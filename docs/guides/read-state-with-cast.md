---
title: Read contract state with cast
description: Read jobs, providers, quotes and configuration, query logs, and decode revert reasons with cast.
---

The examples use the Base deployment. For the [local fork](./run-local-fork.md), use `http://localhost:8545` and the addresses from `fork/state/addresses.json`.

```bash
export RPC=https://mainnet.base.org
export JOBS=0xe09855d7f6d63322Ed625B6Df7138aa03c219888
export PROVIDERS=0x6Da494d3102230148bA9d7a7C0e3865FcD2AdD3D
export ASKS=0x8cb153B0710E00a115A79Ab31db923128371c07f
```

## Read a job

A job id is `keccak256(abi.encodePacked(owner, c))`:

```bash
JOB=$(cast keccak $(cast concat-hex <owner address> <c>))
```

`getJob` returns a [`JobView`](../reference/job-registry.md#jobview) and never reverts. Pass the full tuple as the return type:

```bash
cast call $JOBS "getJob(bytes32)((bool,bytes32,uint8,uint8,uint32,uint64))" $JOB --rpc-url $RPC
```

Fields in order: `found, jobId, state, endedBecause, providerId, claimedAt`. An id with no row (an order never claimed, or no order at all) returns `found == false` and zeros. See [Job lifecycle](../concepts/job-lifecycle.md) for `state` and `endedBecause`. The order itself — owner, rates, units, SLA, expiry, gas fee, `taskCid` — is in the job's `Posted` log, and the delivered counts and fee in its `Settled` log; see [Query logs](#query-logs).

## Read the ledger

```bash
cast call $JOBS "balanceOf(address)(uint128)" <owner address> --rpc-url $RPC   # unlocked balance
cast call $JOBS "earned(uint32)(uint128)" 1 --rpc-url $RPC                     # provider 1, unpaid
cast call $JOBS "relayerEarned(address)(uint128)" <relayer address> --rpc-url $RPC  # relayer, unpaid
cast call $JOBS "accrued()(uint128)" --rpc-url $RPC                            # treasury, unpaid
```

All four are atomic USDC (6 decimals): `1000000` is $1.

## Read a provider

```bash
cast call $PROVIDERS "idOf(address)(uint32)" <operator address> --rpc-url $RPC
cast call $PROVIDERS "operatorOf(uint32)(address)" 1 --rpc-url $RPC
cast call $PROVIDERS "isListed(uint32)(bool)" 1 --rpc-url $RPC
cast call $PROVIDERS "reputationOf(uint32)(uint16)" 1 --rpc-url $RPC
cast call $PROVIDERS "effectiveCap(uint32)(uint32)" 1 --rpc-url $RPC
cast call $JOBS "activeJobs(uint32)(uint32)" 1 --rpc-url $RPC
cast call $PROVIDERS "modelAllowed(uint32,uint32)(bool)" 1 2 --rpc-url $RPC
cast call $PROVIDERS "boxKeyOf(uint32)(bytes32)" 1 --rpc-url $RPC
```

`idOf` returns `0` for an address that is not an operator. The other provider views revert `UnknownProviderId()` for an id that was never registered.

## Read the model catalog

Model ids run from `1` to `nextModelId() - 1`:

```bash
cast call $PROVIDERS "nextModelId()(uint32)" --rpc-url $RPC
cast call $PROVIDERS "modelEnabled(uint32)(bool)" 2 --rpc-url $RPC
```

Model names are only in `ModelRegistered` logs.

## Read a quote

```bash
cast call $ASKS "getQuote(uint32,uint32,uint32)(uint128,uint128)" <providerId> <modelId> <slaSecs> --rpc-url $RPC
cast call $ASKS "lastSignedAt(uint32)(uint64)" <providerId> --rpc-url $RPC
```

`(0, 0)` means no quote. Rates are scaled by `RATE_SCALE`; see [Escrow and fees](../concepts/escrow-and-fees.md).

## Read configuration

```bash
cast call $JOBS "feeBps()(uint16)" --rpc-url $RPC
cast call $JOBS "gasFee()(uint64)" --rpc-url $RPC
cast call $JOBS "depositFee()(uint64)" --rpc-url $RPC
cast call $JOBS "treasury()(address)" --rpc-url $RPC
cast call $JOBS "allowedSla(uint32)(bool)" 86400 --rpc-url $RPC
cast call $PROVIDERS "isJobRegistry(address)(bool)" $JOBS --rpc-url $RPC
```

`allowedSla` is a mapping; the set of allowed values is only enumerable from `SlaAllowedChanged` logs.

## Use the make targets

From the repository root, the read-only targets bind to the address book in [`deployments/`](https://github.com/vorq-ai/vorq-evm-contracts/tree/main/deployments) for the RPC's chain id, check the domain separators, and print formatted output. They send nothing.

```bash
make read-config RPC=$RPC                           # every live parameter, models, SLAs
make read-provider ID=1 RPC=$RPC
make read-job JOB=0x… RPC=$RPC
make read-relayer RELAYER=0x… RPC=$RPC              # a relayer's unpaid gas and deposit fees
make read-asks ID=1 MODEL=2 SLA=86400 RPC=$RPC
make read-allowlist MEASUREMENT=<64 hex, no 0x> RPC=$RPC
make doctor RPC=$RPC                                # wiring, separators, treasury, fees
```

They work only on networks that have an address book, not on the local fork.

## Query logs

Event signatures and topic0 values are in the contract references. Filter by topic0 and, for indexed fields, by topic. For example, every `Posted` for one job:

```bash
cast logs --address $JOBS \
  "Posted(bytes32 indexed,uint32 indexed,uint32 indexed,address,bytes32,uint64,uint32,uint128,uint128,uint32,uint32,uint128,bytes)" \
  $JOB --from-block <start> --to-block <end> --rpc-url $RPC
```

Public RPCs cap the block range of `eth_getLogs` (the local fork proxy allows 5,000 blocks); use a provider RPC for wide scans and query in chunks.

## Decode a revert

Every custom error takes no arguments, so revert data is a 4-byte selector. Look it up in the error tables of the [JobRegistry reference](../reference/job-registry.md#errors), or:

```bash
cast decode-error 0x5276902d    # StaleOp()
```
