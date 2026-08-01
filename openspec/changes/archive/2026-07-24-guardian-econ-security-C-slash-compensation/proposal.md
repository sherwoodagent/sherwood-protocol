# Guardian Economic Security — Plan C: Slash Rails + Compensation Escrow (v1b, part 1)

> Migrated from docs/superpowers/plans/2026-07-24-guardian-econ-security-C-slash-compensation.md (superpowers workflow) on 2026-08-01.

## Why

The master design's v1b phase (§3.8 + §4 "authorized-slasher entrypoint" — see `openspec/changes/archive/2026-07-22-guardian-econ-security-A-execution-safety/design.md`) requires retroactive-liability payout rails: when guardians are convicted of approving a drain, the slash proceeds must compensate the drained shareholders instead of burning. Paying the vault's live NAV would let a coalition drain, buy the depressed shares of exiting honest holders, and recoup its own slash — a recoupment channel the burn sink never had (finding F1). This slice ships first because it contains the F1 regression fix — the highest-value security property in v1b — and every other v1b component (Plan D challenge game, Plan E approver premium) terminates in it: building the sink before the trigger gives Plan D a real, tested target instead of a stub.

## What Changes

- New standalone `CompensationEscrow` (Ownable2Step, not upgradeable): holds WOOD slash proceeds per *case* `(vault, snapshotTimestamp, proceeds)`. Holders of record at the pre-drain snapshot redeem pro-rata against the vault's ERC20Votes checkpoints (`getPastVotes / getPastTotalSupply`); claims are mapping entries, never a token, so they are non-transferable by construction. Unredeemed residue sweeps permissionlessly to the protocol backstop after a per-case-frozen residue window — never to live vault NAV.
- `StakedWood` (UUPS, live): owner-settable `authorizedSlasher` role and a `slashToEscrow` verdict entrypoint that reuses the existing per-approver slash legs (own stake, delegated at the `maxDelegatedSlashBps` cap, first-loss spill) but routes the total to the escrow via `openCase` instead of `_burnWood`. The block-quorum review slash path (`slashGuardians` → burn, registry `refundSlash` reserve) is untouched and stays distinct so the refund reserve can never refund a proven-malice verdict.
- End-to-end suite against a real `StakedWood` proxy + real `SyndicateVault`: verdict slash compensates pre-drain holders 70/30, a post-drain buyer gets nothing (F1 against the real vault), and live `totalAssets()` is untouched.
- `StakedWood` storage layout newly pinned in the golden check; full-suite regression; master spec status header updated (v1b part 1 complete; until Plan D lands, `authorizedSlasher` is owner-set, so a verdict is a governance action, not an adjudicated one).

Post-implementation review (2026-07-25, commit `e7fcc24`) hardened the shipped code beyond the plan snippets — per-case fund isolation (critical), `slashBps` clamping, owner-set `compensationEscrow` instead of a call parameter, frozen per-case residue windows, and `snapshotTimestamp <= openedAt` enforcement. See design.md "Post-implementation amendments" for the record of record.

## Capabilities

- challenge-game
- guardian-staking

## Impact

- New: `src/CompensationEscrow.sol`, `src/interfaces/ICompensationEscrow.sol`
- Modified: `src/StakedWood.sol` (append `authorizedSlasher` and `compensationEscrow` slots, `__gap` 9 → 7), `src/interfaces/IStakedWood.sol`, `script/check-layout-goldens.sh` (+ StakedWood golden)
- Tests: `test/CompensationEscrow.t.sol`, `test/StakedWoodSlashToEscrow.t.sol`, `test/CompensationEndToEnd.t.sol`, `script/staked-wood-layout.golden.json`
- Explicitly untouched: `GuardianRegistry.refundSlash` (decision D4)
