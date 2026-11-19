---
title: JobRegistry
description: Functions, check order, views, constants, events, errors and types of JobRegistry.
---

Source: [`src/JobRegistry.sol`](https://github.com/vorq-ai/vorq-evm-contracts/blob/main/src/JobRegistry.sol), types in [`src/Types.sol`](https://github.com/vorq-ai/vorq-evm-contracts/blob/main/src/Types.sol). Solidity `0.8.30`.

## Constructor

```solidity
constructor(ProviderRegistry registry, IUSDC usdc, address curation, address treasury)
```

Sets `allowedSla[3600] = allowedSla[86400] = true`, `feeBps = 100`, `gasFee = 3000` ($0.003 at 6 decimals), `depositFee = 2000` ($0.002), and emits, in order, `SlaAllowedChanged(3600, true)`, `SlaAllowedChanged(86400, true)`, `FeesChanged(100, 3000, 2000)`, `TreasuryChanged(treasury)`. No argument is validated.

## Job functions

None of these is authorised by `msg.sender`; authority is the embedded signature, so any relayer can land every one. `claim` records its sender in the terms as the relayer that earns the job's `gasFee`. Signed types are on [Signing](./signing.md#jobregistry-vorq-jobs). No job function calls the token.

| Function | Signed by | Effect |
| --- | --- | --- |
| `claim(Order order, address owner, bytes orderSig, uint64 issuedAt, bytes sig)` | client (`Order`) and provider operator (`Claim`) | Records the job as `Claimed` by the signer's provider id, fixes its terms (with `gasFee` as of now and `relayer = msg.sender`) and locks `cap + feeCap + gasFee` out of `balanceOf(owner)`. Emits `Posted`, then `Claimed`. |
| `submitAndSettle(bytes32 jobId, Terms terms, Usage usage, bytes resultCid, uint64 issuedAt, bytes sig)` | claiming provider (`Settle`) | `Usage = (uint32 promptTok, uint32 cachedTok, uint32 completionTok, uint128 rateInCached)`. Clamps `promptTok` to `unitsIn`, `cachedTok` to `promptTok`, `completionTok` to `unitsOut` and `rateInCached` to `rateIn`; credits `charge` to `earned[providerId]`, `fee` to `accrued`, `gasFee` to `relayerEarned[terms.relayer]` and the refund to `balanceOf(owner)`; reputation +5. Emits `Settled`. |
| `fail(bytes32 jobId, Terms terms, uint64 issuedAt, bytes sig)` | claiming provider (`Fail`) | `gasFee` to `relayerEarned[terms.relayer]`, `cap + feeCap` back to `balanceOf(owner)`, reputation −40 if past `FAIL_GRACE`. Emits `Ended(jobId, 3)`. |
| `reclaim(bytes32 jobId, Terms terms)` | nobody | After the SLA: `gasFee` to `relayerEarned[terms.relayer]`, `cap + feeCap` back to `balanceOf(owner)`, reputation −40. Emits `Ended(jobId, 4)`. |
| `cancel(address owner, bytes32 c, uint64 issuedAt, bytes sig)` | owner (`Cancel` over `jobId = keccak256(owner, c)`) | Writes a `Cancelled` row for an order with no row, so it can never be claimed; nothing is locked or moved. Emits `Ended(jobId, 2)`. |

`submitAndSettle`, `fail` and `reclaim` take the job's `Terms` and revert `TermsMismatch` unless `bytes21(keccak256(abi.encode(terms)))` equals the row's `termsHash`. The terms are rebuilt from the job's events: `owner`, `rateIn`, `rateOut`, `unitsIn`, `unitsOut`, `slaSecs` and `gasFee` as announced in `Posted`, and `relayer` as announced in `Claimed`. Whoever lands the exit, the gas fee goes to that `relayer`.

`submitAndSettle` and `fail` compare `registry.idOf(signer)` with the job's `providerId`, so an operator key rotated after the claim still settles or fails the job. Amounts are on [Escrow and fees](../concepts/escrow-and-fees.md).

## Ledger functions

| Function | Authorised by | Effect |
| --- | --- | --- |
| `deposit(address owner, uint256 value, uint256 validBefore, bytes32 nonce, bytes sig)` | owner's USDC `ReceiveWithAuthorization` (`validAfter = 0`) | Pulls `value`, credits `value − depositFee` to `balanceOf(owner)`, adds `depositFee` to `relayerEarned[msg.sender]`. Emits `Deposited(owner, relayer, credited, fee)`. |
| `withdraw(address owner, uint128 amount, uint64 issuedAt, bytes sig)` | owner (`Withdraw`) | Transfers `amount` of the unlocked balance to `owner`. `issuedAt` must be fresh and strictly above the owner's last withdrawal's. Emits `Withdrawn`. |
| `payProvider(uint32 providerId)` | nobody | Transfers all of `earned[providerId]` to `registry.operatorOf(providerId)`. Emits `ProviderPaid`. |
| `payRelayer(address relayer)` | nobody | Transfers all of `relayerEarned[relayer]` to `relayer`. Emits `RelayerPaid`. |
| `payTreasury()` | nobody | Transfers all of `accrued` to `treasury`. Emits `TreasuryPaid`. |

### Check order

Checks run top to bottom; the first failure is the revert.

| Function | Checks |
| --- | --- |
| `claim` | `EmptyTaskCid` → `SlaNotAllowed` → `AlreadyExpired` (`now > expiresAt`) → `ExpiryTooFar` (`expiresAt > now + MAX_EXPIRY`) → `UnknownModel` → `ModelDisabled` → `InvalidOrderSignature` (zero signer or `signer != owner`) → `NotOpen` (a row exists) → `StaleOp` → `UnknownProvider` (zero signer, or `idOf == 0`) → `NotListed` → `ModelNotAllowed` → `NotDesignated` → `AtCapacity` → `CapOverflow` → `InsufficientDeposit` |
| `submitAndSettle` | `NotClaimed` → `TermsMismatch` → `NotTheClaimant` (zero signer, or id mismatch) → `SlaExpired` → `StaleOp` → `EmptyResultCid` |
| `fail` | `NotClaimed` → `TermsMismatch` → `NotTheClaimant` → `StaleOp` |
| `reclaim` | `NotClaimed` → `TermsMismatch` → `SlaNotExpired` |
| `cancel` | `StaleOp` → `NotTheOwner` (zero signer, or `signer != owner`) → return silently if `Settled` or `Cancelled` → `NotCancellable` if `Claimed` |
| `deposit` | `BadDepositValue` (`value <= depositFee`, or above `uint128`) → `OwnerHasCode` (code other than an EIP-7702 designator) → the token's own errors |
| `withdraw` | `StaleOp` → `InvalidWithdrawSignature` (zero signer, or `signer != owner`) → `StaleOp` (`issuedAt` not above the last withdrawal's) → `InsufficientDeposit` |
| `payProvider` | `NothingToPay` → `ProviderRegistry.UnknownProviderId` |
| `payRelayer` | `NothingToPay` |
| `payTreasury` | `NothingToPay` |

Unknown `jobId`: `submitAndSettle`, `fail` and `reclaim` revert `NotClaimed`; `getJob` returns a zeroed `JobView` with `found == false`.

Token and registry calls can also revert with the token's own errors, `TransferFailed`, or `ProviderRegistry.NotJobRegistry` if this contract is not authorised there.

## Curation functions

`onlyCuration`: revert `NotCuration` unless `msg.sender == curation`.

| Function | Notes |
| --- | --- |
| `setFees(uint16 feeBps, uint64 gasFee, uint64 depositFee)` | `FeeTooHigh` if `feeBps > 1000`. Emits `FeesChanged`. Change `feeBps` with no job `Claimed`. |
| `setSlaAllowed(uint32 secs, bool ok)` | `secs` is not validated. Emits `SlaAllowedChanged`. |
| `setTreasury(address treasury)` | No zero-address check. Protocol fees accrued and not yet paid go to the new treasury. Emits `TreasuryChanged`. |

## Views

| Function | Returns |
| --- | --- |
| `getJob(bytes32 jobId)` | `JobView`: `found`, `jobId`, `state`, `endedBecause`, `providerId`, `claimedAt`. Never reverts. |
| `balanceOf(address owner)` | `uint128` unlocked balance |
| `earned(uint32 providerId)` | `uint128` credited, unpaid earnings |
| `relayerEarned(address relayer)` | `uint128` the relayer's credited, unpaid gas and deposit fees |
| `accrued()` | `uint128` credited, unpaid protocol fees (the treasury's) |
| `activeJobs(uint32 providerId)` | `uint32` jobs currently `Claimed` by the provider |
| `allowedSla(uint32 secs)` | `bool` |
| `feeBps()` | `uint16` |
| `gasFee()` | `uint64` |
| `depositFee()` | `uint64` |
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
| `WITHDRAW_TYPEHASH` | `0xedc052d3b52f9b93fc5b0db172c1d5f96b11742424b8d3b2077d1843cf7b6ce4` |

## Events

| Event | Indexed | topic0 |
| --- | --- | --- |
| `Posted(bytes32 jobId, uint32 modelId, uint32 designated, address owner, bytes32 c, uint64 expiresAt, uint32 slaSecs, uint128 rateIn, uint128 rateOut, uint32 unitsIn, uint32 unitsOut, uint128 gasFee, bytes taskCid)` | `jobId`, `modelId`, `designated` | `0x9757c213f28b363acd2b1938ceda488e106b20b88b82ff9f068a986ad2824457` |
| `Claimed(bytes32 jobId, uint32 provider, address relayer, uint64 claimedAt)` | `jobId`, `provider`, `relayer` | `0xdd7732641fc44a308f25dd7005cfcbc79e1faf8308a011723f8c697f94138b07` |
| `Settled(bytes32 jobId, uint32 promptTok, uint32 cachedTok, uint32 completionTok, uint128 rateInCached, uint128 fee, bytes resultCid)` | `jobId` | `0x2b74879005a6bbf738b839b0266b33d5dbb9b4ccb2a1a61f08f43f65edf91530` |
| `Ended(bytes32 jobId, uint8 cause)` | `jobId` | `0xdf704ff689e9d76108fe736861bd4eda8ad2b565106eaea753bea20a1bf9f346` |
| `Deposited(address owner, address relayer, uint128 credited, uint128 fee)` | `owner`, `relayer` | `0x589cd684f076f0896dd77d47ec2957ff8077373f90f03772a6995c4a8459e136` |
| `Withdrawn(address owner, uint128 amount)` | `owner` | `0xab48b3d59a240196dc5bdd7f7a638fca310f8194c7d350c3dd7765861311ddf8` |
| `ProviderPaid(uint32 providerId, address to, uint128 amount)` | `providerId`, `to` | `0x1220f82b4d7587d11224e1ce3ea5b9c23a09b6789c1234595f3f3773971e0372` |
| `RelayerPaid(address relayer, uint128 amount)` | `relayer` | `0xb904082bc0f2211edf77b9e5373e92f09ac74da315c668a7f27a555d87673671` |
| `TreasuryPaid(address to, uint128 amount)` | `to` | `0x7822765c6f79599d9f5c8e1db1ea45a1e077dd69c12610039f32aa9ce4a1f420` |
| `FeesChanged(uint16 feeBps, uint128 gasFee, uint128 depositFee)` | — | `0x609a1b5ed043da7d54cd8523ebc8728b85201c320124b9ff1daa5f986d9af11a` |
| `SlaAllowedChanged(uint32 secs, bool allowed)` | — | `0x92e41ad2fa8f526cab9ad295778472a7ebde41981749b62b3a6e2adddf74e6f0` |
| `TreasuryChanged(address treasury)` | — | `0xc714d22a2f08b695f81e7c707058db484aa5b4d6b4c9fd64beb10fe85832f608` |

- `Posted` is emitted by `claim` and carries the full order; `Posted.gasFee` is the gas fee fixed for the job. `Claimed.relayer` is the claim's sender, the relayer that earns it.
- `Deposited.relayer` is the deposit's sender, the relayer that earns `Deposited.fee`.
- `Settled`'s counts and `rateInCached` are the clamped values. `Settled.fee` is the protocol fee the treasury took on top of the charge.
- `Ended.cause` is only ever 2, 3 or 4 (see [ended causes](../concepts/job-lifecycle.md#ended-causes)).
- topic0 is `keccak256` of the canonical signature (types only, no names or `indexed`).

## Errors

None take arguments.

| Error | Selector |
| --- | --- |
| `AlreadyExpired()` | `0xa0d64f8a` |
| `AtCapacity()` | `0x906e757b` |
| `BadDepositValue()` | `0x259e8a16` |
| `CapOverflow()` | `0xcd34486a` |
| `EmptyResultCid()` | `0x999282dc` |
| `EmptyTaskCid()` | `0xb77d94a7` |
| `ExpiryTooFar()` | `0x4828eeca` |
| `FeeTooHigh()` | `0xcd4e6167` |
| `InsufficientDeposit()` | `0x0e1eddda` |
| `InvalidOrderSignature()` | `0x27a9ca5f` |
| `InvalidWithdrawSignature()` | `0xb9796ddc` |
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
| `NothingToPay()` | `0x4d63c252` |
| `OwnerHasCode()` | `0x78264ee2` |
| `SlaExpired()` | `0x34c7f34d` |
| `SlaNotAllowed()` | `0x893bcb27` |
| `SlaNotExpired()` | `0x09e368e3` |
| `StaleOp()` | `0x5276902d` |
| `TermsMismatch()` | `0xc2f098fa` |
| `TransferFailed()` | `0x90b8ec18` |
| `UnknownModel()` | `0x89aaabd0` |
| `UnknownProvider()` | `0xf2b51dfc` |

## Types

### JobState

```solidity
enum JobState { Open, Claimed, Settled, Cancelled }   // 0, 1, 2, 3; Open = no row
```

### Ended causes

```solidity
uint8 constant ENDED_NONE          = 0;
uint8 constant ENDED_SETTLED       = 1; // getJob only
uint8 constant ENDED_CANCELLED     = 2;
uint8 constant ENDED_PROVIDER_FAIL = 3;
uint8 constant ENDED_RECLAIM       = 4;
uint8 constant ENDED_EXPIRED       = 5; // off chain only: an order that expired unclaimed
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

### Terms

```solidity
struct Terms {
    address owner;
    uint128 rateIn;
    uint128 rateOut;
    uint32  unitsIn;
    uint32  unitsOut;
    uint32  slaSecs;
    uint64  gasFee;   // as of claim
    address relayer;  // the claim's sender; earns gasFee on every exit
}
```

### JobView

```solidity
struct JobView {
    bool    found;
    bytes32 jobId;
    uint8   state;
    uint8   endedBecause;
    uint32  providerId;
    uint64  claimedAt;
}
```
