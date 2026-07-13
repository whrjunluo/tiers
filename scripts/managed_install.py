#!/usr/bin/env python3
"""Managed installation primitives for the global dev-workflow command."""

from __future__ import annotations

import json
import os
import re
import subprocess
import tempfile
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Iterable, Iterator, Mapping, Optional, Sequence, Tuple


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

    def prepare_candidate(self, revision: Revision) -> Path:
        candidate = self.paths.versions / revision.commit
        if candidate.exists():
            actual_commit = self.runner(
                ["git", "-C", str(candidate), "rev-parse", "HEAD"]
            ).strip()
            status = self.runner(
                ["git", "-C", str(candidate), "status", "--porcelain"]
            ).strip()
            if actual_commit != revision.commit or status:
                raise ManagedInstallError(
                    f"Existing candidate is not an immutable clean worktree: {candidate}"
                )
            return candidate
        self.paths.versions.mkdir(parents=True, exist_ok=True)
        self.runner(
            [
                "git",
                "--git-dir",
                str(self.paths.source_git),
                "worktree",
                "add",
                "--detach",
                str(candidate),
                revision.commit,
            ]
        )
        return candidate

    def validate_candidate(self, candidate: Path, revision: Revision) -> str:
        required_files = (
            "bin/install-codex",
            "bin/install-cursor",
            "bin/doctor",
            "bin/dev-workflow",
            "skills/dev-workflow/SKILL.md",
            "skills/external-agent/SKILL.md",
            "skills/grill-me/SKILL.md",
        )
        for relative in required_files:
            if not (candidate / relative).is_file():
                raise ManagedInstallError(f"Candidate is missing required file: {relative}")

        versions = {}
        for relative in (
            ".codex-plugin/plugin.json",
            ".cursor-plugin/plugin.json",
            ".claude-plugin/plugin.json",
        ):
            path = candidate / relative
            try:
                with path.open(encoding="utf-8") as handle:
                    manifest = json.load(handle)
                version = manifest["version"]
            except (OSError, json.JSONDecodeError, KeyError, TypeError) as exc:
                raise ManagedInstallError(f"Cannot read candidate manifest {relative}: {exc}") from exc
            if not isinstance(version, str) or not version:
                raise ManagedInstallError(f"Candidate manifest has an invalid version: {relative}")
            versions[relative] = version

        unique_versions = set(versions.values())
        if len(unique_versions) != 1:
            detail = ", ".join(f"{name}={version}" for name, version in versions.items())
            raise ManagedInstallError(f"Candidate manifest versions do not match: {detail}")
        manifest_version = unique_versions.pop()

        actual_commit = self.runner(
            ["git", "-C", str(candidate), "rev-parse", "HEAD"]
        ).strip()
        if actual_commit != revision.commit:
            raise ManagedInstallError(
                f"Candidate commit mismatch: expected {revision.commit}, found {actual_commit}"
            )

        if revision.channel == "stable":
            tag = revision.ref.removeprefix("refs/tags/")
            tag_version = tag.removeprefix("v")
            if parse_semver_tag(tag) is None or tag_version != manifest_version:
                raise ManagedInstallError(
                    f"Stable tag version {tag_version} does not match manifest version {manifest_version}"
                )
        return manifest_version

    @contextmanager
    def update_lock(self) -> Iterator[None]:
        self.paths.install_root.mkdir(parents=True, exist_ok=True)
        try:
            self.paths.lock_dir.mkdir()
        except FileExistsError as exc:
            raise ManagedInstallError(
                f"Another dev-workflow update is already in progress ({self.paths.lock_dir})"
            ) from exc
        try:
            yield
        finally:
            try:
                self.paths.lock_dir.rmdir()
            except FileNotFoundError:
                pass

    def _replace_current(self, target: Path) -> None:
        self.paths.install_root.mkdir(parents=True, exist_ok=True)
        if os.path.lexists(self.paths.current) and not self.paths.current.is_symlink():
            raise ManagedInstallError(f"Managed current path is not a symlink: {self.paths.current}")
        temporary = self.paths.install_root / f".current.{os.getpid()}"
        try:
            if os.path.lexists(temporary):
                temporary.unlink()
            temporary.symlink_to(target, target_is_directory=True)
            os.replace(temporary, self.paths.current)
        finally:
            if os.path.lexists(temporary):
                temporary.unlink()

    def _remove_current(self) -> None:
        if os.path.lexists(self.paths.current):
            if not self.paths.current.is_symlink():
                raise ManagedInstallError(f"Managed current path is not a symlink: {self.paths.current}")
            self.paths.current.unlink()

    def run_platform_installers(
        self,
        plugin_root: Path,
        platforms: Sequence[str],
        *,
        install_deps: bool = False,
    ) -> None:
        env = dict(os.environ)
        env["DEV_WORKFLOW_PLUGIN_ROOT"] = str(self.paths.current)
        for platform in platforms:
            if platform not in ("codex", "cursor"):
                raise ManagedInstallError(f"Unsupported platform: {platform}")
            args = ["bash", str(plugin_root / "bin" / f"install-{platform}"), "--yes"]
            if install_deps:
                args.append("--install-deps")
            self.runner(args, env=env)

    def run_doctor(self, plugin_root: Path, platforms: Sequence[str]) -> None:
        env = dict(os.environ)
        env["DEV_WORKFLOW_PLUGIN_ROOT"] = str(self.paths.current)
        for platform in platforms:
            self.runner(
                ["bash", str(plugin_root / "bin/doctor"), "--platform", platform],
                env=env,
            )

    def activate_candidate(
        self,
        candidate: Path,
        revision: Revision,
        platforms: Sequence[str],
        *,
        install_deps: bool = False,
    ) -> dict[str, Any]:
        normalized_platforms = sorted(set(platforms))
        if not normalized_platforms:
            raise ManagedInstallError("At least one platform is required for activation")
        if any(platform not in ("codex", "cursor") for platform in normalized_platforms):
            raise ManagedInstallError("Platforms must contain only codex and cursor")

        manifest_version = self.validate_candidate(candidate, revision)
        previous_state = self.load_state()
        previous_target = self.paths.current.resolve() if self.paths.current.is_symlink() else None
        self._replace_current(candidate)
        try:
            self.run_platform_installers(
                candidate, normalized_platforms, install_deps=install_deps
            )
            self.run_doctor(candidate, normalized_platforms)
            return self.write_state(
                {
                    "schema_version": 1,
                    "channel": revision.channel,
                    "platforms": normalized_platforms,
                    "active_ref": revision.ref,
                    "active_commit": revision.commit,
                    "manifest_version": manifest_version,
                    "updated_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
                }
            )
        except Exception:
            if previous_target is None:
                self._remove_current()
            else:
                self._replace_current(previous_target)
                previous_platforms = previous_state.get("platforms", [])
                if previous_platforms:
                    try:
                        self.run_platform_installers(previous_target, previous_platforms)
                    except Exception:
                        pass
            raise
