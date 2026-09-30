# ECI Task Orchestrator

This module defines task-scoped coordination for independent outcomes under one ECI lifecycle. It changes logical ownership only; it does not change worker runtime authority, hooks, or planner authority.

## Active task count and threshold

- Keep one lifecycle marker for the ECI root. Task orchestrators never start or close it.
- Let `N` count admitted independent task outcomes until main accepts them or their explicit cancellation closure completes. Cancellation closure includes observed shutdown of task-owned writers. Count capacity-queued, waiting, blocked, post-Fast, and cancellation-cleanup outcomes. Main reopening an accepted outcome after interacting evidence invalidates acceptance counts it again.
- Count outcomes, not paths, lanes, workers, reviews, additive follow-ups, or repair iterations. Main and Fast paths remain within their task outcome.
- At `N <= 1`, main coordinates the active task directly. At `N > 1`, one task orchestrator logically coordinates each active task. A new task admitted above the threshold gets its own task orchestrator; a closed task's owner retires with that task.
- If capacity is unavailable, main remains the named interim owner and queues the task orchestrator. The count does not change, and the queued task is not described as delegated.
- At `N = 0`, main performs ordinary lifecycle teardown only after every outcome is accepted or cancellation-closed and all task-owned writers are observed stopped.

## Responsibilities

Main retains:

- Task admission and reopening, cancellation and closure decisions, active-count tracking, and final acceptance.
- Lifecycle-marker ownership, protected controls, and lifecycle teardown.
- Global capacity, cross-task conflicts, and shared Git-index/checkpoint operations.
- Final disposition application and all decisions that affect more than one task.

Each task orchestrator coordinates only its assigned task's dispatch, sequencing, local dependencies, evidence, and progress across the main and Fast paths. It assigns task-local workers and routes their reports to the current logical owner without replacing those producers or changing their identities and accountability. It remains an ordinary runtime worker and cannot take main's lifecycle or protected-control authority.

Every worker assignment names its current logical report owner. Route task-local reports to that owner; route admission, closure, cross-task conflict, capacity, protected-control, shared Git-index/checkpoint, final-disposition, acceptance, and teardown decisions to main.

## Ownership handoffs

Main rechecks `N` and the current logical owner before publishing each pending handoff. If either changed, recompute the handoff from current state.

### `N` crosses from one to two

- Move every active task's logical coordination to one task orchestrator per task. Main remains the owner until each orchestrator accepts its bounded handoff.
- Include current scope, progress, evidence, dependencies, workers and assignments, outstanding reports, and in-flight coordination calls. Preserve existing worker identities, assignments, and evidence.
- No runtime reparent operation exists. Change the logical report route only; do not claim that runtime ancestry changed. Reports follow the current owner until the handoff is accepted and the new owner is published.
- Do not yield or stop writers solely for this ownership change. Yield only for a real shared-target conflict or checkpoint.

### `N` crosses from two to one

- Main resumes direct coordination of the remaining active task. That task's outgoing orchestrator stops new assignments, finishes or accounts for its current coordination call, transfers current task state, evidence, and logical report ownership to main, then becomes idle.
- Existing worker calls continue under their current scope, assignment, identity, and runtime ancestry. A coordinator change alone does not require writer quiescence, cancellation, or Fast completion. Yield only for a real shared-target conflict or checkpoint.
- The owner of an accepted or cancellation-closed task retires with that task; the surviving task's owner hands back to main when the count reaches one.
