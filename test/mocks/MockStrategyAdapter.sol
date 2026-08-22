// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IStrategy} from "../../src/interfaces/IStrategy.sol";

/// @notice Minimal IStrategy stub for vault/governor tests that only need a
///         strategy *address* on a proposal (e.g. `activeStrategyAdapter`
///         resolution, redemption-lock semantics). The vault never reads value
///         from a strategy, so this stub implements only the core lifecycle.
contract MockStrategyAdapter is IStrategy {
    function initialize(address, address, bytes calldata) external pure {}

    function execute() external pure {}

    function settle() external pure {}

    function updateParams(bytes calldata) external pure {}

    function vault() external pure returns (address) {
        return address(0);
    }

    function proposer() external pure returns (address) {
        return address(0);
    }

    function executed() external pure returns (bool) {
        return true;
    }

    function name() external pure returns (string memory) {
        return "MockStrategyAdapter";
    }
}
