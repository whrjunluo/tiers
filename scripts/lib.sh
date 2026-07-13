#!/usr/bin/env bash
# 公共函数：插件根目录、数据区解析与模板初始化。被其他脚本 source。
dw_plugin_root() {
  if [ -n "${DEV_WORKFLOW_PLUGIN_ROOT:-}" ]; then
    printf '%s' "$DEV_WORKFLOW_PLUGIN_ROOT"
  elif [ -n "${CODEX_PLUGIN_ROOT:-}" ]; then
    printf '%s' "$CODEX_PLUGIN_ROOT"
  elif [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
    printf '%s' "$CLAUDE_PLUGIN_ROOT"
  elif [ -n "${CURSOR_PLUGIN_ROOT:-}" ]; then
    printf '%s' "$CURSOR_PLUGIN_ROOT"
  elif [ -n "${TRAE_PLUGIN_ROOT:-}" ]; then
    printf '%s' "$TRAE_PLUGIN_ROOT"
  else
    cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd
  fi
}

PLUGIN_ROOT="$(dw_plugin_root)"

# 旧版按工具分目录（Claude / Codex）的历史数据区，仅用于一次性迁移。
dw_legacy_data_dirs() {
  printf '%s\n%s\n' "$HOME/.codex/dev-workflow" "$HOME/.claude/dev-workflow"
}

dw_data_dir() {
  # 跨工具统一一份全局数据区，方便 AI 自我进化时所有客户端（Claude / Codex / Cursor / TRAE）
  # 共享同一份 LEARNINGS.md。可用 DEV_WORKFLOW_DATA 显式覆盖（测试 / 自定义）。
  local d
  if [ -n "${DEV_WORKFLOW_DATA:-}" ]; then
    d="$DEV_WORKFLOW_DATA"          # 显式覆盖，最高优先
  else
    d="$HOME/.dev-workflow"         # 统一全局数据区，跨工具共享
  fi
  mkdir -p "$d"
  printf '%s' "$d"
}

dw_ensure_learnings() {
  local d legacy; d="$(dw_data_dir)"
  [ -f "$d/LEARNINGS.md" ] && return 0

  # 首次落地：把旧版分目录里的历史进化记录迁移进统一数据区（优先 Codex，其次 Claude）。
  while IFS= read -r legacy; do
    if [ "$legacy/LEARNINGS.md" != "$d/LEARNINGS.md" ] && [ -f "$legacy/LEARNINGS.md" ]; then
      cp "$legacy/LEARNINGS.md" "$d/LEARNINGS.md"
      return 0
    fi
  done < <(dw_legacy_data_dirs)

  cp "$PLUGIN_ROOT/templates/LEARNINGS.md" "$d/LEARNINGS.md"
}
