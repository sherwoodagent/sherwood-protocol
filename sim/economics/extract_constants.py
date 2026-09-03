#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""SHE-182 -- read protocol economics constants straight out of the Solidity source.

Nothing in this module is hard-coded arithmetic: every number the model uses is
pulled from a named file with a named regex, and the file:line it was found at is
recorded alongside it. That makes the extraction auditable, and it makes drift
detectable: `constants.lock.json` is a snapshot, and `--check` fails when the
source no longer agrees with it.

Design rules:
  * If a pattern does not match, we raise. There is no silent fallback to a
    literal, ever -- a stale literal that looks live is worse than a crash.
  * A constant whose value is written symbolically (e.g. `= BPS_DENOMINATOR`)
    is resolved against the other extracted constants, not guessed.
  * Values that exist only in prose (token supply, float, price anchors, the
    certified tier bound) are NOT extracted. They live in `assumptions.json`
    and are labelled as assumptions everywhere they surface.

Usage:
    python3 sim/economics/extract_constants.py            # print the table
    python3 sim/economics/extract_constants.py --json     # machine-readable
    python3 sim/economics/extract_constants.py --write    # (re)write the lock
    python3 sim/economics/extract_constants.py --check    # drift detector
"""

import argparse
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
LOCK_PATH = os.path.join(HERE, "constants.lock.json")

BRANCH = "post-audit"


class ExtractionError(RuntimeError):
    """Raised when a pattern does not match. Always names file + pattern."""


# ---------------------------------------------------------------------------
# Value normalisation
# ---------------------------------------------------------------------------

def _int_token(tok):
    """`10_000` / `1_000` / `2000` -> int. Rejects anything else."""
    t = tok.strip().replace("_", "")
    if not re.fullmatch(r"\d+", t):
        raise ValueError("not an integer literal: %r" % tok)
    return int(t)


def _as_int(tok, _all):
    return _int_token(tok)


def _as_days(tok, _all):
    """`14 days` capture group is just the count; the unit is in the pattern."""
    return _int_token(tok)


def _as_e18(tok, _all):
    """`10_000e18` or `1_000 * 1e18` -> the whole-token count (10000 / 1000)."""
    t = tok.strip().replace("_", "").replace(" ", "")
    m = re.fullmatch(r"(\d+)(?:e18|\*1e18)", t)
    if not m:
        raise ValueError("not an 18-decimal literal: %r" % tok)
    return float(m.group(1))


def _as_x8(tok, _all):
    """A Chainlink-style 8-decimal price integer -> float USD."""
    return _int_token(tok) / 1e8


def _as_symbol(tok, all_values):
    """`= BPS_DENOMINATOR` -> resolve against already-extracted constants."""
    t = tok.strip()
    if re.fullmatch(r"[\d_]+", t):
        return _int_token(t)
    if t not in all_values:
        raise ExtractionError(
            "symbolic value %r could not be resolved; known names: %s"
            % (t, ", ".join(sorted(all_values)))
        )
    return all_values[t]["value"]


# ---------------------------------------------------------------------------
# The extraction table
#
# `pattern` must have exactly one capture group: the value token.
# `order` matters only for symbolic resolution (a symbol must be extracted
# before whatever refers to it).
# ---------------------------------------------------------------------------

SPECS = [
    # --- src/FeeConstants.sol -------------------------------------------------
    dict(name="BPS_DENOMINATOR", file="src/FeeConstants.sol",
         pattern=r"constant\s+BPS_DENOMINATOR\s*=\s*([\d_]+)\s*;",
         conv=_as_int,
         note="Basis-point denominator used by every fee computation."),
    dict(name="DEFAULT_AGENT_FEE_BPS", file="src/FeeConstants.sol",
         pattern=r"constant\s+DEFAULT_AGENT_FEE_BPS\s*=\s*([\d_]+)\s*;",
         conv=_as_int,
         note="The performance fee a vault charges out of the box (the '20' in 2-and-20)."),
    dict(name="DEFAULT_MAX_PERFORMANCE_FEE_BPS", file="src/FeeConstants.sol",
         pattern=r"constant\s+DEFAULT_MAX_PERFORMANCE_FEE_BPS\s*=\s*([\d_]+)\s*;",
         conv=_as_int,
         note="Per-vault performance ceiling a new vault starts at; equals the default rate, "
              "so the vault fails closed rather than open."),
    dict(name="MAX_PERFORMANCE_FEE_BPS", file="src/FeeConstants.sol",
         pattern=r"constant\s+MAX_PERFORMANCE_FEE_BPS\s*=\s*([\d_]+)\s*;",
         conv=_as_int,
         note="Hard protocol ceiling on the performance fee. The `worst_stack` fee set runs here."),

    # --- src/ProtocolConfig.sol ----------------------------------------------
    dict(name="MGMT_SPLIT_AGENT_BPS", file="src/ProtocolConfig.sol",
         pattern=r"_mgmtSplit\s*=\s*MgmtSplit\(\{\s*agentBps:\s*([\d_]+)",
         conv=_as_int, note="Agent share of the management fee."),
    dict(name="MGMT_SPLIT_PROTOCOL_BPS", file="src/ProtocolConfig.sol",
         pattern=r"_mgmtSplit\s*=\s*MgmtSplit\(\{[^}]*?protocolBps:\s*([\d_]+)",
         conv=_as_int, note="Protocol share of the management fee."),
    dict(name="MGMT_SPLIT_GUARDIAN_BPS", file="src/ProtocolConfig.sol",
         pattern=r"_mgmtSplit\s*=\s*MgmtSplit\(\{[^}]*?guardianBps:\s*([\d_]+)",
         conv=_as_int,
         note="Guardian share of the management fee. docs/guardian-network.md still says 10% "
              "(SHE-229); the code says this."),
    dict(name="PERF_SPLIT_AGENT_BPS", file="src/ProtocolConfig.sol",
         pattern=r"_perfSplit\s*=\s*PerfSplit\(\{\s*agentBps:\s*([\d_]+)",
         conv=_as_int, note="Agent share of the performance fee."),
    dict(name="PERF_SPLIT_PROTOCOL_BPS", file="src/ProtocolConfig.sol",
         pattern=r"_perfSplit\s*=\s*PerfSplit\(\{[^}]*?protocolBps:\s*([\d_]+)",
         conv=_as_int, note="Protocol share of the performance fee."),
    dict(name="PERF_SPLIT_GUARDIAN_BPS", file="src/ProtocolConfig.sol",
         pattern=r"_perfSplit\s*=\s*PerfSplit\(\{[^}]*?guardianBps:\s*([\d_]+)",
         conv=_as_int,
         note="Guardian share of the performance fee. docs say 15% (SHE-229); the code says this."),
    dict(name="PERF_SPLIT_OWNER_BPS", file="src/ProtocolConfig.sol",
         pattern=r"_perfSplit\s*=\s*PerfSplit\(\{[^}]*?ownerBps:\s*([\d_]+)",
         conv=_as_int,
         note="Vault-owner share of the performance fee. There is no owner leg on management."),

    # --- src/ExposureLedger.sol ----------------------------------------------
    dict(name="PROPOSER_BOND_BPS", file="src/ExposureLedger.sol",
         pattern=r"uint256\s+public\s+proposerBondBps\s*=\s*([\d_]+)\s*;",
         conv=_as_int, note="Proposer bond as bps of USD coverage (1%)."),
    dict(name="K_NUMERATOR", file="src/ExposureLedger.sol",
         pattern=r"uint256\s+public\s+kNumerator\s*=\s*([\d_]+)\s*;",
         conv=_as_int, note="USD of coverage bookable per USD of haircut-priced stake."),
    dict(name="LEDGER_CHALLENGE_WINDOW_DAYS", file="src/ExposureLedger.sol",
         pattern=r"uint256\s+public\s+challengeWindow\s*=\s*([\d_]+)\s*days\s*;",
         conv=_as_days, note="Post-epoch challenge window held by the ledger."),
    dict(name="LEDGER_DEFAULT_WOOD_HAIRCUT_BPS", file="src/ExposureLedger.sol",
         pattern=r"uint256\s+public\s+woodHaircutBps\s*=\s*([A-Za-z_][A-Za-z0-9_]*|[\d_]+)\s*;",
         conv=_as_symbol,
         note="The ledger's OWN default haircut. Written symbolically as BPS_DENOMINATOR, i.e. "
              "NO haircut. Only DeployPlanB overwrites it."),

    # --- src/ChallengeGame.sol -----------------------------------------------
    dict(name="CHALLENGER_BOND_BPS", file="src/ChallengeGame.sol",
         pattern=r"uint256\s+public\s+challengerBondBps\s*=\s*([\d_]+)\s*;",
         conv=_as_int, note="Challenger bond as bps of the coverage a filing freezes (1.5%)."),
    dict(name="PROSECUTOR_FEE_BPS", file="src/ChallengeGame.sol",
         pattern=r"uint256\s+public\s+prosecutorFeeBps\s*=\s*([\d_]+)\s*;",
         conv=_as_int,
         note="Slice of the forfeited proposer bond paid to a winning challenger. The papers "
              "say 5%; the code says this."),
    dict(name="SETTLE_BURN_BPS", file="src/ChallengeGame.sol",
         pattern=r"uint256\s+public\s+settleBurnBps\s*=\s*([\d_]+)\s*;",
         conv=_as_int, note="Slice of a WINNING challenger's own bond that is burned."),
    dict(name="FORFEIT_BURN_BPS", file="src/ChallengeGame.sol",
         pattern=r"uint256\s+public\s+forfeitBurnBps\s*=\s*([\d_]+)\s*;",
         conv=_as_int, note="Slice of a LOSING challenger's forfeited bond that is burned."),
    dict(name="GAME_CHALLENGE_WINDOW_DAYS", file="src/ChallengeGame.sol",
         pattern=r"uint256\s+public\s+challengeWindow\s*=\s*([\d_]+)\s*days\s*;",
         conv=_as_days, note="The game's own copy of the challenge window; must track the ledger's."),

    # --- src/TokenCourt.sol ---------------------------------------------------
    dict(name="PARTICIPATION_FLOOR_BPS", file="src/TokenCourt.sol",
         pattern=r"uint256\s+public\s+participationFloorBps\s*=\s*([\d_]+)\s*;",
         conv=_as_int,
         note="Turnout floor below which a verdict is Inconclusive and the window re-arms. "
              "The model does not price re-arms (caveat A8)."),

    # --- src/TierRegistry.sol -------------------------------------------------
    dict(name="FULL_NOTIONAL_BPS", file="src/TierRegistry.sol",
         pattern=r"constant\s+FULL_NOTIONAL_BPS\s*=\s*([\d_]+)\s*;",
         conv=_as_int, note="Coverage bound for an uncertified (tier-2) call: the full notional."),
    dict(name="TIER_ARBITRARY", file="src/TierRegistry.sol",
         pattern=r"constant\s+TIER_ARBITRARY\s*=\s*([\d_]+)\s*;",
         conv=_as_int, note="The uncertified tier id. Everything ships in it: no script certifies."),

    # --- src/GuardianRegistry.sol ---------------------------------------------
    dict(name="MAX_APPROVERS_PER_PROPOSAL", file="src/GuardianRegistry.sol",
         pattern=r"constant\s+MAX_APPROVERS_PER_PROPOSAL\s*=\s*([\d_]+)\s*;",
         conv=_as_int, note="Ceiling on the approver ladder."),
    dict(name="GUARDIAN_EPOCH_DURATION_DAYS", file="src/GuardianRegistry.sol",
         pattern=r"constant\s+EPOCH_DURATION\s*=\s*([\d_]+)\s*days\s*;",
         conv=_as_days, note="Registry epoch, also the refundSlash cap window."),

    # --- src/StakedWood.sol ---------------------------------------------------
    dict(name="MIN_OWNER_BOND_FLOOR_WOOD", file="src/StakedWood.sol",
         pattern=r"constant\s+MIN_OWNER_BOND_FLOOR\s*=\s*([\d_]+\s*\*\s*1e18)\s*;",
         conv=_as_e18,
         note="Hard floor under the vault-owner bond; the effective bond is "
              "max(minOwnerStake, this)."),

    # --- src/SyndicateFactory.sol ---------------------------------------------
    dict(name="MAX_MANAGEMENT_FEE_BPS", file="src/SyndicateFactory.sol",
         pattern=r"constant\s+MAX_MANAGEMENT_FEE_BPS\s*=\s*([\d_]+)\s*;",
         conv=_as_int, note="Hard ceiling on the management fee (5%/yr)."),
    dict(name="MAX_STRATEGY_DURATION_DAYS", file="src/SyndicateFactory.sol",
         pattern=r"maxStrategyDuration:\s*([\d_]+)\s*days",
         conv=_as_days,
         note="Governor-parameter ceiling on a single strategy. Note Deploy.s.sol ships "
              "MAX_STRATEGY_DAYS at 14, which binds first."),

    # --- script/Deploy.s.sol --------------------------------------------------
    dict(name="MANAGEMENT_FEE_BPS_DEPLOYED", file="script/Deploy.s.sol",
         pattern=r"managementFeeBps:\s*vm\.envOr\(\s*\"MANAGEMENT_FEE\"\s*,\s*uint256\(([\d_]+)\)\s*\)",
         conv=_as_int,
         note="The management rate a mainnet deploy actually ships with (env-overridable)."),
    dict(name="MAX_STRATEGY_DAYS_DEPLOYED", file="script/Deploy.s.sol",
         pattern=r"maxStrategyDays:\s*vm\.envOr\(\s*\"MAX_STRATEGY_DAYS\"\s*,\s*uint256\(([\d_]+)\)\s*\)",
         conv=_as_int,
         note="Deploy-time strategy-duration ceiling in DAYS. Lower than the factory's 30d."),
    dict(name="MIN_GUARDIAN_STAKE_WOOD", file="script/Deploy.s.sol",
         pattern=r"constant\s+DEFAULT_MIN_GUARDIAN_STAKE\s*=\s*([\d_]+e18)\s*;",
         conv=_as_e18, note="WOOD a guardian must stake to register at all."),
    dict(name="MIN_OWNER_STAKE_WOOD", file="script/Deploy.s.sol",
         pattern=r"constant\s+DEFAULT_MIN_OWNER_STAKE\s*=\s*([\d_]+e18)\s*;",
         conv=_as_e18, note="WOOD a vault owner must bond per fund."),
    dict(name="MIN_SLASH_BPS", file="script/Deploy.s.sol",
         pattern=r"constant\s+DEFAULT_MIN_SLASH_BPS\s*=\s*([\d_]+)\s*;",
         conv=_as_int,
         note="Lower clamp on any slash. An approver who underwrote a sliver still pays this "
              "share of their whole stake."),
    dict(name="MAX_SLASH_BPS", file="script/Deploy.s.sol",
         pattern=r"constant\s+DEFAULT_MAX_SLASH_BPS\s*=\s*([\d_]+)\s*;",
         conv=_as_int, note="Upper clamp on any slash. 100% as deployed."),

    # --- script/DeployPlanB.s.sol ---------------------------------------------
    dict(name="WOOD_HAIRCUT_BPS", file="script/DeployPlanB.s.sol",
         pattern=r"constant\s+DEFAULT_WOOD_HAIRCUT_BPS\s*=\s*([\d_]+)\s*;",
         conv=_as_int,
         note="The haircut a Plan B deploy applies to the WOOD price when pricing stake. "
              "The model uses this, NOT the ledger default."),
    dict(name="EPOCH_LENGTH_DAYS", file="script/DeployPlanB.s.sol",
         pattern=r"constant\s+EPOCH_LENGTH\s*=\s*([\d_]+)\s*days\s*;",
         conv=_as_days, note="Exposure epoch length; immutable in the ledger once constructed."),
    dict(name="PLANB_REQUIRED_MAX_SLASH_BPS", file="script/DeployPlanB.s.sol",
         pattern=r"maxSlashBps\(\)\s*==\s*([\d_]+)\s*,",
         conv=_as_int,
         note="Plan B pre-flight HARD-REQUIRES this maxSlashBps. It is why the slash is 100%."),

    # --- script/fork/DeployForkWoodUsdFeed.s.sol ------------------------------
    # The only WOOD price anywhere in the repo grounded in real on-chain state
    # (fork pool reserves x Chainlink ETH/USD). It lives in the usage block of a
    # doc comment, which is the most fragile extraction here -- see README.
    dict(name="WOOD_USD_PRICE_X8_FORK", file="script/fork/DeployForkWoodUsdFeed.s.sol",
         pattern=r"WOOD_USD_PRICE_X8=([\d_]+)\b",
         conv=_as_x8,
         note="Derived spot WOOD/USD from the Robinhood fork's pool reserves. Extracted from a "
              "doc-comment usage line -- fragile by nature, see README 'Fragile patterns'."),
]


# ---------------------------------------------------------------------------
# Extraction
# ---------------------------------------------------------------------------

def _read(repo_root, rel):
    path = os.path.join(repo_root, rel)
    if not os.path.exists(path):
        raise ExtractionError(
            "source file missing: %s (looked in repo root %s). The model refuses to fall "
            "back to a literal." % (rel, repo_root))
    with open(path, "r", encoding="utf-8") as fh:
        return fh.read()


def extract(repo_root=REPO_ROOT):
    """Return {name: {value, raw, file, line, note}} or raise ExtractionError."""
    cache = {}
    out = {}
    for spec in SPECS:
        rel = spec["file"]
        if rel not in cache:
            cache[rel] = _read(repo_root, rel)
        text = cache[rel]
        m = re.search(spec["pattern"], text, re.S)
        if not m:
            raise ExtractionError(
                "NO MATCH for constant %s\n  file:    %s\n  pattern: %s\n"
                "  The Solidity source changed shape. Fix the pattern in "
                "sim/economics/extract_constants.py -- do not hard-code the value."
                % (spec["name"], rel, spec["pattern"]))
        raw = m.group(1)
        try:
            value = spec["conv"](raw, out)
        except ExtractionError:
            raise
        except Exception as exc:
            raise ExtractionError(
                "BAD VALUE for constant %s\n  file:    %s\n  pattern: %s\n  captured: %r\n"
                "  %s" % (spec["name"], rel, spec["pattern"], raw, exc))
        line = text.count("\n", 0, m.start(1)) + 1
        out[spec["name"]] = {
            "value": value,
            "raw": raw.strip(),
            "file": rel,
            "line": line,
            "note": spec["note"],
        }
    return out


# ---------------------------------------------------------------------------
# Lock file + drift
# ---------------------------------------------------------------------------

def load_lock(path=LOCK_PATH):
    if not os.path.exists(path):
        raise ExtractionError(
            "no lock file at %s -- run `python3 sim/economics/extract_constants.py --write`"
            % path)
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def write_lock(constants, path=LOCK_PATH):
    payload = {
        "_comment": "Snapshot of the protocol constants the economics model reads. "
                    "Regenerate with `python3 sim/economics/extract_constants.py --write` "
                    "and review the diff -- a change here is a change to the economics.",
        "branch": BRANCH,
        "constants": constants,
    }
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, indent=2, sort_keys=True)
        fh.write("\n")
    return path


def diff_against_lock(constants, lock=None):
    """Compare live extraction to the lock.

    Returns (drift, moved) where `drift` is the list of value-level changes
    (added / removed / changed) and `moved` is the advisory list of constants
    whose value is unchanged but whose file:line shifted. Only `drift` is a
    failure; a line move is a refactor, not an economics change.
    """
    lock = lock or load_lock()
    locked = lock.get("constants", {})
    drift, moved = [], []
    for name in sorted(set(locked) | set(constants)):
        old = locked.get(name)
        new = constants.get(name)
        if old is None:
            drift.append({"kind": "added", "name": name, "old": None,
                          "new": new["value"], "where": "%s:%d" % (new["file"], new["line"])})
        elif new is None:
            drift.append({"kind": "removed", "name": name, "old": old["value"], "new": None,
                          "where": "%s:%s" % (old["file"], old.get("line", "?"))})
        elif old["value"] != new["value"]:
            drift.append({"kind": "changed", "name": name, "old": old["value"],
                          "new": new["value"],
                          "where": "%s:%d" % (new["file"], new["line"]),
                          "was_at": "%s:%s" % (old["file"], old.get("line", "?"))})
        elif old.get("file") != new["file"] or old.get("line") != new["line"]:
            moved.append({"name": name, "value": new["value"],
                          "from": "%s:%s" % (old.get("file"), old.get("line")),
                          "to": "%s:%d" % (new["file"], new["line"])})
    return drift, moved


def format_drift(drift, moved):
    lines = []
    if drift:
        lines.append("CONSTANT DRIFT -- %d constant(s) no longer match constants.lock.json"
                     % len(drift))
        lines.append("")
        w = max(len(d["name"]) for d in drift)
        for d in drift:
            if d["kind"] == "changed":
                lines.append("  ~ %-*s  %s -> %s   (%s)"
                             % (w, d["name"], d["old"], d["new"], d["where"]))
            elif d["kind"] == "added":
                lines.append("  + %-*s  %s   (%s)" % (w, d["name"], d["new"], d["where"]))
            else:
                lines.append("  - %-*s  was %s   (%s)" % (w, d["name"], d["old"], d["where"]))
        lines.append("")
        lines.append("The economics in out/report.md were computed from the LIVE source above, "
                     "not from the lock.")
        lines.append("If the change is intended: re-run with --write and commit the new lock.")
    else:
        lines.append("No constant drift: every extracted value matches constants.lock.json.")
    if moved:
        lines.append("")
        lines.append("Advisory -- %d constant(s) kept their value but moved in the source:"
                     % len(moved))
        for m in moved:
            lines.append("    %s  %s -> %s" % (m["name"], m["from"], m["to"]))
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _print_table(constants):
    names = sorted(constants)
    w1 = max(len(n) for n in names)
    w2 = max(len(str(constants[n]["value"])) for n in names)
    print("%-*s  %*s  %s" % (w1, "constant", w2, "value", "source"))
    print("%s  %s  %s" % ("-" * w1, "-" * w2, "-" * 46))
    for n in names:
        c = constants[n]
        print("%-*s  %*s  %s:%d" % (w1, n, w2, c["value"], c["file"], c["line"]))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--json", action="store_true", help="emit JSON instead of a table")
    ap.add_argument("--write", action="store_true", help="(re)write constants.lock.json")
    ap.add_argument("--check", action="store_true",
                    help="compare source to the lock; exit 1 on drift")
    ap.add_argument("--repo-root", default=REPO_ROOT)
    args = ap.parse_args(argv)

    try:
        constants = extract(args.repo_root)
    except ExtractionError as exc:
        print("EXTRACTION FAILED\n%s" % exc, file=sys.stderr)
        return 2

    if args.write:
        path = write_lock(constants)
        print("wrote %s (%d constants)" % (path, len(constants)))
        return 0

    if args.check:
        try:
            drift, moved = diff_against_lock(constants)
        except ExtractionError as exc:
            print(str(exc), file=sys.stderr)
            return 2
        print(format_drift(drift, moved))
        return 1 if drift else 0

    if args.json:
        print(json.dumps({"branch": BRANCH, "constants": constants},
                         indent=2, sort_keys=True))
    else:
        _print_table(constants)
    return 0


if __name__ == "__main__":
    sys.exit(main())
