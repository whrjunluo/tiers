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

export AGY_ARGS="$SBOX/args"
export AGY_PWD="$SBOX/pwd"

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
grep -q 'external-agent' "$HERE/skills/dev-workflow/SKILL.md" || fail "dev-workflow routing missing"

echo "PASS tests/external-agent.sh"
