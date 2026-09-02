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
import {GovEnvelope} from "../helpers/GovEnvelope.sol";
import {deployTierRegistry} from "../helpers/TierRegistryFixture.sol";

/// @title Governor_she215OwnerBondGate
/// @notice SHE-215 (audit High), governor half — the enforcement the
///         `claimUnstakeOwner` natspec had always claimed and never had.
///
///         `StakedWood.claimUnstakeOwner` documented that after a claim "the
///         vault then enters grace-period state and new proposals cannot be
///         created until the slot is re-funded". `grep gracePeriod src/`
///         returned that comment and nothing else: `_propose` gated on the
///         vault address, `isAgent`, and the open-proposal lock, and read no
///         owner bond at all; `executeProposal` gated on Approved, the active
///         proposal and the cooldown, and read no owner bond either. The only
///         enforcers in the repo were `GovernorEmergency` and
///         `SyndicateFactory.rotateOwner`.
///
///         `isAgent` is `_agents[a].active` and is independent of the owner's
///         stake, so an owner who is ALSO a registered agent could request
///         their unstake in a quiet gap (`requestUnstakeOwner` only refuses
///         while a proposal is open), sit out the cooldown, claim the bond
///         (`claimUnstakeOwner`'s re-check only refuses while a proposal is
///         open), and then propose AND execute a capital-moving strategy on a
///         vault with nothing slashable behind it.
///
/// @dev    The predicate itself — bind / request / cancel / claim / slash — is
///         pinned against a real `StakedWood` in
///         `StakedWood_she215OwnerBondLive.t.sol`, including the registry
///         passthrough. This suite drives the governor against
///         `MockRegistryMinimal`, whose `setOwnerBondLive` stands in for those
///         sWOOD transitions, so the two halves are pinned independently.
contract GovernorShe215OwnerBondGateTest is Test {
    SyndicateGovernor internal governor;
    ProtocolConfig internal protocolConfig;
    SyndicateVault internal vault;
    BatchExecutorLib internal executorLib;
    ERC20Mock internal usdc;
    ERC20Mock internal targetToken;
    MockAgentRegistry internal agentRegistry;
    MockRegistryMinimal internal guardianRegistry;

    ISyndicateGovernor.RiskEnvelope internal permissiveEnv;

    address internal owner = makeAddr("owner");
    address internal agent = makeAddr("agent");
    address internal lp1 = makeAddr("lp1");
    address internal lp2 = makeAddr("lp2");

    uint256 internal constant VOTING_PERIOD = 1 days;
    uint256 internal constant EXECUTION_WINDOW = 1 days;
    uint256 internal constant STRATEGY_DURATION = 7 days;

    function setUp() public {
        protocolConfig = new ProtocolConfig(owner);
        vm.prank(owner);
        protocolConfig.setProtocolFeeRecipient(owner);

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
                    managementFeeBps: 0
                }))
        );
        vault = SyndicateVault(payable(address(new ERC1967Proxy(address(vaultImpl), vaultInit))));

        // THE EXPLOIT'S PRECONDITION, IN ONE LINE: the vault owner is also a
        // registered agent. `isAgent` is independent of the owner bond, so
        // nothing about claiming the bond ever revoked this.
        // Minted OUTSIDE the prank: an argument-position external call would
        // consume the one-shot prank before `registerAgent` is reached.
        uint256 agentNftId = agentRegistry.mint(agent);
        vm.prank(owner);
        vault.registerAgent(agentNftId, agent);

        SyndicateGovernor govImpl = new SyndicateGovernor(24 hours, 1 hours);
        bytes memory govInit = abi.encodeCall(
            SyndicateGovernor.initialize,
            (
                address(vault),
                address(guardianRegistry),
                address(protocolConfig),
                address(this),
                address(deployTierRegistry(address(this))),
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
        vm.mockCall(address(this), abi.encodeWithSignature("priceRouter()"), abi.encode(address(0)));

        usdc.mint(lp1, 100_000e6);
        usdc.mint(lp2, 100_000e6);
        vm.startPrank(lp1);
        usdc.approve(address(vault), 60_000e6);
        vault.deposit(60_000e6, lp1);
        vm.stopPrank();
        vm.startPrank(lp2);
        usdc.approve(address(vault), 40_000e6);
        vault.deposit(40_000e6, lp2);
        vm.stopPrank();

        vm.warp(vm.getBlockTimestamp() + 1);
        permissiveEnv = GovEnvelope.permissive(address(vault));
    }

    // ── helpers ──

    function _executeCalls() internal view returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({
            target: address(usdc), data: abi.encodeCall(usdc.approve, (address(targetToken), 50_000e6)), value: 0
        });
    }

    function _settlementCalls() internal view returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({
            target: address(usdc), data: abi.encodeCall(usdc.approve, (address(targetToken), 0)), value: 0
        });
    }

    function _propose() internal returns (uint256 proposalId) {
        permissiveEnv = GovEnvelope.permissive(address(vault));
        BatchExecutorLib.Call[] memory ex = _executeCalls();
        BatchExecutorLib.Call[] memory st = _settlementCalls();
        vm.prank(agent);
        proposalId = governor.propose(
            address(vault),
            address(0),
            "ipfs://she215",
            STRATEGY_DURATION,
            permissiveEnv,
            ex,
            GovEnvelope.defaultCaps(permissiveEnv.maxCapital, ex.length),
            st,
            GovEnvelope.defaultCaps(permissiveEnv.maxCapital, st.length),
            new ISyndicateGovernor.CoProposer[](0)
        );
        vm.warp(vm.getBlockTimestamp() + 1);
    }

    function _approve(uint256 proposalId) internal {
        vm.prank(lp1);
        governor.vote(proposalId, ISyndicateGovernor.VoteType.For);
        vm.prank(lp2);
        governor.vote(proposalId, ISyndicateGovernor.VoteType.For);
        vm.warp(vm.getBlockTimestamp() + VOTING_PERIOD + 1);
    }

    // =====================================================================
    // propose
    // =====================================================================

    /// @notice THE CONTROL. Nothing about this fix narrows the ordinary lane:
    ///         a bonded vault proposes exactly as before.
    function test_propose_succeedsWhileTheOwnerBondIsLive() public {
        uint256 proposalId = _propose();
        assertGt(proposalId, 0, "a bonded vault still proposes");
    }

    /// @notice THE FINDING, PROPOSE LEG. With the owner's exit in flight — or
    ///         the bond already claimed or slashed, all three of which
    ///         `ownerBondLive` reports identically — `propose` must fail
    ///         CLOSED with a named error rather than mint a proposal against
    ///         collateral that is leaving or gone.
    ///
    /// @dev    MUTATION-CHECKED: deleting the `ownerBondLive` gate from
    ///         `_propose` makes this call succeed and returns the finding in
    ///         full — an unbonded vault opening a capital-moving proposal, with
    ///         only `GovernorEmergency`'s bond gate left anywhere in the
    ///         protocol.
    function test_propose_revertsWhenTheOwnerBondIsNotLive() public {
        guardianRegistry.setOwnerBondLive(false);

        permissiveEnv = GovEnvelope.permissive(address(vault));
        BatchExecutorLib.Call[] memory ex = _executeCalls();
        BatchExecutorLib.Call[] memory st = _settlementCalls();
        vm.prank(agent);
        vm.expectRevert(ISyndicateGovernor.OwnerBondNotLive.selector);
        governor.propose(
            address(vault),
            address(0),
            "ipfs://she215",
            STRATEGY_DURATION,
            permissiveEnv,
            ex,
            GovEnvelope.defaultCaps(permissiveEnv.maxCapital, ex.length),
            st,
            GovEnvelope.defaultCaps(permissiveEnv.maxCapital, st.length),
            new ISyndicateGovernor.CoProposer[](0)
        );
    }

    /// @notice THE GRACE PERIOD ENDS WHEN THE SLOT IS RE-FUNDED — the second
    ///         half of the sentence the natspec always carried. Restoring the
    ///         bond (`cancelUnstakeOwner` on a request still in flight, or
    ///         `rotateOwner` -> `transferOwnerStakeSlot` on a claimed one)
    ///         reopens the lane. The gate is a state check, not a latch.
    function test_propose_reopensOnceTheBondIsRestored() public {
        guardianRegistry.setOwnerBondLive(false);
        guardianRegistry.setOwnerBondLive(true);

        uint256 proposalId = _propose();
        assertGt(proposalId, 0, "a re-funded slot proposes again");
    }

    // =====================================================================
    // executeProposal
    // =====================================================================

    /// @notice THE FINDING, EXECUTE LEG — and the reason the propose gate is
    ///         not sufficient on its own. `requestUnstakeOwner` refuses only
    ///         while a proposal is open, but the vote and the review period sit
    ///         between propose and execute, so an owner can start their exit
    ///         before the proposal that is about to move capital even exists
    ///         and clear the cooldown while it is still being voted on.
    ///         Re-asserting at the point of use is what closes the class.
    ///
    /// @dev    MUTATION-CHECKED: deleting the gate from `executeProposal`
    ///         leaves this execution succeeding — capital deployed by a batch
    ///         with no owner bond behind it, which is exactly the state the
    ///         emergency lane refuses to enter.
    function test_executeProposal_revertsWhenTheBondLeavesAfterApproval() public {
        uint256 proposalId = _propose();
        _approve(proposalId);

        // The bond exits between approval and execution.
        guardianRegistry.setOwnerBondLive(false);

        vm.expectRevert(ISyndicateGovernor.OwnerBondNotLive.selector);
        governor.executeProposal(proposalId);
    }

    /// @notice THE CONTROL FOR THE EXECUTE LEG: the same proposal executes
    ///         normally while the bond stays live, so the revert above is
    ///         attributable to the bond and to nothing else in the path.
    function test_executeProposal_succeedsWhileTheOwnerBondIsLive() public {
        uint256 proposalId = _propose();
        _approve(proposalId);

        governor.executeProposal(proposalId);
        assertEq(governor.getActiveProposal(), proposalId, "executed with a live bond");
    }

    /// @notice AND IT RECOVERS. A proposal blocked by a departing bond is not
    ///         bricked: re-funding the slot inside the execution window lets it
    ///         through, so an owner who reverses course does not strand an
    ///         approved proposal.
    function test_executeProposal_recoversWhenTheBondIsRestoredInWindow() public {
        uint256 proposalId = _propose();
        _approve(proposalId);

        guardianRegistry.setOwnerBondLive(false);
        vm.expectRevert(ISyndicateGovernor.OwnerBondNotLive.selector);
        governor.executeProposal(proposalId);

        guardianRegistry.setOwnerBondLive(true);
        governor.executeProposal(proposalId);
        assertEq(governor.getActiveProposal(), proposalId, "the approved proposal was never bricked");
    }
}
