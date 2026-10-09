---
title: Escrow and fees
description: How a job's cap, charge, protocol fee and gas fee are computed, pulled and paid out.
---

## Rates and units

An order carries `rateIn` and `rateOut` (`uint128`) and `unitsIn` and `unitsOut` (`uint32`). Rates are in atomic payment-token units per unit, multiplied by `RATE_SCALE` = 1,000,000. With USDC (6 decimals), a `rateOut` of 1,000,000 is 1 atomic unit (0.000001 USDC) per output unit.

## Formulas

```
cap    = max(1, ceilDiv(rateIn·unitsIn + rateOut·unitsOut, RATE_SCALE))
tok    = min(completionTok, unitsOut)
charge = min(cap, max(1, ceilDiv(rateIn·unitsIn + rateOut·tok, RATE_SCALE)))
feeCap = floor(cap · feeBps / 10000)
fee    = floor(charge · feeBps / 10000)          // fee <= feeCap
```

- `cap` is computed at `claim`. A `cap` that does not fit `uint128` reverts `CapOverflow`. A zero-priced order still escrows 1 atomic unit.
- `unitsOut` is a ceiling: the provider reports `completionTok` at settlement and is paid for at most `unitsOut`. The stored `completionTok` is the clamped `tok`.
- `unitsIn` is charged in full.

## The escrow

`claim` pulls `cap + feeCap + gasFeeSnap` from the client once, by executing the payment authorization parked at `post`. `gasFeeSnap` is `gasFee` as of `post`. The escrow resolves once:

| Exit | Operator | Treasury | Client |
| --- | --- | --- | --- |
| `submitAndSettle` | `charge` | `fee + gasFeeSnap` | `(cap − charge) + (feeCap − fee)` |
| `fail` | — | `gasFeeSnap` | `cap + feeCap` |
| `reclaim` | — | `gasFeeSnap` | `cap + feeCap` |
| `cancel` (from `Open`) | — | — | nothing was pulled |

- Each funded exit pays out exactly `cap + feeCap + gasFeeSnap`, provided `feeBps` has not changed since the claim.
- The gas fee goes to the treasury on every funded exit, including `fail` and `reclaim`. The protocol fee is only taken at settlement.
- Zero legs are skipped.
- The operator leg goes to `operatorOf(providerId)` as resolved at settlement, not to the key that signed or sent the settle.

`Posted` and `JobView` carry `gasFeeSnap` as `gasFee`, and `Settled` carries the protocol fee taken as `fee`. `capOf(jobId)` returns `cap` only.

## Fee parameters

| Parameter | Set by | Initial | Bounds | Read when |
| --- | --- | --- | --- | --- |
| `feeBps` | `setFees` (curation) | 100 (1%) | ≤ 1000 (10%), else `FeeTooHigh` | live, at `claim` and again at the exit |
| `gasFee` | `setFees` (curation) | 30000 ($0.03) | none | at `post`, snapshotted per job |

There is no per-job `feeBps` snapshot, so a fee change affects work in flight:

- A job claimed under one `feeBps` and resolved under another pays out a different total than it pulled.
- An order posted but not yet claimed when `feeBps` changes can no longer be claimed: its payment authorization was signed for the old amount, and the token rejects it inside `claim`.

Read the live values from the contract; do not copy them. See [Read contract state with cast](../guides/read-state-with-cast.md#read-configuration).

## Payment authorization amount

The client signs a USDC `ReceiveWithAuthorization` for exactly the amount `claim` will pull:

```
value = cap + floor(cap · feeBps / 10000) + gasFee
```

`gasFee` must be the value at the moment `post` lands, and `feeBps` the value at the moment `claim` lands. The full field list is on [Signing](../reference/signing.md#payment-authorization-eip-3009).
