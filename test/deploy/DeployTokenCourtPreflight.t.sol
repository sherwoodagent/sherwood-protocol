// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {DeployTokenCourt, WireTokenCourt} from "../../script/DeployTokenCourt.s.sol";
import {TokenCourt} from "../../src/TokenCourt.sol";
import {ChallengeGame} from "../../src/ChallengeGame.sol";
import {StakedWood} from "../../src/StakedWood.sol";
import {ExposureLedger} from "../../src/ExposureLedger.sol";
import {TierRegistry} from "../../src/TierRegistry.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";

/// @dev THE ONLY WAY TO RUN A SCRIPT AS ITS OWN BROADCASTER FROM A TEST.
///      `vm.startBroadcast()` executes the script's calls as forge's
///      `DEFAULT_SENDER`, while the script's `deployer = msg.sender` is
///      whoever called `run()`. In production those are the same address
///      (`--sender`); in a test they are not, and the court/game would be
///      owned by one address and configured by another. `vm.prank` cannot
///      bridge the gap — foundry refuses to broadcast while a prank is
///      active. So this etches a forwarder at `DEFAULT_SENDER` and calls
///      `run()` THROUGH it: no prank, and `msg.sender` inside the script is
///      the broadcaster, exactly as on a real deployment. Recovered idiom
///      from the deleted `test/deploy/DeployPlanEPreflight.t.sol`
///      (`git show 222ae21^`).
contract TokenCourtScriptCaller {
    function fwd(address target, bytes calldata data) external {
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }
}

/// @notice Drives the REAL `DeployTokenCourt` / `WireTokenCourt` script
///         contracts against a REAL `StakedWood`, `ExposureLedger`,
///         `TierRegistry`, `ChallengeGame` and `TokenCourt` (no stubs, no
///         mocks for the wired contracts), then breaks one piece of state at
///         a time and proves the corresponding pre-flight bites. This is the
///         CI-runnable form of "simulate the deploy" — no fork and no anvil
///         needed, and unlike a one-off manual anvil session it keeps biting
///         if someone later deletes a check.
///
///         `DeployTokenCourt` itself has no pre-flights (see the script's own
///         natspec) — it only wires the court's own pointers and starts the
///         ownership handoff. Every pre-flight under test here belongs to
///         `WireTokenCourt`, the transaction that actually hands the court
///         ruling authority over the game.
contract DeployTokenCourtPreflightTest is Test {
    ERC20Mock internal wood;
    StakedWood internal swood;
    ExposureLedger internal ledger;
    TierRegistry internal tiers;
    ChallengeGame internal game;

    DeployTokenCourt internal deployScript;
    WireTokenCourt internal wireScript;

    address internal constant PROTOCOL_OWNER = address(0xC0FFEE);

    /// @dev Matches `TokenCourtEndToEndTest`'s fixture value exactly — it is
    ///      also the number spec §5's launch-math example is worked against
    ///      (`participationFloorBps = 1_000` needs 40% of raw stake at this
    ///      floor), so re-using it keeps this file's boundary tests honest
    ///      against the same arithmetic the spec documents.
    uint256 internal constant AGE_FLOOR_BPS = 2_500;

    function setUp() public {
        wood = new ERC20Mock("WOOD", "WOOD", 18);

        StakedWood swoodImpl = new StakedWood();
        bytes memory swoodInit = abi.encodeCall(
            StakedWood.initialize,
            (StakedWood.InitParams({
                    owner: DEFAULT_SENDER,
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

        ledger = new ExposureLedger(DEFAULT_SENDER, address(swood), 28 days);
        tiers = new TierRegistry(DEFAULT_SENDER);
        game = new ChallengeGame(DEFAULT_SENDER, address(wood), address(ledger), address(tiers));

        // Plan D's wiring, as this deployment presumes to find it.
        vm.startPrank(DEFAULT_SENDER);
        ledger.setCoverageFreezer(address(game));
        tiers.setAuthorizedDemoter(address(game));
        swood.setAuthorizedSlasher(address(game));
        game.setStakedWood(address(swood));
        vm.stopPrank();

        deployScript = new DeployTokenCourt();
        wireScript = new WireTokenCourt();
        // OWNED BY `DEFAULT_SENDER`, not the test contract — see
        // `TokenCourtScriptCaller`'s own natspec for why.
        vm.etch(DEFAULT_SENDER, address(new TokenCourtScriptCaller()).code);

        _setEnv();
    }

    // ───────────────────────── step 1: DeployTokenCourt ─────────────────────────

    function test_deploy_configuresCourtButLeavesItInert() public {
        TokenCourt court = _runDeploy();

        assertEq(court.challengeGame(), address(game), "court.challengeGame");
        assertEq(court.stakedWood(), address(swood), "court.stakedWood");
        assertEq(court.pendingOwner(), PROTOCOL_OWNER, "court.pendingOwner");

        // THE POINT OF SPLITTING THE SCRIPTS: step 1 hands the court nothing.
        // Until WireTokenCourt runs, `rule` reverts `NotCourt` for it and a
        // referred case cannot move a single WOOD.
        assertEq(game.court(), address(0), "step 1 must not empower the court");
    }

    // ───────────────────────── step 2: WireTokenCourt ─────────────────────────

    function test_wire_defaultsWireSuccessfully() public {
        TokenCourt court = _deployAndSetCourtEnv();

        TokenCourtScriptCaller(DEFAULT_SENDER).fwd(address(wireScript), abi.encodeCall(WireTokenCourt.run, ()));

        assertEq(game.court(), address(court), "game.court");
    }

    /// @dev PRE-FLIGHT 1: the court must point at the game and sWOOD the
    ///      script is told to wire it to.
    function test_wirePreflight_bites_whenCourtPointsAtADifferentGame() public {
        TokenCourt court = _deployAndSetCourtEnv();
        ChallengeGame other = new ChallengeGame(DEFAULT_SENDER, address(wood), address(ledger), address(tiers));
        vm.prank(DEFAULT_SENDER);
        court.setChallengeGame(address(other));
        _runWireExpecting("PRE-FLIGHT: TokenCourt.challengeGame/stakedWood != CHALLENGE_GAME/STAKED_WOOD.");
    }

    /// @dev PRE-FLIGHT 2: sWOOD identity must match on BOTH contracts. Break
    ///      it from the GAME's side (the court's own pointer is untouched),
    ///      proving this check is independent of pre-flight 1.
    function test_wirePreflight_bites_whenGameStakedWoodDiffersFromCourt() public {
        _deployAndSetCourtEnv();
        vm.prank(DEFAULT_SENDER);
        game.setStakedWood(address(0xBEEF));
        _runWireExpecting("PRE-FLIGHT: ChallengeGame.stakedWood != STAKED_WOOD.");
    }

    /// @dev PRE-FLIGHT 3a: the sum is violated from the GAME's side.
    ///      `autoSlashDelay` alone, raised (but still `< disputeTimeout`, a
    ///      legal value on its own setter), is enough to push
    ///      `autoSlashDelay + voteWindow + FINALIZE_BUFFER` past the default
    ///      30-day `disputeTimeout`.
    function test_wirePreflight_bites_whenAutoSlashDelayEatsTheWindow() public {
        _deployAndSetCourtEnv();
        vm.prank(DEFAULT_SENDER);
        game.setAutoSlashDelay(25 days); // legal on its own: < disputeTimeout (30 days)

        assertEq(game.autoSlashDelay() + 5 days + 1 days, 31 days, "sum should exceed disputeTimeout");
        _runWireExpecting("PRE-FLIGHT: autoSlashDelay + voteWindow + FINALIZE_BUFFER > disputeTimeout.");
    }

    /// @dev PRE-FLIGHT 3b: the sum is violated from the COURT's side instead
    ///      — `voteWindow` raised to `MAX_VOTE_WINDOW` against a shortened
    ///      `disputeTimeout` — proving the check genuinely reads BOTH
    ///      contracts rather than only ever tripping on the game's own
    ///      parameters (3a already covers that side).
    function test_wirePreflight_bites_whenVoteWindowAtMaxOutlivesAShortTimeout() public {
        TokenCourt court = _deployAndSetCourtEnv();
        vm.startPrank(DEFAULT_SENDER);
        court.setVoteWindow(court.MAX_VOTE_WINDOW()); // 14 days, legal on its own
        game.setDisputeTimeout(20 days); // legal on its own: > autoSlashDelay (7 days)
        vm.stopPrank();

        assertEq(game.autoSlashDelay() + court.voteWindow() + court.FINALIZE_BUFFER(), 22 days, "court span");
        assertEq(game.disputeTimeout(), 20 days, "shortened timeout");
        _runWireExpecting("PRE-FLIGHT: autoSlashDelay + voteWindow + FINALIZE_BUFFER > disputeTimeout.");
    }

    /// @dev PRE-FLIGHT 3c: the exact boundary `sum == disputeTimeout` PASSES
    ///      and wires — proving the check is `<=`, not `<`. At the defaults
    ///      the sum is `7 + 5 + 1 = 13 days`; shortening `disputeTimeout` to
    ///      exactly that (still legal: `> autoSlashDelay`) must not refuse.
    function test_wire_acceptsTheExactBoundary() public {
        TokenCourt court = _deployAndSetCourtEnv();
        vm.prank(DEFAULT_SENDER);
        game.setDisputeTimeout(13 days); // == autoSlashDelay(7d) + voteWindow(5d) + FINALIZE_BUFFER(1d)

        assertEq(
            game.autoSlashDelay() + court.voteWindow() + court.FINALIZE_BUFFER(), game.disputeTimeout(), "boundary"
        );

        TokenCourtScriptCaller(DEFAULT_SENDER).fwd(address(wireScript), abi.encodeCall(WireTokenCourt.run, ()));
        assertEq(game.court(), address(court), "boundary must wire");
    }

    /// @dev PRE-FLIGHT 4: launch-math. `setParticipationFloorBps` allows any
    ///      value in `(0, 10_000]`, so raising it to `AGE_FLOOR_BPS` itself
    ///      (still a perfectly legal call on the court's own setter) is
    ///      enough to reach the violating state — no slot poke required.
    function test_wirePreflight_bites_whenParticipationFloorMeetsAgeFloor() public {
        TokenCourt court = _deployAndSetCourtEnv();
        vm.prank(DEFAULT_SENDER);
        court.setParticipationFloorBps(AGE_FLOOR_BPS); // no longer STRICTLY less than ageFloorBps

        assertEq(court.participationFloorBps(), swood.ageFloorBps(), "floor should equal age floor, not be below it");
        _runWireExpecting("PRE-FLIGHT: TokenCourt.participationFloorBps >= StakedWood.ageFloorBps.");
    }

    /// @dev PRE-FLIGHT 5 (a): Plan D's coverage-freezer role lost.
    function test_wirePreflight_bites_whenPlanDLostTheCoverageFreezer() public {
        _deployAndSetCourtEnv();
        vm.prank(DEFAULT_SENDER);
        ledger.setCoverageFreezer(address(0xDEAD));
        _runWireExpecting("PRE-FLIGHT: ExposureLedger.coverageFreezer != CHALLENGE_GAME.");
    }

    /// @dev PRE-FLIGHT 5 (b): Plan D's demoter role lost.
    function test_wirePreflight_bites_whenPlanDLostTheDemoter() public {
        _deployAndSetCourtEnv();
        vm.prank(DEFAULT_SENDER);
        tiers.setAuthorizedDemoter(address(0xDEAD));
        _runWireExpecting("PRE-FLIGHT: TierRegistry.authorizedDemoter != CHALLENGE_GAME.");
    }

    /// @dev PRE-FLIGHT 5 (c): Plan D's slasher role lost.
    function test_wirePreflight_bites_whenPlanDLostTheSlasherPointer() public {
        _deployAndSetCourtEnv();
        vm.prank(DEFAULT_SENDER);
        swood.setAuthorizedSlasher(address(0xDEAD));
        _runWireExpecting("PRE-FLIGHT: StakedWood.authorizedSlasher != CHALLENGE_GAME.");
    }

    /// @dev A refused wiring leaves the game exactly where DeployTokenCourt
    ///      left it — unwired, so a disputed challenge times out in favour of
    ///      the accused. That is the benign fallback, and it is what makes
    ///      refusing safe.
    function test_wire_leavesTheGameUnwired_whenAPreflightFails() public {
        _deployAndSetCourtEnv();
        vm.prank(DEFAULT_SENDER);
        swood.setAuthorizedSlasher(address(0xDEAD));
        _runWireExpecting("PRE-FLIGHT: StakedWood.authorizedSlasher != CHALLENGE_GAME.");
        assertEq(game.court(), address(0), "a refused wiring must not half-wire the game");
    }

    // ─────────────────────────────── helpers ───────────────────────────────

    /// @dev RE-SEEDED BEFORE EVERY SCRIPT RUN, not just in `setUp`. `vm.setEnv`
    ///      writes the PROCESS environment, which forge does not roll back
    ///      between tests the way it rolls back EVM state, and `setUp` runs
    ///      once per test but concurrently with every other test's `setUp` in
    ///      this contract. Re-seeding immediately before every script run
    ///      (matching the deleted `DeployPlanEPreflight.t.sol`'s idiom) is
    ///      what keeps the env addresses pointed at THIS test's fixture.
    function _setEnv() internal {
        vm.setEnv("CHALLENGE_GAME", vm.toString(address(game)));
        vm.setEnv("STAKED_WOOD", vm.toString(address(swood)));
        vm.setEnv("PROTOCOL_OWNER", vm.toString(PROTOCOL_OWNER));
        vm.setEnv("EXPOSURE_LEDGER", vm.toString(address(ledger)));
        vm.setEnv("TIER_REGISTRY", vm.toString(address(tiers)));
    }

    /// @dev Runs `DeployTokenCourt` and recovers the deployed court from the
    ///      `ChallengeGameSet` event's emitter — the script returns nothing,
    ///      and deriving the CREATE address would encode an assumption about
    ///      how broadcast interacts with nonces.
    function _runDeploy() internal returns (TokenCourt court) {
        _setEnv();
        vm.recordLogs();
        TokenCourtScriptCaller(DEFAULT_SENDER).fwd(address(deployScript), abi.encodeCall(DeployTokenCourt.run, ()));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("ChallengeGameSet(address,address)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == topic) return TokenCourt(logs[i].emitter);
        }
        revert("ChallengeGameSet not emitted - the deploy script did not wire the court");
    }

    function _deployAndSetCourtEnv() internal returns (TokenCourt court) {
        court = _runDeploy();
        vm.setEnv("COURT", vm.toString(address(court)));
    }

    function _runWireExpecting(string memory prefix) internal {
        _setEnv();
        try TokenCourtScriptCaller(DEFAULT_SENDER).fwd(address(wireScript), abi.encodeCall(WireTokenCourt.run, ())) {
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
