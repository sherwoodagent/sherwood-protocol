// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {CoverageEpochs} from "src/CoverageEpochs.sol";
import {ICoverageEpochs} from "src/interfaces/ICoverageEpochs.sol";
import {ISyndicateGovernor} from "src/interfaces/ISyndicateGovernor.sol";
import {ExposureLedger} from "src/ExposureLedger.sol";
import {IExposureLedger} from "src/interfaces/IExposureLedger.sol";
import {ChallengeGame} from "src/ChallengeGame.sol";
import {IChallengeGame} from "src/interfaces/IChallengeGame.sol";

/// @dev Minimal sWOOD stub: the ledger's constructor reads `coolDownPeriod`
///      only, and `maxDelegatedSlashBps` on the exposure paths Task 4 uses.
contract MockCoverageSwood {
    uint256 public coolDownPeriod = 45 days;
    uint256 public maxDelegatedSlashBps = 2_000;

    mapping(address guardian => uint256) public guardianStake;
    mapping(address guardian => uint256) public delegatedInbound;

    function setStake(address g, uint256 own, uint256 inbound) external {
        guardianStake[g] = own;
        delegatedInbound[g] = inbound;
    }
}

/// @dev Chainlink feed stub (same shape as `test/ExposureLedger.t.sol`'s). The
///      ledger prices a renewal's coverage through it.
contract MockCoverageFeed {
    int256 public answer;
    uint8 public immutable decimals;
    uint256 public updatedAt;

    constructor(int256 answer_, uint8 decimals_) {
        answer = answer_;
        decimals = decimals_;
        updatedAt = block.timestamp;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

/// @dev Governor stub. `openCover` reads exactly three fields off
///      `getProposal`: `state`, `strategy` and `maxDrawdownBps`. Task 4 adds the
///      two reads `ExposureLedger.recordApproval` makes when a renewal books
///      exposure: `getProposalView().vault` and `getRequiredCoverage`.
contract MockCoverageGovernor {
    mapping(uint256 proposalId => ISyndicateGovernor.StrategyProposal) internal _proposals;

    uint256 public requiredCoverage;

    struct ProposalViewLite {
        uint256 voteEnd;
        uint256 reviewEnd;
        address vault;
    }

    function setRequiredCoverage(uint256 coverage) external {
        requiredCoverage = coverage;
    }

    function getRequiredCoverage(uint256) external view returns (uint256) {
        return requiredCoverage;
    }

    function getProposalView(uint256 proposalId) external view returns (ProposalViewLite memory v) {
        v.vault = _proposals[proposalId].vault;
    }

    function setProposal(
        uint256 proposalId,
        address vault,
        address strategy,
        uint16 maxDrawdownBps,
        ISyndicateGovernor.ProposalState state
    ) external {
        ISyndicateGovernor.StrategyProposal storage p = _proposals[proposalId];
        p.id = proposalId;
        p.vault = vault;
        p.strategy = strategy;
        p.maxDrawdownBps = maxDrawdownBps;
        p.state = state;
        p.executedAt = block.timestamp;
    }

    function setState(uint256 proposalId, ISyndicateGovernor.ProposalState state) external {
        _proposals[proposalId].state = state;
    }

    function setStrategy(uint256 proposalId, address strategy) external {
        _proposals[proposalId].strategy = strategy;
    }

    function getProposal(uint256 proposalId) external view returns (ISyndicateGovernor.StrategyProposal memory) {
        return _proposals[proposalId];
    }
}

/// @dev Price-router stub. Mirrors the real router's G2 Option A contract: when
///      the position is not instantly priceable the value returned is ZERO, not
///      a stale number. That zero is exactly the trap `CoverageEpochs` must not
///      record — see `test_openCover_revertsWhenTheRouterCannotPrice`.
contract MockCoverageRouter {
    mapping(address strategy => uint256) internal _value;
    mapping(address strategy => bool) internal _ok;

    function setValue(address strategy, uint256 value, bool instantOK) external {
        _value[strategy] = value;
        _ok[strategy] = instantOK;
    }

    function valueStrategy(address strategy) external view returns (uint256, bool) {
        if (!_ok[strategy]) return (0, false);
        return (_value[strategy], true);
    }
}

/// @dev Vault stub whose ONLY job is to report a wildly wrong `totalAssets()`.
///      `CoverageEpochs` must never read it (D1): `totalAssets()` is
///      `idle float + liveNav`, and `liveNav` silently collapses to zero during
///      a router outage. If the baseline ever tracked this number, a single
///      oracle hiccup would fabricate a ~100% drawdown and slash honest
///      guardians.
contract MockCoverageVault {
    uint256 public totalAssets;
    /// @dev Read by `ExposureLedger.recordApproval` to price a renewal's
    ///      coverage. Unrelated to `totalAssets`, which stays the trap.
    address public asset;

    function setTotalAssets(uint256 v) external {
        totalAssets = v;
    }

    function setAsset(address a) external {
        asset = a;
    }
}

/// @title CoverageEpochsTest
/// @notice Task 1 — cover open and baseline NAV (spec 2026-07-22 §3.4a).
contract CoverageEpochsTest is Test {
    uint256 internal constant EPOCH_LENGTH = 28 days;
    uint256 internal constant BASELINE = 1_000e18;

    address internal owner = makeAddr("owner");
    address internal strategy = makeAddr("strategy");
    address internal guardianA = makeAddr("guardianA");
    address internal guardianB = makeAddr("guardianB");
    /// @dev Task 5's renewer: it never approved at open, so it exists only to
    ///      show a later epoch's coverer set is disjoint from epoch 0's.
    address internal guardianC = makeAddr("guardianC");
    address internal stranger = makeAddr("stranger");
    /// @dev Stands in for `GuardianRegistry`. `ExposureLedger.recordApproval` is
    ///      `onlyBooker` (registry OR renewal agent) and `releaseApproval` is
    ///      `onlyRegistry` — deliberately NOT widened to the renewal agent — so
    ///      the original-approver side of Task 5 has to be driven from here.
    address internal registry = makeAddr("registry");
    address internal coverageAsset;

    CoverageEpochs internal epochs;
    ExposureLedger internal ledger;
    /// @dev The oracle for `_accusedOracle` — a real `ChallengeGame` over this
    ///      fixture's ledger, so the epoch-0 equality test compares
    ///      `coverersOf` against the code that actually slashes rather than
    ///      against a copy of it kept in this file.
    ChallengeGame internal challengeGame;
    MockCoverageGovernor internal governor;
    MockCoverageRouter internal router;
    MockCoverageVault internal vault;
    MockCoverageSwood internal swood;

    uint256 internal pid = 1;

    function setUp() public {
        // Start somewhere realistic: `epochGenesis` is pinned to deploy time and
        // a genesis of 1 makes boundary arithmetic hard to read.
        vm.warp(1_800_000_000);

        swood = new MockCoverageSwood();
        ledger = new ExposureLedger(owner, address(swood), EPOCH_LENGTH);
        router = new MockCoverageRouter();
        vault = new MockCoverageVault();
        governor = new MockCoverageGovernor();

        epochs = new CoverageEpochs(owner, address(router), address(ledger));
        // Not a fixture under test: it is the ORACLE for `_accusedOracle`, and
        // it must read the same `ledger` `CoverageEpochs` does or the epoch-0
        // equality assertion compares two unrelated answers. WOOD and the tier
        // registry are placeholders — the epoch-0 accused derivation is a pure
        // ledger read and nothing is ever filed against this instance.
        challengeGame = new ChallengeGame(owner, address(swood), address(ledger), address(this));

        governor.setProposal(pid, address(vault), strategy, 2_000, ISyndicateGovernor.ProposalState.Executed);
    }

    // ── Task 1 tests ──

    /// @dev THE RULE OF THIS PLAN. The vault reports a nonsense `totalAssets()`
    ///      and the baseline must still be exactly what `valueStrategy` said.
    function test_openCover_snapshotsBaselineFromTheRouterNotTotalAssets() public {
        router.setValue(strategy, BASELINE, true);
        vault.setTotalAssets(999_999e18); // must be ignored

        epochs.openCover(address(governor), pid);

        assertEq(epochs.baselineNavOf(address(governor), pid), BASELINE, "baseline must come from valueStrategy");
        assertTrue(
            epochs.baselineNavOf(address(governor), pid) != vault.totalAssets(),
            "baseline must not track the vault's totalAssets"
        );
    }

    /// @dev D1 fail-closed. `instantOK == false` means the router refused to
    ///      price; opening anyway would pin a baseline of zero (or of a value
    ///      nobody vouched for) and measure every later drawdown against it.
    function test_openCover_revertsWhenTheRouterCannotPrice() public {
        router.setValue(strategy, 0, false); // instantOK == false
        vm.expectRevert(ICoverageEpochs.NavUnavailable.selector);
        epochs.openCover(address(governor), pid);
    }

    function test_openCover_revertsBeforeExecution() public {
        router.setValue(strategy, BASELINE, true);
        governor.setState(pid, ISyndicateGovernor.ProposalState.Approved);
        vm.expectRevert(ICoverageEpochs.NotExecuted.selector);
        epochs.openCover(address(governor), pid);
    }

    function test_openCover_isIdempotentlyRefused() public {
        router.setValue(strategy, BASELINE, true);
        epochs.openCover(address(governor), pid);
        vm.expectRevert(ICoverageEpochs.AlreadyOpened.selector);
        epochs.openCover(address(governor), pid);
    }

    /// @dev D3. The schedule is copied onto the cover at open so a future ledger
    ///      re-point cannot retroactively re-slice a live strategy's epochs.
    function test_openCover_copiesTheLedgerEpochSchedule() public {
        router.setValue(strategy, BASELINE, true);
        epochs.openCover(address(governor), pid);

        assertEq(epochs.epochLengthOf(address(governor), pid), ledger.epochLength());
        assertEq(epochs.epochGenesisOf(address(governor), pid), ledger.epochGenesis());
    }

    /// @dev A queue-only proposal has no strategy for the router to value, so
    ///      there is nothing to cover and nothing to checkpoint.
    function test_openCover_revertsWithoutAStrategy() public {
        governor.setStrategy(pid, address(0));
        vm.expectRevert(ICoverageEpochs.NoStrategy.selector);
        epochs.openCover(address(governor), pid);
    }

    /// @dev D2. `openCover` is permissionless and may land well after
    ///      execution; the record must say when the number was actually read.
    function test_openCover_recordsTheObservationTimeNotExecutedAt() public {
        router.setValue(strategy, BASELINE, true);
        vm.warp(vm.getBlockTimestamp() + 3 days);
        uint256 observedAt = vm.getBlockTimestamp();

        epochs.openCover(address(governor), pid);

        ICoverageEpochs.Cover memory c = epochs.coverOf(address(governor), pid);
        assertEq(c.openedAt, observedAt, "openedAt is when the NAV was observed");
        assertEq(c.maxDrawdownBps, 2_000, "envelope snapshotted from the proposal");
        assertEq(c.strategy, strategy);
        assertTrue(c.opened);
        assertFalse(c.breached);
        assertFalse(c.windDown);
    }

    // ── Task 2 helpers ──

    function _open() internal {
        router.setValue(strategy, BASELINE, true);
        epochs.openCover(address(governor), pid);
    }

    /// @dev Absolute boundary of epoch `n` on the ledger's schedule, which the
    ///      cover copied at open (D3). Always forward of `setUp`'s warp, since
    ///      `epochGenesis` IS `setUp`'s timestamp — `vm.warp` backwards is a
    ///      silent no-op and would make these tests pass for the wrong reason.
    function _warpToEpochBoundary(uint256 n) internal {
        vm.warp(ledger.epochGenesis() + n * EPOCH_LENGTH);
    }

    function _key() internal view returns (bytes32) {
        return epochs.coverKey(address(governor), pid);
    }

    // ── Task 2 tests ──

    function test_checkpoint_revertsBeforeTheBoundary() public {
        _open();
        vm.expectRevert(ICoverageEpochs.BoundaryNotReached.selector);
        epochs.checkpoint(address(governor), pid);
    }

    function test_checkpoint_recordsNavAtTheBoundary() public {
        _open();
        _warpToEpochBoundary(1);
        router.setValue(strategy, 900e18, true);

        vm.expectEmit(true, true, true, true);
        emit ICoverageEpochs.Checkpointed(_key(), 0, 900e18, 1_000);
        epochs.checkpoint(address(governor), pid);

        assertEq(epochs.navAt(address(governor), pid, 0), 900e18);
        assertEq(epochs.cumulativeLossBps(address(governor), pid), 1_000, "10% from baseline");
    }

    function test_checkpoint_cannotRunTwiceForOneEpoch() public {
        _open();
        _warpToEpochBoundary(1);
        epochs.checkpoint(address(governor), pid);
        vm.expectRevert(ICoverageEpochs.AlreadyCheckpointed.selector);
        epochs.checkpoint(address(governor), pid);
    }

    /// @dev D1 again, at the boundary this time. A checkpoint taken while the
    ///      router is down would record the outage's zero as a ~100% loss and
    ///      slash the epoch's coverers over an oracle hiccup.
    function test_checkpoint_revertsWhenTheRouterCannotPrice() public {
        _open();
        _warpToEpochBoundary(1);
        router.setValue(strategy, 0, false);
        vm.expectRevert(ICoverageEpochs.NavUnavailable.selector);
        epochs.checkpoint(address(governor), pid);
    }

    /// @dev D4, THE RULE OF THIS TASK. Checkpoints are permissionless and
    ///      unpaid, so "nobody called it at the boundary" is the expected case,
    ///      not an edge case. Miss epoch 0 entirely, checkpoint during epoch 2,
    ///      and the loss must still read against the ORIGINAL baseline —
    ///      epoch-over-epoch would re-baseline against the depressed value and
    ///      launder a 30% drawdown into a 0% one via a call nobody made.
    function test_checkpoint_missedBoundaryStillMeasuresFromBaseline() public {
        _open(); // baseline 1_000e18
        _warpToEpochBoundary(2);
        router.setValue(strategy, 700e18, true);
        epochs.checkpoint(address(governor), pid);
        assertEq(epochs.cumulativeLossBps(address(governor), pid), 3_000);
    }

    /// @dev D4 with teeth. The plan's missed-boundary test takes ONE
    ///      checkpoint, so an epoch-over-epoch implementation that falls back
    ///      to the baseline when there is no prior checkpoint passes it too.
    ///      Two checkpoints separate the two rules: measured from baseline the
    ///      loss is 3_000 bps (a breach of the 2_000 envelope); measured
    ///      epoch-over-epoch it is (850-700)/850 = 1_764 bps and the strategy
    ///      walks, having lost 30% of the LPs' money in visible steps.
    function test_cumulativeLossBps_isNotEpochOverEpoch() public {
        _open(); // baseline 1_000e18
        _warpToEpochBoundary(1);
        router.setValue(strategy, 850e18, true);
        epochs.checkpoint(address(governor), pid);
        assertEq(epochs.cumulativeLossBps(address(governor), pid), 1_500);

        _warpToEpochBoundary(2);
        router.setValue(strategy, 700e18, true);
        epochs.checkpoint(address(governor), pid);
        assertEq(
            epochs.cumulativeLossBps(address(governor), pid), 3_000, "from baseline, never from the previous checkpoint"
        );
    }

    /// @dev Off-by-one is the likeliest bug here, so pin both sides of the
    ///      exact second. The boundary of epoch 0 is the START of epoch 1.
    function test_checkpoint_succeedsExactlyAtTheBoundarySecond() public {
        _open();
        vm.warp(ledger.epochGenesis() + EPOCH_LENGTH); // the boundary itself
        router.setValue(strategy, 950e18, true);
        epochs.checkpoint(address(governor), pid);
        assertEq(epochs.navAt(address(governor), pid, 0), 950e18);
    }

    function test_checkpoint_revertsOneSecondBeforeTheBoundary() public {
        _open();
        vm.warp(ledger.epochGenesis() + EPOCH_LENGTH - 1);
        vm.expectRevert(ICoverageEpochs.BoundaryNotReached.selector);
        epochs.checkpoint(address(governor), pid);
    }

    /// @dev D4's labelling half. The NAV recorded at the epoch-2 boundary
    ///      belongs to epoch 1's watch — the epoch whose boundary just closed.
    ///      Filing it under epoch 0 (the last cursor position) would fabricate
    ///      a reading for a period nobody observed and, once Task 3 sets
    ///      `breachEpoch`, would accuse the wrong epoch's coverers. A missed
    ///      epoch stays MISSED.
    function test_checkpoint_recordsUnderTheEpochWhoseBoundaryJustClosed() public {
        _open();
        _warpToEpochBoundary(2);
        router.setValue(strategy, 700e18, true);
        epochs.checkpoint(address(governor), pid);

        assertEq(epochs.navAt(address(governor), pid, 0), 0, "the skipped epoch stays unrecorded");
        assertEq(epochs.navAt(address(governor), pid, 1), 700e18, "recorded on the watch that just ended");
        assertEq(epochs.coverOf(address(governor), pid).lastCheckpointedEpoch, 1);
    }

    function test_checkpoint_revertsWithoutAnOpenCover() public {
        _warpToEpochBoundary(1);
        vm.expectRevert(ICoverageEpochs.NotOpened.selector);
        epochs.checkpoint(address(governor), pid);
    }

    /// @dev The view's own fail-closed. `_lastNav` defaults to zero, and
    ///      reading that default as a NAV would report a fabricated 100%
    ///      drawdown on a cover that has simply never been checkpointed.
    function test_cumulativeLossBps_isZeroBeforeAnyCheckpoint() public {
        _open();
        assertEq(epochs.cumulativeLossBps(address(governor), pid), 0);
    }

    function test_checkpoint_navAboveBaselineIsNoLoss() public {
        _open();
        _warpToEpochBoundary(1);
        router.setValue(strategy, 1_200e18, true);
        epochs.checkpoint(address(governor), pid);
        assertEq(epochs.cumulativeLossBps(address(governor), pid), 0, "a gain is not a negative loss");
        assertEq(epochs.navAt(address(governor), pid, 0), 1_200e18);
    }

    /// @dev Task 2 records; it does not judge. A loss inside the declared
    ///      envelope must leave the breach flags alone — Task 3 owns them.
    function test_checkpoint_insideTheEnvelopeTouchesNoBreachFlag() public {
        _open(); // envelope 2_000 bps
        _warpToEpochBoundary(1);
        router.setValue(strategy, 950e18, true); // 500 bps, well inside
        epochs.checkpoint(address(governor), pid);

        ICoverageEpochs.Cover memory c = epochs.coverOf(address(governor), pid);
        assertFalse(c.breached);
        assertEq(c.breachEpoch, 0);
    }

    // ── Task 3 helpers ──

    /// @dev Open a cover whose proposal declared `envelopeBps` as its drawdown
    ///      bound. Separate from `_open()` so the envelope is visible at the
    ///      call site of every breach test.
    function _openWithEnvelope(uint16 envelopeBps) internal {
        governor.setProposal(pid, address(vault), strategy, envelopeBps, ISyndicateGovernor.ProposalState.Executed);
        router.setValue(strategy, BASELINE, true);
        epochs.openCover(address(governor), pid);
    }

    // ── Task 3 tests: drawdown evaluation (D5) ──

    function test_breach_setsTheFlagAndEmits() public {
        _openWithEnvelope(2_000); // 20%
        _warpToEpochBoundary(1);
        router.setValue(strategy, 700e18, true); // 30% loss
        vm.expectEmit(true, true, true, true);
        emit ICoverageEpochs.DrawdownBreached(_key(), 0, 3_000, 2_000);
        epochs.checkpoint(address(governor), pid);
        assertTrue(epochs.breached(address(governor), pid));
    }

    function test_lossInsideTheEnvelopeDoesNotBreach() public {
        _openWithEnvelope(2_000);
        _warpToEpochBoundary(1);
        router.setValue(strategy, 850e18, true); // 15% < 20%
        epochs.checkpoint(address(governor), pid);
        assertFalse(epochs.breached(address(governor), pid));
    }

    /// @dev The envelope is an inclusive bound: a mandate that declared 20% is
    ///      allowed to lose exactly 20%. Only a STRICTLY greater loss breaches.
    function test_lossExactlyAtTheEnvelopeDoesNotBreach() public {
        _openWithEnvelope(2_000);
        _warpToEpochBoundary(1);
        router.setValue(strategy, 800e18, true); // exactly 20%
        epochs.checkpoint(address(governor), pid);
        assertFalse(epochs.breached(address(governor), pid), "breach must be strictly greater");
    }

    /// @dev D5 — the passive mandate. Total loss, no breach, NAV still recorded.
    function test_passiveMandateCheckpointsButNeverBreaches() public {
        _openWithEnvelope(10_000);
        _warpToEpochBoundary(1);
        router.setValue(strategy, 1, true); // ~100% loss
        epochs.checkpoint(address(governor), pid);
        assertFalse(epochs.breached(address(governor), pid));
        assertEq(epochs.navAt(address(governor), pid, 0), 1, "NAV still feeds monitoring");
    }

    /// @dev The breach is stamped on the epoch it SURFACED on, and it is the
    ///      FIRST one: a later, deeper checkpoint must not move liability onto a
    ///      different epoch's coverers.
    function test_breach_stampsTheEpochItSurfacedOnAndDoesNotMove() public {
        _openWithEnvelope(2_000);
        _warpToEpochBoundary(1);
        router.setValue(strategy, 700e18, true); // 30% — breaches on epoch 0
        epochs.checkpoint(address(governor), pid);
        assertEq(epochs.coverOf(address(governor), pid).breachEpoch, 0);

        _warpToEpochBoundary(2);
        router.setValue(strategy, 400e18, true); // worse, but liability is fixed
        epochs.checkpoint(address(governor), pid);
        assertEq(epochs.coverOf(address(governor), pid).breachEpoch, 0, "liability stays on the surfacing epoch");
    }

    // ── Task 3 tests: D8, cover-relative epoch indices ──

    /// @dev D8, THE RULE OF THIS PART. `ExposureLedger.epochGenesis` is LEDGER
    ///      DEPLOY TIME, so in production a cover opens in absolute epoch
    ///      40-something; the rest of this file only reads "epoch 0" because the
    ///      fixture deploys the ledger and opens the cover in the same block.
    ///      Every index crossing the API is relative to the cover, so a cover
    ///      opened deep into the ledger's life still numbers its own first watch
    ///      0. Boundaries stay on the ledger's GLOBAL grid — that is what keeps a
    ///      guardian's commitment expiring together with its exposure bucket.
    function test_relativeEpochs_coverOpenedInANonZeroAbsoluteEpochStartsAtZero() public {
        // Three whole epochs of ledger history before this cover exists.
        _warpToEpochBoundary(3);
        _openWithEnvelope(2_000);
        assertEq(epochs.relativeEpochNow(address(governor), pid), 0, "the cover's own first watch is 0");

        // The cover's first boundary is the ledger's absolute epoch-4 boundary:
        // boundaries are global, indices are relative.
        _warpToEpochBoundary(4);
        assertEq(epochs.relativeEpochNow(address(governor), pid), 1);
        router.setValue(strategy, 700e18, true);
        epochs.checkpoint(address(governor), pid);

        assertEq(epochs.navAt(address(governor), pid, 0), 700e18, "filed under the cover's epoch 0");
        assertEq(epochs.navAt(address(governor), pid, 3), 0, "never under the absolute index");
        assertEq(epochs.coverOf(address(governor), pid).lastCheckpointedEpoch, 0);
        assertEq(epochs.coverOf(address(governor), pid).breachEpoch, 0);
        assertTrue(epochs.breached(address(governor), pid));
    }

    /// @dev A cover opened MID-epoch waits for the global boundary of the epoch
    ///      it opened in — it never back-fills the ledger epochs that ran before
    ///      it existed — and that first watch is still relative epoch 0.
    function test_relativeEpochs_coverOpenedMidEpochStillNumbersItsFirstWatchZero() public {
        _warpToEpochBoundary(3);
        vm.warp(vm.getBlockTimestamp() + 5 days);
        _openWithEnvelope(2_000);
        assertEq(epochs.relativeEpochNow(address(governor), pid), 0);

        vm.expectRevert(ICoverageEpochs.BoundaryNotReached.selector);
        epochs.checkpoint(address(governor), pid);

        _warpToEpochBoundary(4);
        router.setValue(strategy, 950e18, true);
        epochs.checkpoint(address(governor), pid);
        assertEq(epochs.navAt(address(governor), pid, 0), 950e18);
    }

    /// @dev A skipped boundary consumes a RELATIVE index too: the NAV read two
    ///      of the cover's epochs in belongs to the cover's epoch 1, not to the
    ///      ledger's absolute epoch 4.
    function test_relativeEpochs_missedBoundaryIsLabelledRelatively() public {
        _warpToEpochBoundary(3);
        _openWithEnvelope(2_000);
        _warpToEpochBoundary(5); // two of the cover's epochs have passed
        router.setValue(strategy, 700e18, true);
        epochs.checkpoint(address(governor), pid);

        assertEq(epochs.navAt(address(governor), pid, 1), 700e18, "the cover's epoch 1");
        assertEq(epochs.navAt(address(governor), pid, 0), 0, "the skipped watch stays unrecorded");
        assertEq(epochs.navAt(address(governor), pid, 4), 0, "never the absolute index");
        assertEq(epochs.coverOf(address(governor), pid).breachEpoch, 1);
    }

    function test_relativeEpochNow_revertsWithoutAnOpenCover() public {
        vm.expectRevert(ICoverageEpochs.NotOpened.selector);
        epochs.relativeEpochNow(address(governor), pid);
    }

    // ── Task 4 helpers ──

    /// @dev Everything the ledger needs to price and book a renewal's exposure:
    ///      a feed for the vault asset, a WOOD haircut price, the renewal-agent
    ///      role on `epochs`, and two guardians with $5,000 of budget each
    ///      (100k WOOD at $0.05).
    function _wireRenewal() internal {
        coverageAsset = makeAddr("coverageAsset");
        vm.mockCall(coverageAsset, abi.encodeWithSignature("decimals()"), abi.encode(uint8(6)));
        MockCoverageFeed feed = new MockCoverageFeed(1e8, 8); // $1.00
        vault.setAsset(coverageAsset);
        governor.setRequiredCoverage(1_000e6); // $1,000 of coverage

        vm.startPrank(owner);
        ledger.setWoodUsdPrice(0.05e8);
        // Long staleness tolerance: these tests warp whole epochs, and feed
        // staleness is ExposureLedger's concern, not this suite's.
        ledger.setAssetFeed(coverageAsset, address(feed), 3_650 days);
        ledger.setRenewalAgent(address(epochs));
        vm.stopPrank();

        swood.setStake(guardianA, 100_000e18, 0);
        swood.setStake(guardianB, 100_000e18, 0);
    }

    // ── Task 4 tests: renewal commitments ──

    function test_renewal_acceptedBeforeTheDeadline() public {
        _wireRenewal();
        _open();

        // Hoisted: a call in ARGUMENT position would evaluate before `vm.prank`
        // and eat it, and this repo has been bitten by that before.
        uint256 deadline = epochs.renewalDeadline(address(governor), pid, 1);
        vm.warp(deadline - 1);

        vm.expectEmit(true, true, true, true);
        emit ICoverageEpochs.RenewalCommitted(_key(), 1, guardianA);
        vm.prank(guardianA);
        epochs.commitRenewal(address(governor), pid, 1);

        assertEq(epochs.renewalCoverersOf(address(governor), pid, 1).length, 1);
        assertEq(epochs.renewalCoverersOf(address(governor), pid, 1)[0], guardianA);
    }

    /// @dev THE SEQUENCING TEST. After the deadline — even one second before the
    ///      boundary, when the NAV is visibly cratering — renewal is closed.
    ///      This is what stops the last-moment exit run on a DISCONTINUOUS move.
    function test_renewal_refusedAfterTheDeadlineEvenBeforeTheBoundary() public {
        _wireRenewal();
        _open();

        uint256 boundary = ledger.epochGenesis() + EPOCH_LENGTH;
        vm.warp(boundary - 1); // one second before the boundary
        router.setValue(strategy, 1e18, true); // visibly catastrophic

        vm.prank(guardianA);
        vm.expectRevert(ICoverageEpochs.RenewalClosed.selector);
        epochs.commitRenewal(address(governor), pid, 1);
    }

    /// @dev The exact second. `>=` closes renewal AT the deadline, so the last
    ///      accepted instant is `deadline - 1` — pinned in the test above.
    function test_renewal_refusedAtTheExactDeadlineSecond() public {
        _wireRenewal();
        _open();

        uint256 deadline = epochs.renewalDeadline(address(governor), pid, 1);
        vm.warp(deadline);
        assertLt(vm.getBlockTimestamp(), ledger.epochGenesis() + EPOCH_LENGTH, "still before the boundary");

        vm.prank(guardianA);
        vm.expectRevert(ICoverageEpochs.RenewalClosed.selector);
        epochs.commitRenewal(address(governor), pid, 1);
    }

    /// @dev The sequencing property stated as an ordering: the deadline for the
    ///      epoch about to begin is strictly EARLIER than the checkpoint that
    ///      reveals the epoch now ending. Renewal therefore commits blind to the
    ///      boundary NAV.
    function test_checkpointCannotPrecedeTheRenewalDeadline() public {
        _wireRenewal();
        _open();

        uint256 deadline = epochs.renewalDeadline(address(governor), pid, 1);
        vm.warp(deadline);
        vm.expectRevert(ICoverageEpochs.BoundaryNotReached.selector);
        epochs.checkpoint(address(governor), pid);
    }

    function test_renewal_consumesExposureCapacity() public {
        _wireRenewal();
        _open();

        uint256 openBefore = ledger.openExposureUsd(guardianA);
        vm.prank(guardianA);
        epochs.commitRenewal(address(governor), pid, 1);
        assertGt(ledger.openExposureUsd(guardianA), openBefore, "renewal must book exposure");
        assertEq(ledger.openExposureUsd(guardianA), 1_000e18, "the proposal's full $1,000 of coverage");
    }

    /// @dev The reason booking is not optional: a guardian whose bond is already
    ///      fully spoken for cannot renew. Skipping the ledger call would let it
    ///      back an unbounded number of epochs on one bond.
    function test_renewal_withoutCapacityIsRefused() public {
        _wireRenewal();
        _open();
        swood.setStake(guardianA, 0, 0); // no bond, no budget

        vm.prank(guardianA);
        vm.expectRevert(IExposureLedger.ExposureCapExceeded.selector);
        epochs.commitRenewal(address(governor), pid, 1);
        assertEq(epochs.renewalCoverersOf(address(governor), pid, 1).length, 0, "nothing recorded on a revert");
    }

    /// @dev `ExposureLedger.recordApproval` is deliberately idempotent (it
    ///      absorbs a vote-change round trip), so without this guard a second
    ///      commit would silently succeed and push a duplicate coverer.
    function test_renewal_doubleCommitReverts() public {
        _wireRenewal();
        _open();

        vm.startPrank(guardianA);
        epochs.commitRenewal(address(governor), pid, 1);
        vm.expectRevert(ICoverageEpochs.AlreadyCommitted.selector);
        epochs.commitRenewal(address(governor), pid, 1);
        vm.stopPrank();

        assertEq(epochs.renewalCoverersOf(address(governor), pid, 1).length, 1, "no duplicate coverer");
    }

    /// @dev Relative epoch 0 is the watch the cover OPENED on — covered by the
    ///      original approvers via the ledger. Accepting a "renewal" for it
    ///      would create a second, contradictory notion of who covered epoch 0.
    function test_renewal_epochZeroIsNotARenewal() public {
        _wireRenewal();
        _open();

        vm.prank(guardianA);
        vm.expectRevert(ICoverageEpochs.InvalidParameter.selector);
        epochs.commitRenewal(address(governor), pid, 0);
    }

    function test_renewal_revertsWithoutAnOpenCover() public {
        _wireRenewal();
        vm.prank(guardianA);
        vm.expectRevert(ICoverageEpochs.NotOpened.selector);
        epochs.commitRenewal(address(governor), pid, 1);
    }

    function test_renewalDeadline_revertsWithoutAnOpenCover() public {
        vm.expectRevert(ICoverageEpochs.NotOpened.selector);
        epochs.renewalDeadline(address(governor), pid, 1);
    }

    function test_renewalLeadTime_defaultsToThreeDays() public view {
        assertEq(epochs.renewalLeadTime(), 3 days);
    }

    function test_renewalLeadTime_boundedAndOwnerOnly() public {
        // Hoisted before any prank: a call in argument position eats it.
        uint256 half = ledger.epochLength() / 2;

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        epochs.setRenewalLeadTime(1 days);

        vm.startPrank(owner);
        // Zero would put the deadline ON the boundary: renewal would stay open
        // until the instant the checkpoint can be taken, closing no window at all.
        vm.expectRevert(ICoverageEpochs.InvalidParameter.selector);
        epochs.setRenewalLeadTime(0);
        // Beyond half an epoch guardians commit against badly stale information —
        // a different failure, not a stronger defence (fact 2).
        vm.expectRevert(ICoverageEpochs.InvalidParameter.selector);
        epochs.setRenewalLeadTime(half + 1);

        vm.expectEmit(true, true, true, true);
        emit ICoverageEpochs.RenewalLeadTimeSet(3 days, half);
        epochs.setRenewalLeadTime(half); // the boundary itself is legal
        vm.stopPrank();

        assertEq(epochs.renewalLeadTime(), half);
    }

    /// @dev A longer lead time moves the deadline EARLIER, widening the blind
    ///      window. The deadline must track the setter, not a cached value.
    function test_renewalLeadTime_movesTheDeadline() public {
        _wireRenewal();
        _open();
        uint256 boundary = ledger.epochGenesis() + EPOCH_LENGTH;
        assertEq(epochs.renewalDeadline(address(governor), pid, 1), boundary - 3 days);

        vm.prank(owner);
        epochs.setRenewalLeadTime(10 days);
        assertEq(epochs.renewalDeadline(address(governor), pid, 1), boundary - 10 days);
    }

    // ── Task 4 tests: D8, the relative→global boundary conversion ──

    /// @dev D8, THE HIGHEST-RISK CONVERSION IN THIS TASK. `commitRenewal`'s
    ///      argument is COVER-RELATIVE; the deadline it is checked against lives
    ///      on the ledger's GLOBAL grid. Reading the argument as an absolute
    ///      epoch index puts the cover's epoch-1 deadline three epochs in the
    ///      PAST for a cover opened in absolute epoch 3 — every renewal would be
    ///      refused as already closed, and the whole cover would wind down for a
    ///      reason nobody could see. Every test above opens in absolute epoch 0
    ///      and is blind to this.
    function test_renewal_deadlineIsRelativeToTheCoverNotTheLedger() public {
        _wireRenewal();
        _warpToEpochBoundary(3); // three whole epochs of ledger history first
        _open();

        // The cover's relative epoch 1 BEGINS at the ledger's absolute epoch-4
        // boundary: the label is relative, the grid is global.
        uint256 globalBoundary = ledger.epochGenesis() + 4 * EPOCH_LENGTH;
        assertEq(epochs.renewalDeadline(address(governor), pid, 1), globalBoundary - 3 days);
        assertGt(
            epochs.renewalDeadline(address(governor), pid, 1),
            vm.getBlockTimestamp(),
            "an absolute reading would put the deadline in the past"
        );

        // ...and the deadline is live, not merely arithmetically correct.
        vm.warp(globalBoundary - 3 days - 1);
        vm.prank(guardianA);
        epochs.commitRenewal(address(governor), pid, 1);
        assertEq(epochs.renewalCoverersOf(address(governor), pid, 1)[0], guardianA);

        vm.warp(globalBoundary - 3 days);
        vm.prank(guardianB);
        vm.expectRevert(ICoverageEpochs.RenewalClosed.selector);
        epochs.commitRenewal(address(governor), pid, 1);
    }

    /// @dev The conversion must hold for every relative index, not just 1 — an
    ///      implementation that special-cased the first renewal would pass the
    ///      test above.
    function test_renewal_deadlinesMarchWithTheGlobalGrid() public {
        _wireRenewal();
        _warpToEpochBoundary(3);
        _open();

        for (uint256 n = 1; n <= 4; n++) {
            assertEq(
                epochs.renewalDeadline(address(governor), pid, n),
                ledger.epochGenesis() + (3 + n) * EPOCH_LENGTH - 3 days,
                "relative n sits on the global (openEpoch + n) boundary"
            );
        }
    }

    /// @dev A cover opened MID-epoch renews against the same global grid: the
    ///      deadline is anchored to the boundary, never to `openedAt`. Anchoring
    ///      to `openedAt` would desynchronise the commitment from the exposure
    ///      bucket it is supposed to expire with.
    function test_renewal_midEpochCoverStillUsesTheGlobalBoundary() public {
        _wireRenewal();
        _warpToEpochBoundary(3);
        vm.warp(vm.getBlockTimestamp() + 5 days);
        _open();

        assertEq(
            epochs.renewalDeadline(address(governor), pid, 1),
            ledger.epochGenesis() + 4 * EPOCH_LENGTH - 3 days,
            "the boundary, not openedAt + epochLength"
        );
    }

    /// @dev A renewal booked for the cover's epoch 1 lands in the LEDGER bucket
    ///      current at commit time — the global grid the exposure expires on.
    ///      This is the desynchronisation D8 exists to prevent, observed rather
    ///      than argued.
    function test_renewal_booksIntoTheLedgersGlobalEpochBucket() public {
        _wireRenewal();
        _warpToEpochBoundary(3);
        _open();

        vm.prank(guardianA);
        epochs.commitRenewal(address(governor), pid, 1);

        assertEq(ledger.currentEpoch(), 3, "committed during the ledger's absolute epoch 3");
        assertEq(ledger.openExposureUsd(guardianA), 1_000e18);
        assertEq(epochs.relativeEpochNow(address(governor), pid), 0, "which is the cover's epoch 0");
    }

    // ── Task 5 helpers ──

    /// @dev Wire the ORIGINAL approver side of a cover: `guardianA` and
    ///      `guardianB` each book a non-zero share of the proposal's coverage
    ///      through the ledger, exactly as `GuardianRegistry` does at vote time.
    ///
    ///      The $600 budgets are load-bearing. `recordApproval` returns early
    ///      once `already >= needUsd`, so with `_wireRenewal`'s default $5,000
    ///      guardians the FIRST approver would cover the whole $1,000 need and
    ///      the second would book nothing and never even be listed — the fixture
    ///      would then be testing a one-approver set while claiming two.
    ///      $600 + $400 against $1,000 puts both in the ledger with real shares.
    function _wireEpochZeroApprovers() internal {
        _wireRenewal();

        vm.prank(owner);
        ledger.setGuardianRegistry(registry);

        swood.setStake(guardianA, 12_000e18, 0); // $600 at $0.05/WOOD
        swood.setStake(guardianB, 12_000e18, 0); // $600
        swood.setStake(guardianC, 100_000e18, 0); // $5,000, the renewer

        vm.startPrank(registry);
        ledger.recordApproval(address(governor), pid, guardianA);
        ledger.recordApproval(address(governor), pid, guardianB);
        vm.stopPrank();
    }

    /// @dev THE REAL `ChallengeGame`, ASKED THE REAL QUESTION. This helper used
    ///      to be a hand-written copy of `ChallengeGame._accused`'s filter, kept
    ///      here because the game exposed no public accused view — which made it
    ///      a THIRD copy of a filter that already existed twice, asserting the
    ///      other two agreed while being free to drift from both.
    ///
    ///      Task 7 added `accusedFor`, so the comparison now runs against the
    ///      code that actually slashes. The guarantee is unchanged and still
    ///      load-bearing: predicate 5 at relative epoch 0 takes the LEDGER path
    ///      inside `ChallengeGame` (only a NON-ZERO epoch routes through
    ///      `coverersOf`), so `CoverageEpochs.coverersOf(.., 0)` and the game's
    ///      own filter remain two separate implementations that must never
    ///      disagree — if they do, one slashes a guardian the other calls
    ///      innocent. What is gone is the copy that could disagree with both.
    ///
    ///      The game is constructed against THIS fixture's `ledger`, which is
    ///      the point: a divergence in the ledger read shows up right here. Its
    ///      WOOD and tier-registry arguments are placeholders — the epoch-0
    ///      derivation touches neither, and no challenge is ever filed on it.
    function _accusedOracle(address governor_, uint256 proposalId_) internal view returns (address[] memory) {
        return challengeGame.accusedFor(governor_, proposalId_, IChallengeGame.Predicate.DrawdownBreach, 0);
    }

    function _assertSameSet(address[] memory got, address[] memory want, string memory what) internal pure {
        assertEq(got.length, want.length, what);
        for (uint256 i = 0; i < want.length; i++) {
            assertEq(got[i], want[i], what);
        }
    }

    // ── Task 5 tests: claims-made attribution ──

    /// @dev Relative epoch 0 is the watch the cover opened on, and its coverers
    ///      are the ledger's original approvers — not the (empty) renewal list.
    function test_epochZeroCoverersAreTheOriginalApprovers() public {
        _wireEpochZeroApprovers();
        _warpToEpochBoundary(3); // a NON-ZERO absolute epoch (D8)
        _open();

        address[] memory cov = epochs.coverersOf(address(governor), pid, 0);
        assertEq(cov.length, 2, "both original approvers cover epoch 0");
        assertEq(cov[0], guardianA);
        assertEq(cov[1], guardianB);

        assertEq(
            epochs.renewalCoverersOf(address(governor), pid, 0).length,
            0,
            "the renewal list is empty for epoch 0: coverersOf is the unified view"
        );
    }

    /// @dev Epoch 0's set must be the SAME set `ChallengeGame._accused`
    ///      computes, filter for filter — SO LONG AS NO RENEWAL HAS LANDED. A
    ///      renewal books through `recordApproval` under the same `proposalId`,
    ///      which moves the two apart on purpose; see
    ///      `test_epochZeroDivergesFromChallengeGameOnceARenewalLands` for the
    ///      residual exposure that leaves and why it cannot be closed here.
    function test_epochZeroCoverersMatchChallengeGameAccused() public {
        _wireEpochZeroApprovers();
        _warpToEpochBoundary(3);
        _open();

        _assertSameSet(
            epochs.coverersOf(address(governor), pid, 0),
            _accusedOracle(address(governor), pid),
            "epoch 0 must equal ChallengeGame._accused"
        );

        // ...and it must still equal it once the set has a hole in it.
        vm.prank(registry);
        ledger.releaseApproval(address(governor), pid, guardianA);
        _assertSameSet(
            epochs.coverersOf(address(governor), pid, 0),
            _accusedOracle(address(governor), pid),
            "still equal after a release"
        );
    }

    function test_laterEpochCoverersAreTheRenewers() public {
        _wireEpochZeroApprovers();
        _warpToEpochBoundary(3);
        _open();

        vm.prank(guardianC);
        epochs.commitRenewal(address(governor), pid, 1);

        address[] memory cov = epochs.coverersOf(address(governor), pid, 1);
        assertEq(cov.length, 1);
        assertEq(cov[0], guardianC, "epoch 1 is guardianC's watch");
    }

    /// @dev THE CORE CLAIMS-MADE PROPERTY. An original approver who did not
    ///      renew answers for NOTHING that surfaces after its own epoch — which
    ///      is what bounds a guardian's commitment at one epoch plus the
    ///      challenge window however long the strategy runs.
    function test_originalApproverIsNotLiableForALaterEpoch() public {
        _wireEpochZeroApprovers();
        _warpToEpochBoundary(3);
        _open();

        vm.prank(guardianC);
        epochs.commitRenewal(address(governor), pid, 1);

        address[] memory cov = epochs.coverersOf(address(governor), pid, 1);
        for (uint256 i = 0; i < cov.length; i++) {
            assertNotEq(cov[i], guardianA, "guardianA's watch ended at epoch 0");
            assertNotEq(cov[i], guardianB, "guardianB's watch ended at epoch 0");
        }
        // A guardian is only ever released from FUTURE epochs, never from its
        // own: epoch 0 still names them.
        assertEq(epochs.coverersOf(address(governor), pid, 0).length, 2);
    }

    /// @dev An epoch nobody renewed has NO coverers. This is the honest answer,
    ///      not a fallback to epoch 0's approvers: silently re-accusing the
    ///      original approvers for an unrenewed watch is precisely the
    ///      open-ended liability §3.4a exists to end. (Task 6 turns this state
    ///      into a wind-down.)
    function test_unrenewedEpochHasNoCoverers() public {
        _wireEpochZeroApprovers();
        _warpToEpochBoundary(3);
        _open();

        assertEq(epochs.coverersOf(address(governor), pid, 1).length, 0);
        assertEq(epochs.coverersOf(address(governor), pid, 9).length, 0);
    }

    /// @dev A guardian that released its commitment before the filing backed
    ///      nothing. `ExposureLedger` keeps it in `_approversOf` with a ZEROED
    ///      share rather than dropping it, so the non-zero-`committedUsd` filter
    ///      — not the array membership — is what defines coverage.
    function test_releasedApproverIsNotACoverer() public {
        _wireEpochZeroApprovers();
        _warpToEpochBoundary(3);
        _open();

        vm.prank(registry);
        ledger.releaseApproval(address(governor), pid, guardianB);

        // The ledger still LISTS it, with a zero share...
        (address[] memory all,) = ledger.approversOf(address(governor), pid);
        assertEq(all.length, 2, "the ledger keeps the full historical set");

        // ...and the coverer set does not.
        address[] memory cov = epochs.coverersOf(address(governor), pid, 0);
        assertEq(cov.length, 1);
        for (uint256 i = 0; i < cov.length; i++) {
            assertNotEq(cov[i], guardianB, "a zero committed share is not coverage");
        }
    }

    // ── Epoch 0 covers the ORIGINAL approvers, never a later renewer ──
    //
    // `commitRenewal` books through `exposureLedger.recordApproval(governor,
    // proposalId, msg.sender)` under the SAME `proposalId`, so a renewer joins
    // the very list `coverersOf(.., 0)` reads. A live ledger read alone
    // therefore cannot tell "backed this proposal at vote time" from "took over
    // the watch three epochs later" — and an epoch-0 predicate-5 filing would
    // slash a guardian for a watch it never stood.

    /// @dev The fixture that makes a renewer VISIBLE in the ledger's approver
    ///      list. `recordApproval` returns early once `already >= needUsd`, so
    ///      with `_wireEpochZeroApprovers`'s fully-covered $1,000 a renewer books
    ///      nothing, is never listed, and the misattribution stays invisible —
    ///      the fixture would quietly assert the bug away.
    ///
    ///      $2,000 of required coverage against two $600 guardians leaves $800
    ///      unbooked, so the renewer's commitment lands in `_approversOf` with a
    ///      real share. Under-coverage is not contrived: `recordApproval`'s own
    ///      docs say an under-bonded guardian "commits what it can", and the same
    ///      hole opens whenever an original approver releases.
    function _wireUnderCoveredEpochZeroApprovers() internal {
        _wireRenewal();

        vm.prank(owner);
        ledger.setGuardianRegistry(registry);

        governor.setRequiredCoverage(2_000e6); // $2,000, more than A + B can carry
        swood.setStake(guardianA, 12_000e18, 0); // $600 at $0.05/WOOD
        swood.setStake(guardianB, 12_000e18, 0); // $600
        swood.setStake(guardianC, 100_000e18, 0); // $5,000, the renewer

        vm.startPrank(registry);
        ledger.recordApproval(address(governor), pid, guardianA);
        ledger.recordApproval(address(governor), pid, guardianB);
        vm.stopPrank();
    }

    /// @dev THE BUG THIS FIX EXISTS FOR. `guardianC`'s first commitment to this
    ///      proposal is relative epoch 3. It answers for epoch 3 and for nothing
    ///      before it — anything else is claims-made attribution running
    ///      backwards, the open-ended liability §3.4a ends arriving from the
    ///      other direction.
    function test_renewerOnlyGuardianIsNotAnEpochZeroCoverer() public {
        _wireUnderCoveredEpochZeroApprovers();
        _warpToEpochBoundary(3); // a NON-ZERO absolute epoch (D8)
        _open();

        _warpToEpochBoundary(5); // the cover's relative epoch 2
        vm.prank(guardianC);
        epochs.commitRenewal(address(governor), pid, 3);

        // The ledger genuinely cannot tell the difference: guardianC is in the
        // approver list with a real share, which is what made the live read a
        // wrong answer for epoch 0.
        (address[] memory all, uint256[] memory usd) = ledger.approversOf(address(governor), pid);
        assertEq(all.length, 3, "the renewal booked under the same proposalId");
        assertEq(all[2], guardianC);
        assertGt(usd[2], 0, "and with a non-zero share, so the filter alone cannot exclude it");

        address[] memory zero = epochs.coverersOf(address(governor), pid, 0);
        assertEq(zero.length, 2, "epoch 0 is the original approvers and nobody else");
        assertEq(zero[0], guardianA);
        assertEq(zero[1], guardianB);
        for (uint256 i = 0; i < zero.length; i++) {
            assertNotEq(zero[i], guardianC, "guardianC never stood epoch 0's watch");
        }
        assertFalse(
            epochs.isOriginalApprover(address(governor), pid, guardianC), "a renewal is not a retroactive approval"
        );

        // ...and it is fully liable for the watch it DID stand.
        address[] memory three = epochs.coverersOf(address(governor), pid, 3);
        assertEq(three.length, 1);
        assertEq(three[0], guardianC, "epoch 3 is guardianC's watch");
    }

    /// @dev THE TEST THAT PROVES THE FIX IS NOT OVER-BROAD, and the reason it is
    ///      an AND on the original-approver snapshot rather than an exclusion of
    ///      anyone who renewed. §3.4a is explicit that "incumbent guardians roll
    ///      over", so `guardianA` — an original approver who ALSO renews — stands
    ///      TWO watches and answers for both. Excluding renewers would acquit it
    ///      of epoch 0 and swap one attribution bug for its mirror image.
    function test_rolledOverIncumbentIsLiableForBothWatches() public {
        _wireUnderCoveredEpochZeroApprovers();
        _warpToEpochBoundary(3);
        _open();

        // The incumbent rolls over, and a newcomer joins the same watch.
        vm.prank(guardianA);
        epochs.commitRenewal(address(governor), pid, 1);
        vm.prank(guardianC);
        epochs.commitRenewal(address(governor), pid, 1);

        address[] memory zero = epochs.coverersOf(address(governor), pid, 0);
        assertEq(zero.length, 2, "renewing does not release the incumbent from its own watch");
        assertEq(zero[0], guardianA, "the rolled-over incumbent still answers for epoch 0");
        assertEq(zero[1], guardianB);

        address[] memory one = epochs.coverersOf(address(governor), pid, 1);
        assertEq(one.length, 2, "and for the one it renewed into");
        assertEq(one[0], guardianA);
        assertEq(one[1], guardianC);

        assertTrue(epochs.isOriginalApprover(address(governor), pid, guardianA));
        assertFalse(epochs.isOriginalApprover(address(governor), pid, guardianC));
    }

    /// @dev The two halves are independent, and the release half is unchanged.
    ///      `_originalApprover` is snapshotted once and never cleared, so if it
    ///      REPLACED the live ledger read a released incumbent would be frozen
    ///      into epoch 0 forever. It is an AND with the live read precisely so a
    ///      release still drops a guardian out dynamically — the behaviour
    ///      `test_releasedApproverIsNotACoverer` pins — while the snapshot only
    ///      ever takes guardians OUT.
    function test_originalApproverFlagSurvivesAReleaseButCoverageDoesNot() public {
        _wireUnderCoveredEpochZeroApprovers();
        _warpToEpochBoundary(3);
        _open();

        vm.prank(registry);
        ledger.releaseApproval(address(governor), pid, guardianB);

        assertTrue(
            epochs.isOriginalApprover(address(governor), pid, guardianB),
            "the snapshot records where a guardian started, not what it holds now"
        );
        address[] memory zero = epochs.coverersOf(address(governor), pid, 0);
        assertEq(zero.length, 1, "but a zeroed share is still not coverage");
        assertEq(zero[0], guardianA);
    }

    /// @dev THE RESIDUAL EXPOSURE, RECORDED RATHER THAN ASSUMED AWAY. This fix
    ///      does NOT reach `ChallengeGame`: `_accused` routes only NON-ZERO
    ///      epochs through `coverersOf`, and its epoch-0 branch still reads the
    ///      ledger directly — so an epoch-0 predicate-5 filing STILL accuses a
    ///      renewer-only guardian. Closing it needs a change inside
    ///      `ChallengeGame.sol`, which is outside this change's blast radius.
    ///
    ///      Asserting the divergence rather than describing it means whoever
    ///      lands that change is told by a red test that this note is stale.
    function test_epochZeroDivergesFromChallengeGameOnceARenewalLands() public {
        _wireUnderCoveredEpochZeroApprovers();
        _warpToEpochBoundary(3);
        _open();

        vm.prank(guardianC);
        epochs.commitRenewal(address(governor), pid, 1);

        assertEq(epochs.coverersOf(address(governor), pid, 0).length, 2, "this contract has the right answer");

        // The real ChallengeGame, asked the real question, still has the wrong
        // one. When this stops being true, delete the assertion below and the
        // caveat on `test_epochZeroCoverersMatchChallengeGameAccused`.
        address[] memory accused = _accusedOracle(address(governor), pid);
        assertEq(accused.length, 3, "ChallengeGame's epoch-0 branch still reads the ledger, renewers included");
        assertEq(accused[2], guardianC, "the renewer-only guardian remains exposed to an epoch-0 filing");
    }

    /// @dev `breachEpoch` names the epoch the breach SURFACED on, not the one
    ///      the cover opened on — and the coverers it points at are that epoch's
    ///      renewers. Opened in absolute epoch 3 so a relative/absolute mix-up
    ///      cannot pass, and checkpointed clean once first so the surfacing
    ///      epoch and the opening epoch are different numbers.
    function test_breachEpochIsRecorded() public {
        _wireEpochZeroApprovers();
        _warpToEpochBoundary(3);
        _openWithEnvelope(2_000); // 20%

        vm.prank(guardianC);
        epochs.commitRenewal(address(governor), pid, 1);

        // Relative epoch 0 closes inside the envelope: 5% down, no breach.
        _warpToEpochBoundary(4);
        router.setValue(strategy, 950e18, true);
        epochs.checkpoint(address(governor), pid);
        assertFalse(epochs.breached(address(governor), pid));

        // Relative epoch 1 closes 30% down — the breach surfaces on guardianC's
        // watch, not on the approvers'.
        _warpToEpochBoundary(5);
        router.setValue(strategy, 700e18, true);
        epochs.checkpoint(address(governor), pid);

        assertTrue(epochs.breached(address(governor), pid));
        assertEq(epochs.breachEpochOf(address(governor), pid), 1, "the watch it surfaced on, not the one it opened on");

        address[] memory liable =
            epochs.coverersOf(address(governor), pid, epochs.breachEpochOf(address(governor), pid));
        assertEq(liable.length, 1);
        assertEq(liable[0], guardianC, "predicate 5 accuses epoch 1's coverer");
    }

    /// @dev Task 3 latches `breached` on the FIRST breach, so a later, deeper
    ///      checkpoint must not re-point `breachEpoch` at a different epoch's
    ///      coverers. Without the latch, liability would migrate to whoever
    ///      happened to renew after the loss was already visible.
    function test_breachEpochDoesNotMoveToADeeperLaterCheckpoint() public {
        _wireEpochZeroApprovers();
        _warpToEpochBoundary(3);
        _openWithEnvelope(2_000);

        _warpToEpochBoundary(4);
        router.setValue(strategy, 700e18, true); // 30% down: breach on relative 0
        epochs.checkpoint(address(governor), pid);
        assertEq(epochs.breachEpochOf(address(governor), pid), 0);

        _warpToEpochBoundary(5);
        router.setValue(strategy, 400e18, true); // 60% down
        epochs.checkpoint(address(governor), pid);
        assertEq(epochs.breachEpochOf(address(governor), pid), 0, "still the epoch it surfaced on");
    }

    function test_breachEpochOfIsZeroWithoutABreach() public {
        _wireEpochZeroApprovers();
        _warpToEpochBoundary(3);
        _open();
        assertEq(epochs.breachEpochOf(address(governor), pid), 0);
        assertFalse(epochs.breached(address(governor), pid));
    }

    // ── Task 6 tests: forced wind-down (D6/D7) ──
    //
    // Every cover here opens in a NON-ZERO absolute epoch. `flagWindDown` reads
    // three cover-relative indices — the epoch now beginning, its coverer list,
    // and the checkpoint flag of the epoch that just closed — against boundaries
    // that stay on the ledger's GLOBAL grid (D8). A fixture that opened in
    // absolute epoch 0 makes the two readings identical and is blind to the
    // whole bug class.

    /// @dev Trigger 1. A boundary passed and nobody committed renewal for the
    ///      epoch now beginning. Task 5 made `coverersOf` return an EMPTY set for
    ///      such an epoch rather than falling back to the original approvers —
    ///      re-accusing them for a watch nobody stood is exactly the open-ended
    ///      liability §3.4a ends. This is where that state goes instead.
    function test_windDown_flaggedWhenNobodyRenewed() public {
        _warpToEpochBoundary(3);
        _open();

        _warpToEpochBoundary(4); // the cover's RELATIVE epoch 1 begins
        assertEq(epochs.relativeEpochNow(address(governor), pid), 1);

        vm.expectEmit(true, true, true, true);
        emit ICoverageEpochs.WindDownFlagged(_key(), 1, true, false);
        vm.prank(stranger); // permissionless
        epochs.flagWindDown(address(governor), pid);

        assertTrue(epochs.windDownRequired(address(governor), pid));
        // D7: the flag is the whole effect. Nothing was seized, nothing moved.
        assertEq(epochs.coverOf(address(governor), pid).baselineNav, BASELINE);
        assertFalse(epochs.breached(address(governor), pid));
    }

    /// @dev D8, AND the reason this suite opens in absolute epoch 3. The renewal
    ///      was committed for the cover's RELATIVE epoch 1; an implementation
    ///      that read the epoch now beginning as the ledger's ABSOLUTE 4 would
    ///      find an empty coverer list and wind a fully covered strategy down.
    function test_windDown_refusedWhileCoverageExists() public {
        _wireEpochZeroApprovers();
        _warpToEpochBoundary(3);
        _open();

        vm.prank(guardianC);
        epochs.commitRenewal(address(governor), pid, 1);

        _warpToEpochBoundary(4);
        vm.expectRevert(ICoverageEpochs.StillCovered.selector);
        epochs.flagWindDown(address(governor), pid);
        assertFalse(epochs.windDownRequired(address(governor), pid));
    }

    /// @dev Trigger 2 (D6). A strategy whose value cannot be established cannot
    ///      be underwritten. The checkpoint is retried inside the grace and fails
    ///      closed (D1); once the grace expires the cover unwinds — it is NEVER
    ///      slashed for the fabricated ~100% loss a router outage would report.
    function test_windDown_flaggedWhenNavStaysUnavailablePastTheGrace() public {
        _wireEpochZeroApprovers();
        _warpToEpochBoundary(3);
        _open();

        vm.prank(guardianC);
        epochs.commitRenewal(address(governor), pid, 1); // fully covered...

        _warpToEpochBoundary(4);
        router.setValue(strategy, 0, false); // ...but unpriceable
        vm.expectRevert(ICoverageEpochs.NavUnavailable.selector);
        epochs.checkpoint(address(governor), pid);

        uint256 grace = epochs.checkpointGrace();
        vm.warp(vm.getBlockTimestamp() + grace + 1);

        vm.expectEmit(true, true, true, true);
        emit ICoverageEpochs.WindDownFlagged(_key(), 1, false, true);
        epochs.flagWindDown(address(governor), pid);

        assertTrue(epochs.windDownRequired(address(governor), pid));
        assertFalse(epochs.breached(address(governor), pid), "an unpriceable strategy winds down, never breaches");
    }

    /// @dev The grace is a window, not a formality: inside it the checkpoint may
    ///      still be retried, so the flag must not arm. Pinned at the exact
    ///      second — `>` means `boundary + grace` is still inside.
    function test_windDown_staleIsNotArmedAtTheLastGraceSecond() public {
        _wireEpochZeroApprovers();
        _warpToEpochBoundary(3);
        _open();

        vm.prank(guardianC);
        epochs.commitRenewal(address(governor), pid, 1);

        _warpToEpochBoundary(4);
        uint256 grace = epochs.checkpointGrace();
        vm.warp(vm.getBlockTimestamp() + grace);

        vm.expectRevert(ICoverageEpochs.StillCovered.selector);
        epochs.flagWindDown(address(governor), pid);
    }

    /// @dev D8 on the OTHER index. Checkpoints are filed under COVER-RELATIVE
    ///      epochs, so the staleness test must read the relative epoch that just
    ///      closed (0), not the absolute one (3). Reading absolutely would find
    ///      `_checkpointed[key][3]` false forever and wind down a cover that was
    ///      checkpointed on time, purely because the grace elapsed.
    function test_windDown_staleIsNotArmedAfterASuccessfulCheckpoint() public {
        _wireEpochZeroApprovers();
        _warpToEpochBoundary(3);
        _open();

        vm.prank(guardianC);
        epochs.commitRenewal(address(governor), pid, 1);

        _warpToEpochBoundary(4);
        router.setValue(strategy, 950e18, true);
        epochs.checkpoint(address(governor), pid);
        assertEq(epochs.navAt(address(governor), pid, 0), 950e18, "filed under the cover's relative epoch 0");

        uint256 grace = epochs.checkpointGrace();
        vm.warp(vm.getBlockTimestamp() + grace + 1);

        vm.expectRevert(ICoverageEpochs.StillCovered.selector);
        epochs.flagWindDown(address(governor), pid);
    }

    /// @dev Relative epoch 0 is the watch the cover opened on: no boundary has
    ///      passed, so there is no epoch "now beginning" to be uncovered and no
    ///      closed epoch to be stale. An ABSOLUTE reading would see epoch 3 here
    ///      and wind the cover down on its first day.
    function test_windDown_refusedBeforeTheFirstBoundary() public {
        _warpToEpochBoundary(3);
        _open();
        assertEq(epochs.relativeEpochNow(address(governor), pid), 0);

        vm.expectRevert(ICoverageEpochs.BoundaryNotReached.selector);
        epochs.flagWindDown(address(governor), pid);
    }

    function test_windDown_cannotBeFlaggedTwice() public {
        _warpToEpochBoundary(3);
        _open();
        _warpToEpochBoundary(4);

        epochs.flagWindDown(address(governor), pid);
        vm.expectRevert(ICoverageEpochs.AlreadyWoundDown.selector);
        epochs.flagWindDown(address(governor), pid);
    }

    function test_windDown_revertsWithoutAnOpenCover() public {
        vm.expectRevert(ICoverageEpochs.NotOpened.selector);
        epochs.flagWindDown(address(governor), pid);
        assertFalse(epochs.windDownRequired(address(governor), pid), "no cover, nothing to wind down");
    }

    /// @dev A cover on its way out must not accept new commitments: a guardian
    ///      booking exposure against it would be underwriting a watch that will
    ///      never be stood.
    function test_windDown_closesRenewal() public {
        _wireEpochZeroApprovers();
        _warpToEpochBoundary(3);
        _open();
        _warpToEpochBoundary(4);
        epochs.flagWindDown(address(governor), pid);

        vm.prank(guardianC);
        vm.expectRevert(ICoverageEpochs.WoundDown.selector);
        epochs.commitRenewal(address(governor), pid, 2);
    }

    function test_checkpointGrace_defaultsToSevenDays() public view {
        assertEq(epochs.checkpointGrace(), 7 days);
    }

    /// @dev Bounded strictly BELOW `epochLength`: a grace at or past a whole
    ///      epoch means the next boundary always arrives first, and the stale
    ///      trigger can never fire at all. Zero is refused for the mirror-image
    ///      reason — checkpoints are permissionless and unpaid, so a zero grace
    ///      winds a healthy cover down over one late transaction.
    function test_checkpointGrace_boundedAndOwnerOnly() public {
        uint256 len = ledger.epochLength(); // hoisted: argument position eats a prank

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        epochs.setCheckpointGrace(1 days);

        vm.startPrank(owner);
        vm.expectRevert(ICoverageEpochs.InvalidParameter.selector);
        epochs.setCheckpointGrace(0);
        vm.expectRevert(ICoverageEpochs.InvalidParameter.selector);
        epochs.setCheckpointGrace(len);

        vm.expectEmit(true, true, true, true);
        emit ICoverageEpochs.CheckpointGraceSet(7 days, len - 1);
        epochs.setCheckpointGrace(len - 1); // one second inside the bound is legal
        vm.stopPrank();

        assertEq(epochs.checkpointGrace(), len - 1);
    }

    /// @dev The grace is read live, not cached at open: shortening it arms the
    ///      stale trigger on a cover that was already waiting.
    function test_checkpointGrace_movesTheStaleTrigger() public {
        _wireEpochZeroApprovers();
        _warpToEpochBoundary(3);
        _open();
        vm.prank(guardianC);
        epochs.commitRenewal(address(governor), pid, 1);

        _warpToEpochBoundary(4);
        vm.warp(vm.getBlockTimestamp() + 2 days); // inside the 7-day default
        vm.expectRevert(ICoverageEpochs.StillCovered.selector);
        epochs.flagWindDown(address(governor), pid);

        vm.prank(owner);
        epochs.setCheckpointGrace(1 days);
        epochs.flagWindDown(address(governor), pid);
        assertTrue(epochs.windDownRequired(address(governor), pid));
    }
}
