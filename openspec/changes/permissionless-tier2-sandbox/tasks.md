## 1. The sandbox contract

- [x] 1.1 Add `src/interfaces/ICallSandbox.sol`: the `Call { address target; bytes data; }` struct (no `value` field — design Non-Goals), `init(address vault, Call[] calls, address[] declaredTokens)`, `run()`, the delivery reads, and every error (`DeniedTarget(address)`, `CallFailed(uint256)`, `AlreadyRun`, `NotVault`).
- [x] 1.2 Implement `src/CallSandbox.sol`: minimal, clone-initializable, one-shot. `init` stores the vault, call set and declared tokens; a second `init` reverts.
- [x] 1.3 Implement `run()` as vault-only and one-shot: resolve the denied addresses live (vault, queue, governor, tier registry, exposure ledger, WOOD, sWOOD), revert `DeniedTarget` if any stored call names one, then dispatch each call with `target.call(data)` and no value, reverting `CallFailed(i)` on failure.
- [x] 1.4 Implement the delivery surface: `undeliveredValue()` (asset balance), `hasUndeliveredValue()`, `hasUnvaluedResidue()` (any declared non-asset token with a non-zero balance), and `sweep()` pushing the asset balance to the vault and returning the amount.
- [x] 1.5 Verify against the deployed vault that these selectors are exactly what `SyndicateVault._readUndeliveredValue`, `_refreshUnvalued` and `_SEL_SWEEP` call — a mismatched shape fails as empty returndata, which is indistinguishable from "owes nothing."
- [x] 1.6 Write natspec in house style: every guard names its adversary and cross-references the spec requirement it enforces.

## 2. Vault wiring

- [x] 2.1 Add `address public immutable sandboxImplementation` set in the implementation constructor; no setter, per design D1.
- [x] 2.2 Add the per-proposal sandbox mapping carved from `__gap`, mirroring how `_residuePid` was carved; update the gap comment with what was taken.
- [x] 2.3 Implement `runSandbox(...)`: `onlyGovernor`, `nonReentrant`, `whenNotPaused`. Clone via CREATE2 salted on the proposal id, `init` it, transfer the funding, call `run()`.
- [x] 2.4 Enforce the execute-time ceiling: read `tier2CallCapBps()` and `totalAssets()` live and revert when funding exceeds the ceiling. Fail closed on an unresolvable governor.
- [x] 2.5 Meter the funding transfer against the proposal's effective capital on the same accounting as a batch outflow.
- [x] 2.6 Record the sandbox for residue so `collectResidue`, the deposit gate and the residue bound all reach it; regenerate `script/syndicate-vault-layout.golden.json`.

## 3. Governor wiring

- [x] 3.1 Add the sandbox payload (call set, funding amount, declared tokens) to `StrategyProposal`; store it in `propose`; add a public view returning it in full. No setter. **Deviation:** stored in three pid-keyed mappings carved from `__gap`, NOT in `StrategyProposal` — the struct is append-only on a live BeaconProxy and dynamic arrays cannot be appended to it. New entry point `proposeWithSandbox` binds the payload to the id `propose` is about to mint (checked, not assumed) so pricing can read it; `propose`'s body moved verbatim into a shared `_propose`, so the two entry points cannot diverge.
- [x] 3.2 Make a sandbox payload contribute its funding at full notional to required coverage and force the proposal's tier to 2. Done inside `_snapshotTierAndGate`, which is where coverage is priced and the proposer bond is locked.
- [x] 3.3 Dispatch the sandbox at execute through `vault.runSandbox`, scaling the funding by the same raised-over-required ratio applied to effective capital; skip entirely when the scaled amount floors to zero. **Dispatched BEFORE the execute batch** — `totalAssets()` counts only idle float once capital is deployed, so a sandbox run afterwards would be priced against a ~0 ceiling. The batch then runs under `effectiveMaxCapital - scaledFunding`.
- [x] 3.4 Regenerate `script/syndicate-governor-layout.golden.json`.
- [x] 3.5 Bound the payload at propose by `CallSandbox`'s OWN limits (32 calls / 16 tokens), not `MAX_CALLS_PER_PROPOSAL` (64) — the wider bound would admit a payload that clears review and then reverts `InvalidCallSet` at execute with the bond locked.

## 4. Tests — the central claim

- [x] 4.1 Max-loss invariant: a hostile call set (approvals to third parties, transfers out, calls returning worthless tokens) loses at most the funded amount, measured as a vault-balance delta across execute, settle **and** a follow-up transaction that exercises every approval the sandbox granted. `test_maxLoss_hostilePayloadCostsAtMostTheFundedAmount`. Fixture runs at `managementFeeBps: 0` — a fee also leaves the vault at settle and would be miscounted as payload loss.
- [x] 4.2 Identity: a target observes `msg.sender == sandbox`, and a contract gated on `msg.sender == vault` reverts when the sandbox calls it. `test_permissionless_*` (positive) and `test_identity_vaultGatedTargetRefusesTheSandbox` (negative).
- [x] 4.3 No-allowance: `asset().allowance(vault, sandbox) == 0` before, during and after; a second `run()` reverts `AlreadyRun`. `test_maxLoss_*` and `test_run_isOneShot`.
- [x] 4.4 Funding ceiling: passes at the ceiling, reverts one wei above. **Correction to the third clause:** the ceiling CANNOT be tightened between propose and execute — `setTier2CallCapBps` is `whenNoActiveProposal`, so the window is frozen. `test_ceiling_cannotBeMovedWhileAProposalIsOpen` pins that instead, which is what actually protects the window; the live read still binds a ceiling changed while no proposal was open.
- [x] 4.5 Denylist: one denied target among valid calls reverts the whole execution with no call applied; cover all seven addresses. Split across two fixtures on purpose: vault, queue and governor in `SandboxProposal.t.sol` (which now binds a REAL `VaultWithdrawalQueue` — an unbound queue resolves to `address(0)`, never matches, and would pass vacuously), and tier registry, exposure ledger, sWOOD and WOOD in `GovernorCoverageGates.t.sol`, the only fixture that wires that four-hop chain. `MockSwood` gained the `wood()` getter the real `StakedWood` has, for the same anti-vacuity reason.

## 5. Tests — the permissionless claim and boundaries

- [x] 5.1 **The headline**: an unlisted, uncertified target executes end-to-end with **no owner transaction in the test body** — `test_permissionless_unlistedTargetExecutesWithNoOwnerTransaction`. The registry ceremony in `_wireTierRegistry` allowlists the vault ASSET so the mandatory ordinary batch can run, and never touches the sandbox target.
- [x] 5.2 Pin that `_guardBatchCalls` is unchanged: a non-allowlisted target named directly in a governor batch still reverts `DisallowedBatchCallee`. `test_batchGuard_unchangedForDirectlyNamedTargets`.
- [x] 5.3 Proposer gate: a non-agent opening a sandbox proposal reverts `NotRegisteredAgent`; an agent succeeds.
- [x] 5.4 Coverage: a sandbox proposal with non-zero coverage cannot execute on silence; half-raised coverage funds half the declared amount; coverage flooring to zero runs no sandbox. Added to `test/GovernorCoverageGates.t.sol` (`test_sandbox_noApprovers_cannotExecuteOnSilence`, `test_sandbox_halfRaisedCoverage_fundsHalfTheDeclaredAmount`, `test_sandbox_dustCoverage_runsNoSandboxAtAll`) rather than to the sandbox suite, which runs deliberately un-gated so its reverts stay attributable — this is the fixture that already wires the ExposureLedger, escrow and a stakeable guardian cohort.
- [x] 5.5 Payload immutability and readability: no path alters a stored payload, and the full payload is readable during the review period. `test_payload_readableInFullAndUnchangedAtExecute`, `test_payload_absentReadsEmpty`.
- [x] 5.6 Residue: a declared non-asset leftover reports unvalued residue and locks deposits; `collectResidue` clears it and reopens deposits; an undeclared leftover is stranded and never priced into a deposit. **This task found a real bug and fixed it:** `CallSandbox.sweep()` only moved the vault ASSET, so a declared non-asset token pinned `hasUnvaluedResidue()` true with nothing on earth able to move it — a permanent, unrecoverable deposit brick any registered agent could reach, the exact trade `SyndicateVault.depositsLocked`'s natspec calls worse than the suppression it guards. `sweep()` now pushes declared tokens to the vault (asset first, per-token gas ceiling, best-effort), and a token that PROVES unsweepable is abandoned so it stops counting — degrading it to the already-accepted undeclared case rather than bricking the vault.
- [x] 5.7 `runSandbox` authorization: reverts for a non-governor caller (`test_runSandbox_refusesNonGovernorCallers`) and while paused (`test_runSandbox_refusesWhilePaused` — asserts nothing was minted and nothing funded).
- [x] 5.8 Envelope: the funded amount is subtracted from the capital the execute batch runs under, so the two cannot spend the same declaration (`test_envelope_fundingIsSubtractedFromTheBatchCapital`), and a payload prices at full notional on top of the batches (`test_pricing_fundingAddsToRequiredCoverageAtFullNotional`).

## 6. Deployment

- [ ] 6.1 Deploy `CallSandbox` and pass it to the vault implementation constructor in `script/robinhood-mainnet/`.
- [ ] 6.2 Seed `tier2CallCapBps` to a real value **in the same script**, so it cannot be separated from wiring the sandbox; assert the deployed value is below `10_000`.
- [ ] 6.3 Assert `quorumTierThreshold == 0` in the deploy script so the guardian quorum stays mandatory.
- [ ] 6.4 Update `openspec/specs/deployment-docs/spec.md` with the ordering and the ceiling-before-wiring precondition; state explicitly that no registry ceremony exists.

## 7. Verification

- [ ] 7.1 `forge test` green across the full non-fork suite; diff the test count against `origin/main` first to rule out an inherited failure.
- [ ] 7.2 `forge fmt --check` clean; contract-size gate passing against the Robinhood 98,304-byte limit, with the vault's new size recorded.
- [ ] 7.3 Storage-layout goldens regenerated and the layout gate passing.
- [ ] 7.4 `openspec validate --all --strict` clean.
- [ ] 7.5 Re-read design.md Risks against the finished code and confirm each mitigation is implemented, not just described — in particular that no code path lets a sandbox pull from the vault.
