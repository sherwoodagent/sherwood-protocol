## ADDED Requirements

### Requirement: Unrealized conversions earn no performance fee

Capital converted into inventory the fund declines to price SHALL NOT produce a performance fee until it is realized back into the vault asset. The fund SHALL NOT count unpriced inventory in the value the high-water mark is measured against, and the settlement credit that stops such a conversion being reported as a loss SHALL be clamped so that it can raise reported P&L to at most zero. Realization SHALL occur through a later proposal that sells the inventory back into the vault asset, whose settlement is then measured against the mark in the ordinary way.

#### Scenario: A launch charges no fee at settlement

- **WHEN** a proposal deploys vault capital into a token launch and settles while the fund still holds the launched token
- **THEN** no performance fee is charged, because the price per share has not risen above the mark — the capital changed form rather than growing

#### Scenario: The fee arrives when the position is sold

- **WHEN** a later proposal sells that inventory back into the vault asset at a gain that lifts the price per share above the stored mark
- **THEN** the performance fee is charged at that settlement, on the portion above the mark

#### Scenario: A conversion credit cannot create a fee

- **WHEN** a strategy reports an unpriced cost basis at settlement
- **THEN** the credit SHALL be clamped to the proposal's apparent loss, so reported P&L is at most zero and no performance fee can arise from the credit itself
