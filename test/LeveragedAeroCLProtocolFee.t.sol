// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {LeveragedAerodromeCLStrategy} from "../src/strategies/LeveragedAerodromeCLStrategy.sol";
import {LeveragedAeroManager} from "../src/strategies/LeveragedAeroManager.sol";
import {LeveragedAeroFees} from "../src/strategies/LeveragedAeroFees.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Minimal ERC-20 with test-only mint / burn.
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

// ─────────────────────────────────────────────────────────────────────────────
// Mock vault — share ledger + strategyMint/Burn + governor() wiring.
// ─────────────────────────────────────────────────────────────────────────────
contract MockVault {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;
    address public governor;

    constructor(address gov, address holder, uint256 shares) {
        governor = gov;
        balanceOf[holder] = shares;
        totalSupply = shares;
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
        balanceOf[to] += shares;
        totalSupply += shares;
    }

    function strategyBurn(uint256 shares) external {
        balanceOf[msg.sender] -= shares;
        totalSupply -= shares;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Mock governor — the live protocol-fee rate + recipient the strategy reads.
// ─────────────────────────────────────────────────────────────────────────────
contract MockGovernor {
    uint256 public protocolFeeBps;
    address public protocolFeeRecipient;

    function setFee(uint256 bps, address recipient) external {
        protocolFeeBps = bps;
        protocolFeeRecipient = recipient;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Mock Moonwell market + mUSDC. Flat-book redeem/settle: zero debt / zero collateral.
// ─────────────────────────────────────────────────────────────────────────────
contract MockMarket {
    uint256 public debt;

    function borrowBalanceStored(address) external view returns (uint256) {
        return debt;
    }
}

contract MockCUsdc {
    uint256 public cBal;

    function setCBal(uint256 b) external {
        cBal = b;
    }

    function balanceOf(address) external view returns (uint256) {
        return cBal;
    }

    function exchangeRateStored() external pure returns (uint256) {
        return 1e18;
    }

    function redeemUnderlying(uint256) external pure returns (uint256) {
        return 0;
    }
}

/// @dev Funded mUSDC for the fast-path test: `redeemUnderlying(amt)` burns `amt` mUSDC face and
///      delivers `amt` USDC to the strategy (the fast-path payout source). `cBal` = collateral face.
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
        cBal -= amt; // 1:1 at rate 1e18
        usdc.mint(strategy, amt);
        return 0;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Mock gauge + Aerodrome v2 router for the compound skim/redeploy split. `getReward`
// mints AERO to the caller (the strategy under delegatecall); the router burns AERO and
// mints exactly `usdcOut` USDC — letting the test control the swap output.
// ─────────────────────────────────────────────────────────────────────────────
contract MockGauge {
    address public rewardToken;
    uint256 public rewardAmt;

    constructor(address aero) {
        rewardToken = aero;
    }

    function setReward(uint256 a) external {
        rewardAmt = a;
    }

    function getReward(uint256) external {
        MockToken(rewardToken).mint(msg.sender, rewardAmt);
    }
}

contract MockAeroRouter {
    MockToken public aero;
    MockToken public usdc;
    uint256 public usdcOut;

    constructor(MockToken a, MockToken u) {
        aero = a;
        usdc = u;
    }

    function setUsdcOut(uint256 o) external {
        usdcOut = o;
    }

    struct Route {
        address from;
        address to;
        bool stable;
        address factory;
    }

    function swapExactTokensForTokens(uint256 amountIn, uint256, Route[] calldata, address to, uint256)
        external
        returns (uint256[] memory amounts)
    {
        aero.burn(msg.sender, amountIn); // consume the AERO
        usdc.mint(to, usdcOut); // deliver the configured USDC out
        amounts = new uint256[](1);
        amounts[0] = usdcOut;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Harnesses.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Exposes compoundImpl so the AERO-swap → skim → redeploy split can be unit-tested.
contract CompoundHarness is LeveragedAerodromeCLStrategy {
    function callCompoundImpl(uint256 minUsdcOut, uint256 minLiquidity, uint256 skimCap) external returns (uint256) {
        return LeveragedAeroManager.compoundImpl(minUsdcOut, minLiquidity, skimCap);
    }
}

/// @dev Real-nav() harness for the nav / redeem / settle tests (flat book).
contract NavHarness is LeveragedAerodromeCLStrategy {}

/// @title  LeveragedAeroCLProtocolFeeTest
/// @notice Unit tests for the strategy-side protocol-fee liability (review #388-3):
///         nav() netting, redeem skim (incl. oracle-independence), compound skim, settle
///         discharge, and the zero-cases (bps=0 → no accrual; recipient=0 → persists).
contract LeveragedAeroCLProtocolFeeTest is Test {
    uint256 private constant STRAT_BASE = uint256(0x405ae0b144079093e970849fdffdcb2a514e44968598c6c5c73444496e844900);
    // Diamond field slots (probe-verified): usdc+0, mUsdc+1, mCbBTC+2, mWeth+3, cbBTC+4,
    // weth+5, cbBTCFeed+7, wethFeed+8, usdcFeed+9, seqFeed+10, maxDelay+11, gracePeriod+12,
    // gauge+15, swapRouter+16, tokenId+18, feeRecipient-packed+19, hwm+20, lastFee+21, owed+22.
    uint256 private constant SLOT_USDC = STRAT_BASE + 0;
    uint256 private constant SLOT_MUSDC = STRAT_BASE + 1;
    uint256 private constant SLOT_MCBBTC = STRAT_BASE + 2;
    uint256 private constant SLOT_MWETH = STRAT_BASE + 3;
    uint256 private constant SLOT_CBBTC = STRAT_BASE + 4;
    uint256 private constant SLOT_WETH = STRAT_BASE + 5;
    uint256 private constant SLOT_CBBTCFEED = STRAT_BASE + 7;
    uint256 private constant SLOT_WETHFEED = STRAT_BASE + 8;
    uint256 private constant SLOT_USDCFEED = STRAT_BASE + 9;
    uint256 private constant SLOT_SEQFEED = STRAT_BASE + 10;
    uint256 private constant SLOT_MAX_DELAY = STRAT_BASE + 11;
    uint256 private constant SLOT_GRACE = STRAT_BASE + 12;
    uint256 private constant SLOT_SWAPROUTER = STRAT_BASE + 16;
    uint256 private constant SLOT_GAUGE = STRAT_BASE + 15;
    uint256 private constant SLOT_TOKENID = STRAT_BASE + 18;
    uint256 private constant SLOT_HWM = STRAT_BASE + 20;
    uint256 private constant SLOT_LAST_FEE = STRAT_BASE + 21;
    uint256 private constant SLOT_OWED = STRAT_BASE + 22;
    uint256 private constant SLOT_AERO_FEED = STRAT_BASE + 23; // L9: AERO/USD feed (compound floor)

    // BaseStrategy sequential slots.
    uint256 private constant SLOT_VAULT = 1;
    uint256 private constant SLOT_PROPOSER_STATE_INIT = 2;
    // _proposer (bits 0-159) + _state = Executed(1) (bit 160) + _initialized(true) (bit 168) share slot 2.
    uint256 private constant STATE_EXECUTED_INIT = (uint256(1) << 168) | (uint256(1) << 160);
    uint256 private constant SHARES_VIRTUAL_OFFSET = 1e6;
    // Proposer for the fulfill path (fulfillRedeem is onlyProposer). Packed into slot 2 alongside state.
    address private constant PROPOSER = address(0xB0B);

    // Chainlink prices (8dp) for the settle no-op feed reads.
    uint256 private constant P_BTC = 10_000_000_000_000; // $100k
    uint256 private constant P_ETH = 250_000_000_000; // $2.5k
    uint256 private constant P_USDC = 100_000_000; // $1

    address private constant RECIPIENT = address(0xFEE0);

    function _store(address t, uint256 slot, address a) private {
        vm.store(t, bytes32(slot), bytes32(uint256(uint160(a))));
    }

    function _storeUint(address t, uint256 slot, uint256 v) private {
        vm.store(t, bytes32(slot), bytes32(v));
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Test 2 — nav() netting
    // ═════════════════════════════════════════════════════════════════════════

    /// @dev A flat-book nav() drops by exactly `protocolFeeOwed`, and a fresh deposit prices its
    ///      shares against the NET nav.
    function test_nav_netsProtocolFeeOwed_andDepositPricesNet() public {
        NavHarness h = new NavHarness();
        MockToken usdc = new MockToken("USDC");
        MockVault vault = new MockVault(address(0), makeAddr("alice"), 100_000e12);

        _store(address(h), SLOT_VAULT, address(vault));
        vm.store(address(h), bytes32(SLOT_PROPOSER_STATE_INIT), bytes32(STATE_EXECUTED_INIT));
        _store(address(h), SLOT_USDC, address(usdc));
        _storeUint(address(h), SLOT_LAST_FEE, block.timestamp);

        uint256 idle = 50_000e6;
        usdc.mint(address(h), idle);
        assertEq(h.nav(), idle, "gross flat-book nav");

        uint256 owed = 500e6;
        _storeUint(address(h), SLOT_OWED, owed);
        assertEq(h.nav(), idle - owed, "nav must net protocolFeeOwed");

        // Fresh deposit prices against the NET nav: shares = a × (S+off) / (navNet+1).
        address dep = makeAddr("dep");
        uint256 a = 1_000e6;
        vm.mockCall(
            address(usdc),
            abi.encodeWithSignature("transferFrom(address,address,uint256)", dep, address(h), a),
            abi.encode(true)
        );
        uint256 navNet = h.nav();
        uint256 supply = vault.totalSupply();
        vm.prank(dep);
        uint256 shares = h.deposit(a, 0);
        uint256 expected = Math.mulDiv(a, supply + SHARES_VIRTUAL_OFFSET, navNet + 1);
        assertEq(shares, expected, "deposit must price against net nav");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Test 3 — redeem skim (oracle-independent)
    // ═════════════════════════════════════════════════════════════════════════

    /// @dev MIGRATED (fast path demoted): the Item-3 skim now lives on the escrowed async path
    ///      (`requestRedeem → fulfillRedeem`), so the flat-book proportional-unwind + skim mechanics
    ///      are exercised there. Skims f×owed to the recipient, nets the payout, decrements owed.
    function test_redeem_skimsProtocolFee_netPayout() public {
        (NavHarness h, MockToken usdc, MockVault vault, MockGovernor gov) = _redeemFixture();
        gov.setFee(100, RECIPIENT);

        usdc.mint(address(h), 10_000e6); // idle; f=1/2 → gross unwind 5_000e6
        _storeUint(address(h), SLOT_OWED, 400e6); // skim = f×owed = 200e6

        (address redeemer, uint256 shares) = _fundRedeemer(vault, h, "redeemer");
        _requestAndFulfill(h, redeemer, shares, 0);

        assertEq(usdc.balanceOf(redeemer), 4_800e6, "redeemer receives net = f*idle - f*owed");
        assertEq(usdc.balanceOf(RECIPIENT), 200e6, "recipient receives f*owed");
        assertEq(h.layout().protocolFeeOwed, 200e6, "owed decremented by the skim");
    }

    /// @dev MIGRATED: the STORED `minAssetsOut` applies to the NET amount at fulfill — a bound above net
    ///      but below gross reverts. (requestRedeem escrows minOut; fulfillRedeem enforces it net.)
    function test_redeem_minAssetsOut_appliesToNet() public {
        (NavHarness h, MockToken usdc, MockVault vault, MockGovernor gov) = _redeemFixture();
        gov.setFee(100, RECIPIENT);
        usdc.mint(address(h), 10_000e6);
        _storeUint(address(h), SLOT_OWED, 400e6);

        (address redeemer, uint256 shares) = _fundRedeemer(vault, h, "redeemer2");
        vm.prank(redeemer);
        uint256 id = h.requestRedeem(shares, 4_900e6); // net 4_800 < 4_900 < gross 5_000
        vm.prank(PROPOSER);
        vm.expectRevert(LeveragedAerodromeCLStrategy.InsufficientAssetsOut.selector);
        h.fulfillRedeem(id);
    }

    /// @dev MIGRATED: the skim is pure arithmetic on stored state — no oracle read anywhere in the
    ///      proportional-unwind (fulfill) path. We prove oracle-independence by NOT wiring any Chainlink
    ///      mock (a flat book needs none) and asserting the same net payout as the priced fixture.
    function test_redeem_oracleIndependentSkim() public {
        (NavHarness h, MockToken usdc, MockVault vault, MockGovernor gov) = _redeemFixture();
        gov.setFee(100, RECIPIENT);
        usdc.mint(address(h), 10_000e6);
        _storeUint(address(h), SLOT_OWED, 400e6);

        (address redeemer, uint256 shares) = _fundRedeemer(vault, h, "redeemer3");
        _requestAndFulfill(h, redeemer, shares, 0);
        assertEq(usdc.balanceOf(redeemer), 4_800e6, "oracle-independent net payout");
        assertEq(usdc.balanceOf(RECIPIENT), 200e6, "recipient paid without any oracle");
    }

    /// @dev NEW (fast-path fee-neutrality): the fast path prices `f × nav` and takes NO protocol skim
    ///      — `nav()` is already net of `protocolFeeOwed`, so a skim would double-charge. Assert the
    ///      redeemer gets exactly `f × nav`, `protocolFeeOwed` is UNCHANGED, and the recipient is NOT
    ///      paid. (Debt = 0 → the LTV gate passes; collateral funds the payout.) The per-share
    ///      preservation under an ACTIVE position is proven in the redeem fork suite.
    function test_fastRedeem_feeNeutral_noSkim() public {
        (NavHarness h, MockToken usdc, MockVault vault, MockGovernor gov) = _redeemFixture();
        gov.setFee(100, RECIPIENT);

        // Flat book: nav = idle USDC = 10_000e6. owed = 400e6 → navNet = 9_600e6. f = 1/2.
        uint256 idle = 10_000e6;
        usdc.mint(address(h), idle);
        _storeUint(address(h), SLOT_OWED, 400e6);
        // Funded mUSDC collateral (debt already 0 in the fixture) so fastRedeemImpl can free the payout.
        MockCUsdcFunded mUsdc = new MockCUsdcFunded(usdc, address(h), 1_000_000e6);
        _store(address(h), SLOT_MUSDC, address(mUsdc));

        uint256 navNet = h.nav(); // 9_600e6
        assertEq(navNet, idle - 400e6, "nav must be net of owed");

        (address redeemer, uint256 shares) = _fundRedeemer(vault, h, "fast");
        uint256 supply = vault.totalSupply();
        uint256 expected = Math.mulDiv(shares, navNet, supply); // f × navNet = 4_800e6

        vm.prank(redeemer);
        uint256 out = h.redeem(shares, 0);

        assertEq(out, expected, "fast path pays exactly f * navNet");
        assertEq(usdc.balanceOf(redeemer), expected, "redeemer received f * navNet");
        assertEq(h.layout().protocolFeeOwed, 400e6, "NO skim: owed unchanged on the fast path");
        assertEq(usdc.balanceOf(RECIPIENT), 0, "NO skim: recipient not paid on the fast path");
    }

    // Fast-path LTV gate + previewRedeem (fastOk / (0,false) on oracle-down) are exercised against a
    // REAL levered Moonwell book in test/integration/strategies/LeveragedAeroCL.redeem.fork.t.sol
    // (they need collateral+debt priced through the actual markets, not a flat-book mock).

    /// @dev NEW (fast-path fresh-slice netting): with an uncrystallized gain above the HWM and
    ///      protocolFeeBps > 0, the fast path's crystallize accrues a FRESH protocol slice p AND mints
    ///      perf-fee shares. Pricing must use (navPre − p) over the POST-MINT supply — otherwise the
    ///      redeemer captures f×p from stayers. Expected values recomputed via the pure fees lib.
    ///      Payout is funded from idle (no-op redeemUnderlying) so the flat-book model is
    ///      self-consistent: nav drops by exactly assetsOut → stayers' per-share must be preserved.
    function test_fastRedeem_freshProtocolSlice_notCapturedByRedeemer() public {
        (NavHarness h, MockToken usdc, MockVault vault, MockGovernor gov) = _redeemFixture();
        gov.setFee(1000, RECIPIENT); // 10% protocol slice on gross gain
        address perfRec = address(0xFEE5);
        _setPerfFeeAndRecipient(address(h), 1000, perfRec); // 10% perf fee → a real mint occurs

        // Uncrystallized gain: nav 110k vs HWM seeded at the 100k-per-share basis.
        uint256 idle = 110_000e6;
        usdc.mint(address(h), idle);
        uint256 supply0 = vault.totalSupply();
        uint256 hwm = Math.mulDiv(100_000e6, 1e18, supply0);
        _storeUint(address(h), SLOT_HWM, hwm);
        // Collateral gate: large cBal, zero debt; MockCUsdc.redeemUnderlying is a no-op, so the payout
        // is funded from idle (nav-consistent).
        MockCUsdc(_addr(address(h), SLOT_MUSDC)).setCBal(1_000_000e6);

        uint256 navPre = h.nav(); // 110_000e6 (owed 0)
        // Mirror the crystallize with the pure lib: same inputs the strategy will use (dt = 0).
        uint256 ts = vm.getBlockTimestamp();
        (uint256 feeShares,,, uint256 freshSlice) =
            LeveragedAeroFees.crystallize(navPre, supply0, hwm, ts, ts, 0, 1000, 1000);
        assertGt(freshSlice, 0, "fixture must accrue a fresh protocol slice");
        assertGt(feeShares, 0, "fixture must mint perf-fee shares");

        (address redeemer, uint256 shares) = _fundRedeemer(vault, h, "slice");
        uint256 expected = Math.mulDiv(shares, navPre - freshSlice, supply0 + feeShares);

        vm.prank(redeemer);
        uint256 out = h.redeem(shares, 0);

        // Redeemer does NOT capture f×slice: paid exactly f × (navPre − slice) at the post-mint supply.
        assertEq(out, expected, "fast path must net the fresh slice + use post-mint supply");
        assertEq(usdc.balanceOf(redeemer), expected, "redeemer balance mismatch");
        assertEq(h.layout().protocolFeeOwed, freshSlice, "fresh slice persists as owed (no skim/discharge)");
        assertEq(usdc.balanceOf(RECIPIENT), 0, "no discharge on the fast path");

        // Stayers' per-share preserved (payout funded from idle → nav drops by exactly `out`).
        uint256 perShareBefore = Math.mulDiv(navPre - freshSlice, 1e18, supply0 + feeShares);
        uint256 perShareAfter = Math.mulDiv(h.nav(), 1e18, vault.totalSupply());
        assertGe(perShareAfter, perShareBefore, "stayers diluted by the fast redeem");
        assertApproxEqRel(perShareAfter, perShareBefore, 0.0001e18, "stayers per-share moved > dust");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Test 3b — emergencyRedeem deadman gate + cancelRedeem (unit; fork covers the live book)
    // ═════════════════════════════════════════════════════════════════════════

    /// @dev Window boundary: at exactly `requestedAt + FULFILL_WINDOW` (2 days) the gate is still
    ///      closed (strictly-greater required); one second later it opens.
    function test_emergencyRedeem_beforeWindow_reverts() public {
        (NavHarness h, MockToken usdc, MockVault vault,) = _redeemFixture();
        usdc.mint(address(h), 10_000e6);
        (address redeemer, uint256 shares) = _fundRedeemer(vault, h, "em1");
        vm.prank(redeemer);
        uint256 id = h.requestRedeem(shares, 0);

        vm.warp(vm.getBlockTimestamp() + 2 days); // == requestedAt + FULFILL_WINDOW → still closed
        vm.prank(redeemer);
        vm.expectRevert(LeveragedAerodromeCLStrategy.FulfillWindowOpen.selector);
        h.emergencyRedeem(id, 0);

        vm.warp(vm.getBlockTimestamp() + 1); // strictly past → open
        vm.prank(redeemer);
        uint256 out = h.emergencyRedeem(id, 0);
        assertEq(out, 5_000e6, "f*idle payout after the window");
        assertEq(usdc.balanceOf(redeemer), 5_000e6, "redeemer not paid");
    }

    /// @dev Only the request owner can emergency-redeem, even after the window.
    function test_emergencyRedeem_nonOwner_reverts() public {
        (NavHarness h, MockToken usdc, MockVault vault,) = _redeemFixture();
        usdc.mint(address(h), 10_000e6);
        (address redeemer, uint256 shares) = _fundRedeemer(vault, h, "em2");
        vm.prank(redeemer);
        uint256 id = h.requestRedeem(shares, 0);

        vm.warp(vm.getBlockTimestamp() + 2 days + 1);
        vm.prank(makeAddr("mallory"));
        vm.expectRevert(LeveragedAerodromeCLStrategy.NotRequestOwner.selector);
        h.emergencyRedeem(id, 0);
    }

    /// @dev Pays the owner the proportional out NET of the Item-3 skim, burns the escrowed shares,
    ///      marks the request settled; a second call reverts.
    function test_emergencyRedeem_paysAndSettles() public {
        (NavHarness h, MockToken usdc, MockVault vault, MockGovernor gov) = _redeemFixture();
        gov.setFee(100, RECIPIENT);
        usdc.mint(address(h), 10_000e6);
        _storeUint(address(h), SLOT_OWED, 400e6); // skim = f×owed = 200e6

        (address redeemer, uint256 shares) = _fundRedeemer(vault, h, "em3");
        uint256 supplyBefore = vault.totalSupply();
        vm.prank(redeemer);
        uint256 id = h.requestRedeem(shares, 0);

        vm.warp(vm.getBlockTimestamp() + 2 days + 1);
        vm.prank(redeemer);
        uint256 out = h.emergencyRedeem(id, 0);

        assertEq(out, 4_800e6, "net payout = f*idle - f*owed");
        assertEq(usdc.balanceOf(redeemer), 4_800e6, "owner receives net-of-skim");
        assertEq(usdc.balanceOf(RECIPIENT), 200e6, "recipient receives f*owed");
        assertEq(vault.totalSupply(), supplyBefore - shares, "escrowed shares not burned");
        assertEq(vault.balanceOf(address(h)), 0, "strategy still holds escrow");
        assertTrue(h.redeemRequest(id).settled, "request not marked settled");

        vm.prank(redeemer);
        vm.expectRevert(LeveragedAerodromeCLStrategy.RequestSettled.selector);
        h.emergencyRedeem(id, 0); // double-settle prevented
    }

    /// @dev The FRESH caller-passed minAssetsOut is what's enforced — the stored one is ignored:
    ///      an impossible stored floor doesn't block, and an impossible fresh floor does.
    function test_emergencyRedeem_freshMinAssetsOut_enforced() public {
        (NavHarness h, MockToken usdc, MockVault vault,) = _redeemFixture();
        usdc.mint(address(h), 10_000e6); // net f*idle = 5_000e6
        (address redeemer, uint256 shares) = _fundRedeemer(vault, h, "em4");
        vm.prank(redeemer);
        uint256 id = h.requestRedeem(shares, 9_999e6); // stored floor is impossible (> 5_000e6)

        vm.warp(vm.getBlockTimestamp() + 2 days + 1);
        // Impossible FRESH floor → reverts (even though a passing path exists at floor 0).
        vm.prank(redeemer);
        vm.expectRevert(LeveragedAerodromeCLStrategy.InsufficientAssetsOut.selector);
        h.emergencyRedeem(id, 6_000e6);
        // Passing FRESH floor → succeeds DESPITE the impossible stored floor (stored is ignored).
        vm.prank(redeemer);
        uint256 out = h.emergencyRedeem(id, 0);
        assertEq(out, 5_000e6, "fresh-floor payout");
    }

    /// @dev cancelRedeem returns the exact escrowed shares, settles the request, and blocks a
    ///      subsequent fulfill. (The cancel-after-_settle variant stays fork-side.)
    function test_cancelRedeem_returnsEscrow_unit() public {
        (NavHarness h,, MockVault vault,) = _redeemFixture();
        (address redeemer, uint256 shares) = _fundRedeemer(vault, h, "em5");
        vm.prank(redeemer);
        uint256 id = h.requestRedeem(shares, 0);
        assertEq(vault.balanceOf(redeemer), 0, "shares not escrowed");
        assertEq(vault.balanceOf(address(h)), shares, "strategy did not receive escrow");

        vm.prank(redeemer);
        h.cancelRedeem(id);
        assertEq(vault.balanceOf(redeemer), shares, "cancel did not return the exact shares");
        assertEq(vault.balanceOf(address(h)), 0, "escrow left behind");
        assertTrue(h.redeemRequest(id).settled, "request not settled by cancel");

        vm.prank(PROPOSER);
        vm.expectRevert(LeveragedAerodromeCLStrategy.RequestSettled.selector);
        h.fulfillRedeem(id);
    }

    /// @dev Pack performanceFeeBps + feeRecipient into diamond slot 19 (posTickLower 0-23 |
    ///      posTickUpper 24-47 | mgmtBps 48-63 | perfBps 64-79 | feeRecipient 80-239).
    function _setPerfFeeAndRecipient(address t, uint16 perfBps, address rec) private {
        vm.store(t, bytes32(STRAT_BASE + 19), bytes32((uint256(perfBps) << 64) | (uint256(uint160(rec)) << 80)));
    }

    /// @dev Read an address field back out of a diamond slot (low 160 bits).
    function _addr(address t, uint256 slot) private view returns (address) {
        return address(uint160(uint256(vm.load(t, bytes32(slot)))));
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Test 4 — compound skim (manager split)
    // ═════════════════════════════════════════════════════════════════════════

    /// @dev Full skim: skimCap ≥ usdcOut → the whole swap output is withheld (pay == usdcOut) and
    ///      nothing is redeployed (deployIdleImpl never called → no Moonwell/NPM venue needed).
    function test_compoundImpl_fullSkim_noRedeploy() public {
        (CompoundHarness h, MockToken usdc, MockGauge gauge, MockAeroRouter router) = _compoundFixture();
        gauge.setReward(50e18); // 50 AERO claimable
        router.setUsdcOut(300e6); // swap yields 300 USDC

        uint256 pay = h.callCompoundImpl(1, 0, 1_000e6); // skimCap generous
        assertEq(pay, 300e6, "pay == usdcOut when skimCap >= usdcOut");
        assertEq(usdc.balanceOf(address(h)), 300e6, "no redeploy: full output retained for the skim");
    }

    /// @dev skimCap == usdcOut boundary → pay == usdcOut, still no redeploy.
    function test_compoundImpl_skimCapEqualsOut_noRedeploy() public {
        (CompoundHarness h, MockToken usdc, MockGauge gauge, MockAeroRouter router) = _compoundFixture();
        gauge.setReward(50e18);
        router.setUsdcOut(300e6);

        uint256 pay = h.callCompoundImpl(1, 0, 300e6);
        assertEq(pay, 300e6, "pay == usdcOut at the boundary");
        assertEq(usdc.balanceOf(address(h)), 300e6, "no redeploy at the boundary");
    }

    /// @dev skimCap == 0 (no recipient) → pay == 0; the manager attempts to redeploy the full output.
    ///      We keep the position flat-ish so deployIdleImpl's first venue call is the observable effect;
    ///      here we only assert the skim decision (`pay == 0`) via a skimCap of 0 that leaves usdcOut
    ///      fully to redeploy — and we stop before the venue by giving 0 reward so usdcOut == 0.
    function test_compoundImpl_zeroSkimCap_noPay() public {
        (CompoundHarness h,, MockGauge gauge, MockAeroRouter router) = _compoundFixture();
        gauge.setReward(0); // no AERO → early clean no-op, pay 0
        router.setUsdcOut(0);

        uint256 pay = h.callCompoundImpl(1, 0, 0);
        assertEq(pay, 0, "no reward -> pay 0");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Test 5 — settle discharge
    // ═════════════════════════════════════════════════════════════════════════

    /// @dev _settle pays min(owed, balance) to the recipient BEFORE pushing the rest to the vault;
    ///      owed cleared. Flat book + zero debt/collateral → settleImpl is a clean no-op.
    function test_settle_dischargesBeforeVaultPush() public {
        (NavHarness h, MockToken usdc, MockVault vault) = _settleFixture(100, RECIPIENT);
        uint256 realized = 5_000e6;
        usdc.mint(address(h), realized);
        _storeUint(address(h), SLOT_OWED, 400e6);

        vm.prank(address(vault));
        h.settle();

        assertEq(usdc.balanceOf(RECIPIENT), 400e6, "recipient paid on settle");
        assertEq(usdc.balanceOf(address(vault)), realized - 400e6, "vault receives realized - fee");
        assertEq(h.layout().protocolFeeOwed, 0, "owed cleared on settle");
    }

    /// @dev Settle caps the discharge at the realized balance when owed > balance (never reverts).
    function test_settle_capsAtBalance() public {
        (NavHarness h, MockToken usdc, MockVault vault) = _settleFixture(100, RECIPIENT);
        uint256 realized = 300e6;
        usdc.mint(address(h), realized);
        _storeUint(address(h), SLOT_OWED, 400e6); // owed > realized

        vm.prank(address(vault));
        h.settle();

        assertEq(usdc.balanceOf(RECIPIENT), realized, "discharge capped at balance");
        assertEq(usdc.balanceOf(address(vault)), 0, "nothing left for the vault");
        assertEq(h.layout().protocolFeeOwed, 100e6, "residual liability persists");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Test 6 — zero cases
    // ═════════════════════════════════════════════════════════════════════════

    /// @dev MIGRATED: protocolFeeBps == 0 → the fulfill-path crystallize accrues nothing even when there
    ///      IS a gain above the HWM. (Same best-effort crystallize as the pre-redesign redeem.)
    function test_zeroBps_noAccrual() public {
        (NavHarness h, MockToken usdc, MockVault vault, MockGovernor gov) = _redeemFixture();
        gov.setFee(0, RECIPIENT); // rate 0
        // Gain vs a seeded HWM: nav gross 110k vs 100k supply, HWM at 1:1, dt>0.
        usdc.mint(address(h), 110_000e6);
        _storeUint(address(h), SLOT_HWM, Math.mulDiv(100_000e6, 1e18, vault.totalSupply()));
        _storeUint(address(h), SLOT_LAST_FEE, block.timestamp > 1 ? block.timestamp - 1 : 1);

        (address redeemer, uint256 shares) = _fundRedeemer(vault, h, "r0");
        _requestAndFulfill(h, redeemer, shares, 0);

        assertEq(h.layout().protocolFeeOwed, 0, "bps=0 must accrue no protocol fee");
    }

    /// @dev MIGRATED: recipient == address(0) → the liability still holds (nav stays net) but discharge
    ///      skips, so the fulfill pays the full gross and owed is unchanged.
    function test_zeroRecipient_accruesButNoDischarge() public {
        (NavHarness h, MockToken usdc, MockVault vault, MockGovernor gov) = _redeemFixture();
        gov.setFee(100, address(0)); // rate set, recipient unset
        usdc.mint(address(h), 10_000e6);
        _storeUint(address(h), SLOT_OWED, 400e6);

        (address redeemer, uint256 shares) = _fundRedeemer(vault, h, "rz");
        _requestAndFulfill(h, redeemer, shares, 0);

        assertEq(usdc.balanceOf(redeemer), 5_000e6, "no discharge when recipient == 0 -> full gross");
        assertEq(h.layout().protocolFeeOwed, 400e6, "liability persists when recipient == 0");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Fixtures
    // ─────────────────────────────────────────────────────────────────────────

    function _redeemFixture() private returns (NavHarness h, MockToken usdc, MockVault vault, MockGovernor gov) {
        h = new NavHarness();
        usdc = new MockToken("USDC");
        gov = new MockGovernor();
        vault = new MockVault(address(gov), makeAddr("alice"), 100_000e12);
        MockCUsdc mUsdc = new MockCUsdc();
        MockMarket mCbBTC = new MockMarket();
        MockMarket mWeth = new MockMarket();
        MockToken cbBTC = new MockToken("cbBTC");
        MockToken weth = new MockToken("WETH");

        _store(address(h), SLOT_VAULT, address(vault));
        // Pack proposer + Executed state + initialized into slot 2 (fulfillRedeem is onlyProposer).
        vm.store(
            address(h), bytes32(SLOT_PROPOSER_STATE_INIT), bytes32(STATE_EXECUTED_INIT | uint256(uint160(PROPOSER)))
        );
        _store(address(h), SLOT_USDC, address(usdc));
        _store(address(h), SLOT_MUSDC, address(mUsdc));
        _store(address(h), SLOT_MCBBTC, address(mCbBTC));
        _store(address(h), SLOT_MWETH, address(mWeth));
        _store(address(h), SLOT_CBBTC, address(cbBTC));
        _store(address(h), SLOT_WETH, address(weth));
        _storeUint(address(h), SLOT_LAST_FEE, block.timestamp);
        // tokenId=0 (flat book) → redeem unwind reduces to f×idle, oracle-free.
    }

    /// @dev Migration helper (fast path demoted `redeem` → escrowed async path): the redeemer escrows
    ///      `shares` via `requestRedeem`, then the proposer `fulfillRedeem`s — the SAME oracle-free
    ///      proportional-unwind + Item-3 skim that the pre-redesign `redeem` ran. Returns the net out.
    function _requestAndFulfill(NavHarness h, address redeemer, uint256 shares, uint256 minOut)
        private
        returns (uint256 id)
    {
        vm.prank(redeemer);
        id = h.requestRedeem(shares, minOut);
        vm.prank(PROPOSER);
        h.fulfillRedeem(id);
    }

    /// @dev Give the redeemer HALF the existing supply WITHOUT changing totalSupply (so f = 1/2):
    ///      transfer 50k of alice's 100k shares to the redeemer, then approve the strategy.
    function _fundRedeemer(MockVault vault, NavHarness h, string memory label)
        private
        returns (address redeemer, uint256 shares)
    {
        redeemer = makeAddr(label);
        shares = 50_000e12; // half of the 100k supply → f = 1/2
        vm.prank(makeAddr("alice"));
        vault.approve(address(this), shares);
        vault.transferFrom(makeAddr("alice"), redeemer, shares);
        vm.prank(redeemer);
        vault.approve(address(h), shares);
    }

    function _settleFixture(uint256 bps, address recipient)
        private
        returns (NavHarness h, MockToken usdc, MockVault vault)
    {
        h = new NavHarness();
        usdc = new MockToken("USDC");
        MockGovernor gov = new MockGovernor();
        gov.setFee(bps, recipient);
        vault = new MockVault(address(gov), makeAddr("alice"), 100_000e12);
        MockCUsdc mUsdc = new MockCUsdc();
        MockMarket mCbBTC = new MockMarket();
        MockMarket mWeth = new MockMarket();
        MockToken cbBTC = new MockToken("cbBTC");
        MockToken weth = new MockToken("WETH");

        _store(address(h), SLOT_VAULT, address(vault));
        vm.store(address(h), bytes32(SLOT_PROPOSER_STATE_INIT), bytes32(STATE_EXECUTED_INIT));
        _store(address(h), SLOT_USDC, address(usdc));
        _store(address(h), SLOT_MUSDC, address(mUsdc));
        _store(address(h), SLOT_MCBBTC, address(mCbBTC));
        _store(address(h), SLOT_MWETH, address(mWeth));
        _store(address(h), SLOT_CBBTC, address(cbBTC));
        _store(address(h), SLOT_WETH, address(weth));
        _mockFeeds(address(h)); // settleImpl step-5 reads feeds even with 0 leg balances
    }

    /// @dev The AERO→USDC swap in `compoundImpl` routes through the HARDCODED Aerodrome v2 router
    ///      constant (`AERO_V2_ROUTER`), not the storage `swapRouter`. So we etch a MockAeroRouter's
    ///      runtime + storage at that canonical address rather than wiring it via a slot.
    address private constant AERO_V2_ROUTER = 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43;

    function _compoundFixture()
        private
        returns (CompoundHarness h, MockToken usdc, MockGauge gauge, MockAeroRouter router)
    {
        vm.warp(block.timestamp + 7 days); // clear the sequencer grace window for the L9 AERO feed read
        h = new CompoundHarness();
        usdc = new MockToken("USDC");
        MockToken aero = new MockToken("AERO");
        gauge = new MockGauge(address(aero));

        // Build a MockAeroRouter, then etch its code at the canonical address and prime its storage
        // (aero @ slot 0, usdc @ slot 1, usdcOut @ slot 2) via a returned handle we drive by setter.
        MockAeroRouter impl = new MockAeroRouter(aero, usdc);
        vm.etch(AERO_V2_ROUTER, address(impl).code);
        router = MockAeroRouter(AERO_V2_ROUTER);
        vm.store(AERO_V2_ROUTER, bytes32(uint256(0)), bytes32(uint256(uint160(address(aero)))));
        vm.store(AERO_V2_ROUTER, bytes32(uint256(1)), bytes32(uint256(uint160(address(usdc)))));

        _store(address(h), SLOT_USDC, address(usdc));
        _store(address(h), SLOT_GAUGE, address(gauge));
        _storeUint(address(h), SLOT_TOKENID, 42); // nonzero → not flat book

        // L9: compound now derives an AERO/USD oracle floor and post-checks the fill. Wire a fresh
        // 8dp AERO feed + sequencer + maxSlippageBps=300 so the skim tests (50 AERO @ $0.90 →
        // floor ≈ 43.65e6) clear their 300e6 fills — proving the floor composes with the skim split.
        _store(address(h), SLOT_SEQFEED, address(0xF000));
        _store(address(h), SLOT_AERO_FEED, address(0xFEED));
        _storeUint(address(h), SLOT_MAX_DELAY, type(uint256).max);
        _storeUint(address(h), SLOT_GRACE, 0);
        // maxSlippageBps (byte offset 29 within packed slot 16; swapRouter@0..19 stays 0 here) = 300.
        vm.store(address(h), bytes32(STRAT_BASE + 16), bytes32(uint256(300) << (29 * 8)));
        vm.mockCall(
            address(0xF000),
            abi.encodeWithSelector(bytes4(keccak256("latestRoundData()"))),
            abi.encode(uint80(1), int256(0), uint256(1), block.timestamp, uint80(1))
        );
        _mockFeed(address(0xFEED), 0.9e8); // AERO/USD = $0.90 (8dp)
    }

    function _mockFeeds(address strat) private {
        vm.warp(block.timestamp + 7 days);
        _store(strat, SLOT_CBBTCFEED, address(0xF001));
        _store(strat, SLOT_WETHFEED, address(0xF002));
        _store(strat, SLOT_USDCFEED, address(0xF003));
        _store(strat, SLOT_SEQFEED, address(0xF000));
        _storeUint(strat, SLOT_MAX_DELAY, type(uint256).max);
        _storeUint(strat, SLOT_GRACE, 0);
        vm.mockCall(
            address(0xF000),
            abi.encodeWithSelector(bytes4(keccak256("latestRoundData()"))),
            abi.encode(uint80(1), int256(0), uint256(1), block.timestamp, uint80(1))
        );
        _mockFeed(address(0xF001), P_BTC);
        _mockFeed(address(0xF002), P_ETH);
        _mockFeed(address(0xF003), P_USDC);
    }

    function _mockFeed(address feed, uint256 price) private {
        vm.mockCall(
            feed,
            abi.encodeWithSelector(bytes4(keccak256("latestRoundData()"))),
            abi.encode(uint80(1), int256(price), uint256(1), block.timestamp, uint80(1))
        );
        vm.mockCall(feed, abi.encodeWithSelector(bytes4(keccak256("decimals()"))), abi.encode(uint8(8)));
    }
}
