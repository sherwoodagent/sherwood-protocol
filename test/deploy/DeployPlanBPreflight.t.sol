// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {DeployPlanB} from "../../script/DeployPlanB.s.sol";
import {ExposureLedger} from "../../src/ExposureLedger.sol";
import {StakedWood} from "../../src/StakedWood.sol";
import {GuardianRegistry} from "../../src/GuardianRegistry.sol";
import {SyndicateFactory} from "../../src/SyndicateFactory.sol";
import {SyndicateGovernor} from "../../src/SyndicateGovernor.sol";
import {GovernorBeacon} from "../../src/GovernorBeacon.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {ProtocolConfig} from "../../src/ProtocolConfig.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";
import {MockWoodTwapOracle} from "../mocks/MockWoodTwapOracle.sol";

/// @dev THE ONLY WAY TO RUN A SCRIPT AS ITS OWN BROADCASTER FROM A TEST.
///      `vm.startBroadcast()` executes the script's calls as forge's
///      `DEFAULT_SENDER`, while the script's `deployer = msg.sender` is
///      whoever called `run()`. In production those are the same address
///      (`--sender`); in a test they are not, and `DeployPlanB` would then
///      deploy a ledger owned by one address while calling four owner-only
///      setters as another. `vm.prank` cannot bridge the gap — foundry
///      refuses to broadcast while a prank is active. So this etches a
///      forwarder at `DEFAULT_SENDER` and calls `run()` THROUGH it. Same
///      idiom, and the same reason, as `DeployTokenCourtPreflight.t.sol`.
contract PlanBScriptCaller {
    function fwd(address target, bytes calldata data) external {
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }
}

/// @dev A sWOOD that answers every read `DeployPlanB` makes and SILENTLY
///      SWALLOWS `setExposureLedger`. There is no way to make the real
///      `StakedWood` drop that call — it is a plain storage write — so the
///      only way to prove the exit-gate assertion actually bites is to give
///      the script a sWOOD that does not take the wiring. This stands in for
///      every real cause of the same end state: a proxy pointed at an impl
///      without the setter, a multisig that dropped the last call of a batch,
///      a `setExposureLedger(0)` that lands right afterwards.
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

    /// @dev The whole point: accepts the call, keeps the pointer at zero.
    function setExposureLedger(address) external {}
}

/// @dev A GuardianRegistry that answers `reviewPeriod()` (which
///      `ExposureLedger.setGuardianRegistry` reads) and swallows
///      `setExposureLedger`. Same rationale as `DeafStakedWood`.
contract DeafGuardianRegistry {
    address public exposureLedger;

    function reviewPeriod() external pure returns (uint256) {
        return 24 hours;
    }

    function setExposureLedger(address) external {}
}

/// @dev A SyndicateFactory that swallows both wiring calls the script makes on
///      it. Same rationale as `DeafStakedWood`.
contract DeafSyndicateFactory {
    address public exposureLedger;
    address public bondEscrow;

    /// @dev Fresh: pre-flight 5 skips the beacon probe entirely at a zero count,
    ///      so this stub stays about the wiring assertion it was written for.
    function syndicateCount() external pure returns (uint256) {
        return 0;
    }

    function setExposureLedger(address) external {}

    function setBondEscrow(address) external {}
}

/// @dev A factory with a DECLARED syndicate count and beacon — the two inputs
///      pre-flight 5 reads — plus real storage for the two wiring setters, so a
///      PERMITTED run still reaches and passes the post-broadcast wiring
///      assertions. The real `SyndicateFactory` cannot stand in here: reaching
///      `syndicateCount != 0` through it means driving `createSyndicate`, which
///      needs the whole ENS / agent-registry / owner-stake apparatus, and the
///      state under test is the COUNT and the BEACON, not how they were reached.
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

/// @dev A governor implementation from BEFORE Plan B: no `exposureLedger()` and
///      no `bondEscrow()` selector, and no fallback to fake one. This is the
///      shape a legacy chain's beacon actually serves — Robinhood testnet 46630
///      has 9 live governor proxies on such a beacon — and it is the state
///      pre-flight 5 must refuse, because the beacon upgrade that would make
///      Plan B reachable is exactly what the layout re-baseline forbids.
contract PrePlanBGovernor {
    address public vault;
}

/// @notice Drives the REAL `DeployPlanB` script against a REAL `StakedWood`,
///         `GuardianRegistry` and `SyndicateFactory`, from the state a FIRST
///         deploy actually starts in — `swood.exposureLedger() == 0` — then
///         breaks one piece of that state at a time and proves the
///         corresponding pre-flight refuses. Simulation only: no `--broadcast`
///         is ever involved, the script's own `vm.startBroadcast` runs against
///         this test's EVM state.
///
///         The two properties under test are the two halves of review B3:
///           1. THE SCRIPT MUST RUN FROM A VIRGIN STATE. The pre-flight this
///              replaces demanded a pointer to a ledger that does not exist
///              until step 2 of this very script, so `run()` aborted after
///              `vm.stopBroadcast()` on every first deploy.
///           2. THE CHECK MUST BE AN IDENTITY, NOT A NON-ZERO. A non-zero test
///              is passed by the exact workaround the old message told
///              operators to perform — hand-deploy a ledger, wire sWOOD to it,
///              re-run — which leaves sWOOD reading a ledger holding none of
///              this deployment's bookings.
contract DeployPlanBPreflightTest is Test {
    ERC20Mock internal wood;
    ERC20Mock internal usdg;
    MockAggregatorV3 internal usdgFeed;
    StakedWood internal swood;
    GuardianRegistry internal registry;
    SyndicateFactory internal factory;
    ProtocolConfig internal protocolConfig;

    DeployPlanB internal script;

    uint256 internal constant FEED_MAX_DELAY = 1 days;
    /// @dev The price CAP, $0.50. It is NOT a price — pre-flight 8 requires it
    ///      non-zero, and the market sits BELOW it (see `WOOD_MARKET_X8`), which
    ///      is the configuration production ships.
    uint256 internal constant WOOD_PRICE_CAP_X8 = 5e7;
    /// @dev What the TWAP oracle reports, $0.25 — half the cap, so the cap is
    ///      non-binding and the deployed ledger prices off the market.
    uint256 internal constant WOOD_MARKET_X8 = 2.5e7;
    uint256 internal constant COVERED_TVL_CAP = 1_000_000e18;

    // The address book the next script run should see. See `_book`.
    address internal bookSwood;
    address internal bookRegistry;
    address internal bookFactory;
    uint256 internal bookCap = COVERED_TVL_CAP;
    // Seeded in `setUp` from `script.DEFAULT_MAX_STRATEGY_DURATION()` — the
    // value an UNSET `MAX_STRATEGY_DURATION` produces in `run()`. See
    // `test_deploy_seatsTheProtocolDurationCeiling`.
    uint256 internal bookMaxStrategyDuration;
    /// @dev The live WOOD price source. Under design revision 2 the deployed
    ///      ledger CANNOT price a bond without one — `woodUsdPriceX8` is a cap,
    ///      never a price — so a book with a zero here is a book pre-flight 8
    ///      refuses. Seeded in `setUp`; a test that wants the refusal clears it.
    address internal bookTwapOracle;
    /// @dev The price CAP the next run should seed. A test that wants
    ///      pre-flight 8's first assert zeroes it.
    uint256 internal bookCapPriceX8 = WOOD_PRICE_CAP_X8;
    /// @dev The haircut the next run should seed. Seeded in `setUp` from the
    ///      script's own default so this suite asserts against exactly what an
    ///      unset `WOOD_HAIRCUT_BPS` produces; a test that wants pre-flight 9
    ///      raises it to the ledger's 10,000 no-allowance default.
    uint256 internal bookHaircutBps;
    /// @dev Pre-flight 10's fork bypass. FALSE here on purpose: the default is
    ///      the mainnet posture, so every other test in this suite still runs
    ///      against the refusing branch and `test_preflight10_bites_*` keeps
    ///      meaning what it meant. Only the bypass test raises it.
    bool internal bookAllowEoaLedgerOwner;

    function setUp() public {
        wood = new ERC20Mock("WOOD", "WOOD", 18);
        usdg = new ERC20Mock("USDG", "USDG", 6);
        usdgFeed = new MockAggregatorV3(8, 1e8);
        bookTwapOracle = address(new MockWoodTwapOracle(WOOD_MARKET_X8));

        StakedWood swoodImpl = new StakedWood();
        bytes memory swoodInit = abi.encodeCall(
            StakedWood.initialize,
            (StakedWood.InitParams({
                    owner: DEFAULT_SENDER,
                    wood: address(wood),
                    factory: address(this),
                    minGuardianStake: 10_000e18,
                    coolDownPeriod: 7 days,
                    minOwnerStake: 10_000e18,
                    minSlashBps: 1_000,
                    // Pre-flight 1b demands exactly this. Seated here so the
                    // fixture is a deployment the script is willing to touch.
                    maxSlashBps: 10_000,
                    ageFloorBps: 2_500,
                    maturationPeriod: 30 days
                }))
        );
        swood = StakedWood(address(new ERC1967Proxy(address(swoodImpl), swoodInit)));

        // The registry's `factory` is a placeholder: this script exercises none
        // of the factory-gated paths, and wiring the real circular pair would
        // need the CREATE3 prediction dance `DeployScript.t.sol` already covers.
        GuardianRegistry registryImpl = new GuardianRegistry(6 hours);
        bytes memory registryInit = abi.encodeCall(
            GuardianRegistry.initialize, (DEFAULT_SENDER, address(this), address(swood), 24 hours, 3_000)
        );
        registry = GuardianRegistry(address(new ERC1967Proxy(address(registryImpl), registryInit)));

        // Owned by DEFAULT_SENDER: the script SEATS `maxStrategyDuration` on it
        // (pre-flight 6), and pre-flight 6b refuses the run otherwise.
        protocolConfig = new ProtocolConfig(DEFAULT_SENDER);
        address govImpl = address(new SyndicateGovernor(24 hours, 1 hours));
        GovernorBeacon beacon = new GovernorBeacon(govImpl, DEFAULT_SENDER);
        SyndicateFactory factoryImpl = new SyndicateFactory();
        bytes memory factoryInit = abi.encodeCall(
            SyndicateFactory.initialize,
            (SyndicateFactory.InitParams({
                    owner: DEFAULT_SENDER,
                    executorImpl: address(new BatchExecutorLib()),
                    vaultImpl: address(new SyndicateVault()),
                    ensRegistrar: address(0),
                    agentRegistry: address(0),
                    beacon: address(beacon),
                    protocolConfig: address(protocolConfig),
                    managementFeeBps: 50,
                    guardianRegistry: address(registry)
                }))
        );
        factory = SyndicateFactory(address(new ERC1967Proxy(address(factoryImpl), factoryInit)));

        script = new DeployPlanB();
        // Hoisted out of the `_setBook` argument list: an external call sitting
        // in argument position is evaluated FIRST and would eat any pending
        // one-shot cheatcode. Nothing is armed here today; the habit is what
        // stops the next edit from being the one that breaks.
        bookMaxStrategyDuration = script.DEFAULT_MAX_STRATEGY_DURATION();
        bookHaircutBps = script.DEFAULT_WOOD_HAIRCUT_BPS();
        // OWNED BY `DEFAULT_SENDER`, not the test contract — see
        // `PlanBScriptCaller`'s own natspec for why.
        vm.etch(DEFAULT_SENDER, address(new PlanBScriptCaller()).code);

        _setBook(address(swood), address(registry), address(factory));
    }

    // ─────────────────────────── the happy path ───────────────────────────

    /// @dev B3 (1): A FIRST DEPLOY MUST RUN. This is the exact state the old
    ///      pre-flight could not be satisfied from — sWOOD's pointer is zero
    ///      and the only ledger this deployment will ever have does not exist
    ///      yet. The script now wires it inside the broadcast, so the run
    ///      completes and leaves the gate armed.
    function test_deploy_armsTheExitGateFromAVirginState() public {
        assertEq(swood.exposureLedger(), address(0), "fixture must start with the gate unarmed");

        _run();

        address ledger = swood.exposureLedger();
        assertTrue(ledger != address(0), "the deploy must arm the unstake gate");
        assertEq(address(registry.exposureLedger()), ledger, "registry must book into the same ledger");
        assertEq(factory.exposureLedger(), ledger, "factory must issue against the same ledger");
        assertTrue(factory.bondEscrow() != address(0), "bond escrow must be wired");

        // The ledger really is this run's, not something pre-existing.
        assertEq(ExposureLedger(ledger).owner(), DEFAULT_SENDER, "ledger owner");
        assertEq(ExposureLedger(ledger).coveredTvlCapUsd(), COVERED_TVL_CAP, "ledger cap");
    }

    /// @dev B3 (2): THE OLD REMEDY'S END STATE MUST NOT SURVIVE. Reproduce it
    ///      exactly — an operator hand-deploys a ledger and points sWOOD at it
    ///      to get past a `!= address(0)` check — and prove the script no
    ///      longer leaves sWOOD reading that stale contract while the registry
    ///      and the factory book into a second one. Under the old code this
    ///      state PASSED, and every guardian then read `openExposureUsd == 0`
    ///      from a ledger holding none of this deployment's bookings.
    function test_deploy_repointsSwoodAwayFromAStaleLedger() public {
        ExposureLedger stale = new ExposureLedger(DEFAULT_SENDER, address(swood), 28 days);
        vm.prank(DEFAULT_SENDER);
        swood.setExposureLedger(address(stale));

        _run();

        address ledger = swood.exposureLedger();
        assertTrue(ledger != address(stale), "sWOOD must not be left on the stale ledger");
        assertEq(address(registry.exposureLedger()), ledger, "the three pointers must agree");
        assertEq(factory.exposureLedger(), ledger, "the three pointers must agree");
    }

    /// @dev PRE-FLIGHT 4 passes at the shipped default. Kept as a live check
    ///      rather than a comment: if `ExposureLedger`'s default ever drifts
    ///      off 0, every Plan B deploy starts refusing and this names why.
    function test_deploy_defaultQuorumTierThresholdPasses() public {
        _run();
        assertEq(
            ExposureLedger(swood.exposureLedger()).quorumTierThreshold(),
            0,
            "default must be 0 or pre-flight 4 refuses every deploy"
        );
    }

    // ──────────────────────── the pre-flights bite ────────────────────────

    /// @dev PRE-FLIGHT 2b: the broadcaster must own sWOOD, or it cannot make
    ///      the `setExposureLedger` call the fix relies on. Checked BEFORE the
    ///      broadcast, so the refusal costs nothing and names the remedy
    ///      instead of surfacing as an opaque `OwnableUnauthorizedAccount`
    ///      from inside a half-finished deployment.
    function test_preflight_bites_whenBroadcasterDoesNotOwnStakedWood() public {
        vm.prank(DEFAULT_SENDER);
        swood.transferOwnership(address(0xBEEF)); // plain Ownable: immediate

        _runExpecting("PRE-FLIGHT: broadcaster does not own STAKED_WOOD");

        assertEq(swood.exposureLedger(), address(0), "a refused deploy must not have wired anything");
        assertEq(address(registry.exposureLedger()), address(0), "a refused deploy must not have wired anything");
    }

    /// @dev PRE-FLIGHT 1b: a slash ceiling below 10_000 clips the allocation
    ///      the ledger books at 100% of. `setMaxSlashBps` accepts 9_999, so no
    ///      storage poke is needed to reach the violating state.
    function test_preflight_bites_whenMaxSlashBpsIsBelowTheCeiling() public {
        vm.prank(DEFAULT_SENDER);
        swood.setMaxSlashBps(9_999);
        _runExpecting("PRE-FLIGHT: sWOOD maxSlashBps != 10000");
    }

    /// @dev PRE-FLIGHT 2: a zero covered-TVL cap is fail-closed — wired into a
    ///      governor, nothing could be proposed at all.
    function test_preflight_bites_whenCoveredTvlCapIsZero() public {
        bookCap = 0;
        _runExpecting("PRE-FLIGHT: COVERED_TVL_CAP_USD18 is 0");
    }

    /// @dev PRE-FLIGHT 3 (sWOOD leg) — THE SECURITY GATE. The wiring call now
    ///      happens inside the broadcast, so the only way it fails to land is a
    ///      sWOOD that does not take it; `DeafStakedWood` makes that state
    ///      reachable. Without this assertion the deployment looks entirely
    ///      healthy while `claimUnstakeGuardian` fails open.
    function test_wiringCheck_bites_whenTheExitGateDidNotLand() public {
        DeafStakedWood deaf = new DeafStakedWood(DEFAULT_SENDER);
        _setBook(address(deaf), address(registry), address(factory));
        _runExpecting("PRE-FLIGHT: sWOOD exposureLedger != the ledger just deployed");
    }

    /// @dev PRE-FLIGHT 3 (registry leg). Asserted in the SAME block as the
    ///      sWOOD leg because booking and gating are one mechanism: a registry
    ///      that books into a different ledger than sWOOD reads is the same
    ///      hole approached from the other side.
    function test_wiringCheck_bites_whenTheRegistryDidNotTakeTheLedger() public {
        DeafGuardianRegistry deaf = new DeafGuardianRegistry();
        _setBook(address(swood), address(deaf), address(factory));
        _runExpecting("WIRING: GuardianRegistry.exposureLedger != the ledger just deployed");
    }

    /// @dev PRE-FLIGHT 3 (factory leg). New syndicates would be issued against
    ///      a different ledger than the one the exit gate reads.
    function test_wiringCheck_bites_whenTheFactoryDidNotTakeTheLedger() public {
        DeafSyndicateFactory deaf = new DeafSyndicateFactory();
        _setBook(address(swood), address(registry), address(deaf));
        _runExpecting("WIRING: SyndicateFactory.exposureLedger != the ledger just deployed");
    }

    // ───────────── pre-flight 5: the beacon guard (review M5) ─────────────

    /// @dev THE GUARD BITES. A factory reporting live governor proxies whose
    ///      beacon still serves a PRE-Plan B governor is refused outright.
    ///
    ///      This is not hypothetical: Robinhood testnet (46630) has 9
    ///      `SyndicateCreated` events on factory 0xB9E7..7cce, and a sampled
    ///      governor's ERC-1967 beacon slot reads the recorded beacon
    ///      0x11B726c49E0bAc95bEafF8d648cf3030Dc11B73a. Before this guard the
    ///      script printed "MANUAL NEXT: governor beacon upgrade,
    ///      factory.pushWiring(<each existing governor>)" unconditionally — an
    ///      instruction that on that chain re-points 9 live proxies at an impl
    ///      where every field moved (`vault` 0 -> 15, `_guardianRegistry`
    ///      43 -> 0, `_tierRegistry` 48 -> 58).
    function test_preflight_bites_whenLiveGovernorsSitOnAPrePlanBBeacon() public {
        GovernorBeacon legacyBeacon = new GovernorBeacon(address(new PrePlanBGovernor()), DEFAULT_SENDER);
        CountingSyndicateFactory legacyFactory = new CountingSyndicateFactory(9, address(legacyBeacon));
        _setBook(address(swood), address(registry), address(legacyFactory));

        _runExpecting("PRE-FLIGHT: SYNDICATE_FACTORY has live governor proxies on a PRE-PLAN-B governor");

        // Refused BEFORE the broadcast: nothing was deployed and nothing wired.
        assertEq(swood.exposureLedger(), address(0), "a refused deploy must not have wired anything");
        assertEq(address(registry.exposureLedger()), address(0), "a refused deploy must not have wired anything");
        assertEq(legacyFactory.exposureLedger(), address(0), "a refused deploy must not have wired anything");
    }

    /// @dev THE PROBE IS FAIL-CLOSED. An unreadable beacon (here: no code at
    ///      all, standing in for a mis-recorded address, a self-destructed
    ///      beacon, or anything that is not an `UpgradeableBeacon`) counts as
    ///      "not Plan B-capable" and is refused, rather than being waved
    ///      through on an unanswered question.
    function test_preflight_bites_whenTheBeaconCannotBeProbed() public {
        address notABeacon = address(0xB3AC0);
        assertEq(notABeacon.code.length, 0, "fixture must be code-less");

        CountingSyndicateFactory legacyFactory = new CountingSyndicateFactory(9, notABeacon);
        _setBook(address(swood), address(registry), address(legacyFactory));

        _runExpecting("PRE-FLIGHT: SYNDICATE_FACTORY has live governor proxies on a PRE-PLAN-B governor");
    }

    /// @dev AND IT DOES NOT OVER-REFUSE. Having syndicates is not by itself the
    ///      problem — a chain whose beacon ALREADY serves a Plan B-capable
    ///      governor needs no upgrade at all, so `pushWiring` finishes the job
    ///      and the run must proceed. This is the ordinary "Plan A from this
    ///      stack, then Plan B" path; refusing it would gate legitimate work on
    ///      a condition that has nothing to do with the hazard.
    function test_deploy_allowedWhenLiveGovernorsSitOnAPlanBCapableBeacon() public {
        GovernorBeacon capableBeacon =
            new GovernorBeacon(address(new SyndicateGovernor(24 hours, 1 hours)), DEFAULT_SENDER);
        CountingSyndicateFactory populated = new CountingSyndicateFactory(9, address(capableBeacon));
        _setBook(address(swood), address(registry), address(populated));

        _run();

        address ledger = swood.exposureLedger();
        assertTrue(ledger != address(0), "the deploy must arm the unstake gate");
        assertEq(populated.exposureLedger(), ledger, "the populated factory must be wired");
        assertTrue(populated.bondEscrow() != address(0), "bond escrow must be wired");
    }

    /// @dev A ZERO COUNT DOES NOT TRIGGER THE GUARD, and specifically does not
    ///      trigger it even behind a PRE-Plan B beacon. That pairing is the
    ///      point: with no live proxies there is nothing an impl swap can
    ///      corrupt, so the beacon's current implementation is irrelevant and
    ///      the probe is skipped entirely. A guard keyed on the beacon alone
    ///      would refuse this — the state every fresh chain, mainnet 4663
    ///      included, actually deploys from.
    function test_preflight_passes_whenTheFactoryHasNoSyndicates() public {
        GovernorBeacon legacyBeacon = new GovernorBeacon(address(new PrePlanBGovernor()), DEFAULT_SENDER);
        CountingSyndicateFactory freshFactory = new CountingSyndicateFactory(0, address(legacyBeacon));
        _setBook(address(swood), address(registry), address(freshFactory));

        _run();

        assertEq(freshFactory.exposureLedger(), swood.exposureLedger(), "a fresh factory must be wired normally");
    }

    // ───── pre-flights 6 and 7: the two seated invariants (issue #32) ─────

    /// @dev PRE-FLIGHT 6, DEFAULT RUN. The ceiling is SEATED by the deploy, not
    ///      left to a follow-up transaction — a `maxStrategyDuration` an operator
    ///      is merely told to set afterwards is one that ships at 0, and 0 means
    ///      NO ceiling: a vault owner could then seat their own
    ///      `maxStrategyDuration` up to `ABSOLUTE_MAX_STRATEGY_DURATION` (3,650
    ///      days) and bind the approving guardians for a decade per approval.
    ///
    ///      `bookMaxStrategyDuration` holds exactly what an UNSET
    ///      `MAX_STRATEGY_DURATION` yields in `run()` (`vm.envOr` falls back to
    ///      this constant), so this is the default run. The env read itself stays
    ///      untested here for the reason the whole suite avoids `run()` — see
    ///      `_setBook`.
    function test_deploy_seatsTheProtocolDurationCeiling() public {
        assertEq(protocolConfig.maxStrategyDuration(), 0, "fixture must start with no ceiling");
        assertEq(bookMaxStrategyDuration, 30 days, "the documented default");

        _run();

        assertEq(protocolConfig.maxStrategyDuration(), 30 days, "the deploy must seat the ceiling");
    }

    /// @dev PRE-FLIGHT 6, ZERO OVERRIDE. 0 is a LEGAL argument to
    ///      `setMaxStrategyDuration` — it is how the parameter is unset — so
    ///      without this check an operator could route an explicit "no ceiling"
    ///      through the very script that exists to prevent one, and it would read
    ///      as a deliberate configuration rather than as the omission it
    ///      reproduces. Refused BEFORE the broadcast, so it costs nothing.
    function test_preflight_bites_whenTheDurationCeilingIsZero() public {
        bookMaxStrategyDuration = 0;

        _runExpecting("PRE-FLIGHT: MAX_STRATEGY_DURATION is 0");

        assertEq(swood.exposureLedger(), address(0), "a refused deploy must not have wired anything");
        assertEq(protocolConfig.maxStrategyDuration(), 0, "a refused deploy must not have seated anything");
    }

    /// @dev PRE-FLIGHT 7 BITES. `StakedWood` no longer HAS `delegationEnabled()`
    ///      — the `StakedWoodDelegation` base was removed pre-mainnet — so the
    ///      state under test is not reachable through the current contract at
    ///      all. It is still the state this script must refuse: `DeployPlanB`
    ///      runs against an EXISTING sWOOD proxy, and a chain still serving a
    ///      pre-removal implementation answers this selector for real.
    ///
    ///      Mocked rather than stubbed on purpose. A stub sWOOD would have to
    ///      re-implement everything the script reads and writes, and the
    ///      resulting test would prove the assertion fires on a contract that is
    ///      not `StakedWood`. Mocking one selector onto the REAL fixture makes
    ///      the claim the sharp one: the same deployment that passes every other
    ///      test in this file is refused the moment that selector answers true.
    function test_preflight_bites_whenDelegationIsOn() public {
        vm.mockCall(address(swood), abi.encodeWithSignature("delegationEnabled()"), abi.encode(true));

        _runExpecting("PRE-FLIGHT: sWOOD reports delegationEnabled == true");
    }

    /// @dev PRE-FLIGHT 7 DOES NOT OVER-REFUSE. A sWOOD answering `false` runs
    ///      normally. The OTHER passing shape — no such selector at all, which is
    ///      what every current `StakedWood` presents and what every other passing
    ///      test in this suite therefore exercises — is asserted here too, since
    ///      the probe treats an absent selector as "off": code that does not
    ///      exist cannot be enabled, which is strictly stronger than a flag
    ///      reading false.
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
    // Finding 2. Under design revision 2 `woodUsdPriceX8` is a CAP that is
    // never served as a price, so a deployment can be misconfigured in two
    // independent ways that both leave every price read reverting
    // `NoWoodPrice` — nothing proposable, executable or challengeable — while
    // every other pre-flight in this file passes. Each gets its own assert, and
    // each gets its own test, because the operator's remedy differs.

    /// @dev (a) The CAP is unset. A zero cap is not "uncapped"; it is a revert.
    function test_preflight_bites_whenTheWoodPriceCapIsZero() public {
        bookCapPriceX8 = 0;
        _runExpecting("PRE-FLIGHT: ExposureLedger.woodUsdPriceX8 is 0");
    }

    /// @dev (b) The CAP is set but nothing prices under it. This is the shape a
    ///      cap-only check would MISS: `woodUsdPriceX8 != 0` proves the ceiling
    ///      is configured and says nothing about whether anything is priced
    ///      beneath it. Chain 4663 has no Chainlink WOOD/USD feed, so with no
    ///      oracle wired the ledger has no source at all.
    function test_preflight_bites_whenNoWoodPriceSourceIsWired() public {
        bookTwapOracle = address(0);
        _runExpecting("PRE-FLIGHT: ExposureLedger.woodPriceX8() does not resolve");
    }

    /// @dev (c) The oracle is wired but has no completed averaging window yet —
    ///      the operationally likely mistake, since `WoodTwapOracle` needs at
    ///      least `twapWindow` of keeper activity before `consult()` answers.
    ///      Refused, which is what forces the deploy-and-prime-first ordering.
    function test_preflight_bites_whenTheOracleHasNoCompletedWindowYet() public {
        MockWoodTwapOracle(bookTwapOracle).setAvailable(false);
        _runExpecting("PRE-FLIGHT: ExposureLedger.woodPriceX8() does not resolve");
    }

    /// @dev The passing shape, asserted on the DEPLOYED state rather than on
    ///      the book: the oracle landed, the cap landed, and the composed price
    ///      is the MARKET — proving the cap was seeded above it and is not
    ///      binding, which is the configuration production ships.
    function test_deploy_wiresTheOracleAndPricesOffTheMarket() public {
        _run();

        ExposureLedger ledger = ExposureLedger(swood.exposureLedger());
        assertEq(ledger.woodTwapOracle(), bookTwapOracle, "the oracle must be wired by the script");
        assertEq(ledger.woodUsdPriceX8(), WOOD_PRICE_CAP_X8, "the cap must land");
        // Market-priced, THEN discounted by the seated allowance. The cap sits
        // above the market and so plays no part in the number.
        assertEq(
            ledger.woodPriceX8(),
            (WOOD_MARKET_X8 * DeployPlanB(script).DEFAULT_WOOD_HAIRCUT_BPS()) / 10_000,
            "priced off the market, with the cap above it and the haircut applied"
        );
        (,, bool capBinding) = ledger.woodPriceDetail();
        assertFalse(capBinding, "a cap seeded BELOW market would bind and make the oracle inert");
    }

    // ── PRE-FLIGHT 9: a real haircut allowance must exist ──────────────────

    /// @dev THE LEDGER'S OWN DEFAULT IS THE FAILING VALUE, which is what makes
    ///      this check worth having. `woodHaircutBps` ships at 10,000 — no
    ///      haircut — and the ledger's setter ACCEPTS 10,000 as a legal value,
    ///      so nothing else in the stack refuses the one configuration with
    ///      zero allowance against the accepted overstatements. Left unchecked
    ///      it ships silently and looks entirely healthy.
    function test_preflight_bites_whenTheHaircutLeavesNoAllowance() public {
        bookHaircutBps = 10_000;
        _runExpecting("PRE-FLIGHT: ExposureLedger.woodHaircutBps is 10000");
    }

    /// @dev The shipped value, asserted on the DEPLOYED state and pinned to the
    ///      script's own constant so the two cannot drift. 7,000 is a 30%
    ///      allowance; 5,000 (the ledger floor) was rejected as too costly to
    ///      guardian return on equity.
    function test_deploy_seatsTheShippedHaircut() public {
        assertEq(script.DEFAULT_WOOD_HAIRCUT_BPS(), 7_000, "the shipped haircut is 7,000 -- a 30% allowance");

        _run();

        ExposureLedger ledger = ExposureLedger(swood.exposureLedger());
        assertEq(ledger.woodHaircutBps(), 7_000, "the haircut must be seated by the script, not left at 10,000");

        // It is a real discount on a real valuation, not a stored number: the
        // composed price is 70% of what the market source reports.
        assertEq(ledger.woodPriceX8(), (WOOD_MARKET_X8 * 7_000) / 10_000, "the allowance reaches the price");
    }

    /// @dev An operator override is honoured, and the floor still binds. The
    ///      ledger's own setter rejects anything under 5,000 mid-broadcast, so
    ///      this proves the script does not quietly widen the range.
    function test_deploy_honoursAHaircutOverrideAndRespectsTheFloor() public {
        bookHaircutBps = 6_000;
        _run();
        assertEq(ExposureLedger(swood.exposureLedger()).woodHaircutBps(), 6_000, "an override must be seated");
    }

    // ─────────────── pre-flight 10: the ledger owner (issue #89) ───────────────
    //
    // WHAT THESE TWO TESTS ESTABLISH, AND WHAT THEY DELIBERATELY DO NOT.
    //
    // Issue #89 deleted the in-contract rate limit on `setWoodUsdPrice` and
    // `setWoodHaircutBps` and moved it to a Zodiac Delay/Roles module on the
    // owner Safe. Pre-flight 10 is the only on-chain trace of that requirement,
    // and it checks exactly one thing: the ledger owner is a CONTRACT, not a
    // bare EOA. These tests pin that, and nothing more.
    //
    // DO NOT "IMPROVE" THIS INTO A MODULE PROBE. That was considered and
    // rejected on the merged design, and `openspec/specs/deployment-docs/spec.md`
    // records the reasoning: pre-flight 10
    //
    //   "deliberately does not probe for modules: enumerating a Safe's modules
    //    would prove only that *some* module is attached, not that the delay is
    //    asymmetric, and a probe that appears to verify the requirement while
    //    verifying something weaker is worse than none."
    //
    // The property that actually matters — the delay must be ASYMMETRIC, raises
    // delayed and drops immediate — is not expressible on chain at all, because
    // a Roles modifier cannot compare an argument against current on-chain
    // state. It stays a runbook obligation verified by a human before launch.
    // A test asserting `getModulesPaginated` returns a non-empty page would look
    // like coverage of the Zodiac requirement while covering something strictly
    // weaker, which is the failure mode the spec is warning about.

    /// @dev THE PASSING BRANCH. The harness etches a forwarder at
    ///      `DEFAULT_SENDER` (see `PlanBScriptCaller`), so the broadcaster — and
    ///      therefore the ledger owner — genuinely has code, which is the shape
    ///      pre-flight 10 is built to accept.
    ///
    ///      This test also PINS THE CREATE PREDICTION that the EOA test below
    ///      depends on. The ledger is the first contract the broadcaster creates
    ///      inside `vm.startBroadcast` (`DeployPlanB.s.sol:531`), so its address
    ///      is `computeCreateAddress(DEFAULT_SENDER, nonce)`. Asserting it here
    ///      means a broken prediction is diagnosed by THIS test, rather than
    ///      surfacing as a mysteriously silent mock in the next one.
    function test_preflight10_passes_whenTheLedgerOwnerIsAContract() public {
        address predicted = vm.computeCreateAddress(DEFAULT_SENDER, vm.getNonce(DEFAULT_SENDER));

        _run();

        address ledger = swood.exposureLedger();
        assertEq(ledger, predicted, "ledger must be the broadcaster's first CREATE -- the EOA test relies on it");
        assertEq(ExposureLedger(ledger).owner(), DEFAULT_SENDER, "the broadcaster owns the ledger it deployed");
        assertTrue(DEFAULT_SENDER.code.length != 0, "pre-flight 10's condition: the owner is a contract");
    }

    /// @dev THE REFUSING BRANCH, and the state a real deployment starts in:
    ///      `DeployPlanB` deploys the ledger owned by the broadcaster, so a run
    ///      from a plain deployer key leaves an EOA owning both price levers.
    ///      With the in-contract limit gone that deployment carries NEITHER the
    ///      on-chain control nor the off-chain one — and nothing in the source
    ///      would hint anything is missing. Hence the refusal.
    ///
    ///      THE OWNER IS THE BROADCASTER, so this makes the broadcaster a
    ///      genuine EOA rather than faking the read. The forwarder the other
    ///      tests need exists only to make `deployer == msg.sender` equal the
    ///      broadcast sender; here both are `DEFAULT_SENDER` already, so its
    ///      code can be stripped and the call pranked from that same address —
    ///      the owner-gated setters in the broadcast still run as the owner,
    ///      and the run reaches the pre-flight for the right reason.
    ///
    ///      Mocking the ledger's `owner()` instead does NOT work, and the reason
    ///      is worth recording: `vm.mockCall` gives the target account code, so
    ///      mocking the not-yet-deployed ledger address makes the script's
    ///      `new ExposureLedger(...)` collide with it and revert with no reason
    ///      string — a failure that looks nothing like the refusal under test.
    function test_preflight10_bites_whenTheLedgerOwnerIsABareEOA() public {
        address predicted = vm.computeCreateAddress(DEFAULT_SENDER, vm.getNonce(DEFAULT_SENDER));
        address eoa = address(0xE0A);
        assertEq(eoa.code.length, 0, "the fixture must be a genuine EOA for this to mean anything");

        vm.mockCall(predicted, abi.encodeWithSignature("owner()"), abi.encode(eoa));
        // `vm.mockCall` gives the target account code, which would make the
        // script's `new ExposureLedger(...)` collide with this very address and
        // revert with no reason string (EIP-684). Clear the code again: the mock
        // registration survives, so the CREATE lands and the pre-flight still
        // reads the EOA.
        vm.etch(predicted, "");

        _runExpecting("PRE-FLIGHT: ExposureLedger owner is an EOA, not a contract.");
    }

    /// @dev THE FORK BYPASS. A Tenderly vnet has no Safe and its deployer is an
    ///      impersonated EOA, so pre-flight 10 makes the fork ceremony in
    ///      openspec/specs/deployment-docs/spec.md unrunnable. `ALLOW_EOA_LEDGER_OWNER`
    ///      (surfaced here as `book.allowEoaLedgerOwner`) waives it.
    ///
    ///      SAME FIXTURE AS THE REFUSING TEST ABOVE, deliberately: identical
    ///      setup, one flag flipped, so what this pins is the flag and nothing
    ///      else. If the bypass ever stops covering exactly the branch that test
    ///      exercises, one of the two fails.
    ///
    ///      The flag rides in the `AddressBook` rather than being read from the
    ///      process environment inside `deploy()`. `vm.setEnv` writes one shared
    ///      mutable global that forge does not roll back between tests, so an
    ///      env-based bypass set here would leak into the sibling suites and
    ///      could turn the refusing test above green for the wrong reason.
    function test_preflight10_bypassedWhenTheForkFlagIsSet() public {
        address predicted = vm.computeCreateAddress(DEFAULT_SENDER, vm.getNonce(DEFAULT_SENDER));
        address eoa = address(0xE0A);
        assertEq(eoa.code.length, 0, "the fixture must be a genuine EOA for this to mean anything");

        vm.mockCall(predicted, abi.encodeWithSignature("owner()"), abi.encode(eoa));
        vm.etch(predicted, "");

        bookAllowEoaLedgerOwner = true;
        _run();

        assertEq(swood.exposureLedger(), predicted, "the run must complete and wire the exit gate");
    }

    /// @dev THE BYPASS CANNOT REACH PRODUCTION. An env var is not fork-only by
    ///      virtue of a comment saying so — it survives shell history, CI
    ///      secrets and copied command lines, and the deployment it produces
    ///      looks clean while carrying NEITHER the on-chain rate limit nor the
    ///      off-chain Zodiac one. Chain 4663 refuses it outright, which is what
    ///      lets the sibling test above stay green on 31337.
    function test_preflight10_bypassIsRefusedOnRobinhoodMainnet() public {
        address predicted = vm.computeCreateAddress(DEFAULT_SENDER, vm.getNonce(DEFAULT_SENDER));
        vm.mockCall(predicted, abi.encodeWithSignature("owner()"), abi.encode(address(0xE0A)));
        vm.etch(predicted, "");

        bookAllowEoaLedgerOwner = true;
        vm.chainId(4663);

        _runExpecting("ALLOW_EOA_LEDGER_OWNER is a fork/vnet escape hatch and MUST NOT be set on Robinhood");
    }

    // ─────────────────────────────── helpers ───────────────────────────────

    /// @dev THE ADDRESS BOOK IS PASSED, NOT SET IN THE ENVIRONMENT. `run()`'s
    ///      only job is to read `vm.envAddress`/`vm.envUint` into this struct,
    ///      and `vm.setEnv` writes the PROCESS environment — one shared mutable
    ///      global that forge does not roll back between tests and that every
    ///      parallel suite writes to. Driving the script through `run()` here
    ///      would race `DeployTokenCourtPreflight` and `DeployPlanDPreflight`
    ///      over `STAKED_WOOD` and lose (observed: all 9 of this suite's tests
    ///      failing on an address a sibling suite had just written, with an
    ///      undecodable `EvmError: Revert` from calling a code-less address).
    ///      `deploy()` takes the book directly, so nothing here is shared.
    function _setBook(address swood_, address registry_, address factory_) internal {
        bookSwood = swood_;
        bookRegistry = registry_;
        bookFactory = factory_;
    }

    function _book() internal view returns (DeployPlanB.AddressBook memory) {
        return DeployPlanB.AddressBook({
            swood: bookSwood,
            factory: bookFactory,
            registry: bookRegistry,
            wood: address(wood),
            usdg: address(usdg),
            usdgFeed: address(usdgFeed),
            feedMaxDelay: FEED_MAX_DELAY,
            woodPriceCapX8: bookCapPriceX8,
            woodHaircutBps: bookHaircutBps,
            coveredTvlCapUsd: bookCap,
            protocolConfig: address(protocolConfig),
            maxStrategyDuration: bookMaxStrategyDuration,
            woodTwapOracle: bookTwapOracle,
            allowEoaLedgerOwner: bookAllowEoaLedgerOwner
        });
    }

    function _run() internal {
        PlanBScriptCaller(DEFAULT_SENDER).fwd(address(script), abi.encodeCall(DeployPlanB.deploy, (_book())));
    }

    function _runExpecting(string memory prefix) internal {
        try PlanBScriptCaller(DEFAULT_SENDER).fwd(address(script), abi.encodeCall(DeployPlanB.deploy, (_book()))) {
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
