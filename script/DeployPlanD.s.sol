// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {ScriptBase} from "./ScriptBase.sol";
import {DeploySalts} from "./DeploySalts.sol";
import {Create3Factory} from "./utils/Create3Factory.sol";
import {ChallengeGame} from "../src/ChallengeGame.sol";
import {IExposureLedger} from "../src/interfaces/IExposureLedger.sol";
import {IStakedWood} from "../src/interfaces/IStakedWood.sol";

/// @dev Narrow demoter surface: `ITierRegistry` is the read side and carries neither the
///      role nor its setter, and the concrete `TierRegistry` would drag its whole
///      certification surface into a wiring script.
interface ITierRegistryDemoterRole {
    function authorizedDemoter() external view returns (address);
    function setAuthorizedDemoter(address demoter) external;
    function owner() external view returns (address);
}

/// @dev The sWOOD reads `IStakedWood` does not declare.
interface ISwoodExposureLedger {
    function exposureLedger() external view returns (address);
    function owner() external view returns (address);
}

/// @dev The ledger's owner, absent from `IExposureLedger`.
interface ILedgerOwner {
    function owner() external view returns (address);
}

/**
 * @title  DeployPlanD
 * @notice Challenge phase: mints `ChallengeGame` and grants it the four roles a verdict
 *         needs. An abstract mixin — `DeployAll` owns `run()`, the broadcast and the book.
 *
 *         Order: pre-flights (refuse before anything is minted), CREATE3 mint, the drift
 *         guard, the wiring in SETTLE-BEFORE-FREEZE order, then the post-flights.
 *
 * @dev Idempotent: the mint is `_c3` (adopt-if-present) and every write is guarded on the
 *      value already there. A role naming a FOREIGN holder is refused, never rotated.
 * @dev PRE-FLIGHT 1 (three role slots): each must be unset or already name THIS game.
 *      All three are single-holder slots whose setters overwrite silently, so clobbering
 *      one leaves the live holder unable to freeze, demote or slash.
 * @dev PRE-FLIGHT 2 (review B4): `swood.exposureLedger()` must be the ledger the game is
 *      constructed against. A split (or a zero, where the exit gate fails open by design)
 *      lets an accused approver unstake before `resolve` and be convicted for nothing —
 *      no revert, no distinguishing event, zero recovered.
 * @dev PRE-FLIGHT 3: `file()` reverts `WoodPriceUnset()` on a zero COMPOSED price, so an
 *      unpriced ledger deploys a game where nothing can be challenged. Probed, not called
 *      typed: `woodPriceX8()` REVERTS when no source can price WOOD, and to the game a
 *      revert and a zero are the same problem (review F16).
 *
 *      Ownership: the deployer owns the game and must ALREADY own the ledger, the tier
 *      registry and sWOOD — all three grant setters are `onlyOwner`.
 */
abstract contract DeployPlanD is ScriptBase {
    /// @notice The Plan D inputs. Named `PlanDBook` because `DeployAll` inherits this
    ///         mixin alongside Plan B's, and a shared `AddressBook` would collide.
    struct PlanDBook {
        address swood;
        address wood;
        address ledger;
        address tierRegistry;
    }

    /// @notice Pre-flights, CREATE3 mint, wiring and post-flights. Public so the
    ///         pre-flight suite drives the real thing without the process environment.
    /// @dev The caller must be the `Create3Factory` owner — `_c3Factory` bootstraps it at
    ///      `msg.sender`, exactly as `deployCore` does.
    function deploy(PlanDBook memory book) public returns (address gameAddr) {
        address deployer = msg.sender;
        address swood = book.swood;
        address ledger = book.ledger;
        address tierRegistry = book.tierRegistry;

        uint256 priceX8 = _preflight(book, deployer);

        Create3Factory c3 = _c3Factory(deployer);
        gameAddr = _predict(c3, DeploySalts.CHALLENGE_GAME);

        // ── Pre-flight 1 (PRE-MINT): never rotate a role away from a live holder ──
        // CREATE3 makes the game's address known here, so a slot that already names THIS
        // game is a resumed run and anything else is refused before anything is minted.
        require(
            _slotFree(IExposureLedger(ledger).coverageFreezer(), gameAddr),
            "PRE-FLIGHT: ExposureLedger.coverageFreezer already set. Clear it by governance "
            "FIRST if a rotation is intended - this script will not overwrite a live holder."
        );
        require(
            _slotFree(ITierRegistryDemoterRole(tierRegistry).authorizedDemoter(), gameAddr),
            "PRE-FLIGHT: TierRegistry.authorizedDemoter already set. Clear it by governance "
            "FIRST if a rotation is intended - this script will not overwrite a live holder."
        );
        require(
            _slotFree(IStakedWood(swood).authorizedSlasher(), gameAddr),
            "PRE-FLIGHT: StakedWood.authorizedSlasher already set. Clear it by governance "
            "FIRST if a rotation is intended - this script will not overwrite a live holder."
        );

        // Ledger and tier registry are constructor args — the game reads the approver set
        // from one and demotes through the other, and neither pointer has a sane default.
        ChallengeGame game = ChallengeGame(
            _c3(
                c3,
                DeploySalts.CHALLENGE_GAME,
                abi.encodePacked(
                    type(ChallengeGame).creationCode, abi.encode(deployer, book.wood, ledger, tierRegistry)
                )
            )
        );

        // Drift guard: a filing outside the ledger's coverage window would freeze exposure
        // already aged out of its epoch buckets, so a divergence is a wiring bug.
        require(
            game.challengeWindow() == IExposureLedger(ledger).challengeWindow(),
            "ChallengeGame.challengeWindow != ExposureLedger.challengeWindow - reconcile before wiring"
        );

        // ORDER IS LOAD-BEARING: SETTLE FIRST, FREEZE LAST (review M3). `file()` is
        // permissionless, and a filing between the first write and the last freezes a key
        // — which makes `setCoverageFreezer` revert `CoverageFrozen` from then on, so the
        // deployment could not even be re-run to repair itself.
        // GRANT BEFORE POINTING: `setStakedWood` rejects a sWOOD that has not already
        // named this game `authorizedSlasher` (review M2, `RoleNotGranted`).
        if (IStakedWood(swood).authorizedSlasher() != gameAddr) {
            IStakedWood(swood).setAuthorizedSlasher(gameAddr);
        }
        if (address(game.stakedWood()) != swood) game.setStakedWood(swood);
        if (ITierRegistryDemoterRole(tierRegistry).authorizedDemoter() != gameAddr) {
            ITierRegistryDemoterRole(tierRegistry).setAuthorizedDemoter(gameAddr);
        }
        // LAST. Nothing can be frozen before the verdict path is complete.
        if (IExposureLedger(ledger).coverageFreezer() != gameAddr) {
            IExposureLedger(ledger).setCoverageFreezer(gameAddr);
        }

        _postflight(book, game);
        _report(game, priceX8);
    }

    // ── Pre-flights (PRE-MINT: every one of these refuses before anything exists) ──

    /// @dev Returns the ledger's composed WOOD price, which the report prints.
    function _preflight(PlanDBook memory book, address deployer) internal view returns (uint256 priceX8) {
        // ── Pre-flight 2: Plan B's exit gate must read THIS ledger (review B4) ──
        // `== ledger`, not `!= address(0)`: a stale pointer from an earlier deployment
        // passes a non-zero test while holding none of this deployment's bookings.
        require(
            ISwoodExposureLedger(book.swood).exposureLedger() == book.ledger,
            "PRE-FLIGHT: StakedWood.exposureLedger != EXPOSURE_LEDGER. The exit gate reads a "
            "different ledger than the game freezes on, so an accused approver can unstake before "
            "resolve and be convicted for nothing. Run DeployPlanB (it wires this), or call "
            "setExposureLedger(EXPOSURE_LEDGER) from the sWOOD owner, then re-run."
        );

        // ── Pre-flight 3: an unpriced ledger makes every filing revert ──
        (bool priced, bytes memory ret) = book.ledger.staticcall(abi.encodeWithSignature("woodPriceX8()"));
        priceX8 = (priced && ret.length >= 32) ? abi.decode(ret, (uint256)) : 0;
        require(
            priceX8 != 0,
            "PRE-FLIGHT: ExposureLedger.woodPriceX8 is 0 (fail-closed: no challenge could be filed). "
            "Either the price CAP woodUsdPriceX8 is unset, or no market source is wired under it -- "
            "the ledger needs setWoodFeed pointed at a live WOOD/USD feed."
        );

        // ── Pre-flight 4: the deployer must be able to grant all three roles ──
        // Every grant below is `onlyOwner`. Left to revert mid-run it costs a game and
        // reports as `OwnableUnauthorizedAccount`, naming neither the slot nor the remedy.
        require(
            ILedgerOwner(book.ledger).owner() == deployer,
            "PRE-FLIGHT: broadcaster does not own EXPOSURE_LEDGER, so it cannot grant the coverage-"
            "freezer role. Re-run with --sender set to the ledger owner (if ownership was just "
            "transferred, the new owner must call acceptOwnership() first)."
        );
        require(
            ITierRegistryDemoterRole(book.tierRegistry).owner() == deployer,
            "PRE-FLIGHT: broadcaster does not own TIER_REGISTRY, so it cannot grant the demoter "
            "role. Re-run with --sender set to the registry owner (if ownership was just "
            "transferred, the new owner must call acceptOwnership() first)."
        );
        require(
            ISwoodExposureLedger(book.swood).owner() == deployer,
            "PRE-FLIGHT: broadcaster does not own STAKED_WOOD, so it cannot grant the slasher role. "
            "Re-run with --sender set to the sWOOD owner (the same multisig that owns the ledger "
            "and the tier registry)."
        );
    }

    // ── Post-flights (read the wiring back; the writes above are the only source) ──

    /// @dev Proves all four roles and all three constructor pointers landed on THIS game,
    ///      rather than trusting four setters to have been loud about failure.
    function _postflight(PlanDBook memory book, ChallengeGame game) internal view {
        require(IExposureLedger(book.ledger).coverageFreezer() == address(game), "wiring: coverageFreezer");
        require(
            ITierRegistryDemoterRole(book.tierRegistry).authorizedDemoter() == address(game),
            "wiring: authorizedDemoter"
        );
        require(IStakedWood(book.swood).authorizedSlasher() == address(game), "wiring: authorizedSlasher");
        require(address(game.stakedWood()) == book.swood, "wiring: stakedWood");
        require(address(game.exposureLedger()) == book.ledger, "wiring: exposureLedger");
        require(address(game.tierRegistry()) == book.tierRegistry, "wiring: tierRegistry");
    }

    // ── Helpers ──

    /// @dev A role slot may be empty or already ours; a FOREIGN holder is refused rather
    ///      than rotated, because rotating is how a stale game survives a re-run.
    function _slotFree(address current, address want) internal pure returns (bool) {
        return current == address(0) || current == want;
    }

    function _report(ChallengeGame game, uint256 priceX8) internal view {
        console.log("ChallengeGame:        %s", address(game));
        console.log("game owner:           %s", game.owner());
        console.log("ledger woodPriceX8:   %s", priceX8);
        console.log("challengeWindow (s):  %s", game.challengeWindow());
        console.log("autoSlashDelay (s):   %s", game.autoSlashDelay());
        console.log("disputeTimeout (s):   %s", game.disputeTimeout());
        console.log("challengerBondBps:    %s", game.challengerBondBps());
        console.log("MANUAL NEXT: stand up the OFF-CHAIN bug-bounty program keyed off");
        console.log("  ChallengeFiled / ChallengeSettled. On-chain a successful challenger only");
        console.log("  gets its bond BACK - without that program nobody is paid to file at all.");
        console.log("MANUAL NEXT: review autoSlashDelay against the guardians' real response");
        console.log("  capability - it is their ENTIRE window to notice a filing and counter-bond.");
    }
}
