#!/usr/bin/env bash
# 续行状态独占接口（学 Comet comet-state.sh）。SKILL.md 只调本脚本，禁手改 YAML。
# 用法: workflow-state.sh [--repo R] {init|start <task> <level>|get <field>|set <field> <value>|check|complete}
set -euo pipefail
# 复用 lib.sh 的 dw_plugin_root（单一来源），避免与各脚本重复维护 env 优先级链
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

REPO="$PWD"
if [ "${1:-}" = "--repo" ]; then REPO="$2"; shift 2; fi
STATE="$REPO/docs/superpowers/.workflow-state.yaml"

VALID_PHASES="brainstorm grill spec plan tdd review business-verify fidelity-verify done"
VALID_LEVELS="L0 L1 L2 L3 L4"
VALID_BOOLEANS="true false"
VALID_ENVIRONMENTS="real mock n/a"
VALID_FIELDS="task level phase updated next context.repo context.branch context.target context.sources context.environment context.delivery requirements.business requirements.fidelity requirements.external_review artifacts.spec artifacts.plan evidence.tests evidence.business evidence.requests evidence.codegraph evidence.external_review evidence.fidelity evidence.residual_risks"

die(){ echo "✗ $1" >&2; exit 1; }
in_list(){ printf '%s\n' $2 | grep -qxF "$1"; }
is_empty_value(){ [ -z "$1" ] || [ "$1" = '""' ] || [ "$1" = "''" ]; }

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
    level|phase|updated|requirements.*|context.environment|completion.*|execution.mode|execution.continuation|understanding.status)
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

validate_completion(){
  local mode="${1:-current}" phase level environment business fidelity external expected completed_at sealed_fingerprint sealed_requirements current_requirements
  errors=""
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
    [ "$phase" = "$expected" ] || add_error "phase 应为 $expected，当前为 ${phase:-空}"
  fi

  [ -z "$errors" ] || die "完成门未通过: $errors"
}

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
    in_list "$task_level" "$VALID_LEVELS" || die "非法 level ${task_level}（允许: $VALID_LEVELS）"
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
    echo "✓ 新任务已开始（task=${task_name}, level=${task_level}, phase=brainstorm）" ;;
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
      in_list "$value" "$VALID_PHASES" || die "非法 phase ${value}（允许: $VALID_PHASES）"
    fi
    [ "$field" = level ] && { in_list "$value" "$VALID_LEVELS" || die "非法 level ${value}（允许: $VALID_LEVELS）"; }
    case "$field" in
      requirements.*) in_list "$value" "$VALID_BOOLEANS" || die "$field 只能是 true/false" ;;
      context.environment) in_list "$value" "$VALID_ENVIRONMENTS" || die "$field 只能是 real/mock/n/a" ;;
    esac
    write_field "$field" "$value"
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
    for field in requirements.business requirements.fidelity requirements.external_review; do
      value="$(yget "$field")"
      is_empty_value "$value" || in_list "$value" "$VALID_BOOLEANS" || die "$field 非法: $value"
    done
    sp="$(yget artifacts.spec)"; is_empty_value "$sp" || [ -f "$REPO/$sp" ] || echo "⚠ spec 文件不存在: $sp" >&2
    pp="$(yget artifacts.plan)"; is_empty_value "$pp" || [ -f "$REPO/$pp" ] || echo "⚠ plan 文件不存在: $pp" >&2
    sealed_at="$(yget completion.completed_at)"
    if [ "$ph" = done ] || ! is_empty_value "$sealed_at"; then validate_completion sealed; fi
    is_empty_value "$ph" && ph=""
    echo "✓ check 通过（phase=${ph:-空}）" ;;
  *) echo "用法: workflow-state.sh [--repo R] {init|start <task> <level>|get <field>|set <field> <value>|check|complete}" >&2; exit 2 ;;
esac
