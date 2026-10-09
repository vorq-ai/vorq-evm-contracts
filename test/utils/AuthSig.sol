// SPDX-License-Identifier: FSL-1.1-ALv2
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {IFiatToken} from "./BaseFork.sol";

// Client-side EIP-3009 authorization. The typehash is spelled out here rather than read off the
// token, so a claim only lands if this spelling and the token's agree.
library AuthSig {
    bytes32 constant RECEIVE_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );

    /// @dev nonce = jobId and validBefore = expiresAt + 1, exactly as JobRegistry._pullEscrow spends it
    function signAuth(Vm vm, uint256 pk, address usdc, address to, uint256 value, bytes32 jobId, uint256 expiresAt)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash =
            keccak256(abi.encode(RECEIVE_TYPEHASH, vm.addr(pk), to, value, uint256(0), expiresAt + 1, jobId));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", IFiatToken(usdc).DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }
}
