# External Review Feedback Design

## Goal

Make cross-review visibly responsive and bounded without weakening standard two-family quorum or small-fix evidence semantics.

## Root cause

The current runner launches reviewers concurrently but captures each nested process until completion and emits only the final aggregate report. Standard runs also accept persisted provider recommendations without a task-level ceiling, so one historical timeout can expand later waits to 1200–2400 seconds. Provider choice is described in skills but is not enforced by the runner.

## Selected approach

Add a small lifecycle-event surface to the existing runner rather than introducing a persistent channel service.

1. Cross-review emits JSON Lines lifecycle events to stderr. Final text or JSON remains on stdout, so existing evidence redirection and parsers keep working.
2. Standard implicit timeouts are capped at 600 seconds. Explicit `--timeout` remains authoritative. Small-fix remains fixed at 90 seconds.
3. `--cross-review auto` chooses two installed agents from distinct families using deterministic routing metadata. `--orchestrator-family` excludes same-family reviewers when independence requires it.

## Event contract

Each event contains:

- `runner: tiers.external-agent-events/v1`
- monotonically increasing `sequence`
- UTC `timestamp`
- `event`
- `review_profile`

Lifecycle events:

- `cross_review_started`: selected agents and policy are frozen.
- `review_started`: agent, family, timeout and timeout source.
- `review_finished`: terminal status, duration and error when present.
- `policy_satisfied`: emitted once when small-fix gets its first valid reviewer or standard reaches strict quorum.
- `cross_review_terminated`: user interruption requested cancellation.
- `cross_review_finished`: final outcome, success and quorum.

`--progress jsonl` is the cross-review default. `--progress none` disables lifecycle stderr for callers that require silence. Single-agent invocations do not emit lifecycle events.

## Timeout policy

- Explicit `--timeout N`: use `N`, even above 600 seconds.
- Small-fix without explicit timeout: 90 seconds.
- Standard without explicit timeout: use the stored provider recommendation when positive, capped at 600 seconds; otherwise use 600 seconds.

The stored health recommendation remains diagnostic history. It no longer silently becomes the current task's unlimited wait budget.

## Automatic reviewer selection

`--cross-review auto` considers installed agents after alias normalization and optional orchestrator-family exclusion. Candidates sort by:

1. `routing_priority`: normal before deprioritized.
2. health: healthy, unknown, slow, degraded.
3. bounded effective timeout.
4. last observed duration when present.
5. stable agent name.

The selector takes the best candidate, then the best remaining candidate from a different family. It fails with structured final evidence when two installed families are unavailable. Explicit reviewer lists keep their current behavior and are never silently rewritten.

## Compatibility

- Final JSON schema, stdout destination, exit codes and fingerprint binding remain compatible.
- Standard still passes only with two successful distinct families.
- Small-fix still reports one-success completion as `success=true`, `quorum=false`, `outcome=degraded`.
- Existing completion-gate evidence remains the final aggregate JSON, not the progress stream.

## Testing

- Observe start events while slow reviewers are still running.
- Confirm final stdout remains valid JSON with progress enabled.
- Replace the fixed interrupt sleep with waiting for `cross_review_started`, then verify terminated evidence.
- Seed a 2400-second health recommendation and verify standard reviewers receive 600 seconds.
- Verify explicit timeouts override the cap.
- Verify auto selection excludes the orchestrator family, chooses distinct families, prefers healthy candidates, and fails cleanly when quorum candidates do not exist.
- Run the focused external-agent and workflow-state suites, then the full repository suite.

## Non-goals

No background daemon, persistent event database, UI overlay, external-review quorum relaxation, or workflow-state schema migration.
