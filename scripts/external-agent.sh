#!/usr/bin/env bash
set -euo pipefail

repo="$PWD"
model=""
agent="antigravity"

usage() {
  cat <<'EOF'
Usage: printf '%s\n' '<prompt>' | external-agent.sh [--agent antigravity|cursor|grok] [--repo DIR] [--model MODEL]

Runs one independent external agent CLI non-interactively with conservative permissions.

Agents:
  antigravity  Antigravity CLI (agy). Default.
  cursor       Cursor Agent CLI (cursor-agent).
  grok         Grok CLI (grok).
EOF
}

die() {
  echo "external-agent: $1" >&2
  exit "${2:-2}"
}

while [ "${1:-}" ]; do
  case "$1" in
    --agent)
      [ -n "${2:-}" ] || die "--agent requires antigravity, cursor, or grok"
      agent="$2"
      shift 2
      ;;
    --repo)
      [ -n "${2:-}" ] || die "--repo requires a directory"
      repo="$2"
      shift 2
      ;;
    --model)
      [ -n "${2:-}" ] || die "--model requires a value"
      model="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -d "$repo" ] || die "directory does not exist: $repo"

prompt="$(cat)"
[ -n "${prompt//[$' \t\r\n']/}" ] || die "prompt must not be empty"

case "$agent" in
  antigravity|agy)
    if ! command -v agy >/dev/null 2>&1; then
      echo "external-agent: agy not found on PATH" >&2
      echo "Install it with: curl -fsSL https://antigravity.google/cli/install.sh | bash" >&2
      exit 127
    fi

    args=(--sandbox --print "$prompt")
    [ -z "$model" ] || args+=(--model "$model")

    cd "$repo"
    exec agy "${args[@]}"
    ;;
  cursor|cursor-agent)
    if ! command -v cursor-agent >/dev/null 2>&1; then
      echo "external-agent: cursor-agent not found on PATH" >&2
      echo "Install Cursor Agent CLI and run 'cursor-agent login' if authentication is missing." >&2
      exit 127
    fi

    args=(--print --mode ask --sandbox enabled --trust --workspace "$repo")
    [ -z "$model" ] || args+=(--model "$model")
    args+=("$prompt")

    cd "$repo"
    exec cursor-agent "${args[@]}"
    ;;
  grok)
    if ! command -v grok >/dev/null 2>&1; then
      echo "external-agent: grok not found on PATH" >&2
      echo "Install Grok CLI and run 'grok login' if authentication is missing." >&2
      exit 127
    fi

    args=(--cwd "$repo" --permission-mode plan --sandbox workspace --disable-web-search --no-subagents --no-memory)
    [ -z "$model" ] || args+=(--model "$model")
    args+=(--single "$prompt")

    cd "$repo"
    exec grok "${args[@]}"
    ;;
  *)
    die "unknown agent: $agent (expected antigravity, cursor, or grok)"
    ;;
esac
