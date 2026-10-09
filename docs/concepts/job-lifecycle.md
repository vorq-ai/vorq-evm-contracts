---
title: Job lifecycle
description: The job state machine, job ids, ended causes, and the clocks that bound each transition.
---

A job lives in `JobRegistry`. It is created by `post`, funded by `claim`, and resolved exactly once by `submitAndSettle`, `fail`, `reclaim` or `cancel`.

```
                   post                 claim
     (absent) ──────────────► Open ──────────────► Claimed
                               │                     │
        cancel (owner-signed)  │                     ├─ submitAndSettle ─► Settled
                               ▼                     │       state 2, endedBecause 1
                        Cancelled                    ├─ fail (provider-signed) ─► Cancelled
                        state 3, endedBecause 2      │       state 3, endedBecause 3
                                                     └─ reclaim (anyone, past the SLA) ─► Cancelled
                                                             state 3, endedBecause 4
```

`JobState` values: `0 Open`, `1 Claimed`, `2 Settled`, `3 Cancelled`. `cancel`, `fail` and `reclaim` all end in `Cancelled`; `endedBecause` tells them apart.

## Job ids

`jobId = keccak256(abi.encodePacked(owner, c))`, where `c` is the client's 32-byte commitment to the task payload. Rows are never deleted, so a `c` that has been posted once is spent for that owner: a second `post` reverts `DuplicateJob`. The persistent terminal row is also the replay guard for every job operation.

The task location (`taskCid`) and the result location (`resultCid`) are unsigned call parameters recorded on the row. Only `c` binds the payload; see [Security model](./security-model.md#unsigned-parameters).

## Ended causes

| Code | Constant | With state | Where it appears |
| --- | --- | --- | --- |
| 0 | `ENDED_NONE` | `Open` or `Claimed` | live job |
| 1 | `ENDED_SETTLED` | `Settled` | `getJob` only; settlement emits `Settled`, not `Ended` |
| 2 | `ENDED_CANCELLED` | `Cancelled` | stored; `Ended(jobId, 2)` |
| 3 | `ENDED_PROVIDER_FAIL` | `Cancelled` | stored; `Ended(jobId, 3)` |
| 4 | `ENDED_RECLAIM` | `Cancelled` | stored; `Ended(jobId, 4)` |
| 5 | `ENDED_EXPIRED` | `Cancelled` | `getJob` only; computed at read time |

An `Open` job past `expiresAt` reads as `Cancelled` / `5` from `getJob` with no transaction. Storage still says `Open`, and the job can still be cancelled; a landed `cancel` stores `2`, which then replaces the computed `5`.

## Clocks

| Clock | Rule |
| --- | --- |
| Expiry | `post` requires `block.timestamp < expiresAt <= block.timestamp + MAX_EXPIRY` (86,400 s). A job is expired when `block.timestamp > expiresAt`; a `claim` landing exactly at `expiresAt` succeeds. |
| SLA | The deadline is `claimedAt + slaSecs`. `submitAndSettle` is refused after it (`SlaExpired`); `reclaim` is allowed only after it (`SlaNotExpired` before). `slaSecs` must be allowed at `post` (the constructor allows 3600 and 86400). |
| Fail grace | `FAIL_GRACE` = 300 s. A `fail` landing at or before `claimedAt + 300` costs no reputation; later it costs 40. Measured at landing time, not at `issuedAt`. |
| Op freshness | `Claim`, `Settle`, `Fail` and `Cancel` require `issuedAt` within ±600 s of `block.timestamp`, inclusive (`StaleOp` otherwise). |

`fail` is not bounded by the SLA. After the SLA it races `reclaim`; payout and penalty are identical and only the cause (3 or 4) differs.

## Who can move a job

| Transition | Authorised by | Notes |
| --- | --- | --- |
| `post` | client's `Order` signature | Checks the SLA, expiry window, model exists and is enabled. `designated` is not checked here. |
| `claim` | operator's `Claim` signature | Provider must be listed, allowed the model, match `designated` if nonzero, and be under `effectiveCap`. The model's enabled flag is not re-checked, so jobs posted before a model is disabled can still be claimed. |
| `submitAndSettle` | `Settle` signature from the claiming provider | Compared by provider id, so a key rotated after the claim still settles. |
| `fail` | `Fail` signature from the claiming provider | Same id comparison. |
| `reclaim` | nobody | Anyone, strictly after the SLA. |
| `cancel` | owner's `Cancel` signature | `Open` only. A no-op on an already `Settled` or `Cancelled` job; `NotCancellable` on `Claimed`. |

When `designated == 0`, any eligible provider can claim, and a `fail` within the grace window costs that provider nothing. The job ends with the client refunded less the gas fee, and `c` spent.

Funds for each exit are on [Escrow and fees](./escrow-and-fees.md). Check order and revert behaviour for each function are on the [JobRegistry reference](../reference/job-registry.md).
