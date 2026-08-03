# Tasks: anchor-coverage-at-execution

## 1. StakedWood — shared slash basis (design D2)

- [x] 1.1 Extract `_slashOne`'s sizing (StakedWood.sol:1348-1352) into an
      internal view `_slashableAt(address guardian, uint256 anchor)` returning
      `min(max(liability@anchor, votableStake@anchor), stakedAmount)`;
      `_slashOne` sizes from it unchanged in behavior.
- [x] 1.2 Add external view `slashableStakeAt(address guardian, uint256 anchor)`
      wrapping `_slashableAt`, reverting when `anchor > block.timestamp`
      (mirror `VerdictNotPast`); natspec names the adversary (post-anchor
      top-up counted as coverage) and cross-references `_slashOne`.
- [x] 1.3 Declare the view in `src/interfaces/IStakedWood.sol`.
- [x] 1.4 Verify `./script/check-layout-goldens.sh` passes with ZERO golden
      diffs (a diff here is a bug in this change, not a golden to update).

## 2. Governor — expose the anchor (design D3)

- [x] 2.1 Append `uint256 executedAt` to `SyndicateGovernor.ProposalViewLite`
      (SyndicateGovernor.sol:909-915) and populate it in `getProposalView`
      from `proposal.executedAt` (0 until executed).
- [x] 2.2 Mirror the field in `ILedgerGovernorMinimal.ProposalViewLite`
      (ExposureLedger.sol:26-32).
- [x] 2.3 Add the invariant natspec at SyndicateGovernor.sol:382/:429 — the
      approve-quorum gate MUST run in the transaction that stamps
      `executedAt`, after the stamp (design D5).

## 3. Ledger — anchor the post-execution reads (design D1, D4)

- [x] 3.1 Make `_slashableBondUsd` anchor-aware: anchored variant values the
      guardian at `swood.slashableStakeAt(g, anchor)` when `anchor != 0`,
      live `guardianStake(g)` when `anchor == 0`; same `× priceX8 / 1e8`.
- [x] 3.2 Thread `pv.executedAt` as the anchor through the four
      post-execution call sites: `allocatedUsd` (:1339), `_effectiveTotal`
      (:1383, new anchor param; update `liabilityUsd` caller),
      `settleCoverage` (:1510), `_effectiveReservedTotal` (:1588, new anchor
      param). `recordApproval` (:930), `requireApproveQuorum` (:1220), and
      the public `slashableBondUsd` view (:388) stay live — assert in review
      that their call sites are untouched.
- [x] 3.3 Natspec corrections (design D7): settle residue bound
      (:1531-1533), `liabilityUsd` "cannot drift apart" (:1346-1350),
      `_effectiveTotal` rationale (:1368-1376), `requireApproveQuorum`
      alignment invariant (design D5).

## 4. Test updates and new coverage

- [x] 4.1 Update mocks for the ABI/interface changes in the same commit as
      the src change: inline governor mocks (test/ExposureLedger.t.sol:75-110,
      test/RegistryExposureHook.t.sol:48-83) gain `executedAt`; inline sWOOD
      mock (test/ExposureLedger.t.sol:16-20) and test/mocks/MockStakedWood.sol
      gain `slashableStakeAt`.
- [x] 4.2 StakedWood tests: `slashableStakeAt` equals `_slashOne`'s recovery
      at 100% severity (spec scenario "View agrees with the verdict slash");
      post-anchor top-up excluded; unstake-requested guardian still reports
      the at-anchor basis via the liability trace; future anchor reverts.
- [x] 4.3 Ledger tests: post-execution top-up moves neither `allocatedUsd`,
      `liabilityUsd`, nor `settleCoverage` rebooks/residue (spec scenarios
      "Post-execution top-up is not coverage" / "...cannot raise a booking");
      an unexecuted proposal (`executedAt == 0`) settles on the live basis
      unchanged.
- [x] 4.4 End-to-end (ChallengeGame or CoverageEndToEnd harness): accused
      approver tops up after execution → `liabilityUsd` and the filing bond
      are unchanged (spec scenario "Accused cohort cannot price up its own
      prosecution").
- [x] 4.5 Regression sweep: the existing downward-clamp and price-path tests
      named in design "Risks" still pass unmodified
      (`test_allocatedUsd_excludesBondThatIsNoLongerThere`,
      `test_settleCoverage_survivesABondCollapseBeforeSettling`,
      `test_settleCoverage_cannotBePinnedAtAPriceTrough`,
      `test_approveQuorum_priceCrashShrinksCommittedShare`,
      StakedWoodSlashing top-up clamp tests).

## 5. Verification and coordination

- [x] 5.1 `forge test` full suite; `forge fmt` with a CI-matching forge;
      `./script/check-layout-goldens.sh` with zero diffs.
- [x] 5.2 Serialize builds on this machine (single `via_ir` solc at a time;
      run forge in the foreground, never judge a build through a pipe).
- [ ] 5.3 Comment on issues #83 and #110 pointing at design.md D6 (this
      change preserves both analyses; #83's Case-snapshot fix and #110's cap
      re-check remain necessary), and on issue #35 with the verification that
      the quorum-gate PoC was closed by 4e2823c and this change closes the
      post-execution remainder. NOT DONE in this pass — out of scope per the
      dispatching agent's brief (PR body references #83 per design.md's
      framing instead; posting GH issue comments was not requested).
