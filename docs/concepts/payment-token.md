---
title: Payment token requirements
description: What JobRegistry requires of its payment token, and the token-level risks the design accepts.
---

The payment token is a `JobRegistry` constructor argument (`usdc()`). Deployments use USDC (6 decimals). `JobRegistry` calls exactly two token functions:

- `receiveWithAuthorization(address from, address to, uint256 value, uint256 validAfter, uint256 validBefore, bytes32 nonce, bytes signature)`: the EIP-3009 pull at `claim`, in its `bytes`-signature form.
- `transfer(address, uint256)`: every payout leg.

There is no `approve` / `transferFrom` path. The client sends no transaction at all; its authorization travels in `post` calldata.

## Requirements

The token must:

- implement the EIP-3009 `receiveWithAuthorization` overload above. Only the payee (`to == msg.sender`) may execute it, which is what makes an authorization visible in public calldata safe.
- move exactly the requested amount: no transfer fee, no rebasing. Otherwise escrow conservation breaks.
- revert, or return `false`, on a failed `transfer`. A `false` return reverts with `TransferFailed`.

## Accepted risks

- **Blacklist after claim.** If the client is blacklisted after a claim, `fail` and `reclaim` revert (the client leg is always nonzero), and `submitAndSettle` reverts whenever `cap > charge`. A blacklisted treasury blocks settlement when `fee + gasFeeSnap > 0`, and `fail`/`reclaim` when `gasFeeSnap > 0`. A blacklisted operator blocks settlement only. There is no admin recovery path, so such escrow can stay locked.
- **Pause.** Stops every payout while it lasts; nothing is stranded permanently.
- **Accounts with code.** USDC validates signatures from accounts with code through ERC-1271. A client whose address carries code, such as an EIP-7702 delegation that does not implement ERC-1271, cannot pay.

The authorization's fields are on [Signing](../reference/signing.md#payment-authorization-eip-3009); the amount is derived on [Escrow and fees](./escrow-and-fees.md#payment-authorization-amount).
