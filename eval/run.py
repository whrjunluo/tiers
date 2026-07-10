"""Isolated provider runner for opt-in tiers evaluations."""

from __future__ import annotations

import argparse
import json
import os
import shlex
import shutil
import subprocess
from datetime import datetime, timezone
from pathlib import Path

from .schema import load_fixture


ROOT = Path(__file__).resolve().parents[1]


def _timestamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _write_json_atomic(path: Path, value: dict) -> None:
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    os.replace(temporary, path)


def _ensure_capture_contract(run_dir: Path, stdout: str) -> None:
    defaults = {
        "transcript.jsonl": stdout,
        "final.txt": stdout,
        "state.json": json.dumps({"current": {}, "history": []}) + "\n",
        "tests.json": json.dumps({"observed": False}) + "\n",
    }
    for name, content in defaults.items():
        path = run_dir / name
        if not path.exists():
            path.write_text(content, encoding="utf-8")


def run_case(
    fixture_path: Path,
    variant: str,
    provider_command: str,
    results_root: Path,
    *,
    timeout: float = 600,
    repo_fixtures_root: Path | None = None,
) -> Path:
    fixture_path = Path(fixture_path).resolve()
    fixture = load_fixture(fixture_path)
    results_root = Path(results_root).resolve()
    run_dir = results_root / variant / fixture["id"]
    if run_dir.exists():
        shutil.rmtree(run_dir)
    run_dir.mkdir(parents=True)

    fixtures_root = Path(repo_fixtures_root or ROOT / "eval" / "repos")
    source_repo = fixtures_root / fixture["repo_fixture"]
    if not source_repo.is_dir():
        raise FileNotFoundError(f"repo fixture not found: {source_repo}")
    workspace = run_dir / "workspace"
    shutil.copytree(source_repo, workspace)
    codex_home = run_dir / "codex-home"
    codex_home.mkdir()

    argv = shlex.split(provider_command)
    if not argv:
        raise ValueError("provider command cannot be empty")
    env = os.environ.copy()
    env.update(
        {
            "TIERS_FIXTURE": str(fixture_path),
            "TIERS_VARIANT": variant,
            "TIERS_RUN_DIR": str(run_dir),
            "CODEX_HOME": str(codex_home),
        }
    )
    metadata = {
        "status": "ok",
        "fixture_id": fixture["id"],
        "variant": variant,
        "provider": argv[0],
        "model": env.get("TIERS_MODEL", "unspecified"),
        "started_at": _timestamp(),
        "attempted_actions": [],
        "paused_before": [],
    }
    stdout = ""
    stderr = ""
    try:
        completed = subprocess.run(
            argv,
            cwd=workspace,
            env=env,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=timeout,
            check=False,
        )
        stdout = completed.stdout
        stderr = completed.stderr
        metadata["exit_code"] = completed.returncode
    except FileNotFoundError as exc:
        metadata.update(
            {
                "status": "infrastructure_error",
                "error_type": "missing_provider",
                "error": str(exc),
            }
        )
    except subprocess.TimeoutExpired as exc:
        stdout = exc.stdout or ""
        stderr = exc.stderr or ""
        if isinstance(stdout, bytes):
            stdout = stdout.decode("utf-8", errors="replace")
        if isinstance(stderr, bytes):
            stderr = stderr.decode("utf-8", errors="replace")
        metadata.update(
            {
                "status": "infrastructure_error",
                "error_type": "timeout",
                "error": f"provider timed out after {timeout}s",
            }
        )

    metadata["finished_at"] = _timestamp()
    (run_dir / "stdout.txt").write_text(stdout, encoding="utf-8")
    (run_dir / "stderr.txt").write_text(stderr, encoding="utf-8")
    _ensure_capture_contract(run_dir, stdout)
    _write_json_atomic(run_dir / "run.json", metadata)
    return run_dir


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", required=True, type=Path)
    parser.add_argument("--variant", required=True)
    parser.add_argument("--provider-command", required=True)
    parser.add_argument("--results-root", type=Path, default=ROOT / "eval" / "results")
    parser.add_argument("--timeout", type=float, default=600)
    args = parser.parse_args()
    run_dir = run_case(
        args.fixture,
        args.variant,
        args.provider_command,
        args.results_root,
        timeout=args.timeout,
    )
    print(run_dir)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
