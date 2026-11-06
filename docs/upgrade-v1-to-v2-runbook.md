# Upgrade runbook — live `v1-deploy` → `post-audit-v2`

Operator procedure for upgrading a LIVE `v1-deploy` deployment on Robinhood (4663)
to `post-audit-v2`. Source: the internal review of 2026-10-01.
The guards this runbook relies on are pinned by
`test/guardian/Upgrade_keepLedgerRotateGame.t.sol`.

Every call below is a Safe transaction unless the caller column says otherwise. On 4663
every contract is owned by the deployer EOA, not a Safe; §9 runs the same steps from that
key with `script/robinhood-mainnet/UpgradeV1ToV2.s.sol`. "Old game" is the live v1 `ChallengeGame`; "new game"
is the v2 `ChallengeGame` deployed in step 1.

---

## 1. Scope

| Contract | Action | Why |
|---|---|---|
| `SyndicateGovernor` (all vaults) | Upgrade in place: `GovernorBeacon.upgradeTo` | Storage layout unchanged |
| `GuardianRegistry` | Upgrade in place: `upgradeToAndCall` (UUPS) | Storage layout unchanged; no `reinitializer` needed |
| `SyndicateFactory` | None | Byte-identical between the two versions |
| `StakedWood` | None | Differs only in comments |
| `SyndicateVault` | §9 seats a v2 impl on the factory and enables upgrades; each creator opts in | The owner cannot upgrade a live vault: `upgradeVault` is creator-only. v1 and v2 storage layouts are identical. A live vault keeps v1 behaviour until its creator calls `upgradeVault` (see below) |
| `StrategyFactory` | None | Redeploying it unregisters live clones. The live factory keeps the v1 clone salt (see below) |
| `ChallengeGame` | **Deploy new**, under a NEW CREATE3 salt, on the existing ledger | v2 game is a rewrite; it is not a proxy |
| `ExposureLedger` | **KEEP the v1 instance** | See below |
| `ProposerBondEscrow` | **KEEP the v1 instance** | Its ledger is immutable; a new escrow would need a new ledger |
| `TierRegistry` | Keep (default) or redeploy (optional, §5) | Every function v2 calls on it exists on the v1 registry |
| `TokenCourt` | Retire after the drain | v2 has no court; keep it running until every old challenge is ruled or timed out |

**SHE-470 fixes on live 4663 vaults.** Vault-side L-1 (net buffer floor), L-2 (`Call.value` refused)
and L-5 (same-owner rotation keeps agents) are in the v2 vault impl that §9 phase 1 seats, provided
phase 1 runs from a `post-audit-v2` checkout that contains #413 (§9). They reach a live vault only
once its creator calls `upgradeVault`. Until then that vault keeps v1 behaviour: gross buffer
formula, agents drained on every rotation, and emergency batches still accept `Call.value` at
`finalizeEmergencySettle` (the governor's L-2 mirror covers `propose` only). L-3 (sender-bound clone salt) applies only to a newly deployed
`StrategyFactory`; the live factory keeps `keccak256(abi.encode(vault, salt))`, so SDK
sherwoodagent/sherwood#737 must not ship while that factory is the one clients talk to.

**Why the ledger and escrow are kept.** A fresh `ExposureLedger` knows none
of the live approver locks, freezes or pins. Re-pointing staking at it lets the
approvers of still-challengeable executed proposals claim their unstake, and those
proposals become unchallengeable (`file` reverts `NothingToFreeze`) — proven by
`test_whyLedgerIsKept_freshLedgerFreesApproverAndBlocksFiling`.

## 2. Facts to start from

1. **No protocol-wide pause on `propose`.** `GuardianRegistry.pause()` stops review
   voting and resolution only. It has no built-in expiry and the owner can hold it
   indefinitely, but after `DEADMAN_UNPAUSE_DELAY` (7 days) anyone can `unpause()`.
   Proposals keep arriving throughout.
2. **`factory.pushWiring(governor)` is the only way to re-point a live governor.** It
   writes the governor's `tierRegistry`, `exposureLedger` and `bondEscrow` slots
   together, and reverts `ParamsFrozenDuringProposal` while that governor has ANY open
   proposal (Executed included), even when the ledger value is unchanged.
3. **Never set the factory's `exposureLedger` to zero.** `pushWiring` skips a zero
   slot, which removes the only guard that stops it swapping the `TierRegistry`
   under an Executed proposal.
4. **Build implementation constructor arguments from the LIVE implementations, not
   from the scripts.**
   - Governor: `SyndicateGovernor(minVotingPeriod_, minCooldownPeriod_)`. Read
     `MIN_VOTING_PERIOD()` and `MIN_COOLDOWN_PERIOD()` from
     `GovernorBeacon.implementation()`.
   - Registry: `GuardianRegistry(minReviewPeriod_)`. Read `minReviewPeriod()` from the
     live implementation (ERC-1967 slot
     `0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc` of the
     registry proxy).
   These are bytecode immutables that bound stored live parameters; a mismatch
   changes which values are accepted — it can loosen the floors, or make later
   `forceSetParams` / `setReviewPeriod` calls fail.
5. **`DeployAll` / `DeploySalts` cannot be reused as-is.** Every salt is in the
   `sherwood.robinhood.v1.*` namespace and `DeployAll.stageOf` treats any predicted
   address that already has code as done, so it will not deploy a new game or
   registry. `DeployPlanD` refuses to rotate roles away from live holders. Use new
   salts (e.g. `sherwood.robinhood.v2.challenge-game`).
6. **`script/verify-robinhood.sh` derives addresses from salts.** After the
   migration it validates the OLD game (and old registry, if replaced). Do not use it
   as the pass signal; use §7.

## 3. Ordered steps

Do the steps in this order. Assert every precondition on-chain immediately before
the step.

Global precondition: `owner() == SAFE` on `StakedWood`, `TierRegistry`,
`ExposureLedger`, `GovernorBeacon`, `GuardianRegistry` and `SyndicateFactory` (and on
the new game after step 1b). `TierRegistry`, `ExposureLedger`, `ChallengeGame` and the v1
`TokenCourt` are `Ownable2Step`: the Safe must have called `acceptOwnership()`, so check
`owner()`, not `pendingOwner()`.

| # | Step | Caller | Call(s) | Assert BEFORE |
|---|---|---|---|---|
| 1a | Deploy v2 implementations | deployer | `SyndicateGovernor(liveMinVoting, liveMinCooldown)`, `GuardianRegistry(liveMinReviewPeriod)` and, for opt-in vault upgrades, `SyndicateVault()`. On 4663 §9 deploys all three through `Create3Factory` under v2 salts | Arguments read from the live implementations (§2.4) |
| 1b | Deploy the v2 game on the EXISTING ledger, via CREATE3 under a new salt | `Create3Factory` owner (deployer) | `create3Factory.deploy(keccak256("sherwood.robinhood.v2.challenge-game"), abi.encodePacked(type(ChallengeGame).creationCode, abi.encode(SAFE, WOOD, existingLedger, tierRegistry)))` — the Safe is `initialOwner` so step 5 is one Safe batch | `create3Factory.addressOf(salt)` has no code and is not any v1 salt's address |
| 1c | Configure the new game | Safe | `newGame.setChallengeWindow(...)` if needed; `setVoteWindow`, `setChallengeQuorumBps`, `setChallengerBondBps`, `setForfeitBurnBps`, `setSettleBurnBps`, `setProsecutorFeeBps` per `docs/pre-deployment-parameter-review.md` | `newGame.challengeWindow() == oldGame.challengeWindow()` (`≤ ledger.challengeWindow()` is already enforced by the constructor and `setChallengeWindow`). Do not "copy" the old game's parameters: the v1 and v2 setter sets differ |
| 2 | Upgrade every governor | Safe | `GovernorBeacon.upgradeTo(govImplV2)` | `govImplV2.MIN_VOTING_PERIOD()` / `MIN_COOLDOWN_PERIOD()` equal the live implementation's |
| 3 | Upgrade the registry | Safe | `GuardianRegistry.upgradeToAndCall(regImplV2, "")` | `regImplV2.minReviewPeriod()` equals the live implementation's |
| 4 | Drain the old game | anyone / court | `oldGame.resolve(id)` once due; disputed challenges: `TokenCourt.refer` → `vote` → `finalize` (which calls `oldGame.rule`). Keep the old game as `swood.authorizedSlasher` and `tierRegistry.authorizedDemoter`, and keep `TokenCourt` wired, until done | See §4 for the choice about old-game filings |
| 5 | Rotate roles — **one Safe transaction through `MultiSendCallOnly` (so `msg.sender` is the Safe for every call), in this order** | Safe | 1. `swood.setAuthorizedSlasher(newGame)` 2. `newGame.setStakedWood(swood)` 3. `tierRegistry.setAuthorizedDemoter(newGame)` 4. `ledger.setCoverageFreezer(newGame)` | (a) `ledger.frozenCoverageCount() == 0`; (b) for every executed proposal: `oldGame.liveChallengeCountOf(governor, proposalId) == 0`; (c) for every executed proposal: `oldGame.challengeableUntil(keccak256(abi.encode(governor, proposalId))) < block.timestamp`. Only (a) is enforced on-chain, so once (a)–(c) hold: `oldGame.setFilingsPaused(true)`, re-check (a)–(c), then execute the batch |
| 6 | Optional: redeploy `TierRegistry` | Safe | §5 | Step 5 done |
| 7 | Re-point governors — ONLY if a factory pointer changed (e.g. §5) | Safe | `factory.setTierRegistry(TR2)` once, then `factory.pushWiring(governor)` for each governor, each inside its post-proposal cooldown | `governor.openProposalCount() == 0` for that governor; afterwards assert its `tierRegistry()`, `exposureLedger()`, `bondEscrow()` (§7) |

About the order in step 5:

- Forced by a guard: `newGame.setStakedWood` reverts `RoleNotGranted` until sWOOD names
  the new game `authorizedSlasher`
  (`test_rotation_setStakedWoodBeforeSlasherGrant_revertsRoleNotGranted`).
- `ledger.setCoverageFreezer` reverts `CoverageFrozen` while any key is frozen, i.e.
  while any old-game challenge is live
  (`test_rotation_setCoverageFreezerWhileOldChallengeLive_revertsCoverageFrozen`).
- Freezer last is a choice, not a guard: it keeps the new game unable to freeze until its
  verdict path (slasher, sWOOD, demoter) is complete, matching `DeployPlanD`. Freezer
  first would also be safe, since the new game's `file` reverts `ZeroAddress` while its
  `stakedWood` is unset.
- One transaction, because `file` is permissionless: a filing on the old game between
  the slasher grant and the freezer rotation freezes a key, makes the freezer call
  revert, and leaves the old game a freezer that can no longer slash. In one batch, such
  a filing simply makes the whole batch revert; retry after the drain.

Precondition (c) is required because the rotation guard counts frozen keys, not
re-armed windows. A challenge that ends without a verdict re-arms
`oldGame.challengeableUntil` for that proposal. That state lives only in the old game.
After the rotation the new game has no record of it: `file` reverts `WindowClosed` on
the new game and `NotCoverageFreezer` on the old one, and the governor's bond-reclaim
gate (which reads the ledger's CURRENT `coverageFreezer`) lets the proposer reclaim the
bond before the re-armed deadline
(`test_rearmedWindow_rotationPassesGuard_filingClosedAndBondReleasedEarly`).

Enumeration recipes for the preconditions:

- Governors: for `i` in `1..factory.syndicateCount()`: `factory.governorOf(factory.syndicates(i).vault)`.
- Executed proposals: for each governor, `pid` in `1..governor.proposalCount()` with
  `governor.getProposal(pid).executedAt != 0`.
- Live old-game challenges: per proposal `oldGame.liveChallengeCountOf(governor, proposalId) != 0`,
  or per challenge (`id` in `1..oldGame.challengeCount()`)
  `oldGame.challengeOf(id).status` is `Filed` OR `Disputed`. The v1 `challengeOf` view
  reports `Disputed` for a live, counter-bonded challenge, so checking `Filed` alone misses
  exactly the challenges that need `TokenCourt.refer` → `vote` → `finalize`; left
  un-referred they time out through `resolve`, which re-arms the window.

Why the precondition re-check matters: the Safe collects signatures over time, and only
(a) is enforced by `setCoverageFreezer`. A challenge filed after the check can end without
a verdict before the batch executes (e.g. a court `Inconclusive`, which refunds and
re-arms), leaving (a) true and (c) false. Pausing old-game filings first closes that gap.

## 4. The drain trade-off — choose explicitly

Pausing old-game filings during the drain and waiting out re-armed windows work
against each other. No ordering avoids both costs. Precondition 5(c) holds either way.

| Choice | How | Cost |
|---|---|---|
| A. Pause | `oldGame.setFilingsPaused(true)` at the start of step 4 | Bounded drain: the longest live challenge's `disputeTimeoutAtFiling` (30 days default, 60 max), plus up to one `challengeWindow` (14 days) for the re-arms it produces. Every proposal is unchallengeable while paused; any filing window — ordinary or re-armed — that ends before step 5 is lost for good. Retiring `TokenCourt` makes re-arms likely: every disputed challenge the court never rules on ends in one |
| B. Keep filings open | Leave the old game accepting filings; run step 5 at the first instant 5(a)–(c) all hold | No window is lost. Unbounded: anyone can postpone the rotation by filing, and the v1 game re-arms with no once-per-proposal limit. v1-only behaviours (e.g. the sibling-challenge referral through `TokenCourt.refer`) stay live for the whole wait |

Rotating with a re-armed window outstanding (skipping 5(c)) is a third option only if
the Safe explicitly accepts, per named proposal, that it becomes unchallengeable and its
proposer bond is released early.

## 5. Optional: if `TierRegistry` is redeployed

Keeping the v1 `TierRegistry` is safe: every function v2 calls on it exists with the
same signature. Redeploy only if there is a reason to. If so, all of the following in
the same Safe batch, BEFORE any governor or the new game is pointed at `TR2`:

1. Deploy `TierRegistry(SAFE)` the same way as the game in step 1b:
   `create3Factory.deploy(keccak256("sherwood.robinhood.v2.tier-registry"), ...)`.
2. `TR2.setStrategyFactory(<existing StrategyFactory>)` — do not redeploy the
   StrategyFactory; existing clones must stay registered. The existing factory keeps the
   v1 clone salt, so SHE-481 (L-3) does not apply on 4663 (§1).
3. Replay every certification: `TR2.certify(target, selector, tier, boundBps, expectedCodehash)`
   and `TR2.certifyClass(template, selector, tier, boundBps, expectedTemplateCodehash)`.
4. Replay the counterparty allowlist: `TR2.setCounterpartyAllowed(counterparty, true)`
   (re-snapshots codehashes).
5. Replay price sources: `TR2.setPriceSourceForToken(token, priceSource, true)`.
6. Replay the Morpho market allowlist: `TR2.setMorphoMarketAllowed(id, true)` for every
   `id` with `TR1.isMorphoMarketAllowed(id) == true` (from `MorphoMarketAllowedSet` events).
   `MorphoSupplyStrategy` and the CL strategy check the market id against the governor's
   current registry in clone `initialize`, on execute and (CL) on `rerange`, so a missing
   id makes new clone creation and those calls revert.
7. Re-deny every pair the old registry had demoted: for each `(target, selector)` with
   `TR1.isClassTierDenied(target, selector) == true` (or a `TierDemoted` event), call
   `TR2.demote(target, selector)` AFTER its class certification (`demote` reverts
   `NotCertified` otherwise). For a class demoted on TR1 (`ClassDemoted`), simply do not
   re-certify it.
8. `TR2.setAuthorizedDemoter(newGame)`; `newGame.setTierRegistry(TR2)`.
9. On TR1, cancel every pending certification (`cancelCertification` /
   `cancelClassCertification`), otherwise anyone can complete it after the delay for
   governors still on TR1.
10. Plan for the v1 registry's submitter bonds: a bond on a pair still certified on TR1
    becomes releasable only after a TR1 `demote` / `demoteClass` starts its
    `bondReleaseDelay` timer (then `claimSubmitterBond` / `claimClassSubmitterBond`).
    Retiring TR1 without demoting leaves those bonds locked.

Then §3 step 7: `factory.setTierRegistry(TR2)` and `pushWiring` each governor in its
cooldown. Until the last governor is re-pointed, the new game demotes only in TR2; on
any conviction the Safe must mirror the demotion on TR1 with `TR1.demote(...)` /
`TR1.demoteClass(...)`. Before re-pointing, diff `tierOf(target, selector)` on TR1 and
TR2 for every pair the protocol has used, and `isMorphoMarketAllowed(id)` for every
Morpho market id a live strategy holds.

## 6. Do not

- Do not redeploy `ExposureLedger` or `ProposerBondEscrow`, and do not call
  `StakedWood.setExposureLedger`, `GuardianRegistry.setExposureLedger`,
  `ChallengeGame.setExposureLedger` or `factory.setExposureLedger` at all during this
  migration (a fresh ledger knows none of the live locks).
- Do not set the factory's `exposureLedger` to zero (§2.3).
- Do not call `ledger.setCoverageFreezer` while any old-game challenge is live or any
  `oldGame.challengeableUntil` is in the future.
- Do not split step 5 across transactions while old-game filings are open (§9).
- Do not run `DeployAll`, `DeployPlanD` or `verify-robinhood.sh` against the live chain
  as part of this migration (§2.5, §2.6).

## 7. Post-migration verification

Read on-chain; every line must hold.

| Check | Expected |
|---|---|
| `GovernorBeacon.implementation()` | `govImplV2` |
| `GuardianRegistry` ERC-1967 implementation slot | `regImplV2` |
| `swood.authorizedSlasher()` | new game |
| `swood.exposureLedger()` | v1 ledger (unchanged) |
| `registry.exposureLedger()` | v1 ledger (unchanged) |
| `ledger.coverageFreezer()` | new game |
| `ledger.frozenCoverageCount()` | `0` immediately after step 5 |
| `tierRegistry.authorizedDemoter()` (TR1, or TR2 if §5) | new game |
| If §5: `TR2.isMorphoMarketAllowed(id)` for every id allowed on TR1 | `true` |
| `newGame.stakedWood()` / `exposureLedger()` / `tierRegistry()` | sWOOD / v1 ledger / the live tier registry |
| `newGame.owner()` | Safe |
| `newGame.challengeWindow()` | `== ledger.challengeWindow()` |
| Old game | holds none of the three roles (slasher, demoter, freezer) |
| `factory.exposureLedger()` / `bondEscrow()` | v1 ledger / v1 escrow (unchanged, non-zero) |
| Every governor's `exposureLedger()` / `bondEscrow()` / `tierRegistry()` | v1 ledger / v1 escrow / factory's `tierRegistry()` |

Update the address book and downstream consumers (CLI, app, guardian, skill) with the
new game address by hand; the salt-derived tooling still points at the old one.

## 8. Limitations

The pinned tests use a v2 game standing in for the live v1 game. The behaviour of the
v1 game and `TokenCourt` during the drain (live-status view, re-arms, court rulings) is
verified by reading `origin/v1-deploy` source only, not by running v1 bytecode.

## 9. Running it with the deployer key

On 4663 the deployer EOA `0x5A00afAecE9CF61A768E2AE2713084C8d354DF94` owns every contract
in §3, so there is no Safe batch. `UpgradeV1ToV2.s.sol` runs §3 in three phases. Each phase
reads its addresses from `chains/4663.json`, checks that the caller is `owner()` of the factory,
beacon, guardian registry, tier registry, sWOOD, ledger, old game, `TokenCourt`,
`StrategyFactory` and `Create3Factory` (not `ProposerBondEscrow`, which has no owner and is
never called), in phases 1-3 refuses a book whose `CHALLENGE_GAME` already names the new game, and runs the
§7 checks that apply at that point.

**Run phase 1 from a `post-audit-v2` checkout at or after `98aa2df4` (the merge of #413).**
The script compiles the governor, registry, vault and game it deploys from the checkout it runs
in. An older checkout would seat a vault impl without the SHE-470 vault fixes (§1), and creators
who opt in would need a second `setVaultImpl` and `upgradeVault` to get them.

| Phase | Entry | Does |
|---|---|---|
| 1 | `runPhase1()` | Steps 1a–3. Implementation arguments come from the live implementations. Deploys the governor, registry and vault impls and the new game through `Create3Factory` under `sherwood.robinhood.v2.{governor-impl,guardian-registry-impl,vault-impl,challenge-game}` (game owner: deployer), and copies the old game's `filingsPaused`. Then upgrades the beacon and the registry, seats the v2 vault impl and sets `setUpgradesEnabled(true)`. Every deploy is skipped when its address has code and every call when already applied, so re-running after a partial broadcast resumes. Run `verifyPhase1()` (read-only) after the broadcast and before phase 3; after phase 3 it fails by design, because the roles have moved to the new game |
| 2 | `runPhase2()` | §4 option A: `oldGame.setFilingsPaused(true)`. No-op if already paused (it was on 2026-11-06) |
| 3 | `runPhase3()` | Refuses unless old filings are paused and 5(a)–(c) hold for every executed proposal. Then step 5 as four transactions, each skipped if already applied, so a re-run resumes |
| Open | `runOpenProtocol()` | Not part of the upgrade; refuses until phase 3 has rotated the freezer and the new game is unpaused (SHE-361). `factory.setCreationFee(token, 0, recipient)` (token and recipient read from the factory), `setOwnerOnlyProposals(false)`, `setDepositsRestricted(false)`, each skipped if already applied. Keeps `agentRegistry` (ERC-8004 identity is still required to create a vault or be registered as an agent). Run `verifyOpenProtocol()` after the broadcast |

```
forge script script/robinhood-mainnet/UpgradeV1ToV2.s.sol:UpgradeV1ToV2 --sig "runPhase1()" \
  --rpc-url "$ROBINHOOD_RPC_URL" --sender 0x5A00afAecE9CF61A768E2AE2713084C8d354DF94 \
  --slow --interactive --broadcast
```

Drop `--broadcast` for a dry run. Use the same command with `runPhase2()` and `runPhase3()`,
and without `--interactive --broadcast` for `verifyPhase1()`. If a phase-1 transaction fails or
is dropped, re-run `runPhase1()` **from the same commit** (record `git rev-parse HEAD` with the
phase-1 log): it picks up at the first step not yet applied, and refuses code already at a salt
that differs from what the current checkout would deploy (immutables masked). Every runtime
size is under 4663's 98,304-byte limit (governor 36,815), so no code-size flag is needed.
`--interactive` is a flag and takes no value. The script writes nothing to the address book.
After phase 3, set `CHALLENGE_GAME` to the new game by hand (§7).

**Opening the protocol (`runOpenProtocol`).** On 2026-11-06 the live factory charges a
`1e24` WOOD creation fee (invite-only, waived per creator by `creationSponsored`), allows only a
vault's owner to propose (`ownerOnlyProposals`), and restricts every vault to approved
depositors (`depositsRestricted`). After the open step:

- anyone with an ERC-8004 identity creates a vault for free (sWOOD `minOwnerStake` is `0`, so no
  prepared stake is needed);
- any agent the vault owner registered (`vault.registerAgent`) proposes and co-proposes;
- deposits follow each vault's own flag: `SyndicateVault._depositsOpen()` is
  `_openDeposits && !factory.depositsRestricted()`. New vaults set it with
  `config.openDeposits` at `createSyndicate`. The three live vaults were created with
  `openDeposits == false`, so they stay whitelist-only until their owner calls
  `vault.setOpenDeposits(true)`. This is by design, not a gap in the step.

**Order: unpause first, then open.** `runOpenProtocol()` refuses while the new game's filings
are paused (`OPEN: unpause filings first (SHE-361)`). SHE-352 justified the pause only because
deposits were whitelisted and only vault owners could propose; opening while paused would let any
registered agent's proposal execute with nobody able to challenge it. So the sequence is:
`setFilingsPaused(false)` on the NEW game `0x0d215e4cEd550525fa2F5b2B33E49e671326D72d` (SHE-361),
then `runOpenProtocol()`.

Free creation also makes subdomains first-come at gas cost: `subdomainToSyndicate` is claimed by
whoever creates first. `creationSponsored` waivers stay set while the fee is 0, so if the fee is
ever raised again those creators still get one free creation.

**Creator actions after phase 1 and the open step.** Each vault owner decides, per vault:
`factory.upgradeVault(vault, expectedImpl)` to move to the v2 vault impl (creator only), and
`vault.setOpenDeposits(true)` to accept deposits from anyone (vault owner only).

**Vault upgrades stay enabled.** Phase 1 sets `factory.setUpgradesEnabled(true)`, and it stays
on by decision: the owner wants to be able to upgrade vaults later. Before phase 1 a live vault's
code was fixed (`upgradesEnabled == false`). After it, the trust model is: the factory owner
chooses the vault impl with `setVaultImpl`; each creator opts in per vault with
`upgradeVault(vault, expectedImpl)`, which reverts `VaultImplMismatch` if the owner changed the
impl in between, `StrategyActive` while a strategy is live, and `ProposalsOpen` while the vault's
governor has any open proposal. Depositors therefore rely on the owner and the vault's creator
together for the vault's code.

**Ownership handoff.** The new game is owned by the deployer and is not in
`DeployAll._handoffAll`, which hands off the salt-derived v1 game. If ownership of the protocol
ever moves to a Safe, the v2 game needs its own `transferOwnership` (it is `Ownable2Step`: the Safe
must then `acceptOwnership()`).

**The new game starts paused.** Phase 1 copies the old game's `filingsPaused`, which is `true`
on 4663 (SHE-352 beta posture), so the new game takes no filing until its owner calls
`setFilingsPaused(false)` on it. SHE-361's unpause must target the NEW game,
`0x0d215e4cEd550525fa2F5b2B33E49e671326D72d`, not the old one, and its criteria need restating
for the v2 vote (7-day vote window, 3000 bps quorum): the SHE-352 rationale was about the v1
court path, which v2 does not have. Unpausing is not part of this procedure. Until it happens,
the two executed proposals still inside their filing window cannot be challenged, and their
windows lapse (`executedAt + strategyDuration + 14d`):

| Governor | Proposal | Filing window closes |
|---|---|---|
| `0x01FA20667Cb4A27DdA5FfE375a1cece3e61B35aD` (syndicate 2) | 5 | 2026-11-13 18:26 UTC (`1794594417`) |
| `0x6b52ED9FB522AC17e6c6FD199b0Ffb7B314871C5` (syndicate 1) | 8 | 2026-11-18 21:33 UTC (`1795037602`) |

**Step 5 without the batch.** §3 asks for one transaction because a `file` landing between
the slasher grant and the freezer rotation wedges the freezer call. Old filings are paused
before phase 3, so that `file` reverts with `FilingsPaused`. A filing on the new game reverts
with `ZeroAddress` until `setStakedWood` runs, and with `NotCoverageFreezer` until the
freezer rotation runs; the fork test checks this with the new game unpaused, the worst case.
No challenge exists on either game, so `resolve`, `dispute` and `TokenCourt.refer` have nothing to act on, and nothing else
can freeze a key or re-arm a window. Pinned on a 4663 fork by
`test/fork/UpgradeV1ToV2Fork.t.sol`:
`test_fork_gap_noFilingLandsBetweenRotationSteps` (no filing lands in any gap, with the new
game unpaused), `test_fork_gap_openOldFilingsWedgeFreezerRotation` (the hazard when old
filings are open), and `test_fork_gap_phase3RefusesWhileOldFilingsOpen`.

The fork suite runs only with `ROBINHOOD_RPC_URL` on an archive node and `UPGRADE_FORK_ARCHIVE=true`
(the block is pinned and the public RPC prunes history), so the weekly `fork-tests.yml` run skips it.
