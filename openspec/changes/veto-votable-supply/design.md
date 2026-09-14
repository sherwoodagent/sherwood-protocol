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

A `requestRedeem` between `snapshot` and the stamp moves shares into the queue.
Read at the snapshot they are still "votable"; read live they are not. Live
wins: the queue is not an address that votes, so its balance at the moment the
electorate is fixed is the honest exclusion.

**On the direct `propose` path the two reads cannot disagree.** `requestRedeem`
requires `redemptionsLocked()`, i.e. `openProposalCount != 0`, and `propose`
requires `openProposalCount == 0` plus an elapsed cooldown. No transaction can
move shares into the queue between `snapshot` and the stamp, so no test in
`Governor_vetoDenominatorExits.t.sol` distinguishes the two reads — and none
claims to. `test_queuedSharesAreOutsideTheVetoElectorate` pins the exclusion
itself; what a snapshot read would break is the pair of
`queuedSharesClaimedInTheProposeBlock…` tests, which is the double-subtraction
this change exists to remove.

**On the collaborative path they can disagree**, because a Draft already holds
the lock open. That is the subject of Decision 3.

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

## Decision 3: the collaborative path stamps a window after the lock — RESOLVED in `draft-locks-nothing`

On the direct path the lock, the stamp and the snapshot are one transaction. On
the collaborative path they are not: `redemptionsLocked()` is armed at Draft
creation (so a deposit cannot inflate the Pending snapshot), while
`votableSupply` and `snapshotTimestamp` are stamped later, at the final
`approveCollaboration`. `requestRedeem` is open for the whole collaboration
window.

So an LP can front-run the final `approveCollaboration` in the same block with
`requestRedeem(shares)`: the shares move to the queue in block *t* and leave the
electorate (live queue term), while the LP's weight at *t − 1* still includes
them — and the request is cancellable afterwards, since it is tagged to the
Draft pid and nothing has stamped it. The LP then votes full weight against a
bar cut by its own stake. With `b = vetoThresholdBps` the effective bar falls
from `b` to `b / (10_000 + b)`: 30% becomes 23%, repeatable for gas.

Direction: the veto gets EASIER, not harder — a griefing vector against
collaborative proposals, not a fund path. The pre-change code did not have this
particular hole (its `getPastVotes(queue, snapshot)` term could not see a
same-block queue transfer); it had the two the proposal documents instead.

Two honest shapes. Neither is "read the queue term at the snapshot", which
re-opens the double subtraction the claim-in-propose-block tests pin:

- **(a) Stamp the collaborative path at Draft creation** — the block that arms
  the lock — taking `snapshotTimestamp` there too. From that instant supply is
  frozen and queue moves cannot change anyone's weight at `draft − 1`, so the
  electorate and castable weight coincide. The direct path is untouched. Cost:
  the vote snapshot for collaborative proposals moves earlier by the whole
  collaboration window. `snapshotTimestamp`'s only consumers are `vote()`'s
  weight read, the `getVotingPower` view and its `ProposalInDraft` guard, plus
  two tests that pin it to the Pending instant on purpose
  (`CollaborativeProposals.t.sol:363,378`) — so the change is mechanical but the
  semantics ("weight as of when collaboration opened") is a product decision.
- **(b) Accept it as bounded** — easier veto, collaborative path only, requires
  an open Draft — and pin the current number with a test so a later change is
  deliberate.

Not decided in this change. Same family as Decision 2: both are the cost of the
vote-weight instant and the electorate instant being different, and both should
be settled together rather than one at a time.

**Resolution (`draft-locks-nothing`, SHE-287).** Neither (a) nor (b). A Draft no
longer holds the redeem lock, so the queue is closed for the whole collaboration
window and the `requestRedeem` front-run is unreachable. That reopened the same
window through instant redeem — `{redeem, approveCollaboration}` in one block
left the holder in the `t − 1` weight and out of the live supply — so the
collaborative stamp reads the electorate at `snapshotTimestamp`:
`getPastTotalSupply(t − 1) − getPastVotes(queue, t − 1)`. Numerator and
denominator see the same set; the residual is Decision 2's class (a same-block
exit keeps its weight, the bar stays consistent). The direct path keeps its live
read: instant redeem is open right up to `propose`, and a `t − 1` read there
would count shares that already left (NM 6.4's inflated bar). The double
subtraction the claim-in-propose-block tests pin does not arise on the
collaborative path, because nothing can claim from the queue between `t − 1` and
the stamp without also leaving `getPastVotes(queue, t − 1)` — both terms are
read at the same instant.
