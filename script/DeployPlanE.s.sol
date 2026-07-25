// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Court} from "../src/Court.sol";
import {ChallengeGame} from "../src/ChallengeGame.sol";
import {IExposureLedger} from "../src/interfaces/IExposureLedger.sol";

/// @dev Narrow surface for the demoter role, copied from `DeployPlanD` for the
///      same reason it exists there: `ITierRegistry` is the read-side interface
///      and carries neither the role nor its setter, and importing the concrete
///      `TierRegistry` would drag its whole certification surface into a wiring
///      script. Here it is READ-ONLY — Plan D already granted the role, and this
///      script only proves it is still held by the game it is about to empower.
interface ITierRegistryDemoterRole {
    function authorizedDemoter() external view returns (address);
}

/**
 * @title  DeployPlanE
 * @notice Plan E STEP 1 of 2: deploy and configure the `Court` against an
 *         EXISTING Plan B + C + D deployment. This step deliberately does NOT
 *         grant the court any authority over the challenge game — that is
 *         `WirePlanECourt` below, and it is a separate transaction because of
 *         the ordering constraint the whole plan turns on.
 *
 *         Why two steps: the court's binding incentive on panel behaviour is the
 *         per-member bond, and only a panelist can post its own bond
 *         (`postPanelBond` is `msg.sender`-scoped — nobody can bond on their
 *         behalf). So the roster cannot be fully bonded at the instant the court
 *         is deployed, and "every seated member has posted its bond" cannot be a
 *         pre-flight of the deployment. It is a pre-flight of the WIRING, which
 *         is the transaction that actually hands the court power over 100%
 *         slashes. Between the two steps the court is inert: `ChallengeGame.rule`
 *         reverts `NotCourt` for it, so a case referred to a half-configured
 *         court cannot move anything.
 *
 *         Order here:
 *           1. pre-flights (below) — fail BEFORE anything is deployed
 *           2. deploy Court (owner, WOOD, panel bond in the constructor)
 *           3. configure it: setChallengeGame, setStakedWood, setPanel
 *           4. post-conditions, including the window-fit check that
 *              `WirePlanECourt` re-runs as a pre-flight
 *
 * @dev PRE-FLIGHT 1 (`game.court() == address(0)`): the game's court slot is a
 *      single-holder role whose setter overwrites silently. Deploying a second
 *      court against a game that already has a live one is a governance
 *      decision (unwiring a captured court), not something a deploy script
 *      should stage by accident — refuse and make the operator say so.
 * @dev PRE-FLIGHT 2 (Plan D's wiring intact): the court's only power is to call
 *      `ChallengeGame.rule`, which routes straight into Plan D's `_settle` —
 *      coverage unfreeze, tier demotion, `StakedWood.slashToEscrow`. If the game
 *      has lost any of those three roles, a guilty verdict reverts at the last
 *      step and the case is stuck until `disputeTimeout` acquits the accused.
 *      The court would look wired and be unable to convict.
 * @dev PRE-FLIGHT 3 (a non-empty roster, a non-zero bond): a court with no panel
 *      finalizes every case immediately as `NotGuilty` (`finalizePanel`'s
 *      early-close), i.e. it is an acquittal machine. A zero bond is a panel
 *      with no skin in the game; the constructor refuses it, but fail here with
 *      a message that says why rather than on an opaque `InvalidParameter()`.
 *
 *      Ownership: the broadcaster becomes the court's owner. It does NOT need to
 *      own anything else for this step — every call here is on the court itself.
 *      `WirePlanECourt` is the step that needs ownership of the ChallengeGame.
 *
 *   Environment:
 *     WOOD_TOKEN             — the token every bond in the court is denominated in.
 *     CHALLENGE_GAME         — Plan D game the court will (later) rule for.
 *     STAKED_WOOD            — sWOOD; the electorate `getPastVotes` is read from.
 *     EXPOSURE_LEDGER        — Plan B ledger; read-only here (pre-flight 2).
 *     TIER_REGISTRY          — Plan D demotion target; read-only here (pre-flight 2).
 *     COURT_PANEL_BOND_WOOD  — per-member bond, in WOOD wei. Non-zero.
 *     COURT_PANEL            — comma-separated panelist addresses (the off-chain
 *                              election result the owner is executing, D1).
 *
 *   Usage (simulate; never --broadcast blind):
 *     forge script script/DeployPlanE.s.sol:DeployPlanE --rpc-url <rpc> -vvvv
 */
contract DeployPlanE is Script {
    function run() external {
        address deployer = msg.sender;

        address wood = vm.envAddress("WOOD_TOKEN");
        address gameAddr = vm.envAddress("CHALLENGE_GAME");
        address swood = vm.envAddress("STAKED_WOOD");
        address ledger = vm.envAddress("EXPOSURE_LEDGER");
        address tierRegistry = vm.envAddress("TIER_REGISTRY");
        uint256 panelBond = vm.envUint("COURT_PANEL_BOND_WOOD");
        // `envOr` rather than `envAddress` so an unset or empty COURT_PANEL
        // lands on pre-flight 3's explanation of WHY an empty roster is
        // unacceptable, instead of an opaque env-parsing failure.
        address[] memory members = vm.envOr("COURT_PANEL", ",", new address[](0));

        ChallengeGame game = ChallengeGame(gameAddr);

        // ── Pre-flight 1: never stage a second court over a live one ──
        require(
            game.court() == address(0),
            "PRE-FLIGHT: ChallengeGame.court is already set. Unwiring a live court is a "
            "governance decision - clear it FIRST if that is genuinely intended."
        );

        // ── Pre-flight 2: Plan D's wiring, or the ruling path dead-ends ──
        require(
            address(game.stakedWood()) == swood,
            "PRE-FLIGHT: ChallengeGame.stakedWood != STAKED_WOOD. Plan D wiring is missing - a "
            "guilty verdict would have no slasher to execute it."
        );
        require(
            IExposureLedger(ledger).coverageFreezer() == gameAddr,
            "PRE-FLIGHT: ExposureLedger.coverageFreezer != CHALLENGE_GAME. Plan D wiring is "
            "missing - the game cannot move coverage when the court rules."
        );
        require(
            ITierRegistryDemoterRole(tierRegistry).authorizedDemoter() == gameAddr,
            "PRE-FLIGHT: TierRegistry.authorizedDemoter != CHALLENGE_GAME. Plan D wiring is "
            "missing - a guilty verdict would revert demoting the adapter."
        );

        // ── Pre-flight 3: a court with no bonded panel is an acquittal machine ──
        require(
            members.length != 0,
            "PRE-FLIGHT: COURT_PANEL is empty. An empty roster finalizes every case at once as "
            "NotGuilty - that is an acquittal machine, not a court."
        );
        require(
            panelBond != 0,
            "PRE-FLIGHT: COURT_PANEL_BOND_WOOD is 0. The member bond is the ENTIRE binding "
            "incentive on panel behaviour; a zero bond makes the bad-faith track decorative."
        );

        console.log("deployer / court owner: %s", deployer);
        console.log("challenge game:         %s", gameAddr);
        console.log("panel size:             %s", members.length);
        console.log("panel bond (WOOD wei):  %s", panelBond);

        vm.startBroadcast();

        // WOOD and the panel bond are constructor args: neither has a sane
        // default, and the constructor also seeds `appealBondWood` and
        // `badFaithBondWood` from the panel bond so no bond in this contract is
        // ever zero at any point in its life.
        Court court = new Court(deployer, wood, panelBond);

        // Both pointers are owner-set rather than constructor args because the
        // game's side of the relationship is granted separately (step 2) and the
        // two can be configured in either order.
        court.setChallengeGame(gameAddr);
        court.setStakedWood(swood);
        // D1: the roster is the off-chain election result. Selection is trusted;
        // behaviour is bonded.
        court.setPanel(members);

        vm.stopBroadcast();

        // Post-conditions: prove the configuration landed on THIS court rather
        // than trusting three setters to have been loud about failure.
        require(court.challengeGame() == gameAddr, "wiring: court.challengeGame");
        require(court.stakedWood() == swood, "wiring: court.stakedWood");
        require(court.panelSize() == members.length, "wiring: court.panel");
        require(address(court.wood()) == wood, "wiring: court.wood");

        // The same window-fit check `WirePlanECourt` runs as a pre-flight, run
        // here against the constructor defaults so a bad default is caught at
        // deploy time rather than one transaction later. See the comment there
        // for why this is a correctness condition and not a tuning preference.
        require(
            court.panelWindow() + court.appealWindow() + court.appealVoteWindow() <= game.disputeTimeout(),
            "POST-DEPLOY: panelWindow + appealWindow + appealVoteWindow > ChallengeGame.disputeTimeout. "
            "The challenge would time out and ACQUIT before the court could rule - a court that is "
            "structurally unable to convict. Shorten the court windows or lengthen disputeTimeout."
        );

        console.log("Court:                  %s", address(court));
        console.log("panelWindow (s):        %s", court.panelWindow());
        console.log("appealWindow (s):       %s", court.appealWindow());
        console.log("appealVoteWindow (s):   %s", court.appealVoteWindow());
        console.log("badFaithWindow (s):     %s", court.badFaithWindow());
        console.log("participationFloorBps:  %s", court.participationFloorBps());
        console.log("appealBondWood:         %s", court.appealBondWood());
        console.log("badFaithBondWood:       %s", court.badFaithBondWood());
        console.log("game disputeTimeout(s): %s", game.disputeTimeout());
        console.log("MANUAL NEXT: every seated panelist must approve WOOD to the court and call");
        console.log("  postPanelBond(). WirePlanECourt REFUSES to wire until all of them have -");
        console.log("  an unbonded panel has nothing to slash and rules for free.");
        console.log("MANUAL NEXT: panelRewardWood defaults to 0, so panelists are currently UNPAID");
        console.log("  for ruling. Set it (setPanelRewardWood) against the forfeited-bond flow, or");
        console.log("  accept that the only incentive to rule is avoiding a bad-faith vote.");
        console.log("MANUAL NEXT: review appealBondWood / badFaithBondWood - both were seeded from");
        console.log("  the panel bond so neither is ever zero, not because that is the right price.");
        console.log("MANUAL NEXT: run WirePlanECourt (this file) from the ChallengeGame owner to");
        console.log("  grant the court its ruling authority. Until then the court is INERT.");
        console.log("MANUAL NEXT: hand court ownership to the protocol owner (Ownable2Step: transfer + accept).");
    }
}

/**
 * @title  WirePlanECourt
 * @notice Plan E STEP 2 of 2: grant an ALREADY-DEPLOYED, FULLY-BONDED court its
 *         ruling authority over the challenge game (`game.setCourt(court)`).
 *
 *         This is the transaction that makes the court real, and every check
 *         below is load-bearing rather than ceremony. Fact 2 of the plan: the
 *         panel and the appeal cover each other's failure mode, so a HALF-WIRED
 *         court is worse than no court at all — it holds authority over 100%
 *         slashes with one of its two checks missing. The fail-safe if this
 *         script refuses is benign: an unwired game times a disputed challenge
 *         out in favour of the accused, which is exactly where Plan D left it.
 *
 * @dev PRE-FLIGHT 1 (`game.court() == address(0)`): do not steal the role from a
 *      live court. Single-holder slot, silent overwrite.
 * @dev PRE-FLIGHT 2 (the court points back): `court.challengeGame() == game` and
 *      `court.stakedWood() == swood`. A court wired one way rules for a game
 *      that will reject it; a court with no sWOOD cannot open an appeal at all
 *      (`appeal` reverts `ZeroAddress`), which deletes layer 2 silently and
 *      leaves the bribable panel §3.5 refuses to ship alone.
 * @dev PRE-FLIGHT 3 (roster seated AND fully bonded): `isReadyToRule` for every
 *      seat. An unbonded member cannot rule (`panelRule` reverts), so a partly
 *      bonded panel is a smaller panel than governance elected — and a wholly
 *      unbonded one has no slashable skin, which is the entire binding incentive
 *      the bad-faith track (D4) acts on.
 * @dev PRE-FLIGHT 4 (`participationFloorBps != 0`): a zero floor silently
 *      removes D6. Every appeal with any turnout at all would then clear quorum,
 *      and swinging a single-digit-turnout vote at a ~$15M mcap becomes the
 *      cheapest way to overturn any ruling — the token layer's named failure
 *      mode.
 * @dev PRE-FLIGHT 5 (`badFaithWindow != 0`): a zero window means `openBadFaith`
 *      can never be called in time, so the F6 track never opens and the panel is
 *      unpunishable. That is the standalone bribable panel again.
 * @dev PRE-FLIGHT 6 (the windows fit inside `disputeTimeout`): the court's three
 *      phases run back to back from referral — `referredAt + panelWindow`, then
 *      `panelFinalizedAt + appealWindow`, then `appealedAt + appealVoteWindow` —
 *      while the challenge itself dies at `filedAt + disputeTimeout` in favour of
 *      the ACCUSED. If the three windows do not fit inside the timeout, a case
 *      that uses its full clock is acquitted by the game before the court can
 *      hand down a verdict: a court structurally unable to convict. Necessary,
 *      not sufficient — referral happens some time after filing, so the real
 *      margin is smaller than this check proves.
 * @dev PRE-FLIGHT 7 (Plan D's wiring intact): as in step 1 — the ruling path
 *      must not dead-end.
 *
 *      Ownership: the broadcaster must own the ChallengeGame (`setCourt` is
 *      `onlyOwner`).
 *
 *   Environment:
 *     COURT            — the Court deployed by DeployPlanE.
 *     CHALLENGE_GAME   — Plan D game to grant it authority over.
 *     STAKED_WOOD      — sWOOD; must match on BOTH contracts.
 *     EXPOSURE_LEDGER  — Plan B ledger; read-only (pre-flight 7).
 *     TIER_REGISTRY    — Plan D demotion target; read-only (pre-flight 7).
 *
 *   Usage (simulate; never --broadcast blind):
 *     forge script script/DeployPlanE.s.sol:WirePlanECourt --rpc-url <rpc> -vvvv
 */
contract WirePlanECourt is Script {
    function run() external {
        address courtAddr = vm.envAddress("COURT");
        address gameAddr = vm.envAddress("CHALLENGE_GAME");
        address swood = vm.envAddress("STAKED_WOOD");
        address ledger = vm.envAddress("EXPOSURE_LEDGER");
        address tierRegistry = vm.envAddress("TIER_REGISTRY");

        Court court = Court(courtAddr);
        ChallengeGame game = ChallengeGame(gameAddr);

        // ── Pre-flight 1 ──
        require(
            game.court() == address(0),
            "PRE-FLIGHT: ChallengeGame.court is already set. This script will not overwrite a "
            "live court - unwire it by governance FIRST if a rotation is intended."
        );

        // ── Pre-flight 2: the court points back at both counterparties ──
        require(
            court.challengeGame() == gameAddr,
            "PRE-FLIGHT: Court.challengeGame != CHALLENGE_GAME. The court would refer and rule "
            "against a different game."
        );
        require(
            court.stakedWood() == swood,
            "PRE-FLIGHT: Court.stakedWood != STAKED_WOOD. With no electorate the appeal reverts "
            "at the door, which deletes layer 2 and ships the bare bribable panel."
        );

        // ── Pre-flight 3: the roster is seated AND every seat is bonded ──
        address[] memory members = court.panel();
        require(
            members.length != 0,
            "PRE-FLIGHT: Court panel is empty. An empty roster finalizes every case at once as "
            "NotGuilty - wiring that to the game installs an acquittal machine."
        );
        for (uint256 i; i < members.length; ++i) {
            require(
                court.isReadyToRule(members[i]),
                "PRE-FLIGHT: a seated panelist has not posted its bond. An unbonded member cannot "
                "rule and has no slashable skin - the bad-faith track would have nothing to slash."
            );
        }

        // ── Pre-flight 4: D6's anti-capture property must be on ──
        require(
            court.participationFloorBps() != 0,
            "PRE-FLIGHT: Court.participationFloorBps is 0. Any turnout at all would clear quorum "
            "and a single-digit-turnout vote could overturn any ruling (D6 deleted)."
        );

        // ── Pre-flight 5: the F6 track must be able to open ──
        require(
            court.badFaithWindow() != 0,
            "PRE-FLIGHT: Court.badFaithWindow is 0. The bad-faith proceeding could never be "
            "opened, leaving the panel unpunishable - the standalone bribable panel."
        );

        // ── Pre-flight 6: the court must fit inside the challenge's own clock ──
        uint256 courtSpan = court.panelWindow() + court.appealWindow() + court.appealVoteWindow();
        uint256 timeout = game.disputeTimeout();
        require(
            courtSpan <= timeout,
            "PRE-FLIGHT: panelWindow + appealWindow + appealVoteWindow > ChallengeGame.disputeTimeout. "
            "The challenge times out and ACQUITS before the court can rule - a court structurally "
            "unable to convict. Shorten the court windows or lengthen disputeTimeout."
        );

        // ── Pre-flight 7: Plan D's wiring, or a guilty verdict reverts ──
        require(
            address(game.stakedWood()) == swood,
            "PRE-FLIGHT: ChallengeGame.stakedWood != STAKED_WOOD. Plan D wiring is missing - a "
            "guilty verdict would have no slasher to execute it."
        );
        require(
            IExposureLedger(ledger).coverageFreezer() == gameAddr,
            "PRE-FLIGHT: ExposureLedger.coverageFreezer != CHALLENGE_GAME. Plan D wiring is "
            "missing - the game cannot move coverage when the court rules."
        );
        require(
            ITierRegistryDemoterRole(tierRegistry).authorizedDemoter() == gameAddr,
            "PRE-FLIGHT: TierRegistry.authorizedDemoter != CHALLENGE_GAME. Plan D wiring is "
            "missing - a guilty verdict would revert demoting the adapter."
        );

        console.log("court:                  %s", courtAddr);
        console.log("panel size (all bonded):%s", members.length);
        console.log("court span (s):         %s", courtSpan);
        console.log("disputeTimeout (s):     %s", timeout);

        vm.startBroadcast();
        game.setCourt(courtAddr);
        vm.stopBroadcast();

        require(game.court() == courtAddr, "wiring: game.court");

        console.log("ChallengeGame.court:    %s", game.court());
        console.log("MANUAL NEXT: a disputed challenge must now be REFERRED (Court.refer) inside the");
        console.log("  challenge's disputeTimeout - referral is permissionless but not automatic, and");
        console.log("  an unreferred dispute still times out in favour of the accused.");
        console.log("MANUAL NEXT: panel liveness is an OPERATIONAL requirement the contract cannot");
        console.log("  enforce - a panel that never rules yields NotGuilty by default (fail-safe).");
        console.log("MANUAL NEXT: hand court ownership to the protocol owner if step 1 has not");
        console.log("  already (Ownable2Step: transfer + accept).");
    }
}
