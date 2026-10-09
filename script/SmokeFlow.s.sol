// SPDX-License-Identifier: FSL-1.1-ALv2
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {JobRegistry} from "../src/JobRegistry.sol";
import {JobState, Order} from "../src/Types.sol";
// the signing recipe is shared with the test suite on purpose: the smoke's job is to prove that the
// same EIP-712 and EIP-3009 spellings the unit tests exercise also land over a real RPC
import {OpSig} from "../test/utils/OpSig.sol";
import {OrderSig} from "../test/utils/OrderSig.sol";
import {AuthSig} from "../test/utils/AuthSig.sol";

/// @notice One post -> claim -> submitAndSettle round trip against a deployed stack. Only the
/// JobRegistry address and the chain id come out of `out-addresses/addresses.json`; every other
/// address and every price constant is read off the registry, so a stale file cannot change what the
/// smoke signs. Every op is signed by its own actor (client: order + authorization; provider
/// operator: claim + settle) and every transaction is sent by the relayer, so the client and
/// provider keys never send anything.
contract SmokeFlow is Script {
    uint32 internal constant COMPLETION_TOK = 1500;
    bytes internal constant RESULT_CID = "bafy-smoke";
    string internal constant ADDRESSES = "./out-addresses/addresses.json";

    function run() external {
        string memory json = vm.readFile(ADDRESSES);
        JobRegistry jr = JobRegistry(vm.parseJsonAddress(json, ".jobRegistry"));
        // The two ways this script gets misaimed are the wrong --rpc-url and an addresses.json left
        // over from a previous anvil. Say so here, instead of failing on an ABI decode of the empty
        // returndata an EOA answers a staticcall with.
        require(
            vm.parseJsonUint(json, ".chainId") == block.chainid,
            "SmokeFlow: addresses.json was written for a different chain - check --rpc-url"
        );
        require(address(jr).code.length > 0, "SmokeFlow: no code at the jobRegistry address - addresses.json is stale");

        Order memory order = _order();
        bytes32 jobId = keccak256(abi.encodePacked(vm.addr(vm.envUint("CLIENT_PK")), order.c));

        _post(jr, order, jobId);
        _claimAndSettle(jr, jobId);

        // This runs in the SIMULATION frame, like every other line of this body: `forge script`
        // executes `run()` once, sends the broadcast transactions afterwards, and never re-runs it.
        // So it proves the flow settles against the state the simulation saw — it is not a
        // post-broadcast confirmation. What proves the on-chain outcome is that forge fails the run
        // when a broadcast transaction reverts, so treat forge's exit status as the gate.
        require(jr.getJob(jobId).state == uint8(JobState.Settled), "SmokeFlow: job did not settle");
    }

    function _order() private view returns (Order memory) {
        return Order({
            // fresh per run: jobId = keccak256(owner, c), so a reused `c` is permanently DuplicateJob
            c: keccak256(abi.encodePacked("vorq-smoke", block.number, block.timestamp)),
            modelId: 1,
            slaSecs: 3600,
            rateIn: 30_000,
            rateOut: 90_000,
            unitsIn: 1000,
            unitsOut: 2000,
            // the seeded provider, matching how a coordinator posts: designation is immutable after
            // post and is what a provider's restart recovery dispatches on
            designated: 1,
            // cast is lossless: a uint64 unix timestamp does not overflow until the year 2554
            expiresAt: uint64(block.timestamp + 3600),
            taskCid: bytes("bafy-smoke-task")
        });
    }

    function _post(JobRegistry jr, Order memory order, bytes32 jobId) private {
        uint256 clientPk = vm.envUint("CLIENT_PK");
        uint256 scale = jr.RATE_SCALE();
        // the authorization must cover exactly what claim pulls: cap + the protocol fee's ceiling on
        // top of it + the gas fee snapshotted at post, where
        // cap = ceilDiv(rateIn*unitsIn + rateOut*unitsOut, RATE_SCALE) = 210 at these rates.
        // No max(1, ...) floor — it cannot bind on a nonzero rate.
        uint256 cap =
            (uint256(order.rateIn) * order.unitsIn + uint256(order.rateOut) * order.unitsOut + scale - 1) / scale;
        uint256 amount = cap + cap * jr.feeBps() / 10000 + jr.gasFee();
        // the token comes off the registry, never out of the json: the authorization is only
        // executable against the token `claim` itself will call, and a mismatch would surface as an
        // invalid-signature revert from deep inside claim rather than as a bad address here
        bytes memory authSig =
            AuthSig.signAuth(vm, clientPk, address(jr.usdc()), address(jr), amount, jobId, order.expiresAt);
        bytes memory orderSig = OrderSig.signOrder(vm, clientPk, jr, order);

        vm.startBroadcast(vm.envUint("DEPLOYER_PK"));
        jr.post(order, vm.addr(clientPk), orderSig, authSig);
        vm.stopBroadcast();
    }

    function _claimAndSettle(JobRegistry jr, bytes32 jobId) private {
        uint256 providerPk = vm.envUint("PROVIDER_PK");
        // cast is lossless: a uint64 unix timestamp does not overflow until the year 2554. Job ops
        // accept issuedAt within +-600 s of the block they land in, so a few blocks of relay lag is
        // well inside the window.
        uint64 issuedAt = uint64(block.timestamp);
        bytes memory claimSig = OpSig.signClaim(vm, providerPk, jr, jobId, issuedAt);
        // RESULT_CID is submitted but not signed — it is not a member of the Settle struct
        bytes memory settleSig = OpSig.signSettle(vm, providerPk, jr, jobId, COMPLETION_TOK, issuedAt);

        vm.startBroadcast(vm.envUint("DEPLOYER_PK"));
        jr.claim(jobId, issuedAt, claimSig);
        jr.submitAndSettle(jobId, COMPLETION_TOK, RESULT_CID, issuedAt, settleSig);
        vm.stopBroadcast();
    }
}
