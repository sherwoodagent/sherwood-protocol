// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LaneAFixture} from "../../helpers/LaneAFixture.sol";
import {MorphoSupplyStrategy} from "../../../src/strategies/MorphoSupplyStrategy.sol";
import {MorphoSupplyAdapter} from "../../../src/pricing/MorphoSupplyAdapter.sol";
import {Position} from "../../../src/interfaces/IPriceRouter.sol";
import {PositionKinds} from "../../../src/libraries/PositionKinds.sol";
import {IMorpho, Id, MarketParams, Market} from "../../../src/vendor/morpho/IMorpho.sol";
import {SharesMathLib} from "../../../src/vendor/morpho/MorphoLibs.sol";

/// @notice Minimal vault stand-in for the fork lifecycle (see the unit-suite
///         VaultStub): exposes `asset()` and is pranked for lifecycle calls.
contract ForkVaultStub {
    address internal immutable _assetToken;

    constructor(address assetToken_) {
        _assetToken = assetToken_;
    }

    function asset() external view returns (address) {
        return _assetToken;
    }
}

/**
 * @title MorphoSupplyMainnetForkTest
 * @notice Full-lifecycle fork test for MorphoSupplyStrategy + MorphoSupplyAdapter
 *         against the CANONICAL Morpho Blue singleton on Robinhood Chain
 *         mainnet (4663). This is where the vendored struct layouts and the
 *         view-accrual port earn their keep: every decode and every Taylor
 *         term runs against the live contract and the live AdaptiveCurve IRM.
 *
 *         Market under test (picked 2026-08-01 as the deepest USDG loan
 *         market: ~22.65M USDG supplied, ~20.33M borrowed, ~2.33M idle):
 *           id         0x0309c02dabf0be02682af1a2bde9a457f4df0f0b6bc889cde3f948e5315e4114
 *           loanToken  USDG    0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168
 *           collateral 0xde770c84FE66E063336b31737cFE9790f18c4087
 *           oracle     0xe694c531F65c4BaBc88A52d7178476e095e51574
 *           irm        0x2BD3d5965B26B51814AC95127B2b80dD6CcC0fa1
 *           lltv       0.915e18
 *
 * @dev Skips when ROBINHOOD_RPC_URL is unset (shared fork-test convention);
 *      excluded from default CI via the test/integration/** path filter.
 *      Run explicitly:
 *        forge test --match-path "test/integration/strategies/MorphoSupplyMainnetFork.t.sol" -vv
 */
contract MorphoSupplyMainnetForkTest is LaneAFixture {
    using SharesMathLib for uint256;

    // Pinned Robinhood mainnet block (2026-08-01, market active: ~22.65M USDG
    // supplied, ~20.33M borrowed, interest accruing). NOTE: the public RPC
    // (rpc.mainnet.chain.robinhood.com) only serves state for a sliding window
    // of recent blocks — running this suite against an old pin requires an
    // archive endpoint (e.g. the Tenderly fork RPC wired in foundry.toml).
    uint256 constant FORK_BLOCK = 25_290_555;

    address constant MORPHO = 0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    bytes32 constant MARKET_ID = 0x0309c02dabf0be02682af1a2bde9a457f4df0f0b6bc889cde3f948e5315e4114;

    uint256 constant SUPPLY_AMOUNT = 10_000e6; // 10k USDG — well inside ~2.33M idle

    address proposer = makeAddr("proposer");

    bool internal forkReady;
    ForkVaultStub vaultStub;
    MorphoSupplyStrategy strategy;
    MorphoSupplyAdapter adapter;
    MarketParams mp;

    function setUp() public {
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return; // tests skip via _requireFork()

        vm.createSelectFork(rpc, FORK_BLOCK);
        require(block.chainid == 4663, "not on Robinhood mainnet fork");

        // Vendored-layout validation: decode the live market params and pin
        // them against the values read via `cast` when this test was written.
        // Garbage here = wrong struct layout; fix the vendored types, not this.
        mp = IMorpho(MORPHO).idToMarketParams(Id.wrap(MARKET_ID));
        assertEq(mp.loanToken, USDG, "loanToken decode");
        assertEq(mp.collateralToken, 0xde770c84FE66E063336b31737cFE9790f18c4087, "collateral decode");
        assertEq(mp.oracle, 0xe694c531F65c4BaBc88A52d7178476e095e51574, "oracle decode");
        assertEq(mp.irm, 0x2BD3d5965B26B51814AC95127B2b80dD6CcC0fa1, "irm decode");
        assertEq(mp.lltv, 0.915e18, "lltv decode");

        Market memory m = IMorpho(MORPHO).market(Id.wrap(MARKET_ID));
        assertGt(uint256(m.totalBorrowAssets), 0, "market has active borrows");
        assertGt(uint256(m.totalSupplyAssets), uint256(m.totalBorrowAssets), "market has idle liquidity");

        vaultStub = new ForkVaultStub(USDG);
        deal(USDG, address(vaultStub), SUPPLY_AMOUNT);

        MorphoSupplyStrategy template = new MorphoSupplyStrategy();
        strategy = MorphoSupplyStrategy(Clones.clone(address(template)));
        strategy.initialize(address(vaultStub), proposer, abi.encode(MORPHO, mp, SUPPLY_AMOUNT));

        adapter = new MorphoSupplyAdapter(MORPHO);
        _deployRouter();
        _registerKind(PositionKinds.MORPHO_BLUE_SUPPLY, address(adapter), true);

        forkReady = true;
    }

    /// @dev vm.skip from the test body (not setUp) — the setUp-skip form is
    ///      forge-version-dependent and reads as a failure on some versions.
    function _requireFork() internal {
        if (!forkReady) vm.skip(true);
    }

    // ── Full lifecycle: supply → warp/value → partial withdrawTo → settle ──

    function test_fork_fullLifecycle() public {
        _requireFork();

        // Execute: vault approves, strategy supplies to the live singleton.
        address strat = address(strategy);
        vm.startPrank(address(vaultStub));
        IERC20(USDG).approve(strat, SUPPLY_AMOUNT);
        strategy.execute();
        vm.stopPrank();

        uint256 shares = IMorpho(MORPHO).position(Id.wrap(MARKET_ID), strat).supplyShares;
        assertGt(shares, 0, "supply shares minted on live morpho");
        assertEq(IERC20(USDG).balanceOf(strat), 0, "nothing stranded on strategy");

        Position[] memory ps = strategy.positions();
        assertEq(ps.length, 1, "one live position");
        assertEq(ps[0].venue, MORPHO, "venue = canonical singleton");

        // Value now via the real PriceRouter + adapter: instantOK with Lane A
        // enabled; value = principal minus at most share-rounding dust.
        (uint256 v0, bool ok0) = router.valueStrategy(strat);
        assertTrue(ok0, "lane A open on live market");
        assertGe(v0 + 2, SUPPLY_AMOUNT, "initial value ~= principal");
        assertLe(v0, SUPPLY_AMOUNT, "no free value at entry");
        console2.log("Value at entry:", v0);

        // Warp a week: active borrows → supply-side interest accrues.
        vm.warp(vm.getBlockTimestamp() + 7 days);
        (uint256 v1, bool ok1) = router.valueStrategy(strat);
        assertTrue(ok1, "still priceable after warp");
        assertGt(v1, v0, "interest accrued over 7 days");
        console2.log("Value after 7d:", v1);

        // View-accrual port vs the real singleton: accrue on-chain (live
        // AdaptiveCurve IRM), then the storage-derived value must equal the
        // adapter's pre-accrual view valuation.
        (uint256 viewValue, bool okAdapter) = adapter.value(ps[0], strat);
        assertTrue(okAdapter, "adapter prices directly");
        IMorpho(MORPHO).accrueInterest(mp);
        Market memory m = IMorpho(MORPHO).market(Id.wrap(MARKET_ID));
        uint256 stateValue = shares.toAssetsDown(m.totalSupplyAssets, m.totalSupplyShares);
        assertEq(viewValue, stateValue, "vendored view accrual == live singleton accrual");

        // Partial instant exit: exact delivery straight to the vault.
        uint256 avail = strategy.availableLiquidity();
        assertGt(avail, 0, "instant liquidity advertised");
        console2.log("availableLiquidity:", avail);
        uint256 part = SUPPLY_AMOUNT / 2;
        assertLe(part, avail, "partial request within advertised liquidity");
        uint256 balBefore = IERC20(USDG).balanceOf(address(vaultStub));
        vm.prank(address(vaultStub));
        strategy.withdrawTo(part);
        assertEq(IERC20(USDG).balanceOf(address(vaultStub)) - balBefore, part, "exact partial delivery");

        // Settle: full shares-based unwind, interest included.
        vm.prank(address(vaultStub));
        strategy.settle();
        assertEq(IMorpho(MORPHO).position(Id.wrap(MARKET_ID), strat).supplyShares, 0, "position closed");
        assertEq(IERC20(USDG).balanceOf(strat), 0, "strategy fully drained");
        assertEq(strategy.positions().length, 0, "no positions after settle");

        uint256 finalBal = IERC20(USDG).balanceOf(address(vaultStub));
        console2.log("Vault USDG after settle:", finalBal);
        assertGt(finalBal, SUPPLY_AMOUNT, "principal + 7d interest returned");

        // Post-settle the router degrades to Lane B (no positions).
        (uint256 vEnd, bool okEnd) = router.valueStrategy(strat);
        assertFalse(okEnd, "lane B after full unwind");
        assertEq(vEnd, 0, "no residual value");
    }

    // ── Fail-closed on the live chain: spoofed venue never prices ──

    function test_fork_adapterFailsClosed_spoofedVenue() public {
        _requireFork();
        Position memory p = Position({
            venue: makeAddr("fakeMorpho"), kind: PositionKinds.MORPHO_BLUE_SUPPLY, ref: abi.encode(MARKET_ID)
        });
        (uint256 v, bool ok) = adapter.value(p, address(strategy));
        assertFalse(ok, "spoofed venue fails closed");
        assertEq(v, 0);
    }
}
