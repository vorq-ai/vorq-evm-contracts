// SPDX-License-Identifier: FSL-1.1-ALv2
pragma solidity 0.8.30;

import {AskRegistry} from "../src/AskRegistry.sol";
import {IUSDC, JobRegistry} from "../src/JobRegistry.sol";
import {ProviderRegistry} from "../src/ProviderRegistry.sol";
import {Ask, AskSnapshot, Order} from "../src/Types.sol";
import {BaseFork, IFiatToken} from "./utils/BaseFork.sol";
import {RegSig} from "./utils/RegSig.sol";
import {VecJson} from "./utils/VecJson.sol";

/// @notice The cross-language EIP-712 signing vectors, generated and verified here.
///
/// Every case carries a **standard EIP-712 payload** — `{types, primaryType, domain, message}` —
/// which is the same object `eth_account.encode_typed_data` and viem's `hashTypedData` consume.
/// So the file is not a report about signing; it is executable in all four languages, and each
/// consumer's own type table is checked by list equality against `typed_data.types`.
///
/// Three properties make it non-circular, one per link in the chain:
///
///  1. The digest is derived from the payload's own bytes by `vm.eip712HashTypedData` — not
///     re-assembled here out of typehashes that could agree with a mistake.
///  2. The signature is made over exactly that digest.
///  3. Every signature is then handed to the DEPLOYED contract and must be ACCEPTED. If the
///     published `types` block were wrong, the contract would compute a different digest, recover
///     a stranger and revert. `test_*Accepts*` reaching its assertion is the proof.
///
/// It needs no docker. It forks Base Sepolia at the block `BaseFork` pins, so the payment token is
/// the real USDC and the payment case's domain is read off it rather than transcribed.
/// `Deploy.s.sol` fixes the deploy order precisely so addresses are deterministic, and `setUp`
/// reproduces them in-process — then asserts each one, so a change to that order fails loudly here
/// instead of silently re-addressing the vectors.
///
///   forge test --match-contract VectorsTest           # verify the committed file
///   make eip712                                       # regenerate and distribute it
///
/// The file is checked twice over, because the two checks catch different things.
/// `test_VectorsAreCurrent` compares the values it knows to look for and says which case broke;
/// `test_TheCommittedFileIsExactlyWhatThisTestGenerates` compares the whole document, which is
/// what catches a `typed_data.types` block that no value-by-value assertion reads back. Both sides
/// of that comparison are normalised by the same `vm.writeJson` in the same run, so it is exact
/// without being hostage to Foundry's formatting.
contract VectorsTest is BaseFork {
    using VecJson for *;

    string internal constant OUT = "./vectors/signing-v3.json";
    string internal constant CONTAINER_VECTORS = "../vorq-coordinator-node/test/vectors/container-v1.json";

    // Anvil's dev keys in this project's fixed role assignment, matching Deploy.s.sol.
    uint256 internal constant DEPLOYER_PK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 internal constant TREASURY_PK = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint256 internal constant CURATION_PK = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;
    uint256 internal constant PROVIDER_PK = 0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6;
    uint256 internal constant CLIENT_PK = 0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a;

    // Nothing here is read off the clock: a committed vector may not move between runs. REF_TS sits
    // in the future because the registry ops carry a monotonic floor, so a fixed issuedAt has to
    // stay above whatever a running stack — and, now, the forked block's own clock — has recorded.
    uint64 internal constant REF_TS = 1800000000; // 2027-01-15T08:00:00Z
    uint64 internal constant EXPIRES_A = REF_TS + 3600;
    uint64 internal constant EXPIRES_B = REF_TS + 86400;
    uint32 internal constant COMPLETION_TOK = 1500;
    uint32 internal constant CAPACITY_N = 8;

    // The two `c` values are lifted from the coordinator's container-v1.json on purpose: a client
    // that builds a container, commits it and then signs the order can chain the two vector files
    // end to end instead of trusting an invented commitment. `test_TheContainerLinkIsCurrent()`
    // re-reads that file on every `forge test`, so a copy that has gone stale fails rather than
    // emitting orders no container vector reproduces. BOX_KEY is not a commitment and is this
    // file's own.
    bytes32 internal constant C_A = 0xef1815ef5d6b0fc3e7efed1f823424236e5a273e2154c98ec2cdfd744de139b5;
    bytes32 internal constant C_B = 0x8c4f472c5651b196e8a101db8795d1bd0c29c31403dcbe30969788b6794fa780;
    bytes32 internal constant BOX_KEY = 0x2ff6be44f4c8b0b6e3fe1c22bbe4d1e5cbe4b3a5f9d0c17e2a68b4d3907c5e11;

    string internal constant MODEL_NAME = "deepseek-ai/deepseek-v4-pro:fp8";
    uint32 internal constant CAPACITY_CEILING = 16;
    uint16 internal constant SEED_REPUTATION = 1000;
    /// @dev 1,000,000 USDC at 6 decimals — the same balance `fork/bootstrap.sh` mints the client
    uint256 internal constant CLIENT_FUNDS = 1_000_000_000_000;

    struct Case {
        string name;
        string domainKey;
        string typedData;
        bytes32 digest;
        address signer;
        bytes signature;
        string extra; // raw JSON object of side data a consumer needs, or ""
    }

    ProviderRegistry internal reg;
    JobRegistry internal jr;
    AskRegistry internal ar;

    address internal client;
    address internal provider;
    address internal curation;
    bytes32 internal jobIdA;
    bytes32 internal jobIdB;
    uint256 internal amountA;
    bytes internal evidence;

    // ===========================================================================================
    // deployment — Deploy.s.sol's order, reproduced in-process
    // ===========================================================================================

    function setUp() public {
        _fork();
        client = vm.addr(CLIENT_PK);
        provider = vm.addr(PROVIDER_PK);
        curation = vm.addr(CURATION_PK);
        evidence = bytes("mock-provider-v1:devnet-attestation-0"); // 37 bytes: not a 32-byte multiple

        // Anvil's mnemonic is public, so on a fork of a real network these accounts arrive with
        // history: EIP-7702 delegation code and used nonces. `fork/bootstrap.sh` wipes both before
        // it deploys, and this reproduces that — the client MUST have no code or USDC routes its
        // signature through ERC-1271 and refuses it, and the deployer MUST start at nonce 0 or the
        // three CREATE addresses asserted below move.
        address deployer = vm.addr(DEPLOYER_PK);
        address[4] memory roles = [deployer, client, provider, curation];
        for (uint256 i; i < roles.length; ++i) {
            vm.etch(roles[i], "");
        }
        vm.setNonceUnsafe(deployer, 0);

        vm.startPrank(deployer);
        reg = new ProviderRegistry(curation);
        jr = new JobRegistry(reg, IUSDC(USDC), curation, vm.addr(TREASURY_PK));
        ar = new AskRegistry(reg);
        vm.stopPrank();
        deal(USDC, client, CLIENT_FUNDS);

        // The fork stack's published addresses. Deploy.s.sol calls its deploy order load-bearing;
        // this is where that claim is enforced. A reorder fails here rather than quietly moving
        // every committed digest to a deployment nobody is running.
        assertEq(address(reg), 0x5FbDB2315678afecb367f032d93F642f64180aa3, "providerRegistry address moved");
        assertEq(address(jr), 0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512, "jobRegistry address moved");
        assertEq(address(ar), 0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0, "askRegistry address moved");

        vm.startPrank(curation);
        reg.setJobRegistry(address(jr), true);
        require(reg.registerModel(MODEL_NAME) == 1, "model catalog was not fresh");
        require(reg.register(provider, CAPACITY_CEILING, true, SEED_REPUTATION) == 1, "provider registry was not fresh");
        vm.stopPrank();

        // `claim` needs granted capacity. Issued at the current block, far below REF_TS, so the
        // request-capacity VECTOR still clears the registry's monotonic floor when it lands.
        uint64 seedAt = uint64(block.timestamp);
        reg.requestCapacity(
            CAPACITY_CEILING, seedAt, RegSig.signCapacity(vm, PROVIDER_PK, reg, CAPACITY_CEILING, seedAt)
        );

        jobIdA = keccak256(abi.encodePacked(client, C_A));
        jobIdB = keccak256(abi.encodePacked(client, C_B));
        Order memory a = _orderA();
        // the exact claim pull, cap + feeCap + gasFee, at the constructor's 1% fee. This amount is
        // EMITTED into signing-v3.json: a fee change here re-cuts the vector.
        uint256 cap =
            (uint256(a.rateIn) * a.unitsIn + uint256(a.rateOut) * a.unitsOut + jr.RATE_SCALE() - 1) / jr.RATE_SCALE();
        amountA = cap + cap * jr.feeBps() / 10_000 + jr.gasFee();
    }

    // ===========================================================================================
    // the orders
    // ===========================================================================================

    function _orderA() internal pure returns (Order memory) {
        return Order({
            c: C_A,
            modelId: 1,
            slaSecs: 3600,
            rateIn: 30_000,
            rateOut: 90_000,
            unitsIn: 1000,
            unitsOut: 2000,
            designated: 1,
            expiresAt: EXPIRES_A,
            taskCid: bytes("bafyvorqvectorstaskcid0001")
        });
    }

    function _orderB() internal pure returns (Order memory) {
        return Order({
            c: C_B,
            modelId: 1,
            slaSecs: 86400,
            rateIn: 1,
            rateOut: 1,
            unitsIn: 1,
            unitsOut: 1,
            designated: 0, // open order: 0 is the sentinel for any provider, never a null
            expiresAt: EXPIRES_B,
            taskCid: bytes("bafyvorqvectorstaskcid0002")
        });
    }

    // ===========================================================================================
    // domains
    // ===========================================================================================

    function _domainJson(string memory key) internal view returns (string memory) {
        if (_eq(key, "job_registry")) return VecJson.vorqDomain(jr.EIP712_NAME(), block.chainid, address(jr));
        if (_eq(key, "provider_registry")) return VecJson.vorqDomain(reg.EIP712_NAME(), block.chainid, address(reg));
        if (_eq(key, "ask_registry")) return VecJson.vorqDomain(ar.EIP712_NAME(), block.chainid, address(ar));
        // the payment token's domain is the TOKEN's, not ours: its name and version are read off
        // the deployed USDC rather than transcribed, so an issuer that ships a different version
        // string moves this vector instead of producing signatures the token silently refuses
        if (_eq(key, "payment_token")) {
            return VecJson.fullDomain(IFiatToken(USDC).name(), IFiatToken(USDC).version(), block.chainid, USDC);
        }
        if (_eq(key, "escrow")) return VecJson.bareDomain("VORQ Escrow", "1", block.chainid);
        // The session domain is bound to the deployment's chain. A session is an off-chain auth
        // artifact — never submitted anywhere, verified against a nonce the coordinator minted —
        // and version "1" with no verifyingContract keeps it out of every contract's namespace.
        // It was pinned at 1 until 2026-09-24: a browser wallet refuses to sign a typed-data
        // domain whose chain is not the one it is on, so the pin locked every real wallet out.
        if (_eq(key, "session")) return VecJson.bareDomain("VORQ Session", "1", block.chainid);
        revert(string.concat("unknown domain key: ", key));
    }

    function _separator(string memory key) internal view returns (bytes32) {
        if (_eq(key, "job_registry")) return jr.DOMAIN_SEPARATOR();
        if (_eq(key, "provider_registry")) return reg.DOMAIN_SEPARATOR();
        if (_eq(key, "ask_registry")) return ar.DOMAIN_SEPARATOR();
        if (_eq(key, "payment_token")) return IFiatToken(USDC).DOMAIN_SEPARATOR();
        return bytes32(0); // escrow and session have no contract to answer
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    // ===========================================================================================
    // cases
    // ===========================================================================================

    function _case(
        string memory name,
        string memory domainKey,
        string memory types,
        string memory primaryType,
        string memory message,
        uint256 pk,
        string memory extra
    ) internal view returns (Case memory c) {
        c.name = name;
        c.domainKey = domainKey;
        c.typedData = VecJson.typedData(types, primaryType, _domainJson(domainKey), message);
        c.digest = vm.eip712HashTypedData(c.typedData);
        c.signer = vm.addr(pk);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, c.digest);
        c.signature = abi.encodePacked(r, s, v);
        c.extra = extra;
    }

    function _orderCase(string memory name, Order memory o, bytes32 jobId) internal view returns (Case memory) {
        return _case(
            name,
            "job_registry",
            VecJson.T_ORDER(),
            "Order",
            VecJson.orderMessage(o),
            CLIENT_PK,
            string.concat(
                '{"owner":',
                VecJson.a(client),
                ',"job_id":',
                VecJson.h(jobId),
                ',"task_cid":',
                VecJson.b(o.taskCid),
                ',"task_cid_utf8":',
                VecJson.q(string(o.taskCid)),
                "}"
            )
        );
    }

    function _cases() internal view returns (Case[] memory cs) {
        cs = new Case[](15);
        cs[0] = _orderCase("order-designated", _orderA(), jobIdA);
        cs[1] = _orderCase("order-open", _orderB(), jobIdB);
        cs[2] =
            _case("cancel", "job_registry", VecJson.T_CANCEL(), "Cancel", VecJson.jobOp(jobIdA, REF_TS), CLIENT_PK, "");
        cs[3] = _authCase();
        cs[4] =
            _case("claim", "job_registry", VecJson.T_CLAIM(), "Claim", VecJson.jobOp(jobIdA, REF_TS), PROVIDER_PK, "");
        cs[5] = _case(
            "settle",
            "job_registry",
            VecJson.T_SETTLE(),
            "Settle",
            VecJson.settleMessage(jobIdA, COMPLETION_TOK, REF_TS),
            PROVIDER_PK,
            ""
        );
        cs[6] = _case("fail", "job_registry", VecJson.T_FAIL(), "Fail", VecJson.jobOp(jobIdA, REF_TS), PROVIDER_PK, "");
        cs[7] = _identityCase("set-identity", evidence);
        cs[8] = _identityCase("set-identity-empty-evidence", bytes(""));
        cs[9] = _case(
            "request-capacity",
            "provider_registry",
            VecJson.T_REQUEST_CAPACITY(),
            "RequestCapacity",
            VecJson.capacityMessage(CAPACITY_N, REF_TS),
            PROVIDER_PK,
            ""
        );
        cs[10] = _askCase("ask-snapshot", false);
        cs[11] = _askCase("ask-snapshot-empty", true);
        cs[12] = _releaseCase();
        cs[13] = _handoverAuthCase();
        cs[14] = _sessionCase();
    }

    /// @dev The one case whose type belongs to somebody else: EIP-3009 is the payment token's, and
    /// the client signs it in the TOKEN's domain so only the JobRegistry (`to`) can execute it.
    /// `nonce` is the jobId, which is what makes the authorization single-use per job.
    function _authCase() internal view returns (Case memory) {
        return _case(
            "payment-authorization",
            "payment_token",
            VecJson.T_RECEIVE_AUTH(),
            "ReceiveWithAuthorization",
            VecJson.authMessage(client, address(jr), amountA, EXPIRES_A, jobIdA),
            CLIENT_PK,
            string.concat('{"job_id":', VecJson.h(jobIdA), ',"amount":', VecJson.s(amountA), "}")
        );
    }

    function _identityCase(string memory name, bytes memory ev) internal view returns (Case memory) {
        return _case(
            name,
            "provider_registry",
            VecJson.T_SET_IDENTITY(),
            "SetIdentity",
            VecJson.identityMessage(BOX_KEY, ev, REF_TS),
            PROVIDER_PK,
            string.concat(
                '{"evidence_hash":', VecJson.h(keccak256(ev)), ',"evidence_bytes":', vm.toString(ev.length), "}"
            )
        );
    }

    function _askCase(string memory name, bool empty) internal view returns (Case memory) {
        return _case(
            name,
            "ask_registry",
            VecJson.T_ASK_SNAPSHOT(),
            "AskSnapshot",
            VecJson.askMessage(1, REF_TS, empty),
            PROVIDER_PK,
            ""
        );
    }

    /// @dev No contract verifies a Release, so this case has no acceptance test. Its whole risk is
    /// cross-language — the provider SDK signs it, the coordinator verifies it — and that is
    /// exactly what a vector closes.
    function _releaseCase() internal view returns (Case memory) {
        return _case(
            "release",
            "escrow",
            VecJson.T_RELEASE(),
            "Release",
            VecJson.releaseMessage(jobIdA, bytes("vorq-dek-wrap-vector-0001"), C_B, BOX_KEY, REF_TS),
            PROVIDER_PK,
            ""
        );
    }

    /// @dev Contract-free like Release, and for a sharper reason: both ends are coordinator
    /// instances, so a divergence would show up only as two of *our own* processes refusing each
    /// other during an upgrade — the moment least able to absorb it.
    function _handoverAuthCase() internal view returns (Case memory) {
        return _case(
            "handover-auth",
            "escrow",
            VecJson.T_HANDOVER_AUTH(),
            "HandoverAuth",
            VecJson.handoverAuthMessage(BOX_KEY, REF_TS),
            PROVIDER_PK,
            ""
        );
    }

    /// @dev Also contract-free. Note the member literally named `address` — legal in EIP-712, and
    /// the reason this artifact could never be expressed as a Solidity struct.
    function _sessionCase() internal view returns (Case memory) {
        return _case(
            "session",
            "session",
            VecJson.T_SESSION(),
            "VorqSession",
            VecJson.sessionMessage(client, "vorq-session-nonce-0001"),
            CLIENT_PK,
            ""
        );
    }

    // ===========================================================================================
    // check
    // ===========================================================================================

    function test_VectorsAreCurrent() public view {
        string memory file = vm.readFile(OUT);
        Case[] memory cs = _cases();

        assertEq(vm.parseJsonUint(file, ".chain_id"), block.chainid, "chain id moved");
        assertEq(vm.parseJsonAddress(file, ".addresses.job_registry"), address(jr), "jobRegistry moved");
        assertEq(vm.parseJsonAddress(file, ".addresses.provider_registry"), address(reg), "providerRegistry moved");
        assertEq(vm.parseJsonAddress(file, ".addresses.ask_registry"), address(ar), "askRegistry moved");
        assertEq(vm.parseJsonAddress(file, ".addresses.payment_token"), USDC, "payment token moved");

        for (uint256 i; i < cs.length; i++) {
            string memory at = string.concat(".cases[", vm.toString(i), "]");
            string memory why = string.concat(cs[i].name, ": stale - regenerate with VECTORS_WRITE=1");

            assertEq(vm.parseJsonString(file, string.concat(at, ".name")), cs[i].name, "case order changed");
            assertEq(vm.parseJsonBytes32(file, string.concat(at, ".digest")), cs[i].digest, why);
            assertEq(vm.parseJsonAddress(file, string.concat(at, ".signer")), cs[i].signer, why);
            assertEq(vm.parseJsonBytes(file, string.concat(at, ".signature")), cs[i].signature, why);
            // the signature in the file must recover its own recorded signer over its own recorded
            // digest — a self-contained check a consumer in any language can repeat
            assertEq(
                _recover(cs[i].digest, cs[i].signature), cs[i].signer, string.concat(cs[i].name, ": bad signature")
            );
        }
    }

    /// @dev The same argument as the acceptance tests, one file over. C_A and C_B are a
    /// transcription of the coordinator's container vectors, and every other check in this suite
    /// looks at typehashes, domains, digests and on-chain acceptance — none of them at `c`. So a
    /// stale pair here produces order vectors that no container vector reproduces, and passes.
    /// Read the source file and fail instead.
    function test_TheContainerLinkIsCurrent() public view {
        string memory json = vm.readFile(CONTAINER_VECTORS);

        // Pin the index AND the name together: the index is how the value is read, the name is what
        // makes the index mean something if the cases are ever reordered.
        assertEq(
            vm.parseJsonString(json, ".cases[3].name"),
            "thirty-two-byte-ciphertext",
            "container-v1.json case 3 is no longer thirty-two-byte-ciphertext - C_A names a different case"
        );
        assertEq(
            vm.parseJsonString(json, ".cases[6].name"),
            "long-ciphertext",
            "container-v1.json case 6 is no longer long-ciphertext - C_B names a different case"
        );
        assertEq(
            vm.parseJsonBytes32(json, ".cases[3].c"),
            C_A,
            "C_A is stale - copy .cases[3].c out of the coordinator's container-v1.json and regenerate"
        );
        assertEq(
            vm.parseJsonBytes32(json, ".cases[6].c"),
            C_B,
            "C_B is stale - copy .cases[6].c out of the coordinator's container-v1.json and regenerate"
        );
    }

    /// @dev The committed file, byte for byte, against a fresh generation.
    ///
    /// `test_VectorsAreCurrent` compares the values it knows to look for — digest, signer,
    /// signature — and that leaves a real hole: the `typed_data.types` block is what every
    /// consumer asserts its own table against, and nothing above reads it back. Reorder two
    /// members there and the committed file becomes internally inconsistent while every
    /// value-by-value assertion still passes.
    ///
    /// Both sides are normalised by the SAME `vm.writeJson` in the same run, so this is a byte
    /// comparison without being hostage to Foundry's formatting: a version that pretty-prints
    /// differently moves both sides together.
    function test_TheCommittedFileIsExactlyWhatThisTestGenerates() public {
        string memory fresh = "./vectors/.regenerated.json";
        vm.writeJson(_document(), fresh);
        string memory generated = vm.readFile(fresh);
        vm.removeFile(fresh);

        assertEq(
            vm.readFile(OUT),
            generated,
            "vectors/signing-v3.json is not what the contracts generate - run `make eip712`"
        );
    }

    function test_EveryDomainSeparatorMatchesItsDeployedContract() public view {
        string memory file = vm.readFile(OUT);
        string[4] memory keys = ["job_registry", "provider_registry", "ask_registry", "payment_token"];
        for (uint256 i; i < keys.length; i++) {
            assertEq(
                vm.parseJsonBytes32(file, string.concat(".domains.", keys[i], ".separator")),
                _separator(keys[i]),
                string.concat(keys[i], ": separator is not the deployed contract's")
            );
        }
    }

    function _recover(bytes32 digest, bytes memory sig) internal pure returns (address) {
        bytes32 r;
        bytes32 s;
        assembly {
            r := mload(add(sig, 0x20))
            s := mload(add(sig, 0x40))
        }
        return ecrecover(digest, uint8(sig[64]), r, s);
    }

    // ===========================================================================================
    // acceptance — the link that makes the file non-circular
    //
    // Each signature below was made over the digest `vm.eip712HashTypedData` derived from the
    // PUBLISHED payload. Handing it to the deployed contract asks whether the contract computes
    // that same digest from the same fields. If the published `types` block named a member the
    // contract does not hash, or hashed one it does not, the recovered address would be a stranger
    // and the call would revert. Reaching the end of each test is the proof.
    //
    // No snapshot/revert dance: every test gets fresh state, so the seven vm.snapshotState pairs
    // the old generator needed are gone.
    // ===========================================================================================

    function _sig(string memory name) internal view returns (bytes memory) {
        Case[] memory cs = _cases();
        for (uint256 i; i < cs.length; i++) {
            if (_eq(cs[i].name, name)) return cs[i].signature;
        }
        revert(string.concat("no case named ", name));
    }

    function _postOrderA() internal {
        jr.post(_orderA(), client, _sig("order-designated"), _sig("payment-authorization"));
    }

    function test_PostAndCancelAcceptTheirVectors() public {
        vm.warp(REF_TS);
        _postOrderA();
        jr.cancel(jobIdA, REF_TS, _sig("cancel"));
    }

    /// @dev claim is what hands the authorization to real USDC, so a wrong domain or member
    /// surfaces here as `FiatTokenV2: invalid signature`.
    function test_ClaimAndSettleAcceptTheirVectors() public {
        vm.warp(REF_TS);
        _postOrderA();
        jr.claim(jobIdA, REF_TS, _sig("claim"));
        jr.submitAndSettle(jobIdA, COMPLETION_TOK, bytes("bafyvorqvectorsresultcid01"), REF_TS, _sig("settle"));
    }

    function test_ClaimAndFailAcceptTheirVectors() public {
        vm.warp(REF_TS);
        _postOrderA();
        jr.claim(jobIdA, REF_TS, _sig("claim"));
        jr.fail(jobIdA, REF_TS, _sig("fail"));
    }

    /// @dev The open order carries `designated = 0`, the sentinel for any provider. It reuses the
    /// authorization vector deliberately: `post` parks the authorization but does not spend it, so
    /// what is under test here is the Order signature alone.
    function test_PostAcceptsTheOpenOrderVector() public {
        vm.warp(REF_TS);
        jr.post(_orderB(), client, _sig("order-open"), _sig("payment-authorization"));
    }

    function test_RequestCapacityAcceptsItsVector() public {
        vm.warp(REF_TS);
        reg.requestCapacity(CAPACITY_N, REF_TS, _sig("request-capacity"));
    }

    function test_SetIdentityAcceptsItsVector() public {
        vm.warp(REF_TS);
        reg.setIdentity(BOX_KEY, evidence, REF_TS, _sig("set-identity"));
    }

    /// @dev `keccak256("")` is a real hash, not a zero word. An implementation that special-cases
    /// empty bytes produces a different digest and fails only here.
    function test_SetIdentityAcceptsTheEmptyEvidenceVector() public {
        vm.warp(REF_TS);
        reg.setIdentity(BOX_KEY, bytes(""), REF_TS, _sig("set-identity-empty-evidence"));
    }

    /// @dev `setAsks` never reverts on a bad signature — it `continue`s past the entry. So absence
    /// of a revert proves nothing and the book itself has to be read back. That silent-skip is
    /// exactly why an ask vector is worth more than the hand-written second implementation it
    /// replaces.
    function test_SetAsksAcceptsTheAskSnapshotVector() public {
        vm.warp(REF_TS);

        Ask[] memory quotes = new Ask[](3);
        quotes[0] = Ask({modelId: 1, sla: 3600, rateIn: 30_000, rateOut: 90_000});
        quotes[1] = Ask({modelId: 1, sla: 86400, rateIn: 0, rateOut: 0}); // both zero = withdraw
        quotes[2] = Ask({modelId: 2, sla: 86400, rateIn: 1, rateOut: 0}); // input-only: a LIVE slot

        AskSnapshot[] memory batch = new AskSnapshot[](1);
        batch[0] = AskSnapshot({providerId: 1, signedAt: REF_TS, quotes: quotes});
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _sig("ask-snapshot");

        ar.setAsks(batch, sigs);

        (uint128 rateIn, uint128 rateOut) = ar.getQuote(1, 1, 3600);
        assertEq(rateIn, 30_000, "ask vector was skipped: rateIn not published");
        assertEq(rateOut, 90_000, "ask vector was skipped: rateOut not published");
        assertEq(ar.lastSignedAt(1), REF_TS, "the snapshot did not land");

        // the withdrawal rode in the same snapshot and must leave an empty slot
        (uint128 wIn, uint128 wOut) = ar.getQuote(1, 1, 86400);
        assertEq(wIn, 0, "both-zero did not withdraw the slot");
        assertEq(wOut, 0, "both-zero did not withdraw the slot");

        // and the input-only quote beside it must survive as a published price. This is the pair
        // that pins the sentinel: a consumer reading `rateOut == 0` as "withdraw" deletes this
        // slot, and a consumer reading it as "absent" never offers the model at all.
        (uint128 eIn, uint128 eOut) = ar.getQuote(1, 2, 86400);
        assertEq(eIn, 1, "an input-only ask must publish, not withdraw");
        assertEq(eOut, 0, "and it has no output leg to quote");
    }

    function test_SetAsksAcceptsTheEmptySnapshotVector() public {
        vm.warp(REF_TS);
        AskSnapshot[] memory batch = new AskSnapshot[](1);
        batch[0] = AskSnapshot({providerId: 1, signedAt: REF_TS, quotes: new Ask[](0)});
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _sig("ask-snapshot-empty");

        ar.setAsks(batch, sigs);
        // an empty quotes array hashes to keccak256("") over no element hashes — a real value, and
        // the only evidence it was accepted is the monotonic floor moving
        assertEq(ar.lastSignedAt(1), REF_TS, "the empty snapshot was skipped");
    }

    // ===========================================================================================
    // write
    // ===========================================================================================

    /// @dev The document is assembled as one raw JSON string and handed to `vm.writeJson`, which
    /// parses and pretty-prints it. The `vm.serialize*` builders are not used: they nest a JSON
    /// OBJECT under a key but escape a JSON ARRAY into a string, and `cases` is an array. Building
    /// the text directly also keeps the key order meaningful rather than alphabetical.
    function test_WriteVectors() public {
        if (!vm.envOr("VECTORS_WRITE", false)) return;
        vm.writeJson(_document(), OUT);
    }

    /// @dev The whole file as one raw JSON string, so the write path and the check path cannot
    /// describe different documents.
    function _document() internal view returns (string memory) {
        return string.concat(
            '{"format":"vorq-signing-v3"',
            ',"generated_by":"vorq-evm-contracts/test/Vectors.t.sol"',
            ',"chain_id":',
            VecJson.n(block.chainid),
            ',"addresses":',
            _addressesJson(),
            ',"domains":',
            _domainsJson(),
            ',"cases":',
            _casesJson(),
            "}"
        );
    }

    function _addressesJson() internal view returns (string memory) {
        return string.concat(
            '{"job_registry":',
            VecJson.a(address(jr)),
            ',"provider_registry":',
            VecJson.a(address(reg)),
            ',"ask_registry":',
            VecJson.a(address(ar)),
            ',"payment_token":',
            VecJson.a(USDC),
            "}"
        );
    }

    function _domainsJson() internal view returns (string memory out) {
        string[6] memory keys =
            ["job_registry", "provider_registry", "ask_registry", "payment_token", "escrow", "session"];
        out = "{";
        for (uint256 i; i < keys.length; i++) {
            bytes32 sep = _separator(keys[i]);
            out = string.concat(
                out,
                i == 0 ? "" : ",",
                VecJson.q(keys[i]),
                ':{"domain":',
                _domainJson(keys[i]),
                sep == bytes32(0)
                    // no contract answers a separator for an off-chain artifact; saying so beats
                    // publishing a zero word a consumer might compare against
                    ? ',"separator":null}'
                    : string.concat(',"separator":', VecJson.h(sep), "}")
            );
        }
        out = string.concat(out, "}");
    }

    function _casesJson() internal view returns (string memory out) {
        Case[] memory cs = _cases();
        out = "[";
        for (uint256 i; i < cs.length; i++) {
            out = string.concat(out, i == 0 ? "" : ",", _caseJson(cs[i]));
        }
        out = string.concat(out, "]");
    }

    function _caseJson(Case memory c) internal pure returns (string memory) {
        return string.concat(
            '{"name":',
            VecJson.q(c.name),
            ',"domain":',
            VecJson.q(c.domainKey),
            ',"typed_data":',
            c.typedData,
            ',"digest":',
            VecJson.h(c.digest),
            ',"signer":',
            VecJson.a(c.signer),
            ',"signature":',
            VecJson.b(c.signature),
            bytes(c.extra).length > 0 ? string.concat(',"extra":', c.extra) : "",
            "}"
        );
    }
}
