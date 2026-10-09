// SPDX-License-Identifier: FSL-1.1-ALv2
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {JobRegistry, IUSDC} from "../src/JobRegistry.sol";
import {ProviderRegistry} from "../src/ProviderRegistry.sol";
import "../src/Types.sol";
import {OrderSig} from "./utils/OrderSig.sol";

/// `postMany` is the batch surface's landing door: one transaction, N independent orders, each
/// authored by its own signature. It skips rather than reverts (the `setAsks` rule), because a
/// 50k-line batch must not die on one bad line.
contract JobRegistryPostManyTest is Test {
    JobRegistry jr;
    ProviderRegistry reg;
    address curation = makeAddr("curation");
    uint256 clientPk = 0xC11E47;
    address client;

    function setUp() public {
        client = vm.addr(clientPk);
        reg = new ProviderRegistry(curation);
        jr = new JobRegistry(reg, IUSDC(makeAddr("usdc")), curation, makeAddr("treasury"));
        vm.prank(curation);
        reg.setJobRegistry(address(jr), true);
        vm.prank(curation);
        reg.registerModel("model-a:fp8"); // modelId 1
    }

    function orderWith(bytes32 c) internal view returns (Order memory o) {
        o = Order({
            c: c,
            modelId: 1,
            slaSecs: 3600,
            rateIn: 30_000,
            rateOut: 90_000,
            unitsIn: 1000,
            unitsOut: 2000,
            designated: 0,
            expiresAt: uint64(block.timestamp + 3600),
            taskCid: bytes("bafy-task")
        });
    }

    /// Build `n` distinct lines, all signed by `client`.
    function lines(uint256 n)
        internal
        view
        returns (Order[] memory orders, address[] memory owners, bytes[] memory sigs, bytes[] memory auths)
    {
        orders = new Order[](n);
        owners = new address[](n);
        sigs = new bytes[](n);
        auths = new bytes[](n);
        for (uint256 i; i < n; i++) {
            orders[i] = orderWith(keccak256(abi.encodePacked("line", i)));
            owners[i] = client;
            sigs[i] = OrderSig.signOrder(vm, clientPk, jr, orders[i]);
            auths[i] = "";
        }
    }

    function jobIdOf(address owner, Order memory o) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(owner, o.c));
    }

    function test_postMany_lands_every_line_in_one_transaction() public {
        (Order[] memory orders, address[] memory owners, bytes[] memory sigs, bytes[] memory auths) = lines(3);

        jr.postMany(orders, owners, sigs, auths);

        for (uint256 i; i < 3; i++) {
            JobView memory v = jr.getJob(jobIdOf(client, orders[i]));
            assertTrue(v.found, "every line lands");
            assertEq(uint8(v.state), 0, "Open");
            assertEq(v.owner, client);
        }
    }

    /// The whole reason this door is not a loop over `post`: a 50k-line batch cannot die on line 1.
    function test_postMany_skips_a_bad_line_and_lands_its_neighbours() public {
        (Order[] memory orders, address[] memory owners, bytes[] memory sigs, bytes[] memory auths) = lines(3);
        // Line 1 is signed by somebody who is not its declared owner, so `post` answers
        // InvalidOrderSignature for it and for it alone.
        (, uint256 strangerPk) = makeAddrAndKey("stranger");
        sigs[1] = OrderSig.signOrder(vm, strangerPk, jr, orders[1]);

        jr.postMany(orders, owners, sigs, auths);

        assertTrue(jr.getJob(jobIdOf(client, orders[0])).found, "line 0 lands");
        assertFalse(jr.getJob(jobIdOf(client, orders[1])).found, "line 1 is skipped");
        assertTrue(jr.getJob(jobIdOf(client, orders[2])).found, "line 2 lands past the skip");
    }

    /// A skip is a receipt, never a silence: the index and the gate that refused it.
    function test_postMany_announces_the_skipped_index_and_the_gate_that_refused_it() public {
        (Order[] memory orders, address[] memory owners, bytes[] memory sigs, bytes[] memory auths) = lines(2);
        (, uint256 strangerPk) = makeAddrAndKey("stranger");
        sigs[1] = OrderSig.signOrder(vm, strangerPk, jr, orders[1]);

        vm.expectEmit(true, true, true, true);
        emit JobRegistry.PostSkipped(1, abi.encodeWithSelector(JobRegistry.InvalidOrderSignature.selector));
        jr.postMany(orders, owners, sigs, auths);
    }

    /// A duplicate `c` is the skip a batch actually hits — a resubmitted line, not a forged one.
    function test_postMany_skips_a_duplicate_job_without_disturbing_the_landed_one() public {
        (Order[] memory orders, address[] memory owners, bytes[] memory sigs, bytes[] memory auths) = lines(2);
        orders[1] = orders[0]; // same owner, same commitment => same jobId
        sigs[1] = sigs[0];

        vm.expectEmit(true, true, true, true);
        emit JobRegistry.PostSkipped(1, abi.encodeWithSelector(JobRegistry.DuplicateJob.selector));
        jr.postMany(orders, owners, sigs, auths);

        assertTrue(jr.getJob(jobIdOf(client, orders[0])).found, "the first landing stands");
    }

    /// Ragged arrays are a malformed call, not a bad line — there is no per-line receipt for it.
    function test_postMany_refuses_ragged_arrays() public {
        (Order[] memory orders, address[] memory owners, bytes[] memory sigs, bytes[] memory auths) = lines(2);
        bytes[] memory shortSigs = new bytes[](1);
        shortSigs[0] = sigs[0];

        vm.expectRevert(JobRegistry.LengthMismatch.selector);
        jr.postMany(orders, owners, shortSigs, auths);
    }

    /// Relay confers nothing and takes nothing away: the self-call inside `postMany` rewrites
    /// `msg.sender`, and every line still lands because authority is the order signature alone.
    function test_postMany_lands_orders_owned_by_someone_other_than_the_sender() public {
        (uint256 otherPk) = 0xBEEF;
        address other = vm.addr(otherPk);
        Order[] memory orders = new Order[](2);
        address[] memory owners = new address[](2);
        bytes[] memory sigs = new bytes[](2);
        bytes[] memory auths = new bytes[](2);

        orders[0] = orderWith(keccak256("from-client"));
        owners[0] = client;
        sigs[0] = OrderSig.signOrder(vm, clientPk, jr, orders[0]);

        orders[1] = orderWith(keccak256("from-other"));
        owners[1] = other;
        sigs[1] = OrderSig.signOrder(vm, otherPk, jr, orders[1]);

        vm.prank(makeAddr("relayer"));
        jr.postMany(orders, owners, sigs, auths);

        assertEq(jr.getJob(jobIdOf(client, orders[0])).owner, client);
        assertEq(jr.getJob(jobIdOf(other, orders[1])).owner, other);
    }
}
