#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
WS="$HERE/scripts/workflow-state.sh"
RUNNER="$HERE/scripts/external_agent.py"
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
fail(){ echo "FAIL: $1" >&2; exit 1; }
new_repo(){
  local repo="$ROOT/$1"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" checkout -q -b feat/test-state
  bash "$WS" --repo "$repo" init >/dev/null
  printf '%s\n' "$repo"
}
setf(){ bash "$WS" --repo "$1" set "$2" "$3" >/dev/null; }
getf(){ bash "$WS" --repo "$1" get "$2"; }
evidence(){
  local repo="$1" name="$2" content="$3"
  mkdir -p "$repo/docs/superpowers/.workflow-evidence"
  printf '%s\n' "$content" > "$repo/docs/superpowers/.workflow-evidence/$name"
  printf '%s\n' "docs/superpowers/.workflow-evidence/$name"
}
review_evidence(){
  local repo="$1" name="$2" fingerprint="$3" created_at="$4" path
  path="$repo/docs/superpowers/.workflow-evidence/$name"
  mkdir -p "$(dirname "$path")"
  python3 - "$path" "$fingerprint" "$created_at" <<'PY'
import json
import sys

path, fingerprint, created_at = sys.argv[1:]
data = {
    "runner": "tiers.external-agent/v1",
    "success": True,
    "quorum": True,
    "artifact_sha256": "a" * 64,
    "repository_fingerprint": fingerprint,
    "created_at": created_at,
    "successful_families": ["google", "xiaomi"],
    "reviewers": [
        {"agent": "antigravity", "family": "google", "success": True,
         "timeout_seconds": 360, "agent_messages": "PASS from Google reviewer"},
        {"agent": "mimo", "family": "xiaomi", "success": True,
         "timeout_seconds": 360, "agent_messages": "PASS from Xiaomi reviewer"},
    ],
}
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh)
PY
  printf '%s\n' "docs/superpowers/.workflow-evidence/$name"
}
degraded_review_evidence(){
  local repo="$1" name="$2" fingerprint="$3" created_at="$4" path
  path="$repo/docs/superpowers/.workflow-evidence/$name"
  mkdir -p "$(dirname "$path")"
  python3 - "$path" "$fingerprint" "$created_at" <<'PY'
import json
import sys

path, fingerprint, created_at = sys.argv[1:]
data = {
    "runner": "tiers.external-agent/v1",
    "success": True,
    "quorum": False,
    "outcome": "degraded",
    "review_profile": "small-fix",
    "policy": {
        "minimum_successes": 1,
        "minimum_families": 1,
        "stop_after_policy": True,
    },
    "artifact_sha256": "a" * 64,
    "repository_fingerprint": fingerprint,
    "created_at": created_at,
    "finished_at": created_at,
    "duration_seconds": 1.25,
    "successful_families": ["xiaomi"],
    "reviewers": [
        {"agent": "mimo", "family": "xiaomi", "success": True,
         "status": "success", "timeout_seconds": 90,
         "duration_seconds": 1.0, "agent_messages": "focused review"},
        {"agent": "grok", "family": "xai", "success": False,
         "status": "cancelled", "timeout_seconds": 90,
         "duration_seconds": 1.1,
         "error": "stopped after small-fix policy was satisfied"},
    ],
}
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh)
PY
  printf '%s\n' "docs/superpowers/.workflow-evidence/$name"
}
confirmation_evidence(){
  local repo="$1" name="$2" scope="$3" path
  path="$repo/docs/superpowers/.workflow-evidence/$name"
  mkdir -p "$(dirname "$path")"
  python3 - "$path" "$scope" <<'PY'
import json, sys
path, scope = sys.argv[1:]
data = {
    "runner": "tiers.autonomous-confirmation/v1",
    "mode": "autonomous",
    "status": "PASS",
    "scope_sha256": scope,
    "rounds": 1,
    "requires_user": False,
    "boundary": "safe",
    "proposal": {
        "options": [
            {"id": "A", "summary": "Use repository pattern"},
            {"id": "B", "summary": "Add local adapter"},
        ],
        "recommendation": "A",
        "assumptions": ["The existing contract remains stable"],
    },
    "critic": {
        "provenance": "built-in-checklist",
        "verdict": "PASS",
        "findings": ["No irreversible action is required"],
    },
    "decision": {
        "choice": "A",
        "basis": "Matches the current repository pattern",
        "assumptions": ["The change remains local"],
        "residual_risk": "Provider behavior still needs tests",
    },
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle)
PY
  printf '%s\n' "docs/superpowers/.workflow-evidence/$name"
}
expect_fail(){
  local msg="$1"; shift
  if "$@" >/dev/null 2>&1; then fail "$msg"; fi
}
active_state(){ printf '%s\n' "$1/docs/superpowers/.workflow-state.yaml"; }
snapshot_yaml(){ printf '%s\n' "$1/docs/superpowers/.workflow-suspended/$2.yaml"; }
snapshot_meta(){ printf '%s\n' "$1/docs/superpowers/.workflow-suspended/$2.meta"; }
sha256_file(){
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}
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
seal_active_l4(){
  local repo="$1"
  setf "$repo" context.target scripts/workflow-state.sh
  setf "$repo" context.sources test-seal
  setf "$repo" context.environment n/a
  setf "$repo" context.delivery local-only
  setf "$repo" phase review
  setf "$repo" evidence.tests "$(evidence "$repo" tests.txt $'command: bash tests/workflow-state.sh\nexit_code: 0')"
  setf "$repo" evidence.residual_risks "$(evidence "$repo" risks.txt 'risk: none')"
  bash "$WS" --repo "$repo" complete >/dev/null
}

# check should be harmless before init; a new repo simply has no resumable state.
EMPTY="$ROOT/empty"
mkdir -p "$EMPTY"
bash "$WS" --repo "$EMPTY" check | grep -q "无续行状态" || fail "未初始化 check 应提示无续行状态"

# Codex workspace-write sandboxes expose Git metadata read-only. State commands
# must still work because their lock protects workflow data, not Git internals.
READ_ONLY_GIT="$ROOT/read-only-git"
mkdir -p "$READ_ONLY_GIT"
git -C "$READ_ONLY_GIT" init -q
git -C "$READ_ONLY_GIT" checkout -q -b feat/test-state
chmod a-w "$READ_ONLY_GIT/.git"
if ! bash "$WS" --repo "$READ_ONLY_GIT" init >/dev/null 2>&1; then
  chmod u+w "$READ_ONLY_GIT/.git"
  fail "只读 .git 时 workflow state 仍应可用"
fi
chmod u+w "$READ_ONLY_GIT/.git"

# init migrates the pre-evidence schema without losing task progress.
LEGACY="$ROOT/legacy"
mkdir -p "$LEGACY/docs/superpowers"
printf '%s\n' \
  'task: legacy-task' \
  'level: L1' \
  'phase: review' \
  'artifacts:' \
  '  spec: ""' \
  '  plan: ""' \
  'updated: 2026-07-01' \
  'next: verify' > "$LEGACY/docs/superpowers/.workflow-state.yaml"
bash "$WS" --repo "$LEGACY" init >/dev/null
[ "$(getf "$LEGACY" task)" = legacy-task ] || fail "migration 不得丢失旧 task"
[ "$(getf "$LEGACY" requirements.business)" = false ] || fail "migration 应补 requirements"
[ -n "$(getf "$LEGACY" context.repo)" ] || fail "migration 应补 context"
[ "$(getf "$LEGACY" execution.mode)" = single ] || fail "未完成旧任务应迁移为 single mode"
[ "$(getf "$LEGACY" understanding.status)" = pending ] || fail "未完成旧任务应迁移为 pending understanding"
[ "$(getf "$LEGACY" completion.workflow_version)" = 2 ] || fail "未完成旧任务应升级为 workflow v2"

# An unsealed state cannot opt back into the gate-free v1 contract.
python3 - "$LEGACY/docs/superpowers/.workflow-state.yaml" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
path.write_text(path.read_text().replace('workflow_version: 2', 'workflow_version: 1'), encoding='utf-8')
PY
expect_fail "未封存 workflow v1 不得绕过执行硬门" bash "$WS" --repo "$LEGACY" check
[ "$(getf "$LEGACY" completion.workflow_version)" = 2 ] || fail "未封存 workflow v1 应自动升级为 v2"

# Already sealed legacy tasks remain historical v1 instead of gaining fabricated gates.
LEGACY_SEALED="$ROOT/legacy-sealed"
mkdir -p "$LEGACY_SEALED/docs/superpowers"
printf '%s\n' \
  'task: legacy-sealed' \
  'level: L2' \
  'phase: done' \
  'completion:' \
  '  completed_at: 2026-07-01T00:00:00Z' \
  '  repository_fingerprint: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  '  requirements_sha256: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
  'updated: 2026-07-01' \
  'next: ""' > "$LEGACY_SEALED/docs/superpowers/.workflow-state.yaml"
bash "$WS" --repo "$LEGACY_SEALED" init >/dev/null
[ "$(getf "$LEGACY_SEALED" completion.workflow_version)" = 1 ] || fail "sealed 旧任务应保留 workflow v1"
[ "$(getf "$LEGACY_SEALED" understanding.status)" = pending ] || fail "sealed 旧任务不得伪造 understanding pass"

REPO="$(new_repo basic)"
f="$REPO/docs/superpowers/.workflow-state.yaml"
[ -f "$f" ] || fail "未初始化状态文件"
[ "$(getf "$REPO" context.repo)" = "$(git -C "$REPO" rev-parse --show-toplevel)" ] || fail "init 应记录 repo"
[ "$(getf "$REPO" context.branch)" = "feat/test-state" ] || fail "init 应记录 branch"
[ "$(getf "$REPO" execution.mode)" = single ] || fail "新状态应默认 single mode"
[ "$(getf "$REPO" execution.profile)" = standard ] || fail "新状态应默认 standard profile"
[ "$(getf "$REPO" understanding.status)" = pending ] || fail "新状态应默认 pending understanding"
[ "$(getf "$REPO" confirmation.status)" = pending ] || fail "新状态应默认 pending confirmation"
[ "$(getf "$REPO" completion.workflow_version)" = 2 ] || fail "新状态应使用 workflow v2"

SYMLINK_EVIDENCE="$(new_repo symlink-evidence)"
setf "$SYMLINK_EVIDENCE" task symlink-evidence
setf "$SYMLINK_EVIDENCE" level L1
setf "$SYMLINK_EVIDENCE" context.target workflow-state
setf "$SYMLINK_EVIDENCE" context.sources scripts/workflow-state.sh
outside_evidence="$ROOT/outside-understanding.txt"
printf '%s\n' 'acceptance: reject external evidence' 'non_goals: none' > "$outside_evidence"
mkdir -p "$SYMLINK_EVIDENCE/docs/superpowers/.workflow-evidence"
ln -s "$outside_evidence" "$SYMLINK_EVIDENCE/docs/superpowers/.workflow-evidence/understanding.txt"
expect_fail "understanding evidence symlink 不得越过仓库边界" \
  bash "$WS" --repo "$SYMLINK_EVIDENCE" understand docs/superpowers/.workflow-evidence/understanding.txt

setf "$REPO" phase spec
[ "$(getf "$REPO" phase)" = "spec" ] || fail "set/get phase"
setf "$REPO" requirements.fidelity true
[ "$(getf "$REPO" requirements.fidelity)" = "true" ] || fail "set/get nested field"
task_with_yaml_syntax="Fix #123: Bob's login"
setf "$REPO" task "$task_with_yaml_syntax"
[ "$(getf "$REPO" task)" = "$task_with_yaml_syntax" ] || fail "set/get 应保留 #、冒号和单引号"

CONCURRENT_STATE="$(new_repo concurrent-state)"
for iteration in 1 2 3 4 5 6 7 8 9 10 11 12; do
  setf "$CONCURRENT_STATE" task before
  setf "$CONCURRENT_STATE" context.target before
  bash "$WS" --repo "$CONCURRENT_STATE" set task "task-$iteration" >/dev/null &
  task_pid=$!
  bash "$WS" --repo "$CONCURRENT_STATE" set context.target "target-$iteration" >/dev/null &
  target_pid=$!
  wait "$task_pid"
  wait "$target_pid"
  [ "$(getf "$CONCURRENT_STATE" task)" = "task-$iteration" ] || fail "并发 state 写入丢失 task（iteration=${iteration}）"
  [ "$(getf "$CONCURRENT_STATE" context.target)" = "target-$iteration" ] || fail "并发 state 写入丢失 target（iteration=${iteration}）"
done

INVALID_LEVEL="$(new_repo invalid-level)"
python3 - "$INVALID_LEVEL/docs/superpowers/.workflow-state.yaml" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
path.write_text(path.read_text().replace('level: ""', 'level: L5'), encoding="utf-8")
PY
expect_fail "check 应拒绝手工写入的非法 level" bash "$WS" --repo "$INVALID_LEVEL" check

INVALID_ENV="$(new_repo invalid-env)"
python3 - "$INVALID_ENV/docs/superpowers/.workflow-state.yaml" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
path.write_text(path.read_text().replace('environment: "" # real | mock | n/a', 'environment: invalid'), encoding="utf-8")
PY
expect_fail "check 应拒绝手工写入的非法 environment" bash "$WS" --repo "$INVALID_ENV" check

# Understanding evidence is tier-specific and content-addressed.
understanding_repo(){
  local name="$1" level="$2" repo
  repo="$(new_repo "$name")"
  setf "$repo" task "$name-task"
  setf "$repo" level "$level"
  setf "$repo" context.target scripts/workflow-state.sh
  setf "$repo" context.sources user-request-and-repo
  printf '%s\n' "$repo"
}
understand_pass(){
  local name="$1" level="$2" body="$3" expected_kind="$4" repo path
  repo="$(understanding_repo "$name" "$level")"
  path="$(evidence "$repo" understanding.txt "$body")"
  bash "$WS" --repo "$repo" understand "$path" >/dev/null
  [ "$(getf "$repo" understanding.status)" = passed ] || fail "$level understanding 应通过"
  [ "$(getf "$repo" understanding.kind)" = "$expected_kind" ] || fail "$level understanding kind 错误"
  printf '%s\n' "$(getf "$repo" understanding.scope_sha256)" | grep -qE '^[0-9a-f]{64}$' || fail "$level scope hash 缺失"
  printf '%s\n' "$(getf "$repo" understanding.evidence_sha256)" | grep -qE '^[0-9a-f]{64}$' || fail "$level evidence hash 缺失"
}
understand_pass understanding-l0 L0 $'result: PASS\nkind: architecture\nboundaries: state and consumers\nmigration: preserve sealed v1\nrollback: restore previous template' architecture
understand_pass understanding-l1 L1 $'result: PASS\nkind: requirements\nacceptance: visible hard gate\nnon_goals: no model leaderboard' requirements
understand_pass understanding-l2 L2 $'result: PASS\nkind: impact\naffected: state transitions\ntests: workflow-state suite' impact
understand_pass understanding-l3 L3 $'result: PASS\nkind: root-cause\nreproduction: task with hash truncates\nroot_cause: comment stripping ignores quoting' root-cause

# A same-objective L3 -> L1 reassessment may reuse the content-addressed root
# cause while adding the newly required acceptance and non-goals evidence.
REUSED="$(understanding_repo understanding-reused L3)"
reused_root="$(evidence "$REUSED" root-cause.txt $'result: PASS\nkind: root-cause\nreproduction: failed message remains retryable\nroot_cause: send success and failure share cleanup state')"
bash "$WS" --repo "$REUSED" understand "$reused_root" >/dev/null
setf "$REUSED" level L1
setf "$REUSED" context.sources user-request-expanded-acceptance
reused_requirements="$(evidence "$REUSED" requirements.txt $'result: PASS\nkind: requirements\nacceptance: success clears input and failure remains retryable\nnon_goals: no transport changes\nreuses: docs/superpowers/.workflow-evidence/root-cause.txt')"
bash "$WS" --repo "$REUSED" understand "$reused_requirements" >/dev/null
[ "$(getf "$REUSED" understanding.reused_kind)" = root-cause ] || fail "L3 -> L1 应记录复用 kind"
[ "$(getf "$REUSED" understanding.reused_evidence)" = "$reused_root" ] || fail "L3 -> L1 应记录复用 evidence"
setf "$REUSED" phase tdd
printf '%s\n' $'result: PASS\nkind: root-cause\nreproduction: changed\nroot_cause: tampered' > "$REUSED/$reused_root"
expect_fail "复用的 root-cause 被篡改后不得进入 review" bash "$WS" --repo "$REUSED" set phase review

REUSED_OTHER="$(understanding_repo understanding-reused-other L3)"
other_root="$(evidence "$REUSED_OTHER" root-cause.txt $'result: PASS\nkind: root-cause\nreproduction: stable\nroot_cause: cleanup state')"
bash "$WS" --repo "$REUSED_OTHER" understand "$other_root" >/dev/null
setf "$REUSED_OTHER" level L1
setf "$REUSED_OTHER" context.target scripts/unrelated-target.sh
other_requirements="$(evidence "$REUSED_OTHER" requirements.txt $'result: PASS\nkind: requirements\nacceptance: new target\nnon_goals: none\nreuses: docs/superpowers/.workflow-evidence/root-cause.txt')"
expect_fail "不同 target 不得复用旧 understanding" bash "$WS" --repo "$REUSED_OTHER" understand "$other_requirements"

UNDERSTANDING_WRONG_KIND="$(understanding_repo understanding-wrong-kind L3)"
setf "$UNDERSTANDING_WRONG_KIND" evidence.tests "$(evidence "$UNDERSTANDING_WRONG_KIND" understanding.txt $'result: PASS\nkind: impact\naffected: parser\ntests: state test')"
expect_fail "L3 understanding 应拒绝错误 kind" bash "$WS" --repo "$UNDERSTANDING_WRONG_KIND" understand "$(getf "$UNDERSTANDING_WRONG_KIND" evidence.tests)"

UNDERSTANDING_MISSING="$(understanding_repo understanding-missing L2)"
missing_understanding="$(evidence "$UNDERSTANDING_MISSING" understanding.txt $'result: PASS\nkind: impact\naffected: parser')"
expect_fail "L2 understanding 应拒绝缺 tests" bash "$WS" --repo "$UNDERSTANDING_MISSING" understand "$missing_understanding"

UNDERSTANDING_CONFLICT="$(understanding_repo understanding-conflict L1)"
conflict_understanding="$(evidence "$UNDERSTANDING_CONFLICT" understanding.txt $'result: FAIL\nresult: PASS\nkind: requirements\nacceptance: visible\nnon_goals: none')"
expect_fail "understanding 应拒绝 FAIL/PASS 冲突" bash "$WS" --repo "$UNDERSTANDING_CONFLICT" understand "$conflict_understanding"
expect_fail "understanding 应拒绝目录外证据" bash "$WS" --repo "$UNDERSTANDING_CONFLICT" understand ../outside.txt

UNDERSTANDING_L4="$(new_repo understanding-l4)"
setf "$UNDERSTANDING_L4" level L4
[ "$(getf "$UNDERSTANDING_L4" understanding.status)" = not-required ] || fail "L4 应自动豁免 understanding"

# Execution phases are hard-gated by current scope and evidence hashes.
GATED="$(understanding_repo understanding-gated L2)"
expect_fail "pending understanding 不得进入 tdd" bash "$WS" --repo "$GATED" set phase tdd
gated_evidence="$(evidence "$GATED" understanding.txt $'result: PASS\nkind: impact\naffected: state consumers\ntests: workflow-state suite')"
bash "$WS" --repo "$GATED" understand "$gated_evidence" >/dev/null
setf "$GATED" phase tdd
setf "$GATED" context.target scripts/other.sh
expect_fail "scope 变化后不得进入 review" bash "$WS" --repo "$GATED" set phase review
setf "$GATED" context.target scripts/workflow-state.sh
setf "$GATED" requirements.fidelity true
expect_fail "requirements 变化后不得进入 review" bash "$WS" --repo "$GATED" set phase review

GATED_EVIDENCE="$(understanding_repo understanding-evidence-change L3)"
gated_changed_path="$(evidence "$GATED_EVIDENCE" understanding.txt $'result: PASS\nkind: root-cause\nreproduction: stable failure\nroot_cause: parser strips comments')"
bash "$WS" --repo "$GATED_EVIDENCE" understand "$gated_changed_path" >/dev/null
printf '%s\n' $'result: PASS\nkind: root-cause\nreproduction: stable failure\nroot_cause: different hypothesis' > "$GATED_EVIDENCE/$gated_changed_path"
expect_fail "understanding evidence 被替换后不得进入 tdd" bash "$WS" --repo "$GATED_EVIDENCE" set phase tdd

GATED_TAMPER="$(understanding_repo understanding-tamper L2)"
python3 - "$GATED_TAMPER/docs/superpowers/.workflow-state.yaml" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
path.write_text(path.read_text().replace("status: pending", "status: passed", 1), encoding="utf-8")
PY
expect_fail "只手改 understanding.status 不得进入 tdd" bash "$WS" --repo "$GATED_TAMPER" set phase tdd

# Goal lifecycle stores only an objective digest and reuses valid checkpoints.
GOAL_REPO="$(understanding_repo goal-lifecycle L2)"
goal_objective="Implement private objective #123"
bash "$WS" --repo "$GOAL_REPO" goal "$goal_objective" >/dev/null
[ "$(getf "$GOAL_REPO" execution.mode)" = goal ] || fail "goal 命令应切换 execution.mode"
goal_hash="$(getf "$GOAL_REPO" execution.objective_sha256)"
printf '%s\n' "$goal_hash" | grep -qE '^[0-9a-f]{64}$' || fail "Goal objective hash 缺失"
[ "$(getf "$GOAL_REPO" execution.continuation)" = 0 ] || fail "首次 Goal continuation 应为 0"
if grep -qF "$goal_objective" "$GOAL_REPO/docs/superpowers/.workflow-state.yaml"; then fail "Goal 原文不得落盘"; fi
[ "$(getf "$GOAL_REPO" understanding.status)" = pending ] || fail "进入 Goal 应重置 understanding"
goal_understanding="$(evidence "$GOAL_REPO" understanding.txt $'result: PASS\nkind: impact\naffected: goal state\ntests: continuation suite')"
bash "$WS" --repo "$GOAL_REPO" understand "$goal_understanding" >/dev/null
setf "$GOAL_REPO" execution.checkpoint "tests pending #2"
bash "$WS" --repo "$GOAL_REPO" continue-goal "$goal_objective" >/dev/null
[ "$(getf "$GOAL_REPO" execution.continuation)" = 1 ] || fail "同目标续行应递增 continuation"
[ "$(getf "$GOAL_REPO" execution.checkpoint)" = "tests pending #2" ] || fail "同目标续行应保留 checkpoint"
[ "$(getf "$GOAL_REPO" understanding.status)" = passed ] || fail "同目标续行应复用 understanding"
[ "$(getf "$GOAL_REPO" execution.objective_sha256)" = "$goal_hash" ] || fail "同目标 hash 不应变化"
bash "$WS" --repo "$GOAL_REPO" continue-goal "Deploy objective" >/dev/null
[ "$(getf "$GOAL_REPO" execution.continuation)" = 2 ] || fail "目标变化仍应记录 continuation"
[ "$(getf "$GOAL_REPO" execution.checkpoint)" = "" ] || fail "目标变化应清空 checkpoint"
[ "$(getf "$GOAL_REPO" understanding.status)" = pending ] || fail "目标变化应重置 understanding"
[ "$(getf "$GOAL_REPO" confirmation.status)" = pending ] || fail "目标变化应重置 confirmation"
[ "$(getf "$GOAL_REPO" execution.objective_sha256)" != "$goal_hash" ] || fail "目标变化应更新 objective hash"

SINGLE_CONTINUE="$(new_repo single-continue)"
expect_fail "single mode 不得 continue-goal" bash "$WS" --repo "$SINGLE_CONTINUE" continue-goal "not active"

# Goal execution additionally requires a current autonomous confirmation artifact.
GOAL_CONFIRM="$(understanding_repo goal-confirm L2)"
bash "$WS" --repo "$GOAL_CONFIRM" goal "Implement confirmation gate" >/dev/null
goal_confirm_understanding="$(evidence "$GOAL_CONFIRM" understanding.txt $'result: PASS\nkind: impact\naffected: goal execution\ntests: confirmation integration')"
bash "$WS" --repo "$GOAL_CONFIRM" understand "$goal_confirm_understanding" >/dev/null
expect_fail "Goal 缺 confirmation 不得进入 tdd" bash "$WS" --repo "$GOAL_CONFIRM" set phase tdd
confirmation_path="$(confirmation_evidence "$GOAL_CONFIRM" confirmation.json "$(getf "$GOAL_CONFIRM" understanding.scope_sha256)")"
bash "$WS" --repo "$GOAL_CONFIRM" confirm "$confirmation_path" >/dev/null
[ "$(getf "$GOAL_CONFIRM" confirmation.mode)" = autonomous ] || fail "confirm 应记录 autonomous mode"
[ "$(getf "$GOAL_CONFIRM" confirmation.status)" = passed ] || fail "confirm 应记录 passed status"
printf '%s\n' "$(getf "$GOAL_CONFIRM" confirmation.decision_sha256)" | grep -qE '^[0-9a-f]{64}$' || fail "confirm artifact hash 缺失"
setf "$GOAL_CONFIRM" phase tdd
python3 - "$GOAL_CONFIRM/$confirmation_path" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path))
data["decision"]["basis"] = "Artifact changed after confirmation"
with open(path, "w") as handle:
    json.dump(data, handle)
PY
expect_fail "confirmation artifact 被替换后不得进入 review" bash "$WS" --repo "$GOAL_CONFIRM" set phase review

GOAL_CONFIRM_STALE="$(understanding_repo goal-confirm-stale L2)"
bash "$WS" --repo "$GOAL_CONFIRM_STALE" goal "Implement scoped confirmation" >/dev/null
stale_understanding="$(evidence "$GOAL_CONFIRM_STALE" understanding.txt $'result: PASS\nkind: impact\naffected: initial scope\ntests: initial tests')"
bash "$WS" --repo "$GOAL_CONFIRM_STALE" understand "$stale_understanding" >/dev/null
stale_confirmation="$(confirmation_evidence "$GOAL_CONFIRM_STALE" confirmation.json "$(getf "$GOAL_CONFIRM_STALE" understanding.scope_sha256)")"
bash "$WS" --repo "$GOAL_CONFIRM_STALE" confirm "$stale_confirmation" >/dev/null
setf "$GOAL_CONFIRM_STALE" context.target scripts/new-target.sh
bash "$WS" --repo "$GOAL_CONFIRM_STALE" understand "$stale_understanding" >/dev/null
expect_fail "scope 重评后旧 confirmation 不得进入 tdd" bash "$WS" --repo "$GOAL_CONFIRM_STALE" set phase tdd

GOAL_CONFIRM_UNSAFE="$(understanding_repo goal-confirm-unsafe L2)"
bash "$WS" --repo "$GOAL_CONFIRM_UNSAFE" goal "Unsafe confirmation" >/dev/null
unsafe_understanding="$(evidence "$GOAL_CONFIRM_UNSAFE" understanding.txt $'result: PASS\nkind: impact\naffected: deployment\ntests: dry run')"
bash "$WS" --repo "$GOAL_CONFIRM_UNSAFE" understand "$unsafe_understanding" >/dev/null
unsafe_confirmation="$(confirmation_evidence "$GOAL_CONFIRM_UNSAFE" confirmation.json "$(getf "$GOAL_CONFIRM_UNSAFE" understanding.scope_sha256)")"
python3 - "$GOAL_CONFIRM_UNSAFE/$unsafe_confirmation" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path))
data["boundary"] = "deploy"
data["critic"]["findings"] = ["用户已确认 deployment"]
with open(path, "w") as handle:
    json.dump(data, handle)
PY
expect_fail "不安全或伪称用户确认的 artifact 应拒绝" bash "$WS" --repo "$GOAL_CONFIRM_UNSAFE" confirm "$unsafe_confirmation"

# check: illegal phase should error
expect_fail "非法 phase 应拒绝" bash "$WS" --repo "$REPO" set phase 乱写

# Direct done is never legal; completion must go through the evidence gate.
expect_fail "set phase done 应拒绝" bash "$WS" --repo "$REPO" set phase done

# Standard completion requires the context manifest plus test/risk evidence.
STANDARD="$(new_repo standard)"
setf "$STANDARD" task standard-change
setf "$STANDARD" level L2
setf "$STANDARD" context.target scripts/workflow-state.sh
setf "$STANDARD" context.sources user-request
setf "$STANDARD" context.environment n/a
setf "$STANDARD" context.delivery local-only
standard_understanding="$(evidence "$STANDARD" understanding.txt $'result: PASS\nkind: impact\naffected: workflow completion\ntests: workflow-state suite')"
bash "$WS" --repo "$STANDARD" understand "$standard_understanding" >/dev/null
setf "$STANDARD" phase review
setf "$STANDARD" evidence.tests "$(evidence "$STANDARD" tests.txt $'command: bash tests/workflow-state.sh\nexit_code: 0')"
expect_fail "缺 residual risk 证据不得完成" bash "$WS" --repo "$STANDARD" complete
setf "$STANDARD" evidence.residual_risks "$(evidence "$STANDARD" risks-placeholder.txt 'risk: done')"
expect_fail "占位 residual risk 证据不得完成" bash "$WS" --repo "$STANDARD" complete
setf "$STANDARD" evidence.residual_risks "$(evidence "$STANDARD" risks-placeholder-spaces.txt 'risk: done   ')"
expect_fail "尾部空格不得绕过 residual risk 占位检查" bash "$WS" --repo "$STANDARD" complete
setf "$STANDARD" evidence.residual_risks "$(evidence "$STANDARD" risks.txt 'risk: none')"
bash "$WS" --repo "$STANDARD" complete >/dev/null
[ "$(getf "$STANDARD" phase)" = "done" ] || fail "standard complete 应进入 done"
expect_fail "done 状态不得通过 set 重新打开" bash "$WS" --repo "$STANDARD" set phase review
bash "$WS" --repo "$STANDARD" start next-standard L2 >/dev/null
[ "$(getf "$STANDARD" task)" = next-standard ] || fail "start 应开启新任务"
[ "$(getf "$STANDARD" phase)" = brainstorm ] || fail "start 应从 brainstorm 开始"

# Unfinished tasks can be parked and restored byte-for-byte.
SUSPEND_ROUNDTRIP="$(unfinished_repo suspend-roundtrip original-task)"
cp "$(active_state "$SUSPEND_ROUNDTRIP")" "$ROOT/original-state.yaml"
bash "$WS" --repo "$SUSPEND_ROUNDTRIP" suspend original >/dev/null
[ ! -e "$(active_state "$SUSPEND_ROUNDTRIP")" ] || fail "suspend 成功后 active state 应移除"
[ -f "$(snapshot_yaml "$SUSPEND_ROUNDTRIP" original)" ] || fail "suspend 应创建 YAML snapshot"
[ -f "$(snapshot_meta "$SUSPEND_ROUNDTRIP" original)" ] || fail "suspend 应创建 metadata sidecar"
grep -qxF 'docs/superpowers/.workflow-suspended/' "$SUSPEND_ROUNDTRIP/.gitignore" || fail "suspend 应添加精确 ignore"
bash "$WS" --repo "$SUSPEND_ROUNDTRIP" resume original >/dev/null
cmp -s "$ROOT/original-state.yaml" "$(active_state "$SUSPEND_ROUNDTRIP")" || fail "resume 应逐字节恢复原 state"
[ ! -e "$(snapshot_yaml "$SUSPEND_ROUNDTRIP" original)" ] || fail "resume 成功后应删除 YAML snapshot"
[ ! -e "$(snapshot_meta "$SUSPEND_ROUNDTRIP" original)" ] || fail "resume 成功后应删除 metadata sidecar"

# start accepts an absent or completely empty initialized active slot.
START_EMPTY="$(unfinished_repo start-empty parked-task)"
bash "$WS" --repo "$START_EMPTY" suspend parked >/dev/null
bash "$WS" --repo "$START_EMPTY" start next-task L2 >/dev/null
[ "$(getf "$START_EMPTY" task)" = next-task ] || fail "start 应从 absent slot 初始化新任务"
[ "$(getf "$START_EMPTY" phase)" = brainstorm ] || fail "empty-slot start 应从 brainstorm 开始"
INITIALIZED_EMPTY="$(new_repo initialized-empty)"
bash "$WS" --repo "$INITIALIZED_EMPTY" start initialized-task L4 >/dev/null
[ "$(getf "$INITIALIZED_EMPTY" task)" = initialized-task ] || fail "start 应接受完整空模板"

# resume accepts an empty template or a valid sealed intervening task.
RESUME_EMPTY="$(unfinished_repo resume-empty original-empty-task)"
bash "$WS" --repo "$RESUME_EMPTY" suspend parked >/dev/null
bash "$WS" --repo "$RESUME_EMPTY" init >/dev/null
bash "$WS" --repo "$RESUME_EMPTY" resume parked >/dev/null
[ "$(getf "$RESUME_EMPTY" task)" = original-empty-task ] || fail "resume 应接受 init 重建的空模板"

RESUME_SEALED="$(unfinished_repo resume-sealed original-sealed-task)"
bash "$WS" --repo "$RESUME_SEALED" suspend parked >/dev/null
bash "$WS" --repo "$RESUME_SEALED" start intervening L4 >/dev/null
seal_active_l4 "$RESUME_SEALED"
bash "$WS" --repo "$RESUME_SEALED" resume parked >/dev/null
[ "$(getf "$RESUME_SEALED" task)" = original-sealed-task ] || fail "resume 应替换 valid sealed task"
[ "$(getf "$RESUME_SEALED" phase)" = spec ] || fail "resume 应保留原 phase"

# Another unfinished active task protects the slot from start and resume.
ACTIVE_PROTECTION="$(unfinished_repo active-protection parked-owner)"
bash "$WS" --repo "$ACTIVE_PROTECTION" suspend parked >/dev/null
bash "$WS" --repo "$ACTIVE_PROTECTION" start active-owner L2 >/dev/null
cp "$(active_state "$ACTIVE_PROTECTION")" "$ROOT/active-owner.yaml"
expect_fail "unfinished active slot 不得 start 覆盖" bash "$WS" --repo "$ACTIVE_PROTECTION" start overwrite L2
expect_fail "unfinished active slot 不得 resume 覆盖" bash "$WS" --repo "$ACTIVE_PROTECTION" resume parked
cmp -s "$ROOT/active-owner.yaml" "$(active_state "$ACTIVE_PROTECTION")" || fail "失败的 start/resume 不得修改 active state"
[ -f "$(snapshot_yaml "$ACTIVE_PROTECTION" parked)" ] || fail "失败的 resume 不得删除 snapshot"

# Partially populated templates are malformed rather than empty.
PARTIAL_SLOT="$(new_repo partial-slot)"
setf "$PARTIAL_SLOT" task partial-only
cp "$(active_state "$PARTIAL_SLOT")" "$ROOT/partial-slot.yaml"
expect_fail "partial template 不得被 start 当作 empty" bash "$WS" --repo "$PARTIAL_SLOT" start replacement L2
cmp -s "$ROOT/partial-slot.yaml" "$(active_state "$PARTIAL_SLOT")" || fail "失败的 partial-slot start 不得改 state"

PARTIAL_RESUME="$(unfinished_repo partial-resume parked-partial)"
bash "$WS" --repo "$PARTIAL_RESUME" suspend parked >/dev/null
bash "$WS" --repo "$PARTIAL_RESUME" init >/dev/null
setf "$PARTIAL_RESUME" task partial-only
expect_fail "partial template 不得被 resume 当作 empty" bash "$WS" --repo "$PARTIAL_RESUME" resume parked
[ -f "$(snapshot_yaml "$PARTIAL_RESUME" parked)" ] || fail "partial-slot resume 失败应保留 snapshot"

# suspend rejects empty/sealed states and unsafe or duplicate keys before mutation.
EMPTY_SUSPEND="$(new_repo empty-suspend)"
expect_fail "empty state 不得 suspend" bash "$WS" --repo "$EMPTY_SUSPEND" suspend empty
bash "$WS" --repo "$EMPTY_SUSPEND" start sealed-task L4 >/dev/null
seal_active_l4 "$EMPTY_SUSPEND"
expect_fail "sealed state 不得 suspend" bash "$WS" --repo "$EMPTY_SUSPEND" suspend sealed

UNSAFE_KEYS="$(unfinished_repo unsafe-keys unsafe-owner)"
cp "$(active_state "$UNSAFE_KEYS")" "$ROOT/unsafe-owner.yaml"
for key in '' A upperCase ../escape 'a/b' 'a\b' '.hidden' 'a b' 'a;rm' "$(printf 'a%.0s' {1..65})"; do
  expect_fail "unsafe suspend key 应拒绝: $key" bash "$WS" --repo "$UNSAFE_KEYS" suspend "$key"
  cmp -s "$ROOT/unsafe-owner.yaml" "$(active_state "$UNSAFE_KEYS")" || fail "unsafe key 不得修改 active state: $key"
done

DUPLICATE_KEY="$(unfinished_repo duplicate-key original-owner)"
bash "$WS" --repo "$DUPLICATE_KEY" suspend duplicate >/dev/null
bash "$WS" --repo "$DUPLICATE_KEY" start current-owner L2 >/dev/null
cp "$(active_state "$DUPLICATE_KEY")" "$ROOT/duplicate-active.yaml"
expect_fail "existing snapshot pair 不得覆盖" bash "$WS" --repo "$DUPLICATE_KEY" suspend duplicate
cmp -s "$ROOT/duplicate-active.yaml" "$(active_state "$DUPLICATE_KEY")" || fail "duplicate suspend 不得修改 active state"

for partial in yaml meta; do
  PARTIAL_PAIR="$(unfinished_repo "partial-pair-$partial" partial-owner)"
  mkdir -p "$PARTIAL_PAIR/docs/superpowers/.workflow-suspended"
  : > "$PARTIAL_PAIR/docs/superpowers/.workflow-suspended/blocked.$partial"
  cp "$(active_state "$PARTIAL_PAIR")" "$ROOT/partial-pair-$partial.yaml"
  expect_fail "partial snapshot pair 应阻止 key reuse: $partial" bash "$WS" --repo "$PARTIAL_PAIR" suspend blocked
  cmp -s "$ROOT/partial-pair-$partial.yaml" "$(active_state "$PARTIAL_PAIR")" || fail "partial pair 不得造成 active-state loss: $partial"
done

# Tampering, missing sidecars, wrong repositories, and symlinks fail closed.
TAMPER_YAML="$(unfinished_repo tamper-yaml tamper-owner)"
bash "$WS" --repo "$TAMPER_YAML" suspend parked >/dev/null
bash "$WS" --repo "$TAMPER_YAML" init >/dev/null
printf '\n# tampered\n' >> "$(snapshot_yaml "$TAMPER_YAML" parked)"
cp "$(active_state "$TAMPER_YAML")" "$ROOT/tamper-empty.yaml"
expect_fail "tampered snapshot YAML 不得 resume" bash "$WS" --repo "$TAMPER_YAML" resume parked
cmp -s "$ROOT/tamper-empty.yaml" "$(active_state "$TAMPER_YAML")" || fail "tampered YAML 不得替换 active slot"

TAMPER_META="$(unfinished_repo tamper-meta tamper-meta-owner)"
bash "$WS" --repo "$TAMPER_META" suspend parked >/dev/null
bash "$WS" --repo "$TAMPER_META" init >/dev/null
printf 'unknown: value\n' >> "$(snapshot_meta "$TAMPER_META" parked)"
expect_fail "tampered metadata 不得 resume" bash "$WS" --repo "$TAMPER_META" resume parked

for missing in yaml meta; do
  MISSING_PAIR="$(unfinished_repo "missing-$missing" missing-owner)"
  bash "$WS" --repo "$MISSING_PAIR" suspend parked >/dev/null
  rm -f "$MISSING_PAIR/docs/superpowers/.workflow-suspended/parked.$missing"
  bash "$WS" --repo "$MISSING_PAIR" init >/dev/null
  expect_fail "missing snapshot sidecar 应拒绝: $missing" bash "$WS" --repo "$MISSING_PAIR" resume parked
done

WRONG_REPO_SOURCE="$(unfinished_repo wrong-repo-source source-owner)"
bash "$WS" --repo "$WRONG_REPO_SOURCE" suspend parked >/dev/null
WRONG_REPO_TARGET="$(new_repo wrong-repo-target)"
mkdir -p "$WRONG_REPO_TARGET/docs/superpowers/.workflow-suspended"
cp "$(snapshot_yaml "$WRONG_REPO_SOURCE" parked)" "$(snapshot_yaml "$WRONG_REPO_TARGET" parked)"
cp "$(snapshot_meta "$WRONG_REPO_SOURCE" parked)" "$(snapshot_meta "$WRONG_REPO_TARGET" parked)"
expect_fail "copied snapshot 不得跨 repository resume" bash "$WS" --repo "$WRONG_REPO_TARGET" resume parked

SYMLINK_FILE="$(unfinished_repo symlink-file symlink-owner)"
bash "$WS" --repo "$SYMLINK_FILE" suspend parked >/dev/null
cp "$(snapshot_yaml "$SYMLINK_FILE" parked)" "$ROOT/symlink-target.yaml"
rm "$(snapshot_yaml "$SYMLINK_FILE" parked)"
ln -s "$ROOT/symlink-target.yaml" "$(snapshot_yaml "$SYMLINK_FILE" parked)"
bash "$WS" --repo "$SYMLINK_FILE" init >/dev/null
expect_fail "symlinked snapshot file 不得 resume" bash "$WS" --repo "$SYMLINK_FILE" resume parked

SYMLINK_META="$(unfinished_repo symlink-meta symlink-meta-owner)"
bash "$WS" --repo "$SYMLINK_META" suspend parked >/dev/null
cp "$(snapshot_meta "$SYMLINK_META" parked)" "$ROOT/symlink-target.meta"
rm "$(snapshot_meta "$SYMLINK_META" parked)"
ln -s "$ROOT/symlink-target.meta" "$(snapshot_meta "$SYMLINK_META" parked)"
bash "$WS" --repo "$SYMLINK_META" init >/dev/null
expect_fail "symlinked metadata file 不得 resume" bash "$WS" --repo "$SYMLINK_META" resume parked

SYMLINK_DIR="$(unfinished_repo symlink-dir symlink-dir-owner)"
mkdir -p "$ROOT/outside-snapshots"
ln -s "$ROOT/outside-snapshots" "$SYMLINK_DIR/docs/superpowers/.workflow-suspended"
cp "$(active_state "$SYMLINK_DIR")" "$ROOT/symlink-dir-active.yaml"
expect_fail "symlinked snapshot directory 不得 suspend" bash "$WS" --repo "$SYMLINK_DIR" suspend parked
cmp -s "$ROOT/symlink-dir-active.yaml" "$(active_state "$SYMLINK_DIR")" || fail "symlink dir rejection 不得丢 active state"

RESUME_SYMLINK_DIR="$(unfinished_repo resume-symlink-dir resume-symlink-owner)"
bash "$WS" --repo "$RESUME_SYMLINK_DIR" suspend parked >/dev/null
mv "$RESUME_SYMLINK_DIR/docs/superpowers/.workflow-suspended" "$ROOT/real-resume-snapshots"
ln -s "$ROOT/real-resume-snapshots" "$RESUME_SYMLINK_DIR/docs/superpowers/.workflow-suspended"
bash "$WS" --repo "$RESUME_SYMLINK_DIR" init >/dev/null
cp "$(active_state "$RESUME_SYMLINK_DIR")" "$ROOT/resume-symlink-empty.yaml"
expect_fail "symlinked snapshot directory 不得 resume" bash "$WS" --repo "$RESUME_SYMLINK_DIR" resume parked
cmp -s "$ROOT/resume-symlink-empty.yaml" "$(active_state "$RESUME_SYMLINK_DIR")" || fail "resume symlink dir rejection 不得修改 active slot"

SYMLINK_IGNORE="$(unfinished_repo symlink-ignore symlink-ignore-owner)"
printf '%s\n' '# outside ignore' > "$ROOT/outside-gitignore"
rm -f "$SYMLINK_IGNORE/.gitignore"
ln -s "$ROOT/outside-gitignore" "$SYMLINK_IGNORE/.gitignore"
cp "$(active_state "$SYMLINK_IGNORE")" "$ROOT/symlink-ignore-active.yaml"
expect_fail "symlinked .gitignore 不得被 suspend 写入" bash "$WS" --repo "$SYMLINK_IGNORE" suspend parked
cmp -s "$ROOT/symlink-ignore-active.yaml" "$(active_state "$SYMLINK_IGNORE")" || fail ".gitignore symlink rejection 不得丢 active state"
[ "$(cat "$ROOT/outside-gitignore")" = '# outside ignore' ] || fail "suspend 不得写入 symlinked .gitignore target"

# The shared controller lock serializes concurrent suspend attempts for one key.
CONCURRENT_SUSPEND="$(unfinished_repo concurrent-suspend concurrent-owner)"
set +e
bash "$WS" --repo "$CONCURRENT_SUSPEND" suspend same-key >"$ROOT/concurrent-suspend-1.out" 2>"$ROOT/concurrent-suspend-1.err" &
concurrent_pid_1=$!
bash "$WS" --repo "$CONCURRENT_SUSPEND" suspend same-key >"$ROOT/concurrent-suspend-2.out" 2>"$ROOT/concurrent-suspend-2.err" &
concurrent_pid_2=$!
wait "$concurrent_pid_1"; concurrent_rc_1=$?
wait "$concurrent_pid_2"; concurrent_rc_2=$?
set -e
if [ "$concurrent_rc_1" -eq 0 ]; then
  [ "$concurrent_rc_2" -ne 0 ] || fail "concurrent suspend 应只有一个成功"
else
  [ "$concurrent_rc_2" -eq 0 ] || fail "concurrent suspend 应至少一个成功"
fi
[ ! -e "$(active_state "$CONCURRENT_SUSPEND")" ] || fail "成功的 concurrent suspend 应清空 active slot"
[ -f "$(snapshot_yaml "$CONCURRENT_SUSPEND" same-key)" ] && [ -f "$(snapshot_meta "$CONCURRENT_SUSPEND" same-key)" ] || fail "concurrent suspend 应留下一个完整 pair"

# A completed snapshot is not a rollback archive, even if metadata is rehashed.
COMPLETED_SNAPSHOT="$(unfinished_repo completed-snapshot original-owner)"
bash "$WS" --repo "$COMPLETED_SNAPSHOT" suspend parked >/dev/null
bash "$WS" --repo "$COMPLETED_SNAPSHOT" start completed-owner L4 >/dev/null
seal_active_l4 "$COMPLETED_SNAPSHOT"
cp "$(active_state "$COMPLETED_SNAPSHOT")" "$(snapshot_yaml "$COMPLETED_SNAPSHOT" parked)"
completed_sha="$(sha256_file "$(snapshot_yaml "$COMPLETED_SNAPSHOT" parked)")"
python3 - "$(snapshot_meta "$COMPLETED_SNAPSHOT" parked)" "$completed_sha" <<'PY'
import pathlib, re, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
path.write_text(re.sub(r"^state_sha256: .*?$", "state_sha256: " + sys.argv[2], text, flags=re.M), encoding="utf-8")
PY
rm "$(active_state "$COMPLETED_SNAPSHOT")"
bash "$WS" --repo "$COMPLETED_SNAPSHOT" init >/dev/null
expect_fail "completed snapshot 不得 resume" bash "$WS" --repo "$COMPLETED_SNAPSHOT" resume parked

# Ignore management is idempotent across repeated suspend/resume cycles.
IGNORE_IDEMPOTENT="$(unfinished_repo ignore-idempotent ignore-owner)"
bash "$WS" --repo "$IGNORE_IDEMPOTENT" suspend first >/dev/null
bash "$WS" --repo "$IGNORE_IDEMPOTENT" resume first >/dev/null
bash "$WS" --repo "$IGNORE_IDEMPOTENT" suspend second >/dev/null
[ "$(grep -c '^docs/superpowers/\.workflow-suspended/$' "$IGNORE_IDEMPOTENT/.gitignore")" -eq 1 ] || fail "snapshot ignore entry 不得重复"

# Degraded one-reviewer evidence is explicit opt-in for small-fix only.
STANDARD_DEGRADED="$(understanding_repo standard-degraded L2)"
setf "$STANDARD_DEGRADED" context.environment n/a
setf "$STANDARD_DEGRADED" context.delivery local-only
standard_degraded_understanding="$(evidence "$STANDARD_DEGRADED" understanding.txt $'result: PASS\nkind: impact\naffected: one interaction\ntests: focused suite')"
bash "$WS" --repo "$STANDARD_DEGRADED" understand "$standard_degraded_understanding" >/dev/null
setf "$STANDARD_DEGRADED" requirements.external_review true
bash "$WS" --repo "$STANDARD_DEGRADED" understand "$standard_degraded_understanding" >/dev/null
setf "$STANDARD_DEGRADED" phase review
setf "$STANDARD_DEGRADED" evidence.tests "$(evidence "$STANDARD_DEGRADED" tests.txt $'command: focused tests\nexit_code: 0')"
setf "$STANDARD_DEGRADED" evidence.residual_risks "$(evidence "$STANDARD_DEGRADED" risks.txt 'risk: second reviewer did not finish')"
standard_degraded_fingerprint="$(python3 "$RUNNER" --fingerprint --cd "$STANDARD_DEGRADED")"
standard_degraded_path="$(degraded_review_evidence "$STANDARD_DEGRADED" degraded.json "$standard_degraded_fingerprint" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')")"
setf "$STANDARD_DEGRADED" evidence.external_review "$standard_degraded_path"
expect_fail "standard profile 不得接受 one-success degraded review" bash "$WS" --repo "$STANDARD_DEGRADED" complete
setf "$STANDARD_DEGRADED" execution.profile small-fix
python3 - "$STANDARD_DEGRADED/$standard_degraded_path" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path))
data["reviewers"][1]["family"] = "google"
with open(path, "w") as handle:
    json.dump(data, handle)
PY
expect_fail "small-fix degraded review 仍须校验所有 reviewer family/status" bash "$WS" --repo "$STANDARD_DEGRADED" complete
standard_degraded_path="$(degraded_review_evidence "$STANDARD_DEGRADED" degraded.json "$standard_degraded_fingerprint" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')")"
bash "$WS" --repo "$STANDARD_DEGRADED" complete >/dev/null
[ "$(getf "$STANDARD_DEGRADED" phase)" = done ] || fail "small-fix 应接受有效 one-success degraded review"

# Business completion requires a real environment and real-request evidence.
BUSINESS="$(new_repo business)"
setf "$BUSINESS" task auth-closeout
setf "$BUSINESS" level L2
setf "$BUSINESS" context.target /login
setf "$BUSINESS" context.sources openapi-and-acceptance
setf "$BUSINESS" context.environment mock
setf "$BUSINESS" context.delivery local-only
setf "$BUSINESS" requirements.business true
business_understanding="$(evidence "$BUSINESS" understanding.txt $'result: PASS\nkind: impact\naffected: auth guards and requests\ntests: business and request evidence')"
bash "$WS" --repo "$BUSINESS" understand "$business_understanding" >/dev/null
setf "$BUSINESS" phase business-verify
setf "$BUSINESS" evidence.tests "$(evidence "$BUSINESS" tests.txt $'command: pnpm typecheck && pnpm test\nexit_code: 0')"
setf "$BUSINESS" evidence.business "$(evidence "$BUSINESS" business.txt $'result: PASS\nguards: logged-out, logged-in, deep-link, 401')"
setf "$BUSINESS" evidence.requests "$(evidence "$BUSINESS" requests.txt $'result: PASS\nmethod: POST\nurl: /auth/login\nstatus: 200')"
setf "$BUSINESS" evidence.codegraph "$(evidence "$BUSINESS" codegraph.txt 'result: risk=0.40; gaps reviewed')"
setf "$BUSINESS" evidence.residual_risks "$(evidence "$BUSINESS" risks.txt 'risk: none')"
expect_fail "mock 业务环境不得完成" bash "$WS" --repo "$BUSINESS" complete
setf "$BUSINESS" context.environment real
expect_fail "业务闭环必须强制 external_review=true" bash "$WS" --repo "$BUSINESS" complete
setf "$BUSINESS" requirements.external_review true
bash "$WS" --repo "$BUSINESS" understand "$business_understanding" >/dev/null
setf "$BUSINESS" evidence.external_review ""
expect_fail "缺外部评审证据不得完成" bash "$WS" --repo "$BUSINESS" complete
setf "$BUSINESS" evidence.external_review "$(evidence "$BUSINESS" invalid-review.json not-json)"
if bash "$WS" --repo "$BUSINESS" complete >"$ROOT/invalid.out" 2>"$ROOT/invalid.err"; then
  fail "损坏的评审 JSON 不得完成"
fi
if grep -q Traceback "$ROOT/invalid.err"; then fail "损坏 JSON 应返回干净错误而非 traceback"; fi
fingerprint="$(python3 "$RUNNER" --fingerprint --cd "$BUSINESS")"
created_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
review_path="$(review_evidence "$BUSINESS" absolute-review.json "$fingerprint" "$created_at")"
setf "$BUSINESS" evidence.external_review "$BUSINESS/$review_path"
expect_fail "外部评审证据不得引用仓库外或绝对路径" bash "$WS" --repo "$BUSINESS" complete
setf "$BUSINESS" evidence.external_review "$(review_evidence "$BUSINESS" wrong-repo.json "$(printf 'b%.0s' {1..64})" "$created_at")"
expect_fail "错误仓库 fingerprint 的评审证据不得完成" bash "$WS" --repo "$BUSINESS" complete
setf "$BUSINESS" evidence.external_review "$(review_evidence "$BUSINESS" stale-review.json "$fingerprint" '2000-01-01T00:00:00Z')"
expect_fail "过期评审证据不得完成" bash "$WS" --repo "$BUSINESS" complete
no_message="$(review_evidence "$BUSINESS" no-message.json "$fingerprint" "$created_at")"
python3 - "$BUSINESS/$no_message" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path))
data["reviewers"][0]["agent_messages"] = ""
data["reviewers"][1]["family"] = "google"
with open(path, "w") as handle:
    json.dump(data, handle)
PY
setf "$BUSINESS" evidence.external_review "$no_message"
expect_fail "reviewer 必须有非空输出且 agent-family 映射真实" bash "$WS" --repo "$BUSINESS" complete
setf "$BUSINESS" evidence.external_review "$(review_evidence "$BUSINESS" cross-review.json "$fingerprint" "$created_at")"
setf "$BUSINESS" evidence.business "$(evidence "$BUSINESS" business-fail.txt $'result: FAIL\nguards: login regression')"
expect_fail "业务证据 result: FAIL 不得完成" bash "$WS" --repo "$BUSINESS" complete
setf "$BUSINESS" evidence.business "$(evidence "$BUSINESS" business-conflict.txt $'result: FAIL\nresult: PASS\nguards: conflicting verdicts')"
expect_fail "业务证据同时包含 FAIL/PASS 不得完成" bash "$WS" --repo "$BUSINESS" complete
setf "$BUSINESS" evidence.business "$(evidence "$BUSINESS" business.txt $'result: PASS\nguards: logged-out, logged-in, deep-link, 401')"
setf "$BUSINESS" evidence.requests "$(evidence "$BUSINESS" requests-fail.txt $'result: FAIL\nmethod: POST\nurl: /auth/login\nstatus: 500')"
expect_fail "请求证据 result: FAIL 不得完成" bash "$WS" --repo "$BUSINESS" complete
setf "$BUSINESS" evidence.requests "$(evidence "$BUSINESS" requests.txt $'result: PASS\nmethod: POST\nurl: /auth/login\nstatus: 200')"
bash "$WS" --repo "$BUSINESS" complete >/dev/null
[ "$(getf "$BUSINESS" phase)" = "done" ] || fail "business complete 应进入 done"
[ -n "$(getf "$BUSINESS" completion.completed_at)" ] || fail "complete 应记录 completed_at seal"
[ -n "$(getf "$BUSINESS" completion.requirements_sha256)" ] || fail "complete 应封存 requirements hash"
expect_fail "封存后不得关闭 external review requirement" bash "$WS" --repo "$BUSINESS" set requirements.external_review false
printf '%s\n' 'next task change' > "$BUSINESS/new-task.txt"
bash "$WS" --repo "$BUSINESS" check | grep -q 'phase=done' || fail "done 状态不应因后续代码变化失效"
python3 - "$BUSINESS/docs/superpowers/.workflow-state.yaml" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
path.write_text(path.read_text().replace("phase: done", "phase: review"), encoding="utf-8")
PY
expect_fail "存在 completion seal 时不得通过手改 phase 跳过 sealed check" bash "$WS" --repo "$BUSINESS" check
python3 - "$BUSINESS/docs/superpowers/.workflow-state.yaml" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text().replace("phase: review", "phase: done")
path.write_text(text.replace("external_review: true", "external_review: false", 1), encoding="utf-8")
PY
expect_fail "requirements 手工降级不得通过 seal 校验" bash "$WS" --repo "$BUSINESS" check

# Fidelity tasks must be in the matching phase and carry fidelity evidence.
FIDELITY="$(new_repo fidelity)"
setf "$FIDELITY" task visual-alignment
setf "$FIDELITY" level L1
setf "$FIDELITY" context.target /consultation
setf "$FIDELITY" context.sources figma-node
setf "$FIDELITY" context.environment real
setf "$FIDELITY" context.delivery local-only
setf "$FIDELITY" requirements.fidelity true
fidelity_understanding="$(evidence "$FIDELITY" understanding.txt $'result: PASS\nkind: requirements\nacceptance: match design measurements\nnon_goals: redesign')"
bash "$WS" --repo "$FIDELITY" understand "$fidelity_understanding" >/dev/null
setf "$FIDELITY" phase fidelity-verify
setf "$FIDELITY" evidence.tests "$(evidence "$FIDELITY" tests.txt $'command: visual tests\nexit_code: 0')"
setf "$FIDELITY" evidence.residual_risks "$(evidence "$FIDELITY" risks.txt 'risk: none')"
expect_fail "缺 fidelity 证据不得完成" bash "$WS" --repo "$FIDELITY" complete
setf "$FIDELITY" evidence.fidelity "$(evidence "$FIDELITY" fidelity-fail.txt 'result: FAIL')"
expect_fail "保真证据 result: FAIL 不得完成" bash "$WS" --repo "$FIDELITY" complete
setf "$FIDELITY" evidence.fidelity "$(evidence "$FIDELITY" fidelity.txt 'result: PASS')"
bash "$WS" --repo "$FIDELITY" complete >/dev/null
[ "$(getf "$FIDELITY" phase)" = "done" ] || fail "fidelity complete 应进入 done"

SKILL="$HERE/skills/dev-workflow/SKILL.md"
grep -q 'workflow-state.sh.*complete' "$SKILL" || fail "dev-workflow 应要求 complete 完成门"
grep -q 'start <task> <level>' "$SKILL" || fail "dev-workflow 应说明 sealed 后的新任务入口"
grep -q 'requirements_sha256' "$SKILL" || fail "dev-workflow 应说明 requirements seal"
grep -q '理解度 = PASS' "$SKILL" || fail "dev-workflow 应声明可见理解度输出"
grep -q '目标续行 = 第' "$SKILL" || fail "dev-workflow 应声明 Goal 续行输出"
grep -q 'continue-goal' "$SKILL" || fail "dev-workflow 应说明 Goal 续行命令"
grep -q '不得.*创建 Goal' "$SKILL" || fail "dev-workflow 应禁止自行创建 Goal"
grep -q 'objective.*变化.*pending' "$SKILL" || fail "dev-workflow 应说明目标变化使理解度失效"
grep -q '提案者.*反方审查者.*裁决者' "$SKILL" || fail "dev-workflow 应声明三段式自治确认"
grep -q 'PASS.*REVISE.*BLOCKED' "$SKILL" || fail "dev-workflow 应声明自治确认三种结果"
grep -q 'external-cross-review.*same-model-fresh-context.*built-in-checklist' "$SKILL" || fail "dev-workflow 应声明 reviewer provenance"
grep -q '删除数据.*强制推送.*发布.*部署.*付费.*凭证' "$SKILL" || fail "dev-workflow 应声明不可自治边界"
grep -q '不得.*用户已确认' "$SKILL" || fail "dev-workflow 应禁止伪称用户确认"
grep -q 'workflow-state.sh confirm' "$SKILL" || fail "dev-workflow 应说明 confirmation 命令"
grep -q 'suspend <key>' "$SKILL" || fail "dev-workflow 应说明 suspend 命令"
grep -q 'resume <key>' "$SKILL" || fail "dev-workflow 应说明 resume 命令"
grep -q 'suspend.*start.*resume' "$SKILL" || fail "dev-workflow 应说明合法任务切换顺序"
grep -q 'SELF_HOSTING_CONTROLLER' "$SKILL" || fail "dev-workflow 应前置自举 controller 规则"
grep -q 'understand.*之前.*禁止.*文件修改' "$SKILL" || fail "dev-workflow 应前置 understanding 写入硬门"
grep -q 'set phase tdd.*之前.*测试' "$SKILL" || fail "dev-workflow 应前置 TDD phase 硬门"
grep -q 'small-fix' "$SKILL" || fail "dev-workflow 应声明 small-fix 快速通道"
grep -q 'reuses:' "$SKILL" || fail "dev-workflow 应说明同目标 understanding 证据复用"
grep -q 'checkpoint commit' "$SKILL" || fail "dev-workflow 应说明 business verify 不阻塞本地 checkpoint commit"
grep -q '状态变化' "$SKILL" || fail "dev-workflow 应禁止无信息固定频率状态刷屏"
if grep -q '仅 L0/L1 需要维护' "$SKILL"; then fail "高风险 L2/L3 不得跳过状态机"; fi
if grep -q 'L2–L4 太短，可跳过' "$SKILL"; then fail "高风险 L2/L3 不得被短任务豁免"; fi
grep -q 'workflow-state.sh suspend' "$HERE/README.md" || fail "README 应说明 suspend 命令"
grep -q 'workflow-state.sh resume' "$HERE/README.md" || fail "README 应说明 resume 命令"
grep -qxF 'docs/superpowers/.workflow-suspended/' "$HERE/.gitignore" || fail "仓库应忽略 suspended snapshots"
echo "PASS tests/workflow-state.sh"
