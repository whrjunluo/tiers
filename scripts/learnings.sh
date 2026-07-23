#!/usr/bin/env bash
# dev-workflow 进化日志 helper —— 确定性记录与计数（纯 bash + awk，无外部依赖）
#
# 用法：
#   learnings.sh count                       # 按 category 统计 pending 计数（降序）
#   learnings.sh categories                  # 列出词表里的有效 category
#   learnings.sh add <category> <project> <note>   # 校验 category 后原子追加一条 pending
#   learnings.sh fold <category>              # 将该 category 的 pending 记录原子标记为 folded
#   learnings.sh list                        # 打印「进化记录」整段
#   learnings.sh ready                        # 仅列出已达阈值(≥2)、应提固化提案的 category
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
dw_ensure_learnings
LEARNINGS="$(dw_data_dir)/LEARNINGS.md"

valid_cats() {
  awk '
    /^## category 词表/{ sec=1; next }
    sec && /^```/{ fence++; next }
    sec && fence==1 && NF>0 { print $1 }
    sec && fence==2 { exit }
  ' "$LEARNINGS"
}

count() {
  awk '
    /^## 进化记录/{ inrec=1; next }
    inrec!=1{ next }
    /^[[:space:]]*-[[:space:]]+date:/{ cat=""; st="" }
    /category:/{ l=$0; sub(/.*category:[[:space:]]*/,"",l); sub(/[[:space:]]*#.*/,"",l); gsub(/[[:space:]]+$/,"",l); cat=l }
    /status:/{ l=$0; sub(/.*status:[[:space:]]*/,"",l); sub(/[[:space:]]*#.*/,"",l); gsub(/[[:space:]]+$/,"",l); st=l;
               if(st=="pending" && cat!="") c[cat]++ }
    END{ for(k in c) printf "%d\t%s\n", c[k], k }
  ' "$LEARNINGS" | sort -rn
}

fold_category() {
  local target="$1" tmp count_file changed
  if ! valid_cats | grep -qxF "$target"; then
    echo "✗ category「$target」不在词表中。有效值：" >&2
    valid_cats | sed 's/^/  - /' >&2
    return 1
  fi
  tmp="${LEARNINGS}.tmp.$$"
  count_file="${LEARNINGS}.fold-count.$$"
  if ! awk -v target="$target" -v count_file="$count_file" '
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
  ' "$LEARNINGS" > "$tmp"; then
    rm -f "$tmp" "$count_file"
    return 1
  fi
  changed="$(cat "$count_file")"
  mv "$tmp" "$LEARNINGS"
  rm -f "$count_file"
  echo "✓ 已 folded：${target}（$changed 条）"
}

cmd="${1:-}"
case "$cmd" in
  categories) valid_cats ;;
  count)
    out="$(count)"
    [ -n "$out" ] && echo "$out" || echo "（无 pending 记录）"
    ;;
  ready)
    count | awk -F'\t' '$1>=2{ print "⚠ "$2"（"$1" 次）应提固化提案" }'
    ;;
  list)
    awk '/^## 进化记录/{p=1} p' "$LEARNINGS"
    ;;
  add)
    cat="${2:-}"; proj="${3:-}"; note="${4:-}"
    if [ -z "$cat" ] || [ -z "$proj" ] || [ -z "$note" ]; then
      echo "用法: learnings.sh add <category> <project> <note>" >&2; exit 2
    fi
    if ! valid_cats | grep -qxF "$cat"; then
      echo "✗ category「$cat」不在词表中。有效值：" >&2
      valid_cats | sed 's/^/  - /' >&2
      echo "（如确属新类，请先在 LEARNINGS.md 词表里补一行再 add）" >&2
      exit 1
    fi
    printf '\n- date: %s\n  category: %s\n  project: %s\n  note: %s\n  status: pending\n' \
      "$(date +%F)" "$cat" "$proj" "$note" >> "$LEARNINGS"
    cur="$(count | awk -F'\t' -v c="$cat" '$2==c{print $1}')"
    echo "✓ 已记录：$cat / $proj"
    echo "  该 category 当前 pending 计数：${cur:-1}"
    if [ "${cur:-0}" -ge 2 ]; then
      echo "  ⚠ 已达阈值 ≥2 → 下次开工应对该 category 提固化提案"
    fi
    ;;
  fold)
    cat="${2:-}"
    if [ -z "$cat" ]; then
      echo "用法: learnings.sh fold <category>" >&2; exit 2
    fi
    fold_category "$cat"
    ;;
  *)
    echo "用法: learnings.sh {count|categories|ready|add|fold|list}" >&2; exit 2 ;;
esac
