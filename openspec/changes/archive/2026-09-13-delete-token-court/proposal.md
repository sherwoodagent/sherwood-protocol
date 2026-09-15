# Retire the token-court capability

## Why

Challenges are adjudicated by a vote of the staked guardians. `ChallengeGame.file`
opens that vote directly: it pins the electorate at `filedAt - 1` as total staked
WOOD less the accused approvers' stake, each eligible guardian casts one weighted
`voteOnChallenge(id, convict)` ballot inside `voteWindow`, and `resolve` settles as
soon as convict weight reaches `challengeQuorumBps` of the pinned stake or fails the
challenge when the window closes short of it. Nothing refers a case out of the game,
so the separate adjudication contract this capability specified has no caller, no
state and no verdict to deliver, and it is retired along with the counter-bond pool
whose completion was its only entry condition. The requirements that survive the retirement — the pre-filing
snapshot, the exclusion of the accused from both the ballot and the quorum
denominator, the zero-custody rule on the deciding path, and the burn-only
destination for every confiscated wei — are restated against the guardian vote in
`openspec/specs/challenge-game/spec.md`. `spec.md` here is the capability's final
text, archived unedited as the record of what it required.
