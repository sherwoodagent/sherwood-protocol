# Design: SHE-470 Low findings

One decision per item, with the alternative from the ticket that was not taken.

## Code

**L-1 buffer (SHE-479).** The floor is charged on the deployable float only:
`reserve + (balanceBefore − reserve) × bps / 10_000` (saturating at zero when the reserve exceeds the
pre-batch balance). Batches with `maxNetOutflow == 0` skip it. With the net formula a zero-budget batch
can never breach (its `balanceAfter ≥ balanceBefore`, and the reserve check already runs), so the skip
is defence in depth and has no observable mutant; the formula change is what un-wedges a settle after
an owner raise. Rejected: gating `setMinBufferBps` on an open proposal (not needed once settle cannot
be wedged); dropping the knob. Applies only to vaults deployed from the v2 vault impl; live 4663 vaults keep v1 behaviour.

**L-2 call value (SHE-480).** `CallValueNotAllowed(index)` in the vault guard and in the governor's
propose-time mirror, so a stored leg still cannot pass propose and revert at settle. The vault has no
ETH accounting and no `receive`, so nothing legitimate needs value. Rejected: none in the ticket.
The vault check applies only to v2-impl vaults; on live 4663 vaults only the governor's propose-time
mirror applies, so emergency batches there still accept value at finalize.

**L-3 clone salt (SHE-481).** `keccak256(abi.encode(vault, msg.sender, salt))`. Since
`proposer == msg.sender` is already enforced, this binds the predicted address to the proposer. The SDK
predictor (`effectiveStrategySalt`) must fold the deployer the same way. Rejected: bundling clone and
propose into one call (a larger interface change for the same result). Applies only to a newly deployed
`StrategyFactory`; the live 4663 factory keeps the 2-arg salt, so the SDK change must not ship against it.

**L-5 same-owner rotation (SHE-483).** `rotateOwnership` drains agents only when `newOwner != owner()`.
A new owner still never inherits an at-cap set. Rejected: none. Applies only to vaults deployed from the v2 vault impl; live 4663 vaults keep v1 behaviour.

**L-8 moot emergency round (SHE-486).** `voteBlockEmergencySettle` refuses unless the governor reports
`Executed`. The SHE-471 `_governorInReview` probe is generalized into
`_governorReports(governor, id, expected)` and reused; a failed or short read keeps the window-only
check, as before. Block votes cast before a settle still count at resolve, which keeps the slash for a
round that was blocked while live. Rejected: `_finishSettlement` cancelling a sub-quorum round (a
governor-side call into the registry on every settle), and `cancelEmergencySettle` accepting `Settled`
when not blocked (owner still has to act; the vote gate removes the free burn without that).

**L-9 paused review past executeBy (SHE-487).** In the paused branch of `_afterVote`, return `Expired`
once `block.timestamp > executeBy`, like the sibling branches. Approver slashes are not lost: the
registry's `resolveReview` is permissionless after unpause. Rejected: none.

**L-10 inert re-arm (SHE-488).** `file` stores the baseline deadline
(`executedAt + strategyDuration + challengeWindow`) in `challengeableUntil` when it is higher than the
stored value; `_rearmChallengeWindow` returns before setting `_rearmed` when the extension does not
exceed it. No new storage. A later lowering of `challengeWindow` no longer shortens a deadline already
seeded by a filing; that is the direction that favours challengers. Rejected: computing
`max(baseline, challengeableUntil)` inside `_rearmChallengeWindow` (an extra governor read on the fail
path).

## Accepted, documented

- **L-4 (SHE-482)** `propose` does not tie the clone's `proposer()` to `msg.sender`. `proposer()` is
  self-declared and guardians review it; after L-3 an agent can only propose another's clone knowingly,
  and only with `ownerOnlyProposals` off. Rejected: a propose-time `proposer() == msg.sender` probe.
- **L-6 (SHE-484)** The `requestDeposit` receiver is the ERC-7540 controller; cancel refunds it.
  Rejected: recording a separate payer on the request.
- **L-7 (SHE-485)** A blocked round slashes only when resolved; settlement does not resolve it, so the
  owner's 7 d cooldown races the 24 h review. The guardian daemon resolves blocked rounds. The false
  `isEmergencyOpen` natspec is fixed. Rejected: `requestUnstakeOwner` refusing while a round is open,
  and `_finishSettlement` resolving past `reviewEnd`.
- **L-11 (SHE-489)** No identity exclusions on `voteOnProposal`: a second address defeats them, and a
  self-approver's lock stays slashable. Rejected: mirroring `voteOnChallenge`'s exclusions.
- **L-12 (SHE-490)** A donation during `Executed` is charged the performance fee. The misleading
  comment in `_chargePerformanceFee` is corrected. Rejected: measuring P&L from batch flows.
- **L-13 (SHE-491)** A conviction demotes `(target, selector)` protocol-wide until the Safe
  re-certifies. Demotion is per address: a convicted clone loses its tier alone and its siblings keep the
  class tier; a shared address-certified adapter is demoted for every vault. Rejected: a second signal
  for shared adapters.
- **L-14 (SHE-492)** A diverted or bondless correct filing earns no fee and still burns
  `settleBurnBps`; `honestFilingBreaksEven` is a policy indicator. Rejected: skipping the burn on the
  diverted branch, and a per-key bond read in the view.
