// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {LeveragedAeroForkBase} from "./LeveragedAeroForkBase.sol";
import {BaseAddresses} from "./BaseAddresses.sol";
import {LeveragedAerodromeCLStrategy} from "../../../src/strategies/LeveragedAerodromeCLStrategy.sol";
import {LeveragedAeroValuation} from "../../../src/strategies/LeveragedAeroValuation.sol";
import {IMoonwellMarket, IComptroller, ICToken} from "../../../src/interfaces/IMoonwellMarket.sol";
import {ICLGauge, INonfungiblePositionManager, ICLPool, ICLSwapRouter} from "../../../src/interfaces/ISlipstream.sol";
import {TickMath} from "../../../src/libraries/TickMath.sol";
import {LiquidityAmounts} from "../../../src/libraries/LiquidityAmounts.sol";

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

    /// @dev L7: strategy reads vault().asset() at init — must equal the configured USDC.
    function asset() external pure returns (address) {
        return BaseAddresses.USDC;
    }

    /// @dev #421: strategy resolves protocol-fee params via vault().factory().protocolConfig();
    ///      factory()==0 ⇒ no protocol fee. Mock must track ISyndicateVault (CLAUDE.md MockRegistryMinimal lesson).
    function factory() external pure returns (address) {
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

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "ERC20InsufficientBalance");
        balanceOf[msg.sender] -= amount;
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

/// @dev H3 harness: identical to MockVaultForRedeem but every `strategyMint` REVERTS — models a
///      paused SyndicateVault (or an un-whitelisted feeRecipient on a closed-deposit config). The
///      redeem path (transferFrom / strategyBurn) still works, so a redeem must succeed despite the
///      fee-share mint being rejected.
contract MockVaultMintReverts {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    constructor(address initialHolder, uint256 initialShares) {
        balanceOf[initialHolder] = initialShares;
        totalSupply = initialShares;
    }

    function asset() external pure returns (address) {
        return BaseAddresses.USDC;
    }

    /// @dev #421: strategy resolves protocol-fee params via vault().factory().protocolConfig();
    ///      factory()==0 ⇒ no protocol fee. Mock must track ISyndicateVault (CLAUDE.md MockRegistryMinimal lesson).
    function factory() external pure returns (address) {
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

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "ERC20InsufficientBalance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function strategyMint(address, uint256) external pure {
        revert("EnforcedPause"); // models whenNotPaused / depositor-whitelist gate on strategyMint
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
            managementFeeBps: MGMT_FEE_BPS,
            performanceFeeBps: PERF_FEE_BPS,
            feeRecipient: feeRecipient
        });
    }

    /// @dev Zero-fee variant of `_buildInitParams` — used by the stayer-skim probe so fee
    ///      crystallisation never confounds the before/after NAV-conservation delta.
    function _buildInitParamsZeroFee() internal view returns (LeveragedAerodromeCLStrategy.InitParams memory p) {
        p = _buildInitParams();
        p.managementFeeBps = 0;
        p.performanceFeeBps = 0;
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

        // DepositorB redeems all their shares via the escrowed async path (the proportional-unwind
        // mechanic was demoted off the everyday `redeem`): request (B) → fulfill (proposer). Payout
        // measured via B's USDC-balance delta.
        uint256 bUsdcBefore = IERC20(BaseAddresses.USDC).balanceOf(depositorB);
        vm.startPrank(depositorB);
        mockVault.approve(address(strategy), sharesB);
        uint256 reqId = strategy.requestRedeem(sharesB, 0);
        vm.stopPrank();
        vm.prank(proposer);
        strategy.fulfillRedeem(reqId);
        uint256 assetsOut = IERC20(BaseAddresses.USDC).balanceOf(depositorB) - bUsdcBefore;

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
        uint256 tid = strategy.layout().tokenId;
        assertGt(tid, 0, "tokenId should still be set");
        assertEq(
            IERC721Minimal2(BaseAddresses.SLIPSTREAM_NPM).ownerOf(tid),
            BaseAddresses.CBBTC_WETH_GAUGE,
            "NFT not re-staked"
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 1b: M2 — NAV excludes vault float (donation must not move nav / short redeemer)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice M2: `netEquityUsdc` values strategy-controlled assets only — it no longer adds
    ///         `USDC.balanceOf(vault)`. So a USDC donation straight to the vault must NOT move
    ///         `nav()`, the strategy redeem path must never pull that float, and a partial redeem
    ///         still pays exactly f·nav — the redeemer isn't shorted the donation and a would-be
    ///         depositor isn't overcharged for it. Pre-M2 the float term inflated NAV → redeemers
    ///         underpaid / depositors overcharged whenever float > 0.
    function test_nav_excludesVaultFloat() public {
        if (_skip) return;

        // Second LP so the partial redeem leaves a stayer (depositorA holds the initial shares).
        uint256 depositB = 10_000e6;
        _fundUSDC(depositorB, depositB);
        vm.startPrank(depositorB);
        IERC20(BaseAddresses.USDC).approve(address(strategy), depositB);
        uint256 sharesB = strategy.deposit(depositB, 0);
        vm.stopPrank();
        assertGt(sharesB, 0, "B got 0 shares");

        uint256 navBefore = strategy.nav();
        uint256 supplyBefore = mockVault.totalSupply();
        assertGt(navBefore, 0, "nav should be positive");

        // Donate USDC straight to the vault (float > 0). Pre-M2 this inflated nav; post-M2 nav is
        // strategy-controlled only, so the donation must leave nav() bit-for-bit unchanged.
        uint256 donation = 5_000e6;
        _fundUSDC(address(mockVault), donation);
        assertEq(IERC20(BaseAddresses.USDC).balanceOf(address(mockVault)), donation, "vault not funded");
        assertEq(strategy.nav(), navBefore, "nav moved on vault-float donation (M2: float must be excluded)");

        // A partial FAST-PATH redeem pays exactly f·nav (strategy-controlled), and never taps the vault
        // float. (The fast path prices f × navNet and funds it from the Moonwell collateral.)
        uint256 fairShare = (navBefore * sharesB) / supplyBefore;
        vm.startPrank(depositorB);
        mockVault.approve(address(strategy), sharesB);
        uint256 assetsOut = strategy.redeem(sharesB, 0);
        vm.stopPrank();

        // Fast path pays exactly f·nav (collateral-funded, no LP touch → no realized-exit slippage).
        assertApproxEqRel(assetsOut, fairShare, 0.001e18, "redeem != f*nav (float-exclusion broken)");
        // The donated float is untouched by the strategy redeem path — it stays in the vault.
        assertEq(
            IERC20(BaseAddresses.USDC).balanceOf(address(mockVault)), donation, "vault float was touched by redeem"
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 2: redeem succeeds while oracle is stale
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice When the BTC feed returns a stale answer (so nav() reverts), the ORACLE-FREE async exit
    ///         (requestRedeem → fulfillRedeem) still succeeds (navPre=0 → no fees minted) while both the
    ///         oracle-dependent fast-path `redeem` and `deposit` revert (fail-closed).
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

        // Escrow the shares BEFORE the feed goes stale (requestRedeem never reads the oracle, but this
        // mirrors the real flow: a user requests, then the feed dies, then the backend fulfills).
        vm.startPrank(depositorA);
        mockVault.approve(address(strategy), sharesA);
        uint256 reqId = strategy.requestRedeem(sharesA, 0);
        vm.stopPrank();

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

        // The oracle-dependent fast-path redeem also reverts under the stale feed (fail-closed):
        // `redeem` prices `nav()` FIRST (before any share pull), so the stale feed reverts it.
        vm.prank(depositorB);
        vm.expectRevert();
        strategy.redeem(1, 0);

        // deposit() should also revert under the same stale feed.
        uint256 depositAmt = 1000e6;
        _fundUSDC(depositorB, depositAmt);
        vm.startPrank(depositorB);
        IERC20(BaseAddresses.USDC).approve(address(strategy), depositAmt);
        vm.expectRevert();
        strategy.deposit(depositAmt, 0);
        vm.stopPrank();

        // fulfillRedeem (full redemption, f=1) SUCCEEDS despite the stale oracle (oracle-free path).
        uint256 aUsdcBefore = IERC20(BaseAddresses.USDC).balanceOf(depositorA);
        vm.prank(proposer);
        strategy.fulfillRedeem(reqId);
        uint256 assetsOut = IERC20(BaseAddresses.USDC).balanceOf(depositorA) - aUsdcBefore;
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
    // Test 2b: H3 — redeem survives a fee-mint failure (paused / un-whitelisted vault)
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Re-mock the 3 Chainlink price feeds with a fresh `updatedAt == block.timestamp` (keeping
    ///      their real answers) so nav() stays oracle-valid after a forward warp — lets the
    ///      crystallise compute a nonzero fee whose MINT is the thing we want to fail.
    function _refreshPriceFeeds() internal {
        address[3] memory feeds =
            [BaseAddresses.CHAINLINK_BTC_USD, BaseAddresses.CHAINLINK_ETH_USD, BaseAddresses.CHAINLINK_USDC_USD];
        uint256 ts = vm.getBlockTimestamp();
        for (uint256 i; i < feeds.length; i++) {
            (uint80 rid, int256 answer,,,) = IAggregatorV3Min(feeds[i]).latestRoundData();
            vm.mockCall(feeds[i], abi.encodeWithSignature("latestRoundData()"), abi.encode(rid, answer, ts, ts, rid));
        }
    }

    /// @notice H3 (fund-trap fix): the async proportional exit (requestRedeem → fulfillRedeem) MUST
    ///         succeed even when the vault rejects the fee-share mint (paused vault / un-whitelisted
    ///         feeRecipient) with a management fee owed. The crystallise runs best-effort via
    ///         `try this.crystallizeFeesSelf() {} catch {}` inside `_proportionalRedeem`, so the mint
    ///         revert is swallowed, the fee defers (HWM + lastFeeAccrualTimestamp unchanged), and the
    ///         sole exit of an indefinite proposal stays open. Pre-H3 this reverted.
    function test_redeem_succeedsWhenFeeMintReverts_paused() public {
        if (_skip) return;

        // Fresh strategy whose vault rejects every strategyMint (models whenNotPaused / whitelist).
        MockVaultMintReverts pausedVault = new MockVaultMintReverts(depositorA, DEPOSITOR_A_SHARES);
        address template = address(new LeveragedAerodromeCLStrategy());
        LeveragedAerodromeCLStrategy strat = LeveragedAerodromeCLStrategy(payable(Clones.clone(template)));
        strat.initialize(address(pausedVault), proposer, abi.encode(_buildInitParams()));
        _fundUSDC(address(strat), PRINCIPAL);
        vm.prank(address(pausedVault));
        strat.execute();

        // Accrue a nonzero management fee, then refresh feeds so nav() (hence navPre) is valid → the
        // crystallise computes feeShares > 0 → strategyMint(feeRecipient) is called → reverts.
        vm.warp(vm.getBlockTimestamp() + 7 days);
        _refreshPriceFeeds();

        // The vault really does reject fee-share mints (the gate under test).
        vm.expectRevert();
        pausedVault.strategyMint(feeRecipient, 1);

        uint256 lastAccrualBefore = strat.layout().lastFeeAccrualTimestamp;
        uint256 hwmBefore = strat.layout().hwmPerShare;

        // depositorA redeems ALL shares via the async path — must SUCCEED despite the mint gate.
        uint256 sharesA = pausedVault.balanceOf(depositorA);
        _fundUSDC(address(strat), 2_000e6); // IL / interest buffer for the full unwind
        uint256 aUsdcBefore = IERC20(BaseAddresses.USDC).balanceOf(depositorA);
        vm.startPrank(depositorA);
        pausedVault.approve(address(strat), sharesA);
        uint256 reqId = strat.requestRedeem(sharesA, 0);
        vm.stopPrank();
        vm.prank(proposer);
        strat.fulfillRedeem(reqId);
        uint256 assetsOut = IERC20(BaseAddresses.USDC).balanceOf(depositorA) - aUsdcBefore;

        assertGt(assetsOut, 0, "redeem returned 0 - bricked by fee-mint gate (H3 regression)");
        assertEq(IERC20(BaseAddresses.USDC).balanceOf(depositorA), assetsOut, "A USDC mismatch");
        // Fee DEFERRED: feeRecipient minted nothing and the whole crystallise rolled back.
        assertEq(pausedVault.balanceOf(feeRecipient), 0, "fee minted despite paused vault");
        assertEq(
            strat.layout().lastFeeAccrualTimestamp,
            lastAccrualBefore,
            "accrual clock advanced - crystallise not rolled back"
        );
        assertEq(strat.layout().hwmPerShare, hwmBefore, "HWM advanced - crystallise not rolled back");

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

    // ─────────────────────────────────────────────────────────────────────────
    // Test 4: Finding 2 regression — full redeem with zero idle + IL shortfall
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Finding 2 regression: full redeem with zero idle USDC and IL-induced shortfall.
    ///         OLD code: _redeemCoverShortfall uses idle USDC (=0) → no-op → residual cbBTC debt
    ///                   blocks 100 % collateral redeem → MoonwellRedeemFailed(3).
    ///         NEW code: Phase 2 _settleShortfall() self-funds from mUSDC collateral (oracle path)
    ///                   → repays residual debt → full collateral redemption succeeds.
    function test_redeem_fullUnderILWithZeroIdle() public {
        if (_skip) return;

        // depositorA holds all initial shares.
        uint256 sharesA = mockVault.balanceOf(depositorA);
        assertGt(sharesA, 0, "depositorA has no shares");

        // Deploy ALL idle USDC into the LP (idle → 0).
        uint256 idle = IERC20(BaseAddresses.USDC).balanceOf(address(strategy));
        if (idle > 0) {
            vm.prank(proposer);
            strategy.deployIdle(idle, 0);
        }
        assertEq(IERC20(BaseAddresses.USDC).balanceOf(address(strategy)), 0, "idle not drained");

        // Shove the tick hard to push the LP out of range on the cbBTC side.
        // Selling 200 WETH moves the pool tick down enough that the LP collects
        // mostly WETH and almost no cbBTC → cbBTC IL shortfall.
        _shoveTick(200e18, true);

        // Capture tokenId before redeem so we can query NPM state afterward.
        uint256 tid = strategy.layout().tokenId;
        assertGt(tid, 0, "tokenId should be set before redeem");

        // Best-effort NAV capture — may revert if the tick shove trips the calm gate
        // (500-tick threshold). The redeem path itself uses try-this.nav() so it's fine either way.
        uint256 navBefore;
        try strategy.nav() returns (uint256 n) {
            navBefore = n;
        } catch {
            navBefore = 0;
        }

        // FULL redeem: depositorA redeems ALL shares (shares == supply).
        uint256 supply = mockVault.totalSupply();
        assertEq(supply, sharesA, "depositorA must own 100% of supply for this test");

        // Full redeem via the async proportional path (the IL-self-funding mechanic lives there now).
        uint256 aUsdcBefore = IERC20(BaseAddresses.USDC).balanceOf(depositorA);
        vm.startPrank(depositorA);
        mockVault.approve(address(strategy), sharesA);
        uint256 reqId = strategy.requestRedeem(sharesA, 0);
        vm.stopPrank();
        vm.prank(proposer);
        strategy.fulfillRedeem(reqId); // must NOT revert
        uint256 assetsOut = IERC20(BaseAddresses.USDC).balanceOf(depositorA) - aUsdcBefore;

        // Must receive non-zero USDC.
        assertGt(assetsOut, 0, "received 0 USDC");

        // If the calm gate did not trip, assetsOut should be ≥ 80 % of oracle NAV.
        if (navBefore > 0) {
            assertGe(assetsOut, navBefore * 8000 / 10000, "received < 80% of NAV");
        }

        // Both Moonwell borrow balances must be fully cleared.
        assertEq(
            IMoonwellMarket(BaseAddresses.MOONWELL_MCBBTC).borrowBalanceStored(address(strategy)),
            0,
            "cbBTC debt not cleared after full redeem under IL"
        );
        assertEq(
            IMoonwellMarket(BaseAddresses.MOONWELL_MWETH).borrowBalanceStored(address(strategy)),
            0,
            "WETH debt not cleared after full redeem under IL"
        );

        // Position fully unwound: the NPM position must have zero liquidity.
        (,,,,,,, uint128 liqAfter,,,,) = INpmFull(BaseAddresses.SLIPSTREAM_NPM).positions(tid);
        assertEq(liqAfter, 0, "position not fully unwound after full redeem");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 5: Finding 1 regression — partial redeem with zero idle + IL shortfall
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Finding 1 (partial) regression: partial redeem with zero idle USDC and IL-induced shortfall.
    ///         OLD code: _redeemCoverShortfall uses idle USDC (=0) → exactOutputSingle amountInMax=0 → MoonwellRedeemFailed(3).
    ///         NEW code: redeem f·collateral first → USDC available → shortfall covered.
    function test_redeem_partialUnderILWithZeroIdle() public {
        if (_skip) return;

        // depositorA holds all initial shares
        uint256 sharesA = mockVault.balanceOf(depositorA);
        assertGt(sharesA, 0, "depositorA has no shares");

        // Deploy all idle USDC into the LP (idle → 0)
        uint256 idle = IERC20(BaseAddresses.USDC).balanceOf(address(strategy));
        if (idle > 0) {
            vm.prank(proposer);
            strategy.deployIdle(idle, 0);
        }
        assertEq(IERC20(BaseAddresses.USDC).balanceOf(address(strategy)), 0, "idle not drained");

        // Shove the tick hard to force IL (LP leg collected < debt on one side)
        _shoveTick(200e18, true); // sell 200 WETH → push price down sharply

        // Partial redeem: depositorA redeems half their shares
        uint256 redeemShares = sharesA / 2;
        uint256 supplyBefore = mockVault.totalSupply();
        uint256 cbDebtBefore = IMoonwellMarket(BaseAddresses.MOONWELL_MCBBTC).borrowBalanceStored(address(strategy));
        uint256 wethDebtBefore = IMoonwellMarket(BaseAddresses.MOONWELL_MWETH).borrowBalanceStored(address(strategy));

        // Partial redeem via the async proportional path (IL self-funding + Finding-1 collateral-first).
        uint256 aUsdcBefore = IERC20(BaseAddresses.USDC).balanceOf(depositorA);
        vm.startPrank(depositorA);
        mockVault.approve(address(strategy), redeemShares);
        uint256 reqId = strategy.requestRedeem(redeemShares, 0);
        vm.stopPrank();
        vm.prank(proposer);
        strategy.fulfillRedeem(reqId); // must NOT revert
        uint256 assetsOut = IERC20(BaseAddresses.USDC).balanceOf(depositorA) - aUsdcBefore;

        // Must receive non-zero USDC
        assertGt(assetsOut, 0, "received 0 USDC");
        assertEq(IERC20(BaseAddresses.USDC).balanceOf(depositorA), aUsdcBefore + assetsOut, "USDC not transferred");

        // Stayers' borrow balances should be ≈ (1-f)*original debt (within 1% for interest)
        uint256 f_num = redeemShares;
        uint256 f_den = supplyBefore;
        uint256 cbDebtAfter = IMoonwellMarket(BaseAddresses.MOONWELL_MCBBTC).borrowBalanceStored(address(strategy));
        uint256 wethDebtAfter = IMoonwellMarket(BaseAddresses.MOONWELL_MWETH).borrowBalanceStored(address(strategy));
        uint256 cbDebtExpected = cbDebtBefore - Math.mulDiv(cbDebtBefore, f_num, f_den);
        uint256 wethDebtExpected = wethDebtBefore - Math.mulDiv(wethDebtBefore, f_num, f_den);
        // Allow 1% tolerance for interest accrual
        assertGe(cbDebtAfter, cbDebtExpected * 9900 / 10000, "cbBTC stayers debt too low");
        assertLe(cbDebtAfter, cbDebtExpected * 10100 / 10000, "cbBTC stayers debt too high");
        assertGe(wethDebtAfter, wethDebtExpected * 9900 / 10000, "WETH stayers debt too low");
        assertLe(wethDebtAfter, wethDebtExpected * 10100 / 10000, "WETH stayers debt too high");

        // NFT must still be staked (remaining liq > 0)
        uint256 tid = strategy.layout().tokenId;
        assertGt(tid, 0, "tokenId cleared unexpectedly");
        assertEq(
            IERC721Minimal2(BaseAddresses.SLIPSTREAM_NPM).ownerOf(tid),
            BaseAddresses.CBBTC_WETH_GAUGE,
            "NFT not re-staked after partial redeem"
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 6: triple-coincidence stayer-skim probe — rerange remainder + IL
    //         shortfall on the SAME leg + partial redeem must not skim stayers.
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Spec §7 guarantee: "removing exactly fraction f of every leg leaves stayers with
    ///         (1-f) of every leg, regardless of price." A no-swap `rerange` leaves an idle
    ///         remainder of ONE borrowed leg (`I_leg > 0`); `_redeemRepayFromCollected` repays
    ///         `min(f*debt, totalLegBal)` from the TOTAL balance (collected-from-unwind +
    ///         pre-existing idle), so a severe IL shortfall on that leg can over-repay the
    ///         redeemer's debt out of the stayers' reserved `(1-f)*I_leg` — raising no/too-small a
    ///         `cbShort`/`wethShort`, so the redeemer's own collateral is never tapped for the
    ///         shortfall. Net: stayers shorted, redeemer over-paid.
    ///
    ///         Reachable when (on the SAME leg): a rerange remainder exists (`I_leg > 0`), a hard
    ///         tick shove drives the LP out of range so it collects ~0 of that leg
    ///         (`f*debt_leg > L_leg + f*I_leg`), and the redeem is partial (`f < 1`).
    ///
    ///         The arbiter is the stayer's per-share ORACLE NAV (oracle-implied sqrtP + Chainlink
    ///         prices, NO calm-gate → immune to the shove, same prices before/after): it must be
    ///         NON-DECREASING across the partial redeem.
    function test_redeem_partialUnderIL_afterRerange_noStayerSkim() public {
        if (_skip) return;
        // token0/token1 ordering assumption used by `_oracleNavNoGate` (matches the live pool).
        require(ICLPool(POOL).token0() == WETH, "fork: expected pool token0 == WETH");

        // Fresh ZERO-FEE book so fee crystallisation never confounds the conservation delta.
        MockVaultForRedeem v = new MockVaultForRedeem(depositorA, DEPOSITOR_A_SHARES);
        LeveragedAerodromeCLStrategy strat =
            LeveragedAerodromeCLStrategy(payable(Clones.clone(address(new LeveragedAerodromeCLStrategy()))));
        strat.initialize(address(v), proposer, abi.encode(_buildInitParamsZeroFee()));
        _fundUSDC(address(strat), PRINCIPAL);
        vm.prank(address(v));
        strat.execute();

        // Second LP so the partial redeem leaves a stayer (depositorA).
        uint256 depositB = 10_000e6;
        _fundUSDC(depositorB, depositB);
        vm.startPrank(depositorB);
        IERC20(BaseAddresses.USDC).approve(address(strat), depositB);
        uint256 sharesB = strat.deposit(depositB, 0);
        vm.stopPrank();
        assertGt(sharesB, 0, "B got 0 shares");

        // Drain idle USDC so the ONLY idle asset is the rerange remainder leg.
        uint256 idle = IERC20(BaseAddresses.USDC).balanceOf(address(strat));
        vm.prank(proposer);
        strat.deployIdle(idle, 0);
        assertEq(IERC20(BaseAddresses.USDC).balanceOf(address(strat)), 0, "idle USDC not drained");

        // (a) Drift ~450 ticks in-band (down), then recenter (no swap) → idle remainder of ONE leg.
        (, int24 t0,,,,) = ICLPool(POOL).slot0();
        _shoveToTickDown(t0 - 450);
        vm.prank(proposer);
        strat.rerange(0, 0);
        uint256 idleCb = IERC20(CBBTC).balanceOf(address(strat));
        uint256 idleWeth = IERC20(WETH).balanceOf(address(strat));
        assertTrue(idleCb > 0 || idleWeth > 0, "rerange left no idle remainder leg");

        // (b) Hard-shove to drive a real IL shortfall on the SAME leg as the remainder:
        //       remainder = WETH  → shove UP   (sell cbBTC) → LP all cbBTC → WETH under-collected.
        //       remainder = cbBTC → shove DOWN (sell WETH)  → LP all WETH  → cbBTC under-collected.
        bool remainderIsWeth = idleWeth >= idleCb;
        emit log_named_uint("idleCb (8dp)", idleCb);
        emit log_named_uint("idleWeth (18dp)", idleWeth);
        emit log_named_int("posTickLower", strat.layout().posTickLower);
        emit log_named_int("posTickUpper", strat.layout().posTickUpper);
        (, int24 tPre,,,,) = ICLPool(POOL).slot0();
        emit log_named_int("tick pre-hard-shove", tPre);
        if (remainderIsWeth) _shoveTick(200e8, false); // sell 200 cbBTC → tick UP
        else _shoveTick(2_000e18, true); // sell 2000 WETH → tick DOWN
        // Confirm the LP went out of range (collects ~0 of the remainder leg → genuine shortfall).
        {
            (, int24 tShoved,,,,) = ICLPool(POOL).slot0();
            emit log_named_int("tick post-hard-shove", tShoved);
            int24 pl = strat.layout().posTickLower;
            int24 pu = strat.layout().posTickUpper;
            assertTrue(tShoved < pl || tShoved > pu, "shove did not push LP out of range (no real shortfall)");
        }

        // Snapshot the stayer's per-share oracle NAV right before the redeem.
        uint256 supplyBefore = v.totalSupply();
        uint256 navBefore = _oracleNavNoGate(address(strat));
        uint256 perShareBefore = (navBefore * 1e18) / supplyBefore;

        // (c) PARTIAL redeem via the async proportional path (the stayer-safety mechanic lives there):
        //     depositorB requests ALL of B's shares (f = sharesB/supply < 1), proposer fulfills,
        //     leaving depositorA as the stayer. Payout via B's USDC-balance delta.
        uint256 bUsdcBefore = IERC20(BaseAddresses.USDC).balanceOf(depositorB);
        vm.startPrank(depositorB);
        v.approve(address(strat), sharesB);
        uint256 reqId = strat.requestRedeem(sharesB, 0);
        vm.stopPrank();
        strat.fulfillRedeem(reqId); // proposer == address(this)
        uint256 assetsOut = IERC20(BaseAddresses.USDC).balanceOf(depositorB) - bUsdcBefore;

        uint256 supplyAfter = v.totalSupply();
        assertEq(supplyAfter, supplyBefore - sharesB, "supply bookkeeping");
        uint256 navAfter = _oracleNavNoGate(address(strat));
        uint256 perShareAfter = (navAfter * 1e18) / supplyAfter;

        emit log_named_uint("perShareBefore (1e18)", perShareBefore);
        emit log_named_uint("perShareAfter  (1e18)", perShareAfter);
        emit log_named_uint("navBefore (USDC 6dp)", navBefore);
        emit log_named_uint("navAfter  (USDC 6dp)", navAfter);
        emit log_named_uint("assetsOut (USDC 6dp)", assetsOut);
        emit log_named_uint("fairShare (USDC 6dp)", (navBefore * sharesB) / supplyBefore);

        // PRIMARY (the §7 arbiter): the stayer's per-share NAV must be NON-DECREASING across the
        // partial redeem. Buggy code consumes the stayers' reserved (1-f)*I_leg to over-repay the
        // redeemer's debt → perShareAfter drops materially (measured ~3.2% pre-fix). The reserve-cap
        // fix keeps it flat (measured drop ~1.5e-8, pure mulDiv dust): navAfter == (1-f)*navBefore.
        assertGe(perShareAfter, perShareBefore * 999 / 1000, "STAYER SKIM: per-share NAV dropped");

        // SECONDARY (gross-overpayment sanity): the redeemer must not receive WILDLY more than its
        // fair f*navBefore. A small (~1.4%) excess over the oracle mark is benign and NOT a stayer
        // skim — it is the redeemer realizing ITS OWN f-of-LP at the shoved tick vs the conservative
        // oracle-implied mark (stayers are exactly whole per the PRIMARY check above). The pre-fix
        // skim drove assetsOut to ~17.5% over fair, so a 5% bound cleanly separates skim from noise.
        uint256 fairShare = (navBefore * sharesB) / supplyBefore;
        assertLe(assetsOut, fairShare * 105 / 100, "redeemer grossly over-paid (skimmed stayers)");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // NEW: fast-path redeem (oracle-priced, collateral-funded, LTV-gated)
    // ═════════════════════════════════════════════════════════════════════════

    /// @notice Test 1 — the fast path pays exactly `shares × nav / supply`, funded from the Moonwell
    ///         collateral ONLY: LP liquidity + both borrows are UNCHANGED, mUSDC collateral drops by
    ///         ~assetsOut, and post-LTV stays ≤ max.
    function test_fastRedeem_paysFxNav_collateralOnly() public {
        if (_skip) return;

        // Second LP so a partial fast redeem leaves depositorA as a stayer.
        uint256 sharesB = _depositB(10_000e6);

        uint256 navBefore = strategy.nav();
        uint256 supplyBefore = mockVault.totalSupply();
        uint256 fair = Math.mulDiv(sharesB, navBefore, supplyBefore);

        uint256 tid = strategy.layout().tokenId;
        (,,,,,,, uint128 liqBefore,,,,) = INpmFull(BaseAddresses.SLIPSTREAM_NPM).positions(tid);
        uint256 cbDebtBefore = IMoonwellMarket(BaseAddresses.MOONWELL_MCBBTC).borrowBalanceStored(address(strategy));
        uint256 wethDebtBefore = IMoonwellMarket(BaseAddresses.MOONWELL_MWETH).borrowBalanceStored(address(strategy));
        uint256 collatBefore = ICToken(BaseAddresses.MOONWELL_MUSDC).balanceOf(address(strategy));
        uint256 idleBefore = IERC20(BaseAddresses.USDC).balanceOf(address(strategy));

        vm.startPrank(depositorB);
        mockVault.approve(address(strategy), sharesB);
        uint256 out = strategy.redeem(sharesB, 0);
        vm.stopPrank();

        // Pays exactly f × nav (collateral-funded → no LP/pool slippage).
        assertApproxEqRel(out, fair, 0.001e18, "fast path != f * nav");
        assertEq(IERC20(BaseAddresses.USDC).balanceOf(depositorB), out, "B USDC mismatch");

        // LP liquidity + both borrows UNCHANGED (no LP touch, no debt repay).
        (,,,,,,, uint128 liqAfter,,,,) = INpmFull(BaseAddresses.SLIPSTREAM_NPM).positions(tid);
        assertEq(liqAfter, liqBefore, "LP liquidity moved on the fast path");
        assertEq(
            IMoonwellMarket(BaseAddresses.MOONWELL_MCBBTC).borrowBalanceStored(address(strategy)),
            cbDebtBefore,
            "cbBTC debt moved on the fast path"
        );
        assertEq(
            IMoonwellMarket(BaseAddresses.MOONWELL_MWETH).borrowBalanceStored(address(strategy)),
            wethDebtBefore,
            "WETH debt moved on the fast path"
        );

        // Collateral reduced by ~(assetsOut − fromIdle). Two subtleties this assertion must track:
        //   • mUSDC balanceOf is denominated in cToken SHARES (8dp), not underlying USDC — convert
        //     the drawdown via exchangeRateStored (underlying = shares × rate / 1e18);
        //   • the fast path sources the redeemer's pro-rata idle USDC FIRST (0ecea00b, re-review
        //     f2) and draws only the remainder from collateral, mirroring fastRedeemImpl's
        //     fromIdle = min(assetsOut, idleShare).
        uint256 collatAfter = ICToken(BaseAddresses.MOONWELL_MUSDC).balanceOf(address(strategy));
        assertLt(collatAfter, collatBefore, "collateral not drawn down");
        uint256 drawdownUsdc =
            Math.mulDiv(collatBefore - collatAfter, ICToken(BaseAddresses.MOONWELL_MUSDC).exchangeRateStored(), 1e18);
        uint256 idleShare = Math.mulDiv(idleBefore, sharesB, supplyBefore);
        uint256 fromIdle = Math.min(out, idleShare);
        assertApproxEqRel(drawdownUsdc, out - fromIdle, 0.001e18, "collateral drawdown != assetsOut - fromIdle");
    }

    /// @notice Test 2 — a fast redeem sized so the post-withdraw LTV breaches `maxLtvBps` reverts
    ///         `FastRedeemExceedsLtv`, and `previewRedeem` flags `fastOk == false` for that size while
    ///         reporting the priced `assetsOut`.
    function test_fastRedeem_ltvGate_revertsAndPreviewFlags() public {
        if (_skip) return;

        // depositorA holds ALL supply; a large-enough fast redeem shrinks collateral until the
        // fixed debt breaches maxLtvBps. Redeem ~90% of nav → collateral shrinks hard → LTV spikes.
        uint256 supply = mockVault.totalSupply();
        uint256 shares = (supply * 90) / 100;

        (uint256 pv, bool fastOk) = strategy.previewRedeem(shares);
        assertGt(pv, 0, "preview priced 0");
        assertFalse(fastOk, "preview must flag the LTV breach for a 90% fast redeem");

        // On-chain fast path reverts FastRedeemExceedsLtv (args are runtime-dependent → loose match).
        vm.startPrank(depositorA);
        mockVault.approve(address(strategy), shares);
        vm.expectRevert();
        strategy.redeem(shares, 0);
        vm.stopPrank();
    }

    /// @notice Test 2 (preview) — a small fast redeem clears the gate: `previewRedeem.fastOk == true`
    ///         and the on-chain fast path succeeds.
    function test_fastRedeem_smallSize_previewOkAndSucceeds() public {
        if (_skip) return;
        uint256 sharesB = _depositB(5_000e6);
        (uint256 pv, bool fastOk) = strategy.previewRedeem(sharesB);
        assertGt(pv, 0, "preview priced 0");
        assertTrue(fastOk, "small fast redeem should clear the LTV gate");

        vm.startPrank(depositorB);
        mockVault.approve(address(strategy), sharesB);
        uint256 out = strategy.redeem(sharesB, 0);
        vm.stopPrank();
        assertApproxEqRel(out, pv, 0.001e18, "fast redeem payout != preview");
    }

    /// @notice Test 3 — the fast path fails closed on a down oracle (reverts), and `previewRedeem`
    ///         returns `(0, false)` instead of reverting.
    function test_fastRedeem_oracleDown_revertsAndPreviewZero() public {
        if (_skip) return;
        uint256 sharesA = mockVault.balanceOf(depositorA);

        // Stale the BTC feed → nav() reverts.
        address btcFeed = BaseAddresses.CHAINLINK_BTC_USD;
        (, int256 answer,,, uint80 answeredIn) = IAggregatorV3Min(btcFeed).latestRoundData();
        vm.mockCall(
            btcFeed,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(1), answer, uint256(1), uint256(1), answeredIn)
        );

        (uint256 pv, bool fastOk) = strategy.previewRedeem(sharesA);
        assertEq(pv, 0, "preview must return 0 on a down oracle");
        assertFalse(fastOk, "preview must return fastOk=false on a down oracle");

        vm.startPrank(depositorA);
        mockVault.approve(address(strategy), sharesA);
        vm.expectRevert(); // nav() reverts (stale)
        strategy.redeem(sharesA, 0);
        vm.stopPrank();

        vm.clearMockedCalls();
    }

    // ═════════════════════════════════════════════════════════════════════════
    // NEW: escrowed async request lifecycle + deadman emergencyRedeem
    // ═════════════════════════════════════════════════════════════════════════

    /// @notice Test 5 — request lifecycle: escrow moves shares to the strategy; cancel returns them
    ///         (including AFTER _settle — no Executed gate); double-settle is prevented; fulfill is
    ///         onlyProposer; fulfill pays owner net of skim and enforces the STORED minAssetsOut.
    function test_asyncRedeem_lifecycle() public {
        if (_skip) return;
        uint256 sharesB = _depositB(10_000e6);

        // (a) escrow moves shares into the strategy.
        vm.startPrank(depositorB);
        mockVault.approve(address(strategy), sharesB);
        uint256 id = strategy.requestRedeem(sharesB, 0);
        vm.stopPrank();
        assertEq(mockVault.balanceOf(depositorB), 0, "shares not escrowed");
        assertEq(mockVault.balanceOf(address(strategy)), sharesB, "strategy did not receive escrow");

        // (b) fulfill is onlyProposer.
        vm.prank(makeAddr("notProposer"));
        vm.expectRevert(); // NotProposer
        strategy.fulfillRedeem(id);

        // (c) cancel returns the escrowed shares (a fresh request). B's first tranche is already
        //     escrowed under `id` (kept for the fulfill in (e)) — B's balance is 0 here, per the
        //     assert in (a) — so fund a SECOND independent tranche to exercise cancel.
        uint256 sharesB2 = _depositB(10_000e6);
        vm.startPrank(depositorB);
        mockVault.approve(address(strategy), sharesB2);
        uint256 id2 = strategy.requestRedeem(sharesB2, 0);
        vm.stopPrank();
        vm.prank(depositorB);
        strategy.cancelRedeem(id2);
        assertEq(mockVault.balanceOf(depositorB), sharesB2, "cancel did not return shares");

        // (d) double-settle prevented: cancel again on the same id reverts.
        vm.prank(depositorB);
        vm.expectRevert(LeveragedAerodromeCLStrategy.RequestSettled.selector);
        strategy.cancelRedeem(id2);

        // (e) fulfill the FIRST request (id) — pays owner; enforce a stored minAssetsOut that passes.
        uint256 bUsdcBefore = IERC20(BaseAddresses.USDC).balanceOf(depositorB);
        vm.prank(proposer);
        strategy.fulfillRedeem(id);
        assertGt(IERC20(BaseAddresses.USDC).balanceOf(depositorB) - bUsdcBefore, 0, "fulfill paid nothing");

        // (f) re-fulfilling a settled request reverts.
        vm.prank(proposer);
        vm.expectRevert(LeveragedAerodromeCLStrategy.RequestSettled.selector);
        strategy.fulfillRedeem(id);
    }

    /// @notice Test 5 (cancel-after-settle) — a request outstanding when the proposal settles stays
    ///         cancellable (no Executed gate), so the owner can exit via the vault normally.
    function test_asyncRedeem_cancelWorksAfterSettle() public {
        if (_skip) return;
        uint256 sharesB = _depositB(10_000e6);
        vm.startPrank(depositorB);
        mockVault.approve(address(strategy), sharesB);
        uint256 id = strategy.requestRedeem(sharesB, 0);
        vm.stopPrank();

        // Settle the strategy (state → Settled). requestRedeem/fulfill would now revert (NotExecuted),
        // but cancel must still work.
        vm.prank(address(mockVault));
        strategy.settle();

        vm.prank(depositorB);
        strategy.cancelRedeem(id);
        assertEq(mockVault.balanceOf(depositorB), sharesB, "cancel-after-settle did not return shares");
    }

    /// @notice Test 6 (HEADLINE deadman) — request → warp past FULFILL_WINDOW → BOTH feeds stale
    ///         (oracle down) AND backend silent → `emergencyRedeem` still pays the proportional unwind
    ///         (price-free mgmt-fee crystallize path), burns, marks settled. Before-window reverts;
    ///         non-owner reverts.
    function test_asyncRedeem_deadmanEmergency() public {
        if (_skip) return;

        // depositorA holds ALL supply → a full emergency redeem (f=1).
        uint256 sharesA = mockVault.balanceOf(depositorA);
        _fundUSDC(address(strategy), 2_000e6); // IL/interest buffer for the full unwind

        vm.startPrank(depositorA);
        mockVault.approve(address(strategy), sharesA);
        uint256 id = strategy.requestRedeem(sharesA, 0);
        vm.stopPrank();

        // Before the window elapses → reverts.
        vm.prank(depositorA);
        vm.expectRevert(LeveragedAerodromeCLStrategy.FulfillWindowOpen.selector);
        strategy.emergencyRedeem(id, 0);

        // Warp past FULFILL_WINDOW (2 days) and stale BOTH feeds (oracle fully down).
        vm.warp(vm.getBlockTimestamp() + 2 days + 1);
        _staleAllFeeds();

        // nav() reverts (oracle down) — the fast path would be unusable here.
        vm.expectRevert();
        strategy.nav();

        // Non-owner cannot emergency-redeem.
        vm.prank(makeAddr("notOwner"));
        vm.expectRevert(LeveragedAerodromeCLStrategy.NotRequestOwner.selector);
        strategy.emergencyRedeem(id, 0);

        // Owner emergency-redeems → succeeds oracle-free.
        uint256 aUsdcBefore = IERC20(BaseAddresses.USDC).balanceOf(depositorA);
        vm.prank(depositorA);
        uint256 out = strategy.emergencyRedeem(id, 0);
        assertGt(out, 0, "emergencyRedeem paid nothing");
        assertEq(IERC20(BaseAddresses.USDC).balanceOf(depositorA) - aUsdcBefore, out, "A USDC mismatch");

        // Re-emergency on the settled request reverts.
        vm.prank(depositorA);
        vm.expectRevert(LeveragedAerodromeCLStrategy.RequestSettled.selector);
        strategy.emergencyRedeem(id, 0);

        vm.clearMockedCalls();
    }

    /// @notice Test 7 (cheap fuzz) — a request/cancel/fulfill sequence never strands shares: the
    ///         strategy's escrowed share balance always equals the sum of OPEN (unsettled) request
    ///         shares at every step.
    function testFuzz_asyncRedeem_escrowConservation(uint256 seed) public {
        if (_skip) return;
        uint256 sharesB = _depositB(20_000e6);
        // Split B's shares into 3 equal escrow-able chunks (small so fulfills clear).
        uint256 chunk = sharesB / 3;

        uint256 openShares; // ghost: Σ shares of open requests
        uint256[] memory ids = new uint256[](3);
        bool[] memory open = new bool[](3);

        // Open 3 requests.
        for (uint256 i; i < 3; i++) {
            vm.startPrank(depositorB);
            mockVault.approve(address(strategy), chunk);
            ids[i] = strategy.requestRedeem(chunk, 0);
            vm.stopPrank();
            open[i] = true;
            openShares += chunk;
            assertEq(mockVault.balanceOf(address(strategy)), openShares, "escrow != open-sum after request");
        }

        // Randomly cancel/fulfill each, asserting escrow conservation after every op.
        for (uint256 i; i < 3; i++) {
            if (!open[i]) continue;
            bool doCancel = (uint256(keccak256(abi.encode(seed, i))) % 2) == 0;
            if (doCancel) {
                vm.prank(depositorB);
                strategy.cancelRedeem(ids[i]);
            } else {
                vm.prank(proposer);
                strategy.fulfillRedeem(ids[i]);
            }
            open[i] = false;
            openShares -= chunk;
            assertEq(mockVault.balanceOf(address(strategy)), openShares, "escrow != open-sum after settle");
        }
        assertEq(openShares, 0, "ghost open-sum not drained");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // New-test helpers
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Mint shares for depositorB via a deposit and return the shares.
    function _depositB(uint256 amt) internal returns (uint256 sharesB) {
        _fundUSDC(depositorB, amt);
        vm.startPrank(depositorB);
        IERC20(BaseAddresses.USDC).approve(address(strategy), amt);
        sharesB = strategy.deposit(amt, 0);
        vm.stopPrank();
        assertGt(sharesB, 0, "B got 0 shares");
    }

    /// @dev Stale ALL THREE Chainlink price feeds (updatedAt in the deep past) → nav()/deposit revert.
    function _staleAllFeeds() internal {
        address[3] memory feeds =
            [BaseAddresses.CHAINLINK_BTC_USD, BaseAddresses.CHAINLINK_ETH_USD, BaseAddresses.CHAINLINK_USDC_USD];
        for (uint256 i; i < feeds.length; i++) {
            (uint80 rid, int256 answer,,,) = IAggregatorV3Min(feeds[i]).latestRoundData();
            vm.mockCall(
                feeds[i],
                abi.encodeWithSignature("latestRoundData()"),
                abi.encode(rid, answer, uint256(1), uint256(1), rid)
            );
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helpers for the stayer-skim probe
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Bounded in-band DOWN shove (sell WETH, stop at `targetTick` via sqrtPriceLimit) —
    ///      mirrors the rerange fork test's `_shoveToTick`. Stays inside the calm band so the
    ///      subsequent `rerange` calm-gate passes.
    function _shoveToTickDown(int24 targetTick) internal {
        address shover = makeAddr("redeem_inband_shover");
        uint256 wethIn = 1_000e18; // the sqrtPrice limit caps how much actually fills
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

    /// @dev Oracle NAV of the whole strategy WITHOUT the calm gate — the manipulation-immune fair
    ///      mark for stayer-conservation. Mirrors `LeveragedAeroValuation.netEquityUsdc`
    ///      term-for-term (oracle-implied sqrtP for the CL-leg split + Chainlink leg/debt prices),
    ///      minus `_calmGate` (so it stays computable at the shoved tick). Pool token0 == WETH.
    function _oracleNavNoGate(address strat) internal view returns (uint256) {
        (, int256 btc,,,) = IAggregatorV3Min(BaseAddresses.CHAINLINK_BTC_USD).latestRoundData();
        (, int256 eth,,,) = IAggregatorV3Min(BaseAddresses.CHAINLINK_ETH_USD).latestRoundData();
        (, int256 usd,,,) = IAggregatorV3Min(BaseAddresses.CHAINLINK_USDC_USD).latestRoundData();
        uint256 pBTC = uint256(btc);
        uint256 pETH = uint256(eth);
        uint256 pUsdc = uint256(usd);

        // idle USDC + Moonwell USDC collateral (face, 6dp)
        uint256 assets = IERC20(BaseAddresses.USDC).balanceOf(strat);
        uint256 cBal = ICToken(BaseAddresses.MOONWELL_MUSDC).balanceOf(strat);
        if (cBal > 0) assets += (cBal * ICToken(BaseAddresses.MOONWELL_MUSDC).exchangeRateStored()) / 1e18;

        // CL legs at the oracle-implied sqrtP (token0=WETH/18, token1=cbBTC/8)
        uint256 tid = LeveragedAerodromeCLStrategy(payable(strat)).layout().tokenId;
        if (tid != 0) {
            (,,,,, int24 tl, int24 tu, uint128 liq,,,,) = INpmFull(BaseAddresses.SLIPSTREAM_NPM).positions(tid);
            if (liq > 0) {
                uint160 sqrtP = LeveragedAeroValuation.oracleSqrtPriceX96(pETH, 18, pBTC, 8);
                (uint256 a0, uint256 a1) = LiquidityAmounts.getAmountsForLiquidity(
                    sqrtP, TickMath.getSqrtRatioAtTick(tl), TickMath.getSqrtRatioAtTick(tu), liq
                );
                assets += _usdcV(a0, 18, pETH, pUsdc); // WETH leg
                assets += _usdcV(a1, 8, pBTC, pUsdc); // cbBTC leg
            }
        }
        // idle (out-of-position) borrowed legs — the rerange remainder lives here
        assets += _usdcV(IERC20(CBBTC).balanceOf(strat), 8, pBTC, pUsdc);
        assets += _usdcV(IERC20(WETH).balanceOf(strat), 18, pETH, pUsdc);

        // debt (same Chainlink basis)
        uint256 debt = _usdcV(IMoonwellMarket(BaseAddresses.MOONWELL_MCBBTC).borrowBalanceStored(strat), 8, pBTC, pUsdc)
            + _usdcV(IMoonwellMarket(BaseAddresses.MOONWELL_MWETH).borrowBalanceStored(strat), 18, pETH, pUsdc);

        return assets > debt ? assets - debt : 0;
    }

    /// @dev token `amount` (`dec`-decimals) at USD price `pTok` (8dp) → USDC face (6dp), honoring
    ///      the USDC peg `pUsdc` (8dp). Same scaling as `LeveragedAeroForkBase._usdcValueNaive`.
    function _usdcV(uint256 amount, uint8 dec, uint256 pTok, uint256 pUsdc) private pure returns (uint256) {
        if (amount == 0 || pTok == 0 || pUsdc == 0) return 0;
        return ((amount * pTok / (10 ** uint256(dec))) * 1e6) / pUsdc;
    }
}
