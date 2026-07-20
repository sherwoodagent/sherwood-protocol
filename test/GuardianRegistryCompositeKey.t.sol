// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {GuardianRegistry} from "../src/GuardianRegistry.sol";
import {IGuardianRegistry} from "../src/interfaces/IGuardianRegistry.sol";
import {StakedWood} from "../src/StakedWood.sol";
import {BatchExecutorLib} from "../src/BatchExecutorLib.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {MockGovernorMinimal} from "./mocks/MockGovernorMinimal.sol";

/// @title GuardianRegistryCompositeKey.t
/// @notice Per-vault governor (Task 19): two authorized governors submit the
///         SAME proposalId to one shared registry. The composite review key
///         `keccak256(abi.encode(governor, proposalId))` must keep every
///         proposalId-keyed mapping fully disjoint — review votes, approver
///         weights, emergency calls, and the emergency slash target.
contract GuardianRegistryCompositeKeyTest is Test {
    GuardianRegistry internal registry;
    StakedWood internal swood;
    ERC20Mock internal wood;
    MockGovernorMinimal internal governorA;
    MockGovernorMinimal internal governorB;

    address internal regOwner = address(0xA11CE);
    address internal regFactory = address(0xFAC10);

    address internal guardian1 = makeAddr("guardian1");
    address internal guardian2 = makeAddr("guardian2");
    address internal guardian3 = makeAddr("guardian3");

    address internal ownerA = makeAddr("vaultOwnerA");
    address internal ownerB = makeAddr("vaultOwnerB");
    address internal vaultA = makeAddr("vaultA");
    address internal vaultB = makeAddr("vaultB");

    uint256 constant REVIEW_PERIOD = 24 hours;
    uint256 constant BLOCK_QUORUM_BPS = 3000;
    uint256 constant PID = 1; // deliberately identical under both governors
    uint256 constant STAKE = 20_000e18; // 3 stakers = 60k >= MIN_COHORT (50k)
    uint256 constant OWNER_BOND = 10_000e18;

    function setUp() public {
        wood = new ERC20Mock("WOOD", "WOOD", 18);
        governorA = new MockGovernorMinimal();
        governorB = new MockGovernorMinimal();

        StakedWood swoodImpl = new StakedWood();
        bytes memory swoodInit = abi.encodeCall(
            StakedWood.initialize,
            (StakedWood.InitParams({
                    owner: regOwner,
                    wood: address(wood),
                    factory: regFactory,
                    minGuardianStake: 10_000e18,
                    coolDownPeriod: 7 days,
                    minOwnerStake: OWNER_BOND,
                    minSlashBps: 1000,
                    maxSlashBps: 9999,
                    maxDelegatedSlashBps: 2000,
                    ageFloorBps: 2500,
                    maturationPeriod: 30 days,
                    delegatedWeightCapX: 4
                }))
        );
        swood = StakedWood(address(new ERC1967Proxy(address(swoodImpl), swoodInit)));

        GuardianRegistry regImpl = new GuardianRegistry(6 hours);
        bytes memory regInit = abi.encodeCall(
            GuardianRegistry.initialize, (regOwner, regFactory, address(swood), REVIEW_PERIOD, BLOCK_QUORUM_BPS)
        );
        registry = GuardianRegistry(address(new ERC1967Proxy(address(regImpl), regInit)));

        vm.prank(regOwner);
        swood.setRegistry(address(registry));

        // Authorize BOTH governors (the factory does this per createSyndicate).
        vm.startPrank(regFactory);
        registry.addGovernor(address(governorA));
        registry.addGovernor(address(governorB));
        vm.stopPrank();

        // Cohort: 3 guardians × 20k = 60k total (≥ MIN_COHORT_STAKE_AT_OPEN).
        _stake(guardian1, 1);
        _stake(guardian2, 2);
        _stake(guardian3, 3);

        // Age-weighted voting: mature the cohort to par so vote weights equal
        // raw stake.
        skip(30 days);

        // C-1: reviews snapshot votable stake at t-1 — advance past staking.
        vm.warp(vm.getBlockTimestamp() + 1);
    }

    function _stake(address g, uint256 agentId) internal {
        wood.mint(g, STAKE);
        vm.startPrank(g);
        wood.approve(address(swood), type(uint256).max);
        swood.stakeAsGuardian(STAKE, agentId);
        vm.stopPrank();
    }

    function _openReviewUnder(MockGovernorMinimal gov) internal {
        uint256 ve = vm.getBlockTimestamp();
        gov.setProposal(PID, ve, ve + REVIEW_PERIOD);
        registry.openReview(address(gov), PID);
    }

    function _callsFor(address target) internal pure returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({target: target, data: hex"deadbeef", value: 0});
    }

    // ──────────────────────────────────────────────────────────────
    // Review-state isolation
    // ──────────────────────────────────────────────────────────────

    /// @notice Votes cast under governor A at pid=1 must be invisible under
    ///         governor B's pid=1 — flags, weights, and approver arrays.
    function test_reviewStateIsolatedAcrossGovernors() public {
        _openReviewUnder(governorA);
        _openReviewUnder(governorB);

        // Approve under A only.
        vm.prank(guardian1);
        registry.voteOnProposal(address(governorA), PID, IGuardianRegistry.GuardianVoteType.Approve, 0);

        // A: opened, approver recorded with weight.
        (bool openedA,,,) = registry.getReviewState(address(governorA), PID);
        assertTrue(openedA, "A review open");
        (address[] memory approversA, uint128[] memory weightsA, uint128 denomA) =
            registry.getApproverWeights(address(governorA), PID);
        assertEq(approversA.length, 1, "A has one approver");
        assertEq(approversA[0], guardian1, "A approver identity");
        assertEq(uint256(weightsA[0]), STAKE, "A approver weight");
        assertEq(uint256(denomA), STAKE, "A approve denom");

        // B: opened but ZERO bleed from A's vote.
        (bool openedB,,,) = registry.getReviewState(address(governorB), PID);
        assertTrue(openedB, "B review open");
        (address[] memory approversB,, uint128 denomB) = registry.getApproverWeights(address(governorB), PID);
        assertEq(approversB.length, 0, "B approvers untouched by A's vote");
        assertEq(uint256(denomB), 0, "B approve weight untouched");

        // Block under B: 20k / 60k = 33% >= the 30% quorum. Resolutions must
        // diverge — A (no A-side blocks) unblocked, B blocked.
        vm.prank(guardian2);
        registry.voteOnProposal(address(governorB), PID, IGuardianRegistry.GuardianVoteType.Block, 5000);

        vm.warp(vm.getBlockTimestamp() + REVIEW_PERIOD + 1);
        vm.prank(address(governorA));
        bool blockedA = registry.resolveReview(address(governorA), PID);
        vm.prank(address(governorB));
        bool blockedB = registry.resolveReview(address(governorB), PID);
        assertFalse(blockedA, "A resolves unblocked (no A-side block votes)");
        assertTrue(blockedB, "B resolves blocked (33% >= 30% quorum)");
    }

    // ──────────────────────────────────────────────────────────────
    // Emergency-calls isolation
    // ──────────────────────────────────────────────────────────────

    /// @notice Emergency calldata stored under (A, pid) must never surface
    ///         under (B, pid) — each governor finalizes its OWN batch.
    function test_emergencyCallsIsolatedAcrossGovernors() public {
        BatchExecutorLib.Call[] memory callsA = _callsFor(address(0xAAAA));
        BatchExecutorLib.Call[] memory callsB = _callsFor(address(0xBBBB));

        vm.prank(address(governorA));
        registry.openEmergency(PID, keccak256(abi.encode(callsA)), callsA);
        vm.prank(address(governorB));
        registry.openEmergency(PID, keccak256(abi.encode(callsB)), callsB);

        assertTrue(registry.isEmergencyOpen(address(governorA), PID), "A emergency open");
        assertTrue(registry.isEmergencyOpen(address(governorB), PID), "B emergency open");

        vm.warp(vm.getBlockTimestamp() + REVIEW_PERIOD + 1);

        vm.prank(address(governorA));
        (bool blockedA, BatchExecutorLib.Call[] memory outA) = registry.finalizeEmergency(PID);
        assertFalse(blockedA, "A not blocked");
        assertEq(outA.length, 1, "A calls length");
        assertEq(outA[0].target, address(0xAAAA), "A gets ITS calls back, not B's");

        vm.prank(address(governorB));
        (bool blockedB, BatchExecutorLib.Call[] memory outB) = registry.finalizeEmergency(PID);
        assertFalse(blockedB, "B not blocked");
        assertEq(outB[0].target, address(0xBBBB), "B gets ITS calls back, not A's");
    }

    // ──────────────────────────────────────────────────────────────
    // Emergency slash targets the correct vault
    // ──────────────────────────────────────────────────────────────

    /// @notice A block-quorum'd emergency under governor A must slash vault A's
    ///         owner bond via `er.governor` — vault B's bond stays whole even
    ///         though B has an open emergency at the SAME pid.
    function test_emergencyResolveSlashesCorrectVault() public {
        // Bond both owners to their vaults (factory-only bind).
        _bond(ownerA, vaultA);
        _bond(ownerB, vaultB);

        // Wire pid → vault on each mock so `_resolveEmergency` can look up
        // the slash target through `er.governor`.
        uint256 ve = vm.getBlockTimestamp();
        governorA.setProposalWithVault(PID, ve, ve + REVIEW_PERIOD, vaultA);
        governorB.setProposalWithVault(PID, ve, ve + REVIEW_PERIOD, vaultB);

        BatchExecutorLib.Call[] memory calls = _callsFor(address(0xCCCC));
        bytes32 h = keccak256(abi.encode(calls));
        vm.prank(address(governorA));
        registry.openEmergency(PID, h, calls);
        vm.prank(address(governorB));
        registry.openEmergency(PID, h, calls);

        // Block-quorum A's emergency only: 40k / 60k >= 30%.
        vm.prank(guardian1);
        registry.voteBlockEmergencySettle(address(governorA), PID);
        vm.prank(guardian2);
        registry.voteBlockEmergencySettle(address(governorA), PID);

        vm.warp(vm.getBlockTimestamp() + REVIEW_PERIOD + 1);

        uint256 bondABefore = swood.ownerStake(vaultA);
        uint256 bondBBefore = swood.ownerStake(vaultB);
        assertEq(bondABefore, OWNER_BOND, "pre: A bonded");
        assertEq(bondBBefore, OWNER_BOND, "pre: B bonded");

        // Permissionless keeper resolution — commits the slash for A.
        registry.resolveEmergencyReview(address(governorA), PID);
        registry.resolveEmergencyReview(address(governorB), PID);

        assertLt(swood.ownerStake(vaultA), bondABefore, "vault A bond slashed");
        assertEq(swood.ownerStake(vaultB), bondBBefore, "vault B bond UNTOUCHED");
    }

    function _bond(address owner_, address vault_) internal {
        wood.mint(owner_, OWNER_BOND);
        vm.startPrank(owner_);
        wood.approve(address(swood), type(uint256).max);
        swood.prepareOwnerStake(OWNER_BOND);
        vm.stopPrank();
        vm.prank(regFactory);
        swood.bindOwnerStake(owner_, vault_);
    }
}
