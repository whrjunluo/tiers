# Platform Multi-Model Review Fallback Design

## Goal

Allow a workflow that requires adversarial review to recover from external CLI provider failure by launching two read-only platform subagents with different model IDs, while preserving a strict, auditable completion gate.

The fallback must distinguish “external infrastructure failed” from “the reviewed change failed review.” It must never describe platform review as external cross-family quorum.

## Current Failure

The controller currently accepts only `tiers.external-agent/v1` evidence:

- standard requires two successful external reviewer families;
- small-fix accepts the existing explicit one-success degraded external policy;
- failed authentication, timeout, empty output, unavailable families, or partial standard quorum cause `complete` to fail.

`skills/dev-workflow/SKILL.md` mentions platform agents as advisory reviewers, but they cannot produce evidence that the controller accepts. As a result, repeated external provider outages can block an otherwise reviewed change indefinitely.

## Considered Approaches

### 1. Discriminated evidence in the existing field (selected)

Keep `evidence.external_review` as the workflow-state reference and accept two runner types:

- `tiers.external-agent/v1` for existing external CLI evidence;
- `tiers.platform-review/v1` for a validated fallback that references the failed external attempt.

This avoids a workflow-state schema migration and keeps completion policy centralized.

### 2. Add `evidence.platform_review`

Rejected because every template, migration, field allowlist, seal, and completion path would need another state field. The two evidence types are mutually exclusive final providers, so two state references add coordination without adding safety.

### 3. Synthesize platform agents as external reviewer families

Rejected because it would misrepresent provenance and make reports claim external quorum when no external provider succeeded.

## Trigger and Routing Policy

External CLI cross-review remains the first provider.

Platform fallback is allowed only after one genuine external cross-review report exists and satisfies all of these conditions:

- `runner` is `tiers.external-agent/v1`;
- `success` is `false`;
- `quorum` is `false`;
- `outcome` is `failed`;
- its repository fingerprint and frozen artifact hash match the platform review;
- it is no older than 24 hours at completion time.

Allowed external failure causes include provider authentication failure, timeout, empty output, failed reviewer, auto-selection with fewer than two eligible families, or a partial standard result.

The following do not trigger fallback:

- `outcome=terminated`, because a user stop request stops all later review gates;
- external `outcome=quorum`, because review already passed;
- small-fix `outcome=degraded` with `success=true`, because the existing small-fix policy already passed;
- missing, malformed, stale, repository-mismatched, or manually fabricated external attempt evidence.

After a valid failure, the orchestrator does not repeatedly cycle through external providers. It launches the platform reviewers in parallel when the host exposes platform subagents and at least two distinct model IDs.

## Platform Reviewer Requirements

The fallback always requires two reviewers, including for `execution.profile=small-fix`.

Each reviewer must have:

- a non-empty, unique platform `agent_id` that is not the root orchestrator;
- a non-empty model ID distinct from the other reviewer after lower-case normalization;
- a distinct review role;
- `status=success`;
- a non-empty result;
- `verdict=PASS` with no findings, or `verdict=FINDINGS` with a non-empty structured finding list.

The initial roles are:

- `correctness-regression`: state transitions, regression risk, tests, data loss, and behavior compatibility;
- `security-degradation`: trust boundaries, path/permission safety, provider failure semantics, installation and degraded-mode behavior.

The two reviewers receive the same:

- repository fingerprint;
- artifact SHA-256;
- prompt SHA-256;
- read-only repository scope.

The main orchestrator does not count as a reviewer. Same-model fresh contexts remain useful advisory opinions but cannot satisfy this fallback policy.

## Evidence Contract

The final evidence remains referenced through `evidence.external_review`, but the report identifies its provider honestly:

```json
{
  "runner": "tiers.platform-review/v1",
  "success": true,
  "quorum": false,
  "platform_quorum": true,
  "outcome": "fallback-quorum",
  "review_profile": "standard",
  "repository_fingerprint": "<64 lowercase hex>",
  "artifact_sha256": "<64 lowercase hex>",
  "prompt_sha256": "<64 lowercase hex>",
  "created_at": "2026-07-22T00:00:00Z",
  "finished_at": "2026-07-22T00:01:00Z",
  "duration_seconds": 60.0,
  "external_attempt": {
    "path": "docs/superpowers/.workflow-evidence/external-attempt.json",
    "sha256": "<64 lowercase hex>"
  },
  "policy": {
    "minimum_successes": 2,
    "minimum_models": 2,
    "minimum_roles": 2,
    "requires_external_failure": true
  },
  "reviewers": [
    {
      "agent_id": "platform-agent-1",
      "model": "gpt-5.6-sol",
      "role": "correctness-regression",
      "status": "success",
      "verdict": "PASS",
      "result": "No blocking correctness findings.",
      "findings": []
    },
    {
      "agent_id": "platform-agent-2",
      "model": "gpt-5.6-terra",
      "role": "security-degradation",
      "status": "success",
      "verdict": "PASS",
      "result": "No blocking degradation findings.",
      "findings": []
    }
  ],
  "adjudication": {
    "status": "PASS",
    "findings": []
  }
}
```

`quorum` remains `false` because it is reserved for external cross-family quorum. `platform_quorum=true` and `outcome=fallback-quorum` identify the accepted fallback policy.

## Finding and Adjudication Contract

Reviewer findings have this shape:

```json
{
  "id": "correctness-1",
  "blocking": true,
  "summary": "Restored state can overwrite active work",
  "evidence": "scripts/workflow-state.sh:100"
}
```

If a reviewer returns `verdict=FINDINGS`, every finding must have a unique ID, boolean `blocking`, non-empty summary, and non-empty evidence.

The adjudication must reference every reviewer finding exactly once:

```json
{
  "id": "correctness-1",
  "disposition": "fixed",
  "basis": "Added active-slot rejection and regression coverage"
}
```

Allowed dispositions are:

- `fixed`;
- `false-positive`;
- `accepted-risk` for non-blocking findings only.

Blocking findings cannot be `accepted-risk`. Missing findings, duplicate adjudications, unknown finding IDs, `status` other than `PASS`, or unresolved blocking findings reject completion.

## External Attempt Binding

The platform report references the original external attempt by repository-relative evidence path and SHA-256.

The validator resolves that path inside `docs/superpowers/.workflow-evidence/`, rejects absolute paths, `..`, missing files, empty files, and symlinks that escape the repository, then validates:

- the declared SHA-256 matches the external attempt file;
- the external runner, failure outcome, success, and quorum fields match fallback policy;
- repository and artifact hashes equal the platform report;
- the attempt and platform report are both within the completion freshness window.

This prevents a successful or user-terminated external report from being relabeled as provider failure.

## Controller Integration

Add `scripts/platform_review_contract.py` as a focused validator, following the existing `confirmation_contract.py` pattern.

`workflow-state.sh validate_external_review` keeps the existing external JSON validator unchanged for `tiers.external-agent/v1`. When the final report runner is `tiers.platform-review/v1`, it invokes the new contract with:

- the report path;
- current or sealed repository fingerprint;
- current or sealed reference time;
- current execution profile;
- repository root.

The controller accepts the report only when the contract exits zero. Error output is summarized without a Python traceback.

No workflow-state template or migration field is added.

## Orchestration Guidance

`skills/dev-workflow/SKILL.md` will specify this sequence:

1. Run one bounded external cross-review and save it as `external-attempt.json`.
2. If it succeeds, use the existing external evidence path.
3. If it fails with `outcome=failed`, and platform subagents plus two model IDs are available, launch both reviewers in parallel against one frozen input.
4. Write and validate `platform-review.json`.
5. Set `evidence.external_review` to the platform report.
6. Report the outcome as “external review failed; platform multi-model fallback passed.”

If two distinct platform models are unavailable, the built-in checklist remains advisory and the completion gate stays blocked. The workflow must state that neither external quorum nor platform fallback quorum was completed.

`skills/external-agent/SKILL.md` will clarify that the external runner remains strict and does not silently invoke platform agents; orchestration belongs to dev-workflow and the host platform.

## Failure Semantics

- User termination stops fallback and all later review gates.
- One successful platform reviewer is insufficient.
- Two agents using the same model are insufficient.
- Two model labels with the same normalized value are insufficient.
- The root orchestrator cannot be listed as a reviewer.
- Empty result text, failed status, malformed verdict, malformed findings, or mismatched roles fail closed.
- Repository, artifact, prompt, external-attempt, and time tampering fail closed.
- A valid platform fallback never changes the external attempt file.
- Platform fallback does not install tools, authenticate providers, elevate permissions, or change files under review.

## Test Strategy

Add unit tests for `platform_review_contract.py` covering:

- valid platform fallback quorum;
- same-model reviewers;
- duplicate agent IDs or roles;
- root orchestrator reviewer;
- single reviewer, failed reviewer, and empty result;
- invalid verdict/finding combinations;
- missing, duplicate, or unresolved adjudication;
- blocking `accepted-risk`;
- invalid repository, artifact, prompt, SHA, timestamps, duration, and profile;
- missing, outside-root, symlinked, malformed, stale, successful, degraded, quorum, or terminated external attempt;
- external attempt repository/artifact mismatch.

Add workflow-state integration tests proving:

- standard completion accepts a valid platform fallback report;
- small-fix still requires two platform models;
- existing external standard and small-fix evidence remain accepted unchanged;
- invalid platform reports fail with a clean controller error rather than a traceback;
- sealed `check` revalidates the fallback against the completion fingerprint and timestamp.

Add documentation assertions for the fallback sequence, honest provider wording, user-termination stop rule, and two-model requirement.

## Non-Goals

- Launching platform agents from `external_agent.py`.
- Treating platform models as external provider families.
- Accepting same-model fresh contexts for standard completion.
- Falling back after a user stop request.
- Repeatedly retrying external CLI families before platform fallback.
- Adding a second workflow-state evidence field.
- Cryptographically signing agent output against a malicious operator who can rewrite the repository and both evidence files.
