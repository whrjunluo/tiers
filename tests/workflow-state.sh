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
expect_fail(){
  local msg="$1"; shift
  if "$@" >/dev/null 2>&1; then fail "$msg"; fi
}

# check should be harmless before init; a new repo simply has no resumable state.
EMPTY="$ROOT/empty"
mkdir -p "$EMPTY"
bash "$WS" --repo "$EMPTY" check | grep -q "无续行状态" || fail "未初始化 check 应提示无续行状态"

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
[ "$(getf "$REPO" understanding.status)" = pending ] || fail "新状态应默认 pending understanding"
[ "$(getf "$REPO" completion.workflow_version)" = 2 ] || fail "新状态应使用 workflow v2"

setf "$REPO" phase spec
[ "$(getf "$REPO" phase)" = "spec" ] || fail "set/get phase"
setf "$REPO" requirements.fidelity true
[ "$(getf "$REPO" requirements.fidelity)" = "true" ] || fail "set/get nested field"
task_with_yaml_syntax="Fix #123: Bob's login"
setf "$REPO" task "$task_with_yaml_syntax"
[ "$(getf "$REPO" task)" = "$task_with_yaml_syntax" ] || fail "set/get 应保留 #、冒号和单引号"

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

# check: illegal phase should error
expect_fail "非法 phase 应拒绝" bash "$WS" --repo "$REPO" set phase 乱写

# Direct done is never legal; completion must go through the evidence gate.
expect_fail "set phase done 应拒绝" bash "$WS" --repo "$REPO" set phase done

# Standard completion requires the context manifest plus test/risk evidence.
STANDARD="$(new_repo standard)"
setf "$STANDARD" task standard-change
setf "$STANDARD" level L2
setf "$STANDARD" phase review
setf "$STANDARD" context.target scripts/workflow-state.sh
setf "$STANDARD" context.sources user-request
setf "$STANDARD" context.environment n/a
setf "$STANDARD" context.delivery local-only
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

# Business completion requires a real environment and real-request evidence.
BUSINESS="$(new_repo business)"
setf "$BUSINESS" task auth-closeout
setf "$BUSINESS" level L2
setf "$BUSINESS" phase business-verify
setf "$BUSINESS" context.target /login
setf "$BUSINESS" context.sources openapi-and-acceptance
setf "$BUSINESS" context.environment mock
setf "$BUSINESS" context.delivery local-only
setf "$BUSINESS" requirements.business true
setf "$BUSINESS" evidence.tests "$(evidence "$BUSINESS" tests.txt $'command: pnpm typecheck && pnpm test\nexit_code: 0')"
setf "$BUSINESS" evidence.business "$(evidence "$BUSINESS" business.txt $'result: PASS\nguards: logged-out, logged-in, deep-link, 401')"
setf "$BUSINESS" evidence.requests "$(evidence "$BUSINESS" requests.txt $'result: PASS\nmethod: POST\nurl: /auth/login\nstatus: 200')"
setf "$BUSINESS" evidence.codegraph "$(evidence "$BUSINESS" codegraph.txt 'result: risk=0.40; gaps reviewed')"
setf "$BUSINESS" evidence.residual_risks "$(evidence "$BUSINESS" risks.txt 'risk: none')"
expect_fail "mock 业务环境不得完成" bash "$WS" --repo "$BUSINESS" complete
setf "$BUSINESS" context.environment real
expect_fail "业务闭环必须强制 external_review=true" bash "$WS" --repo "$BUSINESS" complete
setf "$BUSINESS" requirements.external_review true
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
setf "$FIDELITY" phase fidelity-verify
setf "$FIDELITY" context.target /consultation
setf "$FIDELITY" context.sources figma-node
setf "$FIDELITY" context.environment real
setf "$FIDELITY" context.delivery local-only
setf "$FIDELITY" requirements.fidelity true
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
if grep -q '仅 L0/L1 需要维护' "$SKILL"; then fail "高风险 L2/L3 不得跳过状态机"; fi
if grep -q 'L2–L4 太短，可跳过' "$SKILL"; then fail "高风险 L2/L3 不得被短任务豁免"; fi
echo "PASS tests/workflow-state.sh"
