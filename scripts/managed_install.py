#!/usr/bin/env python3
"""Managed installation primitives for the global dev-workflow command."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
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
DEFAULT_REPO_URL = "https://github.com/whrjunluo/tiers.git"


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
        command = " ".join(str(arg) for arg in args)
        raise ManagedInstallError(f"Command failed ({exc.returncode}): {command}: {detail}") from exc
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
                "--prune-tags",
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
            "bin/install-trae",
            "bin/doctor",
            "bin/dev-workflow",
            "skills/dev-workflow/SKILL.md",
            "skills/external-agent/SKILL.md",
            "skills/grill-me/SKILL.md",
            "skills/grilling/SKILL.md",
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

    def ensure_global_command(self) -> None:
        self.paths.bin_dir.mkdir(parents=True, exist_ok=True)
        if os.path.lexists(self.paths.command_link) and not self.paths.command_link.is_symlink():
            raise ManagedInstallError(
                f"Refusing to replace non-symlink command: {self.paths.command_link}"
            )
        self._replace_command_link(self.paths.current / "bin/dev-workflow")

    def _replace_command_link(self, target: Path) -> None:
        self.paths.bin_dir.mkdir(parents=True, exist_ok=True)
        temporary = self.paths.bin_dir / f".dev-workflow.{os.getpid()}"
        try:
            if os.path.lexists(temporary):
                temporary.unlink()
            temporary.symlink_to(target)
            os.replace(temporary, self.paths.command_link)
        finally:
            if os.path.lexists(temporary):
                temporary.unlink()

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
            if platform not in ("codex", "cursor", "trae"):
                raise ManagedInstallError(f"Unsupported platform: {platform}")
            args = ["bash", str(plugin_root / "bin" / f"install-{platform}"), "--yes"]
            if install_deps:
                args.append("--install-deps")
            output = self.runner(args, env=env)
            if output:
                print(output, end="" if output.endswith("\n") else "\n")

    def run_doctor(self, plugin_root: Path, platforms: Sequence[str]) -> None:
        env = dict(os.environ)
        env["DEV_WORKFLOW_PLUGIN_ROOT"] = str(self.paths.current)
        for platform in platforms:
            output = self.runner(
                ["bash", str(plugin_root / "bin/doctor"), "--platform", platform],
                env=env,
            )
            if output:
                print(output, end="" if output.endswith("\n") else "\n")

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
        if any(platform not in ("codex", "cursor", "trae") for platform in normalized_platforms):
            raise ManagedInstallError("Platforms must contain only codex, cursor, and trae")

        manifest_version = self.validate_candidate(candidate, revision)
        previous_state = self.load_state()
        previous_target = self.paths.current.resolve() if self.paths.current.is_symlink() else None
        command_existed = os.path.lexists(self.paths.command_link)
        previous_command_target = (
            Path(os.readlink(self.paths.command_link))
            if self.paths.command_link.is_symlink()
            else None
        )
        self._replace_current(candidate)
        try:
            self.ensure_global_command()
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
                    "reload_required": True,
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
            if previous_command_target is not None:
                self._replace_command_link(previous_command_target)
            elif not command_existed and os.path.lexists(self.paths.command_link):
                self.paths.command_link.unlink()
            raise


def manager_from_env(env: Mapping[str, str] = os.environ) -> ManagedInstaller:
    paths = InstallPaths.from_env(env)
    repo_url = env.get("DEV_WORKFLOW_REPO_URL", DEFAULT_REPO_URL)
    return ManagedInstaller(paths, repo_url)


def require_state(manager: ManagedInstaller) -> dict[str, Any]:
    state = manager.load_state()
    required = (
        "channel",
        "platforms",
        "active_ref",
        "active_commit",
        "manifest_version",
    )
    missing = [field for field in required if field not in state]
    if missing:
        raise ManagedInstallError(
            "No complete managed installation was found; run install.sh first"
        )
    return state


def print_status(manager: ManagedInstaller) -> None:
    state = require_state(manager)
    print("dev-workflow managed installation")
    print(f"Install root: {manager.paths.install_root}")
    print(f"Channel: {state['channel']}")
    print(f"Active ref: {state['active_ref']}")
    print(f"Active commit: {state['active_commit']}")
    print(f"Manifest version: {state['manifest_version']}")
    print(f"Platforms: {', '.join(state['platforms'])}")
    print(f"Reload required: {'yes' if state.get('reload_required') else 'no'}")


def warn_path(manager: ManagedInstaller) -> None:
    path_entries = [Path(entry).expanduser() for entry in os.environ.get("PATH", "").split(os.pathsep)]
    if manager.paths.bin_dir not in path_entries:
        print(
            f"Warning: {manager.paths.bin_dir} is not in PATH; add it to run dev-workflow globally.",
            file=sys.stderr,
        )


def print_reload_guidance(platforms: Sequence[str]) -> None:
    if "codex" in platforms:
        print("Restart Codex or open a new conversation to reload plugin hooks and skills.")
    if "cursor" in platforms:
        print("Reload Window or restart Cursor to reload skills.")
    if "trae" in platforms:
        print("Restart TRAE IDE or TRAE CLI to reload the skill index.")


def command_update(manager: ManagedInstaller, channel: Optional[str], install_deps: bool) -> None:
    state = require_state(manager)
    selected_channel = channel or str(state["channel"])
    platforms = list(state["platforms"])
    with manager.update_lock():
        manager.ensure_repository()
        revision = manager.resolve_revision(selected_channel)
        candidate = manager.prepare_candidate(revision)
        result = manager.activate_candidate(
            candidate, revision, platforms, install_deps=install_deps
        )
    print(
        f"Updated dev-workflow to {result['manifest_version']} "
        f"({result['channel']}, {result['active_commit'][:12]})."
    )
    warn_path(manager)
    print_reload_guidance(platforms)


def command_install(manager: ManagedInstaller, target: str, install_deps: bool) -> None:
    state = require_state(manager)
    requested = ["codex", "cursor", "trae"] if target == "all" else [target]
    platforms = sorted(set(state["platforms"]) | set(requested))
    revision = Revision(
        str(state["channel"]), str(state["active_ref"]), str(state["active_commit"])
    )
    if not manager.paths.current.is_symlink():
        raise ManagedInstallError("Managed current version is missing; run dev-workflow update")
    candidate = manager.paths.current.resolve()
    with manager.update_lock():
        result = manager.activate_candidate(
            candidate, revision, platforms, install_deps=install_deps
        )
    print(f"Installed dev-workflow {result['manifest_version']} for {', '.join(platforms)}.")
    warn_path(manager)
    print_reload_guidance(platforms)


def command_doctor(manager: ManagedInstaller, doctor_args: Sequence[str]) -> int:
    require_state(manager)
    if not manager.paths.current.is_symlink():
        raise ManagedInstallError("Managed current version is missing; run dev-workflow update")
    env = dict(os.environ)
    env["DEV_WORKFLOW_PLUGIN_ROOT"] = str(manager.paths.current)
    completed = subprocess.run(
        ["bash", str(manager.paths.current / "bin/doctor"), *doctor_args], env=env
    )
    return completed.returncode


def command_init(manager: ManagedInstaller, init_args: Sequence[str]) -> int:
    require_state(manager)
    if not manager.paths.current.is_symlink():
        raise ManagedInstallError("Managed current version is missing; run dev-workflow update")
    env = dict(os.environ)
    env["DEV_WORKFLOW_PLUGIN_ROOT"] = str(manager.paths.current)
    completed = subprocess.run(
        ["bash", str(manager.paths.current / "bin/init"), *init_args], env=env
    )
    return completed.returncode


def command_bootstrap(manager: ManagedInstaller, arguments: Sequence[str]) -> None:
    parser = argparse.ArgumentParser(prog="dev-workflow _bootstrap", add_help=False)
    parser.add_argument("--channel", required=True, choices=("stable", "edge"))
    parser.add_argument("--ref", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--platform", required=True, choices=("codex", "cursor", "trae", "all"))
    parser.add_argument("--install-deps", action="store_true")
    parsed = parser.parse_args(list(arguments))

    if os.environ.get("DEV_WORKFLOW_BOOTSTRAP_LOCK_HELD") != "1" or not manager.paths.lock_dir.is_dir():
        raise ManagedInstallError("Bootstrap activation requires the managed update lock")
    if not re.fullmatch(r"[0-9a-f]{40}", parsed.commit):
        raise ManagedInstallError("Bootstrap commit must be a full lowercase Git object ID")
    if parsed.channel == "edge" and parsed.ref != "refs/remotes/origin/main":
        raise ManagedInstallError("Edge bootstrap must use refs/remotes/origin/main")
    if parsed.channel == "stable" and not parsed.ref.startswith("refs/tags/v"):
        raise ManagedInstallError("Stable bootstrap must use a semantic release tag")

    revision = Revision(parsed.channel, parsed.ref, parsed.commit)
    candidate = manager.prepare_candidate(revision)
    requested = ["codex", "cursor", "trae"] if parsed.platform == "all" else [parsed.platform]
    existing = manager.load_state().get("platforms", [])
    platforms = sorted(set(existing) | set(requested))
    result = manager.activate_candidate(
        candidate, revision, platforms, install_deps=parsed.install_deps
    )
    print(
        f"Installed dev-workflow {result['manifest_version']} "
        f"({result['channel']}, {result['active_commit'][:12]})."
    )
    warn_path(manager)
    print_reload_guidance(platforms)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="dev-workflow")
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("status", help="show the active managed installation")

    update = subparsers.add_parser("update", help="update recorded platforms")
    update.add_argument("--channel", choices=("stable", "edge"))
    update.add_argument("--install-deps", action="store_true")

    install = subparsers.add_parser("install", help="add or refresh a platform")
    install.add_argument("platform", choices=("codex", "cursor", "trae", "all"))
    install.add_argument("--install-deps", action="store_true")
    subparsers.add_parser("doctor", help="run the active installation doctor")
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    arguments = list(argv if argv is not None else sys.argv[1:])
    manager = manager_from_env()
    try:
        if arguments and arguments[0] == "_bootstrap":
            command_bootstrap(manager, arguments[1:])
            return 0
        if arguments and arguments[0] == "doctor":
            return command_doctor(manager, arguments[1:])
        parsed = build_parser().parse_args(arguments)
        if parsed.command == "status":
            print_status(manager)
        elif parsed.command == "update":
            command_update(manager, parsed.channel, parsed.install_deps)
        elif parsed.command == "install":
            command_install(manager, parsed.platform, parsed.install_deps)
        return 0
    except ManagedInstallError as exc:
        print(f"dev-workflow: {exc}", file=sys.stderr)
        return 1
