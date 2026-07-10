#!/usr/bin/env python3
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from eval.provider_codex import build_prompt, materialize_plugin, parse_codex_jsonl
from tests.test_eval_schema import valid_fixture


class EvalCodexProviderTest(unittest.TestCase):
    def test_materialize_plugin_uses_requested_git_ref(self):
        with tempfile.TemporaryDirectory() as temporary:
            repo = pathlib.Path(temporary) / "source"
            repo.mkdir()
            subprocess.run(["git", "init", "-q", str(repo)], check=True)
            subprocess.run(["git", "-C", str(repo), "config", "user.email", "t@example.com"], check=True)
            subprocess.run(["git", "-C", str(repo), "config", "user.name", "Test"], check=True)
            marker = repo / "marker.txt"
            marker.write_text("baseline\n", encoding="utf-8")
            subprocess.run(["git", "-C", str(repo), "add", "marker.txt"], check=True)
            subprocess.run(["git", "-C", str(repo), "commit", "-q", "-m", "baseline"], check=True)
            baseline = subprocess.check_output(
                ["git", "-C", str(repo), "rev-parse", "HEAD"], text=True
            ).strip()
            marker.write_text("candidate\n", encoding="utf-8")
            subprocess.run(["git", "-C", str(repo), "commit", "-qam", "candidate"], check=True)
            destination = pathlib.Path(temporary) / "plugin"

            materialize_plugin(repo, baseline, destination)

            self.assertEqual((destination / "marker.txt").read_text(encoding="utf-8"), "baseline\n")
            self.assertFalse((destination / ".git").exists())

    def test_goal_prompt_declares_existing_goal_without_faking_user_approval(self):
        fixture = valid_fixture()
        prompt = build_prompt(fixture)
        self.assertIn("The user has already created a Goal", prompt)
        self.assertIn("autonomous confirmation", prompt)
        self.assertIn(fixture["prompt"], prompt)
        self.assertNotIn("user approved", prompt.casefold())

    def test_parse_codex_jsonl_extracts_final_and_successful_test_command(self):
        lines = [
            json.dumps(
                {
                    "item": {
                        "type": "command_execution",
                        "command": "bash tests/all.sh",
                        "exit_code": 0,
                    }
                }
            ),
            json.dumps(
                {"item": {"type": "agent_message", "text": "级别 = L3｜理由 = bug"}}
            ),
            json.dumps({"type": "turn.completed"}),
        ]

        parsed = parse_codex_jsonl("\n".join(lines))

        self.assertEqual(parsed["final"], "级别 = L3｜理由 = bug")
        self.assertEqual(parsed["tests"], {"observed": True, "exit_code": 0})


if __name__ == "__main__":
    unittest.main()
