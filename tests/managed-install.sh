#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SOURCE="$TMP/source"
REMOTE="$TMP/remote.git"
HOME_DIR="$TMP/home"
INSTALL_ROOT="$TMP/managed"
BIN_DIR="$TMP/bin"
LOG="$TMP/platform.log"
OUTSIDE="$TMP/outside"
mkdir -p "$SOURCE" "$HOME_DIR" "$BIN_DIR" "$OUTSIDE"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() {
  case "$1" in *"$2"*) ;; *) fail "expected output to contain '$2', got: $1" ;; esac
}
assert_state() {
  python3 - "$INSTALL_ROOT/install.json" "$1" "$2" <<'PY'
import json
import sys

state = json.load(open(sys.argv[1], encoding="utf-8"))
field, expected = sys.argv[2:]
actual = state[field]
if isinstance(actual, list):
    actual = ",".join(actual)
if str(actual) != expected:
    raise SystemExit(f"{field}: expected {expected!r}, found {actual!r}")
PY
}

python3 - "$ROOT" "$SOURCE" <<'PY'
import json
import shutil
import sys
from pathlib import Path

root, source = map(Path, sys.argv[1:])
(source / "scripts").mkdir(parents=True)
(source / "bin").mkdir(parents=True)
shutil.copy2(root / "scripts/managed_install.py", source / "scripts/managed_install.py")
shutil.copy2(root / "bin/dev-workflow", source / "bin/dev-workflow")

for manifest in (
    ".codex-plugin/plugin.json",
    ".cursor-plugin/plugin.json",
    ".claude-plugin/plugin.json",
):
    path = source / manifest
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"version": "0.7.0"}) + "\n", encoding="utf-8")

scripts = {
    "install-codex": """#!/usr/bin/env bash
set -euo pipefail
printf 'codex:%s:root=%s\\n' "$*" "${DEV_WORKFLOW_PLUGIN_ROOT:-}" >> "$TEST_LOG"
[ "${FAIL_CODEX:-0}" != 1 ] || exit 41
""",
    "install-cursor": """#!/usr/bin/env bash
set -euo pipefail
printf 'cursor:%s:root=%s\\n' "$*" "${DEV_WORKFLOW_PLUGIN_ROOT:-}" >> "$TEST_LOG"
[ "${FAIL_CURSOR:-0}" != 1 ] || exit 42
""",
    "doctor": """#!/usr/bin/env bash
set -euo pipefail
printf 'doctor:%s:root=%s\\n' "$*" "${DEV_WORKFLOW_PLUGIN_ROOT:-}" >> "$TEST_LOG"
[ "${FAIL_DOCTOR:-0}" != 1 ] || exit 43
""",
}
for name, content in scripts.items():
    path = source / "bin" / name
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)

for skill in ("dev-workflow", "external-agent", "grill-me"):
    path = source / "skills" / skill / "SKILL.md"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(f"# {skill}\n", encoding="utf-8")
PY

git -C "$SOURCE" init -q -b main
git -C "$SOURCE" config user.name "Managed Install Test"
git -C "$SOURCE" config user.email "managed-install@example.test"
git -C "$SOURCE" add .
git -C "$SOURCE" commit -qm "stable fixture"
git -C "$SOURCE" tag v0.7.0
STABLE_COMMIT="$(git -C "$SOURCE" rev-parse HEAD)"

python3 - "$SOURCE" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
for manifest in (
    ".codex-plugin/plugin.json",
    ".cursor-plugin/plugin.json",
    ".claude-plugin/plugin.json",
):
    path = root / manifest
    data = json.loads(path.read_text(encoding="utf-8"))
    data["version"] = "0.8.0"
    path.write_text(json.dumps(data) + "\n", encoding="utf-8")
PY
git -C "$SOURCE" add .
git -C "$SOURCE" commit -qm "edge fixture"
EDGE_COMMIT="$(git -C "$SOURCE" rev-parse HEAD)"
git clone -q --bare "$SOURCE" "$REMOTE"

mkdir -p "$INSTALL_ROOT/versions"
git clone -q --bare "$REMOTE" "$INSTALL_ROOT/source.git"
git --git-dir "$INSTALL_ROOT/source.git" fetch -q origin \
  +refs/heads/main:refs/remotes/origin/main +refs/tags/*:refs/tags/*
git --git-dir "$INSTALL_ROOT/source.git" worktree add -q --detach \
  "$INSTALL_ROOT/versions/$STABLE_COMMIT" "$STABLE_COMMIT"
ln -s "$INSTALL_ROOT/versions/$STABLE_COMMIT" "$INSTALL_ROOT/current"
ln -s "$INSTALL_ROOT/current/bin/dev-workflow" "$BIN_DIR/dev-workflow"
python3 - "$INSTALL_ROOT/install.json" "$STABLE_COMMIT" <<'PY'
import json
import sys
from pathlib import Path

Path(sys.argv[1]).write_text(json.dumps({
    "schema_version": 1,
    "channel": "stable",
    "platforms": ["codex"],
    "active_ref": "refs/tags/v0.7.0",
    "active_commit": sys.argv[2],
    "manifest_version": "0.7.0",
    "updated_at": "2026-07-13T00:00:00Z",
}) + "\n", encoding="utf-8")
PY

export HOME="$HOME_DIR"
export CODEX_HOME="$HOME_DIR/.codex"
export CURSOR_HOME="$HOME_DIR/.cursor"
export DEV_WORKFLOW_DATA="$HOME_DIR/.dev-workflow"
export DEV_WORKFLOW_REPO_URL="$REMOTE"
export DEV_WORKFLOW_INSTALL_ROOT="$INSTALL_ROOT"
export DEV_WORKFLOW_BIN_DIR="$BIN_DIR"
export TEST_LOG="$LOG"
export PATH="$BIN_DIR:$PATH"

status="$(cd "$OUTSIDE" && dev-workflow status)"
assert_contains "$status" "Channel: stable"
assert_contains "$status" "Manifest version: 0.7.0"
assert_contains "$status" "Platforms: codex"

dev-workflow update --channel edge >/dev/null
assert_state channel edge
assert_state active_commit "$EDGE_COMMIT"
assert_state manifest_version 0.8.0

before="$(cat "$INSTALL_ROOT/install.json")"
if FAIL_CURSOR=1 dev-workflow install cursor >"$TMP/failure.out" 2>&1; then
  fail "cursor installer failure should fail the command"
fi
assert_contains "$(cat "$TMP/failure.out")" "install-cursor"
[ "$(cat "$INSTALL_ROOT/install.json")" = "$before" ] || fail "failed platform install changed state"
assert_state platforms codex

dev-workflow install cursor >/dev/null
assert_state platforms codex,cursor

: > "$LOG"
dev-workflow install all --install-deps >/dev/null
assert_contains "$(cat "$LOG")" "codex:--yes --install-deps"
assert_contains "$(cat "$LOG")" "cursor:--yes --install-deps"

: > "$LOG"
dev-workflow doctor --repo "$OUTSIDE" --install-deps >/dev/null
assert_contains "$(cat "$LOG")" "doctor:--repo $OUTSIDE --install-deps"

mkdir "$INSTALL_ROOT/update.lock"
if dev-workflow update >"$TMP/lock.out" 2>&1; then
  fail "contended update should fail"
fi
assert_contains "$(cat "$TMP/lock.out")" "already in progress"
rmdir "$INSTALL_ROOT/update.lock"

DEV_WORKFLOW_REPO_URL="$TMP/unavailable.git" dev-workflow status >/dev/null

echo "managed-install CLI: PASS"
