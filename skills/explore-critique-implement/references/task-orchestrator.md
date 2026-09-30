# ECI Task Orchestrator

This module defines conditional task-local coordination under one ECI lifecycle. Task orchestration changes logical ownership only; it does not change worker runtime authority, hooks, or planner authority.

## Active task count and threshold

- Keep one lifecycle marker for the ECI root. Task orchestrators never start or close it.
- Let `N` count admitted independent task outcomes until main accepts them or their explicit cancellation closure completes. Cancellation closure includes observed shutdown of task-owned writers. Count capacity-queued, waiting, blocked, post-Fast, and cancellation-cleanup outcomes. Main reopening an accepted outcome after interacting evidence invalidates acceptance counts it again.
- Count outcomes, not paths, lanes, workers, reviews, additive follow-ups, or repair iterations. Main and Fast paths remain within their task outcome.
- At `N <= 1`, main coordinates the active task directly. At `N > 1`, one task orchestrator logically coordinates each active task. A new task admitted above the threshold gets its own task orchestrator; a closed task's owner retires with that task.
- If owner capacity is unavailable, main remains the named interim owner and queues a candidate. The count does not change, and the task is not described as delegated.
- At `N = 0`, main performs ordinary lifecycle teardown only after every outcome is accepted or cancellation-closed and all task-owned writers are observed stopped.

## Authority

Main alone owns task admission and closure, active-count tracking, global capacity and cross-task conflicts, shared Git-index/checkpoint operations, protected controls, final impact/treatment/dispositions, acceptance, and lifecycle teardown. Main also handles reports for closed tasks and decides whether their evidence reopens them.

A task orchestrator is an ordinary reusable coordination role with task-local authority only while main has published it as the owner of that task. It coordinates that task's dispatch, sequencing, dependencies, evidence, and progress across the main and Fast paths. It remains a runtime worker and preserves existing producers' identities, assignments, and accountability. It does not take main's lifecycle or protected-control authority.

Every worker assignment names main and the task's current logical report owner by runtime identity. Route task-local reports to that owner; route admission, closure, cross-task conflict, capacity, protected-control, shared Git-index/checkpoint, final impact/treatment/disposition, acceptance, and teardown decisions to main.

## Publication and handoff

Main may use `followup_task` to give explicit task-coordination or handoff instructions to the currently published task orchestrator, whether it is running or idle. Name the task, current ownership, bounded scope, and requested action. At `N <= 1`, resume that owner for handback only; it starts no new task assignments. A report-only follow-up to a non-current owner is allowed only for the report drain described below.

An incoming candidate may prepare and accept a bounded handoff but cannot coordinate the task before main publishes its ownership. Keep its preparation turn active through publication or withdrawal. Acceptance alone does not activate ownership. A withdrawn candidate becomes idle and handles any later report only as a relay. If later delegation needs a candidate and no preparation turn remains active, spawn a fresh candidate. Preserve all producer and reviewer identities.

Before either ownership transfer, the outgoing task-local owner stops new task dispatch and finishes or accounts for its current coordination call. Keep its handoff turn active while transferring scope, evidence, assignments, outstanding reports, and resulting state changes. Hold task-local reports arriving during this interval without processing them or advancing task work. Route main-only decisions to main.

Main rechecks `N` and actual ownership immediately before publication. If the pending transfer is no longer appropriate, withdraw or recompute it. The existing report route remains effective throughout preparation. On withdrawal, the still-published owner resumes the mode main specifies and processes its held reports; an unused candidate gains no authority.

After the candidate accepts, main publishes the new owner and then sends the effective route to the incoming owner, outgoing owner, and existing workers. Transfer held reports through main to the published owner. Do not wait for worker acknowledgements, restart workers, change their assignments or identities, stop writers solely for the transfer, or claim runtime reparenting.

After publication, an outgoing task orchestrator performs report relay only. Keep its handoff/relay turn active until main accounts for the already-produced reports identified by the transfer and observed completions; then it may become idle. Publication and continuing worker execution do not wait for future worker reports.

### `N` crosses from one to two

Move every active task's logical coordination to one published task orchestrator per task. Main remains the owner until each bounded handoff is accepted and published. Preserve existing workers, assignments, and evidence; change only the logical report route.

### `N` crosses from two to one

Main resumes direct coordination of the remaining active task. Its outgoing task orchestrator stops new assignments, finishes or accounts for its current coordination call, transfers current task state, evidence, and logical report ownership to main, then becomes idle. Existing worker calls continue under their current scope, assignment, identity, and runtime ancestry. A coordinator change alone does not require writer quiescence, cancellation, or Fast completion. Yield only for a real shared-target conflict or checkpoint. The owner of an accepted or cancellation-closed task retires with that task.

## Report delivery and drain

Each assignment names main and its logical report owner by runtime identity. Workers explicitly deliver progress and final reports before returning their normal final response. Preserve task, assignment, original source, report, and evidence references. Automatic final delivery to the runtime parent does not replace explicit reporting.

Use `followup_task` for reports addressed to a task orchestrator and `send_message` for reports addressed to main. `followup_task` starts a fresh turn for an idle role and can deliver instructions at a running role's message boundary. A published owner processes reports within its existing assignment, except while its handoff is holding reports. Report delivery adds no scope or authority.

A non-current task orchestrator—including a former, pending, or withdrawn owner—relays received reports to main without task dispatch, implementation, review, disposition, acceptance, or lifecycle action. A report-only turn returns to idle after relaying; delivery into an already-active preparation or handoff/relay turn preserves that turn until its existing completion condition.

Main processes reports for tasks it directly owns and for closed tasks. Main alone decides whether evidence reopens a closed task; never forward a closed task's report to its retired owner. For another active task, main verifies the published owner and forwards the report with `followup_task`. Repeated delivery is the same evidence, not another assignment or completed gate.

Main stays active in coordination or `wait_agent` until outstanding assignments, handoffs, and already-produced reports are accounted for. Queued delivery is not completed processing. Main may use a report-only `followup_task` to drain a non-current owner when an observed completion or handoff inventory identifies an already-produced report; name the affected assignment. Timeout alone does not trigger a drain.

On 1→2, main continues receiving through the old route until publication and then forwards delayed reports to the published task owner. On 2→1, the former task owner relays delayed reports to main. If a pending transfer is withdrawn, the unchanged published owner continues coordinating and the unused candidate remains report-only for any misdirected reports.

## Task-local review dispatch

The current logical task owner alone dispatches fresh task-local Step 2 critics, fresh A/B/C in parallel for each implementation iteration, and fresh independent E2E when required. Preserve reviewer independence, model selection, review scope, post-Fast sequencing, and E2E cadence. Obtain main's named checkpoint before checkpoint-dependent Step 4 dispatch. Transfer already-issued review assignments during handoffs; do not duplicate them.

Task orchestrators load [review policy](../../references/workflow-runtime/review-policy.md) for task-local review dispatch and evidence coordination. They send underlying reports, evidence, and disposition recommendations to main. Main adjudicates final impact, treatment, and dispositions and retains checkpoints, acceptance, and protected operations.

Task owners may maintain ordinary task review summaries. Those summaries are not exclusive publication or work-admission gates. Other coordinator-only lifecycle, protected-runtime, blocker, pause, stop, teardown, and pressure-policy duties remain with main.
