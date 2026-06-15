#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
WS="$HERE/scripts/workflow-state.sh"
REPO="$(mktemp -d)"

bash "$WS" --repo "$REPO" init
f="$REPO/docs/superpowers/.workflow-state.yaml"
[ -f "$f" ] || { echo "FAIL: 未初始化状态文件"; exit 1; }

bash "$WS" --repo "$REPO" set phase spec
[ "$(bash "$WS" --repo "$REPO" get phase)" = "spec" ] || { echo "FAIL: set/get phase"; exit 1; }

# check: illegal phase should error
bash "$WS" --repo "$REPO" set phase 乱写 2>/dev/null && { echo "FAIL: 非法 phase 应拒绝"; exit 1; } || true
echo "PASS tests/workflow-state.sh"
