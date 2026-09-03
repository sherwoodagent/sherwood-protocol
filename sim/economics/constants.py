#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""SHE-182 -- the constant surface the economics model runs on.

Two clearly separated halves:

  * `Protocol`  -- every value read out of the Solidity source at runtime by
    `extract_constants.py`. Each carries its own file:line. These are code
    facts and they are drift-checked against `constants.lock.json`.

  * `Assumptions` -- everything that exists only in prose or only in this
    model: WOOD supply and float, the tokenomics price anchors, the certified
    tier bound, the flywheel threshold, and the invented stage profiles.
    Loaded from `assumptions.json`, labelled as assumptions wherever they are
    reported, and NOT drift-checked (there is nothing to check them against).

The split is the point. If a number is in `Protocol`, disagreeing with it is a
bug report against the contracts. If it is in `Assumptions`, disagreeing with it
is a modelling argument.
"""

import json
import os

from extract_constants import extract, load_lock, ExtractionError, REPO_ROOT

HERE = os.path.dirname(os.path.abspath(__file__))
ASSUMPTIONS_PATH = os.path.join(HERE, "assumptions.json")

SECONDS_PER_YEAR = 365 * 24 * 3600
DAYS_PER_YEAR = 365.0


class Protocol(object):
    """Attribute access over the extracted constants, with provenance kept."""

    def __init__(self, raw):
        self.raw = raw
        for name, rec in raw.items():
            setattr(self, name, rec["value"])

    def where(self, name):
        rec = self.raw[name]
        return "%s:%d" % (rec["file"], rec["line"])

    def note(self, name):
        return self.raw[name]["note"]

    def as_rows(self):
        return [(n, self.raw[n]["value"], self.where(n), self.raw[n]["note"])
                for n in sorted(self.raw)]

    # -- derived views the model wants ------------------------------------
    @property
    def bps(self):
        return float(self.BPS_DENOMINATOR)

    @property
    def mgmt_split(self):
        return {"agent": self.MGMT_SPLIT_AGENT_BPS,
                "protocol": self.MGMT_SPLIT_PROTOCOL_BPS,
                "guardian": self.MGMT_SPLIT_GUARDIAN_BPS,
                "owner": 0}

    @property
    def perf_split(self):
        return {"agent": self.PERF_SPLIT_AGENT_BPS,
                "protocol": self.PERF_SPLIT_PROTOCOL_BPS,
                "guardian": self.PERF_SPLIT_GUARDIAN_BPS,
                "owner": self.PERF_SPLIT_OWNER_BPS}

    @property
    def owner_bond_wood(self):
        """max(minOwnerStake, MIN_OWNER_BOND_FLOOR) -- StakedWood.requiredOwnerBond."""
        return max(self.MIN_OWNER_STAKE_WOOD, self.MIN_OWNER_BOND_FLOOR_WOOD)

    @property
    def challenge_window_days(self):
        """The ledger's window. The game keeps its own copy; they must agree."""
        if self.LEDGER_CHALLENGE_WINDOW_DAYS != self.GAME_CHALLENGE_WINDOW_DAYS:
            raise ValueError(
                "challengeWindow disagrees between ExposureLedger (%d d) and ChallengeGame "
                "(%d d). That is a real protocol inconsistency, not a model bug."
                % (self.LEDGER_CHALLENGE_WINDOW_DAYS, self.GAME_CHALLENGE_WINDOW_DAYS))
        return self.LEDGER_CHALLENGE_WINDOW_DAYS

    @property
    def effective_slash_bps(self):
        """`slashBpsFor` returns 10000 for every approver with a live pledge,
        clamped into [minSlashBps, maxSlashBps]. maxSlashBps is 10000 as
        deployed and Plan B hard-requires it, so the effective rate is 100%."""
        return min(int(self.BPS_DENOMINATOR),
                   max(self.MIN_SLASH_BPS, min(self.MAX_SLASH_BPS,
                                               int(self.BPS_DENOMINATOR))))


class Assumptions(object):
    def __init__(self, blob):
        self.raw = blob
        docs = blob["doc_assumptions"]
        self.wood_total_supply = docs["wood_total_supply"]["value"]
        self.wood_float_m12 = docs["wood_effective_float_m12"]["value"]
        self.wood_price_anchor = docs["wood_price_tokenomics_anchor"]["value"]
        self.wood_price_stretch = list(docs["wood_price_stretch_anchors"]["value"])
        self.certified_bound_bps = docs["certified_bound_bps"]["value"]
        self.flywheel_threshold = docs["flywheel_threshold_frac_of_float"]["value"]
        self.stage_profiles = {k: v for k, v in blob["stage_profiles"].items()
                               if not k.startswith("_")}
        self.fee_sets = {k: v for k, v in blob["fee_sets"].items()
                         if not k.startswith("_")}

    def doc_rows(self):
        return [(k, v["value"], v["source"], v["kind"], v["note"])
                for k, v in sorted(self.raw["doc_assumptions"].items())]


def load(repo_root=REPO_ROOT, use_lock=False):
    """Load (Protocol, Assumptions).

    `use_lock=True` reads the pinned snapshot instead of the live source. That
    exists for reproducing an old report, not for routine runs -- the whole
    point of the tool is that it reads the source.
    """
    if use_lock:
        raw = load_lock()["constants"]
    else:
        raw = extract(repo_root)
    with open(ASSUMPTIONS_PATH, "r", encoding="utf-8") as fh:
        blob = json.load(fh)
    return Protocol(raw), Assumptions(blob)


def resolve_fee_set(name, proto, assumptions):
    """Turn a fee-set name into (mgmt_bps, perf_bps, label, note).

    Fee-set entries may name a protocol constant instead of a literal, so a
    change in FeeConstants.sol propagates into the scenarios automatically.

    The LABEL IS RENDERED, never stored: `assumptions.json` holds the name of
    the set and this function appends the resolved pair. A stored "500/3000"
    on a set that reads `MAX_*_FEE_BPS` survives the constant it names and
    then prints the new economics under the old heading (review of #294).
    """
    if name not in assumptions.fee_sets:
        raise KeyError("unknown fee set %r; known: %s"
                       % (name, ", ".join(sorted(assumptions.fee_sets))))
    spec = assumptions.fee_sets[name]

    def val(x):
        if isinstance(x, str):
            if not hasattr(proto, x):
                raise ExtractionError(
                    "fee set %r refers to protocol constant %r, which the extractor did not "
                    "produce. Add it to SPECS in extract_constants.py." % (name, x))
            return int(getattr(proto, x))
        return int(x)

    mgmt, perf = val(spec["mgmt_bps"]), val(spec["perf_bps"])
    return mgmt, perf, "%s %d/%d" % (spec["label"], mgmt, perf), spec["note"]
