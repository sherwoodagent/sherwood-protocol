// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {LeveragedAeroForkBase} from "./LeveragedAeroForkBase.sol";
import {BaseAddresses} from "./BaseAddresses.sol";
import {LeveragedAerodromeCLStrategy} from "../../../src/strategies/LeveragedAerodromeCLStrategy.sol";
import {Position} from "../../../src/interfaces/IPriceRouter.sol";

/// @title  LeveragedAeroCLDeployFork
/// @notice Task 3.1 TDD: deploy the skeleton, initialize with confirmed params,
///         assert config wiring + pre-deploy nav() == 0.
///
///         Fork is required because `_initialize` reads `Comptroller.markets(mUsdc)`
///         on-chain to validate the USDC collateral factor.  The test env-gates on
///         `TENDERLY_FORK_RPC_URL` (handled by `LeveragedAeroForkBase.setUp`).
///
///         Run locally:
///           forge test --match-path '*LeveragedAeroCL.deploy.fork.t.sol' -vvv
///         Without the env var every test returns a vm.skip pass.
contract LeveragedAeroCLDeployFork is LeveragedAeroForkBase {
    // ── Test actors ──
    address internal fakeVault;
    address internal fakeProposer;
    address internal feeRecipient;

    // ── The cloned + initialised strategy under test ──
    LeveragedAerodromeCLStrategy internal strategy;

    // ── Confirmed risk / fee params (from Global Constraints) ──
    uint16 internal constant TARGET_LTV_BPS = 5000; // 50 %
    uint16 internal constant MAX_LTV_BPS = 6500; // 65 %
    uint16 internal constant MIN_HEALTH_BPS = 12000; // 1.20×
    uint16 internal constant MAX_SLIPPAGE_BPS = 100; // 1 %
    uint16 internal constant MGMT_FEE_BPS = 100; // 1 %/yr
    uint16 internal constant PERF_FEE_BPS = 1000; // 10 % HWM

    function setUp() public override {
        super.setUp();
        if (_skip) return;

        fakeVault = makeAddr("vault");
        fakeProposer = address(this);
        feeRecipient = makeAddr("feeRecipient");

        // Deploy the strategy template (constructor locks _initialized on the template itself).
        address template = address(new LeveragedAerodromeCLStrategy());

        // Clone the template — the clone starts with _initialized = false.
        address clone = Clones.clone(template);
        strategy = LeveragedAerodromeCLStrategy(payable(clone));

        // Initialize with BaseAddresses + confirmed params.
        // _initialize reads Comptroller.markets(mUsdc) on-chain → fork required.
        strategy.initialize(fakeVault, fakeProposer, abi.encode(_buildInitParams()));
    }

    // ─────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────

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
            maxDelay: 48 hours, // generous for Tenderly vnet frozen timestamps
            gracePeriod: 1 hours,
            calmDeviationTicks: 500,
            twapWindow: 1800,
            tickSpacing: BaseAddresses.CBBTC_WETH_TICK_SPACING, // 100
            targetLtvBps: TARGET_LTV_BPS,
            maxLtvBps: MAX_LTV_BPS,
            minHealthBps: MIN_HEALTH_BPS,
            maxSlippageBps: MAX_SLIPPAGE_BPS,
            managementFeeBps: MGMT_FEE_BPS,
            performanceFeeBps: PERF_FEE_BPS,
            feeRecipient: feeRecipient
        });
    }

    // ─────────────────────────────────────────────────────────────
    // Tests
    // ─────────────────────────────────────────────────────────────

    /// @notice Risk params are stored correctly after initialization.
    function test_deploy_riskParamsStored() public {
        if (_skip) return;

        assertEq(strategy.targetLtvBps(), TARGET_LTV_BPS, "targetLtvBps");
        assertEq(strategy.maxLtvBps(), MAX_LTV_BPS, "maxLtvBps");
        assertEq(strategy.minHealthBps(), MIN_HEALTH_BPS, "minHealthBps");
        assertEq(strategy.maxSlippageBps(), MAX_SLIPPAGE_BPS, "maxSlippageBps");
    }

    /// @notice USDC collateral factor was read from Moonwell and stored as bps.
    ///         On Base, Moonwell's USDC CF is 88 % (8800 bps); validate it is in range.
    function test_deploy_usdcCollateralFactorRead() public {
        if (_skip) return;

        uint16 cfBps = strategy.usdcCollateralFactorBps();
        // CF must be > maxLtvBps (65%) and ≤ 100% (10000 bps).
        assertGt(cfBps, MAX_LTV_BPS, "CF must exceed maxLtvBps");
        assertLe(cfBps, 10000, "CF cannot exceed 100%");
        // On Base, Moonwell USDC CF = 88 % → 8800 bps.
        assertEq(cfBps, 8800, "expected USDC CF = 88% on Base");
    }

    /// @notice Address config wired correctly.
    function test_deploy_addressesWired() public {
        if (_skip) return;

        assertEq(strategy.usdc(), BaseAddresses.USDC, "usdc");
        assertEq(strategy.mUsdc(), BaseAddresses.MOONWELL_MUSDC, "mUsdc");
        assertEq(strategy.mCbBTC(), BaseAddresses.MOONWELL_MCBBTC, "mCbBTC");
        assertEq(strategy.mWeth(), BaseAddresses.MOONWELL_MWETH, "mWeth");
        assertEq(strategy.pool(), BaseAddresses.CBBTC_WETH_POOL, "pool");
        assertEq(strategy.gauge(), BaseAddresses.CBBTC_WETH_GAUGE, "gauge");
        assertEq(strategy.npm(), BaseAddresses.SLIPSTREAM_NPM, "npm");
        assertEq(strategy.tickSpacing(), BaseAddresses.CBBTC_WETH_TICK_SPACING, "tickSpacing");
    }

    /// @notice Fee params wired correctly.
    function test_deploy_feeParamsWired() public {
        if (_skip) return;

        assertEq(strategy.managementFeeBps(), MGMT_FEE_BPS, "managementFeeBps");
        assertEq(strategy.performanceFeeBps(), PERF_FEE_BPS, "performanceFeeBps");
        assertEq(strategy.feeRecipient(), feeRecipient, "feeRecipient");
    }

    /// @notice vault() and proposer() are correctly set by BaseStrategy.initialize.
    function test_deploy_vaultAndProposerSet() public {
        if (_skip) return;

        assertEq(strategy.vault(), fakeVault, "vault");
        assertEq(strategy.proposer(), fakeProposer, "proposer");
    }

    /// @notice tokenId is 0 after initialization — no active position.
    function test_deploy_tokenIdZero() public {
        if (_skip) return;

        assertEq(strategy.tokenId(), 0, "tokenId should be 0 pre-deploy");
    }

    /// @notice nav() returns 0 pre-deploy: no position, no idle USDC in vault or strategy.
    ///         This is the load-bearing TDD assertion for the skeleton.
    ///         fakeVault has no USDC (makeAddr) + strategy has no USDC → 0 + 0 = 0.
    function test_deploy_navIsZeroPreDeploy() public {
        if (_skip) return;

        // Sanity: vault has no USDC
        assertEq(IERC20(BaseAddresses.USDC).balanceOf(fakeVault), 0, "vault USDC should be 0");
        // Sanity: strategy has no USDC
        assertEq(IERC20(BaseAddresses.USDC).balanceOf(address(strategy)), 0, "strategy USDC should be 0");

        // Core assertion
        assertEq(strategy.nav(), 0, "nav() should be 0 pre-deploy");
    }

    /// @notice nav() includes idle USDC when no position is open (flat-book branch).
    function test_deploy_navIncludesIdleUsdc() public {
        if (_skip) return;

        // Deal idle USDC to the fake vault
        uint256 idleAmt = 1_000e6;
        _fundUSDC(fakeVault, idleAmt);

        uint256 n = strategy.nav();
        assertEq(n, idleAmt, "nav() should reflect vault idle USDC");
    }

    /// @notice positions() returns one entry with the correct venue, kind, and ref.
    function test_deploy_positionsArray() public {
        if (_skip) return;

        // import Position struct
        (address venue, bytes32 kind, bytes memory ref) = _decodePosition();

        assertEq(venue, BaseAddresses.CBBTC_WETH_POOL, "venue = pool");
        assertEq(kind, keccak256("LEVERAGED_AERO_CL"), "kind");

        // ref = abi.encode(gauge, mUsdc, mCbBTC, mWeth)
        (address encGauge, address encMUsdc, address encMCbBTC, address encMWeth) =
            abi.decode(ref, (address, address, address, address));
        assertEq(encGauge, BaseAddresses.CBBTC_WETH_GAUGE, "ref.gauge");
        assertEq(encMUsdc, BaseAddresses.MOONWELL_MUSDC, "ref.mUsdc");
        assertEq(encMCbBTC, BaseAddresses.MOONWELL_MCBBTC, "ref.mCbBTC");
        assertEq(encMWeth, BaseAddresses.MOONWELL_MWETH, "ref.mWeth");
    }

    /// @notice _execute() reverts NotImplemented (stub until Task 3.2).
    function test_deploy_executeRevertsNotImplemented() public {
        if (_skip) return;

        // Prank as vault — execute() is onlyVault
        vm.prank(fakeVault);
        vm.expectRevert(LeveragedAerodromeCLStrategy.NotImplemented.selector);
        strategy.execute();
    }

    // ─────────────────────────────────────────────────────────────
    // Internal helpers
    // ─────────────────────────────────────────────────────────────

    /// @dev Call strategy.positions() and return the first element's fields.
    ///      `Position` is imported from `IPriceRouter` — the same struct the strategy returns.
    function _decodePosition() internal view returns (address venue, bytes32 kind, bytes memory ref) {
        Position[] memory pos = strategy.positions();
        require(pos.length == 1, "expected 1 position");
        venue = pos[0].venue;
        kind = pos[0].kind;
        ref = pos[0].ref;
    }
}
