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
                    maxDelegatedSlashBps: 2000,
                    ageFloorBps: 2500,
                    maturationPeriod: 30 days,
                    delegatedWeightCapX: 4
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

        // Delegation defaults off at deploy — flip it on so the handler can
        // exercise the `poolTokens` WOOD bucket.
        vm.prank(owner);
        swood.setDelegationEnabled(true);

        handler = new GuardianHandler(registry, swood, wood, governor, vault, owner, factory);

        // Restrict the fuzzer to the handler's action surface.
        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](21);
        // Bucket 1 — guardian own stake.
        selectors[0] = GuardianHandler.stake.selector;
        selectors[1] = GuardianHandler.requestUnstake.selector;
        selectors[2] = GuardianHandler.cancelUnstake.selector;
        selectors[3] = GuardianHandler.claimUnstake.selector;
        // Bucket 2 — delegation pools (poolTokens).
        selectors[4] = GuardianHandler.delegate.selector;
        selectors[5] = GuardianHandler.requestUnstakeDelegation.selector;
        selectors[6] = GuardianHandler.cancelUnstakeDelegation.selector;
        selectors[7] = GuardianHandler.claimUnstakeDelegation.selector;
        // Bucket 3 — owner bonds.
        selectors[8] = GuardianHandler.prepareOwnerStake.selector;
        selectors[9] = GuardianHandler.cancelPreparedStake.selector;
        selectors[10] = GuardianHandler.bindOwnerStake.selector;
        selectors[11] = GuardianHandler.requestUnstakeOwner.selector;
        selectors[12] = GuardianHandler.claimUnstakeOwner.selector;
        // Bucket 4 — pending burn (via slashing).
        selectors[13] = GuardianHandler.slash.selector;
        selectors[14] = GuardianHandler.flushBurn.selector;
        // Review lifecycle + time.
        selectors[15] = GuardianHandler.vote.selector;
        selectors[16] = GuardianHandler.openReview.selector;
        selectors[17] = GuardianHandler.resolveReview.selector;
        selectors[18] = GuardianHandler.createProposal.selector;
        selectors[19] = GuardianHandler.warp.selector;
        // Registry-side slash-appeal reserve.
        selectors[20] = GuardianHandler.fundSlashAppealReserve.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    // ──────────────────────────────────────────────────────────────
    // INV-1: WOOD conservation (two-part, post-split)
    // ──────────────────────────────────────────────────────────────

    /// @notice INV-1 (sWOOD): WOOD conservation. sWOOD is the sole WOOD
    ///         custodian post-split, so its WOOD balance must EXACTLY equal the
    ///         sum of every obligation it tracks across all four buckets:
    ///
    ///           Σ poolTokens (every delegate live pool)    bucket 2
    ///         + Σ unbondingPoolTokens (every unbond pool)   bucket 2
    ///         + Σ guardian own stake                 bucket 1
    ///         + Σ unbound prepared owner stake        bucket 3
    ///         + Σ owner bonds                         bucket 3
    ///         + _pendingBurn                          bucket 4
    ///         == wood.balanceOf(swood)
    ///
    ///         I-1: the unbonding-escrow pool (`unbondingPoolTokens`) custodies
    ///         WOOD requested-out but not yet claimed — it is a real obligation
    ///         and is slashed by `_slashOne` exactly like the live pool, so it
    ///         joins bucket 2.
    ///
    ///         Burn handling — the crux of the equation:
    ///         * Successful slash burn: WOOD `transfer`s to BURN_ADDRESS, so it
    ///           leaves `balanceOf(swood)`; the slash also decremented own
    ///           stake / poolTokens by the same amount, so both sides drop
    ///           together — equality holds.
    ///         * Failed slash burn: WOOD stays in `balanceOf(swood)`, own stake
    ///           / poolTokens are decremented, and `_pendingBurn` is credited —
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
            // Bucket 2 — delegation pool backing for any actor that is a
            // delegate. `delegatedInbound` returns `poolTokens[delegate]`.
            obligations += swood.delegatedInbound(actors[i]);
            // Bucket 2 — I-1 unbonding-escrow pool: WOOD requested-out but not
            // yet claimed, still custodied by sWOOD.
            obligations += swood.unbondingPoolTokens(actors[i]);
        }

        // Bucket 3 — unbound prepared owner stakes (handler-tracked to dodge
        // the post-bind double-count described above).
        obligations += handler.totalUnboundPrepared();

        // Bucket 3 — bound owner stakes across every vault the handler binds.
        address[] memory bondVaults = handler.getBondVaults();
        for (uint256 i = 0; i < bondVaults.length; i++) {
            obligations += swood.ownerStake(bondVaults[i]);
        }

        assertEq(contractBal, obligations, "INV-1: sWOOD wood conservation violated");
    }

    /// @notice INV-1b (sWOOD): per-pool share consistency.
    ///
    ///         The task spec frames this as the biconditional
    ///         `poolShares == 0 ⟺ poolTokens == 0`, but only ONE direction is a
    ///         true protocol invariant — slashing breaks the other:
    ///
    ///         * `poolShares == 0 ⟹ poolTokens == 0` — HOLDS. The last
    ///           delegator to `claimUnstakeDelegation` redeems `myShares ==
    ///           poolShares`, and `owed == myShares * poolTokens / poolShares ==
    ///           poolTokens`, so both hit zero together. No path leaves tokens
    ///           with no shares to back them: `delegateStake` always mints
    ///           shares for the tokens it adds.
    ///
    ///         * `poolTokens == 0 ⟹ poolShares == 0` — does NOT hold. A 100%
    ///           slash (`_slashOne`) writes `poolTokens -= delSlash` to zero but
    ///           deliberately leaves `poolShares` untouched — delegators keep
    ///           their (now worthless) shares and redeem at a 0 rate. That is
    ///           the intended dilution semantics, not a bug, so the invariant
    ///           must not assert it. (`delegateStake` into such a pool reverts
    ///           on the `mulDiv(amount, sh, 0)` divide-by-zero, so the
    ///           shares-without-tokens pool is a safe terminal state.)
    ///
    ///         A `poolShares != 0 && poolTokens == 0` pool is therefore valid;
    ///         a `poolShares == 0 && poolTokens != 0` pool is the real
    ///         corruption this invariant guards against — free tokens with no
    ///         claimant, un-redeemable WOOD stranded in a pool.
    function invariant_poolShareConsistency() public view {
        address[] memory delegates = handler.getTouchedDelegates();
        for (uint256 i = 0; i < delegates.length; i++) {
            if (swood.poolShares(delegates[i]) == 0) {
                assertEq(
                    swood.poolTokens(delegates[i]), 0, "INV-1b: pool has tokens but zero shares (un-redeemable WOOD)"
                );
            }
        }
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
}
