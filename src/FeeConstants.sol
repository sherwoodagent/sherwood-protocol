// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title FeeConstants
/// @notice Single source of truth for the protocol-wide fee ceilings and the
///         basis-point denominator. Shared by the governor (the
///         `maxPerformanceFeeBps` hard cap, `MAX_PERFORMANCE_FEE_CAP`), the
///         vault (the `agentFeeBps` hard cap, `MAX_AGENT_FEE_BPS`) and the
///         factory (the per-vault default) so they can never silently diverge
///         from a hand-edited literal (L1). Referenced as compile-time
///         constants, so this adds no runtime bytecode.
library FeeConstants {
    /// @notice Hard ceiling on the agent performance fee, in basis points (30%).
    /// @dev This is the outer bound governance can ever reach, not the headline
    ///      rate. Three limits stack below it: this constant, the per-vault
    ///      `maxPerformanceFeeBps` (factory default
    ///      `DEFAULT_MAX_PERFORMANCE_FEE_BPS`), and the vault's own
    ///      `agentFeeBps`. Raised 1500 -> 3000 so the 20% headline of the
    ///      two-number fee model is reachable without making 30% the default.
    uint256 internal constant MAX_PERFORMANCE_FEE_BPS = 3000;

    /// @notice Per-vault performance-fee ceiling a newly created vault starts
    ///         with, in basis points (20%) — the advertised headline rate.
    /// @dev Deliberately below `MAX_PERFORMANCE_FEE_BPS`. The governor's
    ///      settle-time clamp resolves an over-ceiling rate *silently* (it
    ///      emits `FeeClamped` and continues rather than reverting), so a
    ///      permissive default fails open — an owner quietly charges above the
    ///      headline — while this one fails closed, with an event. Charging
    ///      above the headline therefore needs an explicit, separately
    ///      authorized governor param change.
    uint256 internal constant DEFAULT_MAX_PERFORMANCE_FEE_BPS = 2000;

    /// @notice Default agent performance fee a vault charges until its owner
    ///         sets one, in basis points (5%). Single source of truth for the
    ///         vault getter's fallback (mirror it in any off-chain default).
    uint256 internal constant DEFAULT_AGENT_FEE_BPS = 500;

    /// @notice 100% in basis points, for fee arithmetic.
    /// @dev Fee math spans the vault, the governor and the protocol config;
    ///      this gives those three one denominator instead of a literal per
    ///      call site. Deliberately not a refactor target for the existing
    ///      `BPS_DENOMINATOR` constants in `GuardianRegistry`,
    ///      `StakedWoodDelegation`, `GovernorParameters` and
    ///      `PortfolioStrategy` — the last of those is `public` and therefore
    ///      ABI surface.
    uint256 internal constant BPS_DENOMINATOR = 10_000;
}
