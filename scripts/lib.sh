#!/usr/bin/env bash
# 公共函数：数据区解析与模板初始化。被其他脚本 source。
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

dw_data_dir() {
  local d="${DEV_WORKFLOW_DATA:-$HOME/.claude/dev-workflow}"
  mkdir -p "$d"
  printf '%s' "$d"
}

dw_ensure_learnings() {
  local d; d="$(dw_data_dir)"
  [ -f "$d/LEARNINGS.md" ] || cp "$PLUGIN_ROOT/templates/LEARNINGS.md" "$d/LEARNINGS.md"
}
