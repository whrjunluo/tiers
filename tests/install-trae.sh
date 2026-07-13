#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SBOX="$(mktemp -d)"
trap 'rm -rf "$SBOX"' EXIT
export HOME="$SBOX/home"
export TRAE_HOME="$HOME/.trae-cn"
mkdir -p "$TRAE_HOME/skills/dev-workflow"
printf 'old skill\n' > "$TRAE_HOME/skills/dev-workflow/SKILL.md"

bash "$HERE/bin/install-trae" --trae-home "$TRAE_HOME" --yes >/dev/null

[ -L "$TRAE_HOME/skills/dev-workflow" ] || { echo "FAIL: dev-workflow skill link missing"; exit 1; }
[ -L "$TRAE_HOME/skills/grill-me" ] || { echo "FAIL: grill-me skill link missing"; exit 1; }
[ -L "$TRAE_HOME/skills/grilling" ] || { echo "FAIL: grilling skill link missing"; exit 1; }
[ -L "$TRAE_HOME/skills/external-agent" ] || { echo "FAIL: external-agent skill link missing"; exit 1; }
ls "$TRAE_HOME/skills-backup"/dev-workflow.* >/dev/null || { echo "FAIL: old skill not backed up"; exit 1; }
[ -f "$HOME/.dev-workflow/LEARNINGS.md" ] || { echo "FAIL: LEARNINGS not initialized in unified data dir"; exit 1; }

echo "PASS tests/install-trae.sh"
