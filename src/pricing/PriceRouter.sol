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
///         over-cap result yields `(0, false)` so the consuming vault silently
///         falls back to the async (Lane B) settlement path. Phase 1 of the
///         live-NAV redesign (PR #357) — no vault consumes this yet.
contract PriceRouter is Initializable, OwnableUpgradeable, UUPSUpgradeable, IPriceRouter {
    uint16 internal constant MAX_HAIRCUT_BPS = 10_000;

    /// @notice kind => adapter that prices it.
    mapping(bytes32 kind => address adapter) public adapterOf;
    /// @notice kind => realizability haircut in bps (monotone-increasing).
    mapping(bytes32 kind => uint16 bps) public haircutBps;
    /// @notice kind => max single-position value eligible for instant pricing (0 = unlimited).
    mapping(bytes32 kind => uint256 cap) public instantCap;
    /// @notice kind => whether the instant (Lane A) lane is governance-enabled.
    ///         Default false: a position is instant-eligible only after governance
    ///         audits the adapter and explicitly enables its kind.
    mapping(bytes32 kind => bool) public laneAEnabled;

    uint256[46] private __gap;

    error ZeroAddress();
    error HaircutTooHigh();
    error HaircutCannotDecrease();

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
    ///      is 0 (G2 Option A) — `totalAssets()` shows only instantly-priceable
    ///      value while locked.
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
            // G3: instant availability requires actually-priced value. A strategy
            // whose reported positions all price to 0 (e.g. value held only in an
            // unreported venue) falls back to Lane B rather than letting deposits
            // mint against a float-only NAV that under-reports the real position.
            if (total == 0) return (0, false);
            return (total, true);
        } catch {
            return (0, false);
        }
    }

    /// @dev Single-position pricing: adapter venue-read → haircut → instant cap.
    ///      Fail-closed to `(0, false)` on unknown kind / adapter revert /
    ///      not-OK / over-cap.
    function _priceOne(Position memory p, address holder) private view returns (uint256, bool) {
        address adapter = adapterOf[p.kind];
        if (adapter == address(0)) return (0, false);
        try IPriceAdapter(adapter).value(p, holder) returns (uint256 raw, bool ok) {
            if (!ok) return (0, false);
            uint256 v = (raw * uint256(MAX_HAIRCUT_BPS - haircutBps[p.kind])) / MAX_HAIRCUT_BPS;
            uint256 cap = instantCap[p.kind];
            if (cap != 0 && v > cap) return (0, false);
            return (v, true);
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
    function setHaircutBps(bytes32 kind, uint16 bps) external onlyOwner {
        if (bps > MAX_HAIRCUT_BPS) revert HaircutTooHigh();
        if (bps < haircutBps[kind]) revert HaircutCannotDecrease();
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
    function setLaneAEnabled(bytes32 kind, bool enabled) external onlyOwner {
        laneAEnabled[kind] = enabled;
        emit LaneAEnabledSet(kind, enabled);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
