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

/// @notice Audit 2026-10-01 V1-04 (CL), re-pinned by FP-02: the market's oracle is bound through the
///         allowlisted market id at init and again at execute, not as its own counterparty.
contract CLStrategy_v104OracleBindingTest is CLFixture {
    function _id(MarketParams memory params) internal pure returns (bytes32) {
        return keccak256(abi.encode(params));
    }

    /// @notice A market whose oracle differs from the allowlisted market's is a different id, refused at init.
    function test_init_otherOracleReverts() public {
        ConcentratedLiquidityStrategy.InitParams memory p = _defaultParams();
        p.marketParams.oracle = makeAddr("otherOracle");
        morpho.createMarket(p.marketParams);
        tierRegistry.setMarketDenied(_id(p.marketParams), true);
        ConcentratedLiquidityStrategy s = ConcentratedLiquidityStrategy(Clones.clone(address(template)));
        bytes memory data = abi.encode(p);
        address v = address(vaultStub);
        vm.expectRevert(
            abi.encodeWithSelector(
                ConcentratedLiquidityStrategy.MorphoMarketNotAllowed.selector,
                _id(p.marketParams),
                address(tierRegistry)
            )
        );
        s.initialize(v, proposer, data);
    }

    /// @notice Direction changed by FP-02: an oracle denied as a counterparty no longer refuses an allowlisted market.
    function test_init_oracleCounterpartyGrantNoLongerConsulted() public {
        tierRegistry.setDenied(address(oracle), true);
        ConcentratedLiquidityStrategy s = _newStrategy(_defaultParams());
        assertEq(s.marketParams().oracle, address(oracle));
    }

    /// @notice A market de-listed between init and execute blocks execute.
    function test_execute_revertsWhenMarketDemotedAfterInit() public {
        tierRegistry.setMarketDenied(_id(mp), true);
        vm.prank(address(vaultStub));
        vm.expectRevert(
            abi.encodeWithSelector(
                ConcentratedLiquidityStrategy.MorphoMarketNotAllowed.selector, _id(mp), address(tierRegistry)
            )
        );
        strategy.execute();
    }
}

/// @notice Audit 2026-10-01 V1-04 (supply), re-pinned by FP-02: the market (oracle and collateral
///         included) must be allowlisted by id at init and again at execute.
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
        registry.setMarketAllowed(_id(mp), true);
        vaultStub = new BindingVaultStub(address(usdg), address(new BindingGovernorStub(address(registry))));
        usdg.mint(address(vaultStub), SUPPLY);
        template = new MorphoSupplyStrategy();
    }

    function _id(MarketParams memory params) internal pure returns (bytes32) {
        return keccak256(abi.encode(params));
    }

    function _init(MarketParams memory params) internal returns (MorphoSupplyStrategy s) {
        s = MorphoSupplyStrategy(Clones.clone(address(template)));
        s.initialize(address(vaultStub), proposer, abi.encode(address(morpho), params, SUPPLY));
    }

    function _expectMarketRevert(MarketParams memory params) internal {
        MorphoSupplyStrategy s = MorphoSupplyStrategy(Clones.clone(address(template)));
        bytes memory data = abi.encode(address(morpho), params, SUPPLY);
        address v = address(vaultStub);
        vm.expectRevert(
            abi.encodeWithSelector(MorphoSupplyStrategy.MorphoMarketNotAllowed.selector, _id(params), address(registry))
        );
        s.initialize(v, proposer, data);
    }

    function _expectExecuteMarketRevert(MorphoSupplyStrategy s) internal {
        vm.prank(address(vaultStub));
        usdg.approve(address(s), SUPPLY);
        vm.prank(address(vaultStub));
        vm.expectRevert(
            abi.encodeWithSelector(MorphoSupplyStrategy.MorphoMarketNotAllowed.selector, _id(mp), address(registry))
        );
        s.execute();
    }

    /// @notice A market with another oracle is another id, refused at init.
    function test_init_otherOracleReverts() public {
        MarketParams memory other = mp;
        other.oracle = makeAddr("otherOracle");
        morpho.createMarket(other);
        _expectMarketRevert(other);
    }

    /// @notice A market with another collateral token is another id, refused at init.
    function test_init_otherCollateralReverts() public {
        MarketParams memory other = mp;
        other.collateralToken = makeAddr("otherCollateral");
        morpho.createMarket(other);
        _expectMarketRevert(other);
    }

    /// @notice Control: the allowlisted market initialises with no oracle or collateral grant of its own.
    function test_init_allowlistedMarketSucceeds() public {
        MorphoSupplyStrategy s = _init(mp);
        assertEq(s.marketParams().oracle, mp.oracle);
    }

    /// @notice Direction changed by FP-02: collateral equal to the vault asset is no longer exempt; the market needs its own grant.
    function test_init_collateralEqualToAssetNeedsMarketGrant() public {
        MarketParams memory same = mp;
        same.collateralToken = address(usdg);
        morpho.createMarket(same);
        _expectMarketRevert(same);
        registry.setMarketAllowed(_id(same), true);
        MorphoSupplyStrategy s = _init(same);
        assertEq(s.marketParams().collateralToken, address(usdg));
    }

    /// @notice A market de-listed between init and execute blocks execute; the vault is untouched.
    function test_execute_revertsWhenMarketDemotedAfterInit() public {
        MorphoSupplyStrategy s = _init(mp);
        registry.setMarketAllowed(_id(mp), false);
        _expectExecuteMarketRevert(s);
        assertEq(usdg.balanceOf(address(vaultStub)), SUPPLY, "nothing left the vault");
    }
}
