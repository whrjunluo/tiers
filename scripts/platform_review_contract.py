#!/usr/bin/env python3
"""Validate platform multi-model review fallback evidence."""

import argparse
import hashlib
import json
import re
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any, Optional


RUNNER_ID = "tiers.platform-review/v1"
EXTERNAL_RUNNER_ID = "tiers.external-agent/v1"
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}")
ALLOWED_PROFILES = {"standard", "small-fix"}
ALLOWED_ROLES = {"correctness-regression", "security-degradation"}
ALLOWED_DISPOSITIONS = {"fixed", "false-positive", "accepted-risk"}
ROOT_AGENT_IDS = {"root", "/root", "orchestrator", "main", "primary"}
POLICY = {
    "minimum_successes": 2,
    "minimum_models": 2,
    "minimum_roles": 2,
    "requires_external_failure": True,
}
EXTERNAL_AGENT_FAMILIES = {
    "codex": "openai",
    "gemini": "google",
    "mimo": "xiaomi",
    "cursor": "cursor",
    "grok": "xai",
    "opencode": "configurable",
    "antigravity": "google",
}


@dataclass(frozen=True)
class ValidationContext:
    expected_fingerprint: str
    reference_time: datetime
    execution_profile: str
    repository_root: Path

    @classmethod
    def from_cli(
        cls,
        expected_fingerprint: str,
        reference_raw: str,
        execution_profile: str,
        repository_root: Path,
    ) -> "ValidationContext":
        return cls(
            expected_fingerprint=expected_fingerprint,
            reference_time=_parse_time(reference_raw),
            execution_profile=execution_profile,
            repository_root=Path(repository_root).resolve(),
        )


def _parse_time(value: Any) -> datetime:
    if not isinstance(value, str):
        raise ValueError("timestamp must be a string")
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def _non_empty(value: Any) -> bool:
    return isinstance(value, str) and bool(value.strip())


def _valid_sha(value: Any) -> bool:
    return isinstance(value, str) and SHA256_PATTERN.fullmatch(value) is not None


def _file_sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _fresh(timestamp: Any, reference: datetime) -> bool:
    try:
        created = _parse_time(timestamp)
        age = (reference - created).total_seconds()
    except (TypeError, ValueError):
        return False
    return -300 <= age <= 86400


def _resolve_external_attempt(
    declaration: Any, context: ValidationContext, errors: list
) -> Optional[Path]:
    if not isinstance(declaration, dict):
        errors.append("external_attempt must be an object")
        return None
    relative = declaration.get("path")
    if not _non_empty(relative):
        errors.append("external attempt path must be non-empty")
        return None
    candidate_relative = Path(relative)
    if (
        candidate_relative.is_absolute()
        or ".." in candidate_relative.parts
        or candidate_relative.parts[:3]
        != ("docs", "superpowers", ".workflow-evidence")
    ):
        errors.append("external attempt path must stay in workflow evidence")
        return None
    evidence_root = (
        context.repository_root / "docs" / "superpowers" / ".workflow-evidence"
    ).resolve()
    candidate = context.repository_root / candidate_relative
    if not candidate.exists():
        errors.append("external attempt file does not exist")
        return None
    try:
        resolved = candidate.resolve(strict=True)
    except OSError:
        errors.append("external attempt file cannot be resolved")
        return None
    try:
        resolved.relative_to(evidence_root)
    except ValueError:
        errors.append("external attempt real path leaves workflow evidence")
        return None
    if not resolved.is_file() or resolved.stat().st_size == 0:
        errors.append("external attempt file must be a non-empty regular file")
        return None
    declared_sha = declaration.get("sha256")
    if not _valid_sha(declared_sha):
        errors.append("external attempt sha256 must be a lowercase SHA-256")
    elif _file_sha256(resolved) != declared_sha:
        errors.append("external attempt SHA-256 does not match")
    return resolved


def _validate_external_attempt(
    path: Optional[Path], data: dict, context: ValidationContext, errors: list
) -> None:
    if path is None:
        return
    try:
        attempt = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        errors.append("external attempt is not valid JSON")
        return
    if not isinstance(attempt, dict):
        errors.append("external attempt must be a JSON object")
        return
    if attempt.get("runner") != EXTERNAL_RUNNER_ID:
        errors.append("external attempt runner is invalid")
    if attempt.get("success") is not False:
        errors.append("external attempt must have success=false")
    if attempt.get("quorum") is not False:
        errors.append("external attempt must have quorum=false")
    outcome = attempt.get("outcome")
    if outcome == "terminated":
        errors.append("user-terminated external attempt cannot trigger fallback")
    elif outcome != "failed":
        errors.append("external attempt outcome must be failed")
    profile = attempt.get("review_profile")
    if profile != data.get("review_profile"):
        errors.append("external attempt review_profile does not match")
    expected_policy = {
        "minimum_successes": 1 if profile == "small-fix" else 2,
        "minimum_families": 1 if profile == "small-fix" else 2,
        "stop_after_policy": profile == "small-fix",
    }
    if profile not in ALLOWED_PROFILES or attempt.get("policy") != expected_policy:
        errors.append("external attempt policy is invalid")
    if "termination_reason" in attempt:
        errors.append("external attempt termination marker is invalid")
    if attempt.get("repository_fingerprint") != data.get("repository_fingerprint"):
        errors.append("external attempt repository fingerprint does not match")
    if attempt.get("artifact_sha256") != data.get("artifact_sha256"):
        errors.append("external attempt artifact hash does not match")
    if not _fresh(attempt.get("created_at"), context.reference_time):
        errors.append("external attempt is stale or from the future")
    try:
        attempt_created = _parse_time(attempt.get("created_at"))
        attempt_finished = _parse_time(attempt.get("finished_at"))
        platform_created = _parse_time(data.get("created_at"))
        if attempt_finished < attempt_created:
            errors.append("external attempt timestamps are invalid")
        if attempt_finished > platform_created:
            errors.append("external attempt must finish before platform review starts")
    except (TypeError, ValueError):
        errors.append("external attempt timestamps are invalid")
    duration = attempt.get("duration_seconds")
    if isinstance(duration, bool) or not isinstance(duration, (int, float)) or duration < 0:
        errors.append("external attempt duration_seconds must be non-negative")
    _validate_external_lifecycle(attempt, errors)


def _validate_external_lifecycle(attempt: dict, errors: list) -> None:
    reviewers = attempt.get("reviewers")
    selection = attempt.get("selection")
    if not isinstance(reviewers, list):
        errors.append("external attempt reviewers must be a list")
        return
    if not isinstance(selection, dict):
        errors.append("external attempt selection must be an object")
        return
    mode = selection.get("mode")
    selected = selection.get("selected_reviewers")
    if not isinstance(mode, str) or mode not in {"auto", "explicit"} or not isinstance(selected, list):
        errors.append("external attempt selection is invalid")
        return
    if any(not _non_empty(agent) for agent in selected) or len(selected) != len(set(selected)):
        errors.append("external attempt selected reviewers are invalid")
    if not reviewers:
        if mode != "auto" or selected or not _non_empty(attempt.get("error")):
            errors.append("external attempt did not execute selected reviewers")
        if attempt.get("successful_families") != []:
            errors.append("external attempt successful_families do not match reviewers")
        return
    if len(selected) < 2:
        errors.append("external attempt requires at least two selected reviewers")
    selected_families = {
        EXTERNAL_AGENT_FAMILIES.get(agent)
        for agent in selected
        if isinstance(agent, str) and agent in EXTERNAL_AGENT_FAMILIES
    }
    if len(selected_families) < 2 or any(
        not isinstance(agent, str) or agent not in EXTERNAL_AGENT_FAMILIES
        for agent in selected
    ):
        errors.append("external attempt selected reviewer families are invalid")
    reviewer_agents = []
    successful_families = set()
    successful_count = 0
    for reviewer in reviewers:
        if not isinstance(reviewer, dict):
            errors.append("external attempt reviewer must be an object")
            continue
        agent = reviewer.get("agent")
        family = reviewer.get("family")
        reviewer_agents.append(agent)
        if not _non_empty(agent) or EXTERNAL_AGENT_FAMILIES.get(agent) != family:
            errors.append("external attempt reviewer family is invalid")
        status = reviewer.get("status")
        success = reviewer.get("success")
        if status not in {"success", "failed", "timeout", "cancelled"}:
            errors.append("external attempt reviewer status is invalid")
        if not isinstance(success, bool) or ((status == "success") != success):
            errors.append("external attempt reviewer success is inconsistent")
        timeout = reviewer.get("timeout_seconds")
        if isinstance(timeout, bool) or not isinstance(timeout, int) or timeout <= 0:
            errors.append("external attempt reviewer timeout is invalid")
        duration = reviewer.get("duration_seconds")
        if isinstance(duration, bool) or not isinstance(duration, (int, float)) or duration < 0:
            errors.append("external attempt reviewer duration is invalid")
        if success:
            successful_count += 1
            successful_families.add(family)
            if not _non_empty(reviewer.get("agent_messages")):
                errors.append("external attempt successful reviewer result is empty")
        elif not _non_empty(reviewer.get("error")):
            errors.append("external attempt failed reviewer error is empty")
    if reviewer_agents != selected:
        errors.append("external attempt did not execute selected reviewers")
    declared_families = attempt.get("successful_families")
    if not isinstance(declared_families, list) or set(declared_families) != successful_families:
        errors.append("external attempt successful_families do not match reviewers")
    profile = attempt.get("review_profile")
    if (profile == "standard" and successful_count >= 2 and len(successful_families) >= 2) or (
        profile == "small-fix" and successful_count >= 1
    ):
        errors.append("external attempt successful reviewers contradict failed outcome")


def _validate_findings(reviewers: list, adjudication: Any, errors: list) -> None:
    findings_by_id = {}
    duplicate_finding = False
    for reviewer in reviewers:
        if not isinstance(reviewer, dict):
            continue
        findings = reviewer.get("findings")
        if not isinstance(findings, list):
            continue
        for finding in findings:
            if not isinstance(finding, dict):
                errors.append("reviewer finding must be an object")
                continue
            identifier = finding.get("id")
            if not _non_empty(identifier):
                errors.append("reviewer finding id must be non-empty")
                continue
            if identifier in findings_by_id:
                duplicate_finding = True
            findings_by_id[identifier] = finding
            if not isinstance(finding.get("blocking"), bool):
                errors.append("reviewer finding blocking must be boolean")
            if not _non_empty(finding.get("summary")):
                errors.append("reviewer finding summary must be non-empty")
            if not _non_empty(finding.get("evidence")):
                errors.append("reviewer finding evidence must be non-empty")
    if duplicate_finding:
        errors.append("finding IDs must be unique")

    if not isinstance(adjudication, dict):
        errors.append("adjudication must be an object")
        return
    if adjudication.get("status") != "PASS":
        errors.append("adjudication status must be PASS")
    decisions = adjudication.get("findings")
    if not isinstance(decisions, list):
        errors.append("adjudication findings must be a list")
        return
    decision_ids = []
    for decision in decisions:
        if not isinstance(decision, dict):
            errors.append("adjudication finding must be an object")
            continue
        identifier = decision.get("id")
        if not _non_empty(identifier):
            errors.append("adjudication id must be non-empty")
            continue
        decision_ids.append(identifier)
        if identifier not in findings_by_id:
            errors.append("adjudication references unknown finding")
        disposition = decision.get("disposition")
        if not isinstance(disposition, str) or disposition not in ALLOWED_DISPOSITIONS:
            errors.append("adjudication disposition is not allowed")
        if not _non_empty(decision.get("basis")):
            errors.append("adjudication basis must be non-empty")
        finding = findings_by_id.get(identifier)
        if (
            finding is not None
            and finding.get("blocking") is True
            and disposition == "accepted-risk"
        ):
            errors.append("blocking findings cannot be accepted-risk")
    if len(decision_ids) != len(set(decision_ids)):
        errors.append("adjudication IDs must be unique")
    if set(decision_ids) != set(findings_by_id):
        errors.append("every reviewer finding must be adjudicated exactly once")


def validate_artifact(data: Any, context: ValidationContext) -> list:
    if not isinstance(data, dict):
        return ["platform review artifact must be a JSON object"]
    errors = []
    if data.get("runner") != RUNNER_ID:
        errors.append(f"runner must be {RUNNER_ID}")
    if data.get("success") is not True:
        errors.append("success must be true")
    if data.get("quorum") is not False:
        errors.append("external quorum must remain false")
    if data.get("platform_quorum") is not True:
        errors.append("platform_quorum must be true")
    if data.get("outcome") != "fallback-quorum":
        errors.append("outcome must be fallback-quorum")

    repository = data.get("repository_fingerprint")
    if not _valid_sha(repository):
        errors.append("repository_fingerprint must be a lowercase SHA-256")
    elif repository != context.expected_fingerprint:
        errors.append("repository fingerprint does not match")
    if not _valid_sha(data.get("artifact_sha256")):
        errors.append("artifact_sha256 must be a lowercase SHA-256")
    if not _valid_sha(data.get("prompt_sha256")):
        errors.append("prompt_sha256 must be a lowercase SHA-256")

    profile = data.get("review_profile")
    if not isinstance(profile, str) or profile not in ALLOWED_PROFILES:
        errors.append("review_profile must be standard or small-fix")
    if profile != context.execution_profile:
        errors.append("review_profile does not match execution profile")
    if data.get("policy") != POLICY:
        errors.append("platform fallback policy is invalid")
    if not _fresh(data.get("created_at"), context.reference_time):
        errors.append("platform report is stale or from the future")
    try:
        created = _parse_time(data.get("created_at"))
        finished = _parse_time(data.get("finished_at"))
        if finished < created or (finished - context.reference_time).total_seconds() > 300:
            errors.append("platform report finished_at is invalid")
    except (TypeError, ValueError):
        errors.append("platform report timestamps are invalid")
    duration = data.get("duration_seconds")
    if isinstance(duration, bool) or not isinstance(duration, (int, float)) or duration < 0:
        errors.append("duration_seconds must be non-negative")

    reviewers = data.get("reviewers")
    if not isinstance(reviewers, list) or len(reviewers) != 2:
        errors.append("platform fallback requires exactly two reviewers")
        reviewers = reviewers if isinstance(reviewers, list) else []
    agent_ids = []
    models = []
    roles = []
    for reviewer in reviewers:
        if not isinstance(reviewer, dict):
            errors.append("platform reviewer must be an object")
            continue
        agent_id = reviewer.get("agent_id")
        model = reviewer.get("model")
        role = reviewer.get("role")
        if not _non_empty(agent_id):
            errors.append("reviewer agent_id must be non-empty")
        else:
            agent_ids.append(agent_id.strip().lower())
            if agent_id.strip().lower() in ROOT_AGENT_IDS:
                errors.append("root orchestrator cannot be a reviewer")
        if not _non_empty(model):
            errors.append("reviewer model must be non-empty")
        else:
            models.append(model.strip().lower())
        if not isinstance(role, str) or role not in ALLOWED_ROLES:
            errors.append("review role is not allowed")
        else:
            roles.append(role)
        if reviewer.get("status") != "success":
            errors.append("reviewer status must be success")
        if not _non_empty(reviewer.get("result")):
            errors.append("reviewer result must be non-empty")
        verdict = reviewer.get("verdict")
        findings = reviewer.get("findings")
        if not isinstance(verdict, str) or verdict not in {"PASS", "FINDINGS"}:
            errors.append("reviewer verdict must be PASS or FINDINGS")
        if verdict == "PASS" and findings != []:
            errors.append("PASS reviewer must not include findings")
        if verdict == "FINDINGS" and (not isinstance(findings, list) or not findings):
            errors.append("FINDINGS reviewer must include findings")
    if len(agent_ids) != len(set(agent_ids)):
        errors.append("agent_id values must be unique")
    if len(models) != len(set(models)):
        errors.append("model IDs must be distinct")
    if len(roles) != len(set(roles)):
        errors.append("review roles must be distinct")

    _validate_findings(reviewers, data.get("adjudication"), errors)
    attempt_path = _resolve_external_attempt(data.get("external_attempt"), context, errors)
    _validate_external_attempt(attempt_path, data, context, errors)
    return errors


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--validate", required=True, type=Path)
    parser.add_argument("--fingerprint", required=True)
    parser.add_argument("--reference", required=True)
    parser.add_argument("--profile", required=True)
    parser.add_argument("--repo", required=True, type=Path)
    args = parser.parse_args(argv)
    try:
        context = ValidationContext.from_cli(
            args.fingerprint, args.reference, args.profile, args.repo
        )
        data = json.loads(args.validate.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError, TypeError, ValueError) as exc:
        print(f"invalid platform review artifact: {exc}", file=sys.stderr)
        return 1
    try:
        errors = validate_artifact(data, context)
    except (TypeError, ValueError) as exc:
        print(f"invalid platform review artifact: {exc}", file=sys.stderr)
        return 1
    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
