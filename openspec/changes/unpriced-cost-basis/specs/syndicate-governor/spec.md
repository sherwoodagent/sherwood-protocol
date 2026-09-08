## MODIFIED Requirements

### Requirement: Settlement and P&L
`settleProposal` SHALL be callable on an `Executed` proposal by anyone after `executedAt + strategyDuration`, and by the proposer after only `executedAt + 1 hours` (the minimum self-settle delay that prevents a single-block execute-and-skim). Settlement SHALL run the pre-committed settlement calls via `executeGovernorBatch` under the same `maxCapital` cap as execution, then finalize: P&L SHALL be computed as the vault's asset-balance delta versus the capital snapshot, minus the vault's interim LP net flow (deposits/withdrawals during the strategy are principal, not performance), PLUS the settling strategy's clamped unpriced cost basis (capital deliberately converted into inventory the strategy declines to price is not a loss); state SHALL move to `Settled`, the active-proposal marker cleared, and the open count decremented before external fee transfers; the vault SHALL be notified via `onProposalSettled` after fees so queued flows settle against post-fee NAV.

#### Scenario: Non-proposer must wait full duration
- **WHEN** a caller other than the proposer calls `settleProposal` before `executedAt + strategyDuration`
- **THEN** the call SHALL revert with `StrategyDurationNotElapsed`

#### Scenario: Proposer early settle
- **WHEN** the proposer calls `settleProposal` at least 1 hour after execution but before `strategyDuration` elapses
- **THEN** settlement SHALL proceed

#### Scenario: Interim LP flow excluded from P&L
- **WHEN** depositors add or remove principal while a strategy is live
- **THEN** the settlement P&L SHALL exclude that interim net flow, so fees are charged only on strategy performance

#### Scenario: Converted capital is not reported as loss
- **WHEN** a strategy settles holding inventory it declines to price, having spent vault capital to acquire it
- **THEN** the reported P&L SHALL credit that strategy's clamped cost basis, so a launch that deployed its capital as intended reports approximately zero rather than a total loss

## ADDED Requirements

### Requirement: Unpriced cost basis is read from the strategy and clamped by the governor
A strategy SHALL be able to report, through `IStrategyDelivery.unpricedCostBasis()`, the vault-asset amount it spent acquiring inventory it declines to price. The governor SHALL read this view with a bounded-gas staticcall and SHALL treat a revert, an out-of-gas, or a malformed return as a basis of zero, so a strategy that does not implement the view settles exactly as it would have without this capability and no deployed strategy requires redeployment.

The governor SHALL clamp the reported figure to the proposal's own apparent loss — the amount by which the capital snapshot exceeds the vault's asset balance at settlement — before using it anywhere. The credited basis therefore SHALL NOT raise reported P&L above zero on a proposal that is nominally down, and SHALL NOT create a positive P&L that would not otherwise exist. A strategy that over-reports SHALL NOT thereby cause any fee to be charged.

The default implementation on the shared strategy base SHALL return zero. A template that reports unvalued residue SHALL implement this view, so the predicate and the amount describing it cannot diverge.

#### Scenario: A hostile report cannot manufacture profit
- **WHEN** a strategy reports a cost basis far exceeding the capital it was given
- **THEN** the credited basis SHALL be clamped to the proposal's apparent loss, the reported P&L SHALL be at most zero, no performance fee SHALL be charged, and the high-water mark SHALL NOT rise

#### Scenario: A strategy without the view settles unchanged
- **WHEN** a strategy that does not implement `unpricedCostBasis()` settles
- **THEN** the probe SHALL yield zero and the settlement SHALL produce exactly the P&L, floor decision, and fees it produced before this capability existed

#### Scenario: Inventory moved to the vault is still unrealized
- **WHEN** the unpriced inventory is swept from the strategy to the vault, which likewise does not price it
- **THEN** the reported basis SHALL be unchanged, because moving inventory between two holders that both decline to price it realizes nothing

### Requirement: Both drawdown gates are conversion-aware
Settlement applies two independent drawdown gates, and BOTH SHALL credit the same clamped unpriced cost basis, because a deliberate conversion is indistinguishable from a loss in the measure each uses:

- The CAPITAL floor, which requires the vault's realized asset balance to clear the capital snapshot less the envelope's allowance, SHALL treat converted capital as realized for the purpose of that comparison — the gate exists to catch value that vanished, and converted capital has not vanished.
- The SETTLE-PRICE floor, which compares live price per share against the declared drawdown envelope, SHALL credit the basis converted into price-per-share units, rounding the credit DOWN so the relief never exceeds the conversion that earned it.

Deliberate conversion into unpriced inventory therefore SHALL NOT consume a proposal's declared drawdown envelope, and a proposal SHALL NOT be required to declare a total-loss envelope in order to deploy capital as its strategy was designed to. Both gates SHALL remain in force for the uncredited remainder, so a converting strategy that also loses value beyond its declared envelope is still refused the ordinary settlement path by each gate independently. The owner-gated rescue and emergency paths SHALL be unchanged, including the rescue path's absolute backstop and the capital floor's existing exemption for them.

#### Scenario: A launch settles without declaring a total loss
- **WHEN** a proposal converts its committed capital into unpriced inventory, having declared a drawdown envelope that describes the risk it is actually taking rather than a total loss
- **THEN** the capital floor SHALL be satisfied by crediting the converted capital, where today only a maximal declaration — which disables that gate outright for the proposal — permits settlement

#### Scenario: A large deployment settles by the ordinary path
- **WHEN** a proposal deploys more than `MAX_STAMP_DRAWDOWN_BPS` of the vault's NAV into a strategy that converts it into unpriced inventory
- **THEN** `settleProposal` SHALL succeed by the ordinary permissionless path rather than reverting below the price floor or requiring the owner-gated rescue path

#### Scenario: A real loss still meets both floors
- **WHEN** a converting strategy settles having also lost value beyond its declared envelope
- **THEN** the credited basis SHALL relieve only the converted portion, and the settlement SHALL still be refused by each gate that the remaining loss breaches

### Requirement: Unpriced conversion is declared at propose time
A strategy SHALL be able to declare, through `IStrategyDelivery.expectsUnpricedResidue()`, that it is expected to settle holding inventory it declines to price. The governor SHALL read that declaration at propose time with a bounded-gas staticcall, treating an unreadable answer as false, and SHALL snapshot it onto the proposal, where it is readable for the proposal's whole lifetime. At settlement, a strategy reporting a nonzero cost basis on a proposal carrying no such snapshot SHALL cause the settlement to revert. A snapshot without a corresponding report SHALL settle ordinarily with no credit.

The declaration SHALL NOT be a proposer input. Both it and the amount come from the certified template, so a proposer can neither inflate the relief nor assert it for a strategy that has not earned it, while a guardian reviewing the proposal still sees the intent before execution.

When a nonzero basis is credited, the governor SHALL emit a distinct event carrying the proposal, the vault, and the credited basis, leaving the existing settlement event's signature unchanged so that consumers decoding it are not broken.

#### Scenario: Undeclared conversion is refused
- **WHEN** a strategy reports a nonzero unpriced cost basis at settlement and its proposal did not declare that it expected one
- **THEN** the settlement SHALL revert

#### Scenario: Declared but unused
- **WHEN** a proposal declares an expected conversion and its strategy reports a zero basis
- **THEN** settlement SHALL proceed normally with no credit applied and no conversion event emitted

#### Scenario: Guardians see the intent before execution
- **WHEN** a proposal that will convert capital into unpriced inventory is under guardian review
- **THEN** the declaration SHALL be readable on the proposal, so the review sees the intent rather than inferring it from a maximal drawdown envelope

#### Scenario: The proposer cannot assert a conversion
- **WHEN** a proposal names a strategy whose template does not declare that it converts capital
- **THEN** the proposal SHALL carry no declaration regardless of anything the proposer supplied, and any cost basis that strategy later reports SHALL cause settlement to revert
