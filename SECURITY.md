# Security Policy

## Reporting a vulnerability

Report vulnerabilities privately through GitHub: [Report a vulnerability](https://github.com/vorq-ai/vorq-evm-contracts/security/advisories/new). Do not open a public issue.

Include the affected contract and function, the impact, and steps or a test that reproduces it. We will acknowledge the report and keep you informed while it is fixed.

## Scope and status

In scope: the contracts in [`src/`](src/) as deployed on the networks listed in [`deployments/`](deployments/). The contracts are deployed on Base mainnet (chain id 8453).

The contracts have **not** been externally audited. An internal manual review has been done; its open findings are listed below.

## Threat model

Design detail (replay rules, signature format, unsigned parameters) is in [docs/concepts/security-model.md](docs/concepts/security-model.md).

### Trust assumptions

- **Curation** is one immutable address per registry and is fully trusted. It controls provider registration, listing, capacity, reputation, the model catalog, the allowlist, fees (protocol fee capped at 10%), allowed SLAs, the treasury, and which `JobRegistry` may move reputation.
- **The payment token** (USDC) is trusted to implement EIP-3009 `receiveWithAuthorization`, move exact amounts, and revert or return `false` on failure. Its blacklist and pause are accepted risks: they can stop deposits, withdrawals and payouts, never a job exit. A blacklisted client's balance cannot be withdrawn, with no admin recovery path.
- **Relayers** have no authority. They can delay, reorder or drop transactions, but cannot alter signed terms. Any relayer can land every op: the one that lands a `claim` earns that job's gas fee, and the one that lands a `deposit` earns its deposit fee.
- **Signers** for protocol ops are EOAs. ERC-1271 is not supported for them. `deposit` refuses an owner with code (`OwnerHasCode`) other than an EIP-7702 delegated EOA.

### Properties the contracts are designed to hold

- **Authority.** No client or provider entry point is authorised by `msg.sender`; `claim` and `deposit` read it only to record the relayer that earns the fee. Each recovers an EIP-712 signer (or, for `deposit`, has the token verify the owner's EIP-3009 authorization) and rejects `address(0)` before any comparison. `reclaim`, `payProvider`, `payRelayer` and `payTreasury` are intentionally unsigned and permissionless: no party can strand a lock or a payout by inaction, and a payout can only go to the provider's current operator, the relayer itself or the treasury.
- **Ledger conservation.** The USDC the contract holds equals Σ client balances + Σ live locks + Σ provider earnings + Σ relayer earnings + accrued treasury fees. `claim` locks `cap + feeCap + gasFee` out of the owner's balance, and the lock is credited exactly once for the same total, on settle, fail or reclaim, provided `feeBps` does not change between claim and exit. Only the owner's signature withdraws, and only the unlocked balance.
- **Terms integrity.** A job's row stores 21 bytes of `keccak256(abi.encode(terms))`; the exits price only from terms that reproduce it, so a relayer cannot change a rate, a ceiling, the SLA, the gas fee, the relayer the gas fee goes to or the refund's owner.
- **Replay.** Job ops are guarded by the one-shot job state machine and a ±600 s freshness window. `withdraw` adds a per-owner strictly increasing `issuedAt`; a deposit authorization is single-use on the token. Latest-wins provider state (`RequestCapacity`, `SetIdentity`, `AskSnapshot`) is guarded by per-provider monotonic timestamps, each bounded to 3600 s of clock skew.
- **Checks-effects-interactions.** No job op calls the token. `deposit`, `withdraw` and the payouts write every balance before the one token call, so a reentrant token sees the books already moved.
- **Arithmetic.** Narrowing casts are bounded or guarded (`CapOverflow`).
- **Domain separation.** Each contract has its own EIP-712 domain name and publishes it via ERC-5267 `eip712Domain()`.

Out of scope: denial of service by the trusted curation key or by the token issuer, gas price manipulation, and off-chain services.

## Known issues

| ID | Severity | Title |
| --- | --- | --- |
| M1 | Medium | Front-running `claim` can announce a wrong `taskCid` |
| M2 | Medium | Free claim/fail cycles within the fail grace window |
| L1 | Low | `effectiveCap` never returns zero |
| L2 | Low | `ecrecover` accepts malleable signatures |
| L3 | Low | A copied `claim` or `deposit` earns the copier its fee |

### M1 — Front-running `claim` can announce a wrong `taskCid`

`taskCid` is a call parameter of `claim` that neither `orderSig` nor the provider's `Claim` signature covers. An observer can copy a pending `claim`, keep the genuine order, `owner` and both signatures, replace `taskCid`, and land it first. The job is claimed by the same provider for the same terms, but `Posted` announces the wrong location. A provider that fetches the payload by that location fails the `c`/`jobId` check and can `fail` the job inside the grace window; the client then loses the gas fee and the `c`.

No funds beyond the gas fee are at risk. The attacker pays the claim's gas and, as the claim's sender, earns the job's gas fee. Mitigation for integrators: fetch the payload by the coordinator's record for the `jobId` and verify `c` rather than trusting `Posted.taskCid`, and prefer private transaction submission for claims.

### M2 — Free claim/fail cycles within the fail grace window

A listed provider can claim an undesignated job and `fail` it within `FAIL_GRACE` (300 s) with no reputation penalty. This is intended so a provider can hand back a job it cannot serve, but a provider can repeat it to withhold jobs from others, and each cycle costs the client the gas fee. On chain, a free fail is distinguishable only by the absence of `ReputationChanged` in the same transaction. Relayers should rate-limit providers by in-grace fail count.

### L1 — `effectiveCap` never returns zero

`effectiveCap` returns at least 1, so `setCapacityCeiling(id, 0)` does not stop a provider from claiming one job at a time. Use `setListed(id, false)` to stop a provider.

### L2 — `ecrecover` accepts malleable signatures

Signature recovery does not enforce low `s`. Both forms of a signature are accepted. Replay protection never depends on signature bytes, so there is no exploit today, but integrators must not key anything (deduplication, idempotency, indexing) on signature bytes. Values of `v` other than 27/28 recover `address(0)` and are refused.

### L3 — A copied `claim` or `deposit` earns the copier its fee

The relayer that earns a job's gas fee or a deposit's fee is the transaction's `msg.sender`, not a signed member. An observer that copies a pending `claim` or `deposit` unchanged and lands it first earns that fee; the original relayer's transaction then reverts (`NotOpen`, or the token's used-authorization error) and it spends gas for nothing. Clients and providers lose nothing. Mitigation for relayers: submit claims and deposits privately.
