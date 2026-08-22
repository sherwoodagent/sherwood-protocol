# Fizz Report — Sherwood Protocol

**Commit:** `3f1099c` (`worktree-vivid-mixing-piglet` = `origin/main` merged with the
local audit-gap fixes) · **Date:** 2026-08-04 · **Fuzzer:** Medusa 1.5.1

---

## Outcome

A stateful fuzzing suite now exists where none did. The protocol had 19 Foundry
invariants and **zero** Echidna or Medusa campaigns; the x-ray audit catalogued
**17 invariants that are real but not asserted on-chain**. This suite targets
exactly that gap.

**Final campaign: 130 tests passed, 0 failed.**

No protocol violation was found. Two violations appeared in the first campaign;
both were defects in the properties themselves, diagnosed and fixed (below).
That distinction is the point of the SHOULD-HOLD / EXPLORATORY tagging — a
violated property is a lead, not a verdict, until a harness bug is ruled out.

---

## What was built

| Artifact | Contents |
|---|---|
| `test/fizz/` | Full harness: 12 protocol contracts + 6 mocks/fixtures deployed, 6 actors, 102 handler entry points across 10 handler contracts |
| `PROPERTIES.md` | 89 curated properties (51 global, 38 specific), distilled from 138 candidates |
| `test/fizz/Properties.sol` | 23 global properties implemented and passing |
| `x-ray/` | Pre-audit report regenerated against this commit — verdict **HARDENED** |
| `fizz_data/coverage-targets.md` | Per-contract targets, cycle history, and why cycles 2–3 were invalid |

The harness deploys the real stack — `SyndicateVault`, `SyndicateGovernor`,
`GuardianRegistry`, `StakedWood`, `ExposureLedger`, `ChallengeGame`, `TokenCourt`,
`TierRegistry`, `ProposerBondEscrow`, `VaultWithdrawalQueue` — behind real
ERC-1967 proxies with production init signatures, plus a certified adapter,
three matured guardians and a seeded vault.

---

## Coverage

| Contract | Target | Start | Final | |
|---|---:|---:|---:|:--:|
| VaultWithdrawalQueue | 70% | 14.0% | **91%** | ✅ |
| ProposalLifecycle | 70% | — | **87%** | ✅ |
| GovernorEmergency | 70% | — | **74%** | ✅ |
| SyndicateVault | 70% | 37.1% | **73%** | ✅ |
| GovernorParameters | 70% | — | 69% | ❌ |
| TierRegistry | 50% | 61.3% | **64%** | ✅ |
| StakedWood | 70% | 63.3% | 64% | ❌ |
| SyndicateGovernor | 70% | 12.4% | 63% | ❌ |
| GuardianRegistry | 50% | 19.8% | 40% | ❌ |
| ProposerBondEscrow | 40% | 8.5% | 34% | ❌ |
| ExposureLedger | 70% | 19.3% | 33% | ❌ |
| TokenCourt | 70% | 29.5% | 29% | ❌ |
| ChallengeGame | 70% | 20.3% | 26% | ❌ |

**5/13 at target.** Targets are set ~10 points below normal because the fuzz
profile must keep `via_ir` on (the repo hits stack-too-deep without it), which
deflates measured coverage.

The LP and governance lanes are well covered. **The adjudication chain is not**,
and that is the clearest remaining gap — see Next Steps.

---

## Findings

### No protocol bugs

The campaign found no violation of any implemented property. That is a real but
bounded result: 23 of 89 catalogued properties are implemented, and the
adjudication subsystem — where the most unenforced invariants live — is only
~30% covered. **Absence of findings here is not evidence of absence of bugs.**

### Two property defects, found and fixed

Both surfaced as SHOULD-HOLD failures in the first campaign and both turned out
to be mine, confirmed by deterministic Foundry repros (`test_triage_GL09`,
`test_triage_GL16`, both retained in `FoundryTester.sol`):

- **GL-09** asserted `Σ tracked share balances == totalSupply`. The unclamped
  handlers take a **raw** `receiver` / `to` by design, so the fuzzer can park
  shares outside the actor set. Repro: a deposit to `0xBEEF` leaves 1e15 shares
  uncounted. Relaxed to `<=`, which still catches a phantom burn.
- **GL-16** compared `openProposalCount` against a count derived from `stateOf`.
  `stateOf` is a **true view** that resolves terminal states the instant they
  are determinable; `_openProposalCount` decrements only when `_commitState`
  commits. Repro: 60 days after propose, `stateOf` reads Expired while the
  counter is still 1. Relaxed to `>=`, which still catches the counter dropping
  below the number of genuinely live proposals.

> **Note on `fizz_data/corpus_medusa/test_results/`:** the 12 JSON files there are
> artifacts of the FIRST campaign (16:25), before GL-09 and GL-16 were corrected.
> The final campaign (16:59) produced none. They are stale — do not read them as
> current findings. `medusa-run.log` holds the authoritative summary.

### Observations worth a human look (not fuzzer findings)

Surfaced by the discovery agents and verified by direct source reading. None is
a confirmed bug; each is a documentation or design question:

1. **Spec described a retired subsystem — RESOLVED.** `openspec/specs/`
   described a `PriceRouter` / "Lane A live-NAV" mechanism that no longer
   exists: `SyndicateFactory.sol:127` marks the slot `__deprecated_priceRouter`,
   and `totalAssets()` is idle balance minus `reservedQueueAssets()` and the
   escrowed fee liability, with no router term.

   The cause was narrower than "the spec is stale". A complete change proposal,
   `openspec/changes/retire-lane-a`, had already been written *with its five
   spec deltas*, and the entire code deletion had shipped — but the change was
   never marked applied, so section 8.1 (the spec sync) never ran and
   `openspec/specs/` kept describing the deleted lane. Applied on branch
   `fix/spec-drift-and-cap-gaps`: the deltas landed, `instant-exit-fees` was
   deleted whole (its one general requirement relocated to `syndicate-vault`),
   and the change was archived.
2. **Agent-fee NatSpec drift, two figures on one interface.** Both are on
   `ISyndicateVault.sol`, and both disagree with the constants they name:
   - line 168 says the fee "Defaults to 5% (500)", but
     `FeeConstants.DEFAULT_AGENT_FEE_BPS = 2000` — 20%, a 4× understatement.
   - line 172 says `setAgentFeeBps` is "Capped at `MAX_AGENT_FEE_BPS` (15%)",
     but `SyndicateVault.sol:84` sets `MAX_AGENT_FEE_BPS =
     FeeConstants.MAX_PERFORMANCE_FEE_BPS = 3000` — 30%, double the stated cap.

   The same 5%/20% drift was corrected in `SyndicateVault.sol` itself by the
   comment-trim work already on `main`; the interface copy was missed, so the
   stale number survived on the file integrators actually read.

   **RESOLVED on `fix/spec-drift-and-cap-gaps`.** The drift turned out to span
   five sites, not the two originally reported — all traceable to the archived
   `2026-07-24-fee-mechanism` change (which raised the ceiling 1500 → 3000 and
   set the default to 2000) never being propagated into the specs:
   `ISyndicateVault.sol` lines 168 and 172, `syndicate-vault/spec.md`,
   `guardian-coverage/spec.md`, and `syndicate-governor/spec.md` in two places
   (the setter bound `≤ 1_500`, actually `MAX_PERFORMANCE_FEE_CAP` = 3000; and
   the factory default `1_500`, actually `DEFAULT_MAX_PERFORMANCE_FEE_BPS` =
   2000). Code was authoritative in all five.
3. **~~Covered-TVL cap is per-proposal, not protocol-wide.~~ RETRACTED — this
   observation was wrong.** It claimed `requireWithinCoveredTvlCap` leaves
   aggregate exposure unbounded because N vaults could each sit just under
   `coveredTvlCapUsd`, and cited G-40. Both halves were wrong:

   - **G-40 is about something else.** It pins `TokenCourt`'s participation
     floor against sWOOD's age-weight floor (`x-ray/invariants.md`,
     `TokenCourt.sol:258`). Nothing in it concerns covered TVL. The citation was
     fabricated by cross-reference, not read.
   - **Aggregate exposure is bounded, just not by this cap.** `recordApproval`
     computes `capUsd = kNumerator * _slashableBondUsd(guardian, …)` against
     `open = openExposureUsd(guardian)`, and `_buckets[guardian][epoch]` is
     keyed by GUARDIAN, not by vault — so a guardian's exposure already sums
     across every vault they cover, and booking stops at `open >= capUsd`. The
     binding constraint is the guardian's own bond budget.

   `coveredTvlCapUsd` is a per-proposal ceiling, and
   `guardian-coverage/spec.md` specifies it as exactly that. Code and spec
   agree; there was no gap.
4. **Challenge economics can be configured into a losing game.**
   `honestFilingBreaksEven` / `honestFilingNetPayoffBps` *report* the break-even
   condition; no setter enforces it. Captured as GL-51.

   Worth stating explicitly, because "add a setter guard" is the obvious wrong
   fix: enforcement per-setter would be incorrect on three counts. The inputs
   span two contracts (`proposerBondBps` lives on `ExposureLedger`, the other
   three on `ChallengeGame`), so no single setter owns the invariant. Enforcing
   it would also brick reconfiguration — moving between two valid configurations
   can require an intermediate that violates it. And the figure is a *lower
   bound* that prices only the silence branch; the escalated branch pays
   `bond + pool − burned`, which the NatSpec says is deliberately not modelled,
   so a negative reading is not by itself a losing game. It is a monitoring
   surface by design, which is why GL-51 is tagged EXPLORATORY rather than
   SHOULD-HOLD.

---

## Toolchain problems hit (and how they were solved)

Recorded because each cost a full run and each will recur:

1. **`targetContractsBalances` was `2^192−1`** — more ether than the deployer
   holds. Medusa died at chain init before any fuzzing. Set to 1e24 wei.
2. **The harness cannot be its own factory.** Under Medusa/Echidna `setup()`
   runs in `FuzzTester`'s *constructor*, so `address(this).code.length == 0`;
   `SyndicateVault._getGovernor()` calls back into the factory on every deposit
   and reverts. Foundry hides this entirely because `setUp()` runs
   post-deployment. Fixed with `FizzFactory`, a separately-deployed stand-in
   that also deploys the vault proxy (`initialize` records `_factory = msg.sender`).
3. **`crytic-compile` version incompatibility.** forge 1.7.1 writes slim
   build-info (`id`, `language`, `source_id_to_path`) with no `output` key;
   crytic-compile **0.3.7** raises `KeyError: 'output'`. Nix exposes only 0.3.7,
   transitively via slither. **0.3.10** works. Runs must put its store path
   first on `PATH`.
4. **Stale export + stale corpus produced two fake "measurements."** Cycles 2
   and 3 reported coverage byte-identical to cycle 1 while an 857-sequence
   corpus replayed against an export that never contained the new code. Clear
   `fizz_data/crytic-export` and `fizz_data/corpus_medusa` after any harness change.
5. **`propose` rejects empty execute batches** (`EmptyExecuteCalls`), and batch
   calls must survive `_guardBatchCalls`. Added `FizzAdapter`, certified at
   tier 1 with a 50% bound and explicitly allowlisted.

---

## Next steps, highest value first

1. **Add a challenge-lifecycle composite.** The single biggest coverage lever.
   `ChallengeGame` 26%, `TokenCourt` 29%, `ExposureLedger` 33% and
   `ProposerBondEscrow` 34% are all gated behind the same chain:
   execute → file → dispute-to-pool-completion → refer → vote → finalize → rule.
   Random sequencing almost never assembles it, exactly as it never assembled
   propose→execute before `syndicateGovernor_lifecycle_toExecuted` was added.
   One `challengeGame_lifecycle_toConviction` handler should move all four.
2. **Implement the remaining 66 properties**, prioritising GL-12/GL-13/GL-49
   (the ExposureLedger shared-stake accumulators — x-ray X-8, the mathematical
   core of the protocol's central economic claim, currently asserted nowhere)
   and the SP-NN handler-level postconditions.
3. **Run Echidna as a complementary pass.** `echidna.yaml` is configured and its
   `balanceContract` is already corrected; Echidna's shrinking differs from
   Medusa's and tends to find different sequences.
4. **Longer campaigns.** These runs were 600s. `testLimit` is 500 000; a
   multi-hour run against the same corpus directory will go deeper.
5. **Add `crytic-compile` to `packages.nix`** so the working 0.3.10 is on `PATH`
   rather than reached through a Nix store path that garbage collection can remove.

---

## Running it

```bash
# Medusa. Needs `crytic-compile` on PATH, version 0.3.10 or newer — 0.3.7 dies
# with `KeyError: 'output'` because forge's slim build-info has no `output` key.
# If your distro ships an older one, a throwaway venv is enough:
#   python3 -m venv /tmp/cc && /tmp/cc/bin/pip install 'crytic-compile>=0.3.10'
#   export PATH="/tmp/cc/bin:$PATH"
crytic-compile --version   # confirm >= 0.3.10 before starting a long campaign
medusa fuzz

# Echidna
echidna . --contract FuzzTester --config echidna.yaml

# Foundry debug harness (setup sanity + the two triage repros)
forge test --match-contract FoundryTester -vvv
```

After any harness change, clear `fizz_data/crytic-export` and
`fizz_data/corpus_medusa` before re-running, or the campaign will silently
replay stale artifacts.

---

## Deep campaign, 2026-08-05 (post challenge-lifecycle composite)

**140 properties passed, 3 failed.** All three failures are informative rather
than regressions — two are EXPLORATORY properties doing their job, one was a
defect in a property added the same day.

### Coverage: the adjudication chain unblocked

| Contract | Before | Now | Lines |
|---|------:|----:|------:|
| ChallengeGame | 26% | **64.2%** | 201/313 |
| TokenCourt | 29% | **83.3%** | 100/120 |
| ExposureLedger | 33% | **83.3%** | 309/371 |
| ProposerBondEscrow | 34% | **88.6%** | 31/35 |

The cause was NOT only the missing composite. Two silent harness bugs meant no
proposal had ever booked guardian coverage: `_benignBatch` declared all-zero
per-call caps (caps price coverage, so `requiredCoverage` was always 0), and
the lifecycle composite cast its guardian approve vote before `openReview`, so
it reverted `ReviewNotOpen` into a try/catch. `ChallengeGame.file` therefore
reverted `NothingToFreeze` on every attempt in every prior campaign. The
composite alone would have hit the same wall.

**Caveat on the other rows.** This run was stopped at ~3 minutes / 8k calls
because a concurrent process drove the machine into swap; the baseline runs
were 600s. Contracts not on the critical path show lower numbers than the
baseline for that reason alone (`TierRegistry` 64% -> 37%,
`VaultWithdrawalQueue` 91% -> 76%) — that is less fuzzing time, not a
regression. The four target contracts improved *despite* the shorter run.

### GL-49 violated — x-ray X-8 does not hold as a standing invariant

Two calls from clean state: `syndicateGovernor_lifecycle_toExecuted` then
`challengeGame_lifecycle_toConviction`. `recordApproval` enforces
`open < kNumerator * slashableBondUsd` at BOOKING time, but the right side is a
live read — a conviction slashes the approvers, their bond falls, and the
coverage booked against it does not move.

Not automatically a bug (the exposure covers an already-adjudicated proposal),
but E-1 rests on this figure, and it is reachable in two calls with no
adversarial parameter tuning. Whether post-slash exposure should unwind, or the
claim be restated as a booking-time precondition, is worth an explicit decision.

### GL-51 violated — one setter call switches the challenge game off

Shrunk to a single call from deploy defaults: `setChallengerBondBps(3238)` gives
`honestFilingNetPayoffBps() == -1_419_000`. With shipped defaults
(`proposerBondBps` 100, `prosecutorFeeBps` 2000, `settleBurnBps` 500) the
break-even challenger bond is **400 bps**. The default 150 is safe, but the
setter accepts up to 10 000 — 25x past the point where filing an honest
challenge stops paying, with no warning and no timelock on that surface.

### GL-10 violated — the property was wrong, now fixed

`donateERC20 -> lifecycle_toExecuted -> lifecycle_toSettled`. The property
enumerated actors plus vault/queue/adapter/governor and asserted no handler
could route assets elsewhere. Settlement pays fees: the management fee goes to
the vault owner and the protocol/guardian legs to whatever `ProtocolConfig`
names, none of which were counted. Holder set corrected; kept as `==` so a
future new sink still surfaces.

### Echidna

**Result: 113 tests passing, 0 failing** (incl. `AssertionFailed(..)`) — no
panic, assertion failure or unexpected revert reachable across the handler set.

`echidna.yaml` runs `testMode: assertion`, which hunts panics and assertion
failures across the handlers. It does NOT evaluate the `property_*` bool
returns — that needs `testMode: property`, which reverts state after each
property call and would break the self-updating ghosts GL-23/25/32/33/35/37
depend on. Echidna is therefore complementary in bug CLASS here, not a second
opinion on the same properties.

Two config blockers had to be cleared before it would start, both worth knowing
if this is re-run:

1. **Unlinked libraries.** Echidna refuses to start if ANY contract in the
   compilation unit carries unlinked library bytecode, and
   `--foundry-compile-all` pulls in `script/Deploy.s.sol`. Fixed with
   `--compile-libraries`.
2. **The linked address must actually hold the library.** `SyndicateVaultAdminLib`
   has external functions, so `SyndicateVault` reaches it by DELEGATECALL
   (`registerAgent` / `removeAgent`). Linking it to an empty address is not
   cosmetic — those calls revert with no data, and the symptom is `setup()`
   dying on its very last line at `vault.registerAgent`, which reads like a
   harness bug rather than a config one. `deployContracts` now places the
   library at the linked address before the harness constructor runs.
