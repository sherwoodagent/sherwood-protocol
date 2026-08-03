// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {SyndicateGovernor} from "../../src/SyndicateGovernor.sol";
import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {ISyndicateVault} from "../../src/interfaces/ISyndicateVault.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {ProtocolConfig} from "../../src/ProtocolConfig.sol";
import {StrategyFactory} from "../../src/StrategyFactory.sol";
import {BaseStrategy} from "../../src/strategies/BaseStrategy.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "../mocks/MockAgentRegistry.sol";
import {MockRegistryMinimal} from "../mocks/MockRegistryMinimal.sol";
import {MockStrategy} from "../mocks/MockStrategy.sol";
import {MockProposalStatus} from "../mocks/MockProposalStatus.sol";
import {GovEnvelope} from "../helpers/GovEnvelope.sol";

/// @notice `StrategyFactory.syndicateFactory` stand-in: reports every vault as
///         registered so the factory's `_authClone` gate passes.
contract MockSyndicateRegistry {
    function vaultToSyndicate(address) external pure returns (uint256) {
        return 1;
    }
}

/// @notice Minimal vault stand-in exposing only `governor()` — the one hop
///         `BaseStrategy.execute()` reads off `vault()`. Used by the
///         fail-closed unit pins (2.3), which need precise, non-permissive
///         governor wiring (`MockProposalStatus`) rather than the full
///         governor+vault lifecycle the headline PoC (2.1) drives.
contract MockVaultGovernorOnly {
    address public governor;

    constructor(address governor_) {
        governor = governor_;
    }
}

/// @notice A governor with code but neither `getActiveProposal()` nor
///         `strategyOf(uint256)` — pins that `execute()` fails closed when a
///         hop resolves to a contract that doesn't answer the
///         `IProposalStatus` selectors (any revert is acceptable; the
///         staticcall simply has no matching function and no fallback).
contract EmptyGovernor {
    function ping() external pure returns (uint256) {
        return 1;
    }
}

/// @notice A strategy that actually moves funds, for the orphan-recovery pin
///         (2.4) — `MockStrategy` deliberately never transfers anything, so
///         it can't demonstrate "the clone's balance returns to the vault."
///         Pull on execute, push-all on settle — the same shape as every
///         production `BaseStrategy` subclass's happy path.
contract MockFundedStrategy is BaseStrategy {
    address public asset;
    uint256 public amount;

    function name() external pure returns (string memory) {
        return "MockFunded";
    }

    function _initialize(bytes calldata data) internal override {
        (asset, amount) = abi.decode(data, (address, uint256));
    }

    function _execute() internal override {
        _pullFromVault(asset, amount);
    }

    function _settle() internal override {
        _pushAllToVault(asset);
    }

    function _updateParams(bytes calldata) internal override {}
}

/// @title Strategy_cloneRatchetBinding
/// @notice Issue #150 — `BaseStrategy.execute()` was `onlyVault` but not bound
///         to any particular proposal. Because `executeGovernorBatch`
///         delegatecalls through `BatchExecutorLib`, every sub-call of every
///         proposal's batch carries `msg.sender == vault`, so ANY registered
///         agent who could get ANY proposal executed could target an
///         unrelated, pre-deployed clone's `execute()` from their own batch,
///         flipping its one-shot `Pending -> Executed` ratchet and
///         permanently bricking that clone's own later legitimate proposal
///         (`AlreadyExecuted` forever).
///
///         The fix (see `openspec/changes/fix-strategy-clone-ratchet/design.md`):
///         `execute()` now resolves `vault() -> governor()` and requires the
///         governor's active proposal to declare the executing clone as its
///         strategy, reverting `NotActiveProposalStrategy` otherwise. Fail-
///         closed by design — no capability probe, no try/catch.
///
///         This file drives the REAL governor + vault + factory lifecycle
///         (harness modeled on `Vault_batchQueueTargets_lifecycle.t.sol`), so
///         the PoC below is the actual end-to-end attack shape from the
///         issue, not a unit-level stand-in.
contract Strategy_cloneRatchetBinding_LifecycleTest is Test {
    SyndicateGovernor governor;
    SyndicateVault vault;
    BatchExecutorLib executorLib;
    ProtocolConfig protocolConfig;
    MockRegistryMinimal guardianRegistry;
    MockAgentRegistry agentRegistry;
    StrategyFactory factory;
    MockSyndicateRegistry syndicateRegistry;
    MockStrategy template;
    ERC20Mock usdc;

    address owner = makeAddr("owner");
    address agent = makeAddr("agent");
    address voter = makeAddr("voter");

    uint256 constant VOTING_PERIOD = 1 days;
    uint256 constant COOLDOWN_PERIOD = 1 days;
    uint256 constant EXECUTION_WINDOW = 1 days;
    uint256 constant STRATEGY_DURATION = 7 days;
    uint256 constant SELF_SETTLE_FLOOR = 1 hours;

    function setUp() public {
        protocolConfig = new ProtocolConfig(owner);
        vm.prank(owner);
        protocolConfig.setProtocolFeeRecipient(owner);

        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        executorLib = new BatchExecutorLib();
        agentRegistry = new MockAgentRegistry();
        guardianRegistry = new MockRegistryMinimal();
        uint256 agentNftId = agentRegistry.mint(agent);

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

        SyndicateGovernor govImpl = new SyndicateGovernor(24 hours, 1 hours);
        bytes memory govInit = abi.encodeCall(
            SyndicateGovernor.initialize,
            (
                address(vault),
                address(guardianRegistry),
                address(protocolConfig),
                address(this), // factory
                ISyndicateGovernor.GovernorParams({
                    votingPeriod: VOTING_PERIOD,
                    executionWindow: EXECUTION_WINDOW,
                    vetoThresholdBps: 4000,
                    maxPerformanceFeeBps: 1500,
                    cooldownPeriod: COOLDOWN_PERIOD,
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

        // Strategy factory: pre-deploys clones ahead of any proposal, exactly
        // as production requires (StrategyFactory.sol:30-36).
        syndicateRegistry = new MockSyndicateRegistry();
        factory = new StrategyFactory(address(syndicateRegistry), address(this));
        template = new MockStrategy();
        factory.setTemplateApproval(address(template), true);

        usdc.mint(voter, 40_000e6);
        vm.startPrank(voter);
        usdc.approve(address(vault), 40_000e6);
        vault.deposit(40_000e6, voter);
        vm.stopPrank();

        vm.warp(vm.getBlockTimestamp() + 1);
    }

    // ── helpers ──

    function _noCoProposers() internal pure returns (ISyndicateGovernor.CoProposer[] memory) {
        return new ISyndicateGovernor.CoProposer[](0);
    }

    function _permissiveEnv() internal view returns (ISyndicateGovernor.RiskEnvelope memory) {
        return ISyndicateGovernor.RiskEnvelope({maxCapital: vault.totalAssets(), maxDrawdownBps: 10_000});
    }

    /// @dev A view call on the asset token — clears the batch guard, moves
    ///      nothing, and is a legal filler for whichever leg (execute /
    ///      settlement) a given scenario doesn't care about.
    function _benignCalls() internal view returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({
            target: address(usdc), value: 0, data: abi.encodeCall(usdc.balanceOf, (address(vault)))
        });
    }

    function _callTo(address target, bytes memory data) internal pure returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({target: target, value: 0, data: data});
    }

    function _deployClone() internal returns (MockStrategy clone) {
        vm.prank(agent);
        clone = MockStrategy(
            payable(factory.cloneAndInit(
                    address(template),
                    address(vault),
                    agent,
                    abi.encode(address(usdc), address(0), uint256(0), uint256(0), false)
                ))
        );
    }

    function _propose(
        address strategy,
        BatchExecutorLib.Call[] memory executeCalls,
        BatchExecutorLib.Call[] memory settlementCalls
    ) internal returns (uint256 pid) {
        // Hoisted: a call in argument position (both `_permissiveEnv()`,
        // which itself calls out to the vault, and — for safety —
        // `_noCoProposers()`) would consume the pending one-shot `vm.prank`
        // before `governor.propose` itself runs, landing the call unpranked.
        ISyndicateGovernor.RiskEnvelope memory env = _permissiveEnv();
        ISyndicateGovernor.CoProposer[] memory noCoProposers = _noCoProposers();
        vm.prank(agent);
        pid = governor.propose(
            address(vault),
            strategy,
            "ipfs://p",
            STRATEGY_DURATION,
            env,
            executeCalls,
            GovEnvelope.defaultCaps(env.maxCapital, executeCalls.length),
            settlementCalls,
            GovEnvelope.defaultCaps(env.maxCapital, settlementCalls.length),
            noCoProposers
        );
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(voter);
        governor.vote(pid, ISyndicateGovernor.VoteType.For);
        vm.warp(vm.getBlockTimestamp() + VOTING_PERIOD + 1);
    }

    /// @dev Pushes `proposalId` (currently Approved, unexecuted) past its
    ///      `executeBy` deadline and flushes the lazy Expired transition, so
    ///      `openProposalCount` releases and a new proposal can be raised.
    ///      Also stamps `_lastSettledAt`, so callers must additionally clear
    ///      `cooldownPeriod` before the NEXT proposal can `executeProposal`.
    function _expireAndRelease(uint256 proposalId) internal {
        vm.warp(vm.getBlockTimestamp() + EXECUTION_WINDOW + 1);
        governor.resolveProposalState(proposalId);
        assertEq(
            uint256(governor.getProposal(proposalId).state),
            uint256(ISyndicateGovernor.ProposalState.Expired),
            "unrelated proposal must expire, not stay open forever"
        );
    }

    // ── 2.1: the headline PoC ──

    /// @notice THE #150 BRICK, NOW IMPOSSIBLE. Clone B is pre-deployed and
    ///         idle. An unrelated proposal (P1, own strategy = clone A) tries
    ///         to reach into clone B's `execute()` from its batch — this used
    ///         to flip clone B's ratchet and permanently brick clone B's own
    ///         future proposal. Now it reverts `NotActiveProposalStrategy`
    ///         and the WHOLE unrelated proposal's execution fails with it
    ///         (bubbled through `BatchExecutorLib`). Clone B is then proposed
    ///         legitimately (P2) and executes + settles cleanly — the exact
    ///         scenario the issue reported, now closed.
    function test_unrelatedProposalCannotExecuteForeignClone_thenOwnProposalSucceeds() public {
        MockStrategy cloneA = _deployClone();
        MockStrategy cloneB = _deployClone();

        uint256 pid1 = _propose(
            address(cloneA), _callTo(address(cloneB), abi.encodeCall(BaseStrategy.execute, ())), _benignCalls()
        );

        vm.expectRevert(BaseStrategy.NotActiveProposalStrategy.selector);
        governor.executeProposal(pid1);

        // Bubbled revert unwinds the WHOLE transaction: neither clone moved.
        assertEq(uint256(cloneA.state()), uint256(BaseStrategy.State.Pending), "clone A untouched");
        assertEq(uint256(cloneB.state()), uint256(BaseStrategy.State.Pending), "clone B's ratchet did not flip");
        assertEq(cloneB.executeCount(), 0, "clone B's _execute() never ran");

        _expireAndRelease(pid1);
        // `_expireAndRelease` stamped `_lastSettledAt` — clear the cooldown
        // before the next `executeProposal`.
        vm.warp(vm.getBlockTimestamp() + COOLDOWN_PERIOD + 1);

        uint256 pid2 = _propose(
            address(cloneB),
            _callTo(address(cloneB), abi.encodeCall(BaseStrategy.execute, ())),
            _callTo(address(cloneB), abi.encodeCall(BaseStrategy.settle, ()))
        );

        governor.executeProposal(pid2);
        assertEq(uint256(cloneB.state()), uint256(BaseStrategy.State.Executed), "clone B's own proposal executes");
        assertEq(cloneB.executeCount(), 1);

        vm.warp(vm.getBlockTimestamp() + SELF_SETTLE_FLOOR + 1);
        vm.prank(agent);
        governor.settleProposal(pid2);
        assertEq(uint256(cloneB.state()), uint256(BaseStrategy.State.Settled), "clone B settles cleanly");
        assertEq(cloneB.settleCount(), 1);
    }

    // ── 2.2: happy-path pin — the check passes for the owner, ratchet semantics unchanged ──

    /// @notice The owning proposal's own batch calling `execute()` on its
    ///         declared clone TWICE: the binding check passes both times (it
    ///         is not what fires), and the ratchet's own `AlreadyExecuted`
    ///         fires on the second call instead — proving the new check
    ///         doesn't change ratchet semantics for the legitimate owner.
    function test_ownProposal_duplicateExecuteInBatch_stillAlreadyExecuted() public {
        MockStrategy clone = _deployClone();

        BatchExecutorLib.Call[] memory calls = new BatchExecutorLib.Call[](2);
        calls[0] =
            BatchExecutorLib.Call({target: address(clone), value: 0, data: abi.encodeCall(BaseStrategy.execute, ())});
        calls[1] = calls[0];

        uint256 pid = _propose(address(clone), calls, _benignCalls());

        // Bubbled from the SECOND call — `AlreadyExecuted`, not
        // `NotActiveProposalStrategy`: the binding check passed both times.
        vm.expectRevert(BaseStrategy.AlreadyExecuted.selector);
        governor.executeProposal(pid);

        // Whole-tx revert: the first call's ratchet flip rolled back too.
        assertEq(uint256(clone.state()), uint256(BaseStrategy.State.Pending));
    }
}

/// @title Strategy_cloneRatchetBinding — unit pins
/// @notice Fail-closed and orphan-recovery pins that don't need the full
///         governor+vault lifecycle — precise, non-permissive
///         `MockProposalStatus` wiring instead (design.md Decision 2 /
///         tasks.md 2.3-2.4).
contract Strategy_cloneRatchetBinding_UnitTest is Test {
    // ── 2.3: fail-closed pins ──

    /// @notice (a) No active proposal (pid 0) — `strategyOf(0) == address(0)`
    ///         never equals the clone, so a direct pranked-vault `execute()`
    ///         reverts `NotActiveProposalStrategy`. This is the DELIBERATE
    ///         fail-closed default, not an edge case needing a special-case
    ///         branch (design.md Decision 2): `pid == 0` needs no carve-out.
    function test_noActiveProposal_reverts() public {
        MockProposalStatus gov = new MockProposalStatus(); // activePid defaults to 0
        MockVaultGovernorOnly vaultStub = new MockVaultGovernorOnly(address(gov));

        MockStrategy template = new MockStrategy();
        MockStrategy clone = MockStrategy(Clones.clone(address(template)));
        clone.initialize(
            address(vaultStub), makeAddr("proposer"), abi.encode(address(0), address(0), uint256(0), uint256(0), false)
        );

        vm.prank(address(vaultStub));
        vm.expectRevert(BaseStrategy.NotActiveProposalStrategy.selector);
        clone.execute();
    }

    /// @notice (b) Vault stub with no `governor()` selector — the staticcall
    ///         hop itself fails (no matching function, no fallback, on a
    ///         codeless address the abi-decode of an empty return fails the
    ///         same way). Any revert is acceptable: this pins fail-closed
    ///         behavior, not a specific error.
    function test_vaultWithoutGovernor_reverts() public {
        address codelessVault = makeAddr("codelessVault");
        MockStrategy template = new MockStrategy();
        MockStrategy clone = MockStrategy(Clones.clone(address(template)));
        clone.initialize(
            codelessVault, makeAddr("proposer"), abi.encode(address(0), address(0), uint256(0), uint256(0), false)
        );

        vm.prank(codelessVault);
        vm.expectRevert();
        clone.execute();
    }

    /// @notice (c) Governor resolves (vault's hop works) but the governor
    ///         itself answers neither `getActiveProposal()` nor
    ///         `strategyOf(uint256)` — the second hop fails the same way.
    function test_governorWithoutProposalStatusViews_reverts() public {
        EmptyGovernor emptyGov = new EmptyGovernor();
        MockVaultGovernorOnly vaultStub = new MockVaultGovernorOnly(address(emptyGov));

        MockStrategy template = new MockStrategy();
        MockStrategy clone = MockStrategy(Clones.clone(address(template)));
        clone.initialize(
            address(vaultStub), makeAddr("proposer"), abi.encode(address(0), address(0), uint256(0), uint256(0), false)
        );

        vm.prank(address(vaultStub));
        vm.expectRevert();
        clone.execute();
    }

    // ── 2.4: orphan-recovery pin ──

    /// @notice `settle()` is deliberately left WITHOUT the active-proposal
    ///         check (design.md Decision 2, reason 2: recovery is
    ///         load-bearing). A clone driven to `Executed` whose owning
    ///         proposal is then force-settled through owner emergency calls
    ///         that never touch the clone is orphaned: the clone stays
    ///         `Executed` with position tokens in custody. A LATER,
    ///         unrelated proposal's batch must still be able to call
    ///         `settle()` on it and recover the funds to the vault — pinning
    ///         that a future "symmetry" refactor guarding `settle()` the same
    ///         way would strand them instead.
    function test_orphanedClone_laterProposalCanStillSettleAndRecoverFunds() public {
        address owner = makeAddr("owner");
        address agent = makeAddr("agent");
        address voter = makeAddr("voter");

        ProtocolConfig protocolConfig = new ProtocolConfig(owner);
        vm.prank(owner);
        protocolConfig.setProtocolFeeRecipient(owner);

        ERC20Mock usdc = new ERC20Mock("USD Coin", "USDC", 6);
        BatchExecutorLib executorLib = new BatchExecutorLib();
        MockAgentRegistry agentRegistry = new MockAgentRegistry();
        MockRegistryMinimal guardianRegistry = new MockRegistryMinimal();
        uint256 agentNftId = agentRegistry.mint(agent);

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
        SyndicateVault vault = SyndicateVault(payable(address(new ERC1967Proxy(address(vaultImpl), vaultInit))));
        vm.prank(owner);
        vault.registerAgent(agentNftId, agent);

        uint256 votingPeriod = 1 days;
        SyndicateGovernor govImpl = new SyndicateGovernor(24 hours, 1 hours);
        bytes memory govInit = abi.encodeCall(
            SyndicateGovernor.initialize,
            (
                address(vault),
                address(guardianRegistry),
                address(protocolConfig),
                address(this),
                ISyndicateGovernor.GovernorParams({
                    votingPeriod: votingPeriod,
                    executionWindow: 1 days,
                    vetoThresholdBps: 4000,
                    maxPerformanceFeeBps: 1500,
                    cooldownPeriod: 1 hours,
                    collaborationWindow: 48 hours,
                    maxCoProposers: 5,
                    minStrategyDuration: 1 hours,
                    maxStrategyDuration: 30 days
                })
            )
        );
        SyndicateGovernor governor = SyndicateGovernor(address(new ERC1967Proxy(address(govImpl), govInit)));
        vm.mockCall(address(this), abi.encodeWithSignature("governorOf(address)"), abi.encode(address(governor)));
        vm.mockCall(address(this), abi.encodeWithSignature("priceRouter()"), abi.encode(address(0)));

        usdc.mint(voter, 40_000e6);
        vm.startPrank(voter);
        usdc.approve(address(vault), 40_000e6);
        vault.deposit(40_000e6, voter);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 1);

        // Clone funded directly (no factory needed for this pin — the
        // property under test is `settle()`'s fund-recovery path, not
        // pre-deployment mechanics, already covered by the lifecycle test).
        MockFundedStrategy template = new MockFundedStrategy();
        MockFundedStrategy clone = MockFundedStrategy(Clones.clone(address(template)));
        uint256 amount = 10_000e6;
        clone.initialize(address(vault), agent, abi.encode(address(usdc), amount));

        ISyndicateGovernor.RiskEnvelope memory env =
            ISyndicateGovernor.RiskEnvelope({maxCapital: vault.totalAssets(), maxDrawdownBps: 10_000});

        BatchExecutorLib.Call[] memory executeCalls = new BatchExecutorLib.Call[](2);
        executeCalls[0] = BatchExecutorLib.Call({
            target: address(usdc), value: 0, data: abi.encodeCall(IERC20.approve, (address(clone), amount))
        });
        executeCalls[1] =
            BatchExecutorLib.Call({target: address(clone), value: 0, data: abi.encodeCall(BaseStrategy.execute, ())});
        // Settlement calls deliberately do NOT touch the clone — this models
        // the owning proposal being force-settled by other means, orphaning
        // the clone in `Executed`.
        BatchExecutorLib.Call[] memory settlementCalls = new BatchExecutorLib.Call[](1);
        settlementCalls[0] = BatchExecutorLib.Call({
            target: address(usdc), value: 0, data: abi.encodeCall(usdc.balanceOf, (address(vault)))
        });

        // NOT `GovEnvelope.defaultCaps` here: that helper caps ONLY call 0 and
        // zeros the rest, but call 0 in THIS batch is the non-moving
        // `approve` — the actual fund-mover is call 1 (`clone.execute()`,
        // which pulls `amount` from the vault). Caps are ordered to match.
        uint256[] memory pid1ExecuteCaps = new uint256[](2);
        pid1ExecuteCaps[0] = 0;
        pid1ExecuteCaps[1] = env.maxCapital;

        vm.prank(agent);
        uint256 pid1 = governor.propose(
            address(vault),
            address(clone),
            "ipfs://p",
            7 days,
            env,
            executeCalls,
            pid1ExecuteCaps,
            settlementCalls,
            GovEnvelope.defaultCaps(env.maxCapital, settlementCalls.length),
            new ISyndicateGovernor.CoProposer[](0)
        );
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(voter);
        governor.vote(pid1, ISyndicateGovernor.VoteType.For);
        vm.warp(vm.getBlockTimestamp() + votingPeriod + 1);

        governor.executeProposal(pid1);
        assertEq(uint256(clone.state()), uint256(BaseStrategy.State.Executed));
        assertEq(usdc.balanceOf(address(clone)), amount, "clone holds the pulled funds");

        // Owner rescues the STUCK proposal via `unstick` (GovernorEmergency)
        // after `strategyDuration` elapses — runs the pre-committed
        // settlement calls (the benign one above), which never touch the
        // clone. The proposal reaches Settled; the clone is now orphaned.
        vm.warp(vm.getBlockTimestamp() + 7 days + 1);
        vm.prank(owner);
        governor.unstick(pid1);
        assertEq(
            uint256(governor.getProposal(pid1).state), uint256(ISyndicateGovernor.ProposalState.Settled), "unstuck"
        );
        assertEq(
            uint256(clone.state()), uint256(BaseStrategy.State.Executed), "clone itself is orphaned, still Executed"
        );
        assertEq(usdc.balanceOf(address(clone)), amount, "funds still sit in the orphaned clone");

        // A LATER, unrelated proposal's batch calls `settle()` on the
        // orphaned clone — deliberately unguarded (design.md Decision 2) —
        // and the funds return to the vault.
        uint256 vaultBalBefore = usdc.balanceOf(address(vault));
        BatchExecutorLib.Call[] memory recoveryExecute = new BatchExecutorLib.Call[](1);
        recoveryExecute[0] = BatchExecutorLib.Call({
            target: address(usdc), value: 0, data: abi.encodeCall(usdc.balanceOf, (address(vault)))
        });
        BatchExecutorLib.Call[] memory recoverySettle = new BatchExecutorLib.Call[](1);
        recoverySettle[0] =
            BatchExecutorLib.Call({target: address(clone), value: 0, data: abi.encodeCall(BaseStrategy.settle, ())});

        // Re-read: totalAssets() dropped (the orphaned clone still holds
        // `amount`), so the stale pid1 envelope would now exceed the vault's
        // live maxCapital ceiling.
        env.maxCapital = vault.totalAssets();

        vm.prank(agent);
        uint256 pid2 = governor.propose(
            address(vault),
            address(0), // opted out — recovery proposal declares no strategy of its own
            "ipfs://recover",
            7 days,
            env,
            recoveryExecute,
            GovEnvelope.defaultCaps(env.maxCapital, recoveryExecute.length),
            recoverySettle,
            GovEnvelope.defaultCaps(env.maxCapital, recoverySettle.length),
            new ISyndicateGovernor.CoProposer[](0)
        );
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(voter);
        governor.vote(pid2, ISyndicateGovernor.VoteType.For);
        vm.warp(vm.getBlockTimestamp() + votingPeriod + 1 + 1 hours + 1);

        governor.executeProposal(pid2);
        vm.warp(vm.getBlockTimestamp() + 1 hours + 1);
        vm.prank(agent);
        governor.settleProposal(pid2);

        assertEq(uint256(clone.state()), uint256(BaseStrategy.State.Settled), "orphaned clone finally settles");
        assertEq(usdc.balanceOf(address(clone)), 0, "clone's balance fully recovered");
        assertEq(usdc.balanceOf(address(vault)) - vaultBalBefore, amount, "funds landed back in the vault");
    }
}
