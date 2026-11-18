---
title: Quickstart
description: Clone, build and test the contracts, then read the live Base deployment with cast.
---

You need [Foundry](https://getfoundry.sh) (`forge` and `cast`) and network access to a Base Sepolia RPC for the tests and a Base RPC for the live deployment. The public `https://sepolia.base.org` and `https://mainnet.base.org` work.

## 1. Clone and build

```bash
git clone https://github.com/vorq-ai/vorq-evm-contracts.git
cd vorq-evm-contracts
forge build
```

Dependencies are vendored in `lib/`; there is no submodule step.

## 2. Run the tests

The suites run on a fork of Base Sepolia at a pinned block, against the real USDC, so they need an RPC URL. After the first run Foundry serves the fork from its cache.

```bash
export BASE_SEPOLIA_RPC_URL=https://sepolia.base.org
forge test --no-match-test test_TheContainerLinkIsCurrent
```

`test_TheContainerLinkIsCurrent` reads a vector file from a sibling checkout of `vorq-coordinator-node` and fails when this repository is cloned alone; every other test is self-contained.

## 3. Read the live deployment

Set the Base addresses from [Deployments](./reference/deployments.md):

```bash
export RPC=https://mainnet.base.org
export JOBS=0x166d56cBB58ba59d1a948729CfC2AB31d4d340Ab
export PROVIDERS=0x6Da494d3102230148bA9d7a7C0e3865FcD2AdD3D
export ASKS=0x8cb153B0710E00a115A79Ab31db923128371c07f
```

Confirm you are talking to the right contract. The EIP-712 domain should read `VORQ Jobs`, version `2`, chain id `8453`, and the `JobRegistry` address:

```bash
cast call $JOBS "eip712Domain()(bytes1,string,string,uint256,address,bytes32,uint256[])" --rpc-url $RPC
```

Read the current fees and whether the one-hour SLA is allowed:

```bash
cast call $JOBS "feeBps()(uint16)" --rpc-url $RPC
cast call $JOBS "gasFee()(uint128)" --rpc-url $RPC
cast call $JOBS "allowedSla(uint32)(bool)" 3600 --rpc-url $RPC
```

Read provider 1 and the size of the model catalog:

```bash
cast call $PROVIDERS "isListed(uint32)(bool)" 1 --rpc-url $RPC
cast call $PROVIDERS "reputationOf(uint32)(uint16)" 1 --rpc-url $RPC
cast call $PROVIDERS "effectiveCap(uint32)(uint32)" 1 --rpc-url $RPC
cast call $PROVIDERS "nextModelId()(uint32)" --rpc-url $RPC
```

Read provider 1's quote for model 2 at the 24-hour SLA. `0 0` means no quote is published:

```bash
cast call $ASKS "getQuote(uint32,uint32,uint32)(uint128,uint128)" 1 2 86400 --rpc-url $RPC
```

The same reads, formatted, are available as `make` targets:

```bash
make read-config RPC=$RPC
make read-provider ID=1 RPC=$RPC
```

## Next

- [Read contract state with cast](./guides/read-state-with-cast.md): jobs, logs and revert reasons.
- [Run the local fork](./guides/run-local-fork.md) to post, claim and settle a job end to end.
- [Job lifecycle](./concepts/job-lifecycle.md) for what the values you just read mean.
