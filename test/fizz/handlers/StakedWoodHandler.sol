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

    function stakedWood_secondary(uint8 selector, uint256 arg0, uint256 guardianSeed) public {
        selector = uint8(selector % 13);
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
    function _stakedWood_slashOwnerBond(address vault_) internal {
        vm.prank(address(registry));
        swood.slashOwnerBond(vault_);
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
