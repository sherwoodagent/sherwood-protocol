// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {TokenCourt} from "../src/TokenCourt.sol";
import {ChallengeGame} from "../src/ChallengeGame.sol";
import {IExposureLedger} from "../src/interfaces/IExposureLedger.sol";
import {IStakedWood} from "../src/interfaces/IStakedWood.sol";

/// @dev Narrow surface for the demoter role, copied from `DeployPlanD` for the
///      same reason it exists there: `ITierRegistry` is the read-side
///      interface and carries neither the role nor its setter, and importing
///      the concrete `TierRegistry` would drag its whole certification
///      surface into a wiring script.
interface ITierRegistryDemoterRole {
    function authorizedDemoter() external view returns (address);
}

/// @dev `IStakedWood` declares `authorizedSlasher` but not `ageFloorBps` — the
///      launch-math pre-flight below needs the latter, and pulling in the
///      concrete `StakedWood` here would drag its whole staking surface into
///      a wiring script for one view function.
interface IStakedWoodAgeFloor {
    function ageFloorBps() external view returns (uint256);
}

/**
 * @title  DeployTokenCourt
 * @notice Deploy step for the token court (spec 2026-07-28-token-court-design.md)
 *         against an EXISTING Plan D deployment (`ChallengeGame` + its
 *         `StakedWood`/`ExposureLedger`/`TierRegistry` wiring). This step
 *         deploys and configures the court's own pointers; it grants the
 *         court NO authority over the game — that is `WireTokenCourt` below,
 *         a separate transaction so every pre-flight below can run against
 *         the finished pair before the game's `court` slot is touched.
 *
 *         Order here:
 *           1. deploy `TokenCourt(deployer)`
 *           2. configure it: `setChallengeGame`, `setStakedWood`
 *           3. hand ownership to the protocol owner (`Ownable2Step`: this
 *              only starts the transfer — see the `MANUAL NEXT` below)
 *
 *      Ownership: the broadcaster becomes the court's owner just long enough
 *      to wire its two pointers, then immediately starts the handoff to
 *      `PROTOCOL_OWNER`. It does not need to own the `ChallengeGame` for this
 *      step — every call here is on the court itself.
 *
 *   Environment:
 *     CHALLENGE_GAME  — Plan D game the court will (later) rule for.
 *     STAKED_WOOD     — sWOOD; the electorate `getPastVotes`/`getPastStake`
 *                        is read from.
 *     PROTOCOL_OWNER  — final owner of the court once `acceptOwnership` runs.
 *
 *   Usage (simulate; never --broadcast blind):
 *     forge script script/DeployTokenCourt.s.sol:DeployTokenCourt --rpc-url <rpc> -vvvv
 */
contract DeployTokenCourt is Script {
    function run() external {
        address deployer = msg.sender;

        address challengeGame = vm.envAddress("CHALLENGE_GAME");
        address stakedWood = vm.envAddress("STAKED_WOOD");
        address protocolOwner = vm.envAddress("PROTOCOL_OWNER");

        console.log("deployer:              %s", deployer);
        console.log("challenge game:        %s", challengeGame);
        console.log("staked wood:           %s", stakedWood);
        console.log("protocol owner:        %s", protocolOwner);

        vm.startBroadcast();

        TokenCourt court = new TokenCourt(deployer);
        court.setChallengeGame(challengeGame);
        court.setStakedWood(stakedWood);
        // Ownable2Step: this only STARTS the handoff. See the MANUAL NEXT
        // line below — the court is still owned by `deployer` until
        // `protocolOwner` calls `acceptOwnership()`.
        court.transferOwnership(protocolOwner);

        vm.stopBroadcast();

        // Post-conditions: prove the configuration landed on THIS court
        // rather than trusting three setters to have been loud about
        // failure.
        require(court.challengeGame() == challengeGame, "wiring: court.challengeGame");
        require(court.stakedWood() == stakedWood, "wiring: court.stakedWood");
        require(court.pendingOwner() == protocolOwner, "wiring: court.pendingOwner");

        console.log("TokenCourt:             %s", address(court));
        console.log("voteWindow (s):         %s", court.voteWindow());
        console.log("MAX_VOTE_WINDOW (s):    %s", court.MAX_VOTE_WINDOW());
        console.log("FINALIZE_BUFFER (s):    %s", court.FINALIZE_BUFFER());
        console.log("participationFloorBps:  %s", court.participationFloorBps());
        console.log("MANUAL NEXT: Ownable2Step needs %s to call acceptOwnership() on the", protocolOwner);
        console.log("  court - it is not the owner yet, only the pending one.");
        console.log("MANUAL NEXT: run WireTokenCourt (this file) once Plan D's wiring is confirmed,");
        console.log("  to grant the court ruling authority over ChallengeGame. Until then a");
        console.log("  disputed challenge has nowhere to be referred and times out to the accused.");
    }
}

/**
 * @title  WireTokenCourt
 * @notice Grant an ALREADY-DEPLOYED, ALREADY-CONFIGURED `TokenCourt` its
 *         ruling authority over the challenge game (`game.setCourt(court)`).
 *         Every check below is load-bearing rather than ceremony. The
 *         fail-safe if this script refuses is benign: an unwired game times a
 *         disputed challenge out in favour of the accused, exactly where the
 *         Plan D deployment left it.
 *
 * @dev PRE-FLIGHT 1: the court points where we think — `court.challengeGame()
 *      == CHALLENGE_GAME` and `court.stakedWood() == STAKED_WOOD`. A court
 *      wired to a different game rules for one that will reject it
 *      (`NotCourt`); a court with no sWOOD (or the wrong one) reads its
 *      electorate from a contract nobody staked in.
 * @dev PRE-FLIGHT 2: `game.stakedWood() == STAKED_WOOD` — sWOOD identity must
 *      match on BOTH contracts. A split here means the electorate that votes
 *      is not the cohort that gets slashed: the court could convict against
 *      one set of checkpoints while `_settle` slashes against another.
 * @dev PRE-FLIGHT 3 — THE CROSS-CONTRACT WINDOW INVARIANT:
 *      `game.autoSlashDelay() + court.voteWindow() + court.FINALIZE_BUFFER()
 *      <= game.disputeTimeout()`. CORRECTED (review 2026-07-29 audit, item 6
 *      — three claims below were true before that review and are not now):
 *      both contracts enforce this too as of "guard the wiring setters" —
 *      `ChallengeGame.setAutoSlashDelay` / `setDisputeTimeout` / `setCourt`
 *      and `TokenCourt.setVoteWindow` / `setChallengeGame` each check it
 *      against whatever the OTHER contract is CURRENTLY wired to at call
 *      time, so this is no longer "otherwise unenforced anywhere on-chain",
 *      `setAutoSlashDelay` is no longer blind to the court's `voteWindow`, and
 *      neither contract is checking this "alone" — each checks it against the
 *      other's live state. What THIS pre-flight still covers, and the only
 *      thing it covers: a pair's very FIRST wiring, before either side has
 *      anything to validate against. `ChallengeGame.setCourt`'s check is
 *      vacuous while `court == address(0)` (by design — unwiring must always
 *      stay legal, the fail-safe off-switch), and a court that has never
 *      called `setChallengeGame` has no game to check either — so the very
 *      first handshake between a fresh pair still needs an external check,
 *      which is what this script is. A counter-bond pool may complete as late
 *      as `filedAt + autoSlashDelay` (the instant the pool fills is the
 *      earliest the game's own auto-referral can fire, and it is also the
 *      LATEST a manual `refer` is still answering a live dispute rather than
 *      a moot one) — and from that instant a referral needs
 *      `voteWindow + FINALIZE_BUFFER` of runway before the challenge dies at
 *      `filedAt + disputeTimeout`. If the sum exceeds the timeout, the
 *      referral window is NEGATIVE: no referral is possible, auto or manual,
 *      and every disputed challenge free-wins for the accused. At defaults:
 *      `7 days + 5 days + 1 days == 13 days <= 30 days` OK, with 17 days of
 *      referral slack.
 * @dev PRE-FLIGHT 4 — LAUNCH-MATH: `court.participationFloorBps() <
 *      swood.ageFloorBps()` (spec §5). Turnout is measured with AGED weight
 *      (`getPastVotes`), while the floor's base is RAW total stake
 *      (`getPastTotalVotes`). With all stake young (the launch state), the
 *      maximum achievable turnout is roughly the `ageFloorBps` fraction of
 *      the raw total — so a floor set at or above that fraction could never
 *      be cleared no matter how complete the vote. An unclearable floor is
 *      not a fund-loss event (`Inconclusive` refunds and re-challenges are
 *      still open), but it is silent, permanent liveness damage to the
 *      court's only decision path. At defaults: `1_000 < 2_500` OK, implying
 *      `1_000 * 10_000 / 2_500 == 4_000` bps (40%) of RAW stake must vote to
 *      clear the floor at launch.
 * @dev PRE-FLIGHT 5: Plan D's wiring is still intact, or a `Guilty` verdict
 *      dead-ends at `_settle` — `ledger.coverageFreezer() == CHALLENGE_GAME`,
 *      `tiers.authorizedDemoter() == CHALLENGE_GAME`,
 *      `swood.authorizedSlasher() == CHALLENGE_GAME`.
 *
 *      Ownership: the broadcaster must own the `ChallengeGame` (`setCourt` is
 *      `onlyOwner`).
 *
 *   Environment:
 *     COURT            — the TokenCourt deployed by DeployTokenCourt.
 *     CHALLENGE_GAME   — Plan D game to grant it authority over.
 *     STAKED_WOOD      — sWOOD; must match on BOTH contracts.
 *     EXPOSURE_LEDGER  — Plan B ledger; read-only (pre-flight 5).
 *     TIER_REGISTRY    — Plan D demotion target; read-only (pre-flight 5).
 *
 *   Usage (simulate; never --broadcast blind):
 *     forge script script/DeployTokenCourt.s.sol:WireTokenCourt --rpc-url <rpc> -vvvv
 */
contract WireTokenCourt is Script {
    function run() external {
        address courtAddr = vm.envAddress("COURT");
        address gameAddr = vm.envAddress("CHALLENGE_GAME");
        address swoodAddr = vm.envAddress("STAKED_WOOD");
        address ledgerAddr = vm.envAddress("EXPOSURE_LEDGER");
        address tierRegistryAddr = vm.envAddress("TIER_REGISTRY");

        TokenCourt court = TokenCourt(courtAddr);
        ChallengeGame game = ChallengeGame(gameAddr);

        // ── Pre-flight 1: the court points where we think ──
        require(
            court.challengeGame() == gameAddr && court.stakedWood() == swoodAddr,
            "PRE-FLIGHT: TokenCourt.challengeGame/stakedWood != CHALLENGE_GAME/STAKED_WOOD. The "
            "court would rule for a game that rejects it, or read an electorate nobody staked in."
        );

        // ── Pre-flight 2: sWOOD identity matches on BOTH contracts ──
        require(
            address(game.stakedWood()) == swoodAddr,
            "PRE-FLIGHT: ChallengeGame.stakedWood != STAKED_WOOD. A split here means the "
            "electorate that votes is not the cohort that gets slashed."
        );

        // ── Pre-flight 3: the cross-contract window invariant (Task 10) ──
        uint256 autoSlashDelay = game.autoSlashDelay();
        uint256 voteWindow = court.voteWindow();
        uint256 finalizeBuffer = court.FINALIZE_BUFFER();
        uint256 disputeTimeout = game.disputeTimeout();
        require(
            autoSlashDelay + voteWindow + finalizeBuffer <= disputeTimeout,
            "PRE-FLIGHT: autoSlashDelay + voteWindow + FINALIZE_BUFFER > disputeTimeout. The "
            "referral window would be NEGATIVE - no referral, auto or manual, is possible, and "
            "every disputed challenge free-wins for the accused."
        );

        // ── Pre-flight 4: launch-math - the floor must be reachable ──
        uint256 floorBps = court.participationFloorBps();
        uint256 ageFloorBps = IStakedWoodAgeFloor(swoodAddr).ageFloorBps();
        require(
            floorBps < ageFloorBps,
            "PRE-FLIGHT: TokenCourt.participationFloorBps >= StakedWood.ageFloorBps. Turnout is "
            "AGED while the floor's base is RAW, so with all stake young the floor may be "
            "unclearable no matter how complete the vote."
        );

        // ── Pre-flight 5: Plan D's wiring intact, or a Guilty verdict dead-ends ──
        require(
            IExposureLedger(ledgerAddr).coverageFreezer() == gameAddr,
            "PRE-FLIGHT: ExposureLedger.coverageFreezer != CHALLENGE_GAME. Plan D wiring is "
            "missing - the game cannot move coverage when the court rules."
        );
        require(
            ITierRegistryDemoterRole(tierRegistryAddr).authorizedDemoter() == gameAddr,
            "PRE-FLIGHT: TierRegistry.authorizedDemoter != CHALLENGE_GAME. Plan D wiring is "
            "missing - a guilty verdict would revert demoting the adapter."
        );
        require(
            IStakedWood(swoodAddr).authorizedSlasher() == gameAddr,
            "PRE-FLIGHT: StakedWood.authorizedSlasher != CHALLENGE_GAME. Plan D wiring is "
            "missing - a guilty verdict would have no slasher to execute it."
        );

        console.log("court:                    %s", courtAddr);
        console.log("challenge game:           %s", gameAddr);
        console.log("autoSlashDelay (s):       %s", autoSlashDelay);
        console.log("voteWindow (s):           %s", voteWindow);
        console.log("FINALIZE_BUFFER (s):      %s", finalizeBuffer);
        console.log("window sum (s):           %s", autoSlashDelay + voteWindow + finalizeBuffer);
        console.log("disputeTimeout (s):       %s", disputeTimeout);
        console.log("participationFloorBps:    %s", floorBps);
        console.log("swood.ageFloorBps:        %s", ageFloorBps);
        console.log("implied raw turnout (bps):%s", floorBps * 10_000 / ageFloorBps);

        vm.startBroadcast();
        game.setCourt(courtAddr);
        vm.stopBroadcast();

        require(game.court() == courtAddr, "wiring: game.court");

        console.log("ChallengeGame.court:      %s", game.court());
        console.log("MANUAL NEXT: a StakedWood upgrade (slashToEscrow's ABI, e.g. the conviction-");
        console.log("  bounty params) and any ChallengeGame redeploy that calls it MUST ship as ONE");
        console.log("  atomic governance batch. A selector mismatch between the two - one upgraded,");
        console.log("  the other not - makes every resolve() revert: coverage stays frozen and every");
        console.log("  accused approver is barred from claimUnstakeGuardian until both sides agree.");
        console.log("MANUAL NEXT: referral on dispute completion is automatic but BEST-EFFORT -");
        console.log("  permissionless TokenCourt.refer is the fallback. Monitor AutoReferFailed and");
        console.log("  have someone ready to call refer directly if it fires.");
        console.log("MANUAL NEXT: off-chain voter incentives are an OPERATIONAL COMMITMENT (spec");
        console.log("  section 1) - nothing on-chain pays a WOOD holder to vote. Without it, turnout");
        console.log("  is a bet on altruism and the participation floor may never clear.");
        console.log("MANUAL NEXT: accept court ownership if DeployTokenCourt's handoff has not");
        console.log("  already completed (Ownable2Step: acceptOwnership from PROTOCOL_OWNER).");
    }
}
