# Proposal: a Draft keeps both LP-flow locks; delegation stays with the holder

## Why

`SyndicateVault.redemptionsLocked()` is `openProposalCount() != 0` — true from Draft
creation to settle — and `depositsLocked()` is `return redemptionsLocked();`.

#320 (SHE-287) first split them: deposits locked only at execute, on the argument
that the electorate recorded at the Draft → Pending stamp (`veto-votable-supply`)
made a Draft-window deposit a fair trade (Sherlock run #1 finding #8, accepted as
"capital at risk buys the vote"). The #362 review (v1-deploy merged into
`post-audit-v2`) rejected that split, and the founder chose v1-deploy's lock
(option b):

- **Risk-free veto (L1).** A Draft-window deposit votes Against; if the veto lands,
  the proposal is rejected and the lock releases at once, so the outsider's capital
  was never at risk.
- **Same-second re-deposit.** With Pending deposits open, a redeem ahead of `propose`
  plus a re-deposit after it in the same second cast 2x the electorate against v1's
  live clamp. `veto-votable-supply`'s checkpoint formula closes it independently;
  the lock closes it too.
- **Shipped selector (L2).** The split replaced `NoOpenProposal` on `requestDeposit`
  with `DepositsNotLocked`, silently changing an error already on mainnet.
- **Audited code = mainnet code.** v1-deploy ships the joint lock; keeping it makes
  the vault's LP-flow gates identical on both branches.

## What Changes

| window | instant deposit | instant redeem | queue |
|---|---|---|---|
| no proposal | open | open | closed |
| Draft → settle | closed | closed | both lanes |

- `redemptionsLocked()` and `depositsLocked()` stay one predicate,
  `openProposalCount() != 0` (Draft included). `requestDeposit` keeps v1-deploy's
  gate and error (`NoOpenProposal`); the request is tagged with the executing pid,
  else the latest.
- The collaborative stamp (`approveCollaboration`) reads `votableSupply` at
  `snapshotTimestamp` — `getPastTotalSupply(t − 1) − getPastVotes(queue, t − 1)` —
  instead of live. The redeem lane is open for the whole Draft and the final
  approve's readiness is public, so a live queue term could be shrunk by a
  same-block `requestRedeem` whose owner keeps `t − 1` weight (`veto-votable-supply`
  Decision 3). Both terms at `t − 1` see one set. The direct path reads the same
  instant; an exit ahead of `propose` in its second is caught when `vote` lowers the
  electorate to the read at `t` (a845b781).
- `delegate`/`delegateBySig` to anyone but the holder revert `DelegationDisabled`
  (`SyndicateVault._delegate`). Without it the two `t − 1` terms are not one set: a
  holder that undelegates (`delegate(address(0))`) a block before the stamp stays in
  `getPastTotalSupply` and votes for nobody, inflating the bar to `b·(G + X)` with
  only `G` castable; `delegate(queue)` on the direct path removes live shares from the
  denominator. No product flow delegates to a third party — the vault self-delegates
  every receipt — so nothing is lost.

Both locks start at **Draft creation**, not at Pending. Two rounds of #320
review showed why: with instant redeem open in Draft while the collaborative stamp
lands later, an exit on either side of the read instant is mispriced — a live read
lets `{redeem, approveCollaboration}` vote full weight against a bar shrunk by its own
exit; a `t − 1` read lets a Draft-window deposit `X` exit in the approve block and
leave a bar of `0.4 (G + X)` that only `G` can reach. Holding the lock through the
Draft is the only shape in which every share in the recorded electorate is capital at
risk for the cycle. What is lost is instant redeem during the collaboration window
(≤ 24 h, collaborative proposals only); against #320, instant deposit from Draft to
execute, where LPs use `requestDeposit` as on v1-deploy.

## Impact

- Closes `veto-votable-supply` design.md **Decision 3**: the collaborative-window
  attack (front-run the final `approveCollaboration` with `requestRedeem`, so shares
  leave the live electorate while their holder keeps snapshot weight) is priced out —
  the collaborative stamp reads both terms at `snapshotTimestamp`, so the same-block
  queue move is inside the recorded set. The shares stay locked either way.
- Accepted and unchanged: Decision 2 (phantom weight inside the stamping block
  itself). Sherlock run #1 finding #8 (Draft-window deposit buys weight) stays closed
  by the deposit lock.
- No storage change; `IProposalStatus` unchanged in shape; `requestDeposit`'s
  error selector unchanged from v1-deploy.
