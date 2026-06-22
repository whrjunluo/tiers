"""
Grok Bridge for Claude Agent Skills.
Wraps the Grok CLI (`grok -p --output-format json`) and returns a uniform JSON
interface for Claude.

`grok -p "<prompt>" --output-format json` prints a single JSON object, e.g.:
  {"text":"pong","stopReason":"EndTurn","sessionId":"<uuid>",
   "requestId":"...","thought":"..."}
"""
from __future__ import annotations

import argparse
import json
import subprocess


def main() -> None:
    parser = argparse.ArgumentParser(description="Grok Bridge")
    parser.add_argument("--PROMPT", required=True, help="Instruction to send to grok.")
    parser.add_argument("--cd", required=True, help="Workspace root (grok `--cwd`).")
    parser.add_argument("--SESSION_ID", default="", help="Resume a session (grok `--resume <id>`). Empty starts a new session.")
    parser.add_argument("--return-all-messages", action="store_true", help="Include the full raw object (incl. `thought`) in output.")
    parser.add_argument("--model", default="", help="Model ID to use. Strictly prohibited unless explicitly specified by the user.")
    parser.add_argument("--require-permissions", dest="bypass", action="store_false", default=True,
                        help="Use the default permission mode instead of bypass. By default the bridge passes `--permission-mode bypassPermissions` because headless runs have no TTY to approve prompts.")
    parser.add_argument("--timeout", type=int, default=600, help="Seconds before giving up on the CLI. Default 600.")
    args = parser.parse_args()

    cmd = ["grok", "-p", args.PROMPT, "--output-format", "json", "--cwd", args.cd]
    if args.bypass:
        cmd.extend(["--permission-mode", "bypassPermissions"])
    if args.model:
        cmd.extend(["--model", args.model])
    if args.SESSION_ID:
        cmd.extend(["--resume", args.SESSION_ID])

    try:
        proc = subprocess.run(
            cmd, cwd=args.cd, stdin=subprocess.DEVNULL,
            capture_output=True, text=True, encoding="utf-8", errors="replace",
            timeout=args.timeout,
        )
    except FileNotFoundError:
        print(json.dumps({"success": False, "error": "grok not found on PATH."})); return
    except subprocess.TimeoutExpired:
        print(json.dumps({"success": False, "error": f"grok timed out after {args.timeout}s."})); return

    out = (proc.stdout or "").strip()
    if not out:
        print(json.dumps({"success": False, "error": f"empty output from grok.\n{(proc.stderr or '').strip()}"}, ensure_ascii=False))
        return

    try:
        data = json.loads(out)
    except json.JSONDecodeError:
        print(json.dumps({"success": False, "error": f"could not parse grok JSON.\n{out[:2000]}"}, ensure_ascii=False))
        return

    session_id = data.get("sessionId")
    agent_messages = data.get("text", "") or ""
    stop = data.get("stopReason", "")
    # Treat anything other than a clean end as a failure signal.
    bad_stop = stop not in ("", "EndTurn", "Stop", "stop", "end_turn")

    if bad_stop or not agent_messages or not session_id:
        result = {"success": False, "SESSION_ID": session_id,
                  "error": f"grok stopReason={stop!r}; text={agent_messages[:200]!r}"}
    else:
        result = {"success": True, "SESSION_ID": session_id, "agent_messages": agent_messages}

    if args.return_all_messages:
        result["all_messages"] = data

    print(json.dumps(result, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
