// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {SyndicateGovernor} from "../../../src/SyndicateGovernor.sol";
import {SyndicateFactory} from "../../../src/SyndicateFactory.sol";
import {GuardianRegistry} from "../../../src/GuardianRegistry.sol";
import {IGuardianRegistry} from "../../../src/interfaces/IGuardianRegistry.sol";
import {StakedWood} from "../../../src/StakedWood.sol";
import {ISyndicateGovernor} from "../../../src/interfaces/ISyndicateGovernor.sol";
import {GovernorParameters} from "../../../src/GovernorParameters.sol";

import {ERC20Mock} from "../../mocks/ERC20Mock.sol";

/// @title ProtocolHandler
/// @notice Bounded fuzz-action surface for the protocol invariant harness
///         (INV-2 / INV-3 / INV-30 / INV-33 / INV-46). Drives the governance
///         and registry surfaces that the target invariants observe.
///
///         Post-split (Task 7.1): guardian staking + `flushBurn` moved to
///         `StakedWood`. The handler drives staking on sWOOD and the pause /
///         review surface on the registry. `flushBurn` lives on sWOOD, which
///         has NO pause mechanism — it is therefore no longer part of the
///         INV-46 pause revert-matrix (a faithful consequence of the split,
///         not a weakened assertion). The still-pause-guarded registry writes
///         (`voteOnProposal`, `openReview`, `resolveReview`,
///         `finalizeEmergency`) keep their attempt/revert bookkeeping.
///
///         Actor set: 5 shareholders, 3 agents, 10 guardians, 1 owner.
contract ProtocolHandler is Test {
    SyndicateGovernor public governor;
    SyndicateFactory public factory;
    GuardianRegistry public registry;
    StakedWood public swood;
    ERC20Mock public wood;

    address public governorOwner;
    address public factoryOwner;
    address public registryOwner;

    // Actor pools.
    address[] public shareholders; // length 5
    address[] public agents; // length 3
    address[] public guardians; // length 10

    // INV-46 revert-matrix bookkeeping — set when a pause-guarded registry
    // call is made during pause; the invariant contract reads these to verify
    // the required revert actually happened.
    uint256 public pausedCallAttempts;
    uint256 public pausedCallReverts;

    // Pending-change seen counters — debug aids.
    uint256 public queueSuccesses;

    constructor(
        SyndicateGovernor _governor,
        SyndicateFactory _factory,
        GuardianRegistry _registry,
        StakedWood _swood,
        ERC20Mock _wood,
        address _governorOwner,
        address _factoryOwner,
        address _registryOwner
    ) {
        governor = _governor;
        factory = _factory;
        registry = _registry;
        swood = _swood;
        wood = _wood;
        governorOwner = _governorOwner;
        factoryOwner = _factoryOwner;
        registryOwner = _registryOwner;

        for (uint256 i = 0; i < 5; i++) {
            shareholders.push(makeAddr(string(abi.encodePacked("shareholder", vm.toString(i)))));
        }
        for (uint256 i = 0; i < 3; i++) {
            agents.push(makeAddr(string(abi.encodePacked("agent", vm.toString(i)))));
        }
        for (uint256 i = 0; i < 10; i++) {
            address g = makeAddr(string(abi.encodePacked("guardian", vm.toString(i))));
            guardians.push(g);
            wood.mint(g, 1_000_000e18);
            // Staking lives in sWOOD post-split — approve sWOOD.
            vm.prank(g);
            wood.approve(address(swood), type(uint256).max);
        }
    }

    // ──────────────────────────────────────────────────────────────
    // Governor parameter lifecycle — drives INV-30
    // ──────────────────────────────────────────────────────────────

    /// @dev Queue a new `protocolFeeBps` change. The setter's own guard
    ///      refuses to queue a non-zero bps value while recipient == 0 —
    ///      so INV-30 cannot be violated through the queue edge.
    function queueProtocolFeeBps(
        uint256 /*bpsSeed*/
    )
        external {
        // setProtocolFeeBps moved to ProtocolConfig in per-vault governor design.
        // No-op to keep selector set stable across refactor.
    }

    /// @dev Queue a new protocol-fee recipient change. Zero-address is rejected
    ///      by the setter so the queued newValue is always nonzero.
    function queueProtocolFeeRecipient(
        uint256 /*recipientSeed*/
    )
        external {
        // setProtocolFeeRecipient moved to ProtocolConfig in per-vault governor design.
        // No-op to keep selector set stable across refactor.
    }

    // ──────────────────────────────────────────────────────────────
    // Registry pause surface — drives INV-46
    // ──────────────────────────────────────────────────────────────

    function pauseRegistry() external {
        vm.prank(registryOwner);
        try registry.pause() {} catch {}
    }

    function unpauseRegistry() external {
        vm.prank(registryOwner);
        try registry.unpause() {} catch {}
    }

    /// @dev Attempt `flushBurn` on sWOOD. Post-split sWOOD has NO pause, so
    ///      this is no longer a pause-guarded call — it is fuzzed for coverage
    ///      but NOT tracked in the INV-46 revert matrix.
    function tryFlushBurn() external {
        try swood.flushBurn() {} catch {}
    }

    /// @dev Attempt `voteOnProposal` with pause semantics tracking. Guarded by
    ///      `whenNotPaused` — every attempt during pause MUST revert.
    function tryVoteOnProposal(uint256 actorSeed, uint256 supportSeed) external {
        address g = guardians[bound(actorSeed, 0, guardians.length - 1)];
        IGuardianRegistry.GuardianVoteType s = (supportSeed % 2 == 0)
            ? IGuardianRegistry.GuardianVoteType.Approve
            : IGuardianRegistry.GuardianVoteType.Block;
        bool isPaused = registry.paused();
        if (isPaused) pausedCallAttempts += 1;
        vm.prank(g);
        try registry.voteOnProposal(address(governor), 1, s, 0) {}
        catch {
            if (isPaused) pausedCallReverts += 1;
        }
    }

    /// @dev Attempt `openReview`. Guarded by `whenNotPaused`.
    function tryOpenReview(uint256 proposalSeed) external {
        uint256 pid = bound(proposalSeed, 1, 3);
        bool isPaused = registry.paused();
        if (isPaused) pausedCallAttempts += 1;
        try registry.openReview(address(governor), pid) {}
        catch {
            if (isPaused) pausedCallReverts += 1;
        }
    }

    /// @dev Attempt `resolveReview`. Guarded by `whenNotPaused`.
    function tryResolveReview(uint256 proposalSeed) external {
        uint256 pid = bound(proposalSeed, 1, 3);
        bool isPaused = registry.paused();
        if (isPaused) pausedCallAttempts += 1;
        try registry.resolveReview(address(governor), pid) {}
        catch {
            if (isPaused) pausedCallReverts += 1;
        }
    }

    /// @dev Attempt `finalizeEmergency`. Guarded by `whenNotPaused` + `onlyGovernor`.
    function tryFinalizeEmergency(uint256 proposalSeed) external {
        uint256 pid = bound(proposalSeed, 1, 3);
        bool isPaused = registry.paused();
        if (isPaused) pausedCallAttempts += 1;
        try registry.finalizeEmergency(pid) {}
        catch {
            if (isPaused) pausedCallReverts += 1;
        }
    }

    // ──────────────────────────────────────────────────────────────
    // Stake / unstake — sWOOD; callable at any time (sWOOD has no pause)
    // ──────────────────────────────────────────────────────────────

    /// @dev Stake action — keeps the guardian cohort non-empty across fuzzing.
    function stake(uint256 actorSeed, uint256 amountSeed) external {
        address g = guardians[bound(actorSeed, 0, guardians.length - 1)];
        uint256 amount = bound(amountSeed, swood.minGuardianStake(), 100_000e18);
        vm.prank(g);
        try swood.stakeAsGuardian(amount, 1) {} catch {}
    }

    function requestUnstake(uint256 actorSeed) external {
        address g = guardians[bound(actorSeed, 0, guardians.length - 1)];
        vm.prank(g);
        try swood.requestUnstakeGuardian() {} catch {}
    }

    function cancelUnstake(uint256 actorSeed) external {
        address g = guardians[bound(actorSeed, 0, guardians.length - 1)];
        vm.prank(g);
        try swood.cancelUnstakeGuardian() {} catch {}
    }

    function claimUnstake(uint256 actorSeed) external {
        address g = guardians[bound(actorSeed, 0, guardians.length - 1)];
        vm.prank(g);
        try swood.claimUnstakeGuardian() {} catch {}
    }

    // ──────────────────────────────────────────────────────────────
    // Time
    // ──────────────────────────────────────────────────────────────

    function warp(uint256 delta) external {
        delta = bound(delta, 1 hours, 3 days);
        vm.warp(block.timestamp + delta);
    }

    // ──────────────────────────────────────────────────────────────
    // Views
    // ──────────────────────────────────────────────────────────────

    function getGuardians() external view returns (address[] memory) {
        return guardians;
    }

    function getShareholders() external view returns (address[] memory) {
        return shareholders;
    }

    function getAgents() external view returns (address[] memory) {
        return agents;
    }
}
