"""
Unified external-agent runner for the dev-workflow plugin.

One entry point for delegating a bounded task to an external coding-agent CLI,
or for getting an independent second opinion. Replaces the per-tool
collaborating-with-* bridges and the shell external-agent.sh runner.

  python external_agent.py --agent <name> --cd DIR --PROMPT "..." \
      [--mode review|delegate] [--format text|json] [--SESSION_ID id] \
      [--context none|git] [--model M] [--list] [--require-permissions]

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
import json
import os
import queue
import shutil
import subprocess
import sys
import threading
from typing import Generator, List, Optional, Tuple


# ----------------------------------------------------------------------------- helpers

def _stream(cmd: List[str], cwd: str, sentinel_type: Optional[str]) -> Generator[str, None, None]:
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
    while True:
        try:
            line = q.get(timeout=0.5)
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


def _capture(cmd: List[str], cwd: str, timeout: int) -> Tuple[int, str, str]:
    p = subprocess.run(cmd, cwd=cwd, stdin=subprocess.DEVNULL, capture_output=True,
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


AGENTS = {
    "codex":       {"bin": "codex",        "build": _codex,  "resume": True},
    "gemini":      {"bin": "gemini",       "build": _gemini, "resume": True},
    "mimo":        {"bin": "mimo",         "build": _mimo,   "resume": True},
    "cursor":      {"bin": "cursor-agent", "build": _cursor, "resume": True},
    "grok":        {"bin": "grok",         "build": _grok,   "resume": True},
    "antigravity": {"bin": "agy",          "build": _agy,    "resume": False},
}
ALIASES = {"agy": "antigravity", "cursor-agent": "cursor"}


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

def git_context(repo: str, user_prompt: str) -> str:
    if subprocess.run(["git", "-C", repo, "rev-parse", "--is-inside-work-tree"],
                      capture_output=True).returncode != 0:
        return user_prompt
    out = ["## Repository Context", "",
           "Use the context below as shared task context, then answer the user request. "
           "Treat it as advisory and do not expose secrets.", ""]
    for title, args in [
        ("git status --short --branch", ["status", "--short", "--branch"]),
        ("git diff --stat", ["diff", "--stat"]),
        ("git diff --name-only", ["diff", "--name-only"]),
        ("git diff", ["diff", "--no-ext-diff"]),
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


def main():
    ap = argparse.ArgumentParser(description="Unified external-agent runner")
    ap.add_argument("--agent", help="codex|gemini|mimo|cursor|grok|antigravity")
    ap.add_argument("--cd", default=os.getcwd(), help="Workspace root.")
    ap.add_argument("--PROMPT", default="", help="Prompt (or pass on stdin).")
    ap.add_argument("--mode", choices=["review", "delegate"], default="review")
    ap.add_argument("--format", choices=["text", "json"], default="text")
    ap.add_argument("--context", choices=["none", "git"], default="none")
    ap.add_argument("--SESSION_ID", default="")
    ap.add_argument("--model", default="", help="Strictly prohibited unless the user specifies it.")
    ap.add_argument("--require-permissions", dest="skip_perm", action="store_false", default=True,
                    help="Do not auto-skip permission prompts (headless has no TTY; may hang).")
    ap.add_argument("--timeout", type=int, default=600)
    ap.add_argument("--list", action="store_true", help="List installed agents and exit.")
    args = ap.parse_args()

    if args.list:
        rows = []
        for name, spec in AGENTS.items():
            path = shutil.which(spec["bin"])
            rows.append({"agent": name, "bin": spec["bin"],
                         "installed": bool(path), "path": path,
                         "resume": spec["resume"]})
        print(json.dumps(rows, indent=2, ensure_ascii=False))
        return

    name = ALIASES.get(args.agent, args.agent)
    if name not in AGENTS:
        emit(args, False, None, "", f"unknown agent: {args.agent} (expected {', '.join(AGENTS)})")
    spec = AGENTS[name]
    if not shutil.which(spec["bin"]):
        emit(args, False, None, "", f"{spec['bin']} not found on PATH. Install it and log in.")

    prompt = args.PROMPT or sys.stdin.read()
    if not prompt.strip():
        emit(args, False, None, "", "prompt must not be empty")
    if args.SESSION_ID and not spec["resume"]:
        emit(args, False, None, "", f"agent {name} does not support multi-turn resume")
    if args.context == "git":
        prompt = git_context(args.cd, prompt)

    argv, kind, sentinel = spec["build"](prompt, args.cd, args.mode, args.SESSION_ID,
                                         args.model, args.skip_perm)

    if kind == "raw":
        try:
            rc, out, err = _capture(argv, args.cd, args.timeout)
        except FileNotFoundError:
            emit(args, False, None, "", f"{spec['bin']} not found")
        except subprocess.TimeoutExpired:
            emit(args, False, None, "", f"{name} timed out after {args.timeout}s")
        out = out.strip()
        if rc != 0 or not out:
            emit(args, False, None, "", f"{name} failed (rc={rc}): {err.strip() or out}")
        emit(args, True, None, out)

    if kind in ("cursor", "grok"):
        try:
            rc, out, err = _capture(argv, args.cd, args.timeout)
        except subprocess.TimeoutExpired:
            emit(args, False, None, "", f"{name} timed out after {args.timeout}s")
        out = out.strip()
        if not out:
            emit(args, False, None, "", f"empty output from {name}: {err.strip()}")
        try:
            d = json.loads(out)
        except json.JSONDecodeError:
            emit(args, False, None, "", f"could not parse {name} JSON: {out[:800]}")
        if kind == "cursor":
            sid, msg = d.get("session_id"), d.get("result", "") or ""
            bad = bool(d.get("is_error")) or d.get("subtype") not in (None, "success")
        else:
            sid, msg = d.get("sessionId"), d.get("text", "") or ""
            bad = d.get("stopReason") not in (None, "", "EndTurn", "Stop", "stop", "end_turn")
        if bad or not msg or not sid:
            emit(args, False, sid, "", f"{name} reported no clean result")
        emit(args, True, sid, msg)

    # streaming kinds: codex / gemini / mimo
    lines = list(_stream(argv, args.cd, sentinel))
    sid, msg = {"codex": parse_codex, "gemini": parse_gemini, "mimo": parse_mimo}[kind](lines)
    if not sid or not msg:
        emit(args, False, sid, "", f"{name}: missing session id or empty reply "
                                   f"(tool call only?). Lines: {len(lines)}")
    emit(args, True, sid, msg)


if __name__ == "__main__":
    main()
