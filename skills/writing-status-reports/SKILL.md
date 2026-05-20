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
| Blockers/Risks | Impact plus needed owner/input. |
| Verification | Tests, commands, observed behavior, or "not verified yet". |
| Next Focus | Next concrete work area, not "continue". |

Progress reports changed state and completed outcomes, not files read, commands run, or agents contacted unless those actions are verification evidence.

## Format Rules

- Keep updates short: one tight paragraph or relevant coverage categories as bullets.
- Lead with state, then include only categories that changed or matter now.
- Name exact affected area, requirement, command, file, or decision when relevant.
- Use "not verified yet" instead of implying unrun checks passed.
- For blockers and risks, state impact and the needed owner/input.

## Multi-Lane Mission Status

For “where are we on each lane?” or “who works on each lane?”, report every in-scope lane known from the active plan, ledger, or test matrix. Include idle, waiting, review, deploy, proof, and paused lanes.

| Lane | Status | Owner | Blocker | Next proof/action |
| --- | --- | --- | --- | --- |
| `<lane result wanted>` | `NEW` / `IN PROGRESS` / `BLOCKED` / `CLOSED` | `<person/agent or unowned>` | `none` or `<exact blocker; impact; unblock owner/path>` | `<next evidence/action>` |

| Rule | Behavior |
| --- | --- |
| Status vocabulary | Use only `NEW`, `IN PROGRESS`, `BLOCKED`, `CLOSED`. |
| Evidence states | Put worker completions, reviews, source fixes, deploys, and partial proofs in `Next proof/action`, not `Status`. |
| `CLOSED` | Use only when the lane result is proven or explicitly removed from scope. |
| `BLOCKED` | Name exact blocker, stalled impact, and unblock owner/path. |
| Coverage | Do not omit lanes because they are idle, waiting, paused, under review, deployment-only, or proof-only. |

## Pressure Scenario

Under time pressure, do not write "blocked on review" or "risk in tests" alone. Write impact plus owner/input: "Blocked on API contract review; checkout validation may be wrong until Alex confirms required fields."

## Common Failures

| Failure | Fix |
| --- | --- |
| Action log: "Read files, ran tests, asked agent." | Report resulting state: "Validation path is mapped; unit tests are the remaining gap." |
| Vague progress: "Made progress." | Name the changed state. |
| Decision without reason. | Add the tradeoff or constraint that drove it. |
| Blocker without impact or owner. | Add what is stalled and whose input is needed. |
| Verification implied. | Cite evidence or say "not verified yet". |
| Next focus is "continue". | Name the next concrete work area. |

## Checklist

| Check | Pass condition |
| --- | --- |
| State | One-line current state is clear. |
| Progress | Describes outcomes, not effort. |
| Decisions | Includes reason for chosen path. |
| Blockers/Risks | Includes impact and needed owner/input. |
| Verification | Evidence is cited or absence is explicit. |
| Next Focus | Names the next concrete work area. |
| Concision | No raw activity log or filler. |
| Multi-lane coverage | Every in-scope lane is listed, including idle/waiting/review/deploy/proof/paused lanes. |
| Lane statuses | Each lane status is exactly `NEW`, `IN PROGRESS`, `BLOCKED`, or `CLOSED`. |
