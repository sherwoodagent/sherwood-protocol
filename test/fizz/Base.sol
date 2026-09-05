// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Actor} from "./Actor.sol";
import {Clamp} from "./utils/Clamp.sol";
import {DecimalPrinter} from "./utils/DecimalPrinter.sol";
import {Deployer} from "./utils/Deployer.sol";
import {vm} from "./utils/Hevm.sol";
import {Logger} from "./utils/Logger.sol";
import {Math} from "./utils/Math.sol";
import {StringUtils} from "./utils/StringUtils.sol";
import {EnumerableSet} from "./utils/EnumerableSet.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {FizzFactory} from "./utils/FizzFactory.sol";
import {FizzAdapter} from "./utils/FizzAdapter.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {SyndicateGovernor} from "../../src/SyndicateGovernor.sol";
import {GuardianRegistry} from "../../src/GuardianRegistry.sol";
import {StakedWood} from "../../src/StakedWood.sol";
import {ExposureLedger} from "../../src/ExposureLedger.sol";
import {ChallengeGame} from "../../src/ChallengeGame.sol";
import {TokenCourt} from "../../src/TokenCourt.sol";
import {TierRegistry} from "../../src/TierRegistry.sol";
import {ProposerBondEscrow} from "../../src/ProposerBondEscrow.sol";
import {ProtocolConfig} from "../../src/ProtocolConfig.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {VaultWithdrawalQueue} from "../../src/queue/VaultWithdrawalQueue.sol";
import {ISyndicateVault} from "../../src/interfaces/ISyndicateVault.sol";
import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";

import {MockAgentRegistry} from "../mocks/MockAgentRegistry.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";
import {deployTierRegistry} from "../helpers/TierRegistryFixture.sol";

/// @notice Base contract with state variables and setup functions.
///
/// @dev `SyndicateFactory` is deliberately not deployed — its only role in the
///      fuzzed surface is one-shot deployment and wiring. A minimal
///      `FizzFactory` stands in for it instead.
///
///      The harness canNOT be its own factory, even though that is what the
///      equivalent unit-test fixtures do. Under Medusa and Echidna `setup()`
///      runs inside `FuzzTester`'s CONSTRUCTOR, so `address(this).code.length`
///      is zero throughout; `SyndicateVault._getGovernor()` resolves the
///      governor via an external `factory.governorOf(vault)` call that every
///      deposit reaches, and calling into a still-constructing contract
///      reverts. Foundry hides this because `setUp()` runs post-deployment.
///      `SyndicateVault.initialize` additionally records `_factory =
///      msg.sender`, so the vault proxy is deployed BY `FizzFactory`.
///      (`vm.mockCall`, which the unit fixtures use for `governorOf`, is
///      supported by neither fuzzer.)
///
///      Deployment order otherwise mirrors `test/TokenCourtEndToEnd.t.sol::setUp`,
///      the most complete non-fork stack in the repo. The circular
///      sWOOD ↔ registry dependency is resolved the same way it is there:
///      sWOOD takes the factory at init, and `setRegistry` closes the loop.
abstract contract Base is StringUtils, Clamp, Deployer, Math {
    using DecimalPrinter for uint256;

    string[] internal ACTOR_LABELS = ["Alice", "Bob", "Charlie", "Dave", "Erin", "Frank"];
    uint256 internal constant BLOCK_INTERVAL = 12 seconds;
    uint256 internal constant INITIAL_ETH_BALANCE = 1_000 ether;

    // ―――――――――――――――――――――――― Parameters ―――――――――――――――――――――――――
    // Chosen to satisfy every cross-contract window invariant simultaneously:
    //   X-1  ledger.challengeWindow (14d default) >= REVIEW_PERIOD + 7d
    //   X-4  swood.coolDownPeriod                 >= REVIEW_PERIOD
    //   X-2  autoSlashDelay + voteWindow + FINALIZE_BUFFER + MIN_REFERRAL_SLACK
    //                                             <= disputeTimeout
    //   X-3  participationFloorBps                <  ageFloorBps
    // The game/court defaults (7d / 5d / 30d, and 1000 < 2500 bps) already
    // satisfy X-2 and X-3, so only the two below need pinning here.

    uint256 internal constant MIN_GUARDIAN_STAKE = 10_000e18;
    uint256 internal constant MIN_OWNER_STAKE = 10_000e18;
    uint256 internal constant COOL_DOWN = 7 days;
    uint256 internal constant REVIEW_PERIOD = 24 hours;
    uint256 internal constant BLOCK_QUORUM_BPS = 3_000;
    uint256 internal constant MATURATION = 30 days;
    uint256 internal constant EPOCH_LENGTH = 7 days;

    uint256 internal constant VOTING_PERIOD = 1 days;
    uint256 internal constant EXECUTION_WINDOW = 1 days;
    uint256 internal constant MIN_STRATEGY_DURATION = 1 hours;
    uint256 internal constant MAX_STRATEGY_DURATION = 30 days;

    uint8 internal constant ASSET_DECIMALS = 6;
    uint256 internal constant INITIAL_ASSET_BALANCE = 1_000_000e6;
    uint256 internal constant INITIAL_WOOD_BALANCE = 5_000_000e18;
    uint256 internal constant SEED_DEPOSIT = 100_000e6;

    // ―――――――――――――――――――――――――― Ghosts ――――――――――――――――――――――――――

    /// @dev Backing state for GL-NN global properties in `Properties.sol`.
    ///      Most fields are SELF-MAINTAINED entirely inside their own
    ///      `property_*` function (read on-chain state, compare to the ghost,
    ///      overwrite the ghost) and need no handler wiring at all. The two
    ///      fields explicitly called out below are the exception: they record
    ///      information a `bondOf` read can never recover after the fact
    ///      (WHICH exit a bond took), so a handler must set them.
    struct Ghosts {
        // GL-23: proposalId => last observed `ProposalState` (uint8 cast).
        // A terminal state (Settled/Cancelled/Expired/Rejected) must never
        // change again.
        mapping(uint256 => uint8) lastProposalState;
        // GL-26: challengeId => last observed `Status` (uint8 cast). A
        // terminal status (Failed/Settled/Inconclusive) must never change.
        mapping(uint256 => uint8) lastChallengeStatus;
        // GL-30: caseId => last observed `Phase` (uint8 cast). `Resolved`
        // must never change back to `Voting`.
        mapping(uint256 => uint8) lastCasePhase;
        // GL-31: caseId => voter => last observed `Ruling` (uint8 cast).
        // Once non-`None`, NatSpec says "NO VOTE CHANGES".
        mapping(uint256 => mapping(address => uint8)) lastVoteOf;
        // GL-34: requestId => whether `claimed` / `cancelled` has EVER been
        // observed true (each is a one-shot latch).
        mapping(uint256 => bool) everClaimed;
        mapping(uint256 => bool) everCancelled;
        // GL-36 — REQUIRES HANDLER WIRING. keccak256(abi.encode(governor,
        // proposalId)) => whether that bond has ever been released /
        // forfeited. `bondOf` reads 0 after EITHER exit, so state alone
        // cannot prove only one was taken; `ProposerBondEscrowHandler` must
        // set the matching flag to `true` immediately after a successful
        // `releaseBond` / `forfeitBond` call so `property_GL36_*` can catch a
        // bond that took both exits.
        mapping(bytes32 => bool) bondReleased;
        mapping(bytes32 => bool) bondForfeited;
        // GL-25: proposalId => last observed `executedAt`. A one-shot latch:
        // once non-zero it must never change, or a challenge's slash basis
        // could be moved out from under it after the fact.
        mapping(uint256 => uint256) lastExecutedAt;
        // GL-32: challengeId => last observed caseId. Set once; a second
        // referral would give one challenge two adjudications.
        mapping(uint256 => uint256) lastCaseOfChallenge;
        // GL-33: caseId => account => whether `isAccused` was EVER observed
        // true. Clearing it mid-case would let an approver vote on their own
        // conviction.
        mapping(uint256 => mapping(address => bool)) everAccused;
        // GL-35: pid => whether the settle price was EVER observed stamped.
        // Re-stamping would re-price already-settled redemptions.
        mapping(uint256 => bool) everStamped;
        // GL-37: reviewKey => whether opened/resolved were EVER observed true.
        mapping(bytes32 => bool) everOpened;
        mapping(bytes32 => bool) everResolved;
        // GL-39: last observed value of each monotonic counter.
        uint256 lastProposalCount;
        uint256 lastChallengeCount;
        uint256 lastCaseCount;
        uint256 lastNextRequestId;
        // GL-40: reviewKey (keccak256(abi.encode(governor, proposalId))) =>
        // last observed `challengeableUntil[key]`.
        mapping(bytes32 => uint256) lastChallengeableUntil;
        // GL-42: last observed `vault.highWaterPricePerShare()`.
        uint256 lastHighWaterPricePerShare;
    }

    Ghosts internal ghosts;

    // ―――――――――――――――――――――――――― Actors ――――――――――――――――――――――――――

    address[] internal actors;
    address internal actor;
    address internal admin;

    /// @dev Guardians are a fixed prefix of `actors` so the court always has a
    ///      non-accused electorate: TokenCourt bars both the accused and the
    ///      challenger from voting, so with fewer than three staked guardians
    ///      a conviction could never clear the participation floor (I-20).
    uint256 internal constant GUARDIAN_COUNT = 3;
    /// @dev Guardians that approve a proposal, leaving `GUARDIAN_COUNT -
    ///      APPROVER_COUNT` staked but unaccused. The reserve exists because
    ///      TokenCourt bars approvers (`isAccused`) from voting: with every
    ///      guardian approving there is no eligible electorate, turnout is zero
    ///      and a disputed challenge can never reach a verdict.
    uint256 internal constant APPROVER_COUNT = GUARDIAN_COUNT - 1;

    modifier asActor() virtual {
        vm.startPrank(actor);
        _;
        vm.stopPrank();
    }

    modifier asAdmin() virtual {
        vm.startPrank(admin);
        _;
        vm.stopPrank();
    }

    // ―――――――――――――――――――――――― Contracts ―――――――――――――――――――――――――

    MockERC20 internal asset;
    MockERC20 internal wood;

    BatchExecutorLib internal executorLib;
    ProtocolConfig internal protocolConfig;
    TierRegistry internal tierRegistry;
    StakedWood internal swood;
    GuardianRegistry internal registry;
    SyndicateVault internal vault;
    SyndicateGovernor internal governor;
    VaultWithdrawalQueue internal queue;
    ExposureLedger internal ledger;
    ProposerBondEscrow internal bondEscrow;
    ChallengeGame internal game;
    TokenCourt internal court;

    MockAgentRegistry internal agentRegistry;
    MockAggregatorV3 internal assetFeed;
    MockAggregatorV3 internal woodFeed;
    FizzFactory internal fizzFactory;
    FizzAdapter internal adapter;

    // ―――――――――――――――――――――――――― Setup ―――――――――――――――――――――――――――

    function setup() internal {
        _deployTokensAndMocks();
        _deployStakingAndRegistry();
        _deployVaultAndGovernor();
        setupActors();
        _stakeGuardians();
        _deployCoverageAndAdjudication();
        _wireRoles();
        _certifyAdapter();
        _seedVault();
    }

    function _deployTokensAndMocks() internal {
        asset = new MockERC20(address(this), 0, "Sherwood Asset", "sASSET", ASSET_DECIMALS);
        wood = new MockERC20(address(this), 0, "Sherwood", "WOOD", 18);

        executorLib = new BatchExecutorLib();
        agentRegistry = new MockAgentRegistry();
        protocolConfig = new ProtocolConfig(address(this));
        tierRegistry = new TierRegistry(address(this));
        fizzFactory = new FizzFactory();
        adapter = new FizzAdapter();

        // $1.00, 8-decimal asset feed.
        assetFeed = new MockAggregatorV3(8, 1e8);
        // WOOD at $0.05 from the market source, with the governance cap set
        // ABOVE it at $0.10 so `min(oracle, governance)` resolves to the
        // oracle — the configuration production ships (see X-7).
        woodFeed = new MockAggregatorV3(8, 0.05e8);
    }

    function _deployStakingAndRegistry() internal {
        StakedWood swoodImpl = new StakedWood();
        swood = StakedWood(
            address(
                new ERC1967Proxy(
                    address(swoodImpl),
                    abi.encodeCall(
                        StakedWood.initialize,
                        (StakedWood.InitParams({
                                owner: address(this),
                                wood: address(wood),
                                factory: address(fizzFactory),
                                minGuardianStake: MIN_GUARDIAN_STAKE,
                                coolDownPeriod: COOL_DOWN,
                                minOwnerStake: MIN_OWNER_STAKE,
                                minSlashBps: 1_000,
                                maxSlashBps: 10_000,
                                ageFloorBps: 2_500,
                                maturationPeriod: MATURATION
                            }))
                    )
                )
            )
        );

        GuardianRegistry regImpl = new GuardianRegistry(6 hours);
        registry = GuardianRegistry(
            address(
                new ERC1967Proxy(
                    address(regImpl),
                    abi.encodeCall(
                        GuardianRegistry.initialize,
                        (address(this), address(fizzFactory), address(swood), REVIEW_PERIOD, BLOCK_QUORUM_BPS)
                    )
                )
            )
        );

        // Closes the sWOOD ↔ registry cycle (one-shot latch, G-29).
        swood.setRegistry(address(registry));
    }

    function _deployVaultAndGovernor() internal {
        // Both proxies are deployed THROUGH `fizzFactory`: `SyndicateVault`
        // records `_factory = msg.sender` at initialize, and every
        // `onlyFactory` / `_getGovernor()` path afterwards resolves against
        // that address.
        SyndicateVault vaultImpl = new SyndicateVault();
        vault = SyndicateVault(
            payable(fizzFactory.deployProxy(
                    address(vaultImpl),
                    abi.encodeCall(
                        SyndicateVault.initialize,
                        (ISyndicateVault.InitParams({
                                asset: address(asset),
                                name: "Sherwood Fuzz Vault",
                                symbol: "fzASSET",
                                owner: address(this),
                                executorImpl: address(executorLib),
                                openDeposits: true,
                                agentRegistry: address(agentRegistry),
                                managementFeeBps: 0
                            }))
                    )
                ))
        );

        SyndicateGovernor govImpl = new SyndicateGovernor(24 hours, 1 hours);
        governor = SyndicateGovernor(
            fizzFactory.deployProxy(
                address(govImpl),
                abi.encodeCall(
                    SyndicateGovernor.initialize,
                    (
                        address(vault),
                        address(registry),
                        address(protocolConfig),
                        address(fizzFactory),
                        address(deployTierRegistry(address(this))),
                        ISyndicateGovernor.GovernorParams({
                            votingPeriod: VOTING_PERIOD,
                            executionWindow: EXECUTION_WINDOW,
                            vetoThresholdBps: 4_000,
                            maxPerformanceFeeBps: 1_500,
                            cooldownPeriod: 1 days,
                            collaborationWindow: 48 hours,
                            maxCoProposers: 5,
                            minStrategyDuration: MIN_STRATEGY_DURATION,
                            maxStrategyDuration: MAX_STRATEGY_DURATION
                        })
                    )
                )
            )
        );

        // The lookup `SyndicateVault._getGovernor()` and
        // `StakedWood.requestUnstakeOwner` both depend on.
        fizzFactory.setGovernor(address(vault), address(governor));

        _asFactory(address(registry), abi.encodeCall(GuardianRegistry.addGovernor, (address(governor), address(vault))));

        // SHE-215: `propose` / `executeProposal` refuse a vault whose
        // owner-stake slot is unbound, claimed, slashed, or exiting. The real
        // `SyndicateFactory.createSyndicate` always binds that slot, so this
        // hand-built syndicate must too or the entire proposal surface is
        // trivially unreachable for the fuzzer. `admin` (this harness) is the
        // vault owner; `bindOwnerStake` is factory-gated like the calls above.
        wood.deal(address(this), MIN_OWNER_STAKE);
        wood.approve(address(swood), MIN_OWNER_STAKE);
        swood.prepareOwnerStake(MIN_OWNER_STAKE);
        _asFactory(address(swood), abi.encodeCall(StakedWood.bindOwnerStake, (address(this), address(vault))));

        // Async LP lane. `setWithdrawalQueue` is factory-gated and set-once
        // (G-17, I-28).
        queue = new VaultWithdrawalQueue(address(vault));
        _asFactory(address(vault), abi.encodeCall(SyndicateVault.setWithdrawalQueue, (address(queue))));
    }

    /// @dev Route a factory-gated call so `msg.sender` is `fizzFactory`.
    function _asFactory(address target, bytes memory data) internal {
        fizzFactory.forwardCall(target, data);
    }

    function setupActors() internal {
        admin = address(this);
        vm.label(admin, "Admin");

        for (uint256 i; i < ACTOR_LABELS.length; i++) {
            address _actor = address(new Actor{value: INITIAL_ETH_BALANCE}());
            actors.push(_actor);
            vm.label(_actor, ACTOR_LABELS[i]);

            // `deal` is the scaffolded MockERC20's open mint entry point.
            asset.deal(_actor, INITIAL_ASSET_BALANCE);
            wood.deal(_actor, INITIAL_WOOD_BALANCE);

            // Blanket approvals for the sinks that already exist. Approval
            // mechanics are not what this campaign targets, and making the
            // fuzzer discover an approve sequence first would waste most of
            // the call budget. Sinks deployed later are approved in
            // `_wireRoles`.
            _actorApprove(_actor, address(asset), address(vault));
            _actorApprove(_actor, address(wood), address(swood));
            _actorApprove(_actor, address(wood), address(tierRegistry));
        }
        actor = actors[0];
    }

    function _actorApprove(address who, address token, address spender) internal {
        vm.prank(who);
        (bool ok,) = token.call(abi.encodeWithSignature("approve(address,uint256)", spender, type(uint256).max));
        require(ok, "approve failed");
    }

    function _stakeGuardians() internal {
        for (uint256 i; i < GUARDIAN_COUNT; i++) {
            vm.prank(actors[i]);
            swood.stakeAsGuardian(MIN_GUARDIAN_STAKE * 2, i + 1);
        }
        // Mature the cohort to full age weight so ballots carry par weight and
        // the participation floor (I-20) is clearable from the first block.
        skipTime(MATURATION);
    }

    function _deployCoverageAndAdjudication() internal {
        // Deployed after maturation so epoch genesis and feed freshness are
        // current relative to the warps above.
        ledger = new ExposureLedger(address(this), address(swood), EPOCH_LENGTH);
        ledger.setWoodUsdPrice(0.1e8);
        // The mock publishes one round at construction and these suites warp far
        // past it; staleness is exercised in test/ExposureLedger.t.sol.
        ledger.setWoodFeed(address(woodFeed), type(uint64).max);
        ledger.setAssetFeed(address(asset), address(assetFeed), 365 days);
        ledger.setCoveredTvlCapUsd(10_000_000e18);
        ledger.setGuardianRegistry(address(registry));
        registry.setExposureLedger(address(ledger));

        bondEscrow = new ProposerBondEscrow(address(wood), address(registry), address(ledger));
        game = new ChallengeGame(address(this), address(wood), address(ledger), address(tierRegistry));
        court = new TokenCourt(address(this));
    }

    function _wireRoles() internal {
        ledger.setCoverageFreezer(address(game));
        tierRegistry.setAuthorizedDemoter(address(game));
        swood.setAuthorizedSlasher(address(game));

        game.setStakedWood(address(swood));
        court.setChallengeGame(address(game));
        court.setStakedWood(address(swood));
        game.setCourt(address(court));

        // Governor wiring — factory-gated.
        _asFactory(address(governor), abi.encodeCall(SyndicateGovernor.setExposureLedger, (address(ledger))));
        _asFactory(address(governor), abi.encodeCall(SyndicateGovernor.setBondEscrow, (address(bondEscrow))));
        _asFactory(address(governor), abi.encodeCall(SyndicateGovernor.setTierRegistry, (address(tierRegistry))));

        // Approvals for the WOOD sinks that did not exist during `setupActors`.
        for (uint256 i; i < actors.length; i++) {
            _actorApprove(actors[i], address(wood), address(bondEscrow));
            _actorApprove(actors[i], address(wood), address(game));
        }
    }

    /// @dev Certify and allowlist the benign batch target. Two separate gates
    ///      have to pass for a proposal's calls to execute: `tierOf` prices the
    ///      (target, selector) pair, and `isAdapterAllowed` decides whether the
    ///      vault may call the target at all (issue #166). Certification is a
    ///      propose → delay → certify cycle (I-30), so the clock is advanced in
    ///      between.
    function _certifyAdapter() internal {
        // Tier 1 with a 50% extractable bound. `extractableBoundBps` must sit
        // strictly inside (0, FULL_NOTIONAL_BPS) — 10_000 is the exclusive
        // upper bound and reverts `BoundRequired`.
        tierRegistry.proposeCertification(
            address(adapter), FizzAdapter.poke.selector, 1, 5_000, address(0), address(adapter).codehash
        );
        skipTime(tierRegistry.certifyDelay() + 1);
        tierRegistry.certify(address(adapter), FizzAdapter.poke.selector);
        tierRegistry.setAdapterAllowed(address(adapter), true);
    }

    function _seedVault() internal {
        // Register two agents so `propose` is reachable from more than one
        // actor and co-proposer flows have a second eligible party.
        for (uint256 i = GUARDIAN_COUNT; i < GUARDIAN_COUNT + 2 && i < actors.length; i++) {
            uint256 agentId = agentRegistry.mint(actors[i]);
            vault.registerAgent(agentId, actors[i]);
        }

        // A non-empty vault: share pricing, the high-water mark and the queue
        // reserve all behave differently against zero supply, and an empty
        // vault would make most of the fuzzed surface trivially revert.
        for (uint256 i; i < actors.length; i++) {
            vm.prank(actors[i]);
            vault.deposit(SEED_DEPOSIT, actors[i]);
        }

        skipTime(1 hours);
    }

    // ――――――――――――――――――――――――― Helpers ――――――――――――――――――――――――――

    // Maps an arbitrary address to an actor address
    function toActor(address addy) internal view returns (address) {
        return actors[uint256(uint160(addy)) % actors.length];
    }

    // Maps an arbitrary address to an actor address that is different from the current actor
    function toActorNotCurrent(address addy) internal view returns (address) {
        address _actor = actors[uint256(uint160(addy)) % actors.length];
        if (_actor == actor) {
            _actor = actors[(uint256(uint160(addy)) + 1) % actors.length];
        }
        return _actor;
    }

    // Maps an arbitrary seed to one of the staked guardians
    function toGuardian(uint256 seed) internal view returns (address) {
        return actors[seed % GUARDIAN_COUNT];
    }

    // Sums the native token balances of all actors
    function sumActorsBalances() internal view returns (uint256 sumOfBalances) {
        for (uint256 i; i < actors.length; i++) {
            sumOfBalances += actors[i].balance;
        }
    }

    // Sums the ERC-20 token balances of all actors for a given token
    function sumActorsERC20Balances(address _token) internal view returns (uint256 sumOfBalances) {
        for (uint256 i; i < actors.length; i++) {
            bytes memory data = abi.encodeWithSignature("balanceOf(address)", actors[i]);
            (bool success, bytes memory result) = _token.staticcall(data);
            require(success, "sumActorsERC20Balances: failed to get balance");
            sumOfBalances += abi.decode(result, (uint256));
        }
    }

    function skipBlocks(uint256 blocks) internal {
        vm.roll(block.number + blocks);
        vm.warp(block.timestamp + blocks * BLOCK_INTERVAL);
    }

    function skipTime(uint256 time) internal {
        uint256 blocks = (time + BLOCK_INTERVAL - 1) / BLOCK_INTERVAL;
        vm.roll(block.number + blocks);
        vm.warp(block.timestamp + time);
    }
}
