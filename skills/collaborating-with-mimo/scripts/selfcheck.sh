#!/usr/bin/env bash
# Self-check for the collaborating-with-mimo skill.
# Verifies: mimo CLI on PATH, a provider configured, and a live one-shot
# round-trip through mimo_bridge.py returns clean JSON.
#
# Usage:
#   scripts/selfcheck.sh [--model provider/model]
# Exit codes: 0 ok | 1 mimo missing | 2 no provider | 3 round-trip failed
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
MODEL=""
[ "${1:-}" = "--model" ] && MODEL="$2"

say() { printf '%s\n' "$*"; }

# 1) mimo on PATH
if ! command -v mimo >/dev/null 2>&1; then
  say "✗ mimo CLI not found on PATH. Install MiMoCode and retry."
  exit 1
fi
say "✓ mimo found: $(command -v mimo)"

# 2) provider configured (models list must be non-empty)
MODELS="$(mimo models 2>/dev/null)"
if [ -z "$MODELS" ]; then
  say "✗ No models available. Configure a provider: mimo providers login"
  exit 2
fi
say "✓ provider OK ($(printf '%s\n' "$MODELS" | grep -c . ) models available)"
[ -z "$MODEL" ] && MODEL="$(printf '%s\n' "$MODELS" | grep -i 'pro' | head -1)"
[ -z "$MODEL" ] && MODEL="$(printf '%s\n' "$MODELS" | head -1)"
say "  using model: $MODEL"

# 3) live round-trip through the bridge
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
say "→ round-trip probe (reply 'pong')..."
OUT="$(python3 "$HERE/mimo_bridge.py" --cd "$TMP" --model "$MODEL" \
        --PROMPT "Reply with exactly the word pong and nothing else" 2>/dev/null)"

if printf '%s' "$OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get('success') and d.get('SESSION_ID') and d.get('agent_messages') else 1)" 2>/dev/null; then
  SID="$(printf '%s' "$OUT" | python3 -c "import sys,json;print(json.load(sys.stdin)['SESSION_ID'])")"
  MSG="$(printf '%s' "$OUT" | python3 -c "import sys,json;print(json.load(sys.stdin)['agent_messages'][:40])")"
  say "✓ round-trip OK — SESSION_ID=$SID reply=$(printf '%q' "$MSG")"
  say ""
  say "All checks passed. The skill is ready."
  exit 0
else
  say "✗ round-trip failed. Bridge output:"
  printf '%s\n' "$OUT"
  exit 3
fi
