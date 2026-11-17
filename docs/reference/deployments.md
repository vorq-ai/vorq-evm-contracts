---
title: Deployments
description: Networks, chain ids, contract addresses and EIP-712 domain separators of the VORQ contracts, and the address file formats.
---

The contracts are deployed on **Base** mainnet.

## Base

Chain id **8453**. Address book: [`deployments/base.json`](https://github.com/vorq-ai/vorq-evm-contracts/blob/main/deployments/base.json). Deploy block: <!-- MAINNET-ADDRESS: deployBlock -->.

| Contract | Address |
| --- | --- |
| `ProviderRegistry` | <!-- MAINNET-ADDRESS: providerRegistry --> |
| `JobRegistry` | <!-- MAINNET-ADDRESS: jobRegistry --> |
| `AskRegistry` | <!-- MAINNET-ADDRESS: askRegistry --> |
| Payment token (USDC) | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |

USDC on Base: EIP-712 `name` `USD Coin`, `version` `2`, 6 decimals.

### Domain separators

| Contract (`name`, `version`) | `DOMAIN_SEPARATOR` |
| --- | --- |
| `ProviderRegistry` (`VORQ Providers`, `2`) | <!-- MAINNET-ADDRESS: providerRegistryDomainSeparator --> |
| `JobRegistry` (`VORQ Jobs`, `2`) | <!-- MAINNET-ADDRESS: jobRegistryDomainSeparator --> |
| `AskRegistry` (`VORQ Asks`, `2`) | <!-- MAINNET-ADDRESS: askRegistryDomainSeparator --> |

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
