---
name: writing-status-reports
description: Use when giving a concise status report, sitrep, or quick status update about work in progress or recently completed work, including progress, decisions, blockers, risks, verification, or next focus.
---

# Writing Status Reports

Core rule: Report changed state, not activity logs. Be concise, specific, and explicit about progress, decisions, blockers, verification, and next focus.

## When to Use

- Work is in progress and the user asks for status, sitrep, progress, or a quick update.
- Work just finished and the user needs a concise completion report.
- A plan, review, handoff, or checkpoint needs current state without an action log.

## When Not to Use

- The user asks for full logs, raw command output, a transcript, or detailed reasoning.
- The work has not started; give the planned first step instead.
- The task requires a formal handoff; use `writing-handovers`.

## Coverage Categories

| Category | Include when relevant |
| --- | --- |
| State | Current overall state in one line. |
| Progress | Outcomes and changed state, not actions taken. |
| Decisions | Chosen path plus reason. |
| Blockers/Risks | Impact, owner, exact unblock action, and target artifact/path when applicable. |
| Verification | Tests, commands, observed behavior, or "not verified yet". |
| Next Focus | Next concrete work area, not "continue". |

Progress reports changed state and completed outcomes, not files read, commands run, or agents contacted unless those actions are verification evidence.

## Format Rules

- Keep updates short: one tight paragraph or relevant coverage categories as bullets.
- Lead with state, then include only categories that changed or matter now.
- Name exact affected area, requirement, command, file, or decision when relevant.
- Use "not verified yet" instead of implying unrun checks passed.
- For blockers/risks, state impact, owner, and exact unblock action; user blockers must name the user's action and target artifact/path when applicable, e.g. `review docs/design.md`.
- Preserve parent/child work: use a tree, or include `Task ID` and `Parent ID` columns; do not flatten children into peer lanes.
- If task IDs exist, make them hierarchical, e.g. `1`, `1.3`, `1.3.2`, and sort children under their parent.
- Use readable requirement context when it is available in active ECI/ATE. Keep the fuller requirement-to-lane explanation in `project-understanding.md`.
- When requirement context is missing or stale, write `lineage unavailable—reconcile` beside the lane and continue the status report and safe bounded work. Do not invent a registry or turn missing context into a blocker.
- In direct work, include requirement context only when it helps the reader.

## Lane forecasts

Use these labels in every multi-lane row and single-lane report.

| Field | Record |
| --- | --- |
| Next milestone | `Next milestone: <named outcome>` |
| Forecast deadline | `Forecast deadline: by <UTC ISO8601> — forecast, not a promise.` |
| Forecast recalibration | `Forecast recalibration: moved earlier | moved later | unchanged — <prior deadline> → <current deadline>; <why>; <evidence>` |
| Dependencies / critical path | `Dependencies / critical path: <none, named dependency + owner/resume, or critical path>` |

Every non-`CLOSED` lane names its next milestone and forecast deadline. A
`CLOSED` lane records `Completed: <UTC ISO8601>; no active forecast deadline.`
For an initial forecast, write `Forecast recalibration: unchanged — baseline <current deadline>; <why>; <evidence>`.

Every material status report recalibrates each affected lane with its prior and
current deadline, why, and evidence. State dependencies and parallel work.
For parallel children, report the single critical-path deadline; child deadlines remain parallel.

Forecast deadlines are forecasts, not promises. They are coordination aids for
catching stale planning assumptions under the non-malicious-bot principle. They
never gate work, authorize or deny work, create a blocker, require a receipt or
artifact, or require per-command updates. Correct missing or stale forecast
deadlines alongside safe work.

| Pressure | Correct report |
| --- | --- |
| Active lane lacks a milestone or deadline | An active lane missing a named milestone or forecast deadline is corrected alongside safe work. |
| Forecast deadline was copied without current evidence | A forecast deadline copied without prior/current deadlines, why, and evidence is stale. |
| Parallel children | For parallel children, report the single critical-path deadline; child deadlines remain parallel. |
| Dependency is paused | A paused dependency names its owner and resume condition; it is not a user blocker. |

## Multi-Lane Mission Status

For “where are we on each lane?” or “who works on each lane?”, report every in-scope lane known from the active plan, ledger, or test matrix. Include idle, waiting, review, deploy, proof, and paused lanes.

Use three separate status columns so source readiness cannot be mistaken for E2E completion.

When work is flat and has no task IDs, omit `Task ID` and `Parent ID`. Keep `Lane` followed by `Lane requirement context` when that context would help the reader. Use a known readable reference or `lineage unavailable—reconcile`.

| Task ID | Parent ID | Lane | Lane requirement context | Stage | Owner | Implementation Status | Test Status | Prod Status | Blocker | Next milestone | Forecast deadline / recalibration | Dependencies / critical path | Next proof/action |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `1.3.2` or `none` | `1.3` or `none` | `<human-readable lane result wanted>` | `<known requirement or lineage unavailable—reconcile>` | `normal` or `emergency` | `<person/agent or unowned>` | `NEW` / `IN PROGRESS` / `PAUSED` / `BLOCKED` / `CLOSED` | `NEW` / `IN PROGRESS` / `PAUSED` / `BLOCKED` / `CLOSED` | `NEW` / `IN PROGRESS` / `PAUSED` / `BLOCKED` / `CLOSED` | `none` or `PAUSED: <dependency lane; impact; owner; resume condition>` or `BLOCKED: <exact user input/decision; impact; owner: user; exact unblock action; target artifact/path>` | `Next milestone: <named outcome>` | `Forecast deadline: by <UTC ISO8601> — forecast, not a promise.`<br>`Forecast recalibration: moved earlier | moved later | unchanged — <prior deadline> → <current deadline>; <why>; <evidence>` | `Dependencies / critical path: <none, named dependency + owner/resume, or critical path>` | `<next evidence/action>` |

Every lane may record `Stage: normal` or `Stage: emergency` as current-state
context. Missing, stale, or unknown stage metadata is reported and reconciled
without pausing harmless work. `Stage: emergency` may use
`skills/explore-critique-implement/references/emergency-unblock.md` as a
recovery aid, but stage grammar and its records never authorize or deny normal
work or change the implementation/test/production status meanings below.

Use a short `Requirements` list near the table only when it makes the report
clearer. It is a readable projection of the ledger, not an admission artifact.
Never delay a report to construct aliases, hashes, receipts, or verbatim
registries.

| Rule | Behavior |
| --- | --- |
| Status vocabulary | In each status column, use only `NEW`, `IN PROGRESS`, `PAUSED`, `BLOCKED`, `CLOSED`. |
| Stage vocabulary | `normal` or `emergency` describes known lane state. Missing/stale stage metadata is a report-quality issue to reconcile, never a work gate. |
| Implementation Status | Covers exploration, RCA, design, code changes, code review, build checks, unit/component/integration auto-tests, and source-level readiness. `CLOSED` means source-level work is accepted with relevant automated checks. |
| Test Status | Covers E2E validation in the non-production test environment, including real devices, test services, UI manipulation, and mission/test-plan helpers. `CLOSED` means test-environment E2E passed or was explicitly waived. |
| Prod Status | Covers E2E validation in production, including deploy provenance, real production services/devices, UI manipulation where relevant, and user-visible behavior. `CLOSED` means production E2E passed or was explicitly waived. |
| Lane closure | A lane is finished only when the required highest environment column is `CLOSED`. For production-gated work, Implementation/Test `CLOSED` with Prod open is still not finished. |
| Evidence states | Put worker completions, reviews, source fixes, deploys, and partial proofs in `Next proof/action`, not by collapsing status columns. |
| RCA/fix closure | For bug/debug lanes, missing, failing, or not-runnable domain-required acceptance proof keeps RCA/fix open. Source approval may close Implementation only; wording must say source-only/progress, not fixed/closed. |
| `CLOSED` | Use only in the specific column whose required evidence is proven or explicitly removed from scope. |
| `PAUSED` | Use only when this lane's next required action is progress from another in-scope lane. No user input or decision is pending for this lane's next action. Name the dependency lane, impact, owner, and resume condition in `Blocker` or `Next proof/action`. If the dependency lane is `BLOCKED`, keep this lane `PAUSED` and mark the dependency lane `BLOCKED`. |
| `BLOCKED` | Use only when this lane cannot make any more progress until the user provides a named input or decision. Name the exact user input/decision, impact, owner (`user`), exact unblock action, and target artifact/path. Do not use `BLOCKED` for another lane's progress. |
| Coverage | Do not omit lanes because they are idle, waiting, paused, under review, deployment-only, or proof-only. |
| Lane requirement context | Use known readable context when available. Otherwise state `lineage unavailable—reconcile`; missing context never fails or delays the report. |

## Pressure Scenario

Under time pressure, classify by the lane's next required action. For example: "PAUSED on API-contract lane [requirement context: checkout contract]; impact: checkout validation cannot make progress; owner: API-contract lane; resume: lane 2 publishes docs/api-contract.md." Use `BLOCKED` only for a real user input: "BLOCKED on user decision: choose required API fields; impact: checkout validation cannot make further progress; owner: user; unblock: record the choice in docs/api-contract.md." If context is not yet known, say `lineage unavailable—reconcile` and report the next safe action.

## Common Failures

| Failure | Fix |
| --- | --- |
| Action log: "Read files, ran tests, asked agent." | Report resulting state: "Validation path is mapped; unit tests are the remaining gap." |
| Vague progress: "Made progress." | Name the changed state. |
| Decision without reason. | Add the tradeoff or constraint that drove it. |
| Blocker without actionable request. | Add stalled impact, owner, exact unblock action, and target artifact/path when applicable. |
| Verification implied. | Cite evidence or say "not verified yet". |
| Next focus is "continue". | Name the next concrete work area. |

## Checklist

| Check | Pass condition |
| --- | --- |
| State | One-line current state is clear. |
| Progress | Describes outcomes, not effort. |
| Decisions | Includes reason for chosen path. |
| Blockers/Risks | Includes impact, owner, exact unblock action, and target artifact/path when applicable. |
| Verification | Evidence is cited or absence is explicit. |
| Next Focus | Names the next concrete work area. |
| Concision | No raw activity log or filler. |
| Hierarchy | Parent/child work is shown as a tree or with `Task ID` + `Parent ID`; nested work is not flattened. |
| Task IDs | Existing task IDs use hierarchical form such as `1.3.2`. |
| Multi-lane coverage | Every in-scope lane is listed, including idle/waiting/review/deploy/proof/paused lanes. |
| Requirement context | Known context is readable and accurate. Missing context is labeled `lineage unavailable—reconcile`; it never fails or delays the report. |
| Lane statuses | Each Implementation/Test/Prod status is exactly `NEW`, `IN PROGRESS`, `PAUSED`, `BLOCKED`, or `CLOSED`. |
| PAUSED semantics | A lane waiting for progress from another in-scope lane, with no user input/decision pending, is labeled `PAUSED`, not `BLOCKED`. |
| BLOCKED semantics | A lane unable to make more progress until the user supplies a named input/decision is labeled `BLOCKED` with `owner=user` and an exact unblock action; dependency-only waiting is not `BLOCKED`. |
| Dependency propagation | If a dependency lane is `BLOCKED` on user input, the dependent lane remains `PAUSED` until its own next required action needs user input. |
| Status separation | Source-level completion, test E2E, and production E2E are never merged into one status. |
| Lane forecasts | Every active lane names a milestone, forecast deadline, recalibration, and critical-path treatment. Closed lanes record a completion timestamp and no active forecast deadline. Parallel child deadlines remain parallel under one critical-path deadline. |
