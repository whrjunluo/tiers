#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER="$HERE/scripts/external-agent.sh"
SBOX="$(mktemp -d)"
trap 'rm -rf "$SBOX"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

[ -x "$RUNNER" ] || fail "external-agent runner missing or not executable"

mkdir -p "$SBOX/bin" "$SBOX/repo"
cat > "$SBOX/bin/agy" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$AGY_ARGS"
pwd > "$AGY_PWD"
echo "agy response"
exit "${AGY_EXIT:-0}"
SH
chmod +x "$SBOX/bin/agy"

cat > "$SBOX/bin/cursor-agent" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CURSOR_ARGS"
pwd > "$CURSOR_PWD"
echo "cursor response"
exit "${CURSOR_EXIT:-0}"
SH
chmod +x "$SBOX/bin/cursor-agent"

cat > "$SBOX/bin/grok" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$GROK_ARGS"
pwd > "$GROK_PWD"
echo "grok response"
exit "${GROK_EXIT:-0}"
SH
chmod +x "$SBOX/bin/grok"

export AGY_ARGS="$SBOX/args"
export AGY_PWD="$SBOX/pwd"
export CURSOR_ARGS="$SBOX/cursor-args"
export CURSOR_PWD="$SBOX/cursor-pwd"
export GROK_ARGS="$SBOX/grok-args"
export GROK_PWD="$SBOX/grok-pwd"

out="$(printf 'review this change\n' | PATH="$SBOX/bin:$PATH" "$RUNNER" --repo "$SBOX/repo" --model gemini-test)"
[ "$out" = "agy response" ] || fail "agy stdout was not forwarded"
[ "$(cat "$AGY_PWD")" = "$SBOX/repo" ] || fail "runner did not use requested repo"
cat > "$SBOX/expected-args" <<'EOF'
--sandbox
--print
review this change
--model
gemini-test
EOF
cmp -s "$SBOX/expected-args" "$AGY_ARGS" || fail "agy arguments were incorrect"

out="$(printf 'review with cursor\n' | PATH="$SBOX/bin:$PATH" "$RUNNER" --agent cursor --repo "$SBOX/repo" --model gpt-test)"
[ "$out" = "cursor response" ] || fail "cursor stdout was not forwarded"
[ "$(cat "$CURSOR_PWD")" = "$SBOX/repo" ] || fail "cursor runner did not use requested repo"
cat > "$SBOX/expected-cursor-args" <<EOF
--print
--mode
ask
--sandbox
enabled
--trust
--workspace
$SBOX/repo
--model
gpt-test
review with cursor
EOF
cmp -s "$SBOX/expected-cursor-args" "$CURSOR_ARGS" || fail "cursor arguments were incorrect"

out="$(printf 'review with grok\n' | PATH="$SBOX/bin:$PATH" "$RUNNER" --agent grok --repo "$SBOX/repo" --model grok-test)"
[ "$out" = "grok response" ] || fail "grok stdout was not forwarded"
[ "$(cat "$GROK_PWD")" = "$SBOX/repo" ] || fail "grok runner did not use requested repo"
cat > "$SBOX/expected-grok-args" <<EOF
--cwd
$SBOX/repo
--permission-mode
plan
--sandbox
workspace
--disable-web-search
--no-subagents
--no-memory
--model
grok-test
--single
review with grok
EOF
cmp -s "$SBOX/expected-grok-args" "$GROK_ARGS" || fail "grok arguments were incorrect"

if printf 'hi\n' | PATH="$SBOX/bin:$PATH" "$RUNNER" --agent unknown >"$SBOX/out" 2>"$SBOX/err"; then
  fail "unknown agent should fail"
fi
grep -q 'unknown agent' "$SBOX/err" || fail "unknown agent error missing"

if printf '\n' | PATH="$SBOX/bin:$PATH" "$RUNNER" >"$SBOX/out" 2>"$SBOX/err"; then
  fail "empty prompt should fail"
fi
grep -q 'prompt must not be empty' "$SBOX/err" || fail "empty prompt error missing"

if printf 'hi\n' | PATH="$SBOX/bin:$PATH" "$RUNNER" --repo "$SBOX/missing" >"$SBOX/out" 2>"$SBOX/err"; then
  fail "missing repo should fail"
fi
grep -q 'directory does not exist' "$SBOX/err" || fail "missing repo error missing"

if printf 'hi\n' | PATH="/usr/bin:/bin" "$RUNNER" >"$SBOX/out" 2>"$SBOX/err"; then
  fail "missing agy should fail"
fi
grep -q 'curl -fsSL https://antigravity.google/cli/install.sh | bash' "$SBOX/err" || fail "install hint missing"

if printf 'hi\n' | PATH="/usr/bin:/bin" "$RUNNER" --agent cursor >"$SBOX/out" 2>"$SBOX/err"; then
  fail "missing cursor-agent should fail"
fi
grep -q 'cursor-agent not found on PATH' "$SBOX/err" || fail "cursor install hint missing"

if printf 'hi\n' | PATH="/usr/bin:/bin" "$RUNNER" --agent grok >"$SBOX/out" 2>"$SBOX/err"; then
  fail "missing grok should fail"
fi
grep -q 'grok not found on PATH' "$SBOX/err" || fail "grok install hint missing"

if AGY_EXIT=23 printf 'hi\n' | AGY_EXIT=23 PATH="$SBOX/bin:$PATH" "$RUNNER" >"$SBOX/out" 2>"$SBOX/err"; then
  fail "agy failure should be propagated"
else
  status=$?
  [ "$status" -eq 23 ] || fail "expected agy exit 23, got $status"
fi

SKILL="$HERE/skills/external-agent/SKILL.md"
[ -f "$SKILL" ] || fail "external-agent skill missing"
grep -q '^name: external-agent$' "$SKILL" || fail "external-agent skill name missing"
grep -q 'scripts/external-agent.sh' "$SKILL" || fail "runner usage missing from skill"
grep -q 'independent external agents' "$SKILL" || fail "independent agent wording missing from skill"
grep -q 'cursor-agent' "$SKILL" || fail "cursor-agent missing from skill"
grep -q 'grok' "$SKILL" || fail "grok missing from skill"
grep -q 'external-agent' "$HERE/skills/dev-workflow/SKILL.md" || fail "dev-workflow routing missing"

echo "PASS tests/external-agent.sh"
