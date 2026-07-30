// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseStrategy} from "../../src/strategies/BaseStrategy.sol";
import {IStrategy} from "../../src/interfaces/IStrategy.sol";

/**
 * @title MockStrategy
 * @notice Minimal concrete `BaseStrategy` for tests that need *a* strategy
 *         rather than a *particular* one.
 * @dev Factory cloning, init front-running, and governance batch paths are
 *      properties of `BaseStrategy` and `StrategyFactory`, not of any single
 *      strategy. Those tests previously reached for `MoonwellSupplyStrategy`
 *      as an arbitrary concrete subclass, which quietly coupled them to a
 *      Base-chain integration that has since been removed.
 *
 *      The init payload is decoded as the same 5-tuple those tests already
 *      build — `(asset, market, amountIn, minOut, flag)` — purely so their
 *      existing `abi.encode(...)` lines keep working. Nothing is done with
 *      the values beyond storing them for assertions.
 */
contract MockStrategy is BaseStrategy {
    address public asset;
    address public market;
    uint256 public supplyAmount;
    uint256 public minOut;
    bool public flag;

    uint256 public executeCount;
    uint256 public settleCount;
    uint256 public updateCount;

    /// @inheritdoc IStrategy
    function name() external pure returns (string memory) {
        return "Mock";
    }

    function _initialize(bytes calldata data) internal override {
        (asset, market, supplyAmount, minOut, flag) = abi.decode(data, (address, address, uint256, uint256, bool));
    }

    function _execute() internal override {
        ++executeCount;
    }

    function _settle() internal override {
        ++settleCount;
    }

    function _updateParams(bytes calldata) internal override {
        ++updateCount;
    }
}
