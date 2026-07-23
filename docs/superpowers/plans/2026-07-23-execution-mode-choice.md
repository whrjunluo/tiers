# Native-First Execution Mode Choice Implementation Plan

> **For agentic workers:** Execute this plan inline in the integration session. This feature must not create a plugin-owned worker runtime.

**Goal:** Let planned work choose single or host-native multi-agent execution, with an honest sequential fallback.

**Architecture:** The Bash controller persists only mode, selection status, plan hash, and fallback reason. The skill asks the host to use native dispatch, model selection, and isolation. The integration session owns final review and verification.

**Tech Stack:** Bash, existing YAML helpers, shell contract tests, Markdown.

## Global Constraints

- Codex/Claude native dispatch is preferred; fallback is current-session sequential execution.
- External CLI delegation stays explicit opt-in and cannot claim native isolation.
- Goal and no-plan L2/L3/L4 compatibility stay unchanged.

---

### Task 1: Remove the duplicate runtime

**Files:** Delete `scripts/execution_manifest.py` and `tests/test_execution_manifest.py`; modify `tests/all.sh`, `scripts/platform_review_contract.py`, and `tests/test_platform_review_contract.py`.

- [ ] Write a failing aggregate assertion that no execution-manifest runtime exists and platform-review validation retains its independent contract.
- [ ] Run `bash tests/all.sh`; expect the new assertion to fail.
- [ ] Remove the validator, its unit suite, aggregate-suite registration, and only its unrelated platform-review coupling.
- [ ] Run `bash tests/all.sh`; expect it to pass without importing execution-manifest code.
- [ ] Commit with `refactor: remove duplicate execution runtime`.

### Task 2: Simplify the controller to a selection adapter

**Files:** Modify `scripts/workflow-state.sh`, `templates/workflow-state.yaml`, and `tests/workflow-state.sh`.

**Interfaces:** `choose-execution single`; `choose-execution multi-agent`; `choose-execution single "<reason>"` for a TDD fallback; `choose-execution reset "<reason>"` after a changed plan.

- [ ] Replace manifest fixtures with a failing native-selection test: multi-agent selection requires only a real plan and records mode with no fallback reason.
- [ ] Run `bash tests/workflow-state.sh`; expect the old manifest requirement to fail the new test.
- [ ] Retain only `execution.mode`, `execution.choice_status`, `execution.plan_sha256`, and `execution.fallback_reason`; remove manifest, worker, worktree, write-set, and cleanup validation.
- [ ] Bind initial choices to `artifacts.plan`, preserve no-plan L2/L3/L4 implicit single, and make fallback update mode plus its required reason.
- [ ] Run `bash tests/workflow-state.sh`; expect selection, reset, fallback, Goal protection, and legacy compatibility to pass without a worktree.
- [ ] Commit with `feat: prefer native execution mode dispatch`.

### Task 3: Align host guidance and release evidence

**Files:** Modify `skills/dev-workflow/SKILL.md`, `README.md`, and `tests/workflow-state.sh`.

- [ ] Write failing documentation assertions for `native-first`, `sequential fallback`, and the prohibition on representing shared-checkout external delegation as isolated parallel writes.
- [ ] Run `bash tests/workflow-state.sh`; expect current Hybrid lifecycle wording to fail.
- [ ] Document plan-time host-native dispatch, host model policy, current-session fallback, and integration-session ownership. Remove all manifest/worktree lifecycle claims.
- [ ] Run `bash tests/all.sh`, `scripts/codegraph-judge.sh --repo "$PWD" --base b689b69 assess`, and `git diff --check`.
- [ ] Commit with `docs: document native-first agent dispatch`.
