## 1. Contract change (src/TierRegistry.sol)

- [ ] 1.1 In `_demote` (src/TierRegistry.sol:270-280), after the bond
      release-timelock block and before `emit TierDemoted`, add the
      guarded clear: `if (_adapterAllowed[target]) { delete
      _adapterAllowed[target]; emit AdapterAllowedSet(target, false); }`
      (design.md Decision 1-2).
- [ ] 1.2 Extend the `_demote` natspec: state that every demotion path
      clears the target's allowlist entry; state the adversary (a
      convicted or code-mutated adapter retaining the standing right to
      receive approvals/transfers of vault funds through governor
      batches — tier 2 is a price, not a prohibition); and record the
      DELIBERATE over-breadth — certification is keyed (target,
      selector), the allowlist by bare address, so demoting ONE selector
      de-allowlists the WHOLE adapter; recovery is one owner
      `setAdapterAllowed` call; do NOT "fix" this back to per-selector
      (design.md Decision 3).
- [ ] 1.3 Extend the allowlist-section natspec (`setAdapterAllowed` /
      `isAdapterAllowed`, src/TierRegistry.sol:305-319) and the
      `certify` natspec: the coupling is one-way — demotion clears the
      entry, but `certify` NEVER sets or restores it; re-allowlisting
      after any demotion is an explicit owner decision (design.md
      Decision 4).

## 2. Tests (test/TierRegistry.t.sol — additive only; design.md sweep found no existing test to update)

- [ ] 2.1 `test_demote_clearsAdapterAllowlist`: certify + allowlist a
      target; owner `demote`; assert `isAdapterAllowed == false` and
      `AdapterAllowedSet(target, false)` emitted.
- [ ] 2.2 `test_demoteByChallenge_clearsAdapterAllowlist`: certify +
      allowlist; set an `authorizedDemoter`; prank it into
      `demoteByChallenge`; assert cleared + event. (Hoist any
      argument-position calls before `vm.prank` — one-shot cheatcode
      consumption guardrail.)
- [ ] 2.3 `test_poke_clearsAdapterAllowlist`: certify + allowlist;
      `vm.etch` a different bytecode onto the target; permissionless
      `poke` from a rando; assert cleared + event.
- [ ] 2.4 `test_demote_neverAllowlisted_noAllowedSetEvent`: demote a
      certified, never-allowlisted target with `vm.recordLogs`; assert
      no `AdapterAllowedSet` log among the recorded logs (guarded
      emission — no phantom event).
- [ ] 2.5 `test_demoteOneSelector_clearsWholeAdapter_intended`: certify
      TWO selectors on one target, allowlist it; demote ONE selector;
      assert `isAdapterAllowed == false` while `tierOf` for the other
      selector still reports its certified tier — comment that this
      pins the over-broad clear as specified behavior (spec scenario
      "One selector's demotion de-allowlists the whole adapter").
- [ ] 2.6 `test_recertify_doesNotRestoreAllowlist`: certify + allowlist;
      demote (allowlist auto-clears); re-`certify` the same (target,
      selector) (use a zero submitter-bond config so `certify` is not
      blocked, or traverse claim first); assert `isAdapterAllowed`
      still false.
- [ ] 2.7 `test_ownerReallowsAfterClear`: after a demotion-clear, owner
      calls `setAdapterAllowed(target, true)`; assert
      `isAdapterAllowed == true` (the recovery path).

## 3. Docs (docs/adapter-onboarding-checklist.md §4)

- [ ] 3.1 Rewrite the "`_demote` does not touch the allowlist — and you
      are not the only caller" subsection: `_demote` now DOES clear the
      allowlist on every persisted demotion (`demote`,
      `demoteByChallenge`, `poke`), emitting `AdapterAllowedSet(adapter,
      false)`; note the over-broad-by-design clear and the explicit
      owner re-allowlist recovery.
- [ ] 3.2 Narrow the "Operational consequence" paragraph: `TierDemoted`
      no longer requires a manual allowlist reaction (the clear already
      happened on-chain); the remaining allowlist alarms are (a)
      `AdapterDemotionFailed` — the try/catch at ChallengeGame.sol:1141
      means a reverted demotion cleared nothing; react with owner
      `demote` (which also clears) or `setAdapterAllowed(adapter,
      false)` — and (b) lazy tier-2 via codehash mismatch that nobody
      has `poke`d yet; keep the §3 drift sweep for that.
- [ ] 3.3 Update the §4 intro ordering note: allowlist-off-first remains
      the documented order, now with a note that step 2 (`demote`) also
      clears the allowlist on-chain, making step 1 a belt-and-suspenders
      for single-adapter cases.
- [ ] 3.4 Re-verify every `src/TierRegistry.sol` line reference in the
      checklist against the post-change file (the doc pins line
      numbers; `_demote` grows by ~4 lines).

## 4. Verify

- [ ] 4.1 `forge fmt` (with a forge matching CI) and `forge build`.
- [ ] 4.2 Run the full `forge test` suite in the foreground (serialize
      against other via_ir builds: wait for no running `solc` first);
      confirm zero failures — in particular TierRegistry, SelectorGuard,
      TierResolution, TierEndToEnd, GovernorCoverageGates,
      ChallengeGame, ChallengeEndToEnd, TokenCourtEndToEnd,
      SlashGasCeiling suites — matching the design.md blast-radius
      prediction of no existing-test breakage.
- [ ] 4.3 `openspec validate --change demote-clears-adapter-allowlist`.
