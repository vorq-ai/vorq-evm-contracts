// SPDX-License-Identifier: FSL-1.1-ALv2
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {Order} from "../../src/Types.sol";

/// @notice The EIP-712 type tables and message renderers the signing vectors publish.
///
/// The `T_*` functions return the **types tables**, not type strings: `[{name, type}, ...]` per
/// struct, which is the object `eth_account.encode_typed_data` and viem's `hashTypedData` take
/// verbatim. Publishing the table rather than the derived string is what lets each consumer assert
/// its own table by direct list equality instead of rebuilding a string to compare.
///
/// These tables are transcribed, and that is safe here for one reason only: every case built from
/// them is signed and handed to the deployed contract in `Vectors.t.sol`. A wrong member list
/// produces a digest the contract does not compute, it recovers a stranger, and the acceptance
/// test reverts. Nothing in this file is trusted on its own.
///
/// Numeric encoding rule, applied throughout: `uint128`/`uint256` are decimal STRINGS, because a
/// 256-bit value does not survive a language whose default number type is a double. `uint32` and
/// `uint64` are JSON numbers.
library VecJson {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    // --- domain tables -------------------------------------------------------------------------

    string internal constant D_FULL =
        '"EIP712Domain":[{"name":"name","type":"string"},{"name":"version","type":"string"},{"name":"chainId","type":"uint256"},{"name":"verifyingContract","type":"address"}]';
    /// @dev Off-chain artifacts (Release, VorqSession) have no verifying contract at all.
    string internal constant D_NO_VC =
        '"EIP712Domain":[{"name":"name","type":"string"},{"name":"version","type":"string"},{"name":"chainId","type":"uint256"}]';

    // --- types tables --------------------------------------------------------------------------

    /// @dev `taskCid` is a member of the Order STRUCT the contract stores but not of the Order TYPE
    /// it hashes: only the coordinator pins, so the client cannot know the CID when it signs. An
    /// implementation that folds it into the struct hash fails on this case and nowhere else.
    function T_ORDER() internal pure returns (string memory) {
        return string.concat(
            "{",
            D_FULL,
            ',"Order":[{"name":"c","type":"bytes32"},{"name":"modelId","type":"uint32"},',
            '{"name":"slaSecs","type":"uint32"},{"name":"rateIn","type":"uint128"},',
            '{"name":"rateOut","type":"uint128"},{"name":"unitsIn","type":"uint32"},',
            '{"name":"unitsOut","type":"uint32"},{"name":"designated","type":"uint32"},',
            '{"name":"expiresAt","type":"uint64"}]}'
        );
    }

    function T_CANCEL() internal pure returns (string memory) {
        return string.concat(
            "{", D_FULL, ',"Cancel":[{"name":"jobId","type":"bytes32"},{"name":"issuedAt","type":"uint64"}]}'
        );
    }

    function T_CLAIM() internal pure returns (string memory) {
        return
            string.concat(
                "{", D_FULL, ',"Claim":[{"name":"jobId","type":"bytes32"},{"name":"issuedAt","type":"uint64"}]}'
            );
    }

    /// @dev Members identical to Claim's — only the type NAME separates the two digests.
    function T_FAIL() internal pure returns (string memory) {
        return
            string.concat(
                "{", D_FULL, ',"Fail":[{"name":"jobId","type":"bytes32"},{"name":"issuedAt","type":"uint64"}]}'
            );
    }

    /// @dev No resultCid: the coordinator pins the result and the relayer fills the CID in
    /// afterwards, so the digest is independent of whatever is submitted alongside it.
    function T_SETTLE() internal pure returns (string memory) {
        return string.concat(
            "{",
            D_FULL,
            ',"Settle":[{"name":"jobId","type":"bytes32"},{"name":"completionTok","type":"uint32"},',
            '{"name":"issuedAt","type":"uint64"}]}'
        );
    }

    /// @dev `evidence` is dynamic bytes: it enters the struct hash as `keccak256(evidence)`, never
    /// inline, and `keccak256("")` is a real hash rather than a zero word.
    function T_SET_IDENTITY() internal pure returns (string memory) {
        return string.concat(
            "{",
            D_FULL,
            ',"SetIdentity":[{"name":"boxKey","type":"bytes32"},{"name":"evidence","type":"bytes"},',
            '{"name":"issuedAt","type":"uint64"}]}'
        );
    }

    function T_REQUEST_CAPACITY() internal pure returns (string memory) {
        return string.concat(
            "{", D_FULL, ',"RequestCapacity":[{"name":"n","type":"uint32"},{"name":"issuedAt","type":"uint64"}]}'
        );
    }

    function T_ASK_SNAPSHOT() internal pure returns (string memory) {
        return string.concat(
            "{",
            D_FULL,
            ',"AskSnapshot":[{"name":"providerId","type":"uint32"},{"name":"signedAt","type":"uint64"},',
            '{"name":"quotes","type":"Ask[]"}],',
            '"Ask":[{"name":"modelId","type":"uint32"},{"name":"sla","type":"uint32"},',
            '{"name":"rateIn","type":"uint128"},{"name":"rateOut","type":"uint128"}]}'
        );
    }

    /// @dev EIP-3009, the payment token's own type — not one of ours. The domain is the TOKEN's
    /// (its name, its version, its address), which is why this case reads every one of those off
    /// the deployed token instead of transcribing them. `nonce` is a bytes32 and carries the jobId,
    /// so the authorization is single-use per job on the token itself.
    function T_RECEIVE_AUTH() internal pure returns (string memory) {
        return string.concat(
            "{",
            D_FULL, // the four-member EIP712Domain list the registries' types already use
            ',"ReceiveWithAuthorization":[{"name":"from","type":"address"},{"name":"to","type":"address"},',
            '{"name":"value","type":"uint256"},{"name":"validAfter","type":"uint256"},',
            '{"name":"validBefore","type":"uint256"},{"name":"nonce","type":"bytes32"}]}'
        );
    }

    function T_RELEASE() internal pure returns (string memory) {
        return string.concat(
            "{",
            D_NO_VC,
            ',"Release":[{"name":"jobId","type":"bytes32"},{"name":"seedWrap","type":"bytes"},',
            '{"name":"ctHash","type":"bytes32"},',
            '{"name":"responsePubkey","type":"bytes32"},{"name":"issuedAt","type":"uint64"}]}'
        );
    }

    /// @dev The operator's authorization for one `POST /handover` pull. Off-chain, in the escrow
    /// domain beside Release: no contract verifies it, so this vector is the only thing keeping the
    /// two coordinator instances that sign and check it in agreement across a release.
    ///
    /// `channelPubkey` is the X25519 key the payload comes back sealed to, so the signature is
    /// bound to one exchange; `issuedAt` bounds the replay window to the same ±600 s the release
    /// path uses. There is no mode member — a handover changes nothing on the node it reads from,
    /// so there is no second flavour of it to distinguish.
    function T_HANDOVER_AUTH() internal pure returns (string memory) {
        return string.concat(
            "{",
            D_NO_VC,
            ',"HandoverAuth":[{"name":"channelPubkey","type":"bytes32"},',
            '{"name":"issuedAt","type":"uint64"}]}'
        );
    }

    /// @dev The member is literally named `address`. Legal in EIP-712, and the reason this artifact
    /// could never be expressed as a Solidity struct.
    function T_SESSION() internal pure returns (string memory) {
        return string.concat(
            "{", D_NO_VC, ',"VorqSession":[{"name":"address","type":"address"},{"name":"nonce","type":"string"}]}'
        );
    }

    // --- scalars -------------------------------------------------------------------------------

    function q(string memory v) internal pure returns (string memory) {
        return string.concat('"', v, '"');
    }

    function h(bytes32 v) internal pure returns (string memory) {
        return q(vm.toString(v));
    }

    function a(address v) internal pure returns (string memory) {
        return q(vm.toString(v));
    }

    function b(bytes memory v) internal pure returns (string memory) {
        return q(vm.toString(v));
    }

    function n(uint256 v) internal pure returns (string memory) {
        return vm.toString(v);
    }

    /// @dev decimal STRING, for anything wider than a uint53
    function s(uint256 v) internal pure returns (string memory) {
        return q(vm.toString(v));
    }

    // --- envelopes -----------------------------------------------------------------------------

    /// @dev Each registry declares its OWN name, so a domain is no longer identified by its
    /// address alone. Two address slots resolving to one contract used to be invisible; now the
    /// separators differ regardless.
    function vorqDomain(string memory name, uint256 chainId, address verifying) internal pure returns (string memory) {
        return fullDomain(name, "2", chainId, verifying);
    }

    /// @dev The same four members, with the version supplied rather than pinned: the payment
    /// token's domain is the token's own and its version is read off the deployed token.
    function fullDomain(string memory name, string memory version, uint256 chainId, address verifying)
        internal
        pure
        returns (string memory)
    {
        return string.concat(
            '{"name":',
            q(name),
            ',"version":',
            q(version),
            ',"chainId":',
            n(chainId),
            ',"verifyingContract":',
            a(verifying),
            "}"
        );
    }

    function bareDomain(string memory name, string memory version, uint256 chainId)
        internal
        pure
        returns (string memory)
    {
        return string.concat('{"name":', q(name), ',"version":', q(version), ',"chainId":', n(chainId), "}");
    }

    function typedData(string memory types, string memory primaryType, string memory domain, string memory message)
        internal
        pure
        returns (string memory)
    {
        return string.concat(
            '{"types":', types, ',"primaryType":', q(primaryType), ',"domain":', domain, ',"message":', message, "}"
        );
    }

    function array(string[] memory items) internal pure returns (string memory out) {
        out = "[";
        for (uint256 i; i < items.length; i++) {
            out = string.concat(out, i == 0 ? "" : ",", items[i]);
        }
        out = string.concat(out, "]");
    }

    // --- messages ------------------------------------------------------------------------------

    function orderMessage(Order memory o) internal pure returns (string memory) {
        return string.concat(
            '{"c":',
            h(o.c),
            ',"modelId":',
            n(o.modelId),
            ',"slaSecs":',
            n(o.slaSecs),
            ',"rateIn":',
            s(o.rateIn),
            ',"rateOut":',
            s(o.rateOut),
            ',"unitsIn":',
            n(o.unitsIn),
            ',"unitsOut":',
            n(o.unitsOut),
            ',"designated":',
            n(o.designated),
            ',"expiresAt":',
            n(o.expiresAt),
            "}"
        );
    }

    function jobOp(bytes32 jobId, uint64 issuedAt) internal pure returns (string memory) {
        return string.concat('{"jobId":', h(jobId), ',"issuedAt":', n(issuedAt), "}");
    }

    function settleMessage(bytes32 jobId, uint32 completionTok, uint64 issuedAt) internal pure returns (string memory) {
        return
            string.concat(
                '{"jobId":', h(jobId), ',"completionTok":', n(completionTok), ',"issuedAt":', n(issuedAt), "}"
            );
    }

    function identityMessage(bytes32 boxKey, bytes memory evidence, uint64 issuedAt)
        internal
        pure
        returns (string memory)
    {
        return string.concat('{"boxKey":', h(boxKey), ',"evidence":', b(evidence), ',"issuedAt":', n(issuedAt), "}");
    }

    function capacityMessage(uint32 count, uint64 issuedAt) internal pure returns (string memory) {
        return string.concat('{"n":', n(count), ',"issuedAt":', n(issuedAt), "}");
    }

    /// @dev `validAfter` is 0 and `validBefore` is `expiresAt + 1`, because the token requires
    /// `block.timestamp < validBefore` and a claim landing exactly on the expiry second must still
    /// fund. `nonce` is the jobId — a bytes32, rendered as hex, and single-use on the token.
    function authMessage(address from, address to, uint256 value, uint64 expiresAt, bytes32 jobId)
        internal
        pure
        returns (string memory)
    {
        return string.concat(
            '{"from":',
            a(from),
            ',"to":',
            a(to),
            ',"value":',
            s(value),
            ',"validAfter":"0","validBefore":',
            s(uint256(expiresAt) + 1),
            ',"nonce":',
            h(jobId),
            "}"
        );
    }

    function askMessage(uint32 providerId, uint64 signedAt, bool empty) internal pure returns (string memory) {
        // Three quotes, and the last two are the point. The withdrawal sentinel is BOTH legs zero;
        // a quote with rateOut 0 and a nonzero rateIn is an input-metered model (embeddings —
        // priced on prompt tokens, settling at completionTok 0) and is a LIVE slot. A consumer
        // that treats rateOut 0 as "withdraw" deletes the third quote; one that treats it as
        // "absent" never offers the model. Both fail here rather than in production.
        string memory quotes = empty
            ? "[]"
            : string.concat(
                '[{"modelId":1,"sla":3600,"rateIn":"30000","rateOut":"90000"},',
                '{"modelId":1,"sla":86400,"rateIn":"0","rateOut":"0"},',
                '{"modelId":2,"sla":86400,"rateIn":"1","rateOut":"0"}]'
            );
        return string.concat('{"providerId":', n(providerId), ',"signedAt":', n(signedAt), ',"quotes":', quotes, "}");
    }

    function releaseMessage(
        bytes32 jobId,
        bytes memory seedWrap,
        bytes32 ctHash,
        bytes32 responsePubkey,
        uint64 issuedAt
    ) internal pure returns (string memory) {
        return string.concat(
            '{"jobId":',
            h(jobId),
            ',"seedWrap":',
            b(seedWrap),
            ',"ctHash":',
            h(ctHash),
            ',"responsePubkey":',
            h(responsePubkey),
            ',"issuedAt":',
            n(issuedAt),
            "}"
        );
    }

    function handoverAuthMessage(bytes32 channelPubkey, uint64 issuedAt) internal pure returns (string memory) {
        return string.concat('{"channelPubkey":', h(channelPubkey), ',"issuedAt":', n(issuedAt), "}");
    }

    function sessionMessage(address addr, string memory nonce) internal pure returns (string memory) {
        return string.concat('{"address":', a(addr), ',"nonce":', q(nonce), "}");
    }
}
