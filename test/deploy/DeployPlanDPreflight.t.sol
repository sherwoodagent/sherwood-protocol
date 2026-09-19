// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {DeployPlanD} from "../../script/DeployPlanD.s.sol";
import {DeploySalts} from "../../script/DeploySalts.sol";
import {Create3} from "../../script/utils/Create3.sol";
import {ChallengeGame} from "../../src/ChallengeGame.sol";
import {ExposureLedger} from "../../src/ExposureLedger.sol";
import {StakedWood} from "../../src/StakedWood.sol";
import {TierRegistry} from "../../src/TierRegistry.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";
import {MockCoverageFreezer} from "../mocks/MockCoverageFreezer.sol";

/// @dev The mixin is abstract, and `Create3Factory.deploy` is `onlyOwner`, so the harness
///      must be both the deployer the fixtures are owned by and the caller of `deploy` —
///      hence `vm.prank(address(script))` everywhere instead of a forwarder.
contract DeployPlanDHarness is DeployPlanD {
    function c3Factory(address deployer) external returns (address) {
        return address(_c3Factory(deployer));
    }
}

/// @notice Drives the REAL Plan D phase against a REAL `StakedWood`, `ExposureLedger` and
///         `TierRegistry` from the state Plan B leaves behind, then breaks one piece of
///         that state at a time and proves the pre-flight refuses.
///
///         Two reviews are pinned here:
///           B4 — the phase never checked `swood.exposureLedger()`, so the game could
///                freeze commitments on a ledger the exit gate does not read. An accused
///                approver then unstakes inside `autoSlashDelay`, `_slashOne` recovers 0,
///                and `_settle` still marks `_convicted`.
///           M3 — the freeze role was granted FIRST and the settle pointer LAST. A
///                permissionless `file()` in that window freezes a key, which makes
///                `setCoverageFreezer` revert `CoverageFrozen` from then on.
contract DeployPlanDPreflightTest is Test {
    ERC20Mock internal wood;
    StakedWood internal swood;
    ExposureLedger internal ledger;
    TierRegistry internal tiers;

    DeployPlanDHarness internal script;
    address internal deployer;

    /// @dev The price CAP, $0.50 — never served as a price. The market sits below it, so
    ///      the cap does not bind (the production shape).
    uint256 internal constant WOOD_PRICE_CAP_X8 = 5e7;
    uint256 internal constant WOOD_MARKET_X8 = 2.5e7; // $0.25, 8-dec

    function setUp() public {
        script = new DeployPlanDHarness();
        deployer = address(script);

        wood = new ERC20Mock("WOOD", "WOOD", 18);

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
                    maxSlashBps: 10_000,
                    ageFloorBps: 2_500,
                    maturationPeriod: 30 days
                }))
        );
        swood = StakedWood(address(new ERC1967Proxy(address(swoodImpl), swoodInit)));

        ledger = new ExposureLedger(deployer, address(swood), 28 days);
        tiers = new TierRegistry(deployer);

        // The state Plan B leaves behind: the exit gate armed, the price CAP seeded and a
        // live market source under it. Without the source the ledger cannot price WOOD at
        // all and pre-flight 3 refuses.
        MockAggregatorV3 woodFeed = new MockAggregatorV3(8, int256(WOOD_MARKET_X8));
        vm.startPrank(deployer);
        ledger.setWoodUsdPrice(WOOD_PRICE_CAP_X8);
        // The mock publishes one round at construction and these suites warp far past it;
        // staleness is exercised in test/ExposureLedger.t.sol.
        ledger.setWoodFeed(address(woodFeed), type(uint64).max);
        swood.setExposureLedger(address(ledger));
        vm.stopPrank();
    }

    // ─────────────────────────── the happy path ───────────────────────────

    function test_deploy_wiresAllFourRoles() public {
        ChallengeGame game = _run();

        assertEq(ledger.coverageFreezer(), address(game), "coverageFreezer");
        assertEq(tiers.authorizedDemoter(), address(game), "authorizedDemoter");
        assertEq(swood.authorizedSlasher(), address(game), "authorizedSlasher");
        assertEq(address(game.stakedWood()), address(swood), "game.stakedWood");
        assertEq(address(game.exposureLedger()), address(ledger), "game.exposureLedger");
    }

    /// @notice The game lands at the address CREATE3 predicts from the salt alone — which
    ///         is what lets pre-flight 1 run BEFORE anything is minted.
    function test_deploy_mintsAtThePredictedCreate3Address() public {
        address predicted = _predictGame();

        ChallengeGame game = _run();

        assertEq(address(game), predicted, "the game must mint at its salt");
    }

    /// @dev M3: THE ORDER IS THE FIX, so assert the order and not merely the end state.
    ///      `setCoverageFreezer` must come after `game.setStakedWood` — until that pointer
    ///      exists `_settle` reverts `ZeroAddress`, and a challenge filed in between
    ///      freezes a key that makes `setCoverageFreezer` itself permanently un-callable.
    function test_deploy_grantsTheFreezeRoleLast() public {
        vm.recordLogs();
        _run();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 stakedWoodSetAt = type(uint256).max;
        uint256 freezerSetAt = type(uint256).max;
        bytes32 stakedWoodTopic = keccak256("StakedWoodSet(address,address)");
        bytes32 freezerTopic = keccak256("CoverageFreezerSet(address,address)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == stakedWoodTopic && stakedWoodSetAt == type(uint256).max) stakedWoodSetAt = i;
            if (logs[i].topics[0] == freezerTopic && freezerSetAt == type(uint256).max) freezerSetAt = i;
        }

        assertTrue(stakedWoodSetAt != type(uint256).max, "StakedWoodSet not emitted");
        assertTrue(freezerSetAt != type(uint256).max, "CoverageFreezerSet not emitted");
        assertLt(stakedWoodSetAt, freezerSetAt, "the ability to settle must exist BEFORE the ability to freeze");
    }

    /// @notice A SECOND RUN ADOPTS AND WRITES NOTHING. Pre-flight 1 passes because every
    ///         role already names the PREDICTED game, which is the resume case — the same
    ///         read that refuses a foreign holder.
    function test_deploy_secondCallAdoptsTheGameAndMintsNothing() public {
        ChallengeGame game = _run();
        bytes32 gameHash = address(game).codehash;

        vm.recordLogs();
        ChallengeGame again = _run();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(address(again), address(game), "the second run must adopt the same game");
        assertEq(address(game).codehash, gameHash, "nothing may be re-minted over it");
        assertEq(logs.length, 0, "a resumed run must send no state-changing call");
    }

    // ──────────────────────── the pre-flights bite ────────────────────────

    /// @dev B4 (a): sWOOD's pointer unset. This is the documented FAIL-OPEN state of
    ///      `claimUnstakeGuardian` — nothing reverts, the gate is simply skipped, and the
    ///      whole conviction path recovers zero.
    function test_preflight_bites_whenTheExitGateIsUnwired() public {
        vm.prank(deployer);
        swood.setExposureLedger(address(0));
        _runExpecting("PRE-FLIGHT: StakedWood.exposureLedger != EXPOSURE_LEDGER");
    }

    /// @dev B4 (b): sWOOD points at a DIFFERENT ledger. The reason the check is an
    ///      identity and not `!= address(0)`: a stale pointer passes a non-zero test while
    ///      holding none of this deployment's bookings.
    function test_preflight_bites_whenTheExitGateReadsADifferentLedger() public {
        ExposureLedger other = new ExposureLedger(deployer, address(swood), 28 days);
        vm.prank(deployer);
        swood.setExposureLedger(address(other));

        assertTrue(swood.exposureLedger() != address(0), "a non-zero check would have passed this state");
        _runExpecting("PRE-FLIGHT: StakedWood.exposureLedger != EXPOSURE_LEDGER");
    }

    /// @dev B4 (c): the refusal must be TOTAL — no role granted. A half-wired Plan D is
    ///      worse than none: the freeze role alone makes pre-flight 1 unsatisfiable.
    function test_preflight_leavesEveryRoleUnwired_whenTheExitGateIsUnwired() public {
        vm.prank(deployer);
        swood.setExposureLedger(address(0));
        _runExpecting("PRE-FLIGHT: StakedWood.exposureLedger != EXPOSURE_LEDGER");

        assertEq(ledger.coverageFreezer(), address(0), "coverageFreezer must be untouched");
        assertEq(tiers.authorizedDemoter(), address(0), "authorizedDemoter must be untouched");
        assertEq(swood.authorizedSlasher(), address(0), "authorizedSlasher must be untouched");
    }

    /// @dev PRE-FLIGHT 1: a role held by a FOREIGN address is refused, not rotated. Proven
    ///      on the freeze role, the one M3's reorder protects: once a filing freezes a key
    ///      the ledger refuses `setCoverageFreezer` outright.
    function test_preflight_bites_whenCoverageFreezerIsAlreadyHeld() public {
        // Hoisted: a call in argument position would consume the prank.
        address stub = address(new MockCoverageFreezer(ledger.challengeWindow()));
        vm.prank(deployer);
        ledger.setCoverageFreezer(stub);
        _runExpecting("PRE-FLIGHT: ExposureLedger.coverageFreezer already set.");
    }

    /// @dev PRE-FLIGHT 3: an unpriced ledger makes every `file()` revert, so the game
    ///      would deploy into a state where nothing can be challenged. Zero stays settable
    ///      on the ledger (it is the emergency stop), so no storage poke is needed.
    function test_preflight_bites_whenTheLedgerIsUnpriced() public {
        vm.prank(deployer);
        ledger.setWoodUsdPrice(0);
        _runExpecting("PRE-FLIGHT: ExposureLedger.woodPriceX8 is 0");
    }

    /// @notice PRE-FLIGHT 4: a deployer that does not own the ledger cannot grant the
    ///         freeze role, and the refusal lands BEFORE the game is minted rather than as
    ///         a mid-run `OwnableUnauthorizedAccount`.
    function test_preflight_bites_whenTheDeployerDoesNotOwnTheLedger() public {
        address predicted = _predictGame();

        vm.prank(deployer);
        ledger.transferOwnership(address(0xBEEF)); // Ownable2Step: owner() does not move yet
        vm.prank(address(0xBEEF));
        ledger.acceptOwnership();

        _runExpecting("PRE-FLIGHT: broadcaster does not own EXPOSURE_LEDGER");

        assertEq(predicted.code.length, 0, "refused BEFORE the mint: nothing was deployed");
        assertEq(swood.authorizedSlasher(), address(0), "and no role was granted");
    }

    // ─────────────────────────────── helpers ───────────────────────────────

    /// @dev THE ADDRESS BOOK IS PASSED, NOT SET IN THE ENVIRONMENT. `vm.setEnv` writes one
    ///      shared mutable global that forge does not roll back between tests, so an
    ///      env-driven suite races every sibling that seeds the same keys.
    function _book() internal view returns (DeployPlanD.PlanDBook memory) {
        return DeployPlanD.PlanDBook({
            swood: address(swood), wood: address(wood), ledger: address(ledger), tierRegistry: address(tiers)
        });
    }

    function _predictGame() internal returns (address) {
        return Create3.addressOf(script.c3Factory(deployer), DeploySalts.CHALLENGE_GAME);
    }

    /// @dev The book is hoisted out of argument position: an external call there is
    ///      evaluated first and would eat the pending `vm.prank`.
    function _run() internal returns (ChallengeGame game) {
        DeployPlanD.PlanDBook memory book = _book();
        vm.prank(deployer);
        game = ChallengeGame(script.deploy(book));
        require(address(game) != address(0), "the deploy script did not wire a game");
    }

    function _runExpecting(string memory prefix) internal {
        DeployPlanD.PlanDBook memory book = _book();
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
