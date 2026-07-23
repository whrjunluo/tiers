#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
export DEV_WORKFLOW_DATA="$(mktemp -d)/data"
LS="$HERE/scripts/learnings.sh"

[ "$(bash "$LS" count)" = "（无 pending 记录）" ] || { echo "FAIL: 初始应为空"; exit 1; }
bash "$LS" add "判级/行为守卫" "repoA" "n1" >/dev/null
bash "$LS" add "判级/行为守卫" "repoB" "n2" >/dev/null
bash "$LS" ready | grep -q "判级/行为守卫" || { echo "FAIL: ≥2 应进 ready"; exit 1; }
bash "$LS" add "流程/tie-breaker" "repoC" "n3" >/dev/null
bash "$LS" add "流程/tie-breaker" "repoD" "n4" >/dev/null
out="$(bash "$LS" fold "流程/tie-breaker")"
echo "$out" | grep -q '2 条' || { echo "FAIL: fold 应报告两条变更"; exit 1; }
if bash "$LS" ready | grep -q "流程/tie-breaker"; then
  echo "FAIL: folded category 不应继续 ready"
  exit 1
fi
bash "$LS" count | grep -q $'2\t判级/行为守卫' || { echo "FAIL: fold 不得修改其他 category"; exit 1; }
out="$(bash "$LS" fold "流程/tie-breaker")"
echo "$out" | grep -q '0 条' || { echo "FAIL: repeated fold 应幂等"; exit 1; }
template_before="$(awk '/^## 进化记录/{exit} {print}' "$DEV_WORKFLOW_DATA/LEARNINGS.md")"
out="$(bash "$LS" fold "判级/行为守卫")"
echo "$out" | grep -q '2 条' || { echo "FAIL: fold 应只统计真实记录"; exit 1; }
template_after="$(awk '/^## 进化记录/{exit} {print}' "$DEV_WORKFLOW_DATA/LEARNINGS.md")"
[ "$template_before" = "$template_after" ] || { echo "FAIL: fold 不得修改进化记录之前的格式示例"; exit 1; }
bash "$LS" add "瞎写类" "x" "y" 2>/dev/null && { echo "FAIL: 非法 category 应拒绝"; exit 1; } || true
bash "$LS" fold "瞎写类" 2>/dev/null && { echo "FAIL: fold 应拒绝非法 category"; exit 1; } || true
echo "PASS tests/learnings.sh"
