# syndicate-governor (delta)

## ADDED Requirements

### Requirement: Owner bond gates the normal proposal lane
`_propose` and `executeProposal` SHALL both refuse with `OwnerBondNotLive` when `IGuardianRegistry.ownerBondLive(vault)` is false, read through the registry handle the governor already holds — the same route `GovernorEmergency` uses for `ownerStake`. The gate SHALL be re-asserted at execute and not only at admission: the bond that matters is the one live WHEN CAPITAL MOVES, and the vote plus the review period sit between the two points. The reachable route between them is `slashOwnerBond`, which carries no open-proposal gate; the owner's own exit is not that route, because `requestUnstakeOwner` refuses while a proposal is open and `propose` refuses once a request is in. The gate SHALL be a state check and not a latch, so re-funding the slot reopens the lane. Registered-agent status (`isAgent`) is independent of the owner's stake and SHALL NOT be treated as a substitute for this check.

#### Scenario: Propose refused without a live owner bond
- **WHEN** a registered agent calls `propose` on a vault whose owner-stake slot is exiting, claimed or slashed
- **THEN** the call SHALL revert with `OwnerBondNotLive`

#### Scenario: Bonded vault proposes as before
- **WHEN** the owner-stake slot is bound and not exiting
- **THEN** `propose` SHALL behave exactly as it did before this change

#### Scenario: Execute refused when the bond leaves after approval
- **GIVEN** an `Approved` proposal whose vault's owner bond was slashed after propose
- **WHEN** `executeProposal` is called
- **THEN** it SHALL revert with `OwnerBondNotLive` before any batch runs

#### Scenario: An approved proposal is not bricked
- **WHEN** the owner-stake slot is re-funded inside the execution window after an `OwnerBondNotLive` refusal
- **THEN** `executeProposal` SHALL succeed for the same proposal
