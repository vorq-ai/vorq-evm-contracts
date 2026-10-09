// SPDX-License-Identifier: FSL-1.1-ALv2
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {AskRegistry} from "../src/AskRegistry.sol";
import {ProviderRegistry} from "../src/ProviderRegistry.sol";
import {Ask, AskSnapshot} from "../src/Types.sol";
import {AskSig} from "./utils/AskSig.sol";
import {ZeroSignerRegistry} from "./utils/TestDoubles.sol";

contract AskRegistryTest is Test {
    AskRegistry ar;
    ProviderRegistry reg;
    address curation = makeAddr("curation");
    uint256 opPk; // assigned 0xA11CE in setUp
    address op;
    uint32 pid;
    address relayer = makeAddr("relayer"); // gas-only key, no registry standing

    function setUp() public {
        opPk = 0xA11CE;
        op = vm.addr(opPk);
        reg = new ProviderRegistry(curation);
        ar = new AskRegistry(reg);
        vm.prank(curation);
        pid = reg.register(op, 4, true, 1000);
    }

    function snap(uint64 signedAt, uint128 rateOut) internal view returns (AskSnapshot memory s) {
        Ask[] memory q = new Ask[](1);
        q[0] = Ask({modelId: 1, sla: 3600, rateIn: 30_000, rateOut: rateOut});
        s = AskSnapshot({providerId: pid, signedAt: signedAt, quotes: q});
    }

    /// The withdrawal snapshot: both legs zero, which is the only thing that deletes a slot.
    function zeroSnap(uint64 signedAt) internal view returns (AskSnapshot memory s) {
        Ask[] memory q = new Ask[](1);
        q[0] = Ask({modelId: 1, sla: 3600, rateIn: 0, rateOut: 0});
        s = AskSnapshot({providerId: pid, signedAt: signedAt, quotes: q});
    }

    function one(AskSnapshot memory s, bytes memory sig)
        internal
        pure
        returns (AskSnapshot[] memory b, bytes[] memory gs)
    {
        b = new AskSnapshot[](1);
        b[0] = s;
        gs = new bytes[](1);
        gs[0] = sig;
    }

    // --- the brief's cases ------------------------------------------------------------------

    function test_gas_only_relayer_lands_a_signed_snapshot() public {
        AskSnapshot memory s = snap(1000, 90_000);
        (AskSnapshot[] memory b, bytes[] memory gs) = one(s, AskSig.signSnapshot(vm, opPk, ar, s));
        vm.prank(relayer);
        ar.setAsks(b, gs);
        (uint128 ri, uint128 ro) = ar.getQuote(pid, 1, 3600);
        assertEq(ri, 30_000);
        assertEq(ro, 90_000);
        assertEq(ar.lastSignedAt(pid), 1000);
    }

    function test_stale_or_equal_signedAt_is_a_noop_duplicate() public {
        AskSnapshot memory s = snap(1000, 90_000);
        (AskSnapshot[] memory b, bytes[] memory gs) = one(s, AskSig.signSnapshot(vm, opPk, ar, s));
        ar.setAsks(b, gs);
        AskSnapshot memory older = snap(999, 50_000);
        (b, gs) = one(older, AskSig.signSnapshot(vm, opPk, ar, older));
        ar.setAsks(b, gs); // skipped silently
        (, uint128 ro) = ar.getQuote(pid, 1, 3600);
        assertEq(ro, 90_000);
        (b, gs) = one(s, AskSig.signSnapshot(vm, opPk, ar, s));
        ar.setAsks(b, gs); // exact duplicate: no-op
        (, ro) = ar.getQuote(pid, 1, 3600);
        assertEq(ro, 90_000);
        assertEq(ar.lastSignedAt(pid), 1000);
    }

    function test_bad_entry_skips_but_batch_lands() public {
        AskSnapshot memory good = snap(1000, 90_000);
        AskSnapshot memory forged = snap(2000, 1); // signed by wrong key
        AskSnapshot[] memory b = new AskSnapshot[](2);
        bytes[] memory gs = new bytes[](2);
        b[0] = forged;
        gs[0] = AskSig.signSnapshot(vm, 0xBAD, ar, forged);
        b[1] = good;
        gs[1] = AskSig.signSnapshot(vm, opPk, ar, good);
        ar.setAsks(b, gs);
        (, uint128 ro) = ar.getQuote(pid, 1, 3600);
        assertEq(ro, 90_000); // good landed, forged skipped
        assertEq(ar.lastSignedAt(pid), 1000); // and the forged 2000 never raised the floor
    }

    function test_both_rates_zero_withdraws() public {
        AskSnapshot memory s = snap(1000, 90_000);
        (AskSnapshot[] memory b, bytes[] memory gs) = one(s, AskSig.signSnapshot(vm, opPk, ar, s));
        ar.setAsks(b, gs);
        AskSnapshot memory w = zeroSnap(1001);
        (b, gs) = one(w, AskSig.signSnapshot(vm, opPk, ar, w));
        ar.setAsks(b, gs);
        (uint128 ri, uint128 ro) = ar.getQuote(pid, 1, 3600);
        assertEq(ri, 0); // the whole slot is deleted, not just the output leg
        assertEq(ro, 0);
    }

    /// An input-metered model — embeddings — has no output side to price: the backend reports
    /// `prompt_tokens` and nothing else, so the job settles at `completionTok == 0` and `rateOut`
    /// never enters the charge. That ask must be publishable as what it is. Were `rateOut == 0`
    /// still the withdraw sentinel on its own, publishing it would silently unpublish the slot,
    /// and the only way to appear in the book would be a fake output price.
    function test_an_input_only_ask_publishes_a_live_slot() public {
        AskSnapshot memory s = snap(1000, 0); // rateIn 30_000, rateOut 0
        (AskSnapshot[] memory b, bytes[] memory gs) = one(s, AskSig.signSnapshot(vm, opPk, ar, s));
        ar.setAsks(b, gs);
        (uint128 ri, uint128 ro) = ar.getQuote(pid, 1, 3600);
        assertEq(ri, 30_000, "the input leg is the whole price and it is live");
        assertEq(ro, 0, "there is no output leg to quote");
    }

    /// And it withdraws like any other slot, rather than being stuck published forever.
    function test_an_input_only_ask_can_still_be_withdrawn() public {
        AskSnapshot memory s = snap(1000, 0);
        (AskSnapshot[] memory b, bytes[] memory gs) = one(s, AskSig.signSnapshot(vm, opPk, ar, s));
        ar.setAsks(b, gs);
        AskSnapshot memory w = zeroSnap(1001);
        (b, gs) = one(w, AskSig.signSnapshot(vm, opPk, ar, w));
        ar.setAsks(b, gs);
        (uint128 ri,) = ar.getQuote(pid, 1, 3600);
        assertEq(ri, 0);
    }

    function test_operator_rotation_invalidates_old_snapshots() public {
        address op2 = makeAddr("op2");
        vm.prank(curation);
        reg.setOperator(pid, op2);
        AskSnapshot memory s = snap(1000, 90_000);
        (AskSnapshot[] memory b, bytes[] memory gs) = one(s, AskSig.signSnapshot(vm, opPk, ar, s));
        ar.setAsks(b, gs); // old key: idOf==0 → skip
        (, uint128 ro) = ar.getQuote(pid, 1, 3600);
        assertEq(ro, 0);
        assertEq(ar.lastSignedAt(pid), 0);
    }

    function test_oversized_snapshot_is_skipped() public {
        Ask[] memory q = new Ask[](65);
        for (uint256 i; i < 65; i++) {
            q[i] = Ask(uint32(i + 1), 3600, 1, 1);
        }
        AskSnapshot memory s = AskSnapshot(pid, 1000, q);
        (AskSnapshot[] memory b, bytes[] memory gs) = one(s, AskSig.signSnapshot(vm, opPk, ar, s));
        ar.setAsks(b, gs);
        assertEq(ar.lastSignedAt(pid), 0);
        (, uint128 ro) = ar.getQuote(pid, 1, 3600);
        assertEq(ro, 0); // not even a partial write
    }

    function test_far_future_signedAt_is_skipped() public {
        AskSnapshot memory s = snap(uint64(block.timestamp + 7200), 90_000);
        (AskSnapshot[] memory b, bytes[] memory gs) = one(s, AskSig.signSnapshot(vm, opPk, ar, s));
        ar.setAsks(b, gs);
        assertEq(ar.lastSignedAt(pid), 0); // a clock-bugged daemon cannot brick its slot
    }

    // --- the digest: the only check that a wrong type string or domain cannot survive ---------

    function test_typehashes_are_byte_exact() public view {
        // AskSig reads both typehashes AND the domain separator off the contract, so a wrong type
        // string, name, version or EIP712Domain type string round-trips through every other test in
        // this file. Recomputing all three from literals here is the only real check — Plan 2's
        // publisher and Plan 4's provider SDK reproduce this digest off-chain from these values.
        assertEq(ar.ASK_TYPEHASH(), keccak256("Ask(uint32 modelId,uint32 sla,uint128 rateIn,uint128 rateOut)"));
        assertEq(
            ar.SNAPSHOT_TYPEHASH(),
            keccak256(
                "AskSnapshot(uint32 providerId,uint64 signedAt,Ask[] quotes)Ask(uint32 modelId,uint32 sla,uint128 rateIn,uint128 rateOut)"
            )
        );
        assertEq(
            ar.DOMAIN_SEPARATOR(),
            keccak256(
                abi.encode(
                    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                    keccak256(bytes(ar.EIP712_NAME())),
                    keccak256("2"),
                    block.chainid,
                    address(ar)
                )
            )
        );
        // ask ops verify against THIS registry's domain, never the provider registry's
        assertTrue(ar.DOMAIN_SEPARATOR() != reg.DOMAIN_SEPARATOR());
    }

    /// @dev The one test that pins the DIGEST rather than the strings it is built from. `structHash`
    /// is a hardcoded fixture computed outside this repo — keccak of the EIP-712 encoding by hand —
    /// and the signature below is made over it, never over anything the contract produced. So it
    /// catches what `test_typehashes_are_byte_exact` cannot: the ENCODING. A swapped `providerId` /
    /// `signedAt` order, a wrong field width, or an `Ask[] quotes` member hashed as anything other
    /// than the keccak of the concatenated element hashes all break this even though AskSig would
    /// follow the contract into the same mistake and every other test would still pass.
    /// The domain half is deliberately the EIP-712 formula over literals and `address(ar)` — the
    /// contract's address cannot be a constant here, and the test above pins that the contract's own
    /// `DOMAIN_SEPARATOR` equals exactly this formula.
    function test_snapshot_digest_matches_a_hardcoded_fixture() public {
        Ask[] memory q = new Ask[](2);
        q[0] = Ask(1, 3600, 30_000, 90_000);
        q[1] = Ask(2, 86400, 10_000, 20_000);
        AskSnapshot memory s = AskSnapshot(1, 1000, q);
        assertEq(s.providerId, pid); // the fixture is computed for providerId 1

        bytes32 structHash = 0x0d4c93bea28ce137c4a558f72486e374be8f6e004c2380aeea9d81f4b81242dd;
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(ar.EIP712_NAME())),
                keccak256("2"),
                block.chainid,
                address(ar)
            )
        );
        (uint8 v, bytes32 r, bytes32 sv) = vm.sign(opPk, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        (AskSnapshot[] memory b, bytes[] memory gs) = one(s, abi.encodePacked(r, sv, v));
        ar.setAsks(b, gs);

        // it landed, so the contract recovered `op` from a signature over the fixture digest — i.e.
        // the digest the contract computes for this snapshot IS the fixture. A skip would be silent,
        // which is why every slot is checked rather than just the floor.
        assertEq(ar.lastSignedAt(pid), 1000);
        (uint128 ri, uint128 ro) = ar.getQuote(pid, 1, 3600);
        assertEq(ri, 30_000);
        assertEq(ro, 90_000);
        (ri, ro) = ar.getQuote(pid, 2, 86400);
        assertEq(ri, 10_000);
        assertEq(ro, 20_000);
    }

    // --- the only reverting path -------------------------------------------------------------

    function test_length_mismatch_reverts_the_whole_call() public {
        AskSnapshot memory s = snap(1000, 90_000);
        (AskSnapshot[] memory b, bytes[] memory gs) = one(s, AskSig.signSnapshot(vm, opPk, ar, s));
        bytes[] memory noSigs = new bytes[](0);
        vm.expectRevert(AskRegistry.LengthMismatch.selector);
        ar.setAsks(b, noSigs);
        AskSnapshot[] memory noSnaps = new AskSnapshot[](0);
        vm.expectRevert(AskRegistry.LengthMismatch.selector);
        ar.setAsks(noSnaps, gs);
        assertEq(ar.lastSignedAt(pid), 0);
    }

    // --- bounds ------------------------------------------------------------------------------

    function test_max_quotes_boundary_accepts_exactly_64() public {
        assertEq(ar.MAX_QUOTES(), 64);
        Ask[] memory q = new Ask[](64);
        for (uint256 i; i < 64; i++) {
            q[i] = Ask(uint32(i + 1), 3600, 1, 7);
        }
        AskSnapshot memory s = AskSnapshot(pid, 1000, q);
        (AskSnapshot[] memory b, bytes[] memory gs) = one(s, AskSig.signSnapshot(vm, opPk, ar, s));
        ar.setAsks(b, gs);
        assertEq(ar.lastSignedAt(pid), 1000);
        (uint128 ri, uint128 ro) = ar.getQuote(pid, 64, 3600); // the last quote landed too
        assertEq(ri, 1);
        assertEq(ro, 7);
    }

    function test_skew_ceiling_is_inclusive() public {
        AskSnapshot memory over = snap(uint64(block.timestamp + 3601), 11);
        (AskSnapshot[] memory b, bytes[] memory gs) = one(over, AskSig.signSnapshot(vm, opPk, ar, over));
        ar.setAsks(b, gs);
        assertEq(ar.lastSignedAt(pid), 0); // one second past the ceiling is skipped
        AskSnapshot memory at = snap(uint64(block.timestamp + 3600), 12);
        (b, gs) = one(at, AskSig.signSnapshot(vm, opPk, ar, at));
        ar.setAsks(b, gs);
        assertEq(ar.lastSignedAt(pid), uint64(block.timestamp + 3600)); // exactly at it lands
        (, uint128 ro) = ar.getQuote(pid, 1, 3600);
        assertEq(ro, 12);
    }

    function test_monotonic_floor_is_strict() public {
        AskSnapshot memory s = snap(1000, 90_000);
        (AskSnapshot[] memory b, bytes[] memory gs) = one(s, AskSig.signSnapshot(vm, opPk, ar, s));
        ar.setAsks(b, gs);
        // a DIFFERENT payload at the same signedAt must not overwrite: the floor is `<=`, not `<`
        AskSnapshot memory sameSecond = snap(1000, 1);
        (b, gs) = one(sameSecond, AskSig.signSnapshot(vm, opPk, ar, sameSecond));
        ar.setAsks(b, gs);
        (, uint128 ro) = ar.getQuote(pid, 1, 3600);
        assertEq(ro, 90_000);
        AskSnapshot memory next = snap(1001, 2);
        (b, gs) = one(next, AskSig.signSnapshot(vm, opPk, ar, next));
        ar.setAsks(b, gs);
        (, ro) = ar.getQuote(pid, 1, 3600);
        assertEq(ro, 2); // one second later is enough
        assertEq(ar.lastSignedAt(pid), 1001);
    }

    function test_packing_round_trips_at_uint128_max() public {
        Ask[] memory q = new Ask[](2);
        q[0] = Ask(7, 86400, type(uint128).max, type(uint128).max);
        q[1] = Ask(8, 86400, 0, type(uint128).max); // a zero rateIn is a real quote, not an absence
        AskSnapshot memory s = AskSnapshot(pid, 1000, q);
        (AskSnapshot[] memory b, bytes[] memory gs) = one(s, AskSig.signSnapshot(vm, opPk, ar, s));
        ar.setAsks(b, gs);
        (uint128 ri, uint128 ro) = ar.getQuote(pid, 7, 86400);
        assertEq(ri, type(uint128).max);
        assertEq(ro, type(uint128).max);
        (ri, ro) = ar.getQuote(pid, 8, 86400);
        assertEq(ri, 0);
        assertEq(ro, type(uint128).max);
    }

    function test_getQuote_of_an_absent_slot_is_zero() public view {
        (uint128 ri, uint128 ro) = ar.getQuote(pid, 1, 3600); // never published
        assertEq(ri, 0);
        assertEq(ro, 0);
        (ri, ro) = ar.getQuote(999, 1, 3600); // provider that does not exist at all
        assertEq(ri, 0);
        assertEq(ro, 0);
    }

    // --- binding, skip semantics, and the event ----------------------------------------------

    function test_snapshot_binds_its_own_providerId() public {
        AskSnapshot memory s = snap(1000, 90_000);
        s.providerId = pid + 7; // a real operator cannot publish a book for someone else's id
        (AskSnapshot[] memory b, bytes[] memory gs) = one(s, AskSig.signSnapshot(vm, opPk, ar, s));
        ar.setAsks(b, gs);
        assertEq(ar.lastSignedAt(pid), 0);
        assertEq(ar.lastSignedAt(pid + 7), 0);
        (, uint128 ro) = ar.getQuote(pid + 7, 1, 3600);
        assertEq(ro, 0);
    }

    function test_a_snapshot_claiming_providerId_zero_is_skipped() public {
        AskSnapshot memory s = snap(1000, 90_000);
        s.providerId = 0; // the one id the providerId match cannot reject on its own
        // signed by a key that is in no registry: idOf[signer] == 0 == s.providerId, so only the
        // explicit `id == 0` guard stops a stranger from writing a book under the null provider
        (AskSnapshot[] memory b, bytes[] memory gs) = one(s, AskSig.signSnapshot(vm, 0xBAD, ar, s));
        ar.setAsks(b, gs);
        assertEq(ar.lastSignedAt(0), 0);
        (, uint128 ro) = ar.getQuote(0, 1, 3600);
        assertEq(ro, 0);
    }

    function test_every_skip_is_a_continue_and_writes_nothing() public {
        // One entry for each skip reason that a fresh floor can reach — every reason except
        // staleness, which needs a floor already in place and so lives in the test below. Each sits
        // at a signedAt far ABOVE the good entry's 1000, and the good entry is LAST. It landing
        // proves three things at once: every skip is a `continue` and not a `break`/`revert`, no
        // skip bumped the floor (1000 would then be stale), and no skip wrote a slot. The recorded
        // log count proves the fourth: no skip emitted AsksPublished, which is Plan 2's projection
        // surface. `bothWrong` trips two conditions at once (65 quotes AND a signedAt past the skew
        // ceiling); this does not pin their relative order — no skip path writes or logs, so the
        // reasons are indistinguishable from state — it pins that two reasons at once still skip
        // exactly once and silently.
        // The warp buys headroom under the +3600 ceiling: at the default timestamp of 1 the ceiling
        // is 3601, so a signedAt of 9000 would be caught by the skew check and the entries below
        // would never reach the paths they exist to exercise.
        vm.warp(10_000);
        Ask[] memory big = new Ask[](65);
        for (uint256 i; i < 65; i++) {
            big[i] = Ask(uint32(i + 1), 3600, 1, 7);
        }
        AskSnapshot memory oversized = AskSnapshot(pid, 9000, big);
        AskSnapshot memory bothWrong = AskSnapshot(pid, uint64(block.timestamp + 3601), big);
        AskSnapshot memory future = snap(uint64(block.timestamp + 3601), 8);
        AskSnapshot memory zeroSigner = snap(9000, 9);
        AskSnapshot memory forged = snap(9000, 10);
        AskSnapshot memory wrongId = snap(9000, 11);
        wrongId.providerId = pid + 7;
        AskSnapshot memory good = snap(1000, 90_000);

        AskSnapshot[] memory b = new AskSnapshot[](7);
        bytes[] memory gs = new bytes[](7);
        b[0] = oversized;
        gs[0] = AskSig.signSnapshot(vm, opPk, ar, oversized);
        b[1] = bothWrong;
        gs[1] = AskSig.signSnapshot(vm, opPk, ar, bothWrong);
        b[2] = future;
        gs[2] = AskSig.signSnapshot(vm, opPk, ar, future);
        b[3] = zeroSigner;
        gs[3] = new bytes(65); // v == 0 ⇒ ecrecover answers address(0)
        b[4] = forged;
        gs[4] = AskSig.signSnapshot(vm, 0xBAD, ar, forged);
        b[5] = wrongId;
        gs[5] = AskSig.signSnapshot(vm, opPk, ar, wrongId);
        b[6] = good;
        gs[6] = AskSig.signSnapshot(vm, opPk, ar, good);
        vm.recordLogs();
        ar.setAsks(b, gs);

        // exactly one log for seven entries: a skipped entry must never reach the emit, or a forged
        // book would land in Plan 2's projection even though no slot changed
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "a skipped entry emitted a log");
        assertEq(logs[0].emitter, address(ar));
        assertEq(logs[0].topics[0], AskRegistry.AsksPublished.selector);
        assertEq(logs[0].topics[1], bytes32(uint256(pid))); // the accepted entry, not a skipped one

        assertEq(ar.lastSignedAt(pid), 1000); // the good entry, six skips later
        (uint128 ri, uint128 ro) = ar.getQuote(pid, 1, 3600);
        assertEq(ri, 30_000);
        assertEq(ro, 90_000);
        (, ro) = ar.getQuote(pid, 65, 3600); // the oversized entry wrote nothing, not even partly
        assertEq(ro, 0);
        assertEq(ar.lastSignedAt(pid + 7), 0);
    }

    function test_a_stale_entry_does_not_block_a_newer_one_in_the_same_batch() public {
        // the stale skip is the only one that needs a floor already in place, so it needs its own
        // batch: a good entry, then a stale entry, then a newer entry that must still land
        AskSnapshot memory g1 = snap(1000, 90_000);
        AskSnapshot memory stale = snap(999, 1);
        AskSnapshot memory g2 = snap(1001, 91_000);
        g2.quotes[0].modelId = 2; // a different slot, so each landing is separately observable
        AskSnapshot[] memory b = new AskSnapshot[](3);
        bytes[] memory gs = new bytes[](3);
        b[0] = g1;
        gs[0] = AskSig.signSnapshot(vm, opPk, ar, g1);
        b[1] = stale;
        gs[1] = AskSig.signSnapshot(vm, opPk, ar, stale);
        b[2] = g2;
        gs[2] = AskSig.signSnapshot(vm, opPk, ar, g2);
        ar.setAsks(b, gs);
        (, uint128 ro1) = ar.getQuote(pid, 1, 3600);
        assertEq(ro1, 90_000); // the first entry landed, and the stale one did not overwrite it
        (, uint128 ro2) = ar.getQuote(pid, 2, 3600);
        assertEq(ro2, 91_000); // and the stale entry did not abort the batch
        assertEq(ar.lastSignedAt(pid), 1001);
    }

    function test_zero_signer_never_authorizes_even_on_a_poisoned_registry() public {
        ZeroSignerRegistry zreg = new ZeroSignerRegistry(curation);
        vm.prank(curation);
        uint32 zpid = zreg.register(op, 4, true, 1000);
        assertEq(zpid, pid);
        zreg.forceZeroSignerRecord(zpid); // idOf[address(0)] now resolves to a real provider
        AskRegistry zar = new AskRegistry(zreg);

        AskSnapshot memory s = snap(1000, 90_000);
        (AskSnapshot[] memory b, bytes[] memory gs) = one(s, new bytes(65)); // v == 0 ⇒ address(0)
        zar.setAsks(b, gs);
        assertEq(zar.lastSignedAt(zpid), 0);
        (b, gs) = one(s, hex"00"); // wrong length ⇒ address(0)
        zar.setAsks(b, gs);
        assertEq(zar.lastSignedAt(zpid), 0);
        (, uint128 ro) = zar.getQuote(zpid, 1, 3600);
        assertEq(ro, 0);
    }

    function test_a_snapshot_upserts_each_quote_and_withdraws_only_the_zeroed_one() public {
        Ask[] memory q = new Ask[](2);
        q[0] = Ask(1, 3600, 30_000, 90_000);
        q[1] = Ask(2, 86400, 10_000, 20_000);
        AskSnapshot memory s = AskSnapshot(pid, 1000, q);
        (AskSnapshot[] memory b, bytes[] memory gs) = one(s, AskSig.signSnapshot(vm, opPk, ar, s));
        ar.setAsks(b, gs);

        Ask[] memory q2 = new Ask[](1);
        q2[0] = Ask(1, 3600, 0, 0); // withdraw model 1 only; model 2 is not mentioned
        AskSnapshot memory s2 = AskSnapshot(pid, 1001, q2);
        (b, gs) = one(s2, AskSig.signSnapshot(vm, opPk, ar, s2));
        ar.setAsks(b, gs);

        // the whole slot is gone, not just its output leg — assert both, or an input-only
        // republish would read as a withdrawal here
        (uint128 ri, uint128 ro) = ar.getQuote(pid, 1, 3600);
        assertEq(ri, 0);
        assertEq(ro, 0);
        // on chain the write is an upsert: an omitted slot keeps its value until it is withdrawn
        (uint128 ri2, uint128 ro2) = ar.getQuote(pid, 2, 86400);
        assertEq(ri2, 10_000);
        assertEq(ro2, 20_000);
    }

    function test_batch_entries_apply_in_order_against_the_moving_floor() public {
        AskSnapshot memory first = snap(1000, 90_000);
        AskSnapshot memory second = snap(1001, 91_000);
        AskSnapshot[] memory b = new AskSnapshot[](2);
        bytes[] memory gs = new bytes[](2);
        b[0] = first;
        gs[0] = AskSig.signSnapshot(vm, opPk, ar, first);
        b[1] = second;
        gs[1] = AskSig.signSnapshot(vm, opPk, ar, second);
        ar.setAsks(b, gs);
        (, uint128 ro) = ar.getQuote(pid, 1, 3600);
        assertEq(ro, 91_000);
        assertEq(ar.lastSignedAt(pid), 1001);

        // reversed: the newer entry moves the floor past the older one inside the same call
        AskSnapshot memory newer = snap(1003, 93_000);
        AskSnapshot memory older = snap(1002, 92_000);
        b[0] = newer;
        gs[0] = AskSig.signSnapshot(vm, opPk, ar, newer);
        b[1] = older;
        gs[1] = AskSig.signSnapshot(vm, opPk, ar, older);
        ar.setAsks(b, gs);
        (, ro) = ar.getQuote(pid, 1, 3600);
        assertEq(ro, 93_000);
        assertEq(ar.lastSignedAt(pid), 1003);
    }

    function test_asks_published_carries_the_complete_snapshot() public {
        Ask[] memory q = new Ask[](2);
        q[0] = Ask(1, 3600, 30_000, 90_000);
        q[1] = Ask(2, 86400, 0, 0); // a withdrawal is part of the published snapshot too
        AskSnapshot memory s = AskSnapshot(pid, 1000, q);
        (AskSnapshot[] memory b, bytes[] memory gs) = one(s, AskSig.signSnapshot(vm, opPk, ar, s));
        vm.expectEmit(true, false, false, true);
        emit AskRegistry.AsksPublished(pid, 1000, q);
        ar.setAsks(b, gs);
    }
}
