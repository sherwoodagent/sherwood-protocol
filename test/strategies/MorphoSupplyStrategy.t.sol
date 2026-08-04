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
// Strategy: init validation, lifecycle
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

    // ── BaseStrategy defaults: no instant-lane surface ──

    function test_defaults_noPositions_noLiquidity_noOnDemandExit() public {
        _approveAndExecute();
        assertEq(strategy.positions().length, 0, "queue-only: no priceable positions");
        assertEq(strategy.availableLiquidity(), 0, "queue-only: no instant liquidity");
        vm.prank(address(vaultStub));
        vm.expectRevert(BaseStrategy.OnDemandExitUnsupported.selector);
        strategy.withdrawTo(1e6);
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

    // ── #16: accrual is bounded by uint128, exactly as upstream ──

    /// @dev Drive `totalBorrowAssets * taylor(rate * elapsed)` past uint128
    ///      while staying inside uint256 — the only band where accumulating in
    ///      uint256 locals disagrees with upstream's `toUint128` narrowing.
    ///      Borrow total is parked high but legal, and a steep rate is accrued
    ///      over a day, so the projected total cannot fit the `Market` struct
    ///      the singleton itself writes.
    ///      Numbers: totals at uint128.max/4 ≈ 8.5e37 (legal), and a rate whose
    ///      product with one day is 2e18, so the Taylor term is
    ///      2e18 + 2e18 + 1.33e18 ≈ 5.33e18 and the projected borrow total is
    ///      8.5e37 × 6.33 ≈ 5.4e38 — past uint128 (3.4e38), while every
    ///      intermediate stays far inside uint256.
    function _forceOverflowingAccrual() internal {
        uint128 nearMax = type(uint128).max / 4;
        mockMorpho.forceTotals(marketId, nearMax, nearMax, nearMax, nearMax);
        mockMorpho.forcePosition(marketId, address(strategy), nearMax / 2);
        irm.setRate(uint256(2e18) / 1 days);
        vm.warp(vm.getBlockTimestamp() + 1 days);
    }

    /// @notice A projection the singleton's own uint128 storage could not hold
    ///         must REVERT, not return an inflated total. Upstream narrows
    ///         accrual through `toUint128`; accumulating in uint256 locals
    ///         instead would report NAV the vault can never realize.
    function test_accrual_beyondUint128_reverts_ratherThanInflating() public {
        _forceOverflowingAccrual();
        vm.expectRevert(bytes("max uint128 exceeded"));
        adapter.unguardedValue(marketId, address(strategy));
    }

    /// @notice And that revert must land as Lane B, not as a broken NAV read:
    ///         the adapter's try/catch turns it into `(0, false)`.
    function test_adapter_failsClosedOnOverflowingAccrual() public {
        _forceOverflowingAccrual();
        (uint256 v, bool ok) = adapter.value(_livePosition(), address(strategy));
        assertFalse(ok, "unrealizable projection degrades to Lane B");
        assertEq(v, 0, "and reports no value, rather than an inflated one");
    }
}

// ═══════════════════════════════════════════════════════════════════════
// #18b — settlement cannot be held hostage by market utilization
// ═══════════════════════════════════════════════════════════════════════

contract MorphoSupplySettlementTest is MorphoSupplyFixture {
    /// @dev Borrow all but `leave` of the market so a full-position withdraw
    ///      cannot be paid out, and do NOT repay: utilization stays pinned,
    ///      which is exactly the hostage state.
    function _pinUtilization(uint256 leave) internal {
        mockMorpho.simulateBorrow(mp, SUPPLY - leave, borrower);
    }

    /// @notice Settlement takes what the market can deliver instead of
    ///         reverting. Adversary: a borrower pinning utilization to freeze
    ///         the whole vault — `redemptionsLocked()` would stay true, instant
    ///         exits shut and the queue unable to settle, for as long as they
    ///         hold the position.
    function test_settle_atPinnedUtilization_deliversMaximum_ratherThanReverting() public {
        _approveAndExecute();
        _pinUtilization(10_000e6); // only 10k of the 100k is withdrawable

        uint256 vaultBefore = usdg.balanceOf(address(vaultStub));
        vm.prank(address(vaultStub));
        strategy.settle(); // must NOT revert

        assertEq(usdg.balanceOf(address(vaultStub)) - vaultBefore, 10_000e6, "delivered what the market could pay");
        assertGt(
            mockMorpho.position(marketId, address(strategy)).supplyShares, 0, "residue stays supplied, not destroyed"
        );
    }

    /// @notice The residue is recoverable: once utilization recedes, anyone can
    ///         sweep it back to the vault.
    function test_sweep_returnsTheResidueOnceLiquidityReturns() public {
        _approveAndExecute();
        _pinUtilization(10_000e6);
        vm.prank(address(vaultStub));
        strategy.settle();

        // Borrower repays; the market can now pay the rest.
        usdg.mint(borrower, SUPPLY);
        vm.startPrank(borrower);
        usdg.approve(address(mockMorpho), type(uint256).max);
        mockMorpho.simulateRepayAll(mp);
        vm.stopPrank();

        uint256 vaultBefore = usdg.balanceOf(address(vaultStub));
        uint256 swept = strategy.sweep(); // permissionless
        assertGt(swept, 0, "residue recovered");
        assertEq(usdg.balanceOf(address(vaultStub)) - vaultBefore, swept, "and lands in the vault");
        assertEq(mockMorpho.position(marketId, address(strategy)).supplyShares, 0, "position fully unwound");
    }

    /// @notice `sweep` is a post-settlement recovery path only — before
    ///         settlement the position is unwound by `settle`.
    function test_sweep_revertsBeforeSettlement() public {
        _approveAndExecute();
        vm.expectRevert(MorphoSupplyStrategy.NotSettled.selector);
        strategy.sweep();
    }

    /// @notice No regression on the liquid path: a market that can pay in full
    ///         still settles by SHARES, so accrued interest comes out with no
    ///         dust stranded.
    function test_settle_whenFullyLiquid_unwindsCompletelyWithInterest() public {
        _approveAndExecute();
        _borrowWarpRepay(50_000e6, 30 days); // leaves interest on the supply side

        uint256 vaultBefore = usdg.balanceOf(address(vaultStub));
        vm.prank(address(vaultStub));
        strategy.settle();

        assertGt(usdg.balanceOf(address(vaultStub)) - vaultBefore, SUPPLY, "principal plus accrued interest");
        assertEq(mockMorpho.position(marketId, address(strategy)).supplyShares, 0, "nothing left behind");
    }
}
