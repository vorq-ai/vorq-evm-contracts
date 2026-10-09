// SPDX-License-Identifier: FSL-1.1-ALv2
pragma solidity 0.8.30;

import {console2} from "forge-std/console2.sol";
import {
    ENDED_CANCELLED,
    ENDED_EXPIRED,
    ENDED_NONE,
    ENDED_PROVIDER_FAIL,
    ENDED_RECLAIM,
    ENDED_SETTLED,
    JobState,
    JobView
} from "../../src/Types.sol";
import {OpsBase} from "./OpsBase.sol";

/// @notice Read-only inspection. Never broadcasts and never resolves a key.
contract Reads is OpsBase {
    /// @notice Every live protocol parameter, read from the chain.
    function config() external {
        _load();
        console2.log("network");
        console2.log("  chainId         ", block.chainid);
        console2.log("  dev             ", _yesNo(dev));
        console2.log("addresses");
        console2.log("  providerRegistry", address(reg));
        console2.log("  jobRegistry     ", address(jr));
        console2.log("  askRegistry     ", address(ar));
        console2.log("  curation        ", curationAddr);
        console2.log("  treasury        ", jr.treasury());
        console2.log("  usdc            ", address(jr.usdc()));
        console2.log("fees");
        console2.log("  feeBps          ", uint256(jr.feeBps()));
        console2.log("  gasFee          ", uint256(jr.gasFee()));
        console2.log("constants");
        console2.log("  MAX_EXPIRY      ", uint256(jr.MAX_EXPIRY()));
        console2.log("  FAIL_GRACE      ", uint256(jr.FAIL_GRACE()));
        console2.log("  RATE_SCALE      ", jr.RATE_SCALE());
        console2.log("  MAX_QUOTES      ", ar.MAX_QUOTES());
        console2.log("catalog");
        console2.log("  nextProviderId  ", uint256(reg.nextProviderId()));
        console2.log("  nextModelId     ", uint256(reg.nextModelId()));
        _printModels();
        _printAllowedSla();
    }

    /// @notice One provider record. `recs` is internal, so this is seven view calls.
    function provider(uint32 id) external {
        _load();
        _requireProvider(id);
        console2.log("provider", uint256(id));
        console2.log("  operator      ", reg.operatorOf(id));
        console2.log("  listed        ", _yesNo(reg.isListed(id)));
        console2.log("  reputation    ", uint256(reg.reputationOf(id)));
        console2.log("  effectiveCap  ", uint256(reg.effectiveCap(id)));
        console2.log("  activeJobs    ", uint256(jr.activeJobs(id)));
        console2.log("  boxKey        ", vm.toString(reg.boxKeyOf(id)));
        console2.log("  lastCapacityAt", uint256(reg.lastCapacityAt(id)));
        console2.log("  lastIdentityAt", uint256(reg.lastIdentityAt(id)));
        console2.log("  lastAskAt     ", uint256(ar.lastSignedAt(id)));
        _printAllowedModels(id);
    }

    /// @notice One job. An absent job reads `found: false`; it is not an error.
    function job(bytes32 jobId) external {
        _load();
        JobView memory v = jr.getJob(jobId);
        console2.log("job", vm.toString(jobId));
        console2.log("  found        ", _yesNo(v.found));
        if (!v.found) return;
        // the id the record carries, not the one that was asked for: a mismatch is a chain bug and
        // echoing the input would be exactly the way to never see it
        console2.log("  jobId (record)", vm.toString(v.jobId));
        console2.log("  owner        ", v.owner);
        console2.log("  state        ", string.concat(vm.toString(uint256(v.state)), " (", _stateMeaning(v.state), ")"));
        console2.log(
            "  endedBecause ",
            string.concat(vm.toString(uint256(v.endedBecause)), " (", _endedMeaning(v.endedBecause), ")")
        );
        console2.log("  providerId   ", uint256(v.providerId));
        console2.log("  designated   ", uint256(v.designated));
        console2.log("  modelId      ", uint256(v.modelId));
        console2.log("  rateIn/Out   ", string.concat(vm.toString(v.rateIn), " / ", vm.toString(v.rateOut)));
        console2.log("  unitsIn/Out  ", string.concat(vm.toString(v.unitsIn), " / ", vm.toString(v.unitsOut)));
        console2.log("  completionTok", uint256(v.completionTok));
        console2.log("  slaSecs      ", uint256(v.slaSecs));
        console2.log("  expiresAt    ", uint256(v.expiresAt));
        console2.log("  claimedAt    ", uint256(v.claimedAt));
        console2.log("  gasFee       ", uint256(v.gasFee));
        console2.log("  c            ", vm.toString(v.c));
        // `bytes` that is ASCII in practice — print both, because the wire value is the bytes
        console2.log("  taskCid hex  ", vm.toString(v.taskCid));
        console2.log("  taskCid utf8 ", string(v.taskCid));
        console2.log("  resultCid hex", vm.toString(v.resultCid));
        console2.log("  resultCid utf8", string(v.resultCid));
    }

    /// @notice The published quote for one (provider, model, sla) triple. Zeroes mean "no quote".
    function asks(uint32 providerId, uint32 modelId, uint32 sla) external {
        _load();
        (uint128 rateIn, uint128 rateOut) = ar.getQuote(providerId, modelId, sla);
        console2.log("quote", string.concat(vm.toString(providerId), "/", vm.toString(modelId)));
        console2.log("  sla     ", uint256(sla));
        console2.log("  rateIn  ", uint256(rateIn));
        console2.log("  rateOut ", uint256(rateOut));
        if (rateIn == 0 && rateOut == 0) console2.log("  (no quote published for this triple)");
    }

    /// @notice One measurement's allowlist status. The key IS the raw sha256 image digest.
    function allowlist(bytes32 key) external {
        _load();
        uint8 status = reg.allowlistStatus(key);
        console2.log("allowlist", vm.toString(key));
        console2.log("  status", uint256(status));
        console2.log("  meaning", _allowlistMeaning(status));
    }

    /**
     * @notice The deployment faults that are readable without sending a transaction: authorisation,
     * fee wiring, and the two settings that leave a live deployment unable to accept any order.
     * @dev `_load` already checked chain id, code, the three separators, and the immutable wiring.
     * What remains is the wiring that has a setter and therefore can drift after deploy. Every
     * failure message names the call that repairs it, because the operator running `doctor` is
     * exactly the person who has to fix what it finds.
     */
    function doctor() external {
        _load();
        console2.log("doctor");
        console2.log("  chainId + code + domain separators + immutable wiring: OK (checked by _load)");

        bool wired = reg.isJobRegistry(address(jr));
        console2.log("  isJobRegistry(jobRegistry)", _yesNo(wired));
        require(
            wired,
            "doctor: this JobRegistry is NOT authorised on the ProviderRegistry. submitAndSettle and "
            "reclaim revert for every claimed job until curation calls setJobRegistry(addr, true)."
        );

        require(
            jr.treasury() != address(0),
            "doctor: treasury is the zero address, so protocol fees would be burned on every "
            "settlement. Curation must call jobRegistry.setTreasury(<treasury>) before any job settles."
        );
        console2.log("  treasury                  ", jr.treasury());
        require(
            jr.feeBps() <= 1000,
            "doctor: feeBps is above the 10% ceiling the contract enforces, so this state predates "
            "the ceiling or was written by another path. Curation must call "
            "jobRegistry.setFees(<bps <= 1000>, gasFee) to bring it back in range."
        );
        console2.log("  feeBps                    ", uint256(jr.feeBps()));

        // Both of the following are setter-mutable, readable without a transaction, and each one
        // alone makes `post` revert for every order — a deployment that is up, wired, and unusable.
        bool anySla = _anySlaAllowed();
        console2.log("  an SLA is allowed         ", _yesNo(anySla));
        require(
            anySla,
            "doctor: no SLA among the probed common values is allowed, so post() reverts "
            "SlaNotAllowed for every order using one (allowedSla is a bare mapping, so a value "
            "outside the probe could still be open). Curation must call " "jobRegistry.setSlaAllowed(3600, true)."
        );

        bool anyModel = _anyModelEnabled();
        console2.log("  a model is enabled        ", _yesNo(anyModel));
        require(
            anyModel,
            "doctor: no model in the catalog is enabled (or the catalog is empty), so post() "
            "reverts ModelDisabled for every order. Curation must call "
            "providerRegistry.registerModel(<name>) and/or setModelEnabled(<modelId>, true)."
        );

        console2.log("  all checks passed");
    }

    /// @dev Private on purpose: this is the `provider()` rendering, and the only other caller that
    /// wanted any of it wanted the READING, not the layout. That reading is `OpsBase._allowAllModels`,
    /// which moved there when `Curation.setAllowedModels` needed the same before-set — `Curation`
    /// does not inherit `Reads`, so `OpsBase` is the one place both can reach.
    function _printAllowedModels(uint32 id) private view {
        (bool allowAll, bool decisive) = _allowAllModels(id);
        console2.log("  allowed models");
        if (!decisive) {
            console2.log("    CANNOT DETERMINE - no unregistered model id was available to probe");
            return;
        }
        // the hedge belongs in the output, not only in the NatSpec: `allowAllModels` is an
        // internal field this script can never read directly, and a flat `yes` would read as one
        console2.log(string.concat("    allowAllModels ", _yesNo(allowAll), " (inferred from unregistered-id probes)"));
        if (allowAll) {
            console2.log("    allows EVERY model id, including ids not yet registered");
            console2.log("    the model catalog is not a constraint on this provider");
            return;
        }
        // the flag is off, so `modelAllowed` is the explicit half alone and this loop is complete:
        // an explicit entry for an unregistered id cannot matter, `post` rejects it as ModelDisabled
        console2.log("    explicitly allowed (complete: 1..nextModelId-1 at the current epoch)");
        uint32 next = reg.nextModelId();
        bool any;
        for (uint32 m = 1; m < next; m++) {
            if (reg.modelAllowed(id, m)) {
                console2.log("      model", uint256(m));
                any = true;
            }
        }
        if (!any) console2.log("      (none - this provider can serve no model)");
    }

    function _printModels() private view {
        uint32 next = reg.nextModelId();
        console2.log("  models");
        for (uint32 m = 1; m < next; m++) {
            console2.log(string.concat("    ", vm.toString(uint256(m)), " enabled=", _yesNo(reg.modelEnabled(m))));
        }
        if (next == 1) console2.log("    (catalog is empty)");
    }

    /// @dev `allowedSla` is a mapping with no enumeration, so this probes the values the protocol
    /// actually uses. A value absent here is not proof it is disallowed — read it directly.
    /// 3600 and 86400 are both seeded in the `JobRegistry` constructor, so both must be probed:
    /// omitting either would hide an SLA that is allowed on every deployment.
    function _slaProbe() private pure returns (uint32[7] memory) {
        return [uint32(60), 300, 900, 1800, 3600, 7200, 86400];
    }

    function _printAllowedSla() private view {
        uint32[7] memory probe = _slaProbe();
        console2.log("  allowedSla (probed at the common values, not an enumeration)");
        for (uint256 i; i < probe.length; i++) {
            if (jr.allowedSla(probe[i])) console2.log("    ", uint256(probe[i]));
        }
    }

    function _anySlaAllowed() private view returns (bool) {
        uint32[7] memory probe = _slaProbe();
        for (uint256 i; i < probe.length; i++) {
            if (jr.allowedSla(probe[i])) return true;
        }
        return false;
    }

    function _anyModelEnabled() private view returns (bool) {
        uint32 next = reg.nextModelId();
        for (uint32 m = 1; m < next; m++) {
            if (reg.modelEnabled(m)) return true;
        }
        return false;
    }

    /// @dev `src/Types.sol` defines both job vocabularies; a bare integer here is an invitation to
    /// misread one. `ENDED_EXPIRED` especially: it is computed by `getJob`, never stored.
    function _stateMeaning(uint8 state) private pure returns (string memory) {
        if (state == uint8(JobState.Open)) return "Open";
        if (state == uint8(JobState.Claimed)) return "Claimed";
        if (state == uint8(JobState.Settled)) return "Settled";
        if (state == uint8(JobState.Cancelled)) return "Cancelled";
        return "UNKNOWN - not a JobState this build defines";
    }

    function _endedMeaning(uint8 ended) private pure returns (string memory) {
        if (ended == ENDED_NONE) return "ENDED_NONE - still live";
        if (ended == ENDED_SETTLED) return "ENDED_SETTLED - view only, settlement has its own event";
        if (ended == ENDED_CANCELLED) return "ENDED_CANCELLED";
        if (ended == ENDED_PROVIDER_FAIL) return "ENDED_PROVIDER_FAIL";
        if (ended == ENDED_RECLAIM) return "ENDED_RECLAIM";
        if (ended == ENDED_EXPIRED) return "ENDED_EXPIRED - view only, computed and never stored";
        return "UNKNOWN - not an EndedBecause this build defines";
    }

    function _allowlistMeaning(uint8 status) private pure returns (string memory) {
        if (status == 0) return "never listed (absent)";
        if (status == 1) return "active";
        if (status == 2) return "revoked (tombstoned)";
        return "UNKNOWN - off-chain readers match only 1 and 2";
    }
}
