// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {DeployPlanD} from "../../script/DeployPlanD.s.sol";
import {ChallengeGame} from "../../src/ChallengeGame.sol";
import {ExposureLedger} from "../../src/ExposureLedger.sol";
import {StakedWood} from "../../src/StakedWood.sol";
import {TierRegistry} from "../../src/TierRegistry.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockWoodTwapOracle} from "../mocks/MockWoodTwapOracle.sol";

/// @dev See `DeployTokenCourtPreflight.t.sol`'s copy of this contract for the
///      full explanation: `vm.startBroadcast` runs the script's calls as
///      `DEFAULT_SENDER` while `deployer = msg.sender` is whoever called
///      `run()`, and `vm.prank` cannot bridge the gap (foundry refuses to
///      broadcast under an active prank). Etching a forwarder at
///      `DEFAULT_SENDER` and calling `run()` through it is the only way to
///      make the two the same address, as they are on a real deployment.
contract PlanDScriptCaller {
    function fwd(address target, bytes calldata data) external {
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }
}

/// @notice Drives the REAL `DeployPlanD` script against a REAL `StakedWood`,
///         `ExposureLedger` and `TierRegistry` (no
///         stubs), from the state Plan B + Plan C actually leave behind, then
///         breaks one piece of that state at a time and proves the pre-flight
///         refuses. Simulation only — no `--broadcast`.
///
///         Two reviews are pinned here:
///           B4 — the script never checked `swood.exposureLedger()` at all, so
///                the game could freeze commitments on a ledger the exit gate
///                does not read. An accused approver then unstakes inside
///                `autoSlashDelay`, `_slashOne` recovers 0, and `_settle`
///                still marks `_convicted` — no revert, no distinguishing
///                event, nothing recovered, and the proposal can never be
///                re-challenged.
///           M3 — the freeze role was granted FIRST and the settle pointer
///                LAST, across four separate multisig transactions. A
///                permissionless `file()` in that window freezes a key, which
///                makes `ExposureLedger.setCoverageFreezer` revert
///                `CoverageFrozen` from then on — so pre-flight 1 becomes
///                permanently unsatisfiable and the deploy cannot be re-run to
///                repair itself.
contract DeployPlanDPreflightTest is Test {
    ERC20Mock internal wood;
    StakedWood internal swood;
    ExposureLedger internal ledger;
    TierRegistry internal tiers;

    DeployPlanD internal script;

    /// @dev The price CAP, $0.50 — never served as a price. The market sits
    ///      below it, so the cap does not bind (the production shape).
    uint256 internal constant WOOD_PRICE_CAP_X8 = 5e7;
    uint256 internal constant WOOD_MARKET_X8 = 2.5e7; // $0.25, 8-dec

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
                    coolDownPeriod: 7 days,
                    minOwnerStake: 10_000e18,
                    minSlashBps: 1_000,
                    maxSlashBps: 10_000,
                    ageFloorBps: 2_500,
                    maturationPeriod: 30 days
                }))
        );
        swood = StakedWood(address(new ERC1967Proxy(address(swoodImpl), swoodInit)));

        ledger = new ExposureLedger(DEFAULT_SENDER, address(swood), 28 days);
        tiers = new TierRegistry(DEFAULT_SENDER);

        // The state Plan B and Plan C leave behind, and which this script
        // presumes to find. Plan B's `swood.setExposureLedger` is part of it —
        // `DeployPlanB` now makes that call inside its own broadcast.
        // Design revision 2: the scalar is a CAP, never a price, so Plan B also
        // leaves a live market source behind. Without one the ledger cannot
        // price WOOD at all and pre-flight 3 refuses — which is the state
        // `test_preflight_bites_whenTheLedgerIsUnpriced` provokes deliberately.
        MockWoodTwapOracle woodTwap = new MockWoodTwapOracle(WOOD_MARKET_X8);
        vm.startPrank(DEFAULT_SENDER);
        ledger.setWoodUsdPrice(WOOD_PRICE_CAP_X8);
        ledger.setWoodTwapOracle(address(woodTwap));
        swood.setExposureLedger(address(ledger));
        vm.stopPrank();

        script = new DeployPlanD();
        vm.etch(DEFAULT_SENDER, address(new PlanDScriptCaller()).code);
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

    /// @dev M3: THE ORDER IS THE FIX, so assert the order and not merely the
    ///      end state. `setCoverageFreezer` must be the LAST of the four, and
    ///      in particular must come after `game.setStakedWood` — until that
    ///      pointer exists `_settle` reverts `ZeroAddress`, and a challenge
    ///      filed in between freezes a key that makes `setCoverageFreezer`
    ///      itself permanently un-callable. Log ordering is the only way to
    ///      see this: the end state is identical either way.
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

    // ──────────────────────── the pre-flights bite ────────────────────────

    /// @dev B4 (a): sWOOD's pointer unset. This is the documented FAIL-OPEN
    ///      state of `claimUnstakeGuardian` — nothing reverts, the gate is
    ///      simply skipped, and the whole conviction path recovers zero.
    function test_preflight_bites_whenTheExitGateIsUnwired() public {
        vm.prank(DEFAULT_SENDER);
        swood.setExposureLedger(address(0));
        _runExpecting("PRE-FLIGHT: StakedWood.exposureLedger != EXPOSURE_LEDGER");
    }

    /// @dev B4 (b): sWOOD points at a DIFFERENT ledger. The reason the check is
    ///      an identity and not `!= address(0)`: a stale pointer from an
    ///      earlier deployment passes a non-zero test while holding none of
    ///      this deployment's frozen commitments, so the gate reads zero
    ///      exposure for an accused approver and lets it out.
    function test_preflight_bites_whenTheExitGateReadsADifferentLedger() public {
        ExposureLedger other = new ExposureLedger(DEFAULT_SENDER, address(swood), 28 days);
        vm.prank(DEFAULT_SENDER);
        swood.setExposureLedger(address(other));

        assertTrue(swood.exposureLedger() != address(0), "a non-zero check would have passed this state");
        _runExpecting("PRE-FLIGHT: StakedWood.exposureLedger != EXPOSURE_LEDGER");
    }

    /// @dev B4 (c): the refusal must be TOTAL — no role granted. A half-wired
    ///      Plan D is worse than none: the freeze role alone is what makes
    ///      pre-flight 1 unsatisfiable on a re-run.
    function test_preflight_leavesEveryRoleUnwired_whenTheExitGateIsUnwired() public {
        vm.prank(DEFAULT_SENDER);
        swood.setExposureLedger(address(0));
        _runExpecting("PRE-FLIGHT: StakedWood.exposureLedger != EXPOSURE_LEDGER");

        assertEq(ledger.coverageFreezer(), address(0), "coverageFreezer must be untouched");
        assertEq(tiers.authorizedDemoter(), address(0), "authorizedDemoter must be untouched");
        assertEq(swood.authorizedSlasher(), address(0), "authorizedSlasher must be untouched");
    }

    /// @dev PRE-FLIGHT 1: never silently steal a live role. Proven on the
    ///      freeze role specifically, because that is the one M3's reorder is
    ///      protecting: once a filing freezes a key the ledger refuses
    ///      `setCoverageFreezer` outright, and a script that clobbered instead
    ///      of refusing would have left no way back.
    function test_preflight_bites_whenCoverageFreezerIsAlreadyHeld() public {
        vm.prank(DEFAULT_SENDER);
        ledger.setCoverageFreezer(address(0xDEAD));
        _runExpecting("PRE-FLIGHT: ExposureLedger.coverageFreezer already set.");
    }

    /// @dev PRE-FLIGHT 3: an unpriced ledger makes every `file()` revert, so
    ///      the game would deploy into a state where nothing can be challenged.
    ///      Zero stays settable on the ledger (it is the emergency stop), so no
    ///      storage poke is needed.
    function test_preflight_bites_whenTheLedgerIsUnpriced() public {
        // No warp needed: `setWoodUsdPrice` is no longer rate-limited (issue
        // #89 moved that to a Zodiac module on the owner Safe), so a second
        // move in the same block `setUp` already used simply lands.
        vm.prank(DEFAULT_SENDER);
        ledger.setWoodUsdPrice(0);
        _runExpecting("PRE-FLIGHT: ExposureLedger.woodPriceX8 is 0");
    }

    /// @dev PRE-FLIGHT 4 (SHE-128): `quorumTierThreshold` must still be 0.
    ///      `DeployPlanB` asserts this on the ledger it MINTS; Plan D runs
    ///      later, against a ledger that has been under governance in between,
    ///      and `setQuorumTierThreshold` is a plain `onlyOwner` setter — so the
    ///      drift this catches needs no exotic state, just the owner having used
    ///      the setter once.
    ///
    ///      WHY IT MATTERS AT 1 SPECIFICALLY. `SyndicateGovernor` gates the
    ///      coverage quorum on `envelopeTier >= quorumTierThreshold`. At 1 a
    ///      tier-0 proposal skips `requireApproveQuorum` entirely and executes
    ///      with no stake-backed approver on the hook, while every other reading
    ///      of the deployment looks healthy.
    ///
    ///      NOT sandbox payloads, at 1 or 2. `_snapshotTierAndGate` forces
    ///      `tier_ = 2` on any proposal with non-zero `_sandboxFunding`, and
    ///      `proposeWithSandbox` refuses zero funding — so a sandbox is always
    ///      tier 2 and stays gated until the threshold reaches 3, the setter's
    ///      own "quorum disabled for all tiers" ceiling. The ordinary
    ///      certified-batch tiers are what 1 and 2 give away.
    function test_preflight_bites_whenTheQuorumTierThresholdHasDrifted() public {
        vm.prank(DEFAULT_SENDER);
        ledger.setQuorumTierThreshold(1);
        assertEq(ledger.quorumTierThreshold(), 1, "the drift did not land - the test would be vacuous");

        _runExpecting("PRE-FLIGHT: ExposureLedger.quorumTierThreshold != 0");
    }

    /// @dev And the refusal is TOTAL, same argument as the exit-gate case: a
    ///      Plan D that granted the freeze role before refusing would make
    ///      pre-flight 1 unsatisfiable on the re-run that fixes the threshold.
    ///
    ///      THIS DOES NOT PIN THE ASSERTION'S POSITION, and an earlier version
    ///      of this comment claimed it did. `_runExpecting` drives the whole of
    ///      `deploy()` in ONE call that reverts, and the revert rolls the role
    ///      grants back regardless of where the `require` sits — measured:
    ///      moving the pre-flight below `vm.stopBroadcast()` leaves all ten
    ///      tests in this suite green. Same trap as a post-revert counter
    ///      assertion. What the three reads below actually prove is that the
    ///      refusal leaves NO residue, which is the property that matters for a
    ///      re-run; position is a non-issue here anyway, since a `forge script`
    ///      that reverts anywhere broadcasts nothing at all (`DeployPlanB` puts
    ///      the same assertion after its broadcast for exactly that reason).
    function test_preflight_leavesEveryRoleUnwired_whenTheQuorumTierThresholdHasDrifted() public {
        vm.prank(DEFAULT_SENDER);
        ledger.setQuorumTierThreshold(2);
        _runExpecting("PRE-FLIGHT: ExposureLedger.quorumTierThreshold != 0");

        assertEq(ledger.coverageFreezer(), address(0), "coverageFreezer must be untouched");
        assertEq(tiers.authorizedDemoter(), address(0), "authorizedDemoter must be untouched");
        assertEq(swood.authorizedSlasher(), address(0), "authorizedSlasher must be untouched");
    }

    /// @dev Non-vacuity control for the two above: the happy path runs with the
    ///      default 0, so the new pre-flight is not simply refusing everything.
    function test_deploy_succeedsAtTheDefaultQuorumTierThreshold() public {
        assertEq(ledger.quorumTierThreshold(), 0, "ExposureLedger's default is no longer 0");
        ChallengeGame game = _run();
        assertEq(ledger.coverageFreezer(), address(game), "coverageFreezer");
    }

    // ─────────────────────────────── helpers ───────────────────────────────

    /// @dev THE ADDRESS BOOK IS PASSED, NOT SET IN THE ENVIRONMENT. `run()`'s
    ///      only job is to read `vm.envAddress` into this struct, and
    ///      `vm.setEnv` writes the PROCESS environment — one shared mutable
    ///      global that forge does not roll back between tests and that every
    ///      parallel suite writes to. Driving the script through `run()` here
    ///      would race `DeployPlanBPreflight` and `DeployTokenCourtPreflight`
    ///      over `STAKED_WOOD` and lose non-deterministically. `deploy()` takes
    ///      the book directly, so nothing here is shared.
    function _book() internal view returns (DeployPlanD.AddressBook memory) {
        return DeployPlanD.AddressBook({
            swood: address(swood), wood: address(wood), ledger: address(ledger), tierRegistry: address(tiers)
        });
    }

    /// @dev Recovers the deployed game from `ledger.coverageFreezer()` — the
    ///      script returns nothing, and deriving the CREATE address would
    ///      encode an assumption about how broadcast interacts with nonces.
    function _run() internal returns (ChallengeGame game) {
        PlanDScriptCaller(DEFAULT_SENDER).fwd(address(script), abi.encodeCall(DeployPlanD.deploy, (_book())));
        game = ChallengeGame(ledger.coverageFreezer());
        require(address(game) != address(0), "the deploy script did not wire a game");
    }

    function _runExpecting(string memory prefix) internal {
        try PlanDScriptCaller(DEFAULT_SENDER).fwd(address(script), abi.encodeCall(DeployPlanD.deploy, (_book()))) {
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
