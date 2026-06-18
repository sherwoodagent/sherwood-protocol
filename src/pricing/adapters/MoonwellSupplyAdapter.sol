// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPriceAdapter, Position} from "../../interfaces/IPriceRouter.sol";
import {ICToken} from "../../interfaces/ICToken.sol";

/// @title  MoonwellSupplyAdapter
/// @notice Prices a Moonwell (Compound v2 fork) supply position vault-side. The
///         value is read FROM THE VENUE — `mToken.balanceOf(holder)` scaled by
///         `exchangeRateStored` — never from the strategy. The venue is
///         validated against the canonical Moonwell Comptroller (`markets().isListed`)
///         so a malicious strategy cannot point at a fake mToken that
///         self-reports an inflated balance/rate.
/// @dev    `value()` is `view`, so it uses `exchangeRateStored` (last-accrued)
///         rather than `exchangeRateCurrent` (which accrues, non-view). The
///         bounded accrual lag is absorbed by the router's realizability
///         haircut. Stateless + immutable comptroller — no upgrade surface.
contract MoonwellSupplyAdapter is IPriceAdapter {
    bytes32 public constant KIND = keccak256("MOONWELL_SUPPLY");

    /// @notice Canonical Moonwell Comptroller — the trusted market registry.
    address public immutable comptroller;

    error ZeroAddress();

    constructor(address comptroller_) {
        if (comptroller_ == address(0)) revert ZeroAddress();
        comptroller = comptroller_;
    }

    /// @inheritdoc IPriceAdapter
    /// @dev Reads the mToken balance + stored exchange rate FROM THE VENUE. The
    ///      venue is first validated as a canonical, listed Moonwell market, so
    ///      a strategy cannot point at a self-reporting fake. A zero balance is
    ///      validly priceable at 0; an unknown/foreign or unreadable venue is
    ///      `(0, false)` (fail-closed).
    function value(Position calldata p, address holder) external view returns (uint256, bool) {
        if (!_isListed(p.venue)) return (0, false);
        uint256 cBal = ICToken(p.venue).balanceOf(holder);
        if (cBal == 0) return (0, true);
        uint256 rate = ICToken(p.venue).exchangeRateStored();
        return ((cBal * rate) / 1e18, true);
    }

    /// @dev Authoritative "is this a real Moonwell market?" check. Asks the
    ///      trusted Comptroller's `markets(address)` getter and reads the first
    ///      returned word (`isListed`). Low-level staticcall + first-word decode
    ///      is robust to the getter's trailing fields (collateralFactor, isComped)
    ///      differing across Comptroller versions, and fail-closed if the call
    ///      reverts or returns short.
    function _isListed(address mToken) internal view returns (bool) {
        (bool ok, bytes memory ret) = comptroller.staticcall(abi.encodeWithSignature("markets(address)", mToken));
        if (!ok || ret.length < 32) return false;
        uint256 first;
        assembly {
            first := mload(add(ret, 0x20))
        }
        return first != 0;
    }
}
