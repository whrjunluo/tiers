"""
MiMo Bridge Script for Claude Agent Skills.
Wraps the MiMoCode CLI (`mimo run`) to provide a JSON-based interface for Claude.
"""
from __future__ import annotations

import json
import os
import sys
import queue
import subprocess
import threading
import shutil
import argparse
from pathlib import Path
from typing import Generator, List, Optional


def _get_windows_npm_paths() -> List[Path]:
    """Return candidate directories for npm global installs on Windows."""
    if os.name != "nt":
        return []
    paths: List[Path] = []
    env = os.environ
    if prefix := env.get("NPM_CONFIG_PREFIX") or env.get("npm_config_prefix"):
        paths.append(Path(prefix))
    if appdata := env.get("APPDATA"):
        paths.append(Path(appdata) / "npm")
    if localappdata := env.get("LOCALAPPDATA"):
        paths.append(Path(localappdata) / "npm")
    if programfiles := env.get("ProgramFiles"):
        paths.append(Path(programfiles) / "nodejs")
    return paths


def _augment_path_env(env: dict) -> None:
    """Prepend npm global directories to PATH if missing."""
    if os.name != "nt":
        return
    path_key = next((k for k in env if k.upper() == "PATH"), "PATH")
    path_entries = [p for p in env.get(path_key, "").split(os.pathsep) if p]
    lower_set = {p.lower() for p in path_entries}
    for candidate in _get_windows_npm_paths():
        if candidate.is_dir() and str(candidate).lower() not in lower_set:
            path_entries.insert(0, str(candidate))
            lower_set.add(str(candidate).lower())
    env[path_key] = os.pathsep.join(path_entries)


def _resolve_executable(name: str, env: dict) -> str:
    """Resolve executable path, checking npm directories for .cmd/.bat on Windows."""
    if os.path.isabs(name) or os.sep in name or (os.altsep and os.altsep in name):
        return name
    path_key = next((k for k in env if k.upper() == "PATH"), "PATH")
    path_val = env.get(path_key)
    win_exts = {".exe", ".cmd", ".bat", ".com"}
    if resolved := shutil.which(name, path=path_val):
        if os.name == "nt":
            suffix = Path(resolved).suffix.lower()
            if not suffix:
                resolved_dir = str(Path(resolved).parent)
                for ext in (".cmd", ".bat", ".exe", ".com"):
                    candidate = Path(resolved_dir) / f"{name}{ext}"
                    if candidate.is_file():
                        return str(candidate)
            elif suffix not in win_exts:
                return resolved
        return resolved
    if os.name == "nt":
        for base in _get_windows_npm_paths():
            for ext in (".cmd", ".bat", ".exe", ".com"):
                candidate = base / f"{name}{ext}"
                if candidate.is_file():
                    return str(candidate)
    return name


def run_shell_command(cmd: List[str]) -> Generator[str, None, None]:
    """Execute a command and stream its output line-by-line until the process exits.

    Unlike the codex bridge we do NOT force-terminate on a sentinel event:
    `mimo run` exits cleanly once the turn completes, so we simply read to EOF.
    """
    env = os.environ.copy()
    _augment_path_env(env)

    popen_cmd = cmd.copy()
    exe_path = _resolve_executable(cmd[0], env)
    popen_cmd[0] = exe_path

    # Windows .cmd/.bat files need cmd.exe wrapper (avoid shell=True for security)
    if os.name == "nt" and Path(exe_path).suffix.lower() in {".cmd", ".bat"}:
        def _cmd_quote(arg: str) -> str:
            if not arg:
                return '""'
            arg = arg.replace('%', '%%')
            arg = arg.replace('^', '^^')
            if any(c in arg for c in '&|<>()^" \t'):
                escaped = arg.replace('"', '"^""')
                return f'"{escaped}"'
            return arg
        cmdline = " ".join(_cmd_quote(a) for a in popen_cmd)
        comspec = env.get("COMSPEC", "cmd.exe")
        popen_cmd = f'"{comspec}" /d /s /c "{cmdline}"'

    process = subprocess.Popen(
        popen_cmd,
        shell=False,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        universal_newlines=True,
        encoding='utf-8',
        errors='replace',
        env=env,
    )

    output_queue: queue.Queue[Optional[str]] = queue.Queue()

    def read_output() -> None:
        if process.stdout:
            for line in iter(process.stdout.readline, ""):
                output_queue.put(line.strip())
            process.stdout.close()
        output_queue.put(None)

    thread = threading.Thread(target=read_output)
    thread.start()

    while True:
        try:
            line = output_queue.get(timeout=0.5)
            if line is None:
                break
            yield line
        except queue.Empty:
            if process.poll() is not None and not thread.is_alive():
                break

    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()
    thread.join(timeout=5)

    while not output_queue.empty():
        try:
            line = output_queue.get_nowait()
            if line is not None:
                yield line
        except queue.Empty:
            break


def windows_escape(prompt: str) -> str:
    """Windows style string escaping for newlines and special chars in prompt text."""
    return prompt.replace('\n', '\\n').replace('\r', '\\r').replace('\t', '\\t')


def configure_windows_stdio() -> None:
    """Configure stdout/stderr to use UTF-8 encoding on Windows."""
    if os.name != "nt":
        return
    for stream in (sys.stdout, sys.stderr):
        reconfigure = getattr(stream, "reconfigure", None)
        if callable(reconfigure):
            try:
                reconfigure(encoding="utf-8")
            except (ValueError, OSError):
                pass


def main():
    configure_windows_stdio()
    parser = argparse.ArgumentParser(description="MiMo Bridge")
    parser.add_argument("--PROMPT", required=True, help="Instruction for the task to send to mimo.")
    parser.add_argument("--cd", required=True, help="Set the workspace root for mimo before executing the task (maps to `--dir`).")
    parser.add_argument("--SESSION_ID", default="", help="Resume the specified session of mimo. Defaults to empty, start a new session.")
    parser.add_argument("--fork", action="store_true", help="Fork the session before continuing (requires --SESSION_ID).")
    parser.add_argument("--return-all-messages", action="store_true", help="Return all NDJSON events (reasoning, tool calls, etc.). Off by default; only the agent's final text reply is returned.")
    parser.add_argument("--file", action="append", default=[], help="Attach one or more files to the prompt. Repeat the flag for multiple files.")
    parser.add_argument("--model", default="", help="Model to use, in `provider/model` form (e.g. xiaomi/mimo-v2.5-pro). Strictly prohibited unless explicitly specified by the user.")
    parser.add_argument("--agent", default="", help="Agent to use. Strictly prohibited unless explicitly specified by the user.")
    parser.add_argument("--require-permissions", dest="skip_permissions", action="store_false", default=True,
                        help="Re-enable interactive permission prompts. WARNING: headless `mimo run` has no TTY and will hang on a prompt; only use when you can supply approvals another way.")

    args = parser.parse_args()

    cmd = ["mimo", "run", "--format", "json", "--dir", args.cd]

    if args.skip_permissions:
        cmd.append("--dangerously-skip-permissions")

    if args.model:
        cmd.extend(["--model", args.model])

    if args.agent:
        cmd.extend(["--agent", args.agent])

    if args.SESSION_ID:
        cmd.extend(["--session", args.SESSION_ID])
        if args.fork:
            cmd.append("--fork")

    for f in args.file:
        cmd.extend(["--file", f])

    PROMPT = windows_escape(args.PROMPT) if os.name == "nt" else args.PROMPT
    cmd.append(PROMPT)

    # Execution Logic
    all_messages = []
    text_parts: dict[str, str] = {}   # part.id -> latest text (cumulative per part)
    text_order: List[str] = []        # preserve first-seen order of text part ids
    session_id: Optional[str] = None
    success = True
    err_message = ""

    for line in run_shell_command(cmd):
        if not line:
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            err_message += "\n\n[json decode error] " + line
            continue

        all_messages.append(event)

        if event.get("sessionID"):
            session_id = event.get("sessionID")

        etype = event.get("type", "")

        if etype == "text":
            part = event.get("part", {}) or {}
            pid = part.get("id", "")
            text = part.get("text", "")
            if pid not in text_parts:
                text_order.append(pid)
            text_parts[pid] = text  # later events for same part carry the fuller text

        elif etype == "error":
            error = event.get("error", {}) or {}
            data = error.get("data", {}) or {}
            msg = data.get("message") or error.get("message") or error.get("name") or json.dumps(error, ensure_ascii=False)
            err_message += "\n\n[mimo error] " + str(msg)
            success = False if not text_parts else success

    agent_messages = "".join(text_parts[pid] for pid in text_order)

    if session_id is None:
        success = False
        err_message = "Failed to get `SESSION_ID` from the mimo session. \n\n" + err_message

    if len(agent_messages) == 0:
        success = False
        err_message = "Failed to get `agent_messages` from the mimo session. \n\n You can set `--return-all-messages` to inspect the full event stream. " + err_message

    if success:
        result = {
            "success": True,
            "SESSION_ID": session_id,
            "agent_messages": agent_messages,
        }
    else:
        result = {"success": False, "error": err_message.strip(), "SESSION_ID": session_id}

    if args.return_all_messages:
        result["all_messages"] = all_messages

    print(json.dumps(result, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
