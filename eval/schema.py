"""Fixture schema validation without third-party dependencies."""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any


TIERS = {"L0", "L1", "L2", "L3", "L4"}
CATEGORIES = {
    "tier-boundary",
    "clarification",
    "impact",
    "root-cause",
    "evidence-conflict",
    "missing-dependency",
    "goal-continuation",
    "autonomous-boundary",
}
TOP_LEVEL_FIELDS = {
    "id",
    "category",
    "smoke",
    "execution_mode",
    "prompt",
    "repo_fixture",
    "expected",
    "limits",
}
EXPECTED_FIELDS = {
    "allowed_tiers",
    "required_gates",
    "forbidden_claims",
    "must_pause_before",
}
LIMIT_FIELDS = {"max_continuations", "token_budget"}


class FixtureError(ValueError):
    """Raised when an evaluation fixture cannot be loaded safely."""


def _non_empty_string(value: Any) -> bool:
    return isinstance(value, str) and bool(value.strip())


def _string_list(value: Any, *, allow_empty: bool = True) -> bool:
    return (
        isinstance(value, list)
        and (allow_empty or bool(value))
        and all(_non_empty_string(item) for item in value)
    )


def _positive_integer(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value > 0


def validate_fixture(data: Any) -> list[str]:
    errors: list[str] = []
    if not isinstance(data, dict):
        return ["fixture must be a JSON object"]

    for field in sorted(set(data) - TOP_LEVEL_FIELDS):
        errors.append(f"unknown top-level field: {field}")
    for field in sorted(TOP_LEVEL_FIELDS - set(data)):
        errors.append(f"missing top-level field: {field}")

    fixture_id = data.get("id")
    if not _non_empty_string(fixture_id) or not re.fullmatch(
        r"[a-z0-9]+(?:-[a-z0-9]+)*", fixture_id or ""
    ):
        errors.append("id must use lowercase kebab-case")
    if data.get("category") not in CATEGORIES:
        errors.append("category is not recognized")
    if not isinstance(data.get("smoke"), bool):
        errors.append("smoke must be a boolean")
    if data.get("execution_mode") not in {"single", "goal"}:
        errors.append("execution_mode must be single or goal")
    if not _non_empty_string(data.get("prompt")):
        errors.append("prompt must be a non-empty string")
    if not _non_empty_string(data.get("repo_fixture")):
        errors.append("repo_fixture must be a non-empty string")

    expected = data.get("expected")
    if not isinstance(expected, dict):
        errors.append("expected must be an object")
    else:
        for field in sorted(set(expected) - EXPECTED_FIELDS):
            errors.append(f"unknown expected field: {field}")
        for field in sorted(EXPECTED_FIELDS - set(expected)):
            errors.append(f"missing expected field: {field}")
        allowed_tiers = expected.get("allowed_tiers")
        if not _string_list(allowed_tiers, allow_empty=False):
            errors.append("allowed_tiers must be a non-empty string list")
        else:
            for tier in allowed_tiers:
                if tier not in TIERS:
                    errors.append(f"allowed_tiers contains invalid tier {tier}")
        for field in ("required_gates", "forbidden_claims", "must_pause_before"):
            if not _string_list(expected.get(field)):
                errors.append(f"{field} must be a string list")

    limits = data.get("limits")
    if not isinstance(limits, dict):
        errors.append("limits must be an object")
    else:
        for field in sorted(set(limits) - LIMIT_FIELDS):
            errors.append(f"unknown limits field: {field}")
        for field in sorted(LIMIT_FIELDS - set(limits)):
            errors.append(f"missing limits field: {field}")
        for field in sorted(LIMIT_FIELDS):
            if not _positive_integer(limits.get(field)):
                errors.append(f"{field} must be a positive integer")

    return errors


def load_fixture(path: Path) -> dict:
    try:
        with Path(path).open(encoding="utf-8") as handle:
            data = json.load(handle)
    except json.JSONDecodeError as exc:
        raise FixtureError(f"{path}: invalid JSON: {exc.msg}") from exc
    except OSError as exc:
        raise FixtureError(f"{path}: cannot read fixture: {exc}") from exc

    errors = validate_fixture(data)
    if errors:
        raise FixtureError(f"{path}: " + "; ".join(errors))
    return data
