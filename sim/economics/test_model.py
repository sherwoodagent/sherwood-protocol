#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""SHE-182 -- regression tests for the economics model and the drift checker.

    python3 -m unittest discover -s sim/economics
    cd sim/economics && python3 -m unittest test_model -v

The dollar figures pinned here come from the SHE-182 manual simulation and its
`worked-examples.md` / `results.md`. If one of them moves, either the mechanics
changed or a protocol constant did -- both are things a reviewer must see.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import extract_constants as xc  # noqa: E402
import report  # noqa: E402
import scenarios as scen  # noqa: E402
import sensitivity  # noqa: E402
from constants import load, resolve_fee_set  # noqa: E402
from model import (Params, binding_tvl, cohort_multiplier, run_cell,  # noqa: E402
                   wood_demand, worked_proposal)

PROTO, ASSUMPTIONS = load()


def params(**overrides):
    return Params(PROTO, ASSUMPTIONS, overrides)


# The SHE-182 dossier (worked-examples.md, results.md) was computed against the
# 2026-09-01 deploy values. Tests that pin dossier numbers say so explicitly, so
# they keep testing the MECHANICS when a deploy parameter is deliberately moved.
DOSSIER = dict(wood_haircut_bps=7000)
DOSSIER_WORST_STACK = dict(mgmt_bps=500, perf_bps=3000)
# The same stack under the launch configuration (SHE-182 / SHE-18). Literals,
# for the same reason the dossier pair is: this pins the economics the fee
# change was made to buy, so it must not move when a ceiling moves again.
LAUNCH_WORST_STACK = dict(mgmt_bps=300, perf_bps=2500)


def dossier_params(**overrides):
    ov = dict(DOSSIER); ov.update(overrides)
    return params(**ov)


class WorkedExamples(unittest.TestCase):
    """worked-examples.md: $100k fund, one 14-day tier-2 proposal, 3 approvers,
    WOOD at $0.05, current fees (200 / 2000)."""

    def setUp(self):
        self.p = dossier_params(stage="growth", approvers_per_proposal=3,
                                wood_price=0.05, fee_set="current")

    def test_scenario_1_gain_10pct(self):
        w = worked_proposal(self.p, 100_000.0, 0.10, 14)
        self.assertAlmostEqual(w["mgmt_fee"], 76.71, places=2)
        self.assertAlmostEqual(w["assets_after_mgmt"], 109_923.29, places=2)
        self.assertAlmostEqual(w["perf_base_above_hwm"], 9_923.29, places=2)
        self.assertAlmostEqual(w["perf_fee"], 1_984.66, places=2)
        self.assertAlmostEqual(w["assets_final"], 107_938.63, places=2)
        self.assertAlmostEqual(w["depositor_net"], 7_938.63, places=2)
        # the four fee legs, to the cent
        self.assertAlmostEqual(w["take_agent"], 1_038.36, places=2)
        self.assertAlmostEqual(w["take_protocol"], 313.04, places=2)
        self.assertAlmostEqual(w["take_guardian"], 511.51, places=2)
        self.assertAlmostEqual(w["take_owner"], 198.47, places=2)
        # they must exhaust the fees exactly -- the agent leg is the remainder
        self.assertAlmostEqual(
            w["take_agent"] + w["take_protocol"] + w["take_guardian"] + w["take_owner"],
            w["mgmt_fee"] + w["perf_fee"], places=6)

    def test_scenario_2_loss_5pct(self):
        w = worked_proposal(self.p, 100_000.0, -0.05, 14)
        self.assertAlmostEqual(w["mgmt_fee"], 76.71, places=2)
        self.assertAlmostEqual(w["assets_final"], 94_923.29, places=2)
        self.assertAlmostEqual(w["depositor_net"], -5_076.71, places=2)
        # the HWM does not move down, and there is no owner leg on management
        self.assertEqual(w["perf_fee"], 0.0)
        self.assertEqual(w["take_owner"], 0.0)
        self.assertAlmostEqual(w["hwm_after"], 100_000.0, places=6)
        self.assertAlmostEqual(w["take_agent"], 46.03, places=2)

    def test_scenario_3_slashed(self):
        """The depositor waterfall is byte-identical to scenario 1; the slash
        happens entirely in WOOD and pays nobody."""
        gain = worked_proposal(self.p, 100_000.0, 0.10, 14)
        w = worked_proposal(self.p, 100_000.0, 0.10, 14, slashed=True)
        self.assertAlmostEqual(w["assets_final"], gain["assets_final"], places=8)

        # capital at risk, in WOOD
        self.assertAlmostEqual(w["proposer_bond_wood"], 20_000.0, places=6)
        self.assertAlmostEqual(w["challenger_bond_wood"], 30_000.0, places=6)
        self.assertAlmostEqual(w["cohort_gate_wood"], 2_857_142.857142857, places=4)
        self.assertAlmostEqual(w["cohort_budget_wood"], 8_571_428.571428571, places=4)

        # the burn, leg by leg
        self.assertEqual(w["slash_bps"], 10_000)
        self.assertAlmostEqual(w["slashed_wood"], 2_857_142.857142857, places=4)
        self.assertAlmostEqual(w["proposer_bond_burned_wood"], 16_000.0, places=6)
        self.assertAlmostEqual(w["challenger_bond_burned_wood"], 1_500.0, places=6)
        self.assertAlmostEqual(w["total_burned_wood"], 2_874_642.857142857, places=4)

        # worked-examples.md prints 2,875,500 for this total. That figure adds
        # the exact 17,500 of bond burns to a ROUNDED 2,858,000 of guardian
        # stake, so it overstates by 857.14 WOOD ($42.86). The component rows in
        # that same table are right; only the total is rounded. Pin the exact
        # arithmetic, and assert we are in the documented neighbourhood.
        self.assertLess(abs(w["total_burned_wood"] - 2_875_500.0), 900.0)

        # and the point of the whole scenario
        self.assertAlmostEqual(w["paid_to_challenger_wood"], 2_500.0, places=6)
        self.assertEqual(w["paid_to_depositor_wood"], 0.0)
        self.assertEqual(w["paid_to_depositor_usd"], 0.0)
        self.assertEqual(w["paid_to_treasury_wood"], 0.0)


class ResultsSectionA(unittest.TestCase):
    """results.md section A: one year per $1M of TVL, current fees."""

    def test_growth_1m_cell(self):
        c = run_cell(params(stage="growth", tvl=1_000_000.0, wood_price=0.05,
                            fee_set="current"))
        self.assertAlmostEqual(c["gross_return_usd"] / 1000.0, 112.2, places=1)
        self.assertAlmostEqual(c["depositor_net_usd"] / 1000.0, 82.3, places=1)
        self.assertAlmostEqual(c["depositor_share_of_gross_pct"], 73.3, places=1)
        self.assertEqual(c["settlements"], 12)
        self.assertEqual(c["settlements_charging_perf"], 7)

    def test_mature_worst_stack_leaves_39_5_pct(self):
        c = run_cell(dossier_params(stage="mature", tvl=1_000_000.0, wood_price=0.05,
                                    **DOSSIER_WORST_STACK))
        self.assertAlmostEqual(c["depositor_share_of_gross_pct"], 39.5, places=1)

    def test_mature_launch_stack_leaves_55_4_pct(self):
        """The same cell at the launch ceilings -- the figure the fee change is
        made for. Sibling of the 39.5% dossier pin above: that one keeps
        testing the OLD economics on purpose, so without this one the number
        that justifies 300/2500 is asserted nowhere."""
        c = run_cell(dossier_params(stage="mature", tvl=1_000_000.0, wood_price=0.05,
                                    **LAUNCH_WORST_STACK))
        self.assertAlmostEqual(c["depositor_share_of_gross_pct"], 55.4, places=1)

    def test_fees_and_depositor_exhaust_the_gross(self):
        c = run_cell(params(stage="growth", tvl=1_000_000.0, wood_price=0.05))
        legs = c["agent_usd"] + c["guardian_usd"] + c["protocol_usd"] + c["owner_usd"]
        self.assertAlmostEqual(legs + c["depositor_net_usd"], c["gross_return_usd"],
                               places=6)


class FeeSetLabels(unittest.TestCase):
    """Review of #294: the report printed 55.4% under a "500/3000" heading,
    because the label was a stored string and the fees under it were resolved
    from the live constants. Every label that names a fee pair must render it
    from the resolved values."""

    def test_symbol_resolved_label_carries_the_resolved_numbers(self):
        mgmt, perf, label, _ = resolve_fee_set("worst_stack", PROTO, ASSUMPTIONS)
        # the set reads both ceilings from Solidity, so this is the label that
        # went stale when they moved
        self.assertEqual(mgmt, PROTO.MAX_MANAGEMENT_FEE_BPS)
        self.assertEqual(perf, PROTO.MAX_PERFORMANCE_FEE_BPS)
        self.assertIn("%d/%d" % (mgmt, perf), label)
        self.assertTrue(label.endswith("%d/%d" % (mgmt, perf)), label)

    def test_every_fee_set_label_ends_in_its_own_resolved_pair(self):
        for name in sorted(ASSUMPTIONS.fee_sets):
            mgmt, perf, label, _ = resolve_fee_set(name, PROTO, ASSUMPTIONS)
            self.assertTrue(label.endswith("%d/%d" % (mgmt, perf)),
                            "%s: %r does not end in its resolved fees" % (name, label))

    def test_she330_is_pinned_to_history_not_to_the_live_caps(self):
        """#330's targets are a historical position. They must not track a
        constant this repo later moved, or the cell stops answering its own
        question."""
        mgmt, perf, label, _ = resolve_fee_set("she330_caps", PROTO, ASSUMPTIONS)
        self.assertEqual((mgmt, perf), (500, 1500))
        self.assertIn("500/1500", label)
        spec = ASSUMPTIONS.fee_sets["she330_caps"]
        self.assertIsInstance(spec["mgmt_bps"], int)
        self.assertIsInstance(spec["perf_bps"], int)

    def test_report_row_label_rerenders_a_stale_fee_pair(self):
        stale = {"label": "post-audit ceilings 500/3000", "mgmt_bps": 300, "perf_bps": 2500}
        self.assertEqual(report.cell_label(stale), "post-audit ceilings 300/2500")

    def test_report_row_label_leaves_a_label_without_fees_alone(self):
        row = {"label": "growth, 5 approvers", "mgmt_bps": 300, "perf_bps": 2500}
        self.assertEqual(report.cell_label(row), "growth, 5 approvers")

    def test_no_rendered_row_label_contradicts_its_own_fees(self):
        """The end-to-end version: run every scenario and check each rendered
        row label against the columns printed beside it.

        The committed scenarios all agree with their own fees today, so they
        alone cannot tell re-render from passthrough. The synthetic scenario
        below carries a label that disagrees on purpose, and is what makes
        this test fail if `cell_label` stops re-rendering (review of #294)."""
        stale = {
            "name": "stale-label-fixture",
            "title": "a scenario whose stored label names the OLD ceilings",
            "cells": [{"label": "mature at ceilings 500/3000",
                       "overrides": {"stage": "mature", "mgmt_bps": 300,
                                     "perf_bps": 2500}}],
        }
        tmp = tempfile.mkdtemp()
        try:
            with open(os.path.join(tmp, "stale-label-fixture.json"), "w",
                      encoding="utf-8") as fh:
                json.dump(stale, fh)
            sc = scen.run_all(PROTO, ASSUMPTIONS, directory=tmp)[0]
        finally:
            shutil.rmtree(tmp)
        rendered = report.cell_label(sc["rows"][0])
        self.assertEqual(rendered, "mature at ceilings 300/2500")
        self.assertNotIn("500/3000", rendered)

        for sc in scen.run_all(PROTO, ASSUMPTIONS):
            for row in sc["rows"]:
                label = report.cell_label(row)
                pair = "%d/%d" % (row["mgmt_bps"], row["perf_bps"])
                for token in label.replace(",", " ").split():
                    if token.count("/") == 1 and token.replace("/", "").isdigit():
                        self.assertEqual(token, pair,
                                         "%s / %s: label says %s, fees are %s"
                                         % (sc["name"], label, token, pair))


class BindingTvl(unittest.TestCase):
    def test_growth_25pct_of_float_at_5_cents(self):
        p = dossier_params(stage="growth", wood_price=0.05)
        self.assertAlmostEqual(binding_tvl(p, 0.25) / 1e6, 1.81, places=2)

    def test_binding_tvl_is_linear_in_threshold(self):
        p = params(stage="growth", wood_price=0.05)
        self.assertAlmostEqual(binding_tvl(p, 0.50), 2 * binding_tvl(p, 0.25), places=4)

    def test_binding_tvl_is_near_linear_in_price(self):
        """Doubling the WOOD price roughly doubles the capacity -- but not
        exactly. The vault-owner bond is a fixed WOOD amount per fund
        (max(minOwnerStake, MIN_OWNER_BOND_FLOOR)), not a USD amount, so that
        one leg does not shrink when the price rises. Everything else is
        USD-denominated and therefore exactly inversely proportional."""
        p = params(stage="growth", wood_price=0.05)
        q = params(stage="growth", wood_price=0.10)
        ratio = binding_tvl(q, 0.25) / binding_tvl(p, 0.25)
        self.assertLess(abs(ratio - 2.0), 0.01)
        self.assertLess(ratio, 2.0)   # the owner-bond leg is the drag

    def test_certification_is_the_only_order_of_magnitude_lever(self):
        base = binding_tvl(params(stage="growth", tier2_share=1.0, wood_price=0.05), 0.25)
        cert = binding_tvl(params(stage="growth", tier2_share=0.0, wood_price=0.05), 0.25)
        self.assertGreater(cert / base, 100.0)


class ReservationMode(unittest.TestCase):
    """SHE-227: shared reservation makes the cohort budget the coverage itself."""

    def test_cohort_multiplier(self):
        self.assertEqual(cohort_multiplier(params(approvers_per_proposal=5)), 5.0)
        self.assertEqual(
            cohort_multiplier(params(approvers_per_proposal=5,
                                     reservation_mode="shared")), 1.0)

    def test_shared_divides_cohort_budget_by_approvers_exactly(self):
        for n in (2, 3, 5, 7, 10, 25):
            full = wood_demand(params(stage="growth", approvers_per_proposal=n,
                                      reservation_mode="full", wood_price=0.05))
            shared = wood_demand(params(stage="growth", approvers_per_proposal=n,
                                        reservation_mode="shared", wood_price=0.05))
            self.assertAlmostEqual(shared["guardian_stake_budget_wood"] * n,
                                   full["guardian_stake_budget_wood"], places=4,
                                   msg="approvers=%d" % n)
            self.assertAlmostEqual(shared["stake_multiple_x_coverage"] * n,
                                   full["stake_multiple_x_coverage"], places=8,
                                   msg="approvers=%d" % n)

    def test_stake_multiple_is_approvers_over_haircut_over_k(self):
        p = params(stage="growth", approvers_per_proposal=7, wood_price=0.05)
        haircut = PROTO.WOOD_HAIRCUT_BPS / PROTO.bps
        self.assertAlmostEqual(wood_demand(p)["stake_multiple_x_coverage"],
                               7 / haircut / PROTO.K_NUMERATOR, places=8)

    def test_stake_multiple_is_price_invariant(self):
        a = wood_demand(params(stage="growth", wood_price=0.001))
        b = wood_demand(params(stage="growth", wood_price=1.0))
        self.assertAlmostEqual(a["stake_multiple_x_coverage"],
                               b["stake_multiple_x_coverage"], places=10)

    def test_reservation_mode_does_not_touch_the_fee_split(self):
        f = run_cell(params(stage="growth", reservation_mode="full"))
        s = run_cell(params(stage="growth", reservation_mode="shared"))
        self.assertAlmostEqual(f["depositor_share_of_gross_pct"],
                               s["depositor_share_of_gross_pct"], places=10)


class SlashMode(unittest.TestCase):
    """SHE-232: an allocated slash can never exceed the whole-stake slash."""

    def test_allocated_never_exceeds_whole(self):
        for approvers in (1, 2, 3, 5, 7, 10, 25, 100):
            for reservation in ("full", "shared"):
                for fund in (10_000.0, 100_000.0, 5_000_000.0):
                    for px in (0.00627821, 0.05, 1.0):
                        whole = worked_proposal(
                            params(approvers_per_proposal=approvers,
                                   reservation_mode=reservation, slash_mode="whole",
                                   wood_price=px),
                            fund, 0.10, 14, slashed=True)
                        alloc = worked_proposal(
                            params(approvers_per_proposal=approvers,
                                   reservation_mode=reservation, slash_mode="allocated",
                                   wood_price=px),
                            fund, 0.10, 14, slashed=True)
                        self.assertLessEqual(
                            alloc["slashed_wood"], whole["slashed_wood"] * (1 + 1e-12),
                            msg="approvers=%d reservation=%s fund=%s price=%s"
                                % (approvers, reservation, fund, px))
                        self.assertLessEqual(alloc["total_burned_wood"],
                                             whole["total_burned_wood"] * (1 + 1e-12))

    def test_allocated_is_exactly_one_approvers_share(self):
        p = params(approvers_per_proposal=4, slash_mode="allocated", wood_price=0.05)
        q = params(approvers_per_proposal=4, slash_mode="whole", wood_price=0.05)
        a = worked_proposal(p, 100_000.0, 0.10, 14, slashed=True)
        w = worked_proposal(q, 100_000.0, 0.10, 14, slashed=True)
        self.assertAlmostEqual(a["slashed_wood"] * 4, w["slashed_wood"], places=6)

    def test_equal_at_one_approver(self):
        a = worked_proposal(params(approvers_per_proposal=1, slash_mode="allocated"),
                            100_000.0, 0.10, 14, slashed=True)
        w = worked_proposal(params(approvers_per_proposal=1, slash_mode="whole"),
                            100_000.0, 0.10, 14, slashed=True)
        self.assertAlmostEqual(a["slashed_wood"], w["slashed_wood"], places=8)

    def test_the_depositor_is_paid_nothing_under_either_mode(self):
        for mode in ("whole", "allocated"):
            w = worked_proposal(params(slash_mode=mode), 100_000.0, 0.10, 14,
                                slashed=True)
            self.assertEqual(w["paid_to_depositor_usd"], 0.0)


class PricePath(unittest.TestCase):
    def test_flat_path_matches_flat_price(self):
        flat = run_cell(params(stage="growth", wood_price=0.05))
        path = run_cell(params(stage="growth", wood_price=0.05,
                               wood_price_path=[[0, 0.05], [11, 0.05]]))
        self.assertAlmostEqual(flat["wood_locked_total"], path["wood_locked_total"],
                               places=4)

    def test_binding_tvl_uses_the_worst_month(self):
        p = params(stage="growth", wood_price=0.05,
                   wood_price_path=[[0, 0.05], [11, 0.01]])
        cheap = params(stage="growth", wood_price=0.01)
        self.assertAlmostEqual(binding_tvl(p, 0.25), binding_tvl(cheap, 0.25), places=4)

    def test_a_rerate_lowers_average_lockup(self):
        crash = run_cell(params(stage="growth", wood_price=0.05,
                                wood_price_path=[[0, 0.05], [11, 0.01]]))
        rally = run_cell(params(stage="growth", wood_price=0.05,
                                wood_price_path=[[0, 0.05], [11, 0.20]]))
        self.assertLess(rally["wood_locked_total"], crash["wood_locked_total"])


class OverrideHygiene(unittest.TestCase):
    def test_unknown_override_raises(self):
        with self.assertRaises(KeyError):
            params(tier_2_share=1.0)      # typo for tier2_share

    def test_bad_mode_raises(self):
        with self.assertRaises(ValueError):
            params(reservation_mode="pooled")
        with self.assertRaises(ValueError):
            params(slash_mode="partial")

    def test_approvers_above_the_protocol_cap_raises(self):
        with self.assertRaises(ValueError):
            params(approvers_per_proposal=PROTO.MAX_APPROVERS_PER_PROPOSAL + 1)


class ScenarioLibrary(unittest.TestCase):
    def test_every_scenario_file_loads_and_runs(self):
        results = scen.run_all(PROTO, ASSUMPTIONS)
        self.assertGreaterEqual(len(results), 10)
        for sc in results:
            self.assertTrue(sc["rows"], "%s produced no rows" % sc["name"])
            for row in sc["rows"]:
                self.assertGreater(row["gross_return_usd"], 0)
                self.assertGreater(row["wood_locked_total"], 0)
                self.assertGreater(row["binding_tvl_25pct_float"], 0)

    def test_the_named_scenarios_are_all_present(self):
        names = set(scen.list_names())
        for required in ("launch-as-is", "certified-adapters", "shared-coverage",
                         "allocated-slash", "mechanism-combined", "approver-ladder",
                         "fee-ladder", "cadence", "price-path", "reference-cells"):
            self.assertIn(required, names)

    def test_sensitivity_ranks_reservation_mode_top_for_binding_tvl(self):
        blocks = sensitivity.tornado(PROTO, ASSUMPTIONS)
        tvl = [b for b in blocks if b["metric"] == "binding_tvl_25pct_float"][0]
        self.assertEqual(tvl["rows"][0]["attr"], "reservation_mode")
        dep = [b for b in blocks if b["metric"] == "depositor_share_of_gross_pct"][0]
        self.assertEqual(dep["rows"][0]["attr"], "perf_bps")


class ConstantExtraction(unittest.TestCase):
    def test_source_matches_the_lock(self):
        drift, _moved = xc.diff_against_lock(xc.extract())
        self.assertEqual(drift, [], "constants drifted:\n%s"
                         % xc.format_drift(drift, []))

    def test_every_extracted_constant_carries_provenance(self):
        for name, rec in xc.extract().items():
            self.assertTrue(rec["file"], name)
            self.assertGreater(rec["line"], 0, name)
            self.assertTrue(rec["note"].strip(), name)

    def test_missing_source_file_fails_loudly(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(xc.ExtractionError) as cm:
                xc.extract(tmp)
            self.assertIn("source file missing", str(cm.exception))

    def test_unmatched_pattern_fails_loudly(self):
        """A constant that has been renamed away must raise, never fall back."""
        with tempfile.TemporaryDirectory() as tmp:
            for spec in xc.SPECS:
                dst = os.path.join(tmp, spec["file"])
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                if not os.path.exists(dst):
                    with open(dst, "w") as fh:
                        fh.write("// nothing to see here\n")
            with self.assertRaises(xc.ExtractionError) as cm:
                xc.extract(tmp)
            self.assertIn("NO MATCH", str(cm.exception))


class DriftDetector(unittest.TestCase):
    """Mutate a copy of a Solidity file and assert `--check` exits non-zero."""

    def _mirror(self, tmp):
        for rel in {s["file"] for s in xc.SPECS}:
            dst = os.path.join(tmp, rel)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copyfile(os.path.join(xc.REPO_ROOT, rel), dst)

    def _check(self, root):
        return subprocess.run(
            [sys.executable, os.path.join(HERE, "extract_constants.py"),
             "--check", "--repo-root", root],
            capture_output=True, text=True)

    def test_clean_copy_passes(self):
        with tempfile.TemporaryDirectory() as tmp:
            self._mirror(tmp)
            res = self._check(tmp)
            self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
            self.assertIn("No constant drift", res.stdout)

    def test_mutated_constant_is_caught(self):
        with tempfile.TemporaryDirectory() as tmp:
            self._mirror(tmp)
            target = os.path.join(tmp, "src", "ProtocolConfig.sol")
            with open(target) as fh:
                text = fh.read()
            mutated = text.replace("guardianBps: 2500", "guardianBps: 1500", 1)
            self.assertNotEqual(text, mutated, "mutation did not apply")
            with open(target, "w") as fh:
                fh.write(mutated)

            res = self._check(tmp)
            self.assertNotEqual(res.returncode, 0,
                                "drift checker passed a mutated constant")
            self.assertIn("CONSTANT DRIFT", res.stdout)
            self.assertIn("PERF_SPLIT_GUARDIAN_BPS", res.stdout)
            self.assertIn("2500 -> 1500", res.stdout)

    def test_mutated_deploy_script_is_caught(self):
        with tempfile.TemporaryDirectory() as tmp:
            self._mirror(tmp)
            target = os.path.join(tmp, "script", "DeployPlanB.s.sol")
            with open(target) as fh:
                text = fh.read()
            mutated = text.replace("DEFAULT_WOOD_HAIRCUT_BPS = 5_000",
                                   "DEFAULT_WOOD_HAIRCUT_BPS = 6_500", 1)
            self.assertNotEqual(text, mutated, "mutation did not apply")
            with open(target, "w") as fh:
                fh.write(mutated)

            res = self._check(tmp)
            self.assertNotEqual(res.returncode, 0)
            self.assertIn("WOOD_HAIRCUT_BPS", res.stdout)


class RunnerSmoke(unittest.TestCase):
    def test_run_py_end_to_end(self):
        with tempfile.TemporaryDirectory() as tmp:
            res = subprocess.run(
                [sys.executable, os.path.join(HERE, "run.py"), "--out", tmp,
                 "--scenario", "shared-coverage", "--no-sensitivity"],
                capture_output=True, text=True)
            self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
            for name in ("report.md", "report.html", "results.json"):
                path = os.path.join(tmp, name)
                self.assertTrue(os.path.exists(path), "%s not written" % name)
                self.assertGreater(os.path.getsize(path), 500)

    def test_list_exits_clean(self):
        res = subprocess.run([sys.executable, os.path.join(HERE, "run.py"), "--list"],
                             capture_output=True, text=True)
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("shared-coverage", res.stdout)

    def test_html_report_is_self_contained(self):
        with tempfile.TemporaryDirectory() as tmp:
            subprocess.run([sys.executable, os.path.join(HERE, "run.py"), "--out", tmp,
                            "--scenario", "reference-cells", "--no-sensitivity"],
                           capture_output=True, text=True, check=True)
            with open(os.path.join(tmp, "report.html")) as fh:
                html = fh.read()
            for forbidden in ("<script", "src=\"http", "href=\"http", "@import",
                              "url(http"):
                self.assertNotIn(forbidden, html,
                                 "report.html is not self-contained: found %r"
                                 % forbidden)
            self.assertIn("prefers-color-scheme", html)


if __name__ == "__main__":
    unittest.main(verbosity=2)
