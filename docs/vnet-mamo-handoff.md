# Sherwood LeveragedAerodromeCL vnet — handoff for Mamo PR #64

Persistent Tenderly Base-fork Virtual TestNet running the full Sherwood stack with one USDC
vault (owned by Mamo's multisig) and one live, indefinite leveraged-aero proposal in
`State.Executed` with NAV ≈ $60k. Deployed 2026-07-20 on branch `vnet/mamo-leveraged-aero`;
**strategy redeployed 2026-07-21 from PR #14 (`feat/rerange-width-param`, d8f593e)** — the live
clone includes the per-cycle `rerange(uint24 width, uint256 minLiq0, uint256 minLiq1)` Mamo
rebalancer param (init: width 4000 raw ticks, minWidth 200, maxWidth 20000). The full
LeveragedAero fork suite (**67 tests**, incl. the new width tests) ran green against this vnet
on the deployed code.

## 1. Vnet

| | |
|---|---|
| Tenderly project | `moonwell/project` |
| Vnet id | `8975a20b-5cf0-4399-9165-08e2b19229db` |
| Slug | `mamo-leveraged-aero-1784592639` |
| chainId | **8453** (matches Base — safe for Mamo's FPS address book) |
| Fork block | 48,901,646 |
| Admin RPC | `https://virtual.base.eu.rpc.tenderly.co/e6961d2a-4711-42eb-b4c1-2a42cbc17d28` |
| Public RPC | `https://virtual.base.eu.rpc.tenderly.co/70a4990f-6686-4536-8237-ad9103acd11b` |
| State sync | off (fork frozen at fork block; vnet clock advanced ~73h during governance) |
| Persistence | not auto-deleted; delete manually via Tenderly dashboard when done |

## 2. Addresses (also in `chains/8453.json` on the branch)

Fund-specific (the two Mamo needs as `SHERWOOD_SYNDICATE_VAULT` / `SHERWOOD_LEVERAGED_AERO_STRATEGY`):

| Contract | Address |
|---|---|
| **SyndicateVault** (syndicateId 1, "Mamo Leveraged Aero Fund" / mLEVAERO, USDC) | `0xf88F704023ED4f77769cB112B3FcBB4Cda8588E9` |
| **LeveragedAerodromeCLStrategy clone** (live, PR #14 code) | `0x5E22913E4C96f816133fbc8E894F652a4f87C760` |
| Per-vault SyndicateGovernor (BeaconProxy) | `0x430FA5659cCf6E9c1586007a0A2B7760fb75e105` |
| (superseded first clone — pre-PR#14 code, Settled, do not use) | `0x168ac730AB0DA6FCDE8aA26e33eac4aE6c8CfB4B` |

Stack:

| Contract | Address |
|---|---|
| SYNDICATE_FACTORY | `0xFf0350eCbF98A7DF765FCe79cCE5E39CDe525eA4` |
| STRATEGY_FACTORY | `0x1fD7160513aC1F1ACe58e2631D0f8f04EF429b0d` |
| LEVERAGED_AERO_CL_TEMPLATE (PR #14 code) | `0x8eE3AD5B3b574b4253985a7F32aB1231474CA381` |
| PRICE_ROUTER | `0x6423f6b8860957e66Db99E185e651373f32FE8cc` |
| WOOD_TOKEN (fixture) | `0x1b8F202855D4f20d05A39D773267077888E1727D` |
| STAKED_WOOD | `0xa97cDD619c396fbF71Aa51B0fa4aEf5F4A3e2078` |
| GUARDIAN_REGISTRY | `0x55aA31052fBccAf0F79cE85EfA1E5B05b83aA494` |
| PROTOCOL_CONFIG | `0x5406a3ec376908d5cF4d075AEAFa68Eac4EE5056` |
| GOVERNOR_BEACON | `0x84f494b7601Fef6912BA9d78a8Fe5Ab901311199` |
| SYNDICATE_VAULT_IMPL | `0x6dd1E1fd8BDF887B9E48f1184C137fd6D2dE2B91` |

(Address-book note: the file's `SYNDICATE_GOVERNOR` key is intentionally zero — governors are
per-vault since #421; use the vault's `governor()`.)

## 3. Actors and keys

| Role | Address | Key handling |
|---|---|---|
| Vault owner | `0x26c158A4CD56d148c554190A95A921d90F00C160` (MAMO_MULTISIG) | no key — impersonate via unlocked tx (below) |
| Proposer / registered agent / fee recipient | `0x2Ab03887829EA8632D972cf3816b825Fe7FC5e73` (MAMO_BACKEND) | Mamo holds the real key; on-vnet also impersonatable; funded 100 ETH |
| Deployer (owns factory/registry/config — `SKIP_MULTISIG_HANDOFF`) | `0x1fE3016Bc84f82903BA4Deb85e37914f8dAdDC0a` | vnet-only throwaway, pk `0x83d14649bc41719d80c221d5960ac332426b7c1093e4f9247fb799fc75e5f304` |
| Seed LP (60k vault deposit + 10k live deposit) | `0x2e26ef5c5Dc8Ce003BE9434E275D129421c8d073` | vnet-only throwaway, pk `0xc3c411751a969be3e09ca3d084bddacf0a0159f519fd5e082d1f5f34f6dda311` |
| Smoke-test EOA | `0x973867BcbBe5A40Fc74966e19301451a8086844D` | vnet-only throwaway, pk `0xe290e0596596abf4c9fc7744899f8bde269179c180e1bcc5fd4a9aeccb639781` |

FEE_RECIPIENT for the strategy = **MAMO_BACKEND** (perf fee 1000 bps, mgmt fee 100 bps —
script defaults). Vault `agentFeeBps` = 1000. All throwaway keys are worthless outside this vnet.

**Impersonation:** the vnet accepts unsigned txs from any address (incl. the Safe):
`cast send <target> '<sig>' <args> --unlocked --from 0x26c158A4...C160 --rpc-url <ADMIN_RPC>`
(or `forge script … --unlocked --sender <addr>`). Mamo's proposal 012 `setOpenDeposits(true)`
can be driven this way as the multisig.

## 4. State confirmations (read back via the public RPC)

- `strategy.state() == 1` (Executed); **proposal 3** state == 6 (Executed, indefinite: 3650-day
  duration). Proposals 1 (Rejected artifact) and 2 (Settled — funded the superseded pre-PR#14
  clone) are history; the live one is **3**.
- `strategy.nav() == 59_999_948_932` (≈ $60k USDC, 6dp)
- `vault.owner() == MAMO_MULTISIG`; `vault.isAgent(MAMO_BACKEND) == true`; `strategy.proposer() == MAMO_BACKEND`
- `vault.openDeposits() == false` (left for proposal 012 to flip; depositors `SEED_LP`, `SMOKE`, `MAMO_BACKEND` are whitelisted)
- Smoke test: fresh EOA deposited 2,000 USDC via `strategy.deposit(2000e6, 0)` → got vault
  shares → `vault.approve(strategy, shares)` → `strategy.redeem(shares, 0)` → 1,999.999986 USDC
  back (rounding dust). NOTE: redeem requires the share approval first.
- Vault-level redemptions are locked while the proposal is Executed — live deposit/redeem goes
  through the strategy (as in the e2e suite).

## 5. Notable deviations / gotchas encountered

1. **Agent registration happens AFTER ownership handoff** (brief said before): the only legal
   handoff is `SyndicateFactory.rotateOwner`, which is blocked while any proposal is open **and
   wipes the vault's agent set**. Order used: create vault → owner ops → `rotateOwner(vault,
   MAMO_MULTISIG)` → `registerAgent(0, MAMO_BACKEND)` as the impersonated multisig → propose.
2. **Chainlink feeds are permanently fresh — no 24h staleness cliff.** The 5 venue feeds (BTC,
   ETH, USDC, AERO, sequencer-uptime) had their code replaced (`tenderly_setCode`) with
   `script/FreshFeed.sol` instances: `updatedAt` tracks `block.timestamp`, prices frozen at
   fork-time values (BTC $65,146.32, ETH $1,900.43, USDC $0.99979, AERO $0.42977, SEQ up).
   To move a price: `forge create script/FreshFeed.sol:FreshFeed --constructor-args <answer> <dec> …`,
   `cast code <mock>`, then `cast rpc tenderly_setCode --raw '["<feedAddr>","<code>"]'`.
   Feeds affected: `0x64c9…848F` (BTC), `0x7104…Bb70` (ETH), `0x7e86…bc6B` (USDC),
   `0xBCF8…6433` (SEQ), `0x4EC5…cfF0` (AERO). Moonwell's oracle reads the same addresses, so
   strategy NAV and borrow-side health stay coherent.
3. **WOOD owner-stake:** `transferOwnerStakeSlot` requires the incoming owner to hold a prepared
   stake, so MAMO_MULTISIG holds a bound 10,000 fixture-WOOD stake; `minOwnerStake` was set to 0
   (any future vault creators on this vnet need no stake).
4. **Governor `VoteType` is `{For=0, Against=1, Abstain=2}`** (not OZ order). Proposal 1 on this
   vnet is a `Rejected` artifact of that (accidental full-weight Against vote); proposal 3 is the
   live one. `resolveProposalState(id)` is the permissionless flush if a rejected/expired
   proposal ever pins `openProposalCount`.
6. **2026-07-21 strategy redeploy (PR #14):** proposal 2 was settled by the proposer (funds
   returned to the vault, ~$60k), a new template + clone were deployed from
   `feat/rerange-width-param` (d8f593e), and proposal 3 re-executed the same 50k principal +
   10k live-deposit/deployIdle shape. Vault, governor, factory, and all other stack addresses
   are unchanged — only `LEVERAGED_AERO_CL_TEMPLATE` and `MAMO_LEVERAGED_AERO_STRATEGY` moved.
5. Deploy posture: `SKIP_MULTISIG_HANDOFF=true ALLOW_FIXTURE_WOOD=true` (fork-only), protocol
   fee 100 bps (default), voting period 24h + guardian review 24h (why the vnet clock is ~73h
   ahead of fork time — harmless now that feeds are always fresh).

## 6. Address-book file

`chains/8453.json` on branch `vnet/mamo-leveraged-aero` is the vnet book (this file must NOT be
merged to `main` — it overwrites the real Base address book; the branch exists to hand the file
over). Keys added for Mamo: `MAMO_SYNDICATE_VAULT`, `MAMO_LEVERAGED_AERO_STRATEGY`,
`MAMO_VAULT_GOVERNOR`. Diff vs main: fresh core stack + PriceRouter + StrategyFactory +
leveraged-aero template; the 5 pre-existing Base template addresses were validated live on the
fork and reused as-is.
