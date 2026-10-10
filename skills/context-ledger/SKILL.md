---
name: context-ledger
description: Use when writing or verifying project-understanding ledgers, context ledgers, ECI/ATE session ledgers, handoff context, or stop-hook ledger updates — keeps the ledger a current-state snapshot and the high-level log an append-only history, side by side
---

# Context Ledger

Three required records, one conditional current forecast record, and one audit-only history:

| File | Role | Edit mode |
|------|------|-----------|
| `project-understanding.yaml` (the ledger) | Current project/task records and forecast locators | Selective native YAML edits; stale records deleted |
| `high_level_log.jsonl` (the log) | Append-only history of every material change | Append only; never edit, never delete past entries |
| `forecasts.md` | Sole current source for lane/root forecast records; create when a forecast first applies | Update current records in place; never copy their values into the ledger |
| `latest-status-report.md` (the report) | Latest user-facing status projection per `writing-status-reports` | Patch only stale or changed lines or sections; preserve unaffected text. Write the whole file only on first creation. |
| `forecast-target-history.tsv` | Audit-only root-task forecast-target history | Append only; corrections add a new target row |

The ledger answers what is true about the project and task now. `forecasts.md` answers what the current forecasts are. The log answers what changed, in order, and why. The report projects the latest state for the user; it is not another source of truth. The TSV audits root-target transitions and does not define current forecast state.

## Core Rule

A fresh agent reading the ledger and its `forecasts.md` locators, without transcript or memory, must reach the same current understanding you have. Record every project/task fact that could affect planning, implementation, risk handling, assignment, command choice, verification, or the final answer.

Keep current project/task facts in `project-understanding.yaml` and current forecast values in `forecasts.md`. The ledger may link to forecast records but never copy their targets, baselines, recalibrations, base-case/downside estimates, scenario ranges, forecast statuses, or endpoints. Binding user deadlines and actual completion timestamps are project facts and may remain in the ledger where useful; estimated completion dates belong only in `forecasts.md`.

Err on exhaustive useful detail for current state. Do not omit a detail because it seems obvious from transcript, local state, prior agent memory, or project familiarity. Equally, do not retain a detail because it was true earlier. Exhaustive on current state; zero on superseded state.

For ECI, record stage `normal` as a context fact. Track main and fast progress under the same task: owners, provisional evidence, current ECI decision, and needed adaptation. [ECI fast path](../explore-critique-implement/references/fast-path.md) defines their relationship; these are paths, not separate stages or automatic lanes. Reconcile missing or stale metadata alongside safe work; records never grant permission.

For material ECI work, keep `exact user source → faithful requested outcome →
bounded scope` as readable context. A repair stays in its lane when it is
necessary to meet or prove that outcome. A separate-outcome concern is only a
post-ECI observation or follow-up, never current lane, assignment, code change,
review, deadline, forecast, or proof program. Reconcile missing or stale
lineage alongside known work; do not block it.

Ground each progress item in `high_level_log.jsonl` and `latest-status-report.md` in a
named or linked user-stated requirement. Explain how the change advances or
verifies the requested outcome; for a blocker, state its effect on that outcome.
For supporting work, state what it enables and whether the requested outcome
remains open.

Example: ‘The test harness now exercises the requested production behavior,
making the fix verifiable; the production fix remains open.’

## Storage

For ECI/ATE, these records live at:

```text
~/.cache/codex-proof/$SESSION_ID/project-understanding.yaml   # the ledger
~/.cache/codex-proof/$SESSION_ID/high_level_log.jsonl          # the log
~/.cache/codex-proof/$SESSION_ID/forecasts.md                # current forecasts, when applicable
~/.cache/codex-proof/$SESSION_ID/latest-status-report.md    # the report
~/.cache/codex-proof/$SESSION_ID/forecast-target-history.tsv # target history
```

Do not store any of these files in the project/repo. The Codex stop hook only deletes named scratch files (`proof.md`, `instructions.md`, `baseline_head`); session-snapshot pruning ignores directories younger than 30 days. The ledger, report, forecasts, and target history survive across stops by construction; do not place them under any other name.

Create `project-understanding.yaml`, `high_level_log.jsonl`, and `latest-status-report.md` once. Create `forecasts.md` once when the first forecast applies, then update current records in place. Create `forecast-target-history.tsv` with its header at the first `none → A` transition. Follow each file's edit mode above; never delete or recreate these records.

The only canonical understanding snapshot is `project-understanding.yaml`. Start
fresh from current authoritative facts; do not import or convert other caches.
No alternate filename, compatibility alias, dual read/write, or migration.

## High-Level Log

Append-only history. Every material change to the ledger or `forecasts.md` gets a corresponding entry appended to the log in the same turn.

| Rule | Detail |
|------|--------|
| Append only | Never edit, reorder, or delete past entries. Wrong entries are corrected by a new appended entry referencing the prior one. |
| Material essence | Lead with what is true now, what to do next, why it matters, and evidence. Add changed-state context or provenance when it explains a material change. |
| Reflect all details | Capture the change, prior state, new state, reason, source/evidence, and agent/turn. |
| Chronological | Newest entries at the bottom. Each object has a UTC `timestamp`. |
| Same-turn pairing | Every material ledger or forecast update has at least one log entry from that turn. A current-state diff with no log append is defective. |
| No synthesis | The log records what changed; it does not duplicate the ledger's current-state synthesis. Cross-reference record IDs instead. |

Treat bytes already present in `high_level_log.jsonl` as immutable; permit only
an EOF append to that same canonical file. Never follow a symlink alias.

Use the command below from the bound CWD with an active direct marker bound to
the selected session. A missing canonical JSONL starts empty through normal
bootstrap; append current events without importing or converting other files.
Existing JSONL remains append-only. The CLI preserves concrete target safety,
detaches shared log inodes, and refreshes `high_level_log.anchor` advisory metadata.

All new canonical entries are one compact JSON object per line, including
direct EOF appends. The only canonical log is `high_level_log.jsonl`; no text
fallback, alternate filename, alias, tolerant parser, sidecar, or conversion.
This is a logging contract, not a syntax/content gate; direct append admission
and advisory anchor reconciliation remain unchanged.

Use exactly `ledger-append --json '<event-object>'`. It validates exactly one object
before log mutation and sets `schema: "eci-high-level-log/v1"`, the actual UTC
`timestamp`, and selected log `session_id`, overriding supplied envelope values.
Preserve event-specific payload in `details`. Direct append callers supply this
same envelope themselves.

| Field | Contract |
|-------|----------|
| `event` | One name from the vocabulary below, chosen by material change, not stage or command. |
| `summary` | Nonempty string describing the changed result and whether supporting work leaves the requested outcome open. |
| `actor` | Performer `{id, role, turn?}`. Use the exact stable runtime worker id from assignments/reports; role changes keep that id. `id`, `role`, and available `turn` are nonempty strings. |
| `recorded_by` | Optional recorder identity in the same form when a coordinator records another worker. Keep the worker in `actor`; the root log session is not the performer. |
| `requirements`, `evidence` | For `worker_progress`, nonempty arrays of nonempty strings naming/linking user requirements and evidence references. |
| `change`, `reason` | For `worker_progress`, `{before, after}` and `reason` are nonempty strings. Use `"unknown"` for an actually unknown prior state; do not fabricate it. Other material events retain prior/new state, reason, and evidence as applicable. |
| `next_action` | Nonempty string required by this guidance when work remains; omit when no action remains. The CLI checks its type when supplied. |
| `details` | Event-specific payload, such as verdicts, forecast targets, commit references, or `corrects` identifying a mistaken prior entry. |

| Event | Material change |
|-------|-----------------|
| `worker_progress` | Worker discovery or milestone advancing a user requirement. |
| `assignment_change` | Ownership, dispatch, or reassignment. |
| `review_result` | Findings or review verdict. |
| `decision` | Selected alternative or changed design choice. |
| `verification_result` | Test, proof, or E2E evidence/verdict. |
| `requirement_change` | Binding requirement, source, or scope update. |
| `forecast_change` | Target or forecast recalibration. |
| `blocker_change` | Block, wait, resume, or recovery. |
| `checkpoint` | Commit or provisional checkpoint. |
| `lifecycle_change` | Launch, cancellation, closure, or teardown. |
| `correction` | Mistaken prior entry, referenced by `details.corrects`. |

Structured worker-progress example, recorded by its coordinator:

```sh
"$HOME/.codex/bin/eci-active" ledger-append --json '{"event":"worker_progress","actor":{"id":"/root/implementer","role":"Implementer","turn":"7"},"recorded_by":{"id":"/root","role":"Supervisor"},"summary":"Focused validation passes; requested outcome remains open.","requirements":["requirement:log:R7:worker-progress; project-understanding.yaml#/records/requirement:log:R7:worker-progress"],"change":{"before":"Structured append unverified","after":"Focused checks pass"},"reason":"Implemented structured serialization","evidence":["focused-checks.out"],"next_action":"Run the production check"}'
```

Extract one worker's v1 progress directly:

```sh
jq -r 'select(.schema == "eci-high-level-log/v1" and .event == "worker_progress" and .actor.id == "/root/implementer") | .summary' high_level_log.jsonl
```

## Latest Status Report

`latest-status-report.md` holds the single most recent status report, written per the `writing-status-reports` skill. It is the handoff snapshot the next agent or user reads first.

| Rule | Detail |
|------|--------|
| Same skill, same format | Content follows `writing-status-reports`: state, progress, decisions, blockers/risks, verification, next focus; multi-lane table when applicable. |
| Lead with UTC timestamp | First line: `# Status - <UTC ISO8601>`. Stale reports without a timestamp are rejected. |
| Refresh triggers | After every ledger update, after every material change, before user-waiting stops, before shutdown, and whenever the user asks for status. |
| Forecast projection | Derive current forecast lines and scenario summaries from `forecasts.md`; do not treat the report as a second source of truth. |
| No copying the ledger | Report changed state plus next focus; do not duplicate ledger structure. Cross-reference instead. |

A ledger or material forecast update without its required same-turn log entry and report refresh is defective.

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

### Log, Ledger, and Forecasts

A current fact lives in one canonical record. Keep only a locator to a current forecast in the ledger; append material forecast changes to the log.

| Content | Ledger | Forecasts | Log |
|---|---|---|---|
| "14:22 - tried A, failed" | - | - | append |
| "Considered X, chose Y because..." | "Using Y. Why: <reason>." | - | append the consideration + decision event |
| "Thought bug was in M, found in N" | "Bug: N. Fix: <link>." | - | append the M->N correction event |
| "Step 1 done. Step 2 done. Step 3 WIP." | "Current: step 3 - <state>. Done: 1, 2 (links)." | - | append each step transition |
| Narrative of what each agent did | Current owner + last verdict + next action | - | append per-agent action when it produced a material change |
| Current lane/root forecast values | Rendered link only | Canonical current values | - |
| Material forecast update | Do not copy current values | Update current record in place | Append the material change |
| Existing ledger fact reaffirmed before action changes state | keep existing current fact | - | keep log as-is for pure reaffirmation; append material planning, risk, ownership, authority, or verification change |

Per-ledger-line test: true and load-bearing right now? No -> drop from ledger; if it captures something material that happened, append to the log instead.

### Lane forecasts

A lane is an independently advancing workstream, not an ECI step. Serial implement→review→repair→review→implement stays one lane with one critical path. Create distinct lanes only for independently advancing work with separate ownership or synchronization.

Record lane/root state and next action in `work` records, including owner and outcome links. Preserve dependencies, binding user deadlines and useful milestones as typed current records. Store each relevant forecast locator in `forecast_ref`; do not copy forecast values into the ledger or require rendered Markdown links inside YAML.

Store every current lane/root forecast in `forecasts.md`: named forecast outcome and status, current target, original baseline, recalibration reason/evidence, ECI base case, and each material downside scenario with its range and endpoint. Keep current records there in place. `latest-status-report.md` projects these values using `writing-status-reports`.

#### Forecast outcome wording

Write every lane and root forecast `Outcome` as a completed result in plain language: name the affected behavior or artifact and what will work or be delivered. The description must be understandable without a `Lane` heading, `Next milestone`, or transcript. Bare labels such as `UNPRICES` or `WITHDRAWN`, opaque identifiers, and vague phrases such as `forecast cleanup` are insufficient. Retain domain terms when the surrounding words explain the delivered result.

Example: `Outcome: Import validation that identifies unpriced records and explains how to correct them.`

**Forecast record fields in `forecasts.md`**

- Lane forecast:
  - Outcome: `<named lane/task outcome>`
  - Status: `active` or `inactive`
  - Target: `<UTC ISO8601>` when active
- Root completion forecast, when an active root outcome is not represented by lane reports:
  - Outcome: `<full named active root-task outcome>`
  - Status: `active` or `inactive`
  - Target: `<UTC ISO8601>` when active
- Recalibration, when a forecast changes:
  - Prior: `<UTC ISO8601>`
  - Current: `<UTC ISO8601>`
  - Why moved: `<why>`
  - Evidence: `<evidence>`
- Initial forecast:
  - Status: `unchanged`
  - Original baseline: `<UTC ISO8601>`
  - Evidence: `<evidence>`

Every non-`CLOSED` lane has a current forecast record with its named outcome and target. For each unrepresented active root-task outcome omitted by lane reports, keep one root completion forecast with the full root outcome and target. Root completion is not a child sum or stage. Keep task dependencies and critical-path facts in the ledger; use them to calculate the forecast without copying forecast values back into the ledger.

When a lane or root forecast changes, update its current record in `forecasts.md` with the outcome and target, then record the prior target, current target, reason, and evidence. Preserve the original baseline. For an initial forecast, record `unchanged`, its baseline, and evidence. When a lane closes, mark its forecast inactive; actual completion time remains a project fact in the ledger.

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
  `forecasts.md` record. A material risk without a finite duration basis is `unknown/unbounded`:
  give it no fabricated endpoint, and do not call the target an absolute worst
  case.
- `Initial forecast.Original baseline` remains the original forecast target; it is not
  the scenario base-case endpoint.

Forecast scenarios describe planning uncertainty only. They do not change
scope, priority, blocker status, or forecast authority.

For every material forecast update, edit `forecasts.md` in place, append to `high_level_log.jsonl`, append a `forecast-target-history.tsv` row only when a root target changes, and refresh `latest-status-report.md`. A forecast-only update does not require rewriting `project-understanding.yaml`. Store forecast values only in `forecasts.md`, keeping locators in the ledger. On closure mark the canonical forecast inactive and retain history rows.

**Status-report projection examples — not ledger storage**

In a material changed-state report, emit each canonical forecast line once using `forecasts.md`. Keep these lines as report-only examples; do not copy them into `project-understanding.yaml`.

- Next milestone: `Next milestone: <named outcome>`
- Forecast deadline: `Forecast deadline: <named lane/task outcome> will be finished by <UTC ISO8601>.`
- Root completion forecast: `Root completion forecast: <named active root-task outcome> will be finished by <UTC ISO8601>.`
- Changed forecast: `Forecast recalibration: <prior UTC ISO8601> → <current UTC ISO8601>; why moved: <why>; supporting evidence: <evidence>.`
- Initial forecast evidence: `Forecast recalibration: unchanged — baseline <UTC ISO8601>; supporting evidence: <evidence>.`
- Dependencies / critical path: `Dependencies / critical path: <none, named dependency + owner/resume, or critical path>`
- `CLOSED` lane: `Completed: <UTC ISO8601>; no active forecast deadline.`

Every non-`CLOSED` lane names its next milestone and canonical forecast line in the report. For each unrepresented active root-task outcome omitted by lane reports, include the standalone root completion line once. The forecast line itself names the finished outcome using the [forecast outcome wording](#forecast-outcome-wording); a separate `Lane` or `Next milestone` does not substitute, and it never names a critic, reviewer, actor, or stage. Root completion is full root completion, not a child sum or stage.

For a changed lane or root forecast, restate its current canonical line in the same report, then record `Forecast recalibration: <prior UTC ISO8601> → <current UTC ISO8601>; why moved: <why>; supporting evidence: <evidence>.`

A closed forecasted lane/root requires actual quoted `completed_at` UTC in its work record and an inactive canonical forecast. Append material closure to the log and refresh the report with `Completed: <UTC ISO8601>; no active forecast deadline.` Small non-lane work timestamps are optional. Removing `forecast_ref` alone does not close a forecast. Do not invent or revive a forecast deadline or recalibration. For an initial forecast, write `Forecast recalibration: unchanged — baseline <UTC ISO8601>; supporting evidence: <evidence>.`

State dependencies and parallel work. For parallel children, report the single critical-path deadline; child deadlines remain parallel; never add or sum parallel child deadlines into a parent, root, or mission deadline.

Forecasts are advisory. They never gate work, grant or deny permissions, require artifacts or receipts, create blockers, require parsers, or require per-command ceremony. Missing or stale forecasts are planning-quality defects. Reconcile them alongside safe work without delaying the update.

Coordinator-to-user updates retain the exact standalone lines defined by the ECI coordinator module. Do not use report lines or the audit history as current forecast storage.

### Forecast target history

`forecast-target-history.tsv` is the canonical audit-only history for root-task forecast targets. It has exactly four columns:

```text
added_utc	root_task_id	new_target_utc	reason
```

Every row records the UTC addition time, root task ID, new UTC target, and a concise human-readable reason for setting or changing the target. Append only: never edit, delete, reorder, or reuse a row.

| Target transition | `high_level_log.jsonl` | `forecast-target-history.tsv` |
| --- | --- | --- |
| none → A | Append a material `high_level_log.jsonl` entry naming A, why, and evidence. | Append A row with reason. |
| A → B | Append a material `high_level_log.jsonl` entry naming prior A, new B, why, and evidence. | Append B row with reason. |
| A → A | No high-level-log entry or history row for mere reaffirmation. | No row. |
| close | Record material completion normally. | No date row. |
| correction | Append a correction naming the prior entry and corrected target. | Append the corrected-target row with reason; never rewrite earlier rows. |

This history is audit-only. It never gates work, grants or denies permission, creates a blocker, or delays ordinary work. It is not a required session record or work prerequisite. Reconcile a missing, stale, or malformed history alongside ordinary work.

## YAML Snapshot Contract

Use one UTF-8 YAML 1.2 document. Required envelope: `schema:
project-understanding/v1`, `sections` map and global `records` map. Each section
has a `title` string; each record has `section` (existing section ID), `type`,
`data`, and `evidence` (string array). Optional `links` maps named relationships
to arrays of existing record IDs. No mandatory timestamp, hash, source registry
or duplicate ID field.

Stable semantic IDs identify subjects, not states or locations:
`requirement:<job>:<source-id>:<facet>`, `work:<job>:<subject>`. Different Jobs'
R1 labels must not collide. Facets distinguish independently binding conditions
from one source. Search/reuse the existing subject before adding; changes to
value, owner, role or section retain its ID. Section title changes preserve IDs;
section-key changes update memberships and record deletion repairs incoming links.

### Predictable shared types

Common `data` values are objects except `context`/`constraint`, which allow
project-specific typed JSON-compatible values and arbitrary domain arrays.
Listed fields are required unless conditional/optional. Common string fields
are nonempty; common string-array fields contain strings. Required acceptance
and relationship arrays are nonempty; named links target the stated record types.

| Type | `data` fields | Required typed links |
|---|---|---|
| requirement | `source_text: string`, `acceptance: string[]` | None |
| outcome | `description: string` | `requirements` → requirement, `scope` → scope |
| scope | `include: string[]`, `exclude: string[]` | None |
| work | `owner: string`, `state: active\|blocked\|completed\|cancelled`; `next_action: string` while active/blocked; `forecast_ref: string` when forecast applies; actual `completed_at: UTC string` for completed forecasted lane/root work, optional for small non-lane work | `outcomes` → outcome |
| unknown | `question: string`, `answer: null`, `effect: string`, `resolve_by: string` | None |
| decision | `choice: string`, `reason: string`, `consequence: string` | None |
| guard | `rule: string`, `reason: string` | None |
| verification | `verdict: pass\|limited-pass\|fail\|unverified`, `scope: string`, `limitations: string[]`; `revision: string` when relevant | None |
| context, constraint | Project-specific typed values | None |

Keep independently changing or differently evidenced subjects in separate
records. Preserve useful architecture, configuration, API, ownership and domain
details, not just progress. Use named fields and explicit units such as
`{value: 1000000, unit: "Hz"}`; booleans/numbers/arrays remain typed. A concise
single-assertion string is allowed; pasted prose reports/chronology are not.
Absent knowledge is an `unknown`, never fabricated zero/false/empty. Provisional
inferences state their uncertainty, effect and resolution action in unknown records.

Retain exact attributed source text and acceptance in requirements; outcomes
link their requirements and bounded scope, work links outcomes. Evidence strings
resolve to accessible passages, retained exact user quotes or observed output;
relative file references resolve from the canonical session directory. Extract
the relevant current facts rather than only listing sources. Commands alone are
not observed proof: verification states scope, limitations and relevant revision.
Tier/confidence may accompany evidence when useful.

One mutable fact has one canonical slot. Work owns workflow state/owner/next
action; outcomes and context never repeat that state. Verification owns observed
verdict/limits. Keep still-binding requirements, exact sources, acceptance and
source→outcome→scope after completion; clear obsolete next actions/blockers.
Delete superseded requirements only when they no longer constrain the project;
preserve original source/change in append-only history, linking it from a guard
when it still explains a current hazard.

### Authoring and native edits

Use unique string keys, two-space indentation and JSON-compatible scalars.
Quote free text, dates, IDs and values resembling booleans/null/numbers. Use
native `true`/`false`, `null`, and finite decimal numbers for typed values.
Quote exact integers outside the read tool's safe range and exact decimals
outside its precision. Preserve exact multiline text with `|-` (no final
newline), `|` (one), `|+` (all trailing newlines), or quoted escapes. No
directives, explicit/custom tags, anchors, aliases, merge keys or multiple
documents. These are writing/quality rules, not runtime content permission gates.

Prefer native selective YAML text edits, preserving unrelated comments, order,
quoting and multiline text. One canonical session writer combines bounded worker
proposals against the latest snapshot. Never serialize the whole document merely
to change one value, redirect parser output onto its input, or publish a stale
worker copy. For whole-snapshot publication, copy the latest snapshot to an owned
same-directory temporary, edit that copy, then replace only the canonical regular
file under existing ownership. Rename is publication, not concurrency control.

```sh
(
set -e
session_dir="$HOME/.cache/codex-proof/$SESSION_ID"
snapshot_tmp=$(mktemp "$session_dir/.understanding-snapshot.XXXXXX")
cp -- "$session_dir/project-understanding.yaml" "$snapshot_tmp"
# Apply the bounded native edit to "$snapshot_tmp"; reconcile/check before publishing.
# On successful editing, replace the own-session canonical regular file:
mv -- "$snapshot_tmp" "$session_dir/project-understanding.yaml"
)
```

Example fixture: [project-understanding.yaml](examples/project-understanding.yaml).
Its source/values are explicitly synthetic; adapt subjects and sections to the
project instead of treating it as a fixed domain template.

### Read-only queries

When available, Node's existing `yaml` package can parse for read-only queries;
check `node -p 'require.resolve("yaml")'`. Do not assume Node, that package, or
`yq` installed. Availability is not a work gate; native text edits remain usable.
The following Bash example rejects parse/key/alias failures but does not certify
the full schema, allowed authoring subset, truth, freshness or completeness:

```sh
set -o pipefail
node -e 'const fs=require("fs"), YAML=require("yaml"); const value=YAML.parse(fs.readFileSync(process.argv[1],"utf8"),{uniqueKeys:true,stringKeys:true,maxAliasCount:0}); process.stdout.write(JSON.stringify(value));' project-understanding.yaml |
jq '.records | to_entries[] | select(.value.type == "requirement") | {id:.key,source:.value.data.source_text,acceptance:.value.data.acceptance}'
```

Parsing cannot detect semantic duplicate subjects or establish that useful
knowledge was omitted. Reconcile quality defects alongside safe work, never as
permission ceremonies. History/status/forecasts retain their separate contracts.

## Update Points

Update before work starts, after material state changes, after material findings/decisions/agreements, after milestones, after material user input that changes current understanding, binding requirements, risks, decisions, or useful recurrence guards, before QA/verdicts, before user-waiting stops, and before shutdown.

Every material forecast change updates its current `forecasts.md` record in place and applies the same-update recalibration rule to that forecast.

Answer the user before ledger maintenance or coordination when a response is due.
After a material event, update the affected current-state record: `project-understanding.yaml` for project/task facts or `forecasts.md` for forecast changes. Append the change to `high_level_log.jsonl` and refresh `latest-status-report.md` before dispatching work, sending coordination messages, or taking the next project action. A forecast-only change does not require rewriting the ledger. Already-running independent jobs continue; launch ready work after recording the event. This orders coordinator work without adding permission gates, receipts, or per-command checks.

For a project/task fact change, use this three-pass ledger edit:

1. Stale pass. Review the whole snapshot against current instructions, sources and reports. Replace/delete obsolete subject records and contradictory copied state.
2. Omission pass. Add what is missing, checking authoritative sources, user instructions, current diffs/state, and this turn's agent reports.
3. Fit pass. Rename, split, merge, add or drop sections so titles/memberships fit current knowledge. Repair incoming references when deleting or moving records.

Review the whole snapshot; affected records bound the native patch, not the stale/omission/fit review. Shared record contracts stay predictable while domain payloads and sections evolve. A purely additive update retaining stale state is a log-into-ledger defect: replace/delete in place.

Then append to `high_level_log.jsonl` one entry per material change made this turn. Every passed-around fact the stale pass deleted or rewrote becomes a log entry. For a forecast-only change, update its `forecasts.md` record and log it without rewriting the ledger.

Finally refresh `latest-status-report.md` using the edit mode above and the format in `writing-status-reports`; reflect the updated ledger and/or forecasts. Skip only when this turn produced no current-state or log change.

## Invalid Ledger

Reject the ledger if any holds:

- A fresh agent needs the transcript or unstated local memory to recover useful current project/task facts.
- An authoritative project/task source is named without extracting its relevant current-state facts. Resolve forecast details through the linked `forecasts.md` record; never extract forecast values into `project-understanding.yaml`.
- Binding requirements, acceptance criteria, material current-understanding corrections, useful recurrence guards, assumptions, risks, decisions, current state, or evidence are missing.
- Claims cannot be traced to sources, reports, commands, logs, screenshots, or commits.
- Obsolete states are retained as if current: stale plans, abandoned hypotheses, finished WIP, resolved blockers, superseded values.
- Entries are timestamped narrative or chronological "what happened next" prose, i.e. log-style.
- Multiple values for the same fact coexist instead of one current value.
- Activity logs or copied report bodies replace current-state summaries and links.
- The latest update is purely additive while sections that should have changed were left untouched.
- Facts are prose dumps instead of independently useful typed records under fitting sections.
- Canonical schema/shared record shape is absent, semantic subjects are duplicated, or section/link targets are missing or mistyped.
- An active lane lacks its next action or `forecast_ref` locator to its current forecast record in `forecasts.md`; the forecast lacks its named outcome, status, target, original baseline, or required recalibration; or a changed lane/root lacks its restated canonical line plus recalibration in the report projection.
- An unrepresented active root-task outcome omitted by lane reports lacks a full outcome and target record in `forecasts.md`.
- The ledger copies a forecast target, baseline, recalibration, base-case/downside estimate, scenario range, endpoint, or forecast status instead of linking to its `forecasts.md` record.
- Completed forecasted lane/root work lacks actual `completed_at` UTC, its forecast remains active, or the report omits `Completed: <UTC ISO8601>; no active forecast deadline.`
This is a planning-quality defect: reconcile it alongside safe work without delaying the update.
- Section titles or memberships no longer fit the content.
- The high-level log is missing, was edited or truncated in place, lacks entries for material ledger changes or material forecast-only updates made this session, or duplicates current-state synthesis.
- The latest status report is missing, lacks a UTC timestamp, predates the last ledger update or material forecast-only update, fails `writing-status-reports` coverage (state, progress, decisions, blockers/risks, verification, next focus), or duplicates ledger structure instead of summarizing changed state.
- Secrets, credentials, or unnecessary personal data are recorded.
