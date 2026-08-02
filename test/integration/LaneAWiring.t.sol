// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {DeployLaneA} from "../../script/DeployLaneA.s.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {ISyndicateVault} from "../../src/interfaces/ISyndicateVault.sol";
import {VaultWithdrawalQueue} from "../../src/queue/VaultWithdrawalQueue.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {PriceRouter} from "../../src/pricing/PriceRouter.sol";
import {Erc20SpotAdapter} from "../../src/pricing/Erc20SpotAdapter.sol";
import {MorphoSupplyAdapter} from "../../src/pricing/MorphoSupplyAdapter.sol";
import {PortfolioStrategy} from "../../src/strategies/PortfolioStrategy.sol";
import {MorphoSupplyStrategy} from "../../src/strategies/MorphoSupplyStrategy.sol";
import {PositionKinds} from "../../src/libraries/PositionKinds.sol";
import {Id, MarketParams} from "../../src/vendor/morpho/IMorpho.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "../mocks/MockAgentRegistry.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";
import {MockMorpho, MockIrm} from "../mocks/MockMorpho.sol";
import {ObservingSwapAdapter} from "../mocks/ObservingSwapAdapter.sol";
import {MockUniV3Pool} from "../pricing/Erc20SpotAdapter.t.sol";
import {VaultStub} from "../strategies/MorphoSupplyStrategy.t.sol";

/// @dev Same forwarder as `DeployPlanDPreflight.t.sol`: `vm.startBroadcast`
///      runs the script's calls as `DEFAULT_SENDER` while `deployer =
///      msg.sender` is whoever called `deploy()`, and a prank cannot bridge the
///      gap. Etching this at `DEFAULT_SENDER` and calling through it makes the
///      two the same address, as on a real deployment.
contract WiringScriptCaller {
    function fwd(address target, bytes calldata data) external {
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }
}

/// @title LaneAWiringTest
/// @notice Task 5.2: drives the REAL `DeployLaneA` script against real vault
///         fixtures — proxied PriceRouter + BOTH adapters (deployed by the
///         script itself) + BOTH strategies (PortfolioStrategy over a real
///         SyndicateVault, MorphoSupplyStrategy over a MockMorpho market) —
///         and proves the degradation ladder rung by rung:
///           (a) registered + enabled + fresh  → instantOK for each strategy
///           (b) kind disabled                 → Lane B
///           (c) adapter unregistered          → Lane B
///           (d) stale feed                    → Lane B (spot only)
///           (e) divergence beyond bound       → Lane B (spot only)
///           (f) over-cap (adapter and router) → Lane B
///           (g) haircut guard                 → script refuses nonzero haircut
///           (h) fee wiring                    → fee = 200 set and actually paid
///         plus parameter-table round-trip, wiring-order, and pre-flight bites.
///         Governor mocked (sanctioned fallback, same as LaneAEndToEnd).
contract LaneAWiringTest is Test {
    DeployLaneA script;

    SyndicateVault vault;
    BatchExecutorLib executorLib;
    MockAgentRegistry agentRegistry;
    PriceRouter router;
    Erc20SpotAdapter spotAdapter;
    MorphoSupplyAdapter morphoAdapter;
    PortfolioStrategy strategy;
    ObservingSwapAdapter swapAdapter;

    ERC20Mock usdc;
    ERC20Mock tsla;
    ERC20Mock amzn;
    MockAggregatorV3 fTsla;
    MockAggregatorV3 fAmzn;
    MockUniV3Pool poolTsla;
    MockUniV3Pool poolAmzn;
    bool tslaIsToken0;
    bool amznIsToken0;

    MockMorpho mockMorpho;
    MockIrm irm;
    MarketParams mp;
    Id marketId;
    VaultStub morphoVaultStub;
    MorphoSupplyStrategy morphoStrategy;

    address proposer = makeAddr("proposer");
    address alice = makeAddr("alice");
    address constant MOCK_GOVERNOR = address(0xF00D);
    uint256 constant PID = 1;

    uint256 constant TOTAL_AMOUNT = 600e6; // portfolio strategy pulls 600 USDC
    uint256 constant MORPHO_SUPPLY = 100_000e6;
    uint256 constant MAX_AGE = 24 hours; // G3 ceiling — the script refuses more
    uint256 constant BIG_CAP = 1_000_000e6;

    function setUp() public {
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        tsla = new ERC20Mock("Tesla Stock", "TSLA", 18);
        amzn = new ERC20Mock("Amazon Stock", "AMZN", 18);

        // 8-dec push feeds: TSLA $200, AMZN $100 (in USDC terms).
        fTsla = new MockAggregatorV3(8, int256(200e8));
        fAmzn = new MockAggregatorV3(8, int256(100e8));

        // Divergence reference pools sitting exactly at the oracle marks.
        tslaIsToken0 = address(tsla) < address(usdc);
        amznIsToken0 = address(amzn) < address(usdc);
        poolTsla = _newPool(address(tsla), tslaIsToken0, 200e6);
        poolAmzn = _newPool(address(amzn), amznIsToken0, 100e6);

        // Swap venue aligned with the marks.
        swapAdapter = new ObservingSwapAdapter();
        swapAdapter.setRate(address(usdc), address(tsla), 5e27); // 1 USDC -> 0.005 TSLA
        swapAdapter.setRate(address(usdc), address(amzn), 1e28); // 1 USDC -> 0.01 AMZN
        swapAdapter.setRate(address(tsla), address(usdc), 2e8); // 1 TSLA -> 200 USDC
        swapAdapter.setRate(address(amzn), address(usdc), 1e8); // 1 AMZN -> 100 USDC
        tsla.mint(address(swapAdapter), 1_000_000e18);
        amzn.mint(address(swapAdapter), 1_000_000e18);
        usdc.mint(address(swapAdapter), 1_000_000_000e6);

        // Real proxied PriceRouter, owned by the script's broadcast sender.
        router = _newRouter(DEFAULT_SENDER);

        // Real vault (proxied) + queue, owned by the script's broadcast sender
        // so the fee wiring exercises the deployer-owned path.
        executorLib = new BatchExecutorLib();
        agentRegistry = new MockAgentRegistry();
        vault = _newVault(DEFAULT_SENDER, address(usdc));

        // Factory surface for the vault: governor + priceRouter reads.
        vm.mockCall(address(this), abi.encodeWithSignature("governorOf(address)"), abi.encode(MOCK_GOVERNOR));
        vm.mockCall(address(this), abi.encodeWithSignature("priceRouter()"), abi.encode(address(router)));
        _setLocked(false);

        // Portfolio strategy clone, push-feed mode, 50/50 TSLA/AMZN.
        strategy = PortfolioStrategy(Clones.clone(address(new PortfolioStrategy())));
        strategy.initialize(address(vault), proposer, _strategyInitData());

        // Morpho fixture: functional mock market in the vault asset.
        irm = new MockIrm();
        irm.setRate(uint256(0.05e18) / 365 days); // ~5% APR
        mockMorpho = new MockMorpho();
        mp = MarketParams({
            loanToken: address(usdc),
            collateralToken: makeAddr("collateral"),
            oracle: makeAddr("oracle"),
            irm: address(irm),
            lltv: 0.86e18
        });
        marketId = mockMorpho.createMarket(mp);
        morphoVaultStub = new VaultStub(address(usdc));
        usdc.mint(address(morphoVaultStub), MORPHO_SUPPLY);
        morphoStrategy = MorphoSupplyStrategy(Clones.clone(address(new MorphoSupplyStrategy())));
        morphoStrategy.initialize(
            address(morphoVaultStub), proposer, abi.encode(address(mockMorpho), mp, MORPHO_SUPPLY)
        );

        // The REAL wiring script, driven as the broadcast sender.
        script = new DeployLaneA();
        vm.etch(DEFAULT_SENDER, address(new WiringScriptCaller()).code);
        _deploy(_config(address(router), _vaults(address(vault)), true));

        spotAdapter = Erc20SpotAdapter(router.adapterOf(PositionKinds.ERC20_SPOT));
        morphoAdapter = MorphoSupplyAdapter(router.adapterOf(PositionKinds.MORPHO_BLUE_SUPPLY));
        require(address(spotAdapter) != address(0) && address(morphoAdapter) != address(0), "wiring did not land");

        usdc.mint(alice, 1_000_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
    }

    // ── Fixture helpers ──

    function _newPool(address token, bool isToken0, uint256 spotNum) internal returns (MockUniV3Pool) {
        uint160 sqrtP = _sqrtPForPrice(spotNum, 18, isToken0);
        return
            isToken0 ? new MockUniV3Pool(token, address(usdc), sqrtP) : new MockUniV3Pool(address(usdc), token, sqrtP);
    }

    /// @dev Babylonian integer sqrt (test-side only).
    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    /// @dev sqrtPriceX96 producing pool spot `poolNum` (numeraire raw units per
    ///      whole token) for the given side of the pair.
    function _sqrtPForPrice(uint256 poolNum, uint8 tokenDec, bool isToken0) internal pure returns (uint160) {
        uint256 ratioX128 = isToken0 ? (poolNum << 128) / (10 ** tokenDec) : ((10 ** tokenDec) << 128) / poolNum;
        return uint160(_sqrt(ratioX128 << 64));
    }

    function _newRouter(address owner_) internal returns (PriceRouter) {
        PriceRouter impl = new PriceRouter();
        return PriceRouter(address(new ERC1967Proxy(address(impl), abi.encodeCall(PriceRouter.initialize, (owner_)))));
    }

    function _newVault(address owner_, address asset_) internal returns (SyndicateVault v) {
        SyndicateVault impl = new SyndicateVault();
        bytes memory initData = abi.encodeCall(
            SyndicateVault.initialize,
            (ISyndicateVault.InitParams({
                    asset: asset_,
                    name: "V",
                    symbol: "V",
                    owner: owner_,
                    executorImpl: address(executorLib),
                    openDeposits: true,
                    agentRegistry: address(agentRegistry),
                    managementFeeBps: 0
                }))
        );
        v = SyndicateVault(payable(address(new ERC1967Proxy(address(impl), initData))));
        v.setWithdrawalQueue(address(new VaultWithdrawalQueue(address(v))));
    }

    function _vaults(address v) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = v;
    }

    /// @dev The script config over THIS fixture's mocks — the analysis table's
    ///      shape (feed, maxAge, cap, pool, 100bps bound) with test values.
    function _config(address routerAddr, address[] memory vaults_, bool enable)
        internal
        view
        returns (DeployLaneA.Config memory)
    {
        DeployLaneA.TokenEntry[] memory entries = new DeployLaneA.TokenEntry[](2);
        entries[0] = DeployLaneA.TokenEntry({
            token: address(tsla),
            aggregator: address(fTsla),
            maxAge: MAX_AGE,
            capAssets: BIG_CAP,
            referencePool: address(poolTsla),
            maxDivergenceBps: 100
        });
        entries[1] = DeployLaneA.TokenEntry({
            token: address(amzn),
            aggregator: address(fAmzn),
            maxAge: MAX_AGE,
            capAssets: BIG_CAP,
            referencePool: address(poolAmzn),
            maxDivergenceBps: 100
        });
        return DeployLaneA.Config({
            router: routerAddr,
            morpho: address(mockMorpho),
            numeraire: address(usdc),
            entries: entries,
            vaults: vaults_,
            instantCapSpot: BIG_CAP,
            instantCapMorpho: BIG_CAP,
            enableLaneA: enable
        });
    }

    function _deploy(DeployLaneA.Config memory cfg) internal {
        WiringScriptCaller(DEFAULT_SENDER).fwd(address(script), abi.encodeCall(DeployLaneA.deploy, (cfg)));
    }

    function _deployExpecting(DeployLaneA.Config memory cfg, string memory prefix) internal {
        try WiringScriptCaller(DEFAULT_SENDER).fwd(address(script), abi.encodeCall(DeployLaneA.deploy, (cfg))) {
            revert("pre-flight did not bite");
        } catch Error(string memory reason) {
            _assertPrefix(reason, prefix);
        }
    }

    function _assertPrefix(string memory reason, string memory prefix) internal pure {
        bytes memory r = bytes(reason);
        bytes memory p = bytes(prefix);
        require(r.length >= p.length, reason);
        bytes memory head = new bytes(p.length);
        for (uint256 i; i < p.length; ++i) {
            head[i] = r[i];
        }
        require(keccak256(head) == keccak256(p), reason);
    }

    function _strategyInitData() internal view returns (bytes memory) {
        address[] memory tokens = new address[](2);
        tokens[0] = address(tsla);
        tokens[1] = address(amzn);
        uint256[] memory weights = new uint256[](2);
        weights[0] = 5000;
        weights[1] = 5000;
        bytes[] memory extraData = new bytes[](2);
        uint8[] memory pd = new uint8[](2);
        pd[0] = 8;
        pd[1] = 8;
        bytes32[] memory feedIds = new bytes32[](2);
        feedIds[0] = bytes32(uint256(uint160(address(fTsla))));
        feedIds[1] = bytes32(uint256(uint160(address(fAmzn))));
        return abi.encode(
            address(usdc),
            address(swapAdapter),
            address(0), // push mode
            tokens,
            weights,
            TOTAL_AMOUNT,
            uint256(100), // 1% max slippage
            extraData,
            pd,
            feedIds
        );
    }

    function _setLocked(bool locked) internal {
        vm.mockCall(
            MOCK_GOVERNOR, abi.encodeWithSignature("getActiveProposal()"), abi.encode(locked ? PID : uint256(0))
        );
        vm.mockCall(MOCK_GOVERNOR, abi.encodeWithSignature("openProposalCount()"), abi.encode(locked ? uint256(1) : 0));
        if (locked) {
            vm.mockCall(
                MOCK_GOVERNOR, abi.encodeWithSignature("strategyOf(uint256)", PID), abi.encode(address(strategy))
            );
        }
    }

    function _depositExecuteLock() internal {
        vm.prank(alice);
        vault.deposit(1_000e6, alice);

        vm.prank(address(vault));
        usdc.approve(address(strategy), TOTAL_AMOUNT);
        vm.prank(address(vault));
        strategy.execute();

        _setLocked(true);
    }

    function _executeMorpho() internal {
        vm.prank(address(morphoVaultStub));
        usdc.approve(address(morphoStrategy), MORPHO_SUPPLY);
        vm.prank(address(morphoVaultStub));
        morphoStrategy.execute();
    }

    // ── (a) both kinds registered + enabled + fresh → instantOK each ──

    function test_ladder_a_bothStrategiesInstantOK() public {
        _depositExecuteLock();
        _executeMorpho();

        (uint256 nav, bool ok) = router.valueStrategy(address(strategy));
        assertTrue(ok, "ERC20_SPOT strategy instant-eligible");
        assertEq(nav, 600e6, "router-priced basket value");

        (uint256 mNav, bool mOk) = router.valueStrategy(address(morphoStrategy));
        assertTrue(mOk, "MORPHO_BLUE_SUPPLY strategy instant-eligible");
        assertEq(mNav, MORPHO_SUPPLY, "supply valued at par pre-interest");

        assertEq(vault.totalAssets(), 1_000e6, "vault NAV = 400 float + 600 live basket");
    }

    // ── (b) kind disabled → Lane B, per kind ──

    function test_ladder_b_kindDisabled_degradesThatKindOnly() public {
        _depositExecuteLock();
        _executeMorpho();

        vm.prank(DEFAULT_SENDER);
        router.setLaneAEnabled(PositionKinds.ERC20_SPOT, false);
        (, bool ok) = router.valueStrategy(address(strategy));
        assertFalse(ok, "disabled kind: spot strategy degrades to Lane B");
        (, bool mOk) = router.valueStrategy(address(morphoStrategy));
        assertTrue(mOk, "other kind unaffected");
        assertEq(vault.totalAssets(), 400e6, "vault degrades to float-only NAV");

        vm.prank(DEFAULT_SENDER);
        router.setLaneAEnabled(PositionKinds.MORPHO_BLUE_SUPPLY, false);
        (, mOk) = router.valueStrategy(address(morphoStrategy));
        assertFalse(mOk, "disabled kind: morpho strategy degrades to Lane B");

        // Rollback is instant and stateless: re-enable reopens with nothing else.
        vm.startPrank(DEFAULT_SENDER);
        router.setLaneAEnabled(PositionKinds.ERC20_SPOT, true);
        router.setLaneAEnabled(PositionKinds.MORPHO_BLUE_SUPPLY, true);
        vm.stopPrank();
        (, ok) = router.valueStrategy(address(strategy));
        (, mOk) = router.valueStrategy(address(morphoStrategy));
        assertTrue(ok && mOk, "re-enable reopens Lane A, no stranded state");
    }

    // ── (c) adapter unregistered → Lane B ──

    function test_ladder_c_adapterUnregistered_degradesToLaneB() public {
        _depositExecuteLock();
        _executeMorpho();

        // A router with the kinds ENABLED but no adapters registered: the
        // enable switch alone must not price anything.
        PriceRouter bare = _newRouter(DEFAULT_SENDER);
        vm.startPrank(DEFAULT_SENDER);
        bare.setLaneAEnabled(PositionKinds.ERC20_SPOT, true);
        bare.setLaneAEnabled(PositionKinds.MORPHO_BLUE_SUPPLY, true);
        vm.stopPrank();

        (uint256 nav, bool ok) = bare.valueStrategy(address(strategy));
        assertFalse(ok, "no adapter: spot strategy is Lane B");
        assertEq(nav, 0);
        (, bool mOk) = bare.valueStrategy(address(morphoStrategy));
        assertFalse(mOk, "no adapter: morpho strategy is Lane B");
    }

    // ── (d) stale feed → Lane B (spot only) ──

    function test_ladder_d_staleFeed_closesSpotOnly() public {
        _depositExecuteLock();
        _executeMorpho();

        vm.warp(vm.getBlockTimestamp() + MAX_AGE + 1);

        (, bool ok) = router.valueStrategy(address(strategy));
        assertFalse(ok, "stale feed: spot strategy is Lane B");
        assertEq(vault.totalAssets(), 400e6, "vault degrades to float-only NAV");
        (, bool mOk) = router.valueStrategy(address(morphoStrategy));
        assertTrue(mOk, "morpho valuation has no feed: unaffected by staleness");

        // Feeds resume → Lane A reopens with no intervention.
        fTsla.setUpdatedAt(vm.getBlockTimestamp());
        fAmzn.setUpdatedAt(vm.getBlockTimestamp());
        (, ok) = router.valueStrategy(address(strategy));
        assertTrue(ok, "fresh marks reopen Lane A");
        assertEq(vault.totalAssets(), 1_000e6);
    }

    // ── (e) divergence beyond bound → Lane B (spot only) ──

    function test_ladder_e_divergenceBeyondBound_closesSpotOnly() public {
        _depositExecuteLock();
        _executeMorpho();

        // Pool drifts 2% off the held oracle mark (bound is 100bps): the
        // weekend hold-last-price adversary — the gate closes Lane A.
        poolTsla.setSqrtPrice(_sqrtPForPrice(204e6, 18, tslaIsToken0));
        (, bool ok) = router.valueStrategy(address(strategy));
        assertFalse(ok, "divergence beyond bound: spot strategy is Lane B");
        assertEq(vault.totalAssets(), 400e6, "vault degrades to float-only NAV");
        (, bool mOk) = router.valueStrategy(address(morphoStrategy));
        assertTrue(mOk, "morpho has no divergence gate: unaffected");

        // Pool re-converges → reopens.
        poolTsla.setSqrtPrice(_sqrtPForPrice(200e6, 18, tslaIsToken0));
        (, ok) = router.valueStrategy(address(strategy));
        assertTrue(ok, "re-converged pool reopens Lane A");
    }

    // ── (f) caps: per-token bounds EXIT SIZE, router kind cap closes the lane ──

    function test_ladder_f_perTokenCapBoundsExitSizeNotPricing() public {
        _depositExecuteLock();

        // A per-token cap below the TSLA position's $300 value does NOT make
        // the position unpriceable — value stays truthful, so NAV stays
        // truthful and a dust donation cannot close the vault's lane. The cap
        // bounds how much can leave through an instant exit instead.
        uint256 uncapped = strategy.availableLiquidity();
        vm.prank(DEFAULT_SENDER);
        spotAdapter.setFeed(address(tsla), address(fTsla), MAX_AGE, 100e6, address(poolTsla), 100);

        (, bool ok) = router.valueStrategy(address(strategy));
        assertTrue(ok, "per-token cap is not a pricing guard: lane stays open");
        assertLt(strategy.availableLiquidity(), uncapped, "but instant-exit capacity is bounded by it");

        // Restore, then trip the router's per-kind cap, which IS a valuation
        // guard and does close the lane.
        vm.prank(DEFAULT_SENDER);
        spotAdapter.setFeed(address(tsla), address(fTsla), MAX_AGE, BIG_CAP, address(poolTsla), 100);
        (, ok) = router.valueStrategy(address(strategy));
        assertTrue(ok, "restored cap reopens");

        vm.prank(DEFAULT_SENDER);
        router.setInstantCap(PositionKinds.ERC20_SPOT, 1e6);
        (, ok) = router.valueStrategy(address(strategy));
        assertFalse(ok, "router kind cap exceeded: Lane B");
    }

    // ── (g) haircut guard: the script refuses a nonzero-haircut router ──

    function test_ladder_g_haircutGuard_refusesNonzeroHaircut() public {
        PriceRouter poisoned = _newRouter(DEFAULT_SENDER);
        vm.prank(DEFAULT_SENDER);
        poisoned.setHaircutBps(PositionKinds.ERC20_SPOT, 1);

        _deployExpecting(_config(address(poisoned), _vaults(address(vault)), false), "PRE-FLIGHT G2");

        // The refusal is total: nothing was registered on the poisoned router.
        assertEq(poisoned.adapterOf(PositionKinds.ERC20_SPOT), address(0), "no adapter registered");
        assertEq(poisoned.adapterOf(PositionKinds.MORPHO_BLUE_SUPPLY), address(0), "no adapter registered");

        // And the guard helper bites standalone (both kinds).
        try script.checkHaircutsZero(address(poisoned)) {
            revert("guard did not bite");
        } catch Error(string memory reason) {
            _assertPrefix(reason, "PRE-FLIGHT G2");
        }
    }

    function test_ladder_g_haircutGuard_morphoKindToo() public {
        PriceRouter poisoned = _newRouter(DEFAULT_SENDER);
        vm.prank(DEFAULT_SENDER);
        poisoned.setHaircutBps(PositionKinds.MORPHO_BLUE_SUPPLY, 50);
        _deployExpecting(_config(address(poisoned), _vaults(address(vault)), false), "PRE-FLIGHT G2");
    }

    // ── (h) fee wiring: 200bps set by the script and actually paid ──

    function test_ladder_h_feeWired_andPaidOnInstantExit() public {
        assertEq(vault.instantExitFeeBps(), 200, "script set the fee (G1)");

        _depositExecuteLock();

        // Withdraw 700 over a 400 float. The penalty is a flat 200bps on the
        // WHOLE exit (float-served or pulled alike), so the ideal gross assets
        // x solves x * 98% = 700e6 -> x = 714_285_714; convert to shares at the
        // pre-exit ratio (the vault mints shares at a decimals offset, so
        // compare in share units).
        uint256 idealShares = vault.convertToShares(714_285_714);
        uint256 shares700 = vault.convertToShares(700e6); // fee-free burn, pre-exit ratio
        uint256 shareSlack = vault.convertToShares(10); // 10 asset units of rounding room
        uint256 sharesBefore = vault.balanceOf(alice);
        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.withdraw(700e6, alice, alice);

        assertEq(usdc.balanceOf(alice) - balBefore, 700e6, "exact assets delivered (EIP-4626 withdraw)");
        uint256 sharesBurned = sharesBefore - vault.balanceOf(alice);
        assertApproxEqAbs(sharesBurned, idealShares, shareSlack, "flat penalty charged on the whole exit");

        // The penalty stays in the vault for remaining LPs: the burn exceeded
        // the fee-free burn (share price rose). Remaining value: the unwind
        // grosses the basket sale up by maxSlippageBps to guarantee min-out,
        // and the surplus parks as strategy-idle numeraire — which `positions()`
        // now enumerates as a par-priced numeraire position, so live NAV alone
        // (no manual add of the strategy's idle balance) is the full 300.
        assertApproxEqAbs(vault.totalAssets(), 300e6, 10, "remaining value in NAV");
        assertGt(sharesBurned, shares700, "penalty burned extra shares beyond the fee-free burn");
    }

    function test_feeAuthority_foreignVault_refusesEnable() public {
        SyndicateVault foreign = _newVault(makeAddr("foreignOwner"), address(usdc));
        PriceRouter fresh = _newRouter(DEFAULT_SENDER);
        _deployExpecting(_config(address(fresh), _vaults(address(foreign)), true), "PRE-FLIGHT G1");
    }

    function test_feeAuthority_foreignVault_wiresInertWithoutEnable() public {
        SyndicateVault foreign = _newVault(makeAddr("foreignOwner"), address(usdc));
        PriceRouter fresh = _newRouter(DEFAULT_SENDER);

        // Without the enable flag the script wires everything inert and emits
        // the fee calldata for the foreign owner instead of setting it.
        _deploy(_config(address(fresh), _vaults(address(foreign)), false));

        assertEq(foreign.instantExitFeeBps(), 0, "foreign vault fee untouched (instructions emitted)");
        assertTrue(fresh.adapterOf(PositionKinds.ERC20_SPOT) != address(0), "adapters registered");
        assertFalse(fresh.laneAEnabled(PositionKinds.ERC20_SPOT), "Lane A stays OFF (default flag)");
        assertFalse(fresh.laneAEnabled(PositionKinds.MORPHO_BLUE_SUPPLY), "Lane A stays OFF (default flag)");
    }

    // ── Parameter table round-trips ──

    function test_parameterTable_roundTrips() public view {
        // Registry entries match the config the script was driven with.
        (address agg, uint48 maxAge,,, uint16 divBps, address pool, uint96 cap) = spotAdapter.feedOf(address(tsla));
        assertEq(agg, address(fTsla), "tsla aggregator");
        assertEq(uint256(maxAge), MAX_AGE, "tsla maxAge");
        assertEq(uint256(cap), BIG_CAP, "tsla per-token cap");
        assertEq(pool, address(poolTsla), "tsla reference pool");
        assertEq(uint256(divBps), 100, "tsla divergence bound");

        (agg, maxAge,,, divBps, pool, cap) = spotAdapter.feedOf(address(amzn));
        assertEq(agg, address(fAmzn), "amzn aggregator");
        assertEq(pool, address(poolAmzn), "amzn reference pool");

        assertEq(spotAdapter.numeraire(), address(usdc), "numeraire = vault asset");
        assertEq(spotAdapter.owner(), DEFAULT_SENDER, "adapter owned by deployer pending handoff");
        assertEq(address(morphoAdapter.morpho()), address(mockMorpho), "canonical morpho pinned");
        assertEq(router.instantCap(PositionKinds.ERC20_SPOT), BIG_CAP, "router spot cap");
        assertEq(router.instantCap(PositionKinds.MORPHO_BLUE_SUPPLY), BIG_CAP, "router morpho cap");
        assertTrue(router.laneAEnabled(PositionKinds.ERC20_SPOT), "spot kind enabled");
        assertTrue(router.laneAEnabled(PositionKinds.MORPHO_BLUE_SUPPLY), "morpho kind enabled");
        assertEq(vault.instantExitFeeBps(), 200, "fee wired");
    }

    /// @dev The default Robinhood config IS the analysis §8 table: NVDA $100k,
    ///      AAPL $25k (only with a v3-style pool supplied), TSLA $7.5k, AMD
    ///      excluded, 24h maxAge, 100bps divergence, morpho $250k ops bound.
    function test_defaultConfig_matchesAnalysisTable() public view {
        DeployLaneA.Config memory cfg =
            script.defaultRobinhoodConfig(address(0xB0B), new address[](0), address(0), false);

        assertEq(cfg.numeraire, 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168, "USDG numeraire");
        assertEq(cfg.morpho, 0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010, "canonical Morpho Blue");
        assertEq(cfg.instantCapSpot, 100_000e6, "router spot cap = largest per-token cap");
        assertEq(cfg.instantCapMorpho, 250_000e6, "morpho ops bound");
        assertFalse(cfg.enableLaneA, "activation switch defaults OFF");

        // AAPL dropped without a v3-style reference pool (G4).
        assertEq(cfg.entries.length, 2, "NVDA + TSLA only when AAPL pool unset");
        assertEq(cfg.entries[0].token, 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC, "NVDA token");
        assertEq(cfg.entries[0].aggregator, 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15, "NVDA feed");
        assertEq(cfg.entries[0].capAssets, 100_000e6, "NVDA cap");
        assertEq(cfg.entries[0].maxAge, 86_400, "24h heartbeat maxAge");
        assertEq(cfg.entries[0].maxDivergenceBps, 100, "100bps divergence bound");
        assertEq(cfg.entries[1].token, 0x322F0929c4625eD5bAd873c95208D54E1c003b2d, "TSLA token");
        assertEq(cfg.entries[1].aggregator, 0x4A1166a659A55625345e9515b32adECea5547C38, "TSLA feed");
        assertEq(cfg.entries[1].capAssets, 7_500e6, "TSLA cap");

        // With an AAPL pool supplied, AAPL joins at $25k; AMD never appears.
        address aaplPool = address(0xAA91);
        cfg = script.defaultRobinhoodConfig(address(0xB0B), new address[](0), aaplPool, false);
        assertEq(cfg.entries.length, 3, "AAPL included with a reference pool");
        assertEq(cfg.entries[2].token, 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9, "AAPL token");
        assertEq(cfg.entries[2].aggregator, 0x6B22A786bAa607d76728168703a39Ea9C99f2cD0, "AAPL feed");
        assertEq(cfg.entries[2].capAssets, 25_000e6, "AAPL cap");
        assertEq(cfg.entries[2].referencePool, aaplPool, "AAPL pool as supplied");
        address amd = 0x86923f96303D656E4aa86D9d42D1e57ad2023fdC;
        for (uint256 i; i < cfg.entries.length; ++i) {
            assertTrue(cfg.entries[i].token != amd, "AMD excluded (depth < $10k)");
        }
    }

    // ── Wiring order: setLaneAEnabled is LAST ──

    /// @dev THE ORDER IS THE GUARANTEE: everything before the switch is inert,
    ///      so a wiring interrupted anywhere leaves Lane A closed, never
    ///      half-armed. Log ordering is the only way to see it — the end state
    ///      is identical either way.
    function test_wiring_enableSwitchIsLast() public {
        SyndicateVault v2 = _newVault(DEFAULT_SENDER, address(usdc));
        PriceRouter fresh = _newRouter(DEFAULT_SENDER);

        vm.recordLogs();
        _deploy(_config(address(fresh), _vaults(address(v2)), true));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 firstEnable = type(uint256).max;
        uint256 lastOther;
        bytes32 tEnable = keccak256("LaneAEnabledSet(bytes32,bool)");
        bytes32 tAdapter = keccak256("AdapterRegistered(bytes32,address)");
        bytes32 tFeed = keccak256("FeedSet(address,address,uint256,uint256,address,uint256)");
        bytes32 tCap = keccak256("InstantCapSet(bytes32,uint256)");
        bytes32 tFee = keccak256("InstantExitFeeUpdated(uint16)");
        for (uint256 i; i < logs.length; ++i) {
            bytes32 t = logs[i].topics[0];
            if (t == tEnable && firstEnable == type(uint256).max) firstEnable = i;
            if (t == tAdapter || t == tFeed || t == tCap || t == tFee) lastOther = i;
        }
        assertTrue(firstEnable != type(uint256).max, "LaneAEnabledSet not emitted");
        assertLt(lastOther, firstEnable, "every adapter/feed/cap/fee write must precede the activation switch");
    }

    // ── Remaining pre-flight bites ──

    function test_preflight_bites_onNumeraireMismatch() public {
        ERC20Mock weird = new ERC20Mock("WEIRD", "WEIRD", 18);
        SyndicateVault mismatched = _newVault(DEFAULT_SENDER, address(weird));
        PriceRouter fresh = _newRouter(DEFAULT_SENDER);
        _deployExpecting(
            _config(address(fresh), _vaults(address(mismatched)), false), "PRE-FLIGHT: vault asset != adapter numeraire"
        );
    }

    function test_preflight_bites_onMissingReferencePool() public {
        PriceRouter fresh = _newRouter(DEFAULT_SENDER);
        DeployLaneA.Config memory cfg = _config(address(fresh), _vaults(address(vault)), false);
        cfg.entries[0].referencePool = address(0);
        cfg.entries[0].maxDivergenceBps = 0;
        _deployExpecting(cfg, "PRE-FLIGHT G4: entry without a divergence reference pool");
    }

    function test_preflight_bites_onDivergenceBoundAboveDesignPoint() public {
        PriceRouter fresh = _newRouter(DEFAULT_SENDER);
        DeployLaneA.Config memory cfg = _config(address(fresh), _vaults(address(vault)), false);
        cfg.entries[0].maxDivergenceBps = 150;
        _deployExpecting(cfg, "PRE-FLIGHT G4: divergence bound outside (0, 100] bps");
    }

    function test_preflight_bites_onStalenessAboveHeartbeat() public {
        PriceRouter fresh = _newRouter(DEFAULT_SENDER);
        DeployLaneA.Config memory cfg = _config(address(fresh), _vaults(address(vault)), false);
        cfg.entries[0].maxAge = 26 hours;
        _deployExpecting(cfg, "PRE-FLIGHT G3");
    }

    function test_preflight_bites_onLiveAdapterRerun() public {
        // The main fixture's router is already wired: a re-run must refuse
        // rather than silently swap the live adapters out.
        _deployExpecting(
            _config(address(router), _vaults(address(vault)), true), "PRE-FLIGHT: ERC20_SPOT adapter already registered"
        );
    }

    function test_preflight_bites_whenBroadcasterDoesNotOwnRouter() public {
        PriceRouter foreignRouter = _newRouter(makeAddr("someoneElse"));
        _deployExpecting(
            _config(address(foreignRouter), _vaults(address(vault)), false),
            "PRE-FLIGHT: broadcaster is not PriceRouter.owner"
        );
    }

    // ── Strategy-coverage cross-check helper ──

    function test_strategyCoverage_checksBasketAgainstRegistry() public {
        _depositExecuteLock();
        // Fully covered basket passes.
        script.checkStrategyCoverage(address(spotAdapter), address(strategy));

        // Delist a basket token: the check names the gap.
        vm.prank(DEFAULT_SENDER);
        spotAdapter.removeFeed(address(amzn));
        try script.checkStrategyCoverage(address(spotAdapter), address(strategy)) {
            revert("coverage check did not bite");
        } catch Error(string memory reason) {
            _assertPrefix(reason, "COVERAGE: basket token not in the spot adapter registry");
        }
    }
}
