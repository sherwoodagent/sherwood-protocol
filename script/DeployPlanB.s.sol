// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ExposureLedger} from "../src/ExposureLedger.sol";
import {ProposerBondEscrow} from "../src/ProposerBondEscrow.sol";
import {ISyndicateFactory} from "../src/interfaces/ISyndicateFactory.sol";
import {IGuardianRegistry} from "../src/interfaces/IGuardianRegistry.sol";

interface ISwoodCooldown {
    function coolDownPeriod() external view returns (uint256);
    function maxSlashBps() external view returns (uint256);
    function exposureLedger() external view returns (address);
}

/**
 * @title  DeployPlanB
 * @notice Plan B deployment against an EXISTING Plan A deployment. Address
 *         book via env vars (from chains/<chainid>.json). Order:
 *           1. pre-flights (see below) — fail BEFORE anything is deployed
 *           2. deploy ExposureLedger (epochLength 28d) + ProposerBondEscrow
 *           3. seed ledger params (WOOD haircut price, asset feed, caps, registry link)
 *           4. registry.setExposureLedger   (owner op — REQUIRES the UUPS-upgraded impl)
 *           5. factory.setExposureLedger / setBondEscrow (new syndicates)
 *         MANUAL follow-ups printed at the end (beacon/UUPS upgrades,
 *         pushWiring per governor, TierRegistry redeploy + recertify).
 *
 * @dev PRE-FLIGHT 1 (cross-contract invariant, spec §5): `swood.coolDownPeriod()`
 *      must be >= epochLength + challengeWindow (42d at defaults) BEFORE wiring,
 *      or an approver can unstake before its epoch's approvals can be challenged.
 *      `ExposureLedger`'s constructor re-enforces this, but only with an opaque
 *      `InvalidParameter()`; the explicit require below names the fix. Raising
 *      the sWOOD cooldown is a LIVE-PARAMETER GOVERNANCE ACTION — surface it,
 *      do not work around it here.
 * @dev PRE-FLIGHT 2: a zero `coveredTvlCapUsd` is fail-closed — the moment the
 *      ledger is wired into a governor, NOTHING can be proposed. Refuse to
 *      deploy into that state rather than brick proposing.
 *
 *      Ownership: the broadcaster becomes the ledger owner and must ALREADY own
 *      the GuardianRegistry and the SyndicateFactory (both setters are onlyOwner).
 *      On mainnet that means running this from the owner multisig, or running it
 *      with the deployer as owner and handing off afterwards.
 *
 *   Environment:
 *     STAKED_WOOD               — sWOOD (cooldown pre-flight + bond reads).
 *     SYNDICATE_FACTORY         — factory to wire (new syndicates).
 *     GUARDIAN_REGISTRY         — registry to wire (approve-side exposure recording).
 *     WOOD_TOKEN                — bond collateral held by the escrow.
 *     USDG                      — vault asset to register a feed for.
 *     CHAINLINK_USDG_USD_FEED   — that asset's Chainlink USD feed.
 *     ASSET_FEED_MAX_DELAY      — feed staleness bound, seconds (see setAssetFeed below).
 *     WOOD_PRICE_HAIRCUT_X8     — conservative WOOD/USD, 8-dec (<= 30-day low).
 *     COVERED_TVL_CAP_USD18     — per-vault covered-TVL ceiling, USD-18. Non-zero.
 *
 *   Usage (simulate; never --broadcast blind):
 *     forge script script/DeployPlanB.s.sol:DeployPlanB --rpc-url <rpc> -vvvv
 */
contract DeployPlanB is Script {
    /// @notice Epoch length (spec §5: 28d initial). Immutable in the ledger.
    uint256 internal constant EPOCH_LENGTH = 28 days;

    /// @notice Mirror of `ExposureLedger`'s default `challengeWindow` (14d).
    ///         Needed for the cooldown pre-flight, which must run BEFORE the
    ///         ledger exists to read it from. Asserted against the deployed
    ///         ledger below so this constant can never silently drift.
    uint256 internal constant EXPECTED_CHALLENGE_WINDOW = 14 days;

    function run() external {
        address deployer = msg.sender;

        address swood = vm.envAddress("STAKED_WOOD");
        address factory = vm.envAddress("SYNDICATE_FACTORY");
        address registry = vm.envAddress("GUARDIAN_REGISTRY");
        address wood = vm.envAddress("WOOD_TOKEN");
        address usdg = vm.envAddress("USDG");
        address usdgFeed = vm.envAddress("CHAINLINK_USDG_USD_FEED");
        uint256 feedMaxDelay = vm.envUint("ASSET_FEED_MAX_DELAY");
        uint256 woodPriceX8 = vm.envUint("WOOD_PRICE_HAIRCUT_X8"); // conservative, <= 30-day low
        uint256 coveredTvlCapUsd = vm.envUint("COVERED_TVL_CAP_USD18");

        // ── Pre-flight 1: REMOVED (ADR 2026-07-26) ──
        // This asserted `coolDownPeriod >= epochLength + challengeWindow` (42d
        // at defaults). It was both unsatisfiable and unnecessary:
        //
        //   - `StakedWood.setCooldownPeriod` caps the cooldown at 30 days, so
        //     the remedy this check printed — "raise the sWOOD cooldown by
        //     governance FIRST" — was not an action any operator could take.
        //     Only `initialize` could reach 42, i.e. only a fresh sWOOD.
        //   - The property it approximated (an approver cannot exit from under
        //     a pending challenge) is now enforced exactly by the exit gate on
        //     `claimUnstakeGuardian`, which reads `openExposureUsd` directly.
        //
        // Pre-flight 3 below replaces it, and is strictly stronger: it checks
        // the mechanism is WIRED rather than that a proxy for it is large
        // enough.
        uint256 coolDown = ISwoodCooldown(swood).coolDownPeriod();

        // ── Pre-flight 1b: the slash ceiling must not clip the allocation ──
        // The ledger books liability at 100% of a guardian's allocation, and
        // after the n1 fix `allocation == live slashable bond` is the DESIGNED
        // outcome whenever a co-approver's bond collapses, not a corner case.
        // With delegation deferred there is no surplus to absorb a clipped
        // ceiling, so any `maxSlashBps` below 10_000 makes recovery a strict
        // shortfall against the allocation and breaks §2's inequality by
        // construction.
        //
        // Every shipped config already seats 10_000 (`Deploy.s.sol`'s
        // DEFAULT_MAX_SLASH_BPS and both testnet scripts). This asserts the
        // choice rather than leaving it to a later governance transaction that
        // could lower it silently (review N9).
        require(
            ISwoodCooldown(swood).maxSlashBps() == 10_000,
            "PRE-FLIGHT: sWOOD maxSlashBps != 10000 -- the ledger books at 100% of allocation, "
            "so a lower ceiling makes recovery a strict shortfall."
        );

        // ── Pre-flight 2: a zero covered-TVL cap bricks all proposing ──
        require(
            coveredTvlCapUsd != 0, "PRE-FLIGHT: COVERED_TVL_CAP_USD18 is 0 (fail-closed: nothing could be proposed)"
        );

        console.log("sWOOD coolDownPeriod (s): %s", coolDown);
        console.log("deployer / ledger owner:  %s", deployer);

        vm.startBroadcast();

        ExposureLedger ledger = new ExposureLedger(deployer, swood, EPOCH_LENGTH);
        // Drift guard: if the ledger's default challenge window ever changes,
        // pre-flight 1 above was checked against a stale bound.
        require(
            ledger.challengeWindow() == EXPECTED_CHALLENGE_WINDOW,
            "ExposureLedger default challengeWindow changed - update EXPECTED_CHALLENGE_WINDOW"
        );

        ProposerBondEscrow escrow = new ProposerBondEscrow(wood, registry);

        ledger.setWoodUsdPrice(woodPriceX8);
        // maxDelay is LOAD-BEARING, not cosmetic: the §3.3a approve quorum
        // re-reads this feed at EXECUTE time, a full
        // `votingPeriod + reviewPeriod + executionWindow` after propose. A
        // maxDelay shorter than that lifecycle makes fully-covered proposals
        // die at execution with `StalePrice`. Size ASSET_FEED_MAX_DELAY against
        // the governor's ACTUAL lifecycle params (and the feed's real heartbeat),
        // not against a habitual `1 days`.
        ledger.setAssetFeed(usdg, usdgFeed, feedMaxDelay);
        ledger.setGuardianRegistry(registry);
        ledger.setCoveredTvlCapUsd(coveredTvlCapUsd);
        // quorumTierThreshold stays at the default 2 (tier-2 only) — lowering
        // it is gated on the §3.10 ROE validation (BLOCKING, spec §4 gate 2).

        IGuardianRegistry(registry).setExposureLedger(address(ledger));
        ISyndicateFactory(factory).setExposureLedger(address(ledger));
        ISyndicateFactory(factory).setBondEscrow(address(escrow));

        vm.stopBroadcast();

        // ── Pre-flight 3 (POST-wiring): the unstake gate must be live ──
        // `StakedWood.claimUnstakeGuardian` FAILS OPEN when `exposureLedger` is
        // unset, because there is necessarily a window at deploy — and again on
        // a UUPS upgrade — where the pointer is still zero, and failing closed
        // there would brick withdrawals over a missed configuration step.
        //
        // The cost of that choice is a deployment which looks entirely healthy
        // while guardians can walk out from under a pending challenge. Asserting
        // it here converts that silent hole into a refused deploy, which is the
        // only point where the mistake is still cheap. Checked AFTER the
        // broadcast because the wiring happens inside it.
        require(
            ISwoodCooldown(swood).exposureLedger() != address(0),
            "PRE-FLIGHT: sWOOD exposureLedger is unset -- the unstake gate would fail open. "
            "Call setExposureLedger(ledger) by governance, then re-run."
        );

        console.log("ExposureLedger:     %s", address(ledger));
        console.log("ProposerBondEscrow: %s", address(escrow));
        console.log("asset feed maxDelay (s): %s", feedMaxDelay);
        console.log("MANUAL NEXT: governor beacon upgrade, registry UUPS upgrade,");
        console.log("factory.pushWiring(<each existing governor>), TierRegistry redeploy + recertify.");
        console.log("MANUAL NEXT: hand ledger ownership to the protocol owner (Ownable2Step: transfer + accept).");
    }
}
