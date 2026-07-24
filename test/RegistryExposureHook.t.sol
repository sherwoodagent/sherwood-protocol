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
///      the registry) PLUS `getRequiredCoverage` (consumed by the ledger's
///      `recordApproval`). `getProposalView().vault` is set via the inherited
///      `setProposalWithVault`.
contract MockGovernorWithCoverage is MockGovernorMinimal {
    uint256 public requiredCoverage;

    function setRequiredCoverage(uint256 c) external {
        requiredCoverage = c;
    }

    function getRequiredCoverage(uint256) external view returns (uint256) {
        return requiredCoverage;
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
        vm.startPrank(ledgerOwner);
        ledger.setWoodUsdPrice(0.05e8); // $0.05 conservative haircut
        ledger.setAssetFeed(address(wired.asset), address(feed), 1 days);
        ledger.setCoveredTvlCapUsd(1_000_000e18); // generous
        ledger.setGuardianRegistry(address(wired.registry));
        vm.stopPrank();
        vm.prank(regOwner);
        wired.registry.setExposureLedger(address(ledger));

        // Open a review with nonzero required coverage on each governor.
        uint256 voteEnd = vm.getBlockTimestamp();
        uint256 reviewEnd = voteEnd + REVIEW_PERIOD;

        wired.gov.setProposalWithVault(PID, voteEnd, reviewEnd, address(wired.vault));
        wired.gov.setRequiredCoverage(1_000e6); // 1,000 USDG (6 dec) => $1,000
        wired.registry.openReview(address(wired.gov), PID);

        unwired.gov.setProposalWithVault(PID2, voteEnd, reviewEnd, address(unwired.vault));
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
                    maxDelegatedSlashBps: 2000,
                    ageFloorBps: 2500,
                    maturationPeriod: 30 days,
                    delegatedWeightCapX: 4
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
        s.registry.addGovernor(address(s.gov));
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

    function test_overCapGuardianCannotApprove() public {
        // Crash the governance WOOD price to shrink g1's slashable bond to ~$0,
        // so ANY nonzero coverage exceeds the cap and the approve vote reverts.
        vm.prank(ledgerOwner);
        ledger.setWoodUsdPrice(1);
        vm.prank(g1);
        vm.expectRevert(IExposureLedger.ExposureCapExceeded.selector);
        wired.registry.voteOnProposal(address(wired.gov), PID, IGuardianRegistry.GuardianVoteType.Approve);
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
