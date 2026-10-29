// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {SyndicateVault} from "../../../src/SyndicateVault.sol";
import {ISyndicateVault} from "../../../src/interfaces/ISyndicateVault.sol";
import {SyndicateGovernor} from "../../../src/SyndicateGovernor.sol";
import {ISyndicateGovernor} from "../../../src/interfaces/ISyndicateGovernor.sol";
import {GovernorBeacon} from "../../../src/GovernorBeacon.sol";
import {ProtocolConfig} from "../../../src/ProtocolConfig.sol";
import {BatchExecutorLib} from "../../../src/BatchExecutorLib.sol";
import {ProtocolFeeRouter} from "../../../src/ProtocolFeeRouter.sol";
import {BlacklistingERC20Mock} from "../../mocks/BlacklistingERC20Mock.sol";
import {MockAgentRegistry} from "../../mocks/MockAgentRegistry.sol";
import {MockRegistryMinimal} from "../../mocks/MockRegistryMinimal.sol";
import {GovEnvelope} from "../../helpers/GovEnvelope.sol";
import {deployTierRegistry} from "../../helpers/TierRegistryFixture.sol";

/// @notice In-process harness (copied from test/fees/ProtocolFeeRouterSettlement.t.sol) that can
///         stand up several vault+governor pairs sharing one ProtocolConfig and one router.
abstract contract RouterIntegrationBase is Test {
    ProtocolConfig internal protocolConfig;
    BlacklistingERC20Mock internal usdg;
    MockAgentRegistry internal agentRegistry;
    ProtocolFeeRouter internal router;
    BatchExecutorLib internal executorLib;
    GovernorBeacon internal beacon;

    SyndicateVault internal vault;
    SyndicateGovernor internal governor;

    address internal owner = makeAddr("owner");
    address internal safe = makeAddr("safe");
    address internal foundation = makeAddr("foundation");
    address internal agent = makeAddr("agent");
    address internal lp1 = makeAddr("lp1");
    address internal guardianRecipient = makeAddr("guardianRecipient");

    uint256 internal constant VOTING_PERIOD = 1 days;
    uint256 internal constant DEPOSIT = 1_000_000e6;
    uint256 internal agentNftId;

    function setUp() public virtual {
        router = new ProtocolFeeRouter(safe);
        protocolConfig = new ProtocolConfig(owner);
        vm.startPrank(owner);
        protocolConfig.setProtocolFeeRecipient(address(router));
        protocolConfig.setGuardiansFeeRecipient(guardianRecipient);
        vm.stopPrank();

        usdg = new BlacklistingERC20Mock("USDG", "USDG", 6);
        executorLib = new BatchExecutorLib();
        agentRegistry = new MockAgentRegistry();
        vm.mockCall(address(this), abi.encodeWithSignature("agentRegistry()"), abi.encode(address(agentRegistry)));
        agentNftId = agentRegistry.mint(agent);
        vm.mockCall(address(this), abi.encodeWithSignature("depositsRestricted()"), abi.encode(false));
        vm.mockCall(address(this), abi.encodeWithSignature("ownerOnlyProposals()"), abi.encode(false));

        beacon = new GovernorBeacon(address(new SyndicateGovernor(24 hours, 1 hours)), owner);
        (vault, governor) = _deployPair(lp1);
        vm.warp(vm.getBlockTimestamp() + 1);
    }

    function _deployPair(address lp) internal returns (SyndicateVault v, SyndicateGovernor g) {
        SyndicateVault vaultImpl = new SyndicateVault();
        bytes memory vaultInit = abi.encodeCall(
            SyndicateVault.initialize,
            (ISyndicateVault.InitParams({
                    asset: address(usdg),
                    name: "Sherwood Vault",
                    symbol: "swUSDG",
                    owner: owner,
                    executorImpl: address(executorLib),
                    openDeposits: true,
                    agentRegistry: address(agentRegistry),
                    managementFeeBps: 200
                }))
        );
        v = SyndicateVault(payable(address(new ERC1967Proxy(address(vaultImpl), vaultInit))));
        vm.startPrank(owner);
        v.registerAgent(agentNftId, agent);
        v.setAgentFeeBps(2000);
        vm.stopPrank();

        bytes memory govInit = abi.encodeCall(
            SyndicateGovernor.initialize,
            (
                address(v),
                address(new MockRegistryMinimal()),
                address(protocolConfig),
                address(this),
                address(deployTierRegistry(address(this))),
                _params()
            )
        );
        g = SyndicateGovernor(address(new BeaconProxy(address(beacon), govInit)));
        // Exact-calldata mock per vault so several pairs can coexist.
        vm.mockCall(address(this), abi.encodeWithSignature("governorOf(address)", address(v)), abi.encode(address(g)));

        usdg.mint(lp, DEPOSIT);
        vm.startPrank(lp);
        usdg.approve(address(v), type(uint256).max);
        v.deposit(DEPOSIT, lp);
        vm.stopPrank();
    }

    function _params() internal pure returns (ISyndicateGovernor.GovernorParams memory) {
        return ISyndicateGovernor.GovernorParams({
            votingPeriod: VOTING_PERIOD,
            executionWindow: 1 days,
            vetoThresholdBps: 4000,
            maxPerformanceFeeBps: 2000,
            cooldownPeriod: 1 hours,
            collaborationWindow: 48 hours,
            maxCoProposers: 5,
            minStrategyDuration: 1 hours,
            maxStrategyDuration: 30 days
        });
    }

    function _noopCalls() internal view returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({
            target: address(usdg), data: abi.encodeCall(usdg.approve, (address(this), 0)), value: 0
        });
    }

    function _proposeOn(SyndicateVault v, SyndicateGovernor g) internal returns (uint256 id) {
        ISyndicateGovernor.RiskEnvelope memory env = GovEnvelope.permissive(address(v));
        BatchExecutorLib.Call[] memory calls = _noopCalls();
        vm.prank(agent);
        id = g.propose(
            address(v),
            address(0),
            "ipfs://test",
            7 days,
            env,
            calls,
            GovEnvelope.defaultCaps(env.maxCapital, calls.length),
            calls,
            GovEnvelope.defaultCaps(env.maxCapital, calls.length),
            new ISyndicateGovernor.CoProposer[](0)
        );
        vm.warp(vm.getBlockTimestamp() + 1);
    }

    function _propose() internal returns (uint256) {
        return _proposeOn(vault, governor);
    }

    function _voteAndExecute(SyndicateGovernor g, uint256 id, address voter) internal {
        vm.prank(voter);
        g.vote(id, ISyndicateGovernor.VoteType.For);
        vm.warp(vm.getBlockTimestamp() + VOTING_PERIOD + 1);
        g.executeProposal(id);
    }

    /// @dev `profit` is minted into the vault mid-strategy so the performance leg is exercised.
    function _settle(SyndicateVault v, SyndicateGovernor g, uint256 id, uint256 profit) internal {
        vm.warp(vm.getBlockTimestamp() + 30 days);
        if (profit != 0) usdg.mint(address(v), profit);
        vm.prank(agent);
        g.settleProposal(id);
    }

    function _executeAndSettle(uint256 id, uint256 profit) internal {
        _voteAndExecute(governor, id, lp1);
        _settle(vault, governor, id, profit);
    }

    function _alloc1(address target) internal pure returns (ProtocolFeeRouter.Allocation[] memory a) {
        a = new ProtocolFeeRouter.Allocation[](1);
        a[0] = ProtocolFeeRouter.Allocation({target: target, bps: 10_000});
    }
}
