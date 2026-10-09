// SPDX-License-Identifier: FSL-1.1-ALv2
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {JobRegistry} from "../../src/JobRegistry.sol";
import {Order} from "../../src/Types.sol";

library OrderSig {
    function orderDigest(JobRegistry jr, Order memory o) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                jr.ORDER_TYPEHASH(),
                o.c,
                o.modelId,
                o.slaSecs,
                o.rateIn,
                o.rateOut,
                o.unitsIn,
                o.unitsOut,
                o.designated,
                o.expiresAt
            ) // taskCid is NOT a member: the client cannot know the CID when it signs
        );
        return keccak256(abi.encodePacked("\x19\x01", jr.DOMAIN_SEPARATOR(), structHash));
    }

    function signOrder(Vm vm, uint256 pk, JobRegistry jr, Order memory o) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, orderDigest(jr, o));
        return abi.encodePacked(r, s, v);
    }
}
