// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ISwapAdapter} from "../../src/interfaces/ISwapAdapter.sol";
import {IStrategy} from "../../src/interfaces/IStrategy.sol";
import {IPriceRouter} from "../../src/interfaces/IPriceRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title ObservingSwapAdapter
 * @notice MockSwapAdapter variant for Lane A tests: rate-table swaps plus a
 *         one-shot mid-swap probe. When armed, the FIRST swap records the
 *         observed strategy's `positions().length` and `availableLiquidity()`
 *         (and optionally the router's `valueStrategy` verdict) — capturing
 *         what a reentrant Lane A read would see while a rebalance or unwind
 *         is in flight. Test-only.
 *
 *   Rates are per directional pair, 1e18-scaled, and the adapter must be
 *   pre-funded with output tokens (same conventions as MockSwapAdapter, which
 *   cannot be extended because its functions are not virtual).
 */
contract ObservingSwapAdapter is ISwapAdapter {
    using SafeERC20 for IERC20;

    uint256 public constant RATE_PRECISION = 1e18;

    mapping(bytes32 => uint256) public rates;

    address public observedStrategy;
    address public observedRouter;
    bool public armed;

    uint256 public observedPositions = type(uint256).max;
    uint256 public observedLiquidity = type(uint256).max;
    uint256 public observedRouterValue = type(uint256).max;
    bool public observedRouterOk = true;

    error RateNotSet();
    error SlippageExceeded();

    function setRate(address tokenIn, address tokenOut, uint256 rate) external {
        rates[_pairKey(tokenIn, tokenOut)] = rate;
    }

    /// @notice Arm the one-shot probe. `router_` may be zero to skip the
    ///         router observation.
    function arm(address strategy_, address router_) external {
        observedStrategy = strategy_;
        observedRouter = router_;
        armed = true;
        observedPositions = type(uint256).max;
        observedLiquidity = type(uint256).max;
        observedRouterValue = type(uint256).max;
        observedRouterOk = true;
    }

    /// @inheritdoc ISwapAdapter
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOutMin, bytes calldata)
        external
        override
        returns (uint256 amountOut)
    {
        if (armed) {
            armed = false;
            observedPositions = IStrategy(observedStrategy).positions().length;
            observedLiquidity = IStrategy(observedStrategy).availableLiquidity();
            if (observedRouter != address(0)) {
                (observedRouterValue, observedRouterOk) = IPriceRouter(observedRouter).valueStrategy(observedStrategy);
            }
        }

        uint256 rate = rates[_pairKey(tokenIn, tokenOut)];
        if (rate == 0) revert RateNotSet();
        amountOut = (amountIn * rate) / RATE_PRECISION;
        if (amountOut < amountOutMin) revert SlippageExceeded();

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
    }

    /// @inheritdoc ISwapAdapter
    function quote(address tokenIn, address tokenOut, uint256 amountIn, bytes calldata)
        external
        view
        override
        returns (uint256 amountOut)
    {
        uint256 rate = rates[_pairKey(tokenIn, tokenOut)];
        if (rate == 0) revert RateNotSet();
        amountOut = (amountIn * rate) / RATE_PRECISION;
    }

    function _pairKey(address tokenIn, address tokenOut) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(tokenIn, tokenOut));
    }
}
