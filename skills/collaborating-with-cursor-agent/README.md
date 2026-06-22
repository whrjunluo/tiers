# collaborating-with-cursor-agent

A Claude Code **Agent Skill** that bridges Claude with the Cursor Agent CLI (`cursor-agent`) for multi-turn collaboration on coding tasks.

## Overview

Delegates coding tasks to Cursor Agent CLI as a multi-turn peer (prototyping, debugging, code analysis). Claude orchestrates; cursor-agent does focused work and the output is verified by Claude.

> This is the **multi-turn delegation** peer. For a read-only, one-shot independent review, use the `external-agent` skill with `--agent cursor`.

## Features

- **Multi-turn sessions** via `SESSION_ID` (cursor `--resume <chatId>`)
- **JSON output**: uniform `{success, SESSION_ID, agent_messages}`
- **Self-check**: `scripts/selfcheck.sh` confirms the CLI is present and does a live round-trip

## Installation

1. Install the Cursor Agent CLI and authenticate (`cursor-agent login`, or set `CURSOR_API_KEY`).
2. Copy this Skill to your skills directory (user-level `~/.claude/skills/` or a plugin's `skills/`).

## Usage

```bash
# Basic
python scripts/cursor_agent_bridge.py --cd "/project" --PROMPT "Review login.py for issues"

# Continue the session
python scripts/cursor_agent_bridge.py --cd "/project" --SESSION_ID "<uuid>" --PROMPT "Suggest fixes"
```

### Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `--PROMPT` | Yes | Task instruction |
| `--cd` | Yes | Workspace root (process working directory) |
| `--SESSION_ID` | No | Resume a previous chat |
| `--return-all-messages` | No | Include the raw result object |
| `--model` | No | Model (use only when explicitly requested) |
| `--require-permissions` | No | Re-enable permission prompts (default passes `--force`) |
| `--timeout` | No | Seconds before giving up (default 600) |

### Output Format

```json
{ "success": true, "SESSION_ID": "<uuid>", "agent_messages": "Cursor response text" }
```

## License

MIT — original work, covered by the repository LICENSE.
