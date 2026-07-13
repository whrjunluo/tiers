#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SBOX="$(mktemp -d)"
export HOME="$SBOX/home"
export CURSOR_HOME="$HOME/.cursor"
mkdir -p "$CURSOR_HOME/skills/dev-workflow"
printf 'old skill\n' > "$CURSOR_HOME/skills/dev-workflow/SKILL.md"

bash "$HERE/bin/install-cursor" --cursor-home "$CURSOR_HOME" --yes >/dev/null

[ -L "$CURSOR_HOME/skills/dev-workflow" ] || { echo "FAIL: dev-workflow skill link missing"; exit 1; }
[ -L "$CURSOR_HOME/skills/grill-me" ] || { echo "FAIL: grill-me skill link missing"; exit 1; }
[ -L "$CURSOR_HOME/skills/grilling" ] || { echo "FAIL: grilling skill link missing"; exit 1; }
[ -L "$CURSOR_HOME/skills/external-agent" ] || { echo "FAIL: external-agent skill link missing"; exit 1; }
ls "$CURSOR_HOME/skills-backup"/dev-workflow.* >/dev/null || { echo "FAIL: old skill not backed up"; exit 1; }

# 跨工具统一全局数据区
[ -f "$HOME/.dev-workflow/LEARNINGS.md" ] || { echo "FAIL: LEARNINGS not initialized in unified data dir"; exit 1; }

# 不应在 Cursor 写入任何 hook 配置（beforeSubmitPrompt 无法注入上下文）
[ ! -f "$CURSOR_HOME/hooks.json" ] || { echo "FAIL: install-cursor 不应写 hooks.json"; exit 1; }

echo "PASS tests/install-cursor.sh"
