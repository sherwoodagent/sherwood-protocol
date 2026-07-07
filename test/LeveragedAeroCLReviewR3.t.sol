// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {LeveragedAerodromeCLStrategy} from "../src/strategies/LeveragedAerodromeCLStrategy.sol";
import {LeveragedAeroFees} from "../src/strategies/LeveragedAeroFees.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Minimal ERC-20 (test mint/burn) + governor mock — self-contained for this file.
// ─────────────────────────────────────────────────────────────────────────────
contract MockToken {
    string public name;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    constructor(string memory n) {
        name = n;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function burn(address from, uint256 amt) external {
        balanceOf[from] -= amt;
        totalSupply -= amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract MockGovernor {
    uint256 public protocolFeeBps;
    address public protocolFeeRecipient;

    function setFee(uint256 bps, address recipient) external {
        protocolFeeBps = bps;
        protocolFeeRecipient = recipient;
    }
}

/// @dev Vault modelling a WHITELIST (or paused) mint gate at the granularity of the real bug: a
///      `strategyMint` to a NON-whitelisted `to` reverts (`_requireApprovedDepositor` / `whenNotPaused`).
///      The finding is that the FEE mint (to a feeRecipient never `approveDepositor`'d) reverts while
///      the depositor's own mint succeeds — so the gate is per-`to`, not a blanket flag. `strategyBurn`
///      always succeeds (the real vault's burn is NOT `whenNotPaused`, so exits survive a pause).
contract MockVaultPausableMint {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool) public mintBlocked; // to => fee-mint reverts (un-whitelisted recipient)
    uint256 public totalSupply;
    address public governor;

    constructor(address gov, address holder, uint256 shares) {
        governor = gov;
        balanceOf[holder] = shares;
        totalSupply = shares;
    }

    /// @dev Block `strategyMint(to, …)` — models `to` not being an approved depositor.
    function blockMintTo(address to) external {
        mintBlocked[to] = true;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        allowance[from][msg.sender] -= amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function strategyMint(address to, uint256 shares) external {
        require(!mintBlocked[to], "NOT_APPROVED_DEPOSITOR");
        balanceOf[to] += shares;
        totalSupply += shares;
    }

    function strategyBurn(uint256 shares) external {
        balanceOf[msg.sender] -= shares;
        totalSupply -= shares;
    }
}

/// @dev mUSDC that funds the fast-path payout: `redeemUnderlying(amt)` burns `amt` face and delivers
///      `amt` USDC to the strategy. `cBal` = collateral face (must exceed the payout for the LTV gate).
contract MockCUsdcFunded {
    MockToken public usdc;
    address public strategy;
    uint256 public cBal;

    constructor(MockToken u, address s, uint256 c) {
        usdc = u;
        strategy = s;
        cBal = c;
    }

    function balanceOf(address) external view returns (uint256) {
        return cBal;
    }

    function exchangeRateStored() external pure returns (uint256) {
        return 1e18;
    }

    function redeemUnderlying(uint256 amt) external returns (uint256) {
        cBal -= amt;
        usdc.mint(strategy, amt);
        return 0;
    }
}

contract MockMarketZeroDebt {
    function borrowBalanceStored(address) external pure returns (uint256) {
        return 0;
    }
}

/// @dev Real-`nav()` harness (no override) → exercises the on-chain flat-book branch.
contract NavHarness is LeveragedAerodromeCLStrategy {}

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
contract LeveragedAeroCLReviewR3 is Test {
    uint256 private constant STRAT_BASE = uint256(0x405ae0b144079093e970849fdffdcb2a514e44968598c6c5c73444496e844900);
    uint256 private constant SLOT_USDC = STRAT_BASE + 0;
    uint256 private constant SLOT_MUSDC = STRAT_BASE + 1;
    uint256 private constant SLOT_MCBBTC = STRAT_BASE + 2;
    uint256 private constant SLOT_MWETH = STRAT_BASE + 3;
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

        // Deposit must proceed and emit the deferral signal (fee rolled back).
        vm.expectEmit(false, false, false, false, address(h));
        emit LeveragedAerodromeCLStrategy.FeeCrystallizeDeferred();
        vm.prank(dep);
        uint256 shares = h.deposit(a, 0);

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
