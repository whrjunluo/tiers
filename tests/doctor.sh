#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SBOX="$(mktemp -d)"
export HOME="$SBOX/home"
export CODEX_HOME="$HOME/.codex"
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
REPO="$SBOX/repo"
mkdir -p "$CODEX_HOME" "$REPO"

out="$(bash "$HERE/bin/doctor" --repo "$REPO" --codex-home "$CODEX_HOME" --platform codex)"

echo "$out" | grep -q "Capability level: base" || { echo "FAIL: should report base capability"; echo "$out"; exit 1; }
echo "$out" | grep -q "Required tools: ok" || { echo "FAIL: required tools should be ok"; echo "$out"; exit 1; }
echo "$out" | grep -q "Built-in skills: ok" || { echo "FAIL: built-in skills should be ok"; echo "$out"; exit 1; }
echo "$out" | grep -q "superpowers: missing" || { echo "FAIL: should report missing superpowers"; echo "$out"; exit 1; }
echo "$out" | grep -q "code-review-graph: missing" || { echo "FAIL: should report missing codegraph"; echo "$out"; exit 1; }
echo "$out" | grep -q "Figma fidelity: missing" || { echo "FAIL: should report missing figma fidelity skill"; echo "$out"; exit 1; }
echo "$out" | grep -q "Adversarial review: built-in" || { echo "FAIL: should report built-in adversarial review fallback"; echo "$out"; exit 1; }
echo "$out" | grep -q "No automatic install was run" || { echo "FAIL: doctor must not install by default"; echo "$out"; exit 1; }

BIN="$SBOX/bin"
mkdir -p "$BIN"
printf '#!/usr/bin/env sh\nexit 0\n' > "$BIN/codex"
printf '#!/usr/bin/env sh\nexit 0\n' > "$BIN/grok"
chmod +x "$BIN/codex" "$BIN/grok"
out_external="$(PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin" bash "$HERE/bin/doctor" --repo "$REPO" --codex-home "$CODEX_HOME" --platform codex)"
echo "$out_external" | grep -q "Adversarial review: external-ready" || { echo "FAIL: should report external-ready with two external CLIs"; echo "$out_external"; exit 1; }

echo "PASS tests/doctor.sh"
