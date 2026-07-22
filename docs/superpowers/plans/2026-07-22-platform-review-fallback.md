# Platform Multi-Model Review Fallback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a validated two-model platform-agent review satisfy the workflow completion gate after a genuine external cross-review failure.

**Architecture:** Add a standalone Python contract validator for `tiers.platform-review/v1`, keeping the existing external-agent report validator unchanged. `workflow-state.sh` dispatches by `runner` within the existing `evidence.external_review` field, while dev-workflow guidance owns platform-agent orchestration and preserves honest provider labels.

**Tech Stack:** Python 3 standard library, Bash controller/tests, JSON evidence, Git fingerprinting.

## Global Constraints

- External CLI cross-review remains the first provider.
- Platform fallback requires a referenced `tiers.external-agent/v1` attempt with `success=false`, `quorum=false`, and `outcome=failed`.
- `outcome=terminated`, successful external quorum, and successful small-fix degraded evidence never trigger fallback.
- Platform fallback always requires two unique non-root agent IDs, two distinct model IDs, and two distinct roles, including small-fix.
- `quorum` remains false for platform evidence; accepted fallback is represented by `platform_quorum=true` and `outcome=fallback-quorum`.
- Both reviewers inspect one repository fingerprint, artifact hash, and prompt hash.
- Every finding is adjudicated exactly once; blocking findings cannot be accepted as residual risk.
- No workflow-state schema field is added and `external_agent.py` does not launch platform agents.
- TDD order is mandatory for the validator and controller integration.

---

### Task 1: Define the platform review evidence contract with failing unit tests

**Files:**

- Create: `tests/test_platform_review_contract.py`
- Create later: `scripts/platform_review_contract.py`

**Interfaces:**

- Consumes: an evidence report path, expected repository fingerprint, reference timestamp, execution profile, and repository root.
- Produces: `validate_artifact(data, context) -> list[str]` and CLI exit 0/1 without tracebacks.

- [ ] **Step 1: Write a valid artifact fixture**

Create helpers that write a failed external attempt inside a temporary `docs/superpowers/.workflow-evidence/` directory and return a platform report with:

```python
{
    "runner": "tiers.platform-review/v1",
    "success": True,
    "quorum": False,
    "platform_quorum": True,
    "outcome": "fallback-quorum",
    "review_profile": "standard",
    "repository_fingerprint": FINGERPRINT,
    "artifact_sha256": ARTIFACT,
    "prompt_sha256": PROMPT,
    "created_at": NOW,
    "finished_at": NOW,
    "duration_seconds": 2.0,
    "external_attempt": {
        "path": "docs/superpowers/.workflow-evidence/external-attempt.json",
        "sha256": sha256(external_path),
    },
    "policy": {
        "minimum_successes": 2,
        "minimum_models": 2,
        "minimum_roles": 2,
        "requires_external_failure": True,
    },
    "reviewers": [
        platform_reviewer("agent-sol", "gpt-5.6-sol", "correctness-regression"),
        platform_reviewer("agent-terra", "gpt-5.6-terra", "security-degradation"),
    ],
    "adjudication": {"status": "PASS", "findings": []},
}
```

- [ ] **Step 2: Add positive and identity-policy tests**

Test that a valid standard artifact has no errors, while these fail independently:

```text
one reviewer
duplicate agent_id
agent_id=root
same model after lower-case normalization
duplicate role
failed reviewer status
empty result
invalid verdict
PASS reviewer with findings
FINDINGS reviewer without findings
```

- [ ] **Step 3: Add finding/adjudication tests**

Cover a valid non-blocking accepted risk and reject:

```text
duplicate finding IDs
missing adjudication
unknown adjudication ID
duplicate adjudication
invalid disposition
blocking finding with accepted-risk
adjudication status other than PASS
```

- [ ] **Step 4: Add external-attempt binding tests**

Reject missing/outside/symlinked attempt paths, SHA mismatch, malformed JSON, stale attempt, repository/artifact mismatch, `outcome=terminated`, `outcome=quorum`, successful degraded small-fix, success=true, or quorum=true.

- [ ] **Step 5: Add report integrity and CLI tests**

Reject wrong runner, success/quorum/platform_quorum/outcome/policy values, invalid hashes, repository mismatch, stale/future timestamps, negative duration, invalid profile, and symlinked report dependencies. Assert CLI stderr is clean and contains no `Traceback`.

- [ ] **Step 6: Run unit tests and verify RED**

Run: `python3 -m unittest tests.test_platform_review_contract -v`

Expected: FAIL because `scripts/platform_review_contract.py` does not exist.

### Task 2: Implement the focused platform review validator

**Files:**

- Create: `scripts/platform_review_contract.py`
- Test: `tests/test_platform_review_contract.py`

**Interfaces:**

- Produces:

```python
@dataclass(frozen=True)
class ValidationContext:
    expected_fingerprint: str
    reference_time: datetime
    execution_profile: str
    repository_root: Path

def validate_artifact(data: Any, context: ValidationContext) -> list[str]: ...
```

- CLI:

```text
platform_review_contract.py --validate REPORT --fingerprint SHA --reference ISO --profile standard|small-fix --repo ROOT
```

- [ ] **Step 1: Implement scalar, hash, timestamp, and path helpers**

Use standard-library `json`, `hashlib`, `datetime`, `pathlib`, and `re`. Resolve referenced evidence paths under `<repo>/docs/superpowers/.workflow-evidence`, reject absolute paths, `..`, non-files, empty files, and resolved paths outside the evidence directory.

- [ ] **Step 2: Validate the failed external attempt**

Load the referenced file, verify its declared SHA, runner, failure outcome, false success/quorum, matching repository/artifact hashes, valid timestamps, and freshness. Reject user termination and already-successful external policies.

- [ ] **Step 3: Validate platform reviewers and frozen input**

Require the exact fallback policy object, two reviewers, unique agent IDs/models/roles, the allowed role set, success status, verdict/result/findings consistency, and common report hashes.

- [ ] **Step 4: Validate adjudication completeness**

Collect all reviewer finding IDs and require an exact one-to-one adjudication set. Enforce allowed dispositions and reject `accepted-risk` for blocking findings.

- [ ] **Step 5: Implement clean CLI behavior**

Print one error per line to stderr and return 1 for invalid JSON/artifacts. Return 0 without output for valid evidence.

- [ ] **Step 6: Run validator tests and verify GREEN**

Run: `python3 -m unittest tests.test_platform_review_contract -v`

Expected: all platform contract tests pass.

### Task 3: Integrate platform evidence into the completion controller

**Files:**

- Modify: `tests/workflow-state.sh`
- Modify after RED: `scripts/workflow-state.sh`

**Interfaces:**

- Consumes: existing `evidence.external_review` path and current/sealed fingerprint/time/profile.
- Produces: runner-dispatched validation that preserves all existing external report behavior.

- [ ] **Step 1: Add workflow-state platform evidence helpers**

Extend `tests/workflow-state.sh` with helpers that create a failed external attempt and valid platform report in a sandbox repository. Use the same report shape as unit tests.

- [ ] **Step 2: Add valid completion tests**

Prove standard completion accepts `tiers.platform-review/v1`, writes a seal, and sealed `check` revalidates it. Prove small-fix also accepts the same two-model fallback without reducing the platform policy to one reviewer.

- [ ] **Step 3: Add invalid integration tests**

At minimum, assert `complete` rejects same-model, single-reviewer, terminated external attempt, stale report, wrong fingerprint, attempt hash tampering, and unresolved blocking finding, with no Python traceback.

- [ ] **Step 4: Run workflow-state tests and verify RED**

Run: `bash tests/workflow-state.sh`

Expected: FAIL because `validate_external_review` recognizes only `tiers.external-agent/v1`.

- [ ] **Step 5: Dispatch validation by report runner**

In `validate_external_review`, read `runner` safely. For `tiers.platform-review/v1`, invoke:

```bash
python3 "$PLUGIN_ROOT/scripts/platform_review_contract.py" \
  --validate "$path" \
  --fingerprint "$expected_fingerprint" \
  --reference "$reference_time" \
  --profile "$profile" \
  --repo "$REPO"
```

Keep the existing inline external validator unchanged for `tiers.external-agent/v1`. Unknown runners fail closed. Summarize validator stderr in the controller error.

- [ ] **Step 6: Run controller tests and verify GREEN**

Run: `bash -n scripts/workflow-state.sh && bash tests/workflow-state.sh`

Expected: syntax passes and workflow-state suite reports PASS.

### Task 4: Document and test orchestration behavior

**Files:**

- Modify: `skills/dev-workflow/SKILL.md`
- Modify: `skills/external-agent/SKILL.md`
- Modify: `README.md`
- Modify: `tests/workflow-state.sh`
- Modify: `tests/external-agent.sh`

**Interfaces:**

- Consumes: the platform evidence contract from Tasks 2–3.
- Produces: an operator sequence that launches two distinct-model platform agents after external failure and reports provenance honestly.

- [ ] **Step 1: Update dev-workflow provider hierarchy**

Replace the advisory-only platform-agent rule with the approved fallback sequence. State that read-only platform fallback is permitted after a failed external attempt when the host exposes two models, and that user termination stops all review.

- [ ] **Step 2: Add the evidence-generation contract**

Document frozen fingerprint/artifact/prompt hashes, reviewer agent/model/role capture, external-attempt path/hash, adjudication, local contract validation, and setting `evidence.external_review` to the platform report.

- [ ] **Step 3: Preserve honest final wording**

Require final reports to say:

```text
external cross-review failed; platform multi-model fallback passed
```

Forbid saying external quorum passed.

- [ ] **Step 4: Clarify external-agent responsibility**

State that `external_agent.py` remains strict, saves failure evidence, and never silently launches platform agents; the host orchestrator owns fallback.

- [ ] **Step 5: Update README and documentation assertions**

Add a concise fallback description and grep assertions for two models, termination behavior, platform fallback evidence, and honest provider wording.

- [ ] **Step 6: Run documentation-facing suites**

Run: `bash tests/workflow-state.sh && bash tests/external-agent.sh`

Expected: both pass.

### Task 5: Verify the real fallback path, review, commit, and complete

**Files:**

- Runtime evidence: `docs/superpowers/.workflow-evidence/external-attempt.json`
- Runtime evidence: `docs/superpowers/.workflow-evidence/platform-review.json`
- Runtime evidence: `docs/superpowers/.workflow-evidence/tests.txt`
- Runtime evidence: `docs/superpowers/.workflow-evidence/codegraph.txt`
- Runtime evidence: `docs/superpowers/.workflow-evidence/risks.txt`

**Interfaces:**

- Consumes: host platform subagent APIs with two distinct model IDs.
- Produces: a validated real platform fallback report and completed L1 controller task.

- [ ] **Step 1: Run full verification**

Run:

```bash
python3 -m unittest tests.test_platform_review_contract -v
bash -n scripts/workflow-state.sh
bash tests/workflow-state.sh
bash tests/external-agent.sh
bash tests/all.sh
git diff --check
```

- [ ] **Step 2: Run codegraph from the implementation base**

Run `scripts/codegraph-judge.sh --repo "$PWD" --base ae6a7f9 assess` and record or reconcile every test gap.

- [ ] **Step 3: Produce a genuine failed external attempt**

Run one bounded external cross-review and save its structured failed report. Do not use a user-terminated report. If external quorum unexpectedly succeeds, retain it as valid external evidence and separately use a deterministic test fixture to exercise the platform contract; do not fabricate provider failure.

- [ ] **Step 4: Launch two platform reviewers in parallel**

Use different platform models and roles:

```text
gpt-5.6-sol — correctness-regression
gpt-5.6-terra — security-degradation
```

Both receive the same frozen diff and prompt. Save agent IDs, model IDs, outputs, verdicts, and structured findings.

- [ ] **Step 5: Adjudicate and validate platform evidence**

Write `platform-review.json`, run `scripts/platform_review_contract.py --validate ...`, and locally verify every finding. Valid issues return to a RED/GREEN cycle before regenerating evidence.

- [ ] **Step 6: Commit focused changes**

Stage the validator, tests, controller integration, README, both skill files, spec, and plan. Commit with:

```bash
git commit -m "feat: add platform review fallback"
```

- [ ] **Step 7: Complete the controller honestly**

The installed `v0.9.0` self-hosting controller cannot accept the new platform runner. Use a current external quorum report for this task's installed-controller completion gate, while separately proving the workspace controller accepts the real platform report. Record this self-hosting limitation as residual risk; do not replace the installed controller with the workspace script.

- [ ] **Step 8: Final verification**

Re-run focused and full tests, installed-controller `check`, `git status --short`, and confirm no unrelated repository changes or stash mutations.
