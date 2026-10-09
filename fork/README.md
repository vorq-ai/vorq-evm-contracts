# vorq-fork

A disposable local Base Sepolia fork with the VORQ contracts deployed.

Runs [Anvil](https://getfoundry.sh/anvil/overview) forked from Base Sepolia near head, deploys the three registries, and funds a client with real Base Sepolia USDC. Chain id stays `84532`. Nothing persists between runs.

## Requirements

- Docker with Compose v2
- `BASE_SEPOLIA_RPC_URL` (required), e.g. `https://sepolia.base.org`
- [Foundry](https://getfoundry.sh), for `make smoke`

## Usage

```bash
export BASE_SEPOLIA_RPC_URL=https://sepolia.base.org
make up      # start and deploy; writes state/addresses.json and state/abi/
make smoke   # post -> claim -> submitAndSettle
make down    # discard the chain
```

Pin the fork block with `FORK_BLOCK=<n> make up`.

| Port | Service |
| --- | --- |
| `8545` | RPC (5000-block `eth_getLogs` cap, no `anvil_*`/`evm_*` methods) |
| `8546` | Anvil directly, for debugging |

Roles use Anvil's well-known dev accounts `#0`–`#4` (deployer/relayer, treasury, curation, provider operator, client).

## Documentation

Accounts, published addresses, composing with another stack and troubleshooting: [Run the local fork](../docs/guides/run-local-fork.md).

## License

MIT
