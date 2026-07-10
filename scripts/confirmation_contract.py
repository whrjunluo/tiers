#!/usr/bin/env python3
"""Validate the provenance and shape of autonomous confirmation artifacts."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any


RUNNER_ID = "tiers.autonomous-confirmation/v1"
PROVENANCE = {
    "external-cross-review",
    "same-model-fresh-context",
    "built-in-checklist",
}
APPROVAL_PATTERN = re.compile(
    r"(?:用户(?:已经|已)?确认|user\s+(?:has\s+)?approved)", re.IGNORECASE
)


def _non_empty_string(value: Any) -> bool:
    return isinstance(value, str) and bool(value.strip())


def _string_list(value: Any) -> bool:
    return isinstance(value, list) and bool(value) and all(
        _non_empty_string(item) for item in value
    )


def _all_strings(value: Any):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for nested in value.values():
            yield from _all_strings(nested)
    elif isinstance(value, list):
        for nested in value:
            yield from _all_strings(nested)


def validate_artifact(data: Any, expected_scope: str) -> list[str]:
    if not isinstance(data, dict):
        return ["artifact must be a JSON object"]
    errors: list[str] = []
    if data.get("runner") != RUNNER_ID:
        errors.append(f"runner must be {RUNNER_ID}")
    if data.get("mode") != "autonomous":
        errors.append("mode must be autonomous")
    if data.get("status") != "PASS":
        errors.append("status must be PASS")
    scope = data.get("scope_sha256")
    if not isinstance(scope, str) or re.fullmatch(r"[0-9a-f]{64}", scope) is None:
        errors.append("scope_sha256 must be a lowercase SHA-256")
    elif scope != expected_scope:
        errors.append("scope_sha256 does not match current understanding scope")
    rounds = data.get("rounds")
    if isinstance(rounds, bool) or rounds not in (1, 2):
        errors.append("rounds must be 1 or 2")
    if data.get("requires_user") is not False:
        errors.append("requires_user must be false")
    if data.get("boundary") != "safe":
        errors.append("boundary must be safe")

    proposal = data.get("proposal")
    option_ids: list[str] = []
    if not isinstance(proposal, dict):
        errors.append("proposal must be an object")
    else:
        options = proposal.get("options")
        if isinstance(options, list):
            for option in options:
                if isinstance(option, dict) and _non_empty_string(option.get("id")) and _non_empty_string(option.get("summary")):
                    option_ids.append(option["id"])
        if (
            not isinstance(options, list)
            or len(options) not in (2, 3)
            or len(option_ids) != len(options)
            or len(set(option_ids)) != len(option_ids)
        ):
            errors.append("proposal.options must contain 2 or 3 unique options")
        if proposal.get("recommendation") not in option_ids:
            errors.append("proposal.recommendation must reference a proposal option")
        if not _string_list(proposal.get("assumptions")):
            errors.append("proposal.assumptions must be a non-empty string list")

    critic = data.get("critic")
    if not isinstance(critic, dict):
        errors.append("critic must be an object")
    else:
        if critic.get("provenance") not in PROVENANCE:
            errors.append("critic.provenance is not allowed")
        if critic.get("verdict") != "PASS":
            errors.append("critic.verdict must be PASS")
        if not _string_list(critic.get("findings")):
            errors.append("critic.findings must be a non-empty string list")

    decision = data.get("decision")
    if not isinstance(decision, dict):
        errors.append("decision must be an object")
    else:
        if decision.get("choice") not in option_ids:
            errors.append("decision.choice must reference a proposal option")
        if not _non_empty_string(decision.get("basis")):
            errors.append("decision.basis must be a non-empty string")
        if not _string_list(decision.get("assumptions")):
            errors.append("decision.assumptions must be a non-empty string list")
        if not _non_empty_string(decision.get("residual_risk")):
            errors.append("decision.residual_risk must be a non-empty string")

    if any(APPROVAL_PATTERN.search(text) for text in _all_strings(data)):
        errors.append("artifact must not claim user approval")
    return errors


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--validate", required=True, type=Path)
    parser.add_argument("--scope", required=True)
    args = parser.parse_args(argv)
    try:
        with args.validate.open(encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        print(f"invalid confirmation artifact: {exc}", file=sys.stderr)
        return 1
    errors = validate_artifact(data, args.scope)
    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
