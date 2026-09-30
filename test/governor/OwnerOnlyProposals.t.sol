// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {SyndicateGovernor} from "../../src/SyndicateGovernor.sol";
import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {ISyndicateVault} from "../../src/interfaces/ISyndicateVault.sol";
import {SyndicateFactory} from "../../src/SyndicateFactory.sol";
import {GovernorBeacon} from "../../src/GovernorBeacon.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {ProtocolConfig} from "../../src/ProtocolConfig.sol";
import {TierRegistry} from "../../src/TierRegistry.sol";
import {IGuardianRegistry} from "../../src/interfaces/IGuardianRegistry.sol";
import {IStakedWood} from "../../src/interfaces/IStakedWood.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "../mocks/MockAgentRegistry.sol";
import {MockRegistryMinimal} from "../mocks/MockRegistryMinimal.sol";
import {GovEnvelope} from "../helpers/GovEnvelope.sol";
import {deployTierRegistry} from "../helpers/TierRegistryFixture.sol";

/// @notice The factory's `ownerOnlyProposals` flag, read live by the governor at propose time.
///         This test contract is the governor's factory, so the flag is a mocked return.
contract OwnerOnlyProposalsTest is Test {
    SyndicateGovernor governor;
    SyndicateVault vault;
    ERC20Mock usdc;
    MockAgentRegistry agentRegistry;
    ISyndicateGovernor.RiskEnvelope env;

    address owner = makeAddr("owner");
    address agent = makeAddr("agent");
    address coAgent = makeAddr("coAgent");
    address lp = makeAddr("lp");

    function setUp() public {
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        agentRegistry = new MockAgentRegistry();
        vm.mockCall(address(this), abi.encodeWithSignature("agentRegistry()"), abi.encode(address(agentRegistry)));

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
                    managementFeeBps: 50
                }))
        );
        vault = SyndicateVault(payable(address(new ERC1967Proxy(address(new SyndicateVault()), vaultInit))));

        bytes memory govInit = abi.encodeCall(
            SyndicateGovernor.initialize,
            (
                address(vault),
                address(new MockRegistryMinimal()),
                address(new ProtocolConfig(owner)),
                address(this),
                address(deployTierRegistry(address(this))),
                ISyndicateGovernor.GovernorParams({
                    votingPeriod: 1 days,
                    executionWindow: 1 days,
                    vetoThresholdBps: 4000,
                    maxPerformanceFeeBps: 1500,
                    cooldownPeriod: 1 days,
                    collaborationWindow: 48 hours,
                    maxCoProposers: 5,
                    minStrategyDuration: 1 days,
                    maxStrategyDuration: 7 days
                })
            )
        );
        governor =
            SyndicateGovernor(address(new ERC1967Proxy(address(new SyndicateGovernor(24 hours, 1 hours)), govInit)));

        vm.mockCall(address(this), abi.encodeWithSignature("governorOf(address)"), abi.encode(address(governor)));
        vm.mockCall(address(this), abi.encodeWithSignature("depositsRestricted()"), abi.encode(false));
        _setFlag(false);

        // Registered while the flag is off: the owner as its own agent, plus two outside agents.
        vm.startPrank(owner);
        vault.registerAgent(agentRegistry.mint(owner), owner);
        vault.registerAgent(agentRegistry.mint(agent), agent);
        vault.registerAgent(agentRegistry.mint(coAgent), coAgent);
        vm.stopPrank();

        usdc.mint(lp, 100_000e6);
        vm.startPrank(lp);
        usdc.approve(address(vault), 100_000e6);
        vault.deposit(100_000e6, lp);
        vm.stopPrank();

        vm.warp(block.timestamp + 1);
        env = GovEnvelope.permissive(address(vault));
    }

    function _setFlag(bool on) internal {
        vm.mockCall(address(this), abi.encodeWithSignature("ownerOnlyProposals()"), abi.encode(on));
    }

    function _coProposers(address co) internal pure returns (ISyndicateGovernor.CoProposer[] memory c) {
        if (co == address(0)) return c;
        c = new ISyndicateGovernor.CoProposer[](1);
        c[0] = ISyndicateGovernor.CoProposer({agent: co, splitBps: 3000});
    }

    function _propose(address proposer, address co) internal returns (uint256) {
        BatchExecutorLib.Call[] memory exec = new BatchExecutorLib.Call[](1);
        exec[0] = BatchExecutorLib.Call({
            target: address(usdc), data: abi.encodeCall(usdc.approve, (address(1), 50_000e6)), value: 0
        });
        BatchExecutorLib.Call[] memory settle = new BatchExecutorLib.Call[](1);
        settle[0] = BatchExecutorLib.Call({
            target: address(usdc), data: abi.encodeCall(usdc.approve, (address(1), 0)), value: 0
        });
        uint256[] memory caps = GovEnvelope.defaultCaps(env.maxCapital, 1);
        ISyndicateGovernor.CoProposer[] memory coProps = _coProposers(co);
        vm.prank(proposer);
        return governor.propose(address(vault), address(0), "ipfs://p", 7 days, env, exec, caps, settle, caps, coProps);
    }

    /// @notice Flag on, a registered agent that is not the vault owner cannot propose.
    function test_flagOn_nonOwnerAgentReverts() public {
        _setFlag(true);
        vm.expectRevert(ISyndicateGovernor.ProposerNotOwner.selector);
        _propose(agent, address(0));
    }

    /// @notice Flag on, the vault owner registered as an agent proposes as usual.
    function test_flagOn_ownerProposes() public {
        _setFlag(true);
        uint256 id = _propose(owner, address(0));
        ISyndicateGovernor.StrategyProposal memory p = governor.getProposal(id);
        assertEq(p.proposer, owner, "owner is the proposer");
        assertEq(uint256(p.state), uint256(ISyndicateGovernor.ProposalState.Pending), "pending");
    }

    /// @notice Flag on, even the owner cannot open a collaborative proposal.
    function test_flagOn_collaborativeReverts() public {
        _setFlag(true);
        vm.expectRevert(ISyndicateGovernor.CollaborationDisabled.selector);
        _propose(owner, coAgent);
    }

    /// @notice Flag off, a non-owner agent proposes as before.
    function test_flagOff_nonOwnerAgentProposes() public {
        uint256 id = _propose(agent, address(0));
        assertEq(governor.getProposal(id).proposer, agent, "agent is the proposer");
    }

    /// @notice A flip binds agents registered before it, in both directions, with no re-registration.
    function test_flip_appliesToAlreadyRegisteredAgents() public {
        _setFlag(true);
        vm.expectRevert(ISyndicateGovernor.ProposerNotOwner.selector);
        _propose(agent, address(0));

        _setFlag(false);
        uint256 id = _propose(agent, address(0));
        assertEq(governor.getProposal(id).proposer, agent, "lifted: agent proposes");
    }

    /// @notice A Draft opened while the flag was off cannot be approved into Pending once it is on.
    function test_flagOn_approveCollaborationRefused() public {
        uint256 id = _propose(agent, coAgent);
        _setFlag(true);
        vm.prank(coAgent);
        vm.expectRevert(ISyndicateGovernor.CollaborationDisabled.selector);
        governor.approveCollaboration(id);
    }
}

/// @notice The flag on the real factory: owner-only setter, event, packed slot, and the
///         governor `createSyndicate` minted reading it.
contract OwnerOnlyProposalsFactoryTest is Test {
    event OwnerOnlyProposalsUpdated(bool enabled);

    SyndicateFactory factory;
    SyndicateVault vault;
    SyndicateGovernor governor;
    MockAgentRegistry agentRegistry;
    ERC20Mock usdc;

    address owner = makeAddr("owner");
    address creator = makeAddr("creator");
    address agent = makeAddr("agent");
    address guardianRegistry = makeAddr("guardianRegistry");
    address swood = makeAddr("swood");

    function setUp() public {
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        agentRegistry = new MockAgentRegistry();
        vm.mockCall(address(this), abi.encodeWithSignature("agentRegistry()"), abi.encode(address(agentRegistry)));
        GovernorBeacon beacon = new GovernorBeacon(address(new SyndicateGovernor(24 hours, 1 hours)), owner);
        bytes memory init = abi.encodeCall(
            SyndicateFactory.initialize,
            (SyndicateFactory.InitParams({
                    owner: owner,
                    executorImpl: address(new BatchExecutorLib()),
                    vaultImpl: address(new SyndicateVault()),
                    agentRegistry: address(agentRegistry),
                    beacon: address(beacon),
                    protocolConfig: address(new ProtocolConfig(owner)),
                    managementFeeBps: 50,
                    guardianRegistry: guardianRegistry,
                    tierRegistry: address(new TierRegistry(owner))
                }))
        );
        factory = SyndicateFactory(address(new ERC1967Proxy(address(new SyndicateFactory()), init)));

        vm.mockCall(guardianRegistry, abi.encodeWithSelector(IGuardianRegistry.addGovernor.selector), "");
        vm.mockCall(guardianRegistry, abi.encodeWithSelector(IGuardianRegistry.swood.selector), abi.encode(swood));
        vm.mockCall(swood, abi.encodeWithSelector(IStakedWood.canCreateVault.selector), abi.encode(true));
        vm.mockCall(swood, abi.encodeWithSelector(IStakedWood.bindOwnerStake.selector), "");

        uint256 creatorId = agentRegistry.mint(creator);
        vm.prank(creator);
        (, address v) = factory.createSyndicate(
            creatorId,
            SyndicateFactory.SyndicateConfig({
                metadataURI: "ipfs://QmTest",
                asset: usdc,
                name: "Sponsored Vault",
                symbol: "sV",
                openDeposits: true,
                subdomain: "sponsored-vault"
            })
        );
        vault = SyndicateVault(payable(v));
        governor = SyndicateGovernor(factory.governorOf(v));

        uint256 agentId = agentRegistry.mint(agent);
        vm.prank(creator);
        vault.registerAgent(agentId, agent);
    }

    /// @notice Only the factory owner flips the flag, and each flip is logged.
    function test_setOwnerOnlyProposals_onlyOwnerAndEmits() public {
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, creator));
        factory.setOwnerOnlyProposals(true);
        assertFalse(factory.ownerOnlyProposals(), "unchanged");

        vm.expectEmit(address(factory));
        emit OwnerOnlyProposalsUpdated(true);
        vm.prank(owner);
        factory.setOwnerOnlyProposals(true);
        assertTrue(factory.ownerOnlyProposals(), "set");
    }

    /// @notice The flag packs into slot 21 beside `depositsRestricted`, and neither write moves the other.
    function test_flagPacksBesideDepositsRestricted() public {
        vm.startPrank(owner);
        factory.setOwnerOnlyProposals(true);
        vm.stopPrank();
        uint256 word = uint256(vm.load(address(factory), bytes32(uint256(21))));
        assertEq((word >> 168) & 0xff, 1, "ownerOnlyProposals at slot 21, offset 21");
        assertEq((word >> 160) & 0xff, 0, "depositsRestricted untouched");
        assertFalse(factory.depositsRestricted(), "depositsRestricted reads false");
    }

    /// @notice A governor the factory minted reads the factory's flag: a registered non-owner agent is refused.
    function test_factoryGovernor_refusesNonOwnerAgentWhenOn() public {
        vm.prank(owner);
        factory.setOwnerOnlyProposals(true);

        BatchExecutorLib.Call[] memory calls = new BatchExecutorLib.Call[](0);
        uint256[] memory caps = new uint256[](0);
        ISyndicateGovernor.CoProposer[] memory coProps = new ISyndicateGovernor.CoProposer[](0);
        ISyndicateGovernor.RiskEnvelope memory env_ = ISyndicateGovernor.RiskEnvelope(1, 0);
        vm.prank(agent);
        vm.expectRevert(ISyndicateGovernor.ProposerNotOwner.selector);
        governor.propose(address(vault), address(0), "", 1 days, env_, calls, caps, calls, caps, coProps);
    }
}
