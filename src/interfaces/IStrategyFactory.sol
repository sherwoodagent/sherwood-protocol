// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IStrategyFactory {
    /// @notice Template `clone` was deployed from; `address(0)` when this
    ///         factory did not deploy it.
    function cloneTemplate(address clone) external view returns (address);
}
