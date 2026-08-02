// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ChallengeGame} from "../src/ChallengeGame.sol";
import {IExposureLedger} from "../src/interfaces/IExposureLedger.sol";
import {IStakedWood} from "../src/interfaces/IStakedWood.sol";

/// @dev Narrow surface for the demoter role. `ITierRegistry` is the read-side
///      interface consumed by the vault and carries neither the role nor its
///      setter, and pulling in the concrete `TierRegistry` here would drag its
///      whole certification surface into a wiring script.
interface ITierRegistryDemoterRole {
    function authorizedDemoter() external view returns (address);
    function setAuthorizedDemoter(address demoter) external;
}

/// @dev `IStakedWood` carries `authorizedSlasher` but not `exposureLedger`,
///      which pre-flight 2 below has to read. One view function does not
///      justify dragging the concrete `StakedWood` into a wiring script.
interface ISwoodExposureLedger {
    function exposureLedger() external view returns (address);
}

/**
 * @title  DeployPlanD
 * @notice Plan D deployment against an EXISTING Plan B + Plan C deployment.
 *         Address book via env vars (from chains/<chainid>.json). Order:
 *           1. pre-flights (see below) — fail BEFORE anything is deployed
 *           2. deploy ChallengeGame (ledger + tier registry set in constructor)
 *           3. wire the four roles the game needs to execute a verdict, in
 *              SETTLE-BEFORE-FREEZE order (review M3 — see the block itself):
 *                game.setStakedWood(swood)                — the reciprocal pointer
 *                swood.setAuthorizedSlasher(game)         — execute the slash
 *                tierRegistry.setAuthorizedDemoter(game)  — demote on a pass
 *                ledger.setCoverageFreezer(game)          — freeze on filing, LAST
 *         MANUAL follow-ups printed at the end (ownership handoff, parameter
 *         review, and the OFF-CHAIN bug-bounty program without which the
 *         challenge game has no detector incentive at all).
 *
 * @dev PRE-FLIGHT 1 (three role checks): each of the three roles this script
 *      grants must currently be UNSET. All three are single-holder slots whose
 *      setters overwrite silently, so re-running this script — or running it
 *      against a chain where a previous ChallengeGame is already wired — would
 *      quietly steal the role from the live holder and leave it unable to
 *      freeze, demote or slash. Refuse rather than clobber; if a rotation is
 *      genuinely intended, clear the role by governance first and say so.
 *      NOTE — the escrow wiring pre-flight is gone. The slash path used to end
 *      in `StakedWood.slashToEscrow` → `CompensationEscrow`, which dead-ended
 *      unless both directions of Plan C's wiring held. The verdict slash now
 *      burns internally, so there is no external sink to mis-wire.
 * @dev PRE-FLIGHT 2 (review B4): Plan B's exit gate must read the SAME ledger
 *      the game is constructed against — `swood.exposureLedger() ==
 *      EXPOSURE_LEDGER`. A split (or a zero, where the gate fails open by
 *      design) lets an accused approver unstake before `resolve` and be
 *      convicted for a zero recovery, silently. See the block itself.
 * @dev PRE-FLIGHT 3: a zero COMPOSED price on the ledger is fail-closed for the
 *      game exactly as it is for the bond math — `file()` reverts
 *      `WoodPriceUnset()` when it is unset, so the game would deploy into a
 *      state where NOTHING can be challenged. Checked as `woodPriceX8()`, the
 *      figure `file` actually divides by: the raw `woodUsdPriceX8` scalar would
 *      pass this pre-flight while the game was unpriced, and fail it while the
 *      game was healthy off a live feed (review 🟠F16).
 *
 *      Ownership: the broadcaster becomes the game's owner and must ALREADY own
 *      the ExposureLedger, the TierRegistry and StakedWood (all three setters
 *      are onlyOwner). On mainnet that means running this from the owner
 *      multisig, or running it with the deployer as owner and handing off
 *      afterwards.
 *
 *   Environment:
 *     STAKED_WOOD          — sWOOD; the WOOD custodian and the slash executor.
 *     WOOD_TOKEN           — bond currency for challenger and counter bonds.
 *     EXPOSURE_LEDGER      — Plan B ledger; approver set + coverage freeze.
 *     TIER_REGISTRY        — adapter certification registry to demote against.
 *
 *   Usage (simulate; never --broadcast blind):
 *     forge script script/DeployPlanD.s.sol:DeployPlanD --rpc-url <rpc> -vvvv
 */
contract DeployPlanD is Script {
    /// @notice The address book this deployment runs against, exactly as
    ///         `run()` reads it out of the environment.
    /// @dev    THE ENV READ AND THE DEPLOYMENT ARE SPLIT ON PURPOSE. `vm.setEnv`
    ///         writes the PROCESS environment — one shared mutable global that
    ///         forge does not roll back between tests and that every parallel
    ///         test suite writes to. A pre-flight test driven through `run()`
    ///         races every sibling suite seeding the same keys. `deploy()`
    ///         takes the book as an argument so the tests never touch that
    ///         global; `run()` is the thin env adapter and stays the only
    ///         production entry point. Same split as `DeployPlanB`.
    struct AddressBook {
        address swood;
        address wood;
        address ledger;
        address tierRegistry;
    }

    function run() external {
        deploy(
            AddressBook({
                swood: vm.envAddress("STAKED_WOOD"),
                wood: vm.envAddress("WOOD_TOKEN"),
                ledger: vm.envAddress("EXPOSURE_LEDGER"),
                tierRegistry: vm.envAddress("TIER_REGISTRY")
            })
        );
    }

    /// @notice Every pre-flight, deploy and wiring step. Public so the
    ///         pre-flight tests can drive the real thing without the process
    ///         environment — see `AddressBook`.
    function deploy(AddressBook memory book) public {
        address deployer = msg.sender;

        address swood = book.swood;
        address wood = book.wood;
        address ledger = book.ledger;
        address tierRegistry = book.tierRegistry;

        // ── Pre-flight 1: never silently steal a role from a live holder ──
        require(
            IExposureLedger(ledger).coverageFreezer() == address(0),
            "PRE-FLIGHT: ExposureLedger.coverageFreezer already set. Clear it by governance "
            "FIRST if a rotation is intended - this script will not overwrite a live holder."
        );
        require(
            ITierRegistryDemoterRole(tierRegistry).authorizedDemoter() == address(0),
            "PRE-FLIGHT: TierRegistry.authorizedDemoter already set. Clear it by governance "
            "FIRST if a rotation is intended - this script will not overwrite a live holder."
        );
        require(
            IStakedWood(swood).authorizedSlasher() == address(0),
            "PRE-FLIGHT: StakedWood.authorizedSlasher already set. Clear it by governance "
            "FIRST if a rotation is intended - this script will not overwrite a live holder."
        );

        // ── Pre-flight 2: Plan B's exit gate must read THIS ledger (review B4) ──
        // The game freezes commitments on the ledger it is constructed with, by
        // writing `_frozenCommitments[guardian]` THERE. `claimUnstakeGuardian`
        // asks whichever ledger sWOOD points at. Point them at different
        // contracts — or leave sWOOD's pointer at zero, where the gate is
        // documented to fail OPEN — and the freeze is written somewhere nobody
        // reads.
        //
        // The failure is total and completely silent. An accused approver
        // requests an unstake, waits out `coolDownPeriod` (floor 1 day) inside
        // the 7-day `autoSlashDelay`, and claims. At `resolve`, `_slashOne`
        // finds nothing staked and returns 0, `slashVerdict` returns 0 —
        // and `_settle` still marks `_convicted[key]`, so the proposal can never
        // be re-challenged either. No revert, no distinguishing event, zero
        // recovered. Nothing else in this script would notice: pre-flight 1 and
        // the post-conditions all check the ledger→game direction.
        //
        // `== ledger`, not `!= address(0)`: a stale pointer from an earlier
        // deployment passes a non-zero test while holding none of this
        // deployment's bookings, which is the same hole with extra steps.
        require(
            ISwoodExposureLedger(swood).exposureLedger() == ledger,
            "PRE-FLIGHT: StakedWood.exposureLedger != EXPOSURE_LEDGER. The exit gate reads a "
            "different ledger than the game freezes on, so an accused approver can unstake before "
            "resolve and be convicted for nothing. Run DeployPlanB (it wires this), or call "
            "setExposureLedger(EXPOSURE_LEDGER) from the sWOOD owner, then re-run."
        );

        // ── Pre-flight 3: an unpriced ledger makes every filing revert ──
        // The COMPOSED price, matching what `ChallengeGame.file` divides by
        // (review 🟠F16). Pre-flighting the raw scalar would pass while the
        // figure the game actually uses was zero, and fail while it was healthy.
        uint256 priceX8 = IExposureLedger(ledger).woodPriceX8();
        require(priceX8 != 0, "PRE-FLIGHT: ExposureLedger.woodPriceX8 is 0 (fail-closed: no challenge could be filed)");

        console.log("deployer / game owner:  %s", deployer);
        console.log("ledger woodPriceX8:     %s", priceX8);

        vm.startBroadcast();

        // Ledger and tier registry are constructor args — the game reads the
        // approver set from one and demotes through the other, and neither
        // pointer has a sane default.
        ChallengeGame game = new ChallengeGame(deployer, wood, ledger, tierRegistry);

        // Drift guard: the game's challenge window is only meaningful while it
        // matches the ledger's coverage window. A filing outside that window
        // would freeze exposure that has already expired out of its epoch
        // buckets, so a divergence here is a wiring bug, not a tuning choice.
        require(
            game.challengeWindow() == IExposureLedger(ledger).challengeWindow(),
            "ChallengeGame.challengeWindow != ExposureLedger.challengeWindow - reconcile before wiring"
        );

        // ORDER IS LOAD-BEARING: SETTLE FIRST, FREEZE LAST (review M3).
        // These are four separate transactions from an owner multisig, and a
        // challenge filed between the first and the last is not hypothetical —
        // `file()` is permissionless. Granting the freeze before the game can
        // settle opens a window where a filing sets `_frozen[key]` on the ledger
        // while `_settle` still reverts `ZeroAddress` for want of sWOOD; and
        // `ExposureLedger.setCoverageFreezer` refuses to run at all while any
        // key is frozen (`CoverageFrozen`), so pre-flight 1 above becomes
        // PERMANENTLY unsatisfiable and the deployment cannot even be re-run to
        // repair itself. Reversing the order costs nothing and closes it: the
        // ability to freeze is granted only once the ability to settle exists.
        //
        // GRANT BEFORE POINTING — and this pair is no longer free to order.
        // `ChallengeGame.setStakedWood` now REJECTS a sWOOD that has not already
        // named this game as its `authorizedSlasher` (review M2, `RoleNotGranted`),
        // so "point, then grant" reverts. The earlier note here said the two could
        // be wired in either order; that was true before M2 and is not now.
        //
        // Both requirements hold together under this interleave: grant the slash
        // role, point the game at sWOOD — the verdict path is complete at this
        // line — and only afterwards grant the freeze role below.
        IStakedWood(swood).setAuthorizedSlasher(address(game));
        game.setStakedWood(swood);
        ITierRegistryDemoterRole(tierRegistry).setAuthorizedDemoter(address(game));
        // LAST. Nothing can be frozen before the verdict path is complete.
        IExposureLedger(ledger).setCoverageFreezer(address(game));

        vm.stopBroadcast();

        // Post-conditions: prove all four roles actually landed on THIS game
        // rather than trusting four setters to have been loud about failure.
        require(IExposureLedger(ledger).coverageFreezer() == address(game), "wiring: coverageFreezer");
        require(
            ITierRegistryDemoterRole(tierRegistry).authorizedDemoter() == address(game), "wiring: authorizedDemoter"
        );
        require(IStakedWood(swood).authorizedSlasher() == address(game), "wiring: authorizedSlasher");
        require(address(game.stakedWood()) == swood, "wiring: stakedWood");
        require(address(game.exposureLedger()) == ledger, "wiring: exposureLedger");
        require(address(game.tierRegistry()) == tierRegistry, "wiring: tierRegistry");

        console.log("ChallengeGame:        %s", address(game));
        console.log("challengeWindow (s):  %s", game.challengeWindow());
        console.log("autoSlashDelay (s):   %s", game.autoSlashDelay());
        console.log("disputeTimeout (s):   %s", game.disputeTimeout());
        console.log("challengerBondBps:    %s", game.challengerBondBps());
        console.log("MANUAL NEXT: stand up the OFF-CHAIN bug-bounty program keyed off");
        console.log("  ChallengeFiled / ChallengeSettled. On-chain a successful challenger only");
        console.log("  gets its bond BACK - without that program nobody is paid to file at all.");
        console.log("MANUAL NEXT: review autoSlashDelay against the guardians' real response");
        console.log("  capability - it is their ENTIRE window to notice a filing and counter-bond.");
        console.log("MANUAL NEXT: a DISPUTED challenge times out in favour of the accused until");
        console.log("  the court (Plan E) ships. Until then a guilty approver can dispute and wait.");
        console.log("MANUAL NEXT: hand game ownership to the protocol owner (Ownable2Step: transfer + accept).");
    }
}
