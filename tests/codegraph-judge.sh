#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
CG="$HERE/scripts/codegraph-judge.sh"
REPO="$(mktemp -d)"   # empty dir, no codegraph

# No code-review-graph or no graph.db → exit code 3 (unavailable), show degradation message
set +e
out="$(bash "$CG" --repo "$REPO" assess 2>&1)"; rc=$?
set -e
[ "$rc" = "3" ] || { echo "FAIL: 不可用时应退出码 3，实际 $rc"; exit 1; }
echo "$out" | grep -q "降级" || { echo "FAIL: 应提示降级"; exit 1; }
echo "PASS tests/codegraph-judge.sh"
