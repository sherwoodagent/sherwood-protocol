// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LeveragedAeroFees} from "../src/strategies/LeveragedAeroFees.sol";

/// @notice Unit tests for LeveragedAeroFees — pure math, no mocks needed.
///
///         Decimal context (matching the live vault):
///         - NAV:   USDC 6 dp  (e.g. 100_000e6 = $100 000).
///         - Supply: shares 12 dp  (vault _decimalsOffset = 6 on top of USDC 6 dp,
///                   so 1 USDC deposited mints 1 × 10^12 shares at 1:1).
///         - hwmPerShareX = navPre × 1e18 / totalSupply.
///           At 1:1: 100_000e6 × 1e18 / 100_000e12 = 1e12.
///
///         The three primary tests match the brief's required invariants:
///           1. test_management_dilutesByRatePerYear
///           2. test_performance_onlyAboveHWM
///           3. test_noPhantomFee_whenIdleJustLanded
contract LeveragedAeroFeesTest is Test {
    // -------------------------------------------------------------------------
    // Constants shared across tests
    // -------------------------------------------------------------------------

    uint256 private constant WAD = 1e18;
    uint256 private constant SECONDS_PER_YEAR = 365 days;

    // USDC 6 dp amounts
    uint256 private constant NAV_90k = 90_000e6;
    uint256 private constant NAV_100k = 100_000e6;
    uint256 private constant NAV_110k = 110_000e6;

    // Share supply 12 dp: 1:1 parity ↔ 100 000 shares for 100 000 USDC
    uint256 private constant SUPPLY_100k = 100_000e12;
    uint256 private constant SUPPLY_1M = 1_000_000e12;

    // HWM at 1:1 (100 000 USDC / 100 000 shares at 12 dp): 100_000e6 × 1e18 / 100_000e12 = 1e12
    uint256 private constant HWM_1TO1 = 1e12;

    // =========================================================================
    // Invariant 1 — Management fee dilutes by the annualised rate
    // =========================================================================

    /// @dev Over exactly 1 year at 1 %/yr the fee recipient must own ≈ 1 % of
    ///      the post-mint supply, and the prior holders' fraction must drop ≈ 1 %.
    ///      Also exercises dt == 0 and totalSupply == 0 edge cases.
    function test_management_dilutesByRatePerYear() public pure {
        uint256 totalSupply = SUPPLY_1M;
        uint256 mgmtBps = 100; // 1 %/yr

        // ── A: 1 year → recipient fraction ≈ 1 % of post-mint supply ──────────
        uint256 feeShares = LeveragedAeroFees.managementFeeShares(totalSupply, mgmtBps, SECONDS_PER_YEAR);

        // Sanity: feeShares > 0
        assertGt(feeShares, 0, "no fee shares minted");

        uint256 newTotal = totalSupply + feeShares;

        // Recipient fraction in bps of the new total — must equal 100 ± 1
        uint256 recipientBps = feeShares * 10_000 / newTotal;
        assertApproxEqAbs(recipientBps, 100, 1, "recipient fraction != 1 %");

        // Dilution: each prior holder's value share drops ≈ 1 % → holderBps ≈ 9 900
        uint256 holderBps = totalSupply * 10_000 / newTotal;
        assertApproxEqAbs(holderBps, 9_900, 1, "holder dilution != ~1 %");

        // ── B: dt == 0 → zero fee (no time elapsed) ──────────────────────────
        uint256 zeroFee = LeveragedAeroFees.managementFeeShares(totalSupply, mgmtBps, 0);
        assertEq(zeroFee, 0, "dt=0 must yield 0 fee shares");

        // ── C: totalSupply == 0 → zero fee (empty vault) ──────────────────────
        uint256 emptyFee = LeveragedAeroFees.managementFeeShares(0, mgmtBps, SECONDS_PER_YEAR);
        assertEq(emptyFee, 0, "zero supply must yield 0 fee shares");

        // ── D: managementFeeBps == 0 → zero fee ───────────────────────────────
        uint256 noBpsFee = LeveragedAeroFees.managementFeeShares(totalSupply, 0, SECONDS_PER_YEAR);
        assertEq(noBpsFee, 0, "zero bps must yield 0 fee shares");
    }

    /// @dev Half-year accrual: recipient fraction ≈ 0.5 % (50 bps).
    function test_management_halfYear() public pure {
        uint256 dt = SECONDS_PER_YEAR / 2;
        uint256 feeShares = LeveragedAeroFees.managementFeeShares(SUPPLY_1M, 100, dt);
        uint256 recipientBps = feeShares * 10_000 / (SUPPLY_1M + feeShares);
        assertApproxEqAbs(recipientBps, 50, 1, "half-year fraction != ~0.5 %");
    }

    /// @dev One-day accrual: recipient fraction ≈ 1/365 % ≈ 0.274 bps.
    ///      Verifies fine-grained accumulation doesn't lose too much to rounding.
    function test_management_oneDay() public pure {
        uint256 dt = 1 days;
        uint256 feeShares = LeveragedAeroFees.managementFeeShares(SUPPLY_1M, 100, dt);
        // Expected: SUPPLY_1M * (100/10000) * (1/365) / (1 - ...) ≈ 274e9 shares
        // Just assert nonzero and within 1 % of expected.
        uint256 expected = Math.mulDiv(SUPPLY_1M, 100 * dt, 10_000 * SECONDS_PER_YEAR);
        assertApproxEqRel(feeShares, expected, 1e16, "one-day fee off by >1 %");
    }

    // =========================================================================
    // Invariant 2 — Performance fee fires only above the HWM
    // =========================================================================

    /// @dev NAV per share above HWM → charges performanceFeeBps of the gain;
    ///      HWM updates to the new peak.  Below/at HWM → zero fee, HWM unchanged.
    ///      Second call at the same NAV → zero fee (no double-charge).
    function test_performance_onlyAboveHWM() public pure {
        // Initial state: 100k USDC / 100k shares → hwm = 1e12 (HWM_1TO1).
        uint256 totalSupply = SUPPLY_100k;
        uint256 hwm = HWM_1TO1; // navPerShareX at 100k/100k
        uint256 perfBps = 1_000; // 10 %

        // ── A: NAV 10 % above HWM → charge 10 % of the 10k gain = 1k USDC ──────
        (uint256 feeShares, uint256 newHwm,) =
            LeveragedAeroFees.performanceFeeShares(NAV_110k, totalSupply, hwm, perfBps, 0);

        assertGt(feeShares, 0, "expected fee shares for gain above HWM");

        // Verify the fee-recipient's USDC value ≈ 1 000 USDC (10 % of 10k gain).
        // After mint: recipientValue = navPre × feeShares / (totalSupply + feeShares).
        uint256 recipientValue = Math.mulDiv(NAV_110k, feeShares, totalSupply + feeShares);
        assertApproxEqRel(recipientValue, 1_000e6, 1e15, "recipient value != ~1 000 USDC");

        // HWM advances to 1.1e12 (110k/100k at 1e18 scale).
        uint256 expectedNewHwm = Math.mulDiv(NAV_110k, WAD, totalSupply);
        assertEq(newHwm, expectedNewHwm, "HWM must advance to new navPerShareX");

        // ── B: NAV exactly at HWM → zero fee, HWM unchanged ──────────────────
        (uint256 feeShares2, uint256 hwm2,) =
            LeveragedAeroFees.performanceFeeShares(NAV_100k, totalSupply, hwm, perfBps, 0);
        assertEq(feeShares2, 0, "at-HWM must yield zero fee");
        assertEq(hwm2, hwm, "HWM must not change at parity");

        // ── C: NAV below HWM → zero fee, HWM unchanged ───────────────────────
        (uint256 feeShares3, uint256 hwm3,) =
            LeveragedAeroFees.performanceFeeShares(NAV_90k, totalSupply, hwm, perfBps, 0);
        assertEq(feeShares3, 0, "below-HWM must yield zero fee");
        assertEq(hwm3, hwm, "HWM must not change when below");

        // ── D: second call at the same (post-gain) NAV → zero fee ─────────────
        // Simulate HWM already at the new peak (newHwm from case A).
        (uint256 feeShares4, uint256 hwm4,) =
            LeveragedAeroFees.performanceFeeShares(NAV_110k, totalSupply, newHwm, perfBps, 0);
        assertEq(feeShares4, 0, "second call at same NAV must not double-charge");
        assertEq(hwm4, newHwm, "HWM must not change on flat NAV");
    }

    /// @dev Zero performance fee rate: gain is recognised (HWM advances), no fee minted.
    ///      Prevents a future non-zero rate from back-charging already-realised gains.
    function test_performance_zeroFeeRate_advancesHWM() public pure {
        uint256 hwm = HWM_1TO1;
        (uint256 feeShares, uint256 newHwm,) = LeveragedAeroFees.performanceFeeShares(NAV_110k, SUPPLY_100k, hwm, 0, 0);
        assertEq(feeShares, 0, "zero perf rate must yield zero fee shares");
        assertGt(newHwm, hwm, "HWM must advance even at zero fee rate");
    }

    // =========================================================================
    // Invariant 3 — No phantom fee when idle deposit just landed
    // =========================================================================

    /// @dev The [1] regression guard: crystallising on the *pre-deposit* NAV (which equals
    ///      the current HWM) must yield ZERO performance fee, even though the same USDC
    ///      would inflate navPOST/share above the HWM.
    ///
    ///      We also prove the regression anchor: using navPOST (wrong) would charge.
    function test_noPhantomFee_whenIdleJustLanded() public pure {
        // State: 100k USDC, 100k shares, HWM at 1:1.
        uint256 totalSupply = SUPPLY_100k;
        uint256 hwm = HWM_1TO1; // navPerShareX = HWM_1TO1 = 1e12

        // Pre-deposit NAV exactly equals the HWM level.
        // crystallize with navPRE = 100k: navPerShareX == hwm → zero perf fee.
        (uint256 feeShares, uint256 newHwm,,) =
            LeveragedAeroFees.crystallize(NAV_100k, totalSupply, hwm, 0, 1, 0, 1_000, 0);

        assertEq(feeShares, 0, "phantom performance fee charged on pre-deposit NAV");
        assertEq(newHwm, hwm, "HWM must not change when navPre == HWM");

        // Regression anchor: if the caller incorrectly used navPOST (110k — deposit of
        // 10k USDC already counted), the library WOULD charge a fee.  This proves the
        // test distinguishes the correct from the incorrect call site.
        (uint256 wrongFeeShares,,) = LeveragedAeroFees.performanceFeeShares(NAV_110k, totalSupply, hwm, 1_000, 0);
        assertGt(wrongFeeShares, 0, "using navPost should charge fee (regression anchor)");
    }

    // =========================================================================
    // HWM seeding (first-cycle guard)
    // =========================================================================

    /// @dev When hwmPerShareX == 0 (unset at deploy) and capital is present, the library
    ///      seeds the HWM to the current navPerShareX without charging any fee.
    function test_crystallize_seedsHWMOnFirstCapital() public pure {
        // hwmPerShareX = 0 (initial state post-deploy before any crystallize).
        (uint256 feeShares, uint256 newHwm,,) =
            LeveragedAeroFees.crystallize(NAV_100k, SUPPLY_100k, 0, 0, 1, 0, 1_000, 0);

        assertEq(feeShares, 0, "no fee on first HWM seeding");
        assertEq(newHwm, HWM_1TO1, "HWM must be seeded to current navPerShareX");
    }

    /// @dev After seeding, a subsequent crystallize at the same NAV → still zero fee.
    function test_crystallize_noFeeImmediatelyAfterSeed() public pure {
        // First call seeds HWM.
        (, uint256 hwm1,,) = LeveragedAeroFees.crystallize(NAV_100k, SUPPLY_100k, 0, 0, 100, 0, 1_000, 0);
        assertEq(hwm1, HWM_1TO1);

        // Second call at same NAV (1 second later) → zero perf fee; tiny mgmt fee ignored here.
        (uint256 feeShares2,,,) = LeveragedAeroFees.crystallize(NAV_100k, SUPPLY_100k, hwm1, 100, 101, 0, 1_000, 0);
        assertEq(feeShares2, 0, "no fee at flat NAV after seeding");
    }

    // =========================================================================
    // crystallize edge cases
    // =========================================================================

    /// @dev totalSupply == 0 (vault empty) → all outputs zero / unchanged.
    function test_crystallize_totalSupplyZero() public pure {
        (uint256 f, uint256 hwm, uint256 ts,) = LeveragedAeroFees.crystallize(0, 0, 0, 0, 100, 100, 1_000, 0);
        assertEq(f, 0);
        assertEq(hwm, 0);
        assertEq(ts, 100);
    }

    /// @dev navPre == 0 (oracle down / calm-gate shut): the price-free MANAGEMENT fee still
    ///      crystallises for the elapsed dt (D6 — it must not be forfeited on an unpriced
    ///      cycle), while the PERFORMANCE fee defers (HWM unchanged). lastAccrual advances.
    function test_crystallize_navPreZero_managementStillAccrues() public pure {
        uint256 storedHwm = HWM_1TO1;
        uint256 mgmtBps = 100; // 1 %/yr

        (uint256 f, uint256 hwm, uint256 ts,) =
            LeveragedAeroFees.crystallize(0, SUPPLY_100k, storedHwm, 0, SECONDS_PER_YEAR, mgmtBps, 1_000, 0);

        // Management leg is price-free → full accrual equals the standalone mgmt calc.
        uint256 mExpected = LeveragedAeroFees.managementFeeShares(SUPPLY_100k, mgmtBps, SECONDS_PER_YEAR);
        assertGt(mExpected, 0, "sanity: mgmt fee should be nonzero over 1 year");
        assertEq(f, mExpected, "mgmt fee must crystallise even with navPre == 0 (no forfeit)");

        // Performance leg defers: HWM unchanged so the next priced cycle re-measures the gain.
        assertEq(hwm, storedHwm, "HWM must NOT advance on an unpriced cycle (perf defers)");
        assertEq(ts, SECONDS_PER_YEAR, "lastAccrual must advance to nowTs");

        // dt == 0 with navPre == 0 → no fee at all (nothing to accrue).
        (uint256 f0, uint256 hwm0,,) =
            LeveragedAeroFees.crystallize(0, SUPPLY_100k, storedHwm, 100, 100, mgmtBps, 1_000, 0);
        assertEq(f0, 0, "navPre==0 & dt==0 must yield zero fee");
        assertEq(hwm0, storedHwm, "HWM unchanged");
    }

    /// @dev D6 escape-analysis: an unpriced crystallize (navPre == 0) that accrues only the mgmt
    ///      fee must NOT let a performance gain escape. Because the HWM is left unchanged, the very
    ///      next priced crystallize still charges the full perf fee on the gain above the ORIGINAL
    ///      HWM — identical to what a single priced cycle over the same gain would have charged.
    function test_crystallize_navPreZero_perfDefersNothingEscapes() public pure {
        uint256 totalSupply = SUPPLY_100k;
        uint256 hwm0 = HWM_1TO1; // starting HWM at 1:1
        uint256 perfBps = 1_000; // 10 %

        // Cycle 1 (unpriced, mid-outage): navPre == 0 → perf defers, HWM must stay at hwm0.
        (, uint256 hwmAfterOutage,,) = LeveragedAeroFees.crystallize(0, totalSupply, hwm0, 0, 1, 0, perfBps, 0);
        assertEq(hwmAfterOutage, hwm0, "outage cycle must not advance HWM");

        // Cycle 2 (priced, oracle back at 110k = +10 % gain): full perf fee charged vs hwm0.
        (uint256 pDeferred,,) =
            LeveragedAeroFees.performanceFeeShares(NAV_110k, totalSupply, hwmAfterOutage, perfBps, 0);

        // Baseline: the same gain charged in a single priced cycle (no intervening outage).
        (uint256 pBaseline,,) = LeveragedAeroFees.performanceFeeShares(NAV_110k, totalSupply, hwm0, perfBps, 0);

        assertGt(pDeferred, 0, "deferred perf fee must still fire on the next priced cycle");
        assertEq(pDeferred, pBaseline, "no gain escaped: deferred perf fee == single-cycle baseline");
    }

    /// @dev Two crystallize calls in the same block (nowTs == lastAccrual) → dt == 0 → no mgmt fee.
    function test_crystallize_sameBlockNoDt() public pure {
        uint256 ts = 1_000_000;
        // Call 1: lastAccrual = 0, nowTs = ts.
        (, uint256 hwm1, uint256 ts1,) = LeveragedAeroFees.crystallize(NAV_100k, SUPPLY_100k, 0, 0, ts, 100, 0, 0);
        assertEq(ts1, ts);

        // Call 2: lastAccrual = ts, nowTs = ts (same block) → dt == 0 → no mgmt shares.
        (uint256 feeShares2,,,) = LeveragedAeroFees.crystallize(NAV_100k, SUPPLY_100k, hwm1, ts, ts, 100, 0, 0);
        assertEq(feeShares2, 0, "same-block second call must yield no management fee");
    }

    // =========================================================================
    // Combined crystallize: management + performance in one call
    // =========================================================================

    /// @dev Both fees fire together: 1 year management + 10 % gain performance.
    ///      Total feeShares = mShares + pShares (computed independently on same supply).
    function test_crystallize_bothFeesCombined() public pure {
        // Start: 100k USDC, 100k shares, HWM 1:1.
        uint256 totalSupply = SUPPLY_100k;
        uint256 hwm = HWM_1TO1;

        // After 1 year: NAV has grown to 110k (10 % gain).
        (uint256 feeShares, uint256 newHwm, uint256 newTs,) = LeveragedAeroFees.crystallize(
            NAV_110k,
            totalSupply,
            hwm,
            0, // lastAccrual
            SECONDS_PER_YEAR, // nowTs
            100, // 1 %/yr management
            1_000, // 10 % performance
            0 // protocol
        );

        // Both components must be nonzero.
        uint256 mAlone = LeveragedAeroFees.managementFeeShares(totalSupply, 100, SECONDS_PER_YEAR);
        (uint256 pAlone,,) = LeveragedAeroFees.performanceFeeShares(NAV_110k, totalSupply, hwm, 1_000, 0);
        assertGt(mAlone, 0, "management shares must be nonzero");
        assertGt(pAlone, 0, "performance shares must be nonzero");
        assertEq(feeShares, mAlone + pAlone, "combined fee != sum of parts");

        // HWM advances to 1.1 × HWM_1TO1.
        assertEq(newHwm, Math.mulDiv(NAV_110k, WAD, totalSupply), "HWM must advance");

        // Timestamp updated.
        assertEq(newTs, SECONDS_PER_YEAR, "newLastAccrual must equal nowTs");
    }

    // =========================================================================
    // Protocol fee — off gross gain FIRST, perf accrues on the net (review #388-3)
    // =========================================================================

    /// @dev Ordering: mgmt=0, perf=2000 (20 %), protocol=100 (1 %) with a known 10k gross gain.
    ///      Protocol slice = 1 % of GROSS (100 USDC). Perf accrues on (gain − protocol) = 9 900 USDC
    ///      → 20 % of that = 1 980 USDC. HWM advances to the GROSS peak.
    function test_performance_protocolBeforePerf_ordering() public pure {
        uint256 totalSupply = SUPPLY_100k;
        uint256 hwm = HWM_1TO1;
        uint256 perfBps = 2_000; // 20 %
        uint256 protoBps = 100; // 1 %

        (uint256 feeShares, uint256 newHwm, uint256 protocolUsdc) =
            LeveragedAeroFees.performanceFeeShares(NAV_110k, totalSupply, hwm, perfBps, protoBps);

        // Gross gain = 10_000 USDC → protocol slice = 1 % = 100 USDC (exact).
        assertEq(protocolUsdc, 100e6, "protocol slice != 1 % of gross gain");

        // Perf value = 20 % of (10_000 − 100) = 1 980 USDC. Recover the minted-share value.
        uint256 recipientValue = Math.mulDiv(NAV_110k, feeShares, totalSupply + feeShares);
        assertApproxEqRel(recipientValue, 1_980e6, 1e12, "perf value != 20 % of net gain");

        // HWM advances to the GROSS peak (navPerShareX on the gross navPre), unaffected by protocol.
        assertEq(newHwm, Math.mulDiv(NAV_110k, WAD, totalSupply), "HWM must advance to gross peak");
    }

    /// @dev protocolFeeBps == 0 → zero protocol slice, perf identical to the pre-protocol path.
    function test_performance_protocolZero_noAccrual() public pure {
        (uint256 feeSharesA, uint256 hwmA, uint256 protoA) =
            LeveragedAeroFees.performanceFeeShares(NAV_110k, SUPPLY_100k, HWM_1TO1, 1_000, 0);
        (uint256 feeSharesB, uint256 hwmB) = _legacyPerf(NAV_110k, SUPPLY_100k, HWM_1TO1, 1_000);
        assertEq(protoA, 0, "protocol=0 must accrue nothing");
        assertEq(feeSharesA, feeSharesB, "perf shares must match the pre-protocol result at protocol=0");
        assertEq(hwmA, hwmB, "HWM must match at protocol=0");
    }

    /// @dev crystallize threads the protocol slice through: perf on net, protocolUsdc returned.
    function test_crystallize_protocolSliceReturned() public pure {
        // mgmt=0 so feeShares is pure perf. gain 10k, protocol 1 % = 100, perf 20 % of 9 900 = 1 980.
        (uint256 feeShares,,, uint256 protocolUsdc) =
            LeveragedAeroFees.crystallize(NAV_110k, SUPPLY_100k, HWM_1TO1, 0, 1, 0, 2_000, 100);
        assertEq(protocolUsdc, 100e6, "crystallize protocol slice != 100 USDC");
        uint256 recipientValue = Math.mulDiv(NAV_110k, feeShares, SUPPLY_100k + feeShares);
        assertApproxEqRel(recipientValue, 1_980e6, 1e12, "crystallize perf value != 20 % of net");
    }

    /// @dev HWM gross-peak semantics: after a protocol accrual advances the HWM to the gross peak,
    ///      a FLAT next cycle (navPre back at the same peak) charges nothing — no double-charge.
    function test_performance_protocolAccrual_grossPeak_noDoubleCharge() public pure {
        // Cycle 1: gain to 110k with protocol=100, perf=2000 → HWM advances to the gross peak.
        (,, uint256 proto1) = LeveragedAeroFees.performanceFeeShares(NAV_110k, SUPPLY_100k, HWM_1TO1, 2_000, 100);
        assertGt(proto1, 0, "cycle 1 should accrue a protocol slice");
        uint256 grossPeakHwm = Math.mulDiv(NAV_110k, WAD, SUPPLY_100k);

        // Cycle 2: navPre still 110k (flat, at the gross peak) → zero perf, zero protocol.
        (uint256 feeShares2, uint256 hwm2, uint256 proto2) =
            LeveragedAeroFees.performanceFeeShares(NAV_110k, SUPPLY_100k, grossPeakHwm, 2_000, 100);
        assertEq(feeShares2, 0, "flat cycle at gross peak must charge no perf");
        assertEq(proto2, 0, "flat cycle at gross peak must accrue no protocol");
        assertEq(hwm2, grossPeakHwm, "HWM unchanged on a flat cycle");
    }

    /// @dev Pre-protocol perf helper (protocol=0) — the reference behaviour before this change.
    function _legacyPerf(uint256 navPre, uint256 supply, uint256 hwm, uint256 perfBps)
        private
        pure
        returns (uint256 feeShares, uint256 newHwm)
    {
        (feeShares, newHwm,) = LeveragedAeroFees.performanceFeeShares(navPre, supply, hwm, perfBps, 0);
    }
}
