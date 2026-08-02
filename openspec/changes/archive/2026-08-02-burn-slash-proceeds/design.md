# Design — Burn Slash Proceeds

## Decisions

### D1. Sink and size are separate decisions, and only size deters

A guardian loses the same bond whether the proceeds land in escrow or at
`BURN_ADDRESS`. The sink is invisible to the attacker's profit-and-loss. Burning
therefore does **not**, on its own, increase deterrence by any amount.

What the burn does is remove the constraint that forced sizing to be
compensatory. Both halves of this change are required; shipping the burn without
the sizing change would leave deterrence exactly where it is today.

```
   ESCROW SINK                          BURN SINK
   -----------                          ---------
   slash <= loss   (windfall bound)     slash <= bond   (bond is the only bound)
        |                                    |
   payoff ~ 0 -> indifferent            payoff = -bond -> deterred iff bond > V
        |                                    |
   value -> harmed depositors           value -> all WOOD holders
                                             (predominantly other guardians)
```

### D2. Flat punitive rate, not a multiplier

Rejected alternative: keep coverage-proportional sizing and multiply by `k > 1`.
That preserves the entire `_allocate` / `_committedUsd` / `effectiveTotal`
machinery in `ExposureLedger` and inherits its known failure mode — sizing keyed
to `getRequiredCoverage`, which a crafted proposal can understate.

Chosen: every approver the ledger names is slashed at `maxSlashBps` (10,000 in
all deploy scripts) of the bond snapshotted at the verdict anchor. The rate no
longer depends on the loss at all, so understating declared coverage buys the
attacker nothing on the slash side.

Consequence: `slashBpsFor` collapses from a proportional allocator to
"return the approver list with a uniform rate". `allocatedUsd` and the
`_allocate` helper survive only where the coverage gate still uses them.

### D3. The coverage gate survives with a new justification

`requireApproveQuorum` is not deleted. Its inequality is unchanged. Its meaning
changes from indemnity to eligibility:

| | Before | After |
| --- | --- | --- |
| Question it answers | Can these approvers make the vault whole? | Are these approvers bonded enough to be trusted with this tier? |
| Failure mode if too low | Depositors under-compensated | Under-bonded guardians gate high-tier proposals |
| `maxSlashBps` gap (N3) | Real recovery shortfall | Not applicable — no recovery |

This is the single largest piece of natspec work in the change: the rationale
blocks at `ExposureLedger.sol:1040-1082` argue at length for a guarantee the
protocol will no longer make.

### D4. Conviction bounty stays, paid from gross

`bounty = gross * bountyBps / 10_000` to `bountyTo`, remainder burned. The
`MAX_CONVICTION_BOUNTY_BPS` ceiling and the unconditional `bountyBps` validation
(`StakedWood.sol:1411`) are retained verbatim — their rationale (a compromised
`authorizedSlasher` must not be able to route the slash to an address of its
choosing) is unaffected by the sink change and becomes *more* important, since
the burn is now the only other destination.

### D5. Depositors are not compensated

Explicitly chosen over two alternatives:

- *Split sink* (part escrow, part burn) — preserves the depositor promise but
  retains every line of escrow machinery, forfeiting the simplification.
- *Treasury-funded compensation* — decouples compensation from slashing, but
  requires a treasury and a funding policy that do not exist.

Caveat emptor is consistent: the protocol's claim to depositors is that
guardians are punitively bonded and therefore unlikely to approve an attack, not
that losses are reimbursed.

## Risks and open questions

### R1. `BURN_ADDRESS` is a supply sink, not a burn — settled, keep as is

WOOD (`0xF8BC...f92b`) is live and exposes no `burn()` / `ERC20Burnable`. This
is confirmed, not open, and the existing design already made the choice
deliberately: `StakedWood.sol:526-530` selects `0x...dEaD` precisely so that
slashing carries "no `burn` dependency on the token." This change keeps that
sink unchanged.

**Consequence.** `totalSupply` never falls. Every deflation claim must be stated
in **circulating-supply** terms, and the change is only visible to anyone who
treats `0x...dEaD` as excluded from circulation.

**Internal impact: none.** Verified by grep — no contract in `src/` reads WOOD's
`totalSupply`. The only occurrence is the natspec at `StakedWood.sol:529`
explaining this very decision. No quorum, coverage, rate, or price denominator
is polluted by the accumulating dead balance, so nothing in the protocol drifts
as burns accumulate.

**External surface — CHECKED, and the answer is bad.** Both providers were
verified rather than assumed:

- **CoinGecko does not auto-detect burns.** Supply figures are "obtained from
  the various token teams and verified by the CoinGecko team"; for
  smart-contract tokens circulating supply is total minus team-supplied
  locked-wallet addresses. There is a manual *Supply Update Form* precisely
  because this is not automatic. WOOD (`sherwood-protocol`, contract
  `0xf8bc…f92b`, platform `robinhood`) currently reports circulating = total =
  max = 1,000,000,000.
- **GeckoTerminal is worse for this purpose.** Its market cap is null unless
  CoinGecko has a verified supply, and its FDV is explicitly "a multiplier of
  *on-chain* supply" — i.e. `totalSupply()`, which for WOOD never falls because
  the token has no `burn()`. GeckoTerminal will therefore *never* reflect a
  `0x…dEaD` burn, no matter how much accumulates.

So the deflation is real on-chain and invisible on both surfaces by default.
Two ways out, and they are not equivalent:

1. **Operational:** submit a CoinGecko supply update after burns accumulate.
   Recurring manual work, always lagging, and it does nothing for
   GeckoTerminal's FDV.
2. **Structural:** if WOOD is upgradeable, add `ERC20Burnable` and burn for
   real. `totalSupply` then falls on-chain and every downstream surface follows
   automatically, with no reporting relationship to maintain.

Option 2 is the only one that makes the tokenomic claim self-evidencing. It is
out of scope here (a token-contract change with its own review surface), but the
choice should be made deliberately rather than inherited — the protocol works
identically either way; only the *observability* of the deflation differs.

**Option not taken.** If WOOD is upgradeable, adding `ERC20Burnable` would make
the reduction visible in `totalSupply` itself and remove the reporting
dependency. That is a token-contract change with its own review surface, out of
scope here, and explicitly not required for this change to work.

### R2. Deflation is conviction-driven, so it is a distress signal

Burn volume is zero in a healthy protocol and rises exactly when the protocol is
under successful attack. This is the correct incentive but a poor growth
narrative. There is no continuous WOOD burn source to complement it: the only
fee in the system is the agent performance fee, denominated in the **vault's
asset**, not WOOD (`FeeConstants`, `SyndicateVault.sol:609`). A continuous burn
would be a separate mechanism and is out of scope here.

### R3. The attacker recaptures a slice of their own burn

A guardian holding fraction `f` of WOOD supply recovers `f x burn` in value
accrual. Negligible for small `f`; not negligible for a whale guardian. The
punitive rate (100% of bond) dominates this effect for any realistic `f`, but it
should be stated rather than ignored.

### R4. Challenge incentives shift in proportion to the challenger's WOOD holdings

Burned WOOD leaves circulation, so every remaining holder's share of supply
rises. A challenger who holds WOOD is one of those holders, and therefore
collects a second payoff on conviction that the current bond parameters were
not calibrated against. The size of that payoff scales with the challenger's
share of supply, so the effect is negligible for small holders and material for
whales.

**Current payoff structure** (defaults from `ChallengeGame`):

| Outcome | Challenger receives |
| --- | --- |
| Silence settle (`!escalated`) | `bond - settleBurnBps` (20% burned); **no bounty** — `bountyTo` is `address(0)` on the uncontested path |
| Contested, accused loses | Full bond, plus the defence pool, plus `convictionBountyBps` (5%) of the gross slash |
| Contested, challenger loses | Nothing — `forfeitBurnBps` burns 20%, the remaining 80% is booked to the defence funders |

`challengerBondBps = 500`, `settleBurnBps = 2_000`, `forfeitBurnBps = 2_000`,
`convictionBountyBps = 500`.

**Worked example** (illustrative figures, not on-chain data). Proposal with
$100k coverage, so a $5,000 challenger bond. Three approvers with $50k bonds
each, fully slashed under the punitive rule (D2): $150k gross, $7,500 bounty,
$142,500 burned.

Break-even win probability on the contested path is
`bounty * p = bond * (1 - p)`, i.e. **40%** with the burn term excluded. Adding
the challenger's share `f` of the burn:

| Challenger holds | Extra from burn | Break-even win probability |
| --- | --- | --- |
| 0.1% of supply | $142 | ~39% |
| 1% | $1,425 | ~36% |
| 5% | $7,125 | ~26% |
| 10% | $14,250 | ~19% |

**Two thresholds fall out of this:**

1. **Contested path** — a holder of 10% of supply files at ~19% confidence where
   an unaffiliated challenger needs ~40%. The bar is roughly halved for them and
   unchanged for everyone else.
2. **Silence path** — today a guaranteed loss of `settleBurnBps * bond`
   ($1,000 here) with no bounty. The burn is the only upside, so it turns
   profitable at `f * burn > settleBurnBps * bond`, i.e. **f > 0.7%** on these
   figures. Above that share, filing challenges that end in silence becomes
   directly profitable rather than a public-good subsidy.

**Why the silence-path effect is partly desirable.** Under the escrow the
challenger's incentive to use the silence path was that they might also be a
vault shareholder and collect from the compensation case. Deleting the escrow
(D5) removes that incentive entirely; the burn replaces it with a payout to
WOOD holders generally — which is predominantly guardians. The mechanism that
creates this risk is the same one that keeps the silence path from becoming pure
charity.

**Why it is partly not.** The 40% bar exists to stop speculative filings against
honest guardians. A whale filing at 19% expects to lose most cases, and every
loss still forces an honest guardian to defend — a defence bond, frozen
coverage, and process time. The adversarial version is deliberate: file against
guardians known to be honest, betting that a fraction are convicted anyway, and
collect a slice of each burn. Whether that is reachable depends entirely on how
hard `TokenCourt` is to sway. **The burn converts "can the court be manipulated"
from a fairness question into a profit question**, which raises the required
assurance on the court itself.

**Decision (2026-08-01): ACCEPTED AS IS.** `challengerBondBps` (500) and
`settleBurnBps` (2,000) stay at their current values. The thresholds above are
recorded as a known, accepted property rather than a defect: a very large WOOD
holder does get a cheaper option to file, and the protocol tolerates that in
exchange for more policing. Revisit if WOOD ownership concentrates further, or
if observed filings skew toward large holders.

**`forfeitBurnBps` / `inconclusiveBurnBps` need no change, and the reason
matters.** They were never escrow-era parameters. Verified against the
pre-change tree: all three challenger-bond burns — settle (`:1500`), forfeit
(`:1637`) and inconclusive (`:1805`) — already sent WOOD to the same
`BURN_ADDRESS` before this change. The compensation escrow only ever received
GUARDIAN slash proceeds; it never touched a challenger's bond. So the sink
change is a no-op for the losing side.

What did change is the SIZE of the slash burn — a whole bond instead of a share
of the loss — which enlarges the `f × burn` term. That term only enters the
decision to FILE, which is the accepted trade-off above; it does not touch what
a loser forfeits.

### R5. Gas constants must be re-derived, not just relaxed

`SLASH_GAS_PER_APPROVER = 300k` and `SLASH_GAS_BASE = 1M`
(`ChallengeGame.sol:151-158`) exist to guarantee the slash call has enough gas
for the `openCase` child under Robinhood's 32M per-transaction limit. With the
child call gone, both are over-reserved. Re-measure with the existing
`SlashGasCeiling.t.sol` harness rather than guessing a new number.

### R6. Storage slots are removed outright, not deprecated — settled

No mainnet 4663 deployment of the Plan D stack exists (no broadcast artifacts),
and testnet deployments are explicitly disregarded as redeployable. Slots are
therefore **deleted**, not zombie-reserved.

This is not a new precedent. `StakedWood.sol:410-427` records the same call
being made once already: "RE-BASELINED 2026-07-26 (DPoS delegation removal,
pre-mainnet) ... goldens regenerated in the same PR; no mainnet 4663 deployment
exists, testnets are redeployable." This change follows that procedure.

**Gap arithmetic.** `StakedWood.__gap` is `uint256[4]` at `:427`, and
`compensationEscrow` (`:485`) sits *after* it. Removing that field shifts every
following field up one slot, so the gap grows **4 -> 5** to hold total size
stable — the exact inverse of the documented `5 -> 4` shrink taken for
`_liabilityCheckpoints`. Same convention, opposite direction.

**Goldens that must be regenerated.** `script/check-layout-goldens.sh` guards
`SyndicateGovernor`, `SyndicateFactory`, and `GuardianRegistry` — the
proxy-upgraded contracts. Of these, only **`SyndicateFactory`** is touched here
(removal of `compensationEscrow` and its setter), so its golden must be
regenerated with `--update-golden` and committed in the same PR. `StakedWood` is
not golden-guarded; its layout is governed by the `__gap` convention above.

**The one discipline to keep.** These goldens exist to catch *accidental* layout
drift, so regenerating them is precisely the action they are designed to make
noisy. Regenerate deliberately and review the emitted diff field by field —
a wholesale re-baseline that nobody reads defeats the guard entirely.

**Append-only begins at first mainnet deploy.** After that point this freedom is
gone and every change must be carved off the front of the gap. This change is
one of the last opportunities to remove rather than deprecate.

### R7. `SyndicateVault` auto-delegate becomes vestigial for slashing

`_update`'s auto-delegation (`SyndicateVault.sol:645-650`) existed so
`getPastVotes` was a valid compensation-claim basis. It is retained by this
change because vote checkpoints may still serve governance, but its stated
justification in natspec is now wrong and must be rewritten or the behavior
removed. Decide explicitly rather than leaving stale rationale.

### R8. Depositor-facing framing must change everywhere at once

Any documentation, spec prose, or marketing describing guardian coverage as
protecting depositor funds becomes false on merge. Grep for "coverage",
"compensation", and "make whole" across docs and natspec as part of the change,
not as follow-up.
