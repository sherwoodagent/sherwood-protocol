// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Canonical `Position.kind` identifiers shared by strategies, pricing
///         adapters, tests, and deploy scripts. A kind mismatch between a
///         strategy's `positions()` and the router's adapter registry does not
///         revert — the fail-closed router silently degrades the vault to
///         Lane B — so every party derives the constant from this single
///         definition instead of re-hashing string literals locally.
library PositionKinds {
    /// @notice Plain ERC-20 spot holding (e.g. a tokenized stock). Venue is
    ///         the token contract; quantity is `balanceOf(holder)`.
    bytes32 internal constant ERC20_SPOT = keccak256("ERC20_SPOT");

    /// @notice Morpho Blue supply position. Venue is the canonical Morpho
    ///         singleton; `ref` carries the market id.
    bytes32 internal constant MORPHO_BLUE_SUPPLY = keccak256("MORPHO_BLUE_SUPPLY");
}
