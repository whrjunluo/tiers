#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SBOX="$(mktemp -d)"
export HOME="$SBOX/home"
export CODEX_HOME="$HOME/.codex"
export DEV_WORKFLOW_DATA="$SBOX/data"
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

BROKEN_PLUGIN="$SBOX/broken-plugin"
mkdir -p "$BROKEN_PLUGIN/skills" "$BROKEN_PLUGIN/scripts"
cp "$HERE/scripts/dependency-doctor.sh" "$BROKEN_PLUGIN/scripts/dependency-doctor.sh"
cp -R "$HERE/skills/dev-workflow" "$BROKEN_PLUGIN/skills/dev-workflow"
cp -R "$HERE/skills/grill-me" "$BROKEN_PLUGIN/skills/grill-me"
cp -R "$HERE/skills/external-agent" "$BROKEN_PLUGIN/skills/external-agent"
out_missing_grilling="$(DEV_WORKFLOW_PLUGIN_ROOT="$BROKEN_PLUGIN" bash "$HERE/bin/doctor" --repo "$REPO" --codex-home "$CODEX_HOME" --platform codex)"
echo "$out_missing_grilling" | grep -q "Capability level: broken" || { echo "FAIL: missing grilling should break base capability"; echo "$out_missing_grilling"; exit 1; }
echo "$out_missing_grilling" | grep -q "Built-in skills: missing (grilling)" || { echo "FAIL: doctor should name missing grilling"; echo "$out_missing_grilling"; exit 1; }

BIN="$SBOX/bin"
mkdir -p "$BIN"
printf '#!/usr/bin/env sh\nexit 0\n' > "$BIN/codex"
printf '#!/usr/bin/env sh\nexit 0\n' > "$BIN/grok"
printf '#!/usr/bin/env sh\nexit 0\n' > "$BIN/kimi"
chmod +x "$BIN/codex" "$BIN/grok" "$BIN/kimi"
mkdir -p "$DEV_WORKFLOW_DATA"
printf '%s\n' '{"version":1,"agents":{"antigravity":{"status":"slow","recommended_timeout_seconds":360,"timeout_count":1,"consecutive_timeouts":0,"success_count":2}}}' > "$DEV_WORKFLOW_DATA/external-agent-health.json"
out_external="$(PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin" bash "$HERE/bin/doctor" --repo "$REPO" --codex-home "$CODEX_HOME" --platform codex)"
echo "$out_external" | grep -q "Adversarial review: external-ready" || { echo "FAIL: should report external-ready with two external CLIs"; echo "$out_external"; exit 1; }
echo "$out_external" | grep -q "3 distinct families" || { echo "FAIL: doctor should report distinct family count"; echo "$out_external"; exit 1; }
echo "$out_external" | grep -q "kimi" || { echo "FAIL: doctor should list Kimi as a detected external CLI"; echo "$out_external"; exit 1; }
echo "$out_external" | grep -q "actual quorum requires successful calls" || { echo "FAIL: doctor should distinguish installed candidates from passed quorum"; echo "$out_external"; exit 1; }
echo "$out_external" | grep -q "External agent health: slow" || { echo "FAIL: doctor should surface persistent provider health"; echo "$out_external"; exit 1; }
echo "$out_external" | grep -q "antigravity:slow(360s)" || { echo "FAIL: doctor should include the slow provider timeout recommendation"; echo "$out_external"; exit 1; }

# A broken environment still needs a complete doctor report when Python is absent.
NO_PYTHON_BIN="$SBOX/no-python-bin"
mkdir -p "$NO_PYTHON_BIN"
for tool in bash awk git find grep dirname; do
  tool_path="$(type -P "$tool")"
  ln -s "$tool_path" "$NO_PYTHON_BIN/$tool"
done
if ! out_no_python="$(PATH="$NO_PYTHON_BIN" "$NO_PYTHON_BIN/bash" "$HERE/bin/doctor" --repo "$REPO" --codex-home "$CODEX_HOME" --platform codex 2>&1)"; then
  echo "FAIL: doctor should finish when python3 is missing"
  echo "$out_no_python"
  exit 1
fi
echo "$out_no_python" | grep -q "Required tools: missing (python3)" || { echo "FAIL: doctor should identify missing python3"; echo "$out_no_python"; exit 1; }
echo "$out_no_python" | grep -q "External agent health: unavailable" || { echo "FAIL: health summary should degrade cleanly without python3"; echo "$out_no_python"; exit 1; }

echo "PASS tests/doctor.sh"

out_trae="$(TRAE_HOME="$HOME/.trae-cn" bash "$HERE/bin/doctor" --repo "$REPO" --platform trae)"
echo "$out_trae" | grep -q "Platform: trae" || { echo "FAIL: doctor should report TRAE platform"; echo "$out_trae"; exit 1; }
