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
- In an active ECI/ATE workflow, every reported lane includes non-empty root-qualified `Lane requirement refs` and a nearby redacted-verbatim `Requirements` registry with each referenced ID's wording and source. Keep the full requirement chain in the current project-understanding ledger; report refs are not a substitute for graph edges.
- In a direct workflow with inactive ECI/ATE lineage, preserve direct-workflow behavior exactly: do not fabricate refs or a registry.
- Lineage-admission failures leave lane/task statuses unchanged. Report them as routing risks and next actions, never as `PAUSED`, `BLOCKED`, BRP, or a lifecycle phase.

## Multi-Lane Mission Status

For “where are we on each lane?” or “who works on each lane?”, report every in-scope lane known from the active plan, ledger, or test matrix. Include idle, waiting, review, deploy, proof, and paused lanes.

Use three separate status columns so source readiness cannot be mistaken for E2E completion.

When work is flat and has no task IDs, omit `Task ID` and `Parent ID`. In active ECI/ATE, keep `Lane` followed immediately by `Lane requirement refs`; in direct workflows, omit that lineage column and registry.

| Task ID | Parent ID | Lane | Lane requirement refs | Owner | Implementation Status | Test Status | Prod Status | Blocker | Next proof/action |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `1.3.2` or `none` | `1.3` or `none` | `<human-readable lane result wanted>` | `root-requirement-lineage-20260822::R1, root-requirement-lineage-20260822::R3` | `<person/agent or unowned>` | `NEW` / `IN PROGRESS` / `PAUSED` / `BLOCKED` / `CLOSED` | `NEW` / `IN PROGRESS` / `PAUSED` / `BLOCKED` / `CLOSED` | `NEW` / `IN PROGRESS` / `PAUSED` / `BLOCKED` / `CLOSED` | `none` or `PAUSED: <dependency lane; impact; owner; resume condition>` or `BLOCKED: <exact user input/decision; impact; owner: user; exact unblock action; target artifact/path>` | `<next evidence/action>` |

Place the redacted-verbatim `Requirements` registry near the active ECI/ATE table. Each referenced ID resolves to its root-qualified declaration, redacted-verbatim user wording, and source. The current project-understanding snapshot records, for each lane, `requirement → decision/reasoning step → parent/derived lane → executed assignment` with evidence for every edge; do not duplicate the graph in status columns.

### Redacted-verbatim Requirements registry

| Requirement ID | Redacted-verbatim user wording | Source |
| --- | --- | --- |
| root-requirement-lineage-20260822::R1 | “In ECI and ATE skills it is required to keep track of which exactly requirement led to a specific lane that we execute.” | direct user message |
| root-requirement-lineage-20260822::R3 | “Also make sure a lane requirement is reflected in writing-status-reports.” | direct user message |

| Rule | Behavior |
| --- | --- |
| Status vocabulary | In each status column, use only `NEW`, `IN PROGRESS`, `PAUSED`, `BLOCKED`, `CLOSED`. |
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
| Lane requirement refs | In active ECI/ATE, every reported lane has non-empty root-qualified refs that resolve to the nearby redacted-verbatim registry; unresolved or empty refs fail the report. Direct workflows do not fabricate refs or a registry. |
| Lineage admission | A failed admission is a routing risk/next action with unchanged statuses, never `PAUSED`, `BLOCKED`, BRP, or a lifecycle phase. |

## Pressure Scenario

Under time pressure, classify by the lane's next required action. In active ECI/ATE, use: "PAUSED on API-contract lane [Lane requirement refs: root-requirement-lineage-20260822::R1]; impact: checkout validation cannot make progress; owner: API-contract lane; resume: lane 2 publishes docs/api-contract.md." Use `BLOCKED` only for user input: "BLOCKED on user decision [Lane requirement refs: root-requirement-lineage-20260822::R1]: choose required API fields; impact: checkout validation cannot make further progress; owner: user; unblock: record the choice in docs/api-contract.md." In a direct workflow, omit the refs and registry.

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
| Requirement traceability | Active ECI/ATE lane rows have non-empty root-qualified refs, and the nearby redacted-verbatim registry contains wording and source for every referenced ID; direct workflows have neither fabricated refs nor a registry. |
| Lineage failure semantics | Admission failures leave statuses unchanged and are reported as routing risks/next actions, not `PAUSED`, `BLOCKED`, BRP, or lifecycle phases. |
| Lane statuses | Each Implementation/Test/Prod status is exactly `NEW`, `IN PROGRESS`, `PAUSED`, `BLOCKED`, or `CLOSED`. |
| PAUSED semantics | A lane waiting for progress from another in-scope lane, with no user input/decision pending, is labeled `PAUSED`, not `BLOCKED`. |
| BLOCKED semantics | A lane unable to make more progress until the user supplies a named input/decision is labeled `BLOCKED` with `owner=user` and an exact unblock action; dependency-only waiting is not `BLOCKED`. |
| Dependency propagation | If a dependency lane is `BLOCKED` on user input, the dependent lane remains `PAUSED` until its own next required action needs user input. |
| Status separation | Source-level completion, test E2E, and production E2E are never merged into one status. |
