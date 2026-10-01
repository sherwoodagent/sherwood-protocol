// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {DeployAllFixture} from "../deploy/DeployAll.t.sol";
import {Checkpoint} from "../../script/robinhood-mainnet/DeployAll.s.sol";
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
/// @notice Creation is closed between Mainnet run 1 and run 2 (unpayable fee), so no vault can
///         predate the coverage layer; run 2 opens it, and every vault is wired at creation.
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

    /// @dev Asserts an outsider holding the invite-only fee cannot create in the gap.
    function _assertCreationClosed(Stack memory first, address who) internal {
        SyndicateFactory factory = SyndicateFactory(first.core.factoryProxy);
        uint256 agentId = _prepareCreator(first, who, RobinhoodParams.INVITE_ONLY_CREATION_FEE);
        uint256 bal = wood.balanceOf(who);
        vm.prank(who);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, who, bal, RobinhoodParams.CREATION_CLOSED_FEE
            )
        );
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

    /// @notice After run 1 an outsider with WOOD, a prepared owner stake and an agent identity
    ///         cannot create a syndicate: the fee is unpayable until run 2.
    function test_gap_creationClosedAfterRun1() public {
        Stack memory first = _runOne();
        assertEq(SyndicateFactory(first.core.factoryProxy).creationFee(), RobinhoodParams.CREATION_CLOSED_FEE, "closed");
        _assertCreationClosed(first, makeAddr("gapOwner"));
    }

    /// @notice After run 2 the fee is the invite-only fee, creation works, the governor is wired
    ///         at creation, and a zero-approval full-capital proposal reverts at execute.
    function test_afterRun2_creationOpen_governorWired_executeNeedsCoverage() public {
        Stack memory s = _runTwo(_runOne());
        SyndicateFactory factory = SyndicateFactory(s.core.factoryProxy);
        assertEq(factory.creationFee(), RobinhoodParams.INVITE_ONLY_CREATION_FEE, "run 2 opens creation");
        assertEq(factory.creationFeeRecipient(), address(safe), "fee to the Safe");

        address owner_ = makeAddr("postOwner");
        (SyndicateVault vault, SyndicateGovernor gov, uint256 agentId) = _create(s, owner_, "postfund");
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

    /// @notice Validation at `AwaitingWoodFeed` refuses any fee but the closed one.
    function test_validateAll_awaitingFeed_refusesAnOpenFee() public {
        Stack memory first = _runOne();
        Inputs memory i = _inputs(Posture.Mainnet);
        script.exposed_validateAll(first, i, Checkpoint.AwaitingWoodFeed);

        vm.prank(deployer);
        SyndicateFactory(first.core.factoryProxy)
            .setCreationFee(i.wood, RobinhoodParams.INVITE_ONLY_CREATION_FEE, address(safe));
        vm.expectRevert(bytes("factory.creationFee"));
        script.exposed_validateAll(first, i, Checkpoint.AwaitingWoodFeed);
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
}
