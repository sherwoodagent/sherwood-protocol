// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";

import {SyndicateGovernor} from "../../src/SyndicateGovernor.sol";
import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {ISyndicateVault} from "../../src/interfaces/ISyndicateVault.sol";
import {GuardianRegistry} from "../../src/GuardianRegistry.sol";
import {StakedWood} from "../../src/StakedWood.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {ExposureLedger} from "../../src/ExposureLedger.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "../mocks/MockAgentRegistry.sol";
import {MockRegistryMinimal} from "../mocks/MockRegistryMinimal.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";
import {ProtocolConfig} from "../../src/ProtocolConfig.sol";
import {GovEnvelope} from "../helpers/GovEnvelope.sol";
import {deployTierRegistry} from "../helpers/TierRegistryFixture.sol";

/// @dev Minimal sWOOD read surface `ExposureLedger` consumes — same shape as
///      `GovernorCoverageGatesTest`'s fixture mock (kept file-local, not
///      imported, so this file has no dependency on another agent's test file).
contract Audit2_MockSwood {
    mapping(address => uint256) public guardianStake;
    uint256 public coolDownPeriod = 45 days;

    function setStake(address g, uint256 own) external {
        guardianStake[g] = own;
    }

    function slashableStakeAt(address g, uint256) external view returns (uint256) {
        return guardianStake[g];
    }
}

/// @dev Chainlink-shaped feed: fixed answer, `decimals`, fresh `updatedAt`.
contract Audit2_MockFeed {
    int256 public answer;
    uint8 public immutable decimals;
    uint256 public updatedAt;

    constructor(int256 answer_, uint8 decimals_) {
        answer = answer_;
        decimals = decimals_;
        updatedAt = block.timestamp;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

/// @title GovernorEmergency_coverageCaps (unstick leg)
/// @notice Regression for the audit-2 highest-confidence finding (9
///         independent agents): `unstick` replayed the pre-committed
///         settlement batch under the propose-time `p.maxCapital` and the
///         UNSCALED `_getSettlementCallCaps`, while `settleProposal` uses
///         `proposal.effectiveMaxCapital` and the coverage-SCALED caps
///         (issue #27 design D3-D7). A proposer who under-covers a proposal
///         could size a settlement leg so the scaled cap reverts
///         `CallCapExceeded` under `settleProposal` — permanently stranding
///         it there — and then drain the FULL, unscaled declaration through
///         `unstick`, which requires no guardian review and is reachable
///         solo (a vault owner can register itself as the proposing agent).
///
///         Fixture mirrors `GovernorCoverageGatesTest`'s lightweight shape
///         (`ExposureLedger` + `MockRegistryMinimal`, no bond escrow / tier
///         registry needed): `unstick` never touches the guardian registry,
///         so the minimal review-free mock is sufficient and lets a REAL
///         coverage-scaling code path (not storage-mangled) drive the
///         scaled figures.
contract GovernorEmergency_UnstickCoverageCapsTest is Test {
    SyndicateGovernor public governor;
    SyndicateVault public vault;
    BatchExecutorLib public executorLib;
    ERC20Mock public usdg;
    ERC20Mock public wood;
    ERC20Mock public targetToken;
    MockAgentRegistry public agentRegistry;
    MockRegistryMinimal public guardianRegistryMock;
    ExposureLedger public ledger;
    Audit2_MockSwood public swood;
    Audit2_MockFeed public feed;

    address public owner = makeAddr("a2-owner");
    address public ledgerOwner = makeAddr("a2-ledgerOwner");
    address public ledgerRegistry = makeAddr("a2-ledgerRegistry");
    address public agent = makeAddr("a2-agent");
    address public lp1 = makeAddr("a2-lp1");
    address public sink = makeAddr("a2-drainSink");
    address public g1 = makeAddr("a2-guardian1");

    uint256 constant VOTING_PERIOD = 1 days;
    uint256 constant EXECUTION_WINDOW = 1 days;
    // Tier-2 flat coverage (no TierRegistry wired) == maxCapital, so
    // requiredCoverageUsd normalizes to MAX_CAPITAL scaled to 1e18.
    uint256 constant MAX_CAPITAL = 1_000e6;
    uint256 constant STRATEGY_DURATION = 7 days;

    function setUp() public {
        usdg = new ERC20Mock("USD Gov", "USDG", 6);
        wood = new ERC20Mock("Sherwood", "WOOD", 18);
        targetToken = new ERC20Mock("Target", "TGT", 18);
        executorLib = new BatchExecutorLib();
        agentRegistry = new MockAgentRegistry();
        guardianRegistryMock = new MockRegistryMinimal();

        // ── Ledger: $0.05 WOOD (via the feed), $1.00 USDG feed, generous cap.
        swood = new Audit2_MockSwood();
        ledger = new ExposureLedger(ledgerOwner, address(swood), 28 days);
        feed = new Audit2_MockFeed(1e8, 8); // $1.00, 8-dec
        MockAggregatorV3 woodFeed = new MockAggregatorV3(8, 0.05e8);
        vm.startPrank(ledgerOwner);
        ledger.setWoodUsdPrice(0.1e8); // cap only, not binding (the feed's $0.05 is used)
        // The mock publishes one round at construction and these suites warp far
        // past it; staleness is exercised in test/ExposureLedger.t.sol.
        ledger.setWoodFeed(address(woodFeed), type(uint64).max);
        ledger.setAssetFeed(address(usdg), address(feed), 365 days);
        ledger.setCoveredTvlCapUsd(10_000_000e18);
        ledger.setGuardianRegistry(ledgerRegistry);
        vm.stopPrank();

        // ── Vault + governor. Test contract is factory.
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
                    managementFeeBps: 0
                }))
        );
        vault = SyndicateVault(payable(address(new ERC1967Proxy(address(vaultImpl), vaultInit))));

        SyndicateGovernor govImpl = new SyndicateGovernor(24 hours, 1 hours);
        bytes memory govInit = abi.encodeCall(
            SyndicateGovernor.initialize,
            (
                address(vault),
                address(guardianRegistryMock),
                address(new ProtocolConfig(owner)),
                address(this),
                address(deployTierRegistry(address(this))), // factory (test contract)
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

        governor.setExposureLedger(address(ledger));

        uint256 agentId = agentRegistry.mint(agent);
        vm.prank(owner);
        vault.registerAgent(agentId, agent);

        usdg.mint(lp1, 60_000e6);
        vm.startPrank(lp1);
        usdg.approve(address(vault), 60_000e6);
        vault.deposit(60_000e6, lp1);
        vm.stopPrank();

        vm.warp(vm.getBlockTimestamp() + 1);
    }

    // ── Helpers ──

    function _execCalls() internal view returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({
            target: address(targetToken), data: abi.encodeCall(targetToken.approve, (address(usdg), 1)), value: 0
        });
    }

    /// @dev A single settlement call that drains the FULL `MAX_CAPITAL` to
    ///      `sink` — an outright extraction, not an honest unwind. Declared
    ///      RAW cap equals `MAX_CAPITAL` (legal: sum of caps <= maxCapital),
    ///      modeling exactly the audit scenario: a proposer sizes the
    ///      settlement leg against the VOTED declaration, not the coverage
    ///      it will actually raise.
    function _drainSettleCalls() internal view returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({
            target: address(usdg), data: abi.encodeCall(usdg.transfer, (sink, MAX_CAPITAL)), value: 0
        });
    }

    /// @dev Stake `g` and lock its WHOLE stake against `pid`: `type(uint256).max`
    ///      clamps to the free budget (`kNumerator x stake - openExposure`, k = 1),
    ///      so the quorum's `min(lock, slashable stake) x price` is exactly the
    ///      stake at $0.05/WOOD and the stake figure stays the one knob the
    ///      coverage-ratio tests below reason about.
    function _seatApprover(uint256 pid, address g, uint256 ownStake) internal {
        swood.setStake(g, ownStake);
        vm.prank(ledgerRegistry);
        ledger.recordApproval(address(governor), pid, g, type(uint256).max);
        assertEq(ledger.lockOf(address(governor), pid, g), ownStake, "fixture: lock == whole stake");
    }

    function _toApproved(uint256 pid) internal {
        vm.warp(governor.getProposal(pid).voteEnd + 1);
        governor.resolveProposalState(pid);
        assertEq(uint256(governor.getProposal(pid).state), uint256(ISyndicateGovernor.ProposalState.Approved));
    }

    function _proposeWithDrainSettleLeg() internal returns (uint256 pid) {
        vm.prank(agent);
        pid = governor.propose(
            address(vault),
            address(0),
            "ipfs://audit2-unstick-coverage-caps",
            STRATEGY_DURATION,
            ISyndicateGovernor.RiskEnvelope({maxCapital: MAX_CAPITAL, maxDrawdownBps: 10_000}),
            _execCalls(),
            GovEnvelope.defaultCaps(MAX_CAPITAL, 1),
            _drainSettleCalls(),
            GovEnvelope.defaultCaps(MAX_CAPITAL, 1),
            new ISyndicateGovernor.CoProposer[](0)
        );
    }

    // ── The regression ──

    /// @notice CORE regression: at 50% raised coverage, `settleProposal`
    ///         reverts `CallCapExceeded` on the coverage-scaled cap (500e6
    ///         of the 1,000e6 declared) — the proposal is stuck `Executed`.
    ///         Pre-fix, `unstick` replayed under the RAW, unscaled cap
    ///         (1,000e6) and `p.maxCapital` (1,000e6) and would have
    ///         DRAINED THE FULL AMOUNT despite only half the coverage being
    ///         raised. Post-fix, `unstick` must revert IDENTICALLY to
    ///         `settleProposal` — it cannot widen past what the
    ///         guardian-unreviewed path was ever supposed to allow.
    function test_unstick_replaysAtCoverageScaledCap_cannotWidenBeyondSettleProposal() public {
        uint256 pid = _proposeWithDrainSettleLeg();

        // This proposal's settle leg really DRAINS, so it declares a full
        // `MAX_CAPITAL` cap on both legs and `requiredCoverage` sums to
        // 2 x MAX_CAPITAL == $2,000. (It used to read $1,000: the harness
        // governor was registry-less, and the flat tier-2 default prices the
        // envelope once. The registry is mandatory at init since pashov
        // finding #1, so per-call pricing is live.)
        // 20,000e18 WOOD @ $0.05 == $1,000 == 50% of the $2,000 required.
        _seatApprover(pid, g1, 20_000e18);
        _toApproved(pid);

        vm.expectEmit(true, false, false, true, address(governor));
        emit ISyndicateGovernor.EffectiveMaxCapitalSet(pid, MAX_CAPITAL, MAX_CAPITAL / 2, 1_000e18, 2_000e18);
        governor.executeProposal(pid);
        assertEq(governor.getEffectiveMaxCapital(pid), MAX_CAPITAL / 2, "executed at the coverage-scaled size");

        vm.warp(vm.getBlockTimestamp() + STRATEGY_DURATION + 1);

        // settleProposal is stuck: the scaled per-call cap (500e6) is
        // smaller than what the settlement call actually moves (1,000e6).
        vm.expectRevert(
            abi.encodeWithSelector(BatchExecutorLib.CallCapExceeded.selector, 0, MAX_CAPITAL, MAX_CAPITAL / 2)
        );
        governor.settleProposal(pid);
        assertEq(
            uint256(governor.getProposal(pid).state),
            uint256(ISyndicateGovernor.ProposalState.Executed),
            "stuck Executed, not silently settled"
        );

        // THE FIX: unstick must revert on the SAME scaled cap, not drain
        // the full 1,000e6 under the raw declaration.
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(BatchExecutorLib.CallCapExceeded.selector, 0, MAX_CAPITAL, MAX_CAPITAL / 2)
        );
        governor.unstick(pid);

        assertEq(usdg.balanceOf(sink), 0, "nothing drained -- unstick cannot widen past settleProposal's bound");
        assertEq(
            uint256(governor.getProposal(pid).state),
            uint256(ISyndicateGovernor.ProposalState.Executed),
            "still stuck -- unstick did not silently succeed either"
        );
    }

    /// @notice Liveness check (failure-mode guardrail): when coverage is
    ///         FULL, `effectiveMaxCapital == maxCapital` and the scaled caps
    ///         equal the raw declared caps -- `unstick` must still succeed
    ///         and actually move the funds. Proves the fix does not brick
    ///         the honest, fully-covered rescue path it was never meant to
    ///         touch.
    function test_unstick_fullCoverage_stillDrainsToSink() public {
        uint256 pid = _proposeWithDrainSettleLeg();

        // This proposal's settle leg really DRAINS, so it declares a full
        // `MAX_CAPITAL` cap on both legs and `requiredCoverage` sums to
        // 2 x MAX_CAPITAL == $2,000. (It used to read $1,000: the harness
        // governor was registry-less, and the flat tier-2 default prices the
        // envelope once. The registry is mandatory at init since pashov
        // finding #1, so per-call pricing is live.)
        // 40,000e18 WOOD @ $0.05 == $2,000 == 100% of the required coverage.
        _seatApprover(pid, g1, 40_000e18);
        _toApproved(pid);
        governor.executeProposal(pid);
        assertEq(governor.getEffectiveMaxCapital(pid), MAX_CAPITAL, "full coverage -- no scaling");

        vm.warp(vm.getBlockTimestamp() + STRATEGY_DURATION + 1);

        vm.prank(owner);
        governor.unstick(pid);

        assertEq(usdg.balanceOf(sink), MAX_CAPITAL, "unstick still moves the full pre-committed amount");
        assertEq(uint256(governor.getProposal(pid).state), uint256(ISyndicateGovernor.ProposalState.Settled));
    }
}

/// @title GovernorEmergency_coverageCaps (finalizeEmergencySettle leg)
/// @notice Sibling regression: `finalizeEmergencySettle` had the identical
///         `p.maxCapital` widening on its batch-level ceiling. Fixture is
///         the real `GuardianRegistry` + `StakedWood` shape (mirroring
///         `test/governor/GovernorEmergency.t.sol`) because, unlike
///         `unstick`, this path DOES need a working guardian-review
///         registry (`openEmergency` / `finalizeEmergency`), which
///         `MockRegistryMinimal` deliberately does not implement.
///
///         No `ExposureLedger` is wired here (a second, independent
///         coverage-gate fixture would roughly double this file's size for
///         no extra signal on the code actually touched by this fix — the
///         batch-ceiling argument, not the coverage-derivation arithmetic
///         already covered above). Instead, `effectiveMaxCapital` is set
///         directly via `stdstore` on `getEffectiveMaxCapital`'s single
///         storage slot -- the same technique this suite's sibling file
///         already uses for `ownerStake` (`_zeroOwnerStake`) -- to model
///         "this proposal's coverage was scaled down to X" without
///         re-deriving the ledger machinery.
contract GovernorEmergency_FinalizeCoverageCapsTest is Test {
    using stdStorage for StdStorage;

    SyndicateGovernor public governor;
    SyndicateVault public vault;
    GuardianRegistry public registry;
    StakedWood public swood;
    BatchExecutorLib public executorLib;
    ERC20Mock public usdc;
    ERC20Mock public wood;
    ERC20Mock public targetToken;
    MockAgentRegistry public agentRegistry;

    address public owner = makeAddr("a2f-owner");
    address public agent = makeAddr("a2f-agent");
    address public lp1 = makeAddr("a2f-lp1");
    address public lp2 = makeAddr("a2f-lp2");
    address public sink = makeAddr("a2f-rescueSink");
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

        ProtocolConfig _hoistedPC = new ProtocolConfig(owner);
        // Hoisted ABOVE the nonce snapshot: the governor's mandatory tier-registry
        // argument (pashov finding #1) is a DEPLOYMENT, so leaving it inline in the
        // `initialize` tuple would consume a nonce and slide every predicted address.
        address fixtureTierRegistry = address(deployTierRegistry(address(this)));
        uint256 baseNonce = vm.getNonce(address(this));
        address predictedGovernor = vm.computeCreateAddress(address(this), baseNonce + 3);
        address predictedRegistryProxy = vm.computeCreateAddress(address(this), baseNonce + 5);

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
                    ageFloorBps: 2500,
                    maturationPeriod: 30 days
                }))
        );
        swood = StakedWood(address(new ERC1967Proxy(address(swoodImpl), swoodInit)));

        SyndicateGovernor govImpl = new SyndicateGovernor(24 hours, 1 hours);
        bytes memory govInit = abi.encodeCall(
            SyndicateGovernor.initialize,
            (
                address(vault),
                predictedRegistryProxy,
                address(_hoistedPC),
                address(this),
                fixtureTierRegistry,
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
        vm.mockCall(address(this), abi.encodeWithSignature("governorOf(address)"), abi.encode(address(governor)));
        require(address(governor) == predictedGovernor, "governor addr mismatch");

        GuardianRegistry regImpl = new GuardianRegistry(6 hours);
        bytes memory regInit = abi.encodeCall(
            GuardianRegistry.initialize, (owner, factoryEoa, address(swood), REVIEW_PERIOD, BLOCK_QUORUM_BPS)
        );
        registry = GuardianRegistry(address(new ERC1967Proxy(address(regImpl), regInit)));
        vm.prank(registry.factory());
        registry.addGovernor(address(governor), address(vault));
        require(address(registry) == predictedRegistryProxy, "registry addr mismatch");

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

        skip(30 days);
    }

    function _emptyCoProposers() internal pure returns (ISyndicateGovernor.CoProposer[] memory) {
        return new ISyndicateGovernor.CoProposer[](0);
    }

    function _execCalls() internal view returns (BatchExecutorLib.Call[] memory) {
        BatchExecutorLib.Call[] memory calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({
            target: address(usdc), data: abi.encodeCall(usdc.approve, (address(targetToken), 50_000e6)), value: 0
        });
        return calls;
    }

    function _settleCalls() internal view returns (BatchExecutorLib.Call[] memory) {
        BatchExecutorLib.Call[] memory calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({
            target: address(usdc), data: abi.encodeCall(usdc.approve, (address(targetToken), 0)), value: 0
        });
        return calls;
    }

    function _createExecutedProposal(uint256 duration) internal returns (uint256 proposalId) {
        vm.prank(agent);
        proposalId = governor.propose(
            address(vault),
            address(0),
            "ipfs://audit2-finalize-coverage-caps",
            duration,
            GovEnvelope.permissive(address(vault)),
            _execCalls(),
            GovEnvelope.defaultCaps((GovEnvelope.permissive(address(vault))).maxCapital, (_execCalls()).length),
            _settleCalls(),
            GovEnvelope.defaultCaps((GovEnvelope.permissive(address(vault))).maxCapital, (_settleCalls()).length),
            _emptyCoProposers()
        );
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(lp1);
        governor.vote(proposalId, ISyndicateGovernor.VoteType.For);
        vm.prank(lp2);
        governor.vote(proposalId, ISyndicateGovernor.VoteType.For);
        vm.warp(vm.getBlockTimestamp() + VOTING_PERIOD + 1);
        registry.openReview(address(governor), proposalId);
        vm.warp(vm.getBlockTimestamp() + REVIEW_PERIOD + 1);
        governor.executeProposal(proposalId);
    }

    /// @dev Overwrites the single storage slot `getEffectiveMaxCapital(pid)`
    ///      reads, simulating "this proposal's coverage-derived ceiling is
    ///      `scaled`" without standing up a second `ExposureLedger` fixture.
    ///      Same technique the sibling file uses for `ownerStake` via
    ///      `_zeroOwnerStake`.
    function _scaleEffectiveMaxCapital(uint256 pid, uint256 scaled) internal {
        stdstore.target(address(governor)).sig("getEffectiveMaxCapital(uint256)").with_key(pid).checked_write(scaled);
        assertEq(governor.getEffectiveMaxCapital(pid), scaled, "sanity: stdstore write landed");
    }

    /// @notice THE SIBLING FIX: with `effectiveMaxCapital` scaled down to
    ///         10,000e6 (of a much larger declared `maxCapital`, since
    ///         `GovEnvelope.permissive` prices it off the vault's full
    ///         100,000e6 TVL), an owner-supplied rescue call that nets an
    ///         outflow of 50,000e6 -- well within the OLD `p.maxCapital`
    ///         widening, and well past the scaled ceiling -- must now
    ///         revert `MaxNetOutflowExceeded`. Pre-fix this call would have
    ///         executed under the full, unscaled `p.maxCapital`.
    function test_finalizeEmergencySettle_scaledCeiling_blocksOversizedRescue() public {
        uint256 pid = _createExecutedProposal(7 days);
        vm.warp(vm.getBlockTimestamp() + 7 days);

        _scaleEffectiveMaxCapital(pid, 10_000e6);

        BatchExecutorLib.Call[] memory rescueCalls = new BatchExecutorLib.Call[](1);
        rescueCalls[0] = BatchExecutorLib.Call({
            target: address(usdc), data: abi.encodeCall(usdc.transfer, (sink, 50_000e6)), value: 0
        });

        vm.prank(owner);
        governor.emergencySettleWithCalls(pid, rescueCalls);

        // No guardian block votes cast -> review resolves clean, not blocked.
        vm.warp(vm.getBlockTimestamp() + REVIEW_PERIOD + 1);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ISyndicateVault.MaxNetOutflowExceeded.selector, 50_000e6, 10_000e6));
        governor.finalizeEmergencySettle(pid);

        assertEq(usdc.balanceOf(sink), 0, "oversized rescue blocked by the scaled batch ceiling");
        assertEq(
            uint256(governor.getProposal(pid).state),
            uint256(ISyndicateGovernor.ProposalState.Executed),
            "proposal stays Executed -- revert did not silently settle it"
        );
    }

    /// @notice FAILURE-MODE GUARDRAIL: even with `effectiveMaxCapital`
    ///         floored to ZERO -- the worst case the audit brief explicitly
    ///         warns about ("if coverage floored effectiveMaxCapital to
    ///         ZERO, tightening finalizeEmergencySettle to
    ///         effectiveMaxCapital BRICKS the rescue path entirely") -- an
    ///         HONEST rescue (net-inflow / net-zero-outflow call) still
    ///         succeeds. The fix tightens the ceiling on genuine extraction,
    ///         not on legitimate recovery: `MaxNetOutflowExceeded` only
    ///         compares `balanceBefore - balanceAfter` against the cap, and
    ///         an approve-only call (or any call that returns at least as
    ///         much as it moves out) nets zero outflow regardless of how
    ///         tight the cap is.
    function test_finalizeEmergencySettle_zeroEffectiveCeiling_honestRescueStillSucceeds() public {
        uint256 pid = _createExecutedProposal(7 days);
        vm.warp(vm.getBlockTimestamp() + 7 days);

        _scaleEffectiveMaxCapital(pid, 0);

        BatchExecutorLib.Call[] memory honestCalls = new BatchExecutorLib.Call[](1);
        honestCalls[0] = BatchExecutorLib.Call({
            target: address(usdc), data: abi.encodeCall(usdc.approve, (address(targetToken), 0)), value: 0
        });

        vm.prank(owner);
        governor.emergencySettleWithCalls(pid, honestCalls);
        vm.warp(vm.getBlockTimestamp() + REVIEW_PERIOD + 1);

        vm.prank(owner);
        governor.finalizeEmergencySettle(pid);

        assertEq(
            uint256(governor.getProposal(pid).state),
            uint256(ISyndicateGovernor.ProposalState.Settled),
            "a zero-outflow rescue is NOT bricked by a zero effective ceiling"
        );
    }
}
