// SPDX-License-Identifier: MIT
pragma solidity >=0.6.2 <0.9.0;

import "../Base.sol";
import {Properties} from "../Properties.sol";

/// @notice Handles the interaction with StakedWood
///
/// @dev sWOOD is the sole WOOD custodian, so I-4 (`Σ stakedAmount ==
///      totalGuardianStake` over active guardians) and I-14 (a slashed
///      guardian can sit below `minGuardianStake` and stay active) both live
///      here. The slash entry points are role-gated — `slashGuardians` /
///      `slashOwnerBond` to the registry, `slashVerdict` to the authorized
///      slasher (the game) — and are pranked accordingly. Without them the
///      fuzzer could never drive stake DOWN except through a full
///      challenge→court lifecycle, leaving I-4's conditional decrement branch
///      essentially unexercised.
///
/// @dev A SLASH MUST HAVE A WAY BACK (SHE-215 review). Since the propose and
///      execute legs read `ownerBondLive`, `slashOwnerBond` is no longer just a
///      stake mutation — it closes the vault's whole proposal lane. The owner
///      slot is bound once, to `address(this)`, and the two owner-exit handlers
///      above run `asActor`, so a slash used to be a one-way door: the fuzzer
///      could enter the unbonded state but never leave it, and everything
///      downstream of `propose` went dark for the rest of the run.
///      `stakedWood_restoreOwnerBond` plus the owner-acting request / cancel /
///      re-bind selectors below make every owner-slot state reachable FROM
///      every other one.
abstract contract StakedWoodHandler is Properties {
    // ――――――――――――――――――――――――― Clamped ――――――――――――――――――――――――――

    function stakedWood_stakeAsGuardian_clamped(uint256 amount, uint256 agentId) public {
        uint256 bal = wood.balanceOf(actor);
        if (bal == 0) return;
        // Below `minGuardianStake` a fresh stake reverts; existing guardians
        // may top up by any amount. Spanning the floor keeps both live.
        amount = clampBetween(amount, 1, bal);
        stakedWood_stakeAsGuardian(amount, agentId % 1_000);
    }

    /// @dev Exactly-at-the-floor entry, the boundary `InsufficientStake` gates.
    function stakedWood_stakeAsGuardian_atFloor() public {
        uint256 min = swood.minGuardianStake();
        if (wood.balanceOf(actor) < min) return;
        stakedWood_stakeAsGuardian(min, 1);
    }

    function stakedWood_requestUnstakeGuardian_clamped() public {
        stakedWood_requestUnstakeGuardian();
    }

    function stakedWood_cancelUnstakeGuardian_clamped() public {
        stakedWood_cancelUnstakeGuardian();
    }

    function stakedWood_claimUnstakeGuardian_clamped() public {
        stakedWood_claimUnstakeGuardian();
    }

    function stakedWood_prepareOwnerStake_clamped(uint256 amount) public {
        uint256 bal = wood.balanceOf(actor);
        if (bal == 0) return;
        amount = clampBetween(amount, 1, bal);
        stakedWood_prepareOwnerStake(amount);
    }

    function stakedWood_cancelPreparedStake_clamped() public {
        stakedWood_cancelPreparedStake();
    }

    function stakedWood_requestUnstakeOwner_clamped() public {
        stakedWood_requestUnstakeOwner(address(vault));
    }

    function stakedWood_claimUnstakeOwner_clamped() public {
        stakedWood_claimUnstakeOwner(address(vault));
    }

    /// @notice Put the vault's owner-stake slot back into the LIVE state, by
    ///         whichever route the slot's current state calls for.
    ///
    /// @dev THE COUNTERWEIGHT TO `_stakedWood_slashOwnerBond` (SHE-215 review).
    ///      `SyndicateGovernor.propose` and `executeProposal` now both refuse a
    ///      vault whose `ownerBondLive` is false, and the harness binds the slot
    ///      exactly once, in `Base.setup()`, to `address(this)`. Before this
    ///      handler existed the only owner-slot mutation the fuzzer could
    ///      actually land was the slash: `stakedWood_requestUnstakeOwner` /
    ///      `claimUnstakeOwner` run `asActor`, and no actor is the bound owner,
    ///      so they revert unconditionally. One draw of the slash selector
    ///      therefore deleted the record for good and silently removed the
    ///      ENTIRE propose → vote → execute → settle lifecycle from the explored
    ///      surface for the remainder of the run — with no property violation to
    ///      show for it, just coverage that stops moving.
    ///
    ///      Deliberately NOT folded into `_stakedWood_slashOwnerBond` as an
    ///      auto-restore: the post-slash unbonded state is itself worth
    ///      exploring (it is what the new gate is FOR), so the two stay separate
    ///      draws. This one sits at top level rather than inside
    ///      `stakedWood_secondary` so restoring is drawn far more often than the
    ///      1-in-16 that breaks it, which keeps the lifecycle the dominant state
    ///      instead of a coin flip.
    ///
    ///      Reachability is asserted end to end by
    ///      `FoundryTester.test_fizz_proposalLaneRecoversAfterSlashOwnerBond`,
    ///      which drives slash → restore → propose through these same handlers.
    function stakedWood_restoreOwnerBond() public {
        if (swood.ownerBondLive(address(vault))) return;

        // Case 1: funded but exiting (`unstakeRequestedAt != 0`). The record is
        // intact, so the cheap reversal is the one SHE-215 added.
        if (swood.ownerStake(address(vault)) != 0) {
            _stakedWood_cancelUnstakeOwnerAsOwner(address(vault));
            return;
        }

        // Case 2: the record is gone (slashed, or claimed out). Only a fresh
        // escrow can refill it, through the same factory-gated route
        // `Base.setup()` uses.
        _stakedWood_rebindOwnerStake();
    }

    function stakedWood_secondary(uint8 selector, uint256 arg0, uint256 guardianSeed) public {
        selector = uint8(selector % 16);
        if (selector == 0) {
            _stakedWood_approveOwnerStakeBinding(address(vault));
        } else if (selector == 1) {
            _stakedWood_revokeOwnerStakeBinding();
        } else if (selector == 2) {
            _stakedWood_flushBurn();
        } else if (selector == 3) {
            _stakedWood_setAgeFloorBps(clampBetween(arg0, 1, 10_000));
        } else if (selector == 4) {
            // X-4: must stay >= registry.reviewPeriod.
            _stakedWood_setCooldownPeriod(clampBetween(arg0, 1 days, 30 days));
        } else if (selector == 5) {
            _stakedWood_setMaturationPeriod(clampBetween(arg0, 7 days, 90 days));
        } else if (selector == 6) {
            // I-8: maxSlashBps must stay >= minSlashBps.
            _stakedWood_setMaxSlashBps(clampBetween(arg0, swood.minSlashBps(), 10_000));
        } else if (selector == 7) {
            _stakedWood_setMinGuardianStake(clampBetween(arg0, 1e18, 100_000e18));
        } else if (selector == 8) {
            _stakedWood_setMinOwnerStake(clampBetween(arg0, 1_000e18, 100_000e18));
        } else if (selector == 9) {
            _stakedWood_setMinSlashBps(clampBetween(arg0, 0, swood.maxSlashBps()));
        } else if (selector == 10) {
            _stakedWood_slashGuardians(guardianSeed, clampBetween(arg0, 1, 10_000));
        } else if (selector == 11) {
            _stakedWood_slashVerdict(guardianSeed, clampBetween(arg0, 1, 10_000));
        } else if (selector == 12) {
            // As the BOUND OWNER, not `asActor`. The `_clamped` pair above act
            // as an actor and so can never touch this vault's slot; without an
            // owner-acting request the "exiting" half of `ownerBondLive` — the
            // clause SHE-215 added — was unreachable in the harness, and the
            // only observable transition was the irreversible slash.
            _stakedWood_requestUnstakeOwnerAsOwner(address(vault));
        } else if (selector == 13) {
            _stakedWood_cancelUnstakeOwnerAsOwner(address(vault));
        } else if (selector == 14) {
            _stakedWood_rebindOwnerStake();
        } else {
            _stakedWood_slashOwnerBond(address(vault));
        }
    }

    // ―――――――――――――――――――――――― Unclamped ―――――――――――――――――――――――――

    function stakedWood_stakeAsGuardian(uint256 amount, uint256 agentId) public asActor {
        swood.stakeAsGuardian(amount, agentId);
    }

    function stakedWood_requestUnstakeGuardian() public asActor {
        swood.requestUnstakeGuardian();
    }

    function stakedWood_cancelUnstakeGuardian() public asActor {
        swood.cancelUnstakeGuardian();
    }

    function stakedWood_claimUnstakeGuardian() public asActor {
        swood.claimUnstakeGuardian();
    }

    function stakedWood_prepareOwnerStake(uint256 amount) public asActor {
        swood.prepareOwnerStake(amount);
    }

    function stakedWood_cancelPreparedStake() public asActor {
        swood.cancelPreparedStake();
    }

    function stakedWood_requestUnstakeOwner(address vault_) public asActor {
        swood.requestUnstakeOwner(vault_);
    }

    function stakedWood_claimUnstakeOwner(address vault_) public asActor {
        swood.claimUnstakeOwner(vault_);
    }

    // ── Secondary: self-service ──

    function _stakedWood_approveOwnerStakeBinding(address vault_) internal asActor {
        swood.approveOwnerStakeBinding(vault_);
    }

    function _stakedWood_revokeOwnerStakeBinding() internal asActor {
        swood.revokeOwnerStakeBinding();
    }

    /// @dev Permissionless retry for a burn transfer that previously failed.
    function _stakedWood_flushBurn() internal asActor {
        swood.flushBurn();
    }

    // ── Secondary: slash paths (role-gated) ──

    /// @dev Registry-gated. `reviewKey` is synthesised from a small domain
    ///      rather than fuzzed: the one-slash-per-key guards (I-27, I-34) only
    ///      bite when keys repeat, so a small key space is what exercises them.
    function _stakedWood_slashGuardians(uint256 guardianSeed, uint256 slashBps) internal {
        address[] memory approvers = new address[](1);
        approvers[0] = toGuardian(guardianSeed);
        bytes32 reviewKey = keccak256(abi.encode("fizz-review", guardianSeed % 4));
        // Per-approver rates (declared coverage locks): one approver, one rate.
        uint256[] memory rates = new uint256[](1);
        rates[0] = slashBps;
        vm.prank(address(registry));
        swood.slashGuardians(reviewKey, block.timestamp - 1, approvers, rates);
    }

    /// @dev Authorized-slasher-gated (the challenge game).
    function _stakedWood_slashVerdict(uint256 guardianSeed, uint256 slashBps) internal {
        address[] memory approvers = new address[](1);
        approvers[0] = toGuardian(guardianSeed);
        uint256[] memory bpsPer = new uint256[](1);
        bpsPer[0] = slashBps;
        bytes32 caseKey = keccak256(abi.encode("fizz-case", guardianSeed % 4));
        vm.prank(address(game));
        swood.slashVerdict(caseKey, block.timestamp - 1, approvers, bpsPer);
    }

    /// @dev Registry-gated.
    ///
    /// @dev Deletes `_ownerStakes[vault]` outright, which drives
    ///      `ownerBondLive` false and shuts the propose/execute lane (SHE-215).
    ///      `stakedWood_restoreOwnerBond` is the way back; see its doc for why
    ///      the restore is a separate draw rather than part of this one.
    function _stakedWood_slashOwnerBond(address vault_) internal {
        vm.prank(address(registry));
        swood.slashOwnerBond(vault_);
    }

    // ── Secondary: owner-slot lifecycle, acted as the BOUND OWNER ──
    //
    // `Base.setup()` binds the slot to `address(this)`, so every call below
    // runs unpranked: this contract IS the vault owner, and `requestUnstakeOwner`
    // / `cancelUnstakeOwner` / `prepareOwnerStake` all key on `msg.sender`.
    // Pranking as `admin` would be equivalent today (`admin == address(this)`)
    // but would silently stop working if the harness ever rebinds elsewhere.

    /// @dev Reverts while the vault has an open or active proposal, which is
    ///      the gate `requestUnstakeOwner` documents — reverting simply drops
    ///      the call from the sequence, so this is safe to draw at any time.
    function _stakedWood_requestUnstakeOwnerAsOwner(address vault_) internal {
        swood.requestUnstakeOwner(vault_);
    }

    function _stakedWood_cancelUnstakeOwnerAsOwner(address vault_) internal {
        swood.cancelUnstakeOwner(vault_);
    }

    /// @dev Re-fund an EMPTIED owner-stake slot through the same factory-gated
    ///      route `Base.setup()` uses, so the fuzzer can climb back out of the
    ///      post-slash (or post-claim) state instead of being stuck in it.
    ///
    ///      `bindOwnerStake` requires `_ownerStakes[vault].stakedAmount == 0`,
    ///      which is exactly the state this handles, and an unbound prepared
    ///      escrow at or above the CURRENT `minOwnerStake` — current, because
    ///      `_stakedWood_setMinOwnerStake` lets the fuzzer move the floor. The
    ///      `canCreateVault` guard makes the prepare idempotent: it is skipped
    ///      when a usable escrow already sits there, which is what keeps a
    ///      previously-failed bind from bricking every later retry on
    ///      `PreparedStakeAlreadyExists`.
    function _stakedWood_rebindOwnerStake() internal {
        if (swood.ownerStake(address(vault)) != 0) return;

        if (!swood.canCreateVault(address(this))) {
            uint256 min = swood.minOwnerStake();
            wood.deal(address(this), min);
            wood.approve(address(swood), min);
            swood.prepareOwnerStake(min);
        }
        _asFactory(address(swood), abi.encodeCall(StakedWood.bindOwnerStake, (address(this), address(vault))));
    }

    // ── Secondary: owner-gated params ──

    function _stakedWood_setAgeFloorBps(uint256 v) internal asAdmin {
        swood.setAgeFloorBps(v);
    }

    function _stakedWood_setCooldownPeriod(uint256 v) internal asAdmin {
        swood.setCooldownPeriod(v);
    }

    function _stakedWood_setMaturationPeriod(uint256 v) internal asAdmin {
        swood.setMaturationPeriod(v);
    }

    function _stakedWood_setMaxSlashBps(uint256 v) internal asAdmin {
        swood.setMaxSlashBps(v);
    }

    function _stakedWood_setMinGuardianStake(uint256 v) internal asAdmin {
        swood.setMinGuardianStake(v);
    }

    function _stakedWood_setMinOwnerStake(uint256 v) internal asAdmin {
        swood.setMinOwnerStake(v);
    }

    function _stakedWood_setMinSlashBps(uint256 v) internal asAdmin {
        swood.setMinSlashBps(v);
    }
}
