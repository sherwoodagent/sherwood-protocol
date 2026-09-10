// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ITierRegistry} from "../../src/interfaces/ITierRegistry.sol";

/// @notice A TierRegistry that grants everything, for harnesses that exercise
///         GOVERNANCE mechanics and never meant to test the registry.
/// @dev    `SyndicateGovernor.initialize` now takes the registry as a
///         MANDATORY, must-hold-code argument (pashov finding #1), so a harness
///         that used to pass nothing has to pass something. Those harnesses
///         previously ran with `_tierRegistry == 0`, under which
///         `SyndicateVault._guardBatchCalls` returned early and applied NO
///         allowlist — so granting everything is what preserves their behavior.
///
///         DO NOT reach for this when the assertion is about the registry —
///         allowlisting, demotion, callee gating, tier resolution. Those
///         fixtures deploy a real `TierRegistry` and seed it; a permissive
///         stand-in would make them pass vacuously.
contract PermissiveTierRegistry is ITierRegistry {
    /// @dev Tier 2 / full notional — the conservative end of the tier scale, so
    ///      a harness never gets a cheaper coverage bill than the real registry
    ///      would hand it.
    function tierOf(address, bytes4) external pure returns (uint8, uint16) {
        return (2, 10_000);
    }

    function isAdapterAllowed(address) external pure returns (bool) {
        return true;
    }

    function isCallableTarget(address) external pure returns (bool) {
        return true;
    }

    function isCounterpartyAllowed(address) external pure returns (bool) {
        return true;
    }

    /// @dev Permissive mirror of factory provenance: anything that answers
    ///      `vault()` is treated as a strategy clone (a class member), so the
    ///      vault's bound-clone predicate and class-binding check see the same
    ///      shape the real registry reports for a minted clone. Everything else
    ///      (routers, tokens, EOAs) stays a non-member.
    function classOf(address target) external view returns (bytes32) {
        (bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSignature("vault()"));
        return ok && ret.length == 32 ? keccak256("permissive-strategy-class") : bytes32(0);
    }
}

/// @notice Deploy a `PermissiveTierRegistry` to satisfy the governor's mandatory
///         registry argument. See the contract's docs for when NOT to use it.
function deployTierRegistry(address) returns (ITierRegistry) {
    return new PermissiveTierRegistry();
}
