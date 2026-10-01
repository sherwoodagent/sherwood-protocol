// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {CLFixture} from "../strategies/ConcentratedLiquidityStrategy.t.sol";
import {
    BindingTierRegistry,
    BindingGovernorStub,
    BindingVaultStub
} from "../pashov-audit/MorphoSupplyStrategy_singletonBinding.t.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockMorpho, MockIrm} from "../mocks/MockMorpho.sol";
import {ConcentratedLiquidityStrategy} from "../../src/strategies/ConcentratedLiquidityStrategy.sol";
import {MorphoSupplyStrategy} from "../../src/strategies/MorphoSupplyStrategy.sol";
import {MarketParams} from "../../src/vendor/morpho/IMorpho.sol";

/// @notice Audit 2026-10-01 V1-04 (CL): the Morpho market's oracle must be an allowed counterparty
///         at init and again at execute.
contract CLStrategy_v104OracleBindingTest is CLFixture {
    function _expectCounterpartyRevert(address counterparty) internal {
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

    /// @notice A market whose oracle is not allowlisted is refused at init.
    function test_init_oracleNotAllowedReverts() public {
        tierRegistry.setDenied(address(oracle), true);
        _expectCounterpartyRevert(address(oracle));
    }

    /// @notice Control: the same market with its oracle allowlisted initialises.
    function test_init_oracleAllowedSucceeds() public {
        ConcentratedLiquidityStrategy s = _newStrategy(_defaultParams());
        assertEq(s.marketParams().oracle, address(oracle));
    }

    /// @notice An oracle demoted between init and execute blocks execute.
    function test_execute_revertsWhenOracleDemotedAfterInit() public {
        tierRegistry.setDenied(address(oracle), true);
        vm.prank(address(vaultStub));
        vm.expectRevert(
            abi.encodeWithSelector(
                ConcentratedLiquidityStrategy.CounterpartyNotAllowed.selector, address(oracle), address(tierRegistry)
            )
        );
        strategy.execute();
    }
}

/// @notice Audit 2026-10-01 V1-04 (supply): the market's oracle, and its collateral token unless it
///         is the vault asset, must be allowed counterparties at init and again at execute.
contract MorphoSupplyStrategy_v104OracleBindingTest is Test {
    uint256 constant SUPPLY = 100_000e6;

    ERC20Mock usdg;
    MockMorpho morpho;
    MarketParams mp;
    BindingTierRegistry registry;
    BindingVaultStub vaultStub;
    MorphoSupplyStrategy template;
    address proposer = makeAddr("proposer");

    function setUp() public {
        usdg = new ERC20Mock("USDG", "USDG", 6);
        MockIrm irm = new MockIrm();
        irm.setRate(0);
        morpho = new MockMorpho();
        mp = MarketParams({
            loanToken: address(usdg),
            collateralToken: makeAddr("collateral"),
            oracle: makeAddr("oracle"),
            irm: address(irm),
            lltv: 0.86e18
        });
        morpho.createMarket(mp);

        registry = new BindingTierRegistry();
        registry.setAllowed(address(morpho), true);
        registry.setAllowed(mp.oracle, true);
        registry.setAllowed(mp.collateralToken, true);
        vaultStub = new BindingVaultStub(address(usdg), address(new BindingGovernorStub(address(registry))));
        usdg.mint(address(vaultStub), SUPPLY);
        template = new MorphoSupplyStrategy();
    }

    function _init(MarketParams memory params) internal returns (MorphoSupplyStrategy s) {
        s = MorphoSupplyStrategy(Clones.clone(address(template)));
        s.initialize(address(vaultStub), proposer, abi.encode(address(morpho), params, SUPPLY));
    }

    function _expectCounterpartyRevert(MarketParams memory params, address counterparty) internal {
        MorphoSupplyStrategy s = MorphoSupplyStrategy(Clones.clone(address(template)));
        bytes memory data = abi.encode(address(morpho), params, SUPPLY);
        address v = address(vaultStub);
        vm.expectRevert(
            abi.encodeWithSelector(
                MorphoSupplyStrategy.CounterpartyNotAllowed.selector, counterparty, address(registry)
            )
        );
        s.initialize(v, proposer, data);
    }

    /// @notice A market whose oracle is not allowlisted is refused at init.
    function test_init_oracleNotAllowedReverts() public {
        registry.setAllowed(mp.oracle, false);
        _expectCounterpartyRevert(mp, mp.oracle);
    }

    /// @notice A market whose collateral token is not allowlisted is refused at init.
    function test_init_collateralNotAllowedReverts() public {
        registry.setAllowed(mp.collateralToken, false);
        _expectCounterpartyRevert(mp, mp.collateralToken);
    }

    /// @notice Control: oracle and collateral allowlisted, the clone initialises.
    function test_init_oracleAndCollateralAllowedSucceeds() public {
        MorphoSupplyStrategy s = _init(mp);
        assertEq(s.marketParams().oracle, mp.oracle);
    }

    /// @notice Collateral equal to the vault asset needs no grant of its own.
    function test_init_collateralEqualToAssetNeedsNoGrant() public {
        MarketParams memory same = mp;
        same.collateralToken = address(usdg);
        morpho.createMarket(same);
        MorphoSupplyStrategy s = _init(same);
        assertEq(s.marketParams().collateralToken, address(usdg));
    }

    /// @notice An oracle demoted between init and execute blocks execute; the vault is untouched.
    function test_execute_revertsWhenOracleDemotedAfterInit() public {
        MorphoSupplyStrategy s = _init(mp);
        registry.setAllowed(mp.oracle, false);
        vm.prank(address(vaultStub));
        usdg.approve(address(s), SUPPLY);
        vm.prank(address(vaultStub));
        vm.expectRevert(
            abi.encodeWithSelector(MorphoSupplyStrategy.CounterpartyNotAllowed.selector, mp.oracle, address(registry))
        );
        s.execute();
        assertEq(usdg.balanceOf(address(vaultStub)), SUPPLY, "nothing left the vault");
    }

    /// @notice A collateral token demoted between init and execute blocks execute.
    function test_execute_revertsWhenCollateralDemotedAfterInit() public {
        MorphoSupplyStrategy s = _init(mp);
        registry.setAllowed(mp.collateralToken, false);
        vm.prank(address(vaultStub));
        usdg.approve(address(s), SUPPLY);
        vm.prank(address(vaultStub));
        vm.expectRevert(
            abi.encodeWithSelector(
                MorphoSupplyStrategy.CounterpartyNotAllowed.selector, mp.collateralToken, address(registry)
            )
        );
        s.execute();
    }
}
