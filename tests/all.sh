#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
echo "=== 全量测试 ==="
for t in lib learnings workflow-state codegraph-judge hook init install-codex; do
  echo "--- $t ---"
  bash "$HERE/$t.sh"
done
echo "--- python hook unit ---"
python3 "$HERE/test_detect_judging_correction.py"
echo "=== 绝对路径扫描（不应出现个人路径）==="
if grep -rn "/Users/elvis" "$HERE/.." --include="*.sh" --include="*.md" --include="*.json" --include="*.py" 2>/dev/null | grep -v "/tests/" | grep -v "/.git/"; then
  echo "FAIL: 存在硬编码个人路径"; exit 1
else
  echo "✓ 无硬编码个人路径"
fi
echo "ALL PASS"
