# Proposal: Record the veto electorate at propose

## Why

The veto bar is a fraction of "the electorate", and the governor reconstructs
that number at resolve from two different instants:

```solidity
min( getPastTotalSupply(snapshot) − queueVotes(snapshot),  totalSupply() )
```

`totalSupply()` says shares were burned; it does not say whether the burn was a
voter redeeming or a queued redemption settling. Those two need opposite
corrections, so any combination of the historical read and the live read is
exact for one shape and wrong for the other — the PR #310 review reached both
halves of that impossibility in `411f9c5f` and `c09842f0`.

The reachable consequence is an inflated bar, i.e. a weakened veto. With shares
parked in the withdrawal queue and a redeem ordered ahead of `propose` in the
same block: LP1 45k, LP3 55k, 100k parked, attacker 200k redeemed first. The
snapshot still holds 400k, live supply is 200k, the `min` takes 200k and the bar
lands at 80k — but only 100k of shares can actually vote. 45k Against, 45% of
the real electorate, misses the inflated bar and the proposal passes. The veto
is the LPs' only control over a bad proposal, so the attacker buys that control
off for the price of ordering one transaction ahead of the propose.

## What Changes

The electorate stops being reconstructed and starts being recorded, once, at the
Draft → Pending transition where the proposal's other bar (`vetoThresholdBps`)
is already snapshotted:

```solidity
p.votableSupply = totalSupply() − vault.balanceOf(queue)
```

Both terms live at that instant, so a same-block redeem ordered ahead of the
call is already reflected in `totalSupply()`, and shares sitting in the queue —
which cannot vote — are subtracted directly rather than inferred from a
historical vote balance. `_computeState` reads the stored figure and the `min`
is deleted. `SyndicateVault.redemptionsLocked` freezes supply for the rest of
the proposal's life, so the recorded number stays true until resolve.

The queue term is read LIVE at propose rather than at the snapshot: shares
queued between `snapshot` and `propose` are in the queue when the electorate is
recorded, and a share in the queue cannot vote whenever it arrived.

## Impact

- `ISyndicateGovernor.StrategyProposal` gains `votableSupply`, appended. Governor
  storage is fresh lineage after V2, so the slot is free; the golden is
  regenerated in this change (append-only, one entry at struct slot 26).
- `ProposalLifecycle` no longer reads `getPastTotalSupply`, `getPastVotes` or
  `totalSupply()` at resolve — the veto bar costs one SLOAD instead of four
  cross-contract calls.
- Residual, NOT closed here: vote weight is still read at `snapshot`
  (`propose − 1`), so a holder who redeems ahead of `propose` in the same block
  keeps weight the electorate no longer counts. Closing it means reading weight
  at the propose instant, which reopens the same-block flash-delegate window the
  `− 1` exists to close. That trade needs a decision; see `design.md`.
