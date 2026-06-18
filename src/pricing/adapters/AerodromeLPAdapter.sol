// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPriceAdapter, Position} from "../../interfaces/IPriceRouter.sol";

/// @notice Minimal Aerodrome (Velodrome-v2 fork) pool surface used for pricing.
interface IAeroPool {
    function getReserves() external view returns (uint256 reserve0, uint256 reserve1, uint256 blockTimestampLast);
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function token0() external view returns (address);
    function token1() external view returns (address);
    /// @notice Native cumulative-price TWAP: averages `amountIn` of `tokenIn`
    ///         over the last `granularity` observations, returning the quote in
    ///         the other token.
    function quote(address tokenIn, uint256 amountIn, uint256 granularity) external view returns (uint256);
    /// @notice Most recent recorded observation (written on swaps/mints).
    function lastObservation()
        external
        view
        returns (uint256 timestamp, uint256 reserve0Cumulative, uint256 reserve1Cumulative);
}

interface IAeroPoolFactory {
    function isPool(address pool) external view returns (bool);
}

interface IAeroGaugeBal {
    function balanceOf(address account) external view returns (uint256);
}

/// @title  AerodromeLPAdapter
/// @notice Prices an Aerodrome LP position vault-side using the pool's NATIVE
///         cumulative-price TWAP (`quote()`), with no custodial recorder. The
///         position is read from the venue (LP balance on the pool + gauge),
///         decomposed into its two legs from the live reserves, and the
///         non-numeraire leg is valued in the numeraire (= the vault asset) via
///         the TWAP. Three call-time gates protect against manipulation:
///           1. venue validation — `factory.isPool(pool)` (no fake pools);
///           2. observation recency — reject if the newest observation is stale
///              (a thin/low-activity pool's TWAP can span a long, manipulable
///              window — the narrower, on-chain-verified form of the original
///              "Aerodrome TWAP" review caution);
///           3. spot-vs-TWAP deviation — reject if the most-recent-observation
///              quote diverges from the longer TWAP beyond `maxDeviationBps`.
///         The realizability haircut + instant size cap are applied by the
///         PriceRouter (the size cap is also the effective min-depth defense:
///         a position too large for a thin pool exceeds the cap → Lane B).
/// @dev    Fail-closed to `(0, false)` on any failing gate → async (Lane B).
///         Calibration params (Q3) are immutable; retune via a new adapter.
contract AerodromeLPAdapter is IPriceAdapter {
    bytes32 public constant KIND = keccak256("AERODROME_LP");
    /// @notice Recent-observation granularity for the spot leg of the deviation gate.
    uint256 internal constant SPOT_GRANULARITY = 1;

    address public immutable factory; // trusted Aerodrome PoolFactory
    uint256 public immutable twapGranularity; // observations averaged for the mark
    uint256 public immutable maxStaleness; // recency bound (seconds)
    uint16 public immutable maxDeviationBps; // spot-vs-TWAP gate

    error BadConfig();

    constructor(address factory_, uint256 twapGranularity_, uint256 maxStaleness_, uint16 maxDeviationBps_) {
        if (factory_ == address(0) || twapGranularity_ == 0 || maxStaleness_ == 0 || maxDeviationBps_ > 10_000) {
            revert BadConfig();
        }
        factory = factory_;
        twapGranularity = twapGranularity_;
        maxStaleness = maxStaleness_;
        maxDeviationBps = maxDeviationBps_;
    }

    /// @inheritdoc IPriceAdapter
    /// @param p `venue` = the Aerodrome pool; `ref` = abi.encode(address gauge,
    ///        address numeraire) where `gauge` is the staking gauge (or
    ///        address(0)) and `numeraire` is the vault asset (must be one of the
    ///        pool tokens). `holder` is the strategy.
    function value(Position calldata p, address holder) external view returns (uint256, bool) {
        address pool = p.venue;
        if (!IAeroPoolFactory(factory).isPool(pool)) return (0, false);
        (address gauge, address numeraire) = abi.decode(p.ref, (address, address));

        uint256 lpBal = IAeroPool(pool).balanceOf(holder);
        if (gauge != address(0)) lpBal += IAeroGaugeBal(gauge).balanceOf(holder);
        if (lpBal == 0) return (0, true);

        uint256 supply = IAeroPool(pool).totalSupply();
        if (supply == 0) return (0, false);

        // Recency: the TWAP is only as fresh as the last recorded observation.
        (uint256 lastTs,,) = IAeroPool(pool).lastObservation();
        if (block.timestamp > lastTs + maxStaleness) return (0, false);

        (uint256 r0, uint256 r1,) = IAeroPool(pool).getReserves();
        address t0 = IAeroPool(pool).token0();
        address t1 = IAeroPool(pool).token1();

        uint256 numAmt;
        address other;
        uint256 otherAmt;
        if (numeraire == t0) {
            numAmt = (lpBal * r0) / supply;
            other = t1;
            otherAmt = (lpBal * r1) / supply;
        } else if (numeraire == t1) {
            numAmt = (lpBal * r1) / supply;
            other = t0;
            otherAmt = (lpBal * r0) / supply;
        } else {
            return (0, false); // numeraire not a pool token
        }

        if (otherAmt == 0) return (numAmt, true);

        uint256 twap = IAeroPool(pool).quote(other, otherAmt, twapGranularity);
        if (twap == 0) return (0, false);
        uint256 spot = IAeroPool(pool).quote(other, otherAmt, SPOT_GRANULARITY);
        uint256 diff = spot > twap ? spot - twap : twap - spot;
        if (diff * 10_000 > twap * maxDeviationBps) return (0, false); // deviation gate

        return (numAmt + twap, true);
    }
}
