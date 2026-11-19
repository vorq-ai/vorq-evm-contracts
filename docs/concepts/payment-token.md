---
title: Payment token requirements
description: What JobRegistry requires of its payment token, and the token-level risks the design accepts.
---

The payment token is a `JobRegistry` constructor argument (`usdc()`). Deployments use USDC (6 decimals). `JobRegistry` calls exactly two token functions:

- `receiveWithAuthorization(address from, address to, uint256 value, uint256 validAfter, uint256 validBefore, bytes32 nonce, bytes signature)`: the EIP-3009 pull at `deposit`, in its `bytes`-signature form.
- `transfer(address, uint256)`: `withdraw`, `payProvider`, `payRelayer` and `payTreasury`.

No job operation calls the token: `claim`, `submitAndSettle`, `fail`, `reclaim` and `cancel` move balances inside the ledger only. There is no `approve` / `transferFrom` path. The client sends no transaction at all; its deposit authorization travels in `deposit` calldata.

## Requirements

The token must:

- implement the EIP-3009 `receiveWithAuthorization` overload above. Only the payee (`to == msg.sender`) may execute it, which is what makes an authorization visible in public calldata safe.
- move exactly the requested amount: no transfer fee, no rebasing. Otherwise the ledger no longer matches the tokens held.
- revert, or return `false`, on a failed `transfer`. A `false` return reverts with `TransferFailed`.

## Accepted risks

- **Blacklist.** A blacklisted client cannot `deposit` or `withdraw`; its balance stays in the ledger and its jobs still settle, fail and reclaim. A blacklisted operator blocks `payProvider` for that provider id until curation rotates its key with `setOperator`; the earnings stay credited to the id. A blacklisted relayer blocks `payRelayer` for that address while the blacklist lasts; its earnings stay credited to the address, which is the only one they are paid to. A blacklisted treasury blocks `payTreasury` until curation calls `setTreasury`; the accrued fees stay credited. No job exit is ever blocked by the token.
- **Pause.** Stops deposits, withdrawals and payouts while it lasts; jobs keep claiming and settling against the ledger, and nothing is stranded permanently.
- **Accounts with code.** `deposit` refuses an owner whose address carries code with `OwnerHasCode`, unless the code is an EIP-7702 delegation designator (`0xef0100 ‖ address`, 23 bytes). The ledger's own signatures (`withdraw`, orders) recover an ECDSA signer only, so a contract wallet's deposit could never leave. USDC validates a delegated EOA's deposit authorization through ERC-1271, so its delegate must implement ERC-1271; one that does not cannot deposit.

The authorization's fields are on [Signing](../reference/signing.md#deposit-authorization-eip-3009); the amount is derived on [Escrow and fees](./escrow-and-fees.md#deposit-authorization).
