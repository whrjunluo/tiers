#!/usr/bin/env python3
import importlib.util
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
MANIFEST_PATH = ROOT / "scripts" / "execution_manifest.py"

spec = importlib.util.spec_from_file_location("execution_manifest", MANIFEST_PATH)
manifest = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manifest)


REPOSITORY = "a" * 64
BASE = "b" * 64
PLAN = "c" * 64


def valid_manifest():
    return {
        "runner": "tiers.execution-manifest/v1",
        "mode": "multi-agent",
        "repository": REPOSITORY,
        "base": BASE,
        "plan_sha": PLAN,
        "max_workers": 2,
        "tasks": [
            {
                "id": "validator",
                "status": "ready",
                "dependencies": [],
                "write_set": ["scripts/execution_manifest.py"],
                "worktree": ".worktrees/validator",
            },
            {
                "id": "tests",
                "status": "ready",
                "dependencies": [],
                "write_set": ["tests/test_execution_manifest.py"],
                "worktree": ".worktrees/tests",
            },
        ],
    }


class ExecutionManifestTest(unittest.TestCase):
    def setUp(self):
        self.repo = REPOSITORY
        self.base = BASE
        self.plan = PLAN

    def test_valid_manifest_reports_worker_limit(self):
        result = manifest.validate_manifest(valid_manifest(), self.repo, self.base, self.plan)
        self.assertEqual(result, [])

    def test_rejects_fewer_than_two_ready_tasks(self):
        data = valid_manifest()
        data["tasks"][1]["status"] = "pending"
        self.assertIn("at least two tasks must be ready", manifest.validate_manifest(data, self.repo, self.base, self.plan))

    def test_rejects_unmet_dependency_for_ready_task(self):
        data = valid_manifest()
        data["tasks"][1]["dependencies"] = ["validator"]
        self.assertIn("ready task tests has unmet dependency validator", manifest.validate_manifest(data, self.repo, self.base, self.plan))

    def test_rejects_dependency_cycle_even_when_no_task_is_ready(self):
        data = valid_manifest()
        data["tasks"][0]["status"] = "pending"
        data["tasks"][0]["dependencies"] = ["tests"]
        data["tasks"][1]["status"] = "pending"
        data["tasks"][1]["dependencies"] = ["validator"]
        self.assertIn("dependency cycle detected: validator -> tests -> validator", manifest.validate_manifest(data, self.repo, self.base, self.plan))

    def test_rejects_overlapping_write_sets(self):
        data = valid_manifest()
        data["tasks"][1]["write_set"] = ["scripts/execution_manifest.py"]
        self.assertIn("write sets overlap", manifest.validate_manifest(data, self.repo, self.base, self.plan)[0])

    def test_allows_sequential_tasks_to_reuse_a_write_set(self):
        data = valid_manifest()
        data["tasks"].append(
            {
                "id": "follow-up",
                "status": "pending",
                "dependencies": ["validator"],
                "write_set": ["scripts/execution_manifest.py"],
                "worktree": ".worktrees/follow-up",
            }
        )
        self.assertEqual(manifest.validate_manifest(data, self.repo, self.base, self.plan), [])

    def test_rejects_missing_write_set(self):
        data = valid_manifest()
        del data["tasks"][0]["write_set"]
        self.assertIn("task validator must declare a write_set", manifest.validate_manifest(data, self.repo, self.base, self.plan))

    def test_rejects_empty_write_set_for_write_task(self):
        data = valid_manifest()
        data["tasks"][0]["write_set"] = []
        self.assertIn("task validator write_set must not be empty", manifest.validate_manifest(data, self.repo, self.base, self.plan))

    def test_rejects_invalid_repository_base_and_plan_hashes(self):
        data = valid_manifest()
        data["repository"] = "invalid"
        data["base"] = "d" * 64
        data["plan_sha"] = "invalid"
        errors = manifest.validate_manifest(data, self.repo, self.base, self.plan)
        self.assertIn("repository must be a 64-hex hash", errors)
        self.assertIn("base does not match expected base", errors)
        self.assertIn("plan_sha must be a 64-hex hash", errors)

    def test_rejects_worker_limits_outside_one_to_three(self):
        for workers in (0, 4):
            with self.subTest(workers=workers):
                data = valid_manifest()
                data["max_workers"] = workers
                self.assertIn("max_workers must be between 1 and 3", manifest.validate_manifest(data, self.repo, self.base, self.plan))

    def test_rejects_write_task_without_worktree_under_repo(self):
        data = valid_manifest()
        data["tasks"][0]["worktree"] = "/tmp/validator"
        self.assertIn("task validator worktree must be under .worktrees/", manifest.validate_manifest(data, self.repo, self.base, self.plan))

    def test_rejects_worktree_path_that_escapes_worktrees_directory(self):
        data = valid_manifest()
        data["tasks"][0]["worktree"] = ".worktrees/../validator"
        self.assertIn("task validator worktree must be under .worktrees/", manifest.validate_manifest(data, self.repo, self.base, self.plan))

    def test_allows_read_only_task_without_worktree(self):
        data = valid_manifest()
        data["tasks"][0] = {
            "id": "review",
            "status": "ready",
            "dependencies": [],
            "read_only": True,
        }
        self.assertEqual(manifest.validate_manifest(data, self.repo, self.base, self.plan), [])

    def test_rejects_manifest_without_explicit_mode(self):
        data = valid_manifest()
        del data["mode"]
        self.assertIn("mode must be multi-agent", manifest.validate_manifest(data, self.repo, self.base, self.plan))

    def test_cli_emits_json_for_valid_and_invalid_manifests(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = pathlib.Path(temporary) / "manifest.json"
            path.write_text(json.dumps(valid_manifest()), encoding="utf-8")
            command = [
                sys.executable,
                str(MANIFEST_PATH),
                "--validate",
                str(path),
                "--repo",
                self.repo,
                "--base",
                self.base,
                "--plan-sha",
                self.plan,
            ]
            valid = subprocess.run(command, capture_output=True, text=True, check=False)
            invalid_data = valid_manifest()
            invalid_data["max_workers"] = 4
            path.write_text(json.dumps(invalid_data), encoding="utf-8")
            invalid = subprocess.run(command, capture_output=True, text=True, check=False)
        self.assertEqual(valid.returncode, 0)
        self.assertEqual(json.loads(valid.stdout), {"valid": True, "max_workers": 2})
        self.assertEqual(invalid.returncode, 1)
        self.assertFalse(json.loads(invalid.stdout)["valid"])
        self.assertTrue(json.loads(invalid.stdout)["errors"])

    def test_cli_returns_json_for_malformed_utf8_manifest(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = pathlib.Path(temporary) / "manifest.json"
            path.write_bytes(b"\xff")
            completed = subprocess.run(
                [
                    sys.executable,
                    str(MANIFEST_PATH),
                    "--validate",
                    str(path),
                    "--repo",
                    self.repo,
                    "--base",
                    self.base,
                    "--plan-sha",
                    self.plan,
                ],
                capture_output=True,
                text=True,
                check=False,
            )
        self.assertEqual(completed.returncode, 1)
        result = json.loads(completed.stdout)
        self.assertFalse(result["valid"])
        self.assertTrue(result["errors"])
        self.assertNotIn("Traceback", completed.stderr)


if __name__ == "__main__":
    unittest.main()
