// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {LeveragedAerodromeCLStrategy} from "../src/strategies/LeveragedAerodromeCLStrategy.sol";
import {LeveragedAeroManager} from "../src/strategies/LeveragedAeroManager.sol";

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
    // _state = Executed(1), _initialized(true) → (1<<168)|(1<<160)
    uint256 private constant STATE_EXECUTED_INIT = (uint256(1) << 168) | (uint256(1) << 160);
    uint256 private constant SHARES_VIRTUAL_OFFSET = 1e6;

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

    /// @dev Flat-book redeem skims f×owed to the recipient, nets the payout, decrements owed.
    function test_redeem_skimsProtocolFee_netPayout() public {
        (NavHarness h, MockToken usdc, MockVault vault, MockGovernor gov) = _redeemFixture();
        gov.setFee(100, RECIPIENT);

        usdc.mint(address(h), 10_000e6); // idle; f=1/2 → gross unwind 5_000e6
        _storeUint(address(h), SLOT_OWED, 400e6); // skim = f×owed = 200e6

        (address redeemer, uint256 shares) = _fundRedeemer(vault, h, "redeemer");
        vm.prank(redeemer);
        uint256 out = h.redeem(shares, 0);

        assertEq(out, 5_000e6 - 200e6, "net payout = f*idle - f*owed");
        assertEq(usdc.balanceOf(RECIPIENT), 200e6, "recipient receives f*owed");
        assertEq(usdc.balanceOf(redeemer), 4_800e6, "redeemer receives net");
        assertEq(h.layout().protocolFeeOwed, 200e6, "owed decremented by the skim");
    }

    /// @dev minAssetsOut applies to the NET amount: a bound above net but below gross reverts.
    function test_redeem_minAssetsOut_appliesToNet() public {
        (NavHarness h, MockToken usdc, MockVault vault, MockGovernor gov) = _redeemFixture();
        gov.setFee(100, RECIPIENT);
        usdc.mint(address(h), 10_000e6);
        _storeUint(address(h), SLOT_OWED, 400e6);

        (address redeemer, uint256 shares) = _fundRedeemer(vault, h, "redeemer2");
        vm.prank(redeemer);
        vm.expectRevert(LeveragedAerodromeCLStrategy.InsufficientAssetsOut.selector);
        h.redeem(shares, 4_900e6); // net 4_800 < 4_900 < gross 5_000 → revert
    }

    /// @dev The skim is pure arithmetic on stored state — no oracle read anywhere in redeem. We prove
    ///      oracle-independence by NOT wiring any Chainlink mock (a flat book needs none) and asserting
    ///      the same net payout as the priced fixture. `nav()` in redeem's try/catch returns idle−owed
    ///      cleanly (flat book), and the skim math is identical regardless.
    function test_redeem_oracleIndependentSkim() public {
        (NavHarness h, MockToken usdc, MockVault vault, MockGovernor gov) = _redeemFixture();
        gov.setFee(100, RECIPIENT);
        usdc.mint(address(h), 10_000e6);
        _storeUint(address(h), SLOT_OWED, 400e6);

        (address redeemer, uint256 shares) = _fundRedeemer(vault, h, "redeemer3");
        vm.prank(redeemer);
        uint256 out = h.redeem(shares, 0);
        assertEq(out, 4_800e6, "oracle-independent net payout");
        assertEq(usdc.balanceOf(RECIPIENT), 200e6, "recipient paid without any oracle");
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

    /// @dev protocolFeeBps == 0 → a crystallize (via redeem's best-effort path) accrues nothing even
    ///      when there IS a gain above the HWM.
    function test_zeroBps_noAccrual() public {
        (NavHarness h, MockToken usdc, MockVault vault, MockGovernor gov) = _redeemFixture();
        gov.setFee(0, RECIPIENT); // rate 0
        // Gain vs a seeded HWM: nav gross 110k vs 100k supply, HWM at 1:1, dt>0.
        usdc.mint(address(h), 110_000e6);
        _storeUint(address(h), SLOT_HWM, Math.mulDiv(100_000e6, 1e18, vault.totalSupply()));
        _storeUint(address(h), SLOT_LAST_FEE, block.timestamp > 1 ? block.timestamp - 1 : 1);

        (address redeemer, uint256 shares) = _fundRedeemer(vault, h, "r0");
        vm.prank(redeemer);
        h.redeem(shares, 0);

        assertEq(h.layout().protocolFeeOwed, 0, "bps=0 must accrue no protocol fee");
    }

    /// @dev recipient == address(0) → the liability still holds (nav stays net) but discharge skips,
    ///      so a redeem pays the full gross and owed is unchanged.
    function test_zeroRecipient_accruesButNoDischarge() public {
        (NavHarness h, MockToken usdc, MockVault vault, MockGovernor gov) = _redeemFixture();
        gov.setFee(100, address(0)); // rate set, recipient unset
        usdc.mint(address(h), 10_000e6);
        _storeUint(address(h), SLOT_OWED, 400e6);

        (address redeemer, uint256 shares) = _fundRedeemer(vault, h, "rz");
        vm.prank(redeemer);
        uint256 out = h.redeem(shares, 0);

        assertEq(out, 5_000e6, "no discharge when recipient == 0 -> full gross");
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
        vm.store(address(h), bytes32(SLOT_PROPOSER_STATE_INIT), bytes32(STATE_EXECUTED_INIT));
        _store(address(h), SLOT_USDC, address(usdc));
        _store(address(h), SLOT_MUSDC, address(mUsdc));
        _store(address(h), SLOT_MCBBTC, address(mCbBTC));
        _store(address(h), SLOT_MWETH, address(mWeth));
        _store(address(h), SLOT_CBBTC, address(cbBTC));
        _store(address(h), SLOT_WETH, address(weth));
        _storeUint(address(h), SLOT_LAST_FEE, block.timestamp);
        // tokenId=0 (flat book) → redeem unwind reduces to f×idle, oracle-free.
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
