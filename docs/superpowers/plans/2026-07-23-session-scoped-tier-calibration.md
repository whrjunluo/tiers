# Session-Scoped Tier Calibration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make dev-workflow classify the current session's real regression surface instead of mechanically defaulting bounded additions and static path replacements to L2.

**Architecture:** Keep classification as an agent-owned policy expressed in `skills/dev-workflow/SKILL.md`, with README mirroring the public contract and shell assertions preventing regression. Extend `learnings.sh` with one deterministic atomic operation for folding an approved category, then use it to close the two confirmed `流程/tie-breaker` records.

**Tech Stack:** Bash, awk, Markdown contract tests, existing dev-workflow controller.

## Global Constraints

- “New” is not an independent L1/L2 trigger.
- Initial classification and post-inspection calibration must use only the current session's objective, task base, consumers, contracts, affected flows, and test boundary.
- An isolated explicit addition with no existing consumer regression surface may be L3.
- A mechanical static-resource path replacement with unchanged runtime logic may be L4.
- Real auth, API write, IM, order, payment, schema, migration, and permission contract changes retain their existing gates.
- Do not add a keyword-based or numeric automatic scoring engine.
- Do not modify business repositories or independent worktrees.

---

### Task 1: Deterministic learning-category folding

**Files:**
- Modify: `tests/learnings.sh`
- Modify: `scripts/learnings.sh`

**Interfaces:**
- Consumes: the existing global `LEARNINGS.md` record format and category vocabulary.
- Produces: `learnings.sh fold <category>`, which atomically changes matching `status: pending` records to `status: folded` and prints the changed count.

- [ ] **Step 1: Write the failing folding contract test**

Add a second category record, invoke `fold`, and assert category isolation and idempotency:

```bash
bash "$LS" add "流程/tie-breaker" "repoC" "n3" >/dev/null
bash "$LS" add "流程/tie-breaker" "repoD" "n4" >/dev/null
out="$(bash "$LS" fold "流程/tie-breaker")"
echo "$out" | grep -q '2' || { echo "FAIL: fold 应报告两条变更"; exit 1; }
bash "$LS" ready | grep -q "流程/tie-breaker" && { echo "FAIL: folded category 不应继续 ready"; exit 1; } || true
bash "$LS" count | grep -q $'2\t判级/行为守卫' || { echo "FAIL: fold 不得修改其他 category"; exit 1; }
out="$(bash "$LS" fold "流程/tie-breaker")"
echo "$out" | grep -q '0' || { echo "FAIL: repeated fold 应幂等"; exit 1; }
```

- [ ] **Step 2: Run the test and verify RED**

Run: `bash tests/learnings.sh`

Expected: FAIL because `learnings.sh` rejects the unknown `fold` command.

- [ ] **Step 3: Implement atomic `fold_category`**

Add usage documentation, validate the category with `valid_cats`, rewrite to same-directory temporary files with awk, and atomically replace `LEARNINGS.md`:

```bash
fold_category() {
  local target="$1" tmp count_file changed
  valid_cats | grep -qxF "$target" || {
    echo "✗ category「$target」不在词表中" >&2
    return 1
  }
  tmp="${LEARNINGS}.tmp.$$"
  count_file="${LEARNINGS}.fold-count.$$"
  trap 'rm -f "$tmp" "$count_file"' EXIT
  awk -v target="$target" -v count_file="$count_file" '
    /^[[:space:]]*-[[:space:]]+date:/ { category="" }
    /category:/ {
      category=$0
      sub(/.*category:[[:space:]]*/, "", category)
      sub(/[[:space:]]*#.*/, "", category)
      gsub(/[[:space:]]+$/, "", category)
    }
    /status:[[:space:]]*pending/ && category==target {
      sub(/status:[[:space:]]*pending/, "status: folded")
      changed++
    }
    { print }
    END { print changed+0 > count_file }
  ' "$LEARNINGS" > "$tmp"
  changed="$(cat "$count_file")"
  mv "$tmp" "$LEARNINGS"
  rm -f "$count_file"
  trap - EXIT
  echo "✓ 已 folded：$target（$changed 条）"
}
```

Add a `fold)` case and include it in the command usage.

- [ ] **Step 4: Run the focused test and verify GREEN**

Run: `bash tests/learnings.sh`

Expected: `PASS tests/learnings.sh`.

- [ ] **Step 5: Commit the folding primitive**

```bash
git add scripts/learnings.sh tests/learnings.sh
git commit -m "feat: add deterministic learning folding"
```

### Task 2: Session-scoped classification contract

**Files:**
- Modify: `tests/workflow-state.sh`
- Modify: `scripts/workflow-state.sh`
- Modify: `skills/dev-workflow/SKILL.md`
- Modify: `README.md`

**Interfaces:**
- Consumes: the approved design and existing L0-L4 workflow policy.
- Produces: a two-stage classification contract and stable examples for isolated additions and static resource migrations.

- [ ] **Step 1: Add failing policy assertions**

Append assertions to `tests/workflow-state.sh` requiring these stable contract phrases or equivalent dedicated headings:

```bash
grep -q '当前会话' "$SKILL" || fail "判级必须绑定当前会话"
grep -q '新增.*不.*自动' "$SKILL" || fail "新增不得自动触发 L1/L2"
grep -q '隔离新增.*L3' "$SKILL" || fail "隔离新增应有 L3 边界"
grep -q '静态资源路径.*L4' "$SKILL" || fail "静态资源路径替换应有 L4 边界"
grep -q '自动重判' "$SKILL" || fail "影响面证据变化后应允许自动重判"
grep -q 'Kimi.*L3' "$SKILL" || fail "Kimi 隔离 adapter 案例应固化"
grep -q 'OSS.*L4' "$SKILL" || fail "静态 OSS 迁移案例应固化"
```

- [ ] **Step 2: Run the policy test and verify RED**

Run: `bash tests/workflow-state.sh`

Expected: FAIL on the first missing session-scoped classification assertion.

- [ ] **Step 3: Replace the mechanical decision tree**

Update `skills/dev-workflow/SKILL.md` so classification first asks whether there is structural migration, then whether a complete new flow/design is needed, then whether existing shared behavior/contracts/consumers change. Add a mandatory post-inspection calibration step and state explicitly:

```text
“新增”不自动等于 L1/L2。完全隔离、仅显式入口可达、且不改变任何既有消费者或路由的新增，可以按 L3；仅替换静态资源路径且不改变运行逻辑、控制流或契约，可以按 L4。
```

Define L2 by real existing regression surface rather than `≥3 files`. Preserve high-risk contract gates only when the current task changes that contract.

Also add a failing L3 understanding case with `kind: impact`, then update controller validation so L3 accepts either `root-cause` (`reproduction` + `root_cause`) or `impact` (`affected` + `tests`). Persist the evidence's actual kind; do not change the YAML schema.

- [ ] **Step 4: Add confirmed boundary examples**

Add these rows to the common-boundaries table:

```markdown
| 新增完全隔离的 provider adapter，显式调用且不进入旧路由 | L3（隔离新增，本地契约测试覆盖） |
| 仅将静态图片路径替换为等价 OSS URL，不改渲染/控制流 | L4（构建 + 资源可达性验证） |
| Kimi adapter：`auto_eligible=false`、旧 provider 路由不变 | L3 |
```

- [ ] **Step 5: Mirror the contract in README**

Update the quick-start example and tier table so L2 means changing existing shared logic/contracts/consumers, L3 includes isolated additions, and L4 includes logic-preserving static resource path replacement. Document automatic reclassification after impact inspection.

- [ ] **Step 6: Run focused policy tests and verify GREEN**

Run: `bash tests/workflow-state.sh && bash tests/learnings.sh`

Expected: both suites print PASS.

- [ ] **Step 7: Commit the classification contract**

```bash
git add scripts/workflow-state.sh skills/dev-workflow/SKILL.md README.md tests/workflow-state.sh docs/superpowers/specs/2026-07-23-session-scoped-tier-calibration-design.md docs/superpowers/plans/2026-07-23-session-scoped-tier-calibration.md
git commit -m "feat: calibrate tiers by session impact"
```

### Task 3: Fold the approved global learnings and verify release integrity

**Files:**
- Modify outside repository through supported data command: `~/.dev-workflow/LEARNINGS.md`
- Create ignored evidence: `docs/superpowers/.workflow-evidence/session-tier-calibration-*.txt`

**Interfaces:**
- Consumes: `learnings.sh fold <category>` from Task 1.
- Produces: no pending `流程/tie-breaker` records and a verified repository/controller state.

- [ ] **Step 1: Fold the confirmed category**

Run:

```bash
scripts/learnings.sh fold '流程/tie-breaker'
scripts/learnings.sh count
scripts/learnings.sh ready
```

Expected: exactly two records folded; `流程/tie-breaker` is absent from pending counts and ready output.

- [ ] **Step 2: Run full verification**

Run:

```bash
bash tests/all.sh
scripts/codegraph-judge.sh --repo "$PWD" --base c111a38 assess
git diff --check
```

Expected: `ALL PASS`, a task-scoped codegraph assessment, and no whitespace errors.

- [ ] **Step 3: Record controller evidence and complete**

Write tests, codegraph, and residual-risk evidence under `docs/superpowers/.workflow-evidence/`; set controller phase to `review`, register evidence paths, run `workflow-state.sh complete`, and verify `phase=done`.

- [ ] **Step 4: Final repository check**

Run:

```bash
git status --short
git log -3 --oneline
```

Expected: clean worktree with the spec, folding primitive, and classification policy commits present.
