// SPDX-License-Identifier: FSL-1.1-ALv2
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import "../src/Types.sol";

contract TypesTest is Test {
    function test_ended_vocabulary_is_stable() public pure {
        assertEq(ENDED_SETTLED, 1);
        assertEq(ENDED_CANCELLED, 2);
        assertEq(ENDED_PROVIDER_FAIL, 3);
        assertEq(ENDED_RECLAIM, 4);
        assertEq(ENDED_EXPIRED, 5);
    }

    function test_state_order_matches_spec() public pure {
        assertEq(uint8(JobState.Open), 0);
        assertEq(uint8(JobState.Cancelled), 3);
    }
}
