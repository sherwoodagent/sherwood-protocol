// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DeployAllFixture} from "../deploy/DeployAll.t.sol";
import {Checkpoint} from "../../script/robinhood-mainnet/DeployAll.s.sol";
import {DeploySherwood} from "../../script/Deploy.s.sol";
import {Posture, Inputs, Stack} from "../../script/robinhood-mainnet/DeployTypes.sol";
import {RobinhoodParams} from "../../script/robinhood-mainnet/RobinhoodParams.sol";

import {SyndicateFactory} from "../../src/SyndicateFactory.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {SyndicateGovernor} from "../../src/SyndicateGovernor.sol";
import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";
import {GuardianRegistry} from "../../src/GuardianRegistry.sol";
import {StakedWood} from "../../src/StakedWood.sol";
import {StrategyFactory} from "../../src/StrategyFactory.sol";
import {IExposureLedger} from "../../src/interfaces/IExposureLedger.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";

import {MockAgentRegistry} from "../mocks/MockAgentRegistry.sol";

/// @dev Minimal conforming strategy: answers vault()/proposer()/executed() so the
///      permissionless `StrategyFactory.registerStrategy` accepts it. Holds no funds.
contract GapInertStrategy {
    address public vault;
    address public proposer;
    bool public executed;

    constructor(address v, address p) {
        vault = v;
        proposer = p;
    }
}

/// @title Deploy_ceremonyGapVault — audit 2026-10-01 V1-05 regression
/// @notice The Mainnet factory is initialised with a closed agent-registry sentinel, so no vault
///         can be created during run 1 or the gap; run 2's last step opens creation and every vault
///         is wired at creation.
contract DeployCeremonyGapVaultTest is DeployAllFixture {
    uint256 internal constant DEPOSIT = 10_000e6; // $10k USDG
    uint256 internal constant STAKE = 10_000e18; // RobinhoodParams.MIN_OWNER_STAKE

    MockAgentRegistry internal agents;

    function setUp() public {
        _stageCeremony();
        vm.etch(RobinhoodParams.AGENT_REGISTRY, type(MockAgentRegistry).runtimeCode);
        agents = MockAgentRegistry(RobinhoodParams.AGENT_REGISTRY);
    }

    // ───────────────────────────── helpers ─────────────────────────────

    /// @dev An outsider with an agent identity, a prepared owner stake and `feeWood` WOOD,
    ///      approving the factory for everything it holds.
    function _prepareCreator(Stack memory s, address who, uint256 feeWood) internal returns (uint256 agentId) {
        agentId = agents.mint(who);
        wood.mint(who, STAKE + feeWood);
        vm.startPrank(who);
        wood.approve(s.core.swoodProxy, STAKE);
        StakedWood(s.core.swoodProxy).prepareOwnerStake(STAKE);
        wood.approve(s.core.factoryProxy, type(uint256).max);
        vm.stopPrank();
    }

    function _config(string memory sub) internal view returns (SyndicateFactory.SyndicateConfig memory) {
        return SyndicateFactory.SyndicateConfig({
            metadataURI: "ipfs://gap",
            asset: IERC20(address(usdg)),
            name: "Gap Vault",
            symbol: "GAPV",
            openDeposits: false,
            subdomain: sub
        });
    }

    function _create(Stack memory s, address who, string memory sub)
        internal
        returns (SyndicateVault vault, SyndicateGovernor gov, uint256 agentId)
    {
        SyndicateFactory factory = SyndicateFactory(s.core.factoryProxy);
        agentId = _prepareCreator(s, who, factory.creationFee());
        vm.prank(who);
        (, address v) = factory.createSyndicate(agentId, _config(sub));
        vault = SyndicateVault(payable(v));
        gov = SyndicateGovernor(factory.governorOf(v));
    }

    /// @dev Asserts `who` (identity, prepared stake, the fee in hand) cannot create: the closed
    ///      sentinel registry has no code, so the identity check reverts with empty data.
    function _assertCreationClosed(Stack memory st, address who) internal {
        SyndicateFactory factory = SyndicateFactory(st.core.factoryProxy);
        assertEq(address(factory.agentRegistry()), RobinhoodParams.AGENT_REGISTRY_CLOSED, "closed sentinel");
        uint256 agentId = _prepareCreator(st, who, RobinhoodParams.INVITE_ONLY_CREATION_FEE);
        vm.prank(who);
        vm.expectRevert(bytes(""));
        factory.createSyndicate(agentId, _config("gapfund"));
        assertEq(factory.syndicateCount(), 0, "no vault predates the coverage layer");
    }

    function _fund(Stack memory s, SyndicateVault vault, address owner_, uint256 agentId, address lp)
        internal
        returns (address strat)
    {
        vm.startPrank(owner_);
        vault.registerAgent(agentId, owner_);
        vault.approveDepositor(lp);
        vm.stopPrank();
        usdg.mint(lp, DEPOSIT);
        vm.startPrank(lp);
        usdg.approve(address(vault), DEPOSIT);
        vault.deposit(DEPOSIT, lp);
        vm.stopPrank();
        strat = address(new GapInertStrategy(address(vault), owner_));
        StrategyFactory(s.strategyFactory).registerStrategy(strat);
        vm.warp(vm.getBlockTimestamp() + 1);
    }

    /// @dev Full-TVL asset transfer out: uncertified ⇒ tier 2, full notional coverage.
    function _propose(SyndicateGovernor gov, SyndicateVault vault, address owner_, address strat)
        internal
        returns (uint256 pid)
    {
        uint256 maxCapital = vault.totalAssets();
        BatchExecutorLib.Call[] memory exec = new BatchExecutorLib.Call[](1);
        exec[0] = BatchExecutorLib.Call({
            target: address(usdg), data: abi.encodeCall(IERC20.transfer, (owner_, maxCapital)), value: 0
        });
        uint256[] memory execCaps = new uint256[](1);
        execCaps[0] = maxCapital;
        BatchExecutorLib.Call[] memory settle = new BatchExecutorLib.Call[](1);
        settle[0] =
            BatchExecutorLib.Call({target: address(usdg), data: abi.encodeCall(IERC20.approve, (strat, 0)), value: 0});
        uint256[] memory settleCaps = new uint256[](1);

        vm.prank(owner_);
        pid = gov.propose(
            address(vault),
            strat,
            "ipfs://gap-proposal",
            1 days,
            ISyndicateGovernor.RiskEnvelope({maxCapital: maxCapital, maxDrawdownBps: 10_000}),
            exec,
            execCaps,
            settle,
            settleCaps,
            new ISyndicateGovernor.CoProposer[](0)
        );
    }

    function _runOne() internal returns (Stack memory first) {
        vm.chainId(MAINNET_CHAIN_ID);
        Checkpoint cp;
        (first, cp) = _runCeremony(Posture.Mainnet);
        assertTrue(cp == Checkpoint.AwaitingWoodFeed, "run 1 stops at the feed gate");
    }

    function _runTwo(Stack memory first) internal returns (Stack memory s) {
        _primeWoodFeed(first.woodUsdFeed);
        Checkpoint cp;
        (s, cp) = _runCeremony(Posture.Mainnet);
        assertTrue(cp == Checkpoint.Complete, "run 2 completes");
    }

    // ───────────────────────────── tests ─────────────────────────────

    /// @notice Right after `deployCore` — the factory's own initialisation, before anything else
    ///         in run 1 — an outsider with a prepared stake and an agent identity cannot create.
    function test_closedFromFactoryInit() public {
        vm.chainId(MAINNET_CHAIN_ID);
        DeploySherwood.Config memory cfg = script.exposed_coreConfig(_inputs(Posture.Mainnet));
        vm.prank(deployer);
        DeploySherwood.Deployed memory core = script.deployCore(cfg);
        Stack memory st;
        st.core = core;
        _assertCreationClosed(st, makeAddr("frontrunner"));
    }

    /// @notice Still closed after run 1 completes, including for a creator the deployer SPONSORED.
    function test_gap_closedAfterRun1_evenWhenSponsored() public {
        Stack memory first = _runOne();
        _assertCreationClosed(first, makeAddr("gapOwner"));

        address sponsored = makeAddr("sponsored");
        vm.prank(deployer);
        SyndicateFactory(first.core.factoryProxy).setCreationSponsored(sponsored, true);
        _assertCreationClosed(first, sponsored);
    }

    /// @notice After run 2 the registry is the real one, creation works at the invite-only fee,
    ///         the governor is wired at creation, and a zero-approval full-capital proposal reverts.
    function test_afterRun2_creationOpen_governorWired_executeNeedsCoverage() public {
        Stack memory s = _runTwo(_runOne());
        SyndicateFactory factory = SyndicateFactory(s.core.factoryProxy);
        assertEq(address(factory.agentRegistry()), RobinhoodParams.AGENT_REGISTRY, "run 2 opens creation");
        assertEq(factory.creationFee(), RobinhoodParams.INVITE_ONLY_CREATION_FEE, "invite-only fee");

        address owner_ = makeAddr("postOwner");
        (SyndicateVault vault, SyndicateGovernor gov, uint256 agentId) = _create(s, owner_, "postfund");
        assertEq(wood.balanceOf(address(safe)), RobinhoodParams.INVITE_ONLY_CREATION_FEE, "fee paid to the Safe");
        assertTrue(factory.exposureLedger() != address(0), "factory issues the ledger");
        assertEq(gov.exposureLedger(), factory.exposureLedger(), "ledger wired at creation");
        assertEq(gov.bondEscrow(), factory.bondEscrow(), "escrow wired at creation");

        address strat = _fund(s, vault, owner_, agentId, makeAddr("lp"));
        wood.mint(owner_, 5_000_000e18);
        vm.prank(owner_);
        wood.approve(s.proposerBondEscrow, type(uint256).max);
        uint256 pid = _propose(gov, vault, owner_, strat);
        assertGt(gov.getProposal(pid).proposerBondWood, 0, "bond locked");

        vm.warp(gov.getProposal(pid).voteEnd + 1);
        GuardianRegistry(s.core.registryProxy).openReview(address(gov), pid);
        vm.warp(gov.getProposal(pid).reviewEnd + 1);
        _refreshMarkets();
        vm.expectRevert(IExposureLedger.InsufficientApproveCoverage.selector);
        gov.executeProposal(pid);
        assertEq(usdg.balanceOf(address(vault)), DEPOSIT, "vault intact");
    }

    /// @notice Validation at `AwaitingWoodFeed` refuses a non-sentinel registry and any syndicate;
    ///         run 2 itself refuses to open creation over an existing syndicate.
    function test_validateAll_awaitingFeed_refusesOpenRegistryOrSyndicates() public {
        Stack memory first = _runOne();
        Inputs memory i = _inputs(Posture.Mainnet);
        SyndicateFactory factory = SyndicateFactory(first.core.factoryProxy);
        script.exposed_validateAll(first, i, Checkpoint.AwaitingWoodFeed);

        vm.prank(deployer);
        factory.setAgentRegistry(RobinhoodParams.AGENT_REGISTRY);
        vm.expectRevert(bytes("factory.agentRegistry mismatch"));
        script.exposed_validateAll(first, i, Checkpoint.AwaitingWoodFeed);

        _create(first, makeAddr("slipped"), "slipped");
        vm.prank(deployer);
        factory.setAgentRegistry(RobinhoodParams.AGENT_REGISTRY_CLOSED);
        vm.expectRevert(bytes("factory.syndicateCount != 0 before creation opened"));
        script.exposed_validateAll(first, i, Checkpoint.AwaitingWoodFeed);

        _primeWoodFeed(first.woodUsdFeed);
        vm.prank(deployer);
        vm.expectRevert(bytes("a syndicate exists before creation was opened"));
        script.deployAll(i);
    }

    /// @notice Negative pin of the PR #368 review stall: a gap owner who would create a vault,
    ///         execute a never-settling proposal and freeze its governor cannot even create one,
    ///         and run 2 completes.
    function test_gap_reviewStallCannotBeSetUp() public {
        Stack memory first = _runOne();
        _assertCreationClosed(first, makeAddr("staller"));
        Stack memory s = _runTwo(first);
        script.exposed_validateAll(s, _inputs(Posture.Mainnet), Checkpoint.Complete);
    }

    /// @notice A fork completes in one run with the real registry, and a re-run sends nothing new.
    function test_fork_realRegistryFromTheStart_rerunIsQuiet() public {
        vm.chainId(FORK_CHAIN_ID);
        (Stack memory s,) = _runCeremony(Posture.Fork);
        SyndicateFactory factory = SyndicateFactory(s.core.factoryProxy);
        assertEq(address(factory.agentRegistry()), RobinhoodParams.AGENT_REGISTRY, "fork: real registry");
        (, Checkpoint cp) = _runCeremony(Posture.Fork);
        assertTrue(cp == Checkpoint.Complete, "re-run completes");
        assertEq(address(factory.agentRegistry()), RobinhoodParams.AGENT_REGISTRY, "unchanged");
    }
}
