// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {GuardianRegistry} from "../../src/GuardianRegistry.sol";
import {StakedWood} from "../../src/StakedWood.sol";
import {ExposureLedger} from "../../src/ExposureLedger.sol";
import {IExposureLedger} from "../../src/interfaces/IExposureLedger.sol";
import {IGuardianRegistry} from "../../src/interfaces/IGuardianRegistry.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockGovernorMinimal} from "../mocks/MockGovernorMinimal.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";

contract F3Feed {
    int256 public answer;
    uint8 public immutable decimals;
    uint256 public updatedAt;

    constructor(int256 a, uint8 d) {
        answer = a;
        decimals = d;
        updatedAt = block.timestamp;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

contract F3Gov is MockGovernorMinimal {
    struct ProposalViewLite {
        uint256 voteEnd;
        uint256 reviewEnd;
        address vault;
        uint256 executeBy;
        uint256 strategyDuration;
        uint256 executedAt;
    }

    uint256 public requiredCoverage;
    address public proposalVault;

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
    }
}

contract F3Vault {
    address public asset;

    constructor(address a) {
        asset = a;
    }
}

/// @notice v1 audit F3 — the sub-share (whole-budget) arm of the approve floor is
///         rationed to half of `APPROVER_SLOTS`, so a cohort staked at exactly
///         `minGuardianStake` can no longer fill the registry's bounded approver
///         array and shut a well-bonded underwriter out of the proposal.
contract ExposureLedgerF3ApproverSlotFloorTest is Test {
    uint256 constant REVIEW_PERIOD = 24 hours;
    uint256 constant Q = 3000;
    uint256 constant PID = 1;

    uint256 constant MIN_STAKE = 10_000e18; // RobinhoodParams.MIN_GUARDIAN_STAKE
    uint256 constant SQUAT = 100; // == MAX_APPROVERS_PER_PROPOSAL
    uint256 constant WHALE_STAKE = 5_000_000e18;
    uint256 constant REQUIRED_COVERAGE = 200_000e6; // 200k USDG == $200k need

    address internal regOwner = address(0xA11CE);
    address internal regFactory = address(0xFAC10);
    address internal ledgerOwner = makeAddr("ledgerOwner");
    address internal whale = makeAddr("honestWhale");

    ERC20Mock wood;
    ERC20Mock asset;
    StakedWood swood;
    GuardianRegistry registry;
    F3Gov gov;
    F3Vault vault;
    ExposureLedger ledger;

    function _squatter(uint256 i) internal pure returns (address) {
        return address(uint160(0x5000000 + i));
    }

    function _stake(address g, uint256 amount, uint256 agentId) internal {
        wood.mint(g, amount);
        vm.startPrank(g);
        wood.approve(address(swood), type(uint256).max);
        swood.stakeAsGuardian(amount, agentId);
        vm.stopPrank();
    }

    function _approve(address g, uint256 proposalId) internal {
        vm.prank(g);
        registry.voteOnProposal(address(gov), proposalId, IGuardianRegistry.GuardianVoteType.Approve, type(uint256).max);
    }

    function setUp() public {
        wood = new ERC20Mock("WOOD", "WOOD", 18);
        asset = new ERC20Mock("USDG", "USDG", 6);
        gov = new F3Gov();
        vault = new F3Vault(address(asset));

        StakedWood swoodImpl = new StakedWood();
        bytes memory swoodInit = abi.encodeCall(
            StakedWood.initialize,
            (StakedWood.InitParams({
                    owner: regOwner,
                    wood: address(wood),
                    factory: regFactory,
                    minGuardianStake: MIN_STAKE,
                    coolDownPeriod: 45 days,
                    minOwnerStake: 10_000e18,
                    minSlashBps: 1000,
                    maxSlashBps: 9999,
                    ageFloorBps: 2500,
                    maturationPeriod: 30 days
                }))
        );
        swood = StakedWood(address(new ERC1967Proxy(address(swoodImpl), swoodInit)));

        GuardianRegistry regImpl = new GuardianRegistry(6 hours);
        bytes memory regInit =
            abi.encodeCall(GuardianRegistry.initialize, (regOwner, regFactory, address(swood), REVIEW_PERIOD, Q));
        registry = GuardianRegistry(address(new ERC1967Proxy(address(regImpl), regInit)));

        vm.prank(regOwner);
        swood.setRegistry(address(registry));
        vm.prank(regFactory);
        registry.addGovernor(address(gov), address(vault));

        // 100 sybils at EXACTLY the minimum stake, plus one honest whale.
        for (uint256 i = 0; i < SQUAT; i++) {
            _stake(_squatter(i), MIN_STAKE, 1 + i);
        }
        _stake(whale, WHALE_STAKE, 9999);

        skip(30 days);
        vm.warp(vm.getBlockTimestamp() + 1);

        ledger = new ExposureLedger(ledgerOwner, address(swood), 28 days);
        F3Feed assetFeed = new F3Feed(1e8, 8); // USDG == $1.00
        MockAggregatorV3 woodFeed = new MockAggregatorV3(8, 0.05e8); // WOOD == $0.05
        vm.startPrank(ledgerOwner);
        ledger.setWoodUsdPrice(0.1e8); // cap above market, not binding
        ledger.setWoodFeed(address(woodFeed), type(uint64).max);
        ledger.setAssetFeed(address(asset), address(assetFeed), 1 days);
        ledger.setCoveredTvlCapUsd(1_000_000e18);
        ledger.setGuardianRegistry(address(registry));
        vm.stopPrank();
        vm.prank(regOwner);
        registry.setExposureLedger(address(ledger));

        uint256 voteEnd = vm.getBlockTimestamp();
        gov.setProposalVault(address(vault));
        gov.setRequiredCoverage(REQUIRED_COVERAGE);
        vm.prank(address(gov));
        registry.registerReview(PID, voteEnd, voteEnd + REVIEW_PERIOD);
        registry.openReview(address(gov), PID);
    }

    /// @notice A cohort of 100 min-stake guardians stops seating at half the
    ///         slots, and the guardian able to cover the whole need alone still
    ///         gets a slot and restores full coverage.
    function test_F3_hundredMinStakeGuardiansLockOutAnHonestApprover() public {
        uint256 needUsd = ledger.coverageUsd(address(asset), REQUIRED_COVERAGE);
        uint256 shareUsd = (needUsd + ledger.APPROVER_SLOTS() - 1) / ledger.APPROVER_SLOTS();
        uint256 squatterBudgetUsd = ledger.slashableBondUsd(_squatter(0));
        uint256 ration = ledger.APPROVER_SLOTS() / 2;

        // The precondition of the cheap branch: the whole budget is under a share.
        assertLt(squatterBudgetUsd, shareUsd, "fixture: a min-stake budget is under one slot's share");

        // The rationed half seats; the next sub-share declaration is refused,
        // whatever the cohort does, because holding nothing back is no longer
        // enough once half the array is spoken for.
        for (uint256 i = 0; i < ration; i++) {
            _approve(_squatter(i), PID);
        }
        for (uint256 i = ration; i < SQUAT; i++) {
            vm.prank(_squatter(i));
            vm.expectRevert(IExposureLedger.ApproveLockBelowFloor.selector);
            registry.voteOnProposal(address(gov), PID, IGuardianRegistry.GuardianVoteType.Approve, type(uint256).max);
        }
        (address[] memory seated,) = ledger.approversOf(address(gov), PID);
        assertEq(seated.length, ration, "the sub-share arm stops at half the slots");

        // The honest, well-capitalised guardian gets a slot -- this reverted
        // `NewSideFull` before the fix.
        assertGt(ledger.slashableBondUsd(whale), needUsd, "the whale could cover the WHOLE need alone");
        _approve(whale, PID);
        (address[] memory withWhale,) = ledger.approversOf(address(gov), PID);
        assertEq(withWhale.length, ration + 1, "and it is seated alongside them");
        assertEq(withWhale[ration], whale);

        // Consequence at execute: the quorum is met, so
        // `SyndicateGovernor._deriveAndStoreEffectiveCapital` no longer throttles.
        (uint256 raisedUsd, uint256 requiredUsd) =
            ledger.requireApproveQuorum(address(gov), PID, address(asset), REQUIRED_COVERAGE);
        assertEq(requiredUsd, needUsd);
        assertGe(raisedUsd, requiredUsd, "the proposal is fully covered again");
    }

    /// @notice Control: below the ration a guardian whose whole budget is under
    ///         one slot's share still keeps its voice by committing everything.
    function test_F3_subShareGuardianStillSeatsBelowTheRation() public {
        uint256 needUsd = ledger.coverageUsd(address(asset), REQUIRED_COVERAGE);
        uint256 shareUsd = (needUsd + ledger.APPROVER_SLOTS() - 1) / ledger.APPROVER_SLOTS();
        uint256 ration = ledger.APPROVER_SLOTS() / 2;

        // On an empty array, and again on the last rationed slot.
        _approve(_squatter(0), PID);
        assertEq(ledger.lockOf(address(gov), PID, _squatter(0)), MIN_STAKE, "the whole budget books");

        for (uint256 i = 1; i < ration - 1; i++) {
            _approve(_squatter(i), PID);
        }
        (address[] memory before,) = ledger.approversOf(address(gov), PID);
        assertEq(before.length, ration - 1, "one rationed slot left");

        address last = _squatter(ration - 1);
        assertLt(ledger.slashableBondUsd(last), shareUsd, "fixture: still a sub-share guardian");
        _approve(last, PID);
        (address[] memory seated,) = ledger.approversOf(address(gov), PID);
        assertEq(seated.length, ration, "the last rationed slot is still reachable on the whole budget");
        assertEq(seated[ration - 1], last);
    }

    /// @notice Scope bound, unchanged by the fix: the squat consumes each
    ///         sybil's WHOLE budget at `kNumerator == 1`, so the same cohort
    ///         cannot underwrite a second proposal concurrently.
    function test_F3_cohortCannotSquatTwoProposalsAtOnce() public {
        for (uint256 i = 0; i < ledger.APPROVER_SLOTS() / 2; i++) {
            _approve(_squatter(i), PID);
        }
        uint256 voteEnd = vm.getBlockTimestamp();
        vm.prank(address(gov));
        registry.registerReview(2, voteEnd, voteEnd + REVIEW_PERIOD);
        registry.openReview(address(gov), 2);

        vm.prank(_squatter(0));
        vm.expectRevert(IExposureLedger.ApproveLockBelowFloor.selector);
        registry.voteOnProposal(address(gov), 2, IGuardianRegistry.GuardianVoteType.Approve, type(uint256).max);
    }
}
