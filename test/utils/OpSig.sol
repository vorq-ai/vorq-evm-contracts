// SPDX-License-Identifier: FSL-1.1-ALv2
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {JobRegistry} from "../../src/JobRegistry.sol";
import {Usage} from "../../src/Types.sol";

// Every JobRegistry op signature, in one place. Each helper reads the
// typehash and the domain separator off the contract instance, so it follows a subclass's domain
// — and so it makes external staticcalls: R1 applies to every call site, never put one of these
// on the line after `vm.expectRevert`.
library OpSig {
    function _sign(Vm vm, uint256 pk, JobRegistry jr, bytes32 structHash) private view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", jr.DOMAIN_SEPARATOR(), structHash)));
        return abi.encodePacked(r, s, v);
    }

    function signClaim(Vm vm, uint256 pk, JobRegistry jr, bytes32 jobId, uint64 issuedAt)
        internal
        view
        returns (bytes memory)
    {
        return _sign(vm, pk, jr, keccak256(abi.encode(jr.CLAIM_TYPEHASH(), jobId, issuedAt)));
    }

    /// @dev deliberately takes NO resultCid: the Settle struct does not carry one, so the digest a
    /// provider signs is independent of the CID the relayer later submits alongside it.
    function signSettle(Vm vm, uint256 pk, JobRegistry jr, bytes32 jobId, Usage memory u, uint64 issuedAt)
        internal
        view
        returns (bytes memory)
    {
        return _sign(
            vm,
            pk,
            jr,
            keccak256(
                abi.encode(
                    jr.SETTLE_TYPEHASH(), jobId, u.promptTok, u.cachedTok, u.completionTok, u.rateInCached, issuedAt
                )
            )
        );
    }

    /// @dev Usage that bills the whole declared input (promptTok clamps to unitsIn), nothing cached,
    /// and `completionTok` out: the charge every pre-metering test was written against.
    function usage(uint32 completionTok) internal pure returns (Usage memory) {
        return Usage({promptTok: type(uint32).max, cachedTok: 0, completionTok: completionTok, rateInCached: 0});
    }

    function signFail(Vm vm, uint256 pk, JobRegistry jr, bytes32 jobId, uint64 issuedAt)
        internal
        view
        returns (bytes memory)
    {
        return _sign(vm, pk, jr, keccak256(abi.encode(jr.FAIL_TYPEHASH(), jobId, issuedAt)));
    }

    function signCancel(Vm vm, uint256 pk, JobRegistry jr, bytes32 jobId, uint64 issuedAt)
        internal
        view
        returns (bytes memory)
    {
        return _sign(vm, pk, jr, keccak256(abi.encode(jr.CANCEL_TYPEHASH(), jobId, issuedAt)));
    }

    function signWithdraw(Vm vm, uint256 pk, JobRegistry jr, uint128 amount, uint64 issuedAt)
        internal
        view
        returns (bytes memory)
    {
        return _sign(vm, pk, jr, keccak256(abi.encode(jr.WITHDRAW_TYPEHASH(), amount, issuedAt)));
    }
}
