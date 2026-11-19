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
/// pinned Base Sepolia fork, a client that deposited once into its prepaid balance, one
/// registered+listed provider at full reputation, and modelId 1 in the catalog. Suites inherit it
/// and override `_fees()` only.
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
    /// @dev a fresh EIP-3009 nonce per deposit: the token burns each one per owner
    uint256 internal depositNonce;

    /// @dev the client's wallet before the deposit and the value it deposits once in `setUp`
    uint256 internal constant WALLET = 1e24;
    uint256 internal constant DEPOSIT = 1_000_000e6;
    /// @dev the client's ledger balance right after that deposit, at the suite's own deposit fee
    uint256 internal START;

    /// @dev the terms each job was claimed under, keyed by jobId, so the exits can hand them back
    mapping(bytes32 => Terms) internal termsOf;

    // The reference order's rates live here and nowhere else.
    uint128 internal constant REF_RATE_IN = 30_000;
    uint128 internal constant REF_RATE_OUT = 90_000;
    uint32 internal constant REF_UNITS_IN = 1000;
    uint32 internal constant REF_UNITS_OUT = 2000;
    /// @dev cap = ceil((REF_RATE_IN*REF_UNITS_IN + REF_RATE_OUT*REF_UNITS_OUT) / RATE_SCALE)
    /// = ceil((3e7 + 1.8e8) / 1e6) = 210. A literal, never a number the contract derived, so a wrong
    /// cap in `JobRegistry` cannot hide behind a fixture that agrees with it. `_ref` re-derives it
    /// inline to check the literal is not stale.
    uint256 internal constant REF_CAP = 210;

    /// @notice Per-suite fee configuration. Called near the END of `setUp`, before the client's one
    /// deposit, so the deposit is taken at the suite's own `depositFee`. Override as e.g.
    /// `vm.prank(curation); jr.setFees(500, 7, 0);` — and nothing else.
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
        deal(USDC, client, WALLET);
        _fees();
        _deposit(jr, DEPOSIT);
        START = jr.balanceOf(client);
    }

    /// @notice Operator-signed capacity request, relayed by the test contract.
    function _requestCapacity(uint32 n) internal {
        uint64 t = uint64(block.timestamp) + (++capNonce);
        reg.requestCapacity(n, t, RegSig.signCapacity(vm, opPk, reg, n, t));
    }

    // ── deposits ──────────────────────────────────────────────────────────────────────────────

    /// @notice A client-signed deposit of `value` into `target`, relayed by the test contract.
    function _deposit(JobRegistry target, uint256 value) internal {
        (uint256 validBefore, bytes32 nonce, bytes memory sig) = _depositAuth(target, value);
        target.deposit(client, value, validBefore, nonce, sig);
    }

    /// @notice R1 companion to `_deposit`: pre-sign, because AuthSig staticcalls the token.
    function _depositAuth(JobRegistry target, uint256 value)
        internal
        returns (uint256 validBefore, bytes32 nonce, bytes memory sig)
    {
        validBefore = block.timestamp + 3600;
        nonce = keccak256(abi.encode("deposit", ++depositNonce));
        sig = AuthSig.signDeposit(vm, clientPk, USDC, address(target), value, validBefore, nonce);
    }

    // ── orders ────────────────────────────────────────────────────────────────────────────────

    /// @notice The reference order every suite reproduces: rateIn 30_000, rateOut 90_000,
    /// unitsIn 1000, unitsOut 2000, slaSecs 3600 ⇒ cap = REF_CAP = 210. `c` is derived from
    /// `designated`, so one `designated` value gives one job per suite; `_refC` and `_orderWith`
    /// are the escape hatches for any other order.
    function _ref(uint32 designated) internal view returns (Order memory o) {
        o = _refC(keccak256(abi.encode(designated, "c")));
        o.designated = designated;
    }

    function _refC(bytes32 c) internal view returns (Order memory o) {
        // a rate edit that forgets REF_CAP would otherwise surface far from its cause
        assertEq(
            REF_CAP,
            (uint256(REF_RATE_IN) * REF_UNITS_IN + uint256(REF_RATE_OUT) * REF_UNITS_OUT + 999_999) / 1_000_000,
            "JobHarness: REF_CAP is stale - update it alongside the reference rates"
        );
        o = _orderWith(c, REF_RATE_IN, REF_UNITS_IN, REF_RATE_OUT, REF_UNITS_OUT);
        o.taskCid = bytes("bafy-task");
    }

    /// @notice An undesignated order with caller-chosen rates and units.
    function _orderWith(bytes32 c, uint128 rateIn, uint32 unitsIn, uint128 rateOut, uint32 unitsOut)
        internal
        view
        returns (Order memory)
    {
        return Order({
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
    }

    function _jobId(Order memory o) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(client, o.c));
    }

    /// @notice The terms a claim of `o` by `client`, relayed by the test contract, would fix on
    /// `target` right now.
    function _termsFor(JobRegistry target, Order memory o) internal view returns (Terms memory) {
        return _termsVia(target, o, address(this));
    }

    /// @notice `_termsFor` for a claim landed by `relayer`.
    function _termsVia(JobRegistry target, Order memory o, address relayer) internal view returns (Terms memory) {
        return Terms({
            owner: client,
            rateIn: o.rateIn,
            rateOut: o.rateOut,
            unitsIn: o.unitsIn,
            unitsOut: o.unitsOut,
            slaSecs: o.slaSecs,
            gasFee: target.gasFee(),
            relayer: relayer
        });
    }

    /// @notice What claiming `o` locks out of the balance at the fees live now, spelled out locally.
    function _lockOf(Order memory o) internal view returns (uint256) {
        uint256 raw = uint256(o.rateIn) * o.unitsIn + uint256(o.rateOut) * o.unitsOut;
        uint256 cap = (raw + 999_999) / 1_000_000;
        if (cap == 0) cap = 1;
        return cap + cap * uint256(jr.feeBps()) / 10000 + uint256(jr.gasFee());
    }

    // ── claim ─────────────────────────────────────────────────────────────────────────────────

    /// @notice The client-signed order claimed by the operator at the current block time, submitted
    /// by the TEST contract — never the operator key. `claim` authorises nothing by `msg.sender`; it
    /// records the sender in the terms as the relayer that earns the gas fee.
    function _claim(Order memory o) internal returns (bytes32 jobId) {
        return _claimOn(jr, o);
    }

    function _claimOn(JobRegistry target, Order memory o) internal returns (bytes32 jobId) {
        return _claimVia(target, o, address(this));
    }

    /// @notice `_claimOn` landed by `relayer`, recording the terms with that relayer in them.
    function _claimVia(JobRegistry target, Order memory o, address relayer) internal returns (bytes32 jobId) {
        jobId = _jobId(o);
        uint64 t = uint64(block.timestamp);
        Terms memory terms = _termsVia(target, o, relayer);
        bytes memory orderSig = OrderSig.signOrder(vm, clientPk, target, o);
        bytes memory sig = OpSig.signClaim(vm, opPk, target, jobId, t);
        vm.prank(relayer);
        target.claim(o, client, orderSig, t, sig);
        termsOf[jobId] = terms;
    }

    /// @notice R1 companion to `_claim`: a negative test must pre-sign, because the signing helpers'
    /// staticcalls would eat an armed `expectRevert`.
    /// Use as: `(bytes memory os, bytes memory cs) = _claimSigs(o); vm.expectRevert(...);
    /// jr.claim(o, client, os, t, cs);`
    function _claimSigs(Order memory o) internal view returns (bytes memory orderSig, bytes memory claimSig) {
        orderSig = OrderSig.signOrder(vm, clientPk, jr, o);
        claimSig = OpSig.signClaim(vm, opPk, jr, _jobId(o), uint64(block.timestamp));
    }

    // ── exits ─────────────────────────────────────────────────────────────────────────────────

    /// @notice Operator-signed settle at the current block time, submitted by the TEST contract.
    /// `pk` is a parameter because a rotated operator signs with a different key for the same id.
    /// `resultCid` is submitted, but it is NOT part of what `pk` signs.
    function _settle(uint256 pk, bytes32 jobId, uint32 completionTok, bytes memory resultCid) internal {
        _settleUsage(pk, jobId, OpSig.usage(completionTok), resultCid);
    }

    /// @notice `_settle` with the backend's full usage.
    function _settleUsage(uint256 pk, bytes32 jobId, Usage memory u, bytes memory resultCid) internal {
        uint64 t = uint64(block.timestamp);
        bytes memory sig = OpSig.signSettle(vm, pk, jr, jobId, u, t);
        jr.submitAndSettle(jobId, termsOf[jobId], u, resultCid, t, sig);
    }

    /// @notice R1 companion to `_settle`: pre-sign on the line BEFORE `vm.expectRevert`.
    function _settleSig(uint256 pk, bytes32 jobId, uint32 completionTok) internal view returns (bytes memory) {
        return OpSig.signSettle(vm, pk, jr, jobId, OpSig.usage(completionTok), uint64(block.timestamp));
    }

    /// @notice Operator-signed provider abort at the current block time, submitted by the TEST
    /// contract. `issuedAt` is the CURRENT time, so this never lands a pre-signed voucher.
    function _fail(uint256 pk, bytes32 jobId) internal {
        uint64 t = uint64(block.timestamp);
        jr.fail(jobId, termsOf[jobId], t, OpSig.signFail(vm, pk, jr, jobId, t));
    }

    /// @notice R1 companion to `_fail`.
    function _failSig(uint256 pk, bytes32 jobId) internal view returns (bytes memory) {
        return OpSig.signFail(vm, pk, jr, jobId, uint64(block.timestamp));
    }

    function _reclaim(bytes32 jobId) internal {
        jr.reclaim(jobId, termsOf[jobId]);
    }

    /// @notice Owner-signed cancel of `client`'s order `c` at the current block time, signed with
    /// `pk` (a negative test signs with a stranger's key) and submitted by the TEST contract.
    function _cancelAs(uint256 pk, bytes32 c) internal {
        uint64 t = uint64(block.timestamp);
        jr.cancel(client, c, t, OpSig.signCancel(vm, pk, jr, keccak256(abi.encodePacked(client, c)), t));
    }

    /// @notice R1 companion to `_cancelAs`.
    function _cancelSig(uint256 pk, bytes32 c) internal view returns (bytes memory) {
        return OpSig.signCancel(vm, pk, jr, keccak256(abi.encodePacked(client, c)), uint64(block.timestamp));
    }
}
