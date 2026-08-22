// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title  IWoodTwapOracle
/// @notice The read surface `ExposureLedger` consumes to obtain a
///         manipulation-resistant WOOD/USD price from a Uniswap-V2-style pair.
///
/// @dev    THE TWAP IS NEVER AN UNBOUNDED PRICE. `ExposureLedger` admits this
///         number only under `min(source, woodUsdPriceX8)`, and the pool behind
///         it is ~$437k deep (design.md, measured 2026-08-01). Promoting it to
///         an unbounded price source would make that pool the valuation basis
///         for every guardian bond in the protocol. Any consumer added later
///         must preserve that constraint.
interface IWoodTwapOracle {
    // ── Errors ──
    error ZeroAddress();
    error InvalidParameter();
    /// @notice The configured pair does not hold exactly {WOOD, WETH}, has an
    ///         empty reserve, or has never accumulated a price — none of which
    ///         can be fixed after construction, so the deploy is refused.
    error PairNotUsable();

    // ── Events ──
    event ObservationRecorded(uint256 cumulative, uint32 timestamp, uint32 spanFromPrevious);
    event TwapWindowSet(uint256 oldWindow, uint256 newWindow);
    event MaxTwapAgeSet(uint256 oldAge, uint256 newAge);
    event EthUsdMaxDelaySet(uint256 oldDelay, uint256 newDelay);

    /// @notice Snapshot the pair's cumulative-price accumulator. Permissionless
    ///         by design (design.md decision 4): the point of this contract is
    ///         to replace a judgment keeper with a mechanical one, so there is
    ///         no owner check, no allowlist and no privileged caller to
    ///         compromise.
    /// @return recorded Whether this call advanced the observation pair. False
    ///         means the call was a no-op — too soon after the previous
    ///         snapshot, or the pair was unreadable — never a revert, so a
    ///         keeper bot cannot be griefed into a failing transaction.
    function update() external returns (bool recorded);

    /// @notice The time-weighted WOOD/USD price over the last completed window,
    ///         8 decimals.
    /// @dev    MUST NOT REVERT. The ledger guards this call defensively anyway,
    ///         but this contract's own contract is `(0, false)` on every
    ///         degraded shape: no completed window, a window shorter than
    ///         `twapWindow` or longer than `MAX_TWAP_SPAN`, a snapshot older
    ///         than `maxTwapAge`, an unusable ETH/USD feed, or a price that
    ///         floors to zero at 8 decimals.
    function consult() external view returns (uint256 twapUsdX8, bool ok);

    /// @notice Live re-check of the invariants the constructor enforced: the
    ///         pair holds exactly {WOOD, WETH} in the recorded ordering, both
    ///         reserves are non-zero, and the accumulator has advanced.
    /// @dev    `ExposureLedger.setWoodTwapOracle` requires this to be true
    ///         before wiring, so an empty or wrong-token pool cannot be adopted
    ///         by address alone (spec: "the pair is validated before it is
    ///         trusted").
    function validatePair() external view returns (bool);

    function pair() external view returns (address);
    function wood() external view returns (address);
    function weth() external view returns (address);
    function woodIsToken0() external view returns (bool);
    function ethUsdFeed() external view returns (address);
    function twapWindow() external view returns (uint256);
    function maxTwapAge() external view returns (uint256);
    function ethUsdMaxDelay() external view returns (uint256);

    function setTwapWindow(uint256 newWindow) external;
    function setMaxTwapAge(uint256 newAge) external;
    function setEthUsdMaxDelay(uint256 newDelay) external;
}
