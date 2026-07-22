#!/usr/bin/env python3
import copy
import hashlib
import importlib.util
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
CONTRACT_PATH = ROOT / "scripts" / "platform_review_contract.py"

spec = importlib.util.spec_from_file_location("platform_review_contract", CONTRACT_PATH)
contract = importlib.util.module_from_spec(spec)
spec.loader.exec_module(contract)


FINGERPRINT = "a" * 64
ARTIFACT = "b" * 64
PROMPT = "c" * 64
REFERENCE = "2026-07-22T01:00:00Z"
CREATED = "2026-07-22T00:59:00Z"
ROLES = ("correctness-regression", "security-degradation")


def sha256(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def reviewer(agent_id, model, role, verdict="PASS", findings=None, result=None):
    if findings is None:
        findings = []
    if result is None:
        result = "No blocking findings." if verdict == "PASS" else "Findings reported."
    return {
        "agent_id": agent_id,
        "model": model,
        "role": role,
        "status": "success",
        "verdict": verdict,
        "result": result,
        "findings": findings,
    }


class PlatformReviewContractTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.repo = pathlib.Path(self.temporary.name) / "repo"
        self.evidence = self.repo / "docs" / "superpowers" / ".workflow-evidence"
        self.evidence.mkdir(parents=True)
        self.external_path = self.evidence / "external-attempt.json"
        self.external = self.valid_external_attempt()
        self.write_external()
        self.report = self.valid_report()
        self.context = contract.ValidationContext.from_cli(
            expected_fingerprint=FINGERPRINT,
            reference_raw=REFERENCE,
            execution_profile="standard",
            repository_root=self.repo,
        )

    def tearDown(self):
        self.temporary.cleanup()

    def valid_external_attempt(self):
        return {
            "runner": "tiers.external-agent/v1",
            "success": False,
            "quorum": False,
            "outcome": "failed",
            "review_profile": "standard",
            "policy": {
                "minimum_successes": 2,
                "minimum_families": 2,
                "stop_after_policy": False,
            },
            "artifact_sha256": ARTIFACT,
            "repository_fingerprint": FINGERPRINT,
            "created_at": CREATED,
            "finished_at": CREATED,
            "duration_seconds": 30.0,
            "successful_families": [],
            "selection": {
                "mode": "explicit",
                "orchestrator_family": "openai",
                "selected_reviewers": ["cursor", "mimo"],
            },
            "error": "cross-review quorum not met",
            "reviewers": [
                {
                    "agent": "cursor",
                    "family": "cursor",
                    "success": False,
                    "status": "timeout",
                    "timeout_seconds": 90,
                    "duration_seconds": 90.0,
                    "error": "cursor timed out",
                },
                {
                    "agent": "mimo",
                    "family": "xiaomi",
                    "success": False,
                    "status": "failed",
                    "timeout_seconds": 90,
                    "duration_seconds": 20.0,
                    "error": "mimo returned empty output",
                },
            ],
        }

    def write_external(self, update_report_sha=True):
        self.external_path.write_text(json.dumps(self.external), encoding="utf-8")
        if update_report_sha and hasattr(self, "report"):
            self.report["external_attempt"]["sha256"] = sha256(self.external_path)

    def valid_report(self):
        return {
            "runner": "tiers.platform-review/v1",
            "success": True,
            "quorum": False,
            "platform_quorum": True,
            "outcome": "fallback-quorum",
            "review_profile": "standard",
            "repository_fingerprint": FINGERPRINT,
            "artifact_sha256": ARTIFACT,
            "prompt_sha256": PROMPT,
            "created_at": CREATED,
            "finished_at": REFERENCE,
            "duration_seconds": 60.0,
            "external_attempt": {
                "path": "docs/superpowers/.workflow-evidence/external-attempt.json",
                "sha256": sha256(self.external_path),
            },
            "policy": {
                "minimum_successes": 2,
                "minimum_models": 2,
                "minimum_roles": 2,
                "requires_external_failure": True,
            },
            "reviewers": [
                reviewer("agent-sol", "gpt-5.6-sol", ROLES[0]),
                reviewer("agent-terra", "gpt-5.6-terra", ROLES[1]),
            ],
            "adjudication": {"status": "PASS", "findings": []},
        }

    def errors(self):
        return contract.validate_artifact(self.report, self.context)

    def assert_error(self, text):
        errors = self.errors()
        self.assertTrue(any(text in error for error in errors), errors)

    def test_valid_artifact_has_no_errors_for_standard_and_small_fix(self):
        self.assertEqual(self.errors(), [])
        self.report["review_profile"] = "small-fix"
        self.external["review_profile"] = "small-fix"
        self.external["policy"] = {
            "minimum_successes": 1,
            "minimum_families": 1,
            "stop_after_policy": True,
        }
        self.write_external()
        self.context = contract.ValidationContext.from_cli(
            expected_fingerprint=FINGERPRINT,
            reference_raw=REFERENCE,
            execution_profile="small-fix",
            repository_root=self.repo,
        )
        self.assertEqual(self.errors(), [])

    def test_requires_two_unique_non_root_agents_models_and_roles(self):
        cases = [
            (lambda r: r["reviewers"].pop(), "exactly two reviewers"),
            (lambda r: r["reviewers"][1].update(agent_id="agent-sol"), "agent_id values must be unique"),
            (lambda r: r["reviewers"][0].update(agent_id="root"), "root orchestrator cannot be a reviewer"),
            (lambda r: r["reviewers"][0].update(agent_id="/root"), "root orchestrator cannot be a reviewer"),
            (lambda r: r["reviewers"][1].update(model="GPT-5.6-SOL"), "model IDs must be distinct"),
            (lambda r: r["reviewers"][1].update(role=ROLES[0]), "review roles must be distinct"),
            (lambda r: r["reviewers"][1].update(role="performance"), "review role is not allowed"),
        ]
        original = copy.deepcopy(self.report)
        for mutate, expected in cases:
            with self.subTest(expected=expected):
                self.report = copy.deepcopy(original)
                mutate(self.report)
                self.assert_error(expected)

    def test_rejects_failed_empty_or_inconsistent_reviewer(self):
        cases = [
            (lambda r: r["reviewers"][0].update(status="failed"), "reviewer status must be success"),
            (lambda r: r["reviewers"][0].update(result="  "), "reviewer result must be non-empty"),
            (lambda r: r["reviewers"][0].update(verdict="MAYBE"), "reviewer verdict must be PASS or FINDINGS"),
            (lambda r: r["reviewers"][0].update(findings=[self.finding("unexpected", False)]), "PASS reviewer must not include findings"),
            (lambda r: r["reviewers"][0].update(verdict="FINDINGS", findings=[]), "FINDINGS reviewer must include findings"),
        ]
        original = copy.deepcopy(self.report)
        for mutate, expected in cases:
            with self.subTest(expected=expected):
                self.report = copy.deepcopy(original)
                mutate(self.report)
                self.assert_error(expected)

    @staticmethod
    def finding(identifier, blocking):
        return {
            "id": identifier,
            "blocking": blocking,
            "summary": "Evidence-backed issue",
            "evidence": "scripts/workflow-state.sh:100",
        }

    def report_finding(self, identifier="finding-1", blocking=False):
        finding = self.finding(identifier, blocking)
        self.report["reviewers"][0].update(verdict="FINDINGS", findings=[finding])
        self.report["adjudication"]["findings"] = [
            {"id": identifier, "disposition": "accepted-risk" if not blocking else "fixed", "basis": "Reviewed locally"}
        ]

    def test_valid_non_blocking_accepted_risk_and_fixed_blocker(self):
        self.report_finding(blocking=False)
        self.assertEqual(self.errors(), [])
        self.report = self.valid_report()
        self.report_finding(blocking=True)
        self.assertEqual(self.errors(), [])

    def test_rejects_invalid_finding_and_adjudication_sets(self):
        self.report_finding(blocking=True)
        original = copy.deepcopy(self.report)
        cases = [
            (lambda r: r["reviewers"][1].update(verdict="FINDINGS", findings=[self.finding("finding-1", False)]), "finding IDs must be unique"),
            (lambda r: r["adjudication"].update(findings=[]), "every reviewer finding must be adjudicated exactly once"),
            (lambda r: r["adjudication"]["findings"].append({"id": "unknown", "disposition": "fixed", "basis": "none"}), "adjudication references unknown finding"),
            (lambda r: r["adjudication"]["findings"].append(copy.deepcopy(r["adjudication"]["findings"][0])), "adjudication IDs must be unique"),
            (lambda r: r["adjudication"]["findings"][0].update(disposition="ignored"), "adjudication disposition is not allowed"),
            (lambda r: r["adjudication"]["findings"][0].update(disposition="accepted-risk"), "blocking findings cannot be accepted-risk"),
            (lambda r: r["adjudication"].update(status="FAIL"), "adjudication status must be PASS"),
        ]
        for mutate, expected in cases:
            with self.subTest(expected=expected):
                self.report = copy.deepcopy(original)
                mutate(self.report)
                self.assert_error(expected)

    def test_rejects_invalid_external_attempt_outcomes_and_binding(self):
        original = copy.deepcopy(self.external)
        cases = [
            (lambda d: d.update(runner="other"), "external attempt runner is invalid"),
            (lambda d: d.update(success=True), "external attempt must have success=false"),
            (lambda d: d.update(quorum=True), "external attempt must have quorum=false"),
            (lambda d: d.update(outcome="terminated"), "user-terminated external attempt cannot trigger fallback"),
            (lambda d: d.update(outcome="quorum"), "external attempt outcome must be failed"),
            (lambda d: d.update(outcome="degraded", success=True), "external attempt must have success=false"),
            (lambda d: d.update(repository_fingerprint="d" * 64), "external attempt repository fingerprint does not match"),
            (lambda d: d.update(artifact_sha256="d" * 64), "external attempt artifact hash does not match"),
            (lambda d: d.update(created_at="2000-01-01T00:00:00Z"), "external attempt is stale or from the future"),
            (lambda d: d.update(review_profile="small-fix"), "external attempt review_profile does not match"),
            (lambda d: d.update(policy={}), "external attempt policy is invalid"),
            (lambda d: d.update(termination_reason="user_interrupt"), "external attempt termination marker is invalid"),
            (lambda d: d.update(finished_at="not-a-time"), "external attempt timestamps are invalid"),
            (lambda d: d.update(finished_at=REFERENCE), "external attempt must finish before platform review starts"),
            (lambda d: d.update(duration_seconds=-1), "external attempt duration_seconds must be non-negative"),
        ]
        for mutate, expected in cases:
            with self.subTest(expected=expected):
                self.external = copy.deepcopy(original)
                mutate(self.external)
                self.write_external()
                self.assert_error(expected)

    def test_valid_auto_selection_failure_and_rejects_lifecycle_contradictions(self):
        self.external["reviewers"] = []
        self.external["selection"] = {
            "mode": "auto",
            "orchestrator_family": "openai",
            "selected_reviewers": [],
        }
        self.external["error"] = "auto cross-review needs two eligible families"
        self.write_external()
        self.assertEqual(self.errors(), [])

        self.external = self.valid_external_attempt()
        self.external["reviewers"] = []
        self.write_external()
        self.assert_error("external attempt did not execute selected reviewers")

        self.external = self.valid_external_attempt()
        self.external["reviewers"] = self.external["reviewers"][:1]
        self.external["selection"]["selected_reviewers"] = ["cursor"]
        self.write_external()
        self.assert_error("external attempt requires at least two selected reviewers")

        self.external = self.valid_external_attempt()
        for item in self.external["reviewers"]:
            item.update(success=True, status="success", agent_messages="review passed")
            item.pop("error", None)
        self.external["successful_families"] = ["cursor", "xiaomi"]
        self.write_external()
        self.assert_error("external attempt successful reviewers contradict failed outcome")

        self.external = self.valid_external_attempt()
        self.external["successful_families"] = ["cursor"]
        self.write_external()
        self.assert_error("external attempt successful_families do not match reviewers")

        self.external = self.valid_external_attempt()
        self.external["reviewers"][0]["family"] = "xai"
        self.write_external()
        self.assert_error("external attempt reviewer family is invalid")

    def test_rejects_attempt_path_sha_and_file_safety_failures(self):
        self.report["external_attempt"]["sha256"] = "d" * 64
        self.assert_error("external attempt SHA-256 does not match")

        self.report = self.valid_report()
        self.report["external_attempt"]["path"] = "../external.json"
        self.assert_error("external attempt path must stay in workflow evidence")

        self.report = self.valid_report()
        self.external_path.unlink()
        self.assert_error("external attempt file does not exist")

        outside = pathlib.Path(self.temporary.name) / "outside.json"
        outside.write_text(json.dumps(self.external), encoding="utf-8")
        self.external_path.symlink_to(outside)
        self.report["external_attempt"]["sha256"] = sha256(outside)
        self.assert_error("external attempt real path leaves workflow evidence")

    def test_rejects_report_integrity_time_profile_and_policy_errors(self):
        cases = [
            (lambda r: r.update(runner="other"), "runner must be tiers.platform-review/v1"),
            (lambda r: r.update(success=False), "success must be true"),
            (lambda r: r.update(quorum=True), "external quorum must remain false"),
            (lambda r: r.update(platform_quorum=False), "platform_quorum must be true"),
            (lambda r: r.update(outcome="quorum"), "outcome must be fallback-quorum"),
            (lambda r: r.update(repository_fingerprint="d" * 64), "repository fingerprint does not match"),
            (lambda r: r.update(artifact_sha256="bad"), "artifact_sha256 must be a lowercase SHA-256"),
            (lambda r: r.update(prompt_sha256="bad"), "prompt_sha256 must be a lowercase SHA-256"),
            (lambda r: r.update(created_at="2000-01-01T00:00:00Z"), "platform report is stale or from the future"),
            (lambda r: r.update(duration_seconds=-1), "duration_seconds must be non-negative"),
            (lambda r: r.update(review_profile="small-fix"), "review_profile does not match execution profile"),
            (lambda r: r.update(policy={}), "platform fallback policy is invalid"),
        ]
        original = copy.deepcopy(self.report)
        for mutate, expected in cases:
            with self.subTest(expected=expected):
                self.report = copy.deepcopy(original)
                mutate(self.report)
                self.assert_error(expected)

    def test_cli_returns_clean_nonzero_for_invalid_artifact(self):
        self.report["reviewers"][1]["model"] = "GPT-5.6-SOL"
        report_path = self.evidence / "platform-review.json"
        report_path.write_text(json.dumps(self.report), encoding="utf-8")
        completed = subprocess.run(
            [
                sys.executable,
                str(CONTRACT_PATH),
                "--validate",
                str(report_path),
                "--fingerprint",
                FINGERPRINT,
                "--reference",
                REFERENCE,
                "--profile",
                "standard",
                "--repo",
                str(self.repo),
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(completed.returncode, 1)
        self.assertIn("model IDs must be distinct", completed.stderr)
        self.assertNotIn("Traceback", completed.stderr)

        self.external_path.write_bytes(b"\xff")
        self.report = self.valid_report()
        self.report["external_attempt"]["sha256"] = sha256(self.external_path)
        report_path.write_text(json.dumps(self.report), encoding="utf-8")
        completed = subprocess.run(
            [
                sys.executable,
                str(CONTRACT_PATH),
                "--validate",
                str(report_path),
                "--fingerprint",
                FINGERPRINT,
                "--reference",
                REFERENCE,
                "--profile",
                "standard",
                "--repo",
                str(self.repo),
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(completed.returncode, 1)
        self.assertIn("external attempt is not valid JSON", completed.stderr)
        self.assertNotIn("Traceback", completed.stderr)

        self.write_external()
        self.report = self.valid_report()
        self.report["reviewers"][0] = "not-an-object"
        report_path.write_text(json.dumps(self.report), encoding="utf-8")
        completed = subprocess.run(
            [
                sys.executable,
                str(CONTRACT_PATH),
                "--validate",
                str(report_path),
                "--fingerprint",
                FINGERPRINT,
                "--reference",
                REFERENCE,
                "--profile",
                "standard",
                "--repo",
                str(self.repo),
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(completed.returncode, 1)
        self.assertIn("platform reviewer must be an object", completed.stderr)
        self.assertNotIn("Traceback", completed.stderr)

        self.report = self.valid_report()
        self.report["reviewers"][0]["role"] = []
        report_path.write_text(json.dumps(self.report), encoding="utf-8")
        completed = subprocess.run(
            [
                sys.executable,
                str(CONTRACT_PATH),
                "--validate",
                str(report_path),
                "--fingerprint",
                FINGERPRINT,
                "--reference",
                REFERENCE,
                "--profile",
                "standard",
                "--repo",
                str(self.repo),
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(completed.returncode, 1)
        self.assertIn("review role is not allowed", completed.stderr)
        self.assertNotIn("Traceback", completed.stderr)


if __name__ == "__main__":
    unittest.main()
