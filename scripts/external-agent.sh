#!/usr/bin/env bash
set -euo pipefail

repo="$PWD"
model=""

usage() {
  cat <<'EOF'
Usage: printf '%s\n' '<prompt>' | external-agent.sh [--repo DIR] [--model MODEL]

Runs Antigravity CLI non-interactively in its terminal sandbox.
EOF
}

die() {
  echo "external-agent: $1" >&2
  exit "${2:-2}"
}

while [ "${1:-}" ]; do
  case "$1" in
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

if ! command -v agy >/dev/null 2>&1; then
  echo "external-agent: agy not found on PATH" >&2
  echo "Install it with: curl -fsSL https://antigravity.google/cli/install.sh | bash" >&2
  exit 127
fi

args=(--sandbox --print "$prompt")
[ -z "$model" ] || args+=(--model "$model")

cd "$repo"
exec agy "${args[@]}"
