// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {SyndicateGovernor} from "../src/SyndicateGovernor.sol";
import {ISyndicateGovernor} from "../src/interfaces/ISyndicateGovernor.sol";
import {SyndicateVault} from "../src/SyndicateVault.sol";
import {ISyndicateVault} from "../src/interfaces/ISyndicateVault.sol";
import {GuardianRegistry} from "../src/GuardianRegistry.sol";
import {IGuardianRegistry} from "../src/interfaces/IGuardianRegistry.sol";
import {StakedWood} from "../src/StakedWood.sol";
import {ExposureLedger} from "../src/ExposureLedger.sol";
import {IExposureLedger} from "../src/interfaces/IExposureLedger.sol";
import {TierRegistry} from "../src/TierRegistry.sol";
import {ChallengeGame} from "../src/ChallengeGame.sol";
import {IChallengeGame} from "../src/interfaces/IChallengeGame.sol";
import {CompensationEscrow} from "../src/CompensationEscrow.sol";
import {ICompensationEscrow} from "../src/interfaces/ICompensationEscrow.sol";
import {ProposerBondEscrow} from "../src/ProposerBondEscrow.sol";
import {BatchExecutorLib} from "../src/BatchExecutorLib.sol";
import {ProtocolConfig} from "../src/ProtocolConfig.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "./mocks/MockAgentRegistry.sol";

/// @dev Chainlink-shaped USD feed for the vault asset.
contract ChallengeE2EFeed {
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

/// @dev A real adapter with two entrypoints, neither of them one of the four
///      value-moving ERC20 selectors — so the vault's `_guardBatchCalls` lets
///      both through without an adapter-allowlist entry, and the TierRegistry
///      can certify ONE of them while the other stays at the tier-2 default.
///      That asymmetry is what makes the challenged proposal tier 2 (so the
///      §3.3a coverage quorum engages and there is coverage to freeze) while
///      still containing a genuinely certified adapter call for a passed
///      challenge to demote.
contract ChallengeE2EAdapter {
    uint256 public pokes;
    uint256 public bumps;

    function poke() external {
        pokes++;
    }

    function bump() external {
        bumps++;
    }
}

/// @title ChallengeEndToEndTest
/// @notice Plan D Task 5 — the whole challenge game against the REAL stack, with
///         no mock standing in for a protocol contract anywhere: a real UUPS
///         `StakedWood` proxy holding a real staked+matured guardian, a real
///         `GuardianRegistry` running a real review window, a real
///         `SyndicateVault` + `SyndicateGovernor` executing a real proposal, a
///         real `ExposureLedger` booking the coverage that approval commits, a
///         real `TierRegistry` holding the certification a passed challenge
///         revokes, a real `CompensationEscrow`, and a real `ChallengeGame`
///         wired into all of its roles.
///
/// @dev    The roles, each of them load-bearing for one leg of the arcs below:
///           - `ledger.coverageFreezer`         → the per-proposal freeze (D3)
///           - `tierRegistry.authorizedDemoter` → the passed-challenge demotion (D7)
///           - `swood.authorizedSlasher`        → the silence verdict's slash (D1)
///           - `escrow.authorizedFunder` is sWOOD, NOT the game: the escrow
///             address is owner-set state on sWOOD and deliberately not a
///             `slashToEscrow` argument, so the game can never redirect the
///             proceeds of a slash it triggers.
///
/// @dev    Fixture arithmetic, all exact:
///           - USDG 6-dec at $1.00; `_decimalsOffset()` is the asset's decimals,
///             so the first deposit into an empty vault mints `assets * 1e6`
///             shares and every later one converts at exactly `10^d` while the
///             vault's assets are unchanged (the proposal's batch moves none).
///             LP1 70,000 USDG → 70,000e12 shares, LP2 30,000 → 30,000e12,
///             post-drain buyer 20,000 → 20,000e12.
///           - Tier pricing: (adapter, poke) certified tier 1 @ 5,000 bps,
///             (adapter, bump) uncertified ⇒ tier 2 @ 10,000 bps. Exec batch is
///             [poke, bump] ⇒ tier 2, 15,000 bps; settle batch is [poke] ⇒
///             5,000 bps. coverage = maxCapital × 20,000/10,000 = 2 × 500 USDG
///             = 1,000 USDG = $1,000.
///           - proposerBondBps 100 ⇒ $10 ⇒ 200 WOOD at the $0.05 haircut.
///           - challengerBondBps 500 ⇒ $50 ⇒ 1,000 WOOD.
///           - g1 stakes 30,000 WOOD == $1,500 of slashable bond, so its
///             commitment is the whole $1,000 the proposal needs; a full
///             (10,000 bps) verdict slash yields 30,000 WOOD of proceeds, split
///             70/30 into 21,000 / 9,000.
contract ChallengeEndToEndTest is Test {
    // ── Real stack ──
    ERC20Mock public usdg; // vault asset, 6-dec, $1.00
    ERC20Mock public wood; // stake + bond token, 18-dec
    BatchExecutorLib public executorLib;
    MockAgentRegistry public agentRegistry;
    ProtocolConfig public protocolConfig;
    ChallengeE2EFeed public feed;
    ChallengeE2EAdapter public adapter;

    StakedWood public swood;
    GuardianRegistry public registry;
    ExposureLedger public ledger;
    TierRegistry public tierRegistry;
    ProposerBondEscrow public bondEscrow;
    CompensationEscrow public escrow;
    ChallengeGame public game;

    SyndicateVault public vault;
    SyndicateGovernor public gov;

    address public owner = makeAddr("owner");
    address public ledgerOwner = makeAddr("ledgerOwner");
    address public backstop = makeAddr("backstop");
    address public agent = makeAddr("agent");
    address public challenger = makeAddr("challenger");

    address public g1 = makeAddr("guardian1"); // the covering approver
    address public g2 = makeAddr("guardian2"); // cohort filler
    address public g3 = makeAddr("guardian3"); // cohort filler

    address public lp1 = makeAddr("lp1"); // pre-drain holder, 70%
    address public lp2 = makeAddr("lp2"); // pre-drain holder, 30%
    address public buyer = makeAddr("postDrainBuyer"); // deposits AFTER the drain

    uint256 constant VOTING_PERIOD = 1 days;
    uint256 constant EXECUTION_WINDOW = 1 days;
    uint256 constant REVIEW_PERIOD = 24 hours;
    uint256 constant BLOCK_QUORUM_BPS = 3000;
    uint256 constant MIN_GUARDIAN_STAKE = 10_000e18;
    uint256 constant COOL_DOWN = 45 days; // >= epochLength (28d) + challengeWindow (14d)
    uint256 constant EPOCH_LENGTH = 28 days;
    uint256 constant MATURATION = 30 days;

    uint256 constant G1_STAKE = 30_000e18; // $1,500 of slashable bond
    uint256 constant FILLER_STAKE = 20_000e18; // cohort padding over the 50k floor

    uint256 constant LP1_ASSETS = 70_000e6;
    uint256 constant LP2_ASSETS = 30_000e6;
    uint256 constant BUYER_ASSETS = 20_000e6;
    uint256 constant LP1_SHARES = 70_000e12;
    uint256 constant LP2_SHARES = 30_000e12;
    uint256 constant BUYER_SHARES = 20_000e12;
    uint256 constant SNAP_SUPPLY = LP1_SHARES + LP2_SHARES;

    uint256 constant MAX_CAPITAL = 500e6;
    /// @dev maxCapital × (exec 15,000 bps + settle 5,000 bps) / 10,000.
    uint256 constant REQUIRED_COVERAGE = 1_000e6;
    uint256 constant COVERAGE_USD = 1_000e18;
    uint256 constant PROPOSER_BOND = 200e18; // $1,000 × 1% ÷ $0.05
    uint256 constant CHALLENGER_BOND = 1_000e18; // $1,000 × 5% ÷ $0.05

    /// @dev The verdict no longer takes the lot. g1 committed $1,000 of
    ///      coverage against a $1,500 slashable bond (G1_STAKE at $0.05), so the
    ///      ledger prices its liability at `ceil(1_000 * 10_000 / 1_500)` = 6667
    ///      bps of its own stake — what it underwrote, rounded toward the
    ///      protocol. The remainder stays staked and is still available to a
    ///      second, concurrent conviction, which is the point of per-approver
    ///      rates.
    uint256 constant VERDICT_BPS = 6667;
    uint256 constant PROCEEDS = (G1_STAKE * VERDICT_BPS) / 10_000;
    uint256 constant LP1_CLAIM = (PROCEEDS * 70) / 100; // pre-drain cohort, 70%
    uint256 constant LP2_CLAIM = PROCEEDS - LP1_CLAIM; // ...and 30%, exhausting the case

    uint16 constant CERTIFIED_BOUND_BPS = 5_000;

    function setUp() public {
        usdg = new ERC20Mock("USD Gov", "USDG", 6);
        wood = new ERC20Mock("Sherwood", "WOOD", 18);
        executorLib = new BatchExecutorLib();
        agentRegistry = new MockAgentRegistry();
        protocolConfig = new ProtocolConfig(owner);
        adapter = new ChallengeE2EAdapter();
        tierRegistry = new TierRegistry(address(this));

        // ── sWOOD (sole WOOD custodian). The test contract is the factory.
        StakedWood swoodImpl = new StakedWood();
        bytes memory swoodInit = abi.encodeCall(
            StakedWood.initialize,
            (StakedWood.InitParams({
                    owner: owner,
                    wood: address(wood),
                    factory: address(this),
                    minGuardianStake: MIN_GUARDIAN_STAKE,
                    coolDownPeriod: COOL_DOWN,
                    minOwnerStake: 10_000e18,
                    minSlashBps: 1000,
                    maxSlashBps: 10_000,
                    ageFloorBps: 2500,
                    maturationPeriod: MATURATION
                }))
        );
        swood = StakedWood(address(new ERC1967Proxy(address(swoodImpl), swoodInit)));

        // ── Real guardian registry with a real review window.
        GuardianRegistry regImpl = new GuardianRegistry(6 hours);
        bytes memory regInit = abi.encodeCall(
            GuardianRegistry.initialize, (owner, address(this), address(swood), REVIEW_PERIOD, BLOCK_QUORUM_BPS)
        );
        registry = GuardianRegistry(address(new ERC1967Proxy(address(regImpl), regInit)));
        vm.prank(owner);
        swood.setRegistry(address(registry));

        // ── Real vault + real governor; the test contract is their factory, so
        //    the vault resolves its governor through `governorOf`.
        _deploySyndicate();
        registry.addGovernor(address(gov), address(vault));
        vm.mockCall(
            address(this), abi.encodeWithSignature("governorOf(address)", address(vault)), abi.encode(address(gov))
        );
        // Hoisted: a cheatcode in argument position is consumed by the inner
        // call — `agentRegistry.mint` would eat the prank before `registerAgent`.
        uint256 agentId = agentRegistry.mint(agent);
        vm.prank(owner);
        vault.registerAgent(agentId, agent);

        // ── Guardian cohort (70k total, over the registry's 50k floor at open),
        //    matured to par so `getPastVotes` == raw stake.
        _stakeGuardian(g1, G1_STAKE, 1);
        _stakeGuardian(g2, FILLER_STAKE, 2);
        _stakeGuardian(g3, FILLER_STAKE, 3);
        skip(MATURATION);
        vm.warp(vm.getBlockTimestamp() + 1);

        // ── Ledger deployed after the maturation warp so epoch genesis and feed
        //    freshness are current: approvals book into bucket 0 at a live price.
        ledger = new ExposureLedger(ledgerOwner, address(swood), EPOCH_LENGTH);
        feed = new ChallengeE2EFeed(1e8, 8); // $1.00, 8-dec
        vm.startPrank(ledgerOwner);
        ledger.setWoodUsdPrice(0.05e8); // conservative governance haircut
        // Generous staleness bound: the §3.3a quorum re-reads this feed at
        // EXECUTE time, a full voting + review window after propose.
        ledger.setAssetFeed(address(usdg), address(feed), 365 days);
        ledger.setCoveredTvlCapUsd(10_000_000e18);
        ledger.setGuardianRegistry(address(registry));
        vm.stopPrank();
        vm.prank(owner);
        registry.setExposureLedger(address(ledger));

        bondEscrow = new ProposerBondEscrow(address(wood), address(registry));
        escrow = new CompensationEscrow(owner, address(wood));

        // ── The game, then its roles.
        game = new ChallengeGame(owner, address(wood), address(ledger), address(tierRegistry));
        vm.prank(ledgerOwner);
        ledger.setCoverageFreezer(address(game));
        tierRegistry.setAuthorizedDemoter(address(game));
        vm.startPrank(owner);
        swood.setAuthorizedSlasher(address(game));
        swood.setCompensationEscrow(address(escrow));
        escrow.setAuthorizedFunder(address(swood));
        escrow.setBackstop(backstop);
        game.setStakedWood(address(swood));
        vm.stopPrank();

        // ── Governor wiring (the test contract is the factory).
        gov.setExposureLedger(address(ledger));
        gov.setBondEscrow(address(bondEscrow));
        gov.setTierRegistry(address(tierRegistry));

        // The certification a passed challenge will revoke. `poke` is priced at
        // half notional; `bump` is left uncertified so the batch as a whole is
        // still tier 2 and therefore coverage-gated.
        tierRegistry.certify(address(adapter), adapter.poke.selector, 1, CERTIFIED_BOUND_BPS, address(0));

        // ── WOOD for the proposer's bond, the challenger's bond, and the
        //    accused guardian's counter-bond.
        wood.mint(agent, 1_000_000e18);
        vm.prank(agent);
        wood.approve(address(bondEscrow), type(uint256).max);
        wood.mint(challenger, CHALLENGER_BOND);
        vm.prank(challenger);
        wood.approve(address(game), type(uint256).max);
        wood.mint(g1, CHALLENGER_BOND); // counter-bond matches the challenger's
        vm.prank(g1);
        wood.approve(address(game), type(uint256).max);

        // ── PRE-drain LPs, one per timestamp so the vault's ERC20Votes
        //    checkpoints genuinely separate (`clock()` is `block.timestamp`).
        //    Nobody calls `delegate` anywhere in this suite — the vault's own
        //    `_deposit` hook auto-delegates, and the escrow apportions against
        //    the checkpoints that hook produced.
        _deposit(lp1, LP1_ASSETS);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        _deposit(lp2, LP2_ASSETS);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
    }

    // ── Fixture helpers ───────────────────────────────────────────────────

    function _deploySyndicate() internal {
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
                address(registry),
                address(protocolConfig),
                address(this), // factory
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
        gov = SyndicateGovernor(address(new ERC1967Proxy(address(govImpl), govInit)));
    }

    function _stakeGuardian(address who, uint256 amount, uint256 agentId) internal {
        wood.mint(who, amount);
        vm.startPrank(who);
        wood.approve(address(swood), type(uint256).max);
        swood.stakeAsGuardian(amount, agentId);
        vm.stopPrank();
    }

    function _deposit(address who, uint256 assets) internal {
        usdg.mint(who, assets);
        vm.startPrank(who);
        usdg.approve(address(vault), assets);
        vault.deposit(assets, who);
        vm.stopPrank();
    }

    /// @dev Exec batch: the certified adapter call plus an uncertified one, so
    ///      the envelope resolves to tier 2 and the coverage quorum engages.
    function _execCalls() internal view returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](2);
        calls[0] = BatchExecutorLib.Call({target: address(adapter), data: abi.encodeCall(adapter.poke, ()), value: 0});
        calls[1] = BatchExecutorLib.Call({target: address(adapter), data: abi.encodeCall(adapter.bump, ()), value: 0});
    }

    function _settleCalls() internal view returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({target: address(adapter), data: abi.encodeCall(adapter.poke, ()), value: 0});
    }

    function _propose() internal returns (uint256) {
        vm.prank(agent);
        return gov.propose(
            address(vault),
            address(0),
            "ipfs://challenge-e2e",
            7 days,
            ISyndicateGovernor.RiskEnvelope({maxCapital: MAX_CAPITAL, maxDrawdownBps: 10_000}),
            _execCalls(),
            _settleCalls(),
            new ISyndicateGovernor.CoProposer[](0)
        );
    }

    function _state(uint256 pid) internal view returns (uint256) {
        return uint256(gov.getProposal(pid).state);
    }

    /// @dev propose → review opens → g1 approves (coverage committed) → execute.
    ///      Asserted here rather than in the two arcs, because both arcs depend
    ///      on the SAME real lifecycle and a silent difference between them
    ///      would invalidate the comparison the bad-faith arc makes.
    function _proposeApproveExecute() internal returns (uint256 pid) {
        uint256 agentBalBefore = wood.balanceOf(agent);

        pid = _propose();
        assertEq(gov.getProposal(pid).envelopeTier, 2, "uncertified call in the batch => tier 2");
        assertEq(gov.getProposal(pid).requiredCoverage, REQUIRED_COVERAGE, "half-notional + full-notional + settle");
        assertEq(ledger.coverageUsd(address(usdg), REQUIRED_COVERAGE), COVERAGE_USD, "$1,000 of coverage");
        assertEq(gov.getProposal(pid).proposerBondWood, PROPOSER_BOND, "1% of $1,000 at the $0.05 haircut");
        assertEq(wood.balanceOf(address(bondEscrow)), PROPOSER_BOND, "the proposer bond is locked");
        assertEq(wood.balanceOf(agent), agentBalBefore - PROPOSER_BOND, "and the proposer paid it");

        // ── Guardian approves through the REAL registry, which books the
        //    coverage on the REAL ledger.
        vm.warp(gov.getProposal(pid).voteEnd + 1);
        registry.openReview(address(gov), pid);
        assertEq(ledger.openExposureUsd(g1), 0, "no exposure before the vote");
        vm.prank(g1);
        registry.voteOnProposal(address(gov), pid, IGuardianRegistry.GuardianVoteType.Approve);
        assertEq(ledger.openExposureUsd(g1), COVERAGE_USD, "approve commits the proposal's coverage");

        (address[] memory approvers, uint256[] memory shares) = ledger.approversOf(address(gov), pid);
        assertEq(approvers.length, 1, "one covering approver");
        assertEq(approvers[0], g1);
        assertEq(shares[0], COVERAGE_USD, "g1 backed the whole thing");

        // ── Execute: the §3.3a quorum reads g1's bond live and finds it enough.
        vm.warp(gov.getProposal(pid).reviewEnd + 1);
        gov.executeProposal(pid);
        assertEq(_state(pid), uint256(ISyndicateGovernor.ProposalState.Executed), "executed");
        assertEq(gov.getProposal(pid).executedAt, vm.getBlockTimestamp(), "executedAt stamped now");
        assertEq(adapter.pokes(), 1, "the batch really ran");
        assertEq(adapter.bumps(), 1);
    }

    /// @dev The ledger-level proof that the freeze BINDS: `releaseApproval` is
    ///      registry-gated, so this is exactly the call a vote change would make.
    function _expectReleaseBlocked(uint256 pid) internal {
        vm.prank(address(registry));
        vm.expectRevert(IExposureLedger.CoverageFrozen.selector);
        ledger.releaseApproval(address(gov), pid, g1);
    }

    // ── 1. The happy arc: a real drain is challenged, slashed and compensated ──

    /// @notice Spec §3.4 + §3.8, end to end and with nothing mocked. A tier-2
    ///         proposal is proposed under a real bond, approved by a real staked
    ///         guardian whose coverage is really booked, and executed. A
    ///         watchtower files a bonded predicate-1 challenge naming the
    ///         certified adapter; the filing freezes that proposal's coverage so
    ///         the accused cannot recycle its budget while under challenge.
    ///         Nobody contests, so silence is the verdict (D1): the covering
    ///         approver is slashed into the compensation escrow as a case pinned
    ///         to the block before the drain (D6), the named adapter loses its
    ///         certification (D7), the challenger is made whole, the freeze
    ///         lifts — and the pre-drain LPs, not the buyer who arrived after,
    ///         redeem the proceeds.
    function test_happyArc_challengeSlashesApproverAndCompensatesPreDrainLps() public {
        uint256 pid = _proposeApproveExecute();
        uint256 executedAt = gov.getProposal(pid).executedAt;
        uint256 challengerBalBefore = wood.balanceOf(challenger);

        // ── File. Bond pulled, coverage frozen, challenge recorded.
        vm.prank(challenger);
        uint256 cid = game.file(
            address(gov),
            pid,
            IChallengeGame.Predicate.OutOfAdapterOutflow,
            address(adapter),
            adapter.poke.selector,
            "ipfs://evidence/out-of-adapter-outflow"
        );
        assertEq(cid, 1, "the first challenge");
        assertEq(game.liveChallengeOf(address(gov), pid), cid, "and it is the live one");
        assertEq(wood.balanceOf(address(game)), CHALLENGER_BOND, "the game custodies the bond");
        assertEq(wood.balanceOf(challenger), challengerBalBefore - CHALLENGER_BOND, "the challenger paid it");
        assertEq(game.bondedWood(), CHALLENGER_BOND, "and books it as live");

        IChallengeGame.Challenge memory c = game.challengeOf(cid);
        assertEq(uint256(c.status), uint256(IChallengeGame.Status.Filed), "Filed");
        assertEq(c.frozenCoverageUsd, COVERAGE_USD, "the bond was sized against the frozen coverage");
        assertEq(c.bondWood, CHALLENGER_BOND, "5% of $1,000 at $0.05/WOOD");
        assertEq(c.adapterTarget, address(adapter), "the filing names the adapter it accuses");
        assertEq(c.adapterSelector, adapter.poke.selector);
        assertEq(c.filedAt, vm.getBlockTimestamp());

        // ── The freeze BINDS (§3.4, D3): the accused guardian genuinely cannot
        //    release this commitment and recycle the budget while challenged.
        assertTrue(ledger.isCoverageFrozen(address(gov), pid), "coverage pinned");
        _expectReleaseBlocked(pid);
        assertEq(ledger.openExposureUsd(g1), COVERAGE_USD, "still committed");

        // ── The drain settles and a buyer arrives AFTER it. A real deposit —
        //    its shares and its vote checkpoints both move, they just move too
        //    late to matter to a case pinned to the pre-drain block.
        vm.warp(executedAt + 1 hours + 1);
        vm.prank(agent);
        gov.settleProposal(pid);
        assertEq(_state(pid), uint256(ISyndicateGovernor.ProposalState.Settled), "settled");
        assertTrue(ledger.isCoverageFrozen(address(gov), pid), "settling does not lift a challenge freeze");
        _deposit(buyer, BUYER_ASSETS);
        assertEq(vault.balanceOf(buyer), BUYER_SHARES, "the buyer really holds shares");
        assertEq(vault.delegates(buyer), buyer, "and is auto-delegated like everyone else");

        // ── The verdict is not due yet.
        vm.expectRevert(IChallengeGame.DelayNotElapsed.selector);
        game.resolve(cid);

        // ── Silence. Resolve is permissionless, so anyone may execute it.
        vm.warp(c.filedAt + game.autoSlashDelay());
        game.resolve(cid);

        // ── The verdict landed: the approver paid, and the whole of it reached
        //    the escrow as a case pinned to the block BEFORE the drain (D6).
        assertEq(uint256(game.challengeOf(cid).status), uint256(IChallengeGame.Status.Settled), "Settled");
        assertEq(
            swood.guardianStake(g1),
            G1_STAKE - PROCEEDS,
            "the approver paid exactly what it underwrote -- and no more, so the residue can still answer a second case"
        );
        assertEq(escrow.caseCount(), 1, "one compensation case");
        uint256 caseId = escrow.caseCount();
        (address caseVault, uint256 snapTs, uint256 proceeds, uint256 redeemed,,, bool swept) = escrow.caseOf(caseId);
        assertEq(caseVault, address(vault), "pinned to the real vault");
        assertEq(snapTs, executedAt - 1, "and to the block before the drain executed (D6)");
        assertEq(proceeds, PROCEEDS, "the full slash reached the escrow");
        assertEq(redeemed, 0);
        assertFalse(swept);
        assertEq(wood.balanceOf(address(escrow)), PROCEEDS, "the escrow holds it");
        assertEq(escrow.totalEscrowed(), PROCEEDS);

        // ── The named adapter lost its certification (§3.4 / D7).
        (uint8 tierAfter, uint16 boundAfter) = tierRegistry.tierOf(address(adapter), adapter.poke.selector);
        assertEq(tierAfter, 2, "demoted back to the arbitrary-calldata default");
        assertEq(boundAfter, 10_000, "and back to full notional");

        // ── The challenger gets its bond back LESS the settle burn (review F4:
        //    a correct filing is cheap, not free — the old full refund fully
        //    subsidised an attacker whose payoff is the consequence rather than
        //    the bond). Nothing is stranded in the game either way.
        uint256 settleBurn = (CHALLENGER_BOND * game.settleBurnBps()) / 10_000;
        assertGt(settleBurn, 0, "the burn is live in this fixture");
        assertEq(wood.balanceOf(challenger), challengerBalBefore - settleBurn, "bond back less the burn");
        assertEq(wood.balanceOf(address(game)), 0, "the game holds nothing");
        assertEq(game.bondedWood(), 0, "and books nothing as live");
        assertEq(game.liveChallengeOf(address(gov), pid), 0, "no live challenge remains");

        // ── The freeze lifted on the terminal path, and the guardian can
        //    actually release again — proving the pin was the challenge's, not
        //    a one-way door.
        assertFalse(ledger.isCoverageFrozen(address(gov), pid), "unfrozen");
        vm.prank(address(registry));
        ledger.releaseApproval(address(gov), pid, g1);
        assertEq(ledger.openExposureUsd(g1), 0, "the guardian recycled its budget");

        // ── §3.8: the pre-drain cohort owns the whole case, exactly 70/30.
        assertEq(vault.getPastTotalSupply(snapTs), SNAP_SUPPLY, "snapshot supply is the two pre-drain LPs");
        assertEq(vault.getPastVotes(lp1, snapTs), LP1_SHARES, "LP1 held 70%");
        assertEq(vault.getPastVotes(lp2, snapTs), LP2_SHARES, "LP2 held 30%");
        assertEq(vault.getPastVotes(buyer, snapTs), 0, "the buyer held nothing pre-drain");
        assertEq(escrow.claimable(caseId, lp1), LP1_CLAIM);
        assertEq(escrow.claimable(caseId, lp2), LP2_CLAIM);
        assertEq(LP1_CLAIM + LP2_CLAIM, PROCEEDS, "the two claims exhaust the case");

        // Hoisted before the pranked calls: a cheatcode in argument position is
        // consumed by the inner call.
        uint256 lp1Before = wood.balanceOf(lp1);
        uint256 lp2Before = wood.balanceOf(lp2);
        vm.prank(lp1);
        uint256 got1 = escrow.redeem(caseId);
        vm.prank(lp2);
        uint256 got2 = escrow.redeem(caseId);
        assertEq(got1, LP1_CLAIM, "LP1 redeemed its 70%");
        assertEq(got2, LP2_CLAIM, "LP2 redeemed its 30%");
        assertEq(wood.balanceOf(lp1), lp1Before + LP1_CLAIM, "LP1 actually received the WOOD");
        assertEq(wood.balanceOf(lp2), lp2Before + LP2_CLAIM, "LP2 actually received the WOOD");
        assertEq(escrow.totalEscrowed(), 0, "the whole slash reached pre-drain holders");

        // ── Finding F1, against the real vault: post-drain shares carry no
        //    claim, however real the purchase.
        assertEq(escrow.claimable(caseId, buyer), 0, "the post-drain buyer has no claim");
        vm.prank(buyer);
        vm.expectRevert(ICompensationEscrow.NoClaim.selector);
        escrow.redeem(caseId);
        assertEq(wood.balanceOf(buyer), 0, "and got nothing at all");
    }

    // ── 2. The bad-faith arc: the bond is a real deterrent ────────────────

    /// @notice D5's fail-safe, and the reason the challenger's bond is
    ///         load-bearing rather than ceremonial. A CLEAN proposal is
    ///         challenged; an accused approver buys the escalation with a
    ///         matching counter-bond, which stops the auto-slash clock. The
    ///         court of §3.5 does not exist yet, so nobody rules — and rather
    ///         than pinning the guardian's coverage forever, the challenge fails
    ///         to the accused once `disputeTimeout` elapses: the challenger's
    ///         bond forfeits pro-rata to what each accused actually committed,
    ///         the counter-bond returns to whoever posted it, the coverage
    ///         unfreezes, and the guardian can release it normally again.
    ///
    ///         Nothing is slashed, no case is opened, and the adapter keeps its
    ///         certification — a failed challenge must leave no mark.
    function test_badFaithArc_disputedChallengeTimesOutToTheAccused() public {
        uint256 pid = _proposeApproveExecute();
        uint256 challengerBalBefore = wood.balanceOf(challenger);
        uint256 g1BalBefore = wood.balanceOf(g1);
        uint256 g1StakeBefore = swood.guardianStake(g1);

        // ── A bad-faith filing against a clean proposal. Nothing on-chain can
        //    tell it apart from the honest one — that is D1's whole point, and
        //    the bond is what prices the difference.
        vm.prank(challenger);
        uint256 cid = game.file(
            address(gov),
            pid,
            IChallengeGame.Predicate.ProposerLinkedOutflow,
            address(adapter),
            adapter.poke.selector,
            "ipfs://evidence/fabricated"
        );
        assertTrue(ledger.isCoverageFrozen(address(gov), pid), "even a bad-faith filing pins the coverage");
        _expectReleaseBlocked(pid);
        assertEq(game.bondedWood(), CHALLENGER_BOND);

        uint256 filedAt = game.challengeOf(cid).filedAt;

        // ── The accused answers, inside the window, at the same price the
        //    challenger paid.
        vm.warp(filedAt + 1 hours);
        vm.prank(g1);
        game.dispute(cid, type(uint256).max);
        IChallengeGame.Challenge memory c = game.challengeOf(cid);
        assertEq(uint256(c.status), uint256(IChallengeGame.Status.Disputed), "Disputed");
        assertEq(c.counterBondWood, CHALLENGER_BOND, "the counter-bond pool matches the bond");
        address[] memory funders = game.counterBondContributors(cid);
        assertEq(funders.length, 1, "g1 covered all the coverage, so it funds the whole defence alone");
        assertEq(funders[0], g1);
        assertEq(game.counterBondContributionOf(cid, g1), CHALLENGER_BOND, "the forfeit follows this, not coverage");
        assertEq(game.bondedWood(), 2 * CHALLENGER_BOND, "both bonds are live");
        assertEq(wood.balanceOf(address(game)), 2 * CHALLENGER_BOND);
        assertEq(wood.balanceOf(g1), g1BalBefore - CHALLENGER_BOND, "the accused paid for the escalation");

        // ── The dispute really did stop the auto-slash clock: at the instant the
        //    silence verdict WOULD have fired, resolve still refuses.
        vm.warp(filedAt + game.autoSlashDelay());
        vm.expectRevert(IChallengeGame.DelayNotElapsed.selector);
        game.resolve(cid);
        assertEq(swood.guardianStake(g1), g1StakeBefore, "nothing slashed while the escalation stands");
        assertEq(escrow.caseCount(), 0, "and no case opened");

        // ── Nobody rules. D5: the challenge fails safe, in favour of the accused.
        vm.warp(filedAt + game.disputeTimeout());
        game.resolve(cid);
        assertEq(uint256(game.challengeOf(cid).status), uint256(IChallengeGame.Status.Failed), "Failed");

        // ── The bond is a real cost to the challenger and a real payment to the
        //    accused; the counter-bond is returned, not staked on the outcome.
        assertEq(wood.balanceOf(challenger), challengerBalBefore - CHALLENGER_BOND, "the challenger forfeited it");
        // The forfeit reaches the defence MINUS the burned slice: g1 funded 100%
        // of the pool, so it takes 100% of what is distributed. The burn is what
        // stops that funder from profitably being the challenger's own second
        // address.
        uint256 burned = (CHALLENGER_BOND * game.forfeitBurnBps()) / 10_000;
        assertEq(
            wood.balanceOf(g1),
            g1BalBefore + CHALLENGER_BOND - burned,
            "contribution returned plus the whole UNBURNED forfeit (g1 funded 100% of the pool)"
        );
        assertEq(wood.balanceOf(game.BURN_ADDRESS()), burned, "and the burned slice left the system for good");
        assertEq(wood.balanceOf(address(game)), 0, "nothing stranded in the game");
        assertEq(game.bondedWood(), 0);

        // ── A failed challenge leaves no mark anywhere else.
        assertEq(swood.guardianStake(g1), g1StakeBefore, "the accused was never slashed");
        assertEq(escrow.caseCount(), 0, "no compensation case was ever opened");
        assertEq(escrow.totalEscrowed(), 0);
        (uint8 tierAfter, uint16 boundAfter) = tierRegistry.tierOf(address(adapter), adapter.poke.selector);
        assertEq(tierAfter, 1, "the adapter keeps its certification");
        assertEq(boundAfter, CERTIFIED_BOUND_BPS);

        // ── And the coverage the filing pinned is genuinely free again.
        assertFalse(ledger.isCoverageFrozen(address(gov), pid), "unfrozen on the fail path too");
        assertEq(game.liveChallengeOf(address(gov), pid), 0, "no live challenge remains");
        assertEq(ledger.openExposureUsd(g1), COVERAGE_USD, "still committed until released");
        vm.prank(address(registry));
        ledger.releaseApproval(address(gov), pid, g1);
        assertEq(ledger.openExposureUsd(g1), 0, "the guardian recycled the budget a bad-faith filing had pinned");
    }
}
