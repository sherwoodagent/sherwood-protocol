// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";

/// @notice Shared test helper for the Task-3 risk envelope. Call sites that
///         are not exercising envelope semantics pass `GovEnvelope.permissive()`
///         so the envelope never constrains pre-existing test behavior.
library GovEnvelope {
    function permissive() internal pure returns (ISyndicateGovernor.RiskEnvelope memory) {
        return ISyndicateGovernor.RiskEnvelope({maxCapital: type(uint256).max, maxDrawdownBps: 10_000});
    }
}
