#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER="$HERE/scripts/external_agent.py"
SBOX="$(mktemp -d)"
trap 'rm -rf "$SBOX"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }
export DEV_WORKFLOW_DATA="$SBOX/data"

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
make_slow_stub() {  # name  delay  payload
  local name="$1" delay="$2" payload="$3"
  cat > "$SBOX/bin/$name" <<SH
#!/usr/bin/env bash
sleep "$delay"
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
make_stub opencode     '{"sessionID":"O1","type":"text","part":{"id":"p1","text":"opencode ok"}}'
make_stub agy          'agy ok'

run() { PATH="$SBOX/bin:$PATH" python3 "$RUNNER" --progress none "$@"; }
field() { python3 -c "import sys,json;print(json.load(sys.stdin).get('$2',''))" <<<"$1"; }
wait_for_event() { # file event [minimum-count]
  local file="$1" event="$2" minimum="${3:-1}"
  local count
  for _ in $(seq 1 100); do
    count="$(grep -c '\"event\": \"'"$event"'\"' "$file" 2>/dev/null || true)"
    [ "$count" -ge "$minimum" ] && return 0
    sleep 0.02
  done
  return 1
}

# --- each agent: json contract parsed correctly -----------------------------
for pair in "codex|codex ok|T1" "gemini|gemini ok|G1" "mimo|mimo ok|M1" \
            "cursor|cursor ok|C1" "grok|grok ok|K1" "opencode|opencode ok|O1"; do
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
git -C "$SBOX/repo" add f.txt
run --agent mimo --cd "$SBOX/repo" --context git --PROMPT "review staged" >/dev/null
grep -q 'git diff --cached' "$ARGS_DIR/mimo" || fail "staged diff context missing"
grep -q '+two' "$ARGS_DIR/mimo" || fail "staged change content missing"

# --- --list ------------------------------------------------------------------
out="$(run --list)"
python3 -c "import sys,json; d=json.load(sys.stdin); assert any(a['agent']=='codex' for a in d)" <<<"$out" \
  || fail "--list missing codex"
python3 -c "import sys,json; d=json.load(sys.stdin); assert all(a.get('family') for a in d)" <<<"$out" \
  || fail "--list missing provider family"
python3 -c "import sys,json; d=json.load(sys.stdin); assert all(a.get('health_status') for a in d); assert all(a.get('recommended_timeout_seconds') for a in d)" <<<"$out" \
  || fail "--list missing persistent health metadata"
python3 -c "import sys,json; d=json.load(sys.stdin); assert all(a.get('routing_priority') for a in d)" <<<"$out" \
  || fail "--list missing machine-readable routing priority"

# --- cross-review quorum ------------------------------------------------------
out="$(run --cross-review mimo,grok --cd "$SBOX/repo" --context git --format json --PROMPT "same artifact")"
python3 -c 'import sys,json; d=json.load(sys.stdin); assert d["success"] and d["quorum"]; assert len(d["artifact_sha256"]) == 64; assert len(d["reviewers"]) == 2; assert len(d["successful_families"]) == 2' <<<"$out" \
  || fail "valid cross-review quorum failed: $out"
python3 -c 'import sys,json; d=json.load(sys.stdin); assert d["outcome"] == "quorum"; assert d["review_profile"] == "standard"; assert d["finished_at"].endswith("Z"); assert d["duration_seconds"] >= 0; assert all(r["status"] == "success" and r["duration_seconds"] >= 0 for r in d["reviewers"])' <<<"$out" \
  || fail "cross-review lifecycle evidence missing: $out"
python3 -c 'import sys,json; d=json.load(sys.stdin); assert d["runner"] == "tiers.external-agent/v1"' <<<"$out" \
  || fail "cross-review report must declare runner provenance"
python3 -c 'import sys,json; d=json.load(sys.stdin); assert len(d["repository_fingerprint"]) == 64; assert d["created_at"].endswith("Z")' <<<"$out" \
  || fail "cross-review repository binding missing: $out"
fingerprint="$(run --fingerprint --cd "$SBOX/repo")"
[ "$(field "$out" repository_fingerprint)" = "$fingerprint" ] || fail "report fingerprint should match current repository"
printf 'first\n' > "$SBOX/repo/untracked.txt"
untracked_one="$(run --fingerprint --cd "$SBOX/repo")"
printf 'second\n' > "$SBOX/repo/untracked.txt"
untracked_two="$(run --fingerprint --cd "$SBOX/repo")"
[ "$untracked_one" != "$untracked_two" ] || fail "fingerprint must bind untracked file content"
rm "$SBOX/repo/untracked.txt"
grep -q 'same artifact' "$ARGS_DIR/mimo" || fail "mimo did not receive shared artifact"
grep -q 'same artifact' "$ARGS_DIR/grok" || fail "grok did not receive shared artifact"
grep -q 'git diff --cached' "$ARGS_DIR/mimo" || fail "mimo cross-review missing staged context"
grep -q 'git diff --cached' "$ARGS_DIR/grok" || fail "grok cross-review missing staged context"

# Standard cross-review starts reviewers in parallel; wall time is bounded by
# the slowest provider rather than the sum of provider durations.
make_slow_stub mimo 1 '{"sessionID":"M2","type":"text","part":{"id":"p1","text":"mimo parallel"}}'
make_slow_stub grok 1 '{"text":"grok parallel","stopReason":"EndTurn","sessionId":"K2"}'
parallel_started="$(python3 -c 'import time; print(time.monotonic())')"
out="$(run --cross-review mimo,grok --cd "$SBOX/repo" --format json --PROMPT parallel)"
parallel_elapsed="$(python3 -c 'import sys,time; print(time.monotonic()-float(sys.argv[1]))' "$parallel_started")"
python3 -c 'import sys; assert float(sys.argv[1]) < 1.8, sys.argv[1]' "$parallel_elapsed" \
  || fail "cross-review should run in parallel, elapsed=${parallel_elapsed}s"

# Lifecycle progress must be observable before slow reviewers finish, while
# final JSON remains isolated on stdout for evidence consumers.
make_slow_stub mimo 2 '{"sessionID":"M-progress","type":"text","part":{"id":"p1","text":"mimo progress"}}'
make_slow_stub grok 2 '{"text":"grok progress","stopReason":"EndTurn","sessionId":"K-progress"}'
PATH="$SBOX/bin:$PATH" python3 "$RUNNER" --cross-review mimo,grok \
  --progress jsonl --cd "$SBOX/repo" --format json --PROMPT progress \
  >"$SBOX/progress-final.json" 2>"$SBOX/progress-events.jsonl" &
progress_pid=$!
wait_for_event "$SBOX/progress-events.jsonl" cross_review_started \
  || fail "cross-review start event was not observable"
wait_for_event "$SBOX/progress-events.jsonl" review_started 2 \
  || fail "reviewer start events were not observable"
kill -0 "$progress_pid" 2>/dev/null \
  || fail "slow cross-review finished before lifecycle events were observed"
wait "$progress_pid" || fail "progress-enabled cross-review should succeed"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["success"] and d["quorum"]' "$SBOX/progress-final.json" \
  || fail "progress output corrupted final JSON"
python3 -c 'import json,sys; rows=[json.loads(line) for line in open(sys.argv[1]) if line.strip()]; assert rows; assert [r["sequence"] for r in rows] == list(range(1, len(rows)+1)); assert rows[0]["event"] == "cross_review_started"; assert rows[-1]["event"] == "cross_review_finished"' "$SBOX/progress-events.jsonl" \
  || fail "progress lifecycle contract failed"

# Small-fix review uses a 90-second implicit budget and stops after the first
# valid external opinion, preserving strict quorum=false in degraded evidence.
make_stub mimo '{"sessionID":"M3","type":"text","part":{"id":"p1","text":"mimo first"}}'
make_slow_stub grok 3 '{"text":"grok late","stopReason":"EndTurn","sessionId":"K3"}'
small_started="$(python3 -c 'import time; print(time.monotonic())')"
out="$(run --cross-review mimo,grok --review-profile small-fix --cd "$SBOX/repo" --format json --PROMPT narrow)"
small_elapsed="$(python3 -c 'import sys,time; print(time.monotonic()-float(sys.argv[1]))' "$small_started")"
python3 -c 'import sys; assert float(sys.argv[1]) < 1.5, sys.argv[1]' "$small_elapsed" \
  || fail "small-fix should stop after first success, elapsed=${small_elapsed}s"
python3 -c 'import sys,json; d=json.load(sys.stdin); assert d["success"] and not d["quorum"]; assert d["outcome"] == "degraded"; assert d["review_profile"] == "small-fix"; assert d["policy"] == {"minimum_successes": 1, "minimum_families": 1, "stop_after_policy": True}; assert all(r["timeout_seconds"] == 90 for r in d["reviewers"]); assert any(r["status"] == "cancelled" for r in d["reviewers"])' <<<"$out" \
  || fail "small-fix degraded evidence contract failed: $out"

# SIGINT must leave machine-readable termination evidence instead of an empty
# or half-written review artifact.
make_slow_stub mimo 5 '{"sessionID":"M4","type":"text","part":{"id":"p1","text":"mimo late"}}'
make_slow_stub grok 5 '{"text":"grok late","stopReason":"EndTurn","sessionId":"K4"}'
PATH="$SBOX/bin:$PATH" python3 "$RUNNER" --cross-review mimo,grok --cd "$SBOX/repo" \
  --progress jsonl --format json --PROMPT interrupted \
  >"$SBOX/interrupted.json" 2>"$SBOX/interrupted-events.jsonl" &
interrupt_pid=$!
wait_for_event "$SBOX/interrupted-events.jsonl" cross_review_started \
  || fail "interrupt test never observed cross-review start"
kill -INT "$interrupt_pid"
if wait "$interrupt_pid"; then fail "interrupted cross-review should exit non-zero"; fi
python3 -c 'import sys,json; d=json.load(open(sys.argv[1])); assert not d["success"] and not d["quorum"]; assert d["outcome"] == "terminated"; assert d["termination_reason"] == "user_interrupt"; assert d["finished_at"].endswith("Z")' "$SBOX/interrupted.json" \
  || fail "interrupted review should preserve structured evidence"
wait_for_event "$SBOX/interrupted-events.jsonl" cross_review_terminated \
  || fail "interrupted review should emit termination progress"

make_stub mimo '{"sessionID":"M1","type":"text","part":{"id":"p1","text":"mimo ok"}}'
make_stub grok '{"text":"grok ok","stopReason":"EndTurn","sessionId":"K1"}'

if out="$(run --cross-review mimo,grok --cd "$SBOX/missing-repo" --format json --PROMPT review 2>/dev/null)"; then
  fail "worker infrastructure errors should fail cross-review"
fi
python3 -c 'import sys,json; d=json.load(sys.stdin); assert d["outcome"] == "failed"; assert len(d["reviewers"]) == 2; assert all(r["status"] == "failed" for r in d["reviewers"])' <<<"$out" \
  || fail "worker infrastructure errors should preserve structured evidence: $out"

if out="$(run --cross-review agy,antigravity --cd "$SBOX/repo" --format json --PROMPT review 2>/dev/null)"; then
  fail "duplicate/same-family reviewers should not form quorum"
fi
python3 -c 'import sys,json; d=json.load(sys.stdin); assert not d["success"] and not d["quorum"]' <<<"$out" \
  || fail "same-family failure should return structured JSON: $out"

make_stub grok '{"text":"","stopReason":"EndTurn","sessionId":"K2"}'
if out="$(run --cross-review mimo,grok --cd "$SBOX/repo" --format json --PROMPT review 2>/dev/null)"; then
  fail "partial provider failure should not form quorum"
fi
python3 -c 'import sys,json; d=json.load(sys.stdin); assert not d["success"] and not d["quorum"]; assert any(not r["success"] for r in d["reviewers"])' <<<"$out" \
  || fail "partial failure should return reviewer evidence: $out"
out="$(run --list)"
python3 -c 'import sys,json; row=next(r for r in json.load(sys.stdin) if r["agent"] == "grok"); assert row["routing_priority"] == "deprioritized"' <<<"$out" \
  || fail "a provider with a current failure streak should be deprioritized"

make_slow_stub agy 2 'agy late'
if out="$(run --cross-review agy,mimo --timeout 1 --cd "$SBOX/repo" --format json --PROMPT review 2>/dev/null)"; then
  fail "timed-out provider should not form quorum"
fi
python3 -c 'import sys,json; d=json.load(sys.stdin); assert not d["quorum"]; assert any("timed out" in r.get("error", "") for r in d["reviewers"])' <<<"$out" \
  || fail "timeout should be preserved in reviewer evidence: $out"

HEALTH="$DEV_WORKFLOW_DATA/external-agent-health.json"
[ -s "$HEALTH" ] || fail "provider timeout should create persistent health state"
python3 -c 'import sys,json; d=json.load(open(sys.argv[1])); h=d["agents"]["antigravity"]; assert h["status"] == "slow"; assert h["timeout_count"] == 1; assert h["consecutive_timeouts"] == 1; assert h["recommended_timeout_seconds"] >= 2' "$HEALTH" \
  || fail "first timeout should persist a slow marker"
out="$(run --list)"
python3 -c 'import sys,json; row=next(r for r in json.load(sys.stdin) if r["agent"] == "antigravity"); assert row["health_status"] == "slow"; assert row["recommended_timeout_seconds"] >= 2; assert row["routing_priority"] == "deprioritized"' <<<"$out" \
  || fail "--list should expose the persisted slow marker and lower routing priority"

if run --agent agy --timeout 1 --cd "$SBOX/repo" --PROMPT review >/dev/null 2>&1; then
  fail "second timed-out provider call should fail"
fi
python3 -c 'import sys,json; h=json.load(open(sys.argv[1]))["agents"]["antigravity"]; assert h["status"] == "degraded"; assert h["timeout_count"] == 2; assert h["consecutive_timeouts"] == 2' "$HEALTH" \
  || fail "consecutive timeouts should promote the long-term marker to degraded"

make_stub agy 'agy recovered'
run --agent agy --timeout 2 --cd "$SBOX/repo" --PROMPT review >/dev/null
python3 -c 'import sys,json; h=json.load(open(sys.argv[1]))["agents"]["antigravity"]; assert h["status"] == "slow"; assert h["consecutive_timeouts"] == 0; assert h["success_count"] >= 1' "$HEALTH" \
  || fail "a successful retry should clear the failure streak but retain slow history"

# Concurrent provider completions must not overwrite each other's health events.
CONCURRENT_DATA="$SBOX/concurrent-health"
mkdir -p "$CONCURRENT_DATA"
pids=""
for _worker in 1 2 3 4 5 6; do
  DEV_WORKFLOW_DATA="$CONCURRENT_DATA" python3 - "$RUNNER" <<'PY' &
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("external_agent", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
for _ in range(100):
    module._record_health("codex", "timeout", 10, 0.1, "concurrent timeout")
PY
  pids="$pids $!"
done
for pid in $pids; do wait "$pid"; done
CONCURRENT_HEALTH="$CONCURRENT_DATA/external-agent-health.json"
python3 -c 'import json,sys; h=json.load(open(sys.argv[1]))["agents"]["codex"]; assert h["timeout_count"] == 600, h' "$CONCURRENT_HEALTH" \
  || fail "concurrent health writes should preserve every provider event"

# A stored provider recommendation is the default; an explicit timeout remains authoritative.
python3 - "$HEALTH" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path))
data["agents"]["antigravity"]["recommended_timeout_seconds"] = 1
with open(path, "w") as handle:
    json.dump(data, handle)
PY
make_slow_stub agy 2 'agy recommended-timeout'
if run --agent agy --cd "$SBOX/repo" --PROMPT review >/dev/null 2>"$SBOX/err"; then
  fail "stored provider timeout should apply when --timeout is omitted"
fi
grep -q 'timed out after 1s' "$SBOX/err" || fail "default call should report the stored provider timeout"
run --agent agy --timeout 3 --cd "$SBOX/repo" --PROMPT review >/dev/null \
  || fail "explicit --timeout should override the stored recommendation"

# --- error cases -------------------------------------------------------------
if run --agent bogus --cd "$SBOX/repo" --PROMPT hi >/dev/null 2>"$SBOX/err"; then fail "unknown agent should fail"; fi
if run --agent codex --cd "$SBOX/repo" --PROMPT "" </dev/null >/dev/null 2>"$SBOX/err"; then fail "empty prompt should fail"; fi
if PATH="/usr/bin:/bin" python3 "$RUNNER" --agent codex --cd "$SBOX/repo" --PROMPT hi >/dev/null 2>"$SBOX/err"; then fail "missing binary should fail"; fi
grep -q 'not found on PATH' "$SBOX/err" || fail "missing-binary hint missing"
# resume unsupported for antigravity
if run --agent antigravity --cd "$SBOX/repo" --SESSION_ID x --PROMPT hi >/dev/null 2>"$SBOX/err"; then fail "agy resume should fail"; fi
if run --cross-review mimo,grok --mode delegate --cd "$SBOX/repo" --PROMPT hi >/dev/null 2>"$SBOX/err"; then fail "cross-review delegate mode should fail"; fi

# --- skill + routing docs ----------------------------------------------------
SKILL="$HERE/skills/external-agent/SKILL.md"
[ -f "$SKILL" ] || fail "external-agent skill missing"
grep -q '^name: external-agent$' "$SKILL" || fail "skill name missing"
grep -q 'external_agent.py' "$SKILL" || fail "runner usage missing from skill"
grep -q -- '--cross-review' "$SKILL" || fail "cross-review quorum usage missing from skill"
grep -q 'recommended_timeout_seconds' "$SKILL" || fail "persistent provider timeout policy missing from skill"
grep -q 'degraded' "$SKILL" || fail "provider health escalation policy missing from skill"
grep -q 'routing_priority' "$SKILL" || fail "health-aware routing priority missing from skill"
grep -q -- '--review-profile small-fix' "$SKILL" || fail "small-fix review profile missing from skill"
grep -q '并行\|parallel' "$SKILL" || fail "parallel cross-review policy missing from skill"
grep -q 'terminated' "$SKILL" || fail "terminated evidence contract missing from skill"
for a in codex gemini mimo cursor grok opencode antigravity; do
  grep -q "$a" "$SKILL" || fail "$a missing from skill"
done
grep -q 'external-agent' "$HERE/skills/dev-workflow/SKILL.md" || fail "dev-workflow routing missing"

echo "PASS tests/external-agent.sh"
