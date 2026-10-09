---
title: ProviderRegistry
description: Functions, views, constants, events and errors of ProviderRegistry, and the allowlist convention.
---

Source: [`src/ProviderRegistry.sol`](https://github.com/vorq-ai/vorq-evm-contracts/blob/main/src/ProviderRegistry.sol). Solidity `0.8.30`.

## Constructor

```solidity
constructor(address curation)
```

Provider ids and model ids are assigned from 1 (`nextProviderId` and `nextModelId` start at 1). Id 0 means "none".

## Provider-signed functions

Signed by the provider operator, sent by anyone. Signed types are on [Signing](./signing.md#providerregistry-vorq-providers).

| Function | Signed type | Effect |
| --- | --- | --- |
| `requestCapacity(uint32 n, uint64 issuedAt, bytes sig)` | `RequestCapacity` | Sets `capacityRequested = n`, advances `lastCapacityAt`. Emits `CapacityChanged(id, ceiling, n)`. |
| `setIdentity(bytes32 boxKey, bytes evidence, uint64 issuedAt, bytes sig)` | `SetIdentity` | Stores `boxKey`, advances `lastIdentityAt`. `evidence` is emitted in `IdentityUpdated`, not stored. |

Both revert `NotAProvider` for a zero or unregistered signer, then `StaleOp` when `issuedAt` is not above that type's floor or is more than 3600 s ahead of `block.timestamp`.

## Curation functions

`onlyCuration`: revert `NotCuration` unless `msg.sender == curation`. Functions that take a provider `id` revert `UnknownProviderId` for an id never registered.

| Function | Notes |
| --- | --- |
| `setJobRegistry(address a, bool authorized)` | Authorises or revokes a `JobRegistry` to call `applyReputationDelta`. Several may be authorised at once. Emits `JobRegistryAuthorized`. |
| `register(address operator, uint32 capacityCeiling, bool listed, uint16 reputation) returns (uint32 id)` | `ZeroOperator` → `DuplicateOperator`. Reputation clamped to `[100, 1000]`; `capacityRequested` starts at 0; all models allowed. Emits `ProviderRegistered`, `ListedChanged`, `CapacityChanged`, `ReputationChanged` in that order. |
| `setOperator(uint32 id, address newOperator)` | `UnknownProviderId` → `ZeroOperator` → `DuplicateOperator` (address already bound to any provider, including this one). Unbinds the old operator. Emits `OperatorChanged`. |
| `setListed(uint32 id, bool listed)` | Unlisted providers cannot claim. Emits `ListedChanged`. |
| `setCapacityCeiling(uint32 id, uint32 ceiling)` | Emits `CapacityChanged(id, ceiling, requested)`. |
| `setReputation(uint32 id, uint16 milli)` | Clamped to `[100, 1000]`. Emits `ReputationChanged` with the clamped value. |
| `registerModel(string name) returns (uint32 id)` | New model exists and is enabled. Emits `ModelRegistered`. |
| `setModelEnabled(uint32 modelId, bool enabled)` | `UnknownModel` for an unregistered id. Emits `ModelEnabledChanged`. |
| `setAllowedModels(uint32 id, uint32[] modelIds, bool allowAll)` | Replaces the provider's allowed set entirely. Model ids are not checked against the catalog. Emits `AllowedModelsChanged` with the full new list. |
| `setAllowlistEntry(bytes32 key, uint8 status, bytes entry)` | Any `status` is accepted; `entry` is only emitted. See [Allowlist](#allowlist). |

## JobRegistry-only

| Function | Notes |
| --- | --- |
| `applyReputationDelta(uint32 id, int16 delta)` | `NotJobRegistry` unless `isJobRegistry[msg.sender]`; then `UnknownProviderId`. The result is clamped to `[100, 1000]`. Emits `ReputationChanged`. |

## Views

Plain getters that never revert:

| Function | Returns |
| --- | --- |
| `idOf(address operator)` | `uint32` provider id, 0 if none |
| `modelExists(uint32 modelId)` | `bool` |
| `modelEnabled(uint32 modelId)` | `bool` |
| `allowlistStatus(bytes32 key)` | `uint8` |
| `lastCapacityAt(uint32 id)` | `uint64` |
| `lastIdentityAt(uint32 id)` | `uint64` |
| `isJobRegistry(address a)` | `bool` |
| `nextProviderId()` | `uint32` |
| `nextModelId()` | `uint32` |
| `curation()` | `address` (immutable) |
| `DOMAIN_SEPARATOR()` | `bytes32` (immutable) |
| `eip712Domain()` | ERC-5267: `fields = 0x0f`, `EIP712_NAME`, `EIP712_VERSION`, `block.chainid`, `address(this)`, zero salt, no extensions |

Revert `UnknownProviderId` for an unregistered id:

| Function | Returns |
| --- | --- |
| `operatorOf(uint32 id)` | `address` |
| `isListed(uint32 id)` | `bool` |
| `reputationOf(uint32 id)` | `uint16` milli |
| `effectiveCap(uint32 id)` | `uint32`, `max(1, reputation · min(requested, ceiling) / 1000)` |
| `boxKeyOf(uint32 id)` | `bytes32` |
| `modelAllowed(uint32 id, uint32 modelId)` | `bool` |

`capacityCeiling` and `capacityRequested` have no direct getter; read them from `CapacityChanged` logs.

## Constants

| Name | Value |
| --- | --- |
| `EIP712_NAME` | `"VORQ Providers"` |
| `EIP712_VERSION` | `"2"` |
| `REQUEST_CAPACITY_TYPEHASH` | `0x1cc140b451b7b8bb60ac573bbe29ca7b37d6d80863e1015939a6b91d18586075` |
| `SET_IDENTITY_TYPEHASH` | `0x69fa5ea756b6031e7f884ca04caa57f17c175a6415125c3246d07776881afd1d` |

## Events

| Event | Indexed | topic0 |
| --- | --- | --- |
| `ProviderRegistered(uint32 providerId, address operator)` | `providerId` | `0x461808cbb80c364a24895bd28e0c53fcb0c33e9830f89176475ec656b7a2bfc4` |
| `OperatorChanged(uint32 providerId, address operator)` | `providerId` | `0x5a29c5ca51d54be26cce6e9a628abd5a0548aaf327728161a087a266677863f8` |
| `ListedChanged(uint32 providerId, bool listed)` | `providerId` | `0x78eeec08b54e686d20bc737418ccb562e5d8a6db0084e21f1fdbe953b257840b` |
| `CapacityChanged(uint32 providerId, uint32 ceiling, uint32 requested)` | `providerId` | `0xd8ef4d8c27fd5a666c642b658aa2a91ec07623e426b863345cabeba2219f6d22` |
| `ReputationChanged(uint32 providerId, uint16 milli)` | `providerId` | `0x07ed324eaf790172d078e08010f3cb02ff6ac4be60054213b9b348e34465efce` |
| `ModelRegistered(uint32 modelId, string name)` | `modelId` | `0x77c8fb9f40a3112be0590c2f65f51ae6e462dfb0eba0c03d47cf7b29ab462d03` |
| `ModelEnabledChanged(uint32 modelId, bool enabled)` | `modelId` | `0x0102ce6704bf8835c8911ac9eaf908bbd9b913f0828c131e098fa085214dcffb` |
| `AllowedModelsChanged(uint32 providerId, bool allowAll, uint32[] modelIds)` | `providerId` | `0x03a498c26a011d1242e1f8382776a797379c12a9f8b88c0f1373ccedf64f44fb` |
| `AllowlistEntrySet(bytes32 key, uint8 status, bytes entry)` | `key` | `0x044e425ff74f1539dcbbeb66b33a8fa6d47329109caf473fc9559f4591319636` |
| `IdentityUpdated(uint32 providerId, bytes32 boxKey, bytes evidence)` | `providerId` | `0xd02a166e77204b97340d0543c26b743abca7ba68d41b6639082640934c3530ef` |
| `JobRegistryAuthorized(address registry, bool authorized)` | `registry` | `0xe6d1f435ecffe5f3f57d1f69e34bc93aa7530c8b763ec202b36f4fb55c048be3` |

`CapacityChanged` and `AllowedModelsChanged` carry the complete new values, so a log projection replaces rather than merges.

## Errors

None take arguments.

| Error | Selector |
| --- | --- |
| `DuplicateOperator()` | `0x1ac56f79` |
| `NotAProvider()` | `0x3b87b40b` |
| `NotCuration()` | `0xd8f520b9` |
| `NotJobRegistry()` | `0xd4d4b8af` |
| `StaleOp()` | `0x5276902d` |
| `UnknownModel()` | `0x89aaabd0` |
| `UnknownProviderId()` | `0x23ad0289` |
| `ZeroOperator()` | `0x89961e91` |

## Allowlist

`allowlistStatus[key]` records curated code measurements. The contract accepts any `status`; the vocabulary is `0` never listed, `1` active, `2` revoked. Entries are never deleted; revocation writes `2`.

- `key` is the raw 32-byte SHA-256 image measurement, with no prefix and no second hash.
- `entry` is only emitted in `AllowlistEntrySet`. It is JSON of the form `{"kind":"cvm-image","measurement":"<64 lowercase hex>"}`. Readers match entries whose `kind` is `image` or `cvm-image`, and refuse a measurement if any entry for it is revoked.

The allowlist answers "is this code curated". It does not identify who operates a deployment.
