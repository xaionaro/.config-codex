# status-report

The launcher requires Go and the module dependencies. `status-report validate [FILE]` validates one YAML document; `status-report render [FILE]` validates and prints it. Omit FILE or use `-` to read stdin. Validation checks structural consistency, not factual truth, completeness of evidence, or reviewer independence.

Required top-level keys: `timestamp` (RFC3339 UTC), `state`, `progress` (list of strings), `decisions` (list), `blockers_risks` (list of strings), `verification` (list of strings), `next_focus`, `scope_complete` (boolean), `tasks` (list), and `top_priorities` (list of task IDs). Empty lists must be `[]`, not null. Optional structured sections are `lanes` and `root_forecasts` (lists of mappings), `roster` (mapping), `timeline` and `reviews` (lists of mappings), and `details` (mapping). Put other report-specific structured content under `details`; top-level unknown keys are rejected. Lanes require a `task_id` referencing a task, an `outcome`, and `implementation_status`, `test_status`, and `prod_status` each in `NEW`, `IN PROGRESS`, `PAUSED`, `BLOCKED`, or `CLOSED`. `root_forecasts` entries use the same forecast fields as lane forecasts and are for root outcomes omitted by lane forecasts. Lane and forecast data are projections from the authoritative forecast records, not newly calculated forecasts. Lane scalar fields accepted: `id`, `task_id`, `parent_id`, `outcome`, `owner`, `stage`, the three readiness statuses, `next_milestone`, `completed_at`, `blocker`, `next_action`, `context`, and `root_task_status`. The optional forecast mapping accepts `outcome`, `target`, `assessment`, `baseline`, `prior`, `reason`, `evidence`, `dependencies`, and a `scenarios` list; each scenario accepts `case`, `trigger`, `affected_work`, `duration_basis`, `evidence_assumptions`, `endpoint`, and `evidence_gap_next_action`. Scalar fields must be strings or null; quote UTC values. Unknown fields in these fixed sections are rejected; `details` is intentionally extensible and all its content is rendered. `timeline_state` may be `verified_empty`, `unavailable`, or `present`; missing state means unknown. Timeline entries use `job`, `parent_chain`, `interval`, `fast`, `normal`, optional `evidence`, and `uncertainty`; rows for a Job must agree on parent chain. Unknown values must be labeled.

Each task has `id`, optional `parent_id`, `title`, `priority`, `impact`, `effort` mapping, `status`, optional `owner`, `context`, `evidence` and `indivisible_reason`. Task IDs are unique; parents and top-priority references must exist, and the tree must be acyclic. Priority and impact can be `unknown`; effort requires numeric `min_minutes` and `max_minutes` (nonnegative, ordered), `kind` (`elapsed` or `work`), and nonempty `basis` (label educated guesses). Attempt a breakdown into leaf packages of at most 30 minutes for all priorities. Explain a leaf with an upper estimate over 30 minutes in `indivisible_reason`; aggregate parent effort may exceed 30 minutes. `status` is `NEW`, `IN PROGRESS`, `PAUSED`, `BLOCKED`, `CLOSED`, `unknown`, or null. `CLOSED` requires acceptance evidence. No estimated bar or percentage is stored. The renderer counts completed known leaf tasks divided by known leaf tasks, labels this an equal-package estimate, excludes parents, and identifies unknown statuses or incomplete scope as partial. This does not represent elapsed time.

`reviews` is a list of mappings with `task_id` (existing task), `reporter`, `critic`, `rounds` (1–5), `estimate`, `impact`, `priority`, and `unresolved` (use `none` if resolved). It records the reporter and independent critic's scoped checks of newly added time-estimated queue items: their estimate, impact, priority, rounds, and unresolved findings. Trigger that human/agent workflow only for additions; the tool does not dispatch critics or establish their independence. Five rounds maximum. Refreshing or rendering a report, compaction, or recalibration of an existing item alone does not trigger review.

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
top_priorities: ['1']
lanes: []
roster: {}
timeline: []
reviews: []
```
