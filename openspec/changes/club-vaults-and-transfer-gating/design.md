# Design: club vaults — transfer gating, holder cap, affirmative approval (SHE-197, SHE-201)

All file:line references are against `origin/main` @ `a5399c7` (`a5399c7b0221bd3c4d7f608b6d81e42e0abd8647`, 2026-08-31) unless a branch is named.

## Context

Verified in-worktree on main @ `a5399c7`:

- **There is no transfer restriction today.** `SyndicateVault` (declared `src/SyndicateVault.sol:53-58`) inherits `ERC4626Upgradeable` + `ERC20VotesUpgradeable` and overrides no `transfer`/`transferFrom`. Grep over the file finds only `transferOwnership` (`:691`, disabled — `public pure override`) and `transferPerformanceFee` (`:1304`). The one `_update` override is `:1445-1491`; after `super._update` it resets `_highWaterPricePerShare` when supply empties (`:1471-1473`) and auto-delegates an undelegated receiver (`:1488-1490`). Its own comment calls it "the single OZ chokepoint for all of them" (`:1466-1468`).
- **The whitelist is a deposit gate, not a holding gate.** `_requireApprovedDepositor` (`:2039-2041`):
  ```solidity
  function _requireApprovedDepositor(address who) private view {
      if (!_openDeposits && !_approvedDepositors.contains(who)) revert NotApprovedDepositor();
  }
  ```
  Two call sites only: `_deposit` (`:2202`) and `requestDeposit` (`:2335`). Storage: `_approvedDepositors` (`:170`), `_openDeposits` (`:173`). Admin bodies are delegatecalled to `SyndicateVaultAdminLib` with `onlyOwner` retained on the wrapper (`:559-572`, library `src/SyndicateVaultAdminLib.sol:36-60`, trust-boundary note `:19-25`). `setOpenDeposits` is `onlyOwner` and unconditional (`:595-598`).
- **Nothing counts holders.** No holder set, no counter, no cap anywhere in `src/`.
- **The withdrawal queue really holds shares.** `requestRedeem` (`:2284-2309`) moves them with an internal `_transfer` at `:2306` — so the escrow goes *through* `_update`:
  ```solidity
  _transfer(owner_, q, shares);
  requestId = IVaultWithdrawalQueue(q).queueRedeem(owner_, shares, pid);
  ```
  `settleRedeem` burns from the queue, not from the LP (`:2372`, `_burn(_withdrawalQueue, shares)`), and `cancel` sends them back (`src/queue/VaultWithdrawalQueue.sol:434`, `IERC20(vault).safeTransfer(r.owner, amount)`). The queue's nonzero share balance is a pinned invariant: `test/invariants/AsyncRedeemInvariants.t.sol:106-110` and `test/fizz/Properties.sol:96-102` (GL-09, `PROPERTIES.md:43`).
  The deposit side escrows ASSETS, not shares (`src/SyndicateVault.sol:2342`), and mints on claim via `settleDeposit` (`:2389-2393`) — unaffected by a transfer gate.
- **Redeem cancel is pre-stamp only; deposit cancel is unconditional.** `src/queue/VaultWithdrawalQueue.sol:425-426` sets `priceFixed` only for `RequestKind.Redeem`. Load-bearing for D8's escape hatch.
- **Optimistic passage lives in one resolver.** `ProposalLifecycle._computeState` (`src/ProposalLifecycle.sol:66-125`); the `Pending` branch is `:77-110`; `liveSupply` nets the queue's checkpointed votes out of past total supply at `:86-99`; veto rejection returns `(Rejected, false)` at `:102-105`; `_transition` (`:230-232`) is the single writer; `_commitState`'s dead-proposal review-cancel is `:272-280`.
- **Governor params are vault-owner-instant, frozen mid-proposal, hardcoded-bounded.** `src/GovernorParameters.sol:194-292` (setters), `:163-192` (`_validateParamBounds`, which the factory rescue path shares), `:39-66` (bounds constants), `:70-80` (param keys), `whenNoActiveProposal` from `src/ProposalLifecycle.sol:39-42`. `vetoThresholdBps` snapshots at Draft→Pending (`src/SyndicateGovernor.sol:1362`, `:1610`); `votesFor` is already accumulated (`:721`).
- **`agentFeeBps = 0` is already reachable and already distinguishable from unset.** Setter `src/SyndicateVault.sol:1427-1433` is `onlyOwner` with an upper bound only (`MAX_AGENT_FEE_BPS`, `:87` = `FeeConstants.MAX_PERFORMANCE_FEE_BPS` = 3000); storage is offset-by-one precisely so an explicit 0% is not the 20% unset default (`:201-207`, `:548-550`, getter `:1418-1424`). The management fee, by contrast, has **no per-vault setter** — it is init-only from a factory global (`:181`, `:547`, `src/SyndicateFactory.sol:372`, `:590-595`).
- **Measured sizes on main @ `a5399c7`** (`forge build --skip test --skip script --sizes`): `SyndicateVault` runtime **32,971** bytes, `SyndicateGovernor` **44,134**, `SyndicateFactory` **24,538**, `SyndicateVaultAdminLib` **2,390**. Limit enforced by CI is 98,304 (`.github/workflows/ci.yml:194-225`, `openspec/config.yaml:21-22`, `openspec/specs/deployment-docs/spec.md:21`).

## D1 — The gate goes in `_update`, before `super._update`, and nowhere else

`_update` is the only hook every share movement passes through: `deposit`/`mint` (via OZ `_mint`), `_burn` (`:2372`), `settleDeposit`'s mint (`:2391`), `_transfer` from `requestRedeem` (`:2306`), the queue's `safeTransfer` back on cancel, and every external `transfer`/`transferFrom`, including one driven through Permit2 (Permit2 calls the token's ordinary `transferFrom`, so it lands here like any other spender — no separate Permit2 surface exists on the share token; the vault's Permit2 machinery at `:135-140`, `:1123`, `:1205` is about the vault spending its ASSET inside governor batches, not about share transfers).

Overriding `transfer`/`transferFrom` instead was rejected: it misses `_transfer` from `requestRedeem` and every internal path, and OZ's own guidance is that `_update` is the hook. Adding a separate `_beforeTokenTransfer`-style hook was rejected: OZ v5 removed it, and re-introducing one is a second chokepoint to keep in sync with the first.

**Placement within the function: the check runs BEFORE `super._update`.** Two reasons. It reverts, so nothing after it matters for correctness — but a pre-check reads pre-move balances, which is what the holder-count arithmetic in D6 wants, and it keeps `super._update`'s checkpoint writes off the failing path entirely. The two existing post-`super` blocks (high-water reset, auto-delegate) stay exactly where they are and in their current order.

**ERC20Votes checkpoints are unaffected — confirmed, not assumed.** A guard that either reverts or falls through changes no argument to `super._update`, so `_transferVotingUnits` sees identical `(from, to, value)` triples on every path that survives. There is no checkpoint written for a reverted transaction because the whole transaction reverts. The one interaction worth naming is the reverse direction: the auto-delegate heal at `:1488-1490` runs on **zero-value** transfers by design ("anyone can arm a stranded undelegated holder by sending it 0 shares", `:1484-1487`), and a naive `require(approved(to))` would kill it for exactly the holders most likely to need it — a legacy holder outside a newly-closed whitelist. Hence the `value == 0` exemption in D2.

## D2 — The exemption set, and why each member is load-bearing

The gate is skipped when ANY of the following holds:

| Exemption | Why it must exist | Citation |
|---|---|---|
| `to == address(0)` | burn — the redeem/settle path (`_burn(_withdrawalQueue, ...)`) and any future burn | `src/SyndicateVault.sol:2372` |
| `from == address(0)` | mint — already gated on `receiver` at both deposit entrypoints; re-gating here is a duplicate check, and `settleDeposit`'s mint would otherwise re-litigate a whitelist decision made at request time | `:2202`, `:2335`, `:2391` |
| `to == address(this)` or `from == address(this)` | the vault holding its own shares is not a beneficial owner; keeps any future self-custody path from tripping the gate | — |
| `to == _withdrawalQueue` | **`requestRedeem` would otherwise revert for every LP in a club vault** — the queue is not and must not be a whitelisted depositor | `:2306`, `:199` |
| `from == _withdrawalQueue` | **`cancel` returns escrowed shares to the LP**; a removed-from-the-whitelist LP would otherwise have their escrow permanently trapped, since post-stamp redeem cancel is already forbidden | `src/queue/VaultWithdrawalQueue.sol:434`, `:425-426` |
| `value == 0` | preserves the permissionless delegation heal; a zero-value transfer creates no beneficial ownership | `src/SyndicateVault.sol:1484-1490` |

The queue exemptions are the ones that would actually break things, and they are cheap to get wrong in a way tests catch late: the fizz property that fails first is `property_GL09_vaultShareSupplyConserved` (`test/fizz/Properties.sol:96`), which sums `vault.balanceOf(address(queue))` into total supply, and the Foundry pin is `invariant_queueShareBalanceCoversPendingShares` (`test/invariants/AsyncRedeemInvariants.t.sol:106`).

**Rejected alternative — whitelist the queue address itself** (call `approveDepositor(queue)` at creation). It works, and it is worse: it puts a contract into the register of beneficial owners, so `approvedDepositorsPaginated` and any off-chain register export lists it as a member; and it depends on a factory step that an owner could later undo with `removeDepositor`, silently bricking Lane B. An address comparison against the set-once `_withdrawalQueue` slot cannot be undone by an owner mistake.

## D3 — Receiver-only. The sender may always leave.

The gate never inspects `from`. Three reasons, in descending order of weight:

1. **Consistency with the existing model.** The deposit gate already checks `receiver` and explicitly not the payer, and the reason is recorded in the contract: "compliance attaches to the share holder... Checking both sides would break subsidised onboarding, so it is not the default" (`src/SyndicateVault.sol:577-582`). A transfer gate that checked the sender would make the two halves of one policy disagree.
2. **Exit is not a compliance event.** Restricting who may SEND creates a fund an investor cannot leave. That is a worse legal fact than the one being fixed, not a better one, and it is the failure mode of most naive transfer-restriction designs.
3. **It makes the gate total anyway.** Since every recipient must be approved, the set of possible holders is exactly the approved set plus grandfathered pre-existing holders, whose number can only shrink. Checking the sender adds nothing to that closure.

## D4 — Flip to whitelist mode: existing holders are grandfathered OUT-only, at zero storage cost (owner decision, do not re-litigate)

**Owner decision (2026-08-31).** When a vault flips `setOpenDeposits(true → false)` with shares already held outside `_approvedDepositors`, those holders SHALL keep every exit: they may `transfer` and `transferFrom` to any APPROVED address, may `redeem`/`withdraw`, and may `requestRedeem` into the queue and cancel back out of it. They SHALL NOT be able to receive further shares — neither by deposit (already true today) nor by transfer (new).

This is not extra machinery; it is what D3 produces for free. Because the gate reads only `to`, a grandfathered holder is simply an address the gate never asks about on the paths that matter to them. **No grandfather set, no snapshot, no migration, no new storage slot.** The counterfactual is worth stating precisely: a design that checked the sender would need a grandfather register seeded at flip time — an unbounded write over an unknown holder set, impossible to do atomically, and permanently divergent from the whitelist thereafter.

Two consequences accepted as part of the decision:

- **A grandfathered holder can only sell to an approved buyer.** That is the intended effect. Their liquidity is not zero — instant redeem and the Lane B queue both remain open to them.
- **The flip does not retro-count.** `maxHolders` (D6) counts holders from the moment counting is enabled; a vault that flips with 150 existing holders is over its own cap and the cap simply forbids CREATING a 151st. It does not, and must not, forcibly reduce anyone's balance. See D9 for why the club template's 99 rather than 100 absorbs this class of slack.

**Rejected alternative — freeze grandfathered balances entirely** (no send, no redeem) until the holder is approved. Rejected outright: it converts a compliance boundary into an expropriation, and it is the single most litigable thing this change could do.

## D5 — A named error, no event

A rejected transfer reverts with `ReceiverNotApproved(address receiver)`. No `TransferRejected` event: a revert produces no logs by definition, so an "event" would have to be emitted on the success path (useless) or the design would have to become a silent no-op returning `false` (an ERC-20 misfeature that breaks every integrator that checks the return). Existing revert-only precedent throughout the vault's error set (`src/interfaces/ISyndicateVault.sol:9-124`), including `NotApprovedDepositor` (`:16`) for the same policy on the deposit side. The new error carries the receiver so a front-end can name the address that failed.

## D6 — Holder-count mechanics: two comparisons in the same `_update` pass

State: one counter (`_holderCount`) and one parameter (`_maxHolders`), both new vault storage carved from the front of `__gap` (`src/SyndicateVault.sol:525`, decrement log `:515-524`). No holder SET — an `EnumerableSet` of every holder is an unbounded write on every transfer and buys nothing the count does not.

Computed pre-`super._update` from pre-move balances:

- **`to` gains a slot** iff `value != 0 && balanceOf(to) == 0` and `to` is a counted address.
- **`from` frees a slot** iff `value != 0 && balanceOf(from) == value` and `from` is a counted address.
- A counted address is any address except `address(0)`, `address(this)`, and `_withdrawalQueue`.

The two comparisons are independent — a transfer that empties the sender and creates the receiver is +1/−1, net zero, and is not blocked by a full cap. Order matters only for the cap test, which is evaluated on the GAIN alone: **the cap check is `if (gains && _maxHolders != 0 && _holderCount >= _maxHolders) revert MaxHoldersExceeded();`**, deliberately not netted against a simultaneous departure, because netting would make a transfer's admissibility depend on the sender's exact balance in a way that is invisible to the sender and unpleasant to reason about. A full club can still churn: an outgoing holder's slot is freed by their transaction and the next joiner takes it in theirs.

**Escrow does not change beneficial ownership, but it does move the count.** An LP who escrows their entire balance into the queue goes to zero and the counter decrements; on `cancel` the shares come back and the counter increments again. Tracking "escrowed-on-behalf-of" to hold the slot open was rejected — it needs a per-holder escrow tally, i.e. an unbounded second ledger duplicating the queue's own. The consequence is handled instead in D8 (the return path is cap-exempt) and D9 (the template's headroom).

**Mints are counted and capped.** `_deposit` and `settleDeposit` both create holders, and a cap that only bound transfers would be trivially bypassed by depositing to a fresh whitelisted address. Burns decrement.

## D7 — `maxHolders != 0` requires whitelist mode

A holder cap on an OPEN-deposit vault is a griefing primitive: anyone can `deposit` 1 wei to each of `maxHolders` fresh addresses and permanently lock out every real depositor for the price of gas. The cap's whole purpose is an ICA §3(c)(1) argument that only makes sense for a permissioned fund anyway.

Therefore both setters enforce the pair:

- `setMaxHolders(n)` with `n != 0` SHALL revert `HolderCapRequiresWhitelist` when `_openDeposits == true`.
- `setOpenDeposits(true)` SHALL revert `HolderCapRequiresWhitelist` when `_maxHolders != 0`.
- Creation config validates the same pair before any side effect.

With whitelist mode on, a dust-split attack reduces to "an approved member splits their position across several addresses the owner also approved" — the owner's own whitelist is the bound, and the attack is indistinguishable from the owner adding members, which they are entitled to do. Recorded as the answer to the dust/split question rather than an unanswered residual.

**Rejected alternative — cap enforced in both modes with a minimum-balance floor for counting** (dust below a threshold does not count as a holder). Rejected: a balance floor is a second economic parameter with its own denomination and rounding problems, it changes the count retroactively as the share price moves, and "beneficial owner" in the statute is not a size test.

## D8 — Queue round trips are exempt from the cap as well as from the gate

`from == _withdrawalQueue` is exempt from the cap check, not only from the whitelist gate. A returning escrow is a holder the vault already counted before they queued; refusing the return because the club filled up in the meantime would strand shares that have no other exit — post-stamp redeem cancel is already forbidden (`src/queue/VaultWithdrawalQueue.sol:425-426`), so an LP whose cancel reverted and whose claim also reverted would be trapped with no path at all.

The accepted residual: **the count can transiently exceed `maxHolders`**, bounded above by the number of live redeem requests whose owners emptied their balance and whose slots were taken by joiners before they cancelled. It self-heals on the next claim (burn → decrement) or on any exit. D9 explains why the template's 99 is the buffer for it.

The deposit side needs no equivalent exemption, and that asymmetry is deliberate: `settleDeposit`'s mint IS cap-checked, and an LP blocked there is not trapped, because **deposit cancel is unconditional** — `priceFixed` is computed only for `RequestKind.Redeem` (`src/queue/VaultWithdrawalQueue.sol:425-426`), so a deposit request can always be cancelled and the assets recovered even after the pid is stamped. That escape hatch is what makes capping the deposit claim safe; if it ever changes, this decision must be revisited.

## D9 — 99, not 100

ICA §3(c)(1) is "fewer than 100 beneficial owners", i.e. 99 is the legal maximum, not 100. Setting the template to 99 is therefore correct on its face — and it also absorbs D8's transient overshoot and D4's flip slack without ever touching the statutory line. The parameter is not hardcoded to 99: `maxHolders` is a free `uint` (0 = uncapped) and the club preset is the thing that says 99.

## D10 — The club template is a documented parameter bundle, not contract code (owner decision, do not re-litigate)

**Owner decision (2026-08-31): minimal protocol surface.** After features 1–3, every element of the club posture is an existing parameter:

| Club property | Parameter | Where it already lives |
|---|---|---|
| Permissioned register | `openDeposits = false` | `src/SyndicateVault.sol:173`, seeded at creation `src/SyndicateFactory.sol:369` |
| < 100 beneficial owners | `maxHolders = 99` | new, this change (features 1–2) |
| A vote before every buy | `approvalMode = Affirmative` + `approvalQuorumBps` | new, this change (feature 3) |
| Management fee only | `agentFeeBps = 0` | **already owner-settable**, `src/SyndicateVault.sol:1427-1433`; explicit-zero encoding `:201-207` |

So "club template" needs exactly one protocol capability that does not already exist: the ability to seat those values **at creation**, atomically, rather than in follow-up transactions that could be forgotten or front-run. That is three added fields on two existing structs (`SyndicateConfig`, `src/SyndicateFactory.sol:79-86`; `ISyndicateVault.InitParams`, `src/interfaces/ISyndicateVault.sol:127-136`) plus a governor-init overlay — and nothing else.

**Rejected alternative A — a `VaultTemplate` registry** in the manner of `StrategyFactory`'s `approvedTemplate` (`src/StrategyFactory.sol:53-58`, `:81-83`). Rejected: strategy templates exist because a strategy is a *contract* to clone; a vault preset is a *tuple of numbers*. A registry would add an owner-controlled indirection between a creator's intent and the parameters actually seated, plus a new upgrade surface, to store four constants.

**Rejected alternative B — a `preset: enum { Standard, Club }` field on `SyndicateConfig`** that expands to the four values in-contract. Rejected: it hardcodes 99 and a quorum into bytecode behind a beacon/proxy, so tuning the club default becomes an upgrade; and it creates two ways to reach the same state, one of which silently overrides explicit fields. The CLI can offer `--club` and expand it client-side, where changing the default is a release, not an upgrade.

**Consequence to record for tooling:** the management fee is NOT part of the bundle in any settable sense — there is no per-vault management-fee setter (`src/SyndicateVault.sol:181`, `:547`; the only setter is the factory-global `setManagementFeeBps`, `src/SyndicateFactory.sol:590-595`, affecting future vaults only). "Management-fee-only" for a club vault means `agentFeeBps = 0` on top of whatever the factory global was at creation. The CLI must show the inherited figure at creation time rather than implying it is choosable.

## D11 — Where the gate's code lives: OPEN QUESTION FOR REVIEW, with a measured recommendation

The brief for this change assumed `SyndicateVault` is against the EIP-170 ceiling and that gating logic might have to live in the delegatecalled `SyndicateVaultAdminLib`. **The measurement says otherwise, and the assumption in the repo's own comments is stale.**

Measured on main @ `a5399c7` (`forge build --skip test --skip script --sizes`):

| Contract | Runtime bytes | vs 98,304 (Robinhood, enforced) | vs 24,576 (EIP-170) |
|---|---|---|---|
| `SyndicateVault` | 32,971 | **65,333 free** | **8,395 OVER** |
| `SyndicateGovernor` | 44,134 | 54,170 free | 19,558 over |
| `SyndicateFactory` | 24,538 | 73,766 free | 38 free |
| `SyndicateVaultAdminLib` | 2,390 | — | — |

Two facts follow. First, there is no size pressure on the deployment target: CI's gate is 98,304 (`.github/workflows/ci.yml:225`, named "Contract size (Robinhood 96 KiB limit)"; the chain constant is spec'd at `openspec/specs/deployment-docs/spec.md:21` and `openspec/config.yaml:21-22`). Second, the vault is already 8 KB past EIP-170, so the framing in `README.md:18` ("extracted... to free EIP-170 runtime headroom"), in `src/SyndicateVaultAdminLib.sol:10-11`, and in the vault's own `minHoldingPeriod` / `lastDepositAt` comments (`src/SyndicateVault.sol:215-217`, `:222-224`) describes a constraint that no longer binds any deployable target. The archived note that "the vault sits at the EIP-170 ceiling" (`openspec/changes/archive/2026-07-19-instant-withdrawal-liquidity/tasks.md:41`) is from a much smaller vault.

**Recommendation: the hot-path gate stays INLINE in `_update`; only the cold-path `maxHolders` admin body may go to `SyndicateVaultAdminLib`.** Reasons: a `delegatecall` on every ERC-20 transfer is a per-transfer gas cost paid by every LP forever; the vault re-verifies `_expectedExecutorCodehash` on delegatecall paths for good reason (`:186-189`) and adding a second codehash-sensitive hot path widens that surface; and `SyndicateVaultAdminLib` performs no access control by design (`src/SyndicateVaultAdminLib.sol:19-25`), which is fine for owner-gated wrappers and wrong for a guard that IS the access control.

**What review must decide:** (a) whether to accept the inline placement given the measurement, and (b) whether the stale EIP-170 language in README and vault natspec should be corrected by this change or by a separate docs pass. This change does not assume an answer to (b).

Note for whichever way (a) goes: `echidna.yaml:20-21` links AND deploys `SyndicateVaultAdminLib` (`cryticArgs` / `deployContracts`, rationale `:10-19`). Moving logic into the library keeps that linkage valid only if the harness is updated in the same commit.

## D12 — Affirmative mode inside the single resolver

`_computeState`'s `Pending` branch (`src/ProposalLifecycle.sol:77-110`) today reads:

1. `block.timestamp <= p.voteEnd` → `(Pending, false)`.
2. Compute `liveSupply = getPastTotalSupply(snapshot) - getPastVotes(queue, snapshot)`, floored at 0 (`:86-99`).
3. `if (liveSupply > 0)` → `if (votesAgainst >= liveSupply * p.vetoThresholdBps / 10_000) return (Rejected, false);`
4. Fall through to `_afterVote(p)`.

Affirmative mode changes step 3 and nothing else:

- Step 2 is **shared verbatim**. The queue-netting rationale at `:87-96` — escrowed shares are checkpointed but never vote, so leaving them in the denominator lets a whale make a threshold arithmetically unreachable — applies identically and more sharply to a FOR quorum, where an unreachable bar means nothing ever passes.
- Step 3 becomes: if the proposal's snapshotted mode is `Affirmative`, `if (p.votesFor < liveSupply * p.approvalQuorumBps / 10_000) return (Rejected, false);` — and the veto inequality is **not** evaluated.
- `liveSupply == 0` inverts by mode: optimistic skips the check (a zero threshold would auto-reject everything, `:82-83`); affirmative returns `Rejected` (a zero supply can never reach any positive bar; passing would mean a proposal approved by a fund with no live shareholders).
- Step 4 is untouched. `_afterVote` (`:134-227`), guardian review, the registry economic commit, `executeBy`, and every later state behave identically.

The `(Rejected, false)` shape is what makes this cheap: `reviewConcluded == false` is already the veto-rejection contract (`:60-65`), so `_commitState` (`:239-281`) routes an affirmative rejection down the existing `_closeReviewIfRegistered` branch at `:272-280` — the registered guardian review is best-effort cancelled and no `resolveReview` economic commit fires. **No new branch in `_commitState`.**

**Rejected alternative — run both tests in affirmative mode** (must clear the FOR quorum AND not be vetoed). Rejected: two thresholds an owner must reason about jointly, with a dead zone where a proposal clears the quorum and is vetoed anyway, and no member-facing story for which number matters. The affirmative bar already subsumes the veto's job — organised opposition wins by not voting FOR.

**Rejected alternative — a third `Quorum` mode with quorum + simple majority of votes cast.** Rejected for v1 scope, not on merit: it needs a tie rule, an abstain rule (`votesAbstain` is tracked, `src/interfaces/ISyndicateGovernor.sol:91`), and a story for `votesFor == votesAgainst`. `approvalMode` is an enum precisely so this can be added later without another parameter.

## D13 — Bounds and snapshotting for the new governor params

`approvalQuorumBps ∈ [2_000, 6_700]`. The floor mirrors `MIN_VETO_THRESHOLD_BPS` (`src/GovernorParameters.sol:43`) — below 20% the "vote" is theatre. The ceiling is the substantive choice: above ~2/3, a single large holder's silence makes passage impossible and the club deadlocks itself into never trading, which is a worse outcome than a low bar. 6_700 is the smallest round number above two-thirds.

**Note a contradiction found while writing this.** The brief for this change described `vetoThresholdBps` as bounded 20–50%, and `openspec/specs/syndicate-governor/spec.md` ("Governance parameter management", and its "Out-of-bounds value rejected" scenario) says `[2_000, 5_000]`. **The code says `MAX_VETO_THRESHOLD_BPS = 8000`** (`src/GovernorParameters.sol:44`, enforced at `:168` and `:341`, and `test/GovernorParameters.t.sol:145` asserts against the constant rather than a literal). The base spec is stale — the tightening commit is `c305701`. This change's `syndicate-governor` delta restates the requirement with `8_000` so the spec matches the code; that is a drive-by correction of documentation only, no code moves, and it is called out here so review can reject it separately from the rest if preferred.

Both new params snapshot onto the proposal at Draft→Pending alongside `vetoThresholdBps` (`src/SyndicateGovernor.sol:1353-1362` and the collaborative path `:1603-1610`). The reason is the one already recorded there — a mid-vote parameter change must not move the bar a voter was told about — and it is strictly more important for an affirmative bar, where raising the quorum mid-vote could retroactively fail a proposal that had already cleared.

`approvalQuorumBps` is validated on **every** write, including while the mode is `Optimistic` and the value is inert. Otherwise a flip to `Affirmative` could activate a value no bound ever saw. Same rule inside `_validateParamBounds` (`:163-192`) so `forceSetParams` / `initialize` cannot seat what a setter rejects — the existing comment at `:185-187` states exactly this principle for the collaboration params.

## D14 — Storage: appended, and two goldens to regenerate

Vault side: `_maxHolders` and `_holderCount` are new top-level state carved from the front of `uint256[19] private __gap` (`src/SyndicateVault.sol:525`), following the running decrement log at `:515-524`. They pack: a `uint32` cap and a `uint32` count share one slot with room to spare, and the file already has the packing precedent next door (`uint16 minBufferBps` / `uint32 minHoldingPeriod`, `:211-218`). A `uint32` cap is 4.29e9 holders — not a real bound.

Governor side: `approvalMode` (`uint8`) and `approvalQuorumBps` (`uint256`, or `uint16` if packed with the mode) are APPENDED as trailing `StrategyProposal` members, below the `── APPENDED FIELDS ONLY BELOW (beacon-upgraded governors; storage parity) ──` divider (`src/interfaces/ISyndicateGovernor.sol:111`); `GovernorParams` gains the live params. The struct's own comment (`:105-108`) makes append-only a standing rule regardless of deployment state.

Both goldens are CI-gated (`script/check-layout-goldens.sh:271-297`; the vault was added by `pin-vault-storage-layout` and is live in the script today) with forge twins `test/VaultLayoutPins.t.sol` and `test/governor/GovernorLayoutPins.t.sol`. Regeneration is `./script/check-layout-goldens.sh --update-golden`, never by hand — the checker canonicalizes (strips AST ids, prunes non-struct types, re-indents), so pasted `forge inspect` output will never diff clean. **The diff is reviewed as its own task**: the only legal changes are new trailing entries and, for the vault, `__gap`'s array length shrinking. Any moved label, slot, offset or type is a bug in this change, not a golden to update.

## Alternatives considered (whole-change level)

- **A transfer-restricted wrapper token** (shares stay free; a separate wrapper holds the compliance). Rejected: two tokens, two vote-weight surfaces, and the governor reads `IVotes` off the vault itself (`src/ProposalLifecycle.sol:86`, `src/SyndicateGovernor.sol:715`) — a wrapper either forfeits voting or duplicates checkpointing.
- **ERC-1404 / ERC-3643 style `detectTransferRestriction` + `messageForTransferRestriction`.** Rejected for v1: it is an integrator-facing convenience over the same underlying revert, and it adds two external views and a message table to a contract whose gate is a one-line set membership test. Worth revisiting if a venue ever asks for it; the revert-based gate is forward-compatible with adding the views later.
- **Enforcing the cap off-chain** (owner curates the whitelist to ≤99 entries). Rejected: the whitelist is an eligibility list, not a holder list — approved members who never deposit occupy list slots but not ownership slots, and one member splitting across three of their own approved addresses is three beneficial owners against one list entry. The count has to be of nonzero balances.
- **Making the whole thing a new capability spec** (`club-vaults`). Rejected per `openspec/config.yaml`'s rule to name capabilities with existing kebab-case folders: every requirement here modifies or extends behavior already specced under `syndicate-vault` and `syndicate-governor`.

## Sequencing and re-verification ledger

Order: **vault side (features 1+2) → governor side (feature 3) → factory/CLI (feature 4).** Governor side may run in parallel with the vault side but MUST rebase onto whichever `StrategyProposal` appenders land first.

| Assumption | Source | Re-verify before implementing |
|---|---|---|
| `_update` (`src/SyndicateVault.sol:1445-1491`) still has no transfer restriction and is still the sole chokepoint | this worktree, main @ `a5399c7` | `git log -L :_update:src/SyndicateVault.sol` since `a5399c7`; re-grep for `transfer`/`transferFrom` overrides |
| `requestRedeem` escrows via `_transfer` (`:2306`) and `cancel` returns via `safeTransfer` (`src/queue/VaultWithdrawalQueue.sol:434`) | this worktree | Re-read both; if either path changes to a burn/mint pair, D2's exemption table shrinks and D8 changes |
| Deposit-side `cancel` is unconditional (`src/queue/VaultWithdrawalQueue.sol:425-426`) | this worktree | Load-bearing for D8's escape hatch. If a deposit cancel ever becomes stamp-gated, `settleDeposit` must be cap-exempted too |
| `StrategyProposal` append point is `src/interfaces/ISyndicateGovernor.sol:111`+ | this worktree | `per-call-capital-declarations` and `proportional-quorum-sizing` both append here; rebase onto the landed order and regenerate `script/syndicate-governor-layout.golden.json` LAST |
| `script/syndicate-vault-layout.golden.json` is live in `check-layout-goldens.sh` (`:297`) | this worktree | `pin-vault-storage-layout`'s change dir is still unarchived under `openspec/changes/` although its artifacts are on main — confirm no second baseline is in flight before regenerating |
| Vault runtime 32,971 B; CI limit 98,304 (`.github/workflows/ci.yml:225`) | measured this worktree, 2026-08-31 | Re-measure after implementation; the decision in D11 is a measurement, not a belief |
| `agentFeeBps` owner-settable with explicit-zero encoding (`src/SyndicateVault.sol:1427-1433`) | this worktree | If `remove-self-managed-fees` or any fee change lands first, re-read before writing the CLI bundle |
| `vetoThresholdBps` max is 8_000 in code vs 5_000 in the base spec | `src/GovernorParameters.sol:44` vs `openspec/specs/syndicate-governor/spec.md` | D13's drive-by spec correction — confirm no in-flight change is re-tightening the constant to 5_000, in which case drop the correction |
