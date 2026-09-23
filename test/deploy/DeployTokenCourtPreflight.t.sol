// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {DeployTokenCourt} from "../../script/DeployTokenCourt.s.sol";
import {Stack} from "../../script/robinhood-mainnet/DeployTypes.sol";
import {TokenCourt} from "../../src/TokenCourt.sol";
import {ITokenCourt} from "../../src/interfaces/ITokenCourt.sol";
import {ChallengeGame} from "../../src/ChallengeGame.sol";
import {IChallengeGame} from "../../src/interfaces/IChallengeGame.sol";
import {StakedWood} from "../../src/StakedWood.sol";
import {ExposureLedger} from "../../src/ExposureLedger.sol";
import {TierRegistry} from "../../src/TierRegistry.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockStakedWood} from "../mocks/MockStakedWood.sol";
import {MockCoverageFreezer} from "../mocks/MockCoverageFreezer.sol";

/// @dev The mixin is abstract and its two phases are internal, so the suite drives them
///      through external wrappers. `Create3Factory.deploy` is `onlyOwner`, so the harness
///      must be both the deployer the fixtures are owned by and the caller — hence
///      `vm.prank(address(harness))` rather than a forwarder etched at `DEFAULT_SENDER`.
contract DeployTokenCourtHarness is DeployTokenCourt {
    function deployCourt(Stack memory s) external returns (address) {
        _deployCourt(s);
        return s.tokenCourt;
    }

    function wireCourt(Stack memory s) external {
        _wireCourt(s);
    }
}

/// @notice Drives the REAL court phases against a REAL `StakedWood`, `ExposureLedger`,
///         `TierRegistry`, `ChallengeGame` and `TokenCourt` (no stubs for the wired
///         contracts), then breaks one piece of state at a time and proves the
///         corresponding pre-flight bites. CI-runnable: no fork, no anvil, no env.
///
///         `_deployCourt` has no pre-flights — it only wires the court's own pointers.
///         Every pre-flight under test belongs to `_wireCourt`, the call that actually
///         hands the court ruling authority over the game.
contract DeployTokenCourtPreflightTest is Test {
    ERC20Mock internal wood;
    StakedWood internal swood;
    ExposureLedger internal ledger;
    TierRegistry internal tiers;
    ChallengeGame internal game;

    DeployTokenCourtHarness internal harness;
    address internal deployer;
    address internal courtAddr;

    /// @dev Matches `TokenCourtEndToEndTest`'s fixture and spec §5's launch-math example
    ///      (`participationFloorBps = 1_000` needs 40% of raw stake at this floor).
    uint256 internal constant AGE_FLOOR_BPS = 2_500;

    function setUp() public {
        harness = new DeployTokenCourtHarness();
        deployer = address(harness);

        wood = new ERC20Mock("WOOD", "WOOD", 18);

        StakedWood swoodImpl = new StakedWood();
        bytes memory swoodInit = abi.encodeCall(
            StakedWood.initialize,
            (StakedWood.InitParams({
                    owner: deployer,
                    wood: address(wood),
                    factory: address(this),
                    minGuardianStake: 10_000e18,
                    coolDownPeriod: 45 days,
                    minOwnerStake: 10_000e18,
                    minSlashBps: 1_000,
                    maxSlashBps: 10_000,
                    ageFloorBps: AGE_FLOOR_BPS,
                    maturationPeriod: 30 days
                }))
        );
        swood = StakedWood(address(new ERC1967Proxy(address(swoodImpl), swoodInit)));

        ledger = new ExposureLedger(deployer, address(swood), 28 days);
        tiers = new TierRegistry(deployer);
        game = new ChallengeGame(deployer, address(wood), address(ledger), address(tiers));

        // Plan D's wiring, as this phase presumes to find it, in the settle-before-freeze
        // order Plan D uses (review M3). Grant before pointing: `setStakedWood` refuses a
        // sWOOD that has not already named this game as its slasher (review M2).
        vm.startPrank(deployer);
        swood.setAuthorizedSlasher(address(game));
        game.setStakedWood(address(swood));
        tiers.setAuthorizedDemoter(address(game));
        ledger.setCoverageFreezer(address(game));
        vm.stopPrank();
    }

    // ───────────────────────── step 1: _deployCourt ─────────────────────────

    function test_deploy_configuresCourtButLeavesItInert() public {
        TokenCourt court = _runDeploy();

        assertEq(court.challengeGame(), address(game), "court.challengeGame");
        assertEq(court.stakedWood(), address(swood), "court.stakedWood");
        // Ownership stays with the deployer; `_handoffAll` moves it last.
        assertEq(court.owner(), deployer, "court.owner");
        assertEq(court.pendingOwner(), address(0), "the court phase must not start a handoff");

        // THE POINT OF SPLITTING THE PHASES: step 1 hands the court nothing. Until
        // `_wireCourt` runs, `rule` reverts `NotCourt` and a referred case cannot move a
        // single WOOD.
        assertEq(game.court(), address(0), "step 1 must not empower the court");
    }

    // ───────────────────────── step 2: _wireCourt ─────────────────────────

    function test_wire_defaultsWireSuccessfully() public {
        TokenCourt court = _runDeploy();

        _runWire();

        assertEq(game.court(), address(court), "game.court");
    }

    /// @dev PRE-FLIGHT 1: the court must point at the game and sWOOD it is wired to.
    function test_wirePreflight_bites_whenCourtPointsAtADifferentGame() public {
        TokenCourt court = _runDeploy();
        ChallengeGame other = new ChallengeGame(deployer, address(wood), address(ledger), address(tiers));
        vm.prank(deployer);
        court.setChallengeGame(address(other));
        _runWireExpecting("PRE-FLIGHT: TokenCourt.challengeGame/stakedWood != CHALLENGE_GAME/STAKED_WOOD.");
    }

    /// @dev PRE-FLIGHT 2: sWOOD identity must match on BOTH contracts. Broken from the
    ///      GAME's side (the court's own pointer is untouched), proving this check is
    ///      independent of pre-flight 1.
    /// @dev A REAL `IStakedWood` IMPLEMENTER, NOT A BARE ADDRESS: `setStakedWood` calls
    ///      `authorizedSlasher()` on the candidate, so a code-less address reverts in the
    ///      setter before this test reaches the pre-flight it means to exercise.
    function test_wirePreflight_bites_whenGameStakedWoodDiffersFromCourt() public {
        _runDeploy();
        // Hoisted: a call in argument position would consume the pending one-shot prank.
        address otherStakedWood = address(new MockStakedWood());
        // The reciprocal half of the slasher grant (review M2). Granted here so the test
        // reaches the WIRE pre-flight; the divergence it asserts on is between the game's
        // sWOOD and the court's, which the grant leaves untouched.
        MockStakedWood(otherStakedWood).setAuthorizedSlasher(address(game));
        vm.prank(deployer);
        game.setStakedWood(otherStakedWood);
        _runWireExpecting("PRE-FLIGHT: ChallengeGame.stakedWood != STAKED_WOOD.");
    }

    /// @dev PRE-FLIGHT 3a: the sum is violated from the GAME's side. `autoSlashDelay`
    ///      alone, raised but still `< disputeTimeout` (legal on its own setter), is
    ///      enough to push the sum past the default 30-day timeout.
    function test_wirePreflight_bites_whenAutoSlashDelayEatsTheWindow() public {
        _runDeploy();
        vm.prank(deployer);
        game.setAutoSlashDelay(25 days); // legal on its own: < disputeTimeout (30 days)

        assertEq(game.autoSlashDelay() + 5 days + 1 days, 31 days, "sum should exceed disputeTimeout");
        _runWireExpecting(
            "PRE-FLIGHT: autoSlashDelay + voteWindow + FINALIZE_BUFFER + MIN_REFERRAL_SLACK > disputeTimeout."
        );
    }

    /// @dev PRE-FLIGHT 3b: the sum is violated from the COURT's side instead, proving the
    ///      check reads BOTH contracts rather than only the game's parameters.
    function test_wirePreflight_bites_whenVoteWindowAtMaxOutlivesAShortTimeout() public {
        TokenCourt court = _runDeploy();
        vm.startPrank(deployer);
        court.setVoteWindow(court.MAX_VOTE_WINDOW()); // 14 days, legal on its own
        game.setDisputeTimeout(20 days); // legal on its own: > autoSlashDelay (7 days)
        vm.stopPrank();

        assertEq(game.autoSlashDelay() + court.voteWindow() + court.FINALIZE_BUFFER(), 22 days, "court span");
        assertEq(game.disputeTimeout(), 20 days, "shortened timeout");
        _runWireExpecting(
            "PRE-FLIGHT: autoSlashDelay + voteWindow + FINALIZE_BUFFER + MIN_REFERRAL_SLACK > disputeTimeout."
        );
    }

    /// @dev PRE-FLIGHT 3c: the exact boundary `sum == disputeTimeout` USED TO wire — the
    ///      pre-fix check was on the bare sum. Issue #181 finding 20 added
    ///      `MIN_REFERRAL_SLACK` (1 hour) of headroom, because exact equality left one
    ///      second to retry a dropped auto-referral and the disputer controls the stall
    ///      instant. The phase's own require now fires first, with the string reason, so
    ///      this routes through `_runWireExpecting` rather than the typed selector.
    function test_wire_rejectsTheExactBoundary() public {
        TokenCourt court = _runDeploy();
        uint256 bareSum = game.autoSlashDelay() + court.voteWindow() + court.FINALIZE_BUFFER();

        vm.prank(deployer);
        game.setDisputeTimeout(bareSum); // == autoSlashDelay(7d) + voteWindow(5d) + FINALIZE_BUFFER(1d)
        assertEq(
            game.autoSlashDelay() + court.voteWindow() + court.FINALIZE_BUFFER(),
            game.disputeTimeout(),
            "boundary, zero slack"
        );

        _runWireExpecting(
            "PRE-FLIGHT: autoSlashDelay + voteWindow + FINALIZE_BUFFER + MIN_REFERRAL_SLACK > disputeTimeout."
        );
        assertEq(
            game.court(), address(0), "the exact boundary must not wire - MIN_REFERRAL_SLACK closes the last second"
        );
    }

    /// @dev Companion to the above: the ON-CHAIN guard still independently refuses the
    ///      same boundary for a caller that skips the ceremony entirely (a manual
    ///      `cast send` against `setCourt`), so both layers stay covered.
    function test_setCourt_rejectsTheExactBoundary_whenScriptBypassed() public {
        TokenCourt court = _runDeploy();
        uint256 bareSum = game.autoSlashDelay() + court.voteWindow() + court.FINALIZE_BUFFER();

        vm.startPrank(deployer);
        game.setDisputeTimeout(bareSum);
        vm.expectRevert(IChallengeGame.WindowInvariantViolated.selector);
        game.setCourt(address(court));
        vm.stopPrank();

        assertEq(game.court(), address(0), "the exact boundary must not wire even calling setCourt directly");
    }

    function test_wire_acceptsWithSlack() public {
        TokenCourt court = _runDeploy();
        uint256 bareSum = game.autoSlashDelay() + court.voteWindow() + court.FINALIZE_BUFFER();

        vm.prank(deployer);
        game.setDisputeTimeout(bareSum + 1 days);

        _runWire();
        assertEq(game.court(), address(court), "sum + slack headroom must wire");
    }

    /// @dev PRE-FLIGHT 4: launch-math. Issue #84 guarded the court's own setters, so the
    ///      old route (`setParticipationFloorBps(AGE_FLOOR_BPS)`) now reverts before the
    ///      wire step (see the companion below). What this pre-flight still uniquely
    ///      covers is the side those setters CANNOT guard: `StakedWood.setAgeFloorBps`
    ///      LOWERING the age floor after deploy, which sWOOD holds no pointer to report.
    function test_wirePreflight_bites_whenParticipationFloorMeetsAgeFloor() public {
        TokenCourt court = _runDeploy();
        vm.prank(deployer);
        swood.setAgeFloorBps(1_000); // legal on sWOOD's own setter

        assertEq(court.participationFloorBps(), swood.ageFloorBps(), "floor should equal age floor, not be below it");
        _runWireExpecting("PRE-FLIGHT: TokenCourt.participationFloorBps >= StakedWood.ageFloorBps.");
    }

    /// @dev Companion: the OLD route to the violating state — raising
    ///      `participationFloorBps` on the court's own setter — is now dead.
    function test_setParticipationFloorBps_revertsFloorInvariantViolated_viaTheOldRoute() public {
        TokenCourt court = _runDeploy();
        vm.prank(deployer);
        vm.expectRevert(ITokenCourt.FloorInvariantViolated.selector);
        court.setParticipationFloorBps(AGE_FLOOR_BPS);
    }

    /// @dev PRE-FLIGHT 5 (a): Plan D's coverage-freezer role lost.
    function test_wirePreflight_bites_whenPlanDLostTheCoverageFreezer() public {
        _runDeploy();
        // Hoisted: a call in argument position would consume the prank.
        address stub = address(new MockCoverageFreezer(ledger.challengeWindow()));
        vm.prank(deployer);
        ledger.setCoverageFreezer(stub);
        _runWireExpecting("PRE-FLIGHT: ExposureLedger.coverageFreezer != CHALLENGE_GAME.");
    }

    /// @dev PRE-FLIGHT 5 (b): Plan D's demoter role lost.
    function test_wirePreflight_bites_whenPlanDLostTheDemoter() public {
        _runDeploy();
        vm.prank(deployer);
        tiers.setAuthorizedDemoter(address(0xDEAD));
        _runWireExpecting("PRE-FLIGHT: TierRegistry.authorizedDemoter != CHALLENGE_GAME.");
    }

    /// @dev PRE-FLIGHT 5 (c): Plan D's slasher role lost.
    function test_wirePreflight_bites_whenPlanDLostTheSlasherPointer() public {
        _runDeploy();
        vm.prank(deployer);
        swood.setAuthorizedSlasher(address(0xDEAD));
        _runWireExpecting("PRE-FLIGHT: StakedWood.authorizedSlasher != CHALLENGE_GAME.");
    }

    /// @dev A refused wiring leaves the game exactly where Plan D left it — unwired, so a
    ///      disputed challenge times out in favour of the accused. That benign fallback is
    ///      what makes refusing safe.
    function test_wire_leavesTheGameUnwired_whenAPreflightFails() public {
        _runDeploy();
        vm.prank(deployer);
        swood.setAuthorizedSlasher(address(0xDEAD));
        _runWireExpecting("PRE-FLIGHT: StakedWood.authorizedSlasher != CHALLENGE_GAME.");
        assertEq(game.court(), address(0), "a refused wiring must not half-wire the game");
    }

    /// @dev A `court` slot naming someone else is refused, not repointed — repointing is
    ///      how a stale court survives a re-run, and the live one loses ruling authority
    ///      with no event naming this ceremony as the cause.
    function test_wire_refusesAForeignCourtPointer() public {
        _runDeploy();
        // Hoisted: a call in argument position would consume the prank.
        address foreign = address(new TokenCourt(deployer));
        vm.prank(deployer);
        game.setCourt(foreign);

        _runWireExpecting("WIRING: ChallengeGame.court already names a foreign court");
        assertEq(game.court(), foreign, "the live slot must be left alone");
    }

    // ─────────────────────────────── helpers ───────────────────────────────

    /// @dev THE STACK IS PASSED, NOT SET IN THE ENVIRONMENT. The phases read no env at
    ///      all, so this suite touches none of the process-global environment forge does
    ///      not roll back between tests — it used to race its siblings over STAKED_WOOD.
    function _stack() internal view returns (Stack memory s) {
        s.core.swoodProxy = address(swood);
        s.core.tierRegistry = address(tiers);
        s.exposureLedger = address(ledger);
        s.challengeGame = address(game);
        s.tokenCourt = courtAddr;
    }

    /// @dev The stack is hoisted out of argument position: an external call there is
    ///      evaluated first and would eat the pending `vm.prank`.
    function _runDeploy() internal returns (TokenCourt court) {
        Stack memory s = _stack();
        vm.prank(deployer);
        courtAddr = harness.deployCourt(s);
        court = TokenCourt(courtAddr);
    }

    function _runWire() internal {
        Stack memory s = _stack();
        vm.prank(deployer);
        harness.wireCourt(s);
    }

    function _runWireExpecting(string memory prefix) internal {
        Stack memory s = _stack();
        vm.prank(deployer);
        try harness.wireCourt(s) {
            revert("wire pre-flight did not bite");
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
