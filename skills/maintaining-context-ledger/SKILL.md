---
name: maintaining-context-ledger
description: Use when writing or verifying project-understanding ledgers, context ledgers, ECI/ATE session ledgers, handoff context, or stop-hook ledger updates — keeps the ledger a current-state snapshot and the high-level log an append-only history, side by side
---

# Maintaining Context Ledgers

Three files, side by side, all required:

| File | Role | Edit mode |
|------|------|-----------|
| `project-understanding.md` (the ledger) | Current-state snapshot | Rewrite in place; stale entries deleted |
| `high_level_log.md` (the log) | Append-only history of every material change | Append only; never edit, never delete past entries |
| `latest-status-report.md` (the report) | Latest status report per `writing-status-reports` | Overwrite in place each refresh |

The ledger answers what is true now. The log answers what happened, in order, and why we believe what is now in the ledger. The report answers the most recent status update, ready to relay to the user without recomputation. They are not redundant: the ledger has no history; the log has no synthesis; the report has no detail beyond the status-report categories.

## Core Rule

A fresh agent reading only the ledger, without transcript or memory, must reach the same current understanding you have. Record every project/task detail that could affect planning, implementation, risk handling, assignment, command choice, verification, or the final answer.

Err on exhaustive useful detail for current state. Do not omit a detail because it seems obvious from transcript, local state, prior agent memory, or project familiarity. Equally, do not retain a detail because it was true earlier. Exhaustive on current state; zero on superseded state.

## Storage

For ECI/ATE, all three files live at:

```text
~/.cache/codex-proof/$SESSION_ID/project-understanding.md   # the ledger
~/.cache/codex-proof/$SESSION_ID/high_level_log.md          # the log
~/.cache/codex-proof/$SESSION_ID/latest-status-report.md    # the report
```

Do not store any of these files in the project/repo. The Codex stop hook only deletes named scratch files (`proof.md`, `instructions.md`, `baseline_head`); session-snapshot pruning ignores directories younger than 30 days. Both the ledger and the report survive across stops by construction; do not place them under any other name.

Create each file once; then update in place. Never delete/recreate.

## High-Level Log

Append-only history. Every material change recorded in the ledger gets a corresponding entry appended to the log in the same turn.

| Rule | Detail |
|------|--------|
| Append only | Never edit, reorder, or delete past entries. Wrong entries are corrected by a new appended entry referencing the prior one. |
| Material essence | Lead with what is true now, what to do next, why it matters, and evidence. Add changed-state context or provenance when it explains a material change. |
| Reflect all details | Capture the change, prior state, new state, reason, source/evidence, and agent/turn. |
| Chronological | Newest entries at the bottom. Each entry leads with a UTC timestamp. |
| Same-turn pairing | Every ledger update has at least one log entry from that turn. A ledger diff with no log append is defective. |
| No synthesis | The log records what changed; it does not duplicate the ledger's current-state synthesis. Cross-reference by section/heading instead. |

Suggested entry shape:

```text
## 2026-05-08T14:22Z - Decisions / library choice
- Was: undecided between X and Y.
- Now: chose Y.
- Why: <reason, in one sentence>.
- Evidence: <commit | report path | command output reference>.
- Agent: <runtime name / role>.
```

## Latest Status Report

`latest-status-report.md` holds the single most recent status report, written per the `writing-status-reports` skill. It is the handoff snapshot the next agent or user reads first.

| Rule | Detail |
|------|--------|
| One file, overwrite | Each refresh overwrites content in place. No history kept here: that is the log's job. |
| Same skill, same format | Content follows `writing-status-reports`: state, progress, decisions, blockers/risks, verification, next focus; multi-lane table when applicable. |
| Lead with UTC timestamp | First line: `# Status - <UTC ISO8601>`. Stale reports without a timestamp are rejected. |
| Refresh triggers | After every ledger update, after every material change, before user-waiting stops, before shutdown, and whenever the user asks for status. |
| No copying the ledger | Report changed state plus next focus; do not duplicate ledger structure. Cross-reference instead. |

A ledger update without a matching report refresh is a defect, same as a missing log append.

## Current State, Not History

| Case | Ledger Action |
|------|---------------|
| Mutable fact changes | Replace value in place; never append beside old |
| Hypothesis disproved, plan abandoned, decision reversed | Delete the obsolete entry; keep only the surviving conclusion |
| Old state explains a binding constraint or hazard | Keep only the needed history and why it still matters |
| Step finishes | Record verdict + resulting state + evidence link; drop the in-progress entry |
| Detailed report exists elsewhere | Link it; do not copy report body, substeps, transcripts, or bullet lists |
| Correction changes current understanding | Record the surviving fact, affected state, recurrence guard when useful, and source/evidence. For reaffirmed existing facts, use the `Existing ledger fact reaffirmed before action changes state` routing row. |
| Task/blocker resolved | Move to completed milestones with link, or delete |

Skip blow-by-blow history unless it prevents recurrence.

### Log vs Ledger

A given fact lives in one file, not both. Route by edit mode:

| Content | Ledger | Log |
|---|---|---|
| "14:22 - tried A, failed" | - | append |
| "Considered X, chose Y because..." | "Using Y. Why: <reason>." | append the consideration + decision event |
| "Thought bug was in M, found in N" | "Bug: N. Fix: <link>." | append the M->N correction event |
| "Step 1 done. Step 2 done. Step 3 WIP." | "Current: step 3 - <state>. Done: 1, 2 (links)." | append each step transition |
| Narrative of what each agent did | Current owner + last verdict + next action | append per-agent action when it produced a material change |
| Existing ledger fact reaffirmed before action changes state | keep existing current fact | keep log as-is for pure reaffirmation; append material planning, risk, ownership, authority, or verification change |

Per-ledger-line test: true and load-bearing right now? No -> drop from ledger; if it captures something material that happened, append to the log instead.

## Structure

The ledger is always structured. Free-form prose, wall-of-text, and chat-style narration are rejected. Every fact lives under a heading whose subject covers it. Every section is scannable: table, bullet list, or short labeled lines (`Owner: ...`, `Status: ...`, `Evidence: ...`). No multi-paragraph essays. No long one-liners: split multi-clause bullets, semicolon chains, and "and"-joined run-ons into sub-bullets, labeled lines, or table rows. One fact per line. Prefer tables for more than two parallel items.

Choose headings that fit the project. The agent decides section set, names, and order. This example is a starting template, not a fixed schema:

| Example section | Purpose |
|---------|---------|
| Sources | Authoritative inputs and what each governs |
| Goal | Desired outcome, reason, scope boundaries |
| Requirements | Binding conditions, acceptance criteria, source refs, current status |
| Context | Domain model, terminology, relevant locations, relationships |
| Decisions | Choices made, rationale, tradeoffs, consequences |
| Guards | Material current-understanding changes, binding requirement updates, and useful recurrence guards |
| Unknowns | Assumptions, risks, blockers, open questions, validation needed |
| Progress | Current work state, owners, completed milestones with report links, WIP, next action |
| Verification | How completion will be proven, evidence links, current verdicts, missing proof |

Use `### <subject>` subsections when a section grows large enough that a fresh agent would have to scan to find a fact. Keep the project's own vocabulary, names, identifiers, and source wording when binding. Do not flatten specifics into generic labels.

## Update Points

Update before work starts, after material state changes, after material findings/decisions/agreements, after milestones, after material user input that changes current understanding, binding requirements, risks, decisions, or useful recurrence guards, before QA/verdicts, before user-waiting stops, and before shutdown.

When independent jobs are ready, launch them first. Update the ledger/log while they run. Documentation must not block parallel work.

Three-pass ledger edit, in order:

1. Stale pass. Re-read each section; for every line ask: still current? No -> delete or rewrite.
2. Omission pass. Add what is missing, checking authoritative sources, user instructions, current diffs/state, and this turn's agent reports.
3. Fit pass. Re-read the section list itself. Rename, split, merge, add, or drop sections so headings match the current work.

Structure must evolve with the project. A frozen schema that no longer fits is defective. A purely additive diff to the ledger is a log-into-ledger defect: rewrite in place.

Then append to `high_level_log.md` one entry per material change made this turn. Every passed-around fact the stale pass deleted or rewrote becomes a log entry.

Finally refresh `latest-status-report.md` in place with a fresh status report (per `writing-status-reports`) reflecting the just-updated ledger. Skip only when this turn produced no ledger or log change.

## Invalid Ledger

Reject the ledger if any holds:

- A fresh agent needs the transcript or unstated local memory to recover useful current project/task facts.
- An authoritative source is named without extracting its relevant current-state details.
- Binding requirements, acceptance criteria, material current-understanding corrections, useful recurrence guards, assumptions, risks, decisions, current state, or evidence are missing.
- Claims cannot be traced to sources, reports, commands, logs, screenshots, or commits.
- Obsolete states are retained as if current: stale plans, abandoned hypotheses, finished WIP, resolved blockers, superseded values.
- Entries are timestamped narrative or chronological "what happened next" prose, i.e. log-style.
- Multiple values for the same fact coexist instead of one current value.
- Activity logs or copied report bodies replace current-state summaries and links.
- The latest update is purely additive while sections that should have changed were left untouched.
- Facts are dumped as free-form prose instead of placed under a fitting heading.
- A section runs as multi-paragraph narrative where a table, bullet list, or labeled lines would scan.
- A line packs multiple facts into a long bullet or run-on sentence.
- Headings no longer fit the content.
- The high-level log is missing, was edited or truncated in place, lacks entries for ledger changes made this session, or duplicates the ledger's current-state synthesis.
- The latest status report is missing, lacks a UTC timestamp, predates the last ledger update, fails `writing-status-reports` coverage (state, progress, decisions, blockers/risks, verification, next focus), or duplicates ledger structure instead of summarizing changed state.
- Secrets, credentials, or unnecessary personal data are recorded.
