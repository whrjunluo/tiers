#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
echo "=== 全量测试 ==="
for t in lib learnings workflow-state codegraph-judge hook init; do
  echo "--- $t ---"
  bash "$HERE/$t.sh"
done
echo "=== 绝对路径扫描（不应出现个人路径）==="
if grep -rn "/Users/elvis" "$HERE/.." --include="*.sh" --include="*.md" --include="*.json" --include="*.py" 2>/dev/null | grep -v "/tests/" | grep -v "/.git/"; then
  echo "FAIL: 存在硬编码个人路径"; exit 1
else
  echo "✓ 无硬编码个人路径"
fi
echo "ALL PASS"
