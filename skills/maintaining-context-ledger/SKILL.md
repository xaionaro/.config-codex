---
name: maintaining-context-ledger
description: Use when writing or verifying project-understanding ledgers, context ledgers, ECI/ATE session ledgers, handoff context, or stop-hook ledger updates
---

# Maintaining Context Ledgers

A context ledger preserves current project understanding for safe resumption. It is not an activity log, transcript summary, proof bundle, or report archive.

## Core Rule

A fresh agent should be able to resume accurately from the ledger without transcript access. Record every known project/task detail that could affect planning, implementation, risk handling, assignment, command choice, verification, or the final answer.

Err on exhaustive useful detail. Do not omit a detail because it seems obvious from the transcript, local state, prior agent memory, or project familiarity.

## Storage

For ECI/ATE, write the ledger at:

```text
~/.cache/codex-proof/$SESSION_ID/project-understanding.md
```

Do not store the ECI/ATE ledger in the project/repo.

## Current State, Not History

| Case | Ledger Action |
|------|---------------|
| Mutable fact changes | Replace stale value with latest state by subject |
| Old state explains a binding constraint, user correction, or future hazard | Keep only the needed history and why it matters |
| Large step finishes | Record verdict, resulting state, report/evidence link, remaining gaps |
| Detailed report exists elsewhere | Link it; do not copy report body, substeps, transcripts, or verification bullet lists |
| User corrects an agent mistake | Record corrected fact/rule, affected current state, recurrence guard, and source/correction link |

Do not keep blow-by-blow mistake or activity history unless it prevents a likely recurrence.

## Suggested Shape

Use headings that fit the work. This pseudo-schema is a floor, not a fixed form:

| Field | Purpose |
|-------|---------|
| Sources | Authoritative inputs and what each governs |
| Goal | Desired outcome, reason, scope boundaries |
| Requirements | Binding conditions, acceptance criteria, source refs, current status |
| Context | Domain model, terminology, relevant locations, relationships |
| Decisions | Choices made, rationale, tradeoffs, consequences |
| Corrections | User-corrected agent mistakes and recurrence guards |
| Unknowns | Assumptions, risks, blockers, open questions, validation needed |
| Progress | Current work state, owners, completed milestones with report links, WIP, next action |
| Verification | How completion will be proven, evidence links, current verdicts, missing proof |

Keep the project's own vocabulary, names, identifiers, and source wording when they are binding. Do not flatten specifics into generic labels.

## Update Points

Update before work starts, after material state changes, after material findings/decisions/agreements, after milestones, after user corrections, before QA/verdicts, before user-waiting stops, and before shutdown.

After each update, run an omission pass against authoritative sources, current user instructions, current diffs/state, and agent reports available this turn.

## Invalid Ledger

Reject the ledger if:

- A fresh agent needs the transcript or unstated local memory to recover useful current project/task facts.
- An authoritative source is named without extracting its relevant current-state details.
- Binding requirements, acceptance criteria, user corrections, assumptions, risks, decisions, current state, or evidence are missing.
- Claims cannot be traced to sources, reports, commands, logs, screenshots, or commits.
- Obsolete states are retained as if current.
- Activity logs or copied report bodies replace current-state summaries and links.
- Secrets, credentials, or unnecessary personal data are recorded.
