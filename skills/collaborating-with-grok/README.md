# collaborating-with-grok

A Claude Code **Agent Skill** that bridges Claude with the Grok CLI (`grok`) for multi-turn collaboration on coding tasks.

## Overview

Delegates coding tasks to Grok CLI as a multi-turn peer (prototyping, debugging, alternative reasoning). Claude orchestrates; grok does focused work and the output is verified by Claude.

> This is the **multi-turn delegation** peer. For a read-only, one-shot independent review, use the `external-agent` skill with `--agent grok`.

## Features

- **Multi-turn sessions** via `SESSION_ID` (grok `--resume <id>`)
- **JSON output**: uniform `{success, SESSION_ID, agent_messages}`
- **Self-check**: `scripts/selfcheck.sh` confirms the CLI is present and does a live round-trip

## Installation

1. Install the Grok CLI and authenticate (`grok login`).
2. Copy this Skill to your skills directory (user-level `~/.claude/skills/` or a plugin's `skills/`).

## Usage

```bash
# Basic
python scripts/grok_bridge.py --cd "/project" --PROMPT "Review login.py for issues"

# Continue the session
python scripts/grok_bridge.py --cd "/project" --SESSION_ID "<id>" --PROMPT "Suggest fixes"
```

### Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `--PROMPT` | Yes | Task instruction |
| `--cd` | Yes | Workspace root (grok `--cwd`) |
| `--SESSION_ID` | No | Resume a previous session |
| `--return-all-messages` | No | Include the raw object (incl. `thought`) |
| `--model` | No | Model id (use only when explicitly requested) |
| `--require-permissions` | No | Default permission mode (default passes `--permission-mode bypassPermissions`) |
| `--timeout` | No | Seconds before giving up (default 600) |

### Output Format

```json
{ "success": true, "SESSION_ID": "<id>", "agent_messages": "Grok response text" }
```

## License

MIT — original work, covered by the repository LICENSE.
