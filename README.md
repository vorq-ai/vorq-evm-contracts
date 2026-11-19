# vorq-evm-contracts

Solidity contracts for the VORQ compute marketplace on Base.

A client prepays a USDC balance and signs an order; a registered provider's claim carries the order on chain and locks its cost from that balance, and settlement credits the provider, the treasury's protocol fee, the relayer's gas fee and the client's refund against metered usage. Earnings are paid out to the provider's operator key, the relayer and the treasury by permissionless payout calls. Every client and provider action is authorised by a signature, so any key can relay the transaction and anyone can run a coordinator: the relayer that lands a claim earns that job's gas fee, and the relayer that lands a deposit earns its deposit fee. Deposits are pulled with EIP-3009 `receiveWithAuthorization`.

## Contracts

| Contract | Purpose |
| --- | --- |
| [`JobRegistry`](src/JobRegistry.sol) | Job lifecycle and the prepaid ledger: claim, settle, fail, reclaim, cancel; deposit, withdraw, payouts |
| [`ProviderRegistry`](src/ProviderRegistry.sol) | Providers, model catalog, reputation, capacity, curation allowlist |
| [`AskRegistry`](src/AskRegistry.sol) | Signed provider price quotes |
| [`Types.sol`](src/Types.sol) | Shared structs and status codes |

## Build and test

Requires [Foundry](https://getfoundry.sh). Dependencies are vendored in `lib/` (see [lib/VENDORED.md](lib/VENDORED.md)); no submodule step is needed.

Tests run on a fork of Base Sepolia against the real USDC, so an RPC URL is required:

```bash
export BASE_SEPOLIA_RPC_URL=https://sepolia.base.org
forge build
forge test
forge fmt --check
```

`test_TheContainerLinkIsCurrent` reads a vector file from a sibling checkout of `vorq-coordinator-node`; skip it when this repository is cloned alone with `--no-match-test test_TheContainerLinkIsCurrent`.

A local Base Sepolia fork with the contracts deployed is in [`fork/`](fork/README.md).

## Deployments

Base (chain id 8453): [`deployments/base.json`](deployments/base.json). See [Deployments](docs/reference/deployments.md) for addresses and domain separators.

## Documentation

[docs.vorq.co/docs/contracts](https://docs.vorq.co/docs/contracts), built from [`docs/`](docs/):

- [Overview](docs/index.md) and [Quickstart](docs/quickstart.md)
- Guides: [run the local fork](docs/guides/run-local-fork.md), [read contract state with cast](docs/guides/read-state-with-cast.md), [verify an EIP-712 signature](docs/guides/verify-eip712-signature.md)
- Concepts: [job lifecycle](docs/concepts/job-lifecycle.md), [escrow and fees](docs/concepts/escrow-and-fees.md), [reputation and capacity](docs/concepts/reputation-and-capacity.md), [payment token requirements](docs/concepts/payment-token.md), [security model](docs/concepts/security-model.md)
- Reference: [JobRegistry](docs/reference/job-registry.md), [ProviderRegistry](docs/reference/provider-registry.md), [AskRegistry](docs/reference/ask-registry.md), [signing](docs/reference/signing.md), [deployments](docs/reference/deployments.md)

## Security

See [SECURITY.md](SECURITY.md) to report a vulnerability and for known issues. The contracts have not been externally audited.

## License

[FSL-1.1-ALv2](LICENSE.md) (Functional Source License). Any use is permitted except offering a competing product or service. Each version converts to Apache-2.0 two years after its release.
