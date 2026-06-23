#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER="$HERE/scripts/external_agent.py"
SBOX="$(mktemp -d)"
trap 'rm -rf "$SBOX"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }

[ -f "$RUNNER" ] || fail "external_agent.py missing"

mkdir -p "$SBOX/bin" "$SBOX/repo"
ARGS_DIR="$SBOX/args"; mkdir -p "$ARGS_DIR"

# --- stub CLIs: record args, emit minimal valid output per agent -------------
make_stub() {  # name  json-line
  local name="$1" payload="$2"
  cat > "$SBOX/bin/$name" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$ARGS_DIR/$name"
pwd > "$ARGS_DIR/$name.pwd"
printf '%s\n' '$payload'
SH
  chmod +x "$SBOX/bin/$name"
}
make_stub codex        '{"thread_id":"T1"}
{"item":{"type":"agent_message","text":"codex ok"}}
{"type":"turn.completed"}'
make_stub gemini       '{"role":"assistant","content":"gemini ok","session_id":"G1"}'
make_stub mimo         '{"sessionID":"M1","type":"text","part":{"id":"p1","text":"mimo ok"}}'
make_stub cursor-agent '{"is_error":false,"subtype":"success","result":"cursor ok","session_id":"C1"}'
make_stub grok         '{"text":"grok ok","stopReason":"EndTurn","sessionId":"K1"}'
make_stub agy          'agy ok'

run() { PATH="$SBOX/bin:$PATH" python3 "$RUNNER" "$@"; }
field() { python3 -c "import sys,json;print(json.load(sys.stdin).get('$2',''))" <<<"$1"; }

# --- each agent: json contract parsed correctly -----------------------------
for pair in "codex|codex ok|T1" "gemini|gemini ok|G1" "mimo|mimo ok|M1" \
            "cursor|cursor ok|C1" "grok|grok ok|K1"; do
  IFS='|' read -r ag msg sid <<<"$pair"
  out="$(run --agent "$ag" --cd "$SBOX/repo" --format json --PROMPT "hi")"
  [ "$(field "$out" success)" = "True" ] || fail "$ag did not succeed: $out"
  [ "$(field "$out" agent_messages)" = "$msg" ] || fail "$ag wrong message: $out"
  [ "$(field "$out" SESSION_ID)" = "$sid" ] || fail "$ag wrong SESSION_ID: $out"
done

# antigravity (raw, no session id)
out="$(run --agent antigravity --cd "$SBOX/repo" --format json --PROMPT "hi")"
[ "$(field "$out" agent_messages)" = "agy ok" ] || fail "agy wrong message: $out"

# alias agy == antigravity, cursor-agent == cursor
run --agent agy --cd "$SBOX/repo" --PROMPT hi >/dev/null || fail "agy alias failed"
run --agent cursor-agent --cd "$SBOX/repo" --PROMPT hi >/dev/null || fail "cursor-agent alias failed"

# --- mode review vs delegate changes flags ----------------------------------
run --agent codex --cd "$SBOX/repo" --PROMPT hi >/dev/null
grep -q 'read-only' "$ARGS_DIR/codex" || fail "codex review should be read-only"
run --agent codex --cd "$SBOX/repo" --mode delegate --PROMPT hi >/dev/null
grep -q 'workspace-write' "$ARGS_DIR/codex" || fail "codex delegate should be workspace-write"

run --agent grok --cd "$SBOX/repo" --PROMPT hi >/dev/null
grep -q 'plan' "$ARGS_DIR/grok" || fail "grok review should use plan"
run --agent grok --cd "$SBOX/repo" --mode delegate --PROMPT hi >/dev/null
grep -q 'bypassPermissions' "$ARGS_DIR/grok" || fail "grok delegate should bypass"

run --agent cursor --cd "$SBOX/repo" --PROMPT hi >/dev/null
grep -q 'ask' "$ARGS_DIR/cursor-agent" || fail "cursor review should be ask mode"
grep -q 'trust' "$ARGS_DIR/cursor-agent" || fail "cursor should pass --trust"
run --agent cursor --cd "$SBOX/repo" --mode delegate --PROMPT hi >/dev/null
grep -q 'force' "$ARGS_DIR/cursor-agent" || fail "cursor delegate should force"

# --- context git prepends repo context --------------------------------------
git -C "$SBOX/repo" init -q
git -C "$SBOX/repo" config user.email t@e.com
git -C "$SBOX/repo" config user.name T
printf 'one\n' > "$SBOX/repo/f.txt"; git -C "$SBOX/repo" add f.txt; git -C "$SBOX/repo" commit -q -m init
printf 'one\ntwo\n' > "$SBOX/repo/f.txt"
run --agent grok --cd "$SBOX/repo" --context git --PROMPT "review" >/dev/null
grep -q '## Repository Context' "$ARGS_DIR/grok" || fail "git context header missing"
grep -q 'review' "$ARGS_DIR/grok" || fail "user prompt missing from context"

# --- --list ------------------------------------------------------------------
out="$(run --list)"
python3 -c "import sys,json; d=json.load(sys.stdin); assert any(a['agent']=='codex' for a in d)" <<<"$out" \
  || fail "--list missing codex"

# --- error cases -------------------------------------------------------------
if run --agent bogus --cd "$SBOX/repo" --PROMPT hi >/dev/null 2>"$SBOX/err"; then fail "unknown agent should fail"; fi
if run --agent codex --cd "$SBOX/repo" --PROMPT "" </dev/null >/dev/null 2>"$SBOX/err"; then fail "empty prompt should fail"; fi
if PATH="/usr/bin:/bin" python3 "$RUNNER" --agent codex --cd "$SBOX/repo" --PROMPT hi >/dev/null 2>"$SBOX/err"; then fail "missing binary should fail"; fi
grep -q 'not found on PATH' "$SBOX/err" || fail "missing-binary hint missing"
# resume unsupported for antigravity
if run --agent antigravity --cd "$SBOX/repo" --SESSION_ID x --PROMPT hi >/dev/null 2>"$SBOX/err"; then fail "agy resume should fail"; fi

# --- skill + routing docs ----------------------------------------------------
SKILL="$HERE/skills/external-agent/SKILL.md"
[ -f "$SKILL" ] || fail "external-agent skill missing"
grep -q '^name: external-agent$' "$SKILL" || fail "skill name missing"
grep -q 'external_agent.py' "$SKILL" || fail "runner usage missing from skill"
for a in codex gemini mimo cursor grok antigravity; do
  grep -q "$a" "$SKILL" || fail "$a missing from skill"
done
grep -q 'external-agent' "$HERE/skills/dev-workflow/SKILL.md" || fail "dev-workflow routing missing"

echo "PASS tests/external-agent.sh"
