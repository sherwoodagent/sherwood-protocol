// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SyndicateGovernor} from "../../src/SyndicateGovernor.sol";
import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockRegistryMinimal} from "../mocks/MockRegistryMinimal.sol";
import {ProtocolConfig} from "../../src/ProtocolConfig.sol";
import {deployTierRegistry} from "../helpers/TierRegistryFixture.sol";

/// @notice pashov finding #1, governor half: the tier registry is a MANDATORY
///         `initialize` argument, so a governor cannot exist unwired even for a
///         single block.
///
///         The factory half (`SyndicateFactory.InitParams.tierRegistry`, the
///         `createSyndicate` pre-flight, and the `createSyndicate` → governor
///         hand-off) is pinned in `test/SyndicateFactory.t.sol`; the runtime
///         half (`SyndicateVault._guardBatchCalls` refusing a batch when it
///         resolves no registry) is pinned in `test/vault/CalleeGate.t.sol` and
///         `test/vault/SelectorGuard.t.sol`. This file covers only the seam
///         those two lean on: that init itself cannot be handed a non-registry.
contract Governor_tierRegistryMandatoryAtInitTest is Test {
    MockRegistryMinimal guardianRegistry;
    SyndicateGovernor impl;
    address protocolConfig;

    address owner = makeAddr("owner");
    address vaultSentinel = makeAddr("vault");

    function setUp() public {
        guardianRegistry = new MockRegistryMinimal();
        impl = new SyndicateGovernor(24 hours, 1 hours);
        protocolConfig = address(new ProtocolConfig(owner));
    }

    function _initData(address tierRegistry) internal view returns (bytes memory) {
        return abi.encodeCall(
            SyndicateGovernor.initialize,
            (
                vaultSentinel,
                address(guardianRegistry),
                protocolConfig,
                address(this),
                tierRegistry,
                ISyndicateGovernor.GovernorParams({
                    votingPeriod: 1 days,
                    executionWindow: 2 days,
                    vetoThresholdBps: 4000,
                    maxPerformanceFeeBps: 1500,
                    cooldownPeriod: 1 days,
                    collaborationWindow: 48 hours,
                    maxCoProposers: 5,
                    minStrategyDuration: 1 hours,
                    maxStrategyDuration: 30 days
                })
            )
        );
    }

    /// @dev Zero and codeless are refused for DIFFERENT reasons, so both are
    ///      pinned. Zero leaves `_guardBatchCalls` unable to resolve an
    ///      allowlist at all — the finding. A codeless address passes every
    ///      zero-check and then reverts the guard's typed `isCallableTarget`
    ///      call in the VAULT's frame with empty returndata, bricking every
    ///      batch instead of merely un-gating them.
    ///
    ///      HOISTED: `_initData` is a view call, and in argument position it
    ///      would be evaluated before the create and eat the one-shot
    ///      `vm.expectRevert`, leaving the create unarmed.
    function test_initialize_refusesZeroAndCodelessTierRegistry() public {
        bytes memory initZero = _initData(address(0));
        bytes memory initEoa = _initData(makeAddr("eoaRegistry"));

        vm.expectRevert(ISyndicateGovernor.TierRegistryNotWired.selector);
        new ERC1967Proxy(address(impl), initZero);

        vm.expectRevert(ISyndicateGovernor.TierRegistryNotWired.selector);
        new ERC1967Proxy(address(impl), initEoa);
    }

    /// @dev The positive case, and the one that makes the guarantee structural
    ///      rather than merely enforced: the registry is readable through
    ///      `tierRegistry()` the instant `initialize` returns, with no
    ///      follow-up `setTierRegistry` call in between. That closes the window
    ///      the old two-step wiring left open.
    function test_initialize_wiresTheRegistryBeforeReturning() public {
        address reg = address(deployTierRegistry(address(this)));
        SyndicateGovernor gov = SyndicateGovernor(address(new ERC1967Proxy(address(impl), _initData(reg))));
        assertEq(gov.tierRegistry(), reg, "registry readable with no post-init wiring step");
    }
}
