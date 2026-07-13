#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SBOX="$(mktemp -d)"
trap 'rm -rf "$SBOX"' EXIT
export HOME="$SBOX/home"
export CODEX_HOME="$HOME/.codex"
export CURSOR_HOME="$HOME/.cursor"

bash "$HERE/bin/install-codex" --codex-home "$CODEX_HOME" --yes >/dev/null
bash "$HERE/bin/install-cursor" --cursor-home "$CURSOR_HOME" --yes >/dev/null

ln -sfn "$SBOX/stale-codex" "$CODEX_HOME/skills/dev-workflow"
ln -sfn "$SBOX/stale-cursor" "$CURSOR_HOME/skills/dev-workflow"

out="$(bash "$HERE/bin/update" --codex --cursor)"
[ "$(readlink "$CODEX_HOME/skills/dev-workflow")" = "$HERE/skills/dev-workflow" ] || { echo "FAIL: Codex skill link not refreshed"; exit 1; }
[ "$(readlink "$CURSOR_HOME/skills/dev-workflow")" = "$HERE/skills/dev-workflow" ] || { echo "FAIL: Cursor skill link not refreshed"; exit 1; }
echo "$out" | grep -q 'Updated dev-workflow 0.6.0' || { echo "FAIL: update summary missing"; echo "$out"; exit 1; }
echo "$out" | grep -q 'Restart Codex' || { echo "FAIL: reload guidance missing"; echo "$out"; exit 1; }
bash "$HERE/bin/update" --codex >/dev/null || { echo "FAIL: Codex-only update should exit zero"; exit 1; }
grep -q 'bin/update --codex' "$HERE/README.md" || { echo "FAIL: README missing Codex update command"; exit 1; }
grep -q -- '--pull' "$HERE/README.md" || { echo "FAIL: README missing remote pull option"; exit 1; }

echo "PASS tests/update.sh"
