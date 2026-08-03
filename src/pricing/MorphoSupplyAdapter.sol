// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPriceAdapter, Position} from "../interfaces/IPriceRouter.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {PositionKinds} from "../libraries/PositionKinds.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IMorpho, Id, MarketParams} from "../vendor/morpho/IMorpho.sol";
import {MorphoBalancesLib} from "../vendor/morpho/MorphoLibs.sol";

/**
 * @title MorphoSupplyAdapter
 * @notice Prices `MORPHO_BLUE_SUPPLY` positions for the PriceRouter: the
 *         holder's supply shares converted to loan-token assets over the
 *         market's interest-accrued totals (`toAssetsDown` — the redeemable
 *         value a same-block withdraw delivers). Pure market accounting — no
 *         external price oracle is involved.
 *
 *         Fail-closed: every guard returns `(0, false)` and the adapter never
 *         reverts, so the router degrades the vault to Lane B instead of
 *         bricking `totalAssets()`.
 */
contract MorphoSupplyAdapter is IPriceAdapter {
    /// @notice The canonical Morpho Blue singleton — pinned at deploy so a
    ///         position cannot point valuation at a lookalike contract.
    IMorpho public immutable morpho;

    error ZeroAddress();
    /// @dev Internal-only signals surfaced through the `value` try/catch —
    ///      they never escape this contract.
    error UnknownMarket();
    error NumeraireMismatch();

    constructor(address morpho_) {
        if (morpho_ == address(0)) revert ZeroAddress();
        morpho = IMorpho(morpho_);
    }

    /// @inheritdoc IPriceAdapter
    /// @dev Guards, each with its adversary:
    ///        - kind != MORPHO_BLUE_SUPPLY → (0, false). Adversary: a router
    ///          misregistration routing a foreign kind here; defense in depth
    ///          on top of the router's kind→adapter mapping.
    ///        - venue != the canonical singleton → (0, false). Adversary: a
    ///          strategy naming a spoofed Morpho lookalike as `venue` whose
    ///          state it controls, fabricating supply value (spoofed-venue).
    ///        - `ref` not exactly one bytes32, or the id unknown to the
    ///          singleton (`idToMarketParams` returns a zero loan token) →
    ///          (0, false). Adversary: a fabricated market id that decodes but
    ///          was never created (spoofed-market).
    ///        - market loan token != the holder's vault asset → (0, false).
    ///          Adversary: a real market in the wrong numeraire — its share
    ///          value would be added into `totalAssets()` at a foreign token's
    ///          scale (the unenforced-precondition the router natspec warns
    ///          adapters to uphold).
    ///        - ANY external read reverting (singleton, IRM, holder, vault) →
    ///          (0, false) via the try/catch around `unguardedValue`.
    function value(Position calldata p, address holder) external view returns (uint256, bool) {
        if (p.kind != PositionKinds.MORPHO_BLUE_SUPPLY) return (0, false);
        if (p.venue != address(morpho)) return (0, false);
        if (p.ref.length != 32) return (0, false);
        Id id = Id.wrap(abi.decode(p.ref, (bytes32)));

        try this.unguardedValue(id, holder) returns (uint256 v) {
            return (v, true);
        } catch {
            return (0, false);
        }
    }

    /// @notice Valuation body, external ONLY so `value` can wrap it in a
    ///         try/catch (fail-closed conversion of any revert). Not part of
    ///         the adapter's consumed interface — callers other than `value`
    ///         get raw reverts, never a safe default.
    function unguardedValue(Id id, address holder) external view returns (uint256) {
        MarketParams memory mp = morpho.idToMarketParams(id);
        if (mp.loanToken == address(0)) revert UnknownMarket();

        address vaultAsset = IERC4626(IStrategy(holder).vault()).asset();
        if (mp.loanToken != vaultAsset) revert NumeraireMismatch();

        return MorphoBalancesLib.expectedSupplyAssets(morpho, mp, holder);
    }
}
