#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SBOX="$(mktemp -d)"; export HOME="$SBOX/home"; mkdir -p "$HOME"
REPO="$SBOX/repo"; mkdir -p "$REPO"; (cd "$REPO" && git init -q)
export CODEX_HOME="$HOME/.codex"
export CODEX_PLUGIN_ROOT="$HERE"

bash "$HERE/bin/init" --repo "$REPO" --yes >/dev/null
# Data dir and LEARNINGS should be created
[ -f "$CODEX_HOME/dev-workflow/LEARNINGS.md" ] || { echo "FAIL: 数据区未建"; exit 1; }
# .workflow-state.yaml should be in repo .gitignore
grep -q "workflow-state.yaml" "$REPO/.gitignore" || { echo "FAIL: 未写 gitignore"; exit 1; }
echo "PASS tests/init.sh"
