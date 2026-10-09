# Security Policy

## Reporting a vulnerability

Report vulnerabilities privately through GitHub: [Report a vulnerability](https://github.com/vorq-ai/vorq-evm-contracts/security/advisories/new). Do not open a public issue.

Include the affected contract and function, the impact, and steps or a test that reproduces it. We will acknowledge the report and keep you informed while it is fixed.

## Scope and status

In scope: the contracts in [`src/`](src/) as deployed on the networks listed in [`deployments/`](deployments/). The contracts are deployed on Base Sepolia (testnet) only.

The contracts have **not** been externally audited. An internal manual review has been done; its open findings are listed below.

## Threat model

Design detail (replay rules, signature format, unsigned parameters) is in [docs/concepts/security-model.md](docs/concepts/security-model.md).

### Trust assumptions

- **Curation** is one immutable address per registry and is fully trusted. It controls provider registration, listing, capacity, reputation, the model catalog, the allowlist, fees (protocol fee capped at 10%), allowed SLAs, the treasury, and which `JobRegistry` may move reputation.
- **The payment token** (USDC) is trusted to implement EIP-3009 `receiveWithAuthorization`, move exact amounts, and revert or return `false` on failure. Its blacklist and pause are accepted risks: a blacklist that lands after a claim can lock that job's escrow permanently, with no admin recovery path.
- **Relayers** have no authority. They can delay, reorder or drop transactions, but cannot alter signed terms.
- **Signers** for protocol ops are EOAs. ERC-1271 is not supported for them.

### Properties the contracts are designed to hold

- **Authority.** No client or provider entry point reads `msg.sender`. Each recovers an EIP-712 signer and rejects `address(0)` before any comparison. `reclaim` is intentionally unsigned and permissionless so no party can strand escrow by inaction.
- **Escrow conservation.** Escrow is funded once at `claim` for `cap + feeCap + gasFeeSnap` and paid out exactly once for the same total, on settle, fail or reclaim, provided `feeBps` does not change between claim and exit.
- **Replay.** Job ops are guarded by the one-shot job state machine and a ±600 s freshness window. Latest-wins provider state (`RequestCapacity`, `SetIdentity`, `AskSnapshot`) is guarded by per-provider monotonic timestamps, each bounded to 3600 s of clock skew.
- **Checks-effects-interactions.** All state and reputation changes precede token calls; a reentrant token sees a terminal row and is refused.
- **Arithmetic.** Narrowing casts are bounded or guarded (`CapOverflow`).
- **Domain separation.** Each contract has its own EIP-712 domain name and publishes it via ERC-5267 `eip712Domain()`.

Out of scope: denial of service by the trusted curation key or by the token issuer, gas price manipulation, and off-chain services.

## Known issues

| ID | Severity | Title |
| --- | --- | --- |
| M1 | Medium | Front-running `post` burns the order's `c` |
| M2 | Medium | Free claim/fail cycles within the fail grace window |
| L1 | Low | `effectiveCap` never returns zero |
| L2 | Low | `ecrecover` accepts malleable signatures |
| L3 | Low | `postMany` reports out-of-gas as a per-line refusal |
| I1 | Info | `authSig` is not cleared on cancel or expiry |

### M1 — Front-running `post` burns the order's `c`

`taskCid` and `authSig` are call parameters of `post` that `orderSig` does not cover, and `jobId = keccak256(owner, c)` depends on neither. An observer can copy a pending `post`, keep the genuine `order`, `owner` and `orderSig`, replace `taskCid` or `authSig`, and land it first. The resulting job cannot be claimed (the provider's `c`/`jobId` check fails, or the token rejects the authorization), and the client's own `post` reverts `DuplicateJob` because rows are never deleted.

No funds are at risk. The cost to the client is a new `c` (re-sealing the payload) and a new signature; the attacker pays one `post`. Mitigation for integrators: treat a `c` as spent once any `post` for it lands, prefer private transaction submission for posts, and re-post with a fresh `c` rather than retrying.

### M2 — Free claim/fail cycles within the fail grace window

A listed provider can claim an undesignated job and `fail` it within `FAIL_GRACE` (300 s) with no reputation penalty. This is intended so a provider can hand back a job it cannot serve, but a provider can repeat it to withhold jobs from others, and whoever relays pays the gas for each cycle. On chain, a free fail is distinguishable only by the absence of `ReputationChanged` in the same transaction. Relayers should rate-limit providers by in-grace fail count.

### L1 — `effectiveCap` never returns zero

`effectiveCap` returns at least 1, so `setCapacityCeiling(id, 0)` does not stop a provider from claiming one job at a time. Use `setListed(id, false)` to stop a provider.

### L2 — `ecrecover` accepts malleable signatures

Signature recovery does not enforce low `s`. Both forms of a signature are accepted. Replay protection never depends on signature bytes, so there is no exploit today, but integrators must not key anything (deduplication, idempotency, indexing) on signature bytes. Values of `v` other than 27/28 recover `address(0)` and are refused.

### L3 — `postMany` reports out-of-gas as a per-line refusal

`postMany` calls `post` through `try this.post(...)`. A line that runs out of gas is reported as `PostSkipped` like a line an admission check rejected, and the transaction succeeds. Callers must size the gas limit for the full batch and must not read `PostSkipped` as proof that an order was invalid.

### I1 — `authSig` is not cleared on cancel or expiry

`claim` deletes the parked authorization; `cancel` and expiry leave it in storage. It cannot be spent: only the `JobRegistry` can execute it and no path does so for a non-`Open` job. Storage only.
