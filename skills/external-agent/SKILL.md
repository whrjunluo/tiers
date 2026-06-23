---
name: external-agent
description: Use when delegating a bounded sub-task to an external coding-agent CLI (codex, cursor, grok, mimo, opencode, antigravity/agy, gemini) or getting an independent second opinion — gather info, implement, or cross-review. One runner, one routing policy.
---

# External Agent

One unified entry point for handing a bounded task to an external coding-agent CLI.
The **main agent stays the orchestrator and decision-maker**; these agents are
bounded workers whose output is evidence, never the final word.

These are **separate agents** with separate auth, permissions, and behavior — not
different models of one agent. Treat their output as advisory and verify locally.

## Runner (the hands)

Resolve `<plugin-root>` like `dev-workflow`, then:

```bash
python3 <plugin-root>/scripts/external_agent.py \
  --agent <name> --cd "$PWD" --PROMPT "bounded task" \
  [--mode review|delegate] [--format text|json] [--SESSION_ID id] [--context none|git]
```

- `--mode review` (default): **read-only** posture — independent review / research, no writes.
- `--mode delegate`: **read-write** posture — let the agent implement. **Needs explicit user authorization.**
- `--format text` (default) / `--format json` → `{success, SESSION_ID, agent_messages}`.
- `--SESSION_ID` resumes a prior session (multi-turn); antigravity has no resume.
- `--context git` prepends branch/status/diff to the prompt (for review of current changes).
- `--list` reports which agents are installed.
- `--model` only when the user named a model.

## Agent capability matrix (routing)

| agent | family | strong at | default role |
|---|---|---|---|
| `codex` | OpenAI | algorithms, patch diffs, sandbox levels | **execute** |
| `cursor` | multi (GPT/Claude) | repo-aware edits, implementation critique | **execute / review** |
| `grok` | xAI | web search, alternative reasoning | **gather / cross-review** |
| `antigravity` (`agy`) | Google | independent agentic review (Gemini successor) | **gather / review** |
| `mimo` | Xiaomi | China-available, Chinese reasoning | execute / review (fallback) |
| `opencode` | open-source, BYO provider | repo-aware execute/review on your own (often free/self-hosted) models | execute / review |
| `gemini` | Google | long context — **legacy: individual tiers disabled, migrate to `antigravity`** | (enterprise only) |

> The `gemini` CLI returns `IneligibleTierError` for free / Pro / Ultra accounts since
> the June 2026 migration. Use `antigravity` (`agy`) for Google-family work. The
> `gemini` adapter is kept only for enterprise Code Assist users who still have access.

## Routing policy (the brain)

Classify the sub-task, then pick mode + agent:

- **Gather info / research** → `--mode review`. Web/external facts → `grok`; large codebase/doc digest → `antigravity`. Read-only.
- **Execute / implement** → `--mode delegate` (needs user OK). Repo edits → `cursor` or `codex`; pure algorithm → `codex`; own/free/self-hosted models → `opencode`; domestic/fallback → `mimo`. Read-write, scoped to `--cd`.
- **Cross-review** → `--mode review`, run the **same artifact through ≥2 agents of different families** (e.g. `codex` + `grok` + `antigravity` — not two GPT-family agents), then the main agent reconciles. Diversity is the point: same-family agents share blind spots.

Before routing, run `--list` and only pick installed agents. If the user names an agent, use it; if they just say "external agent", ask which unless context makes it obvious.

## Orchestration

```
gather(grok/antigravity, review) → execute(codex/cursor, delegate)
  → cross-review(2 different-family agents, review) → main agent reconciles + verifies
```

## Guardrails

- Invoke only after the user requests or authorizes it. `--mode delegate` (writes) needs explicit OK and stays inside `--cd`.
- Tell the user before sending repository context (`--context git`) externally.
- Never include secrets, credentials, private keys, `.env` contents, or unrelated files.
- Output is evidence, not authority — verify findings locally; the main agent decides.
- **Committing not降级流程**: judging level, comprehension gate, TDD, and human review stay owned by `dev-workflow`.
- Do not silently fall back to another agent. If auth is missing, ask the user to log that agent in once.
