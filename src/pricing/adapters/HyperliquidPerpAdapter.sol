// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPriceAdapter, Position} from "../../interfaces/IPriceRouter.sol";
import {IHyperliquidPerpStrategy} from "../../interfaces/IHyperliquidPerpStrategy.sol";
import {L1Read, AccountMarginSummary} from "../../hyperliquid/L1Read.sol";

/// @title  HyperliquidPerpAdapter
/// @notice Prices a HyperCore perp account's equity (margin + unrealized PnL)
///         via the AccountMarginSummary precompile (0x...080F) — HyperLiquid's
///         manipulation-resistant venue mark (a median across external CEXes +
///         its own book, the oracle a depositor cannot move). The vault reads
///         the holder (strategy)'s equity directly from the precompile; the
///         strategy is never trusted for value, and the precompile address is
///         hardcoded so a strategy cannot point at a fake venue.
/// @dev    The realizability haircut + instant size cap (the March-2025 $4M HLP
///         lesson — an oracle mark is only fair if the position is realizable at
///         that mark for the held size) are applied by the PriceRouter.
///         HyperEVM-only: on a chain without the precompile the staticcall
///         fails and this returns `(0, false)` (fail-closed -> Lane B).
///
///         TRANSIT GUARDS — two windows where HC equity is temporarily unreliable:
///
///         Inbound (execute -> HC credit, ~1-2 blocks): fresh clone has HC equity = 0.
///         Adapter returns `(0, true)` -> PriceRouter G3 (`total == 0`) -> `(0, false)`
///         -> Lane B. Already safe without explicit code in this contract.
///
///         Outbound (initiateReturn -> HC drain, ~1-2 blocks): `returnsInitiated` is
///         stamped BEFORE `_drainHC()` queues to HC. HC equity is still non-zero for
///         one block. This adapter gates on `returnsInitiated` -> returns `(0, false)`
///         -> Lane B, preventing new Lane A deposits during active settlement.
contract HyperliquidPerpAdapter is IPriceAdapter {
    bytes32 public constant KIND = keccak256("HL_PERP");

    /// @inheritdoc IPriceAdapter
    /// @param p `ref` optionally abi-encodes the perp dex index (uint32); empty
    ///        => index 0 (the main perp dex). `venue` is unused — the precompile
    ///        address is fixed.
    /// @param holder the account whose HyperCore equity is read.
    function value(Position calldata p, address holder) external view returns (uint256, bool) {
        // Outbound transit guard: returnsInitiated is set before _drainHC() queues HC
        // actions. HC equity may still be non-zero for one block after the flag flips.
        // Force Lane B during active settlement so no new LPs lock into a settling proposal.
        // Low-level staticcall avoids Solidity ABI-decode failures for holders that don't
        // implement returnsInitiated() or return unexpected data.
        (bool success, bytes memory retData) =
            holder.staticcall(abi.encodeWithSelector(IHyperliquidPerpStrategy.returnsInitiated.selector));
        if (success && retData.length >= 32 && abi.decode(retData, (bool))) {
            return (0, false);
        }

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
