---
title: Overview
description: What the VORQ contracts on Base do, who uses them, and where to go next.
---

VORQ is a compute job marketplace settled on Base. A client posts a signed order, a registered provider claims it against USDC escrow, and settlement pays out against metered usage. Escrow is pulled with an EIP-3009 `receiveWithAuthorization` the client signed when posting.

Every client and provider action carries an EIP-712 signature from the acting party, never a `msg.sender` check, so any key can relay the transaction. `reclaim` is the one unsigned, permissionless action. Only curation functions and `ProviderRegistry.applyReputationDelta` (callable by an authorised `JobRegistry`) are gated on `msg.sender`.

## Contracts

| Contract | Purpose |
| --- | --- |
| [`JobRegistry`](./reference/job-registry.md) | Job lifecycle and escrow: `post`, `postMany`, `claim`, `submitAndSettle`, `fail`, `reclaim`, `cancel`. Holds the protocol fee, gas fee, allowed SLAs and treasury. |
| [`ProviderRegistry`](./reference/provider-registry.md) | Provider directory (ids, operator keys, listing, capacity, reputation, allowed models, `boxKey`), the model catalog, and the curation allowlist. |
| [`AskRegistry`](./reference/ask-registry.md) | Price book of signed provider quote snapshots. No contract reads it; prices reach a job only through the client-signed `Order`. |

Shared structs and status codes are in [`src/Types.sol`](https://github.com/vorq-ai/vorq-evm-contracts/blob/main/src/Types.sol). Off-chain code signs `Order` and decodes `JobView` in field order, so both are wire format.

## Roles

| Role | Does | Authorised by |
| --- | --- | --- |
| Client (order `owner`) | Signs `Order`, the USDC payment authorization, and `Cancel`. | EIP-712 signature |
| Provider operator | Signs `Claim`, `Settle`, `Fail`, `RequestCapacity`, `SetIdentity`, `AskSnapshot`. Identified on chain by a `uint32` provider id, not by address. | EIP-712 signature, resolved through `ProviderRegistry.idOf` |
| Relayer | Sends transactions that carry other parties' signatures. Has no authority of its own. | none |
| Curation | Registers providers and models; sets listing, capacity ceiling, reputation, fees, allowed SLAs, treasury, allowlist and authorised `JobRegistry` addresses. | `msg.sender == curation` (immutable) |
| Treasury | Receives the protocol fee and the gas fee. | none (payee only) |
| `JobRegistry` | Moves provider reputation on terminal job paths. | `ProviderRegistry.isJobRegistry` |

## Next

- [Quickstart](./quickstart.md): build, test, and read a live deployment.
- [Job lifecycle](./concepts/job-lifecycle.md) and [escrow and fees](./concepts/escrow-and-fees.md): how a job moves and what it pays.
- [Signing](./reference/signing.md): EIP-712 domains, types and the payment authorization.
- [Deployments](./reference/deployments.md): addresses and domain separators.
- [Run the local fork](./guides/run-local-fork.md): a disposable Base Sepolia fork with the contracts deployed.
- [Security model](./concepts/security-model.md) and [`SECURITY.md`](https://github.com/vorq-ai/vorq-evm-contracts/blob/main/SECURITY.md): trust assumptions and known issues.
