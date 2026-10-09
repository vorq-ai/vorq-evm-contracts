// SPDX-License-Identifier: FSL-1.1-ALv2
pragma solidity 0.8.30;

import {console2} from "forge-std/console2.sol";
import {JobRegistry} from "../../src/JobRegistry.sol";
import {ProviderRegistry} from "../../src/ProviderRegistry.sol";
import {OpsBase} from "./OpsBase.sol";

/**
 * @notice Every `onlyCuration` operation, one external function each.
 *
 * Each one reads the current value first, refuses what the chain would refuse (with a message
 * naming the fix), skips when the target state already holds, then executes. `abi.encodeCall` is
 * the only encoding used, so a changed signature in `src/` is a compile error here.
 *
 * The one exception is `setCapacityCeiling`, which cannot skip because the value it writes has no
 * getter — see the note on that function. Every skip that IS claimed is covered by a test proven to
 * fail when its early return is removed; a no-op assertion nothing forces is worth nothing.
 */
contract Curation is OpsBase {
    /// @notice Create a provider record. The chain assigns the id, not this script.
    /// @dev On a dev network the assigned id is read back from `idOf` after execution and printed
    /// as fact. On the Safe path nothing has executed — the calldata is signed later, possibly days
    /// later, and any other `register` landing first takes the id this run predicted. So that path
    /// prints `nextProviderId()` labelled as the guess it is, and the operator must read the real
    /// id off the executed transaction rather than off this output.
    function register(address operator, uint32 ceiling, bool listed, uint16 reputation) external {
        _load();
        require(
            operator != address(0), unicode"register: operator is the zero address — the record would be unreachable"
        );
        // The contract clamps the seed to [100,1000] and emits the CLAMPED value, exactly as
        // `setReputation` does, so a request outside the band lands as a different number with no
        // error and no warning anywhere.
        require(
            reputation >= 100 && reputation <= 1000,
            unicode"register: reputation must be within [100,1000] — the contract clamps silently"
        );
        uint32 existing = reg.idOf(operator);
        require(
            existing == 0,
            string.concat(
                "register: operator already holds provider id ",
                vm.toString(uint256(existing)),
                unicode" — use setOperator to move it"
            )
        );
        console2.log("  operator     ", operator);
        console2.log("  ceiling      ", uint256(ceiling));
        console2.log("  listed       ", _yesNo(listed));
        console2.log("  reputation   ", uint256(reputation));
        console2.log(
            "  will take id ",
            string.concat(
                vm.toString(uint256(reg.nextProviderId())),
                dev ? "" : " (PREDICTED - a register that lands before this one is signed takes it instead)"
            )
        );
        console2.log(
            "  note: capacityRequested seeds at 0, so effectiveCap is 1 until the provider signs a requestCapacity op."
        );
        _exec(
            address(reg), abi.encodeCall(ProviderRegistry.register, (operator, ceiling, listed, reputation)), "register"
        );
        if (dev) console2.log("  registered as id", uint256(reg.idOf(operator)));
    }

    /// @notice Move a provider record to a new operator key.
    /// @dev The no-op check MUST precede the duplicate guard. An operator already bound to this
    /// record satisfies `idOf[newOperator] != 0` (it holds exactly `id`, which `_requireProvider`
    /// has proven non-zero), so ordering the guard first makes the skip unreachable and reports
    /// "already holds a provider id" for an address whose only record is this one.
    function setOperator(uint32 id, address newOperator) external {
        _load();
        _requireProvider(id);
        require(newOperator != address(0), "setOperator: the zero address would brick the record irreversibly");
        address current = reg.operatorOf(id);
        if (current == newOperator) {
            console2.log("  no-op: already this operator");
            return;
        }
        require(reg.idOf(newOperator) == 0, "setOperator: that address already holds a provider id");
        console2.log("  operator     ", string.concat(vm.toString(current), " -> ", vm.toString(newOperator)));
        console2.log("  note: the old key stops authorising immediately. Every op it signed but that");
        console2.log("        has not landed yet becomes unusable.");
        _exec(address(reg), abi.encodeCall(ProviderRegistry.setOperator, (id, newOperator)), "setOperator");
    }

    /// @notice List or delist a provider. Delisting is one of the two levers that bite immediately.
    function setListed(uint32 id, bool listed) external {
        _load();
        _requireProvider(id);
        bool current = reg.isListed(id);
        console2.log("  listed       ", string.concat(_yesNo(current), " -> ", _yesNo(listed)));
        if (current == listed) {
            console2.log("  no-op: already set");
            return;
        }
        if (!listed) {
            console2.log("  effect: new claims fail NotListed at once. Claimed jobs are UNAFFECTED and");
            console2.log(unicode"          still settle — delisting stops intake, it does not stop work.");
            console2.log("  activeJobs right now", uint256(jr.activeJobs(id)));
        }
        _exec(address(reg), abi.encodeCall(ProviderRegistry.setListed, (id, listed)), "setListed");
    }

    /// @notice Set the ceiling half of the capacity pair. The provider owns the other half.
    /// @dev The only op here with no no-op branch, and not by choice: `capacityCeiling` lives in
    /// the `internal recs` mapping and `ProviderRegistry` exposes no getter for it, so the current
    /// value cannot be read and "already set" cannot be detected. `effectiveCap` is not a
    /// substitute — it collapses the pair through `min(requested, ceiling)`, so it is unchanged by
    /// any ceiling above `capacityRequested`. Re-running therefore always sends.
    function setCapacityCeiling(uint32 id, uint32 ceiling) external {
        _load();
        _requireProvider(id);
        uint32 capBefore = reg.effectiveCap(id);
        console2.log("  ceiling      ", uint256(ceiling));
        console2.log("  effectiveCap ", uint256(capBefore));
        console2.log("  note: effectiveCap = reputation/1000 * min(requested, ceiling), floored at 1.");
        console2.log("        A ceiling below the provider's requested value is what actually binds.");
        _exec(address(reg), abi.encodeCall(ProviderRegistry.setCapacityCeiling, (id, ceiling)), "setCapacityCeiling");
        if (dev) console2.log("  effectiveCap now", uint256(reg.effectiveCap(id)));
    }

    /// @notice Override a provider's reputation. Normal movement is the job path's, not this.
    function setReputation(uint32 id, uint16 milli) external {
        _load();
        _requireProvider(id);
        // The contract clamps to [100,1000] and emits the CLAMPED value, so a request outside the
        // band lands as a different number with no error and no warning anywhere.
        require(
            milli >= 100 && milli <= 1000,
            unicode"setReputation: milli must be within [100,1000] — the contract clamps silently"
        );
        uint16 current = reg.reputationOf(id);
        console2.log(
            "  reputation   ", string.concat(vm.toString(uint256(current)), " -> ", vm.toString(uint256(milli)))
        );
        if (current == milli) {
            console2.log("  no-op: already set");
            return;
        }
        // `effectiveCap ` before, `effectiveCap now` after, exactly as `setCapacityCeiling` prints
        // them: the same label meaning "before" in one op and "after" in the next is how an
        // operator reads a number as the result of a change that has not happened yet.
        console2.log("  effectiveCap ", uint256(reg.effectiveCap(id)));
        _exec(address(reg), abi.encodeCall(ProviderRegistry.setReputation, (id, milli)), "setReputation");
        if (dev) console2.log("  effectiveCap now", uint256(reg.effectiveCap(id)));
    }

    /// @notice Append a model to the catalog. There is no delete and no rename.
    /// @dev Three things worth knowing, all of them consequences of append-only.
    ///
    /// The id is PREDICTED on the Safe path, exactly as in `register` and for the same reason:
    /// nothing has executed, the calldata is signed later, and any other `registerModel` landing
    /// first takes the id printed here. That matters more than it does for a provider record —
    /// the only way to walk back a typo is `setModelEnabled(<id>, false)`, so an operator who
    /// disables the PREDICTED id rather than the executed one permanently kills a model that was
    /// never the mistake. On a dev network the id is read back after execution and printed as fact.
    ///
    /// This op cannot detect a duplicate name. Names live only in the `ModelRegistered` event and
    /// never in storage, so there is nothing on chain to compare against and re-running appends a
    /// second id for the same model.
    ///
    /// The empty-name guard is this script's, not the chain's: `registerModel` takes any string,
    /// so an empty one would consume an id permanently with nothing to identify it.
    function registerModel(string calldata name) external {
        _load();
        require(bytes(name).length > 0, "registerModel: empty name");
        console2.log("  name         ", name);
        console2.log(
            "  will take id ",
            string.concat(
                vm.toString(uint256(reg.nextModelId())),
                dev ? "" : " (PREDICTED - a registerModel that lands before this one is signed takes it instead)"
            )
        );
        console2.log(unicode"  note: the catalog is APPEND-ONLY. A typo occupies this id permanently — the");
        console2.log("        only remedy is setModelEnabled(<id>, false) on the wrong entry, so take");
        console2.log("        that id from the executed transaction and never from a prediction.");
        console2.log("  note: names are not stored on chain - they exist only in the ModelRegistered");
        console2.log("        event - so this op CANNOT tell whether this name is already in the");
        console2.log("        catalog. Re-running it appends a SECOND id for the same model.");
        _exec(address(reg), abi.encodeCall(ProviderRegistry.registerModel, (name)), "registerModel");
        // `nextModelId` is post-increment in `registerModel`, so the id just taken is one below it.
        // There is no `idOf`-style lookup to use instead: the name is not stored anywhere.
        if (dev) console2.log("  registered as id", uint256(reg.nextModelId()) - 1);
    }

    /// @notice The model kill switch. With delisting, one of the two levers that bite at once.
    function setModelEnabled(uint32 modelId, bool enabled) external {
        _load();
        require(
            reg.modelExists(modelId),
            string.concat(
                "setModelEnabled: model ",
                vm.toString(uint256(modelId)),
                unicode" is not in the catalog — run registerModel first"
            )
        );
        bool current = reg.modelEnabled(modelId);
        console2.log("  model        ", uint256(modelId));
        console2.log("  enabled      ", string.concat(_yesNo(current), " -> ", _yesNo(enabled)));
        if (current == enabled) {
            console2.log("  no-op: already set");
            return;
        }
        if (!enabled) {
            console2.log("  effect: every new post naming this model fails ModelDisabled at once.");
            console2.log("          Jobs already posted or claimed are UNAFFECTED and still settle.");
        }
        _exec(address(reg), abi.encodeCall(ProviderRegistry.setModelEnabled, (modelId, enabled)), "setModelEnabled");
    }

    /**
     * @notice Replace a provider's allowed-model set.
     * @dev The call bumps an epoch, so it REPLACES rather than adds: anything absent from
     * `modelIds` loses access and nothing is emitted naming it. Two things are therefore this
     * script's job and not the chain's.
     *
     * First, the catalog check. `ProviderRegistry.setAllowedModels` writes
     * `allowed[id][epoch][modelIds[i]] = true` without ever consulting `modelExists`, so an id
     * that is not in the catalog lands silently and reads back as allowed while `post` rejects it
     * as ModelDisabled. The guard below is real added safety, not a mirror of a chain check.
     *
     * Second, the before-set. It is rendered from `_allowAllModels`, never from a
     * `1..nextModelId()` loop: `register` seeds `allowAllModels = true`, so such a loop reports a
     * closed set for a record that allows every id there is, and `(none)` when the catalog is
     * empty — the exact inversion of the truth, on precisely the records an operator is most
     * likely to be editing for the first time.
     */
    function setAllowedModels(uint32 id, uint32[] calldata modelIds, bool allowAll) external {
        _load();
        _requireProvider(id);
        uint32 next = reg.nextModelId();
        for (uint256 i; i < modelIds.length; i++) {
            require(
                reg.modelExists(modelIds[i]),
                string.concat(
                    "setAllowedModels: model ",
                    vm.toString(uint256(modelIds[i])),
                    unicode" is not in the catalog — run registerModel first"
                )
            );
        }

        console2.log("  provider     ", uint256(id));
        console2.log("  allowAll     ", _yesNo(allowAll));
        console2.log("  current set (probed against the live epoch)");
        (bool allowAllNow, bool decisive) = _allowAllModels(id);
        if (!decisive) {
            console2.log("    CANNOT DETERMINE - no unregistered model id was available to probe");
        } else if (allowAllNow) {
            console2.log("    allowAllModels yes (inferred from unregistered-id probes)");
            console2.log("    EVERY model id, including ids not yet registered");
        } else {
            // the flag is off, so `modelAllowed` is the explicit half alone and this loop is
            // complete for the current epoch. The hedge is carried over from `_printAllowedModels`
            // verbatim: the SAME probe backs both, so it must be qualified the same in both.
            console2.log("    allowAllModels no (inferred from unregistered-id probes)");
            console2.log("    explicitly allowed (complete: 1..nextModelId-1 at the current epoch)");
            bool any;
            for (uint32 m = 1; m < next; m++) {
                if (reg.modelAllowed(id, m)) {
                    console2.log("      model", uint256(m));
                    any = true;
                }
            }
            if (!any) console2.log("      (none - this provider can serve no model)");
        }

        console2.log("  new set");
        if (allowAll) {
            // not "every catalog model": `allowAll` writes the FLAG, so ids registered after this
            // call are allowed too. Understating that on a signing diff understates the grant.
            console2.log("    EVERY model id, including ids not yet registered");
            console2.log(unicode"    (allowAll ignores the list entirely — future ids are auto-allowed)");
        } else if (modelIds.length == 0) {
            console2.log(unicode"    (none — this revokes every model for this provider)");
        } else {
            for (uint256 i; i < modelIds.length; i++) {
                console2.log("    model", uint256(modelIds[i]));
            }
        }
        // Only where something CAN lose access. allow-all is a superset of every prior set, so
        // warning on that path would be false, and a note that cries wolf is not read on the two
        // paths where it is exactly right.
        if (!allowAll) {
            console2.log("  note: this REPLACES the set. Anything in the current list and not in the new");
            console2.log("        one loses access, and no event names it individually.");
        }

        _exec(
            address(reg),
            abi.encodeCall(ProviderRegistry.setAllowedModels, (id, modelIds, allowAll)),
            "setAllowedModels"
        );
    }

    /**
     * @notice List (status 1) or revoke (status 2) a measurement.
     * @dev The key IS the measurement — the raw 32-byte sha256 image digest, no namespace prefix
     * and no second hash — so there is nothing to derive and nothing to get wrong except the
     * digest itself. Copy it from the build output; a mistyped digest writes a real entry under a
     * key nothing will ever read, and neither the chain nor this script can tell.
     *
     * Both status guards are this script's alone. `setAllowlistEntry` is `onlyCuration` and
     * curation is trusted, so the contract stores whatever byte it is handed: `{1 active,
     * 2 revoked}` is an off-chain vocabulary and 0 or 7 land just as happily. Status 0 is the one
     * that cannot be walked back — entries are never deleted, so 0 means "never listed" and
     * writing it makes a real revocation indistinguishable from an absent entry.
     *
     * The entry bytes are DERIVED from the key rather than taken as an argument, so the recorded
     * measurement can never disagree with the key it is filed under.
     */
    function setAllowlistEntry(bytes32 key, uint8 status) external {
        _load();
        require(status != 0, unicode"setAllowlistEntry: status 0 means 'never listed' — revoke with 2, never 0");
        require(status == 1 || status == 2, "setAllowlistEntry: status must be 1 (list) or 2 (revoke)");
        require(
            key != bytes32(0),
            unicode"setAllowlistEntry: the zero key is not a measurement — pass the sha256 image digest"
        );

        uint8 current = reg.allowlistStatus(key);
        bytes memory entry = _allowlistEntry(key);
        console2.log("  key (measurement)", vm.toString(key));
        console2.log(
            "  status           ", string.concat(vm.toString(uint256(current)), " -> ", vm.toString(uint256(status)))
        );
        console2.log("  entry            ", string(entry));
        if (current == status) {
            console2.log("  no-op: already set");
            return;
        }
        if (status == 1) {
            console2.log("  effect: a coordinator running this image can pull escrow keys at handover,");
            console2.log("          and clients will seal open bids to it.");
        } else {
            console2.log("  effect: clients stop sealing new bids to this image. A STILL-RUNNING");
            console2.log(unicode"          instance keeps serving releases — killing the process is what");
            console2.log("          destroys its keys, not this write.");
        }
        _exec(
            address(reg), abi.encodeCall(ProviderRegistry.setAllowlistEntry, (key, status, entry)), "setAllowlistEntry"
        );
    }

    /// @notice The protocol fee and the flat gas fee.
    /// @dev The 1000 ceiling is `JobRegistry.setFees`'s own `FeeTooHigh` bound, mirrored here so a
    /// typo fails before anything is signed rather than as a bare custom error on the Safe path.
    function setFees(uint16 feeBps_, uint128 gasFee_) external {
        _load();
        require(feeBps_ <= 1000, unicode"setFees: feeBps above the 10% ceiling — JobRegistry reverts FeeTooHigh");
        uint16 curFee = jr.feeBps();
        uint128 curGas = jr.gasFee();
        console2.log(
            "  feeBps       ", string.concat(vm.toString(uint256(curFee)), " -> ", vm.toString(uint256(feeBps_)))
        );
        console2.log(
            "  gasFee       ", string.concat(vm.toString(uint256(curGas)), " -> ", vm.toString(uint256(gasFee_)))
        );
        if (curFee == feeBps_ && curGas == gasFee_) {
            console2.log("  no-op: already set");
            return;
        }
        console2.log("  note: both price at SETTLEMENT, not at post. Jobs already posted settle at the");
        console2.log("        NEW feeBps, so this moves money for work already in flight.");
        console2.log("  note: gasFee is snapshotted per job at post (gasFeeSnap), so a change here");
        console2.log("        reaches new posts only.");
        _exec(address(jr), abi.encodeCall(JobRegistry.setFees, (feeBps_, gasFee_)), "setFees");
    }

    /// @notice Add or remove an SLA value from the allowed set.
    /// @dev `setSlaAllowed` validates `secs` not at all, so any value lands. The allowed set is
    /// what `post` gates on; nothing else reads it.
    function setSlaAllowed(uint32 secs, bool ok) external {
        _load();
        bool current = jr.allowedSla(secs);
        console2.log("  sla          ", uint256(secs));
        console2.log("  allowed      ", string.concat(_yesNo(current), " -> ", _yesNo(ok)));
        if (current == ok) {
            console2.log("  no-op: already set");
            return;
        }
        if (!ok) {
            console2.log("  effect: new posts naming this SLA fail SlaNotAllowed. Jobs already posted");
            console2.log("          keep their SLA and settle normally.");
        }
        _exec(address(jr), abi.encodeCall(JobRegistry.setSlaAllowed, (secs, ok)), "setSlaAllowed");
    }

    /// @notice Move the fee sink.
    /// @dev The zero check is this script's alone: `JobRegistry.setTreasury` writes whatever it is
    /// handed, so address(0) is stored happily and every subsequent fee is transferred to it.
    function setTreasury(address treasury_) external {
        _load();
        require(
            treasury_ != address(0),
            unicode"setTreasury: the zero address would burn every fee — the chain does not check this"
        );
        address current = jr.treasury();
        console2.log("  treasury     ", string.concat(vm.toString(current), " -> ", vm.toString(treasury_)));
        if (current == treasury_) {
            console2.log("  no-op: already set");
            return;
        }
        console2.log("  note: the treasury holds no privilege - JobRegistry transfers to it and never");
        console2.log("        calls it. Fees already paid stay at the old address.");
        _exec(address(jr), abi.encodeCall(JobRegistry.setTreasury, (treasury_)), "setTreasury");
    }

    /**
     * @notice Authorise or revoke a JobRegistry on the ProviderRegistry.
     *
     * The highest-consequence op in the system, and only in the revoking direction. `JobRegistry`
     * reaches `ProviderRegistry.applyReputationDelta` behind `onlyJobRegistry` on every terminal
     * path that PRICES the outcome — `submitAndSettle`, and any refund that penalises (`reclaim`
     * always, `fail` only past `FAIL_GRACE`). Revoking makes those calls revert for every CLAIMED
     * job, and the escrow they hold is unrecoverable until the same address is re-authorised.
     *
     * `fail` inside `FAIL_GRACE` is the one escape hatch: it passes `penalise: false`, so it calls
     * no `onlyJobRegistry` function. It is not true that it leaves `ProviderRegistry` untouched —
     * `registry.idOf(signer)` resolves the claimant on that path — but `idOf` is an ungated public
     * mapping and answers just the same after revocation, so the full refund still lands.
     *
     * Only claimed jobs are at risk. `cancel` ends an Open row that never funded escrow and reaches
     * the registry on no line at all, so the count that belongs in the warning is `activeJobs`.
     *
     * THE COUNT IS READ FROM `a`, NEVER FROM THE ADDRESS BOOK'S `jr`. `a` is an arbitrary address
     * and the realistic revocation is retiring an OLD registry after the book has already moved to
     * its replacement — exactly the case where the two differ, and where a count taken from the
     * book would read the new registry's jobs (often zero) while the old one holds the escrow this
     * call is about to strand. That understates the magnitude on the one screen the operator reads
     * before signing, which is the whole purpose of the warning. The printed line therefore names
     * the contract the number came from, so it can never be misattributed to `a` by proximity.
     *
     * `_claimedJobs` refuses to answer for an address it cannot read, and the op prints that
     * refusal rather than a number. Be precise about what the check buys: `a.registry() == reg` is
     * a CLAIM MADE BY `a`, not a fact about it. A contract answering `reg` from `registry()` and 0
     * from every `activeJobs` yields a vouched, confidently printed, fabricated zero, and nothing
     * here can tell the difference. What actually narrows the field is not in that check at all —
     * this branch is only reachable when `reg.isJobRegistry(a)` is already true, so `a` is an
     * address curation itself authorised. The `registry()` probe is a consistency test that catches
     * the honest mistake (a registry bound to a DIFFERENT ProviderRegistry, whose `activeJobs` are
     * indexed by another id space and cannot be summed under this loop bound); it is not a defence
     * against a contract built to lie, and no read of `a` could be.
     */
    function setJobRegistry(address a, bool authorized) external {
        _load();
        require(
            a != address(0),
            unicode"setJobRegistry: the zero address — pass the jobRegistry address from the address book"
        );
        bool current = reg.isJobRegistry(a);
        console2.log("  registry     ", a);
        console2.log("  authorized   ", string.concat(_yesNo(current), " -> ", _yesNo(authorized)));
        if (current == authorized) {
            console2.log("  no-op: already set");
            return;
        }

        if (!authorized) {
            // from `a` itself, never from the book's `jr` - see the note on this function
            (uint256 claimed, bool readable) = _claimedJobs(a);
            console2.log(_claimedLine(a, claimed, readable));
            console2.log("  effect: submitAndSettle, reclaim, and fail past FAIL_GRACE all revert for");
            console2.log("          every one of them, and their escrow is unrecoverable until this");
            console2.log("          address is re-authorised.");
            console2.log(unicode"          `fail` inside FAIL_GRACE still refunds in full — it calls no");
            console2.log("          onlyJobRegistry function - so the grace window is the only escape");
            console2.log("          hatch, and it is measured from each job's own claimedAt.");
            console2.log("  FAIL_GRACE seconds", uint256(jr.FAIL_GRACE()));
            require(
                _ackStranding(),
                "setJobRegistry: revoking strands escrow for every claimed job. Re-run with "
                "VORQ_OPS_ACK_STRANDING=1 once you have read the count above."
            );
        }
        _exec(address(reg), abi.encodeCall(ProviderRegistry.setJobRegistry, (a, authorized)), "setJobRegistry");
    }

    /// @notice The exact number of claimed jobs on the address book's JobRegistry, exposed so a
    /// test can pin it. `_loadFrom` has already proven that one points at `reg`.
    function claimedJobs() external view returns (uint256 total) {
        bool readable;
        (total, readable) = _claimedJobs(address(jr));
        require(readable, "claimedJobs: the address book's jobRegistry does not answer for this ProviderRegistry");
    }

    /// @notice The claimed-job count on any registry, exposed so a test can pin which one the
    /// revoking path reads. `readable` false means no number could be established at all.
    function claimedJobsOn(address target) external view returns (uint256 total, bool readable) {
        return _claimedJobs(target);
    }

    /**
     * @dev The acknowledgement, read through a hook rather than inline at its one call site — the
     * same substitution point `_asCuration` and `_requireCurationKey` already use, and for a
     * sharper version of the same reason. `vm.setEnv` writes the ONE process environment every test
     * in a run shares, foundry never resets it, and the tests inside a contract execute IN
     * PARALLEL. The two tests covering this gate hold OPPOSITE expectations of this exact variable,
     * so reaching it through `setEnv` would race them directly and the loser reports the safety
     * gate as not firing. A `virtual` hook gives each harness instance its own answer and no test
     * touches the environment at all.
     *
     * The body below is still covered, in the direction that matters. `AckProbe` in
     * `test/ops/CurationOps.t.sol` does NOT override this hook and asserts it answers false with
     * the variable absent — the FAIL-CLOSED half, which needs no `vm.setEnv` and so carries no
     * race. The other half, "set implies proceed", cannot be unit-tested without writing that
     * shared environment, so it is proven by a `forge script` run against a live network instead;
     * the task report records it.
     */
    function _ackStranding() internal view virtual returns (bool) {
        return vm.envOr("VORQ_OPS_ACK_STRANDING", uint256(0)) == 1;
    }

    /**
     * @dev `JobRegistry.jobs` is internal with no enumeration, but `activeJobs` is a public mapping
     * per provider and `nextProviderId` bounds the loop — so this total is EXACT across every
     * provider, not a sample. Ids start at 1; `nextProviderId` is the next unissued one.
     *
     * `target` is a parameter rather than always `jr` because the revoking path must count the
     * registry it is revoking, which need not be the book's. The `registry()` probe is a
     * CONSISTENCY TEST, not a guarantee: `target.registry() == reg` is a claim made by `target`,
     * and a contract answering `reg` and then zero from every `activeJobs` is vouched by it while
     * printing a fabricated count. What it does catch is the honest mistake — a real registry bound
     * to a DIFFERENT ProviderRegistry, whose `activeJobs` are indexed by another id space and so
     * cannot be summed under this loop bound. See `setJobRegistry` for what actually narrows the
     * field, which is not in this function: the revoking branch is reachable only for an address
     * curation has already authorised.
     *
     * `readable` false is not zero and must never be rendered as zero — it means no number could be
     * established, which on this op is the difference between "nothing is at risk" and "how much is
     * at risk is unknown".
     */
    function _claimedJobs(address target) internal view returns (uint256 total, bool readable) {
        // NOT an equivalence, though it looks like one. For an EOA and for precompiles 0x01-0x04
        // this line is indeed redundant — the call succeeds, `_read32` sees a length it rejects,
        // and the answer is `(0, false)` either way. It is NOT redundant from 0x05 up. Measured on
        // this code, guard in place: 1,086 gas for every one of 0x01-0x0a. Guard removed, the
        // 4-byte selector reaches the precompile as a malformed input: 0x05 modexp reads it as
        // enormous length fields and burned 1,029,976,059; 0x06 ecAdd 31,932,152; 0x07 ecMul
        // 986,941; 0x08 pairing OOG'd the measurement outright. Two distinct mechanisms — modexp
        // prices its declared lengths, while the curve precompiles simply FAIL on malformed input
        // and a failed precompile consumes everything forwarded to it. Value-equivalent,
        // emphatically not gas-equivalent, and under any bounded budget the child burns 63/64 and
        // the parent limps on with 1/64. A mutation removing it therefore SURVIVES the suite
        // without being an equivalent mutant, which is a gap in the tests rather than a property
        // of the code. (0x09-0x0a were not measured; the range is stated as 0x05 upward for that
        // reason, and re-measure rather than inherit these numbers if this line is ever revisited.)
        if (target.code.length == 0) return (0, false);

        // NOT `try JobRegistry(target).registry()`. `try/catch` catches a REVERTING callee; it does
        // not catch a failure to ABI-decode the return data of a call that SUCCEEDED, and that is
        // the shape `a` actually takes here. A contract with `fallback() external {}` — or any
        // payable-fallback token — answers this probe successfully with zero bytes, and the decode
        // then reverts OUTSIDE the try, aborting the whole op before the UNKNOWN line can print.
        // The operator sees a bare `EvmError: Revert` and CANNOT REVOKE THE ADDRESS AT ALL, on the
        // one op whose job is undoing a mis-authorisation — and a mis-authorised address is a live
        // hole, since anything authorised may call `applyReputationDelta` freely.
        (uint256 word, bool ok) = _read32(target, abi.encodeWithSelector(jr.registry.selector));
        if (!ok) return (0, false);
        if (word > type(uint160).max) return (0, false); // dirty high bits: not an address
        if (address(uint160(word)) != address(reg)) return (0, false);

        uint32 next = reg.nextProviderId();
        for (uint32 id = 1; id < next; id++) {
            // the same validation inside the loop, and not symmetry for its own sake: a VOUCHED
            // target answering short, or answering above `uint32` max, would otherwise abort the
            // count mid-way — past the point where the op could still say anything useful.
            (word, ok) = _read32(target, abi.encodeWithSelector(jr.activeJobs.selector, id));
            if (!ok) return (0, false);
            if (word > type(uint32).max) return (0, false);
            total += word;
        }
        return (total, true);
    }

    /**
     * @dev One 32-byte word from an untrusted address, or `ok == false`. Written in assembly for
     * one reason, and it is not gas: `target.staticcall(...)` returning `bytes memory` copies the
     * ENTIRE returndata into memory BEFORE any length check can look at it, so a hostile callee
     * returning megabytes takes the frame out with an out-of-gas that no `ret.length` test can
     * intercept — the same availability failure as the decode abort above, reached by gas instead.
     * Measured: roughly 3-3.5 MB of returndata OOGs the whole run at a 30M budget, and the operator
     * again cannot revoke through this op. Passing `0, 0` as the output window copies nothing;
     * `returndatasize()` is then read and rejected before `returndatacopy` touches memory.
     *
     * Scope, honestly: this needs a deliberately hostile ALREADY-AUTHORISED contract, not a
     * fat-fingered token, and `cast send` to `ProviderRegistry.setJobRegistry` remains as the
     * operator's escape. It is guarded anyway because availability is the whole point of this op.
     *
     * `ok` folds "the call succeeded" and "it answered exactly one word" into a single condition,
     * so the two sites above cannot drift apart on it.
     */
    function _read32(address target, bytes memory data) private view returns (uint256 word, bool ok) {
        assembly ("memory-safe") {
            // output window 0,0: nothing is copied on return, whatever the callee sends back
            let success := staticcall(gas(), target, add(data, 0x20), mload(data), 0, 0)
            if and(success, eq(returndatasize(), 32)) {
                returndatacopy(0x00, 0, 32) // scratch space, only now that the size is known
                word := mload(0x00)
                ok := 1
            }
        }
    }

    /// @notice The claimed-count line the revoking path prints, exposed so a test can pin both
    /// renderings exactly.
    function claimedLine(address target, uint256 claimed, bool readable) external view returns (string memory) {
        return _claimedLine(target, claimed, readable);
    }

    /// @dev Extracted from `setJobRegistry` because `console2.log` reaches the console address by
    /// staticcall rather than by an event, so a test can observe what this RETURNS but never what
    /// the op PRINTED. Rendering here is what lets a test pin the unknown string as carrying no
    /// digit at all — the one shape that would be misread as a count. The residual gap narrows to
    /// "the single log call was deleted", which matters because the unknown branch is unreachable
    /// from read-only devnet evidence too: getting there needs an already-authorised non-registry
    /// address, and authorising one is a broadcast.
    function _claimedLine(address target, uint256 claimed, bool readable) internal view returns (string memory) {
        if (!readable) {
            return string.concat(
                "  claimed jobs across all providers RIGHT NOW: UNKNOWN",
                unicode" — nothing bound to this ProviderRegistry answers at the address above, so how",
                " much escrow this strands cannot be established here. Treat it as unknown, never as",
                " zero."
            );
        }
        return string.concat(
            "  claimed jobs across all providers RIGHT NOW, counted on ",
            vm.toString(target),
            ": ",
            vm.toString(claimed)
        );
    }

    /// @notice The entry bytes for a key, exposed so a test can pin them.
    function entryFor(bytes32 key) external pure returns (bytes memory) {
        return _allowlistEntry(key);
    }

    /// @dev `kind` is opaque to the chain and load-bearing off it: clients match only `image` and
    /// `cvm-image`, so an entry written under any other kind is invisible to its only readers.
    /// This must stay byte-identical to `Deploy.s.sol._allowlistEntry` and to the literal pinned in
    /// `test/AllowlistKeyConvention.t.sol` — the two other places this convention lives.
    function _allowlistEntry(bytes32 key) internal pure returns (bytes memory) {
        string memory measurement = vm.replace(vm.toString(key), "0x", "");
        return bytes(string.concat('{"kind":"cvm-image","measurement":"', measurement, '"}'));
    }
}
