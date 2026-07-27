// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ExposureLedger} from "src/ExposureLedger.sol";
import {IExposureLedger} from "src/interfaces/IExposureLedger.sol";

/// @dev Minimal sWOOD stub exposing exactly the reads the ledger consumes.
contract MockSwood {
    mapping(address => uint256) public guardianStake;
    mapping(address => uint256) public delegatedInbound;
    uint256 public maxDelegatedSlashBps = 2000;
    uint256 public coolDownPeriod = 45 days;

    function setStake(address g, uint256 own, uint256 inbound) external {
        guardianStake[g] = own;
        delegatedInbound[g] = inbound;
    }

    function setMaxDelegatedSlashBps(uint256 v) external {
        maxDelegatedSlashBps = v;
    }
}

contract MockFeed {
    int256 public answer;
    uint8 public immutable decimals;
    uint256 public updatedAt;

    constructor(int256 answer_, uint8 decimals_) {
        answer = answer_;
        decimals = decimals_;
        updatedAt = block.timestamp;
    }

    function set(int256 answer_) external {
        answer = answer_;
        updatedAt = block.timestamp;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

contract MockGovernorForLedger {
    address public vaultAddr;
    uint256 public coverage;

    constructor(address vault_) {
        vaultAddr = vault_;
    }

    function set(uint256 coverage_) external {
        coverage = coverage_;
    }

    function getRequiredCoverage(uint256) external view returns (uint256) {
        return coverage;
    }

    struct ProposalViewLite {
        uint256 voteEnd;
        uint256 reviewEnd;
        address vault;
        uint256 executeBy;
        uint256 strategyDuration;
    }

    uint256 public executeBy;
    uint256 public strategyDuration;

    /// @dev Left at 0/0 by default, which makes `coverUntil` fall at or before
    ///      epoch genesis so the ledger books into the CURRENT epoch — the
    ///      pre-ADR behaviour every existing test in this file was written
    ///      against. Set them to exercise the settlement-dated bucket.
    uint256 public reviewEnd;

    /// @dev Separates `reviewEnd` from `executeBy`, which `setSchedule` collapses.
    ///      `settleCoverage` gates on `executeBy` now, and the window between the
    ///      two is exactly where N3's attack lived.
    function setScheduleFull(uint256 executeBy_, uint256 duration_, uint256 reviewEnd_) external {
        executeBy = executeBy_;
        strategyDuration = duration_;
        reviewEnd = reviewEnd_;
    }

    function setSchedule(uint256 executeBy_, uint256 duration_) external {
        executeBy = executeBy_;
        strategyDuration = duration_;
        // In the real governor `executeBy = reviewEnd + executionWindow`, so the
        // review always shuts at or before `executeBy`. `settleCoverage` gates
        // on it, and a mock returning 0 would read as "never closes".
        reviewEnd = executeBy_;
    }

    function getProposalView(uint256) external view returns (ProposalViewLite memory v) {
        v.vault = vaultAddr;
        v.executeBy = executeBy;
        v.strategyDuration = strategyDuration;
        v.reviewEnd = reviewEnd;
    }
}

contract MockVaultForLedger {
    address public asset;

    constructor(address asset_) {
        asset = asset_;
    }
}

/// @dev Registry stub returning a canned approver set for quorum tests.
contract MockRegistryForLedger {
    address[] internal _approvers;

    function setApprovers(address[] memory a) external {
        _approvers = a;
    }

    function getApproverWeights(address, uint256)
        external
        view
        returns (address[] memory approvers, uint128[] memory weights, uint128 total)
    {
        approvers = _approvers;
        weights = new uint128[](approvers.length);
        total = 0;
    }

    /// @dev `setChallengeWindow` floors the window at
    ///      `reviewPeriod + MAX_GOVERNOR_EXECUTION_WINDOW`, so the ledger now
    ///      needs a registry that actually answers this.
    uint256 public reviewPeriod = 3 days;
}

contract ExposureLedgerTest is Test {
    ExposureLedger internal ledger;
    MockSwood internal swood;
    address internal owner = makeAddr("owner");
    address internal guardian = makeAddr("guardian");
    address internal registry = makeAddr("registry");
    address internal freezer = makeAddr("freezer");
    MockGovernorForLedger internal mgov;
    address internal usdgAsset;

    function setUp() public {
        swood = new MockSwood();
        // epochLength 28d immutable; genesis = deploy timestamp.
        ledger = new ExposureLedger(owner, address(swood), 28 days);
        vm.prank(owner);
        ledger.setWoodUsdPrice(0.05e8); // $0.05, conservative haircut price
    }

    function test_slashableBondUsd_ownPlusCappedDelegated() public {
        // own 100k WOOD, inbound 200k WOOD, delegated cap 2000 bps (20%)
        swood.setStake(guardian, 100_000e18, 200_000e18);
        // slashable WOOD = 100k + 200k * 20% = 140k; at $0.05 => $7,000
        assertEq(ledger.slashableBondUsd(guardian), 7_000e18);
    }

    function test_slashableBondUsd_zeroWhenPriceUnset() public {
        ExposureLedger fresh = new ExposureLedger(owner, address(swood), 28 days);
        swood.setStake(guardian, 100_000e18, 0);
        // fail-closed: unset price values every bond at $0 (nothing can be approved)
        assertEq(fresh.slashableBondUsd(guardian), 0);
    }

    function test_setWoodUsdPrice_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        ledger.setWoodUsdPrice(1e8);
    }

    function test_currentEpoch_advances() public {
        uint256 e0 = ledger.currentEpoch();
        vm.warp(block.timestamp + 28 days);
        assertEq(ledger.currentEpoch(), e0 + 1);
    }

    function test_coverageUsd_6decAsset() public {
        MockFeed feed = new MockFeed(1e8, 8); // $1.00, 8-dec feed
        address usdg = makeAddr("usdg");
        vm.mockCall(usdg, abi.encodeWithSignature("decimals()"), abi.encode(uint8(6)));
        vm.prank(owner);
        ledger.setAssetFeed(usdg, address(feed), 1 days);
        // 2,000,000 USDG (6 dec) at $1 => $2,000,000 in USD-18
        assertEq(ledger.coverageUsd(usdg, 2_000_000e6), 2_000_000e18);
    }

    function test_coverageUsd_18decAssetNonUnitPrice() public {
        MockFeed feed = new MockFeed(2500e8, 8); // $2,500 (e.g. WETH)
        address weth = makeAddr("weth");
        vm.mockCall(weth, abi.encodeWithSignature("decimals()"), abi.encode(uint8(18)));
        vm.prank(owner);
        ledger.setAssetFeed(weth, address(feed), 1 days);
        assertEq(ledger.coverageUsd(weth, 2e18), 5_000e18);
    }

    function test_coverageUsd_revertsUnconfigured() public {
        vm.expectRevert(IExposureLedger.FeedNotConfigured.selector);
        ledger.coverageUsd(makeAddr("unknown"), 1e18);
    }

    function test_coverageUsd_revertsStale() public {
        MockFeed feed = new MockFeed(1e8, 8);
        address usdg = makeAddr("usdg2");
        vm.mockCall(usdg, abi.encodeWithSignature("decimals()"), abi.encode(uint8(6)));
        vm.prank(owner);
        ledger.setAssetFeed(usdg, address(feed), 1 days);
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(IExposureLedger.StalePrice.selector);
        ledger.coverageUsd(usdg, 1e6);
    }

    function _wireRecording() internal {
        usdgAsset = makeAddr("usdgAsset");
        vm.mockCall(usdgAsset, abi.encodeWithSignature("decimals()"), abi.encode(uint8(6)));
        MockFeed feed = new MockFeed(1e8, 8);
        MockVaultForLedger vault = new MockVaultForLedger(usdgAsset);
        mgov = new MockGovernorForLedger(address(vault));
        vm.startPrank(owner);
        ledger.setAssetFeed(usdgAsset, address(feed), 365 days);
        ledger.setGuardianRegistry(registry);
        ledger.setCoverageFreezer(freezer);
        vm.stopPrank();
        swood.setStake(guardian, 100_000e18, 0); // slashableBondUsd = $5,000 at $0.05
    }

    function test_recordApproval_registryOnly() public {
        _wireRecording();
        mgov.set(1_000e6);
        vm.expectRevert(IExposureLedger.NotGuardianRegistry.selector);
        ledger.recordApproval(address(mgov), 1, guardian);
    }

    function test_recordApproval_booksExposure() public {
        _wireRecording();
        mgov.set(1_000e6); // $1,000
        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);
        assertEq(ledger.openExposureUsd(guardian), 1_000e18);
    }

    /// @notice An under-bonded guardian is NOT rejected — it commits what its
    ///         free budget allows and the shortfall is left to other approvers
    ///         (or the proposal fails the execute-time quorum). Booking the full
    ///         coverage against every approver would force each one to
    ///         single-handedly cover the proposal, which is §3.3's per-guardian
    ///         batching cap misapplied to a single proposal.
    function test_recordApproval_underBondedGuardianCommitsPartialShare() public {
        _wireRecording();
        mgov.set(6_000e6); // $6,000 needed vs a $5,000 bond
        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);
        // Commits its whole budget, not the full $6,000.
        assertEq(ledger.openExposureUsd(guardian), 5_000e18);
        // ...and the proposal is NOT covered: the quorum still fails.
        vm.expectRevert(IExposureLedger.InsufficientApproveCoverage.selector);
        ledger.requireApproveQuorum(address(mgov), 1, usdgAsset, 6_000e6);
    }

    /// @notice Two half-bonded guardians jointly cover one proposal — §3.3a's
    ///         aggregate quorum doing what it says. Each RESERVES up to the full
    ///         coverage (capped by its own budget); the pro-rata scale-back then
    ///         decides what each actually carries. Arrival order changes
    ///         nothing, which is the property the free-rider veto exploited.
    function test_recordApproval_twoGuardiansAggregateToCover() public {
        _wireRecording();
        address g2 = makeAddr("g2");
        swood.setStake(g2, 100_000e18, 0); // $5,000 each at $0.05
        mgov.set(8_000e6); // $8,000 needed — neither covers it alone

        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);
        assertEq(ledger.openExposureUsd(guardian), 5_000e18, "first reserves its whole budget");

        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, g2);
        // The second reserves its OWN budget too, not merely the remainder —
        // there is no leftover to race for.
        assertEq(ledger.openExposureUsd(g2), 5_000e18, "second reserves its own budget, not the remainder");

        // $10,000 reserved against $8,000 needed, so each carries 5/10 of it.
        assertEq(ledger.allocatedUsd(address(mgov), 1, guardian), 4_000e18, "pro-rata half");
        assertEq(ledger.allocatedUsd(address(mgov), 1, g2), 4_000e18, "...and the other half");

        // Reservations aggregate past the requirement -> covered.
        ledger.requireApproveQuorum(address(mgov), 1, usdgAsset, 8_000e6);
    }

    /// @notice M2 — the approver list must not grow with every guardian that
    ///         ever approved. A release now swap-and-pops, so the array tracks
    ///         CURRENT approvers and the execute-path loop stays bounded by the
    ///         registry's own approver cap rather than by the cohort.
    function test_releaseApproval_popsTheApproverList() public {
        _wireRecording();
        address g2 = makeAddr("g2");
        swood.setStake(g2, 100_000e18, 0);
        mgov.set(1_000e6);

        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);
        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, g2);

        // Release the FIRST of two, so the swap actually moves an element.
        vm.prank(registry);
        ledger.releaseApproval(address(mgov), 1, guardian);

        // The survivor still carries the whole proposal -- proof the swap kept
        // its index consistent rather than orphaning it.
        assertEq(ledger.allocatedUsd(address(mgov), 1, g2), 1_000e18, "survivor intact after the swap");
        assertEq(ledger.allocatedUsd(address(mgov), 1, guardian), 0, "released approver carries nothing");

        // Re-approving re-lists cleanly (the index was cleared, not left stale).
        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);
        assertEq(ledger.openExposureUsd(guardian), 1_000e18, "re-approve books again");
    }

    /// @notice M3 — the registry hook fires for EVERY authorized governor once
    ///         the ledger is wired, including vaults whose asset has no feed.
    ///         Reverting there made approve votes impossible on those vaults
    ///         while Block votes still worked, so reviews became block-only.
    ///         Booking nothing is the conservative half; failing the vote was
    ///         the harmful half.
    function test_recordApproval_unfedAssetBooksNothingInsteadOfReverting() public {
        _wireRecording();
        // Point the governor at a vault whose asset was never given a feed.
        MockVaultForLedger unfed = new MockVaultForLedger(makeAddr("unfedAsset"));
        MockGovernorForLedger gov2 = new MockGovernorForLedger(address(unfed));
        gov2.set(1_000e6);

        vm.prank(registry);
        ledger.recordApproval(address(gov2), 1, guardian); // must not revert
        assertEq(ledger.openExposureUsd(guardian), 0, "nothing booked, but the vote survives");
    }

    /// @notice M4 — the ceiling bounds one CALL; the interval bounds how many.
    ///         Without the interval, N calls in a single multisig batch move the
    ///         price 2^N — seven take $0.05 to $6.40 — and `set(0)` followed by
    ///         `set(anything)` walked straight through the zero exemption in the
    ///         same transaction.
    ///
    ///         Only the UPWARD move is capped, deliberately: this price exists
    ///         to absorb a WOOD crash, and rate-limiting the fall would leave
    ///         bonds over-valued for as long as it took to walk the price down.
    function test_setWoodUsdPrice_intervalAndUpwardCeiling() public {
        vm.startPrank(owner);

        // Same block as the fixture's own update: the interval bites first.
        vm.expectRevert(IExposureLedger.InvalidParameter.selector);
        ledger.setWoodUsdPrice(0.06e8);

        skip(1 days);
        ledger.setWoodUsdPrice(0.1e8); // exactly 2x -- allowed
        assertEq(ledger.woodUsdPriceX8(), 0.1e8);

        // A second move in the same block, however small, is still refused.
        vm.expectRevert(IExposureLedger.InvalidParameter.selector);
        ledger.setWoodUsdPrice(0.11e8);

        skip(1 days);
        vm.expectRevert(IExposureLedger.InvalidParameter.selector);
        ledger.setWoodUsdPrice(0.2000001e8); // a hair over 2x

        ledger.setWoodUsdPrice(0.001e8); // a 100x collapse -- allowed, conservative
        assertEq(ledger.woodUsdPriceX8(), 0.001e8);

        // Zero stays settable: it is the emergency stop, and banning it would
        // strand the price there (any non-zero value exceeds `0 * 2`).
        skip(1 days);
        ledger.setWoodUsdPrice(0);
        assertEq(ledger.woodUsdPriceX8(), 0);

        // ...and the recovery that used to be a free second call now costs a day.
        vm.expectRevert(IExposureLedger.InvalidParameter.selector);
        ledger.setWoodUsdPrice(1_000_000e8);
        skip(1 days);
        ledger.setWoodUsdPrice(1_000_000e8); // exempt from the ceiling, not from time
        vm.stopPrank();
    }

    /// @notice M1 — the challenge window must outlive the longest
    ///         approve->execute gap, or one bond can cover two live drains
    ///         across an epoch boundary. Only the upper bounds were enforced.
    function test_setChallengeWindow_rejectsAWindowShorterThanReviewPlusExecution() public {
        _wireRecording();
        // The shared fixture wires an EOA as the registry, which cannot answer
        // `reviewPeriod()`. Point at a real stub for the floor check.
        MockRegistryForLedger reg = new MockRegistryForLedger();
        vm.startPrank(owner);
        ledger.setGuardianRegistry(address(reg));

        // 3d review + 7d max execution window = a 10d floor.
        vm.expectRevert(IExposureLedger.InvalidParameter.selector);
        ledger.setChallengeWindow(1); // the old code accepted this
        vm.expectRevert(IExposureLedger.InvalidParameter.selector);
        ledger.setChallengeWindow(10 days - 1);

        ledger.setChallengeWindow(10 days); // exactly the floor -- allowed
        assertEq(ledger.challengeWindow(), 10 days);
        vm.stopPrank();
    }

    /// @notice ADR 2026-07-26 — THE SETTLEMENT-COVERAGE BUG.
    ///
    ///         A commitment must outlive the drain it backs. Risk ends at
    ///         `executeBy + strategyDuration + challengeWindow`; keying the
    ///         bucket on `currentEpoch()` expired it at
    ///         `approval + challengeWindow`, releasing the guardian's budget
    ///         roughly a month before their own approval could still be
    ///         challenged. A drain surfacing in that gap had no bond to slash.
    ///
    ///         Booking into the bucket that CONTAINS settlement closes it.
    function test_recordApproval_holdsBudgetUntilSettlementCanBeChallenged() public {
        _wireRecording();
        // Settles ~35 days out: one epoch (28d) ahead of the vote.
        mgov.setSchedule(block.timestamp + 5 days, 30 days);
        mgov.set(1_000e6);

        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);
        assertEq(ledger.openExposureUsd(guardian), 1_000e18, "booked");

        // Past the point the OLD keying would have freed it — one epoch plus a
        // challenge window after the vote. The strategy has not even settled.
        vm.warp(block.timestamp + 28 days + 14 days + 1);
        assertEq(
            ledger.openExposureUsd(guardian), 1_000e18, "still committed while the drain it backs can be challenged"
        );

        // ...and released once the bucket covering settlement has itself
        // expired. Warped well past it rather than pinned to the exact
        // boundary: the point of the test is that release happens AFTER the
        // risk window, not that it happens on a particular second.
        vm.warp(block.timestamp + 120 days);
        assertEq(ledger.openExposureUsd(guardian), 0, "released once the risk window has closed");
    }

    /// @notice N4 — an over-horizon settlement books NOTHING; it does not
    ///         revert the vote. Reverting here took `voteOnProposal` with it,
    ///         leaving a block-only review in which guardians can veto but never
    ///         endorse — the third trigger for the shape M3 was filed for, and
    ///         the only one reachable at defaults, since
    ///         `ProtocolConfig.maxStrategyDuration` ships unset.
    ///
    ///         The refusal moved to `propose`, where it lands on the proposer
    ///         who chose the duration rather than on a cohort that cannot
    ///         change it.
    function test_recordApproval_beyondHorizonBooksNothingAndProposeRejects() public {
        _wireRecording();
        mgov.setSchedule(block.timestamp + 1 days, 365 days); // far past the horizon
        mgov.set(1_000e6);

        // The vote survives and books nothing.
        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);
        assertEq(ledger.openExposureUsd(guardian), 0, "nothing booked, vote intact");

        // ...and propose refuses it outright.
        vm.expectRevert(IExposureLedger.CoverageHorizonExceeded.selector);
        ledger.requireWithinCoverageHorizon(block.timestamp + 1 days, 365 days);

        // A duration inside the horizon passes.
        ledger.requireWithinCoverageHorizon(block.timestamp + 1 days, 30 days);
    }

    /// @notice N3 — settling is NOT neutral, so it must wait until the proposal
    ///         can no longer execute. Settling collapses the A-fold cushion to
    ///         exactly `needUsd` priced at settle time while the quorum
    ///         re-derives it at execute, so any EOA settling at `reviewEnd`
    ///         could let a small price rise permanently brick a covered
    ///         proposal.
    function test_settleCoverage_refusedUntilTheProposalCanNoLongerExecute() public {
        _wireRecording();
        address g2 = makeAddr("g2");
        swood.setStake(g2, 100_000e18, 0);
        mgov.set(1_000e6);
        // reviewEnd is well before executeBy, which is the window the attack used.
        mgov.setScheduleFull(block.timestamp + 20 days, 3 days, block.timestamp + 1 days);

        vm.startPrank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);
        ledger.recordApproval(address(mgov), 1, g2);
        vm.stopPrank();

        skip(2 days); // past reviewEnd, before executeBy
        vm.expectRevert(IExposureLedger.ReviewNotClosed.selector);
        ledger.settleCoverage(address(mgov), 1);

        skip(25 days); // past executeBy
        ledger.settleCoverage(address(mgov), 1);
        assertEq(ledger.allocatedUsd(address(mgov), 1, guardian), 500e18, "settles once execution is moot");
    }

    /// @notice N6 — the haircut is the second multiplier on the same quantity
    ///         and was unbounded, so M4's rate limit was bypassable through it:
    ///         a legal `[1, 10_000]` range with no interval moved every bond's
    ///         valuation 10,000x in one transaction.
    function test_setWoodHaircutBps_rateLimitedAndFloored() public {
        vm.startPrank(owner);
        vm.expectRevert(IExposureLedger.InvalidParameter.selector);
        ledger.setWoodHaircutBps(1); // below the floor -- a mis-set parameter
        vm.expectRevert(IExposureLedger.InvalidParameter.selector);
        ledger.setWoodHaircutBps(10_001);

        ledger.setWoodHaircutBps(8_000);
        // Second move in the same block is refused, as for the price itself.
        vm.expectRevert(IExposureLedger.InvalidParameter.selector);
        ledger.setWoodHaircutBps(5_000);

        skip(1 days);
        ledger.setWoodHaircutBps(5_000);
        vm.stopPrank();
        assertEq(ledger.woodHaircutBps(), 5_000);
    }

    /// @notice M3 — a STALE feed must not kill the approve vote. Closing only
    ///         the missing-feed case left the more reachable half live: a stale
    ///         oracle is an operational condition, not a wiring mistake, and it
    ///         made reviews block-only — guardians able to veto but not endorse,
    ///         with the proposal passing optimistically anyway.
    function test_recordApproval_staleFeedBooksNothingInsteadOfReverting() public {
        _wireRecording();
        mgov.set(1_000e6);

        // Tighten the staleness bound so the fixture's feed is now stale.
        // Hoisted: a constructor in ARGUMENT position is evaluated first and
        // would consume the one-shot prank, leaving the setter unpranked.
        MockFeed tight = new MockFeed(1e8, 8);
        vm.prank(owner);
        ledger.setAssetFeed(usdgAsset, address(tight), 1);
        skip(2 days);

        // The read itself genuinely reverts...
        vm.expectRevert(IExposureLedger.StalePrice.selector);
        ledger.coverageUsd(usdgAsset, 1_000e6);

        // ...but the hook books nothing rather than taking the vote with it.
        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);
        assertEq(ledger.openExposureUsd(guardian), 0, "unpriceable: booked nothing, vote survives");
    }

    /// @notice M1 gap 1 — wiring order was a bypass. `setChallengeWindow` skips
    ///         the floor while no registry is wired, so an out-of-spec window
    ///         could be seated first and the registry pointed at afterwards with
    ///         nothing revalidating.
    function test_setGuardianRegistry_rechecksTheChallengeWindowFloor() public {
        MockRegistryForLedger reg = new MockRegistryForLedger(); // reviewPeriod 3d -> floor 10d
        ExposureLedger led = new ExposureLedger(owner, address(swood), 28 days);

        vm.startPrank(owner);
        led.setChallengeWindow(8 days); // legal while unwired
        assertEq(led.challengeWindow(), 8 days);

        vm.expectRevert(IExposureLedger.InvalidParameter.selector);
        led.setGuardianRegistry(address(reg)); // 8d < 3d + 7d

        led.setChallengeWindow(10 days);
        led.setGuardianRegistry(address(reg)); // now consistent
        vm.stopPrank();
        assertEq(led.guardianRegistry(), address(reg));
    }

    /// @notice N1 — the over-reservation is returned once the approver set is
    ///         final. Every approver reserves up to the whole coverage (that is
    ///         what closed C1), so three approvers on a $1,200 proposal tie up
    ///         $3,600 of cohort budget. Settling collapses that to $1,200.
    function test_settleCoverage_returnsTheOverReservation() public {
        _wireRecording();
        address g2 = makeAddr("g2");
        address g3 = makeAddr("g3");
        swood.setStake(g2, 100_000e18, 0);
        swood.setStake(g3, 100_000e18, 0);
        mgov.set(1_200e6); // $1,200, each guardian holds a $5,000 bond
        mgov.setSchedule(block.timestamp + 1 days, 3 days);

        vm.startPrank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);
        ledger.recordApproval(address(mgov), 1, g2);
        ledger.recordApproval(address(mgov), 1, g3);
        vm.stopPrank();

        uint256 tiedUp = ledger.openExposureUsd(guardian) + ledger.openExposureUsd(g2) + ledger.openExposureUsd(g3);
        assertEq(tiedUp, 3_600e18, "3 x full coverage reserved while the set can still change");

        // Cannot settle while the review is open -- an approver could still be
        // left carrying the whole thing alone.
        vm.expectRevert(IExposureLedger.ReviewNotClosed.selector);
        ledger.settleCoverage(address(mgov), 1);

        skip(31 days); // past reviewEnd
        ledger.settleCoverage(address(mgov), 1); // permissionless

        uint256 afterSettle = ledger.openExposureUsd(guardian) + ledger.openExposureUsd(g2) + ledger.openExposureUsd(g3);
        assertEq(afterSettle, 1_200e18, "collapsed to the real total liability");
        assertEq(ledger.allocatedUsd(address(mgov), 1, guardian), 400e18, "even split, order irrelevant");
        assertEq(ledger.allocatedUsd(address(mgov), 1, g2), 400e18);
        assertEq(ledger.allocatedUsd(address(mgov), 1, g3), 400e18);
    }

    /// @notice Settling must not break the coverage check. Allocations round
    ///         down, so a naive settle leaves the aggregate a few wei under
    ///         `needUsd` and a fully-subscribed proposal would fail its own
    ///         quorum afterwards. The residue goes to the first holder.
    function test_settleCoverage_doesNotBreakTheQuorum() public {
        _wireRecording();
        address g2 = makeAddr("g2");
        address g3 = makeAddr("g3");
        swood.setStake(g2, 100_000e18, 0);
        swood.setStake(g3, 100_000e18, 0);
        mgov.set(1_000e6); // 1000e18 / 3 does not divide evenly
        mgov.setSchedule(block.timestamp + 1 days, 3 days);

        vm.startPrank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);
        ledger.recordApproval(address(mgov), 1, g2);
        ledger.recordApproval(address(mgov), 1, g3);
        vm.stopPrank();

        skip(31 days);
        ledger.settleCoverage(address(mgov), 1);

        // Exactly on the requirement, not a wei under.
        uint256 total = ledger.allocatedUsd(address(mgov), 1, guardian) + ledger.allocatedUsd(address(mgov), 1, g2)
            + ledger.allocatedUsd(address(mgov), 1, g3);
        assertEq(total, 1_000e18, "residue absorbed, not lost");
        ledger.requireApproveQuorum(address(mgov), 1, usdgAsset, 1_000e6); // must not revert
    }

    /// @notice Idempotent. A second pass would otherwise re-divide already
    ///         settled numbers against the shrunken total.
    function test_settleCoverage_isIdempotent() public {
        _wireRecording();
        address g2 = makeAddr("g2");
        swood.setStake(g2, 100_000e18, 0);
        mgov.set(1_000e6);
        mgov.setSchedule(block.timestamp + 1 days, 3 days);
        vm.startPrank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);
        ledger.recordApproval(address(mgov), 1, g2);
        vm.stopPrank();

        skip(31 days);
        ledger.settleCoverage(address(mgov), 1);
        uint256 once = ledger.openExposureUsd(guardian);
        ledger.settleCoverage(address(mgov), 1);
        assertEq(ledger.openExposureUsd(guardian), once, "second pass changes nothing");
    }

    /// @notice THE CAVEAT I LEFT OPEN on `settleCoverage`: a guardian whose
    ///         bond collapses between the review shutting and settle being
    ///         called.
    ///
    ///         The excess release keys off the RECORDED amount and epoch, not
    ///         the live bond — `_buckets[g][e]` was incremented by exactly
    ///         `r.usd` at record time, so subtracting `excess <= r.usd` cannot
    ///         underflow however far the bond has fallen since. Asserted rather
    ///         than assumed, because "I expect it falls out" is how the
    ///         settlement bug got in.
    function test_settleCoverage_survivesABondCollapseBeforeSettling() public {
        _wireRecording();
        address g2 = makeAddr("g2");
        swood.setStake(g2, 100_000e18, 0);
        mgov.set(1_000e6);
        mgov.setSchedule(block.timestamp + 1 days, 3 days);

        vm.startPrank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);
        ledger.recordApproval(address(mgov), 1, g2);
        vm.stopPrank();
        assertEq(ledger.openExposureUsd(guardian), 1_000e18, "reserved the full coverage");

        skip(31 days); // review shut

        // The guardian's bond evaporates -- unstaked, or WOOD collapsed.
        swood.setStake(guardian, 0, 0);
        assertEq(ledger.slashableBondUsd(guardian), 0, "nothing left to slash");

        ledger.settleCoverage(address(mgov), 1); // must not revert or underflow

        // The split follows ABILITY TO PAY (review n1). A guardian with no bond
        // left is allocated nothing, and the survivor absorbs the whole
        // liability rather than being assigned half of a total the cohort can no
        // longer cover.
        //
        // That is not an escape hatch: `StakedWood.claimUnstakeGuardian` refuses
        // while open exposure remains, so the collapsed guardian is held — this
        // only stops their absence from silently shrinking what everyone else
        // owes. Before n1 the two shares were 500/500 and $500 of the $1,000 was
        // simply unrecoverable.
        assertEq(ledger.allocatedUsd(address(mgov), 1, guardian), 0, "cannot pay -> carries nothing");
        assertEq(ledger.allocatedUsd(address(mgov), 1, g2), 1_000e18, "survivor absorbs it all");

        // ...and the proposal is still genuinely covered, where it was not before.
        ledger.requireApproveQuorum(address(mgov), 1, usdgAsset, 1_000e6);
    }

    /// @notice Settle with a RELEASED approver still in the list. The loop must
    ///         skip zero-reservation entries without letting one become the
    ///         residue holder, or the dust would be credited to somebody who
    ///         underwrote nothing.
    function test_settleCoverage_skipsReleasedApprovers() public {
        _wireRecording();
        address g2 = makeAddr("g2");
        address g3 = makeAddr("g3");
        swood.setStake(g2, 100_000e18, 0); // $5,000 -> reserves the full 1,000
        // Deliberately UNEQUAL so the pro-rata split does not divide evenly and
        // the residue path is actually exercised. With equal bonds this test
        // passes with the residue top-up deleted, which makes it worthless as
        // cover for that branch.
        swood.setStake(g3, 10_000e18, 0); // $500 -> reserves only 500
        mgov.set(1_000e6);
        mgov.setSchedule(block.timestamp + 1 days, 3 days);

        vm.startPrank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);
        ledger.recordApproval(address(mgov), 1, g2);
        ledger.recordApproval(address(mgov), 1, g3);
        // The FIRST-listed approver leaves, so the swap-and-pop moves an element
        // and the residue holder is no longer the one the loop started with.
        ledger.releaseApproval(address(mgov), 1, guardian);
        vm.stopPrank();

        skip(31 days);
        ledger.settleCoverage(address(mgov), 1);

        assertEq(ledger.allocatedUsd(address(mgov), 1, guardian), 0, "a departed approver carries nothing");
        uint256 total = ledger.allocatedUsd(address(mgov), 1, g2) + ledger.allocatedUsd(address(mgov), 1, g3);
        assertEq(total, 1_000e18, "the survivors carry all of it, residue included");
        ledger.requireApproveQuorum(address(mgov), 1, usdgAsset, 1_000e6);
    }

    // ── WOOD price: Chainlink feed with a governance fallback ─────────────

    /// @notice Once a feed is wired it supersedes the governance number, and
    ///         the haircut is applied on top — collateral wants a floor, not a
    ///         quote. An unhaircut oracle tracks WOOD UP and inflates every
    ///         bond exactly when the market is frothy, which is what the old
    ///         manually-maintained "<= 30-day low" existed to prevent.
    function test_woodPrice_feedSupersedesGovernanceAndAppliesTheHaircut() public {
        assertEq(ledger.woodPriceX8(), 0.05e8, "governance value while unwired");

        MockFeed woodFeed = new MockFeed(0.08e8, 8); // market says $0.08
        vm.startPrank(owner);
        ledger.setWoodFeed(address(woodFeed), 1 days);
        assertEq(ledger.woodPriceX8(), 0.08e8, "feed wins, no haircut by default");

        ledger.setWoodHaircutBps(7_500); // value bonds at 75% of market
        vm.stopPrank();
        assertEq(ledger.woodPriceX8(), 0.06e8, "haircut applied to the live read");

        // And it flows through to what a bond is worth.
        swood.setStake(guardian, 100_000e18, 0);
        assertEq(ledger.slashableBondUsd(guardian), 6_000e18, "100k WOOD at the haircut price");
    }

    /// @notice A crash is tracked IMMEDIATELY, which is the direction where lag
    ///         hurts: under the manual number somebody has to notice and
    ///         transact while bonds stay over-valued in the meantime.
    function test_woodPrice_tracksACrashWithoutAGovernanceTransaction() public {
        MockFeed woodFeed = new MockFeed(0.05e8, 8);
        vm.prank(owner);
        ledger.setWoodFeed(address(woodFeed), 1 days);
        swood.setStake(guardian, 100_000e18, 0);
        assertEq(ledger.slashableBondUsd(guardian), 5_000e18);

        woodFeed.set(0.005e8); // 10x collapse, no owner action
        assertEq(ledger.slashableBondUsd(guardian), 500e18, "bond revalued with no transaction");
    }

    /// @notice A stale or broken feed FALLS BACK rather than reverting. Failing
    ///         closed would value every bond at $0 and halt approvals
    ///         protocol-wide on a Chainlink hiccup — a liveness risk the manual
    ///         price does not have. The fallback is itself a conservative floor,
    ///         so the degraded path stays safe; the cost is that the governance
    ///         number must be MAINTAINED, not abandoned once the feed is wired.
    function test_woodPrice_fallsBackToGovernanceWhenTheFeedIsStale() public {
        MockFeed woodFeed = new MockFeed(0.08e8, 8);
        vm.prank(owner);
        ledger.setWoodFeed(address(woodFeed), 1 hours);

        assertEq(ledger.woodPriceX8(), 0.08e8, "fresh: feed");
        skip(2 hours);
        assertEq(ledger.woodPriceX8(), 0.05e8, "stale: governance fallback, not zero");

        swood.setStake(guardian, 100_000e18, 0);
        assertEq(ledger.slashableBondUsd(guardian), 5_000e18, "bonds still valued, approvals still possible");
    }

    /// @notice The haircut is bounded on both sides. Zero would value bonds at
    ///         $0 and brick approvals; above 100% would value them ABOVE market,
    ///         which is the direction that overstates coverage.
    function test_setWoodHaircutBps_bounded() public {
        vm.startPrank(owner);
        vm.expectRevert(IExposureLedger.InvalidParameter.selector);
        ledger.setWoodHaircutBps(0);
        vm.expectRevert(IExposureLedger.InvalidParameter.selector);
        ledger.setWoodHaircutBps(10_001);
        ledger.setWoodHaircutBps(10_000);
        vm.stopPrank();
        assertEq(ledger.woodHaircutBps(), 10_000);
    }

    /// @notice n1 — a guardian who can no longer pay must not dilute the
    ///         survivors' shares. Using the raw pledged total as the denominator
    ///         computed everyone's slice against a bond that had gone, so the
    ///         recoverable total fell short of the loss by far more than
    ///         rounding.
    function test_allocatedUsd_excludesBondThatIsNoLongerThere() public {
        _wireRecording();
        address g2 = makeAddr("g2");
        swood.setStake(g2, 100_000e18, 0);
        mgov.set(1_000e6);
        mgov.setSchedule(block.timestamp + 1 days, 3 days);

        vm.startPrank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);
        ledger.recordApproval(address(mgov), 1, g2);
        vm.stopPrank();
        assertEq(ledger.allocatedUsd(address(mgov), 1, guardian), 500e18, "even split while both can pay");

        // One bond is devalued to a quarter of what it pledged.
        swood.setStake(guardian, 5_000e18, 0); // $250 of a $1,000 reservation

        // The split is pro-rata over EFFECTIVE capacity, not a simple cap:
        // effective total is 250 + 1000 = 1250, so the shares are 250/1250 and
        // 1000/1250 of the $1,000 needed.
        assertEq(ledger.allocatedUsd(address(mgov), 1, guardian), 200e18, "sized by what it can still pay");
        assertEq(ledger.allocatedUsd(address(mgov), 1, g2), 800e18, "survivor absorbs the shortfall");
        // Still fully covered -- which is the point. Before n1 the devalued
        // guardian kept a 500 slice it could not honour and $250 was unbacked.
        ledger.requireApproveQuorum(address(mgov), 1, usdgAsset, 1_000e6);
    }

    /// @notice FINDING 1 — the haircut must apply to the FALLBACK as well.
    ///
    ///         While `woodHaircutBps` defaults to `BPS_DENOMINATOR` both paths
    ///         agree and nothing is visibly wrong, which is why the existing
    ///         tests passed either way. The inconsistency only appears once
    ///         governance turns the haircut on: the healthy path valued bonds at
    ///         0.8x spot while every degraded path returned the manual number
    ///         raw — so enabling the safety feature made the fallback LESS
    ///         conservative than the primary, in exactly the state where more
    ///         margin is wanted.
    function test_woodPrice_haircutAppliesToTheFallbackToo() public {
        MockFeed woodFeed = new MockFeed(0.05e8, 8);
        vm.startPrank(owner);
        ledger.setWoodFeed(address(woodFeed), 1 hours);
        ledger.setWoodHaircutBps(8_000); // 20% haircut
        vm.stopPrank();

        assertEq(ledger.woodPriceX8(), 0.04e8, "healthy path: 0.8x spot");

        skip(2 hours); // feed goes stale -> fallback
        assertEq(ledger.woodPriceX8(), 0.04e8, "fallback: 0.8x the manual number, NOT raw 0.05e8");

        // And it flows through to bond valuation, which is what the looser
        // batching cap would have come from.
        swood.setStake(guardian, 100_000e18, 0);
        assertEq(ledger.slashableBondUsd(guardian), 4_000e18, "not the 5_000 an unhaircut fallback would give");
    }

    /// @notice FINDING 2 — the degraded path must be observable. Without this,
    ///         "feed healthy" and "feed dead for months, running on a manual
    ///         number nobody has touched" are indistinguishable from outside,
    ///         and monitoring cannot alert on a condition it cannot see.
    function test_woodPriceDetail_reportsWhenRunningOnTheFallback() public {
        (, bool fellBack) = ledger.woodPriceDetail();
        assertTrue(fellBack, "no feed wired -> fallback");

        MockFeed woodFeed = new MockFeed(0.05e8, 8);
        vm.prank(owner);
        ledger.setWoodFeed(address(woodFeed), 1 hours);
        (, fellBack) = ledger.woodPriceDetail();
        assertFalse(fellBack, "fresh feed -> primary");

        skip(2 hours);
        (, fellBack) = ledger.woodPriceDetail();
        assertTrue(fellBack, "stale feed -> fallback, and now visible");

        woodFeed.set(0.05e8); // fresh again
        (, fellBack) = ledger.woodPriceDetail();
        assertFalse(fellBack, "recovered");
    }

    /// @notice N11 — the propose-time horizon gate was fed `p.executeBy`, which
    ///         is still ZERO on the collaborative Draft path, making the check
    ///         `strategyDuration > block.timestamp`: unsatisfiable on any real
    ///         chain, so the gate silently could not fire for co-proposed
    ///         strategies.
    ///
    ///         `vm.warp` to real chain time is load-bearing here. Foundry starts
    ///         at `t = 1`, where `duration > 1` is trivially true and the bug is
    ///         invisible — which is exactly why the first version of this test
    ///         passed against broken code.
    function test_requireWithinCoverageHorizon_zeroDeadlineIsNotAFreePass() public {
        vm.warp(1_800_000_000); // ~2027, i.e. a real chain

        // The raw-field call the governor used to make. At `executeBy == 0` this
        // is `3650 days > now + 60 days` -> false, so it does NOT revert: the
        // gate is vacuous, which is the whole finding.
        ledger.requireWithinCoverageHorizon(0, 3650 days);

        // With a real deadline the same duration is refused.
        vm.expectRevert(IExposureLedger.CoverageHorizonExceeded.selector);
        ledger.requireWithinCoverageHorizon(block.timestamp + 1 days, 3650 days);

        // ...and an in-horizon duration still passes.
        ledger.requireWithinCoverageHorizon(block.timestamp + 1 days, 30 days);
    }

    /// @notice C1 REGRESSION — the free-rider veto.
    ///
    ///         Under first-come booking an attacker could approve first and
    ///         absorb the ENTIRE coverage, leaving an honest approver with a
    ///         zero commitment and — worse — off the ledger's approver list
    ///         entirely. Flipping to Block then released the whole commitment,
    ///         while the registry's late-vote lockout stopped the free-ridden
    ///         approver from re-registering: a permanent, costless veto by a
    ///         guardian holding less than block quorum.
    ///
    ///         With per-approver reservations there is nothing to squat. The
    ///         honest approver reserves its own budget regardless of who voted
    ///         first, and the attacker's departure scales the survivor UP.
    function test_recordApproval_frontRunnerCannotVetoByReleasing() public {
        _wireRecording();
        address attacker = makeAddr("attacker");
        swood.setStake(attacker, 100_000e18, 0); // $5,000
        mgov.set(4_000e6); // $4,000 needed — either could cover it alone

        // The attacker gets in first and would, under the old rule, absorb it all.
        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, attacker);

        // The honest approver still books its own reservation.
        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);
        assertEq(ledger.openExposureUsd(guardian), 4_000e18, "not free-ridden into a zero commitment");

        // The attacker flips to Block, releasing everything it reserved.
        vm.prank(registry);
        ledger.releaseApproval(address(mgov), 1, attacker);
        assertEq(ledger.openExposureUsd(attacker), 0, "attacker pays nothing and walks");

        // The survivor absorbs the whole proposal rather than the veto landing.
        assertEq(ledger.allocatedUsd(address(mgov), 1, guardian), 4_000e18, "scaled UP to the full coverage");
        assertEq(ledger.allocatedUsd(address(mgov), 1, attacker), 0, "a released approver carries nothing");

        // ...and the proposal stays executable, which is exactly what C1 broke.
        ledger.requireApproveQuorum(address(mgov), 1, usdgAsset, 4_000e6);
    }

    function test_recordApproval_netsAcrossSequentialEpochs() public {
        _wireRecording();
        mgov.set(4_000e6);
        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);
        // same guardian, next epoch + challenge window fully elapsed: budget recycled
        vm.warp(block.timestamp + 28 days + 14 days + 1);
        vm.prank(registry);
        ledger.recordApproval(address(mgov), 2, guardian); // would exceed the cap if netted with #1
        assertEq(ledger.openExposureUsd(guardian), 4_000e18); // only the live epoch counts
    }

    /// @notice The batching attack (spec §3.3): one guardian cannot back two
    ///         simultaneous drains with the same bond. Its committed exposure
    ///         is capped at its bond in TOTAL across open approvals, so the
    ///         second proposal is left short and cannot reach quorum.
    function test_recordApproval_blocksSimultaneousOverExposure() public {
        _wireRecording();
        mgov.set(3_000e6);
        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);
        assertEq(ledger.openExposureUsd(guardian), 3_000e18);

        // Second $3,000 drain: only $2,000 of budget remains, so that is all it
        // can back — total exposure is pinned at the $5,000 bond, never $6,000.
        vm.prank(registry);
        ledger.recordApproval(address(mgov), 2, guardian);
        assertEq(ledger.openExposureUsd(guardian), 5_000e18, "total exposure capped at the bond");

        // Proposal 1 stays covered; proposal 2 is under-covered and cannot execute.
        ledger.requireApproveQuorum(address(mgov), 1, usdgAsset, 3_000e6);
        vm.expectRevert(IExposureLedger.InsufficientApproveCoverage.selector);
        ledger.requireApproveQuorum(address(mgov), 2, usdgAsset, 3_000e6);
    }

    /// @notice The hard edge of the batching cap: with NO free budget left, an
    ///         approve reverts outright rather than committing zero.
    /// @notice N1 — a spent budget books NOTHING; it does not revert. Reverting
    ///         took `voteOnProposal` down with it, so a guardian whose budget
    ///         went on an earlier proposal could not cast an approve vote at
    ///         all — approve-side silence while Block still worked.
    ///
    ///         The cap still binds: nothing is committed, so the same bond
    ///         cannot back two drains. Enforcement moves to the execute-time
    ///         quorum, which is already the enforcement point.
    function test_recordApproval_noFreeBudgetBooksNothingWithoutReverting() public {
        _wireRecording();
        mgov.set(5_000e6); // consumes the entire $5,000 bond
        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);
        assertEq(ledger.openExposureUsd(guardian), 5_000e18);

        vm.prank(registry);
        ledger.recordApproval(address(mgov), 2, guardian); // must not revert

        // Nothing extra booked -- the cap is intact.
        assertEq(ledger.openExposureUsd(guardian), 5_000e18, "no second drain backed by the same bond");
        assertEq(ledger.allocatedUsd(address(mgov), 2, guardian), 0, "carries nothing on the second proposal");
    }

    function test_releaseApproval_freesExactRecordedAmount() public {
        _wireRecording();
        mgov.set(3_000e6);
        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);
        vm.prank(registry);
        ledger.releaseApproval(address(mgov), 1, guardian);
        assertEq(ledger.openExposureUsd(guardian), 0);
    }

    function test_releaseApproval_idempotentNoUnderflow() public {
        _wireRecording();
        vm.prank(registry);
        ledger.releaseApproval(address(mgov), 99, guardian); // never recorded: no-op
        assertEq(ledger.openExposureUsd(guardian), 0);
    }

    /// Fuzz the stated invariant: any record/release interleaving leaves
    /// openExposureUsd == sum recorded-minus-released in unexpired buckets.
    function testFuzz_exposureAccountingConserved(uint96 c1, uint96 c2, bool releaseFirst) public {
        _wireRecording();
        // uint96-max stake alone puts the bond ~3 orders of magnitude above
        // any coverage this fuzz generates, so the cap never binds. The old
        // 20x price raise on top of that was redundant, and now trips the
        // upward rate limit on `setWoodUsdPrice`.
        swood.setStake(guardian, type(uint96).max, 0);
        uint256 u1 = uint256(c1) % 1_000_000e6 + 1;
        uint256 u2 = uint256(c2) % 1_000_000e6 + 1;
        mgov.set(u1);
        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);
        mgov.set(u2);
        vm.prank(registry);
        ledger.recordApproval(address(mgov), 2, guardian);
        if (releaseFirst) {
            vm.prank(registry);
            ledger.releaseApproval(address(mgov), 1, guardian);
            assertEq(ledger.openExposureUsd(guardian), u2 * 1e12); // 6-dec asset at $1 → USD-18
        } else {
            vm.prank(registry);
            ledger.releaseApproval(address(mgov), 2, guardian);
            assertEq(ledger.openExposureUsd(guardian), u1 * 1e12);
        }
    }

    function test_coveredTvlCap_enforced() public {
        _wireRecording();
        vm.prank(owner);
        ledger.setCoveredTvlCapUsd(2_000e18);
        ledger.requireWithinCoveredTvlCap(usdgAsset, 1_500e6); // $1,500 <= $2,000: fine
        vm.expectRevert(IExposureLedger.CoveredTvlCapExceeded.selector);
        ledger.requireWithinCoveredTvlCap(usdgAsset, 2_500e6);
    }

    function test_coveredTvlCap_zeroCapFailsClosed() public {
        _wireRecording(); // cap never set => 0
        vm.expectRevert(IExposureLedger.CoveredTvlCapExceeded.selector);
        ledger.requireWithinCoveredTvlCap(usdgAsset, 1e6);
    }

    /// @notice The quorum sums COMMITTED shares from the ledger's own approver
    ///         list — it no longer asks a registry who approved, so the ledger's
    ///         and the governor's registry pointers cannot disagree (I-1).
    function test_approveQuorum_sumOfCommittedSharesCoversCoverage() public {
        _wireRecording();
        address g2 = makeAddr("g2");
        swood.setStake(guardian, 60_000e18, 0); // $3,000
        swood.setStake(g2, 60_000e18, 0); // $3,000
        mgov.set(5_000e6); // $5,000 needed

        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian); // commits $3,000
        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, g2); // commits the $2,000 remainder

        // $3,000 + $2,000 == $5,000 → covered.
        ledger.requireApproveQuorum(address(mgov), 1, usdgAsset, 5_000e6);
        // Asking for more than was ever committed fails.
        vm.expectRevert(IExposureLedger.InsufficientApproveCoverage.selector);
        ledger.requireApproveQuorum(address(mgov), 1, usdgAsset, 7_000e6);
    }

    /// @notice The LIVE leg of the quorum (F2): a committed share counts only at
    ///         what the bond behind it is worth NOW, so a WOOD price crash
    ///         between approve and execute un-covers the proposal.
    function test_approveQuorum_priceCrashShrinksCommittedShare() public {
        _wireRecording();
        mgov.set(5_000e6);
        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian); // commits its full $5,000
        ledger.requireApproveQuorum(address(mgov), 1, usdgAsset, 5_000e6); // covered at $0.05

        vm.prank(owner);
        // `setWoodUsdPrice` is rate-limited (review M4) and `setUp` already set
        // one, so a second update waits out the interval.
        skip(1 days);
        ledger.setWoodUsdPrice(0.005e8); // 10x crash — bond now worth $500
        vm.expectRevert(IExposureLedger.InsufficientApproveCoverage.selector);
        ledger.requireApproveQuorum(address(mgov), 1, usdgAsset, 5_000e6);
    }

    /// @notice A vote change releases the commitment, so the proposal loses the
    ///         coverage it had — the quorum reflects it immediately.
    function test_approveQuorum_releaseRemovesCoverage() public {
        _wireRecording();
        mgov.set(3_000e6);
        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);
        ledger.requireApproveQuorum(address(mgov), 1, usdgAsset, 3_000e6);

        vm.prank(registry);
        ledger.releaseApproval(address(mgov), 1, guardian);
        vm.expectRevert(IExposureLedger.InsufficientApproveCoverage.selector);
        ledger.requireApproveQuorum(address(mgov), 1, usdgAsset, 3_000e6);
    }

    function test_approveQuorum_zeroApproversFailsClosed() public {
        _wireRecording();
        MockRegistryForLedger mockReg = new MockRegistryForLedger();
        vm.prank(owner);
        ledger.setGuardianRegistry(address(mockReg));
        // spec §3.3a cold-start: no covering signer => coverage-consuming proposal
        // cannot execute — it expires instead of executing unreviewed.
        vm.expectRevert(IExposureLedger.InsufficientApproveCoverage.selector);
        ledger.requireApproveQuorum(address(mgov), 1, usdgAsset, 1e6);
    }

    /// @notice What bounds the window now: zero (frees coverage instantly), the
    ///         M1 floor, and `MAX_SCAN_BUCKETS`. The cooldown invariant is gone
    ///         — unsatisfiable against sWOOD's 30-day setter cap, and superseded
    ///         by the exit gate on `claimUnstakeGuardian`. A window longer than
    ///         the epoch is now legal, which it had to become for narrow buckets
    ///         to be usable at all.
    function test_setChallengeWindow_bounds() public {
        vm.startPrank(owner);
        vm.expectRevert(IExposureLedger.InvalidParameter.selector);
        ledger.setChallengeWindow(0);

        // Longer than the epoch: rejected before, fine now.
        ledger.setChallengeWindow(28 days + 1);
        assertEq(ledger.challengeWindow(), 28 days + 1);

        // 18d used to fail on the cooldown (28 + 18 = 46 > 45). It passes now.
        ledger.setChallengeWindow(18 days);
        assertEq(ledger.challengeWindow(), 18 days);

        ledger.setChallengeWindow(7 days);
        vm.stopPrank();
        assertEq(ledger.challengeWindow(), 7 days);
    }

    function test_openExposure_exactExpiryBoundary() public {
        _wireRecording();
        uint256 genesis = block.timestamp; // no warp since deploy
        mgov.set(1_000e6);
        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);
        // bucket 0 stays open until exactly genesis + epochLength + challengeWindow
        vm.warp(genesis + 28 days + 14 days - 1);
        assertEq(ledger.openExposureUsd(guardian), 1_000e18);
        vm.warp(genesis + 28 days + 14 days);
        assertEq(ledger.openExposureUsd(guardian), 0);
    }

    function test_openExposure_carriesIntoNextEpochWithinWindow() public {
        _wireRecording();
        mgov.set(3_000e6);
        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);
        // into epoch 1, but epoch 0's challenge window (open until 28d + 14d) has not elapsed
        vm.warp(block.timestamp + 28 days + 1);
        assertEq(ledger.openExposureUsd(guardian), 3_000e18);
        // The carried exposure still consumes budget: a second $3k approval can
        // only commit the $2k that remains, pinning the total at the bond.
        vm.prank(registry);
        ledger.recordApproval(address(mgov), 2, guardian);
        assertEq(ledger.openExposureUsd(guardian), 5_000e18, "epoch-0 exposure still counts against the cap");
    }

    /// @notice `W <= L` is GONE. It was never a correctness rule — it was a
    ///         proxy for keeping `openExposureUsd`'s walk short, and as a proxy
    ///         it pinned buckets at >= 14 days. Narrow buckets are now the point:
    ///         they let a guardian's short commitments expire without waiting on
    ///         their long ones. What replaces it is a direct bound on the walk.
    function test_constructor_allowsBucketsNarrowerThanTheChallengeWindow() public {
        // 10d buckets under a 14d window: rejected before, fine now.
        ExposureLedger narrow = new ExposureLedger(owner, address(swood), 10 days);
        assertEq(narrow.epochLength(), 10 days);

        // ...and 7d, the width that actually motivates this.
        ExposureLedger sevenDay = new ExposureLedger(owner, address(swood), 7 days);
        assertEq(sevenDay.epochLength(), 7 days);
    }

    function test_constructor_enforcesDefaultWindowInvariants() public {
        // A 40d epoch used to fail the cooldown invariant (40 + 14 = 54 > 45).
        // That invariant is gone, so this is now a legal ledger.
        ExposureLedger wide = new ExposureLedger(owner, address(swood), 40 days);
        assertEq(wide.epochLength(), 40 days);

        // What still binds: buckets so narrow the walk would exceed
        // MAX_SCAN_BUCKETS — (14d + 60d) / 4d + 2 = 20 > 16.
        vm.expectRevert(IExposureLedger.InvalidParameter.selector);
        new ExposureLedger(owner, address(swood), 4 days);
    }

    /// @notice Narrow buckets are what buy independent release: a 7-day and a
    ///         30-day commitment land in DIFFERENT buckets, so the short one
    ///         frees up while the long one is still held. Under 28-day buckets
    ///         they would share one and expire together.
    function test_openExposure_shortCommitmentReleasesBeforeTheLongOne() public {
        ExposureLedger led = new ExposureLedger(owner, address(swood), 7 days);
        usdgAsset = makeAddr("usdgAssetSplit");
        vm.mockCall(usdgAsset, abi.encodeWithSignature("decimals()"), abi.encode(uint8(6)));
        MockFeed feed = new MockFeed(1e8, 8);
        MockVaultForLedger vault = new MockVaultForLedger(usdgAsset);
        MockGovernorForLedger shortGov = new MockGovernorForLedger(address(vault));
        MockGovernorForLedger longGov = new MockGovernorForLedger(address(vault));
        vm.startPrank(owner);
        led.setAssetFeed(usdgAsset, address(feed), 365 days);
        led.setGuardianRegistry(registry);
        led.setWoodUsdPrice(0.05e8);
        vm.stopPrank();
        swood.setStake(guardian, 400_000e18, 0); // $20,000 budget

        shortGov.setSchedule(block.timestamp + 1 days, 3 days); // settles ~4d out
        shortGov.set(1_000e6);
        longGov.setSchedule(block.timestamp + 1 days, 30 days); // settles ~31d out
        longGov.set(2_000e6);

        vm.startPrank(registry);
        led.recordApproval(address(shortGov), 1, guardian);
        led.recordApproval(address(longGov), 1, guardian);
        vm.stopPrank();
        assertEq(led.openExposureUsd(guardian), 3_000e18, "both held");

        // Past the short one's bucket + challenge window, well short of the long
        // one's. The short commitment is gone; the long one is untouched.
        vm.warp(block.timestamp + 7 days + 14 days + 1);
        assertEq(led.openExposureUsd(guardian), 2_000e18, "short released, long still held");
    }

    function test_kNumerator_doublesHeadroom() public {
        _wireRecording();
        vm.prank(owner);
        ledger.setKNumerator(2);
        mgov.set(9_000e6); // $9,000 > $5,000 bond but <= 2 x $5,000
        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);
        assertEq(ledger.openExposureUsd(guardian), 9_000e18);
    }

    function test_recordApproval_uint192OverflowGuardReverts() public {
        _wireRecording();
        // The committed share is min(free budget, still needed), so BOTH must
        // exceed uint192 to reach the guard. Absurd feed price →
        // needUsd = 1e25 * 1e30 * 1e18 / 1e14 = 1e59; absurd stake →
        // free = 1e60 * 5e6 / 1e8 = 5e58. min == 5e58 > type(uint192).max (~6.28e57).
        MockFeed hugeFeed = new MockFeed(1e30, 8);
        vm.prank(owner);
        ledger.setAssetFeed(usdgAsset, address(hugeFeed), 365 days);
        swood.setStake(guardian, 1e60, 0);
        mgov.set(1e25);
        vm.prank(registry);
        vm.expectRevert(IExposureLedger.InvalidParameter.selector);
        ledger.recordApproval(address(mgov), 1, guardian);
    }

    function test_approversOf_listsCommittedApprovers() public {
        _wireRecording();
        address g2 = makeAddr("g2");
        swood.setStake(g2, 100_000e18, 0);
        mgov.set(8_000e6);
        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);
        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, g2);

        (address[] memory gs, uint256[] memory shares) = ledger.approversOf(address(mgov), 1);
        assertEq(gs.length, 2);
        assertEq(gs[0], guardian);
        assertEq(gs[1], g2);
        // RESERVATION, NOT ALLOCATION: each approver books min(free budget,
        // whole coverage) — the most it could ever carry — and the final
        // pro-rata split is computed at read time by `allocatedUsd`.
        assertEq(shares[0], 5_000e18); // its whole budget
        assertEq(shares[1], 5_000e18); // its whole budget too, not the remainder
    }

    /// @notice #22's M2 fix swap-and-pops a released approver out of the list
    ///         rather than leaving it behind with a zeroed commitment, so it is
    ///         no longer returned at all — a released approver contributes
    ///         NOTHING to a conviction, and the list stays bounded by the
    ///         registry's approver cap instead of by everyone who EVER approved.
    function test_approversOf_dropsReleasedApprovers() public {
        _wireRecording();
        mgov.set(3_000e6);
        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);
        vm.prank(registry);
        ledger.releaseApproval(address(mgov), 1, guardian);
        (address[] memory gs, uint256[] memory shares) = ledger.approversOf(address(mgov), 1);
        assertEq(gs.length, 0, "released approver is popped, not zeroed");
        assertEq(shares.length, 0);
    }

    /// @notice `slashBpsFor` converts each guardian's BOOKED coverage into the
    ///         bps-of-stake that `slashToEscrow` speaks. Both inputs are USD, so
    ///         the quotient is DIMENSIONALLY unitless — but both operands are
    ///         priced (🟡N5): asset feed in the numerator, `woodPriceX8()` in
    ///         the denominator. Here the two approvers underwrote different
    ///         amounts of the same proposal, so they must carry different rates.
    function test_slashBpsFor_ratesTrackEachApproversOwnCommitment() public {
        _wireRecording();
        address g2 = makeAddr("g2");
        swood.setStake(g2, 50_000e18, 0); // $2,500 bond vs the guardian's $5,000
        mgov.set(2_000e6); // $2,000 needed — either could carry it alone

        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);
        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, g2);

        // Both reservations are capped by the COVERAGE ($2,000), not by budget,
        // so the pro-rata split is even: $1,000 of liability each.
        assertEq(ledger.allocatedUsd(address(mgov), 1, guardian), 1_000e18);
        assertEq(ledger.allocatedUsd(address(mgov), 1, g2), 1_000e18);

        (address[] memory approvers, uint256[] memory bps) = ledger.slashBpsFor(address(mgov), 1);

        assertEq(approvers.length, 2, "both approvers listed");
        assertEq(approvers[0], guardian);
        assertEq(approvers[1], g2);
        // Equal liability, unequal bonds -> unequal RATES. $1,000 is a fifth of
        // the guardian's $5,000 but two fifths of g2's $2,500, and the rate is
        // what `slashToEscrow` applies to each one's own stake.
        assertEq(bps[0], 2_000, "a fifth of the larger bond");
        assertEq(bps[1], 4_000, "two fifths of the smaller one");
    }

    /// @notice PR #24 review F-B: `slashBpsFor` must price the bond with
    ///         `woodPriceX8()` — the same Chainlink-with-haircut read every
    ///         other consumer uses — not the raw governance scalar. A merge
    ///         artefact had it on `woodUsdPriceX8`, so the moment a WOOD feed
    ///         was wired the gate and the slash rail priced the same bond
    ///         differently: a feed above the scalar over-slashed 2x, a haircut
    ///         under-recovered by half.
    function test_slashBpsFor_pricesBondsWithTheFeedNotTheRawScalar() public {
        _wireRecording();
        address g2 = makeAddr("g2");
        swood.setStake(g2, 50_000e18, 0);
        mgov.set(2_000e6);

        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);
        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, g2);

        // Baseline (governance scalar $0.05): $5,000 / $2,500 bonds, $1,000
        // liability each -> 2,000 / 4,000 bps.
        (, uint256[] memory bpsBefore) = ledger.slashBpsFor(address(mgov), 1);
        assertEq(bpsBefore[0], 2_000);
        assertEq(bpsBefore[1], 4_000);

        // Wire a feed at 2x the scalar. `woodPriceX8()` now reads $0.10, the
        // bonds are worth twice as much, and the SAME dollar liability is half
        // the rate. Reading the raw scalar would leave the rates unchanged —
        // taking twice the liability from every approver.
        MockFeed woodFeed = new MockFeed(0.1e8, 8);
        vm.prank(owner);
        ledger.setWoodFeed(address(woodFeed), 1 days);
        assertEq(ledger.woodPriceX8(), 0.1e8, "feed supersedes the scalar");

        (, uint256[] memory bpsAfter) = ledger.slashBpsFor(address(mgov), 1);
        assertEq(bpsAfter[0], 1_000, "rate tracks the feed-priced bond");
        assertEq(bpsAfter[1], 2_000, "rate tracks the feed-priced bond");
    }

    /// @notice A guardian whose commitment was RELEASED by a vote change stays
    ///         in the approver list with a zeroed booking. It must price at 0 —
    ///         liability follows the commitment, and `slashToEscrow` skips a
    ///         zero rate rather than flooring it to `minSlashBps`.
    function test_slashBpsFor_zeroForAnApproverThatBookedNothing() public {
        _wireRecording();
        mgov.set(1_000e6);

        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);
        vm.prank(registry);
        ledger.releaseApproval(address(mgov), 1, guardian);

        // #22's M2 fix swap-and-pops a released approver out of the list rather
        // than leaving it behind with a zeroed commitment, so it is no longer
        // returned at all. The property this test exists for is unchanged and
        // arguably stated better: a released approver contributes NOTHING to a
        // conviction. Previously that was "present with a 0 rate"; it is now
        // "absent", and `slashToEscrow` cannot slash whom it is not given.
        (address[] memory approvers, uint256[] memory bps) = ledger.slashBpsFor(address(mgov), 1);
        assertEq(approvers.length, 0, "released approver is popped, not zeroed");
        assertEq(bps.length, 0);

        // Re-approving re-lists cleanly, with a real rate.
        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);
        (approvers, bps) = ledger.slashBpsFor(address(mgov), 1);
        assertEq(approvers.length, 1, "re-listed");
        assertEq(approvers[0], guardian);
        assertGt(bps[0], 0, "and carries a real rate again");
    }

    /// @notice Rounds UP. Truncation would shave every approver's rate and the
    ///         residue compounds across a cohort, quietly breaking
    ///         `sum(slashed) >= loss`. $1,000 booked against a $3,000 bond is
    ///         3333.33 bps, which must price at 3334 rather than 3333.
    function test_slashBpsFor_roundsUpSoTheCohortNeverUnderCovers() public {
        _wireRecording();
        swood.setStake(guardian, 60_000e18, 0); // $3,000 bond at $0.05
        mgov.set(1_000e6); // books exactly $1,000

        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);

        (, uint256[] memory bps) = ledger.slashBpsFor(address(mgov), 1);
        assertEq(bps[0], 3334, "3333.33 bps rounds toward the protocol");
    }

    /// @notice When the bond SHRANK below the commitment after the vote —
    ///         unstaking, or a WOOD price crash — the rate saturates at 100%.
    ///         The case under-recovers by the shortfall, which is unavoidable:
    ///         the guardian no longer has it.
    function test_slashBpsFor_saturatesWhenTheBondShrankBelowTheCommitment() public {
        _wireRecording();
        mgov.set(5_000e6); // books the full $5,000 bond

        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);

        swood.setStake(guardian, 50_000e18, 0); // bond halves to $2,500

        (, uint256[] memory bps) = ledger.slashBpsFor(address(mgov), 1);
        assertEq(bps[0], 10_000, "capped at everything the guardian still has");
    }

    function test_freeze_onlyFreezer() public {
        _wireRecording();
        vm.expectRevert(IExposureLedger.NotCoverageFreezer.selector);
        ledger.freezeCoverage(address(mgov), 1);
    }

    /// @notice §3.4: a live challenge pins the proposal's coverage. The guardian
    ///         cannot vote-change out of it and recycle the budget elsewhere while
    ///         it is under challenge.
    function test_freeze_blocksRelease() public {
        _wireRecording();
        mgov.set(3_000e6);
        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);

        vm.prank(freezer);
        ledger.freezeCoverage(address(mgov), 1);

        vm.prank(registry);
        vm.expectRevert(IExposureLedger.CoverageFrozen.selector);
        ledger.releaseApproval(address(mgov), 1, guardian);
        assertEq(ledger.openExposureUsd(guardian), 3_000e18, "still committed");
    }

    function test_unfreeze_restoresRelease() public {
        _wireRecording();
        mgov.set(3_000e6);
        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);
        vm.prank(freezer);
        ledger.freezeCoverage(address(mgov), 1);
        vm.prank(freezer);
        ledger.unfreezeCoverage(address(mgov), 1);
        vm.prank(registry);
        ledger.releaseApproval(address(mgov), 1, guardian);
        assertEq(ledger.openExposureUsd(guardian), 0);
    }

    /// @notice The freeze is per-proposal, NOT whole-stake (§3.4 freeze scope):
    ///         the guardian's other open approvals are untouched.
    function test_freeze_doesNotTouchOtherApprovals() public {
        _wireRecording();
        swood.setStake(guardian, 200_000e18, 0); // $10,000 of budget
        mgov.set(3_000e6);
        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);
        vm.prank(registry);
        ledger.recordApproval(address(mgov), 2, guardian);

        vm.prank(freezer);
        ledger.freezeCoverage(address(mgov), 1);

        // Proposal 2's commitment still releases normally.
        vm.prank(registry);
        ledger.releaseApproval(address(mgov), 2, guardian);
        assertEq(ledger.openExposureUsd(guardian), 3_000e18, "only the frozen one remains");
    }
}
