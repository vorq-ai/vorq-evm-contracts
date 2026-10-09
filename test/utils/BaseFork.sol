// SPDX-License-Identifier: FSL-1.1-ALv2
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

/// @notice The read side of Circle's FiatToken that the suites assert through.
interface IFiatToken {
    function balanceOf(address) external view returns (uint256);
    function authorizationState(address authorizer, bytes32 nonce) external view returns (bool);
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function name() external view returns (string memory);
    function version() external view returns (string memory);
    function decimals() external view returns (uint8);
}

/// @notice Every suite that moves money runs on a fork of Base Sepolia at one pinned block, against
/// the real USDC. The pin is what makes Foundry's RPC cache effective, so after the first run the
/// suite is offline. It is the only pin: `fork/docker-compose.yml` and
/// `meta-sdk/e2e/docker-compose.yml` fork near head at start, because a stack that boots from a
/// public non-archive endpoint cannot depend on a block that endpoint will one day prune. Bump this
/// number only when the upstream no longer serves its state; nothing else moves with it.
abstract contract BaseFork is Test {
    address internal constant USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    uint256 internal constant FORK_BLOCK = 47_121_000;

    function _fork() internal {
        vm.createSelectFork("base_sepolia", FORK_BLOCK);
    }
}
