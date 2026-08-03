# syndicate-vault (delta)

## ADDED Requirements

### Requirement: Target-based batch callee gate

When the calling governor exposes a nonzero TierRegistry, every governor-batch sub-call's `target` SHALL be either the vault's underlying `asset()` or an address for which the registry's `isAdapterAllowed(target)` returns true; otherwise the batch SHALL revert `DisallowedBatchCallee(target)`. The gate SHALL apply to every call **regardless of selector, calldata length, or attached native `value`** — including calls whose calldata is empty or shorter than four bytes, which carry native ETH or trigger fallback logic and are invisible to every selector check and to the `asset()`-balance net-outflow meter. Because the gate runs inside `executeGovernorBatch`'s guard, it SHALL apply on the execute, settlement, `unstick`, and both emergency batch paths alike.

The callee gate is the durable close of the selector-allowlist gap class (issue #166, Option B from PR #157's audit): four consecutive remediation rounds on issue #115 each found further missed value-moving selectors (Permit2 single+batch, DSToken pull/move/push, ERC-1363 families, ERC-4626 withdraw/redeem), proving the selector set unenumerable. Gating by target inverts the question — an unknown selector on an unknown target is refused before its calldata is examined, covering every current and future token-router standard (including issue #18's ERC-721/1155/777 surfaces) by default posture rather than selector-by-selector.

Layering SHALL be strictly additive and ordered:

- The unconditional layers — the privileged-target denylist and the `transferFrom`-source guard — SHALL run before, and independent of, the callee gate, exactly as specified elsewhere; the callee gate SHALL NOT weaken or reorder them.
- The callee gate SHALL live in the registry-gated half and follow the same degrade posture as the value-moving-selector guard, mirroring issue #118's precedent: when the governor's TierRegistry cannot be resolved (getter missing, malformed return, or `address(0)`), the gate SHALL be skipped by design (degrade open — hard-reverting would brick registry-less vaults); when the registry resolves and refuses a target — including a refusal arising purely from codehash drift on an allowlisted address — the batch SHALL revert (fail closed), with no fallback to tier-2 pricing.
- The value-moving-selector guard SHALL be retained beneath the callee gate as defense-in-depth: on an allowlisted token callee, a guarded selector naming a non-allowlisted spender/recipient SHALL still revert `DisallowedTransferTarget` — a pure target gate cannot see calldata-level recipients, so neither layer subsumes the other.

`asset()` SHALL be the sole callee-gate exemption: it is the one deployment-time-vetted contract every deploy batch must call (`asset().approve(adapter, …)`), and the one token whose movements the outer net-outflow balance-diff meter independently verifies. Calls targeting `asset()` remain fully subject to the source guard and the value-moving-selector guard, including the recipient-side self-transfer fast-path scoped to `asset()`, which SHALL be preserved unchanged. The documented residual of this design is exactly: an unenumerated approval-setting selector on `asset()` itself or on an explicitly-allowlisted token — bounded to owner-attested, codehash-pinned contracts rather than the open-ended set of tokens the vault holds.

#### Scenario: Unknown selector on an unlisted token is rejected

- **WHEN** a governor batch contains a call to a token that is neither `asset()` nor allowlisted, carrying a selector the value-moving guard does not enumerate (e.g. legacy `increaseApproval(address,uint256)`)
- **THEN** the batch reverts `DisallowedBatchCallee(token)` before the selector is examined — the gap class the four selector-remediation rounds chased is closed at the target, not the selector

#### Scenario: Exotic-asset approval is rejected by default posture (issue #18)

- **WHEN** a governor batch contains `nft.setApprovalForAll(attacker, true)` (or any ERC-721/1155/777 operator/approval call) against an exotic-asset contract the vault holds as a position, and that contract is not allowlisted as a callee
- **THEN** the batch reverts `DisallowedBatchCallee(nft)` — no per-standard selector enumeration is needed

#### Scenario: Empty-calldata native-value call is rejected

- **WHEN** a governor batch contains a call with empty calldata and `value > 0` to an address that is neither `asset()` nor allowlisted
- **THEN** the batch reverts `DisallowedBatchCallee(target)` — the callee gate runs before any short-calldata skip, closing the raw-ETH exfiltration route no selector check ever saw

#### Scenario: asset() is exempt from the callee gate but not the selector guard

- **WHEN** a governor batch calls `asset().approve(adapter, amt)` with `adapter` allowlisted
- **THEN** the callee gate passes the call without an allowlist entry for `asset()`, and the batch proceeds
- **WHEN** a governor batch calls `asset().approve(attacker, max)` with `attacker` not the vault or an allowlisted adapter
- **THEN** the batch reverts `DisallowedTransferTarget` — the retained selector guard still bites on the exempted callee

#### Scenario: Allowlisted token callee is still recipient-guarded

- **WHEN** a governor batch calls `rewardToken.transfer(attacker, bal)` where `rewardToken` is allowlisted as a callee but `attacker` is not the vault or an allowlisted adapter
- **THEN** the batch reverts `DisallowedTransferTarget` — the callee gate admits the call to the inner layer; it does not replace it

#### Scenario: Registry-less governor degrades open

- **WHEN** the calling governor exposes no TierRegistry (getter missing, malformed return, or returning `address(0)`) and a batch calls an arbitrary non-privileged target
- **THEN** the callee gate is skipped along with the value-moving-selector guard, and the batch proceeds under the unconditional guards and the outflow/reserve/buffer meters only

#### Scenario: Codehash drift severs callability

- **WHEN** an allowlisted callee's bytecode changes at the same address after the grant (metamorphic redeploy, or code appearing at a codeless allowlisted address) and no demotion has been persisted
- **THEN** the very next batch naming it as a target reverts `DisallowedBatchCallee(target)` — the callee gate inherits the allowlist's lazy read-side self-heal

#### Scenario: In-flight settlement calls are re-validated at use time

- **WHEN** a proposal stored before this gate existed reaches `settleProposal` with a settlement call targeting a non-allowlisted, non-`asset()` address
- **THEN** the batch reverts `DisallowedBatchCallee(target)` — stored calldata is validated under the rule live at execution, and recovery is allowlisting the target (registry owner) followed by `unstick`, or the emergency path with compliant calls
