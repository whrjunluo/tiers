# External Review Feedback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add real-time cross-review lifecycle feedback, bounded implicit timeouts, and deterministic automatic reviewer selection without changing final evidence semantics.

**Architecture:** Keep `scripts/external_agent.py` as the single process orchestrator. Add a thread-safe stderr JSONL event emitter, separate provider health recommendations from the standard 600-second hard budget, and resolve `--cross-review auto` before launching the existing thread pool. The final aggregate report remains the completion-gate artifact.

**Tech Stack:** Python 3 standard library, Bash black-box tests, JSON/JSONL.

## Global Constraints

- Standard quorum remains two successful distinct families.
- Small-fix remains 90 seconds and may complete degraded after one success.
- Explicit `--timeout` overrides implicit caps.
- Final stdout and exit-code contracts remain backward compatible.
- No persistent daemon, UI overlay, or workflow-state schema migration.

---

### Task 1: Lifecycle progress events and deterministic interruption

**Files:**
- Modify: `tests/external-agent.sh:109-175`
- Modify: `scripts/external_agent.py:500-755`

**Interfaces:**
- Produces: `ProgressEmitter.emit(event: str, **fields)` writing one JSON object per line to stderr.
- Produces: CLI `--progress jsonl|none`, defaulting to `jsonl` for cross-review.

- [ ] **Step 1: Write failing black-box tests**

Add a helper that waits until a file contains an event rather than sleeping a fixed duration:

```bash
wait_for_event() {
  local file="$1" event="$2"
  for _ in $(seq 1 100); do
    grep -q '"event": "'"$event"'"' "$file" 2>/dev/null && return 0
    sleep 0.02
  done
  return 1
}
```

Start a slow cross-review in the background, redirect stderr to `progress.jsonl`, assert `cross_review_started` and both `review_started` events appear while the PID is still alive, then wait for final JSON and validate it. Update the SIGINT test to wait for `cross_review_started` before `kill -INT`.

- [ ] **Step 2: Verify RED**

Run: `bash tests/external-agent.sh`

Expected: FAIL because `--progress` and lifecycle JSONL events do not exist.

- [ ] **Step 3: Implement the minimal emitter**

Add:

```python
EVENT_RUNNER_ID = "tiers.external-agent-events/v1"

class ProgressEmitter:
    def __init__(self, enabled: bool, review_profile: str): ...
    def emit(self, event: str, **fields) -> None: ...
```

Use a `threading.Lock`, monotonic sequence number, UTC timestamp, `json.dumps`, newline, and stderr flush. Emit start/finish events from the worker and aggregate paths. Keep final JSON on stdout only.

- [ ] **Step 4: Verify GREEN**

Run: `bash tests/external-agent.sh`

Expected: PASS, including the former SIGINT race.

- [ ] **Step 5: Commit**

```bash
git add scripts/external_agent.py tests/external-agent.sh
git commit -m "feat(review): stream cross-review lifecycle events"
```

### Task 2: Bound implicit standard timeouts

**Files:**
- Modify: `tests/external-agent.sh:192-260`
- Modify: `scripts/external_agent.py:203-360`

**Interfaces:**
- Produces: `STANDARD_TIMEOUT_CAP_SECONDS = 600`.
- Produces: `_effective_timeout_details(agent, explicit_timeout, review_profile) -> (seconds, source)`.

- [ ] **Step 1: Write failing timeout tests**

Seed an agent health entry with `recommended_timeout_seconds: 2400`. Run standard cross-review and assert both the final reviewer evidence and `review_started` event use `timeout_seconds: 600` and `timeout_source: provider_capped`. Add an explicit `--timeout 700` assertion showing `timeout_source: explicit` and 700 seconds.

- [ ] **Step 2: Verify RED**

Run: `bash tests/external-agent.sh`

Expected: FAIL because standard currently inherits 2400 seconds and has no timeout source.

- [ ] **Step 3: Implement bounded timeout resolution**

Resolve in this order:

```python
if explicit_timeout is not None: return explicit_timeout, "explicit"
if review_profile == "small-fix": return 90, "profile"
if positive recommendation exists:
    return min(recommendation, 600), (
        "provider" if recommendation <= 600 else "provider_capped"
    )
return 600, "default"
```

Keep `_effective_timeout()` as a compatibility wrapper if useful. Include `timeout_source` in reviewer evidence and start events.

- [ ] **Step 4: Verify GREEN**

Run: `bash tests/external-agent.sh`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/external_agent.py tests/external-agent.sh
git commit -m "fix(review): cap implicit provider wait budgets"
```

### Task 3: Automatic health-aware reviewer selection

**Files:**
- Modify: `tests/external-agent.sh:98-190`
- Modify: `scripts/external_agent.py:340-760`

**Interfaces:**
- Produces: `_select_auto_reviewers(review_profile, orchestrator_family) -> list[str]`.
- Produces: CLI `--cross-review auto` and `--orchestrator-family`.
- Produces: final `selection` object containing mode, orchestrator family, and selected reviewers.

- [ ] **Step 1: Write failing selection tests**

Create health data where Grok is degraded, Cursor is slow, Mimo is healthy, and Antigravity is healthy. Run:

```bash
run --cross-review auto --orchestrator-family openai \
  --review-profile small-fix --cd "$SBOX/repo" --format json --PROMPT auto
```

Assert the selected agents are installed, exclude family `openai`, use two distinct families, prefer healthy candidates over degraded Grok, and remain stable across two invocations. Add a failure fixture with only one installed family and assert structured failed evidence.

- [ ] **Step 2: Verify RED**

Run: `bash tests/external-agent.sh`

Expected: FAIL because `auto` is treated as an unknown agent.

- [ ] **Step 3: Implement deterministic selection**

Build candidate metadata from `AGENTS`, `shutil.which`, `_health_metadata`, bounded timeout details, and optional family exclusion. Sort by routing priority, health rank, timeout, last duration, and name. Select the best candidate, then the best candidate with a different family. Explicit comma-separated lists retain current validation.

- [ ] **Step 4: Verify GREEN**

Run: `bash tests/external-agent.sh`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/external_agent.py tests/external-agent.sh
git commit -m "feat(review): add health-aware automatic routing"
```

### Task 4: Workflow guidance and regression verification

**Files:**
- Modify: `skills/external-agent/SKILL.md`
- Modify: `skills/dev-workflow/SKILL.md`
- Modify: `README.md`
- Test: `tests/external-agent.sh`
- Test: `tests/workflow-state.sh`

**Interfaces:**
- Documents the progress stream, bounded implicit budgets, and Codex auto-routing example.

- [ ] **Step 1: Add failing documentation assertions**

Assert the external-agent skill mentions `--progress jsonl`, `--cross-review auto`, `--orchestrator-family openai`, lifecycle event names, and the 600-second implicit standard cap.

- [ ] **Step 2: Verify RED**

Run: `bash tests/external-agent.sh`

Expected: FAIL on the new documentation assertions.

- [ ] **Step 3: Update documentation**

Document a Codex example:

```bash
python3 <plugin-root>/scripts/external_agent.py \
  --cross-review auto --orchestrator-family openai \
  --review-profile small-fix --progress jsonl \
  --cd "$PWD" --context git --format json --PROMPT "..."
```

Clarify that stderr progress is user feedback, stdout final JSON is evidence, standard implicit waits are capped at 600 seconds, and explicit timeout can exceed the cap.

- [ ] **Step 4: Run focused and full verification**

Run:

```bash
python3 -m py_compile scripts/external_agent.py
bash -n tests/external-agent.sh
bash tests/external-agent.sh
bash tests/workflow-state.sh
bash tests/all.sh
git diff --check
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add README.md skills/dev-workflow/SKILL.md skills/external-agent/SKILL.md tests/external-agent.sh
git commit -m "docs(review): explain responsive bounded cross-review"
```
