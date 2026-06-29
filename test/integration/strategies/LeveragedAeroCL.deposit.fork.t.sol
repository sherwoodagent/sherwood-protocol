// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {LeveragedAeroForkBase} from "./LeveragedAeroForkBase.sol";
import {BaseAddresses} from "./BaseAddresses.sol";
import {LeveragedAerodromeCLStrategy} from "../../../src/strategies/LeveragedAerodromeCLStrategy.sol";

/// @dev Minimal mock vault — implements ERC20 totalSupply + strategyMint for deposit tests.
contract MockVaultForDeposit {
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    constructor(address initialHolder, uint256 initialShares) {
        balanceOf[initialHolder] = initialShares;
        totalSupply = initialShares;
    }

    function strategyMint(address to, uint256 shares) external {
        balanceOf[to] += shares;
        totalSupply += shares;
    }

    function strategyBurn(uint256 shares) external {
        require(balanceOf[msg.sender] >= shares, "insufficient shares");
        balanceOf[msg.sender] -= shares;
        totalSupply -= shares;
    }
}

/// @title LeveragedAeroCLDepositFork
/// @notice Task 3.6 TDD: deposit + deployIdle fork tests.
contract LeveragedAeroCLDepositFork is LeveragedAeroForkBase {
    MockVaultForDeposit internal mockVault;
    LeveragedAerodromeCLStrategy internal strategy;

    address internal firstDepositor;
    address internal secondDepositor;
    address internal feeRecipient;
    address internal proposer;

    uint16 internal constant TARGET_LTV_BPS = 5000;
    uint16 internal constant MAX_LTV_BPS = 6500;
    uint16 internal constant MIN_HEALTH_BPS = 12000;
    uint16 internal constant MAX_SLIPPAGE_BPS = 100;
    uint16 internal constant MGMT_FEE_BPS = 100;
    uint16 internal constant PERF_FEE_BPS = 1000;

    uint256 internal constant PRINCIPAL = 50_000e6;
    // First depositor's shares: PRINCIPAL * 10**decimalsOffset / 1 = PRINCIPAL * 1e6
    uint256 internal constant FIRST_DEPOSITOR_SHARES = PRINCIPAL * 1e6;

    function setUp() public override {
        super.setUp();
        if (_skip) return;

        firstDepositor = makeAddr("firstDepositor");
        secondDepositor = makeAddr("secondDepositor");
        feeRecipient = makeAddr("feeRecipient");
        proposer = address(this);

        // MockVault: firstDepositor already holds shares from their 50k USDC deposit.
        mockVault = new MockVaultForDeposit(firstDepositor, FIRST_DEPOSITOR_SHARES);

        // Deploy strategy clone
        address template = address(new LeveragedAerodromeCLStrategy());
        address clone = Clones.clone(template);
        strategy = LeveragedAerodromeCLStrategy(payable(clone));
        strategy.initialize(address(mockVault), proposer, abi.encode(_buildInitParams()));

        // Fund strategy + execute to open the levered position
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
    // Test 1: deposit mints shares proportional to oracle NAV
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice A second depositor calling deposit() receives shares proportional to the
    ///         oracle NAV, and their USDC lands idle in the strategy.
    function test_deposit_mintsAtOracleNav() public {
        if (_skip) return;

        uint256 depositAmt = 1_000e6; // 1k USDC
        _fundUSDC(secondDepositor, depositAmt);

        uint256 navBefore = strategy.nav();
        assertGt(navBefore, 0, "nav should be > 0 after execute");

        uint256 supplyBefore = mockVault.totalSupply();
        uint256 usdcInStrategyBefore = IERC20(BaseAddresses.USDC).balanceOf(address(strategy));

        vm.startPrank(secondDepositor);
        IERC20(BaseAddresses.USDC).approve(address(strategy), depositAmt);
        uint256 shares = strategy.deposit(depositAmt, 0);
        vm.stopPrank();

        // shares should be approximately depositAmt * totalSupply / nav (proportional to existing)
        uint256 expectedShares = (depositAmt * supplyBefore) / navBefore;
        // allow 1% tolerance for oracle drift
        assertGe(shares, expectedShares * 9900 / 10000, "shares too low");
        assertLe(shares, expectedShares * 10100 / 10000, "shares too high");

        // USDC lands idle in the strategy (not pushed to vault)
        uint256 usdcInStrategyAfter = IERC20(BaseAddresses.USDC).balanceOf(address(strategy));
        assertEq(usdcInStrategyAfter, usdcInStrategyBefore + depositAmt, "USDC not idle in strategy");

        // Total supply in mockVault increased by shares
        assertEq(mockVault.totalSupply(), supplyBefore + shares, "totalSupply not updated");

        // secondDepositor received the shares
        assertEq(mockVault.balanceOf(secondDepositor), shares, "depositor did not receive shares");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 2: No phantom fee when NAV has not risen above HWM
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice With no NAV gain, crystallizeFees inside deposit should produce zero
    ///         performance fee shares for feeRecipient.
    function test_deposit_noPhantomFee() public {
        if (_skip) return;

        uint256 depositAmt = 1_000e6;
        _fundUSDC(secondDepositor, depositAmt);

        uint256 feeSharesBefore = mockVault.balanceOf(feeRecipient);

        vm.startPrank(secondDepositor);
        IERC20(BaseAddresses.USDC).approve(address(strategy), depositAmt);
        strategy.deposit(depositAmt, 0);
        vm.stopPrank();

        uint256 feeSharesAfter = mockVault.balanceOf(feeRecipient);
        uint256 feeSharesMinted = feeSharesAfter - feeSharesBefore;
        uint256 supplyTotal = mockVault.totalSupply();
        // fee shares should be < 1 bps of total supply (management over dt=0 is negligible)
        assertLt(feeSharesMinted, supplyTotal / 10000, "phantom performance fee charged");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 3: deposit reverts before execute (state check)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice deposit() must revert when the strategy is not in Executed state.
    function test_deposit_revertsBeforeExecute() public {
        if (_skip) return;

        // Deploy a fresh strategy (Pending state -- never executed)
        address template = address(new LeveragedAerodromeCLStrategy());
        address freshClone = Clones.clone(template);
        LeveragedAerodromeCLStrategy freshStrategy = LeveragedAerodromeCLStrategy(payable(freshClone));
        MockVaultForDeposit freshVault = new MockVaultForDeposit(firstDepositor, FIRST_DEPOSITOR_SHARES);
        freshStrategy.initialize(address(freshVault), proposer, abi.encode(_buildInitParams()));

        uint256 depositAmt = 1_000e6;
        _fundUSDC(secondDepositor, depositAmt);

        vm.startPrank(secondDepositor);
        IERC20(BaseAddresses.USDC).approve(address(freshStrategy), depositAmt);
        vm.expectRevert(abi.encodeWithSignature("NotExecuted()"));
        freshStrategy.deposit(depositAmt, 0);
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 4: deployIdle deploys idle USDC into the existing position
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice After a deposit lands idle USDC, deployIdle adds it to the levered
    ///         position: idle is near 0 afterwards, nav() is approximately conserved.
    function test_deployIdle_deploysAndStaysHealthy() public {
        if (_skip) return;

        uint256 idleAmt = 1_000e6; // 1k USDC idle after deposit
        _fundUSDC(secondDepositor, idleAmt);

        vm.startPrank(secondDepositor);
        IERC20(BaseAddresses.USDC).approve(address(strategy), idleAmt);
        strategy.deposit(idleAmt, 0);
        vm.stopPrank();

        // Confirm USDC is idle in strategy
        uint256 idleInStrategy = IERC20(BaseAddresses.USDC).balanceOf(address(strategy));
        assertGe(idleInStrategy, idleAmt, "USDC should be idle in strategy after deposit");

        uint256 navBefore = strategy.nav();

        // Read tokenId to read liquidity before
        uint256 tokenId_ = strategy.tokenId();
        (,,,,,,, uint128 liqBefore,,,,) =
            INonfungiblePositionManager_Dep(BaseAddresses.SLIPSTREAM_NPM).positions(tokenId_);

        // Deploy idle USDC into the position (proposer = address(this))
        strategy.deployIdle(idleAmt, 0);

        // Idle USDC should be gone from strategy (within dust)
        uint256 idleAfter = IERC20(BaseAddresses.USDC).balanceOf(address(strategy));
        assertLt(idleAfter, 1e6, "idle USDC should be near 0 after deployIdle");

        // NAV should be approximately conserved (within 2%)
        uint256 navAfter = strategy.nav();
        uint256 tolerance = navBefore / 50; // 2%
        assertGe(navAfter, navBefore - tolerance, "NAV dropped > 2% after deployIdle");
        assertLe(navAfter, navBefore + tolerance + idleAmt, "NAV rose unexpectedly");

        // Position liquidity should have increased
        (,,,,,,, uint128 liqAfter,,,,) =
            INonfungiblePositionManager_Dep(BaseAddresses.SLIPSTREAM_NPM).positions(tokenId_);
        assertGt(uint256(liqAfter), uint256(liqBefore), "liquidity should have increased");

        // NFT must be re-staked in the gauge (restake mirrors _mintAndStake)
        address ownerAfter = IERC721Minimal(BaseAddresses.SLIPSTREAM_NPM).ownerOf(tokenId_);
        assertEq(ownerAfter, BaseAddresses.CBBTC_WETH_GAUGE, "NFT not re-staked in gauge");
    }
}

/// @dev Minimal ERC-721 interface for `ownerOf` checks in fork tests.
interface IERC721Minimal {
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// @dev Minimal INonfungiblePositionManager interface for reading positions in tests.
interface INonfungiblePositionManager_Dep {
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
