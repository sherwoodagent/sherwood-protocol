// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {LeveragedAerodromeCLStrategy} from "../src/strategies/LeveragedAerodromeCLStrategy.sol";
import {
    MockToken,
    MockGovernor,
    MockVaultPausableMint,
    MockCUsdcFunded,
    MockMarketZeroDebt,
    NavHarness
} from "./mocks/LeveragedAeroCLMocks.sol";

/// @title  LeveragedAeroCLReviewF13
/// @notice Regression tests for review #388 findings 1 and 3, both in `LeveragedAerodromeCLStrategy`:
///           F1 — `deposit` must revert `NavUnpriceable` when `nav()==0 && supply>0` (share-inflation
///                guard), yet still allow the legitimate first deposit (`supply==0`).
///           F3 — the fast-path `redeem` crystallise is best-effort (try/catch): a paused-vault /
///                de-whitelisted-recipient fee-mint revert must NOT brick the exit (fee simply defers).
contract LeveragedAeroCLReviewF13 is Test {
    uint256 private constant STRAT_BASE = uint256(0x405ae0b144079093e970849fdffdcb2a514e44968598c6c5c73444496e844900);
    uint256 private constant SLOT_USDC = STRAT_BASE + 0;
    uint256 private constant SLOT_MUSDC = STRAT_BASE + 1;
    uint256 private constant SLOT_MCBBTC = STRAT_BASE + 2;
    uint256 private constant SLOT_MWETH = STRAT_BASE + 3;
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

    /// @dev Pack feeRecipient (byte offset 10) into diamond slot 19 so the fee-mint targets it.
    function _setFeeRecipient(address t, address rec) private {
        vm.store(t, bytes32(STRAT_BASE + 19), bytes32(uint256(uint160(rec)) << 80));
    }

    // ═════════════════════════════════════════════════════════════════════════
    // FINDING 1 — deposit() nav()==0 share-inflation guard
    // ═════════════════════════════════════════════════════════════════════════

    /// @dev Flat book with `protocolFeeOwed > idleUSDC` → `nav()` floors to 0 while supply > 0.
    ///      Pre-fix this minted `~assets × (supply + offset)` shares (denominator collapses to 1),
    ///      diluting stayers. Post-fix `deposit` must revert `NavUnpriceable`.
    function test_deposit_navZero_supplyPositive_reverts() public {
        (NavHarness h, MockToken usdc,) = _depositFixture(100_000e12);

        uint256 idle = 1_000e6;
        usdc.mint(address(h), idle);
        _storeUint(address(h), SLOT_OWED, idle + 1); // owed > idle → nav() floors to 0
        assertEq(h.nav(), 0, "fixture must drive nav() to 0 with supply > 0");

        address dep = makeAddr("dep");
        uint256 a = 1_000e6;
        vm.mockCall(
            address(usdc),
            abi.encodeWithSignature("transferFrom(address,address,uint256)", dep, address(h), a),
            abi.encode(true)
        );

        vm.prank(dep);
        vm.expectRevert(LeveragedAerodromeCLStrategy.NavUnpriceable.selector);
        h.deposit(a, 0);
    }

    /// @dev The guard is correctly scoped to `supply > 0`: a legitimate FIRST deposit (`supply == 0`,
    ///      empty book → `nav()==0`) must STILL succeed, minting the bootstrap `assets × offset` shares.
    function test_deposit_navZero_firstDeposit_succeeds() public {
        (NavHarness h, MockToken usdc, MockVaultPausableMint vault) = _depositFixture(0); // supply == 0
        assertEq(vault.totalSupply(), 0, "fixture must start with empty supply");
        assertEq(h.nav(), 0, "empty book gives nav() == 0");

        address dep = makeAddr("first");
        uint256 a = 1_000e6;
        vm.mockCall(
            address(usdc),
            abi.encodeWithSignature("transferFrom(address,address,uint256)", dep, address(h), a),
            abi.encode(true)
        );

        vm.prank(dep);
        uint256 shares = h.deposit(a, 0);

        uint256 expected = Math.mulDiv(a, 0 + SHARES_VIRTUAL_OFFSET, 0 + 1); // bootstrap ratio
        assertEq(shares, expected, "first deposit must mint the bootstrap shares");
        assertEq(vault.balanceOf(dep), shares, "depositor not credited");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // FINDING 3 — fast-path redeem crystallise is best-effort (H3/§7)
    // ═════════════════════════════════════════════════════════════════════════

    /// @dev A paused vault (or de-whitelisted feeRecipient) makes the fee-share mint revert. The fast
    ///      redeem must still PROCEED — the crystallise rolls back (fee defers), the payout + burn go
    ///      through. Netting stays self-consistent: crystallise rollback leaves `protocolFeeOwed`
    ///      unchanged, so `navNet == navPre` and the pre-crystallise supply prices the payout.
    function test_fastRedeem_proceedsWhenFeeMintReverts() public {
        (NavHarness h, MockToken usdc, MockVaultPausableMint vault) = _redeemFixture();

        // A pending management + performance fee so crystallise WOULD mint fee-shares (which reverts).
        _setPerfFeeAndMgmt(address(h), 1000, 100);
        // Seed the HWM below current per-share so there is a real gain to crystallise a perf fee on.
        uint256 idle = 10_000e6;
        usdc.mint(address(h), idle);
        uint256 supply0 = vault.totalSupply();
        _storeUint(address(h), STRAT_BASE + 20, Math.mulDiv(5_000e6, 1e18, supply0)); // HWM well below nav
        _storeUint(address(h), SLOT_LAST_FEE, block.timestamp > 1 ? block.timestamp - 1 : 1); // dt > 0

        // Fund mUSDC so fastRedeemImpl can free the payout; zero debt → LTV gate passes.
        MockCUsdcFunded mUsdc = new MockCUsdcFunded(usdc, address(h), 1_000_000e6);
        _store(address(h), SLOT_MUSDC, address(mUsdc));

        // Pause the vault's mint → the fee-mint inside crystallise reverts.
        vault.setMintReverts(true);

        uint256 navPre = h.nav(); // 10_000e6 (owed 0)
        (address redeemer, uint256 shares) = _fundRedeemer(vault, h, "f3");
        uint256 expected = Math.mulDiv(shares, navPre, supply0); // navNet == navPre (fee deferred)

        vm.prank(redeemer);
        uint256 out = h.redeem(shares, 0); // must NOT brick

        assertEq(out, expected, "fast redeem must proceed at navPre when the fee-mint reverts");
        assertEq(usdc.balanceOf(redeemer), expected, "redeemer not paid");
        assertEq(vault.balanceOf(RECIPIENT), 0, "fee deferred, no fee-shares minted");
        assertEq(vault.totalSupply(), supply0 - shares, "escrowed shares not burned (only the redeemer's)");
        assertEq(h.layout().protocolFeeOwed, 0, "no protocol slice accrued (crystallise rolled back)");
    }

    /// @dev Control: with the SAME state but the mint NOT reverting, the redeem also succeeds — proving
    ///      the try/catch is transparent on the happy path (fee crystallises, exit proceeds).
    function test_fastRedeem_happyPath_stillCrystallises() public {
        (NavHarness h, MockToken usdc, MockVaultPausableMint vault) = _redeemFixture();
        _setPerfFeeAndMgmt(address(h), 1000, 100);
        uint256 idle = 10_000e6;
        usdc.mint(address(h), idle);
        uint256 supply0 = vault.totalSupply();
        _storeUint(address(h), STRAT_BASE + 20, Math.mulDiv(5_000e6, 1e18, supply0));
        _storeUint(address(h), SLOT_LAST_FEE, block.timestamp > 1 ? block.timestamp - 1 : 1);
        MockCUsdcFunded mUsdc = new MockCUsdcFunded(usdc, address(h), 1_000_000e6);
        _store(address(h), SLOT_MUSDC, address(mUsdc));

        (address redeemer, uint256 shares) = _fundRedeemer(vault, h, "f3ok");
        vm.prank(redeemer);
        uint256 out = h.redeem(shares, 0);

        assertGt(out, 0, "happy-path redeem paid out");
        assertGt(vault.balanceOf(RECIPIENT), 0, "fee-shares minted on the happy path (crystallise ran)");
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
        gov.setFee(1000, RECIPIENT); // protocol rate live so a slice could accrue (proves it does not)
        vault = new MockVaultPausableMint(address(gov), makeAddr("alice"), 100_000e12);
        MockMarketZeroDebt mCbBTC = new MockMarketZeroDebt();
        MockMarketZeroDebt mWeth = new MockMarketZeroDebt();

        _store(address(h), SLOT_VAULT, address(vault));
        vm.store(address(h), bytes32(SLOT_PROPOSER_STATE_INIT), bytes32(STATE_EXECUTED_INIT));
        _store(address(h), SLOT_USDC, address(usdc));
        _store(address(h), SLOT_MCBBTC, address(mCbBTC));
        _store(address(h), SLOT_MWETH, address(mWeth));
        _setFeeRecipient(address(h), RECIPIENT);
        _storeUint(address(h), SLOT_LAST_FEE, block.timestamp);
        // tokenId=0 (flat book) → fast path prices f×nav, funded from mUSDC collateral.
    }

    /// @dev Pack performanceFeeBps (bits 64-79) + managementFeeBps (bits 48-63) + feeRecipient
    ///      (bits 80-239) into diamond slot 19, preserving the RECIPIENT set by the fixture.
    function _setPerfFeeAndMgmt(address t, uint16 perfBps, uint16 mgmtBps) private {
        vm.store(
            t,
            bytes32(STRAT_BASE + 19),
            bytes32((uint256(mgmtBps) << 48) | (uint256(perfBps) << 64) | (uint256(uint160(RECIPIENT)) << 80))
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
