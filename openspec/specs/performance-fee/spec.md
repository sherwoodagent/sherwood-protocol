# Performance Fee Specification

## Purpose

Defines the performance fee and the high-water mark that bounds it, so that a fund is
charged profit-share only on gains that lift it above its previous peak and never twice
on the same recovered dollars.
## Requirements
### Requirement: The performance fee is charged only on value above the high-water mark

The fund SHALL store a high-water mark expressed as a price per share. The performance
fee base MUST be the lesser of (a) the amount by which the current price per share
exceeds that mark, multiplied by the vault's pricing supply (total supply less shares of
stamped-but-unclaimed queued redemptions), and (b) the proposal's positive realized
profit (its asset-balance gain over the execute-time snapshot, zero on a loss). When the
current price per share is at or below the mark, or the proposal made no profit, the
performance fee MUST be zero.

#### Scenario: A recovery to a previous peak is not charged again

- **WHEN** a fund rises from 100 to 120 and pays a performance fee, then falls to 95, then
  recovers to 120
- **THEN** the recovery settlement charges no performance fee, because the price per share
  did not exceed the stored mark

#### Scenario: Only the portion above the peak is charged

- **WHEN** a fund whose mark stands at 120 settles at a price per share of 130
- **THEN** the performance fee applies to the 120-to-130 portion only, not to the full
  gain since the last settlement

#### Scenario: A settlement below the mark charges nothing

- **WHEN** a proposal settles with a price per share below the stored high-water mark
- **THEN** no performance fee is charged, and the management fee is still charged

#### Scenario: Positive proposal profit below the mark is still not charged

- **WHEN** a proposal is individually profitable but the fund's price per share remains
  below its stored mark
- **THEN** no performance fee is charged — profit is measured against the mark, not
  against the proposal's own starting balance

### Requirement: The high-water mark ratchets upward only

At every settlement, after any performance fee, the mark SHALL advance to the post-fee
price per share when that is higher, whether or not a fee was charged. While shares
exist the mark MUST never decrease. When the pricing supply reaches zero (every share has
left) the mark SHALL reset, and it SHALL be re-seeded at the next deposit.

#### Scenario: The mark advances after a charged fee

- **WHEN** a settlement charges a performance fee at a post-fee price per share of 128
- **THEN** the stored mark becomes 128

#### Scenario: A loss does not lower the mark

- **WHEN** a settlement completes at a price per share below the stored mark
- **THEN** the stored mark is unchanged

#### Scenario: The mark is initialized at the fund's first deposit

- **WHEN** the first deposit into a vault occurs
- **THEN** the mark is initialized to the price per share at that moment, so the first
  proposal's gains above it are chargeable

### Requirement: The management fee is applied before the high-water-mark comparison

Because the management fee reduces assets and therefore the price per share, it SHALL be
charged first. The high-water-mark comparison and the performance fee MUST be computed
against the post-management-fee price per share, so that performance fee is never
charged on assets the management fee has already taken.

#### Scenario: Performance is computed on post-management-fee assets

- **WHEN** a proposal settles profitably with a nonzero management fee owed
- **THEN** the price per share used for the mark comparison is the one remaining after the
  management fee has been deducted

#### Scenario: The management fee can move a settlement below the mark

- **WHEN** a proposal's gross gain lifts the pre-fee price per share just above the mark
  but the management fee brings the post-fee price back to or below it
- **THEN** no performance fee is charged

### Requirement: A configured rate above the vault's ceiling is clamped, not reverted

When the agent's configured performance-fee rate exceeds the per-vault maximum enforced
by its governor, the governor SHALL clamp it to that maximum at propose time (emitting
`FeeClamped`) and record the clamped rate on the proposal, and SHALL re-clamp the
recorded rate at settlement against the per-vault maximum then in force (emitting
`FeeClamped` again only if the maximum was lowered after propose). Neither path SHALL
revert on this condition.

#### Scenario: An over-ceiling rate is clamped at settlement

- **WHEN** a vault's configured performance-fee rate exceeds its per-vault maximum and a
  profitable proposal settles
- **THEN** the fee charged corresponds to the per-vault maximum, a `FeeClamped` event
  recorded the clamp (at propose, and at settlement if the maximum was lowered since),
  and settlement completes

### Requirement: The performance fee is divided by the proposal's recorded performance split

A charged performance fee SHALL be divided among agent, protocol, guardian network, and
fund owner according to the performance split recorded on the proposal, as a single
division of one base rather than a sequence of compounding deductions. The agent takes
the remainder, so rounding dust goes to the agent, and the agent's share is then split
with any co-proposers; a co-proposer no longer registered as an agent forfeits its part,
which stays in the vault.

#### Scenario: The four shares divide one base

- **WHEN** a performance fee is charged under a recorded split of 6000/1500/1500/1000
- **THEN** each recipient receives its basis-point share of the same fee amount, with the
  agent taking the remainder, so the four shares sum exactly to the fee

#### Scenario: No recipient's share is reduced by another recipient's share

- **WHEN** a performance fee is charged
- **THEN** the protocol's share is computed from the full fee, not from the remainder left
  after the agent's share was taken

