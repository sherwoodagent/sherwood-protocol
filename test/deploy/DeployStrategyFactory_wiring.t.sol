// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {DeployStrategyFactory} from "../../script/DeployStrategyFactory.s.sol";
import {StrategyFactory} from "../../src/StrategyFactory.sol";
import {TierRegistry} from "../../src/TierRegistry.sol";
import {SyndicateGovernor} from "../../src/SyndicateGovernor.sol";
import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {ISyndicateVault} from "../../src/interfaces/ISyndicateVault.sol";
import {VaultWithdrawalQueue} from "../../src/queue/VaultWithdrawalQueue.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {ProtocolConfig} from "../../src/ProtocolConfig.sol";

import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "../mocks/MockAgentRegistry.sol";
import {MockRegistryMinimal} from "../mocks/MockRegistryMinimal.sol";
import {MockStrategy} from "../mocks/MockStrategy.sol";
import {MockStrategyAdapter} from "../mocks/MockStrategyAdapter.sol";

/// @dev The mixin is abstract; this makes it concrete.
contract SfHarness is DeployStrategyFactory {}

/// @notice The StrategyFactory phase leaves `TierRegistry.strategyFactory()` pointing at the
///         factory it minted, and a proposal flows afterwards. Without the wiring every
///         `propose` reverts `StrategyNotRegistered`, so the ceremony refuses to skip it.
contract DeployStrategyFactoryWiringTest is Test {
    SfHarness script;
    TierRegistry tierRegistry;
    SyndicateGovernor governor;
    SyndicateVault vault;
    ERC20Mock usdc;
    MockStrategy template;

    address owner = makeAddr("owner");
    address agent = makeAddr("agent");
    address lp = makeAddr("lp");

    function setUp() public {
        script = new SfHarness();
        template = new MockStrategy();
        // `deploy()` bootstraps the Create3Factory at `msg.sender` and then calls `c3.deploy`
        // as the SCRIPT, so the script address is the broadcaster stand-in throughout.
        tierRegistry = new TierRegistry(address(script));

        usdc = new ERC20Mock("USDC", "USDC", 6);
        MockAgentRegistry agentRegistry = new MockAgentRegistry();
        SyndicateVault vaultImpl = new SyndicateVault();
        bytes memory vaultInit = abi.encodeCall(
            SyndicateVault.initialize,
            (ISyndicateVault.InitParams({
                    asset: address(usdc),
                    name: "Sherwood Vault",
                    symbol: "swUSDC",
                    owner: owner,
                    executorImpl: address(new BatchExecutorLib()),
                    openDeposits: true,
                    agentRegistry: address(agentRegistry),
                    managementFeeBps: 0
                }))
        );
        vault = SyndicateVault(payable(address(new ERC1967Proxy(address(vaultImpl), vaultInit))));
        vault.setWithdrawalQueue(address(new VaultWithdrawalQueue(address(vault))));

        SyndicateGovernor govImpl = new SyndicateGovernor(24 hours, 1 hours);
        bytes memory govInit = abi.encodeCall(
            SyndicateGovernor.initialize,
            (
                address(vault),
                address(new MockRegistryMinimal()),
                address(new ProtocolConfig(owner)),
                address(this),
                address(tierRegistry),
                ISyndicateGovernor.GovernorParams({
                    votingPeriod: 1 days,
                    executionWindow: 1 days,
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
        // The test contract is the syndicate factory.
        vm.mockCall(address(this), abi.encodeWithSignature("governorOf(address)"), abi.encode(address(governor)));
        vm.mockCall(address(this), abi.encodeWithSignature("vaultToSyndicate(address)"), abi.encode(uint256(1)));

        uint256 agentId = agentRegistry.mint(agent);
        vm.prank(owner);
        vault.registerAgent(agentId, agent);
        usdc.mint(lp, 1_000_000e6);
        vm.startPrank(lp);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(1_000_000e6, lp);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 1);
    }

    function _deploy(address registry) internal returns (StrategyFactory) {
        address[] memory templates = new address[](1);
        templates[0] = address(template);
        vm.prank(address(script));
        return script.deploy(address(this), registry, templates);
    }

    function test_ceremonyWiresTheFactoryAndAProposalFlows() public {
        StrategyFactory sf = _deploy(address(tierRegistry));

        assertEq(tierRegistry.strategyFactory(), address(sf), "registry points at the minted factory");
        assertTrue(sf.approvedTemplate(address(template)), "template allowlisted");
        assertEq(sf.owner(), address(script), "the deployer keeps the factory; DeployAll._handoffAll moves it");

        MockStrategyAdapter s = new MockStrategyAdapter();
        sf.registerStrategy(address(s));
        BatchExecutorLib.Call[] memory calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({
            target: address(usdc), data: abi.encodeCall(usdc.approve, (address(s), 0)), value: 0
        });
        vm.prank(agent);
        uint256 pid = governor.propose(
            address(vault),
            address(s),
            "ipfs://wiring",
            7 days,
            ISyndicateGovernor.RiskEnvelope({maxCapital: 1, maxDrawdownBps: 10_000}),
            calls,
            new uint256[](1),
            calls,
            new uint256[](1),
            new ISyndicateGovernor.CoProposer[](0)
        );
        assertEq(governor.getProposal(pid).strategy, address(s), "a proposal flows through the wired registry");
    }

    function test_ceremonyRefusesARegistryTheDeployerNoLongerOwns() public {
        TierRegistry handedOff = new TierRegistry(makeAddr("safe"));
        vm.expectRevert(
            bytes(
                "TIER_REGISTRY owner is not the deployer: run this phase BEFORE the multisig accepts TierRegistry ownership (unwired, every propose reverts StrategyNotRegistered)"
            )
        );
        _deploy(address(handedOff));
        assertEq(tierRegistry.strategyFactory(), address(0), "nothing wired anywhere");
    }

    function test_ceremonyRefusesAMissingRegistry() public {
        vm.expectRevert(bytes("TIER_REGISTRY missing from the address book: run Deploy first"));
        _deploy(address(0));
    }

    /// @notice A registry already pointing at some other factory is refused, not overwritten:
    ///         re-pointing a live registry strands every strategy registered on the old one.
    function test_ceremonyRefusesAForeignStrategyFactoryPointer() public {
        StrategyFactory foreign = new StrategyFactory(address(this), address(this));
        vm.prank(address(script));
        tierRegistry.setStrategyFactory(address(foreign));

        vm.expectRevert(bytes("TIER_REGISTRY already points at a foreign StrategyFactory"));
        _deploy(address(tierRegistry));
    }

    /// @notice Re-running the phase adopts the same factory and sends no second wiring write.
    function test_secondRunAdoptsTheSameFactory() public {
        StrategyFactory first = _deploy(address(tierRegistry));
        StrategyFactory second = _deploy(address(tierRegistry));

        assertEq(address(second), address(first), "CREATE3 address is stable across runs");
        assertEq(tierRegistry.strategyFactory(), address(first), "registry still points at it");
    }
}
