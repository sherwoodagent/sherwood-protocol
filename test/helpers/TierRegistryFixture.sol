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
///         The one visible difference is pricing: the registry-less branch in
///         `_resolveTierAndCoverage` short-circuits to `(2, maxCapital)`, while
///         resolving through here prices `sum(cap_i)` at `boundBps == 10_000`.
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

    /// @dev SHE-209: no class concept in this stand-in — every address is a
    ///      non-member, so the vault's class-binding check never fires.
    function classOf(address) external pure returns (bytes32) {
        return bytes32(0);
    }
}

/// @notice Deploy a `PermissiveTierRegistry` to satisfy the governor's mandatory
///         registry argument. See the contract's docs for when NOT to use it.
function deployTierRegistry(address) returns (ITierRegistry) {
    return new PermissiveTierRegistry();
}
