# Protocol tests

Tests live with the subsystem they exercise. Regression names describe behavior;
original audit references may remain in comments for provenance.

| Directory | Scope |
| --- | --- |
| `vault` | Vault accounting, fees, withdrawal queue, batch custody rules |
| `governor` | Proposal lifecycle, voting, execution and coverage gates |
| `guardian` | Guardian registry, sWOOD, exposure ledger, tier registry and pricing |
| `challenge` | Challenge game, token court and dispute lifecycle |
| `strategies` | Portfolio, Morpho, concentrated liquidity and adapters |
| `factory` | Syndicate/strategy factories, configuration, deployment and vesting |
| `layout` | Vault, governor and guardian registry storage pins |
| `invariants` | Foundry invariant campaigns and their handlers |
| `fizz` | Medusa/Echidna harness and Foundry replay adapter |
| `fork` | Tests that require an RPC endpoint |
| `helpers`, `mocks` | Shared test plumbing and explicit stand-ins |

## Shared fixture

Inherit `helpers/ProtocolFixture.sol`. `_deployProtocol(owner)` creates the real
factory, core and guardian/challenge stack, then creates one owner-bonded syndicate
with its vault, governor and withdrawal queue. External tokens, identity registry
and price feeds are mocked. The caller controls guardian funding/maturation and
LP deposits.

Focused suites use `_deployVault`, `_deployStakedWood`, `_deployFactory`,
`_deployGovernor` and `_deployRegistry` with their own parameters. This keeps
negative initialization tests, custom economics and intentional dependency mocks
explicit. The fixture has no automatic `setUp` or clock advancement.

Use real registries when testing authorization, tiering or collateral. The
permissive tier helper is only appropriate when those checks are outside the
assertion's scope.

## Run

```sh
forge test --no-match-path 'test/fork/**' --summary
forge test --match-path 'test/invariants/**'
FOUNDRY_PROFILE=coverage forge coverage --ir-minimum \
  --no-match-path 'test/fork/**' --report summary --report lcov
```

Coverage uses minimal IR optimization to avoid stack-too-deep errors without
excluding large production contracts. IR source maps are approximate; the report
is advisory. Fork tests select their own RPC endpoint and block; the opt-in fork
workflow runs `test/fork/**`. The non-RPC sWOOD review/slash and tier lifecycle
suites run in the normal guardian/governor jobs.

## Preserved invariants

All 20 existing invariant functions remain, including vault solvency (warm and
cold start), the five async redemption invariants, WOOD custody conservation,
fee accounting and capital snapshot lifecycle. The entire fizz harness remains.

`invariant_blockedImpliesEpochAccounting` retains its public name, but checks the
persistent committed review outcome: SHE-207 removed blocker enumeration and
epoch rewards moved off chain. The handler's governor is registered, and a
deterministic reachability test ensures a blocked review can actually occur.

## Refactor inventory

Compared with `post-audit-v2` at `188941b6`:

- 58 audit-batch files moved to subsystem directories; no audit-named test directories remain.
- 139 existing files relocated, including root suites, layout pins and fork tests.
- All 2,277 existing test/invariant function declarations preserved, including fork suites.
- Existing test bodies preserved except the strengthened blocked-review invariant; two new tests cover fixture wiring and invariant reachability.
- All 20 invariant names and all 30 fizz harness files retained. Fizz edits only update comments pointing to moved tests.
- Three existing `LayoutPins` suites retained; the ticket's count of four was stale. The separate golden script still checks all five upgradeable contracts.

## Runtime baseline

Foundry v1.7.1 on GitHub Actions `ubuntu-latest`, non-fork command above:

| Revision | Suites | Passed | Failed | Skipped | Suite wall time | Compilation |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Before (`188941b6`) | 180 | 2,714 | 0 | 1 | 436.91 s | 1,125.16 s |

Baseline evidence: [CI run 35008993338](https://github.com/sherwoodagent/sherwood-protocol/actions/runs/35008993338/job/104515888236).
The job checked out PR merge `930989e59f6db61427498f16b601272089968bb2`, whose
Git tree exactly matches `188941b6` (`9bd0a7191d34d1b2d94896941282564c40a0da21`).
The full job took 26m20s; suite wall time excludes compilation and setup.
