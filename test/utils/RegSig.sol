// SPDX-License-Identifier: FSL-1.1-ALv2
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {ProviderRegistry} from "../../src/ProviderRegistry.sol";

// Every ProviderRegistry registry-op signature, in one place — the counterpart to OpSig for job
// ops. It exists because the RequestCapacity digest was previously spelled out three times (both
// registry suites and JobHarness); three copies that each read the typehash off the contract drift
// silently, since a wrong type string round-trips through every test that signs with it.
// Each helper reads the typehash and the domain separator off the contract instance, so it follows a
// subclass's domain — and so it makes external staticcalls: R1 applies to every call site, never put
// one of these on the line after `vm.expectRevert`.
library RegSig {
    function _sign(Vm vm, uint256 pk, ProviderRegistry reg, bytes32 structHash) private view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", reg.DOMAIN_SEPARATOR(), structHash)));
        return abi.encodePacked(r, s, v);
    }

    function signCapacity(Vm vm, uint256 pk, ProviderRegistry reg, uint32 n, uint64 issuedAt)
        internal
        view
        returns (bytes memory)
    {
        return _sign(vm, pk, reg, keccak256(abi.encode(reg.REQUEST_CAPACITY_TYPEHASH(), n, issuedAt)));
    }

    function signIdentity(
        Vm vm,
        uint256 pk,
        ProviderRegistry reg,
        bytes32 boxKey,
        bytes memory evidence,
        uint64 issuedAt
    ) internal view returns (bytes memory) {
        // evidence is hashed inside the struct hash, per the EIP-712 rule for dynamic bytes
        return
            _sign(
                vm, pk, reg, keccak256(abi.encode(reg.SET_IDENTITY_TYPEHASH(), boxKey, keccak256(evidence), issuedAt))
            );
    }
}
