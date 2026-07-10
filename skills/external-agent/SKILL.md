---
name: external-agent
description: Use when a bounded task needs an external coding-agent CLI or an independent second opinion, including repository research, implementation delegation, and cross-provider review.
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

python3 <plugin-root>/scripts/external_agent.py \
  --cross-review agy,mimo --cd "$PWD" --context git --format json \
  --PROMPT "review the same frozen artifact"
```

- `--mode review` (default): **read-only** posture — independent review / research, no writes.
- `--mode delegate`: **read-write** posture — let the agent implement. **Needs explicit user authorization.**
- `--format text` (default) / `--format json` → `{success, SESSION_ID, agent_messages}`.
- `--SESSION_ID` resumes a prior session (multi-turn); antigravity has no resume.
- `--context git` prepends branch/status/diff to the prompt (for review of current changes).
- `--list` reports installed candidates, provider family, persistent `health_status`, machine-readable `routing_priority`, and `recommended_timeout_seconds`.
- `--cross-review a,b` freezes one prompt/context, computes its SHA-256 and repository fingerprint, calls every reviewer read-only, and returns a timestamped report with `runner: tiers.external-agent/v1`. It exits successfully only when at least two known agents from different families return non-empty successful reviews.
- `--fingerprint --cd <repo>` prints the deterministic Git snapshot hash used by the completion gate; workflow state/evidence files are excluded.
- `--timeout N` is an explicit per-agent hard limit. When omitted, the runner uses that provider's persisted recommendation, then falls back to 600 seconds.
- `--model` only when the user named a model.

## Agent capability matrix (routing)

| agent | family | strong at | default role |
|---|---|---|---|
| `codex` | OpenAI | algorithms, patch diffs, sandbox levels | **execute** |
| `cursor` | multi (GPT/Claude) | repo-aware edits, implementation critique | **execute / review** |
| `grok` | xAI | web search, alternative reasoning | **gather / cross-review** |
| `antigravity` (`agy`) | Google | independent agentic review (Gemini successor) | **gather / review** |
| `mimo` | Xiaomi | China-available, Chinese reasoning | execute / review (fallback) |
| `opencode` | configurable provider | repo-aware execute/review on your own (often free/self-hosted) models | execute / review |
| `gemini` | Google | long context — **legacy: individual tiers disabled, migrate to `antigravity`** | (enterprise only) |

> The `gemini` CLI returns `IneligibleTierError` for free / Pro / Ultra accounts since
> the June 2026 migration. Use `antigravity` (`agy`) for Google-family work. The
> `gemini` adapter is kept only for enterprise Code Assist users who still have access.

> ⚠️ **调用返回拒绝/空产出时，优先检查调用方式，而不是归因到具体 agent。**
> 对长 prompt、敏感领域或保真验收要求高的任务，先收敛输入范围、拆分上下文、降低无关敏感表述；
> 若仍返回拒绝/空产出，切换执行路径或换用更适合当前约束的 agent，不要反复重试同一 prompt。

## Routing policy (the brain)

Classify the sub-task, then pick mode + agent:

- **Gather info / research** → `--mode review`. Web/external facts → `grok`; large codebase/doc digest → `antigravity`. Read-only.
- **Execute / implement** → `--mode delegate` (needs user OK). Repo edits → `cursor` or `codex`; pure algorithm → `codex`; own/free/self-hosted models → `opencode`; China-available execution → `mimo`. If a call returns refusal/empty output, adjust the invocation or switch execution path instead of repeating the same prompt. Read-write, scoped to `--cd`.
- **Cross-review** → `--cross-review <a>,<b>`, using **≥2 external CLI agents of different families**. Prefer installed reviewers with `routing_priority=normal` (normally `grok`, `cursor`, or `mimo`); use `antigravity`/`agy` after healthy candidates when it is marked `slow` or `degraded`, unless the user explicitly names it. Use `codex` as one reviewer only when the main orchestrator is not Codex. Installed binaries are only candidates: failed auth, timeout, empty output, aliases of one agent, or one successful family produce `quorum=false`. Platform subagents are not a substitute. The main agent reconciles every result.

Before routing, run `--list` and only pick installed agents. Health persists globally under `$DEV_WORKFLOW_DATA/external-agent-health.json` (default `~/.dev-workflow/`): the first timeout marks the provider `slow` and doubles its recommendation; any current failure streak sets `routing_priority=deprioritized`; two consecutive failures mark it `degraded`. A later success clears the consecutive-failure streak but retains `slow` history. Prefer healthy candidates when equivalent, but never silently skip a named or required provider: report the marker and use its recommendation or an explicit timeout. If the user names an agent, use it; if they just say "external agent", ask which unless context makes it obvious.

## Orchestration

```
gather(grok/antigravity, review) → execute(codex/cursor, delegate)
  → --cross-review(2 different-family successes, one artifact hash) → main agent reconciles + verifies
```

## Guardrails

- Read-only external review requires task/workflow authorization to send the scoped artifact; announce before sending repository context with `--context git`. Cross-review children inherit the parent permission mode. `--mode delegate` additionally needs explicit write authorization and stays inside `--cd`.
- Never include secrets, credentials, private keys, `.env` contents, or unrelated files.
- Output is evidence, not authority — verify findings locally; the main agent decides.
- **委派不降级流程**：judging level, comprehension gate, TDD, evidence gates, and final verification stay owned by `dev-workflow`.
- Do not silently fall back to another agent. If auth is missing, ask the user to log that agent in once.
