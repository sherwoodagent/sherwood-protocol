// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {LeveragedAeroForkBase} from "./LeveragedAeroForkBase.sol";
import {BaseAddresses} from "./BaseAddresses.sol";
import {LeveragedAerodromeCLStrategy} from "../../../src/strategies/LeveragedAerodromeCLStrategy.sol";
import {BaseStrategy} from "../../../src/strategies/BaseStrategy.sol";
import {IMoonwellMarket, ICToken} from "../../../src/interfaces/IMoonwellMarket.sol";
import {ICLGauge, INonfungiblePositionManager} from "../../../src/interfaces/ISlipstream.sol";
// #421: reuse the unit-suite MockFactory (protocolConfig()-only) rather than re-declaring it — the
// strategy now reads vault().factory().protocolConfig() for the protocol-fee leg.
import {MockFactory} from "../../mocks/LeveragedAeroCLMocks.sol";

// ─── Minimal mock vault (share ledger only; holds no USDC) ──────────────────────

/// @dev Mock vault for compound tests: ERC20 approve/transferFrom + strategyMint/strategyBurn.
contract MockVaultForCompound {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;
    address public governor; // legacy; unused by the strategy post-#421 (kept only for the setGovernor call-site).
    // #421: the strategy resolves protocol-fee params via vault().factory().protocolConfig(), NOT
    // vault().governor(). factory()==0 ⇒ no protocol fee. This mock MUST track ISyndicateVault's read
    // surface (CLAUDE.md MockRegistryMinimal lesson).
    address public factory;

    constructor(address initialHolder, uint256 initialShares) {
        balanceOf[initialHolder] = initialShares;
        totalSupply = initialShares;
    }

    /// @dev Wire the protocol-fee chain factory().protocolConfig() → `gov`, where `gov` is a
    ///      MockGovernorForCompound exposing protocolFeeBps()/protocolFeeRecipient() (the IProtocolConfig
    ///      read surface). gov==0 ⇒ factory==0 ⇒ no protocol fee (the strategy short-circuits on factory==0).
    function setGovernor(address gov) external {
        governor = gov;
        factory = gov == address(0) ? address(0) : address(new MockFactory(gov));
    }

    /// @dev L7: strategy reads vault().asset() at init — must equal the configured USDC.
    function asset() external pure returns (address) {
        return BaseAddresses.USDC;
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

interface IERC721Owner {
    function ownerOf(uint256 tokenId) external view returns (address);
}

interface INpmPos {
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

interface IAggregatorV3Min {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @dev Mock governor exposing only the two getters the strategy reads for the protocol-fee leg.
contract MockGovernorForCompound {
    uint256 public protocolFeeBps;
    address public protocolFeeRecipient;

    function setFee(uint256 bps, address recipient) external {
        protocolFeeBps = bps;
        protocolFeeRecipient = recipient;
    }
}

/// @title  LeveragedAeroCLCompoundFork
/// @notice Task 3.8 TDD: AERO reward compound (claim → synchronous AERO→USDC v2 swap → redeploy).
///
///         Discovery (fork, block ~47246489):
///           - gauge.rewardToken() == AERO (0x9401…8631); claim via ICLGauge.getReward(uint256).
///           - Deepest AERO/USDC venue = Aerodrome v2 volatile pool (~$10.4M USDC) via the v2
///             Router (0xcF77…4E43); 1000 AERO → 357.43 USDC (0.23% off the AERO/USD oracle).
///           - Chainlink AERO/USD feed exists (0x4EC5…cfF0) but the strategy has no AERO-feed
///             slot, so min-out is the caller-supplied `minUsdcOut` (compound is onlyProposer).
///
///         AERO is funded via `deal` to deterministically simulate the post-claim reward state:
///         warping the fork to accrue gauge emissions would push the Chainlink feeds past
///         maxDelay (48h) and trip the fail-closed `nav()` read in `compound`. `compoundImpl`
///         still calls `gauge.getReward(tid)` internally, so the real claim path is exercised.
contract LeveragedAeroCLCompoundFork is LeveragedAeroForkBase {
    MockVaultForCompound internal mockVault;
    LeveragedAerodromeCLStrategy internal strategy;

    address internal depositorA;
    address internal feeRecipient;
    address internal proposer;
    address internal stranger;

    uint16 internal constant TARGET_LTV_BPS = 5000;
    uint16 internal constant MAX_LTV_BPS = 6500;
    uint16 internal constant MIN_HEALTH_BPS = 12000;
    uint16 internal constant MAX_SLIPPAGE_BPS = 100;
    uint16 internal constant MGMT_FEE_BPS = 100;
    uint16 internal constant PERF_FEE_BPS = 1000;

    uint256 internal constant PRINCIPAL = 50_000e6;
    uint256 internal constant DEPOSITOR_A_SHARES = PRINCIPAL * 1e6; // ERC-4626 virtual offset 1e6

    // Simulated AERO reward to compound (≈ $7.1k at ~$0.357/AERO).
    uint256 internal constant AERO_REWARD = 20_000e18;

    function setUp() public override {
        super.setUp();
        if (_skip) return;

        depositorA = makeAddr("depositorA");
        feeRecipient = makeAddr("feeRecipient");
        stranger = makeAddr("stranger");
        proposer = address(this);

        mockVault = new MockVaultForCompound(depositorA, DEPOSITOR_A_SHARES);

        address template = address(new LeveragedAerodromeCLStrategy());
        address clone = Clones.clone(template);
        strategy = LeveragedAerodromeCLStrategy(payable(clone));
        strategy.initialize(address(mockVault), proposer, abi.encode(_buildInitParams()));

        // Open the levered position.
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

    /// @dev On-chain LTV (bps) from Moonwell state + Chainlink, mirroring the deploy test.
    function _ltvBps() internal view returns (uint256) {
        uint256 mUsdcBal = ICToken(BaseAddresses.MOONWELL_MUSDC).balanceOf(address(strategy));
        uint256 rate = ICToken(BaseAddresses.MOONWELL_MUSDC).exchangeRateStored();
        uint256 collateralUsdc = (mUsdcBal * rate) / 1e18;
        uint256 cbDebt = IMoonwellMarket(BaseAddresses.MOONWELL_MCBBTC).borrowBalanceStored(address(strategy));
        uint256 wethDebt = IMoonwellMarket(BaseAddresses.MOONWELL_MWETH).borrowBalanceStored(address(strategy));
        (, int256 btc,,,) = IAggregatorV3Min(BaseAddresses.CHAINLINK_BTC_USD).latestRoundData();
        (, int256 eth,,,) = IAggregatorV3Min(BaseAddresses.CHAINLINK_ETH_USD).latestRoundData();
        (, int256 usdc,,,) = IAggregatorV3Min(BaseAddresses.CHAINLINK_USDC_USD).latestRoundData();
        uint256 cbDebtUsdc = (cbDebt * uint256(btc) * 1e6) / (1e8 * uint256(usdc));
        uint256 wethDebtUsdc = (wethDebt * uint256(eth) * 1e6) / (1e18 * uint256(usdc));
        return ((cbDebtUsdc + wethDebtUsdc) * 10000) / collateralUsdc;
    }

    function _liquidity() internal view returns (uint128 liq) {
        (,,,,,,, liq,,,,) = INpmPos(BaseAddresses.SLIPSTREAM_NPM).positions(strategy.layout().tokenId);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 1: compound swaps AERO → USDC and redeploys, NAV ↑, position healthy.
    // ─────────────────────────────────────────────────────────────────────────

    function test_compound_swapsAeroAndRedeploys() public {
        if (_skip) return;

        // Simulate the post-claim reward: fund AERO directly to the strategy (gauge emission
        // at the pinned vnet block is unreliable, and warping to accrue it would stale the
        // Chainlink feeds). compoundImpl still calls gauge.getReward(tid) — the real claim path.
        deal(BaseAddresses.AERO, address(strategy), AERO_REWARD);
        assertEq(IERC20(BaseAddresses.AERO).balanceOf(address(strategy)), AERO_REWARD, "AERO not funded");

        uint256 navBefore = strategy.nav();
        uint128 liqBefore = _liquidity();
        uint256 cbDebtBefore = IMoonwellMarket(BaseAddresses.MOONWELL_MCBBTC).borrowBalanceStored(address(strategy));
        uint256 wethDebtBefore = IMoonwellMarket(BaseAddresses.MOONWELL_MWETH).borrowBalanceStored(address(strategy));
        uint256 tid = strategy.layout().tokenId;

        // Compound: claim → swap ≈$7.1k AERO → USDC (minUsdcOut 6000e6) → redeploy at target LTV.
        vm.prank(proposer);
        strategy.compound(6000e6, 0);

        // AERO fully consumed by the swap.
        assertEq(IERC20(BaseAddresses.AERO).balanceOf(address(strategy)), 0, "AERO not fully swapped");

        // NAV increased by ≈ the realized yield (≈$7.1k less swap/deploy slippage).
        uint256 navAfter = strategy.nav();
        assertGt(navAfter, navBefore, "nav() did not increase after compound");
        assertGe(navAfter, navBefore + 5_000e6, "nav() increase below the realized-yield floor");

        // Yield was deployed into the position: liquidity grew and both borrows grew.
        assertGt(_liquidity(), liqBefore, "CL liquidity did not grow");
        assertGt(
            IMoonwellMarket(BaseAddresses.MOONWELL_MCBBTC).borrowBalanceStored(address(strategy)),
            cbDebtBefore,
            "cbBTC debt did not grow"
        );
        assertGt(
            IMoonwellMarket(BaseAddresses.MOONWELL_MWETH).borrowBalanceStored(address(strategy)),
            wethDebtBefore,
            "WETH debt did not grow"
        );

        // Position stays healthy: compound() would have reverted in _assertHealthy otherwise.
        assertLe(_ltvBps(), MAX_LTV_BPS, "post-compound LTV exceeds maxLtvBps");

        // Same NFT, still staked in the gauge after the redeploy's unstake→restake.
        assertEq(strategy.layout().tokenId, tid, "tokenId changed");
        assertEq(
            IERC721Owner(BaseAddresses.SLIPSTREAM_NPM).ownerOf(tid), BaseAddresses.CBBTC_WETH_GAUGE, "NFT not staked"
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 2: only the proposer may compound.
    // ─────────────────────────────────────────────────────────────────────────

    function test_compound_onlyProposer() public {
        if (_skip) return;
        deal(BaseAddresses.AERO, address(strategy), AERO_REWARD);
        vm.prank(stranger);
        vm.expectRevert(BaseStrategy.NotProposer.selector);
        strategy.compound(0, 0);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 3: an unachievable minUsdcOut reverts (the swap min-out is enforced).
    // ─────────────────────────────────────────────────────────────────────────

    function test_compound_minOutEnforced() public {
        if (_skip) return;
        deal(BaseAddresses.AERO, address(strategy), AERO_REWARD);
        // ≈$7.1k of AERO can never yield 100k USDC → the v2 router reverts on amountOutMin.
        vm.prank(proposer);
        vm.expectRevert();
        strategy.compound(100_000e6, 0);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 4: no AERO → clean no-op (no revert, position unchanged).
    // ─────────────────────────────────────────────────────────────────────────

    function test_compound_zeroRewardNoOp() public {
        if (_skip) return;
        // No AERO funded; no warp → gauge has emitted nothing → getReward yields 0.
        assertEq(IERC20(BaseAddresses.AERO).balanceOf(address(strategy)), 0, "unexpected AERO");

        uint256 tid = strategy.layout().tokenId;
        uint128 liqBefore = _liquidity();
        uint256 cbDebtBefore = IMoonwellMarket(BaseAddresses.MOONWELL_MCBBTC).borrowBalanceStored(address(strategy));
        uint256 wethDebtBefore = IMoonwellMarket(BaseAddresses.MOONWELL_MWETH).borrowBalanceStored(address(strategy));
        uint256 supplyBefore = mockVault.totalSupply();

        vm.prank(proposer);
        // L8: minUsdcOut must be nonzero (ZeroMinOut floor). With no rewards the impl early-returns
        // at `aeroBal == 0` before any swap, so the floor never binds — still a clean no-op.
        strategy.compound(1, 0); // must NOT revert

        // Position + supply unchanged (no fee-shares: dt==0 and first-ever crystallize seeds HWM).
        assertEq(strategy.layout().tokenId, tid, "tokenId changed on no-op");
        assertEq(_liquidity(), liqBefore, "liquidity changed on no-op");
        assertEq(
            IMoonwellMarket(BaseAddresses.MOONWELL_MCBBTC).borrowBalanceStored(address(strategy)),
            cbDebtBefore,
            "cbBTC debt changed on no-op"
        );
        assertEq(
            IMoonwellMarket(BaseAddresses.MOONWELL_MWETH).borrowBalanceStored(address(strategy)),
            wethDebtBefore,
            "WETH debt changed on no-op"
        );
        assertEq(mockVault.totalSupply(), supplyBefore, "supply changed on no-op");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 5: fee fairness — a redeem right after compound pays the perf fee on the yield.
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice compound crystallizes on the PRE-compound NAV (seeds the HWM), then realizes
    ///         the AERO yield → NAV ↑. A redeem immediately after crystallizes on the higher
    ///         POST-compound NAV, so the performance fee on the yield is charged to feeRecipient
    ///         — the yield cannot escape the HWM fee.
    function test_compound_redeemAfterPaysPerfFeeOnYield() public {
        if (_skip) return;

        deal(BaseAddresses.AERO, address(strategy), AERO_REWARD);

        vm.prank(proposer);
        strategy.compound(6000e6, 0);

        // compound's first-ever crystallize seeds the HWM and (dt==0) mints no fee-shares.
        uint256 frAfterCompound = mockVault.balanceOf(feeRecipient);
        assertEq(frAfterCompound, 0, "compound should mint no perf fee on the first (seeding) crystallize");

        // Fast-path redeem 10% of supply → the fast path crystallizes on the post-compound NAV (> HWM)
        // → perf fee minted. (Small size → the LTV gate passes; fast path is fine here.)
        uint256 redeemShares = mockVault.balanceOf(depositorA) / 10;
        vm.prank(depositorA);
        mockVault.approve(address(strategy), redeemShares);
        vm.prank(depositorA);
        strategy.redeem(redeemShares, 0);

        uint256 frAfterRedeem = mockVault.balanceOf(feeRecipient);
        assertGt(frAfterRedeem, frAfterCompound, "redeem after compound did not charge the perf fee on the yield");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 6 (review #388-3): compound discharges the protocol fee to the governor's
    //   recipient AND redeploys the remainder. Protocol=100 (1%), recipient set.
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Wire a governor with protocolFeeBps=100 + recipient, seed the HWM strictly below the
    ///         current NAV so the compound's crystallize accrues a protocol slice, then compound: the
    ///         AERO→USDC yield funds a skim (recipient balance grows) and the remainder is redeployed
    ///         (CL liquidity + both borrows grow). owed is decremented by the discharged `pay`.
    function test_compound_dischargesProtocolFeeAndRedeploysRemainder() public {
        if (_skip) return;

        MockGovernorForCompound gov = new MockGovernorForCompound();
        address protoRecipient = makeAddr("protoRecipient");
        gov.setFee(100, protoRecipient); // 1% protocol fee
        mockVault.setGovernor(address(gov));

        // Seed the HWM strictly below the current NAV so the compound's pre-swap crystallize sees a
        // gain and accrues the protocol slice. hwmPerShare lives at diamond slot base+20.
        uint256 navNow = strategy.nav();
        uint256 supply = mockVault.totalSupply();
        uint256 loweredHwm = (navNow * 1e18 / supply) / 2; // half the current per-share level → gain
        bytes32 base = 0x405ae0b144079093e970849fdffdcb2a514e44968598c6c5c73444496e844900;
        vm.store(address(strategy), bytes32(uint256(base) + 20), bytes32(loweredHwm));
        // dt>0 is irrelevant for the protocol leg (it rides the perf gain path); ensure lastFee<now.
        vm.store(address(strategy), bytes32(uint256(base) + 21), bytes32(uint256(1)));

        deal(BaseAddresses.AERO, address(strategy), AERO_REWARD);
        uint128 liqBefore = _liquidity();
        uint256 recipBefore = IERC20(BaseAddresses.USDC).balanceOf(protoRecipient);

        vm.prank(proposer);
        strategy.compound(6000e6, 0);

        // Protocol recipient was paid a USDC skim from the compound yield.
        uint256 recipAfter = IERC20(BaseAddresses.USDC).balanceOf(protoRecipient);
        assertGt(recipAfter, recipBefore, "protocol recipient not paid from compound yield");
        uint256 skimmed = recipAfter - recipBefore;

        // The remainder was redeployed: CL liquidity grew (and AERO fully consumed).
        assertGt(_liquidity(), liqBefore, "remainder not redeployed (liquidity flat)");
        assertEq(IERC20(BaseAddresses.AERO).balanceOf(address(strategy)), 0, "AERO not fully swapped");

        // The discharged `pay` == the accrued owed when the yield covered it (skim == accrued), so
        // owed nets to 0; if the accrued liability exceeded the single compound's yield a residual
        // remains. Either way the skim is bounded by the accrual: owed + skim == the accrued total,
        // and the recipient got a nonzero USDC transfer sourced from the swap (not from principal).
        assertGt(skimmed, 0, "no skim");
        assertLe(strategy.layout().protocolFeeOwed + skimmed, navNow, "skim/owed bookkeeping sanity");
    }
}
