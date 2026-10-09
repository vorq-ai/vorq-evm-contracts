---
title: Reputation and capacity
description: How provider reputation moves and how it bounds the number of jobs a provider can hold.
---

Both live in `ProviderRegistry` and are keyed by provider id.

## Reputation

Reputation is in milli-units, clamped to `[100, 1000]`. Curation sets the seed in `register` and can overwrite it with `setReputation`; both clamp. Job outcomes move it through `applyReputationDelta`, which only an authorised `JobRegistry` can call:

| Outcome | Delta |
| --- | --- |
| `submitAndSettle` | +5 |
| `fail` within `FAIL_GRACE` (300 s after claim) | none |
| `fail` after grace | −40 |
| `reclaim` | −40 |

Every change emits `ReputationChanged(providerId, milli)` with the new value. On chain, a free `fail` and a penalised one differ only by whether `ReputationChanged` is emitted in the same transaction.

## Capacity

```
granted          = min(capacityRequested, capacityCeiling)
effectiveCap(id) = max(1, floor(reputation · granted / 1000))
```

- `capacityCeiling` is set by curation (`register`, `setCapacityCeiling`).
- `capacityRequested` is set by the provider with a signed `RequestCapacity` (`requestCapacity`). It starts at 0.
- `claim` requires `activeJobs[id] < effectiveCap(id)`, else `AtCapacity`.
- `activeJobs` (in `JobRegistry`) goes up at `claim` and down at `submitAndSettle`, `fail` and `reclaim`. A `Claimed` job past its SLA still counts until someone lands `reclaim`.

Because of the floor of 1, `setCapacityCeiling(id, 0)` does not stop a provider from claiming one job at a time. `setListed(id, false)` does.

## Other claim gates

| Gate | Set by |
| --- | --- |
| Listed | curation, `setListed` |
| Model allowed | curation, `setAllowedModels` (full replacement; a new provider allows all models) |
| Designation | the client, `Order.designated` (0 = any provider) |

## Multiple JobRegistries

`ProviderRegistry.setJobRegistry(address, bool)` authorises any number of `JobRegistry` contracts to move reputation, so a replacement can run alongside one that is draining. Revoking a registry that still has claimed jobs makes their `submitAndSettle`, `reclaim` and post-grace `fail` revert with `NotJobRegistry` until it is authorised again. A `fail` within grace does not touch reputation and still succeeds.
