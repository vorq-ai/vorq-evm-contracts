// SPDX-License-Identifier: FSL-1.1-ALv2
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {AskRegistry} from "../../src/AskRegistry.sol";
import {IUSDC, JobRegistry} from "../../src/JobRegistry.sol";
import {ProviderRegistry} from "../../src/ProviderRegistry.sol";

/// @notice The three registries wired exactly as `Deploy.s.sol` wires them, with a known curation
/// key. No fork and no funded client: every op under test is `onlyCuration`, so the job path is
/// not exercised here and a real payment token would only slow the suite down.
abstract contract OpsFixture is Test {
    ProviderRegistry internal reg;
    JobRegistry internal jr;
    AskRegistry internal ar;

    /// @dev an arbitrary fixture key. A harness reaches `OpsBase` with it by overriding
    /// `_requireCurationKey`, never by exporting `CURATION_PK` — see `ExecProbe`.
    uint256 internal curationPk = 0xC0FFEE;
    address internal curation;
    address internal treasury = makeAddr("treasury");
    address internal usdc = makeAddr("usdc");
    address internal operator = makeAddr("operator");

    function _deployFixture() internal {
        curation = vm.addr(curationPk);
        reg = new ProviderRegistry(curation);
        jr = new JobRegistry(reg, IUSDC(usdc), curation, treasury);
        ar = new AskRegistry(reg);
        vm.prank(curation);
        reg.setJobRegistry(address(jr), true);
    }

    /**
     * @dev The path is derived from the CALLING TEST, never supplied by it, so two tests cannot
     * write the same file. That is a correctness requirement, not tidiness: foundry runs the tests
     * in one contract IN PARALLEL, and `vm.writeJson` truncates before it writes, so a shared path
     * lets one test's `vm.readFile` land inside another test's truncate window and read a
     * zero-length file. It surfaces as
     * `vm.parseJsonUint: failed parsing JSON: EOF while parsing a value at line 1 column 0`,
     * always on `.chainId` because that is the first field `_loadFrom` parses — which reads as a
     * malformed address book and sends the reader into `foundry.toml`, exactly the wrong place.
     * Measured before this was fixed: 5 failures in 300 runs of this file, across three different
     * tests. Serializing with `-j 1` also removes it, which is how the race was confirmed; it is
     * not the fix, because it would slow every future run to paper over a fixture bug.
     *
     * `msg.sig` is the test function's own selector: `_writeBook` is `internal`, so it shares the
     * test's call frame rather than opening a new one. `label` separates several books written by
     * a single test.
     */
    function _bookPath(string memory label) internal view returns (string memory) {
        return string.concat("./out-addresses/ops-", vm.toString(msg.sig), "-", label, ".json");
    }

    /// @dev writes the book and returns the path it chose — see `_bookPath` for why the caller
    /// does not get to name it. `label` need only be unique within one test.
    function _writeBook(string memory label, uint256 chainId, address pr, address jrAddr, address arAddr)
        internal
        returns (string memory path)
    {
        path = _bookPath(label);
        string memory obj = "book";
        vm.serializeUint(obj, "chainId", chainId);
        vm.serializeBool(obj, "dev", true);
        vm.serializeAddress(obj, "providerRegistry", pr);
        vm.serializeAddress(obj, "jobRegistry", jrAddr);
        vm.serializeAddress(obj, "askRegistry", arAddr);
        vm.serializeBytes32(obj, "providerRegistryDomainSeparator", ProviderRegistry(pr).DOMAIN_SEPARATOR());
        vm.serializeBytes32(obj, "jobRegistryDomainSeparator", JobRegistry(jrAddr).DOMAIN_SEPARATOR());
        string memory json =
            vm.serializeBytes32(obj, "askRegistryDomainSeparator", AskRegistry(arAddr).DOMAIN_SEPARATOR());
        vm.writeJson(json, path);
    }
}
