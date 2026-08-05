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

1. **Spec describes a retired subsystem.** `openspec/specs/epoch-nav/spec.md`
   and parts of `syndicate-vault/spec.md` describe a `PriceRouter` / "Lane A
   live-NAV" mechanism. `SyndicateFactory.sol:127` marks the slot
   `__deprecated_priceRouter`, and `SyndicateVault.totalAssets()` is
   `balanceOf(asset) − reservedQueueAssets()` with no router term. Consequence:
   a live strategy's PnL is invisible to share price until settlement. Several
   SHALL-clauses in that spec cannot be checked against this codebase at all.
2. **Agent-fee NatSpec drift, two figures on one interface.** Both are on
   `ISyndicateVault.sol`, and both disagree with the constants they name:
   - line 168 says the fee "Defaults to 5% (500)", but
     `FeeConstants.DEFAULT_AGENT_FEE_BPS = 2000` — 20%, a 4× understatement.
   - line 172 says `setAgentFeeBps` is "Capped at `MAX_AGENT_FEE_BPS` (15%)",
     but `SyndicateVault.sol:84` sets `MAX_AGENT_FEE_BPS =
     FeeConstants.MAX_PERFORMANCE_FEE_BPS = 3000` — 30%, double the stated cap.

   The same 5%/20% drift was corrected in `SyndicateVault.sol` itself by the
   comment-trim work already on `main`; the interface copy was missed, so the
   stale number now survives only on the file integrators actually read.
   `guardian-coverage/spec.md` and `syndicate-governor/spec.md` still say
   `1500` as well. Code is authoritative in all four places.
3. **Covered-TVL cap is per-proposal, not protocol-wide.**
   `requireWithinCoveredTvlCap` checks one proposal against `coveredTvlCapUsd`
   with no running accumulator, so N vaults could each sit just under it. G-40
   describes it as a ceiling on *simultaneously* covered TVL. Not reachable in
   this harness (single vault), so untested here.
4. **Challenge economics can be configured into a losing game.**
   `honestFilingBreaksEven` / `honestFilingNetPayoffBps` *report* the break-even
   condition; no setter enforces it across the three parameters that determine
   it. Captured as GL-51, not yet implemented.

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
