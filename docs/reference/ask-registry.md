---
title: AskRegistry
description: Functions, skip rules, views, constants, events, errors and types of AskRegistry.
---

Source: [`src/AskRegistry.sol`](https://github.com/vorq-ai/vorq-evm-contracts/blob/main/src/AskRegistry.sol). Solidity `0.8.30`.

The price book. Providers publish signed quote snapshots; any key can relay them. There is no curation surface; the provider signature is the only authority. No contract reads the book: prices reach a job only through the client-signed `Order`.

## Constructor

```solidity
constructor(ProviderRegistry registry)
```

## Functions

| Function | Notes |
| --- | --- |
| `setAsks(AskSnapshot[] batch, bytes[] sigs)` | Anyone may send. Reverts only on `LengthMismatch`; each invalid entry is skipped silently. |
| `getQuote(uint32 providerId, uint32 modelId, uint32 sla) returns (uint128 rateIn, uint128 rateOut)` | Never reverts. `(0, 0)` means no quote. |

### Skip rules

Each entry of `setAsks` is checked in this order and skipped at the first failure:

1. `quotes.length > MAX_QUOTES` (64)
2. `signedAt > block.timestamp + 3600`
3. The recovered signer is `address(0)` (malformed signature)
4. `idOf(signer) == 0`, or `idOf(signer) != snapshot.providerId`
5. `signedAt <= lastSignedAt[providerId]`

A skipped entry writes and emits nothing, so the reason is not visible on chain. Confirm a publish by reading `lastSignedAt` or the `AsksPublished` log.

### Semantics

- Storage is an upsert keyed by `(providerId, modelId, sla)`: a snapshot writes only the slots it lists. To withdraw a quote, publish it with `rateIn == 0 && rateOut == 0`.
- A quote with only one nonzero rate is valid, for example an input-metered model with `rateOut == 0`.
- `AsksPublished` carries the whole snapshot. An empty `quotes` array is valid: it advances the floor and emits an empty list, but clears no storage.
- One `lastSignedAt` floor per provider. An exact duplicate is skipped, so retries are safe.
- Only `idOf` is checked. Listing, capacity and model status are enforced at `post` and `claim`, not here.
- After an operator key rotation, snapshots signed by the old key are skipped, including replays of ones already published.

## Views

| Function | Returns |
| --- | --- |
| `lastSignedAt(uint32 providerId)` | `uint64` |
| `registry()` | `ProviderRegistry` (immutable) |
| `DOMAIN_SEPARATOR()` | `bytes32` (immutable) |
| `eip712Domain()` | ERC-5267: `fields = 0x0f`, `EIP712_NAME`, `EIP712_VERSION`, `block.chainid`, `address(this)`, zero salt, no extensions |

## Constants

| Name | Value |
| --- | --- |
| `MAX_QUOTES` | `64` (`uint256`) |
| `EIP712_NAME` | `"VORQ Asks"` |
| `EIP712_VERSION` | `"2"` |
| `ASK_TYPEHASH` | `0x4fadd8d1027fd2cdf6dc25ac6cb3d6ec9086a535c3f8e1c0e5cb80bb9acb2ef4` |
| `SNAPSHOT_TYPEHASH` | `0xfa55cbb0125320b1af05486ce48f1e655c7143a975aa0442af5801ceac80236e` |

## Events

| Event | Indexed | topic0 |
| --- | --- | --- |
| `AsksPublished(uint32 providerId, uint64 signedAt, Ask[] quotes)` | `providerId` | `0xe99681dfc5f3c76af67c4002113feabc8e12e6e7636fc9d1950d203c95d19d4e` |

The canonical signature is `AsksPublished(uint32,uint64,(uint32,uint32,uint128,uint128)[])`.

## Errors

| Error | Selector |
| --- | --- |
| `LengthMismatch()` | `0xff633a38` |

## Types

```solidity
struct Ask {
    uint32  modelId;
    uint32  sla;      // seconds
    uint128 rateIn;   // atomic units per unit × RATE_SCALE
    uint128 rateOut;
}

struct AskSnapshot {
    uint32 providerId;
    uint64 signedAt;
    Ask[]  quotes;
}
```

The signed type is on [Signing](./signing.md#askregistry-vorq-asks).
