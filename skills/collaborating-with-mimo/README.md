# collaborating-with-mimo

A Claude Code **Agent Skill** that bridges Claude with the MiMoCode CLI (`mimo`) for multi-model collaboration on coding tasks.

## Overview

This Skill enables Claude to delegate coding tasks to MiMoCode CLI, combining the strengths of multiple AI models. MiMo handles algorithm implementation, debugging, and code analysis while Claude orchestrates the workflow and refines the output.

## Features

- **Multi-turn sessions**: Maintain conversation context across multiple interactions via `SESSION_ID`
- **NDJSON event parsing**: Reconstructs the agent's reply from the `mimo run --format json` event stream
- **JSON output**: Structured responses for easy parsing and integration
- **File attachments**: Attach files to prompts for additional context
- **Cross-platform**: Windows path/executable resolution handled automatically

## Installation

1. Ensure the [MiMoCode CLI](https://github.com/XiaomiMiMo) (`mimo`) is installed and available in your PATH, and a provider is configured (`mimo providers list`).
2. Copy this Skill to your Claude Code skills directory:
   - User-level: `~/.claude/skills/collaborating-with-mimo/`
   - Project-level: `.claude/skills/collaborating-with-mimo/`

## Usage

### Basic

```bash
python scripts/mimo_bridge.py --cd "/path/to/project" --PROMPT "Analyze the authentication flow"
```

### Multi-turn Session

```bash
# Start a session
python scripts/mimo_bridge.py --cd "/project" --PROMPT "Review login.py for security issues"
# Response includes SESSION_ID

# Continue the session
python scripts/mimo_bridge.py --cd "/project" --SESSION_ID "ses_xxx-from-response" --PROMPT "Suggest fixes for the issues found"
```

### Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `--PROMPT` | Yes | Task instruction |
| `--cd` | Yes | Workspace root directory (maps to `mimo --dir`) |
| `--SESSION_ID` | No | Resume a previous session (`ses_...`) |
| `--fork` | No | Fork the session before continuing (requires `--SESSION_ID`) |
| `--return-all-messages` | No | Include full NDJSON event stream in output |
| `--file` | No | Attach files (repeat the flag for multiple) |
| `--model` | No | `provider/model` (use only when explicitly requested) |
| `--agent` | No | Agent name (use only when explicitly requested) |
| `--require-permissions` | No | Re-enable interactive permission prompts (default skips them; a no-TTY prompt will hang) |

### Output Format

```json
{
  "success": true,
  "SESSION_ID": "ses_xxx",
  "agent_messages": "MiMo response text",
  "all_messages": []
}
```

## License

MIT License. See [LICENSE](LICENSE) for details.
