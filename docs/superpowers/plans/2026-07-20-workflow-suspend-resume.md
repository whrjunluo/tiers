# Workflow Suspend/Resume Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add safe `suspend <key>` and `resume <key>` transitions to the workflow controller while preserving the single-active-slot completion and evidence gates.

**Architecture:** Keep `.workflow-state.yaml` as the only active state and store parked unfinished states as ignored `<key>.yaml` plus `<key>.meta` pairs. Extend the existing shell controller with narrowly scoped validation/atomic-write helpers, reuse the current repository lock, and treat absent or completely empty initialized state as the only new start/resume slot in addition to a valid sealed state.

**Tech Stack:** Bash 3-compatible shell, POSIX utilities, Git, Python 3 only where existing tests already use it.

## Global Constraints

- Work only in `/Users/elvis/gst-workspace/tiers` on `main`; do not modify doctor-console or other business repositories.
- Preserve the user's existing four-line change in `skills/dev-workflow/SKILL.md`; any edits to that file must retain those lines exactly.
- Leave `stash@{0}: backup-before-updating-dev-workflow-external-agent-py` untouched.
- Snapshot keys are 1–64 characters, start with lowercase ASCII alphanumeric, and then contain only lowercase ASCII alphanumeric, hyphen, or underscore.
- Snapshot state bytes are exact after normal schema migration at command entry; snapshot metadata format is `workflow-snapshot/v1` with repository and state SHA-256 values.
- No force mode, overwrite mode, automatic conflict resolution, snapshot listing, or doctor-task switching is in scope.
- TDD order is mandatory: edit `tests/workflow-state.sh`, observe the missing-command/behavior RED, then edit `scripts/workflow-state.sh`.
- `requirements.external_review=true` remains required; completion needs a current standard two-family external review report.

---

### Task 1: Add suspend/resume contract tests and prove RED

**Files:**

- Modify: `tests/workflow-state.sh`

**Interfaces:**

- Consumes: existing `new_repo`, `setf`, `getf`, `evidence`, and `expect_fail` helpers.
- Produces: executable behavioral contract for `suspend <key>`, empty-slot `start`, and `resume <key>`.

- [ ] **Step 1: Add focused test helpers**

Add helpers that create a valid unfinished L1 state, return the active-state path, return snapshot paths, and compute a portable SHA-256 using the same Python-free fallback contract as production. Keep the helper API explicit:

```bash
active_state(){ printf '%s\n' "$1/docs/superpowers/.workflow-state.yaml"; }
snapshot_yaml(){ printf '%s\n' "$1/docs/superpowers/.workflow-suspended/$2.yaml"; }
snapshot_meta(){ printf '%s\n' "$1/docs/superpowers/.workflow-suspended/$2.meta"; }
unfinished_repo(){
  local repo
  repo="$(new_repo "$1")"
  setf "$repo" task "$2"
  setf "$repo" level L1
  setf "$repo" phase spec
  setf "$repo" context.target scripts/workflow-state.sh
  setf "$repo" context.sources approved-spec
  printf '%s\n' "$repo"
}
```

- [ ] **Step 2: Add round-trip and active-slot tests**

Cover these exact transitions:

```text
unfinished -> suspend -> absent active file -> resume -> byte-identical unfinished state
unfinished -> suspend -> start new L2 from absent slot
unfinished -> suspend -> start intervening task -> validly complete/seal -> resume original
unfinished active -> start rejects and resume rejects without changing either state
empty initialized template -> start succeeds
empty initialized template -> resume succeeds
partially populated template -> start/resume reject
```

Record the pre-suspend state copy after controller migration, compare with `cmp -s`, and assert snapshot files are deleted only after a successful restore.

- [ ] **Step 3: Add validation and recovery tests**

Use a loop for unsafe keys and separate assertions for mutation safety:

```bash
for key in '' A upperCase ../escape 'a/b' 'a\b' '.hidden' 'a b' 'a;rm' "$(printf 'a%.0s' {1..65})"; do
  expect_fail "unsafe suspend key should fail: $key" bash "$WS" --repo "$repo" suspend "$key"
done
```

Also cover duplicate pair protection, YAML-only/meta-only partial pairs, state tampering, metadata tampering, wrong repository, snapshot file symlinks, snapshot directory symlink escape, sealed/empty suspend rejection, completed snapshot rejection, ignore idempotency, and active-state preservation after every failed operation.

- [ ] **Step 4: Add CLI/documentation assertions**

Extend the existing `SKILL` assertions and add README/ignore assertions for:

```bash
grep -q 'suspend <key>' "$SKILL"
grep -q 'resume <key>' "$SKILL"
grep -q 'suspend.*start.*resume' "$SKILL"
grep -q 'workflow-state.sh suspend' "$HERE/README.md"
grep -qxF 'docs/superpowers/.workflow-suspended/' "$HERE/.gitignore"
```

- [ ] **Step 5: Run the focused suite and verify RED**

Run: `bash tests/workflow-state.sh`

Expected: FAIL on the first new `suspend`/`resume` behavior because the controller usage switch has no such commands yet; existing earlier tests must reach that failure without syntax/setup errors.

### Task 2: Implement safe snapshot primitives and controller transitions

**Files:**

- Modify: `scripts/workflow-state.sh`
- Test: `tests/workflow-state.sh`

**Interfaces:**

- Consumes: `STATE`, `REPO`, `PLUGIN_ROOT`, `file_sha256`, `ensure_schema`, `validate_completion`, `write_field`, and the existing controller lock.
- Produces: `suspend <key>`, `resume <key>`, empty-slot-aware `start`, strict snapshot metadata parsing, and atomic install/restore helpers.

- [ ] **Step 1: Add constants and key/path validation**

Define the ignored snapshot directory and metadata format near `STATE`:

```bash
SUSPENDED_DIR="$REPO/docs/superpowers/.workflow-suspended"
SNAPSHOT_FORMAT="workflow-snapshot/v1"
```

Add helpers with single responsibilities:

```text
validate_snapshot_key <key>
canonical_repo_root
repository_sha256
snapshot_path <key> yaml|meta
assert_snapshot_directory_safe
assert_regular_snapshot_file <path> <label>
```

Reject invalid keys before any path construction. Resolve the repository and snapshot parent with `pwd -P`; reject a symlinked suspended directory or any resolved path outside the canonical repository root.

- [ ] **Step 2: Add active-slot classification**

Implement helpers that distinguish exactly three valid slot forms:

```text
empty: state absent, or template fields all empty/default and no completion seal
unfinished: valid task/level/non-done phase with no completion seal
sealed: validate_completion sealed succeeds
```

Malformed or partially initialized states must fail closed. Avoid using `validate_completion current` for unfinished snapshots because that requires final evidence; instead validate the controller schema, legal enum values, required unfinished identity fields, no completion seal, and `phase != done`.

- [ ] **Step 3: Implement snapshot pair validation**

Strictly accept metadata with exactly these three keys and no duplicates/unknown keys:

```text
format: workflow-snapshot/v1
repository_sha256: <64 lowercase hex>
state_sha256: <64 lowercase hex>
```

Verify both files are regular non-symlink files, the repository hash matches the current canonical repository identity, the YAML digest matches metadata, and the YAML represents a valid unfinished state. Metadata validation returns parsed digests without printing snapshot contents.

- [ ] **Step 4: Implement `suspend <key>` in atomic order**

Under the already-acquired controller lock:

1. validate argument count/key and unused pair;
2. require a valid unfinished active state;
3. ensure exact `.gitignore` entry idempotently;
4. create YAML/meta temporary files beside their finals;
5. copy active bytes, compute hashes, write/validate metadata;
6. rename YAML then metadata to final names;
7. revalidate installed pair;
8. remove active state only after pair validation succeeds.

Use a cleanup trap or explicit cleanup path for temporary files without replacing the existing lock-release trap. If installation fails, leave the active state intact and retain any final partial pair as a duplicate-blocking recovery artifact.

- [ ] **Step 5: Extend `start <task> <level>`**

Validate the current slot before replacing it. Accept absent state, a completely empty initialized template, or a valid sealed state. Reject unfinished/malformed states. Initialize through a temporary state beside `$STATE`, validate it, and rename it into place so a failed initialization cannot destroy a sealed state.

- [ ] **Step 6: Implement `resume <key>` in restore order**

1. validate key and active slot (empty or sealed only);
2. validate the complete snapshot pair and hashes;
3. copy YAML to a temporary active-state file;
4. validate the temporary unfinished state using the same helper;
5. atomically rename it to `$STATE`;
6. verify the installed digest;
7. delete YAML then metadata.

If cleanup fails after restore, return a cleanup error while leaving the restored active state and any undeleted snapshot artifact intact.

- [ ] **Step 7: Update usage strings and run GREEN**

Update both the file header and fallback usage to include `suspend <key>` and `resume <key>`.

Run: `bash -n scripts/workflow-state.sh && bash tests/workflow-state.sh`

Expected: syntax check exits 0 and `PASS tests/workflow-state.sh`.

### Task 3: Document the legal task-switch workflow

**Files:**

- Modify: `.gitignore`
- Modify: `README.md`
- Modify: `skills/dev-workflow/SKILL.md`
- Test: `tests/workflow-state.sh`

**Interfaces:**

- Consumes: controller CLI implemented in Task 2.
- Produces: consistent operator guidance and ignored local snapshot storage.

- [ ] **Step 1: Add the exact ignore rule**

Add once:

```gitignore
docs/superpowers/.workflow-suspended/
```

- [ ] **Step 2: Update README controller examples**

Document:

```bash
<plugin-root>/scripts/workflow-state.sh suspend <key>
<plugin-root>/scripts/workflow-state.sh start <task> <level>
<plugin-root>/scripts/workflow-state.sh resume <key>
```

Explain that suspend is for unfinished tasks, snapshots are repository-bound ignored local state, start/resume require an empty or sealed active slot, and operators must not fake completion or manually swap YAML.

- [ ] **Step 3: Update dev-workflow guidance without losing user changes**

Re-read `git diff -- skills/dev-workflow/SKILL.md` before editing. Add the suspend/start/resume sequence to the controller hard-gate and cross-session sections, while preserving the existing task-scope calibration and graph-risk divergence paragraphs byte-for-byte.

- [ ] **Step 4: Run focused tests again**

Run: `bash tests/workflow-state.sh`

Expected: `PASS tests/workflow-state.sh`, including documentation assertions.

### Task 4: Verify, review, and seal the controller task

**Files:**

- Modify: `docs/superpowers/.workflow-evidence/tests.txt`
- Modify: `docs/superpowers/.workflow-evidence/codegraph.txt`
- Modify: `docs/superpowers/.workflow-evidence/external-review.json`
- Modify: `docs/superpowers/.workflow-evidence/risks.txt`
- Controller-only state update: `docs/superpowers/.workflow-state.yaml`

**Interfaces:**

- Consumes: completed code/docs/tests and installed controller at `/Users/elvis/.codex/plugins/cache/local/dev-workflow/0.8.0`.
- Produces: fresh local verification evidence, dual-family review evidence, focused commit, and a valid sealed controller task.

- [ ] **Step 1: Run full verification**

Run, in order:

```bash
bash -n scripts/workflow-state.sh
bash tests/workflow-state.sh
bash tests/all.sh
git diff --check
```

Expected: all exit 0; record exact commands and `exit_code: 0` in `docs/superpowers/.workflow-evidence/tests.txt`.

- [ ] **Step 2: Run codegraph with task base calibration**

Use controller `execution.base_revision` (expected `d33ab97...`) as the base:

```bash
scripts/codegraph-judge.sh --repo "$PWD" --base "$(CONTROLLER get execution.base_revision)" assess
```

Save the actual result or explicit degraded reason in `docs/superpowers/.workflow-evidence/codegraph.txt` and reconcile affected flows/test gaps.

- [ ] **Step 3: Enter review and request standard external cross-review**

Set controller phase `review`, list providers, then freeze and review the current Git context:

```bash
python3 scripts/external_agent.py --list
python3 scripts/external_agent.py \
  --cross-review auto --orchestrator-family openai --progress jsonl \
  --cd "$PWD" --context git --format json \
  --PROMPT "只读审查 workflow suspend/resume 实现与已批准 spec 的一致性；重点检查数据丢失、路径穿越/symlink、原子顺序、哈希/仓库绑定、活动槽保护和测试缺口，只报告有证据的问题" \
  > docs/superpowers/.workflow-evidence/external-review.json
```

Require `success=true`, `quorum=true`, and two successful distinct non-OpenAI families. Locally verify every finding; fix valid issues with a new RED/GREEN cycle, rerun verification, and regenerate the frozen review evidence afterward.

- [ ] **Step 4: Record residual risks and controller evidence**

Write a non-placeholder risk statement (for example, integrity is not an attacker-resistant signature and cleanup failure can leave a recoverable partial pair), then set `evidence.tests`, `evidence.codegraph`, `evidence.external_review`, and `evidence.residual_risks` through the installed controller.

- [ ] **Step 5: Create a focused commit**

Before staging, inspect `git diff` and ensure no unrelated files or stash changes are included. Force-add the ignored spec/plan only if they are intentionally part of the task, then commit only the suspend/resume implementation, tests, docs, and approved design/plan:

```bash
git add .gitignore README.md scripts/workflow-state.sh tests/workflow-state.sh
git add -f docs/superpowers/specs/2026-07-20-workflow-suspend-resume-design.md docs/superpowers/plans/2026-07-20-workflow-suspend-resume.md
git commit -m "feat: add workflow suspend resume"
```

Stage only the suspend/resume hunks from `skills/dev-workflow/SKILL.md` (for example with a reviewed cached patch). Leave the user's pre-existing task-scope calibration and graph-risk divergence hunks unstaged and unchanged in the working tree.

- [ ] **Step 6: Refresh repository-bound review if commit changed the fingerprint, then complete**

Because the external report binds a Git snapshot, regenerate it after the final commit if the fingerprint changed. Re-set the current evidence path, run `check`, then `complete` with the installed controller. Do not invoke suspend/start on the doctor task from this repository.

- [ ] **Step 7: Final verification after sealing**

Run:

```bash
bash tests/workflow-state.sh
bash tests/all.sh
git status --short
CONTROLLER check
```

Expected: test commands exit 0, controller reports `phase=done`, stash remains untouched, and the only remaining working-tree change is none (or explicitly documented user-owned state if controller evidence is ignored).
