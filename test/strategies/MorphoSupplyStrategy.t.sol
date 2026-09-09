// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
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
}

// ═══════════════════════════════════════════════════════════════════════
// Settlement is all-or-revert: the market pays in full or settle reverts
// ═══════════════════════════════════════════════════════════════════════

contract MorphoSupplySettlementTest is MorphoSupplyFixture {
    /// @dev Borrow all but `leave` of the market so a full-position withdraw
    ///      cannot be paid out, and do NOT repay.
    function _pinUtilization(uint256 leave) internal {
        mockMorpho.simulateBorrow(mp, SUPPLY - leave, borrower);
    }

    /// @notice A market that cannot pay the whole position reverts settle; nothing is
    ///         delivered partially and the position is untouched.
    function test_settle_atPinnedUtilization_revertsRatherThanDeliveringPartially() public {
        _approveAndExecute();
        _pinUtilization(10_000e6); // only 10k of the 100k is withdrawable
        uint256 sharesBefore = mockMorpho.position(marketId, address(strategy)).supplyShares;

        vm.prank(address(vaultStub));
        vm.expectRevert("MockMorpho: insufficient liquidity");
        strategy.settle();

        assertEq(usdg.balanceOf(address(vaultStub)), 0, "delivered partially");
        assertEq(mockMorpho.position(marketId, address(strategy)).supplyShares, sharesBefore, "position touched");
        assertEq(uint256(strategy.state()), uint256(BaseStrategy.State.Executed), "state advanced");
    }

    /// @notice A flash loan that empties Morpho's idle balance while the totals still
    ///         say the position is withdrawable: the transfer fails and settle reverts,
    ///         instead of the old clamp-to-idle-balance delivering the drained residue.
    function test_settle_revertsRatherThanDeliveringPartially_whenMorphoIsFlashDrained() public {
        _approveAndExecute();
        uint256 idle = usdg.balanceOf(address(mockMorpho));
        assertEq(idle, SUPPLY, "precondition: the market holds the whole supply idle");

        // Model the flash-loan frame: the tokens leave, the accounting does not.
        vm.prank(address(mockMorpho));
        usdg.transfer(borrower, idle - 10_000e6);

        vm.prank(address(vaultStub));
        vm.expectPartialRevert(IERC20Errors.ERC20InsufficientBalance.selector);
        strategy.settle();

        assertEq(usdg.balanceOf(address(vaultStub)), 0, "delivered the drained remainder");
        assertGt(mockMorpho.position(marketId, address(strategy)).supplyShares, 0, "position burned");

        // The frame ends, the balance is back, and the identical call delivers everything.
        vm.prank(borrower);
        usdg.transfer(address(mockMorpho), idle - 10_000e6);
        vm.prank(address(vaultStub));
        strategy.settle();
        assertEq(usdg.balanceOf(address(vaultStub)), SUPPLY, "full delivery on retry");
        assertEq(mockMorpho.position(marketId, address(strategy)).supplyShares, 0, "position fully unwound");
    }

    /// @notice A failed settle is simply retried once utilization recedes.
    function test_settle_succeedsOnRetryOnceLiquidityReturns() public {
        _approveAndExecute();
        _pinUtilization(10_000e6);
        vm.prank(address(vaultStub));
        vm.expectRevert("MockMorpho: insufficient liquidity");
        strategy.settle();

        usdg.mint(borrower, SUPPLY);
        vm.startPrank(borrower);
        usdg.approve(address(mockMorpho), type(uint256).max);
        mockMorpho.simulateRepayAll(mp);
        vm.stopPrank();

        vm.prank(address(vaultStub));
        strategy.settle();
        assertGe(usdg.balanceOf(address(vaultStub)), SUPPLY, "principal (plus interest) delivered");
        assertEq(mockMorpho.position(marketId, address(strategy)).supplyShares, 0, "position fully unwound");
        assertEq(usdg.balanceOf(address(strategy)), 0, "nothing left on the clone");
    }

    /// @notice No regression on the liquid path: a market that can pay in full
    ///         settles by SHARES, so accrued interest comes out with no dust stranded.
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
