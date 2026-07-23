# Session-Scoped Tier Calibration Design

## Problem

The current guidance overweights broad signals such as “new behavior,” changed-file count, and domain keywords. In practice this causes many bounded tasks to default to L2 even when the current session changes no existing consumer or contract. Two confirmed examples are an isolated Kimi external-agent adapter and a static image path migration to OSS.

The workflow must classify the task performed in the current session, not the repository's general complexity, previous dirty changes, or the noun used in the request.

## Decision

Use a two-stage, session-scoped classification process.

1. Initial classification uses the stated objective, expected production boundary, and whether an existing contract or consumer will change.
2. Impact calibration runs after repository inspection or a task-specific codegraph snapshot. It may automatically raise or lower the initial tier when evidence changes the known boundary.

The classification explanation must name the current-session evidence. “It is new,” “it touches business code,” “three files changed,” or a codegraph score alone is not sufficient.

## Tier Boundaries

- L0 remains structural migration or multi-module architectural reorganization.
- L1 means a new module, complete user flow, cross-module orchestration, or a design with multiple unresolved behavioral branches. A small isolated addition is not L1 merely because it is new.
- L2 means existing shared behavior, contracts, or consumers are changed and therefore have a real regression surface. File count is supporting evidence, not the definition.
- L3 includes stable bug fixes and isolated behavioral additions whose entry point is explicit, whose implementation does not alter existing provider/consumer behavior, and whose regression boundary can be covered locally.
- L4 includes text/style changes and mechanical static-resource path replacements that preserve runtime logic, API/schema, control flow, and consumer semantics. These tasks still verify build or resource reachability when relevant.

High-risk auth, route guard, API write, order, IM, prescription, payment, schema, migration, and permission changes retain their existing minimum gates when the task actually changes that contract. Proximity to such code does not activate the gate.

## Session Evidence

Each visible classification must be justified using at least these questions:

- What exact production behavior changes in this session?
- Which existing consumers or contracts can regress?
- Is the change isolated behind a new explicit entry point?
- Does it change control flow, persistence, API/schema, permissions, or cross-end timing?
- What task-specific base and tests bound the impact?

If inspection contradicts the initial answer, the agent updates the tier without waiting for the user to correct it. The new classification must explain the evidence that changed.

Codegraph must use the current task base or checkpoint. Changed-file count, risk score, and test-gap output calibrate impact but never mechanically override verified task scope.

## Confirmed Examples

- Adding the Kimi adapter as `auto_eligible=false`, with an explicit entry point and no change to existing provider routing: L3.
- Replacing static image paths with equivalent OSS URLs without changing rendering logic or control flow: L4, with build/resource verification.
- Adding a complete questionnaire or cross-end orchestration: L1.
- Changing a shared store action or an existing API response contract: L2.
- Repairing an existing incorrect behavior with a reproducible regression test: L3.

## Learning Lifecycle

Add a deterministic `learnings.sh fold <category>` command. It changes every pending record in the confirmed category to `folded`, leaves other categories and statuses untouched, and reports the number of records changed. The command is used after the approved rule is committed to the workflow guidance.

For this task, both pending `流程/tie-breaker` records—the Kimi adapter and static OSS migration—must be folded.

## Documentation and Tests

- Update `skills/dev-workflow/SKILL.md` decision tree, tie-breaker, tier definitions, codegraph calibration, and boundary table.
- Update `README.md` quick reference and examples so the public contract matches the skill.
- Extend `tests/workflow-state.sh` with assertions for the session-scoped rules and confirmed examples.
- Allow L3 understanding to use `root-cause` evidence for bugs or `impact` evidence for isolated additions; keep the persisted workflow-state schema unchanged.
- Extend `tests/learnings.sh` with RED/GREEN coverage for category folding, idempotency, and isolation from unrelated pending records.
- Keep controller schemas unchanged; classification remains an agent decision rather than a new persisted scoring engine.

## Non-Goals

- No keyword-based or numeric automatic tier scoring engine.
- No weakening of real business-contract gates.
- No modifications to business repositories or their active worktrees.
- No retroactive reclassification of completed workflow states.
