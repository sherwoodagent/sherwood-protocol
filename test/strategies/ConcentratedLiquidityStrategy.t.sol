// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockERC4626Wrapper} from "../mocks/MockERC4626Wrapper.sol";
import {MockMorpho, MockIrm} from "../mocks/MockMorpho.sol";
import {MockProposalStatus} from "../mocks/MockProposalStatus.sol";
import {MockPermissiveTierRegistry} from "../mocks/MockPermissiveTierRegistry.sol";
import {MockSwapAdapter} from "../mocks/MockSwapAdapter.sol";
import {MockUniswapV3Pool} from "../mocks/MockUniswapV3Pool.sol";
import {MockUniswapV3Factory} from "../mocks/MockUniswapV3Factory.sol";
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

    /// @dev The pool price matching this fixture's adapter rate, as
    ///      `sqrt(token1_raw / token0_raw) * 2^96`. token0 is USDG (6dp),
    ///      token1 is NVDA (18dp), and 1 USDG buys 0.01 NVDA, so in RAW units
    ///      1e6 USDG buys 1e16 NVDA and the raw ratio is 1e10.
    ///      `sqrt(1e10) = 1e5`, so the value is `1e5 * 2^96`.
    uint160 constant FAIR_SQRT_PRICE_X96 = uint160(1e5) * uint160(2 ** 96);

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
    MockPermissiveTierRegistry tierRegistry;
    VaultStub vaultStub;

    MarketParams mp;
    Id marketId;

    ConcentratedLiquidityStrategy template;
    ConcentratedLiquidityStrategy strategy;

    /// @dev A DEPLOYED factory, not `makeAddr`. The strategy resolves a pool's
    ///      provenance by asking the factory `getPool`, so a codeless stand-in
    ///      answers nothing and every configuration in this file would read as
    ///      un-vouched. Pools this fixture means to be genuine must be
    ///      `register`ed on it.
    MockUniswapV3Factory factoryMock;
    address factory;

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

        factoryMock = new MockUniswapV3Factory();
        factory = address(factoryMock);

        pool = new MockUniswapV3Pool(address(usdg), address(nvda), POOL_FEE, TICK_SPACING, factory);
        pool.setLiquidity(POOL_LIQUIDITY);
        pool.setTicks(0, 0);
        factoryMock.register(address(usdg), address(nvda), POOL_FEE, address(pool));

        posm = new MockPositionManager(factory);
        adapter = new MockSwapAdapter();
        // 1 USDG (6dp) -> 0.01 NVDA (18dp): rate is scaled 1e18 and must absorb
        // the 12-decimal gap between the two tokens.
        adapter.setRate(address(usdg), address(nvda), 1e18 * 1e12 / 100);
        adapter.setRate(address(nvda), address(usdg), 100 * 1e18 / 1e12);
        nvda.mint(address(adapter), 1_000_000e18);
        usdg.mint(address(adapter), 1_000_000e6);

        // Seat a real pool price. `_poolAnchoredMinOut` treats 0 as unreadable
        // and degrades to the quote floor alone, so leaving the mock's default
        // would make the anchored floor inert in every test here rather than
        // fail loudly. FAIR_SQRT_PRICE_X96 encodes exactly the adapter's rate,
        // so the two floors agree and the honest path is unaffected; the
        // manipulation tests move the ADAPTER away from it.
        pool.setSqrtPriceX96(FAIR_SQRT_PRICE_X96);

        status = new MockProposalStatus();
        // `_initialize` binds every proposer-supplied counterparty to the
        // registry reached through `vault() -> governor() -> tierRegistry()`,
        // and fails CLOSED when that walk yields nothing — so the fixture must
        // seat one. Permissive by default; the binding tests deny specific
        // addresses to drive the refusal.
        tierRegistry = new MockPermissiveTierRegistry();
        status.setTierRegistry(address(tierRegistry));
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

/// @notice A `TierRegistry` stand-in whose `isAdapterAllowed` returns a raw
///         word rather than a canonical boolean.
/// @dev    Exists to drive the one input `abi.decode(ret, (bool))` cannot
///         survive. Solidity's bool decoder reverts on any word outside {0, 1},
///         and there is no `try` around the binding probe — so a registry that
///         answers `2` would brick `_initialize` instead of failing closed.
///         Written in assembly because the type system cannot express it.
contract DirtyWordTierRegistry {
    uint256 private _word;

    function setWord(uint256 w) external {
        _word = w;
    }

    fallback() external {
        uint256 w = _word;
        assembly ("memory-safe") {
            mstore(0x00, w)
            return(0x00, 0x20)
        }
    }
}

contract ConcentratedLiquidityStrategyInitTest is CLFixture {
    // ── 6.2 Init validation, one test per check ──

    /// @dev The rogue pool is never registered with the factory, so `getPool`
    ///      for its own key names the genuine pool instead. `setFactory` puts it
    ///      on the strongest footing the old self-attestation check could give
    ///      it — claiming the real factory — which is precisely what that check
    ///      accepted and this one does not.
    function test_init_poolNotFromFactoryReverts() public {
        MockUniswapV3Pool rogue = new MockUniswapV3Pool(address(usdg), address(nvda), POOL_FEE, TICK_SPACING, factory);
        rogue.setFactory(factory);
        ConcentratedLiquidityStrategy.InitParams memory p = _defaultParams();
        p.pool = address(rogue);
        _expectInitRevert(ConcentratedLiquidityStrategy.PoolNotFromFactory.selector, p);
    }

    /// @dev Registered with the factory on purpose. Provenance is checked
    ///      BEFORE the asset check, so an unregistered pool would revert
    ///      `PoolNotFromFactory` and this test would pass without ever reaching
    ///      the mismatch it is named for. The pool under test is genuine; it
    ///      simply quotes the wrong pair.
    function test_init_poolDoesNotQuoteVaultAssetReverts() public {
        ERC20Mock other = new ERC20Mock("OTHER", "OTHER", 18);
        MockUniswapV3Pool bad = new MockUniswapV3Pool(address(other), address(nvda), POOL_FEE, TICK_SPACING, factory);
        factoryMock.register(address(other), address(nvda), POOL_FEE, address(bad));
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

    // ── Pashov 2026-08 finding #16 — a zero slippage floor is a self-brick ──
    //
    // ZERO IS THE STRICTEST VALUE HERE, NOT THE LOOSEST, which is why it reads
    // as a safe default and survives review. `_quoteMinOut` computes
    // `expected * (BPS_DENOMINATOR - slippageBps) / BPS_DENOMINATOR`, so zero
    // puts the floor exactly ON the quote — and the quote is taken BEFORE the
    // swap moves the pool, so no honest fill ever clears it.
    //
    // The consequence is unrecoverable rather than merely annoying:
    // `_updateParams` reaches only `settleSlippageBps` and `settleDeadline` and
    // is a one-way ratchet, so neither of these two can be corrected after
    // init. Every `rerange()` reverts for the clone's whole life — up to
    // `ABSOLUTE_MAX_STRATEGY_DURATION` frozen in the initial band, earning no
    // fees while the Morpho borrow accrues.
    //
    // This file ALREADY rejects `settleSlippageBps == 0` for the same reason,
    // and `PortfolioStrategy` carries `MIN_SLIPPAGE_BPS = 50` with the note
    // that it "turns a permanent self-brick into a rejected input". These two
    // fields were the ones left out.

    function test_init_rerangeSlippageZeroReverts() public {
        ConcentratedLiquidityStrategy.InitParams memory p = _defaultParams();
        p.rerange.slippageBps = 0;
        _expectInitRevert(ConcentratedLiquidityStrategy.InvalidRerangePolicy.selector, p);
    }

    /// @dev The mint side of the same shape, and ALSO finding #9's guaranteed
    ///      trigger: `_mintPosition` derives `amountXMin` from the amounts
    ///      OFFERED, so zero slippage demands the pool consume every wei of both
    ///      legs — which a two-sided mint never does. Rejecting zero closes that
    ///      trigger outright. Finding #9's other half (spot drifting outside the
    ///      band, leaving one leg untouched at any non-zero setting) needs the
    ///      floors derived from the range-implied amounts and is NOT fixed here.
    function test_init_mintSlippageZeroReverts() public {
        ConcentratedLiquidityStrategy.InitParams memory p = _defaultParams();
        p.mintSlippageBps = 0;
        _expectInitRevert(ConcentratedLiquidityStrategy.InvalidBound.selector, p);
    }

    /// @dev NOT A BLANKET REJECTION. The bar is "non-zero", the same bar
    ///      `settleSlippageBps` clears — one basis point is admissible. Without
    ///      this the two tests above would also hold for a guard that refused
    ///      every value, which would brick the template far harder than the
    ///      finding does.
    function test_init_oneBasisPointSlippageIsAccepted() public {
        ConcentratedLiquidityStrategy.InitParams memory p = _defaultParams();
        p.mintSlippageBps = 1;
        p.rerange.slippageBps = 1;

        ConcentratedLiquidityStrategy s = _newStrategy(p);

        assertEq(uint256(s.state()), uint256(BaseStrategy.State.Pending));
        assertEq(s.mintSlippageBps(), 1, "the mint floor was not stored as given");
        assertEq(s.rerangePolicy().slippageBps, 1, "the rerange floor was not stored as given");
    }

    function test_init_twapWindowTooShortReverts() public {
        ConcentratedLiquidityStrategy.InitParams memory p = _defaultParams();
        p.twapWindow = strategy.MIN_TWAP_WINDOW() - 1;
        _expectInitRevert(ConcentratedLiquidityStrategy.InvalidBound.selector, p);
    }

    /// @notice PASHOV 2026-08 FINDING #17, structural half — a rerange band
    ///         narrower than the approved one is refused at BIND time.
    /// @dev    `_execute` enforces `MAX_POOL_SHARE_BPS` on the liquidity it
    ///         actually mints; `rerange` re-mints through the same
    ///         `_mintPosition` and cannot re-check it without a permanent brick
    ///         (see the block in `rerange`). So the cap is preserved here
    ///         instead.
    ///
    ///         The finding's own worked case: a wide initial range plus
    ///         `halfWidthTicks == tickSpacing` cleared every init and execute
    ///         check and then concentrated the same notional into ONE spacing,
    ///         far above the cap, on a permissionless call. For fixed token
    ///         amounts liquidity scales inversely with band width, so requiring
    ///         the rerange band to be at least as wide as the initial one
    ///         bounds the re-mint by a figure that already cleared the cap.
    function test_init_rerangeBandNarrowerThanApprovedRangeReverts() public {
        ConcentratedLiquidityStrategy.InitParams memory p = _defaultParams();
        // The exact shape from the finding: initial range is +/-1000, the
        // rerange policy would re-mint into a single tick spacing.
        p.rerange.halfWidthTicks = TICK_SPACING;
        _expectInitRevert(ConcentratedLiquidityStrategy.InvalidRerangePolicy.selector, p);
    }

    /// @dev The boundary is inclusive: a band exactly as wide as the approved
    ///      range mints at most what the initial mint did, so it is admissible.
    function test_init_rerangeBandEqualToApprovedRangeSucceeds() public {
        ConcentratedLiquidityStrategy.InitParams memory p = _defaultParams();
        p.rerange.halfWidthTicks = (TICK_UPPER - TICK_LOWER) / 2;
        ConcentratedLiquidityStrategy s = _newStrategy(p);
        assertEq(uint256(s.state()), uint256(BaseStrategy.State.Pending));
        assertEq(s.rerangePolicy().halfWidthTicks, (TICK_UPPER - TICK_LOWER) / 2, "the band was accepted as given");
    }

    function test_init_deviationBoundAboveCeilingReverts() public {
        ConcentratedLiquidityStrategy.InitParams memory p = _defaultParams();
        p.maxTwapDeviationBps = strategy.MAX_TWAP_DEVIATION_BPS() + 1;
        _expectInitRevert(ConcentratedLiquidityStrategy.InvalidBound.selector, p);
    }

    // ── Pashov 2026-08 finding #3 — governance binding of counterparties ──
    //
    // Every init-time check in this template resolves THROUGH an address the
    // proposer chose: `getPool` asks a factory which pool it created,
    // `market(id).lastUpdate` asks a Morpho whether a market exists,
    // `_isWrapperOf` asks a token what it wraps. Unless the address answering
    // is bound first, every one of them is self-consistent by construction —
    // which is what finding #4 turned out to be for the pool, and why
    // `uniswapFactory` is on this list too.
    //
    // The vault's batch guard does not cover it either: `_guardBatchCalls`
    // PART 2a checks the CLONE is an allowlisted callee, while the approvals
    // that move money are issued INSIDE this contract — `forceApprove` to the
    // collateral token in `_postCollateral` and to the swap adapter in
    // `_rebalanceToTarget` — one hop past anything the batch names.
    //
    // `PortfolioStrategy` binds its adapter and price sources for exactly this
    // reason. These pin that this template now does the same, for all four.

    /// @dev Each counterparty individually, so a fix that binds three of four
    ///      cannot pass.
    function test_init_deniedSwapAdapterReverts() public {
        tierRegistry.setDenied(address(adapter), true);
        _expectInitRevertWithArgs(address(adapter));
    }

    function test_init_deniedPositionManagerReverts() public {
        tierRegistry.setDenied(address(posm), true);
        _expectInitRevertWithArgs(address(posm));
    }

    function test_init_deniedMorphoReverts() public {
        tierRegistry.setDenied(address(morpho), true);
        _expectInitRevertWithArgs(address(morpho));
    }

    function test_init_deniedCollateralTokenReverts() public {
        tierRegistry.setDenied(mp.collateralToken, true);
        _expectInitRevertWithArgs(mp.collateralToken);
    }

    /// @dev The binding must run BEFORE the counterparty-derived checks, or a
    ///      hostile `morpho` gets to answer `market()` first and the refusal
    ///      surfaces as whatever THAT contract chose to revert with. Denying a
    ///      counterparty while also handing over params that would fail a later
    ///      check pins the ordering: the binding error is what comes out.
    function test_init_bindingRunsBeforeCounterpartyDerivedChecks() public {
        tierRegistry.setDenied(address(morpho), true);
        ConcentratedLiquidityStrategy.InitParams memory p = _defaultParams();
        // Would trip `BorrowExceedsLiquidity` if the binding did not fire first.
        p.borrowAmount = MARKET_SUPPLY * 100;

        ConcentratedLiquidityStrategy s = ConcentratedLiquidityStrategy(Clones.clone(address(template)));
        bytes memory data = abi.encode(p);
        address v = address(vaultStub);
        vm.expectRevert(
            abi.encodeWithSelector(
                ConcentratedLiquidityStrategy.CounterpartyNotAllowed.selector, address(morpho), address(tierRegistry)
            )
        );
        s.initialize(v, proposer, data);
    }

    /// @dev No registry resolvable → fail CLOSED, matching
    ///      `PortfolioStrategy._initialize`. Binding time is the cheap place to
    ///      refuse: it costs a re-proposal, where discovering it at execute
    ///      costs the deployed capital.
    function test_init_unresolvableTierRegistryReverts() public {
        status.setTierRegistry(address(0));
        _expectInitRevert(ConcentratedLiquidityStrategy.TierRegistryUnresolved.selector, _defaultParams());
    }

    /// @dev THE POINT OF THE TWO AXES. The position manager and Morpho bind on
    ///      `isCounterpartyAllowed`, not `isAdapterAllowed` — so an owner can
    ///      run this template WITHOUT admitting either to the allowlist that
    ///      governs batch callees, approve spenders and transfer recipients.
    ///
    ///      That is not a preference. `TierRegistry.setAdapterAllowed`'s own
    ///      contract says exotic-asset contracts, naming LP-position NFTs, MUST
    ///      NOT be listed on that axis, and a Uniswap position manager is one.
    ///      Binding it there would have made operating the template require the
    ///      exact entry the registry tells the owner not to make.
    ///
    ///      Denies both on the ADAPTER axis only, so the test fails if either
    ///      one is ever moved back onto the strong grant.
    function test_init_counterpartiesDoNotNeedAdapterStanding() public {
        tierRegistry.setDeniedAsAdapter(address(posm), true);
        tierRegistry.setDeniedAsAdapter(address(morpho), true);
        tierRegistry.setDeniedAsAdapter(mp.collateralToken, true);

        ConcentratedLiquidityStrategy s = _newStrategy(_defaultParams());
        assertEq(address(s.positionManager()), address(posm));
    }

    /// @dev The converse, so the split does not quietly weaken the swap adapter.
    ///      It is the one address here that receives `forceApprove` of the
    ///      strategy's balances, so the WEAK grant must not be enough for it.
    function test_init_swapAdapterStillNeedsAdapterStanding() public {
        tierRegistry.setDeniedAsAdapter(address(adapter), true);
        _expectInitRevertWithArgs(address(adapter));
    }

    /// @dev The vault asset is EXEMPT from the binding, mirroring
    ///      `SyndicateVault._guardBatchCalls`' own `target != asset_` carve-out.
    ///      `collateralToken == vaultAsset` is an explicitly supported market
    ///      (see `test_init_vaultAssetAsCollateralSucceeds`), and the vault's
    ///      guard treats its own asset as needing no allowlist entry — so
    ///      demanding one here would refuse a legitimate market on a registry
    ///      configured exactly right.
    ///
    ///      DENIES `usdg` EXPLICITLY, which is the whole point: the permissive
    ///      mock answers yes to everything it was not told about, so a test
    ///      that merely used the asset as collateral would pass either way and
    ///      prove nothing. Same inert-fixture failure this PR fixed for
    ///      `slot0()`.
    function test_init_vaultAssetAsCollateralIsExemptFromTheBinding() public {
        MarketParams memory direct = mp;
        direct.collateralToken = address(usdg);
        morpho.createMarket(direct);
        _fundMarket(direct);

        tierRegistry.setDenied(address(usdg), true);

        ConcentratedLiquidityStrategy.InitParams memory p = _defaultParams();
        p.marketParams = direct;
        ConcentratedLiquidityStrategy s = _newStrategy(p);
        assertEq(s.marketParams().collateralToken, address(usdg));
    }

    /// @dev A registry answering with a word that is neither 0 nor 1 must fail
    ///      CLOSED, not undecodably. `abi.decode(ret, (bool))` REVERTS on such a
    ///      word, in this frame, with nothing to catch it — which would turn the
    ///      documented "unreadable means not vouched for" into a bricked
    ///      `_initialize`, the exact failure the raw-staticcall form exists to
    ///      avoid. Non-zero reads as true, matching the EVM's own convention.
    function test_init_registryReturningNonBooleanWordDoesNotBrickInit() public {
        DirtyWordTierRegistry dirty = new DirtyWordTierRegistry();
        status.setTierRegistry(address(dirty));

        // 2 is "true" by the EVM's convention, so the binding passes rather than
        // reverting on the decode.
        dirty.setWord(2);
        ConcentratedLiquidityStrategy s = _newStrategy(_defaultParams());
        assertEq(s.marketParams().collateralToken, mp.collateralToken);

        // 0 is still a refusal, and it surfaces as the typed error.
        dirty.setWord(0);
        ConcentratedLiquidityStrategy s2 = ConcentratedLiquidityStrategy(Clones.clone(address(template)));
        bytes memory data = abi.encode(_defaultParams());
        address v = address(vaultStub);
        vm.expectRevert(
            abi.encodeWithSelector(
                ConcentratedLiquidityStrategy.CounterpartyNotAllowed.selector, address(adapter), address(dirty)
            )
        );
        s2.initialize(v, proposer, data);
    }

    function _expectInitRevertWithArgs(address counterparty) internal {
        ConcentratedLiquidityStrategy s = ConcentratedLiquidityStrategy(Clones.clone(address(template)));
        bytes memory data = abi.encode(_defaultParams());
        address v = address(vaultStub);
        vm.expectRevert(
            abi.encodeWithSelector(
                ConcentratedLiquidityStrategy.CounterpartyNotAllowed.selector, counterparty, address(tierRegistry)
            )
        );
        s.initialize(v, proposer, data);
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

/// @notice Pashov 2026-08 finding #4 — swap floors must not be derived from the
///         venue being swapped against.
/// @dev    Every swap floor in this template came from
///         `swapAdapter.quote(..., swapExtraData)` taken in the SAME transaction,
///         through the SAME route, as the swap it bounded. `PortfolioStrategy`
///         states the property outright for its own `_quoteMinOut` ("NOT
///         SANDWICH PROTECTION ... a searcher who moves the pool before the call
///         gets a quote at the moved price and a floor derived from it, and the
///         swap clears") and answers it with oracle-anchored floors. This
///         template had no oracle and no equivalent.
///
///         `_requireSpotNearTwap` did not cover it: it reads `pool.slot0()` —
///         the LP venue — while `swapExtraData` is stored verbatim at
///         `_initialize` and may route a different fee tier, a V4 pool, or a
///         multi-hop path. So the guarded venue and the swapped venue were not
///         the same venue.
///
///         These drive exactly that split: the POOL keeps quoting the fair
///         price while the ROUTED ADAPTER is moved against the strategy.
contract ConcentratedLiquidityStrategyPoolAnchoredFloorTest is CLFixture {
    /// @dev Sanity that the anchored floor is not simply blocking everything:
    ///      with the adapter and the pool agreeing, the honest path is
    ///      unaffected. Without this a floor stuck at "reject" would look like
    ///      a working fix.
    function test_execute_fairVenueStillSucceeds() public {
        _execute();
        assertEq(uint256(strategy.state()), uint256(BaseStrategy.State.Executed));
    }

    /// @dev THE fix. The routed venue pays half what the configured pool says.
    ///      Pre-fix `minOut` came from that same halved venue and the swap
    ///      cleared; post-fix the pool-anchored floor rejects it.
    function test_execute_routedVenueMovedAgainstPool_isRejected() public {
        adapter.setRate(address(usdg), address(nvda), (1e18 * 1e12 / 100) / 2);
        vm.prank(address(vaultStub));
        vm.expectRevert(MockSwapAdapter.SlippageExceeded.selector);
        strategy.execute();
    }

    /// @dev SELF-PROVING COUNTERPART to the test above, and the reason it is not
    ///      vacuous. Same halved routed venue, but with the pool price
    ///      unreadable the floor degrades to the quote alone — the pre-fix
    ///      construction — and the identical skim CLEARS.
    ///
    ///      Two things are pinned at once: the manipulation test is actually
    ///      exercising the new floor rather than some unrelated guard, and the
    ///      degradation path is a real, deliberate residual (an unreadable pool
    ///      price buys back the old exposure) rather than an accident.
    function test_execute_quoteFloorAloneAdmitsTheSkim_provingTheAnchorIsLoadBearing() public {
        pool.setSqrtPriceX96(0);
        adapter.setRate(address(usdg), address(nvda), (1e18 * 1e12 / 100) / 2);
        _execute();
        assertEq(
            uint256(strategy.state()),
            uint256(BaseStrategy.State.Executed),
            "without the pool anchor the halved venue clears -- this is the pre-fix behaviour"
        );
    }

    /// @dev The pool read degrades rather than bricks: an unreadable price
    ///      (`sqrtPriceX96 == 0`) must fall back to the quote floor alone, which
    ///      is the pre-existing behaviour, not a new revert. Pins that the
    ///      degradation path is deliberate — and, read against the test above,
    ///      pins that a zero price is what made this floor inert.
    function test_execute_unreadablePoolPriceDegradesToQuoteFloor() public {
        pool.setSqrtPriceX96(0);
        _execute();
        assertEq(uint256(strategy.state()), uint256(BaseStrategy.State.Executed));
    }

    /// @dev The anchor is the pool's MID price, while `_quoteMinOut`'s operand
    ///      is an adapter quote that already has the venue's fee taken out of
    ///      it. Applying the same `slippageBps` to both would quietly redefine
    ///      that budget as "fee first, slippage with whatever is left", so a
    ///      fee tier wider than the configured slippage would revert every
    ///      `_rebalanceToTarget` — at execute, after the vote.
    ///
    ///      Discriminating by construction: a 1% pool against a 50 bps slippage
    ///      budget, with the venue filling at exactly mid-less-fee. Without the
    ///      haircut the anchor sits at `mid * 0.995`, above the honest `mid *
    ///      0.99` fill, and this reverts.
    function test_execute_poolFeeIsNettedOutOfTheAnchor() public {
        MockUniswapV3Pool widePool = new MockUniswapV3Pool(address(usdg), address(nvda), 10_000, TICK_SPACING, factory);
        factoryMock.register(address(usdg), address(nvda), 10_000, address(widePool));
        widePool.setLiquidity(POOL_LIQUIDITY);
        widePool.setTicks(0, 0);
        widePool.setSqrtPriceX96(FAIR_SQRT_PRICE_X96);

        // The honest fill for a 1% venue: mid less the fee, nothing else.
        adapter.setRate(address(usdg), address(nvda), (1e18 * 1e12 / 100) * 99 / 100);

        ConcentratedLiquidityStrategy.InitParams memory p = _defaultParams();
        p.pool = address(widePool);
        p.mintSlippageBps = 50;
        ConcentratedLiquidityStrategy s = _newStrategy(p);
        status.set(1, 1, address(s));
        vm.prank(address(vaultStub));
        usdg.approve(address(s), type(uint256).max);

        vm.prank(address(vaultStub));
        s.execute();
        assertEq(uint256(s.state()), uint256(BaseStrategy.State.Executed), "the fee haircut must not be double-counted");
    }

    // ── The exit leg: the anchor must not become a settlement veto ──

    /// @dev THE REGRESSION THE GATE MUST NOT BREAK. Pool honest, routed venue
    ///      short: the anchor holds and the skim is refused, leaving the residue
    ///      for `sweep()`. If gating the anchor on `_spotNearTwap()` had
    ///      disabled it on this path, this converts and the finding is back.
    function test_settle_shortRoutedVenueIsRefusedWhileSpotIsTwapVerified() public {
        _execute();
        // Half of what the pool says the token is worth.
        adapter.setRate(address(nvda), address(usdg), (100 * 1e18 / 1e12) / 2);
        _settle();
        assertGt(
            nvda.balanceOf(address(strategy)), 0, "the halved venue must not clear while the pool price is verified"
        );
    }

    /// @dev THE FIX, and the correction to its first attempt. `_settle`/`sweep`
    ///      assert nothing about spot — unlike `_execute`/`rerange`, which
    ///      revert `SpotOutsideTwapBound` first — so the anchor's safety is not
    ///      inherited here and a pushed pool has to be handled explicitly.
    ///
    ///      SKIPPING THE ANCHOR IS THE WRONG HANDLING, which is what this pins.
    ///      With the anchor off, `minOut` falls back to the routed venue quoting
    ///      itself, so the same actor who pushed the pool also moves the venue
    ///      and the original finding clears — measured at a full conversion of
    ///      the position through a venue paying half the pool price. Skipping
    ///      the SWAP instead costs delay rather than principal.
    function test_settle_pushedPoolMustNotHandTheSkimBack() public {
        _execute();
        pool.setTicks(23_000, 0);
        adapter.setRate(address(nvda), address(usdg), (100 * 1e18 / 1e12) / 2);
        _settle();
        assertGt(
            nvda.balanceOf(address(strategy)),
            0,
            "an unverified pool must skip the swap, not swap on the venue's own quote"
        );
    }

    /// @dev And the delay is only that. The residue a pushed pool leaves is
    ///      recoverable by the permissionless `sweep()` at any later honest
    ///      moment, with no owner involvement — which is what makes trading the
    ///      skim for a skipped swap the right way round. Holding spot outside
    ///      the bound costs the attacker every block while the TWAP walks toward
    ///      spot, so the deviation they are paying for closes underneath them.
    function test_settle_pushedPoolResidueIsRecoveredBySweep() public {
        _execute();
        pool.setSqrtPriceX96(FAIR_SQRT_PRICE_X96 / 3);
        pool.setTicks(23_000, 0);

        _settle();
        assertGt(nvda.balanceOf(address(strategy)), 0, "precondition: the pushed pool left a residue");

        // The pool returns to itself; anyone may retry.
        pool.setSqrtPriceX96(FAIR_SQRT_PRICE_X96);
        pool.setTicks(0, 0);
        vm.prank(address(vaultStub));
        strategy.sweep();

        assertEq(nvda.balanceOf(address(strategy)), 0, "sweep must recover the residue once the pool is honest");
    }
}
