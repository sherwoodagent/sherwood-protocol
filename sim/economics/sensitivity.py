#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""SHE-182 -- one-at-a-time tornado sweeps around the growth baseline.

For each metric, every input is moved on its own with everything else held at
the baseline, and the inputs are ranked by the spread they produce. Continuous
inputs move +/-50%; discrete ones move across their real ladder (the approver
count, the mechanism toggles), because +/-50% of "5 approvers" is not a thing
the protocol can be set to.

OAT is deliberately the crude method: it cannot see interactions, and where two
inputs multiply (approvers x tier-2 share, cadence x duration) the true joint
effect is larger than either bar. It is here to rank levers, not to size them.
"""

from model import Params, binding_tvl, run_cell

BASELINE = {"stage": "growth", "tvl": 10_000_000.0, "wood_price": 0.05,
            "fee_set": "current"}

# name -> (attribute, kind, spec)
#   "pct"    : multiply by 1 -/+ frac, optionally clamped
#   "ladder" : walk an explicit list of values
SWEEPS = [
    ("WOOD price", "wood_price", "pct", None),
    ("tier-2 share", "tier2_share", "pct", (0.0, 1.0)),
    ("proposals / fund / yr", "proposals_per_fund_year", "pct", (1, None)),
    ("strategy duration (d)", "strategy_duration_days", "pct", (1, None)),
    ("proposal size / fund", "proposal_frac_of_fund", "pct", (0.0, 1.0)),
    ("avg fund size", "avg_fund_size", "pct", None),
    ("gross return", "gross_return_annual", "pct", None),
    ("win rate", "frac_profitable", "pct", (0.05, 0.95)),
    ("loss ratio", "loss_ratio", "pct", (0.0, None)),
    ("challenge rate", "challenge_rate", "pct", (0.0, 1.0)),
    ("management fee bps", "mgmt_bps", "pct", (0, None)),
    ("performance fee bps", "perf_bps", "pct", (0, None)),
    ("WOOD haircut bps", "wood_haircut_bps", "pct", (1, 10_000)),
    ("certified bound bps", "certified_bound_bps", "pct", (1, 9999)),
    ("proposer bond bps", "proposer_bond_bps", "pct", (0, None)),
    ("challenger bond bps", "challenger_bond_bps", "pct", (0, None)),
    ("epoch length (d)", "epoch_length_days", "pct", (1, None)),
    ("challenge window (d)", "challenge_window_days", "pct", (1, None)),
    ("approvers", "approvers_per_proposal", "ladder", [3, 5, 7, 10]),
    ("reservation_mode", "reservation_mode", "ladder", ["full", "shared"]),
    ("slash_mode", "slash_mode", "ladder", ["whole", "allocated"]),
]

METRICS = [
    ("depositor_share_of_gross_pct", "depositor share of gross (%)", "%.2f%%"),
    ("guardian_pool_pct_tvl", "guardian pool (% of TVL/yr)", "%.4f%%"),
    ("binding_tvl_25pct_float", "binding TVL @ 25% of float ($)", "$%.0f"),
]

FRAC = 0.50


def _metric(p, key):
    if key == "binding_tvl_25pct_float":
        return binding_tvl(p, 0.25)
    return run_cell(p)[key]


def _clamp(v, bounds):
    if not bounds:
        return v
    lo, hi = bounds
    if lo is not None:
        v = max(lo, v)
    if hi is not None:
        v = min(hi, v)
    return v


def _vary(base, attr, kind, spec):
    """Yield (variant_label, Params) for one input."""
    cur = getattr(base, attr)
    if kind == "pct":
        for sign, tag in ((-FRAC, "-50%"), (FRAC, "+50%")):
            new = cur * (1.0 + sign)
            if isinstance(cur, int) and attr not in ("wood_price",):
                new = int(round(new))
            new = _clamp(new, spec)
            if new == cur:
                continue
            yield ("%s (%s)" % (_fmt(new), tag), base.copy(**{attr: new}))
    else:
        for v in spec:
            if v == cur:
                continue
            yield (str(v), base.copy(**{attr: v}))


def _fmt(v):
    if isinstance(v, float):
        return ("%.5f" % v).rstrip("0").rstrip(".")
    return str(v)


def tornado(proto, assumptions, baseline=None):
    """Ranked OAT sweeps for every metric. Returns a list of metric blocks."""
    base = Params(proto, assumptions, dict(baseline or BASELINE),
                  label="growth baseline")
    out = []
    for key, title, fmt in METRICS:
        base_val = _metric(base, key)
        rows = []
        for label, attr, kind, spec in SWEEPS:
            # The baseline is always in the point set. That keeps the bar honest
            # when one side of a sweep is infeasible (a win rate cut by half
            # cannot produce a positive annual return, for instance) instead of
            # collapsing the spread to zero.
            pts = [("baseline", base_val)]
            infeasible = []
            for vlabel, variant in _vary(base, attr, kind, spec):
                try:
                    pts.append((vlabel, _metric(variant, key)))
                except ValueError as exc:
                    infeasible.append({"variant": vlabel, "why": str(exc)})
            if len(pts) == 1:
                continue
            vals = [v for _, v in pts]
            lo, hi = min(vals), max(vals)
            lo_label = [l for l, v in pts if v == lo][0]
            hi_label = [l for l, v in pts if v == hi][0]
            spread = hi - lo
            rows.append({
                "input": label,
                "attr": attr,
                "kind": kind,
                "low": lo, "low_at": lo_label,
                "high": hi, "high_at": hi_label,
                "spread": spread,
                "spread_pct_of_base": (100.0 * spread / abs(base_val)) if base_val else None,
                "points": [{"variant": l, "value": v} for l, v in pts],
                "infeasible": infeasible,
            })
        rows.sort(key=lambda r: abs(r["spread"]), reverse=True)
        for i, r in enumerate(rows, 1):
            r["rank"] = i
        out.append({
            "metric": key,
            "title": title,
            "fmt": fmt,
            "baseline_value": base_val,
            "baseline": dict(baseline or BASELINE),
            "rows": rows,
        })
    return out


def format_block(block, top=None):
    rows = block["rows"][:top] if top else block["rows"]
    fmt = block["fmt"]
    head = ["#", "input", "low", "at", "high", "at", "spread", "% of base"]
    body = []
    for r in rows:
        body.append([
            str(r["rank"]), r["input"],
            fmt % r["low"], r["low_at"],
            fmt % r["high"], r["high_at"],
            fmt % r["spread"],
            "-" if r["spread_pct_of_base"] is None else "%.1f%%" % r["spread_pct_of_base"],
        ])
    widths = [max(len(h), *(len(b[i]) for b in body)) if body else len(h)
              for i, h in enumerate(head)]
    lines = ["%s  (baseline %s)" % (block["title"], fmt % block["baseline_value"]), ""]

    def render(vals):
        return "  ".join(v.ljust(widths[i]) if i in (1, 3, 5) else v.rjust(widths[i])
                         for i, v in enumerate(vals))

    lines.append(render(head))
    lines.append("  ".join("-" * w for w in widths))
    for b in body:
        lines.append(render(b))
    return "\n".join(lines)


if __name__ == "__main__":
    from model import load
    proto, assumptions = load()
    for block in tornado(proto, assumptions):
        print(format_block(block))
        print()
