---
title: Deployments
description: Networks, chain ids, contract addresses and EIP-712 domain separators of the VORQ contracts, and the address file formats.
---

The contracts are deployed on **Base** mainnet.

## Base

Chain id **8453**. Address book: [`deployments/base.json`](https://github.com/vorq-ai/vorq-evm-contracts/blob/main/deployments/base.json). Deploy block: 58932765 (`JobRegistry`: 59020219, redeployed 2026-11-18 for metered settlement).

| Contract | Address |
| --- | --- |
| `ProviderRegistry` | `0x6Da494d3102230148bA9d7a7C0e3865FcD2AdD3D` |
| `JobRegistry` | `0xF7a0b0444d069aEB58091Ff846b64a11C9e7BcdA` |
| `AskRegistry` | `0x8cb153B0710E00a115A79Ab31db923128371c07f` |
| Payment token (USDC) | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |

USDC on Base: EIP-712 `name` `USD Coin`, `version` `2`, 6 decimals.

### Domain separators

| Contract (`name`, `version`) | `DOMAIN_SEPARATOR` |
| --- | --- |
| `ProviderRegistry` (`VORQ Providers`, `2`) | `0x5a24ce171bb87c581acd6e635691077e43b6802add3b296b8d31021acc4ff8d6` |
| `JobRegistry` (`VORQ Jobs`, `2`) | `0x009fe01dcae7cacbafd70a887f1e921bc2af24ea038073dd20bb4b454bb3e43e` |
| `AskRegistry` (`VORQ Asks`, `2`) | `0x1fc58eca44f5c2fb25546111fc94a9ad625e59d0c3e6a5e56bbd1ff5d903f149` |

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
