# Proposal: a Draft locks nothing; redeem locks at Pending, deposit at execute

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
| Draft | **open** | **open** | closed |
| Pending → Approved | **open** | closed | redeem lane |
| Executed → settle | closed | closed | both lanes |

- `ProposalLifecycle` tracks `_draftCount` alongside `_openProposalCount` and exposes
  `lockedProposalCount() = open − drafts`.
- `redemptionsLocked()` reads `lockedProposalCount()`; `depositsLocked()` reads
  `getActiveProposal()` and stops being an alias.
- `requestRedeem` follows the redeem lock (unchanged predicate, new boundary);
  `requestDeposit` follows `depositsLocked()`, so exactly one deposit path is open in
  every state — it used to be gated on the open-proposal count, which after this
  change would have left both paths open from Draft to execute.
- The owner rescue paths keep reading `openProposalCount()`: the vault is bound by a
  Draft even though no LP flow is locked, and the owner must not siphon
  strategy-transit assets while any proposal is alive.

Redeem locks at **Pending**, not at execute, on purpose. Open until execute would let
a holder vote Against and leave during the voting window — the cost of a veto would
fall from capital committed for a cycle to capital present for one block, which is
the opposite of what this change is for.

## Impact

- Closes `veto-votable-supply` design.md **Decision 3**: the collaborative-window
  attack (front-run the final `approveCollaboration` with `requestRedeem`, so shares
  leave the electorate while their holder keeps snapshot weight) is unreachable —
  the queue only opens with the redeem lock, and a Draft does not hold it.
- Accepted and unchanged: Decision 2 (phantom weight inside the stamping block
  itself), and the Draft-window deposit buying weight (Sherlock run #1 finding #8,
  now a deliberate trade rather than a bug).
- Governor storage: `_draftCount` carved from `__lifecycleGap` (10 → 9), append-only
  in effect. Golden regenerated.
- `IProposalStatus` gains a fifth selector; the mock and every governor fake follow.
- An integrator reading `openProposalCount()` as "can I deposit" now reads the wrong
  thing — the seam docstring says which selector answers which question.
