// SPDX-License-Identifier: FSL-1.1-ALv2
pragma solidity 0.8.30;

import {ProviderRegistry} from "../../src/ProviderRegistry.sol";

/// @notice Makes the zero address resolve to a real, listed provider id — the one state the public
/// API cannot reach, because `register` and `setOperator` both revert `ZeroOperator()` on a zero
/// address (R15's first bullet). It is the only way to discriminate R15's second bullet: every
/// signed entry point's *explicit* `signer == address(0)` refusal. Against a normal registry that
/// guard is invisible, since `idOf[address(0)]` is 0 and the following "unknown provider" check
/// answers the same error anyway. Forced into this state, deleting the guard turns a 65-zero-byte
/// signature into a live authentication as that provider.
/// @dev One double, four call sites, no per-suite subclass — the forced state and the
/// `forceZeroSignerRecord(uint32)` shape are identical for all of them:
/// `ProviderRegistry.requestCapacity` (`ProviderRegistry.t.sol`),
/// `ProviderRegistry.setIdentity` (`ProviderRegistryCuration.t.sol`),
/// `JobRegistry.claim` (`JobRegistryClaim.t.sol`) and `JobRegistry.submitAndSettle`
/// (`JobRegistrySettle.t.sol`). The two JobRegistry suites stand up their own `JobRegistry` around
/// this instance. Task 7's `fail` needs the same state and should import this, not fork it.
contract ZeroSignerRegistry is ProviderRegistry {
    constructor(address curation_) ProviderRegistry(curation_) {}

    function forceZeroSignerRecord(uint32 id) external {
        idOf[address(0)] = id;
    }
}

/// @notice Signals failure the way an ERC-20 is allowed to: `transfer` returns false instead of
/// reverting. The pull leg funds normally, so `_pay`'s return-value check is the only thing standing
/// between a false payout and a settled row. Real USDC reverts and can never produce this.
contract FalseTransferToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function receiveWithAuthorization(address from, address to, uint256 value, uint256, uint256, bytes32, bytes memory)
        external
    {
        balanceOf[from] -= value;
        balanceOf[to] += value;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return false; // the whole point
    }
}
