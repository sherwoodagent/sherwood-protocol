// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {GuardianRegistry} from "../src/GuardianRegistry.sol";
import {StakedWood} from "../src/StakedWood.sol";
import {ExposureLedger} from "../src/ExposureLedger.sol";
import {IExposureLedger} from "../src/interfaces/IExposureLedger.sol";
import {IGuardianRegistry} from "../src/interfaces/IGuardianRegistry.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {MockGovernorMinimal} from "./mocks/MockGovernorMinimal.sol";
import {MockWoodTwapOracle} from "./mocks/MockWoodTwapOracle.sol";

/// @dev Chainlink feed stub (copied from test/ExposureLedger.t.sol) — the
///      ledger reads `latestRoundData` + `decimals` to value coverage.
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

/// @dev Governor mock: the shared `MockGovernorMinimal` surface (consumed by
///      the registry) PLUS the two reads the ledger's `recordApproval` makes —
///      `getRequiredCoverage` and `getProposalView().vault`.
/// @dev The lifecycle refactor removed the review-window/vault plumbing from the
///      shared mock: the REGISTRY now takes its window from `registerReview` and
///      the vault from `vaultOf`. The LEDGER still calls back into the governor
///      for the proposal's vault (integration plan C5), so that surface is
///      re-provided here rather than restored on the shared mock.
contract MockGovernorWithCoverage is MockGovernorMinimal {
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
    function setSchedule(uint256 executeBy_, uint256 duration_) external {
        executeBy = executeBy_;
        strategyDuration = duration_;
    }

    uint256 public requiredCoverage;
    address public proposalVault;

    /// @dev 0 (unexecuted) by default — this file's fixtures exercise the
    ///      approve-vote path, which stays on the live basis regardless
    ///      (issue #35). Set to exercise the execution-anchored basis.
    uint256 public executedAt;

    function setExecutedAt(uint256 executedAt_) external {
        executedAt = executedAt_;
    }

    function setRequiredCoverage(uint256 c) external {
        requiredCoverage = c;
    }

    function setProposalVault(address v) external {
        proposalVault = v;
    }

    function getRequiredCoverage(uint256) external view returns (uint256) {
        return requiredCoverage;
    }

    function getProposalView(uint256) external view returns (ProposalViewLite memory v) {
        v.vault = proposalVault;
        v.executeBy = executeBy;
        v.strategyDuration = strategyDuration;
        v.executedAt = executedAt;
    }
}

/// @dev Minimal vault exposing `asset()` — the ledger resolves the proposal's
///      asset through `getProposalView().vault.asset()`.
contract MockVault {
    address public asset;

    constructor(address asset_) {
        asset = asset_;
    }
}

/// @title RegistryExposureHookTest
/// @notice Spec 2026-07-22 §3.3: `GuardianRegistry.voteOnProposal` records /
///         releases dollar exposure on the ExposureLedger at approve-vote time.
///         Driven through REAL `voteOnProposal` calls against a REAL ledger
///         wired both ways. A second, unwired registry/governor pair proves the
///         pre-wiring (ledger unset) path is untouched.
contract RegistryExposureHookTest is Test {
    uint256 constant REVIEW_PERIOD = 24 hours;
    uint256 constant Q = 3000; // block quorum bps
    uint256 constant PID = 1;
    uint256 constant PID2 = 2;

    address internal regOwner = address(0xA11CE);
    address internal regFactory = address(0xFAC10);
    address internal ledgerOwner = makeAddr("ledgerOwner");
    address internal g1 = makeAddr("g1");
    address internal g2 = makeAddr("g2");

    /// @dev A full independent registry + sWOOD + governor + vault stack.
    struct Sys {
        ERC20Mock wood;
        ERC20Mock asset;
        StakedWood swood;
        GuardianRegistry registry;
        MockGovernorWithCoverage gov;
        MockVault vault;
    }

    Sys internal wired; // registry with the ledger wired in
    Sys internal unwired; // registry without the ledger (`registryNoLedger`/`gov2`)

    ExposureLedger internal ledger;
    MockFeed internal feed;

    function setUp() public {
        wired = _deploySystem();
        unwired = _deploySystem();

        // Two staked guardians per cohort (matured below to full weight so the
        // combined stake clears MIN_COHORT_STAKE_AT_OPEN).
        _stakeGuardian(wired, g1, 100_000e18, 1);
        _stakeGuardian(wired, g2, 100_000e18, 2);
        _stakeGuardian(unwired, g1, 100_000e18, 1);
        _stakeGuardian(unwired, g2, 100_000e18, 2);

        // Mature both cohorts to par (maturationPeriod 30d) so aged vote weight
        // == raw stake. The +1 warp: openReview snapshots at `block.timestamp-1`.
        skip(30 days);
        vm.warp(vm.getBlockTimestamp() + 1);

        // Ledger deployed AFTER the warp: epoch genesis + feed freshness are
        // current, so recordApproval books into the live bucket with a fresh
        // price. epochLength 28d + challengeWindow 14d = 42d <= coolDown 45d.
        ledger = new ExposureLedger(ledgerOwner, address(wired.swood), 28 days);
        feed = new MockFeed(1e8, 8); // $1.00, 8-dec feed
        // Design revision 2: `woodUsdPriceX8` is a CAP, never a price. WOOD is
        // valued from the TWAP oracle at $0.05, with the cap 2x ABOVE it and
        // therefore NOT binding — the configuration production ships.
        MockWoodTwapOracle woodTwap = new MockWoodTwapOracle(0.05e8);
        vm.startPrank(ledgerOwner);
        ledger.setWoodUsdPrice(0.1e8);
        ledger.setWoodTwapOracle(address(woodTwap));
        ledger.setAssetFeed(address(wired.asset), address(feed), 1 days);
        ledger.setCoveredTvlCapUsd(1_000_000e18); // generous
        ledger.setGuardianRegistry(address(wired.registry));
        vm.stopPrank();
        vm.prank(regOwner);
        wired.registry.setExposureLedger(address(ledger));

        // Open a review with nonzero required coverage on each governor.
        uint256 voteEnd = vm.getBlockTimestamp();
        uint256 reviewEnd = voteEnd + REVIEW_PERIOD;

        wired.gov.setProposalVault(address(wired.vault));
        vm.prank(address(wired.gov));
        wired.registry.registerReview(PID, voteEnd, reviewEnd);
        wired.gov.setRequiredCoverage(1_000e6); // 1,000 USDG (6 dec) => $1,000
        wired.registry.openReview(address(wired.gov), PID);

        unwired.gov.setProposalVault(address(unwired.vault));
        vm.prank(address(unwired.gov));
        unwired.registry.registerReview(PID2, voteEnd, reviewEnd);
        unwired.gov.setRequiredCoverage(1_000e6);
        unwired.registry.openReview(address(unwired.gov), PID2);
    }

    // ── Fixture helpers (mirror RegistryTestHarness, parameterized per stack) ──

    function _deploySystem() internal returns (Sys memory s) {
        s.wood = new ERC20Mock("WOOD", "WOOD", 18);
        s.asset = new ERC20Mock("USDG", "USDG", 6);
        s.gov = new MockGovernorWithCoverage();
        s.vault = new MockVault(address(s.asset));

        StakedWood swoodImpl = new StakedWood();
        bytes memory swoodInit = abi.encodeCall(
            StakedWood.initialize,
            (StakedWood.InitParams({
                    owner: regOwner,
                    wood: address(s.wood),
                    factory: regFactory,
                    minGuardianStake: 10_000e18,
                    coolDownPeriod: 45 days, // >= epochLength (28d) + challengeWindow (14d)
                    minOwnerStake: 10_000e18,
                    minSlashBps: 1000,
                    maxSlashBps: 9999,
                    ageFloorBps: 2500,
                    maturationPeriod: 30 days
                }))
        );
        s.swood = StakedWood(address(new ERC1967Proxy(address(swoodImpl), swoodInit)));

        GuardianRegistry regImpl = new GuardianRegistry(6 hours);
        bytes memory regInit =
            abi.encodeCall(GuardianRegistry.initialize, (regOwner, regFactory, address(s.swood), REVIEW_PERIOD, Q));
        s.registry = GuardianRegistry(address(new ERC1967Proxy(address(regImpl), regInit)));

        vm.prank(regOwner);
        s.swood.setRegistry(address(s.registry));
        vm.prank(regFactory);
        s.registry.addGovernor(address(s.gov), address(s.vault));
    }

    function _stakeGuardian(Sys memory s, address g, uint256 amount, uint256 agentId) internal {
        s.wood.mint(g, amount);
        vm.startPrank(g);
        s.wood.approve(address(s.swood), type(uint256).max);
        s.swood.stakeAsGuardian(amount, agentId);
        vm.stopPrank();
    }

    // ── Tests ──

    function test_approveVote_recordsExposure() public {
        vm.prank(g1);
        wired.registry.voteOnProposal(address(wired.gov), PID, IGuardianRegistry.GuardianVoteType.Approve);
        assertGt(ledger.openExposureUsd(g1), 0);
    }

    function test_blockVote_recordsNothing() public {
        vm.prank(g1);
        wired.registry.voteOnProposal(address(wired.gov), PID, IGuardianRegistry.GuardianVoteType.Block);
        assertEq(ledger.openExposureUsd(g1), 0);
    }

    function test_voteChange_approveToBlock_releases() public {
        vm.prank(g1);
        wired.registry.voteOnProposal(address(wired.gov), PID, IGuardianRegistry.GuardianVoteType.Approve);
        assertGt(ledger.openExposureUsd(g1), 0);
        vm.prank(g1);
        wired.registry.voteOnProposal(address(wired.gov), PID, IGuardianRegistry.GuardianVoteType.Block);
        assertEq(ledger.openExposureUsd(g1), 0);
    }

    /// @notice N1 — a guardian with no free budget can still VOTE; it just
    ///         books no coverage. Previously the hook reverted and took the vote
    ///         with it, silencing the approve side while Block votes still
    ///         worked. That is the shape the C1 veto survived in: an attacker
    ///         who front-runs while the cohort is busy bricks the proposal,
    ///         because the guardians who would have covered it cannot
    ///         participate at all.
    function test_overCapGuardianVotesButBooksNothing() public {
        // Zero g1's slashable bond so its free budget is exactly $0. Done by
        // mocking the ledger's stake reads rather than by zeroing the WOOD
        // price: the price setter is rate-limited now (review M4) and this test
        // sits inside an already-open review window, so waiting out the interval
        // would push past `reviewEnd` and change what is being tested.
        // Own stake is the whole slashable bond post delegation-removal, so
        // zeroing it is sufficient — there is no delegated leg left to mock.
        vm.mockCall(address(wired.swood), abi.encodeWithSignature("guardianStake(address)", g1), abi.encode(uint256(0)));
        assertEq(ledger.slashableBondUsd(g1), 0, "no slashable bond -> no free budget");

        vm.prank(g1);
        wired.registry.voteOnProposal(address(wired.gov), PID, IGuardianRegistry.GuardianVoteType.Approve);

        assertEq(ledger.openExposureUsd(g1), 0, "no coverage booked");
        (address[] memory approvers,,) = wired.registry.getApproverWeights(address(wired.gov), PID);
        assertEq(approvers.length, 1, "...but the vote itself counted");
        assertEq(approvers[0], g1);
    }

    /// @notice THE FEE-WEIGHTING GAP (§3.10). The test above pins the divergence
    ///         that makes it possible: the registry counts the vote while the
    ///         ledger books nothing. Since `getApproverWeights` returns
    ///         `_voteStake` — staked WOOD, not underwritten coverage — an
    ///         approver the ledger declined to book still carries full stake
    ///         weight into the off-chain Merkl attribution, and is paid beside
    ///         approvers who actually carried the risk.
    ///
    ///         The free-ride needs no exotic state: burn the whole budget on one
    ///         proposal, then keep approving everything else. Every later
    ///         approve books zero and consumes no capacity, yet still bills at
    ///         full stake.
    ///
    ///         `getApproverCoverage` is the weight the fee should be paid on. It
    ///         reports what each approver actually underwrote, so a zero-coverage
    ///         approve weighs zero — closing the free-ride WITHOUT gating the
    ///         vote, which review N1 rejected because it silenced the approve
    ///         side and revived the C1 veto.
    function test_getApproverCoverage_zeroForAnApproverThatUnderwroteNothing() public {
        // Same setup as above: g1 has no slashable bond, so no free budget.
        vm.mockCall(address(wired.swood), abi.encodeWithSignature("guardianStake(address)", g1), abi.encode(uint256(0)));

        vm.prank(g1);
        wired.registry.voteOnProposal(address(wired.gov), PID, IGuardianRegistry.GuardianVoteType.Approve);
        vm.prank(g2);
        wired.registry.voteOnProposal(address(wired.gov), PID, IGuardianRegistry.GuardianVoteType.Approve);

        // Stake weighting: both approvers listed, and g1 is NOT weighted zero --
        // this is the surface that overpays.
        (address[] memory sApprovers, uint128[] memory stakeWeights,) =
            wired.registry.getApproverWeights(address(wired.gov), PID);
        assertEq(sApprovers.length, 2, "both votes counted for attribution");

        // Coverage weighting: same set, but the free-rider weighs nothing.
        (address[] memory cApprovers, uint256[] memory coverage, bool priced) =
            wired.registry.getApproverCoverage(address(wired.gov), PID);
        assertTrue(priced, "asset feed is live in this fixture");
        assertEq(cApprovers.length, 2, "same approver set as the stake view");

        for (uint256 i; i < cApprovers.length; ++i) {
            if (cApprovers[i] == g1) {
                assertEq(coverage[i], 0, "underwrote nothing -> weighs nothing");
                assertGt(uint256(stakeWeights[i]), 0, "...while stake weighting paid it in full");
            } else {
                assertGt(coverage[i], 0, "the guardian that actually covered it carries weight");
            }
        }
    }

    /// @notice An unwired ledger has no coverage to attribute, and that is a
    ///         real answer rather than a failure — `priced` stays true so the
    ///         payout job does not retry forever against a Plan A deployment.
    function test_getApproverCoverage_unwiredLedgerReportsPricedZeros() public {
        vm.prank(g1);
        unwired.registry.voteOnProposal(address(unwired.gov), PID2, IGuardianRegistry.GuardianVoteType.Approve);

        (address[] memory approvers, uint256[] memory coverage, bool priced) =
            unwired.registry.getApproverCoverage(address(unwired.gov), PID2);
        assertTrue(priced, "no ledger is a determinate answer, not an outage");
        assertEq(approvers.length, 1);
        assertEq(coverage[0], 0);
    }

    function test_ledgerUnset_votesUnaffected() public {
        // Plan A behavior preserved: an unwired registry runs no hooks.
        assertEq(address(unwired.registry.exposureLedger()), address(0));
        vm.prank(g1);
        unwired.registry.voteOnProposal(address(unwired.gov), PID2, IGuardianRegistry.GuardianVoteType.Approve);
        // no revert, no recording anywhere
        assertEq(ledger.openExposureUsd(g1), 0);
    }

    function test_voteChange_approveBlockApprove_rebooks() public {
        // Approve → Block → Approve: record, release, re-record (cap re-checked
        // on the final approve). Exposure returns to the originally booked amount.
        vm.prank(g1);
        wired.registry.voteOnProposal(address(wired.gov), PID, IGuardianRegistry.GuardianVoteType.Approve);
        uint256 booked = ledger.openExposureUsd(g1);
        assertGt(booked, 0);

        vm.prank(g1);
        wired.registry.voteOnProposal(address(wired.gov), PID, IGuardianRegistry.GuardianVoteType.Block);
        assertEq(ledger.openExposureUsd(g1), 0);

        vm.prank(g1);
        wired.registry.voteOnProposal(address(wired.gov), PID, IGuardianRegistry.GuardianVoteType.Approve);
        assertEq(ledger.openExposureUsd(g1), booked);
    }

    function test_voteChange_blockToApprove_booksFresh() public {
        // Block records nothing; changing to Approve books fresh exposure.
        vm.prank(g1);
        wired.registry.voteOnProposal(address(wired.gov), PID, IGuardianRegistry.GuardianVoteType.Block);
        assertEq(ledger.openExposureUsd(g1), 0);

        vm.prank(g1);
        wired.registry.voteOnProposal(address(wired.gov), PID, IGuardianRegistry.GuardianVoteType.Approve);
        assertGt(ledger.openExposureUsd(g1), 0);
    }

    function test_setExposureLedger_accessControl() public {
        // Non-owner cannot wire the ledger.
        vm.prank(g1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, g1));
        wired.registry.setExposureLedger(address(ledger));

        // Owner cannot wire the zero address.
        vm.prank(regOwner);
        vm.expectRevert(IGuardianRegistry.ZeroAddress.selector);
        wired.registry.setExposureLedger(address(0));
    }
}
