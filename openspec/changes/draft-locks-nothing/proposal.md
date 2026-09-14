# Proposal: deposits lock at execute; a Draft keeps the redeem lock

## Why

`SyndicateVault.redemptionsLocked()` was `openProposalCount() != 0` — true from Draft
creation to settle — and `depositsLocked()` was literally `return
redemptionsLocked();`. One predicate, two locks, three reasons, only one of which
still holds.

The reason the code gives for the redeem lock (`SyndicateVault.sol:556`):

> no share is minted or burned while a proposal is open, **so the veto denominator
> cannot move**

`veto-votable-supply` (SHE-282) records the electorate at the Draft → Pending stamp.
The denominator cannot move afterwards no matter what mint and burn do, so the lock
is no longer what protects it.

The reason for the deposit lock at Draft, from `propose`:

> an unlocked Draft would let an attacker deposit between propose and the final
> approve, inflating the balance counted in the Pending snapshot

That vector is now a fair trade, and is accepted deliberately: a Draft-window deposit
buys vote weight with capital that is then locked until settle. Capital at risk is
the price of the vote.

What survives is the `depositsLocked` docstring's own reason:

> a proposal settles only when its strategy holds nothing, so no receivable is ever
> priced

That one is about pricing, and it holds for exactly one window: `execute` → `settle`.
Before execute the vault still holds everything and the NAV is knowable.

## What Changes

| window | instant deposit | instant redeem | queue |
|---|---|---|---|
| no proposal | open | open | closed |
| Draft → Approved | **open** | closed | redeem lane |
| Executed → settle | closed | closed | both lanes |

- `redemptionsLocked()` keeps reading `openProposalCount()` (Draft included).
  `depositsLocked()` reads `getActiveProposal()` and stops being an alias.
- `requestRedeem` is unchanged; `requestDeposit` follows `depositsLocked()`, so
  exactly one deposit path is open in every state — it used to be gated on the
  open-proposal count, which after this change would have left both paths open from
  Draft to execute.
- The collaborative stamp (`approveCollaboration`) reads `votableSupply` at
  `snapshotTimestamp` — `getPastTotalSupply(t − 1) − getPastVotes(queue, t − 1)` —
  instead of live. The redeem lane is open for the whole Draft and the final
  approve's readiness is public, so a live queue term could be shrunk by a
  same-block `requestRedeem` whose owner keeps `t − 1` weight (`veto-votable-supply`
  Decision 3). Both terms at `t − 1` see one set. The direct path keeps its live read:
  instant redeem is open right up to `propose`, and a `t − 1` read there would count
  shares that already left.

Redeem stays locked from **Draft creation**, not from Pending. Two rounds of #320
review showed why: with instant redeem open in Draft while the collaborative stamp
lands later, an exit on either side of the read instant is mispriced — a live read
lets `{redeem, approveCollaboration}` vote full weight against a bar shrunk by its own
exit; a `t − 1` read lets a Draft-window deposit `X` exit in the approve block and
leave a bar of `0.4 (G + X)` that only `G` can reach. Holding the lock through the
Draft is the only shape in which every share in the recorded electorate is capital at
risk for the cycle. What is lost is instant redeem during the collaboration window
(≤ 24 h, collaborative proposals only).

## Impact

- Closes `veto-votable-supply` design.md **Decision 3**: the collaborative-window
  attack (front-run the final `approveCollaboration` with `requestRedeem`, so shares
  leave the live electorate while their holder keeps snapshot weight) is priced out —
  the collaborative stamp reads both terms at `snapshotTimestamp`, so the same-block
  queue move is inside the recorded set. The shares stay locked either way.
- Accepted and unchanged: Decision 2 (phantom weight inside the stamping block
  itself), and the Draft-window deposit buying weight (Sherlock run #1 finding #8,
  now a deliberate trade rather than a bug).
- No storage change; `IProposalStatus` unchanged in shape.
- An integrator reading `openProposalCount()` as "can I deposit" now reads the wrong
  thing — the seam docstring says which selector answers which question.
