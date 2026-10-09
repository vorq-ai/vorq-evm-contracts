// SPDX-License-Identifier: FSL-1.1-ALv2
pragma solidity 0.8.30;

contract ProviderRegistry {
    error NotCuration();
    error NotJobRegistry();
    error DuplicateOperator();
    error ZeroOperator();
    error UnknownProviderId();
    error NotAProvider();
    error StaleOp();
    error UnknownModel();

    event ProviderRegistered(uint32 indexed providerId, address operator);
    event OperatorChanged(uint32 indexed providerId, address operator);
    event ListedChanged(uint32 indexed providerId, bool listed);
    event CapacityChanged(uint32 indexed providerId, uint32 ceiling, uint32 requested);
    event ReputationChanged(uint32 indexed providerId, uint16 milli);
    event ModelRegistered(uint32 indexed modelId, string name);
    event ModelEnabledChanged(uint32 indexed modelId, bool enabled);
    event AllowedModelsChanged(uint32 indexed providerId, bool allowAll, uint32[] modelIds);
    event AllowlistEntrySet(bytes32 indexed key, uint8 status, bytes entry);
    event IdentityUpdated(uint32 indexed providerId, bytes32 boxKey, bytes evidence);
    event JobRegistryAuthorized(address indexed registry, bool authorized);

    struct Rec {
        address operator;
        bytes32 boxKey;
        uint16 reputation; // milli, [100,1000]; seeded by register, moved by the job path
        uint32 capacityCeiling;
        uint32 capacityRequested;
        bool listed;
        bool allowAllModels;
    }

    address public immutable curation;
    /**
     * The JobRegistries allowed to move reputation — an allowlist, not a pointer.
     *
     * A JobRegistry holds no durable state (a job is dead within `MAX_EXPIRY` plus one SLA window,
     * and everything long-lived — ids, reputation, models, the allowlist — lives here), so it is
     * serviced by redeploying rather than by upgrading. That cutover has an overlap: for the ~48h
     * the outgoing registry takes to drain, both it and its replacement must be able to apply
     * reputation for their own in-flight jobs. A single settable address cannot say that, and a
     * set-once one cannot say it even in principle.
     */
    mapping(address => bool) public isJobRegistry;
    uint32 public nextProviderId = 1;
    mapping(uint32 => Rec) internal recs;
    mapping(address => uint32) public idOf;
    mapping(uint32 => uint64) public lastCapacityAt; // monotonic floor — RequestCapacity ops
    mapping(uint32 => uint64) public lastIdentityAt; // monotonic floor — SetIdentity ops

    uint32 public nextModelId = 1;
    mapping(uint32 => bool) public modelExists;
    mapping(uint32 => bool) public modelEnabled;
    mapping(uint32 => uint32) internal allowEpoch;
    mapping(uint32 => mapping(uint32 => mapping(uint32 => bool))) internal allowed; // id → epoch → model
    mapping(bytes32 => uint8) public allowlistStatus; // 0 never, 1 active, 2 revoked

    bytes32 public immutable DOMAIN_SEPARATOR; // this contract's own domain
    /// @dev A DISTINCT EIP-712 domain name per contract, deliberately.
    ///
    /// All three registries previously answered to `"VORQ"` and differed only in
    /// `verifyingContract`. That is legal, and it makes one real failure mode invisible: a
    /// deployment whose configuration resolves two address slots to the same contract produces
    /// digests indistinguishable from legitimate ones, and a wrong `verifyingContract` never
    /// errors - it recovers a stranger. Distinct names make the separators differ regardless of
    /// what the addresses are, and let a wallet show which contract is being authorised.
    string public constant EIP712_NAME = "VORQ Providers";
    string public constant EIP712_VERSION = "2";
    bytes32 public constant REQUEST_CAPACITY_TYPEHASH = keccak256("RequestCapacity(uint32 n,uint64 issuedAt)");
    bytes32 public constant SET_IDENTITY_TYPEHASH =
        keccak256("SetIdentity(bytes32 boxKey,bytes evidence,uint64 issuedAt)");

    modifier onlyCuration() {
        if (msg.sender != curation) revert NotCuration();
        _;
    }

    modifier onlyJobRegistry() {
        if (!isJobRegistry[msg.sender]) revert NotJobRegistry();
        _;
    }

    constructor(address curation_) {
        curation = curation_;
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

    /// Authorize (or revoke) a JobRegistry. Revocation is what closes a cutover: the drained
    /// registry loses its one privilege here the moment its last job is terminal.
    function setJobRegistry(address a, bool authorized) external onlyCuration {
        isJobRegistry[a] = authorized;
        emit JobRegistryAuthorized(a, authorized);
    }

    /// @notice Create a provider record at the reputation curation chose for it. The seed is
    /// clamped exactly as `setReputation` clamps, so the record can never be born outside
    /// [100,1000]; the ops script is what refuses an out-of-band value before it is sent.
    function register(address operator, uint32 capacityCeiling, bool listed, uint16 reputation)
        external
        onlyCuration
        returns (uint32 id)
    {
        if (operator == address(0)) revert ZeroOperator(); // idOf[0] can never resolve — the record would be unreachable
        if (idOf[operator] != 0) revert DuplicateOperator();
        id = nextProviderId++;
        recs[id] = Rec(operator, 0, _clamp(reputation), capacityCeiling, 0, listed, true);
        idOf[operator] = id;
        emit ProviderRegistered(id, operator);
        emit ListedChanged(id, listed);
        emit CapacityChanged(id, capacityCeiling, 0);
        emit ReputationChanged(id, recs[id].reputation);
    }

    function setOperator(uint32 id, address newOperator) external onlyCuration {
        Rec storage r = _rec(id);
        // a zero operator would brick the record irreversibly (every _rec path, this one
        // included, would revert) and would let idOf[address(0)] authorize a bad signature
        if (newOperator == address(0)) revert ZeroOperator();
        if (idOf[newOperator] != 0) revert DuplicateOperator();
        delete idOf[r.operator];
        r.operator = newOperator;
        idOf[newOperator] = id;
        emit OperatorChanged(id, newOperator);
    }

    function setListed(uint32 id, bool listed) external onlyCuration {
        _rec(id).listed = listed;
        emit ListedChanged(id, listed);
    }

    function setCapacityCeiling(uint32 id, uint32 ceiling) external onlyCuration {
        Rec storage r = _rec(id);
        r.capacityCeiling = ceiling;
        emit CapacityChanged(id, ceiling, r.capacityRequested);
    }

    function setReputation(uint32 id, uint16 milli) external onlyCuration {
        Rec storage r = _rec(id);
        r.reputation = _clamp(milli);
        emit ReputationChanged(id, r.reputation);
    }

    function registerModel(string calldata name) external onlyCuration returns (uint32 id) {
        id = nextModelId++;
        modelExists[id] = true;
        modelEnabled[id] = true;
        emit ModelRegistered(id, name);
    }

    function setModelEnabled(uint32 modelId, bool enabled) external onlyCuration {
        if (!modelExists[modelId]) revert UnknownModel();
        modelEnabled[modelId] = enabled;
        emit ModelEnabledChanged(modelId, enabled);
    }

    function setAllowedModels(uint32 id, uint32[] calldata modelIds, bool allowAll) external onlyCuration {
        Rec storage r = _rec(id);
        r.allowAllModels = allowAll;
        uint32 epoch = ++allowEpoch[id]; // full replacement: prior-epoch entries are orphaned, never read again
        for (uint256 i; i < modelIds.length; i++) {
            allowed[id][epoch][modelIds[i]] = true;
        }
        emit AllowedModelsChanged(id, allowAll, modelIds);
    }

    function modelAllowed(uint32 id, uint32 modelId) external view returns (bool) {
        Rec storage r = _rec(id);
        return r.allowAllModels || allowed[id][allowEpoch[id]][modelId];
    }

    function setAllowlistEntry(bytes32 key, uint8 status, bytes calldata entry) external onlyCuration {
        // curation is trusted: any status lands, {1 active, 2 revoked} is the off-chain vocabulary.
        // Revocation is a status flip — an entry is never deleted, so 0 always means "never listed".
        allowlistStatus[key] = status;
        emit AllowlistEntrySet(key, status, entry);
    }

    function requestCapacity(uint32 n, uint64 issuedAt, bytes calldata sig) external {
        // NEVER msg.sender: any key may land the op; only the operator can author it
        address signer = _recover(keccak256(abi.encode(REQUEST_CAPACITY_TYPEHASH, n, issuedAt)), sig);
        // a zero recovered signer never authorizes: _recover answers address(0) for a
        // malformed signature, so reject it before it is compared to anything
        if (signer == address(0)) revert NotAProvider();
        uint32 id = idOf[signer];
        if (id == 0) revert NotAProvider();
        // latest-wins state: strict ordering (a replayed older op must never land),
        // skew-bounded so a broken clock cannot brick the slot — the ask book's rule.
        // block.timestamp is the intended reference: a nudged timestamp only shifts a
        // 1h acceptance window; the monotonic floor, not the clock, is the replay guard.
        if (issuedAt <= lastCapacityAt[id] || issuedAt > block.timestamp + 3600) revert StaleOp();
        lastCapacityAt[id] = issuedAt;
        Rec storage r = recs[id];
        r.capacityRequested = n;
        emit CapacityChanged(id, r.capacityCeiling, n);
    }

    function setIdentity(bytes32 boxKey, bytes calldata evidence, uint64 issuedAt, bytes calldata sig) external {
        // operator-signed, relayed by anyone — attested deployments rotate ephemeral keys per
        // boot, gas-free hosted; the monotonic floor makes a superseded key unreplayable.
        // NEVER msg.sender. `evidence` is hashed into the struct hash per EIP-712 bytes rules.
        address signer =
            _recover(keccak256(abi.encode(SET_IDENTITY_TYPEHASH, boxKey, keccak256(evidence), issuedAt)), sig);
        // a zero recovered signer never authorizes: _recover answers address(0) for a
        // malformed signature, so reject it before it is compared to anything
        if (signer == address(0)) revert NotAProvider();
        uint32 id = idOf[signer];
        if (id == 0) revert NotAProvider();
        // this op's own floor, independent of lastCapacityAt: a concurrent capacity op must
        // never invalidate an identity op, and a replayed older identity op must never
        // republish a superseded box key. Skew-bounded so a broken clock cannot brick the slot.
        if (issuedAt <= lastIdentityAt[id] || issuedAt > block.timestamp + 3600) revert StaleOp();
        lastIdentityAt[id] = issuedAt;
        recs[id].boxKey = boxKey;
        emit IdentityUpdated(id, boxKey, evidence); // the chain stores only the key; evidence lives in the log
    }

    function _recover(bytes32 structHash, bytes calldata sig) internal view returns (address) {
        // plain ecrecover, 65-byte (r,s,v) sigs — EOA keys only in v1 (no OZ dependency);
        // malformed sigs recover to garbage or address(0), which idOf resolves to nothing
        if (sig.length != 65) return address(0);
        (bytes32 r, bytes32 s) = (bytes32(sig[0:32]), bytes32(sig[32:64]));
        return ecrecover(keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash)), uint8(sig[64]), r, s);
    }

    function applyReputationDelta(uint32 id, int16 delta) external onlyJobRegistry {
        Rec storage r = _rec(id);
        int32 next = int32(uint32(r.reputation)) + delta;
        // both casts are lossless on this branch: next > 0, and next <= 1000 + int16max = 33767 < 2**16
        r.reputation = _clamp(next <= 0 ? 0 : uint16(uint32(next)));
        emit ReputationChanged(id, r.reputation);
    }

    function operatorOf(uint32 id) external view returns (address) {
        return _rec(id).operator;
    }

    function isListed(uint32 id) external view returns (bool) {
        return _rec(id).listed;
    }

    function reputationOf(uint32 id) external view returns (uint16) {
        return _rec(id).reputation;
    }

    function effectiveCap(uint32 id) external view returns (uint32) {
        Rec storage r = _rec(id);
        uint32 granted = r.capacityRequested < r.capacityCeiling ? r.capacityRequested : r.capacityCeiling;
        // cast is lossless: reputation <= 1000 always (the [100,1000] invariant, written only by
        // register's clamped seed, _clamp and applyReputationDelta) and granted <= 2**32-1, so the product
        // over 1000 is at most 2**32-1
        uint32 cap = uint32(uint256(r.reputation) * granted / 1000);
        return cap == 0 ? 1 : cap;
    }

    function boxKeyOf(uint32 id) external view returns (bytes32) {
        return _rec(id).boxKey;
    }

    function _clamp(uint16 v) internal pure returns (uint16) {
        if (v < 100) return 100;
        if (v > 1000) return 1000;
        return v;
    }

    function _rec(uint32 id) internal view returns (Rec storage r) {
        r = recs[id];
        if (r.operator == address(0)) revert UnknownProviderId();
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
