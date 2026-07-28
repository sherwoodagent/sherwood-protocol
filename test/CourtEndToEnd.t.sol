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
import {TierRegistry} from "../src/TierRegistry.sol";
import {ChallengeGame} from "../src/ChallengeGame.sol";
import {IChallengeGame} from "../src/interfaces/IChallengeGame.sol";
import {Court} from "../src/Court.sol";
import {ICourt} from "../src/interfaces/ICourt.sol";
import {CompensationEscrow} from "../src/CompensationEscrow.sol";
import {ICompensationEscrow} from "../src/interfaces/ICompensationEscrow.sol";
import {ProposerBondEscrow} from "../src/ProposerBondEscrow.sol";
import {BatchExecutorLib} from "../src/BatchExecutorLib.sol";
import {ProtocolConfig} from "../src/ProtocolConfig.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "./mocks/MockAgentRegistry.sol";

/// @dev Chainlink-shaped USD feed for the vault asset.
contract CourtE2EFeed {
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

/// @dev Two entrypoints, neither a value-moving ERC20 selector, so the vault's
///      `_guardBatchCalls` lets both through and the TierRegistry can certify
///      ONE of them — the asymmetry that makes the challenged proposal tier 2
///      (coverage-gated) while still containing a certified adapter call a
///      passed challenge can demote.
contract CourtE2EAdapter {
    uint256 public pokes;
    uint256 public bumps;

    function poke() external {
        pokes++;
    }

    function bump() external {
        bumps++;
    }
}

/// @title CourtEndToEndTest
/// @notice Plan E Task 6 — the two-layer court of spec §3.5 against the REAL
///         stack, extending `ChallengeEndToEnd`'s fixture (real UUPS sWOOD, real
///         `GuardianRegistry` review, real `SyndicateVault` + `SyndicateGovernor`
///         proposal, real `ExposureLedger` coverage, real `TierRegistry` grant,
///         real `CompensationEscrow` and `ProposerBondEscrow`, real
///         `ChallengeGame`) with a real `Court` wired both ways —
///         `game.setCourt(court)` and `court.setChallengeGame(game)`.
///
/// @dev    THE HOLE THESE ARCS CLOSE. Plan D left `Disputed` terminal-with-
///         timeout: a genuinely guilty approver could buy the escalation and run
///         out `disputeTimeout`, and the challenge would fail IN ITS FAVOUR.
///         Arc 1 runs exactly that attack and proves the court's ruling gets
///         there first and terminally. Arcs 2 and 3 then prove the two ways an
///         appeal can land are not the same outcome: an overturn on a quorate
///         vote acquits and leaves the panel's own bonds untouched (D4/F6),
///         while an appeal that misses the participation floor is a NON-EVENT —
///         the panel ruling stands and the guardian is still slashed (D6).
///
/// @dev    Fixture arithmetic, all exact:
///           - USDG 6-dec at $1.00; the vault's `_decimalsOffset()` is the
///             asset's decimals, so LP1 70,000 USDG → 70,000e12 shares, LP2
///             30,000 → 30,000e12, post-drain buyer 20,000 → 20,000e12.
///           - Exec batch [poke (certified, 5,000 bps), bump (uncertified,
///             10,000 bps)] ⇒ tier 2; settle batch [poke] ⇒ 5,000 bps. Coverage
///             = 1,000 USDG × 20,000/10,000 = 2,000 USDG = $2,000.
///           - That is MORE than g1's budget, so the proposal has TWO covering
///             approvers: g1 books $1,500 and g2 the remaining $500. Both are
///             accused; only g1 pays for the defence, which is what makes arc
///             2's pro-rata-to-CONTRIBUTION forfeit observable.
///           - challengerBondBps 500 ⇒ $100 ⇒ 2,000 WOOD at the $0.05 haircut.
///           - A `maxSlashBps` verdict takes both approvers' whole stake:
///             30,000 + 20,000 = 50,000 WOOD, split 70/30 into 35,000 / 15,000.
///
/// @dev    Court arithmetic, chosen so ONE configuration serves all three arcs
///         and the participation floor is what separates arc 2 from arc 3:
///           - Electorate = the four staked guardians, matured to par:
///             g1 30,000 + g2 20,000 + g3 20,000 + g4 30,000 = 100,000 WOOD of
///             `getPastTotalVotes` at the snapshot.
///           - THE ACCUSED MAY NOT VOTE (§3.5). g1 + g2 are the covering
///             approvers, so 50,000 of that 100,000 is barred from both of the
///             court's votes, and the participation floor is measured on the
///             50,000 that REMAINS — otherwise honest turnout would be asked to
///             outvote stake the contract itself refuses to accept, more
///             appeals would fall below the floor, and below the floor the
///             panel's ruling stands.
///           - `participationFloorBps` 6,000 of that reduced base ⇒ floor
///             30,000 WOOD — the same bar in WOOD as before the exclusion, so
///             the two arcs below still differ by TURNOUT ALONE.
///           - Arc 2 turnout g3+g4 = 50,000 CLEARS it and decides — and both are
///             DISINTERESTED, so the acquittal is not the accused voting for
///             itself. It could not be: they would revert.
///           - Arc 3 turnout g3 alone = 20,000 MISSES it and decides nothing.
///           - Windows: panel 7d, appeal 3d, appeal vote 5d — 15d total against
///             the challenge's own 30d `disputeTimeout`, so every arc finishes
///             with the timeout still pending. That ordering is the point.
contract CourtEndToEndTest is Test {
    // ── Real stack ──
    ERC20Mock public usdg; // vault asset, 6-dec, $1.00
    ERC20Mock public wood; // stake + bond token, 18-dec
    BatchExecutorLib public executorLib;
    MockAgentRegistry public agentRegistry;
    ProtocolConfig public protocolConfig;
    CourtE2EFeed public feed;
    CourtE2EAdapter public adapter;

    StakedWood public swood;
    GuardianRegistry public registry;
    ExposureLedger public ledger;
    TierRegistry public tierRegistry;
    ProposerBondEscrow public bondEscrow;
    CompensationEscrow public escrow;
    ChallengeGame public game;
    Court public court;

    SyndicateVault public vault;
    SyndicateGovernor public gov;

    address public owner = makeAddr("owner");
    address public ledgerOwner = makeAddr("ledgerOwner");
    address public backstop = makeAddr("backstop");
    address public agent = makeAddr("agent");
    address public challenger = makeAddr("challenger");

    address public g1 = makeAddr("guardian1"); // covering approver, funds the defence
    address public g2 = makeAddr("guardian2"); // covering approver, free-rides the defence
    // The DISINTERESTED electorate: neither approves the challenged proposal, so
    // neither is accused, and layer 2's verdict in arc 2 is theirs alone. Without
    // them an overturn would have to be carried by the accused's own stake, and
    // "the appeal acquitted" would be indistinguishable from "the accused voted".
    address public g3 = makeAddr("guardian3");
    address public g4 = makeAddr("guardian4");

    // The panel. Deliberately NOT stakers: a panelist with voting weight would
    // blur layer 1 (a head count of seats) into layer 2 (a stake-weighted vote).
    address public p1 = makeAddr("panelist1");
    address public p2 = makeAddr("panelist2");
    address public p3 = makeAddr("panelist3");
    address public appellant = makeAddr("appellant");

    address public lp1 = makeAddr("lp1"); // pre-drain holder, 70%
    address public lp2 = makeAddr("lp2"); // pre-drain holder, 30%
    address public buyer = makeAddr("postDrainBuyer"); // deposits AFTER the drain

    uint256 constant VOTING_PERIOD = 1 days;
    uint256 constant EXECUTION_WINDOW = 1 days;
    uint256 constant REVIEW_PERIOD = 24 hours;
    uint256 constant BLOCK_QUORUM_BPS = 3000;
    uint256 constant MIN_GUARDIAN_STAKE = 10_000e18;
    uint256 constant COOL_DOWN = 45 days;
    uint256 constant EPOCH_LENGTH = 28 days;
    uint256 constant MATURATION = 30 days;

    uint256 constant G1_STAKE = 30_000e18;
    uint256 constant FILLER_STAKE = 20_000e18; // g2 and g3
    uint256 constant G4_STAKE = 30_000e18;
    uint256 constant TOTAL_VOTES = G1_STAKE + 2 * FILLER_STAKE + G4_STAKE; // 100,000 WOOD

    uint256 constant LP1_ASSETS = 70_000e6;
    uint256 constant LP2_ASSETS = 30_000e6;
    uint256 constant BUYER_ASSETS = 20_000e6;
    uint256 constant LP1_SHARES = 70_000e12;
    uint256 constant LP2_SHARES = 30_000e12;
    uint256 constant BUYER_SHARES = 20_000e12;
    uint256 constant SNAP_SUPPLY = LP1_SHARES + LP2_SHARES;

    uint256 constant MAX_CAPITAL = 1_000e6;
    uint256 constant REQUIRED_COVERAGE = 2_000e6;
    uint256 constant COVERAGE_USD = 2_000e18;
    uint256 constant PROPOSER_BOND = 400e18; // $2,000 × 1% ÷ $0.05
    /// @dev Sized off the FROZEN coverage, which is the sum of the approvers'
    ///      RESERVATIONS ($1,500 + $1,000), not the proposal's $2,000 need. Each
    ///      approver reserves up to the full need, so the two diverge as soon as
    ///      more than one guardian covers — see `G2_COVERAGE_USD`.
    uint256 constant CHALLENGER_BOND = 2_500e18; // $2,500 × 5% ÷ $0.05

    /// @dev THE COVERAGE DELIBERATELY EXCEEDS ONE GUARDIAN'S BUDGET, so the
    ///      proposal has TWO covering approvers and the defence has a free-rider
    ///      to expose. `recordApproval` sizes each share against what is still
    ///      uncovered, capped at `kNumerator × slashableBondUsd`: g1 approves
    ///      first and takes 30,000 WOOD × $0.05 = $1,500 of it, and g2 books the
    ///      remaining $500 against its own $1,000 of budget. Both are `_accused`,
    ///      so both are slashed on a conviction — and in arc 2, only ONE of them
    ///      funds the counter-bond, which is what makes the forfeit's
    ///      pro-rata-to-CONTRIBUTION rule observable rather than degenerate.
    uint256 constant G1_COVERAGE_USD = 1_500e18;
    /// @dev g2 RESERVES its whole free bond, not the $500 shortfall g1 left.
    ///      The ledger books `min(free bond, the proposal's full need)` — a
    ///      reservation is an upper bound on liability, and the pro-rata
    ///      `allocatedUsd` is what scales it down at settle. Booking the
    ///      remainder instead conflated the two, which is the bug the exposure
    ///      ledger fixed; this constant tracked the superseded model.
    uint256 constant G2_COVERAGE_USD = 1_000e18;

    /// @dev BOTH APPROVERS AT 8,000 bps, not in full. Each is slashed for the
    ///      ALLOCATION it carries, not the reservation it booked: g1 carries
    ///      $1,200 against a $1,500 bond and g2 carries $800 against a $1,000
    ///      bond, both 80%. `slashBpsFor` prices the rate that way on purpose —
    ///      slashing reservations would take the whole coverage from every
    ///      approver, which is the conflation it exists to avoid.
    uint256 constant APPROVER_SLASH_BPS = 8_000;
    uint256 constant PROCEEDS = ((G1_STAKE + FILLER_STAKE) * APPROVER_SLASH_BPS) / 10_000; // 40,000
    uint256 constant LP1_CLAIM = (PROCEEDS * 70) / 100; // 28,000 — 70% of PROCEEDS
    uint256 constant LP2_CLAIM = (PROCEEDS * 30) / 100; // 12,000 — 30% of PROCEEDS

    uint16 constant CERTIFIED_BOUND_BPS = 5_000;

    // ── Court configuration ──
    uint256 constant PANEL_BOND = 5_000e18;
    /// @dev The constructor seeds `appealBondWood` from the panel bond, and this
    ///      test never re-tunes it — so they are the same number by construction.
    uint256 constant APPEAL_BOND = PANEL_BOND;
    /// @dev 60% of the ELECTORATE THAT MAY ACTUALLY VOTE, which is
    ///      `getPastTotalVotes` less the accused's own weight — the base
    ///      `finalizeAppeal` measures against now that the accused are barred
    ///      from their own appeal (spec §3.5). g1 + g2 hold 50,000 of the
    ///      100,000 snapshot total and are the challenge's covering approvers,
    ///      so the base is 50,000 and the floor is 30,000: THE SAME NUMBER OF
    ///      WOOD AS BEFORE THE EXCLUSION, reached through the corrected
    ///      denominator. That is the point of re-tuning the bps rather than the
    ///      arcs — the bar honest turnout faces did not move, so arcs 2 and 3
    ///      still differ by turnout ALONE.
    uint256 constant FLOOR_BPS = 6_000;
    uint256 constant FLOOR_VOTES = 30_000e18; // (TOTAL_VOTES − ACCUSED_VOTES) × 6,000 / 10,000
    /// @dev g1 + g2, the two covering approvers — the set `ChallengeGame` slashes
    ///      on a conviction and, now, the set barred from both of the court's
    ///      stake-weighted votes.
    uint256 constant ACCUSED_VOTES = G1_STAKE + FILLER_STAKE; // 50,000 WOOD
    /// @dev Arc 3 only, and turned on mid-arc so the two earlier arcs resolve
    ///      against an empty pot. Sized so three of them fit inside one forfeited
    ///      appeal bond with a surplus left over for the burn to take.
    uint256 constant PANEL_REWARD = 1_000e18;

    function setUp() public {
        usdg = new ERC20Mock("USD Gov", "USDG", 6);
        wood = new ERC20Mock("Sherwood", "WOOD", 18);
        executorLib = new BatchExecutorLib();
        agentRegistry = new MockAgentRegistry();
        protocolConfig = new ProtocolConfig(owner);
        adapter = new CourtE2EAdapter();
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
                    maxDelegatedSlashBps: 2000,
                    ageFloorBps: 2500,
                    maturationPeriod: MATURATION,
                    delegatedWeightCapX: 4
                }))
        );
        swood = StakedWood(address(new ERC1967Proxy(address(swoodImpl), swoodInit)));

        GuardianRegistry regImpl = new GuardianRegistry(6 hours);
        bytes memory regInit = abi.encodeCall(
            GuardianRegistry.initialize, (owner, address(this), address(swood), REVIEW_PERIOD, BLOCK_QUORUM_BPS)
        );
        registry = GuardianRegistry(address(new ERC1967Proxy(address(regImpl), regInit)));
        vm.prank(owner);
        swood.setRegistry(address(registry));

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

        // ── Guardian cohort, matured to par so `getPastVotes` == raw stake and
        //    the appeal electorate is exactly 100,000 WOOD.
        _stakeGuardian(g1, G1_STAKE, 1);
        _stakeGuardian(g2, FILLER_STAKE, 2);
        _stakeGuardian(g3, FILLER_STAKE, 3);
        _stakeGuardian(g4, G4_STAKE, 4);
        skip(MATURATION);
        vm.warp(vm.getBlockTimestamp() + 1);

        ledger = new ExposureLedger(ledgerOwner, address(swood), EPOCH_LENGTH);
        feed = new CourtE2EFeed(1e8, 8); // $1.00, 8-dec
        vm.startPrank(ledgerOwner);
        ledger.setWoodUsdPrice(0.05e8);
        ledger.setAssetFeed(address(usdg), address(feed), 365 days);
        ledger.setCoveredTvlCapUsd(10_000_000e18);
        ledger.setGuardianRegistry(address(registry));
        vm.stopPrank();
        vm.prank(owner);
        registry.setExposureLedger(address(ledger));

        bondEscrow = new ProposerBondEscrow(address(wood), address(registry));
        escrow = new CompensationEscrow(owner, address(wood));

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

        gov.setExposureLedger(address(ledger));
        gov.setBondEscrow(address(bondEscrow));
        gov.setTierRegistry(address(tierRegistry));
        tierRegistry.certify(address(adapter), adapter.poke.selector, 1, CERTIFIED_BOUND_BPS, address(0));

        _deployAndWireCourt();

        // ── WOOD for the proposer's bond, the challenger's bond, and the
        //    accused guardian's counter-bond contributions.
        wood.mint(agent, 1_000_000e18);
        vm.prank(agent);
        wood.approve(address(bondEscrow), type(uint256).max);
        wood.mint(challenger, CHALLENGER_BOND);
        vm.prank(challenger);
        wood.approve(address(game), type(uint256).max);
        wood.mint(g1, CHALLENGER_BOND);
        vm.prank(g1);
        wood.approve(address(game), type(uint256).max);

        // ── PRE-drain LPs, one per timestamp so the vault's ERC20Votes
        //    checkpoints genuinely separate (`clock()` is `block.timestamp`).
        _deposit(lp1, LP1_ASSETS);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        _deposit(lp2, LP2_ASSETS);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
    }

    // ── Fixture helpers ───────────────────────────────────────────────────

    /// @dev THE WIRING IS MUTUAL AND BOTH HALVES MATTER. `game.setCourt` is what
    ///      lets a verdict beat the timeout; `court.setChallengeGame` is what the
    ///      court reads a challenge's status and governor from. A court wired one
    ///      way only either cannot rule or cannot be ruled by, which is why
    ///      Plan E's Task 7 makes the pair a deploy-time pre-flight.
    function _deployAndWireCourt() internal {
        court = new Court(owner, address(wood), PANEL_BOND);

        address[] memory members = new address[](3);
        members[0] = p1;
        members[1] = p2;
        members[2] = p3;

        vm.startPrank(owner);
        court.setChallengeGame(address(game));
        court.setStakedWood(address(swood));
        court.setParticipationFloorBps(FLOOR_BPS);
        court.setPanel(members);
        game.setCourt(address(court));
        vm.stopPrank();

        for (uint256 i; i < members.length; ++i) {
            _bondPanelist(members[i]);
        }

        wood.mint(appellant, APPEAL_BOND);
        vm.prank(appellant);
        wood.approve(address(court), type(uint256).max);

        assertEq(game.court(), address(court), "the game answers to this court");
        assertEq(court.challengeGame(), address(game), "and the court rules on this game");
        assertEq(court.appealBondWood(), APPEAL_BOND, "the appeal bond is seeded from the panel bond");
        assertEq(court.bondedWood(), 3 * PANEL_BOND, "three seated, bonded members");
        assertEq(wood.balanceOf(address(court)), 3 * PANEL_BOND, "and the court really holds them");
    }

    function _bondPanelist(address member) internal {
        wood.mint(member, PANEL_BOND);
        vm.startPrank(member);
        wood.approve(address(court), type(uint256).max);
        court.postPanelBond();
        vm.stopPrank();
        assertTrue(court.isReadyToRule(member), "seated and fully bonded");
    }

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

    function _execCalls() internal view returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](2);
        calls[0] = BatchExecutorLib.Call({target: address(adapter), data: abi.encodeCall(adapter.poke, ()), value: 0});
        calls[1] = BatchExecutorLib.Call({target: address(adapter), data: abi.encodeCall(adapter.bump, ()), value: 0});
    }

    function _settleCalls() internal view returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({target: address(adapter), data: abi.encodeCall(adapter.poke, ()), value: 0});
    }

    function _state(uint256 pid) internal view returns (uint256) {
        return uint256(gov.getProposal(pid).state);
    }

    /// @dev propose → review opens → g1 approves (coverage committed) → execute.
    ///      Identical across all three arcs on purpose: the only thing that
    ///      differs between them is what the COURT does, so anything that
    ///      differed here would invalidate the comparison.
    function _proposeApproveExecute() internal returns (uint256 pid) {
        vm.prank(agent);
        pid = gov.propose(
            address(vault),
            address(0),
            "ipfs://court-e2e",
            7 days,
            ISyndicateGovernor.RiskEnvelope({maxCapital: MAX_CAPITAL, maxDrawdownBps: 10_000}),
            _execCalls(),
            _settleCalls(),
            new ISyndicateGovernor.CoProposer[](0)
        );

        assertEq(gov.getProposal(pid).envelopeTier, 2, "uncertified call in the batch => tier 2");
        assertEq(gov.getProposal(pid).requiredCoverage, REQUIRED_COVERAGE, "half-notional + full-notional + settle");
        assertEq(gov.getProposal(pid).proposerBondWood, PROPOSER_BOND, "1% of $1,000 at the $0.05 haircut");

        vm.warp(gov.getProposal(pid).voteEnd + 1);
        registry.openReview(address(gov), pid);

        // TWO covering approvers, in this order and for this reason: g1 goes
        // first and its $1,500 of budget cannot cover the whole $2,000, so g2
        // books the $500 remainder. Both end up accused; only g1 will pay for
        // the defence.
        vm.prank(g1);
        registry.voteOnProposal(address(gov), pid, IGuardianRegistry.GuardianVoteType.Approve);
        vm.prank(g2);
        registry.voteOnProposal(address(gov), pid, IGuardianRegistry.GuardianVoteType.Approve);
        assertEq(ledger.openExposureUsd(g1), G1_COVERAGE_USD, "g1 committed all the budget it had");
        assertEq(ledger.openExposureUsd(g2), G2_COVERAGE_USD, "g2 reserved its whole free bond");

        (address[] memory approvers, uint256[] memory shares) = ledger.approversOf(address(gov), pid);
        assertEq(approvers.length, 2, "two covering approvers");
        assertEq(approvers[0], g1);
        assertEq(approvers[1], g2);
        // AT LEAST, not exactly. Reservations are upper bounds on liability and
        // each approver reserves up to the proposal's full need, so they sum to
        // MORE than it whenever more than one guardian covers — the pro-rata
        // `allocatedUsd` is what scales them back down at settle. The property
        // §3.3a actually needs is `Σ min(live_i, reserved_i) >= need`.
        assertGe(shares[0] + shares[1], COVERAGE_USD, "and between them they back the whole thing");

        vm.warp(gov.getProposal(pid).reviewEnd + 1);
        gov.executeProposal(pid);
        assertEq(_state(pid), uint256(ISyndicateGovernor.ProposalState.Executed), "executed");
        assertEq(adapter.pokes(), 1, "the batch really ran");
    }

    function _file(uint256 pid) internal returns (uint256 cid) {
        vm.prank(challenger);
        cid = game.file(
            address(gov),
            pid,
            IChallengeGame.Predicate.OutOfAdapterOutflow,
            address(adapter),
            adapter.poke.selector,
            "ipfs://evidence/out-of-adapter-outflow"
        );
    }

    /// @dev The full escalation, pooled: g1 is the ONLY approver with a live
    ///      commitment, so it funds the whole counter-bond itself and the pool
    ///      completes on its last contribution. Arc 1 opens this helper up and
    ///      walks the pool half-way first; arcs 2 and 3 use it whole.
    function _fileDisputeRefer(uint256 pid) internal returns (uint256 cid, uint256 caseId) {
        cid = _file(pid);
        vm.warp(game.challengeOf(cid).filedAt + 1 hours);
        vm.prank(g1);
        game.dispute(cid, type(uint256).max);
        assertEq(uint256(game.challengeOf(cid).status), uint256(IChallengeGame.Status.Disputed), "Disputed");
        assertEq(game.counterBondContributionOf(cid, g1), CHALLENGER_BOND, "g1 bought the whole escalation");
        caseId = court.refer(cid);
    }

    /// @dev All three seats convict. `finalizePanel` closes EARLY once every seat
    ///      has voted — there is nothing left to wait for, and burning the rest
    ///      of `panelWindow` would only eat into the challenge's own timeout.
    function _panelConvicts(uint256 caseId) internal {
        vm.prank(p1);
        court.panelRule(caseId, true);
        vm.prank(p2);
        court.panelRule(caseId, true);
        vm.prank(p3);
        court.panelRule(caseId, true);

        court.finalizePanel(caseId);
        ICourt.Case memory c = court.caseOf(caseId);
        assertEq(uint256(c.panelRuling), uint256(ICourt.Ruling.Guilty), "layer 1 convicted");
        assertEq(uint256(c.phase), uint256(ICourt.Phase.AppealWindow), "and opened the appeal window");
        assertEq(c.panelGuiltyVotes, 3, "a HEAD COUNT of seats, not stake");
        assertEq(c.panelNotGuiltyVotes, 0);
    }

    /// @dev Every panelist's bond, exactly as posted. The D4/F6 assertion arcs 2
    ///      and 3 both make: the merits track never touches it, whichever way the
    ///      merits came out.
    function _assertPanelBondsIntact(string memory why) internal view {
        assertEq(court.panelBondOf(p1), PANEL_BOND, why);
        assertEq(court.panelBondOf(p2), PANEL_BOND, why);
        assertEq(court.panelBondOf(p3), PANEL_BOND, why);
        assertEq(court.bondedWood(), 3 * PANEL_BOND, why);
        // Their own wallets are empty because every last WOOD they were minted is
        // still posted — so "bond intact" cannot be satisfied by a refund either.
        assertEq(wood.balanceOf(p1), 0, "nothing was handed back to the panelist");
        assertEq(wood.balanceOf(p2), 0);
        assertEq(wood.balanceOf(p3), 0);
    }

    // ── Arc 1: guilty, unappealed — Plan D's hole, closed ─────────────────

    /// @notice THE ARC PLAN E EXISTS FOR. A guilty approver runs the exact escape
    ///         Plan D left open: it buys the escalation with a counter-bond,
    ///         which stops the auto-slash clock and — before this plan — would
    ///         have failed the challenge in its favour once `disputeTimeout`
    ///         elapsed. Here the escalation is referred to a real court instead:
    ///         layer 1 convicts, nobody appeals, and `finalizeUnappealed` hands
    ///         the verdict to `ChallengeGame.rule` weeks BEFORE the timeout the
    ///         accused was buying.
    ///
    ///         Everything downstream is Plan D's own settle path, reached through
    ///         the court rather than through silence: the approver is slashed at
    ///         `maxSlashBps` into the compensation escrow as a case pinned to the
    ///         block before the drain, the named adapter loses its certification,
    ///         and the pre-drain LPs — not the buyer who arrived after — redeem
    ///         the proceeds 70/30.
    ///
    ///         The closing assertion is the load-bearing one: once the court has
    ///         ruled, warping past `disputeTimeout` and calling `resolve` reverts
    ///         `WrongStatus`. The clock the accused was running out cannot fire.
    function test_arc1_guiltyUnappealed_theRulingBeatsTheTimeout() public {
        uint256 pid = _proposeApproveExecute();
        uint256 executedAt = gov.getProposal(pid).executedAt;
        uint256 challengerBalBefore = wood.balanceOf(challenger);
        uint256 g1WalletBefore = wood.balanceOf(g1);

        // ── File. Bond pulled, coverage frozen.
        uint256 cid = _file(pid);
        uint256 filedAt = game.challengeOf(cid).filedAt;
        assertEq(
            game.challengeOf(cid).bondWood,
            CHALLENGER_BOND,
            "5% of the 2,500 USD of frozen reservations, at 0.05 USD/WOOD"
        );
        assertTrue(ledger.isCoverageFrozen(address(gov), pid), "the filing pins the coverage");

        // ── THE COUNTER-BOND IS POOLED, and the completed pool is what buys the
        //    escalation. A half-funded defence is not a defence: the challenge is
        //    still `Filed`, so there is nothing for the court to be referred.
        vm.warp(filedAt + 1 hours);
        vm.prank(g1);
        game.dispute(cid, CHALLENGER_BOND / 2);
        assertEq(uint256(game.challengeOf(cid).status), uint256(IChallengeGame.Status.Filed), "still Filed at half");
        assertEq(game.challengeOf(cid).counterBondWood, CHALLENGER_BOND / 2, "the pool is half full");
        vm.expectRevert(ICourt.ChallengeNotDisputed.selector);
        court.refer(cid);

        // ── The contribution that completes the pool is the one that flips the
        //    status, in the same call.
        vm.prank(g1);
        game.dispute(cid, type(uint256).max); // clamped to the shortfall
        assertEq(uint256(game.challengeOf(cid).status), uint256(IChallengeGame.Status.Disputed), "Disputed");
        assertEq(game.challengeOf(cid).counterBondWood, CHALLENGER_BOND, "the pool matches the bond exactly");
        assertEq(game.counterBondContributionOf(cid, g1), CHALLENGER_BOND, "g1 bought the whole escalation");
        assertEq(wood.balanceOf(g1), g1WalletBefore - CHALLENGER_BOND, "and paid for it");
        assertEq(game.bondedWood(), 2 * CHALLENGER_BOND, "both bonds are live");

        // ── Referral is permissionless: the accused cannot sit on the escalation
        //    it just bought and quietly let the clock do the work.
        uint256 caseId = court.refer(cid);
        ICourt.Case memory c = court.caseOf(caseId);
        assertEq(caseId, 1, "the first case");
        assertEq(court.caseOfChallenge(cid), caseId);
        assertEq(c.challengeId, cid);
        assertEq(c.snapshotTs, executedAt - 1, "the electorate is pinned to the block before the drain (D2)");
        assertEq(uint256(c.phase), uint256(ICourt.Phase.Panel), "layer 1 is taking votes");
        assertEq(swood.getPastTotalVotes(c.snapshotTs), TOTAL_VOTES, "70,000 WOOD of electorate");

        // ── The drain settles and a buyer arrives AFTER it — a real deposit whose
        //    shares and vote checkpoints both move, they just move too late.
        vm.warp(executedAt + 1 hours + 1);
        vm.prank(agent);
        gov.settleProposal(pid);
        _deposit(buyer, BUYER_ASSETS);
        assertEq(vault.balanceOf(buyer), BUYER_SHARES, "the buyer really holds shares");

        // ── Layer 1 convicts.
        _panelConvicts(caseId);
        uint256 panelFinalizedAt = court.caseOf(caseId).panelFinalizedAt;

        // ── THE TIMEOUT IS STILL PENDING AT THIS POINT. The accused's escape is
        //    not merely beaten on the merits — it has not even matured.
        vm.expectRevert(IChallengeGame.DelayNotElapsed.selector);
        game.resolve(cid);
        assertEq(swood.guardianStake(g1), G1_STAKE, "nothing slashed while the appeal window is open");
        assertEq(swood.guardianStake(g2), FILLER_STAKE);

        // ── The appeal window has to actually elapse; a ruling cannot be made
        //    final early just because nobody has appealed yet.
        vm.expectRevert(ICourt.WindowOpen.selector);
        court.finalizeUnappealed(caseId);

        // ── Nobody appeals. Permissionless finalization, and the caller chooses
        //    nothing: the verdict is `panelRuling` and the clock decides when.
        vm.warp(panelFinalizedAt + court.appealWindow());
        court.finalizeUnappealed(caseId);

        ICourt.Case memory resolved = court.caseOf(caseId);
        assertEq(uint256(resolved.phase), uint256(ICourt.Phase.Resolved), "the case is terminal");
        assertEq(uint256(resolved.finalRuling), uint256(ICourt.Ruling.Guilty), "and the verdict is the panel's");
        assertEq(resolved.appellant, address(0), "nobody appealed");

        // ── Plan D's settle path, reached through the court instead of silence.
        assertEq(uint256(game.challengeOf(cid).status), uint256(IChallengeGame.Status.Settled), "Settled");
        // PROPORTIONAL, NOT FULL. g1 RESERVED $1,500 but CARRIES $1,200 — the
        // $2,000 need split by effective bond, 1,500/2,500 — and its $1,500
        // bond covers that at 8,000 bps. So 24,000 of its 30,000 WOOD is taken.
        // The old "slashed in full" expectation priced liability at the
        // reservation, which is precisely the conflation `slashBpsFor` fixed:
        // slashing reservations would take the whole coverage from EVERY
        // approver.
        assertEq(
            swood.guardianStake(g1), 6_000e18, "the approver was slashed for what it carried, not what it reserved"
        );
        assertEq(
            swood.guardianStake(g2),
            4_000e18,
            "and so was the one that free-rode the defence: coverage is what is judged, "
            "at the same 8,000 bps - g2 carries $800 of the $2,000 against a $1,000 bond"
        );

        // ── A GUILTY RULING FORFEITS THE WHOLE POOL TO THE CHALLENGER, on top of
        //    its returned bond. Disputing was not free, and being right paid.
        assertEq(
            wood.balanceOf(challenger),
            challengerBalBefore + CHALLENGER_BOND,
            "bond returned plus the forfeited counter-bond pool"
        );
        assertEq(wood.balanceOf(g1), 0, "the accused lost the pool it posted as well as its stake");
        assertEq(wood.balanceOf(address(game)), 0, "nothing stranded in the game");
        assertEq(game.bondedWood(), 0);

        // ── The court is not a money path for the verdict: it moved a BIT, not
        //    WOOD. Its balance is still exactly the three panel bonds.
        assertEq(wood.balanceOf(address(court)), 3 * PANEL_BOND, "the court took nothing out of this");
        assertEq(court.forfeitedWood(), 0, "and forfeited nothing: the ruling went unappealed");
        _assertPanelBondsIntact("an unappealed conviction leaves the panel whole");

        // ── The named adapter lost its certification (§3.4 / D7).
        (uint8 tierAfter, uint16 boundAfter) = tierRegistry.tierOf(address(adapter), adapter.poke.selector);
        assertEq(tierAfter, 2, "demoted back to the arbitrary-calldata default");
        assertEq(boundAfter, 10_000);

        // ── §3.8: the case is pinned to the pre-drain block and the pre-drain
        //    cohort owns all of it, exactly 70/30.
        assertEq(escrow.caseCount(), 1, "one compensation case");
        uint256 escrowCaseId = escrow.caseCount();
        (address caseVault, uint256 snapTs, uint256 proceeds,,,,) = escrow.caseOf(escrowCaseId);
        assertEq(caseVault, address(vault), "pinned to the real vault");
        assertEq(snapTs, executedAt - 1, "and to the block before the drain executed");
        assertEq(snapTs, resolved.snapshotTs, "THE SAME INSTANT THE COURT JUDGED AT (D2): one rule, both consumers");
        assertEq(proceeds, PROCEEDS, "the full slash reached the escrow");
        assertEq(vault.getPastTotalSupply(snapTs), SNAP_SUPPLY, "snapshot supply is the two pre-drain LPs");
        assertEq(escrow.claimable(escrowCaseId, lp1), LP1_CLAIM);
        assertEq(escrow.claimable(escrowCaseId, lp2), LP2_CLAIM);
        assertEq(escrow.claimable(escrowCaseId, buyer), 0, "the post-drain buyer has no claim");

        uint256 lp1Before = wood.balanceOf(lp1);
        uint256 lp2Before = wood.balanceOf(lp2);
        vm.prank(lp1);
        uint256 got1 = escrow.redeem(escrowCaseId);
        vm.prank(lp2);
        uint256 got2 = escrow.redeem(escrowCaseId);
        assertEq(got1, LP1_CLAIM, "LP1 redeemed its 70%");
        assertEq(got2, LP2_CLAIM, "LP2 redeemed its 30%");
        assertEq(wood.balanceOf(lp1), lp1Before + LP1_CLAIM, "LP1 actually received the WOOD");
        assertEq(wood.balanceOf(lp2), lp2Before + LP2_CLAIM, "LP2 actually received the WOOD");
        assertEq(escrow.totalEscrowed(), 0, "the whole slash reached pre-drain holders");
        vm.prank(buyer);
        vm.expectRevert(ICompensationEscrow.NoClaim.selector);
        escrow.redeem(escrowCaseId);

        // ── The freeze lifted on the terminal path.
        assertFalse(ledger.isCoverageFrozen(address(gov), pid), "unfrozen");

        // ══ THE ASSERTION THIS WHOLE ARC EXISTS TO MAKE ══
        //    `disputeTimeout` was the accused's escape: from `Disputed`, Plan D's
        //    `resolve` fails the challenge IN ITS FAVOUR once the clock runs out.
        //    Walk the clock all the way past it. There is nothing left to run out
        //    — the challenge is already terminal, so the timeout cannot fire, and
        //    it cannot un-slash what the ruling took.
        vm.warp(filedAt + game.disputeTimeout() + 1);
        vm.expectRevert(IChallengeGame.WrongStatus.selector);
        game.resolve(cid);
        assertEq(uint256(game.challengeOf(cid).status), uint256(IChallengeGame.Status.Settled), "still Settled");
        assertEq(
            swood.guardianStake(g1),
            6_000e18,
            "and still slashed at its carried rate: the ruling beat the timeout, terminally"
        );

        // The court's own case is likewise beyond re-litigation.
        vm.expectRevert(ICourt.WrongPhase.selector);
        court.finalizeUnappealed(caseId);
    }

    // ── Arc 2: acquitted on appeal — D4/F6, proven end to end ─────────────

    /// @notice THE INDEPENDENCE ARC. Layer 1 convicts; layer 2 is asked to look
    ///         again, clears the participation floor, and OVERTURNS the panel on
    ///         the merits. The challenge fails, the challenger's bond forfeits
    ///         (minus the burn) to whoever actually funded the defence —
    ///         and the panelists who called it wrong keep every WOOD of their
    ///         bonds.
    ///
    ///         THAT LAST FACT IS D4/F6, AND IT IS ONLY MEANINGFUL HERE. In
    ///         isolation "an overturn does not slash the panel" is a unit test on
    ///         a storage slot; against the real stack it says something sharper —
    ///         the ruling was materially wrong, real money moved because of it,
    ///         two real guardians were nearly slashed for it, AND STILL nothing
    ///         happened to the panel bond. §3.5's first draft slashed on exactly
    ///         this event, which handed anyone who could swing the cheap appeal
    ///         layer both halves of the prize: a corrupt ruling made safe and the
    ///         honest panelists who voted against it punished. The only thing an
    ///         overturn does to a panelist here is extend the window in which a
    ///         SEPARATE vote could find bad faith — asserted below as an exact
    ///         deadline, not as a vague "still locked".
    ///
    ///         The two voters are g3 and g4, neither of whom approved the
    ///         challenged proposal. The acquittal is therefore the disinterested
    ///         electorate's, and the arc asserts the two ACCUSED approvers never
    ///         voted at all.
    function test_arc2_acquittedOnAppeal_thePanelistBondIsUntouched() public {
        uint256 pid = _proposeApproveExecute();
        uint256 challengerBalBefore = wood.balanceOf(challenger);
        uint256 g1WalletBefore = wood.balanceOf(g1);
        uint256 appellantBefore = wood.balanceOf(appellant);
        assertEq(wood.balanceOf(g2), 0, "the free-riding approver starts with nothing liquid");

        (uint256 cid, uint256 caseId) = _fileDisputeRefer(pid);
        uint256 filedAt = game.challengeOf(cid).filedAt;
        assertEq(game.counterBondContributionOf(cid, g2), 0, "g2 paid nothing toward the defence");

        _panelConvicts(caseId);

        // ── The appeal. Permissionless — gating who may check the panel would
        //    hand the panel a say in whether it is checked.
        vm.prank(appellant);
        court.appeal(caseId);
        ICourt.Case memory appealed = court.caseOf(caseId);
        assertEq(uint256(appealed.phase), uint256(ICourt.Phase.Appeal), "layer 2 is open");
        assertEq(appealed.appellant, appellant);
        assertEq(appealed.appealBond, APPEAL_BOND, "the bond is captured at filing time");
        assertEq(wood.balanceOf(appellant), appellantBefore - APPEAL_BOND, "and really paid");
        assertEq(court.bondedWood(), 3 * PANEL_BOND + APPEAL_BOND, "panel bonds plus one open appeal");

        // ── A CONTESTED, QUORATE VOTE. Weight is `getPastVotes` at the stored
        //    snapshot — already age-weighted by sWOOD (D3), never re-weighted
        //    here — so it is the pre-drain electorate that decides.
        vm.prank(g3);
        court.voteAppeal(caseId, true); // 20,000 WOOD says the panel was right
        vm.prank(g4);
        court.voteAppeal(caseId, false); // 30,000 WOOD says it was wrong

        // AND THEY COULD NOT HAVE. This arc always routed its overturn through
        // the disinterested pair by construction; §3.5's exclusion makes that a
        // property of the contract rather than of the fixture. g1 alone holds
        // 30,000 WOOD — enough to clear the floor and carry this vote by itself —
        // and it is the party the panel just convicted.
        vm.expectRevert(ICourt.AccusedCannotVote.selector);
        vm.prank(g1);
        court.voteAppeal(caseId, false);
        vm.expectRevert(ICourt.AccusedCannotVote.selector);
        vm.prank(g2);
        court.voteAppeal(caseId, false);

        assertEq(uint256(court.appealVoteOf(caseId, g1)), uint256(ICourt.Ruling.None), "the accused did not vote");
        assertEq(uint256(court.appealVoteOf(caseId, g2)), uint256(ICourt.Ruling.None), "nor its co-approver");

        uint256 appealedAt = court.caseOf(caseId).appealedAt;
        vm.expectRevert(ICourt.WindowOpen.selector);
        court.finalizeAppeal(caseId);

        vm.warp(appealedAt + court.appealVoteWindow());
        court.finalizeAppeal(caseId);

        // ── THE OVERTURN. Turnout cleared the floor, so the majority of cast
        //    votes decided and overrode layer 1 where they disagree.
        ICourt.Case memory resolved = court.caseOf(caseId);
        assertEq(uint256(resolved.phase), uint256(ICourt.Phase.Resolved));
        assertEq(uint256(resolved.panelRuling), uint256(ICourt.Ruling.Guilty), "layer 1 had convicted");
        assertEq(uint256(resolved.finalRuling), uint256(ICourt.Ruling.NotGuilty), "layer 2 overturned it");
        assertEq(resolved.appealGuiltyVotes, FILLER_STAKE, "g3's 20,000 for the panel");
        assertEq(resolved.appealNotGuiltyVotes, G4_STAKE, "g4's 30,000 against it");
        assertEq(
            resolved.appealGuiltyVotes + resolved.appealNotGuiltyVotes,
            50_000e18,
            "50,000 of turnout against a 30,000 floor: this vote genuinely decided something"
        );
        assertGe(resolved.appealGuiltyVotes + resolved.appealNotGuiltyVotes, FLOOR_VOTES);

        // ── The challenge fails, exactly as a timeout would have failed it —
        //    `_fail` asserts nothing about the clock, so an acquittal and an
        //    unruled escalation unwind identically.
        assertEq(uint256(game.challengeOf(cid).status), uint256(IChallengeGame.Status.Failed), "Failed");
        assertEq(swood.guardianStake(g1), G1_STAKE, "the accused was never slashed");
        assertEq(swood.guardianStake(g2), FILLER_STAKE);
        assertEq(escrow.caseCount(), 0, "no compensation case was ever opened");
        assertEq(escrow.totalEscrowed(), 0);
        (uint8 tierAfter, uint16 boundAfter) = tierRegistry.tierOf(address(adapter), adapter.poke.selector);
        assertEq(tierAfter, 1, "the adapter keeps its certification: a failed challenge leaves no mark");
        assertEq(boundAfter, CERTIFIED_BOUND_BPS);

        // ── THE FORFEIT, WITH THE BURN OFF THE TOP AND KEYED TO CONTRIBUTION.
        //    The burn is what stops the challenger's own second address from
        //    funding the counter-bond and collecting its own forfeited bond back.
        uint256 burned = (CHALLENGER_BOND * game.forfeitBurnBps()) / 10_000;
        assertEq(burned, 500e18, "20% of a 2,500 WOOD bond");
        assertEq(wood.balanceOf(challenger), challengerBalBefore - CHALLENGER_BOND, "the challenger forfeited it");
        assertEq(wood.balanceOf(game.BURN_ADDRESS()), burned, "and the burned slice left the system for good");
        assertEq(
            wood.balanceOf(g1),
            g1WalletBefore + CHALLENGER_BOND - burned,
            "g1 funded 100% of the pool, so it gets its contribution back plus the whole unburned forfeit"
        );
        // THE FREE-RIDER TEST. g2 is an ACCUSED APPROVER that the failed
        // challenge vindicated, and it collects NOTHING — because the split is
        // keyed to what each side actually put into the defence, not to the
        // coverage each committed. Under the old coverage-keyed split g2 would
        // have taken a quarter of the forfeit for paying nothing, which is
        // exactly how a collective defence fails to get funded.
        assertEq(wood.balanceOf(g2), 0, "a non-contributing approver receives ZERO of the forfeit");
        assertEq(wood.balanceOf(address(game)), 0, "nothing stranded in the game");
        assertEq(game.bondedWood(), 0);

        // ── The appellant is made whole: above the floor the bond returns
        //    whichever way the vote went. It is not a fee on being wrong.
        assertEq(wood.balanceOf(appellant), appellantBefore, "appeal bond returned in full");
        assertEq(court.forfeitedWood(), 0, "and nothing forfeited into the court's pot");
        vm.expectRevert(ICourt.NothingToBurn.selector);
        court.burnForfeited();

        // ══ D4 / F6: THE MERITS OVERTURN DID NOT TOUCH THE PANEL BOND ══
        _assertPanelBondsIntact("being overturned on the merits is not bad faith");
        assertEq(wood.balanceOf(address(court)), 3 * PANEL_BOND, "the court holds the three bonds and nothing else");
        assertEq(court.openBadFaithVotes(p1), 0, "no bad-faith proceeding was opened by the overturn");
        assertEq(court.openBadFaithVotes(p2), 0);
        assertEq(court.openBadFaithVotes(p3), 0);

        // The ONLY thing the case did to a panelist: hold its bond inside the
        // window where a SEPARATE vote — never this one — could find bad faith.
        // Asserted as an exact deadline, because "still locked" would also be
        // true of a bond that had been slashed to zero.
        //
        // AND THE DEADLINE IS THE PANEL-PHASE ONE, NOT THE RESOLUTION ONE. Both
        // locks are applied — `panelRule` writes `referredAt + panelWindow +
        // badFaithWindow`, `_resolve` writes `finalizedAt + badFaithWindow` — and
        // `_lockPanelBond` never shortens, so the later of the two stands. On
        // this arc the panel closed EARLY (every seat voted at once) and the
        // appeal ran only its 5-day vote window, so `finalizedAt` lands 5 days
        // after referral while the panel-phase lock reserved 7 — the floor is
        // still the binding term, by exactly 2 days. The `_resolve` extension
        // starts to bite on the arcs it was written for: a panel that uses its
        // whole window and an appeal filed late in `appealWindow`.
        uint256 panelPhaseLock = resolved.referredAt + court.panelWindow() + court.badFaithWindow();
        uint256 resolutionLock = resolved.finalizedAt + court.badFaithWindow();
        assertGt(panelPhaseLock, resolutionLock, "the early-closing panel makes the panel-phase floor the binding one");
        assertEq(panelPhaseLock - resolutionLock, 2 days, "and it binds by the 2 days the appeal did not use");
        assertEq(court.panelBondLockedUntil(p1), panelPhaseLock, "locked, not slashed");
        assertEq(court.panelBondLockedUntil(p2), panelPhaseLock);
        assertEq(court.panelBondLockedUntil(p3), panelPhaseLock);

        // The bond is escrowed, not merely accounted for: a panelist cannot walk
        // away from a ruling it just got overturned. That is what keeps the F6
        // track able to slash it later — while the merits track, here, did not.
        vm.prank(p1);
        vm.expectRevert(ICourt.StillSeated.selector);
        court.withdrawPanelBond();

        // ── The coverage a failed challenge pinned is genuinely free again.
        assertFalse(ledger.isCoverageFrozen(address(gov), pid), "unfrozen on the fail path too");
        vm.prank(address(registry));
        ledger.releaseApproval(address(gov), pid, g1);
        assertEq(ledger.openExposureUsd(g1), 0, "the guardian recycled the budget the filing had pinned");

        // ── And the timeout the accused would once have waited for is moot: the
        //    court got there first on this arc too, it simply ruled the other way.
        vm.warp(filedAt + game.disputeTimeout() + 1);
        vm.expectRevert(IChallengeGame.WrongStatus.selector);
        game.resolve(cid);
    }

    // ── Arc 3: below-floor appeal — D6, the anti-capture arc ──────────────

    /// @notice THE ARC THAT PROVES AN APPEAL IS NOT A VETO. §3.5 names the token
    ///         layer's own failure mode: at a ~$15M mcap with single-digit
    ///         turnout, a vote is cheap to swing. D6 is the answer — an appeal
    ///         that fails to raise a quorum is a NON-EVENT. Not an acquittal, not
    ///         a ratification: the panel's ruling stands untouched, the votes
    ///         that were cast are DISCARDED even though they all went the other
    ///         way, and the appellant's bond forfeits for escalating without
    ///         delivering the electorate that would have made the escalation
    ///         mean something.
    ///
    ///         So the shape of this arc is deliberately adversarial: every single
    ///         vote cast says NOT GUILTY, and the guardian is slashed anyway. If
    ///         the below-floor branch were quietly "the appeal upheld the panel",
    ///         a 20,000-WOOD holder could acquit a drainer at will.
    ///
    ///         The arc also closes the loop on the forfeited bond, because the
    ///         court is where it lands. `_resolve` RESERVES the flat panel reward
    ///         out of the pot first, and the permissionless `burnForfeited` then
    ///         destroys only the unreserved surplus — so a burn (which anyone may
    ///         trigger, precisely so nobody's forbearance is worth anything)
    ///         cannot defund a panel that has already earned its sitting fee.
    function test_arc3_belowFloorAppeal_thePanelRulingStandsAndTheGuardianIsSlashed() public {
        uint256 pid = _proposeApproveExecute();
        uint256 executedAt = gov.getProposal(pid).executedAt;
        uint256 challengerBalBefore = wood.balanceOf(challenger);
        uint256 appellantBefore = wood.balanceOf(appellant);

        (uint256 cid, uint256 caseId) = _fileDisputeRefer(pid);
        uint256 filedAt = game.challengeOf(cid).filedAt;
        uint256 snapshotTs = court.caseOf(caseId).snapshotTs;

        // The floor, read off the live configuration rather than assumed — AND
        // OFF THE REDUCED BASE, because the two covering approvers are barred
        // from this vote and their weight is therefore not something honest
        // turnout can be asked to outvote. `accusedWeight` was summed once, at
        // referral, and is read from the case rather than recomputed here.
        assertEq(swood.getPastTotalVotes(snapshotTs), TOTAL_VOTES, "100,000 WOOD of electorate at the snapshot");
        assertEq(court.caseOf(caseId).accusedWeight, ACCUSED_VOTES, "g1 + g2 hold half of it and may not vote");
        assertTrue(court.isAccused(caseId, g1), "the covering approvers are the ones on trial");
        assertTrue(court.isAccused(caseId, g2));
        uint256 floor = (court.participationFloorBps() * (TOTAL_VOTES - ACCUSED_VOTES)) / 10_000;
        assertEq(floor, FLOOR_VOTES, "60% of the 50,000 that may actually vote: the same 30,000 bar as before");

        _panelConvicts(caseId);

        // Rewards on, funded by whatever this case forfeits. Set before the case
        // resolves, because `_resolve` is where the liability is reserved.
        vm.prank(owner);
        court.setPanelRewardWood(PANEL_REWARD);

        // ── The appeal, and a turnout that misses.
        vm.prank(appellant);
        court.appeal(caseId);
        assertEq(wood.balanceOf(appellant), appellantBefore - APPEAL_BOND, "the appellant posted the bond");

        // EVERY vote cast says NOT GUILTY. g3 alone is 20,000 WOOD against a
        // 30,000 floor — 20% turnout, which is exactly the single-digit-ish
        // participation §3.5 says a token layer cannot be trusted with alone.
        vm.prank(g3);
        court.voteAppeal(caseId, false);
        assertEq(uint256(court.appealVoteOf(caseId, g3)), uint256(ICourt.Ruling.NotGuilty), "and it was recorded");

        uint256 appealedAt = court.caseOf(caseId).appealedAt;
        vm.warp(appealedAt + court.appealVoteWindow());
        court.finalizeAppeal(caseId);

        // ══ D6: THE PANEL RULING STANDS, AND THIS IS NOT AN ACQUITTAL ══
        ICourt.Case memory resolved = court.caseOf(caseId);
        assertEq(resolved.appealGuiltyVotes, 0, "nobody voted to convict on appeal");
        assertEq(resolved.appealNotGuiltyVotes, FILLER_STAKE, "and 20,000 WOOD voted to acquit");
        assertLt(resolved.appealGuiltyVotes + resolved.appealNotGuiltyVotes, floor, "turnout missed the floor");
        assertEq(uint256(resolved.panelRuling), uint256(ICourt.Ruling.Guilty), "layer 1 convicted");
        assertEq(
            uint256(resolved.finalRuling),
            uint256(ICourt.Ruling.Guilty),
            "AND THE COURT CONVICTED: 100% of the cast votes said acquit and were discarded, "
            "because a vote that cannot raise a quorum decides nothing"
        );

        // ── The consequence is Plan D's full settle path, identical to arc 1's:
        //    an appeal below the floor changes nothing about the outcome.
        assertEq(uint256(game.challengeOf(cid).status), uint256(IChallengeGame.Status.Settled), "Settled");
        // Proportional, exactly as in arc 1: $1,200 carried against a $1,500
        // bond is 8,000 bps, so 6,000 of the 30,000 WOOD survives.
        assertEq(
            swood.guardianStake(g1), 6_000e18, "the approver was slashed for what it carried, not what it reserved"
        );
        assertEq(swood.guardianStake(g2), 4_000e18, "and so was its co-approver, at the same proportional rate");
        assertEq(escrow.caseCount(), 1, "a compensation case really opened");
        uint256 escrowCaseId = escrow.caseCount();
        (address caseVault, uint256 snapTs, uint256 proceeds,,,,) = escrow.caseOf(escrowCaseId);
        assertEq(caseVault, address(vault));
        assertEq(snapTs, executedAt - 1, "pinned to the block before the drain");
        assertEq(snapTs, snapshotTs, "the same instant the appeal's electorate was read at (D2)");
        assertEq(proceeds, PROCEEDS, "both approvers' whole stake reached the escrow");
        assertEq(escrow.claimable(escrowCaseId, lp1), LP1_CLAIM);
        assertEq(escrow.claimable(escrowCaseId, lp2), LP2_CLAIM);
        (uint8 tierAfter,) = tierRegistry.tierOf(address(adapter), adapter.poke.selector);
        assertEq(tierAfter, 2, "and the named adapter was demoted");

        // ── The challenger, who was right, is made whole and paid the pool.
        assertEq(
            wood.balanceOf(challenger),
            challengerBalBefore + CHALLENGER_BOND,
            "bond returned plus the forfeited counter-bond pool"
        );
        assertEq(wood.balanceOf(game.BURN_ADDRESS()), 0, "a PASSED challenge burns nothing: there is no forfeited bond");

        // ── THE APPELLANT'S BOND FORFEITS. This is the one condition on which it
        //    does — not losing, which costs nothing (arc 2 got its bond back
        //    after WINNING, and would have got it back after losing quorately
        //    too), but failing to raise an electorate at all.
        assertEq(wood.balanceOf(appellant), appellantBefore - APPEAL_BOND, "forfeited, not returned");
        assertEq(court.forfeitedWood(), APPEAL_BOND, "into the court's ownerless pot");
        assertEq(court.bondedWood(), 3 * PANEL_BOND, "no live bond remains: only the panel's");

        // ── Panel bonds are untouched here too. Neither branch of the merits
        //    track can reach them; only the separate bad-faith vote can (D4).
        _assertPanelBondsIntact("a below-floor appeal does not touch the panel bond either");

        // ── THE REWARD WAS RESERVED AT RESOLUTION, out of the very bond this
        //    failed appeal forfeited: bad conduct funds the honest panel's
        //    sitting fee, and no new WOOD sink was invented for it.
        assertEq(court.reservedRewards(), 3 * PANEL_REWARD, "three ruling members, one flat fee each");
        assertEq(court.panelRewardOf(p1), PANEL_REWARD, "FLAT (D5): the same whichever way it ruled");
        assertEq(court.panelRewardOf(p2), PANEL_REWARD);
        assertEq(court.panelRewardOf(p3), PANEL_REWARD);
        assertEq(court.panelVoters(caseId).length, 3);

        // ── §4, at every step: `balance == bondedWood + forfeitedWood`.
        assertEq(wood.balanceOf(address(court)), court.bondedWood() + court.forfeitedWood(), "custody invariant");

        // ── THE BURN IS PERMISSIONLESS AND HAS NO BENEFICIARY. Anyone may call
        //    it — here a passer-by with no role in any of this — and it takes
        //    only the UNRESERVED surplus, so the panel's accrued pay survives it.
        address passerby = makeAddr("passerby");
        uint256 deadBefore = wood.balanceOf(game.BURN_ADDRESS());
        vm.prank(passerby);
        uint256 burned = court.burnForfeited();
        assertEq(burned, APPEAL_BOND - 3 * PANEL_REWARD, "the surplus only");
        assertEq(wood.balanceOf(game.BURN_ADDRESS()), deadBefore + burned, "and it went to a dead address");
        assertEq(wood.balanceOf(passerby), 0, "the caller earned nothing: there is nobody to profit from a forfeit");
        assertEq(court.forfeitedWood(), 3 * PANEL_REWARD, "exactly the reserve is left");
        assertEq(court.reservedRewards(), 3 * PANEL_REWARD, "untouched by the burn");

        // A second burn finds nothing: every remaining unit is spoken for. This
        // is what "a burn cannot unfund the panel" means operationally.
        vm.expectRevert(ICourt.NothingToBurn.selector);
        court.burnForfeited();

        // ── And the panel can actually collect what survived the burn.
        vm.prank(p1);
        uint256 claimed = court.claimPanelReward();
        assertEq(claimed, PANEL_REWARD);
        assertEq(wood.balanceOf(p1), PANEL_REWARD, "paid, out of a pot a burn had already run over");
        vm.prank(p2);
        court.claimPanelReward();
        vm.prank(p3);
        court.claimPanelReward();
        assertEq(court.reservedRewards(), 0);
        assertEq(court.forfeitedWood(), 0);
        assertEq(wood.balanceOf(address(court)), 3 * PANEL_BOND, "back to the three bonds and nothing else");
        assertEq(wood.balanceOf(address(court)), court.bondedWood() + court.forfeitedWood(), "custody invariant");

        // ── The pre-drain LPs redeem the slash, as in arc 1: a below-floor
        //    appeal delays compensation by a vote window and changes nothing else.
        uint256 lp1Before = wood.balanceOf(lp1);
        vm.prank(lp1);
        uint256 got1 = escrow.redeem(escrowCaseId);
        assertEq(got1, LP1_CLAIM);
        assertEq(wood.balanceOf(lp1), lp1Before + LP1_CLAIM);

        // ── The timeout is moot on this arc too.
        vm.warp(filedAt + game.disputeTimeout() + 1);
        vm.expectRevert(IChallengeGame.WrongStatus.selector);
        game.resolve(cid);
        assertEq(
            swood.guardianStake(g1),
            6_000e18,
            "still slashed at its carried rate: a failed appeal did not buy the accused an acquittal"
        );
    }
}
