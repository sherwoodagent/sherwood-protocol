// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {ScriptBase} from "./ScriptBase.sol";
import {DeploySalts} from "./DeploySalts.sol";
import {Stack} from "./robinhood-mainnet/DeployTypes.sol";
import {Create3Factory} from "./utils/Create3Factory.sol";
import {TokenCourt} from "../src/TokenCourt.sol";
import {ChallengeGame} from "../src/ChallengeGame.sol";
import {IExposureLedger} from "../src/interfaces/IExposureLedger.sol";
import {IStakedWood} from "../src/interfaces/IStakedWood.sol";

/// @dev Read-only demoter surface; `ITierRegistry` carries neither the role nor its setter.
interface ITierRegistryDemoter {
    function authorizedDemoter() external view returns (address);
}

/// @dev `IStakedWood` declares `authorizedSlasher` but not `ageFloorBps`, which the
///      launch-math pre-flight reads.
interface IStakedWoodAgeFloor {
    function ageFloorBps() external view returns (uint256);
}

/**
 * @title  DeployTokenCourt
 * @notice Token-court phase (spec 2026-07-28-token-court-design.md), split in two: mint
 *         and configure the court's own pointers, then — only once every pre-flight has
 *         run against the finished pair — grant it ruling authority over the game. An
 *         abstract mixin; `DeployAll` owns `run()`, the broadcast and the handoff.
 *
 * @dev Idempotent: the mint is `_c3` and both wiring calls are skip-if-set. A `court`
 *      slot naming a FOREIGN court is refused, never repointed.
 * @dev The fail-safe if `_wireCourt` refuses is benign: an unwired game times a disputed
 *      challenge out in favour of the accused, exactly where Plan D left it.
 */
abstract contract DeployTokenCourt is ScriptBase {
    /// @notice Mint the court and point it at the game and the electorate.
    /// @dev Ownership stays with the deployer; `DeployAll._handoffAll` moves it last.
    function _deployCourt(Stack memory s) internal {
        address deployer = msg.sender;
        Create3Factory c3 = _c3Factory(deployer);

        TokenCourt court = TokenCourt(
            _c3(c3, DeploySalts.TOKEN_COURT, abi.encodePacked(type(TokenCourt).creationCode, abi.encode(deployer)))
        );
        s.tokenCourt = address(court);

        if (court.challengeGame() == address(0)) court.setChallengeGame(s.challengeGame);
        if (court.stakedWood() == address(0)) court.setStakedWood(s.core.swoodProxy);

        // Post-conditions: prove the configuration landed on THIS court, and refuse a
        // court already pointed somewhere else.
        require(court.challengeGame() == s.challengeGame, "wiring: court.challengeGame");
        require(court.stakedWood() == s.core.swoodProxy, "wiring: court.stakedWood");

        console.log("TokenCourt:             %s", address(court));
        console.log("voteWindow (s):         %s", court.voteWindow());
        console.log("participationFloorBps:  %s", court.participationFloorBps());
    }

    /// @notice Grant the configured court ruling authority over the game.
    /// @dev PRE-FLIGHT 1: the court points where we think. A court wired to a different
    ///      game rules for one that rejects it (`NotCourt`); a court with the wrong sWOOD
    ///      reads its electorate from a contract nobody staked in.
    /// @dev PRE-FLIGHT 2: sWOOD identity must match on BOTH contracts, or the electorate
    ///      that votes is not the cohort that gets slashed.
    /// @dev PRE-FLIGHT 3: `autoSlashDelay + voteWindow + FINALIZE_BUFFER +
    ///      MIN_REFERRAL_SLACK <= disputeTimeout`. Both contracts enforce this against
    ///      whatever the OTHER is currently wired to, which is vacuous for a pair's very
    ///      FIRST handshake — that gap is what this check covers.
    /// @dev PRE-FLIGHT 4 (launch-math, spec §5): `participationFloorBps < ageFloorBps`.
    ///      Turnout is AGED weight while the floor's base is RAW stake, so with all stake
    ///      young a floor at or above that fraction can never be cleared. The court's own
    ///      setters guard this too, but cannot see `StakedWood.setAgeFloorBps` LOWERING
    ///      the floor after deploy — sWOOD holds no pointer back to the court.
    /// @dev PRE-FLIGHT 5: Plan D's wiring is still intact, or a `Guilty` verdict
    ///      dead-ends at `_settle`. Ranked by what a miss costs (review M4); the demoter
    ///      is last because `_settle` try/catches it and emits `AdapterDemotionFailed`.
    function _wireCourt(Stack memory s) internal {
        TokenCourt court = TokenCourt(s.tokenCourt);
        ChallengeGame game = ChallengeGame(s.challengeGame);
        address swoodAddr = s.core.swoodProxy;

        require(
            court.challengeGame() == s.challengeGame && court.stakedWood() == swoodAddr,
            "PRE-FLIGHT: TokenCourt.challengeGame/stakedWood != CHALLENGE_GAME/STAKED_WOOD. The "
            "court would rule for a game that rejects it, or read an electorate nobody staked in."
        );
        require(
            address(game.stakedWood()) == swoodAddr,
            "PRE-FLIGHT: ChallengeGame.stakedWood != STAKED_WOOD. A split here means the "
            "electorate that votes is not the cohort that gets slashed."
        );

        uint256 autoSlashDelay = game.autoSlashDelay();
        uint256 voteWindow = court.voteWindow();
        uint256 finalizeBuffer = court.FINALIZE_BUFFER();
        uint256 disputeTimeout = game.disputeTimeout();
        // `MIN_REFERRAL_SLACK` is read from the game rather than hardcoded: without the
        // margin this check passes at the bare boundary while `setCourt` itself reverts,
        // so the phase would fail late with a typed error instead of this message.
        require(
            autoSlashDelay + voteWindow + finalizeBuffer + game.MIN_REFERRAL_SLACK() <= disputeTimeout,
            "PRE-FLIGHT: autoSlashDelay + voteWindow + FINALIZE_BUFFER + MIN_REFERRAL_SLACK > "
            "disputeTimeout. The referral window leaves no runway for a dropped auto-referral to "
            "be retried, and every disputed challenge free-wins for the accused."
        );

        uint256 floorBps = court.participationFloorBps();
        uint256 ageFloorBps = IStakedWoodAgeFloor(swoodAddr).ageFloorBps();
        require(
            floorBps < ageFloorBps,
            "PRE-FLIGHT: TokenCourt.participationFloorBps >= StakedWood.ageFloorBps. Turnout is "
            "AGED while the floor's base is RAW, so with all stake young the floor may be "
            "unclearable no matter how complete the vote."
        );

        require(
            IStakedWood(swoodAddr).authorizedSlasher() == s.challengeGame,
            "PRE-FLIGHT: StakedWood.authorizedSlasher != CHALLENGE_GAME. Plan D wiring is "
            "missing - a guilty verdict would have no slasher to execute it."
        );
        require(
            IExposureLedger(s.exposureLedger).coverageFreezer() == s.challengeGame,
            "PRE-FLIGHT: ExposureLedger.coverageFreezer != CHALLENGE_GAME. Plan D wiring is "
            "missing - the game cannot move coverage when the court rules."
        );
        require(
            ITierRegistryDemoter(s.core.tierRegistry).authorizedDemoter() == s.challengeGame,
            "PRE-FLIGHT: TierRegistry.authorizedDemoter != CHALLENGE_GAME. Plan D wiring is "
            "missing - a guilty verdict would skip demoting the adapter (try/catch: it emits "
            "AdapterDemotionFailed rather than reverting), leaving it certified."
        );

        // A `court` slot naming someone else is refused, never repointed: repointing is
        // how a stale court survives a re-run.
        address current = game.court();
        require(
            current == address(0) || current == s.tokenCourt,
            "WIRING: ChallengeGame.court already names a foreign court -- this ceremony never "
            "repoints a live slot. Clear it with setCourt(0), or bump the CREATE3 salt namespace."
        );
        if (current == address(0)) game.setCourt(s.tokenCourt);
        require(game.court() == s.tokenCourt, "wiring: game.court");

        console.log("ChallengeGame.court:      %s", game.court());
        console.log("window sum (s):           %s", autoSlashDelay + voteWindow + finalizeBuffer);
        console.log("disputeTimeout (s):       %s", disputeTimeout);
        console.log("implied raw turnout (bps):%s", floorBps * 10_000 / ageFloorBps);
        console.log("MANUAL NEXT: a StakedWood upgrade (slashToEscrow's ABI) and any ChallengeGame");
        console.log("  redeploy that calls it MUST ship as ONE atomic governance batch - a selector");
        console.log("  mismatch makes every resolve() revert and coverage stays frozen.");
        console.log("MANUAL NEXT: referral on dispute completion is automatic but BEST-EFFORT -");
        console.log("  permissionless TokenCourt.refer is the fallback. Monitor AutoReferFailed.");
        console.log("MANUAL NEXT: off-chain voter incentives are an OPERATIONAL COMMITMENT (spec");
        console.log("  section 1) - nothing on-chain pays a WOOD holder to vote.");
    }
}
