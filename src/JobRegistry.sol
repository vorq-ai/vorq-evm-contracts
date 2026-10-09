// SPDX-License-Identifier: FSL-1.1-ALv2
pragma solidity 0.8.30;

import "./Types.sol";
import {ProviderRegistry} from "./ProviderRegistry.sol";

// the two legs this contract uses. The pull is EIP-3009: the client signs an authorization that
// only this contract can execute, so neither `approve` nor `transferFrom` ever appears here.
interface IUSDC {
    function transfer(address to, uint256 amount) external returns (bool);

    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes memory signature
    ) external;
}

contract JobRegistry {
    error EmptyTaskCid();
    error SlaNotAllowed();
    error AlreadyExpired();
    error ExpiryTooFar();
    error UnknownModel();
    error ModelDisabled();
    error InvalidOrderSignature();
    error DuplicateJob();
    error UnknownJob();
    error NotOpen();
    error StaleOp();
    error UnknownProvider();
    error NotListed();
    error ModelNotAllowed();
    error NotDesignated();
    error AtCapacity();
    error CapOverflow();
    error NotTheClaimant();
    error NotClaimed();
    error SlaExpired();
    error EmptyResultCid();
    error TransferFailed();
    error SlaNotExpired();
    error NotTheOwner();
    error NotCancellable();
    error NotCuration();
    error FeeTooHigh();
    error LengthMismatch();

    /// A `postMany` line that `post` refused. `reason` is the raw revert data — a custom-error
    /// selector — so the caller learns which gate rejected the line, not merely that one did.
    event PostSkipped(uint256 indexed index, bytes reason);

    event Posted(
        bytes32 indexed jobId,
        uint32 indexed modelId,
        uint32 indexed designated,
        address owner,
        bytes32 c,
        uint64 expiresAt,
        uint32 slaSecs,
        uint128 rateIn,
        uint128 rateOut,
        uint32 unitsIn,
        uint32 unitsOut,
        uint128 gasFee,
        bytes taskCid
    );
    event Claimed(bytes32 indexed jobId, uint32 indexed provider, uint64 claimedAt);
    event Settled(bytes32 indexed jobId, uint32 completionTok, uint128 fee, bytes resultCid);
    event Ended(bytes32 indexed jobId, uint8 cause); // 2 cancelled | 3 provider_fail | 4 reclaim only
    event FeesChanged(uint16 feeBps, uint128 gasFee);
    event SlaAllowedChanged(uint32 secs, bool allowed);
    event TreasuryChanged(address treasury);

    uint64 public constant MAX_EXPIRY = 86400;
    uint64 public constant FAIL_GRACE = 300;
    uint256 public constant RATE_SCALE = 1_000_000;
    // taskCid is NOT signed: only the coordinator pins, and the storage service mints the name, so
    // the client cannot know the CID at the moment it signs. `c` — the container commitment,
    // keccak(version ‖ seed_wrap ‖ keccak(ciphertext)) — is what binds the payload, and the provider
    // rebuilds it from the fetched container and requires keccak(owner ‖ c) == jobId; the CID is a
    // fetch hint the relayer fills in, recorded on the row and in the log but never attested.
    bytes32 public constant ORDER_TYPEHASH = keccak256(
        "Order(bytes32 c,uint32 modelId,uint32 slaSecs,uint128 rateIn,uint128 rateOut,uint32 unitsIn,uint32 unitsOut,uint32 designated,uint64 expiresAt)"
    );
    // the four job ops all land in this contract's domain; declared here so every signer —
    // contract, test helper, and off-chain client — reads one authority for the type strings
    bytes32 public constant CLAIM_TYPEHASH = keccak256("Claim(bytes32 jobId,uint64 issuedAt)");
    // resultCid is NOT signed, for the same reason taskCid is not: the provider hands the result to
    // the coordinator, which pins it and learns the name from the storage service. Unlike the order
    // path there is no commitment standing behind it — the settle path has no `c` — which is an
    // accepted consequence: the CID is recorded, never attested.
    bytes32 public constant SETTLE_TYPEHASH = keccak256("Settle(bytes32 jobId,uint32 completionTok,uint64 issuedAt)");
    bytes32 public constant FAIL_TYPEHASH = keccak256("Fail(bytes32 jobId,uint64 issuedAt)");
    bytes32 public constant CANCEL_TYPEHASH = keccak256("Cancel(bytes32 jobId,uint64 issuedAt)");

    struct Job {
        address owner;
        uint32 modelId;
        uint32 slaSecs;
        uint32 designated; // immutable after post — claim sets providerId and never touches this
        bytes32 c;
        uint128 rateIn;
        uint128 rateOut;
        uint32 unitsIn;
        uint32 unitsOut;
        uint32 completionTok;
        uint32 providerId;
        uint64 expiresAt;
        uint64 claimedAt;
        uint8 state;
        uint8 endedBecause;
        uint128 cap;
        uint128 gasFeeSnap; // gasFee as of post — the escrow amount cannot move under the client
        bytes taskCid;
        bytes resultCid;
        bytes authSig; // parked at post, consumed and deleted by claim
    }

    ProviderRegistry public immutable registry;
    IUSDC public immutable usdc;
    address public immutable curation;
    address public treasury;
    uint16 public feeBps;
    uint128 public gasFee;
    mapping(uint32 => bool) public allowedSla;
    mapping(bytes32 => Job) internal jobs;
    mapping(uint32 => uint32) public activeJobs;
    bytes32 public immutable DOMAIN_SEPARATOR; // this contract's own domain
    /// @dev A DISTINCT EIP-712 domain name per contract, deliberately.
    ///
    /// All three registries previously answered to `"VORQ"` and differed only in
    /// `verifyingContract`. That is legal, and it makes one real failure mode invisible: a
    /// deployment whose configuration resolves two address slots to the same contract produces
    /// digests indistinguishable from legitimate ones, and a wrong `verifyingContract` never
    /// errors - it recovers a stranger. Distinct names make the separators differ regardless of
    /// what the addresses are, and let a wallet show which contract is being authorised.
    string public constant EIP712_NAME = "VORQ Jobs";
    string public constant EIP712_VERSION = "2";

    modifier onlyCuration() {
        if (msg.sender != curation) revert NotCuration();
        _;
    }

    constructor(ProviderRegistry registry_, IUSDC usdc_, address curation_, address treasury_) {
        registry = registry_;
        usdc = usdc_;
        curation = curation_;
        treasury = treasury_;
        allowedSla[3600] = true;
        allowedSla[86400] = true;
        feeBps = 100; // 1%, the protocol's fee; `setFees` moves it
        // $0.03 in USDC's 6 decimals: the relayer's post + claim + settle gas on Base mainnet
        // (~700k gas, ~$0.02-0.03 at 0.010-0.015 gwei and ETH $2,736 on 2026-09-30); `setFees` moves it
        gasFee = 30_000;
        // the seeded config is emitted too: the log alone is a complete history, which keeps a
        // future log-projection option open without a redeploy
        emit SlaAllowedChanged(3600, true);
        emit SlaAllowedChanged(86400, true);
        emit FeesChanged(100, 30_000);
        emit TreasuryChanged(treasury_);
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

    function setFees(uint16 feeBps_, uint128 gasFee_) external onlyCuration {
        if (feeBps_ > 1000) revert FeeTooHigh(); // 10% hard ceiling on the protocol fee
        feeBps = feeBps_;
        gasFee = gasFee_;
        emit FeesChanged(feeBps_, gasFee_);
    }

    function setSlaAllowed(uint32 secs, bool ok) external onlyCuration {
        allowedSla[secs] = ok;
        emit SlaAllowedChanged(secs, ok);
    }

    function setTreasury(address treasury_) external onlyCuration {
        treasury = treasury_;
        emit TreasuryChanged(treasury_);
    }

    function post(Order calldata order, address owner, bytes calldata orderSig, bytes calldata authSig) external {
        if (order.taskCid.length == 0) revert EmptyTaskCid();
        if (!allowedSla[order.slaSecs]) revert SlaNotAllowed();
        // block.timestamp is the intended reference for both bounds: MAX_EXPIRY bounds how long
        // escrow can be committed, and an order that expires now can never be claimed
        if (order.expiresAt <= block.timestamp) revert AlreadyExpired();
        if (order.expiresAt > block.timestamp + MAX_EXPIRY) revert ExpiryTooFar();
        // the catalog answers false for an unregistered model and never reverts. `order.designated`
        // is NOT validated here — it may legitimately be 0 ("any provider") and every _rec-gated
        // registry view reverts on an unknown id; claim resolves a real provider id from its signer.
        if (!registry.modelExists(order.modelId)) revert UnknownModel();
        if (!registry.modelEnabled(order.modelId)) revert ModelDisabled();
        {
            // signature-only auth: the client's embedded Order signature is the whole authority
            // and msg.sender is never read, so a relayer lands this transaction
            address signer = _recoverOrder(order, orderSig);
            // a zero recovered signer never authorizes: _recoverOrder answers address(0) for a
            // malformed signature, so reject it before it is compared to anything — otherwise a
            // zero `owner` would authenticate itself
            if (signer == address(0) || signer != owner) revert InvalidOrderSignature();
        }
        bytes32 jobId = keccak256(abi.encodePacked(owner, order.c));
        // the row is never deleted, so a used `c` is permanently spent for this owner
        if (jobs[jobId].owner != address(0)) revert DuplicateJob();
        {
            Job storage j = jobs[jobId];
            j.owner = owner;
            j.modelId = order.modelId;
            j.slaSecs = order.slaSecs;
            j.designated = order.designated;
            j.c = order.c;
            j.rateIn = order.rateIn;
            j.rateOut = order.rateOut;
            j.unitsIn = order.unitsIn;
            j.unitsOut = order.unitsOut;
            j.expiresAt = order.expiresAt;
            j.gasFeeSnap = gasFee;
            j.taskCid = order.taskCid;
            j.authSig = authSig;
        }
        _emitPosted(jobId, owner, order);
    }

    // the fat Posted event needs thirteen arguments off a calldata struct, which does not fit
    // alongside post's four parameters ("stack too deep"); a private frame gives it room
    function _emitPosted(bytes32 jobId, address owner, Order calldata order) private {
        emit Posted(
            jobId,
            order.modelId,
            order.designated,
            owner,
            order.c,
            order.expiresAt,
            order.slaSecs,
            order.rateIn,
            order.rateOut,
            order.unitsIn,
            order.unitsOut,
            gasFee,
            order.taskCid
        );
    }

    /**
     * Land N independent orders in one transaction — the batch surface's posting door.
     *
     * **Skips rather than reverts**, the `AskRegistry.setAsks` rule: a batch is up to 50 000 lines
     * and one bad line must not kill the other 49 999. Every refusal is announced as `PostSkipped`
     * carrying `post`'s own revert data, so a skipped line is a receipt and never a silence.
     *
     * The `try this.post(...)` self-call is what keeps `post` untouched — no second copy of the
     * eight admission gates to drift, and its audit surface is exactly what it was. It is sound
     * **only because `post` never reads `msg.sender`**: authority there is entirely the embedded
     * order signature (see `post`), so re-entering through this contract's own address confers
     * nothing and takes nothing away. A contract that authenticated on the caller could not do
     * this. The cost is one external call's overhead per line.
     *
     * Lengths must agree — a mismatch is a malformed call, not a bad line, and there is no
     * per-line receipt that could describe it.
     */
    function postMany(
        Order[] calldata orders,
        address[] calldata owners,
        bytes[] calldata orderSigs,
        bytes[] calldata authSigs
    ) external {
        if (orders.length != owners.length || orders.length != orderSigs.length || orders.length != authSigs.length) revert LengthMismatch();
        for (uint256 i; i < orders.length; i++) {
            try this.post(orders[i], owners[i], orderSigs[i], authSigs[i]) {}
            catch (bytes memory reason) {
                emit PostSkipped(i, reason);
            }
        }
    }

    function claim(bytes32 jobId, uint64 issuedAt, bytes calldata sig) external {
        Job storage j = jobs[jobId];
        if (j.owner == address(0)) revert UnknownJob();
        // one answer for "not claimable": a resolved row and an abandoned one read alike. Expiry
        // is STRICTLY past expiresAt, matching getJob — a claim landing exactly on the expiry
        // second still lands, which is why the authorization is valid through `expiresAt + 1`.
        if (j.state != uint8(JobState.Open) || block.timestamp > j.expiresAt) revert NotOpen();
        _freshJobOp(issuedAt);
        // NEVER msg.sender: any key may land the op, only the operator can author it
        address signer = _recover(keccak256(abi.encode(CLAIM_TYPEHASH, jobId, issuedAt)), sig);
        // a zero recovered signer never authorizes: _recover answers address(0) for a malformed
        // signature, so reject it before it is compared to anything
        if (signer == address(0)) revert UnknownProvider();
        // idOf is a plain mapping and never reverts, but isListed/modelAllowed/effectiveCap are
        // all _rec-gated and WOULD revert UnknownProviderId on id 0 — so this gate comes first
        uint32 provider = registry.idOf(signer);
        if (provider == 0) revert UnknownProvider();
        if (!registry.isListed(provider)) revert NotListed();
        // modelEnabled is deliberately NOT re-checked here: a model retired after post must still
        // let already-posted jobs drain
        if (!registry.modelAllowed(provider, j.modelId)) revert ModelNotAllowed();
        // designation is matched against the SIGNER's provider id, never the sender
        if (j.designated != 0 && j.designated != provider) revert NotDesignated();
        if (activeJobs[provider] >= registry.effectiveCap(provider)) revert AtCapacity();

        uint128 cap = _atomicCharge(j.rateIn, j.unitsIn, j.rateOut, j.unitsOut);
        // one cast, so the row and the log can never disagree; block.timestamp fits uint64 for the
        // next ~584 billion years
        uint64 at = uint64(block.timestamp);
        j.cap = cap;
        j.providerId = provider; // `designated` is immutable after post and is never written here
        j.claimedAt = at;
        j.state = uint8(JobState.Claimed);
        activeJobs[provider] += 1;
        // CEI, as everywhere else in this file: the parked authorization is hoisted into memory and
        // its storage slot cleared BEFORE the external call, and Claimed is emitted before it too,
        // so every write and every log of this frame precedes the token. The state gates already
        // make a reentrant claim/settle/fail answer NotOpen/NotClaimed, but a token holding a valid
        // settle signature could otherwise settle DURING the pull and leave Claimed logged after
        // Settled — a log projection cannot recover from that ordering.
        // spent either way: the job's single-use nonce is burned, and clearing earns a refund
        bytes memory authSig = j.authSig;
        delete j.authSig;
        emit Claimed(jobId, provider, at);
        // escrow funds exactly once, here, for cap + feeCap + gasFeeSnap, and resolves exactly once
        // later: distributed at settle; at fail/reclaim the gas fee goes to the treasury and the
        // rest back to the owner. A failed pull reverts the
        // whole claim — the chain is the atomicity and there is no unclaim path, so the writes and
        // the log above roll back with it.
        _pullEscrow(jobId, j, _locked(j), authSig);
    }

    // `receive…`, never `transfer…`: the parked signature is public in post's calldata, and only the
    // payee can execute a receive authorization. validBefore is expiresAt + 1 because the token
    // requires `block.timestamp < validBefore` and a claim landing exactly on expiresAt must fund.
    // nonce == jobId: single-use on the token, and bound to this job.
    function _pullEscrow(bytes32 jobId, Job storage j, uint256 amount, bytes memory authSig) private {
        usdc.receiveWithAuthorization(j.owner, address(this), amount, 0, uint256(j.expiresAt) + 1, jobId, authSig);
    }

    function submitAndSettle(
        bytes32 jobId,
        uint32 completionTok,
        bytes calldata resultCid,
        uint64 issuedAt,
        bytes calldata sig
    ) external {
        Job storage j = jobs[jobId];
        // STATE FIRST, claimant second: an Open row (and an absent one) carries providerId 0, so a
        // claimant-first ladder would answer NotTheClaimant and this branch would be unreachable.
        // Job existence is deliberately NOT checked — an unknown job reads Open and answers here.
        // A replay is dead by the same gate: the terminal row persists forever.
        if (j.state != uint8(JobState.Claimed)) revert NotClaimed();
        // NEVER msg.sender: the op signature is the whole authority, so a relayer can land this.
        // The signature binds jobId + completionTok, which is what lets a relayer submit without
        // being able to edit what it settles. resultCid is deliberately OUTSIDE the signature — the
        // coordinator pins the result and the storage service mints the name, so the provider
        // cannot know the CID when it signs; the relayer fills it in and it is recorded, not
        // attested. Nothing else on this path may start depending on it being signed.
        address signer = _recoverSettle(jobId, completionTok, issuedAt, sig);
        // a zero recovered signer never authorizes: _recover answers address(0) for a malformed
        // signature, so reject it before it is compared to anything
        if (signer == address(0)) revert NotTheClaimant();
        // ID equality, not address equality — this is what makes settlement rotation-correct: an
        // operator key rotated after the claim still settles the same provider's job.
        // The `provider == 0` disjunct is subsumed today (the state gate above already means the
        // row is Claimed, and claim always writes a nonzero providerId), and is kept as an
        // explicit refusal so an unresolvable signer can never match a row whose id is zero.
        uint32 provider = registry.idOf(signer);
        if (provider == 0 || provider != j.providerId) revert NotTheClaimant();
        // the SLA deadline is claimedAt + slaSecs, and expiry is STRICTLY past it (a settle landing
        // on the final second lands). reclaim is the permissionless counterpart on this deadline.
        if (block.timestamp > uint256(j.claimedAt) + j.slaSecs) revert SlaExpired();
        _freshJobOp(issuedAt);
        if (resultCid.length == 0) revert EmptyResultCid();

        // the count is clamped BEFORE it is stored, emitted, or priced — so the row's own
        // rateIn*unitsIn + rateOut*completionTok is always the charge that was actually paid
        uint32 tok = completionTok > j.unitsOut ? j.unitsOut : completionTok;
        uint128 metered = _atomicCharge(j.rateIn, j.unitsIn, j.rateOut, tok);
        // widened to uint256 deliberately: `charge * feeBps` would overflow a uint128 for a large
        // charge, and the widening itself is lossless. This is the global-constraints charge
        // formula spelled out; the clamp above already makes metered <= cap (both legs price the
        // same immutable row and tok <= unitsOut), so the min never bites — it is what makes
        // `cap - charge` provably non-negative without relying on that argument.
        uint256 charge = metered > j.cap ? j.cap : metered;

        j.completionTok = tok;
        j.resultCid = resultCid;
        j.state = uint8(JobState.Settled);
        j.endedBecause = ENDED_SETTLED; // cause 1 is view-only — settlement has its own event
        activeJobs[provider] -= 1; // the claim's increment is released here, on this terminal path

        // +5 milli per settlement, clamped to the [100,1000] ceiling by the registry. The literal
        // fits int16 trivially and applyReputationDelta widens to int32 before adding.
        // R25: this runs BEFORE the payout legs, so every state change — here and in the registry,
        // whose effectiveCap reads reputation — is already in place when the untrusted token gets
        // control. A reentrant token can never observe pre-reward capacity.
        registry.applyReputationDelta(provider, 5);
        // escrow resolves exactly once and in full: these three legs sum to charge + fee +
        // gasFeeSnap + (cap + feeCap - charge - fee) == cap + feeCap + gasFeeSnap, the conservation
        // identity on every terminal path. Everything above precedes the transfers, so a reentrant
        // token sees a Settled row and answers NotClaimed.
        uint256 fee = _distribute(j, provider, charge);
        // fee <= cap * 1000 / 10000 < 2**128, so the narrowing is lossless
        emit Settled(jobId, tok, uint128(fee), resultCid);
    }

    // what claim pulled for this row: the cap, the protocol fee's ceiling on top of it, and the
    // gas fee snapshot. feeBps is read live — a fee change follows the drain runbook. No overflow:
    // cap <= uint128 max and feeBps <= 1000, so the product is < 2**138, and the widening is lossless.
    function _locked(Job storage j) private view returns (uint256) {
        return uint256(j.cap) + uint256(j.cap) * feeBps / 10000 + j.gasFeeSnap;
    }

    // a private frame for the payout legs: submitAndSettle's five parameters plus the metering
    // locals leave no room for the fee arithmetic and three calls ("stack too deep")
    function _distribute(Job storage j, uint32 provider, uint256 charge) private returns (uint256 fee) {
        // the fee rides ON TOP of the charge: floors, and charge <= cap, so fee <= the fee ceiling
        // claim pulled and the owner's leg cannot underflow
        fee = charge * feeBps / 10000;
        // CEI, as everywhere else in this file: BOTH fee-derived legs are computed here, before
        // any transfer hands control to the untrusted token. `_locked` reads feeBps a second time,
        // but nothing between the two reads can move it — `setFees` is onlyCuration and no external
        // call has happened yet — so the three legs provably sum to what claim pulled. Deriving the
        // refund after a _pay would put that second read on the far side of the token.
        uint256 refund = _locked(j) - charge - fee - j.gasFeeSnap;
        // the CURRENT operator, resolved at settle time — never the submitter. The full charge.
        _pay(registry.operatorOf(provider), charge);
        _pay(treasury, fee + j.gasFeeSnap);
        // the unused cap and the unused fee go back together
        _pay(j.owner, refund);
    }

    // every payout leg goes through this. A zero leg is a no-op: `fee` floors to 0 at low fees and
    // the refund is 0 whenever charge == cap. The constructor validates nothing about the token, so
    // one that signals failure by returning false must not be mistaken for a successful payout —
    // that is all this guard buys. It is NOT a claim that any ERC-20 is safe here: see "What the
    // payment token has to be" in README.md for the ones this protocol cannot be deployed against.
    function _pay(address to, uint256 amount) internal {
        if (amount == 0) return;
        if (!usdc.transfer(to, amount)) revert TransferFailed();
    }

    function fail(bytes32 jobId, uint64 issuedAt, bytes calldata sig) external {
        Job storage j = jobs[jobId];
        // STATE FIRST, claimant second — the same reason as submitAndSettle: an Open row (and an
        // absent one) carries providerId 0, so a claimant-first ladder would answer NotTheClaimant
        // and this branch would be unreachable. Job existence is deliberately NOT checked, so an
        // unknown job answers here. A replay is dead by the same gate: the terminal row persists.
        if (j.state != uint8(JobState.Claimed)) revert NotClaimed();
        // NEVER msg.sender: the provider's Fail signature is the WHOLE authority, so any relayer may
        // land the abort. The op binds jobId and issuedAt and nothing else — there is nothing to
        // meter or price on this path, only an escrow to unwind.
        address signer = _recover(keccak256(abi.encode(FAIL_TYPEHASH, jobId, issuedAt)), sig);
        // a zero recovered signer never authorizes: _recover answers address(0) for a malformed
        // signature, so reject it before it is compared to anything
        if (signer == address(0)) revert NotTheClaimant();
        // ID equality, not address equality — an operator key rotated after the claim can still
        // abort the same provider's job. The `provider == 0` disjunct is subsumed today (the state
        // gate above already means the row is Claimed, and claim always writes a nonzero
        // providerId), and is kept as an explicit refusal so an unresolvable signer can never match
        // a row whose id is zero.
        uint32 provider = registry.idOf(signer);
        if (provider == 0 || provider != j.providerId) revert NotTheClaimant();
        // the ±600 s op window is a clock of its own and independent of the grace window below —
        // both apply. Its only job is to stop a withheld op from landing at a moment its signer did
        // not choose; it is never a fee clock.
        _freshJobOp(issuedAt);

        // THE GRACE WINDOW PRICES AT LANDING TIME, never at issuedAt: pricing on issuedAt would let
        // a provider pre-sign a free-fail voucher inside the window and land it long after. Strictly
        // past claimedAt + FAIL_GRACE, so an abort at exactly the boundary second is still free.
        // claimedAt is widened so a near-max value reads "inside grace" instead of panicking.
        bool pastGrace = block.timestamp > uint256(j.claimedAt) + FAIL_GRACE;
        // and unlike settle, this path emits its cause
        _refundAndEnd(jobId, j, ENDED_PROVIDER_FAIL, pastGrace);
    }

    // The terminal half of `fail` and `reclaim` — the same five operations in the same order, so it
    // lives in ONE place and R23's capacity decrement and R25's before-the-token ordering cannot
    // drift apart between the two paths. `penalise` is a parameter rather than a rule of its own
    // because only `fail` has a free window: `reclaim` always prices, the SLA having already expired.
    // Both callers have already gated on the row being Claimed. The provider is read off the row
    // rather than passed in: `fail` has just proved its signer's id EQUALS `j.providerId`, so a
    // parameter could only ever disagree with the row whose escrow this releases.
    function _refundAndEnd(bytes32 jobId, Job storage j, uint8 cause, bool penalise) private {
        uint32 provider = j.providerId;
        j.state = uint8(JobState.Cancelled);
        j.endedBecause = cause;
        // cannot underflow: the row is Claimed, which only `claim` produces, and `claim` increments
        // in the same transaction
        activeJobs[provider] -= 1;
        if (penalise) {
            // -40 milli for the accepted-but-undelivered job. The literal fits int16 trivially and
            // applyReputationDelta widens to int32 before adding, then clamps to [100,1000] — the
            // registry's floor, not this call, is what bounds how far a provider can decay.
            // R25: the penalty lands BEFORE the refund, so the registry's effectiveCap has already
            // dropped by the time the untrusted token gets control.
            registry.applyReputationDelta(provider, -40);
        }
        // two legs, and neither pays the operator: the gas fee snapshot goes to the treasury on
        // EVERY terminal path, because the relayer has already spent the gas it recovers — post,
        // claim, and this exit — whether or not the job delivered; a failed job must never cost
        // the coordinator money. The owner gets everything else: the cap, and the fee ceiling
        // untouched, since the take is only ever earned at settlement. Together the legs are the
        // conservation identity — paid out == cap + feeCap + gasFeeSnap, exactly. Every write above
        // precedes the transfers, so a reentrant token sees a Cancelled row and answers NotClaimed.
        _pay(treasury, j.gasFeeSnap);
        _pay(j.owner, _locked(j) - j.gasFeeSnap);
        emit Ended(jobId, cause);
    }

    // The one permissionless, UNSIGNED mutation in the protocol: no issuedAt, no signature, and no
    // msg.sender check. A claimed job that blows its SLA must be resolvable by anyone — the client
    // whose money is locked, a keeper, or the provider itself — because requiring a signature from
    // any particular party would let that party strand the escrow by doing nothing. There is no
    // grace concept here: the SLA has already expired, which is the whole precondition.
    function reclaim(bytes32 jobId) external {
        Job storage j = jobs[jobId];
        // job existence is deliberately NOT checked (as in submitAndSettle and fail): an absent row
        // reads state 0 (Open) and answers here. A replay is dead by the same gate — the terminal
        // row persists, so a second reclaim answers NotClaimed.
        if (j.state != uint8(JobState.Claimed)) revert NotClaimed();
        // the SAME deadline submitAndSettle guards with SlaExpired, read from the other side: at
        // exactly claimedAt + slaSecs the provider may still settle, so reclaim opens strictly
        // after it and the two permissions can never overlap. claimedAt is widened so a near-max
        // value answers SlaNotExpired instead of panicking on overflow.
        if (block.timestamp <= uint256(j.claimedAt) + j.slaSecs) revert SlaNotExpired();
        // `penalise: true` unconditionally — the -40 a post-grace fail pays is owed here too (the job
        // was accepted and not delivered), and there is no free window left to be inside
        _refundAndEnd(jobId, j, ENDED_RECLAIM, true);
    }

    // ONE cancel — signature-only, like every other actor op. There is no `cancelFor` and no
    // msg.sender path: an owner submitting its own cancel is simply relaying its own signature, so
    // the two cases collapse into one entry point. No funds move on ANY path here, because the only
    // cancellable state is Open and an Open job has never funded escrow.
    function cancel(bytes32 jobId, uint64 issuedAt, bytes calldata sig) external {
        _freshJobOp(issuedAt);
        address signer = _recover(keccak256(abi.encode(CANCEL_TYPEHASH, jobId, issuedAt)), sig);
        // a zero recovered signer never authorizes, and here that guard is LOAD-BEARING rather than
        // defense in depth: this path has no existence check, so an unknown job's `owner` is
        // address(0) — exactly what _recover answers for a malformed signature. Refusing zero
        // before the comparison is what stops a 65-zero-byte signature from "matching" it.
        if (signer == address(0)) revert NotTheOwner();
        Job storage j = jobs[jobId];
        // OWNERSHIP BEFORE STATE, so a stranger learns nothing about the row it is poking at. There
        // is deliberately no UnknownJob branch: that is a state answer, and an unknown job fails
        // this gate anyway (its owner is address(0), which the guard above already excluded).
        if (signer != j.owner) revert NotTheOwner();
        uint8 s = j.state;
        // idempotent on an already-ended job: no revert, no event, no funds move. A client retrying
        // a cancel it could not observe must not be punished for it.
        if (s == uint8(JobState.Settled) || s == uint8(JobState.Cancelled)) return;
        // a Claimed job is the provider's to resolve — the client's exit from there is `reclaim`
        if (s != uint8(JobState.Open)) revert NotCancellable();
        // an Open row past its expiresAt is still cancellable: getJob DERIVES an ending for it but
        // stores nothing, so this write is what makes the cause permanent, and the stored 2
        // supersedes the read-time 5 from then on.
        j.state = uint8(JobState.Cancelled);
        j.endedBecause = ENDED_CANCELLED;
        emit Ended(jobId, ENDED_CANCELLED);
    }

    function capOf(bytes32 jobId) external view returns (uint128) {
        return jobs[jobId].cap;
    }

    function getJob(bytes32 jobId) external view returns (JobView memory v) {
        Job storage j = jobs[jobId];
        if (j.owner == address(0)) return v; // unknown job: a fully zeroed body, never a revert
        v.found = true;
        v.jobId = jobId;
        v.owner = j.owner;
        v.c = j.c;
        uint8 state = j.state;
        uint8 ended = j.endedBecause;
        // expiry is derived at read time and never written: nobody has to send a transaction for
        // an abandoned Open job to read as ended
        if (state == uint8(JobState.Open) && block.timestamp > j.expiresAt) {
            state = uint8(JobState.Cancelled);
            ended = ENDED_EXPIRED;
        }
        v.state = state;
        v.endedBecause = ended;
        v.providerId = j.providerId;
        v.designated = j.designated;
        v.modelId = j.modelId;
        v.rateIn = j.rateIn;
        v.rateOut = j.rateOut;
        v.unitsIn = j.unitsIn;
        v.unitsOut = j.unitsOut;
        v.completionTok = j.completionTok;
        v.slaSecs = j.slaSecs;
        v.expiresAt = j.expiresAt;
        v.claimedAt = j.claimedAt;
        v.taskCid = j.taskCid;
        v.resultCid = j.resultCid;
        v.gasFee = j.gasFeeSnap;
    }

    // +-600 s, INCLUSIVE at both ends. No nonce: the one-shot job state machine is the replay
    // guard (a landed claim leaves NotOpen), so the window's only job is to stop a withheld op
    // from landing at a moment its signer did not choose. Cancel/Settle/Fail share the rule.
    function _freshJobOp(uint64 issuedAt) internal view {
        // widened to uint256 so a near-max issuedAt answers StaleOp rather than an arithmetic panic
        uint256 at = issuedAt;
        if (at + 600 < block.timestamp || at > block.timestamp + 600) revert StaleOp();
    }

    // cap = max(1, ceilDiv(rateIn*unitsIn + rateOut*unitsOut, RATE_SCALE)). Settlement reuses this
    // with completionTok in place of unitsOut, which is why both unit counts are uint256.
    function _atomicCharge(uint128 rateIn, uint256 unitsIn, uint128 rateOut, uint256 unitsOut)
        internal
        pure
        returns (uint128)
    {
        // A CALLER OBLIGATION, not an invariant this frame can enforce: both unit counts are
        // `uint256` (so settlement can pass a clamped completionTok through the same arithmetic),
        // and callers MUST pass uint32-wide counts. Both do, straight off the row's uint32 fields,
        // which keeps raw <= 2*(2**128-1)*(2**32-1) < 2**161 and rules out uint256 overflow. A
        // future caller passing a wider count would have to re-argue this bound.
        uint256 raw = uint256(rateIn) * unitsIn + uint256(rateOut) * unitsOut;
        uint256 c = (raw + RATE_SCALE - 1) / RATE_SCALE;
        if (c == 0) c = 1; // a zero-priced order still escrows the one-atomic-unit floor
        // the narrowing cast below is lossless only while c fits uint128, and c reaches ~2**141 at
        // the extremes of that bound, so it is GUARDED rather than range-argued: an order whose cap
        // cannot be represented in Job.cap could not be escrowed or paid out at all, and silently
        // truncating it would escrow a number nobody computed. Unreachable for any sane rate.
        if (c > type(uint128).max) revert CapOverflow();
        return uint128(c);
    }

    // generic op recovery over THIS contract's domain — Claim (and later Settle/Fail/Cancel) use
    // it; the Order path keeps _recoverOrder for its bespoke struct hash. Plain ecrecover over
    // 65-byte (r,s,v) sigs — EOA keys only in v1 (ERC-1271 is future work). A malformed signature
    // recovers to garbage or address(0), and every caller refuses zero before comparing it.
    function _recover(bytes32 structHash, bytes calldata sig) internal view returns (address) {
        if (sig.length != 65) return address(0);
        (bytes32 r, bytes32 s) = (bytes32(sig[0:32]), bytes32(sig[32:64]));
        return ecrecover(keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash)), uint8(sig[64]), r, s);
    }

    // Settle's struct hash, in its own frame for the same stack reason as _distribute. Every member
    // is a static type — resultCid is deliberately not one of them, so the digest this recovers is
    // independent of whatever CID the relayer submits alongside it.
    function _recoverSettle(bytes32 jobId, uint32 completionTok, uint64 issuedAt, bytes calldata sig)
        private
        view
        returns (address)
    {
        return _recover(keccak256(abi.encode(SETTLE_TYPEHASH, jobId, completionTok, issuedAt)), sig);
    }

    function _recoverOrder(Order calldata o, bytes calldata sig) internal view returns (address) {
        return _recover(
            keccak256(
                abi.encode(
                    ORDER_TYPEHASH,
                    o.c,
                    o.modelId,
                    o.slaSecs,
                    o.rateIn,
                    o.rateOut,
                    o.unitsIn,
                    o.unitsOut,
                    o.designated,
                    o.expiresAt
                )
            ),
            sig
        );
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
