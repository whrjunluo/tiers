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

# 统一数据区：未设 DEV_WORKFLOW_DATA 时一律落到 ~/.dev-workflow（跨工具共享）
SBOX="$(mktemp -d)"
out="$(HOME="$SBOX" DEV_WORKFLOW_DATA="" bash -c 'source "'"$HERE"'/scripts/lib.sh"; dw_data_dir')"
[ "$out" = "$SBOX/.dev-workflow" ] || { echo "FAIL: 统一数据区默认路径不符（得到 ${out}）"; exit 1; }

# Cursor 插件环境：CURSOR_PLUGIN_ROOT 应作为一等插件根目录来源
CURSOR_ROOT="$(mktemp -d)"
out="$(DEV_WORKFLOW_PLUGIN_ROOT="" CODEX_PLUGIN_ROOT="" CLAUDE_PLUGIN_ROOT="" CURSOR_PLUGIN_ROOT="$CURSOR_ROOT" bash -c 'source "'"$HERE"'/scripts/lib.sh"; dw_plugin_root')"
[ "$out" = "$CURSOR_ROOT" ] || { echo "FAIL: CURSOR_PLUGIN_ROOT 未被识别（得到 ${out}）"; exit 1; }

# 迁移：未设 DEV_WORKFLOW_DATA 且统一区无 LEARNINGS 时，从旧版 ~/.codex/dev-workflow 迁移
MIG="$(mktemp -d)"
mkdir -p "$MIG/.codex/dev-workflow"
printf 'LEGACY-CODEX-MARK\n## category 词表\n' > "$MIG/.codex/dev-workflow/LEARNINGS.md"
HOME="$MIG" DEV_WORKFLOW_DATA="" bash -c 'source "'"$HERE"'/scripts/lib.sh"; dw_ensure_learnings'
grep -q "LEGACY-CODEX-MARK" "$MIG/.dev-workflow/LEARNINGS.md" || { echo "FAIL: 未从旧 codex 数据区迁移"; exit 1; }

echo "PASS tests/lib.sh"
