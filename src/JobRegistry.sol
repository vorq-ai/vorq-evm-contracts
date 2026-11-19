// SPDX-License-Identifier: FSL-1.1-ALv2
pragma solidity 0.8.30;

import "./Types.sol";
import {ProviderRegistry} from "./ProviderRegistry.sol";

// the two legs this contract uses. The deposit is EIP-3009: the client signs an authorization that
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

/// @notice The job book and the money behind it.
///
/// A client prepays a balance with `deposit`. An order rests off chain until a provider claims it:
/// `claim` carries the client's signed order, records the job as one storage slot, and locks the
/// job's ceiling out of the balance. `submitAndSettle` credits the provider's earnings, the
/// treasury's fee, the relayer's gas fee and the client's refund inside the ledger; `fail` and
/// `reclaim` release the lock. No job op moves a token. Tokens leave only through `withdraw` (the
/// client's own signature), `payProvider` (to the provider's current operator key), `payRelayer`
/// and `payTreasury`.
///
/// Every op is authorised by signatures alone, so any coordinator can relay. The relayer that lands
/// a claim earns that job's `gasFee`, and the relayer that lands a deposit earns its `depositFee`:
/// both pay for gas the relayer spent.
///
/// Conservation: the USDC this contract holds equals the sum of client balances, live locks,
/// provider earnings, relayer earnings and `accrued`.
contract JobRegistry {
    error EmptyTaskCid();
    error SlaNotAllowed();
    error AlreadyExpired();
    error ExpiryTooFar();
    error UnknownModel();
    error ModelDisabled();
    error InvalidOrderSignature();
    error NotOpen();
    error StaleOp();
    error UnknownProvider();
    error NotListed();
    error ModelNotAllowed();
    error NotDesignated();
    error AtCapacity();
    error CapOverflow();
    error InsufficientDeposit();
    error TermsMismatch();
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
    error BadDepositValue();
    error OwnerHasCode();
    error InvalidWithdrawSignature();
    error NothingToPay();

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
    event Claimed(bytes32 indexed jobId, uint32 indexed provider, address indexed relayer, uint64 claimedAt);
    event Settled(
        bytes32 indexed jobId,
        uint32 promptTok,
        uint32 cachedTok,
        uint32 completionTok,
        uint128 rateInCached,
        uint128 fee,
        bytes resultCid
    );
    event Ended(bytes32 indexed jobId, uint8 cause); // 2 cancelled | 3 provider_fail | 4 reclaim only
    event Deposited(address indexed owner, address indexed relayer, uint128 credited, uint128 fee);
    event Withdrawn(address indexed owner, uint128 amount);
    event ProviderPaid(uint32 indexed providerId, address indexed to, uint128 amount);
    event RelayerPaid(address indexed relayer, uint128 amount);
    event TreasuryPaid(address indexed to, uint128 amount);
    event FeesChanged(uint16 feeBps, uint128 gasFee, uint128 depositFee);
    event SlaAllowedChanged(uint32 secs, bool allowed);
    event TreasuryChanged(address treasury);

    uint64 public constant MAX_EXPIRY = 86400;
    uint64 public constant FAIL_GRACE = 300;
    uint256 public constant RATE_SCALE = 1_000_000;
    // taskCid is NOT signed: only the coordinator pins, and the storage service mints the name, so
    // the client cannot know the CID at the moment it signs. `c` — the container commitment,
    // keccak(version ‖ seed_wrap ‖ keccak(ciphertext)) — is what binds the payload, and the provider
    // rebuilds it from the fetched container and requires keccak(owner ‖ c) == jobId; the CID is a
    // fetch hint the relayer fills in, announced in `Posted` but never attested.
    bytes32 public constant ORDER_TYPEHASH = keccak256(
        "Order(bytes32 c,uint32 modelId,uint32 slaSecs,uint128 rateIn,uint128 rateOut,uint32 unitsIn,uint32 unitsOut,uint32 designated,uint64 expiresAt)"
    );
    // every op lands in this contract's domain; declared here so every signer — contract, test
    // helper, and off-chain client — reads one authority for the type strings
    bytes32 public constant CLAIM_TYPEHASH = keccak256("Claim(bytes32 jobId,uint64 issuedAt)");
    // resultCid is NOT signed, for the same reason taskCid is not: the provider hands the result to
    // the coordinator, which pins it and learns the name from the storage service. The CID is
    // announced, never attested. The four usage members are the backend's own counts and the
    // provider's cached rate; the order's units and rateIn cap them.
    bytes32 public constant SETTLE_TYPEHASH = keccak256(
        "Settle(bytes32 jobId,uint32 promptTok,uint32 cachedTok,uint32 completionTok,uint128 rateInCached,uint64 issuedAt)"
    );
    bytes32 public constant FAIL_TYPEHASH = keccak256("Fail(bytes32 jobId,uint64 issuedAt)");
    bytes32 public constant CANCEL_TYPEHASH = keccak256("Cancel(bytes32 jobId,uint64 issuedAt)");
    // the owner is the recovered signer, so it is not a member; the domain binds chain and contract
    bytes32 public constant WITHDRAW_TYPEHASH = keccak256("Withdraw(uint128 amount,uint64 issuedAt)");

    /// One storage slot per job, written once at claim (or at cancel, for an order never claimed).
    /// state 0 (Open) means "no row".
    struct Job {
        uint32 providerId;
        uint40 claimedAt;
        uint8 state;
        uint8 endedBecause;
        bytes21 termsHash;
    }

    /// A client's prepaid, unlocked balance and the issuedAt of its last withdrawal (the replay floor).
    struct Account {
        uint128 balance;
        uint64 lastWithdrawAt;
    }

    /// The two per-provider counters settle touches, in one slot.
    struct Book {
        uint32 active;
        uint128 earned;
    }

    ProviderRegistry public immutable registry;
    IUSDC public immutable usdc;
    address public immutable curation;
    // one slot: everything claim reads about fees, and the treasury beside it
    address public treasury;
    uint16 public feeBps;
    uint64 public gasFee;
    // one slot: the treasury's unpaid protocol fees, and the fee every deposit pays its relayer
    uint128 public accrued;
    uint64 public depositFee;
    mapping(uint32 => bool) public allowedSla;
    mapping(bytes32 => Job) internal jobs;
    mapping(uint32 => Book) internal books;
    mapping(address => Account) internal accounts;
    // gas and deposit fees owed to each relayer, paid to that same address
    mapping(address => uint128) public relayerEarned;
    bytes32 public immutable DOMAIN_SEPARATOR; // this contract's own domain
    /// @dev A DISTINCT EIP-712 domain name per contract, deliberately: a deployment whose
    /// configuration resolves two address slots to the same contract would otherwise produce
    /// digests indistinguishable from legitimate ones, and a wrong `verifyingContract` never errors -
    /// it recovers a stranger. Distinct names make the separators differ regardless of what the
    /// addresses are, and let a wallet show which contract is being authorised.
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
        // $0.003 and $0.002 in USDC's 6 decimals: the relayer's claim + settle gas and its deposit +
        // withdrawal gas on Base mainnet, at a 78% cover ratio; `setFees` moves both. Both are paid
        // to the relayer that spent the gas, never to the treasury.
        gasFee = 3_000;
        depositFee = 2_000;
        // the seeded config is emitted too: the log alone is a complete history
        emit SlaAllowedChanged(3600, true);
        emit SlaAllowedChanged(86400, true);
        emit FeesChanged(100, 3_000, 2_000);
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

    // ── curation ──────────────────────────────────────────────────────────────────────────────

    /// feeBps is read live at every exit and gasFee is fixed per job at claim: both move with the
    /// book empty, so a lock is released at the same fee it was taken at.
    function setFees(uint16 feeBps_, uint64 gasFee_, uint64 depositFee_) external onlyCuration {
        if (feeBps_ > 1000) revert FeeTooHigh(); // 10% hard ceiling on the protocol fee
        feeBps = feeBps_;
        gasFee = gasFee_;
        depositFee = depositFee_;
        emit FeesChanged(feeBps_, gasFee_, depositFee_);
    }

    function setSlaAllowed(uint32 secs, bool ok) external onlyCuration {
        allowedSla[secs] = ok;
        emit SlaAllowedChanged(secs, ok);
    }

    /// Moves where `payTreasury` pays, including fees already accrued and not yet paid out.
    function setTreasury(address treasury_) external onlyCuration {
        treasury = treasury_;
        emit TreasuryChanged(treasury_);
    }

    // ── the ledger ────────────────────────────────────────────────────────────────────────────

    /// Signature-only: the owner's EIP-3009 authorization is the whole authority, and only this
    /// contract (its `to`) can execute it, so any relayer lands the deposit. `depositFee` is taken
    /// from the value and earned by the sender; the rest is credited to the owner. The owner is an
    /// EOA or an EIP-7702 delegated EOA (code `0xef0100 ‖ address`): withdraw and claim recover an
    /// ECDSA signer, so a contract-wallet owner could never move its balance again.
    function deposit(address owner, uint256 value, uint256 validBefore, bytes32 nonce, bytes calldata sig) external {
        uint128 fee = uint128(depositFee);
        if (value <= fee || value > type(uint128).max) revert BadDepositValue();
        uint256 codeSize = owner.code.length;
        if (codeSize != 0 && (codeSize != 23 || bytes3(owner.code) != 0xef0100)) revert OwnerHasCode();
        uint128 credit = uint128(value) - fee;
        accounts[owner].balance += credit;
        relayerEarned[msg.sender] += fee;
        emit Deposited(owner, msg.sender, credit, fee);
        // effects and log first: the token is the last thing to run in this frame
        usdc.receiveWithAuthorization(owner, address(this), value, 0, validBefore, nonce, sig);
    }

    /// The owner's signature withdraws; nothing else does. `issuedAt` is fresh (±600 s) and strictly
    /// above the owner's last withdrawal, so a landed signature can never land again. Only the
    /// unlocked balance can leave: a claimed job's lock is not in it.
    function withdraw(address owner, uint128 amount, uint64 issuedAt, bytes calldata sig) external {
        _freshJobOp(issuedAt);
        address signer = _recover(keccak256(abi.encode(WITHDRAW_TYPEHASH, amount, issuedAt)), sig);
        // a zero recovered signer never authorizes: a zero `owner` would otherwise match it
        if (signer == address(0) || signer != owner) revert InvalidWithdrawSignature();
        Account storage a = accounts[owner];
        if (issuedAt <= a.lastWithdrawAt) revert StaleOp();
        if (amount > a.balance) revert InsufficientDeposit();
        a.balance -= amount;
        a.lastWithdrawAt = issuedAt;
        emit Withdrawn(owner, amount);
        _pay(owner, amount);
    }

    /// Permissionless: pays everything provider `providerId` has earned to its CURRENT operator key,
    /// so a key rotated after the work was done is the key that is paid.
    function payProvider(uint32 providerId) external {
        Book storage b = books[providerId];
        uint128 amount = b.earned;
        if (amount == 0) revert NothingToPay();
        address to = registry.operatorOf(providerId);
        b.earned = 0;
        emit ProviderPaid(providerId, to, amount);
        _pay(to, amount);
    }

    /// Permissionless: pays everything `relayer` has earned to that same address.
    function payRelayer(address relayer) external {
        uint128 amount = relayerEarned[relayer];
        if (amount == 0) revert NothingToPay();
        relayerEarned[relayer] = 0;
        emit RelayerPaid(relayer, amount);
        _pay(relayer, amount);
    }

    /// Permissionless: pays every accrued protocol fee to the treasury.
    function payTreasury() external {
        uint128 amount = accrued;
        if (amount == 0) revert NothingToPay();
        address to = treasury;
        accrued = 0;
        emit TreasuryPaid(to, amount);
        _pay(to, amount);
    }

    function balanceOf(address owner) external view returns (uint128) {
        return accounts[owner].balance;
    }

    function earned(uint32 providerId) external view returns (uint128) {
        return books[providerId].earned;
    }

    function activeJobs(uint32 providerId) external view returns (uint32) {
        return books[providerId].active;
    }

    // ── the job ───────────────────────────────────────────────────────────────────────────────

    /// The provider's claim, carrying the client's signed order: the order goes on chain here.
    /// Two signatures, both the whole authority for their half — the order's recovers `owner`, the
    /// Claim's resolves the provider — so any relayer lands it. msg.sender authorises nothing: it is
    /// recorded in the terms as the relayer that earns the job's gas fee.
    /// Locks `cap + feeCap + gasFee` out of the owner's balance; no token moves.
    function claim(Order calldata order, address owner, bytes calldata orderSig, uint64 issuedAt, bytes calldata sig)
        external
    {
        bytes32 jobId = _admitOrder(order, owner, orderSig);
        uint32 provider = _admitProvider(order, jobId, issuedAt, sig);
        (uint64 gas, bytes21 termsHash) = _lock(order, owner);

        // one cast, so the row and the log can never disagree. uint40 seconds last ~34,800 years.
        uint40 at = uint40(block.timestamp);
        jobs[jobId] = Job({
            providerId: provider,
            claimedAt: at,
            state: uint8(JobState.Claimed),
            endedBecause: ENDED_NONE,
            termsHash: termsHash
        });
        books[provider].active += 1;
        _emitPosted(jobId, owner, order, gas);
        emit Claimed(jobId, provider, msg.sender, at);
    }

    // The order's gates, in order: payload, SLA, expiry, catalog, signature, and an id never used.
    function _admitOrder(Order calldata order, address owner, bytes calldata orderSig)
        private
        view
        returns (bytes32 jobId)
    {
        if (order.taskCid.length == 0) revert EmptyTaskCid();
        if (!allowedSla[order.slaSecs]) revert SlaNotAllowed();
        // expired means STRICTLY past expiresAt: a claim landing on the expiry second still lands
        if (block.timestamp > order.expiresAt) revert AlreadyExpired();
        if (order.expiresAt > block.timestamp + MAX_EXPIRY) revert ExpiryTooFar();
        // the catalog answers false for an unregistered model and never reverts
        if (!registry.modelExists(order.modelId)) revert UnknownModel();
        if (!registry.modelEnabled(order.modelId)) revert ModelDisabled();
        address signer = _recoverOrder(order, orderSig);
        // a zero recovered signer never authorizes: _recoverOrder answers address(0) for a
        // malformed signature, and a zero `owner` would otherwise authenticate itself
        if (signer == address(0) || signer != owner) revert InvalidOrderSignature();
        jobId = keccak256(abi.encodePacked(owner, order.c));
        // a row is never deleted, so a claimed or cancelled id is spent for good
        if (jobs[jobId].state != uint8(JobState.Open)) revert NotOpen();
    }

    // The provider's gates, in order: freshness, a resolvable signer, listed, model allowed,
    // designation, capacity.
    function _admitProvider(Order calldata order, bytes32 jobId, uint64 issuedAt, bytes calldata sig)
        private
        view
        returns (uint32 provider)
    {
        _freshJobOp(issuedAt);
        address signer = _recover(keccak256(abi.encode(CLAIM_TYPEHASH, jobId, issuedAt)), sig);
        if (signer == address(0)) revert UnknownProvider();
        // idOf is a plain mapping and never reverts, but isListed/modelAllowed/effectiveCap are
        // all _rec-gated and WOULD revert UnknownProviderId on id 0 — so this gate comes first
        provider = registry.idOf(signer);
        if (provider == 0) revert UnknownProvider();
        if (!registry.isListed(provider)) revert NotListed();
        if (!registry.modelAllowed(provider, order.modelId)) revert ModelNotAllowed();
        // designation is matched against the SIGNER's provider id, never the sender
        if (order.designated != 0 && order.designated != provider) revert NotDesignated();
        if (books[provider].active >= registry.effectiveCap(provider)) revert AtCapacity();
    }

    // Locks the job's ceiling out of the owner's balance and fixes the terms the exits will price.
    function _lock(Order calldata order, address owner) private returns (uint64 gas, bytes21 termsHash) {
        gas = gasFee;
        Terms memory t = Terms({
            owner: owner,
            rateIn: order.rateIn,
            rateOut: order.rateOut,
            unitsIn: order.unitsIn,
            unitsOut: order.unitsOut,
            slaSecs: order.slaSecs,
            gasFee: gas,
            relayer: msg.sender
        });
        uint256 lock = _locked(_atomicCharge(t.rateIn, t.unitsIn, t.rateOut, t.unitsOut), gas);
        Account storage a = accounts[owner];
        if (lock > a.balance) revert InsufficientDeposit();
        // cannot truncate: lock <= balance <= uint128 max
        a.balance -= uint128(lock);
        termsHash = bytes21(keccak256(abi.encode(t)));
    }

    // its own frame: thirteen event arguments off a calldata struct do not fit beside claim's
    function _emitPosted(bytes32 jobId, address owner, Order calldata order, uint64 gas) private {
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
            gas,
            order.taskCid
        );
    }

    function submitAndSettle(
        bytes32 jobId,
        Terms calldata terms,
        Usage calldata usage,
        bytes calldata resultCid,
        uint64 issuedAt,
        bytes calldata sig
    ) external {
        uint32 provider = _settleGate(jobId, terms, usage, issuedAt, sig, resultCid.length);
        (Usage memory u, uint128 fee) = _settleBooks(provider, terms, usage);
        // +5 milli per settlement, clamped to the [100,1000] ceiling by the registry
        registry.applyReputationDelta(provider, 5);
        emit Settled(jobId, u.promptTok, u.cachedTok, u.completionTok, u.rateInCached, fee, resultCid);
    }

    // Settle's gates, in order: Claimed, terms, claimant, SLA, freshness, a result; then the row is
    // Settled. Its own frame: submitAndSettle's parameters leave no room for these locals.
    function _settleGate(
        bytes32 jobId,
        Terms calldata terms,
        Usage calldata usage,
        uint64 issuedAt,
        bytes calldata sig,
        uint256 resultCidLength
    ) private returns (uint32 provider) {
        Job storage j = _claimedRow(jobId, terms);
        // NEVER msg.sender: the op signature is the whole authority, so a relayer can land this.
        // The signature binds jobId + the usage, so a relayer cannot edit what it settles.
        // resultCid is deliberately OUTSIDE the signature: the relayer fills it in and it is
        // announced, not attested.
        address signer = _recoverSettle(jobId, usage, issuedAt, sig);
        if (signer == address(0)) revert NotTheClaimant();
        // ID equality, not address equality — an operator key rotated after the claim still
        // settles the same provider's job
        provider = registry.idOf(signer);
        if (provider == 0 || provider != j.providerId) revert NotTheClaimant();
        // the SLA deadline is claimedAt + slaSecs, and expiry is STRICTLY past it (a settle landing
        // on the final second lands). reclaim is the permissionless counterpart on this deadline.
        if (block.timestamp > uint256(j.claimedAt) + terms.slaSecs) revert SlaExpired();
        _freshJobOp(issuedAt);
        if (resultCidLength == 0) revert EmptyResultCid();
        j.state = uint8(JobState.Settled);
        j.endedBecause = ENDED_SETTLED; // cause 1 is view-only — settlement has its own event
    }

    // Clamps the backend's counts to the terms — promptTok <= unitsIn, cachedTok <= promptTok,
    // completionTok <= unitsOut, rateInCached <= rateIn — prices them, and splits the lock:
    // the charge to the provider, the fee to the treasury, the gas fee to the claim's relayer, the
    // rest back to the owner. The four credits sum to cap + feeCap + gasFee, what claim locked.
    function _settleBooks(uint32 provider, Terms calldata t, Usage calldata usage)
        private
        returns (Usage memory u, uint128 fee)
    {
        u.promptTok = usage.promptTok > t.unitsIn ? t.unitsIn : usage.promptTok;
        u.cachedTok = usage.cachedTok > u.promptTok ? u.promptTok : usage.cachedTok;
        u.completionTok = usage.completionTok > t.unitsOut ? t.unitsOut : usage.completionTok;
        u.rateInCached = usage.rateInCached > t.rateIn ? t.rateIn : usage.rateInCached;
        uint128 metered = _scaled(
            uint256(t.rateIn) * (u.promptTok - u.cachedTok) + uint256(u.rateInCached) * u.cachedTok + uint256(t.rateOut)
                * u.completionTok
        );
        uint128 cap = _atomicCharge(t.rateIn, t.unitsIn, t.rateOut, t.unitsOut);
        // every clamped leg prices at or under the cap's own leg; the min makes it provable
        uint128 charge = metered > cap ? cap : metered;
        // the fee rides ON TOP of the charge and floors, so fee <= the fee ceiling claim locked.
        // fee <= cap * 1000 / 10000 < 2**128, so the narrowings are lossless.
        uint256 bps = feeBps;
        fee = uint128(uint256(charge) * bps / 10000);
        uint128 refund = (cap - charge) + (uint128(uint256(cap) * bps / 10000) - fee);
        Book storage b = books[provider];
        b.active -= 1; // the claim's increment is released here, on this terminal path
        b.earned += charge;
        accrued += fee;
        relayerEarned[t.relayer] += t.gasFee;
        accounts[t.owner].balance += refund;
    }

    function fail(bytes32 jobId, Terms calldata terms, uint64 issuedAt, bytes calldata sig) external {
        Job storage j = _claimedRow(jobId, terms);
        // NEVER msg.sender: the provider's Fail signature is the WHOLE authority, so any relayer may
        // land the abort. The op binds jobId and issuedAt and nothing else.
        address signer = _recover(keccak256(abi.encode(FAIL_TYPEHASH, jobId, issuedAt)), sig);
        if (signer == address(0)) revert NotTheClaimant();
        uint32 provider = registry.idOf(signer);
        if (provider == 0 || provider != j.providerId) revert NotTheClaimant();
        // the ±600 s op window is a clock of its own and independent of the grace window below
        _freshJobOp(issuedAt);
        // THE GRACE WINDOW PRICES AT LANDING TIME, never at issuedAt: pricing on issuedAt would let
        // a provider pre-sign a free-fail voucher inside the window and land it long after. Strictly
        // past claimedAt + FAIL_GRACE, so an abort at exactly the boundary second is still free.
        bool pastGrace = block.timestamp > uint256(j.claimedAt) + FAIL_GRACE;
        _refundAndEnd(jobId, j, terms, ENDED_PROVIDER_FAIL, pastGrace);
    }

    // The one permissionless, UNSIGNED mutation on a job: no issuedAt, no signature, and no
    // msg.sender check. A claimed job that blows its SLA must be resolvable by anyone — the client
    // whose money is locked, a keeper, or the provider itself — because requiring a signature from
    // any particular party would let that party strand the lock by doing nothing.
    function reclaim(bytes32 jobId, Terms calldata terms) external {
        Job storage j = _claimedRow(jobId, terms);
        // the SAME deadline submitAndSettle guards with SlaExpired, read from the other side: at
        // exactly claimedAt + slaSecs the provider may still settle, so reclaim opens strictly
        // after it and the two permissions can never overlap
        if (block.timestamp <= uint256(j.claimedAt) + terms.slaSecs) revert SlaNotExpired();
        // the -40 a post-grace fail pays is owed here too: the job was accepted and not delivered
        _refundAndEnd(jobId, j, terms, ENDED_RECLAIM, true);
    }

    // The terminal half of `fail` and `reclaim`. The gas fee goes to the claim's relayer on EVERY
    // exit, because the relayer has already spent the gas it recovers whether or not the job delivered;
    // the owner gets the cap and the untouched fee ceiling back, since the take is only ever earned
    // at settlement. Together: cap + feeCap + gasFee, what claim locked.
    function _refundAndEnd(bytes32 jobId, Job storage j, Terms calldata t, uint8 cause, bool penalise) private {
        uint32 provider = j.providerId;
        j.state = uint8(JobState.Cancelled);
        j.endedBecause = cause;
        books[provider].active -= 1;
        relayerEarned[t.relayer] += t.gasFee;
        accounts[t.owner].balance += uint128(_locked(_atomicCharge(t.rateIn, t.unitsIn, t.rateOut, t.unitsOut), 0));
        if (penalise) {
            // -40 milli for the accepted-but-undelivered job, clamped to [100,1000] by the registry
            registry.applyReputationDelta(provider, -40);
        }
        emit Ended(jobId, cause);
    }

    // STATE FIRST, terms second: an id with no row reads Open, so every exit answers NotClaimed for
    // an unknown job and for a replay against the terminal row, which persists forever.
    function _claimedRow(bytes32 jobId, Terms calldata terms) private view returns (Job storage j) {
        j = jobs[jobId];
        if (j.state != uint8(JobState.Claimed)) revert NotClaimed();
        if (bytes21(keccak256(abi.encode(terms))) != j.termsHash) revert TermsMismatch();
    }

    /// The owner's way out of an order nobody has claimed: it writes a Cancelled row, so the id can
    /// never be claimed. Signature-only; no funds move, because an unclaimed order locks nothing.
    function cancel(address owner, bytes32 c, uint64 issuedAt, bytes calldata sig) external {
        _freshJobOp(issuedAt);
        bytes32 jobId = keccak256(abi.encodePacked(owner, c));
        address signer = _recover(keccak256(abi.encode(CANCEL_TYPEHASH, jobId, issuedAt)), sig);
        // the zero refusal is LOAD-BEARING: a malformed signature recovers address(0), which would
        // otherwise match a zero `owner`. The id is derived from `owner`, so a signer can only ever
        // cancel its own orders, and learns nothing about anyone else's.
        if (signer == address(0) || signer != owner) revert NotTheOwner();
        Job storage j = jobs[jobId];
        uint8 s = j.state;
        // idempotent on an already-ended job: no revert, no event, no write
        if (s == uint8(JobState.Settled) || s == uint8(JobState.Cancelled)) return;
        // a Claimed job is the provider's to resolve — the client's exit from there is `reclaim`
        if (s == uint8(JobState.Claimed)) revert NotCancellable();
        j.state = uint8(JobState.Cancelled);
        j.endedBecause = ENDED_CANCELLED;
        emit Ended(jobId, ENDED_CANCELLED);
    }

    function getJob(bytes32 jobId) external view returns (JobView memory v) {
        Job storage j = jobs[jobId];
        if (j.state == uint8(JobState.Open)) return v; // no row: a fully zeroed body, never a revert
        v.found = true;
        v.jobId = jobId;
        v.state = j.state;
        v.endedBecause = j.endedBecause;
        v.providerId = j.providerId;
        v.claimedAt = j.claimedAt;
    }

    // ── internals ─────────────────────────────────────────────────────────────────────────────

    // what claim locks: the cap, the protocol fee's ceiling on top of it, and the gas fee. No
    // overflow: cap < 2**128 and feeBps <= 1000, so the sum is < 2**130.
    function _locked(uint128 cap, uint64 gas) private view returns (uint256) {
        return uint256(cap) + uint256(cap) * feeBps / 10000 + gas;
    }

    // Every token transfer goes through this. A zero amount is a no-op. A token that signals
    // failure by returning false must not be mistaken for a successful payout — that is all this
    // guard buys; see "What the payment token has to be" in README.md.
    function _pay(address to, uint256 amount) internal {
        if (amount == 0) return;
        if (!usdc.transfer(to, amount)) revert TransferFailed();
    }

    // +-600 s, INCLUSIVE at both ends. Its only job is to stop a withheld op from landing at a
    // moment its signer did not choose. The job state machine is the replay guard for claim,
    // settle, fail and cancel; withdraw adds a per-owner monotonic floor.
    function _freshJobOp(uint64 issuedAt) internal view {
        // widened to uint256 so a near-max issuedAt answers StaleOp rather than an arithmetic panic
        uint256 at = issuedAt;
        if (at + 600 < block.timestamp || at > block.timestamp + 600) revert StaleOp();
    }

    // cap = max(1, ceilDiv(rateIn*unitsIn + rateOut*unitsOut, RATE_SCALE)). Callers pass uint32
    // counts, which keeps raw <= 2*(2**128-1)*(2**32-1) < 2**161.
    function _atomicCharge(uint128 rateIn, uint256 unitsIn, uint128 rateOut, uint256 unitsOut)
        internal
        pure
        returns (uint128)
    {
        return _scaled(uint256(rateIn) * unitsIn + uint256(rateOut) * unitsOut);
    }

    // raw atomic-rate sum -> max(1, ceilDiv(raw, RATE_SCALE)), guarded to uint128. Every caller
    // passes uint128 rates times uint32 counts (at most three legs), so raw < 2**163 never overflows.
    function _scaled(uint256 raw) private pure returns (uint128) {
        uint256 c = (raw + RATE_SCALE - 1) / RATE_SCALE;
        if (c == 0) c = 1; // a zero-priced order still locks the one-atomic-unit floor
        // an order whose cap cannot be represented could not be locked or paid at all, and silently
        // truncating it would lock a number nobody computed. Unreachable for any sane rate.
        if (c > type(uint128).max) revert CapOverflow();
        return uint128(c);
    }

    // Plain ecrecover over 65-byte (r,s,v) sigs — EOA keys only. A malformed signature recovers to
    // garbage or address(0), and every caller refuses zero before comparing it.
    function _recover(bytes32 structHash, bytes calldata sig) internal view returns (address) {
        if (sig.length != 65) return address(0);
        (bytes32 r, bytes32 s) = (bytes32(sig[0:32]), bytes32(sig[32:64]));
        return ecrecover(keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash)), uint8(sig[64]), r, s);
    }

    // Settle's struct hash. Every member is a static type — resultCid is deliberately not one of
    // them, so the digest is independent of whatever CID the relayer submits alongside it.
    function _recoverSettle(bytes32 jobId, Usage calldata u, uint64 issuedAt, bytes calldata sig)
        private
        view
        returns (address)
    {
        return _recover(
            keccak256(
                abi.encode(SETTLE_TYPEHASH, jobId, u.promptTok, u.cachedTok, u.completionTok, u.rateInCached, issuedAt)
            ),
            sig
        );
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
    /// salt, no extensions.
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
