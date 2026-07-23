#!/usr/bin/env python3
"""Validate parallel execution manifests before tasks are dispatched."""

from __future__ import annotations

import argparse
import json
import posixpath
import re
import sys
from pathlib import Path
from typing import Any


RUNNER_ID = "tiers.execution-manifest/v1"
HASH_PATTERN = re.compile(r"[0-9a-fA-F]{64}")


def _is_hash(value: Any) -> bool:
    return isinstance(value, str) and HASH_PATTERN.fullmatch(value) is not None


def _normalize_write_path(value: Any) -> str | None:
    if not isinstance(value, str) or not value.strip():
        return None
    normalized = posixpath.normpath(value)
    if normalized in (".", "..") or normalized.startswith("../") or normalized.startswith("/"):
        return None
    return normalized


def _paths_overlap(first: str, second: str) -> bool:
    return first == second or first.startswith(f"{second}/") or second.startswith(f"{first}/")


def validate_manifest(
    data: Any,
    repo: str,
    expected_base: str,
    expected_plan: str,
    mode: str = "multi-agent",
) -> list[str]:
    """Return every contract violation in an execution manifest."""
    if not isinstance(data, dict):
        return ["manifest must be a JSON object"]

    errors: list[str] = []
    if data.get("runner") != RUNNER_ID:
        errors.append(f"runner must be {RUNNER_ID}")
    if data.get("mode", mode) != mode:
        errors.append(f"mode must be {mode}")

    for field, expected, mismatch in (
        ("repository", repo, "repository does not match expected repository"),
        ("base", expected_base, "base does not match expected base"),
        ("plan_sha", expected_plan, "plan_sha does not match expected plan SHA"),
    ):
        value = data.get(field)
        if not _is_hash(value):
            errors.append(f"{field} must be a 64-hex hash")
        elif value != expected:
            errors.append(mismatch)

    max_workers = data.get("max_workers")
    if isinstance(max_workers, bool) or not isinstance(max_workers, int) or not 1 <= max_workers <= 3:
        errors.append("max_workers must be between 1 and 3")

    tasks = data.get("tasks")
    if not isinstance(tasks, list):
        return errors + ["tasks must be a list"]

    task_by_id: dict[str, dict[str, Any]] = {}
    for index, task in enumerate(tasks):
        if not isinstance(task, dict):
            errors.append(f"task {index} must be an object")
            continue
        task_id = task.get("id")
        if not isinstance(task_id, str) or not task_id.strip():
            errors.append(f"task {index} must have a non-empty id")
        elif task_id in task_by_id:
            errors.append(f"task id {task_id} is duplicated")
        else:
            task_by_id[task_id] = task

    ready_tasks: list[tuple[str, dict[str, Any]]] = []
    normalized_sets: list[tuple[str, str]] = []
    for task_id, task in task_by_id.items():
        dependencies = task.get("dependencies", [])
        if not isinstance(dependencies, list) or not all(isinstance(dep, str) and dep for dep in dependencies):
            errors.append(f"task {task_id} dependencies must be a string list")
            dependencies = []
        for dependency in dependencies:
            if dependency not in task_by_id:
                errors.append(f"task {task_id} has unknown dependency {dependency}")

        if task.get("status") == "ready":
            ready_tasks.append((task_id, task))
            for dependency in dependencies:
                dependency_task = task_by_id.get(dependency)
                if dependency_task is not None and dependency_task.get("status") != "completed":
                    errors.append(f"ready task {task_id} has unmet dependency {dependency}")

        if task.get("read_only") is True:
            continue

        write_set = task.get("write_set")
        if not isinstance(write_set, list):
            errors.append(f"task {task_id} must declare a write_set")
        else:
            for path in write_set:
                normalized = _normalize_write_path(path)
                if normalized is None:
                    errors.append(f"task {task_id} write_set contains an invalid path")
                elif task.get("status") == "ready":
                    normalized_sets.append((task_id, normalized))

        worktree = task.get("worktree")
        normalized_worktree = posixpath.normpath(worktree) if isinstance(worktree, str) else ""
        if not normalized_worktree.startswith(".worktrees/"):
            errors.append(f"task {task_id} worktree must be under .worktrees/")

    if len(ready_tasks) < 2:
        errors.append("at least two tasks must be ready")

    for index, (first_task, first_path) in enumerate(normalized_sets):
        for second_task, second_path in normalized_sets[index + 1 :]:
            if first_task != second_task and _paths_overlap(first_path, second_path):
                errors.append(
                    f"write sets overlap: {first_task} and {second_task} both include {first_path if first_path == second_path else min(first_path, second_path)}"
                )
    return errors


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--validate", required=True, type=Path)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--base", required=True)
    parser.add_argument("--plan-sha", required=True)
    parser.add_argument("--mode", default="multi-agent")
    args = parser.parse_args(argv)
    try:
        with args.validate.open(encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        print(json.dumps({"valid": False, "errors": [f"invalid manifest: {exc}"]}))
        return 1

    errors = validate_manifest(data, args.repo, args.base, args.plan_sha, args.mode)
    if errors:
        print(json.dumps({"valid": False, "errors": errors}))
        return 1
    print(json.dumps({"valid": True, "max_workers": data["max_workers"]}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
