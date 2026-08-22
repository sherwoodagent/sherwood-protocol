// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MorphoSupplyStrategy} from "../../../src/strategies/MorphoSupplyStrategy.sol";
import {MockProposalStatus} from "../../mocks/MockProposalStatus.sol";
import {IMorpho, Id, MarketParams, Market} from "../../../src/vendor/morpho/IMorpho.sol";
import {MorphoBalancesLib, SharesMathLib} from "../../../src/vendor/morpho/MorphoLibs.sol";

/// @notice Minimal vault stand-in for the fork lifecycle (see the unit-suite
///         VaultStub): exposes `asset()` and `governor()` (BaseStrategy's
///         active-proposal binding) and is pranked for lifecycle calls.
contract ForkVaultStub {
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

/**
 * @title MorphoSupplyMainnetForkTest
 * @notice Full-lifecycle fork test for MorphoSupplyStrategy against the
 *         CANONICAL Morpho Blue singleton on Robinhood Chain mainnet (4663).
 *         This is where the vendored struct layouts and the view-accrual port
 *         (`MorphoBalancesLib`) earn their keep: every decode and every Taylor
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
contract MorphoSupplyMainnetForkTest is Test {
    using SharesMathLib for uint256;
    using MorphoBalancesLib for IMorpho;

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
    MarketParams mp;

    function setUp() public {
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return; // tests skip via _requireFork()

        // PIN FROM THE ENVIRONMENT, like RobinhoodMainnetIntegrationTest. The
        // hardcoded pin this replaced is unreachable: the public RPC prunes to
        // a ~5k-block window and returns -32000 for it, and the archive vnet
        // reports a different chain id, which the old `require` refused. 0 =
        // fork at latest.
        uint256 pin = vm.envOr("ROBINHOOD_FORK_BLOCK", uint256(0));
        if (pin == 0) {
            vm.createSelectFork(rpc);
        } else {
            vm.createSelectFork(rpc, pin);
        }
        uint256 wantChain = vm.envOr("ROBINHOOD_FORK_CHAIN_ID", uint256(4663));
        require(block.chainid == wantChain, "unexpected chain: set ROBINHOOD_FORK_CHAIN_ID (archive vnet is 9994663)");

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

        MockProposalStatus status = new MockProposalStatus();
        vaultStub = new ForkVaultStub(USDG, address(status));
        deal(USDG, address(vaultStub), SUPPLY_AMOUNT);

        MorphoSupplyStrategy template = new MorphoSupplyStrategy();
        strategy = MorphoSupplyStrategy(Clones.clone(address(template)));
        strategy.initialize(address(vaultStub), proposer, abi.encode(MORPHO, mp, SUPPLY_AMOUNT));
        // BaseStrategy.execute() binds to the active proposal's strategy.
        status.set(1, 1, address(strategy));

        forkReady = true;
    }

    /// @dev vm.skip from the test body (not setUp) — the setUp-skip form is
    ///      forge-version-dependent and reads as a failure on some versions.
    function _requireFork() internal {
        if (!forkReady) vm.skip(true);
    }

    // ── Full lifecycle: supply → warp/value → settle ──

    /// @dev The strategy's supply value with pending interest, computed
    ///      view-side through the vendored `MorphoBalancesLib` accrual port —
    ///      the same read `_deliverableNow` builds on.
    function _viewValue(uint256 shares) internal view returns (uint256) {
        (uint256 totalSupplyAssets, uint256 totalSupplyShares,,) = IMorpho(MORPHO).expectedMarketBalances(mp);
        return shares.toAssetsDown(totalSupplyAssets, totalSupplyShares);
    }

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

        // Value now: principal minus at most share-rounding dust.
        uint256 v0 = _viewValue(shares);
        assertGe(v0 + 2, SUPPLY_AMOUNT, "initial value ~= principal");
        assertLe(v0, SUPPLY_AMOUNT, "no free value at entry");
        console2.log("Value at entry:", v0);

        // Warp a week: active borrows → supply-side interest accrues.
        vm.warp(vm.getBlockTimestamp() + 7 days);
        uint256 v1 = _viewValue(shares);
        assertGt(v1, v0, "interest accrued over 7 days");
        console2.log("Value after 7d:", v1);

        // View-accrual port vs the real singleton: accrue on-chain (live
        // AdaptiveCurve IRM), then the storage-derived value must equal the
        // pre-accrual view valuation.
        IMorpho(MORPHO).accrueInterest(mp);
        Market memory m = IMorpho(MORPHO).market(Id.wrap(MARKET_ID));
        uint256 stateValue = shares.toAssetsDown(m.totalSupplyAssets, m.totalSupplyShares);
        assertEq(v1, stateValue, "vendored view accrual == live singleton accrual");

        // Settle: full shares-based unwind, interest included.
        vm.prank(address(vaultStub));
        strategy.settle();
        assertEq(IMorpho(MORPHO).position(Id.wrap(MARKET_ID), strat).supplyShares, 0, "position closed");
        assertEq(IERC20(USDG).balanceOf(strat), 0, "strategy fully drained");

        uint256 finalBal = IERC20(USDG).balanceOf(address(vaultStub));
        console2.log("Vault USDG after settle:", finalBal);
        assertGt(finalBal, SUPPLY_AMOUNT, "principal + 7d interest returned");
    }
}
