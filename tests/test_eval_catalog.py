#!/usr/bin/env python3
import collections
import pathlib
import sys
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from eval.schema import CATEGORIES, load_fixture


class EvalCatalogTest(unittest.TestCase):
    def test_catalog_has_expected_coverage(self):
        paths = sorted((ROOT / "eval" / "fixtures").glob("*.json"))
        fixtures = [load_fixture(path) for path in paths]
        ids = [fixture["id"] for fixture in fixtures]
        counts = collections.Counter(fixture["category"] for fixture in fixtures)

        self.assertEqual(len(fixtures), 24)
        self.assertEqual(len(set(ids)), 24)
        self.assertEqual(set(counts), CATEGORIES)
        self.assertTrue(all(count == 3 for count in counts.values()))
        self.assertEqual(sum(fixture["smoke"] for fixture in fixtures), 12)

    def test_every_repo_fixture_exists(self):
        for path in sorted((ROOT / "eval" / "fixtures").glob("*.json")):
            fixture = load_fixture(path)
            repo = ROOT / "eval" / "repos" / fixture["repo_fixture"]
            self.assertTrue(repo.is_dir(), f"missing repo fixture for {fixture['id']}")

    def test_goal_cases_have_multiple_continuations(self):
        fixtures = [
            load_fixture(path)
            for path in sorted((ROOT / "eval" / "fixtures").glob("*.json"))
        ]
        goal_cases = [fixture for fixture in fixtures if fixture["execution_mode"] == "goal"]
        self.assertGreaterEqual(len(goal_cases), 6)
        self.assertTrue(
            all(fixture["limits"]["max_continuations"] >= 2 for fixture in goal_cases)
        )

    def test_smoke_gold_accepts_context_dependent_tiers(self):
        fixtures = {
            path.stem: load_fixture(path)
            for path in (ROOT / "eval" / "fixtures").glob("*.json")
        }
        clarification = fixtures["clarify-ambiguous-product-choice"]["expected"]
        self.assertEqual(set(clarification["allowed_tiers"]), {"L1", "L2"})

        fidelity = fixtures["evidence-fail-plus-pass"]["expected"]
        self.assertEqual(set(fidelity["allowed_tiers"]), {"L1", "L2", "L3", "L4"})
        self.assertNotIn("understanding", fidelity["required_gates"])

        new_workflow = fixtures["tier-new-workflow-behavior"]["expected"]
        self.assertEqual(new_workflow["required_gates"], [])
        self.assertEqual(new_workflow["must_pause_before"], ["product-choice"])


if __name__ == "__main__":
    unittest.main()
