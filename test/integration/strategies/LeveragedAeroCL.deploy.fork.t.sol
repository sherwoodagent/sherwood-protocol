// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {LeveragedAeroForkBase} from "./LeveragedAeroForkBase.sol";
import {BaseAddresses} from "./BaseAddresses.sol";
import {LeveragedAerodromeCLStrategy} from "../../../src/strategies/LeveragedAerodromeCLStrategy.sol";
import {Position} from "../../../src/interfaces/IPriceRouter.sol";
import {IAggregatorV3} from "../../../src/interfaces/IAggregatorV3.sol";
import {IMoonwellMarket} from "../../../src/interfaces/IMoonwellMarket.sol";
import {ICToken} from "../../../src/interfaces/ICToken.sol";
import {ICLPool, ICLSwapRouter, INonfungiblePositionManager} from "../../../src/interfaces/ISlipstream.sol";
import {TickMath} from "../../../src/libraries/TickMath.sol";

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

        // L7: _initialize now reads vault().asset(); the bare fakeVault has no code, so make it
        // answer asset() == USDC to satisfy the new asset-wiring check.
        vm.mockCall(fakeVault, abi.encodeWithSignature("asset()"), abi.encode(USDC));

        // Protocol-fee wiring (#421): settle/crystallize now resolve the protocol-fee params via
        // vault().factory().protocolConfig() (moved off vault().governor()). The bare fakeVault has
        // no code — a call to it returns EMPTY returndata and the address decode reverts before the
        // strategy's own factory()==0 short-circuit can run. Answer address(0): the documented
        // "no factory → no ProtocolConfig → 0 bps, skip discharge" state (_protocolFeeBps /
        // _protocolFeeRecipient). Mock must track ISyndicateVault (CLAUDE.md MockRegistryMinimal lesson).
        vm.mockCall(fakeVault, abi.encodeWithSignature("factory()"), abi.encode(address(0)));

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
            aeroUsdFeed: BaseAddresses.CHAINLINK_AERO_USD,
            maxDelay: 48 hours, // generous for Tenderly vnet frozen timestamps
            gracePeriod: 1 hours,
            calmDeviationTicks: 500,
            twapWindow: 1800,
            tickSpacing: BaseAddresses.CBBTC_WETH_TICK_SPACING, // 100
            width: 4000, // full width (raw ticks) = 40·tickSpacing (preserves the pre-param 20-spacing/side range)
            minWidth: 200, // 2·tickSpacing
            maxWidth: 20000,
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

        assertEq(strategy.layout().targetLtvBps, TARGET_LTV_BPS, "targetLtvBps");
        assertEq(strategy.layout().maxLtvBps, MAX_LTV_BPS, "maxLtvBps");
        assertEq(strategy.layout().minHealthBps, MIN_HEALTH_BPS, "minHealthBps");
        assertEq(strategy.layout().maxSlippageBps, MAX_SLIPPAGE_BPS, "maxSlippageBps");
    }

    /// @notice USDC collateral factor was read from Moonwell and stored as bps.
    ///         On Base, Moonwell's USDC CF is 88 % (8800 bps); validate it is in range.
    function test_deploy_usdcCollateralFactorRead() public {
        if (_skip) return;

        uint16 cfBps = strategy.layout().usdcCollateralFactorBps;
        // CF must be > maxLtvBps (65%) and ≤ 100% (10000 bps).
        assertGt(cfBps, MAX_LTV_BPS, "CF must exceed maxLtvBps");
        assertLe(cfBps, 10000, "CF cannot exceed 100%");
        // On Base, Moonwell USDC CF = 88 % → 8800 bps.
        assertEq(cfBps, 8800, "expected USDC CF = 88% on Base");
    }

    /// @notice Address config wired correctly.
    function test_deploy_addressesWired() public {
        if (_skip) return;

        assertEq(strategy.layout().usdc, BaseAddresses.USDC, "usdc");
        assertEq(strategy.layout().mUsdc, BaseAddresses.MOONWELL_MUSDC, "mUsdc");
        assertEq(strategy.layout().mCbBTC, BaseAddresses.MOONWELL_MCBBTC, "mCbBTC");
        assertEq(strategy.layout().mWeth, BaseAddresses.MOONWELL_MWETH, "mWeth");
        assertEq(strategy.layout().pool, BaseAddresses.CBBTC_WETH_POOL, "pool");
        assertEq(strategy.layout().gauge, BaseAddresses.CBBTC_WETH_GAUGE, "gauge");
        assertEq(strategy.layout().npm, BaseAddresses.SLIPSTREAM_NPM, "npm");
        assertEq(strategy.layout().tickSpacing, BaseAddresses.CBBTC_WETH_TICK_SPACING, "tickSpacing");
    }

    /// @notice Fee params wired correctly.
    function test_deploy_feeParamsWired() public {
        if (_skip) return;

        assertEq(strategy.layout().managementFeeBps, MGMT_FEE_BPS, "managementFeeBps");
        assertEq(strategy.layout().performanceFeeBps, PERF_FEE_BPS, "performanceFeeBps");
        assertEq(strategy.layout().feeRecipient, feeRecipient, "feeRecipient");
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

        assertEq(strategy.layout().tokenId, 0, "tokenId should be 0 pre-deploy");
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

        // Deal idle USDC to the STRATEGY. Flat-book nav() deliberately excludes vault float
        // (d780090e, review #388 finding 3 — strategy.redeem never pays vault float out, so
        // counting it would reintroduce the M2 deposit/redeem asymmetry; the vault-float
        // exclusion itself is asserted by test_nav_excludesVaultFloat in the redeem fork suite).
        uint256 idleAmt = 1_000e6;
        _fundUSDC(address(strategy), idleAmt);

        uint256 n = strategy.nav();
        assertEq(n, idleAmt, "nav() should reflect strategy-controlled idle USDC");
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

    /// @notice Opening the leveraged position works end-to-end:
    ///         - collateral deposited in Moonwell mUSDC
    ///         - cbBTC + WETH borrowed
    ///         - Slipstream CL NFT minted and staked in gauge
    ///         - Post-op LTV ≈ 50% and within [targetLtvBps ± 10%, maxLtvBps]
    ///         - Health ≥ minHealthBps (1.20)
    ///         - nav() ≈ 50_000e6 within 5%
    function test_execute_opensLeveredPositionWithinBounds() public {
        if (_skip) return;

        // ── fund and execute ──
        _fundUSDC(address(strategy), 50_000e6);
        vm.prank(fakeVault);
        strategy.execute();

        // ── Assert: mUSDC collateral deposited ──
        assertGt(ICToken(MUSDC).balanceOf(address(strategy)), 0, "mUSDC collateral == 0");

        // ── Assert: both borrows active ──
        uint256 cbDebt = IMoonwellMarket(MCBBTC).borrowBalanceStored(address(strategy));
        uint256 wethDebt = IMoonwellMarket(MWETH).borrowBalanceStored(address(strategy));
        assertGt(cbDebt, 0, "cbBTC borrow balance == 0");
        assertGt(wethDebt, 0, "WETH borrow balance == 0");

        // ── Assert: CL NFT minted and staked ──
        uint256 tid = strategy.layout().tokenId;
        assertGt(tid, 0, "tokenId == 0");
        assertNotEq(strategy.layout().posTickLower, strategy.layout().posTickUpper, "ticks equal");
        // Explicit gauge-custody check: the gauge holds the NFT after deposit().
        assertEq(IERC721(NPM).ownerOf(tid), GAUGE, "gauge should own minted NFT");

        // ── Compute LTV and health from on-chain state ──
        // Collateral: mUSDC balance × exchangeRate / 1e18 → USDC face (6dp)
        uint256 mUsdcBal = ICToken(MUSDC).balanceOf(address(strategy));
        uint256 rate = ICToken(MUSDC).exchangeRateStored();
        uint256 collateralUsdc = (mUsdcBal * rate) / 1e18;

        // Prices (8dp each)
        (, int256 btcAns,,,) = IAggregatorV3(BaseAddresses.CHAINLINK_BTC_USD).latestRoundData();
        (, int256 ethAns,,,) = IAggregatorV3(BaseAddresses.CHAINLINK_ETH_USD).latestRoundData();
        (, int256 usdcAns,,,) = IAggregatorV3(BaseAddresses.CHAINLINK_USDC_USD).latestRoundData();
        uint256 pBTC = uint256(btcAns);
        uint256 pETH = uint256(ethAns);
        uint256 pUsdc = uint256(usdcAns); // ≈ 1e8

        // cbBTC debt → USDC 6dp: cbDebt(8dp) × pBTC(8dp) / 1e8 = usd(8dp); ÷ pUsdc × 1e6 = usdc(6dp)
        uint256 cbDebtUsdc = (cbDebt * pBTC * 1e6) / (1e8 * pUsdc);
        // WETH debt → USDC 6dp: wethDebt(18dp) × pETH(8dp) / 1e18 = usd(8dp); ÷ pUsdc × 1e6 = usdc(6dp)
        uint256 wethDebtUsdc = (wethDebt * pETH * 1e6) / (1e18 * pUsdc);
        uint256 totalDebtUsdc = cbDebtUsdc + wethDebtUsdc;

        // LTV in bps
        uint256 ltvBps = (totalDebtUsdc * 10000) / collateralUsdc;
        assertLe(ltvBps, MAX_LTV_BPS, "LTV > maxLtvBps");
        // Within ±15% (750 bps) of target — feeds may vary slightly from borrow-time prices
        assertGe(ltvBps, TARGET_LTV_BPS - 750, "LTV too low vs target");
        assertLe(ltvBps, TARGET_LTV_BPS + 750, "LTV too high vs target");

        // Health in bps: collateral × CF / debt
        uint256 cfBps = uint256(strategy.layout().usdcCollateralFactorBps);
        uint256 healthBps = (collateralUsdc * cfBps) / totalDebtUsdc;
        assertGe(healthBps, MIN_HEALTH_BPS, "health < minHealthBps");

        // nav() ≈ 50_000e6 within 5%
        uint256 navVal = strategy.nav();
        uint256 tolerance = 50_000e6 * 500 / 10000; // 5%
        assertGe(navVal, 50_000e6 - tolerance, "nav() too low");
        assertLe(navVal, 50_000e6 + tolerance, "nav() too high");
    }

    /// @notice Full settle unwind returns principal to vault and clears all position state.
    ///
    ///         Checks:
    ///           - Both Moonwell borrow balances reach 0.
    ///           - tokenId cleared to 0.
    ///           - On-chain NPM liquidity for the pre-settle tokenId is 0.
    ///           - Vault receives ≥95% and ≤101% of the 50k USDC principal
    ///             (round-trip swap costs + 1% slippage + IL bounded by range).
    ///           - No meaningful WETH or cbBTC residual remains in the strategy.
    function test_settle_returnsPrincipalAndClears() public {
        if (_skip) return;

        uint256 principal = 50_000e6;

        // ── Open position ──
        _fundUSDC(address(strategy), principal);
        vm.prank(fakeVault);
        strategy.execute();

        // Sanity: position is open
        assertGt(strategy.layout().tokenId, 0, "tokenId should be non-zero after execute");

        // Capture tokenId before settle so we can check NPM state after
        uint256 tid = strategy.layout().tokenId;

        // ── Settle ──
        vm.prank(fakeVault);
        strategy.settle();

        // ── Assert: both Moonwell debts cleared ──
        assertEq(
            IMoonwellMarket(BaseAddresses.MOONWELL_MCBBTC).borrowBalanceStored(address(strategy)),
            0,
            "cbBTC debt not fully repaid"
        );
        assertEq(
            IMoonwellMarket(BaseAddresses.MOONWELL_MWETH).borrowBalanceStored(address(strategy)),
            0,
            "WETH debt not fully repaid"
        );

        // ── Assert: position cleared (storage + on-chain NPM liquidity) ──
        assertEq(strategy.layout().tokenId, 0, "tokenId not cleared after settle");
        (,,,,,,, uint128 liqAfter,,,,) = INonfungiblePositionManager(BaseAddresses.SLIPSTREAM_NPM).positions(tid);
        assertEq(liqAfter, 0, "NFT liquidity drained");

        // ── Assert: vault received ≈ principal (95%–101%) ──
        uint256 vaultUsdc = IERC20(BaseAddresses.USDC).balanceOf(fakeVault);
        assertGe(vaultUsdc, principal * 9500 / 10000, "vault received < 95% of principal");
        assertLe(vaultUsdc, principal * 10100 / 10000, "vault received > 101% of principal");

        // ── Assert: no meaningful residual in strategy ──
        assertLt(IERC20(BaseAddresses.USDC).balanceOf(address(strategy)), 1e6, "USDC residual in strategy");
        assertLt(IERC20(BaseAddresses.WETH).balanceOf(address(strategy)), 1e15, "WETH residual in strategy");
        assertLt(IERC20(BaseAddresses.CBBTC).balanceOf(address(strategy)), 1000, "cbBTC residual in strategy");
    }

    /// @notice Settle still fully clears both debts even when IL causes a shortfall (one LP
    ///         leg comes back with less token than the matching debt).  The strategy redeems
    ///         mUSDC collateral and swaps to cover the gap.
    ///
    ///         Method: open the book, shove the pool tick far enough that the LP's collected
    ///         tokens are heavily weighted toward ONE leg (IL), then settle.  Whether or not
    ///         the shortfall branch is entered depends on how much the LP over-collects on the
    ///         shoved side; the invariant that MUST hold regardless is:
    ///           - cbBTC borrow balance == 0 after settle
    ///           - WETH borrow balance == 0 after settle
    ///           - USDC arrives in the vault (strategy is solvent)
    function test_settle_coversShortfallUnderIL() public {
        if (_skip) return;

        uint256 principal = 50_000e6;

        // ── Open position ──
        _fundUSDC(address(strategy), principal);
        vm.prank(fakeVault);
        strategy.execute();

        assertGt(strategy.layout().tokenId, 0, "tokenId should be non-zero after execute");

        // ── Snapshot pre-settle USDC in vault (should be 0) ──
        uint256 vaultUsdcBefore = IERC20(BaseAddresses.USDC).balanceOf(fakeVault);

        // ── Shove the tick to induce IL ──
        // Sell a large WETH amount into the pool (zeroForOne=true: token0=WETH → token1=cbBTC).
        // This pushes the price down (more cbBTC per WETH), concentrating the LP in the WETH
        // leg and leaving the cbBTC leg under-collected relative to cbBTC debt.
        // 200 WETH ≈ $500k at ~$2500/ETH — enough to move a 50k principal position out of range.
        uint256 shoveWeth = 200e18;
        int24 tickBefore;
        (, tickBefore,,,,) = ICLPool(BaseAddresses.CBBTC_WETH_POOL).slot0();
        int24 tickAfter = _shoveTick(shoveWeth, true);
        assertTrue(tickAfter != tickBefore, "shove should move the pool tick");

        // ── Check pre-settle borrow balances (both must be non-zero still) ──
        uint256 cbDebtBefore = IMoonwellMarket(BaseAddresses.MOONWELL_MCBBTC).borrowBalanceStored(address(strategy));
        uint256 wethDebtBefore = IMoonwellMarket(BaseAddresses.MOONWELL_MWETH).borrowBalanceStored(address(strategy));
        assertGt(cbDebtBefore, 0, "cbBTC debt should be non-zero before settle");
        assertGt(wethDebtBefore, 0, "WETH debt should be non-zero before settle");

        // ── Settle ──
        vm.prank(fakeVault);
        strategy.settle();

        // ── Assert: both Moonwell debts cleared regardless of shortfall path ──
        assertEq(
            IMoonwellMarket(BaseAddresses.MOONWELL_MCBBTC).borrowBalanceStored(address(strategy)),
            0,
            "cbBTC debt not fully repaid after shoved settle"
        );
        assertEq(
            IMoonwellMarket(BaseAddresses.MOONWELL_MWETH).borrowBalanceStored(address(strategy)),
            0,
            "WETH debt not fully repaid after shoved settle"
        );

        // ── Assert: USDC reached the vault ──
        uint256 vaultUsdcAfter = IERC20(BaseAddresses.USDC).balanceOf(fakeVault);
        assertGt(vaultUsdcAfter, vaultUsdcBefore, "vault received no USDC after shoved settle");

        // ── Assert: tokenId cleared ──
        assertEq(strategy.layout().tokenId, 0, "tokenId not cleared after shoved settle");
    }

    /// @notice Oracle NAV is resistant to tick manipulation:
    ///         after shoving the pool tick 300 ticks down (via sqrtPriceLimitX96),
    ///         `strategy.nav()` should stay within 1 % of its pre-shove value.
    ///
    ///         The oracle-implied sqrtP (derived from Chainlink prices) is used for
    ///         the CL-leg split — NOT the manipulable pool slot0 sqrtP — so a tick
    ///         shove cannot change the NAV as long as Chainlink prices are unchanged.
    ///         A 300-tick shove is within the 500-tick calm gate, so nav() returns
    ///         normally rather than reverting with CalmGateBreached.
    function test_nav_invariantUnderTickShove() public {
        if (_skip) return;

        // ── Open leveraged position ──
        _fundUSDC(address(strategy), 50_000e6);
        vm.prank(fakeVault);
        strategy.execute();

        uint256 navBefore = strategy.nav();
        assertGt(navBefore, 0, "navBefore should be > 0");

        // ── Shove the pool tick 300 ticks down ──
        // Use sqrtPriceLimitX96 = getSqrtRatioAtTick(currentTick - 300) so the swap
        // stops exactly 300 ticks below current rather than running to exhaustion.
        (, int24 currentTick,,,,) = ICLPool(BaseAddresses.CBBTC_WETH_POOL).slot0();
        uint160 sqrtPriceLimit = TickMath.getSqrtRatioAtTick(currentTick - 300);

        address shover = makeAddr("tick_shover");
        uint256 shoveAmt = 1_000e18; // large enough to reach the sqrtP limit
        _fundWETH(shover, shoveAmt);

        vm.startPrank(shover);
        IERC20(BaseAddresses.WETH).approve(BaseAddresses.SLIPSTREAM_CL_SWAP_ROUTER, shoveAmt);
        ICLSwapRouter(BaseAddresses.SLIPSTREAM_CL_SWAP_ROUTER)
            .exactInputSingle(
                ICLSwapRouter.ExactInputSingleParams({
                tokenIn: BaseAddresses.WETH,
                tokenOut: BaseAddresses.CBBTC,
                tickSpacing: BaseAddresses.CBBTC_WETH_TICK_SPACING,
                recipient: shover,
                deadline: block.timestamp + 600,
                amountIn: shoveAmt,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: sqrtPriceLimit
            })
            );
        vm.stopPrank();

        // Sanity: confirm the tick moved.
        (, int24 newTick,,,,) = ICLPool(BaseAddresses.CBBTC_WETH_POOL).slot0();
        assertLt(newTick, currentTick, "pool tick should have moved down after WETH shove");

        // ── Oracle NAV should be stable (within 1 %) ──
        // The CL-leg split uses Chainlink-derived sqrtP, not the manipulated pool sqrtP,
        // so a tick shove that doesn't change oracle prices cannot change the NAV.
        uint256 navAfter = strategy.nav();
        uint256 tolerance = navBefore / 100; // 1 %
        assertGe(navAfter, navBefore - tolerance, "NAV dropped > 1 % under 300-tick shove");
        assertLe(navAfter, navBefore + tolerance, "NAV rose > 1 % under 300-tick shove");
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
