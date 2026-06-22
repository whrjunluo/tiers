---
name: collaborating-with-cursor-agent
description: Delegates coding tasks to Cursor Agent CLI for prototyping, debugging, and code review. Use when needing algorithm implementation, bug analysis, or code quality feedback. Supports multi-turn sessions via SESSION_ID.
---

## Quick Start

```bash
python scripts/cursor_agent_bridge.py --cd "/path/to/project" --PROMPT "Your task"
```

**Output:** JSON with `success`, `SESSION_ID`, `agent_messages`, and optional `error`.

> Multi-turn delegation peer (writes/runs allowed). For a read-only, one-shot
> independent review instead, use the `external-agent` skill (`--agent cursor`).

## Parameters

```
usage: cursor_agent_bridge.py [-h] --PROMPT PROMPT --cd CD [--SESSION_ID SESSION_ID]
                              [--return-all-messages] [--model MODEL] [--require-permissions]
                              [--timeout TIMEOUT]

options:
  --PROMPT PROMPT       Instruction to send to cursor-agent.
  --cd CD               Workspace root; the agent runs with this as its working directory.
  --SESSION_ID SESSION_ID
                        Resume a previous chat (cursor `--resume <chatId>`). Empty starts a new session.
  --return-all-messages
                        Include the full raw result object in output.
  --model MODEL         Model (e.g. gpt-5, sonnet-4-thinking). Strictly prohibited unless explicitly specified by the user.
  --require-permissions
                        Re-enable tool-permission prompts. By default the bridge passes `--force` because headless runs have no TTY to approve prompts.
  --timeout TIMEOUT     Seconds before giving up on the CLI. Default 600.
```

## Multi-turn Sessions

**Always capture `SESSION_ID`** from the first response for follow-up:

```bash
# Initial task
python scripts/cursor_agent_bridge.py --cd "/project" --PROMPT "Analyze auth in login.py"

# Continue with SESSION_ID
python scripts/cursor_agent_bridge.py --cd "/project" --SESSION_ID "<uuid-from-response>" --PROMPT "Write unit tests for that"
```

## Notes

- Wraps `cursor-agent -p --output-format json`, which prints a single JSON object: the reply is `result`, the session id is `session_id`, errors are flagged by `is_error` / `subtype`.
- Headless runs default to `--force` (no TTY to approve tool prompts). Pass `--require-permissions` only if you can approve another way.
- `scripts/selfcheck.sh` verifies the CLI is present and does one live round-trip.
- `--model` is gated: do not pass it unless the user asks for a specific model.
