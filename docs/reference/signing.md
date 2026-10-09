---
title: Signing
description: EIP-712 domains, type strings, typehashes and the USDC payment authorization used by the VORQ contracts.
---

Every client and provider action carries an EIP-712 signature from the acting party. `reclaim` and the curation functions are the only unsigned entry points. Freshness and replay rules are on [Security model](../concepts/security-model.md#replay-and-freshness).

## Domains

Each contract has its own domain:

```
EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)
```

| Contract | `name` | `version` | `chainId` | `verifyingContract` | Types verified |
| --- | --- | --- | --- | --- | --- |
| `JobRegistry` | `VORQ Jobs` | `2` | `block.chainid` at deploy | the `JobRegistry` | `Order`, `Claim`, `Settle`, `Fail`, `Cancel` |
| `ProviderRegistry` | `VORQ Providers` | `2` | `block.chainid` at deploy | the `ProviderRegistry` | `RequestCapacity`, `SetIdentity` |
| `AskRegistry` | `VORQ Asks` | `2` | `block.chainid` at deploy | the `AskRegistry` | `AskSnapshot` |

`DOMAIN_SEPARATOR` is computed once in the constructor. Each contract exposes `EIP712_NAME`, `EIP712_VERSION`, `DOMAIN_SEPARATOR` and ERC-5267 `eip712Domain()` (`fields = 0x0f`, no salt, no extensions). Read the domain from the contract and check that the separator rebuilt from `eip712Domain()` equals `DOMAIN_SEPARATOR`; a mismatch means a wrong address or chain. Published separators are on [Deployments](./deployments.md).

## Digest and signature format

```
digest = keccak256(0x19 0x01 || DOMAIN_SEPARATOR || hashStruct(message))
sig    = r || s || v     // 65 bytes, v = 27 or 28
```

Any other length or `v` recovers `address(0)`, which every entry point refuses. `s` is not range-checked; sign with low `s`.

## Type strings

Members are encoded in declaration order. The strings below are byte-exact (no spaces after commas).

### JobRegistry (`VORQ Jobs`)

```
Order(bytes32 c,uint32 modelId,uint32 slaSecs,uint128 rateIn,uint128 rateOut,uint32 unitsIn,uint32 unitsOut,uint32 designated,uint64 expiresAt)
Claim(bytes32 jobId,uint64 issuedAt)
Settle(bytes32 jobId,uint32 completionTok,uint64 issuedAt)
Fail(bytes32 jobId,uint64 issuedAt)
Cancel(bytes32 jobId,uint64 issuedAt)
```

| Type | Signed by |
| --- | --- |
| `Order` | client; the recovered signer must equal the `owner` argument of `post` |
| `Claim` | any registered operator; resolved to a provider id |
| `Settle`, `Fail` | the operator of the provider that claimed the job |
| `Cancel` | the job owner |

`Order` fields:

| Field | Type | Meaning |
| --- | --- | --- |
| `c` | `bytes32` | Payload commitment; `jobId = keccak256(abi.encodePacked(owner, c))`. Fresh per job. |
| `modelId` | `uint32` | Catalog model id; must exist and be enabled at `post`. |
| `slaSecs` | `uint32` | Must be an allowed SLA at `post`. |
| `rateIn` | `uint128` | Atomic units per input unit × `RATE_SCALE`. |
| `rateOut` | `uint128` | Atomic units per output unit × `RATE_SCALE`. |
| `unitsIn` | `uint32` | Input units, charged in full. |
| `unitsOut` | `uint32` | Maximum output units. |
| `designated` | `uint32` | Provider id, or `0` for any provider. |
| `expiresAt` | `uint64` | Unix seconds; at most `MAX_EXPIRY` (86,400 s) ahead at `post`. |

Not signed: the Solidity `Order` struct's tenth member `taskCid`, the `authSig` argument of `post`, and the `resultCid` argument of `submitAndSettle`. See [unsigned parameters](../concepts/security-model.md#unsigned-parameters).

### ProviderRegistry (`VORQ Providers`)

```
RequestCapacity(uint32 n,uint64 issuedAt)
SetIdentity(bytes32 boxKey,bytes evidence,uint64 issuedAt)
```

Signed by the provider operator. `evidence` is dynamic and is encoded as `keccak256(evidence)`.

### AskRegistry (`VORQ Asks`)

```
Ask(uint32 modelId,uint32 sla,uint128 rateIn,uint128 rateOut)
AskSnapshot(uint32 providerId,uint64 signedAt,Ask[] quotes)Ask(uint32 modelId,uint32 sla,uint128 rateIn,uint128 rateOut)
```

Signed by the operator of `providerId`. The second line is the full encoded type hashed into `SNAPSHOT_TYPEHASH`. `quotes` is encoded as `keccak256` of the concatenated `hashStruct(Ask)` values in array order, so reordering quotes changes the digest.

## Typehashes

| Type | Constant | Value |
| --- | --- | --- |
| `Order` | `JobRegistry.ORDER_TYPEHASH` | `0x3e16d11d9c120ac2d4b3537e27a5e2f4f865f70a23849726350cf94b6dc5e90c` |
| `Claim` | `JobRegistry.CLAIM_TYPEHASH` | `0x9fb2253ddb001029db8b11481f856ed57697534c3cb8d823bd30a9dd3ff5ce0f` |
| `Settle` | `JobRegistry.SETTLE_TYPEHASH` | `0x85d2b9b4329dab43c509568a439b97db47deb525379a4774834969a4aeb5b756` |
| `Fail` | `JobRegistry.FAIL_TYPEHASH` | `0x7b55bc6e850c33643ce0bcd3046c87851a9659ecb6d541612cdb4bef5a8d1269` |
| `Cancel` | `JobRegistry.CANCEL_TYPEHASH` | `0x571302868b9c6729294600c0b1e1dcd58dfe44e82f479f1f68c7b68669562a94` |
| `RequestCapacity` | `ProviderRegistry.REQUEST_CAPACITY_TYPEHASH` | `0x1cc140b451b7b8bb60ac573bbe29ca7b37d6d80863e1015939a6b91d18586075` |
| `SetIdentity` | `ProviderRegistry.SET_IDENTITY_TYPEHASH` | `0x69fa5ea756b6031e7f884ca04caa57f17c175a6415125c3246d07776881afd1d` |
| `Ask` | `AskRegistry.ASK_TYPEHASH` | `0x4fadd8d1027fd2cdf6dc25ac6cb3d6ec9086a535c3f8e1c0e5cb80bb9acb2ef4` |
| `AskSnapshot` | `AskRegistry.SNAPSHOT_TYPEHASH` | `0xfa55cbb0125320b1af05486ce48f1e655c7143a975aa0442af5801ceac80236e` |
| `EIP712Domain` | — | `0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f` |

## Payment authorization (EIP-3009)

Escrow is pulled with the payment token's `receiveWithAuthorization`. The client signs it before `post`, `post` stores it, and `claim` executes it once. It is signed on the **token's** domain:

```
domain = { name: token.name(), version: token.version(), chainId, verifyingContract: <token address> }
ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)
```

Typehash: `0xd099cc98ef71107a616c4f0f941f04c322d8e254fe26b3c6668db87aae413de8`.

| Field | Value |
| --- | --- |
| `from` | the order `owner` |
| `to` | the `JobRegistry` address |
| `value` | `cap + floor(cap · feeBps / 10000) + gasFee`; see [payment authorization amount](../concepts/escrow-and-fees.md#payment-authorization-amount) |
| `validAfter` | `0` |
| `validBefore` | `order.expiresAt + 1` |
| `nonce` | `jobId` |

- A wrong `value` surfaces as a token revert inside `claim`, not at `post`.
- Only the payee (`to == msg.sender`) can execute a receive authorization, so the signature in public `post` calldata can be spent only by the `JobRegistry`.
- `validBefore` is `expiresAt + 1` because the token requires `block.timestamp < validBefore` while `claim` accepts `block.timestamp == expiresAt`.
- `nonce = jobId` makes the authorization single-use and bound to one job. The nonce does not include the registry address.
- A stored authorization cannot be replaced.
- Read the token's `name` and `version` on chain. For Base Sepolia USDC they are `USDC` and `2`.

## Test vectors

[`vectors/signing-v3.json`](https://github.com/vorq-ai/vorq-evm-contracts/blob/main/vectors/signing-v3.json) holds domains, typed data, digests, signers and signatures for every type above plus the payment authorization, computed at the [local fork](../guides/run-local-fork.md) addresses on chain id `84532` with Anvil's public dev keys. The file also carries vectors for off-chain VORQ message types that no contract verifies. [Verify an EIP-712 signature](../guides/verify-eip712-signature.md) walks through one case.
