// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PortfolioStrategy} from "../../src/strategies/PortfolioStrategy.sol";
import {BaseStrategy} from "../../src/strategies/BaseStrategy.sol";
import {ISwapAdapter} from "../../src/interfaces/ISwapAdapter.sol";
import {ExposureLedger} from "../../src/ExposureLedger.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockSwapAdapter} from "../mocks/MockSwapAdapter.sol";
import {
    MockGovernorAlwaysActive,
    MockPermissiveTierRegistry,
    MockVaultGovernorStub
} from "../mocks/MockGovernorAlwaysActive.sol";

contract FP01Aggregator {
    uint8 public decimals;
    int256 internal _answer;
    uint256 internal _updatedAt;

    constructor(uint8 d, int256 a, uint256 u) {
        decimals = d;
        _answer = a;
        _updatedAt = u;
    }

    function set(int256 a, uint256 u) external {
        _answer = a;
        _updatedAt = u;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, _answer, _updatedAt, _updatedAt, 1);
    }
}

/// @notice Two-token constant-product pool exposed as an ISwapAdapter (no fee). Reserves = balances.
contract FP01Cpmm is ISwapAdapter {
    error FP01Slippage(uint256 out, uint256 minOut);

    function _out(address tokenIn, address tokenOut, uint256 amountIn) internal view returns (uint256) {
        uint256 rIn = IERC20(tokenIn).balanceOf(address(this));
        uint256 rOut = IERC20(tokenOut).balanceOf(address(this));
        return (rOut * amountIn) / (rIn + amountIn);
    }

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOutMin, bytes calldata)
        external
        returns (uint256 amountOut)
    {
        amountOut = _out(tokenIn, tokenOut, amountIn);
        if (amountOut < amountOutMin) revert FP01Slippage(amountOut, amountOutMin);
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).transfer(msg.sender, amountOut);
    }

    function quote(address tokenIn, address tokenOut, uint256 amountIn, bytes calldata)
        external
        view
        returns (uint256)
    {
        return _out(tokenIn, tokenOut, amountIn);
    }
}

/// @notice FP-01 / N-03: the Portfolio strategy only initialises and executes on the vault asset, priced at $1 by the ledger.
contract PortfolioStrategy_usdPeggedAssetTest is Test {
    int256 constant PRICE_TSLA = 37090999999; // TSLA/USD, 8 dec (4663)
    uint256 constant ETH_USD_8 = 3000e8;
    uint256 constant SLIP = 500; // 5%

    MockGovernorAlwaysActive gov;
    ExposureLedger ledger;
    address ledgerOwner = makeAddr("ledgerOwner");
    FP01Aggregator fTsla;
    FP01Aggregator fUsdg;
    FP01Aggregator fUsd18;
    FP01Aggregator fWeth;
    ERC20Mock tsla;
    ERC20Mock weth;
    ERC20Mock usdg;
    ERC20Mock usd18;
    address attacker = makeAddr("attacker");

    function setUp() public {
        gov = new MockGovernorAlwaysActive();
        gov.setTierRegistry(address(new MockPermissiveTierRegistry()));
        tsla = new ERC20Mock("Tesla", "TSLA", 18);
        weth = new ERC20Mock("Wrapped Ether", "WETH", 18);
        usdg = new ERC20Mock("Global Dollar", "USDG", 6);
        usd18 = new ERC20Mock("USD 18", "USD18", 18);
        fTsla = new FP01Aggregator(8, PRICE_TSLA, block.timestamp);
        fUsdg = new FP01Aggregator(8, 1e8, block.timestamp);
        fUsd18 = new FP01Aggregator(8, 1e8, block.timestamp);
        fWeth = new FP01Aggregator(8, int256(ETH_USD_8), block.timestamp);

        ledger = new ExposureLedger(ledgerOwner, address(0xdead), 28 days);
        vm.startPrank(ledgerOwner);
        ledger.setAssetFeed(address(usdg), address(fUsdg), 1 days);
        ledger.setAssetFeed(address(usd18), address(fUsd18), 1 days);
        vm.stopPrank();
        gov.setExposureLedger(address(ledger));
    }

    // ── helpers ──

    function _vault(address asset_) internal returns (address v) {
        MockVaultGovernorStub stub = new MockVaultGovernorStub(address(gov));
        stub.setAsset(asset_);
        v = address(stub);
    }

    function _initData(address asset_, address adapter, uint256 total) internal view returns (bytes memory) {
        address[] memory tokens = new address[](1);
        tokens[0] = address(tsla);
        uint256[] memory w = new uint256[](1);
        w[0] = 10_000;
        bytes[] memory extra = new bytes[](1);
        uint8[] memory pd = new uint8[](1);
        pd[0] = 8;
        address[] memory feeds = new address[](1);
        feeds[0] = address(fTsla);
        return abi.encode(asset_, adapter, tokens, w, total, SLIP, extra, pd, feeds);
    }

    function _clone() internal returns (PortfolioStrategy) {
        return PortfolioStrategy(Clones.clone(address(new PortfolioStrategy())));
    }

    function _strategy(address vault, address asset_, address adapter, uint256 total)
        internal
        returns (PortfolioStrategy s)
    {
        s = _clone();
        s.initialize(vault, makeAddr("proposer"), _initData(asset_, adapter, total));
    }

    function _approve(address vault, PortfolioStrategy s, IERC20 asset_, uint256 total) internal {
        vm.prank(vault);
        asset_.approve(address(s), total);
    }

    function _execute(address vault, PortfolioStrategy s, IERC20 asset_, uint256 total) internal {
        _approve(vault, s, asset_, total);
        vm.prank(vault);
        s.execute();
    }

    function _fairRates(uint256 assetDec, uint256 assetUsd8) internal pure returns (uint256 buy, uint256 sell) {
        buy = (assetUsd8 * 1e18 * 1e18) / (uint256(PRICE_TSLA) * (10 ** assetDec));
        sell = (uint256(PRICE_TSLA) * (10 ** assetDec)) / assetUsd8;
    }

    function _adapter(ERC20Mock asset_, uint256 assetUsd8) internal returns (MockSwapAdapter ad, uint256 sell) {
        ad = new MockSwapAdapter();
        uint256 buy;
        (buy, sell) = _fairRates(asset_.decimals(), assetUsd8);
        ad.setRate(address(asset_), address(tsla), buy);
        tsla.mint(address(ad), 1e30);
        asset_.mint(address(ad), 1e36);
    }

    function _pegErr(address asset_, uint256 usd) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(PortfolioStrategy.AssetNotUsdPegged.selector, asset_, usd);
    }

    function _buyFloorRun(ERC20Mock asset_, uint256 total) internal returns (uint256 floor, uint256 fairOut) {
        (MockSwapAdapter ad,) = _adapter(asset_, 1e8);
        (uint256 buy,) = _fairRates(asset_.decimals(), 1e8);
        address vault = _vault(address(asset_));
        asset_.mint(vault, total);
        PortfolioStrategy s = _strategy(vault, address(asset_), address(ad), total);
        _execute(vault, s, asset_, total);
        floor = ad.lastAmountOutMin();
        fairOut = (total * buy) / 1e18;
    }

    // ── non-$1 asset refused at init ──

    /// @notice A WETH vault is refused at init even after the ledger owner gives WETH a feed.
    function test_nonUsdAssetRefusedAtInitEvenWithFeed() public {
        vm.prank(ledgerOwner);
        ledger.setAssetFeed(address(weth), address(fWeth), 1 days);
        (MockSwapAdapter ad,) = _adapter(weth, ETH_USD_8);
        address vault = _vault(address(weth));
        PortfolioStrategy s = _clone();
        vm.expectRevert(_pegErr(address(weth), 3000e18));
        s.initialize(vault, makeAddr("proposer"), _initData(address(weth), address(ad), 10e18));
    }

    /// @notice An asset the ledger cannot price (`FeedNotConfigured`) is refused at init.
    function test_unpricedAssetRefusedAtInit() public {
        (MockSwapAdapter ad,) = _adapter(weth, ETH_USD_8);
        address vault = _vault(address(weth));
        PortfolioStrategy s = _clone();
        vm.expectRevert(_pegErr(address(weth), 0));
        s.initialize(vault, makeAddr("proposer"), _initData(address(weth), address(ad), 10e18));
    }

    /// @notice A stale asset feed is refused at init.
    function test_staleAssetFeedRefusedAtInit() public {
        vm.warp(vm.getBlockTimestamp() + 2 days);
        fTsla.set(PRICE_TSLA, vm.getBlockTimestamp());
        (MockSwapAdapter ad,) = _adapter(usdg, 1e8);
        address vault = _vault(address(usdg));
        PortfolioStrategy s = _clone();
        vm.expectRevert(_pegErr(address(usdg), 0));
        s.initialize(vault, makeAddr("proposer"), _initData(address(usdg), address(ad), 10_000e6));
    }

    /// @notice A governor with no exposure ledger fails closed at init.
    function test_unresolvedLedgerRefusedAtInit() public {
        gov.setExposureLedger(address(0));
        (MockSwapAdapter ad,) = _adapter(usdg, 1e8);
        address vault = _vault(address(usdg));
        PortfolioStrategy s = _clone();
        vm.expectRevert(PortfolioStrategy.ExposureLedgerUnresolved.selector);
        s.initialize(vault, makeAddr("proposer"), _initData(address(usdg), address(ad), 10_000e6));
    }

    /// @notice `asset_` must equal the vault's ERC4626 asset.
    function test_assetArgMustBeVaultAsset() public {
        (MockSwapAdapter ad,) = _adapter(usd18, 1e8);
        address vault = _vault(address(usdg));
        PortfolioStrategy s = _clone();
        vm.expectRevert(
            abi.encodeWithSelector(PortfolioStrategy.AssetNotVaultAsset.selector, address(usd18), address(usdg))
        );
        s.initialize(vault, makeAddr("proposer"), _initData(address(usd18), address(ad), 10_000e18));
    }

    // ── peg band ──

    /// @notice The band is inclusive: exactly $0.99 and $1.01 initialise.
    function test_bandEdgesPass() public {
        (MockSwapAdapter ad,) = _adapter(usdg, 1e8);
        fUsdg.set(0.99e8, block.timestamp);
        _strategy(_vault(address(usdg)), address(usdg), address(ad), 10_000e6);
        fUsdg.set(1.01e8, block.timestamp);
        _strategy(_vault(address(usdg)), address(usdg), address(ad), 10_000e6);
    }

    /// @notice One feed unit outside either edge is refused.
    function test_justOutsideBandRefused() public {
        (MockSwapAdapter ad,) = _adapter(usdg, 1e8);
        address vault = _vault(address(usdg));
        bytes memory data = _initData(address(usdg), address(ad), 10_000e6);
        fUsdg.set(0.99e8 - 1, block.timestamp);
        PortfolioStrategy s = _clone();
        vm.expectRevert(_pegErr(address(usdg), 0.99e18 - 1e10));
        s.initialize(vault, makeAddr("proposer"), data);
        fUsdg.set(1.01e8 + 1, block.timestamp);
        s = _clone();
        vm.expectRevert(_pegErr(address(usdg), 1.01e18 + 1e10));
        s.initialize(vault, makeAddr("proposer"), data);
    }

    // ── execute re-check ──

    /// @notice The asset depegs between init and execute: execute reverts and no funds move.
    function test_depegBetweenInitAndExecuteRefused() public {
        (MockSwapAdapter ad,) = _adapter(usdg, 1e8);
        address vault = _vault(address(usdg));
        usdg.mint(vault, 10_000e6);
        PortfolioStrategy s = _strategy(vault, address(usdg), address(ad), 10_000e6);
        _approve(vault, s, usdg, 10_000e6);

        fUsdg.set(0.98e8, block.timestamp);
        vm.prank(vault);
        vm.expectRevert(_pegErr(address(usdg), 0.98e18));
        s.execute();

        fUsdg.set(1.011e8, block.timestamp);
        vm.prank(vault);
        vm.expectRevert(_pegErr(address(usdg), 1.011e18));
        s.execute();

        assertEq(usdg.balanceOf(vault), 10_000e6);
        assertEq(uint256(s.state()), uint256(BaseStrategy.State.Pending));
    }

    /// @notice The ledger is unwired between init and execute: execute fails closed.
    function test_unresolvedLedgerRefusedAtExecute() public {
        (MockSwapAdapter ad,) = _adapter(usdg, 1e8);
        address vault = _vault(address(usdg));
        usdg.mint(vault, 10_000e6);
        PortfolioStrategy s = _strategy(vault, address(usdg), address(ad), 10_000e6);
        _approve(vault, s, usdg, 10_000e6);
        gov.setExposureLedger(address(0));
        vm.prank(vault);
        vm.expectRevert(PortfolioStrategy.ExposureLedgerUnresolved.selector);
        s.execute();
    }

    // ── exits are never gated ──

    /// @notice The asset depegs after execute: settle and rebalanceDelta still run.
    function test_settleAndRebalanceAfterDepeg() public {
        (MockSwapAdapter ad, uint256 sell) = _adapter(usdg, 1e8);
        address vault = _vault(address(usdg));
        usdg.mint(vault, 10_000e6);
        PortfolioStrategy s = _strategy(vault, address(usdg), address(ad), 10_000e6);
        _execute(vault, s, usdg, 10_000e6);

        fUsdg.set(0.5e8, block.timestamp);
        ad.setRate(address(tsla), address(usdg), sell);
        vm.prank(makeAddr("proposer"));
        s.rebalanceDelta();

        gov.setExposureLedger(address(0));
        vm.prank(vault);
        s.settle();
        assertEq(uint256(s.state()), uint256(BaseStrategy.State.Settled));
        assertApproxEqRel(usdg.balanceOf(vault), 10_000e6, 1e15);
    }

    // ── controls (PoC) ──

    /// @notice USDG (6 dec, $1): the buy floor equals (1-slip) x fair out.
    function test_control_buyFloorUsdg() public {
        (uint256 floor, uint256 fairOut) = _buyFloorRun(usdg, 10_000e6);
        assertApproxEqRel(floor, (fairOut * (10_000 - SLIP)) / 10_000, 1e12);
    }

    /// @notice 18-dec $1 asset: the buy floor equals (1-slip) x fair out.
    function test_control_buyFloorUsd18() public {
        (uint256 floor, uint256 fairOut) = _buyFloorRun(usd18, 10_000e18);
        assertApproxEqRel(floor, (fairOut * (10_000 - SLIP)) / 10_000, 1e12);
    }

    /// @notice USDG vault: settle at the fair price passes.
    function test_control_settleUsdg() public {
        (MockSwapAdapter ad, uint256 sell) = _adapter(usdg, 1e8);
        address vault = _vault(address(usdg));
        usdg.mint(vault, 10_000e6);
        PortfolioStrategy s = _strategy(vault, address(usdg), address(ad), 10_000e6);
        _execute(vault, s, usdg, 10_000e6);
        ad.setRate(address(tsla), address(usdg), sell);
        vm.prank(vault);
        s.settle();
        assertApproxEqRel(usdg.balanceOf(vault), 10_000e6, 1e15);
    }

    /// @notice USDG vault: a front-run pool makes execute revert at the floor.
    function test_control_sandwichRevertsOnUsdg() public {
        FP01Cpmm pool = new FP01Cpmm();
        usdg.mint(address(pool), 370_910e6);
        (uint256 buy,) = _fairRates(6, 1e8);
        tsla.mint(address(pool), (370_910e6 * buy) / 1e18);
        address vault = _vault(address(usdg));
        usdg.mint(vault, 10_000e6);
        PortfolioStrategy s = _strategy(vault, address(usdg), address(pool), 10_000e6);

        usdg.mint(attacker, 3_338_190e6);
        vm.startPrank(attacker);
        usdg.approve(address(pool), type(uint256).max);
        pool.swap(address(usdg), address(tsla), 3_338_190e6, 0, "");
        vm.stopPrank();

        _approve(vault, s, usdg, 10_000e6);
        vm.prank(vault);
        vm.expectRevert();
        s.execute();
        assertEq(uint256(s.state()), uint256(BaseStrategy.State.Pending));
    }
}
