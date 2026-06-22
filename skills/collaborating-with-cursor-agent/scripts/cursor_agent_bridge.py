"""
Cursor Agent Bridge for Claude Agent Skills.
Wraps the Cursor Agent CLI (`cursor-agent -p --output-format json`) and returns a
uniform JSON interface for Claude.

`cursor-agent -p --output-format json` prints a single JSON object on success, e.g.:
  {"type":"result","subtype":"success","is_error":false,"result":"pong",
   "session_id":"<uuid>","request_id":"...","usage":{...}}
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys


def main() -> None:
    parser = argparse.ArgumentParser(description="Cursor Agent Bridge")
    parser.add_argument("--PROMPT", required=True, help="Instruction to send to cursor-agent.")
    parser.add_argument("--cd", required=True, help="Workspace root; the agent runs with this as its working directory.")
    parser.add_argument("--SESSION_ID", default="", help="Resume a previous chat (cursor `--resume <chatId>`). Empty starts a new session.")
    parser.add_argument("--return-all-messages", action="store_true", help="Include the full raw result object in output.")
    parser.add_argument("--model", default="", help="Model to use (e.g. gpt-5, sonnet-4-thinking). Strictly prohibited unless explicitly specified by the user.")
    parser.add_argument("--require-permissions", dest="force", action="store_false", default=True,
                        help="Re-enable tool-permission prompts. By default the bridge passes `--force` because headless runs have no TTY to approve prompts.")
    parser.add_argument("--timeout", type=int, default=600, help="Seconds before giving up on the CLI. Default 600.")
    args = parser.parse_args()

    cmd = ["cursor-agent", "-p", "--output-format", "json"]
    if args.force:
        cmd.append("--force")
    if args.model:
        cmd.extend(["--model", args.model])
    if args.SESSION_ID:
        cmd.extend(["--resume", args.SESSION_ID])
    cmd.append(args.PROMPT)

    try:
        proc = subprocess.run(
            cmd, cwd=args.cd, stdin=subprocess.DEVNULL,
            capture_output=True, text=True, encoding="utf-8", errors="replace",
            timeout=args.timeout,
        )
    except FileNotFoundError:
        print(json.dumps({"success": False, "error": "cursor-agent not found on PATH."})); return
    except subprocess.TimeoutExpired:
        print(json.dumps({"success": False, "error": f"cursor-agent timed out after {args.timeout}s."})); return

    out = (proc.stdout or "").strip()
    if not out:
        print(json.dumps({"success": False, "error": f"empty output from cursor-agent.\n{(proc.stderr or '').strip()}"}, ensure_ascii=False))
        return

    try:
        data = json.loads(out)
    except json.JSONDecodeError:
        print(json.dumps({"success": False, "error": f"could not parse cursor-agent JSON.\n{out[:2000]}"}, ensure_ascii=False))
        return

    session_id = data.get("session_id")
    agent_messages = data.get("result", "") or ""
    is_error = bool(data.get("is_error")) or data.get("subtype") not in (None, "success")

    if is_error or not agent_messages or not session_id:
        result = {"success": False, "SESSION_ID": session_id,
                  "error": data.get("result") or data.get("subtype") or "cursor-agent reported an error."}
    else:
        result = {"success": True, "SESSION_ID": session_id, "agent_messages": agent_messages}

    if args.return_all_messages:
        result["all_messages"] = data

    print(json.dumps(result, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
