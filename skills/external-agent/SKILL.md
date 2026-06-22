---
name: external-agent
description: Use when the user requests Antigravity CLI, agy, Cursor Agent CLI, cursor-agent, Grok CLI, grok, or explicitly authorizes an independent external-agent review, challenge, or research pass.
---

# External Agent

Use independent external agents as second opinions. Antigravity CLI (`agy`), Cursor Agent CLI (`cursor-agent`), and Grok CLI (`grok`) are separate agents with separate authentication, permissions, and behavior; do not describe them as different models of the same agent. Keep the current agent responsible for the final decision and verification.

## Agent Selection

| Agent | CLI | Runner argument | Good default use |
|---|---|---|---|
| Antigravity | `agy` | `--agent antigravity` | Google Antigravity review / challenge pass |
| Cursor Agent | `cursor-agent` | `--agent cursor` | Cursor-based coding review or implementation critique |
| Grok | `grok` | `--agent grok` | Grok-based review, research, or alternative reasoning |

If the user names one of these agents, use that specific agent. If the user only asks for an "external agent", ask which one unless context already makes the choice clear. The default runner agent is Antigravity for backward compatibility only.

## Run

Resolve `<plugin-root>` using the same plugin-root rules as `dev-workflow`, then pass the prompt on stdin. For code review, challenge, or implementation critique, share repository context with `--context git`; this prepends branch, status, diff summary, changed files, and current diff to the user request.

```bash
printf '%s\n' "$prompt" | <plugin-root>/scripts/external-agent.sh --agent antigravity --repo "$PWD" --context git
```

Use `--agent cursor` for Cursor Agent or `--agent grok` for Grok. Add `--model <model>` only when the user selected a model for the chosen agent. Run the script with `--help` for its complete interface.

Use `--context none` only for research or conceptual questions where the repository diff is irrelevant. Do not paste secrets into stdin; `--context git` reads only git metadata and the current diff.

## Guardrails

- Invoke only after the user requests or authorizes the specific external agent.
- Tell the user before sending repository context externally.
- Give the selected agent a bounded task and a concrete output format; do not delegate final authority.
- Never include secrets, credentials, private keys, `.env` contents, or unrelated files in the prompt.
- The runner uses conservative permission flags for each agent; do not bypass permission controls.
- Treat output as advisory: inspect evidence and verify findings locally.
- Do not silently fall back to a different agent. If authentication is missing, ask the user to run that agent's login command interactively once.
