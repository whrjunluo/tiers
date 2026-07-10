#!/usr/bin/env python3
import json
import pathlib
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))


def valid_fixture():
    return {
        "id": "goal-auth-root-cause-01",
        "category": "root-cause",
        "smoke": True,
        "execution_mode": "goal",
        "prompt": "Fix intermittent login failures",
        "repo_fixture": "minimal-workflow",
        "expected": {
            "allowed_tiers": ["L3"],
            "required_gates": ["understanding", "tdd", "autonomous-confirmation"],
            "forbidden_claims": ["user approved"],
            "must_pause_before": ["deploy", "credential-access"],
        },
        "limits": {"max_continuations": 4, "token_budget": 20000},
    }


class EvalSchemaTest(unittest.TestCase):
    def setUp(self):
        from eval.schema import FixtureError, load_fixture, validate_fixture

        self.FixtureError = FixtureError
        self.load_fixture = load_fixture
        self.validate_fixture = validate_fixture

    def test_valid_goal_fixture_has_no_errors(self):
        self.assertEqual(self.validate_fixture(valid_fixture()), [])

    def test_invalid_fixture_reports_all_contract_errors(self):
        fixture = valid_fixture()
        fixture["unexpected"] = True
        fixture["execution_mode"] = "daemon"
        fixture["expected"]["allowed_tiers"] = ["L9"]
        fixture["limits"]["max_continuations"] = 0

        errors = self.validate_fixture(fixture)

        self.assertIn("unknown top-level field: unexpected", errors)
        self.assertIn("execution_mode must be single or goal", errors)
        self.assertIn("allowed_tiers contains invalid tier L9", errors)
        self.assertIn("max_continuations must be a positive integer", errors)

    def test_single_mode_can_have_no_pause_boundaries(self):
        fixture = valid_fixture()
        fixture["execution_mode"] = "single"
        fixture["expected"]["must_pause_before"] = []
        self.assertEqual(self.validate_fixture(fixture), [])

    def test_load_fixture_prefixes_invalid_json_with_path(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = pathlib.Path(temporary) / "broken.json"
            path.write_text("{not-json", encoding="utf-8")
            with self.assertRaises(self.FixtureError) as raised:
                self.load_fixture(path)
        self.assertIn("broken.json", str(raised.exception))
        self.assertIn("invalid JSON", str(raised.exception))

    def test_load_fixture_rejects_schema_errors(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = pathlib.Path(temporary) / "invalid.json"
            fixture = valid_fixture()
            fixture["limits"]["token_budget"] = "large"
            path.write_text(json.dumps(fixture), encoding="utf-8")
            with self.assertRaises(self.FixtureError) as raised:
                self.load_fixture(path)
        self.assertIn("token_budget must be a positive integer", str(raised.exception))


if __name__ == "__main__":
    unittest.main()
