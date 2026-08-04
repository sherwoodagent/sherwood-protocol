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
import {MockStrategyAdapter} from "../mocks/MockStrategyAdapter.sol";
import {ProtocolConfig} from "../../src/ProtocolConfig.sol";
import {GovEnvelope} from "../helpers/GovEnvelope.sol";

/// @title GovernorStrategyOnProposalTest
/// @notice Coverage for the strategy-on-proposal model: the proposer passes
///         `strategy` directly to `propose(...)`, no separate
///         `bindProposalAdapter` step. The vault resolves the live-NAV adapter
///         by reading `governor.getProposal(activePid).strategy`.
contract GovernorStrategyOnProposalTest is Test {
    SyndicateGovernor public governor;
    SyndicateVault public vault;
    BatchExecutorLib public executorLib;
    ERC20Mock public usdc;
    ERC20Mock public targetToken;
    MockAgentRegistry public agentRegistry;
    MockRegistryMinimal public guardianRegistry;

    address public owner = makeAddr("owner");
    address public agent = makeAddr("agent");
    address public lp1 = makeAddr("lp1");
    address public lp2 = makeAddr("lp2");

    uint256 public agentNftId;

    uint256 constant VOTING_PERIOD = 1 days;
    uint256 constant EXECUTION_WINDOW = 1 days;
    uint256 constant VETO_THRESHOLD_BPS = 4000;
    uint256 constant MAX_PERF_FEE_BPS = 1500;
    uint256 constant MAX_STRATEGY_DURATION = 30 days;
    uint256 constant COOLDOWN_PERIOD = 1 days;

    function setUp() public {
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        targetToken = new ERC20Mock("Target", "TGT", 18);
        executorLib = new BatchExecutorLib();
        agentRegistry = new MockAgentRegistry();
        guardianRegistry = new MockRegistryMinimal();
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
                    managementFeeBps: 50
                }))
        );
        vault = SyndicateVault(payable(address(new ERC1967Proxy(address(vaultImpl), vaultInit))));

        vm.prank(owner);
        vault.registerAgent(agentNftId, agent);

        SyndicateGovernor govImpl = new SyndicateGovernor(24 hours, 1 hours);
        bytes memory govInit = abi.encodeCall(
            SyndicateGovernor.initialize,
            (
                address(vault), // vault_: this test's vault (per-vault governor)
                address(guardianRegistry),
                address(new ProtocolConfig(owner)),
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
                    maxStrategyDuration: MAX_STRATEGY_DURATION
                })
            )
        );
        governor = SyndicateGovernor(address(new ERC1967Proxy(address(govImpl), govInit)));

        vm.mockCall(address(this), abi.encodeWithSignature("governorOf(address)"), abi.encode(address(governor)));

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
    }

    // ==================== HELPERS ====================

    function _emptyCoProposers() internal pure returns (ISyndicateGovernor.CoProposer[] memory) {
        return new ISyndicateGovernor.CoProposer[](0);
    }

    function _execCalls() internal view returns (BatchExecutorLib.Call[] memory) {
        BatchExecutorLib.Call[] memory cs = new BatchExecutorLib.Call[](1);
        cs[0] = BatchExecutorLib.Call({
            target: address(usdc), data: abi.encodeCall(usdc.approve, (address(targetToken), 50_000e6)), value: 0
        });
        return cs;
    }

    function _settleCalls() internal view returns (BatchExecutorLib.Call[] memory) {
        BatchExecutorLib.Call[] memory cs = new BatchExecutorLib.Call[](1);
        cs[0] = BatchExecutorLib.Call({
            target: address(usdc), data: abi.encodeCall(usdc.approve, (address(targetToken), 0)), value: 0
        });
        return cs;
    }

    /// @notice PASHOV REVIEW FINDING #8: `propose` wrote `p.strategy` verbatim
    ///         from calldata, but `BaseStrategy.execute()` treats
    ///         `strategyOf(activePid) == address(this)` as its whole
    ///         authorisation — so the equality held BY CONSTRUCTION for whoever
    ///         DECLARED the clone, not for whoever owned it.
    /// @dev    `StrategyFactory.cloneAndInit` enforces `proposer == msg.sender`
    ///         so `_proposer` is "a known authorized address", and
    ///         `StrategyFactory` itself records the governor-side check as
    ///         "deferred". Unbound, any registered agent could name a rival's
    ///         pre-deployed, governance-allowlisted clone and drive it
    ///         Pending -> Executed. The ratchet is one-way, so the rightful
    ///         proposer's own later proposal reverts `AlreadyExecuted` forever;
    ///         recovery needs a redeploy plus a fresh `setAdapterAllowed` and,
    ///         if tier-certified, a new `proposeCertification` + `certifyDelay`.
    function test_finding8_cannotProposeAnotherProposersClone() public {
        address rival = makeAddr("rivalAgent");
        StrategyOwnedBy foreign = new StrategyOwnedBy(rival, address(vault));

        // HOISTED, NOT VIA `_propose`. Every argument here is itself a call
        // (`GovEnvelope.permissive`, `_execCalls`, `defaultCaps`), and Solidity
        // evaluates arguments BEFORE the callee — so building them inline would
        // consume the one-shot `expectRevert` and the assertion would pass for
        // the wrong reason (or, as here, fail with "next call did not revert").
        ISyndicateGovernor.RiskEnvelope memory env = GovEnvelope.permissive(address(vault));
        BatchExecutorLib.Call[] memory ex = _execCalls();
        BatchExecutorLib.Call[] memory st = _settleCalls();
        uint256[] memory exCaps = GovEnvelope.defaultCaps(env.maxCapital, ex.length);
        uint256[] memory stCaps = GovEnvelope.defaultCaps(env.maxCapital, st.length);
        ISyndicateGovernor.CoProposer[] memory cps = _emptyCoProposers();

        vm.prank(agent);
        vm.expectRevert(ISyndicateGovernor.StrategyProposerMismatch.selector);
        governor.propose(address(vault), address(foreign), "ipfs://test", 7 days, env, ex, exCaps, st, stCaps, cps);
    }

    /// @dev The control: the SAME shape, owned by the caller, must still work.
    ///      Without it, the test above would also pass for a fix that simply
    ///      refused every strategy.
    function test_finding8_ownClonePropsesFine() public {
        StrategyOwnedBy own = new StrategyOwnedBy(agent, address(vault));
        uint256 pid = _propose(address(own));
        assertEq(governor.getProposal(pid).strategy, address(own), "the caller's own clone is accepted");
    }

    function _propose(address strategy) internal returns (uint256 proposalId) {
        vm.prank(agent);
        proposalId = governor.propose(
            address(vault),
            strategy,
            "ipfs://test",
            7 days,
            GovEnvelope.permissive(address(vault)),
            _execCalls(),
            GovEnvelope.defaultCaps((GovEnvelope.permissive(address(vault))).maxCapital, (_execCalls()).length),
            _settleCalls(),
            GovEnvelope.defaultCaps((GovEnvelope.permissive(address(vault))).maxCapital, (_settleCalls()).length),
            _emptyCoProposers()
        );
        vm.warp(vm.getBlockTimestamp() + 1);
    }

    function _proposeAndApprove(address strategy) internal returns (uint256 proposalId) {
        proposalId = _propose(strategy);
        vm.prank(lp1);
        governor.vote(proposalId, ISyndicateGovernor.VoteType.For);
        vm.prank(lp2);
        governor.vote(proposalId, ISyndicateGovernor.VoteType.For);
        vm.warp(vm.getBlockTimestamp() + VOTING_PERIOD + 1);
    }

    // ==================== TESTS ====================

    function test_propose_storesStrategyOnProposal() public {
        MockStrategyAdapter adapter = new MockStrategyAdapter();
        uint256 pid = _propose(address(adapter));
        ISyndicateGovernor.StrategyProposal memory p = governor.getProposal(pid);
        assertEq(p.strategy, address(adapter), "strategy field stored on proposal");
    }

    function test_propose_strategyZeroIsValid() public {
        // Queue-only proposal: no live NAV.
        uint256 pid = _propose(address(0));
        ISyndicateGovernor.StrategyProposal memory p = governor.getProposal(pid);
        assertEq(p.strategy, address(0));
    }

    function test_vault_activeStrategyAdapter_zeroBeforeExecute() public {
        // Strategy is on the proposal but `_activeProposal[vault]` is unset
        // until `executeProposal`. Vault resolves through governor and sees
        // pid == 0 → returns address(0).
        MockStrategyAdapter adapter = new MockStrategyAdapter();
        _propose(address(adapter));
        assertEq(vault.activeStrategyAdapter(), address(0), "no live strategy until execute");
    }

    function test_vault_activeStrategyAdapter_resolvesAfterExecute() public {
        MockStrategyAdapter adapter = new MockStrategyAdapter();
        uint256 pid = _proposeAndApprove(address(adapter));
        governor.executeProposal(pid);

        // Post-execute: vault reads strategy from governor's proposal struct.
        assertEq(vault.activeStrategyAdapter(), address(adapter), "vault resolves strategy through governor");
    }

    function test_vault_activeStrategyAdapter_zeroAfterSettle() public {
        MockStrategyAdapter adapter = new MockStrategyAdapter();
        uint256 pid = _proposeAndApprove(address(adapter));
        governor.executeProposal(pid);
        assertEq(vault.activeStrategyAdapter(), address(adapter));

        // MS-H3: proposer self-settle requires MIN_STRATEGY_DURATION_BEFORE_SELF_SETTLE.
        vm.warp(vm.getBlockTimestamp() + 1 hours + 1);
        vm.prank(agent);
        governor.settleProposal(pid);

        // Post-settle: governor clears `_activeProposal`, so the vault read
        // resolves to pid=0 → strategy=address(0). Implicit clear without
        // the vault holding any storage.
        assertFalse(vault.redemptionsLocked());
        assertEq(vault.activeStrategyAdapter(), address(0));
    }

    function test_executeProposal_queueOnlyStrategyZeroIsBenign() public {
        // Standard flow with `strategy=address(0)` — vault's adapter resolution
        // returns zero, behaviour matches the legacy queue-only path.
        uint256 pid = _proposeAndApprove(address(0));
        governor.executeProposal(pid);
        assertEq(vault.activeStrategyAdapter(), address(0));
    }

    function test_strategy_immutableOnceProposed() public {
        // The proposal struct is set at propose time. There is no setter, no
        // governor-side bind function — voters always see the same strategy
        // they approved.
        MockStrategyAdapter adapter = new MockStrategyAdapter();
        uint256 pid = _propose(address(adapter));

        ISyndicateGovernor.StrategyProposal memory before = governor.getProposal(pid);
        // No way to mutate strategy: confirm the field is the same after voting.
        vm.prank(lp1);
        governor.vote(pid, ISyndicateGovernor.VoteType.For);
        ISyndicateGovernor.StrategyProposal memory afterVote = governor.getProposal(pid);
        assertEq(before.strategy, afterVote.strategy, "strategy unchanged across vote");
    }
}

/// @notice Minimal stand-in for a `BaseStrategy` clone: it answers the two
///         views `SyndicateGovernor.propose` binds against, and nothing else.
/// @dev    Deliberately NOT a full `IStrategy` — `propose` reaches it by raw
///         staticcall, so only these selectors matter, and keeping the surface
///         this small is what makes the two finding-#8 tests read as "who owns
///         this clone" rather than "is this a valid strategy".
contract StrategyOwnedBy {
    address internal immutable _proposer;
    address internal immutable _vault;

    constructor(address proposer_, address vault_) {
        _proposer = proposer_;
        _vault = vault_;
    }

    function proposer() external view returns (address) {
        return _proposer;
    }

    function vault() external view returns (address) {
        return _vault;
    }
}
