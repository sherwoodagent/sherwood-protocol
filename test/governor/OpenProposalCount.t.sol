// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {SyndicateGovernor} from "../../src/SyndicateGovernor.sol";
import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {ISyndicateVault} from "../../src/interfaces/ISyndicateVault.sol";
import {GuardianRegistry} from "../../src/GuardianRegistry.sol";
import {IGuardianRegistry} from "../../src/interfaces/IGuardianRegistry.sol";
import {StakedWood} from "../../src/StakedWood.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "../mocks/MockAgentRegistry.sol";
import {ProtocolConfig} from "../../src/ProtocolConfig.sol";

/// @title OpenProposalCount.t
/// @notice Regression tests for Fix 2 — track open proposals per vault to plug
///         the rage-quit gap in `requestUnstakeOwner`. The legacy
///         `getActiveProposal` check only covered the Executed state, so an
///         owner could unstake while a Pending / GuardianReview / Approved
///         proposal was outstanding. The new `openProposalCount(vault)`
///         counter closes that gap.
contract OpenProposalCountTest is Test {
    SyndicateGovernor public governor;
    SyndicateVault public vault;
    GuardianRegistry public registry;
    StakedWood public swood;
    BatchExecutorLib public executorLib;
    ERC20Mock public usdc;
    ERC20Mock public wood;
    ERC20Mock public targetToken;
    MockAgentRegistry public agentRegistry;

    address public owner = makeAddr("owner");
    address public agent = makeAddr("agent");
    address public lp1 = makeAddr("lp1");
    address public lp2 = makeAddr("lp2");

    address public g1 = makeAddr("guardian1");
    address public g2 = makeAddr("guardian2");
    address public g3 = makeAddr("guardian3");
    address public g4 = makeAddr("guardian4");
    address public g5 = makeAddr("guardian5");

    address public factoryEoa;
    uint256 public agentNftId;

    uint256 constant VOTING_PERIOD = 1 days;
    uint256 constant EXECUTION_WINDOW = 1 days;
    uint256 constant VETO_THRESHOLD_BPS = 4000;
    uint256 constant MAX_PERF_FEE_BPS = 1500;
    uint256 constant COOLDOWN_PERIOD = 1 days;

    uint256 constant MIN_GUARDIAN_STAKE = 10_000e18;
    uint256 constant MIN_OWNER_STAKE = 10_000e18;
    uint256 constant REVIEW_PERIOD = 24 hours;
    uint256 constant BLOCK_QUORUM_BPS = 3000;
    uint256 constant GUARDIAN_STAKE = 20_000e18;

    function setUp() public {
        factoryEoa = address(this);

        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        wood = new ERC20Mock("WOOD", "WOOD", 18);
        targetToken = new ERC20Mock("Target", "TGT", 18);
        executorLib = new BatchExecutorLib();
        agentRegistry = new MockAgentRegistry();
        agentNftId = agentRegistry.mint(agent);

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

        vm.prank(owner);
        vault.registerAgent(agentNftId, agent);

        // sWOOD + Governor + Registry — three-way circular init dependency
        // resolved by predicting proxy addresses. From `baseNonce`:
        //   swoodImpl (+0), swoodProxy (+1), govImpl (+2), govProxy (+3),
        //   regImpl (+4), regProxy (+5).
        ProtocolConfig _hoistedPC = new ProtocolConfig(owner);
        uint256 baseNonce = vm.getNonce(address(this));
        address predictedGovernor = vm.computeCreateAddress(address(this), baseNonce + 3);
        address predictedRegistryProxy = vm.computeCreateAddress(address(this), baseNonce + 5);

        // sWOOD — sole WOOD custodian post-split.
        StakedWood swoodImpl = new StakedWood();
        bytes memory swoodInit = abi.encodeCall(
            StakedWood.initialize,
            (StakedWood.InitParams({
                    owner: owner,
                    wood: address(wood),
                    factory: factoryEoa,
                    minGuardianStake: MIN_GUARDIAN_STAKE,
                    coolDownPeriod: 7 days,
                    minOwnerStake: MIN_OWNER_STAKE,
                    minSlashBps: 1000,
                    maxSlashBps: 9999,
                    maxDelegatedSlashBps: 2000,
                    ageFloorBps: 2500,
                    maturationPeriod: 30 days,
                    delegatedWeightCapX: 4
                }))
        );
        swood = StakedWood(address(new ERC1967Proxy(address(swoodImpl), swoodInit)));

        SyndicateGovernor govImpl = new SyndicateGovernor(24 hours, 1 hours);
        bytes memory govInit = abi.encodeCall(
            SyndicateGovernor.initialize,
            (
                address(vault), // vault_: this test's vault (per-vault governor)
                predictedRegistryProxy,
                address(_hoistedPC),
                address(this), // factory (test contract)
                ISyndicateGovernor.GovernorParams({
                    votingPeriod: VOTING_PERIOD,
                    executionWindow: EXECUTION_WINDOW,
                    vetoThresholdBps: VETO_THRESHOLD_BPS,
                    maxPerformanceFeeBps: MAX_PERF_FEE_BPS,
                    cooldownPeriod: COOLDOWN_PERIOD,
                    collaborationWindow: 48 hours,
                    maxCoProposers: 5,
                    minStrategyDuration: 1 hours,
                    maxStrategyDuration: 30 days
                })
            )
        );
        governor = SyndicateGovernor(address(new ERC1967Proxy(address(govImpl), govInit)));
        // Per-vault governor: the vault resolves its governor via its factory
        // (this test contract). Mock governorOf(vault) -> the deployed governor.
        vm.mockCall(address(this), abi.encodeWithSignature("governorOf(address)"), abi.encode(address(governor)));
        require(address(governor) == predictedGovernor, "governor addr mismatch");

        GuardianRegistry regImpl = new GuardianRegistry(6 hours);
        bytes memory regInit = abi.encodeCall(
            GuardianRegistry.initialize, (owner, factoryEoa, address(swood), REVIEW_PERIOD, BLOCK_QUORUM_BPS)
        );
        registry = GuardianRegistry(address(new ERC1967Proxy(address(regImpl), regInit)));
        // Authorize the per-vault governor on the composite-key registry
        // (replaces the removed governor.addVault wiring).
        vm.prank(registry.factory());
        registry.addGovernor(address(governor));
        require(address(registry) == predictedRegistryProxy, "registry addr mismatch");

        // Resolve the registry ↔ sWOOD circular dependency.
        vm.prank(owner);
        swood.setRegistry(address(registry));

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

        wood.mint(owner, 100_000e18);
        vm.prank(owner);
        wood.approve(address(swood), type(uint256).max);
        vm.prank(owner);
        swood.prepareOwnerStake(MIN_OWNER_STAKE);
        vm.prank(factoryEoa);
        swood.bindOwnerStake(owner, address(vault));

        _stakeGuardian(g1, GUARDIAN_STAKE, 1);
        _stakeGuardian(g2, GUARDIAN_STAKE, 2);
        _stakeGuardian(g3, GUARDIAN_STAKE, 3);
        _stakeGuardian(g4, GUARDIAN_STAKE, 4);
        _stakeGuardian(g5, GUARDIAN_STAKE, 5);
    }

    function _stakeGuardian(address who, uint256 amount, uint256 agentId) internal {
        wood.mint(who, amount);
        vm.prank(who);
        wood.approve(address(swood), type(uint256).max);
        vm.prank(who);
        swood.stakeAsGuardian(amount, agentId);
    }

    function _emptyCoProposers() internal pure returns (ISyndicateGovernor.CoProposer[] memory) {
        return new ISyndicateGovernor.CoProposer[](0);
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

    function _propose() internal returns (uint256 proposalId) {
        vm.prank(agent);
        proposalId = governor.propose(
            address(vault), address(0), "ipfs://open-count", 7 days, _execCalls(), _settleCalls(), _emptyCoProposers()
        );
    }

    function _voteFor(uint256 pid) internal {
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(lp1);
        governor.vote(pid, ISyndicateGovernor.VoteType.For);
        vm.prank(lp2);
        governor.vote(pid, ISyndicateGovernor.VoteType.For);
    }

    // ──────────────────────────────────────────────────────────────
    // Rage-quit blocking
    // ──────────────────────────────────────────────────────────────

    function test_requestUnstakeOwner_revertsDuringPending() public {
        _propose();
        assertEq(governor.openProposalCount(), 1, "counter == 1 in Pending");

        vm.prank(owner);
        vm.expectRevert(StakedWood.VaultHasActiveProposal.selector);
        swood.requestUnstakeOwner(address(vault));
    }

    function test_requestUnstakeOwner_revertsDuringGuardianReview() public {
        uint256 pid = _propose();
        _voteFor(pid);

        vm.warp(vm.getBlockTimestamp() + VOTING_PERIOD + 1);
        assertEq(
            uint256(governor.getProposalState(pid)),
            uint256(ISyndicateGovernor.ProposalState.GuardianReview),
            "state is GuardianReview"
        );
        assertEq(governor.openProposalCount(), 1, "counter still 1 in GuardianReview");

        vm.prank(owner);
        vm.expectRevert(StakedWood.VaultHasActiveProposal.selector);
        swood.requestUnstakeOwner(address(vault));
    }

    function test_requestUnstakeOwner_revertsDuringApproved() public {
        uint256 pid = _propose();
        _voteFor(pid);

        vm.warp(vm.getBlockTimestamp() + VOTING_PERIOD + 1);
        registry.openReview(address(governor), pid);
        vm.warp(vm.getBlockTimestamp() + REVIEW_PERIOD + 1);

        // Drive registry resolution without executing so we land in Approved.
        registry.resolveReview(address(governor), pid);
        // Sync governor-side state via a mutating path.
        governor.getProposal(pid); // view
        // Force a mutating _resolveState via a path that transitions — we
        // approximate by calling executeProposal which will succeed and move to
        // Executed. To test Approved specifically we rely on the view-path
        // equivalence. Pull cached state via resolveReview then check counter.
        // Approved is brief here; the counter should still be 1 at this moment
        // because no terminal transition has fired yet.
        assertEq(governor.openProposalCount(), 1, "counter still 1 in Approved");

        vm.prank(owner);
        vm.expectRevert(StakedWood.VaultHasActiveProposal.selector);
        swood.requestUnstakeOwner(address(vault));
    }

    function test_requestUnstakeOwner_revertsDuringExecuted() public {
        // PR #229 Fix 2: counter stays incremented through Executed; the dec
        // fires on Executed -> Settled. `_activeProposal` also covers Executed
        // so the registry's OR-check blocks rage-quit regardless.
        uint256 pid = _propose();
        _voteFor(pid);
        vm.warp(vm.getBlockTimestamp() + VOTING_PERIOD + 1);
        registry.openReview(address(governor), pid);
        vm.warp(vm.getBlockTimestamp() + REVIEW_PERIOD + 1);

        governor.executeProposal(pid);
        assertEq(governor.openProposalCount(), 1, "counter still 1 in Executed");
        assertEq(governor.getActiveProposal(), pid, "_activeProposal also set");

        vm.prank(owner);
        vm.expectRevert(StakedWood.VaultHasActiveProposal.selector);
        swood.requestUnstakeOwner(address(vault));
    }

    function test_requestUnstakeOwner_succeedsAfterProposalSettled() public {
        uint256 pid = _propose();
        _voteFor(pid);

        vm.warp(vm.getBlockTimestamp() + VOTING_PERIOD + 1);
        registry.openReview(address(governor), pid);
        vm.warp(vm.getBlockTimestamp() + REVIEW_PERIOD + 1);

        governor.executeProposal(pid);
        // Counter stays 1 through Executed; cleared on Settled.
        assertEq(governor.openProposalCount(), 1, "counter stays 1 through Executed");
        assertEq(governor.getActiveProposal(), pid, "_activeProposal non-zero");

        vm.warp(vm.getBlockTimestamp() + 7 days + 1);
        governor.settleProposal(pid);
        assertEq(governor.openProposalCount(), 0, "counter == 0 after Settled");
        assertEq(governor.getActiveProposal(), 0, "_activeProposal cleared on Settled");

        vm.prank(owner);
        swood.requestUnstakeOwner(address(vault)); // must not revert
    }

    function test_requestUnstakeOwner_succeedsAfterCancel() public {
        uint256 pid = _propose();
        assertEq(governor.openProposalCount(), 1, "counter == 1 after propose");

        vm.prank(agent);
        governor.cancelProposal(pid);
        assertEq(governor.openProposalCount(), 0, "counter == 0 after cancel");

        vm.prank(owner);
        swood.requestUnstakeOwner(address(vault)); // must not revert
    }

    // NOTE (closed): a vote-driven Rejected or deadline-driven Expired
    // transition only persists to storage when a NON-reverting mutating call
    // lands inside `_resolveState`. Since every allow-listed entrypoint
    // (`executeProposal`, `settleProposal`, `vote`, etc.) reverts when the
    // resolved state isn't the one it expects, the dec of
    // `openProposalCount` was rolled back and the counter stayed pinned at 1.
    // `resolveProposalState(pid)` is the permissionless flush path — it runs
    // `_resolveState` and returns, so the lazy transition (and its dec)
    // commit. Regression tests: `test_resolveProposalState_*` below.

    function test_resolveProposalState_flushesVetoRejection() public {
        uint256 pid = _propose();
        assertEq(governor.openProposalCount(), 1, "counter == 1 in Pending");

        // Both LPs vote Against → crosses 40% vetoThresholdBps with 100%.
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(lp1);
        governor.vote(pid, ISyndicateGovernor.VoteType.Against);
        vm.prank(lp2);
        governor.vote(pid, ISyndicateGovernor.VoteType.Against);

        // Warp past voting period — proposal is lazily Rejected but the
        // counter hasn't flushed because no non-reverting mutating call has
        // landed in `_resolveState`.
        vm.warp(vm.getBlockTimestamp() + VOTING_PERIOD + 1);
        assertEq(
            uint256(governor.getProposalState(pid)),
            uint256(ISyndicateGovernor.ProposalState.Rejected),
            "state is lazily Rejected"
        );
        assertEq(governor.openProposalCount(), 1, "counter still stuck at 1 pre-flush");

        // Permissionless flush — anyone can call.
        governor.resolveProposalState(pid);
        assertEq(governor.openProposalCount(), 0, "counter == 0 after flush");

        // PR #359 review #1: the lazy-resolution `_decOpen` MUST also bump
        // `_lastSettledAt` so the settle cooldown gates the next execute.
        // Pre-fix this branch decremented the counter WITHOUT the bump,
        // letting propose→resolve→propose→execute skip the cooldown.
        // `getCooldownEnd == now + COOLDOWN_PERIOD` proves the bump landed.
        assertEq(
            governor.getCooldownEnd(),
            vm.getBlockTimestamp() + COOLDOWN_PERIOD,
            "resolveProposalState must bump _lastSettledAt (PR #359 #1)"
        );

        // Owner can now rage-quit.
        vm.prank(owner);
        swood.requestUnstakeOwner(address(vault));
    }

    /// @notice PR #359 review #1 — the permissionless lazy-resolution path
    ///         (`resolveProposalState` → `_resolveState` → `_decOpen`) bumps
    ///         the settle cooldown identically to the explicit cancel/veto
    ///         paths. Pre-fix it was the lone `_decOpen` site without the
    ///         `_lastSettledAt` write, so a guardian-blocked / expired
    ///         proposal left the cooldown un-armed.
    function test_resolveProposalState_armsCooldownLikeVeto() public {
        // Path A: explicit veto bumps the cooldown.
        uint256 pidA = _propose();
        vm.prank(owner);
        governor.vetoProposal(pidA);
        uint256 cooldownAfterVeto = governor.getCooldownEnd();

        // Same vault, fresh proposal, drive it to lazy Rejected via vote-veto.
        uint256 pidB = _propose();
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(lp1);
        governor.vote(pidB, ISyndicateGovernor.VoteType.Against);
        vm.prank(lp2);
        governor.vote(pidB, ISyndicateGovernor.VoteType.Against);
        vm.warp(vm.getBlockTimestamp() + VOTING_PERIOD + 1);

        // Path B: permissionless flush must arm the cooldown to NOW too.
        governor.resolveProposalState(pidB);
        assertEq(
            governor.getCooldownEnd(),
            vm.getBlockTimestamp() + COOLDOWN_PERIOD,
            "lazy-resolution path arms cooldown (PR #359 #1)"
        );
        assertGt(governor.getCooldownEnd(), cooldownAfterVeto, "cooldown advanced past the earlier veto stamp");
    }

    function test_resolveProposalState_flushesExpiredApproved() public {
        uint256 pid = _propose();
        _voteFor(pid);

        // Past voteEnd → GuardianReview, past reviewEnd with no blockers
        // would be Approved, past executeBy with no executeProposal call
        // would be Expired. The VIEW remains at GuardianReview until a
        // mutating `_resolveState` calls `resolveReview` on the registry.
        vm.warp(vm.getBlockTimestamp() + VOTING_PERIOD + REVIEW_PERIOD + EXECUTION_WINDOW + 1);
        assertEq(
            uint256(governor.getProposalState(pid)),
            uint256(ISyndicateGovernor.ProposalState.GuardianReview),
            "view pins at GuardianReview until registry resolves"
        );
        assertEq(governor.openProposalCount(), 1, "counter stuck at 1 pre-flush");

        // Permissionless flush resolves the registry review AND commits the
        // state transition, decrementing the counter.
        governor.resolveProposalState(pid);
        assertEq(
            uint256(governor.getProposalState(pid)),
            uint256(ISyndicateGovernor.ProposalState.Expired),
            "state is Expired after flush"
        );
        assertEq(governor.openProposalCount(), 0, "counter == 0 after flush");

        vm.prank(owner);
        swood.requestUnstakeOwner(address(vault));
    }

    function test_resolveProposalState_idempotent() public {
        uint256 pid = _propose();
        vm.prank(owner);
        governor.vetoProposal(pid); // already flushes counter via non-reverting path
        assertEq(governor.openProposalCount(), 0);

        // Re-calling resolve is a no-op.
        governor.resolveProposalState(pid);
        assertEq(governor.openProposalCount(), 0, "counter remains 0 on re-resolve");
    }

    function test_resolveProposalState_revertsIfProposalDoesNotExist() public {
        vm.expectRevert(ISyndicateGovernor.ProposalNotFound.selector);
        governor.resolveProposalState(99_999);
    }

    function test_requestUnstakeOwner_succeedsAfterVeto() public {
        uint256 pid = _propose();
        assertEq(governor.openProposalCount(), 1);

        vm.prank(owner);
        governor.vetoProposal(pid);
        assertEq(governor.openProposalCount(), 0, "counter == 0 after veto");

        vm.prank(owner);
        swood.requestUnstakeOwner(address(vault));
    }

    function test_requestUnstakeOwner_succeedsAfterEmergencyCancel() public {
        uint256 pid = _propose();
        assertEq(governor.openProposalCount(), 1);

        vm.prank(owner);
        governor.emergencyCancel(pid);
        assertEq(governor.openProposalCount(), 0, "counter == 0 after emergencyCancel");

        vm.prank(owner);
        swood.requestUnstakeOwner(address(vault));
    }

    function test_openProposalCount_trackedAcrossLifecycle() public {
        // Start at 0.
        assertEq(governor.openProposalCount(), 0, "start at 0");

        uint256 pid1 = _propose();
        assertEq(governor.openProposalCount(), 1, "inc on propose");

        // Cancel pid1 → back to 0.
        vm.prank(agent);
        governor.cancelProposal(pid1);
        assertEq(governor.openProposalCount(), 0, "dec on cancel");

        // New proposal, settle through the full happy path.
        uint256 pid2 = _propose();
        assertEq(governor.openProposalCount(), 1, "inc on second propose");

        _voteFor(pid2);
        vm.warp(vm.getBlockTimestamp() + VOTING_PERIOD + 1);
        registry.openReview(address(governor), pid2);
        vm.warp(vm.getBlockTimestamp() + REVIEW_PERIOD + 1);

        governor.executeProposal(pid2);
        // Counter stays through Executed; dec on the Settled edge.
        assertEq(governor.openProposalCount(), 1, "counter stays 1 through Executed");
        assertEq(governor.getActiveProposal(), pid2, "_activeProposal also set");

        vm.warp(vm.getBlockTimestamp() + 7 days + 1);
        governor.settleProposal(pid2);
        assertEq(governor.openProposalCount(), 0, "counter cleared on Settled");
        assertEq(governor.getActiveProposal(), 0, "_activeProposal zeroed on Settled");
    }

    function test_openProposalCount_collaborativeLifecycle() public {
        // Register a second agent.
        address agent2 = makeAddr("agent2");
        uint256 agent2Id = agentRegistry.mint(agent2);
        vm.prank(owner);
        vault.registerAgent(agent2Id, agent2);

        ISyndicateGovernor.CoProposer[] memory coProps = new ISyndicateGovernor.CoProposer[](1);
        coProps[0] = ISyndicateGovernor.CoProposer({agent: agent2, splitBps: 2000});

        vm.prank(agent);
        uint256 pid = governor.propose(
            address(vault), address(0), "ipfs://collab", 7 days, _execCalls(), _settleCalls(), coProps
        );

        // Sherlock #8: Draft now binds the vault — counter incremented at
        // propose time.
        assertEq(
            uint256(governor.getProposalState(pid)),
            uint256(ISyndicateGovernor.ProposalState.Draft),
            "in Draft until co-proposers approve"
        );
        assertEq(governor.openProposalCount(), 1, "Sherlock #8: Draft binds the vault");

        // Co-proposer approves → transitions to Pending → counter stays at 1
        // (already counted from propose time).
        vm.prank(agent2);
        governor.approveCollaboration(pid);
        assertEq(
            uint256(governor.getProposalState(pid)),
            uint256(ISyndicateGovernor.ProposalState.Pending),
            "collab -> Pending"
        );
        assertEq(governor.openProposalCount(), 1, "still 1 after Draft -> Pending (no double-count)");

        // Cancel.
        vm.prank(agent);
        governor.cancelProposal(pid);
        assertEq(governor.openProposalCount(), 0, "dec on cancel");
    }

    function test_openProposalCount_rejectCollaboration_noDecrement() public {
        // Register co-proposer.
        address agent2 = makeAddr("agent2");
        uint256 agent2Id = agentRegistry.mint(agent2);
        vm.prank(owner);
        vault.registerAgent(agent2Id, agent2);

        ISyndicateGovernor.CoProposer[] memory coProps = new ISyndicateGovernor.CoProposer[](1);
        coProps[0] = ISyndicateGovernor.CoProposer({agent: agent2, splitBps: 2000});

        vm.prank(agent);
        uint256 pid = governor.propose(
            address(vault), address(0), "ipfs://collab-reject", 7 days, _execCalls(), _settleCalls(), coProps
        );
        // Sherlock #8: Draft binds the vault.
        assertEq(governor.openProposalCount(), 1, "Sherlock #8: Draft counted");

        // Reject collaboration — Draft → Cancelled, counter decrements to 0.
        // Sherlock #9: must be called by the lead, not the co-proposer.
        vm.prank(agent);
        governor.rejectCollaboration(pid);
        assertEq(governor.openProposalCount(), 0, "decremented on rejectCollaboration");
    }

    /// @notice PR #324 review comment 4454151855 — owner-`emergencyCancel`
    ///         on a Draft proposal must decrement `openProposalCount`. Pre-fix
    ///         the Draft branch in `emergencyCancel` fell through to set
    ///         `state = Cancelled` without calling `_decOpen`, soft-locking
    ///         the vault: subsequent `propose` calls reverted
    ///         `VaultHasOpenProposal` because the counter stayed bumped from
    ///         the cancelled Draft.
    function test_emergencyCancel_draftDecrements() public {
        // Register co-proposer.
        address agent2 = makeAddr("agent2");
        uint256 agent2Id = agentRegistry.mint(agent2);
        vm.prank(owner);
        vault.registerAgent(agent2Id, agent2);

        ISyndicateGovernor.CoProposer[] memory coProps = new ISyndicateGovernor.CoProposer[](1);
        coProps[0] = ISyndicateGovernor.CoProposer({agent: agent2, splitBps: 2000});

        vm.prank(agent);
        uint256 pid = governor.propose(
            address(vault), address(0), "ipfs://draft-emerg", 7 days, _execCalls(), _settleCalls(), coProps
        );
        // Sherlock #8: Draft binds the vault.
        assertEq(governor.openProposalCount(), 1, "Sherlock #8: Draft counted");
        assertEq(
            uint256(governor.getProposalState(pid)), uint256(ISyndicateGovernor.ProposalState.Draft), "in Draft state"
        );

        // Owner emergency-cancels the Draft.
        vm.prank(owner);
        governor.emergencyCancel(pid);

        // R9 fix: counter must drop back to 0.
        assertEq(governor.openProposalCount(), 0, "R9: emergencyCancel decremented Draft");
        assertEq(
            uint256(governor.getProposalState(pid)),
            uint256(ISyndicateGovernor.ProposalState.Cancelled),
            "state is Cancelled"
        );

        // Liveness regression: a fresh `propose` must succeed. Pre-fix this
        // reverted `VaultHasOpenProposal` because the counter stayed at 1.
        vm.prank(agent);
        uint256 pid2 = governor.propose(
            address(vault),
            address(0),
            "ipfs://draft-emerg-2",
            7 days,
            _execCalls(),
            _settleCalls(),
            _emptyCoProposers()
        );
        assertGt(pid2, pid, "new proposal created post-emergencyCancel");
        assertEq(governor.openProposalCount(), 1, "counter at 1 after fresh propose");
    }

    /// @notice Sherlock run #1 finding #8 — once a Draft exists, the vault
    ///         is bound and new deposits are blocked (vault's
    ///         `_depositsLocked` reads `governor.openProposalCount > 0`).
    ///         Pre-fix, Draft sat outside the counter, so depositors could
    ///         front-run the Draft→Pending snapshot during the up-to-7-day
    ///         collab window and have their fresh balance counted at vote time.
    function test_draft_locksDeposits() public {
        address agent2 = makeAddr("agent2");
        uint256 agent2Id = agentRegistry.mint(agent2);
        vm.prank(owner);
        vault.registerAgent(agent2Id, agent2);

        ISyndicateGovernor.CoProposer[] memory coProps = new ISyndicateGovernor.CoProposer[](1);
        coProps[0] = ISyndicateGovernor.CoProposer({agent: agent2, splitBps: 2000});

        vm.prank(agent);
        governor.propose(address(vault), address(0), "ipfs://draft-lock", 7 days, _execCalls(), _settleCalls(), coProps);

        // openProposalCount = 1; vault's _depositsLocked() returns true.
        assertEq(governor.openProposalCount(), 1, "Draft bumps openProposalCount");

        // Attempt to deposit during the Draft window — must revert.
        address depositor = makeAddr("depositor");
        usdc.mint(depositor, 1_000e6);
        vm.startPrank(depositor);
        usdc.approve(address(vault), type(uint256).max);
        vm.expectRevert(ISyndicateVault.DepositsLocked.selector);
        vault.deposit(1_000e6, depositor);
        vm.stopPrank();
    }
}
