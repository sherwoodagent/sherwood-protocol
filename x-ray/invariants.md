# Invariant Map

> Sherwood Protocol | 40 guards | 39 inferred | 14 not enforced on-chain

Analyzed at `8b82598` (`main`).

---

## 1. Enforced Guards (Reference)

Per-call preconditions. Heading IDs below (`G-N`) are anchor targets from x-ray.md attack surfaces.

#### G-1
`if (_executorImpl.codehash != _expectedExecutorCodehash) revert ExecutorCodehashMismatch();` · `SyndicateVault.sol:531` · Pins the delegatecall target's bytecode so a metamorphic redeploy at the same address cannot silently take over vault storage.

#### G-2
`if (balanceAfter < reserve) revert QueueReserveBreached();` · `SyndicateVault.sol:595` · Stops a strategy batch from spending assets the withdrawal queue has already promised to stamped redeemers.

#### G-3
`if (balanceAfter < reserve + (balanceBefore * minBufferBps) / 10_000) revert BufferBreached();` · `SyndicateVault.sol:598` · Keeps a liquid float above the queue reserve so synchronous LP flow survives a fully-deployed strategy.

#### G-4
`if (_isPrivilegedBatchTarget(target)) revert DisallowedBatchTarget(target);` · `SyndicateVault.sol:915` · Blocks the strategy batch from calling back into the protocol's own privileged surfaces (vault, governor, queue, factory).

#### G-5
`if (target != asset_ && !ITierRegistry(registry).isAdapterAllowed(target)) revert DisallowedBatchCallee(target);` · `SyndicateVault.sol:981` · Confines batch value-routing to governance-certified adapters, so a proposal cannot name an arbitrary sink.

#### G-6
`if (_withdrawalQueue != address(0)) revert WithdrawalQueueAlreadySet();` · `SyndicateVault.sol:461` · Makes the queue pointer a one-shot latch — the queue holds escrowed shares and assets, so re-pointing it would orphan them.

#### G-7
`if (msg.sender != _withdrawalQueue) revert NotQueue();` · `SyndicateVault.sol:1582` · Restricts share burning at a frozen settlement price to the single contract that owns the escrow bookkeeping.

#### G-8
`if (!redemptionsLocked()) revert RedemptionsNotLocked();` · `SyndicateVault.sol:1497` · Forces async redemption only while a proposal is live; outside that window the synchronous ERC-4626 path is the correct one.

#### G-9
`if (redemptionsLocked()) revert RedemptionsLocked();` · `SyndicateVault.sol:1828` · Prevents owner rescue functions from moving assets while shareholders are locked out of exiting.

#### G-10
`if (sp.stamped) revert AlreadySettled();` · `queue/VaultWithdrawalQueue.sol:153` · Freezes exactly one settlement price per proposal, closing the mid-flight NAV re-pricing surface.

#### G-11
`if (_settlePrice[r.pid].stamped) revert AlreadySettled();` · `queue/VaultWithdrawalQueue.sol:295` · Shuts the cancel path the instant a price is frozen, so a queued request cannot be withdrawn after its outcome is known.

#### G-12
`if (IRequestableVault(vault).redemptionsLocked()) revert VaultLocked();` · `queue/VaultWithdrawalQueue.sol:214` · Confines claims to the gap between proposals, where the vault's live share price equals the latest stamp.

#### G-13
`if (_openProposalCount != 0) revert VaultHasOpenProposal();` · `SyndicateGovernor.sol:283` · Binds at most one non-terminal proposal lifecycle to a vault at a time (spec: syndicate-governor, single-lifecycle requirement).

#### G-14
`if (_activeProposal != 0) revert StrategyAlreadyActive();` · `SyndicateGovernor.sol:433` · Serializes execution so two strategies cannot hold the same capital snapshot.

#### G-15
`if (liveTier > proposal.envelopeTier) revert TierRegressed();` · `SyndicateGovernor.sol:489` · Fail-safe against a certification demoted between propose and execute — the executed risk envelope may never exceed the voted one.

#### G-16
`if (liveCoverage > proposal.requiredCoverage) revert CoverageRegressed();` · `SyndicateGovernor.sol:490` · Same fail-safe on the coverage axis: guardians must not end up underwriting more than they approved.

#### G-17
`if (proposal.maxCapital > _capitalCeiling()) revert MaxCapitalCeilingRegressed();` · `SyndicateGovernor.sol:509` · Re-checks the capital ceiling at execute because vault TVL can shrink after propose (audit #181 finding #9).

#### G-18
`if (block.timestamp < executedAt + strategyDuration + IExposureLedger(ledger).challengeWindow()) revert ChallengeWindowOpen();` · `SyndicateGovernor.sol:820` · Holds the proposer bond until the strategy's term AND the challenge window have both elapsed — the bond is what a successful challenge is paid from.

#### G-19
`if (IExposureLedger(ledger).isCoverageFrozen(address(this), proposalId)) revert ChallengeWindowOpen();` · `SyndicateGovernor.sol:823` · Blocks bond reclaim while a live challenge has frozen the proposal's coverage.

#### G-20
`if (block.timestamp <= deadline) revert ChallengeWindowOpen();` · `SyndicateGovernor.sol:841` · Reproduces `ChallengeGame.file`'s own live deadline (strictly, since `file` still admits at equality) so reclaim cannot lift while filing is still open.

#### G-21
`if (IProposerBondEscrow(escrow).exposureLedger() != ledger) revert LedgerEscrowMismatch();` · `SyndicateGovernor.sol:1403` · Refuses to lock a bond into an escrow bound to a different ledger than the one that will gate its release.

#### G-22
`if (newLedger != address(0) && _openProposalCount > 0) revert ParamsFrozenDuringProposal();` · `SyndicateGovernor.sol:2300` · Prevents wiring a ledger mid-flight, which would make pre-ledger proposals permanently unexecutable.

#### G-23
`if (_openProposalCount > 0) revert ParamsFrozenDuringProposal();` · `ProposalLifecycle.sol:41` · Freezes every governance parameter for the duration of a proposal, so the rules cannot shift under an in-flight vote.

#### G-24
`if (_registrySet) revert RegistryAlreadySet();` · `StakedWood.sol:581` · One-shot latch on the only address permitted to drive the review-path slash.

#### G-25
`if (v > maxSlashBps) revert InvalidParameter();` · `StakedWood.sol:859` · Keeps the slash-severity envelope ordered; paired with G-26 it makes `minSlashBps <= maxSlashBps` unbreakable from either setter.

#### G-26
`if (v < minSlashBps || v > 10_000) revert InvalidParameter();` · `StakedWood.sol:868` · Upper half of the same ordering invariant, plus the absolute 100% ceiling.

#### G-27
`if (reg != address(0) && v < IRegistryReviewPeriod(reg).reviewPeriod()) revert CooldownBelowReviewPeriod();` · `StakedWood.sol:836` · A guardian must not be able to unstake faster than the review that could slash them concludes.

#### G-28
`if (l.openExposureUsd(msg.sender) != 0 || l.hasFrozenCoverage(msg.sender)) revert CoverageStillOpen();` · `StakedWood.sol:986` · Holds a guardian's stake while any coverage they wrote is still open or frozen.

#### G-29
`if (_verdictSlashed[caseKey][approvers[i]]) revert ApproverAlreadySlashed();` · `StakedWood.sol:1494` · One slash per (case, approver) — stops a verdict from being replayed to compound a slash.

#### G-30
`if (v > sw.coolDownPeriod()) revert CooldownBelowReviewPeriod();` · `GuardianRegistry.sol:1199` · Mirror of G-27 from the registry side, so the cooldown ≥ review-period invariant holds from either setter.

#### G-31
`if (led.challengeWindow() < v + MAX_GOVERNOR_EXECUTION_WINDOW) revert InvalidParameter();` · `GuardianRegistry.sol:1212` · Keeps the coverage bucket alive long enough to outlive the proposal it backs, defeating approve-twice-per-bucket batching.

#### G-32
`if (boundRegistry != address(0) && boundRegistry != address(this)) revert InvalidParameter();` · `GuardianRegistry.sol:1284` · Refuses to point at a ledger that is bound to a different registry.

#### G-33
`if (block.timestamp >= lockoutStart) revert VoteChangeLockedOut();` · `GuardianRegistry.sol:604` · Freezes guardian vote-flipping near the end of review so the block-quorum computation cannot be gamed on the last block.

#### G-34
`if (cap == 0) revert NoWoodPrice();` · `ExposureLedger.sol:627` · Refuses to price coverage at all when the governance cap is unset — the WOOD price is never "uncapped", only "unavailable".

#### G-35
`if (_frozenKeyCount != 0) revert CoverageFrozen();` · `ExposureLedger.sol:1053` · Blocks rotating the coverage freezer while any freeze is live, which would strand every live freeze with no unfreeze path.

#### G-36
`if (_pinnedUntil[key][guardian] >= block.timestamp) revert CoveragePinnedActive();` · `ExposureLedger.sol:1510` · Reads the per-key pin, not the per-guardian max, so one proposal's pin cannot block an unrelated proposal's retire (audit #181 finding C).

#### G-37
`if (_convicted[key]) revert AlreadyConvicted();` · `ChallengeGame.sol:854` · Enforces one liability per proposal — once collected, no further filing can extract a second one.

#### G-38
`if (newDelay < MIN_AUTO_SLASH_DELAY || newDelay >= disputeTimeout) revert InvalidParameter();` · `ChallengeGame.sol:2414` · Keeps the silence window strictly inside the dispute window; paired with G-39 the ordering is unbreakable from either setter.

#### G-39
`if (newTimeout <= autoSlashDelay || newTimeout > MAX_DISPUTE_TIMEOUT) revert InvalidParameter();` · `ChallengeGame.sol:2426` · Other half of the same ordering, plus the 60-day absolute ceiling.

#### G-40
`if (participationFloorBps >= IStakedWoodAgeFloor(newStakedWood).ageFloorBps()) revert FloorInvariantViolated();` · `TokenCourt.sol:258` · Keeps the court's participation floor strictly below sWOOD's age-weight floor, so a fresh-stake electorate cannot be a quorum by construction. One-sided — see [X-2](#x-2).

---

## 2. Inferred Invariants (Single-Contract)

Inferred invariants are derived from structural analysis of the source code. Each block below cites one of five extraction methods in its `Derivation` field:

- **Δ-pair (delta-pair) analysis** — two or more storage variables in the same function body that change by equal-and-opposite amounts, implying a conservation law.
- **Guard lift** — a `require` / `if-revert` on a storage variable, promoted from a per-call precondition to a global property by checking that *every* other write site of that variable enforces an equivalent guard.
- **State-machine edge** — a storage variable that transitions through discrete values with no reverse path.
- **Temporal predicate** — a check tied to `block.timestamp`, `block.number`, or a stored duration/deadline variable.
- **NatSpec-stated global property** — a developer-asserted invariant, routed here and then confirmed or contradicted by the structural scan.

Each block is classified into one of five **categories** by shape: `Conservation` · `Bound` · `Ratio` · `StateMachine` · `Temporal`. Category definitions at the end of §2.

---

#### I-1

`Conservation` · On-chain: **No**

> `wood.balanceOf(ChallengeGame) >= bondedWood + unclaimedWood` at all times.

**Derivation** — NatSpec: `ChallengeGame.sol` header — *"The game SHALL track `bondedWood` … and `unclaimedWood` … maintaining `wood.balanceOf(game) >= bondedWood + unclaimedWood` at all times"*. Structural confirmation via Δ-pairs: `file` `Δ(bondedWood)=+bondWood` ↔ `wood.safeTransferFrom(challenger, this, bondWood)`; `dispute:1221` `Δ(bondedWood)=+amount` ↔ `Δ(_contributed[id][sender])=+amount`; `_settle:1414` `Δ(bondedWood)=-(bond+pool)` ↔ two `safeTransfer` legs; `_fail:1790` `Δ(bondedWood)=-(bond+pool)`, `Δ(unclaimedWood)=+(pool+payout)`; `claimContribution:2098` `Δ(_contributed)=0` ↔ `Δ(unclaimedWood)=-amount`. Never asserted at runtime.

**If violated** — a terminal path pays out more WOOD than the game holds, and the last claimant's `safeTransfer` reverts with no recovery route.

---

#### I-2

`Conservation` · On-chain: **Yes**

> `totalBondedWood == Σ _bonds[k].amount` over all live submitter bonds, and the bond token cannot change while any bond is outstanding.

**Derivation** — Δ-pair: `TierRegistry.certify` `Δ(totalBondedWood) = +p.bondAmount` ↔ `Δ(_bonds[k]) = SubmitterBond{...}`; `claimSubmitterBond:711-712` `Δ(_bonds[k]) = delete` ↔ `Δ(totalBondedWood) = -b.amount`. These are the only two write sites of `totalBondedWood`. Token-swap guard-lift: `setWood:333` `if (totalBondedWood != 0) revert BondsOutstanding();` — the sole writer of `wood`.

**If violated** — a submitter's bond becomes unclaimable, or the registry pays a bond in a token it no longer holds.

---

#### I-3

`Conservation` · On-chain: **Yes**

> `totalGuardianStake == Σ _guardians[g].stakedAmount` over guardians with `unstakeRequestedAt == 0` (active stake only).

**Derivation** — Δ-pair set: `stakeAsGuardian` `Δ(g.stakedAmount)=+amount` ↔ `Δ(totalGuardianStake)=+amount`; `requestUnstakeGuardian:898` `Δ(totalGuardianStake)=-g.stakedAmount` with `stakedAmount` deliberately unchanged (leaves the active set); `cancelUnstakeGuardian` `+g.stakedAmount` (rejoins); `_slashOne:1665-1673` `Δ(g.stakedAmount)=-ownSlash` with `Δ(totalGuardianStake)=-ownSlash` **only** on the `g.unstakeRequestedAt == 0` branch — the else-branch is correct precisely because the aggregate was already decremented at request time.

**If violated** — the block-quorum denominator (`getPastTotalVotes`) diverges from the real electorate, moving the guardian veto threshold in one direction or the other.

---

#### I-4

`Conservation` · On-chain: **No**

> `_reservedAssets == Σ_pid _pidReserved[pid]`, and `_stampedUnclaimedShares` equals the outstanding stamped share count.

**Derivation** — Δ-pair: `stampSettlement:156+` `Δ(_pidReserved[pid])=+reservedForPid` ↔ `Δ(_reservedAssets)=+reservedForPid` ↔ `Δ(_stampedUnclaimedShares)=+redeemShares`. The unwind at `claim` is **saturating**, not exact: `queue/VaultWithdrawalQueue.sol:241` `_reservedAssets = reserved > release ? reserved - release : 0;` and `:246` `_stampedUnclaimedShares = stamped > amount ? stamped - amount : 0;`. Any path where `release > _reservedAssets` clamps to zero and breaks the equality downward permanently.

**If violated** — the vault's `reservedQueueAssets()` under-reports what the queue owes, so G-2's reserve floor admits a batch that spends stamped-but-unclaimed assets.

---

#### I-5

`Conservation` · On-chain: **No**

> `_liveBookedUsd[g] == Σ_keys _recorded[key][g].usd` and `_livePledgedUsd[g] == Σ_keys _reservedUsd[key][g]`, for every guardian.

**Derivation** — Δ-pair: `ExposureLedger.recordApproval:1352+` moves `_buckets[g][epoch]`, `_reservedUsd[key][g]`, `_committedUsd[key]`, `_liveBookedUsd[g]`, `_livePledgedUsd[g]` all by `+share` in one body; `_unwindApproval` reverses with `-r.usd` on the booking side and `-reserved` on the pledge side; `_rebook` moves `_buckets[g][r.epoch]` and `_liveBookedUsd[g]` by the same signed delta and deliberately leaves the pledge side untouched. The two accumulators are never reconciled against the mappings they summarize.

**If violated** — the shared-stake partition-of-unity breaks: one bond can be counted as backing more than 100% of the proposals it actually backs.

---

#### I-6

`Conservation` · On-chain: **No**

> `openExposureUsd(g)` equals `_liveBookedUsd[g]` only when all of a guardian's live exposure sits inside the 16-epoch scan window.

**Derivation** — guard-lift: `ExposureLedger._requireScanBounded` caps the `openExposureUsd:2625` walk at `MAX_SCAN_BUCKETS = 16`, while `_liveBookedUsd[g]` (I-5) is an exact non-decaying accumulator. Two different notions of "open exposure" coexist, and the batching cap at `recordApproval:1318` (`if (open >= capUsd) return;`) uses the *bounded* one.

**If violated** — exposure that has aged past the scan window is invisible to the batching cap, so a guardian can write fresh coverage against a bond that is already fully committed.

---

#### I-7

`Conservation` · On-chain: **Yes**

> `_frozenKeyCount == |{ key : _frozen[key] }|`.

**Derivation** — Δ-pair: `ExposureLedger.freezeCoverage:1604-1605` `Δ(_frozenKeyCount)=+1` guarded by `if (!_frozen[key])`; `unfreezeCoverage:1627-1628` `Δ(_frozenKeyCount)=-1` guarded by `if (_frozen[key])`. These are the only write sites, and each is idempotent under its own guard.

**If violated** — G-35's freezer-rotation gate would let the freezer be re-pointed while a freeze is live, stranding every accused guardian's stake.

---

#### I-8

`Conservation` · On-chain: **No**

> `_activeProposal != 0` implies `_openProposalCount >= 1`.

**Derivation** — Δ-pair: `SyndicateGovernor.executeProposal:446` `Δ(_activeProposal) = proposalId` with `_openProposalCount` already incremented at `propose`; `_finishSettlement:1849-1852` `Δ(_activeProposal)=0` then `_decOpen()` `Δ(_openProposalCount)=-1` in the same body with no intervening external call. Every other `_decOpen()` call site (`cancelProposal:640`, `emergencyCancel:661`, `vetoProposal:874`, `rejectCollaboration:961`, `_commitState`) operates on non-Executed states where `_activeProposal` is already zero. Never asserted.

**If violated** — the vault's `redemptionsLocked()` and the parameter freeze (G-23) disagree with the real lifecycle state.

---

#### I-9

`Bound` · On-chain: **Yes**

> `_params.maxPerformanceFeeBps <= FeeConstants.MAX_PERFORMANCE_FEE_BPS (3000)` globally.

**Derivation** — guard-lift from `GovernorParameters.setMaxPerformanceFeeBps:221`, plus enumeration of every write site of `_params`: `initialize` and `forceSetParams` (`SyndicateGovernor.sol:2324`) both route through `_validateParamBounds` (`GovernorParameters.sol:163-192`), which re-applies the same ceiling. Three write sites, three equivalent guards.

**If violated** — a factory-pushed rescue-path parameter set could seat a fee above the protocol ceiling on a live vault.

---

#### I-10

`Bound` · On-chain: **Yes**

> `mgmtSplit.agentBps + protocolBps + guardianBps == 10_000` and `perfSplit.agentBps + protocolBps + guardianBps + ownerBps == 10_000`.

**Derivation** — guard-lift: `ProtocolConfig.sol:93-94` and `:104-105` reject any sum ≠ `BPS_DENOMINATOR`. `setMgmtSplit` and `setPerfSplit` are the only write sites of `_mgmtSplit` / `_perfSplit` (whole-struct overwrite, no partial setters, no initializer — the contract is non-upgradeable `Ownable2Step`).

**If violated** — settlement would either over-distribute the fee pool (reverting on the last leg) or silently strand the remainder.

---

#### I-11

`Bound` · On-chain: **Yes**

> `minSlashBps <= maxSlashBps <= 10_000` globally.

**Derivation** — guard-lift over all three write sites: `StakedWood.initialize:569` (`p.minSlashBps > p.maxSlashBps || p.maxSlashBps > 10_000`), `setMinSlashBps:859` (G-25), `setMaxSlashBps:868` (G-26). No other writer touches either field.

**If violated** — the verdict-slash clamp envelope inverts and `Math.mulDiv` could produce a rate outside `[min, max]`.

---

#### I-12

`Bound` · On-chain: **Yes**

> `autoSlashDelay < disputeTimeout <= MAX_DISPUTE_TIMEOUT (60 days)` globally.

**Derivation** — guard-lift over both write sites: `ChallengeGame.setAutoSlashDelay:2414` (G-38) and `setDisputeTimeout:2426` (G-39) each reject values that would invert the ordering, so neither setter can break it unilaterally. The constructor seeds a valid pair.

**If violated** — the silence window would outlast the dispute window, making `resolve` reachable on both branches at once.

---

#### I-13

`Bound` · On-chain: **No**

> "A non-verdict never costs more than a verdict" — i.e. the Inconclusive burn rate never exceeds `settleBurnBps`.

**Derivation** — guard-lift, negative result. `ChallengeGame.setSettleBurnBps:2455` bounds only against `MAX_SETTLE_BURN_BPS`; `setInconclusiveBurnBps:2512` bounds only against `MAX_INCONCLUSIVE_BURN_BPS`. The cross-setter check was **deliberately removed** (second-audit finding C, documented in the setter's own natspec). `_inconclusiveBurnBpsForRound` still clamps rounds 1–3 to the live `settleBurnBps` but no longer clamps round 4+. Both ceilings are 5,000 bps, so the round-4+ tier can legally exceed `settleBurnBps`.

**If violated** — a challenger drawing repeated Inconclusive verdicts pays more per round than a losing verdict would have cost. That is the intended pricing for a griefer, and simultaneously the honest filer's tail risk.

---

#### I-14

`Bound` · On-chain: **Yes**

> `PortfolioStrategy.maxSlippageBps` is monotonically non-increasing after initialization, and stays within `[MIN_SLIPPAGE_BPS, 1000]`.

**Derivation** — guard-lift over both write sites: `_initialize` seeds within `[50, 1000]`; `_updateParams:496` `if (newMaxSlippageBps > maxSlippageBps || newMaxSlippageBps < MIN_SLIPPAGE_BPS) revert InvalidSlippage();` — tighten-only. No other writer.

**If violated** — a proposer could widen the slippage budget mid-strategy and sandwich their own rebalance.

---

#### I-15

`Bound` · On-chain: **Yes**

> The WOOD price used for all coverage math is `haircut(min(marketSource, woodUsdPriceX8))`, floored at 1, and is never served uncapped.

**Derivation** — guard-lift: `ExposureLedger.sol:627` `if (cap == 0) revert NoWoodPrice();` (G-34) sits on the only path that produces a price, so an unset governance cap is a hard revert rather than a fallthrough to the raw market source. `woodHaircutBps` is bounded `[5_000, 10_000]` at its single setter.

**If violated** — a manipulated TWAP or feed would set the guardian bond's USD value directly, and the batching cap (E-1) with it.

---

#### I-16

`Ratio` · On-chain: **Yes**

> Queue payouts use exactly one frozen price per proposal: `assets = shares * sp.num / sp.den` (Redeem, own pid) and `shares = assets * sp.den / sp.num` (Deposit, `_lastStampedPid`).

**Derivation** — Ratio at `queue/VaultWithdrawalQueue.sol:219` and `:283`, with the snapshot pinned by G-10. Snapshot ordering is load-bearing: `stampSettlement` is reached from `SyndicateVault.onProposalSettled`, itself called inside `_finishSettlement` **after** all fee transfers (`SyndicateGovernor.sol:1832-1848`), so the frozen price is post-fee NAV. Deposits deliberately price at the latest stamp rather than their own pid, to remove a perpetual look-back option on vault NAV.

**If violated** — a queued participant could choose the more favourable of two NAVs, diluting incumbents.

---

#### I-17

`Ratio` · On-chain: **Yes**

> After coverage scaling, `Σ floor(cap_i * s) <= effectiveMaxCapital`.

**Derivation** — Ratio with explicit re-assertion: `SyndicateGovernor._scaleCaps:1635-1669` derives the bound from the propose-time invariant `Σ caps <= maxCapital`, then re-asserts it and absorbs any truncation dust into the largest cap rather than trusting the derivation.

**If violated** — per-call caps would sum above the coverage-proportional capital the guardians actually underwrote.

---

#### I-18

`Ratio` · On-chain: **Yes**

> `_highWaterPricePerShare` is monotonically non-decreasing within a supply epoch, and resets to 0 exactly when `totalSupply() == 0`.

**Derivation** — write-site enumeration: `ratchetHighWaterMark` (raises only when `pps > mark`), `_initHighWaterMarkIfUnset` (writes only when `== 0 && totalSupply() != 0`), and the deliberate reset at `SyndicateVault._update:1213` on empty supply. The reset is the only decrease and is unreachable while any share exists.

**If violated** — performance fees would be charged on a price the vault has already paid a fee on.

---

#### I-19

`StateMachine` · On-chain: **Yes**

> `_withdrawalQueue` transitions `address(0) → q` exactly once and never again.

**Derivation** — edge: `SyndicateVault.sol:461 → :462`, guarded by G-6, factory-only. No delete or reassignment path exists.

**If violated** — escrowed shares and assets in the old queue would become unreachable.

---

#### I-20

`StateMachine` · On-chain: **Yes**

> `_convicted[reviewKey]` transitions `false → true` exactly once per proposal, and every later filing against that proposal reverts.

**Derivation** — edge: `ChallengeGame.sol:854 (checked) → :1438/:1441 (set)`, guarded by G-37, cross-checked against sWOOD's own `verdictSlashed` dedup at `:892`. NatSpec: *"Once any settled challenge has collected the proposal's one liability (`_convicted`), ALL further filings against that proposal SHALL revert `AlreadyConvicted`"*.

**If violated** — the same approver set could be slashed repeatedly for one proposal.

---

#### I-21

`StateMachine` · On-chain: **Yes**

> `_verdictSlashed[caseKey][approver]` transitions `false → true` exactly once.

**Derivation** — edge: `StakedWood.sol:1494 (checked, G-29) → :1512 (set)`. No reset path.

**If violated** — a replayed verdict would compound slashes on the same guardian.

---

#### I-22

`StateMachine` · On-chain: **Yes**

> `caseOfChallenge[game][challengeId]` transitions `0 → caseId` exactly once, and the claim is written before any external read.

**Derivation** — edge: `TokenCourt.sol:387 (checked) → :390 (set)`, and `:390` precedes the external `IChallengeGame(game).challengeOf` read — the ordering is the reentrancy defense, not just style.

**If violated** — one challenge could be referred to two cases and receive two verdicts.

---

#### I-23

`StateMachine` · On-chain: **Yes**

> `_activeProposal` cycles `0 → proposalId → 0` with no path that overwrites a nonzero value.

**Derivation** — edge: `SyndicateGovernor.sol:433 (checked, G-14) → :446 (set) → :1849 (cleared)`. `_finishSettlement` is the only clearer and it runs after all fee transfers.

**If violated** — two strategies could share one capital snapshot.

---

#### I-24

`StateMachine` · On-chain: **Yes**

> `BaseStrategy._state` advances `Pending → Executed → Settled` with no reverse edge, and `_initialized` latches once.

**Derivation** — edges: `strategies/BaseStrategy.sol:133 → :134` and `:155 → :156`; `_initialized` `false@:102 → true@:105`, also forced `true` in the template constructor at `:87`, permanently disabling the implementation's own `initialize`.

**If violated** — a clone could be re-executed against a second proposal, or an uninitialized template could be seized.

---

#### I-25

`StateMachine` · On-chain: **Yes**

> `_bonds[key].proposer` latches `address(0) → proposer` on lock, and returns to `address(0)` through exactly two exits: release or forfeit.

**Derivation** — edge: `ProposerBondEscrow.sol:139 (checked) → :142 (set)`, then `:161 (delete, release)` or `:256 (delete, forfeit)`. NatSpec: *"TWO EXITS, AND ONLY TWO"* and *"NO PARTIAL FORFEIT: the whole bond always leaves the proposer"*.

**If violated** — a bond could be double-released or partially escape the forfeit path.

---

#### I-26

`StateMachine` · On-chain: **Yes**

> `_prepared[owner].bound` latches `false → true`, and a vault slot cannot be bound over a nonzero prior stake.

**Derivation** — edges: `StakedWood.sol:1128 (checked) → :1133 (bindOwnerStake)` and `:1235 → :1241 (transferOwnerStakeSlot)`; prior-stake guard at `:1125` / `:1232` `if (_ownerStakes[vault].stakedAmount != 0) revert PriorStakeNotCleared();`.

**If violated** — an owner bond could be silently overwritten, orphaning the prior owner's WOOD.

---

#### I-27

`StateMachine` · On-chain: **Yes**

> `p.state` is written at exactly one site.

**Derivation** — NatSpec: `ProposalLifecycle.sol` — *"Single-writer invariant: `p.state =` appears nowhere but `_transition`"* and *"Single-resolver invariant: `_computeState` is the ONE resolver"*. Structural confirmation: `_transition:203` is the sole assignment; every state change in `SyndicateGovernor` (`:447`, `:640`, `:661`, `:868`, `:910`, `:959`, `:1850`) routes through it.

**If violated** — the guardian-registry economic commit (`resolveReview`, fired only from `_commitState`) could desynchronize from the proposal's actual outcome.

---

#### I-28

`StateMachine` · On-chain: **Yes**

> `TokenCourt` holds no WOOD at any point in any case lifecycle.

**Derivation** — NatSpec: `token-court/spec.md` — *"The court SHALL hold no WOOD at any point in any case lifecycle"*. Structural confirmation: `TokenCourt.sol` contains no `safeTransfer` / `safeTransferFrom` / `call{value:}` of any kind; its only state-changing external call is `IChallengeGame.rule`.

**If violated** — the verdict contract would become a custody target, and its `finalize` a fund-moving function.

---

#### I-29

`StateMachine` · On-chain: **Yes**

> Every slash path terminates at `BURN_ADDRESS`, net only of the bounded conviction bounty and prosecutor fee. No path routes proceeds to a depositor, shareholder, or caller-chosen address.

**Derivation** — NatSpec: `guardian-slashing/spec.md` — *"Every slash path SHALL send its proceeds to the burn address, net of the conviction bounty where one applies."* Structural confirmation: `StakedWood.slashGuardians` / `slashVerdict` / `slashOwnerBond` all funnel to `_burnWood` → `BURN_ADDRESS` (with a `_pendingBurn` retry queue and permissionless `flushBurn`); `ProposerBondEscrow.forfeitBond` splits into `feeTo` (bounded by `MAX_PROSECUTOR_FEE_BPS = 2000`) and `BURN_ADDRESS`.

**If violated** — slashing would become an indemnity mechanism, creating an incentive to manufacture convictions.

---

#### I-30

`Temporal` · On-chain: **Yes**

> `challengeableUntil[reviewKey]` is raise-only.

**Derivation** — temporal: `ChallengeGame._rearmChallengeWindow` writes `max(current, block.timestamp + challengeWindow)`, immediately followed by `exposureLedger.pinCoverageUntil` with the same deadline. No decreasing write exists.

**If violated** — an Inconclusive or Failed round could shorten the window it was supposed to extend.

---

#### I-31

`Temporal` · On-chain: **Yes**

> `_pinnedCoverageUntil[g]` and `_pinnedUntil[key][g]` are raise-only ratchets driven from a single `deadline`, so they cannot diverge.

**Derivation** — temporal: `ExposureLedger.pinCoverageUntil:1695-1696` — both writes are conditional on `deadline > current` and read the identical parameter.

**If violated** — the per-key pin read by G-36 could lag the per-guardian max, letting a retire sweep run while a challenge is live.

---

#### I-32

`Temporal` · On-chain: **Yes**

> `retireApproval` is gated on epoch-bucket expiry plus the full challenge window, not on the proposal's own clock.

**Derivation** — temporal: `ExposureLedger.sol:1518-1520` `if (block.timestamp <= epochGenesis + (uint256(r.epoch) + 1) * epochLength + challengeWindow) revert ChallengeWindowOpen();`.

**If violated** — a permissionless sweep could empty `_approversOf[key]` while the proposal is still challengeable, making it permanently unchallengeable. Which window this reads is the subject of [X-4](#x-4).

---

#### I-33

`Temporal` · On-chain: **Yes**

> Court voting weight is snapshotted at `executedAt - 1`, pinned once at `refer`, and never re-read live.

**Derivation** — temporal: `TokenCourt.refer` writes `c.snapshotTs` from the challenge's `executedAt - 1`; `vote:646` reads `getPastVotes` / `getPastStake` at that pinned timestamp, combined with a growth-gated lookback minimum over `FLOOR_LOOKBACK = 30 days`.

**If violated** — a flash-acquired WOOD position could decide a verdict.

---

#### I-34

`Temporal` · On-chain: **Yes**

> `WoodTwapOracle.consult()` degrades to `(0, false)` rather than serving a stale, zero, or over-extrapolated price.

**Derivation** — temporal: `pricing/WoodTwapOracle.sol:380` (`span < twapWindow || span > MAX_TWAP_SPAN`), `:381` (`age > maxTwapAge`), `:517` (idle-span extrapolation bound, `idle * MAX_IDLE_SPAN_DIVISOR > twapWindow`), `:390` / `:405` (zero-price rejection), `:556` (ETH/USD leg `age > ethUsdMaxDelay`). Every failure mode returns `ok = false`; none returns a floored-to-zero price.

**If violated** — the ledger's primary WOOD valuation would silently accept a stale or extrapolated number.

---

#### I-35

`Temporal` · On-chain: **Yes**

> `twapWindow <= maxTwapAge` globally.

**Derivation** — guard-lift over both write sites: `_setTwapWindow:454` (`newWindow > maxTwapAge` reverts) and `_setMaxTwapAge:464` (`newAge < twapWindow` reverts). The constructor seeds in the order `maxTwapAge → twapWindow → ethUsdMaxDelay`, which the natspec flags as load-bearing.

**If violated** — every `consult()` would return `ok = false` permanently, bricking the primary price source.

---

#### I-36

`Bound` · On-chain: **Yes**

> `reviewPeriod ∈ [minReviewPeriod, 3 days]` and `blockQuorumBps ∈ [1_000, 10_000]`, with `blockQuorumBpsAtOpen` snapshotted per review.

**Derivation** — guard-lift: `GuardianRegistry.initialize:274` / `:283` and `setReviewPeriod:1197` / `setBlockQuorumBps:1221` are the only write sites, all bounded. The per-review snapshot (`openReview:916` writes `r.blockQuorumBpsAtOpen`) means a mid-review change cannot move the threshold for a review already open.

**If violated** — the block quorum could be shifted under an in-flight guardian review.

---

#### I-37

`StateMachine` · On-chain: **Yes**

> `syndicates[id].active` is one-way `true → false`, with no reactivation path.

**Derivation** — edge: `SyndicateFactory.sol:431 (set at create) → :495 (deactivate)`, creator-gated, paired with `Δ(_activeSyndicateIds) = remove(id)` in the same body with no intervening external call.

**If violated** — a deactivated syndicate could silently rejoin the active enumeration.

---

#### I-38

`Bound` · On-chain: **Yes**

> `_agentSet.length() <= MAX_AGENTS_PER_VAULT`, and no agent address is registered twice.

**Derivation** — guard-lift: `SyndicateVaultAdminLib.sol:76` (`agents[agentAddress].active` re-registration guard) and `:79` (cap). `registerAgent` is the only growth path; `removeAgent` / `drainAgents` are the only shrink paths, and both delete the mapping entry and the set member together.

**If violated** — agent enumeration would become unbounded, and a stale `agentId` could be silently reused.

---

#### I-39

`Temporal` · On-chain: **Yes**

> `certifyDelay ∈ [1 day, 30 days]`, `bondReleaseDelay ∈ [1 day, 365 days]`, and a certification must be executed inside `[readyAt, readyAt + MAX_CERTIFY_WINDOW]` against an unchanged codehash.

**Derivation** — guard-lift plus temporal: `TierRegistry.setCertifyDelay:573` and `setBondReleaseDelay:355` are the sole writers of their fields; `certify:505-508` enforces `readyAt != 0`, `block.timestamp >= readyAt`, `block.timestamp <= readyAt + MAX_CERTIFY_WINDOW`, and `target.codehash == p.codehash`.

**If violated** — a compromised registry owner could reprice extractable value instantly, or execute a stale certification against redeployed code.

---

**Categories:**
- **Conservation**: Two or more storage variables change by equal-and-opposite amounts in the same function body. Pattern: `Δ(A) = +x, Δ(B) = -x` → `A + B = const`.
- **Bound**: A guard on a storage variable, *lifted to a global property* and enforced across every write site of that variable. On-chain=**No** if any write site lacks the equivalent guard.
- **Ratio**: A storage variable is defined as a formula of other storage variables.
- **StateMachine**: A storage variable transitions through discrete values with guards preventing reversal.
- **Temporal**: A condition depends on `block.timestamp`, `block.number`, or a duration/deadline variable.

---

## 3. Inferred Invariants (Cross-Contract)

Trust assumptions that span contract boundaries. Each block cites both caller-side and callee-side code.

---

#### X-1

On-chain: **Yes** (once both pointers are wired)

> `StakedWood.coolDownPeriod >= GuardianRegistry.reviewPeriod` — a guardian cannot unstake faster than the review that could slash them concludes.

**Caller side** — `GuardianRegistry.sol:1199-1201` — `setReviewPeriod` reads the live `sw.coolDownPeriod()` and reverts `CooldownBelowReviewPeriod` if the new period would exceed it.

**Callee side** — `StakedWood.sol:836-838` — `setCooldownPeriod` reads the live `reg.reviewPeriod()` and reverts symmetrically. Both guards are conditional on the counterparty pointer being non-zero — see [X-1b](#x-1b).

**If violated** — an approver could complete the cooldown and withdraw before `resolveReview` reaches them.

---

#### X-1b

On-chain: **No**

> The same cooldown ≥ review-period coupling, during the wiring window.

**Caller side** — `GuardianRegistry.sol:1199` — the guard sits inside `if (address(sw) != address(0))`.

**Callee side** — `StakedWood.sol:836` — the guard sits inside `if (reg != address(0))`, and `setRegistry` (the one-shot latch of G-24) performs no ordering check against the already-seated `coolDownPeriod`.

**If violated** — a deployment-ordering mistake seats the pair inconsistently with no on-chain signal.

---

#### X-2

On-chain: **No**

> `TokenCourt.participationFloorBps < StakedWood.ageFloorBps` — the court's anti-capture floor must stay strictly below sWOOD's age-0 weight floor.

**Caller side** — `TokenCourt.sol:258-260` (`setStakedWood`, G-40) and `:320-322` (`setParticipationFloorBps`) both read the live `ageFloorBps()` and revert `FloorInvariantViolated`. The second is additionally vacuous when `stakedWood == address(0)`.

**Callee side** — `StakedWood.setAgeFloorBps:874-876` — bounded only by `[1, 10_000]`. It holds no pointer back to the court and performs no reverse check. The court's own natspec documents this as intentional: *"giving it one would invert the dependency direction … covered by the wire-time pre-flight and off-chain monitoring, not by this setter — see issue #84."*

**If violated** — lowering `ageFloorBps` below the court's floor makes the participation floor unreachable by any electorate, so every disputed case resolves Inconclusive.

---

#### X-3

On-chain: **No** (fail-open)

> `ExposureLedger.challengeWindow >= GuardianRegistry.reviewPeriod + MAX_GOVERNOR_EXECUTION_WINDOW` — a coverage bucket must outlive the proposal it backs.

**Caller side** — `GuardianRegistry.sol:1212-1214` (`setReviewPeriod`) and `:1279` (`setExposureLedger`, G-31) both enforce the floor.

**Callee side** — `ExposureLedger.setChallengeWindow:1010-1015` mirrors it, but inside `try IRegistryApproversMinimal(reg).reviewPeriod() { … } catch {}` and gated on `reg.code.length != 0` — a registry that reverts or is unset silently skips the bound. The natspec states this is deliberate: *"Liveness of a governance setter must not depend on a foreign contract answering a view call."*

**If violated** — approve #1 just before an epoch boundary, let the bucket expire while #1 is still Approved and inside its execution window, then approve #2 at full budget: one bond covers two live drains.

---

#### X-4

On-chain: **No** (fail-open, and vacuous when the freezer is unset)

> `ChallengeGame.challengeWindow <= ExposureLedger.challengeWindow` — the filing deadline must never outlast the coverage that would pay the challenge.

**Caller side** — `ChallengeGame.sol:711` (`setExposureLedger`) and `:2305` (`setChallengeWindow`) both enforce `<=` against the ledger's live value; the constructor does too.

**Callee side** — `ExposureLedger.setChallengeWindow:1035-1041` mirrors the check back (added for audit-181 finding D, *"WINDOW COUPLING IS ONE-SIDED"*), but inside `try IChallengeGameWindowMinimal(freezer).challengeWindow() { … } catch {}` and gated on `freezer != address(0) && freezer.code.length != 0`. `setCoverageFreezer:1052` may legally set the freezer to zero once nothing is frozen (G-35), after which the mirror vacates entirely. None of the four checks re-fires when the counterparty moves afterward.

**If violated** — `retireApproval`'s gate ([I-32](#i-32), keyed off the ledger window) opens before `ChallengeGame.file`'s deadline (keyed off the game window) closes, so a permissionless sweep can empty `_approversOf` while the proposal is still legally filable. `SyndicateGovernor.reclaimProposerBond` gate 1 ([G-18](#g-18)) reads the **ledger** window, so the same gap also governs when the proposer bond is released.

---

#### X-5

On-chain: **Yes**

> `ChallengeGame.autoSlashDelay + TokenCourt.voteWindow + FINALIZE_BUFFER + MIN_REFERRAL_SLACK <= ChallengeGame.disputeTimeout` — a referred case must have room to vote and finalize before the game times it out.

**Caller side** — `TokenCourt.sol:216-219` (`setChallengeGame`) and `:280-284` (`setVoteWindow`) read the game's live `autoSlashDelay` / `disputeTimeout` / `MIN_REFERRAL_SLACK`.

**Callee side** — `ChallengeGame._requireWindowFits:2398-2399`, invoked from `setCourt`, `setAutoSlashDelay`, and `setDisputeTimeout`, reads the court's live `voteWindow()` / `FINALIZE_BUFFER()`. Both sides guard, and neither `catch`es — this is the one window coupling with a symmetric hard check on both ends.

**If violated** — a case could be referred with insufficient clock and resolve Inconclusive by construction.

---

#### X-6

On-chain: **Yes**

> The proposer-bond release gates read the ledger recorded at propose time, not the governor's live slot.

**Caller side** — `SyndicateGovernor.reclaimProposerBond:800-806` — `address ledger = proposal.proposerBondLedger; if (ledger == address(0)) ledger = _exposureLedger;` then `if (ledger == address(0)) revert ExposureLedgerUnset();`, which fails closed explicitly so a factory `setExposureLedger(0)` cannot bypass the delay in one transaction.

**Callee side** — `ProposerBondEscrow` binds `exposureLedger` as an **immutable**; `SyndicateGovernor._snapshotTierAndGate:1403-1405` ([G-21](#g-21)) refuses to lock a bond into an escrow whose immutable ledger differs from the one being pinned.

**If violated** — the factory could detach a live proposal's release gates by re-pointing `_exposureLedger`.

---

#### X-7

On-chain: **Yes**

> `_governorOf[vault]` only ever names a governor this factory deployed, verified by an unforgeable round-trip.

**Caller side** — `SyndicateFactory._isFactoryGovernor` → `gov.vault()` → `_governorOf[thatVault] == gov`; enforced at `:708` (`pushWiring`) via `if (!_isFactoryGovernor(governor)) revert NotFactoryGovernor();`.

**Callee side** — `SyndicateGovernor.initialize:200` writes `vault` once under the `initializer` modifier; no setter exists.

**If violated** — an attacker-deployed governor could receive factory wiring pushes.

---

#### X-8

On-chain: **Yes** (for direct code drift)

> A certified `(target, selector)` tier and an allowlisted adapter are honoured only while the target's EXTCODEHASH matches the hash snapshotted at grant time.

**Caller side** — `SyndicateVault._guardBatchCalls:981` ([G-5](#g-5)) calls `isAdapterAllowed(target)`; `SyndicateGovernor._scanCalls` calls `tierOf(target, selector)` at propose and re-resolves at execute ([G-15](#g-15)).

**Callee side** — `TierRegistry.certify:508` / `:527` pins `target.codehash`; `tierOf:248` and `isAdapterAllowed:817` lazily self-heal to the conservative default on mismatch without a state write; `setAdapterAllowed:776` re-pins on grant.

**If violated** — a metamorphic redeploy at a certified address would inherit its tier.

---

#### X-9

On-chain: **No**

> The same codehash pin, for adapters sitting behind a proxy.

**Caller side** — as X-8: `SyndicateVault.sol:981` and `SyndicateGovernor._scanCalls`.

**Callee side** — `TierRegistry.tierOf:248` / `isAdapterAllowed:817` read `target.codehash`, which for a proxy is the proxy's own code and does not change when the implementation is swapped. The tier-policy spec documents this and states *"governance SHALL NOT certify proxied adapters at tier 0/1"* — a discipline expectation the code cannot check.

**If violated** — an upgradeable adapter certified at tier 0/1 could change behaviour entirely without losing its certification.

---

#### X-10

On-chain: **No**

> `GuardianRegistry` and `ExposureLedger` point at each other.

**Caller side** — `GuardianRegistry.setExposureLedger:1284` ([G-32](#g-32)) reads `ILedgerRegistryPointer(ledger).guardianRegistry()` and refuses a ledger bound to a different registry.

**Callee side** — `ExposureLedger.setGuardianRegistry:948` is `onlyOwner` and performs no reverse check against the registry's current `exposureLedger`. The two contracts have independent owners in principle, so the ledger can be re-pointed away without the registry noticing.

**If violated** — `recordApproval` / `releaseApproval` (both `onlyRegistry`) would revert for the live registry, silently un-booking every new approval.

---

#### X-11

On-chain: **No**

> `ChallengeGame` is `StakedWood.authorizedSlasher` for the whole life of a challenge.

**Caller side** — `ChallengeGame._settle:1397+` calls `swood.slashVerdict(...)`, which is `onlyAuthorizedSlasher` (`StakedWood.sol:609`). The game reads `stakedWood.authorizedSlasher` defensively, but the binding is not pinned per challenge the way `settleBurnBpsAtFiling` and `prosecutorFeeBps` are.

**Callee side** — `StakedWood.setAuthorizedSlasher:1287` is `onlyOwner` with no live-challenge guard, unlike `ExposureLedger.setCoverageFreezer` which refuses while `_frozenKeyCount != 0` ([G-35](#g-35)).

**If violated** — rotating the slasher mid-challenge leaves the settle path unable to slash; the conviction still runs its challenger-side accounting but collects no liability.

---

#### X-12

On-chain: **Yes**

> The vault's delegatecall target and its expected codehash are always written together.

**Caller side** — `SyndicateVault.executeGovernorBatch:531` ([G-1](#g-1)) compares them on every batch.

**Callee side** — `setExecutorImpl:621` writes `_executorImpl` and `_expectedExecutorCodehash = newImpl.codehash` in the same body with no intervening call; `initialize` seeds both. Factory-only on both paths.

**If violated** — the vault would delegatecall arbitrary code into its own storage.

---

## 4. Economic Invariants

Higher-order properties derived from combinations of §2 and §3 invariants. Every block traces back to concrete invariant IDs.

---

#### E-1

On-chain: **No**

> A guardian's total open coverage never exceeds `kNumerator × slashableBondUsd(guardian)`.

**Follows from** — `I-5` + `I-6` + `I-15`

**If violated** — one bond underwrites more USD of live risk than it can pay out under slash, so the coverage quorum ([G-16](#g-16)) certifies capital that is not actually collateralized. The cap check at `ExposureLedger.recordApproval:1318` reads `openExposureUsd` (the 16-bucket bounded walk of `I-6`), not the exact `_liveBookedUsd` accumulator of `I-5`; the two agree only inside the scan window.

---

#### E-2

On-chain: **No**

> Filing an honest challenge is net-positive in expectation, so the deterrent has willing filers.

**Follows from** — `I-13` + `I-12`

**If violated** — nobody files, and every gate that depends on the threat of a challenge (`G-18`, `G-19`, `G-20`, [I-32](#i-32)) degrades into a pure time delay. `ChallengeGame` exposes `honestFilingBreaksEven()` and `honestFilingNetPayoffBps()` as views, but no setter is gated on them: `settleBurnBps`, `forfeitBurnBps`, `inconclusiveBurnBps`, `challengerBondBps`, and `prosecutorFeeBps` are five independently-settable owner knobs whose product determines the sign of the payoff.

---

#### E-3

On-chain: **Yes**

> No depositor, shareholder, or queue participant can claim value originating from a slash.

**Follows from** — `I-28` + `I-29`

**If violated** — slashing would become an indemnity, creating an incentive to manufacture convictions against honest guardians.

---

#### E-4

On-chain: **Yes**

> Settlement pays fees at the splits that were in force when the proposal was created, not when it settled.

**Follows from** — `I-10` + `I-9` + `I-27`

**If violated** — a `ProtocolConfig` owner could re-cut an in-flight proposal's fee distribution after the strategy's outcome is known.

---

#### E-5

On-chain: **Yes** (subject to X-9)

> Executed capital never exceeds the coverage-scaled envelope the guardians actually underwrote.

**Follows from** — `I-17` + `X-8` + `G-15` + `G-16` + `G-17`

**If violated** — a proposal could deploy more capital, or at a looser extractable bound, than the approving guardians priced their bond against. The chain holds for direct code drift but not for proxy implementation swaps ([X-9](#x-9)).
