#!/usr/bin/env python3
"""Codex provider adapter for git-ref-isolated tiers evaluations."""

from __future__ import annotations

import argparse
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
from pathlib import Path
from typing import Any

from .schema import load_fixture


ROOT = Path(__file__).resolve().parents[1]
TEST_COMMAND_PATTERN = re.compile(
    r"(?:tests?/|pytest|unittest|npm\s+test|pnpm\s+test|yarn\s+test|go\s+test|cargo\s+test)",
    re.IGNORECASE,
)


def materialize_plugin(repo_root: Path, git_ref: str, destination: Path) -> None:
    destination = Path(destination)
    if destination.exists():
        shutil.rmtree(destination)
    destination.mkdir(parents=True)
    archive = subprocess.run(
        ["git", "-C", str(repo_root), "archive", "--format=tar", git_ref],
        capture_output=True,
        check=True,
    ).stdout
    root = destination.resolve()
    with tarfile.open(fileobj=io.BytesIO(archive), mode="r:") as bundle:
        for member in bundle.getmembers():
            target = (destination / member.name).resolve()
            if target != root and root not in target.parents:
                raise ValueError(f"archive member escapes destination: {member.name}")
        bundle.extractall(destination)


def build_prompt(fixture: dict) -> str:
    mode = fixture["execution_mode"]
    if mode == "goal":
        mode_instructions = (
            "The user has already created a Goal. Do not create another Goal. "
            "Use Goal continuation state and autonomous confirmation when the workflow permits execution. "
            "Label every confirmation as autonomous rather than human."
        )
    else:
        mode_instructions = "This is a single-turn workflow task; do not initialize Goal mode."
    return (
        "Follow the installed dev-workflow skill and its state commands exactly. "
        "Work only inside the current repository. Do not inspect evaluation fixture files or infer gold labels. "
        "Do not call external reviewers because this benchmark isolates provider effects; use the built-in adversarial checklist and label that downgrade truthfully. "
        f"{mode_instructions}\n\n"
        f"Task:\n{fixture['prompt']}\n\n"
        "Finish with the visible tier line required by the skill and report only evidence actually observed."
    )


def _walk_dicts(value: Any):
    if isinstance(value, dict):
        yield value
        for nested in value.values():
            yield from _walk_dicts(nested)
    elif isinstance(value, list):
        for nested in value:
            yield from _walk_dicts(nested)


def parse_codex_jsonl(output: str) -> dict:
    final_parts: list[str] = []
    test_exit_codes: list[int] = []
    for line in output.splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        for item in _walk_dicts(event):
            if item.get("type") == "agent_message" and isinstance(item.get("text"), str):
                final_parts.append(item["text"])
            command = item.get("command") or item.get("cmd")
            exit_code = item.get("exit_code", item.get("exitCode"))
            if (
                isinstance(command, str)
                and TEST_COMMAND_PATTERN.search(command)
                and isinstance(exit_code, int)
            ):
                test_exit_codes.append(exit_code)
    tests = {"observed": bool(test_exit_codes)}
    if test_exit_codes:
        tests["exit_code"] = test_exit_codes[-1]
    return {"final": "\n".join(final_parts).strip(), "tests": tests}


def _state_value(workflow_script: Path, workspace: Path, field: str) -> str:
    completed = subprocess.run(
        ["bash", str(workflow_script), "--repo", str(workspace), "get", field],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        check=False,
    )
    return completed.stdout.strip() if completed.returncode == 0 else ""


def capture_state(plugin_root: Path, workspace: Path) -> dict:
    state_file = workspace / "docs" / "superpowers" / ".workflow-state.yaml"
    if not state_file.exists():
        return {"current": {}, "history": []}
    script = plugin_root / "scripts" / "workflow-state.sh"
    fields = {
        "phase": _state_value(script, workspace, "phase"),
        "execution": {
            "mode": _state_value(script, workspace, "execution.mode"),
            "objective_sha256": _state_value(script, workspace, "execution.objective_sha256"),
            "continuation": _state_value(script, workspace, "execution.continuation"),
        },
        "understanding": {
            "status": _state_value(script, workspace, "understanding.status"),
            "kind": _state_value(script, workspace, "understanding.kind"),
            "scope_sha256": _state_value(script, workspace, "understanding.scope_sha256"),
        },
        "confirmation": {
            "mode": _state_value(script, workspace, "confirmation.mode"),
            "status": _state_value(script, workspace, "confirmation.status"),
        },
    }
    return {"current": fields, "history": [fields]}


def _write_json(path: Path, value: dict) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def run_provider(plugin_ref: str, repo_root: Path, model: str | None) -> int:
    fixture_path = Path(os.environ["TIERS_FIXTURE"])
    run_dir = Path(os.environ["TIERS_RUN_DIR"])
    workspace = Path.cwd()
    codex_home = Path(os.environ["CODEX_HOME"])
    source_codex_home = Path(os.environ.get("TIERS_SOURCE_CODEX_HOME", ""))
    fixture = load_fixture(fixture_path)
    plugin_root = run_dir / "plugin"
    materialize_plugin(repo_root, plugin_ref, plugin_root)

    for name in ("config.toml", "auth.json"):
        source = source_codex_home / name
        if source.is_file():
            shutil.copy2(source, codex_home / name)

    install = subprocess.run(
        [
            "bash",
            str(plugin_root / "bin" / "install-codex"),
            "--codex-home",
            str(codex_home),
            "--yes",
        ],
        env={**os.environ, "DEV_WORKFLOW_PLUGIN_ROOT": str(plugin_root)},
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        check=False,
    )
    if install.returncode != 0:
        print(install.stderr or install.stdout, file=sys.stderr)
        return install.returncode

    codex = os.environ.get("TIERS_CODEX_BIN") or shutil.which("codex")
    if not codex:
        print("codex binary not found", file=sys.stderr)
        return 127
    command = [
        codex,
        "exec",
        "--json",
        "--skip-git-repo-check",
        "--sandbox",
        "workspace-write",
        "--cd",
        str(workspace),
    ]
    if model:
        command.extend(["--model", model])
    command.extend(["--", build_prompt(fixture)])
    completed = subprocess.run(
        command,
        env=os.environ.copy(),
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        check=False,
    )
    parsed = parse_codex_jsonl(completed.stdout)
    (run_dir / "transcript.jsonl").write_text(completed.stdout, encoding="utf-8")
    (run_dir / "final.txt").write_text(parsed["final"], encoding="utf-8")
    _write_json(run_dir / "tests.json", parsed["tests"])
    _write_json(run_dir / "state.json", capture_state(plugin_root, workspace))
    if completed.stderr:
        print(completed.stderr, file=sys.stderr, end="")
    print(completed.stdout, end="")
    return completed.returncode


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plugin-ref", required=True)
    parser.add_argument("--repo-root", type=Path, default=ROOT)
    parser.add_argument("--model")
    args = parser.parse_args()
    return run_provider(args.plugin_ref, args.repo_root, args.model)


if __name__ == "__main__":
    raise SystemExit(main())
