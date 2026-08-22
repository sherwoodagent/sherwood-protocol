## Why

`SyndicateVault._guardBatchCalls` decodes only the **destination** (`to`, calldata bytes 36..68) of a `transferFrom(address,address,uint256)` batch call; the **source** (`from`, bytes 4..36) is never read by any guard (issue #115, found by the Pashov `solidity-auditor` panel reviewing PR #111, confidence 90; pre-existing on `main`). Because a governor batch runs via `delegatecall` from the vault, every sub-call carries `msg.sender == vault`, so `asset.transferFrom(victim, vault, victimBalance)` spends `allowance[victim][vault]` — the allowance every LP must grant in order to deposit, which UIs routinely set to `type(uint256).max`. The current `to == vault → continue` exemption passes it outright as an "inflow", and every other meter is blind: net-outflow reads 0 (the vault's balance *rises*), coverage prices an uncertified target at tier 2 against a trivially small `maxCapital`, and the #93 privileged-target denylist doesn't fire (the call target is the asset token, not the vault or queue). The result is a confiscate-any-LP-wallet primitive — third-party funds, outside anything the tier system prices.

## What Changes

- `_guardBatchCalls` SHALL decode the `from` argument of every `transferFrom` batch call and reject the batch unless `from == address(this)`, reverting with a new dedicated error `DisallowedTransferFromSource(address target, address from)`.
- The source check SHALL be **unconditional** — enforced in the Part-1 (registry-independent) pass, NOT inside the registry-gated selector loop. Rationale mirrors #93's target denylist: confiscating a third party's allowance is not a priced capability (tier coverage bounds vault capital, never LP wallets), so a registry-less governor must not skip it. This deliberately goes beyond the audit's suggested diff, which placed the check inside the registry-gated loop and would have left registry-less vaults exposed to the same theft.
- The source check SHALL NOT consult `isAdapterAllowed(from)`. That flag encodes destination consent ("may *receive* approvals/transfers of vault funds", per its natspec) — reusing it for the source would silently convert "may receive vault funds" into "may be seized from". No honest batch pulls from an adapter: deploys go `approve(adapter)` + the adapter pulls in its own code (`BaseStrategy._pullFromVault`, swap adapters' `safeTransferFrom(msg.sender, …)` — never batch calldata), returns are pushes (`_pushToVault` / `withdrawTo`), and no adapter grants the vault an allowance. This resolves the issue's open question: the only honest source is the vault itself.
- `transferFrom(vault, X, amount)` remains permitted and keeps flowing through the existing destination guard (`X` must be the vault or an allowlisted adapter) plus the net-outflow meter — it is semantically `transfer(X, amount)`.
- **BREAKING (behavioral tightening)**: `transferFrom` calldata shorter than 68 bytes now reverts `MalformedCall` unconditionally (previously only when a registry was wired), and `transferFrom` with `from != vault` reverts even when `to == vault`. `test/vault/SelectorGuard.t.sol::test_transferFromIntoVaultPasses` currently pins the hole as intended behaviour (pulls 100e6 from a third-party `sink` and asserts success) — it is deliberately replaced by a confiscation regression test, with the reasoning recorded in the test's natspec.

## Capabilities

### New Capabilities

<!-- none -->

### Modified Capabilities

- `syndicate-vault`: the "Value-moving selector guard on batches" requirement changes — the "pull into the vault always passes" scenario is removed — and a new unconditional "transferFrom source guard on batches" requirement is added: `from` must be the vault itself, enforced independently of the TierRegistry on every batch path (execute, settlement, both emergency).

## Impact

- **Code**: `src/SyndicateVault.sol` — `_guardBatchCalls` (decode `from`, add the unconditional source check) plus natspec; new error in `src/interfaces/ISyndicateVault.sol`.
- **Errors/ABI**: new `DisallowedTransferFromSource(address target, address from)` custom error surfaced on the vault.
- **Behavior**: strictly rejects previously-accepted-but-malicious batches. No honest batch encodes a raw `transferFrom` at all (verified across `src/strategies/*`, `src/adapters/*`, and all batch fixtures), so there is no functional regression.
- **Tests**: `test/vault/SelectorGuard.t.sol` — one asserted-safe test replaced (see above), new pins for the source guard including the registry-less path and the "allowlisted adapter is NOT a permitted source" decision.
- **Sequencing**: same function as #93 (landed, PR #111), #19 (fail-closed on unset registry) and #18 (exotic-asset selectors). Issue #115 states the natural order: #93 → **this** → #19 → #18.

## Post-merge remediation round (Pashov audit of PR #157)

A 12-agent Pashov security audit of this change's PR (#157) returned 2 confirmed findings, addressed in this same change before merge (see design.md § "Post-merge remediation round" for full rationale):

- **Finding 1 [90, 3-agent convergence]**: the new Part-1b source guard and the pre-existing Part-2 destination guard both matched only the four legacy-ERC20 selectors, leaving Permit2's `AllowanceTransfer.transferFrom`/`.approve` and DSToken's `pull`/`move` — different selectors, identical "pull via delegated allowance" capability — completely unguarded. Fixed by extending the guarded-selector set (Option A) rather than the audit's suggested target-based redesign (Option B), which was assessed as more durable but deferred as a required follow-up because it would re-plumb the tier-pricing/TierRegistry relationship for every non-value-moving adapter call, outside this change's footprint.
- **Finding 2 [80]**: Part 2's self-transfer fast-path (`recipient == address(this) → continue`) exempted any token decoding to the vault, not only `asset()` — the one token the outer net-outflow meter verifies. Fixed by scoping the fast-path to `calls[i].target == asset()`.

This adds `_SEL_PERMIT2_TRANSFER_FROM`, `_SEL_PERMIT2_APPROVE`, `_SEL_DSTOKEN_PULL`, `_SEL_DSTOKEN_MOVE` to the spec's guarded-selector requirements (see the ADDED/MODIFIED requirement deltas) and is reflected in `specs/syndicate-vault/spec.md`'s new scenarios.
