// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @notice `ExposureLedger.coverageUsd` stand-in: an asset is unpriced (reverts) until `setPrice`.
contract MockAssetLedger {
    error FeedNotConfigured();

    mapping(address => uint256) public priceX8;

    function setPrice(address asset, uint256 usdX8) external {
        priceX8[asset] = usdX8;
    }

    function coverageUsd(address asset, uint256 amount) external view returns (uint256) {
        uint256 px = priceX8[asset];
        if (px == 0) revert FeedNotConfigured();
        return (amount * px * 1e18) / (10 ** IERC20Metadata(asset).decimals()) / 1e8;
    }
}
