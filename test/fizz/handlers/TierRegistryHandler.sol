// SPDX-License-Identifier: MIT
pragma solidity >=0.6.2 <0.9.0;

import "../Base.sol";
import {Properties} from "../Properties.sol";

/// @notice Handles the interaction with TierRegistry
///
/// @dev Certification is keyed by `(target, selector)`. A fuzzer handed raw
///      addresses would essentially never hit a certified key, so both are
///      drawn from small fixed domains: targets from the deployed protocol
///      contracts, selectors from a fixed set. That makes collisions frequent,
///      which is the point — the certify → demote → claim cycle and I-2's bond
///      accounting only come under pressure when many actions share one key.
abstract contract TierRegistryHandler is Properties {
    // ――――――――――――――――――――――――― Clamped ――――――――――――――――――――――――――

    /// @dev Four candidate targets, all real contracts with stable codehashes,
    ///      so `certify`'s codehash pin (I-32) can actually pass rather than
    ///      always tripping `CodehashChanged`.
    function _tierTarget(uint256 seed) internal view returns (address) {
        uint256 i = seed % 4;
        if (i == 0) return address(vault);
        if (i == 1) return address(queue);
        if (i == 2) return address(swood);
        return address(governor);
    }

    function _tierSelector(uint256 seed) internal pure returns (bytes4) {
        uint256 i = seed % 3;
        if (i == 0) return bytes4(0xaabbccdd);
        if (i == 1) return bytes4(0x11223344);
        return bytes4(0xdeadbeef);
    }

    function tierRegistry_certify_clamped(uint256 targetSeed, uint256 selectorSeed, uint256 cfgSeed) public {
        address target = _tierTarget(targetSeed);
        tierRegistry_certify(
            target,
            _tierSelector(selectorSeed),
            uint8(cfgSeed % 3),
            uint16(clampBetween(cfgSeed, 0, 10_000)),
            target.codehash
        );
    }

    function tierRegistry_claimSubmitterBond_clamped(uint256 targetSeed, uint256 selectorSeed) public {
        tierRegistry_claimSubmitterBond(_tierTarget(targetSeed), _tierSelector(selectorSeed));
    }

    /// @dev `poke` is the permissionless self-heal: it demotes a certification
    ///      whose target codehash no longer matches (I-32).
    function tierRegistry_poke_clamped(uint256 targetSeed, uint256 selectorSeed) public {
        tierRegistry_poke(_tierTarget(targetSeed), _tierSelector(selectorSeed));
    }

    function tierRegistry_secondary(uint8 selector, uint256 arg0, uint256 arg1, uint256 arg2) public {
        address target = _tierTarget(arg0);
        bytes4 sel = _tierSelector(arg1);

        selector = uint8(selector % 5);
        if (selector == 0) {
            _tierRegistry_demote(target, sel);
        } else if (selector == 1) {
            _tierRegistry_demoteByChallenge(target, sel);
        } else if (selector == 2) {
            _tierRegistry_setCounterpartyAllowed(target, arg2 % 2 == 0);
        } else if (selector == 3) {
            _tierRegistry_setBondReleaseDelay(clampBetween(arg2, 1 days, 60 days));
        } else {
            // I-2: a non-zero bond requires `wood` to be configured, and
            // `setWood` refuses while bonds are outstanding.
            _tierRegistry_setSubmitterBondWood(clampBetween(arg2, 0, 100_000e18));
        }
    }

    // ―――――――――――――――――――――――― Unclamped ―――――――――――――――――――――――――

    function tierRegistry_certify(
        address target,
        bytes4 selector,
        uint8 tier,
        uint16 extractableBoundBps,
        bytes32 expectedCodehash
    ) public asAdmin {
        tierRegistry.certify(target, selector, tier, extractableBoundBps, expectedCodehash);
    }

    function tierRegistry_claimSubmitterBond(address target, bytes4 selector) public asActor {
        tierRegistry.claimSubmitterBond(target, selector);
    }

    function tierRegistry_poke(address target, bytes4 selector) public asActor {
        tierRegistry.poke(target, selector);
    }

    // ── Secondary (owner-gated unless noted; dispatcher-only entry) ──

    function _tierRegistry_demote(address target, bytes4 selector) internal asAdmin {
        tierRegistry.demote(target, selector);
    }

    /// @dev Gated to `authorizedDemoter`, which is the challenge game.
    function _tierRegistry_demoteByChallenge(address target, bytes4 selector) internal {
        vm.prank(address(game));
        tierRegistry.demoteByChallenge(target, selector);
    }

    function _tierRegistry_setCounterpartyAllowed(address counterparty, bool allowed) internal asAdmin {
        tierRegistry.setCounterpartyAllowed(counterparty, allowed);
    }

    function _tierRegistry_setBondReleaseDelay(uint256 delay) internal asAdmin {
        tierRegistry.setBondReleaseDelay(delay);
    }

    function _tierRegistry_setSubmitterBondWood(uint256 amount) internal asAdmin {
        tierRegistry.setSubmitterBondWood(amount);
    }
}
