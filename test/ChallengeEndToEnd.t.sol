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
import {ProposerBondEscrow} from "../src/ProposerBondEscrow.sol";
import {BatchExecutorLib} from "../src/BatchExecutorLib.sol";
import {ProtocolConfig} from "../src/ProtocolConfig.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "./mocks/MockAgentRegistry.sol";
import {MockWoodTwapOracle} from "./mocks/MockWoodTwapOracle.sol";
import {GovEnvelope} from "./helpers/GovEnvelope.sol";
import {deployTierRegistry} from "./helpers/TierRegistryFixture.sol";

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

/// @dev The court's only job in this suite is to hand `ChallengeGame.rule` an
///      `Inconclusive` verdict, so it implements exactly the two views
///      `_requireWindowFits` reads at `setCourt` and nothing else. `refer` is
///      deliberately absent: `dispute`'s auto-referral is a try/catch, so the
///      missing selector is swallowed and the challenge stays `Disputed` —
///      which is the state `rule` requires. The turnout arithmetic that picks
///      between the three verdicts belongs to `TokenCourt` and is proven in
///      `TokenCourt.t.sol` and `TokenCourtEndToEnd.t.sol`; what is under test
///      here is the GOVERNOR-side consequence of the verdict, not a second
///      copy of the vote count.
///
///      7d `autoSlashDelay` + 5d + 1d == 13d, inside the shipped 30d
///      `disputeTimeout`, so `setCourt`'s window invariant accepts it.
contract StubInconclusiveCourt {
    uint256 public constant FINALIZE_BUFFER = 1 days;
    uint256 public constant voteWindow = 5 days;
}

/// @title ChallengeEndToEndTest
/// @notice Plan D Task 5 — the whole challenge game against the REAL stack, with
///         no mock standing in for a protocol contract anywhere: a real UUPS
///         `StakedWood` proxy holding a real staked+matured guardian, a real
///         `GuardianRegistry` running a real review window, a real
///         `SyndicateVault` + `SyndicateGovernor` executing a real proposal, a
///         real `ExposureLedger` booking the coverage that approval commits, a
///         real `TierRegistry` holding the certification a passed challenge
///         revokes, and a real `ChallengeGame` wired into all of its roles.
///
/// @dev    The roles, each of them load-bearing for one leg of the arcs below:
///           - `ledger.coverageFreezer`         → the per-proposal freeze (D3)
///           - `tierRegistry.authorizedDemoter` → the passed-challenge demotion (D7)
///           - `swood.authorizedSlasher`        → the silence verdict's slash (D1)
///           - the slash has no sink to redirect and no payee at all: every
///             wei burns. The prosecutor's fee comes from the convicted
///             proposer's forfeited bond instead, and `ProposerBondEscrow`
///             bounds the rate itself rather than trusting the game's clamp —
///             the same reason `slashBpsPer` is re-clamped in sWOOD rather
///             than trusted from `ExposureLedger`.
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
    /// @dev Issue #43 per-call caps: `_execCalls()` has 2 calls (`poke`
    ///      certified at CERTIFIED_BOUND_BPS, `bump` uncertified) and the
    ///      test-fixture default (`GovEnvelope.defaultCaps`) caps only the
    ///      FIRST call — `poke` gets `maxCapital`, `bump` gets 0 (a zero cap
    ///      is a legal declaration at every tier: "this call moves no vault
    ///      asset"). `requiredCoverage` = (maxCapital * 5_000/10_000) [exec
    ///      poke] + 0 [exec bump, zero cap] + (maxCapital * 5_000/10_000)
    ///      [settle poke, default cap = maxCapital] = maxCapital = 500e6.
    uint256 constant REQUIRED_COVERAGE = 500e6;
    uint256 constant COVERAGE_USD = 500e18;
    uint256 constant PROPOSER_BOND = 100e18; // $500 × 1% ÷ $0.05

    /// @dev The verdict no longer takes the lot. g1 committed $1,000 of
    ///      coverage against a $1,500 slashable bond (G1_STAKE at $0.05), so the
    ///      ledger prices its liability at `ceil(1_000 * 10_000 / 1_500)` = 6667
    ///      bps of its own stake — what it underwrote, rounded toward the
    ///      protocol. The remainder stays staked and is still available to a
    ///      second, concurrent conviction, which is the point of per-approver
    ///      rates.
    /// @dev RETIRED with the compensatory rate. `VERDICT_BPS` was the
    ///      coverage-proportional figure `slashBpsFor` used to derive (6,667 —
    ///      two thirds of a bond, being this fixture's share of the loss). The
    ///      rate is now the severity ceiling for every committed approver, so
    ///      the whole of `G1_STAKE` is taken and the split constants that
    ///      apportioned it between LPs have no meaning.

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
        _bondVaultOwner(address(vault));
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
        // Design revision 2: `woodUsdPriceX8` is a CAP, never a price. WOOD is
        // valued from the TWAP oracle at $0.05, with the cap 2x ABOVE it and
        // therefore NOT binding — the configuration production ships. Every
        // dollar figure in this suite is unchanged; only the reason it holds is.
        MockWoodTwapOracle woodTwap = new MockWoodTwapOracle(0.05e8);
        vm.startPrank(ledgerOwner);
        ledger.setWoodUsdPrice(0.1e8);
        ledger.setWoodTwapOracle(address(woodTwap));
        // Generous staleness bound: the §3.3a quorum re-reads this feed at
        // EXECUTE time, a full voting + review window after propose.
        ledger.setAssetFeed(address(usdg), address(feed), 365 days);
        ledger.setCoveredTvlCapUsd(10_000_000e18);
        ledger.setGuardianRegistry(address(registry));
        vm.stopPrank();
        vm.prank(owner);
        registry.setExposureLedger(address(ledger));

        bondEscrow = new ProposerBondEscrow(address(wood), address(registry), address(ledger));

        // ── The game, then its roles.
        game = new ChallengeGame(owner, address(wood), address(ledger), address(tierRegistry));
        vm.prank(ledgerOwner);
        ledger.setCoverageFreezer(address(game));
        tierRegistry.setAuthorizedDemoter(address(game));
        vm.startPrank(owner);
        swood.setAuthorizedSlasher(address(game));
        game.setStakedWood(address(swood));
        vm.stopPrank();

        // ── Governor wiring (the test contract is the factory).
        gov.setExposureLedger(address(ledger));
        gov.setBondEscrow(address(bondEscrow));
        gov.setTierRegistry(address(tierRegistry));

        // The certification a passed challenge will revoke. `poke` is priced at
        // half notional; `bump` is left uncertified so the batch as a whole is
        // still tier 2 and therefore coverage-gated.
        //
        // Two-step certification (design.md / tasks.md 2.1): the test contract
        // IS the registry owner, so no prank is needed — propose, warp past
        // the pinned `readyAt` (`vm.getBlockTimestamp()`, never a cached
        // `block.timestamp` local — the optimizer CSEs it across `vm.warp`),
        // execute. Every later warp in this suite reads live state
        // (`gov.getProposal(...)`, `game.challengeOf(...)`, or an
        // in-test-live `filedAt`/`executedAt`), so this setUp-time shift is safe.
        tierRegistry.proposeCertification(
            address(adapter), adapter.poke.selector, 1, CERTIFIED_BOUND_BPS, address(0), address(adapter).codehash
        );
        vm.warp(vm.getBlockTimestamp() + tierRegistry.certifyDelay());
        tierRegistry.certify(address(adapter), adapter.poke.selector);
        // issue #166: certifying a (target, selector) prices it for tiering
        // but does NOT make `target` batch-callable at all — that is a
        // SEPARATE allowlist (`isAdapterAllowed`) `SyndicateVault._guardBatchCalls`
        // PART 2a now enforces on every batch callee. `adapter` is this
        // suite's real, benign (fund-neutral) production-shaped adapter, not
        // an attacker probe — it must be explicitly allowlisted here or every
        // proposal touching it (execute AND settlement calls) is refused with
        // `DisallowedBatchCallee` before any challenge/coverage mechanics run.
        tierRegistry.setAdapterAllowed(address(adapter), true);

        // ── WOOD for the proposer's bond, the challenger's bond, and the
        //    accused guardian's counter-bond.
        wood.mint(agent, 1_000_000e18);
        vm.prank(agent);
        wood.approve(address(bondEscrow), type(uint256).max);
        // 2x, not 1x: `_driveToInconclusiveRearm` (issue #94 fixtures) files
        // once, takes a round-1 Inconclusive burn on the refund, and a
        // second test-body filing then needs a FULL fresh bond out of what's
        // left — a bare 1x mint left no headroom for that once the mint
        // amount stopped being a stale, accidentally-oversized literal (was
        // 500e18 against a live-computed ~150e18 pull) and started tracking
        // the real bond exactly.
        wood.mint(challenger, _challengerBond() * 2);
        vm.prank(challenger);
        wood.approve(address(game), type(uint256).max);
        wood.mint(g1, _challengerBond()); // counter-bond matches the challenger's
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
                address(this),
                address(deployTierRegistry(address(this))), // factory
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

    /// @dev Mirrors `ChallengeGame.file`'s bond formula exactly, and reads
    ///      `challengerBondBps` LIVE off the contract rather than hardcoding
    ///      it — audit #181 finding 18a moved it from 500 to 150, and a
    ///      future parameter change should not have to touch this fixture.
    ///      Mirrors `ChallengeGame.t.sol`'s own `_expectedBondWood` /
    ///      `_standardBondWood` helpers.
    function _challengerBond() internal view returns (uint256) {
        return (((COVERAGE_USD * game.challengerBondBps()) / 10_000) * 1e8) / 0.05e8;
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
            GovEnvelope.defaultCaps(
                (ISyndicateGovernor.RiskEnvelope({maxCapital: MAX_CAPITAL, maxDrawdownBps: 10_000})).maxCapital,
                (_execCalls()).length
            ),
            _settleCalls(),
            GovEnvelope.defaultCaps(
                (ISyndicateGovernor.RiskEnvelope({maxCapital: MAX_CAPITAL, maxDrawdownBps: 10_000})).maxCapital,
                (_settleCalls()).length
            ),
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
        assertEq(ledger.openExposure(g1), 0, "no exposure before the vote");
        // g1 DECLARES its whole stake: `type(uint256).max` clamps to the free
        // budget (`kNumerator x stake - openExposure`, k = 1), so the lock is
        // the entire 30,000 WOOD bond and a conviction burns all of it — the
        // shape every dollar figure in the two arcs below was written for.
        // `test_partialLock_*` is the arc where the lock is smaller than the
        // bond.
        vm.prank(g1);
        registry.voteOnProposal(address(gov), pid, IGuardianRegistry.GuardianVoteType.Approve, type(uint256).max);
        assertEq(ledger.openExposure(g1), G1_STAKE, "approve locks the whole declared stake");

        (address[] memory approvers, uint256[] memory locks) = ledger.approversOf(address(gov), pid);
        assertEq(approvers.length, 1, "one covering approver");
        assertEq(approvers[0], g1);
        assertEq(locks[0], G1_STAKE, "g1 locked its whole bond");
        assertEq(ledger.coverageUsdOf(address(gov), pid, g1), 1_500e18, "worth $1,500 at $0.05, uncapped");
        assertEq(
            ledger.liabilityUsd(address(gov), pid), COVERAGE_USD, "recoverable for THIS proposal: capped at the need"
        );

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
        assertEq(wood.balanceOf(address(game)), _challengerBond(), "the game custodies the bond");
        assertEq(wood.balanceOf(challenger), challengerBalBefore - _challengerBond(), "the challenger paid it");
        assertEq(game.bondedWood(), _challengerBond(), "and books it as live");

        IChallengeGame.Challenge memory c = game.challengeOf(cid);
        assertEq(uint256(c.status), uint256(IChallengeGame.Status.Filed), "Filed");
        assertEq(c.frozenCoverageUsd, COVERAGE_USD, "the bond was sized against the frozen coverage");
        assertEq(c.bondWood, _challengerBond(), "challengerBondBps of $1,000 at $0.05/WOOD");
        assertEq(c.adapterTarget, address(adapter), "the filing names the adapter it accuses");
        assertEq(c.adapterSelector, adapter.poke.selector);
        assertEq(c.filedAt, vm.getBlockTimestamp());

        // ── The freeze BINDS (§3.4, D3): the accused guardian genuinely cannot
        //    release this commitment and recycle the budget while challenged.
        assertTrue(ledger.isCoverageFrozen(address(gov), pid), "coverage pinned");
        _expectReleaseBlocked(pid);
        assertEq(ledger.openExposure(g1), G1_STAKE, "still locked");

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

        // Hoisted before `resolve`: these are the balances the burn is measured
        // against, and a cheatcode in argument position is consumed by the
        // inner call.
        // sWOOD's OWN balance, not the burn address: the burn address also
        // receives the challenger's settle-burn, so a delta measured there
        // conflates two sinks. Only a slash moves WOOD out of the custodian.
        uint256 swoodBalBefore = wood.balanceOf(address(swood));
        uint256 lp1Before = wood.balanceOf(lp1);
        uint256 lp2Before = wood.balanceOf(lp2);

        // ── Silence. Resolve is permissionless, so anyone may execute it.
        vm.warp(c.filedAt + game.autoSlashDelay());
        game.resolve(cid);

        // ── The verdict landed. THE BURN IS THE LOCK: g1 declared its whole
        //    bond, so its whole bond goes — and every wei is destroyed rather
        //    than paid to anyone. (A smaller declaration burns a smaller lock;
        //    see `test_partialLock_*`.)
        assertEq(uint256(game.challengeOf(cid).status), uint256(IChallengeGame.Status.Settled), "Settled");
        assertEq(swood.guardianStake(g1), 0, "the lock was the whole bond, so the whole bond burns");
        assertEq(
            swoodBalBefore - wood.balanceOf(address(swood)),
            G1_STAKE,
            "and the whole of it left the custodian for the burn address"
        );
        assertEq(swood.pendingBurn(), 0, "the burn transfer landed; nothing parked for a flush retry");

        // ── The named adapter lost its certification (§3.4 / D7).
        (uint8 tierAfter, uint16 boundAfter) = tierRegistry.tierOf(address(adapter), adapter.poke.selector);
        assertEq(tierAfter, 2, "demoted back to the arbitrary-calldata default");
        assertEq(boundAfter, 10_000, "and back to full notional");

        // ── The challenger gets its bond back LESS the settle burn (review F4:
        //    a correct filing is cheap, not free — the old full refund fully
        //    subsidised an attacker whose payoff is the consequence rather than
        //    the bond). Nothing is stranded in the game either way.
        //
        //    IT ALSO COLLECTS THE PROSECUTOR'S FEE, and this is the silence
        //    path — the one where a correct filing used to pay nothing at all
        //    and cost the filer `settleBurnBps` of its bond. The fee comes from
        //    the convicted PROPOSER's forfeited bond, the one pot a prosecutor
        //    cannot fund for itself.
        uint256 settleBurn = (_challengerBond() * game.settleBurnBps()) / 10_000;
        assertGt(settleBurn, 0, "the burn is live in this fixture");
        uint256 prosecutorFee = (PROPOSER_BOND * game.prosecutorFeeBps()) / 10_000;
        assertGt(prosecutorFee, 0, "and the fee is live too");
        assertEq(
            wood.balanceOf(challenger),
            challengerBalBefore - settleBurn + prosecutorFee,
            "bond back less the settle burn, plus the prosecutor's cut of the proposer bond"
        );
        assertEq(wood.balanceOf(address(game)), 0, "the game holds nothing");
        assertEq(game.bondedWood(), 0, "and books nothing as live");
        assertEq(game.liveChallengeOf(address(gov), pid), 0, "no live challenge remains");

        // ── The freeze lifted on the terminal path, and the guardian can
        //    actually release again — proving the pin was the challenge's, not
        //    a one-way door.
        assertFalse(ledger.isCoverageFrozen(address(gov), pid), "unfrozen");
        vm.prank(address(registry));
        ledger.releaseApproval(address(gov), pid, g1);
        assertEq(ledger.openExposure(g1), 0, "the guardian recycled its budget");

        // ── CAVEAT EMPTOR. Depositors are NOT made whole: there is no case, no
        //    claim, and no path by which any holder recovers slashed value. The
        //    vault's snapshot arithmetic still works — the shares moved exactly
        //    as they always did — it is simply never consulted, because nothing
        //    is apportioned.
        assertEq(vault.getPastTotalSupply(executedAt - 1), SNAP_SUPPLY, "the pre-drain cohort is still identifiable");
        assertEq(vault.getPastVotes(lp1, executedAt - 1), LP1_SHARES, "LP1 held 70% of it");
        assertEq(vault.getPastVotes(lp2, executedAt - 1), LP2_SHARES, "LP2 held 30%");
        assertEq(vault.getPastVotes(buyer, executedAt - 1), 0, "and the buyer held nothing pre-drain");

        // ...and none of that entitles anyone to anything.
        assertEq(wood.balanceOf(lp1), lp1Before, "LP1 recovers nothing from the slash");
        assertEq(wood.balanceOf(lp2), lp2Before, "nor does LP2");
        assertEq(wood.balanceOf(buyer), 0, "nor the post-drain buyer");

        // The old F1 attack — buy shares AFTER the drain to capture the
        // compensation — has no target left. There is no payout to race.
    }

    // ── 2. The bad-faith arc: the bond is a real deterrent ────────────────

    /// @notice D5's fail-safe. A CLEAN proposal is challenged; an accused
    ///         approver buys the escalation with a matching counter-bond, which
    ///         stops the auto-slash clock. The court of §3.5 does not exist
    ///         yet, so nobody rules — and rather than pinning the guardian's
    ///         coverage forever, the timeout unwinds the challenge once
    ///         `disputeTimeout` elapses.
    ///
    ///         A TIMEOUT WITH NO ADJUDICATOR IS A NON-VERDICT, NOT AN
    ///         ACQUITTAL (audit #181 finding 2). This path used to reach
    ///         `_fail`, forfeiting the challenger's whole bond to whoever
    ///         funded the counter-bond. Because `dispute` is open to ANYONE,
    ///         that made funding the defence of a challenge you filed yourself
    ///         a deterministic +80% round trip at the shipped rates, paid for
    ///         by every honest filer — so no rational party would ever file.
    ///         `courtAtFiling` is now pinned per challenge, and when it is the
    ///         zero address the timeout routes to `_refundAll`: both sides
    ///         unwind whole, exactly as `Inconclusive` already behaved.
    ///
    ///         The challenger is not made whole to the wei — it still pays the
    ///         round-1 anti-grinding burn (finding 19), which is what stops a
    ///         free filing from pinning a cohort's coverage for weeks. That is
    ///         a small toll on the filer, not a transfer to the accused.
    ///
    ///         Nothing is slashed, no case is opened, and the adapter keeps its
    ///         certification — an unwound challenge must leave no mark.
    function test_badFaithArc_disputedChallengeTimesOutToANonVerdict() public {
        uint256 pid = _proposeApproveExecute();
        uint256 challengerBalBefore = wood.balanceOf(challenger);
        uint256 g1BalBefore = wood.balanceOf(g1);
        uint256 g1StakeBefore = swood.guardianStake(g1);
        // sWOOD's own balance — the burn address also takes the challenger's
        // forfeit burn on this path, so it cannot distinguish "no slash".
        uint256 swoodBalBefore = wood.balanceOf(address(swood));

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
        assertEq(game.bondedWood(), _challengerBond());

        uint256 filedAt = game.challengeOf(cid).filedAt;

        // ── The accused answers, inside the window, at the same price the
        //    challenger paid.
        vm.warp(filedAt + 1 hours);
        vm.prank(g1);
        game.dispute(cid, type(uint256).max);
        IChallengeGame.Challenge memory c = game.challengeOf(cid);
        assertEq(uint256(c.status), uint256(IChallengeGame.Status.Disputed), "Disputed");
        assertEq(c.counterBondWood, _challengerBond(), "the counter-bond pool matches the bond");
        address[] memory funders = game.counterBondContributors(cid);
        assertEq(funders.length, 1, "g1 covered all the coverage, so it funds the whole defence alone");
        assertEq(funders[0], g1);
        assertEq(game.counterBondContributionOf(cid, g1), _challengerBond(), "the forfeit follows this, not coverage");
        assertEq(game.bondedWood(), 2 * _challengerBond(), "both bonds are live");
        assertEq(wood.balanceOf(address(game)), 2 * _challengerBond());
        assertEq(wood.balanceOf(g1), g1BalBefore - _challengerBond(), "the accused paid for the escalation");

        // ── The dispute really did stop the auto-slash clock: at the instant the
        //    silence verdict WOULD have fired, resolve still refuses.
        vm.warp(filedAt + game.autoSlashDelay());
        vm.expectRevert(IChallengeGame.DelayNotElapsed.selector);
        game.resolve(cid);
        assertEq(swood.guardianStake(g1), g1StakeBefore, "nothing slashed while the escalation stands");
        assertEq(wood.balanceOf(address(swood)), swoodBalBefore, "and no WOOD left the custodian");

        // ── Nobody rules, and no court was ever wired — so the timeout is a
        //    NON-VERDICT, not an acquittal. Both sides unwind.
        vm.warp(filedAt + game.disputeTimeout());
        IChallengeGame.Challenge memory cAt = game.challengeOf(cid);
        assertEq(cAt.courtAtFiling, address(0), "fixture: this challenge was filed against an unwired game");
        game.resolve(cid);
        assertEq(
            uint256(game.challengeOf(cid).status), uint256(IChallengeGame.Status.Inconclusive), "unwound, not acquitted"
        );

        // ── The challenger keeps its bond less ONLY the round-1 anti-grinding
        //    burn. Derived from the rate pinned at filing, not hardcoded, so a
        //    later schedule change does not silently invalidate this.
        uint256 burned = (_challengerBond() * cAt.inconclusiveBurnBpsAtFiling) / 10_000;
        assertGt(burned, 0, "round 1 is priced, not free (finding 19)");
        assertEq(
            wood.balanceOf(challenger),
            challengerBalBefore - burned,
            "the challenger keeps its bond less only the anti-grinding burn"
        );

        // ── The counter-bond funder recovers exactly what it put in and NOT a
        //    wei more. This is the assertion that proves the arbitrage is dead:
        //    funding the defence of a challenge you filed yourself is now
        //    strictly loss-making (you eat the burn), where it used to return
        //    +80% at the shipped rates.
        //
        //    Collected rather than pushed — resolution records the entitlement
        //    and the funder calls for it, which is what removed the unbounded
        //    payout loop and let contribution standing open up.
        vm.prank(g1);
        game.claimContribution(cid);
        assertEq(wood.balanceOf(g1), g1BalBefore, "the defence recovers its stake exactly, with no forfeit windfall");
        assertEq(wood.balanceOf(game.BURN_ADDRESS()), burned, "and the burned slice left the system for good");
        assertEq(wood.balanceOf(address(game)), 0, "nothing stranded in the game");
        assertEq(game.bondedWood(), 0);

        // ── A failed challenge leaves no mark anywhere else.
        assertEq(swood.guardianStake(g1), g1StakeBefore, "the accused was never slashed");
        assertEq(wood.balanceOf(address(swood)), swoodBalBefore, "and no WOOD left the custodian on its behalf");
        (uint8 tierAfter, uint16 boundAfter) = tierRegistry.tierOf(address(adapter), adapter.poke.selector);
        assertEq(tierAfter, 1, "the adapter keeps its certification");
        assertEq(boundAfter, CERTIFIED_BOUND_BPS);

        // ── And the coverage the filing pinned is genuinely free again.
        assertFalse(ledger.isCoverageFrozen(address(gov), pid), "unfrozen on the fail path too");
        assertEq(game.liveChallengeOf(address(gov), pid), 0, "no live challenge remains");
        assertEq(ledger.openExposure(g1), G1_STAKE, "still locked until released");
        vm.prank(address(registry));
        ledger.releaseApproval(address(gov), pid, g1);
        assertEq(ledger.openExposure(g1), 0, "the guardian recycled the budget a bad-faith filing had pinned");
    }

    // ── 3. The proposer bond is a deterrent, not a deposit ─────────────────

    /// @notice THE SELF-SETTLE RACE. `MIN_STRATEGY_DURATION_BEFORE_SELF_SETTLE`
    ///         lets the PROPOSER settle its own strategy an hour after
    ///         execution, while everyone else waits `strategyDuration`. That
    ///         hour is two orders of magnitude shorter than the window a
    ///         challenge has to be filed in, so a proposer that executed a
    ///         drain used to be able to self-settle at +1h, reclaim its whole
    ///         bond from the terminal `Settled` state, and be gone long before
    ///         anything could convict it — the bond deterred nothing it was
    ///         posted to deter.
    ///
    ///         An EXECUTED proposal therefore holds its bond until the
    ///         challenge window has run out from `executedAt`. Settlement is
    ///         still not a conviction: once no filing can arrive, the bond
    ///         returns in full to the proposer, permissionlessly and unburned.
    function test_settledProposal_bondLockedUntilTheChallengeWindowCloses() public {
        uint256 pid = _proposeApproveExecute();
        uint256 agentBalAfterBond = wood.balanceOf(agent);

        vm.warp(gov.getProposal(pid).executedAt + 1 hours + 1);
        vm.prank(agent);
        gov.settleProposal(pid);
        assertEq(_state(pid), uint256(ISyndicateGovernor.ProposalState.Settled), "self-settled an hour in");

        // The terminal state is reached, and the bond still does not move.
        vm.expectRevert(ISyndicateGovernor.ChallengeWindowOpen.selector);
        gov.reclaimProposerBond(pid);
        assertEq(wood.balanceOf(address(bondEscrow)), PROPOSER_BOND, "the escrow still holds it");

        // Anchored on what the CONTRACT stored, never on a local captured
        // before a warp — the optimizer CSEs `block.timestamp` across
        // `vm.warp`, and `executedAt` is the value the gate itself reads.
        // `+ strategyDuration` (second-audit finding A): the filing deadline —
        // and therefore this hold — runs from the end of the strategy's TERM,
        // not from the instant it was executed. Self-settling early does not
        // shorten it.
        uint256 opensAt =
            gov.getProposal(pid).executedAt + gov.getProposal(pid).strategyDuration + ledger.challengeWindow();
        vm.warp(opensAt - 1);
        vm.expectRevert(ISyndicateGovernor.ChallengeWindowOpen.selector);
        gov.reclaimProposerBond(pid);

        // AT the deadline it still refuses, and that is not an off-by-one: the
        // game admits a filing while `block.timestamp <= deadline`, so this is
        // the last instant at which a challenger could still accuse this
        // proposal. Releasing here would reopen the overlap issue #94 is about,
        // one second wide. (This fixture's ledger and game windows are both
        // 14d, so the two deadlines coincide.)
        vm.warp(opensAt);
        vm.expectRevert(ISyndicateGovernor.ChallengeWindowOpen.selector);
        gov.reclaimProposerBond(pid);

        // One second later the last filing deadline has passed and the bond is
        // free — in full, to the proposer, on a permissionless call.
        vm.warp(opensAt + 1);
        vm.prank(makeAddr("stranger"));
        gov.reclaimProposerBond(pid);
        assertEq(wood.balanceOf(agent), agentBalAfterBond + PROPOSER_BOND, "returned whole, and to the proposer");
        assertEq(wood.balanceOf(address(bondEscrow)), 0, "escrow drained");
        assertEq(gov.getProposal(pid).proposerBondWood, 0);
    }

    /// @notice A LIVE CHALLENGE OUTLIVES THE FILING WINDOW, and the bond has to
    ///         outlive it too. `autoSlashDelay` (7d) runs from `filedAt`, so a
    ///         filing on the last day of the window convicts a week after the
    ///         window shut. A pure `executedAt + challengeWindow` gate would
    ///         hand the bond back mid-accusation and leave the forfeiture path
    ///         with nothing to confiscate — so the reclaim also refuses while
    ///         the ledger reports this proposal's coverage frozen, which is
    ///         exactly the flag a live filing sets and every terminal challenge
    ///         path clears.
    function test_liveChallenge_holdsTheBondPastTheWindow() public {
        uint256 pid = _proposeApproveExecute();
        uint256 executedAt = gov.getProposal(pid).executedAt;

        // Terminal FIRST, so what this test pins is the freeze gate and not
        // the pre-existing `ProposalNotTerminal` guard.
        vm.warp(executedAt + 1 hours + 1);
        vm.prank(agent);
        gov.settleProposal(pid);
        assertEq(_state(pid), uint256(ISyndicateGovernor.ProposalState.Settled), "self-settled an hour in");

        // File on the last day the window admits it.
        vm.warp(executedAt + game.challengeWindow() - 1);
        vm.prank(challenger);
        uint256 cid = game.file(
            address(gov),
            pid,
            IChallengeGame.Predicate.OutOfAdapterOutflow,
            address(adapter),
            adapter.poke.selector,
            "ipfs://evidence/late-filing"
        );

        // The ordinary window has now closed, and the bond stays put: the
        // accusation is live and unadjudicated.
        vm.warp(executedAt + ledger.challengeWindow() + 1);
        assertTrue(ledger.isCoverageFrozen(address(gov), pid), "the filing pinned the coverage");
        vm.expectRevert(ISyndicateGovernor.ChallengeWindowOpen.selector);
        gov.reclaimProposerBond(pid);

        // Silence convicts, so this bond is forfeited rather than released —
        // the freeze lifts on the terminal path either way.
        vm.warp(game.challengeOf(cid).filedAt + game.autoSlashDelay());
        game.resolve(cid);
        assertEq(uint256(game.challengeOf(cid).status), uint256(IChallengeGame.Status.Settled));
        assertFalse(ledger.isCoverageFrozen(address(gov), pid), "the freeze lifted with the verdict");
    }

    /// @notice THE OTHER HALF OF THE SAME FIX. Locking the reclaim is only
    ///         worth something if a conviction can actually take the bond, and
    ///         until now nothing could: the escrow's only exit was
    ///         release-to-proposer. A passed challenge now confiscates it —
    ///         burned, not paid to anyone (see `ProposerBondEscrow.forfeitBond`
    ///         for why every reachable payee is a round trip to the proposer) —
    ///         and the reclaim that would have returned it can never pay out
    ///         again.
    function test_conviction_forfeitsTheProposerBond() public {
        uint256 pid = _proposeApproveExecute();
        uint256 burnBalBefore = wood.balanceOf(game.BURN_ADDRESS());
        uint256 agentBalAfterBond = wood.balanceOf(agent);

        vm.prank(challenger);
        uint256 cid = game.file(
            address(gov),
            pid,
            IChallengeGame.Predicate.OutOfAdapterOutflow,
            address(adapter),
            adapter.poke.selector,
            "ipfs://evidence/out-of-adapter-outflow"
        );

        // Silence is the verdict (D1).
        vm.warp(game.challengeOf(cid).filedAt + game.autoSlashDelay());
        game.resolve(cid);
        assertEq(uint256(game.challengeOf(cid).status), uint256(IChallengeGame.Status.Settled), "convicted");

        // The proposer's bond is GONE — not sitting in the escrow waiting to be
        // reclaimed, and not returned to the proposer.
        assertEq(wood.balanceOf(address(bondEscrow)), 0, "the escrow no longer holds the bond");
        (address bondProposer, uint256 bondAmount) = bondEscrow.bondOf(address(gov), pid);
        assertEq(bondProposer, address(0), "the bond record is cleared");
        assertEq(bondAmount, 0);

        // THREE SINKS SHARE THIS ADDRESS NOW, so the total is asserted with all
        // three named rather than as "the bond plus the settle burn". The
        // conviction also slashes the covering approver, and those proceeds
        // burn here too — before, they went to the compensation escrow, so this
        // delta used to see only the bond and the challenger's settle burn. A
        // bare total would silently absorb a regression in any one leg.
        //
        //    The proposer bond arrives NET of the prosecutor's fee: that slice
        //    pays the challenger rather than burning, which is the whole point
        //    of funding the fee from this pot.
        uint256 settleBurn = (_challengerBond() * game.settleBurnBps()) / 10_000;
        uint256 prosecutorFee = (PROPOSER_BOND * game.prosecutorFeeBps()) / 10_000;
        assertEq(
            wood.balanceOf(game.BURN_ADDRESS()),
            burnBalBefore + (PROPOSER_BOND - prosecutorFee) + settleBurn + G1_STAKE,
            "proposer bond net of the fee, plus the settle burn, plus the whole slashed guardian bond"
        );
        assertEq(wood.balanceOf(agent), agentBalAfterBond, "the proposer got nothing back");

        // The conviction above demoted `adapter`'s certification, which (by
        // design — `TierRegistry._demote`'s natspec, "DELIBERATELY
        // OVER-BROAD") ALSO cleared its batch-callee allowlist entry
        // entirely. The pre-committed settlement batch (`_settleCalls()`,
        // set at propose time) still names `adapter`, so self-settle would
        // now hit the SAME `DisallowedBatchCallee` a fresh, never-certified
        // target would — this is issue #166's gate doing exactly its job on
        // a demoted target. The natspec's own documented recovery is one
        // owner `setAdapterAllowed` call; this test is not about that
        // recovery ceremony (it is about proposer-bond forfeiture / reclaim
        // mechanics), so perform it here to reach self-settle, same as a
        // real owner would before an already-convicted proposal is unstuck.
        tierRegistry.setAdapterAllowed(address(adapter), true);

        // Reclaim's forfeiture-acknowledge path only applies from a TERMINAL
        // state (design D3, same terminal gate every other reclaim path
        // goes through) — self-settle here, as a real proposer would once
        // the strategy winds down, well past `_settle`'s conviction above.
        vm.prank(agent);
        gov.settleProposal(pid);
        assertEq(_state(pid), uint256(ISyndicateGovernor.ProposalState.Settled), "self-settled after conviction");

        // And the reclaim path does not resurrect the bond, at any later
        // time — but (issue #117 L1) it also does not revert forever: it
        // acknowledges the forfeiture, clears the stale record, and moves no
        // WOOD.
        vm.warp(gov.getProposal(pid).executedAt + ledger.challengeWindow() + 365 days);
        uint256 burnBalBeforeReclaim = wood.balanceOf(game.BURN_ADDRESS());
        vm.expectEmit(true, true, true, true, address(gov));
        emit ISyndicateGovernor.ProposerBondForfeitureAcknowledged(pid, PROPOSER_BOND);
        gov.reclaimProposerBond(pid);
        assertEq(wood.balanceOf(agent), agentBalAfterBond, "still nothing");
        assertEq(wood.balanceOf(game.BURN_ADDRESS()), burnBalBeforeReclaim, "acknowledge moves no WOOD");
        assertEq(gov.getProposal(pid).proposerBondWood, 0, "the stale bond record is cleared");

        // A second call lands on the same terminal answer as an ordinary
        // release.
        vm.expectRevert(ISyndicateGovernor.NoBondToReclaim.selector);
        gov.reclaimProposerBond(pid);
    }

    // ── 4. Issue #94: the two clocks are independent ───────────────────────

    /// @dev Issue #94's timeline, run against the real game at shipped
    ///      defaults: execute at T0, file on day 13, escalate on day 19, and
    ///      land an `Inconclusive` ruling on day 24 — ten days PAST
    ///      `executedAt + challengeWindow`, which is exactly what makes both of
    ///      the governor's original gates read "open" while `_refundAll` has
    ///      simultaneously re-armed the filing deadline to day 38.
    ///
    ///      Every warp is forward-only and every timestamp is derived from a
    ///      value the CONTRACT stored (`executedAt`) or read back live, never
    ///      from a `block.timestamp` local captured before a warp — the
    ///      optimizer CSEs that across `vm.warp`.
    function _driveToInconclusiveRearm() internal returns (uint256 pid, uint256 cid) {
        pid = _proposeApproveExecute();
        uint256 executedAt = gov.getProposal(pid).executedAt;

        // Terminal FIRST, so what the probes pin is the filing-deadline gate
        // and not the pre-existing `ProposalNotTerminal` guard.
        vm.warp(executedAt + 1 hours + 1);
        vm.prank(agent);
        gov.settleProposal(pid);
        assertEq(_state(pid), uint256(ISyndicateGovernor.ProposalState.Settled), "self-settled an hour in");

        // Hoisted: a CREATE in argument position would consume the prank and
        // `setCourt` would run unpranked (`onlyOwner` → revert).
        address stubCourt = address(new StubInconclusiveCourt());
        vm.prank(owner);
        game.setCourt(stubCourt);

        // Day 13: a sock-puppet files on the second-to-last day of the window.
        vm.warp(executedAt + 13 days);
        vm.prank(challenger);
        cid = game.file(
            address(gov),
            pid,
            IChallengeGame.Predicate.OutOfAdapterOutflow,
            address(adapter),
            adapter.poke.selector,
            "ipfs://evidence/sock-puppet"
        );

        // Day 19: the accused self-disputes, inside `autoSlashDelay` (7d from
        // `filedAt`), which stops the silence clock and refers the case.
        vm.warp(executedAt + 19 days);
        vm.prank(g1);
        game.dispute(cid, type(uint256).max);
        assertEq(uint256(game.challengeOf(cid).status), uint256(IChallengeGame.Status.Disputed), "escalated");

        // Day 24: turnout misses the participation floor, so the court unwinds
        // rather than rules.
        vm.warp(executedAt + 24 days);
        vm.prank(stubCourt);
        game.rule(cid, IChallengeGame.Verdict.Inconclusive);
    }

    function _reviewKey(uint256 pid) internal view returns (bytes32) {
        return keccak256(abi.encode(address(gov), pid));
    }

    /// @notice ISSUE #94. `ChallengeGame._refundAll` does two things in one
    ///         call: it RELEASES the coverage freeze and it RE-ARMS
    ///         `challengeableUntil[rk]` to `block.timestamp + challengeWindow`.
    ///         The governor's original two gates read the ledger only — elapsed
    ///         time since `executedAt`, and the freeze — so between an
    ///         `Inconclusive` unwind landing past the ordinary window and the
    ///         re-armed deadline, BOTH of them said "open" while
    ///         `ChallengeGame.file` would still have taken an accusation.
    ///
    ///         The proposer could therefore walk its bond home on day 24 and an
    ///         honest challenge filed on day 30 would still convict — slashing
    ///         the approvers who merely underwrote it for 100% of their bond
    ///         while the party the threat model calls the actual attacker kept
    ///         its stake, and (since the prosecutor's fee is carved from that
    ///         same bond) paying the prosecutor nothing.
    ///
    ///         The bond now stays put for every instant a filing is still
    ///         admissible, and opens one second after the deadline — not at it.
    function test_issue94_inconclusiveRearm_holdsTheBondUntilFilingCloses() public {
        (uint256 pid, uint256 cid) = _driveToInconclusiveRearm();
        uint256 executedAt = gov.getProposal(pid).executedAt;

        assertEq(uint256(game.challengeOf(cid).status), uint256(IChallengeGame.Status.Inconclusive), "unwound");

        // ── The bug, stated as assertions rather than as prose: both of the
        //    governor's ORIGINAL gates are open right now.
        assertGt(vm.getBlockTimestamp(), executedAt + ledger.challengeWindow(), "the ledger's window lapsed on day 14");
        assertFalse(ledger.isCoverageFrozen(address(gov), pid), "and `_refundAll` released the freeze");

        // ── While the game's own deadline has been pushed a further 14 days out.
        uint256 rearmed = game.challengeableUntil(_reviewKey(pid));
        assertEq(rearmed, vm.getBlockTimestamp() + game.challengeWindow(), "re-armed to ruling + challengeWindow");
        assertEq(rearmed, executedAt + 38 days, "day 38, exactly the figure in the issue");

        // ── Every probe in (ruling, deadline] refuses. Forward-only warps; the
        //    first probe is the ruling instant itself, so nothing warps back.
        uint256[4] memory probes =
            [executedAt + 24 days, executedAt + 30 days, executedAt + 37 days, executedAt + 38 days];
        for (uint256 i = 0; i < probes.length; i++) {
            vm.warp(probes[i]);
            vm.expectRevert(ISyndicateGovernor.ChallengeWindowOpen.selector);
            gov.reclaimProposerBond(pid);
            assertEq(wood.balanceOf(address(bondEscrow)), PROPOSER_BOND, "the escrow held on throughout");
        }

        // ── And it opens the instant the deadline lapses, not before.
        uint256 agentBalBefore = wood.balanceOf(agent);
        vm.warp(rearmed + 1);
        gov.reclaimProposerBond(pid);
        assertEq(wood.balanceOf(agent), agentBalBefore + PROPOSER_BOND, "returned whole, and to the proposer");
        assertEq(wood.balanceOf(address(bondEscrow)), 0, "escrow drained");
    }

    /// @notice THE OTHER HALF OF #94, and the reason the hold is worth having:
    ///         a challenge filed INSIDE the re-armed window still convicts, and
    ///         because the bond never left, the conviction can actually take
    ///         it. `ProposerBondForfeited`, not `ProposerBondForfeitureFailed`
    ///         — the failure event is what a reclaim on day 24 used to produce,
    ///         and with it a silently zeroed prosecutor fee.
    function test_issue94_convictionInsideTheRearmedWindow_stillTakesTheBond() public {
        (uint256 pid,) = _driveToInconclusiveRearm();
        uint256 executedAt = gov.getProposal(pid).executedAt;
        uint256 challengerBalBefore = wood.balanceOf(challenger);
        uint256 burnBalBefore = wood.balanceOf(game.BURN_ADDRESS());

        // Day 30: six days into the re-armed window, eight days before it lapses.
        vm.warp(executedAt + 30 days);
        vm.prank(challenger);
        uint256 cid2 = game.file(
            address(gov),
            pid,
            IChallengeGame.Predicate.OutOfAdapterOutflow,
            address(adapter),
            adapter.poke.selector,
            "ipfs://evidence/honest-refiling"
        );
        assertTrue(ledger.isCoverageFrozen(address(gov), pid), "the re-filing pinned the coverage again");

        // Silence convicts. Hoisted before the `expectEmit` — a call in
        // argument position consumes a pending one-shot cheatcode.
        uint256 filedAt2 = game.challengeOf(cid2).filedAt;
        uint256 dueAt = filedAt2 + game.autoSlashDelay();
        vm.warp(dueAt);
        vm.expectEmit(true, true, true, true, address(game));
        emit IChallengeGame.ProposerBondForfeited(cid2, address(gov), pid, agent, PROPOSER_BOND);
        game.resolve(cid2);
        assertEq(uint256(game.challengeOf(cid2).status), uint256(IChallengeGame.Status.Settled), "convicted");

        // ── The bond really moved: fee to the prosecutor, remainder burned.
        uint256 prosecutorFee = (PROPOSER_BOND * game.prosecutorFeeBps()) / 10_000;
        uint256 settleBurn = (_challengerBond() * game.settleBurnBps()) / 10_000;
        assertGt(prosecutorFee, 0, "the fee is live in this fixture");
        assertEq(wood.balanceOf(address(bondEscrow)), 0, "the escrow gave the bond up");
        (address bondProposer, uint256 bondAmount) = bondEscrow.bondOf(address(gov), pid);
        assertEq(bondProposer, address(0), "and cleared the record");
        assertEq(bondAmount, 0);
        assertEq(
            wood.balanceOf(challenger),
            challengerBalBefore - settleBurn + prosecutorFee,
            "the prosecutor was paid out of the bond it was nearly denied"
        );
        assertEq(
            wood.balanceOf(game.BURN_ADDRESS()),
            burnBalBefore + (PROPOSER_BOND - prosecutorFee) + settleBurn + G1_STAKE,
            "bond net of the fee, plus the settle burn, plus the whole slashed guardian bond"
        );

        // ── And no later reclaim can resurrect it — but (issue #117 L1) the
        //    governor's own gates all pass eventually, and reclaim now
        //    acknowledges the forfeiture instead of dying in the escrow's
        //    `NoBond`.
        vm.warp(executedAt + 365 days);
        uint256 burnBalBeforeReclaim = wood.balanceOf(game.BURN_ADDRESS());
        vm.expectEmit(true, true, true, true, address(gov));
        emit ISyndicateGovernor.ProposerBondForfeitureAcknowledged(pid, PROPOSER_BOND);
        gov.reclaimProposerBond(pid);
        assertEq(gov.getProposal(pid).proposerBondWood, 0, "the stale bond record is cleared");
        assertEq(wood.balanceOf(game.BURN_ADDRESS()), burnBalBeforeReclaim, "acknowledge moves no further WOOD");

        vm.expectRevert(ISyndicateGovernor.NoBondToReclaim.selector);
        gov.reclaimProposerBond(pid);
    }

    /// @notice THE ONE-SECOND OVERLAP, proved from both sides. `file` admits
    ///         while `block.timestamp <= deadline`, so a `>=` reclaim gate — the
    ///         obvious reading, and the one issue #94 suggested — would leave
    ///         exactly one timestamp at which a filing and a reclaim both
    ///         succeed. At the deadline itself the game still takes a filing,
    ///         so reclaim must still refuse.
    function test_issue94_atTheDeadline_filingIsStillAdmissible() public {
        (uint256 pid,) = _driveToInconclusiveRearm();
        uint256 deadline = game.challengeableUntil(_reviewKey(pid));

        vm.warp(deadline);
        vm.expectRevert(ISyndicateGovernor.ChallengeWindowOpen.selector);
        gov.reclaimProposerBond(pid);

        // The same instant, from the game's side.
        vm.prank(challenger);
        uint256 cid2 = game.file(
            address(gov),
            pid,
            IChallengeGame.Predicate.OutOfAdapterOutflow,
            address(adapter),
            adapter.poke.selector,
            "ipfs://evidence/last-legal-instant"
        );
        assertEq(game.liveChallengeOf(address(gov), pid), cid2, "the game took it at exactly the deadline");
    }

    /// @notice The companion fixture at deadline + 1s. Separate contract state
    ///         rather than a backward warp, which forge 1.7.1 ignores.
    function test_issue94_oneSecondPast_filingClosesAndReclaimOpens() public {
        (uint256 pid,) = _driveToInconclusiveRearm();
        uint256 deadline = game.challengeableUntil(_reviewKey(pid));
        uint256 agentBalBefore = wood.balanceOf(agent);

        vm.warp(deadline + 1);
        vm.prank(challenger);
        vm.expectRevert(IChallengeGame.WindowClosed.selector);
        game.file(
            address(gov),
            pid,
            IChallengeGame.Predicate.OutOfAdapterOutflow,
            address(adapter),
            adapter.poke.selector,
            "ipfs://evidence/too-late"
        );

        gov.reclaimProposerBond(pid);
        assertEq(wood.balanceOf(agent), agentBalBefore + PROPOSER_BOND, "and the bond goes home the moment it can");
    }

    // ── 4. Declared coverage locks: the burn is the lock, and only the lock ──

    /// @notice Task 6.4, end to end and with nothing mocked: propose -> approve
    ///         with a PARTIAL lock -> execute at quorum -> challenge ->
    ///         conviction burns EXACTLY the lock under the envelope -> an
    ///         unrelated proposal the same guardian also backs is unaffected,
    ///         and a stake top-up landed after the drain neither shields the
    ///         lock nor is burned (spec: "Post-drain top-up does not dilute
    ///         the burn").
    ///
    ///         g1 holds 30,000 WOOD and declares 15,000 on P (5,000 bps of the
    ///         at-execution basis, inside the [1,000, 10,000] envelope so the
    ///         clamp is inert). It then backs Q with the other 15,000 — at
    ///         k = 1 that is exactly its remaining budget — and tops up a
    ///         further 30,000 after P executed. The verdict on P burns 15,000:
    ///         `slashBpsFor` prices the lock over `slashableStakeAt(g1,
    ///         executedAt)` = 30,000, so the top-up is outside the basis, and
    ///         `_slashOne` multiplies that same basis. 45,000 remains — Q's
    ///         lock, and then some.
    function test_partialLock_convictionBurnsExactlyTheLockAndSparesTheOtherProposal() public {
        // ── P: proposed, approved with a HALF-stake lock, executed.
        uint256 pid = _propose();
        vm.warp(gov.getProposal(pid).voteEnd + 1);
        registry.openReview(address(gov), pid);
        vm.prank(g1);
        registry.voteOnProposal(address(gov), pid, IGuardianRegistry.GuardianVoteType.Approve, G1_STAKE / 2);
        assertEq(ledger.lockOf(address(gov), pid, g1), 15_000e18, "half the stake locked on P");
        assertEq(ledger.coverageUsdOf(address(gov), pid, g1), 750e18, "$750 of coverage against the $500 need");
        vm.warp(gov.getProposal(pid).reviewEnd + 1);
        gov.executeProposal(pid);
        assertEq(_state(pid), uint256(ISyndicateGovernor.ProposalState.Executed), "executed at quorum on the lock");
        uint256 executedAt = gov.getProposal(pid).executedAt;
        (, uint256[] memory rateAtExecute) = ledger.slashBpsFor(address(gov), pid);
        assertEq(rateAtExecute[0], 5_000, "15,000 over the 30,000 basis");

        // ── The challenge. The bond is sized off the capped liability: the lock
        //    is worth $750 but the need is $500.
        vm.prank(challenger);
        uint256 cid = game.file(
            address(gov),
            pid,
            IChallengeGame.Predicate.OutOfAdapterOutflow,
            address(adapter),
            adapter.poke.selector,
            "ipfs://evidence/partial-lock"
        );
        IChallengeGame.Challenge memory c = game.challengeOf(cid);
        assertEq(c.frozenCoverageUsd, COVERAGE_USD, "liability capped at the need, not the $750 lock");
        assertEq(c.bondWood, _challengerBond(), "so the challenger bond is the standard one");

        // ── P settles, which lets the vault take Q.
        vm.warp(executedAt + 1 hours + 1);
        vm.prank(agent);
        gov.settleProposal(pid);

        // ── Q: the unrelated proposal g1 also backs, with the OTHER half.
        uint256 qid = _propose();
        vm.warp(gov.getProposal(qid).voteEnd + 1);
        registry.openReview(address(gov), qid);
        vm.prank(g1);
        registry.voteOnProposal(address(gov), qid, IGuardianRegistry.GuardianVoteType.Approve, G1_STAKE / 2);
        assertEq(ledger.lockOf(address(gov), qid, g1), 15_000e18, "the other half locked on Q");
        assertEq(ledger.openExposure(g1), G1_STAKE, "k = 1: the two locks exactly exhaust the stake");
        assertEq(ledger.coverageUsdOf(address(gov), qid, g1), 750e18, "Q's coverage from g1, before");

        // ── The post-drain top-up: 30,000 more WOOD, staked AFTER P executed.
        _stakeGuardian(g1, 30_000e18, 1);
        assertEq(swood.guardianStake(g1), 60_000e18, "live stake doubled");
        assertEq(swood.slashableStakeAt(g1, executedAt), 30_000e18, "the verdict basis excludes the top-up");
        (, uint256[] memory rateAfterTopUp) = ledger.slashBpsFor(address(gov), pid);
        assertEq(rateAfterTopUp[0], 5_000, "the rate is over the anchored basis, so the top-up does not dilute it");

        // ── Silence; the verdict lands.
        vm.warp(c.filedAt + game.autoSlashDelay());
        uint256 swoodBalBefore = wood.balanceOf(address(swood));
        game.resolve(cid);
        assertEq(uint256(game.challengeOf(cid).status), uint256(IChallengeGame.Status.Settled), "Settled");

        // THE BURN IS THE LOCK: 5,000 bps of the 30,000 basis == 15,000 WOOD,
        // no more (the top-up is untouched) and no less (the envelope did not
        // bind).
        assertEq(swoodBalBefore - wood.balanceOf(address(swood)), 15_000e18, "burned exactly the lock");
        assertEq(swood.guardianStake(g1), 45_000e18, "the top-up and the other half are still staked");

        // Q IS UNAFFECTED: same lock, same coverage, still fully collectable.
        assertEq(ledger.lockOf(address(gov), qid, g1), 15_000e18, "Q's lock is intact");
        assertEq(ledger.coverageUsdOf(address(gov), qid, g1), 750e18, "Q's coverage from g1 is unchanged");
        assertEq(ledger.liabilityUsd(address(gov), qid), COVERAGE_USD, "Q remains fully covered");
        assertFalse(ledger.isCoverageFrozen(address(gov), qid), "and was never frozen by P's challenge");
    }

    /// @dev SHE-215: `SyndicateGovernor.propose` / `executeProposal` now refuse
    ///      a vault whose owner-stake slot is unbound, claimed, slashed, or
    ///      exiting. `SyndicateFactory.createSyndicate` ALWAYS binds that slot,
    ///      so a hand-built syndicate that skips it models a vault the real
    ///      factory cannot produce. Binding here restores the fixture to a
    ///      state the protocol can actually reach.
    function _bondVaultOwner(address vault_) internal {
        uint256 bond = swood.minOwnerStake();
        wood.mint(owner, bond);
        vm.startPrank(owner);
        wood.approve(address(swood), bond);
        swood.prepareOwnerStake(bond);
        vm.stopPrank();
        // The test contract is sWOOD's factory.
        swood.bindOwnerStake(owner, vault_);
    }

    // ── SHE-213: every filing re-buckets the approvers' locks ──

    /// @dev propose(`duration`) -> review -> g1 approves -> execute, without
    ///      the 7-day-arc assertions `_proposeApproveExecute` makes.
    function _proposeApproveExecuteWithDuration(uint256 duration) internal returns (uint256 pid) {
        ISyndicateGovernor.RiskEnvelope memory env =
            ISyndicateGovernor.RiskEnvelope({maxCapital: MAX_CAPITAL, maxDrawdownBps: 10_000});
        vm.prank(agent);
        pid = gov.propose(
            address(vault),
            address(0),
            "ipfs://she-213",
            duration,
            env,
            _execCalls(),
            GovEnvelope.defaultCaps(MAX_CAPITAL, _execCalls().length),
            _settleCalls(),
            GovEnvelope.defaultCaps(MAX_CAPITAL, _settleCalls().length),
            new ISyndicateGovernor.CoProposer[](0)
        );
        vm.warp(gov.getProposal(pid).voteEnd + 1);
        registry.openReview(address(gov), pid);
        vm.prank(g1);
        registry.voteOnProposal(address(gov), pid, IGuardianRegistry.GuardianVoteType.Approve, type(uint256).max);
        vm.warp(gov.getProposal(pid).reviewEnd + 1);
        gov.executeProposal(pid);
    }

    function _epochOf(uint256 t) internal view returns (uint256) {
        return (t - ledger.epochGenesis()) / EPOCH_LENGTH;
    }

    /// @dev The instant bucket `epoch` stops counting in `openExposure`.
    function _bucketExpiry(uint256 epoch) internal view returns (uint256) {
        return ledger.epochGenesis() + (epoch + 1) * EPOCH_LENGTH + ledger.challengeWindow();
    }

    function _file(address who, uint256 pid, string memory uri) internal returns (uint256 cid) {
        vm.prank(who);
        cid = game.file(
            address(gov),
            pid,
            IChallengeGame.Predicate.OutOfAdapterOutflow,
            address(adapter),
            adapter.poke.selector,
            uri
        );
    }

    /// @notice THE SECOND FILING REACHES THE LEDGER. A executes on day ~1 with
    ///         a 30-day strategy (filing deadline day ~45). Challenge 1 is filed
    ///         at execution: its worst-case end falls in bucket 1, which stops
    ///         counting on day 70. Challenge 2 is filed at the inclusive
    ///         deadline; its dispute clock runs to day ~76. On day 71 g1 is
    ///         frozen and slashable through challenge 2 — and, because the game
    ///         freezes the ledger on EVERY filing and the ledger re-buckets
    ///         raise-only on every call, still COUNTED. Under first-filing-only
    ///         freezing `openExposure` read zero here and g1 could re-lock.
    function test_secondFiling_keepsTheLockCountedPastTheFirstFreezesBucket() public {
        uint256 pid = _proposeApproveExecuteWithDuration(30 days);
        uint256 executedAt = gov.getProposal(pid).executedAt;
        assertEq(ledger.openExposure(g1), G1_STAKE, "locked");

        // Challenge 1 at execution.
        _file(challenger, pid, "ipfs://c1");
        uint256 firstEpoch = _epochOf(vm.getBlockTimestamp() + game.disputeTimeout());

        // Challenge 2, from a second challenger, at the inclusive filing deadline.
        vm.warp(executedAt + 30 days + game.challengeWindow());
        address challenger2 = makeAddr("challenger2");
        wood.mint(challenger2, _challengerBond() * 2);
        vm.prank(challenger2);
        wood.approve(address(game), type(uint256).max);
        uint256 cid2 = _file(challenger2, pid, "ipfs://c2");
        uint256 secondLiveUntil = vm.getBlockTimestamp() + game.disputeTimeout();
        // Non-vacuity: the second clock must outlive the first target's bucket.
        assertGt(secondLiveUntil, _bucketExpiry(firstEpoch), "fixture: second clock outlives the first bucket");

        // The instant after the first target's bucket has aged out.
        vm.warp(_bucketExpiry(firstEpoch) + 1);
        assertEq(
            uint256(game.challengeOf(cid2).status), uint256(IChallengeGame.Status.Filed), "challenge 2 is still live"
        );
        assertTrue(ledger.isCoverageFrozen(address(gov), pid), "still frozen");
        assertTrue(ledger.hasFrozenCoverage(g1), "g1 still exit-blocked");
        assertEq(ledger.openExposure(g1), G1_STAKE, "frozen and slashable means COUNTED");
    }

    /// @notice The horizon clamp in `ExposureLedger._horizonClampedEpochOf`
    ///         "only bites on a value the game itself would refuse" iff the
    ///         game's dispute-timeout ceiling fits inside the ledger's coverage
    ///         horizon. Pinned here so a later raise of `MAX_DISPUTE_TIMEOUT`
    ///         cannot silently turn the clamp into an early expiry.
    function test_constants_disputeTimeoutCeilingFitsTheCoverageHorizon() public view {
        assertLe(game.MAX_DISPUTE_TIMEOUT(), ledger.MAX_COVERAGE_HORIZON(), "MAX_DISPUTE_TIMEOUT must fit the horizon");
    }

    // ── SHE-246: a challenge is unrulable past its dispute deadline ──

    /// @notice THE LEDGER'S `liveUntil` IS THE END OF SLASHABILITY. Reviewer
    ///         sequence on #299: freeze on day 20, `liveUntil` day 50, nobody
    ///         resolves, day 70. The lock has aged out of `openExposure` (the
    ///         bucket containing `liveUntil` expired), the key is still frozen,
    ///         and the ONLY thing `resolve` may now do is unwind - never slash.
    function test_staleUnbackedFiling_cannotSettlePastTheDisputeDeadline() public {
        uint256 pid = _proposeApproveExecuteWithDuration(30 days);
        uint256 executedAt = gov.getProposal(pid).executedAt;

        vm.warp(executedAt + 20 days);
        uint256 cid = _file(challenger, pid, "ipfs://stale");
        uint256 liveUntil = vm.getBlockTimestamp() + game.disputeTimeout();
        uint256 stakeBefore = swood.guardianStake(g1);
        uint256 challengerBefore = wood.balanceOf(challenger);
        uint256 bond = game.challengeOf(cid).bondWood;

        // Past the deadline AND past the bucket's wall-clock expiry.
        uint256 expiry = _bucketExpiry(_epochOf(liveUntil));
        vm.warp((expiry > liveUntil ? expiry : liveUntil) + 1);
        assertTrue(ledger.isCoverageFrozen(address(gov), pid), "fixture: still frozen, nobody resolved");
        assertTrue(ledger.hasFrozenCoverage(g1), "fixture: exit still blocked");
        assertEq(ledger.openExposure(g1), 0, "the lock aged out at liveUntil - correct iff nothing can slash it");

        game.resolve(cid);
        assertEq(
            uint256(game.challengeOf(cid).status), uint256(IChallengeGame.Status.Inconclusive), "a stale filing unwinds"
        );
        assertEq(swood.guardianStake(g1), stakeBefore, "nothing slashed past the deadline");
        assertFalse(ledger.isCoverageFrozen(address(gov), pid), "unfrozen");
        // A non-verdict re-arms the re-challenge window and pins the ledger
        // through it: exit stays blocked and the lock is COUNTED again for
        // exactly as long as a fresh filing is legal, then both clear.
        uint256 rearmedUntil = game.challengeableUntil(_reviewKey(pid));
        assertEq(rearmedUntil, vm.getBlockTimestamp() + game.challengeWindow(), "re-armed one window from now");
        assertTrue(ledger.hasFrozenCoverage(g1), "pinned through the re-armed window");
        assertEq(ledger.openExposure(g1), G1_STAKE, "re-counted while re-challengeable");
        vm.warp(rearmedUntil + 1);
        assertFalse(ledger.hasFrozenCoverage(g1), "exit unblocked once the window shuts");
        uint256 burned = (bond * game.challengeOf(cid).inconclusiveBurnBpsAtFiling) / 10_000;
        assertGt(burned, 0, "fixture: the free-freeze price is non-zero");
        assertEq(wood.balanceOf(challenger), challengerBefore + bond - burned, "bond back net of the round burn");

        // Capacity is not over-committed: once the pinned bucket has aged out
        // too, a fresh approval by the same guardian lands at full size.
        vm.warp(_bucketExpiry(_epochOf(rearmedUntil)) + 1);
        assertEq(ledger.openExposure(g1), 0, "nothing left counted");
        vm.prank(agent);
        gov.settleProposal(pid);
        gov.resolveProposalState(pid);
        uint256 pid2 = _proposeApproveExecuteWithDuration(30 days);
        assertEq(ledger.lockOf(address(gov), pid2, g1), G1_STAKE, "a fresh lock lands at full size");
        assertEq(ledger.openExposure(g1), G1_STAKE, "and is the only thing counted");
    }

    /// @notice THE DEADLINE READS THE PINNED TIMEOUT, NOT THE LIVE ONE. An
    ///         owner raising `disputeTimeout` after a filing must not extend
    ///         that filing's slashability past the `liveUntil` it booked on the
    ///         ledger - that would be SHE-246 reopened by a setter. The filing
    ///         is placed so `liveUntil` is the LAST second of its bucket: the
    ///         bucket then ages out `challengeWindow` after the deadline, well
    ///         inside the raised clock, so the ledger boundary and the stale
    ///         `resolve` are checked in one run under both clocks.
    function test_deadlineReadsThePinnedTimeout_unbackedResolveUnwindsAndTheLedgerIsUnmoved() public {
        uint256 pid = _proposeApproveExecuteWithDuration(30 days);
        uint256 executedAt = gov.getProposal(pid).executedAt;
        uint256 oldTimeout = game.disputeTimeout();
        uint256 e = _epochOf(executedAt + 1 + oldTimeout);
        uint256 fileAt = ledger.epochGenesis() + (e + 1) * EPOCH_LENGTH - 1 - oldTimeout;
        assertGe(fileAt, executedAt + 1, "fixture: filed after execution");
        vm.warp(fileAt);
        uint256 cid = _file(challenger, pid, "ipfs://pinned");
        assertEq(game.challengeOf(cid).disputeTimeoutAtFiling, oldTimeout, "fixture: pinned the old clock");

        // Hoisted: a call in argument position would consume the prank.
        uint256 maxTimeout = game.MAX_DISPUTE_TIMEOUT();
        vm.prank(owner);
        game.setDisputeTimeout(maxTimeout);
        uint256 liveDeadline = fileAt + game.disputeTimeout();
        uint256 boundary = _bucketExpiry(e) + 1;
        assertGt(liveDeadline, boundary, "fixture: the live clock outlives the booked bucket");

        vm.warp(boundary);
        assertTrue(ledger.isCoverageFrozen(address(gov), pid), "still frozen, nobody resolved");
        assertEq(ledger.openExposure(g1), 0, "the raise moved nothing: the lock aged out at the booked liveUntil");

        game.resolve(cid);
        assertEq(
            uint256(game.challengeOf(cid).status),
            uint256(IChallengeGame.Status.Inconclusive),
            "stale on the PINNED clock"
        );
        assertEq(swood.guardianStake(g1), G1_STAKE, "the live clock convicts nothing");
    }

    function test_deadlineReadsThePinnedTimeout_ruleRevertsAtTheOldDeadlineAfterARaise() public {
        (uint256 cid, address stubCourt) = _fileAndDisputeWithStubCourt();
        IChallengeGame.Challenge memory c = game.challengeOf(cid);
        uint256 oldDeadline = c.filedAt + c.disputeTimeoutAtFiling;

        // Hoisted: a call in argument position would consume the prank.
        uint256 maxTimeout = game.MAX_DISPUTE_TIMEOUT();
        vm.prank(owner);
        game.setDisputeTimeout(maxTimeout);
        assertGt(c.filedAt + game.disputeTimeout(), oldDeadline, "fixture: raised");

        vm.warp(oldDeadline);
        vm.prank(stubCourt);
        vm.expectRevert(IChallengeGame.WindowClosed.selector);
        game.rule(cid, IChallengeGame.Verdict.Guilty);

        game.resolve(cid);
        assertEq(
            uint256(game.challengeOf(cid).status),
            uint256(IChallengeGame.Status.Failed),
            "timed out on the pinned clock"
        );
        assertEq(swood.guardianStake(g1), G1_STAKE, "never slashed");
    }

    /// @notice `rule` is open one second before the deadline and shut from the
    ///         deadline on - the same instant `resolve`'s non-slashing branch
    ///         opens, so no instant is both rulable and unwindable.
    function test_rule_convictsAtDeadlineMinusOne() public {
        (uint256 cid, address stubCourt) = _fileAndDisputeWithStubCourt();
        IChallengeGame.Challenge memory c = game.challengeOf(cid);
        vm.warp(c.filedAt + c.disputeTimeoutAtFiling - 1);
        vm.prank(stubCourt);
        game.rule(cid, IChallengeGame.Verdict.Guilty);
        assertEq(uint256(game.challengeOf(cid).status), uint256(IChallengeGame.Status.Settled), "ruled in time");
        assertEq(swood.guardianStake(g1), 0, "slashed");
    }

    function test_rule_revertsFromTheDeadlineOn_andResolveUnwinds() public {
        (uint256 cid, address stubCourt) = _fileAndDisputeWithStubCourt();
        IChallengeGame.Challenge memory c = game.challengeOf(cid);
        uint256 stakeBefore = swood.guardianStake(g1);

        vm.warp(c.filedAt + c.disputeTimeoutAtFiling);
        vm.prank(stubCourt);
        vm.expectRevert(IChallengeGame.WindowClosed.selector);
        game.rule(cid, IChallengeGame.Verdict.Guilty);

        vm.warp(c.filedAt + c.disputeTimeoutAtFiling + 1);
        vm.prank(stubCourt);
        vm.expectRevert(IChallengeGame.WindowClosed.selector);
        game.rule(cid, IChallengeGame.Verdict.Guilty);

        // The clock's own exit: a court WAS pinned, so the timeout is `_fail`.
        game.resolve(cid);
        assertEq(uint256(game.challengeOf(cid).status), uint256(IChallengeGame.Status.Failed), "timed out");
        assertEq(swood.guardianStake(g1), stakeBefore, "never slashed");
        assertFalse(ledger.isCoverageFrozen(address(gov), pid_), "unfrozen");
    }

    /// @notice CONCURRENT FILINGS: the deadline is per filing, and the key is
    ///         slashable until the LATEST live filing's deadline. The earlier
    ///         filing going stale neither unfreezes the key nor shortens the
    ///         later one's window, and the ledger keeps counting the lock until
    ///         that later `liveUntil` - which is what #299's raise-only freeze
    ///         booked.
    function test_twoFilings_keyStaysSlashableUntilTheLaterDeadline() public {
        uint256 pid = _proposeApproveExecuteWithDuration(30 days);
        uint256 executedAt = gov.getProposal(pid).executedAt;

        vm.warp(executedAt + 1);
        uint256 cid1 = _file(challenger, pid, "ipfs://c1");
        uint256 deadline1 = vm.getBlockTimestamp() + game.disputeTimeout();

        vm.warp(executedAt + 20 days);
        address challenger2 = makeAddr("challenger2");
        wood.mint(challenger2, _challengerBond() * 2);
        vm.prank(challenger2);
        wood.approve(address(game), type(uint256).max);
        uint256 cid2 = _file(challenger2, pid, "ipfs://c2");
        uint256 deadline2 = vm.getBlockTimestamp() + game.disputeTimeout();

        // Between the two deadlines: 1 is stale, 2 is live.
        vm.warp(deadline1 + 5 days);
        assertLt(vm.getBlockTimestamp(), deadline2, "fixture: inside the second window");
        game.resolve(cid1);
        assertEq(uint256(game.challengeOf(cid1).status), uint256(IChallengeGame.Status.Inconclusive), "1 unwound");
        assertEq(swood.guardianStake(g1), G1_STAKE, "the stale filing slashed nothing");
        assertTrue(ledger.isCoverageFrozen(address(gov), pid), "still frozen by 2");
        assertEq(ledger.openExposure(g1), G1_STAKE, "still counted until the later liveUntil");

        game.resolve(cid2);
        assertEq(uint256(game.challengeOf(cid2).status), uint256(IChallengeGame.Status.Settled), "2 convicts");
        assertEq(swood.guardianStake(g1), 0, "slashed through the later filing");
    }

    function test_twoFilings_nothingSlashesPastTheLaterDeadline() public {
        uint256 pid = _proposeApproveExecuteWithDuration(30 days);
        uint256 executedAt = gov.getProposal(pid).executedAt;

        vm.warp(executedAt + 1);
        uint256 cid1 = _file(challenger, pid, "ipfs://c1");
        vm.warp(executedAt + 20 days);
        address challenger2 = makeAddr("challenger2");
        wood.mint(challenger2, _challengerBond() * 2);
        vm.prank(challenger2);
        wood.approve(address(game), type(uint256).max);
        uint256 cid2 = _file(challenger2, pid, "ipfs://c2");
        uint256 deadline2 = vm.getBlockTimestamp() + game.disputeTimeout();

        vm.warp(deadline2);
        game.resolve(cid2);
        game.resolve(cid1);
        assertEq(uint256(game.challengeOf(cid1).status), uint256(IChallengeGame.Status.Inconclusive));
        assertEq(uint256(game.challengeOf(cid2).status), uint256(IChallengeGame.Status.Inconclusive));
        assertEq(swood.guardianStake(g1), G1_STAKE, "no path slashes past the last deadline");
        assertFalse(ledger.isCoverageFrozen(address(gov), pid), "fully released");
    }

    uint256 internal pid_;

    /// @dev A court is wired BEFORE filing so `courtAtFiling` pins non-zero and
    ///      `rule` is reachable; g1 completes the pool inside `autoSlashDelay`.
    function _fileAndDisputeWithStubCourt() internal returns (uint256 cid, address stubCourt) {
        pid_ = _proposeApproveExecute();
        uint256 executedAt = gov.getProposal(pid_).executedAt;
        stubCourt = address(new StubInconclusiveCourt());
        vm.prank(owner);
        game.setCourt(stubCourt);
        vm.warp(executedAt + 1);
        cid = _file(challenger, pid_, "ipfs://disputed");
        vm.warp(executedAt + 2 days);
        vm.prank(g1);
        game.dispute(cid, type(uint256).max);
        assertEq(uint256(game.challengeOf(cid).status), uint256(IChallengeGame.Status.Disputed), "fixture: backed");
    }
}
