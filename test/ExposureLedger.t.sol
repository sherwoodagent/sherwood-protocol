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
    function setSchedule(uint256 executeBy_, uint256 duration_) external {
        executeBy = executeBy_;
        strategyDuration = duration_;
    }

    function getProposalView(uint256) external view returns (ProposalViewLite memory v) {
        v.vault = vaultAddr;
        v.executeBy = executeBy;
        v.strategyDuration = strategyDuration;
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

    /// @notice M4 — the price may fall freely but may not more than double in
    ///         one transaction. The directions are not symmetric: upward
    ///         over-values every bond and overstates coverage, downward only
    ///         tightens. Rate-limiting the fall would leave bonds over-valued
    ///         during exactly the crash the price exists to absorb.
    function test_setWoodUsdPrice_boundsTheUpwardMoveOnly() public {
        vm.startPrank(owner);
        ledger.setWoodUsdPrice(0.1e8); // exactly 2x from the 0.05e8 fixture -- allowed
        assertEq(ledger.woodUsdPriceX8(), 0.1e8);

        vm.expectRevert(IExposureLedger.InvalidParameter.selector);
        ledger.setWoodUsdPrice(0.2000001e8); // a hair over 2x -- rejected

        ledger.setWoodUsdPrice(0.001e8); // a 100x collapse -- allowed, conservative
        assertEq(ledger.woodUsdPriceX8(), 0.001e8);
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

    /// @notice A settlement further out than the ledger will book for is
    ///         REFUSED, not clamped. Clamping would silently under-cover the
    ///         tail — reintroducing the bug above in a quieter form. The revert
    ///         surfaces a duration ceiling set out of step with the epoch length.
    function test_recordApproval_refusesASettlementBeyondTheHorizon() public {
        _wireRecording();
        mgov.setSchedule(block.timestamp + 1 days, 365 days); // far past 3 epochs
        mgov.set(1_000e6);

        vm.prank(registry);
        vm.expectRevert(IExposureLedger.CoverageHorizonExceeded.selector);
        ledger.recordApproval(address(mgov), 1, guardian);
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
    function test_recordApproval_noFreeBudgetReverts() public {
        _wireRecording();
        mgov.set(5_000e6); // consumes the entire $5,000 bond
        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);
        assertEq(ledger.openExposureUsd(guardian), 5_000e18);

        vm.prank(registry);
        vm.expectRevert(IExposureLedger.ExposureCapExceeded.selector);
        ledger.recordApproval(address(mgov), 2, guardian);
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
}
