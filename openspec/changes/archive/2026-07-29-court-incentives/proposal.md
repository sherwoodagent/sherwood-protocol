# Court Incentives — making filing rational, voting honest, and the fallback real

> Migrated from docs/superpowers/plans/2026-07-29-court-incentives.md + docs/superpowers/specs/2026-07-29-court-incentives-design.md (superpowers workflow) on 2026-08-01.

## Why

The adversarial review of PR #52 found the TokenCourt code sound but the *mechanism* underpowered, all tracing to one root: nobody is paid to make the system work, and nobody pays for getting it wrong. A correct, unanswered challenge lost money (−20% of bond, A4/F7); a fully exited holder could vote forever at 25% of historic weight (B4); "Inconclusive is survivable because the proposal is re-challengeable" was arithmetically false past day 2 with the accused controlling the clock (M3); and voters were paid nothing, making abstention dominant (M2). Jury capture (M1 — the accused outbids the challenger ~20:1 for a jury with nothing at risk) was **accepted as risk, not solved** — see design.md §6. Four review defects (B1–B4) also needed fixes.

## What Changes

- **Conviction bounty (on-chain):** `StakedWood.slashToEscrow` gains `bountyTo`/`bountyBps` calldata params (no new storage — layout goldens untouched); the bounty is deducted off the top before `openCase` so escrow `proceeds` stay honest. `ChallengeGame` pins `convictionBountyBpsAtFiling` (default 500 bps, bounded [0, 2000]) and pays it **only on the escalated `Guilty` ruling** — never on the silence path, where an honest filer and a liar are indistinguishable to the contract and the two constraints (make honest filing profitable / keep false filing unprofitable) are contradictory at every rate. Not paid on `_fail`, `_refundAll`, or the `_convicted` short-circuit. The approver-membership gate on `contested` keeps the bounty from turning M1 into a profitable-prosecution attack.
- **Present-holdings gate (B4):** `TokenCourt.vote` additionally requires `getVotes(msg.sender) != 0` — a gate, never a weight; historical snapshot weight still decides how much a vote counts (the flash-loan defence is unchanged).
- **Re-challenge window extension (M3):** per-`reviewKey` `challengeableUntil` deadline, extended (never shortened) on every Inconclusive unwind; `file` reads it with fallback to `executedAt + challengeWindow`. Stalling now buys the accused a delay, not an acquittal.
- **Defect fixes:** case registry namespaced by `(game, challengeId)` (B1 — a redeployed game's ids restart at 1); `NotCourt` bubbles out of `finalize`'s selector filter instead of being swallowed (B2 — it is retryable, not terminal); cross-contract window invariant `autoSlashDelay + voteWindow + FINALIZE_BUFFER <= disputeTimeout` enforced on all three setters across both contracts (B3).
- **Spec/natspec honesty pass:** the 2026-07-28 design's capture-economics claim corrected (M1); A1 (address splitting defeats `AccusedCannotVote`), A2 (last-mover advantage), A5 (`getPastVotes` age-factor drift, confirmed on the real contract) documented where they live.
- **Escalating Inconclusive burn (§8):** per-proposal `inconclusiveRounds` with schedule 0 / 500 / 1,000 / `inconclusiveBurnBps` bps for rounds 1/2/3/4+, pinned at filing, clamped to live `settleBurnBps`, counter reset when the re-armed window lapses.
- Off-chain majority-side APY for voters is policy, not code — deliberately no contract change.
- Full mutation battery: every load-bearing line verified by applying the mutation and watching the named test fail.

## Capabilities

- token-court
- challenge-game
- guardian-staking

## Impact

- Modified: `src/StakedWood.sol` + `src/interfaces/IStakedWood.sol` (`slashToEscrow` signature, `ConvictionBountyPaid` event; UUPS layout goldens unchanged)
- Modified: `src/ChallengeGame.sol` + `src/interfaces/IChallengeGame.sol` (`convictionBountyBps` + pin, `challengeableUntil`, `inconclusiveRounds`/`inconclusiveBurnBpsAtFiling`, `_requireWindowFits`, `WindowInvariantViolated`)
- Modified: `src/TokenCourt.sol` + `src/interfaces/ITokenCourt.sol` (present-holdings gate, `caseOfChallenge[game][id]`, `NotCourt` bubbling, `setVoteWindow` invariant mirror)
- Modified: `test/mocks/MockStakedWood.sol`, `test/StakedWood*`, `test/ChallengeGame.t.sol`, `test/TokenCourt.t.sol`
- Docs: capture-economics correction applied to the 2026-07-28 token-court design (`openspec/changes/archive/2026-07-28-token-court/design.md` §1)
