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
    /// @dev `onlyOwner` on sWOOD. This script CALLS it (see the wiring block)
    ///      rather than only asserting it: the ledger the pointer has to name
    ///      does not exist until this script has already deployed it, so
    ///      "go set it first, then re-run" is not an instruction an operator
    ///      can follow on a first deploy.
    function setExposureLedger(address ledger) external;
    /// @dev Read PRE-broadcast, to prove the broadcaster can actually make the
    ///      `setExposureLedger` call below instead of discovering it cannot
    ///      halfway through the broadcast, with two contracts already deployed.
    function owner() external view returns (address);
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
 *           6. swood.setExposureLedger      (owner op — arms the unstake gate)
 *         MANUAL follow-ups printed at the end (UUPS upgrade, TierRegistry
 *         redeploy + recertify, and — CONDITIONAL ON THE CHAIN, see pre-flight
 *         5 — either a governor beacon upgrade or pushWiring per governor).
 *
 * @dev PRE-FLIGHT 1 was REMOVED (ADR 2026-07-26) — it demanded a 42d sWOOD
 *      cooldown that `setCooldownPeriod`'s own 30d cap made unreachable, so its
 *      printed remedy was not an action any operator could take. Pre-flight 3
 *      replaces it and is strictly stronger. Kept named here so the numbering
 *      below is not read as a gap; see the body for the full argument.
 * @dev PRE-FLIGHT 1b (review N9): `maxSlashBps == 10_000`. The ledger books at
 *      100% of allocation, so any lower ceiling makes recovery a strict
 *      shortfall against it.
 * @dev PRE-FLIGHT 4 (ADR 2026-07-27): `quorumTierThreshold == 0` — a covering
 *      approve quorum is required at EVERY tier. The `maxEnvelopeTier <= 1`
 *      half this was once paired with was dropped (owner decision 2026-07-31);
 *      see the block itself.
 * @dev PRE-FLIGHT 2: a zero `coveredTvlCapUsd` is fail-closed — the moment the
 *      ledger is wired into a governor, NOTHING can be proposed. Refuse to
 *      deploy into that state rather than brick proposing.
 * @dev PRE-FLIGHT 5 (review M5): a factory with LIVE governor proxies whose
 *      beacon impl predates Plan B is refused. Plan B cannot be wired into
 *      those governors, and the beacon upgrade that would make it possible is
 *      forbidden on this stack — `SyndicateGovernor`'s layout was re-baselined
 *      non-append-only, so an impl swap on a populated beacon corrupts every
 *      proxy. See the block itself; it also shapes the manual follow-ups.
 * @dev PRE-FLIGHT 3 (review B3): the three ledger pointers — registry, factory
 *      and sWOOD — must all name THE LEDGER THIS RUN DEPLOYED. sWOOD's is wired
 *      inside the broadcast rather than demanded of the operator beforehand,
 *      because the ledger does not exist until step 2. See the block itself.
 *
 *      Ownership: the broadcaster becomes the ledger owner and must ALREADY own
 *      the GuardianRegistry, the SyndicateFactory and StakedWood (all three
 *      setters are onlyOwner; `Deploy.s.sol` hands all three to the same owner
 *      multisig). On mainnet that means running this from the owner multisig, or
 *      running it with the deployer as owner and handing off afterwards.
 *      Pre-flight 2b checks the sWOOD half of that up front.
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

    /// @notice The address book this deployment runs against, exactly as
    ///         `run()` reads it out of the environment.
    /// @dev    THE ENV READ AND THE DEPLOYMENT ARE SPLIT ON PURPOSE. `vm.setEnv`
    ///         writes the PROCESS environment — one shared mutable global for
    ///         the whole `forge test` run, which forge does not roll back
    ///         between tests and which every test suite executing in parallel
    ///         writes to. A pre-flight test driven through `run()` therefore
    ///         races every sibling suite that seeds the same keys, and loses
    ///         non-deterministically (observed: all 9 tests of this script's
    ///         suite failing on an address another suite had just written).
    ///         `deploy()` takes the book as an argument so the tests never
    ///         touch that global at all; `run()` is the thin env adapter and
    ///         stays the only production entry point.
    struct AddressBook {
        address swood;
        address factory;
        address registry;
        address wood;
        address usdg;
        address usdgFeed;
        uint256 feedMaxDelay;
        uint256 woodPriceX8; // conservative, <= 30-day low
        uint256 coveredTvlCapUsd;
    }

    function run() external {
        deploy(
            AddressBook({
                swood: vm.envAddress("STAKED_WOOD"),
                factory: vm.envAddress("SYNDICATE_FACTORY"),
                registry: vm.envAddress("GUARDIAN_REGISTRY"),
                wood: vm.envAddress("WOOD_TOKEN"),
                usdg: vm.envAddress("USDG"),
                usdgFeed: vm.envAddress("CHAINLINK_USDG_USD_FEED"),
                feedMaxDelay: vm.envUint("ASSET_FEED_MAX_DELAY"),
                woodPriceX8: vm.envUint("WOOD_PRICE_HAIRCUT_X8"),
                coveredTvlCapUsd: vm.envUint("COVERED_TVL_CAP_USD18")
            })
        );
    }

    /// @notice Every pre-flight, deploy and wiring step. Public so the
    ///         pre-flight tests can drive the real thing without the process
    ///         environment — see `AddressBook`.
    function deploy(AddressBook memory book) public {
        address deployer = msg.sender;

        address swood = book.swood;
        address factory = book.factory;
        address registry = book.registry;
        address wood = book.wood;
        address usdg = book.usdg;
        address usdgFeed = book.usdgFeed;
        uint256 feedMaxDelay = book.feedMaxDelay;
        uint256 woodPriceX8 = book.woodPriceX8;
        uint256 coveredTvlCapUsd = book.coveredTvlCapUsd;
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

        // ── Pre-flight 2b: the broadcaster must be able to arm the exit gate ──
        // `StakedWood.setExposureLedger` is `onlyOwner`, and the wiring block
        // below CALLS it (see pre-flight 3 for why it cannot merely assert it).
        // Checked here rather than left to revert inside the broadcast: a
        // failure there costs a ledger and an escrow deploy before it lands, and
        // reports itself as an opaque `OwnableUnauthorizedAccount` rather than
        // as the one thing the operator has to change. This is the same
        // ownership assumption the script already makes of the GuardianRegistry
        // and the SyndicateFactory — `Deploy.s.sol` hands all three to the same
        // owner multisig — stated where it can be checked.
        require(
            ISwoodCooldown(swood).owner() == deployer,
            "PRE-FLIGHT: broadcaster does not own STAKED_WOOD, so it cannot arm the unstake gate. "
            "Re-run with --sender set to the sWOOD owner (the same multisig that owns the registry " "and the factory)."
        );

        // ── Pre-flight 5: the governor beacon must not need an impl swap it
        //    cannot survive (review M5) ──
        // Plan B needs every governor to carry `_exposureLedger` / `_bondEscrow`:
        // `createSyndicate` pushes both into each new governor, and `pushWiring`
        // pushes them into the existing ones. On a beacon whose implementation
        // predates Plan B, BOTH of those calls revert — so the moment this script
        // sets `factory.exposureLedger`, syndicate creation on that factory is
        // bricked until the beacon is upgraded.
        //
        // AND THE BEACON UPGRADE IS THE ONE THING THAT MUST NOT HAPPEN HERE. This
        // stack re-baselined `SyndicateGovernor`'s storage layout non-append-only:
        // `GovernorParameters` now inherits `ProposalLifecycle`, which C3
        // PREPENDS, so every field moved (`vault` 0 -> 15, `_guardianRegistry`
        // 43 -> 0, `_tierRegistry` 48 -> 58). That is legitimate for a FRESH
        // deployment and only for a fresh deployment — pushed onto a beacon with
        // live proxies, every governor reads garbage at every slot. See
        // `test/governor/GovernorLayoutPins.t.sol`, which pins the new baseline
        // and carries the same warning.
        //
        // So the three live states differ completely and the script must not
        // treat them alike:
        //   - `syndicateCount == 0`  — no proxies exist; a beacon upgrade is a
        //     no-op on live state and the manual follow-up is safe to print.
        //   - `syndicateCount != 0` and the beacon ALREADY serves a Plan B-capable
        //     governor — nothing needs upgrading; `pushWiring` alone finishes the
        //     job. This is the ordinary "Plan A from this stack, then Plan B"
        //     path and stays allowed: having syndicates is not by itself a
        //     problem, and refusing it would block legitimate work.
        //   - `syndicateCount != 0` and the beacon serves a PRE-Plan B governor —
        //     refused below. There is no ordering of the remaining steps that is
        //     both safe and complete: wiring the factory bricks creation,
        //     `pushWiring` reverts, and the upgrade that would fix either
        //     corrupts the live proxies. Those syndicates need a fresh factory
        //     and beacon, not an upgrade.
        //
        // REFUSES rather than warns, and refuses BEFORE the broadcast, for the
        // same reason as every other pre-flight here: the failure is silent and
        // the remedy is a redeployment. The scope is the narrowest one that is
        // still honest — this is not "the chain has syndicates", it is "the chain
        // has syndicates this deployment cannot reach without an upgrade that
        // would corrupt them".
        //
        // TWO WAYS THIS READS CONSERVATIVELY, both deliberate. `syndicateCount`
        // counts every syndicate this factory ever created, so after a
        // `setBeacon` migration it over-counts the CURRENT beacon's proxies; and
        // if two factories were ever pointed at one beacon, this factory's count
        // says nothing about the other's proxies. Over-refusal is the safe
        // direction for the first; the second is an operator obligation — check
        // every factory sharing the beacon.
        uint256 liveGovernors = ISyndicateFactory(factory).syndicateCount();
        if (liveGovernors != 0) {
            require(
                _beaconServesPlanBGovernor(ISyndicateFactory(factory).beacon()),
                "PRE-FLIGHT: SYNDICATE_FACTORY has live governor proxies on a PRE-PLAN-B governor "
                "impl. Plan B cannot be wired into them: createSyndicate/pushWiring would revert, and "
                "upgrading the beacon is FORBIDDEN on this stack -- SyndicateGovernor's layout was "
                "re-baselined non-append-only (fresh deploys only, see GovernorLayoutPins.t.sol), so "
                "every live governor would read garbage. Deploy a FRESH SyndicateFactory + "
                "GovernorBeacon on the Plan B governor impl and run this against that factory."
            );
        }

        console.log("sWOOD coolDownPeriod (s): %s", coolDown);
        console.log("deployer / ledger owner:  %s", deployer);
        console.log("existing syndicates on this factory: %s", liveGovernors);

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
        // quorumTierThreshold stays at its default, which ADR 2026-07-27 moved
        // to 0 (every tier fail-closed). Asserted in pre-flight 4 rather than
        // re-set here, so a ledger whose default ever drifts is caught instead
        // of silently corrected.

        IGuardianRegistry(registry).setExposureLedger(address(ledger));
        ISyndicateFactory(factory).setExposureLedger(address(ledger));
        ISyndicateFactory(factory).setBondEscrow(address(escrow));
        // THE READ SIDE OF THE SAME POINTER. The registry BOOKS exposure into
        // the ledger; sWOOD READS it to gate `claimUnstakeGuardian`. Both have
        // to name the same contract or the gate reads an empty ledger — so this
        // call belongs in the same block as the two above, not in a follow-up
        // transaction an operator is trusted to remember.
        ISwoodCooldown(swood).setExposureLedger(address(ledger));

        vm.stopBroadcast();

        // ── Pre-flight 3 (POST-wiring): the unstake gate must be live, and
        //    must be reading THE LEDGER THIS DEPLOYMENT BOOKS INTO ──
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
        //
        // WHY THIS IS AN `==` AND NOT A `!= address(0)` (review B3). A non-zero
        // test is passed by a sWOOD pointing at ANY ledger, including a stale
        // one from an earlier deployment — and that is not a hypothetical, it is
        // precisely the state the old "set it by governance FIRST, then re-run"
        // remedy produced: an operator who deployed a ledger by hand to satisfy
        // the check got a SECOND ledger from this script, with the registry and
        // the factory booking into the new one while sWOOD read the old. Every
        // guardian then shows `openExposureUsd == 0` and walks out carrying live
        // exposure — the exact failure the check exists to prevent, reached by
        // following its own instructions.
        //
        // WHY THE THREE ARE ASSERTED TOGETHER. Booking (registry), issuance
        // (factory) and the exit gate (sWOOD) are one mechanism split across
        // three pointers; any one of them naming a different ledger is silently
        // unsafe in the same way. Splitting them into separate blocks would let
        // a partial state look like a partial success.
        require(
            address(IGuardianRegistry(registry).exposureLedger()) == address(ledger),
            "WIRING: GuardianRegistry.exposureLedger != the ledger just deployed. Approvals would "
            "be booked nowhere the exit gate can see. Re-run this script from the registry owner."
        );
        require(
            ISyndicateFactory(factory).exposureLedger() == address(ledger),
            "WIRING: SyndicateFactory.exposureLedger != the ledger just deployed. New syndicates "
            "would be issued against a different ledger. Re-run this script from the factory owner."
        );
        require(
            ISwoodCooldown(swood).exposureLedger() == address(ledger),
            "PRE-FLIGHT: sWOOD exposureLedger != the ledger just deployed -- the unstake gate is "
            "open, or reads a ledger holding none of this deployment's bookings. This script wires "
            "it inside the broadcast; if it did not land, re-run from the sWOOD owner."
        );

        // ── Pre-flight 4 (POST-wiring): coverage is enforced at every tier ──
        // ADR 2026-07-27 originally paired this with a `maxEnvelopeTier <= 1`
        // ceiling that refused tier-2 exposure outright. THAT HALF WAS DROPPED
        // (owner decision 2026-07-31): tier-2 guardian ROE is to be closed with
        // off-chain team token incentives rather than by refusing the tier, so
        // tier 2 remains admissible on-chain and there is no ceiling to assert.
        //
        // What remains is the half that was never a policy choice. Coverage
        // SIZING was already correct at every tier; only ENFORCEMENT was gated,
        // and at the old default of 2 it ran at tier 2 alone — so a tier-0/1
        // proposal could execute with NO covering approver at all, its
        // correctly-sized coverage never checked. Threshold 0 closes that.
        //
        // Asserted after the broadcast, the only point where the value is
        // readable in the form the protocol will actually run with.
        require(
            ledger.quorumTierThreshold() == 0,
            "PRE-FLIGHT: ExposureLedger.quorumTierThreshold != 0 -- a covering approve quorum is "
            "required at EVERY tier. Call setQuorumTierThreshold(0), then re-run."
        );

        console.log("ExposureLedger:     %s", address(ledger));
        console.log("ProposerBondEscrow: %s", address(escrow));
        console.log("asset feed maxDelay (s): %s", feedMaxDelay);

        // The manual follow-ups are NOT the same list in both states, and the
        // difference is the whole of review M5. The old unconditional text told
        // every operator to upgrade the governor beacon and then `pushWiring`
        // each existing governor — an instruction that is correct on a fresh
        // chain and destroys a populated one. Pre-flight 5 above has already
        // refused the genuinely unreachable case, so only two states get here;
        // each is printed with its own precondition spelled out, so the safety
        // of the step is legible from the transcript rather than from having
        // read this file.
        console.log("MANUAL NEXT: registry UUPS upgrade, TierRegistry redeploy + recertify.");
        if (liveGovernors == 0) {
            console.log("MANUAL NEXT: governor beacon upgrade.");
            console.log("  PRECONDITION MET: syndicateCount == 0 -- this beacon has no live governor");
            console.log("  proxies, so swapping its impl cannot corrupt anyone. This is the ONLY");
            console.log("  state in which the upgrade is safe on this stack: SyndicateGovernor's");
            console.log("  layout was re-baselined non-append-only (see GovernorLayoutPins.t.sol).");
            console.log("  Re-check the count immediately before broadcasting the upgrade -- a");
            console.log("  syndicate created in between makes it unsafe.");
            console.log("  No pushWiring calls: there are no existing governors to wire.");
        } else {
            console.log("MANUAL NEXT: factory.pushWiring(<each existing governor>) -- %s syndicates.", liveGovernors);
            console.log("  DO *NOT* UPGRADE THE GOVERNOR BEACON ON THIS CHAIN. %s live governor", liveGovernors);
            console.log("  proxies read their impl from it, and this stack's SyndicateGovernor layout");
            console.log("  was re-baselined non-append-only (vault 0->15, _guardianRegistry 43->0,");
            console.log("  _tierRegistry 48->58): an impl swap makes every one of them read garbage.");
            console.log("  No upgrade is needed -- pre-flight 5 confirmed the beacon impl already");
            console.log("  exposes the Plan B wiring, which is why this run was allowed to proceed.");
            console.log("  If some future governor change DOES require a new impl here, those");
            console.log("  syndicates need a FRESH factory + beacon and a migration, not an upgrade.");
        }
        console.log("MANUAL NEXT: hand ledger ownership to the protocol owner (Ownable2Step: transfer + accept).");
    }

    /// @notice True when `beacon`'s CURRENT implementation is a governor that
    ///         already carries the Plan B wiring slots.
    /// @dev Probes for the two views (`exposureLedger()` / `bondEscrow()`) that
    ///      only a Plan B-era `SyndicateGovernor` has. A pre-Plan B impl has no
    ///      such selector and no fallback, so the staticcall reverts and returns
    ///      `false` — which is also the answer for a `beacon` that is not a
    ///      beacon at all, or one whose impl has no code. FAIL-CLOSED
    ///      throughout: every unknown answers "not capable", and pre-flight 5
    ///      turns that into a refusal rather than a silent pass.
    ///
    ///      Deliberately a CAPABILITY probe, not a version or codehash
    ///      comparison. What Plan B needs from the beacon is exactly that
    ///      `setExposureLedger`/`setBondEscrow` land somewhere the governor
    ///      reads back; any impl offering that is fine, and pinning a specific
    ///      codehash would refuse legitimate governor builds for no gain.
    ///
    ///      A `view` staticcall on an UNINITIALIZED implementation is fine here:
    ///      these getters read storage unconditionally, so the selector's
    ///      existence — not the impl's initialization state — is what answers.
    function _beaconServesPlanBGovernor(address beacon) internal view returns (bool) {
        if (beacon.code.length == 0) return false;
        (bool okImpl, bytes memory implRet) = beacon.staticcall(abi.encodeWithSignature("implementation()"));
        if (!okImpl || implRet.length != 32) return false;

        address impl = abi.decode(implRet, (address));
        if (impl.code.length == 0) return false;

        (bool okLedger, bytes memory ledgerRet) = impl.staticcall(abi.encodeWithSignature("exposureLedger()"));
        if (!okLedger || ledgerRet.length != 32) return false;

        (bool okEscrow, bytes memory escrowRet) = impl.staticcall(abi.encodeWithSignature("bondEscrow()"));
        return okEscrow && escrowRet.length == 32;
    }
}
