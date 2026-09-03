#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""SHE-182 -- the protocol economics mechanics.

Ported from the SHE-182 manual simulation with the mechanics unchanged. Every
number that came from Solidity now arrives through `constants.py`, and every
input that a scenario can move is an override on `Params`, so a scenario file
is just a dict.

What the model reproduces, in the order the contracts do it:

  1. Management fee on a SINGLE execute-time base for the deployed span.
     `_accrueManagementFee` has one call site (SyndicateVault.sol:2643) and no
     hooks on deposit / withdraw / batch, so the asset-seconds integral is one
     rectangle at the execute-time balance -- not a time-weighted average, and
     not what the NatSpec claims.
  2. Performance fee on the excess above the high-water mark, measured AFTER
     the management transfer has left the vault.
  3. High-water mark ratchets monotonically, fee or no fee.
  4. Coverage: each approver reserves the FULL coverage against haircut-priced
     stake (this is what `reservation_mode` toggles).
  5. Exposure is held for duration + challengeWindow + epochLength/2.
  6. A conviction burns 100% of the at-anchor stake (this is what `slash_mode`
     toggles); the proposer bond pays prosecutorFeeBps to the challenger and
     burns the rest; the depositor receives nothing.

Two mechanism toggles model fixes that are currently on the table. Both default
to today's behaviour, so an unmodified run describes the protocol as deployed.

  reservation_mode:
    "full"   (today)   Each approver reserves the whole coverage, so a cohort of
                       A approvers ties up A x coverage of budget for the life
                       of the exposure. ExposureLedger.sol:268 says so in as
                       many words. Adding approvers multiplies the collateral
                       requirement instead of sharing it.
    "shared" (SHE-227) Approvers declare amounts that SUM to the coverage, so
                       the cohort budget is coverage, not approvers x coverage.
                       The stake multiple stops scaling with cohort size.

  slash_mode:
    "whole"     (today)   A conviction burns 100% of the approver's at-anchor
                          slashable stake, regardless of how much of the
                          coverage they actually carried. slashBpsFor returns a
                          flat 10000 for every approver with a live pledge and
                          maxSlashBps is 10000 as deployed (Plan B pre-flight
                          hard-requires it).
    "allocated" (SHE-232) Burn only the stake allocated to THIS proposal, i.e.
                          the approver's pro-rata share of the coverage. This is
                          always <= the whole-stake slash.

  wood_price_path:
    [[month, price], ...] -- a piecewise-linear price path over the year. WOOD
    demand is recomputed monthly and the reported lockup is the 12-month mean;
    the binding-TVL figures use the WORST (lowest-price) month, because that is
    the month the constraint actually binds in.
"""


from constants import DAYS_PER_YEAR, load, resolve_fee_set

RESERVATION_MODES = ("full", "shared")
SLASH_MODES = ("whole", "allocated")

# Fields a scenario may override. Anything not on this list is a typo, and a
# typo that silently does nothing is the worst failure mode a scenario runner
# has -- so unknown keys raise.
OVERRIDABLE = {
    # profile
    "stage", "avg_fund_size", "proposals_per_fund_year", "proposal_frac_of_fund",
    "strategy_duration_days", "approvers_per_proposal", "tier2_share",
    "gross_return_annual", "frac_profitable", "loss_ratio", "challenge_rate",
    # fees
    "fee_set", "mgmt_bps", "perf_bps",
    # market
    "tvl", "wood_price", "wood_price_path",
    # protocol knobs a scenario is allowed to move (defaults come from source)
    "certified_bound_bps", "wood_haircut_bps", "proposer_bond_bps",
    "challenger_bond_bps", "k_numerator", "epoch_length_days",
    "challenge_window_days", "min_guardian_stake_wood",
    # mechanism toggles
    "reservation_mode", "slash_mode",
    # single-proposal worked case
    "worked_fund_size", "worked_gross_move", "worked_duration_days",
    # reporting
    "flywheel_threshold",
}


class Params(object):
    """A fully resolved scenario cell. Immutable in spirit; copy to vary."""

    def __init__(self, proto, assumptions, overrides=None, label=None):
        self.proto = proto
        self.assumptions = assumptions
        self.label = label or ""
        ov = dict(overrides or {})
        unknown = set(ov) - OVERRIDABLE
        if unknown:
            raise KeyError(
                "unknown scenario override(s): %s\n  known keys: %s"
                % (", ".join(sorted(unknown)), ", ".join(sorted(OVERRIDABLE))))

        # ---- stage profile ------------------------------------------------
        stage = ov.pop("stage", "growth")
        if stage not in assumptions.stage_profiles:
            raise KeyError("unknown stage %r; known: %s"
                           % (stage, ", ".join(sorted(assumptions.stage_profiles))))
        self.stage = stage
        prof = dict(assumptions.stage_profiles[stage])
        for k, v in prof.items():
            setattr(self, k, v)

        # ---- fees ---------------------------------------------------------
        self.fee_set = ov.pop("fee_set", "current")
        mgmt, perf, fee_label, fee_note = resolve_fee_set(self.fee_set, proto, assumptions)
        self.mgmt_bps, self.perf_bps = mgmt, perf
        self.fee_label, self.fee_note = fee_label, fee_note
        self.mgmt_split = proto.mgmt_split
        self.perf_split = proto.perf_split

        # ---- protocol knobs (source defaults) ------------------------------
        self.bps = proto.bps
        self.certified_bound_bps = assumptions.certified_bound_bps
        self.full_notional_bps = proto.FULL_NOTIONAL_BPS
        self.wood_haircut_bps = proto.WOOD_HAIRCUT_BPS
        self.proposer_bond_bps = proto.PROPOSER_BOND_BPS
        self.challenger_bond_bps = proto.CHALLENGER_BOND_BPS
        self.prosecutor_fee_bps = proto.PROSECUTOR_FEE_BPS
        self.settle_burn_bps = proto.SETTLE_BURN_BPS
        self.forfeit_burn_bps = proto.FORFEIT_BURN_BPS
        self.k_numerator = proto.K_NUMERATOR
        self.epoch_length_days = proto.EPOCH_LENGTH_DAYS
        self.challenge_window_days = proto.challenge_window_days
        self.min_guardian_stake_wood = proto.MIN_GUARDIAN_STAKE_WOOD
        self.owner_bond_wood = proto.owner_bond_wood
        self.effective_slash_bps = proto.effective_slash_bps

        # ---- market -------------------------------------------------------
        self.tvl = 10_000_000.0
        self.wood_price = assumptions.wood_price_anchor
        self.wood_price_path = None
        self.flywheel_threshold = assumptions.flywheel_threshold

        # ---- toggles ------------------------------------------------------
        self.reservation_mode = "full"
        self.slash_mode = "whole"

        # ---- worked single-proposal case ----------------------------------
        self.worked_fund_size = 100_000.0
        self.worked_gross_move = 0.10
        self.worked_duration_days = 14

        # ---- apply overrides ----------------------------------------------
        for k, v in ov.items():
            setattr(self, k, v)

        self._validate()

    def _validate(self):
        if self.reservation_mode not in RESERVATION_MODES:
            raise ValueError("reservation_mode must be one of %s, got %r"
                             % (RESERVATION_MODES, self.reservation_mode))
        if self.slash_mode not in SLASH_MODES:
            raise ValueError("slash_mode must be one of %s, got %r"
                             % (SLASH_MODES, self.slash_mode))
        if self.approvers_per_proposal < 1:
            raise ValueError("approvers_per_proposal must be >= 1")
        if self.approvers_per_proposal > self.proto.MAX_APPROVERS_PER_PROPOSAL:
            raise ValueError(
                "approvers_per_proposal %d exceeds MAX_APPROVERS_PER_PROPOSAL %d (%s)"
                % (self.approvers_per_proposal, self.proto.MAX_APPROVERS_PER_PROPOSAL,
                   self.proto.where("MAX_APPROVERS_PER_PROPOSAL")))
        if not 0.0 <= self.tier2_share <= 1.0:
            raise ValueError("tier2_share must be in [0, 1]")
        if self.wood_price <= 0:
            raise ValueError("wood_price must be > 0")
        if self.wood_price_path is not None:
            pts = self.wood_price_path
            if len(pts) < 2:
                raise ValueError("wood_price_path needs at least two (month, price) points")
            if any(p <= 0 for _, p in pts):
                raise ValueError("wood_price_path prices must be > 0")

    def copy(self, **changes):
        p = Params.__new__(Params)
        p.__dict__.update(self.__dict__)
        for k, v in changes.items():
            if k not in OVERRIDABLE and not hasattr(p, k):
                raise KeyError("unknown parameter %r" % k)
            setattr(p, k, v)
        p._validate()
        return p

    def price_months(self):
        """12 monthly prices. Flat unless a path is declared."""
        if self.wood_price_path is None:
            return [self.wood_price] * 12
        pts = sorted((float(m), float(p)) for m, p in self.wood_price_path)
        out = []
        for month in range(12):
            if month <= pts[0][0]:
                out.append(pts[0][1])
                continue
            if month >= pts[-1][0]:
                out.append(pts[-1][1])
                continue
            for i in range(len(pts) - 1):
                m0, p0 = pts[i]
                m1, p1 = pts[i + 1]
                if m0 <= month <= m1:
                    t = 0.0 if m1 == m0 else (month - m0) / (m1 - m0)
                    out.append(p0 + t * (p1 - p0))
                    break
        return out


# ---------------------------------------------------------------------------
# Fee mechanics
# ---------------------------------------------------------------------------

def coverage_factor(p):
    """USD coverage consumed per USD of proposal notional.

    requiredCoverage = SUM_i cap_i * boundBps_i / BPS  (SyndicateGovernor.sol:1924).
    Tier 2 -> FULL_NOTIONAL_BPS; certified tier 0/1 -> the adapter's bound.
    """
    return (p.tier2_share * p.full_notional_bps
            + (1.0 - p.tier2_share) * p.certified_bound_bps) / p.bps


def per_settlement_moves(p):
    """Per-settlement win/loss magnitudes that reproduce the annual gross return
    given the win rate and the loss ratio."""
    n = p.proposals_per_fund_year
    f = p.frac_profitable
    denom = n * (f - (1.0 - f) * p.loss_ratio)
    if denom <= 0:
        raise ValueError("degenerate return profile: win rate %.2f and loss ratio %.2f "
                         "cannot produce a positive annual return" % (f, p.loss_ratio))
    w = p.gross_return_annual / denom
    return w, w * p.loss_ratio


def settlement_order(n, f):
    """Deterministic Bresenham interleave of wins and losses.

    Order matters because the HWM ratchets monotonically; all-wins-first and
    all-losses-first bracket the answer and this reports neither.
    """
    wins = int(round(n * f))
    seq, acc = [], 0.0
    for _ in range(n):
        acc += wins / float(n)
        if acc >= 1.0 - 1e-9:
            seq.append(True)
            acc -= 1.0
        else:
            seq.append(False)
    return seq


def run_fund_year(p):
    """One fund, one year, settlement by settlement."""
    w, l = per_settlement_moves(p)
    order = settlement_order(p.proposals_per_fund_year, p.frac_profitable)

    assets = float(p.avg_fund_size)
    start_assets = assets
    hwm = assets                      # seeded at first mint
    dur_frac = p.strategy_duration_days / DAYS_PER_YEAR

    tot_mgmt = tot_perf = 0.0
    gross_pnl = 0.0
    n_hwm_charged = 0

    for is_win in order:
        base_at_execute = assets      # single rectangle, never re-stamped
        r = w if is_win else -l
        after_pnl = assets * (1.0 + r)
        gross_pnl += after_pnl - assets

        mgmt = base_at_execute * (p.mgmt_bps / p.bps) * dur_frac
        mgmt = min(mgmt, max(after_pnl, 0.0))
        after_mgmt = after_pnl - mgmt
        tot_mgmt += mgmt

        perf = 0.0
        if after_mgmt > hwm:
            perf = (after_mgmt - hwm) * (p.perf_bps / p.bps)
            n_hwm_charged += 1
        tot_perf += perf

        assets = after_mgmt - perf
        if assets > hwm:
            hwm = assets              # monotonic ratchet

    return {
        "start_assets": start_assets,
        "end_assets": assets,
        "gross_pnl": gross_pnl,
        "mgmt_fee": tot_mgmt,
        "perf_fee": tot_perf,
        "depositor_net": assets - start_assets,
        "settlements": len(order),
        "settlements_charging_perf": n_hwm_charged,
        "per_settlement_win": w,
        "per_settlement_loss": l,
        "deployed_frac_of_year": min(
            1.0, p.proposals_per_fund_year * p.strategy_duration_days / DAYS_PER_YEAR),
    }


def split_fees(mgmt, perf, p):
    """Split each fee leg by its snapshotted bps. The agent leg is paid as the
    REMAINDER on-chain, so it absorbs rounding and any unwired recipient."""
    out = {}
    for who in ("agent", "protocol", "guardian", "owner"):
        out[who] = (mgmt * p.mgmt_split.get(who, 0) / p.bps
                    + perf * p.perf_split.get(who, 0) / p.bps)
    return out


# ---------------------------------------------------------------------------
# WOOD demand
# ---------------------------------------------------------------------------

def cohort_multiplier(p):
    """Approvers' worth of coverage the cohort ties up while a review is open.

    full   -> approvers (today; ExposureLedger.sol:268)
    shared -> 1         (SHE-227; declared amounts sum to the coverage)
    """
    return float(p.approvers_per_proposal) if p.reservation_mode == "full" else 1.0


def wood_demand(p, tvl=None, wood_price=None):
    """WOOD that must be locked to support `tvl` at this profile and price."""
    tvl = float(p.tvl if tvl is None else tvl)
    price = float(p.wood_price if wood_price is None else wood_price)
    haircut_price = price * p.wood_haircut_bps / p.bps

    n_funds = tvl / p.avg_fund_size
    notional = p.avg_fund_size * p.proposal_frac_of_fund
    cov = notional * coverage_factor(p)
    proposals_year = n_funds * p.proposals_per_fund_year

    # Coverage budget is released only when the epoch bucket containing
    # executeBy + duration expires. The /2 is a uniform-arrival average; the
    # worst case is a full epoch + window.
    exposure_hold_d = (p.strategy_duration_days + p.challenge_window_days
                       + p.epoch_length_days / 2.0)
    # The proposer bond clears earlier: executedAt + duration + challengeWindow.
    bond_hold_d = p.strategy_duration_days + p.challenge_window_days

    live_exposures = proposals_year * exposure_hold_d / DAYS_PER_YEAR
    live_bonds = proposals_year * bond_hold_d / DAYS_PER_YEAR

    # (a) proposer bonds
    bond_usd = live_bonds * cov * p.proposer_bond_bps / p.bps
    bond_wood = bond_usd / price

    # (b) guardian stake. The EXECUTE gate only needs aggregate >= coverage
    # (1x); the BUDGET is what gates the next proposal, and that runs to
    # cohort_multiplier x coverage.
    mult = cohort_multiplier(p)
    gate_usd = live_exposures * cov / p.k_numerator
    budget_usd = gate_usd * mult
    gate_wood = gate_usd / haircut_price
    budget_wood = budget_usd / haircut_price

    # floor: every guardian must hold minGuardianStake to register at all
    n_guardians = max(p.approvers_per_proposal,
                      int(round(live_exposures * p.approvers_per_proposal)) or 1)
    stake_floor_wood = n_guardians * p.min_guardian_stake_wood
    stake_wood = max(budget_wood, stake_floor_wood)

    # (c) vault-owner bonds: one per fund
    owner_bond_wood = n_funds * p.owner_bond_wood

    # (d) challenge bonds + a 1:1 counter-bond pool
    challenges_live = live_exposures * p.challenge_rate
    chal_usd = challenges_live * cov * p.challenger_bond_bps / p.bps
    chal_wood = 2.0 * chal_usd / price

    total_wood = bond_wood + stake_wood + chal_wood + owner_bond_wood
    open_coverage = live_exposures * cov

    return {
        "wood_price": price,
        "coverage_per_proposal_usd": cov,
        "notional_per_proposal_usd": notional,
        "coverage_factor": coverage_factor(p),
        "n_funds": n_funds,
        "proposals_per_year": proposals_year,
        "live_exposures": live_exposures,
        "live_bonds": live_bonds,
        "exposure_hold_days": exposure_hold_d,
        "open_coverage_usd": open_coverage,
        "proposer_bond_wood": bond_wood,
        "proposer_bond_usd": bond_usd,
        "guardian_stake_gate_wood": gate_wood,
        "guardian_stake_budget_wood": budget_wood,
        "guardian_stake_wood": stake_wood,
        "guardian_stake_usd": stake_wood * price,
        "stake_floor_wood": stake_floor_wood,
        "stake_floor_binds": stake_floor_wood > budget_wood,
        "owner_bond_wood": owner_bond_wood,
        "challenge_bond_wood": chal_wood,
        "challenge_bond_usd": chal_usd * 2.0,
        "total_wood_locked": total_wood,
        "total_usd_locked": total_wood * price,
        "cohort_multiplier": mult,
        # price-invariant: approvers / haircut / k in "full", 1 / haircut / k in "shared"
        "stake_multiple_x_coverage": (mult / (p.wood_haircut_bps / p.bps)) / p.k_numerator,
        "pct_total_supply": 100.0 * total_wood / p.assumptions.wood_total_supply,
        "pct_effective_float": 100.0 * total_wood / p.assumptions.wood_float_m12,
    }


def wood_demand_year(p, tvl=None):
    """Year view of WOOD demand, honouring `wood_price_path`.

    The lockup reported is the 12-month mean; `worst` is the month with the
    largest requirement (the lowest price), which is the month the constraint
    actually binds in.
    """
    prices = p.price_months()
    months = [wood_demand(p, tvl, px) for px in prices]
    if p.wood_price_path is None:
        base = dict(months[0])
        base["price_path"] = None
        base["worst_month_price"] = prices[0]
        base["mean_price"] = prices[0]
        base["monthly_total_wood"] = None
        return base

    mean = {}
    keys_to_mean = ("proposer_bond_wood", "proposer_bond_usd", "guardian_stake_gate_wood",
                    "guardian_stake_budget_wood", "guardian_stake_wood", "guardian_stake_usd",
                    "owner_bond_wood", "challenge_bond_wood", "challenge_bond_usd",
                    "total_wood_locked", "total_usd_locked", "pct_total_supply",
                    "pct_effective_float", "stake_floor_wood")
    base = dict(months[0])
    for k in keys_to_mean:
        mean[k] = sum(m[k] for m in months) / len(months)
    base.update(mean)
    worst = max(months, key=lambda m: m["total_wood_locked"])
    base["stake_floor_binds"] = any(m["stake_floor_binds"] for m in months)
    base["price_path"] = [[i, prices[i]] for i in range(12)]
    base["worst_month_price"] = worst["wood_price"]
    base["worst_month_total_wood"] = worst["total_wood_locked"]
    base["worst_month_pct_float"] = worst["pct_effective_float"]
    base["mean_price"] = sum(prices) / len(prices)
    base["wood_price"] = base["mean_price"]
    base["monthly_total_wood"] = [m["total_wood_locked"] for m in months]
    return base


def binding_tvl(p, threshold_frac=None, basis="float", wood_price=None):
    """TVL at which required WOOD lockup crosses `threshold_frac` of supply.

    Every leg is linear in TVL (the min-stake and owner-bond floors scale with
    fund count, which is itself linear in TVL), so one reference evaluation is
    exact. With a price path this uses the worst month.
    """
    threshold_frac = p.flywheel_threshold if threshold_frac is None else threshold_frac
    if wood_price is None:
        wood_price = min(p.price_months())
    ref = 100_000_000.0
    wd = wood_demand(p, ref, wood_price)
    supply = (p.assumptions.wood_float_m12 if basis == "float"
              else p.assumptions.wood_total_supply)
    return ref * threshold_frac * supply / wd["total_wood_locked"]


# ---------------------------------------------------------------------------
# The single-proposal worked case, including the fraud waterfall
# ---------------------------------------------------------------------------

def worked_proposal(p, fund_size=None, gross_move=None, duration_days=None,
                    wood_price=None, slashed=False):
    """One fund, one tier-2 proposal, full waterfall in dollars and WOOD."""
    fund_size = float(p.worked_fund_size if fund_size is None else fund_size)
    gross_move = float(p.worked_gross_move if gross_move is None else gross_move)
    duration_days = int(p.worked_duration_days if duration_days is None else duration_days)
    price = float(p.wood_price if wood_price is None else wood_price)

    cov = fund_size                    # tier 2 -> coverage == notional == fund
    dur_frac = duration_days / DAYS_PER_YEAR
    haircut_price = price * p.wood_haircut_bps / p.bps
    approvers = p.approvers_per_proposal

    assets0 = fund_size
    hwm = fund_size
    after_pnl = assets0 * (1.0 + gross_move)
    gross_pnl = after_pnl - assets0

    mgmt = assets0 * (p.mgmt_bps / p.bps) * dur_frac
    after_mgmt = after_pnl - mgmt
    perf_base = max(0.0, after_mgmt - hwm)
    perf = perf_base * (p.perf_bps / p.bps)
    assets1 = after_mgmt - perf
    takes = split_fees(mgmt, perf, p)

    proposer_bond_usd = cov * p.proposer_bond_bps / p.bps
    proposer_bond_wood = proposer_bond_usd / price
    cohort_gate_usd = cov / p.k_numerator
    cohort_gate_wood = cohort_gate_usd / haircut_price
    mult = cohort_multiplier(p)
    cohort_budget_usd = cohort_gate_usd * mult
    cohort_budget_wood = cohort_budget_usd / haircut_price
    # What ONE approver reserves: the whole coverage today, its declared share
    # under SHE-227.
    per_guardian_reserved_wood = cohort_gate_wood * (1.0 if p.reservation_mode == "full"
                                                     else 1.0 / approvers)
    # What is ALLOCATED to this proposal per approver once settleCoverage
    # collapses pro-rata: the approver's share of the coverage, either way.
    per_guardian_allocated_wood = cohort_gate_wood / approvers
    challenger_bond_usd = cov * p.challenger_bond_bps / p.bps
    challenger_bond_wood = challenger_bond_usd / price

    d = {
        "fee_set": p.fee_set,
        "reservation_mode": p.reservation_mode,
        "slash_mode": p.slash_mode,
        "fund_size": fund_size,
        "gross_move_pct": 100.0 * gross_move,
        "duration_days": duration_days,
        "approvers": approvers,
        "wood_price": price,
        "assets_after_pnl": after_pnl,
        "gross_pnl": gross_pnl,
        "mgmt_fee": mgmt,
        "assets_after_mgmt": after_mgmt,
        "perf_base_above_hwm": perf_base,
        "perf_fee": perf,
        "assets_final": assets1,
        "depositor_net": assets1 - assets0,
        "depositor_share_of_gross_pct": (100.0 * (assets1 - assets0) / gross_pnl)
                                        if gross_pnl > 0 else None,
        "hwm_before": hwm,
        "hwm_after": max(hwm, assets1),
        "take_agent": takes["agent"],
        "take_protocol": takes["protocol"],
        "take_guardian": takes["guardian"],
        "take_owner": takes["owner"],
        "coverage_usd": cov,
        "proposer_bond_usd": proposer_bond_usd,
        "proposer_bond_wood": proposer_bond_wood,
        "cohort_gate_usd": cohort_gate_usd,
        "cohort_gate_wood": cohort_gate_wood,
        "cohort_budget_usd": cohort_budget_usd,
        "cohort_budget_wood": cohort_budget_wood,
        "per_guardian_reserved_wood": per_guardian_reserved_wood,
        "per_guardian_allocated_wood": per_guardian_allocated_wood,
        "challenger_bond_usd": challenger_bond_usd,
        "challenger_bond_wood": challenger_bond_wood,
        "owner_bond_wood": p.owner_bond_wood,
    }

    if slashed:
        slash_bps = p.effective_slash_bps
        at_risk = (per_guardian_reserved_wood if p.slash_mode == "whole"
                   else per_guardian_allocated_wood)
        slashed_wood = at_risk * slash_bps / p.bps
        to_challenger = proposer_bond_wood * p.prosecutor_fee_bps / p.bps
        proposer_burn = proposer_bond_wood - to_challenger
        challenger_burn = challenger_bond_wood * p.settle_burn_bps / p.bps
        total_burn = slashed_wood + proposer_burn + challenger_burn
        d.update({
            "slash_bps": slash_bps,
            "slashed_guardians": 1,
            "slashed_wood": slashed_wood,
            "slashed_usd": slashed_wood * price,
            "slashed_pct_total_supply": 100.0 * slashed_wood
                                        / p.assumptions.wood_total_supply,
            "proposer_bond_to_challenger_wood": to_challenger,
            "proposer_bond_burned_wood": proposer_burn,
            "challenger_bond_burned_wood": challenger_burn,
            "challenger_bond_returned_wood": challenger_bond_wood - challenger_burn,
            "challenger_net_wood": to_challenger - challenger_burn,
            # the whole point: the burn pays nobody, least of all the depositor
            "total_burned_wood": total_burn,
            "total_burned_usd": total_burn * price,
            "total_burned_pct_total_supply": 100.0 * total_burn
                                              / p.assumptions.wood_total_supply,
            "paid_to_challenger_wood": to_challenger - challenger_burn,
            "paid_to_depositor_wood": 0.0,
            "paid_to_depositor_usd": 0.0,
            "paid_to_treasury_wood": 0.0,
        })
    return d


# ---------------------------------------------------------------------------
# One scenario cell
# ---------------------------------------------------------------------------

def run_cell(p):
    """Everything a scenario row reports, for one fully-resolved Params."""
    fy = run_fund_year(p)
    n_funds = p.tvl / p.avg_fund_size
    mgmt = fy["mgmt_fee"] * n_funds
    perf = fy["perf_fee"] * n_funds
    gross = fy["gross_pnl"] * n_funds
    dep = fy["depositor_net"] * n_funds
    takes = split_fees(mgmt, perf, p)
    total_fees = mgmt + perf
    wd = wood_demand_year(p)

    worked = worked_proposal(p)
    worked_slashed = worked_proposal(p, slashed=True)

    return {
        "label": p.label,
        "stage": p.stage,
        "fee_set": p.fee_set,
        "fee_label": p.fee_label,
        "mgmt_bps": p.mgmt_bps,
        "perf_bps": p.perf_bps,
        "tvl": p.tvl,
        "wood_price": wd["wood_price"],
        "wood_price_path": wd.get("price_path"),
        "approvers": p.approvers_per_proposal,
        "tier2_share": p.tier2_share,
        "proposals_per_fund_year": p.proposals_per_fund_year,
        "strategy_duration_days": p.strategy_duration_days,
        "reservation_mode": p.reservation_mode,
        "slash_mode": p.slash_mode,
        "n_funds": n_funds,

        # --- returns and fees ---
        "gross_return_usd": gross,
        "gross_return_pct_tvl": 100.0 * gross / p.tvl,
        "mgmt_fee_usd": mgmt,
        "perf_fee_usd": perf,
        "total_fee_usd": total_fees,
        "fee_pct_of_gross": (100.0 * total_fees / gross) if gross > 0 else float("nan"),
        "depositor_net_usd": dep,
        "depositor_share_of_gross_pct": (100.0 * dep / gross) if gross > 0 else float("nan"),
        "deployed_frac_of_year": fy["deployed_frac_of_year"],
        "settlements": fy["settlements"],
        "settlements_charging_perf": fy["settlements_charging_perf"],

        # --- who earns what ---
        "agent_usd": takes["agent"],
        "guardian_usd": takes["guardian"],
        "protocol_usd": takes["protocol"],
        "owner_usd": takes["owner"],
        "agent_pct_tvl": 100.0 * takes["agent"] / p.tvl,
        "guardian_pool_pct_tvl": 100.0 * takes["guardian"] / p.tvl,
        "protocol_rev_pct_tvl": 100.0 * takes["protocol"] / p.tvl,
        "owner_pct_tvl": 100.0 * takes["owner"] / p.tvl,
        "all_fees_pct_tvl": 100.0 * total_fees / p.tvl,

        # --- WOOD ---
        "wood": wd,
        "wood_locked_total": wd["total_wood_locked"],
        "wood_pct_supply": wd["pct_total_supply"],
        "wood_pct_float": wd["pct_effective_float"],
        "stake_multiple_x_coverage": wd["stake_multiple_x_coverage"],
        "open_coverage_usd": wd["open_coverage_usd"],
        "coverage_factor_pct": 100.0 * wd["coverage_factor"],

        # --- where the flywheel binds ---
        "binding_tvl_10pct_float": binding_tvl(p, 0.10),
        "binding_tvl_25pct_float": binding_tvl(p, 0.25),
        "binding_tvl_50pct_float": binding_tvl(p, 0.50),
        "binding_tvl_25pct_supply": binding_tvl(p, 0.25, basis="total"),

        # --- worked single proposal + fraud waterfall ---
        "worked": worked,
        "worked_slashed": worked_slashed,
    }


def make_params(proto, assumptions, overrides, label=None):
    return Params(proto, assumptions, overrides, label=label)


__all__ = [
    "Params", "make_params", "load", "coverage_factor", "per_settlement_moves",
    "settlement_order", "run_fund_year", "split_fees", "wood_demand",
    "wood_demand_year", "binding_tvl", "worked_proposal", "run_cell",
    "cohort_multiplier", "RESERVATION_MODES", "SLASH_MODES", "OVERRIDABLE",
]
