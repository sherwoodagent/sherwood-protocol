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

/// @dev Forwarder etched at `DEFAULT_SENDER` so the script's `msg.sender` is the
///      broadcaster (see `DeployPlanBPreflight.t.sol` for why a prank cannot do this).
contract SfScriptCaller {
    function fwd(address target, bytes calldata data) external returns (bytes memory ret) {
        bool ok;
        (ok, ret) = target.call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }
}

/// @notice The StrategyFactory phase leaves `TierRegistry.strategyFactory()` pointing at the
///         factory it minted, and a proposal flows afterwards. Without the wiring every
///         `propose` reverts `StrategyNotRegistered`, so the ceremony refuses to skip it.
contract DeployStrategyFactoryWiringTest is Test {
    DeployStrategyFactory script;
    TierRegistry tierRegistry;
    SyndicateGovernor governor;
    SyndicateVault vault;
    ERC20Mock usdc;
    MockStrategy template;

    address owner = makeAddr("owner");
    address agent = makeAddr("agent");
    address lp = makeAddr("lp");

    function setUp() public {
        vm.etch(DEFAULT_SENDER, address(new SfScriptCaller()).code);
        script = new DeployStrategyFactory();
        template = new MockStrategy();
        tierRegistry = new TierRegistry(DEFAULT_SENDER);

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

    /// @dev The raw forwarded call, so a refusal test can arm `expectRevert` on it directly.
    function _deployRaw(address registry) internal returns (bytes memory) {
        address[] memory templates = new address[](1);
        templates[0] = address(template);
        return SfScriptCaller(DEFAULT_SENDER)
            .fwd(
                address(script),
                abi.encodeCall(DeployStrategyFactory.deploy, (address(this), registry, templates, address(0)))
            );
    }

    function _deploy(address registry) internal returns (StrategyFactory) {
        return StrategyFactory(abi.decode(_deployRaw(registry), (address)));
    }

    function test_ceremonyWiresTheFactoryAndAProposalFlows() public {
        StrategyFactory sf = _deploy(address(tierRegistry));

        assertEq(tierRegistry.strategyFactory(), address(sf), "registry points at the minted factory");
        assertTrue(sf.approvedTemplate(address(template)), "template allowlisted");
        assertEq(sf.owner(), DEFAULT_SENDER, "handoff skipped: deployer keeps the factory");

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
        _deployRaw(address(handedOff));
        assertEq(tierRegistry.strategyFactory(), address(0), "nothing wired anywhere");
    }

    function test_ceremonyRefusesAMissingRegistry() public {
        vm.expectRevert(bytes("TIER_REGISTRY missing from the address book: run Deploy first"));
        _deployRaw(address(0));
    }
}
