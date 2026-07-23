# Execution Mode Choice Design

## Problem

The workflow currently has `execution.mode: single` (and `goal` for Goal tasks), but the plan-to-TDD handoff does not let users choose whether to execute inline or use independent parallel workers. Long workflows therefore serialize work that could safely run concurrently, while naïve parallel writes would create shared-checkout conflicts.

## Decision

Add a plan-time execution choice with a conservative Hybrid policy:

- `single`: execute in the current integration session/worktree.
- `multi-agent`: run independent ready tasks in parallel; read-only workers may share the frozen integration checkout, while every write worker uses its own worktree/branch.
- `goal`: preserve existing Goal behavior and never reinterpret it as multi-agent.

The choice happens once after understanding and plan are ready, immediately before TDD/execution. The controller reports the recommendation and evidence. It does not repeatedly ask unless the plan/scope hash changes or the selected mode becomes invalid.

## Eligibility and Safety

Multi-agent mode is valid only when all conditions hold:

1. The execution manifest has at least two ready tasks.
2. Ready tasks have no unmet dependency and have explicit write sets or are read-only.
3. Write sets are disjoint; shared schema/migration/lock/config files, same-file tasks, strong ordering, release/deploy/credential/destructive operations are not parallelizable.
4. The plan/base fingerprint is frozen and the host has available worker slots.
5. Each write worker has an isolated worktree and branch under the host-owned worktree root.

L4, L3 `small-fix`, one-task plans, same-file changes, and tasks with unknown write sets default to `single`. The user may select `multi-agent` only when the manifest validates; an invalid selection fails closed with a reason and can be changed back to `single`.

Workers must not modify the integration controller, suspend/resume state, release/deploy state, credentials, or another worker's branch. The host owns task transitions, merge/cherry-pick, conflict resolution, integration tests, and cleanup. A failed or cancelled worker may be marked failed and the remaining work may continue inline; failure is not silently treated as success.

## State and Manifest

Keep the existing YAML state shape and add scalar fields:

- `execution.mode: single | multi-agent | goal`
- `execution.plan_sha256`: hash of the approved plan/manifest input
- `execution.max_workers`: positive integer, default 2
- `execution.fallback_reason`: host explanation when multi-agent is unavailable or downgraded
- `artifacts.execution_manifest`: repository-relative JSON/YAML manifest path

The manifest is host-owned evidence and contains task id, dependencies, read-only flag, write set, worktree path/branch, worker commit, and status. It must be under `docs/superpowers/.workflow-evidence/` and bound to the current repository/base and plan hash. It is not copied into worker controller state.

## Lifecycle

```text
understanding-passed → plan-ready → execution-choice → tdd/executing
single: current session → review → verify → complete
multi-agent: ready → running (worker worktrees) → committed → integrating (host) → review → verify → complete
```

Worker states are `pending`, `ready`, `running`, `committed`, `integrating`, `reviewed`, `completed`, `blocked`, `failed`, or `cancelled`. `suspend/resume` remains a user task lifecycle and is never used for workers.

## Documentation and Tests

- Update `templates/workflow-state.yaml` and `scripts/workflow-state.sh` to validate mode, manifest, plan hash, worker limit, and safe transitions while preserving Goal mode.
- Add a host-owned execution manifest validator with write-set overlap, dependency, base/plan hash, worktree, and cleanup checks.
- Update `skills/dev-workflow/SKILL.md` and `README.md` to ask once after planning and document the Hybrid rules.
- Add TDD tests for single compatibility, multi-agent eligibility, overlap rejection, read-only sharing, worker failure fallback, integration conflict fail-closed, and cleanup only after successful integration.

## Non-Goals

- No simultaneous writes to one checkout.
- No automatic multi-agent mode for small fixes or unknown plans.
- No worker ownership of the main controller or release lifecycle.
- No change to L0-L4 risk definitions.
