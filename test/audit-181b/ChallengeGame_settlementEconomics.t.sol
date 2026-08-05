// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ChallengeGame} from "src/ChallengeGame.sol";
import {IChallengeGame} from "src/interfaces/IChallengeGame.sol";
import {ISyndicateGovernor} from "src/interfaces/ISyndicateGovernor.sol";
import {BatchExecutorLib} from "src/BatchExecutorLib.sol";
import {ERC20Mock} from "test/mocks/ERC20Mock.sol";

/// @dev Minimal governor stub — `file()` only reads `executedAt`/`vault` off
///      `getProposal` (every filing here names no adapter, so
///      `getExecuteCalls` is never consulted), and `proposerBondEscrow`
///      defaults to `address(0)`, which `_settle` treats as "nothing to
///      forfeit" — none of these tests exercise `ProposerBondEscrow`.
contract MockGovernorSE {
    mapping(uint256 => ISyndicateGovernor.StrategyProposal) internal _proposals;

    function setExecuted(uint256 proposalId, address vault, uint256 executedAt) external {
        _proposals[proposalId].vault = vault;
        _proposals[proposalId].executedAt = executedAt;
    }

    function getProposal(uint256 proposalId) external view returns (ISyndicateGovernor.StrategyProposal memory) {
        return _proposals[proposalId];
    }

    function getExecuteCalls(uint256) external pure returns (BatchExecutorLib.Call[] memory) {
        return new BatchExecutorLib.Call[](0);
    }
}

/// @dev Minimal `IExposureLedger` stand-in implementing exactly the
///      selectors `ChallengeGame` calls. `slashBpsFor` returns empty arrays
///      deliberately — these tests are about the CHALLENGER-side settlement
///      economics (the bond/pool burn), not the accused's slash amounts, so
///      an empty accused set keeps `slashVerdict` a no-op without changing
///      anything these tests assert on.
contract MockLedgerSE {
    uint256 public challengeWindow = 14 days;

    uint256 internal _woodPriceX8;
    mapping(bytes32 => address[]) internal _approvers;
    mapping(bytes32 => mapping(address => uint256)) internal _committed;

    /// @dev Tracks `pinCoverageUntil` the same way the main suite's
    ///      `MockChallengeLedger` does, so the finding-20 test can assert the
    ///      re-arm actually reached the ledger, not merely that
    ///      `challengeableUntil` moved locally.
    uint256 public pinCoverageUntilCallCount;
    mapping(bytes32 => uint256) public pinnedUntil;

    function setWoodPriceX8(uint256 p) external {
        _woodPriceX8 = p;
    }

    function woodPriceX8() external view returns (uint256) {
        return _woodPriceX8;
    }

    function woodUsdPriceX8() external view returns (uint256) {
        return _woodPriceX8;
    }

    function setApprovers(address governor, uint256 proposalId, address[] memory guardians, uint256[] memory usd)
        external
    {
        bytes32 k = _key(governor, proposalId);
        delete _approvers[k];
        for (uint256 i = 0; i < guardians.length; i++) {
            _approvers[k].push(guardians[i]);
            _committed[k][guardians[i]] = usd[i];
        }
    }

    function approversOf(address governor, uint256 proposalId)
        external
        view
        returns (address[] memory guardians, uint256[] memory committedUsd)
    {
        bytes32 k = _key(governor, proposalId);
        guardians = _approvers[k];
        committedUsd = new uint256[](guardians.length);
        for (uint256 i = 0; i < guardians.length; i++) {
            committedUsd[i] = _committed[k][guardians[i]];
        }
    }

    /// @dev `ChallengeGame.file` reads the PLEDGE, not the booking (pashov
    ///      2026-08 finding #24). This stub does not model `settleCoverage`, so
    ///      the two never diverge here — present so the typed call resolves.
    function pledgedOf(address governor, uint256 proposalId)
        external
        view
        returns (address[] memory guardians, uint256[] memory pledgedUsd)
    {
        bytes32 k = _key(governor, proposalId);
        guardians = _approvers[k];
        pledgedUsd = new uint256[](guardians.length);
        for (uint256 i = 0; i < guardians.length; i++) {
            pledgedUsd[i] = _committed[k][guardians[i]];
        }
    }

    /// @dev Zero means "no override" at the `file()` call site — the raw
    ///      `approversOf` sum is used as-is.
    function unsharedLiabilityUsd(address, uint256) external pure returns (uint256) {
        return 0;
    }

    function freezeCoverage(address, uint256) external {}
    function unfreezeCoverage(address, uint256) external {}

    function pinCoverageUntil(address governor, uint256 proposalId, uint256 deadline) external {
        pinCoverageUntilCallCount++;
        pinnedUntil[_key(governor, proposalId)] = deadline;
    }

    function slashBpsFor(address, uint256) external pure returns (address[] memory, uint256[] memory) {
        return (new address[](0), new uint256[](0));
    }

    function proposerBondBps() external pure returns (uint256) {
        return 100;
    }

    function _key(address governor, uint256 proposalId) internal pure returns (bytes32) {
        return keccak256(abi.encode(governor, proposalId));
    }
}

contract MockTierRegistrySE {
    function demoteByChallenge(address, bytes4) external {}
}

/// @dev Minimal `IStakedWood` stand-in. `slashVerdict` is a no-op that
///      returns 0 — these tests exercise an empty accused set (see
///      `MockLedgerSE.slashBpsFor`), so nothing here needs to actually slash
///      anything to make the challenger-side economics under test land.
contract MockStakedWoodSE {
    address public authorizedSlasher;

    function setAuthorizedSlasher(address a) external {
        authorizedSlasher = a;
    }

    function slashVerdict(bytes32, uint256, address[] calldata, uint256[] calldata) external pure returns (uint256) {
        return 0;
    }

    function verdictSlashed(bytes32, address) external pure returns (bool) {
        return false;
    }
}

/// @dev Minimal court stand-in — mirrors the main suite's `MockRecordingCourt`
///      defaults (5-day `voteWindow`, 1-day `FINALIZE_BUFFER`), which is what
///      `ChallengeGame._requireWindowFits`/`setCourt` read live. `refer` is a
///      harmless recorder: these tests deliberately never call `rule` after
///      the pool completes, so the dispute is left to expire UN-ADJUDICATED —
///      exactly the finding-20 scenario (a court IS wired, but nothing ever
///      rules).
contract MockCourtSE {
    uint256 public voteWindow = 5 days;
    uint256 public constant FINALIZE_BUFFER = 1 days;
    uint256 public lastReferred;

    function refer(uint256 challengeId) external returns (uint256) {
        lastReferred = challengeId;
        return 1;
    }
}

/// @title ChallengeGame_settlementEconomics
/// @notice Regression coverage for audit issue #181's remaining
///         MEDIUM/LOW settlement-path findings (wave 2), against
///         `ChallengeGame`/`IChallengeGame` as fixed on top of
///         `fix/audit-181-critical-high`.
///
/// @dev    Finding 18b (self-dealing round trip): a challenger that funds its
///         OWN counter-bond pool and is then ruled `Guilty` used to recover
///         `bond + pool` untouched — its whole round-trip capital, net cost
///         zero, despite `forfeitBurnBps`'s own natspec pricing exactly this
///         trade on the FAIL path. `test_selfFundedGuiltyRuling_burnsASlice_notTheWholeRoundTrip`
///         proves the escalated branch now burns too.
///
/// @dev    Finding 19 (free first round): the very first `Inconclusive`
///         unwind against a fresh proposal used to pin a 0 bps burn rate,
///         making a self-funded stall-to-quorum-miss a genuinely free way to
///         hold a cohort's coverage frozen for up to `disputeTimeout` +
///         `challengeWindow`. `test_firstEverInconclusiveRound_pinsAPositiveBurnRate`
///         proves round 1 is no longer free.
///
/// @dev    Finding 20 (un-adjudicated timeout never re-arms): a Disputed
///         challenge with a court WIRED AT FILING that simply times out
///         without a ruling ever landing used to leave `challengeableUntil`
///         untouched, unlike the structurally identical non-verdict
///         `_refundAll` handles — silently permitting the ordinary
///         `executedAt + challengeWindow` deadline to lapse with no
///         re-challenge gate left standing, despite nothing having been
///         decided on the merits. `test_unadjudicatedDisputeTimeout_reArmsReChallengeWindow`
///         proves the re-arm now happens on this entry, and
///         `test_genuineNotGuiltyRuling_doesNotReArm` proves a REAL acquittal
///         still does not.
contract ChallengeGame_settlementEconomicsTest is Test {
    ChallengeGame internal game;
    MockGovernorSE internal governor;
    MockLedgerSE internal ledger;
    MockTierRegistrySE internal tierRegistry;
    MockStakedWoodSE internal swood;
    MockCourtSE internal court;
    ERC20Mock internal wood;

    address internal owner = address(this);
    address internal approver1 = address(0xA9911);
    address internal vault = address(0x1A017);

    uint256 internal constant PROPOSAL_ID = 1;
    uint256 internal constant COVERAGE_USD = 100_000e18;
    uint256 internal constant PRICE_X8 = 1e8; // $1.00 / WOOD

    function setUp() public {
        governor = new MockGovernorSE();
        ledger = new MockLedgerSE();
        tierRegistry = new MockTierRegistrySE();
        swood = new MockStakedWoodSE();
        court = new MockCourtSE();
        wood = new ERC20Mock("WOOD", "WOOD", 18);

        game = new ChallengeGame(owner, address(wood), address(ledger), address(tierRegistry));

        governor.setExecuted(PROPOSAL_ID, vault, block.timestamp);

        address[] memory guardians = new address[](1);
        guardians[0] = approver1;
        uint256[] memory usd = new uint256[](1);
        usd[0] = COVERAGE_USD;
        ledger.setApprovers(address(governor), PROPOSAL_ID, guardians, usd);
        ledger.setWoodPriceX8(PRICE_X8);

        swood.setAuthorizedSlasher(address(game));
        game.setStakedWood(address(swood));
    }

    function _fund(address who, uint256 amount) internal {
        wood.mint(who, amount);
        vm.prank(who);
        wood.approve(address(game), type(uint256).max);
    }

    /// @dev Expected undiscounted bond for `COVERAGE_USD` at `PRICE_X8`:
    ///      `coverageUsd * challengerBondBps / 10_000 * 1e8 / priceX8`, with
    ///      `challengerBondBps` read LIVE off the contract (audit #181
    ///      finding 18a moved the default from 500 to 150) rather than
    ///      hardcoded, so a future parameter change does not silently break
    ///      every fixture built on top of this.
    function _expectedBondWood() internal view returns (uint256) {
        return (((COVERAGE_USD * game.challengerBondBps()) / 10_000) * 1e8) / PRICE_X8;
    }

    function _file(address challenger) internal returns (uint256 id) {
        _fund(challenger, _expectedBondWood());
        vm.prank(challenger);
        id = game.file(
            address(governor), PROPOSAL_ID, IChallengeGame.Predicate.OutOfAdapterOutflow, address(0), bytes4(0), "ev"
        );
    }

    // ── Finding 18b ──

    /// @notice A challenger that files, then funds its OWN counter-bond pool
    ///         in full, and is then ruled `Guilty`, must NOT round-trip its
    ///         whole stake — the escalated branch must burn the same
    ///         `settleBurnBpsAtFiling` slice of the forfeited pool that the
    ///         silence branch already takes off the bond.
    /// @dev    FAILS AGAINST THE PRE-FIX CODE: `_settle`'s `escalated` branch
    ///         used to be `wood.safeTransfer(c.challenger, bond + pool)` with
    ///         no burn at all, so a challenger funding its own pool recovered
    ///         exactly `2 * bondWood` against a `2 * bondWood` outlay (bond +
    ///         its own pool contribution) — a net WOOD change of exactly ZERO
    ///         for a conviction it triggered entirely with its own capital.
    ///         The `assertLt(received, 2 * bondWood, ...)` below is the
    ///         load-bearing assertion: it is false (`received == 2 *
    ///         bondWood`) against the old code and true against the fix.
    function test_selfFundedGuiltyRuling_burnsASlice_notTheWholeRoundTrip() public {
        address challenger = address(0xC4A11E7);
        uint256 bondWood = _expectedBondWood();

        // The court must be wired BEFORE filing: `Challenge.courtAtFiling`
        // pins whatever `court` reads at `file()` time, and `rule` refuses to
        // act on a challenge that pinned `address(0)` regardless of what
        // `court` is wired to later (`ChallengeGame.rule`, second-audit
        // finding B) — this test needs the later `game.rule(id, Guilty)`
        // call below to actually land, so the court has to be live before
        // `_file` pins it, not after.
        vm.prank(owner);
        game.setCourt(address(court));

        // The challenger funds BOTH legs of the trade: the bond that opens
        // the challenge (inside `_file`, mint-then-spend), and (below) the
        // entire counter-bond pool that escalates it — the exact round trip
        // `forfeitBurnBps`'s natspec prices on the FAIL path, and issue #181
        // finding 18b says the ESCALATED path must price too.
        uint256 id = _file(challenger);
        assertEq(wood.balanceOf(challenger), 0, "sanity: leg 1 (the bond) fully outlaid by filing");

        // Fund the pool from the SAME challenger address — `dispute` is
        // permissionless, so nothing stops the challenger from being its own
        // pool's sole funder. Minted fresh, then spent in full by `dispute`
        // below, so the challenger's balance is exactly 0 again right before
        // the ruling — which is what makes its POST-ruling balance directly
        // readable as "what the round trip returned", with no before/after
        // subtraction needed.
        _fund(challenger, bondWood);
        vm.prank(challenger);
        game.dispute(id, type(uint256).max);
        assertEq(uint8(game.challengeOf(id).status), uint8(IChallengeGame.Status.Disputed), "pool must be complete");
        assertEq(wood.balanceOf(challenger), 0, "sanity: leg 2 (the pool) fully outlaid too, before the ruling");

        uint256 settleBurnBpsAtFiling = game.challengeOf(id).settleBurnBpsAtFiling;
        uint256 expectedBurn = (bondWood * settleBurnBpsAtFiling) / 10_000;
        assertGt(expectedBurn, 0, "fixture must exercise a non-zero burn rate");
        // BURN MODEL (pashov 2026-08 finding #10). The pool is burned on
        // conviction rather than forfeited to the challenger, so a self-funded
        // round trip recovers only its own BOND net of the slice -- it does not
        // get the pool back at all. That makes issue #181 finding 18b STRICTLY
        // STRONGER than when this test was written: the round trip used to cost
        // the slice alone, and now costs the whole pool plus the slice.
        uint256 expectedReceipt = bondWood - expectedBurn;

        vm.prank(address(court));
        game.rule(id, IChallengeGame.Verdict.Guilty);

        assertEq(uint8(game.challengeOf(id).status), uint8(IChallengeGame.Status.Settled));

        // Challenger's balance was exactly 0 immediately before this call, so
        // its balance now IS what the round trip returned.
        uint256 received = wood.balanceOf(challenger);
        assertEq(received, expectedReceipt, "the round trip must cost exactly the settle-burn slice, not zero");
        assertLt(received, 2 * bondWood, "THE ROUND TRIP MUST NOT BE FREE (issue #181 finding 18b)");
        assertLt(received, bondWood, "and under the burn model it does not even recover its own bond");
        assertEq(wood.balanceOf(game.BURN_ADDRESS()), expectedBurn, "the slice must actually be destroyed");
    }

    // ── Finding 19 ──

    /// @notice The FIRST-EVER `Inconclusive` unwind against a fresh proposal
    ///         must pin a positive `inconclusiveBurnBpsAtFiling`, not a free
    ///         0 bps rate.
    /// @dev    FAILS AGAINST THE PRE-FIX CODE:
    ///         `_inconclusiveBurnBpsForRound(0)` used to return `0`
    ///         unconditionally, so `assertEq(pinnedRate, 250, ...)` fails
    ///         (pre-fix: 0) and `assertLt(challengerReceived, bondWood, ...)`
    ///         also fails (pre-fix: the challenger recovers the whole bond).
    function test_firstEverInconclusiveRound_pinsAPositiveBurnRate() public {
        address challenger = address(0xC4A11E7);
        address funder = address(0xF00DE12);

        uint256 bondWood = _expectedBondWood();

        // The court must be wired BEFORE filing for the same reason as
        // `test_selfFundedGuiltyRuling_burnsASlice_notTheWholeRoundTrip`
        // above: `courtAtFiling` pins whatever `court` reads at `file()`
        // time, and the later `game.rule(id, Inconclusive)` call below is
        // refused (`NotCourt`) on a challenge that pinned `address(0)`,
        // regardless of `court` being wired by the time `rule` is called.
        vm.prank(owner);
        game.setCourt(address(court));

        uint256 id = _file(challenger);

        IChallengeGame.Challenge memory c = game.challengeOf(id);
        uint256 pinnedRate = c.inconclusiveBurnBpsAtFiling;
        assertEq(pinnedRate, 250, "the first-ever attempt must pin the round-1 fixed step, not 0");

        _fund(funder, bondWood);
        vm.prank(funder);
        game.dispute(id, type(uint256).max);
        assertEq(uint8(game.challengeOf(id).status), uint8(IChallengeGame.Status.Disputed));

        uint256 challengerBefore = wood.balanceOf(challenger);
        vm.prank(address(court));
        game.rule(id, IChallengeGame.Verdict.Inconclusive);

        assertEq(uint8(game.challengeOf(id).status), uint8(IChallengeGame.Status.Inconclusive));

        uint256 expectedBurn = (bondWood * pinnedRate) / 10_000;
        uint256 received = wood.balanceOf(challenger) - challengerBefore;
        assertEq(received, bondWood - expectedBurn, "challenger must receive bond net of the round-1 burn");
        assertLt(received, bondWood, "A FIRST-ROUND STALL MUST NOT BE FREE (issue #181 finding 19)");
        assertGt(wood.balanceOf(game.BURN_ADDRESS()), 0, "the round-1 burn must actually be destroyed");
    }

    // ── Finding 20 ──

    /// @notice A Disputed challenge whose game HAD a court wired at filing,
    ///         but whose dispute times out with no ruling ever landing, must
    ///         re-arm the proposal's re-challenge window — the same
    ///         non-verdict treatment `_refundAll` already gives an
    ///         Inconclusive unwind.
    /// @dev    FAILS AGAINST THE PRE-FIX CODE: `_fail` never touched
    ///         `challengeableUntil` or called `pinCoverageUntil` on either of
    ///         its entries, so `challengeableUntil(key)` stays exactly `0`
    ///         after this timeout — `assertGt(rearmed, block.timestamp, ...)`
    ///         is false pre-fix (0 is never greater than a nonzero
    ///         `block.timestamp` this far into the test) and true post-fix.
    function test_unadjudicatedDisputeTimeout_reArmsReChallengeWindow() public {
        address challenger = address(0xC4A11E7);
        address funder = address(0xF00DE12);
        bytes32 key = keccak256(abi.encode(address(governor), PROPOSAL_ID));

        vm.prank(owner);
        game.setCourt(address(court));

        uint256 id = _file(challenger);
        IChallengeGame.Challenge memory c = game.challengeOf(id);
        assertEq(c.courtAtFiling, address(court), "sanity: a court WAS pinned at filing");
        assertEq(game.challengeableUntil(key), 0, "sanity: no re-arm has happened yet");

        uint256 bondWood = _expectedBondWood();
        _fund(funder, bondWood);
        vm.prank(funder);
        game.dispute(id, type(uint256).max);
        assertEq(uint8(game.challengeOf(id).status), uint8(IChallengeGame.Status.Disputed));
        // The best-effort auto-referral landed, but nothing ever calls
        // `game.rule(...)` from here on — the dispute is left to expire
        // un-adjudicated, exactly the scenario finding 20 is about (a court
        // wired away, a dropped referral nobody retried, or the court's own
        // vote never finalized before this game's own clock ran out).
        assertEq(court.lastReferred(), id, "sanity: the auto-referral did fire");

        c = game.challengeOf(id);
        vm.warp(c.filedAt + c.disputeTimeoutAtFiling + 1);

        uint256 pinCallsBefore = ledger.pinCoverageUntilCallCount();
        game.resolve(id);

        assertEq(
            uint8(game.challengeOf(id).status),
            uint8(IChallengeGame.Status.Failed),
            "the payout path is unchanged: still a forfeit to the defenders"
        );

        uint256 rearmed = game.challengeableUntil(key);
        assertGt(rearmed, block.timestamp, "THE RE-CHALLENGE WINDOW MUST RE-ARM (issue #181 finding 20)");
        assertEq(rearmed, block.timestamp + game.challengeWindow(), "re-armed to the ordinary window from now");
        assertEq(ledger.pinCoverageUntilCallCount(), pinCallsBefore + 1, "the ledger pin must accompany the re-arm");
        assertEq(ledger.pinnedUntil(key), rearmed, "pinned through the SAME instant the re-armed deadline reads");
    }

    /// @notice A GENUINE `NotGuilty` ruling — an adjudicator that actually
    ///         looked at the merits and cleared the accused — must NOT
    ///         re-arm the re-challenge window. Only the un-adjudicated
    ///         TIMEOUT entry does (see the test above); this is the negative
    ///         case that proves the `unadjudicatedTimeout` flag actually
    ///         distinguishes the two `_fail` entries rather than re-arming
    ///         unconditionally.
    function test_genuineNotGuiltyRuling_doesNotReArm() public {
        address challenger = address(0xC4A11E7);
        address funder = address(0xF00DE12);
        bytes32 key = keccak256(abi.encode(address(governor), PROPOSAL_ID));

        vm.prank(owner);
        game.setCourt(address(court));

        uint256 id = _file(challenger);
        uint256 bondWood = _expectedBondWood();
        _fund(funder, bondWood);
        vm.prank(funder);
        game.dispute(id, type(uint256).max);
        assertEq(uint8(game.challengeOf(id).status), uint8(IChallengeGame.Status.Disputed));

        uint256 pinCallsBefore = ledger.pinCoverageUntilCallCount();
        vm.prank(address(court));
        game.rule(id, IChallengeGame.Verdict.NotGuilty);

        assertEq(uint8(game.challengeOf(id).status), uint8(IChallengeGame.Status.Failed));
        assertEq(game.challengeableUntil(key), 0, "a real acquittal must not re-arm the re-challenge window");
        assertEq(ledger.pinCoverageUntilCallCount(), pinCallsBefore, "and must not touch the ledger pin either");
    }
}
