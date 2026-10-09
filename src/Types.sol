// SPDX-License-Identifier: FSL-1.1-ALv2
pragma solidity 0.8.30;

enum JobState {
    Open,
    Claimed,
    Settled,
    Cancelled
}

// EndedBecause: one vocabulary, shared by Ended events and JobView.endedBecause.
uint8 constant ENDED_NONE = 0;
uint8 constant ENDED_SETTLED = 1; // view only — settlement has its own event
uint8 constant ENDED_CANCELLED = 2;
uint8 constant ENDED_PROVIDER_FAIL = 3;
uint8 constant ENDED_RECLAIM = 4;
uint8 constant ENDED_EXPIRED = 5; // view only — computed, never stored

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

struct JobView {
    bool found;
    bytes32 jobId;
    address owner;
    bytes32 c;
    uint8 state;
    uint8 endedBecause;
    uint32 providerId;
    uint32 designated;
    uint32 modelId;
    uint128 rateIn;
    uint128 rateOut;
    uint32 unitsIn;
    uint32 unitsOut;
    uint32 completionTok;
    uint32 slaSecs;
    uint64 expiresAt;
    uint64 claimedAt;
    bytes taskCid;
    bytes resultCid;
    uint128 gasFee; // the job's gas fee snapshot, taken at post
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
