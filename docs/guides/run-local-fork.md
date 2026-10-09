---
title: Run the local fork
description: Start a disposable Base Sepolia fork with the VORQ contracts deployed and a client funded in USDC.
---

[`fork/`](https://github.com/vorq-ai/vorq-evm-contracts/tree/main/fork) runs an [Anvil](https://getfoundry.sh/anvil/overview) fork of Base Sepolia, deploys the three contracts, and funds a client with the real Base Sepolia USDC (`0x036CbD53842c5426634e7929541eC2318f3dCF7e`). The chain id stays `84532`, so EIP-712 domains and USDC authorizations behave as on the live network. Nothing persists: `make down` discards the chain.

## Requirements

- Docker with Compose v2
- `BASE_SEPOLIA_RPC_URL`: an upstream Base Sepolia RPC. Required, no default. The public `https://sepolia.base.org` works; the endpoint does not need to be an archive node.
- [Foundry](https://getfoundry.sh) on the host, for `make smoke`

## Start, test, stop

```bash
cd fork
export BASE_SEPOLIA_RPC_URL=https://sepolia.base.org
make up      # start Anvil, deploy, publish state/addresses.json and state/abi/
make smoke   # post -> claim -> submitAndSettle through :8545
make down    # discard the chain
```

The first `make up` fetches fork state from the upstream RPC and can take a few minutes. On a running stack `make up` changes nothing; run `make down` first to start over.

`make smoke` signs a real order, payment authorization, claim and settle, relays them through the RPC on `8545`, and fails unless the job ends `Settled`.

## Pin the fork block

The fork is taken at the upstream head minus 64 blocks. The chosen block is the first line of `docker compose logs anvil`. To reproduce a run, pin it:

```bash
FORK_BLOCK=<block number> make up
```

## Ports

| Port | Service |
| --- | --- |
| `8545` | RPC proxy in front of Anvil. Use this one. |
| `8546` | Anvil directly, for debugging. |

The proxy on `8545` behaves like a public endpoint: `eth_getLogs` ranges above 5000 blocks are refused with error `-32005`, and `anvil_*`, `evm_*` and `hardhat_*` methods return `-32601`. Everything else is forwarded unchanged. Code that works against `8545` works against a range-capped public RPC.

## Accounts

Anvil's well-known dev accounts `#0`–`#4`:

| # | Address | Role |
| --- | --- | --- |
| 0 | `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266` | deployer and relayer |
| 1 | `0x70997970C51812dc3A010C7d01b50e0d17dc79C8` | treasury |
| 2 | `0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC` | curation |
| 3 | `0x90F79bf6EB2c4f870365E785982E1f101E93b906` | provider operator (provider id 1) |
| 4 | `0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65` | client, funded with 1,000,000 USDC |

On Base Sepolia these public accounts carry other people's history, so the bootstrap resets each one before deploying: 10,000 ETH, no code, nonce 0, existing USDC swept. Clearing code matters because USDC checks signatures from accounts with code through ERC-1271. With the deployer at nonce 0, the contract addresses are the same on every boot.

The bootstrap also sets the fork clock to the host's current time, so `issuedAt` and `expiresAt` values built from the wall clock are accepted.

The deploy then:

- authorises the `JobRegistry` in `ProviderRegistry`,
- registers model id 1,
- registers provider 1 (account `#3`), listed, reputation 1000, capacity ceiling 16,
- writes one allowlist entry,
- relays a provider-signed `requestCapacity(8)`, so `effectiveCap(1) == 8`.

## Published state

After a successful boot `fork/state/` contains:

- `addresses.json`, in the [deploy output format](../reference/deployments.md#deploy-output-format). Contract addresses on the fork:

  | Contract | Address |
  | --- | --- |
  | `ProviderRegistry` | `0x5FbDB2315678afecb367f032d93F642f64180aa3` |
  | `JobRegistry` | `0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512` |
  | `AskRegistry` | `0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0` |

- `abi/JobRegistry.json`, `abi/ProviderRegistry.json`, `abi/AskRegistry.json`

`addresses.json` is written last, only when every step succeeded, so treat a missing file as "not ready". It survives `make down`; check that `jobRegistry` has code before trusting it.

## Run your own scripts

Pass `--no-storage-caching` to every `forge script` aimed at the fork. Foundry caches fork state by chain id and block, and a new fork restarts at the same heights, so without the flag a script can read stale state.

```bash
forge script script/SmokeFlow.s.sol --rpc-url http://localhost:8545 --broadcast --no-storage-caching
```

`SmokeFlow.s.sol` needs `DEPLOYER_PK`, `PROVIDER_PK` and `CLIENT_PK` in the environment; `make smoke` sets them to the keys of accounts `#0`, `#3` and `#4`.

Do not run `script/Deploy.s.sol` against the running fork. It has no idempotence check and deploys a second set of contracts.

## Compose with another stack

Compose resolves paths against the first `-f` file's directory, so `fork/docker-compose.yml` must be the first `-f` file, or `VORQ_FORK_DIR` must be set to its absolute directory:

```bash
VORQ_FORK_DIR=/abs/path/to/vorq-evm-contracts/fork \
  docker compose -f other.yml -f /abs/path/to/vorq-evm-contracts/fork/docker-compose.yml up
```

The stack binds `8545` and `8546`, so only one fork runs per host.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `bootstrap: … has code but /state is empty. Recreate the stack.` | `make down && make up` |
| `bootstrap: /contracts is not writable by uid <n>` | Make the checkout writable by that uid (on Linux, `chown -R <n>:<n>` or rootless Docker). |
| `smoke: … and … disagree.` | Something deployed outside the bootstrap. `make down && make up` |
| `SmokeFlow: addresses.json was written for a different chain` | Wrong `--rpc-url`, or stale `state/`: `make down && make up` |
| Anvil never becomes healthy | Check `docker compose logs anvil`; the upstream RPC is likely wrong or rate-limited. |
