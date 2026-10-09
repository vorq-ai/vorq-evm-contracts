// SPDX-License-Identifier: FSL-1.1-ALv2
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {AskRegistry} from "../../src/AskRegistry.sol";
import {Ask, AskSnapshot} from "../../src/Types.sol";

// The AskSnapshot signature, in one place. Reads both typehashes and the domain separator off the
// contract instance, so it follows a subclass's domain — and so it makes external staticcalls: R1
// applies to every call site, never put one of these on the line after `vm.expectRevert`.
library AskSig {
    function signSnapshot(Vm vm, uint256 pk, AskRegistry ar, AskSnapshot memory s)
        internal
        view
        returns (bytes memory)
    {
        bytes32[] memory quoteHashes = new bytes32[](s.quotes.length);
        for (uint256 i; i < s.quotes.length; i++) {
            Ask memory a = s.quotes[i];
            quoteHashes[i] = keccak256(abi.encode(ar.ASK_TYPEHASH(), a.modelId, a.sla, a.rateIn, a.rateOut));
        }
        bytes32 structHash = keccak256(
            abi.encode(ar.SNAPSHOT_TYPEHASH(), s.providerId, s.signedAt, keccak256(abi.encodePacked(quoteHashes)))
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", ar.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s2) = vm.sign(pk, digest);
        return abi.encodePacked(r, s2, v);
    }
}
