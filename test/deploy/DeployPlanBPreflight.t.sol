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

    function setExposureLedger(address) external {}

    function setBondEscrow(address) external {}
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

    DeployPlanB internal script;

    uint256 internal constant FEED_MAX_DELAY = 1 days;
    uint256 internal constant WOOD_PRICE_X8 = 5e7; // $0.50, 8-dec
    uint256 internal constant COVERED_TVL_CAP = 1_000_000e18;

    // The address book the next script run should see. See `_book`.
    address internal bookSwood;
    address internal bookRegistry;
    address internal bookFactory;
    uint256 internal bookCap = COVERED_TVL_CAP;

    function setUp() public {
        wood = new ERC20Mock("WOOD", "WOOD", 18);
        usdg = new ERC20Mock("USDG", "USDG", 6);
        usdgFeed = new MockAggregatorV3(8, 1e8);

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

        ProtocolConfig protocolConfig = new ProtocolConfig(DEFAULT_SENDER);
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
            woodPriceX8: WOOD_PRICE_X8,
            coveredTvlCapUsd: bookCap
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
