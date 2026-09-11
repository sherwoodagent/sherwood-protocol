# Design: veto electorate recorded at propose

## Why a `min` of two instants cannot be exact

The two burn kinds are indistinguishable from `totalSupply()` alone:

| burn | should the electorate shrink? | what the old reads saw |
|---|---|---|
| a voter redeems ahead of propose, same block | yes — those shares cannot vote | in the snapshot, gone from live supply |
| a queued redemption is claimed | no — already subtracted via the queue term | gone from live supply, still in the queue's snapshot votes |

Subtract on the live read and the second case double-counts (the bar halves, or
collapses to zero); don't subtract and the first case inflates. `min` picks one
victim. Both were reachable — the four `queuedSharesClaimedInTheProposeBlock…`
and `sameBlockPreProposeRedeem…` tests in
`test/audit-fixes/Governor_vetoDenominatorExits.t.sol` pin the shapes that drove
the earlier attempts.

Recording the number at propose removes the reconstruction entirely: at that
instant both facts are directly observable, and neither has to be inferred from
the other.

## Decision 1: the queue term is read live at propose, not at the snapshot

A `requestRedeem` between `snapshot` and `propose` moves shares into the queue.
Read at the snapshot they are still "votable"; read live they are not.

Live wins: the queue is not an address that votes, so its balance at the moment
the electorate is fixed is the honest exclusion. The existing test
`test_queuedRedeemAfterTheSnapshotDoesNotShrinkTheVetoBar` is unaffected — its
`requestRedeem` lands after `propose`, where supply is already frozen.

The cost is bounded and is the mirror of the residual below: a holder who queues
in that same-block window keeps snapshot weight against an electorate that no
longer counts them. The shrink equals the shares they queued and their weight
equals those same shares, so it does not hand them a bar they could not already
clear.

## Decision 2: the phantom-weight residual is NOT closed here

`vote()` reads `getPastVotes(voter, snapshotTimestamp)` with
`snapshotTimestamp = block.timestamp − 1`. The `− 1` is deliberate: it closes
the window where a delegation made in the propose block itself would count.

Closing phantom weight means reading vote weight at the same instant as the
electorate — the propose block — which re-opens exactly that window, and makes
`getPastVotes` revert for anyone voting in the propose block (`clock()` is not
in the past yet). So the two leaks trade against each other and the choice is a
security decision, not a refactor:

- keep `− 1` (this change): a same-block pre-propose redeemer can still cast
  weight the electorate excludes — a cheaper veto, bounded by their own
  redeemed size.
- move to the propose instant: phantom weight closes, flash-delegation in the
  propose block opens.

Recorded here so the next reader does not "fix" one by silently reopening the
other. The exact fix is a third option — a weight read and an electorate read
that share a recorded timepoint chosen to be after every same-block burn AND
after every same-block delegation — which needs the vault's checkpoint surface
to expose it.
