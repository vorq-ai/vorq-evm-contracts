---
title: Security model
description: Who is trusted, how authority and replay protection work, and what the contracts deliberately leave out.
---

This page explains the design. Reporting, audit status and the list of known issues are in [`SECURITY.md`](https://github.com/vorq-ai/vorq-evm-contracts/blob/main/SECURITY.md).

## Trust assumptions

- **Curation** is one immutable address in `ProviderRegistry` and `JobRegistry`, and is fully trusted. It controls provider registration, listing, capacity ceilings, reputation, the model catalog, the allowlist, fees (protocol fee capped at 10%), allowed SLAs, the treasury, and which `JobRegistry` may move reputation. `AskRegistry` has no curation surface.
- **The payment token** is trusted to behave as described in [Payment token requirements](./payment-token.md).
- **Relayers** have no authority. They can delay, reorder or drop transactions, but cannot change signed terms.
- **Signers** of protocol operations are EOAs. ERC-1271 contract signatures are not supported.

## Authority

No client or provider entry point reads `msg.sender`. Each recovers an EIP-712 signer and refuses `address(0)` before any comparison. Provider operations resolve the signer to a provider id through `ProviderRegistry.idOf`; claimant checks, designation and ask ownership compare ids, not addresses, so they survive an operator key rotation.

`reclaim` is unsigned and permissionless on purpose: a job past its SLA must be resolvable by anyone, so no single party can strand escrow by doing nothing.

Each contract has its own EIP-712 domain name (`VORQ Jobs`, `VORQ Providers`, `VORQ Asks`), so a signature for one contract never verifies at another, even if addresses are misconfigured.

## Replay and freshness

| Types | Rule | Replay guard |
| --- | --- | --- |
| `Claim`, `Settle`, `Fail`, `Cancel` | `issuedAt` within ±600 s of `block.timestamp`, inclusive; otherwise `StaleOp`. | The one-shot job state machine. No nonce. |
| `RequestCapacity`, `SetIdentity` | `issuedAt` above that type's per-provider floor (`lastCapacityAt`, `lastIdentityAt`) and at most `block.timestamp + 3600`; otherwise `StaleOp`. | Per-provider monotonic timestamp, one per type. |
| `AskSnapshot` | `signedAt` above `lastSignedAt[providerId]` and at most `block.timestamp + 3600`; otherwise the entry is skipped. | Per-provider monotonic timestamp. |
| `Order` | No `issuedAt`; bounded by `expiresAt`. | A `jobId` can be posted once. |
| Payment authorization | `nonce = jobId`, `validBefore = expiresAt + 1`. | The token's per-authorizer nonce. |

A signature with a far-future `issuedAt` / `signedAt` blocks further updates of that type until that time passes; the +3600 s ceiling bounds this to one hour.

## Signature format

- Exactly 65 bytes, `r || s || v`, with `v` 27 or 28. Anything else recovers `address(0)` and is refused (a revert, or a skip in `setAsks`).
- Recovery uses `ecrecover` without a low-`s` check, so both the low-`s` and high-`s` form of a signature are accepted. Never use signature bytes as an identifier. Sign with low `s`.

## Unsigned parameters

`taskCid` (in `post`) and `resultCid` (in `submitAndSettle`) are not covered by any signature. Both must be non-empty and are recorded in storage and events, but they are location hints, not attestations.

- Payload integrity rests on `c`. A consumer that fetches the task, recomputes `c`, and checks `keccak256(abi.encodePacked(owner, c)) == jobId` rejects substituted content.
- The result has no on-chain commitment.
- `authSig` in `post` is not covered by `orderSig` either. Anyone can copy a pending `post`, swap `taskCid` or `authSig`, and land it first. No funds are at risk, but the client's `c` is spent. Treat a `c` as used once any `post` for it lands, and re-post with a fresh `c` rather than retrying.

## Ordering and arithmetic

- State and reputation changes precede every token call. A reentrant token sees a terminal row and is refused.
- Narrowing casts are either bounded or guarded (`CapOverflow`).
- `postMany` runs each line as an external self-call. A line that runs out of gas is reported as `PostSkipped` like any other refusal and the transaction succeeds, so size the gas limit for the whole batch.

## Not supported

- ERC-1271 or other contract-account signers for protocol operations.
- Provider stake and slashing; reputation is the only economic signal.
- Multi-signature curation inside the contracts; `curation` is one address.
- Replacing a parked payment authorization.
- Upgradeability; a new `JobRegistry` is a new deployment.
