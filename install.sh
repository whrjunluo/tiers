#!/usr/bin/env bash
# Bootstrap a managed dev-workflow installation for Codex and/or Cursor.
set -euo pipefail

DEFAULT_REPO_URL="https://github.com/whrjunluo/tiers.git"
RAW_INSTALL_URL="https://raw.githubusercontent.com/whrjunluo/tiers/main/install.sh"
PLATFORM=""
CHANNEL="stable"
INSTALL_DEPS=0

die() { echo "dev-workflow installer: $*" >&2; exit 1; }
select_platform() {
  [ -z "$PLATFORM" ] || die "select exactly one of --codex, --cursor, or --all"
  PLATFORM="$1"
}

while [ "${1:-}" ]; do
  case "$1" in
    --codex) select_platform codex; shift ;;
    --cursor) select_platform cursor; shift ;;
    --all) select_platform all; shift ;;
    --channel)
      [ -n "${2:-}" ] || die "--channel requires stable or edge"
      CHANNEL="$2"
      shift 2
      ;;
    --install-deps) INSTALL_DEPS=1; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$PLATFORM" ] || die "select exactly one of --codex, --cursor, or --all"
case "$CHANNEL" in stable|edge) ;; *) die "channel must be stable or edge" ;; esac
command -v git >/dev/null 2>&1 || die "git is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required"

REPO_URL="${DEV_WORKFLOW_REPO_URL:-$DEFAULT_REPO_URL}"
INSTALL_ROOT="${DEV_WORKFLOW_INSTALL_ROOT:-$HOME/.local/share/dev-workflow}"
BIN_DIR="${DEV_WORKFLOW_BIN_DIR:-$HOME/.local/bin}"
SOURCE_GIT="$INSTALL_ROOT/source.git"
VERSIONS="$INSTALL_ROOT/versions"
LOCK_DIR="$INSTALL_ROOT/update.lock"

mkdir -p "$INSTALL_ROOT" "$VERSIONS" "$BIN_DIR"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  die "another dev-workflow update is already in progress ($LOCK_DIR)"
fi
cleanup() { rmdir "$LOCK_DIR" 2>/dev/null || true; }
trap cleanup EXIT

if [ ! -e "$SOURCE_GIT" ]; then
  git clone --bare "$REPO_URL" "$SOURCE_GIT"
else
  git --git-dir "$SOURCE_GIT" rev-parse --is-bare-repository >/dev/null 2>&1 || \
    die "managed repository is invalid: $SOURCE_GIT"
  git --git-dir "$SOURCE_GIT" remote set-url origin "$REPO_URL"
fi
git --git-dir "$SOURCE_GIT" fetch --prune --prune-tags origin \
  +refs/heads/main:refs/remotes/origin/main \
  +refs/tags/*:refs/tags/*

if [ "$CHANNEL" = stable ]; then
  TAG="$(git --git-dir "$SOURCE_GIT" tag --list | python3 -c '
import re, sys
pattern = re.compile(r"^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
matches = []
for raw in sys.stdin:
    tag = raw.strip()
    match = pattern.fullmatch(tag)
    if match:
        matches.append((tuple(map(int, match.groups())), tag))
print(max(matches)[1] if matches else "")
')"
  [ -n "$TAG" ] || die "No stable release tag matching v<major>.<minor>.<patch> was found"
  REF="refs/tags/$TAG"
  COMMIT="$(git --git-dir "$SOURCE_GIT" rev-parse "$REF^{commit}")"
else
  REF="refs/remotes/origin/main"
  COMMIT="$(git --git-dir "$SOURCE_GIT" rev-parse "$REF^{commit}")"
fi

CANDIDATE="$VERSIONS/$COMMIT"
if [ ! -d "$CANDIDATE" ]; then
  git --git-dir "$SOURCE_GIT" worktree add --detach "$CANDIDATE" "$COMMIT"
fi

BOOTSTRAP_ARGS=(
  _bootstrap
  --channel "$CHANNEL"
  --ref "$REF"
  --commit "$COMMIT"
  --platform "$PLATFORM"
)
if [ "$INSTALL_DEPS" = 1 ]; then
  BOOTSTRAP_ARGS+=(--install-deps)
fi

DEV_WORKFLOW_REPO_URL="$REPO_URL" \
DEV_WORKFLOW_INSTALL_ROOT="$INSTALL_ROOT" \
DEV_WORKFLOW_BIN_DIR="$BIN_DIR" \
DEV_WORKFLOW_BOOTSTRAP_LOCK_HELD=1 \
python3 "$CANDIDATE/bin/dev-workflow" "${BOOTSTRAP_ARGS[@]}"

echo "Installer source: $RAW_INSTALL_URL"
echo "Inspect first: curl -fsSLO $RAW_INSTALL_URL && less install.sh"
