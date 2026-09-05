// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SyndicateGovernor} from "../../src/SyndicateGovernor.sol";
import {SyndicateFactory} from "../../src/SyndicateFactory.sol";
import {TierRegistry} from "../../src/TierRegistry.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {MockRegistryMinimal} from "../mocks/MockRegistryMinimal.sol";
import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";
import {ProtocolConfig} from "../../src/ProtocolConfig.sol";
import {deployTierRegistry} from "../helpers/TierRegistryFixture.sol";

/// @title SetGuardianRegistry — the guardian registry pointer is not settable
/// @notice Both the governor and the factory bind their registry at
///         `initialize` and expose no setter for it.
contract SetGuardianRegistryTest is Test {
    SyndicateGovernor governor;
    SyndicateFactory factory;
    MockRegistryMinimal initialRegistry;
    MockRegistryMinimal replacementRegistry;

    address owner = makeAddr("owner");

    function setUp() public {
        initialRegistry = new MockRegistryMinimal();
        replacementRegistry = new MockRegistryMinimal();

        // Governor proxy
        SyndicateGovernor govImpl = new SyndicateGovernor(24 hours, 1 hours);
        bytes memory govInit = abi.encodeCall(
            SyndicateGovernor.initialize,
            (
                address(0), // vault_: bootstrap (factory auto-deploys per-vault governors)
                address(initialRegistry),
                address(new ProtocolConfig(owner)),
                address(this),
                address(deployTierRegistry(address(this))), // factory (test contract)
                ISyndicateGovernor.GovernorParams({
                    votingPeriod: 24 hours,
                    executionWindow: 1 days,
                    vetoThresholdBps: 4000,
                    maxPerformanceFeeBps: 1000,
                    cooldownPeriod: 1 hours,
                    collaborationWindow: 24 hours,
                    maxCoProposers: 5,
                    minStrategyDuration: 1 hours,
                    maxStrategyDuration: 14 days
                })
            )
        );
        governor = SyndicateGovernor(address(new ERC1967Proxy(address(govImpl), govInit)));
        // Per-vault governor: the vault resolves its governor via its factory
        // (this test contract). Mock governorOf(vault) -> the deployed governor.
        vm.mockCall(address(this), abi.encodeWithSignature("governorOf(address)"), abi.encode(address(governor)));

        // Factory proxy (wired with governor + initial registry)
        BatchExecutorLib executorLib = new BatchExecutorLib();
        SyndicateVault vaultImpl = new SyndicateVault();
        SyndicateFactory factoryImpl = new SyndicateFactory();
        bytes memory factoryInit = abi.encodeCall(
            SyndicateFactory.initialize,
            (SyndicateFactory.InitParams({
                    owner: owner,
                    executorImpl: address(executorLib),
                    vaultImpl: address(vaultImpl),
                    ensRegistrar: address(0),
                    agentRegistry: address(0),
                    beacon: address(governor),
                    protocolConfig: address(governor),
                    managementFeeBps: 0,
                    guardianRegistry: address(initialRegistry),
                    // Mandatory since pashov finding #1.
                    tierRegistry: address(new TierRegistry(owner))
                }))
        );
        factory = SyndicateFactory(address(new ERC1967Proxy(address(factoryImpl), factoryInit)));

        // governor.setFactory removed in per-vault design — factory set at initialize time
    }

    /// @notice Neither proxy exposes `setGuardianRegistry(address)`: the
    ///         pointer each one binds at `initialize` is the pointer it keeps.
    function test_setGuardianRegistry_isAbsentFromGovernorAndFactory() public {
        bytes memory data = abi.encodeWithSignature("setGuardianRegistry(address)", address(replacementRegistry));

        vm.prank(owner);
        (bool govOk,) = address(governor).call(data);
        assertFalse(govOk, "governor must expose no registry setter");
        assertEq(governor.guardianRegistry(), address(initialRegistry), "governor registry slot moved");

        vm.prank(owner);
        (bool factoryOk,) = address(factory).call(data);
        assertFalse(factoryOk, "factory must expose no registry setter");
        assertEq(factory.guardianRegistry(), address(initialRegistry), "factory registry slot moved");
    }
}
