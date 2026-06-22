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
///
///         IN-FLIGHT BRIDGE CAPITAL (keep-disabled requirement): the mark is the
///         holder's HyperCore equity only. During an EVM<->HyperCore transit
///         window, capital already gone from vault float but not yet credited to
///         HC equity is OMITTED, so the mark under-reports NAV. There is no
///         manipulation-resistant venue read for a holder's in-transit bridge
///         balance — the strategy's `inFlightToHc` is a self-reported monotonic
///         high-water mark, not a live in-transit balance, so trusting it would
///         reintroduce exactly the self-reporting this redesign removed. HL_PERP
///         MUST therefore stay `laneAEnabled == false` until an on-chain
///         in-transit source exists; until then HL perp positions settle via
///         Lane B at the realized price.
contract HyperliquidPerpAdapter is IPriceAdapter {
    bytes32 public constant KIND = keccak256("HL_PERP");

    /// @inheritdoc IPriceAdapter
    /// @param p `ref` optionally abi-encodes the perp dex index (uint32); empty
    ///        ⇒ index 0 (the main perp dex). `venue` is unused — the precompile
    ///        address is fixed.
    /// @param holder the account whose HyperCore equity is read.
    function value(Position calldata p, address holder) external view returns (uint256, bool) {
        uint32 dex = p.ref.length == 32 ? abi.decode(p.ref, (uint32)) : 0;
        // Centralized precompile read (fail-closed on call failure / short buffer).
        (AccountMarginSummary memory s, bool ok) = L1Read.tryAccountMarginSummary(dex, holder);
        if (!ok) return (0, false);
        // `accountValue` is 6-decimal USD (perp domain) == USDC 6dp. Non-positive
        // equity (liquidated / fully underwater) prices to 0 but is validly read.
        if (s.accountValue <= 0) return (0, true);
        return (uint256(uint64(s.accountValue)), true);
    }
}
