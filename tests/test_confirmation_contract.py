#!/usr/bin/env python3
import importlib.util
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
CONTRACT_PATH = ROOT / "scripts" / "confirmation_contract.py"

spec = importlib.util.spec_from_file_location("confirmation_contract", CONTRACT_PATH)
contract = importlib.util.module_from_spec(spec)
spec.loader.exec_module(contract)


SCOPE = "a" * 64


def valid_artifact():
    return {
        "runner": "tiers.autonomous-confirmation/v1",
        "mode": "autonomous",
        "status": "PASS",
        "scope_sha256": SCOPE,
        "rounds": 1,
        "requires_user": False,
        "boundary": "safe",
        "proposal": {
            "options": [
                {"id": "A", "summary": "Use the repository pattern"},
                {"id": "B", "summary": "Add a local adapter"},
            ],
            "recommendation": "A",
            "assumptions": ["The existing API remains stable"],
        },
        "critic": {
            "provenance": "built-in-checklist",
            "verdict": "PASS",
            "findings": ["No irreversible action is required"],
        },
        "decision": {
            "choice": "A",
            "basis": "Matches the current repository pattern",
            "assumptions": ["The change remains local"],
            "residual_risk": "Provider behavior still needs tests",
        },
    }


class ConfirmationContractTest(unittest.TestCase):
    def test_valid_artifact_has_no_errors(self):
        self.assertEqual(contract.validate_artifact(valid_artifact(), SCOPE), [])

    def test_rejects_scope_round_boundary_and_user_requirement(self):
        artifact = valid_artifact()
        artifact["scope_sha256"] = "b" * 64
        artifact["rounds"] = 3
        artifact["boundary"] = "deploy"
        artifact["requires_user"] = True
        errors = contract.validate_artifact(artifact, SCOPE)
        self.assertIn("scope_sha256 does not match current understanding scope", errors)
        self.assertIn("rounds must be 1 or 2", errors)
        self.assertIn("boundary must be safe", errors)
        self.assertIn("requires_user must be false", errors)

    def test_rejects_invalid_options_provenance_and_choice(self):
        artifact = valid_artifact()
        artifact["proposal"]["options"] = [{"id": "A", "summary": "Only option"}]
        artifact["critic"]["provenance"] = "imaginary-independent-agent"
        artifact["decision"]["choice"] = "C"
        errors = contract.validate_artifact(artifact, SCOPE)
        self.assertIn("proposal.options must contain 2 or 3 unique options", errors)
        self.assertIn("critic.provenance is not allowed", errors)
        self.assertIn("decision.choice must reference a proposal option", errors)

    def test_rejects_revise_as_persistent_pass_artifact(self):
        artifact = valid_artifact()
        artifact["status"] = "REVISE"
        errors = contract.validate_artifact(artifact, SCOPE)
        self.assertIn("status must be PASS", errors)

    def test_rejects_fake_user_approval_at_any_depth(self):
        for text in ("用户已确认这个方案", "The user approved this decision"):
            artifact = valid_artifact()
            artifact["critic"]["findings"] = [text]
            errors = contract.validate_artifact(artifact, SCOPE)
            self.assertIn("artifact must not claim user approval", errors)

    def test_cli_returns_clean_nonzero_for_invalid_artifact(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = pathlib.Path(temporary) / "confirmation.json"
            artifact = valid_artifact()
            artifact["boundary"] = "unsafe"
            path.write_text(json.dumps(artifact), encoding="utf-8")
            completed = subprocess.run(
                [
                    sys.executable,
                    str(CONTRACT_PATH),
                    "--validate",
                    str(path),
                    "--scope",
                    SCOPE,
                ],
                capture_output=True,
                text=True,
                check=False,
            )
        self.assertEqual(completed.returncode, 1)
        self.assertIn("boundary must be safe", completed.stderr)
        self.assertNotIn("Traceback", completed.stderr)


if __name__ == "__main__":
    unittest.main()
