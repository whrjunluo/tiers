# Execution Mode Choice Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users choose inline or safe multi-agent execution after planning, with manifest validation, isolated write worktrees, host-owned integration, and cleanup.

**Architecture:** A standalone Python manifest validator owns DAG, write-set, hash, worker-limit, and worktree safety checks. The shell controller owns persisted execution choice and phase gates; it invokes the validator only for `choose-execution multi-agent` and later `check`. Skill/README describe the one-time choice and the host/worker boundary.

**Tech Stack:** Bash/awk controller, Python 3 standard library JSON validator, Markdown contract tests, native `git worktree`.

## Global Constraints

- `execution.mode` remains `single | multi-agent | goal`; Goal behavior is unchanged.
- `execution.choice_status` remains `undecided | selected`; the initial plan-stage choice is one-time.
- Selection happens after understanding and plan, before TDD; mode is not repeatedly requested unless plan/scope changes.
- Multi-agent requires at least two ready tasks, satisfied dependencies, explicit write sets or read-only tasks, disjoint writes, frozen base/plan hashes, worker slots, and isolated write worktrees.
- L4, L3 small-fix, one-task plans, same-file/shared schema/migration/lock/config changes, release/deploy/credential/destructive work, and unknown write sets default to single.
- Workers never edit the integration controller or own suspend/resume/release/deploy; the host owns merge, verification, and worktree cleanup.
- No shared-checkout parallel writes and no new automatic risk-tier scoring.

---

### Task 1: Execution manifest validator

**Files:**
- Create: `scripts/execution_manifest.py`
- Create: `tests/test_execution_manifest.py`
- Modify: `tests/all.sh`

**Interfaces:**
- `validate_manifest(data, repo, expected_base, expected_plan, mode="multi-agent") -> list[str]`
- CLI: `python3 scripts/execution_manifest.py --validate PATH --repo REPO --base SHA --plan-sha SHA --mode multi-agent`
- Valid output is JSON containing `valid: true` and `max_workers`; invalid output is JSON containing `valid: false` and non-empty `errors`.

- [ ] **Step 1: Write failing validator tests**

Cover one valid manifest and each rejection: fewer than two ready tasks, unmet dependency, write-set overlap, missing write set, invalid base/plan/repository hashes, max workers outside 1–3, write task without `.worktrees/<branch>` path, and read-only task without a worktree.

```python
def test_valid_manifest_reports_worker_limit(self):
    result = validate_manifest(valid_manifest(), self.repo, self.base, self.plan)
    self.assertEqual(result, [])

def test_rejects_overlapping_write_sets(self):
    data = valid_manifest()
    data["tasks"][1]["write_set"] = ["scripts/shared.sh"]
    self.assertIn("write sets overlap", validate_manifest(data, self.repo, self.base, self.plan)[0])
```

- [ ] **Step 2: Run RED**

Run: `python3 -m unittest tests.test_execution_manifest -v`

Expected: import failure because `scripts/execution_manifest.py` does not exist.

- [ ] **Step 3: Implement the validator**

Parse JSON with the standard library; require `runner: tiers.execution-manifest/v1`, 64-hex repository/base/plan hashes, `max_workers` in `1..3`, unique task ids, known dependencies, completed dependencies for ready tasks, at least two ready tasks, explicit `write_set` for non-read-only tasks, normalized disjoint write sets, and write worktrees under `<repo>/.worktrees/`. Read-only tasks may omit worktrees. Return all errors instead of stopping at the first one.

- [ ] **Step 4: Run GREEN and add the suite**

Run: `python3 -m unittest tests.test_execution_manifest -v` and then add the command to `tests/all.sh`.

Expected: all validator tests pass and `tests/all.sh` includes the new unit suite.

- [ ] **Step 5: Commit**

```bash
git add scripts/execution_manifest.py tests/test_execution_manifest.py tests/all.sh
git commit -m "feat: validate parallel execution manifests"
```

### Task 2: Controller execution-choice state machine

**Files:**
- Modify: `templates/workflow-state.yaml`
- Modify: `scripts/workflow-state.sh`
- Modify: `tests/workflow-state.sh`

**Interfaces:**
- New command: `workflow-state.sh choose-execution <single|multi-agent> [manifest]`
- `single` requires phase `plan` or `tdd`, clears manifest/hash/worker fields, and remains valid for all existing tasks.
- `multi-agent` requires phase `plan`, a real `artifacts.plan`, a manifest under `.workflow-evidence`, and validator success; it writes mode, manifest path, plan SHA-256, and max workers.

- [ ] **Step 1: Write failing state tests**

Add fixture assertions for default single compatibility, valid multi-agent selection, invalid overlap rejection, unknown write-set rejection, stale plan hash rejection, `choose-execution single` clearing a previous manifest, and Goal mode refusing the choice command. Add fields to empty-slot and migration checks.

- [ ] **Step 2: Run RED**

Run: `bash tests/workflow-state.sh`

Expected: failure because the template lacks manifest fields and the controller has no `choose-execution` command.

- [ ] **Step 3: Add state fields and schema migration**

Add `execution.plan_sha256`, `execution.max_workers: 2`, `execution.fallback_reason`, and `artifacts.execution_manifest` to the template. Include them in `VALID_FIELDS`, `ensure_schema`, empty-slot checks, and structure validation. Accept `single multi-agent goal`; require positive max workers and 64-hex plan hash only for multi-agent.

- [ ] **Step 4: Implement `choose-execution`**

For initial `single`, require a non-sealed state, phase `plan`, and an undecided choice; clear multi-agent fields and print the selected mode. For `multi-agent`, require the same one-time plan-stage choice, an existing plan artifact, validate the manifest with the current `execution.base_revision` and plan file SHA-256, then persist the manifest path, plan SHA-256, and manifest worker limit. Reject Goal mode and all invalid manifests fail-closed. Permit only a phase=tdd multi-agent-to-single fallback with a non-empty reason.

- [ ] **Step 5: Enforce mode during check/execution**

When mode is multi-agent, revalidate the manifest path, repository/base/plan hashes, and worker limit during `check` and execution phases. Do not alter Goal confirmation or suspend/resume semantics.

- [ ] **Step 6: Run GREEN**

Run: `bash tests/workflow-state.sh && python3 -m unittest tests.test_execution_manifest -v`

Expected: both pass, including old single/goal migration fixtures.

- [ ] **Step 7: Commit**

```bash
git add templates/workflow-state.yaml scripts/workflow-state.sh tests/workflow-state.sh
git commit -m "feat: add execution mode selection to controller"
```

### Task 3: User-facing workflow and integration contract

**Files:**
- Modify: `skills/dev-workflow/SKILL.md`
- Modify: `README.md`
- Modify: `tests/workflow-state.sh`

**Interfaces:**
- Produces the user-facing plan handoff and worker lifecycle contract; no worker may directly mutate the main controller.

- [ ] **Step 1: Write failing documentation assertions**

Require tests for `choose-execution`, the one-time post-plan choice, `multi-agent`, isolated worktrees, disjoint write sets, host-owned integration, graceful failure fallback, and cleanup after successful integration.

- [ ] **Step 2: Run RED**

Run: `bash tests/workflow-state.sh`

Expected: fail on missing execution-choice documentation.

- [ ] **Step 3: Document the Hybrid handoff**

Between plan and TDD, instruct the host to present `single` and `multi-agent` with the recommendation and evidence. Document defaults for small tasks, read-only sharing, worker-per-worktree writes, host merge/conflict handling, failure-to-inline fallback, and cleanup only after integration verification.

- [ ] **Step 4: Run GREEN and full verification**

Run:

```bash
bash tests/all.sh
scripts/codegraph-judge.sh --repo "$PWD" --base a47260a assess
git diff --check
```

Expected: `ALL PASS`, task-scoped codegraph output, and no whitespace errors.

- [ ] **Step 5: Commit**

```bash
git add skills/dev-workflow/SKILL.md README.md tests/workflow-state.sh
git commit -m "docs: add hybrid execution mode guidance"
```

### Task 4: Host integration and worktree cleanup evidence

**Files:**
- Create: `docs/superpowers/.workflow-evidence/execution-mode-tests.txt`
- Create: `docs/superpowers/.workflow-evidence/execution-mode-codegraph.txt`
- Create: `docs/superpowers/.workflow-evidence/execution-mode-risks.txt`

- [ ] **Step 1: Exercise a valid multi-agent manifest**

Create a temporary two-task manifest with disjoint write sets and worktrees under `.worktrees/`; select multi-agent through the controller; verify mode, manifest path, plan hash, and max workers.

- [ ] **Step 2: Exercise failure and cleanup guards**

Verify overlap, stale hash, same-checkout write, and missing dependency fail closed. Verify the host can mark a worker failed and return to single mode, and that cleanup is only considered after a committed worker is integrated and tests pass.

- [ ] **Step 3: Complete controller**

Register tests, codegraph, and residual-risk evidence, set phase `review`, run `workflow-state.sh complete`, and verify `phase=done` in the isolated worktree.

- [ ] **Step 4: Merge and clean up**

After review, merge the feature branch into `main`, run the full suite from the integration checkout, then run `git worktree remove .worktrees/execution-mode-choice` and delete the feature branch only after the merge is verified.
