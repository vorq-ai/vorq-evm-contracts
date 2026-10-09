// SPDX-License-Identifier: FSL-1.1-ALv2
pragma solidity 0.8.30;

import {OpsBase} from "../../script/ops/OpsBase.sol";
import {OpsFixture} from "./OpsFixture.sol";
import {ProviderRegistry} from "../../src/ProviderRegistry.sol";

/// @dev `_load` is exercised for real here — this is the one suite that does NOT stub it.
contract Probe is OpsBase {
    function load(string memory path) external {
        _loadFrom(path);
    }

    /// @dev the path `_load` derives, exposed so the network → book mapping is asserted directly:
    /// no book for a chain exists in this checkout, so going through `_load` could only ever fail
    /// on the read.
    function bookPath() external view returns (string memory) {
        return _bookPath();
    }

    function seenCuration() external view returns (address) {
        return curationAddr;
    }

    function seenBook() external view returns (address, address, address, bool) {
        return (address(reg), address(jr), address(ar), dev);
    }
}

/**
 * @dev The execution split, made a regression-provable property rather than a construction.
 * `_asCuration` is the only thing `_exec` does differently between the two networks, so counting
 * its invocations is exactly "did this broadcast".
 */
contract ExecProbe is OpsBase {
    uint256 public broadcasts;
    uint256 internal immutable injectedPk;

    constructor(uint256 pk) {
        injectedPk = pk;
    }

    /**
     * @dev the fixture's key, injected rather than exported. This keeps the real assertion — the
     * key still has to match the curation address read off chain — while making the suite hermetic
     * against the developer's shell. The base `_requireCurationKey` REQUIRES `CURATION_PK` with no
     * default, so without this override the two `_exec` tests would fail on any machine that has
     * not exported it — and fail differently, on the address check, wherever it IS exported:
     * `CURATION_PK` is exactly the variable an operator running these ops scripts keeps exported,
     * for a network whose curation address is not this fixture's.
     */
    function _requireCurationKey() internal override {
        curationPk = injectedPk;
        require(vm.addr(curationPk) == curationAddr, "ops: CURATION_PK is not this network's curation key");
    }

    function load(string memory path) external {
        _loadFrom(path);
    }

    /// @dev `OpsFixture._writeBook` writes `dev: true`, so a freshly loaded fixture book is already
    /// on the broadcast side of the switch and this is how the Safe side is reached. Setting the
    /// flag directly rather than writing a second book keeps the two `_exec` tests differing in
    /// exactly the one input whose effect they assert.
    function setDev(bool v) external {
        dev = v;
    }

    function exec(address target, bytes memory data) external {
        _exec(target, data, "unit test");
    }

    /// @dev counts the broadcast the script would have made, then pranks so the call itself still
    /// lands as curation — `vm.broadcast` records a transaction, which a test must not do.
    function _asCuration() internal override {
        broadcasts += 1;
        vm.prank(curationAddr);
    }
}

contract OpsBaseTest is OpsFixture {
    Probe internal probe;
    ExecProbe internal execProbe;

    function setUp() public {
        _deployFixture();
        probe = new Probe();
        execProbe = new ExecProbe(curationPk);
    }

    /// @dev One reviewed book per real network, named by network, so there is nothing to select
    /// between and no environment variable pointing at a file.
    function test_theBookIsNamedByNetwork() public {
        vm.chainId(84532);
        assertEq(probe.bookPath(), "deployments/base-sepolia.json");
        vm.chainId(8453);
        assertEq(probe.bookPath(), "deployments/base.json");
    }

    /// @dev 31337 is the id an unconfigured anvil answers with, and it is exactly the case that
    /// must not silently bind to a neighbouring network's book.
    function test_aChainWithNoBookIsRefused() public {
        vm.chainId(31337);
        vm.expectRevert(bytes("ops: no address book for this chain"));
        probe.bookPath();
    }

    function test_bindsToACorrectBook() public {
        string memory book = _writeBook("good", block.chainid, address(reg), address(jr), address(ar));
        probe.load(book);
        assertEq(probe.seenCuration(), curation);
        (address bReg, address bJr, address bAr, bool bDev) = probe.seenBook();
        assertEq(bReg, address(reg), "providerRegistry not bound");
        assertEq(bJr, address(jr), "jobRegistry not bound");
        assertEq(bAr, address(ar), "askRegistry not bound");
        assertTrue(bDev, "dev not bound");
    }

    function test_refusesABookForAnotherChain() public {
        string memory book = _writeBook("wrongchain", block.chainid + 1, address(reg), address(jr), address(ar));
        vm.expectRevert(bytes("ops: address book is for another chain"));
        probe.load(book);
    }

    function test_refusesAnAddressWithNoCode() public {
        string memory book = _writeBook("nocode", block.chainid, address(reg), address(jr), address(ar));
        // rewrite providerRegistry to an EOA, leaving the separator field intact — the shape a
        // stale book has after a redeploy
        vm.writeJson(vm.toString(makeAddr("eoa")), book, ".providerRegistry");
        vm.expectRevert(bytes("ops: no code at providerRegistry"));
        probe.load(book);
    }

    /// @dev the load-bearing check: a fork shares its network's chain id, so a chain-id match
    /// proves little. A separator mismatch is the only cheap proof of "the right contract on the
    /// right chain", and it is what catches a book pointing at a redeployed registry.
    function test_refusesASeparatorMismatch() public {
        string memory book = _writeBook("sep", block.chainid, address(reg), address(jr), address(ar));
        ProviderRegistry other = new ProviderRegistry(curation);
        vm.writeJson(vm.toString(address(other)), book, ".providerRegistry");
        vm.expectRevert(bytes("ops: providerRegistry domain separator mismatch"));
        probe.load(book);
    }

    /**
     * @dev The headline property of this task: on a network whose book says `dev: false`, `_exec`
     * simulates and prints, and broadcasts nothing. The simulation deliberately DOES mutate local
     * state — that is how it proves the op succeeds before anyone signs for it — so the assertion
     * that carries the property is the broadcast count, not the target's state.
     */
    function test_execBroadcastsNothingOnANonDevNetwork() public {
        execProbe.load(_writeBook("exec", block.chainid, address(reg), address(jr), address(ar)));
        execProbe.setDev(false);

        address target = makeAddr("safePathJobRegistry");
        execProbe.exec(address(reg), abi.encodeCall(ProviderRegistry.setJobRegistry, (target, true)));

        assertEq(execProbe.broadcasts(), 0, "Safe path broadcast");
        assertTrue(reg.isJobRegistry(target), "Safe path did not simulate the op as curation");
    }

    /// @dev the other half of the switch, so the test above cannot pass by `_exec` doing nothing
    function test_execBroadcastsOnADevNetwork() public {
        execProbe.load(_writeBook("exec", block.chainid, address(reg), address(jr), address(ar)));

        address target = makeAddr("devPathJobRegistry");
        // No `setEnv`: `ExecProbe` injects the fixture key and still runs the real
        // `vm.addr(curationPk) == curationAddr` assertion, so the key check is exercised, not
        // bypassed — and the suite does not care what the developer has exported.
        execProbe.exec(address(reg), abi.encodeCall(ProviderRegistry.setJobRegistry, (target, true)));

        assertEq(execProbe.broadcasts(), 1, "dev path did not broadcast");
        assertTrue(reg.isJobRegistry(target), "dev path did not apply the op");
    }

    /**
     * @dev `_bubble` is the single line that turns the Safe-path simulation into a REFUSAL, so it
     * is the one this pair pins. Neutered, `_exec` prints `simulated OK as curation` and invites the
     * operator to paste `to` and `data` into the Safe for an op the chain would reject — the
     * simulation would then prove nothing, which is the entire claim the Safe path is sold on.
     *
     * The assertion is the SELECTOR, deliberately, and it pins two things at once: that the failure
     * surfaces at all, and that the original error data was re-reverted rather than flattened. A
     * string assertion would also pass against a `require(ok, "...")`, which is exactly the
     * degradation `_bubble`'s NatSpec promises against.
     *
     * Provider 99 is unregistered, so `_rec` reverts `UnknownProviderId` — an error carrying no
     * arguments, so the whole revert payload is the four selector bytes.
     */
    function test_bubbleRefusesAFailingOpOnTheSafePath() public {
        execProbe.load(_writeBook("bubbleSafe", block.chainid, address(reg), address(jr), address(ar)));
        execProbe.setDev(false);

        vm.expectRevert(ProviderRegistry.UnknownProviderId.selector);
        execProbe.exec(address(reg), abi.encodeCall(ProviderRegistry.setReputation, (99, 500)));
    }

    /// @dev the other half: on the dev path the call is the real one, so a swallowed failure would
    /// report an op as landed that never landed
    function test_bubbleRefusesAFailingOpOnTheDevPath() public {
        execProbe.load(_writeBook("bubbleDev", block.chainid, address(reg), address(jr), address(ar)));

        vm.expectRevert(ProviderRegistry.UnknownProviderId.selector);
        execProbe.exec(address(reg), abi.encodeCall(ProviderRegistry.setReputation, (99, 500)));
    }
}
