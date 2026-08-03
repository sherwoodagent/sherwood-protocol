# Tasks — fix-proposer-bond-reclaim-gates

NOTE: #117 L2 (zero-answer freezer) was blocked on Ana's decision; she
approved failing closed on 2026-08-03 (design.md D7), so it is in scope —
see section 6. Same round: the D2 live-slot fallback was dropped in favor of
failing closed, since the protocol is not deployed and the legacy cohort it
served is empty.

## 1. Interface and storage

- [ ] 1.1 Append `address proposerBondLedger;` at the tail of
      `StrategyProposal` in `src/interfaces/ISyndicateGovernor.sol` (after
      `snapshotPerfSplit`, inside the "APPENDED FIELDS ONLY BELOW" region),
      with natspec mirroring `proposerBondEscrow`'s: the exposure ledger the
      reclaim gates read for this bond, pinned at propose time; zero only
      when no bond was locked (a locked bond always pins, and reclaim fails
      closed on a zero pin).
- [ ] 1.2 Add event `ProposerBondForfeitureAcknowledged(uint256 indexed
      proposalId, uint256 amount)` to `ISyndicateGovernor`, natspec stating
      when it fires (reclaim of a conviction-forfeited bond: record zeroed,
      nothing transferred).

## 2. Governor changes

- [ ] 2.1 In `_snapshotTierAndGate` (`src/SyndicateGovernor.sol`, the
      `bondWood != 0` block at ~:1010-1040): write
      `p.proposerBondLedger = ledger;` alongside the existing
      `p.proposerBondWood` / `p.proposerBondEscrow` writes, BEFORE the
      external `lockBond` call (the CEI invariant comment there applies —
      do not move any state write below the call).
- [ ] 2.2 In `reclaimProposerBond` (~:606-657): after the `bond == 0` check,
      add the forfeiture acknowledge — read
      `bondOf(address(this), proposalId)` on
      `proposal.proposerBondEscrow`; if the held amount is zero, zero
      `proposal.proposerBondWood`, emit
      `ProposerBondForfeitureAcknowledged(proposalId, bond)`, and return.
      Placed BEFORE the executed-proposal window gates (design D3 ordering
      rationale).
- [ ] 2.3 In the same function's `executedAt != 0` block: resolve the gate
      ledger as `proposal.proposerBondLedger` and revert
      `ExposureLedgerUnset` when it is zero — no fallback to
      `_exposureLedger` (design D2). Run all three gates (ledger window,
      freeze, freezer filing deadline) against it.
- [ ] 2.4 Rewrite the function's natspec: replace the `:575` "as long as
      `_exposureLedger` is stable... (issue #116)" caveat with the pinned
      statement (reclaim mirrors filing admissibility against the
      propose-time ledger; re-pointing the live slot cannot detach the
      gates); update `:588-598` recovery text (recovery is
      `setCoverageFreezer` on the PINNED ledger — re-pointing the governor's
      slot no longer applies to locked bonds), keeping the honest
      zero-answer asymmetry sentence but dropping the "(issue #117)"
      forward reference in favor of a pointer to the L1 acknowledge path.
      Also update `setExposureLedger`'s natspec (~:1602-1635) to state that
      re-pointing does not move existing bonds' gates.

## 3. Layout golden

- [ ] 3.1 Run `./script/check-layout-goldens.sh --update-golden` and commit
      the regenerated `script/syndicate-governor-layout.golden.json` —
      verify the diff shows exactly one appended `proposerBondLedger` member
      in the `StrategyProposal` type and NO top-level `storage` changes.
      (Serialize with any other running solc build first; run forge in the
      foreground.)
- [ ] 3.2 Confirm `test/governor/GovernorLayoutPins.t.sol` passes unchanged
      (top-level slots did not move; its pins must not be edited).

## 4. Tests

- [ ] 4.1 New test (#116, `test/GovernorCoverageGates.t.sol` or
      `test/ChallengeEndToEnd.t.sol`): execute + settle a bonded proposal
      with a live/admissible challenge, then re-point the governor's ledger
      (via the factory-caller harness) at a permissive ledger (no freezer,
      collapsed window) — `reclaimProposerBond` still reverts
      `ChallengeWindowOpen`, and a conviction inside the window still
      forfeits the bond from escrow.
- [ ] 4.2 New test (#116 fail-closed): a proposal whose
      `proposerBondLedger` is zero (fabricated via `vm.store`, unreachable
      in production) reverts `ExposureLedgerUnset` — including when the live
      `_exposureLedger` slot has been re-pointed at a permissive ledger,
      which is the composed re-point-against-zero-pin scenario the round-1
      audit flagged as untested.
- [ ] 4.3 New test (#117 L1): after a conviction forfeits the bond,
      `reclaimProposerBond` succeeds without transfer, emits
      `ProposerBondForfeitureAcknowledged(pid, amount)`, zeroes
      `getProposal(pid).proposerBondWood`, and a second call reverts
      `NoBondToReclaim`; WOOD balances (proposer, escrow, burn address)
      unchanged by the acknowledge.
- [ ] 4.4 Update `test/ChallengeEndToEnd.t.sol`
      `test_conviction_forfeitsTheProposerBond` (~:880-884): the
      post-forfeiture `vm.expectRevert(); gov.reclaimProposerBond(pid);`
      becomes the acknowledged no-op assertions from 4.3 ("still nothing"
      balance assertion stays).
- [ ] 4.5 Sweep the other `reclaimProposerBond` call sites
      (`test/GovernorCoverageGates.t.sol` 23 refs,
      `test/ChallengeEndToEnd.t.sol` 11, `test/CoverageEndToEnd.t.sol` 4)
      for assertions the pin or the acknowledge path changes; the
      ledger-wired-in-setUp happy paths (pinned == live) should pass
      unchanged — investigate any that do not rather than editing them to
      green.

## 5. Verification

- [ ] 5.1 `forge build` + full `forge test` in the foreground (serialize
      against concurrent solc; never judge a build through a piped exit
      code), plus `forge fmt` with a CI-matching forge.
- [ ] 5.2 `./script/check-layout-goldens.sh` passes clean on the committed
      golden.
- [ ] 5.3 Re-read the final natspec against the shipped behavior — no
      sentence may claim more than the code does (the #94/#112 lesson);
      confirm the "(issue #116)"/"(issue #117)" forward references are gone
      and that "fails closed" now covers the zero-answer case it describes.

## 6. #117 L2 — zero-answer freezer (approved 2026-08-03, design D7)

- [ ] 6.1 In `reclaimProposerBond` gate 3, read
      `IChallengeGame(freezer).challengeWindow()` into a local and revert
      `ChallengeWindowOpen` when it is zero, before computing `deadline`.
      Scope it to that view only — `challengeableUntil == 0` must keep
      passing.
- [ ] 6.2 New test: a wired freezer answering zero blocks the reclaim and is
      recoverable by rotating `coverageFreezer` on the pinned ledger; plus a
      companion test pinning the scope boundary (zero `challengeableUntil`
      still reclaims on the ordinary schedule).
- [ ] 6.3 Update the challenge-game delta spec sentence that recorded the
      pass-through as intended behavior, and its scenario list.
