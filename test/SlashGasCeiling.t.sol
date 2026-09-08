// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

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
import {TokenCourt} from "../src/TokenCourt.sol";
import {ITokenCourt} from "../src/interfaces/ITokenCourt.sol";
import {ProposerBondEscrow} from "../src/ProposerBondEscrow.sol";
import {BatchExecutorLib} from "../src/BatchExecutorLib.sol";
import {ProtocolConfig} from "../src/ProtocolConfig.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "./mocks/MockAgentRegistry.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";
import {GovEnvelope} from "./helpers/GovEnvelope.sol";
import {deployTierRegistry} from "./helpers/TierRegistryFixture.sol";

/// @dev Chainlink-shaped USD feed for the vault asset.
contract SlashGasFeed {
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

/// @dev Two entrypoints, one certified and one not, so the exec batch resolves
///      to tier 2 and the §3.3a coverage quorum engages.
contract SlashGasAdapter {
    uint256 public pokes;
    uint256 public bumps;

    function poke() external {
        pokes++;
    }

    function bump() external {
        bumps++;
    }
}

/// @title SlashGasCeilingTest
/// @notice PR #56 review H2. The settle path's gas floor is checked against the
///         gas a transaction can actually be given on the target chain, and a
///         FULL-CAP conviction is executed inside that budget for real.
///
/// @dev    THE FINDING. `ChallengeGame._settle` refuses to run unless
///         `gasleft() >= approvers.length * SLASH_GAS_PER_APPROVER +
///         SLASH_GAS_BASE`. At the old constants (300k / 1M) and the registry's
///         `MAX_APPROVERS_PER_PROPOSAL = 100` that floor was 31,000,000 gas —
///         measured INSIDE `ChallengeGame.rule`, two external frames below an
///         EOA. Robinhood Chain (4663) caps a transaction at
///         `maxTxGasLimit = 32,000,000` (`ArbGasInfo.getGasAccountingParams()`,
///         probed on mainnet 2026-07-24; the block `gasLimit` field reads 2^50,
///         Orbit's "no block cap" sentinel, so the per-tx limit is the binding
///         one). After EIP-150's 63/64 haircut at each of those two frames a
///         31,000,000 floor needs ~31,986,000 of frame-0 gas BEFORE `finalize`'s
///         own prelude and `_settle`'s pre-check work — more than a transaction
///         can carry. A full-cap conviction was therefore unminable:
///         `TokenCourt.finalize` bubbles the revert (it only swallows
///         `WrongStatus`), the case stays in `Voting`, and the challenge times
///         out through `resolve` -> `_fail`, ACQUITTING the accused and paying
///         them the challenger's forfeited bond.
///
///         And the cap is cheap to approach on purpose: an attacker stakes
///         `minGuardianStake` across ~100 addresses and approves its own
///         proposal. Those are dust approvers (`slashBpsFor` scales them to 0,
///         `slashToEscrow` skips them at `requested == 0`), so the padding costs
///         almost nothing while adding `SLASH_GAS_PER_APPROVER` to the floor per
///         address. The guard written to stop a mid-array out-of-gas became the
///         denial mechanism.
///
/// @dev    THE VERIFIED CALL DEPTH IS TWO, NOT THREE. `_settle` is a PRIVATE
///         function — it shares a frame with its caller. Neither `ChallengeGame`
///         nor `TokenCourt` sits behind a proxy (both are plain `Ownable2Step`
///         contracts, no delegatecall hop). So the deepest external path down to
///         the `gasleft()` check is
///
///             EOA -> TokenCourt.finalize   [frame 1]
///                 -> ChallengeGame.rule    [frame 2]  <- gasleft() checked here
///                    _settle               (private, still frame 2)
///                    -> StakedWood.slashToEscrow [frame 3, + proxy delegatecall]
///
///         i.e. TWO `CALL`s above the check, so the haircut on the floor is
///         `(63/64)^2`, not `(63/64)^3`. The `resolve` entry is shallower still
///         (one frame). The ceiling gate below uses `(63/64)^3` anyway: the
///         third factor is spent on `finalize`'s prelude, the intrinsic
///         transaction cost, and `_settle`'s own pre-check work
///         (`_accusedWithRates` reads the ledger's rate for all 100 approvers
///         before the floor is ever consulted), all of which come out of the
///         same 32M.
contract SlashGasCeilingTest is Test {
    // ── Real stack ──
    ERC20Mock public usdg;
    ERC20Mock public wood;
    BatchExecutorLib public executorLib;
    MockAgentRegistry public agentRegistry;
    ProtocolConfig public protocolConfig;
    SlashGasFeed public feed;
    SlashGasAdapter public adapter;

    StakedWood public swood;
    GuardianRegistry public registry;
    ExposureLedger public ledger;
    TierRegistry public tierRegistry;
    ProposerBondEscrow public bondEscrow;
    ChallengeGame public game;
    TokenCourt public court;

    SyndicateVault public vault;
    SyndicateGovernor public gov;

    address public owner = makeAddr("owner");
    address public ledgerOwner = makeAddr("ledgerOwner");
    address public backstop = makeAddr("backstop");
    address public agent = makeAddr("agent");
    address public challenger = makeAddr("challenger");
    address public lp1 = makeAddr("lp1");

    /// @dev The approver cohort — the accused set a conviction slashes.
    address[] public approvers;
    /// @dev Two non-accused holders, so the court's participation floor can be
    ///      cleared by somebody the conviction is not about (`vote` bars the
    ///      accused, and at the cap the accused are most of the cohort).
    address public juror1 = makeAddr("juror1");
    address public juror2 = makeAddr("juror2");

    uint256 constant VOTING_PERIOD = 1 days;
    uint256 constant EXECUTION_WINDOW = 1 days;
    uint256 constant REVIEW_PERIOD = 24 hours;
    uint256 constant BLOCK_QUORUM_BPS = 3000;
    uint256 constant MIN_GUARDIAN_STAKE = 10_000e18;
    uint256 constant COOL_DOWN = 45 days;
    uint256 constant EPOCH_LENGTH = 28 days;
    uint256 constant MATURATION = 30 days;

    uint256 constant APPROVER_STAKE = MIN_GUARDIAN_STAKE; // the cheapest cohort seat there is
    uint256 constant JUROR_STAKE = 250_000e18;

    uint256 constant LP1_ASSETS = 70_000e6;
    /// @dev Sized so that ONE approver at `minGuardianStake` already clears the
    ///      coverage quorum. Issue #43's per-call caps changed the exact
    ///      figure: `_execCalls()` has 2 calls (`poke` certified at
    ///      CERTIFIED_BOUND_BPS, `bump` uncertified) and the test-fixture
    ///      default caps only the FIRST call (`poke`, cap = maxCapital) —
    ///      `bump`'s cap is 0, contributing nothing. `requiredCoverage` =
    ///      (maxCapital * 5_000/10_000) [exec poke] + 0 [exec bump] +
    ///      (maxCapital * 5_000/10_000) [settle poke, default cap =
    ///      maxCapital] = maxCapital = $100 at the $1.00 asset price — still
    ///      comfortably against the $500 of slashable bond a 10,000-WOOD seat
    ///      carries at the $0.05 governance haircut. That keeps the SAME
    ///      proposal executable at every cohort size this file measures,
    ///      which is the only way the sizes are comparable.
    uint256 constant MAX_CAPITAL = 100e6;
    uint16 constant CERTIFIED_BOUND_BPS = 5_000;

    /// @notice Robinhood Chain (4663) `maxTxGasLimit`, from
    ///         `ArbGasInfo.getGasAccountingParams()` at precompile
    ///         `0x000000000000000000000000000000000000006C`, probed against
    ///         `https://rpc.mainnet.chain.robinhood.com` on 2026-07-24:
    ///         `speedLimitPerSecond = 7,000,000`, `gasPoolMax = 32,000,000`,
    ///         `maxTxGasLimit = 32,000,000`. The block `gasLimit` header field
    ///         reads 2^50 — Orbit's "no block cap" sentinel — so this per-tx
    ///         limit is what actually binds a conviction.
    uint256 internal constant MAX_TX_GAS = 32_000_000;

    /// @dev Intrinsic cost of the `finalize(uint256)` transaction that carries a
    ///      conviction: 21,000 base plus 4 selector bytes and 32 argument bytes
    ///      at 16 gas per non-zero byte. Rounded UP to 22,000, so the budget
    ///      handed to frame 0 below is never optimistic.
    uint256 internal constant INTRINSIC_TX_GAS = 22_000;

    // ── Fixture ───────────────────────────────────────────────────────────

    /// @dev Not `setUp()`: the cohort size is the independent variable of this
    ///      whole file, so every test builds its own stack at the size it needs.
    function _deployStack(uint256 approverCount) internal {
        usdg = new ERC20Mock("USD Gov", "USDG", 6);
        wood = new ERC20Mock("Sherwood", "WOOD", 18);
        executorLib = new BatchExecutorLib();
        agentRegistry = new MockAgentRegistry();
        protocolConfig = new ProtocolConfig(owner);
        adapter = new SlashGasAdapter();
        tierRegistry = new TierRegistry(address(this));

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

        GuardianRegistry regImpl = new GuardianRegistry(6 hours);
        bytes memory regInit = abi.encodeCall(
            GuardianRegistry.initialize, (owner, address(this), address(swood), REVIEW_PERIOD, BLOCK_QUORUM_BPS)
        );
        registry = GuardianRegistry(address(new ERC1967Proxy(address(regImpl), regInit)));
        vm.prank(owner);
        swood.setRegistry(address(registry));

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

        // ── The cohort. Every approver takes the CHEAPEST seat the registry
        //    sells (`minGuardianStake`) — exactly what an attacker padding the
        //    accused set would buy, and the size at which a cohort of 100 is
        //    reachable in practice.
        for (uint256 i = 0; i < approverCount; i++) {
            address a = address(uint160(uint256(keccak256(abi.encodePacked("approver", i)))));
            approvers.push(a);
            _stakeGuardian(a, APPROVER_STAKE, 1000 + i);
        }
        _stakeGuardian(juror1, JUROR_STAKE, 1);
        _stakeGuardian(juror2, JUROR_STAKE, 2);
        skip(MATURATION);
        vm.warp(vm.getBlockTimestamp() + 1);

        ledger = new ExposureLedger(ledgerOwner, address(swood), EPOCH_LENGTH);
        feed = new SlashGasFeed(1e8, 8);
        // Design revision 2: `woodUsdPriceX8` is a CAP, never a price. WOOD is
        // valued from the WOOD/USD feed at $0.05, with the cap 2x ABOVE it and
        // therefore NOT binding — the configuration production ships.
        MockAggregatorV3 woodFeed = new MockAggregatorV3(8, 0.05e8);
        vm.startPrank(ledgerOwner);
        ledger.setWoodUsdPrice(0.1e8);
        // The mock publishes one round at construction and these suites warp far
        // past it; staleness is exercised in test/ExposureLedger.t.sol.
        ledger.setWoodFeed(address(woodFeed), type(uint64).max);
        ledger.setAssetFeed(address(usdg), address(feed), 365 days);
        ledger.setCoveredTvlCapUsd(10_000_000e18);
        ledger.setGuardianRegistry(address(registry));
        vm.stopPrank();
        vm.prank(owner);
        registry.setExposureLedger(address(ledger));

        bondEscrow = new ProposerBondEscrow(address(wood), address(registry), address(ledger));

        game = new ChallengeGame(owner, address(wood), address(ledger), address(tierRegistry));
        court = new TokenCourt(owner);
        vm.prank(ledgerOwner);
        ledger.setCoverageFreezer(address(game));
        tierRegistry.setAuthorizedDemoter(address(game));
        vm.startPrank(owner);
        swood.setAuthorizedSlasher(address(game));
        game.setStakedWood(address(swood));
        court.setChallengeGame(address(game));
        court.setStakedWood(address(swood));
        game.setCourt(address(court));
        vm.stopPrank();

        gov.setExposureLedger(address(ledger));
        gov.setBondEscrow(address(bondEscrow));
        gov.setTierRegistry(address(tierRegistry));

        // Two-step certification (design.md / tasks.md 2.1): the test contract
        // IS the registry owner, so no prank is needed — propose, warp past
        // the pinned `readyAt` (`vm.getBlockTimestamp()`, never a cached
        // `block.timestamp` local — the optimizer CSEs it across `vm.warp`),
        // execute. Every later warp in this suite is relative
        // (`vm.getBlockTimestamp() + X` or a live `gov.getProposal(...)`
        // field), so this setUp-time shift is safe.
        tierRegistry.proposeCertification(
            address(adapter), adapter.poke.selector, 1, CERTIFIED_BOUND_BPS, address(0), address(adapter).codehash
        );
        vm.warp(vm.getBlockTimestamp() + tierRegistry.certifyDelay());
        tierRegistry.certify(address(adapter), adapter.poke.selector);
        // issue #166: certifying a (target, selector) prices it for tiering
        // but does NOT make `target` batch-callable at all — that is the
        // SEPARATE `isAdapterAllowed` allowlist `SyndicateVault._guardBatchCalls`
        // PART 2a now enforces on every batch callee. `adapter` (`SlashGasAdapter`)
        // is a benign, fund-neutral fixture, not an attacker probe — allowlist
        // it or every proposal touching it is refused with
        // `DisallowedBatchCallee` before the gas-ceiling mechanics under test
        // ever run. Inherited by `DemotionGasProbeTest` (`is SlashGasCeilingTest`).
        tierRegistry.setAdapterAllowed(address(adapter), true);

        wood.mint(agent, 1_000_000e18);
        vm.prank(agent);
        wood.approve(address(bondEscrow), type(uint256).max);
        wood.mint(challenger, 1_000_000e18);
        vm.prank(challenger);
        wood.approve(address(game), type(uint256).max);

        _deposit(lp1, LP1_ASSETS);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
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

    /// @dev propose -> review opens -> the WHOLE cohort approves (each booking
    ///      its own reservation, so every one of them carries a real, non-zero
    ///      slash rate) -> execute.
    function _proposeApproveExecute() internal returns (uint256 pid) {
        vm.prank(agent);
        pid = gov.propose(
            address(vault),
            address(0),
            "ipfs://slash-gas-ceiling",
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

        vm.warp(gov.getProposal(pid).voteEnd + 1);
        registry.openReview(address(gov), pid);
        for (uint256 i = 0; i < approvers.length; i++) {
            vm.prank(approvers[i]);
            registry.voteOnProposal(address(gov), pid, IGuardianRegistry.GuardianVoteType.Approve, type(uint256).max);
        }

        vm.warp(gov.getProposal(pid).reviewEnd + 1);
        gov.executeProposal(pid);
        assertEq(
            uint256(gov.getProposal(pid).state), uint256(ISyndicateGovernor.ProposalState.Executed), "drain executed"
        );
    }

    /// @dev File a challenge and escalate it, so the terminal path runs through
    ///      the court — the DEEPEST route to `_settle`, and the one the finding
    ///      is about. The disputer is one of the ACCUSED, which is what makes
    ///      `_settle`'s per-approver work run over the approver array and hands
    ///      `slashToEscrow` a non-zero `bountyBps`: the gas-hungriest settle
    ///      there is.
    function _fileDisputeRefer(uint256 pid) internal returns (uint256 cid, uint256 caseId) {
        vm.prank(challenger);
        cid = game.file(
            address(gov),
            pid,
            IChallengeGame.Predicate.OutOfAdapterOutflow,
            address(adapter),
            adapter.poke.selector,
            "ipfs://evidence"
        );

        // Hoisted out of argument position: the read below would otherwise
        // consume the prank meant for `dispute`.
        uint256 bond = game.challengeOf(cid).bondWood;
        address defender = approvers[0];
        wood.mint(defender, bond);
        vm.startPrank(defender);
        wood.approve(address(game), type(uint256).max);
        game.dispute(cid, type(uint256).max);
        vm.stopPrank();
        assertEq(
            uint256(game.challengeOf(cid).status), uint256(IChallengeGame.Status.Disputed), "escalated to the court"
        );

        caseId = court.caseOfChallenge(address(game), cid);
        assertGt(caseId, 0, "dispute auto-referred the case");
    }

    /// @dev The jurors convict, then the vote window closes. Leaves the case
    ///      exactly one `finalize` away from a full-cap conviction.
    function _convictAndCloseTheWindow(uint256 caseId) internal {
        vm.prank(juror1);
        court.vote(caseId, true);
        vm.prank(juror2);
        court.vote(caseId, true);
        vm.warp(vm.getBlockTimestamp() + court.voteWindow());
    }

    // ── 1. The CI gate ────────────────────────────────────────────────────

    /// @notice THE REGRESSION GATE (H2). Whatever the constants are, a
    ///         conviction at the registry's own approver cap has to be
    ///         expressible as a transaction on the chain this protocol deploys
    ///         to.
    ///
    /// @dev    Deliberately arithmetic and deliberately cheap: this is the line
    ///         that fails in CI the moment somebody raises
    ///         `SLASH_GAS_PER_APPROVER`, raises `MAX_APPROVERS_PER_PROPOSAL`, or
    ///         moves the protocol to a chain with a tighter per-tx cap — without
    ///         anyone having to run the (very heavy) full-cap fixture below. The
    ///         execution proof is
    ///         `test_fullCapConviction_fitsInAMinableTransaction`; this is the
    ///         tripwire in front of it.
    ///
    ///         The haircut is `(63/64)^3` against a VERIFIED depth of two frames
    ///         (see the contract-level note and
    ///         `test_theGasFloorSitsTwoExternalFramesBelowAnEoa`). The third factor is
    ///         not superstition — it is the budget reserved for everything the
    ///         floor does NOT cover but the same 32M still has to pay for: the
    ///         intrinsic transaction cost, `finalize`'s vote-tally prelude, and
    ///         `_settle`'s pre-check work, which reads the ledger's rate for all
    ///         100 approvers BEFORE `gasleft()` is ever consulted.
    function test_slashGasFloorFitsRobinhoodMaxTxGas() public {
        _deployStack(0); // the gate needs the constants, not a cohort

        // Worst case is an adapter-naming settle (issue #51,
        // openspec settle-demotion-gas-floor): it owes DEMOTION_GAS on top of
        // the slash terms. A zero-adapter filing's floor is strictly smaller,
        // so the adapter-naming total is the binding case for this gate.
        uint256 cap = registry.MAX_APPROVERS_PER_PROPOSAL();
        uint256 floor = cap * game.SLASH_GAS_PER_APPROVER() + game.SLASH_GAS_BASE() + game.DEMOTION_GAS();

        // 32,000,000 * 63^3 / 64^3, integer-exact.
        uint256 ceiling = (MAX_TX_GAS * 63 * 63 * 63) / (64 * 64 * 64);

        emit log_named_uint("MAX_APPROVERS_PER_PROPOSAL", cap);
        emit log_named_uint("SLASH_GAS_PER_APPROVER", game.SLASH_GAS_PER_APPROVER());
        emit log_named_uint("SLASH_GAS_BASE", game.SLASH_GAS_BASE());
        emit log_named_uint("DEMOTION_GAS", game.DEMOTION_GAS());
        emit log_named_uint("full-cap slash gas floor (adapter-naming)", floor);
        emit log_named_uint("32M after (63/64)^3", ceiling);

        assertLt(floor, ceiling, "a full-cap conviction must fit inside one Robinhood transaction");
    }

    /// @notice The call depth the haircut is derived from, PINNED to the three
    ///         facts that produce it rather than asserted as a number.
    ///
    ///         The path an EOA takes to the `gasleft()` check is
    ///
    ///           1. EOA      -> TokenCourt.finalize     (the transaction itself)
    ///           2. finalize -> ChallengeGame.rule      <- gasleft() read here
    ///                          _settle                 (private: same frame)
    ///
    ///         so TWO `CALL`s, and the reachable ceiling inside frame 2 is
    ///         `(63/64)^2` of the transaction's budget — not `(63/64)^3`.
    ///
    /// @dev    WHAT WOULD MAKE THIS WRONG, and what this test therefore checks:
    ///
    ///         (a) A PROXY anywhere on the path. A `delegatecall` hop is subject
    ///             to the same 63/64 rule as a `CALL`, so putting either contract
    ///             behind ERC-1967 silently adds a haircut. Checked by reading
    ///             the implementation slot of both — and, as a positive control
    ///             that the check can actually see a proxy, of `StakedWood`,
    ///             which IS one.
    ///         (b) A ROUTER between them — `finalize` reaching `rule` through
    ///             anything other than a direct call. Checked by pinning the two
    ///             wiring pointers to each other.
    ///         (c) `_settle` becoming external/public. Not observable at runtime;
    ///             it is `private` in `ChallengeGame` and the natspec above the
    ///             constants records the dependency.
    ///
    ///         The gate above deliberately uses the STRICTER `(63/64)^3`
    ///         regardless, so the verified depth being two leaves a whole
    ///         haircut in reserve for the intrinsic cost, `finalize`'s prelude
    ///         and `_settle`'s pre-check work. This test's job is to make a
    ///         change in depth loud rather than silent.
    function test_theGasFloorSitsTwoExternalFramesBelowAnEoa() public {
        _deployStack(0);

        // (a) Neither contract on the path is proxied.
        assertEq(_implementationSlot(address(court)), address(0), "TokenCourt must not be proxied");
        assertEq(_implementationSlot(address(game)), address(0), "ChallengeGame must not be proxied");
        // ...and the same read DOES see a proxy, so a zero above means something.
        assertTrue(_implementationSlot(address(swood)) != address(0), "positive control: StakedWood is behind ERC-1967");

        // (b) `finalize` calls the game directly, and `rule` accepts only the court.
        assertEq(court.challengeGame(), address(game), "finalize calls the game with no router in between");
        assertEq(game.court(), address(court), "and rule's only permitted caller is that court");

        // The gate is conservative by construction: three haircuts reserve
        // strictly less than the two the verified depth actually spends.
        uint256 gateCeiling = (MAX_TX_GAS * 63 * 63 * 63) / (64 * 64 * 64);
        uint256 reachableAtVerifiedDepth = (MAX_TX_GAS * 63 * 63) / (64 * 64);
        assertLt(gateCeiling, reachableAtVerifiedDepth, "the (63/64)^3 gate under-claims what depth 2 can reach");
    }

    /// @dev The ERC-1967 implementation slot,
    ///      `bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1)`.
    ///      Zero for a plain contract, non-zero for a proxy.
    function _implementationSlot(address who) internal view returns (address) {
        bytes32 slot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        return address(uint160(uint256(vm.load(who, slot))));
    }

    // ── 2. The execution proof ────────────────────────────────────────────

    /// @notice H2's regression test. A conviction against the FULL approver cap,
    ///         through the deepest path there is (court `finalize` -> `rule` ->
    ///         `_settle` -> `slashToEscrow`), executed with the gas an actual
    ///         Robinhood transaction can carry — and nothing more.
    ///
    /// @dev    NOT AN ARITHMETIC ASSERTION. The budget handed to frame 0 is
    ///         `MAX_TX_GAS - INTRINSIC_TX_GAS`, i.e. exactly what a
    ///         `finalize(uint256)` transaction submitted at the chain's per-tx
    ///         ceiling leaves for execution; the two EIP-150 haircuts then happen
    ///         for real inside the EVM rather than being multiplied out on paper.
    ///         At the OLD constants (300k / 1M) this call reverts
    ///         `InsufficientSlashGas`.
    ///
    ///         `finalize` BUBBLES everything except `WrongStatus`, so a starved
    ///         `rule` surfaces here as `ok == false` rather than as a silently
    ///         swallowed verdict — which is exactly why the finding is a
    ///         denial-of-conviction and not merely a wasted transaction.
    function test_fullCapConviction_fitsInAMinableTransaction() public {
        _deployStack(100);
        assertEq(approvers.length, registry.MAX_APPROVERS_PER_PROPOSAL(), "the cohort really is at the cap");

        uint256 pid = _proposeApproveExecute();
        (uint256 cid, uint256 caseId) = _fileDisputeRefer(pid);

        // Every one of the 100 carries a real, non-zero rate: this is the
        // EXPENSIVE case (100 actual `_slashOne` writes), not the cheap
        // dust-approver padding the attack uses. The floor has to cover this one.
        (, uint256[] memory bps) = ledger.slashBpsFor(address(gov), pid);
        assertEq(bps.length, 100, "the ledger lists the whole cohort");
        for (uint256 i = 0; i < bps.length; i++) {
            assertGt(bps[i], 0, "every approver is really slashed, so this is the worst case");
        }

        _convictAndCloseTheWindow(caseId);

        uint256 stakeBefore = swood.guardianStake(approvers[7]);

        // The adapter this filing named is certified GOING IN, so its tier
        // after the conviction is a real signal rather than a tautology.
        (uint8 tierBefore,) = tierRegistry.tierOf(address(adapter), adapter.poke.selector);
        assertEq(tierBefore, 1, "the challenged adapter is certified before the conviction");
        vm.recordLogs();

        // THE BUDGET A REAL TRANSACTION HAS. Frame 0 is entered by the
        // transaction itself (no 63/64 haircut on that hop); every haircut below
        // it is the EVM's own.
        uint256 frameZeroGas = MAX_TX_GAS - INTRINSIC_TX_GAS;
        uint256 before = gasleft();
        (bool ok,) = address(court).call{gas: frameZeroGas}(abi.encodeCall(TokenCourt.finalize, (caseId)));
        uint256 spent = before - gasleft();

        emit log_named_uint("full-cap conviction gas (frame 0 and below)", spent);
        emit log_named_uint("frame-0 budget", frameZeroGas);

        assertTrue(ok, "a full-cap conviction must be minable at maxTxGasLimit");
        assertLt(spent, frameZeroGas, "and must not merely have consumed the whole budget");

        // The verdict actually landed — not swallowed, not timed out into an
        // acquittal.
        assertEq(uint256(game.challengeOf(cid).status), uint256(IChallengeGame.Status.Settled), "Settled, not Failed");
        assertEq(uint256(court.caseOf(caseId).verdict), uint256(IChallengeGame.Verdict.Guilty), "Guilty");
        assertLt(swood.guardianStake(approvers[7]), stakeBefore, "the cohort really was slashed");
        // The proceeds were destroyed, not routed: there is no case to open.
        assertEq(swood.pendingBurn(), 0, "and the burn landed rather than parking for a flush retry");

        // AND THE DEMOTION LANDED — the assertion this test was missing.
        // This is the only test that drives a full-cap, adapter-naming
        // conviction through the real call depth at the real worst-case
        // budget, which is the exact condition `DEMOTION_GAS` exists for. But
        // `_settle` swallows a failed demotion in a bare catch, so without
        // this check a future regression that re-narrows the margin at
        // precisely this boundary would leave the test green: the verdict
        // would still settle, the cohort would still be slashed, and the
        // challenged adapter would quietly keep its certification.
        //
        // The TIER is the binding check — it is the invariant that matters
        // and it survives any renaming of the event below.
        (uint8 tierAfter,) = tierRegistry.tierOf(address(adapter), adapter.poke.selector);
        assertEq(tierAfter, tierRegistry.TIER_ARBITRARY(), "the challenged adapter really lost its certification");

        // The event absence is the explicit form of the same claim: the
        // demotion did not merely fail into the catch.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(
                logs[i].topics[0] != keccak256("AdapterDemotionFailed(uint256,address,bytes4)"),
                "the demotion must not have been swallowed by the bare catch"
            );
        }
    }

    // ── 3. The measurement the constants are set from ─────────────────────

    /// @notice What one approver ACTUALLY costs the settle path, measured across
    ///         cohort sizes rather than assumed. This is the evidence behind
    ///         `SLASH_GAS_PER_APPROVER`: the constant has to sit ABOVE the true
    ///         marginal cost (it is a floor that must cover the work) and far
    ///         enough below `32M / MAX_APPROVERS` for the gate above to pass.
    ///
    /// @dev    Measures the whole `finalize` transaction, which is strictly MORE
    ///         than the floor is responsible for: the floor covers only what
    ///         happens AFTER the `gasleft()` check, while this also pays for
    ///         `finalize`'s prelude and `_settle`'s pre-check ledger read. Using
    ///         the larger number to size the floor is the conservative direction.
    ///
    ///         Every approver here carries a real non-zero rate, so each one is a
    ///         genuine `_slashOne` — two checkpoint pushes, a stake write, a
    ///         persistent-dedup write and an event — plus its share of
    ///         `slashToEscrow`'s O(n^2) pairwise duplicate scan. The dust
    ///         approvers of the padding attack are strictly cheaper (skipped at
    ///         `requested == 0`), which is why the floor is sized against this
    ///         path and not that one.
    ///
    ///         WHAT THESE MEASURED, on the commit that set the constants:
    ///
    ///             4 approvers      713,853
    ///            52 approvers    5,428,313
    ///           100 approvers   11,176,224
    ///
    ///         fitting `~224*n^2 + 85,659*n + 367,629` — a ~368k fixed base,
    ///         ~86k linear per approver, and ~224 gas per pair for the O(n²)
    ///         dedup (2.24M of the 11.18M at the cap). Average per approver at
    ///         the cap ~108k; marginal cost of the hundredth ~130k. That is what
    ///         `SLASH_GAS_PER_APPROVER = 180_000` is 1.4x of, and what the old
    ///         300_000 was 2.3-3.5x of.
    ///
    ///         These three are logging tests, not thresholds: the assertion that
    ///         binds is `test_theFloorExceedsWhatAFullCapConvictionSpends`, which
    ///         brackets the same measurement from the side that matters.
    function test_measure_convictionGas_at4Approvers() public {
        emit log_named_uint("conviction gas @ 4 approvers", _measureConvictionGas(4));
    }

    function test_measure_convictionGas_at52Approvers() public {
        emit log_named_uint("conviction gas @ 52 approvers", _measureConvictionGas(52));
    }

    /// @notice The floor genuinely over-covers the work it guards, at the cap.
    ///         If this ever inverts, `SLASH_GAS_PER_APPROVER` has stopped being a
    ///         safety margin and started being a lie — and the burn-vs-bubble
    ///         classifier in `StakedWood` that the floor exists to protect loses
    ///         its guarantee.
    function test_theFloorExceedsWhatAFullCapConvictionSpends() public {
        // `_measureConvictionGas` runs through `_fileDisputeRefer`, which
        // names a real adapter — the measured spend already includes the
        // demotion, so the floor it is compared against must include
        // DEMOTION_GAS too (issue #51, openspec settle-demotion-gas-floor).
        uint256 spent = _measureConvictionGas(100);
        uint256 floor = uint256(100) * game.SLASH_GAS_PER_APPROVER() + game.SLASH_GAS_BASE() + game.DEMOTION_GAS();
        emit log_named_uint("full-cap conviction gas", spent);
        emit log_named_uint("full-cap gas floor (adapter-naming)", floor);
        assertLt(spent, floor, "the floor must reserve more than the conviction actually spends");
    }

    // ── 4. The demotion-cost bracketing (issue #51) ────────────────────────

    /// @notice Task 2.4 (openspec settle-demotion-gas-floor). `DEMOTION_GAS`'s
    ///         natspec estimates the worst-case `demoteByChallenge` frame at
    ///         ~45-50k; this anchors that to a real measurement against the
    ///         real `TierRegistry` rather than trusting the estimate.
    ///
    /// @dev    Measures the WORST-CASE demotion, not the fixture's default
    ///         zero-bond one: `_deployStack`'s `certify` call passes
    ///         `submitter = address(0)`, which skips the submitter-bond
    ///         machinery entirely. This test re-certifies the same
    ///         (target, selector) with a real, funded submitter bond first, so
    ///         `_demote`'s conditional bond-release branch — the
    ///         `releasableAt` SSTORE from zero to non-zero, plus
    ///         `SubmitterBondReleaseStarted` — actually runs, matching the
    ///         sizing note's worst-case accounting.
    ///
    ///         Measured directly against `demoteByChallenge`, pranked as the
    ///         registry's `authorizedDemoter` (the game, per `_deployStack`),
    ///         rather than through a full `_settle` — isolating the child's
    ///         own cost from the slash and payout work around it, which is
    ///         what `DEMOTION_GAS` actually reserves gas for.
    function test_demotionGas_fitsInsideTheReservedStipend() public {
        _deployStack(0);

        // `_deployStack` constructs `tierRegistry = new TierRegistry(address(this))`
        // — the test contract itself is the owner, not the `owner` fixture
        // address used for the rest of the stack. No prank needed here.
        address submitter = makeAddr("demotionGasSubmitter");
        wood.mint(submitter, 10_000e18);
        tierRegistry.setWood(address(wood));
        tierRegistry.setSubmitterBondWood(10_000e18);
        tierRegistry.setBondReleaseDelay(14 days);
        vm.prank(submitter);
        wood.approve(address(tierRegistry), type(uint256).max);
        // Re-certify the fixture's adapter with a real bond so the demotion
        // below actually starts the bond-release timelock — the worst case.
        // Two-step flow (issue #45): propose (with the reviewed codehash),
        // warp past the pinned readyAt, then execute pranked as the pinned
        // submitter (PR #156 finding #3: execution is submitter-gated once a
        // bond is pinned).
        tierRegistry.proposeCertification(
            address(adapter), adapter.poke.selector, 1, CERTIFIED_BOUND_BPS, submitter, address(adapter).codehash
        );
        vm.warp(vm.getBlockTimestamp() + tierRegistry.certifyDelay());
        vm.prank(submitter);
        tierRegistry.certify(address(adapter), adapter.poke.selector);

        uint256 forwarded = (game.DEMOTION_GAS() * 63) / 64;

        vm.prank(address(game));
        uint256 before = gasleft();
        tierRegistry.demoteByChallenge(address(adapter), adapter.poke.selector);
        uint256 spent = before - gasleft();

        emit log_named_uint("measured demoteByChallenge gas (worst case, real bond release)", spent);
        emit log_named_uint("DEMOTION_GAS * 63/64 (the stipend a starved-to-the-floor caller forwards)", forwarded);
        emit log_named_uint("headroom left for issue #77's extra delete", forwarded - spent);

        assertLt(spent, forwarded, "DEMOTION_GAS must reserve more than a real demotion actually spends");
    }

    function _measureConvictionGas(uint256 n) internal returns (uint256 spent) {
        _deployStack(n);
        uint256 pid = _proposeApproveExecute();
        (, uint256 caseId) = _fileDisputeRefer(pid);
        _convictAndCloseTheWindow(caseId);

        uint256 before = gasleft();
        (bool ok,) =
            address(court).call{gas: MAX_TX_GAS - INTRINSIC_TX_GAS}(abi.encodeCall(TokenCourt.finalize, (caseId)));
        spent = before - gasleft();
        assertTrue(ok, "the measurement must be of a conviction that landed");
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
}
