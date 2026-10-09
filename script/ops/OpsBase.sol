// SPDX-License-Identifier: FSL-1.1-ALv2
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {AskRegistry} from "../../src/AskRegistry.sol";
import {JobRegistry} from "../../src/JobRegistry.sol";
import {ProviderRegistry} from "../../src/ProviderRegistry.sol";

/**
 * Shared plumbing for the ops scripts: bind to a reviewed address book, then either broadcast
 * (dev networks) or print calldata for the curation Safe (everywhere else).
 *
 * Why a script and not a CLI: an ops script builds its calldata with `abi.encodeCall` against the
 * imported contract, so a changed function signature is a compile error rather than a runtime
 * surprise. There is no ABI copy, no generated binding, and nothing to keep in sync with `src/`.
 * This file supplies the plumbing only — the encoding lives in the subclasses, which hand `_exec`
 * the bytes it broadcasts or prints.
 */
abstract contract OpsBase is Script {
    ProviderRegistry internal reg;
    JobRegistry internal jr;
    AskRegistry internal ar;
    /// @dev read from the chain, never from the book — `curation` is immutable in both registries
    address internal curationAddr;
    uint256 internal curationPk;
    bool internal dev;

    /// @dev One reviewed book per real network, named by network. A fork of a network shares its
    /// chain id but not its addresses; the separator check in `_loadFrom` is what refuses it.
    function _bookPath() internal view returns (string memory) {
        if (block.chainid == 84532) return "deployments/base-sepolia.json";
        if (block.chainid == 8453) return "deployments/base.json";
        revert("ops: no address book for this chain");
    }

    /// @dev virtual so the unit suite injects a live fixture instead of a committed book
    function _load() internal virtual {
        _loadFrom(_bookPath());
    }

    /**
     * @dev What the separator check proves and what it does not. A match proves "the right
     * contract on the right chain" — it binds chainId and verifyingContract in one 32-byte
     * comparison. It does NOT prove "the same deployment instance": an address is derived from the
     * deployer and its nonce, so a network recreated from fresh state and deployed again by the
     * same key redeploys the registries to the same addresses with the same separators, and passes
     * this check against state that went away. That is inherent to any separator check — the fork
     * is where it bites, its deployer starting at nonce 0 every time. `doctor` reads live wiring
     * and is what notices such a chain.
     */
    function _loadFrom(string memory path) internal {
        string memory json = vm.readFile(path);

        require(vm.parseJsonUint(json, ".chainId") == block.chainid, "ops: address book is for another chain");
        dev = vm.parseJsonBool(json, ".dev");

        reg = ProviderRegistry(vm.parseJsonAddress(json, ".providerRegistry"));
        jr = JobRegistry(vm.parseJsonAddress(json, ".jobRegistry"));
        ar = AskRegistry(vm.parseJsonAddress(json, ".askRegistry"));

        require(address(reg).code.length > 0, "ops: no code at providerRegistry");
        require(address(jr).code.length > 0, "ops: no code at jobRegistry");
        require(address(ar).code.length > 0, "ops: no code at askRegistry");

        // The one check worth having. A chain-id match proves little — a fork shares it. A domain
        // separator binds chainId and verifyingContract in one comparison.
        require(
            reg.DOMAIN_SEPARATOR() == vm.parseJsonBytes32(json, ".providerRegistryDomainSeparator"),
            "ops: providerRegistry domain separator mismatch"
        );
        require(
            jr.DOMAIN_SEPARATOR() == vm.parseJsonBytes32(json, ".jobRegistryDomainSeparator"),
            "ops: jobRegistry domain separator mismatch"
        );
        require(
            ar.DOMAIN_SEPARATOR() == vm.parseJsonBytes32(json, ".askRegistryDomainSeparator"),
            "ops: askRegistry domain separator mismatch"
        );

        // the immutable wiring nothing emits and no setter can repair
        curationAddr = reg.curation();
        require(jr.curation() == curationAddr, "ops: registries disagree about curation");
        require(address(jr.registry()) == address(reg), "ops: jobRegistry points at another ProviderRegistry");
        require(address(ar.registry()) == address(reg), "ops: askRegistry points at another ProviderRegistry");
    }

    /**
     * The safety ladder. Dry run is the default because `forge script` only broadcasts under
     * `--broadcast`, and it simulates the whole script first either way — so an op that would
     * revert fails here having sent nothing.
     */
    function _exec(address target, bytes memory data, string memory label) internal {
        console2.log("");
        console2.log(string.concat("op: ", label));
        console2.log("  to  ", target);
        console2.log("  data");
        console2.logBytes(data);

        if (!dev) {
            // Nothing is broadcast on this path, so mutating the local fork costs nothing — and it
            // proves the op succeeds against current chain state before anyone signs for it.
            /// @dev INVARIANT, and the strongest guarantee in this file: this `vm.prank` is not
            /// merely setting a sender. foundry refuses `prank` while a broadcast is armed, so a
            /// subclass that opened `vm.startBroadcast` before calling `_exec` hard-reverts here
            /// instead of quietly signing a Safe-path transaction. Do not replace it with a plain
            /// call or with `vm.startPrank`, and do not move it below the call: the abort is what
            /// makes "a non-dev network broadcasts nothing" enforced rather than merely intended.
            vm.prank(curationAddr);
            (bool okSim, bytes memory retSim) = target.call(data);
            _bubble(okSim, retSim);
            console2.log("  simulated OK as curation", curationAddr);
            console2.log("  MODE: Safe. This script broadcast nothing.");
            console2.log("  Paste `to` and `data` above into the Safe Transaction Builder.");
            return;
        }

        _requireCurationKey();
        _asCuration();
        (bool ok, bytes memory ret) = target.call(data);
        _bubble(ok, ret);
    }

    /// @dev virtual so a unit test substitutes a prank: `vm.broadcast` records a transaction, which
    /// is what a script must do and what a test must not.
    function _asCuration() internal virtual {
        vm.broadcast(curationPk);
    }

    /// @dev Resolved at execution, not at load, so a read never asks for a key. REQUIRED, with no
    /// default: the key that would be defaulted to is a published one, and an op that broadcast
    /// under it would be signing with a key anybody has. An operator who has not exported
    /// `CURATION_PK` gets foundry's missing-variable error instead, and the address check below
    /// still has to pass afterwards.
    ///
    /// `virtual` so a test harness injects its fixture's key: `vm.setEnv` writes the shared process
    /// environment, which foundry never resets and which races the tests it runs in parallel, so a
    /// suite that reached this through the environment would both leak and depend on the
    /// developer's shell.
    function _requireCurationKey() internal virtual {
        curationPk = vm.envUint("CURATION_PK");
        require(vm.addr(curationPk) == curationAddr, "ops: CURATION_PK is not this network's curation key");
    }

    /// @dev re-revert with the ORIGINAL data so forge decodes the custom error name itself. A
    /// `require(ok, "...")` here would throw that away and report every failure as one string.
    function _bubble(bool ok, bytes memory ret) internal pure {
        if (ok) return;
        if (ret.length == 0) revert("ops: reverted with no data");
        assembly {
            revert(add(ret, 0x20), mload(ret))
        }
    }

    /**
     * `operatorOf` / `isListed` / `modelAllowed` REVERT `UnknownProviderId` on an unknown id rather
     * than returning a zero value, so a typo reads as a chain failure unless it is caught as data.
     *
     * @dev The zero-operator `require` is UNREACHABLE against today's `ProviderRegistry`, and is
     * kept deliberately: `_rec` (`ProviderRegistry.sol`) reverts `UnknownProviderId` on exactly the
     * zero-operator record, so the `catch` below is what fires and this branch cannot. It is a
     * belt-and-braces check against a future registry that returns zero instead of reverting, not a
     * live path. Nobody should "prove" it reachable and write a test for it; the test would be
     * asserting on a `ProviderRegistry` that does not exist.
     */
    function _requireProvider(uint32 id) internal view {
        try reg.operatorOf(id) returns (address op) {
            require(op != address(0), "ops: provider record has a zero operator");
        } catch {
            revert(string.concat("ops: unknown provider id ", vm.toString(uint256(id))));
        }
    }

    /**
     * @dev The state a probe of `1..nextModelId()` cannot see, and reading it wrong inverts the
     * answer. `register` seeds `allowAllModels = true` (`ProviderRegistry.register`) and
     * `modelAllowed` is `allowAllModels || allowed[id][allowEpoch[id]][modelId]`, so on a default
     * record EVERY probe returns true and a closed list rendered from it is a fabrication — while
     * on a default record with an empty catalog the same loop prints `(none)` for a provider that
     * allows everything, which is the exact inversion of the truth.
     *
     * `allowEpoch` and `allowed` are both `internal`, so the flag is read indirectly: an id at or
     * above `nextModelId()` is not registered, so the explicit half is false for it unless
     * curation passed that exact id to `setAllowedModels`. Such a read is therefore
     * `allowAllModels` itself.
     *
     * The directions are not symmetric. ONE false reading is proof the flag is off, because an
     * allow-all record cannot return false for any id. All-true is the flag being on unless
     * curation explicitly listed every one of these unrelated sentinels in the current epoch —
     * which is why several are probed rather than one.
     *
     * It lives here, not in `Reads`, because `Curation.setAllowedModels` renders the same
     * before-set and `Curation` does not inherit `Reads`. A second copy would be a second thing
     * to get wrong, and getting it wrong reads as the opposite of the truth.
     */
    function _allowAllModels(uint32 id) internal view returns (bool allowAll, bool decisive) {
        uint32 next = reg.nextModelId();
        uint32[4] memory sentinels = [next, 0xC0FFEE, 0x7FFFFFFF, type(uint32).max];
        uint256 usable;
        uint256 trues;
        for (uint256 i; i < sentinels.length; i++) {
            if (sentinels[i] < next) continue; // a registered id says nothing about the flag
            usable++;
            if (reg.modelAllowed(id, sentinels[i])) trues++;
        }
        if (usable == 0) return (false, false); // unreachable — `next` is never below itself
        if (trues < usable) return (false, true); // proof: an allow-all record has no false reading
        return (true, true);
    }

    function _yesNo(bool v) internal pure returns (string memory) {
        return v ? "yes" : "no";
    }
}
