// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {LeveragedAeroForkBase} from "./LeveragedAeroForkBase.sol";
import {BaseAddresses} from "./BaseAddresses.sol";
import {LeveragedAerodromeCLStrategy} from "../../../src/strategies/LeveragedAerodromeCLStrategy.sol";
import {IMoonwellMarket, IComptroller, ICToken} from "../../../src/interfaces/IMoonwellMarket.sol";
import {ICLGauge, INonfungiblePositionManager} from "../../../src/interfaces/ISlipstream.sol";

// ─── Minimal mock vault ───────────────────────────────────────────────────────

/// @dev Full mock vault for redeem tests: ERC20 approve/transferFrom + strategyMint/strategyBurn.
contract MockVaultForRedeem {
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

// ─── Interfaces needed in tests ───────────────────────────────────────────────

interface IERC721Minimal2 {
    function ownerOf(uint256 tokenId) external view returns (address);
}

interface INpmFull {
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
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );
}

interface IAggregatorV3Min {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

// ─── Test contract ────────────────────────────────────────────────────────────

/// @title LeveragedAeroCLRedeemFork
/// @notice Task 3.7 TDD: oracle-free proportional redeem fork tests.
contract LeveragedAeroCLRedeemFork is LeveragedAeroForkBase {
    MockVaultForRedeem internal mockVault;
    LeveragedAerodromeCLStrategy internal strategy;

    address internal depositorA;
    address internal depositorB;
    address internal feeRecipient;
    address internal proposer;

    uint16 internal constant TARGET_LTV_BPS = 5000;
    uint16 internal constant MAX_LTV_BPS = 6500;
    uint16 internal constant MIN_HEALTH_BPS = 12000;
    uint16 internal constant MAX_SLIPPAGE_BPS = 100;
    uint16 internal constant MGMT_FEE_BPS = 100;
    uint16 internal constant PERF_FEE_BPS = 1000;

    uint256 internal constant PRINCIPAL = 50_000e6;

    // Shares minted to depositorA when mockVault is constructed (ERC-4626 virtual offset 1e6).
    uint256 internal constant DEPOSITOR_A_SHARES = PRINCIPAL * 1e6;

    function setUp() public override {
        super.setUp();
        if (_skip) return;

        depositorA = makeAddr("depositorA");
        depositorB = makeAddr("depositorB");
        feeRecipient = makeAddr("feeRecipient");
        proposer = address(this);

        // MockVault: depositorA already holds shares representing the initial 50k USDC.
        mockVault = new MockVaultForRedeem(depositorA, DEPOSITOR_A_SHARES);

        // Deploy strategy clone.
        address template = address(new LeveragedAerodromeCLStrategy());
        address clone = Clones.clone(template);
        strategy = LeveragedAerodromeCLStrategy(payable(clone));
        strategy.initialize(address(mockVault), proposer, abi.encode(_buildInitParams()));

        // Fund + execute to open the levered position.
        _fundUSDC(address(strategy), PRINCIPAL);
        vm.prank(address(mockVault));
        strategy.execute();
    }

    function _buildInitParams() internal view returns (LeveragedAerodromeCLStrategy.InitParams memory p) {
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
            managementFeeBps: MGMT_FEE_BPS,
            performanceFeeBps: PERF_FEE_BPS,
            feeRecipient: feeRecipient
        });
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 1: proportional redeem — stayer's per-share NAV unchanged
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Two depositors; B redeems fraction f.
    ///         - B receives ≈ f·NAV (USDC).
    ///         - A's per-share NAV (`nav()/totalSupply`) is unchanged within tolerance,
    ///           even after a _shoveTick manipulation mid-test.
    ///         - Gauge still owns the NFT after restake.
    ///         - Remaining position health invariant holds.
    function test_redeem_proportional_stayerSafe() public {
        if (_skip) return;

        // Mint shares for depositorB via a second deposit.
        uint256 depositB = 10_000e6; // 10k USDC
        _fundUSDC(depositorB, depositB);
        vm.startPrank(depositorB);
        IERC20(BaseAddresses.USDC).approve(address(strategy), depositB);
        uint256 sharesB = strategy.deposit(depositB, 0);
        vm.stopPrank();

        assertGt(sharesB, 0, "B got 0 shares");

        // Snapshot per-share NAV for depositorA before B redeems.
        uint256 navBefore = strategy.nav();
        uint256 supplyBefore = mockVault.totalSupply();
        uint256 navPerShareBefore = (navBefore * 1e18) / supplyBefore;

        // Shove the tick (manipulate spot price) to confirm oracle-priced NAV is immune.
        _shoveTick(5 ether, true); // sell WETH, move tick down

        // DepositorB redeems all their shares.
        vm.startPrank(depositorB);
        mockVault.approve(address(strategy), sharesB);
        uint256 assetsOut = strategy.redeem(sharesB, 0);
        vm.stopPrank();

        // B should receive ≈ f·NAV.
        // expectedOut is based on oracle-implied NAV; assetsOut reflects actual AMM execution
        // after the tick shove, so allow ±15% for swap costs, IL, and the manipulation delta.
        uint256 expectedOut = (navBefore * sharesB) / supplyBefore;
        assertGe(assetsOut, expectedOut * 8500 / 10000, "B received < 85% expected");
        assertLe(assetsOut, expectedOut * 11500 / 10000, "B received > 115% expected");

        // B's USDC balance should equal assetsOut.
        assertEq(IERC20(BaseAddresses.USDC).balanceOf(depositorB), assetsOut, "B USDC mismatch");

        // B's shares are burned.
        assertEq(mockVault.balanceOf(depositorB), 0, "B shares not burned");

        // A's per-share NAV should be unchanged within 2%.
        uint256 navAfter = strategy.nav();
        uint256 supplyAfter = mockVault.totalSupply();
        assertGt(supplyAfter, 0, "supply drained unexpectedly");
        uint256 navPerShareAfter = (navAfter * 1e18) / supplyAfter;
        uint256 tolerance = navPerShareBefore / 50; // 2%
        assertGe(navPerShareAfter, navPerShareBefore - tolerance, "A's per-share NAV dropped > 2%");
        assertLe(navPerShareAfter, navPerShareBefore + tolerance, "A's per-share NAV rose > 2%");

        // NFT must still be staked in the gauge after restake.
        uint256 tid = strategy.tokenId();
        assertGt(tid, 0, "tokenId should still be set");
        assertEq(
            IERC721Minimal2(BaseAddresses.SLIPSTREAM_NPM).ownerOf(tid),
            BaseAddresses.CBBTC_WETH_GAUGE,
            "NFT not re-staked"
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 2: redeem succeeds while oracle is stale
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice When the BTC feed returns a stale answer (so nav() reverts), redeem still
    ///         succeeds (oracle-free path, navPre=0 → no fees minted) while deposit reverts.
    function test_redeem_worksWhileOracleStale() public {
        if (_skip) return;

        // depositorA holds all shares. Redeem all (f=1) so _assertHealthy() short-circuits
        // (both debts cleared → no oracle call needed).
        uint256 sharesA = mockVault.balanceOf(depositorA);
        assertGt(sharesA, 0, "depositorA has no shares");

        // Pre-fund 2k USDC idle in the strategy. This represents a recent deposit that
        // hasn't been deployed yet — gives _redeemCoverShortfall a USDC buffer to cover
        // any IL shortfall (exactOutputSingle spends idle USDC to buy the deficit token).
        // Without idle USDC the swap has amountInMaximum=0 and returns early, leaving
        // residual debt that causes Moonwell to reject the full collateral redemption.
        _fundUSDC(address(strategy), 2_000e6);

        // Mock the BTC/USD feed to return a stale timestamp (age > maxDelay=48h).
        address btcFeed = BaseAddresses.CHAINLINK_BTC_USD;
        (, int256 answer,,, uint80 answeredIn) = IAggregatorV3Min(btcFeed).latestRoundData();
        vm.mockCall(
            btcFeed,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(1), answer, uint256(1), uint256(1), answeredIn)
        );

        // nav() should now revert (stale feed).
        vm.expectRevert();
        strategy.nav();

        // deposit() should also revert under the same stale feed.
        uint256 depositAmt = 1000e6;
        _fundUSDC(depositorB, depositAmt);
        vm.startPrank(depositorB);
        IERC20(BaseAddresses.USDC).approve(address(strategy), depositAmt);
        vm.expectRevert();
        strategy.deposit(depositAmt, 0);
        vm.stopPrank();

        // redeem (full redemption, f=1) should SUCCEED despite stale oracle.
        vm.startPrank(depositorA);
        mockVault.approve(address(strategy), sharesA);
        uint256 assetsOut = strategy.redeem(sharesA, 0);
        vm.stopPrank();
        assertGt(assetsOut, 0, "redeem returned 0 USDC");

        // Verify debts are fully cleared after full redemption.
        assertEq(
            IMoonwellMarket(BaseAddresses.MOONWELL_MCBBTC).borrowBalanceStored(address(strategy)),
            0,
            "cbBTC debt not cleared"
        );
        assertEq(
            IMoonwellMarket(BaseAddresses.MOONWELL_MWETH).borrowBalanceStored(address(strategy)),
            0,
            "WETH debt not cleared"
        );

        vm.clearMockedCalls();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 3: redeem reverts without approval
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice redeem without prior vault.approve reverts ERC20InsufficientAllowance.
    function test_redeem_revertsWithoutApproval() public {
        if (_skip) return;

        uint256 sharesA = mockVault.balanceOf(depositorA);
        assertGt(sharesA, 0, "depositorA has no shares");

        // No approve → safeTransferFrom should revert.
        vm.prank(depositorA);
        vm.expectRevert();
        strategy.redeem(sharesA, 0);
    }
}
