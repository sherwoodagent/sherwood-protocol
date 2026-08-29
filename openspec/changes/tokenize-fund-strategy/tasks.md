# Tasks — tokenize-fund-strategy

Spec-first change: tasks below are the implementation plan and are all unchecked. Tasks 0.x are verification work that can invalidate parts of the design and SHOULD land (as review comments or design.md amendments) before contract code starts.

## 0. Pre-implementation verification (answers feed back into design.md)

- [ ] 0.1 StonkBrokers never-graduates path: on a 4663 fork, run a Smart Launch through a closed window below `gradMcapUsd8` with buys present, and record what `closing` permits — can the creator recover arm'd supply or realized quote, or is the launch permanently stranded? Resolves design Open Question 3 and fixes the `LaunchPhase.Failed` semantics.
- [ ] 0.2 Confirm Sushi `launchAndBuy` accounting end-to-end on a 4663 fork (WETH quote): launch fee in native ETH, dev-buy output vs `minTokensOut`, `transferCreator` in the same tx, `distributeFees` paying the new creator.
- [ ] 0.3 Confirm the Smart Launch V3 (BYO) pads accept an external token minted by an arbitrary contract, and whether V2-vs-V3 pad choice changes anything besides token provenance (doc says same ABI; verify `createLaunch(token != 0)` is rejected on V2 pads or merely conventional).
- [ ] 0.4 Open the WOOD-quote conversation with the Sushi owner (business task, SHE-153 Open Question 1); until resolved the Sushi fork tests use WETH quote.
- [ ] 0.5 Decide the default reserve fraction (below the now-fixed `MAX_RESERVE_BPS = 2_000` ceiling) and the Stonk start/grad mcap and tax-schedule defaults — product input, recorded in design.md when settled.
- [ ] 0.6 File and track the vault-side finding this review surfaced: a strategy that truthfully clears residue and later truthfully reports it again can be re-marked by permissionless `collectResidue`, re-stamping a fresh `UNVALUED_MAX_LOCK` deposit lock indefinitely — `_unvaluedBurned` guards only the post-prune direction (`SyndicateVault.sol:1988`, `:2011-2013`, `:2023-2024`). Protocol-level hardening candidate; out of scope for this change, which routes around it by latching the template's views.

## 1. Vendored venue interfaces

- [x] 1.1 `src/vendor/sushi/ISushiLaunchpad.sol` — reduced surface: `launch`, `launchAndBuy`, `distributeFees`, `transferCreator`, `launchInfo`, `quoteTokenPriceFeed`, `launchFee`, `WETH`; provenance natspec header (verified source, address, chain).
- [x] 1.2 `src/vendor/stonkbrokers/IStonkSafeLaunchpadV2.sol` — `createLaunch`, `arm`, `abort`, `buy`, `sell`, `graduate`, `bond`, `flushCreatorQuote`, `getLaunch`, `modesOf`, `launchIdOfToken`, `quote`, `launchFeeWei`; and `ISafeLaunchLensV2.sol` — `quoteBuy`, `quoteSell`, `priceWei`, `viewLaunch`; provenance headers.
- [x] 1.3 `forge build` clean; no manifest entries (in-file provenance is the repo convention for reduced-surface vendors).

## 2. ILaunchAdapter + SushiLaunchAdapter

- [x] 2.1 `src/interfaces/ILaunchAdapter.sol` per design Decision 1, natspec carrying the custody invariant verbatim.
- [x] 2.2 `SushiLaunchAdapter` singleton: pull quote, unwrap launch-fee ETH from quote WETH, `launchAndBuy(recipient = msg.sender)`, `transferCreator(token, msg.sender)`, zero-balance/zero-role postcondition asserted in tests.
- [x] 2.3 `quoteSupported` mirrors `quoteTokenPriceFeed != 0`; `phase`/ref validity derived from `launchInfo(token)` only — zero adapter storage — returning `Live` for issued launches and `None` otherwise; `finalize` no-op; `collectFees` wraps `distributeFees` and reports strategy-side deltas; `receive()` restricted to WETH withdrawals (assert a plain-value send reverts).
- [x] 2.4 Fork tests (4663): full launch with WETH quote; reserve floor enforcement; WOOD quote reverts pre-registration; fee distribution reaches the strategy; post-`transferCreator`-to-vault, `distributeFees` pays BOTH legs to the vault and nothing to the strategy.

## 3. StonkLaunchAdapter (implementation + per-launch clone)

- [x] 3.1 Implementation with `initialize(owner, pad)` clone-init lock (constructor locks the implementation, `BaseStrategy` precedent); constructor-set immutable lane → pad set with no setter (test: no reachable write path post-deploy); factory entry `launchWithClone` deploying the ERC-1167 clone inside `launch()`.
- [x] 3.2 Clone flow: `createLaunch` (clone = creator) with `venueData`-decoded economics, transfer `reserveAmount` to owner, `forceApprove` + `arm` remainder; never sets `eoaOnly`.
- [x] 3.3 Owner-only lifecycle verbs: `finalize` (graduate/bond by phase), `collectFees` (`flushCreatorQuote` → forward), `abort` passthrough while trade-free; `phase` derived from `getLaunch` flags per task 0.1's findings. Plus `forwardToVault()` — owner-only pre-settlement, permissionless after — flushing creator quote and sending every clone balance to the owner strategy's vault (never to the caller, never through the strategy).
- [x] 3.4 ERC-1167 target introspection helper so consumers can verify clone → allowed implementation.
- [x] 3.5 Fork tests (4663): fair-launch shape (zero `quoteIn`), reserve withheld before arm, curve dev-buy via pad `buy(recipient = strategy)`, graduation + bond driving, stock-lane `StalePrice` surfaced unchanged, foreign-caller reverts on every clone verb, and post-settlement `forwardToVault()` from a random caller landing both legs on the vault.

## 4. TokenizeFundStrategy template

- [x] 4.1 Skeleton on `BaseStrategy`, struct init decode, fail-closed init checks in spec order (including `reserveAmount ≤ launchSupply × MAX_RESERVE_BPS / 10_000` against Stonk `venueData` supply / Sushi `TOKEN_TOTAL_SUPPLY`, and `quoteIn ≤` proposal budget); `updateParams` monotonic — `minTokensOut` raise-only, lowering reverts; errors one-per-check with adversary natspec.
- [x] 4.2 `_execute`: pull → optional swap to quote (live adapter re-certs) → `launch` → custody assertion → snapshot `clock()` → cache `pid` from `getActiveProposal()` and compute `windowEnd = min(executedAt + configuredWindow, executedAt + strategyDuration − CLAIM_SETTLE_BUFFER)` from `getProposal(pid)` → push unspent; execute event with token, launchRef, reserve, snapshot, windowEnd. Unit tests for the truncation math at both branches of the `min`, at `configuredWindow` exactly on the boundary, and at `strategyDuration ≤ CLAIM_SETTLE_BUFFER` — which must revert with the template's named error (no panic, no saturating clamp) before any capital is deployed.
- [x] 4.3 `claim`/`claimFor`: pro-rata math on `getPastVotes/getPastTotalSupply`, once-per-holder, `windowEnd`-gated, rejected with the template's own error when `clock() == snap` (never bubbling OZ `ERC5805FutureLookup`); Σclaims ≤ reserve invariant test (fuzz + property).
- [x] 4.4 `_settle`: `windowEnd` gate that is revert-proof whenever `block.timestamp >= executedAt + strategyDuration`; Sushi `transferCreator(token, vault())` handoff; `collectFees`, quote→asset conversion, push; no fund-token sale into its own pool (test asserts no pool interaction in settle).
- [x] 4.5 Delivery views + `sweep()` per spec; balance-only sweep (assert zero venue calls) with per-token gas budgeting; latch tests armed from the settled-with-vault-asset-residue-only state (fund-token custody already below `RESIDUE_DUST`, no clearing sweep ever runs): a post-settlement fund-token donation leaves `hasUnvaluedResidue()` false and `collectResidue` unable to re-mark or re-stamp a lock, while `undeliveredValue()` still reports the real vault-asset custody after that latch has armed — the views are not latched together; deliverable-maximum path for non-`Live` phases; views never revert (property test), residue dust floor honored; fork-measured gas assertions — `sweep()` under `_SWEEP_GAS = 1_500_000` and each of the three views under `_PROBE_GAS = 150_000`, at the worst-case token count.
- [x] 4.6 Template conformance suite: init front-run lock, clone-ratchet binding, live `isAgent` re-check, `updateParams` bounds; extend the existing mock vault/governor/registry stand-ins with any new selectors in the same commit.
- [ ] 4.7 Fork test (4663): a claim window configured longer than the proposal's `strategyDuration` cannot wedge settlement — after `executedAt + strategyDuration` an arbitrary caller settles the proposal, `openProposalCount()` returns to 0, and vault deposits unlock.

## 5. Deploy + address book

- [x] 5.1 `DeployTokenizeFundStrategy.s.sol` with venue-identity asserts (not just code-presence), template approval, adapter allow + certification runbook, counterparty writes.
- [x] 5.2 `chains/4663.json` + `addresses/4663.json` entries with verification evidence; note 46630 skip.
- [ ] 5.3 Fork ceremony rehearsal on a 4663 fork; post-deploy validation reads extended.

## 6. Follow-ups (explicitly out of this change)

- [ ] 6.1 sherwood repo PR: CLI `strategy propose --template tokenize-fund` + docs walkthrough entry (after this spec settles).
- [ ] 6.2 v2 questions parked in SHE-153: burn-to-redeem variant, Uniswap/Bankr adapters. (Post-settlement fee-stream ownership is no longer open — review settled it on the vault; see design Decision 4.)
