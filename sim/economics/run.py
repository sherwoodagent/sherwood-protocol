#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""SHE-182 -- run the whole economics pipeline.

    extract constants -> check against the lock -> run scenarios ->
    run the sensitivity sweeps -> render out/report.{md,html} + out/results.json

Exits non-zero when a constant has drifted, because a report computed from a
different set of numbers than the one that was reviewed is worse than no report.
Pass --allow-drift to render anyway (CI does this, and the report opens with the
diff).

    python3 sim/economics/run.py
    python3 sim/economics/run.py --list
    python3 sim/economics/run.py --scenario shared-coverage --scenario approver-ladder
    python3 sim/economics/run.py --allow-drift
"""

import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import report  # noqa: E402
import scenarios as scen  # noqa: E402
import sensitivity  # noqa: E402
from constants import load  # noqa: E402
from extract_constants import (ExtractionError, REPO_ROOT, diff_against_lock,  # noqa: E402
                               extract, format_drift)
from model import Params, worked_proposal  # noqa: E402


def _worked_block(proto, assumptions):
    """The three canonical worked examples, pinned by test_model.py."""
    p = Params(proto, assumptions,
               {"stage": "growth", "approvers_per_proposal": 3, "wood_price": 0.05,
                "fee_set": "current"},
               label="worked")
    return {
        "mgmt_bps": p.mgmt_bps,
        "perf_bps": p.perf_bps,
        "gain": worked_proposal(p, 100_000.0, 0.10, 14),
        "loss": worked_proposal(p, 100_000.0, -0.05, 14),
        "slashed": worked_proposal(p, 100_000.0, 0.10, 14, slashed=True),
    }


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--list", action="store_true", help="list scenarios and exit")
    ap.add_argument("--scenario", action="append", default=None,
                    help="run only this scenario (repeatable)")
    ap.add_argument("--allow-drift", action="store_true",
                    help="render the report even if constants drifted (still reported)")
    ap.add_argument("--no-sensitivity", action="store_true",
                    help="skip the tornado sweeps")
    ap.add_argument("--out", default=report.OUT_DIR, help="output directory")
    ap.add_argument("--repo-root", default=REPO_ROOT)
    args = ap.parse_args(argv)

    if args.list:
        for s in scen.load_scenarios():
            print("%-22s %-34s %-18s %d cell(s)"
                  % (s["name"], s["title"], s["ticket"] or "-", len(s["cells"])))
        return 0

    # 1. extract ------------------------------------------------------------
    print("[1/5] reading constants from the Solidity source ...")
    try:
        raw = extract(args.repo_root)
    except ExtractionError as exc:
        print("EXTRACTION FAILED\n%s" % exc, file=sys.stderr)
        return 2
    print("      %d constants read from %d files"
          % (len(raw), len({v["file"] for v in raw.values()})))

    # 2. drift --------------------------------------------------------------
    print("[2/5] checking against constants.lock.json ...")
    try:
        drift, moved = diff_against_lock(raw)
    except ExtractionError as exc:
        print(str(exc), file=sys.stderr)
        return 2
    for line in format_drift(drift, moved).splitlines():
        print("      " + line)
    if drift and not args.allow_drift:
        print("\nSTOPPING: %d constant(s) drifted. Re-run with --allow-drift to render "
              "the report anyway, or re-write the lock if the change is intended."
              % len(drift), file=sys.stderr)
        return 1

    proto, assumptions = load(args.repo_root)

    # 3. scenarios ----------------------------------------------------------
    print("[3/5] running scenarios ...")
    try:
        results = scen.run_all(proto, assumptions, only=args.scenario)
    except scen.ScenarioError as exc:
        print("SCENARIO FAILED\n%s" % exc, file=sys.stderr)
        return 2
    n_cells = sum(len(s["rows"]) for s in results)
    print("      %d scenario(s), %d cell(s)" % (len(results), n_cells))

    # 4. sensitivity --------------------------------------------------------
    blocks = []
    if args.no_sensitivity:
        print("[4/5] sensitivity skipped")
    else:
        print("[4/5] sensitivity sweeps ...")
        blocks = sensitivity.tornado(proto, assumptions)
        print("      %d metric(s) x %d input(s)"
              % (len(blocks), len(blocks[0]["rows"]) if blocks else 0))

    # 5. report -------------------------------------------------------------
    print("[5/5] rendering ...")
    payload = report.build_payload(proto, assumptions, results, blocks, drift, moved,
                                   _worked_block(proto, assumptions))
    md, html, js = report.write_all(payload, args.out)
    for path in (md, html, js):
        print("      wrote %s (%d bytes)" % (os.path.relpath(path, args.repo_root),
                                             os.path.getsize(path)))

    if drift:
        print("\nDone, but %d constant(s) drifted -- see section 1 of the report."
              % len(drift))
        return 0 if args.allow_drift else 1
    print("\nDone. No constant drift.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
