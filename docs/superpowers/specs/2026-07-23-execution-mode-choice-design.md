# Native-First Execution Mode Choice Design

## Decision

After requirements understanding and an implementation plan are ready, the
workflow asks once whether to execute in the current session (`single`) or
with multiple agents (`multi-agent`). The choice is an execution preference,
not a new risk tier or a change to the accepted requirements.

`multi-agent` is **native-first**. Codex and Claude Code already own agent
dispatch, model selection, worktree isolation, result collection, and cleanup.
The workflow supplies the plan and clear task boundaries; the host runtime
performs the dispatch. The integration session remains responsible for the
final diff, tests, review, and completion evidence.

## Fallback

If native parallel execution is unavailable, fails, or is disabled by the
user, the workflow records a non-empty fallback reason and continues in the
current integration session. It does not recreate worktrees, branches,
write-set scheduling, worker lifecycle, merging, or cleanup in shell/Python.
This makes the fallback safe and predictable: it is sequential execution, not
an imitation of parallel writes in a shared checkout.

External CLIs remain an explicit opt-in for a bounded delegate or a read-only
review. They are not the default multi-agent runtime and a shared-checkout
delegate is never described as isolated parallel writing.

## Controller Contract

The persisted state is deliberately small:

- `execution.mode`: `single`, `multi-agent`, or existing `goal`.
- `execution.choice_status`: whether a plan-time choice was made.
- `execution.plan_sha256`: binds the selection to the plan shown to the user.
- `execution.fallback_reason`: records a native-to-single downgrade.

The controller requires a selection for planned work before TDD, preserves
the existing no-plan L2/L3/L4 implicit-single compatibility, and permits the
only runtime change `multi-agent → single` with a reason. Plan changes permit
the user to reset and choose again. Execution fields are excluded from the
requirements-understanding scope hash.

## Host Guidance

For `multi-agent`, the skill tells the host to use its native facility and to
partition independent work. Same-file edits, dependent changes, migrations,
release/deploy work, and any task the runtime cannot isolate run as `single`.
The host may choose models using its own capability and task policy; the
plugin does not hard-code model identities or provider routing.

## Non-goals

- No plugin-owned execution manifest or worker state machine.
- No plugin-created worktrees, branches, commits, merges, or cleanup.
- No custom parallel-write safety protocol that duplicates host guarantees.
- No change to Goal mode, risk-tier classification, or external-review policy.

## Verification

Controller tests cover selection, plan binding, reset, native-to-single
fallback, and legacy compatibility. Documentation tests require an explicit
native-first contract, the sequential fallback, and the prohibition on
claiming external shared-checkout delegation is isolated parallel execution.
