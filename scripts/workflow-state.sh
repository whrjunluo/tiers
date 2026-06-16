#!/usr/bin/env bash
# 续行状态独占接口（学 Comet comet-state.sh）。SKILL.md 只调本脚本，禁手改 YAML。
# 用法: workflow-state.sh [--repo R] {init|get <field>|set <field> <value>|check}
set -euo pipefail
# 复用 lib.sh 的 dw_plugin_root（单一来源），避免与各脚本重复维护 env 优先级链
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

REPO="$PWD"
if [ "${1:-}" = "--repo" ]; then REPO="$2"; shift 2; fi
STATE="$REPO/docs/superpowers/.workflow-state.yaml"

VALID_PHASES="brainstorm spec plan tdd review done"
VALID_FIELDS="task level phase updated next artifacts.spec artifacts.plan"

die(){ echo "✗ $1" >&2; exit 1; }
in_list(){ printf '%s\n' $2 | grep -qxF "$1"; }

yget(){ # top-level or artifacts.* value extraction
  local k="$1"
  case "$k" in
    artifacts.*) awk -v sub="${k#artifacts.}" '/^artifacts:/{f=1;next} f&&$0!~/^[[:space:]]/{f=0} f&&$1==sub":"{sub(/^[[:space:]]*[^:]+:[[:space:]]*/,"");print;exit}' "$STATE" ;;
    *) awk -v k="$k" '$1==k":"{sub(/^[^:]+:[[:space:]]*/,"");print;exit}' "$STATE" ;;
  esac
}

case "${1:-}" in
  init)
    mkdir -p "$(dirname "$STATE")"
    [ -f "$STATE" ] || cp "$PLUGIN_ROOT/templates/workflow-state.yaml" "$STATE"
    echo "✓ 状态文件就绪：$STATE" ;;
  get)
    [ -f "$STATE" ] || die "状态文件不存在，先 init"
    yget "$2" ;;
  set)
    [ -f "$STATE" ] || die "状态文件不存在，先 init"
    field="$2"; value="$3"
    in_list "$field" "$VALID_FIELDS" || die "未知字段 $field（允许: $VALID_FIELDS）"
    [ "$field" = "phase" ] && { in_list "$value" "$VALID_PHASES" || die "非法 phase $value（允许: $VALID_PHASES）"; }
    # auto-update the "updated" field
    today="$(date +%F)"
    tmp="$(mktemp)"
    awk -v field="$field" -v value="$value" -v today="$today" '
      BEGIN{set_done=0; upd_done=0}
      /^artifacts:/{inart=1}
      inart && $0!~/^[[:space:]]/ && $0!~/^artifacts:/{inart=0}
      {
        line=$0
        if(field ~ /^artifacts\./ && inart){ key=substr(field,11); if($1==key":"){ line="  " key ": " value; set_done=1 } }
        else if(field !~ /^artifacts\./ && $1==field":"){ line=field ": " value; set_done=1 }
        if($1=="updated:"){ line="updated: " today; upd_done=1 }
        print line
      }' "$STATE" > "$tmp" && mv "$tmp" "$STATE"
    echo "✓ ${field} = ${value}（updated=${today}）" ;;
  check)
    [ -f "$STATE" ] || die "状态文件不存在"
    ph="$(yget phase)"; [ -z "$ph" ] || in_list "$ph" "$VALID_PHASES" || die "phase 非法: $ph"
    sp="$(yget artifacts.spec)"; [ -z "$sp" ] || [ -f "$REPO/$sp" ] || echo "⚠ spec 文件不存在: $sp" >&2
    echo "✓ check 通过（phase=${ph:-空}）" ;;
  *) echo "用法: workflow-state.sh [--repo R] {init|get <field>|set <field> <value>|check}" >&2; exit 2 ;;
esac
