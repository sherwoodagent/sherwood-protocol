// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IStrategy} from "../../src/interfaces/IStrategy.sol";
import {Position} from "../../src/interfaces/IPriceRouter.sol";

/// @notice Minimal IStrategy stub for vault/governor tests that only need a
///         strategy *address* on a proposal (e.g. `activeStrategyAdapter`
///         resolution, redemption-lock semantics). The V2 live-NAV redesign
///         removed the value/hook surface — the vault never reads value from a
///         strategy — so this stub implements only the core lifecycle.
contract MockStrategyAdapter is IStrategy {
    /// @notice Test-settable self-fee flag; snapshotted by the governor at propose.
    bool public selfFee;
    /// @notice When true, `selfManagesFees()` reverts — models a broken/non-view
    ///         implementation so the propose-time snapshot (not settle) fail-fasts.
    bool public revertOnSelfManagesFees;

    function setSelfFee(bool v) external {
        selfFee = v;
    }

    function setRevertOnSelfManagesFees(bool v) external {
        revertOnSelfManagesFees = v;
    }

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

    function positions() external pure returns (Position[] memory) {
        return new Position[](0);
    }

    /// @notice H2/M4 capability flag mock — default `false` (governor distributes
    ///         settle-fees). Toggle with `setSelfFee`; `setRevertOnSelfManagesFees`
    ///         models a broken implementation the propose-time snapshot fail-fasts on.
    function selfManagesFees() external view returns (bool) {
        require(!revertOnSelfManagesFees, "selfManagesFees: revert");
        return selfFee;
    }
}
