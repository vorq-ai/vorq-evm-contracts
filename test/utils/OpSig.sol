// SPDX-License-Identifier: FSL-1.1-ALv2
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {JobRegistry} from "../../src/JobRegistry.sol";

// Every JobRegistry job-op signature, in one place (Tasks 5-8 share it). Each helper reads the
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
    function signSettle(Vm vm, uint256 pk, JobRegistry jr, bytes32 jobId, uint32 completionTok, uint64 issuedAt)
        internal
        view
        returns (bytes memory)
    {
        return _sign(vm, pk, jr, keccak256(abi.encode(jr.SETTLE_TYPEHASH(), jobId, completionTok, issuedAt)));
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
}
