// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {DeployPlanE, WirePlanECourt} from "../../script/DeployPlanE.s.sol";
import {Court} from "../../src/Court.sol";
import {ChallengeGame} from "../../src/ChallengeGame.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockStakedWood} from "../mocks/MockStakedWood.sol";

/// @dev Exposure-ledger stub carrying only what the two scripts READ: the
///      coverage-freezer role Plan D granted. Settable so a test can revoke it
///      and prove the pre-flight refuses to empower a court whose ruling path
///      dead-ends.
contract PlanEDeployLedgerStub {
    address public coverageFreezer;

    function setCoverageFreezer(address freezer) external {
        coverageFreezer = freezer;
    }
}

/// @dev Tier-registry stub, same shape and same reason.
contract PlanEDeployTierRegistryStub {
    address public authorizedDemoter;

    function setAuthorizedDemoter(address demoter) external {
        authorizedDemoter = demoter;
    }
}

/// @dev THE ONLY WAY TO RUN A SCRIPT AS ITS OWN BROADCASTER FROM A TEST.
///      `vm.startBroadcast()` executes the script's calls as forge's
///      `DEFAULT_SENDER`, while the script's `deployer = msg.sender` is whoever
///      called `run()`. In production those are the same address (`--sender`);
///      in a test they are not, and the court would be owned by one address and
///      configured by another. `vm.prank` cannot bridge the gap — foundry
///      refuses to broadcast while a prank is active. So the test etches this
///      forwarder at `DEFAULT_SENDER` and calls `run()` THROUGH it: no prank,
///      and `msg.sender` inside the script is the broadcaster, exactly as on a
///      real deployment.
contract PlanEScriptCaller {
    function fwd(address target, bytes calldata data) external {
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }
}

/// @notice Drives the REAL `DeployPlanE` / `WirePlanECourt` script contracts
///         against a real `Court` and a real `ChallengeGame`, then breaks one
///         piece of state at a time and proves the corresponding pre-flight
///         bites. This is the CI-runnable form of "simulate the deploy" — no
///         fork and no anvil needed, and unlike a one-off manual anvil session
///         it keeps biting if someone later deletes a check.
///
///         The two scripts are split because only a panelist can post its own
///         bond (`postPanelBond` is `msg.sender`-scoped), so "every seat is
///         bonded" cannot be a precondition of the deployment — it is a
///         precondition of the WIRING, which is the transaction that actually
///         hands the court authority over 100% slashes.
contract DeployPlanEPreflightTest is Test {
    ERC20Mock internal wood;
    PlanEDeployLedgerStub internal ledger;
    PlanEDeployTierRegistryStub internal tiers;
    MockStakedWood internal swood;
    ChallengeGame internal game;

    DeployPlanE internal deployScript;
    WirePlanECourt internal wireScript;

    address internal constant PANELIST_A = address(0xA11CE);
    address internal constant PANELIST_B = address(0xB0B);
    address internal constant PANELIST_C = address(0xCA401);

    uint256 internal constant PANEL_BOND = 25_000e18;

    /// @dev `Court` storage slots for the two parameters whose SETTERS already
    ///      refuse zero (`setParticipationFloorBps`, `setBadFaithWindow`), so
    ///      there is no legitimate call that can break them. Poking the slot is
    ///      the only way to stand the state up and prove the wiring script
    ///      refuses it anyway — the pre-flight is defence in depth against a
    ///      future setter regression, and a check nobody has ever seen fire is
    ///      a check nobody knows works. Read from
    ///      `forge inspect Court storage-layout`.
    ///
    ///      THESE MOVE WHEN `Court` GAINS STATE. `participationFloorBps` shifted
    ///      22 -> 24 when the accused-exclusion fields landed. The assertions
    ///      below re-read the getter after the poke precisely so a stale slot
    ///      fails loudly here instead of silently testing nothing.
    uint256 internal constant SLOT_BAD_FAITH_WINDOW = 12;
    uint256 internal constant SLOT_PARTICIPATION_FLOOR_BPS = 24;

    function setUp() public {
        wood = new ERC20Mock("WOOD", "WOOD", 18);
        ledger = new PlanEDeployLedgerStub();
        tiers = new PlanEDeployTierRegistryStub();
        swood = new MockStakedWood();

        // OWNED BY `DEFAULT_SENDER`, not by the test contract, because that is
        // the address `vm.startBroadcast()` executes as inside a script run —
        // and the scripts' owner-only calls (`game.setCourt`, and every setter
        // on the court they create) would otherwise revert
        // `OwnableUnauthorizedAccount`. Pranking `run()` as the same address
        // keeps the script's `deployer = msg.sender` and its broadcaster
        // identical, which is exactly the production shape.
        game = new ChallengeGame(DEFAULT_SENDER, address(wood), address(ledger), address(tiers));

        // Plan D's wiring, as this deployment presumes to find it.
        vm.prank(DEFAULT_SENDER);
        game.setStakedWood(address(swood));
        ledger.setCoverageFreezer(address(game));
        tiers.setAuthorizedDemoter(address(game));

        deployScript = new DeployPlanE();
        wireScript = new WirePlanECourt();
        vm.etch(DEFAULT_SENDER, address(new PlanEScriptCaller()).code);

        _setEnv();
    }

    // ───────────────────────── step 1: DeployPlanE ─────────────────────────

    function test_deploy_configuresCourtButLeavesItInert() public {
        Court court = _runDeploy();

        assertEq(court.challengeGame(), address(game), "court.challengeGame");
        assertEq(court.stakedWood(), address(swood), "court.stakedWood");
        assertEq(court.panelSize(), 3, "panel size");
        assertEq(court.panelBondWood(), PANEL_BOND, "panel bond");
        assertEq(court.owner(), DEFAULT_SENDER, "court owner");

        // THE POINT OF SPLITTING THE SCRIPTS: step 1 hands the court nothing.
        // Until the panel is bonded and step 2 runs, `rule` reverts for it and a
        // referred case cannot move a single WOOD.
        assertEq(game.court(), address(0), "step 1 must not empower the court");
    }

    function test_deployPreflight_bites_whenGameAlreadyHasACourt() public {
        vm.prank(DEFAULT_SENDER);
        game.setCourt(address(0xDEAD));
        _runDeployExpecting("PRE-FLIGHT: ChallengeGame.court is already set.");
    }

    function test_deployPreflight_bites_whenGameHasNoSlasherPointer() public {
        vm.prank(DEFAULT_SENDER);
        game.setStakedWood(address(0xBEEF));
        _runDeployExpecting("PRE-FLIGHT: ChallengeGame.stakedWood != STAKED_WOOD.");
    }

    function test_deployPreflight_bites_whenCoverageFreezerIsNotTheGame() public {
        ledger.setCoverageFreezer(address(0xDEAD));
        _runDeployExpecting("PRE-FLIGHT: ExposureLedger.coverageFreezer != CHALLENGE_GAME.");
    }

    function test_deployPreflight_bites_whenDemoterIsNotTheGame() public {
        tiers.setAuthorizedDemoter(address(0xDEAD));
        _runDeployExpecting("PRE-FLIGHT: TierRegistry.authorizedDemoter != CHALLENGE_GAME.");
    }

    // THE TWO ENV-DERIVED PRE-FLIGHTS — an empty `COURT_PANEL` and a zero
    // `COURT_PANEL_BOND_WOOD` — ARE DELIBERATELY NOT TESTED HERE. `vm.setEnv`
    // mutates the PROCESS environment, which is shared by every test forge runs
    // concurrently, and forge executes the functions in a contract in parallel:
    // a test that empties `COURT_PANEL` to prove that check bites also empties
    // it under whichever sibling happens to be mid-run, so the suite passes or
    // fails on scheduling. Both were proven instead by running
    // `forge script script/DeployPlanE.s.sol:DeployPlanE` against a local anvil
    // with each variable broken in turn (simulation only, no --broadcast); the
    // empty-roster branch is additionally covered in-process at the wiring step
    // by `test_wirePreflight_bites_whenTheRosterWasEmptied`, which reads the
    // roster from contract state rather than the environment.

    // ──────────────────────── step 2: WirePlanECourt ────────────────────────

    function test_wire_grantsRulingAuthority_onceEverySeatIsBonded() public {
        Court court = _deployAndBondPanel();

        PlanEScriptCaller(DEFAULT_SENDER).fwd(address(wireScript), abi.encodeCall(WirePlanECourt.run, ()));

        assertEq(game.court(), address(court), "game.court");
    }

    function test_wirePreflight_bites_whenGameAlreadyHasACourt() public {
        _deployAndBondPanel();
        vm.prank(DEFAULT_SENDER);
        game.setCourt(address(0xDEAD));
        _runWireExpecting("PRE-FLIGHT: ChallengeGame.court is already set.");
    }

    function test_wirePreflight_bites_whenCourtPointsAtADifferentGame() public {
        Court court = _deployAndBondPanel();
        ChallengeGame other = new ChallengeGame(DEFAULT_SENDER, address(wood), address(ledger), address(tiers));
        vm.prank(DEFAULT_SENDER);
        court.setChallengeGame(address(other));
        _runWireExpecting("PRE-FLIGHT: Court.challengeGame != CHALLENGE_GAME.");
    }

    function test_wirePreflight_bites_whenCourtElectorateDisagrees() public {
        Court court = _deployAndBondPanel();
        address otherSwood = address(new MockStakedWood());
        vm.prank(DEFAULT_SENDER);
        court.setStakedWood(otherSwood);
        _runWireExpecting("PRE-FLIGHT: Court.stakedWood != STAKED_WOOD.");
    }

    /// @dev THE BOND CHECK IS THE ONE THAT MATTERS MOST. Two of three seats
    ///      bonded looks like a seated panel from every getter except this one,
    ///      and an unbonded member has nothing the bad-faith track can slash.
    function test_wirePreflight_bites_whenOneSeatIsUnbonded() public {
        Court court = _runDeploy();
        vm.setEnv("COURT", vm.toString(address(court)));
        _bond(court, PANELIST_A);
        _bond(court, PANELIST_B);
        // PANELIST_C never posts.
        _runWireExpecting("PRE-FLIGHT: a seated panelist has not posted its bond.");
    }

    function test_wirePreflight_bites_whenTheRosterWasEmptied() public {
        Court court = _runDeploy();
        vm.setEnv("COURT", vm.toString(address(court)));
        vm.prank(DEFAULT_SENDER);
        court.setPanel(new address[](0));
        _runWireExpecting("PRE-FLIGHT: Court panel is empty.");
    }

    /// @dev `setParticipationFloorBps` refuses zero, so this state is only
    ///      reachable by poking the slot. Proving the pre-flight bites anyway is
    ///      the whole value of a redundant check.
    function test_wirePreflight_bites_whenParticipationFloorIsZero() public {
        Court court = _deployAndBondPanel();
        vm.store(address(court), bytes32(SLOT_PARTICIPATION_FLOOR_BPS), bytes32(0));
        assertEq(court.participationFloorBps(), 0, "slot poke missed participationFloorBps");
        _runWireExpecting("PRE-FLIGHT: Court.participationFloorBps is 0.");
    }

    /// @dev Same, for the F6 track's window.
    function test_wirePreflight_bites_whenBadFaithWindowIsZero() public {
        Court court = _deployAndBondPanel();
        vm.store(address(court), bytes32(SLOT_BAD_FAITH_WINDOW), bytes32(0));
        assertEq(court.badFaithWindow(), 0, "slot poke missed badFaithWindow");
        _runWireExpecting("PRE-FLIGHT: Court.badFaithWindow is 0.");
    }

    /// @dev The check that is NOT in the plan. At the parameter ceilings the
    ///      court's three phases span 28 days; a `disputeTimeout` below that
    ///      lets the challenge time out and ACQUIT before a verdict can land, so
    ///      the court would be structurally unable to convict. Both halves are
    ///      set through legitimate owner setters here — this is a reachable
    ///      misconfiguration, not a hypothetical one.
    function test_wirePreflight_bites_whenCourtOutlivesTheDisputeTimeout() public {
        Court court = _deployAndBondPanel();
        vm.startPrank(DEFAULT_SENDER);
        court.setPanelWindow(14 days);
        court.setAppealWindow(7 days);
        court.setAppealVoteWindow(7 days);
        game.setDisputeTimeout(20 days);
        vm.stopPrank();

        assertEq(court.panelWindow() + court.appealWindow() + court.appealVoteWindow(), 28 days, "court span");
        _runWireExpecting("PRE-FLIGHT: panelWindow + appealWindow + appealVoteWindow > ");
    }

    /// @dev And the boundary passes: 28 days of court inside a 28-day timeout is
    ///      the tightest configuration that can still convict, so the check is
    ///      `<=` and not `<`.
    function test_wire_acceptsTheExactBoundary() public {
        Court court = _deployAndBondPanel();
        vm.startPrank(DEFAULT_SENDER);
        court.setPanelWindow(14 days);
        court.setAppealWindow(7 days);
        court.setAppealVoteWindow(7 days);
        game.setDisputeTimeout(28 days);
        vm.stopPrank();

        PlanEScriptCaller(DEFAULT_SENDER).fwd(address(wireScript), abi.encodeCall(WirePlanECourt.run, ()));
        assertEq(game.court(), address(court), "boundary must wire");
    }

    function test_wirePreflight_bites_whenPlanDLostTheSlasherPointer() public {
        _deployAndBondPanel();
        vm.prank(DEFAULT_SENDER);
        game.setStakedWood(address(0xBEEF));
        _runWireExpecting("PRE-FLIGHT: ChallengeGame.stakedWood != STAKED_WOOD.");
    }

    function test_wirePreflight_bites_whenPlanDLostTheCoverageFreezer() public {
        _deployAndBondPanel();
        ledger.setCoverageFreezer(address(0xDEAD));
        _runWireExpecting("PRE-FLIGHT: ExposureLedger.coverageFreezer != CHALLENGE_GAME.");
    }

    function test_wirePreflight_bites_whenPlanDLostTheDemoter() public {
        _deployAndBondPanel();
        tiers.setAuthorizedDemoter(address(0xDEAD));
        _runWireExpecting("PRE-FLIGHT: TierRegistry.authorizedDemoter != CHALLENGE_GAME.");
    }

    /// @dev A refused wiring leaves the game exactly where Plan D left it —
    ///      unwired, so a disputed challenge times out in favour of the accused.
    ///      That is the benign fallback, and it is what makes refusing safe.
    function test_wire_leavesTheGameUnwired_whenAPreflightFails() public {
        Court court = _runDeploy();
        vm.setEnv("COURT", vm.toString(address(court)));
        _bond(court, PANELIST_A);
        _runWireExpecting("PRE-FLIGHT: a seated panelist has not posted its bond.");
        assertEq(game.court(), address(0), "a refused wiring must not half-wire the game");
    }

    // ─────────────────────────────── helpers ───────────────────────────────

    /// @dev RE-SEEDED BEFORE EVERY SCRIPT RUN, not just in `setUp`. `vm.setEnv`
    ///      writes the PROCESS environment, which forge does not roll back
    ///      between tests the way it rolls back EVM state — and `setUp` executes
    ///      once, before the snapshot, while the tests that follow run
    ///      concurrently against the same process environment. The
    ///      environment is therefore re-seeded immediately before every script
    ///      run rather than once in `setUp`.
    function _setEnv() internal {
        vm.setEnv("WOOD_TOKEN", vm.toString(address(wood)));
        vm.setEnv("CHALLENGE_GAME", vm.toString(address(game)));
        vm.setEnv("STAKED_WOOD", vm.toString(address(swood)));
        vm.setEnv("EXPOSURE_LEDGER", vm.toString(address(ledger)));
        vm.setEnv("TIER_REGISTRY", vm.toString(address(tiers)));
        vm.setEnv("COURT_PANEL_BOND_WOOD", vm.toString(PANEL_BOND));
        vm.setEnv(
            "COURT_PANEL",
            string.concat(vm.toString(PANELIST_A), ",", vm.toString(PANELIST_B), ",", vm.toString(PANELIST_C))
        );
    }

    /// @dev Runs step 1 and recovers the deployed court from the `PanelSet`
    ///      event's emitter — the script returns nothing, and deriving the
    ///      CREATE address would encode an assumption about how broadcast
    ///      interacts with nonces.
    function _runDeploy() internal returns (Court court) {
        _setEnv();
        vm.recordLogs();
        PlanEScriptCaller(DEFAULT_SENDER).fwd(address(deployScript), abi.encodeCall(DeployPlanE.run, ()));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("PanelSet(uint256,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == topic) return Court(logs[i].emitter);
        }
        revert("PanelSet not emitted - the deploy script did not seat a panel");
    }

    function _deployAndBondPanel() internal returns (Court court) {
        court = _runDeploy();
        _bond(court, PANELIST_A);
        _bond(court, PANELIST_B);
        _bond(court, PANELIST_C);
        vm.setEnv("COURT", vm.toString(address(court)));
    }

    function _bond(Court court, address member) internal {
        wood.mint(member, PANEL_BOND);
        vm.startPrank(member);
        wood.approve(address(court), PANEL_BOND);
        court.postPanelBond();
        vm.stopPrank();
    }

    function _runDeployExpecting(string memory prefix) internal {
        _setEnv();
        try PlanEScriptCaller(DEFAULT_SENDER).fwd(address(deployScript), abi.encodeCall(DeployPlanE.run, ())) {
            revert("deploy pre-flight did not bite");
        } catch Error(string memory reason) {
            _assertPrefix(reason, prefix);
        }
    }

    function _runWireExpecting(string memory prefix) internal {
        try PlanEScriptCaller(DEFAULT_SENDER).fwd(address(wireScript), abi.encodeCall(WirePlanECourt.run, ())) {
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
