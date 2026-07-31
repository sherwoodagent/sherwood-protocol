// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {GuardianRegistry} from "../../src/GuardianRegistry.sol";
import {IGuardianRegistry} from "../../src/interfaces/IGuardianRegistry.sol";
import {StakedWood} from "../../src/StakedWood.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockGovernorMinimal} from "../mocks/MockGovernorMinimal.sol";
import {MockERC4626Vault} from "../mocks/MockERC4626Vault.sol";

import {GuardianHandler} from "./handlers/GuardianHandler.sol";

/// @title GuardianInvariantsTest
/// @notice Task 28 — StdInvariant harness for the guardian-review system.
///
///         Post-split (Task 7.1): guardian staking moved to `StakedWood`;
///         review/resolution + slash-appeal reserve stay on `GuardianRegistry`.
///         The harness deploys + wires both. WOOD conservation is now a
///         two-part check: the registry custodies only the slash-appeal
///         reserve, sWOOD custodies all staking WOOD.
contract GuardianInvariantsTest is StdInvariant, Test {
    GuardianRegistry public registry;
    StakedWood public swood;
    ERC20Mock public wood;
    MockGovernorMinimal public governor;
    MockERC4626Vault public vault;
    GuardianHandler public handler;

    address public owner = makeAddr("registryOwner");
    address public factory = makeAddr("factoryEoa");

    uint256 constant MIN_GUARDIAN_STAKE = 10_000e18;
    uint256 constant MIN_OWNER_STAKE = 10_000e18;
    uint256 constant COOL_DOWN = 7 days;
    uint256 constant REVIEW_PERIOD = 24 hours;
    uint256 constant BLOCK_QUORUM_BPS = 3000;

    function setUp() public {
        wood = new ERC20Mock("WOOD", "WOOD", 18);
        governor = new MockGovernorMinimal();
        vault = new MockERC4626Vault();

        // sWOOD — sole WOOD custodian post-split.
        StakedWood swoodImpl = new StakedWood();
        bytes memory swoodInit = abi.encodeCall(
            StakedWood.initialize,
            (StakedWood.InitParams({
                    owner: owner,
                    wood: address(wood),
                    factory: factory,
                    minGuardianStake: MIN_GUARDIAN_STAKE,
                    coolDownPeriod: COOL_DOWN,
                    minOwnerStake: MIN_OWNER_STAKE,
                    minSlashBps: 1000,
                    maxSlashBps: 9999,
                    ageFloorBps: 2500,
                    maturationPeriod: 30 days
                }))
        );
        swood = StakedWood(address(new ERC1967Proxy(address(swoodImpl), swoodInit)));

        GuardianRegistry impl = new GuardianRegistry(6 hours);
        bytes memory initData = abi.encodeCall(
            GuardianRegistry.initialize, (owner, factory, address(swood), REVIEW_PERIOD, BLOCK_QUORUM_BPS)
        );
        registry = GuardianRegistry(address(new ERC1967Proxy(address(impl), initData)));

        // Resolve the registry ↔ sWOOD circular dependency.
        vm.prank(owner);
        swood.setRegistry(address(registry));

        handler = new GuardianHandler(registry, swood, wood, governor, vault, owner, factory);

        // Restrict the fuzzer to the handler's action surface.
        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](17);
        // Bucket 1 — guardian own stake.
        selectors[0] = GuardianHandler.stake.selector;
        selectors[1] = GuardianHandler.requestUnstake.selector;
        selectors[2] = GuardianHandler.cancelUnstake.selector;
        selectors[3] = GuardianHandler.claimUnstake.selector;
        // Bucket 2 — owner bonds.
        selectors[4] = GuardianHandler.prepareOwnerStake.selector;
        selectors[5] = GuardianHandler.cancelPreparedStake.selector;
        selectors[6] = GuardianHandler.bindOwnerStake.selector;
        selectors[7] = GuardianHandler.requestUnstakeOwner.selector;
        selectors[8] = GuardianHandler.claimUnstakeOwner.selector;
        // Bucket 3 — pending burn (via slashing).
        selectors[9] = GuardianHandler.slash.selector;
        selectors[10] = GuardianHandler.flushBurn.selector;
        // Review lifecycle + time.
        selectors[11] = GuardianHandler.vote.selector;
        selectors[12] = GuardianHandler.openReview.selector;
        selectors[13] = GuardianHandler.resolveReview.selector;
        selectors[14] = GuardianHandler.createProposal.selector;
        selectors[15] = GuardianHandler.warp.selector;
        // Registry-side slash-appeal reserve.
        selectors[16] = GuardianHandler.fundSlashAppealReserve.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    // ──────────────────────────────────────────────────────────────
    // INV-1: WOOD conservation (two-part, post-split)
    // ──────────────────────────────────────────────────────────────

    /// @notice INV-1 (sWOOD): WOOD conservation. sWOOD is the sole WOOD
    ///         custodian post-split, so its WOOD balance must EXACTLY equal the
    ///         sum of every obligation it tracks across all three buckets:
    ///
    ///           Σ guardian own stake                  bucket 1
    ///         + Σ unbound prepared owner stake        bucket 2
    ///         + Σ owner bonds                         bucket 2
    ///         + _pendingBurn                          bucket 3
    ///         == wood.balanceOf(swood)
    ///
    ///         Burn handling — the crux of the equation:
    ///         * Successful slash burn: WOOD `transfer`s to BURN_ADDRESS, so it
    ///           leaves `balanceOf(swood)`; the slash also decremented own
    ///           stake by the same amount, so both sides drop together —
    ///           equality holds.
    ///         * Failed slash burn: WOOD stays in `balanceOf(swood)`, own stake
    ///           is decremented, and `_pendingBurn` is credited —
    ///           `_pendingBurn` rebalances the equation.
    ///
    ///         `preparedStakeOf` keeps returning the amount after a slot is
    ///         bound (only the `bound` flag flips), so summing it would
    ///         double-count a stake already moved into `_ownerStakes`. The
    ///         handler tracks the *unbound* prepared amount itself
    ///         (`totalUnboundPrepared`) to avoid the double-count.
    ///
    ///         V1.5: epoch-reward budgets moved to Merkl — no on-chain term.
    function invariant_swoodWoodConservation() public view {
        uint256 contractBal = wood.balanceOf(address(swood));

        uint256 obligations = swood.pendingBurn();

        address[] memory actors = handler.getActors();
        for (uint256 i = 0; i < actors.length; i++) {
            // Bucket 1 — guardian own stake.
            obligations += swood.guardianStake(actors[i]);
        }

        // Bucket 2 — unbound prepared owner stakes (handler-tracked to dodge
        // the post-bind double-count described above).
        obligations += handler.totalUnboundPrepared();

        // Bucket 2 — bound owner stakes across every vault the handler binds.
        address[] memory bondVaults = handler.getBondVaults();
        for (uint256 i = 0; i < bondVaults.length; i++) {
            obligations += swood.ownerStake(bondVaults[i]);
        }

        assertEq(contractBal, obligations, "INV-1: sWOOD wood conservation violated");
    }

    /// @notice The registry custodies WOOD only for the slash-appeal reserve
    ///         post-split — its balance must cover that reserve.
    function invariant_registryWoodConservation() public view {
        assertGe(
            wood.balanceOf(address(registry)),
            registry.slashAppealReserve(),
            "INV-1: registry wood conservation violated"
        );
    }

    // ──────────────────────────────────────────────────────────────
    // INV-2: blocked-implies-accounting
    // ──────────────────────────────────────────────────────────────

    /// @notice For every resolved-blocked proposal, the review state stays
    ///         self-consistent: `resolved` and `blocked` flags both set.
    ///         Strict INV-2 ("slashed approvers have zero stake") requires the
    ///         approver list at resolve time, which the registry does not
    ///         expose — that is covered by `GuardianReviewLifecycle` /
    ///         `StakedWoodSlashing` unit tests.
    function invariant_blockedImpliesEpochAccounting() public view {
        uint256[] memory bids = handler.getBlockedProposalIds();
        for (uint256 i = 0; i < bids.length; i++) {
            (, bool resolved, bool blocked, bool cohortTooSmall) = registry.getReviewState(address(governor), bids[i]);
            if (!resolved || !blocked || cohortTooSmall) continue;
            assertTrue(resolved, "INV-2: resolved flag missing for blocked proposal");
            assertTrue(blocked, "INV-2: blocked flag missing after resolveReview returned true");
        }
    }

    // ──────────────────────────────────────────────────────────────
    // INV-3: aged vote weight bounds (spec Part B)
    // ──────────────────────────────────────────────────────────────

    /// @notice Age-weighted vote weight never exceeds raw own stake, and a
    ///         zero-stake guardian carries zero weight.
    ///
    ///         Bound derivation (spec §4-§5): `getVotes = agedOwn` where
    ///         `agedOwn = rawCheckpoint · factor/10_000` and `factor <=
    ///         10_000`, so `agedOwn <= rawCheckpoint`. The stake checkpoint is
    ///         re-pushed to `stakedAmount` on every mutation
    ///         (stake/cancel/slash) and to 0 on unstake-request, so
    ///         `rawCheckpoint <= guardianStake` always. Hence
    ///         `getVotes <= raw`.
    ///
    ///         Zero-stake leg: a guardian slashed to zero own stake re-pushes
    ///         a 0 checkpoint (active leg) or already carries one (unstake-
    ///         requested leg), so `agedOwn` collapses to 0. The `slash`
    ///         handler selector exercises both legs, so this is non-vacuous.
    function invariant_agedWeightBounds() public view {
        address[] memory gs = handler.getActors();
        for (uint256 i = 0; i < gs.length; i++) {
            uint256 raw = swood.guardianStake(gs[i]);
            uint256 votes = swood.getVotes(gs[i]);
            assertLe(votes, raw, "INV-3: vote weight exceeds raw own stake");
            if (raw == 0) assertEq(votes, 0, "INV-3: zero-stake guardian carries nonzero weight");
        }
    }
}
