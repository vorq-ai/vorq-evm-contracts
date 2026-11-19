---
title: Security model
description: Who is trusted, how authority and replay protection work, and what the contracts deliberately leave out.
---

This page explains the design. Reporting, audit status and the list of known issues are in [`SECURITY.md`](https://github.com/vorq-ai/vorq-evm-contracts/blob/main/SECURITY.md).

## Trust assumptions

- **Curation** is one immutable address in `ProviderRegistry` and `JobRegistry`, and is fully trusted. It controls provider registration, listing, capacity ceilings, reputation, the model catalog, the allowlist, fees (protocol fee capped at 10%), allowed SLAs, the treasury, and which `JobRegistry` may move reputation. `AskRegistry` has no curation surface.
- **The payment token** is trusted to behave as described in [Payment token requirements](./payment-token.md).
- **Relayers** have no authority. They can delay, reorder or drop transactions, but cannot change signed terms. Any relayer can land every op: the one that lands a `claim` earns that job's gas fee, and the one that lands a `deposit` earns its deposit fee.
- **Signers** of protocol operations are EOAs. ERC-1271 contract signatures are not supported. `deposit` refuses an owner with code (`OwnerHasCode`) other than an EIP-7702 delegated EOA.

## Authority

No client or provider entry point is authorised by `msg.sender`; `claim` and `deposit` read it only to record the relayer that earns the fee. Each recovers an EIP-712 signer and refuses `address(0)` before any comparison. Provider operations resolve the signer to a provider id through `ProviderRegistry.idOf`; claimant checks, designation and ask ownership compare ids, not addresses, so they survive an operator key rotation.

`reclaim` is unsigned and permissionless on purpose: a job past its SLA must be resolvable by anyone, so no single party can strand a lock by doing nothing. `payProvider`, `payRelayer` and `payTreasury` are unsigned for the same reason; they can only pay the provider's current operator key, the relayer itself and the treasury. `deposit` is authorised by the owner's EIP-3009 authorization, which the token verifies.

Each contract has its own EIP-712 domain name (`VORQ Jobs`, `VORQ Providers`, `VORQ Asks`), so a signature for one contract never verifies at another, even if addresses are misconfigured.

## Replay and freshness

| Types | Rule | Replay guard |
| --- | --- | --- |
| `Claim`, `Settle`, `Fail`, `Cancel` | `issuedAt` within ±600 s of `block.timestamp`, inclusive; otherwise `StaleOp`. | The one-shot job state machine. No nonce. |
| `Withdraw` | `issuedAt` within ±600 s of `block.timestamp`, inclusive; otherwise `StaleOp`. | Per-owner strictly increasing `issuedAt`. |
| `RequestCapacity`, `SetIdentity` | `issuedAt` above that type's per-provider floor (`lastCapacityAt`, `lastIdentityAt`) and at most `block.timestamp + 3600`; otherwise `StaleOp`. | Per-provider monotonic timestamp, one per type. |
| `AskSnapshot` | `signedAt` above `lastSignedAt[providerId]` and at most `block.timestamp + 3600`; otherwise the entry is skipped. | Per-provider monotonic timestamp. |
| `Order` | No `issuedAt`; bounded by `expiresAt`. | A `jobId` can be claimed or cancelled once. |
| Deposit authorization | the signer's `validBefore`. | The token's per-authorizer nonce. |

A signature with a far-future `issuedAt` / `signedAt` blocks further updates of that type until that time passes; the +3600 s ceiling bounds this to one hour.

## Signature format

- Exactly 65 bytes, `r || s || v`, with `v` 27 or 28. Anything else recovers `address(0)` and is refused (a revert, or a skip in `setAsks`).
- Recovery uses `ecrecover` without a low-`s` check, so both the low-`s` and high-`s` form of a signature are accepted. Never use signature bytes as an identifier. Sign with low `s`.

## Unsigned parameters

`taskCid` (in `claim`) and `resultCid` (in `submitAndSettle`) are not covered by any signature. Both must be non-empty and are announced in `Posted` and `Settled`, but they are location hints, not attestations.

- Payload integrity rests on `c`. A consumer that fetches the task, recomputes `c`, and checks `keccak256(abi.encodePacked(owner, c)) == jobId` rejects substituted content.
- The result has no on-chain commitment.
- Anyone can copy a pending `claim`, swap `taskCid`, and land it first: the job is claimed by the same provider on the same terms, under a wrong announced location. Fetch the payload by the coordinator's record for the `jobId` and verify `c`.
- The relayer is `msg.sender`, not a signed member, so whoever lands a copy of a pending `claim` or `deposit` first earns its gas fee or deposit fee. Submit claims and deposits privately.
- `terms` in `submitAndSettle`, `fail` and `reclaim` is unsigned but bound: it must hash to the row's `termsHash`, fixed at `claim`, so an exit cannot name a different relayer.

## Ordering and arithmetic

- No job operation calls the token. `deposit`, `withdraw`, `payProvider`, `payRelayer` and `payTreasury` write every balance before their one token call.
- Narrowing casts are either bounded or guarded (`CapOverflow`, `BadDepositValue`).

## Not supported

- ERC-1271 or other contract-account signers for protocol operations.
- Provider stake and slashing; reputation is the only economic signal.
- Multi-signature curation inside the contracts; `curation` is one address.
- Upgradeability; a new `JobRegistry` is a new deployment.
