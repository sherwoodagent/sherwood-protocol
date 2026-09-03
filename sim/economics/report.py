#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""SHE-182 -- render the scenario run to out/report.md, out/report.html, out/results.json.

The HTML is a single self-contained file: no external stylesheet, no external
script, no web fonts, no image files. Charts are inline SVG built here. It
follows the viewer's light/dark preference through CSS custom properties, keeps
all text in ink colours, and uses the series palette only on marks -- with a
legend on every chart that has more than one series.
"""

import datetime
import json
import math
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.join(HERE, "out")


# ---------------------------------------------------------------------------
# formatting
# ---------------------------------------------------------------------------

def usd(x):
    if x is None or (isinstance(x, float) and math.isnan(x)):
        return "-"
    a = abs(x)
    sign = "-" if x < 0 else ""
    if a >= 1e9:
        return "%s$%.2fB" % (sign, a / 1e9)
    if a >= 1e6:
        return "%s$%.2fM" % (sign, a / 1e6)
    if a >= 1e3:
        return "%s$%.1fk" % (sign, a / 1e3)
    return "%s$%.2f" % (sign, a)


def wood(x):
    if x is None:
        return "-"
    a = abs(x)
    if a >= 1e9:
        return "%.2fB" % (a / 1e9)
    if a >= 1e6:
        return "%.2fM" % (a / 1e6)
    if a >= 1e3:
        return "%.1fk" % (a / 1e3)
    return "%.0f" % a


def pct(x, dp=1):
    if x is None or (isinstance(x, float) and math.isnan(x)):
        return "-"
    return ("%." + str(dp) + "f%%") % x


def price(x):
    return "$%.5f" % x


def md_table(headers, rows):
    out = ["| " + " | ".join(str(h) for h in headers) + " |",
           "|" + "|".join(["---"] * len(headers)) + "|"]
    for r in rows:
        out.append("| " + " | ".join("" if c is None else str(c) for c in r) + " |")
    return "\n".join(out)


def esc(s):
    return (str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
            .replace('"', "&quot;"))


# ---------------------------------------------------------------------------
# table shapes shared by both renderers
# ---------------------------------------------------------------------------

_TRAILING_FEE_PAIR = re.compile(r"\s+\d{1,5}\s*/\s*\d{1,5}\s*$")


def cell_label(row):
    """The row label, with any fee pair in it RE-RENDERED from the resolved
    fees. A scenario file that writes "post-audit ceilings 500/3000" into a
    label keeps saying 500/3000 after the constants it names have moved, and
    the report then prints the new economics under the old heading (review of
    #294). A label that names no fee pair is returned untouched."""
    base = _TRAILING_FEE_PAIR.sub("", row["label"])
    if base == row["label"]:
        return base
    return "%s %d/%d" % (base, row["mgmt_bps"], row["perf_bps"])


HEADLINE_HEADERS = ["scenario", "ticket", "cells", "depositor share of gross",
                    "guardian pool %TVL", "WOOD locked (%float)",
                    "binding TVL @25% float", "stake multiple", "what it moves"]


def _rng(vals, fmt):
    lo, hi = min(vals), max(vals)
    if abs(hi - lo) < 1e-9:
        return fmt(lo)
    return "%s - %s" % (fmt(lo), fmt(hi))


def _moved_by(sc):
    """Which reported quantity this scenario actually separates."""
    rows = sc["rows"]
    if len(rows) < 2:
        return "single reference cell"
    moves = []
    checks = [("depositor share", "depositor_share_of_gross_pct", 0.05),
              ("guardian pool", "guardian_pool_pct_tvl", 0.001),
              ("WOOD locked", "wood_locked_total", 1.0),
              ("binding TVL", "binding_tvl_25pct_float", 1.0),
              ("slash size", None, None)]
    for label, key, tol in checks:
        if key is None:
            vals = [r["worked_slashed"]["slashed_wood"] for r in rows]
            if max(vals) - min(vals) > 1.0:
                moves.append(label)
            continue
        vals = [r[key] for r in rows]
        if max(vals) - min(vals) > tol:
            moves.append(label)
    return ", ".join(moves) if moves else "nothing (cells agree)"


def headline_rows(scenarios):
    rows = []
    for sc in scenarios:
        rs = sc["rows"]
        rows.append([
            sc["name"],
            sc["ticket"] or "-",
            len(rs),
            _rng([r["depositor_share_of_gross_pct"] for r in rs], lambda v: pct(v, 1)),
            _rng([r["guardian_pool_pct_tvl"] for r in rs], lambda v: pct(v, 3)),
            _rng([r["wood_pct_float"] for r in rs], lambda v: pct(v, 1)),
            _rng([r["binding_tvl_25pct_float"] for r in rs], usd),
            _rng([r["stake_multiple_x_coverage"] for r in rs], lambda v: "%.2fx" % v),
            _moved_by(sc),
        ])
    return rows


CELL_HEADERS = ["cell", "stage", "fees", "WOOD $", "gross", "mgmt", "perf",
                "depositor", "dep/gross", "agent", "guardians", "protocol", "owner",
                "guard %TVL", "WOOD locked", "%supply", "%float", "stake x",
                "bind@10%", "bind@25%", "bind@50%"]


def cell_rows(sc):
    rows = []
    for r in sc["rows"]:
        rows.append([
            cell_label(r), r["stage"], "%d/%d" % (r["mgmt_bps"], r["perf_bps"]),
            price(r["wood_price"]),
            usd(r["gross_return_usd"]), usd(r["mgmt_fee_usd"]), usd(r["perf_fee_usd"]),
            usd(r["depositor_net_usd"]), pct(r["depositor_share_of_gross_pct"]),
            usd(r["agent_usd"]), usd(r["guardian_usd"]), usd(r["protocol_usd"]),
            usd(r["owner_usd"]),
            pct(r["guardian_pool_pct_tvl"], 3),
            wood(r["wood_locked_total"]), pct(r["wood_pct_supply"], 2),
            pct(r["wood_pct_float"], 2), "%.2fx" % r["stake_multiple_x_coverage"],
            usd(r["binding_tvl_10pct_float"]), usd(r["binding_tvl_25pct_float"]),
            usd(r["binding_tvl_50pct_float"]),
        ])
    return rows


WOOD_LEG_HEADERS = ["cell", "open coverage", "proposer bonds", "guardian stake",
                    "challenge bonds", "owner bonds", "TOTAL WOOD", "TOTAL USD",
                    "floor binds?"]


def wood_leg_rows(sc):
    rows = []
    for r in sc["rows"]:
        w = r["wood"]
        rows.append([
            cell_label(r), usd(w["open_coverage_usd"]), wood(w["proposer_bond_wood"]),
            wood(w["guardian_stake_wood"]), wood(w["challenge_bond_wood"]),
            wood(w["owner_bond_wood"]), wood(w["total_wood_locked"]),
            usd(w["total_usd_locked"]), "yes" if w["stake_floor_binds"] else "",
        ])
    return rows


FRAUD_HEADERS = ["cell", "slash mode", "coverage", "guardian slashed (WOOD)",
                 "burned total (WOOD)", "burned (USD)", "to challenger (WOOD)",
                 "to depositor"]


def fraud_rows(sc):
    rows = []
    for r in sc["rows"]:
        w = r["worked_slashed"]
        rows.append([
            cell_label(r), r["slash_mode"], usd(w["coverage_usd"]),
            wood(w["slashed_wood"]), wood(w["total_burned_wood"]),
            usd(w["total_burned_usd"]), wood(w["paid_to_challenger_wood"]),
            usd(w["paid_to_depositor_usd"]),
        ])
    return rows


# ---------------------------------------------------------------------------
# Markdown
# ---------------------------------------------------------------------------

def render_md(payload):
    d = payload
    L = []
    a = L.append
    a("# SHE-182 - protocol economics scenario run")
    a("")
    a("Generated by `sim/economics/run.py` on %s. Constants are read from the Solidity "
      "source at run time; nothing in the model is a hard-coded protocol number."
      % d["generated_at"])
    a("")

    # --- 1. drift -----------------------------------------------------------
    a("## 1. What changed vs the lock")
    a("")
    if d["drift"]:
        a("**%d constant(s) drifted.** The economics below were computed from the LIVE "
          "source, not from `constants.lock.json`." % len(d["drift"]))
        a("")
        a(md_table(["constant", "change", "lock", "source", "where"],
                   [[x["name"], x["kind"], x["old"], x["new"], "`%s`" % x["where"]]
                    for x in d["drift"]]))
        a("")
        a("If the change is intended, re-run `python3 sim/economics/extract_constants.py "
          "--write` and commit the new lock in the same PR as the Solidity change.")
    else:
        a("No drift. Every constant the model reads matches `constants.lock.json`.")
    if d["moved"]:
        a("")
        a("Advisory - unchanged values that moved in the source:")
        a("")
        a(md_table(["constant", "value", "was", "now"],
                   [[m["name"], m["value"], "`%s`" % m["from"], "`%s`" % m["to"]]
                    for m in d["moved"]]))
    a("")

    # --- 2. headline --------------------------------------------------------
    a("## 2. Headline - every scenario on one screen")
    a("")
    a(md_table(HEADLINE_HEADERS, headline_rows(d["scenarios"])))
    a("")
    a("Ranges are across the cells of that scenario. `stake multiple` is the staked-WOOD "
      "face value required per $1 of open coverage: `approvers / haircut / k` today, "
      "`1 / haircut / k` under SHE-227. It is price-invariant.")
    a("")

    # --- 3. per scenario ----------------------------------------------------
    a("## 3. Scenarios")
    a("")
    for sc in d["scenarios"]:
        a("### %s - %s" % (sc["name"], sc["title"]))
        a("")
        if sc["ticket"]:
            a("**Ticket:** %s  " % sc["ticket"])
        if sc["question"]:
            a("**Question:** %s" % sc["question"])
        a("")
        if sc["note"]:
            a("> %s" % sc["note"])
            a("")
        a(md_table(CELL_HEADERS, cell_rows(sc)))
        a("")
        a("WOOD locked by leg:")
        a("")
        a(md_table(WOOD_LEG_HEADERS, wood_leg_rows(sc)))
        a("")
        a("Fraud waterfall, one convicted approver on the worked single proposal "
          "(%s fund, %d days, tier 2):"
          % (usd(sc["rows"][0]["worked"]["fund_size"]),
             sc["rows"][0]["worked"]["duration_days"]))
        a("")
        a(md_table(FRAUD_HEADERS, fraud_rows(sc)))
        a("")
        a("The depositor column is $0 in every row and every scenario. The slash is a "
          "deterrent, not insurance: 100% of it goes to `0x...dEaD`, WOOD has no `burn()`, "
          "and there is no treasury path on any outcome.")
        a("")

    # --- 4. worked proposal -------------------------------------------------
    a("## 4. Worked single proposal")
    a("")
    w = d["worked"]["gain"]
    a("A %s fund, one %d-day tier-2 proposal, %d approvers, WOOD at %s, current fees "
      "(%d/%d)." % (usd(w["fund_size"]), w["duration_days"], w["approvers"],
                    price(w["wood_price"]), d["worked"]["mgmt_bps"],
                    d["worked"]["perf_bps"]))
    a("")
    a(md_table(["step", "gain +10%", "loss -5%"],
               [["start assets", usd(w["fund_size"]),
                 usd(d["worked"]["loss"]["fund_size"])],
                ["after strategy P&L", usd(w["assets_after_pnl"]),
                 usd(d["worked"]["loss"]["assets_after_pnl"])],
                ["- management fee", usd(-w["mgmt_fee"]),
                 usd(-d["worked"]["loss"]["mgmt_fee"])],
                ["= after mgmt", usd(w["assets_after_mgmt"]),
                 usd(d["worked"]["loss"]["assets_after_mgmt"])],
                ["above high-water mark", usd(w["perf_base_above_hwm"]),
                 usd(d["worked"]["loss"]["perf_base_above_hwm"])],
                ["- performance fee", usd(-w["perf_fee"]),
                 usd(-d["worked"]["loss"]["perf_fee"])],
                ["**= depositor assets**", "**%s**" % usd(w["assets_final"]),
                 "**%s**" % usd(d["worked"]["loss"]["assets_final"])],
                ["agent", usd(w["take_agent"]), usd(d["worked"]["loss"]["take_agent"])],
                ["protocol", usd(w["take_protocol"]),
                 usd(d["worked"]["loss"]["take_protocol"])],
                ["guardians", usd(w["take_guardian"]),
                 usd(d["worked"]["loss"]["take_guardian"])],
                ["vault owner", usd(w["take_owner"]),
                 usd(d["worked"]["loss"]["take_owner"])]]))
    a("")
    s = d["worked"]["slashed"]
    a("If a guardian is convicted on that same proposal, the depositor waterfall is "
      "byte-identical and the WOOD side reads:")
    a("")
    a(md_table(["item", "WOOD", "USD"],
               [["guardian stake slashed (100% burned)", wood(s["slashed_wood"]),
                 usd(s["slashed_usd"])],
                ["proposer bond burned", wood(s["proposer_bond_burned_wood"]),
                 usd(s["proposer_bond_burned_wood"] * s["wood_price"])],
                ["challenger bond burned", wood(s["challenger_bond_burned_wood"]),
                 usd(s["challenger_bond_burned_wood"] * s["wood_price"])],
                ["**total burned**", "**%s**" % wood(s["total_burned_wood"]),
                 "**%s**" % usd(s["total_burned_usd"])],
                ["net to challenger", wood(s["paid_to_challenger_wood"]),
                 usd(s["paid_to_challenger_wood"] * s["wood_price"])],
                ["**net to depositor**", "**0**", "**$0.00**"]]))
    a("")

    # --- 5. sensitivity -----------------------------------------------------
    a("## 5. Sensitivity - one-at-a-time tornado")
    a("")
    a("Around the growth baseline. Continuous inputs move +/-50%; the approver count and "
      "the two mechanism toggles move across their real ladder. The baseline is always in "
      "the point set, so a bar stays honest when one side of a sweep is infeasible.")
    a("")
    for block in d["sensitivity"]:
        a("### %s" % block["title"])
        a("")
        a("Baseline: **%s**" % (block["fmt"] % block["baseline_value"]))
        a("")
        rows = []
        for r in block["rows"]:
            rows.append([r["rank"], r["input"], block["fmt"] % r["low"], r["low_at"],
                         block["fmt"] % r["high"], r["high_at"],
                         block["fmt"] % r["spread"],
                         "-" if r["spread_pct_of_base"] is None
                         else pct(r["spread_pct_of_base"])])
        a(md_table(["#", "input", "low", "at", "high", "at", "spread", "% of base"], rows))
        a("")
        infeas = [(r["input"], i) for r in block["rows"] for i in r["infeasible"]]
        if infeas:
            a("Infeasible variants (excluded from the bar, baseline used instead):")
            a("")
            for name, i in infeas:
                a("- `%s` at %s: %s" % (name, i["variant"], i["why"]))
            a("")
    a("OAT cannot see interactions. Where two inputs multiply -- approvers x tier-2 share, "
      "cadence x duration -- the joint effect is larger than either bar. And a +/-50% move "
      "around a 40% tier-2 share badly understates certification: the `certified-adapters` "
      "scenario runs the real extremes and finds a 200:1 coverage reduction.")
    a("")

    # --- 6. constants -------------------------------------------------------
    a("## 6. Constants read from source")
    a("")
    a(md_table(["constant", "value", "source", "note"],
               [[n, v, "`%s`" % w_, note] for n, v, w_, note in d["constants"]]))
    a("")
    a("## 7. Assumptions (not code facts)")
    a("")
    a("Nothing in this section is extracted from Solidity and nothing here is drift-checked.")
    a("")
    a(md_table(["assumption", "value", "source", "kind", "note"],
               [[k, v, ("`%s`" % s) if s != "none" else "_none_", kind, note]
                for k, v, s, kind, note in d["assumptions"]]))
    a("")
    a("Stage profiles (fund size, cadence, proposal size, tier-2 share, approvers, return, "
      "win rate) are invented for this model and live in `assumptions.json`. The ratios the "
      "model reports are far more robust than the absolute dollars.")
    a("")
    a("See `sim/economics/README.md` for the full caveats list.")
    a("")
    return "\n".join(L)


# ---------------------------------------------------------------------------
# SVG charts
# ---------------------------------------------------------------------------

SERIES = ["var(--s1)", "var(--s2)", "var(--s3)", "var(--s4)", "var(--s5)"]


def _legend(items, x, y, width):
    """items: [(label, colour)]. Wraps across the chart width."""
    out = []
    cx, cy = x, y
    for label, colour in items:
        w = 12 + 7 * len(label) + 18
        if cx + w > x + width and cx > x:
            cx, cy = x, cy + 18
        out.append('<rect x="%d" y="%d" width="10" height="10" rx="2" fill="%s"/>'
                   % (cx, cy - 9, colour))
        out.append('<text class="lgd" x="%d" y="%d">%s</text>'
                   % (cx + 15, cy, esc(label)))
        cx += w
    return "\n".join(out), cy + 12


CHAR_PX = 6.2   # approximate advance width of the 11.5px UI sans at these sizes


def _fit_labels(labels, max_px, min_px=140):
    """Truncate row labels to fit the gutter, and size the gutter to the content.

    Returns (labels, gutter_px). SVG has no text metrics at build time, so this
    estimates from character count -- deliberately generous, because a clipped
    axis label is a worse failure than a little whitespace.
    """
    max_chars = int(max_px / CHAR_PX)
    out = []
    for l in labels:
        l = str(l)
        out.append(l if len(l) <= max_chars else l[:max_chars - 1].rstrip() + "…")
    longest = max((len(l) for l in out), default=0)
    return out, int(max(min_px, min(max_px, longest * CHAR_PX + 16)))


def stacked_bar_chart(title, row_labels, series_labels, matrix, unit="%"):
    """Horizontal 100%-stacked bars. matrix[row][series] in the same unit."""
    row_labels, pad_l = _fit_labels(row_labels, 260, min_px=170)
    pad_r, pad_t = 20, 8
    bar_h, gap = 20, 10
    plot_w = 520
    legend_svg, legend_bottom = _legend(list(zip(series_labels, SERIES)), pad_l, pad_t + 12,
                                        plot_w)
    top = legend_bottom + 10
    height = top + len(row_labels) * (bar_h + gap) + 26
    width = pad_l + plot_w + pad_r

    parts = ['<svg viewBox="0 0 %d %d" role="img" aria-label="%s" '
             'xmlns="http://www.w3.org/2000/svg">' % (width, height, esc(title)),
             legend_svg]
    for i, label in enumerate(row_labels):
        y = top + i * (bar_h + gap)
        parts.append('<text class="ylab" x="%d" y="%d">%s</text>'
                     % (pad_l - 10, y + bar_h - 6, esc(label)))
        total = sum(matrix[i]) or 1.0
        x = pad_l
        for j, v in enumerate(matrix[i]):
            w = plot_w * v / total
            if w <= 0:
                continue
            parts.append('<rect x="%.2f" y="%d" width="%.2f" height="%d" fill="%s">'
                         '<title>%s - %s: %.2f%s</title></rect>'
                         % (x, y, w, bar_h, SERIES[j % len(SERIES)],
                            esc(label), esc(series_labels[j]), v, unit))
            if w > 34:
                parts.append('<text class="inbar" x="%.2f" y="%d">%.0f%s</text>'
                             % (x + w / 2, y + bar_h - 6, v, unit))
            x += w
    parts.append('<line class="axis" x1="%d" y1="%d" x2="%d" y2="%d"/>'
                 % (pad_l, top - 4, pad_l, top + len(row_labels) * (bar_h + gap) - gap + 4))
    parts.append('<text class="xlab" x="%d" y="%d">share of gross profit (%%)</text>'
                 % (pad_l, height - 8))
    parts.append("</svg>")
    return "\n".join(parts)


def log_bar_chart(title, row_labels, values, ref=None, ref_label=None, fmt=usd):
    """Horizontal bars on a log10 scale -- binding TVL spans two orders of magnitude."""
    row_labels, pad_l = _fit_labels(row_labels, 330, min_px=200)
    pad_r, pad_t = 92, 22
    bar_h, gap = 18, 8
    plot_w = 460
    vals = [max(v, 1.0) for v in values]
    lo = math.log10(min(vals)) - 0.15
    hi = math.log10(max(vals)) + 0.15
    span = max(hi - lo, 1e-9)
    height = pad_t + len(row_labels) * (bar_h + gap) + 30
    width = pad_l + plot_w + pad_r

    def x_of(v):
        return pad_l + plot_w * (math.log10(max(v, 1.0)) - lo) / span

    parts = ['<svg viewBox="0 0 %d %d" role="img" aria-label="%s" '
             'xmlns="http://www.w3.org/2000/svg">' % (width, height, esc(title))]
    # decade gridlines
    d0, d1 = int(math.floor(lo)), int(math.ceil(hi))
    for d in range(d0, d1 + 1):
        v = 10.0 ** d
        if not (lo <= d <= hi):
            continue
        x = x_of(v)
        parts.append('<line class="grid" x1="%.2f" y1="%d" x2="%.2f" y2="%d"/>'
                     % (x, pad_t - 6, x, pad_t + len(row_labels) * (bar_h + gap) - gap))
        parts.append('<text class="tick" x="%.2f" y="%d">%s</text>'
                     % (x, pad_t - 10, esc(fmt(v))))
    for i, label in enumerate(row_labels):
        y = pad_t + i * (bar_h + gap)
        v = values[i]
        parts.append('<text class="ylab" x="%d" y="%d">%s</text>'
                     % (pad_l - 10, y + bar_h - 5, esc(label)))
        parts.append('<rect x="%d" y="%d" width="%.2f" height="%d" rx="2" fill="%s">'
                     '<title>%s: %s</title></rect>'
                     % (pad_l, y, max(x_of(v) - pad_l, 1.0), bar_h, SERIES[0],
                        esc(label), esc(fmt(v))))
        parts.append('<text class="val" x="%.2f" y="%d">%s</text>'
                     % (x_of(v) + 6, y + bar_h - 5, esc(fmt(v))))
    if ref is not None:
        x = x_of(ref)
        parts.append('<line class="ref" x1="%.2f" y1="%d" x2="%.2f" y2="%d"/>'
                     % (x, pad_t - 6, x, pad_t + len(row_labels) * (bar_h + gap) - gap))
        parts.append('<text class="tick" x="%.2f" y="%d">%s</text>'
                     % (x, pad_t + len(row_labels) * (bar_h + gap) + 6,
                        esc(ref_label or "baseline")))
    parts.append("</svg>")
    return "\n".join(parts)


def tornado_chart(title, block, top=10, log=False):
    """Diverging bars around the baseline. Two series: low side and high side."""
    rows = block["rows"][:top]
    base = block["baseline_value"]
    # Chart marks get the compact formatter; the tables keep full precision.
    fmt = ((lambda v: usd(v)) if block["metric"].startswith("binding_tvl")
           else (lambda v: block["fmt"] % v))
    input_labels, pad_l = _fit_labels([r["input"] for r in rows], 220, min_px=150)
    pad_r = 130
    bar_h, gap = 18, 9
    plot_w = 420

    def t(v):
        return math.log10(max(v, 1.0)) if log else v

    tb = t(base)
    lows = [t(r["low"]) for r in rows] or [tb]
    highs = [t(r["high"]) for r in rows] or [tb]
    lo, hi = min(lows + [tb]), max(highs + [tb])
    pad = (hi - lo) * 0.08 or 1.0
    lo, hi = lo - pad, hi + pad
    span = hi - lo

    legend_svg, legend_bottom = _legend(
        [("below baseline", SERIES[1]), ("above baseline", SERIES[0])], pad_l, 14, plot_w)
    top_y = legend_bottom + 8
    height = top_y + len(rows) * (bar_h + gap) + 26
    width = pad_l + plot_w + pad_r

    def x_of(v):
        return pad_l + plot_w * (t(v) - lo) / span

    xb = pad_l + plot_w * (tb - lo) / span
    parts = ['<svg viewBox="0 0 %d %d" role="img" aria-label="%s" '
             'xmlns="http://www.w3.org/2000/svg">' % (width, height, esc(title)),
             legend_svg]
    for i, r in enumerate(rows):
        y = top_y + i * (bar_h + gap)
        parts.append('<text class="ylab" x="%d" y="%d">%s</text>'
                     % (pad_l - 10, y + bar_h - 5, esc(input_labels[i])))
        xl, xh = x_of(r["low"]), x_of(r["high"])
        if xl < xb:
            parts.append('<rect x="%.2f" y="%d" width="%.2f" height="%d" fill="%s">'
                         '<title>%s low: %s at %s</title></rect>'
                         % (xl, y, xb - xl, bar_h, SERIES[1], esc(r["input"]),
                            fmt(r["low"]), esc(r["low_at"])))
        if xh > xb:
            parts.append('<rect x="%.2f" y="%d" width="%.2f" height="%d" fill="%s">'
                         '<title>%s high: %s at %s</title></rect>'
                         % (xb, y, xh - xb, bar_h, SERIES[0], esc(r["input"]),
                            fmt(r["high"]), esc(r["high_at"])))
        parts.append('<text class="val" x="%.2f" y="%d">%s</text>'
                     % (max(xh, xb) + 6, y + bar_h - 5, esc(fmt(r["spread"]))))
    parts.append('<line class="ref" x1="%.2f" y1="%d" x2="%.2f" y2="%d"/>'
                 % (xb, top_y - 5, xb, top_y + len(rows) * (bar_h + gap) - gap + 3))
    parts.append('<text class="tick" x="%.2f" y="%d">baseline %s</text>'
                 % (xb, height - 8, esc(fmt(base))))
    parts.append("</svg>")
    return "\n".join(parts)


CSS = """
:root {
  color-scheme: light dark;
  --bg: #fbfaf8;
  --panel: #ffffff;
  --ink: #16181d;
  --ink-2: #4a505c;
  --ink-3: #767d8b;
  --rule: #e2e0db;
  --rule-2: #cfcdc7;
  --accent: #8a5a00;
  --warn-bg: #fdf3e3;
  --warn-ink: #7a4b00;
  --ok-bg: #eef5ee;
  --ok-ink: #2f5734;
  --s1: #3f6fd8;
  --s2: #d4772b;
  --s3: #3f9e86;
  --s4: #9a6bc4;
  --s5: #c05a76;
  --mono: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #14161a;
    --panel: #1b1e24;
    --ink: #e8e9ec;
    --ink-2: #b3b8c2;
    --ink-3: #868d99;
    --rule: #2a2e36;
    --rule-2: #3a404a;
    --accent: #e0a94b;
    --warn-bg: #2c2317;
    --warn-ink: #e6bf7a;
    --ok-bg: #1a251c;
    --ok-ink: #86c294;
    --s1: #7aa2f7;
    --s2: #e8a35c;
    --s3: #6fc9ae;
    --s4: #bb96e0;
    --s5: #e08098;
  }
}
* { box-sizing: border-box; }
body {
  margin: 0; background: var(--bg); color: var(--ink);
  font: 15px/1.55 ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
  -webkit-text-size-adjust: 100%;
}
.wrap { max-width: 1180px; margin: 0 auto; padding: 40px 24px 80px; }
h1 { font-size: 26px; line-height: 1.2; margin: 0 0 6px; letter-spacing: -0.01em; }
h2 { font-size: 19px; margin: 44px 0 12px; padding-bottom: 6px;
     border-bottom: 1px solid var(--rule); letter-spacing: -0.005em; }
h3 { font-size: 15.5px; margin: 28px 0 6px; }
h4 { font-size: 13px; margin: 18px 0 6px; color: var(--ink-2);
     text-transform: uppercase; letter-spacing: 0.06em; }
p { margin: 8px 0; color: var(--ink-2); }
.sub { color: var(--ink-3); font-size: 13px; margin-bottom: 26px; }
code, .mono { font-family: var(--mono); font-size: 0.9em; }
.note { border-left: 3px solid var(--rule-2); padding: 2px 0 2px 14px;
        color: var(--ink-2); font-size: 13.5px; margin: 10px 0 14px; }
.banner { border-radius: 8px; padding: 12px 16px; margin: 12px 0 18px; font-size: 14px; }
.banner.ok { background: var(--ok-bg); color: var(--ok-ink); }
.banner.warn { background: var(--warn-bg); color: var(--warn-ink); }
.scroll { overflow-x: auto; margin: 10px 0 18px;
          border: 1px solid var(--rule); border-radius: 8px; background: var(--panel); }
table { border-collapse: collapse; width: 100%; font-size: 12.5px; }
th, td { padding: 7px 11px; text-align: right; white-space: nowrap;
         border-bottom: 1px solid var(--rule); }
th { font-weight: 600; color: var(--ink-2); text-align: right;
     position: sticky; top: 0; background: var(--panel); }
th:first-child, td:first-child { text-align: left; }
th:nth-child(2), td:nth-child(2) { text-align: left; }
tbody tr:last-child td { border-bottom: 0; }
tbody tr:hover td { background: color-mix(in srgb, var(--ink) 4%, transparent); }
td.l, th.l { text-align: left; }
figure { margin: 18px 0 26px; }
figcaption { color: var(--ink-3); font-size: 12.5px; margin-top: 6px; }
svg { width: 100%; height: auto; display: block; }
svg text { fill: var(--ink-2); font: 11px ui-sans-serif, system-ui, sans-serif; }
svg .ylab { text-anchor: end; fill: var(--ink); font-size: 11.5px; }
svg .val { text-anchor: start; fill: var(--ink-2); font-size: 11px;
           font-family: var(--mono); }
svg .tick { text-anchor: middle; fill: var(--ink-3); font-size: 10.5px; }
svg .lgd { fill: var(--ink-2); font-size: 11.5px; }
svg .xlab { text-anchor: start; fill: var(--ink-3); font-size: 11px; }
svg .inbar { text-anchor: middle; fill: var(--bg); font-size: 10.5px; font-weight: 600; }
svg .axis { stroke: var(--rule-2); stroke-width: 1; }
svg .grid { stroke: var(--rule); stroke-width: 1; }
svg .ref { stroke: var(--ink-3); stroke-width: 1; stroke-dasharray: 3 3; }
ul { color: var(--ink-2); font-size: 13.5px; }
"""


def _html_table(headers, rows):
    out = ['<div class="scroll"><table><thead><tr>']
    out += ["<th>%s</th>" % esc(h) for h in headers]
    out.append("</tr></thead><tbody>")
    for r in rows:
        out.append("<tr>" + "".join("<td>%s</td>" % esc("" if c is None else c)
                                    for c in r) + "</tr>")
    out.append("</tbody></table></div>")
    return "".join(out)


def render_html(payload):
    d = payload
    H = []
    a = H.append
    a("<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">")
    a('<meta name="viewport" content="width=device-width, initial-scale=1">')
    a("<title>Sherwood Scenario Report</title>")
    a("<style>%s</style></head><body><div class=\"wrap\">" % CSS)
    a("<h1>Sherwood protocol economics</h1>")
    a('<div class="sub">SHE-182 scenario run &middot; generated %s &middot; '
      'constants read from the Solidity source at run time</div>' % esc(d["generated_at"]))

    # 1 drift
    a("<h2>1. What changed vs the lock</h2>")
    if d["drift"]:
        a('<div class="banner warn"><strong>%d constant(s) drifted.</strong> '
          'The figures below were computed from the live source, not from '
          'constants.lock.json.</div>' % len(d["drift"]))
        a(_html_table(["constant", "change", "lock", "source", "where"],
                      [[x["name"], x["kind"], x["old"], x["new"], x["where"]]
                       for x in d["drift"]]))
    else:
        a('<div class="banner ok">No drift. Every constant the model reads matches '
          'constants.lock.json.</div>')
    if d["moved"]:
        a("<h4>Advisory: unchanged values that moved in the source</h4>")
        a(_html_table(["constant", "value", "was", "now"],
                      [[m["name"], m["value"], m["from"], m["to"]] for m in d["moved"]]))

    # 2 headline
    a("<h2>2. Headline &mdash; every scenario on one screen</h2>")
    a(_html_table(HEADLINE_HEADERS, headline_rows(d["scenarios"])))
    a('<p class="note">Ranges are across the cells of that scenario. '
      "<em>Stake multiple</em> is the staked-WOOD face value required per $1 of open "
      "coverage: approvers / haircut / k today, 1 / haircut / k under SHE-227. "
      "It is price-invariant.</p>")

    # charts
    a("<h2>3. Charts</h2>")
    ref = [sc for sc in d["scenarios"] if sc["name"] == "reference-cells"]
    fee = [sc for sc in d["scenarios"] if sc["name"] == "fee-ladder"]
    chart_rows = (fee[0]["rows"] if fee else []) + (ref[0]["rows"] if ref else [])
    seen, picked = set(), []
    for r in chart_rows:
        key = (r["stage"], r["mgmt_bps"], r["perf_bps"])
        if key in seen:
            continue
        seen.add(key)
        picked.append(r)
    labels = ["%s %d/%d" % (r["stage"], r["mgmt_bps"], r["perf_bps"]) for r in picked]
    matrix = []
    for r in picked:
        g = r["gross_return_usd"]
        matrix.append([100.0 * r["depositor_net_usd"] / g, 100.0 * r["agent_usd"] / g,
                       100.0 * r["guardian_usd"] / g, 100.0 * r["protocol_usd"] / g,
                       100.0 * r["owner_usd"] / g])
    a("<figure>")
    a(stacked_bar_chart("Where the gross profit goes", labels,
                        ["depositor", "agent", "guardians", "protocol", "vault owner"],
                        matrix))
    a("<figcaption>Where a year of gross profit ends up, by stage and fee rate. "
      "The management leg is charged win or lose, so a fund that is deployed most of the "
      "year hands over most of its gross at the higher management rates.</figcaption>")
    a("</figure>")

    all_rows = [r for sc in d["scenarios"] for r in sc["rows"]]
    by_bind = sorted(all_rows, key=lambda r: r["binding_tvl_25pct_float"])
    pick = by_bind[:6] + by_bind[-6:]
    a("<figure>")
    a(log_bar_chart("Binding TVL at 25% of effective float",
                    ["%s / %s" % (r["scenario"], cell_label(r)) for r in pick],
                    [r["binding_tvl_25pct_float"] for r in pick]))
    a("<figcaption>Six tightest and six loosest cells in the whole run, log scale. "
      "The spread is nearly four orders of magnitude and almost all of it is adapter "
      "certification and the reservation rule &mdash; not price.</figcaption>")
    a("</figure>")

    for block in d["sensitivity"]:
        is_tvl = block["metric"] == "binding_tvl_25pct_float"
        a("<figure>")
        a(tornado_chart(block["title"], block, top=10, log=is_tvl))
        a("<figcaption>Tornado: %s. One-at-a-time around the growth baseline, top ten "
          "inputs.%s</figcaption>"
          % (esc(block["title"]), " Log scale." if is_tvl else ""))
        a("</figure>")

    # 4 scenarios
    a("<h2>4. Scenarios</h2>")
    for sc in d["scenarios"]:
        a("<h3>%s &mdash; %s</h3>" % (esc(sc["name"]), esc(sc["title"])))
        meta = []
        if sc["ticket"]:
            meta.append("<strong>%s</strong>" % esc(sc["ticket"]))
        if sc["question"]:
            meta.append(esc(sc["question"]))
        if meta:
            a("<p>%s</p>" % " &middot; ".join(meta))
        if sc["note"]:
            a('<p class="note">%s</p>' % esc(sc["note"]))
        a(_html_table(CELL_HEADERS, cell_rows(sc)))
        a("<h4>WOOD locked by leg</h4>")
        a(_html_table(WOOD_LEG_HEADERS, wood_leg_rows(sc)))
        a("<h4>Fraud waterfall &mdash; one convicted approver</h4>")
        a(_html_table(FRAUD_HEADERS, fraud_rows(sc)))
    a('<p class="note">The depositor column is $0 in every row of every scenario. '
      "The slash is a deterrent, not insurance: all of it goes to 0x&hellip;dEaD, WOOD has "
      "no burn(), and there is no treasury path on any outcome.</p>")

    # 5 sensitivity tables
    a("<h2>5. Sensitivity tables</h2>")
    for block in d["sensitivity"]:
        a("<h3>%s</h3>" % esc(block["title"]))
        a("<p>Baseline: <code>%s</code></p>" % esc(block["fmt"] % block["baseline_value"]))
        rows = [[r["rank"], r["input"], block["fmt"] % r["low"], r["low_at"],
                 block["fmt"] % r["high"], r["high_at"], block["fmt"] % r["spread"],
                 "-" if r["spread_pct_of_base"] is None else pct(r["spread_pct_of_base"])]
                for r in block["rows"]]
        a(_html_table(["#", "input", "low", "at", "high", "at", "spread", "% of base"], rows))

    # 6/7 constants and assumptions
    a("<h2>6. Constants read from source</h2>")
    a(_html_table(["constant", "value", "source", "note"],
                  [[n, v, w_, note] for n, v, w_, note in d["constants"]]))
    a("<h2>7. Assumptions (not code facts)</h2>")
    a("<p>Nothing in this section is extracted from Solidity and nothing here is "
      "drift-checked.</p>")
    a(_html_table(["assumption", "value", "source", "kind", "note"],
                  [[k, v, s if s != "none" else "none", kind, note]
                   for k, v, s, kind, note in d["assumptions"]]))
    a("<p>See <code>sim/economics/README.md</code> for the full caveats list.</p>")
    a("</div></body></html>")
    return "".join(H)


# ---------------------------------------------------------------------------
# entry point
# ---------------------------------------------------------------------------

def build_payload(proto, assumptions, scenarios, sensitivity_blocks, drift, moved,
                  worked):
    return {
        "generated_at": datetime.datetime.now().strftime("%Y-%m-%d %H:%M"),
        "drift": drift,
        "moved": moved,
        "constants": proto.as_rows(),
        "assumptions": assumptions.doc_rows(),
        "scenarios": scenarios,
        "sensitivity": sensitivity_blocks,
        "worked": worked,
    }


def write_all(payload, out_dir=OUT_DIR):
    os.makedirs(out_dir, exist_ok=True)
    md_path = os.path.join(out_dir, "report.md")
    html_path = os.path.join(out_dir, "report.html")
    json_path = os.path.join(out_dir, "results.json")
    with open(md_path, "w", encoding="utf-8") as fh:
        fh.write(render_md(payload) + "\n")
    with open(html_path, "w", encoding="utf-8") as fh:
        fh.write(render_html(payload) + "\n")
    with open(json_path, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, indent=2, sort_keys=True, default=str)
        fh.write("\n")
    return md_path, html_path, json_path
