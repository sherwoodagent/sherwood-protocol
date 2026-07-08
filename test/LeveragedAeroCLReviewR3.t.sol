// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {LeveragedAerodromeCLStrategy} from "../src/strategies/LeveragedAerodromeCLStrategy.sol";
import {LeveragedAeroFees} from "../src/strategies/LeveragedAeroFees.sol";
import {
    MockToken,
    MockGovernor,
    MockVaultPausableMint,
    MockCUsdcFunded,
    MockMarketZeroDebt,
    NavHarness
} from "./mocks/LeveragedAeroCLMocks.sol";

/// @title  LeveragedAeroCLReviewR3
/// @notice Regression tests for review-round-3 findings in `LeveragedAerodromeCLStrategy`:
///           F1 — `deposit` must not brick on a whitelist/paused vault: the fee crystallise is
///                best-effort (try/catch → `FeeCrystallizeDeferred`) so a fee-MINT revert defers the
///                fee and the deposit proceeds; the down-oracle `nav()` revert stays OUTSIDE the catch.
///           F3 — `deposit` prices against the NET nav: the FRESH protocol slice the crystallise accrues
///                is subtracted from `navPre` and `supply` is read POST-crystallise, so the depositor is
///                not under-minted (the OLD ÷(navPre+1) formula minted strictly fewer shares).
///           F2 — fast `redeem` reverts `ZeroAssetsOut` (before pulling shares) when the payout floors
///                to 0 (navNet==0 with supply>0, OR a dust-share redeem) — no burn-for-zero.
///           F2-async — the async proportional redeem (`fulfillRedeem` / `emergencyRedeem`, both via
///                `_proportionalRedeem`) applies the SAME `ZeroAssetsOut` guard AFTER the protocol skim:
///                at navNet==0 (owed ≥ gross) the skim nets the payout to 0 with a stored `minOut == 0`,
///                so pre-fix the escrowed shares were burned for a 0 transfer. Post-fix it reverts, the
///                escrow stays intact, and the request is still recoverable via `cancelRedeem`.
contract LeveragedAeroCLReviewR3 is Test {
    uint256 private constant STRAT_BASE = uint256(0x405ae0b144079093e970849fdffdcb2a514e44968598c6c5c73444496e844900);
    uint256 private constant SLOT_USDC = STRAT_BASE + 0;
    uint256 private constant SLOT_MUSDC = STRAT_BASE + 1;
    uint256 private constant SLOT_MCBBTC = STRAT_BASE + 2;
    uint256 private constant SLOT_MWETH = STRAT_BASE + 3;
    uint256 private constant SLOT_CBBTC = STRAT_BASE + 4;
    uint256 private constant SLOT_WETH = STRAT_BASE + 5;
    uint256 private constant SLOT_HWM = STRAT_BASE + 20;
    uint256 private constant SLOT_LAST_FEE = STRAT_BASE + 21;
    uint256 private constant SLOT_OWED = STRAT_BASE + 22;

    uint256 private constant SLOT_VAULT = 1;
    uint256 private constant SLOT_PROPOSER_STATE_INIT = 2;
    uint256 private constant STATE_EXECUTED_INIT = (uint256(1) << 168) | (uint256(1) << 160);
    uint256 private constant SHARES_VIRTUAL_OFFSET = 1e6;

    address private constant RECIPIENT = address(0xFEE0);

    function _store(address t, uint256 slot, address a) private {
        vm.store(t, bytes32(slot), bytes32(uint256(uint160(a))));
    }

    function _storeUint(address t, uint256 slot, uint256 v) private {
        vm.store(t, bytes32(slot), bytes32(v));
    }

    /// @dev Pack performanceFeeBps (bits 64-79) + managementFeeBps (bits 48-63) + feeRecipient
    ///      (bits 80-239) into diamond slot 19.
    function _setPerfMgmtRecipient(address t, uint16 perfBps, uint16 mgmtBps, address rec) private {
        vm.store(
            t,
            bytes32(STRAT_BASE + 19),
            bytes32((uint256(mgmtBps) << 48) | (uint256(perfBps) << 64) | (uint256(uint160(rec)) << 80))
        );
    }

    // ═════════════════════════════════════════════════════════════════════════
    // FINDING 1 — deposit must not brick when the fee-mint reverts (whitelist / paused vault)
    // ═════════════════════════════════════════════════════════════════════════

    /// @dev A pending fee on a WHITELIST vault whose feeRecipient was never `approveDepositor`'d → the
    ///      fee mint (to RECIPIENT) reverts, but the depositor's own mint succeeds. Pre-fix `deposit`
    ///      called `_crystallizeFees` directly → the fee-mint revert bricked ALL deposits. Post-fix the
    ///      try/catch defers the fee (emits `FeeCrystallizeDeferred`) and the deposit PROCEEDS. Because
    ///      the crystallise rolled back, `owed` is unchanged → `navNet == navPre`, and the depositor is
    ///      credited the priced shares.
    function test_deposit_proceedsWhenFeeMintReverts_deferred() public {
        (NavHarness h, MockToken usdc, MockVaultPausableMint vault) = _depositFixture(100_000e12);

        // A pending management + performance fee so crystallise WOULD mint fee-shares (which reverts).
        _setPerfMgmtRecipient(address(h), 1000, 100, RECIPIENT);
        uint256 idle = 10_000e6;
        usdc.mint(address(h), idle);
        uint256 supply0 = vault.totalSupply();
        _storeUint(address(h), SLOT_HWM, Math.mulDiv(5_000e6, 1e18, supply0)); // HWM well below nav → gain
        _storeUint(address(h), SLOT_LAST_FEE, block.timestamp > 1 ? block.timestamp - 1 : 1); // dt > 0

        uint256 navPre = h.nav(); // 10_000e6 (owed 0)
        vault.blockMintTo(RECIPIENT); // feeRecipient not an approved depositor → the fee mint reverts

        address dep = makeAddr("dep");
        uint256 a = 1_000e6;
        vm.mockCall(
            address(usdc),
            abi.encodeWithSignature("transferFrom(address,address,uint256)", dep, address(h), a),
            abi.encode(true)
        );

        // Deposit must proceed and emit the deferral signal (fee rolled back) with op=OP_DEPOSIT (0) and
        // the at-risk navPre. Check-data on so the op code + navPre payload are asserted, not just the topic.
        vm.expectEmit(false, false, false, true, address(h));
        emit LeveragedAerodromeCLStrategy.FeeCrystallizeDeferred(0, navPre);
        vm.prank(dep);
        uint256 shares = h.deposit(a, 0);
        assertGt(navPre, 0, "deferred-op navPre must be nonzero (NAV at risk in the event payload)");

        // navNet == navPre (crystallise rolled back → owed unchanged), supply unchanged (no fee mint).
        uint256 expected = Math.mulDiv(a, supply0 + SHARES_VIRTUAL_OFFSET, navPre + 1);
        assertEq(shares, expected, "deposit must mint at navNet == navPre when the fee-mint reverts");
        assertEq(vault.balanceOf(dep), shares, "depositor not credited");
        assertEq(vault.balanceOf(RECIPIENT), 0, "fee deferred, no fee-shares minted");
        assertEq(vault.totalSupply(), supply0 + shares, "only the depositor's shares minted");
        assertEq(h.layout().protocolFeeOwed, 0, "no protocol slice accrued (crystallise rolled back)");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // FINDING 3 — deposit prices against the NET nav (fresh protocol slice netted, post-mint supply)
    // ═════════════════════════════════════════════════════════════════════════

    /// @dev With an uncrystallized gain above the HWM + protocolFeeBps > 0, the crystallise accrues a
    ///      FRESH protocol slice `p` AND mints perf-fee shares. Pricing must use `(navPre − p)` over the
    ///      POST-mint supply — else the depositor is under-minted by ~their share of `p`. Assert against
    ///      a hand-computed navNet from the pure fees lib, and that the OLD ÷(navPre+1) formula would
    ///      have minted STRICTLY FEWER shares (proves the fix direction).
    function test_deposit_pricesAgainstNetNav_notUnderMinted() public {
        (NavHarness h, MockToken usdc, MockVaultPausableMint vault) = _depositFixture(100_000e12);
        MockGovernor(vault.governor()).setFee(1000, RECIPIENT); // 10% protocol slice on gross gain
        _setPerfMgmtRecipient(address(h), 1000, 100, RECIPIENT); // 10% perf + 1%/yr mgmt

        uint256 idle = 110_000e6;
        usdc.mint(address(h), idle);
        uint256 supply0 = vault.totalSupply();
        uint256 hwm = Math.mulDiv(100_000e6, 1e18, supply0); // gain: nav 110k vs 100k basis
        _storeUint(address(h), SLOT_HWM, hwm);
        uint256 lastFee = block.timestamp > 1 ? block.timestamp - 1 : 1;
        _storeUint(address(h), SLOT_LAST_FEE, lastFee);

        uint256 navPre = h.nav(); // 110_000e6 (owed 0)

        // Mirror the crystallize with the pure lib (same inputs the strategy uses) to derive the fresh
        // slice + fee-share mint.
        uint256 ts = vm.getBlockTimestamp();
        (uint256 feeShares,,, uint256 freshSlice) =
            LeveragedAeroFees.crystallize(navPre, supply0, hwm, lastFee, ts, 100, 1000, 1000);
        assertGt(freshSlice, 0, "fixture must accrue a fresh protocol slice");
        assertGt(feeShares, 0, "fixture must mint perf-fee shares");

        address dep = makeAddr("dep3");
        uint256 a = 1_000e6;
        vm.mockCall(
            address(usdc),
            abi.encodeWithSignature("transferFrom(address,address,uint256)", dep, address(h), a),
            abi.encode(true)
        );

        vm.prank(dep);
        uint256 shares = h.deposit(a, 0);

        uint256 navNet = navPre - freshSlice;
        uint256 expected = Math.mulDiv(a, (supply0 + feeShares) + SHARES_VIRTUAL_OFFSET, navNet + 1);
        assertEq(shares, expected, "deposit must price against net nav over the post-mint supply");
        assertEq(vault.balanceOf(dep), shares, "depositor not credited");

        // The OLD (buggy) formula: ÷(navPre+1) with the same post-mint supply → strictly FEWER shares
        // (larger denominator un-netted). Proves the fix mints MORE, not fewer.
        uint256 oldShares = Math.mulDiv(a, (supply0 + feeShares) + SHARES_VIRTUAL_OFFSET, navPre + 1);
        assertLt(oldShares, shares, "old un-netted formula must have under-minted");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // FINDING 2 — fast redeem rejects a burn-for-zero (navNet==0 OR dust shares)
    // ═════════════════════════════════════════════════════════════════════════

    /// @dev `protocolFeeOwed ≥ gross book` → `nav()` (and `navNet`) floor to 0 with supply > 0. A fast
    ///      redeem at minAssetsOut=0 would pull + burn shares for a 0 payout. Post-fix it reverts
    ///      `ZeroAssetsOut` BEFORE the share pull → shares NOT burned, escrow untouched.
    function test_fastRedeem_navZero_revertsZeroAssetsOut_noBurn() public {
        (NavHarness h, MockToken usdc, MockVaultPausableMint vault) = _redeemFixture();

        uint256 idle = 1_000e6;
        usdc.mint(address(h), idle);
        _storeUint(address(h), SLOT_OWED, idle + 1); // owed > idle → nav() / navNet floor to 0
        assertEq(h.nav(), 0, "fixture must drive nav() to 0 with supply > 0");

        (address redeemer, uint256 shares) = _fundRedeemer(vault, h, "z1");
        uint256 supplyBefore = vault.totalSupply();

        vm.prank(redeemer);
        vm.expectRevert(LeveragedAerodromeCLStrategy.ZeroAssetsOut.selector);
        h.redeem(shares, 0);

        assertEq(vault.totalSupply(), supplyBefore, "no shares burned on the reverted redeem");
        assertEq(vault.balanceOf(redeemer), shares, "redeemer's shares not pulled");
        assertEq(vault.balanceOf(address(h)), 0, "strategy holds no escrow");
    }

    /// @dev A dust-share redeem that floors to 0 (`shares × navNet / supply == 0`) also reverts
    ///      `ZeroAssetsOut` — the guard doubles as a dust-redeem reject. Here navNet == 5_000e6,
    ///      supply == 100_000e12; one wei of shares rounds down to 0 assets.
    function test_fastRedeem_dustShares_revertsZeroAssetsOut() public {
        (NavHarness h, MockToken usdc, MockVaultPausableMint vault) = _redeemFixture();
        usdc.mint(address(h), 5_000e6); // navNet == 5_000e6, owed 0
        uint256 supply = vault.totalSupply(); // 100_000e12
        // 1 wei of shares: 1 * 5_000e6 / 100_000e12 == 0 (floors).
        assertEq(Math.mulDiv(1, 5_000e6, supply), 0, "fixture must floor dust shares to 0 assets");

        address dust = makeAddr("dust");
        vm.prank(makeAddr("alice"));
        vault.transfer(dust, 1);
        vm.prank(dust);
        vault.approve(address(h), 1);

        vm.prank(dust);
        vm.expectRevert(LeveragedAerodromeCLStrategy.ZeroAssetsOut.selector);
        h.redeem(1, 0);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // FINDING 4 — previewRedeem simulates the pending crystallise (== executed payout to the wei)
    // ═════════════════════════════════════════════════════════════════════════

    /// @dev MONEY ASSERT: with a pending perf + protocol fee (real gain above the HWM), `previewRedeem`
    ///      must equal the EXACT `assetsOut` the subsequent `redeem(shares, preview)` pays — the executed
    ///      path crystallises first (perf-fee mint dilutes supply, fresh protocol slice nets out of nav),
    ///      so a preview priced on the LIVE nav/supply would over-quote and the preview-as-`minAssetsOut`
    ///      would `InsufficientAssetsOut`. Post-fix the preview simulates that crystallise → exact equality
    ///      → the redeem clears its own preview as the floor. Idle-covered (idle > navNet) so no LTV read.
    function test_previewRedeem_matchesExecuted_pendingFee() public {
        (NavHarness h, MockToken usdc, MockVaultPausableMint vault) = _redeemFixture();
        _setPerfMgmtRecipient(address(h), 1000, 100, RECIPIENT); // 10% perf + 1%/yr mgmt

        uint256 idle = 10_000e6;
        usdc.mint(address(h), idle); // navPre == 10_000e6 (owed 0), idle > navNet → fully idle-funded
        uint256 supply = vault.totalSupply();
        _storeUint(address(h), SLOT_HWM, Math.mulDiv(5_000e6, 1e18, supply)); // HWM below nav → gain
        uint256 lastFee = block.timestamp > 1 ? block.timestamp - 1 : 1;
        _storeUint(address(h), SLOT_LAST_FEE, lastFee); // dt > 0 → mgmt fee too

        // Sanity: a fee is genuinely pending (else this test would trivially pass).
        (uint256 feeShares,,, uint256 freshSlice) = LeveragedAeroFees.crystallize(
            h.nav(), supply, Math.mulDiv(5_000e6, 1e18, supply), lastFee, vm.getBlockTimestamp(), 100, 1000, 1000
        );
        assertGt(feeShares, 0, "fixture must have a pending perf-fee mint");
        assertGt(freshSlice, 0, "fixture must have a pending protocol slice");

        (address redeemer, uint256 shares) = _fundRedeemer(vault, h, "f4");
        (uint256 preview, bool fastOk) = h.previewRedeem(shares);
        assertGt(preview, 0, "preview must quote a payout");
        assertTrue(fastOk, "idle-covered redeem clears the gate");

        // The preview used AS minAssetsOut must NOT bounce, and the payout must equal it to the wei.
        vm.prank(redeemer);
        uint256 out = h.redeem(shares, preview);
        assertEq(out, preview, "executed payout != preview (view/exec drift)");
    }

    /// @dev STRUCTURAL DEDUP (Part A): after `previewRedeem` was rewired through the shared
    ///      `_simulateCrystallize` marshalling (the F4-desync killer), the quote must still equal a
    ///      payout independently reconstructed from the pure fees lib — i.e. the refactor is
    ///      behaviour-preserving, deriving `(navNet, supplyPost)` from the SAME 8-arg call as
    ///      `_crystallizeFees`. Idle-covered so the LTV branch is a clean pass.
    function test_previewRedeem_simulateCrystallize_matchesLibDerivation() public {
        (NavHarness h, MockToken usdc, MockVaultPausableMint vault) = _redeemFixture();
        _setPerfMgmtRecipient(address(h), 1000, 100, RECIPIENT); // 10% perf + 1%/yr mgmt

        uint256 idle = 10_000e6;
        usdc.mint(address(h), idle);
        uint256 supply = vault.totalSupply();
        uint256 hwm = Math.mulDiv(5_000e6, 1e18, supply); // HWM below nav → gain
        _storeUint(address(h), SLOT_HWM, hwm);
        uint256 lastFee = block.timestamp > 1 ? block.timestamp - 1 : 1;
        _storeUint(address(h), SLOT_LAST_FEE, lastFee);

        uint256 navPre = h.nav();
        // Independent (navNet, supplyPost) from the pure lib — the contract's `_simulateCrystallize`
        // MUST marshal the identical inputs (protocol rate 1000 from the fixture governor).
        (uint256 feeShares,,, uint256 freshSlice) =
            LeveragedAeroFees.crystallize(navPre, supply, hwm, lastFee, vm.getBlockTimestamp(), 100, 1000, 1000);
        assertGt(feeShares, 0, "fixture must mint perf-fee shares");
        assertGt(freshSlice, 0, "fixture must accrue a fresh protocol slice");

        (address redeemer, uint256 shares) = _fundRedeemer(vault, h, "f4sim");
        (uint256 preview,) = h.previewRedeem(shares);

        uint256 expected = Math.mulDiv(shares, navPre - freshSlice, supply + feeShares);
        assertEq(preview, expected, "preview must equal the shared-marshalling lib derivation");
        // And it clears execution to the wei (the dedup didn't drift the money path).
        vm.prank(redeemer);
        assertEq(h.redeem(shares, preview), preview, "executed payout != refactored preview");
    }

    /// @dev Safe-direction edge: when the executed crystallise DEFERS (feeRecipient un-whitelisted → the
    ///      fee mint reverts, H3), the actual payout is MORE than the fee-adjusted preview (no dilution,
    ///      no fresh slice) — so a preview-derived `minAssetsOut` still clears. `actual ≥ preview`.
    function test_previewRedeem_executedDefers_paysAtLeastPreview() public {
        (NavHarness h, MockToken usdc, MockVaultPausableMint vault) = _redeemFixture();
        _setPerfMgmtRecipient(address(h), 1000, 100, RECIPIENT);

        uint256 idle = 10_000e6;
        usdc.mint(address(h), idle);
        uint256 supply = vault.totalSupply();
        _storeUint(address(h), SLOT_HWM, Math.mulDiv(5_000e6, 1e18, supply));
        _storeUint(address(h), SLOT_LAST_FEE, block.timestamp > 1 ? block.timestamp - 1 : 1);

        (address redeemer, uint256 shares) = _fundRedeemer(vault, h, "f4d");
        (uint256 preview,) = h.previewRedeem(shares); // simulates the crystallise (fee-adjusted)

        vault.blockMintTo(RECIPIENT); // executed crystallise's fee mint reverts → defers → no dilution/slice
        vm.prank(redeemer);
        uint256 out = h.redeem(shares, preview); // preview as floor must still clear
        assertGe(out, preview, "deferred crystallise must pay >= the fee-adjusted preview");
        // And strictly more here (the deferral drops the dilution + slice that the preview priced in).
        assertGt(out, preview, "deferral pays strictly more than the fee-adjusted preview");
    }

    /// @dev navNet == 0 (owed >= gross book) → `previewRedeem` returns `(0, false)`, matching the executed
    ///      `redeem`'s `ZeroAssetsOut` revert — the preview never quotes a payout the exec path rejects.
    function test_previewRedeem_navZero_returnsZeroFalse() public {
        (NavHarness h, MockToken usdc, MockVaultPausableMint vault) = _redeemFixture();
        uint256 idle = 1_000e6;
        usdc.mint(address(h), idle);
        _storeUint(address(h), SLOT_OWED, idle + 1); // owed > idle → nav()/navNet floor to 0
        assertEq(h.nav(), 0, "fixture must drive nav() to 0");

        (address redeemer, uint256 shares) = _fundRedeemer(vault, h, "f4z");
        (uint256 preview, bool fastOk) = h.previewRedeem(shares);
        assertEq(preview, 0, "navZero preview must be 0");
        assertFalse(fastOk, "navZero preview must flag fastOk == false");

        // The executed path reverts ZeroAssetsOut on the same state → the preview correctly pre-routes away.
        vm.prank(redeemer);
        vm.expectRevert(LeveragedAerodromeCLStrategy.ZeroAssetsOut.selector);
        h.redeem(shares, 0);
    }

    /// @dev No pending fee (`dt == 0` at the last accrual AND nav at the HWM) → the simulated crystallise
    ///      is a no-op, so the preview equals the plain `f × nav` (pre-fix behaviour) AND the executed
    ///      payout — proving the fee simulation adds nothing when there's nothing to crystallise.
    function test_previewRedeem_noPendingFee_unchanged() public {
        (NavHarness h, MockToken usdc, MockVaultPausableMint vault) = _redeemFixture();
        _setPerfMgmtRecipient(address(h), 1000, 100, RECIPIENT);

        uint256 idle = 10_000e6;
        usdc.mint(address(h), idle);
        uint256 supply = vault.totalSupply();
        _storeUint(address(h), SLOT_HWM, Math.mulDiv(idle, 1e18, supply)); // HWM == nav-per-share → no gain
        _storeUint(address(h), SLOT_LAST_FEE, block.timestamp); // dt == 0 → no mgmt fee

        (address redeemer, uint256 shares) = _fundRedeemer(vault, h, "f4n");
        (uint256 preview, bool fastOk) = h.previewRedeem(shares);
        assertTrue(fastOk, "idle-covered redeem clears the gate");
        // Plain f × nav (no fee adjustment).
        assertEq(preview, Math.mulDiv(shares, h.nav(), supply), "no-fee preview must equal plain f * nav");

        vm.prank(redeemer);
        uint256 out = h.redeem(shares, preview);
        assertEq(out, preview, "no-fee executed payout != preview");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // FINDING 2-async — async proportional redeem rejects a burn-for-zero (navNet==0)
    // ═════════════════════════════════════════════════════════════════════════

    /// @dev `protocolFeeOwed ≥ gross book` → the async unwind pays f×idle GROSS, then the Item-3 skim
    ///      (`f×owed` capped at assetsOut) nets the payout to exactly 0. With the request's stored
    ///      `minAssetsOut == 0` the pre-fix `< minOut` check fell through → burn-for-zero. Post-fix
    ///      `fulfillRedeem` reverts `ZeroAssetsOut`, the escrowed shares are NOT burned, and the owner
    ///      recovers them via `cancelRedeem`.
    function test_asyncFulfill_navZero_revertsZeroAssetsOut_recoverable() public {
        (NavHarness h, MockToken usdc, MockVaultPausableMint vault) = _asyncRedeemFixture();

        uint256 idle = 1_000e6;
        usdc.mint(address(h), idle);
        _storeUint(address(h), SLOT_OWED, idle + 1); // owed > idle → gross ≤ owed → skim nets payout to 0
        assertEq(h.nav(), 0, "fixture must drive nav() to 0 with supply > 0");

        (address owner, uint256 shares) = _fundRedeemer(vault, h, "af0");
        vm.prank(owner);
        uint256 id = h.requestRedeem(shares, 0); // stored minAssetsOut == 0 (the burn-for-zero trigger)
        assertEq(vault.balanceOf(address(h)), shares, "shares escrowed in the strategy");

        uint256 supplyBefore = vault.totalSupply();
        vm.prank(address(this)); // proposer == deployer (STATE_EXECUTED_INIT stores this)
        vm.expectRevert(LeveragedAerodromeCLStrategy.ZeroAssetsOut.selector);
        h.fulfillRedeem(id);

        // Escrow intact — nothing burned, request not settled.
        assertEq(vault.totalSupply(), supplyBefore, "no shares burned on the reverted fulfill");
        assertEq(vault.balanceOf(address(h)), shares, "escrow untouched");
        assertFalse(h.redeemRequest(id).settled, "request must remain unsettled");

        // Owner recovers the escrow via cancelRedeem (no State/navNet gate).
        vm.prank(owner);
        h.cancelRedeem(id);
        assertEq(vault.balanceOf(owner), shares, "owner recovers the escrowed shares");
        assertEq(vault.balanceOf(address(h)), 0, "strategy holds no escrow after cancel");
        assertTrue(h.redeemRequest(id).settled, "request settled after cancel");
    }

    /// @dev `emergencyRedeem` (the permissionless deadman, owner-gated) routes through the same
    ///      `_proportionalRedeem` — so it reverts `ZeroAssetsOut` at navNet==0 too, leaving the escrow
    ///      intact. Reverting is NOT a stuck state: the shares stay escrowed and `cancelRedeem` recovers
    ///      them (asserted in the fulfill test above).
    function test_asyncEmergency_navZero_revertsZeroAssetsOut_escrowIntact() public {
        (NavHarness h, MockToken usdc, MockVaultPausableMint vault) = _asyncRedeemFixture();

        uint256 idle = 1_000e6;
        usdc.mint(address(h), idle);
        _storeUint(address(h), SLOT_OWED, idle + 1);

        (address owner, uint256 shares) = _fundRedeemer(vault, h, "ae0");
        vm.prank(owner);
        uint256 id = h.requestRedeem(shares, 0);

        vm.warp(vm.getBlockTimestamp() + 2 days + 1); // past FULFILL_WINDOW → deadman reachable
        uint256 supplyBefore = vault.totalSupply();
        vm.prank(owner);
        vm.expectRevert(LeveragedAerodromeCLStrategy.ZeroAssetsOut.selector);
        h.emergencyRedeem(id, 0);

        assertEq(vault.totalSupply(), supplyBefore, "no shares burned on the reverted emergencyRedeem");
        assertEq(vault.balanceOf(address(h)), shares, "escrow untouched");
        assertFalse(h.redeemRequest(id).settled, "request must remain unsettled");
    }

    /// @dev Control: a normal async fulfill at a NONZERO navNet still pays out and burns the escrow —
    ///      the new guard only fires on an exact-0 payout. navNet == idle (owed 0), f = 1/2 → pays f×idle.
    function test_asyncFulfill_nonzeroNav_succeeds() public {
        (NavHarness h, MockToken usdc, MockVaultPausableMint vault) = _asyncRedeemFixture();

        uint256 idle = 1_000e6;
        usdc.mint(address(h), idle); // navNet == 1_000e6 (owed 0)
        assertEq(h.nav(), idle, "fixture must have a nonzero nav");

        (address owner, uint256 shares) = _fundRedeemer(vault, h, "an0"); // f = shares/supply = 1/2
        uint256 supply = vault.totalSupply();
        uint256 expected = Math.mulDiv(idle, shares, supply); // f × idle, oracle-free unwind
        assertGt(expected, 0, "control must pay out");

        vm.prank(owner);
        uint256 id = h.requestRedeem(shares, 0);
        uint256 supplyBefore = vault.totalSupply();

        vm.prank(address(this)); // proposer
        h.fulfillRedeem(id);

        assertEq(usdc.balanceOf(owner), expected, "owner paid f * idle");
        assertEq(vault.totalSupply(), supplyBefore - shares, "escrowed shares burned on fulfill");
        assertEq(vault.balanceOf(address(h)), 0, "no escrow remains");
        assertTrue(h.redeemRequest(id).settled, "request settled after fulfill");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Control — normal deposit + fast-redeem round-trip unchanged
    // ═════════════════════════════════════════════════════════════════════════

    /// @dev No pending fee, live oracle, healthy book: deposit prices at `navNet == navPre` (no fresh
    ///      slice) and a subsequent fast redeem pays `f × nav`, both unchanged by the fix.
    function test_control_depositRedeemRoundTrip_unchanged() public {
        (NavHarness h, MockToken usdc, MockVaultPausableMint vault) = _redeemFixture();

        uint256 idle = 10_000e6;
        usdc.mint(address(h), idle);
        uint256 supply0 = vault.totalSupply();
        MockCUsdcFunded mUsdc = new MockCUsdcFunded(usdc, address(h), 1_000_000e6);
        _store(address(h), SLOT_MUSDC, address(mUsdc));

        // Deposit: no fee wired → navNet == navPre, supply unchanged by crystallise.
        address dep = makeAddr("ctrl");
        uint256 a = 1_000e6;
        uint256 navPre = h.nav();
        vm.mockCall(
            address(usdc),
            abi.encodeWithSignature("transferFrom(address,address,uint256)", dep, address(h), a),
            abi.encode(true)
        );
        vm.prank(dep);
        uint256 shares = h.deposit(a, 0);
        assertEq(shares, Math.mulDiv(a, supply0 + SHARES_VIRTUAL_OFFSET, navPre + 1), "control deposit shares");

        // Fast redeem of half the original supply pays f × nav.
        (address redeemer, uint256 rShares) = _fundRedeemer(vault, h, "ctrlR");
        uint256 supplyNow = vault.totalSupply();
        uint256 navNow = h.nav();
        uint256 expected = Math.mulDiv(rShares, navNow, supplyNow);
        assertGt(expected, 0, "control redeem must pay out");

        vm.prank(redeemer);
        uint256 out = h.redeem(rShares, 0);
        assertEq(out, expected, "control fast redeem pays f * nav");
        assertEq(usdc.balanceOf(redeemer), expected, "redeemer not paid");
        assertEq(vault.totalSupply(), supplyNow - rShares, "only the redeemer's shares burned");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Fixtures
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Flat-book deposit fixture with a configurable initial supply (0 → first-deposit case).
    function _depositFixture(uint256 initialShares)
        private
        returns (NavHarness h, MockToken usdc, MockVaultPausableMint vault)
    {
        h = new NavHarness();
        usdc = new MockToken("USDC");
        MockGovernor gov = new MockGovernor();
        address holder = initialShares == 0 ? address(0) : makeAddr("alice");
        vault = new MockVaultPausableMint(address(gov), holder, initialShares);

        _store(address(h), SLOT_VAULT, address(vault));
        vm.store(address(h), bytes32(SLOT_PROPOSER_STATE_INIT), bytes32(STATE_EXECUTED_INIT));
        _store(address(h), SLOT_USDC, address(usdc));
        _storeUint(address(h), SLOT_LAST_FEE, block.timestamp);
        // tokenId defaults to 0 (flat book) → nav() = idle − owed, floored at 0.
    }

    /// @dev Flat-book redeem fixture: zero-debt Moonwell markets + funded feeRecipient wiring.
    function _redeemFixture() private returns (NavHarness h, MockToken usdc, MockVaultPausableMint vault) {
        h = new NavHarness();
        usdc = new MockToken("USDC");
        MockGovernor gov = new MockGovernor();
        gov.setFee(1000, RECIPIENT); // protocol rate live (proves the fast path takes no skim)
        vault = new MockVaultPausableMint(address(gov), makeAddr("alice"), 100_000e12);
        MockMarketZeroDebt mCbBTC = new MockMarketZeroDebt();
        MockMarketZeroDebt mWeth = new MockMarketZeroDebt();

        _store(address(h), SLOT_VAULT, address(vault));
        vm.store(address(h), bytes32(SLOT_PROPOSER_STATE_INIT), bytes32(STATE_EXECUTED_INIT));
        _store(address(h), SLOT_USDC, address(usdc));
        _store(address(h), SLOT_MCBBTC, address(mCbBTC));
        _store(address(h), SLOT_MWETH, address(mWeth));
        _storeUint(address(h), SLOT_LAST_FEE, block.timestamp);
        // tokenId=0 (flat book) → fast path prices f×nav, funded from mUSDC collateral.
    }

    /// @dev Async-redeem fixture: the flat-book redeem wiring PLUS zero-balance cbBTC / WETH tokens and a
    ///      zero-collateral mUSDC — so `redeemUnwindImpl`'s leg reservation (`_stayerLeg`), residual sweep
    ///      (`_sweepLegToUsdc`) and collateral redeem (`_redeemCollateral`) are clean no-ops on the flat
    ///      book (they'd otherwise `balanceOf` an unset address(0) slot and revert). The unwind then
    ///      returns the redeemer's f×idle share, which the Item-3 skim nets against `protocolFeeOwed`.
    function _asyncRedeemFixture() private returns (NavHarness h, MockToken usdc, MockVaultPausableMint vault) {
        (h, usdc, vault) = _redeemFixture();
        MockToken cbBTC = new MockToken("cbBTC");
        MockToken weth = new MockToken("WETH");
        MockCUsdcFunded mUsdc = new MockCUsdcFunded(usdc, address(h), 0); // zero collateral → redeem no-op
        _store(address(h), SLOT_CBBTC, address(cbBTC));
        _store(address(h), SLOT_WETH, address(weth));
        _store(address(h), SLOT_MUSDC, address(mUsdc));
        // Set `_proposer` to this test (slot 2 low 160 bits) while keeping `_state == Executed`
        // (bit 160) + `_initialized` (bit 168) — so `fulfillRedeem`'s `onlyProposer` accepts it.
        vm.store(
            address(h),
            bytes32(SLOT_PROPOSER_STATE_INIT),
            bytes32(uint256(uint160(address(this))) | STATE_EXECUTED_INIT)
        );
    }

    /// @dev Give the redeemer HALF the supply (f = 1/2) without changing totalSupply, then approve.
    function _fundRedeemer(MockVaultPausableMint vault, NavHarness h, string memory label)
        private
        returns (address redeemer, uint256 shares)
    {
        redeemer = makeAddr(label);
        shares = 50_000e12;
        vm.prank(makeAddr("alice"));
        vault.approve(address(this), shares);
        vault.transferFrom(makeAddr("alice"), redeemer, shares);
        vm.prank(redeemer);
        vault.approve(address(h), shares);
    }
}
