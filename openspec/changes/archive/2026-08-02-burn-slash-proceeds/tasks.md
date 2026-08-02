# Tasks — Burn Slash Proceeds

## 1. Confirm assumptions before deleting anything

- [x] 1.1 RESOLVED — WOOD has no `burn()` / `ERC20Burnable`. Sink stays
      `BURN_ADDRESS` (`0x...dEaD`), which `StakedWood.sol:526-530` already chose
      deliberately to avoid a burn dependency on the token. No contract in
      `src/` reads WOOD `totalSupply`, so the accumulating dead balance pollutes
      no internal denominator. See design.md R1.
- [x] 1.2 RESOLVED — no mainnet 4663 deployment exists and testnets are
      redeployable, so slots are removed outright rather than deprecated.
      Precedent: the 2026-07-26 DPoS re-baseline (`StakedWood.sol:410-427`).
      See design.md R6.
- [x] 1.3 RESOLVED — wrote `test/SlashGasCeiling.t.sol` against a real
      `StakedWood` proxy. Measured `slashVerdict`: 137k @ 1 approver, 824k @ 10,
      4.44M @ 50, 9.97M @ 100 (marginal ~101.6k, rising with cohort size because
      the duplicate scan is O(n²)).

## 2. Punitive sizing (the half that actually changes deterrence)

- [x] 2.1 Replace the proportional allocation in `ExposureLedger.slashBpsFor`
      with a uniform `maxSlashBps` rate for every named approver; keep the
      released-reservation skip. Returns `BPS_DENOMINATOR` and lets
      `_slashOne`'s existing clamp apply the ceiling, so severity stays
      governed at one site. Side effect: the view no longer reads any price
      feed, removing the documented conviction-unpriceable liveness hole.
- [x] 2.2 Rewrite the `requireApproveQuorum` rationale block
      (`ExposureLedger.sol:1040-1082`) from indemnity to eligibility floor, and
      retire the N3 `maxSlashBps` shortfall note as no longer applicable.
- [x] 2.3 Update `ChallengeGame._accusedWithRates` for the new rate source. The
      zero-filter needs no code change (released approvers still report 0), but
      three stale rationales did: the challenger-bond basis note
      (`ChallengeGame.sol:811`), `IChallengeGame.frozenCoverageUsd`, and the
      `slashBpsFor` / `liabilityUsd` docs in `IExposureLedger`.
- [x] 2.4 Tests: an approver's slash is unchanged when a proposal's declared
      coverage is understated; a released approver is still skipped. Rewrote the
      six `slashBpsFor` tests in `ExposureLedger.t.sol` as INVARIANCE tests —
      the rate is unmoved by commitment size, bond size, required coverage, the
      WOOD feed, and the haircut. The rounding test is deleted (no division
      left); the saturation test becomes a ceiling-holds test.

## 3. Burn sink

- [x] 3.1 Rename `StakedWood.slashToEscrow` to `slashVerdict`; drop the `vault`
      and `snapshotTimestamp` parameters and the `caseId` return.
- [x] 3.2 Replace the `try openCase / catch _burnWood` block with an
      unconditional `_burnWood(total)`; delete `_isRecoverableOpenCaseFailure`
      and the `forceApprove` pair.
- [x] 3.3 Delete `compensationEscrow`, `setCompensationEscrow`,
      `CompensationEscrowNotSet`, `CompensationEscrowSet`,
      `VerdictSlashRouted`, `VerdictSlashUncompensated`, `SnapshotAfterVerdict`,
      and the `factory.governorOf(vault)` membership check.
- [x] 3.4 Keep the bounty leg and the unconditional `MAX_CONVICTION_BOUNTY_BPS`
      check verbatim; add a `VerdictSlashBurned` event carrying `caseKey`,
      gross, bounty, and burned amounts.
- [x] 3.5 Mirror every signature, event, and error change in
      `src/interfaces/IStakedWood.sol` and update the `ChallengeGame` call site.

## 4. Remove the compensation machinery

- [x] 4.1 Delete `src/CompensationEscrow.sol` and
      `src/interfaces/ICompensationEscrow.sol`.
- [x] 4.2 Delete `VaultWithdrawalQueue.claimCompensation`, `compensationCase`,
      `compensationClaimed`, `CompCase`, `_compCases`, `_compClaimed`, and their
      events and errors. Decide whether `Request.queuedAt` / `closedAt` still
      have a consumer; remove them if not.
- [x] 4.3 Delete `SyndicateFactory.compensationEscrow` and its setter, plus the
      `ISyndicateFactory` entry.
- [x] 4.4 Delete `DeployPlanD` pre-flight 1 and renumber the remaining
      pre-flights.
- [x] 4.5 Delete `CompensationEscrow.t.sol`, `CompensationEndToEnd.t.sol`,
      `StakedWoodSlashToEscrow.t.sol`, `SlashToEscrowProportional.t.sol`; update
      `CoverageEndToEnd.t.sol` and `TokenCourtEndToEnd.t.sol` to assert burn
      instead of escrow.

## 5. Resolve the vestigial vault behavior

- [x] 5.1 Decide whether `SyndicateVault`'s auto-delegate-on-`_update` is still
      wanted for governance. Either rewrite its natspec justification or remove
      the behavior — do not leave the compensation-claim rationale in place.

## 6. Re-derive gas and re-validate incentives

- [x] 6.1 DONE — `SLASH_GAS_PER_APPROVER` 300k -> 110k; `SLASH_GAS_BASE` kept at
      1M but REPURPOSED as the post-slash reserve. The floor still has a job:
      `demoteByChallenge` runs after the slash inside a bare `try/catch`, so a
      caller who leaves it starved gets a silently-skipped adapter demotion
      rather than a revert. Floor at the 100-approver cap: 12M against a
      measured 9.97M (was 31M of a 32M per-tx limit — the H2 blocker).
      `test_floorCoversMeasuredCostAtEveryCohortSize` pins the linear floor
      above the convex real curve at n = 1/10/50/100.
- [x] 6.2 ACCEPTED AS IS (owner decision, 2026-08-01). `challengerBondBps` 500
      and `settleBurnBps` 2,000 unchanged. The R4 thresholds are recorded as a
      known, accepted property: a 10%-of-supply holder files at ~19% confidence
      versus ~40% for everyone else, and the silence path turns profitable above
      f > 0.7%. Traded for more policing; revisit if WOOD ownership
      concentrates.
- [x] 6.3 NO CHANGE NEEDED — and the premise was wrong. These were never
      escrow-era parameters: verified against the pre-change tree that all three
      challenger-bond burns (settle, forfeit, inconclusive) ALREADY sent WOOD to
      the same BURN_ADDRESS. The escrow only ever received guardian slash
      proceeds, never a challenger's bond, so the sink change is a no-op here.
- [x] 6.4 Recorded in `TokenCourt.sol`'s contract header, where an auditor of
      that contract will actually meet it — not only in this change's design
      doc. Convictions burn, burned WOOD lifts every holder's share, so a
      WOOD-heavy party profits from ANY conviction whether or not the accused
      was guilty. Under the escrow the same manipulation paid only the drained
      vault's shareholders, a far narrower position to hold.

## 7. Documentation and framing

- [x] 7.1 DONE. Beyond the earlier pass: `TokenCourt`'s snapshot rationale,
      `ProposerBondEscrow`'s forfeiture promise, `IChallengeGame`'s title,
      `resolve` and `ChallengeSettled` docs, the queue's `IRequestableVault`
      reads, and sWOOD's bounty-ceiling guarantee (which cited the deleted
      `compensationEscrow` natspec as its authority). Remaining hits for
      "compensation" are deliberate history — they explain what changed.
- [x] 7.2 Stated on `StakedWood.BURN_ADDRESS`, where a reader asks what burning
      means here: supply SINK not reduction, `totalSupply` never falls, the
      effect is circulating-only and depends on providers excluding the address;
      no contract reads WOOD `totalSupply` so nothing internal drifts; volume is
      conviction-driven, and there is no continuous WOOD burn source because the
      only protocol fee is denominated in the vault's asset.
- [x] 7.3 CHECKED — neither surface will show it. CoinGecko does not auto-detect
      burns (supply is team-submitted and manually verified; WOOD currently
      reports circulating = total = max = 1,000,000,000). GeckoTerminal's FDV is
      a multiplier of ON-CHAIN supply, i.e. `totalSupply()`, which never falls
      without a real `burn()`. Escalated in design.md R1 with the two remedies:
      recurring manual supply updates, or add `ERC20Burnable` to WOOD.

## 8. Verify

- [x] 8.1 `forge build`, `forge test`, `forge fmt --check` on `src/`, `test/`,
      `script/` with a CI-matching forge.
- [x] 8.2 Grow `StakedWood.__gap` 4 -> 5 to absorb the removed
      `compensationEscrow` slot, keeping total size stable (design.md R6).
- [x] 8.3 Regenerate the `SyndicateFactory` golden with
      `./script/check-layout-goldens.sh --update-golden` and commit it in this
      PR. Review the emitted diff field by field — the golden exists to make
      layout drift noisy, so an unread re-baseline defeats it.
- [x] 8.4 Layout pin tests pass (8/8 across `GovernorLayoutPins` and
      `GuardianRegistryLayoutPins`), and `check-layout-goldens.sh` is green
      against the regenerated goldens. NOTE: `script/check-storage-parity.sh`
      does not exist in this repo — the CI proposal references it but it was
      never added, so only the golden gate ran.
- [x] 8.5 All artifacts fit Robinhood's 98,304-byte limit with wide margin
      (largest is `SyndicateGovernor` at 28,312). Four of them still exceed the
      24,576 EIP-170 limit, which is the pre-existing Robinhood-only posture,
      not something this change introduced.
