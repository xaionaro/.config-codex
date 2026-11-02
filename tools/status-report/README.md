# status-report

Run `status-report validate [FILE]` or `status-report render [FILE]`; omit FILE or use `-` for stdin. The launcher requires Go and module dependencies. Both commands validate the YAML; rendering uses only that YAML and derives the progress bar. Validation checks structure and references, not factual truth or reviewer independence.

Required top-level fields are `timestamp` (RFC3339 UTC, `Z` or `+00:00`), `state`, lists `progress`, `decisions`, `blockers_risks`, `verification`, `tasks`, `top_priorities`, `next_focus`, `scope_complete` (boolean), `priority_estimates`, and `completion_estimate`. Use empty lists as `[]`. Optional fields are `lanes`, `root_forecasts`, `roster`, `timeline`, `timeline_state`, `reviews`, and the extensible mapping `details`. Unknown fixed fields are rejected; `details` is rendered in full.

Tasks have unique `id`, optional `parent_id`, `title`, `priority`, `impact`, `effort`, `status`, optional `owner`, `context`, `evidence`, and `indivisible_reason`. Task IDs and parents define the hierarchy; a dotted ID's `parent_id` is its exact prefix before the final dot, and a root ID has no parent. Task `owner` executes the task. Parent and top-priority references must exist and the tree must be acyclic. `effort` has finite ordered nonnegative `min_minutes` and `max_minutes`, `kind` (`elapsed` or `work`), and `basis`. Attempt a leaf breakdown of at most 30 minutes for every priority; a leaf upper bound above 30 requires `indivisible_reason`. Status is `NEW`, `IN PROGRESS`, `PAUSED`, `BLOCKED`, `CLOSED`, `unknown` or null. CLOSED requires acceptance evidence. The progress bar counts completed known leaf packages / known leaf packages, labels this an equal-package estimate, excludes parents and marks unknown statuses and incomplete scope as partial. It is not elapsed-time progress.

Provide one `priority_estimates` entry for each priority present in the tasks, including `unknown`, and one overall `completion_estimate`. Each has a UTC `as_of`, finite ordered `min_minutes` and `max_minutes` of elapsed time, and nonempty `basis`, `assumptions`, `dependencies`, and `critical_path`; priority entries additionally have `priority`. The renderer derives endpoints by adding the durations to `as_of`; do not supply `earliest` or `latest`. Label educated guesses as such. The producer determines the critical path and latest parallel endpoint; the tool never adds parallel durations. Refresh estimates when affected work changes.

Lanes have `task_id` (an existing task), `outcome`, `required_environment` (`implementation`, `test`, or `prod`), and distinct `implementation_status`, `test_status`, `prod_status` (`NEW`, `IN PROGRESS`, `PAUSED`, `BLOCKED`, `CLOSED`). Optional fields: `owner`, `stage`, `next_milestone`, `completed_at`, `forecasted`, `blocker`, `next_action`, `context`, `root_task_status` (`FOLLOWUP` or `FOLLOWUP_PAUSED`), `forecast`. Lane `owner` coordinates the lane; its referenced task's `owner` executes the task. Lane hierarchy comes from that task, not separate lane IDs or parent aliases. A `completed_at` UTC value requires the selected required-environment status to be CLOSED and no active forecast. Every lane whose selected status is CLOSED requires actual `completed_at`; a CLOSED selected status cannot retain an active forecast. Task status remains independent of lane readiness; a CLOSED source package can have an active test or production lane.

Enum fields must be YAML string scalars with an allowed value; mappings, lists, numeric or boolean scalars are invalid. Task `status` also accepts YAML null as unknown; use the documented values for other enum fields.

A supplied lane forecast or `root_forecasts` entry requires `outcome`, `target`, and `assessment`; use `unknown` for an unsupported target and quote UTC values. Optional fields are `baseline`, `prior`, `reason`, `evidence`, `dependencies`, and `scenarios` (list with `case`, `trigger`, `affected_work`, `duration_basis`, `evidence_assumptions`, `endpoint`, `evidence_gap_next_action`). Every scenario field must be nonempty; use `unknown`, `none`, or `—` where appropriate. Forecasts project upstream records; the tool does not calculate them. Root forecasts cover roots omitted by lane forecasts.

Timeline entries have `job`, `parent_chain`, `start`, `end`, `fast`, `normal`, optional `evidence`, `uncertainty`. Start and end are UTC timestamps exactly 30 minutes apart within the four hours ending at report time; intervals can cross midnight. All rows for a job must have the same parent chain. `timeline_state` may be `verified_empty`, `unavailable`, `present`, or omitted for unknown. Unavailable with rows is rendered as incomplete history.

`reviews` is a list of mappings with `task_id` (existing task), `reporter`, `critic`, `rounds` (1–5), `estimate`, `impact`, `priority`, and `unresolved` (`none` if resolved). The reporter requests independent review only for newly added time-estimated queue items; the tool does not dispatch critics or establish independence. At most five rounds. A report refresh, compaction, or recalibration of an existing item alone does not trigger this review.

```yaml
timestamp: '2026-11-02T15:24:00Z'
state: Work is underway.
progress: [Implementation started.]
decisions: [Use the existing contract.]
blockers_risks: []
verification: [Checks pending.]
next_focus: Complete checks.
scope_complete: false
tasks:
  - id: '1'
    title: Finish the work
    priority: high
    impact: Required outcome is incomplete.
    effort: {min_minutes: 20, max_minutes: 30, kind: elapsed, basis: educated guess}
    status: IN PROGRESS
    owner: implementation executor
top_priorities: ['1']
priority_estimates:
  - {priority: high, as_of: '2026-11-02T15:24:00Z', min_minutes: 20, max_minutes: 30, basis: educated guess, assumptions: review available, dependencies: none, critical_path: latest parallel endpoint}
completion_estimate: {as_of: '2026-11-02T15:24:00Z', min_minutes: 20, max_minutes: 30, basis: educated guess, assumptions: review available, dependencies: none, critical_path: latest parallel endpoint}
lanes: []
roster: {}
timeline: []
reviews: []
```
