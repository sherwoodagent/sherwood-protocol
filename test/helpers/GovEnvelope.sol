// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Vm, VmSafe} from "forge-std/Vm.sol";

/// @notice Shared test helper for the Task-3 risk envelope. Call sites that
///         are not exercising envelope semantics pass `GovEnvelope.permissive(vault)`
///         so the envelope never constrains pre-existing test behavior.
/// @dev    Finding 3 capped `maxCapital` at `maxCapitalBps` (default 100%) of
///         the vault's `totalAssets()` at propose time, so the widest LEGAL
///         envelope is exactly `totalAssets()` — `type(uint256).max` now
///         reverts `MaxCapitalExceedsCeiling`. A zero-TVL vault computes a zero
///         ceiling, and any nonzero maxCapital is rejected: deposit before
///         proposing (an empty vault has nothing to deploy).
library GovEnvelope {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function permissive(address vault) internal returns (ISyndicateGovernor.RiskEnvelope memory env) {
        // Reading totalAssets() is an external staticcall and would CONSUME a
        // single-use vm.prank armed for the propose() this envelope feeds —
        // snapshot the prank state and re-arm it so the ubiquitous
        // `vm.prank(agent); governor.propose(..., GovEnvelope.permissive(vault), ...)`
        // pattern keeps working. startPrank (recurrent) is not consumed; no-op.
        (VmSafe.CallerMode mode, address sender, address origin) = vm.readCallers();
        env = ISyndicateGovernor.RiskEnvelope({maxCapital: IERC4626(vault).totalAssets(), maxDrawdownBps: 10_000});
        if (mode == VmSafe.CallerMode.Prank) vm.prank(sender, origin);
    }
}
