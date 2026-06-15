#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
export DEV_WORKFLOW_DATA="$(mktemp -d)/data"
source "$HERE/scripts/lib.sh"

# data_dir should return DEV_WORKFLOW_DATA and create the directory
d="$(dw_data_dir)"
[ "$d" = "$DEV_WORKFLOW_DATA" ] || { echo "FAIL: data_dir 路径不符"; exit 1; }
[ -d "$d" ] || { echo "FAIL: data_dir 未创建"; exit 1; }

# First run should copy LEARNINGS.md from template
dw_ensure_learnings
[ -f "$d/LEARNINGS.md" ] || { echo "FAIL: LEARNINGS.md 未初始化"; exit 1; }
grep -q "category 词表" "$d/LEARNINGS.md" || { echo "FAIL: 模板内容缺失"; exit 1; }
echo "PASS tests/lib.sh"
