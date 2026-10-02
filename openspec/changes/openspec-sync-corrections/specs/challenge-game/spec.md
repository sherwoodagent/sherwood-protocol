## MODIFIED Requirements

### Requirement: Economic terms and slash basis pinned at filing
Each challenge SHALL pin at filing: `voteWindowAtFiling`, `quorumBpsAtFiling`, `totalStakeAtFiling`, `votableAtFiling`, `settleBurnBpsAtFiling`, `forfeitBurnBpsAtFiling`, `prosecutorFeeBpsAtFiling`, plus the proposal's `executedAt`, `vault`, `proposerBondEscrow` and `proposer`. All clock checks and payout rates for that challenge MUST read the pinned values, never the live parameters — the owner can never retroactively shorten a window or re-price a challenge already running. Two reads are live by design: the one-shot re-arm after a silent failure extends the filing deadline and pins coverage by the LIVE `challengeWindow`, and the per-approver slash rates are read from the ledger at settle (`slashBpsFor`). The verdict slash basis SHALL be the pinned `executedAt` (with snapshot `executedAt - 1`), never `filedAt`, so an accused approver cannot zero its own stake checkpoint between drain and accusation.

#### Scenario: Owner parameter change does not move a live challenge
- **WHEN** the owner changes `voteWindow`, `challengeQuorumBps`, or any burn or fee rate after a challenge is filed
- **THEN** that challenge's windows and payouts continue to use the values pinned at its filing; only challenges filed after the change use the new values

### Requirement: Settle path — conviction, burn-only slash, prosecutor fee from the proposer's bond
`_settle` (reached only from a crossed convict quorum with convict weight above half the votable stake early, or above the acquit weight at the window's close) SHALL fail closed with `ZeroAddress` if `stakedWood` is unwired (recoverable: wiring the slasher makes every stuck challenge resolvable). It SHALL mark the status `Settled`, release this challenge's freeze hold, and — unless the proposal was already convicted by a concurrent challenge or by an earlier deployment of this game, in which case it SHALL emit `VerdictAlreadyCollected` and slash nothing — set the convicted flag and execute the slash via `IStakedWood.slashVerdict` using the ledger's per-approver rates (`slashBpsFor`, filtered to non-zero entries so released approvers are not named in the conviction) and the pinned `executedAt` as basis. `slashVerdict` takes no recipient: the slash burns inside sWOOD and pays nobody. When the pinned `proposerBondEscrow` is non-zero it SHALL then be asked to `forfeitBond(governor, proposalId, challenger, prosecutorFeeBpsAtFiling)`; a revert SHALL be retried at a zero fee and, failing that, surfaced as `ProposerBondForfeitureFailed` rather than losing the conviction. The challenger SHALL receive its bond less `settleBurnBpsAtFiling`, burned to `0x…dEaD` (`ChallengerBondBurned`) — a correct filing is cheap, not free, and the burn is charged by rate rather than by an identity check a second address would defeat. `ChallengeSettled(challengeId, slashedWood)` SHALL be emitted, where `slashedWood` is what was burned.

#### Scenario: Conviction burns the settle slice and pays the prosecutor fee
- **WHEN** a challenge settles on a crossed convict quorum
- **THEN** the accused approvers' locks are burned, the named adapter demotion is attempted, the convicted proposer's bond is forfeited with `prosecutorFeeBpsAtFiling` to the challenger, `settleBurnBpsAtFiling` of the challenger's bond is burned, and the challenger receives the rest

#### Scenario: Concurrent settle against an already-convicted proposal
- **WHEN** a second live challenge settles after another already collected the proposal's liability
- **THEN** no slash is attempted, `VerdictAlreadyCollected` is emitted, and the challenge still terminates normally (settle-path bond handling included)

### Requirement: No transfer in the game reaches an approver or the proposer
Every value-moving path SHALL pay only `BURN_ADDRESS` or the challenger. `_settle` burns `settleBurnBpsAtFiling` of the bond and returns the remainder to the challenger; `_fail` burns `forfeitBurnBpsAtFiling` and returns the remainder to the challenger; `slashVerdict` names no recipient; `forfeitBond` splits into the challenger's bounded prosecutor fee and the burn address. No path pays an accused approver or the proposer in that role; `file` does not refuse either of them as the challenger, so the only payee besides the burn address is whoever filed, and self-dealing is priced by the burn rates rather than barred. This is what makes an attacker controlling both sides of a challenge strictly worse off either way: convicting itself forfeits a bond in full to recover at most `MAX_PROSECUTOR_FEE_BPS` of it, and failing against itself destroys `forfeitBurnBpsAtFiling` of the challenger bond for nothing.

#### Scenario: Self-filed challenge has no profitable branch
- **WHEN** one operator controls the challenger, the accused approvers and the proposer
- **THEN** both terminal paths destroy value it holds and neither routes any of it back to the accused side

### Requirement: Adapter demotion is best-effort on a passed challenge only
A passed challenge naming a non-zero adapter SHALL attempt `tierRegistry.demoteByChallenge(target, selector)` inside a `try/catch`: a registry refusal (e.g. the game's demoter role was rotated away mid-challenge) MUST NOT revert the verdict — the slash, bond refund, and freeze release proceed, and the miss is surfaced as `AdapterDemotionFailed`. The catch exists for REGISTRY-SIDE refusals, which no caller selects at call time; the caller-selectable failure axis — the gas budget — is refused up front by the demotion-extended slash gas floor, so `AdapterDemotionFailed` can no longer be induced by dialling gas. The catch SHALL remain bare (no selector filter): every reachable failure behind the floor is registry-side, and bubbling any of them would re-open the permanent wedge the best-effort design exists to prevent (a revoked role stranding the bond, the freeze, and the accused's unstake path forever). The game's registry surface SHALL be demote-only (`ITierRegistryDemoterMinimal`): it can revoke a certification on a passed challenge and never grant one. No demotion occurs on any non-settled outcome, nor on the `VerdictAlreadyCollected` branch.

#### Scenario: Rotated demoter role does not strand the verdict
- **WHEN** `demoteByChallenge` reverts during settle
- **THEN** `AdapterDemotionFailed` is emitted and the settlement completes; the registry owner's own `demote` is the remedy

### Requirement: Fail path — bond returned to the challenger net of the forfeit burn
`_fail` (reached at or after the pinned window's close when the convict quorum was not met, or was met with convict weight not exceeding acquit weight) SHALL mark the status `Failed`, release the freeze hold, burn `forfeitBurnBpsAtFiling` of the challenger's bond to `0x…dEaD`, and return the remainder to the CHALLENGER. Integer division keeps the burn at most the bond, so the remainder cannot underflow and a zero rate returns the bond whole. The accused SHALL receive nothing: a failed accusation is a cost to the filer, never a transfer to the cohort it accused. `ChallengeFailed(challengeId, bondWood, burnedWood)` SHALL report the gross bond and the burned slice separately, and the burn SHALL additionally emit `ChallengerBondBurned`. The re-arm decision on this path is governed by the acquittal requirement above.

#### Scenario: Failed challenge pays the challenger, not the cohort
- **WHEN** a challenge fails at the window's close
- **THEN** the challenger receives `bond - burn` and every accused approver receives zero

#### Scenario: Forfeit burn prices the self-challenge round trip
- **WHEN** a challenge fails with `forfeitBurnBpsAtFiling` of 2,000
- **THEN** 20% of the bond is destroyed with no reachable beneficiary, so an operator that filed against its own proposal to freeze co-approvers' coverage pays for the freeze
