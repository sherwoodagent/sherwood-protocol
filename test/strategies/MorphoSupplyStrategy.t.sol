// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {LaneAFixture} from "../helpers/LaneAFixture.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockMorpho, MockIrm} from "../mocks/MockMorpho.sol";
import {MorphoSupplyStrategy} from "../../src/strategies/MorphoSupplyStrategy.sol";
import {MorphoSupplyAdapter} from "../../src/pricing/MorphoSupplyAdapter.sol";
import {BaseStrategy} from "../../src/strategies/BaseStrategy.sol";
import {Position} from "../../src/interfaces/IPriceRouter.sol";
import {PositionKinds} from "../../src/libraries/PositionKinds.sol";
import {Id, MarketParams, Market} from "../../src/vendor/morpho/IMorpho.sol";
import {SharesMathLib} from "../../src/vendor/morpho/MorphoLibs.sol";

/// @notice Minimal vault stand-in: the only vault surface the strategy and
///         adapter consume is `asset()`; lifecycle calls are pranked as this
///         address.
contract VaultStub {
    address internal immutable _assetToken;

    constructor(address assetToken_) {
        _assetToken = assetToken_;
    }

    function asset() external view returns (address) {
        return _assetToken;
    }
}

/// @notice Shared fixture: 6-decimal USDG-like loan token, a functional
///         MockMorpho market with a settable-rate IRM, a VaultStub funded
///         with the supply amount, and an initialized strategy clone.
abstract contract MorphoSupplyFixture is LaneAFixture {
    uint256 constant SUPPLY = 100_000e6;
    // ~5% APR as a per-second WAD rate.
    uint256 constant RATE_PER_SECOND = uint256(0.05e18) / 365 days;

    ERC20Mock usdg;
    MockIrm irm;
    MockMorpho mockMorpho;
    MarketParams mp;
    Id marketId;
    VaultStub vaultStub;
    MorphoSupplyStrategy template;
    MorphoSupplyStrategy strategy;

    address proposer = makeAddr("proposer");
    address borrower = makeAddr("borrower");

    function setUp() public virtual {
        usdg = new ERC20Mock("USDG", "USDG", 6);
        irm = new MockIrm();
        irm.setRate(RATE_PER_SECOND);
        mockMorpho = new MockMorpho();

        mp = MarketParams({
            loanToken: address(usdg),
            collateralToken: makeAddr("collateral"),
            oracle: makeAddr("oracle"),
            irm: address(irm),
            lltv: 0.86e18
        });
        marketId = mockMorpho.createMarket(mp);

        vaultStub = new VaultStub(address(usdg));
        usdg.mint(address(vaultStub), SUPPLY);

        template = new MorphoSupplyStrategy();
        strategy = _newStrategy(mp, SUPPLY);
    }

    function _newStrategy(MarketParams memory mpArg, uint256 amount) internal returns (MorphoSupplyStrategy s) {
        s = MorphoSupplyStrategy(Clones.clone(address(template)));
        s.initialize(address(vaultStub), proposer, abi.encode(address(mockMorpho), mpArg, amount));
    }

    function _approveAndExecute() internal {
        address strat = address(strategy);
        vm.prank(address(vaultStub));
        usdg.approve(strat, SUPPLY);
        vm.prank(address(vaultStub));
        strategy.execute();
    }

    /// @dev Borrow, warp, then repay everything (with interest) so the mock is
    ///      fully token-backed again. Leaves accrued interest in the supply side.
    function _borrowWarpRepay(uint256 borrowAmount, uint256 duration) internal {
        mockMorpho.simulateBorrow(mp, borrowAmount, borrower);
        vm.warp(vm.getBlockTimestamp() + duration);
        usdg.mint(borrower, borrowAmount); // headroom for interest
        vm.startPrank(borrower);
        usdg.approve(address(mockMorpho), type(uint256).max);
        mockMorpho.simulateRepayAll(mp);
        vm.stopPrank();
    }
}

// ═══════════════════════════════════════════════════════════════════════
// Strategy: init validation, lifecycle, Lane A surface
// ═══════════════════════════════════════════════════════════════════════

contract MorphoSupplyStrategyTest is MorphoSupplyFixture {
    function test_init_storesMarketAndAmount() public view {
        assertEq(Id.unwrap(strategy.marketId()), keccak256(abi.encode(mp)), "marketId = keccak(params)");
        assertEq(strategy.asset(), address(usdg), "asset = vault asset");
        assertEq(strategy.supplyAmount(), SUPPLY, "supplyAmount stored");
        assertEq(address(strategy.morpho()), address(mockMorpho), "morpho stored");
        MarketParams memory stored = strategy.marketParams();
        assertEq(stored.loanToken, mp.loanToken, "loanToken stored");
        assertEq(stored.irm, mp.irm, "irm stored");
    }

    function test_init_revertsOnLoanAssetMismatch() public {
        ERC20Mock other = new ERC20Mock("OTHER", "OTHER", 18);
        MarketParams memory bad = mp;
        bad.loanToken = address(other);
        MorphoSupplyStrategy s = MorphoSupplyStrategy(Clones.clone(address(template)));
        bytes memory initData = abi.encode(address(mockMorpho), bad, SUPPLY);
        vm.expectRevert(MorphoSupplyStrategy.LoanAssetMismatch.selector);
        s.initialize(address(vaultStub), proposer, initData);
    }

    function test_init_revertsOnUncreatedMarket() public {
        MarketParams memory ghost = mp;
        ghost.lltv = 0.5e18; // different id, never created
        MorphoSupplyStrategy s = MorphoSupplyStrategy(Clones.clone(address(template)));
        bytes memory initData = abi.encode(address(mockMorpho), ghost, SUPPLY);
        vm.expectRevert(MorphoSupplyStrategy.MarketNotCreated.selector);
        s.initialize(address(vaultStub), proposer, initData);
    }

    function test_init_revertsOnZeroAmount() public {
        MorphoSupplyStrategy s = MorphoSupplyStrategy(Clones.clone(address(template)));
        bytes memory initData = abi.encode(address(mockMorpho), mp, uint256(0));
        vm.expectRevert(MorphoSupplyStrategy.InvalidAmount.selector);
        s.initialize(address(vaultStub), proposer, initData);
    }

    function test_init_revertsOnZeroMorpho() public {
        MorphoSupplyStrategy s = MorphoSupplyStrategy(Clones.clone(address(template)));
        bytes memory initData = abi.encode(address(0), mp, SUPPLY);
        vm.expectRevert(BaseStrategy.ZeroAddress.selector);
        s.initialize(address(vaultStub), proposer, initData);
    }

    function test_execute_suppliesToMarket() public {
        _approveAndExecute();
        assertGt(mockMorpho.position(marketId, address(strategy)).supplyShares, 0, "supply shares minted");
        assertEq(usdg.balanceOf(address(mockMorpho)), SUPPLY, "tokens moved into morpho");
        assertEq(usdg.balanceOf(address(strategy)), 0, "nothing stranded on strategy");
        assertEq(usdg.balanceOf(address(vaultStub)), 0, "vault fully deployed");
        Market memory m = mockMorpho.market(marketId);
        assertEq(uint256(m.totalSupplyAssets), SUPPLY, "market supply total");
    }

    function test_execute_onlyVault() public {
        vm.expectRevert(BaseStrategy.NotVault.selector);
        strategy.execute();
    }

    function test_settle_fullUnwind_noInterest() public {
        _approveAndExecute();
        vm.prank(address(vaultStub));
        strategy.settle();
        assertEq(usdg.balanceOf(address(vaultStub)), SUPPLY, "principal returned exactly");
        assertEq(mockMorpho.position(marketId, address(strategy)).supplyShares, 0, "position closed");
        assertEq(usdg.balanceOf(address(strategy)), 0, "no residue on strategy");
    }

    function test_settle_fullUnwind_includesAccruedInterest() public {
        _approveAndExecute();
        _borrowWarpRepay(60_000e6, 30 days);

        vm.prank(address(vaultStub));
        strategy.settle();

        // Sole supplier: the whole accrued interest lands on the vault.
        assertGt(usdg.balanceOf(address(vaultStub)), SUPPLY, "interest included in unwind");
        assertEq(mockMorpho.position(marketId, address(strategy)).supplyShares, 0, "position closed");
        assertEq(usdg.balanceOf(address(strategy)), 0, "no residue on strategy");
    }

    function test_updateParams_reverts() public {
        _approveAndExecute();
        vm.prank(proposer);
        vm.expectRevert(MorphoSupplyStrategy.NoTunableParams.selector);
        strategy.updateParams("");
    }

    // ── positions() enumeration ──

    function test_positions_emptyBeforeExecute() public view {
        assertEq(strategy.positions().length, 0, "no position pre-execute");
        assertEq(template.positions().length, 0, "uninitialized template is empty");
    }

    function test_positions_onePositionWhileSupplied() public {
        _approveAndExecute();
        Position[] memory ps = strategy.positions();
        assertEq(ps.length, 1, "exactly one position");
        assertEq(ps[0].venue, address(mockMorpho), "venue = morpho singleton");
        assertEq(ps[0].kind, PositionKinds.MORPHO_BLUE_SUPPLY, "kind = MORPHO_BLUE_SUPPLY");
        assertEq(ps[0].ref, abi.encode(Id.unwrap(marketId)), "ref = abi.encode(marketId)");
    }

    function test_positions_emptyAfterSettle() public {
        _approveAndExecute();
        vm.prank(address(vaultStub));
        strategy.settle();
        assertEq(strategy.positions().length, 0, "empty after full unwind");
    }

    // ── availableLiquidity() ──

    function test_availableLiquidity_zeroBeforeExecute() public view {
        assertEq(strategy.availableLiquidity(), 0, "pending strategy advertises nothing");
    }

    function test_availableLiquidity_unborrowedEqualsSupply() public {
        _approveAndExecute();
        assertEq(strategy.availableLiquidity(), SUPPLY, "sole supplier, zero utilization");
    }

    function test_availableLiquidity_utilizationCaps() public {
        _approveAndExecute();
        mockMorpho.simulateBorrow(mp, 80_000e6, borrower);
        // Own value (100k) > unborrowed (20k) → report the market's liquidity.
        assertEq(strategy.availableLiquidity(), 20_000e6, "capped at unborrowed liquidity");
    }

    function test_availableLiquidity_idleBalanceCaps() public {
        _approveAndExecute();
        // Accounting says 100k liquid, but force the singleton's actual token
        // balance lower — the conservative min must win.
        deal(address(usdg), address(mockMorpho), 30_000e6);
        assertEq(strategy.availableLiquidity(), 30_000e6, "capped at real token balance");
    }

    function test_availableLiquidity_zeroAfterSettle() public {
        _approveAndExecute();
        vm.prank(address(vaultStub));
        strategy.settle();
        assertEq(strategy.availableLiquidity(), 0, "settled strategy advertises nothing");
    }

    // ── withdrawTo() ──

    function test_withdrawTo_deliversExactAssets() public {
        _approveAndExecute();
        uint256 balBefore = usdg.balanceOf(address(vaultStub));
        vm.prank(address(vaultStub));
        strategy.withdrawTo(40_000e6);
        assertEq(usdg.balanceOf(address(vaultStub)) - balBefore, 40_000e6, "exact delivery to vault");
        assertApproxEqAbs(strategy.availableLiquidity(), 60_000e6, 1, "remainder still supplied");
        assertEq(usdg.balanceOf(address(strategy)), 0, "nothing routed through strategy");
    }

    function test_withdrawTo_onlyVault() public {
        _approveAndExecute();
        vm.prank(proposer);
        vm.expectRevert(BaseStrategy.NotVault.selector);
        strategy.withdrawTo(1e6);
    }

    function test_withdrawTo_revertsBeforeExecute() public {
        vm.prank(address(vaultStub));
        vm.expectRevert(BaseStrategy.NotExecuted.selector);
        strategy.withdrawTo(1e6);
    }

    function test_withdrawTo_revertsOnZero() public {
        _approveAndExecute();
        vm.prank(address(vaultStub));
        vm.expectRevert(MorphoSupplyStrategy.InvalidAmount.selector);
        strategy.withdrawTo(0);
    }

    function test_withdrawTo_revertsBeyondMarketLiquidity() public {
        _approveAndExecute();
        mockMorpho.simulateBorrow(mp, 80_000e6, borrower);
        // 30k requested > 20k unborrowed → the venue cannot deliver → revert,
        // never partial delivery.
        vm.prank(address(vaultStub));
        vm.expectRevert("MockMorpho: insufficient liquidity");
        strategy.withdrawTo(30_000e6);
    }
}

// ═══════════════════════════════════════════════════════════════════════
// Adapter: valuation + fail-closed matrix (router involved via LaneAFixture)
// ═══════════════════════════════════════════════════════════════════════

contract MorphoSupplyAdapterTest is MorphoSupplyFixture {
    using SharesMathLib for uint256;

    MorphoSupplyAdapter adapter;

    function setUp() public override {
        super.setUp();
        adapter = new MorphoSupplyAdapter(address(mockMorpho));
        _deployRouter();
        _registerKind(PositionKinds.MORPHO_BLUE_SUPPLY, address(adapter), true);
    }

    function _livePosition() internal view returns (Position memory) {
        return Position({
            venue: address(mockMorpho), kind: PositionKinds.MORPHO_BLUE_SUPPLY, ref: abi.encode(Id.unwrap(marketId))
        });
    }

    function test_constructor_revertsOnZeroMorpho() public {
        vm.expectRevert(MorphoSupplyAdapter.ZeroAddress.selector);
        new MorphoSupplyAdapter(address(0));
    }

    function test_value_freshSupply_equalsPrincipal() public {
        _approveAndExecute();
        (uint256 v, bool ok) = adapter.value(_livePosition(), address(strategy));
        assertTrue(ok, "priceable");
        assertEq(v, SUPPLY, "no interest yet -> principal");
    }

    /// @dev The core view-accrual property: the adapter's view valuation must
    ///      equal what the singleton's own storage-side accrual produces —
    ///      i.e. the assets a same-block withdraw would deliver.
    function test_value_withPendingInterest_matchesAccruedState() public {
        _approveAndExecute();
        mockMorpho.simulateBorrow(mp, 60_000e6, borrower);
        vm.warp(vm.getBlockTimestamp() + 30 days);

        (uint256 viewValue, bool ok) = adapter.value(_livePosition(), address(strategy));
        assertTrue(ok, "priceable with pending interest");
        assertGt(viewValue, SUPPLY, "interest accrued view-side");

        // Accrue for real, then recompute from storage.
        mockMorpho.accrueInterest(mp);
        Market memory m = mockMorpho.market(marketId);
        uint256 shares = mockMorpho.position(marketId, address(strategy)).supplyShares;
        uint256 stateValue = shares.toAssetsDown(m.totalSupplyAssets, m.totalSupplyShares);
        assertEq(viewValue, stateValue, "view accrual == storage accrual");
    }

    function test_value_withFee_matchesAccruedState() public {
        mockMorpho.setFee(marketId, 0.1e18); // 10% of interest to fee shares
        _approveAndExecute();
        mockMorpho.simulateBorrow(mp, 60_000e6, borrower);
        vm.warp(vm.getBlockTimestamp() + 30 days);

        (uint256 viewValue, bool ok) = adapter.value(_livePosition(), address(strategy));
        assertTrue(ok, "priceable with fee");

        mockMorpho.accrueInterest(mp);
        Market memory m = mockMorpho.market(marketId);
        uint256 shares = mockMorpho.position(marketId, address(strategy)).supplyShares;
        uint256 stateValue = shares.toAssetsDown(m.totalSupplyAssets, m.totalSupplyShares);
        assertEq(viewValue, stateValue, "fee-share dilution reproduced view-side");
    }

    function test_value_zeroShares_okAtZero() public view {
        // Initialized but never executed: a real strategy holder with no
        // shares prices honestly to 0 (the router maps total==0 to Lane B).
        (uint256 v, bool ok) = adapter.value(_livePosition(), address(strategy));
        assertTrue(ok, "no-position holder is still priceable");
        assertEq(v, 0, "zero shares -> zero value");
    }

    function test_router_valueStrategy_instantOK() public {
        _approveAndExecute();
        (uint256 v, bool ok) = router.valueStrategy(address(strategy));
        assertTrue(ok, "lane A open end-to-end");
        assertEq(v, SUPPLY, "router reports supply value");
    }

    function test_router_valueStrategy_laneBAfterSettle() public {
        _approveAndExecute();
        vm.prank(address(vaultStub));
        strategy.settle();
        (uint256 v, bool ok) = router.valueStrategy(address(strategy));
        assertFalse(ok, "no positions -> lane B");
        assertEq(v, 0, "no value reported");
    }

    // ── Fail-closed matrix ──

    function test_value_failsClosed_wrongVenue() public {
        _approveAndExecute();
        // Spoofed-venue adversary: same kind/ref, lookalike venue address.
        Position memory p = _livePosition();
        p.venue = makeAddr("fakeMorpho");
        (uint256 v, bool ok) = adapter.value(p, address(strategy));
        assertFalse(ok, "wrong venue fails closed");
        assertEq(v, 0);
    }

    function test_value_failsClosed_wrongKind() public {
        _approveAndExecute();
        Position memory p = _livePosition();
        p.kind = PositionKinds.ERC20_SPOT;
        (uint256 v, bool ok) = adapter.value(p, address(strategy));
        assertFalse(ok, "foreign kind fails closed");
        assertEq(v, 0);
    }

    function test_value_failsClosed_malformedRef() public {
        _approveAndExecute();
        Position memory p = _livePosition();

        p.ref = "";
        (uint256 v, bool ok) = adapter.value(p, address(strategy));
        assertFalse(ok, "empty ref fails closed");
        assertEq(v, 0);

        p.ref = abi.encode(Id.unwrap(marketId), Id.unwrap(marketId));
        (v, ok) = adapter.value(p, address(strategy));
        assertFalse(ok, "oversized ref fails closed");
        assertEq(v, 0);
    }

    function test_value_failsClosed_unknownMarket() public {
        _approveAndExecute();
        // Spoofed-market adversary: an id the singleton never created —
        // idToMarketParams returns a zero loan token.
        Position memory p = _livePosition();
        p.ref = abi.encode(keccak256("no such market"));
        (uint256 v, bool ok) = adapter.value(p, address(strategy));
        assertFalse(ok, "unknown market fails closed");
        assertEq(v, 0);
    }

    function test_value_failsClosed_numeraireMismatch() public {
        // A REAL market whose loan token isn't the holder's vault asset must
        // not be priced — its units would corrupt the vault's NAV scale.
        ERC20Mock other = new ERC20Mock("OTHER", "OTHER", 18);
        MarketParams memory foreign = mp;
        foreign.loanToken = address(other);
        Id foreignId = mockMorpho.createMarket(foreign);

        Position memory p = _livePosition();
        p.ref = abi.encode(Id.unwrap(foreignId));
        (uint256 v, bool ok) = adapter.value(p, address(strategy));
        assertFalse(ok, "wrong-numeraire market fails closed");
        assertEq(v, 0);
    }

    function test_value_failsClosed_holderWithoutVault() public {
        // A holder that isn't a strategy (no vault()) cannot prove its
        // numeraire → fail closed rather than skip the binding.
        address eoa = makeAddr("eoa");
        (uint256 v, bool ok) = adapter.value(_livePosition(), eoa);
        assertFalse(ok, "non-strategy holder fails closed");
        assertEq(v, 0);
    }

    function test_value_failsClosed_irmReverts() public {
        _approveAndExecute();
        mockMorpho.simulateBorrow(mp, 60_000e6, borrower);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        irm.setReverting(true);
        // Pending interest forces a borrowRateView call → external read
        // reverts → (0, false), never a bubbled revert.
        (uint256 v, bool ok) = adapter.value(_livePosition(), address(strategy));
        assertFalse(ok, "reverting IRM fails closed");
        assertEq(v, 0);
    }

    function test_router_failsClosed_wrongVenueThroughRouter() public {
        _approveAndExecute();
        Position memory p = _livePosition();
        p.venue = makeAddr("fakeMorpho");
        (uint256 v, bool ok) = router.valuePosition(p, address(strategy));
        assertFalse(ok, "router maps adapter not-OK to lane B");
        assertEq(v, 0);
    }
}
