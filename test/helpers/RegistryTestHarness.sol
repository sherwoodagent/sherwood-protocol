// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {GuardianRegistry} from "../../src/GuardianRegistry.sol";
import {StakedWood} from "../../src/StakedWood.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockGovernorMinimal} from "../mocks/MockGovernorMinimal.sol";

/// @notice Shared test harness for the post-split `GuardianRegistry` +
///         `StakedWood` (sWOOD) pair. After the sWOOD staking split the
///         registry holds zero WOOD and reads vote weight from sWOOD. Review /
///         emergency / reward tests must therefore deploy BOTH contracts and
///         wire them: the registry is `initialize`d with the sWOOD address and
///         sWOOD's set-once `setRegistry` is pointed back at the registry.
///
///         Guardians stake through `swood.stakeAsGuardian`, not the registry.
///         `_stakeGuardian` is the canonical helper review tests use to build
///         a cohort.
abstract contract RegistryTestHarness is Test {
    GuardianRegistry internal registry;
    StakedWood internal swood;
    ERC20Mock internal wood;
    MockGovernorMinimal internal governor;

    address internal regOwner = address(0xA11CE);
    address internal regFactory = address(0xFAC10);

    /// @dev Deploys WOOD, a governor mock, sWOOD, and the registry, then wires
    ///      sWOOD ↔ registry. Call from a test's `setUp`.
    function _deployRegistryAndSwood(uint256 reviewPeriod, uint256 blockQuorumBps) internal {
        wood = new ERC20Mock("WOOD", "WOOD", 18);
        governor = new MockGovernorMinimal();

        // sWOOD first — the registry's `initialize` takes the sWOOD address.
        StakedWood swoodImpl = new StakedWood();
        bytes memory swoodInit = abi.encodeCall(
            StakedWood.initialize,
            (StakedWood.InitParams({
                    owner: regOwner,
                    wood: address(wood),
                    factory: regFactory,
                    minGuardianStake: 10_000e18,
                    coolDownPeriod: 7 days,
                    minOwnerStake: 10_000e18,
                    minSlashBps: 1000,
                    maxSlashBps: 9999,
                    maxDelegatedSlashBps: 2000,
                    ageFloorBps: 2500,
                    maturationPeriod: 30 days,
                    delegatedWeightCapX: 4
                }))
        );
        swood = StakedWood(address(new ERC1967Proxy(address(swoodImpl), swoodInit)));

        GuardianRegistry regImpl = new GuardianRegistry(6 hours);
        bytes memory regInit = abi.encodeCall(
            GuardianRegistry.initialize, (regOwner, regFactory, address(swood), reviewPeriod, blockQuorumBps)
        );
        registry = GuardianRegistry(address(new ERC1967Proxy(address(regImpl), regInit)));

        // Resolve the registry ↔ sWOOD circular dependency.
        vm.prank(regOwner);
        swood.setRegistry(address(registry));

        // Authorize the mock governor on the composite-key registry (the factory
        // does this in production via createSyndicate).
        vm.prank(regFactory);
        registry.addGovernor(address(governor));
    }

    /// @dev Mints WOOD to `g`, approves sWOOD, and stakes `amount` as a
    ///      guardian. Guardian is active afterwards.
    function _stakeGuardian(address g, uint256 amount, uint256 agentId) internal {
        wood.mint(g, amount);
        vm.startPrank(g);
        wood.approve(address(swood), type(uint256).max);
        swood.stakeAsGuardian(amount, agentId);
        vm.stopPrank();
    }

    /// @dev Owner-enables DPoS delegation on sWOOD. `delegationEnabled` defaults
    ///      false at deploy; tests that exercise `delegateStake` must flip it.
    function _enableDelegation() internal {
        vm.prank(regOwner);
        swood.setDelegationEnabled(true);
    }

    /// @dev Mints WOOD to `delegator`, approves sWOOD, and delegates `amount`
    ///      to `delegate`. Requires `_enableDelegation` to have been called.
    function _delegate(address delegator, address delegate, uint256 amount) internal {
        wood.mint(delegator, amount);
        vm.startPrank(delegator);
        wood.approve(address(swood), type(uint256).max);
        swood.delegateStake(delegate, amount);
        vm.stopPrank();
    }
}
