#!/usr/bin/env bash
# Dependency and capability doctor for dev-workflow.
set -euo pipefail

PLUGIN_ROOT="${DEV_WORKFLOW_PLUGIN_ROOT:-${CODEX_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CURSOR_PLUGIN_ROOT:-${TRAE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}}}}}"

REPO="$PWD"
CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
TRAE_HOME_DIR="${TRAE_HOME:-$HOME/.trae-cn}"
DEV_WORKFLOW_DATA_DIR="${DEV_WORKFLOW_DATA:-$HOME/.dev-workflow}"
PLATFORM=""
INSTALL_DEPS=0

while [ "${1:-}" ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --codex-home) CODEX_HOME_DIR="$2"; shift 2 ;;
    --trae-home) TRAE_HOME_DIR="$2"; shift 2 ;;
    --platform) PLATFORM="$2"; shift 2 ;;
    --install-deps) INSTALL_DEPS=1; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$PLATFORM" ]; then
  if [ -n "${CODEX_PLUGIN_ROOT:-}" ] || [ -n "${CODEX_HOME:-}" ]; then
    PLATFORM=codex
  elif [ -n "${CURSOR_PLUGIN_ROOT:-}" ] || [ -n "${CURSOR_HOME:-}" ]; then
    PLATFORM=cursor
  elif [ -n "${TRAE_PLUGIN_ROOT:-}" ] || [ -n "${TRAE_HOME:-}" ]; then
    PLATFORM=trae
  else
    PLATFORM=claude-code
  fi
fi

have() { command -v "$1" >/dev/null 2>&1; }

skill_present() {
  local pattern="$1"
  find "$CODEX_HOME_DIR/skills" "$TRAE_HOME_DIR/skills" "$HOME/.traecli/skills" "$HOME/.agents/skills" "$HOME/.claude" -maxdepth 6 -type d -name "$pattern" 2>/dev/null | grep -q .
}

status() {
  local label="$1" state="$2" detail="${3:-}"
  if [ -n "$detail" ]; then
    printf '%s: %s (%s)\n' "$label" "$state" "$detail"
  else
    printf '%s: %s\n' "$label" "$state"
  fi
}

missing_required=0
missing_required_names=""
for tool in bash awk python3 git; do
  if ! have "$tool"; then
    missing_required=1
    missing_required_names="${missing_required_names}${missing_required_names:+, }$tool"
  fi
done

missing_builtin=0
missing_builtin_names=""
for skill in dev-workflow grill-me grilling external-agent; do
  if [ ! -d "$PLUGIN_ROOT/skills/$skill" ]; then
    missing_builtin=1
    missing_builtin_names="${missing_builtin_names}${missing_builtin_names:+, }$skill"
  fi
done

superpowers=missing
skill_present '*superpowers*' && superpowers=ok

grill_docs=missing
skill_present grill-with-docs && grill_docs=ok

figma_fidelity=missing
skill_present figma-fidelity-verification && figma_fidelity=ok

codegraph=missing
if have code-review-graph; then
  if [ -f "$REPO/.code-review-graph/graph.db" ]; then
    codegraph="ok"
  else
    codegraph="cli-only"
  fi
fi

external_ready=0
external_families=""
external_family_count=0
for entry in codex:openai cursor-agent:cursor grok:xai agy:google opencode:configurable mimo:xiaomi; do
  cli="${entry%%:*}"
  family="${entry#*:}"
  if have "$cli"; then
    external_ready=$((external_ready + 1))
    case " $external_families " in
      *" $family "*) ;;
      *) external_families="${external_families}${external_families:+ }$family"; external_family_count=$((external_family_count + 1)) ;;
    esac
  fi
done
adversarial_review=built-in
if [ "$external_family_count" -eq 1 ]; then
  adversarial_review=external-partial
elif [ "$external_family_count" -ge 2 ]; then
  adversarial_review=external-ready
fi

level=base
if [ "$missing_required" = 1 ] || [ "$missing_builtin" = 1 ]; then
  level=broken
elif [ "$superpowers" = ok ] && { [ "$codegraph" = ok ] || [ "$codegraph" = cli-only ]; }; then
  level=enhanced
fi
if [ "$level" = enhanced ] && [ "$figma_fidelity" = ok ] && [ "$codegraph" = ok ]; then
  level=full
fi

echo "dev-workflow doctor"
echo "Platform: $PLATFORM"
echo "Capability level: $level"
if [ "$missing_required" = 0 ]; then
  status "Required tools" ok
else
  status "Required tools" missing "$missing_required_names"
fi
if [ "$missing_builtin" = 0 ]; then
  status "Built-in skills" ok
else
  status "Built-in skills" missing "$missing_builtin_names"
fi
status "superpowers" "$superpowers" "optional enhanced L1/TDD/review skill chain"
status "grill-with-docs" "$grill_docs" "optional upgrade; built-in grilling is available"
status "Figma fidelity" "$figma_fidelity" "optional UI design verification workflow"
status "code-review-graph" "$codegraph" "optional risk calibration and MCP registration"
status "external-agent CLIs" "$external_ready available" "$external_family_count distinct families; codex/cursor-agent/grok/agy/opencode/mimo"
status "Adversarial review" "$adversarial_review" "installed CLIs are candidates; actual quorum requires successful calls from 2+ distinct families"
if have python3; then
  health_summary="$(python3 - "$DEV_WORKFLOW_DATA_DIR/external-agent-health.json" <<'PY'
import json, sys
try:
    agents = json.load(open(sys.argv[1])).get("agents", {})
except (FileNotFoundError, OSError, ValueError, json.JSONDecodeError):
    agents = {}
marked = []
for name, state in sorted(agents.items()):
    status = state.get("status")
    if status not in ("slow", "degraded"):
        continue
    timeout = state.get("recommended_timeout_seconds")
    suffix = f"({timeout}s)" if timeout else ""
    marked.append(f"{name}:{status}{suffix}")
overall = "degraded" if any(":degraded" in item for item in marked) else ("slow" if marked else "ok")
print(overall + "|" + (", ".join(marked) if marked else "no persistent slow/degraded markers"))
PY
)"
else
  health_summary="unavailable|python3 missing; persistent provider markers not inspected"
fi
status "External agent health" "${health_summary%%|*}" "${health_summary#*|}"

echo
echo "Install commands:"
echo "  Codex skills: npx skills@latest add obra/superpowers"
echo "  Grill upgrade: npx skills@latest add mattpocock/skills"
echo "  code-review-graph: uv tool install code-review-graph"
echo "  codegraph MCP: run bin/init --repo <project> --yes after code-review-graph is installed"
echo "  Figma fidelity: install the figma-fidelity-verification skill/MCP bundle for design-source checks"

if [ "$INSTALL_DEPS" = 1 ]; then
  echo
  echo "Automatic install requested."
  if [ "$superpowers" = missing ] && [ "$PLATFORM" = codex ]; then
    CODEX_HOME="$CODEX_HOME_DIR" npx -y skills@latest add obra/superpowers || echo "  warning: superpowers install failed"
  fi
  if [ "$grill_docs" = missing ]; then
    npx -y skills@latest add mattpocock/skills || echo "  warning: grill-with-docs install failed"
  fi
  if [ "$codegraph" = missing ]; then
    if have uv; then uv tool install code-review-graph
    elif have pipx; then pipx install code-review-graph
    elif have pip; then pip install code-review-graph
    else echo "  warning: no uv/pipx/pip found for code-review-graph install"; fi || true
  fi
else
  echo
  echo "No automatic install was run. Re-run with --install-deps to install scriptable optional dependencies."
fi
