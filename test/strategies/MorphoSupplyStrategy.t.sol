// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockMorpho, MockIrm} from "../mocks/MockMorpho.sol";
import {MockProposalStatus} from "../mocks/MockProposalStatus.sol";
import {MockPermissiveTierRegistry} from "../mocks/MockPermissiveTierRegistry.sol";
import {MorphoSupplyStrategy} from "../../src/strategies/MorphoSupplyStrategy.sol";
import {BaseStrategy} from "../../src/strategies/BaseStrategy.sol";
import {Id, MarketParams, Market} from "../../src/vendor/morpho/IMorpho.sol";

/// @notice Minimal vault stand-in: the strategy consumes `asset()` and, on
///         `execute()`, `governor()` (BaseStrategy's active-proposal binding,
///         issue #150); lifecycle calls are pranked as this address.
contract VaultStub {
    /// @dev `BaseStrategy.onlyProposer` re-checks the vault's live agent set on
    ///      every proposer-gated call, so a vault stand-in must answer this or
    ///      `rebalance` / `rebalanceDelta` / `updateParams` all fail closed.
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

/// @notice Shared fixture: 6-decimal USDG-like loan token, a functional
///         MockMorpho market with a settable-rate IRM, a VaultStub funded
///         with the supply amount, and an initialized strategy clone.
abstract contract MorphoSupplyFixture is Test {
    uint256 constant SUPPLY = 100_000e6;
    // ~5% APR as a per-second WAD rate.
    uint256 constant RATE_PER_SECOND = uint256(0.05e18) / 365 days;

    ERC20Mock usdg;
    MockIrm irm;
    MockMorpho mockMorpho;
    MarketParams mp;
    Id marketId;
    MockProposalStatus status;
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

        status = new MockProposalStatus();
        // `_initialize` fails CLOSED when `vault() -> governor() -> tierRegistry()`
        // yields nothing, so the governor stand-in must seat a registry.
        // Permissive by default; the binding tests deny specific addresses.
        status.setTierRegistry(address(new MockPermissiveTierRegistry()));
        vaultStub = new VaultStub(address(usdg), address(status));
        usdg.mint(address(vaultStub), SUPPLY);

        template = new MorphoSupplyStrategy();
        strategy = _newStrategy(mp, SUPPLY);
        // BaseStrategy.execute() binds to the active proposal's strategy.
        status.set(1, 1, address(strategy));
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

    /// @notice A template that round-trips into the vault asset declares no
    ///         conversion and reports no basis.
    /// @dev    THE COUPLING, from the other side. `hasUnvaluedResidue()`,
    ///         `expectsUnpricedResidue()` and `unpricedCostBasis()` describe one
    ///         design decision, and this template made the opposite one to the
    ///         launch and CL templates: it holds the vault asset, which is
    ///         priced, so it is owed no credit and asks for none. Asserted so a
    ///         future edit cannot make it claim one by accident.
    function test_unpricedCostBasis_nonConvertingTemplateClaimsNothing() public view {
        assertFalse(strategy.expectsUnpricedResidue(), "supplying the vault asset converts nothing");
        assertEq(strategy.unpricedCostBasis(), 0, "and so has no cost basis to report");
        assertFalse(strategy.hasUnvaluedResidue(), "nothing here is unpriceable");
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
        // Vault-only since the cohort-accounting fix: `collectResidue` measures
        // the arrival as a balance delta, so a direct call would land outside
        // that measurement and starve the exited redeem cohort.
        vm.prank(address(vaultStub));
        uint256 swept = strategy.sweep();
        assertGt(swept, 0, "residue recovered");
        assertEq(usdg.balanceOf(address(vaultStub)) - vaultBefore, swept, "and lands in the vault");
        assertEq(mockMorpho.position(marketId, address(strategy)).supplyShares, 0, "position fully unwound");
    }

    /// @notice `sweep` is a post-settlement recovery path only — before
    ///         settlement the position is unwound by `settle`.
    function test_sweep_revertsBeforeSettlement() public {
        _approveAndExecute();
        vm.prank(address(vaultStub));
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

    // ── the residue probes must not route through the proposer's IRM ──

    /// @notice FINDING #3, SUPPRESSED THROUGH THE IRM. `_initialize` binds
    ///         neither `mp.irm` nor the registry against it, and the vault reads
    ///         the residue probes under a gas cap. An accruing read routes
    ///         through `IIrm.borrowRateView`, so an IRM whose view burns past
    ///         that cap makes the probe fail — and a failed probe means the
    ///         residue is never recorded, deposits are priced as if there were
    ///         none, and the skim is back.
    ///
    ///         `sweep()` calls the same market with FULL gas and still works,
    ///         which is what made the asymmetry reachable: suppress the price,
    ///         keep the recovery.
    ///
    ///         Both probes are computed from raw stored totals, so there is no
    ///         external call for a hostile IRM to enter through.
    function test_residueProbes_surviveAGasGriefingIrm() public {
        _approveAndExecute();
        _pinUtilization(10_000e6);
        vm.prank(address(vaultStub));
        strategy.settle();

        // Interest must be pending, or there is nothing for the IRM to be asked
        // about and the griefing branch is never reached.
        vm.warp(vm.getBlockTimestamp() + 30 days);
        irm.setGasToBurn(10_000_000);

        // Read under the same 150k cap the vault applies. Pre-fix these OOG'd.
        (bool okAmount, bytes memory amountRet) =
            address(strategy).staticcall{gas: 150_000}(abi.encodeWithSignature("undeliveredValue()"));
        assertTrue(okAmount, "amount probe must not depend on the proposer's IRM");
        assertGt(abi.decode(amountRet, (uint256)), 0, "and must report the residue");

        (bool okBool,) = address(strategy).staticcall{gas: 150_000}(abi.encodeWithSignature("hasUndeliveredValue()"));
        assertTrue(okBool, "the bool probe must be equally immune");
    }

    /// @notice The raw basis is stale-LOW by the interest accrued since
    ///         `lastUpdate`, never high — the bounded direction. It under-prices
    ///         a deposit by at most that interest, where the suppression it
    ///         replaces omitted the entire residue.
    function test_undeliveredValue_isStaleLowNotHigh() public {
        _approveAndExecute();
        _pinUtilization(10_000e6);
        vm.prank(address(vaultStub));
        strategy.settle();

        uint256 atSettle = strategy.undeliveredValue();
        vm.warp(vm.getBlockTimestamp() + 30 days);

        // Accrual is not projected, so the figure does not move until the market
        // itself accrues — under-reporting by exactly the pending interest, and
        // never over-reporting, which is the direction that would let a deposit
        // be priced against value that never arrives.
        assertEq(strategy.undeliveredValue(), atSettle, "raw totals, no projection");

        // Once the market itself accrues, the figure catches up — the staleness
        // is a lag, not a permanent under-count, and it only ever resolves
        // upward.
        mockMorpho.accrueInterest(mp);
        assertGe(strategy.undeliveredValue(), atSettle, "resolves upward once accrued, never downward");
    }
}
