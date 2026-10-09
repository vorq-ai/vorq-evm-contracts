---
title: Quickstart
description: Clone, build and test the contracts, then read the live Base Sepolia deployment with cast.
---

You need [Foundry](https://getfoundry.sh) (`forge` and `cast`) and network access to a Base Sepolia RPC. The public `https://sepolia.base.org` works.

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

Set the Base Sepolia addresses from [Deployments](./reference/deployments.md):

```bash
export RPC=https://sepolia.base.org
export JOBS=0x5AAe62B7f27ad375610f8B559359De7c2136b760
export PROVIDERS=0xE09698C32e73F86D8227cDB3588fc219d8ce0471
export ASKS=0xBA8eC092e701E4F60536d19443F12E441403743D
```

Confirm you are talking to the right contract. The EIP-712 domain should read `VORQ Jobs`, version `2`, chain id `84532`, and the `JobRegistry` address:

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
