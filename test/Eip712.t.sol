// SPDX-License-Identifier: FSL-1.1-ALv2
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {JobRegistry, IUSDC} from "../src/JobRegistry.sol";
import {ProviderRegistry} from "../src/ProviderRegistry.sol";
import {AskRegistry} from "../src/AskRegistry.sol";

/// @notice Every `*_TYPEHASH` constant is the hash of a CANONICAL EIP-712 type string.
///
/// A typehash constant is written as `keccak256("Some(uint32 a,uint64 b)")` — a literal the
/// compiler will hash whatever it says. Nothing in the language checks that the string inside is
/// well formed, and a non-canonical one produces a hash no standards-compliant signer will ever
/// reproduce: the signature is then refused with no indication why.
///
/// `vm.eip712HashType` re-derives the hash from the CANONICAL form of whatever it is handed —
/// referenced structs sorted by name and appended after the primary one, no stray whitespace. So
/// comparing it against the deployed constant asks exactly one question: is the literal already
/// canonical? `AskRegistry.SNAPSHOT_TYPEHASH` is where this earns its keep — it hand-concatenates
/// `AskSnapshot(...)` with `Ask(...)`, and getting that order or spacing wrong is invisible
/// everywhere else.
///
/// What this does NOT prove: that the member list is the one the protocol intends. Nothing in
/// Solidity can — the signed shapes are not structs. That is what `Vectors.t.sol` is for, where
/// each signature is built from the published type table and handed to the deployed contract.
///
/// The three registries are deployed with placeholder collaborators: nothing here reads state, and
/// no constructor validates its arguments, so the cheapest instance that answers a getter will do.
contract Eip712Test is Test {
    JobRegistry internal jr;
    ProviderRegistry internal reg;
    AskRegistry internal ar;

    function setUp() public {
        reg = new ProviderRegistry(address(this));
        ar = new AskRegistry(reg);
        jr = new JobRegistry(reg, IUSDC(makeAddr("usdc")), address(this), address(3));
    }

    // Transcribed from the contracts. The assertions below are what make the transcription safe:
    // a drift between these and the source fails `_assertCanonical`'s first check.
    string internal constant ORDER =
        "Order(bytes32 c,uint32 modelId,uint32 slaSecs,uint128 rateIn,uint128 rateOut,uint32 unitsIn,uint32 unitsOut,uint32 designated,uint64 expiresAt)";
    string internal constant CLAIM = "Claim(bytes32 jobId,uint64 issuedAt)";
    string internal constant SETTLE = "Settle(bytes32 jobId,uint32 completionTok,uint64 issuedAt)";
    string internal constant FAIL = "Fail(bytes32 jobId,uint64 issuedAt)";
    string internal constant CANCEL = "Cancel(bytes32 jobId,uint64 issuedAt)";
    string internal constant REQUEST_CAPACITY = "RequestCapacity(uint32 n,uint64 issuedAt)";
    string internal constant SET_IDENTITY = "SetIdentity(bytes32 boxKey,bytes evidence,uint64 issuedAt)";
    string internal constant ASK = "Ask(uint32 modelId,uint32 sla,uint128 rateIn,uint128 rateOut)";
    string internal constant ASK_SNAPSHOT =
        "AskSnapshot(uint32 providerId,uint64 signedAt,Ask[] quotes)Ask(uint32 modelId,uint32 sla,uint128 rateIn,uint128 rateOut)";

    function _assertCanonical(string memory typeString, bytes32 deployed, string memory what) private pure {
        assertEq(keccak256(bytes(typeString)), deployed, string.concat(what, ": transcription drifted"));
        assertEq(vm.eip712HashType(typeString), deployed, string.concat(what, ": type string is not canonical"));
    }

    function test_JobRegistryTypehashesAreCanonical() public view {
        _assertCanonical(ORDER, jr.ORDER_TYPEHASH(), "Order");
        _assertCanonical(CLAIM, jr.CLAIM_TYPEHASH(), "Claim");
        _assertCanonical(SETTLE, jr.SETTLE_TYPEHASH(), "Settle");
        _assertCanonical(FAIL, jr.FAIL_TYPEHASH(), "Fail");
        _assertCanonical(CANCEL, jr.CANCEL_TYPEHASH(), "Cancel");
    }

    function test_ProviderRegistryTypehashesAreCanonical() public view {
        _assertCanonical(REQUEST_CAPACITY, reg.REQUEST_CAPACITY_TYPEHASH(), "RequestCapacity");
        _assertCanonical(SET_IDENTITY, reg.SET_IDENTITY_TYPEHASH(), "SetIdentity");
    }

    function test_AskRegistryTypehashesAreCanonical() public view {
        _assertCanonical(ASK, ar.ASK_TYPEHASH(), "Ask");
        _assertCanonical(ASK_SNAPSHOT, ar.SNAPSHOT_TYPEHASH(), "AskSnapshot");
    }

    /// @dev The failure mode `_assertCanonical` exists to catch, made concrete.
    ///
    /// EIP-712 appends referenced structs AFTER the primary type. Write the same two structs the
    /// other way round and you get a different literal, a different `keccak256`, and therefore a
    /// different typehash — but `vm.eip712HashType` normalises both to the canonical one. So the
    /// two assertions in `_assertCanonical` are not redundant: the raw `keccak256` says which side
    /// of that normalisation the deployed constant sits on, and only the canonical side is a hash
    /// any standards-compliant signer will ever produce.
    function test_MisorderedReferencedStructWouldChangeTheTypehash() public view {
        string memory prepended =
            "Ask(uint32 modelId,uint32 sla,uint128 rateIn,uint128 rateOut)AskSnapshot(uint32 providerId,uint64 signedAt,Ask[] quotes)";

        assertTrue(keccak256(bytes(prepended)) != ar.SNAPSHOT_TYPEHASH(), "the mis-ordered literal is not distinct");
        assertEq(vm.eip712HashType(prepended), ar.SNAPSHOT_TYPEHASH(), "both orderings canonicalise to one typehash");
    }

    /// @dev An incomplete definition is refused rather than guessed at: naming `Ask[]` without
    /// defining `Ask` cannot resolve. Worth pinning, because it is what makes a type table that
    /// omits a referenced struct fail loudly instead of hashing something plausible.
    function test_AnUnresolvedReferencedStructIsRefused() public {
        vm.expectRevert();
        this.hashType("AskSnapshot(uint32 providerId,uint64 signedAt,Ask[] quotes)");
    }

    function hashType(string calldata t) external pure returns (bytes32) {
        return vm.eip712HashType(t);
    }

    /// @dev The three registries answer to three DIFFERENT domain names.
    ///
    /// They used to share `"VORQ"` and differ only in `verifyingContract`. That left one real
    /// failure mode invisible: a deployment whose configuration resolves two address slots to the
    /// same contract produces digests indistinguishable from legitimate ones. Distinct names make
    /// the separators differ whatever the addresses are.
    function test_TheThreeRegistriesDeclareDistinctDomains() public view {
        assertEq(jr.EIP712_NAME(), "VORQ Jobs");
        assertEq(reg.EIP712_NAME(), "VORQ Providers");
        assertEq(ar.EIP712_NAME(), "VORQ Asks");

        assertTrue(jr.DOMAIN_SEPARATOR() != reg.DOMAIN_SEPARATOR(), "job and provider domains collide");
        assertTrue(jr.DOMAIN_SEPARATOR() != ar.DOMAIN_SEPARATOR(), "job and ask domains collide");
        assertTrue(reg.DOMAIN_SEPARATOR() != ar.DOMAIN_SEPARATOR(), "provider and ask domains collide");
    }

    /// @dev The names alone separate them — proved by holding the address constant.
    ///
    /// Rebuild all three separators over ONE address. If they still differ, the discrimination
    /// comes from the name and survives any address mix-up; under the old shared `"VORQ"` all
    /// three would have been identical here.
    function test_TheNamesAloneSeparateTheDomainsEvenAtOneAddress() public view {
        bytes32 j = _separatorOver(jr.EIP712_NAME(), address(jr));
        bytes32 p = _separatorOver(reg.EIP712_NAME(), address(jr));
        bytes32 a = _separatorOver(ar.EIP712_NAME(), address(jr));

        assertTrue(j != p && j != a && p != a, "the domains are told apart only by address");
        assertEq(j, jr.DOMAIN_SEPARATOR(), "the job registry's own separator is not this recipe");
    }

    function _separatorOver(string memory name, address verifying) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes("2")),
                block.chainid,
                verifying
            )
        );
    }

    /// @dev ERC-5267: each registry publishes the domain it actually computes, so a consumer can
    /// rebuild the separator and refuse to boot rather than discovering the mismatch as a stranger.
    function test_Erc5267PublishesTheDomainEachContractActuallyUses() public view {
        _assertPublishedDomain(address(jr), jr.EIP712_NAME(), jr.DOMAIN_SEPARATOR());
        _assertPublishedDomain(address(reg), reg.EIP712_NAME(), reg.DOMAIN_SEPARATOR());
        _assertPublishedDomain(address(ar), ar.EIP712_NAME(), ar.DOMAIN_SEPARATOR());
    }

    function _assertPublishedDomain(address target, string memory expectedName, bytes32 expectedSeparator)
        private
        view
    {
        (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        ) = IErc5267(target).eip712Domain();

        assertEq(fields, hex"0f", "fields must claim name, version, chainId, verifyingContract");
        assertEq(name, expectedName);
        assertEq(version, "2");
        assertEq(chainId, block.chainid);
        assertEq(verifyingContract, target);
        assertEq(salt, bytes32(0), "no salt is used");
        assertEq(extensions.length, 0, "no extensions are used");

        assertEq(_separatorOver(name, verifyingContract), expectedSeparator, "published domain is not the real one");
    }

    /// @dev Claim and Fail have identical members; only the type NAME separates their digests. A
    /// signer that reuses one typehash for the other produces a signature the contract silently
    /// refuses, so this is asserted rather than assumed.
    function test_ClaimAndFailShareMembersButNotTypehashes() public view {
        assertTrue(jr.CLAIM_TYPEHASH() != jr.FAIL_TYPEHASH(), "Claim and Fail collide");
        assertTrue(jr.CANCEL_TYPEHASH() != jr.CLAIM_TYPEHASH(), "Cancel and Claim collide");
        assertTrue(jr.CANCEL_TYPEHASH() != jr.FAIL_TYPEHASH(), "Cancel and Fail collide");
    }
}

/// @notice ERC-5267's one method, declared here rather than vendored: the three registries
/// implement it and nothing else in this repo consumes it.
interface IErc5267 {
    function eip712Domain()
        external
        view
        returns (bytes1, string memory, string memory, uint256, address, bytes32, uint256[] memory);
}
