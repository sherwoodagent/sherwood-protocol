// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IPriceRouter, IPriceAdapter, Position} from "../interfaces/IPriceRouter.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";

/// @title  PriceRouter
/// @notice Governance-owned, vault-side pricing oracle for live-NAV. Maps a
///         position `kind` to a pricing adapter, applies a per-kind
///         realizability haircut, and enforces a per-kind instant size cap.
///         Fail-closed: any unknown kind / adapter revert / not-OK adapter /
///         over-cap result yields `(0, false)` so the consuming vault falls
///         back to the async (Lane B) settlement path.
///
/// @dev    Inert but not unused: `SyndicateVault._laneState` calls
///         `valueStrategy` and adds the result into `totalAssets()`. No
///         adapter is currently registered, and no surviving strategy
///         overrides `positions()`, so `valueStrategy` short-circuits on the
///         empty array and every vault takes Lane B.
///
/// @dev    THE OUTPUT IS NOT NORMALIZED; a consumer must not assume it is.
///         Each adapter answers in its own numeraire at that token's decimals
///         — `IPriceAdapter.value` promises only "the position's underlying
///         units" — and `_priceOne`'s haircut is a bps ratio, so it preserves
///         whatever unit the adapter returned. `valueStrategy` takes no vault
///         or asset argument, so it cannot check. "The adapter's numeraire
///         equals `asset()` at `asset().decimals()`" is an unenforced
///         precondition on the vault's share price — the first thing any new
///         adapter must uphold: bind the locator to `IERC4626(vault()).asset()`
///         and fail closed.
contract PriceRouter is Initializable, OwnableUpgradeable, UUPSUpgradeable, IPriceRouter {
    uint16 internal constant MAX_HAIRCUT_BPS = 10_000;

    /// @notice kind => adapter that prices it.
    mapping(bytes32 kind => address adapter) public adapterOf;
    /// @notice kind => realizability haircut in bps (monotone-increasing).
    mapping(bytes32 kind => uint16 bps) public haircutBps;
    /// @notice kind => max value a single instant EXIT may take out of a
    ///         position of this kind (0 = no bound configured).
    /// @dev    Published here, enforced by the consumers that size exits — NOT
    ///         by `_priceOne`, which prices truthfully and never sees an exit
    ///         size (see the note there for the griefing vector that enforcing
    ///         it at valuation opened).
    ///
    ///         READ THIS BEFORE TUNING IT. The two kinds are asymmetric:
    ///           - `ERC20_SPOT`: INERT. `Erc20SpotAdapter` carries per-TOKEN
    ///             depth caps and `PortfolioStrategy.availableLiquidity` binds
    ///             against those, which are strictly tighter (this value is set
    ///             to the LARGEST per-token cap, so nothing reaches it before
    ///             hitting its own token's bound). Changing it will not change
    ///             stock-basket exit capacity — change the adapter's per-token
    ///             cap instead.
    ///           - `MORPHO_BLUE_SUPPLY`: LOAD-BEARING. There is no per-token
    ///             registry on the Morpho side, so this is the only depth bound
    ///             on a Morpho unwind (`MorphoSupplyStrategy.availableLiquidity`
    ///             reads it). Setting it to 0 removes that bound entirely.
    mapping(bytes32 kind => uint256 cap) public instantCap;
    /// @notice kind => whether the instant (Lane A) lane is governance-enabled.
    ///         Default false: a position is instant-eligible only after governance
    ///         audits the adapter and explicitly enables its kind.
    mapping(bytes32 kind => bool) public laneAEnabled;

    uint256[46] private __gap;

    error ZeroAddress();
    error HaircutTooHigh();
    error HaircutCannotDecrease();
    error HaircutLaneAConflict();

    event AdapterRegistered(bytes32 indexed kind, address indexed adapter);
    event HaircutSet(bytes32 indexed kind, uint16 bps);
    event InstantCapSet(bytes32 indexed kind, uint256 cap);
    event LaneAEnabledSet(bytes32 indexed kind, bool enabled);

    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_) external initializer {
        if (owner_ == address(0)) revert ZeroAddress();
        __Ownable_init(owner_);
    }

    // ── Pricing ──

    /// @inheritdoc IPriceRouter
    /// @dev Fail-closed everywhere: unknown kind, adapter revert, adapter
    ///      not-OK, and over-cap all yield `(0, false)` so the consumer falls
    ///      back to the async (Lane B) path. When `instantOK == false`, value
    ///      is 0 — `totalAssets()` shows only instantly-priceable value while
    ///      locked.
    function valuePosition(Position calldata p, address holder) external view returns (uint256, bool) {
        return _priceOne(p, holder);
    }

    /// @inheritdoc IPriceRouter
    /// @dev Aggregate vault-facing view: reads the strategy's venue positions
    ///      (never its self-reported value) and prices each. Instant-eligible
    ///      only when EVERY position's kind is Lane-A-enabled AND prices with
    ///      `instantOK`. A strategy with no positions, a not-OK position, a
    ///      disabled kind, or a reverting `positions()` is `(0, false)` →
    ///      the vault falls back to the async (Lane B) path.
    function valueStrategy(address strategy) external view returns (uint256 value, bool instantOK) {
        if (strategy == address(0)) return (0, false);
        try IStrategy(strategy).positions() returns (Position[] memory ps) {
            uint256 n = ps.length;
            if (n == 0) return (0, false);
            uint256 total;
            for (uint256 i; i < n; i++) {
                if (!laneAEnabled[ps[i].kind]) return (0, false);
                (uint256 v, bool ok) = _priceOne(ps[i], strategy);
                if (!ok) return (0, false);
                total += v;
            }
            // Instant availability requires actually-priced value. A strategy
            // whose reported positions all price to 0 (e.g. value held only in an
            // unreported venue) falls back to Lane B rather than letting deposits
            // mint against a float-only NAV that under-reports the real position.
            if (total == 0) return (0, false);
            return (total, true);
        } catch {
            return (0, false);
        }
    }

    /// @dev Single-position pricing: adapter venue-read → haircut. Fail-closed
    ///      to `(0, false)` on unknown kind / adapter revert / not-OK.
    ///
    ///      `instantCap` is deliberately NOT applied here. Size is not a
    ///      pricing doubt: this function answers what a position is worth, and
    ///      it never sees an exit size, so a cap enforced here could only bound
    ///      the POSITION — and the only lever available would be to declare the
    ///      position unpriceable. Because `valueStrategy` requires every
    ///      position to be ok, that turned one over-cap slot into a vault-wide
    ///      shutdown of the instant lane, in both directions. Adversary: a
    ///      griefer donating tokens to a strategy (position size comes from a
    ///      venue `balanceOf`, which anyone can inflate) to push a slot past the
    ///      cap and freeze deposits and exits for every LP until settlement.
    ///      Clamping instead would be worse — it under-reports `totalAssets()`
    ///      and Lane A deposits mint against the understatement (the one-sided
    ///      mark transfer `setHaircutBps` documents).
    ///
    ///      The cap is instead published (`instantCap` is public) and enforced
    ///      by the consumers that actually size exits — see
    ///      `MorphoSupplyStrategy.availableLiquidity`, and
    ///      `PortfolioStrategy.availableLiquidity`, which binds tighter still
    ///      via the spot adapter's per-token depth caps.
    function _priceOne(Position memory p, address holder) private view returns (uint256, bool) {
        address adapter = adapterOf[p.kind];
        if (adapter == address(0)) return (0, false);
        try IPriceAdapter(adapter).value(p, holder) returns (uint256 raw, bool ok) {
            if (!ok) return (0, false);
            return ((raw * uint256(MAX_HAIRCUT_BPS - haircutBps[p.kind])) / MAX_HAIRCUT_BPS, true);
        } catch {
            return (0, false);
        }
    }

    // ── Governance ──

    /// @inheritdoc IPriceRouter
    function registerAdapter(bytes32 kind, address adapter) external onlyOwner {
        if (adapter == address(0)) revert ZeroAddress();
        adapterOf[kind] = adapter;
        emit AdapterRegistered(kind, adapter);
    }

    /// @inheritdoc IPriceRouter
    /// @dev ONE-SIDED HAIRCUT, SYMMETRIC CONSUMER — read this before raising it
    ///      above 0 for a kind whose Lane A is enabled.
    ///
    ///      The haircut applies to the single value `SyndicateVault.totalAssets()`
    ///      consumes for both directions. On redemption that's correct: an
    ///      exiter is paid against a conservative mark. On deposit it inverts —
    ///      `_deposit` mints against an understated NAV, so a Lane A depositor
    ///      receives more shares than the position is worth, and `_laneALockPid`
    ///      forces them to hold until the haircut comes off, transferring the
    ///      difference from existing holders.
    ///
    ///      The correct fix is a two-sided quote — un-haircut "ask" for mints,
    ///      haircut "bid" for redemptions — an `IPriceRouter` interface change.
    ///
    ///      Enforced on-chain: this setter reverts `HaircutLaneAConflict` when
    ///      `bps != 0` and `laneAEnabled[kind]` is true, so the depositor-side
    ///      wealth transfer above can never be armed while the kind's instant
    ///      lane is live. A kind that needs a haircut stays Lane B (queue-only)
    ///      until the two-sided quote ships; `Erc20SpotAdapter` and
    ///      `MorphoSupplyAdapter` exist in-tree and `script/DeployLaneA.s.sol`
    ///      registers them and can enable Lane A, so this is reachable in
    ///      practice, not theoretical.
    function setHaircutBps(bytes32 kind, uint16 bps) external onlyOwner {
        if (bps > MAX_HAIRCUT_BPS) revert HaircutTooHigh();
        if (bps < haircutBps[kind]) revert HaircutCannotDecrease();
        if (bps != 0 && laneAEnabled[kind]) revert HaircutLaneAConflict();
        haircutBps[kind] = bps;
        emit HaircutSet(kind, bps);
    }

    /// @inheritdoc IPriceRouter
    function setInstantCap(bytes32 kind, uint256 cap) external onlyOwner {
        instantCap[kind] = cap;
        emit InstantCapSet(kind, cap);
    }

    /// @inheritdoc IPriceRouter
    /// @notice Enable / disable the instant (Lane A) lane for a position kind.
    ///         Governance flips this on only after auditing the kind's adapter.
    /// @dev    Enabling requires `haircutBps[kind] == 0`: reverts
    ///         `HaircutLaneAConflict` when `enabled == true` and the kind
    ///         carries a nonzero haircut, guarding the same invariant as
    ///         `setHaircutBps` from the other direction (see its natspec).
    ///         Disabling (`enabled == false`) is never blocked — it is the
    ///         de-escalation path and must always be available.
    function setLaneAEnabled(bytes32 kind, bool enabled) external onlyOwner {
        if (enabled && haircutBps[kind] != 0) revert HaircutLaneAConflict();
        laneAEnabled[kind] = enabled;
        emit LaneAEnabledSet(kind, enabled);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
