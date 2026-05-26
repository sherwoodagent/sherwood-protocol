// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice WOOD-like ERC20 whose `transfer` to a specific recipient can be
///         toggled into a broken mode — used to exercise both the `!ok`
///         (returns `false`) and `catch` (reverts) branches of the fail-soft
///         burn path in `StakedWood._burnWood` (Task 5.2).
contract MockBrokenWood is ERC20 {
    /// @dev Broken-transfer behaviour for a blocked recipient.
    enum BrokenMode {
        None, // transfer works normally
        ReturnFalse, // transfer returns false (no revert)
        Revert // transfer reverts
    }

    uint8 private _decimals;

    /// @dev Per-recipient broken mode. `transfer(to, *)` consults this.
    mapping(address => BrokenMode) public brokenMode;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice Toggle the broken-transfer behaviour for `to`.
    /// @dev `BrokenMode.None` restores normal transfers (used by `flushBurn`
    ///      recovery tests).
    function setBrokenMode(address to, BrokenMode mode) external {
        brokenMode[to] = mode;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        BrokenMode mode = brokenMode[to];
        if (mode == BrokenMode.Revert) revert("transfer reverts");
        if (mode == BrokenMode.ReturnFalse) return false;
        return super.transfer(to, amount);
    }
}
