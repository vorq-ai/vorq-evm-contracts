// SPDX-License-Identifier: FSL-1.1-ALv2
pragma solidity 0.8.30;

import {BaseFork, IFiatToken} from "./BaseFork.sol";
import {JobRegistry, IUSDC} from "../../src/JobRegistry.sol";
import {ProviderRegistry} from "../../src/ProviderRegistry.sol";
import "../../src/Types.sol";
import {OrderSig} from "./OrderSig.sol";
import {AuthSig} from "./AuthSig.sol";
import {OpSig} from "./OpSig.sol";
import {RegSig} from "./RegSig.sol";

/// @notice The one funded end-to-end fixture for every job-lifecycle suite: the real USDC on a
/// pinned Base Sepolia fork, a client holding a balance and nothing else, one registered+listed
/// provider at full reputation, and modelId 1 in the catalog. Suites inherit it and override
/// `_fees()` only.
abstract contract JobHarness is BaseFork {
    JobRegistry internal jr;
    ProviderRegistry internal reg;
    IFiatToken internal usdc = IFiatToken(USDC);

    address internal curation = makeAddr("curation");
    address internal treasury = makeAddr("treasury");
    uint256 internal clientPk = 0xC11E47;
    address internal client;
    address internal op;
    uint256 internal opPk;
    uint32 internal pid;

    /// @dev strictly-monotonic issuedAt for the registry's capacity op floor
    uint64 internal capNonce;

    // The reference order's rates live here and nowhere else, so `postJob`'s order and the
    // authorization amount it signs cannot drift apart.
    uint128 internal constant REF_RATE_IN = 30_000;
    uint128 internal constant REF_RATE_OUT = 90_000;
    uint32 internal constant REF_UNITS_IN = 1000;
    uint32 internal constant REF_UNITS_OUT = 2000;
    /// @dev cap = ceil((REF_RATE_IN*REF_UNITS_IN + REF_RATE_OUT*REF_UNITS_OUT) / RATE_SCALE)
    /// = ceil((3e7 + 1.8e8) / 1e6) = 210. The CAP half of what the authorization signs is this
    /// literal — never `capOf` or any number the contract DERIVED — so a wrong `cap` in `JobRegistry`
    /// cannot hide behind a fixture that agreed with it, and every suite re-asserts
    /// `capOf(jobId) == 210` against it after claiming. The gas-fee addend in `postJob` is the one
    /// part read back off the contract (`jr.gasFee()`), which couples nothing: it is plain curation
    /// config this fixture itself wrote through `_fees()`, not a computed quantity under test.
    /// `postJob` additionally re-derives the ceiling inline to check this literal is not stale; that
    /// arithmetic is spelled out locally rather than delegated to the contract, so it adds no
    /// coupling. It omits `_atomicCharge`'s `max(1, ...)` floor, which cannot bind at these
    /// rates — a `postJobWith` order priced below one atomic unit must pass its own amount.
    uint256 internal constant REF_CAP = 210;

    /// @notice Per-suite fee configuration. Called at the very END of `setUp`, so every
    /// `postJob` after it snapshots the fees this suite wants into `Job.gasFeeSnap`.
    /// Override as e.g. `vm.prank(curation); jr.setFees(500, 7);` — and nothing else: the
    /// registry, the provider and the client's balance are already up.
    function _fees() internal virtual {}

    function setUp() public virtual {
        _fork();
        client = vm.addr(clientPk);
        (op, opPk) = makeAddrAndKey("op");
        reg = new ProviderRegistry(curation);
        jr = new JobRegistry(reg, IUSDC(USDC), curation, treasury);
        vm.startPrank(curation);
        reg.setJobRegistry(address(jr), true);
        reg.registerModel("model-a:fp8"); // modelId 1
        // registered at full reputation: effectiveCap = 1000 * min(16, 16) / 1000 = 16
        pid = reg.register(op, 16, true, 1000);
        vm.stopPrank();
        _requestCapacity(16);
        // no approval and no client transaction at all: the client only ever signs
        deal(USDC, client, 1e24);
        _fees();
    }

    /// @notice Operator-signed capacity request, relayed by the test contract.
    function _requestCapacity(uint32 n) internal {
        uint64 t = uint64(block.timestamp) + (++capNonce);
        reg.requestCapacity(n, t, RegSig.signCapacity(vm, opPk, reg, n, t));
    }

    /// @notice The reference order every later suite reproduces: rateIn 30_000, rateOut 90_000,
    /// unitsIn 1000, unitsOut 2000, slaSecs 3600 ⇒ cap = REF_CAP = 210.
    /// The authorization covers the exact claim-time pull, `cap + cap*feeBps/10000 + gasFeeSnap`, so
    /// it reads `feeBps`/`gasFee` at post time — which is why `_fees()` runs before any `postJob`.
    /// `c` is derived from `designated`, so one `designated` value gives one job per suite;
    /// `postJobWith` is the escape hatch for any other order shape.
    function postJob(uint32 designated) internal returns (bytes32 jobId, Order memory o) {
        // a rate edit that forgets REF_CAP would otherwise surface as an invalid-signature revert
        // from inside `claim`, which reads as a signing bug; fail here instead, and say why. The ceiling
        // is spelled out inline (not read from the contract), so this checks the literal against the
        // rates above and nothing else. No `max(1, ...)` floor: it cannot bind at these rates.
        assertEq(
            REF_CAP,
            (uint256(REF_RATE_IN) * REF_UNITS_IN + uint256(REF_RATE_OUT) * REF_UNITS_OUT + 999_999) / 1_000_000,
            "JobHarness: REF_CAP is stale - update it alongside the reference rates"
        );
        o = Order({
            c: keccak256(abi.encode(designated, "c")),
            modelId: 1,
            slaSecs: 3600,
            rateIn: REF_RATE_IN,
            rateOut: REF_RATE_OUT,
            unitsIn: REF_UNITS_IN,
            unitsOut: REF_UNITS_OUT,
            designated: designated,
            expiresAt: uint64(block.timestamp + 3600),
            taskCid: bytes("bafy-task")
        });
        jobId = keccak256(abi.encodePacked(client, o.c));
        bytes memory authSig = AuthSig.signAuth(
            vm,
            clientPk,
            USDC,
            address(jr),
            REF_CAP + REF_CAP * uint256(jr.feeBps()) / 10000 + uint256(jr.gasFee()),
            jobId,
            o.expiresAt
        );
        jr.post(o, client, OrderSig.signOrder(vm, clientPk, jr, o), authSig);
    }

    /// @notice An undesignated job with caller-chosen rates, units and authorization amount — the
    /// escape hatch for cap arithmetic, dust orders, and any suite needing more than one open job.
    /// `authAmount` stays explicit (never derived) so a suite can deliberately under-sign it:
    /// it must equal `cap + cap*feeBps/10000 + gasFee-at-post` for the claim-time pull to succeed.
    function postJobWith(
        bytes32 c,
        uint128 rateIn,
        uint32 unitsIn,
        uint128 rateOut,
        uint32 unitsOut,
        uint256 authAmount
    ) internal returns (bytes32 jobId) {
        Order memory o = Order({
            c: c,
            modelId: 1,
            slaSecs: 3600,
            rateIn: rateIn,
            rateOut: rateOut,
            unitsIn: unitsIn,
            unitsOut: unitsOut,
            designated: 0,
            expiresAt: uint64(block.timestamp + 3600),
            taskCid: bytes("bafy-raw")
        });
        jobId = keccak256(abi.encodePacked(client, o.c));
        jr.post(
            o,
            client,
            OrderSig.signOrder(vm, clientPk, jr, o),
            AuthSig.signAuth(vm, clientPk, USDC, address(jr), authAmount, jobId, o.expiresAt)
        );
    }

    /// @notice The reference order posted against an ARBITRARY registry/token pair — the fixture for
    /// every test that has to stand up its own `JobRegistry` (a forced zero-signer record, a token
    /// that returns false, a registry whose `jobRegistry` is somebody else). `postJob` cannot serve
    /// those: it is hardwired to the harness's `jr` and `usdc`.
    /// @dev Its own frame because the two signing calls plus the order overflow a test body's stack
    /// (R19). `c` must be fresh across the whole test — the authorization's nonce is the jobId and
    /// the token burns it per owner, not per payee, so two posts sharing a `c` collide even on two
    /// different registries.
    function _postTo(JobRegistry target, address payToken, bytes32 c) internal returns (bytes32 jobId) {
        Order memory o = Order({
            c: c,
            modelId: 1,
            slaSecs: 3600,
            rateIn: REF_RATE_IN,
            rateOut: REF_RATE_OUT,
            unitsIn: REF_UNITS_IN,
            unitsOut: REF_UNITS_OUT,
            designated: 0,
            expiresAt: uint64(block.timestamp + 3600),
            taskCid: bytes("bafy-alt")
        });
        jobId = keccak256(abi.encodePacked(client, o.c));
        target.post(
            o, client, OrderSig.signOrder(vm, clientPk, target, o), _authFor(target, payToken, jobId, o.expiresAt)
        );
    }

    /// @dev `signAuth` is an internal library call, so its arguments land on the caller's stack; a
    /// frame of its own is what keeps `_postTo` compiling (R19). The amount is
    /// `REF_CAP + its fee ceiling + target.gasFee()`, read off the TARGET rather than off `jr`,
    /// because every caller configures its own instance's fees inline and `_fees()` (which
    /// configures `jr`) never reaches them. Where the authorization is actually SPENT — the settle,
    /// fail, exit and invariant suites all claim through it — a stale literal would surface as an
    /// invalid-signature revert from inside `claim`; where it is not (the claim suite's caller
    /// expects `claim` to revert before the token is touched) reading the target is what keeps the
    /// fixture honest if that test ever starts claiming for real.
    /// `payToken` is the token whose domain signs. `FalseTransferToken` has none and validates
    /// nothing, so it is handed bytes it will never read.
    function _authFor(JobRegistry target, address payToken, bytes32 jobId, uint64 deadline)
        internal
        view
        returns (bytes memory)
    {
        if (payToken != USDC) return hex"";
        return AuthSig.signAuth(
            vm,
            clientPk,
            payToken,
            address(target),
            REF_CAP + REF_CAP * uint256(target.feeBps()) / 10000 + uint256(target.gasFee()),
            jobId,
            deadline
        );
    }

    /// @notice Operator-signed claim at the current block time, submitted by the TEST contract —
    /// never the operator key. `claim` reads no `msg.sender`; the signature is the whole authority.
    function _claim(bytes32 jobId) internal {
        uint64 t = uint64(block.timestamp);
        jr.claim(jobId, t, OpSig.signClaim(vm, opPk, jr, jobId, t));
    }

    /// @notice R1 companion to `_claim`: a negative test must pre-sign, because OpSig's
    /// `DOMAIN_SEPARATOR()`/`CLAIM_TYPEHASH()` staticcalls would eat an armed `expectRevert`.
    /// Use as: `bytes memory sig = _claimSig(id); vm.expectRevert(...); jr.claim(id, t, sig);`
    /// Tasks adding `_settle`/`_fail` should ship the same `_xSig`/`_x` pair.
    function _claimSig(bytes32 jobId) internal view returns (bytes memory) {
        return OpSig.signClaim(vm, opPk, jr, jobId, uint64(block.timestamp));
    }

    /// @notice Operator-signed settle at the current block time, submitted by the TEST contract —
    /// which is therefore a gas-only relayer and must be paid nothing. `pk` is a parameter, not
    /// `opPk`, because a rotated operator signs with a different key for the same provider id.
    /// `resultCid` is still a submission argument — it is stored, emitted and required non-empty —
    /// but it is NOT part of what `pk` signs, so this helper passes it only to `submitAndSettle`.
    function _settle(uint256 pk, bytes32 jobId, uint32 completionTok, bytes memory resultCid) internal {
        uint64 t = uint64(block.timestamp);
        bytes memory sig = OpSig.signSettle(vm, pk, jr, jobId, completionTok, t);
        jr.submitAndSettle(jobId, completionTok, resultCid, t, sig);
    }

    /// @notice R1 companion to `_settle`, same contract as `_claimSig`: pre-sign on the line
    /// BEFORE `vm.expectRevert`, or OpSig's staticcalls eat the armed cheatcode.
    /// Takes no `resultCid` — the Settle struct has none, so the signature a negative test pre-signs
    /// is valid for whatever CID the call then submits.
    function _settleSig(uint256 pk, bytes32 jobId, uint32 completionTok) internal view returns (bytes memory) {
        return OpSig.signSettle(vm, pk, jr, jobId, completionTok, uint64(block.timestamp));
    }

    /// @notice Operator-signed provider abort at the current block time, submitted by the TEST
    /// contract — a gas-only relayer that must be paid nothing. `pk` is a parameter for the same
    /// reason `_settle` takes one: the claimant's key is not the only one a negative test signs
    /// with. `issuedAt` is the CURRENT time, so this helper never lands a pre-signed voucher — the
    /// grace window prices at landing, and a test pinning that must sign explicitly via `OpSig`.
    function _fail(uint256 pk, bytes32 jobId) internal {
        uint64 t = uint64(block.timestamp);
        jr.fail(jobId, t, OpSig.signFail(vm, pk, jr, jobId, t));
    }

    /// @notice R1 companion to `_fail`, same contract as `_claimSig`/`_settleSig`: pre-sign on the
    /// line BEFORE `vm.expectRevert`, or OpSig's staticcalls eat the armed cheatcode.
    function _failSig(uint256 pk, bytes32 jobId) internal view returns (bytes memory) {
        return OpSig.signFail(vm, pk, jr, jobId, uint64(block.timestamp));
    }

    /// @notice Owner-signed cancel at the current block time, submitted by the TEST contract. `pk`
    /// is a parameter because `cancel` is the one op the CLIENT signs (`clientPk`), and a negative
    /// test signs with a stranger's key for the same job. There is no `cancelFor` and no
    /// `msg.sender` path: an owner submitting its own cancel is just relaying its own signature.
    function _cancelAs(uint256 pk, bytes32 jobId) internal {
        uint64 t = uint64(block.timestamp);
        jr.cancel(jobId, t, OpSig.signCancel(vm, pk, jr, jobId, t));
    }

    /// @notice R1 companion to `_cancelAs`, same contract as the other `_xSig` helpers: pre-sign on
    /// the line BEFORE `vm.expectRevert`, or OpSig's staticcalls eat the armed cheatcode.
    function _cancelSig(uint256 pk, bytes32 jobId) internal view returns (bytes memory) {
        return OpSig.signCancel(vm, pk, jr, jobId, uint64(block.timestamp));
    }
}
