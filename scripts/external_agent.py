"""
Unified external-agent runner for the dev-workflow plugin.

One entry point for delegating a bounded task to an external coding-agent CLI,
or for getting an independent second opinion. Replaces the per-tool
collaborating-with-* bridges and the shell external-agent.sh runner.

  python external_agent.py --agent <name> --cd DIR --PROMPT "..." \
      [--mode review|delegate] [--format text|json] [--SESSION_ID id] \
      [--context none|git] [--model M] [--list] [--require-permissions]

  python external_agent.py --cross-review agy,mimo --cd DIR --PROMPT "..." \
      [--format text|json] [--context none|git] \
      [--review-profile standard|small-fix] [--timeout N]

Agents: codex, gemini, mimo, cursor, grok, antigravity (alias: agy).

--mode review   : read-only posture (independent review / research). Default.
--mode delegate : read-write posture (let the agent implement). Needs user OK.

--format text   : print the agent's reply as plain text. Default.
--format json   : print {success, SESSION_ID, agent_messages, error?}.

The orchestrator (the main agent) stays responsible for the final decision and
verification; this runner is only the hands. See SKILL.md for routing policy.
"""
from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import json
import os
import queue
import signal
import shutil
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone
from typing import Generator, List, Optional, Tuple


# ----------------------------------------------------------------------------- helpers

def _stream(cmd: List[str], cwd: str, sentinel_type: Optional[str],
            timeout: int) -> Generator[str, None, None]:
    """Run cmd in cwd, yield stdout lines. If sentinel_type is set, terminate the
    process once a JSON line with that top-level "type" is seen (streaming CLIs)."""
    proc = subprocess.Popen(
        cmd, cwd=cwd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL, text=True, encoding="utf-8", errors="replace",
    )
    q: "queue.Queue[Optional[str]]" = queue.Queue()

    def reader() -> None:
        if proc.stdout:
            for line in iter(proc.stdout.readline, ""):
                s = line.strip()
                q.put(s)
                if sentinel_type:
                    try:
                        if json.loads(s).get("type") == sentinel_type:
                            proc.terminate()
                            break
                    except Exception:
                        pass
            proc.stdout.close()
        q.put(None)

    t = threading.Thread(target=reader)
    t.start()
    started = time.monotonic()
    while True:
        elapsed = time.monotonic() - started
        if elapsed >= timeout:
            proc.kill()
            proc.wait()
            t.join(timeout=5)
            raise subprocess.TimeoutExpired(cmd, timeout)
        try:
            line = q.get(timeout=min(0.5, timeout - elapsed))
            if line is None:
                break
            yield line
        except queue.Empty:
            if proc.poll() is not None and not t.is_alive():
                break
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill(); proc.wait()
    t.join(timeout=5)
    while not q.empty():
        line = q.get_nowait()
        if line is not None:
            yield line


def _capture(cmd: List[str], cwd: str, timeout: int,
             input_text: Optional[str] = None) -> Tuple[int, str, str]:
    p = subprocess.run(cmd, cwd=cwd, input=input_text,
                       stdin=None if input_text is not None else subprocess.DEVNULL,
                       capture_output=True,
                       text=True, encoding="utf-8", errors="replace", timeout=timeout)
    return p.returncode, (p.stdout or ""), (p.stderr or "")


# ----------------------------------------------------------------------------- adapters
# Each adapter returns (argv, parser_kind, sentinel). parser_kind in:
#   "codex" | "gemini" | "mimo" | "cursor" | "grok" | "raw"

def _codex(prompt, cd, mode, sid, model, skip_perm):
    sandbox = "workspace-write" if mode == "delegate" else "read-only"
    cmd = ["codex", "exec", "--json", "--skip-git-repo-check", "--sandbox", sandbox, "--cd", cd]
    if model:
        cmd += ["--model", model]
    if sid:
        cmd += ["resume", sid]
    cmd += ["--", prompt]
    return cmd, "codex", "turn.completed"


def _gemini(prompt, cd, mode, sid, model, skip_perm):
    cmd = ["gemini", "--prompt", prompt, "-o", "stream-json"]
    if model:
        cmd += ["--model", model]
    if sid:
        cmd += ["--resume", sid]
    return cmd, "gemini", None


def _mimo(prompt, cd, mode, sid, model, skip_perm):
    cmd = ["mimo", "run", "--format", "json", "--dir", cd]
    if skip_perm:
        cmd.append("--dangerously-skip-permissions")
    if model:
        cmd += ["--model", model]
    if sid:
        cmd += ["--session", sid]
    cmd.append(prompt)
    return cmd, "mimo", None


def _cursor(prompt, cd, mode, sid, model, skip_perm):
    # --trust avoids the interactive "Workspace Trust Required" prompt (headless has no TTY).
    cmd = ["cursor-agent", "-p", "--output-format", "json", "--trust"]
    if mode == "review":
        cmd += ["--mode", "ask", "--sandbox", "enabled"]
    elif skip_perm:
        cmd.append("--force")
    if model:
        cmd += ["--model", model]
    if sid:
        cmd += ["--resume", sid]
    cmd.append(prompt)
    return cmd, "cursor", None


def _grok(prompt, cd, mode, sid, model, skip_perm):
    perm = "plan" if mode == "review" else ("bypassPermissions" if skip_perm else "default")
    cmd = ["grok", "-p", prompt, "--output-format", "json", "--cwd", cd, "--permission-mode", perm]
    if model:
        cmd += ["--model", model]
    if sid:
        cmd += ["--resume", sid]
    return cmd, "grok", None


def _agy(prompt, cd, mode, sid, model, skip_perm):
    cmd = ["agy", "--sandbox", "--print", prompt]
    if model:
        cmd += ["--model", model]
    return cmd, "raw", None


def _opencode(prompt, cd, mode, sid, model, skip_perm):
    # opencode shares MiMoCode's CLI surface and NDJSON event schema (same upstream).
    cmd = ["opencode", "run", "--format", "json", "--dir", cd]
    if skip_perm:
        cmd.append("--dangerously-skip-permissions")
    if model:
        cmd += ["--model", model]
    if sid:
        cmd += ["--session", sid]
    cmd.append(prompt)
    return cmd, "mimo", None


AGENTS = {
    "codex":       {"bin": "codex",        "build": _codex,    "resume": True,  "family": "openai"},
    "gemini":      {"bin": "gemini",       "build": _gemini,   "resume": True,  "family": "google"},
    "mimo":        {"bin": "mimo",         "build": _mimo,     "resume": True,  "family": "xiaomi"},
    "cursor":      {"bin": "cursor-agent", "build": _cursor,   "resume": True,  "family": "cursor"},
    "grok":        {"bin": "grok",         "build": _grok,     "resume": True,  "family": "xai"},
    "opencode":    {"bin": "opencode",     "build": _opencode, "resume": True,  "family": "configurable"},
    "antigravity": {"bin": "agy",          "build": _agy,      "resume": False, "family": "google"},
}
ALIASES = {"agy": "antigravity", "cursor-agent": "cursor"}


# ----------------------------------------------------------------------------- persistent provider health

DEFAULT_TIMEOUT_SECONDS = 600
STANDARD_TIMEOUT_CAP_SECONDS = 600
SMALL_FIX_TIMEOUT_SECONDS = 90
MAX_RECOMMENDED_TIMEOUT_SECONDS = 3600
HEALTH_LOCK_TIMEOUT_SECONDS = 5.0
HEALTH_LOCK_STALE_SECONDS = 30.0
RUNNER_ID = "tiers.external-agent/v1"
EVENT_RUNNER_ID = "tiers.external-agent-events/v1"


def _health_path() -> str:
    root = os.environ.get("DEV_WORKFLOW_DATA") or os.path.expanduser("~/.dev-workflow")
    return os.path.join(root, "external-agent-health.json")


def _load_health() -> dict:
    try:
        with open(_health_path(), encoding="utf-8") as handle:
            data = json.load(handle)
        if not isinstance(data, dict) or not isinstance(data.get("agents"), dict):
            raise ValueError("invalid health state")
        return data
    except (FileNotFoundError, OSError, ValueError, json.JSONDecodeError):
        return {"version": 1, "agents": {}}


def _write_health(data: dict) -> None:
    path = _health_path()
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        temporary = f"{path}.{os.getpid()}.tmp"
        with open(temporary, "w", encoding="utf-8") as handle:
            json.dump(data, handle, indent=2, ensure_ascii=False, sort_keys=True)
            handle.write("\n")
        os.replace(temporary, path)
    except OSError:
        # Health telemetry must never hide the underlying agent result.
        try:
            os.unlink(temporary)
        except (OSError, UnboundLocalError):
            pass


def _acquire_health_lock() -> Optional[str]:
    path = f"{_health_path()}.lock"
    deadline = time.monotonic() + HEALTH_LOCK_TIMEOUT_SECONDS
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
    except OSError:
        return None

    while True:
        try:
            os.mkdir(path)
            return path
        except FileExistsError:
            try:
                if time.time() - os.path.getmtime(path) > HEALTH_LOCK_STALE_SECONDS:
                    os.rmdir(path)
                    continue
            except (FileNotFoundError, OSError):
                pass
            if time.monotonic() >= deadline:
                return None
            time.sleep(0.01)
        except OSError:
            return None


def _release_health_lock(path: str) -> None:
    try:
        os.rmdir(path)
    except OSError:
        pass


def _health_entry(agent: str) -> dict:
    return _load_health().get("agents", {}).get(agent, {})


def _effective_timeout_details(agent: str, explicit_timeout: Optional[int],
                               review_profile: str = "standard") -> Tuple[int, str]:
    if explicit_timeout is not None:
        return explicit_timeout, "explicit"
    if review_profile == "small-fix":
        return SMALL_FIX_TIMEOUT_SECONDS, "profile"
    recommended = _health_entry(agent).get("recommended_timeout_seconds")
    if isinstance(recommended, int) and recommended > 0:
        bounded = min(recommended, STANDARD_TIMEOUT_CAP_SECONDS)
        source = "provider" if bounded == recommended else "provider_capped"
        return bounded, source
    return DEFAULT_TIMEOUT_SECONDS, "default"


def _effective_timeout(agent: str, explicit_timeout: Optional[int],
                       review_profile: str = "standard") -> int:
    return _effective_timeout_details(agent, explicit_timeout, review_profile)[0]


def _record_health(agent: str, event: str, timeout: int, duration: float,
                   error: str = "") -> None:
    lock_path = _acquire_health_lock()
    if lock_path is None:
        return
    try:
        data = _load_health()
        agents = data.setdefault("agents", {})
        entry = agents.setdefault(agent, {})
        entry.setdefault("timeout_count", 0)
        entry.setdefault("consecutive_timeouts", 0)
        entry.setdefault("failure_count", 0)
        entry.setdefault("consecutive_failures", 0)
        entry.setdefault("success_count", 0)

        entry["last_duration_seconds"] = round(duration, 3)
        entry["updated_at"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        if event == "timeout":
            entry["timeout_count"] += 1
            entry["consecutive_timeouts"] += 1
            entry["failure_count"] += 1
            entry["consecutive_failures"] += 1
            entry["last_timeout_seconds"] = timeout
            entry["recommended_timeout_seconds"] = min(
                MAX_RECOMMENDED_TIMEOUT_SECONDS,
                max(entry.get("recommended_timeout_seconds", 0), timeout * 2),
            )
            entry["status"] = "degraded" if entry["consecutive_failures"] >= 2 else "slow"
        elif event == "failure":
            entry["failure_count"] += 1
            entry["consecutive_failures"] += 1
            entry["consecutive_timeouts"] = 0
            if entry["consecutive_failures"] >= 2:
                entry["status"] = "degraded"
            else:
                entry.setdefault("status", "unknown")
        elif event == "success":
            entry["success_count"] += 1
            entry["consecutive_timeouts"] = 0
            entry["consecutive_failures"] = 0
            entry["status"] = "slow" if entry["timeout_count"] else "healthy"
        if error:
            entry["last_error"] = error[:1000]
        elif event == "success":
            entry.pop("last_error", None)
        _write_health(data)
    finally:
        _release_health_lock(lock_path)


def _health_metadata(agent: str) -> dict:
    entry = _health_entry(agent)
    status = entry.get("status", "unknown")
    has_failure_streak = entry.get("consecutive_failures", 0) > 0
    return {
        "health_status": status,
        "routing_priority": (
            "deprioritized" if status in ("slow", "degraded") or has_failure_streak else "normal"
        ),
        "recommended_timeout_seconds": entry.get(
            "recommended_timeout_seconds", DEFAULT_TIMEOUT_SECONDS),
        "timeout_count": entry.get("timeout_count", 0),
        "consecutive_timeouts": entry.get("consecutive_timeouts", 0),
        "consecutive_failures": entry.get("consecutive_failures", 0),
    }


# ----------------------------------------------------------------------------- parsers

def parse_codex(lines):
    msg, tid = "", None
    for ln in lines:
        try:
            d = json.loads(ln)
        except Exception:
            continue
        item = d.get("item", {})
        if item.get("type") == "agent_message":
            msg += item.get("text", "")
        if d.get("thread_id"):
            tid = d["thread_id"]
    return tid, msg


def parse_gemini(lines):
    msg, sid = "", None
    for ln in lines:
        try:
            d = json.loads(ln)
        except Exception:
            continue
        if d.get("role") == "assistant" and isinstance(d.get("content"), str):
            msg += d["content"]
        if d.get("session_id"):
            sid = d["session_id"]
    return sid, msg


def parse_mimo(lines):
    parts, order, sid = {}, [], None
    for ln in lines:
        try:
            d = json.loads(ln)
        except Exception:
            continue
        if d.get("sessionID"):
            sid = d["sessionID"]
        if d.get("type") == "text":
            p = d.get("part", {}) or {}
            pid = p.get("id", "")
            if pid not in parts:
                order.append(pid)
            parts[pid] = p.get("text", "")
    return sid, "".join(parts[p] for p in order)


# ----------------------------------------------------------------------------- git context

LOCAL_WORKFLOW_PATHS = [
    ":(exclude)docs/superpowers/.workflow-state.yaml",
    ":(exclude)docs/superpowers/.workflow-evidence/**",
]


def _git_output(repo: str, args: List[str]) -> str:
    result = subprocess.run(["git", "-C", repo] + args, capture_output=True,
                            text=True, encoding="utf-8", errors="replace")
    return (result.stdout or "").strip()


def _untracked_content_fingerprint(repo: str) -> str:
    result = subprocess.run(
        ["git", "-C", repo, "ls-files", "--others", "--exclude-standard", "-z",
         "--", "."] + LOCAL_WORKFLOW_PATHS,
        capture_output=True,
    )
    digest = hashlib.sha256()
    for raw_path in result.stdout.split(b"\0"):
        if not raw_path:
            continue
        digest.update(raw_path)
        digest.update(b"\0")
        path = os.path.join(repo, os.fsdecode(raw_path))
        try:
            if os.path.islink(path):
                digest.update(os.fsencode(os.readlink(path)))
            else:
                with open(path, "rb") as handle:
                    for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                        digest.update(chunk)
        except OSError:
            digest.update(b"(unreadable)")
        digest.update(b"\0")
    return digest.hexdigest()


def repository_fingerprint(repo: str) -> Optional[str]:
    if subprocess.run(["git", "-C", repo, "rev-parse", "--is-inside-work-tree"],
                      capture_output=True).returncode != 0:
        return None
    pathspec = ["--", "."] + LOCAL_WORKFLOW_PATHS
    parts = [
        _git_output(repo, ["rev-parse", "HEAD"]) or "(unborn)",
        _git_output(repo, ["symbolic-ref", "--quiet", "--short", "HEAD"]) or "(detached)",
        _git_output(repo, ["status", "--porcelain=v1", "--untracked-files=all"] + pathspec),
        _git_output(repo, ["diff", "--no-ext-diff", "--binary"] + pathspec),
        _git_output(repo, ["diff", "--cached", "--no-ext-diff", "--binary"] + pathspec),
        _untracked_content_fingerprint(repo),
    ]
    return hashlib.sha256("\0".join(parts).encode("utf-8")).hexdigest()

def git_context(repo: str, user_prompt: str) -> str:
    if subprocess.run(["git", "-C", repo, "rev-parse", "--is-inside-work-tree"],
                      capture_output=True).returncode != 0:
        return user_prompt
    out = ["## Repository Context", "",
           "Use the context below as shared task context, then answer the user request. "
           "Treat it as advisory and do not expose secrets.", ""]
    pathspec = ["--", "."] + LOCAL_WORKFLOW_PATHS
    for title, args in [
        ("git status --short --branch", ["status", "--short", "--branch"] + pathspec),
        ("git diff --stat", ["diff", "--stat"] + pathspec),
        ("git diff --name-only", ["diff", "--name-only"] + pathspec),
        ("git diff", ["diff", "--no-ext-diff"] + pathspec),
        ("git diff --cached --stat", ["diff", "--cached", "--stat"] + pathspec),
        ("git diff --cached --name-only", ["diff", "--cached", "--name-only"] + pathspec),
        ("git diff --cached", ["diff", "--cached", "--no-ext-diff"] + pathspec),
    ]:
        r = subprocess.run(["git", "-C", repo] + args, capture_output=True, text=True)
        out += [f"### {title}", (r.stdout or "").strip() or "(none)", ""]
    out += ["## User Request", "", user_prompt]
    return "\n".join(out)


# ----------------------------------------------------------------------------- main

def emit(args, success, sid, msg, error=""):
    if args.format == "json":
        r = {"success": success}
        if success:
            r["SESSION_ID"], r["agent_messages"] = sid, msg
        else:
            r["SESSION_ID"], r["error"] = sid, error
        print(json.dumps(r, indent=2, ensure_ascii=False))
    else:
        if success:
            print(msg)
        else:
            print(f"[external-agent error] {error}", file=sys.stderr)
    sys.exit(0 if success else 1)


def emit_cross_review(args, report):
    if args.format == "json":
        print(json.dumps(report, indent=2, ensure_ascii=False))
    else:
        print(f"artifact_sha256: {report['artifact_sha256']}")
        for reviewer in report["reviewers"]:
            status = "PASS" if reviewer["success"] else "FAIL"
            detail = reviewer.get("agent_messages") or reviewer.get("error") or ""
            print(f"[{status}] {reviewer['agent']} ({reviewer['family']}): {detail}")
        print(f"quorum: {'PASS' if report['quorum'] else 'FAIL'}")
        if report.get("error"):
            print(report["error"], file=sys.stderr)
    sys.exit(0 if report["success"] else 1)


class ProgressEmitter:
    """Thread-safe JSONL lifecycle output kept separate from final stdout."""

    def __init__(self, enabled: bool, review_profile: str) -> None:
        self.enabled = enabled
        self.review_profile = review_profile
        self._sequence = 0
        self._lock = threading.Lock()

    def emit(self, event: str, **fields) -> None:
        if not self.enabled:
            return
        with self._lock:
            self._sequence += 1
            payload = {
                "runner": EVENT_RUNNER_ID,
                "sequence": self._sequence,
                "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "event": event,
                "review_profile": self.review_profile,
                **fields,
            }
            sys.stderr.write(json.dumps(payload, ensure_ascii=False, sort_keys=True) + "\n")
            sys.stderr.flush()


def _terminate_process_group(proc: subprocess.Popen) -> None:
    if proc.poll() is not None:
        return
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except (AttributeError, ProcessLookupError, PermissionError):
        proc.terminate()
    try:
        proc.wait(timeout=1)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except (AttributeError, ProcessLookupError, PermissionError):
            proc.kill()
        proc.wait()


def _capture_interruptible(cmd: List[str], cwd: str, timeout: int,
                           input_text: str,
                           stop_event: threading.Event) -> Tuple[str, int, str, str]:
    """Capture a child runner while allowing a sibling success or user stop to cancel it."""
    proc = subprocess.Popen(
        cmd, cwd=cwd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, text=True, encoding="utf-8", errors="replace",
        start_new_session=True,
    )
    started = time.monotonic()
    pending_input: Optional[str] = input_text
    while True:
        if stop_event.is_set():
            _terminate_process_group(proc)
            out, err = proc.communicate()
            return "cancelled", proc.returncode or 1, out or "", err or ""
        remaining = timeout - (time.monotonic() - started)
        if remaining <= 0:
            _terminate_process_group(proc)
            raise subprocess.TimeoutExpired(cmd, timeout)
        try:
            out, err = proc.communicate(input=pending_input, timeout=min(0.1, remaining))
            return "completed", proc.returncode, out or "", err or ""
        except subprocess.TimeoutExpired:
            pending_input = None


def _cross_review_one(args, prompt: str, name: str,
                      stop_event: threading.Event,
                      progress: ProgressEmitter) -> dict:
    spec = AGENTS[name]
    timeout, timeout_source = _effective_timeout_details(
        name, args.timeout, args.review_profile)
    reviewer = {
        "agent": name,
        "family": spec["family"],
        "success": False,
        "status": "failed",
        "timeout_seconds": timeout,
        "timeout_source": timeout_source,
    }
    progress.emit(
        "review_started",
        agent=name,
        family=spec["family"],
        timeout_seconds=timeout,
        timeout_source=timeout_source,
    )
    started = time.monotonic()
    cmd = [
        sys.executable, os.path.abspath(__file__),
        "--agent", name,
        "--cd", args.cd,
        "--mode", "review",
        "--format", "json",
        "--context", "none",
        "--timeout", str(timeout),
    ]
    if not args.skip_perm:
        cmd.append("--require-permissions")
    try:
        capture_status, rc, out, err = _capture_interruptible(
            cmd, args.cd, timeout + 5, prompt, stop_event)
        if capture_status == "cancelled":
            reviewer["status"] = "cancelled"
            reviewer["error"] = "stopped after small-fix policy was satisfied"
            return reviewer
        data = json.loads(out) if out.strip() else {}
    except subprocess.TimeoutExpired:
        reviewer["status"] = "timeout"
        reviewer["error"] = f"{name} timed out after {timeout}s"
        _record_health(name, "timeout", timeout, timeout, reviewer["error"])
    except json.JSONDecodeError:
        reviewer["error"] = f"could not parse {name} result: {out[:400]}"
    else:
        message = data.get("agent_messages") or ""
        success = rc == 0 and data.get("success") is True and bool(message.strip())
        reviewer["success"] = success
        reviewer["SESSION_ID"] = data.get("SESSION_ID")
        if success:
            reviewer["status"] = "success"
            reviewer["agent_messages"] = message
        else:
            error = data.get("error") or err.strip() or f"{name} returned no valid review"
            reviewer["status"] = "timeout" if "timed out after" in error else "failed"
            reviewer["error"] = error
    finally:
        reviewer["duration_seconds"] = round(time.monotonic() - started, 3)
        progress.emit(
            "review_finished",
            agent=name,
            family=spec["family"],
            status=reviewer["status"],
            success=reviewer["success"],
            timeout_seconds=timeout,
            timeout_source=timeout_source,
            duration_seconds=reviewer["duration_seconds"],
            **({"error": reviewer["error"]} if reviewer.get("error") else {}),
        )
    return reviewer


def _finish_cross_review(report: dict, started: float) -> None:
    report["finished_at"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    report["duration_seconds"] = round(time.monotonic() - started, 3)


def cross_review(args, prompt):
    started = time.monotonic()
    artifact_sha256 = hashlib.sha256(prompt.encode("utf-8")).hexdigest()
    repo_fingerprint = repository_fingerprint(args.cd) if args.context == "git" else None
    small_fix = args.review_profile == "small-fix"
    progress = ProgressEmitter(args.progress == "jsonl", args.review_profile)
    report = {
        "runner": RUNNER_ID,
        "success": False,
        "quorum": False,
        "outcome": "failed",
        "review_profile": args.review_profile,
        "policy": {
            "minimum_successes": 1 if small_fix else 2,
            "minimum_families": 1 if small_fix else 2,
            "stop_after_policy": small_fix,
        },
        "artifact_sha256": artifact_sha256,
        "repository_fingerprint": repo_fingerprint,
        "created_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "successful_families": [],
        "reviewers": [],
    }

    def fail(message: str) -> None:
        report["error"] = message
        _finish_cross_review(report, started)
        progress.emit(
            "cross_review_finished",
            success=False,
            quorum=False,
            outcome=report["outcome"],
            duration_seconds=report["duration_seconds"],
            error=message,
        )
        emit_cross_review(args, report)

    if args.context == "git" and not repo_fingerprint:
        fail("--context git requires a Git worktree for repository binding")

    requested = [part.strip() for part in args.cross_review.split(",") if part.strip()]
    normalized = [ALIASES.get(name, name) for name in requested]
    if len(normalized) < 2:
        fail("cross-review requires at least two agents")
    if len(set(normalized)) != len(normalized):
        fail("cross-review agents must be distinct after alias normalization")

    unknown = [name for name in normalized if name not in AGENTS]
    if unknown:
        fail(f"unknown cross-review agents: {', '.join(unknown)}")

    selected_families = {AGENTS[name]["family"] for name in normalized}
    if len(selected_families) < 2:
        fail("cross-review requires agents from at least two families")

    progress.emit(
        "cross_review_started",
        agents=normalized,
        families=sorted(selected_families),
        policy=report["policy"],
    )

    stop_event = threading.Event()
    executor = concurrent.futures.ThreadPoolExecutor(max_workers=len(normalized))
    futures = {
        executor.submit(_cross_review_one, args, prompt, name, stop_event, progress): name
        for name in normalized
    }
    results = {}
    interrupted = False
    policy_event_emitted = False
    previous_sigint = signal.getsignal(signal.SIGINT)
    previous_sigterm = signal.getsignal(signal.SIGTERM)

    def interrupt_review(_signum, _frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGINT, interrupt_review)
    signal.signal(signal.SIGTERM, interrupt_review)
    try:
        for future in concurrent.futures.as_completed(futures):
            name = futures[future]
            try:
                reviewer = future.result()
            except Exception as exc:
                timeout, timeout_source = _effective_timeout_details(
                    name, args.timeout, args.review_profile)
                reviewer = {
                    "agent": name, "family": AGENTS[name]["family"],
                    "success": False, "status": "failed",
                    "timeout_seconds": timeout,
                    "timeout_source": timeout_source,
                    "duration_seconds": 0.0, "error": str(exc),
                }
            results[reviewer["agent"]] = reviewer
            completed_successes = [item for item in results.values() if item["success"]]
            completed_families = {item["family"] for item in completed_successes}
            policy_satisfied = (
                bool(completed_successes) if small_fix
                else len(completed_successes) >= 2 and len(completed_families) >= 2
            )
            if policy_satisfied and not policy_event_emitted:
                policy_event_emitted = True
                progress.emit(
                    "policy_satisfied",
                    successful_agents=[item["agent"] for item in completed_successes],
                    successful_families=sorted(completed_families),
                    quorum=not small_fix,
                )
            if small_fix and reviewer["success"]:
                stop_event.set()
    except KeyboardInterrupt:
        interrupted = True
        stop_event.set()
        progress.emit("cross_review_terminated", reason="user_interrupt")
    finally:
        executor.shutdown(wait=True, cancel_futures=True)
        signal.signal(signal.SIGINT, previous_sigint)
        signal.signal(signal.SIGTERM, previous_sigterm)

    for future, name in futures.items():
        if name in results:
            continue
        if future.done() and not future.cancelled():
            try:
                results[name] = future.result()
            except Exception as exc:  # Preserve evidence instead of hiding worker failures.
                timeout, timeout_source = _effective_timeout_details(
                    name, args.timeout, args.review_profile)
                results[name] = {
                    "agent": name, "family": AGENTS[name]["family"],
                    "success": False, "status": "failed",
                    "timeout_seconds": timeout,
                    "timeout_source": timeout_source,
                    "duration_seconds": 0.0, "error": str(exc),
                }
        else:
            timeout, timeout_source = _effective_timeout_details(
                name, args.timeout, args.review_profile)
            results[name] = {
                "agent": name, "family": AGENTS[name]["family"],
                "success": False, "status": "cancelled",
                "timeout_seconds": timeout,
                "timeout_source": timeout_source,
                "duration_seconds": 0.0,
                "error": "review terminated before completion",
            }
    report["reviewers"] = [results[name] for name in normalized]

    successful = [reviewer for reviewer in report["reviewers"] if reviewer["success"]]
    families = sorted({reviewer["family"] for reviewer in successful})
    report["successful_families"] = families
    report["quorum"] = len(successful) >= 2 and len(families) >= 2
    if interrupted:
        report["outcome"] = "terminated"
        report["termination_reason"] = "user_interrupt"
        report["error"] = "cross-review terminated by user"
    elif report["quorum"]:
        report["success"] = True
        report["outcome"] = "quorum"
    elif small_fix and successful:
        report["success"] = True
        report["outcome"] = "degraded"
    else:
        report["error"] = "cross-review quorum not met: need two successful distinct families"
    _finish_cross_review(report, started)
    progress.emit(
        "cross_review_finished",
        success=report["success"],
        quorum=report["quorum"],
        outcome=report["outcome"],
        duration_seconds=report["duration_seconds"],
    )
    emit_cross_review(args, report)


def main():
    ap = argparse.ArgumentParser(description="Unified external-agent runner")
    ap.add_argument("--agent", help="codex|gemini|mimo|cursor|grok|antigravity")
    ap.add_argument("--cross-review", default="", help="Comma-separated read-only reviewers.")
    ap.add_argument("--cd", default=os.getcwd(), help="Workspace root.")
    ap.add_argument("--PROMPT", default="", help="Prompt (or pass on stdin).")
    ap.add_argument("--mode", choices=["review", "delegate"], default="review")
    ap.add_argument("--format", choices=["text", "json"], default="text")
    ap.add_argument("--context", choices=["none", "git"], default="none")
    ap.add_argument("--SESSION_ID", default="")
    ap.add_argument("--model", default="", help="Strictly prohibited unless the user specifies it.")
    ap.add_argument("--require-permissions", dest="skip_perm", action="store_false", default=True,
                    help="Do not auto-skip permission prompts (headless has no TTY; may hang).")
    ap.add_argument("--timeout", type=int, default=None,
                    help="Per-agent timeout; standard uses provider recommendation/600s, small-fix uses 90s.")
    ap.add_argument("--review-profile", choices=["standard", "small-fix"],
                    default="standard",
                    help="Cross-review policy; small-fix defaults to 90s and one-success degradation.")
    ap.add_argument("--progress", choices=["jsonl", "none"], default="jsonl",
                    help="Cross-review lifecycle events on stderr; final report remains on stdout.")
    ap.add_argument("--list", action="store_true", help="List installed agents and exit.")
    ap.add_argument("--fingerprint", action="store_true",
                    help="Print the current reviewable Git snapshot SHA-256 and exit.")
    args = ap.parse_args()

    if args.fingerprint:
        fingerprint = repository_fingerprint(args.cd)
        if not fingerprint:
            print("not a Git worktree", file=sys.stderr)
            sys.exit(1)
        print(fingerprint)
        return

    if args.list:
        rows = []
        for name, spec in AGENTS.items():
            path = shutil.which(spec["bin"])
            row = {"agent": name, "bin": spec["bin"],
                   "installed": bool(path), "path": path,
                   "resume": spec["resume"], "family": spec["family"]}
            row.update(_health_metadata(name))
            rows.append(row)
        print(json.dumps(rows, indent=2, ensure_ascii=False))
        return

    if args.cross_review and args.agent:
        report = {"success": False, "quorum": False, "artifact_sha256": "",
                  "successful_families": [], "reviewers": [],
                  "error": "use either --agent or --cross-review, not both"}
        emit_cross_review(args, report)
    if args.cross_review and args.mode != "review":
        report = {"success": False, "quorum": False, "artifact_sha256": "",
                  "successful_families": [], "reviewers": [],
                  "error": "cross-review is read-only; --mode must be review"}
        emit_cross_review(args, report)

    prompt = args.PROMPT or sys.stdin.read()
    if not prompt.strip():
        emit(args, False, None, "", "prompt must not be empty")
    if args.context == "git":
        prompt = git_context(args.cd, prompt)
    if args.cross_review:
        if args.SESSION_ID:
            report = {"success": False, "quorum": False,
                      "artifact_sha256": hashlib.sha256(prompt.encode("utf-8")).hexdigest(),
                      "successful_families": [], "reviewers": [],
                      "error": "cross-review does not support --SESSION_ID"}
            emit_cross_review(args, report)
        cross_review(args, prompt)

    name = ALIASES.get(args.agent, args.agent)
    if name not in AGENTS:
        emit(args, False, None, "", f"unknown agent: {args.agent} (expected {', '.join(AGENTS)})")
    spec = AGENTS[name]
    if not shutil.which(spec["bin"]):
        emit(args, False, None, "", f"{spec['bin']} not found on PATH. Install it and log in.")
    if args.SESSION_ID and not spec["resume"]:
        emit(args, False, None, "", f"agent {name} does not support multi-turn resume")

    argv, kind, sentinel = spec["build"](prompt, args.cd, args.mode, args.SESSION_ID,
                                         args.model, args.skip_perm)
    timeout = _effective_timeout(name, args.timeout)
    started = time.monotonic()

    if kind == "raw":
        try:
            rc, out, err = _capture(argv, args.cd, timeout)
        except FileNotFoundError:
            emit(args, False, None, "", f"{spec['bin']} not found")
        except subprocess.TimeoutExpired:
            error = f"{name} timed out after {timeout}s"
            _record_health(name, "timeout", timeout, time.monotonic() - started, error)
            emit(args, False, None, "", error)
        out = out.strip()
        if rc != 0 or not out:
            error = f"{name} failed (rc={rc}): {err.strip() or out}"
            _record_health(name, "failure", timeout, time.monotonic() - started, error)
            emit(args, False, None, "", error)
        _record_health(name, "success", timeout, time.monotonic() - started)
        emit(args, True, None, out)

    if kind in ("cursor", "grok"):
        try:
            rc, out, err = _capture(argv, args.cd, timeout)
        except subprocess.TimeoutExpired:
            error = f"{name} timed out after {timeout}s"
            _record_health(name, "timeout", timeout, time.monotonic() - started, error)
            emit(args, False, None, "", error)
        out = out.strip()
        if not out:
            error = f"empty output from {name}: {err.strip()}"
            _record_health(name, "failure", timeout, time.monotonic() - started, error)
            emit(args, False, None, "", error)
        try:
            d = json.loads(out)
        except json.JSONDecodeError:
            error = f"could not parse {name} JSON: {out[:800]}"
            _record_health(name, "failure", timeout, time.monotonic() - started, error)
            emit(args, False, None, "", error)
        if kind == "cursor":
            sid, msg = d.get("session_id"), d.get("result", "") or ""
            bad = bool(d.get("is_error")) or d.get("subtype") not in (None, "success")
        else:
            sid, msg = d.get("sessionId"), d.get("text", "") or ""
            bad = d.get("stopReason") not in (None, "", "EndTurn", "Stop", "stop", "end_turn")
        if bad or not msg or not sid:
            error = f"{name} reported no clean result"
            _record_health(name, "failure", timeout, time.monotonic() - started, error)
            emit(args, False, sid, "", error)
        _record_health(name, "success", timeout, time.monotonic() - started)
        emit(args, True, sid, msg)

    # streaming kinds: codex / gemini / mimo
    try:
        lines = list(_stream(argv, args.cd, sentinel, timeout))
    except subprocess.TimeoutExpired:
        error = f"{name} timed out after {timeout}s"
        _record_health(name, "timeout", timeout, time.monotonic() - started, error)
        emit(args, False, None, "", error)
    sid, msg = {"codex": parse_codex, "gemini": parse_gemini, "mimo": parse_mimo}[kind](lines)
    if not sid or not msg:
        error = (f"{name}: missing session id or empty reply "
                 f"(tool call only?). Lines: {len(lines)}")
        _record_health(name, "failure", timeout, time.monotonic() - started, error)
        emit(args, False, sid, "", error)
    _record_health(name, "success", timeout, time.monotonic() - started)
    emit(args, True, sid, msg)


if __name__ == "__main__":
    main()
