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

/// @dev `ICompensationEscrow` declares `setAuthorizedFunder` but no getter, and
///      the pre-flight below needs to READ the funder — Plan C's wiring is a
///      precondition of this deployment, not something to re-apply here.
interface ICompensationEscrowFunder {
    function authorizedFunder() external view returns (address);
}

/**
 * @title  DeployPlanD
 * @notice Plan D deployment against an EXISTING Plan B + Plan C deployment.
 *         Address book via env vars (from chains/<chainid>.json). Order:
 *           1. pre-flights (see below) — fail BEFORE anything is deployed
 *           2. deploy ChallengeGame (ledger + tier registry set in constructor)
 *           3. wire the four roles the game needs to execute a verdict:
 *                ledger.setCoverageFreezer(game)          — freeze on filing
 *                tierRegistry.setAuthorizedDemoter(game)  — demote on a pass
 *                swood.setAuthorizedSlasher(game)         — execute the slash
 *                game.setStakedWood(swood)                — the reciprocal pointer
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
 * @dev PRE-FLIGHT 2 (Plan C's wiring must already be in place): the slash path
 *      ends in `StakedWood.slashToEscrow` → `CompensationEscrow.fundCase`, so
 *      it dead-ends unless BOTH directions of Plan C's wiring hold —
 *      `escrow.authorizedFunder() == swood` and `swood.compensationEscrow() ==
 *      escrow`. Either one missing makes every settled challenge revert at the
 *      last step, after the coverage was frozen and the bond was posted.
 * @dev PRE-FLIGHT 3: a zero `woodUsdPriceX8` on the ledger is fail-closed for
 *      the game exactly as it is for the bond math — `file()` reverts
 *      `InvalidParameter()` when the haircut price is unset, so the game would
 *      deploy into a state where NOTHING can be challenged.
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
 *     COMPENSATION_ESCROW  — Plan C escrow; read-only here (pre-flight 2).
 *
 *   Usage (simulate; never --broadcast blind):
 *     forge script script/DeployPlanD.s.sol:DeployPlanD --rpc-url <rpc> -vvvv
 */
contract DeployPlanD is Script {
    function run() external {
        address deployer = msg.sender;

        address swood = vm.envAddress("STAKED_WOOD");
        address wood = vm.envAddress("WOOD_TOKEN");
        address ledger = vm.envAddress("EXPOSURE_LEDGER");
        address tierRegistry = vm.envAddress("TIER_REGISTRY");
        address escrow = vm.envAddress("COMPENSATION_ESCROW");

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

        // ── Pre-flight 2: Plan C's rails, both directions ──
        require(
            ICompensationEscrowFunder(escrow).authorizedFunder() == swood,
            "PRE-FLIGHT: CompensationEscrow.authorizedFunder != STAKED_WOOD. Plan C wiring is "
            "missing - every settled challenge would revert funding the case."
        );
        require(
            IStakedWood(swood).compensationEscrow() == escrow,
            "PRE-FLIGHT: StakedWood.compensationEscrow != COMPENSATION_ESCROW. Plan C wiring is "
            "missing - slashToEscrow has nowhere to send the proceeds."
        );

        // ── Pre-flight 3: an unpriced ledger makes every filing revert ──
        uint256 priceX8 = IExposureLedger(ledger).woodUsdPriceX8();
        require(
            priceX8 != 0, "PRE-FLIGHT: ExposureLedger.woodUsdPriceX8 is 0 (fail-closed: no challenge could be filed)"
        );

        console.log("deployer / game owner:  %s", deployer);
        console.log("ledger woodUsdPriceX8:  %s", priceX8);

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

        IExposureLedger(ledger).setCoverageFreezer(address(game));
        ITierRegistryDemoterRole(tierRegistry).setAuthorizedDemoter(address(game));
        IStakedWood(swood).setAuthorizedSlasher(address(game));
        // The reciprocal pointer. sWOOD is owner-set state on the game rather
        // than a constructor arg because the role is granted on sWOOD's side and
        // the two can be wired in either order.
        game.setStakedWood(swood);

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
