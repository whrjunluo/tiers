#!/usr/bin/env bash
# 续行状态独占接口（学 Comet comet-state.sh）。SKILL.md 只调本脚本，禁手改 YAML。
# 用法: workflow-state.sh [--repo R] {init|start <task> <level>|goal <objective>|continue-goal <objective>|understand <evidence>|confirm <json>|get <field>|set <field> <value>|check|complete}
set -euo pipefail
# 复用 lib.sh 的 dw_plugin_root（单一来源），避免与各脚本重复维护 env 优先级链
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

REPO="$PWD"
if [ "${1:-}" = "--repo" ]; then REPO="$2"; shift 2; fi
STATE="$REPO/docs/superpowers/.workflow-state.yaml"
STATE_LOCK_ROOT="${DEV_WORKFLOW_STATE_LOCK_ROOT:-${TMPDIR:-/tmp}/dev-workflow-state-${UID}}"
STATE_LOCK_ID="$(printf '%s' "$STATE" | cksum | awk '{print $1 "-" $2}')"
STATE_LOCK="$STATE_LOCK_ROOT/$STATE_LOCK_ID.lock"
STATE_LOCK_TIMEOUT_SECONDS=5

VALID_PHASES="brainstorm grill spec plan tdd review business-verify fidelity-verify done"
VALID_LEVELS="L0 L1 L2 L3 L4"
VALID_BOOLEANS="true false"
VALID_ENVIRONMENTS="real mock n/a"
VALID_UNDERSTANDING_STATUSES="pending passed blocked not-required"
VALID_UNDERSTANDING_KINDS="architecture requirements impact root-cause"
VALID_CONFIRMATION_STATUSES="pending passed blocked"
VALID_FIELDS="task level phase updated next context.repo context.branch context.target context.sources context.environment context.delivery execution.checkpoint requirements.business requirements.fidelity requirements.external_review artifacts.spec artifacts.plan evidence.tests evidence.business evidence.requests evidence.codegraph evidence.external_review evidence.fidelity evidence.residual_risks"

die(){ echo "✗ $1" >&2; exit 1; }
in_list(){ printf '%s\n' $2 | grep -qxF "$1"; }
is_empty_value(){ [ -z "$1" ] || [ "$1" = '""' ] || [ "$1" = "''" ]; }

release_state_lock(){
  local owner=""
  [ -f "$STATE_LOCK/owner" ] && owner="$(awk 'NR==1{print;exit}' "$STATE_LOCK/owner" 2>/dev/null || true)"
  if [ "$owner" = "$$" ]; then
    rm -f "$STATE_LOCK/owner"
    rmdir "$STATE_LOCK" 2>/dev/null || true
  fi
}

acquire_state_lock(){
  local started owner
  mkdir -p "$(dirname "$STATE_LOCK")"
  started=$SECONDS
  while ! mkdir "$STATE_LOCK" 2>/dev/null; do
    owner=""
    [ -f "$STATE_LOCK/owner" ] && owner="$(awk 'NR==1{print;exit}' "$STATE_LOCK/owner" 2>/dev/null || true)"
    if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
      rm -f "$STATE_LOCK/owner"
      rmdir "$STATE_LOCK" 2>/dev/null || true
      continue
    fi
    [ $((SECONDS - started)) -lt "$STATE_LOCK_TIMEOUT_SECONDS" ] || die "等待 workflow state lock 超时: $STATE_LOCK"
    sleep 0.05
  done
  printf '%s\n' "$$" > "$STATE_LOCK/owner"
  trap release_state_lock EXIT INT TERM
}

decode_yaml_scalar(){
  local value="$1" apostrophe="'"
  case "$value" in
    \'*\') value="${value#\'}"; value="${value%\'}"; value="${value//\'\'/$apostrophe}" ;;
    \"*\") value="${value#\"}"; value="${value%\"}" ;;
  esac
  printf '%s\n' "$value"
}

yget(){ # top-level or one-level section.key value extraction
  local k="$1" raw
  case "$k" in
    *.*)
      local section="${k%%.*}" key="${k#*.}"
      raw="$(awk -v section="$section" -v key="$key" '
        $0==section":"{f=1;next}
        f&&$0!~/^[[:space:]]/{f=0}
        f&&$1==key":"{
          sub(/^[[:space:]]*[^:]+:[[:space:]]*/,"")
          if(substr($0,1,1)!=sprintf("%c",39)) sub(/[[:space:]]+#.*$/,"")
          print;exit
        }
      ' "$STATE")" ;;
    *) raw="$(awk -v k="$k" '
      $1==k":"{
        sub(/^[^:]+:[[:space:]]*/,"")
        if(substr($0,1,1)!=sprintf("%c",39)) sub(/[[:space:]]+#.*$/,"")
        print;exit
      }
    ' "$STATE")" ;;
  esac
  decode_yaml_scalar "$raw"
}

encode_yaml_scalar(){
  local field="$1" value="$2"
  case "$field" in
    level|phase|updated|requirements.*|context.environment|completion.*|execution.mode|execution.continuation|understanding.status|confirmation.mode|confirmation.status)
      printf '%s\n' "$value"
      ;;
    *)
      value="${value//\'/\'\'}"
      printf "'%s'\n" "$value"
      ;;
  esac
}

write_field(){
  local field="$1" value="$2" encoded_value today tmp
  encoded_value="$(encode_yaml_scalar "$field" "$value")"
  today="$(date +%F)"
  tmp="$(mktemp)"
  if ! awk -v field="$field" -v value="$encoded_value" -v today="$today" '
    BEGIN {
      nested=(index(field,".")>0)
      if(nested){section=substr(field,1,index(field,".")-1); key=substr(field,index(field,".")+1)}
    }
    {
      line=$0
      if(nested && $0==section ":"){insection=1}
      else if(insection && $0!~/^[[:space:]]/){insection=0}

      if(nested && insection && $1==key ":"){
        line="  " key ": " value
        set_done=1
      } else if(!nested && $1==field ":"){
        line=field ": " value
        set_done=1
      }

      if($1=="updated:" && field!="updated"){line="updated: " today}
      print line
    }
    END {if(!set_done) exit 2}
  ' "$STATE" > "$tmp"; then
    rm -f "$tmp"
    die "状态模板缺少字段 $field"
  fi
  mv "$tmp" "$STATE"
}

append_template_section(){
  local section="$1"
  grep -q "^${section}:$" "$STATE" && return
  printf '\n' >> "$STATE"
  awk -v section="$section" '
    $0==section ":" {copy=1}
    copy {
      if(seen && $0!~/^[[:space:]]/) exit
      print
      seen=1
    }
  ' "$PLUGIN_ROOT/templates/workflow-state.yaml" >> "$STATE"
}

ensure_schema(){
  local sealed_at workflow_version
  sealed_at="$(yget completion.completed_at)"
  workflow_version="$(yget completion.workflow_version)"
  append_template_section context
  append_template_section execution
  append_template_section understanding
  append_template_section confirmation
  append_template_section requirements
  append_template_section evidence
  append_template_section completion
  if is_empty_value "$workflow_version"; then
    if is_empty_value "$sealed_at"; then
      ensure_nested_field completion workflow_version 2
    else
      ensure_nested_field completion workflow_version 1
    fi
  fi
  ensure_nested_field completion requirements_sha256 '""'
}

ensure_nested_field(){
  local section="$1" key="$2" default_value="$3" tmp
  if awk -v section="$section" -v key="$key" '
    $0==section ":" {inside=1; next}
    inside && $0!~/^[[:space:]]/ {exit}
    inside && $1==key ":" {found=1; exit}
    END {exit(found ? 0 : 1)}
  ' "$STATE"; then
    return
  fi
  tmp="$(mktemp)"
  awk -v section="$section" -v key="$key" -v value="$default_value" '
    $0==section ":" {inside=1}
    inside && $0!~/^[[:space:]]/ && $0!=section ":" && !inserted {
      print "  " key ": " value
      inserted=1
      inside=0
    }
    {print}
    END {if(inside && !inserted) print "  " key ": " value}
  ' "$STATE" > "$tmp"
  mv "$tmp" "$STATE"
}

errors=""
add_error(){ errors="${errors}${errors:+; }$1"; }

require_value(){
  local field="$1" value
  value="$(yget "$field")"
  if is_empty_value "$value"; then
    add_error "缺少 $field"
  fi
}

evidence_path(){
  local value="$1"
  printf '%s/%s\n' "$REPO" "$value"
}

valid_evidence_reference(){
  local value="$1"
  case "$value" in
    docs/superpowers/.workflow-evidence/*) ;;
    *) return 1 ;;
  esac
  case "/$value/" in
    *"/../"*|*"/./"*) return 1 ;;
  esac
  return 0
}

requirements_sha256(){
  {
    for field in requirements.business requirements.fidelity requirements.external_review; do
      printf '%s\0%s\0' "$field" "$(yget "$field")"
    done
  } | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'
}

scope_sha256(){
  {
    for field in task level context.target context.sources requirements.business requirements.fidelity requirements.external_review execution.mode execution.objective_sha256 context.branch execution.base_revision; do
      printf '%s\0%s\0' "$field" "$(yget "$field")"
    done
  } | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'
}

file_sha256(){
  python3 - "$1" <<'PY'
import hashlib, sys
with open(sys.argv[1], "rb") as handle:
    print(hashlib.sha256(handle.read()).hexdigest())
PY
}

text_sha256(){
  printf '%s' "$1" | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'
}

understanding_kind_for_level(){
  case "$1" in
    L0) printf '%s\n' architecture ;;
    L1) printf '%s\n' requirements ;;
    L2) printf '%s\n' impact ;;
    L3) printf '%s\n' root-cause ;;
    L4) printf '%s\n' not-required ;;
    *) return 1 ;;
  esac
}

evidence_scalar(){
  local key="$1" path="$2"
  awk -v key="$key" '$1==key":"{sub(/^[^:]+:[[:space:]]*/,"");print;exit}' "$path"
}

reset_understanding(){
  local status="${1:-pending}"
  write_field understanding.status "$status"
  write_field understanding.kind ""
  write_field understanding.evidence ""
  write_field understanding.evidence_sha256 ""
  write_field understanding.scope_sha256 ""
}

reset_confirmation(){
  local status="${1:-pending}"
  write_field confirmation.mode ""
  write_field confirmation.status "$status"
  write_field confirmation.evidence ""
  write_field confirmation.decision_sha256 ""
}

validate_understanding_evidence(){
  local level="$1" path="$2" expected_kind actual_kind key
  expected_kind="$(understanding_kind_for_level "$level")" || add_error "无法识别 understanding level: $level"
  require_single_pass_result understanding "$path"
  actual_kind="$(evidence_scalar kind "$path")"
  [ "$actual_kind" = "$expected_kind" ] || add_error "understanding kind 应为 ${expected_kind}，当前为 ${actual_kind:-空}"
  case "$level" in
    L0) required_keys="boundaries migration rollback" ;;
    L1) required_keys="acceptance non_goals" ;;
    L2) required_keys="affected tests" ;;
    L3) required_keys="reproduction root_cause" ;;
    *) required_keys="" ;;
  esac
  for key in $required_keys; do
    grep -qE "^${key}:[[:space:]]*[^[:space:]]" "$path" || add_error "understanding 缺 ${key}:"
  done
}

require_single_pass_result(){
  local field="$1" path="$2" count
  count="$(grep -cE '^result:' "$path" || true)"
  if [ "$count" -ne 1 ] || ! grep -qE '^result:[[:space:]]*PASS[[:space:]]*$' "$path"; then
    add_error "$field 必须且只能包含一个 result: PASS"
  fi
}

validate_evidence_shape(){
  local field="$1" path="$2"
  case "$field" in
    evidence.tests)
      grep -qE '^command:[[:space:]]*[^[:space:]]' "$path" || add_error "$field 缺 command:"
      grep -qE '^exit_code:[[:space:]]*0[[:space:]]*$' "$path" || add_error "$field 缺 exit_code: 0"
      ;;
    evidence.business)
      require_single_pass_result "$field" "$path"
      ;;
    evidence.requests)
      require_single_pass_result "$field" "$path"
      grep -qE '^method:[[:space:]]*[^[:space:]]' "$path" || add_error "$field 缺 method:"
      grep -qE '^url:[[:space:]]*[^[:space:]]' "$path" || add_error "$field 缺 url:"
      grep -qE '^status:[[:space:]]*[0-9]{3}[[:space:]]*$' "$path" || add_error "$field 缺三位 status:"
      ;;
    evidence.codegraph)
      grep -qE '^(result|degraded):[[:space:]]*[^[:space:]]' "$path" || add_error "$field 缺 result: 或 degraded:"
      ;;
    evidence.fidelity)
      require_single_pass_result "$field" "$path"
      ;;
    evidence.residual_risks)
      if ! grep -qE '^risk:[[:space:]]*[^[:space:]]' "$path"; then
        add_error "$field 缺 risk:"
      else
        risk_value="$(awk -F: '$1=="risk"{sub(/^[^:]+:[[:space:]]*/,"");print;exit}' "$path" | tr '[:upper:]' '[:lower:]' | sed 's/[[:space:]]*$//')"
        case "$risk_value" in
          done|ok|pass|todo|tbd|n/a|na) add_error "$field 不能使用占位值: $risk_value" ;;
        esac
      fi
      ;;
  esac
}

require_evidence_file(){
  local field="$1" value path
  value="$(yget "$field")"
  if is_empty_value "$value"; then
    add_error "缺少 $field"
    return
  fi
  if ! valid_evidence_reference "$value"; then
    add_error "$field 必须位于 docs/superpowers/.workflow-evidence/ 且不得包含 ..: $value"
    return
  fi
  path="$(evidence_path "$value")"
  if [ ! -s "$path" ]; then
    add_error "$field 证据文件不存在或为空: $value"
    return
  fi
  validate_evidence_shape "$field" "$path"
}

validate_external_review(){
  local mode="${1:-current}" value path expected_fingerprint reference_time
  value="$(yget evidence.external_review)"
  if is_empty_value "$value"; then
    add_error "缺少 evidence.external_review"
    return
  fi
  if ! valid_evidence_reference "$value"; then
    add_error "evidence.external_review 必须位于 docs/superpowers/.workflow-evidence/ 且不得包含 ..: $value"
    return
  fi
  path="$(evidence_path "$value")"
  if [ ! -s "$path" ]; then
    add_error "evidence.external_review 证据文件不存在或为空: $value"
    return
  fi
  if [ "$mode" = current ]; then
    if ! expected_fingerprint="$(python3 "$PLUGIN_ROOT/scripts/external_agent.py" --fingerprint --cd "$REPO" 2>/dev/null)"; then
      add_error "无法计算当前 repository fingerprint"
      return
    fi
    reference_time="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  else
    expected_fingerprint="$(yget completion.repository_fingerprint)"
    reference_time="$(yget completion.completed_at)"
  fi
  if ! python3 - "$path" "$expected_fingerprint" "$reference_time" <<'PY'
from datetime import datetime, timezone
import json
import re
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        data = json.load(fh)
except (OSError, json.JSONDecodeError):
    raise SystemExit(1)

current_fingerprint = sys.argv[2]
reference_raw = sys.argv[3]
families = data.get("successful_families") or []
reviewers = data.get("reviewers") or []
known_families = {
    "codex": "openai", "gemini": "google", "mimo": "xiaomi",
    "cursor": "cursor", "cursor-agent": "cursor", "grok": "xai",
    "opencode": "configurable", "antigravity": "google", "agy": "google",
}
artifact = data.get("artifact_sha256") or ""
repository = data.get("repository_fingerprint") or ""
created_raw = data.get("created_at") or ""
try:
    created = datetime.fromisoformat(created_raw.replace("Z", "+00:00"))
    reference = datetime.fromisoformat(reference_raw.replace("Z", "+00:00"))
    age = (reference - created).total_seconds()
except (TypeError, ValueError):
    age = -999999
successful = [
    reviewer for reviewer in reviewers
    if reviewer.get("success") is True
    and known_families.get(reviewer.get("agent")) == reviewer.get("family")
    and isinstance(reviewer.get("agent_messages"), str)
    and reviewer["agent_messages"].strip()
    and isinstance(reviewer.get("timeout_seconds"), int)
    and reviewer["timeout_seconds"] > 0
]
computed_families = {reviewer["family"] for reviewer in successful}
valid = (
    data.get("runner") == "tiers.external-agent/v1"
    and data.get("success") is True
    and data.get("quorum") is True
    and re.fullmatch(r"[0-9a-f]{64}", artifact) is not None
    and repository == current_fingerprint
    and re.fullmatch(r"[0-9a-f]{64}", repository) is not None
    and -300 <= age <= 86400
    and set(families) == computed_families
    and len(set(families)) >= 2
    and len(successful) >= 2
    and len(computed_families) >= 2
)
raise SystemExit(0 if valid else 1)
PY
  then
    add_error "evidence.external_review 不是封存仓库 24h 内的有效双家族 quorum JSON: $value"
  fi
}

is_execution_phase(){
  case "$1" in
    tdd|review|business-verify|fidelity-verify) return 0 ;;
    *) return 1 ;;
  esac
}

validate_understanding_gate(){
  local version level status kind expected_kind value path expected_evidence_sha current_evidence_sha expected_scope current_scope
  version="$(yget completion.workflow_version)"
  [ "$version" != 1 ] || return 0
  level="$(yget level)"
  status="$(yget understanding.status)"
  if [ "$level" = L4 ]; then
    [ "$status" = not-required ] || add_error "L4 understanding.status 应为 not-required"
    return
  fi
  in_list "$level" "L0 L1 L2 L3" || { add_error "understanding gate 缺合法 level"; return; }
  [ "$status" = passed ] || add_error "understanding.status 应为 passed，当前为 ${status:-空}"
  expected_kind="$(understanding_kind_for_level "$level")"
  kind="$(yget understanding.kind)"
  [ "$kind" = "$expected_kind" ] || add_error "understanding.kind 应为 ${expected_kind}，当前为 ${kind:-空}"
  value="$(yget understanding.evidence)"
  if is_empty_value "$value" || ! valid_evidence_reference "$value"; then
    add_error "understanding.evidence 引用非法: ${value:-空}"
    return
  fi
  path="$(evidence_path "$value")"
  if [ ! -s "$path" ]; then
    add_error "understanding.evidence 不存在或为空: $value"
    return
  fi
  validate_understanding_evidence "$level" "$path"
  expected_evidence_sha="$(yget understanding.evidence_sha256)"
  current_evidence_sha="$(file_sha256 "$path")"
  [ "$expected_evidence_sha" = "$current_evidence_sha" ] || add_error "understanding evidence 内容已变化"
  expected_scope="$(yget understanding.scope_sha256)"
  current_scope="$(scope_sha256)"
  [ "$expected_scope" = "$current_scope" ] || add_error "understanding scope 已变化，需重新评估"
}

validate_confirmation_gate(){
  local version level mode status value path expected_sha current_sha scope output
  version="$(yget completion.workflow_version)"
  [ "$version" != 1 ] || return 0
  [ "$(yget execution.mode)" = goal ] || return 0
  level="$(yget level)"
  [ "$level" != L4 ] || return 0
  mode="$(yget confirmation.mode)"
  status="$(yget confirmation.status)"
  [ "$mode" = autonomous ] || add_error "Goal confirmation.mode 应为 autonomous，当前为 ${mode:-空}"
  [ "$status" = passed ] || add_error "Goal confirmation.status 应为 passed，当前为 ${status:-空}"
  value="$(yget confirmation.evidence)"
  if is_empty_value "$value" || ! valid_evidence_reference "$value"; then
    add_error "confirmation.evidence 引用非法: ${value:-空}"
    return
  fi
  path="$(evidence_path "$value")"
  if [ ! -s "$path" ]; then
    add_error "confirmation.evidence 不存在或为空: $value"
    return
  fi
  scope="$(yget understanding.scope_sha256)"
  if ! output="$(python3 "$PLUGIN_ROOT/scripts/confirmation_contract.py" --validate "$path" --scope "$scope" 2>&1)"; then
    add_error "confirmation artifact 无效: ${output//$'\n'/; }"
  fi
  expected_sha="$(yget confirmation.decision_sha256)"
  current_sha="$(file_sha256 "$path")"
  [ "$expected_sha" = "$current_sha" ] || add_error "confirmation artifact 内容已变化"
}

validate_completion(){
  local mode="${1:-current}" phase level environment business fidelity external expected completed_at sealed_fingerprint sealed_requirements current_requirements
  errors=""
  validate_understanding_gate
  validate_confirmation_gate
  for field in task level context.repo context.branch context.target context.sources context.environment context.delivery; do
    require_value "$field"
  done
  require_evidence_file evidence.tests
  require_evidence_file evidence.residual_risks

  phase="$(yget phase)"
  level="$(yget level)"
  environment="$(yget context.environment)"
  business="$(yget requirements.business)"
  fidelity="$(yget requirements.fidelity)"
  external="$(yget requirements.external_review)"

  if [ "$mode" = sealed ]; then
    require_value completion.completed_at
    require_value completion.repository_fingerprint
    require_value completion.requirements_sha256
    completed_at="$(yget completion.completed_at)"
    sealed_fingerprint="$(yget completion.repository_fingerprint)"
    sealed_requirements="$(yget completion.requirements_sha256)"
    current_requirements="$(requirements_sha256)"
    printf '%s\n' "$completed_at" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' || add_error "completion.completed_at 非法"
    printf '%s\n' "$sealed_fingerprint" | grep -qE '^[0-9a-f]{64}$' || add_error "completion.repository_fingerprint 非法"
    printf '%s\n' "$sealed_requirements" | grep -qE '^[0-9a-f]{64}$' || add_error "completion.requirements_sha256 非法"
    [ "$sealed_requirements" = "$current_requirements" ] || add_error "requirements 与完成时封存值不一致"
  fi

  is_empty_value "$level" || in_list "$level" "$VALID_LEVELS" || add_error "level 非法: $level"
  is_empty_value "$environment" || in_list "$environment" "$VALID_ENVIRONMENTS" || add_error "context.environment 非法: $environment"

  expected=review
  if [ "$business" = true ]; then
    expected=business-verify
    [ "$external" = true ] || add_error "业务闭环必须 requirements.external_review=true"
    [ "$environment" = real ] || add_error "业务闭环只能在 context.environment=real 时完成"
    require_evidence_file evidence.business
    require_evidence_file evidence.requests
    require_evidence_file evidence.codegraph
  fi
  if [ "$external" = true ]; then
    validate_external_review "$mode"
  fi
  if [ "$fidelity" = true ]; then
    expected=fidelity-verify
    require_evidence_file evidence.fidelity
  fi
  if [ "$mode" = sealed ]; then
    [ "$phase" = done ] || add_error "封存状态 phase 应为 done，当前为 ${phase:-空}"
  else
    [ "$phase" = "$expected" ] || add_error "phase 应为 ${expected}，当前为 ${phase:-空}"
  fi

  [ -z "$errors" ] || die "完成门未通过: $errors"
}

acquire_state_lock

case "${1:-}" in
  init)
    mkdir -p "$(dirname "$STATE")"
    if [ ! -f "$STATE" ]; then
      cp "$PLUGIN_ROOT/templates/workflow-state.yaml" "$STATE"
    else
      ensure_schema
    fi
    if is_empty_value "$(yget context.repo)"; then
      repo_root="$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$REPO")"
      write_field context.repo "$repo_root"
    fi
    if is_empty_value "$(yget context.branch)"; then
      branch="$(git -C "$REPO" symbolic-ref --quiet --short HEAD 2>/dev/null || printf '%s' non-git)"
      write_field context.branch "$branch"
    fi
    if is_empty_value "$(yget execution.base_revision)"; then
      if ! base_revision="$(git -C "$REPO" rev-parse --verify HEAD 2>/dev/null)"; then
        base_revision=unborn
      fi
      write_field execution.base_revision "$base_revision"
    fi
    echo "✓ 状态文件就绪：$STATE" ;;
  start)
    [ -f "$STATE" ] || die "状态文件不存在，先 init"
    [ "$#" -ge 3 ] || die "用法: workflow-state.sh [--repo R] start <task> <level>"
    sealed_at="$(yget completion.completed_at)"
    ! is_empty_value "$sealed_at" || die "只有已完成并封存的任务可 start 新任务"
    task_name="$2"; task_level="$3"
    [ -n "$task_name" ] || die "task 不能为空"
    in_list "$task_level" "$VALID_LEVELS" || die "非法 level ${task_level}（允许: ${VALID_LEVELS}）"
    cp "$PLUGIN_ROOT/templates/workflow-state.yaml" "$STATE"
    repo_root="$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$REPO")"
    branch="$(git -C "$REPO" symbolic-ref --quiet --short HEAD 2>/dev/null || printf '%s' non-git)"
    write_field task "$task_name"
    write_field level "$task_level"
    write_field phase brainstorm
    write_field context.repo "$repo_root"
    write_field context.branch "$branch"
    if ! base_revision="$(git -C "$REPO" rev-parse --verify HEAD 2>/dev/null)"; then
      base_revision=unborn
    fi
    write_field execution.base_revision "$base_revision"
    if [ "$task_level" = L4 ]; then reset_understanding not-required; fi
    echo "✓ 新任务已开始（task=${task_name}, level=${task_level}, phase=brainstorm）" ;;
  goal)
    [ -f "$STATE" ] || die "状态文件不存在，先 init"
    [ "$#" -ge 2 ] || die "用法: workflow-state.sh [--repo R] goal <objective>"
    sealed_at="$(yget completion.completed_at)"
    is_empty_value "$sealed_at" || die "任务已封存；请先 start 新任务"
    [ "$(yget execution.mode)" != goal ] || die "Goal 已初始化；请使用 continue-goal"
    [ -n "$2" ] || die "Goal objective 不能为空"
    write_field execution.mode goal
    write_field execution.objective_sha256 "$(text_sha256 "$2")"
    write_field execution.continuation 0
    write_field execution.checkpoint ""
    if [ "$(yget level)" = L4 ]; then reset_understanding not-required; else reset_understanding pending; fi
    reset_confirmation pending
    echo "✓ Goal 已初始化（continuation=0，understanding=$(yget understanding.status)）" ;;
  continue-goal)
    [ -f "$STATE" ] || die "状态文件不存在，先 init"
    [ "$#" -ge 2 ] || die "用法: workflow-state.sh [--repo R] continue-goal <objective>"
    sealed_at="$(yget completion.completed_at)"
    is_empty_value "$sealed_at" || die "任务已封存；不得续行"
    [ "$(yget execution.mode)" = goal ] || die "当前不是 Goal mode；先使用 goal <objective>"
    [ -n "$2" ] || die "Goal objective 不能为空"
    previous_hash="$(yget execution.objective_sha256)"
    current_hash="$(text_sha256 "$2")"
    continuation="$(yget execution.continuation)"
    printf '%s\n' "$continuation" | grep -qE '^[0-9]+$' || die "execution.continuation 非法: $continuation"
    write_field execution.continuation "$((continuation + 1))"
    if [ "$previous_hash" = "$current_hash" ]; then
      reuse="$(yget understanding.status)"
    else
      write_field execution.objective_sha256 "$current_hash"
      write_field execution.checkpoint ""
      if [ "$(yget level)" = L4 ]; then reset_understanding not-required; else reset_understanding pending; fi
      reset_confirmation pending
      reuse="$(yget understanding.status)"
    fi
    echo "✓ 目标续行 = 第 $(yget execution.continuation) 次｜phase = $(yget phase)｜理解度 = $reuse" ;;
  understand)
    [ -f "$STATE" ] || die "状态文件不存在，先 init"
    [ "$#" -ge 2 ] || die "用法: workflow-state.sh [--repo R] understand <evidence>"
    sealed_at="$(yget completion.completed_at)"
    is_empty_value "$sealed_at" || die "任务已封存；不得更新 understanding"
    level="$(yget level)"
    in_list "$level" "$VALID_LEVELS" || die "先设置合法 level"
    [ "$level" != L4 ] || die "L4 understanding 为 not-required，无需证据"
    errors=""
    for field in task level context.target context.sources; do require_value "$field"; done
    value="$2"
    if ! valid_evidence_reference "$value"; then
      add_error "understanding evidence 必须位于 docs/superpowers/.workflow-evidence/ 且不得包含 ..: $value"
    else
      path="$(evidence_path "$value")"
      if [ ! -s "$path" ]; then
        add_error "understanding evidence 不存在或为空: $value"
      else
        validate_understanding_evidence "$level" "$path"
      fi
    fi
    [ -z "$errors" ] || die "理解度关卡未通过: $errors"
    write_field understanding.kind "$(understanding_kind_for_level "$level")"
    write_field understanding.evidence "$value"
    write_field understanding.evidence_sha256 "$(file_sha256 "$path")"
    write_field understanding.scope_sha256 "$(scope_sha256)"
    write_field understanding.status passed
    reset_confirmation pending
    echo "✓ 理解度 = PASS（kind=$(understanding_kind_for_level "$level")）" ;;
  confirm)
    [ -f "$STATE" ] || die "状态文件不存在，先 init"
    [ "$#" -ge 2 ] || die "用法: workflow-state.sh [--repo R] confirm <json>"
    sealed_at="$(yget completion.completed_at)"
    is_empty_value "$sealed_at" || die "任务已封存；不得更新 confirmation"
    [ "$(yget execution.mode)" = goal ] || die "只有 Goal mode 需要 autonomous confirmation"
    [ "$(yget level)" != L4 ] || die "L4 Goal 无需 confirmation"
    errors=""
    validate_understanding_gate
    [ -z "$errors" ] || die "自治确认前理解度无效: $errors"
    value="$2"
    valid_evidence_reference "$value" || die "confirmation evidence 必须位于 docs/superpowers/.workflow-evidence/ 且不得包含 ..: $value"
    path="$(evidence_path "$value")"
    [ -s "$path" ] || die "confirmation evidence 不存在或为空: $value"
    scope="$(yget understanding.scope_sha256)"
    if ! output="$(python3 "$PLUGIN_ROOT/scripts/confirmation_contract.py" --validate "$path" --scope "$scope" 2>&1)"; then
      die "自治确认未通过: ${output//$'\n'/; }"
    fi
    write_field confirmation.mode autonomous
    write_field confirmation.evidence "$value"
    write_field confirmation.decision_sha256 "$(file_sha256 "$path")"
    write_field confirmation.status passed
    echo "✓ 自治确认 = PASS（artifact=${value}）" ;;
  get)
    [ -f "$STATE" ] || die "状态文件不存在，先 init"
    yget "$2" ;;
  set)
    [ -f "$STATE" ] || die "状态文件不存在，先 init"
    sealed_at="$(yget completion.completed_at)"
    is_empty_value "$sealed_at" || die "任务已封存；状态不可修改，请用 start <task> <level> 开始新任务"
    field="$2"; value="$3"
    in_list "$field" "$VALID_FIELDS" || die "未知字段 ${field}（允许: ${VALID_FIELDS}）"
    if [ "$field" = phase ]; then
      [ "$value" = done ] && die "禁止直接 set phase done；请使用 complete 通过证据门"
      in_list "$value" "$VALID_PHASES" || die "非法 phase ${value}（允许: ${VALID_PHASES}）"
      if is_execution_phase "$value"; then
        errors=""
        validate_understanding_gate
        validate_confirmation_gate
        [ -z "$errors" ] || die "执行硬门未通过: $errors"
      fi
    fi
    [ "$field" = level ] && { in_list "$value" "$VALID_LEVELS" || die "非法 level ${value}（允许: ${VALID_LEVELS}）"; }
    case "$field" in
      requirements.*) in_list "$value" "$VALID_BOOLEANS" || die "$field 只能是 true/false" ;;
      context.environment) in_list "$value" "$VALID_ENVIRONMENTS" || die "$field 只能是 real/mock/n/a" ;;
    esac
    write_field "$field" "$value"
    if [ "$field" = level ]; then
      if [ "$value" = L4 ]; then
        reset_understanding not-required
      elif [ "$(yget understanding.status)" = not-required ]; then
        reset_understanding pending
      fi
    fi
    echo "✓ ${field} = ${value}（updated=$(date +%F)）" ;;
  complete)
    [ -f "$STATE" ] || die "状态文件不存在，先 init"
    sealed_at="$(yget completion.completed_at)"
    is_empty_value "$sealed_at" || die "任务已封存；不得重复 complete，请用 start <task> <level>"
    validate_completion current
    completion_fingerprint="$(python3 "$PLUGIN_ROOT/scripts/external_agent.py" --fingerprint --cd "$REPO")" || die "无法封存 repository fingerprint"
    write_field completion.completed_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    write_field completion.repository_fingerprint "$completion_fingerprint"
    write_field completion.requirements_sha256 "$(requirements_sha256)"
    write_field phase done
    write_field next ""
    echo "✓ 完成门通过（phase=done）" ;;
  check)
    if [ ! -f "$STATE" ]; then
      echo "✓ 无续行状态（未初始化）：$STATE"
      exit 0
    fi
    ph="$(yget phase)"; is_empty_value "$ph" || in_list "$ph" "$VALID_PHASES" || die "phase 非法: $ph"
    lv="$(yget level)"; is_empty_value "$lv" || in_list "$lv" "$VALID_LEVELS" || die "level 非法: $lv"
    env="$(yget context.environment)"; is_empty_value "$env" || in_list "$env" "$VALID_ENVIRONMENTS" || die "context.environment 非法: $env"
    execution_mode="$(yget execution.mode)"; is_empty_value "$execution_mode" || in_list "$execution_mode" "single goal" || die "execution.mode 非法: $execution_mode"
    continuation="$(yget execution.continuation)"; printf '%s\n' "$continuation" | grep -qE '^[0-9]+$' || die "execution.continuation 非法: $continuation"
    for field in requirements.business requirements.fidelity requirements.external_review; do
      value="$(yget "$field")"
      is_empty_value "$value" || in_list "$value" "$VALID_BOOLEANS" || die "$field 非法: $value"
    done
    understanding_status="$(yget understanding.status)"
    is_empty_value "$understanding_status" || in_list "$understanding_status" "$VALID_UNDERSTANDING_STATUSES" || die "understanding.status 非法: $understanding_status"
    understanding_kind="$(yget understanding.kind)"
    is_empty_value "$understanding_kind" || in_list "$understanding_kind" "$VALID_UNDERSTANDING_KINDS" || die "understanding.kind 非法: $understanding_kind"
    confirmation_status="$(yget confirmation.status)"
    is_empty_value "$confirmation_status" || in_list "$confirmation_status" "$VALID_CONFIRMATION_STATUSES" || die "confirmation.status 非法: $confirmation_status"
    sp="$(yget artifacts.spec)"; is_empty_value "$sp" || [ -f "$REPO/$sp" ] || echo "⚠ spec 文件不存在: $sp" >&2
    pp="$(yget artifacts.plan)"; is_empty_value "$pp" || [ -f "$REPO/$pp" ] || echo "⚠ plan 文件不存在: $pp" >&2
    sealed_at="$(yget completion.completed_at)"
    if [ "$ph" = done ] || ! is_empty_value "$sealed_at"; then validate_completion sealed; fi
    if is_execution_phase "$ph"; then
      errors=""
      validate_understanding_gate
      validate_confirmation_gate
      [ -z "$errors" ] || die "执行硬门未通过: $errors"
    fi
    is_empty_value "$ph" && ph=""
    echo "✓ check 通过（phase=${ph:-空}）" ;;
  *) echo "用法: workflow-state.sh [--repo R] {init|start <task> <level>|goal <objective>|continue-goal <objective>|understand <evidence>|confirm <json>|get <field>|set <field> <value>|check|complete}" >&2; exit 2 ;;
esac
