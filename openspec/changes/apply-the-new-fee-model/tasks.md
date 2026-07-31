> Implementation reference: `docs/superpowers/plans/2026-07-24-fee-mechanism.md` carries
> step-level code for each of these groups. Its line anchors were written 26 commits back —
> re-confirm the anchor at the start of each group rather than trusting it (see design.md
> § Risks). Requirements live in `specs/`; the "how" and the three deviations live in
> `design.md`.

## 1. Constants and split configuration

- [ ] 1.1 Raise `MAX_PERFORMANCE_FEE_BPS` 1500 → 3000 in `src/FeeConstants.sol` and add the shared `BPS_DENOMINATOR`; add the named constant for the factory's default per-vault maximum (2000) so it is not a literal
- [ ] 1.2 Write `test/fees/FeeConstantsCap.t.sol` asserting the raised cap propagates to every consumer (`GovernorParameters.MAX_PERFORMANCE_FEE_CAP`, `SyndicateVault.MAX_AGENT_FEE_BPS`) and that the pre-existing 500 bps default agent fee is unchanged
- [ ] 1.3 Add `MgmtSplit` (agent/protocol/guardian) and `PerfSplit` (agent/protocol/guardian/owner) structs, setters, getters and validation errors to `src/interfaces/IProtocolConfig.sol` and `src/ProtocolConfig.sol`, rejecting any split not summing to 10 000 and restricting setters to the configuration owner
- [ ] 1.4 Write `test/fees/ProtocolConfigSplits.t.sol` covering every scenario in `specs/fee-splits/spec.md`: valid splits accepted with events, under- and over-sum rejected with prior state intact, a zero share to one party accepted, unauthorized caller rejected
- [ ] 1.5 Raise the factory default `maxPerformanceFeeBps` 1500 → 2000 in `src/SyndicateFactory.sol` (`:419`) using the named constant from 1.1, and assert a freshly created vault's per-vault maximum equals the headline and sits strictly below the protocol ceiling
- [ ] 1.6 Run `forge test --match-path 'test/fees/*'` and `script/check-layout-goldens.sh`; both green before moving on

## 2. Propose-time split snapshot

- [ ] 2.1 Add two packed split-snapshot fields to `StrategyProposal` in `src/interfaces/ISyndicateGovernor.sol`, keeping them inside the `_proposals` mapping so governor linear storage does not move (design.md Decision 6)
- [ ] 2.2 Populate both snapshots at propose time in `src/SyndicateGovernor.sol` alongside the existing `protocolFeeBps`/`guardianFeeBps` snapshot (`:307-313`)
- [ ] 2.3 Add tests proving a split change after propose does not alter what the in-flight proposal pays, and that a change before propose does affect the next one (`specs/fee-splits/spec.md`)
- [ ] 2.4 Run `test/governor/GovernorLayoutPins.t.sol` and `script/check-layout-goldens.sh` to confirm slots 0–81 are untouched

## 3. Vault — management-fee accrual

- [ ] 3.1 Add the asset-seconds accumulator and its last-update stamp to `src/SyndicateVault.sol`, appending storage and shrinking `__gap` (`:186`) by the exact number of slots added
- [ ] 3.2 Update the accumulator on every base-changing path: the execute-time capital stamp (`SyndicateGovernor:395`), Lane A deposit (`SyndicateVault:866`), Lane A instant exit (`:909`), and the custody hooks `strategyMint`/`strategyBurn` (`:1083`/`:1098`)
- [ ] 3.3 Expose the accrual getters on `src/interfaces/ISyndicateVault.sol` and add the governor-only consume-and-reset entry point used at settlement
- [ ] 3.4 Write `test/fees/MgmtFeeAccrual.t.sol` covering `specs/management-fee/spec.md`: half-duration owes half; capital added mid-proposal charged only for its time; capital withdrawn mid-proposal stops accruing; a late depositor is not charged for time before deposit; consume-and-reset prevents double-charge across consecutive proposals
- [ ] 3.5 Add the idle-capital tests: the cooldown gap between two proposals generates no fee, and a dormant fund (agent stops proposing) charges nothing (design.md Decision 4)
- [ ] 3.6 In every time-based test use `vm.getBlockTimestamp()` or a contract-stored timestamp rather than a local captured before a `vm.warp`, and structure warps forward-only (design.md § Risks)
- [ ] 3.7 Run `script/check-layout-goldens.sh` to confirm the `__gap` reduction is the only linear-storage change

## 4. Vault — high-water mark

- [ ] 4.1 Add `highWaterPricePerShare` storage to `src/SyndicateVault.sol` (appended, `__gap` reduced) with its getter on `ISyndicateVault`, initialized to the price per share at the fund's first deposit
- [ ] 4.2 Add the governor-only ratchet entry point that advances the mark to the post-fee price per share and can never lower it
- [ ] 4.3 Write `test/fees/HighWaterMark.t.sol` covering `specs/performance-fee/spec.md`: 100 → 120 (charged) → 95 → 120 charges nothing on recovery; only the above-peak portion is charged; a settlement below the mark charges nothing; positive proposal profit below the mark is still not charged; the mark advances on a charged fee and is unchanged on a loss; the mark initializes at first deposit

## 5. Governor — two split distributions

- [ ] 5.1 Rewrite `_distributeFees` (`src/SyndicateGovernor.sol:1153`) from the four-step sequential waterfall to two split distributions — each recipient's share computed from the full base, never from another recipient's remainder
- [ ] 5.2 Move the management-fee charge out of the `pnl > 0` gate (`:1092`) so it runs on every settlement, and order settlement as management fee → high-water-mark comparison → performance fee
- [ ] 5.3 Apply the per-vault performance-fee clamp at settle, emitting `FeeClamped` and continuing rather than reverting
- [ ] 5.4 Charge the management fee on the `selfManagesFees` path (`:1098`) while keeping the performance leg skipped (design.md Decision 3)
- [ ] 5.5 Route every payment through the existing `_payFee` escrow (`:1267`) so a bricked recipient cannot block settlement
- [ ] 5.6 Write `test/fees/FeeDistribution.t.sol`: flat and losing proposals still pay management; a profitable proposal pays management first and performance on post-management price per share; the management fee can push a settlement below the mark so no performance is charged; splits divide one base and sum to the fee up to dust; an over-ceiling rate is clamped with an event; one bricked recipient does not brick settlement; the self-managed path pays management but not performance

## 6. Crystallize fees on Lane A instant exit

- [ ] 6.1 Add the management and performance crystallization counters to `src/SyndicateVault.sol` (appended, `__gap` reduced) and exclude both from `totalAssets()` (design.md Decision 2)
- [ ] 6.2 Compute and book the exiting shares' pro-rata management accrual and per-share above-mark performance fee on the Lane A instant path, without resolving recipients and without any external call
- [ ] 6.3 Confirm the mark is not ratcheted on a partial exit — it advances only at settlement
- [ ] 6.4 Write `test/fees/CrystallizeOnExit.t.sol` covering `specs/instant-exit-fees/spec.md`: an instant exiter pays accrued management; an exiter above the mark pays performance and one below pays none; retention leaves the remaining holders' price per share unmoved; the mark is unchanged after a partial exit
- [ ] 6.5 Add the fee-neutrality test: an instant exiter and an economically equivalent hold-to-settle depositor bear equal total fees up to rounding
- [ ] 6.6 Add the Lane B test: a queue exiter claims at the post-distribution settle price and is charged no separate crystallization

## 7. Pay crystallized fees at settlement

- [ ] 7.1 Distribute the crystallized management and performance amounts at settlement to the recipients named by the proposal's recorded splits, through `_payFee`
- [ ] 7.2 Net the crystallized management total out of the settlement management charge so no portion is charged twice
- [ ] 7.3 Verify the performance base excludes already-exited shares by construction (they are burned at exit) and add the test that pins it
- [ ] 7.4 Add the test that an unpayable crystallized amount does not block settlement and does not retroactively affect the exit that produced it
- [ ] 7.5 Run the full fee suite (`forge test --match-path 'test/fees/*'`) green before starting group 8

## 8. Instant-exit penalty

> Independent of groups 3–7 — different storage, different path, no shared math. Sequenced
> last so it can be dropped without unpicking anything (design.md Open Question 2).

- [ ] 8.1 Add `instantExitFeeBps` with its ≤ 200 bps protocol maximum and owner-only setter, reviving the slots reserved in `docs/specs/2026-07-19-instant-withdrawal-liquidity-design.md` §6
- [ ] 8.2 Charge the penalty on the `withdrawTo`-sourced portion of a Lane A exit only, accruing it to the vault and routing it to no fee recipient (design.md Decision 7)
- [ ] 8.3 Apply the two exit charges in order — crystallization to the exiting shares' value first, then the penalty on the net — and release the remainder
- [ ] 8.4 Update `previewRedeem` and `previewWithdraw` to account for both charges; `previewWithdraw` grosses up once and rounds conservatively across the float-boundary kink
- [ ] 8.5 Write `test/fees/InstantExitFee.t.sol`: an exit served entirely from idle balance pays no penalty; an exit that forces an unwind pays on the pulled portion; the penalty stays in the vault; a rate above the maximum reverts; a queue exit never pays under any fund state
- [ ] 8.6 Add the preview-matches-execution test for an instant exit with no intervening state change
- [ ] 8.7 Confirm no deposit fee is charged on entry

## 9. Documentation, goldens, and verification

- [ ] 9.1 Correct the product spec's "on fund assets (AUM) … **Always**" wording to match the decided behaviour that capital idle between proposals accrues nothing (design.md Decision 4)
- [ ] 9.2 Flip `docs/specs/2026-07-24-fee-model-design.md` and `docs/product/2026-07-24-fee-model-product-spec.md` from "Design — not implemented"/"Proposed" to implemented, and record the three deviations (D1 vault-side accumulator, D2 retained-not-transferred exit fees, D3 self-managed pays management) in each
- [ ] 9.3 Update the README fee table to the two-number model with its splits
- [ ] 9.4 Note the subgraph work as a follow-up: per-proposal `managementFee`/`performanceFee` with splits, plus the high-water-mark series
- [ ] 9.5 Run `script/check-layout-goldens.sh` and `test/governor/GovernorLayoutPins.t.sol` — governor linear storage unchanged, vault `__gap` reduced by exactly the number of slots added
- [ ] 9.6 Run the full `forge test` suite and compare the failure set against the pre-change baseline on `integration/lifecycle-planb`; the only acceptable outcome is an identical set of pre-existing fork failures (those needing `--fork-url`) and zero new failures
- [ ] 9.7 Run `forge fmt --check` with a forge matching CI's pinned version
- [ ] 9.8 Record the pre-upgrade migration steps for live vaults: read and reset any nonzero legacy `managementFeeBps` in the same batch as the upgrade, and set both splits before the first post-upgrade proposal (design.md § Migration Plan)
