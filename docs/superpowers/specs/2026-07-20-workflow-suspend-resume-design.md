# Workflow Suspend/Resume Design

## Goal

Allow an unfinished workflow-controller task to be parked without pretending it is complete, so a different task can legally occupy the repository's single active workflow slot and the parked task can later be restored exactly.

The immediate use case is to suspend the backend-blocked doctor questionnaire task, start the doctor prescription integration as a new L1 task, and retain a deterministic path back to the questionnaire state.

## Current Constraint

The controller currently has one state file, `docs/superpowers/.workflow-state.yaml`, and `start` only accepts a task whose current state has a valid completion seal. This correctly prevents overwriting unfinished work, but it has no legal task-switch operation when the current task is genuinely blocked.

Manually copying or replacing the state file is not acceptable because it bypasses controller validation, has no integrity check, and makes recovery dependent on operator memory.

## Considered Approaches

1. **Ignored-directory snapshots with one active slot (selected).** Preserve the existing state schema and parser, add explicit `suspend` and `resume` transitions, and store inactive states outside Git tracking.
2. **A task stack inside the current YAML.** Rejected because the controller intentionally supports only top-level and one-level scalar fields; arrays or nested task objects would require a new parser and migration path.
3. **Per-task states plus an active-task pointer.** Rejected because it changes every controller operation and requires migration, pointer-recovery, and multi-file consistency rules beyond the immediate need.

## Selected Storage Contract

Snapshots live under:

```text
docs/superpowers/.workflow-suspended/
  <key>.yaml
  <key>.meta
```

`<key>.yaml` is the byte-for-byte active state after the controller's normal schema migration at command entry. The controller does not add snapshot-only fields to it.

`<key>.meta` is a small, strictly parsed sidecar containing:

```text
format: workflow-snapshot/v1
repository_sha256: <64 lowercase hex>
state_sha256: <64 lowercase hex>
```

`repository_sha256` binds the snapshot to the canonical repository instance used by the command. A copied snapshot fails closed in another repository. `state_sha256` detects accidental modification or partial writes. This is an integrity check, not a cryptographic signature against an attacker who can rewrite both files.

The controller ensures `docs/superpowers/.workflow-suspended/` is ignored by Git before creating a snapshot. The ignore entry is exact and idempotent.

## Key Contract

The operator supplies a stable key explicitly:

```bash
workflow-state.sh suspend doctor-questionnaire-generation
workflow-state.sh resume doctor-questionnaire-generation
```

A valid key:

- is 1–64 characters;
- starts with a lowercase ASCII letter or digit;
- contains only lowercase ASCII letters, digits, hyphens, and underscores;
- cannot contain a slash, backslash, dot segment, whitespace, or shell metacharacter.

The controller rejects an unsafe key before creating or reading any path. It also rejects a duplicate key if either sidecar already exists, so an existing parked task is never overwritten.

## Active-Slot Model

The active slot has three legal forms:

| Form | Meaning | `start` | `resume` |
|---|---|---:|---:|
| State file absent, or a completely empty initialized template | No active task | allowed | allowed |
| Valid unfinished task | Active work is owned by that task | rejected | rejected |
| Valid completed and sealed task | No unfinished task owns the slot | allowed | allowed |

A partially populated template, `phase: done` without a valid seal, or any other malformed state is not an empty slot. The controller rejects the operation instead of overwriting ambiguous data.

`suspend` removes the active state file only after the snapshot pair is fully installed. The absent file is the canonical empty-slot representation. A later `init` may recreate an empty template without losing the parked snapshot.

## `suspend <key>` Contract

`suspend` succeeds only when all of the following are true:

- an active state file exists;
- it passes the current controller validation;
- it represents an unfinished task with non-empty `task`, valid `level`, and a non-`done` phase;
- `completion.completed_at` is empty;
- the key is safe and unused;
- the snapshot directory resolves inside the current repository and is not a symlink escape;
- the suspended-directory ignore rule is present.

The operation runs under the same per-state controller lock used by all state mutations.

Write order:

1. Copy the normalized active state to a temporary file beside the final snapshot.
2. Compute the state SHA-256 and repository identity.
3. Write and validate a temporary metadata sidecar.
4. Atomically rename both temporary files to their final snapshot names.
5. Re-read and verify the installed pair.
6. Remove the active state file, making the slot empty.

Any failure before step 6 leaves the active state intact. A crash between the two final renames may leave a partial snapshot pair, but it cannot lose the active task; the partial pair blocks duplicate reuse of the key and produces a precise recovery error.

## `start <task> <level>` Contract

`start` keeps its existing sealed-task behavior and additionally accepts an empty active slot.

- If the state file is absent, `start` creates a fresh template and initializes the new task directly.
- If the state file is a completely empty initialized template, `start` initializes it.
- If the current state is valid and sealed, `start` replaces it as today.
- If any unfinished or malformed state occupies the slot, `start` fails without changing it.

This makes the intended switch sequence legal:

```text
unfinished task -> suspend -> empty slot -> start new task
```

## `resume <key>` Contract

`resume` succeeds only when:

- the key is safe;
- both snapshot files exist as regular files;
- metadata format and hashes are valid;
- repository identity matches the current canonical repository instance;
- the snapshot is a valid unfinished workflow state;
- the active slot is empty or contains a valid sealed task.

Restore order:

1. Validate the active-slot precondition without modifying it.
2. Validate the snapshot pair and SHA-256 values.
3. Copy the snapshot state to a temporary file beside the active state.
4. Validate the temporary state as if it were active.
5. Atomically rename the temporary file to `.workflow-state.yaml`.
6. Verify that the active state digest matches the snapshot digest.
7. Delete `<key>.yaml` and then `<key>.meta`.

Snapshot deletion only happens after a successful restore. If cleanup fails after the active state is restored, the command reports a cleanup error and leaves the remaining snapshot artifact in place; it never rolls back to an unrelated task or deletes the restored state.

The restored YAML is exact. Its prior `phase`, understanding hashes, artifacts, evidence references, requirements, and `next` instruction are not recomputed or reset.

## Failure and Recovery Semantics

- Unsafe or duplicate keys fail before state mutation.
- Hash mismatch, malformed metadata, wrong repository, missing sidecar, or snapshot symlinks fail without touching the active slot.
- `suspend` while no task is active or while the task is sealed fails.
- `resume` or `start` while another unfinished task is active fails.
- `resume` of a completed snapshot fails; snapshots are for parked unfinished tasks, not rollback archives.
- Existing completion, understanding, Goal, external-review, and evidence gates remain unchanged after restoration.
- Error messages identify the failed precondition and key but do not print snapshot contents.

There is no automatic conflict resolution, overwrite flag, or force mode. Manual recovery remains possible by inspecting the ignored snapshot files, but normal task switching must use controller commands.

## CLI and Documentation Changes

The usage contract becomes:

```text
workflow-state.sh [--repo R] {
  init |
  start <task> <level> |
  suspend <key> |
  resume <key> |
  goal <objective> |
  continue-goal <objective> |
  understand <evidence> |
  confirm <json> |
  get <field> |
  set <field> <value> |
  check |
  complete
}
```

`README.md` and `skills/dev-workflow/SKILL.md` will describe the legal task-switch sequence and explicitly prohibit using `complete`, manual YAML replacement, or `start` to disguise an unfinished task.

The repository `.gitignore` will include `docs/superpowers/.workflow-suspended/`. Controller behavior will keep this entry idempotent for repositories that use suspend/resume.

## Test Strategy

Tests are added to `tests/workflow-state.sh` before implementation and must first fail for the missing behavior.

Required cases:

- suspend then resume restores the exact original state bytes and all meaningful fields;
- suspend clears the active slot and `start` can initialize a new task from that empty slot;
- resume is allowed after the intervening task is validly sealed;
- start and resume reject another unfinished active task;
- suspend rejects empty and sealed states;
- duplicate key rejection preserves both active state and the original snapshot;
- unsafe keys reject traversal, separators, dot segments, whitespace, uppercase, overlength input, and metacharacters;
- missing YAML or metadata sidecars fail safely;
- snapshot or metadata tampering fails without replacing the active state;
- copying a valid snapshot pair to a different repository fails repository validation;
- malformed or partially populated active states are not treated as empty;
- symlinked snapshot paths cannot escape the repository;
- repeated ignore management does not duplicate `.gitignore` entries;
- interrupted/partial snapshot pairs remain recoverable and never cause active-state loss;
- existing init, start-after-seal, understanding, completion, Goal, and concurrency tests remain green.

## Rollout Sequence

1. Add RED controller tests for the state transitions and failure paths.
2. Implement key, repository-identity, snapshot validation, and atomic file helpers.
3. Implement `suspend`, empty-slot-aware `start`, and `resume` under the existing lock.
4. Update usage text, `.gitignore`, README, and dev-workflow guidance.
5. Run focused tests, the full repository suite, syntax checks, diff checks, codegraph assessment, and external cross-review.
6. Seal the controller task only after its evidence gates pass.
7. In `gst-ai-doctor-console`, suspend `doctor-questionnaire-generation`, start `医生端处方正式中转接入` as L1, and preserve the questionnaire snapshot for later resume.

## Non-Goals

- Multiple simultaneously active tasks.
- Listing, renaming, deleting, expiring, or garbage-collecting snapshots.
- Nested task stacks, automatic LIFO behavior, or implicit key generation.
- Cross-repository or cross-clone snapshot portability.
- Changing workflow state schema, phase names, evidence semantics, or completion seals.
- Automatically completing, cancelling, or downgrading a blocked task.
- Modifying doctor questionnaire or prescription product code as part of the controller implementation.
