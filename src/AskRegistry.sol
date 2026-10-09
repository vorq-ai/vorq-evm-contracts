// SPDX-License-Identifier: FSL-1.1-ALv2
pragma solidity 0.8.30;

import {Ask, AskSnapshot} from "./Types.sol";
import {ProviderRegistry} from "./ProviderRegistry.sol";

/// @notice The ask book: providers publish a whole price snapshot, signed EIP-712, and any relayer
/// lands it. There is no curation surface here — the signature is the only authority.
/// @dev `setAsks` is skip-not-revert per entry: one malformed, oversized, forged or stale entry is
/// silently dropped and its neighbours in the same batch still land. `LengthMismatch()` is the only
/// condition that reverts the whole call, because a length mismatch means the caller cannot say
/// which signature belongs to which snapshot — there is nothing to skip.
contract AskRegistry {
    error LengthMismatch();

    event AsksPublished(uint32 indexed providerId, uint64 signedAt, Ask[] quotes);

    uint256 public constant MAX_QUOTES = 64;
    bytes32 public constant ASK_TYPEHASH = keccak256("Ask(uint32 modelId,uint32 sla,uint128 rateIn,uint128 rateOut)");
    // the concatenated EIP-712 form: the primary type first, then the referenced struct appended
    // (EIP-712 appends referenced types after the primary one, sorted by name). Plan 2's publisher
    // and Plan 4's provider SDK both sign against this string off-chain, so it is byte-exact and a
    // test spells the literal out again rather than reading it back off the contract.
    bytes32 public constant SNAPSHOT_TYPEHASH = keccak256(
        "AskSnapshot(uint32 providerId,uint64 signedAt,Ask[] quotes)Ask(uint32 modelId,uint32 sla,uint128 rateIn,uint128 rateOut)"
    );

    ProviderRegistry public immutable registry;
    bytes32 public immutable DOMAIN_SEPARATOR; // this contract's own domain
    /// @dev A DISTINCT EIP-712 domain name per contract, deliberately.
    ///
    /// All three registries previously answered to `"VORQ"` and differed only in
    /// `verifyingContract`. That is legal, and it makes one real failure mode invisible: a
    /// deployment whose configuration resolves two address slots to the same contract produces
    /// digests indistinguishable from legitimate ones, and a wrong `verifyingContract` never
    /// errors - it recovers a stranger. Distinct names make the separators differ regardless of
    /// what the addresses are, and let a wallet show which contract is being authorised.
    string public constant EIP712_NAME = "VORQ Asks";
    string public constant EIP712_VERSION = "2";
    mapping(uint32 => uint64) public lastSignedAt; // monotonic floor — AskSnapshot ops
    // providerId → modelId → sla → (rateIn << 128) | rateOut; an absent slot is 0, i.e. (0, 0)
    mapping(uint32 => mapping(uint32 => mapping(uint32 => uint256))) internal slots;

    constructor(ProviderRegistry registry_) {
        registry = registry_;
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(EIP712_NAME)),
                keccak256(bytes(EIP712_VERSION)),
                block.chainid,
                address(this)
            )
        );
    }

    function setAsks(AskSnapshot[] calldata batch, bytes[] calldata sigs) external {
        // NEVER msg.sender: any key may land the batch; only the operator can author an entry
        if (batch.length != sigs.length) revert LengthMismatch();
        for (uint256 i; i < batch.length; i++) {
            AskSnapshot calldata s = batch[i];
            if (s.quotes.length > MAX_QUOTES) continue; // bounded so one entry cannot eat the block
            // clock-skew bound: without it a daemon with a broken clock signs a far-future signedAt
            // and bricks its own slot forever under the monotonic rule
            if (s.signedAt > block.timestamp + 3600) continue;
            address signer = _recover(s, sigs[i]);
            // a zero recovered signer never authorizes: _recover answers address(0) for a malformed
            // signature, so refuse it before it is compared to anything — idOf[address(0)] could be
            // nonzero on a poisoned registry, and a bad signature must never authenticate
            if (signer == address(0)) continue;
            uint32 id = registry.idOf(signer); // plain mapping, never reverts: 0 = not a provider
            // the snapshot names its own provider, so a real operator cannot publish for another id
            if (id == 0 || id != s.providerId) continue;
            // latest-wins state: strict ordering, so a replayed older snapshot never resurrects an
            // old price and an exact duplicate re-publish is a silent no-op
            if (s.signedAt <= lastSignedAt[id]) continue;
            lastSignedAt[id] = s.signedAt;
            for (uint256 q; q < s.quotes.length; q++) {
                Ask calldata a = s.quotes[q];
                // BOTH legs zero means withdraw. `rateOut == 0` alone cannot be the sentinel: an
                // input-metered model prices only its input side — an embedding backend reports
                // `prompt_tokens` and no completion count, so the job settles at `completionTok == 0`
                // and `rateOut` never enters the charge — and that ask must be publishable as
                // itself. Under the old rule it would silently unpublish the slot, leaving a fake
                // output price as the only way into the book.
                if (a.rateIn == 0 && a.rateOut == 0) {
                    delete slots[id][a.modelId][a.sla];
                } else {
                    // packing is lossless: rateIn and rateOut are both uint128, so the shift moves
                    // rateIn (< 2**128) into the high half with nothing carried out of the uint256,
                    // and rateOut only ever occupies the low 128 bits — the two halves cannot
                    // collide. getQuote reverses it exactly.
                    uint256 packed = (uint256(a.rateIn) << 128) | a.rateOut;
                    if (slots[id][a.modelId][a.sla] != packed) slots[id][a.modelId][a.sla] = packed;
                }
            }
            // the whole snapshot, so a log projection replaces its book for this provider rather
            // than merging. On chain the write is an upsert: a slot this snapshot omits keeps its
            // previous value until an explicit both-legs-zero entry withdraws it.
            emit AsksPublished(id, s.signedAt, s.quotes);
        }
    }

    function getQuote(uint32 providerId, uint32 modelId, uint32 sla)
        external
        view
        returns (uint128 rateIn, uint128 rateOut)
    {
        uint256 p = slots[providerId][modelId][sla];
        // both casts are lossless by construction of the packing above: the slot is only ever
        // written as (uint256(rateIn) << 128) | rateOut with both operands uint128, so p >> 128 is
        // exactly rateIn (already < 2**128) and the low 128 bits of p are exactly rateOut
        return (uint128(p >> 128), uint128(p));
    }

    function _recover(AskSnapshot calldata s, bytes calldata sig) internal view returns (address) {
        // plain ecrecover, 65-byte (r,s,v) sigs — EOA keys only in v1; malformed sigs recover to
        // garbage or address(0), and setAsks refuses address(0) explicitly before using it
        if (sig.length != 65) return address(0);
        bytes32[] memory quoteHashes = new bytes32[](s.quotes.length);
        for (uint256 i; i < s.quotes.length; i++) {
            Ask calldata a = s.quotes[i];
            quoteHashes[i] = keccak256(abi.encode(ASK_TYPEHASH, a.modelId, a.sla, a.rateIn, a.rateOut));
        }
        // EIP-712 array-of-structs: the member is the keccak of the concatenated element hashes
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR,
                keccak256(
                    abi.encode(SNAPSHOT_TYPEHASH, s.providerId, s.signedAt, keccak256(abi.encodePacked(quoteHashes)))
                )
            )
        );
        return ecrecover(digest, uint8(sig[64]), bytes32(sig[0:32]), bytes32(sig[32:64]));
    }

    /// @notice ERC-5267: publish this contract's EIP-712 domain rather than making every client
    /// transcribe it. `fields = 0x0f` - name, version, chainId and verifyingContract present; no
    /// salt, no extensions. A consumer can rebuild `DOMAIN_SEPARATOR` from this and check it,
    /// which is what turns a wrong address from a silent stranger into a refusal to boot.
    function eip712Domain()
        external
        view
        returns (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        )
    {
        return (hex"0f", EIP712_NAME, EIP712_VERSION, block.chainid, address(this), bytes32(0), new uint256[](0));
    }
}
