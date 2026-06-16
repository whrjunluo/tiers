#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SBOX="$(mktemp -d)"
export HOME="$SBOX/home"
export CODEX_HOME="$HOME/.codex"
mkdir -p "$CODEX_HOME/skills/dev-workflow"
printf 'old skill\n' > "$CODEX_HOME/skills/dev-workflow/SKILL.md"

bash "$HERE/bin/install-codex" --codex-home "$CODEX_HOME" --yes >/dev/null

[ -L "$CODEX_HOME/skills/dev-workflow" ] || { echo "FAIL: dev-workflow skill link missing"; exit 1; }
[ -L "$CODEX_HOME/skills/grill-me" ] || { echo "FAIL: grill-me skill link missing"; exit 1; }
[ -f "$CODEX_HOME/dev-workflow/LEARNINGS.md" ] || { echo "FAIL: LEARNINGS not initialized"; exit 1; }
[ -f "$CODEX_HOME/plugins/local-marketplace/.agents/plugins/marketplace.json" ] || { echo "FAIL: marketplace missing"; exit 1; }
grep -q '\[plugins."dev-workflow@local"\]' "$CODEX_HOME/config.toml" || { echo "FAIL: plugin config missing"; exit 1; }
grep -q 'enabled = true' "$CODEX_HOME/config.toml" || { echo "FAIL: plugin not enabled"; exit 1; }
ls "$CODEX_HOME/skills-backup"/dev-workflow.* >/dev/null || { echo "FAIL: old skill not backed up"; exit 1; }

echo "PASS tests/install-codex.sh"
