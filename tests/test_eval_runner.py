#!/usr/bin/env python3
import json
import pathlib
import sys
import tempfile
import textwrap
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from eval.run import run_case, select_fixtures
from tests.test_eval_schema import valid_fixture


class EvalRunnerTest(unittest.TestCase):
    def make_fixture(self, root):
        fixture = valid_fixture()
        fixture["repo_fixture"] = "target"
        fixture_path = root / "fixture.json"
        fixture_path.write_text(json.dumps(fixture), encoding="utf-8")
        repo_root = root / "repos"
        target = repo_root / "target"
        target.mkdir(parents=True)
        (target / "input.txt").write_text("original\n", encoding="utf-8")
        return fixture_path, repo_root

    def test_run_case_isolates_workspace_home_and_captures_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            fixture_path, repo_root = self.make_fixture(root)
            provider = root / "provider.py"
            provider.write_text(
                textwrap.dedent(
                    """
                    import json, os, pathlib
                    cwd = pathlib.Path.cwd()
                    (cwd / "input.txt").write_text("changed\\n")
                    payload = {
                        "fixture": os.environ["TIERS_FIXTURE"],
                        "variant": os.environ["TIERS_VARIANT"],
                        "run_dir": os.environ["TIERS_RUN_DIR"],
                        "codex_home": os.environ["CODEX_HOME"],
                        "cwd": str(cwd),
                    }
                    print(json.dumps(payload))
                    """
                ),
                encoding="utf-8",
            )

            run_dir = run_case(
                fixture_path,
                "candidate",
                f"{sys.executable} {provider}",
                root / "results",
                repo_fixtures_root=repo_root,
            )

            metadata = json.loads((run_dir / "run.json").read_text(encoding="utf-8"))
            payload = json.loads((run_dir / "stdout.txt").read_text(encoding="utf-8"))
            self.assertEqual(metadata["status"], "ok")
            self.assertEqual(metadata["exit_code"], 0)
            self.assertEqual(payload["variant"], "candidate")
            self.assertEqual(pathlib.Path(payload["cwd"]), run_dir / "workspace")
            self.assertEqual(pathlib.Path(payload["codex_home"]), run_dir / "codex-home")
            self.assertEqual(
                (repo_root / "target" / "input.txt").read_text(encoding="utf-8"),
                "original\n",
            )

    def test_timeout_is_an_infrastructure_error(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            fixture_path, repo_root = self.make_fixture(root)
            run_dir = run_case(
                fixture_path,
                "baseline",
                f'{sys.executable} -c "import time; time.sleep(2)"',
                root / "results",
                timeout=0.05,
                repo_fixtures_root=repo_root,
            )
            metadata = json.loads((run_dir / "run.json").read_text(encoding="utf-8"))
            self.assertEqual(metadata["status"], "infrastructure_error")
            self.assertEqual(metadata["error_type"], "timeout")

    def test_missing_provider_is_an_infrastructure_error(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            fixture_path, repo_root = self.make_fixture(root)
            run_dir = run_case(
                fixture_path,
                "baseline",
                "definitely-not-a-real-provider --json",
                root / "results",
                repo_fixtures_root=repo_root,
            )
            metadata = json.loads((run_dir / "run.json").read_text(encoding="utf-8"))
            self.assertEqual(metadata["status"], "infrastructure_error")
            self.assertEqual(metadata["error_type"], "missing_provider")

    def test_suite_selection_and_repetitions_do_not_overwrite(self):
        fixtures_root = ROOT / "eval" / "fixtures"
        self.assertEqual(len(select_fixtures("smoke", fixtures_root)), 12)
        self.assertEqual(len(select_fixtures("release", fixtures_root)), 24)

        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            fixture_path, repo_root = self.make_fixture(root)
            first = run_case(
                fixture_path,
                "candidate",
                f'{sys.executable} -c "print(1)"',
                root / "results",
                repetition=1,
                repo_fixtures_root=repo_root,
            )
            second = run_case(
                fixture_path,
                "candidate",
                f'{sys.executable} -c "print(2)"',
                root / "results",
                repetition=2,
                repo_fixtures_root=repo_root,
            )
            self.assertNotEqual(first, second)
            self.assertTrue(first.is_dir())
            self.assertTrue(second.is_dir())


if __name__ == "__main__":
    unittest.main()
