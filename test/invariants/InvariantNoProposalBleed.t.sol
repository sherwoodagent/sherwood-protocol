// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {GuardianRegistry} from "../../src/GuardianRegistry.sol";
import {IGuardianRegistry} from "../../src/interfaces/IGuardianRegistry.sol";
import {StakedWood} from "../../src/StakedWood.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockGovernorMinimal} from "../mocks/MockGovernorMinimal.sol";

/// @notice Randomly drives review + emergency lifecycle actions under TWO
///         governors sharing one registry and one proposalId space. Fuzzed
///         action ordering must never leak state across the composite keys.
contract ProposalBleedHandler is Test {
    GuardianRegistry public registry;
    StakedWood public swood;
    ERC20Mock public wood;
    MockGovernorMinimal public governorA;
    MockGovernorMinimal public governorB;

    address[3] public guardians;
    uint256 public constant PID_SPACE = 3; // pids 1..3, shared across A and B
    uint256 public constant REVIEW_PERIOD = 24 hours;

    // Ground truth of approve-votes cast, per (governor, pid, guardian).
    mapping(address => mapping(uint256 => mapping(address => bool))) public approvedUnder;

    constructor(
        GuardianRegistry _registry,
        StakedWood _swood,
        ERC20Mock _wood,
        MockGovernorMinimal _a,
        MockGovernorMinimal _b,
        address[3] memory _guardians
    ) {
        registry = _registry;
        swood = _swood;
        wood = _wood;
        governorA = _a;
        governorB = _b;
        guardians = _guardians;
    }

    function _gov(uint256 seed) internal view returns (MockGovernorMinimal) {
        return seed % 2 == 0 ? governorA : governorB;
    }

    function openReview(uint256 seed) external {
        MockGovernorMinimal gov = _gov(seed);
        uint256 pid = 1 + (seed % PID_SPACE);
        (bool opened,,,) = registry.getReviewState(address(gov), pid);
        if (opened) return;
        uint256 ve = vm.getBlockTimestamp();
        gov.setProposal(pid, ve, ve + REVIEW_PERIOD);
        registry.openReview(address(gov), pid);
    }

    function voteApprove(uint256 seed) external {
        MockGovernorMinimal gov = _gov(seed);
        uint256 pid = 1 + (seed % PID_SPACE);
        address g = guardians[(seed / 7) % 3];
        (bool opened, bool resolved,,) = registry.getReviewState(address(gov), pid);
        if (!opened || resolved) return;
        // Skip if this guardian already voted under (gov, pid) or the window closed.
        if (approvedUnder[address(gov)][pid][g]) return;
        vm.prank(g);
        try registry.voteOnProposal(address(gov), pid, IGuardianRegistry.GuardianVoteType.Approve, 0) {
            approvedUnder[address(gov)][pid][g] = true;
        } catch {}
    }

    function openEmergency(uint256 seed) external {
        MockGovernorMinimal gov = _gov(seed);
        uint256 pid = 1 + (seed % PID_SPACE);
        if (registry.isEmergencyOpen(address(gov), pid)) return;
        BatchExecutorLib.Call[] memory calls = new BatchExecutorLib.Call[](1);
        // Marker encodes (gov, pid) so the invariant can verify the payload
        // that comes back out belongs to the right composite key.
        calls[0] = BatchExecutorLib.Call({
            target: address(uint160(uint256(keccak256(abi.encode(address(gov), pid))))), data: "", value: 0
        });
        vm.prank(address(gov));
        try registry.openEmergency(pid, keccak256(abi.encode(calls)), calls) {} catch {}
    }

    function warp(uint256 seed) external {
        vm.warp(vm.getBlockTimestamp() + bound(seed, 1 hours, 30 hours));
    }
}

contract InvariantNoProposalBleed is StdInvariant, Test {
    GuardianRegistry internal registry;
    StakedWood internal swood;
    ERC20Mock internal wood;
    MockGovernorMinimal internal governorA;
    MockGovernorMinimal internal governorB;
    ProposalBleedHandler internal handler;

    address internal regOwner = address(0xA11CE);
    address internal regFactory = address(0xFAC10);
    address[3] internal guardians;

    function setUp() public {
        wood = new ERC20Mock("WOOD", "WOOD", 18);
        governorA = new MockGovernorMinimal();
        governorB = new MockGovernorMinimal();
        guardians = [makeAddr("g1"), makeAddr("g2"), makeAddr("g3")];

        StakedWood swoodImpl = new StakedWood();
        bytes memory swoodInit = abi.encodeCall(
            StakedWood.initialize,
            (StakedWood.InitParams({
                    owner: regOwner,
                    wood: address(wood),
                    factory: regFactory,
                    minGuardianStake: 10_000e18,
                    coolDownPeriod: 7 days,
                    minOwnerStake: 10_000e18,
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
        bytes memory regInit =
            abi.encodeCall(GuardianRegistry.initialize, (regOwner, regFactory, address(swood), 24 hours, 3000));
        registry = GuardianRegistry(address(new ERC1967Proxy(address(regImpl), regInit)));

        vm.prank(regOwner);
        swood.setRegistry(address(registry));

        vm.startPrank(regFactory);
        registry.addGovernor(address(governorA));
        registry.addGovernor(address(governorB));
        vm.stopPrank();

        for (uint256 i = 0; i < 3; i++) {
            address g = guardians[i];
            wood.mint(g, 20_000e18);
            vm.startPrank(g);
            wood.approve(address(swood), type(uint256).max);
            swood.stakeAsGuardian(20_000e18, i + 1);
            vm.stopPrank();
        }
        vm.warp(vm.getBlockTimestamp() + 1);

        handler = new ProposalBleedHandler(registry, swood, wood, governorA, governorB, guardians);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = ProposalBleedHandler.openReview.selector;
        selectors[1] = ProposalBleedHandler.voteApprove.selector;
        selectors[2] = ProposalBleedHandler.openEmergency.selector;
        selectors[3] = ProposalBleedHandler.warp.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @notice Approver sets under (A, pid) and (B, pid) must exactly mirror
    ///         the handler's ground truth — no vote recorded under one
    ///         governor may ever appear under the other.
    function invariant_noCrossGovernorBleed() public view {
        MockGovernorMinimal[2] memory govs = [governorA, governorB];
        for (uint256 gi = 0; gi < 2; gi++) {
            address gov = address(govs[gi]);
            address other = address(govs[1 - gi]);
            for (uint256 pid = 1; pid <= handler.PID_SPACE(); pid++) {
                (address[] memory approvers, uint128[] memory weights,) = registry.getApproverWeights(gov, pid);
                for (uint256 i = 0; i < approvers.length; i++) {
                    // Every recorded approver must trace to a real vote under
                    // THIS governor (never the other one).
                    assertTrue(
                        handler.approvedUnder(gov, pid, approvers[i]),
                        "approver present without a matching vote under this governor"
                    );
                    assertGt(uint256(weights[i]), 0, "approver with zero weight");
                }
                // And every ground-truth vote must be visible under its own key.
                for (uint256 g = 0; g < 3; g++) {
                    address guardian = handler.guardians(g);
                    if (handler.approvedUnder(gov, pid, guardian)) {
                        bool found;
                        for (uint256 i = 0; i < approvers.length; i++) {
                            if (approvers[i] == guardian) found = true;
                        }
                        assertTrue(found, "vote cast under governor missing from its approver set");
                    }
                    // A vote under `gov` must NOT make the guardian an approver
                    // under `other` unless independently cast there.
                    if (!handler.approvedUnder(other, pid, guardian)) {
                        (address[] memory otherApprovers,,) = registry.getApproverWeights(other, pid);
                        for (uint256 i = 0; i < otherApprovers.length; i++) {
                            assertTrue(otherApprovers[i] != guardian, "vote bled across governors");
                        }
                    }
                }
            }
        }
    }
}
