// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ExposureLedger} from "src/ExposureLedger.sol";
import {IExposureLedger} from "src/interfaces/IExposureLedger.sol";
import {
    MockWoodTwapOracle,
    DirtyFlagWoodTwapOracle,
    ShortReturnWoodTwapOracle
} from "test/mocks/MockWoodTwapOracle.sol";

/// @dev Minimal sWOOD stub exposing exactly the reads the ledger consumes.
///      `slashableStakeAt` (issue #35) mirrors `StakedWood`'s own
///      `min(snapshot at anchor, live)` shape with real checkpoint semantics
///      (not just an alias for live stake), so tests can prove a
///      post-execution top-up is excluded from the anchored basis: each
///      `setStake` call snapshots at the CURRENT `block.timestamp`, and
///      `slashableStakeAt(g, anchor)` returns `min(latest snapshot at or
///      before anchor, live)`.
contract MockSwood {
    mapping(address => uint256) public guardianStake;
    uint256 public coolDownPeriod = 45 days;

    struct Checkpoint {
        uint256 ts;
        uint256 amount;
    }

    mapping(address => Checkpoint[]) internal _checkpoints;

    function setStake(address g, uint256 own) external {
        guardianStake[g] = own;
        _checkpoints[g].push(Checkpoint({ts: block.timestamp, amount: own}));
    }

    function slashableStakeAt(address g, uint256 anchor) external view returns (uint256) {
        Checkpoint[] storage cps = _checkpoints[g];
        uint256 snap;
        for (uint256 i = 0; i < cps.length; i++) {
            if (cps[i].ts > anchor) break;
            snap = cps[i].amount;
        }
        uint256 live = guardianStake[g];
        return snap < live ? snap : live;
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

/// @dev A wired-but-data-less Chainlink aggregator: answers `decimals()` (so it
///      can be wired) and then REVERTS on every price read. A fresh proxy with
///      no round published reverts `"No data present"`; a proxy pointed at a
///      dead implementation, a paused feed, or an address that stopped being an
///      aggregator behave the same way. None is one of the three degraded shapes
///      `_woodPrice` originally handled (unset / non-positive / stale).
contract RevertingFeed {
    uint8 public constant decimals = 8;

    function latestRoundData() external pure returns (uint80, int256, uint256, uint256, uint80) {
        revert("No data present");
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
        uint256 executedAt;
    }

    uint256 public executeBy;
    uint256 public strategyDuration;

    /// @dev Left at 0/0 by default, which makes `coverUntil` fall at or before
    ///      epoch genesis so the ledger books into the CURRENT epoch — the
    ///      pre-ADR behaviour every existing test in this file was written
    ///      against. Set them to exercise the settlement-dated bucket.
    uint256 public reviewEnd;

    /// @dev 0 (unexecuted) by default — every existing test in this file that
    ///      never calls this keeps reading the LIVE basis, unchanged (issue
    ///      #35). Set to exercise the execution-anchored basis.
    uint256 public executedAt;

    function setExecutedAt(uint256 executedAt_) external {
        executedAt = executedAt_;
    }

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
        v.executedAt = executedAt;
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
    // ── FIXTURE HAZARD: TWO EARLY EXITS SILENTLY SHRINK A MULTI-APPROVER SET ──
    //
    // Both exits below are correct, deliberate behaviour in `ExposureLedger` and
    // both stay. What they do to a TEST is quieter: a fixture that wires N
    // approvers can end up exercising fewer than N, and still pass. Four tests
    // shipped passing for the wrong reason (repaired in #61), two of them
    // exactly this shape.
    //
    //   1. `requireApproveQuorum` — QUORUM-REACHED BREAK.
    //      The loop returns the moment `haveUsd >= needUsd`, so every approver
    //      after the one that tips the sum is never read. Size a fixture so the
    //      FIRST approver's reservation alone meets the requirement and the
    //      second approver's accounting is not under test at all: break that
    //      path and the assertion still passes.
    //
    //   2. `recordApproval` — NO-FREE-BUDGET RETURN.
    //      A guardian whose `kNumerator * slashableBondUsd` is already spoken
    //      for by its open exposure returns before booking. It books zero, it is
    //      NOT pushed onto `_approversOf`, and nothing reverts to mark it. The
    //      fixture believes it seated N approvers; the ledger holds N-1. Reached
    //      whenever an approver's stake is left at zero, or an earlier proposal
    //      in the same test already consumed its budget.
    //
    // THE SIZING RULE, which defeats both at once: give every approver a
    // bookable budget STRICTLY GREATER THAN ZERO and STRICTLY SMALLER than the
    // proposal's requirement. Then each one books a real non-zero share (exit 2
    // cannot fire), no single reservation can satisfy the quorum on its own
    // (exit 1 cannot fire before the last approver), and every approver is
    // genuinely read.
    //
    // `_wireUnderCoveredApprovers` applies the rule BY CONSTRUCTION, asserts it,
    // and ends on an `approversOf` count check. `_assertApproverSet` is that
    // count check on its own, for fixtures whose sizing is deliberately
    // different — an over-reservation test needs each bond ABOVE the
    // requirement, so it cannot take the rule, but it still wants to know the
    // ledger seated the set it wired.
    //
    // A fixture that WANTS an early exit says so with an
    // `// EARLY-EXIT INTENDED:` comment naming which one and why.

    ExposureLedger internal ledger;
    MockSwood internal swood;
    address internal owner = makeAddr("owner");
    address internal guardian = makeAddr("guardian");
    address internal registry = makeAddr("registry");
    address internal freezer = makeAddr("freezer");
    MockGovernorForLedger internal mgov;
    address internal usdgAsset;

    // ── FIXTURE: THE PRODUCTION CONFIGURATION, CAP ABOVE MARKET ──
    //
    // The 2026-08-01 audit's sharpest finding was about this fixture rather
    // than about the contract: `grep setWoodTwapOracle test/` returned NOTHING,
    // and the price the ledger served was the governance scalar itself — the
    // one configuration in which "the market may only lower the price" is
    // trivially true, because there was no market. Every claim downstream
    // rested on a `min` that no test ever exercised.
    //
    // So the fixture now ships what production ships: a live market source at
    // MARKET_X8, and the cap at CAP_X8 = 2x above it, NON-BINDING. Reads
    // resolve to MARKET_X8, which is the same $0.05 every existing assertion in
    // this file was written against — the numbers did not move, the reason they
    // hold did.
    //
    // A test that wants the cap to bind says so, by lowering it (that is the
    // emergency brake) or by pushing the market above it.
    uint256 internal constant MARKET_X8 = 0.05e8;
    uint256 internal constant CAP_X8 = 0.1e8;

    MockWoodTwapOracle internal twap;

    function setUp() public {
        swood = new MockSwood();
        // epochLength 28d immutable; genesis = deploy timestamp.
        ledger = new ExposureLedger(owner, address(swood), 28 days);
        twap = new MockWoodTwapOracle(MARKET_X8);
        vm.startPrank(owner);
        ledger.setWoodUsdPrice(CAP_X8);
        ledger.setWoodTwapOracle(address(twap));
        vm.stopPrank();
        assertEq(ledger.woodPriceX8(), MARKET_X8, "fixture must price off the market, not the cap");
    }

    function test_slashableBondUsd_ownStakeAtPrice() public {
        // own 100k WOOD (the only slashable capital post delegation-removal)
        swood.setStake(guardian, 100_000e18);
        // slashable WOOD = 100k; at $0.05 => $5,000
        assertEq(ledger.slashableBondUsd(guardian), 5_000e18);
    }

    /// @notice FINDING 7. An unset cap is NOT "no cap", and it is not a $0
    ///         valuation either — it is a revert.
    ///
    /// @dev    Reading zero as "uncapped" would make the single most likely
    ///         misconfiguration (a ledger deployed before governance seeded the
    ///         number) the one state in which a ~$438k pool prices every bond
    ///         without bound. Reading it as a $0 price, which is what this test
    ///         used to assert, is quieter but also wrong: it values every bond
    ///         at nothing while every call still succeeds, and `effectiveTotal
    ///         == 0` marks a challenge convicted while recovering nothing.
    ///         Fail LOUD on a state a deploy pre-flight already refuses.
    function test_woodPrice_zeroCapRevertsRatherThanUncappingOrZeroing() public {
        ExposureLedger fresh = new ExposureLedger(owner, address(swood), 28 days);
        swood.setStake(guardian, 100_000e18);

        // Cap unset AND a perfectly healthy market source wired: the market
        // alone is not enough, because nothing would be bounding it.
        vm.prank(owner);
        fresh.setWoodTwapOracle(address(twap));

        vm.expectRevert(IExposureLedger.NoWoodPrice.selector);
        fresh.slashableBondUsd(guardian);
        vm.expectRevert(IExposureLedger.NoWoodPrice.selector);
        fresh.woodPriceX8();
    }

    /// @notice The other half of the same rule: a cap without any market source
    ///         reverts too. `woodUsdPriceX8` is never served as a price, so
    ///         "governance number only" is not a working configuration.
    function test_woodPrice_capAloneIsNotAPrice() public {
        ExposureLedger fresh = new ExposureLedger(owner, address(swood), 28 days);
        swood.setStake(guardian, 100_000e18);
        vm.prank(owner);
        fresh.setWoodUsdPrice(CAP_X8);

        vm.expectRevert(IExposureLedger.NoWoodPrice.selector);
        fresh.woodPriceX8();
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
        swood.setStake(guardian, 100_000e18); // slashableBondUsd = $5,000 at $0.05
    }

    /// @dev THE SHARED MULTI-APPROVER FIXTURE (see the hazard block above).
    ///      Seats `coverage6` as the proposal's requirement, stakes every
    ///      approver at `stakeWood`, records all their approvals, and hands back
    ///      a set that BOTH early exits leave intact.
    ///
    ///      Call after `_wireRecording()`. The sizing rule is ASSERTED rather
    ///      than assumed: each approver's free budget must be non-zero (so it
    ///      books a real share instead of taking `recordApproval`'s
    ///      no-free-budget return) and strictly below the requirement (so no
    ///      single reservation can satisfy `requireApproveQuorum` on its own and
    ///      leave the later approvers unread). A fixture that cannot hold to
    ///      that sizing does not belong on this helper — it either states
    ///      `// EARLY-EXIT INTENDED:` or takes `_assertApproverSet` alone.
    function _wireUnderCoveredApprovers(
        uint256 proposalId,
        uint256 coverage6,
        uint256 stakeWood,
        address[] memory approvers
    ) internal {
        mgov.set(coverage6);
        uint256 needUsd = ledger.coverageUsd(usdgAsset, coverage6);
        uint256 k = ledger.kNumerator();
        for (uint256 i = 0; i < approvers.length; i++) {
            swood.setStake(approvers[i], stakeWood);
            uint256 capUsd = k * ledger.slashableBondUsd(approvers[i]);
            uint256 open = ledger.openExposureUsd(approvers[i]);
            uint256 free = capUsd > open ? capUsd - open : 0;
            assertGt(free, 0, "sizing rule: an approver with no free budget books nothing and is never listed");
            assertLt(free, needUsd, "sizing rule: no approver may satisfy the quorum on its own");
        }
        vm.startPrank(registry);
        for (uint256 i = 0; i < approvers.length; i++) {
            ledger.recordApproval(address(mgov), proposalId, approvers[i]);
        }
        vm.stopPrank();
        _assertApproverSet(proposalId, approvers);
    }

    /// @dev The count check on its own, for fixtures whose sizing is
    ///      deliberately different from the rule above. `recordApproval`'s
    ///      no-free-budget return leaves no trace — no revert, no event, no
    ///      list entry — so asking the ledger who it actually seated is the only
    ///      way a fixture learns that one of its approvers silently dropped out.
    function _assertApproverSet(uint256 proposalId, address[] memory expected) internal {
        (address[] memory listed, uint256[] memory shares) = ledger.approversOf(address(mgov), proposalId);
        assertEq(listed.length, expected.length, "the ledger seated a different approver set than the fixture wired");
        for (uint256 i = 0; i < expected.length; i++) {
            assertEq(listed[i], expected[i], "approver membership/order");
            assertGt(shares[i], 0, "every approver books a non-zero share");
        }
    }

    function _approverSet(address a, address b) internal pure returns (address[] memory set) {
        set = new address[](2);
        set[0] = a;
        set[1] = b;
    }

    function _approverSet(address a, address b, address c) internal pure returns (address[] memory set) {
        set = new address[](3);
        set[0] = a;
        set[1] = b;
        set[2] = c;
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
        // ...and the proposal is NOT fully covered (issue #27: a partial but
        // nonzero aggregate now SIZES instead of reverting) — the measurement
        // reports the $5,000 raised against the $6,000 required, so the
        // governor can size execution to 5/6 instead of blocking it outright.
        (uint256 coverageRaisedUsd, uint256 requiredCoverageUsd) =
            ledger.requireApproveQuorum(address(mgov), 1, usdgAsset, 6_000e6);
        assertEq(coverageRaisedUsd, 5_000e18, "raised is capped at the guardian's own free budget");
        assertEq(requiredCoverageUsd, 6_000e18);
        assertLt(coverageRaisedUsd, requiredCoverageUsd, "still short of full coverage");
    }

    /// @notice Two half-bonded guardians jointly cover one proposal — §3.3a's
    ///         aggregate quorum doing what it says. Each RESERVES up to the full
    ///         coverage (capped by its own budget); the pro-rata scale-back then
    ///         decides what each actually carries. Arrival order changes
    ///         nothing, which is the property the free-rider veto exploited.
    ///
    /// @dev    On the shared helper: $5,000 budgets against an $8,000
    ///         requirement IS the sizing rule — neither approver can clear the
    ///         quorum alone, so `requireApproveQuorum` has to read both, and
    ///         the helper's count check proves the ledger seated both.
    function test_recordApproval_twoGuardiansAggregateToCover() public {
        _wireRecording();
        address g2 = makeAddr("g2");
        // $5,000 each at $0.05; $8,000 needed — neither covers it alone.
        _wireUnderCoveredApprovers(1, 8_000e6, 100_000e18, _approverSet(guardian, g2));

        assertEq(ledger.openExposureUsd(guardian), 5_000e18, "first reserves its whole budget");
        // The second reserves its OWN budget too, not merely the remainder —
        // there is no leftover to race for. Under the old first-come rule this
        // would read $3,000.
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
        swood.setStake(g2, 100_000e18);
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

    /// @notice THE TRUST MODEL, PINNED. This contract imposes NO rate limit and
    ///         no per-call size ceiling on the price cap. Rate limiting is
    ///         enforced off-chain by a Zodiac Delay/Roles module on the owner
    ///         Safe (issue #89, owner decision 2026-08-02).
    ///
    /// @dev    THE POINT OF THIS TEST IS THAT IT PASSES. It replaces
    ///         `test_setWoodUsdPrice_intervalAndUpwardCeiling`, which asserted
    ///         a 1-day `MIN_PRICE_UPDATE_INTERVAL` and a `<= 2x` ceiling on
    ///         raises. Both were removed, and they had to go TOGETHER: the
    ///         interval was the only thing making the ceiling a rate limit,
    ///         since N calls in one multisig batch move the price 2^N. Keeping
    ///         the ceiling alone would have advertised a protection that the
    ///         exact party it constrains can bypass in a single batch.
    ///
    ///         A future reviewer finding an unrestricted owner here should read
    ///         this as DELIBERATE and go look at the Safe's module config,
    ///         rather than filing it. The interval gated both directions while
    ///         the size cap gated only raises, and after design revision 2
    ///         lowering the cap IS the emergency action — so the limit sat
    ///         directly on crisis response, and a routine morning adjustment
    ///         spent the lever for the rest of the day.
    function test_setWoodUsdPrice_isUnrestrictedOnChainByDesign() public {
        vm.startPrank(owner);

        // TWO CONSECUTIVE CALLS IN THE SAME BLOCK. This is the behaviour change:
        // under the old interval the second one reverted, and `setUp` has
        // already made a first call in this very block.
        ledger.setWoodUsdPrice(0.06e8);
        ledger.setWoodUsdPrice(0.07e8);
        assertEq(ledger.woodUsdPriceX8(), 0.07e8, "a same-block second move must now land");

        // A raise far beyond the old 2x ceiling, also same-block.
        ledger.setWoodUsdPrice(100 * CAP_X8);
        assertEq(ledger.woodUsdPriceX8(), 100 * CAP_X8, "no size ceiling on a raise");

        // THE EMERGENCY PATH, which is what the removal was for: the brake can
        // be pulled repeatedly as a crash develops, with no waiting.
        ledger.setWoodUsdPrice(0.01e8);
        ledger.setWoodUsdPrice(0.001e8);
        assertEq(ledger.woodUsdPriceX8(), 0.001e8, "the brake can be pulled twice as a crash deepens");

        // Zero remains the hard stop, and recovery from it is immediate rather
        // than costing a day.
        ledger.setWoodUsdPrice(0);
        assertEq(ledger.woodUsdPriceX8(), 0);
        ledger.setWoodUsdPrice(1_000_000e8);
        assertEq(ledger.woodUsdPriceX8(), 1_000_000e8, "recovery from the stop is not gated either");
        vm.stopPrank();
    }

    /// @notice Ownership is still the whole access control, and it still bites.
    ///         Removing the rate limit did not widen WHO may call these.
    function test_priceLevers_remainOwnerOnly() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        ledger.setWoodUsdPrice(1e8);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        ledger.setWoodHaircutBps(9_000);
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
        swood.setStake(g2, 100_000e18);
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

    /// @notice N6 — the haircut is the second multiplier on the same quantity,
    ///         so its VALUE bounds still matter: an unbounded multiplier would
    ///         move every bond's valuation 10,000x in one transaction.
    ///
    /// @dev    The value bounds STAY; the 1-day interval that used to sit
    ///         alongside them is GONE (issue #89), so the same-block second
    ///         move now lands. Bounds cost nothing in a crisis; a timer does,
    ///         and tightening the haircut is a safe-direction move that a
    ///         crisis is exactly when you want.
    function test_setWoodHaircutBps_boundedButNotRateLimited() public {
        vm.startPrank(owner);
        vm.expectRevert(IExposureLedger.InvalidParameter.selector);
        ledger.setWoodHaircutBps(1); // below the floor -- a mis-set parameter
        vm.expectRevert(IExposureLedger.InvalidParameter.selector);
        ledger.setWoodHaircutBps(10_001);

        ledger.setWoodHaircutBps(8_000);
        // Same block, immediately again: allowed now, and this is the change.
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
        swood.setStake(g2, 100_000e18);
        swood.setStake(g3, 100_000e18);
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
        swood.setStake(g2, 100_000e18);
        swood.setStake(g3, 100_000e18);
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
        swood.setStake(g2, 100_000e18);
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
        swood.setStake(g2, 100_000e18);
        mgov.set(1_000e6);
        mgov.setSchedule(block.timestamp + 1 days, 3 days);

        vm.startPrank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);
        ledger.recordApproval(address(mgov), 1, g2);
        vm.stopPrank();
        assertEq(ledger.openExposureUsd(guardian), 1_000e18, "reserved the full coverage");

        skip(31 days); // review shut

        // The guardian's bond evaporates -- unstaked, or WOOD collapsed.
        swood.setStake(guardian, 0);
        assertEq(ledger.slashableBondUsd(guardian), 0, "nothing left to slash");

        ledger.settleCoverage(address(mgov), 1); // must not revert or underflow

        // The split follows ABILITY TO PAY (review n1). A guardian with no bond
        // left is allocated nothing, and the survivor absorbs the whole
        // liability rather than being assigned half of a total the cohort can no
        // longer cover. Before n1 the two shares were 500/500 and $500 of the
        // $1,000 was simply unrecoverable.
        assertEq(ledger.allocatedUsd(address(mgov), 1, guardian), 0, "cannot pay -> carries nothing");
        assertEq(ledger.allocatedUsd(address(mgov), 1, g2), 1_000e18, "survivor absorbs it all");

        // AND THE EXIT GATE NO LONGER HOLDS THE COLLAPSED GUARDIAN. This comment
        // used to claim the opposite — "`StakedWood.claimUnstakeGuardian`
        // refuses while open exposure remains, so the collapsed guardian is
        // held" — and nothing asserted it, because it is false. Settling zeroes
        // their booking, which zeroes the bucket, which is exactly the number
        // that gate reads. Asserted here so the claim is measured rather than
        // repeated.
        assertEq(ledger.openExposureUsd(guardian), 0, "settling releases the collapsed guardian's bucket");

        // What actually holds a guardian under accusation is the FREEZE, not the
        // bucket: `claimUnstakeGuardian` asks two questions, and
        // `hasFrozenCoverage` is the one that does not age out on wall-clock
        // (review 🔴F2 / 🟠F6). Nothing is frozen here, so nothing holds them —
        // which is the honest state, not a hidden safety net.
        assertFalse(ledger.hasFrozenCoverage(guardian), "no challenge filed: nothing pins them either");
        vm.prank(freezer);
        ledger.freezeCoverage(address(mgov), 1);
        assertTrue(ledger.hasFrozenCoverage(g2), "the freeze is what pins a live approver");
        // ...and it pins only guardians still carrying something, so a booking
        // settled to zero is outside even that. A guardian whose bond is gone
        // has nothing to hold; the loss is booked against the cohort, not
        // recovered from them.
        assertFalse(ledger.hasFrozenCoverage(guardian), "a zero booking is not frozen either");

        // ...and the proposal is still genuinely covered, where it was not before.
        ledger.requireApproveQuorum(address(mgov), 1, usdgAsset, 1_000e6);
    }

    // ── pinCoverageUntil (issue #95) ──

    /// @notice THE MECHANISM ITSELF: pinning holds `hasFrozenCoverage` true
    ///         through a chosen future instant, independent of `freezeCoverage`
    ///         ever having been called at all — and it decays on its own once
    ///         wall-clock passes that instant, with no unpin call required.
    function test_pinCoverageUntil_holdsThenDecaysOnWallClock() public {
        _wireRecording();
        mgov.set(1_000e6);
        mgov.setSchedule(block.timestamp + 1 days, 3 days);
        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);

        assertFalse(ledger.hasFrozenCoverage(guardian), "never frozen, never pinned");

        uint256 deadline = block.timestamp + 30 days;
        vm.prank(freezer);
        ledger.pinCoverageUntil(address(mgov), 1, deadline);
        assertTrue(ledger.hasFrozenCoverage(guardian), "pinned, though `freezeCoverage` was never called");

        vm.warp(deadline - 1);
        assertTrue(ledger.hasFrozenCoverage(guardian), "one second before the deadline: still pinned");

        vm.warp(deadline);
        assertFalse(ledger.hasFrozenCoverage(guardian), "at the deadline: decayed with no unpin call");
    }

    /// @notice ONLY EVER RAISES, mirroring `ChallengeGame.challengeableUntil`'s
    ///         own monotonic-raise semantics one layer up. A smaller, later pin
    ///         must not shadow a larger, earlier one still in effect — the exact
    ///         property `ChallengeGame._refundAll` relies on across repeated
    ///         Inconclusive rounds.
    function test_pinCoverageUntil_onlyEverRaises() public {
        _wireRecording();
        mgov.set(1_000e6);
        mgov.setSchedule(block.timestamp + 1 days, 3 days);
        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);

        uint256 far = block.timestamp + 60 days;
        uint256 near = block.timestamp + 10 days;
        vm.startPrank(freezer);
        ledger.pinCoverageUntil(address(mgov), 1, far);
        ledger.pinCoverageUntil(address(mgov), 1, near); // smaller, later call
        vm.stopPrank();

        vm.warp(far - 1);
        assertTrue(ledger.hasFrozenCoverage(guardian), "the earlier, LARGER pin survives the smaller call");

        vm.warp(far);
        assertFalse(ledger.hasFrozenCoverage(guardian), "and decays at its own instant, not the smaller one's");
    }

    /// @notice ONLY GUARDIANS WHO ACTUALLY COMMITTED are pinned — mirroring
    ///         `freezeCoverage`'s own `_recorded[key][g].usd == 0` skip. A
    ///         guardian with nothing booked against this proposal has nothing
    ///         a conviction could recover from them, so pinning them would hold
    ///         an unstake claim for no protective reason.
    function test_pinCoverageUntil_skipsGuardiansWithNoCommitment() public {
        _wireRecording();
        mgov.set(1_000e6);
        mgov.setSchedule(block.timestamp + 1 days, 3 days);
        address uncommitted = makeAddr("uncommitted");
        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);
        // `uncommitted` is never recorded as an approver of this proposal.

        vm.prank(freezer);
        ledger.pinCoverageUntil(address(mgov), 1, block.timestamp + 30 days);

        assertTrue(ledger.hasFrozenCoverage(guardian), "the actual approver is pinned");
        assertFalse(ledger.hasFrozenCoverage(uncommitted), "an address never approving this proposal is not");
    }

    /// @notice THE FIX'S WHOLE PURPOSE: the pin outlives `unfreezeCoverage`.
    ///         This is the exact sequence `ChallengeGame._refundAll` performs —
    ///         release the live freeze, then pin through the re-armed
    ///         deadline — proven directly against the ledger rather than only
    ///         through `ChallengeGame`'s own call.
    function test_pinCoverageUntil_survivesUnfreezeCoverage() public {
        _wireRecording();
        mgov.set(1_000e6);
        mgov.setSchedule(block.timestamp + 1 days, 3 days);
        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);

        vm.startPrank(freezer);
        ledger.freezeCoverage(address(mgov), 1);
        assertTrue(ledger.hasFrozenCoverage(guardian), "live freeze holds first");

        uint256 deadline = block.timestamp + 26 days; // e.g. a re-armed challengeableUntil
        ledger.unfreezeCoverage(address(mgov), 1);
        ledger.pinCoverageUntil(address(mgov), 1, deadline);
        vm.stopPrank();

        assertTrue(ledger.hasFrozenCoverage(guardian), "the pin holds even though the live freeze was JUST released");

        vm.warp(deadline);
        assertFalse(ledger.hasFrozenCoverage(guardian), "and finally releases at the pinned instant");
    }

    /// @notice H1 — `settleCoverage` was a ONE-SHOT priced at the caller's
    ///         chosen instant, so an approver could time it to a WOOD trough and
    ///         permanently write down what a conviction could recover.
    ///
    ///         Two approvers, 100k WOOD each, an $8,000 proposal. Settled at
    ///         $0.05 the cohort books $4,000 + $4,000 and $8,000 is recoverable.
    ///         Settled at $0.025 the live cohort value ($5,000) falls under the
    ///         need, `_allocate` returns each bond's trough value unchanged, and
    ///         the old unbounded residue dumped the $3,000 gap on the first
    ///         holder: $5,500 + $2,500 booked, of which only $7,500 is ever
    ///         recoverable once WOOD comes back. 6.25% of underwritten coverage
    ///         gone, permanently, for the cost of gas at a chosen block.
    ///
    ///         The fix is that no pass binds a later one: the pledges survive
    ///         settlement, so anyone can re-derive the split at the recovered
    ///         price. Asserted against the SAME numbers the good-instant pass
    ///         produces.
    function test_settleCoverage_cannotBePinnedAtAPriceTrough() public {
        _wireRecording();
        address g2 = makeAddr("g2");
        swood.setStake(g2, 100_000e18); // both hold $5,000 at $0.05
        mgov.set(8_000e6); // $8,000 needed; each reserves its whole $5,000
        mgov.setSchedule(block.timestamp + 1 days, 3 days);

        vm.startPrank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);
        ledger.recordApproval(address(mgov), 1, g2);
        vm.stopPrank();

        skip(31 days); // past executeBy: settling is now permitted

        // WOOD halves and an approver settles at exactly that instant.
        vm.prank(owner);
        ledger.setWoodUsdPrice(0.025e8);
        ledger.settleCoverage(address(mgov), 1);

        // WOOD comes back, immediately — neither the interval nor the 2x
        // ceiling exists any more (issue #89), so the recovery needs no wait.
        vm.prank(owner);
        ledger.setWoodUsdPrice(0.05e8);

        // Anyone refreshes it — the challenger about to file, the resolver about
        // to price a conviction, or a passer-by.
        ledger.settleCoverage(address(mgov), 1);

        assertEq(ledger.allocatedUsd(address(mgov), 1, guardian), 4_000e18, "re-derived, not pinned at the trough");
        assertEq(ledger.allocatedUsd(address(mgov), 1, g2), 4_000e18, "and the residue did not favour the first");
        assertEq(ledger.liabilityUsd(address(mgov), 1), 8_000e18, "the whole coverage is recoverable again");
        ledger.requireApproveQuorum(address(mgov), 1, usdgAsset, 8_000e6);
    }

    /// @notice M1 — the residue is TRUNCATION DUST only when the cohort's live
    ///         value still covers the need. When `reservedTotal > needUsd` (so
    ///         the old under-subscribed short-circuit did not fire) but
    ///         `effectiveTotal < needUsd`, `_allocate` returns everyone's whole
    ///         `min(live, pledge)` and the "residue" is the entire cohort
    ///         shortfall — which the old code credited wholesale to the first
    ///         holder, with no bound against that guardian's own reservation.
    ///
    ///         $1,000 needed. A pledges its whole $600 budget; B pledges the
    ///         full $1,000 off a $5,000 bond. Reservations total $1,600, above
    ///         the need. B's bond then collapses to $50, leaving a live cohort
    ///         value of $650 and a $350 gap — which landed on A, booking $950
    ///         against a $600 pledge and a $600 `k x bond` cap.
    ///         Pure budget griefing: $350 of A's capacity locked for a bucket
    ///         lifetime against a liability A never took on, and no extra dollar
    ///         recovered, since the slash clamps to the live bond either way.
    function test_settleCoverage_residueCannotExceedAGuardiansOwnReservation() public {
        _wireRecording();
        address big = makeAddr("bigBond");
        swood.setStake(guardian, 12_000e18); // $600 bond -> pledges all of it
        swood.setStake(big, 100_000e18); // $5,000 bond -> pledges the full $1,000
        mgov.set(1_000e6);
        mgov.setSchedule(block.timestamp + 1 days, 3 days);

        vm.startPrank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);
        ledger.recordApproval(address(mgov), 1, big);
        vm.stopPrank();
        assertEq(ledger.openExposureUsd(guardian), 600e18, "pledged its whole budget, not a wei more");

        skip(31 days);
        swood.setStake(big, 1_000e18); // $50 left: the cohort can only pay $650
        ledger.settleCoverage(address(mgov), 1);

        (, uint256[] memory committed) = ledger.approversOf(address(mgov), 1);
        assertEq(committed[0], 600e18, "booked at its pledge, never above it");
        assertEq(ledger.openExposureUsd(guardian), 600e18, "no griefed $350 of locked capacity");
        assertLe(
            ledger.openExposureUsd(guardian),
            ledger.kNumerator() * ledger.slashableBondUsd(guardian),
            "coverage <= k x slashableBondUsd still holds"
        );

        // The aggregate lands UNDER `needUsd`, which is the honest answer and
        // costs the quorum nothing: it sums the same `min(live, booked)` it
        // would have summed had settling never run — a nonzero shortfall now
        // SIZES (issue #27) rather than reverting, exactly as the proposal's
        // coverage measurement already would have reported.
        assertEq(ledger.liabilityUsd(address(mgov), 1), 650e18, "bounded by what the cohort can actually pay");
        (uint256 coverageRaisedUsd, uint256 requiredCoverageUsd) =
            ledger.requireApproveQuorum(address(mgov), 1, usdgAsset, 1_000e6);
        assertEq(coverageRaisedUsd, 650e18, "bounded by what the cohort can actually pay");
        assertEq(requiredCoverageUsd, 1_000e18);
    }

    /// @notice The fourth block-only path (siblings: M3, N1, N4). `_woodPrice`
    ///         handled an UNSET and a STALE feed by degrading, but a bare
    ///         `latestRoundData()` revert propagated through `slashableBondUsd`
    ///         into `recordApproval` — which reads the bond OUTSIDE the
    ///         try/catch guarding the asset feed — so approve votes reverted
    ///         while Block votes worked, and `requireApproveQuorum` reverted
    ///         with them, blocking execution protocol-wide. `setWoodFeed(0, …)`
    ///         was refused, so there was no path back either.
    ///
    /// @dev    Re-pointed at revision 2: a dead aggregator now degrades to the
    ///         TWAP rather than to the governance scalar. What must NOT change
    ///         is that it degrades at all, silently and in the safe direction.
    function test_woodPrice_revertingAggregatorDegradesToTheTwapAndIsUnwireable() public {
        _wireRecording();
        mgov.set(1_000e6);

        RevertingFeed dead = new RevertingFeed();
        vm.prank(owner);
        ledger.setWoodFeed(address(dead), 1 days);

        (uint256 px, bool fromFeed, bool capBinding) = ledger.woodPriceDetail();
        assertEq(px, MARKET_X8, "degrades to the TWAP, not to the cap");
        assertFalse(fromFeed, "and says so, for monitoring");
        assertFalse(capBinding, "the cap sits above market and does not bind");
        assertEq(ledger.slashableBondUsd(guardian), 5_000e18, "bonds still price");

        // The approve side is not silenced, and execution is not blocked.
        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);
        assertEq(ledger.openExposureUsd(guardian), 1_000e18);
        ledger.requireApproveQuorum(address(mgov), 1, usdgAsset, 1_000e6);

        // A healthy feed is PREFERRED over the TWAP...
        MockFeed healthy = new MockFeed(0.08e8, 8);
        vm.prank(owner);
        ledger.setWoodFeed(address(healthy), 1 days);
        (uint256 p2, bool fromFeed2,) = ledger.woodPriceDetail();
        assertEq(p2, 0.08e8, "a live aggregator supersedes the TWAP");
        assertTrue(fromFeed2);

        // ...and zero is the unwire switch, which is the governance path back
        // from an aggregator that has gone bad. It lands on the TWAP.
        vm.prank(owner);
        ledger.setWoodFeed(address(0), 0);
        (uint256 p3, bool fromFeed3,) = ledger.woodPriceDetail();
        assertEq(p3, MARKET_X8, "back on the TWAP");
        assertFalse(fromFeed3);
    }

    /// @notice Settle with a RELEASED approver still in the list. The loop must
    ///         skip zero-reservation entries without letting one become the
    ///         residue holder, or the dust would be credited to somebody who
    ///         underwrote nothing.
    function test_settleCoverage_skipsReleasedApprovers() public {
        _wireRecording();
        address g2 = makeAddr("g2");
        address g3 = makeAddr("g3");
        swood.setStake(g2, 100_000e18); // $5,000 -> reserves the full 1,000
        // Deliberately UNEQUAL so the pro-rata split does not divide evenly and
        // the residue path is actually exercised. With equal bonds this test
        // passes with the residue top-up deleted, which makes it worthless as
        // cover for that branch.
        swood.setStake(g3, 10_000e18); // $500 -> reserves only 500
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

    /// @notice The residue top-up exists for `_allocate`'s truncation dust. But
    ///         `_allocate` returns each reservation UNSCALED whenever
    ///         `effectiveTotal <= needUsd`, and the early return above it guards
    ///         `reservedTotal`, not `effectiveTotal`. Between those two a cohort
    ///         whose bonds shrank after the vote lands in a regime where
    ///         `assigned` is the cohort's whole ability to pay, so
    ///         `needUsd - assigned` is a genuine coverage SHORTFALL — not dust.
    ///
    ///         Crediting it to the first holder books exposure that guardian
    ///         never reserved, above its own `kNumerator * slashableBondUsd`
    ///         cap, which freezes its approve budget and its unstake claim for
    ///         the rest of the bucket's life. The victim is attacker-selectable:
    ///         `releaseApproval`'s swap-and-pop chooses who sits at index 0.
    function test_settleCoverage_shortfallIsNotBookedOnTheFirstHolder() public {
        _wireRecording();
        address g2 = makeAddr("g2");
        swood.setStake(g2, 100_000e18); // $5,000 -> reserves the full $1,000
        mgov.set(1_000e6); // needUsd = $1,000
        mgov.setSchedule(block.timestamp + 1 days, 3 days);

        vm.startPrank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);
        ledger.recordApproval(address(mgov), 1, g2);
        vm.stopPrank();
        // reservedTotal = $2,000 > needUsd, so settle does NOT take the
        // under-subscribed early return -- this is the gap the guard misses.
        assertEq(ledger.openExposureUsd(guardian), 1_000e18, "reserved the full coverage");

        skip(31 days); // review shut, past executeBy

        // Both bonds fall to $200 (WOOD decline / partial unstake), so
        // effectiveTotal = $400 <= needUsd and `_allocate` scales nothing.
        swood.setStake(guardian, 4_000e18);
        swood.setStake(g2, 4_000e18);

        ledger.settleCoverage(address(mgov), 1);

        // Each guardian carries exactly what it can pay. The $600 the cohort
        // cannot cover stays uncovered -- booking it on someone invents
        // collateral nobody pledged, which is the same reasoning `_allocate`
        // already applies when it refuses to scale UP.
        assertEq(ledger.openExposureUsd(guardian), 200e18, "first holder carries only its own ability to pay");
        assertEq(ledger.openExposureUsd(g2), 200e18, "second holder unchanged");

        // The invariant that makes this a bug and not an accounting preference:
        // booked exposure must never exceed the guardian's own coverage cap.
        assertLe(
            ledger.openExposureUsd(guardian),
            ledger.kNumerator() * ledger.slashableBondUsd(guardian),
            "booked exposure must stay within the guardian's own cap"
        );
    }

    /// @dev Second proposal on its own governor, so `getRequiredCoverage` for
    ///      P2 is independent of P1's — the shared mock returns one number for
    ///      every id, and mutating it between calls would silently re-price the
    ///      proposal a later `settleCoverage` is about to re-derive.
    function _secondGovernor(uint256 coverage, uint256 duration) internal returns (MockGovernorForLedger) {
        MockVaultForLedger vault2 = new MockVaultForLedger(usdgAsset);
        MockGovernorForLedger g = new MockGovernorForLedger(address(vault2));
        g.set(coverage);
        g.setSchedule(block.timestamp + 1 days, duration);
        return g;
    }

    /// @notice #110 — THE BATCHING CAP WAS ENFORCED AT EXACTLY ONE PLACE.
    ///         `openExposureUsd(g) <= kNumerator * slashableBondUsd(g)` is a
    ///         property of `_buckets`, but `recordApproval` is not the only
    ///         writer of `_buckets`: `_rebook` is too, and its upward branch had
    ///         no cap check. `settleCoverage` is `external`, permissionless and
    ///         deliberately re-runnable, so the walk-up could be replayed AFTER
    ///         the guardian had legally spent the budget an earlier pass freed.
    ///
    ///         The whole trace needs no capital, no price manipulation and no
    ///         privileged role — step 4 is ordinary protocol operation and step 5
    ///         is an EOA paying gas.
    function test_settleCoverage_reRunCannotPushAGuardianPastItsCap() public {
        _wireRecording();
        address g2 = makeAddr("g2");
        swood.setStake(g2, 100_000e18); // both hold $5,000 at $0.05
        assertEq(ledger.kNumerator(), 1, "the trace is written for k = 1");

        // 1. Both approve P1, each reserving the full coverage. g1 is at its cap.
        mgov.set(5_000e6); // needUsd = $5,000 = one guardian's whole budget
        mgov.setSchedule(block.timestamp + 1 days, 3 days);
        vm.startPrank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);
        ledger.recordApproval(address(mgov), 1, g2);
        vm.stopPrank();
        assertEq(ledger.openExposureUsd(guardian), 5_000e18, "fully pledged: exactly at the cap");

        // 2. Anyone settles P1 once execution is moot. The pro-rata split writes
        //    both bookings DOWN and hands half of g1's budget back.
        skip(31 days);
        ledger.settleCoverage(address(mgov), 1);
        assertEq(ledger.openExposureUsd(guardian), 2_500e18, "written down: $2,500 came free");

        // 3. g1 spends the freed budget on an unrelated proposal. The cap check
        //    in `recordApproval` passes, and it is right to pass.
        MockGovernorForLedger mgov2 = _secondGovernor(2_500e6, 3 days);
        vm.prank(registry);
        ledger.recordApproval(address(mgov2), 1, guardian);
        assertEq(ledger.openExposureUsd(guardian), 5_000e18, "back at the cap, legitimately");

        // 4. g2 is slashed to zero on an unrelated conviction.
        swood.setStake(g2, 0);

        // 5. Anyone re-runs settlement on P1. `_effectiveReservedTotal` sums over
        //    LIVE bonds, so it has halved, and `_allocate` now wants to hand g1
        //    the whole $5,000 back — on top of the $2,500 already spent on P2.
        ledger.settleCoverage(address(mgov), 1);

        // Pre-fix this read $7,500 against a $5,000 cap: one bond underwriting
        // 1.5x its own value, slashable in full exactly once.
        assertLe(
            ledger.openExposureUsd(guardian),
            ledger.kNumerator() * ledger.slashableBondUsd(guardian),
            "one bond must never underwrite more than k x its own value"
        );
        assertEq(ledger.openExposureUsd(guardian), 5_000e18, "clamped to zero free budget: the re-run gains nothing");
        assertEq(ledger.allocatedUsd(address(mgov2), 1, guardian), 2_500e18, "and P2's booking is untouched");
    }

    /// @notice The clamp must be a CLAMP, not a freeze. #110's fix bounds an
    ///         upward `_rebook` by the guardian's free budget, and the whole
    ///         reason claim A of that audit was dismissed is that settlement
    ///         REPAIRS: a pass taken at a WOOD trough is a stale number anyone
    ///         can refresh. Bounding the walk-up so hard that it stopped
    ///         repairing would be the rejected option — a de-facto once-only
    ///         settlement, which re-opens the trough-pinning attack H1 closed.
    ///
    ///         With no competing exposure, `openExposureUsd` is just this key's
    ///         own booking, so the bound is the full cap and the repair runs to
    ///         completion.
    function test_settleCoverage_capClampStillRepairsOnReRun() public {
        _wireRecording();
        address g2 = makeAddr("g2");
        swood.setStake(g2, 100_000e18); // both hold $5,000 at $0.05
        mgov.set(8_000e6); // $8,000 needed; each reserves its whole $5,000
        mgov.setSchedule(block.timestamp + 1 days, 3 days);

        vm.startPrank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);
        ledger.recordApproval(address(mgov), 1, g2);
        vm.stopPrank();

        skip(31 days);

        // Settled at a trough: the live cohort is worth $5,000 against an $8,000
        // need, so `_allocate` returns each bond's trough value and both bookings
        // are written down to $2,500. Post-#88 the effective price is
        // `min(market, cap)`, so dropping the CAP below MARKET_X8 is what moves
        // it — the same lever the sibling trough test pulls.
        vm.prank(owner);
        ledger.setWoodUsdPrice(MARKET_X8 / 2);
        assertEq(ledger.woodPriceX8(), MARKET_X8 / 2, "the cap is binding: this is the trough");
        ledger.settleCoverage(address(mgov), 1);
        uint256 atTrough = ledger.openExposureUsd(guardian);
        assertEq(atTrough, 2_500e18, "written down at the trough");

        // WOOD recovers and anyone refreshes the split. Neither the interval nor
        // the 2x ceiling exists any more (issue #89), so no wait is needed.
        vm.prank(owner);
        ledger.setWoodUsdPrice(CAP_X8);
        assertEq(ledger.woodPriceX8(), MARKET_X8, "back on the market price");
        ledger.settleCoverage(address(mgov), 1);

        assertGt(ledger.openExposureUsd(guardian), atTrough, "the booking WALKED BACK UP: still re-runnable");
        assertEq(ledger.allocatedUsd(address(mgov), 1, guardian), 4_000e18, "repaired in full, not partially");
        assertEq(ledger.allocatedUsd(address(mgov), 1, g2), 4_000e18);
        assertEq(ledger.liabilityUsd(address(mgov), 1), 8_000e18, "the whole coverage is recoverable again");
        assertLe(
            ledger.openExposureUsd(guardian),
            ledger.kNumerator() * ledger.slashableBondUsd(guardian),
            "and the repair stayed inside the cap"
        );
        ledger.requireApproveQuorum(address(mgov), 1, usdgAsset, 8_000e6);
    }

    /// @notice The two halves together: a repair that is PARTIALLY clamped. The
    ///         guardian spent some but not all of the freed budget elsewhere, so
    ///         the walk-up must run as far as the remaining headroom and stop
    ///         there — neither refused outright (that would be the freeze) nor
    ///         allowed through to `_allocate`'s figure (that is #110).
    function test_settleCoverage_upwardRebookStopsAtTheRemainingHeadroom() public {
        _wireRecording();
        address g2 = makeAddr("g2");
        swood.setStake(g2, 100_000e18); // both hold $5,000 at $0.05

        mgov.set(5_000e6);
        mgov.setSchedule(block.timestamp + 1 days, 3 days);
        vm.startPrank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);
        ledger.recordApproval(address(mgov), 1, g2);
        vm.stopPrank();

        skip(31 days);
        ledger.settleCoverage(address(mgov), 1); // both down to $2,500

        // g1 spends only $1,000 of the $2,500 that came free.
        MockGovernorForLedger mgov2 = _secondGovernor(1_000e6, 3 days);
        vm.prank(registry);
        ledger.recordApproval(address(mgov2), 1, guardian);
        assertEq(ledger.openExposureUsd(guardian), 3_500e18, "$1,500 of headroom left");

        swood.setStake(g2, 0);
        ledger.settleCoverage(address(mgov), 1);

        // `_allocate` wanted $5,000; the headroom allowed $2,500 + $1,500.
        assertEq(ledger.allocatedUsd(address(mgov), 1, guardian), 4_000e18, "repaired up to the headroom, no further");
        assertEq(ledger.openExposureUsd(guardian), 5_000e18, "which lands exactly on the cap");
        assertLe(
            ledger.openExposureUsd(guardian),
            ledger.kNumerator() * ledger.slashableBondUsd(guardian),
            "cap holds on the partially-clamped path too"
        );
    }

    /// @notice `_woodPrice` degrades to the governance fallback on an unset
    ///         feed, a non-positive answer and a stale answer — but the read
    ///         itself was unwrapped, so a feed that REVERTS propagated instead.
    ///         A fresh aggregator with no round published is exactly that shape,
    ///         and it is the shape the first WOOD/USD wiring will have (there is
    ///         no WOOD feed on Robinhood today).
    ///
    ///         Unhandled, it halts far more than pricing: every Approve vote,
    ///         every tier-gated `executeProposal`, `settleCoverage` and
    ///         `slashBpsFor` route through `slashableBondUsd`. `recordApproval`
    ///         deliberately wraps only the ASSET-price read, so the WOOD read
    ///         reverting fails the vote — reproducing the block-only review that
    ///         three review rounds existed to eliminate.
    function test_woodPrice_degradesToTheTwapWhenTheFeedReverts() public {
        RevertingFeed dead = new RevertingFeed();
        vm.prank(owner);
        ledger.setWoodFeed(address(dead), 1 days);

        (uint256 price, bool fromFeed,) = ledger.woodPriceDetail();
        assertFalse(fromFeed, "a reverting feed is a degraded feed, not a fatal one");
        assertEq(price, MARKET_X8, "degrades to the TWAP");

        // The property that matters: bonds still price, so approvals still work.
        swood.setStake(guardian, 100_000e18);
        assertEq(ledger.slashableBondUsd(guardian), 5_000e18, "bond still priceable through the outage");
    }

    /// @notice Recovery must not require deploying a substitute aggregator.
    ///         `setWoodFeed` rejected `address(0)`, so once a bad feed was
    ///         wired there was no transaction that returned the ledger to its
    ///         other source.
    function test_setWoodFeed_canClearBackToTheTwap() public {
        RevertingFeed dead = new RevertingFeed();
        vm.startPrank(owner);
        ledger.setWoodFeed(address(dead), 1 days);
        ledger.setWoodFeed(address(0), 0); // clear
        vm.stopPrank();

        (uint256 price, bool fromFeed,) = ledger.woodPriceDetail();
        assertFalse(fromFeed, "cleared feed reads the TWAP");
        assertEq(price, MARKET_X8, "market price restored");
    }

    /// @notice Clearing is an explicit two-zero move, so a mis-typed maxDelay
    ///         alongside a zero feed is still rejected.
    function test_setWoodFeed_zeroFeedWithNonZeroDelayReverts() public {
        vm.prank(owner);
        vm.expectRevert(IExposureLedger.InvalidParameter.selector);
        ledger.setWoodFeed(address(0), 1 days);
    }

    // ── WOOD price: market sources under a governance cap ──────────────────

    /// @notice Once a feed is wired it is PREFERRED over the TWAP, and the
    ///         haircut is applied on top — collateral wants a floor, not a
    ///         quote. An unhaircut oracle tracks WOOD UP and inflates every
    ///         bond exactly when the market is frothy.
    function test_woodPrice_feedPreferredOverTwapAndAppliesTheHaircut() public {
        assertEq(ledger.woodPriceX8(), MARKET_X8, "TWAP-priced while no aggregator is wired");

        MockFeed woodFeed = new MockFeed(0.08e8, 8); // aggregator says $0.08
        vm.startPrank(owner);
        ledger.setWoodFeed(address(woodFeed), 1 days);
        assertEq(ledger.woodPriceX8(), 0.08e8, "feed wins over the TWAP, no haircut by default");

        ledger.setWoodHaircutBps(7_500); // value bonds at 75% of market
        vm.stopPrank();
        assertEq(ledger.woodPriceX8(), 0.06e8, "haircut applied to the live read");

        // And it flows through to what a bond is worth.
        swood.setStake(guardian, 100_000e18);
        assertEq(ledger.slashableBondUsd(guardian), 6_000e18, "100k WOOD at the haircut price");
    }

    /// @notice THE INVARIANT, AND IT NEVER HAD A TEST. The market may only
    ///         LOWER the WOOD price. Pushing the TWAP up must change nothing.
    ///
    /// @dev    This is the whole safety argument of the change: the pool behind
    ///         the TWAP is ~$438k deep and moving its spot 2x costs ~$91k, so
    ///         an unbounded read from it would put every guardian bond in the
    ///         protocol on a market an attacker can afford to move. The audit
    ///         found the shipped `min` pointed at a number the emergency-only
    ///         doctrine required to be set HIGH and non-binding — a `min`
    ///         against a number chosen never to bind is not a bound — and no
    ///         test would have caught it, because none pumped the TWAP.
    ///
    ///         Asserted at 20x, well past any plausible manipulation, and on
    ///         the derived quantity (`slashableBondUsd`) as well as the price,
    ///         since the bond valuation is what a quorum actually consumes.
    function test_woodPrice_pumpingTheTwapCannotRaiseThePrice() public {
        swood.setStake(guardian, 100_000e18);
        assertEq(ledger.woodPriceX8(), MARKET_X8);
        assertEq(ledger.slashableBondUsd(guardian), 5_000e18);

        // Just under the cap: still tracked, because the cap is not binding.
        twap.setPrice(CAP_X8 - 1);
        assertEq(ledger.woodPriceX8(), CAP_X8 - 1, "the market is followed right up to the cap");

        // At the cap and far beyond it: pinned. The attack is inert.
        twap.setPrice(CAP_X8);
        assertEq(ledger.woodPriceX8(), CAP_X8, "exactly at the cap is not yet over it");
        (,, bool bindingAtCap) = ledger.woodPriceDetail();
        assertFalse(bindingAtCap, "equal is not binding");

        twap.setPrice(20 * CAP_X8); // a 20x pump
        assertEq(ledger.woodPriceX8(), CAP_X8, "a pumped TWAP CANNOT raise the price above the cap");
        assertEq(ledger.slashableBondUsd(guardian), 10_000e18, "and the bond is capped with it");
        (,, bool binding) = ledger.woodPriceDetail();
        assertTrue(binding, "and the cap reports itself as binding");

        // The other direction is followed all the way down, immediately and
        // with no governance transaction — a crash must devalue bonds.
        twap.setPrice(0.005e8);
        assertEq(ledger.woodPriceX8(), 0.005e8, "a crash IS tracked");
        assertEq(ledger.slashableBondUsd(guardian), 500e18);
    }

    /// @notice The same invariant on the Chainlink leg: the cap binds whichever
    ///         source is live, so a compromised aggregator buys no more than a
    ///         compromised pool.
    function test_woodPrice_capBindsTheChainlinkFeedToo() public {
        MockFeed woodFeed = new MockFeed(int256(int256(CAP_X8) * 20), 8);
        vm.prank(owner);
        ledger.setWoodFeed(address(woodFeed), 1 days);

        (uint256 price, bool fromFeed, bool binding) = ledger.woodPriceDetail();
        assertEq(price, CAP_X8, "a 20x aggregator is capped exactly like a 20x TWAP");
        assertTrue(fromFeed);
        assertTrue(binding);
    }

    /// @notice A crash is tracked IMMEDIATELY, which is the direction where lag
    ///         hurts: under the manual number somebody has to notice and
    ///         transact while bonds stay over-valued in the meantime.
    function test_woodPrice_tracksACrashWithoutAGovernanceTransaction() public {
        MockFeed woodFeed = new MockFeed(0.05e8, 8);
        vm.prank(owner);
        ledger.setWoodFeed(address(woodFeed), 1 days);
        swood.setStake(guardian, 100_000e18);
        assertEq(ledger.slashableBondUsd(guardian), 5_000e18);

        woodFeed.set(0.005e8); // 10x collapse, no owner action
        assertEq(ledger.slashableBondUsd(guardian), 500e18, "bond revalued with no transaction");
    }

    /// @notice A stale or broken aggregator DEGRADES TO THE TWAP rather than
    ///         reverting. Failing closed on a Chainlink hiccup while another
    ///         live source is sitting right there would halt approvals for no
    ///         reason; the degraded path is a different market source, not a
    ///         hand-maintained number, so it stays honest.
    function test_woodPrice_degradesToTheTwapWhenTheFeedIsStale() public {
        MockFeed woodFeed = new MockFeed(0.08e8, 8);
        vm.prank(owner);
        ledger.setWoodFeed(address(woodFeed), 1 hours);

        assertEq(ledger.woodPriceX8(), 0.08e8, "fresh: feed");
        skip(2 hours);
        assertEq(ledger.woodPriceX8(), MARKET_X8, "stale: the TWAP, not the cap and not zero");

        swood.setStake(guardian, 100_000e18);
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
        swood.setStake(g2, 100_000e18);
        mgov.set(1_000e6);
        mgov.setSchedule(block.timestamp + 1 days, 3 days);

        vm.startPrank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);
        ledger.recordApproval(address(mgov), 1, g2);
        vm.stopPrank();
        assertEq(ledger.allocatedUsd(address(mgov), 1, guardian), 500e18, "even split while both can pay");

        // One bond is devalued to a quarter of what it pledged.
        swood.setStake(guardian, 5_000e18); // $250 of a $1,000 reservation

        // The split is pro-rata over EFFECTIVE capacity, not a simple cap:
        // effective total is 250 + 1000 = 1250, so the shares are 250/1250 and
        // 1000/1250 of the $1,000 needed.
        assertEq(ledger.allocatedUsd(address(mgov), 1, guardian), 200e18, "sized by what it can still pay");
        assertEq(ledger.allocatedUsd(address(mgov), 1, g2), 800e18, "survivor absorbs the shortfall");
        // Still fully covered -- which is the point. Before n1 the devalued
        // guardian kept a 500 slice it could not honour and $250 was unbacked.
        ledger.requireApproveQuorum(address(mgov), 1, usdgAsset, 1_000e6);
    }

    /// @notice Issue #35, spec scenarios "Accused cohort cannot price up its
    ///         own prosecution" and "Post-execution top-up is not coverage".
    ///
    ///         Reproduces the exact attack design.md describes: a WOOD price
    ///         crash between vote and read opens a gap between what the
    ///         guardian reserved and what its bond is worth NOW; a
    ///         post-execution top-up (in WOOD units) restores the LIVE bond
    ///         value back to the reservation. Under the OLD (pre-fix, always-
    ///         live) basis that top-up would have fully restored
    ///         `allocatedUsd`/`liabilityUsd` to the pre-crash figure — capital
    ///         the verdict slash, anchored at execution, can never reach. The
    ///         anchored basis prices the guardian at its PRE-top-up WOOD
    ///         snapshot even at the post-crash price, so the top-up buys
    ///         nothing.
    function test_allocatedUsd_and_liabilityUsd_postExecutionTopUpCannotUndoAPriceCrash() public {
        _wireRecording();
        mgov.set(1_000e6); // needUsd = $1,000
        mgov.setSchedule(block.timestamp + 1 days, 3 days);

        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);
        // Sole approver, bond ($5,000) >> need ($1,000): reserves the full
        // $1,000, unscaled (reservedTotal == needUsd).
        assertEq(ledger.allocatedUsd(address(mgov), 1, guardian), 1_000e18, "pre-crash: fully reserved");

        // Execute: the anchor snapshots the CURRENT 100,000 WOOD.
        mgov.setExecutedAt(block.timestamp);
        assertEq(ledger.liabilityUsd(address(mgov), 1), 1_000e18, "pre-crash: fully covered");

        skip(12 hours);

        // WOOD crashes 10x: $0.05 -> $0.005. Live bond falls to 100,000 *
        // 0.005 = $500, below the $1,000 reservation -- exactly the gap
        // design.md's "reachable magnitude" analysis describes.
        twap.setPrice(0.005e8);
        assertEq(ledger.allocatedUsd(address(mgov), 1, guardian), 500e18, "post-crash: mine drops with the price");
        assertEq(ledger.liabilityUsd(address(mgov), 1), 500e18, "post-crash: liability drops with the price");

        // The guardian tops up 100,000 MORE WOOD, post-execution: at the
        // crashed price this exactly restores LIVE bond value to $1,000.
        swood.setStake(guardian, 200_000e18);
        assertEq(ledger.slashableBondUsd(guardian), 1_000e18, "sanity: live bond IS fully restored by the top-up");

        // The anchored reads are NOT restored: the anchor still snapshots the
        // pre-top-up 100,000 WOOD, so pricing it at the crashed rate still
        // gives $500 -- the top-up cannot buy back what the price crash took,
        // because the verdict slash (anchored at execution) can never reach
        // WOOD staked after that instant.
        assertEq(
            ledger.allocatedUsd(address(mgov), 1, guardian), 500e18, "anchored: top-up does not restore the booking"
        );
        assertEq(ledger.liabilityUsd(address(mgov), 1), 500e18, "anchored: top-up does not inflate the filing bond");
    }

    /// @notice Same attack as the read-side test above, run through
    ///         `settleCoverage`: a post-execution top-up must not let a
    ///         rebook or the residue top-up recover more than the anchored
    ///         basis allows.
    function test_settleCoverage_postExecutionTopUpCannotUndoAPriceCrash() public {
        _wireRecording();
        mgov.set(1_000e6); // needUsd = $1,000
        mgov.setSchedule(block.timestamp + 1 days, 3 days);

        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);
        assertEq(ledger.openExposureUsd(guardian), 1_000e18, "reserved the full coverage");

        mgov.setExecutedAt(block.timestamp); // anchor snapshots 100,000 WOOD

        skip(31 days); // past executeBy: settleCoverage's window gate opens
        twap.setPrice(0.005e8); // 10x crash: live bond now $500 < $1,000 reserved

        // Top up post-execution, post-crash: live bond restored to $1,000.
        swood.setStake(guardian, 200_000e18);
        assertEq(ledger.slashableBondUsd(guardian), 1_000e18, "sanity: live bond restored by the top-up");

        ledger.settleCoverage(address(mgov), 1);

        // Settlement books the guardian at the ANCHORED basis: $500, not the
        // top-up-restored $1,000. A conviction anchored at execution could
        // never have reached the top-up tranche.
        assertEq(
            ledger.allocatedUsd(address(mgov), 1, guardian),
            500e18,
            "settle: anchored basis, top-up buys no extra booking"
        );
        assertEq(ledger.openExposureUsd(guardian), 500e18, "settle: bucket reflects the anchored booking only");
    }

    /// @notice Spec: "an unexecuted proposal (`executedAt == 0`) settles on
    ///         the live basis unchanged." Contrast with the two tests above:
    ///         with NO anchor (never executed, only the review window
    ///         closed), the same price-crash-then-top-up sequence DOES
    ///         restore the booking, because live is all there is to read and
    ///         a live-priced bond is genuinely reachable capital -- there is
    ///         no verdict to bound it against.
    function test_settleCoverage_unexecutedProposal_topUpDoesRestoreTheLiveBooking() public {
        _wireRecording();
        mgov.set(1_000e6);
        mgov.setSchedule(block.timestamp + 1 days, 3 days);
        // executedAt intentionally left at 0: no verdict anchor exists.

        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);

        skip(31 days);
        twap.setPrice(0.005e8);
        swood.setStake(guardian, 200_000e18); // restores live bond to $1,000

        ledger.settleCoverage(address(mgov), 1);

        assertEq(
            ledger.allocatedUsd(address(mgov), 1, guardian),
            1_000e18,
            "no anchor: live basis, the top-up genuinely restores reachable coverage"
        );
    }

    /// @notice Pashov audit finding 2 (hardening #35, confidence 85): a
    ///         guardian's shared live stake was not reserved across
    ///         simultaneously-open anchored proposals, so two
    ///         individually-correct anchored reads could sum to MORE than the
    ///         guardian's one, finite, shared recoverable pool.
    ///
    ///         Reproduces the audit's own numeric trace: guardian g approves
    ///         TWO independent proposals (P1, P2), each reserving $400 of a
    ///         $1,000 bond ($800 total, legally within the k=1 batching cap).
    ///         Both execute, each stamping its own anchor. An UNRELATED
    ///         conviction (never modelled here beyond its effect: a plain
    ///         `swood.setStake` write, exactly what a real slash does to live
    ///         stake) then drops g's LIVE stake to $600 — below the $800 the
    ///         two proposals together still claim.
    ///
    ///         Pre-fix, `liabilityUsd`/`allocatedUsd` each independently
    ///         computed `min(reserved=$400, slashableBondUsd(g, anchor)=$600)
    ///         = $400` for BOTH proposals — $800 claimed against $600 real,
    ///         exactly the audit's proof. Post-fix, `_sharedSlashableUsd`
    ///         pro-rates g's $600 slashable basis across BOTH proposals'
    ///         $400 shares of g's $800 total open exposure ($600 * 400 / 800
    ///         = $300 each), so the two reads sum to exactly $600 — g's real
    ///         remaining recoverable stake, never more.
    ///
    ///         THE INVARIANT THIS TEST PROVES: for any guardian g, the sum
    ///         over all currently-open anchored proposals of that proposal's
    ///         claimed-recoverable-from-g must never exceed g's actual
    ///         live/anchored recoverable stake. Checked on BOTH `liabilityUsd`
    ///         (what the audit's own proof used — `ChallengeGame.file()`'s
    ///         bond-sizing basis) and `allocatedUsd` (the guardian-fee
    ///         attribution basis the audit's finding 1 proof separately
    ///         exploited via a different mechanism).
    function test_finding2_sharedStakeAcrossOpenProposalsNeverOversumsTheRealRecoverableBond() public {
        _wireRecording();
        // Override `_wireRecording`'s $5,000 fixture stake down to $1,000, so
        // the numbers here match the audit's own trace exactly (1,000 WOOD
        // basis, $1/WOOD in the audit's telling; here 20,000 WOOD at the
        // fixture's $0.05, same $1,000).
        swood.setStake(guardian, 20_000e18);
        assertEq(ledger.slashableBondUsd(guardian), 1_000e18, "sanity: $1,000 bond before either proposal");

        // P1: reserves $400 of the $1,000 bond.
        mgov.set(400e6);
        mgov.setSchedule(block.timestamp + 1 days, 3 days);
        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);
        assertEq(ledger.openExposureUsd(guardian), 400e18, "P1 books its $400 reservation");
        mgov.setExecutedAt(block.timestamp); // anchor A

        skip(1 days);

        // P2: reserves the OTHER $400 — both fit inside the $1,000 cap
        // (open $400 + free $600 >= needUsd $400), exactly the audit's
        // "legally books shared exposure under the k-multiplier design".
        MockGovernorForLedger mgov2 = _secondGovernor(400e6, 3 days);
        vm.prank(registry);
        ledger.recordApproval(address(mgov2), 1, guardian);
        assertEq(ledger.openExposureUsd(guardian), 800e18, "both proposals booked: $800 of the $1,000 cap");
        mgov2.setExecutedAt(block.timestamp); // anchor B, strictly later than A

        // The unrelated conviction: g's live stake drops to $600 — below the
        // $800 the two EXECUTED proposals still jointly claim. This is a bare
        // `setStake` write standing in for a real slash's effect on live
        // stake; nothing about P1 or P2 themselves changes.
        swood.setStake(guardian, 12_000e18);
        assertEq(ledger.slashableBondUsd(guardian), 600e18, "live bond crashed to $600 on the unrelated conviction");

        // THE INVARIANT: both proposals' independently-read `liabilityUsd`
        // must sum to AT MOST g's real $600 — never the $800 both would have
        // reported pre-fix.
        uint256 liabilityP1 = ledger.liabilityUsd(address(mgov), 1);
        uint256 liabilityP2 = ledger.liabilityUsd(address(mgov2), 1);
        assertLe(
            liabilityP1 + liabilityP2,
            ledger.slashableBondUsd(guardian),
            "sum of both proposals' liabilityUsd must never exceed g's real recoverable stake"
        );
        // Exact, not just bounded: pro-rata over two equal $400 shares of an
        // $800 total splits g's $600 evenly.
        assertEq(liabilityP1, 300e18, "P1's pro-rata share of the $600 real bond");
        assertEq(liabilityP2, 300e18, "P2's pro-rata share of the $600 real bond");

        // Same invariant on `allocatedUsd` — the guardian-fee attribution
        // basis. Sole approver on each proposal, so `allocatedUsd` here
        // equals the same pro-rata share `liabilityUsd` computed.
        uint256 allocatedP1 = ledger.allocatedUsd(address(mgov), 1, guardian);
        uint256 allocatedP2 = ledger.allocatedUsd(address(mgov2), 1, guardian);
        assertLe(
            allocatedP1 + allocatedP2,
            ledger.slashableBondUsd(guardian),
            "sum of both proposals' allocatedUsd must never exceed g's real recoverable stake"
        );
        assertEq(allocatedP1, 300e18);
        assertEq(allocatedP2, 300e18);
    }

    /// @notice A guardian backing only ONE open proposal sees no change from
    ///         the finding-2 fix: `_sharedSlashableUsd`'s pro-rata ratio
    ///         reduces algebraically to the pre-fix `min(reserved,
    ///         slashable)` whenever `openExposureUsd(g) == reserved` for that
    ///         guardian's one commitment. Regression guard for the common
    ///         case, alongside the fuller re-derivation already covered by
    ///         `test_allocatedUsd_and_liabilityUsd_postExecutionTopUpCannotUndoAPriceCrash`.
    function test_finding2_singleOpenProposalIsUnaffectedByTheSharedStakeFix() public {
        _wireRecording();
        mgov.set(1_000e6);
        mgov.setSchedule(block.timestamp + 1 days, 3 days);

        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);
        mgov.setExecutedAt(block.timestamp);

        skip(1 hours);
        swood.setStake(guardian, 50_000e18); // live bond now $2,500, below the $5,000 checkpoint at anchor

        assertEq(
            ledger.liabilityUsd(address(mgov), 1),
            1_000e18,
            "one open proposal: liabilityUsd unaffected by the sharing fix"
        );
        assertEq(
            ledger.allocatedUsd(address(mgov), 1, guardian),
            1_000e18,
            "one open proposal: allocatedUsd unaffected by the sharing fix"
        );
    }

    /// @notice The haircut must apply to EVERY branch, including the one where
    ///         the cap is what bound.
    ///
    ///         While `woodHaircutBps` sits at its 10_000 default every branch
    ///         agrees and nothing is visibly wrong, which is why the original
    ///         tests passed either way. The inconsistency only appears once
    ///         governance turns the haircut on — so this test turns it on, and
    ///         walks all three branches under it.
    function test_woodPrice_haircutAppliesToEveryBranch() public {
        MockFeed woodFeed = new MockFeed(0.05e8, 8);
        vm.startPrank(owner);
        ledger.setWoodFeed(address(woodFeed), 1 hours);
        ledger.setWoodHaircutBps(8_000); // 20% haircut
        vm.stopPrank();

        assertEq(ledger.woodPriceX8(), 0.04e8, "feed branch: 0.8x the aggregator");

        skip(2 hours); // aggregator goes stale -> TWAP branch
        assertEq(ledger.woodPriceX8(), 0.04e8, "TWAP branch: 0.8x the market, NOT raw 0.05e8");

        twap.setPrice(20 * CAP_X8); // cap-bound branch
        assertEq(ledger.woodPriceX8(), (CAP_X8 * 8_000) / 10_000, "capped branch: 0.8x the CAP, not the raw cap");

        // And it flows through to bond valuation, which is what a looser
        // batching cap would have come from.
        twap.setPrice(MARKET_X8);
        swood.setStake(guardian, 100_000e18);
        assertEq(ledger.slashableBondUsd(guardian), 4_000e18, "not the 5_000 an unhaircut branch would give");
    }

    /// @notice `woodHaircutBps` IS THE ALLOWANCE against the two overstatements
    ///         this design accepts rather than eliminates — and at its 10_000
    ///         default that allowance is exactly zero.
    ///
    /// @dev    The accepted overstatements are (a) the oracle's two legs not
    ///         being contemporaneous, so an ETH drawdown inside the ~10.7h
    ///         ETH/USD heartbeat makes WOOD/USD read high by roughly the ETH
    ///         move — with no attacker capital involved; and (b) the residual
    ///         crash lag of up to `twapWindow + maxTwapAge`. Both were accepted
    ///         (owner decision 2026-08-02) because the alternative — coupling
    ///         `ethUsdMaxDelay` to `twapWindow` — forces a ~12h averaging
    ///         window and half a day of blindness to a WOOD crash.
    ///
    ///         That makes this parameter load-bearing, so the claim is pinned:
    ///         a source overstated 2x, priced at a 5_000 haircut, values bonds
    ///         at their TRUE worth rather than at double it. The cap is held
    ///         deliberately NON-BINDING here — the overstated source lands
    ///         exactly on it — so the haircut is doing the work alone and the
    ///         test cannot pass for the wrong reason.
    function test_woodHaircut_absorbsAnOverstatedMarketSource() public {
        swood.setStake(guardian, 100_000e18);
        uint256 trueBondUsd = 5_000e18; // 100k WOOD at the true $0.05

        // The oracle reads 2x high — an ETH drawdown inside the heartbeat.
        twap.setPrice(2 * MARKET_X8);
        (,, bool binding) = ledger.woodPriceDetail();
        assertFalse(binding, "the cap must NOT be what absorbs this, or the test proves nothing");
        assertEq(ledger.slashableBondUsd(guardian), 2 * trueBondUsd, "no haircut: the overstatement lands in full");

        // With the allowance seated, the same overstatement is absorbed.
        vm.prank(owner);
        ledger.setWoodHaircutBps(5_000);
        assertEq(ledger.slashableBondUsd(guardian), trueBondUsd, "the haircut absorbs a 2x overstatement exactly");

        // And it is paid for in normal operation, which is the trade: an
        // unexaggerated market is valued at half.
        twap.setPrice(MARKET_X8);
        assertEq(ledger.slashableBondUsd(guardian), trueBondUsd / 2, "the allowance costs conservatism when healthy");
    }

    /// @notice THE SHIPPED VALUE, 7,000 — a 30% allowance. Pinned here as the
    ///         behaviour it buys, not merely as a number in a deploy script.
    ///
    /// @dev    `DeployPlanB` seats this as its `DEFAULT_WOOD_HAIRCUT_BPS`, with
    ///         a pre-flight refusing the ledger's own 10,000 default; 5,000 was
    ///         rejected as too costly to guardian return on equity. What 7,000
    ///         buys, exactly: every source is valued at 70%, so an overstatement
    ///         up to 1/0.7 — about +42.9% — still values bonds at or below their
    ///         true worth. A 30% overstatement, the sizing case, leaves margin.
    function test_woodHaircut_shippedValueAbsorbsAThirtyPercentOverstatement() public {
        swood.setStake(guardian, 100_000e18);
        uint256 trueBondUsd = 5_000e18; // 100k WOOD at the true $0.05

        vm.prank(owner);
        ledger.setWoodHaircutBps(7_000);

        // Healthy market: bonds carry the 30% discount. That is what the
        // allowance costs in normal operation.
        assertEq(ledger.woodPriceX8(), (MARKET_X8 * 7_000) / 10_000);
        assertEq(ledger.slashableBondUsd(guardian), (trueBondUsd * 7_000) / 10_000);

        // A 30% overstatement — the sizing case — still leaves bonds valued
        // BELOW their true worth, which is the property being bought.
        twap.setPrice((MARKET_X8 * 13_000) / 10_000);
        (,, bool binding) = ledger.woodPriceDetail();
        assertFalse(binding, "the cap must not be what absorbs this, or the test proves nothing");
        assertLt(ledger.slashableBondUsd(guardian), trueBondUsd, "a 30% overstatement is fully absorbed");

        // Break-even: at +1/0.7 the discount exactly cancels the error, so bonds
        // land at true worth and not a wei above it.
        twap.setPrice((MARKET_X8 * 10_000) / 7_000);
        assertLe(ledger.slashableBondUsd(guardian), trueBondUsd, "break-even is the edge of the allowance");
        assertApproxEqRel(ledger.slashableBondUsd(guardian), trueBondUsd, 1e12, "and it is genuinely AT the edge");

        // Past it the overstatement starts landing — the allowance is finite,
        // and the cap is the control that takes over.
        twap.setPrice(2 * MARKET_X8);
        assertGt(ledger.slashableBondUsd(guardian), trueBondUsd, "a 2x error exceeds a 30% allowance");
    }

    /// @notice Both degraded states must be observable. Without this, "TWAP
    ///         healthy" and "cap drifted under market and has been pinning
    ///         every bond for a month" are indistinguishable from outside, and
    ///         monitoring cannot alert on a condition it cannot see.
    function test_woodPriceDetail_reportsTheSourceAndWhetherTheCapBinds() public {
        (, bool fromFeed, bool binding) = ledger.woodPriceDetail();
        assertFalse(fromFeed, "no aggregator wired -> TWAP-priced");
        assertFalse(binding, "cap above market -> not binding, which is the healthy shape");

        MockFeed woodFeed = new MockFeed(0.05e8, 8);
        vm.prank(owner);
        ledger.setWoodFeed(address(woodFeed), 1 hours);
        (, fromFeed,) = ledger.woodPriceDetail();
        assertTrue(fromFeed, "fresh aggregator -> feed-priced");

        skip(2 hours);
        (, fromFeed,) = ledger.woodPriceDetail();
        assertFalse(fromFeed, "stale aggregator -> back on the TWAP, and now visible");

        woodFeed.set(0.05e8); // fresh again
        (, fromFeed,) = ledger.woodPriceDetail();
        assertTrue(fromFeed, "recovered");

        // The signal that the CAP has drifted below market: it binds, and stays
        // bound, which means the market source has gone inert.
        woodFeed.set(int256(int256(CAP_X8) * 2));
        (,, binding) = ledger.woodPriceDetail();
        assertTrue(binding, "cap under market -> binding, the alarm to raise the number");
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
        swood.setStake(attacker, 100_000e18); // $5,000
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

    /// @notice Budget recycles once a commitment's bucket has expired — measured
    ///         against the SETTLEMENT bucket, which is what the ledger actually
    ///         keys on.
    ///
    /// @dev    This test used to run on the mock's default `executeBy = 0,
    ///         strategyDuration = 0`, which makes `coverUntil <= epochGenesis`
    ///         so `_coverageEpoch` short-circuits to `cur` — the PRE-ADR
    ///         current-epoch keying. It therefore asserted "recycles after epoch
    ///         + window", which is the property the ADR deliberately replaced:
    ///         production books into the bucket covering `executeBy +
    ///         strategyDuration`, so the budget is held until THAT bucket's
    ///         challenge window elapses, roughly a month later.
    ///
    ///         With a realistic schedule the mid-point assertion below is the
    ///         discriminating one: at epoch + window the pre-ADR keying would
    ///         have released the budget, and the shipped keying still holds it.
    function test_recordApproval_netsAcrossSequentialEpochs() public {
        _wireRecording();
        mgov.set(4_000e6);
        // Settles in epoch 1 (t0+30d), so the commitment is booked forward.
        mgov.setSchedule(block.timestamp + 25 days, 5 days);
        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);
        assertEq(ledger.currentEpoch(), 0, "voted in epoch 0...");
        assertEq(ledger.openExposureUsd(guardian), 4_000e18, "...but booked into the settlement bucket");

        // One epoch + one challenge window on from the VOTE. Under the pre-ADR
        // keying the bucket would have expired here and the budget would be
        // free while the drain it backs is still challengeable.
        // `skip` rather than `vm.warp(block.timestamp + …)`: the optimizer
        // CSE-s `block.timestamp` across a warp, so a re-read can silently
        // return the pre-warp value.
        skip(28 days + 14 days + 1);
        assertEq(ledger.openExposureUsd(guardian), 4_000e18, "still committed: the settlement bucket is live");

        // Epoch 1 runs to t0+56d and its challenge window closes at t0+70d.
        skip(28 days);
        assertEq(ledger.openExposureUsd(guardian), 0, "budget recycled once the settlement bucket expired");

        // Same guardian, a fresh proposal: would exceed the cap if netted with #1.
        mgov.setSchedule(vm.getBlockTimestamp() + 25 days, 5 days);
        vm.prank(registry);
        ledger.recordApproval(address(mgov), 2, guardian);
        assertEq(ledger.openExposureUsd(guardian), 4_000e18); // only the live bucket counts
    }

    /// @notice The batching attack (spec §3.3): one guardian cannot back two
    ///         simultaneous drains with the same bond. Its committed exposure
    ///         is capped at its bond in TOTAL across open approvals, so the
    ///         second proposal is left short and cannot reach quorum.
    /// @dev The mock carries a REALISTIC schedule here. On its default
    ///      `executeBy = 0, strategyDuration = 0` the ledger short-circuits to
    ///      current-epoch keying, so this exercised the pre-ADR bucket rather
    ///      than the shipped one. With a settlement date both proposals land in
    ///      the SAME forward-dated bucket, which is what production does and is
    ///      the configuration the batching cap has to hold under.
    function test_recordApproval_blocksSimultaneousOverExposure() public {
        _wireRecording();
        mgov.set(3_000e6);
        mgov.setSchedule(block.timestamp + 25 days, 5 days);
        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);
        assertEq(ledger.openExposureUsd(guardian), 3_000e18);

        // Second $3,000 drain: only $2,000 of budget remains, so that is all it
        // can back — total exposure is pinned at the $5,000 bond, never $6,000.
        vm.prank(registry);
        ledger.recordApproval(address(mgov), 2, guardian);
        assertEq(ledger.openExposureUsd(guardian), 5_000e18, "total exposure capped at the bond");

        // Proposal 1 stays fully covered; proposal 2 is under-covered — a
        // nonzero shortfall now SIZES (issue #27) rather than blocking
        // execution outright, so it returns the raised/required pair instead
        // of reverting.
        ledger.requireApproveQuorum(address(mgov), 1, usdgAsset, 3_000e6);
        (uint256 coverageRaisedUsd, uint256 requiredCoverageUsd) =
            ledger.requireApproveQuorum(address(mgov), 2, usdgAsset, 3_000e6);
        assertEq(coverageRaisedUsd, 2_000e18, "only the remaining $2,000 of budget backs proposal 2");
        assertEq(requiredCoverageUsd, 3_000e18);
    }

    // EARLY-EXIT INTENDED: `recordApproval`'s no-free-budget return. This test IS
    // that exit — the second approval books nothing and the guardian is never
    // listed for proposal 2, which is the asserted behaviour rather than a
    // fixture that lost an approver by accident. (A stale line here used to claim
    // the opposite, "an approve reverts outright"; N1 replaced that revert with
    // this return.)
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
        swood.setStake(guardian, type(uint96).max);
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
    ///
    /// @dev    THE ARITHMETIC IS PINNED DELIBERATELY, because the obvious
    ///         version of this test cannot fail. Its comment used to claim g2
    ///         "commits the $2,000 remainder"; under the shipped
    ///         FULL-reservation rule g2 reserves its own $3,000 budget, so the
    ///         reservations total $6,000, not $5,000. Checking only "covered at
    ///         $5,000, uncovered at $7,000" passes identically under both rules
    ///         — 3,000 + 2,000 = 5,000 also clears $5,000 and also misses
    ///         $7,000 — so the test read as cover for the C1 regression while
    ///         being blind to it.
    ///
    ///         Two things discriminate: the per-approver commitments, and a
    ///         threshold BETWEEN the two totals. $6,000 is covered under the
    ///         reservation rule and uncovered under the remainder rule.
    function test_approveQuorum_sumOfCommittedSharesCoversCoverage() public {
        _wireRecording();
        address g2 = makeAddr("g2");
        swood.setStake(guardian, 60_000e18); // $3,000
        swood.setStake(g2, 60_000e18); // $3,000
        mgov.set(5_000e6); // $5,000 needed

        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian); // reserves its whole $3,000
        vm.prank(registry);
        // NOT the $2,000 remainder: g2 reserves its own $3,000 too, because it
        // might end up carrying the proposal alone. That is what closed C1.
        ledger.recordApproval(address(mgov), 1, g2);

        (address[] memory approvers, uint256[] memory committed) = ledger.approversOf(address(mgov), 1);
        assertEq(approvers.length, 2);
        assertEq(committed[0], 3_000e18, "first approver reserves its whole budget");
        assertEq(committed[1], 3_000e18, "second reserves its own budget, not the remainder");

        // $3,000 + $3,000 == $6,000 of reservations.
        ledger.requireApproveQuorum(address(mgov), 1, usdgAsset, 5_000e6);
        // The discriminating threshold: only the reservation rule clears this.
        ledger.requireApproveQuorum(address(mgov), 1, usdgAsset, 6_000e6);
        // Asking for more than was ever committed no longer fails outright
        // (issue #27) — the aggregate is reported CLAMPED at what was
        // actually committed ($6,000), never inflated to meet the ask, so the
        // governor sizes execution to 6/7 instead of blocking it.
        (uint256 coverageRaisedUsd, uint256 requiredCoverageUsd) =
            ledger.requireApproveQuorum(address(mgov), 1, usdgAsset, 7_000e6);
        assertEq(coverageRaisedUsd, 6_000e18, "capped at the cohort's actual committed total");
        assertEq(requiredCoverageUsd, 7_000e18);
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
        // Nonzero-but-shrunken coverage now SIZES (issue #27) instead of
        // reverting: the crashed bond still backs $500 of the $5,000
        // required, so the governor can size execution to 1/10 instead of
        // blocking it outright.
        (uint256 coverageRaisedUsd, uint256 requiredCoverageUsd) =
            ledger.requireApproveQuorum(address(mgov), 1, usdgAsset, 5_000e6);
        assertEq(coverageRaisedUsd, 500e18, "live leg shrank with the price crash");
        assertEq(requiredCoverageUsd, 5_000e18);
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
        // Same production shape as the main fixture: market-priced at $0.05,
        // cap 2x above it and not binding.
        MockWoodTwapOracle ledTwap = new MockWoodTwapOracle(MARKET_X8);
        vm.startPrank(owner);
        led.setAssetFeed(usdgAsset, address(feed), 365 days);
        led.setGuardianRegistry(registry);
        led.setWoodUsdPrice(CAP_X8);
        led.setWoodTwapOracle(address(ledTwap));
        vm.stopPrank();
        swood.setStake(guardian, 400_000e18); // $20,000 budget

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
        swood.setStake(guardian, 1e60);
        mgov.set(1e25);
        vm.prank(registry);
        vm.expectRevert(IExposureLedger.InvalidParameter.selector);
        ledger.recordApproval(address(mgov), 1, guardian);
    }

    /// @notice PUNITIVE, NOT COMPENSATORY. Every approver still holding a live
    ///         commitment carries the SAME rate — the ceiling — regardless of
    ///         how much each underwrote or how large their bond is. The old
    ///         behaviour derived a per-approver rate from their share of the
    ///         loss, which capped the penalty at break-even; the burn removed
    ///         the windfall constraint that forced it.
    function test_slashBpsFor_uniformCeilingRegardlessOfCommitmentOrBond() public {
        _wireRecording();
        address g2 = makeAddr("g2");
        swood.setStake(g2, 50_000e18); // $2,500 bond vs the guardian's $5,000
        mgov.set(2_000e6); // $2,000 needed — either could carry it alone

        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);
        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, g2);

        // The allocation still exists and is still even ($1,000 each) — the
        // coverage GATE reads it. The slash simply does not.
        assertEq(ledger.allocatedUsd(address(mgov), 1, guardian), 1_000e18);
        assertEq(ledger.allocatedUsd(address(mgov), 1, g2), 1_000e18);

        (address[] memory approvers, uint256[] memory bps) = ledger.slashBpsFor(address(mgov), 1);

        assertEq(approvers.length, 2, "both approvers listed");
        assertEq(approvers[0], guardian);
        assertEq(approvers[1], g2);
        // Same rate despite a 2x difference in bond size. Under the old
        // allocation these were 2,000 and 4,000 bps.
        assertEq(bps[0], 10_000, "the ceiling, not a share of the loss");
        assertEq(bps[1], 10_000, "and the same for the smaller bond");
    }

    /// @notice THE RATE IS INDEPENDENT OF THE LOSS. A proposal that understates
    ///         what it can actually extract used to buy its approvers a
    ///         proportionally smaller slash — mis-declaring coverage was a
    ///         direct discount on the penalty. It buys nothing now.
    function test_slashBpsFor_unmovedByRequiredCoverage() public {
        _wireRecording();
        mgov.set(5_000e6); // books the full $5,000 bond

        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);

        (, uint256[] memory bpsHigh) = ledger.slashBpsFor(address(mgov), 1);
        assertEq(bpsHigh[0], 10_000);

        // Same approver, same bond, a twentieth of the declared coverage. The
        // old allocation would have derived a proportionally smaller rate.
        mgov.set(250e6);
        (, uint256[] memory bpsLow) = ledger.slashBpsFor(address(mgov), 1);
        assertEq(bpsLow[0], 10_000, "understating the loss does not shrink the slash");
    }

    /// @notice AND INDEPENDENT OF EVERY PRICE READ. The allocation this
    ///         replaced priced BOTH operands — the asset feed in the numerator
    ///         (behind a `StalePrice` gate) and `woodPriceX8()` in the
    ///         denominator — so a stale feed made a conviction UNPRICEABLE and
    ///         reverted this view, precisely during the market stress a drain
    ///         happens in. Removing the division removed that liveness hole;
    ///         this pins it shut.
    function test_slashBpsFor_unmovedByTheWoodPrice() public {
        _wireRecording();
        mgov.set(2_000e6);

        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);

        (, uint256[] memory bpsBefore) = ledger.slashBpsFor(address(mgov), 1);
        assertEq(bpsBefore[0], 10_000, "baseline: governance scalar, no haircut");

        // A feed at 2x the scalar. Under the allocation this halved the rate.
        MockFeed woodFeed = new MockFeed(0.1e8, 8);
        vm.prank(owner);
        ledger.setWoodFeed(address(woodFeed), 1 days);
        assertEq(ledger.woodPriceX8(), 0.1e8, "feed supersedes the scalar");
        (, uint256[] memory bpsFeed) = ledger.slashBpsFor(address(mgov), 1);
        assertEq(bpsFeed[0], 10_000, "rate does not track the feed");

        // A 50% haircut. Under the allocation this doubled the rate.
        vm.prank(owner);
        ledger.setWoodHaircutBps(5_000);
        assertEq(ledger.woodPriceX8(), 0.05e8, "haircut applies to the feed");
        (, uint256[] memory bpsHaircut) = ledger.slashBpsFor(address(mgov), 1);
        assertEq(bpsHaircut[0], 10_000, "nor the haircut");
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

    /// @notice A bond that SHRANK after the vote — unstaking, or a WOOD price
    ///         crash — still yields the ceiling. This used to be a SATURATING
    ///         case worth its own test, because the derived rate could land
    ///         anywhere below 100% and only pinned there once the commitment
    ///         exceeded the live bond. There is no division left to saturate;
    ///         the rate was already the ceiling. What still matters is
    ///         downstream: `_slashOne` clamps to live stake, so a shrunken bond
    ///         yields whatever remains of it rather than reverting.
    function test_slashBpsFor_ceilingHoldsWhenTheBondShrank() public {
        _wireRecording();
        mgov.set(5_000e6); // books the full $5,000 bond

        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);

        swood.setStake(guardian, 50_000e18); // bond halves to $2,500

        (, uint256[] memory bps) = ledger.slashBpsFor(address(mgov), 1);
        assertEq(bps[0], 10_000, "everything the guardian still has");
    }

    /// @notice `approversOf` is the challenge game's read of who covered a
    ///         proposal (Plan D). It reports RESERVATIONS, not allocations.
    function test_approversOf_listsCommittedApprovers() public {
        _wireRecording();
        address g2 = makeAddr("g2");
        swood.setStake(g2, 100_000e18);
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

    // ── NoWoodPrice: the halting semantics, one test per consumer ──────────
    //
    // Revision 2 deleted the fallback price, so `NoWoodPrice` is REACHABLE in
    // production: no Chainlink WOOD feed on 4663, plus a TWAP that has gone
    // stale, and nothing can price a bond. The design's whole claim is that
    // this is a clean fail-safe rather than a halt, and that claim is exactly
    // one table of per-consumer decisions. Each row gets a test, because a
    // silent flip of any of them reintroduces the block-only review that three
    // review rounds were spent removing.

    /// @dev Put the ledger into the "no market data at all" state that the
    ///      halting table is about: no aggregator wired (the 4663 reality) and
    ///      a TWAP reporting unavailable.
    function _killAllPriceSources() internal {
        twap.setAvailable(false);
        vm.expectRevert(IExposureLedger.NoWoodPrice.selector);
        ledger.woodPriceX8();
    }

    /// @notice THE LOAD-BEARING ROW. `recordApproval` must CATCH `NoWoodPrice`
    ///         and book nothing.
    ///
    /// @dev    Reverting here disenfranchises the approve side while Block
    ///         votes keep landing, so guardians could veto but never endorse
    ///         and the proposal would pass optimistically anyway — the
    ///         block-only review that reviews M3, N1 and N4 each removed, this
    ///         time reintroduced through the price path. Booking nothing is the
    ///         conservative half: the commitment is not made, so the
    ///         execute-time quorum fails loudly instead.
    function test_recordApproval_booksNothingWhenNoSourceCanPriceWood() public {
        _wireRecording();
        mgov.set(1_000e6);
        _killAllPriceSources();

        // MUST NOT REVERT.
        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);

        assertEq(ledger.openExposureUsd(guardian), 0, "unpriceable WOOD: booked nothing, vote survives");
        (address[] memory gs,) = ledger.approversOf(address(mgov), 1);
        assertEq(gs.length, 0, "and was not listed as a covering approver");

        // The cap still binds at execute: nothing was booked, so the quorum
        // cannot be met. Recovery is a real price coming back, not a retry.
        twap.setAvailable(true);
        vm.expectRevert(IExposureLedger.InsufficientApproveCoverage.selector);
        ledger.requireApproveQuorum(address(mgov), 1, usdgAsset, 1_000e6);
    }

    /// @notice EXECUTION HALTS, and that is correct: no price means no proof of
    ///         coverage, and executing on an unprovable coverage claim is the
    ///         exact outcome the gate exists to refuse.
    function test_requireApproveQuorum_revertsWhenNoSourceCanPriceWood() public {
        _wireRecording();
        mgov.set(1_000e6);

        // Book real coverage first, so the revert is about the PRICE and not
        // about an empty approver list.
        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);
        ledger.requireApproveQuorum(address(mgov), 1, usdgAsset, 1_000e6); // healthy

        _killAllPriceSources();
        vm.expectRevert(IExposureLedger.NoWoodPrice.selector);
        ledger.requireApproveQuorum(address(mgov), 1, usdgAsset, 1_000e6);
    }

    /// @notice PROPOSAL CREATION HALTS. `SyndicateGovernor.propose` sizes the
    ///         proposer bond through this view, so new risk cannot be admitted
    ///         unpriced.
    function test_proposerBondWood_revertsWhenNoSourceCanPriceWood() public {
        _wireRecording();
        assertGt(ledger.proposerBondWood(usdgAsset, 1_000e6), 0, "healthy: a bond is sizeable");

        _killAllPriceSources();
        vm.expectRevert(IExposureLedger.NoWoodPrice.selector);
        ledger.proposerBondWood(usdgAsset, 1_000e6);
    }

    /// @notice The conviction-sizing views halt too. `ChallengeGame.file`
    ///         catches `liabilityUsd` but then reads `woodPriceX8()` directly,
    ///         so filing halts as well — acceptable, because the challenge
    ///         window is 14 days against staleness measured in hours.
    function test_allocatedAndLiabilityViews_revertWhenNoSourceCanPriceWood() public {
        _wireRecording();
        mgov.set(1_000e6);
        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);

        _killAllPriceSources();
        vm.expectRevert(IExposureLedger.NoWoodPrice.selector);
        ledger.allocatedUsd(address(mgov), 1, guardian);
        vm.expectRevert(IExposureLedger.NoWoodPrice.selector);
        ledger.liabilityUsd(address(mgov), 1);
    }

    /// @notice The slash rail is OUT of the price's blast radius (PR #102), so
    ///         a conviction is still computable through a total price outage.
    ///         That is the property that let the fallback be deleted at all.
    function test_slashBpsFor_survivesATotalPriceOutage() public {
        _wireRecording();
        mgov.set(1_000e6);
        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);

        _killAllPriceSources();
        (address[] memory gs, uint256[] memory bps) = ledger.slashBpsFor(address(mgov), 1);
        assertEq(gs.length, 1);
        assertEq(bps[0], 10_000, "punitive rate reads no price and is unaffected");
    }

    // ── The emergency lever ────────────────────────────────────────────────

    /// @notice The brake works, AND IT WORKS UNDER A NON-DEFAULT HAIRCUT.
    ///
    /// @dev    Finding 6 (`_haircut(1) == 0`) passed CI only because the
    ///         fixture left `woodHaircutBps` at 10_000, where the haircut is
    ///         the identity and no truncation is possible. With a real haircut
    ///         seated, a cap of 1 wei-X8 truncates to a price of ZERO — and
    ///         zero is not "very cheap" to the consumers: `ChallengeGame.file`
    ///         reverts `WoodPriceUnset` on it and `proposerBondWood` reverts
    ///         `InvalidParameter`, so pulling the brake to a small non-zero
    ///         value would have bricked the paths governance still needs.
    ///         The floor at 1 keeps them alive at a valuation that is still,
    ///         correctly, negligible.
    function test_emergencyLever_lowersThePriceUnderANonDefaultHaircut() public {
        _wireRecording(); // stakes the guardian and seats the USDG feed
        vm.prank(owner);
        ledger.setWoodHaircutBps(5_000); // the floor: half of market

        assertEq(ledger.woodPriceX8(), MARKET_X8 / 2, "haircut seated, market still above the cap-free path");
        assertEq(ledger.slashableBondUsd(guardian), 2_500e18);

        // EVERY PULL BELOW HAPPENS IN THE SAME BLOCK, with no `skip`. That is
        // the crisis shape issue #89 was about: a crash deepens faster than a
        // daily interval allows, and under the old in-contract rate limit the
        // second pull here reverted and the brake was spent until tomorrow.
        //
        // Pull the brake hard. The cap now binds and drags everything with it.
        vm.prank(owner);
        ledger.setWoodUsdPrice(0.001e8);
        assertEq(ledger.woodPriceX8(), 0.0005e8, "the brake bites through the haircut");
        assertEq(ledger.slashableBondUsd(guardian), 50e18, "every bond revalued");

        // All the way down to a cap of 1 wei-X8: the haircut would truncate
        // this to zero, which is the finding. It must floor at 1 instead.
        vm.prank(owner);
        ledger.setWoodUsdPrice(1);
        assertEq(ledger.woodPriceX8(), 1, "floored at 1, NOT truncated to 0 by the haircut");
        assertGt(ledger.proposerBondWood(usdgAsset, 1_000e6), 0, "the bond path stays alive");

        // And zero is a STOP, not a $0 valuation.
        vm.prank(owner);
        ledger.setWoodUsdPrice(0);
        vm.expectRevert(IExposureLedger.NoWoodPrice.selector);
        ledger.woodPriceX8();
    }

    // ── Wiring the oracle ──────────────────────────────────────────────────

    /// @notice The pair is VALIDATED before it is trusted. Four WOOD/WETH V3
    ///         pools on 4663 are initialised-but-never-traded shells whose
    ///         `getPool` returns a non-zero address, so "does it exist?" is not
    ///         a check. The V2 analogue would price guardian collateral off an
    ///         unrelated market.
    function test_setWoodTwapOracle_refusesAnOracleWhosePairDoesNotValidate() public {
        MockWoodTwapOracle bad = new MockWoodTwapOracle(MARKET_X8);
        bad.setPairValid(false);
        vm.prank(owner);
        vm.expectRevert(IExposureLedger.InvalidParameter.selector);
        ledger.setWoodTwapOracle(address(bad));
    }

    /// @notice An EOA (or any codeless address) is refused before it is called.
    ///         The extcodesize guard on a high-level call reverts in the
    ///         caller's frame, where no `try` could catch it.
    function test_setWoodTwapOracle_refusesACodelessAddress() public {
        vm.prank(owner);
        vm.expectRevert(IExposureLedger.InvalidParameter.selector);
        ledger.setWoodTwapOracle(makeAddr("notAContract"));
    }

    function test_setWoodTwapOracle_refusesAnOracleThatRevertsOnValidate() public {
        MockWoodTwapOracle bad = new MockWoodTwapOracle(MARKET_X8);
        bad.setValidateReverts(true);
        vm.prank(owner);
        vm.expectRevert(IExposureLedger.InvalidParameter.selector);
        ledger.setWoodTwapOracle(address(bad));
    }

    function test_setWoodTwapOracle_isOwnerOnly() public {
        MockWoodTwapOracle other = new MockWoodTwapOracle(MARKET_X8);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        ledger.setWoodTwapOracle(address(other));
    }

    /// @notice Unwiring to zero is accepted — the rotation path — but it is NOT
    ///         a safe resting state: with no aggregator on 4663 it leaves the
    ///         ledger with no price source at all.
    function test_setWoodTwapOracle_unwireIsAcceptedAndLeavesNoPriceSource() public {
        vm.prank(owner);
        ledger.setWoodTwapOracle(address(0));
        assertEq(ledger.woodTwapOracle(), address(0));

        vm.expectRevert(IExposureLedger.NoWoodPrice.selector);
        ledger.woodPriceX8();

        // Rotation: a replacement restores pricing in one transaction.
        MockWoodTwapOracle replacement = new MockWoodTwapOracle(0.06e8);
        vm.prank(owner);
        ledger.setWoodTwapOracle(address(replacement));
        assertEq(ledger.woodPriceX8(), 0.06e8);
    }

    /// @notice A wired oracle that later REVERTS on `consult()` must not take
    ///         the price path down with it — it degrades to unavailable, which
    ///         here means `NoWoodPrice` (no aggregator) rather than a bubbled
    ///         `"oracle down"`.
    function test_woodPrice_revertingOracleIsUnavailableRatherThanFatal() public {
        twap.setConsultReverts(true);
        vm.expectRevert(IExposureLedger.NoWoodPrice.selector);
        ledger.woodPriceX8();

        // With an aggregator wired, the same broken oracle costs nothing at all.
        MockFeed woodFeed = new MockFeed(0.07e8, 8);
        vm.prank(owner);
        ledger.setWoodFeed(address(woodFeed), 1 days);
        assertEq(ledger.woodPriceX8(), 0.07e8, "a dead oracle is invisible while the feed is healthy");
    }

    /// @notice THE DIRTY-BOOLEAN SHAPE, which is why the availability flag is
    ///         decoded as a `uint256`.
    ///
    /// @dev    `abi.decode(ret, (uint256, bool))` REVERTS on any second word
    ///         outside {0, 1}, and it reverts in the DECODER's frame — no `try`
    ///         can catch it. A wired contract returning a dirty word would
    ///         therefore take every price read down protocol-wide, turning a
    ///         defensive wrapper into the very failure it was written to
    ///         prevent. Decoded as a `uint256` and compared against 1, the same
    ///         answer is simply "unavailable".
    function test_woodPrice_dirtyAvailabilityWordIsUnavailableNotUndecodable() public {
        DirtyFlagWoodTwapOracle dirty = new DirtyFlagWoodTwapOracle(MARKET_X8);
        vm.prank(owner);
        ledger.setWoodTwapOracle(address(dirty));

        // NoWoodPrice — the ledger's own error — rather than a decode panic.
        vm.expectRevert(IExposureLedger.NoWoodPrice.selector);
        ledger.woodPriceX8();
    }

    /// @notice Short return data is rejected on LENGTH, before `abi.decode`
    ///         gets a chance to revert on it.
    function test_woodPrice_shortOracleReturnIsUnavailable() public {
        ShortReturnWoodTwapOracle short = new ShortReturnWoodTwapOracle();
        vm.prank(owner);
        ledger.setWoodTwapOracle(address(short));

        vm.expectRevert(IExposureLedger.NoWoodPrice.selector);
        ledger.woodPriceX8();
    }

    /// @notice A zero TWAP is refused rather than served. `min(0, cap)` would
    ///         drag every bond's valuation to nothing exactly as silently as
    ///         the failure this design was built to remove.
    function test_woodPrice_zeroTwapIsUnavailableRatherThanAZeroPrice() public {
        twap.setPrice(0);
        vm.expectRevert(IExposureLedger.NoWoodPrice.selector);
        ledger.woodPriceX8();
    }

    // ══════════════════════════════════════════════════════════════════════
    // Pashov re-audit of PR #158 (issuecomment-5165468296): findings 1-4.
    // ══════════════════════════════════════════════════════════════════════

    /// @notice FINDING 1 [88] — `requireApproveQuorum` is the ACTUAL
    ///         execute-time gate `SyndicateGovernor.executeProposal` calls,
    ///         and it was never routed through the shared-stake fix (D9):
    ///         it kept computing `live = slashableBondUsd(g)` fresh, with
    ///         nothing decremented between two proposals' independent checks.
    ///
    ///         Reproduces the audit's own proof exactly: guardian g is the
    ///         SOLE approver of two $500-need proposals, k=1, stake $1,000 —
    ///         both individually legal at booking time ($500 + $500 = the
    ///         $1,000 cap, exactly). An unrelated conviction on a THIRD
    ///         proposal (modelled, as elsewhere in this file, as a bare
    ///         `swood.setStake` write standing in for a real slash's effect
    ///         on live stake) then drops g's live stake to $600.
    function test_finding1_requireApproveQuorum_sharedAcrossOpenProposals() public {
        _wireRecording();
        swood.setStake(guardian, 20_000e18); // $1,000 bond at $0.05/WOOD
        assertEq(ledger.slashableBondUsd(guardian), 1_000e18, "sanity: $1,000 bond before either proposal");

        mgov.set(500e6);
        mgov.setSchedule(block.timestamp + 1 days, 3 days);
        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);
        assertEq(ledger.openExposureUsd(guardian), 500e18, "P1 books its $500 reservation");

        MockGovernorForLedger mgov2 = _secondGovernor(500e6, 3 days);
        vm.prank(registry);
        ledger.recordApproval(address(mgov2), 1, guardian);
        assertEq(ledger.openExposureUsd(guardian), 1_000e18, "both proposals booked: exactly at the $1,000 cap");

        // The unrelated conviction: g's live stake drops to $600 — below the
        // $1,000 the two proposals together still claim.
        swood.setStake(guardian, 12_000e18);
        assertEq(ledger.slashableBondUsd(guardian), 600e18, "live bond crashed to $600 on the unrelated conviction");

        // PRE-FIX SANITY (documented, not executed against old code): the OLD
        // `requireApproveQuorum` read `live = slashableBondUsd(g) = $600`
        // fresh for EACH call, with nothing decremented between them, so
        // `min(live, reserved) = min(600, 500) = 500 >= needUsd (500)`
        // independently for BOTH proposals — both would have passed,
        // claiming $1,000 of "verified backing" against $600 real. This
        // assertion just confirms the ingredient that made that possible:
        // g's live stake alone (with no sharing) covers either proposal's
        // need on its own.
        assertGe(
            ledger.slashableBondUsd(guardian),
            500e18,
            "pre-fix ingredient: g's unshared live stake alone would satisfy either proposal's $500 need"
        );

        // POST-FIX: both proposals now read the SAME shared pro-rata split —
        // slashable ($600) * reserved ($500) / liveBookedUsd ($1,000) = $300
        // each — which is LESS than the $500 either proposal needs. Because
        // both proposals reserved EXACTLY their own need (the sole-approver
        // case), the dilution ratio (`600/1000 = 0.6`) applies identically to
        // both: whenever a shared guardian's live stake falls below the total
        // it is backing, EVERY proposal it solely backs at its own full need
        // fails TOGETHER, rather than one arbitrarily "winning" by call
        // order. `_sharedSlashableUsd` is a pure view with no state mutation
        // (confirmed by the audit's own "ruled out" section — every call in
        // this chain is `view`/`STATICCALL`), so this holds regardless of
        // which proposal's `requireApproveQuorum` is evaluated first or
        // whether they run in the same block. This is the established,
        // symmetric pro-rata semantics `_sharedSlashableUsd` already applies
        // everywhere else (see `test_finding2_...` below) — not a new rule
        // invented for this gate. A nonzero-but-diluted aggregate now SIZES
        // (issue #27) rather than reverting — both proposals report the same
        // $300 raised against their $500 need, symmetric per the dilution
        // ratio above, so the governor sizes both DOWN together instead of
        // letting one "win" by call order.
        (uint256 coverageRaisedUsd1, uint256 requiredCoverageUsd1) =
            ledger.requireApproveQuorum(address(mgov), 1, usdgAsset, 500e6);
        assertEq(coverageRaisedUsd1, 300e18, "diluted pro-rata share, proposal 1");
        assertEq(requiredCoverageUsd1, 500e18);
        (uint256 coverageRaisedUsd2, uint256 requiredCoverageUsd2) =
            ledger.requireApproveQuorum(address(mgov2), 1, usdgAsset, 500e6);
        assertEq(coverageRaisedUsd2, 300e18, "diluted pro-rata share, proposal 2, symmetric with proposal 1");
        assertEq(requiredCoverageUsd2, 500e18);
    }

    /// @notice Companion to the test above: when the guardian's live stake
    ///         still covers the FULL total it backs (no dilution — the ratio
    ///         is >= 1), the shared quorum check passes for both proposals
    ///         exactly as it did before this fix. Proves the fix does not
    ///         spuriously block ordinary, adequately-collateralised
    ///         multi-proposal coverage.
    function test_finding1_requireApproveQuorum_stillPassesWhenSharedStakeCoversTheTotal() public {
        _wireRecording();
        swood.setStake(guardian, 20_000e18); // $1,000 bond

        mgov.set(500e6);
        mgov.setSchedule(block.timestamp + 1 days, 3 days);
        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);

        MockGovernorForLedger mgov2 = _secondGovernor(500e6, 3 days);
        vm.prank(registry);
        ledger.recordApproval(address(mgov2), 1, guardian);

        // No conviction: g's $1,000 live bond still fully covers the $1,000
        // total it backs (ratio == 1), so BOTH proposals pass — neither call
        // reverts.
        ledger.requireApproveQuorum(address(mgov), 1, usdgAsset, 500e6);
        ledger.requireApproveQuorum(address(mgov2), 1, usdgAsset, 500e6);
    }

    /// @notice FINDING 2 [85], TRIGGER 1 — ORDINARY WALL-CLOCK AGING, NO
    ///         ACTION REQUIRED (agent 9's minimal case, reproduced with this
    ///         file's own numbers). `openExposureUsd`'s bucket scan ages a
    ///         proposal's contribution out of the window on pure wall clock,
    ///         but `_recorded[key][g].usd` — the numerator every sharing
    ///         consumer reads — is cleared ONLY by an explicit
    ///         `releaseApproval`/`_rebook` write. P1 is never released or
    ///         settled here: it simply sits, exactly as the contract's own
    ///         docs say is safe to do ("`settleCoverage`... safe to skip").
    ///
    ///         Guardian g stakes 1,000 WOOD ($1,000 at $0.05). P1 (near-term
    ///         epoch) reserves $500. Time passes — no admin action, no
    ///         settlement, no release — until P1's bucket has aged out of
    ///         `openExposureUsd`'s scan window. P2 (later epoch, same
    ///         guardian) then reserves $500 against what LOOKS like a clean
    ///         $500-of-$1,000 budget (openExposureUsd already excludes P1).
    ///         An unrelated conviction drops g's live stake to $600.
    function test_finding2_trigger1_ordinaryWallClockAgingWithNoRelease() public {
        _wireRecording();
        swood.setStake(guardian, 20_000e18); // $1,000 bond at $0.05/WOOD

        // P1 books into epoch 0 (near-term settlement).
        mgov.set(500e6);
        mgov.setSchedule(block.timestamp + 1 days, 3 days);
        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);

        // 50 days pass — no release, no settlement, purely wall-clock. With
        // challengeWindow=14d and epochLength=28d, `openExposureUsd`'s
        // window now starts at epoch `(50-14)/28 = 1`, excluding P1's epoch
        // 0 — even though P1 was NEVER released and remains a live, listed
        // approver with a non-zero `_recorded` entry.
        skip(50 days);
        assertEq(ledger.openExposureUsd(guardian), 0, "P1 already aged out of the OLD denominator's scan window");

        // P2 books into a later epoch. `recordApproval`'s batching cap reads
        // `openExposureUsd == 0` (correctly, for the CAP's own recycling
        // purpose) and lets P2 book its full $500.
        MockGovernorForLedger mgov2 = _secondGovernor(500e6, 3 days);
        vm.prank(registry);
        ledger.recordApproval(address(mgov2), 1, guardian);
        assertEq(
            ledger.openExposureUsd(guardian),
            500e18,
            "the OLD denominator counts ONLY P2 -- P1 is still silently excluded"
        );

        // The unrelated conviction: g's live stake drops to $600.
        swood.setStake(guardian, 12_000e18);
        assertEq(ledger.slashableBondUsd(guardian), 600e18, "live bond crashed to $600 on the unrelated conviction");

        // PRE-FIX ARITHMETIC (documented, not executed against old code): had
        // `_sharedSlashableUsd` still divided by `openExposureUsd`, BOTH
        // proposals would independently see `openTotal == reserved == $500`
        // (P1 because its own $500 booking is the only thing IT reads via
        // `reserved`, wrongly measured against a denominator that excludes
        // itself and everything else; P2 because it happens to be the ONLY
        // thing left in the window). Both ratios reduce to 1, so BOTH would
        // report `min(600, 500) = 500` "recoverable" -- $1,000 claimed
        // against $600 real, exactly the audit's proof (a 67% overstatement
        // once P1's epoch fully drops from the scan).
        //
        // POST-FIX: `_liveBookedUsd[g]` is EXACT and non-decaying -- it still
        // holds P1's $500 (never released) PLUS P2's $500 = $1,000 -- so both
        // proposals correctly share the guardian's real $600: `600 * 500 /
        // 1000 = 300` each.
        assertEq(ledger.liabilityUsd(address(mgov), 1), 300e18, "P1's fair pro-rata share of the $600 real bond");
        assertEq(ledger.liabilityUsd(address(mgov2), 1), 300e18, "P2's fair pro-rata share of the $600 real bond");
        assertEq(
            ledger.liabilityUsd(address(mgov), 1) + ledger.liabilityUsd(address(mgov2), 1),
            ledger.slashableBondUsd(guardian),
            "the two claims sum to EXACTLY g's real recoverable stake -- never more, despite P1 aging out of openExposureUsd"
        );
    }

    /// @notice FINDING 2 [85], TRIGGER 2 — A FROZEN/PINNED PROPOSAL AGES OUT
    ///         OF THE OLD DENOMINATOR WHILE STILL LEGALLY LIVE (agent 3).
    ///         Same mechanism as trigger 1, but P1 is not merely abandoned —
    ///         it is under an ACTIVE, ongoing challenge pin
    ///         (`pinCoverageUntil`, issue #95's mechanism) the whole time,
    ///         so `hasFrozenCoverage(guardian)` reads `true` throughout: a
    ///         conviction against P1 remains a live possibility, yet the OLD
    ///         `openExposureUsd`-based denominator still silently drops it,
    ///         because `pinCoverageUntil` only ever touches
    ///         `_pinnedCoverageUntil`/`_frozenCommitments`, never `_buckets`.
    function test_finding2_trigger2_frozenPinnedProposalAgesOutOfTheOldDenominatorButNotTheNewOne() public {
        _wireRecording();
        swood.setStake(guardian, 20_000e18); // $1,000 bond

        mgov.set(500e6);
        mgov.setSchedule(block.timestamp + 1 days, 3 days);
        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);

        // Pin P1's coverage far into the future, independent of
        // `freezeCoverage` ever being called -- the exact mechanism
        // `ChallengeGame._refundAll` uses to keep an `Inconclusive`-resolved
        // proposal legally re-challengeable (issue #95).
        vm.prank(freezer);
        ledger.pinCoverageUntil(address(mgov), 1, block.timestamp + 200 days);
        assertTrue(ledger.hasFrozenCoverage(guardian), "pinned: g remains legally accusable on P1");

        skip(50 days);
        assertTrue(ledger.hasFrozenCoverage(guardian), "STILL pinned 50 days later -- P1 is still legally live");
        assertEq(
            ledger.openExposureUsd(guardian),
            0,
            "yet the OLD denominator already dropped P1's contribution on pure wall clock"
        );

        MockGovernorForLedger mgov2 = _secondGovernor(500e6, 3 days);
        vm.prank(registry);
        ledger.recordApproval(address(mgov2), 1, guardian);

        swood.setStake(guardian, 12_000e18); // unrelated conviction: live stake -> $600

        // Same fair split as trigger 1: the pin changes NOTHING about
        // `_liveBookedUsd`'s bookkeeping (it only ever moves on
        // recordApproval/releaseApproval/_rebook), so the guardian's real
        // $600 is still split $300/$300 -- proving the fix generalizes to the
        // challenge-driven aging case, not just plain abandonment, with no
        // need for the audit's rejected Option B (union the denominator with
        // `_frozenCommitments`/`_pinnedCoverageUntil`).
        assertEq(ledger.liabilityUsd(address(mgov), 1), 300e18);
        assertEq(ledger.liabilityUsd(address(mgov2), 1), 300e18);
        assertEq(ledger.liabilityUsd(address(mgov), 1) + ledger.liabilityUsd(address(mgov2), 1), 600e18);
    }

    /// @notice FINDING 2 [85], TRIGGER 3 — AN OWNER `setChallengeWindow`
    ///         SHRINK RETROACTIVELY EXCLUDES A STILL-OPEN BUCKET (agent 11).
    ///         A legal, ordinary parameter change with no live-exposure check
    ///         -- `setChallengeWindow`'s own natspec already documents that
    ///         shrinking "instantly expires buckets recorded under the longer
    ///         window." That is the CORRECT, intended behaviour for the
    ///         batching cap; the bug was reusing the same decaying scan as
    ///         the shared-stake denominator.
    ///
    ///         Needs a registry WITH CODE (`MockRegistryForLedger`), not the
    ///         bare EOA `_wireRecording()` wires by default: `setChallengeWindow`
    ///         re-checks the floor via `IRegistryApproversMinimal(registry)
    ///         .reviewPeriod()`, which reverts against a codeless address.
    function test_finding2_trigger3_challengeWindowShrinkDoesNotReopenTheSharedDenominator() public {
        MockRegistryForLedger reg = new MockRegistryForLedger(); // reviewPeriod 3d -> floor 10d
        usdgAsset = makeAddr("usdgAssetShrinkTrigger");
        vm.mockCall(usdgAsset, abi.encodeWithSignature("decimals()"), abi.encode(uint8(6)));
        MockFeed feed = new MockFeed(1e8, 8);
        MockVaultForLedger vault = new MockVaultForLedger(usdgAsset);
        mgov = new MockGovernorForLedger(address(vault));
        vm.startPrank(owner);
        ledger.setAssetFeed(usdgAsset, address(feed), 365 days);
        ledger.setChallengeWindow(20 days); // legal pre-registry; >= 3d + 7d floor
        ledger.setGuardianRegistry(address(reg));
        vm.stopPrank();
        swood.setStake(guardian, 20_000e18); // $1,000 bond

        // P1 books into epoch 0.
        mgov.set(500e6);
        mgov.setSchedule(block.timestamp + 1 days, 3 days);
        vm.prank(address(reg));
        ledger.recordApproval(address(mgov), 1, guardian);

        skip(40 days);

        // P2 books into a later epoch (epoch 1 at this elapsed time).
        MockGovernorForLedger mgov2 = _secondGovernor(500e6, 3 days);
        vm.prank(address(reg));
        ledger.recordApproval(address(mgov2), 1, guardian);
        assertEq(ledger.openExposureUsd(guardian), 1_000e18, "both still counted under the WIDE 20d window");

        // Owner shrinks the window to the registry's floor (still legal: 10d
        // >= 3d + 7d). No further time passes -- the shrink ALONE pushes
        // `openExposureUsd`'s scan start from epoch 0 to epoch 1, excluding
        // P1 even though it was never released.
        vm.prank(owner);
        ledger.setChallengeWindow(10 days);
        assertEq(
            ledger.openExposureUsd(guardian),
            500e18,
            "the shrink ALONE dropped P1 from the OLD denominator -- no time passed, no release, no settlement"
        );

        swood.setStake(guardian, 12_000e18); // unrelated conviction: live stake -> $600

        // `_liveBookedUsd` never read `challengeWindow` at all, so the shrink
        // changes nothing about it: the fair $300/$300 split holds exactly as
        // in triggers 1 and 2.
        assertEq(ledger.liabilityUsd(address(mgov), 1), 300e18);
        assertEq(ledger.liabilityUsd(address(mgov2), 1), 300e18);
    }

    /// @notice FINDING 3 [78] — `ChallengeGame.file`'s challenger-bond
    ///         sizing must read the UNSHARED total (`unsharedLiabilityUsd`),
    ///         not the shared one (`liabilityUsd`), or the anti-frivolous-
    ///         filing deterrent gets diluted every time `kNumerator > 1` and
    ///         the accused cohort also backs another open proposal.
    ///
    ///         Reproduces the audit's own numeric trace exactly: G stakes
    ///         1,000 WOOD ($1,000 at $0.05, no haircut) => slashableBondUsd
    ///         (G) = 1,000. kNumerator = 2 => capUsd = 2,000. G is sole
    ///         approver on P1 and P2, needUsd = 1,000 each -- both legal
    ///         under the batching cap (P1 books 1,000, P2 books 1,000,
    ///         openExposureUsd(G) = 2,000, exactly the cap).
    function test_finding3_unsharedLiabilityUsdIsNotDilutedByASiblingProposal() public {
        _wireRecording();
        swood.setStake(guardian, 20_000e18); // $1,000 bond
        vm.prank(owner);
        ledger.setKNumerator(2);

        mgov.set(1_000e6);
        mgov.setSchedule(block.timestamp + 1 days, 3 days);
        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian);

        MockGovernorForLedger mgov2 = _secondGovernor(1_000e6, 3 days);
        vm.prank(registry);
        ledger.recordApproval(address(mgov2), 1, guardian);
        assertEq(ledger.openExposureUsd(guardian), 2_000e18, "both booked: exactly at the k=2 cap");

        // SHARED (`liabilityUsd`): G's $1,000 real bond is pro-rated across
        // both $1,000 reservations -- `1000 * 1000 / 2000 = 500` each. This
        // is CORRECT for pricing what a conviction on P1 alone can actually
        // recover.
        assertEq(ledger.liabilityUsd(address(mgov), 1), 500e18, "shared: diluted by P2's equal claim");

        // UNSHARED (`unsharedLiabilityUsd`) -- the basis `ChallengeGame.file`
        // must use instead: `min(reserved=1000, slashable=1000) = 1000`, NOT
        // diluted by P2. This is what a filing against P1 alone must freeze,
        // regardless of G's unrelated activity on P2.
        assertEq(
            ledger.unsharedLiabilityUsd(address(mgov), 1),
            1_000e18,
            "unshared: full, undiluted by G's unrelated P2 commitment"
        );
        assertEq(ledger.unsharedLiabilityUsd(address(mgov2), 1), 1_000e18, "symmetric: same for P2 read against P1");
    }

    /// @notice `unsharedLiabilityUsd` still respects its own cap: an
    ///         under-covered cohort is priced on what it actually pledged,
    ///         same as `liabilityUsd` and `_effectiveTotal` before it.
    function test_finding3_unsharedLiabilityUsdStillCapsAtTheReservation() public {
        _wireRecording();
        mgov.set(10_000e6); // needUsd = $10,000, far above the guardian's bond
        vm.prank(registry);
        ledger.recordApproval(address(mgov), 1, guardian); // reserves its $5,000 bond in full

        assertEq(
            ledger.unsharedLiabilityUsd(address(mgov), 1),
            5_000e18,
            "capped by what the cohort actually pledged, not inflated by the unmet need"
        );
    }

    /// @notice FINDING 4 [75] — `_effectiveReservedTotal`/`settleCoverage`
    ///         used to divide a FROZEN pledge numerator by a LIVE, self-
    ///         mutating booking denominator (`openExposureUsd`, shrunk by the
    ///         settlement pass's own prior writes), breaking the "shares sum
    ///         to <= 1" property on a RE-SETTLE. The fix's basis-matched
    ///         accumulators (`_livePledgedUsd` for the pledge-basis callers)
    ///         close this as a side effect: the pledge-basis denominator is
    ///         now, by construction, immune to `_rebook`'s writes, because
    ///         settlement never touches `_reservedUsd`/`_livePledgedUsd`.
    ///
    ///         Reproduces the audit's own trace: two guardians pledge $1,000
    ///         each on a $1,000-need proposal (k=1), settle once (writes both
    ///         bookings down to $500 pro-rata), WOOD price crashes 60%
    ///         ($0.05 -> $0.02, dropping each live bond to $400), re-settle.
    function test_finding4_reSettleAfterAPriceCrashNeverExceedsTheLiveCap() public {
        _wireRecording();
        address g2 = makeAddr("finding4_g2");
        swood.setStake(guardian, 20_000e18); // $1,000 at $0.05
        swood.setStake(g2, 20_000e18); // $1,000 at $0.05

        mgov.set(1_000e6); // $1,000 need
        mgov.setSchedule(block.timestamp + 1 days, 3 days);
        vm.startPrank(registry);
        ledger.recordApproval(address(mgov), 1, guardian); // reserves its full $1,000
        ledger.recordApproval(address(mgov), 1, g2); // reserves its full $1,000
        vm.stopPrank();

        skip(31 days); // past executeBy: settleCoverage's window gate opens

        // FIRST SETTLE, at the pre-crash price. Two guardians x $1,000
        // reserved against a $1,000 need: `_allocate` scales each down to
        // `1000 * 1000 / 2000 = 500`.
        ledger.settleCoverage(address(mgov), 1);
        assertEq(ledger.allocatedUsd(address(mgov), 1, guardian), 500e18, "first settle: written down pro-rata");
        assertEq(ledger.allocatedUsd(address(mgov), 1, g2), 500e18);

        // WOOD crashes 60%: $0.05 -> $0.02 (the cap binds -- same lever the
        // sibling trough tests in this file pull). Live bonds fall to $400
        // each.
        vm.prank(owner);
        ledger.setWoodUsdPrice(0.02e8);
        assertEq(ledger.woodPriceX8(), 0.02e8, "the cap is binding: this is the crash");
        assertEq(ledger.slashableBondUsd(guardian), 400e18, "live bond crashed to $400");
        assertEq(ledger.slashableBondUsd(g2), 400e18);

        // RE-SETTLE. `_reservedUsd`/`_livePledgedUsd` are UNCHANGED by the
        // first settle (still $1,000 each -- settlement only ever rewrites
        // the BOOKING, never the pledge), so the pledge-basis ratio stays
        // exactly `reserved / livePledgedUsd == 1` for both guardians --
        // `_sharedSlashableUsd` reduces to the plain `min(reserved,
        // slashable) = min(1000, 400) = 400` for each, with NO inflation.
        //
        // PRE-FIX ARITHMETIC (documented, not executed against old code): the
        // OLD denominator, `openExposureUsd(g)`, sums the CURRENT booking --
        // which at the moment `_effectiveReservedTotal` is evaluated (BEFORE
        // this pass's own `_rebook` writes run) still holds the FIRST
        // settle's $500, not yet written down. Old ratio =
        // reserved($1,000)/openTotal($500) = 2.0 -- DOUBLE. Old share =
        // min(slashable($400) * 2.0 = $800, reserved($1,000)) = $800, twice
        // the guardian's real $400. Old `_allocate(mine=$800,
        // effectiveTotal=$1,600, needUsd=$1,000)` = `800*1000/1600 = $500` --
        // and `_rebook(target=$500)` against a CURRENT booking that is
        // ALREADY $500 is a no-op, LEAVING the booking at $500 even though
        // the guardian's real live cap just fell to $400. A genuine breach of
        // "never underwrite more than 1x its own value" per proposal.
        ledger.settleCoverage(address(mgov), 1);

        uint256 bookedAfterReSettle = ledger.allocatedUsd(address(mgov), 1, guardian);
        assertEq(bookedAfterReSettle, 400e18, "re-settle correctly writes the booking down to the live cap");
        assertLe(
            bookedAfterReSettle,
            ledger.slashableBondUsd(guardian),
            "THE INVARIANT: booked coverage after re-settle must never exceed the guardian's live cap"
        );
        assertEq(ledger.allocatedUsd(address(mgov), 1, g2), 400e18);
        assertLe(ledger.allocatedUsd(address(mgov), 1, g2), ledger.slashableBondUsd(g2));

        // And the aggregate never overstates the cohort's real recoverable
        // total either.
        assertEq(ledger.liabilityUsd(address(mgov), 1), 800e18, "cohort liability: exactly the sum of both live caps");
    }
}
