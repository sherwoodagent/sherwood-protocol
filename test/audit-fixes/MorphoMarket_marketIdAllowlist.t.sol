// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockMorpho, MockIrm, MockMorphoOracle} from "../mocks/MockMorpho.sol";
import {BindingGovernorStub, BindingVaultStub} from "../pashov-audit/MorphoSupplyStrategy_singletonBinding.t.sol";
import {CLFixture} from "../strategies/ConcentratedLiquidityStrategy.t.sol";
import {MorphoSupplyStrategy} from "../../src/strategies/MorphoSupplyStrategy.sol";
import {ConcentratedLiquidityStrategy} from "../../src/strategies/ConcentratedLiquidityStrategy.sol";
import {TierRegistry} from "../../src/TierRegistry.sol";
import {Id, MarketParams} from "../../src/vendor/morpho/IMorpho.sol";
import {MarketParamsLib} from "../../src/vendor/morpho/MorphoLibs.sol";

/// @notice A registry that answers `isCounterpartyAllowed` but predates `isMorphoMarketAllowed`.
contract CounterpartyOnlyRegistry {
    function isCounterpartyAllowed(address) external pure returns (bool) {
        return true;
    }
}

/// @notice Audit 2026-10-02 FP-02 (N-04): MorphoSupplyStrategy admits a market only by its allowlisted id.
contract MorphoSupply_marketIdAllowlistTest is Test {
    using MarketParamsLib for MarketParams;

    uint256 constant SUPPLY = 100_000e6;

    ERC20Mock usdg;
    ERC20Mock spUsdg;
    MockMorpho morpho;
    MockIrm irm;
    MockMorphoOracle oracle;
    TierRegistry registry;
    BindingGovernorStub governor;
    BindingVaultStub vaultStub;
    MorphoSupplyStrategy template;
    MarketParams canonical;

    address safe = makeAddr("safe");
    address proposer = makeAddr("proposer");

    function setUp() public {
        usdg = new ERC20Mock("USDG", "USDG", 6);
        spUsdg = new ERC20Mock("spUSDG", "spUSDG", 6);
        morpho = new MockMorpho();
        irm = new MockIrm();
        irm.setRate(0);
        oracle = new MockMorphoOracle();
        canonical = MarketParams(address(usdg), address(spUsdg), address(oracle), address(irm), 0.915e18);
        morpho.createMarket(canonical);

        registry = new TierRegistry(safe);
        vm.startPrank(safe);
        registry.setCounterpartyAllowed(address(morpho), true);
        // The old runbook's per-address grants: every part is individually acceptable.
        registry.setCounterpartyAllowed(address(oracle), true);
        registry.setCounterpartyAllowed(address(spUsdg), true);
        registry.setMorphoMarketAllowed(Id.unwrap(canonical.id()), true);
        vm.stopPrank();

        governor = new BindingGovernorStub(address(registry));
        vaultStub = new BindingVaultStub(address(usdg), address(governor));
        usdg.mint(address(vaultStub), SUPPLY);
        template = new MorphoSupplyStrategy();
    }

    function _clone(MarketParams memory mp) internal returns (MorphoSupplyStrategy s) {
        s = MorphoSupplyStrategy(Clones.clone(address(template)));
        s.initialize(address(vaultStub), proposer, abi.encode(address(morpho), mp, SUPPLY));
    }

    function _expectMarketRefused(MarketParams memory mp) internal {
        morpho.createMarket(mp);
        MorphoSupplyStrategy s = MorphoSupplyStrategy(Clones.clone(address(template)));
        bytes memory data = abi.encode(address(morpho), mp, SUPPLY);
        address v = address(vaultStub);
        vm.expectRevert(
            abi.encodeWithSelector(MorphoSupplyStrategy.MorphoMarketNotAllowed.selector, mp.id(), address(registry))
        );
        s.initialize(v, proposer, data);
    }

    function _execute(MorphoSupplyStrategy s) internal {
        vm.prank(address(vaultStub));
        usdg.approve(address(s), SUPPLY);
        vm.prank(address(vaultStub));
        s.execute();
    }

    /// @notice A correctly paired market with irm == 0, built from allowlisted parts, is refused at init.
    function test_init_zeroIrmMarketRefused() public {
        _expectMarketRefused(MarketParams(address(usdg), address(spUsdg), address(oracle), address(0), 0.915e18));
    }

    /// @notice A loan == collateral market priced by the allowlisted oracle is refused at init.
    function test_init_loanEqualsCollateralMarketRefused() public {
        _expectMarketRefused(MarketParams(address(usdg), address(usdg), address(oracle), address(irm), 0.98e18));
    }

    /// @notice The canonical parts at a non-canonical LLTV form a different market, refused at init.
    function test_init_nonCanonicalLltvMarketRefused() public {
        _expectMarketRefused(MarketParams(address(usdg), address(spUsdg), address(oracle), address(irm), 0.98e18));
    }

    /// @notice A registry that cannot answer `isMorphoMarketAllowed` fails closed.
    function test_init_failsClosedWhenRegistryCannotAnswer() public {
        CounterpartyOnlyRegistry old = new CounterpartyOnlyRegistry();
        governor.setTierRegistry(address(old));
        MorphoSupplyStrategy s = MorphoSupplyStrategy(Clones.clone(address(template)));
        bytes memory data = abi.encode(address(morpho), canonical, SUPPLY);
        address v = address(vaultStub);
        vm.expectRevert(
            abi.encodeWithSelector(MorphoSupplyStrategy.MorphoMarketNotAllowed.selector, canonical.id(), address(old))
        );
        s.initialize(v, proposer, data);
    }

    /// @notice Control: the allowlisted market initialises and executes.
    function test_init_allowlistedMarketPasses() public {
        MorphoSupplyStrategy s = _clone(canonical);
        assertEq(Id.unwrap(s.marketId()), Id.unwrap(canonical.id()));
        _execute(s);
        assertEq(morpho.market(canonical.id()).totalSupplyAssets, SUPPLY);
    }

    /// @notice The per-address grants for oracle and collateral no longer admit or refuse a market.
    function test_init_partGrantsAreNotWhatAdmitsTheMarket() public {
        vm.startPrank(safe);
        registry.setCounterpartyAllowed(address(oracle), false);
        registry.setCounterpartyAllowed(address(spUsdg), false);
        vm.stopPrank();
        MorphoSupplyStrategy s = _clone(canonical);
        assertEq(Id.unwrap(s.marketId()), Id.unwrap(canonical.id()));
    }

    /// @notice A market de-listed after init blocks execute; nothing leaves the vault.
    function test_execute_revertsWhenMarketDelistedAfterInit() public {
        MorphoSupplyStrategy s = _clone(canonical);
        vm.prank(safe);
        registry.setMorphoMarketAllowed(Id.unwrap(canonical.id()), false);
        vm.prank(address(vaultStub));
        usdg.approve(address(s), SUPPLY);
        vm.prank(address(vaultStub));
        vm.expectRevert(
            abi.encodeWithSelector(
                MorphoSupplyStrategy.MorphoMarketNotAllowed.selector, canonical.id(), address(registry)
            )
        );
        s.execute();
        assertEq(usdg.balanceOf(address(vaultStub)), SUPPLY, "nothing left the vault");
    }

    /// @notice De-listing the market (and Morpho) after execute does not block settle.
    function test_settle_notBlockedByMarketDelisting() public {
        MorphoSupplyStrategy s = _clone(canonical);
        _execute(s);
        vm.startPrank(safe);
        registry.setMorphoMarketAllowed(Id.unwrap(canonical.id()), false);
        registry.setCounterpartyAllowed(address(morpho), false);
        vm.stopPrank();
        vm.prank(address(vaultStub));
        s.settle();
        assertEq(usdg.balanceOf(address(vaultStub)), SUPPLY, "settle returned the supply");
    }

    /// @notice The registry setter is owner-only.
    function test_setMorphoMarketAllowed_onlyOwner() public {
        vm.expectRevert();
        registry.setMorphoMarketAllowed(bytes32(uint256(1)), true);
        assertFalse(registry.isMorphoMarketAllowed(bytes32(uint256(1))));
    }
}

/// @notice Audit 2026-10-02 FP-02: the CL strategy's Morpho leg admits a market only by its allowlisted id.
contract CLStrategy_marketIdAllowlistTest is CLFixture {
    using MarketParamsLib for MarketParams;

    function _expectMarketRefused(ConcentratedLiquidityStrategy.InitParams memory p) internal {
        ConcentratedLiquidityStrategy s = ConcentratedLiquidityStrategy(Clones.clone(address(template)));
        bytes memory data = abi.encode(p);
        address v = address(vaultStub);
        vm.expectRevert(
            abi.encodeWithSelector(
                ConcentratedLiquidityStrategy.MorphoMarketNotAllowed.selector,
                p.marketParams.id(),
                address(tierRegistry)
            )
        );
        s.initialize(v, proposer, data);
    }

    /// @notice A market whose id is not allowlisted is refused at init, though every part is allowed.
    function test_init_marketNotAllowedReverts() public {
        tierRegistry.setMarketDenied(Id.unwrap(mp.id()), true);
        _expectMarketRefused(_defaultParams());
    }

    /// @notice A market de-listed after init blocks execute.
    function test_execute_revertsWhenMarketDelistedAfterInit() public {
        tierRegistry.setMarketDenied(Id.unwrap(mp.id()), true);
        vm.prank(address(vaultStub));
        vm.expectRevert(
            abi.encodeWithSelector(
                ConcentratedLiquidityStrategy.MorphoMarketNotAllowed.selector, mp.id(), address(tierRegistry)
            )
        );
        strategy.execute();
    }

    /// @notice De-listing the market after execute does not block settle.
    function test_settle_notBlockedByMarketDelisting() public {
        _execute();
        tierRegistry.setMarketDenied(Id.unwrap(mp.id()), true);
        _settle();
        assertFalse(strategy.executed(), "settled");
    }

    /// @notice A market de-listed after execute blocks rerange; settle still succeeds.
    function test_rerange_revertsWhenMarketDelisted_settleStillSucceeds() public {
        _execute();
        tierRegistry.setMarketDenied(Id.unwrap(mp.id()), true);
        pool.setTicks(850, 850);
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                ConcentratedLiquidityStrategy.MorphoMarketNotAllowed.selector, mp.id(), address(tierRegistry)
            )
        );
        strategy.rerange();
        _settle();
        assertFalse(strategy.executed(), "settled");
    }

    /// @notice A registry without `isMorphoMarketAllowed` fails closed at CL init.
    function test_init_failsClosedWhenRegistryCannotAnswer() public {
        CounterpartyOnlyRegistry old = new CounterpartyOnlyRegistry();
        status.setTierRegistry(address(old));
        ConcentratedLiquidityStrategy s = ConcentratedLiquidityStrategy(Clones.clone(address(template)));
        bytes memory data = abi.encode(_defaultParams());
        address v = address(vaultStub);
        vm.expectRevert(
            abi.encodeWithSelector(ConcentratedLiquidityStrategy.MorphoMarketNotAllowed.selector, mp.id(), address(old))
        );
        s.initialize(v, proposer, data);
    }
}

/// @notice FP-02 review: the CL Morpho leg against a real, default-deny TierRegistry.
contract CLStrategy_marketIdRealRegistryTest is CLFixture {
    using MarketParamsLib for MarketParams;

    TierRegistry realRegistry;

    function setUp() public override {
        super.setUp();
        realRegistry = new TierRegistry(address(this));
        realRegistry.setCounterpartyAllowed(address(adapter), true);
        realRegistry.setCounterpartyAllowed(address(posm), true);
        realRegistry.setCounterpartyAllowed(address(morpho), true);
        realRegistry.setCounterpartyAllowed(factory, true);
        realRegistry.setCounterpartyAllowed(address(nvda), true);
        // The old per-address grants: every part of the market is individually acceptable.
        realRegistry.setCounterpartyAllowed(address(oracle), true);
        realRegistry.setCounterpartyAllowed(address(spUsdg), true);
        status.setTierRegistry(address(realRegistry));
    }

    function _expectRefused(MarketParams memory m) internal {
        ConcentratedLiquidityStrategy.InitParams memory p = _defaultParams();
        p.marketParams = m;
        ConcentratedLiquidityStrategy s = ConcentratedLiquidityStrategy(Clones.clone(address(template)));
        bytes memory data = abi.encode(p);
        address v = address(vaultStub);
        vm.expectRevert(
            abi.encodeWithSelector(
                ConcentratedLiquidityStrategy.MorphoMarketNotAllowed.selector, m.id(), address(realRegistry)
            )
        );
        s.initialize(v, proposer, data);
    }

    /// @notice The canonical market, never allowlisted, is refused at init.
    function test_init_unlistedMarketRefused() public {
        _expectRefused(mp);
    }

    /// @notice Acceptable parts with another irm form another id, refused though the canonical id is allowlisted.
    function test_init_nonCanonicalIrmRefused() public {
        realRegistry.setMorphoMarketAllowed(Id.unwrap(mp.id()), true);
        MarketParams memory m = mp;
        m.irm = address(new MockIrm());
        morpho.createMarket(m);
        _fundMarket(m);
        _expectRefused(m);
    }

    /// @notice Acceptable parts at another lltv form another id, refused though the canonical id is allowlisted.
    function test_init_nonCanonicalLltvRefused() public {
        realRegistry.setMorphoMarketAllowed(Id.unwrap(mp.id()), true);
        MarketParams memory m = mp;
        m.lltv = 0.86e18;
        morpho.createMarket(m);
        _fundMarket(m);
        _expectRefused(m);
    }

    /// @notice The same clone initialises once that exact id is allowlisted.
    function test_init_allowlistedMarketInitialises() public {
        _expectRefused(mp);
        realRegistry.setMorphoMarketAllowed(Id.unwrap(mp.id()), true);
        ConcentratedLiquidityStrategy s = _newStrategy(_defaultParams());
        assertEq(Id.unwrap(s.marketId()), Id.unwrap(mp.id()));
    }
}
