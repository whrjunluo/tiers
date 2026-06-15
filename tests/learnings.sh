#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
export DEV_WORKFLOW_DATA="$(mktemp -d)/data"
LS="$HERE/scripts/learnings.sh"

[ "$(bash "$LS" count)" = "（无 pending 记录）" ] || { echo "FAIL: 初始应为空"; exit 1; }
bash "$LS" add "判级/行为守卫" "repoA" "n1" >/dev/null
bash "$LS" add "判级/行为守卫" "repoB" "n2" >/dev/null
bash "$LS" ready | grep -q "判级/行为守卫" || { echo "FAIL: ≥2 应进 ready"; exit 1; }
bash "$LS" add "瞎写类" "x" "y" 2>/dev/null && { echo "FAIL: 非法 category 应拒绝"; exit 1; } || true
echo "PASS tests/learnings.sh"
