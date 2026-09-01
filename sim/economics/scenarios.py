#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""SHE-182 -- the declared scenario library.

Every scenario is one JSON file in `scenarios/`. Nothing here asks the user a
question, and nothing here is defined in Python: adding a scenario is adding a
file, which is what makes the set reviewable in a diff.

File shape:

    {
      "name":     "unique-slug",           # must match the filename
      "title":    "Human title",
      "ticket":   "SHE-227" | null,        # the fix this scenario is evidence for
      "question": "What this answers",
      "note":     "Caveats, provenance, judgement calls",
      "cells": [ { "label": "...", "overrides": { ... } }, ... ]
    }

`overrides` keys are validated against `model.OVERRIDABLE`; an unknown key is
an error, because a typo that silently does nothing is the worst failure mode a
scenario runner can have.
"""

import json
import os

from model import Params, run_cell

HERE = os.path.dirname(os.path.abspath(__file__))
SCENARIO_DIR = os.path.join(HERE, "scenarios")


class ScenarioError(RuntimeError):
    pass


def _load_one(path):
    with open(path, "r", encoding="utf-8") as fh:
        try:
            blob = json.load(fh)
        except ValueError as exc:
            raise ScenarioError("%s is not valid JSON: %s" % (path, exc))
    slug = os.path.splitext(os.path.basename(path))[0]
    for key in ("name", "title", "cells"):
        if key not in blob:
            raise ScenarioError("%s is missing required key %r" % (path, key))
    if blob["name"] != slug:
        raise ScenarioError("%s declares name %r but the filename says %r"
                            % (path, blob["name"], slug))
    if not blob["cells"]:
        raise ScenarioError("%s declares no cells" % path)
    for i, cell in enumerate(blob["cells"]):
        if "label" not in cell or "overrides" not in cell:
            raise ScenarioError("%s cell %d needs both 'label' and 'overrides'" % (path, i))
    blob.setdefault("ticket", None)
    blob.setdefault("question", "")
    blob.setdefault("note", "")
    blob["_path"] = os.path.relpath(path, os.path.dirname(HERE))
    return blob


def load_scenarios(directory=SCENARIO_DIR):
    """Every scenario file, ordered by name. Raises on a malformed file."""
    if not os.path.isdir(directory):
        raise ScenarioError("no scenario directory at %s" % directory)
    paths = sorted(os.path.join(directory, f) for f in os.listdir(directory)
                   if f.endswith(".json"))
    if not paths:
        raise ScenarioError("no scenario files in %s" % directory)
    out = []
    seen = set()
    for path in paths:
        blob = _load_one(path)
        if blob["name"] in seen:
            raise ScenarioError("duplicate scenario name %r" % blob["name"])
        seen.add(blob["name"])
        out.append(blob)
    return out


def list_names(directory=SCENARIO_DIR):
    return [s["name"] for s in load_scenarios(directory)]


def run_scenario(blob, proto, assumptions):
    """Run every cell of one scenario. Returns the scenario dict + results."""
    rows = []
    for cell in blob["cells"]:
        try:
            p = Params(proto, assumptions, cell["overrides"], label=cell["label"])
        except (KeyError, ValueError) as exc:
            raise ScenarioError("scenario %r, cell %r: %s"
                                % (blob["name"], cell["label"], exc))
        row = run_cell(p)
        row["scenario"] = blob["name"]
        rows.append(row)
    return {
        "name": blob["name"],
        "title": blob["title"],
        "ticket": blob["ticket"],
        "question": blob["question"],
        "note": blob["note"],
        "path": blob["_path"],
        "rows": rows,
    }


def run_all(proto, assumptions, only=None, directory=SCENARIO_DIR):
    scenarios = load_scenarios(directory)
    if only:
        wanted = set(only)
        names = {s["name"] for s in scenarios}
        missing = wanted - names
        if missing:
            raise ScenarioError("unknown scenario(s): %s\n  available: %s"
                                % (", ".join(sorted(missing)), ", ".join(sorted(names))))
        scenarios = [s for s in scenarios if s["name"] in wanted]
    return [run_scenario(s, proto, assumptions) for s in scenarios]


if __name__ == "__main__":
    for s in load_scenarios():
        print("%-22s %-34s %-16s %d cell(s)"
              % (s["name"], s["title"], s["ticket"] or "-", len(s["cells"])))
