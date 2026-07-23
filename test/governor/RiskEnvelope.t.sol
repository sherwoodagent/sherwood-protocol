// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SyndicateGovernor} from "../../src/SyndicateGovernor.sol";
import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {ISyndicateVault} from "../../src/interfaces/ISyndicateVault.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "../mocks/MockAgentRegistry.sol";
import {MockRegistryMinimal} from "../mocks/MockRegistryMinimal.sol";
import {ProtocolConfig} from "../../src/ProtocolConfig.sol";

/// @notice Task 3 — per-proposal risk envelope (spec 2026-07-22 §3.1). The
///         proposer declares `maxCapital` (net-outflow ceiling, vault-enforced
///         in Task 4) and `maxDrawdownBps` (declared loss envelope; losses
///         beyond it are challengeable in a later plan) at propose time.
contract RiskEnvelopeTest is Test {
    SyndicateGovernor public governor;
    SyndicateVault public vault;
    BatchExecutorLib public executorLib;
    ERC20Mock public usdc;
    MockAgentRegistry public agentRegistry;
    MockRegistryMinimal public guardianRegistry;
    ERC20Mock public targetToken;

    address public owner = makeAddr("owner");
    address public agent = makeAddr("agent");
    address public lp1 = makeAddr("lp1");

    uint256 constant VOTING_PERIOD = 1 days;
    uint256 constant EXECUTION_WINDOW = 1 days;

    function setUp() public {
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        targetToken = new ERC20Mock("Target", "TGT", 18);
        executorLib = new BatchExecutorLib();
        agentRegistry = new MockAgentRegistry();
        guardianRegistry = new MockRegistryMinimal();

        SyndicateVault vaultImpl = new SyndicateVault();
        bytes memory vaultInit = abi.encodeCall(
            SyndicateVault.initialize,
            (ISyndicateVault.InitParams({
                    asset: address(usdc),
                    name: "Sherwood Vault",
                    symbol: "swUSDC",
                    owner: owner,
                    executorImpl: address(executorLib),
                    openDeposits: true,
                    agentRegistry: address(agentRegistry),
                    managementFeeBps: 50
                }))
        );
        vault = SyndicateVault(payable(address(new ERC1967Proxy(address(vaultImpl), vaultInit))));

        SyndicateGovernor govImpl = new SyndicateGovernor(24 hours, 1 hours);
        bytes memory govInit = abi.encodeCall(
            SyndicateGovernor.initialize,
            (
                address(vault),
                address(guardianRegistry),
                address(new ProtocolConfig(owner)),
                address(this), // factory (test contract)
                ISyndicateGovernor.GovernorParams({
                    votingPeriod: VOTING_PERIOD,
                    executionWindow: EXECUTION_WINDOW,
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
        governor = SyndicateGovernor(address(new ERC1967Proxy(address(govImpl), govInit)));

        vm.mockCall(address(this), abi.encodeWithSignature("governorOf(address)"), abi.encode(address(governor)));

        vm.startPrank(owner);
        vault.registerAgent(agentRegistry.mint(agent), agent);
        vm.stopPrank();

        usdc.mint(lp1, 100_000e6);
        vm.startPrank(lp1);
        usdc.approve(address(vault), 60_000e6);
        vault.deposit(60_000e6, lp1);
        vm.stopPrank();

        vm.warp(vm.getBlockTimestamp() + 1);
    }

    function _execCalls() internal view returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({
            target: address(usdc), data: abi.encodeCall(usdc.approve, (address(targetToken), 50_000e6)), value: 0
        });
    }

    function _settleCalls() internal view returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({
            target: address(usdc), data: abi.encodeCall(usdc.approve, (address(targetToken), 0)), value: 0
        });
    }

    /// @dev Builds a normal single-proposer proposal carrying the given envelope.
    function _proposeWithEnvelope(uint256 maxCapital, uint16 maxDrawdownBps) internal returns (uint256 proposalId) {
        vm.prank(agent);
        proposalId = governor.propose(
            address(vault),
            address(0),
            "ipfs://risk-envelope",
            7 days,
            ISyndicateGovernor.RiskEnvelope({maxCapital: maxCapital, maxDrawdownBps: maxDrawdownBps}),
            _execCalls(),
            _settleCalls(),
            new ISyndicateGovernor.CoProposer[](0)
        );
    }

    function test_proposeStoresEnvelope() public {
        uint256 pid = _proposeWithEnvelope(1_000e6, 400); // maxCapital 1000 USDC, 4% drawdown
        (uint256 maxCapital, uint16 maxDrawdownBps) = governor.getRiskEnvelope(pid);
        assertEq(maxCapital, 1_000e6);
        assertEq(maxDrawdownBps, 400);
    }

    function test_proposeRevertsOnZeroMaxCapital() public {
        vm.expectRevert(ISyndicateGovernor.ZeroMaxCapital.selector);
        _proposeWithEnvelope(0, 400);
    }

    function test_proposeRevertsOnDrawdownOver100Pct() public {
        vm.expectRevert(ISyndicateGovernor.InvalidDrawdown.selector);
        _proposeWithEnvelope(1_000e6, 10_001);
    }

    /// @notice Boundary: exactly 100% drawdown is the maximum legal declaration.
    function test_proposeAcceptsDrawdownAtExactly100Pct() public {
        uint256 pid = _proposeWithEnvelope(1_000e6, 10_000);
        (, uint16 maxDrawdownBps) = governor.getRiskEnvelope(pid);
        assertEq(maxDrawdownBps, 10_000);
    }
}
