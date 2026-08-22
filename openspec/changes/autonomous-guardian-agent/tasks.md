Groups 1–7 are implemented in the `sherwood-guardian` repo; group 8 lands here.

## 1. Unblock the build

- [ ] 1.1 Resolve and pin the real `sha256` digests for `ghcr.io/foundry-rs/foundry` and `node:20-alpine`, replacing the `REPLACE_*_DIGEST` placeholders in `Dockerfile`
- [ ] 1.2 Confirm `docker build` succeeds and the resulting image has `forge`, `cast`, and `anvil` on PATH
- [ ] 1.3 Add a build step to the PR workflow so an unbuildable image fails CI instead of merging

## 2. Chain-agnostic configuration

- [ ] 2.1 Replace the hardcoded `CHAINS` map in `src/chains.ts` with a loader over the committed `chains/<chainId>.json` address books, keeping the `ChainConfig` shape
- [ ] 2.2 Vendor or fetch `chains/9994663.json` into the image, and refuse start-up when no address book exists for the connected chain id
- [ ] 2.3 Derive the `known` target set from every address-valued key in the book, so an unknown target means "not sanctioned by the deploy ceremony"
- [ ] 2.4 Unit-test that a target absent from the book classifies as unknown and that an unsupported chain id refuses start-up

## 3. Review discovery across per-vault governors

- [ ] 3.1 Extend `src/watcher.ts` to index `ReviewRegistered(address indexed governor, uint256 indexed proposalId, uint64 voteEnd, uint64 reviewEnd)` and persist the proposal-to-governor map
- [ ] 3.2 Join `ReviewOpened(uint256 indexed proposalId, uint128 totalStakeAtOpen)` to its governor via that map; drop `GOVERNOR_ADDRESS` from required configuration
- [ ] 3.3 Replace all local-clock deadline arithmetic with reads of block timestamp and the on-chain `reviewWindow`
- [ ] 3.4 Unit-test governor resolution for a governor first seen at registration, and abstention when chain time has passed `reviewEnd`

## 4. Coverage and verdict pipeline

- [ ] 4.1 Add `src/ledger.ts` reading required coverage for a proposal plus the agent's free staked weight, with an explicit fail branch on empty returndata
- [ ] 4.2 Add `src/judge.ts` as a pure function from risk report plus coverage facts to `APPROVE | BLOCK | ABSTAIN`, with the deterministic gate ordered: simulation failure → block; any critical code → block; coverage over capacity or ceiling → abstain; clean and fully known → approve; otherwise escalate
- [ ] 4.3 Implement the model tier behind that escalation, narrowing any response to `BLOCK | ABSTAIN` and treating an approval-shaped response as abstain
- [ ] 4.4 Add the achievable-block-weight computation and emit an unreachable-quorum result distinct from a cleared review
- [ ] 4.5 Unit-test the full gate table over fixture proposals, including that no model response can produce `APPROVE`, and that every unavailable input resolves to block or abstain

## 5. Signing and posture gate

- [ ] 5.1 Add `GUARDIAN_MODE` (`observe` | `defend` | `autonomous`), defaulting to `observe`, and refuse `autonomous` unless the RPC-reported chain id is 9994663
- [ ] 5.2 Refuse start-up when the agent's signing address is a registered agent on a vault it would review
- [ ] 5.3 Add `src/signer.ts` sending `openReview`, `resolveReview`, and `voteOnProposal`, reading on-chain review state immediately before each vote and skipping when a vote from this address already exists
- [ ] 5.4 Enforce the late-vote lockout and the per-proposal coverage ceiling at the signer boundary as well as in the judge
- [ ] 5.5 Unit-test that `observe` issues no `eth_sendRawTransaction`, and that `autonomous` on chain 4663 or 8453 exits non-zero

## 6. Container and deployment

- [ ] 6.1 Add a `HEALTHCHECK` and a `railway.json` modelled on `spectator/railway.json` (Dockerfile builder, `/health`, restart on failure)
- [ ] 6.2 Document the service variables: `RPC_URL`, `GUARDIAN_KEY`, `CHAIN_ID`, `GUARDIAN_MODE`, `MAX_COVERAGE_PER_PROPOSAL`, model API key
- [ ] 6.3 Verify the `/data` volume survives restart and that a wiped volume does not produce a duplicate vote

## 7. End-to-end on the fork

- [ ] 7.1 Extend `foundry/test/SimulateProposal.t.sol` to replay a Robinhood-target proposal (Morpho supply or a Uniswap route) rather than a Base one
- [ ] 7.2 Stake the agent wallet, then age the cohort ≥2 days with `evm_increaseTime` before opening a review, per the `deployment-docs` delta
- [ ] 7.3 Run one proposal end to end in `defend`: confirm the agent opens the review, votes Block, and that `getReviewState` records the vote
- [ ] 7.4 Run one clean proposal end to end in `autonomous`: confirm an Approve vote lands and coverage is booked on the `ExposureLedger`
- [ ] 7.5 Confirm a restart mid-review does not double-vote, and that an expired RPC is reported without exiting

## 8. Spec and documentation sync (this repo)

- [ ] 8.1 Validate the change with `openspec validate autonomous-guardian-agent --strict`
- [ ] 8.2 After implementation, archive the change so the `deployment-docs` delta lands in the main spec and `guardian-agent` becomes a capability
- [ ] 8.3 Cross-check that `docs/guardian-network.md` and the archived `deployment-docs` requirement agree on slash severity being derived, not voted
