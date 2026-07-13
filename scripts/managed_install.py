#!/usr/bin/env python3
"""Managed installation primitives for the global dev-workflow command."""

from __future__ import annotations

import json
import os
import re
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Iterable, Mapping, Optional, Sequence, Tuple


class ManagedInstallError(RuntimeError):
    """A user-actionable managed installation failure."""


CommandRunner = Callable[..., str]
SEMVER_TAG = re.compile(r"^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")


def run_command(
    args: Sequence[str],
    *,
    cwd: Optional[Path] = None,
    env: Optional[Mapping[str, str]] = None,
) -> str:
    try:
        completed = subprocess.run(
            list(args),
            cwd=str(cwd) if cwd else None,
            env=dict(env) if env else None,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
    except FileNotFoundError as exc:
        raise ManagedInstallError(f"Required command not found: {args[0]}") from exc
    except subprocess.CalledProcessError as exc:
        detail = (exc.stderr or exc.stdout or "command failed").strip()
        raise ManagedInstallError(f"{args[0]} failed: {detail}") from exc
    return completed.stdout


def parse_semver_tag(tag: str) -> Optional[Tuple[int, int, int]]:
    match = SEMVER_TAG.fullmatch(tag.strip())
    if not match:
        return None
    return tuple(int(part) for part in match.groups())  # type: ignore[return-value]


def latest_semver_tag(tags: Iterable[str]) -> Optional[str]:
    parsed = [(version, tag.strip()) for tag in tags if (version := parse_semver_tag(tag))]
    return max(parsed)[1] if parsed else None


@dataclass(frozen=True)
class InstallPaths:
    install_root: Path
    bin_dir: Path

    @classmethod
    def from_env(
        cls,
        env: Mapping[str, str] = os.environ,
        *,
        home: Optional[Path] = None,
    ) -> "InstallPaths":
        resolved_home = home or Path.home()
        install_root = Path(
            env.get("DEV_WORKFLOW_INSTALL_ROOT", resolved_home / ".local/share/dev-workflow")
        ).expanduser()
        bin_dir = Path(env.get("DEV_WORKFLOW_BIN_DIR", resolved_home / ".local/bin")).expanduser()
        return cls(install_root=install_root, bin_dir=bin_dir)

    @property
    def source_git(self) -> Path:
        return self.install_root / "source.git"

    @property
    def versions(self) -> Path:
        return self.install_root / "versions"

    @property
    def current(self) -> Path:
        return self.install_root / "current"

    @property
    def state_file(self) -> Path:
        return self.install_root / "install.json"

    @property
    def lock_dir(self) -> Path:
        return self.install_root / "update.lock"

    @property
    def command_link(self) -> Path:
        return self.bin_dir / "dev-workflow"


@dataclass(frozen=True)
class Revision:
    channel: str
    ref: str
    commit: str


class ManagedInstaller:
    def __init__(
        self,
        paths: InstallPaths,
        repo_url: str,
        *,
        runner: CommandRunner = run_command,
    ) -> None:
        self.paths = paths
        self.repo_url = repo_url
        self.runner = runner

    def ensure_repository(self) -> None:
        self.paths.install_root.mkdir(parents=True, exist_ok=True)
        self.paths.versions.mkdir(parents=True, exist_ok=True)
        if not self.paths.source_git.exists():
            self.runner(
                ["git", "clone", "--bare", self.repo_url, str(self.paths.source_git)]
            )
        else:
            self.runner(
                [
                    "git",
                    "--git-dir",
                    str(self.paths.source_git),
                    "remote",
                    "set-url",
                    "origin",
                    self.repo_url,
                ]
            )
        self.runner(
            [
                "git",
                "--git-dir",
                str(self.paths.source_git),
                "fetch",
                "--prune",
                "origin",
                "+refs/heads/main:refs/remotes/origin/main",
                "+refs/tags/*:refs/tags/*",
            ]
        )

    def resolve_revision(self, channel: str) -> Revision:
        if channel == "stable":
            tags = self.runner(
                ["git", "--git-dir", str(self.paths.source_git), "tag", "--list"]
            ).splitlines()
            tag = latest_semver_tag(tags)
            if not tag:
                raise ManagedInstallError("No stable release tag matching v<major>.<minor>.<patch> was found")
            ref = f"refs/tags/{tag}"
            commit = self.runner(
                [
                    "git",
                    "--git-dir",
                    str(self.paths.source_git),
                    "rev-parse",
                    f"{ref}^{{commit}}",
                ]
            ).strip()
            return Revision(channel, ref, commit)
        if channel == "edge":
            ref = "refs/remotes/origin/main"
            commit = self.runner(
                [
                    "git",
                    "--git-dir",
                    str(self.paths.source_git),
                    "rev-parse",
                    f"{ref}^{{commit}}",
                ]
            ).strip()
            return Revision(channel, ref, commit)
        raise ManagedInstallError(f"Unsupported channel: {channel}. Expected stable or edge")

    def load_state(self) -> dict[str, Any]:
        if not self.paths.state_file.exists():
            return {}
        try:
            with self.paths.state_file.open(encoding="utf-8") as handle:
                state = json.load(handle)
        except (OSError, json.JSONDecodeError) as exc:
            raise ManagedInstallError(f"Cannot read installation state: {exc}") from exc
        if not isinstance(state, dict):
            raise ManagedInstallError("Installation state must be a JSON object")
        return state

    def write_state(self, updates: Mapping[str, Any]) -> dict[str, Any]:
        self.paths.install_root.mkdir(parents=True, exist_ok=True)
        state = self.load_state()
        state.update(updates)
        descriptor, temp_name = tempfile.mkstemp(
            prefix=".install.json.", dir=str(self.paths.install_root), text=True
        )
        temp_path = Path(temp_name)
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
                json.dump(state, handle, ensure_ascii=False, indent=2, sort_keys=True)
                handle.write("\n")
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temp_path, self.paths.state_file)
        finally:
            if temp_path.exists():
                temp_path.unlink()
        return state
