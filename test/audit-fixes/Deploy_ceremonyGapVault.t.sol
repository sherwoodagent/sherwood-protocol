// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DeployAllFixture} from "../deploy/DeployAll.t.sol";
import {Checkpoint, Stage} from "../../script/robinhood-mainnet/DeployAll.s.sol";
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
/// @notice A vault created between run 1 and run 2 of the mainnet ceremony is wired by run 2
///         itself, and run 2 refuses (rather than reporting green) while it cannot wire one.
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

    function _create(Stack memory s, address who, string memory sub)
        internal
        returns (SyndicateVault vault, SyndicateGovernor gov, uint256 agentId)
    {
        SyndicateFactory factory = SyndicateFactory(s.core.factoryProxy);
        agentId = agents.mint(who);
        wood.mint(who, STAKE + factory.creationFee());
        vm.startPrank(who);
        wood.approve(s.core.swoodProxy, STAKE);
        StakedWood(s.core.swoodProxy).prepareOwnerStake(STAKE);
        wood.approve(address(factory), factory.creationFee());
        (, address v) = factory.createSyndicate(
            agentId,
            SyndicateFactory.SyndicateConfig({
                metadataURI: "ipfs://gap",
                asset: IERC20(address(usdg)),
                name: "Gap Vault",
                symbol: "GAPV",
                openDeposits: false,
                subdomain: sub
            })
        );
        vm.stopPrank();
        vault = SyndicateVault(payable(v));
        gov = SyndicateGovernor(factory.governorOf(v));
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

    function _assertWired(SyndicateFactory factory, SyndicateGovernor gov) internal view {
        assertEq(gov.exposureLedger(), factory.exposureLedger(), "gap governor: ledger");
        assertEq(gov.bondEscrow(), factory.bondEscrow(), "gap governor: escrow");
        assertEq(gov.tierRegistry(), factory.tierRegistry(), "gap governor: tier registry");
    }

    // ───────────────────────────── tests ─────────────────────────────

    /// @notice Run 2 wires the gap governor with no manual step, so the zero-approval
    ///         full-capital proposal now needs a bond and reverts `InsufficientApproveCoverage`.
    function test_gapVault_wiredByRun2_executeNeedsCoverage() public {
        Stack memory first = _runOne();
        address gapOwner = makeAddr("gapOwner");
        (SyndicateVault vault, SyndicateGovernor gov, uint256 agentId) = _create(first, gapOwner, "gapfund");
        assertEq(gov.exposureLedger(), address(0), "gap: unwired before run 2");

        Stack memory s = _runTwo(first);
        SyndicateFactory factory = SyndicateFactory(s.core.factoryProxy);
        assertTrue(factory.exposureLedger() != address(0), "factory issues the ledger");
        _assertWired(factory, gov);
        script.exposed_validateAll(s, _inputs(Posture.Mainnet), Checkpoint.Complete);
        assertTrue(script.stageOf(s, address(safe)) == Stage.Done, "stageOf == Done");

        address strat = _fund(s, vault, gapOwner, agentId, makeAddr("lp"));
        wood.mint(gapOwner, 5_000_000e18);
        vm.prank(gapOwner);
        wood.approve(s.proposerBondEscrow, type(uint256).max);
        uint256 pid = _propose(gov, vault, gapOwner, strat);
        assertGt(gov.getProposal(pid).proposerBondWood, 0, "bond locked");

        vm.warp(gov.getProposal(pid).voteEnd + 1);
        GuardianRegistry(s.core.registryProxy).openReview(address(gov), pid);
        vm.warp(gov.getProposal(pid).reviewEnd + 1);
        _refreshMarkets();
        vm.expectRevert(IExposureLedger.InsufficientApproveCoverage.selector);
        gov.executeProposal(pid);
        assertEq(usdg.balanceOf(address(vault)), DEPOSIT, "vault intact");
    }

    /// @notice A gap governor with an OPEN proposal cannot be wired, so run 2 reverts instead
    ///         of reporting green; once the proposal ends, re-running run 2 completes and wires it.
    function test_gapVault_openProposalAtRun2_ceremonyReverts_thenRerunWires() public {
        Stack memory first = _runOne();
        address gapOwner = makeAddr("gapOwner");
        (SyndicateVault vault, SyndicateGovernor gov, uint256 agentId) = _create(first, gapOwner, "gapfund");
        address strat = _fund(first, vault, gapOwner, agentId, makeAddr("lp"));
        uint256 pid = _propose(gov, vault, gapOwner, strat);

        _primeWoodFeed(first.woodUsdFeed);
        Inputs memory i = _inputs(Posture.Mainnet);
        vm.prank(deployer);
        vm.expectRevert(ISyndicateGovernor.ParamsFrozenDuringProposal.selector);
        script.deployAll(i);
        SyndicateFactory factory = SyndicateFactory(first.core.factoryProxy);
        assertEq(factory.exposureLedger(), address(0), "the reverted run left nothing behind");

        // Runbook remedy: let the proposal end, commit its state, re-run inside the cooldown.
        vm.warp(gov.getProposal(pid).executeBy + 1);
        gov.resolveProposalState(pid);
        assertEq(uint256(gov.getProposal(pid).state), uint256(ISyndicateGovernor.ProposalState.Expired));
        _primeWoodFeed(first.woodUsdFeed);
        Checkpoint cp;
        Stack memory s;
        (s, cp) = _runCeremony(Posture.Mainnet);
        assertTrue(cp == Checkpoint.Complete, "re-run completes");
        _assertWired(factory, gov);
        script.exposed_validateAll(s, i, Checkpoint.Complete);
    }

    /// @notice The Complete-stage validation refuses a live governor whose wiring lags the factory.
    function test_validateAll_refusesAnUnwiredGovernor() public {
        Stack memory first = _runOne();
        (, SyndicateGovernor gov,) = _create(first, makeAddr("gapOwner"), "gapfund");
        Stack memory s = _runTwo(first);
        // Simulate a governor the ceremony missed: clear its ledger slot as the factory.
        vm.prank(s.core.factoryProxy);
        gov.setExposureLedger(address(0));
        vm.expectRevert(bytes("governor #1.exposureLedger mismatch"));
        script.exposed_validateAll(s, _inputs(Posture.Mainnet), Checkpoint.Complete);
    }
}
