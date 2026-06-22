#!/usr/bin/env bash
# Self-check for the collaborating-with-codex skill.
# Verifies: codex CLI on PATH, and a live one-shot round-trip through
# codex_bridge.py returns clean JSON (this also confirms codex is logged in).
#
# Usage: scripts/selfcheck.sh
# Exit codes: 0 ok | 1 codex missing | 3 round-trip failed
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
say() { printf '%s\n' "$*"; }

if ! command -v codex >/dev/null 2>&1; then
  say "✗ codex CLI not found on PATH. Install Codex CLI and retry."
  exit 1
fi
say "✓ codex found: $(command -v codex)"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
say "→ round-trip probe (reply 'pong')..."
OUT="$(python3 "$HERE/codex_bridge.py" --cd "$TMP" \
        --PROMPT "Reply with exactly the word pong and nothing else" 2>/dev/null)"

if printf '%s' "$OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get('success') and d.get('SESSION_ID') and d.get('agent_messages') else 1)" 2>/dev/null; then
  SID="$(printf '%s' "$OUT" | python3 -c "import sys,json;print(json.load(sys.stdin)['SESSION_ID'])")"
  say "✓ round-trip OK — SESSION_ID=$SID"
  say ""; say "All checks passed. The skill is ready."
  exit 0
else
  say "✗ round-trip failed (codex logged in? \`codex login\`). Bridge output:"
  printf '%s\n' "$OUT"
  exit 3
fi
