// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {GuardianRegistry} from "../../../src/GuardianRegistry.sol";
import {IGuardianRegistry} from "../../../src/interfaces/IGuardianRegistry.sol";
import {StakedWood} from "../../../src/StakedWood.sol";
import {ERC20Mock} from "../../mocks/ERC20Mock.sol";
import {MockGovernorMinimal} from "../../mocks/MockGovernorMinimal.sol";
import {MockERC4626Vault} from "../../mocks/MockERC4626Vault.sol";

/// @title GuardianHandler
/// @notice Bounded fuzz-action surface for the GuardianRegistry invariant
///         harness (Task 28). Wraps the registry + sWOOD and their mocks,
///         exposing deterministic action functions the Foundry fuzzer calls
///         in randomized sequences.
///
///         Post-split (Task 7.1): guardian staking lives in `StakedWood`;
///         review voting / resolution and the slash-appeal reserve stay on
///         `GuardianRegistry`. The handler drives the staking surface on sWOOD
///         and the review surface on the registry.
///
///         Task 11.2: the handler now exercises ALL FOUR WOOD-holding buckets
///         on `StakedWood` so the WOOD-conservation invariant is meaningful:
///         (1) guardian own stake, (2) delegation pools (`poolTokens`),
///         (3) owner bonds, (4) the `_pendingBurn` queue (via slashing).
contract GuardianHandler is Test {
    GuardianRegistry public registry;
    StakedWood public swood;
    ERC20Mock public wood;
    MockGovernorMinimal public governor;
    MockERC4626Vault public vault;

    address public registryOwner;
    address public factory;

    address[] public actors;
    uint256[] public proposalIds;
    uint256[] public blockedProposalIds;

    /// @dev Synthetic vault addresses the handler binds owner stakes to. The
    ///      harness `vault` is element 0 so review flows (which read the
    ///      registry's `vault`) and owner-bond flows share it.
    address[] public bondVaults;

    /// @dev Delegates the handler has ever delegated to — the share-consistency
    ///      invariant iterates this set.
    address[] public touchedDelegates;
    mapping(address => bool) internal _seenDelegate;

    /// @dev Vaults that currently hold a bound owner stake. The production
    ///      factory calls `bindOwnerStake` exactly once per freshly-created
    ///      vault, so a vault is never double-bound. `bindOwnerStake` on an
    ///      already-bound vault overwrites `_ownerStakes[vault]` and orphans the
    ///      prior owner's WOOD — an unreachable state in production. The handler
    ///      enforces the one-vault-one-bind invariant so the conservation check
    ///      models real factory behaviour.
    mapping(address => bool) internal _vaultBound;

    /// @dev Per-owner unbound prepared-stake amount. `StakedWood.preparedStakeOf`
    ///      keeps returning the amount AFTER the slot is bound (only the `bound`
    ///      flag flips), so summing that getter would double-count a stake that
    ///      has already moved into `_ownerStakes`. The handler tracks the
    ///      *unbound* amount itself: set on `prepareOwnerStake`, cleared on
    ///      `bindOwnerStake` / `cancelPreparedStake`.
    mapping(address => uint256) public unboundPrepared;

    uint256 public currentProposalId;

    /// @dev Per-proposal snapshot of approvers taken just before resolveReview.
    ///      INV-2 uses this to verify slashed approvers had stake at resolve time.
    mapping(uint256 => address[]) public _approversSnapshot;

    // Stats for debugging / logs.
    uint256 public successfulStakes;
    uint256 public successfulResolves;
    uint256 public successfulDelegations;
    uint256 public successfulBonds;
    uint256 public successfulSlashes;

    constructor(
        GuardianRegistry _registry,
        StakedWood _swood,
        ERC20Mock _wood,
        MockGovernorMinimal _governor,
        MockERC4626Vault _vault,
        address _registryOwner,
        address _factory
    ) {
        registry = _registry;
        swood = _swood;
        wood = _wood;
        governor = _governor;
        vault = _vault;
        registryOwner = _registryOwner;
        factory = _factory;

        for (uint256 i = 0; i < 5; i++) {
            address a = makeAddr(string(abi.encodePacked("actor", vm.toString(i))));
            actors.push(a);
            wood.mint(a, 1_000_000e18);
            vm.prank(a);
            wood.approve(address(swood), type(uint256).max);
        }

        // Owner-bond targets. Element 0 is the harness vault so review +
        // owner-bond flows act on the same address.
        bondVaults.push(address(_vault));
        for (uint256 i = 1; i < 4; i++) {
            bondVaults.push(makeAddr(string(abi.encodePacked("bondVault", vm.toString(i)))));
        }

        // Prefund the owner so fundSlashAppealReserve can pull. The reserve
        // lives on the registry, so the approval targets the registry.
        wood.mint(registryOwner, 10_000_000e18);
        vm.prank(registryOwner);
        wood.approve(address(registry), type(uint256).max);
    }

    // ──────────────────────────────────────────────────────────────
    // Guardian actions (own stake → sWOOD bucket 1)
    // ──────────────────────────────────────────────────────────────

    function stake(uint256 actorSeed, uint256 amount) external {
        address a = actors[bound(actorSeed, 0, actors.length - 1)];
        amount = bound(amount, swood.minGuardianStake(), 50_000e18);
        vm.prank(a);
        try swood.stakeAsGuardian(amount, 1) {
            successfulStakes += 1;
        } catch {}
    }

    function requestUnstake(uint256 actorSeed) external {
        address a = actors[bound(actorSeed, 0, actors.length - 1)];
        vm.prank(a);
        try swood.requestUnstakeGuardian() {} catch {}
    }

    function cancelUnstake(uint256 actorSeed) external {
        address a = actors[bound(actorSeed, 0, actors.length - 1)];
        vm.prank(a);
        try swood.cancelUnstakeGuardian() {} catch {}
    }

    function claimUnstake(uint256 actorSeed) external {
        address a = actors[bound(actorSeed, 0, actors.length - 1)];
        vm.prank(a);
        try swood.claimUnstakeGuardian() {} catch {}
    }

    // ──────────────────────────────────────────────────────────────
    // Delegation actions (pool tokens → sWOOD bucket 2)
    // ──────────────────────────────────────────────────────────────

    function delegate(uint256 delegatorSeed, uint256 delegateSeed, uint256 amount) external {
        address delegator = actors[bound(delegatorSeed, 0, actors.length - 1)];
        address delegateAddr = actors[bound(delegateSeed, 0, actors.length - 1)];
        amount = bound(amount, 1e18, 100_000e18);
        vm.prank(delegator);
        try swood.delegateStake(delegateAddr, amount) {
            successfulDelegations += 1;
            if (!_seenDelegate[delegateAddr]) {
                _seenDelegate[delegateAddr] = true;
                touchedDelegates.push(delegateAddr);
            }
        } catch {}
    }

    function requestUnstakeDelegation(uint256 delegatorSeed, uint256 delegateSeed) external {
        address delegator = actors[bound(delegatorSeed, 0, actors.length - 1)];
        address delegateAddr = actors[bound(delegateSeed, 0, actors.length - 1)];
        vm.prank(delegator);
        try swood.requestUnstakeDelegation(delegateAddr) {} catch {}
    }

    function cancelUnstakeDelegation(uint256 delegatorSeed, uint256 delegateSeed) external {
        address delegator = actors[bound(delegatorSeed, 0, actors.length - 1)];
        address delegateAddr = actors[bound(delegateSeed, 0, actors.length - 1)];
        vm.prank(delegator);
        try swood.cancelUnstakeDelegation(delegateAddr) {} catch {}
    }

    function claimUnstakeDelegation(uint256 delegatorSeed, uint256 delegateSeed) external {
        address delegator = actors[bound(delegatorSeed, 0, actors.length - 1)];
        address delegateAddr = actors[bound(delegateSeed, 0, actors.length - 1)];
        vm.prank(delegator);
        try swood.claimUnstakeDelegation(delegateAddr) {} catch {}
    }

    // ──────────────────────────────────────────────────────────────
    // Owner-bond actions (owner stake → sWOOD bucket 3)
    // ──────────────────────────────────────────────────────────────

    function prepareOwnerStake(uint256 actorSeed, uint256 amount) external {
        address a = actors[bound(actorSeed, 0, actors.length - 1)];
        amount = bound(amount, swood.minOwnerStake(), 50_000e18);
        vm.prank(a);
        try swood.prepareOwnerStake(amount) {
            unboundPrepared[a] = amount;
        } catch {}
    }

    function cancelPreparedStake(uint256 actorSeed) external {
        address a = actors[bound(actorSeed, 0, actors.length - 1)];
        vm.prank(a);
        try swood.cancelPreparedStake() {
            unboundPrepared[a] = 0;
        } catch {}
    }

    function bindOwnerStake(uint256 actorSeed, uint256 vaultSeed) external {
        address a = actors[bound(actorSeed, 0, actors.length - 1)];
        address v = bondVaults[bound(vaultSeed, 0, bondVaults.length - 1)];
        // One-vault-one-bind: skip an already-bound vault. Re-binding would
        // overwrite `_ownerStakes[v]` and orphan the prior owner's WOOD — a
        // state the production factory never produces (one bind per fresh
        // vault), so the conservation invariant should not have to model it.
        if (_vaultBound[v]) return;
        vm.prank(factory);
        try swood.bindOwnerStake(a, v) {
            // The bound stake moves into `_ownerStakes[v]`; the prepared slot is
            // no longer unbound. Clear the handler's mirror so the conservation
            // sum counts it once (as owner stake), not twice.
            unboundPrepared[a] = 0;
            _vaultBound[v] = true;
            successfulBonds += 1;
        } catch {}
    }

    function requestUnstakeOwner(uint256 actorSeed, uint256 vaultSeed) external {
        address a = actors[bound(actorSeed, 0, actors.length - 1)];
        address v = bondVaults[bound(vaultSeed, 0, bondVaults.length - 1)];
        vm.prank(a);
        try swood.requestUnstakeOwner(v) {} catch {}
    }

    function claimUnstakeOwner(uint256 actorSeed, uint256 vaultSeed) external {
        address a = actors[bound(actorSeed, 0, actors.length - 1)];
        address v = bondVaults[bound(vaultSeed, 0, bondVaults.length - 1)];
        vm.prank(a);
        try swood.claimUnstakeOwner(v) {
            // `_ownerStakes[v]` is deleted — the slot is free to re-bind.
            _vaultBound[v] = false;
        } catch {}
    }

    // ──────────────────────────────────────────────────────────────
    // Slashing (pending-burn → sWOOD bucket 4)
    // ──────────────────────────────────────────────────────────────

    /// @dev Slashing is `onlyRegistry`. Driving a real review-block to quorum
    ///      from the fuzzer is brittle, so the handler pranks the registry
    ///      directly to exercise the slash path — this mutates own stake,
    ///      `poolTokens` and (on a transfer-failing WOOD) `_pendingBurn`,
    ///      which is exactly the bucket-4 coverage the conservation invariant
    ///      needs. `slashGuardians` clamps `slashBps` to [minSlashBps,
    ///      maxSlashBps] internally; any value is safe to pass.
    function slash(uint256 proposalSeed, uint256 approverSeed, uint256 slashBps) external {
        if (proposalIds.length == 0) return;
        uint256 pid = proposalIds[bound(proposalSeed, 0, proposalIds.length - 1)];
        slashBps = bound(slashBps, 1, 10_000);

        address[] memory approvers = new address[](1);
        approvers[0] = actors[bound(approverSeed, 0, actors.length - 1)];

        vm.prank(address(registry));
        // Pass openedAt = now: the own-slash basis is the raw own-stake
        // checkpoint at openedAt (spec 2026-07-19 §5), so `now` sizes the
        // slash off the approver's current stake and keeps the own-stake
        // leg exercised. (openedAt=0 would find no checkpoint → own basis 0.)
        try swood.slashGuardians(bytes32(uint256(pid)), block.timestamp, approvers, slashBps) {
            successfulSlashes += 1;
        } catch {}
    }

    /// @dev Drains the `_pendingBurn` queue. With a well-behaved mock WOOD the
    ///      queue is normally empty, but exercising the path keeps the
    ///      conservation invariant honest if a slash ever fails to burn.
    function flushBurn() external {
        try swood.flushBurn() {} catch {}
    }

    // ──────────────────────────────────────────────────────────────
    // Review voting + permissionless lifecycle (review → registry)
    // ──────────────────────────────────────────────────────────────

    function vote(uint256 actorSeed, uint256 supportSeed, uint256 proposalSeed) external {
        if (proposalIds.length == 0) return;
        address a = actors[bound(actorSeed, 0, actors.length - 1)];
        uint256 pid = proposalIds[bound(proposalSeed, 0, proposalIds.length - 1)];
        IGuardianRegistry.GuardianVoteType s = (supportSeed % 2 == 0)
            ? IGuardianRegistry.GuardianVoteType.Approve
            : IGuardianRegistry.GuardianVoteType.Block;
        vm.prank(a);
        try registry.voteOnProposal(address(governor), pid, s, 0) {} catch {}
    }

    function openReview(uint256 proposalSeed) external {
        if (proposalIds.length == 0) return;
        uint256 pid = proposalIds[bound(proposalSeed, 0, proposalIds.length - 1)];
        try registry.openReview(address(governor), pid) {} catch {}
    }

    function resolveReview(uint256 proposalSeed) external {
        if (proposalIds.length == 0) return;
        uint256 pid = proposalIds[bound(proposalSeed, 0, proposalIds.length - 1)];

        // Snapshot approvers BEFORE the registry zeroes their stake on a
        // blocked resolve (INV-2 needs to see the slashed set).
        (bool opened, bool alreadyResolved,, bool cohortTooSmall) = registry.getReviewState(address(governor), pid);
        if (opened && !alreadyResolved && !cohortTooSmall) {
            address[] memory snapshot = _snapshotApprovers(pid);
            _approversSnapshot[pid] = snapshot;
        }

        try registry.resolveReview(address(governor), pid) returns (bool blocked) {
            successfulResolves += 1;
            if (blocked) blockedProposalIds.push(pid);
        } catch {}
    }

    // ──────────────────────────────────────────────────────────────
    // Proposals & time
    // ──────────────────────────────────────────────────────────────

    function createProposal(uint256 voteEndOffset, uint256 reviewPeriodOffset) external {
        voteEndOffset = bound(voteEndOffset, 1 hours, 1 days);
        reviewPeriodOffset = bound(reviewPeriodOffset, 1 hours, 1 days);
        currentProposalId += 1;
        uint256 ve = block.timestamp + voteEndOffset;
        uint256 re = ve + reviewPeriodOffset;
        governor.setProposalWithVault(currentProposalId, ve, re, address(vault));
        proposalIds.push(currentProposalId);
    }

    function warp(uint256 delta) external {
        delta = bound(delta, 1, 7 days);
        vm.warp(block.timestamp + delta);
    }

    // ──────────────────────────────────────────────────────────────
    // Slash-appeal reserve (registry-side)
    // ──────────────────────────────────────────────────────────────

    function fundSlashAppealReserve(uint256 amount) external {
        amount = bound(amount, 1e18, 10_000e18);
        vm.prank(registryOwner);
        try registry.fundSlashAppealReserve(amount) {} catch {}
    }

    // ──────────────────────────────────────────────────────────────
    // Views for the invariant contract
    // ──────────────────────────────────────────────────────────────

    function getActors() external view returns (address[] memory) {
        return actors;
    }

    function getBondVaults() external view returns (address[] memory) {
        return bondVaults;
    }

    function getTouchedDelegates() external view returns (address[] memory) {
        return touchedDelegates;
    }

    /// @dev Sum of every actor's UNBOUND prepared owner stake — mirrors what
    ///      sWOOD actually escrows for prepared (not-yet-bound) stakes.
    function totalUnboundPrepared() external view returns (uint256 total) {
        for (uint256 i = 0; i < actors.length; i++) {
            total += unboundPrepared[actors[i]];
        }
    }

    function getAllProposalIds() external view returns (uint256[] memory) {
        return proposalIds;
    }

    function getBlockedProposalIds() external view returns (uint256[] memory) {
        return blockedProposalIds;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    /// @dev Returns the approver list for a proposal by reading the registry's
    ///      `getApproverWeights` view. Used to snapshot before resolve.
    function _snapshotApprovers(uint256 pid) internal view returns (address[] memory) {
        (address[] memory approvers,,) = registry.getApproverWeights(address(governor), pid);
        return approvers;
    }

    function getApproversSnapshot(uint256 pid) external view returns (address[] memory) {
        return _approversSnapshot[pid];
    }
}
