# Pause All Work

Coordinator/lead only. Evaluate before every workflow decision or transition. Trigger only when the direct current top-level user message, after case and outer-whitespace normalization, equals exactly `pause all work`, `stop all work`, or `pause everything`. Quoted, negated, interrogative, conditional, historical, status, timer, provider, silence, one-task, and `stop for today` text never triggers it.

Immediately stop admitting routing. Let only an already-running top-level call reach its safe boundary; do not cancel it merely for the pause. Then drain/close the provider event stream, attest closure, freeze late-child and quarantine snapshots, write/verify the canonical report, checkpoint/quarantine every frozen output, publish/verify the immutable transaction, project ledger/log/status, and update the marker last. A post-freeze event is a failed-closed conflict. If drain attestation is unavailable, write the report-only branch, keep the live marker in its prior phase, publish no transaction/marker update, and require an explicit all-active user resume/closure.

The only report path is `<current session proof directory>/pause-all-work-report.md`. Preserve the redacted exact trigger, direct-top-level source, canonical reason `user explicitly requested an all-work pause`, scope `all active work`, impact `intentionally paused, not a technical blocker`, user-only resume/closure, role/task/queue/in-flight/expected snapshots, quarantine state, canonical path, session-scoped report ID, and SHA-256 trailer. Never store raw secrets.

Canonical report body uses compact `key=<JSON value>\n`, exactly one final LF, and ordered fields: `report_id`, `captured_utc`, `source`, `quotation`, `reason`, `scope`, `impact`, `resume_owner`, `resume_or_closure`, `workflow_state`, `role_snapshot`, `task_snapshot`, `queue_snapshot`, `in_flight_snapshot`, `expected_event_snapshot`, `nested_eci_snapshot`, `safe_boundary_snapshot`, `late_child_snapshot`, `quarantine_snapshot`, `canonical_path`; then exactly one `report_sha256=<lowercase-64-hex>\n` trailer. Reject missing, duplicate, reordered, noncompact, noncanonical, unsafe-path, wrong-type, or invalid-hash data.

`workflow_state` is ordered `{ate_phase,eci_step,eci_iteration,resume_phase}`. Direct ECI stays active/nonterminal at its prior step; outer ATE alone owns nested ECI pause projection and may target `awaiting_user` only after the verified transaction and idle-role check. Snapshots use stable IDs, sorted arrays, canonical absolute paths, hashes, and quarantine states `review_state=unreviewed`, `routing_state=unrouted`, `commit_state=uncommitted`. The frozen manifest is exact ordered `{late_child_snapshot,quarantine_snapshot}` bytes and hash. The transaction is ordered `{report_id,report_sha256,frozen_manifest_sha256,intended_marker_state,projection_paths}` and is published atomically before idempotent projections; crashes replay only verified immutable bytes.

Present `BLOCKED: user-owned lifecycle pause; owner: user; impact: all active progress intentionally paused; unblock: explicit all-active user resume or closure; target: <report path>; report_sha256: <hash>; not technical/BRP`. This is lifecycle pause, not BRP or technical `BLOCKED`. Only a direct all-active user resume/closure changes it.

## Admission boundary and safe sequence

Evaluate the guard before normal work, blocker handling, autonomy, review, routing, teardown, and any `awaiting_user` transition. Read only the direct current top-level user message. If user attribution or the current proof directory is unavailable/ambiguous, fail closed through the existing status route and perform no routing. Do not fuzzy-match, infer intent from events, or preserve raw prompt bytes. A redacted exact trigger quotation, `source: direct current top-level user message`, and a stable session-scoped report ID unrelated to prompt content are sufficient evidence.

On an exact trigger: stop new routing immediately; permit a current top-level provider/tool call only to its safe boundary; hold composite-child/late events for the drain barrier; start no call, message, spawn, reassignment, commit, research, design, test, or arbitrary tool action. At the boundary invoke the provider-native drain/close barrier for top-level and composite-child streams, include every event observed through it, and require an attestation that no further events can arrive. Without attestation, use the report-only branch; never fake a frozen manifest or committed transaction.

With attestation, freeze the complete late-child/quarantine manifest before report serialization. Then write and verify report body/trailer; checkpoint/quarantine and verify every frozen entry; publish and verify transaction; project and verify ledger, high-level log, latest status, and marker last. A failure at any write/verification point is closed-fail. Replays re-read immutable verified report/transaction bytes and repair missing projections; they do not create duplicate log entries or a new report ID.

## Canonical report details

Use compact JSON values with strict escaping. The closed scalar contract is:

| Field | Exact constraint |
| --- | --- |
| `report_id` | Non-empty session-scoped ASCII `[A-Za-z0-9][A-Za-z0-9._-]*`, unrelated to prompt content. |
| `captured_utc` | RFC3339 UTC `Z`. |
| `source` | `direct current top-level user message`. |
| `quotation` | Non-empty redacted UTF-8, no raw secret/control character, preserves which exact trigger was sent. |
| `reason` | `user explicitly requested an all-work pause`. |
| `scope` | `all active work`. |
| `impact` | `intentionally paused, not a technical blocker`. |
| `resume_owner` | `user`. |
| `resume_or_closure` | Non-empty redacted UTF-8. |
| `canonical_path` | Exact normalized proof-directory `pause-all-work-report.md` path. |

Reject wrong JSON type/literal, unknown/duplicate/reordered field, control character, noncanonical encoding/path, non-UTF-8, noncompact body, missing final LF, or invalid/missing trailer. The body excludes `report_sha256`; calculate it over body bytes only. No other trailer is allowed.

`workflow_state` is ordered `{ate_phase,eci_step,eci_iteration,resume_phase}`. Direct ECI uses `ate_phase: null`, retains live marker step/nonnegative iteration, and uses that step as `resume_phase`; nested state appears only in `nested_eci_snapshot`. ATE’s attested transaction targets `awaiting_user`, retains the prior active phase in `resume_phase`, and keeps nested ECI step/iteration when present. In report-only unavailable-drain state both direct ECI and ATE retain their live prior marker/phase and never encode committed `awaiting_user`.

## Snapshot and transaction schemas

All snapshots are closed and sorted by stable/event ID. `role_snapshot` entries are `{stable_id,semantic_role,category,state}` with category `exploration-only|design|mixed|implementation`. `task_snapshot` is `{stable_id,parent_id,state,owner}`. `queue_snapshot` is `{stable_id,kind,state}`. `in_flight_snapshot` is `{stable_id,top_level_call_id,owner,state}`. `expected_event_snapshot` is `{stable_id,provider,kind,state}`. `nested_eci_snapshot` is `{stable_id,step,iteration,marker_state}`. `safe_boundary_snapshot` is null or exactly `{top_level_call_id,call_type,owner,state}`. `late_child_snapshot` is `{event_id,producer,observed_utc,result}` with bounded/redacted result. `quarantine_snapshot` is `{stable_id,artifact_path,artifact_sha256,review_state,routing_state,commit_state}`; every entry has `unreviewed`, `unrouted`, and `uncommitted` simultaneously. Non-null paths are normalized absolute paths and hashes are lowercase 64-hex.

`frozen_manifest` is compact UTF-8 one-final-LF ordered `{late_child_snapshot,quarantine_snapshot}` whose arrays are byte-identical to the report. Hash it exactly; changed order, mutation, missing observed event, or mismatch fails closed. The transaction is compact UTF-8 one-final-LF ordered `{report_id,report_sha256,frozen_manifest_sha256,intended_marker_state,projection_paths}`. `projection_paths` is ordered `{ledger,high_level_log,latest_status,marker}` with exact current proof paths. Direct ECI uses intended marker `active`; attested ATE uses `awaiting_user`. Publish through verified recoverable atomic replacement (or documented provider equivalent) before projections and marker update.

## Report-only branch and resume

When drain attestation is unavailable, after safe boundary write/verify the canonical report with only observable snapshots and bounded `resume_or_closure` stating `drain attestation unavailable; explicit all-active user resume or closure required`. Mark transaction `pending/unpublished`; do not freeze/hash manifest, publish transaction, update marker, claim `awaiting_user`, create BRP attempt data, or continue routing. Present the BLOCKED line with `transaction: pending/unpublished (drain attestation unavailable)`. A direct current top-level all-active resume/closure is the only state change; status, timer, and provider events do not resume it.

With a verified attestation, archive the immutable report at `pause-all-work-report.<report_id>.md` after verification and never overwrite it. A post-freeze event, conflicting body/digest/transaction/projection, missing atomic marker projection, or inability to verify every checkpointed artifact fails closed. The pause remains deliberately nonterminal: retain roles/tasks and resume prior phase/step only on explicit user command.
