#!/usr/bin/env bash
# 公共函数：插件根目录、数据区解析与模板初始化。被其他脚本 source。
dw_plugin_root() {
  if [ -n "${DEV_WORKFLOW_PLUGIN_ROOT:-}" ]; then
    printf '%s' "$DEV_WORKFLOW_PLUGIN_ROOT"
  elif [ -n "${CODEX_PLUGIN_ROOT:-}" ]; then
    printf '%s' "$CODEX_PLUGIN_ROOT"
  elif [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
    printf '%s' "$CLAUDE_PLUGIN_ROOT"
  else
    cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd
  fi
}

PLUGIN_ROOT="$(dw_plugin_root)"

dw_data_dir() {
  # 数据区按「实际在跑哪个工具」判定，不靠磁盘上是否存在 ~/.codex 之类的痕迹，
  # 否则一个在 Claude 里跑、但机器上装过 Codex 的用户数据会被写错目录。
  local d
  if [ -n "${DEV_WORKFLOW_DATA:-}" ]; then
    d="$DEV_WORKFLOW_DATA"                       # 显式覆盖，最高优先
  elif [ -n "${CODEX_PLUGIN_ROOT:-}" ] || [ -n "${CODEX_HOME:-}" ]; then
    d="${CODEX_HOME:-$HOME/.codex}/dev-workflow" # 确在 Codex 下运行
  else
    d="$HOME/.claude/dev-workflow"               # 默认 Claude（含 CLAUDE_PLUGIN_ROOT）
  fi
  mkdir -p "$d"
  printf '%s' "$d"
}

dw_ensure_learnings() {
  local d; d="$(dw_data_dir)"
  [ -f "$d/LEARNINGS.md" ] || cp "$PLUGIN_ROOT/templates/LEARNINGS.md" "$d/LEARNINGS.md"
}
