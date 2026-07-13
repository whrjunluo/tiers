#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SBOX="$(mktemp -d)"; export HOME="$SBOX/home"; mkdir -p "$HOME"
REPO="$SBOX/repo"; mkdir -p "$REPO"; (cd "$REPO" && git init -q)
export TRAE_HOME="$HOME/.trae-cn"
export TRAE_PLUGIN_ROOT="$HERE"

out="$(bash "$HERE/bin/init" --repo "$REPO" --yes)"
echo "$out" | grep -q "Platform: trae" || { echo "FAIL: init 未识别 TRAE 平台"; echo "$out"; exit 1; }
# Data dir and LEARNINGS should be created in the unified cross-tool data dir
[ -f "$HOME/.dev-workflow/LEARNINGS.md" ] || { echo "FAIL: 数据区未建"; exit 1; }
# .workflow-state.yaml should be in repo .gitignore
grep -q "workflow-state.yaml" "$REPO/.gitignore" || { echo "FAIL: 未写 gitignore"; exit 1; }
grep -q "docs/superpowers/.workflow-evidence/" "$REPO/.gitignore" || { echo "FAIL: 未忽略本地工作流证据目录"; exit 1; }
echo "PASS tests/init.sh"
