# Tasks: club-vaults-and-transfer-gating (SHE-197, SHE-201)

> **SPEC ONLY. Nothing in `src/`, `test/`, `script/` or `.github/` is touched by
> this change as merged.** Every task below §0 describes work to be done AFTER
> approval, in a separate implementation PR.
>
> Line references are against `origin/main` @ `a5399c7`
> (`a5399c7b0221bd3c4d7f608b6d81e42e0abd8647`, 2026-08-31) and will drift.
>
> Build discipline for the implementation pass: `via_ir = true` on this machine
> OOM-kills concurrent solc runs. Serialize every forge command behind the build
> lock (`while pgrep -x forge >/dev/null; do sleep 30; done`), run it in the
> FOREGROUND, and never judge a build through a piped exit code.
>
> `gh` note: use `--body-file` — never inline backticks in `gh` bodies.

## 0. DO NOT IMPLEMENT until this change is approved in review

**STOP. This change is spec-only. No `src/` edit, no test edit, no golden
regeneration is authorized by merging it.** The gate below must be fully checked
before a single line of Solidity is written.

- [ ] 0.1 **Approval recorded.** An owner/reviewer has approved this change as
      written, or has recorded the deltas they want. In particular the three
      decisions most likely to be re-litigated are flagged in design.md as
      owner decisions or open questions and MUST be confirmed, not assumed:
      **D4** (flip-to-whitelist grandfathering: exit-only, no grandfather
      register), **D8** (queue-return leg exempt from the cap, with a bounded
      transient overshoot), and **D11** (gate lives INLINE in `_update`, not in
      the delegatecalled `SyndicateVaultAdminLib`).
- [ ] 0.2 **D11's measurement re-taken on the then-current main.** design.md
      D11 recommends inline placement on the strength of a measurement, not a
      belief: vault runtime 32,971 B against CI's 98,304 B limit
      (`.github/workflows/ci.yml:225`). Re-run
      `forge build --skip test --skip script --sizes` and re-read the table
      before accepting the recommendation.
- [ ] 0.3 **`StrategyProposal` append order settled.** `per-call-capital-declarations`
      and `proportional-quorum-sizing` both append to the same struct
      (`src/interfaces/ISyndicateGovernor.sol:111`+) and both regenerate
      `script/syndicate-governor-layout.golden.json`. Confirm which have landed,
      rebase onto them, and append this change's two members LAST.
- [ ] 0.4 **`pin-vault-storage-layout` status confirmed.** Its artifacts are
      already on main (`script/syndicate-vault-layout.golden.json`, and the
      vault is gated at `script/check-layout-goldens.sh:297`) while its change
      dir is still unarchived under `openspec/changes/`. Confirm no second vault
      baseline is in flight before regenerating the vault golden.
- [ ] 0.5 **Deployment reality re-listed.** Re-list `broadcast/` for a chain-4663
      vault or governor deployment. Append-only is followed either way (the
      struct's own comment makes it a standing rule,
      `src/interfaces/ISyndicateGovernor.sol:105-108`), but if a live proxy
      exists the golden diffs in §5 become load-bearing rather than hygienic.
- [ ] 0.6 **Queue assumptions re-read.** design.md's re-verification ledger lists
      four: `requestRedeem` escrows via `_transfer` (`src/SyndicateVault.sol:2306`),
      `cancel` returns via `safeTransfer` (`src/queue/VaultWithdrawalQueue.sol:434`),
      deposit-side cancel is unconditional (`:425-426`), and `settleRedeem` burns
      from the queue (`src/SyndicateVault.sol:2372`). If any has changed, D2's
      exemption table and D8's escape hatch must be re-derived BEFORE coding.
- [ ] 0.7 **D13's drive-by spec correction decided separately.** The
      `syndicate-governor` delta restates `vetoThresholdBps`'s max as `8_000` to
      match `src/GovernorParameters.sol:44`; the base spec says `5_000`.
      Reviewer confirms whether to keep that correction in this change or split
      it into its own docs PR.

## 1. Vault — the transfer guard (design D1, D2, D3, D4, D5)

- [ ] 1.1 Add errors to `src/interfaces/ISyndicateVault.sol` beside the existing
      set (`:9-124`): `ReceiverNotApproved(address receiver)`,
      `MaxHoldersExceeded()`, `InvalidMaxHolders()`,
      `HolderCapRequiresWhitelist()`.
- [ ] 1.2 In `_update` (`src/SyndicateVault.sol:1445-1491`), insert the guard
      BEFORE `super._update` (design D1). Leave the high-water reset
      (`:1471-1473`) and the auto-delegate block (`:1488-1490`) exactly where and
      as they are.
- [ ] 1.3 Implement the exemption set EXACTLY as D2's table: `from == 0`,
      `to == 0`, `from|to == address(this)`, `to == _withdrawalQueue`,
      `from == _withdrawalQueue`, `value == 0`. Each exemption gets a natspec
      line naming what breaks without it; the two queue exemptions name the
      call sites (`:2306`, `src/queue/VaultWithdrawalQueue.sol:434`).
- [ ] 1.4 Gate body: `if (!_openDeposits && !_approvedDepositors.contains(to))
      revert ReceiverNotApproved(to);`. Receiver-only — do NOT add a `from`
      check (design D3). Natspec states the adversary per
      `openspec/config.yaml`'s rules.
- [ ] 1.5 Confirm by reading, not by assumption, that no `src/` path transfers
      shares to an address the gate would newly reject: re-grep for
      `_transfer(`, `_mint(`, `_burn(` in `src/SyndicateVault.sol` and for
      `IERC20(vault)` in `src/queue/`.

## 2. Vault — the beneficial-owner cap (design D6, D7, D8, D9)

- [ ] 2.1 Add storage carved from the FRONT of `uint256[19] private __gap`
      (`src/SyndicateVault.sol:525`), packed into one slot: `uint32 _maxHolders`,
      `uint32 _holderCount`. Extend the running decrement log at `:515-524` in
      the established style.
- [ ] 2.2 Seat `maxHolders` in `initialize` (`:531-552`) from a new
      `InitParams` field, validating the D7 pair before any write.
- [ ] 2.3 Count in the same `_update` pass from PRE-move balances (design D6):
      `to` gains iff `value != 0 && balanceOf(to) == 0`; `from` frees iff
      `value != 0 && balanceOf(from) == value`; counted addresses exclude
      `address(0)`, `address(this)`, `_withdrawalQueue`.
- [ ] 2.4 Cap check on the GAIN alone, not netted (design D6), and exempt
      `from == _withdrawalQueue` from the cap as well as from the gate
      (design D8). Natspec cites `src/queue/VaultWithdrawalQueue.sol:425-426`
      as the reason the return leg cannot be refused.
- [ ] 2.5 `setMaxHolders(uint32)` — `onlyOwner`, reverts
      `HolderCapRequiresWhitelist` when nonzero while `_openDeposits`, emits a
      change event. Cold path: this body is the ONLY candidate for
      `SyndicateVaultAdminLib` (design D11) — if it moves there, keep
      `onlyOwner` on the wrapper per the library's trust boundary
      (`src/SyndicateVaultAdminLib.sol:19-25`) and update `echidna.yaml:20-21`.
- [ ] 2.6 `setOpenDeposits` (`src/SyndicateVault.sol:595-598`) gains the mirror
      guard: revert `HolderCapRequiresWhitelist` on `true` while
      `_maxHolders != 0`.
- [ ] 2.7 Views: `maxHolders()`, `holderCount()`. Declare both on
      `ISyndicateVault`.

## 3. Governor — affirmative-approval mode (design D12, D13)

- [ ] 3.1 `src/interfaces/ISyndicateGovernor.sol`: `enum ApprovalMode { Optimistic, Affirmative }`;
      two APPENDED `StrategyProposal` members below the
      `APPENDED FIELDS ONLY BELOW` divider (`:111`); two `GovernorParams`
      members; `error InvalidApprovalQuorumBps()`.
- [ ] 3.2 `src/GovernorParameters.sol`: constants
      `MIN_APPROVAL_QUORUM_BPS = 2000` / `MAX_APPROVAL_QUORUM_BPS = 6700`
      beside `:43-44`; keys `PARAM_APPROVAL_MODE`,
      `PARAM_APPROVAL_QUORUM_BPS` beside `:70-80`; setters
      `setApprovalMode` / `setApprovalQuorumBps`, both
      `onlyVaultOwner whenNoActiveProposal`, both emitting
      `ParameterChangeFinalized`, matching `:197-292` exactly in shape.
- [ ] 3.3 Extend `_validateParamBounds` (`:163-192`) with both params, so
      `forceSetParams` / `initialize` cannot seat what a setter rejects — the
      principle already recorded at `:185-187`. Validate `approvalQuorumBps` on
      EVERY write regardless of the mode in force (design D13).
- [ ] 3.4 Snapshot both onto the proposal at BOTH Draft→Pending sites, beside
      the existing `vetoThresholdBps` snapshot: `src/SyndicateGovernor.sol:1362`
      and `:1610`.
- [ ] 3.5 `ProposalLifecycle._computeState` (`src/ProposalLifecycle.sol:77-110`):
      keep the `liveSupply` derivation at `:86-99` VERBATIM and shared; branch
      only the threshold test. Affirmative → `if (p.votesFor < liveSupply *
      p.approvalQuorumBps / BPS_DENOMINATOR) return (ProposalState.Rejected,
      false);` with `liveSupply == 0` resolving `Rejected`; Optimistic → today's
      code unchanged, `liveSupply == 0` still skipping. Do NOT run both tests
      (design D12).
- [ ] 3.6 Verify by reading that `_commitState` (`:239-281`) needs NO new
      branch: `(Rejected, false)` already routes to `_closeReviewIfRegistered`
      at `:272-280`. If it does need one, D12 is wrong and must be revised
      before coding further.
- [ ] 3.7 `getGovernorParams` (`:323-325`) and any status surface that reports
      passage semantics carry the mode.

## 4. Factory + interfaces — the club bundle's protocol surface (design D10)

- [ ] 4.1 `SyndicateConfig` (`src/SyndicateFactory.sol:79-86`) gains
      `maxHolders`, `approvalMode`, `approvalQuorumBps`. NO preset enum, NO
      template registry (design D10 — both alternatives are explicitly
      rejected).
- [ ] 4.2 `ISyndicateVault.InitParams` (`src/interfaces/ISyndicateVault.sol:127-136`)
      gains `maxHolders`; wire at `src/SyndicateFactory.sol:364-373`.
- [ ] 4.3 Validate the club pair in `createSyndicate`'s pre-flight block
      (`:325-331`), before any side effect, using the same errors the setters
      raise.
- [ ] 4.4 Overlay the two governor params onto the factory defaults at governor
      init; omitted values keep today's defaults (`Optimistic`, quorum unread).
- [ ] 4.5 CLI/docs only, NOT contract code: a `--club` flag expanding to
      `openDeposits=false, maxHolders=99, approvalMode=Affirmative,
      approvalQuorumBps=<default>` plus a post-creation `setAgentFeeBps(0)`.
      Document that the management fee is NOT choosable per vault — it is
      init-only from the factory global (`src/SyndicateVault.sol:181`, `:547`;
      `src/SyndicateFactory.sol:590-595`) — and surface the inherited figure at
      creation time rather than implying otherwise (design D10).

## 5. Storage goldens (design D14)

- [ ] 5.1 Regenerate BOTH goldens AFTER the storage edits, once, under the build
      lock: `./script/check-layout-goldens.sh --update-golden`. Never hand-write
      a golden and never paste raw `forge inspect` output — the checker
      canonicalizes.
- [ ] 5.2 REVIEW THE VAULT DIFF as its own task: the only legal changes to
      `script/syndicate-vault-layout.golden.json` are the new trailing entries
      and `__gap`'s array length shrinking. NO existing label, slot, offset or
      type may move. A non-append diff is a bug in this change, not a golden to
      update.
- [ ] 5.3 REVIEW THE GOVERNOR DIFF as its own task: the only legal change to
      `script/syndicate-governor-layout.golden.json` is the `StrategyProposal`
      type's two new trailing members and its `numberOfBytes`, plus the two
      `GovernorParams` members.
- [ ] 5.4 Extend `test/VaultLayoutPins.t.sol` and
      `test/governor/GovernorLayoutPins.t.sol` with pins for the new fields.
      Pins are ADDED, never edited.
- [ ] 5.5 `./script/check-layout-goldens.sh` passes.

## 6. Tests and invariants

- [ ] 6.1 Transfer guard unit tests: rejected receiver; approved→approved
      succeeds with unchanged ERC20Votes semantics; open mode inert; every one
      of D2's six exemptions has its own test, each named for what it protects.
- [ ] 6.2 Grandfathering (design D4): open vault → holders acquire shares →
      `setOpenDeposits(false)` → assert the grandfathered holder can transfer to
      an approved address, `redeem`, `requestRedeem` and `cancel`, and CANNOT
      receive. Assert no grandfather storage exists.
- [ ] 6.3 Queue round trip under the gate: `requestRedeem` → owner removed from
      whitelist → `cancel` returns the shares. Then the stamped path:
      `requestRedeem` → stamp → `claim` burns from the queue
      (`src/SyndicateVault.sol:2372`) with the gate inert.
- [ ] 6.4 Cap tests (design D6, D8): blocks a new holder at the cap; permits a
      top-up; permits the net-neutral full-balance transfer; mints capped on
      BOTH the instant path and `settleDeposit`; a `settleDeposit` blocked by the
      cap is recoverable via the unconditional deposit cancel; queue-return leg
      exempt with the transient overshoot asserted and shown to self-heal.
- [ ] 6.5 D7 pair tests: `setMaxHolders` nonzero on an open vault reverts;
      `setOpenDeposits(true)` on a capped vault reverts; creation validates the
      pair.
- [ ] 6.6 Affirmative-mode tests (design D12): silence rejects; quorum reached
      proceeds to `GuardianReview`; `votesAgainst` above the veto threshold is
      irrelevant once the FOR bar is cleared; `liveSupply == 0` rejects;
      queue-escrowed shares netted out of the denominator; a rejection fires NO
      `resolveReview` and DOES cancel the registered review; snapshotted mode
      governs an in-flight proposal after a `forceSetParams` change.
- [ ] 6.7 Bounds tests: `approvalQuorumBps` below 2_000 / above 6_700 rejected,
      including while the mode is `Optimistic`; `forceSetParams` rejects the
      same values.
- [ ] 6.8 Fizz/echidna campaign updates. `test/fizz/handlers/SyndicateVaultHandler.sol`
      transfer drivers (`:78`, `:85`, `:147`, `:151`) must clamp targets to the
      whitelist in club configurations, or the campaign degenerates to
      all-reverts and asserts nothing. Add a holder-count property beside
      `property_GL09_vaultShareSupplyConserved` (`test/fizz/Properties.sol:96`)
      and a matching `PROPERTIES.md` entry near GL-09 (`PROPERTIES.md:43`):
      counted holders == number of distinct nonzero actor balances, excluding
      the queue and the vault. If the cap is set, add a second property that the
      count never exceeds `maxHolders` EXCEPT by live escrow returns, stated in
      the same shape as the existing bounded-slack entries.
- [ ] 6.9 `test/invariants/AsyncRedeemInvariants.t.sol` — re-run with a
      club-configured vault so `invariant_queueShareBalanceCoversPendingShares`
      (`:106`) and `invariant_totalSupplyConserved` (`:94`) exercise the
      exemptions rather than only the open-mode paths.
- [ ] 6.10 `echidna.yaml:20-21` linkage still valid if any body moved to
      `SyndicateVaultAdminLib` (see task 2.5).

## 7. Validation

- [ ] 7.1 Full non-integration suite green; forge in the FOREGROUND under the
      build lock, never judged through a piped exit code.
- [ ] 7.2 `forge fmt` with a CI-matching forge version.
- [ ] 7.3 `forge build --skip test --skip script --sizes` — record the new vault
      and governor runtime sizes against the 98,304 limit and compare to D11's
      table; a material regression reopens D11.
- [ ] 7.4 `npx --yes @fission-ai/openspec@1.7.0 validate --all --strict` clean
      (the CI job at `.github/workflows/ci.yml:158-159`).
- [ ] 7.5 Update SHE-197 and SHE-201 with the landed shape (`--body-file`).
