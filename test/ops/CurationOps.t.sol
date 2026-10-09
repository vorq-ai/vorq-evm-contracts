// SPDX-License-Identifier: FSL-1.1-ALv2
pragma solidity 0.8.30;

import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
import {Curation} from "../../script/ops/Curation.s.sol";
import {AskRegistry} from "../../src/AskRegistry.sol";
import {IUSDC, JobRegistry} from "../../src/JobRegistry.sol";
import {ProviderRegistry} from "../../src/ProviderRegistry.sol";
import {OpsFixture} from "./OpsFixture.sol";

/// @dev `vm.broadcast` records a transaction — correct in a script, wrong in a test. The base
/// makes the sender application virtual for exactly this substitution.
contract CurationHarness is Curation {
    function bind(ProviderRegistry r, JobRegistry j, AskRegistry a, address c) external {
        reg = r;
        jr = j;
        ar = a;
        curationAddr = c;
        dev = true;
    }

    /// @dev `setAllowedModels` renders its before-set from this. `Reads.t.sol` asserts the same
    /// helper through its own harness; this one exists to prove `Curation` reaches the SAME
    /// implementation in `OpsBase`, which is the whole reason it does not live in `Reads`.
    function allowAllModels(uint32 id) external view returns (bool allowAll, bool decisive) {
        return _allowAllModels(id);
    }

    /**
     * @dev The stranding acknowledgement, per instance. NOT `vm.setEnv`: that writes the one
     * process environment the whole run shares, foundry never resets it, and the tests in this
     * contract execute IN PARALLEL — so `test_revokingRequiresAnExplicitAcknowledgement` (which
     * needs it unset) and `test_revokingProceedsWithTheAcknowledgement` (which needs it set) would
     * race over a single global and the loser would report the safety gate as not firing. `setUp`
     * builds a fresh harness per test, so this field cannot cross a test boundary. The production
     * reader in `Curation._ackStranding` is covered by a `forge script` run instead.
     */
    bool internal ack;

    function ackStranding(bool v) external {
        ack = v;
    }

    function _ackStranding() internal view override returns (bool) {
        return ack;
    }

    function _load() internal override {}

    function _asCuration() internal override {
        vm.prank(curationAddr);
    }

    function _requireCurationKey() internal override {}
}

/**
 * @dev The one thing `CurationHarness` cannot cover: it OVERRIDES `_ackStranding`, so the
 * production body — the single line that decides whether the stranding gate fires at all — is
 * invisible to every test that goes through the harness, and stubbing it to `return true` leaves
 * the whole suite green. This probe deliberately does NOT override it, so the assertion below runs
 * the real `vm.envOr` read.
 *
 * Only the FAIL-CLOSED direction is asserted, and that is not a shortcut. "Absent acknowledgement
 * must refuse" is the safety-critical half and needs no `vm.setEnv` — no test in this suite sets
 * `VORQ_OPS_ACK_STRANDING`, so an absent variable is deterministic. The other half, "set implies
 * proceed", cannot be reached without writing the process environment that foundry runs every test
 * in IN PARALLEL, which would trade a real race for coverage of the less dangerous direction. It is
 * covered by a `forge script` run against the devnet instead — see the task report.
 */
contract AckProbe is Curation {
    function ackStrandingFromEnv() external view returns (bool) {
        return _ackStranding();
    }
}

/**
 * @dev The seven return shapes that `try/catch` does NOT catch. `try` catches a REVERTING callee; a
 * callee that SUCCEEDS and returns bytes the caller cannot decode reverts outside the try, taking
 * the whole op with it. Each of these is a real thing an address can be, and the first is the
 * likeliest of all: `fallback() external {}` is what a mis-authorised helper contract or a
 * payable-fallback token looks like, and revoking a mis-authorisation is the realistic reason to
 * call this op on a non-registry address at all.
 */
contract EmptyReturnFallback {
    fallback() external {}
}

/// @dev answers every call with 32 bytes of ones: decodes as a uint256 but not as an address
contract DirtyWordFallback {
    fallback() external {
        assembly {
            mstore(0, not(0))
            return(0, 32)
        }
    }
}

/// @dev answers every call with 16 bytes — a short word no decode can complete
contract ShortReturnFallback {
    fallback() external {
        assembly {
            mstore(0, 0)
            return(0, 16)
        }
    }
}

/// @dev the shape that makes the high-bit check load-bearing rather than decorative: the LOW 160
/// bits are the real ProviderRegistry, so truncating the word would vouch this contract, and only
/// rejecting the dirty high bits catches it. `abi.decode(…, (address))` would revert on it, which
/// is the abort the whole fix exists to avoid.
contract DirtyHighBitsRegistry {
    uint256 private immutable word;

    constructor(address r) {
        word = uint256(uint160(r)) | (uint256(1) << 200);
    }

    /// @dev same selector as the real getter, returning a word that is not a clean address
    function registry() external view returns (uint256) {
        return word;
    }

    /// @dev deliberately clean and NON-ZERO: without the high-bit check this contract is vouched
    /// and its 3 is printed as a real claimed-job count. A dirty answer here would be caught by the
    /// `uint32` bound instead, and the high-bit check would score as equivalent.
    function activeJobs(uint32) external pure returns (uint32) {
        return 3;
    }
}

/// @dev vouches correctly and then answers SHORT from inside the loop. Distinct from
/// `ShortReturnFallback`, which never gets past `registry()`: this one exercises the loop's own
/// length check, the Finding-1 abort class in its second half.
contract VouchedShortActiveJobs {
    ProviderRegistry public immutable registry;

    constructor(ProviderRegistry r) {
        registry = r;
    }

    /// @dev nothing is stored before returning: only the LENGTH is under test, and writing a value
    /// here would suggest the returned 16 bytes carry a truncated count. They do not — a word
    /// written at 0 puts its low byte at offset 31, outside what is returned.
    function activeJobs(uint32) external pure returns (uint32) {
        assembly {
            return(0, 16)
        }
    }
}

/// @dev vouches correctly and then returns 1 MiB from the loop. This pins the BEHAVIOUR — a bomb
/// is answered "unknown" and the revocation still completes — but it does NOT discriminate the two
/// implementations, and saying so is the point of this comment. Reverting `_read32` to
/// `staticcall` into `bytes memory` still passes here, because foundry's default test gas limit is
/// far above the ~2.2M the copy costs at this size. Killing that mutant needs an explicit `{gas:}`
/// cap tight enough to separate the copy from the callee's own memory expansion, which is brittle
/// against solc's layout; the guard rests on the measurement in `_read32`'s NatSpec instead.
contract VouchedReturndataBomb {
    ProviderRegistry public immutable registry;

    constructor(ProviderRegistry r) {
        registry = r;
    }

    function activeJobs(uint32) external pure returns (uint32) {
        assembly {
            return(0, 0x100000)
        }
    }
}

/// @dev vouches correctly and then overflows: `registry()` answers the real ProviderRegistry, so
/// the count proceeds, and `activeJobs` returns a value above `uint32` max from inside the loop.
contract OverflowingCounter {
    ProviderRegistry public immutable registry;

    constructor(ProviderRegistry r) {
        registry = r;
    }

    function activeJobs(uint32) external pure returns (uint256) {
        return uint256(type(uint32).max) + 1;
    }
}

contract CurationOpsTest is OpsFixture {
    using stdStorage for StdStorage;

    CurationHarness internal ops;

    function setUp() public {
        _deployFixture();
        ops = new CurationHarness();
        ops.bind(reg, jr, ar, curation);
    }

    function _register() internal returns (uint32) {
        ops.register(operator, 16, true, 1000);
        return reg.idOf(operator);
    }

    function test_registerCreatesAListedProvider() public {
        uint32 id = _register();
        assertEq(id, 1);
        assertEq(reg.operatorOf(id), operator);
        assertTrue(reg.isListed(id));
        assertEq(reg.reputationOf(id), 1000); // the seed the op was given, not a contract default
    }

    function test_registerRefusesADuplicateOperatorBeforeSending() public {
        _register();
        vm.expectRevert(bytes(unicode"register: operator already holds provider id 1 — use setOperator to move it"));
        ops.register(operator, 16, true, 1000);
    }

    /// @dev The chain clamps a seed outside [100,1000] instead of reverting, so the record would be
    /// born at a number nobody asked for. This preflight is the only thing that says so.
    function test_registerRefusesAnOutOfBandSeedBeforeSending() public {
        vm.expectRevert(bytes(unicode"register: reputation must be within [100,1000] — the contract clamps silently"));
        ops.register(operator, 16, true, 1001);
        assertEq(reg.idOf(operator), 0, "nothing was sent");
    }

    function test_registerRefusesAZeroOperator() public {
        vm.expectRevert(bytes(unicode"register: operator is the zero address — the record would be unreachable"));
        ops.register(address(0), 16, true, 1000);
    }

    /// @dev Every no-op test below asserts on emitted logs, NOT on `vm.getNonce(curation)`. The
    /// harness applies the sender with `vm.prank`, which does not advance an EOA's nonce, so a
    /// nonce assertion holds whether or not the op executed — it was verified to PASS against a
    /// mutant with the early `return` removed. Each of these ops emits unconditionally when it
    /// executes and the preflight reads are `view`, so an empty log buffer is the only sound
    /// evidence that nothing was sent. Do not reintroduce the nonce form.
    function test_setListedIsANoOpWhenAlreadySatisfied() public {
        uint32 id = _register();
        vm.recordLogs();
        ops.setListed(id, true); // already listed
        assertEq(vm.getRecordedLogs().length, 0, "a no-op must not send a transaction");
    }

    /// @dev Regression: the no-op check must run BEFORE the duplicate guard. An operator already
    /// bound to this record has `idOf[newOperator] == id != 0`, so guard-first made this branch
    /// unreachable and refused with "that address already holds a provider id" — naming a conflict
    /// with the record it is already part of.
    function test_setOperatorIsANoOpWhenAlreadyThisOperator() public {
        uint32 id = _register();
        vm.recordLogs();
        ops.setOperator(id, operator); // already this operator
        assertEq(vm.getRecordedLogs().length, 0, "a no-op must not send a transaction");
        assertEq(reg.operatorOf(id), operator);
    }

    function test_setReputationIsANoOpWhenAlreadySatisfied() public {
        uint32 id = _register();
        ops.setReputation(id, 750);
        vm.recordLogs();
        ops.setReputation(id, 750); // already 750
        assertEq(vm.getRecordedLogs().length, 0, "a no-op must not send a transaction");
        assertEq(reg.reputationOf(id), 750);
    }

    function test_setListedDelists() public {
        uint32 id = _register();
        ops.setListed(id, false);
        assertFalse(reg.isListed(id));
    }

    /**
     * @dev Regression, and the sharpest lesson in this file. This test used to assert only
     * `effectiveCap(id) == 1` — which is true BEFORE the call and for EVERY ceiling, because
     * `effectiveCap` is `reputation/1000 * min(requested, ceiling)` floored at 1 and
     * `capacityRequested` is still 0. Its own comment conceded as much. Deleting the whole `_exec`
     * from `setCapacityCeiling` left all 23 tests here green.
     *
     * An assertion that is invariant under the operation is invisible to mutation testing that
     * only ever mutates guards and no-op branches, which is how it survived a seven-row table.
     * `setCapacityCeiling` is the one op in this file with no no-op branch, so nothing else
     * covered its send path either, and `capacityCeiling` has no getter — the emitted event is the
     * only observable proof that anything was sent at all.
     */
    function test_setCapacityCeilingApplies() public {
        uint32 id = _register();
        vm.expectEmit(true, false, false, true, address(reg));
        emit ProviderRegistry.CapacityChanged(id, 64, 0);
        ops.setCapacityCeiling(id, 64);
        // and the pair still collapses to 1, which is the thing the old assertion mistook for proof
        assertEq(reg.effectiveCap(id), 1);
    }

    /// @dev the silent one: the contract clamps to [100,1000] and emits the clamped value, so a
    /// request outside the band lands as something else with no error anywhere.
    function test_setReputationRefusesAValueThatWouldSilentlyClamp() public {
        uint32 id = _register();
        vm.expectRevert(bytes(unicode"setReputation: milli must be within [100,1000] — the contract clamps silently"));
        ops.setReputation(id, 50);
        vm.expectRevert(bytes(unicode"setReputation: milli must be within [100,1000] — the contract clamps silently"));
        ops.setReputation(id, 1001);
    }

    /// @dev The `[100,1000]` band in `setReputation` is two hardcoded literals mirroring `_clamp`.
    /// `abi.encodeCall` pins signatures, but a VALUE is not a signature, so a change to the
    /// contract's band would drift past the compiler in silence. This asserts what the CHAIN does
    /// with the two values just outside the guard, so widening or narrowing `_clamp` fails here.
    function test_theRefusedBandIsExactlyWhatTheChainClamps() public {
        uint32 id = _register();

        vm.prank(curation);
        reg.setReputation(id, 99);
        assertEq(reg.reputationOf(id), 100, "chain clamps 99 up to 100");
        vm.prank(curation);
        reg.setReputation(id, 1001);
        assertEq(reg.reputationOf(id), 1000, "chain clamps 1001 down to 1000");

        // so the op must refuse both rather than let them land as a different number
        vm.expectRevert(bytes(unicode"setReputation: milli must be within [100,1000] — the contract clamps silently"));
        ops.setReputation(id, 99);
        vm.expectRevert(bytes(unicode"setReputation: milli must be within [100,1000] — the contract clamps silently"));
        ops.setReputation(id, 1001);

        // and the edges themselves are accepted — the guard is not off by one in either direction
        ops.setReputation(id, 100);
        assertEq(reg.reputationOf(id), 100);
        ops.setReputation(id, 1000);
        assertEq(reg.reputationOf(id), 1000);
    }

    function test_setReputationApplies() public {
        uint32 id = _register();
        ops.setReputation(id, 750);
        assertEq(reg.reputationOf(id), 750);
    }

    function test_setOperatorMovesTheRecordAndRefusesADuplicate() public {
        uint32 id = _register();
        address next = makeAddr("next-operator");
        ops.setOperator(id, next);
        assertEq(reg.operatorOf(id), next);
        assertEq(reg.idOf(operator), 0);

        ops.register(operator, 8, true, 1000); // operator is free again
        vm.expectRevert(bytes("setOperator: that address already holds a provider id"));
        ops.setOperator(id, operator);
    }

    function test_everyOpRefusesAnUnknownProviderId() public {
        vm.expectRevert(bytes("ops: unknown provider id 7"));
        ops.setListed(7, true);
        vm.expectRevert(bytes("ops: unknown provider id 7"));
        ops.setCapacityCeiling(7, 1);
        vm.expectRevert(bytes("ops: unknown provider id 7"));
        ops.setReputation(7, 500);
        vm.expectRevert(bytes("ops: unknown provider id 7"));
        ops.setOperator(7, makeAddr("x"));
        vm.expectRevert(bytes("ops: unknown provider id 7"));
        ops.setAllowedModels(7, new uint32[](0), false);
    }

    function test_registerModelAppendsAndReportsTheId() public {
        ops.registerModel("some-org/some-model:fp8");
        assertTrue(reg.modelExists(1));
        assertTrue(reg.modelEnabled(1));
        assertEq(reg.nextModelId(), 2);
    }

    /// @dev the catalog is append-only, so an empty name would occupy an id forever with nothing
    /// to identify it. The chain accepts it — this guard is the only thing that does not.
    function test_registerModelRefusesAnEmptyName() public {
        vm.expectRevert(bytes("registerModel: empty name"));
        ops.registerModel("");
        assertEq(reg.nextModelId(), 1, "nothing may have been appended");
    }

    function test_setModelEnabledRefusesAnUnknownModel() public {
        vm.expectRevert(bytes(unicode"setModelEnabled: model 3 is not in the catalog — run registerModel first"));
        ops.setModelEnabled(3, false);
    }

    /// @dev asserts on emitted logs, never on `vm.getNonce(curation)` — see the note above
    /// `test_setListedIsANoOpWhenAlreadySatisfied`. `setModelEnabled` emits `ModelEnabledChanged`
    /// unconditionally when it executes and every preflight read is `view`, so an empty log buffer
    /// is the only sound evidence that the early return was taken.
    function test_setModelEnabledIsANoOpWhenAlreadySatisfied() public {
        ops.registerModel("m");
        vm.recordLogs();
        ops.setModelEnabled(1, true); // registerModel enables on creation
        assertEq(vm.getRecordedLogs().length, 0, "a no-op must not send a transaction");
        assertTrue(reg.modelEnabled(1));
    }

    function test_setModelEnabledDisables() public {
        ops.registerModel("m");
        ops.setModelEnabled(1, false);
        assertFalse(reg.modelEnabled(1));
    }

    /// @dev the replacement hazard: model 1 is allowed, the new set names only model 2, and 1
    /// silently loses access. The op must show that before it sends.
    function test_setAllowedModelsReplacesRatherThanAdds() public {
        ops.registerModel("m1");
        ops.registerModel("m2");
        uint32 id = _register();

        uint32[] memory first = new uint32[](1);
        first[0] = 1;
        ops.setAllowedModels(id, first, false);
        assertTrue(reg.modelAllowed(id, 1));
        assertFalse(reg.modelAllowed(id, 2));

        uint32[] memory second = new uint32[](1);
        second[0] = 2;
        ops.setAllowedModels(id, second, false);
        assertFalse(reg.modelAllowed(id, 1), unicode"model 1 must have lost access — this call REPLACES");
        assertTrue(reg.modelAllowed(id, 2));
    }

    /// @dev `ProviderRegistry.setAllowedModels` writes `allowed[id][epoch][modelIds[i]] = true`
    /// without consulting `modelExists`, so an unregistered id lands silently and the operator
    /// believes a model is allowed that `post` will reject as ModelDisabled. The guard is real
    /// added safety, not a mirror of a chain check.
    function test_setAllowedModelsRefusesAModelOutsideTheCatalog() public {
        uint32 id = _register();
        uint32[] memory bad = new uint32[](1);
        bad[0] = 9;
        vm.expectRevert(bytes(unicode"setAllowedModels: model 9 is not in the catalog — run registerModel first"));
        ops.setAllowedModels(id, bad, false);

        // and the chain itself would have taken it, which is why the guard has to exist here
        vm.prank(curation);
        reg.setAllowedModels(id, bad, false);
        assertTrue(reg.modelAllowed(id, 9), "the chain accepts an id that is not in the catalog");
        assertFalse(reg.modelExists(9));
    }

    function test_setAllowedModelsAllowAllIgnoresTheList() public {
        ops.registerModel("m1");
        ops.registerModel("m2");
        uint32 id = _register();

        // close the set first: a fresh record is ALREADY allow-all, so asserting against the
        // seeded default would pass against an op that did nothing at all
        uint32[] memory only2 = new uint32[](1);
        only2[0] = 2;
        ops.setAllowedModels(id, only2, false);
        assertFalse(reg.modelAllowed(id, 1));

        uint32[] memory none = new uint32[](0);
        ops.setAllowedModels(id, none, true);
        assertTrue(reg.modelAllowed(id, 1), "allowAll must grant every catalog model");
    }

    /**
     * @dev The before/after diff is the entire point of the op, and a probe of `1..nextModelId()`
     * renders it backwards for every default record: `register` seeds `allowAllModels = true`, so
     * such a loop reports a CLOSED set for a record that allows every id there is. The op reads
     * `OpsBase._allowAllModels` instead, and this pins that it does.
     */
    function test_theBeforeSetSeesADefaultRecordAsAllowAllNotAClosedList() public {
        ops.registerModel("m1");
        uint32 id = _register();

        // the chain's own answer: ids outside the catalog are allowed, so this is allow-all
        assertTrue(reg.modelAllowed(id, reg.nextModelId()));
        (bool allowAll, bool decisive) = ops.allowAllModels(id);
        assertTrue(decisive);
        assertTrue(allowAll, unicode"a 1..nextModelId loop would render this record as a closed set");

        uint32[] memory only1 = new uint32[](1);
        only1[0] = 1;
        ops.setAllowedModels(id, only1, false);
        (allowAll, decisive) = ops.allowAllModels(id);
        assertTrue(decisive);
        assertFalse(allowAll, "the op turned the flag off, so the probed list is now the whole truth");
    }

    /// @dev the same inversion at its loudest: an empty catalog gives the naive loop nothing to
    /// iterate, so it prints `(none)` for a provider that allows every model id in existence.
    function test_theBeforeSetOnAnEmptyCatalogIsAllowAllNotNone() public {
        uint32 id = _register();
        assertEq(reg.nextModelId(), 1, "empty catalog: a 1..nextModelId loop has nothing to iterate");
        (bool allowAll, bool decisive) = ops.allowAllModels(id);
        assertTrue(decisive);
        assertTrue(allowAll, unicode"printing (none) here would be the exact inversion of the truth");
    }

    /// @dev the digest `Deploy.s.sol` seeds and `test/AllowlistKeyConvention.t.sol` pins
    bytes32 internal constant CVM_IMAGE_KEY = 0x3456994b572f1de0ba1b0ab60ef75683822414c5317b6dbbbea50d203bd5d75d;
    string internal constant CVM_IMAGE_MEASUREMENT = "3456994b572f1de0ba1b0ab60ef75683822414c5317b6dbbbea50d203bd5d75d";

    function test_setAllowlistEntryListsAMeasurement() public {
        ops.setAllowlistEntry(CVM_IMAGE_KEY, 1);
        assertEq(reg.allowlistStatus(CVM_IMAGE_KEY), 1);
    }

    function test_setAllowlistEntryRevokes() public {
        ops.setAllowlistEntry(CVM_IMAGE_KEY, 1);
        ops.setAllowlistEntry(CVM_IMAGE_KEY, 2);
        assertEq(reg.allowlistStatus(CVM_IMAGE_KEY), 2);
    }

    /// @dev status 0 is "never listed". Writing it would make a real revocation indistinguishable
    /// from an absent entry, and entries are never deleted, so it is never the right write.
    function test_setAllowlistEntryRefusesStatusZero() public {
        vm.expectRevert(bytes(unicode"setAllowlistEntry: status 0 means 'never listed' — revoke with 2, never 0"));
        ops.setAllowlistEntry(CVM_IMAGE_KEY, 0);
        assertEq(reg.allowlistStatus(CVM_IMAGE_KEY), 0, "nothing may have been written");
    }

    function test_setAllowlistEntryRefusesAStatusNoReaderMatches() public {
        vm.expectRevert(bytes("setAllowlistEntry: status must be 1 (list) or 2 (revoke)"));
        ops.setAllowlistEntry(CVM_IMAGE_KEY, 3);
        // and the chain itself would have taken it, which is why the guard has to exist here
        vm.prank(curation);
        reg.setAllowlistEntry(CVM_IMAGE_KEY, 3, "");
        assertEq(reg.allowlistStatus(CVM_IMAGE_KEY), 3, "curation is trusted: any status lands");
    }

    /// @dev the key IS the measurement, so the zero key is not a digest anyone computed — it is an
    /// empty argument that reached the script. The chain would file a real entry under it.
    function test_setAllowlistEntryRefusesTheZeroKey() public {
        vm.expectRevert(
            bytes(unicode"setAllowlistEntry: the zero key is not a measurement — pass the sha256 image digest")
        );
        ops.setAllowlistEntry(bytes32(0), 1);
    }

    /// @dev asserts on emitted logs, never on `vm.getNonce(curation)` — see the note above
    /// `test_setListedIsANoOpWhenAlreadySatisfied`. `setAllowlistEntry` emits `AllowlistEntrySet`
    /// unconditionally when it executes and every preflight read is `view`, so an empty log buffer
    /// is the only sound evidence that the early return was taken.
    function test_setAllowlistEntryIsANoOpWhenAlreadySatisfied() public {
        ops.setAllowlistEntry(CVM_IMAGE_KEY, 1);
        vm.recordLogs();
        ops.setAllowlistEntry(CVM_IMAGE_KEY, 1); // already 1
        assertEq(vm.getRecordedLogs().length, 0, "a no-op must not send a transaction");
        assertEq(reg.allowlistStatus(CVM_IMAGE_KEY), 1);
    }

    /**
     * The entry is DERIVED from the key, so it can never disagree with the key it is filed under.
     * Its `kind` matters even though the chain never reads it: clients match only `image` and
     * `cvm-image`, so an entry under any other kind gates nothing. This pins the exact bytes the
     * deploy script and `test/AllowlistKeyConvention.t.sol` already pin.
     */
    function test_theEntryIsDerivedFromTheKeyAndCarriesAMatchedKind() public view {
        assertEq(
            string(ops.entryFor(CVM_IMAGE_KEY)),
            string.concat('{"kind":"cvm-image","measurement":"', CVM_IMAGE_MEASUREMENT, '"}')
        );
    }

    /// @dev the entry the op would actually send, taken off the event rather than off `entryFor`:
    /// a derivation nothing routes through is a derivation the op need not be using.
    function test_theEntryTheOpSendsIsTheDerivedOne() public {
        vm.expectEmit(true, false, false, true, address(reg));
        emit ProviderRegistry.AllowlistEntrySet(
            CVM_IMAGE_KEY, 1, bytes(string.concat('{"kind":"cvm-image","measurement":"', CVM_IMAGE_MEASUREMENT, '"}'))
        );
        ops.setAllowlistEntry(CVM_IMAGE_KEY, 1);
    }

    // --- JobRegistry parameters -------------------------------------------------------------

    function test_setFeesApplies() public {
        ops.setFees(250, 7);
        assertEq(jr.feeBps(), 250);
        assertEq(jr.gasFee(), 7);
    }

    function test_setFeesRefusesAboveTheCeilingBeforeSending() public {
        vm.expectRevert(bytes(unicode"setFees: feeBps above the 10% ceiling — JobRegistry reverts FeeTooHigh"));
        ops.setFees(1001, 0);
        assertEq(jr.feeBps(), 100, "nothing may have been sent");
    }

    /// @dev The `1000` in the guard is a literal mirroring `JobRegistry.setFees`'s own bound, and a
    /// VALUE is not a signature — `abi.encodeCall` would not notice the contract moving it. This
    /// asserts what the CHAIN does either side of the guard, so a changed ceiling fails here.
    function test_theRefusedFeeCeilingIsExactlyWhatTheChainRejects() public {
        vm.expectRevert(JobRegistry.FeeTooHigh.selector);
        vm.prank(curation);
        jr.setFees(1001, 0);
        vm.prank(curation);
        jr.setFees(1000, 0);
        assertEq(jr.feeBps(), 1000, "the chain accepts 1000 itself");

        vm.expectRevert(bytes(unicode"setFees: feeBps above the 10% ceiling — JobRegistry reverts FeeTooHigh"));
        ops.setFees(1001, 0);
        // and the edge itself is accepted - the guard is not off by one
        ops.setFees(1000, 3);
        assertEq(jr.feeBps(), 1000);
        assertEq(jr.gasFee(), 3);
    }

    /// @dev asserts on emitted logs, never on `vm.getNonce(curation)` — see the note above
    /// `test_setListedIsANoOpWhenAlreadySatisfied`. `setFees` emits `FeesChanged` unconditionally
    /// when it executes and every preflight read is `view`.
    function test_setFeesIsANoOpWhenAlreadySatisfied() public {
        ops.setFees(250, 7);
        vm.recordLogs();
        ops.setFees(250, 7);
        assertEq(vm.getRecordedLogs().length, 0, "a no-op must not send a transaction");
        assertEq(jr.feeBps(), 250);
        assertEq(jr.gasFee(), 7);
    }

    /// @dev both halves are compared, so moving either one alone must still send
    function test_setFeesSendsWhenOnlyTheGasFeeMoves() public {
        ops.setFees(250, 7);
        ops.setFees(250, 8);
        assertEq(jr.gasFee(), 8);
    }

    /// @dev the chain accepts a zero treasury and would transfer every fee to it. This refuses
    /// locally, which is real added safety rather than a mirror of a chain check.
    function test_setTreasuryRefusesZero() public {
        vm.expectRevert(
            bytes(unicode"setTreasury: the zero address would burn every fee — the chain does not check this")
        );
        ops.setTreasury(address(0));
        assertEq(jr.treasury(), treasury, "nothing may have been sent");

        // and the chain itself would have taken it, which is why the guard has to exist here
        vm.prank(curation);
        jr.setTreasury(address(0));
        assertEq(jr.treasury(), address(0), "JobRegistry.setTreasury has no zero check");
    }

    function test_setTreasuryApplies() public {
        address next = makeAddr("next-treasury");
        ops.setTreasury(next);
        assertEq(jr.treasury(), next);
    }

    /// @dev asserts on emitted logs — `setTreasury` emits `TreasuryChanged` when it executes.
    function test_setTreasuryIsANoOpWhenAlreadySatisfied() public {
        vm.recordLogs();
        ops.setTreasury(treasury); // the fixture already deployed with this treasury
        assertEq(vm.getRecordedLogs().length, 0, "a no-op must not send a transaction");
        assertEq(jr.treasury(), treasury);
    }

    /// @dev 900, deliberately not 3600: the constructor seeds `allowedSla[3600]` and
    /// `allowedSla[86400]`, so a test written against either takes the no-op branch on the FIRST
    /// call and its `assertTrue` passes without the apply path ever running.
    function test_setSlaAllowedApplies() public {
        assertFalse(jr.allowedSla(900), "900 must not be seeded, or this test never applies anything");
        ops.setSlaAllowed(900, true);
        assertTrue(jr.allowedSla(900));

        vm.recordLogs();
        ops.setSlaAllowed(900, true);
        assertEq(vm.getRecordedLogs().length, 0, "a no-op must not send a transaction");
        assertTrue(jr.allowedSla(900));
    }

    function test_setSlaAllowedRemoves() public {
        assertTrue(jr.allowedSla(3600), "the constructor seeds this one");
        ops.setSlaAllowed(3600, false);
        assertFalse(jr.allowedSla(3600));
    }

    function test_setJobRegistryAuthorises() public {
        address other = makeAddr("other-registry");
        assertFalse(reg.isJobRegistry(other));
        ops.setJobRegistry(other, true);
        assertTrue(reg.isJobRegistry(other));
    }

    function test_setJobRegistryRefusesTheZeroAddress() public {
        vm.expectRevert(
            bytes(unicode"setJobRegistry: the zero address — pass the jobRegistry address from the address book")
        );
        ops.setJobRegistry(address(0), true);
    }

    /// @dev asserts on emitted logs — `setJobRegistry` emits `JobRegistryAuthorized` when it
    /// executes. The fixture already authorised `jr`, so this is the no-op path.
    function test_setJobRegistryIsANoOpWhenAlreadySatisfied() public {
        vm.recordLogs();
        ops.setJobRegistry(address(jr), true);
        assertEq(vm.getRecordedLogs().length, 0, "a no-op must not send a transaction");
        assertTrue(reg.isJobRegistry(address(jr)));
    }

    /// @dev revocation is the dangerous direction and must not be reachable without the ack. The
    /// harness defaults `ack` to false and NO test calls `vm.setEnv` — see `CurationHarness`.
    function test_revokingRequiresAnExplicitAcknowledgement() public {
        vm.expectRevert(
            bytes(
                "setJobRegistry: revoking strands escrow for every claimed job. Re-run with "
                "VORQ_OPS_ACK_STRANDING=1 once you have read the count above."
            )
        );
        ops.setJobRegistry(address(jr), false);
        assertTrue(reg.isJobRegistry(address(jr)), "nothing may have been sent");
    }

    /**
     * @dev The production acknowledgement reader, run WITHOUT the harness override — see
     * `AckProbe`. This is the only test that reaches
     * `vm.envOr("VORQ_OPS_ACK_STRANDING", uint256(0)) == 1`, and it asserts the fail-closed
     * direction: with the variable absent the gate must refuse. A body mutated to `return true`
     * fails here and nowhere else.
     *
     * This test is NOT hermetic, deliberately. It reads the real process environment, so it fails
     * for a developer who happens to export `VORQ_OPS_ACK_STRANDING=1` — which is the correct
     * outcome (that shell would sail through the gate on a real revocation) provided the message
     * sends the reader to their shell rather than to this file.
     */
    function test_theProductionAcknowledgementReaderFailsClosedWhenTheVariableIsAbsent() public {
        AckProbe probe = new AckProbe();
        assertFalse(
            probe.ackStrandingFromEnv(),
            "the production acknowledgement reader answered TRUE with no acknowledgement asked for. "
            "Check the shell first: VORQ_OPS_ACK_STRANDING exported here would pass the stranding "
            "gate on a real revocation. Otherwise _ackStranding has stopped reading it."
        );
    }

    function test_revokingProceedsWithTheAcknowledgement() public {
        ops.ackStranding(true);
        ops.setJobRegistry(address(jr), false);
        assertFalse(reg.isJobRegistry(address(jr)));
    }

    /// @dev the acknowledgement gates the REVOKING direction only — authorising is safe and must
    /// not be made to demand it.
    function test_theAcknowledgementIsNotDemandedWhenAuthorising() public {
        ops.setJobRegistry(makeAddr("other-registry"), true);
        assertTrue(reg.isJobRegistry(makeAddr("other-registry")));
    }

    /**
     * @dev `JobRegistry.jobs` is internal with no enumeration, but `activeJobs` is a public mapping
     * per provider and `nextProviderId` bounds the loop — so the total is exact across every
     * provider rather than a sample of the first. A loop that stopped at provider 1 would answer 2
     * instead of 7, and one that summed the wrong counter would answer 0.
     *
     * The counters are written into JobRegistry's OWN storage rather than mocked. The only thing
     * that moves a real one is `claim`, i.e. the full USDC escrow path this fixture deliberately
     * does not wire, so something has to stand in for it — but a `vm.mockCall` would have to name
     * the getter, and `activeJobs` is a public state variable, which the compiler does not expose
     * as a member of `type(JobRegistry)` for `abi.encodeCall`. The only encoding left there is the
     * hand-written `"activeJobs(uint32)"` string this repo forbids precisely because it drifts in
     * silence. `stdstore` takes `jr.activeJobs.selector` off the instance — the compiler checks
     * that against `src/` — locates the slot itself rather than hardcoding one, and the reads below
     * then go through the genuine getter against genuine storage.
     */
    function test_theStrandingCountSumsEveryProvider() public {
        assertEq(ops.claimedJobs(), 0, "no providers registered: nothing to count");

        uint32 a = _register();
        address operatorB = makeAddr("operator-b");
        ops.register(operatorB, 16, true, 1000);
        uint32 b = reg.idOf(operatorB);
        assertEq(reg.nextProviderId(), b + 1, "the loop bound is one past the last issued id");
        assertEq(ops.claimedJobs(), 0, "registered but idle providers hold no claimed job");

        stdstore.target(address(jr)).sig(jr.activeJobs.selector).with_key(uint256(a)).checked_write(uint256(2));
        stdstore.target(address(jr)).sig(jr.activeJobs.selector).with_key(uint256(b)).checked_write(uint256(5));
        assertEq(jr.activeJobs(a), 2, "real storage, read back through the real getter");
        assertEq(jr.activeJobs(b), 5, "real storage, read back through the real getter");

        assertEq(ops.claimedJobs(), 7, "the count must sum EVERY provider, not just the first");
    }

    /// @dev a second registry on the SAME ProviderRegistry: the shape of a cutover, where the book
    /// has already moved on and the address being revoked is the OLD one.
    function _secondRegistry() internal returns (JobRegistry other) {
        other = new JobRegistry(reg, IUSDC(usdc), curation, treasury);
        vm.prank(curation);
        reg.setJobRegistry(address(other), true);
    }

    /**
     * @dev Regression, and the one the review caught. `setJobRegistry` takes an ARBITRARY address,
     * but the count was read from the address book's `jr`. The realistic revocation is retiring an
     * old registry after the book has moved to its replacement — precisely when the two differ —
     * so the warning could print the NEW registry's jobs (usually zero) while the OLD one held the
     * escrow the call was about to strand. The gate still fired, so it could never produce an
     * unacknowledged revocation; it understated the magnitude on the one screen the operator reads
     * before signing, which is the entire purpose of the warning.
     */
    function test_theStrandingCountIsReadFromTheRegistryBeingRevokedNotTheBooks() public {
        uint32 id = _register();
        JobRegistry other = _secondRegistry();

        // deliberately different numbers: reading the wrong registry cannot coincide with the right one
        stdstore.target(address(jr)).sig(jr.activeJobs.selector).with_key(uint256(id)).checked_write(uint256(4));
        stdstore.target(address(other)).sig(other.activeJobs.selector).with_key(uint256(id)).checked_write(uint256(9));

        (uint256 total, bool readable) = ops.claimedJobsOn(address(other));
        assertTrue(readable);
        assertEq(total, 9, "the count must come from the registry named in the argument");
        assertEq(ops.claimedJobs(), 4, "and the book's registry is a different number entirely");

        // and the OP reads that registry, not the book's: a count taken from `jr` would never
        // touch `other.activeJobs` at all
        ops.ackStranding(true);
        vm.expectCall(address(other), abi.encodeWithSelector(other.activeJobs.selector, id));
        ops.setJobRegistry(address(other), false);
        assertFalse(reg.isJobRegistry(address(other)));
    }

    /**
     * @dev `readable` false is not zero. An address the script cannot vouch for yields no number at
     * all, and the op says so rather than printing a figure from somewhere else — on this op the
     * difference between "nothing is at risk" and "how much is at risk is unknown" is the whole
     * decision. The acknowledgement is still demanded, so an unknown count is never a way past it.
     */
    function test_theStrandingCountRefusesToGuessForAnAddressItCannotVouchFor() public {
        (uint256 total, bool readable) = ops.claimedJobsOn(makeAddr("no-code-here"));
        assertFalse(readable, "an address with no code yields no count");
        assertEq(total, 0);

        // a real JobRegistry bound to a DIFFERENT ProviderRegistry: its activeJobs are indexed by
        // provider ids from another id space, so summing them under this loop bound is meaningless
        ProviderRegistry otherReg = new ProviderRegistry(curation);
        JobRegistry foreign = new JobRegistry(otherReg, IUSDC(usdc), curation, treasury);
        (total, readable) = ops.claimedJobsOn(address(foreign));
        assertFalse(readable, "a registry indexing another ProviderRegistry's ids cannot be summed here");

        vm.prank(curation);
        reg.setJobRegistry(address(foreign), true);
        vm.expectRevert(
            bytes(
                "setJobRegistry: revoking strands escrow for every claimed job. Re-run with "
                "VORQ_OPS_ACK_STRANDING=1 once you have read the count above."
            )
        );
        ops.setJobRegistry(address(foreign), false);
        assertTrue(reg.isJobRegistry(address(foreign)), "nothing may have been sent");
    }

    /**
     * @dev Regression. `try/catch` catches a reverting callee, NOT a failure to decode the return
     * data of a call that succeeded — so every shape below used to abort `setJobRegistry` with a
     * bare `EvmError: Revert` before the UNKNOWN line could print, making the address impossible to
     * revoke through this op at all. It failed closed (nothing broadcast), but the realistic reason
     * to revoke a non-registry address is undoing a MIS-AUTHORISATION, and a mis-authorised address
     * is a live hole on `reg` — anything authorised may call `applyReputationDelta` freely. The op
     * that repairs the mistake must not be the one that cannot run.
     *
     * TWO shapes reach the LOOP's own `ok` test: `VouchedShortActiveJobs` (answers short) and
     * `VouchedReturndataBomb` (answers oversized). Either kills that mutant alone, so neither is
     * load-bearing on its own — do not read this as a uniqueness claim, and do not prune one on
     * the assumption the other is the redundant copy. The four unvouched shapes stop at the
     * `registry()` probe and `OverflowingCounter` answers a full clean word, so without a vouched
     * misbehaving shape the loop's `if (!ok) return (0, false)` is unexercised — and deleting that
     * guard does not abort, it makes `_read32`'s zeroed `word` sum into a `readable == true` count
     * of 0. A fabricated zero on the one op where zero means "nothing is at risk" is worse than
     * the abort this test was written for, so both shapes are carried in the same array rather
     * than in tests of their own: every assertion the other five get applies to them unchanged.
     */
    function test_theCountRefusesEveryUndecodableShapeInsteadOfAborting() public {
        // `OverflowingCounter` vouches, so its bad read is only reached once the loop has a
        // provider to iterate — with an empty registry it would answer a truthful, useless zero
        _register();
        address[7] memory shapes = [
            address(new EmptyReturnFallback()), // succeeds with ZERO bytes - the likeliest shape
            address(new DirtyWordFallback()), // 32 bytes, high bits dirty: not an address
            address(new ShortReturnFallback()), // 16 bytes: too short to decode at all
            address(new DirtyHighBitsRegistry(address(reg))), // dirty bits over the REAL registry
            address(new OverflowingCounter(reg)), // vouches, then overflows uint32 inside the loop
            address(new VouchedShortActiveJobs(reg)), // vouches, then answers SHORT inside the loop
            address(new VouchedReturndataBomb(reg)) // vouches, then answers 1 MiB inside the loop
        ];

        for (uint256 i; i < shapes.length; i++) {
            (uint256 total, bool readable) = ops.claimedJobsOn(shapes[i]);
            assertFalse(readable, "every undecodable shape must answer 'unknown', never abort");
            assertEq(total, 0);
        }
    }

    /// @dev the end-to-end half of the regression: the op must reach its gate, and then complete,
    /// for an address whose reads cannot be decoded. `OverflowingCounter` and
    /// `VouchedShortActiveJobs` both vouch, so they need a registered provider for the loop to
    /// reach their `activeJobs` at all.
    function test_aMisAuthorisedAddressCanStillBeRevoked() public {
        _register();
        address[7] memory shapes = [
            address(new EmptyReturnFallback()),
            address(new DirtyWordFallback()),
            address(new ShortReturnFallback()),
            address(new DirtyHighBitsRegistry(address(reg))),
            address(new OverflowingCounter(reg)),
            address(new VouchedShortActiveJobs(reg)),
            address(new VouchedReturndataBomb(reg))
        ];

        for (uint256 i; i < shapes.length; i++) {
            vm.prank(curation);
            reg.setJobRegistry(shapes[i], true); // the mis-authorisation being undone
            assertTrue(reg.isJobRegistry(shapes[i]));

            // the gate still fires rather than the op exploding before it
            vm.expectRevert(
                bytes(
                    "setJobRegistry: revoking strands escrow for every claimed job. Re-run with "
                    "VORQ_OPS_ACK_STRANDING=1 once you have read the count above."
                )
            );
            ops.setJobRegistry(shapes[i], false);

            ops.ackStranding(true);
            ops.setJobRegistry(shapes[i], false);
            assertFalse(reg.isJobRegistry(shapes[i]), "the mis-authorisation must be revocable");
            ops.ackStranding(false);
        }
    }

    /**
     * @dev The rendering is a function so a test can see it: `console2.log` reaches the console
     * address by staticcall, not by an event, so `vm.recordLogs` cannot observe what the op
     * printed. The unknown line carrying NO DIGIT is the assertion that matters — a `0` rendered
     * there would be read as a count, which is the exact confusion the branch exists to prevent.
     */
    function test_theClaimedCountLineNamesItsSourceAndNeverRendersUnknownAsANumber() public view {
        assertEq(
            ops.claimedLine(address(jr), 7, true),
            string.concat(
                "  claimed jobs across all providers RIGHT NOW, counted on ", vm.toString(address(jr)), ": 7"
            ),
            "the readable line must name the contract the number came from"
        );

        string memory unknown = ops.claimedLine(address(jr), 0, false);
        assertTrue(vm.contains(unknown, "UNKNOWN"), "the unknown line must say so in as many words");
        assertTrue(vm.contains(unknown, "never as zero"), "and must say not to read it as zero");
        bytes memory b = bytes(unknown);
        for (uint256 i; i < b.length; i++) {
            assertFalse(
                b[i] >= 0x30 && b[i] <= 0x39, "the unknown line must contain no digit: one would read as a count"
            );
        }
    }
}
