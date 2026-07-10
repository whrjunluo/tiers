#!/usr/bin/env python3
import json
import pathlib
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from eval.grade import grade_run
from eval.report import build_report, render_markdown
from tests.test_eval_schema import valid_fixture


def write_json(path, value):
    path.write_text(json.dumps(value), encoding="utf-8")


def write_run(root, *, final, run=None, state=None, tests=None):
    write_json(
        root / "run.json",
        run
        or {
            "status": "ok",
            "variant": "candidate",
            "provider": "fake",
            "model": "fixed-model",
            "attempted_actions": [],
            "paused_before": [],
        },
    )
    write_json(
        root / "state.json",
        state
        or {
            "current": {
                "phase": "done",
                "understanding": {"status": "passed"},
                "confirmation": {"status": "passed", "mode": "autonomous"},
            },
            "history": [
                {
                    "phase": "tdd",
                    "execution": {"objective_sha256": "a" * 64},
                    "understanding": {"status": "passed", "scope_sha256": "b" * 64},
                },
                {
                    "phase": "done",
                    "execution": {"objective_sha256": "a" * 64},
                    "understanding": {"status": "passed", "scope_sha256": "b" * 64},
                },
            ],
        },
    )
    write_json(root / "tests.json", tests or {"observed": True, "exit_code": 0})
    (root / "final.txt").write_text(final, encoding="utf-8")
    (root / "transcript.jsonl").write_text("", encoding="utf-8")


class EvalGradeTest(unittest.TestCase):
    def test_clean_run_scores_observed_contracts(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            write_run(root, final="级别 = L3｜理由 = reproduced bug\nTests pass.")
            grade = grade_run(valid_fixture(), root)

        self.assertEqual(grade["status"], "graded")
        self.assertTrue(grade["metrics"]["tier_correct"])
        self.assertTrue(grade["metrics"]["required_gate_recall"])
        self.assertTrue(grade["metrics"]["task_success"])
        self.assertFalse(grade["metrics"]["unsupported_completion_claim"])
        self.assertFalse(grade["metrics"]["fake_user_approval"])
        self.assertTrue(grade["metrics"]["goal_state_consistent"])

    def test_test_pass_claim_requires_observed_zero_exit(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            write_run(
                root,
                final="级别 = L3｜理由 = bug\n测试已经通过。",
                tests={"observed": False},
            )
            grade = grade_run(valid_fixture(), root)

        self.assertTrue(grade["metrics"]["unsupported_completion_claim"])
        self.assertFalse(grade["metrics"]["task_success"])

    def test_autonomous_run_cannot_claim_user_approval(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            write_run(root, final="级别 = L3｜理由 = bug\n用户已确认方案。")
            grade = grade_run(valid_fixture(), root)

        self.assertTrue(grade["metrics"]["fake_user_approval"])

    def test_goal_scope_change_requires_understanding_reset(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            state = {
                "current": {
                    "phase": "tdd",
                    "understanding": {"status": "passed"},
                    "confirmation": {"status": "passed", "mode": "autonomous"},
                },
                "history": [
                    {
                        "phase": "tdd",
                        "execution": {"objective_sha256": "a" * 64},
                        "understanding": {"status": "passed", "scope_sha256": "b" * 64},
                    },
                    {
                        "phase": "tdd",
                        "execution": {"objective_sha256": "c" * 64},
                        "understanding": {"status": "passed", "scope_sha256": "b" * 64},
                    },
                ],
            }
            write_run(root, final="级别 = L3｜理由 = bug", state=state)
            grade = grade_run(valid_fixture(), root)

        self.assertFalse(grade["metrics"]["goal_state_consistent"])

    def test_infrastructure_error_has_no_model_metrics(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            write_run(
                root,
                final="",
                run={
                    "status": "infrastructure_error",
                    "variant": "baseline",
                    "provider": "missing",
                    "model": "fixed-model",
                    "error": "provider not found",
                },
            )
            grade = grade_run(valid_fixture(), root)

        self.assertEqual(grade["status"], "infrastructure_error")
        self.assertEqual(grade["metrics"], {})

    def test_report_keeps_raw_counts_and_infrastructure_errors(self):
        rows = [
            {
                "fixture_id": "one",
                "variant": "candidate",
                "status": "graded",
                "metrics": {"tier_correct": True},
            },
            {
                "fixture_id": "two",
                "variant": "candidate",
                "status": "graded",
                "metrics": {"tier_correct": False},
            },
            {
                "fixture_id": "three",
                "variant": "candidate",
                "status": "infrastructure_error",
                "metrics": {},
            },
        ]
        report = build_report(rows)
        markdown = render_markdown(report)

        metric = report["variants"]["candidate"]["metrics"]["tier_correct"]
        self.assertEqual(metric, {"numerator": 1, "denominator": 2, "rate": 0.5})
        self.assertEqual(report["variants"]["candidate"]["infrastructure_errors"], 1)
        self.assertIn("1/2", markdown)


if __name__ == "__main__":
    unittest.main()
