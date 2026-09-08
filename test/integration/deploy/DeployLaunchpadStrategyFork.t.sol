// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";

import {DeployLaunchpadStrategy} from "../../../script/robinhood-mainnet/DeployLaunchpadStrategy.s.sol";
import {LaunchpadStrategy} from "../../../src/strategies/LaunchpadStrategy.sol";
import {StonkLaunchAdapter} from "../../../src/adapters/StonkLaunchAdapter.sol";
import {SushiLaunchAdapter} from "../../../src/adapters/SushiLaunchAdapter.sol";
import {IStonkSafeLaunchpadV2} from "../../../src/vendor/stonkbrokers/IStonkSafeLaunchpadV2.sol";

/// @dev Lifts the two `internal view` gates into reach — the
///      `DeployConcentratedLiquidityStrategy.t.sol` harness precedent. Reading a
///      gate through a harness keeps the test about the RULE rather than about
///      staging files on disk, which matters more here than there: see the
///      suite header on why exactly one test in this file is allowed to write.
contract DeployLaunchpadHarness is DeployLaunchpadStrategy {
    function exposed_assertIsSushiLaunchpad(address launchpad, address weth) external view {
        _assertIsSushiLaunchpad(launchpad, weth);
    }

    function exposed_stonkLaneSet() external view returns (address[] memory quotes, address[] memory pads) {
        return _stonkLaneSet();
    }

    function exposed_requireNoV3Pads(address[] memory pads, string[8] memory lanes) external view {
        _requireNoV3Pads(pads, lanes);
    }
}

/**
 * @title DeployLaunchpadStrategyForkTest
 * @notice FORK REHEARSAL of `script/robinhood-mainnet/DeployLaunchpadStrategy.s.sol`,
 *         which has never been executed anywhere. The script is mainnet-only by
 *         construction — both venues exist on 4663 and nowhere else — so a 4663
 *         fork is the only place its guards can be exercised at all, and the
 *         only place its happy path can be.
 *
 *         WHAT THIS SUITE IS FOR. The guards are not decoration. On this chain
 *         the canonical Uniswap mainnet addresses each hold ~2110 bytes of an
 *         UNRELATED contract (see `addresses/4663.json`), so `code.length != 0`
 *         passes on the wrong address, the ceremony completes, agents write
 *         proposals, and every one of them reverts a governance cycle later.
 *         `_assertIsSushiLaunchpad` exists to make that impossible.
 *
 * @dev ONE WRITER, ON PURPOSE. `run()` persists through
 *      `ScriptBase._patchAddress`, which rewrites (and reformats) the REAL
 *      `chains/4663.json`. Foundry executes the tests of a suite concurrently
 *      while they share one filesystem, so a second file-mutating test does not
 *      merely risk a dirty repo — it makes every test that reads the book
 *      flaky, which is exactly what an earlier draft of this file did. Only
 *      `test_run_ceremonyCompletesOnA4663Fork` touches disk; it snapshots the
 *      book, runs, and restores it BYTE-FOR-BYTE before asserting anything, so
 *      a failing assertion cannot leave the repo modified either. Every other
 *      test reaches the same rules through the harness, or through the same
 *      constructor `run()` would have called, and writes nothing.
 *
 *      Skips when ROBINHOOD_RPC_URL is unset (shared fork-test convention);
 *      excluded from default CI by the `test/integration/**` path filter. It
 *      lives under `test/integration/` rather than beside `test/deploy/` for
 *      that reason — it needs a live 4663 fork, and `test/deploy/` is the
 *      unforked lane CI runs on every push.
 *
 *      Run:
 *        ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com \
 *        forge test --match-path "test/integration/deploy/DeployLaunchpadStrategyFork.t.sol" -vv
 */
contract DeployLaunchpadStrategyForkTest is Test {
    /// @dev Robinhood Chain MaxCodeSize — 4x EIP-170. Mirrors the script.
    uint256 constant ROBINHOOD_MAX_CODE_SIZE = 98_304;

    // ── addresses resolved on-chain (chains/4663.json, addresses/4663.json) ──
    address constant SUSHI_LAUNCHPAD_V1 = 0x104F1Ab42674565EC3DF0BFEbCcC4186f72fA7ED;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;

    /// @dev THE HAZARD, IN ONE ADDRESS. The canonical Uniswap V3 factory address
    ///      holds 2110 bytes of unrelated bytecode on 4663 — codeful, and
    ///      answers none of the launchpad's getters. Filing it as
    ///      `SUSHI_LAUNCHPAD_V1` is precisely the mistake the identity round
    ///      trip exists to catch, and `code.length != 0` would wave it through.
    address constant CODEFUL_BUT_UNRELATED = 0x1F98431c8aD98523631AE4a59f267346ea31F984;

    /// @dev The eight V2 (mint-launch) lanes in the SCRIPT'S OWN ORDER. The
    ///      order is part of `padSetHash`, which is why it is pinned here
    ///      independently rather than read back off the adapter.
    string[8] LANES = ["WETH", "STONK", "USDG", "GME", "NVDA", "AAPL", "SPCX", "USO"];

    string bookPath;
    string pristineBook;
    bool forked;

    function setUp() public {
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        uint256 pin = vm.envOr("ROBINHOOD_FORK_BLOCK", uint256(0));
        if (pin == 0) {
            vm.createSelectFork(rpc);
        } else {
            vm.createSelectFork(rpc, pin);
        }
        // NORMALISE THE CHAIN ID. `ScriptBase._chainsPath()` derives the book
        // path from `block.chainid`, so the rehearsal reads `chains/4663.json`
        // only when the fork reports 4663 — which the archive vnet (9994663)
        // does not. Stamping it here lets the same suite rehearse on either
        // endpoint against the book the real ceremony will use.
        vm.chainId(4663);
        forked = true;

        bookPath = string.concat(vm.projectRoot(), "/chains/4663.json");
        pristineBook = vm.readFile(bookPath);
        // A previous run that died between patch and restore would poison every
        // assertion below. Fail loudly rather than testing a mangled book.
        require(
            vm.parseJsonAddress(pristineBook, ".SUSHI_LAUNCHPAD_V1") == SUSHI_LAUNCHPAD_V1,
            "chains/4663.json is not pristine - restore it before running this suite"
        );
    }

    // ── the happy path: the whole ceremony, once ──

    /// @notice The script runs to completion on a 4663 fork: both adapters and
    ///         the template are deployed and recorded, the template fits
    ///         Robinhood's 98,304-byte limit, and the `padSetHash` it prints is
    ///         reproducible from the address book by anyone holding it.
    ///
    /// @dev    Everything the happy path can assert is asserted HERE, in one
    ///         test, because this is the only test permitted to write the book.
    function test_run_ceremonyCompletesOnA4663Fork() public {
        if (!forked) return;

        DeployLaunchpadStrategy script = new DeployLaunchpadStrategy();
        script.run();
        string memory patched = vm.readFile(bookPath);
        // Restore FIRST. No assertion below can leave the repo's book modified.
        vm.writeFile(bookPath, pristineBook);
        assertEq(
            keccak256(bytes(vm.readFile(bookPath))),
            keccak256(bytes(pristineBook)),
            "the rehearsal left chains/4663.json modified"
        );

        address sushi = vm.parseJsonAddress(patched, ".SUSHI_LAUNCH_ADAPTER");
        address stonk = vm.parseJsonAddress(patched, ".STONK_LAUNCH_ADAPTER");
        address template = vm.parseJsonAddress(patched, ".LAUNCHPAD_TEMPLATE");

        assertTrue(sushi != address(0) && sushi.code.length != 0, "SUSHI_LAUNCH_ADAPTER");
        assertTrue(stonk != address(0) && stonk.code.length != 0, "STONK_LAUNCH_ADAPTER");
        assertTrue(template != address(0) && template.code.length != 0, "LAUNCHPAD_TEMPLATE");

        // Wired to the live venues, not merely constructed.
        assertEq(address(SushiLaunchAdapter(payable(sushi)).launchpad()), SUSHI_LAUNCHPAD_V1, "sushi venue");
        assertEq(SushiLaunchAdapter(payable(sushi)).weth(), WETH, "sushi fee source read off the venue");
        assertEq(StonkLaunchAdapter(stonk).implementation(), stonk, "the deployed Stonk adapter IS the implementation");

        // ── the Robinhood code-size limit ──
        uint256 size = template.code.length;
        console2.log("LaunchpadStrategy runtime size:", size);
        console2.log("Robinhood MaxCodeSize:         ", ROBINHOOD_MAX_CODE_SIZE);
        assertLt(size, ROBINHOOD_MAX_CODE_SIZE, "template exceeds Robinhood MaxCodeSize");
        // And it really is the template: a locked, vault-less clone source.
        assertEq(LaunchpadStrategy(payable(template)).vault(), address(0), "a template binds no vault");

        // ── padSetHash, recomputed from the book by an independent path ──
        (address[] memory quotes, address[] memory pads) = _laneSetFromBook();
        bytes32 expected = keccak256(abi.encode(quotes, pads));
        assertEq(
            StonkLaunchAdapter(stonk).padSetHash(),
            expected,
            "padSetHash is not keccak256(abi.encode(quotes, pads)) over the book's eight V2 lanes"
        );
        (address[] memory onChainQuotes, address[] memory onChainPads) = StonkLaunchAdapter(stonk).lanes();
        assertEq(onChainQuotes.length, 8, "eight V2 lanes, no V3 pads");
        for (uint256 i; i < 8; ++i) {
            assertEq(onChainQuotes[i], quotes[i], "lane quote order");
            assertEq(onChainPads[i], pads[i], "lane pad order");
        }
        console2.log("padSetHash:");
        console2.logBytes32(expected);
    }

    // ── the launchpad identity guard ──

    /// @notice THE CHAIN-SPECIFIC HAZARD. A codeful-but-unrelated address must
    ///         be refused. `code.length != 0` passes on it; the identity round
    ///         trip does not.
    function test_assertIsSushiLaunchpad_rejectsACodefulButUnrelatedAddress() public {
        if (!forked) return;

        assertTrue(CODEFUL_BUT_UNRELATED.code.length != 0, "the witness must be codeful, or it proves nothing");
        assertTrue(CODEFUL_BUT_UNRELATED != SUSHI_LAUNCHPAD_V1, "the witness must not be the venue");

        DeployLaunchpadHarness harness = new DeployLaunchpadHarness();
        // The squatting contract returns nothing decodable for `WETH()`, so the
        // round trip fails at its first hop rather than returning a wrong answer.
        vm.expectRevert();
        harness.exposed_assertIsSushiLaunchpad(CODEFUL_BUT_UNRELATED, WETH);
    }

    /// @notice The complement, and the reason the rejection above means
    ///         something: the REAL venue round-trips cleanly through the same
    ///         gate, so the guard is discriminating rather than merely strict.
    function test_assertIsSushiLaunchpad_acceptsTheRealVenue() public {
        if (!forked) return;

        DeployLaunchpadHarness harness = new DeployLaunchpadHarness();
        harness.exposed_assertIsSushiLaunchpad(SUSHI_LAUNCHPAD_V1, WETH);
    }

    /// @notice A codeless address is refused on presence, before any venue call.
    function test_assertIsSushiLaunchpad_rejectsACodelessAddress() public {
        if (!forked) return;

        DeployLaunchpadHarness harness = new DeployLaunchpadHarness();
        vm.expectRevert(bytes("SUSHI_LAUNCHPAD_V1 holds no code"));
        harness.exposed_assertIsSushiLaunchpad(makeAddr("nothingHere"), WETH);
    }

    /// @notice The round trip is two-directional: a WETH the venue disowns fails
    ///         too, so the book cannot disagree with the venue in either
    ///         direction.
    function test_assertIsSushiLaunchpad_rejectsAWethTheVenueDisowns() public {
        if (!forked) return;

        DeployLaunchpadHarness harness = new DeployLaunchpadHarness();
        vm.expectRevert(bytes("launchpad WETH() disagrees with the address book"));
        harness.exposed_assertIsSushiLaunchpad(SUSHI_LAUNCHPAD_V1, makeAddr("notWeth"));
    }

    // ── the Stonk lane set ──

    /// @notice The lanes the book actually names are internally consistent: each
    ///         pad claims its own lane's quote, and the eight quotes are
    ///         distinct. This is the precondition the two mis-file tests below
    ///         perturb.
    function test_stonkLaneSet_theBooksLanesAreConsistent() public {
        if (!forked) return;

        DeployLaunchpadHarness harness = new DeployLaunchpadHarness();
        (address[] memory quotes, address[] memory pads) = harness.exposed_stonkLaneSet();
        (address[] memory bookQuotes, address[] memory bookPads) = _laneSetFromBook();

        assertEq(quotes.length, 8, "eight lanes");
        for (uint256 i; i < 8; ++i) {
            assertEq(pads[i], bookPads[i], "pad from the book");
            assertEq(quotes[i], bookQuotes[i], "quote read off the pad");
            for (uint256 j; j < i; ++j) {
                assertTrue(quotes[i] != quotes[j], "two lanes claim the same quote");
            }
        }
    }

    /// @notice A MIS-FILED PAD MUST FAIL THE DEPLOY rather than ship a mis-wired
    ///         lane. The V2 USDG pad filed under the GME key makes two lanes
    ///         claim USDG, and `StonkLaunchAdapter`'s constructor refuses the
    ///         second — so the ceremony aborts with nothing deployed.
    ///
    /// @dev    WHICH GUARD FIRES MATTERS, because the script's own comment
    ///         credits the wrong one. `_stonkLaneSet` DERIVES each `quotes[i]`
    ///         by asking `pads[i].quote()`, so the constructor's
    ///         `PadQuoteMismatch` compares a value against itself and is
    ///         UNREACHABLE from this call path. What actually catches the
    ///         mis-file is `DuplicateQuote` — and only when the mis-filed pad
    ///         collides with another lane. See the next test for the case that
    ///         therefore slips through.
    ///
    ///         Reproduced through the constructor rather than by patching the
    ///         book on disk: `_stonkLaneSet` + `new StonkLaunchAdapter(...)` is
    ///         exactly what `run()` does with those arrays, and this file gets
    ///         one filesystem writer (see the suite header).
    function test_stonkLaneSet_misfiledV2PadFailsTheDeploy() public {
        if (!forked) return;

        // Lane 3 is GME; file the USDG pad there, the way a copy-paste would.
        (address[] memory quotes, address[] memory pads) = _laneSetWithPadSubstitutedAt(3, _bookPad("USDG"));
        assertEq(quotes[3], quotes[2], "premise: the mis-filed pad claims lane 2's quote");

        vm.expectRevert(abi.encodeWithSelector(StonkLaunchAdapter.DuplicateQuote.selector, quotes[2]));
        new StonkLaunchAdapter(quotes, pads, _bookAddress("SAFE_LAUNCH_LENS_V2"));
    }

    /// @notice THE GAP THIS REHEARSAL FOUND, pinned rather than papered over.
    ///
    ///         A V3 pad filed under a V2 key reports the SAME `quote()` as its V2
    ///         sibling — verified on-chain for every shared lane — so it collides
    ///         with nothing, `PadQuoteMismatch` cannot fire (the quote was read
    ///         off that very pad), and the DEPLOY COMPLETES with a lane pointed
    ///         at a BYO-token pad that this always-minting template can never
    ///         use. The only witness is `padSetHash`, and only a certifier who
    ///         recomputes it from the INTENDED pad list would ever see it.
    ///
    /// @dev    This test asserts the CURRENT behaviour. If the script grows a
    ///         V2/V3 discriminator, this test should flip to expecting a revert.
    /// @dev THE ADAPTER CANNOT CATCH THIS, AND THAT IS NOT ITS JOB. A V3
    ///      (external-token) pad reports the same `quote()` as its V2 sibling,
    ///      so filing one under a V2 key collides with no other lane and the
    ///      constructor's `DuplicateQuote` never fires; the constructor's
    ///      `PadQuoteMismatch` cannot fire either, since the script derives
    ///      each quote from the pad itself. The adapter has no notion of pad
    ///      families, so the deploy script has to carry the check — see the
    ///      test below, which is the one that matters.
    function test_stonkLaneSet_theAdapterAloneCannotSeeAV3Pad() public {
        if (!forked) return;

        address v3Usdg = _bookAddress("STONK_SAFE_LAUNCHPAD_V3_USDG");
        address v2Usdg = _bookPad("USDG");
        assertEq(
            IStonkSafeLaunchpadV2(v3Usdg).quote(),
            IStonkSafeLaunchpadV2(v2Usdg).quote(),
            "premise: the V3 pad claims the same quote as its V2 sibling"
        );

        (address[] memory quotes, address[] memory pads) = _laneSetWithPadSubstitutedAt(2, v3Usdg);
        StonkLaunchAdapter misWired = new StonkLaunchAdapter(quotes, pads, _bookAddress("SAFE_LAUNCH_LENS_V2"));
        assertEq(misWired.padOf(quotes[2]), v3Usdg, "the adapter wires it in without complaint");
    }

    /// @dev THE SCRIPT DOES catch it — this is the guard that closes the hole
    ///      the test above documents. Without it the ceremony completes with a
    ///      lane pointed at a bring-your-own-token pad that this always-minting
    ///      template can never use, and `padSetHash` is the only witness.
    function test_stonkLaneSet_scriptRejectsAV3PadFiledUnderAV2Key() public {
        if (!forked) return;

        DeployLaunchpadHarness harness = new DeployLaunchpadHarness();
        string[8] memory lanes = ["WETH", "STONK", "USDG", "GME", "NVDA", "AAPL", "SPCX", "USO"];

        // Sanity: the book's own lane set passes the guard untouched.
        (, address[] memory goodPads) = _laneSetFromBook();
        harness.exposed_requireNoV3Pads(goodPads, lanes);

        // Substituting ANY V3 pad, under ANY lane key, is refused.
        (, address[] memory badPads) = _laneSetWithPadSubstitutedAt(2, _bookAddress("STONK_SAFE_LAUNCHPAD_V3_USDG"));
        vm.expectRevert(bytes("a V3 (external-token) pad is filed under a V2 lane key"));
        harness.exposed_requireNoV3Pads(badPads, lanes);

        // ...including one whose own lane differs from the key it sits under,
        // which is the case `DuplicateQuote` would also have missed.
        (, address[] memory crossPads) = _laneSetWithPadSubstitutedAt(4, _bookAddress("STONK_SAFE_LAUNCHPAD_V3_GME"));
        vm.expectRevert(bytes("a V3 (external-token) pad is filed under a V2 lane key"));
        harness.exposed_requireNoV3Pads(crossPads, lanes);
    }

    // ── the chain guard ──

    /// @notice A script that can only work on 4663 must refuse to run anywhere
    ///         else, before it reads a book or deploys anything.
    function test_run_rejectsAWrongChainId() public {
        if (!forked) return;

        // Pick an id that is neither 4663 nor whatever the fork escape hatch
        // names, so the GUARD is under test rather than the environment.
        uint256 escape = vm.envOr("ROBINHOOD_FORK_CHAIN_ID", uint256(0));
        uint256 wrong = escape == 1 ? 2 : 1;
        vm.chainId(wrong);

        DeployLaunchpadStrategy script = new DeployLaunchpadStrategy();
        vm.expectRevert(bytes("wrong chain: expected Robinhood mainnet 4663 or ROBINHOOD_FORK_CHAIN_ID"));
        script.run();
    }

    // ── helpers (all read-only on the filesystem) ──

    function _bookAddress(string memory key) internal view returns (address) {
        return vm.parseJsonAddress(pristineBook, string.concat(".", key));
    }

    function _bookPad(string memory lane) internal view returns (address) {
        return _bookAddress(string.concat("STONK_SAFE_LAUNCHPAD_V2_", lane));
    }

    /// @dev `_stonkLaneSet`, reproduced from the book by an independent path —
    ///      so `padSetHash` is checked against the CONFIGURATION rather than
    ///      against the code that produced it.
    function _laneSetFromBook() internal view returns (address[] memory quotes, address[] memory pads) {
        quotes = new address[](8);
        pads = new address[](8);
        for (uint256 i; i < 8; ++i) {
            pads[i] = _bookPad(LANES[i]);
            quotes[i] = IStonkSafeLaunchpadV2(pads[i]).quote();
            assertTrue(quotes[i] != address(0), "pad reports no quote token");
        }
    }

    /// @dev The same derivation with ONE pad swapped — a mis-filed book, without
    ///      writing a mis-filed book. The substituted lane's quote is re-read off
    ///      the substituted pad, exactly as `_stonkLaneSet` would.
    function _laneSetWithPadSubstitutedAt(uint256 index, address pad)
        internal
        view
        returns (address[] memory quotes, address[] memory pads)
    {
        (quotes, pads) = _laneSetFromBook();
        pads[index] = pad;
        quotes[index] = IStonkSafeLaunchpadV2(pad).quote();
    }
}
