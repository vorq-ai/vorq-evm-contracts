---
title: Job lifecycle
description: The job state machine, job ids, ended causes, and the clocks that bound each transition.
---

A job goes on chain when a provider claims it. Until then the client's signed order rests off chain. `claim` carries the order, records the job and locks its funds; the job is then resolved exactly once by `submitAndSettle`, `fail` or `reclaim`. `cancel` ends an order nobody has claimed.

```
                          claim (carries the signed order)
     (no row) ─────────────────────────────────────────► Claimed
         │                                                 │
         │ cancel (owner-signed)                           ├─ submitAndSettle ─► Settled
         ▼                                                 │       state 2, endedBecause 1
     Cancelled                                             ├─ fail (provider-signed) ─► Cancelled
     state 3, endedBecause 2                               │       state 3, endedBecause 3
                                                           └─ reclaim (anyone, past the SLA) ─► Cancelled
                                                                   state 3, endedBecause 4
```

`JobState` values: `0 Open`, `1 Claimed`, `2 Settled`, `3 Cancelled`. `Open` is the state of an id with no row: `getJob` answers `found: false`. `cancel`, `fail` and `reclaim` all end in `Cancelled`; `endedBecause` tells them apart.

## The row

One storage slot per job, written at `claim` (or at `cancel`, for an order never claimed): `providerId`, `claimedAt`, `state`, `endedBecause` and `termsHash`. `getJob` returns the first four.

`termsHash` is the first 21 bytes of `keccak256(abi.encode(terms))`, where `terms` is what the exits price:

```
Terms { owner, rateIn, rateOut, unitsIn, unitsOut, slaSecs, gasFee, relayer }
```

`gasFee` is the value live at the claim. `relayer` is the claim's sender: any relayer can land every op, and the one that lands the claim earns the job's gas fee at the exit, whoever lands the exit. `submitAndSettle`, `fail` and `reclaim` take `terms` as an argument and revert `TermsMismatch` unless it reproduces the row's hash. Everything else about a job is in its events: `Posted` carries the full order (owner, `c`, model, designation, rates, units, SLA, expiry, gas fee, `taskCid`), `Claimed` the provider, the relayer and the claim time, and `Settled` carries the delivered counts, the fee taken and `resultCid`.

## Job ids

`jobId = keccak256(abi.encodePacked(owner, c))`, where `c` is the client's 32-byte commitment to the task payload. Rows are never deleted, so an id that has been claimed or cancelled is spent for good: a second `claim` reverts `NotOpen`. The persistent terminal row is also the replay guard for every job operation.

The task location (`taskCid`) and the result location (`resultCid`) are unsigned call parameters announced in `Posted` and `Settled`. Only `c` binds the payload; see [Security model](./security-model.md#unsigned-parameters).

## Ended causes

| Code | Constant | With state | Where it appears |
| --- | --- | --- | --- |
| 0 | `ENDED_NONE` | `Claimed` | live job |
| 1 | `ENDED_SETTLED` | `Settled` | `getJob` only; settlement emits `Settled`, not `Ended` |
| 2 | `ENDED_CANCELLED` | `Cancelled` | stored; `Ended(jobId, 2)` |
| 3 | `ENDED_PROVIDER_FAIL` | `Cancelled` | stored; `Ended(jobId, 3)` |
| 4 | `ENDED_RECLAIM` | `Cancelled` | stored; `Ended(jobId, 4)` |
| 5 | `ENDED_EXPIRED` | — | off chain only: an order that expired unclaimed has no row |

## Clocks

| Clock | Rule |
| --- | --- |
| Expiry | `claim` requires `block.timestamp <= expiresAt <= block.timestamp + MAX_EXPIRY` (86,400 s): an order past `expiresAt` cannot be claimed (`AlreadyExpired`), and a claim landing exactly at `expiresAt` succeeds. |
| SLA | The deadline is `claimedAt + slaSecs`. `submitAndSettle` is refused after it (`SlaExpired`); `reclaim` is allowed only after it (`SlaNotExpired` before). `slaSecs` must be allowed at `claim` (the constructor allows 3600 and 86400). |
| Fail grace | `FAIL_GRACE` = 300 s. A `fail` landing at or before `claimedAt + 300` costs no reputation; later it costs 40. Measured at landing time, not at `issuedAt`. |
| Op freshness | `Claim`, `Settle`, `Fail`, `Cancel` and `Withdraw` require `issuedAt` within ±600 s of `block.timestamp`, inclusive (`StaleOp` otherwise). |

`fail` is not bounded by the SLA. After the SLA it races `reclaim`; the release and the penalty are identical and only the cause (3 or 4) differs.

## Who can move a job

| Transition | Authorised by | Notes |
| --- | --- | --- |
| `claim` | the client's `Order` signature and the operator's `Claim` signature | Order: non-empty `taskCid`, allowed SLA, expiry window, model exists and is enabled, signature recovers `owner`, no row for the id. Provider: fresh, listed, allowed the model, matches `designated` if nonzero, under `effectiveCap`. Then the lock must fit the owner's balance (`InsufficientDeposit`). |
| `submitAndSettle` | `Settle` signature from the claiming provider | Compared by provider id, so a key rotated after the claim still settles. |
| `fail` | `Fail` signature from the claiming provider | Same id comparison. |
| `reclaim` | nobody | Anyone, strictly after the SLA. |
| `cancel` | owner's `Cancel` signature | An order with no row gets a `Cancelled` row, so it can never be claimed. A no-op on an already `Settled` or `Cancelled` job; `NotCancellable` on `Claimed`. |

When `designated == 0`, any eligible provider can claim, and a `fail` within the grace window costs that provider nothing. The job ends with the client's lock released less the gas fee, and the id spent.

Funds for each transition are on [Escrow and fees](./escrow-and-fees.md). Check order and revert behaviour for each function are on the [JobRegistry reference](../reference/job-registry.md).
