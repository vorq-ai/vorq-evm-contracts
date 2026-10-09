---
title: JobRegistry
description: Functions, check order, views, constants, events, errors and types of JobRegistry.
---

Source: [`src/JobRegistry.sol`](https://github.com/vorq-ai/vorq-evm-contracts/blob/main/src/JobRegistry.sol), types in [`src/Types.sol`](https://github.com/vorq-ai/vorq-evm-contracts/blob/main/src/Types.sol). Solidity `0.8.30`.

## Constructor

```solidity
constructor(ProviderRegistry registry, IUSDC usdc, address curation, address treasury)
```

Sets `allowedSla[3600] = allowedSla[86400] = true`, `feeBps = 100`, `gasFee = 30000` ($0.03 at 6 decimals), and emits, in order, `SlaAllowedChanged(3600, true)`, `SlaAllowedChanged(86400, true)`, `FeesChanged(100, 30000)`, `TreasuryChanged(treasury)`. No argument is validated.

## Actor functions

None of these reads `msg.sender`; authority is the embedded signature. Signed types are on [Signing](./signing.md#jobregistry-vorq-jobs).

| Function | Signed by | Effect |
| --- | --- | --- |
| `post(Order order, address owner, bytes orderSig, bytes authSig)` | client (`Order`) | Creates an `Open` job, stores `authSig` (the payment authorization) and snapshots `gasFee`. Emits `Posted`. |
| `postMany(Order[] orders, address[] owners, bytes[] orderSigs, bytes[] authSigs)` | client, per line | Runs `post` for each line as an external self-call. A refused line emits `PostSkipped(index, reason)` instead of reverting. |
| `claim(bytes32 jobId, uint64 issuedAt, bytes sig)` | provider operator (`Claim`) | Assigns the job to the signer's provider id, stores `cap`, deletes the stored `authSig`, emits `Claimed`, then pulls `cap + feeCap + gasFeeSnap` with `receiveWithAuthorization`. |
| `submitAndSettle(bytes32 jobId, uint32 completionTok, bytes resultCid, uint64 issuedAt, bytes sig)` | claiming provider (`Settle`) | Clamps `completionTok` to `unitsOut`, stores it and `resultCid`, reputation +5, pays operator, treasury and client. Emits `Settled`. |
| `fail(bytes32 jobId, uint64 issuedAt, bytes sig)` | claiming provider (`Fail`) | Gas fee snapshot to the treasury, the rest to the client, reputation −40 if past `FAIL_GRACE`. Emits `Ended(jobId, 3)`. |
| `reclaim(bytes32 jobId)` | nobody | After the SLA: gas fee snapshot to the treasury, the rest to the client, reputation −40. Emits `Ended(jobId, 4)`. |
| `cancel(bytes32 jobId, uint64 issuedAt, bytes sig)` | job owner (`Cancel`) | Ends an `Open` job; no funds move. Emits `Ended(jobId, 2)`. |

`submitAndSettle` and `fail` compare `registry.idOf(signer)` with the job's `providerId`, so an operator key rotated after the claim still settles or fails the job. Payout amounts are on [Escrow and fees](../concepts/escrow-and-fees.md).

### Check order

Checks run top to bottom; the first failure is the revert.

| Function | Checks |
| --- | --- |
| `post` | `EmptyTaskCid` → `SlaNotAllowed` → `AlreadyExpired` (`expiresAt <= now`) → `ExpiryTooFar` (`expiresAt > now + MAX_EXPIRY`) → `UnknownModel` → `ModelDisabled` → `InvalidOrderSignature` (zero signer or `signer != owner`) → `DuplicateJob` |
| `postMany` | `LengthMismatch` (the only whole-call revert), then each line as `post` |
| `claim` | `UnknownJob` → `NotOpen` (not `Open`, or `now > expiresAt`) → `StaleOp` → `UnknownProvider` (zero signer, or `idOf == 0`) → `NotListed` → `ModelNotAllowed` → `NotDesignated` → `AtCapacity` → `CapOverflow` → token pull |
| `submitAndSettle` | `NotClaimed` → `NotTheClaimant` (zero signer, or id mismatch) → `SlaExpired` → `StaleOp` → `EmptyResultCid` |
| `fail` | `NotClaimed` → `NotTheClaimant` → `StaleOp` |
| `reclaim` | `NotClaimed` → `SlaNotExpired` |
| `cancel` | `StaleOp` → `NotTheOwner` (zero signer, or `signer != owner`) → return silently if `Settled` or `Cancelled` → `NotCancellable` if `Claimed` |

Unknown `jobId`: `claim` reverts `UnknownJob`; `cancel` reverts `NotTheOwner`; `submitAndSettle`, `fail` and `reclaim` revert `NotClaimed`; `getJob` returns a zeroed `JobView` with `found == false`; `capOf` returns 0.

Token and registry calls can also revert with the token's own errors, `TransferFailed`, or `ProviderRegistry.NotJobRegistry` if this contract is not authorised there.

## Curation functions

`onlyCuration`: revert `NotCuration` unless `msg.sender == curation`.

| Function | Notes |
| --- | --- |
| `setFees(uint16 feeBps, uint128 gasFee)` | `FeeTooHigh` if `feeBps > 1000`. Emits `FeesChanged`. |
| `setSlaAllowed(uint32 secs, bool ok)` | `secs` is not validated. Emits `SlaAllowedChanged`. |
| `setTreasury(address treasury)` | No zero-address check. Emits `TreasuryChanged`. |

## Views

| Function | Returns |
| --- | --- |
| `getJob(bytes32 jobId)` | `JobView`. Never reverts. Reports an expired `Open` job as `Cancelled` / `ENDED_EXPIRED`. |
| `capOf(bytes32 jobId)` | `uint128` cap; 0 until claimed. |
| `activeJobs(uint32 providerId)` | `uint32` jobs currently `Claimed` by the provider. |
| `allowedSla(uint32 secs)` | `bool` |
| `feeBps()` | `uint16` |
| `gasFee()` | `uint128` |
| `treasury()` | `address` |
| `curation()` | `address` (immutable) |
| `registry()` | `ProviderRegistry` (immutable) |
| `usdc()` | payment token (immutable) |
| `DOMAIN_SEPARATOR()` | `bytes32` (immutable) |
| `eip712Domain()` | ERC-5267: `fields = 0x0f`, `EIP712_NAME`, `EIP712_VERSION`, `block.chainid`, `address(this)`, zero salt, no extensions |

## Constants

| Name | Value |
| --- | --- |
| `MAX_EXPIRY` | `86400` (`uint64`) |
| `FAIL_GRACE` | `300` (`uint64`) |
| `RATE_SCALE` | `1000000` (`uint256`) |
| `EIP712_NAME` | `"VORQ Jobs"` |
| `EIP712_VERSION` | `"2"` |
| `ORDER_TYPEHASH` | `0x3e16d11d9c120ac2d4b3537e27a5e2f4f865f70a23849726350cf94b6dc5e90c` |
| `CLAIM_TYPEHASH` | `0x9fb2253ddb001029db8b11481f856ed57697534c3cb8d823bd30a9dd3ff5ce0f` |
| `SETTLE_TYPEHASH` | `0x85d2b9b4329dab43c509568a439b97db47deb525379a4774834969a4aeb5b756` |
| `FAIL_TYPEHASH` | `0x7b55bc6e850c33643ce0bcd3046c87851a9659ecb6d541612cdb4bef5a8d1269` |
| `CANCEL_TYPEHASH` | `0x571302868b9c6729294600c0b1e1dcd58dfe44e82f479f1f68c7b68669562a94` |

## Events

| Event | Indexed | topic0 |
| --- | --- | --- |
| `Posted(bytes32 jobId, uint32 modelId, uint32 designated, address owner, bytes32 c, uint64 expiresAt, uint32 slaSecs, uint128 rateIn, uint128 rateOut, uint32 unitsIn, uint32 unitsOut, uint128 gasFee, bytes taskCid)` | `jobId`, `modelId`, `designated` | `0x9757c213f28b363acd2b1938ceda488e106b20b88b82ff9f068a986ad2824457` |
| `PostSkipped(uint256 index, bytes reason)` | `index` | `0x0e44fad0f0784bdb805f59ccd2509c265820de2805466bb2b1ec76a30205862f` |
| `Claimed(bytes32 jobId, uint32 provider, uint64 claimedAt)` | `jobId`, `provider` | `0x9ff987bb77698e24589f4fc36a1daa4345684c255c51ac8030b7f2f97bed93af` |
| `Settled(bytes32 jobId, uint32 completionTok, uint128 fee, bytes resultCid)` | `jobId` | `0x4ba0aa7b142dc1543dcaaa43dd4f4d6b9a80094440f3dc773dc7d09251fee1a9` |
| `Ended(bytes32 jobId, uint8 cause)` | `jobId` | `0xdf704ff689e9d76108fe736861bd4eda8ad2b565106eaea753bea20a1bf9f346` |
| `FeesChanged(uint16 feeBps, uint128 gasFee)` | — | `0xc4f1b19e28c7452ef005df1e28d41f0896abff20264d65837fa9e8385823835f` |
| `SlaAllowedChanged(uint32 secs, bool allowed)` | — | `0x92e41ad2fa8f526cab9ad295778472a7ebde41981749b62b3a6e2adddf74e6f0` |
| `TreasuryChanged(address treasury)` | — | `0xc714d22a2f08b695f81e7c707058db484aa5b4d6b4c9fd64beb10fe85832f608` |

- `Posted.gasFee` is the gas fee snapshotted for the job (`gasFeeSnap`).
- `Settled.completionTok` is the clamped value. `Settled.fee` is the protocol fee the treasury took on top of the charge.
- `Ended.cause` is only ever 2, 3 or 4 (see [ended causes](../concepts/job-lifecycle.md#ended-causes)).
- `PostSkipped.reason` is `post`'s raw revert data: an error selector below, or empty if the line ran out of gas.
- topic0 is `keccak256` of the canonical signature (types only, no names or `indexed`).

## Errors

None take arguments.

| Error | Selector |
| --- | --- |
| `AlreadyExpired()` | `0xa0d64f8a` |
| `AtCapacity()` | `0x906e757b` |
| `CapOverflow()` | `0xcd34486a` |
| `DuplicateJob()` | `0x8c2f943c` |
| `EmptyResultCid()` | `0x999282dc` |
| `EmptyTaskCid()` | `0xb77d94a7` |
| `ExpiryTooFar()` | `0x4828eeca` |
| `FeeTooHigh()` | `0xcd4e6167` |
| `InvalidOrderSignature()` | `0x27a9ca5f` |
| `LengthMismatch()` | `0xff633a38` |
| `ModelDisabled()` | `0x4e3a3578` |
| `ModelNotAllowed()` | `0x265a3787` |
| `NotCancellable()` | `0x67909b15` |
| `NotClaimed()` | `0xb72a2522` |
| `NotCuration()` | `0xd8f520b9` |
| `NotDesignated()` | `0x69f3dfcd` |
| `NotListed()` | `0x665c1c57` |
| `NotOpen()` | `0xddafad98` |
| `NotTheClaimant()` | `0xfea92514` |
| `NotTheOwner()` | `0x36b6b895` |
| `SlaExpired()` | `0x34c7f34d` |
| `SlaNotAllowed()` | `0x893bcb27` |
| `SlaNotExpired()` | `0x09e368e3` |
| `StaleOp()` | `0x5276902d` |
| `TransferFailed()` | `0x90b8ec18` |
| `UnknownJob()` | `0x408c4295` |
| `UnknownModel()` | `0x89aaabd0` |
| `UnknownProvider()` | `0xf2b51dfc` |

## Types

### JobState

```solidity
enum JobState { Open, Claimed, Settled, Cancelled }   // 0, 1, 2, 3
```

### Ended causes

```solidity
uint8 constant ENDED_NONE          = 0;
uint8 constant ENDED_SETTLED       = 1; // getJob only
uint8 constant ENDED_CANCELLED     = 2;
uint8 constant ENDED_PROVIDER_FAIL = 3;
uint8 constant ENDED_RECLAIM       = 4;
uint8 constant ENDED_EXPIRED       = 5; // getJob only, computed at read time
```

### Order

```solidity
struct Order {
    bytes32 c;
    uint32  modelId;
    uint32  slaSecs;
    uint128 rateIn;
    uint128 rateOut;
    uint32  unitsIn;
    uint32  unitsOut;
    uint32  designated; // 0 = any provider
    uint64  expiresAt;
    bytes   taskCid;    // not part of the signed Order type
}
```

### JobView

```solidity
struct JobView {
    bool    found;
    bytes32 jobId;
    address owner;
    bytes32 c;
    uint8   state;
    uint8   endedBecause;
    uint32  providerId;
    uint32  designated;
    uint32  modelId;
    uint128 rateIn;
    uint128 rateOut;
    uint32  unitsIn;
    uint32  unitsOut;
    uint32  completionTok;
    uint32  slaSecs;
    uint64  expiresAt;
    uint64  claimedAt;
    bytes   taskCid;
    bytes   resultCid;
    uint128 gasFee;   // gasFeeSnap
}
```
