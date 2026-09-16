// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20Mock} from "./ERC20Mock.sol";

/// @notice Paxos-shaped stablecoin, the launch asset's surface: `approve`, `increaseApproval`,
///         `decreaseApproval`, `transfer`, `transferFrom`; NO `increaseAllowance`.
/// @dev    Probed by eth_call on Robinhood 4663 USDG `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168`
///         (2026-09-10): `increaseApproval` returns true, `increaseAllowance` reverts with the
///         same data as a nonexistent selector.
contract GlobalDollarMock is ERC20Mock {
    constructor() ERC20Mock("Global Dollar", "USDG", 6) {}

    function increaseApproval(address spender, uint256 added) external returns (bool) {
        _approve(msg.sender, spender, allowance(msg.sender, spender) + added);
        return true;
    }

    function decreaseApproval(address spender, uint256 subtracted) external returns (bool) {
        uint256 current = allowance(msg.sender, spender);
        _approve(msg.sender, spender, subtracted >= current ? 0 : current - subtracted);
        return true;
    }
}
