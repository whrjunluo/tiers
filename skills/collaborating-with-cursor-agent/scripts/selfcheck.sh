#!/usr/bin/env bash
# Self-check for the collaborating-with-cursor-agent skill.
# Verifies: cursor-agent CLI on PATH, and a live one-shot round-trip through
# cursor_agent_bridge.py returns clean JSON (this also confirms it is authed).
#
# Usage: scripts/selfcheck.sh
# Exit codes: 0 ok | 1 cursor-agent missing | 3 round-trip failed
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
say() { printf '%s\n' "$*"; }

if ! command -v cursor-agent >/dev/null 2>&1; then
  say "✗ cursor-agent CLI not found on PATH. Install Cursor Agent CLI and retry."
  exit 1
fi
say "✓ cursor-agent found: $(command -v cursor-agent)"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
say "→ round-trip probe (reply 'pong')..."
OUT="$(python3 "$HERE/cursor_agent_bridge.py" --cd "$TMP" \
        --PROMPT "Reply with exactly the word pong and nothing else" 2>/dev/null)"

if printf '%s' "$OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get('success') and d.get('SESSION_ID') and d.get('agent_messages') else 1)" 2>/dev/null; then
  SID="$(printf '%s' "$OUT" | python3 -c "import sys,json;print(json.load(sys.stdin)['SESSION_ID'])")"
  say "✓ round-trip OK — SESSION_ID=$SID"
  say ""; say "All checks passed. The skill is ready."
  exit 0
else
  say "✗ round-trip failed (is cursor-agent authed? \`cursor-agent login\`). Bridge output:"
  printf '%s\n' "$OUT"
  exit 3
fi
