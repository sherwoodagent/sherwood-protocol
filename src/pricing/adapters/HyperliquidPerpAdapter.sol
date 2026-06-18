// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPriceAdapter, Position} from "../../interfaces/IPriceRouter.sol";
import {L1Read, AccountMarginSummary} from "../../hyperliquid/L1Read.sol";

/// @title  HyperliquidPerpAdapter
/// @notice Prices a HyperCore perp account's equity (margin + unrealized PnL)
///         via the AccountMarginSummary precompile (0x…080F) — HyperLiquid's
///         manipulation-resistant venue mark (a median across external CEXes +
///         its own book, the oracle a depositor cannot move). The vault reads
///         the holder (strategy)'s equity directly from the precompile; the
///         strategy is never trusted for value, and the precompile address is
///         hardcoded so a strategy cannot point at a fake venue.
/// @dev    The realizability haircut + instant size cap (the March-2025 $4M HLP
///         lesson — an oracle mark is only fair if the position is realizable at
///         that mark for the held size) are applied by the PriceRouter.
///         HyperEVM-only: on a chain without the precompile the staticcall
///         fails and this returns `(0, false)` (fail-closed → Lane B).
contract HyperliquidPerpAdapter is IPriceAdapter {
    bytes32 public constant KIND = keccak256("HL_PERP");

    /// @inheritdoc IPriceAdapter
    /// @param p `ref` optionally abi-encodes the perp dex index (uint32); empty
    ///        ⇒ index 0 (the main perp dex). `venue` is unused — the precompile
    ///        address is fixed.
    /// @param holder the account whose HyperCore equity is read.
    function value(Position calldata p, address holder) external view returns (uint256, bool) {
        uint32 dex = p.ref.length == 32 ? abi.decode(p.ref, (uint32)) : 0;
        (bool ok, bytes memory ret) = L1Read.ACCOUNT_MARGIN_SUMMARY_PRECOMPILE_ADDRESS
        .staticcall{gas: L1Read.ACCOUNT_MARGIN_SUMMARY_GAS}(
            abi.encode(dex, holder)
        );
        if (!ok || ret.length < 128) return (0, false);
        AccountMarginSummary memory s = abi.decode(ret, (AccountMarginSummary));
        // `accountValue` is 6-decimal USD (perp domain) == USDC 6dp. Non-positive
        // equity (liquidated / fully underwater) prices to 0 but is validly read.
        if (s.accountValue <= 0) return (0, true);
        return (uint256(uint64(s.accountValue)), true);
    }
}
