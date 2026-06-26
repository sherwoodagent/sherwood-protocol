// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title  LeveragedAeroFees
/// @notice Streaming management fee + high-water-mark (HWM) performance fee for the
///         leveraged Aerodrome CL strategy, both crystallised by minting fee-shares.
///
///         All functions are **pure** — the strategy passes state in and applies the
///         returned deltas (`newHwmPerShareX`, `newLastAccrual`); it then calls
///         `vault.strategyMint(feeRecipient, feeShares)`.  No storage is touched here.
///
///         ## Decimal context
///         - `navPre`        USDC, 6 dp.
///         - `totalSupply`   vault shares, 12 dp (`_decimalsOffset() = 6` on USDC 6 dp).
///         - `hwmPerShareX`  = `navPre × 1e18 / totalSupply` — dimensionless, 1e18-scaled.
///         - Fee rates (`managementFeeBps`, `performanceFeeBps`) are bps; 1% = 100.
///
///         ## Ordering
///         `crystallize` computes management and performance fees against the **same**
///         pre-action `navPre` / `totalSupply`.  Management shares are NOT applied before
///         the performance computation — LP-favourable: avoids double-counting that
///         dilution in the HWM basis.
///
///         ## [1] review fix (phantom-fee guard)
///         `crystallize` must be called with the *pre-deposit* NAV, before the vault
///         pulls any USDC.  Calling it on the post-deposit NAV would let idle incoming
///         USDC look like a profit above the HWM, silently over-charging existing LPs.
///         The library enforces nothing about call ordering — that invariant is owned by
///         the strategy (Tasks 3.6 / 3.7).  `test_noPhantomFee_whenIdleJustLanded`
///         anchors the regression: given the correct pre-deposit input, this library
///         produces zero performance fee.
library LeveragedAeroFees {
    /// @dev 1e18 fixed-point scale for per-share HWM and the management fee rate.
    uint256 private constant WAD = 1e18;

    /// @dev 365-day year in seconds (365 × 24 × 60 × 60 = 31 536 000).
    uint256 private constant SECONDS_PER_YEAR = 365 days;

    // =========================================================================
    // Management fee
    // =========================================================================

    /// @notice Streaming management fee shares for an elapsed window `dt`.
    ///
    ///         `feeRate = managementFeeBps × dt / (10 000 × SECONDS_PER_YEAR)`
    ///
    ///         Minting `feeShares = totalSupply × feeRate / (1 − feeRate)` ensures the
    ///         recipient owns exactly `feeRate` of the **post-mint** supply, i.e. the
    ///         annualised dilution equals the bps fraction of AUM.
    ///
    ///         Rounds **down** (LP-favourable).
    ///
    /// @param totalSupply      Current vault share supply (12 dp).
    /// @param managementFeeBps Annual management fee in bps (e.g. 100 = 1 %/yr).
    /// @param dt               Seconds elapsed since last accrual.
    /// @return feeShares       Shares to mint to the fee recipient.
    function managementFeeShares(uint256 totalSupply, uint256 managementFeeBps, uint256 dt)
        internal
        pure
        returns (uint256 feeShares)
    {
        if (totalSupply == 0 || managementFeeBps == 0 || dt == 0) return 0;

        // feeRateX = managementFeeBps × dt × WAD / (10 000 × SECONDS_PER_YEAR).
        // Math.mulDiv carries the 512-bit intermediate: the pre-multiply
        // (managementFeeBps × dt) fits easily in uint256 for any realistic timestamp.
        uint256 feeRateX = Math.mulDiv(managementFeeBps * dt, WAD, 10_000 * SECONDS_PER_YEAR);

        // Absurd-dt guard: if feeRate ≥ 100 % the denominator (WAD − feeRateX) would
        // underflow.  Return 0 (LP-favourable) rather than reverting — stale accruals
        // must not brick the contract (e.g. extreme bps × impossible dt).
        if (feeRateX >= WAD) return 0;

        // feeShares = totalSupply × feeRateX / (WAD − feeRateX), rounded down.
        // Post-mint invariant: feeShares / (totalSupply + feeShares) = feeRateX / WAD.
        feeShares = Math.mulDiv(totalSupply, feeRateX, WAD - feeRateX);
    }

    // =========================================================================
    // Performance fee
    // =========================================================================

    /// @notice HWM performance fee shares.
    ///
    ///         `navPerShareX = navPre × 1e18 / totalSupply`  (1e18-scaled ratio)
    ///
    ///         - If `hwmPerShareX == 0` (never set): seed the HWM to the current level,
    ///           **no fee charged** — avoids a phantom fee on the first cycle after deploy.
    ///         - If `navPerShareX ≤ hwmPerShareX`: no fee, HWM unchanged.
    ///         - Else:
    ///
    ///             gain = (navPerShareX − hwmPerShareX) × totalSupply / 1e18  (USDC 6 dp)
    ///             fee  = gain × performanceFeeBps / 10 000                    (USDC 6 dp)
    ///             feeShares = fee × totalSupply / (navPre − fee)              (12 dp shares)
    ///
    ///           After mint the recipient holds value ≈ `fee` USDC and the HWM resets to
    ///           `navPerShareX` so future fees accrue only on NEW gains.
    ///
    ///         If `performanceFeeBps == 0` but there is a gain, the HWM still advances
    ///         (no retroactive back-charge when the rate is later set non-zero).
    ///
    ///         Rounds **down** (LP-favourable).
    ///
    /// @param navPre            Pre-action strategy NAV (USDC, 6 dp).
    /// @param totalSupply       Current vault share supply (12 dp).
    /// @param hwmPerShareX      Stored HWM per share (1e18-scaled); 0 ⇒ first cycle.
    /// @param performanceFeeBps Performance fee in bps (e.g. 1000 = 10 %).
    /// @return feeShares        Shares to mint (0 if at/below HWM or unset).
    /// @return newHwmPerShareX  Updated HWM (unchanged if no gain).
    function performanceFeeShares(uint256 navPre, uint256 totalSupply, uint256 hwmPerShareX, uint256 performanceFeeBps)
        internal
        pure
        returns (uint256 feeShares, uint256 newHwmPerShareX)
    {
        // No capital — nothing to charge or update.
        if (totalSupply == 0 || navPre == 0) return (0, hwmPerShareX);

        uint256 navPerShareX = Math.mulDiv(navPre, WAD, totalSupply);

        // First-time seeding: HWM was 0 (unset). Record current level, no fee charged —
        // avoids a phantom performance fee on the first crystallize after deployment.
        if (hwmPerShareX == 0) return (0, navPerShareX);

        // At or below the high-water mark → no fee, mark unchanged.
        if (navPerShareX <= hwmPerShareX) return (0, hwmPerShareX);

        // Gain above the HWM is recognised; HWM always advances to the new peak, even if
        // the fee rate is zero, so future non-zero rates don't back-charge this gain.
        if (performanceFeeBps == 0) return (0, navPerShareX);

        // Gain in USDC 6 dp: (navPerShareX − hwmPerShareX) × totalSupply / WAD.
        uint256 gainPerShareX = navPerShareX - hwmPerShareX;
        uint256 totalGainUsdc = Math.mulDiv(gainPerShareX, totalSupply, WAD);
        uint256 feeValueUsdc = Math.mulDiv(totalGainUsdc, performanceFeeBps, 10_000);

        // Degenerate guard: fee must be strictly less than NAV (else denominator ≤ 0).
        // This can only trigger for extreme/malformed fee rates — fail safe, LP-favourable.
        if (feeValueUsdc >= navPre) return (0, navPerShareX);

        // Dilution: mint enough shares so the recipient's value ≈ feeValueUsdc.
        // feeShares × navPre / (totalSupply + feeShares) = feeValueUsdc  (exact by algebra).
        feeShares = Math.mulDiv(feeValueUsdc, totalSupply, navPre - feeValueUsdc);
        newHwmPerShareX = navPerShareX;
    }

    // =========================================================================
    // Combined entrypoint
    // =========================================================================

    /// @notice Crystallise management + performance fees before a user action.
    ///
    ///         **Call with the pre-action NAV** (before USDC is pulled in or shares are
    ///         burned) so that no incoming deposit inflates the HWM basis ([1] fix).
    ///
    ///         The strategy:
    ///         1. Calls `crystallize(nav(), vault.totalSupply(), ...)`.
    ///         2. Calls `vault.strategyMint(feeRecipient, feeShares)` if `feeShares > 0`.
    ///         3. Stores `hwmPerShareX = newHwmPerShareX` and `lastAccrual = newLastAccrual`.
    ///         4. Proceeds with the user action (deposit / redeem).
    ///
    /// @param navPre            Strategy NAV before any user action (USDC, 6 dp).
    /// @param totalSupply       Current vault share supply (12 dp).
    /// @param hwmPerShareX      Stored HWM per share (1e18-scaled); 0 ⇒ first cycle.
    /// @param lastAccrual       Timestamp of the previous crystallization.
    /// @param nowTs             Current `block.timestamp`.
    /// @param managementFeeBps  Annual management fee in bps.
    /// @param performanceFeeBps Performance fee in bps.
    /// @return feeShares        Total shares to mint (management + performance).
    /// @return newHwmPerShareX  Updated HWM to store.
    /// @return newLastAccrual   Updated accrual timestamp (= `nowTs`).
    function crystallize(
        uint256 navPre,
        uint256 totalSupply,
        uint256 hwmPerShareX,
        uint256 lastAccrual,
        uint256 nowTs,
        uint256 managementFeeBps,
        uint256 performanceFeeBps
    ) public pure returns (uint256 feeShares, uint256 newHwmPerShareX, uint256 newLastAccrual) {
        // Always advance the accrual timestamp so management fees do not accumulate
        // over periods when the vault held no capital.
        newLastAccrual = nowTs;

        // No capital: zero fees, HWM unchanged.
        if (totalSupply == 0 || navPre == 0) {
            newHwmPerShareX = hwmPerShareX;
            return (0, newHwmPerShareX, newLastAccrual);
        }

        // dt is 0 when called in the same block as the last accrual (e.g. two deposits).
        uint256 dt = nowTs > lastAccrual ? nowTs - lastAccrual : 0;

        uint256 mShares = managementFeeShares(totalSupply, managementFeeBps, dt);
        (uint256 pShares, uint256 newHwm) = performanceFeeShares(navPre, totalSupply, hwmPerShareX, performanceFeeBps);

        // feeShares = mShares + pShares; overflow impossible (both << totalSupply).
        feeShares = mShares + pShares;
        newHwmPerShareX = newHwm;
    }
}
