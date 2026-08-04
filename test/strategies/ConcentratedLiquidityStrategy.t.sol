// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockERC4626Wrapper} from "../mocks/MockERC4626Wrapper.sol";
import {MockMorpho, MockIrm} from "../mocks/MockMorpho.sol";
import {MockProposalStatus} from "../mocks/MockProposalStatus.sol";
import {MockSwapAdapter} from "../mocks/MockSwapAdapter.sol";
import {MockUniswapV3Pool} from "../mocks/MockUniswapV3Pool.sol";
import {MockPositionManager} from "../mocks/MockPositionManager.sol";

import {ConcentratedLiquidityStrategy} from "../../src/strategies/ConcentratedLiquidityStrategy.sol";
import {BaseStrategy} from "../../src/strategies/BaseStrategy.sol";
import {Id, MarketParams} from "../../src/vendor/morpho/IMorpho.sol";

/// @notice Minimal vault stand-in — the strategy reads `asset()` and, inside
///         `execute()`, `governor()` for BaseStrategy's active-proposal binding.
contract VaultStub {
    /// @dev `BaseStrategy.onlyProposer` re-checks the vault's live agent set on
    ///      every proposer-gated call, so a vault stand-in must answer this or
    ///      `updateParams` fails closed. Mirrors `MorphoSupplyStrategy`'s stub.
    function isAgent(address) external pure returns (bool) {
        return true;
    }

    address internal immutable _assetToken;
    address public governor;

    constructor(address assetToken_, address governor_) {
        _assetToken = assetToken_;
        governor = governor_;
    }

    function asset() external view returns (address) {
        return _assetToken;
    }
}

/// @notice Shared fixture: a 6-decimal USDG-like vault asset, an 18-decimal
///         volatile leg, a funded Morpho market whose collateral is an ERC-4626
///         wrapper OF the vault asset (the `spUSDG/USDG` shape measured on chain
///         4663), a pool whose spot and TWAP are driven independently, and an
///         initialized clone.
abstract contract CLFixture is Test {
    uint256 constant COLLATERAL = 100_000e6;
    uint256 constant BORROW = 50_000e6;
    uint256 constant MARKET_SUPPLY = 1_000_000e6;
    /// @dev In `MockPositionManager`'s liquidity unit — `sqrt(amount0*amount1)`
    ///      across a 6-decimal and an 18-decimal leg, so ~1e15 for the default
    ///      position. Sized so the 10% pool-share cap sits an order of magnitude
    ///      above that, leaving the cap tests room to cross it deliberately.
    uint128 constant POOL_LIQUIDITY = 1e18;
    uint128 constant EXPECTED_LIQUIDITY = 1e16;

    int24 constant TICK_SPACING = 10;
    int24 constant TICK_LOWER = -1000;
    int24 constant TICK_UPPER = 1000;
    uint24 constant POOL_FEE = 500;

    uint32 constant TWAP_WINDOW = 1800;
    uint256 constant MAX_DEVIATION_BPS = 100;

    ERC20Mock usdg;
    ERC20Mock nvda;
    MockERC4626Wrapper spUsdg;
    MockIrm irm;
    MockMorpho morpho;
    MockUniswapV3Pool pool;
    MockPositionManager posm;
    MockSwapAdapter adapter;
    MockProposalStatus status;
    VaultStub vaultStub;

    MarketParams mp;
    Id marketId;

    ConcentratedLiquidityStrategy template;
    ConcentratedLiquidityStrategy strategy;

    address factory = makeAddr("uniswapFactory");
    address proposer = makeAddr("proposer");
    address keeper = makeAddr("keeper");
    address supplier = makeAddr("supplier");

    function setUp() public virtual {
        usdg = new ERC20Mock("USDG", "USDG", 6);
        nvda = new ERC20Mock("NVDA", "NVDA", 18);
        spUsdg = new MockERC4626Wrapper(IERC20(address(usdg)), "spUSDG", "spUSDG");

        irm = new MockIrm();
        irm.setRate(uint256(0.05e18) / 365 days);
        morpho = new MockMorpho();

        mp = MarketParams({
            loanToken: address(usdg),
            collateralToken: address(spUsdg),
            oracle: makeAddr("oracle"),
            irm: address(irm),
            lltv: 0.915e18
        });
        marketId = morpho.createMarket(mp);
        _fundMarket(mp);

        pool = new MockUniswapV3Pool(address(usdg), address(nvda), POOL_FEE, TICK_SPACING, factory);
        pool.setLiquidity(POOL_LIQUIDITY);
        pool.setTicks(0, 0);

        posm = new MockPositionManager(factory);
        adapter = new MockSwapAdapter();
        // 1 USDG (6dp) -> 0.01 NVDA (18dp): rate is scaled 1e18 and must absorb
        // the 12-decimal gap between the two tokens.
        adapter.setRate(address(usdg), address(nvda), 1e18 * 1e12 / 100);
        adapter.setRate(address(nvda), address(usdg), 100 * 1e18 / 1e12);
        nvda.mint(address(adapter), 1_000_000e18);
        usdg.mint(address(adapter), 1_000_000e6);

        status = new MockProposalStatus();
        vaultStub = new VaultStub(address(usdg), address(status));
        usdg.mint(address(vaultStub), COLLATERAL * 10);

        template = new ConcentratedLiquidityStrategy();
        strategy = _newStrategy(_defaultParams());
        status.set(1, 1, address(strategy));

        vm.prank(address(vaultStub));
        usdg.approve(address(strategy), type(uint256).max);
    }

    /// @dev Supply the loan side so a borrow against this market is fundable.
    ///      Every market a test constructs needs this — the init-time
    ///      `BorrowExceedsLiquidity` check reads live lendable liquidity, so an
    ///      unfunded market fails that check before reaching whatever the test
    ///      was actually about.
    function _fundMarket(MarketParams memory mpArg) internal {
        usdg.mint(supplier, MARKET_SUPPLY);
        vm.startPrank(supplier);
        usdg.approve(address(morpho), MARKET_SUPPLY);
        morpho.supply(mpArg, MARKET_SUPPLY, 0, supplier, "");
        vm.stopPrank();
    }

    function _defaultParams() internal view returns (ConcentratedLiquidityStrategy.InitParams memory p) {
        p = ConcentratedLiquidityStrategy.InitParams({
            pool: address(pool),
            positionManager: address(posm),
            uniswapFactory: factory,
            swapAdapter: address(adapter),
            morpho: address(morpho),
            marketParams: mp,
            collateralAmount: COLLATERAL,
            borrowAmount: BORROW,
            tickLower: TICK_LOWER,
            tickUpper: TICK_UPPER,
            expectedLiquidity: EXPECTED_LIQUIDITY,
            swapFractionBps: 5_000,
            twapWindow: TWAP_WINDOW,
            maxTwapDeviationBps: MAX_DEVIATION_BPS,
            mintSlippageBps: 500,
            rerange: ConcentratedLiquidityStrategy.RerangePolicy({
                halfWidthTicks: 1000,
                triggerBps: 8_000,
                minInterval: 1 hours,
                maxReranges: 3,
                slippageBps: 500,
                swapFractionBps: 5_000
            }),
            settleSlippageBps: 500,
            settleDeadline: 0,
            swapExtraData: ""
        });
    }

    function _newStrategy(ConcentratedLiquidityStrategy.InitParams memory p)
        internal
        returns (ConcentratedLiquidityStrategy s)
    {
        s = ConcentratedLiquidityStrategy(Clones.clone(address(template)));
        s.initialize(address(vaultStub), proposer, abi.encode(p));
    }

    /// @dev Assert that INITIALIZE reverts with `err`.
    ///      The clone and the `abi.encode` are hoisted deliberately: `vm.expectRevert`
    ///      is a one-shot that binds to the very next call, and `Clones.clone` is a
    ///      CREATE. Arming the cheatcode before it makes the cheatcode intercept the
    ///      deployment instead of the initializer, and every negative init test then
    ///      fails with `FailedDeployment()` no matter what the contract actually does.
    function _expectInitRevert(bytes4 err, ConcentratedLiquidityStrategy.InitParams memory p) internal {
        ConcentratedLiquidityStrategy s = ConcentratedLiquidityStrategy(Clones.clone(address(template)));
        bytes memory data = abi.encode(p);
        address v = address(vaultStub);
        vm.expectRevert(err);
        s.initialize(v, proposer, data);
    }

    function _execute() internal {
        vm.prank(address(vaultStub));
        strategy.execute();
    }

    function _settle() internal {
        vm.prank(address(vaultStub));
        strategy.settle();
    }
}

contract ConcentratedLiquidityStrategyLifecycleTest is CLFixture {
    // ── 6.1 Lifecycle ──

    function test_execute_mintsExactlyOnePosition() public {
        _execute();
        assertEq(uint256(strategy.state()), uint256(BaseStrategy.State.Executed));
        assertGt(strategy.tokenId(), 0, "no position minted");
        assertEq(morpho.position(marketId, address(strategy)).collateral > 0, true, "collateral not posted");
    }

    /// @dev The clone-ratchet bypass (issue #150): a foreign proposal's batch
    ///      reaching this clone's `execute()` would flip the one-shot ratchet and
    ///      permanently brick the clone's own later proposal.
    function test_execute_fromForeignProposalReverts() public {
        status.set(1, 1, makeAddr("someOtherStrategy"));
        vm.prank(address(vaultStub));
        vm.expectRevert(BaseStrategy.NotActiveProposalStrategy.selector);
        strategy.execute();
        assertEq(uint256(strategy.state()), uint256(BaseStrategy.State.Pending), "ratchet flipped");
    }

    /// @dev The init-time cap bounds the agent's CLAIM; this is the enforceable
    ///      version, checked against the liquidity actually minted and against
    ///      the venue as it stands at execute rather than as it stood at
    ///      proposal time. Depth that evaporated between the two must fail here.
    function test_execute_poolShareCapIsRecheckedAgainstTheLiveVenue() public {
        // Admissible at init against the 1e18 the pool held. By execute the
        // venue has collapsed to a thousandth of that, so the 10% cap can no
        // longer admit the position the borrow actually mints.
        pool.setLiquidity(uint128(uint256(POOL_LIQUIDITY) / 1_000));

        vm.prank(address(vaultStub));
        vm.expectRevert(ConcentratedLiquidityStrategy.PositionExceedsPoolShareCap.selector);
        strategy.execute();
    }

    /// @dev `unwindPosition` is external ONLY so `_settle` can `try/catch` it as
    ///      a unit. It moves the position and clears `tokenId`, so anything but
    ///      a self-call must be refused.
    function test_unwindPosition_onlySelfReverts() public {
        _execute();
        vm.prank(keeper);
        vm.expectRevert(ConcentratedLiquidityStrategy.NotSelf.selector);
        strategy.unwindPosition();

        vm.prank(proposer);
        vm.expectRevert(ConcentratedLiquidityStrategy.NotSelf.selector);
        strategy.unwindPosition();
    }

    function test_execute_twiceReverts() public {
        _execute();
        vm.prank(address(vaultStub));
        vm.expectRevert(BaseStrategy.AlreadyExecuted.selector);
        strategy.execute();
    }

    function test_settle_beforeExecuteReverts() public {
        vm.prank(address(vaultStub));
        vm.expectRevert(BaseStrategy.NotExecuted.selector);
        strategy.settle();
    }

    function test_execute_onlyVault() public {
        vm.prank(keeper);
        vm.expectRevert(BaseStrategy.NotVault.selector);
        strategy.execute();
    }

    function test_name() public view {
        assertEq(strategy.name(), "Concentrated Liquidity LP");
    }
}

contract ConcentratedLiquidityStrategyInitTest is CLFixture {
    // ── 6.2 Init validation, one test per check ──

    function test_init_poolNotFromFactoryReverts() public {
        MockUniswapV3Pool rogue = new MockUniswapV3Pool(address(usdg), address(nvda), POOL_FEE, TICK_SPACING, factory);
        rogue.setFactory(makeAddr("attackerFactory"));
        ConcentratedLiquidityStrategy.InitParams memory p = _defaultParams();
        p.pool = address(rogue);
        _expectInitRevert(ConcentratedLiquidityStrategy.PoolNotFromFactory.selector, p);
    }

    function test_init_poolDoesNotQuoteVaultAssetReverts() public {
        ERC20Mock other = new ERC20Mock("OTHER", "OTHER", 18);
        MockUniswapV3Pool bad = new MockUniswapV3Pool(address(other), address(nvda), POOL_FEE, TICK_SPACING, factory);
        ConcentratedLiquidityStrategy.InitParams memory p = _defaultParams();
        p.pool = address(bad);
        _expectInitRevert(ConcentratedLiquidityStrategy.PoolAssetMismatch.selector, p);
    }

    function test_init_loanAssetMismatchReverts() public {
        ConcentratedLiquidityStrategy.InitParams memory p = _defaultParams();
        p.marketParams.loanToken = address(nvda);
        _expectInitRevert(ConcentratedLiquidityStrategy.LoanAssetMismatch.selector, p);
    }

    function test_init_marketNotCreatedReverts() public {
        ConcentratedLiquidityStrategy.InitParams memory p = _defaultParams();
        p.marketParams.oracle = makeAddr("unknownOracle"); // changes the derived id
        _expectInitRevert(ConcentratedLiquidityStrategy.MarketNotCreated.selector, p);
    }

    /// @dev Collateralizing the volatile leg is the shape the design rejects on
    ///      measured liquidity — every tokenized-equity market on 4663 held
    ///      $0–$1.6k lendable.
    function test_init_volatileLegAsCollateralReverts() public {
        MarketParams memory bad = mp;
        bad.collateralToken = address(nvda);
        morpho.createMarket(bad);
        ConcentratedLiquidityStrategy.InitParams memory p = _defaultParams();
        p.marketParams = bad;
        _expectInitRevert(ConcentratedLiquidityStrategy.CollateralAssetMismatch.selector, p);
    }

    function test_init_unrelatedCollateralReverts() public {
        ERC20Mock unrelated = new ERC20Mock("XYZ", "XYZ", 18);
        MarketParams memory bad = mp;
        bad.collateralToken = address(unrelated);
        morpho.createMarket(bad);
        ConcentratedLiquidityStrategy.InitParams memory p = _defaultParams();
        p.marketParams = bad;
        _expectInitRevert(ConcentratedLiquidityStrategy.CollateralAssetMismatch.selector, p);
    }

    /// @dev The vault asset posted directly is admissible, not only a wrapper.
    function test_init_vaultAssetAsCollateralSucceeds() public {
        MarketParams memory direct = mp;
        direct.collateralToken = address(usdg);
        morpho.createMarket(direct);
        _fundMarket(direct);
        ConcentratedLiquidityStrategy.InitParams memory p = _defaultParams();
        p.marketParams = direct;
        ConcentratedLiquidityStrategy s = _newStrategy(p);
        assertEq(s.marketParams().collateralToken, address(usdg));
    }

    function test_init_borrowExceedsLendableReverts() public {
        ConcentratedLiquidityStrategy.InitParams memory p = _defaultParams();
        // Lendable liquidity is checked BEFORE the LTV gate, so an oversized
        // borrow trips this even though it is also far past the buffer.
        p.borrowAmount = MARKET_SUPPLY * 2;
        _expectInitRevert(ConcentratedLiquidityStrategy.BorrowExceedsLiquidity.selector, p);
    }

    function test_init_ltvInsideLiquidationBufferReverts() public {
        ConcentratedLiquidityStrategy.InitParams memory p = _defaultParams();
        // lltv 91.5% - 5pp buffer = 86.5% ceiling; ask for 90% of the
        // COLLATERAL (100_000e6), which the fee-free wrapper values 1:1.
        p.borrowAmount = 90_000e6;
        _expectInitRevert(ConcentratedLiquidityStrategy.LtvInsideLiquidationBuffer.selector, p);
    }

    function test_init_ltvJustInsideBufferSucceeds() public {
        ConcentratedLiquidityStrategy.InitParams memory p = _defaultParams();
        p.borrowAmount = 86_500e6; // exactly the ceiling
        ConcentratedLiquidityStrategy s = _newStrategy(p);
        assertEq(s.borrowAmount(), 86_500e6);
    }

    /// @dev The LTV gate divides by a value READ FROM THE COLLATERAL TOKEN, not
    ///      one supplied at init. `InitParams` carries no collateral-value field
    ///      to overstate, so this is the only remaining way the denominator can
    ///      move — and it moves in the wrapper's favour, never the proposer's.
    ///
    ///      A borrow that sits exactly at the ceiling against a fee-free wrapper
    ///      must be REFUSED once the same wrapper charges a round-trip fee,
    ///      because the collateral is genuinely worth less on the way out. If
    ///      the gate were still reading an init-data figure, nothing about
    ///      changing the wrapper would alter the verdict.
    function test_init_ltvUsesWrapperRedemptionValueNotADeclaredOne() public {
        ConcentratedLiquidityStrategy.InitParams memory p = _defaultParams();
        p.borrowAmount = 86_500e6; // the ceiling at a 1:1 round trip

        // Same params, admissible a moment ago (test above).
        spUsdg.setExitFeeBps(100); // 1% out; 100_000e6 now redeems for 99_000e6
        // 86_500 / 99_000 = 87.4% > the 86.5% ceiling.
        _expectInitRevert(ConcentratedLiquidityStrategy.LtvInsideLiquidationBuffer.selector, p);

        // And the same borrow re-priced against the lower value is admissible
        // again, so the gate is tracking the wrapper rather than just refusing.
        p.borrowAmount = 85_600e6; // 85_600 / 99_000 = 86.46%
        ConcentratedLiquidityStrategy s = _newStrategy(p);
        assertEq(s.borrowAmount(), 85_600e6);
    }

    function test_init_exceedsPoolShareCapReverts() public {
        ConcentratedLiquidityStrategy.InitParams memory p = _defaultParams();
        // Cap is 10% of in-range liquidity.
        p.expectedLiquidity = uint128(uint256(POOL_LIQUIDITY) / 10 + 1);
        _expectInitRevert(ConcentratedLiquidityStrategy.PositionExceedsPoolShareCap.selector, p);
    }

    function test_init_invertedTickRangeReverts() public {
        ConcentratedLiquidityStrategy.InitParams memory p = _defaultParams();
        (p.tickLower, p.tickUpper) = (TICK_UPPER, TICK_LOWER);
        _expectInitRevert(ConcentratedLiquidityStrategy.InvalidTickRange.selector, p);
    }

    function test_init_emptyTickRangeReverts() public {
        ConcentratedLiquidityStrategy.InitParams memory p = _defaultParams();
        p.tickUpper = p.tickLower;
        _expectInitRevert(ConcentratedLiquidityStrategy.InvalidTickRange.selector, p);
    }

    function test_init_misalignedTickRangeReverts() public {
        ConcentratedLiquidityStrategy.InitParams memory p = _defaultParams();
        p.tickUpper = TICK_UPPER + 1; // not a multiple of spacing 10
        _expectInitRevert(ConcentratedLiquidityStrategy.InvalidTickRange.selector, p);
    }

    // ── Rerange-policy validation (4.1) ──

    function test_init_rerangeHalfWidthBelowSpacingReverts() public {
        ConcentratedLiquidityStrategy.InitParams memory p = _defaultParams();
        p.rerange.halfWidthTicks = TICK_SPACING - 1;

        _expectInitRevert(ConcentratedLiquidityStrategy.InvalidRerangePolicy.selector, p);
    }

    /// @dev A half-width wider than the tick domain cannot describe a band any
    ///      voter meant to approve, and `_derivedRange` would silently clamp it
    ///      to full-range — a materially different position from the reviewed
    ///      one. Rejected here so the clamp only ever handles a legitimate band
    ///      running off the domain near an extreme tick.
    function test_init_rerangeHalfWidthAboveCeilingReverts() public {
        ConcentratedLiquidityStrategy.InitParams memory p = _defaultParams();
        p.rerange.halfWidthTicks = template.MAX_HALF_WIDTH_TICKS() + 1;

        _expectInitRevert(ConcentratedLiquidityStrategy.InvalidRerangePolicy.selector, p);
    }

    function test_init_rerangeTriggerZeroReverts() public {
        ConcentratedLiquidityStrategy.InitParams memory p = _defaultParams();
        p.rerange.triggerBps = 0;
        _expectInitRevert(ConcentratedLiquidityStrategy.InvalidRerangePolicy.selector, p);
    }

    function test_init_rerangeTriggerAboveOneReverts() public {
        ConcentratedLiquidityStrategy.InitParams memory p = _defaultParams();
        p.rerange.triggerBps = 10_001;
        _expectInitRevert(ConcentratedLiquidityStrategy.InvalidRerangePolicy.selector, p);
    }

    function test_init_rerangeCapAboveLimitReverts() public {
        ConcentratedLiquidityStrategy.InitParams memory p = _defaultParams();
        p.rerange.maxReranges = strategy.MAX_RERANGE_LIMIT() + 1;
        _expectInitRevert(ConcentratedLiquidityStrategy.InvalidRerangePolicy.selector, p);
    }

    function test_init_twapWindowTooShortReverts() public {
        ConcentratedLiquidityStrategy.InitParams memory p = _defaultParams();
        p.twapWindow = strategy.MIN_TWAP_WINDOW() - 1;
        _expectInitRevert(ConcentratedLiquidityStrategy.InvalidBound.selector, p);
    }

    function test_init_deviationBoundAboveCeilingReverts() public {
        ConcentratedLiquidityStrategy.InitParams memory p = _defaultParams();
        p.maxTwapDeviationBps = strategy.MAX_TWAP_DEVIATION_BPS() + 1;
        _expectInitRevert(ConcentratedLiquidityStrategy.InvalidBound.selector, p);
    }
}

contract ConcentratedLiquidityStrategyTwapTest is CLFixture {
    // ── 6.3 TWAP guard ──

    function test_execute_spotOutsideTwapBoundReverts() public {
        // Deviation bound is 100 bps ~ 100 ticks; put spot 150 ticks away.
        pool.setTicks(150, 0);
        vm.prank(address(vaultStub));
        vm.expectRevert(ConcentratedLiquidityStrategy.SpotOutsideTwapBound.selector);
        strategy.execute();
    }

    function test_execute_spotBelowTwapOutsideBoundReverts() public {
        pool.setTicks(-150, 0);
        vm.prank(address(vaultStub));
        vm.expectRevert(ConcentratedLiquidityStrategy.SpotOutsideTwapBound.selector);
        strategy.execute();
    }

    function test_execute_spotAtBoundSucceeds() public {
        pool.setTicks(100, 0);
        _execute();
        assertGt(strategy.tokenId(), 0);
    }

    /// @dev Cardinality 1 means the ring holds only the current observation, so
    ///      `observe` would answer with spot — the guard would compare spot
    ///      against itself and pass unconditionally. Fail closed instead.
    function test_execute_insufficientCardinalityReverts() public {
        pool.setObservationCardinality(1);
        vm.prank(address(vaultStub));
        vm.expectRevert(ConcentratedLiquidityStrategy.TwapUnavailable.selector);
        strategy.execute();
    }

    function test_execute_observeRevertsIsFatal() public {
        pool.setObserveReverts(true);
        vm.prank(address(vaultStub));
        vm.expectRevert(ConcentratedLiquidityStrategy.TwapUnavailable.selector);
        strategy.execute();
    }

    /// @dev A pool that answers the selector but not the contract must not reach
    ///      `abi.decode` unchecked.
    function test_execute_malformedObserveIsFatal() public {
        pool.setObserveShortArray(true);
        vm.prank(address(vaultStub));
        vm.expectRevert(ConcentratedLiquidityStrategy.TwapUnavailable.selector);
        strategy.execute();
    }
}
