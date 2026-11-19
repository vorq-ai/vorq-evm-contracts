// SPDX-License-Identifier: FSL-1.1-ALv2
pragma solidity 0.8.30;

enum JobState {
    Open,
    Claimed,
    Settled,
    Cancelled
}

// EndedBecause: one vocabulary, shared by Ended events, JobView.endedBecause and the off-chain
// readers. `Open` is the state of an id with no row: an order the chain has not seen claimed.
uint8 constant ENDED_NONE = 0;
uint8 constant ENDED_SETTLED = 1; // view only — settlement has its own event
uint8 constant ENDED_CANCELLED = 2;
uint8 constant ENDED_PROVIDER_FAIL = 3;
uint8 constant ENDED_RECLAIM = 4;
uint8 constant ENDED_EXPIRED = 5; // off chain only — an order that expired unclaimed has no row

struct Order {
    bytes32 c;
    uint32 modelId;
    uint32 slaSecs;
    uint128 rateIn;
    uint128 rateOut;
    uint32 unitsIn;
    uint32 unitsOut;
    uint32 designated; // 0 = open order
    uint64 expiresAt;
    bytes taskCid;
}

/// What the exits need from the order, fixed at claim. The row stores only the first 21 bytes of
/// `keccak256(abi.encode(terms))`; settle, fail and reclaim are handed the terms again and must
/// reproduce that hash. The full order is announced in `Posted`, the relayer in `Claimed`.
struct Terms {
    address owner;
    uint128 rateIn;
    uint128 rateOut;
    uint32 unitsIn;
    uint32 unitsOut;
    uint32 slaSecs;
    uint64 gasFee; // the gas fee as of claim
    address relayer; // the claim's sender; earns gasFee on every exit
}

struct JobView {
    bool found;
    bytes32 jobId;
    uint8 state;
    uint8 endedBecause;
    uint32 providerId;
    uint64 claimedAt;
}

// What a settle meters, as the provider's backend reported it. unitsIn and unitsOut on the order
// are the ceilings; cachedTok is the part of promptTok billed at rateInCached (<= the order's rateIn).
struct Usage {
    uint32 promptTok;
    uint32 cachedTok;
    uint32 completionTok;
    uint128 rateInCached;
}

struct Ask {
    uint32 modelId;
    uint32 sla;
    uint128 rateIn;
    uint128 rateOut;
}

struct AskSnapshot {
    uint32 providerId;
    uint64 signedAt;
    Ask[] quotes;
}
