// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {LeveragedAeroForkBase} from "./LeveragedAeroForkBase.sol";
import {BaseAddresses} from "./BaseAddresses.sol";
import {LeveragedAerodromeCLStrategy} from "../../../src/strategies/LeveragedAerodromeCLStrategy.sol";
import {BaseStrategy} from "../../../src/strategies/BaseStrategy.sol";
import {IMoonwellMarket, ICToken} from "../../../src/interfaces/IMoonwellMarket.sol";
import {INonfungiblePositionManager} from "../../../src/interfaces/ISlipstream.sol";

// ─── Minimal mock vault (share ledger only; holds no USDC) ──────────────────────

/// @dev Mock vault for leverage tests: ERC20 approve/transferFrom + strategyMint/strategyBurn.
contract MockVaultForLeverage {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    constructor(address initialHolder, uint256 initialShares) {
        balanceOf[initialHolder] = initialShares;
        totalSupply = initialShares;
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

interface IAggLev {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

interface INpmPosLev {
    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            int24 tickSpacing,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 fg0,
            uint256 fg1,
            uint128 owed0,
            uint128 owed1
        );
}

/// @title  LeveragedAeroCLLeverageFork
/// @notice Task 3.10 TDD: `adjustLeverage()` (onlyProposer LTV retarget) + `deleverage()`
///         (permissionless health restore).
///
///         `adjustLeverage` retargets LTV on the debt side only (collateral untouched): lever UP
///         borrows the cbBTC/WETH delta and adds it to the CL position; lever DOWN unwinds the
///         matching CL fraction and repays the debt delta. `deleverage` is a public safety valve:
///         anyone may unwind + repay when our-oracle health < `minHealthBps`.
///
///         Health is priced on the SAME hardened-Chainlink basis as `_assertHealthy`
///         (`collateral_USDC × 1e4 / debt_USDC`). `_shoveTick` moves the POOL tick, not the
///         Chainlink feed, so it cannot change Chainlink-priced health; the unhealthy scenario is
///         driven by an adverse Chainlink PRICE move (mock the cbBTC feed UP → net-short debt rises
///         → health falls). That divergence (our feed vs Moonwell's own oracle) is the intended
///         deleverage trigger (spec §13).
contract LeveragedAeroCLLeverageFork is LeveragedAeroForkBase {
    MockVaultForLeverage internal mockVault;
    LeveragedAerodromeCLStrategy internal strategy;

    address internal depositorA;
    address internal feeRecipient;
    address internal proposer;
    address internal stranger;

    uint16 internal constant TARGET_LTV_BPS = 5000; // 50% open
    uint16 internal constant MAX_LTV_BPS = 6500; // 65%
    uint16 internal constant MIN_HEALTH_BPS = 12000; // 1.20×
    uint16 internal constant MAX_SLIPPAGE_BPS = 100; // 1%

    uint256 internal constant PRINCIPAL = 50_000e6;
    uint256 internal constant DEPOSITOR_A_SHARES = PRINCIPAL * 1e6; // ERC-4626 virtual offset 1e6

    function setUp() public override {
        super.setUp();
        if (_skip) return;

        depositorA = makeAddr("depositorA");
        feeRecipient = makeAddr("feeRecipient");
        stranger = makeAddr("stranger");
        proposer = address(this);

        mockVault = new MockVaultForLeverage(depositorA, DEPOSITOR_A_SHARES);

        address template = address(new LeveragedAerodromeCLStrategy());
        strategy = LeveragedAerodromeCLStrategy(payable(Clones.clone(template)));
        strategy.initialize(address(mockVault), proposer, abi.encode(_buildInitParams()));

        // Open the levered position at ~50% LTV.
        _fundUSDC(address(strategy), PRINCIPAL);
        vm.prank(address(mockVault));
        strategy.execute();
    }

    function _buildInitParams() internal view returns (LeveragedAerodromeCLStrategy.InitParams memory p) {
        // Fees = 0: adjustLeverage / deleverage never crystallize (no supply change, no realized
        // PnL), so the fee config is irrelevant here and a 0 fee keeps the mock vault uninvolved.
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

    // ─────────────────────────────────────────────────────────────
    // Helpers — collateral / debt / LTV / health on the Chainlink basis
    // ─────────────────────────────────────────────────────────────

    /// @dev Collateral + debt in USDC face (6dp) using the CURRENT (possibly mocked) Chainlink
    ///      feeds — mirrors `LeveragedAeroManager._readCollateralDebt` / `_assertHealthy`.
    function _collatDebt() internal view returns (uint256 collateralUsdc, uint256 debtUsdc) {
        uint256 mBal = ICToken(BaseAddresses.MOONWELL_MUSDC).balanceOf(address(strategy));
        uint256 rate = ICToken(BaseAddresses.MOONWELL_MUSDC).exchangeRateStored();
        collateralUsdc = (mBal * rate) / 1e18;
        uint256 cbDebt = IMoonwellMarket(BaseAddresses.MOONWELL_MCBBTC).borrowBalanceStored(address(strategy));
        uint256 wethDebt = IMoonwellMarket(BaseAddresses.MOONWELL_MWETH).borrowBalanceStored(address(strategy));
        (, int256 btc,,,) = IAggLev(BaseAddresses.CHAINLINK_BTC_USD).latestRoundData();
        (, int256 eth,,,) = IAggLev(BaseAddresses.CHAINLINK_ETH_USD).latestRoundData();
        (, int256 usdc,,,) = IAggLev(BaseAddresses.CHAINLINK_USDC_USD).latestRoundData();
        uint256 cbUsdc = (cbDebt * uint256(btc) * 1e6) / (1e8 * uint256(usdc));
        uint256 wethUsdc = (wethDebt * uint256(eth) * 1e6) / (1e18 * uint256(usdc));
        debtUsdc = cbUsdc + wethUsdc;
    }

    function _ltvBps() internal view returns (uint256) {
        (uint256 c, uint256 d) = _collatDebt();
        return (d * 10000) / c;
    }

    function _healthBps() internal view returns (uint256) {
        (uint256 c, uint256 d) = _collatDebt();
        return d == 0 ? type(uint256).max : (c * 10000) / d;
    }

    function _liquidity() internal view returns (uint128 liq) {
        (,,,,,,, liq,,,,) = INpmPosLev(BaseAddresses.SLIPSTREAM_NPM).positions(strategy.tokenId());
    }

    /// @dev Mock the cbBTC (BTC/USD) feed to `num/den` × its real answer, preserving the real
    ///      (fresh) round metadata so the hardened staleness/completeness checks still pass.
    ///      Simulates an adverse price move against the net-short cbBTC debt.
    function _mockBtcScaled(uint256 num, uint256 den) internal {
        address feed = BaseAddresses.CHAINLINK_BTC_USD;
        (uint80 rid, int256 ans, uint256 startedAt, uint256 updatedAt, uint80 air) = IAggLev(feed).latestRoundData();
        int256 scaled = (ans * int256(num)) / int256(den);
        vm.mockCall(
            feed, abi.encodeWithSignature("latestRoundData()"), abi.encode(rid, scaled, startedAt, updatedAt, air)
        );
    }

    // ─────────────────────────────────────────────────────────────
    // adjustLeverage — lever UP
    // ─────────────────────────────────────────────────────────────

    /// @notice Open ~50%, adjustLeverage(6000) → measured LTV ≈ 60%, position healthy + staked.
    function test_adjustLeverage_leversUpToTarget() public {
        if (_skip) return;

        uint256 ltvBefore = _ltvBps();
        assertApproxEqAbs(ltvBefore, TARGET_LTV_BPS, 400, "open LTV not ~50%");

        uint256 cbDebtBefore = IMoonwellMarket(BaseAddresses.MOONWELL_MCBBTC).borrowBalanceStored(address(strategy));
        uint256 wethDebtBefore = IMoonwellMarket(BaseAddresses.MOONWELL_MWETH).borrowBalanceStored(address(strategy));
        uint128 liqBefore = _liquidity();
        uint256 tid = strategy.tokenId();

        vm.prank(proposer);
        strategy.adjustLeverage(6000, 0, 0);

        // LTV retargeted to ~60%.
        assertApproxEqAbs(_ltvBps(), 6000, 400, "LTV did not retarget to ~60%");

        // Lever UP borrowed more of both legs and grew CL liquidity.
        assertGt(
            IMoonwellMarket(BaseAddresses.MOONWELL_MCBBTC).borrowBalanceStored(address(strategy)),
            cbDebtBefore,
            "cbBTC debt did not grow on lever-up"
        );
        assertGt(
            IMoonwellMarket(BaseAddresses.MOONWELL_MWETH).borrowBalanceStored(address(strategy)),
            wethDebtBefore,
            "WETH debt did not grow on lever-up"
        );
        assertGt(_liquidity(), liqBefore, "CL liquidity did not grow on lever-up");

        // Same NFT, still staked, still healthy (≤ maxLtv).
        assertEq(strategy.tokenId(), tid, "tokenId changed");
        assertEq(
            IERC20Owner(BaseAddresses.SLIPSTREAM_NPM).ownerOf(tid), BaseAddresses.CBBTC_WETH_GAUGE, "NFT not staked"
        );
        assertLe(_ltvBps(), MAX_LTV_BPS, "post lever-up LTV exceeds maxLtv");
        assertGe(_healthBps(), MIN_HEALTH_BPS, "post lever-up health below min");
    }

    // ─────────────────────────────────────────────────────────────
    // adjustLeverage — lever DOWN
    // ─────────────────────────────────────────────────────────────

    /// @notice Open ~50%, adjustLeverage(4000) → measured LTV ≈ 40%, debt repaid, healthy.
    function test_adjustLeverage_leversDownToTarget() public {
        if (_skip) return;

        uint256 cbDebtBefore = IMoonwellMarket(BaseAddresses.MOONWELL_MCBBTC).borrowBalanceStored(address(strategy));
        uint256 wethDebtBefore = IMoonwellMarket(BaseAddresses.MOONWELL_MWETH).borrowBalanceStored(address(strategy));
        uint256 collatBefore = ICToken(BaseAddresses.MOONWELL_MUSDC).balanceOf(address(strategy));
        uint256 tid = strategy.tokenId();

        vm.prank(proposer);
        strategy.adjustLeverage(4000, 0, 0);

        // LTV retargeted down to ~40%.
        assertApproxEqAbs(_ltvBps(), 4000, 400, "LTV did not retarget to ~40%");

        // Lever DOWN repaid part of both debts; collateral is untouched (lever-down never redeems it).
        assertLt(
            IMoonwellMarket(BaseAddresses.MOONWELL_MCBBTC).borrowBalanceStored(address(strategy)),
            cbDebtBefore,
            "cbBTC debt did not shrink on lever-down"
        );
        assertLt(
            IMoonwellMarket(BaseAddresses.MOONWELL_MWETH).borrowBalanceStored(address(strategy)),
            wethDebtBefore,
            "WETH debt did not shrink on lever-down"
        );
        assertApproxEqAbs(
            ICToken(BaseAddresses.MOONWELL_MUSDC).balanceOf(address(strategy)),
            collatBefore,
            collatBefore / 1000,
            "collateral changed materially on lever-down"
        );

        // Position remains open + staked + healthy.
        assertEq(strategy.tokenId(), tid, "tokenId changed");
        assertEq(
            IERC20Owner(BaseAddresses.SLIPSTREAM_NPM).ownerOf(tid), BaseAddresses.CBBTC_WETH_GAUGE, "NFT not staked"
        );
        assertLe(_ltvBps(), MAX_LTV_BPS, "post lever-down LTV exceeds maxLtv");
        assertGe(_healthBps(), MIN_HEALTH_BPS, "post lever-down health below min");
    }

    // ─────────────────────────────────────────────────────────────
    // adjustLeverage — guards
    // ─────────────────────────────────────────────────────────────

    /// @notice adjustLeverage above maxLtvBps reverts TargetLtvExceedsMax (checked in the entrypoint).
    function test_adjustLeverage_revertsAboveMax() public {
        if (_skip) return;
        vm.prank(proposer);
        vm.expectRevert(LeveragedAerodromeCLStrategy.TargetLtvExceedsMax.selector);
        strategy.adjustLeverage(7000, 0, 0); // > maxLtv 6500
    }

    /// @notice Only the proposer may adjustLeverage.
    function test_adjustLeverage_onlyProposer() public {
        if (_skip) return;
        vm.prank(stranger);
        vm.expectRevert(BaseStrategy.NotProposer.selector);
        strategy.adjustLeverage(6000, 0, 0);
    }

    // ─────────────────────────────────────────────────────────────
    // deleverage — permissionless
    // ─────────────────────────────────────────────────────────────

    /// @notice A fresh, healthy position cannot be deleveraged (no-op safety valve).
    function test_deleverage_revertsWhenHealthy() public {
        if (_skip) return;
        assertGe(_healthBps(), MIN_HEALTH_BPS, "fresh position should be healthy");
        // Even the proposer cannot deleverage a healthy position.
        vm.prank(proposer);
        vm.expectRevert(LeveragedAerodromeCLStrategy.HealthyNoDeleverage.selector);
        strategy.deleverage(0);
    }

    /// @notice An adverse cbBTC price move pushes our-oracle health < minHealthBps; ANY caller
    ///         (here a non-proposer stranger) may deleverage to restore health ≥ minHealthBps.
    function test_deleverage_restoresHealthWhenUnhealthy() public {
        if (_skip) return;

        // Sanity: healthy before the price move.
        assertGe(_healthBps(), MIN_HEALTH_BPS, "should start healthy");

        // Adverse move: mock the BTC/USD feed 3× (net-short cbBTC debt value triples) → health falls.
        _mockBtcScaled(3, 1);
        uint256 healthUnhealthy = _healthBps();
        assertLt(healthUnhealthy, MIN_HEALTH_BPS, "mock did not push health below min");

        uint256 cbDebtBefore = IMoonwellMarket(BaseAddresses.MOONWELL_MCBBTC).borrowBalanceStored(address(strategy));
        uint256 wethDebtBefore = IMoonwellMarket(BaseAddresses.MOONWELL_MWETH).borrowBalanceStored(address(strategy));

        // A NON-PROPOSER (stranger) calls the permissionless safety valve.
        vm.prank(stranger);
        strategy.deleverage(0);

        // Health restored to ≥ minHealthBps (measured under the still-mocked feed).
        uint256 healthAfter = _healthBps();
        assertGe(healthAfter, MIN_HEALTH_BPS, "deleverage did not restore health to >= min");
        assertGt(healthAfter, healthUnhealthy, "deleverage did not improve health");

        // Debt was actually repaid down (both legs).
        assertLt(
            IMoonwellMarket(BaseAddresses.MOONWELL_MCBBTC).borrowBalanceStored(address(strategy)),
            cbDebtBefore,
            "cbBTC debt not repaid by deleverage"
        );
        assertLt(
            IMoonwellMarket(BaseAddresses.MOONWELL_MWETH).borrowBalanceStored(address(strategy)),
            wethDebtBefore,
            "WETH debt not repaid by deleverage"
        );

        // Now-healthy position: a second deleverage reverts HealthyNoDeleverage.
        vm.prank(stranger);
        vm.expectRevert(LeveragedAerodromeCLStrategy.HealthyNoDeleverage.selector);
        strategy.deleverage(0);

        vm.clearMockedCalls();
    }
}

interface IERC20Owner {
    function ownerOf(uint256 tokenId) external view returns (address);
}
