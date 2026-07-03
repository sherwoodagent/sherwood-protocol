// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {LeveragedAeroForkBase} from "./LeveragedAeroForkBase.sol";
import {BaseAddresses} from "./BaseAddresses.sol";
import {LeveragedAerodromeCLStrategy} from "../../../src/strategies/LeveragedAerodromeCLStrategy.sol";
import {LeveragedAeroValuation} from "../../../src/strategies/LeveragedAeroValuation.sol";
import {BaseStrategy} from "../../../src/strategies/BaseStrategy.sol";
import {IMoonwellMarket, ICToken} from "../../../src/interfaces/IMoonwellMarket.sol";
import {ICLPool, ICLSwapRouter} from "../../../src/interfaces/ISlipstream.sol";
import {TickMath} from "../../../src/libraries/TickMath.sol";

interface IERC721OwnerR {
    function ownerOf(uint256 tokenId) external view returns (address);
}

interface IAggR {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @dev Minimal share-ledger mock vault (mirrors the compound test's): ERC20 approve/transferFrom
///      + strategyMint/strategyBurn. Holds no USDC, so nav()'s vault-float term is 0.
contract MockVault {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    constructor(address initialHolder, uint256 initialShares) {
        balanceOf[initialHolder] = initialShares;
        totalSupply = initialShares;
    }

    /// @dev L7: strategy reads vault().asset() at init — must equal the configured USDC.
    function asset() external pure returns (address) {
        return BaseAddresses.USDC;
    }

    /// @dev Strategy reads vault().governor() for the live protocol-fee rate; 0 ⇒ no protocol fee.
    function governor() external pure returns (address) {
        return address(0);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "ERC20InsufficientAllowance");
        allowance[from][msg.sender] -= amount;
        require(balanceOf[from] >= amount, "ERC20InsufficientBalance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function strategyMint(address to, uint256 shares) external {
        balanceOf[to] += shares;
        totalSupply += shares;
    }

    function strategyBurn(uint256 shares) external {
        require(balanceOf[msg.sender] >= shares, "insufficient balance");
        balanceOf[msg.sender] -= shares;
        totalSupply -= shares;
    }
}

/// @title  LeveragedAeroCLRerangeFork
/// @notice Task 3.9 TDD: `rerange()` — recenter the levered CL position on the current tick
///         WITHOUT swapping (principal conserved; IL only ever realized on a true exit),
///         behind the same calm-gate as the valuation, leaving the position healthy.
///
///         Design: single-position recenter. A no-swap recenter leaves a remainder of one
///         borrowed leg (the collected token ratio can't match the new range and swapping is
///         forbidden). `LeveragedAeroValuation.netEquityUsdc` was extended (task 3.9) to price
///         idle cbBTC/WETH on the Chainlink basis, so the remainder is NAV-counted and the
///         recenter is NAV-neutral — no dual-position (`alt`) NFT needed (which would have to be
///         threaded through the safety-critical `nav()`/settle/redeem, all built around a single
///         `$.tokenId`). The Moonwell debt + collateral are untouched, so health is preserved.
///
///         The pool tick is moved via a bounded `sqrtPriceLimitX96` shove (NOT time) so the
///         48h Chainlink feeds never go stale and `nav()` stays computable. The happy-path shove
///         stays inside the 500-tick calm band; the calm-gate test shoves past it.
contract LeveragedAeroCLRerangeFork is LeveragedAeroForkBase {
    LeveragedAerodromeCLStrategy internal strategy;
    MockVault internal mockVault;

    address internal depositor;
    address internal feeRecipient;
    address internal proposer;
    address internal stranger;

    uint16 internal constant TARGET_LTV_BPS = 5000;
    uint16 internal constant MAX_LTV_BPS = 6500;
    uint16 internal constant MIN_HEALTH_BPS = 12000;
    uint16 internal constant MAX_SLIPPAGE_BPS = 100;

    uint256 internal constant PRINCIPAL = 50_000e6;
    uint256 internal constant DEPOSITOR_SHARES = PRINCIPAL * 1e6; // ERC-4626 virtual offset 1e6

    function setUp() public override {
        super.setUp();
        if (_skip) return;

        depositor = makeAddr("depositor");
        feeRecipient = makeAddr("feeRecipient");
        stranger = makeAddr("stranger");
        proposer = address(this);

        // Share-ledger vault holding no USDC: nav()'s vault float = 0; the depositor holds all
        // shares so a partial redeem's f = redeemShares/supply is well-defined.
        mockVault = new MockVault(depositor, DEPOSITOR_SHARES);

        address template = address(new LeveragedAerodromeCLStrategy());
        strategy = LeveragedAerodromeCLStrategy(payable(Clones.clone(template)));
        strategy.initialize(address(mockVault), proposer, abi.encode(_buildInitParams()));

        // Open the levered position.
        _fundUSDC(address(strategy), PRINCIPAL);
        vm.prank(address(mockVault));
        strategy.execute();
    }

    function _buildInitParams() internal view returns (LeveragedAerodromeCLStrategy.InitParams memory p) {
        // Fees = 0: rerange does NOT crystallize (no supply change, no realized PnL), so the fee
        // config is irrelevant here and a 0 fee keeps the mock vault entirely uninvolved.
        p = LeveragedAerodromeCLStrategy.InitParams({
            usdc: BaseAddresses.USDC,
            mUsdc: BaseAddresses.MOONWELL_MUSDC,
            mCbBTC: BaseAddresses.MOONWELL_MCBBTC,
            mWeth: BaseAddresses.MOONWELL_MWETH,
            comptroller: BaseAddresses.MOONWELL_COMPTROLLER,
            cbBTC: BaseAddresses.CBBTC,
            weth: BaseAddresses.WETH,
            pool: BaseAddresses.CBBTC_WETH_POOL,
            npm: BaseAddresses.SLIPSTREAM_NPM,
            gauge: BaseAddresses.CBBTC_WETH_GAUGE,
            swapRouter: BaseAddresses.SLIPSTREAM_CL_SWAP_ROUTER,
            cbBTCFeed: BaseAddresses.CHAINLINK_BTC_USD,
            wethFeed: BaseAddresses.CHAINLINK_ETH_USD,
            usdcFeed: BaseAddresses.CHAINLINK_USDC_USD,
            sequencerFeed: BaseAddresses.SEQUENCER_UPTIME_FEED,
            aeroUsdFeed: BaseAddresses.CHAINLINK_AERO_USD,
            maxDelay: 48 hours,
            gracePeriod: 1 hours,
            calmDeviationTicks: 500,
            twapWindow: 1800,
            tickSpacing: BaseAddresses.CBBTC_WETH_TICK_SPACING,
            targetLtvBps: TARGET_LTV_BPS,
            maxLtvBps: MAX_LTV_BPS,
            minHealthBps: MIN_HEALTH_BPS,
            maxSlippageBps: MAX_SLIPPAGE_BPS,
            managementFeeBps: 0,
            performanceFeeBps: 0,
            feeRecipient: feeRecipient
        });
    }

    /// @dev On-chain LTV (bps) from Moonwell state + Chainlink (mirrors the compound/deploy tests).
    function _ltvBps() internal view returns (uint256) {
        uint256 mUsdcBal = ICToken(BaseAddresses.MOONWELL_MUSDC).balanceOf(address(strategy));
        uint256 rate = ICToken(BaseAddresses.MOONWELL_MUSDC).exchangeRateStored();
        uint256 collateralUsdc = (mUsdcBal * rate) / 1e18;
        uint256 cbDebt = IMoonwellMarket(BaseAddresses.MOONWELL_MCBBTC).borrowBalanceStored(address(strategy));
        uint256 wethDebt = IMoonwellMarket(BaseAddresses.MOONWELL_MWETH).borrowBalanceStored(address(strategy));
        (, int256 btc,,,) = IAggR(BaseAddresses.CHAINLINK_BTC_USD).latestRoundData();
        (, int256 eth,,,) = IAggR(BaseAddresses.CHAINLINK_ETH_USD).latestRoundData();
        (, int256 usdc,,,) = IAggR(BaseAddresses.CHAINLINK_USDC_USD).latestRoundData();
        uint256 cbDebtUsdc = (cbDebt * uint256(btc) * 1e6) / (1e8 * uint256(usdc));
        uint256 wethDebtUsdc = (wethDebt * uint256(eth) * 1e6) / (1e18 * uint256(usdc));
        return ((cbDebtUsdc + wethDebtUsdc) * 10000) / collateralUsdc;
    }

    /// @dev Bounded in-band shove: sell WETH (token0) → cbBTC, stopping the swap at `targetTick`
    ///      via `sqrtPriceLimitX96` so the move lands deterministically (no unbounded free-fall).
    function _shoveToTick(int24 targetTick) internal {
        address shover = makeAddr("inband_shover");
        uint256 wethIn = 1_000e18; // generous; the sqrtPrice limit caps how much actually fills
        _fundWETH(shover, wethIn);
        vm.startPrank(shover);
        IERC20(WETH).approve(CL_ROUTER, wethIn);
        ICLSwapRouter(CL_ROUTER)
            .exactInputSingle(
                ICLSwapRouter.ExactInputSingleParams({
                tokenIn: WETH,
                tokenOut: CBBTC,
                tickSpacing: TICK_SPACING,
                recipient: shover,
                deadline: block.timestamp + 600,
                amountIn: wethIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: TickMath.getSqrtRatioAtTick(targetTick)
            })
            );
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 1: rerange recenters with NO swap → principal conserved, NAV-neutral, healthy.
    // ─────────────────────────────────────────────────────────────────────────

    function test_rerange_conservesPrincipalNoSwap() public {
        if (_skip) return;

        // Drift the pool tick 300 ticks DOWN (inside the 500-tick calm band) so the open
        // position becomes OFF-center — giving rerange something real to recenter.
        (, int24 tickStart,,,,) = ICLPool(POOL).slot0();
        _shoveToTick(tickStart - 300);
        (, int24 tickShoved,,,,) = ICLPool(POOL).slot0();
        assertLt(tickShoved, tickStart, "pool tick did not move down");
        assertGe(tickShoved, tickStart - 500, "shove left the calm band");

        uint256 tidBefore = strategy.layout().tokenId;
        int24 oldLower = strategy.layout().posTickLower;
        int24 oldUpper = strategy.layout().posTickUpper;
        uint256 navBefore = strategy.nav();
        assertGt(navBefore, 0, "navBefore should be > 0");

        // rerange leaves debt + collateral untouched (it never calls Moonwell) — snapshot to prove it.
        uint256 cbDebtBefore = IMoonwellMarket(BaseAddresses.MOONWELL_MCBBTC).borrowBalanceStored(address(strategy));
        uint256 wethDebtBefore = IMoonwellMarket(BaseAddresses.MOONWELL_MWETH).borrowBalanceStored(address(strategy));
        uint256 collatBefore = ICToken(BaseAddresses.MOONWELL_MUSDC).balanceOf(address(strategy));

        // Recenter (NO swap). minLiq0/minLiq1 = 0: the always-on maxSlippageBps mins + the
        // calm-gate are the real protection; the caller two-sided mins are an additional belt.
        vm.prank(proposer);
        strategy.rerange(0, 0);

        // (1) NAV conserved — no swap-loss; principal preserved. Tolerance covers the collected LP
        //     fees + the oracle-vs-pool split convexity realized on removal + dust (NO swap loss).
        uint256 navAfter = strategy.nav();
        assertApproxEqRel(navAfter, navBefore, 1e16, "NAV not conserved across the no-swap rerange"); // 1%

        // (2) The new range is RECENTERED: it straddles the current tick and differs from the old
        //     off-center range.
        (, int24 tickNow,,,,) = ICLPool(POOL).slot0();
        int24 newLower = strategy.layout().posTickLower;
        int24 newUpper = strategy.layout().posTickUpper;
        assertLt(newLower, tickNow, "new lower tick !< current tick");
        assertLt(tickNow, newUpper, "current tick !< new upper tick");
        assertTrue(newLower != oldLower || newUpper != oldUpper, "range was not recentered");

        // (3) Health preserved — debt + collateral are exactly unchanged, and LTV stays under cap
        //     (rerange would have reverted in `_assertHealthy` otherwise).
        assertEq(
            IMoonwellMarket(BaseAddresses.MOONWELL_MCBBTC).borrowBalanceStored(address(strategy)),
            cbDebtBefore,
            "cbBTC debt changed (rerange must not touch Moonwell)"
        );
        assertEq(
            IMoonwellMarket(BaseAddresses.MOONWELL_MWETH).borrowBalanceStored(address(strategy)),
            wethDebtBefore,
            "WETH debt changed (rerange must not touch Moonwell)"
        );
        assertEq(
            ICToken(BaseAddresses.MOONWELL_MUSDC).balanceOf(address(strategy)),
            collatBefore,
            "collateral changed (rerange must not touch Moonwell)"
        );
        assertLe(_ltvBps(), MAX_LTV_BPS, "post-rerange LTV exceeds maxLtvBps");

        // (4) A NEW tokenId was minted and staked in the gauge (Slipstream ticks are immutable).
        uint256 tidAfter = strategy.layout().tokenId;
        assertTrue(tidAfter != tidBefore && tidAfter != 0, "tokenId was not rotated to a recentered NFT");
        assertEq(IERC721OwnerR(NPM).ownerOf(tidAfter), GAUGE, "new NFT is not staked in the gauge");

        // (5) The no-swap recenter leaves a remainder of one borrowed leg idle — and it is
        //     NAV-counted (the NAV-conservation in (1) already proves it is not leaked).
        uint256 idleCb = IERC20(CBBTC).balanceOf(address(strategy));
        uint256 idleWeth = IERC20(WETH).balanceOf(address(strategy));
        assertTrue(idleCb > 0 || idleWeth > 0, "expected a remainder leg from the no-swap recenter");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 2: the calm-gate blocks rerange at a manipulated tick.
    // ─────────────────────────────────────────────────────────────────────────

    function test_rerange_calmGateReverts() public {
        if (_skip) return;

        // Unbounded large WETH shove drives spot ~100k+ ticks from the fresh-fork TWAP — far past
        // the 500-tick calm gate (same magnitude the valuation fork test uses for a breach).
        _shoveTick(2_000e18, true);

        vm.prank(proposer);
        vm.expectRevert(LeveragedAeroValuation.CalmGateBreached.selector);
        strategy.rerange(0, 0);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 3: only the proposer may rerange.
    // ─────────────────────────────────────────────────────────────────────────

    function test_rerange_onlyProposer() public {
        if (_skip) return;
        vm.prank(stranger);
        vm.expectRevert(BaseStrategy.NotProposer.selector);
        strategy.rerange(0, 0);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 4: a partial redeem AFTER a rerange is stayer-fair — the redeemer cannot
    //         skim the stayers' (1-f) share of the no-swap recenter's idle remainder.
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice rerange leaves a remainder of one borrowed leg idle, which `nav()` now prices.
    ///         The redeem path's residual sweep would otherwise hand a partial redeemer 100% of
    ///         that remainder (a ~(1-f)*remainder skim of stayers). With the idle-leg reservation
    ///         fix, the redeemer gets ~f*nav and the stayers' NAV is preserved.
    function test_rerange_thenPartialRedeem_stayerFair() public {
        if (_skip) return;

        // Drift 300 ticks (in-band) then recenter → leaves a non-trivial idle remainder leg.
        (, int24 tickStart,,,,) = ICLPool(POOL).slot0();
        _shoveToTick(tickStart - 300);
        vm.prank(proposer);
        strategy.rerange(0, 0);

        uint256 idleCb = IERC20(CBBTC).balanceOf(address(strategy));
        uint256 idleWeth = IERC20(WETH).balanceOf(address(strategy));
        assertTrue(idleCb > 0 || idleWeth > 0, "no remainder to test fairness on");

        uint256 navBeforeRedeem = strategy.nav();
        uint256 supplyBefore = mockVault.totalSupply();
        uint256 redeemShares = mockVault.balanceOf(depositor) / 10; // f = 10%
        // Fair redeemer share = f*nav (nav prices the idle remainder). The redeemer must NOT also
        // skim the stayers' (1-f) share of that remainder via the residual leg sweep.
        uint256 fairShare = (navBeforeRedeem * redeemShares) / supplyBefore;

        vm.prank(depositor);
        mockVault.approve(address(strategy), redeemShares);
        vm.prank(depositor);
        uint256 out = strategy.redeem(redeemShares, 0);

        // (1) Redeemer got ~f*nav (oracle-free exit slippage keeps it slightly under), NOT
        //     f*nav + (1-f)*remainder. Without the idle-leg reservation `out` would be ~2x fairShare
        //     here, so the `assertLe` cleanly catches a regression of the skim.
        assertApproxEqRel(out, fairShare, 0.05e18, "redeemer did not receive ~f*nav");
        assertLe(out, fairShare + fairShare / 20, "redeemer skimmed the stayers' idle-leg share");

        // (2) Stayer NAV preserved: the strategy NAV left behind ~= (1-f)*navBeforeRedeem.
        assertApproxEqRel(
            strategy.nav(), navBeforeRedeem - fairShare, 0.03e18, "stayer NAV not preserved after partial redeem"
        );
    }
}
