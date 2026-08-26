// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Vm.sol";

/// @dev `SyndicateGovernor._tierRegistry`. Frozen and independently pinned by
///      `test/governor/GovernorLayoutPins.t.sol::test_layout_appendedFieldsPinned`,
///      so a layout shift fails there rather than silently zeroing some other
///      field here.
uint256 constant GOVERNOR_TIER_REGISTRY_SLOT = 58;

/// @notice Put a governor back into the registry-less state that predates the
///         mandatory `initialize` argument (pashov finding #1).
/// @dev    Written with `vm.store` because there is no longer any API that
///         reaches this state: `initialize` requires a code-bearing registry and
///         `setTierRegistry` refuses zero. The state is still REACHABLE ON
///         CHAIN — every governor deployed before the fix is in it until
///         `SyndicateFactory.pushWiring` rescues it — so the branches that
///         handle it (`_resolveTierAndCoverage`'s tier-2 flat default,
///         `SyndicateVault._guardBatchCalls`'s `TierRegistryUnresolved`) still
///         need coverage. This is what gives them a subject.
///
///         Kept OUT of `TierRegistryFixture.sol` on purpose: that file is
///         imported by ~45 suites, and dragging `forge-std/Vm.sol` into all of
///         them is bytecode every one of them pays for.
function unwireTierRegistry(address governor) {
    Vm(address(uint160(uint256(keccak256("hevm cheat code")))))
        .store(governor, bytes32(GOVERNOR_TIER_REGISTRY_SLOT), bytes32(0));
}
