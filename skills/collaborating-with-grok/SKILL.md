---
name: collaborating-with-grok
description: Delegates coding tasks to Grok CLI for prototyping, debugging, and code review. Use when needing algorithm implementation, bug analysis, or code quality feedback. Supports multi-turn sessions via SESSION_ID.
---

## Quick Start

```bash
python scripts/grok_bridge.py --cd "/path/to/project" --PROMPT "Your task"
```

**Output:** JSON with `success`, `SESSION_ID`, `agent_messages`, and optional `error`.

> Multi-turn delegation peer. For a read-only, one-shot independent review
> instead, use the `external-agent` skill (`--agent grok`).

## Parameters

```
usage: grok_bridge.py [-h] --PROMPT PROMPT --cd CD [--SESSION_ID SESSION_ID]
                      [--return-all-messages] [--model MODEL] [--require-permissions]
                      [--timeout TIMEOUT]

options:
  --PROMPT PROMPT       Instruction to send to grok.
  --cd CD               Workspace root (grok `--cwd`).
  --SESSION_ID SESSION_ID
                        Resume a session (grok `--resume <id>`). Empty starts a new session.
  --return-all-messages
                        Include the full raw object (incl. `thought`) in output.
  --model MODEL         Model ID to use. Strictly prohibited unless explicitly specified by the user.
  --require-permissions
                        Use the default permission mode instead of bypass. By default the bridge passes `--permission-mode bypassPermissions` because headless runs have no TTY to approve prompts.
  --timeout TIMEOUT     Seconds before giving up on the CLI. Default 600.
```

## Multi-turn Sessions

**Always capture `SESSION_ID`** from the first response for follow-up:

```bash
# Initial task
python scripts/grok_bridge.py --cd "/project" --PROMPT "Analyze auth in login.py"

# Continue with SESSION_ID
python scripts/grok_bridge.py --cd "/project" --SESSION_ID "<id-from-response>" --PROMPT "Write unit tests for that"
```

## Notes

- Wraps `grok -p --output-format json`, which prints a single JSON object: the reply is `text`, the session id is `sessionId`, completion is signalled by `stopReason` (`EndTurn`).
- Headless runs default to `--permission-mode bypassPermissions` (no TTY to approve tool prompts). Pass `--require-permissions` for the default permission mode.
- `scripts/selfcheck.sh` verifies the CLI is present and does one live round-trip.
- `--model` is gated: do not pass it unless the user asks for a specific model.
