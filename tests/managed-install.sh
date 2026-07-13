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
resolved_current() {
  python3 - "$1/current" <<'PY'
import sys
from pathlib import Path
print(Path(sys.argv[1]).resolve())
PY
}

release_versions="$(python3 - "$ROOT" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
manifests = (
    ".codex-plugin/plugin.json",
    ".cursor-plugin/plugin.json",
    ".claude-plugin/plugin.json",
)
print(",".join(json.loads((root / path).read_text(encoding="utf-8"))["version"] for path in manifests))
PY
)"
[ "$release_versions" = "0.7.0,0.7.0,0.7.0" ] || \
  fail "release manifests must all be 0.7.0, found $release_versions"

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

BOOT_HOME="$TMP/bootstrap-home"
BOOT_ROOT="$TMP/bootstrap-managed"
BOOT_BIN="$TMP/bootstrap-bin"
BOOT_DATA="$BOOT_HOME/.dev-workflow"
mkdir -p "$BOOT_DATA" "$BOOT_BIN"
printf 'keep-me\n' > "$BOOT_DATA/user-note.txt"

bootstrap() {
  HOME="$BOOT_HOME" \
  DEV_WORKFLOW_REPO_URL="$REMOTE" \
  DEV_WORKFLOW_INSTALL_ROOT="$BOOT_ROOT" \
  DEV_WORKFLOW_BIN_DIR="$BOOT_BIN" \
  DEV_WORKFLOW_DATA="$BOOT_DATA" \
  TEST_LOG="$LOG" \
  bash "$ROOT/install.sh" "$@"
}

if bootstrap >"$TMP/no-platform.out" 2>&1; then
  fail "bootstrap without a platform should fail"
fi
assert_contains "$(cat "$TMP/no-platform.out")" "exactly one"
if bootstrap --codex --cursor >"$TMP/two-platforms.out" 2>&1; then
  fail "bootstrap with multiple platform flags should fail"
fi
assert_contains "$(cat "$TMP/two-platforms.out")" "exactly one"
if PATH="$TMP/empty-path" /bin/bash "$ROOT/install.sh" --codex >"$TMP/prereq.out" 2>&1; then
  fail "bootstrap without git should fail"
fi
assert_contains "$(cat "$TMP/prereq.out")" "git is required"

bootstrap --codex >/dev/null
assert_state_file="$BOOT_ROOT/install.json"
python3 - "$assert_state_file" "$STABLE_COMMIT" <<'PY'
import json
import sys

state = json.load(open(sys.argv[1], encoding="utf-8"))
assert state["channel"] == "stable", state
assert state["platforms"] == ["codex"], state
assert state["active_commit"] == sys.argv[2], state
assert state["manifest_version"] == "0.7.0", state
PY
[ -L "$BOOT_ROOT/current" ] || fail "bootstrap did not create current symlink"
[ -L "$BOOT_BIN/dev-workflow" ] || fail "bootstrap did not create global command symlink"
[ "$(cat "$BOOT_DATA/user-note.txt")" = "keep-me" ] || fail "bootstrap changed user data"
PYTHON_CACHE="$TMP/python-cache"
HOME="$BOOT_HOME" DEV_WORKFLOW_INSTALL_ROOT="$BOOT_ROOT" DEV_WORKFLOW_BIN_DIR="$BOOT_BIN" \
  PYTHONPYCACHEPREFIX="$PYTHON_CACHE" \
  "$BOOT_BIN/dev-workflow" status >/dev/null
[ -z "$(find "$PYTHON_CACHE" -type f -name 'managed_install*.pyc' -print 2>/dev/null)" ] || \
  fail "managed command wrote bytecode for the managed installer"
[ -z "$(git -C "$BOOT_ROOT/versions/$STABLE_COMMIT" status --porcelain)" ] || \
  fail "managed command wrote runtime files into the immutable candidate"

old_current="$(resolved_current "$BOOT_ROOT")"
old_state="$(cat "$BOOT_ROOT/install.json")"
if HOME="$BOOT_HOME" DEV_WORKFLOW_REPO_URL="$REMOTE" DEV_WORKFLOW_INSTALL_ROOT="$BOOT_ROOT" \
  DEV_WORKFLOW_BIN_DIR="$BOOT_BIN" DEV_WORKFLOW_DATA="$BOOT_DATA" TEST_LOG="$LOG" FAIL_CODEX=1 \
  "$BOOT_BIN/dev-workflow" update --channel edge >"$TMP/platform-rollback.out" 2>&1; then
  fail "platform failure should roll back update"
fi
[ "$(resolved_current "$BOOT_ROOT")" = "$old_current" ] || fail "platform failure changed current"
[ "$(cat "$BOOT_ROOT/install.json")" = "$old_state" ] || fail "platform failure changed state"

if HOME="$BOOT_HOME" DEV_WORKFLOW_REPO_URL="$REMOTE" DEV_WORKFLOW_INSTALL_ROOT="$BOOT_ROOT" \
  DEV_WORKFLOW_BIN_DIR="$BOOT_BIN" DEV_WORKFLOW_DATA="$BOOT_DATA" TEST_LOG="$LOG" FAIL_DOCTOR=1 \
  "$BOOT_BIN/dev-workflow" update --channel edge >"$TMP/doctor-rollback.out" 2>&1; then
  fail "doctor failure should roll back update"
fi
[ "$(resolved_current "$BOOT_ROOT")" = "$old_current" ] || fail "doctor failure changed current"
[ "$(cat "$BOOT_ROOT/install.json")" = "$old_state" ] || fail "doctor failure changed state"

HOME="$BOOT_HOME" DEV_WORKFLOW_REPO_URL="$REMOTE" DEV_WORKFLOW_INSTALL_ROOT="$BOOT_ROOT" \
  DEV_WORKFLOW_BIN_DIR="$BOOT_BIN" DEV_WORKFLOW_DATA="$BOOT_DATA" TEST_LOG="$LOG" \
  "$BOOT_BIN/dev-workflow" update --channel edge >/dev/null
python3 - "$BOOT_ROOT/install.json" "$EDGE_COMMIT" <<'PY'
import json
import sys
state = json.load(open(sys.argv[1], encoding="utf-8"))
assert state["channel"] == "edge" and state["active_commit"] == sys.argv[2], state
PY
HOME="$BOOT_HOME" DEV_WORKFLOW_REPO_URL="$REMOTE" DEV_WORKFLOW_INSTALL_ROOT="$BOOT_ROOT" \
  DEV_WORKFLOW_BIN_DIR="$BOOT_BIN" DEV_WORKFLOW_DATA="$BOOT_DATA" TEST_LOG="$LOG" \
  "$BOOT_BIN/dev-workflow" update --channel stable >/dev/null

EDGE_HOME="$TMP/edge-home"
EDGE_ROOT="$TMP/edge-managed"
EDGE_BIN="$TMP/edge-bin"
HOME="$EDGE_HOME" DEV_WORKFLOW_REPO_URL="$REMOTE" DEV_WORKFLOW_INSTALL_ROOT="$EDGE_ROOT" \
  DEV_WORKFLOW_BIN_DIR="$EDGE_BIN" DEV_WORKFLOW_DATA="$EDGE_HOME/.dev-workflow" TEST_LOG="$LOG" \
  bash "$ROOT/install.sh" --all --channel edge >/dev/null
python3 - "$EDGE_ROOT/install.json" "$EDGE_COMMIT" <<'PY'
import json
import sys
state = json.load(open(sys.argv[1], encoding="utf-8"))
assert state["channel"] == "edge", state
assert state["platforms"] == ["codex", "cursor"], state
assert state["active_commit"] == sys.argv[2], state
PY

FAIL_ROOT="$TMP/failed-first-managed"
FAIL_BIN="$TMP/failed-first-bin"
if HOME="$TMP/failed-first-home" DEV_WORKFLOW_REPO_URL="$REMOTE" \
  DEV_WORKFLOW_INSTALL_ROOT="$FAIL_ROOT" DEV_WORKFLOW_BIN_DIR="$FAIL_BIN" TEST_LOG="$LOG" \
  FAIL_CURSOR=1 bash "$ROOT/install.sh" --cursor --channel edge >"$TMP/failed-first.out" 2>&1; then
  fail "failed first install should return non-zero"
fi
[ ! -e "$FAIL_ROOT/current" ] && [ ! -L "$FAIL_ROOT/current" ] || fail "failed first install left current"
[ ! -e "$FAIL_ROOT/install.json" ] || fail "failed first install left state"
[ ! -e "$FAIL_BIN/dev-workflow" ] && [ ! -L "$FAIL_BIN/dev-workflow" ] || fail "failed first install left command"

NO_TAG_REMOTE="$TMP/no-tag.git"
git clone -q --bare "$REMOTE" "$NO_TAG_REMOTE"
git --git-dir "$NO_TAG_REMOTE" update-ref -d refs/tags/v0.7.0
if HOME="$TMP/no-tag-home" DEV_WORKFLOW_REPO_URL="$NO_TAG_REMOTE" \
  DEV_WORKFLOW_INSTALL_ROOT="$TMP/no-tag-managed" DEV_WORKFLOW_BIN_DIR="$TMP/no-tag-bin" \
  bash "$ROOT/install.sh" --codex >"$TMP/no-tag.out" 2>&1; then
  fail "stable bootstrap without a release tag should fail"
fi
assert_contains "$(cat "$TMP/no-tag.out")" "No stable release tag"

MISMATCH_REMOTE="$TMP/mismatch.git"
git clone -q --bare "$REMOTE" "$MISMATCH_REMOTE"
git --git-dir "$MISMATCH_REMOTE" tag v0.9.0 "$STABLE_COMMIT"
if HOME="$TMP/mismatch-home" DEV_WORKFLOW_REPO_URL="$MISMATCH_REMOTE" \
  DEV_WORKFLOW_INSTALL_ROOT="$TMP/mismatch-managed" DEV_WORKFLOW_BIN_DIR="$TMP/mismatch-bin" \
  TEST_LOG="$LOG" bash "$ROOT/install.sh" --codex >"$TMP/mismatch.out" 2>&1; then
  fail "stable bootstrap with a tag/version mismatch should fail"
fi
assert_contains "$(cat "$TMP/mismatch.out")" "does not match manifest version"

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
