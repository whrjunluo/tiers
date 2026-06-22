---
name: external-agent
description: Use when the user requests Antigravity CLI or agy, or explicitly authorizes an independent external-agent review, challenge, or research pass.
---

# External Agent

Use Antigravity CLI as an independent second opinion. Keep the current agent responsible for the final decision and verification.

## Run

Resolve `<plugin-root>` using the same plugin-root rules as `dev-workflow`, then pass the prompt on stdin:

```bash
printf '%s\n' "$prompt" | <plugin-root>/scripts/external-agent.sh --repo "$PWD"
```

Add `--model <model>` only when the user selected a model. Run the script with `--help` for its complete interface.

## Guardrails

- Invoke only after the user requests or authorizes an external Google agent.
- Tell the user before sending repository context externally.
- Give `agy` a bounded task and a concrete output format; do not delegate final authority.
- Never include secrets, credentials, private keys, `.env` contents, or unrelated files in the prompt.
- The runner always uses `--sandbox`; do not bypass its permission controls.
- Treat output as advisory: inspect evidence and verify findings locally.
- Do not silently fall back to legacy `gemini`. If authentication is missing, ask the user to run `agy` interactively once.
