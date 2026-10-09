---
title: Deployments
description: Networks, chain ids, contract addresses and EIP-712 domain separators of the VORQ contracts, and the address file formats.
---

The contracts are deployed on **Base Sepolia** (testnet) only.

## Base Sepolia

Chain id **84532**. Address book: [`deployments/base-sepolia.json`](https://github.com/vorq-ai/vorq-evm-contracts/blob/main/deployments/base-sepolia.json).

| Contract | Address |
| --- | --- |
| `ProviderRegistry` | `0xE09698C32e73F86D8227cDB3588fc219d8ce0471` |
| `JobRegistry` | `0x5AAe62B7f27ad375610f8B559359De7c2136b760` |
| `AskRegistry` | `0xBA8eC092e701E4F60536d19443F12E441403743D` |
| Payment token (USDC) | `0x036CbD53842c5426634e7929541eC2318f3dCF7e` |

USDC on Base Sepolia: EIP-712 `name` `USDC`, `version` `2`, 6 decimals.

### Domain separators

| Contract (`name`, `version`) | `DOMAIN_SEPARATOR` |
| --- | --- |
| `ProviderRegistry` (`VORQ Providers`, `2`) | `0xac35c81fd56bff5756ebf7acc8c948e5ba89c7162f2c337cec9eaf867d73804c` |
| `JobRegistry` (`VORQ Jobs`, `2`) | `0x0647d233e20351bf2753df373c2d6494bb06e823421b456a596675de3e3a3426` |
| `AskRegistry` (`VORQ Asks`, `2`) | `0xa60aa36b1536a07c36bb601e3766d27a2d5f1d8457559964646af54eb2b9d946` |

A separator rebuilt from `eip712Domain()` that differs from these means a different deployment.

### Live parameters

Fees, allowed SLAs, the treasury and the provider and model sets are curation-controlled and change without a redeploy. Read them on chain; see [Read contract state with cast](../guides/read-state-with-cast.md#read-configuration). Their history is in the `FeesChanged`, `SlaAllowedChanged`, `TreasuryChanged` and `ProviderRegistry` event logs.

## Address book format

`deployments/<network>.json`:

| Key | Meaning |
| --- | --- |
| `chainId` | Chain id the book is for. |
| `dev` | `true` on development networks. The repository's `make` curation targets broadcast only where this is `true`; elsewhere they print `to` and `data` for an external signer. |
| `providerRegistry`, `jobRegistry`, `askRegistry` | Contract addresses. |
| `providerRegistryDomainSeparator`, `jobRegistryDomainSeparator`, `askRegistryDomainSeparator` | Expected `DOMAIN_SEPARATOR` of each contract. The `make` targets refuse to run when the chain disagrees. |

## Deploy output format

`script/Deploy.s.sol` writes `out-addresses/addresses.json`. The [local fork](../guides/run-local-fork.md) publishes the same file as `fork/state/addresses.json`.

| Key | Meaning |
| --- | --- |
| `chainId` | Chain id deployed to. |
| `deployBlock` | Block the script simulated at; a lower bound for log indexing. |
| `usdc` | Payment token address. |
| `paymentTokenDecimals` | Token `decimals()`. |
| `tokenDomain` | Token EIP-712 domain: `{ "name", "version" }`. |
| `providerRegistry`, `jobRegistry`, `askRegistry` | Contract addresses. |
| `curation` | Curation address. |
| `treasury` | Treasury address. |
| `providerOperator` | Operator of provider 1, registered by the script. |
| `client` | Client account named to the script. |
| `deployer` | Deployer address. |
