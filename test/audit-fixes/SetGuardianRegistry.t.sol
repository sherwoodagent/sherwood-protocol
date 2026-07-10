// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SyndicateGovernor} from "../../src/SyndicateGovernor.sol";
import {SyndicateFactory} from "../../src/SyndicateFactory.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {MinimalGuardianRegistry} from "../../src/MinimalGuardianRegistry.sol";
import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";
import {ProtocolConfig} from "../../src/ProtocolConfig.sol";

/// @title SetGuardianRegistry — owner-only registry repointing
/// @notice Lets the protocol upgrade from the beta `MinimalGuardianRegistry`
///         to the real `GuardianRegistry` once WOOD is live without redeploying
///         the governor + factory proxies.
contract SetGuardianRegistryTest is Test {
    SyndicateGovernor governor;
    SyndicateFactory factory;
    MinimalGuardianRegistry initialRegistry;
    MinimalGuardianRegistry replacementRegistry;

    address owner = makeAddr("owner");
    address attacker = makeAddr("attacker");

    function setUp() public {
        initialRegistry = new MinimalGuardianRegistry();
        replacementRegistry = new MinimalGuardianRegistry();

        // Governor proxy
        SyndicateGovernor govImpl = new SyndicateGovernor();
        bytes memory govInit = abi.encodeCall(
            SyndicateGovernor.initialize,
            (
                address(0), // vault_: bootstrap (factory auto-deploys per-vault governors)
                address(initialRegistry),
                address(new ProtocolConfig(owner)),
                address(this), // factory (test contract)
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
                    guardianRegistry: address(initialRegistry)
                }))
        );
        factory = SyndicateFactory(address(new ERC1967Proxy(address(factoryImpl), factoryInit)));

        // governor.setFactory removed in per-vault design — factory set at initialize time
    }

    /// @notice PR #351 review #1: `governor.setGuardianRegistry` was REMOVED.
    ///         Repointing mid-proposal silently auto-Approved any blocked
    ///         review (the new registry's `!r.opened` branch in
    ///         `resolveReview` returned `blocked=false`, discarding every
    ///         Block vote AND the approver slash). Same hazard class as V-H2
    ///         (which removed the factory's `setGovernor`). The legitimate
    ///         beta-stub → real-registry migration path is a governor UUPS
    ///         upgrade that writes the new address in its initializer, not a
    ///         setter. The factory's `setGuardianRegistry` is preserved (it
    ///         only gates new vault creation + `rotateOwner`, not in-flight
    ///         reviews, and Sherlock #28 added a factory-alignment check).
    function test_governor_setGuardianRegistry_doesNotExist() public {
        // The governor proxy has no `setGuardianRegistry(address)` selector.
        bytes memory data = abi.encodeWithSignature("setGuardianRegistry(address)", address(replacementRegistry));
        vm.prank(owner);
        (bool ok,) = address(governor).call(data);
        assertFalse(ok, "setGuardianRegistry MUST be absent (PR #351 review #1)");
        assertEq(governor.guardianRegistry(), address(initialRegistry), "registry slot unchanged");
    }

    function test_factory_setGuardianRegistry_succeedsForOwner() public {
        assertEq(factory.guardianRegistry(), address(initialRegistry));
        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit SyndicateFactory.GuardianRegistrySet(address(initialRegistry), address(replacementRegistry));
        factory.setGuardianRegistry(address(replacementRegistry));
        assertEq(factory.guardianRegistry(), address(replacementRegistry));
    }

    function test_factory_setGuardianRegistry_revertsForAttacker() public {
        vm.prank(attacker);
        vm.expectRevert();
        factory.setGuardianRegistry(address(replacementRegistry));
    }

    function test_factory_setGuardianRegistry_revertsOnZero() public {
        vm.prank(owner);
        vm.expectRevert(SyndicateFactory.InvalidGuardianRegistry.selector);
        factory.setGuardianRegistry(address(0));
    }

    /// @notice Sherlock run #1 finding #28 — new registry whose `factory()`
    ///         returns a different address (misconfig) reverts at swap time
    ///         instead of bricking subsequent bindOwnerStake calls.
    function test_factory_setGuardianRegistry_revertsOnFactoryMismatch() public {
        // Deploy a contract that pretends to be a registry but reports a
        // different factory address.
        _BadRegistry bad = new _BadRegistry();
        vm.prank(owner);
        vm.expectRevert(SyndicateFactory.RegistryFactoryMismatch.selector);
        factory.setGuardianRegistry(address(bad));
    }
}

contract _BadRegistry {
    function factory() external pure returns (address) {
        return address(0xBAD); // not the test factory
    }
}
