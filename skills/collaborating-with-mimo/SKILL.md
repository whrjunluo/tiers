---
name: collaborating-with-mimo
description: Delegates coding tasks to MiMoCode CLI for prototyping, debugging, and code review. Use when needing algorithm implementation, bug analysis, or code quality feedback. Supports multi-turn sessions via SESSION_ID.
---

## Quick Start

```bash
python scripts/mimo_bridge.py --cd "/path/to/project" --PROMPT "Your task"
```

**Output:** JSON with `success`, `SESSION_ID`, `agent_messages`, and optional `error`.

## Parameters

```
usage: mimo_bridge.py [-h] --PROMPT PROMPT --cd CD [--SESSION_ID SESSION_ID] [--fork]
                      [--return-all-messages] [--file FILE] [--model MODEL] [--agent AGENT]
                      [--require-permissions]

MiMo Bridge

options:
  -h, --help            show this help message and exit
  --PROMPT PROMPT       Instruction for the task to send to mimo.
  --cd CD               Set the workspace root for mimo before executing the task (maps to `--dir`).
  --SESSION_ID SESSION_ID
                        Resume the specified session of mimo. Defaults to empty, start a new session.
  --fork                Fork the session before continuing (requires --SESSION_ID).
  --return-all-messages
                        Return all NDJSON events (reasoning, tool calls, etc.). Off by default; only the agent's final text reply is returned.
  --file FILE           Attach one or more files to the prompt. Repeat the flag for multiple files.
  --model MODEL         Model to use, in `provider/model` form (e.g. xiaomi/mimo-v2.5-pro). This parameter is strictly prohibited unless explicitly specified by the user.
  --agent AGENT         Agent to use. This parameter is strictly prohibited unless explicitly specified by the user.
  --require-permissions
                        Re-enable interactive permission prompts. By default the bridge passes `--dangerously-skip-permissions` because headless `mimo run` has no TTY and would otherwise hang waiting for approval.
```

## Multi-turn Sessions

**Always capture `SESSION_ID`** from the first response for follow-up:

```bash
# Initial task
python scripts/mimo_bridge.py --cd "/project" --PROMPT "Analyze auth in login.py"

# Continue with SESSION_ID
python scripts/mimo_bridge.py --cd "/project" --SESSION_ID "ses_xxx-from-response" --PROMPT "Write unit tests for that"
```

## Common Patterns

**Prototyping (request diffs):**
```bash
python scripts/mimo_bridge.py --cd "/project" --PROMPT "Generate unified diff to add logging"
```

**Debug with full event trace:**
```bash
python scripts/mimo_bridge.py --cd "/project" --PROMPT "Debug this error" --return-all-messages
```

## Notes

- The bridge wraps `mimo run --format json` (NDJSON event stream). The agent's reply is reconstructed from `text` events; `SESSION_ID` is read from the top-level `sessionID` field present on every event.
- `mimo run` exits cleanly when the turn completes, so the bridge simply reads to EOF (no sentinel/force-terminate needed).
- Permissions: headless runs default to `--dangerously-skip-permissions`. Pass `--require-permissions` only if you have another way to approve tool actions, since a no-TTY prompt will hang.
- Model/agent flags are gated: do not pass `--model` or `--agent` unless the user explicitly asks for a specific one.
