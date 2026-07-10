// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SyndicateGovernor} from "../src/SyndicateGovernor.sol";
import {GovernorParameters} from "../src/GovernorParameters.sol";
import {ISyndicateGovernor} from "../src/interfaces/ISyndicateGovernor.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {MockRegistryMinimal} from "./mocks/MockRegistryMinimal.sol";
import {ProtocolConfig} from "../src/ProtocolConfig.sol";
import {IProtocolConfig} from "../src/interfaces/IProtocolConfig.sol";

/// @notice Unit tests targeting the abstract `GovernorParameters` surface
///         through a deployed `SyndicateGovernor` proxy. Covers happy path,
///         bound-check reverts, cross-bound reverts, address validation, and
///         the `ParameterChangeFinalized` event topic / payload contract.
contract GovernorParametersTest is Test {
    SyndicateGovernor public governor;
    ProtocolConfig public protocolConfig;
    MockRegistryMinimal public guardianRegistry;

    address public owner = makeAddr("owner");
    address public random = makeAddr("random");

    uint256 constant VOTING_PERIOD = 1 days;
    uint256 constant EXECUTION_WINDOW = 1 days;
    uint256 constant VETO_THRESHOLD_BPS = 4000;
    uint256 constant MAX_PERF_FEE_BPS = 1500;
    uint256 constant MIN_STRATEGY_DURATION = 1 hours;
    uint256 constant MAX_STRATEGY_DURATION = 30 days;
    uint256 constant COOLDOWN_PERIOD = 1 days;
    uint256 constant COLLAB_WINDOW = 48 hours;
    uint256 constant MAX_CO_PROPOSERS = 5;
    uint256 constant PROTOCOL_FEE_BPS = 100;

    function setUp() public {
        guardianRegistry = new MockRegistryMinimal();
        protocolConfig = new ProtocolConfig(owner);
        vm.prank(owner);
        protocolConfig.setProtocolFeeRecipient(owner);
        vm.prank(owner);
        protocolConfig.setProtocolFeeBps(PROTOCOL_FEE_BPS);

        SyndicateGovernor govImpl = new SyndicateGovernor();
        bytes memory govInit = abi.encodeCall(
            SyndicateGovernor.initialize,
            (
                address(0), // vault_: bootstrap governor; factory acts as bootstrap owner
                address(guardianRegistry),
                address(protocolConfig),
                owner, // factory == bootstrap owner: param setters are onlyVaultOwner → _bootstrapOwner
                ISyndicateGovernor.GovernorParams({
                    votingPeriod: VOTING_PERIOD,
                    executionWindow: EXECUTION_WINDOW,
                    vetoThresholdBps: VETO_THRESHOLD_BPS,
                    maxPerformanceFeeBps: MAX_PERF_FEE_BPS,
                    cooldownPeriod: COOLDOWN_PERIOD,
                    collaborationWindow: COLLAB_WINDOW,
                    maxCoProposers: MAX_CO_PROPOSERS,
                    minStrategyDuration: MIN_STRATEGY_DURATION,
                    maxStrategyDuration: MAX_STRATEGY_DURATION
                })
            )
        );
        governor = SyndicateGovernor(address(new ERC1967Proxy(address(govImpl), govInit)));
        // Per-vault governor: the vault resolves its governor via its factory
        // (this test contract). Mock governorOf(vault) -> the deployed governor.
        vm.mockCall(address(this), abi.encodeWithSignature("governorOf(address)"), abi.encode(address(governor)));
    }

    // ==================== setVotingPeriod ====================

    function test_setVotingPeriod_happyPath() public {
        uint256 oldVal = governor.getGovernorParams().votingPeriod;
        uint256 newVal = 2 days;
        vm.expectEmit(true, false, false, true, address(governor));
        emit ISyndicateGovernor.ParameterChangeFinalized(governor.PARAM_VOTING_PERIOD(), oldVal, newVal);
        vm.prank(owner);
        governor.setVotingPeriod(newVal);
        assertEq(governor.getGovernorParams().votingPeriod, newVal);
    }

    function test_setVotingPeriod_belowMin_reverts() public {
        uint256 belowMin = governor.MIN_VOTING_PERIOD() - 1;
        vm.prank(owner);
        vm.expectRevert(ISyndicateGovernor.InvalidVotingPeriod.selector);
        governor.setVotingPeriod(belowMin);
    }

    function test_setVotingPeriod_aboveMax_reverts() public {
        uint256 aboveMax = governor.MAX_VOTING_PERIOD() + 1;
        vm.prank(owner);
        vm.expectRevert(ISyndicateGovernor.InvalidVotingPeriod.selector);
        governor.setVotingPeriod(aboveMax);
    }

    // ==================== setExecutionWindow ====================

    function test_setExecutionWindow_happyPath() public {
        uint256 oldVal = governor.getGovernorParams().executionWindow;
        uint256 newVal = 3 days;
        vm.expectEmit(true, false, false, true, address(governor));
        emit ISyndicateGovernor.ParameterChangeFinalized(governor.PARAM_EXECUTION_WINDOW(), oldVal, newVal);
        vm.prank(owner);
        governor.setExecutionWindow(newVal);
        assertEq(governor.getGovernorParams().executionWindow, newVal);
    }

    function test_setExecutionWindow_belowMin_reverts() public {
        uint256 belowMin = governor.MIN_EXECUTION_WINDOW() - 1;
        vm.prank(owner);
        vm.expectRevert(ISyndicateGovernor.InvalidExecutionWindow.selector);
        governor.setExecutionWindow(belowMin);
    }

    function test_setExecutionWindow_aboveMax_reverts() public {
        uint256 aboveMax = governor.MAX_EXECUTION_WINDOW() + 1;
        vm.prank(owner);
        vm.expectRevert(ISyndicateGovernor.InvalidExecutionWindow.selector);
        governor.setExecutionWindow(aboveMax);
    }

    // ==================== setVetoThresholdBps ====================

    function test_setVetoThresholdBps_happyPath() public {
        uint256 oldVal = governor.getGovernorParams().vetoThresholdBps;
        uint256 newVal = 3000;
        vm.expectEmit(true, false, false, true, address(governor));
        emit ISyndicateGovernor.ParameterChangeFinalized(governor.PARAM_VETO_THRESHOLD_BPS(), oldVal, newVal);
        vm.prank(owner);
        governor.setVetoThresholdBps(newVal);
        assertEq(governor.getGovernorParams().vetoThresholdBps, newVal);
    }

    function test_setVetoThresholdBps_belowMin_reverts() public {
        uint256 belowMin = governor.MIN_VETO_THRESHOLD_BPS() - 1;
        vm.prank(owner);
        vm.expectRevert(ISyndicateGovernor.InvalidVetoThresholdBps.selector);
        governor.setVetoThresholdBps(belowMin);
    }

    function test_setVetoThresholdBps_aboveMax_reverts() public {
        uint256 aboveMax = governor.MAX_VETO_THRESHOLD_BPS() + 1;
        vm.prank(owner);
        vm.expectRevert(ISyndicateGovernor.InvalidVetoThresholdBps.selector);
        governor.setVetoThresholdBps(aboveMax);
    }

    // ==================== setMaxPerformanceFeeBps ====================

    function test_setMaxPerformanceFeeBps_happyPath() public {
        uint256 oldVal = governor.getGovernorParams().maxPerformanceFeeBps;
        uint256 newVal = 1200;
        vm.expectEmit(true, false, false, true, address(governor));
        emit ISyndicateGovernor.ParameterChangeFinalized(governor.PARAM_MAX_PERF_FEE(), oldVal, newVal);
        vm.prank(owner);
        governor.setMaxPerformanceFeeBps(newVal);
        assertEq(governor.getGovernorParams().maxPerformanceFeeBps, newVal);
    }

    function test_setMaxPerformanceFeeBps_aboveCap_reverts() public {
        uint256 aboveCap = governor.MAX_PERFORMANCE_FEE_CAP() + 1;
        vm.prank(owner);
        vm.expectRevert(ISyndicateGovernor.InvalidMaxPerformanceFeeBps.selector);
        governor.setMaxPerformanceFeeBps(aboveCap);
    }

    // ==================== setMinStrategyDuration ====================

    function test_setMinStrategyDuration_happyPath() public {
        uint256 oldVal = governor.getGovernorParams().minStrategyDuration;
        uint256 newVal = 2 hours;
        vm.expectEmit(true, false, false, true, address(governor));
        emit ISyndicateGovernor.ParameterChangeFinalized(governor.PARAM_MIN_STRATEGY_DURATION(), oldVal, newVal);
        vm.prank(owner);
        governor.setMinStrategyDuration(newVal);
        assertEq(governor.getGovernorParams().minStrategyDuration, newVal);
    }

    function test_setMinStrategyDuration_belowAbsoluteMin_reverts() public {
        uint256 belowMin = governor.ABSOLUTE_MIN_STRATEGY_DURATION() - 1;
        vm.prank(owner);
        vm.expectRevert(ISyndicateGovernor.InvalidStrategyDurationBounds.selector);
        governor.setMinStrategyDuration(belowMin);
    }

    function test_setMinStrategyDuration_aboveCurrentMax_reverts() public {
        // Can't set min above the configured max.
        vm.prank(owner);
        vm.expectRevert(ISyndicateGovernor.InvalidStrategyDurationBounds.selector);
        governor.setMinStrategyDuration(MAX_STRATEGY_DURATION + 1);
    }

    // ==================== setMaxStrategyDuration ====================

    function test_setMaxStrategyDuration_happyPath() public {
        uint256 oldVal = governor.getGovernorParams().maxStrategyDuration;
        uint256 newVal = 14 days;
        vm.expectEmit(true, false, false, true, address(governor));
        emit ISyndicateGovernor.ParameterChangeFinalized(governor.PARAM_MAX_STRATEGY_DURATION(), oldVal, newVal);
        vm.prank(owner);
        governor.setMaxStrategyDuration(newVal);
        assertEq(governor.getGovernorParams().maxStrategyDuration, newVal);
    }

    function test_setMaxStrategyDuration_aboveAbsoluteMax_reverts() public {
        uint256 aboveMax = governor.ABSOLUTE_MAX_STRATEGY_DURATION() + 1;
        vm.prank(owner);
        vm.expectRevert(ISyndicateGovernor.InvalidStrategyDurationBounds.selector);
        governor.setMaxStrategyDuration(aboveMax);
    }

    function test_setMaxStrategyDuration_allowsLongHorizon() public {
        // Beyond the old 30-day cap — now allowed after raising ABSOLUTE_MAX to 3650d,
        // so an indefinitely-lived strategy (leveraged Aerodrome CL) can run.
        assertEq(governor.ABSOLUTE_MAX_STRATEGY_DURATION(), 3650 days);
        uint256 longHorizon = 365 days;
        vm.prank(owner);
        governor.setMaxStrategyDuration(longHorizon);
        assertEq(governor.getGovernorParams().maxStrategyDuration, longHorizon);
    }

    function test_setMaxStrategyDuration_belowCurrentMin_reverts() public {
        // Can't set max below the configured min.
        vm.prank(owner);
        vm.expectRevert(ISyndicateGovernor.InvalidStrategyDurationBounds.selector);
        governor.setMaxStrategyDuration(MIN_STRATEGY_DURATION - 1);
    }

    // ==================== setCooldownPeriod ====================

    function test_setCooldownPeriod_happyPath() public {
        uint256 oldVal = governor.getGovernorParams().cooldownPeriod;
        uint256 newVal = 2 days;
        vm.expectEmit(true, false, false, true, address(governor));
        emit ISyndicateGovernor.ParameterChangeFinalized(governor.PARAM_COOLDOWN(), oldVal, newVal);
        vm.prank(owner);
        governor.setCooldownPeriod(newVal);
        assertEq(governor.getGovernorParams().cooldownPeriod, newVal);
    }

    function test_setCooldownPeriod_belowMin_reverts() public {
        uint256 belowMin = governor.MIN_COOLDOWN_PERIOD() - 1;
        vm.prank(owner);
        vm.expectRevert(ISyndicateGovernor.InvalidCooldownPeriod.selector);
        governor.setCooldownPeriod(belowMin);
    }

    function test_setCooldownPeriod_aboveMax_reverts() public {
        uint256 aboveMax = governor.MAX_COOLDOWN_PERIOD() + 1;
        vm.prank(owner);
        vm.expectRevert(ISyndicateGovernor.InvalidCooldownPeriod.selector);
        governor.setCooldownPeriod(aboveMax);
    }

    // ==================== setCollaborationWindow ====================

    function test_setCollaborationWindow_happyPath() public {
        uint256 oldVal = governor.getGovernorParams().collaborationWindow;
        uint256 newVal = 24 hours;
        vm.expectEmit(true, false, false, true, address(governor));
        emit ISyndicateGovernor.ParameterChangeFinalized(governor.PARAM_COLLAB_WINDOW(), oldVal, newVal);
        vm.prank(owner);
        governor.setCollaborationWindow(newVal);
        assertEq(governor.getGovernorParams().collaborationWindow, newVal);
    }

    function test_setCollaborationWindow_belowMin_reverts() public {
        uint256 belowMin = governor.MIN_COLLABORATION_WINDOW() - 1;
        vm.prank(owner);
        vm.expectRevert(ISyndicateGovernor.InvalidCollaborationWindow.selector);
        governor.setCollaborationWindow(belowMin);
    }

    function test_setCollaborationWindow_aboveMax_reverts() public {
        uint256 aboveMax = governor.MAX_COLLABORATION_WINDOW() + 1;
        vm.prank(owner);
        vm.expectRevert(ISyndicateGovernor.InvalidCollaborationWindow.selector);
        governor.setCollaborationWindow(aboveMax);
    }

    // ==================== setMaxCoProposers ====================

    function test_setMaxCoProposers_happyPath() public {
        uint256 oldVal = governor.getGovernorParams().maxCoProposers;
        uint256 newVal = 7;
        vm.expectEmit(true, false, false, true, address(governor));
        emit ISyndicateGovernor.ParameterChangeFinalized(governor.PARAM_MAX_CO_PROPOSERS(), oldVal, newVal);
        vm.prank(owner);
        governor.setMaxCoProposers(newVal);
        assertEq(governor.getGovernorParams().maxCoProposers, newVal);
    }

    function test_setMaxCoProposers_zero_reverts() public {
        vm.prank(owner);
        vm.expectRevert(ISyndicateGovernor.InvalidMaxCoProposers.selector);
        governor.setMaxCoProposers(0);
    }

    function test_setMaxCoProposers_aboveAbsoluteMax_reverts() public {
        uint256 aboveMax = governor.ABSOLUTE_MAX_CO_PROPOSERS() + 1;
        vm.prank(owner);
        vm.expectRevert(ISyndicateGovernor.InvalidMaxCoProposers.selector);
        governor.setMaxCoProposers(aboveMax);
    }

    // ==================== setProtocolFeeBps ====================

    function test_setProtocolFeeBps_happyPath() public {
        uint256 oldVal = protocolConfig.protocolFeeBps();
        uint256 newVal = 50;
        vm.expectEmit(true, false, false, true, address(protocolConfig));
        emit IProtocolConfig.ParameterChangeFinalized(keccak256("protocolFeeBps"), oldVal, newVal);
        vm.prank(owner);
        protocolConfig.setProtocolFeeBps(newVal);
        assertEq(protocolConfig.protocolFeeBps(), newVal);
    }

    function test_setProtocolFeeBps_aboveMax_reverts() public {
        uint256 aboveMax = protocolConfig.MAX_PROTOCOL_FEE_BPS() + 1;
        vm.prank(owner);
        vm.expectRevert(IProtocolConfig.InvalidProtocolFeeBps.selector);
        protocolConfig.setProtocolFeeBps(aboveMax);
    }

    // ==================== setProtocolFeeRecipient ====================

    function test_setProtocolFeeRecipient_happyPath() public {
        address newRecipient = makeAddr("newRecipient");
        uint256 oldVal = uint256(uint160(protocolConfig.protocolFeeRecipient()));
        uint256 newVal = uint256(uint160(newRecipient));
        vm.expectEmit(true, false, false, true, address(protocolConfig));
        emit IProtocolConfig.ProtocolFeeRecipientSet(protocolConfig.protocolFeeRecipient(), newRecipient);
        vm.prank(owner);
        protocolConfig.setProtocolFeeRecipient(newRecipient);
        assertEq(protocolConfig.protocolFeeRecipient(), newRecipient);
    }

    function test_setProtocolFeeRecipient_zero_reverts() public {
        vm.prank(owner);
        vm.expectRevert(IProtocolConfig.InvalidProtocolFeeRecipient.selector);
        protocolConfig.setProtocolFeeRecipient(address(0));
    }

    // ==================== setGuardianFeeBps ====================

    function test_setGuardianFeeBps_happyPath() public {
        // Raising the guardian fee above 0 now requires a guardians-fee
        // recipient (coupling mirrors the protocol-fee recipient rule).
        vm.prank(owner);
        protocolConfig.setGuardiansFeeRecipient(makeAddr("guardiansFeeRecipient"));

        uint256 oldVal = protocolConfig.guardianFeeBps();
        uint256 newVal = 250;
        vm.expectEmit(true, false, false, true, address(protocolConfig));
        emit IProtocolConfig.ParameterChangeFinalized(keccak256("guardianFeeBps"), oldVal, newVal);
        vm.prank(owner);
        protocolConfig.setGuardianFeeBps(newVal);
        assertEq(protocolConfig.guardianFeeBps(), newVal);
    }

    function test_setGuardianFeeBps_aboveMax_reverts() public {
        uint256 aboveMax = protocolConfig.MAX_GUARDIAN_FEE_BPS() + 1;
        vm.prank(owner);
        vm.expectRevert(IProtocolConfig.InvalidGuardianFeeBps.selector);
        protocolConfig.setGuardianFeeBps(aboveMax);
    }

    // setFactory removed in per-vault governor design — factory is set-once at initialize.

    // ==================== Cross-setter: protocolFeeBps requires recipient ====================

    function test_setProtocolFeeBps_noRecipient_reverts() public {
        // Deploy a fresh ProtocolConfig with no recipient set.
        ProtocolConfig pc2 = new ProtocolConfig(owner);
        vm.prank(owner);
        vm.expectRevert(IProtocolConfig.InvalidProtocolFeeRecipient.selector);
        pc2.setProtocolFeeBps(100);
    }

    // ==================== onlyOwner blanket coverage ====================

    /// @notice Every parameter setter must reject non-owner callers with the
    ///         OZ unauthorized error. Batched into one test to avoid 13 near-
    ///         identical bodies; each setter is exercised once.
    function test_allSetters_notOwner_revert() public {
        bytes memory expected = abi.encodeWithSelector(ISyndicateGovernor.NotVaultOwner.selector);
        vm.startPrank(random);
        vm.expectRevert(expected);
        governor.setVotingPeriod(2 days);
        vm.expectRevert(expected);
        governor.setExecutionWindow(2 days);
        vm.expectRevert(expected);
        governor.setVetoThresholdBps(3000);
        vm.expectRevert(expected);
        governor.setMaxPerformanceFeeBps(4000);
        vm.expectRevert(expected);
        governor.setMinStrategyDuration(2 hours);
        vm.expectRevert(expected);
        governor.setMaxStrategyDuration(14 days);
        vm.expectRevert(expected);
        governor.setCooldownPeriod(2 days);
        vm.expectRevert(expected);
        governor.setCollaborationWindow(24 hours);
        vm.expectRevert(expected);
        governor.setMaxCoProposers(7);
        // ProtocolConfig setters are plain Ownable2Step — different error.
        bytes memory expectedOwnable =
            abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, random);
        vm.expectRevert(expectedOwnable);
        protocolConfig.setProtocolFeeBps(500);
        vm.expectRevert(expectedOwnable);
        protocolConfig.setProtocolFeeRecipient(makeAddr("r"));
        vm.expectRevert(expectedOwnable);
        protocolConfig.setGuardianFeeBps(250);
        // governor.setFactory removed in per-vault design — factory is set-once at initialize.
        vm.stopPrank();
    }

    // ==================== Param-key topic contract ====================

    /// @notice Off-chain consumers (indexers, the Mintlify docs, the CLI's
    ///         governance event subscriber) rely on these topic hashes —
    ///         pinning at least three guards against accidental key drift.
    function test_paramKeys_matchKeccak() public view {
        assertEq(governor.PARAM_VOTING_PERIOD(), keccak256("votingPeriod"));
        assertEq(governor.PARAM_EXECUTION_WINDOW(), keccak256("executionWindow"));
        // PARAM_PROTOCOL_FEE_BPS moved to ProtocolConfig.
        // assertEq(governor.PARAM_PROTOCOL_FEE_BPS(), keccak256("protocolFeeBps"));
    }

    // ==================== Pre-init guard ====================

    /// @notice A bare implementation deploy (never initialized) has owner == 0.
    ///         Any setter call must revert with the OZ unauthorized error.
    function test_setters_beforeInit_revertOwnable() public {
        SyndicateGovernor bareImpl = new SyndicateGovernor();

        vm.expectRevert(abi.encodeWithSelector(ISyndicateGovernor.NotVaultOwner.selector));
        bareImpl.setVotingPeriod(2 days);

        // setFactory and setProtocolFeeRecipient removed from governor in per-vault design.
    }
}
