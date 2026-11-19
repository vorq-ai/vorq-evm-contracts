---
title: Escrow and fees
description: The prepaid balance, how a job's cap, charge, protocol fee and gas fee are computed, locked and credited, who earns each fee, and how payouts leave the contract.
---

## Rates and units

An order carries `rateIn` and `rateOut` (`uint128`) and `unitsIn` and `unitsOut` (`uint32`). Rates are in atomic payment-token units per unit, multiplied by `RATE_SCALE` = 1,000,000. With USDC (6 decimals), a `rateOut` of 1,000,000 is 1 atomic unit ($0.000001) per output unit.

## Formulas

```
cap    = max(1, ceilDiv(rateIn·unitsIn + rateOut·unitsOut, RATE_SCALE))
p      = min(promptTok, unitsIn)
k      = min(cachedTok, p)
r      = min(rateInCached, rateIn)
tok    = min(completionTok, unitsOut)
charge = min(cap, max(1, ceilDiv(rateIn·(p−k) + r·k + rateOut·tok, RATE_SCALE)))
feeCap = floor(cap · feeBps / 10000)
fee    = floor(charge · feeBps / 10000)          // fee <= feeCap
lock   = cap + feeCap + gasFee
```

- `cap` is computed at `claim`. A `cap` that does not fit `uint128` reverts `CapOverflow`. A zero-priced order still locks 1 atomic unit.
- `unitsIn` and `unitsOut` are ceilings. At settlement the provider reports the backend's own counts: `promptTok`, the `cachedTok` part of it, and `completionTok`. It is paid for at most `unitsIn` and `unitsOut`. `Settled` carries the clamped counts.
- `cachedTok` is charged at the provider's `rateInCached`, which can never exceed the order's `rateIn`.

## The ledger

`JobRegistry` holds every client's prepaid balance, every live lock, every provider's unpaid earnings, every relayer's unpaid gas and deposit fees and the treasury's unpaid protocol fees. Five numbers describe it:

| Read | What it is |
| --- | --- |
| `balanceOf(owner)` | the owner's unlocked balance |
| `earned(providerId)` | the provider's credited, unpaid earnings |
| `relayerEarned(relayer)` | the relayer's credited, unpaid gas fees and deposit fees |
| `accrued()` | the treasury's credited, unpaid protocol fees |
| live locks | `lock` of every `Claimed` job; not stored as a total |

The USDC the contract holds always equals Σ `balanceOf` + Σ live locks + Σ `earned` + Σ `relayerEarned` + `accrued`.

## Relayers

Every op is authorised by signatures alone, so any relayer can land every op, and anyone can run a coordinator. The gas fee and the deposit fee pay for gas the relayer spent:

- The relayer that lands a `claim` (its `msg.sender`) is recorded in the job's terms and earns that job's `gasFee` at the exit, whoever lands the exit.
- The relayer that lands a `deposit` earns its `depositFee`.

`Claimed` and `Deposited` name the relayer.

### Deposit

`deposit(owner, value, validBefore, nonce, sig)` executes the owner's EIP-3009 `ReceiveWithAuthorization` for `value`, credits `value − depositFee` to `balanceOf(owner)` and adds `depositFee` to `relayerEarned(msg.sender)`. A `value` at or below `depositFee` reverts `BadDepositValue`. Any relayer can land it; only this contract can execute the authorization.

### The lock

`claim` takes `lock = cap + feeCap + gasFee` out of `balanceOf(owner)`, or reverts `InsufficientDeposit`. `gasFee` is the value live at the claim; it is fixed for the job in its terms and announced in `Posted`. No token moves.

### The exits

Each exit credits the lock inside the ledger, exactly once. No token moves.

| Exit | `earned[providerId]` | `relayerEarned[terms.relayer]` | `accrued` | `balanceOf(owner)` |
| --- | --- | --- | --- | --- |
| `submitAndSettle` | `+ charge` | `+ gasFee` | `+ fee` | `+ (cap − charge) + (feeCap − fee)` |
| `fail` | — | `+ gasFee` | — | `+ cap + feeCap` |
| `reclaim` | — | `+ gasFee` | — | `+ cap + feeCap` |
| `cancel` of an unclaimed order | — | — | — | nothing was locked |

- Each exit credits exactly `lock`, provided `feeBps` has not changed since the claim.
- The gas fee goes to the claim's relayer on every exit, including `fail` and `reclaim`. The protocol fee is only taken at settlement.
- Earnings are credited to the provider id, not to a key.

`Settled` carries the protocol fee taken as `fee`.

### Withdraw

`withdraw(owner, amount, issuedAt, sig)` transfers `amount` of the owner's unlocked balance to the owner, on the owner's `Withdraw` signature. A live lock is never part of the balance, so a withdrawal cannot leave a claimed job unfunded. Over the balance reverts `InsufficientDeposit`.

### Payouts

| Call | Who | Pays |
| --- | --- | --- |
| `payProvider(providerId)` | anyone | all of `earned[providerId]` to `operatorOf(providerId)` as resolved at the payout |
| `payRelayer(relayer)` | anyone | all of `relayerEarned[relayer]` to `relayer` |
| `payTreasury()` | anyone | all of `accrued` to `treasury` as set at the payout |

All three revert `NothingToPay` on a zero amount. A key rotated after the work was done is the key that is paid.

## Fee parameters

| Parameter | Set by | Initial | Bounds | Read when |
| --- | --- | --- | --- | --- |
| `feeBps` | `setFees` (curation) | 100 (1%) | ≤ 1000 (10%), else `FeeTooHigh` | live, at `claim` and again at the exit |
| `gasFee` | `setFees` (curation) | 3000 ($0.003) | none | at `claim`, fixed per job |
| `depositFee` | `setFees` (curation) | 2000 ($0.002) | none | at each `deposit` |

`feeBps` is not fixed per job: a job claimed under one `feeBps` and resolved under another credits a different total than it locked. Change `feeBps` with no job `Claimed`.

Read the live values from the contract; do not copy them. See [Read contract state with cast](../guides/read-state-with-cast.md#read-configuration).

## Deposit authorization

The client signs a USDC `ReceiveWithAuthorization` with `to` = `JobRegistry`, `validAfter` = 0, a random `nonce` and its own `validBefore`. To fund one job exactly, `value` is that job's lock plus the deposit fee:

```
value = cap + floor(cap · feeBps / 10000) + gasFee + depositFee
```

The full field list is on [Signing](../reference/signing.md#deposit-authorization-eip-3009).
