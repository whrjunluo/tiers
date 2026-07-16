# Small-Fix Fast Path Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use test-driven-development. Execute inline; do not start a long external review loop.

**Goal:** Add a bounded small-fix workflow path with parallel review, one-success degradation, and L3→L1 evidence reuse.

**Architecture:** Extend the existing standard-library Python runner and dependency-free Bash controller. Keep `standard` behavior compatible; make every relaxation explicit through `small-fix` metadata and content-addressed evidence.

**Tech Stack:** Python standard library, Bash/awk, Markdown.

## Global Constraints

- Do not modify `gst-ai-doctor-console`.
- Keep root-cause, TDD, and real business verification gates truthful.
- Small-fix review defaults to 90 seconds and never silently claims strict quorum.
- Preserve the pre-existing doctor/patient tier-boundary edit in `skills/dev-workflow/SKILL.md` without treating it as newly authored work.

---

### Task 1: Parallel bounded cross-review

**Files:**
- Modify: `tests/external-agent.sh`
- Modify: `scripts/external_agent.py`

**Interfaces:**
- Produces: `--review-profile standard|small-fix`; JSON `outcome`, `policy`, reviewer `status` and durations.

- [ ] Add a failing timing test using two one-second stub reviewers; assert standard cross-review completes below 1.8 seconds.
- [ ] Add a failing small-fix test with one immediate success and one slow reviewer; assert exit 0, `quorum=false`, `outcome=degraded`, timeout 90, and a cancelled reviewer.
- [ ] Run `bash tests/external-agent.sh`; verify failures identify sequential orchestration and the missing profile.
- [ ] Implement parallel workers, interruptible child capture, short-circuit cancellation, and structured failed/terminated evidence.
- [ ] Re-run `bash tests/external-agent.sh`; expect `PASS tests/external-agent.sh`.

### Task 2: Controller profile and understanding reuse

**Files:**
- Modify: `tests/workflow-state.sh`
- Modify: `templates/workflow-state.yaml`
- Modify: `scripts/workflow-state.sh`

**Interfaces:**
- Produces: `execution.profile`; controller-owned `understanding.objective_sha256` and reused evidence metadata.

- [ ] Add a failing test that passes L3 root-cause, changes only level/sources to L1, then accepts an L1 evidence file containing `reuses:` and rejects tampered or different-target reuse.
- [ ] Add a failing completion test: standard rejects one-success degraded JSON; small-fix accepts it only with valid fingerprint/family/status metadata.
- [ ] Run `bash tests/workflow-state.sh`; verify failures are due to missing fields/validation.
- [ ] Extend schema migration, `understand`, `check`, and external-review validation without weakening standard quorum.
- [ ] Re-run `bash tests/workflow-state.sh`; expect `PASS tests/workflow-state.sh`.

### Task 3: Workflow policy and focused verification

**Files:**
- Modify: `skills/dev-workflow/SKILL.md`
- Modify: `skills/external-agent/SKILL.md`
- Modify: `README.md`

- [ ] Document eligibility, proportional verification, checkpoint commits, parallel business/review work, update throttling, and stop behavior.
- [ ] Document the exact degraded/failed/terminated evidence contract and migration defaults.
- [ ] Run `python3 -m py_compile scripts/external_agent.py`, `bash -n scripts/workflow-state.sh tests/external-agent.sh tests/workflow-state.sh`, both focused suites, and `git diff --check`.
- [ ] Review the final diff with the built-in adversarial checklist; do not invoke a long external cross-review.
- [ ] Create one focused commit while leaving unrelated pre-existing work unstaged where technically possible.
