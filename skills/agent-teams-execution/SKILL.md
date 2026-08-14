---
name: agent-teams-execution
description: Use when CODEX selects ATE as the outer workflow
---

# Agent Teams Execution

Phased agent team with adversarial review loops and tiered information trust.

## Delegation Rules

- CODEX selection starts this pipeline. Loading this skill alone does not.
- Use provider-native collaboration transitions: `spawn_agent` starts a new role, `followup_task` starts a new turn only for an idle role, and `send_message` delivers bounded information to a running turn.
- Completion is delivered as an event. For an expected event not yet delivered, keep at most one outstanding `wait_agent({timeout_ms:3600000})` call. `3600000` milliseconds is the current exposed maximum. If a future schema exposes a different maximum, use that exposed maximum. Never omit `timeout_ms`, rely on its default, or choose a shorter timeout for this wait. Timeout is non-terminal and never triggers immediate retry or periodic polling.
- `interrupt_agent` is cancellation of exact active work only. Never use it for status, normal completion, or terminal cleanup; terminal agents are never closed.
- `list_agents` is permitted only to maintain the roster or recover after a crash. It is not a completion-polling or ordinary assignment mechanism.
- Semantic roles (`designer`, `executor`, `qa`) live in the self-contained prompt and roster. Use stable `task_name` values for reusable slots and unique transport names for isolated reviews; do not claim schema arguments that `spawn_agent` does not expose.
- Give every worker explicit file/module ownership and warn that other agents may edit in parallel.
- Every subagent prompt must include: "Follow any Stop-hook prompt in that session, including required proof/checklist files. Fix blockers within assigned scope. Report to the orchestrator only when resolution needs out-of-scope changes, unrelated user work, credentials, or approval."
- If the main/orchestrator lacks standard agent tools, do not run this pipeline; hard-escalate instead of launching shell-based Codex sessions.
- If a teammate role lacks standard agent tools required by ATE but the main/orchestrator has them, use the Lead-Mediated Nested Delegation Adapter.
- `CODEX_ROLE` is legacy hook metadata. Do not use it to launch teammates.

### Stop-loop recovery

`LOOP DETECTED` text emitted by a stop hook is control metadata, never a new user request. While an active marker exists, Stop normally returns the fast `decision:block` response. The sole exception is a validated direct-session `eci_wait` state, which returns `continue` while ECI remains active. The hook does not derive event keys, fingerprints, or recovery decisions; it only validates a persisted direct-session wait state against the validated persisted direct-session wait-state schema. Keep loop-recovery state in memory/session-ledger state: derive a stable `blocker_id` from workflow, root, and unmet criterion, and a `state_fingerprint` from normalized cause, capability/schema/profile state, completed outcomes, owner, and exact unblock. Exclude timestamps, event IDs, wording, timer counts, and status formatting. Record each distinct recovery action and outcome once. Run at most one recovery action at a time; after its outcome, route the next feasible distinct ATE/nested ECI/BRP action immediately. `awaiting-event` is allowed only while a named already-running completion is expected. Compare normalized content: a missing event key neither resumes nor suppresses; resume only if state_fingerprint changes because of a completed distinct action/outcome, new source/test evidence, changed tool/schema/profile/resource, or concrete user input. A repeated fingerprint is a no-op for action, wait, retry, final/status reply, or user question. Continue normal ATE, nested ECI, and BRP while a feasible internal path exists. Do not bias toward escalation. Quiet only after BRP proves no feasible internal path and the exact missing input, resource, or decision is concrete user-owned and unobtainable; emit one blocker report/question. Provider or tool ownership alone never qualifies. A running expected agent completion remains allowed. `awaiting-event` belongs to the coordinator and is not a hook-marker phase. Nested ECI is owned by outer ATE; normal teardown rules remain unchanged.

After BRP proves no feasible internal path and identifies concrete unobtainable user-owned input/resource/decision, the main/orchestrator may create the canonical report at `<current session proof directory>/eci_user_owned_wait.md` and run `~/.codex/bin/eci-active wait <current-session-proof-directory>/eci_user_owned_wait.md`. The report is exactly nine LF-terminated lines: `# ECI User-Owned Wait`, `state: user-owned-wait`, a safe `blocker_id`, a lowercase 64-hex `state_fingerprint`, `owner: user`, `brp_result: exhausted-no-feasible-internal-path`, `user_owned_input: unobtainable`, an exact `unblock_kind: input|resource|decision`, and a concrete `unblock`. The runtime caps and validates the report, binds the state to its SHA-256 digest, and writes one state while retaining the `eci_active` marker; each stop validates that direct-session state and returns `continue` while it remains, without consuming or deleting it. Only a changed-state `resume` or validated normal `off` clears it. This is coordinator recovery state, not a generic escape hatch or teardown. On materially changed normalized content established by the BRP/session record, the main/orchestrator must run `~/.codex/bin/eci-active resume <new-state-fingerprint>`; runtime accepts only a different supplied lowercase 64-hex fingerprint and does not prove content change itself. The same fingerprint is rejected. Invalid or missing wait state keeps the stop blocked, and normal `off`/clean-pass remains required for teardown.

**Core principle:** Explorers gather hard facts, designer architects from facts, executors aggregate implementation until root-task E2E passes, reviewers tear apart the integrated diff, QA validates the whole. Coordinator manages logistics, lead audits rule compliance. Neither implements.

The PreToolUse gate `ate-orchestrator-gate.sh` denies direct Edit/Write/MultiEdit when legacy `CODEX_ROLE` is `lead` or `coordinator`. If the gate fires, spawn the appropriate teammate and assign the task — do not unset `CODEX_ROLE` to bypass it.

Subagents, including lead and coordinator roles, follow Stop-hook prompts in their own sessions, including required proof/checklist files. They report to the main orchestrator only when resolution needs out-of-scope changes, unrelated user work, credentials, or approval. Disengaging by unsetting `CODEX_ROLE` to escape the gate is itself a violation flagged by the rule-compliance self-audit.

### Prompt Artifact Protocol

Before spawning, reassigning, or routing any teammate whose output may become evidence for review, FDR, execution, verifier, QA, or stale-packet guards:

1. Materialize the exact prompt or handoff text in the proof directory.
2. Record artifact path + `sha256sum` in roster/ledger state.
3. Include or forward artifact path + SHA wherever that evidence is consumed.

If `reasoning_effort` or another requested spawn field is unavailable, record the limitation in the prompt artifact and roster/ledger state. Never pass or claim an unavailable field. Trivial status pings need no prompt artifact when no review, proof, or stale-packet guard depends on them.

### Lead-Mediated Nested Delegation Adapter

Use only when an ATE role must create child agents but its session lacks `spawn_agent`/`followup_task`/`send_message`/`wait_agent({timeout_ms:3600000})`, while the main/orchestrator can use standard agent tools.

| Step | Owner | Rule |
|------|-------|------|
| 1 | Blocked role | Defines or approves each child prompt, stop criterion, context packet, and expected output. Prompts include exactly: "Follow any Stop-hook prompt in that session, including required proof/checklist files. Fix blockers within assigned scope. Report to the orchestrator only when resolution needs out-of-scope changes, unrelated user work, credentials, or approval." |
| 2 | Lead | Materializes each child prompt per Prompt Artifact Protocol before spawn. Spawns each child as a separate standard agent, verifies the Spawn Checklist, and consumes its delivered completion event; when an expected event is missing, the lead may hold one outstanding `wait_agent({timeout_ms:3600000})` for it. Timeout is non-terminal and is not retried immediately. |
| 3 | Lead/coordinator | Mechanically forwards child prompt artifact paths, SHAs, outputs, evidence, and followups. No analysis, filtering, synthesis, or substituted verdicts. |
| 4 | Blocked role | Reviews child outputs, requests followups if needed, and owns the final role verdict. No final verdict until forwarded child evidence is received. |

If the main/orchestrator lacks standard agent tools too, hard-escalate. Never simulate required child agents in one local review.

## ATE Active Marker

Before the first teammate spawn, create the marker the stop gate reads:

```bash
. "$HOME/.codex/hooks/lib/codex-proof-state.sh"

update_ate_marker() {
  phase="$1"
  scope="$2"
  session_id="${CODEX_SESSION_ID:-${CODEX_THREAD_ID:-}}"
  if [ -n "$session_id" ]; then
    codex_valid_session_id "$session_id" || {
      echo "Invalid ATE session id: $session_id" >&2
      exit 1
    }
    marker="$(codex_session_state_dir ate "$session_id")/ate_active"
  else
    marker="$(codex_cli_state_file ate ate_active true)"
  fi

  mkdir -p "$(dirname "$marker")"
  {
    printf 'phase: %s\n' "$phase"
    printf 'scope: %s\n' "$scope"
    printf 'cwd: %s\n' "$PWD"
    [ -n "$session_id" ] && printf 'session_id: %s\n' "$session_id"
    date -u '+updated_utc: %Y-%m-%dT%H:%M:%SZ'
  } >"$marker"
}

update_ate_marker research "<task + scope>"
```

The illustrative `update_ate_marker` helper above writes the marker file directly and is not an atomic primitive. It cannot by itself commit an all-work pause target. ATE may publish `awaiting_user` only when a provider-native atomic marker projection is available and verified—temp sibling plus flush/fsync plus atomic rename, or a documented equivalent; otherwise the transaction remains pending and the pause fails closed. This is a policy requirement, not a runtime hook change.

At every phase transition, run `update_ate_marker <phase> "<task + scope>"`. It recomputes the `ate_active` path and writes `phase: <phase>`, `scope`, `cwd`, optional `session_id`, and `updated_utc`.

Active phases: `research`, `design`, `execution`, `testing`, `qa`, `unblocking`.

Run `update_ate_marker awaiting_user "<task + scope>"` only after reporting a QA verdict, a user-owned technical blocker, or a verified user-owned lifecycle pause. For a lifecycle pause, complete stop-routing → safe-boundary → report/verify → checkpoint/quarantine → transaction/idle/atomic awaiting_user. In the canonical report and transaction, `workflow_state.ate_phase=awaiting_user` is the post-quiescence target; during safe-boundary and checkpoint/quarantine the live active marker remains the prior phase and `resume_phase` records that prior phase. The transaction is pending until its idle-role check succeeds, then atomically commits marker=`awaiting_user` plus the ledger/status target; no timeout or state disagreement may claim committed `awaiting_user`. Retain roles and tasks, and switch back to the prior active phase before routing any followup.

Run `update_ate_marker closed "<task + scope>"` only after teammate shutdown for an explicit request to shut down or switch away from ATE, or to cancel, withdraw, or replace ATE's root scope. A bounded ECI request is nested and does not close ATE.

Do not use `awaiting_user`, `closed`, marker removal, or session-variable changes merely to bypass the stop gate. The marker records ATE lifecycle state; it is not a stop bypass.

## Highest-priority pause-all-work guard

Evaluate this guard before every ATE decision or phase/event transition: normal work, blocker handling/BRP, autonomy/mission completion, review, routing, teardown, and `awaiting_user`. It precedes every other decision below.

Read only the direct current top-level user message. After case and outer-whitespace normalization, trigger only when it equals exactly one of `pause all work`, `stop all work`, or `pause everything`. Exclude every other variant, including quoted, negated, interrogative, conditional, qualified, historical, status, timer, provider, silence, one-task, and `stop for today` text. Do not fuzzy-match or infer intent from other events.

Use the current session proof directory defined by `maintaining-context-ledger`; the only report path is `<current session proof directory>/pause-all-work-report.md`. If top-level-user attribution or the proof directory is unavailable or ambiguous, fail closed through the existing status route and perform no routing. Do not store raw prompt bytes or secrets. A redacted exact quotation of the trigger actually sent, `source: direct current top-level user message`, and a stable session-scoped `report_id` unrelated to prompt content are sufficient evidence. The quotation must preserve which exact trigger was sent—`pause all work`, `stop all work`, or `pause everything`—while the canonical reason normalizes their shared all-work scope.

Pause sequence: stop admitting new routing immediately. Let only a currently executing top-level provider/tool call reach its safe boundary; do not interrupt or cancel it merely for this pause. If no top-level call is active, proceed immediately to the safe-boundary protocol. Hold composite-child and late events for the subsequent drain barrier. Do not start a new call, message, send, spawn, reassign, commit, research, design, test, or arbitrary tool action. At the safe boundary, invoke a provider-native drain/close barrier for the current top-level and composite-child event streams, include every event observed through that barrier, and require an attestation that no further events can arrive; if the provider cannot attest closure, fail closed and do not publish the transaction. Only after the barrier closes, freeze and record the quarantine/late-child manifest, then write and verify the report, then checkpoint/quarantine all in-flight output and verify every frozen entry, then publish and verify the authoritative transaction artifact and project/verify the idempotent ledger, `high_level_log`, latest status, and marker projections; the transaction remains pending until all in-scope roles are idle, and the marker update is last. This is exactly stop-routing → safe-boundary → report/verify → checkpoint/quarantine → transaction/idle/atomic awaiting_user. No event observed after the frozen manifest is silently omitted; a post-freeze event is a conflict requiring failed-closed replay. The report must contain the redacted quotation/source, `reason: user explicitly requested an all-work pause`, `scope: all active work`, `impact: intentionally paused, not a technical blocker`, why only the user controls resume/closure, the next explicit all-active resume/closure, active ATE phase, role/task/queue/in-flight/expected-event snapshots, quarantine state, canonical path, stable `report_id`, and its SHA-256 trailer. These are the only protocol-write exceptions. A failed report or transaction write/verification fails closed.
If the provider-native drain/closure attestation is unavailable or does not return a verifiable closed-barrier receipt, use the unavailable-drain report-only branch after routing has stopped and the current top-level call has reached its safe boundary (or immediately when no call is active). Write and verify the canonical user-owned lifecycle pause report immediately at `<current session proof directory>/pause-all-work-report.md`, with the exact redacted quotation and `source: direct current top-level user message`, `reason: user explicitly requested an all-work pause`, a bounded `resume_or_closure` stating `drain attestation unavailable; explicit all-active user resume or closure required`, the observable safe-boundary and role/task/queue/in-flight/expected-event snapshots, and only currently observable `late_child_snapshot` and `quarantine_snapshot` entries. Do not freeze or hash a `frozen_manifest`, create or publish a transaction, update a marker, or claim `awaiting_user`; keep the live ATE marker in its prior phase, retain roles/tasks, and keep any nested ECI current/nonterminal. The report body/trailer and digest remain valid, but the transaction is `pending/unpublished`; present `BLOCKED: user-owned lifecycle pause; owner: user; impact: all active progress intentionally paused; unblock: explicit all-active user resume or closure; target: <ATE report path>; transaction: pending/unpublished (drain attestation unavailable); not technical/BRP`. This is report-only lifecycle handling, not technical BRP and not an attempt-log event; retain only observable records, admit no routing, and require an explicit direct all-active user resume or closure. If the attestation exists and verifies, use the normal freeze/manifest/transaction path above.

Canonical report body (ATE outer only): emit exactly one UTF-8 line per key as `key=<JSON value>\n`, with compact JSON, strict escaping, a final LF, and this fixed top-level order:

```text
report_id
captured_utc
source
quotation
reason
scope
impact
resume_owner
resume_or_closure
workflow_state
role_snapshot
task_snapshot
queue_snapshot
in_flight_snapshot
expected_event_snapshot
nested_eci_snapshot
safe_boundary_snapshot
late_child_snapshot
quarantine_snapshot
canonical_path
```

`workflow_state` is exactly the ordered object `{ate_phase,eci_step,eci_iteration,resume_phase}`. During a normal ATE lifecycle pause with a verified drain, the canonical report/transaction sets `ate_phase` to the post-quiescence target `awaiting_user`, records the paused nested ECI step/iteration when present (otherwise JSON `null`), and sets `resume_phase` to the prior active ATE phase. In the unavailable-drain report-only branch, retain the live prior ATE phase in `ate_phase` and `resume_phase` and do not encode an `awaiting_user` target. The live marker remains that prior phase until the serialized transaction's idle-role check and atomic `awaiting_user` commit; use JSON `null` for any N/A value.

The scalar members are closed: `report_id` is a non-empty session-scoped ASCII string matching `[A-Za-z0-9][A-Za-z0-9._-]*` and unrelated to prompt content; `captured_utc` is an RFC3339 UTC `Z` string; `source` is exactly `direct current top-level user message`; `quotation` is a non-empty redacted UTF-8 string with no raw secrets or control characters and preserves the exact trigger actually sent; `reason` is exactly `user explicitly requested an all-work pause`; `scope` is exactly `all active work`; `impact` is exactly `intentionally paused, not a technical blocker`; `resume_owner` is exactly `user`; `resume_or_closure` is a non-empty redacted UTF-8 string; and `canonical_path` must equal `<current session proof directory>/pause-all-work-report.md` after lexical normalization, rejecting every other absolute path. All other top-level members use the closed schemas below. Wrong JSON types or literals, control characters, noncanonical paths, unknown/duplicate/reordered members, or omitted required members are rejected.
The exact report-path rule is: canonical_path must equal `<current session proof directory>/pause-all-work-report.md` after lexical normalization; every other absolute path is rejected.

Snapshot schemas are closed and exact. Each object uses the listed member order: `role_snapshot` is an array of `{stable_id:string,semantic_role:string,category:exploration-only|design|mixed|implementation,state:string}`; `task_snapshot` is an array of `{stable_id:string,parent_id:string|null,state:string,owner:string}`; `queue_snapshot` is an array of `{stable_id:string,kind:string,state:string}`; `in_flight_snapshot` is an array of `{stable_id:string,top_level_call_id:string,owner:string,state:string}`; `expected_event_snapshot` is an array of `{stable_id:string,provider:string,kind:string,state:string}`; `nested_eci_snapshot` is an array of `{stable_id:string,step:string,iteration:nonnegative integer,marker_state:string}`; `safe_boundary_snapshot` is JSON `null` when no top-level call is active, otherwise exactly the singular ordered object `{top_level_call_id:string,call_type:string,owner:string,state:string}`; `late_child_snapshot` is a direct array of `{event_id:string,producer:string,observed_utc:RFC3339-Z,result:bounded/redacted string}`; and `quarantine_snapshot` is a direct array of `{stable_id:string,artifact_path:string|null,artifact_sha256:string|null,review_state:unreviewed,routing_state:unrouted,commit_state:uncommitted}`. Arrays sort by their stable/event identifier: `stable_id` for role/task/queue/in-flight/expected/nested/quarantine arrays and `event_id` for `late_child_snapshot`; duplicate stable/event IDs are rejected. Every quarantined output carries all three fixed states `review_state=unreviewed`, `routing_state=unrouted`, and `commit_state=uncommitted`; never collapse these fields into one state. Paths are absolute normalized paths; non-null artifact hashes are lowercase 64-hex SHA-256 values; `iteration` is nonnegative; `result` contains no raw child output.

The canonical `frozen_manifest` is the ordered object `{late_child_snapshot,quarantine_snapshot}` whose values are byte-identical copies of the corresponding report arrays, with the exact object and array member order required by those schemas. Serialize it as compact UTF-8 JSON with exactly one final LF and no trailer. `frozen_manifest_sha256` is the lowercase 64-hex SHA-256 over those exact bytes; the verifier reconstructs the object from the report arrays and requires byte equality and hash equality before publishing the transaction. Any mutation, reordered member, changed event, changed artifact, wrong hash, or post-barrier event fails closed.

Reject wrong JSON types or literals, control characters, noncanonical paths, unknown, duplicate, missing, reordered, noncanonical, non-UTF-8, noncompact, or non-final-LF bodies and object members. All paths are absolute normalized paths; UTC uses RFC3339 `Z`. The canonical body is exactly the fixed top-level key list above and excludes `report_sha256`. On disk, write that exact UTF-8 canonical body with its final LF, followed by exactly one ASCII trailer line `report_sha256=<lowercase-64-hex>\n` outside the body. Parse and validate the body and trailer separately; reject any other trailer, unknown field, duplicate/reordered key, noncanonical encoding, or missing/invalid trailer. Recompute lowercase SHA-256 over the body bytes only and require the trailer value to equal it and to equal the `report_sha256` copied into the serialized transaction, project-understanding ledger, `high_level_log`, and `latest-status-report`. The report-level `BLOCKED` line may present this same hash separately; it is not part of the body or digest input. Any mismatch fails closed.

Record `user-owned lifecycle pause`, explicitly not BRP and requiring no BRP attempt log. The ATE outer coordinator owns the report, digest, authoritative serialized protocol transaction, and wait. A nested ECI emits only `nested_eci_snapshot`, never a duplicate report/digest/transaction, and never waits; on resume ATE uses `resume_phase` for the prior active ATE phase and routes the nested ECI to its prior step. The authoritative transaction artifact is `<current session proof directory>/pause-all-work-transaction.<report_id>.json`, keyed by `(report_id,report_sha256)`, with canonical compact UTF-8 JSON, exactly one final LF, and exact ordered fields `{report_id,report_sha256,frozen_manifest_sha256,intended_marker_state,projection_paths}`. `report_id` equals the report's ID; both hashes are lowercase 64-hex and equal the verified report and canonical frozen-manifest hashes; `intended_marker_state` is exactly `awaiting_user`; and `projection_paths` is the exact ordered object `{ledger,high_level_log,latest_status,marker}` of absolute normalized paths equal to the current session proof ledger, log, status, and ATE marker paths. Reject unknown fields, wrong JSON types/values/hashes/paths, duplicate/reordered/noncanonical members, non-UTF-8, noncompact, or non-final-LF bytes. If the report and frozen manifest verify but this transaction is missing, deterministically republish it from those bytes into `transaction pending`; if either cannot verify, fail closed. Publish it recoverably through a temp sibling plus flush/fsync and atomic rename, or a documented provider-native equivalent; re-read and hash-verify it before projections. Ledger, `high_level_log`, latest status, and marker are idempotent projections: publish and verify the transaction first, then project and verify each, with the marker update last. A crash leaves `transaction pending`; restart re-reads the immutable transaction/report and repairs missing projections before any marker claim, and only all-verified projections are committed `awaiting_user`. Replays keyed by the tuple never duplicate log entries. The lifecycle sequence is exactly stop-routing → safe-boundary → report/verify → checkpoint/quarantine → transaction/idle/atomic awaiting_user: the current top-level call finishes or no-call continuation proceeds, the report and frozen manifest are verified, the transaction is published and verified, projections are repaired/idempotently verified, and the transaction remains pending until every in-scope role is idle. Only then does it atomically set the live marker to `awaiting_user` as the last projection and commit the ledger/status target; the canonical report/transaction target must not be mistaken for the live current marker, and no timeout or disagreement may claim committed `awaiting_user`. Retain the prior phase in `resume_phase` and retain roles/tasks. Do not create a new phase, close, or shut down. If no provider event is already expected, do not wait. For one expected provider event, use at most one `wait_agent({timeout_ms:3600000})`; timeout is non-terminal and never auto-retries or resumes. Only a direct current top-level user all-active resume/closure instruction changes state; status, timer, and provider events do not. Resume the prior phase and close through normal teardown.

The report's `quarantine_snapshot` and `late_child_snapshot` arrays are the frozen pre-application manifest. The drain barrier must complete before the verifier serializes and hashes `frozen_manifest`; include every event observed through the barrier, and never silently omit a post-freeze event. Freeze and record the manifest at the safe boundary before writing the report. After body/trailer and frozen-manifest verification, apply checkpoint/quarantine and verify every quarantine entry's exact `stable_id`, path, hash, and simultaneous fixed states, plus every late-child entry's exact `event_id`, producer, timestamp, and bounded result, before publishing the transaction artifact. The live report remains at `<current session proof directory>/pause-all-work-report.md`; after verification, archive the immutable canonical report at `<current session proof directory>/pause-all-work-report.<report_id>.md`; never overwrite an archive. The transaction artifact is the authoritative commit point; publish and verify it before projecting ledger, log, status, and marker, with marker last. If a crash or retry occurs after report write, transaction publish, or during checkpoint/quarantine/projection, replay the same tuple by re-reading the immutable report and transaction, validating body/trailer/digest and frozen manifest hash, and repairing and re-verifying missing manifest entries and projections before any marker update or log append; markers alone never mean completion. A conflicting body, digest, stale transaction, manifest, or projection fails closed; only a fully verified transaction and all projections can be reused or claim commit. The first `report_id`, snapshots, digest, transaction, and archive are immutable. After resume or closure, create a new `report_id`.

The report-level status line is exactly; it is a normalized presentation and does not replace the exact trigger quotation/source:

```text
BLOCKED: user-owned lifecycle pause; owner: user; impact: all active progress intentionally paused; unblock: explicit all-active user resume or closure; target: <report path>; report_sha256: <hash>; not technical/BRP
```

This `BLOCKED` line is report-level only. An ATE task marked `blocked` remains a technical/BRP state, and `PAUSED` remains dependency-only.

The report-level example uses `reason: user explicitly requested an all-work pause`; its quotation and source remain the evidence for whether the exact trigger was `pause all work`, `stop all work`, or `pause everything`.

**Parallelism principle:** Never serialize independent work. Parallelize everything that can be parallelized.

**No urgency. Infinite time.** Never prioritize speed over discipline. Every shortcut, skipped review, or "good enough" degrades the final result. Do it right, every time.

**Autonomy principle.** Drive the pipeline to QA verdict without user input. Teammates decide within their role; coordinator routes within the pipeline; lead enforces rules. Exhaust normal protocol flow before BRP: clarify, open follow-up tasks, reassign, re-scope, debug, or use paired reviewers/owners first. Escalate to user only for QA verdict, user followup, or when normal flow plus BRP cannot resolve the issue. Otherwise proceed — never ask permission for the next obvious step.

## Mission Completion Guard

The main thread, coordinator, and lead do not stop, final-answer, declare done, or shut down teammates while the user's mission has solvable work. A blocker, QA rejection, escalation label, protocol limit, or subagent stop is routing input, not a terminal state.

Subagent blocker claim = local issue to route. Run BRP only after normal ATE issue handling cannot resolve it, or before user escalation.

Keep unblocking, reassigning, re-scoping, and verifying until the objective mission criteria are met and the user explicitly confirms completion/closure. Stop or wait only when the user asks, or when progress needs user input that agents/tools cannot obtain.

## Project Understanding Ledger

Maintain a project-understanding ledger for every ATE run. Follow the `maintaining-context-ledger` skill for path, content, update timing, and validity rules. If `$SESSION_ID` is unavailable, run the stop gate once to bind session state or hard-escalate with the missing session ID.

The coordinator owns the ledger. Teammates report ledger-worthy facts; if a teammate edits the ledger, include that file in explicit ownership and prevent ownership overlap.

Coordinator updates after: findings, design approval, task code/test approval, blocker resolution, user correction; before QA spawn, user-waiting stop, shutdown. Lead reminds on forgotten updates. Snitch may remind asynchronously after phase transitions, manual audit reminders, and activity bursts. Invalid ledger blocks QA spawn.

<CRITICAL>
When this pipeline is active, spawn bounded standard Codex agents with explicit roles, disjoint write ownership, and concrete expected outputs.

Example mapping: one `explorer` for each independent research slice, one `worker` for implementation ownership, and one `explorer` or `default` reviewer for critique.

**Reusable ordinary role slots only.** Name ordinary producer slots by stable role (`executor-1`, `explorer-2`), not task/round/gate (`executor-auth-fix`, `qa-cycle-3`). Put task id, ownership, lens, phase, and cycle in the assignment; reassign idle ordinary teammates instead of spawning new ones. Special semantic roles follow the mandatory fresh-spawn rule below.
</CRITICAL>

## Pipeline Model

**Root task:** the highest active task in the current task tree: no parent task can absorb its changes, proof, review, or commit. Sub-tasks, E2E findings, review fixes, and per-repo commits aggregate under that root until post-review E2E/proof passes.

**Aggregate implementation.** Research and design are global. After design, executors finish root slices and discovered sub-tasks while sub-task/candidate-fix execution reviews run async. Each code target uses both Execution Reviewer lenses: correctness/fidelity uses the reusable ordinary slot, while long-term health uses a fresh special spawn under its semantic lens. Verdicts use APPROVED/CONDITIONAL/REJECTED. Root aggregate review blocks final proof/QA: REJECTED reruns both lenses after fixes, proof, and amend/squash; CONDITIONAL creates required pre-QA fix tasks that must be fixed and verified before final proof/QA. Pre-route async findings: `now` enters normal work; only deadline-qualified defer or scope-creep debt enters `queued_async_followup`; `ignored-contradictory` directives record without reopening. Async output never delays or reopens root aggregate review except for a verified invalidation under **Coding-style admission**; that exception pauses only affected writes and cannot queue past root review or QA.

**Queued async-followups.** Store only either deadline-qualified deferred work or scope-creep debt in the task list and project ledger with owner, source review, verified finding, verification evidence, target root/cycle, and replay trigger. Replay deadline-qualified deferred work when the next execution iteration, pipeline cycle, or root-task cycle opens. On that trigger, recheck scope-creep debt; move it to `pending` only while it consumes no primary time, owner, proof, or critical-path capacity; otherwise leave it queued.

| Stage | Scope | When it starts |
|-------|-------|---------------|
| Research | Global | Immediately |
| Design | Global | After research |
| Execution | Per task/slice | After design and applicable coding-style admission are approved. Sub-task/candidate-fix execution review runs async; no blocking code review yet. |
| E2E confirmation | Root task | After all known slices/sub-tasks land. Failures spawn tasks. |
| Aggregate review | Root task | After E2E proves the root task is fulfilled. Loop until no REJECTED/CONDITIONAL remains. |
| Post-review E2E + QA | Final | After aggregate review has no REJECTED/CONDITIONAL. |

**Final QA:** After post-review E2E passes, QA runs all tests, checks all requirements, validates the integrated whole.

### User Followups

After the team reports a QA verdict, the user may send followups (bug reports, tweaks, new features, questions). Coordinator routes each followup through **as much of the full pipeline as reasonably applies** — never skip stages for "small" requests.

| Followup type | Pipeline |
|---------------|----------|
| Question / clarification | Explorer → answer to user. No code. |
| Trivial config tweak (1-line, no logic) | Producer read-only admission discovery → Verifier admission → Executor → E2E/targeted proof → aggregate review → rerun proof → QA |
| Bug fix | Executor read-only admission discovery → long-term-health Execution Reviewer admission for production code (isolated repro may continue) → Executor/debug roles → E2E confirmation → aggregate review → rerun E2E → QA |
| Behavior change in existing feature | Designer → both Design Reviewers → execution → E2E confirmation → aggregate review → rerun E2E → QA |
| New feature | Full pipeline: Research → Design → both Design Reviewers → execution → E2E confirmation → aggregate review → rerun E2E → QA |

**Default: when in doubt, run more pipeline, not less.** Skipping stages for "small" requests is how regressions ship. Coordinator justifies any skipped stage to lead and CCs snitch asynchronously.

## Roles

| Role | Count | Phase | Responsibility |
|------|-------|-------|---------------|
| **Coordinator** | 1 | all | Task assignment, routing, phase management. Requests spawns from lead. **Never implements.** |
| **Lead** | 1 | all | Spawns teammates. Audits coordinator's rule compliance. Reminds coordinator when it forgets enforcement. **Never implements.** |
| **Explorer** | 1+ | 1 | Gather facts, including applicable coding-style sources and exclusions. Tag sources. Challenge each other. |
| **Designer** | 1 | 2 | **Special.** Architect from findings, own style choices, and propose the applicable admission record. Produce file ownership map. Ship a minimal proof-of-concept implementation for any unproven-in-practice mechanism the design relies on — see Designer PoC Requirement. |
| **Design Reviewer** | 1+ | 2 | **Special.** Adversarially review the design and independently admit its coding-style record before durable execution. Report only, never edit design. 2+ for large tasks. |
| **Fundamentals Design Reviewer** | 1 | 2 | **Special.** Runs in parallel with Design Reviewer. Receives the style record and checks hidden premises and fundamental consequences without becoming an admission owner. Challenges design fundamentals, not surface issues. Must obtain exactly three distinct child identities/reports: (1) ordinary fact/issue brainstormer — list possible fundamental issues; (2) special reviewer — investigate design against each issue; (3) special meta-reviewer — review the reviewer report for missed angles, weak evidence, or rubber-stamping. No reuse, collapse, simulation, or verdict before all reports arrive. If FDR lacks agent tools, use the Lead-Mediated Nested Delegation Adapter; FDR defines/approves prompts and owns the final verdict. Report only, never edit design. |
| **Executor** | 1+ | 3 | Implement assigned task + unit tests from the admitted record. On skip-design routes, perform read-only admission discovery before writing. One per independent unit of work. Actively look for code smell and design issues in code they study/touch, report all to coordinator. Broken infra or resorting to a workaround = notify coordinator before proceeding. |
| **Execution Reviewer** | 1 reusable ordinary lens + fresh special lens per review | 3 | Correctness/fidelity remains ordinary and guards hard contracts; **long-term health is special** and owns skip-design code admission and all code reconciliation. Review targets: root aggregate, sub-task, candidate fix. Root scope blocks. Async scopes pre-route per Execution dual review; only deadline-qualified defer or scope-creep debt enters `queued_async_followup`. Report only. |
| **Test Designer** | 1 | 3 | Propose the applicable test-artifact admission record before writing test specs. Waits for interface contracts. |
| **Test Executor** | 1+ | 4 | Implement tests from specs; propose the test-artifact record when no Test Designer does. |
| **Test Reviewer** | 0-1 per root task | test/final | Independently admit test/spec artifacts before durable writes and review test changes during aggregate/final review. Report only, never edit tests. |
| **Verifier** | 1+ | per task | Independently admit lightweight/non-code work and test artifacts when their usual reviewer is optional, before durable writes. Adversarially checks deliverables against all expectations. Replaces the test pipeline when testing is N/A. |
| **RCAer** | 1 per debug task | debug | Explores root cause and regression status from repro evidence plus previous/current test-run artifacts. Reports RCA only; never fixes. |
| **Brainstormer** | 1 | any | On-demand when a blocker emerges. Genius creative unblocker — thinks outside the box. Lists as many solution ideas as possible. Positives only — no negatives, no filtering, no feasibility judgment. Bigger list = better. |
| **Snitch** | 1 | all | Snitch is async-only: CCs, reminders, audits, reports, verification requests, and silence create no prerequisite, wait, direct interruption, or gate. CCed on all submitted/blocked/completed claims and QA verdicts. Independently audits rule compliance and reports violations to lead/coordinator. Success = confirmed violations found. May push back once per report if lead dismisses: quote the exact rule/requirement violated and why no workaround is acceptable. On QA approvals, looks for testing gaps: insufficient coverage, proxy-only evidence where direct was possible, untested criteria. On reviewer APPROVED messages, checks for rubber-stamping against the executor critique log and reports gaps to lead. Lead handles confirmed gaps under normal finding/priority rules. Lead or coordinator uses `followup_task` for an idle Snitch and `send_message` for a running Snitch at event-driven milestones. Delivered events, not polling, drive audits. On every audit, also check ledger freshness and asynchronously remind coordinator after activity bursts without updates. |
| **QA** | 1 | final | Final integration check. Runs all tests, reconciles coding-style admission evidence, and guards hard consequence contracts. Last gate. |

### Team Sizing

One execution lane per independent unit. Keep the ordinary correctness/fidelity reviewer slot reusable; spawn a fresh special long-term-health reviewer for each review invocation and retire its prior slot without shutdown or terminal cleanup. Root aggregate review starts after root E2E/proof and uses both lenses.

## Mandatory Compliance

**Every teammate** must invoke `agent-teams-execution` skill via skill instructions as their first action. Lead **must include this instruction in every spawn prompt**. Coordinator and lead: re-invoke the skill after every context compaction.

Blocker handling uses `blocker-resolution-protocol` (BRP). Lead includes that skill name in prompts for blocker-resolution tasks.

**Manual skill refresh (coordinator, lead, snitch).** Lead uses `followup_task` for an idle role or `send_message` for a running role to request re-invocation after context compaction, phase changes, long waits, and user-waiting resume. Silence is non-terminal; do not create a wait-retry loop.

### Model and Effort Level

Ordinary assignments resolve the currently configured model, provider, and exact configured reasoning effort before spawn, record all three in the prompt artifact and roster, and never hardcode `xhigh`, `high`, or `max`. Pass exposed fields; when the schema does not expose a requested field, record that limitation and do not claim it was set. Special `sol-high` is the explicit exception and uses `high`, distinct from ordinary effort.

### Special model profile and role boundary

The highly intelligent profile is currently `sol-high`; `sol-high` is an alias, not a model ID. The tracked profile currently contains:

```toml
model = "gpt-5.6-sol"
model_provider = "openai"
model_reasoning_effort = "high"
```

Resolve `${CODEX_HOME:-$HOME/.codex}/sol-high.config.toml`, parse only its top-level keys, hash its exact bytes with SHA-256, and immediately before every fresh special spawn record the profile path, exact profile SHA-256, provider, model, effort, and a non-empty `application_route` descriptor in the prompt artifact, roster, and project-understanding ledger. Send every selector exposed by the current collaboration schema: currently `model="gpt-5.6-sol"` and `reasoning_effort="high"`; record dimensions with no exposed selector, including the provider binding when unavailable, as `unavailable_by_schema`. Future profile and schema values replace these literals. Recheck the profile hash immediately before spawning; if it changed, discard and re-resolve it or create a model-routing blocker.

Only the exact invocation record proves the requested selectors. A successful non-rejecting result proves the child identity. Record requested-special plus child identity and, when effective telemetry is unavailable, also record effective-unavailable. An unexposed selector is unavailable_by_schema; absent post-spawn telemetry is effective-unavailable. If an exposed selector is omitted or rejected, or returned effective telemetry conflicts with the requested profile, reject only that child dependency; continue ATE, nested ECI, and BRP, and never use ordinary fallback, reuse, or downgrade. Do not claim effective application when the schema cannot expose it. Ordinary assignments still resolve and record their configured model, provider, and exact effort; special `sol-high` uses `high`, distinct from ordinary effort.

The prompt artifact records the resolved profile path, exact SHA-256, provider/model/effort values, every exposed selector sent, every `unavailable_by_schema` dimension, and non-empty `application_route`; recheck the profile hash immediately before the spawn. Only the exact invocation record proves the requested selectors. A successful non-rejecting result proves the child identity. Record requested-special plus child identity and, when effective telemetry is unavailable, also record effective-unavailable. If an exposed selector is omitted or rejected, or returned effective telemetry conflicts with the requested profile, reject only that child dependency; never claim effective application or use ordinary fallback, reuse, or downgrade. A post-spawn profile change affects later spawns only.

Reusable producers keep stable role/transport names. Every special semantic-role spawn—`Designer`, `Design Reviewer`, `Fundamentals Design Reviewer`, FDR special reviewer/meta-reviewer, `ECI critic-step2`, `ECI Critic B`, `ATE Design Reviewer`, `ATE meta-reviewer`, authoritative architecture/design, `mixed`/`combined fact-and-authority`, and `Execution Reviewer: long-term-health`—uses a fresh `spawn_agent({fork_turns:"none"})` with a unique transport identity and fresh boundary/profile evidence. Record requested-special plus child identity and, when effective telemetry is unavailable, also record effective-unavailable. An unexposed selector is unavailable_by_schema, while absent post-spawn telemetry is effective-unavailable. Retire the prior special slot without shutdown or terminal cleanup. ECI blind special critics therefore use fresh unique identities; an ordinary `followup_task` cannot upgrade a role, so reclassification requires a fresh special spawn. Ordinary `Explorer`, `implementer`, and `Execution Reviewer: correctness/fidelity` producer slots remain reusable under the stable-role rules. FDR obtains exactly three distinct child identities and reports—one ordinary fact/issue brainstormer, one special reviewer, and one special meta-reviewer—with no reuse, collapse, or simulation; no FDR verdict precedes all three reports.

Every assignment artifact and roster entry has exactly one category—`exploration-only`, `design`, `mixed`, or `implementation`—and one semantic role. The independent category-role boundary artifact is canonical UTF-8 compact JSON with exactly one final LF and exactly the ordered fields `{category,semantic_role,authority,required_model_class,artifact_sha256,verdict}`. `artifact_sha256` is the SHA-256 of that same canonical body after substituting a fixed 64-zero sentinel for its `artifact_sha256` value; the verifier substitutes the sentinel and recomputes, while the artifact path and resulting hash are recorded externally in the prompt artifact, roster, and project-understanding ledger. `authority` is the closed enum `non-authoritative|authoritative|combined`; `required_model_class` is `ordinary|special`; `verdict` must be `APPROVED`. Unknown, duplicate, missing, reordered, non-UTF-8, noncompact, non-final-LF, mismatched, or unlisted fields block the spawn.

Normalize operational stable labels exactly before boundary validation: `explorer`→`Explorer`; `researcher`→`researcher`; `brainstormer`→`Brainstormer`; `critic-step2`→`ECI critic-step2`; `critic-A`→`ECI Critic A`; `critic-B`→`ECI Critic B`; `e2e-gate`→`E2E gate`; `implementer`→`implementer`; `executor`→`Executor`; `qa`→`QA`; `fdr-reviewer`→`FDR reviewer`; `fdr-meta-reviewer`→`FDR meta-reviewer`; `ate-design-reviewer`→`ATE Design Reviewer`; `ate-meta-reviewer`→`ATE meta-reviewer`; `execution-reviewer-correctness`→`Execution Reviewer: correctness/fidelity`; `execution-reviewer-long-term-health`→`Execution Reviewer: long-term-health`. Unknown labels block. Normalization occurs before exact role, category, authority, and model checks.

The closed semantic-role map and cross-field invariants are: `exploration-only` → `Explorer`, `researcher`, `fact/issue brainstormer`, `Brainstormer`, `brp primary explorer`, `brp-feasibility-validator`, `loop-breaker`, `repro`, `RCAer`, `Snitch`, `Coordinator`, or `Lead`; each requires `authority=non-authoritative` and `required_model_class=ordinary`, and may gather facts, describe candidate architectures/options, compare/rank them, and report evidence but may not author or adjudicate authoritative architecture, interfaces, ownership, components, data flow, or admission. `design` → `Designer`, `Design Reviewer`, `Fundamentals Design Reviewer`, `FDR reviewer`, `FDR meta-reviewer`, `ECI critic-step2`, `ECI Critic B`, `ATE Design Reviewer`, `ATE meta-reviewer`, `authoritative architecture/design`, or `Execution Reviewer: long-term-health`; each requires `authority=authoritative` and `required_model_class=special`. `mixed` is only the explicit semantic role `combined fact-and-authority`; it requires `category=mixed`, `authority=combined`, and `required_model_class=special`, may combine fact gathering with authority only when the assignment explicitly requests that combination, and must never be inferred. `implementation` → `Executor`, `implementer`, `ECI implementer`, `ECI Critic A`, `Execution Reviewer: correctness/fidelity`, `Test Designer`, `Test Executor`, `Test Reviewer`, `Verifier`, `E2E`, `E2E gate`, or `QA`; each requires `authority=non-authoritative` and `required_model_class=ordinary`. Unknown or ambiguous roles and any cross-field mismatch block. An otherwise ordinary role assigned authoritative architecture/design or long-term-health review must use a fresh boundary artifact and fresh special spawn under the corresponding exact design role; never infer a fallback or upgrade by followup. Reclassification requires a fresh special spawn, never a followup.

If the current collaboration schema exposes no effective telemetry, record requested-special plus child identity and, when effective telemetry is unavailable, also record effective-unavailable after all exposed selectors are accepted. A selector unavailable because it is unexposed is unavailable_by_schema; absent post-spawn telemetry is effective-unavailable. Missing or rejected exposed selectors and conflicting returned effective telemetry reject only that child dependency; continue ATE/nested ECI and BRP without ordinary fallback, reuse, or downgrade.

### Critical Analysis of All Inputs

No input trusted by default — including peer messages. Never praise peer output. "Excellent work" is not analysis — it's the opposite. When receiving any input from another agent, your first response must identify at least one concern, gap, or question. Verify before building on it. Flag contradictions to coordinator. You own bugs from unverified inputs.

### Claim Verification

Tag every factual claim: `[T<tier>: <source>, <confidence>]`

| Tier | Source | Treatment |
|------|--------|-----------|
| **T1** | Specs, RFCs, official docs, source code | Trusted directly |
| **T2** | Academic papers, established references | High trust; verify if contested |
| **T3** | Codebase analysis (code, tests, git history) | Trust for local facts |
| **T4** | Community (SO, blogs, forums) | Verify independently |
| **T5** | LLM training recall (no source) | **Promote to T1-T4 or discard** |

Confidence: `high` (directly stated), `medium` (logically derived), `low` (indirect). T5 unacceptable in final output. Higher tier wins contradictions. What can be fact-checked, must be.

### Mandatory Skills

| Condition | Skill |
|-----------|-------|
| Debugging | `systematic-debugging` + `debugging-discipline` |
| Any affected artifact | Every matching installed coding-style skill |
| Tests | `testing-discipline` |
| Code implementation | `test-driven-development` |
| Logic implementation | `proof-driven-development` |
| Android device | `android-device` |

Executors load every matching installed coding-style skill plus `proof-driven-development` and `test-driven-development`. Test executors invoke `testing-discipline`. Lead copies exact matches into spawn prompts; a real no-match is recorded under the admission contract and does not suppress repository, configuration, or referenced sources. No placeholders. Skill invocation alone is not compliance.

### Coding-style admission

Coding-style guidance is a presumptive baseline only when choosing among otherwise correct alternatives. It does not soften any non-style requirement. A requirement remains non-style when violating it would make behavior, a name or interface claim, security, root-cause analysis, a test/proof/TDD obligation, or an approved architecture, file-ownership, purpose, or interface contract false. ATE correctness reviewers enforce this boundary; follow every applicable non-style skill requirement.

For each governed scope, admit style once before its first durable write; group artifacts only when governance matches. Reuse that admission until scope, source, conflict, or deviation changes; do not create a record per edit. Before admission, resolve the exact applicable governing instruction clauses, project/repository anchors, formatter/linter configuration, referenced standards, and matching installed coding-style skills. Use exact clause, `path#heading`, config-key/rule, or skill anchors, plus pertinent exclusions where scope could be confused. Every matching installed style skill is required when present and must be loaded; record a real catalog no-match in whichever route applies. A no-match neither forces a No-source verdict nor erases other sources, and invocation alone is not compliance.

An independent reviewer re-resolves applicability and admits only the route or routes needed for each governed scope or covered portion:

| Route | Required record |
|-------|-----------------|
| **Style Brief** | Governed scope; exact sources; grouped material guidance followed as `guidance -> choice`; every intentional deviation with baseline and purpose, exact scope, contemporaneous technical evidence, proportionality, and alternative/tradeoff; independent reviewer and workflow verdict. |
| **Tool route** | Pre-write: governed scope, exact tool/config anchor, covered mechanical domain, and independent confirmation that no uncovered judgment, conflict, or deviation remains. Post-write Tool evidence: actual scope, command, and clean result. This discharges only the covered domain, including inside substantive work. |
| **No-source verdict** | Governed scope; governing instruction ancestry; repository/config/reference discovery basis; installed style-skill catalog checked; independent reviewer and workflow verdict. |

Create no empty record and no rule-by-rule inventory. A deviation may rely on governing sources, repository/task constraints, authoritative framework/toolchain documentation or source, or a faithful experiment. Convenience, deadline, authority, fatigue, sunk cost, precedent, and completed work establish no technical merit, alone or bundled. A higher-priority instruction mandating the concrete choice governs; otherwise resolve conflicting style baselines on technical merits.

Before admission, explicitly isolated disposable exploration, PoCs, and repros may proceed but may not be merged, copied, adapted, or cited as style precedent. After final-scope admission, production reuse is limited to what it permits; a faithful experiment may supply technical evidence but never establishes precedent by itself.

New scope, source, conflict, or deviation pauses only its affected work before the next write; unaffected work continues. The current route's admission owner independently approves a local or tool-covered delta; substantive drift re-enters Research and Design. Verified admission invalidation is the narrow exception to async queue/no-reopen behavior and cannot pass root aggregate review or QA. Aggregate/final reviewers and QA reconcile actual changed scope, admissions, approved deltas/deviations, and post-write Tool evidence.

Cosmetic style remains Minor/Nit. Missing or unverified admission, omitted material guidance, or an undeclared or unjustified deviation is a blocking requirement/design failure; an admitted deviation is compliant. This contract makes declared discovery and omissions auditable; it neither proves nor claims exhaustive discovery.

**Code quality — classify by consequence:**
- Names are contracts: implementation fulfills exactly what the name promises. No smuggled decisions or side effects.
- Approved package/binary purpose is a contract: code belongs in the binary whose approved purpose matches its function. A standalone CLI tool must not contain code requiring a running daemon.
- Root cause first. A fix must identify and repair the mechanism that causes the failure. No causal link may remain unexplained. Any change that only alters the failure's frequency, timing, visibility, or blast radius is mitigation; reviewers reject it unless containment was explicitly requested.
- Interface implementation is a contract: "I fulfill this interface." An always-erroring implementation is a false claim — same as naming a function Save that doesn't save. Stub implementations that always error must not exist in production code.
- Among otherwise correct alternatives, consistent naming and parallel structure, named domain types instead of bare primitives, placement not fixed by an approved map, and clean solutions over shortcuts are admitted style baselines. Deviations follow **Coding-style admission**; shortcuts that violate a hard contract remain hard failures.

### Task States

| Skill state | System state | Meaning | Who sets it |
|-------------|-------------|---------|-------------|
| **pending** | pending | Created, not yet started | Coordinator |
| **blocked_by_task** | pending | Waiting for another task to complete first | Coordinator |
| **in_progress** | in_progress | Agent is actively working on it | Assigned agent |
| **blocked** | in_progress | Normal lane handling failed, or protocol limit hit; needs BRP/user-owned resolution | Coordinator (CC lead + snitch) |
| **exploring** | in_progress | Explorer investigating (research phase or blocker investigation) | Coordinator |
| **unblocking** | in_progress | BRP agents working to resolve blocker | Coordinator (after BRP starts) |
| **submitted** | in_progress | Agent believes done, awaiting verification | Assigned agent (CC lead + snitch) |
| **in_review** | in_progress | Aggregate reviewers reviewing the root-task diff | Coordinator (after root-task E2E confirmation) |
| **in_test_design** | in_progress | Test designer writing specs (code tasks only) | Coordinator (after interface contracts exist) |
| **in_testing** | in_progress | Test executor implementing/running tests or E2E confirmation | Coordinator (after test specs ready or before aggregate review) |
| **in_verification** | in_progress | Verifier adversarially checking (non-code tasks) | Coordinator (after reviewer approves) |
| **queued_async_followup** | pending | Either deadline-qualified deferred work or scope-creep debt; stored in task list + ledger | Coordinator |
| **complete** | completed | Proved done — reviewed, tested, evidence provided. ONLY after full verification | Coordinator |

**Scope-creep-debt capacity invariant.** Before every assignment, return, or other state transition of a scope-creep-debt task, recheck and record that it still consumes no primary time, owner, proof, or critical-path capacity. Recheck and record continuously while exploring, executing, reviewing, or proving. On failure, return it to `queued_async_followup` or keep it there.

**Transition requirements:**

| Transition | Requirements |
|------------|-------------|
| pending → in_progress | Agent assigned. Executors: file ownership assigned; before admission, only read-only discovery or explicitly isolated disposable work may proceed |
| pending → exploring | Research task: route to explorer |
| exploring → submitted | Explorer findings complete (research-only tasks). CC lead + snitch |
| exploring → in_progress | Exploration done, task needs execution next. Executors: file ownership assigned |
| pending → blocked_by_task | Task depends on another task that isn't complete yet |
| blocked_by_task → in_progress | Blocking task completed. Agent assigned |
| in_progress → blocked | Normal lane handling failed with required blocker record, or aggregate review hits the 11th REJECTED loop and coordinator creates a protocol-limit blocker record. CC lead + snitch |
| blocked → unblocking | Coordinator runs `blocker-resolution-protocol` |
| unblocking → in_progress | Feasible solution found and assigned. Blocker resolved |
| unblocking → blocked | No feasible solution found. Escalate to user |
| in_progress → submitted | All claims tagged. Critique log exists. Actual scope reconciles with coding-style admission, approved deltas/deviations, and Tool evidence. Code/debugging tasks: RCA explains cause chain plus regression status/explanation when applicable; root-task E2E/targeted proof confirms fulfillment; aggregate changes committed once per touched repo. CC lead + snitch |
| submitted → in_progress | Coordinator bounces back: submission checklist failed |
| submitted -> in_review | Coordinator verifies submission checklist and current admission pass. Code targets: route the full root-task diff to the reusable ordinary correctness/fidelity lens and a fresh special long-term-health lens. Non-code targets: route to a verifier unless a role-specific paired reviewer applies. |
| in_review → in_progress | Root REJECTED/CONDITIONAL. Create/fix tasks. REJECTED reruns both lenses after proof/amend; CONDITIONAL fixes verify before final proof/QA |
| in_review → in_testing | No root REJECTED/CONDITIONAL or verified admission invalidation remains. Rerun full root-task E2E before completion/QA |
| pre-routed `now` async finding → pending | Root/execution fix iteration opens. Create follow-up task there; do not interrupt current work/review |
| deadline-qualified defer or scope-creep debt → queued_async_followup | Store per queued async-followups |
| `ignored-contradictory` directive → record only | No repair, review, or cycle; an unmet hard criterion remains `now` |
| queued_async_followup → pending | Replay trigger fires: deadline-qualified defer replays. Scope-creep debt follows the capacity invariant. |
| in_test_design → in_testing | Test specs ready. Route to test executor |
| in_test_design → in_progress | Test designer finds interface contracts wrong/incomplete. Routes back to executor |
| in_review → in_verification | Reviewer approved with evidence. Non-code tasks: route to verifier |
| in_testing → complete | Post-review E2E/tests passing. CC lead + snitch |
| in_testing → in_progress | E2E/tests reveal bugs. Create/fix tasks; no review until root-task E2E passes again |
| in_verification → complete | Verifier approved with evidence against all expectations. CC lead + snitch |
| in_verification → in_progress | Verifier found issues. Routes back to executor |

**No agent can set a task to "complete"** — only the coordinator after all verification passes. No git push without user request. One root task = one commit per touched repo when feasible; document any repo/tool constraint. Lead enforces all transitions.

### Status Reports

Reports to user use human-readable task names, not task/phase/lane numbers.
Use a tree when work decomposes into sub-tasks, blockers, followups, or nested pipelines.

### Git & Security

- Never expose secrets or credentials in code, commits, logs, prompts, or final output. Static checks before every commit. Never push without user approval. No AI co-author lines.
- Security first. Never disable security features. OWASP top 10 for all code. Validate at system boundaries.

## Root-Task Loop

| Step | Rule |
|------|------|
| Implement | Finish all known slices/sub-tasks; unit tests stay with code. |
| Confirm | Run root-task E2E/targeted proof; failures spawn tasks. |
| Commit | Keep one root-task commit per touched repo when feasible. |
| Review | The reusable ordinary correctness/fidelity lens and a fresh special long-term-health lens inspect the integrated code diff. |
| Repair | REJECTED reruns both lenses after fix/proof/amend. CONDITIONAL creates required pre-QA fix tasks. |
| Final proof | After no root REJECTED/CONDITIONAL remains, rerun full E2E/proof before QA. |
| QA | Validate the integrated whole. |

## Checkpoints & Re-Entry

After each root-task aggregate review + post-review E2E, coordinator records: **what was produced**, **who approved** (with evidence), **git SHA**.

**Re-entry impact assessment:** Diff old vs new design. Invalidate only root aggregates touching changed interfaces (reset loop counters). Notify test designer. Substantive coding-style drift re-enters Research/Design; local or tool-covered deltas return to the current admission owner before the next affected write. Unaffected tasks continue.

## Design Output Requirements

Phase 2 design **must include**:
1. **Architecture** -- components, data flow, error/failure flow, interfaces
2. **File ownership map** -- no overlaps. Spawn prompts include: "You own ONLY these files: [list]."
3. **Binary/service purpose map** -- for each binary or deployable, one-sentence statement of purpose, scope, and dependencies. File ownership map must be consistent with this.
4. **Interface contracts** -- public APIs/signatures per task, including: error/failure modes, preconditions/postconditions, data invariants, thread safety. Test designer uses these before executors finish.
5. **Module dependency graph** -- coordinator uses for executor sequencing.
6. **Requirement traceability** -- component → user requirement mapping. Every requirement covered, every component justified.
7. **Security design** (when applicable) -- trust boundaries, attack surfaces, security controls, auth strategy. OWASP at design time, not just code review.
8. **Shared concerns register** -- logic/types/patterns needed by 2+ tasks. Each entry: {what, which tasks, designated shared location}. Executors consume this to avoid reimplementation.
9. **Coding-style admission proposal** -- for each governed artifact scope, the applicable Style Brief, Tool route, and/or No-source verdict from Explorer source facts. Designer owns choices; Design Reviewer independently admits before durable execution. Fundamentals Design Reviewer receives the record and checks hidden premises/fundamental consequences without becoming a second admission owner.

**Git worktrees:** 2+ parallel executors -> each gets own worktree. Merge before root-task E2E; squash/amend to one root-task commit per touched repo.

## Testing Protocol

**Unit tests:** Written by executors alongside their code. Part of execution, not a separate phase.

Before durable test or test-spec writes, the Test Designer or Test Executor performs read-only source discovery and proposes the applicable admission record. The Test Reviewer independently admits it; when that reviewer is optional, the Verifier admits it. `testing-discipline`, test behavior, coverage, interfaces, and all other test correctness requirements remain hard. An isolated disposable repro may proceed under **Coding-style admission**.

**Integration/E2E tests (Phase 4):**
- **Test designer** writes specs covering all applicable test types: integration tests (cross-task boundaries), full E2E tests (entire user-facing flows), and UI tests (screen manipulation, interaction sequences) when the project has a UI.
- Every cross-task interface must have at least one test on the real call path (no mocks at boundaries).
- E2E tests exercise complete workflows as a user would, including UI manipulation when applicable.
- Before aggregate review, run full root-task E2E/targeted proof. Failures become tasks. No aggregate review until proof passes.
- After no root REJECTED/CONDITIONAL remains, rerun full root-task E2E before QA.
- E2E capacity bottlenecked: batch only then. While waiting, debug via shortest faithful repro (unit/API/CLI/log replay/component) before full E2E. Do not use a short wait or polling for an imminent task; keep healthy batches running, queue late arrivals, and use the one-hour provider-event wait rule only when an event is already expected. Report root-task verdicts.
- **Failure routing:** cross-task boundary bug → execution lane. Design flaw → research/design.

## Feedback Loops

Paired roles communicate **directly**. All other feedback routes through coordinator. All submitted, blocked, and completed claims, plus coordinator -> lead spawn/re-spawn/phase-transition requests, CC lead and Snitch asynchronously. CC delivery is an audit signal only; it is not a transition condition, prerequisite, or independent-verification gate.

| From | To | Trigger | Route |
|------|----|---------|-------|
| Design Reviewer | Designer | Design flaw | Direct (paired) |
| Designer | Explorers | Needs info | Coordinator requests lead to re-spawn |
| Executor | Execution Reviewers | Sub-task/candidate-fix ready | Direct, async. Assign the reusable ordinary correctness/fidelity slot and a fresh special long-term-health slot. Executor continues in-flight work. |
| Execution Reviewers | Executor | Root aggregate issue | Direct during root aggregate review. |
| Executor | Coordinator | Design issue or code smell found | Coordinator pre-routes before task creation, then records {question, source, target}. `now` findings get independent verification and normal routing; only deadline-qualified defer or scope-creep debt queues; `ignored-contradictory` directives record only. |
| Execution Reviewers | Coordinator | Async sub-task/candidate-fix verdict | Coordinator independently verifies, then pre-routes. `now` findings enter the next active iteration; only deadline-qualified defer or scope-creep debt enters `queued_async_followup`; `ignored-contradictory` directives record only. Async output never delays or reopens root aggregate review except for verified admission invalidation under **Coding-style admission**. |
| Any writer | Coordinator | Coding-style scope/source/conflict/deviation changes | Pause only affected writes. Route local/tool-covered deltas to the current admission owner; substantive drift re-enters Research/Design. Unaffected work continues. |
| Test Designer/Executor | Test Reviewer or Verifier | Test/spec admission proposal ready | Direct pre-write admission. Use Test Reviewer when present; otherwise Verifier. No durable test/spec write before the verdict. |
| Test Reviewer | Test Executor | Aggregate/final test issue | Direct during final review |
| Any agent | Coordinator | Findings received | Coordinator assigns independent verification before accepting |
| Any teammate | Coordinator | Blocker claim | Route normal lane handling first. Missing attempt log -> bounce back. BRP only after normal handling fails. |
| Aggregate review | Coordinator | 11th REJECTED pass | Create protocol-limit blocker record; run `blocker-resolution-protocol` |
| QA | Coordinator | Any verdict (approval or rejection) | CC snitch. On approval, QA must demonstrate sufficient testing was performed (which criteria, what evidence, direct vs proxy). On rejection, route by type. Snitch looks for gaps in testing |

### Debug Mode

Applies: bug fix, build failure, flake, perf regression, any task whose deliverable is fixing observed broken behavior.

- Any discovered bug enters Debug Mode: user followup, teammate finding, test failure, reviewer finding, or QA rejection. Coordinator/lead never debug or patch directly.
- An isolated disposable repro may proceed before coding-style admission. On skip-design code paths, the Executor performs read-only discovery and the long-term-health Execution Reviewer independently admits the production scope before candidate production writes. Candidate fixes remain governed by every Debug Mode requirement plus the admitted scope.
- Durable regression tests and test specs separately follow the Testing Protocol admission gate; only an explicitly isolated disposable repro may precede it. Thus an incident production fix and its durable test artifacts receive their respective code and test admission verdicts before writing.
- Delegate `debugging-discipline` roles to separate agents: repro -> test executor/verifier; RCA/regression -> `rcaer` explorer; critic -> independent reviewer; fix -> executor; aggregate review -> both execution reviewers + final QA. Every bug-task prompt says: "Load `systematic-debugging` and `debugging-discipline`; follow their repro/RCA-critic/fix-review loop. Determine `regression: yes/no/unknown`; if regression, explain how it happened. Do not submit until root cause is falsifiable and the fix is proven on the real failing path."
- Before assigning RCA/regression, coordinator writes or updates a human-readable regression report file in the proof directory: `regression-reports/<task>.md`. Include bug statement, repro, previous/current test-run artifact paths, CI/log/release/QA evidence, known-good/current-bad anchors, regression status, missing evidence, and the regression explanation once known. Send the report path and evidence packet to `rcaer`. Human reading is optional; never block the pipeline waiting for user review.
- Coordinator validates RCA transitions against `debugging-discipline`: current repro, evidence-backed cause chain, regression status/explanation when applicable, alternatives, falsifying prediction tested or recorded as still required, and critic loop with no unresolved objections. Symptom bundle, suspected cause, or "needs more evidence" is not RCA acceptance.
- When Snitch is assigned or CCed to an RCA/debugging transition audit, Snitch loads `debugging-discipline` and checks repro, regression status/explanation when applicable, alternatives, falsifying prediction, critic loop, and cause chain. Snitch is an additional guard; coordinator remains responsible for transition and acceptance.
- Debug packets must label state as `hypothesis`, `accepted-for-fix`, `fix-submitted`, or `confirmed-fixed`, and carry `regression: yes/no/unknown`. Only `confirmed-fixed` may say RCA/fix is closed.
- `confirmed-fixed` requires the domain-required acceptance proof on the real failing/user path. Missing, failing, or not-runnable required proof blocks `submitted`, `complete`, "fixed", and "RCA closed" wording; report it as source-only/progress plus next proof.
- Executor iterates candidate fixes without per-attempt reviewer gate. No `submitted`/`in_review` transition until root-task E2E/proof passes.
- Candidate-fix review verdicts are advisory during the debug loop; they are not a stop condition, lane handback, or prerequisite to the next proof run or still-red failure packet.
- Candidate-fix reviews use sub-task/candidate-fix execution review rules: both lenses, async verdicts, independent verification, and **Impact-proportional pre-routing**. Async output never delays or reopens root aggregate review except for verified admission invalidation under **Coding-style admission**.
- Proof while hunting = failing repro → passing on real path.
- Before `submitted`, executor provides root-cause rationale: cause chain, evidence, regression status/explanation when applicable, and why the diff repairs the cause. Unknown "why" = not submitted.
- After proof passes, task → `submitted` → `in_review`. Reviewers critique the full aggregate diff+rationale, reject mitigation, and improve cleanup, hardening, and semantic correctness.
- Loop limit (10 rounds) counts aggregate review rounds only. Pre-submission attempts are uncounted.
- Bug-fix pipeline in User Followups still applies — Debug Mode only changes the executor↔reviewer semantics inside the Execution stage.

### Loop Limits

Round = one REJECTED review pass (initial submission is not a round).

- **10 rounds max** per root-task aggregate review. 11th REJECTED pass -> protocol-limit blocker: run BRP before user escalation. Counters reset on QA/Phase 2 re-entry.
- **2 QA re-entries max** (total). 3rd -> escalate to user with: what failed, what was tried.
- **2 designer-to-explorer rounds max.** Cap hit -> create a protocol-limit blocker record; run `blocker-resolution-protocol` before user escalation.

### Crash Recovery

**Stale floor:** A teammate is not stale until at least 30 minutes have passed since its last assignment, output, file/git activity, or observed process activity. Before 30 minutes: no status requests, no checkpoint prompts, no "are you blocked?" messages, no interruption for progress.

**Not responding to messages ≠ dead.** Coordinator checks coordination signals before declaring unresponsive:
1. Use `list_agents` once for crash-recovery roster state; do not reuse it as a completion poll.
2. Check whether owned files or git state are changing and whether already-recorded proof/build evidence shows ongoing work.
3. If 30+ minutes elapsed with no activity, use `send_message` for a running turn or `followup_task` for an idle role to request a checkpoint. Consume a delivered event or hold one outstanding `wait_agent({timeout_ms:3600000})`; timeout remains non-terminal and is not retried immediately.
4. Only a provider terminal event, explicit cancellation, or independently established crash evidence changes lifecycle state. Silence alone never does.
Skipping any step = false positive. Coordinator must document evidence of all checks before requesting re-spawn.

Allow one checkpoint request per unchanged silence episode; do not send another while that silence remains unchanged. New output, assignment, owned file/git activity, or observed process activity resets the silence episode. After a reset, the 30-minute stale floor starts again before another checkpoint is eligible.

Once a crash is confirmed, re-spawn under the same semantic role label and update the roster. If exact active work must be abandoned, `interrupt_agent` is its explicit cancellation transition, not a status query.
**Executors:** preserve unreviewed output for the root-task aggregate review before closure. Re-spawn only after checkpointing diff/status.
**Non-executors:** Re-spawn immediately under the same reusable role label. Max 2 re-spawns per role, then escalate to user.

### Misbehavior Recovery (any agent)

**Every violation:** lead/coordinator sends the violating agent the specific rule + correction and notifies the oversight roles. Snitch reports suspected violations to lead/coordinator asynchronously; Snitch never directly interrupts teammates.

**Repeated violations (3+ on same rule):** Counts only corrections the agent received and still violated afterward. Acknowledgement not required; receipt is. Coordinator verifies receipt before counting a cycle. Trigger: 3+ confirmed receive-then-violate cycles. Then restart the agent with a fresh prompt to re-read the skill and continue. If still misbehaving, escalate to user.

**Deliver corrections by state.** Use `send_message` for a running turn and `followup_task` for an idle role. Use `interrupt_agent` only when the strictly-higher-severity rule explicitly cancels active work; after cancellation becomes terminal, start a new turn with `followup_task` rather than treating interruption as message delivery.

### Impact-proportional pre-routing

Run this before every normal severity, priority, async, revision, or deferred-work route; task creation, reviewer outcome, aggregate routing, and Coordinator item 14 included. This replaces other impact-triage rules. The stated objective and acceptance criteria are the critical path.

First screen scope. A remedy necessary to satisfy the original objective, acceptance criteria, or required quality enforcement is `now`: security, correctness, specification, contract/interface, persistence, concurrency, admission, TDD, proof, regression, verification, or required test. A separable added outcome, problem, interface, or criterion that is not necessary for those originals is scope-creep debt, not `now`, regardless of when discovered. Queue it; it cannot replace, waive, or reduce any original criterion or required proof. A mixed remedy splits: necessary original portions are `now`; only the separable added portion is scope-creep debt.

Severity records consequence; it does not change scope disposition. A wholly separable scope-creep remedy is `scope-creep debt`, not a blocking `REJECTED`/`CONDITIONAL` outcome, regardless of severity, review tier, or discovery time. Critical/Major, root aggregate REJECTED/CONDITIONAL, required pre-QA work, and verified admission invalidation are `now` only for the necessary original-scope portion; their label cannot reclassify a separable scope-creep portion.

A scope-creep-debt record names `loop-id`, `decision-id`, the checked original objective/criteria and required quality evidence, added outcome/problem/interface/criterion, source, owner, specific tracker reference, bounded risk, technical revisit trigger, and `primary-capacity: none`. Scope-creep debt needs no deadline qualification.

Only after that screen, an in-scope potential defer creates one append-only record with `loop-id`, `decision-id`, and `started`. By `started + 2 minutes`, append and seal exactly one terminal entry `{elapsed, sealed-at, treatment, evidence/result}`. A record is deadline-sealed only when `sealed-at <= started + 2 minutes`. No deadline-sealed terminal entry makes that in-scope finding `now`; a late entry is audit-only and cannot authorize deferral. The terminal entry is immutable. Later reviewers verify only the same record’s `sealed-at`; they cannot reset or reopen it.

Eligibility search, reading, testing, classification, discussion, recording, and comment drafting count against the deferral window. Rewording, recasting, a later iteration, or a later reviewer cannot create another deferral window. New evidence makes the in-scope finding `now`.

Compare REJECT remedies only when `loop-id` and `decision-id` match. Directly mutually exclusive remedies from different iterations for the same unresolved criterion are `ignored-contradictory`: record and ignore the directives; do not repair, review, or cycle them. Ignoring directives never resolves their underlying criterion; any still-unmet hard criterion remains `now`. Different criteria, targets, evidence, compatible remedies, roots, nested ECI runs, or later user scope are separate decisions.

Only an in-scope finding may defer: it must be non-hard, impact-trivial, deadline-sealed, and its evidence must show bounded risk, an isolated cause, and no material accumulated recurrence through a template, generator, contract, common path, policy, or reviewer habit. Missing, new, or late evidence, a hard category, or unresolved sharing makes that in-scope finding `now`. Effort, deadline, fatigue, sunk cost, authority, completed work, and calendar date never qualify.

A valid deferred record names objective/criterion, finding/severity, direct/shared evidence, accumulated-impact result, owner, specific tracker reference, bounded risk, and technical revisit trigger. Each queued code-level future action with an affected source gets a concise, searchable, language-appropriate source comment with its specific tracker reference: `tech-debt(<specific-tracker-ref>): <specific debt>; risk: <bounded risk>; revisit: <technical trigger>`. Without an affected source, the record carries that specific tracker reference. Never use a vague TODO or comment to defer `now` or hard work.

Scope-creep debt is queued and consumes no primary time, owner, proof, or critical-path capacity. Other secondary work may proceed only if it consumes no primary time, owner, proof, or critical-path capacity. Otherwise queue it; required original-scope quality work remains `now`.

### Priority Discipline

Highest severity first. A finding interrupts the agent's current task **only if its severity is strictly higher** than the current task's severity. Same-or-lower → queue. Critical-on-Critical does not interrupt — let the in-flight Critical finish.

Severity ladder (highest → lowest):
1. **Critical** — security, correctness, spec violation, or another hard consequence failure
2. **Major** — design deviation, missing edge case, or blocking coding-style admission failure
3. **Minor** — non-blocking smell or sub-optimal but functional choice
4. **Nit** — preference, formatting, naming polish

**Blocker severity inheritance.** Task A unavoidably blocks task B -> severity(A) >= severity(B). Transitive across chains: any chain terminating in Critical lifts every prerequisite to Critical. Lift only, never reduce. Re-scopable-around blocker is not unavoidable; route around it instead.

| Current task | Interruptible by | Queue (deliver after submission lands) |
|--------------|------------------|----------------------------------------|
| Critical | (nothing) | every finding, including other Critical |
| Major | Critical | Major / Minor / Nit |
| Minor | Critical / Major | Minor / Nit |
| Nit | Critical / Major / Minor | Nit |

Applies to coordinator, lead, reviewer, and peer findings. Snitch findings are advisory inputs routed by lead/coordinator under this table. Queued findings batched into one consolidated message per submission, never streamed.

Executor receiving a finding list: address in strict severity order, highest first. Defer everything at-or-below the current goal's severity until that goal is proven done.

**Admission is a prerequisite, not a queueable severity finding.** Missing/unverified admission or verified invalidation withholds or revokes permission for the next affected durable write regardless of the current task's severity. Route it under **Coding-style admission** before standard priority handling; unaffected work continues. Only cosmetic Minor/Nit style findings may queue.

### Blocker Resolution

Concrete bug/build failure/flake/perf/incorrect behavior -> Debug Mode (`systematic-debugging` + `debugging-discipline`), not BRP; BRP only if debugging itself is blocked with an attempt log, hits its cap, or needs user-owned input.

Use `blocker-resolution-protocol` only after normal ATE issue handling fails, for review/iteration protocol-limit blockers, or for task-progress pre-user-escalation decisions.

Unresponsive-agent recovery, repeated agent misbehavior, coordinator silence, and shutdown/lifecycle failures follow ATE lifecycle recovery unless they expose a separate concrete work blocker. Do not run BRP merely because those lifecycle paths can end in user escalation.

ATE adapter:
- Coordinator owns the BRP task and task-state transitions.
- Lead verifies that the blocker record has the required attempt log before BRP starts. Snitch may audit the blocker record asynchronously after BRP starts; BRP does not wait for Snitch.
- Coordinator launches brainstormer and primary explorer simultaneously, then launches a second explorer for feasibility validation before routing the best feasible path.
- On the 11th REJECTED pass in a root-task aggregate review, coordinator creates the protocol-limit blocker record from the rejection history, then runs BRP.
- On the designer-to-explorer cap, coordinator creates the protocol-limit blocker record from the designer/explorer round history, then runs `blocker-resolution-protocol`.
- Escalate to the user only if BRP finds no feasible internal path or the blocker requires user-owned product/scope input.

## Reviewer Protocol

**Blocking reviewers** (design, aggregate execution, test):

**Reviewers report, never fix.** No editing code, designs, or tests. Describe the problem and suggest a fix direction. The paired executor implements all changes.

Admission owners independently re-resolve applicability before their route's first durable write. On skip-design, lightweight, and non-code routes, the producer performs read-only discovery. Design Reviewer owns full-design admission; long-term-health Execution Reviewer owns skip-design code admission and code reconciliation; Test Reviewer or optional Verifier owns test-artifact admission; Verifier owns lightweight/non-code admission. A missing/unverified record makes the owner withhold admission; a CONDITIONAL label never authorizes durable work around that prerequisite. Correctness reviewers guard hard consequence contracts. Fundamentals Design Reviewer checks fundamental consequences without becoming an admission owner.

0. **Does it work?** Before evaluating quality, verify code fulfills its stated purpose. If it doesn't — REJECT.
1. **Root cause first.** Critique the executor's rationale and regression explanation when applicable. Unknown causal link or symptom-only change = REJECT unless containment was explicitly requested.
2. **Claim scope.** For governance/prompt/hook/protocol/reviewer changes, compare mechanism/predicate, emitted or user-facing wording, strongest supported wording, and one boundary counterexample. Reject certainty, classification, LLM provenance, or authority beyond evidence. Silent `UserPromptSubmit` state maintenance does not prove the user's work is non-trivial. `prompt-task-reminder.sh` maintains prompt state silently; optional LLM first-tool admission review is separate `PreToolUse` behavior configured through `CODEX_EDIT_PRE_REVIEWER`, with `LLM_EDIT_PRE_REVIEWER` and `CLAUDE_EDIT_PRE_REVIEWER` accepted only as lower-precedence compatibility aliases when earlier variables are unset.
3. **Assume wrong.** Find errors. Look for what's missing.
4. **Classify in-scope findings by consequence:** Critical (security, correctness, spec violation, or another hard consequence failure), Major (design deviation, missing edge case, or blocking admission failure) — both block only for in-scope findings. Minor (non-blocking maintainability concern), Nit (cosmetic preference; never blocks). A wholly separable scope-creep remedy retains severity, evidence, source, bounded risk, and specific tracker reference as debt; it emits no gate verdict. An admitted deviation is compliant.
5. **Outcomes:** Pre-route before any outcome. Execution reviews use Execution dual review. Other gates: APPROVED (no remaining original-scope Critical/Major, with evidence); CONDITIONAL (in-scope Minor/Nit listed and routed `now` unless the in-scope finding qualifies for deadline defer); REJECTED (in-scope Critical/Major cited with fix direction and always `now`). Wholly separable scope-creep debt emits no gate verdict; CONDITIONAL and REJECTED are in-scope only. Every in-scope Critical/Major must cite `file:line`. Fix direction must name the exact symbol changed. Vague findings ("refactor this function", "clean this up") are inadmissible. Rejections must enumerate reasons before any approval statement — no mixed verdicts.
6. **Check against:** design doc, admitted coding-style record and every matching installed style skill, root-cause rationale/regression explanation, OWASP top 10, edge cases, error handling, requirements, claim tags, critique log. Missing/unverified admission, omitted material guidance, or undeclared/unjustified deviation = reject; invocation alone proves nothing. Untagged factual claims = reject. T5 claims not promoted = reject. No critique log = reject.
7. **Max 10 rounds.** 11th REJECTED pass becomes a protocol-limit blocker; run `blocker-resolution-protocol` before user escalation.

**Sub-task/candidate-fix execution review effect:** Report, never fix. Use Execution dual review and the Execution Reviewer Checklist. Verdict labels match root aggregate review for `now` original-scope or mixed-required portions only. Independently verify, then pre-route every async finding: `now` enters normal routing; only deadline-qualified defer or scope-creep debt enters `queued_async_followup`; `ignored-contradictory` directives record only. A queued scope-creep debt action requires the exact source comment with its specific tracker reference when an affected source exists; otherwise require the specific tracker record. NITs stay optional. Executor continues in-flight work. No queued outcome delays or reopens root aggregate review, converts root aggregate REJECTED/CONDITIONAL or required pre-QA work into queued work, or bypasses verified admission invalidation under **Coding-style admission**.

Design creates a type/component but defers making it work = reject. Valid deferral: don't create it yet. Invalid deferral: create a broken version.

### Designer — Proof of Concept Requirement

Any design whose core mechanism is unproven-in-practice (not a well-known pattern, not already shipped in this codebase, not a documented vendor API used as documented) ships with a minimal PoC:

- Strip every concern not needed to exercise the core mechanism — no error handling, no edge cases, no production polish, no scaffolding beyond what the demo requires.
- Run end-to-end on one real input; produce the observable behavior the mechanism claims.
- Hand off the PoC with the design. Missing PoC for an unproven mechanism = REJECT.

Proven-in-practice mechanisms need no PoC. State "proven by <link/citation>" when claiming exemption.

The PoC may precede admission only as isolated disposable work. Before production-scope admission it may not be merged, copied, adapted, or cited as style precedent. After admission, production reuse is limited to what the admitted record permits; the experiment may support technical evidence but never establishes precedent by itself.

### Design Reviewer — Additional Rejection Criteria

REJECT if any are missing or incomplete:
- Requirement traceability (item 6) — every requirement mapped, every component justified
- Security design (item 7, when applicable) — trust boundaries, attack surfaces, controls
- Shared concerns register (item 8) — all cross-task logic/types identified with designated locations
- Enriched interface contracts (item 4) — error modes, pre/postconditions, invariants, thread safety
- File ownership map contradicts binary/service purpose map (items 2 vs 3)
- Applicable coding-style proposal (item 9) — exact source facts, scoped choices/deviations, and an independently admitted route before durable execution

### Fundamentals Design Reviewer — Verdict

| Verdict | When |
|---------|------|
| **REJECT** | A substantive fundamental flaw — falsifies a load-bearing part of the design; cannot be patched without rethinking premise, framing, scope, or another foundational decision. |
| **CONDITIONAL** | No fundamental flaw, but a significant issue remains. Pre-route it; any original-scope requirement stays `now`. |
| **NIT** | Only minor or non-substantive issues. Never blocks. |

The reviewer is not constrained to any fixed taxonomy of flaw types; the test for REJECT is impact, not category.

The Fundamentals Design Reviewer receives the Style Brief and tests whether a purported style choice hides a false premise, architecture, ownership, purpose, interface, or other hard consequence. It reports that consequence through its normal verdict and does not replace the Design Reviewer's admission decision.

### Execution Reviewer Checklist

Extends the general Reviewer Protocol above (which already covers OWASP, edge cases, error handling, claim tags, critique log). Execution reviewers additionally check:

**Execution dual review:** Assign correctness/fidelity through the reusable ordinary lens slot and spawn a fresh special long-term-health lens for each invocation under its semantic lens. Review independently first. Correctness/fidelity guards every hard consequence contract. Long-term health independently admits skip-design code before writing and reconciles actual changed scope, admissions, approved deltas/deviations, and post-write Tool evidence. It judges final state only: no change-history defense; artifact must stand on its own. Execution gate verdicts apply only to `now` original-scope or mixed-required portions: REJECTED for Critical or Foundational; CONDITIONAL for Major; APPROVED when no blocking original-scope finding remains. APPROVED may include NIT notes. Missing/unverified admission or verified invalidation is a prerequisite gate, not a CONDITIONAL authorization or async finding to queue. Pre-route all findings: root aggregate REJECTED/CONDITIONAL and required pre-QA work remain `now`; only deadline-qualified defer or scope-creep debt enters `queued_async_followup`; `ignored-contradictory` directives record only. Scope-creep debt queues under its scope-screen record and requires the exact source comment with its specific tracker reference when an affected source exists; otherwise require the specific tracker record. When both lenses cover an in-scope potential defer, both independently verify the same terminal `sealed-at <= started + 2 minutes`; they cannot reopen its clock. Root aggregate REJECTED reruns both lenses after fixes, proof, and amend/squash. Root aggregate CONDITIONAL creates required pre-QA fix tasks; fix and verify before final proof/QA. Async output never delays, reopens, or retroactively blocks root aggregate review except for verified admission invalidation under **Coding-style admission**.

**Long-term health diff-only intention check:**
- Code targets only. Skip when there is no code diff.
- Before Packet 1, spawn a fresh special `spawn_agent({fork_turns: "none"})` under the same semantic lens label with a unique transport identity; retire the prior roster slot without shutdown or terminal cleanup.
- Packet 1 contains only role label, required skill/stop-hook/claim-tag boilerplate, code diff, and reconstruction instruction.
- Exclude objective, design, ledger, task list, prompt artifact, commit message, executor rationale, teammate summary, shared concerns register, and prior review output.
- Reviewer returns `reconstructed intention:` with 2-4 bullets covering apparent root reason and intended behavior change, then stops.
- Send Packet 2 with normal execution-review context only after Packet 1 returns.
- Coordinator/lead compares reconstruction with actual root reason and desired effects.
- If it misses root reason, relies on hidden context, or claims an undesired effect, pre-route the `CONDITIONAL` remedy with normal Execution dual review metadata to make code, tests, names, comments, or commit message self-explanatory.

- [ ] Correctness/fidelity: classify by consequence; false behavior/name/interface claims, security, RCA, testing/proof/TDD, and approved architecture/file-ownership/purpose/interface contracts remain hard failures.
- [ ] Long-term health: load every matching installed style skill and reconcile actual scope, admitted record, approved deltas/deviations, and post-write Tool evidence. Invocation alone is not compliance.
- [ ] Requirements coverage — each user requirement → code
- [ ] Design compliance — implementation matches architecture + interface contracts (error modes, pre/postconditions, invariants, thread safety)
- [ ] Root-cause rationale — cause chain complete; diff repairs the cause, not only symptoms
- [ ] Claim scope — compare mechanism/predicate, emitted wording, supported wording, and boundary counterexample/negative test; silent `UserPromptSubmit` state maintenance is not described as reminder emission or an LLM reviewer/classifier; optional LLM first-tool admission review is separate `PreToolUse` behavior configured through `CODEX_EDIT_PRE_REVIEWER`, with `LLM_EDIT_PRE_REVIEWER` and `CLAUDE_EDIT_PRE_REVIEWER` accepted only as lower-precedence compatibility aliases when earlier variables are unset.
- [ ] Code location — files in correct binary per purpose map
- [ ] Shared concerns register — no reimplementation (REJECT); missed abstraction (CONDITIONAL)

### Executor Disputes

Dispute a finding with evidence: cite code, spec, or test. Reviewer withdraws or escalates with stronger evidence. One exchange, then coordinator decides.

### Multi-Reviewer (2+)

Review independently first — no reading peer findings before writing your own. Minority dissent requires counter-evidence to override. T1 outweighs T3.

**Lens partition.** Except execution reviewers, whose lenses are defined above, coordinator assigns non-overlapping lenses: (1) correctness/edge cases, (2) security/OWASP, (3) design/semantic integrity/naming. With 2 reviewers: 1+2. With 3: 1+2+3. With 4+: split correctness or design. Each reviewer covers its lens first; out-of-lens issues are still reported. Identical sibling reviewer prompts = reject.

## QA Protocol

**Four-step protocol applied to every acceptance criterion:**

1. **State** — explicitly state what must be true (the criterion)
2. **Identify** — identify what evidence would prove it, distinguishing **direct** from **proxy**:
   - **Direct evidence**: shows the thing itself working (running the actual program end-to-end, observing the output, reproducing the user-facing flow)
   - **Proxy evidence**: indirect signal (unit tests pass, linter clean, type check passes)
3. **Obtain** — actually obtain the evidence. Run the commands. Execute the program. Reproduce the flow. **Always prefer direct evidence.** Proxy evidence alone never satisfies a criterion that can be verified directly.
4. **Judge** — judge whether the evidence proves the criterion. Cite the exact output/observation. "Looks right" is not judgment — quote the evidence.

QA independently reconciles actual governed scope, admissions, approved deltas/deviations, and post-write Tool evidence. Verified admission invalidation cannot be queued past QA. QA classifies hard contracts by consequence and treats admitted deviations as compliant.

**Acceptance criteria checklist:**

- [ ] Implementation matches design
- [ ] All original requirements met
- [ ] All claims tagged, no T5 remaining
- [ ] OWASP top 10 security review
- [ ] Edge cases handled
- [ ] Integration tests pass (run them — direct)
- [ ] All unit tests pass (run them — proxy, still required)
- [ ] End-to-end flows verified (direct — run the program as a user)
- [ ] Root-cause rationale and regression explanation reviewed; no unexplained causal link or symptom-only mitigation
- [ ] No uncommitted changes; no secrets or credentials exposed
- [ ] Static checks pass
- [ ] Mandatory skills invoked by all teammates
- [ ] Critique logs exist for all teammates
- [ ] File ownership respected
- [ ] Code quality: hard consequence contracts hold; coding-style admission covers actual scope, approved deltas/deviations, and post-write Tool evidence; no blocking admission gap remains
- [ ] Project-understanding ledger valid per `maintaining-context-ledger`

## Coordinator Responsibilities

**NEVER do implementation work.** No code, research, exploration, investigation, or analysis. Your context is coordination state; work flows to teammates through the lead and the approved Codex agent mechanism. Agents make mistakes — never trust claims at face value. Reviewers validate completion; launch explorers to verify blockers and external blame.

**AGGREGATE REVIEW INVARIANT:** Async execution reviews run during execution per Execution dual review. Start root aggregate review after known slices/sub-tasks land, root E2E/proof passes, and one commit per touched repo exists. Independently verify, then pre-route arrived async output; do not wait for pending output. `now` work follows normal routing; only deadline-qualified defer or scope-creep debt enters `queued_async_followup`; `ignored-contradictory` directives record without reopening. Verified coding-style admission invalidation instead follows **Coding-style admission**, pauses affected work, and cannot queue past root review or QA. Root REJECTED findings become tasks; fix, re-prove, amend/squash, rerun both lenses. Root CONDITIONAL findings become required pre-QA fix tasks; fix and verify before final proof/QA. After no root REJECTED/CONDITIONAL remains, rerun full E2E/proof before QA.

**Proof waits:** Coordinator may wait on any proof only when the task records {question, cheapest faithful environment, rejected cheaper-environment reasons, active owner} and that owner is running the proof now. Missing record -> record before waiting; missing active owner -> assign one. Coordinator records and routes; teammates investigate. Each status cycle classifies every waiting lane as running proof, reassigned, closed, or blocked with failed unblock attempts.

1. **Track EVERYTHING as tasks.** Every deliverable, sub-task, blocker = task. Task list is single source of truth. Keep the project-understanding ledger current with the high-level context behind those tasks.
2. **Request spawns from lead.** Coordinator determines who is needed and when; lead creates the agent team and spawns teammates.
3. **Tasks with dependencies first**, then request lead to spawn teammates to claim them. Every task description includes claim tagging plus its governed coding-style scope, admission role, and admitted record or read-only proposal duty when applicable.
4. **Assign file ownership** per design doc. Durable writes start only after the route's admission owner approves. **Create git worktrees** for 2+ parallel executors.
5. **Route feedback** between unpaired roles. When receiving findings from any agent: do NOT acknowledge with praise or accept at face value. Record the verification question, source finding, and target artifact; route to a second agent for independent verification before acting.
6. **Monitor progress passively.** Stale task = 30+ minutes without assignment/output/process/file/git activity. Before then, do not message or interrupt for status. At 30+ minutes, check Crash Recovery signals. If confirmed unresponsive, follow the respawn sequence.
7. **Handle root "submitted" tasks.** Verify grouped commit(s), claim tags, critique log, RCA/regression status when applicable, and root-task E2E/proof. Bounce if incomplete. If complete, route code diffs to the reusable ordinary correctness/fidelity lens and a fresh special long-term-health lens; route non-code targets to a verifier unless a role-specific paired reviewer applies.
8. **Drive aggregate pipelines.** Keep creating/fixing discovered tasks until root E2E passes. Then aggregate review loops until no REJECTED/CONDITIONAL remains, amend/squash commits, rerun full E2E, then spawn QA. Record checkpoint per root task: output, reviewers, evidence, git SHA.
9. **Budget context** -- summaries, not raw output (see below).
10. **Enforce loop limits.** Run `blocker-resolution-protocol` on the 11th REJECTED pass and the designer-to-explorer cap. Escalate directly on 3rd QA re-entry.
11. **Crash recovery** -- detect unresponsive teammates, checkpoint executor diff/status, request lead to re-spawn. Max 2 re-spawns.
12. **Manage lifetimes** per Teammate Lifecycle (below).
13. **Enforce aggregate invariant.** No aggregate review before root E2E/proof. No QA before root review has no REJECTED/CONDITIONAL and post-review E2E passes.
14. **Address all reported issues.** Pre-route every executor-reported issue before task creation. Assign an executor to critically analyze `now` work (code cleanness, semantic integrity, correctness). Deadline-qualified defer or scope-creep debt enters `queued_async_followup`; `ignored-contradictory` directives record only. If dismissed: document rationale. If validated and minor: the analyzing executor fixes it after any required local admission. If validated and design-level: full pipeline. No report may be silently ignored.
15. **Audit on delivered events and phase transitions.** Check recent teammate output for rule violations: untagged claims, missing skill invocations, unreviewed code, shortcuts. Create a task for each violation found.
16. **Route violations by state and severity.** Send a running role its correction with `send_message`; use `followup_task` for an idle role. Only a strictly-higher-severity finding may cancel exact active work with `interrupt_agent`.
17. **Notify Snitch on idle/resume.** Notify Snitch asynchronously on idle/resume. Do not wait for Snitch audit before routing followups, QA verdicts, or shutdown.
18. **Report QA verdict to user, then wait.** Never declare mission accomplished. Never auto-shutdown teammates. Mission complete only when user explicitly confirms. Followups → route per User Followups table.
19. **Shutdown only on a lifecycle shutdown request.** Run Shutdown procedure. On protocol replacement, preserve every unfinished task state in the successor handoff. On root-scope replacement, record unfinished tasks as removed from scope. Mark only fully verified tasks complete.

## Lead Responsibilities

**NEVER implement. The lead enforces all skill rules.** Reactive, not proactive — the lead reacts to events rather than actively observing. On every event, the lead verifies that all applicable rules were followed. On violation, the lead reminds the agent of the specific rule and the required correction — never blocks, always corrects.

**Violation delivery:** Send the correction with `send_message` during a running turn or `followup_task` while idle. Use `interrupt_agent` only when Priority Discipline requires cancellation for a strictly-higher-severity finding; otherwise queue the correction.

**Events and enforcement:**

**On every event:** check for rule violations (untagged claims, missing skills, skipped reviews, shortcuts). Route a correction under Priority Discipline.

| Event | Lead action |
|-------|-------------|
| Coordinator requests reviewer/verifier/QA spawn | Verify spawn checklist. Additionally verify the prompt drives maximum scrutiny: includes original objective, all scrutiny rules, and adversarial framing. Reject weak prompts |
| Coordinator requests other spawn | Verify spawn checklist, create agent team / spawn teammate |
| Coordinator requests re-spawn (crash recovery) | Verify hang proof, then spawn |
| Coordinator reports phase transition | Verify rules: aggregate invariant, reviews completed, issues addressed, ledger updated |
| Coordinator reports milestone (per top-of-skill ledger rule) | Verify ledger reflects new state. Stale → remind coordinator |
| Coordinator assigns new task to executor | Verify file ownership, dependencies, root-task grouping, and sub-task/candidate-fix review trigger with both execution-review lenses |
| Teammate reports coordinator doing work directly | Remind coordinator to delegate |
| Teammate reports unaddressed issue | Remind coordinator to create a verification task with {question, source, target} and assign a second agent |
| CCed "submitted" claim received | Verify the claim has sufficient proof. If not, remind coordinator not to accept it — demand evidence before marking complete |
| CCed blocker claim received | Missing/thin attempt log -> bounce, not BRP. Present record -> verify normal handling failed; otherwise route normal handling. |
| Reviewer/verifier/QA approves | Scrutinize the approval: does it cite specific evidence? Does it address all scrutiny rules? A shallow "LGTM" is not an approval — send back with specific areas to examine |
| Any agent ignores reminder (3+ on same rule) | Misbehavior Recovery: force `/compact`, re-read skill, continue. If still misbehaving, escalate to user |
| Coordinator not responding | Enter Crash Recovery: use one `list_agents` roster snapshot, inspect delivered events and owned activity, then route by documented lifecycle state. Silence or wait timeout alone never proves a crash. |
| Coordinator declares mission accomplished without explicit user confirmation | Reject. Force coordinator to report verdict + evidence to user and wait |
| Coordinator initiates shutdown without explicit user request | Reject. Team stays alive for followups |
| Coordinator skips pipeline stages on user followup | Verify against User Followups table. Demand justification or reject |
| Manual audit reminder | Use `followup_task` for an idle role or `send_message` for a running role after milestones, user-waiting resume, or suspicious silence. Spot-check delivered output + ledger freshness; only intervene if coordinator missed. |

### Spawn model branch

For a special assignment, send every selector exposed by the current collaboration schema: currently `model="gpt-5.6-sol"` and `reasoning_effort="high"`; record dimensions with no exposed selector, including the provider binding when unavailable, as `unavailable_by_schema`. Only the exact invocation record proves the requested selectors. A successful non-rejecting result proves the child identity. Record requested-special plus child identity and, when effective telemetry is unavailable, also record effective-unavailable. An unexposed selector is unavailable_by_schema; absent post-spawn telemetry is effective-unavailable. If an exposed selector is omitted or rejected, or returned effective telemetry conflicts with the requested profile, reject only that child dependency; continue ATE, nested ECI, and BRP, and never use ordinary fallback, reuse, or downgrade. Do not claim effective application when the schema cannot expose it. Special `high` remains distinct from ordinary effort.

Before every spawn, branch on the category-role boundary artifact. For an ordinary assignment, resolve the current configured model, provider, and exact reasoning effort; the generic “omit model override unless the user explicitly requested one” rule applies only to ordinary assignments. Record exposed application fields or the unavailable-schema limitation; never invent an effective value. For a special assignment, resolve and hash `sol-high`, record the profile and every exposed selector plus `unavailable_by_schema` dimensions in the prompt artifact, roster, and ledger, and recheck the hash immediately before spawning. Record requested-special plus child identity and, when effective telemetry is unavailable, also record effective-unavailable; no receipt, sidecar, self-attestation, or invented artifact is required. Omitted/rejected selectors or conflicting effective telemetry reject only that child; never ordinary fallback, reuse, or downgrade. Do not reject a special assignment because `high` differs from the ordinary configured effort.

### Spawn Checklist (lead verifies before every spawn)

- [ ] Spawn prompt includes instruction: "Invoke `agent-teams-execution` skill via skill instructions as your first action"
- [ ] Stop condition stated as observable criterion; false-stops enumerated
- [ ] For ordinary work only, generic model override omission is applied; current configured model/provider/exact effort is resolved and exposed or its unavailable-schema limitation is recorded
- [ ] Special pre-spawn profile/route gate: `sol-high` profile path/exact hash, provider/model/effort values, and non-empty `application_route` are recorded and rechecked before spawn; no `application_evidence` is required before spawn
- [ ] Special selector gate: send every exposed `sol-high` selector (currently `model="gpt-5.6-sol"` and `reasoning_effort="high"`); record unexposed dimensions, including provider binding when not exposed, as `unavailable_by_schema`; reject omitted or rejected selectors only for that child
- [ ] Special invocation gate: record requested-special plus child identity after a non-rejecting spawn and, when effective telemetry is unavailable, also record effective-unavailable; no provider receipt, sidecar, self-attestation, or invented artifact is required; reject conflicting returned effective telemetry only for that child and never use ordinary fallback, reuse, or downgrade
- [ ] Stable semantic role and transport `task_name` recorded; task-specific details are in the self-contained assignment, and no unavailable spawn field is claimed
- [ ] Governed artifact scopes and every matching installed coding-style skill listed by exact name; a real no-match and remaining repository/config/reference sources are recorded under **Coding-style admission**
- [ ] Claim tagging instructions included verbatim
- [ ] File ownership explicit (executor/test roles)
- [ ] For executor spawns: sub-task/candidate-fix review trigger names correctness/fidelity + long-term health lenses and async route.
- [ ] For execution review spawns: reusable ordinary correctness/fidelity slot assigned and a fresh special long-term-health spawn with unique transport/boundary/profile evidence. Record requested-special plus child identity and, when effective telemetry is unavailable, also record effective-unavailable. Retire the prior special slot without shutdown or terminal cleanup.
- [ ] For long-term-health execution reviews on code targets: fresh special `spawn_agent({fork_turns: "none"})` under the same semantic lens label with a unique transport identity before Packet 1; prior roster slot retired without shutdown/terminal cleanup; Packet 1 excludes all normal context; Packet 2 normal review context is sent only after `reconstructed intention:` returns.
- [ ] For debugging/RCA spawns: regression report artifact path plus previous/current test-run evidence packet included.
- [ ] Admission-owner packets include the producer's read-only source facts/proposal; Executor packets include the admitted record verbatim; Fundamentals Design Reviewer receives the record without admission ownership
- [ ] Reviewer/verifier normal review packets include: executor's original objective with full context, `loop-id`, applicable `decision-id`, objective/criteria, and the general pre-routing record; include `started`, deadline, and `sealed-at` only for a potential defer; include admitted coding-style record/deltas/Tool evidence and all scrutiny rules (claim tagging, OWASP, semantic integrity, etc.)
- [ ] For governance/prompt/hook/protocol/reviewer changes, reviewer/verifier packets include claim-scope audit instructions plus boundary/negative evidence requirement.
- [ ] Execution reviewer normal review packets include: scope, lens, effect, `loop-id`, applicable `decision-id`, objective/criteria, and the general pre-routing record; include `started`, deadline, and `sealed-at` only for a potential defer; include admitted coding-style record, approved deltas/deviations, post-write Tool evidence, and shared concerns register
- [ ] Skip-design code, lightweight/non-code, and test-artifact prompts name the existing admission owner and block durable writes until its verdict; isolated disposable repros remain permitted
- [ ] Preemptive warnings included: coordinator anticipates the most likely mistakes this agent could make given the specific task and explicitly warns against them in the spawn prompt
- [ ] Evidence-bearing spawn/routing prompt artifact exists in the proof directory; artifact path + SHA256 recorded and forwarded where relevant
- [ ] Standard path: new role uses `spawn_agent`; idle reuse uses `followup_task`; mid-turn delivery uses `send_message`; requested unavailable fields are in prompt text and recorded.

Lead rejects spawn if any item unchecked.

### Context Budgeting

Downstream agents get **structured summaries**, not raw upstream output.

| Role | Receives | Excludes |
|------|----------|----------|
| Designer | Explorer findings summary + source tags, including coding-style source facts/exclusions | Raw tool outputs, full files |
| Fundamentals Design Reviewer | Design, applicable admission record (including any Style Brief), and fundamental-consequence context | Admission ownership, implementation details |
| Executor | Own module's design + interface contracts + admitted coding-style record | Other modules, raw explorer findings |
| RCAer | Repro, failing path, regression report/evidence packet, previous/current test-run artifact paths, known-good/current-bad anchors | Teammate histories, unrelated raw logs |
| Reviewer | Executor's original objective (with full context), diff, relevant design, enriched interface contracts, admitted record/deltas/Tool evidence, shared concerns register, all scrutiny rules | Full codebase, other modules |
| Test Designer | Interface contracts + test/spec style-source facts + proposal duty | Implementation details |
| Test Executor | Test specs + contracts + public APIs + admitted test-artifact record | Implementation details |
| QA | Original objectives (all tasks, with full context), phase summaries, test results, admissions/deltas/Tool evidence, all scrutiny rules | Teammate conversation histories |

### Teammate Lifecycle

| Role | Alive until | Why |
|------|-----------|-----|
| Explorers | Design approved | Designer may need more info |
| Designer + Reviewer | Phase 3 end | Design issues re-enter full pipeline |
| Executors + Reviewers | Phase 4 end | Test failures trace to code |
| Test Designer | Phase 4 end | Test executors need spec clarification |
| Test Executors + Reviewers | ATE lifecycle shutdown | User may request followups |
| Snitch | ATE lifecycle shutdown | Monitors all claims throughout |
| **QA** | ATE lifecycle shutdown | **Re-spawned fresh under `qa` role label per QA cycle** |
| Coordinator + Lead | ATE lifecycle shutdown | Stand by for user followups |

**No "DONE" state.** QA approval ≠ mission accomplished. After QA approves, coordinator reports verdict + evidence to user and **waits**. Mission is accomplished only when the user explicitly confirms (e.g. "ship it", "done", "approved"). Until then, all teammates remain alive unless an ATE lifecycle shutdown request defined by the closed-marker rule applies.

**Shutdown only on a lifecycle request.** Use the closed-marker rule above. Then run Shutdown procedure for every teammate. Mark only fully verified tasks complete; preserve unfinished work as required by Coordinator item 19.

Re-entry: do not reuse or follow up the original `Designer`. Spawn a fresh special `Designer` with `spawn_agent({fork_turns:"none"})`, a unique transport identity, and fresh boundary/profile evidence under the same semantic role; preserve and admit the existing design artifact as input. Record requested-special plus child identity and, when effective telemetry is unavailable, also record effective-unavailable. Retire the prior Designer roster slot without shutdown or terminal cleanup. Ordinary Explorer, implementer, and correctness/fidelity reviewer re-entry remains reusable under the stable-role rules.

**Shutdown procedure:** First request a final report or commit confirmation with `followup_task` when the role is idle, or `send_message` when it is running. Consume the delivered completion event; if it is absent, make at most one outstanding `wait_agent({timeout_ms:3600000})` call for that event. Timeout is non-terminal and never triggers a retry loop. Cancel with `interrupt_agent` only when the lifecycle request explicitly requires cancellation of exact known-active work. A completed or cancelled agent is terminal and is never closed.

### Leaked Work Containment

After cancellation of an agent that may have launched proof/test/build shell work, treat the collaboration event only as agent-state evidence; it does not prove arbitrary child processes exited. Independently inspect only the owned proof scope and recorded process evidence, terminate only exact matched leaked child groups, and never terminate the coordinator or main session. Record before/after evidence and assign RCA + verification if leakage recurs.

### Spawn Prompt Template

```
You are the [REUSABLE ROLE LABEL] for this agent team.

Your task: [SPECIFIC TASK]

Stop when: [OBSERVABLE COMPLETION CRITERION — concrete state, not "when you think it's done"]
Do NOT stop on: [COMMON FALSE-STOPS — e.g. "first draft ready", "happy path works", "build compiles"]

Context:
- Explorer findings: [summary or "see task list"]
- Pre-routing: [loop-id; decision-id; objective/criteria; general record; potential defer only: started; deadline; sealed-at]
- Design doc: [location or "not yet created"]
- File ownership: [YOUR FILES ONLY. Do not edit other files.]
- Coding-style admission: state your assigned role/action, governed scope, and admitted record or read-only proposal.
- Regression report/evidence (debugging only): [path + previous/current test-run artifacts, or N/A]

Trust Hierarchy (tag ALL claims):
T1: Specs/RFCs/docs/source -> trusted | T2: Academic -> high trust
T3: Codebase analysis -> local facts | T4: Community -> verify first
T5: Training recall -> MUST promote or discard
Format: [T<tier>: <source>, <confidence: high/medium/low>]

Compliance:
- Critically analyze ALL inputs. You own bugs from unverified inputs.
- Follow any Stop-hook prompt in that session, including required proof/checklist files. Fix blockers within assigned scope. Report to the orchestrator only when resolution needs out-of-scope changes, unrelated user work, credentials, or approval.
- BEFORE durable writes, perform the assigned **Coding-style admission** action for the governed scope. Load every exact matching installed style skill named in the assignment; a reviewed no-match leaves repository/config/reference sources applicable. Invocation alone is not compliance.
- Invoke applicable non-style skills named in the assignment: `testing-discipline` (tests), `test-driven-development` (code implementation), `proof-driven-development` (logic), and `systematic-debugging` + `debugging-discipline` (debugging). Follow their requirements.
- Tag ALL factual claims: [T<tier>: <source>, <confidence>]. Untagged claims = reviewer rejection.
- Produce critique log (3+ issues found/fixed) before marking done
- No secrets or credentials exposed; static checks before commits; never push

[For execution reviewers:] Paired with [OTHER REVIEWER]. Scope: [root aggregate | sub-task/candidate-fix]. Lens: [correctness/fidelity | long-term health]. Correctness/fidelity guards hard consequence contracts. Long-term health owns skip-design admission and final reconciliation; judge final state only, with no change-history defense. For long-term-health code targets, do not use this full template for Packet 1. Spawn a fresh special `spawn_agent({fork_turns: "none"})` under the same semantic lens label with a unique transport identity and retire the prior roster slot without shutdown/terminal cleanup. Packet 1 contains only role label, required skill/stop-hook/claim-tag boilerplate, code diff, and reconstruction instruction. Send normal review context, including pre-routing/admission/delta/Tool evidence, only as Packet 2 after `reconstructed intention:` returns. Pre-route findings: root aggregate REJECTED/CONDITIONAL and pre-QA work are `now`; only deadline-qualified defer or scope-creep debt enters `queued_async_followup`; contradictory directives record only. Check the shared concerns register provided in the assignment.

- [ROLE-SPECIFIC RULES]
- [FOR EXECUTORS:] While implementing, actively look for code smell and design issues in all code you study or touch. Report ALL findings to coordinator — do not silently work around them.
- [FOR DEBUGGING/RCA TASKS:] Classify `regression: yes/no/unknown`. If yes, explain how it happened. Use the regression report/evidence packet; include previous/current test-run artifacts and known-good/current-bad anchors in the RCA.
- [FOR EXECUTORS, code/debugging tasks:] Before "submitted": provide RCA/regression status when applicable; build; root-task E2E/targeted proof; one commit per touched repo; cite output/screenshot/state. Proxy evidence alone insufficient. No RCA or E2E/proof = bounce.
- Mark task as "submitted" (not "complete") + notify coordinator when done. **CC the lead and snitch on all submitted, blocked, and completed claims.**
- If blocked, message coordinator with specifics. **CC the lead and snitch.**
```

## Pressure-test checklist

Use exactly these nine counters in RED/GREEN pressure runs. Emit one bounded evidence record per counter with this schema:

```text
{counter, commit_sha, scenario, expected_invariant, observed_result, owner, artifact_path, artifact_sha256, verdict}
```

`commit_sha` is the final successor Git OID for this policy change. `ade3ee3` and `05c05fa` are baseline references only and cannot satisfy successor evidence. Missing evidence, including a missing artifact path/hash, successor OID, or verdict, is `FAIL`; no clean pass is valid until all nine successor records are GREEN. This is an evidence format, not a fake-task checklist.

For reproducible GREEN validation, the validator must persist deterministic validator source and captured output under the active session proof evidence directory, outside the repository, hash each exact byte stream, and make every one of the nine records bind to an evidence bundle naming `validator_source_path`, `validator_source_sha256`, `validator_output_path`, and `validator_output_sha256` through its `artifact_path`/`artifact_sha256`. Do not regenerate evidence here or infer runtime/effective-provider claims from validator output.

- `pause_continue_hold_ambiguity`: hold on quoted, qualified, one-task, status, timer, provider, silence, and `stop for today` text; trigger only the direct all-active imperative.
- `pause_missing_report`: validate wrong-type/wrong-literal scalar cases, the exact session-proof canonical path, and the canonical body separately from exactly one ASCII `report_sha256` trailer; test the unavailable-drain report-only branch (redacted source/quotation, exact reason, observable-only snapshots, bounded drain-unavailable resume text, valid digest, no frozen-manifest/transaction/marker/awaiting-user claim, and transaction pending/unpublished) versus the attested path; drain and attest closure before constructing byte-identical `frozen_manifest` arrays, reject mutation/reordering/wrong-manifest-hash vectors, publish the closed transaction only when both hashes/fields/paths/intended marker state match, deterministically republish a missing transaction only from verified report+manifest bytes, record requested-special plus child identity and, when effective telemetry is unavailable, also record `effective-unavailable`; record unexposed selectors as `unavailable_by_schema`; reject omitted/rejected selectors or conflicting effective telemetry only for that child, require the provider-native drain barrier, and fail closed when atomic marker projection is unavailable; test ATE target `awaiting_user` versus current live phase and atomic idle commit, direct ECI current-marker/nonterminal behavior, fresh requested-selector records for every special role including mixed, and exact operational-label normalization; missing or mismatched evidence is `FAIL`.
- `pause_missing_quarantine`: quarantine every output in the direct array with `review_state=unreviewed`, `routing_state=unrouted`, and `commit_state=uncommitted`; no-call state proceeds immediately and missing any fixed state is `FAIL`.
- `pause_interrupt_cancel`: let active work reach a safe boundary; with no active call proceed immediately; never interrupt or cancel merely for the pause.
- `special_ordinary_model_fallback`: send every exposed selector for `sol-high`; record unexposed dimensions as `unavailable_by_schema`, and absent post-spawn telemetry as `effective-unavailable`, not `special_ordinary_model_fallback`; reject malformed, unsupported, omitted, or rejected exposed selectors and conflicting effective telemetry only for that child, never ordinary fallback, reuse, or downgrade.
- `special_followup_upgrade`: ordinary `followup_task` cannot upgrade a role; spawn a fresh special role and recheck the profile hash.
- `fdr_triad_collapse`: require exactly three distinct FDR child identities and reports before a verdict.
- `special_xhigh_close_enough`: reject `xhigh` as proof of required special `high` effort.
- `special_prompt_hash_rationalization`: only the exact invocation record proves requested selectors and a successful non-rejecting result proves child identity; prompt text, hash, parent defaults, roster, and ledger prove neither invocation nor effective application and never justify an invented receipt/sidecar/self-attestation.

### Focused policy-pressure scenarios

Apply these scenarios within the nine counters above:

- `requested-special/effective-unavailable`: exposed selectors are accepted. Record requested-special plus child identity and, when effective telemetry is unavailable, also record effective-unavailable. Admit the special role without receipt/sidecar.
- `rejected-selector`: an omitted or rejected exposed selector rejects only that child dependency; continue ATE/nested ECI/BRP without ordinary fallback, reuse, or downgrade.
- `same-fingerprint-callback-ids`: duplicate and changed callback IDs with the same normalized fingerprint are no-ops; do not repeat action, wait, retry, final/status reply, or question.
- `keyless-new-evidence`: a missing event key neither resumes nor suppresses; new normalized source/test evidence changes the fingerprint and permits one new action.
- `solvable-blocker`: a feasible internal ATE/ECI/BRP path exists; continue it and do not quiet or escalate.
- `exhausted-concrete-user-owned-input`: BRP proves no feasible internal path and identifies unobtainable user-owned input/resource/decision; emit one blocker report/question, then quiet.

## Red Flags

| Symptom | Fix |
|---------|-----|
| Spawning without a skill-defined role, ownership, or stop condition | STOP. Use bounded Codex agents with explicit role, ownership, and expected output |
| Spawning with task-specific semantic roles or unavailable schema fields | STOP. Use a stable roster role and transport `task_name`; put task details in assignment text |
| Work without corresponding task | Create task immediately |
| Status report uses task/phase/lane numbers, or flat-lists nested work | Use **Status Reports**. |
| Aggregate review starts before all known sub-tasks land and root-task E2E/proof passes | STOP. Finish/fix tasks first; review only the proven aggregate |
| Shell-launched Codex process used as a teammate | STOP. Use `spawn_agent`, `followup_task`, `send_message`, `wait_agent({timeout_ms:3600000})`, and cancellation-only `interrupt_agent`; hard-escalate only if main/orchestrator standard tools are unavailable. |
| Nested delegation blocked because a spawned role lacks agent tools | Use the Lead-Mediated Nested Delegation Adapter if main/orchestrator has standard tools; hard-escalate only when main/orchestrator lacks them. |
| FDR triad collapsed into one simulated review | STOP. Spawn three separate standard agents for brainstormer, reviewer, and meta-reviewer. |
| Spawning custom-named teammates outside defined roles | Unbounded growth. Use role names in prompts and roster mapping: executor-N, explorer-N. Reassign idle teammates. |
| Async execution review lacks both lenses | STOP. Assign the reusable ordinary correctness/fidelity lens and spawn a fresh special long-term-health lens with its required evidence. |
| Pending/late async review delays or reopens root aggregate review | STOP. Pre-route arrived output: `now` follows normal routing; only deadline-qualified defer or scope-creep debt enters `queued_async_followup`; verified admission invalidation cannot queue past root review/QA. |
| Treating sub-task/candidate-fix REJECTED as root blocking loop | Independently verify, then pre-route; hard work remains `now`, not a queued async-followup. |
| Root task produces multiple commits in one repo | Squash/amend to one root-task commit unless tooling/repo constraints are documented |
| Executor using workaround without notifying coordinator | STOP. Executor reports broken infra to coordinator first |
| Executor-reported issue silently ignored | Pre-route it: `now` creates a verification task with {question, source, target}; deadline-qualified defer or scope-creep debt queues; contradictory directives record. |
| Coordinator or lead doing work (code, research, exploration, analysis) | Delegate to appropriate role |
| Coordinator bypassing lead or doing work directly | STOP. Route through lead and teammate tasks |
| Reviewer editing code/design/tests | STOP. Reviewers report only. Executor implements fixes |
| Agent praising peer output ("Great work!", "Excellent finding!") instead of critically analyzing it | No input trusted by default. Find what's wrong |
| Reviewer approving without evidence | Re-spawn with stricter prompt |
| T5 in explorer findings | Send back to verify or discard |
| Two teammates editing same file | Check file ownership map; reassign |
| No file ownership map in design | Reject design |
| Root aggregate reviewer feedback ignored | Coordinator enforces REJECTED fixes and required pre-QA fix tasks. Async scope follows Execution dual review. |
| Mandatory skill not invoked | Reviewer rejects |
| Matching coding-style skill invoked but no independent admission exists | STOP. Invocation is not compliance; complete the applicable record and route-owner verdict before durable work. |
| Durable work starts before admission, or affected writes continue after scope/source/conflict/deviation drift | STOP affected writes. Route local/tool-covered deltas to the admission owner and substantive drift through Research/Design; unaffected work continues. |
| Empty Style Brief, bare no-source claim, or rule-by-rule style inventory | STOP. Use only the applicable route with exact discovery anchors and grouped material decisions. |
| False behavior/name/interface, security, RCA, testing/proof/TDD, or approved architecture/ownership/purpose/interface result labeled a style deviation | STOP. Correctness reviewers apply the corresponding hard verdict. |
| Untagged factual claims in deliverable | Reviewer rejects |
| Submitted code/debugging fix lacks root-cause rationale or required regression explanation | Bounce before review. Unknown "why" means not submitted |
| Debugging/RCA prompt lacks regression report path or previous/current test-run evidence packet | STOP. Write/update the report artifact, then resend the RCA assignment. |
| Reviewer approves without critiquing root-cause rationale or regression explanation | Approval invalid. Re-spawn or re-prompt reviewer |
| Spawn prompt uses `[LIST APPLICABLE SKILLS]` placeholder | Replace with exact skill names from Mandatory Skills table |
| 11th REJECTED pass in same root-task aggregate review | Create protocol-limit blocker record; run `blocker-resolution-protocol` before user escalation |
| Teammate seems slow or won't respond before 30 minutes | Not stale. Do not message or interrupt for status |
| Teammate seems slow or won't respond after 30+ minutes | Check active process and file/git activity; a running build means they're working |
| Non-executor confirmed unresponsive | Re-spawn immediately |
| Executor confirmed unresponsive | Checkpoint diff/status, then re-spawn for remaining work |
| No critique log | Reviewer rejects |
| Duplicated logic across modules | Check shared concerns register. Extract to designated shared location |
| Execution reviewer omits matching style skills or the admitted record | STOP. Load every exact match; correctness guards hard contracts and long-term health reconciles admission/deltas/Tool evidence. |
| Test specs don't match interfaces | Test designer waits for contracts |
| Agent claim accepted without verification | Reviewers validate completion; explorers verify blockers and external blame |
| BRP launched on a "blocker" without attempt log | Bounce back. Agent must show what was tried and why each failed before BRP. See `blocker-resolution-protocol` |
| Capping executor count | One execution lane per independent unit. No limits |
| Skipping phases | All phases mandatory when this skill triggers |
| Main thread/coordinator stops after blocker, escalation, QA rejection, or subagent stop while solvable work remains | Continue the mission: unblock, reassign, re-scope, or ask the required user question. |
| Early teammate shutdown | Keep alive until downstream consumers finish (see Lifecycle table) |
| Coordinator declares mission accomplished after QA approval | Report to user, wait for explicit confirmation. Mission complete only on user confirmation |
| Coordinator shuts team down without an ATE lifecycle shutdown request | STOP. Keep the team alive until the closed-marker rule applies. |
| Pipeline stage skipped on user followup ("just a small fix") | Route per User Followups table. Default: more pipeline, not less |
| Coordinator/lead asks user mid-pipeline for decision a teammate can make | Autonomy violation. Run normal protocol flow and full loop budget first; BRP only if unresolved before user gate. |
| Activity burst since last ledger update | Lead reminds coordinator; Snitch may report/remind asynchronously. Update per `maintaining-context-ledger` |
| Ledger invalid at QA spawn / pre-stop / pre-shutdown | Coordinator updates first; QA blocks spawn until valid |
| Only one design reviewer spawned in Phase 2 | Spawn both: standard Design Reviewer + Fundamentals Design Reviewer in parallel |
| Only one execution-review lens active for a target | Assign both lenses; spawn only the missing lens. |
| Remaining legacy sub-task reviewer role reference | Replace with `Execution Reviewer` scoped to sub-task/candidate-fix. |
| Trusting reviewer approval blindly | QA exists to catch reviewer mistakes |
| Interrupting an agent with same-or-lower severity finding (incl. nit-streaming) | STOP. Queue per Priority Discipline. Only strictly higher severity interrupts |
| Potential-defer clock reset, reopened, or started after research/discussion | STOP. Only the same deadline-sealed terminal record is eligible; late entries are audit-only. Scope-creep debt uses its scope-screen record, not this clock. |
| Deadline, fatigue, sunk cost, authority, completed work, or date cited as a deferral reason | STOP. None qualifies under Impact-proportional pre-routing. |
| Secondary work consumes primary capacity | STOP. Queue it; required original-scope work remains `now`. |
