// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {DeployPlanB} from "../../script/DeployPlanB.s.sol";
import {Checkpoint} from "../../script/robinhood-mainnet/DeployAll.s.sol";
import {Posture, Inputs, Stack} from "../../script/robinhood-mainnet/DeployTypes.sol";
import {DeployAllFixture} from "./DeployAll.t.sol";
import {DeploySalts} from "../../script/DeploySalts.sol";
import {RobinhoodParams} from "../../script/robinhood-mainnet/RobinhoodParams.sol";
import {Create3} from "../../script/utils/Create3.sol";
import {ExposureLedger} from "../../src/ExposureLedger.sol";
import {IExposureLedger} from "../../src/interfaces/IExposureLedger.sol";
import {StakedWood} from "../../src/StakedWood.sol";
import {GuardianRegistry} from "../../src/GuardianRegistry.sol";
import {SyndicateFactory} from "../../src/SyndicateFactory.sol";
import {TierRegistry} from "../../src/TierRegistry.sol";
import {SyndicateGovernor} from "../../src/SyndicateGovernor.sol";
import {GovernorBeacon} from "../../src/GovernorBeacon.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {ProtocolConfig} from "../../src/ProtocolConfig.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";

/// @dev The mixin is abstract, and `Create3Factory.deploy` is `onlyOwner`, so the harness
///      must be both the deployer the fixtures are owned by and the caller of `deploy` —
///      hence `vm.prank(address(script))` everywhere instead of a forwarder.
contract DeployPlanBHarness is DeployPlanB {
    function c3Factory(address deployer) external returns (address) {
        return address(_c3Factory(deployer));
    }
}

/// @dev A sWOOD that answers every read and SILENTLY SWALLOWS `setExposureLedger`. The
///      real `StakedWood` cannot drop that write, so this is the only way to prove the
///      exit-gate post-flight bites. Stands in for a proxy on an impl without the setter,
///      a multisig that dropped the last call of a batch, a `setExposureLedger(0)` after.
contract DeafStakedWood {
    address public owner;
    address public exposureLedger;

    constructor(address owner_) {
        owner = owner_;
    }

    function coolDownPeriod() external pure returns (uint256) {
        return 7 days;
    }

    function maxSlashBps() external pure returns (uint256) {
        return 10_000;
    }

    function minSlashBps() external pure returns (uint256) {
        return 500;
    }

    /// @dev The whole point: accepts the call, keeps the pointer at zero.
    function setExposureLedger(address) external {}
}

/// @dev A GuardianRegistry that answers `reviewPeriod()` (read by
///      `ExposureLedger.setGuardianRegistry`) and swallows `setExposureLedger`.
contract DeafGuardianRegistry {
    address public exposureLedger;

    function reviewPeriod() external pure returns (uint256) {
        return 24 hours;
    }

    function setExposureLedger(address) external {}
}

/// @dev A SyndicateFactory that swallows both wiring calls. A zero count keeps pre-flight
///      5 out of the way, so this stub stays about the wiring post-flight.
contract DeafSyndicateFactory {
    address public exposureLedger;
    address public bondEscrow;

    function syndicateCount() external pure returns (uint256) {
        return 0;
    }

    function setExposureLedger(address) external {}

    function setBondEscrow(address) external {}
}

/// @dev A factory with a DECLARED count and beacon — pre-flight 5's two inputs — plus real
///      storage for the wiring setters, so a PERMITTED run still reaches the post-flights.
///      Reaching `syndicateCount != 0` through the real factory means driving
///      `createSyndicate`, and the state under test is the count, not how it was reached.
contract CountingSyndicateFactory {
    uint256 public syndicateCount;
    address public beacon;
    address public exposureLedger;
    address public bondEscrow;

    constructor(uint256 count_, address beacon_) {
        syndicateCount = count_;
        beacon = beacon_;
    }

    function setExposureLedger(address newLedger) external {
        exposureLedger = newLedger;
    }

    function setBondEscrow(address newEscrow) external {
        bondEscrow = newEscrow;
    }
}

/// @dev A governor implementation from BEFORE Plan B: neither `exposureLedger()` nor
///      `bondEscrow()`, and no fallback to fake one. Robinhood testnet 46630 serves
///      exactly this shape behind a beacon with 9 live proxies.
contract PrePlanBGovernor {
    address public vault;
}

/// @notice Drives the REAL Plan B phase against a REAL `StakedWood`, `GuardianRegistry`
///         and `SyndicateFactory` from the state a first deploy starts in —
///         `swood.exposureLedger() == 0` — then breaks one piece of that state at a time.
contract DeployPlanBPreflightTest is Test {
    ERC20Mock internal wood;
    ERC20Mock internal usdg;
    MockAggregatorV3 internal usdgFeed;
    StakedWood internal swood;
    GuardianRegistry internal registry;
    SyndicateFactory internal factory;
    ProtocolConfig internal protocolConfig;

    DeployPlanBHarness internal script;
    /// @dev The harness address: it owns every fixture AND calls `deploy`, because the
    ///      CREATE3 factory it bootstraps only takes mints from its own owner.
    address internal deployer;

    uint256 internal constant FEED_MAX_DELAY = 1 days;
    /// @dev The price CAP, $0.50 — not a price. The market sits BELOW it (see
    ///      `WOOD_MARKET_X8`), which is the configuration production ships.
    uint256 internal constant WOOD_PRICE_CAP_X8 = 5e7;
    /// @dev What the feed reports, $0.25 — half the cap, so the cap is non-binding.
    uint256 internal constant WOOD_MARKET_X8 = 2.5e7;
    uint256 internal constant COVERED_TVL_CAP = 1_000_000e18;

    // The address book the next run should see. See `_book`.
    address internal bookSwood;
    address internal bookRegistry;
    address internal bookFactory;
    uint256 internal bookCap = COVERED_TVL_CAP;
    uint256 internal bookMaxStrategyDuration = RobinhoodParams.MAX_STRATEGY_DURATION;
    uint256 internal bookCapPriceX8 = WOOD_PRICE_CAP_X8;
    uint256 internal bookHaircutBps = RobinhoodParams.WOOD_HAIRCUT_BPS;
    /// @dev THE live WOOD price source. The ledger cannot price a bond without one —
    ///      `woodUsdPriceX8` is a cap, never a price. A test that wants the refusal
    ///      clears it.
    address internal bookWoodUsdFeed;
    /// @dev Its staleness bound. Paired with the field above by pre-flight 12.
    uint256 internal bookWoodFeedMaxDelay;

    function setUp() public {
        script = new DeployPlanBHarness();
        deployer = address(script);

        wood = new ERC20Mock("WOOD", "WOOD", 18);
        usdg = new ERC20Mock("USDG", "USDG", 6);
        usdgFeed = new MockAggregatorV3(8, 1e8);
        bookWoodUsdFeed = address(new MockAggregatorV3(8, int256(WOOD_MARKET_X8)));
        bookWoodFeedMaxDelay = 365 days;

        StakedWood swoodImpl = new StakedWood();
        bytes memory swoodInit = abi.encodeCall(
            StakedWood.initialize,
            (StakedWood.InitParams({
                    owner: deployer,
                    wood: address(wood),
                    factory: address(this),
                    minGuardianStake: 10_000e18,
                    coolDownPeriod: 7 days,
                    minOwnerStake: 10_000e18,
                    minSlashBps: 1_000,
                    // Pre-flight 1b demands exactly this.
                    maxSlashBps: 10_000,
                    ageFloorBps: 2_500,
                    maturationPeriod: 30 days
                }))
        );
        swood = StakedWood(address(new ERC1967Proxy(address(swoodImpl), swoodInit)));

        // The registry's `factory` is a placeholder: this phase exercises none of the
        // factory-gated paths.
        GuardianRegistry registryImpl = new GuardianRegistry(6 hours);
        bytes memory registryInit =
            abi.encodeCall(GuardianRegistry.initialize, (deployer, address(this), address(swood), 24 hours, 3_000));
        registry = GuardianRegistry(address(new ERC1967Proxy(address(registryImpl), registryInit)));

        // Owned by the deployer: the phase SEATS `maxStrategyDuration` on it (pre-flight
        // 6), and pre-flight 6b refuses the run otherwise.
        protocolConfig = new ProtocolConfig(deployer);
        address govImpl = address(new SyndicateGovernor(24 hours, 1 hours));
        GovernorBeacon beacon = new GovernorBeacon(govImpl, deployer);
        SyndicateFactory factoryImpl = new SyndicateFactory();
        bytes memory factoryInit = abi.encodeCall(
            SyndicateFactory.initialize,
            (SyndicateFactory.InitParams({
                    owner: deployer,
                    executorImpl: address(new BatchExecutorLib()),
                    vaultImpl: address(new SyndicateVault()),
                    ensRegistrar: address(0),
                    agentRegistry: address(0),
                    beacon: address(beacon),
                    protocolConfig: address(protocolConfig),
                    managementFeeBps: 50,
                    guardianRegistry: address(registry),
                    // Mandatory since pashov finding #1.
                    tierRegistry: address(new TierRegistry(deployer))
                }))
        );
        factory = SyndicateFactory(address(new ERC1967Proxy(address(factoryImpl), factoryInit)));

        _setBook(address(swood), address(registry), address(factory));
    }

    // ─────────────────────────── the happy path ───────────────────────────

    /// @notice A FIRST DEPLOY MUST RUN from the state where sWOOD's pointer is zero and
    ///         the only ledger this deployment will have does not exist yet.
    function test_deploy_armsTheExitGateFromAVirginState() public {
        assertEq(swood.exposureLedger(), address(0), "fixture must start with the gate unarmed");

        _run();

        address ledger = swood.exposureLedger();
        assertTrue(ledger != address(0), "the deploy must arm the unstake gate");
        assertEq(address(registry.exposureLedger()), ledger, "registry must book into the same ledger");
        assertEq(factory.exposureLedger(), ledger, "factory must issue against the same ledger");
        assertTrue(factory.bondEscrow() != address(0), "bond escrow must be wired");

        assertEq(ExposureLedger(ledger).owner(), deployer, "ledger owner");
        assertEq(ExposureLedger(ledger).coveredTvlCapUsd(), COVERED_TVL_CAP, "ledger cap");
    }

    /// @notice Both contracts land at the address CREATE3 predicts from the salt alone —
    ///         which is what lets the pointer pre-flights run BEFORE anything is minted.
    function test_deploy_mintsAtThePredictedCreate3Addresses() public {
        address c3 = script.c3Factory(deployer);
        address predictedLedger = Create3.addressOf(c3, DeploySalts.EXPOSURE_LEDGER);
        address predictedEscrow = Create3.addressOf(c3, DeploySalts.PROPOSER_BOND_ESCROW);

        _run();

        assertEq(swood.exposureLedger(), predictedLedger, "the ledger must mint at its salt");
        assertEq(factory.bondEscrow(), predictedEscrow, "the escrow must mint at its salt");
        assertTrue(predictedLedger != predictedEscrow, "distinct salts, distinct addresses");
    }

    /// @notice A SECOND RUN ADOPTS AND WRITES NOTHING. Every mint is skip-if-code and
    ///         every write is guarded on the value already there, so a resumed ceremony
    ///         is a no-op rather than a second ledger.
    function test_deploy_secondCallMintsNothing() public {
        _run();
        address ledger = swood.exposureLedger();
        address escrow = factory.bondEscrow();
        bytes32 ledgerHash = ledger.codehash;

        _run();

        assertEq(swood.exposureLedger(), ledger, "the second run must adopt the same ledger");
        assertEq(factory.bondEscrow(), escrow, "and the same escrow");
        assertEq(ledger.codehash, ledgerHash, "nothing may be re-minted over it");
        assertEq(ExposureLedger(ledger).woodHaircutBps(), RobinhoodParams.WOOD_HAIRCUT_BPS, "params unchanged");
    }

    /// @notice A POINTER ALREADY NAMING A FOREIGN LEDGER IS REFUSED, not repointed. This
    ///         is the end state the old "hand-deploy a ledger, wire sWOOD, re-run" remedy
    ///         produced; repointing it silently would leave the operator believing the
    ///         first ledger's bookings still count.
    function test_deploy_refusesAForeignLedgerPointer() public {
        address c3 = script.c3Factory(deployer);
        address predicted = Create3.addressOf(c3, DeploySalts.EXPOSURE_LEDGER);

        ExposureLedger stale = new ExposureLedger(deployer, address(swood), 28 days);
        vm.prank(deployer);
        swood.setExposureLedger(address(stale));

        _runExpecting("WIRING: StakedWood.exposureLedger already names a foreign address");

        assertEq(predicted.code.length, 0, "refused BEFORE the mint: nothing was deployed");
        assertEq(swood.exposureLedger(), address(stale), "and the live slot was left alone");
    }

    // ──────────────────────── the pre-flights bite ────────────────────────

    /// @notice PRE-FLIGHT 2b: the deployer must own sWOOD, or it cannot make the
    ///         `setExposureLedger` call the exit gate depends on.
    function test_preflight_bites_whenBroadcasterDoesNotOwnStakedWood() public {
        vm.prank(deployer);
        swood.transferOwnership(address(0xBEEF)); // plain Ownable: immediate

        _runExpecting("PRE-FLIGHT: broadcaster does not own STAKED_WOOD");

        assertEq(swood.exposureLedger(), address(0), "a refused deploy must not have wired anything");
        assertEq(address(registry.exposureLedger()), address(0), "a refused deploy must not have wired anything");
    }

    /// @notice PRE-FLIGHT 1b: a slash ceiling below 10_000 clips every fully-locked burn
    ///         beneath the lock. `setMaxSlashBps(9_999)` is legal, so no storage poke.
    function test_preflight_bites_whenMaxSlashBpsIsBelowTheCeiling() public {
        vm.prank(deployer);
        swood.setMaxSlashBps(9_999);
        _runExpecting("PRE-FLIGHT: sWOOD maxSlashBps != 10000 -- a lock may equal the whole stake and must");
        assertEq(address(registry.exposureLedger()), address(0), "a refused deploy must not have wired anything");
    }

    /// @notice PRE-FLIGHT 1c: a zero `minSlashBps` disarms the single deterrence floor, so
    ///         a token lock would buy a token penalty.
    function test_preflight_bites_whenMinSlashBpsIsZero() public {
        vm.prank(deployer);
        swood.setMinSlashBps(0);
        assertEq(swood.minSlashBps(), 0, "precondition: the floor really is zero");
        _runExpecting("PRE-FLIGHT: sWOOD minSlashBps == 0 -- it is the single deterrence floor");
        assertEq(address(registry.exposureLedger()), address(0), "a refused deploy must not have wired anything");
    }

    /// @notice Control for 1c: the fixture's 1_000-bps floor passes, so the pre-flight
    ///         refuses ZERO and not any small value — the launch value is governance's.
    function test_preflight_passes_atANonZeroMinSlashBps() public {
        assertEq(swood.minSlashBps(), 1_000, "fixture floor");
        _run();
        assertTrue(swood.exposureLedger() != address(0), "deployed and wired");
    }

    /// @notice PRE-FLIGHT 2: a zero covered-TVL cap is fail-closed — wired into a
    ///         governor, nothing could be proposed at all.
    function test_preflight_bites_whenCoveredTvlCapIsZero() public {
        bookCap = 0;
        _runExpecting("PRE-FLIGHT: COVERED_TVL_CAP_USD18 is 0");
    }

    /// @notice PRE-FLIGHT 3 (sWOOD leg) — THE SECURITY GATE. The wiring call happens in
    ///         the run, so the only way it fails to land is a sWOOD that swallows it;
    ///         without this the deployment looks healthy while the exit gate fails open.
    function test_wiringCheck_bites_whenTheExitGateDidNotLand() public {
        DeafStakedWood deaf = new DeafStakedWood(deployer);
        _setBook(address(deaf), address(registry), address(factory));
        _runExpecting("PRE-FLIGHT: sWOOD exposureLedger != the ledger just deployed");
    }

    /// @notice PRE-FLIGHT 3 (registry leg): booking and gating are one mechanism, so a
    ///         registry on a different ledger is the same hole from the other side.
    function test_wiringCheck_bites_whenTheRegistryDidNotTakeTheLedger() public {
        DeafGuardianRegistry deaf = new DeafGuardianRegistry();
        _setBook(address(swood), address(deaf), address(factory));
        _runExpecting("WIRING: GuardianRegistry.exposureLedger != the ledger just deployed");
    }

    /// @notice PRE-FLIGHT 3 (factory leg): new syndicates would be issued against a
    ///         different ledger than the exit gate reads.
    function test_wiringCheck_bites_whenTheFactoryDidNotTakeTheLedger() public {
        DeafSyndicateFactory deaf = new DeafSyndicateFactory();
        _setBook(address(swood), address(registry), address(deaf));
        _runExpecting("WIRING: SyndicateFactory.exposureLedger != the ledger just deployed");
    }

    // ───────────── pre-flight 5: the beacon guard (review M5) ─────────────

    /// @notice THE GUARD BITES: live governor proxies on a PRE-Plan B beacon are refused,
    ///         because the upgrade that would make Plan B reachable is the one the layout
    ///         re-baseline forbids. Robinhood testnet 46630 is exactly this shape.
    function test_preflight_bites_whenLiveGovernorsSitOnAPrePlanBBeacon() public {
        GovernorBeacon legacyBeacon = new GovernorBeacon(address(new PrePlanBGovernor()), deployer);
        CountingSyndicateFactory legacyFactory = new CountingSyndicateFactory(9, address(legacyBeacon));
        _setBook(address(swood), address(registry), address(legacyFactory));

        _runExpecting("PRE-FLIGHT: SYNDICATE_FACTORY has live governor proxies on a PRE-PLAN-B governor");

        assertEq(swood.exposureLedger(), address(0), "a refused deploy must not have wired anything");
        assertEq(address(registry.exposureLedger()), address(0), "a refused deploy must not have wired anything");
        assertEq(legacyFactory.exposureLedger(), address(0), "a refused deploy must not have wired anything");
    }

    /// @notice THE PROBE IS FAIL-CLOSED: an unreadable beacon counts as "not Plan
    ///         B-capable" rather than being waved through on an unanswered question.
    function test_preflight_bites_whenTheBeaconCannotBeProbed() public {
        address notABeacon = address(0xB3AC0);
        assertEq(notABeacon.code.length, 0, "fixture must be code-less");

        CountingSyndicateFactory legacyFactory = new CountingSyndicateFactory(9, notABeacon);
        _setBook(address(swood), address(registry), address(legacyFactory));

        _runExpecting("PRE-FLIGHT: SYNDICATE_FACTORY has live governor proxies on a PRE-PLAN-B governor");
    }

    /// @notice AND IT DOES NOT OVER-REFUSE: a beacon already serving a Plan B-capable
    ///         governor needs no upgrade, so `pushWiring` finishes the job and the run
    ///         must proceed. This is the ordinary "Plan A from this stack, then Plan B".
    function test_deploy_allowedWhenLiveGovernorsSitOnAPlanBCapableBeacon() public {
        GovernorBeacon capableBeacon = new GovernorBeacon(address(new SyndicateGovernor(24 hours, 1 hours)), deployer);
        CountingSyndicateFactory populated = new CountingSyndicateFactory(9, address(capableBeacon));
        _setBook(address(swood), address(registry), address(populated));

        _run();

        address ledger = swood.exposureLedger();
        assertTrue(ledger != address(0), "the deploy must arm the unstake gate");
        assertEq(populated.exposureLedger(), ledger, "the populated factory must be wired");
        assertTrue(populated.bondEscrow() != address(0), "bond escrow must be wired");
    }

    /// @notice A ZERO COUNT SKIPS THE PROBE, even behind a PRE-Plan B beacon: with no live
    ///         proxies there is nothing an impl swap can corrupt. That pairing is the
    ///         state every fresh chain — 4663 included — deploys from.
    function test_preflight_passes_whenTheFactoryHasNoSyndicates() public {
        GovernorBeacon legacyBeacon = new GovernorBeacon(address(new PrePlanBGovernor()), deployer);
        CountingSyndicateFactory freshFactory = new CountingSyndicateFactory(0, address(legacyBeacon));
        _setBook(address(swood), address(registry), address(freshFactory));

        _run();

        assertEq(freshFactory.exposureLedger(), swood.exposureLedger(), "a fresh factory must be wired normally");
    }

    // ───── pre-flights 6 and 7: the two seated invariants (issue #32) ─────

    /// @notice PRE-FLIGHT 6: the ceiling is SEATED by the run. Left to a follow-up it
    ///         ships at 0, and 0 means a vault owner may bind approving guardians for up
    ///         to `ABSOLUTE_MAX_STRATEGY_DURATION` per approval.
    function test_deploy_seatsTheProtocolDurationCeiling() public {
        assertEq(protocolConfig.maxStrategyDuration(), 0, "fixture must start with no ceiling");
        assertEq(bookMaxStrategyDuration, 30 days, "the documented default");

        _run();

        assertEq(protocolConfig.maxStrategyDuration(), 30 days, "the deploy must seat the ceiling");
    }

    /// @notice PRE-FLIGHT 6, ZERO OVERRIDE: 0 is how the parameter is UNSET, so without
    ///         this an operator could route "no ceiling" through the script that exists to
    ///         prevent one, and it would read as a configuration rather than an omission.
    function test_preflight_bites_whenTheDurationCeilingIsZero() public {
        bookMaxStrategyDuration = 0;

        _runExpecting("PRE-FLIGHT: MAX_STRATEGY_DURATION is 0");

        assertEq(swood.exposureLedger(), address(0), "a refused deploy must not have wired anything");
        assertEq(protocolConfig.maxStrategyDuration(), 0, "a refused deploy must not have seated anything");
    }

    /// @notice PRE-FLIGHT 7 BITES. The current `StakedWood` has no `delegationEnabled()`,
    ///         but this phase runs against an EXISTING proxy and a chain still serving a
    ///         pre-removal impl answers it for real. Mocked onto the REAL fixture so the
    ///         claim is sharp: the same deployment every other test passes is refused.
    function test_preflight_bites_whenDelegationIsOn() public {
        vm.mockCall(address(swood), abi.encodeWithSignature("delegationEnabled()"), abi.encode(true));

        _runExpecting("PRE-FLIGHT: sWOOD reports delegationEnabled == true");
    }

    /// @notice PRE-FLIGHT 7 DOES NOT OVER-REFUSE. The other passing shape — no selector at
    ///         all, which every current `StakedWood` presents — is asserted here too.
    function test_deploy_allowedWhenDelegationIsOff() public {
        (bool answered,) = address(swood).staticcall(abi.encodeWithSignature("delegationEnabled()"));
        assertFalse(answered, "current StakedWood must not carry the selector at all");

        vm.mockCall(address(swood), abi.encodeWithSignature("delegationEnabled()"), abi.encode(false));

        _run();

        assertTrue(swood.exposureLedger() != address(0), "delegation off must not block the deploy");
        assertEq(protocolConfig.maxStrategyDuration(), 30 days, "and the run must still seat the ceiling");
    }

    // ── PRE-FLIGHT 8: the WOOD price must actually resolve ─────────────────
    //
    // `woodUsdPriceX8` is a CAP that is never served as a price, so a deployment can be
    // misconfigured in two independent ways that both leave every price read reverting
    // `NoWoodPrice`. Each gets its own assert and its own test: the remedies differ.

    /// @notice (a) The CAP is unset. A zero cap is not "uncapped"; it is a revert.
    function test_preflight_bites_whenTheWoodPriceCapIsZero() public {
        bookCapPriceX8 = 0;
        _runExpecting("PRE-FLIGHT: ExposureLedger.woodUsdPriceX8 is 0");
    }

    /// @notice (b) The CAP is set but nothing prices under it — the shape a cap-only check
    ///         misses. The feed is the ledger's only source.
    function test_preflight_bites_whenNoWoodPriceSourceIsWired() public {
        bookWoodUsdFeed = address(0);
        bookWoodFeedMaxDelay = 0;
        _runExpecting("PRE-FLIGHT: WOOD_USD_FEED is unset");
    }

    /// @notice (c) The feed is wired but not answering — a `WoodPoolFeed` with no
    ///         completed window yet is exactly this, and it forces the prime-first order.
    function test_preflight_bites_whenTheFeedIsNotAnswering() public {
        MockAggregatorV3(bookWoodUsdFeed).setAnswer(0);
        _runExpecting("PRE-FLIGHT: ExposureLedger.woodPriceX8() does not resolve");
    }

    /// @notice The passing shape, asserted on the DEPLOYED state: the cap landed and the
    ///         composed price is the MARKET, so the cap sits above it and is not binding.
    function test_deploy_wiresTheFeedAndPricesOffTheMarket() public {
        _run();

        ExposureLedger ledger = ExposureLedger(swood.exposureLedger());
        assertEq(ledger.woodUsdPriceX8(), WOOD_PRICE_CAP_X8, "the cap must land");
        assertEq(
            ledger.woodPriceX8(),
            (WOOD_MARKET_X8 * RobinhoodParams.WOOD_HAIRCUT_BPS) / 10_000,
            "priced off the market, with the cap above it and the haircut applied"
        );
    }

    // ── PRE-FLIGHT 12: the WOOD/USD feed and its delay move together ───────

    /// @notice A feed named with no staleness bound. `setWoodFeed` would revert too, but
    ///         only from inside the run, after the ledger and escrow are already minted.
    function test_preflight12_bites_whenTheFeedHasNoDelay() public {
        bookWoodUsdFeed = address(new MockAggregatorV3(8, int256(WOOD_MARKET_X8)));
        bookWoodFeedMaxDelay = 0;
        _runExpecting("PRE-FLIGHT: WOOD_USD_FEED and WOOD_FEED_MAX_DELAY must be set together");
    }

    /// @notice The mirror slip: the delay is set and the address forgotten. Nothing
    ///         downstream would notice — the ledger would simply ship with no source.
    function test_preflight12_bites_whenTheDelayHasNoFeed() public {
        bookWoodUsdFeed = address(0);
        bookWoodFeedMaxDelay = 1 hours;
        _runExpecting("PRE-FLIGHT: WOOD_USD_FEED and WOOD_FEED_MAX_DELAY must be set together");
    }

    /// @notice A typo'd address holding no code. `setWoodFeed` calls `decimals()` on it,
    ///         so this would otherwise surface as an undecodable mid-run revert.
    function test_preflight12_bites_whenTheFeedHoldsNoCode() public {
        bookWoodUsdFeed = address(0xFEED);
        bookWoodFeedMaxDelay = 1 hours;
        _runExpecting("PRE-FLIGHT: WOOD_USD_FEED holds no code");
    }

    /// @notice A pool feed rolls `updatedAt` at most once per window, so a bound that does
    ///         not clear window + cadence halts every read BETWEEN rolls. Seeded exactly
    ///         at the boundary, which is the value an operator would pick.
    function test_preflight12_bites_whenTheDelayDoesNotClearThePoolFeedsWindow() public {
        bookWoodUsdFeed = address(new MockWindowedFeed(8, int256(WOOD_MARKET_X8), 24 hours));
        bookWoodFeedMaxDelay = 24 hours + 2 hours;
        _runExpecting("PRE-FLIGHT: WOOD_FEED_MAX_DELAY must EXCEED the feed's averaging window plus the");
    }

    /// @notice The paired passing case, so the bound is pinned from both sides.
    function test_preflight12_passes_whenTheDelayClearsTheWindowAndTheCadence() public {
        bookWoodUsdFeed = address(new MockWindowedFeed(8, int256(WOOD_MARKET_X8), 24 hours));
        bookWoodFeedMaxDelay = 24 hours + 2 hours + 1;
        _run();
    }

    /// @notice The ledger prices off whichever feed the book names. Seeded away from
    ///         `WOOD_MARKET_X8` so the assertion reads the wired feed, not a coincidence.
    function test_deploy_pricesOffWhicheverFeedTheBookNames() public {
        uint256 feedPriceX8 = WOOD_MARKET_X8 / 2;
        bookWoodUsdFeed = address(new MockAggregatorV3(8, int256(feedPriceX8)));
        bookWoodFeedMaxDelay = 1 hours;

        _run();

        ExposureLedger ledger = ExposureLedger(swood.exposureLedger());
        assertEq(
            ledger.woodPriceX8(),
            (feedPriceX8 * RobinhoodParams.WOOD_HAIRCUT_BPS) / 10_000,
            "the composed price must come from the feed the book named"
        );
    }

    // ── PRE-FLIGHT 9: a real haircut allowance must exist ──────────────────

    /// @notice THE LEDGER'S OWN DEFAULT IS THE FAILING VALUE: `woodHaircutBps` ships at
    ///         10,000 — no haircut — and the setter accepts it, so nothing else in the
    ///         stack refuses the one configuration with zero allowance.
    function test_preflight_bites_whenTheHaircutLeavesNoAllowance() public {
        bookHaircutBps = 10_000;
        _runExpecting("PRE-FLIGHT: ExposureLedger.woodHaircutBps is 10000");
    }

    /// @notice The shipped value, asserted on the DEPLOYED state and pinned to the
    ///         ceremony constant so the two cannot drift.
    function test_deploy_seatsTheShippedHaircut() public {
        assertEq(RobinhoodParams.WOOD_HAIRCUT_BPS, 5_000, "the shipped haircut equals the ledger floor (5,000)");

        _run();

        ExposureLedger ledger = ExposureLedger(swood.exposureLedger());
        assertEq(ledger.woodHaircutBps(), 5_000, "the haircut must be seated by the script, not left at 10,000");
        // A real discount on a real valuation: the composed price is 50% of the source.
        assertEq(ledger.woodPriceX8(), (WOOD_MARKET_X8 * 5_000) / 10_000, "the allowance reaches the price");
    }

    /// @notice An override above the default is honoured; the floor branch is pinned by
    ///         `test_deploy_refusesAHaircutBelowTheLedgerFloor`.
    function test_deploy_honoursAHaircutOverrideAndRespectsTheFloor() public {
        bookHaircutBps = 6_000;
        _run();
        assertEq(ExposureLedger(swood.exposureLedger()).woodHaircutBps(), 6_000, "an override must be seated");
    }

    /// @notice ONE BPS BELOW THE SHIPPED VALUE. The ceremony haircut equals the ledger's
    ///         `MIN_WOOD_HAIRCUT_BPS`, so the default sits on the revert boundary: the
    ///         refusal comes from the ledger's own setter, mid-run, which is why the
    ///         script mirrors the floor and asserts it afterwards as well.
    function test_deploy_refusesAHaircutBelowTheLedgerFloor() public {
        bookHaircutBps = 4_999;
        DeployPlanB.PlanBBook memory book = _book();
        vm.prank(deployer);
        vm.expectRevert(IExposureLedger.InvalidParameter.selector);
        script.deploy(book);
    }

    // Pre-flight 10 (the ledger owner, issue #89) is no longer a phase pre-flight — this
    // mixin runs BEFORE the handoff. It lives in `DeployAll._validateAll`; the three cases
    // are `DeployPlanBPreflight10Test` at the bottom of this file.

    // ─────────────────────────────── helpers ───────────────────────────────

    /// @dev THE ADDRESS BOOK IS PASSED, NOT SET IN THE ENVIRONMENT. `vm.setEnv` writes one
    ///      shared mutable global that forge does not roll back between tests, so an
    ///      env-driven suite races every sibling that seeds the same keys.
    function _setBook(address swood_, address registry_, address factory_) internal {
        bookSwood = swood_;
        bookRegistry = registry_;
        bookFactory = factory_;
    }

    /// @dev Field-by-field rather than one struct literal: the literal form holds every
    ///      value live on the stack at once and trips solc's "1 too deep".
    function _book() internal view returns (DeployPlanB.PlanBBook memory book) {
        book.swood = bookSwood;
        book.factory = bookFactory;
        book.registry = bookRegistry;
        book.wood = address(wood);
        book.usdg = address(usdg);
        book.usdgFeed = address(usdgFeed);
        book.feedMaxDelay = FEED_MAX_DELAY;
        book.woodPriceCapX8 = bookCapPriceX8;
        book.woodHaircutBps = bookHaircutBps;
        book.coveredTvlCapUsd = bookCap;
        book.protocolConfig = address(protocolConfig);
        book.maxStrategyDuration = bookMaxStrategyDuration;
        book.woodUsdFeed = bookWoodUsdFeed;
        book.woodFeedMaxDelay = bookWoodFeedMaxDelay;
    }

    /// @dev The book is hoisted out of argument position: an external call there is
    ///      evaluated first and would eat the pending `vm.prank`.
    function _run() internal {
        DeployPlanB.PlanBBook memory book = _book();
        vm.prank(deployer);
        script.deploy(book);
    }

    function _runExpecting(string memory prefix) internal {
        DeployPlanB.PlanBBook memory book = _book();
        vm.prank(deployer);
        try script.deploy(book) {
            revert("pre-flight did not bite");
        } catch Error(string memory reason) {
            _assertPrefix(reason, prefix);
        }
    }

    function _assertPrefix(string memory reason, string memory prefix) internal pure {
        bytes memory r = bytes(reason);
        bytes memory p = bytes(prefix);
        require(r.length >= p.length, reason);
        bytes memory head = new bytes(p.length);
        for (uint256 i; i < p.length; ++i) {
            head[i] = r[i];
        }
        require(keccak256(head) == keccak256(p), reason);
    }
}

/// @dev What a `WoodPoolFeed` looks like to pre-flight 12's probe: an ordinary aggregator
///      that also reports the window its `updatedAt` advances on.
contract MockWindowedFeed is MockAggregatorV3 {
    uint256 public immutable window;

    constructor(uint8 decimals_, int256 answer_, uint256 window_) MockAggregatorV3(decimals_, answer_) {
        window = window_;
    }
}

/**
 * @notice Pre-flight 10 in its new home: the ledger's owner is the slashing and freeze
 *         authority, so on Mainnet it must end up at a CONTRACT — and a two-step transfer
 *         leaves that in `pendingOwner` until the Safe accepts.
 *
 * @dev DO NOT "IMPROVE" ANY OF THESE INTO A ZODIAC MODULE PROBE.
 *      `openspec/specs/deployment-docs/spec.md` records why: enumerating a Safe's modules
 *      proves only that SOME module is attached, never that the delay is ASYMMETRIC, and a
 *      probe that appears to verify the requirement while verifying something weaker is
 *      worse than none.
 */
contract DeployPlanBPreflight10Test is DeployAllFixture {
    function setUp() public {
        _stageCeremony();
    }

    /// @notice A finished Mainnet ceremony leaves the ledger armed for the Safe.
    function test_preflight10_mainnetPendingOwnerIsTheSafe() public {
        Stack memory s = _completeMainnetCeremony();
        Inputs memory i = _inputs(Posture.Mainnet);

        assertEq(Ownable2Step(s.exposureLedger).pendingOwner(), address(safe), "ledger armed for the Safe");
        script.exposed_validateAll(s, i, Checkpoint.Complete);
    }

    /// @notice An EOA `OWNER_MULTISIG` that slipped past the pre-flight is caught after the
    ///         handoff, where the ledger's pending owner is read back.
    function test_preflight10_mainnetRefusesAnEoaPendingOwner() public {
        address eoa = address(0xA11CE);
        Stack memory s = _completeMainnetCeremony(eoa);
        Inputs memory i = _inputs(Posture.Mainnet);
        i.ownerMultisig = eoa;

        assertEq(Ownable2Step(s.exposureLedger).pendingOwner(), eoa, "armed for an EOA");
        vm.expectRevert(bytes("OWNER_MULTISIG must be a contract (Safe), not an EOA"));
        script.exposed_validateAll(s, i, Checkpoint.Complete);
    }

    /// @notice Fork posture never hands off, so the owner check has no subject: the deployer
    ///         keeps the ledger and nothing is armed.
    function test_preflight10_forkPostureSkipsTheOwnerCheck() public {
        vm.chainId(FORK_CHAIN_ID);
        (Stack memory s,) = _runCeremony(Posture.Fork);
        Inputs memory i = _inputs(Posture.Fork);

        assertEq(Ownable(s.exposureLedger).owner(), deployer, "ledger still the deployer's");
        assertEq(Ownable2Step(s.exposureLedger).pendingOwner(), address(0), "nothing armed");
        script.exposed_validateAll(s, i, Checkpoint.Complete);
    }

    // ─────────────────────────────── helpers ───────────────────────────────

    function _completeMainnetCeremony() internal returns (Stack memory) {
        return _completeMainnetCeremony(address(safe));
    }

    /// @dev Two runs: the first mints the WOOD feed and stops, the keeper primes it, the
    ///      second completes and hands off.
    function _completeMainnetCeremony(address ownerMultisig) internal returns (Stack memory s) {
        vm.chainId(MAINNET_CHAIN_ID);
        Inputs memory i = _inputs(Posture.Mainnet);
        i.ownerMultisig = ownerMultisig;

        vm.prank(deployer);
        (Stack memory first,) = script.deployAll(i);
        _primeWoodFeed(first.woodUsdFeed);

        vm.prank(deployer);
        (s,) = script.deployAll(i);
    }
}
