// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {LeveragedAerodromeCLStrategy} from "../src/strategies/LeveragedAerodromeCLStrategy.sol";
import {LeveragedAeroManager} from "../src/strategies/LeveragedAeroManager.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Review finding #2 — fast redeem now sources the redeemer's pro-rata `f×idle`
// share FIRST, then funds only the remainder from Moonwell collateral (LTV gate
// on that remainder). Proves: (a) a levered book that previously reverted
// `FastRedeemExceedsLtv` now succeeds off idle; (b) the redeemer draws at most
// `f×idle` so a stayer's `(1-f)×idle` is untouched; (c) flat book (collateral==0,
// only idle) works; (d) pure-collateral book LTV behaviour is unchanged.
//
// The tests drive `fastRedeemImpl` directly (the delegatecalled venue body) via a
// harness, holding it byte-for-byte equivalent to the strategy's `redeem` funding
// step. The strategy computes `idleShare = f×idle` and passes it in.
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
}

/// @dev Moonwell borrow market — only `borrowBalanceStored` is read by the fast path.
contract MockMarket {
    uint256 public debt;

    function setDebt(uint256 d) external {
        debt = d;
    }

    function borrowBalanceStored(address) external view returns (uint256) {
        return debt;
    }
}

/// @dev mUSDC collateral — `redeemUnderlying` frees USDC to the strategy (rate 1:1).
contract MockCUsdc {
    MockToken public usdc;
    address public strategy;
    uint256 public cBal;
    uint256 public exchangeRate = 1e18;
    uint256 public totalRedeemed;

    constructor(MockToken u) {
        usdc = u;
    }

    function setStrategy(address s) external {
        strategy = s;
    }

    function setCBal(uint256 b) external {
        cBal = b;
    }

    function balanceOf(address) external view returns (uint256) {
        return cBal;
    }

    function exchangeRateStored() external view returns (uint256) {
        return exchangeRate;
    }

    function redeemUnderlying(uint256 amt) external returns (uint256) {
        cBal -= amt;
        totalRedeemed += amt;
        usdc.mint(strategy, amt);
        return 0;
    }
}

/// @dev Chainlink aggregator returning a fixed positive answer with 8 decimals.
contract MockFeed {
    int256 public answer;
    uint8 public constant decimals = 8;

    constructor(int256 a) {
        answer = a;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, 1, block.timestamp, 1);
    }
}

/// @dev Sequencer-uptime feed: up (answer 0) and started long ago (grace elapsed).
contract MockSequencer {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 0, 1, block.timestamp, 1);
    }
}

/// @dev Comptroller — `getAccountLiquidity` returns healthy (no shortfall) for `_assertHealthy`.
contract MockComptroller {
    function getAccountLiquidity(address) external pure returns (uint256, uint256, uint256) {
        return (0, 1e18, 0);
    }
}

/// @dev Harness: typed setters over the strategy's ERC-7201 diamond storage (no slot math), plus a
///      thin wrapper over the delegatecalled `fastRedeemImpl`.
contract FastRedeemHarness is LeveragedAerodromeCLStrategy {
    function callFastRedeem(uint256 assetsOut, uint256 idleShare) external {
        LeveragedAeroManager.fastRedeemImpl(assetsOut, idleShare);
    }

    function setTokens(address usdc_, address mUsdc_, address mCbBTC_, address mWeth_) external {
        Layout storage $ = _lay();
        $.usdc = usdc_;
        $.mUsdc = mUsdc_;
        $.mCbBTC = mCbBTC_;
        $.mWeth = mWeth_;
    }

    function setFeeds(address cbBTCFeed_, address wethFeed_, address usdcFeed_, address sequencerFeed_) external {
        Layout storage $ = _lay();
        $.cbBTCFeed = cbBTCFeed_;
        $.wethFeed = wethFeed_;
        $.usdcFeed = usdcFeed_;
        $.sequencerFeed = sequencerFeed_;
        $.maxDelay = 1 days;
        $.gracePeriod = 0;
    }

    function setComptroller(address c) external {
        _lay().comptroller = c;
    }

    function setMaxLtvBps(uint16 v) external {
        _lay().maxLtvBps = v;
    }

    // Same diamond slot + accessor as the strategy/manager (byte-identical discipline).
    bytes32 private constant STORAGE_SLOT = 0x405ae0b144079093e970849fdffdcb2a514e44968598c6c5c73444496e844900;

    function _lay() private pure returns (Layout storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := STORAGE_SLOT
        }
    }
}

contract LeveragedAeroCLReviewF2Test is Test {
    FastRedeemHarness private h;
    MockToken private usdc;
    MockMarket private mCbBTC;
    MockMarket private mWeth;
    MockCUsdc private mUsdc;

    function setUp() public {
        vm.warp(1_000_000); // past the sequencer grace period (seqStartedAt=1, gracePeriod=0)
        h = new FastRedeemHarness();
        usdc = new MockToken("USDC");
        mCbBTC = new MockMarket();
        mWeth = new MockMarket();
        mUsdc = new MockCUsdc(usdc);
        mUsdc.setStrategy(address(h));

        h.setTokens(address(usdc), address(mUsdc), address(mCbBTC), address(mWeth));
        h.setMaxLtvBps(6500);
        // Debt 0 by default → `_readCollateralDebt` / `_assertHealthy` skip the oracle entirely.
        mCbBTC.setDebt(0);
        mWeth.setDebt(0);
    }

    // ── (a) Levered book (collateral present) + idle USDC: a redeem that the OLD gate
    //    (LTV on the full assetsOut) rejected now succeeds, funded partly from f×idle. ──
    //
    // f = 1/2. idle = 4_000e6 → f×idle = 2_000e6. collateral = 3_000e6. assetsOut = 2_500e6.
    // OLD: assetsOut(2_500e6) < collateral(3_000e6) would actually pass with debt=0... so to make
    //      the OLD path REVERT we need assetsOut >= collateral. Use assetsOut = 3_500e6 below.
    function test_leveredBookWithIdle_previouslyReverted_nowSucceedsFromIdle() public {
        uint256 idle = 4_000e6;
        usdc.mint(address(h), idle);
        mUsdc.setCBal(3_000e6); // collateral 3_000e6
        // f = 1/2, idleShare = 2_000e6. assetsOut = 3_500e6.
        // OLD behaviour: fromCollateral == assetsOut == 3_500e6 >= collateral 3_000e6 → revert.
        // NEW behaviour: fromIdle = min(3_500e6, 2_000e6) = 2_000e6 → fromCollateral = 1_500e6 < 3_000e6 → OK.
        uint256 assetsOut = 3_500e6;
        uint256 idleShare = 2_000e6;

        // Sanity: the OLD single-arg gate would have reverted (fromCollateral == assetsOut).
        // (Asserted implicitly — with idleShare=0 the new impl reproduces the old gate.)
        vm.expectRevert(
            abi.encodeWithSelector(LeveragedAeroManager.FastRedeemExceedsLtv.selector, type(uint256).max, uint256(6500))
        );
        h.callFastRedeem(assetsOut, 0);

        // NEW: with the real f×idle share, the redeem funds 2_000e6 off idle + 1_500e6 off collateral.
        h.callFastRedeem(assetsOut, idleShare);
        assertEq(mUsdc.totalRedeemed(), 1_500e6, "collateral drawn should be the remainder only");
        // Strategy USDC = idle(4_000e6) + freed collateral(1_500e6) = 5_500e6 (payout happens in the
        // strategy entrypoint, not here) — enough to cover assetsOut 3_500e6.
        assertEq(usdc.balanceOf(address(h)), 5_500e6, "idle+freed collateral");
    }

    // ── (b) The redeemer draws AT MOST f×idle from idle — a stayer's (1-f)×idle is untouched. ──
    //
    // f = 1/4. idle = 8_000e6 → f×idle = 2_000e6, stayers keep 6_000e6. collateral = 10_000e6.
    // assetsOut = 5_000e6 (> f×idle). fromIdle capped at 2_000e6 → fromCollateral = 3_000e6.
    // After the strategy pays out assetsOut, remaining idle = idle - fromIdle = 6_000e6 = stayers'.
    function test_redeemerDrawsAtMostFxIdle_stayerIdleUntouched() public {
        uint256 idle = 8_000e6;
        usdc.mint(address(h), idle);
        mUsdc.setCBal(10_000e6);
        uint256 idleShare = 2_000e6; // f = 1/4
        uint256 assetsOut = 5_000e6;

        h.callFastRedeem(assetsOut, idleShare);
        // Only the remainder was freed from collateral (idle covered the redeemer's f×idle slice).
        assertEq(mUsdc.totalRedeemed(), 3_000e6, "collateral should fund only assetsOut - f*idle");

        // Simulate the strategy's payout transfer of assetsOut. Remaining USDC MUST be >= stayers' (1-f)*idle.
        uint256 stayersIdle = idle - idleShare; // 6_000e6
        vm.prank(address(h));
        usdc.transfer(address(0xBEEF), assetsOut);
        assertEq(usdc.balanceOf(address(h)), stayersIdle, "stayers' (1-f)*idle must be exactly preserved");
        assertGe(usdc.balanceOf(address(h)), stayersIdle, "stayer idle skimmed");
    }

    // ── (c) Flat book: collateral == 0, only idle. Fast redeem funds the redeemer's f share
    //    purely from idle and never touches collateral (LTV gate skipped). ──
    //
    // On a flat book navNet = idle - owed, so assetsOut = f×(idle-owed) <= f×idle = idleShare,
    // hence fromCollateral == 0. Here owed==0 for simplicity → assetsOut == f×idle.
    function test_flatBook_fundsFromIdleOnly_noCollateralTouch() public {
        uint256 idle = 10_000e6;
        usdc.mint(address(h), idle);
        mUsdc.setCBal(0); // flat book — no collateral
        uint256 idleShare = 5_000e6; // f = 1/2
        uint256 assetsOut = 5_000e6; // == f×idle (owed 0)

        h.callFastRedeem(assetsOut, idleShare);
        assertEq(mUsdc.totalRedeemed(), 0, "flat book must not touch collateral");
        assertEq(usdc.balanceOf(address(h)), idle, "no USDC moved inside the manager (payout is in the strategy)");

        // A flat-book redeem where the OLD gate would have reverted (assetsOut >= collateral==0)
        // now succeeds because fromCollateral == 0.
        vm.expectRevert(
            abi.encodeWithSelector(LeveragedAeroManager.FastRedeemExceedsLtv.selector, type(uint256).max, uint256(6500))
        );
        h.callFastRedeem(assetsOut, 0); // old-equivalent (idleShare 0) still reverts on the empty collateral
    }

    // ── (d) Pure-collateral book (idle == 0): existing LTV behaviour is unchanged. ──
    function test_pureCollateralBook_ltvBehaviourUnchanged_debtFree() public {
        // idle == 0 → fromIdle == 0 → fromCollateral == assetsOut (identical to the old path).
        mUsdc.setCBal(3_000e6);
        // assetsOut >= collateral → the same FastRedeemExceedsLtv revert as before.
        vm.expectRevert(
            abi.encodeWithSelector(LeveragedAeroManager.FastRedeemExceedsLtv.selector, type(uint256).max, uint256(6500))
        );
        h.callFastRedeem(3_000e6, 0);

        // assetsOut < collateral with no debt → passes, frees the full assetsOut from collateral.
        h.callFastRedeem(2_000e6, 0);
        assertEq(mUsdc.totalRedeemed(), 2_000e6, "full assetsOut freed from collateral (idle==0)");
    }

    // ── (d') Pure-collateral book, debt > 0: the postLtv gate still binds on the full assetsOut
    //    when idle == 0 (behaviour unchanged), and passes when the remainder keeps LTV <= max. ──
    function test_pureCollateralBook_postLtvGate_unchanged() public {
        // Wire oracle mocks (debt > 0 path). All feeds 1e8 (=$1, 8dp) so USDC-face == token units*scale.
        MockFeed f1 = new MockFeed(1e8);
        MockSequencer seq = new MockSequencer();
        MockComptroller comp = new MockComptroller();
        h.setFeeds(address(f1), address(f1), address(f1), address(seq));
        h.setComptroller(address(comp));

        // collateral 10_000e6, debt 7_000e6-equivalent. cbBTC 8dp: 7_000e6 USDC-face == 7_000e6 * 1e8 / 1e8
        // through _tokenToUsdc(amt, 8, 1e8, 1e8) = amt * 1e6 / 1e8 → to get 7_000e6 face set amt = 7_000e8.
        mUsdc.setCBal(10_000e6);
        mCbBTC.setDebt(7_000e8); // → 7_000e6 USDC-face debt
        h.setMaxLtvBps(8000); // 80%

        // assetsOut = 2_000e6, idle == 0 → fromCollateral = 2_000e6.
        // postLtv = 7_000e6 / (10_000e6 - 2_000e6) = 87.5% > 80% → revert (unchanged gate).
        vm.expectRevert(
            abi.encodeWithSelector(LeveragedAeroManager.FastRedeemExceedsLtv.selector, uint256(8750), uint256(8000))
        );
        h.callFastRedeem(2_000e6, 0);

        // Smaller remainder keeps LTV under max: assetsOut = 1_000e6 → postLtv = 7_000/9_000 = 77.7% < 80%.
        h.callFastRedeem(1_000e6, 0);
        assertEq(mUsdc.totalRedeemed(), 1_000e6, "freed the remainder under the LTV cap");
    }

    // ── (d'') Levered book with debt AND idle: idle-first shrinks the collateral remainder enough
    //    to clear a postLtv gate that the OLD full-assetsOut gate would have breached. ──
    function test_leveredBookWithDebtAndIdle_idleFirstClearsPostLtv() public {
        MockFeed f1 = new MockFeed(1e8);
        MockSequencer seq = new MockSequencer();
        MockComptroller comp = new MockComptroller();
        h.setFeeds(address(f1), address(f1), address(f1), address(seq));
        h.setComptroller(address(comp));

        usdc.mint(address(h), 4_000e6); // idle
        mUsdc.setCBal(10_000e6);
        mCbBTC.setDebt(7_000e8); // 7_000e6 face
        h.setMaxLtvBps(8000);

        uint256 assetsOut = 2_000e6;
        uint256 idleShare = 2_000e6; // f = 1/2, idle 4_000e6

        // OLD: fromCollateral == 2_000e6 → postLtv = 7_000/8_000 = 87.5% > 80% → revert.
        vm.expectRevert(
            abi.encodeWithSelector(LeveragedAeroManager.FastRedeemExceedsLtv.selector, uint256(8750), uint256(8000))
        );
        h.callFastRedeem(assetsOut, 0);

        // NEW: idle covers the whole 2_000e6 (<= f×idle) → fromCollateral == 0 → gate skipped entirely.
        h.callFastRedeem(assetsOut, idleShare);
        assertEq(mUsdc.totalRedeemed(), 0, "idle fully funded the redeem; collateral & LTV gate untouched");
    }
}
