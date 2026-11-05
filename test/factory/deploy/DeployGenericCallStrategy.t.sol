// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {DeployGenericCallTemplate} from "../../../script/robinhood-mainnet/DeployGenericCallStrategy.s.sol";
import {BatchExecutorLib} from "../../../src/BatchExecutorLib.sol";
import {BaseStrategy} from "../../../src/strategies/BaseStrategy.sol";
import {GenericCallStrategy} from "../../../src/strategies/GenericCallStrategy.sol";
import {ERC20Mock} from "../../mocks/ERC20Mock.sol";
import {GCRegistryStub, GCGovernorStub, GCVaultStub} from "../../mocks/GenericCallMocks.sol";

/// @title DeployGenericCallStrategy — the template deploy step
/// @dev   The strategy's behaviour is covered under `test/strategies/GenericCallStrategy*.t.sol`;
///        this suite pins that the phase yields a locked, clonable template.
contract DeployGenericCallStrategyTest is Test {
    DeployGenericCallTemplate internal script;
    GCVaultStub internal vault;

    function setUp() public {
        script = new DeployGenericCallTemplate();
        GCRegistryStub registry = new GCRegistryStub();
        registry.setStrategyFactory(makeAddr("strategyFactory"));
        GCGovernorStub gov = new GCGovernorStub(address(registry));
        vault = new GCVaultStub(address(new ERC20Mock("USDG", "USDG", 6)), address(gov), makeAddr("factory"));
    }

    /// @dev The phase calls `c3.deploy` as the script, so the broadcaster stand-in is the script.
    function _deploy() internal returns (GenericCallStrategy) {
        vm.prank(address(script));
        return script.deployGenericCallTemplate();
    }

    function _emptyPlan() internal pure returns (bytes memory) {
        return abi.encode(uint256(0), new BatchExecutorLib.Call[](0), new BatchExecutorLib.Call[](0), new address[](0));
    }

    /// @notice The template itself can never be initialized: only its clones can.
    function test_deploy_templateIsLocked() public {
        GenericCallStrategy template = _deploy();
        assertEq(template.name(), "Generic Call");
        assertEq(template.vault(), address(0), "a template binds no vault");
        bytes memory plan = _emptyPlan();
        vm.expectRevert(BaseStrategy.AlreadyInitialized.selector);
        template.initialize(address(vault), address(this), plan);
    }

    /// @notice A clone of the deployed template initializes against a vault.
    function test_deploy_templateIsClonable() public {
        GenericCallStrategy template = _deploy();
        GenericCallStrategy clone = GenericCallStrategy(Clones.clone(address(template)));
        clone.initialize(address(vault), address(this), _emptyPlan());
        assertEq(clone.vault(), address(vault));
        assertEq(clone.asset(), vault.asset());
    }

    /// @notice A second run adopts the template already minted at the salt's address.
    function test_deploy_isIdempotent() public {
        assertEq(address(_deploy()), address(_deploy()));
    }
}
