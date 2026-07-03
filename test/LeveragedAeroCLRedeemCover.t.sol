// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {LeveragedAerodromeCLStrategy} from "../src/strategies/LeveragedAerodromeCLStrategy.sol";
import {LeveragedAeroManager} from "../src/strategies/LeveragedAeroManager.sol";
import {ICLSwapRouter} from "../src/interfaces/ISlipstream.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Minimal ERC-20 with test-only mint / burn (no allowances checked — the strategy
// uses forceApprove but our mock market/router pull via burn/transfer directly).
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
// Mock Moonwell market — records repays; borrowBalanceStored is fully controllable.
// ─────────────────────────────────────────────────────────────────────────────

contract MockMarket {
    MockToken public underlying;
    uint256 public debt; // borrowBalanceStored
    uint256 public totalRepaid;

    constructor(MockToken u) {
        underlying = u;
    }

    function setDebt(uint256 d) external {
        debt = d;
    }

    function borrowBalanceStored(address) external view returns (uint256) {
        return debt;
    }

    function repayBorrow(uint256 amt) external returns (uint256) {
        // Consume the repaid underlying from the caller, like the real market.
        underlying.burn(msg.sender, amt);
        totalRepaid += amt;
        debt -= amt;
        return 0;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Mock mUSDC — redeemUnderlying mints the freed USDC into the strategy (the
// redeemer's collateral budget).
// ─────────────────────────────────────────────────────────────────────────────

contract MockCUsdc {
    MockToken public usdc;
    address public strategy;
    uint256 public cBal; // mUSDC balance held by the strategy
    uint256 public exchangeRate = 1e18;

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
        // Free `amt` USDC to the strategy, burning the equivalent mUSDC face.
        cBal -= amt; // 1:1 at rate 1e18
        usdc.mint(strategy, amt);
        return 0;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Mock CL swap router — mirrors exactOutputSingle (buy tokenOut) and
// exactInputSingle (sell leg → USDC). `price` = USDC-in per 1 unit tokenOut.
// exactOutputSingle reverts if the required USDC exceeds amountInMaximum, exactly
// like the real router — this is the fail-safe the fix relies on.
// ─────────────────────────────────────────────────────────────────────────────

contract MockRouter {
    MockToken public usdc;
    uint256 public price = 1; // USDC per unit tokenOut (exact-output leg)

    error AmountInTooHigh();

    constructor(MockToken u) {
        usdc = u;
    }

    function setPrice(uint256 p) external {
        price = p;
    }

    function exactOutputSingle(ICLSwapRouter.ExactOutputSingleParams calldata p) external returns (uint256 amountIn) {
        amountIn = p.amountOut * price;
        if (amountIn > p.amountInMaximum) revert AmountInTooHigh();
        usdc.burn(msg.sender, amountIn); // pull USDC in
        MockToken(p.tokenOut).mint(msg.sender, p.amountOut); // deliver tokenOut
    }

    function exactInputSingle(ICLSwapRouter.ExactInputSingleParams calldata p) external returns (uint256 amountOut) {
        // Sell tokenIn 1:1 for USDC (no residual legs in these tests → never hit with amt>0).
        MockToken(p.tokenIn).burn(msg.sender, p.amountIn);
        amountOut = p.amountIn;
        usdc.mint(msg.sender, amountOut);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Harness — wires diamond storage for a FLAT-BOOK redeem (tokenId == 0 skips the
// CL unwind), so the redeem path reduces to: repay-from-collected → collateral
// redeem → IL-cover → residual sweep. Lets us exercise the partial-branch cover
// cap in isolation.
// ─────────────────────────────────────────────────────────────────────────────

contract RedeemHarness is LeveragedAerodromeCLStrategy {
    function callRedeemUnwind(uint256 shares, uint256 supply) external returns (uint256) {
        return LeveragedAeroManager.redeemUnwindImpl(shares, supply);
    }
}

/// @title  LeveragedAeroCLRedeemCoverTest
/// @notice Offline unit tests for the partial-redeem IL-cover budget cap
///         (stayer-idle protection). Flat book (tokenId==0) isolates the cover step.
contract LeveragedAeroCLRedeemCoverTest is Test {
    uint256 private constant STRAT_BASE = uint256(0x405ae0b144079093e970849fdffdcb2a514e44968598c6c5c73444496e844900);
    // Diamond field slots (verified by storage probe): usdc+0, mUsdc+1, mCbBTC+2,
    // mWeth+3, cbBTC+4, weth+5, swapRouter+16, tokenId+18.
    uint256 private constant SLOT_USDC = STRAT_BASE + 0;
    uint256 private constant SLOT_MUSDC = STRAT_BASE + 1;
    uint256 private constant SLOT_MCBBTC = STRAT_BASE + 2;
    uint256 private constant SLOT_MWETH = STRAT_BASE + 3;
    uint256 private constant SLOT_CBBTC = STRAT_BASE + 4;
    uint256 private constant SLOT_WETH = STRAT_BASE + 5;
    uint256 private constant SLOT_SWAPROUTER = STRAT_BASE + 16;
    uint256 private constant SLOT_TOKENID = STRAT_BASE + 18;

    RedeemHarness private h;
    MockToken private usdc;
    MockToken private cbBTC;
    MockToken private weth;
    MockMarket private mCbBTC;
    MockMarket private mWeth;
    MockCUsdc private mUsdc;
    MockRouter private router;

    function setUp() public {
        h = new RedeemHarness();
        usdc = new MockToken("USDC");
        cbBTC = new MockToken("cbBTC");
        weth = new MockToken("WETH");
        mCbBTC = new MockMarket(cbBTC);
        mWeth = new MockMarket(weth);
        mUsdc = new MockCUsdc(usdc);
        router = new MockRouter(usdc);
        mUsdc.setStrategy(address(h));

        _store(SLOT_USDC, address(usdc));
        _store(SLOT_MUSDC, address(mUsdc));
        _store(SLOT_MCBBTC, address(mCbBTC));
        _store(SLOT_MWETH, address(mWeth));
        _store(SLOT_CBBTC, address(cbBTC));
        _store(SLOT_WETH, address(weth));
        _store(SLOT_SWAPROUTER, address(router));
        // tokenId defaults to 0 (flat book) — no CL unwind.

        // No WETH debt in these tests.
        mWeth.setDebt(0);
    }

    // ── Test 1 — regression: cover that would exceed the redeemer's budget REVERTS,
    //    never consuming stayer idle. ──────────────────────────────────────────────
    //
    // Setup: f = 1/2. Pre-existing idle = 10_000e6 → stayersIdle = 5_000e6.
    // Collateral freed on redeem = f * 4_000e6 = 2_000e6. cbShort = f * debt = 1_000
    // (cbBTC 8dp units). Redeemer budget = (10_000e6 + 2_000e6) - 5_000e6 = 7_000e6.
    // Set an inflated price so the cover needs > 7_000e6 → exactOutputSingle reverts →
    // whole redeem reverts. Stayer idle is untouched (revert rolls back all state).
    function test_partialRedeem_coverExceedsBudget_reverts() public {
        usdc.mint(address(h), 10_000e6); // pre-existing idle
        mCbBTC.setDebt(2_000); // f=1/2 → cbShort = 1_000
        mUsdc.setCBal(4_000e6); // f=1/2 → frees 2_000e6

        // Budget = 7_000e6. Price 8_000 → need 1_000 * 8_000 = 8_000_000e0 = 8_000e0?? keep math simple:
        // amountOut = cbShort = 1_000 (8dp units). price = 8_000_000 (USDC per unit) → amountIn = 8e9 = 8_000e6 > 7_000e6.
        router.setPrice(8_000_000);

        uint256 idleShareOfStayers = 5_000e6;
        assertEq(usdc.balanceOf(address(h)), 10_000e6, "pre-state");

        vm.expectRevert(MockRouter.AmountInTooHigh.selector);
        h.callRedeemUnwind(1, 2);

        // Revert rolled back — stayers' idle (>= 5_000e6) is intact.
        assertEq(usdc.balanceOf(address(h)), 10_000e6, "stayer idle consumed");
        assertGe(usdc.balanceOf(address(h)), idleShareOfStayers, "stayer idle share lost");
    }

    // ── Test 2 — conservation: a genuine small IL shortfall at a fair price still
    //    settles, and stayers keep >= (1-f) of idle USDC. ───────────────────────────
    function test_partialRedeem_genuineShortfall_succeeds_stayersKeepIdle() public {
        uint256 idle = 10_000e6;
        usdc.mint(address(h), idle); // pre-existing idle
        mCbBTC.setDebt(2_000); // f=1/2 → cbShort = 1_000
        mUsdc.setCBal(4_000e6); // f=1/2 → frees 2_000e6

        // Fair price: cover 1_000 units at 1 USDC/unit = 1_000 USDC → well under budget 7_000e6.
        router.setPrice(1);

        uint256 stayersIdle = idle - Math.mulDiv(idle, 1, 2); // 5_000e6
        uint256 out = h.callRedeemUnwind(1, 2);

        // Redeemer receives usdcFinal - stayersIdle. usdcFinal = 10_000e6 + 2_000e6 (freed) - 1_000 (cover).
        uint256 usdcFinal = 12_000e6 - 1_000;
        assertEq(out, usdcFinal - stayersIdle, "redeemer payout formula");
        // Strategy still holds >= (1-f) of the original idle for stayers.
        assertGe(usdc.balanceOf(address(h)), stayersIdle, "stayers lost idle");
        // Cover actually repaid the shortfall.
        assertEq(mCbBTC.totalRepaid(), 1_000, "shortfall not covered");
    }

    // ── Test 3 — no shortfall: healthy partial redeem needs no cover, stayers keep idle. ─
    function test_partialRedeem_noShortfall_noCover() public {
        uint256 idle = 10_000e6;
        usdc.mint(address(h), idle);
        // cbBTC debt fully covered by held cbBTC: give the strategy enough cbBTC balance.
        mCbBTC.setDebt(2_000);
        cbBTC.mint(address(h), 4_000); // f=1/2 budget = 2_000 >= cbDebtRepay(1_000) → no shortfall
        mUsdc.setCBal(4_000e6);
        router.setPrice(1);

        uint256 stayersIdle = idle - Math.mulDiv(idle, 1, 2);
        h.callRedeemUnwind(1, 2);

        assertEq(mCbBTC.totalRepaid(), 1_000, "expected direct repay of f*debt");
        assertGe(usdc.balanceOf(address(h)), stayersIdle, "stayers lost idle");
    }

    function _store(uint256 slot, address a) private {
        vm.store(address(h), bytes32(slot), bytes32(uint256(uint160(a))));
    }
}
