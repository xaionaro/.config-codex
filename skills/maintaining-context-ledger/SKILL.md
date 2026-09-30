---
name: maintaining-context-ledger
description: Use when writing or verifying project-understanding ledgers, context ledgers, ECI/ATE session ledgers, handoff context, or stop-hook ledger updates — keeps the ledger a current-state snapshot and the high-level log an append-only history, side by side
---

# Maintaining Context Ledgers

Three required records and one audit-only history, side by side:

| File | Role | Edit mode |
|------|------|-----------|
| `project-understanding.md` (the ledger) | Current-state snapshot | Rewrite in place; stale entries deleted |
| `high_level_log.md` (the log) | Append-only history of every material change | Append only; never edit, never delete past entries |
| `latest-status-report.md` (the report) | Latest status report per `writing-status-reports` | Patch only stale or changed lines or sections; preserve unaffected text. Write the whole file only on first creation. |
| `forecast-target-history.tsv` | Audit-only root-task forecast-target history | Append only; corrections add a new target row |

The ledger answers what is true now. The log answers what happened, in order, and why we believe what is now in the ledger. The report answers the most recent status update, ready to relay to the user without recomputation. They are not redundant: the ledger has no history; the log has no synthesis; the report has no detail beyond the status-report categories.

## Core Rule

A fresh agent reading only the ledger, without transcript or memory, must reach the same current understanding you have. Record every project/task detail that could affect planning, implementation, risk handling, assignment, command choice, verification, or the final answer.

Err on exhaustive useful detail for current state. Do not omit a detail because it seems obvious from transcript, local state, prior agent memory, or project familiarity. Equally, do not retain a detail because it was true earlier. Exhaustive on current state; zero on superseded state.

For ECI, record `Stage: normal`. Track main and fast progress under the same task: owners, provisional evidence, current ECI decision, and needed adaptation. [ECI fast path](../explore-critique-implement/references/fast-path.md) defines their relationship; these are paths, not separate stages or automatic lanes. Reconcile missing or stale metadata alongside safe work; records never grant permission.

For material ECI work, keep `exact user source → faithful requested outcome →
bounded scope` as readable context. A repair stays in its lane when it is
necessary to meet or prove that outcome. A separate-outcome concern is only a
post-ECI observation or follow-up, never current lane, assignment, code change,
review, deadline, forecast, or proof program. Reconcile missing or stale
lineage alongside known work; do not block it.

Ground each progress item in `high_level_log.md` and `latest-status-report.md` in a
named or linked user-stated requirement. Explain how the change advances or
verifies the requested outcome; for a blocker, state its effect on that outcome.
For supporting work, state what it enables and whether the requested outcome
remains open.

Example: ‘The test harness now exercises the requested production behavior,
making the fix verifiable; the production fix remains open.’

## Storage

For ECI/ATE, these records live at:

```text
~/.cache/codex-proof/$SESSION_ID/project-understanding.md   # the ledger
~/.cache/codex-proof/$SESSION_ID/high_level_log.md          # the log
~/.cache/codex-proof/$SESSION_ID/latest-status-report.md    # the report
~/.cache/codex-proof/$SESSION_ID/forecast-target-history.tsv # target history
```

Do not store any of these files in the project/repo. The Codex stop hook only deletes named scratch files (`proof.md`, `instructions.md`, `baseline_head`); session-snapshot pruning ignores directories younger than 30 days. The ledger, report, and target history survive across stops by construction; do not place them under any other name.

Create the three required files once. Create `forecast-target-history.tsv` with its header at the first `none → A` transition. Then follow each file's edit mode above; never delete or recreate.

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

Treat bytes already present in `high_level_log.md` as immutable; permit only
an EOF append to that same canonical file. Never follow a symlink alias.

Use the command shown below from the bound CWD only when the selected-session
log exists at its canonical path as a regular non-symlink file with link count
1, and the active direct marker is already bound to the current session and
CWD as a regular non-symlink file with link count 1. These checks avoid the
CLI's missing-log bootstrap and replacement of multiply-linked log or marker
pathnames. If either check fails, do not invoke it until the target is
resolved. The command attempts to initialize or refresh `high_level_log.anchor`;
the CLI may continue after an anchor refresh failure.

A missing established log is unresolved history; recover its prior contents
before appending. A missing or stale anchor is separate metadata from the log.

Suggested invocation:

```sh
"$HOME/.codex/bin/eci-active" ledger-append 'Library choice changed from X to Y; reason: <reason>; evidence: <source or command output>; agent/turn: <runtime name / role, turn>.'
```

## Latest Status Report

`latest-status-report.md` holds the single most recent status report, written per the `writing-status-reports` skill. It is the handoff snapshot the next agent or user reads first.

| Rule | Detail |
|------|--------|
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
| False current scope | Correct the ledger/status and append the correction to the log. Cancel or reassign only unrooted current work; do not destructively revert already-made work without user direction. |
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

### Lane forecasts

A lane is an independently advancing workstream, not an ECI step. Serial implement→review→repair→review→implement stays one lane with one critical path. Create distinct lanes only for independently advancing work with separate ownership or synchronization.

Under `Progress`, store these fields in structured form in `project-understanding.md`. Progress is the source of truth; `latest-status-report.md` projects these fields using `writing-status-reports`.

#### Forecast outcome wording

Write every lane and root forecast `Outcome` as a completed result in plain language: name the affected behavior or artifact and what will work or be delivered. The description must be understandable without a `Lane` heading, `Next milestone`, or transcript. Bare labels such as `UNPRICES` or `WITHDRAWN`, opaque identifiers, and vague phrases such as `forecast cleanup` are insufficient. Retain domain terms when the surrounding words explain the delivered result.

Example: `Outcome: Import validation that identifies unpriced records and explains how to correct them.`

**Project-understanding ledger storage**

- Next milestone: `<named outcome>`
- Forecast deadline:
  - Outcome: `<named lane/task outcome>`
  - Target: `<UTC ISO8601>`
- Root completion forecast, when an active root outcome is not represented by lane reports:
  - Outcome: `<full named active root-task outcome>`
  - Target: `<UTC ISO8601>`
- Forecast recalibration, when a forecast changes:
  - Prior: `<UTC ISO8601>`
  - Current: `<UTC ISO8601>`
  - Why moved: `<why>`
  - Evidence: `<evidence>`
- Initial forecast:
  - Status: `unchanged`
  - Baseline: `<UTC ISO8601>`
  - Evidence: `<evidence>`
- Dependencies / critical path:
  - Dependency: `<none or named dependency>`
  - Owner: `<owner, if applicable>`
  - Resume condition: `<condition, if applicable>`
  - Critical path: `<single critical path>`
- A `CLOSED` lane records:
  - Completed: `<UTC ISO8601>`
  - Forecast deadline: `inactive`
  - Recalibration: `none`

Every non-`CLOSED` lane records its next milestone and named forecast outcome with target. For each unrepresented active root-task outcome omitted by lane reports, record one root completion forecast with the full root outcome and target. Root completion is not a child sum or stage.

When a lane or root forecast changes, restate its current outcome and target fields, then record the prior target, current target, reason, and evidence. For an initial forecast, record `unchanged`, its baseline, and evidence. A `CLOSED` lane has no active deadline or recalibration.

#### ECI scenario forecasts

For ECI forecasts, including nested ECI, store a base case and each material
evidence-supported downside scenario alongside the canonical target:

- Base case: completion UTC for the remaining authorized in-scope work on the
  current critical path, assuming no listed downside scenario. Add no generic
  buffer.
- Scenario: include only material, evidence-supported downside scenarios that
  affect or delay completion of the requested ECI outcome. For each, record the
  name; trigger/evidence; affected work or dependency; added duration or
  supported range and its basis; resulting endpoint or endpoint range.
- Record supported co-occurring delays as combinations only when they can occur
  sequentially on the same path. List mutually exclusive scenarios separately;
  count overlapping delay once. For root forecasts, use the latest required
  parallel lane/dependency endpoint, not a sum of parallel work.
- The single UTC target is the latest endpoint among the base case and bounded,
  evidence-supported scenarios. Keep each scenario's endpoint/range in the
  ledger. A material risk without a finite duration basis is `unknown/unbounded`:
  give it no fabricated endpoint, and do not call the target an absolute worst
  case.
- `Initial forecast.Baseline` remains the original forecast target; it is not
  the scenario base-case endpoint.

Forecast scenarios describe planning uncertainty only. They do not change
scope, priority, blocker status, or forecast authority.

**Report-only projection examples — not ledger storage**

In a material changed-state report, emit each canonical forecast line once. Keep these lines as report-only examples; do not store them as flat ledger entries.

- Next milestone: `Next milestone: <named outcome>`
- Forecast deadline: `Forecast deadline: <named lane/task outcome> will be finished by <UTC ISO8601>.`
- Root completion forecast: `Root completion forecast: <named active root-task outcome> will be finished by <UTC ISO8601>.`
- Changed forecast: `Forecast recalibration: <prior UTC ISO8601> → <current UTC ISO8601>; why moved: <why>; supporting evidence: <evidence>.`
- Initial forecast evidence: `Forecast recalibration: unchanged — baseline <UTC ISO8601>; supporting evidence: <evidence>.`
- Dependencies / critical path: `Dependencies / critical path: <none, named dependency + owner/resume, or critical path>`
- `CLOSED` lane: `Completed: <UTC ISO8601>; no active forecast deadline.`

Every non-`CLOSED` lane names its next milestone and canonical forecast line in the report. For each unrepresented active root-task outcome omitted by lane reports, include the standalone root completion line once. The forecast line itself names the finished outcome using the [forecast outcome wording](#forecast-outcome-wording); a separate `Lane` or `Next milestone` does not substitute, and it never names a critic, reviewer, actor, or stage. Root completion is full root completion, not a child sum or stage.

For a changed lane or root forecast, restate its current canonical line in the same report, then record `Forecast recalibration: <prior UTC ISO8601> → <current UTC ISO8601>; why moved: <why>; supporting evidence: <evidence>.`

A `CLOSED` lane records `Completed: <UTC ISO8601>; no active forecast deadline.` Do not invent or revive a forecast deadline or recalibration. For an initial forecast, write `Forecast recalibration: unchanged — baseline <UTC ISO8601>; supporting evidence: <evidence>.`

State dependencies and parallel work. For parallel children, report the single critical-path deadline; child deadlines remain parallel; never add or sum parallel child deadlines into a parent, root, or mission deadline.

Forecasts are advisory. They never gate work, grant or deny permissions, require artifacts or receipts, create blockers, require parsers, or require per-command ceremony. Missing or stale forecasts are planning-quality defects. Reconcile them alongside safe work without delaying the update.

Coordinator-to-user updates retain the exact standalone lines defined by the ECI coordinator module.

### Forecast target history

`forecast-target-history.tsv` is the canonical audit-only history for root-task forecast targets. It has exactly four columns:

```text
added_utc	root_task_id	new_target_utc	reason
```

Every row records the UTC addition time, root task ID, new UTC target, and a concise human-readable reason for setting or changing the target. Append only: never edit, delete, reorder, or reuse a row.

| Target transition | `high_level_log.md` | `forecast-target-history.tsv` |
| --- | --- | --- |
| none → A | Append a material `high_level_log.md` entry naming A, why, and evidence. | Append A row with reason. |
| A → B | Append a material `high_level_log.md` entry naming prior A, new B, why, and evidence. | Append B row with reason. |
| A → A | No high-level-log entry or history row for mere reaffirmation. | No row. |
| close | Record material completion normally. | No date row. |
| correction | Append a correction naming the prior entry and corrected target. | Append the corrected-target row with reason; never rewrite earlier rows. |

This history is audit-only. It never gates work, grants or denies permission, creates a blocker, or delays ordinary work. It is not a required session record or work prerequisite. Reconcile a missing, stale, or malformed history alongside ordinary work.

## Structure

The ledger is always structured. Reject free-form prose, wall-of-text, and chat-style narration.

- Put every fact under a heading whose subject covers it.
- Keep sections scannable with tables, bullet lists, or short labeled lines
  (`Owner: ...`, `Status: ...`, `Evidence: ...`).
- Keep factual non-table content concise and one fact per bullet, labeled line, or short prose sentence. For a longer point, use a concise parent bullet with supporting facts in nested one-fact bullets or labeled fields.
- Keep each table row to one fact. Keep cells concise. When a cell needs detail, use a short summary and a rendered Markdown link to the matching, populated heading below. The summary and link refer to the same row fact; the linked heading expands it as bullets or labeled fields.
- Keep each bullet, labeled line, and table row to one fact.
- Avoid multi-paragraph essays.
- Prefer tables for more than two parallel items.

Include a rendered, unfenced Markdown example with matching populated details:

| Decision |
|----------|
| Use X. [Rationale and impact](#decision-details). |

### Decision details

- Reason: `<reason>`.
- Consequence: `<consequence>`.

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

Every material ledger refresh applies the same-update recalibration rule to
each affected changed lane or root forecast.

Answer the user before ledger maintenance or coordination when a response is due.
After a material event, update `project-understanding.md`, append its change to
`high_level_log.md`, and refresh `latest-status-report.md` before dispatching work,
sending coordination messages, or taking the next project action. Already-running
independent jobs continue; launch ready work after recording the event. This orders
coordinator work without adding permission gates, receipts, or per-command checks.

Three-pass ledger edit, in order:

1. Stale pass. Re-read each section; for every line ask: still current? No -> delete or rewrite.
2. Omission pass. Add what is missing, checking authoritative sources, user instructions, current diffs/state, and this turn's agent reports.
3. Fit pass. Re-read the section list itself. Rename, split, merge, add, or drop sections so headings match the current work.

Structure must evolve with the project. A frozen schema that no longer fits is defective. A purely additive diff to the ledger is a log-into-ledger defect: rewrite in place.

Then append to `high_level_log.md` one entry per material change made this turn. Every passed-around fact the stale pass deleted or rewrote becomes a log entry.

Finally refresh `latest-status-report.md` using the edit mode above and the format in `writing-status-reports`; reflect the updated ledger. Skip only when this turn produced no ledger or log change.

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
- A longer factual non-table item (including a bullet, labeled value, or prose paragraph) is compressed into a one-line point instead of one-fact items, with nested bullets for supporting detail when needed.
- A table cell contains long detail instead of a concise TLDR linked to matching populated structured detail below, or its reference target is missing, broken, empty, unrelated, or unstructured.
- An active lane lacks its next milestone or named forecast outcome and target in `Lane forecasts`; an affected active lane lacks nested prior/current/why/evidence recalibration fields; or a changed lane/root lacks its restated current canonical line plus recalibration in the report projection.
- An unrepresented active root-task outcome omitted by lane reports lacks a full outcome and target record in `Root completion forecast`.
- A `CLOSED` lane lacks completion UTC or inactive-deadline status, including `Completed: <UTC ISO8601>; no active forecast deadline.` in the report projection, or retains a forecast deadline/recalibration.
This is a planning-quality defect: reconcile it alongside safe work without delaying the update.
- Headings no longer fit the content.
- The high-level log is missing, was edited or truncated in place, lacks entries for ledger changes made this session, or duplicates the ledger's current-state synthesis.
- The latest status report is missing, lacks a UTC timestamp, predates the last ledger update, fails `writing-status-reports` coverage (state, progress, decisions, blockers/risks, verification, next focus), or duplicates ledger structure instead of summarizing changed state.
- Secrets, credentials, or unnecessary personal data are recorded.
