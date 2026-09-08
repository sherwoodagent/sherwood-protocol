// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ILaunchAdapter} from "../../../src/interfaces/ILaunchAdapter.sol";
import {StonkLaunchAdapter} from "../../../src/adapters/StonkLaunchAdapter.sol";
import {IStonkSafeLaunchpadV2} from "../../../src/vendor/stonkbrokers/IStonkSafeLaunchpadV2.sol";

/// @notice Minimal WETH9 surface — the fork funds itself by WRAPPING native
///         ETH rather than `deal`-ing a balance slot, so the quote token's own
///         accounting is what pays for every buy below.
interface IWETH9 {
    function deposit() external payable;
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

/// @notice Pad surface deliberately ABSENT from
///         `src/vendor/stonkbrokers/IStonkSafeLaunchpadV2.sol` and needed only
///         to PROBE the venue here. `sell` in particular is omitted from the
///         vendored interface on purpose (the adapter must never grow a sell
///         path); this test re-declares it locally so the venue's answer can be
///         recorded without widening the production surface.
interface IStonkPadProbe {
    function sell(uint256 id, uint256 tokensIn, uint256 minQuoteOut, bytes32 ref, address account, bool ethOut)
        external
        returns (uint256 quoteOut);
    function boughtOf(uint256 id, address who) external view returns (uint256);
    function bufferSecsOf(uint256 id) external view returns (uint32);
    function closedAt(uint256 id) external view returns (uint64);
    function currentTaxBps(uint256 id) external view returns (uint256);
    function mcapUsd8(uint256 id) external view returns (uint256);
    function creatorFeeBps() external view returns (uint16);
    function protocolFeeBps() external view returns (uint16);
    function lpFeeBps() external view returns (uint16);
    function MAX_BUFFER_SECS() external view returns (uint32);
    function BUFFER_TAX_BPS() external view returns (uint256);
    function bounds()
        external
        view
        returns (
            uint64 minStartMcapUsd8,
            uint64 maxStartMcapUsd8,
            uint64 minGradMcapUsd8,
            uint64 maxGradMcapUsd8,
            uint16 maxStartTaxBps,
            uint32 minWindowSecs,
            uint32 maxWindowSecs
        );
}

/// @notice A plain, non-fee-on-transfer ERC-20 deployed BY THIS TEST CONTRACT —
///         i.e. an arbitrary contract's token, which is the bring-your-own case
///         Task 0.3 is about. Whole supply mints to the deployer so it can be
///         armed onto a pad's curve.
contract ForkExternalToken is ERC20 {
    constructor(string memory n, string memory s, uint256 supply) ERC20(n, s) {
        _mint(msg.sender, supply);
    }
}

/**
 * @title StonkLaunchRobinhoodForkTest
 * @notice Venue-fact fork test against the LIVE StonkBrokers Smart Launch pads
 *         on Robinhood Chain mainnet (4663). It exists to RESOLVE two open
 *         questions the spec left provisional, and its assertions ARE the
 *         record of the answers.
 *
 *         Addresses were resolved ON-CHAIN, not taken from a vendor address
 *         list: every pad below is asserted to claim its own lane through
 *         `quote()` in `setUp`, and the live fee/bounds configuration is
 *         re-asserted rather than assumed, because a canonical-looking address
 *         on this chain can hold unrelated code.
 *
 *   ── TASK 0.1 — THE NEVER-GRADUATES PATH. ANSWERED: THERE ISN'T ONE. ──
 *   Observed at block 50_934_300 on the WETH V2 pad
 *   (`0xFCd61B25BbF3AbD6cf0070D6328E351cc30EEC9f`):
 *
 *     (a) `graduate(id)` on a NON-open-ended launch SUCCEEDS after `deadline`
 *         with `gradMcapUsd8` unmet and buys present. Timer expiry is itself a
 *         graduation trigger, not a failure — the pad closes the curve on the
 *         clock. Before `deadline`, with the cap unmet, it reverts
 *         `NotGraduatable`. `bond(id)` then succeeds and mints the locked LP,
 *         so the launch reaches a TRADABLE POOL, never a dead end.
 *
 *         There is NO "inside `bufferSecs` but after the window" regime to
 *         test: `arm` sets `deadline = block.timestamp + bufferSecs +
 *         windowSecs`, so the buffer is an OPENING anti-snipe shield (99.99%
 *         tax while `elapsed < bufferSecs`) folded into the deadline, not a
 *         post-window grace period. `test_fork_bufferIsAnOpeningShield`
 *         pins that.
 *
 *     (b) The creator cannot recover ANYTHING directly in this state:
 *         `abort` reverts (`buyCount != 0`), and `sell` reverts `WindowClosed`
 *         past the deadline. But nothing is STRANDED either — the armed supply
 *         and the realized quote are not the creator's to recover; they belong
 *         to the timer close, which anyone may drive: `graduate` then `bond`
 *         moves the raise into a permanently locked LP and disposes of unsold
 *         supply per `unsoldMode`. Creator fee income is separate and already
 *         in hand: the pad PUSHES the creator's tax share at every trade and
 *         only accrues to `creatorQuoteOwed` if that push fails, so
 *         `flushCreatorQuote` reverts `NothingOwed` on a healthy ERC-20 lane.
 *
 *     (c) `getLaunch`/`modesOf` in this state read `armed && !graduated &&
 *         !bonded && !aborted`, `openEnded == false`, `deadline` in the past.
 *         Nothing in that flag set distinguishes "could still graduate" from
 *         "never will" — because the distinction does not exist: a closed
 *         window IS graduatable. `Failed` is reachable at this venue ONLY
 *         through `aborted`.
 *
 *     CONSEQUENCE, ASSERTED END-TO-END BY
 *     `test_fork_adapterPhase_closedWindowIsClosingThenLive`: the adapter's
 *     provisional `armed && !openEnded && now > deadline -> Failed` mapping was
 *     WRONG and is now `Closing`.
 *
 *   ── TASK 0.3 — V2 vs V3 PADS. ANSWERED: CONVENTION, NOT ENFORCEMENT. ──
 *   `createLaunch` with `token != address(0)` is ACCEPTED on a V2 pad exactly
 *   as it is on a V3 pad — both record `externalToken == true` and both arm the
 *   supplied token onto the curve. Nothing in either pad rejects a
 *   bring-your-own token, and the caller being an arbitrary contract changes
 *   nothing. Our V2-only pad set in the deploy script is therefore a CHOICE
 *   (the mint path is what hands the fund its whole supply as a free
 *   allocation), not a correctness requirement.
 *
 * @dev Skips when ROBINHOOD_RPC_URL is unset (shared fork-test convention);
 *      excluded from default CI via the `test/integration/**` path filter.
 *      Run explicitly:
 *        ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com \
 *        ROBINHOOD_FORK_BLOCK=50934300 \
 *        forge test --match-path "test/integration/strategies/StonkLaunchRobinhoodFork.t.sol" -vv
 */
contract StonkLaunchRobinhoodForkTest is Test {
    // ── venue addresses, each asserted against its own `quote()` in setUp ──

    /// @dev V2 (pad-mints-the-token) pads, one per quote lane.
    address constant PAD_V2_WETH = 0xFCd61B25BbF3AbD6cf0070D6328E351cc30EEC9f;
    address constant PAD_V2_USDG = 0xd4F20033586977A2511f4A2DB4aF7C79a340D70a;
    address constant PAD_V2_GME = 0x4B9Dcd6CCFAeF0f6D23065Dd78E79d5E20ec8cFD;
    /// @dev V3 (bring-your-own token) pad on the same lane as `PAD_V2_WETH`.
    address constant PAD_V3_WETH = 0x5BCEefBa6fDf437A7388aDC5c9056c827baca3B3;

    address constant LENS = 0x25b5Df581f4b2Ed450203f375ad8A28b17F115B3;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant GME = 0x1b0E319c6A659F002271B69dB8A7df2F911c153E;

    /// @dev The block every answer in the header was observed at. The public
    ///      RPC prunes to a sliding window, so this is passed through the
    ///      environment (`ROBINHOOD_FORK_BLOCK`) like the other 4663 fork tests
    ///      rather than hardcoded into `createSelectFork`; 0 = fork at latest.
    uint256 constant OBSERVED_AT_BLOCK = 50_934_300;

    // ── launch economics used throughout: NON-open-ended, minimum window ──

    uint256 constant SUPPLY = 1_000_000_000e18;
    /// @dev $10k start, $10M graduation — the pad's `maxGradMcapUsd8`. A
    ///      1000x is unreachable by the sub-cent buys below, which is what
    ///      makes this a genuinely never-graduating curve.
    uint64 constant START_MCAP_USD8 = 1e12;
    uint64 constant GRAD_MCAP_USD8 = 1e15;
    /// @dev `10_00 / 1_00 * 60 == 600` == the pad's `minWindowSecs`.
    uint16 constant START_TAX_BPS = 1000;
    uint16 constant DECAY_BPS_PER_MIN = 100;
    uint32 constant WINDOW_SECS = 600;
    uint32 constant BUFFER_SECS = 60;

    bool forked;
    address buyer = makeAddr("stonkBuyer");
    address feeSink = makeAddr("fundVault");

    function setUp() public {
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        uint256 pin = vm.envOr("ROBINHOOD_FORK_BLOCK", uint256(0));
        if (pin == 0) {
            vm.createSelectFork(rpc);
        } else {
            vm.createSelectFork(rpc, pin);
        }

        // ── Identity, not code presence. A pad that does not itself claim the
        //    lane is not the pad we mean, whatever the address looks like. ──
        assertEq(IStonkSafeLaunchpadV2(PAD_V2_WETH).quote(), WETH, "V2 WETH pad disowns the lane");
        assertEq(IStonkSafeLaunchpadV2(PAD_V3_WETH).quote(), WETH, "V3 WETH pad disowns the lane");
        assertEq(IStonkSafeLaunchpadV2(PAD_V2_USDG).quote(), USDG, "V2 USDG pad disowns the lane");
        assertEq(IStonkSafeLaunchpadV2(PAD_V2_GME).quote(), GME, "V2 GME pad disowns the lane");

        forked = true;
    }

    function _skipIfNoFork() internal {
        // `vm.skip` from the TEST BODY, never `setUp` — the setUp form reports
        // `[FAIL: skipped]` on the forge version CI runs.
        if (!forked) vm.skip(true);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // helpers
    // ─────────────────────────────────────────────────────────────────────────

    function _params(address token) internal pure returns (IStonkSafeLaunchpadV2.CreateParams memory p) {
        p = IStonkSafeLaunchpadV2.CreateParams({
            token: token,
            name: "Sherwood Fork Probe",
            symbol: "SFP",
            supply: SUPPLY,
            vanitySalt: bytes32(0),
            startMcapUsd8: START_MCAP_USD8,
            gradMcapUsd8: GRAD_MCAP_USD8,
            startTaxBps: START_TAX_BPS,
            taxDecayPerMinuteBps: DECAY_BPS_PER_MIN,
            sellsEnabled: true,
            bufferSecs: BUFFER_SECS,
            unsoldMode: 0,
            // FALSE on purpose: every verb below is a contract call, and the
            // adapter could not function on an `eoaOnly` launch.
            eoaOnly: false,
            openEnded: false,
            postTaxBps: 0,
            bondVenue: 0,
            maxBuyPpm: 0
        });
    }

    /// @dev Wrap native ETH into the lane's quote so buys are paid for out of
    ///      WETH's own accounting.
    function _fundWeth(address who, uint256 amount) internal {
        vm.deal(who, amount);
        vm.prank(who);
        IWETH9(WETH).deposit{value: amount}();
    }

    /// @dev create -> arm -> one buy, on the WETH V2 pad, with THIS CONTRACT as
    ///      creator. Returns the launch id and the token the pad minted.
    function _openArmedLaunchWithABuy() internal returns (uint256 id, address token) {
        (id, token) = IStonkSafeLaunchpadV2(PAD_V2_WETH).createLaunch(_params(address(0)));

        assertEq(IERC20(token).balanceOf(address(this)), SUPPLY, "mint path did not deliver supply to the creator");
        IERC20(token).approve(PAD_V2_WETH, SUPPLY);
        IStonkSafeLaunchpadV2(PAD_V2_WETH).arm(id, SUPPLY);

        // Past the opening buffer, so the buy pays the decaying window tax and
        // not the 99.99% anti-snipe shield — a real raise, not dust.
        IStonkSafeLaunchpadV2.Launch memory l = IStonkSafeLaunchpadV2(PAD_V2_WETH).getLaunch(id);
        vm.warp(uint256(l.startTime) + BUFFER_SECS + 1);

        _fundWeth(buyer, 0.05 ether);
        vm.startPrank(buyer);
        IWETH9(WETH).approve(PAD_V2_WETH, 0.05 ether);
        uint256 out = IStonkSafeLaunchpadV2(PAD_V2_WETH).buy(id, 0.05 ether, 0, bytes32(0), buyer);
        vm.stopPrank();
        assertGt(out, 0, "the probe buy bought nothing");

        l = IStonkSafeLaunchpadV2(PAD_V2_WETH).getLaunch(id);
        assertEq(l.buyCount, 1, "buyCount is what bars abort - it must be nonzero");
        assertGt(l.realQuote, 0, "no quote was realized by the buy");
        assertFalse(l.graduated, "a probe buy must not have reached the graduation cap");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // baseline — the venue economics the adapter and the spec depend on
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice The live configuration every other answer here is conditional on.
    function test_fork_venueEconomicsAreAsSpecified() public {
        _skipIfNoFork();

        address[3] memory pads = [PAD_V2_WETH, PAD_V2_USDG, PAD_V2_GME];
        for (uint256 i; i < pads.length; ++i) {
            assertEq(IStonkSafeLaunchpadV2(pads[i]).launchFeeWei(), 0, "a pad started charging a native launch fee");
            assertEq(IStonkPadProbe(pads[i]).creatorFeeBps(), 1650, "creator fee moved");
            (
                uint64 minStart,
                uint64 maxStart,
                uint64 minGrad,
                uint64 maxGrad,
                uint16 maxStartTax,
                uint32 minWindow,
                uint32 maxWindow
            ) = IStonkPadProbe(pads[i]).bounds();
            assertEq(minStart, 1e11, "minStartMcapUsd8");
            assertEq(maxStart, 1e14, "maxStartMcapUsd8");
            assertEq(minGrad, 5e12, "minGradMcapUsd8");
            assertEq(maxGrad, 1e15, "maxGradMcapUsd8");
            assertEq(maxStartTax, 9900, "maxStartTaxBps");
            assertEq(minWindow, 600, "minWindowSecs");
            assertEq(maxWindow, 5940, "maxWindowSecs");
        }
        // The economics chosen throughout this file sit inside those bounds.
        assertEq(uint256(START_TAX_BPS) / DECAY_BPS_PER_MIN * 60, WINDOW_SECS, "derived window drifted");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TASK 0.1 (a) — what `graduate` does on a closed, un-capped window
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice `bufferSecs` PRECEDES the window and is folded into `deadline`.
    /// @dev This is why the brief's "inside `bufferSecs` but after the window"
    ///      case has no on-chain existence: the buffer is the opening 99.99%-tax
    ///      anti-snipe shield, and `deadline == startTime + bufferSecs +
    ///      windowSecs` is the single wall for trades.
    function test_fork_bufferIsAnOpeningShield() public {
        _skipIfNoFork();

        (uint256 id, address token) = IStonkSafeLaunchpadV2(PAD_V2_WETH).createLaunch(_params(address(0)));
        IERC20(token).approve(PAD_V2_WETH, SUPPLY);
        IStonkSafeLaunchpadV2(PAD_V2_WETH).arm(id, SUPPLY);

        IStonkSafeLaunchpadV2.Launch memory l = IStonkSafeLaunchpadV2(PAD_V2_WETH).getLaunch(id);
        assertEq(l.windowSecs, WINDOW_SECS, "derived window");
        assertEq(IStonkPadProbe(PAD_V2_WETH).bufferSecsOf(id), BUFFER_SECS, "buffer recorded");
        assertEq(
            uint256(l.deadline),
            uint256(l.startTime) + BUFFER_SECS + WINDOW_SECS,
            "deadline is arm-time + buffer + window: the buffer is INSIDE the deadline, not after it"
        );

        // Opening shield: full 99.99% while `elapsed < bufferSecs`.
        vm.warp(uint256(l.startTime) + BUFFER_SECS - 1);
        assertEq(
            IStonkPadProbe(PAD_V2_WETH).currentTaxBps(id),
            IStonkPadProbe(PAD_V2_WETH).BUFFER_TAX_BPS(),
            "buffer tax not applied at the START of the launch"
        );
        // Then the decaying window tax.
        vm.warp(uint256(l.startTime) + BUFFER_SECS + 1);
        assertEq(IStonkPadProbe(PAD_V2_WETH).currentTaxBps(id), START_TAX_BPS, "window tax does not start after buffer");
    }

    /// @notice THE GATING ANSWER: a closed window with buys and the graduation
    ///         cap unmet DOES graduate — timer expiry is a close, not a failure.
    function test_fork_closedWindowWithBuys_graduatesOnTheTimer() public {
        _skipIfNoFork();

        (uint256 id,) = _openArmedLaunchWithABuy();
        IStonkSafeLaunchpadV2.Launch memory l = IStonkSafeLaunchpadV2(PAD_V2_WETH).getLaunch(id);

        // ── Before the deadline, cap unmet: REFUSED. ──
        vm.warp(uint256(l.deadline) - 1);
        assertLt(IStonkPadProbe(PAD_V2_WETH).mcapUsd8(id), GRAD_MCAP_USD8, "probe buy accidentally reached the cap");
        (bool early,) = PAD_V2_WETH.call(abi.encodeCall(IStonkSafeLaunchpadV2.graduate, (id)));
        assertFalse(early, "graduate must be refused (NotGraduatable) while the window is open and the cap unmet");

        // ── At the deadline: PERMITTED, cap still unmet. ──
        vm.warp(uint256(l.deadline));
        assertLt(IStonkPadProbe(PAD_V2_WETH).mcapUsd8(id), GRAD_MCAP_USD8, "cap must still be unmet");
        (bool onTime,) = PAD_V2_WETH.call(abi.encodeCall(IStonkSafeLaunchpadV2.graduate, (id)));
        assertTrue(onTime, "graduate MUST succeed at the deadline with the cap unmet (timer close)");

        l = IStonkSafeLaunchpadV2(PAD_V2_WETH).getLaunch(id);
        assertTrue(l.graduated, "timer close did not set graduated");
        assertFalse(l.bonded, "graduate must not bond");
        assertFalse(l.aborted, "a timer close is not an abort");
        assertEq(IStonkPadProbe(PAD_V2_WETH).closedAt(id), block.timestamp, "closedAt not stamped");

        // ── And it BONDS: the launch reaches a tradable pool, not a dead end. ──
        uint256 padQuoteBefore = IWETH9(WETH).balanceOf(PAD_V2_WETH);
        IStonkSafeLaunchpadV2(PAD_V2_WETH).bond(id);
        l = IStonkSafeLaunchpadV2(PAD_V2_WETH).getLaunch(id);
        assertTrue(l.bonded, "bond did not complete after a timer close");
        assertLt(IWETH9(WETH).balanceOf(PAD_V2_WETH), padQuoteBefore, "the raise never left the pad into the LP");
        console2.log("timer-closed raise bonded, quote wei moved", padQuoteBefore - IWETH9(WETH).balanceOf(PAD_V2_WETH));
    }

    /// @notice Deep past the deadline is the same answer — there is no expiry
    ///         on the timer close, so a launch can never age into unrecoverable.
    function test_fork_longAfterDeadline_stillGraduates() public {
        _skipIfNoFork();

        (uint256 id,) = _openArmedLaunchWithABuy();
        IStonkSafeLaunchpadV2.Launch memory l = IStonkSafeLaunchpadV2(PAD_V2_WETH).getLaunch(id);

        vm.warp(uint256(l.deadline) + 365 days);
        (bool ok,) = PAD_V2_WETH.call(abi.encodeCall(IStonkSafeLaunchpadV2.graduate, (id)));
        assertTrue(ok, "the timer close never expires");
        assertTrue(IStonkSafeLaunchpadV2(PAD_V2_WETH).getLaunch(id).graduated, "graduated flag not set a year later");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TASK 0.1 (b) — what the CREATOR can and cannot recover in that state
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice `abort` is barred, `sell` is barred, and the creator's fee income
    ///         was already PUSHED at trade time — so `flushCreatorQuote` has
    ///         nothing to pay. Nothing is recoverable by the creator, and
    ///         nothing is stranded: the value belongs to the timer close.
    function test_fork_closedWindowWithBuys_creatorCannotRecover() public {
        _skipIfNoFork();

        (uint256 id, address token) = _openArmedLaunchWithABuy();
        IStonkSafeLaunchpadV2.Launch memory l = IStonkSafeLaunchpadV2(PAD_V2_WETH).getLaunch(id);
        uint256 armedSupply = l.loadedSupply;
        uint256 realized = l.realQuote;

        vm.warp(uint256(l.deadline) + 1);

        // ── `abort`: barred by `buyCount != 0`, exactly as the adapter assumes. ──
        (bool aborted,) = PAD_V2_WETH.call(abi.encodeCall(IStonkSafeLaunchpadV2.abort, (id)));
        assertFalse(aborted, "abort MUST be refused once buyCount != 0");
        assertFalse(IStonkSafeLaunchpadV2(PAD_V2_WETH).getLaunch(id).aborted, "a refused abort must not latch");

        // ── `sell`: barred by the closed window, for the buyer AND the creator. ──
        uint256 held = IStonkPadProbe(PAD_V2_WETH).boughtOf(id, buyer);
        assertGt(held, 0, "buyer holds no curve credit");
        vm.startPrank(buyer);
        IERC20(token).approve(PAD_V2_WETH, held);
        (bool sold,) = PAD_V2_WETH.call(abi.encodeCall(IStonkPadProbe.sell, (id, held, 0, bytes32(0), buyer, false)));
        vm.stopPrank();
        assertFalse(sold, "sell MUST be refused (WindowClosed) past the deadline");

        // ── `flushCreatorQuote`: nothing owed, because the pad PUSHES the
        //    creator's 16.5% tax share at every trade and only accrues here if
        //    that push fails. The creator fee is already in hand. ──
        assertEq(IStonkSafeLaunchpadV2(PAD_V2_WETH).creatorQuoteOwed(id), 0, "creator quote should be pushed, not owed");
        assertGt(IWETH9(WETH).balanceOf(address(this)), 0, "creator received no pushed fee from the buy tax");
        (bool flushed,) = PAD_V2_WETH.call(abi.encodeCall(IStonkSafeLaunchpadV2.flushCreatorQuote, (id)));
        assertFalse(flushed, "flushCreatorQuote reverts NothingOwed when the push already landed");

        // ── The armed supply and the raise are still on the pad, and the ONLY
        //    lever that moves them is the (permissionless) timer close. ──
        assertGt(armedSupply, 0, "nothing was armed");
        assertGt(realized, 0, "nothing was raised");
        assertGe(IERC20(token).balanceOf(PAD_V2_WETH), 1, "armed supply left the pad without a close");

        IStonkSafeLaunchpadV2(PAD_V2_WETH).graduate(id);
        IStonkSafeLaunchpadV2(PAD_V2_WETH).bond(id);
        assertTrue(IStonkSafeLaunchpadV2(PAD_V2_WETH).getLaunch(id).bonded, "the close is available to anyone, always");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TASK 0.1 (c) — what the flags read, and what they cannot tell you
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice The stranded-looking flag set, recorded — and the proof that it
    ///         does NOT encode "will never graduate".
    function test_fork_closedWindowFlags_doNotDistinguishFailure() public {
        _skipIfNoFork();

        (uint256 id,) = _openArmedLaunchWithABuy();
        IStonkSafeLaunchpadV2.Launch memory l = IStonkSafeLaunchpadV2(PAD_V2_WETH).getLaunch(id);
        vm.warp(uint256(l.deadline) + 1);

        l = IStonkSafeLaunchpadV2(PAD_V2_WETH).getLaunch(id);
        IStonkSafeLaunchpadV2.LaunchModes memory m = IStonkSafeLaunchpadV2(PAD_V2_WETH).modesOf(id);

        assertTrue(l.armed, "armed");
        assertFalse(l.graduated, "not graduated");
        assertFalse(l.bonded, "not bonded");
        assertFalse(l.aborted, "not aborted - nothing here marks failure");
        assertFalse(m.openEnded, "not open-ended");
        assertLt(uint256(l.deadline), block.timestamp, "deadline is in the past");
        assertGt(l.buyCount, 0, "buys present");
        assertLt(IStonkPadProbe(PAD_V2_WETH).mcapUsd8(id), GRAD_MCAP_USD8, "cap unmet");

        // Every one of those reads is ALSO true of a launch that is one
        // permissionless call away from a locked LP. The venue exposes no
        // graduatability predicate because it needs none: this state IS
        // graduatable, so `Failed` would be a lie.
        (bool ok,) = PAD_V2_WETH.call(abi.encodeCall(IStonkSafeLaunchpadV2.graduate, (id)));
        assertTrue(ok, "the very flag set that looks failed is graduatable");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TASK 0.1 — the adapter's own answer, end to end through a real clone
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice `StonkLaunchAdapter.phase()` over a live launch whose window
    ///         closed below the cap: `Closing`, then `Live` after `finalize`.
    ///         This is the assertion the `clonePhase` fix is answerable to.
    function test_fork_adapterPhase_closedWindowIsClosingThenLive() public {
        _skipIfNoFork();

        address[] memory quotes = new address[](1);
        address[] memory pads = new address[](1);
        quotes[0] = WETH;
        pads[0] = PAD_V2_WETH;
        StonkLaunchAdapter adapter = new StonkLaunchAdapter(quotes, pads, LENS);

        StonkLaunchAdapter.VenueData memory v = StonkLaunchAdapter.VenueData({
            supply: SUPPLY,
            startMcapUsd8: START_MCAP_USD8,
            gradMcapUsd8: GRAD_MCAP_USD8,
            startTaxBps: START_TAX_BPS,
            taxDecayPerMinuteBps: DECAY_BPS_PER_MIN,
            sellsEnabled: true,
            bufferSecs: BUFFER_SECS,
            unsoldMode: 0,
            openEnded: false,
            postTaxBps: 0,
            bondVenue: 0,
            maxBuyPpm: 0
        });

        // No dev buy: this contract stands in for the owning strategy, and the
        // reserve comes out of the minted supply, not out of quote.
        ILaunchAdapter.LaunchResult memory r = adapter.launch(
            ILaunchAdapter.LaunchParams({
                name: "Sherwood Fork Probe",
                symbol: "SFP",
                quoteToken: WETH,
                quoteIn: 0,
                minTokensOut: 0,
                reserveAmount: SUPPLY / 10,
                deadline: 0,
                feeRecipient: feeSink,
                venueData: abi.encode(v)
            })
        );

        assertEq(IERC20(r.token).balanceOf(address(this)), SUPPLY / 10, "reserve did not land on the owner");
        assertEq(
            uint256(adapter.phase(r.launchRef)), uint256(ILaunchAdapter.LaunchPhase.Curve), "fresh launch is Curve"
        );

        address clone = address(uint160(uint256(r.launchRef)));
        uint256 id = StonkLaunchAdapter(clone).launchId();

        // One buy so `buyCount != 0` — the case the spec cares about.
        IStonkSafeLaunchpadV2.Launch memory l = IStonkSafeLaunchpadV2(PAD_V2_WETH).getLaunch(id);
        vm.warp(uint256(l.startTime) + BUFFER_SECS + 1);
        _fundWeth(buyer, 0.05 ether);
        vm.startPrank(buyer);
        IWETH9(WETH).approve(PAD_V2_WETH, 0.05 ether);
        IStonkSafeLaunchpadV2(PAD_V2_WETH).buy(id, 0.05 ether, 0, bytes32(0), buyer);
        vm.stopPrank();
        assertEq(
            uint256(adapter.phase(r.launchRef)), uint256(ILaunchAdapter.LaunchPhase.Curve), "still Curve mid-window"
        );

        // ── The boundary second, pinned against the pad's own `>=`. ──
        l = IStonkSafeLaunchpadV2(PAD_V2_WETH).getLaunch(id);
        vm.warp(uint256(l.deadline) - 1);
        assertEq(
            uint256(adapter.phase(r.launchRef)),
            uint256(ILaunchAdapter.LaunchPhase.Curve),
            "one second before the deadline the venue still trades"
        );

        // ── Window closes below the cap. THE ANSWER: `Closing`, not `Failed`. ──
        vm.warp(uint256(l.deadline));
        assertFalse(IStonkSafeLaunchpadV2(PAD_V2_WETH).getLaunch(id).graduated, "must not have graduated on its own");
        assertEq(
            uint256(adapter.phase(r.launchRef)),
            uint256(ILaunchAdapter.LaunchPhase.Closing),
            "a timer-closed curve is graduatable, so it is Closing - NOT Failed"
        );

        // ── And `finalize` drives it the rest of the way, permissionlessly. ──
        vm.prank(makeAddr("keeper"));
        adapter.finalize(r.launchRef);
        assertEq(
            uint256(adapter.phase(r.launchRef)), uint256(ILaunchAdapter.LaunchPhase.Live), "finalize did not reach Live"
        );
        assertTrue(IStonkSafeLaunchpadV2(PAD_V2_WETH).getLaunch(id).bonded, "the locked LP was never minted");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TASK 0.3 — bring-your-own token on a V2 pad vs a V3 pad
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice A V2 pad ACCEPTS an external token from an arbitrary contract.
    /// @dev The V2/V3 split is convention, not enforcement: the pad records
    ///      `externalToken == true` and arms the supplied token onto the curve
    ///      with no branch that could have refused it.
    function test_fork_v2Pad_acceptsBringYourOwnToken() public {
        _skipIfNoFork();

        ForkExternalToken t = new ForkExternalToken("Fork BYO", "FBYO", SUPPLY);
        (uint256 id, address token) = IStonkSafeLaunchpadV2(PAD_V2_WETH).createLaunch(_params(address(t)));

        assertEq(token, address(t), "the pad swapped the token out from under us");
        IStonkSafeLaunchpadV2.Launch memory l = IStonkSafeLaunchpadV2(PAD_V2_WETH).getLaunch(id);
        assertTrue(l.externalToken, "V2 pad did not flag the launch external");
        assertEq(l.creator, address(this), "an arbitrary contract IS an acceptable external-token creator");
        assertEq(IStonkSafeLaunchpadV2(PAD_V2_WETH).launchIdOfToken(address(t)), id, "reverse index not written");

        // And it fully works: the BYO supply arms onto the curve.
        t.approve(PAD_V2_WETH, SUPPLY);
        IStonkSafeLaunchpadV2(PAD_V2_WETH).arm(id, SUPPLY);
        assertTrue(IStonkSafeLaunchpadV2(PAD_V2_WETH).getLaunch(id).armed, "BYO launch did not arm on a V2 pad");
    }

    /// @notice The V3 pad accepts the same thing — so the difference between
    ///         the two pad families is not the token source.
    function test_fork_v3Pad_acceptsBringYourOwnToken() public {
        _skipIfNoFork();

        ForkExternalToken t = new ForkExternalToken("Fork BYO", "FBYO", SUPPLY);
        (uint256 id, address token) = IStonkSafeLaunchpadV2(PAD_V3_WETH).createLaunch(_params(address(t)));

        assertEq(token, address(t), "the pad swapped the token out from under us");
        IStonkSafeLaunchpadV2.Launch memory l = IStonkSafeLaunchpadV2(PAD_V3_WETH).getLaunch(id);
        assertTrue(l.externalToken, "V3 pad did not flag the launch external");

        t.approve(PAD_V3_WETH, SUPPLY);
        IStonkSafeLaunchpadV2(PAD_V3_WETH).arm(id, SUPPLY);
        assertTrue(IStonkSafeLaunchpadV2(PAD_V3_WETH).getLaunch(id).armed, "BYO launch did not arm on a V3 pad");
    }

    /// @notice ...and the mint path is equally available on BOTH families, so
    ///         our V2-only pad set is a CHOICE. Recorded so a future reader does
    ///         not mistake the deploy script's V2 list for a safety constraint.
    function test_fork_v3Pad_alsoAcceptsTheMintPath() public {
        _skipIfNoFork();

        (uint256 id, address token) = IStonkSafeLaunchpadV2(PAD_V3_WETH).createLaunch(_params(address(0)));
        assertTrue(token != address(0), "V3 pad refused to mint");
        assertFalse(IStonkSafeLaunchpadV2(PAD_V3_WETH).getLaunch(id).externalToken, "mint path flagged external");
        assertEq(IERC20(token).balanceOf(address(this)), SUPPLY, "V3 mint path did not deliver supply to the creator");
    }
}
