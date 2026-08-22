---
name: explore-critique-implement
description: Use when CODEX selects ECI as the outer workflow or active ATE routes bounded work through ECI
---

# Explore-Critique-Implement

Separate the hand that builds from the hand that tears down. The builder cannot credibly critique its own output.

## When to use

| Use | Skip |
|-----|------|
| Solution space uncertain | Mechanical change with obvious answer and no future behavior risk |
| 2+ plausible approaches | Trivial typo or reformat |
| Correctness is load-bearing | Throwaway experiment |
| Research would reduce uncertainty | Mechanical rename |

**Triviality rule:** Classify by decision complexity and future behavior risk, not diff size, line count, file count, or locality. A single-line or single-file change is non-trivial when it changes instructions, prompts, routing, protocols, public contracts, security, persistence, concurrency, architecture, or reviewer/agent behavior, or when 2+ plausible approaches exist. Skip ECI only when the correct change is mechanical and consequences are obvious, directly verifiable, and carry no future behavior or routing risk.

Maintain a project-understanding ledger for every ECI run. Use the `maintaining-context-ledger` skill for storage path, content schema, update timing, and validity rules.

### Requirement register and lane-lineage contract

At an active ECI root, the coordinator owns one immutable, normalized requirement register in the project-understanding ledger. `register_root_id` is the canonical register root, distinct from `task_root_id`, task-tree display names, lane names, marker roots, and nested-ECI identifiers. Nested ECI inherits the outer ATE register root; an ECI→ATE replacement for the same logical scope carries it, while an unrelated or replaced root gets a new register only after the prior outer scope closes.

Requirement declarations are append-only and immutable:
`{register_root_id, requirement_id, origin:"user", redacted_verbatim_user_text, source_location, redaction_ids}`.
Use root-qualified IDs such as `<session-id>::<register_root_id>::R<n>`; each component is a non-empty lexical token (`[A-Za-z0-9][A-Za-z0-9._-]*`), no component contains `::`, and the numeric suffix is canonical (no leading zero). Reject duplicate IDs or malformed IDs. The declaration preserves all non-secret characters, clause order, scope, qualifiers, and modality. Redact only secrets before persistence/reporting with stable root-scoped placeholders such as `<REDACTED_SECRET_001>`; record source location and never raw secret bytes. When redaction occurs, call the value **redacted verbatim user wording**, not exact wording.

The mutable requirement-state projection is `{requirement_id,state:active|superseded|retired,supersedes,superseded_by,state_event_ref}`. Only active, root-qualified IDs admit new work. Additions create a new active ID; a correction or replacement creates a new active ID and atomically supersedes named old IDs; explicit user withdrawal retires without a successor. Only direct user evidence authorizes these transitions. `project-understanding.md` is the current projection; append capture, old redacted wording, supersession/removal relations, lane creation, owner assignment, and material reroute events to `high_level_log.md`. Affected lanes stop new admission and retire or reroute before any provider call; completed historical lanes retain provenance but cannot authorize new work.

Store the normalized graph once and keep current projections separate:

```text
Lane       = {lane_id,register_root_id,task_root_id,human_name,derivation_kind,
              predecessor_lane_ids:[...],requirement_refs:[...],derivation_reason,
              path_ids:[...]}
Assignment = {assignment_id,lane_id,owner,canonical_status_ref,evidence,admission_binding}
Path       = {path_id,requirement_ref,lane_id,edge_ids:[...]}
Edge       = {edge_id,path_id,seq,register_root_id,from:{kind,id},relation,
              to:{kind,id},reason,evidence:{source_kind,locator,canonical_bytes_sha256}}
```

`Lane` identity and lineage are immutable after admission. `derivation_kind` is `root|child|derived|protocol|reroute`; roots have zero predecessors, ordinary non-roots have one or more ordered predecessors, and a reroute has exactly the superseded lane as its direct predecessor. Aggregate/review/integration lanes may have two or more. Owner-only reassignment with unchanged purpose updates only a new `Assignment` projection and appends a log event; material work-definition change creates a new reroute lane.

Node `kind` is one of `requirement|decision|lane|assignment`; `relation` is one of `authorizes|justifies|derives|precedes|executes|reroutes|evidences`. Validate unique IDs, same-register endpoints, no self/cross-root/duplicate/cyclic edges, no undeclared predecessors, contiguous `seq`, and path endpoints. Every predecessor appears in a path; every requirement ref has one complete path beginning at its user requirement and ending at the current lane/assignment. Edge evidence binds `source_kind`, `locator`, canonical source bytes, and a lowercase SHA-256. Expand complete paths in the current ledger and ordinary assignment packets so the full `requirement → decision/reasoning step → parent/derived lane → executed assignment` chain is visible without duplicating graph objects.

Before `spawn_agent`, `followup_task`, or a `send_message` that starts, changes, or reroutes lane work, and before otherwise-unbound durable execution, perform coordinator admission: update the current ledger projection; verify the existing `high_level_log` prefix; append an EOF PREPARE/admission event; publish and re-read the ledger and latest-status; materialize and hash the prompt artifact; record `admission_binding` as `{register_root_id,lane_id,assignment_id,active_requirement_state_version,expanded_path_sha256,prompt_sha256,ledger_sha256,log_post_append_sha256,log_post_append_size,latest_status_sha256,admission_record_sha256}`; then append and verify COMMIT. This is recoverable coordinator evidence, not an atomic provider transaction. Fail closed before the provider/tool call if any pair/hash is missing or stale.

Validate that every declared object ID resolves uniquely in this register, refs are non-empty active IDs authorized by the same root, predecessors are admitted, ordered, and declared in a complete path, and the chain reaches a user requirement. A child’s refs are a subset of its root-authorized set. A running agent may submit only a non-executable proposal `{proposal_id,source_lane_id,register_root_id,kind,requirement_refs,predecessor_lane_ids,derivation_reason,evidence}`. If the proposal is necessary for the existing objective/acceptance, the coordinator independently admits a derived lane through the same graph/pair binding; missing refs alone do not prove new scope. A genuinely new outcome/scope or proposal without a user ancestor remains scope-creep debt: no lane, provider call, or status change. Direct user authorization first creates a new declaration.

Lineage admission failure leaves existing task/lane status unchanged and is a routing risk/next action, never `PAUSED`, `BLOCKED`, BRP, or a lifecycle phase. ATE owns canonical status for nested ECI. Do not add lineage fields to closed pause snapshots, required-critic manifests, marker schemas, or task-state schemas. Assignment packets, routing messages, Step 1–4 packets, spawn checklists, reviewer prompts, reusable-producer reassignments, and discovered-work proposals carry the structured lane, paths/edge evidence, register root, active-state version, assignment/admission binding, and expanded full chain before execution. Critic C Packet 1 still requires lineage admission, current project-understanding ledger/high_level_log pair verification, exact prompt-artifact creation, and any required provider/profile/identity checks before spawning; these remain coordinator evidence, not Packet 1 body fields. Only lineage serialization and normal review context are omitted from its body. Packet 2 carries the full register, graph/paths/edge evidence, admission binding, and context.

## Codex adapter

- Start ECI only when CODEX selects it as the outer workflow or active ATE routes bounded work through it. Loading this skill alone does not start ECI.
- ECI includes its required spawned agents.
- A request to use ATE while ECI is active, or to cancel, withdraw, or replace ECI's root scope, is user closure for ECI teardown. Checkpoint unfinished work and record its successor handoff or scope removal before using `user-closed:`.
- Codex uses `spawn_agent`, `followup_task`, `send_message`, `wait_agent({timeout_ms:3600000})`, and `interrupt_agent` according to the lifecycle below. These are provider-native transitions, not aliases for another provider's team controls.
- Codex ECI uses standard agent management tools only. Do not launch shell-wrapped Codex agents. If `spawn_agent` or related agent tools are unavailable, ECI cannot run; hard-escalate to the user.

### Stop-loop recovery

`LOOP DETECTED` text emitted by a stop hook is control metadata, never a new user request. While an active marker exists, Stop normally returns the fast `decision:block` response. The sole exception is a validated direct-session `eci_wait` state, which returns `continue` while ECI remains active. The hook does not derive event keys, fingerprints, or recovery decisions; it only validates a persisted direct-session wait state against the validated persisted direct-session wait-state schema. Keep loop-recovery state in memory/session-ledger state: derive a stable `blocker_id` from workflow, root, and unmet criterion, and a `state_fingerprint` from normalized cause, capability/schema/profile state, completed outcomes, owner, and exact unblock. Exclude timestamps, event IDs, wording, timer counts, and status formatting. Record each distinct recovery action and outcome once. Run at most one recovery action at a time; after its outcome, route the next feasible distinct ECI/BRP action immediately. `awaiting-event` is allowed only while a named already-running completion is expected. Compare normalized content: a missing event key neither resumes nor suppresses; resume only if state_fingerprint changes because of a completed distinct action/outcome, new source/test evidence, changed tool/schema/profile/resource, or concrete user input. A repeated fingerprint is a no-op for action, wait, retry, final/status reply, or user question. Continue normal ECI and BRP while a feasible internal path exists. Do not bias toward escalation. Quiet only after BRP proves no feasible internal path and the exact missing input, resource, or decision is concrete user-owned and unobtainable; emit one blocker report/question. Provider or tool ownership alone never qualifies. A running expected agent completion remains allowed. `awaiting-event` belongs to the coordinator and is not a hook-marker phase. Nested ECI is owned by outer ATE; normal teardown rules remain unchanged.
Never answer an unchanged stop block—including repeated `ECI_STOP_ACTIVE_ECI` or `ECI_STOP_MARKER_*` diagnostics—with another final/status/question, retry, poll, or Stop attempt. Perform at most one distinct recovery action, or record one concrete user-owned blocker, then wait for new external state.

After BRP proves no feasible internal path and identifies concrete unobtainable user-owned input/resource/decision, the main/orchestrator may create the canonical report at `<current session proof directory>/eci_user_owned_wait.md` and run `~/.codex/bin/eci-active wait <current-session-proof-directory>/eci_user_owned_wait.md`. The report is exactly nine LF-terminated lines: `# ECI User-Owned Wait`, `state: user-owned-wait`, a safe `blocker_id`, a lowercase 64-hex `state_fingerprint`, `owner: user`, `brp_result: exhausted-no-feasible-internal-path`, `user_owned_input: unobtainable`, an exact `unblock_kind: input|resource|decision`, and a concrete `unblock`. The runtime caps and validates the report, binds the state to its SHA-256 digest, and writes one state while retaining the `eci_active` marker; each stop validates that direct-session state and returns `continue` while it remains, without consuming or deleting it. Only a changed-state `resume` or validated normal `off` clears it. This is coordinator recovery state, not a generic escape hatch or teardown. On materially changed normalized content established by the BRP/session record, the main/orchestrator must run `~/.codex/bin/eci-active resume <new-state-fingerprint>`; runtime accepts only a different supplied lowercase 64-hex fingerprint and does not prove content change itself. The same fingerprint is rejected. Invalid or missing wait state keeps the stop blocked, and normal `off`/clean-pass remains required for teardown.

## Highest-priority pause-all-work guard

Evaluate this guard before every ECI decision or phase/event transition: normal work, blocker handling/BRP, autonomy, review, routing, teardown, and `awaiting_user`. It precedes every other decision below.

Read only the direct current top-level user message. After case and outer-whitespace normalization, trigger only when it equals exactly one of `pause all work`, `stop all work`, or `pause everything`. Exclude every other variant, including quoted, negated, interrogative, conditional, qualified, historical, status, timer, provider, silence, one-task, and `stop for today` text. Do not fuzzy-match or infer intent from other events.

Use the current session proof directory defined by `maintaining-context-ledger`; the only report path is `<current session proof directory>/pause-all-work-report.md`. If top-level-user attribution or the proof directory is unavailable or ambiguous, fail closed through the existing status route and perform no routing. Do not store raw prompt bytes or secrets. A redacted exact quotation of the trigger actually sent, `source: direct current top-level user message`, and a stable session-scoped `report_id` unrelated to prompt content are sufficient evidence. The quotation must preserve which exact trigger was sent—`pause all work`, `stop all work`, or `pause everything`—while the canonical reason normalizes their shared all-work scope.

Pause sequence: stop admitting new routing immediately. Let only a currently executing top-level provider/tool call reach its safe boundary; do not interrupt or cancel it merely for this pause. If no top-level call is active, proceed immediately to the safe-boundary protocol. Hold composite-child and late events for the subsequent drain barrier. Do not start a new call, message, send, spawn, reassign, commit, research, design, test, or arbitrary tool action. At the safe boundary, invoke a provider-native drain/close barrier for the current top-level and composite-child event streams, include every event observed through that barrier, and require an attestation that no further events can arrive; if the provider cannot attest closure, fail closed and do not publish the transaction. Only after the barrier closes, freeze and record the quarantine/late-child manifest, then write and verify the report, then checkpoint/quarantine all in-flight output and verify every frozen entry, then publish and verify the authoritative transaction artifact and project/verify the idempotent ledger, `high_level_log`, latest status, and current marker projections in one outer serialized protocol transaction, with the marker update last. No event observed after the frozen manifest is silently omitted; a post-freeze event is a conflict requiring failed-closed replay. The report must contain the redacted quotation/source, `reason: user explicitly requested an all-work pause`, `scope: all active work`, `impact: intentionally paused, not a technical blocker`, why only the user controls resume/closure, the next explicit all-active resume/closure, active ECI step/iteration, role/task/queue/in-flight/expected-event snapshots, quarantine state, canonical path, stable `report_id`, and its SHA-256 trailer. These are the only protocol-write exceptions. A failed report or transaction write/verification fails closed. Direct ECI remains active and nonterminal with its current marker, step, and iteration; it does not enter `awaiting_user`, stop, or teardown merely for this pause.
If the provider-native drain/closure attestation is unavailable or does not return a verifiable closed-barrier receipt, use the unavailable-drain report-only branch after routing has stopped and the current top-level call has reached its safe boundary (or immediately when no call is active). Write and verify the canonical user-owned lifecycle pause report immediately at `<current session proof directory>/pause-all-work-report.md`, with the exact redacted quotation and `source: direct current top-level user message`, `reason: user explicitly requested an all-work pause`, a bounded `resume_or_closure` stating `drain attestation unavailable; explicit all-active user resume or closure required`, the observable safe-boundary and role/task/queue/in-flight/expected-event snapshots, and only currently observable `late_child_snapshot` and `quarantine_snapshot` entries. Do not freeze or hash a `frozen_manifest`, create or publish a transaction, update a marker, or claim `awaiting_user`; keep the direct ECI marker, step, and iteration active and nonterminal. The report body/trailer and digest remain valid, but the transaction is `pending/unpublished`; present `BLOCKED: user-owned lifecycle pause; owner: user; impact: all active progress intentionally paused; unblock: explicit all-active user resume or closure; target: <ECI report path>; transaction: pending/unpublished (drain attestation unavailable); not technical/BRP`. This is report-only lifecycle handling, not technical BRP and not an attempt-log event; retain only observable records, admit no routing, and require an explicit direct all-active user resume or closure. If the attestation exists and verifies, use the normal freeze/manifest/transaction path above.

Canonical report body (direct ECI only): emit exactly one UTF-8 line per key as `key=<JSON value>\n`, with compact JSON, strict escaping, a final LF, and this fixed top-level order:

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

`workflow_state` is exactly the ordered object `{ate_phase,eci_step,eci_iteration,resume_phase}`. Direct ECI sets `ate_phase` to JSON `null`, records the current marker step and nonnegative iteration in `eci_step`/`eci_iteration`, and records that same step as `resume_phase`; nested ECI state is represented only in `nested_eci_snapshot`. In the unavailable-drain report-only branch, retain the live current ECI marker/step/iteration and do not encode an `awaiting_user` target. Use JSON `null` for any N/A value.

The scalar members are closed: `report_id` is a non-empty session-scoped ASCII string matching `[A-Za-z0-9][A-Za-z0-9._-]*` and unrelated to prompt content; `captured_utc` is an RFC3339 UTC `Z` string; `source` is exactly `direct current top-level user message`; `quotation` is a non-empty redacted UTF-8 string with no raw secrets or control characters and preserves the exact trigger actually sent; `reason` is exactly `user explicitly requested an all-work pause`; `scope` is exactly `all active work`; `impact` is exactly `intentionally paused, not a technical blocker`; `resume_owner` is exactly `user`; `resume_or_closure` is a non-empty redacted UTF-8 string; and `canonical_path` must equal `<current session proof directory>/pause-all-work-report.md` after lexical normalization, rejecting every other absolute path. All other top-level members use the closed schemas below. Wrong JSON types or literals, control characters, noncanonical paths, unknown/duplicate/reordered members, or omitted required members are rejected.
The exact report-path rule is: canonical_path must equal `<current session proof directory>/pause-all-work-report.md` after lexical normalization; every other absolute path is rejected.

Snapshot schemas are closed and exact. Each object uses the listed member order: `role_snapshot` is an array of `{stable_id:string,semantic_role:string,category:exploration-only|design|mixed|implementation,state:string}`; `task_snapshot` is an array of `{stable_id:string,parent_id:string|null,state:string,owner:string}`; `queue_snapshot` is an array of `{stable_id:string,kind:string,state:string}`; `in_flight_snapshot` is an array of `{stable_id:string,top_level_call_id:string,owner:string,state:string}`; `expected_event_snapshot` is an array of `{stable_id:string,provider:string,kind:string,state:string}`; `nested_eci_snapshot` is an array of `{stable_id:string,step:string,iteration:nonnegative integer,marker_state:string}`; `safe_boundary_snapshot` is JSON `null` when no top-level call is active, otherwise exactly the singular ordered object `{top_level_call_id:string,call_type:string,owner:string,state:string}`; `late_child_snapshot` is a direct array of `{event_id:string,producer:string,observed_utc:RFC3339-Z,result:bounded/redacted string}`; and `quarantine_snapshot` is a direct array of `{stable_id:string,artifact_path:string|null,artifact_sha256:string|null,review_state:unreviewed,routing_state:unrouted,commit_state:uncommitted}`. Arrays sort by their stable/event identifier: `stable_id` for role/task/queue/in-flight/expected/nested/quarantine arrays and `event_id` for `late_child_snapshot`; duplicate stable/event IDs are rejected. Every quarantined output carries all three fixed states `review_state=unreviewed`, `routing_state=unrouted`, and `commit_state=uncommitted`; never collapse these fields into one state. Paths are absolute normalized paths; non-null artifact hashes are lowercase 64-hex SHA-256 values; `iteration` is nonnegative; `result` contains no raw child output.

The canonical `frozen_manifest` is the ordered object `{late_child_snapshot,quarantine_snapshot}` whose values are byte-identical copies of the corresponding report arrays, with the exact object and array member order required by those schemas. Serialize it as compact UTF-8 JSON with exactly one final LF and no trailer. `frozen_manifest_sha256` is the lowercase 64-hex SHA-256 over those exact bytes; the verifier reconstructs the object from the report arrays and requires byte equality and hash equality before publishing the transaction. Any mutation, reordered member, changed event, changed artifact, wrong hash, or post-barrier event fails closed.

Reject wrong JSON types or literals, control characters, noncanonical paths, unknown, duplicate, missing, reordered, noncanonical, non-UTF-8, noncompact, or non-final-LF bodies and object members. All paths are absolute normalized paths; UTC uses RFC3339 `Z`. The canonical body is exactly the fixed top-level key list above and excludes `report_sha256`. On disk, write that exact UTF-8 canonical body with its final LF, followed by exactly one ASCII trailer line `report_sha256=<lowercase-64-hex>\n` outside the body. Parse and validate the body and trailer separately; reject any other trailer, unknown field, duplicate/reordered key, noncanonical encoding, or missing/invalid trailer. Recompute lowercase SHA-256 over the body bytes only and require the trailer value to equal it and to equal the `report_sha256` copied into the serialized transaction, project-understanding ledger, `high_level_log`, and `latest-status-report`. The report-level `BLOCKED` line may present this same hash separately; it is not part of the body or digest input. Any mismatch fails closed.

Record `user-owned lifecycle pause`, explicitly not BRP and requiring no BRP attempt log. Do not label this pause `PAUSED` (dependency-only) or technical `BLOCKED`. Direct ECI owns the report, digest, and serialized protocol transaction. The authoritative transaction artifact is `<current session proof directory>/pause-all-work-transaction.<report_id>.json`, keyed by `(report_id,report_sha256)`, with canonical compact UTF-8 JSON, exactly one final LF, and exact ordered fields `{report_id,report_sha256,frozen_manifest_sha256,intended_marker_state,projection_paths}`. `report_id` equals the report's ID; both hashes are lowercase 64-hex and equal the verified report and canonical frozen-manifest hashes; `intended_marker_state` is exactly `active`; and `projection_paths` is the exact ordered object `{ledger,high_level_log,latest_status,marker}` of absolute normalized paths equal to the current session proof ledger, log, status, and direct-ECI marker paths. Reject unknown fields, wrong JSON types/values/hashes/paths, duplicate/reordered/noncanonical members, non-UTF-8, noncompact, or non-final-LF bytes. If the report and frozen manifest verify but this transaction is missing, deterministically republish it from those bytes into `transaction pending`; if either cannot verify, fail closed. Publish it recoverably through a temp sibling plus flush/fsync and atomic rename, or a documented provider-native equivalent; re-read and hash-verify it before projections. Ledger, `high_level_log`, latest status, and marker are idempotent projections: publish and verify the transaction first, then project and verify each, with the marker update last. A crash leaves `transaction pending`; restart re-reads the immutable transaction/report and repairs missing projections before any marker claim, and only all-verified projections are committed. Replays keyed by the tuple never duplicate log entries. If no provider event is expected, do not wait; for one expected event use at most one `wait_agent({timeout_ms:3600000})`, with timeout non-terminal and no auto-retry/resume. Only a direct current top-level user all-active resume/closure instruction changes state; status, timer, and provider events do not. Keep the current marker, step, and iteration; resume that prior step/iteration; only a later explicit closure may enter normal teardown. When ECI is nested under ATE, ECI emits only `nested_eci_snapshot` and does not write a report, digest, transaction, or wait; ATE owns those and routes ECI to its prior step on resume.

The report's `quarantine_snapshot` and `late_child_snapshot` arrays are the frozen pre-application manifest. The drain barrier must complete before the verifier serializes and hashes `frozen_manifest`; include every event observed through the barrier, and never silently omit a post-freeze event. Freeze and record the manifest at the safe boundary before writing the report. After body/trailer and frozen-manifest verification, apply checkpoint/quarantine and verify every quarantine entry's exact `stable_id`, path, hash, and simultaneous fixed states, plus every late-child entry's exact `event_id`, producer, timestamp, and bounded result, before publishing the transaction artifact. The live report remains at `<current session proof directory>/pause-all-work-report.md`; after verification, archive the immutable canonical report at `<current session proof directory>/pause-all-work-report.<report_id>.md`; never overwrite an archive. The transaction artifact is the authoritative commit point; publish and verify it before projecting ledger, log, status, and marker, with marker last. If a crash or retry occurs after report write, transaction publish, or during checkpoint/quarantine/projection, replay the same tuple by re-reading the immutable report and transaction, validating body/trailer/digest and frozen manifest hash, and repairing and re-verifying missing manifest entries and projections before any marker update or log append; markers alone never mean completion. A conflicting body, digest, stale transaction, manifest, or projection fails closed; only a fully verified transaction and all projections can be reused or claim commit. The first `report_id`, snapshots, digest, transaction, and archive are immutable. After resume or closure, create a new `report_id`.

The direct ECI report-level presentation line is exactly; it is a normalized presentation and does not replace the exact trigger quotation/source:

```text
BLOCKED: user-owned lifecycle pause; owner: user; impact: all active progress intentionally paused; unblock: explicit all-active user resume or closure; target: <ECI report path>; report_sha256: <hash>; not technical/BRP
```

This `BLOCKED` line is report-level only. An ECI task marked `blocked` remains a technical/BRP state, and `PAUSED` remains dependency-only.

The report-level example uses `reason: user explicitly requested an all-work pause`; its quotation and source remain the evidence for whether the exact trigger was `pause all work`, `stop all work`, or `pause everything`.

## Prerequisites

Apply the Requirement register and lane-lineage contract before every lane assignment, routing change, and durable execution. Validate the normalized register/graph/assignment projections and complete paths; a non-empty ref never substitutes for the chain, edge evidence, or admission binding.

For coding tasks, every affected agent prompt names the governed scope and every matching installed coding-style skill. A matching skill is required when present and must be loaded before handling that scope; loading it is not evidence of compliance.

### Coding-style admission

Coding-style guidance is a presumptive baseline only when choosing among otherwise correct alternatives. It does not soften any non-style requirement. A requirement remains non-style when violating it would make behavior, a name or interface claim, security, root-cause analysis, a test/proof/TDD obligation, or an approved architecture, file-ownership, purpose, or interface contract false. Follow every applicable non-style skill requirement.

For each governed scope, admit style once before its first durable write; group artifacts only when their governance matches. Reuse that admission until the scope, source, conflict, or deviation changes. Before admission, resolve the exact applicable governing instruction clauses, project/repository anchors, formatter/linter configuration, referenced standards, and matching installed coding-style skills. Use exact clause, `path#heading`, config-key/rule, or skill anchors, plus pertinent exclusions where scope could be confused. Load every matching installed style skill; a no-match result does not erase other sources, and invocation alone is not compliance.

An independent reviewer re-resolves applicability and admits only the route or routes needed for each governed scope or covered portion:

| Route | Required record |
|-------|-----------------|
| **Style Brief** | Governed scope; exact sources; grouped material guidance followed as `guidance -> choice`; every intentional deviation with baseline and purpose, exact scope, contemporaneous technical evidence, proportionality, and alternative/tradeoff; independent reviewer and workflow verdict. |
| **Tool route** | Pre-write: governed scope, exact tool/config anchor, covered mechanical domain, and independent confirmation that no uncovered judgment, conflict, or deviation remains. Post-write: actual scope, command, and clean result. This discharges only the covered domain, including inside substantive work. |
| **No-source verdict** | Governed scope; governing instruction ancestry; repository/config/reference discovery basis; installed style-skill catalog checked; independent reviewer and workflow verdict. |

Create no empty record and no rule-by-rule inventory. A deviation may rely on governing sources, repository/task constraints, authoritative framework/toolchain documentation or source, or a faithful experiment. Convenience, deadline, authority, fatigue, sunk cost, precedent, and completed work establish no technical merit, alone or bundled. A higher-priority instruction mandating the concrete choice governs; otherwise resolve conflicting style baselines on technical merits.

Explicitly disposable exploration, PoCs, and repros may proceed in isolated scope before admission, but may not be merged, copied, adapted, or cited as style precedent. After final-scope admission, reuse is limited to what it permits; a faithful experiment may supply technical evidence but never establishes precedent by itself.

New scope, source, conflict, or deviation pauses only its affected work before the next write. Independently approve a local or tool-covered delta through `critic-step2`; route substantive drift through Steps 1 and 2. Final review independently reconciles actual changed scope, initial admission, approved deltas and deviations, and post-write tool evidence.

Cosmetic style remains NIT. Missing or unverified admission, omitted material guidance, or an undeclared or unjustified deviation is a blocking requirement/design failure; an admitted deviation is compliant. This contract makes declared discovery and omissions auditable; it neither proves nor claims exhaustive discovery.

## Blocker handling

Use `blocker-resolution-protocol` only after normal ECI issue handling cannot resolve a stall, after Step 2 post-bounce all-REJECT outcomes, or after gate/cycle limit hits before hard escalation.

Concrete bug/failure/flake/perf/incorrect behavior -> debugging iteration (`debugging-discipline`), not BRP; BRP only if debugging itself is blocked with an attempt log, hits its cap, or needs user-owned input.

ECI adapter:
- Keep ECI active while resolving blockers.
- Subagent-blocked != mission-blocked. Try normal ECI issue handling first; BRP is last resort before hard escalation.
- Use the separate `brainstormer` role for genuine stalls and Step 2 all-REJECT caps.
- Run a BRP primary explorer and separate `brp-feasibility-validator` before routing brainstormer output onward.
- Feed the blocker record, validated feasible ideas, primary explorer facts, and prior failures into the next explorer or implementer message.
- Use the separate `loop-breaker` role at gate/cycle limits before hard escalation.
- Hard escalation reports the blocker requiring user input; it does not disengage ECI.

## Engagement marker

The PreToolUse gate `~/.codex/hooks/eci-active-gate.sh` denies direct Edit/Write/MultiEdit on the main thread while engaged. Every code change must flow through a spawned agent. Spawned agents write from their own session; the marker is keyed to the orchestrator's session and must not block them.

An ATE `ate_active` marker alone does not engage ECI's required-critic runtime gate. When an ATE route explicitly selects ECI, the coordinator must first create the direct marker with `~/.codex/bin/eci-active on "<task + scope>"`, then keep that marker active through governed work and use the `commit`, `final`, and `off` acceptance boundaries. The ATE marker remains outer lifecycle state; it is not a substitute for the direct ECI marker.

| Step | Command | When |
|------|---------|------|
| Engage | `~/.codex/bin/eci-active on "<task + scope>"` | Before Step 1 of the first iteration |
| Disengage | See Teardown sequence below | Clean pass or user closes ECI through protocol or root-scope replacement |
| Hard escalate | Report blocker requiring user input; marker stays active | ECI cannot proceed without user input |

Do not disengage mid-task to escape the gate — that is the regression this marker exists to catch. If a hand-edit feels necessary, send the work to the persistent `implementer` agent.

## Team setup

**Reusable role** = spawned once with `spawn_agent`, then given a new turn with `followup_task` only while idle. `send_message` delivers information to an already-running turn; it does not start a new turn. ECI reuses producer roles and uses isolated critic identities as described below.

Reusable agents handle Step 1 (explorer) and Step 3 (implementer) across iterations. Each critic-role invocation (Step 2 critic, Critic A coding style, Critic B correctness/fidelity, Critic C long-term health, brainstormer, brp-feasibility-validator, loop-breaker, and E2E) gets a separate blind identity. The producer (explorer/implementer) must never act as critic.

**"Reusable" != "trust prior context".** The reusable agent's spawn-prompt baseline forces fresh-assignment treatment on every `followup_task` (re-read referenced files, no prior-turn trust). Producer-vs-critic separation is identity separation, not a claim that transport reuse clears context.

**Reusable role rule.** Use a stable `task_name` for a reused producer slot and carry the semantic role in its self-contained prompt and roster label. Put changing details (`round`, `gate`, `scope`, `lens`) in the assignment. Do not claim or pass schema fields that `spawn_agent` does not expose.

**Blind critic rule.** Every critic-class invocation is a newly isolated `spawn_agent` with `fork_turns: "none"` and a unique transport `task_name`. Its prompt must be fully self-contained: role label, original requirements when allowed by the packet protocol, exact files/scope, sources to reread, expected output, and all applicable review rules. Never assume the critic inherited orchestrator context. The producer must not be the critic.

### Context-compaction refresh

When ECI is engaged, immediately after the authoritative `PostCompact` compaction refresh signal, the coordinator and lead must re-read this entire `skills/explore-critique-implement/SKILL.md` and re-invoke its instructions before any next decision or tool call. `PostCompact` is the authoritative compaction refresh signal. A `SessionStart` `startup|resume|clear` signal is only a best-effort resume/clear reminder, not proof that compaction occurred; when it arrives while ECI is active, perform the reminder refresh before the next decision.

Codex does not use `CLAUDE_ROLE`, `TeamCreate`, `team_name`, context-clear commands, terminal-agent close operations, or independent shell/CLI agents for ECI. Role identity is carried in the prompt, roster, and provider agent id.

### Spawning

| Action | Command |
|--------|---------|
| Spawn explorer | `spawn_agent({task_name: "explorer", fork_turns: "all", message: <self-contained prompt>})` |
| Spawn implementer | `spawn_agent({task_name: "implementer", fork_turns: "all", message: <self-contained prompt with explicit ownership>})` |
| Reassign idle producer | `followup_task({target: <agent id>, message: <fresh self-contained assignment>})` |
| Deliver to running producer | `send_message({target: <agent id>, message: <bounded in-turn information>})` |
| Spawn any critic / E2E / brainstormer / validator / loop-breaker | New `spawn_agent({task_name: <unique transport name>, fork_turns: "none", message: <self-contained blind prompt>})`; parallel calls where required |

Every spawned agent prompt states the role name, original user requirements, exact scope, expected output, and that other agents may be editing in parallel. For Critic C Packet 1 for code diffs, lineage admission, current project-understanding ledger/high_level_log pair verification, exact prompt-artifact creation, and any required provider/profile/identity checks remain mandatory before spawn. The Packet 1 body contains only role label, stop-hook/reporting boilerplate, code diff, and reconstruction instruction; it omits only serialized lineage and normal review context until Packet 2, which carries the full context.
Every spawned ECI agent prompt must also state: "Follow any Stop-hook prompt in that session, including required proof/checklist files. Fix blockers within assigned scope. Report to the orchestrator only when resolution needs out-of-scope changes, unrelated user work, credentials, or approval."

Before each spawn, followup, or lane-changing message, validate the structured `Lane`, `Path`, and `Edge` records under the Requirement register and lane-lineage contract, then carry `register_root_id`, `task_root_id`, `lane_id`, `assignment_id`, `derivation_kind`, `predecessor_lane_ids`, `requirement_refs`, `derivation_reason`, paths/edge evidence, the active-state version, expanded `requirement_chain`, and `admission_binding` in the assignment packet. A failed admission stops the provider call and leaves status unchanged.

### Special model profile and role boundary

The highly intelligent profile is currently `sol-high`; `sol-high` is an alias, not a model ID. The tracked profile currently contains:

```toml
model = "gpt-5.6-sol"
model_provider = "openai"
model_reasoning_effort = "high"
```

Resolve `${CODEX_HOME:-$HOME/.codex}/sol-high.config.toml`, parse only its top-level keys, hash its exact bytes with SHA-256, and immediately before every fresh special spawn record the profile path, exact profile SHA-256, provider, model, effort, and a non-empty `application_route` descriptor in the prompt artifact, roster, and project-understanding ledger. Send every selector exposed by the current collaboration schema: currently `model="gpt-5.6-sol"` and `reasoning_effort="high"`; record dimensions with no exposed selector, including the provider binding when unavailable, as `unavailable_by_schema`. Future profile and schema values replace these literals. Recheck the profile hash immediately before spawning; if it changed, discard and re-resolve it or create a model-routing blocker.

Only the exact invocation record proves the requested selectors. A successful non-rejecting result proves the child identity. Record requested-special plus child identity and, when effective telemetry is unavailable, also record effective-unavailable. An unexposed selector is unavailable_by_schema; absent post-spawn telemetry is effective-unavailable. If an exposed selector is omitted or rejected, or returned effective telemetry conflicts with the requested profile, reject only that child dependency; continue ECI and BRP, and never use ordinary fallback, reuse, or downgrade. Do not claim effective application when the schema cannot expose it. Ordinary assignments still resolve and record their configured model, provider, and exact effort; special `sol-high` uses `high`, distinct from ordinary effort.

Every assignment artifact and roster entry has exactly one category—`exploration-only`, `design`, `mixed`, or `implementation`—and one semantic role. The independent category-role boundary artifact is canonical UTF-8 compact JSON with exactly one final LF and exactly the ordered fields `{category,semantic_role,authority,required_model_class,artifact_sha256,verdict}`. `artifact_sha256` is the SHA-256 of that same canonical body after substituting a fixed 64-zero sentinel for its `artifact_sha256` value; the verifier substitutes the sentinel and recomputes, while the artifact path and resulting hash are recorded externally in the prompt artifact, roster, and project-understanding ledger. `authority` is the closed enum `non-authoritative|authoritative|combined`; `required_model_class` is `ordinary|special`; `verdict` must be `APPROVED`. Unknown, duplicate, missing, reordered, non-UTF-8, noncompact, non-final-LF, mismatched, or unlisted fields block the spawn.

Normalize operational stable labels exactly before boundary validation: `explorer`→`Explorer`; `researcher`→`researcher`; `brainstormer`→`Brainstormer`; `critic-step2`→`ECI critic-step2`; `critic-A`→`ECI Critic A`; `critic-B`→`ECI Critic B`; `critic-C`→`ECI Critic C`; `e2e-gate`→`E2E gate`; `implementer`→`implementer`; `executor`→`Executor`; `qa`→`QA`; `fdr-reviewer`→`FDR reviewer`; `fdr-meta-reviewer`→`FDR meta-reviewer`; `ate-design-reviewer`→`ATE Design Reviewer`; `ate-meta-reviewer`→`ATE meta-reviewer`; `execution-reviewer-correctness`→`Execution Reviewer: correctness/fidelity`; `execution-reviewer-long-term-health`→`Execution Reviewer: long-term-health`. Unknown labels block. Normalization occurs before exact role, category, authority, and model checks.

The closed semantic-role map and cross-field invariants are: `exploration-only` → `Explorer`, `researcher`, `fact/issue brainstormer`, `Brainstormer`, `brp primary explorer`, `brp-feasibility-validator`, `loop-breaker`, `repro`, `RCAer`, `Snitch`, `Coordinator`, or `Lead`; each requires `authority=non-authoritative` and `required_model_class=ordinary`, and may gather facts, describe candidate architectures/options, compare/rank them, and report evidence but may not author or adjudicate authoritative architecture, interfaces, ownership, components, data flow, or admission. `design` → `Designer`, `Design Reviewer`, `Fundamentals Design Reviewer`, `FDR reviewer`, `FDR meta-reviewer`, `ECI critic-step2`, `ECI Critic C`, `ATE Design Reviewer`, `ATE meta-reviewer`, `authoritative architecture/design`, or `Execution Reviewer: long-term-health`; each requires `authority=authoritative` and `required_model_class=special`. `mixed` is only the explicit semantic role `combined fact-and-authority`; it requires `category=mixed`, `authority=combined`, and `required_model_class=special`, may combine fact gathering with authority only when the assignment explicitly requests that combination, and must never be inferred. `implementation` → `Executor`, `implementer`, `ECI implementer`, `ECI Critic A`, `ECI Critic B`, `Execution Reviewer: correctness/fidelity`, `Test Designer`, `Test Executor`, `Test Reviewer`, `Verifier`, `E2E`, `E2E gate`, or `QA`; each requires `authority=non-authoritative` and `required_model_class=ordinary`. Unknown or ambiguous roles and any cross-field mismatch block. An otherwise ordinary role assigned authoritative architecture/design or long-term-health review must use a fresh boundary artifact and fresh special spawn under the corresponding exact design role; never infer a fallback or upgrade by followup. Reclassification requires a fresh special spawn, never a followup.

Reusable producers keep stable role/transport names. Every special semantic-role spawn—`Designer`, `Design Reviewer`, `Fundamentals Design Reviewer`, FDR special reviewer/meta-reviewer, `ECI critic-step2`, `ECI Critic C`, `ATE Design Reviewer`, `ATE meta-reviewer`, authoritative architecture/design, `mixed`/`combined fact-and-authority`, and `Execution Reviewer: long-term-health`—uses a fresh `spawn_agent({fork_turns:"none"})` with a unique transport identity and fresh boundary/profile evidence. Record requested-special plus child identity and, when effective telemetry is unavailable, also record effective-unavailable. An unexposed selector is unavailable_by_schema, while absent post-spawn telemetry is effective-unavailable. Retire the prior special slot without shutdown or terminal cleanup. ECI blind special critics therefore use fresh unique identities; an ordinary `followup_task` cannot upgrade a role. Ordinary `Explorer`, `implementer`, and `Execution Reviewer: correctness/fidelity` producer slots remain reusable under the stable-role rules; ECI Critic A and ECI Critic B use ordinary models but remain fresh blind critic invocations. FDR obtains exactly three distinct child identities and reports—one ordinary fact/issue brainstormer, one special reviewer, and one special meta-reviewer—with no reuse, collapse, or simulation; no FDR verdict precedes all three reports.

If the current collaboration schema exposes no effective telemetry, record requested-special plus child identity and, when effective telemetry is unavailable, also record effective-unavailable after all exposed selectors are accepted. A selector unavailable because it is unexposed is unavailable_by_schema; absent post-spawn telemetry is effective-unavailable. Missing or rejected exposed selectors and conflicting returned effective telemetry reject only that child dependency; continue ECI/ATE and BRP without ordinary fallback, reuse, or downgrade.

### Explorer spawn-prompt baseline

Per-message body in Step 1.
- Role label per Spawning table.
- "Treat each new task message as a fresh assignment per Step 1 of the ECI skill. Re-read every referenced file each turn — do not trust prior-turn reads."

### Implementer spawn-prompt baseline

Per-message body in Step 3.
- **Implementer role (ECI):** Act as a top-tier open-source maintainer focused on code quality.
- Role label per Spawning table.
- "Treat each new task message as a fresh assignment per Step 3 of the ECI skill. Re-read every file you intend to modify each turn."
- Validated structured `Lane`/`Assignment` records, complete `Path`/`Edge` evidence, the register root and active-state version, expanded requirement chain, and admission binding.
- One commit per logical change.
- Code/debugging submissions include root-cause rationale plus regression status/explanation when applicable: cause chain, evidence, and why the diff repairs the cause. Unknown "why" = unsubmittable.
- Every factual claim in submission carries a T1-T5 tag per CODEX.md Claim Verification protocol. E2E evidence ("tests pass", "build succeeded", screenshots, observed state) cited as T1 with tool output, log path, or screenshot file. Concrete example: "[T1: `go test ./...` exit 0, all 47 pass]" not bare "tests pass". Untagged "all green" = unsubmittable.

## Teardown sequence

Run in this exact order on disengage. Stopping mid-sequence keeps the gate armed.

1. Write disengage-report markdown (content per **Disengage report** below).
2. For an idle implementer, use `followup_task` to request `confirm completed work and a clean tree`; if it is running, use `send_message`. Acceptance-sensitive commits remain coordinator-owned. Observe the delivered completion event or make one outstanding `wait_agent({timeout_ms:3600000})` call for that expected event.
3. Record each role as completed, idle/addressable, cancelled, or still running from delivered status. Use `interrupt_agent` only when the workflow explicitly cancels active work; never use it to close or clean up a terminal agent.
4. Do not close terminal agents. Their terminal status is the lifecycle boundary; timeout or silence is not terminal. A timed-out `wait_agent({timeout_ms:3600000})` must not trigger an immediate retry or polling loop.
5. `~/.codex/bin/eci-active off <report.md>` (LAST — keeps gate armed if teardown fails partway).

If the orchestrator's next Stop blocks, follow the hook prompt and use the disengage report as the verification summary.

### Disengage report

`~/.codex/bin/eci-active off` requires a markdown report walking the stop checklist (`~/.codex/hooks/stop-checklist.md`) and critically analyzing items that could not be fully complied with during the ECI scope. Required sections:

```
## ECI completion certificate
<exactly one of: clean-pass: <evidence> | user-closed: <evidence>>

## Stop checklist walkthrough
- Questions: pass/fail/N-A — <one-line evidence>
- Git: pass/fail/N-A — <one-line evidence>
- Completion: pass/fail/N-A — <one-line evidence>
- Root cause: ...
- Adversarial self-critique: ...
- Assumed blockers: ...
- Rule-compliance self-audit: ...
- Project understanding ledger: ...
- Testing: ...

## Incomplete compliance
- <item> — could not fully comply because <reason>; impact: <what slipped>
- ...
fully-compliant: <reason rule-by-rule>   # only if no incomplete items
```

The bin rejects reports missing `## Stop checklist walkthrough`, `## Incomplete compliance`, non-empty bodies, and exactly one terminal verdict marker: `clean-pass:` or `user-closed:`. Include either all full Codex stop-verification sections or `## ECI completion certificate`. Validation is a content gate, not a wordcount — write substance, not boilerplate.

Full Codex stop-verification sections: `Summary`, `Verification`, `Requirements`, `Root Cause`, `Claim Inventory`, `Pre-Mortem`, `Adversarial Critique`, `Rule-Compliance Self-Audit`, `Gaps`.

## Loop structure

Each iteration tackles one change. All four steps run per iteration. Do not advance to next change until current one passes all steps.

| Step | Phase | Actor | Output |
|------|-------|-------|--------|
| 1 | Explore | Reusable `explorer` agent (`followup_task` while idle) | Ranked options + cited sources |
| 2 | Critique explorations | New blind `critic-step2` agent per round (`fork_turns: "none"`) | Winner with concrete text + tagged CONDITIONAL/NIT list (one explorer revision round permitted on all-REJECT) |
| 3 | Implement | Reusable `implementer` agent (`followup_task` while idle) | One diff |
| 4 | Review gate (parallel) | Critic A coding style + Critic B correctness/fidelity + Critic C long-term health + E2E where code applies | All three critics run concurrently; wait for all critic reports and E2E when applicable |
| Exit | Main thread | Apply / commit / report |

Agent separation: see Red Flags. Main thread orchestrates; agents produce.
**Coordinator role (ECI):** Act as a Meta IC7-level high-level engineer coordinating this workflow.

Every Step 1–4 packet and result carries the validated structured lane graph, assignment projection, complete paths/edges, register root, active-state version, admission binding, and expanded full requirement chain. A child lane, derived fix, protocol/review/proof lane, or material reroute must pass lineage admission before routing; a producer reassignment with unchanged purpose creates only a new assignment projection.

Completion is event-driven. For each expected completion not yet delivered, use at most one outstanding `wait_agent({timeout_ms:3600000})` call. `3600000` milliseconds is the current exposed maximum. If a future schema exposes a different maximum, use that exposed maximum. Never omit `timeout_ms`, rely on its default, or choose a shorter timeout for this wait. A timeout is non-terminal and never causes immediate retry or periodic polling.

### Bug-discovery routing

If any ECI agent, gate, or user followup discovers a concrete bug (failure, flake, perf regression, or incorrect behavior), route the bug through a debugging iteration or nested ECI pipeline. Main thread only coordinates.

An explicitly isolated disposable repro may run before coding-style admission under the contract above. It may supply technical evidence, but a production fix or reuse of repro code waits for admission of the final governed scope.

Map `debugging-discipline` to separate delegated ECI roles: repro -> `repro` worker; RCA/regression -> `rcaer` explorer; critic -> Step 2 critic; fix -> implementer; review -> Critic A/B/C + E2E gate. Every bug prompt says: "Load `debugging-discipline`; follow its repro/RCA-critic/fix-review loop. Determine `regression: yes/no/unknown`; if regression, explain how it happened. Do not submit until root cause is falsifiable and the fix is proven on the real failing path."

Before sending the RCA/regression assignment, write or update a human-readable regression report file: `~/.cache/codex-proof/$SESSION_ID/eci-regression-reports/<task>.md` when `$SESSION_ID` exists; otherwise `./.codex-regression-reports/<task>.md`. Include bug statement, repro, previous/current test-run artifact paths, CI/log/release/QA evidence, known-good/current-bad anchors, regression status, missing evidence, and the regression explanation once known. Send the report path and evidence packet to `rcaer`. Human reading is optional; never block the pipeline waiting for user review.

## Step 1: Explore

Use `followup_task` to start the idle reusable `explorer` role's turn. Use `send_message` only to deliver bounded information while that turn is running. Each fresh assignment body must include:
- The validated `Lane`/`Assignment` record, non-empty root-qualified requirement refs, register root and active-state version, complete paths/edges with evidence, derivation reason, admission binding, and expanded full chain; reject a proposal that does not reach an active user requirement.
- The problem/change for THIS iteration, in full context.
- What's already been tried or ruled out (iterations 2+: include results from prior iterations, current codebase state, and last blocking gate issues verbatim if a prior cycle's gate failed).
- Exact file paths of existing related code — explorer must re-read them this turn to avoid suggesting duplicates. "Re-read referenced files; do not trust prior turn reads."
- For every governed coding scope, resolve applicable style sources and propose only the needed Style Brief, Tool route, and/or No-source verdict under **Coding-style admission**. Step 1 owns the proposal; Step 2 owns admission.
- Required output: ranked options, each with {what, why, where it applies, cost, tradeoffs}.
- Every factual claim in the report must carry a T1-T5 tag per CODEX.md Claim Verification protocol. Primary sources only for T1. Untagged factual claims are not allowed.
- Word cap on the report (default: 1000 words).

### Proof of Concept Requirement

Any proposed option whose core mechanism is unproven-in-practice (not a well-known pattern, not already shipped in this codebase, not a documented vendor API used as documented) ships with a minimal PoC alongside the proposal:

- Strip every concern not needed to exercise the core mechanism — no error handling, no edge cases, no production polish, no scaffolding beyond what the demo requires.
- Run end-to-end on one real input; produce the observable behavior the mechanism claims.
- Explorer attaches the PoC to the option in Step 1. Missing PoC on an unproven option = Step 2 REJECT.

Proven-in-practice mechanisms need no PoC. State "proven by <link/citation>" when claiming exemption.

An isolated disposable PoC may precede coding-style admission, but production reuse waits for the final-scope admission and is limited to what that admission permits. The experiment may be evidence; it is never style precedent.

## Step 2: Critique explorations

Spawn a DIFFERENT agent — not the explorer, implementer, or main thread — with `fork_turns: "none"`. Use a unique transport `task_name` for every blind critic invocation and put the stable semantic role plus round in the self-contained prompt. MUST NOT reuse a producer or prior critic identity for blind critic work.

Carry the target structured lane graph, assignment binding, paths/edge evidence, register/state version, and expanded full requirement chain into the critic packet. Critic C Packet 1 remains diff-only at the body-serialization layer only; the shared admission checks remain mandatory before spawn, and send these fields in Packet 2.

The critic's prompt must include:
- **Designer role (ECI):** Act as a highly skilled principal/staff-level systems designer.
- **Original user requirements verbatim.** The critic must verify options against what the user actually asked for, not just technical soundness.
- **Pre-routing packet and report.** Carry `loop-id`, each `decision-id`, objectives/criteria, and the general pre-routing record; carry `started`, deadline, and `sealed-at` only for a potential defer. Run **Impact-proportional pre-routing** before candidate REJECT/deferral; report the result and record reference. Only `critic-step2` approves a Step 2 deadline-qualified defer after verifying `sealed-at <= started + 2 minutes`; scope-creep debt queues under its scope-screen record; every other in-scope case is `now`.
- **"Step 0 — Independent baseline."** Read the source material (target file, existing code, prior art) and write your own 3-5 bullet assessment BEFORE opening the explorer's report. Include this baseline in the critique output.
- "Assume every suggestion is wrong until you prove otherwise."
- "Read the current state first" (the file/code/doc the explorer was working on) — verify duplication claims independently.
- **Coding-style admission.** Before Step 3, independently re-resolve applicability and either admit the explorer's exact record or issue a REJECT. Do not accept skill invocation, the explorer's conclusion, or a bare no-match/no-source claim as proof. The admitted record is handed to the implementer verbatim.
- **Claim-scope audit for governance/prompt/hook/protocol/reviewer changes:** record mechanism/predicate, emitted or user-facing wording, strongest wording evidence supports, and one boundary counterexample. REJECT certainty, classification, provenance, or authority wording beyond mechanism evidence. Silent `UserPromptSubmit` state maintenance does not prove the user's work is non-trivial. `prompt-task-reminder.sh` maintains prompt state silently. An optional LLM first-tool review is a manual or asynchronous/cached-only auxiliary (`edit-bash-pre-reviewer.sh`); it is deliberately not registered in the synchronous `PreToolUse` chain and must never be awaited by a hook.
- **Cite-verify and tag-discipline protocol:**
  - Untagged factual claim from explorer = REJECT-tagged issue on the option that depends on it.
  - Fetch every T1/T2 URL via WebFetch; use Read for source-code citations.
  - Unfetchable URL (auth-gated, internal, tool unavailable) → flag "unverified — could not fetch" + state whether dependent claim is load-bearing.
  - Load-bearing = any citation justifying picking an option as winner, or justifying a REJECT verdict that bounces an option to the explorer. Load-bearing + unfetchable = issue.
  - Quote the exact supporting passage. Flag hallucinated URLs, misquotes, and training-recall mislabeled as T1.
  - Non-load-bearing citations may be skipped if explicitly marked "non-load-bearing: no verdict depends on this source."
  - T3/T4: sample, not exhaustive.
- Per remaining in-scope issue severity code (table below). Issues attach to specific options. Aggregate per-option verdict = strongest severity.
- **DUPLICATE-of-#N marker** (orthogonal to severity): set when one option restates another option's substance.
- **If at least one option has zero remaining `now` REJECTs**: pick winner from that set with CONCRETE TEXT. Output winner + that option's `treatment: now` fix-text list (verbatim) + pre-routing record references + NITs (informational).
- **If every option has remaining `now` REJECTs**: do not pick. Return those REJECT issues verbatim to orchestrator for bounce per Loop-logic table.
- Single-option explorations get the same adversarial treatment.
- "Be harsh. Most suggestions are noise. Zero survivors is a valid outcome."
- Each retry round uses a clean critic context under the same reusable critic role label.

### Step 2 severity codes

| Code | Meaning | Effect on the option |
|------|---------|----------------------|
| **REJECT** | Option is wrong-shaped: violates user requirements, rests on unsound assumption, lacks a critical capability, or is unfixable without re-exploration | Option cannot be the winner. If ALL options have ≥1 REJECT, see Loop-logic. |
| **CONDITIONAL** | Option is sound; needs a specific tweak the critic spells out as one-or-two lines of fix-text | Option remains viable. `treatment: now` goes to Step 3; a deadline-qualified `defer` or scope-creep debt is recorded below. |
| **NIT** | Soft preference; doesn't affect viability | May be ignored when picking the winner |

Same vocabulary as Step 4; Effect column differs because receiver/artifact/remediation differ per phase.

For coding-style issues, cosmetic preference is NIT; missing or unverified admission, omitted material guidance, or an undeclared or unjustified deviation is REJECT. An admitted deviation is compliant. Classify hard non-style failures by their existing requirement, not as style.

### Impact-proportional pre-routing

Run this before every normal severity, priority, async, revision, or deferred-work route. This replaces other impact-triage rules. The stated objective and acceptance criteria are the critical path.

**Scope screen before severity.** Before coding, pre-route a wholly separable scope-creep remedy as a scope-creep-debt record, not a critic issue, code, or gate verdict. For a mixed remedy, record only the separable added portion as debt; code and gate the necessary original-scope portion.

First screen scope. A remedy necessary to satisfy the original objective, acceptance criteria, or required quality enforcement is `now`: security, correctness, specification, contract/interface, persistence, concurrency, admission, TDD, proof, regression, verification, or required test. A separable added outcome, problem, interface, or criterion that is not necessary for those originals is scope-creep debt, not `now`, regardless of when discovered. Queue it; it cannot replace, waive, or reduce any original criterion or required proof. A mixed remedy splits: necessary original portions are `now`; only the separable added portion is scope-creep debt.

A scope-creep-debt record uses the canonical shared ECI/ATE schema: `loop-id`, `decision-id`, the checked original objective/criteria and required quality evidence, added outcome/problem/interface/criterion, source, `owner`, `primary-owner: none`, `primary-capacity: none`, `tracker-ref`, `bounded-risk`, `revisit-trigger`, `replay-trigger`, and `replay-state: queued|pending|replayed|closed`. `tracker-ref` is specific and searchable; replay fields identify when and how the queued debt may be reconsidered without reopening the original review. Scope-creep debt needs no deadline qualification.

Only after that screen, an in-scope potential defer creates one append-only record with `loop-id`, `decision-id`, and `started`. By `started + 2 minutes`, append and seal exactly one terminal entry `{elapsed, sealed-at, treatment, evidence/result}`. A record is deadline-sealed only when `sealed-at <= started + 2 minutes`. No deadline-sealed terminal entry makes that in-scope finding `now`; a late entry is audit-only and cannot authorize deferral. The terminal entry is immutable. Later reviewers verify only the same record’s `sealed-at`; they cannot reset or reopen it.

Eligibility search, reading, testing, classification, discussion, recording, and comment drafting count against the deferral window. Rewording, recasting, a later iteration, or a later reviewer cannot create another deferral window. New evidence makes the in-scope finding `now`.

Compare REJECT remedies only when `loop-id` and `decision-id` match. Directly mutually exclusive remedies from different iterations for the same unresolved criterion are `ignored-contradictory`: record and ignore the directives; do not repair, review, or cycle them. Ignoring directives never resolves their underlying criterion; any still-unmet hard criterion remains `now`. Different criteria, targets, evidence, compatible remedies, roots, nested ECI runs, or later user scope are separate decisions.

Only an in-scope finding may defer: it must be non-hard, impact-trivial, deadline-sealed, and its evidence must show bounded risk, an isolated cause, and no material accumulated recurrence through a template, generator, contract, common path, policy, or reviewer habit. Missing, new, or late evidence, a hard category, or unresolved sharing makes that in-scope finding `now`. Effort, deadline, fatigue, sunk cost, authority, completed work, and calendar date never qualify.

A valid deferred record names objective/criterion, finding/severity, direct/shared evidence, accumulated-impact result, owner, specific tracker reference, bounded risk, and technical revisit trigger. Each queued code-level future action with an affected source gets a concise, searchable, language-appropriate source comment with its specific tracker reference: `tech-debt(<specific-tracker-ref>): <specific debt>; risk: <bounded risk>; revisit: <technical trigger>`. Without an affected source, the record carries that specific tracker reference. Never use a vague TODO or comment to defer `now` or hard work.

Scope-creep debt is queued and consumes no primary time, owner, proof, or critical-path capacity. Other secondary work may proceed only if it consumes no primary time, owner, proof, or critical-path capacity. Otherwise queue it; required original-scope quality work remains `now`.

### Step 2 loop-logic

| Critic verdict pattern | Action | Output |
|---|---|---|
| ≥1 option with zero remaining `now` REJECTs | Pick highest-ranked clean option as winner | Winner + `treatment: now` fix-text + pre-routing record references + NITs |
| Every option has ≥1 remaining `now` REJECT, round 1 | Bounce verbatim REJECT reasons to the idle explorer with `followup_task`; spawn a new blind `critic-step2` identity for round 2 | Bounce-back |
| Every option has ≥1 remaining `now` REJECT, round 2 | Trigger brainstormer per Brainstormer trigger row; new explorer round | Escalation per Escalation table |
| Only NITs across all options | Pick highest-ranked option directly | Winner + NITs |

**Critic emits issues only.** At hand-off, the orchestrator folds only `treatment: now` fix-text into the Step 3 implementer `followup_task`; deadline-qualified defer or scope-creep debt, and `ignored-contradictory` directives are recorded, not implemented. The critic does NOT rewrite options.

## Step 3: Implement

Use `followup_task` to start the idle reusable `implementer` role's next turn; use `send_message` only for bounded information while that turn is running. One change, one diff per assignment. Code tasks: implementer invokes `test-driven-development` and `debugging-discipline`, loads every matching installed coding-style skill, applies the admitted coding-style record, and re-reads every file it intends to modify on each new task message.

Revalidate the immutable lane graph and mutable assignment binding before each reassignment or durable write. Include root-qualified refs, register/state version, derivation reason, complete paths/edges, admission binding, and expanded chain in the implementer packet; discovered work without authorized ancestry is queued as scope-creep debt, not executed.

Each new task message to `implementer` includes:
- The current iteration's concrete-text from the Step 2 critic (verbatim).
- The current governed scope's admitted coding-style record and reviewer verdict (verbatim), including any approved deltas and applicable Tool route.
- Iterations 2+: prior iteration's gate findings (verbatim) and files changed since the last message.
- Only `treatment: now` fix-list (verbatim, if any) — implementer applies it alongside the concrete text.
- `deadline-qualified defer` or scope-creep-debt records (verbatim) — implementer does not implement deferred/debt work; an affected source gets the exact source comment with its specific tracker reference; otherwise include the specific tracker record.
- Code/debugging submissions include root-cause rationale plus regression status/explanation when applicable. A fix must identify and repair the mechanism that causes the failure. No causal link may remain unexplained. Any change that only alters the failure's frequency, timing, visibility, or blast radius is mitigation unless containment was explicitly requested.
- Submission tags every factual claim. Untagged claim → orchestrator bounces back without spawning the gate (parallel to E2E-evidence rule).

Before the next affected write, the implementer reports any new style scope, source, conflict, or deviation. Continue unaffected work; return a local or tool-covered delta to `critic-step2` for independent approval, and rerun Steps 1 and 2 for substantive drift. Do not create a new record for each edit when the admitted governed scope is unchanged.

**Affected-path E2E before submit.** Runtime behavior reachable via UI/API/device/CLI: build, run full tests, exercise affected user path, cite output/screenshot/state. Proxy evidence alone insufficient. Skip docs, prompts, config-only, tests-only, pure refactors. If E2E unavailable, report BLOCKED with the exact missing resource; missing E2E/rationale → bounce before Step 4.

If applicable E2E evidence is missing, reassign the idle implementer with `followup_task`: "Missing E2E evidence — build, run full suite, exercise user path, cite output/screenshot/state. Do not resubmit without evidence."

## Step 4: Review gate (parallel)

Spawn Critic A, Critic B, and Critic C as new blind critic agents in one parallel message, plus E2E when code applies: each critic uses `fork_turns: "none"`, a unique transport `task_name`, and a self-contained role prompt for `critic-A`, `critic-B`, or `critic-C`; E2E uses `e2e-gate`. Each MUST NOT message the reusable explorer or implementer. Completion is an automatically delivered event; if an expected event has not arrived, keep at most one outstanding `wait_agent({timeout_ms:3600000})` call for it. Timeout never authorizes an immediate retry or polling. All three critic reports are required; the aggregate verdict is withheld until they arrive, and until E2E arrives when code applies. Every normal reviewer prompt includes the **original user requirements verbatim**, `loop-id`, applicable `decision-id`, objectives/criteria, and the general pre-routing record; include `started`, deadline, and `sealed-at` only for a potential defer.

Bind each review/E2E packet to the validated lane graph, assignment/admission binding, and expanded full requirement chain. Critic C Packet 1 remains a closed diff-only body-serialization exception only; admission and prompt-artifact checks still run before spawn, and Packet 2 carries full lineage/context. A lineage-admission failure is a routing defect and leaves implementation/test/prod status semantics unchanged.

**Required-critic admission:** For every governed target—root, subtask, and candidate-fix—the coordinator records one immutable row per required critic using the single canonical v2 manifest and phase/version ledger schema in **Runtime required-critic boundary** below. Do not define an abbreviated parallel row schema. Every spawn request, report, and required E2E artifact binds to the same target, diff, role, child, and gate-phase tuple; missing, stale, contradictory, or unverified rows block implementation acceptance, commit, final gate, and clean teardown and route back to the exact missing fresh critic. This is coordinator/session-ledger evidence, not provider telemetry or a hook runtime artifact.

**Runtime required-critic boundary:** The coordinator writes the bounded canonical `<proof-root>/<session-id>/eci-required-critics.json` manifest with schema `eci-required-critics/v2`, fixed ordered header fields `{schema,current_target_id,current_target_kind,current_diff_artifact,current_diff_sha256,current_target_path,repo_root,git_dir,git_common_dir,base_oid,head_oid,staged_diff_sha256,worktree_diff_sha256,status_sha256,target_file_hashes,acceptance_version,targets,rows}`, and one target record per governed root, subtask, or candidate-fix. Each target has `{target_id,target_kind,diff_artifact,diff_sha256,e2e_required,target_path,target_version}`. Each row adds the live repository/target binding, `gate_phase` (`prewrite|postwrite`), and optional C-prewrite intention fields to the ordered row schema above. At normal `commit`, `final`, and `off` boundaries, `hooks/eci-review-gate.sh` requires exactly one fresh `A:postwrite`, `B:postwrite`, and `C:postwrite` row per target, plus E2E when required. A present `C:prewrite` row is validated as an optional prefix only; it is not required or counted in the postwrite row set. An explicitly selected `prewrite` phase instead requires exactly one `C:prewrite` row with intention evidence. The gate validates exact bytes, lowercase hashes, regular non-symlink artifacts, target/diff bindings, and E2E when required. Reviewer verdict mapping is closed: `APPROVED` serializes to manifest `PASS`; `CONDITIONAL` and `REJECTED` are never admitted. It runs only at main/coordinator commit acceptance, final-proof/QA acceptance, and validated ECI teardown; it never runs on the active Stop fast path. Missing evidence names the exact target and role and routes to one fresh blind identity. Worker/subagent commits remain provisional and cannot establish main-session acceptance. A `PostCompact` signal is a reminder, not proof the skill was reread. After validated `off`, the coordinator atomically publishes `eci-teardown-complete` bound to the session, canonical manifest SHA-256, exact canonical disengage-report path and SHA-256, and the admitted live repository binding tuple before removing the active marker; final-proof validates that terminal receipt against the current tuple and consumes the already-admitted critic identities rather than re-admitting them. Replaying `off` with another report path/hash or after repository drift fails closed; malformed or stale receipt evidence fails closed. Full transcript archival/anti-tamper redesign is scope-creep debt, not required by this lightweight gate. If the legacy `Execution Reviewer` alias is retained, correctness/fidelity maps to Critic B and long-term-health maps to Critic C; it is not a fourth required critic.

The coordinator publishes or replaces that manifest only through the main-owned `~/.codex/bin/eci-active manifest-write <session>/eci-required-critics.json[.source]` route while the direct marker is active. The source is the exact canonical session-directory destination or its directly adjacent `eci-required-critics.json.*` candidate; it is validated as compact schema-v2 bytes and atomically published under the mutation lock. Worker roles are denied this lifecycle mutation; arbitrary paths, shell redirections, and general file-write routes are not manifest publication.

**Runtime v2 enforcement (bounded, non-Stop):** The v2 manifest extends the header and every row with the exact canonical `repo_root`, `git_dir`, `git_common_dir`, base/HEAD OIDs, staged/worktree/status SHA-256 values, `target_path`, `target_version`, and `acceptance_version`; the header also carries `target_file_hashes`. The canonical row fields are `{target_id,target_kind,diff_artifact,diff_sha256,critic_role,gate_phase,child_identity,spawn_request_artifact,spawn_request_sha256,report_artifact,report_sha256,adjudication_artifact,adjudication_sha256,verdict,e2e_required,e2e_artifact,e2e_sha256,repo_root,git_dir,git_common_dir,base_oid,head_oid,staged_diff_sha256,worktree_diff_sha256,status_sha256,target_path,target_version,intention_artifact,intention_sha256,acceptance_version}` in that order. Paths are absolute lexical canonical paths with no `..`, duplicate separators, or symlink components; final artifacts are regular non-symlink files. The gate recomputes the live repository binding at commit/final/off (and, only when explicitly selected, prewrite), rejects alternate repositories, HEAD/index/worktree/status drift, stale target hashes, and out-of-repository targets. `target_file_hashes` must have exactly the governed target-path key set and every value is recomputed. It computes the trusted current diff from `git diff --cached --binary` for staged-only work, `git diff --binary` for dirty-only worktree state, or `git diff --binary <base_oid> <head_oid>` for a clean post-commit snapshot; mixed staged/worktree state is rejected unless represented as its own snapshot. It keeps a prefix-preserving append-only ledger at `<session>/eci-required-critics.<phase>.<acceptance_version>.ledger`: admitted bytes, order, tuples, and versions cannot be mutated, deleted, reordered, or skipped; new subtask/candidate-fix rows append only after the prior prefix verifies. Historical phase/version ledgers are evidence for their snapshot and are not revalidated against later HEAD; a new repository snapshot or repair increments the positive canonical decimal `acceptance_version`.

**Adjudication record details:** The canonical row fields `adjudication_artifact` and `adjudication_sha256` appear immediately after `report_artifact` and `report_sha256`, in the fixed order enforced by the runtime gate. The closed `eci-critic-adjudication/v1` record binds target, role, gate phase, child identity, and exact report hash. `APPROVED` maps only to `accepted`; `CONDITIONAL` or `REJECTED` requires `downgraded` plus a bounded reason. Thus manifest `PASS` never silently erases a non-APPROVED critic report; the record is coordinator evidence, not provider telemetry.
Every report artifact must be bounded text ending with exactly one canonical `eci_critic_verdict: APPROVED|CONDITIONAL|REJECTED` line; the runtime compares that marker to `adjudication.source_verdict`, so a matching hash alone cannot hide a contradictory report. Only the coordinator's explicit `downgraded` decision with a bounded reason can admit a non-APPROVED report.
Report text is UTF-8, bounded, LF-terminated, and permits only tab/LF control bytes; it must contain substantive text before the single terminal verdict marker. Marker-only, malformed-UTF-8, embedded-control, duplicate-marker, or missing-final-LF reports are rejected before adjudication.

**User-authorized Git history/worktree/commit exception:** `git reset` and mutating `git worktree` verbs remain denied by default, and the hidden direct-commit workaround is an exact opt-in operation. A pre-existing, user-created approval artifact may authorize exactly one direct command only when it binds the operation (`reset|worktree|commit`), canonical repository root, canonical Git directory, exact command, bounded reason/timestamp, `authorized_by: user`, and `one_time: true`; the `commit` form is a canonical direct `git commit` invocation with only bounded post-subcommand commit options, no wrapper, assignment, alias, alternate executable, Git context option, shell operator, or substitution. The hook classifies the exact operation first, so approval never converts UNKNOWN or unsafe inherited Git context into an allow; this applies equally to reset and worktree approvals. Without approval, an inactive direct commit remains available and an active-ECI direct commit uses the normal review gate; a valid approval skips only that one active-ECI acceptance gate after canonical classification and approval consumption. It does not fabricate critic/evidence artifacts or bypass identity, path, security, or worker controls. Tracked/indexed approval files are invalid. Atomic claim directories protect one-time replay; only an empty stale orphan beyond the bounded recovery window may be reclaimed. The hook intentionally does not advertise the artifact name or route in denial feedback. The file claim is structural coordinator evidence, not cryptographic proof of who wrote it; only an approval artifact supplied by the user is treated as authorization. This exception is outside the active Stop fast path.

Only the governed target paths must be covered by the current target set; unrelated changed paths are explicit out-of-scope exclusions, never satisfy a critic row, and remain subject to the original scope screen.

The header's `acceptance_version` is authoritative, a positive canonical decimal, and every row must carry the same value. Each phase/version ledger is immutable after its admitted prefix; changing snapshot state requires a new version rather than rewriting history. Every artifact path must already be lexical-canonical (`realpath -m path == path`) and regular/non-symlink, including all intermediate components. Normal `commit`, `final`, and `off` require exactly A/B/C `postwrite` rows. An explicit `prewrite` run is a bounded optional policy prefix: it is allowed only while that phase/version ledger is empty, requires a valid `ECI_PREWRITE_WRITER_SESSION` equal to the canonical gate session id (the Critic C `child_identity` remains a separate fresh reviewer identity), and is rejected after any postwrite admission in that version. A bounded `<session>/eci-acceptance-anchor` fixes the session/repository/base lineage and records phase/version/manifest/diff/target-set admissions append-only; a version cannot reset for an unchanged snapshot, and commit/final/prewrite cannot substitute phases at one version. This is not provider-authenticated evidence: the manifest/ledger records coordinator claims and hashes, prevents omission or stale/contradictory rows, and cannot prove that an external child ran or provide a provider receipt.

`validate-bash` uses strict typed hook input and a tri-state command parser whose default is `unknown`, not read-only. It recognizes only the allowlisted read-only utilities and git subcommands, safe shell syntax checks (`bash|sh|dash|zsh -n <script>`), and explicit `hooks/tests` entry points; arbitrary Python, Make, shell scripts, mutating utilities, and git aliases/config/tag/unknown subcommands remain unknown. It recognizes git global `-c`, `-C`, and `--config-env`, the bounded env/sudo/doas/nohup/setsid/timeout/xargs wrappers, and literal `sh -c`/`eval`; substitution, unknown indirection, unsupported wrapper options, malformed input, multiple unsafe markers, or parser failure are unknown and deny active acceptance-sensitive writes. The gate never trusts `ECI_MUTATION_LOCK_HELD` or `ECI_REVIEW_GATE_LOCK_HELD`: mutation callers pass FD 9 bound to the canonical lock, or the standalone gate acquires it non-blocking.

An explicit `eci-review-gate prewrite` remains an optional policy-only Critic C skip-design admission route: only an explicitly selected skip-design route uses it before that route's first write. It requires the exact writer session, canonical target, current repository/version binding, and fresh C-prewrite intention, and may create a target/version-scoped admission sentinel only after all validation succeeds. It is not required for normal `commit`, `final`, or `off` acceptance, is not a universal worker-write firewall, and the active edit-routing gate does not invoke it for every write. Runtime acceptance requires postwrite A/B/C rows (plus E2E when required); a C-prewrite row may be retained only as an optional validated prefix. The outer coordinator owns bounded nested ATE state; nested ECI may never remove the outer marker, and outer commit/final/off consults active nested targets.

`nested-enter` is valid only under an active direct ECI marker while the canonical mutation lock is held; it records the outer session/owner and target. Only the main/orchestrator may publish `nested-accept` or clear it with `nested-exit`; worker roles fail closed. `nested-accept` writes the exact six-line accepted receipt under that owned marker and lock. Repeated `nested-enter` is rejected before any prior receipt is touched. `nested-exit` validates that ownership plus the receipt at `<session>/ate_nested_eci_completion` (bound to marker, acceptance version, step, and iteration) before clearing only its own nested marker.

The `PostCompact` hook is read-only and authoritative as a refresh signal: when a validated direct or nested marker is active it emits the full-skill reread instruction and writes no acknowledgement or refresh state. It is a reminder, not proof of semantic comprehension; the coordinator/lead must re-read and re-invoke the full ECI skill before the next decision/tool. SessionStart startup/resume/clear is only an available lifecycle reminder. Full openat/provider transcript archival remains scope-creep debt.

The `prewrite` row is optional policy evidence only: normal `commit`, `final`, and `off` require exactly A/B/C `postwrite` rows per target (plus required E2E), while an explicitly selected `prewrite` phase requires exactly C `prewrite` plus intention evidence. C `prewrite` is not a universal worker-write firewall or a normal acceptance prerequisite.

Critic C code-diff exception:
- Code diffs use two packets. Skip Packet 1 when there is no code diff.
- Packet 1 is diff-only isolation and goes to a newly spawned blind Critic C (`fork_turns: "none"`).
- Before Packet 1 spawn, perform lineage admission; verify the current project-understanding ledger/high_level_log pair; create and hash the exact prompt artifact; and complete any required provider/profile/identity checks. These checks remain mandatory coordinator evidence and are not serialized in the Packet 1 body.
- Packet 1 body contains only role label, stop-hook/reporting boilerplate, code diff, and reconstruction instruction. Under the closed diff-only protocol it omits only serialized lineage and normal review context.
- After `reconstructed intention:` returns, send Packet 2 with original requirements, exact scope, the full register/lane graph/paths/edges, admission binding, and full Critic C context.
- Gate remains incomplete until Packet 2/report returns.

### Issue severity codes

### Design-versus-implementation boundary

Critics report implementation-level findings as well as design findings; do
not discard a detail merely because the approved design can survive it. Classify
by blast radius and repair nature. A design-level finding is REJECT-worthy when
substantial scale-up would amplify the problem and fixing it requires a new
design decision, model, contract, trust boundary, or feasibility assumption;
semantic/model/contract errors are normally in this class. A local
syntax/style/wiring/mechanical defect with contained blast radius that can be
repaired without changing the approved design is an implementation detail. A
critic still reports every real finding under its own adversarial rubric and
may label it REJECT when its evidence supports that label; do not bias or
silence the report. The coordinator alone adjudicates final impact and may
downgrade a contained implementation detail to CONDITIONAL or tech-debt, so it
is never a design REJECT after that adjudication. The implementation loop still
resolves or records every such finding in its acceptance/debt ledger. Do not
silently drop a fixable detail, and do not downgrade a design change to polish.

Examples: a changed persistence model, ownership rule, public contract, or
security boundary is design-level; a typo, local adapter wiring error, or
mechanical call-site correction that preserves those decisions is
implementation-level.

Every remaining in-scope issue from Critic A, Critic B, and Critic C must carry exactly one code:

| Code | Meaning | Effect |
|------|---------|--------|
| **REJECT** | Would make the change wrong, unsafe, or contradictory | Must be fixed; routing follows impact/evaluation rules below |
| **CONDITIONAL** | Fix needed, but specific enough for the implementer to apply without redesign unless impact requires it | Must be fixed; routing follows impact/evaluation rules below |
| **NIT** | Soft recommendation | May be ignored |

All three critics tag every issue per the severity codes table above. Same vocabulary as Step 2; Effect differs (re-implement vs. re-explore).

For every REJECT or CONDITIONAL, reviewers must also tag `impact: trivial` or `impact: substantive` with a one-line rationale. `substantive` means non-trivial, major, API-changing, contract-changing, architecture-changing, security-sensitive, persistence-affecting, concurrency-affecting, or requiring a design tradeoff. Use the Triviality rule above for impact tags. Small patches are substantive when they alter future behavior, decision rules, contracts, prompts/instructions, or review routing. Missing impact tag = REJECT against the review output; re-prompt that reviewer before evaluating the gate.

All three critics critique the implementer's root-cause rationale and regression explanation when applicable. Unknown causal link or symptom-only change = REJECT unless containment was explicitly requested.

For governance/prompt/hook/protocol/reviewer changes, all three critics perform the Step 2 claim-scope audit within their lens. REJECT overclaims and missing boundary/negative tests; silent `UserPromptSubmit` state maintenance must not be described as reminder emission or an LLM reviewer/classifier. An optional LLM first-tool review is a manual or asynchronous/cached-only auxiliary (`edit-bash-pre-reviewer.sh`); it is deliberately not registered in the synchronous `PreToolUse` chain and must never be awaited by a hook.

### Critic A — coding style

Critic A is an ordinary, non-authoritative reviewer. The style critic reports findings only; the implementer fixes them. Before reviewing a governed code scope, load every matching installed coding-style skill: Go files, go.mod, or go.sum => go-coding-style; non-Go files => every matching installed style skill. Resolve the repository formatter/linter/config and exact source anchors, then review actual adherence rather than treating invocation as compliance.

Enforce material style and quality rules, hard contracts in the admitted style record, and declared deviations. A missing or unverified style admission is blocking. A cosmetic-only issue is a NIT. Critic A must not edit, rewrite, or route its own fix. A style label cannot downgrade behavior, security, interface, test/proof, architecture, or ownership failures; those remain hard findings for Critic B or Critic C under their lenses.

Tag-discipline audit: every factual claim in the implementer's submission must carry a T1-T5 tag per CODEX.md Claim Verification protocol. Untagged factual claim = REJECT.

### Critic B — correctness/fidelity

Critic B is an ordinary, non-authoritative reviewer and is distinct from Critic A and Critic C. Emit only issues affecting correctness, safety, or fidelity to the concrete text. Interface contract fulfillment — does every interface implementation actually work, not just compile? Polish and taste items are NITs at most.

Under **Coding-style admission**, Critic B guards the non-style boundary by consequence. False behavior, name/interface claims, security, root-cause analysis, test/proof/TDD obligations, or approved architecture, file-ownership, purpose, and interface contracts remain hard failures; they cannot be excused as style deviations. Guidance selecting among otherwise correct alternatives remains style.

Tag-discipline audit: every factual claim in the implementer's submission must carry a T1-T5 tag per CODEX.md Claim Verification protocol. Untagged factual claim = REJECT.

### Critic C — long-term health

Critic C is a fresh special `sol-high` reviewer, distinct from Critic A and Critic B. It reports findings only and never edits.

**Separate Critic C gates:** The `Critic C pre-write skip-design admission report` is a fresh special Critic C report owned by Critic C only on an explicitly selected skip-design route before that route's first production write; it covers read-only discovery and the admitted production scope, and its gate is permission for that route's write. It is not a universal prerequisite for ordinary writes. The `Critic C post-write reconciliation report` is a separate fresh special Critic C report owned by Critic C after writes; the coordinator/lead verifies actual scope, approved deltas/deviations, and post-write Tool evidence, and its gate is aggregate acceptance, commit, final proof, and teardown. Neither report substitutes for the other.

Diff-only intention check:
- Code diffs only. Skip when there is no code diff.
- Before spawning Packet 1, perform the shared Critic C checks: lineage admission, current project-understanding ledger/high_level_log pair verification, exact prompt-artifact creation, and any required provider/profile/identity checks.
- Spawn a new blind Critic C with `fork_turns: "none"` and a self-contained Packet 1 prompt.
- Packet 1 contains only role label, stop-hook/reporting boilerplate, code diff, and reconstruction instruction.
- Packet 1 body omits only serialized lineage and normal review context under the closed diff-only protocol; do not skip the mandatory checks above.
- Output `reconstructed intention:` with 2-4 bullets covering apparent root reason and intended behavior change, then stop.
- Main thread compares the reconstruction with the actual root reason and desired effects.
- If it misses the root reason, relies on hidden context, or claims an undesired effect, pre-route the `CONDITIONAL` remedy with the normal `impact:` tag to make code, tests, names, comments, or commit message explain the change.
- Packet 2: continue normal long-term-health review with the full register/lane graph/paths/edges, admission binding, and context.

Focus — adversarial, long-term lens:
- **Tech debt**: Coupling, hidden dependencies, or shortcuts costing more to fix later than now?
- **Coding-style admission**: Independently re-resolve actual governed scope and matching installed skills, then reconcile the diff with the admitted record, approved deltas/deviations, and post-write Tool evidence. Loading a skill alone proves nothing. Missing or unverified admission is blocking; an admitted deviation is compliant, and cosmetic taste is NIT.
- **Code smells**: God methods, feature envy, primitive obsession, duplicated logic, unclear names, missing/premature abstractions. Flag only smells that materially hurt readability or maintainability.
- **Architectural fit**: Right layer? Respects module boundaries? Code in correct binary/package per its stated purpose?
- **Tag-discipline**: every factual claim in submission carries T1-T5 per CODEX.md Claim Verification. Untagged factual claim = REJECT.

Emit only issues that matter for long-term health. "Would refactor eventually" is not an issue — "will cause bugs or confusion within 3 months" is.

### E2E agent — end-to-end verification

**Code/debugging tasks only.** Skip for non-code tasks (docs, config, design).
E2E capacity bottlenecked (device/browser/env slots, credentials, long setup): batch only then. While waiting, debug via shortest faithful repro (unit/API/CLI/log replay/component) before full E2E. Do not use short waits or polling for imminent tasks; keep healthy batches running, queue late arrivals, and use the one-hour provider-event wait rule only when an event is already expected. Report per-task verdicts.

1. Build; failure = issue.
2. Run full suite; failure = issue.
3. Exercise affected user path through real UI/API; cite output/screenshot/state. Proxy evidence alone insufficient.
4. Check related regressions.

### Evaluating results

Collect Critic A, Critic B, Critic C, and E2E results when applicable. Apply severity logic only after all required reports arrive:

Critic A's coding-style reconciliation is part of the gate. Route a substantive admission invalidation or substantive drift through Steps 1 and 2; return a local or tool-covered delta to `critic-step2` before the next affected write. Then apply the existing severity logic below. Final acceptance requires reconciliation of actual changed scope, admission, approved deltas/deviations, and Tool evidence.

Pre-route gate findings before evaluation. Scope-creep debt queues with its scope-screen record regardless of deadline. For queued future work, verifiers require the exact source comment with its specific tracker reference when an affected source exists; otherwise require the specific tracker record. An in-scope gate defer is valid only when Critic A, Critic B, and Critic C independently confirm the same terminal `sealed-at <= deadline` and that requirement. Every other in-scope case is `treatment: now`.

- At least one remaining substantive `now` REJECT or CONDITIONAL, OR an E2E failure caused by design/API uncertainty → batch all remaining `now` REJECTs, CONDITIONALs, and E2E failures into one design-revision issue list → return to Step 1/Step 2 explorer/designer-critic loop → Step 3 implements the selected revised design plus the full batch → re-run gate.
- At least one remaining trivial `now` REJECT from Critic A, Critic B, or Critic C, OR any trivial E2E failure → fix all remaining `now` REJECTs, CONDITIONALs, and E2E failures in one implementer message → re-run gate.
- Zero remaining `now` REJECTs but only trivial `now` CONDITIONALs exist → fix them in one implementer message; deadline-qualified deferred work or scope-creep debt is recorded → gate passes (no re-run).
- No remaining `now` issue → gate passes. `ignored-contradictory` directives, scope-creep debt, and deadline-qualified deferment open no repair, review, or cycle.

Gate retry and cycle limits defined in Escalation table.

**Clean pass** = every original criterion and required E2E/proof pass, zero remaining `now` REJECTs/CONDITIONALs, and E2E pass from the same gate run. Independently confirmed deadline-qualified deferrals and queued scope-creep debt are future work, not unresolved findings.

### Design-revision issue batch

When the gate routes back to design revision, batch issues before contacting any agent. Do not run one loop per issue.

The batch must include:
- All remaining `now` REJECTs, CONDITIONALs, and E2E failures from the completed gate, grouped by affected artifact/API/contract.
- Source agent, severity, impact tag, file:line or direct evidence, exact quoted issue text, and the `deadline-qualified defer` or scope-creep-debt record reference where audit needs it.
- Acceptance criteria for resolving the whole batch.

Step 1 explorer re-reads current code and researches options that resolve the full batch. Step 2 critic reviews those options as the designer-critic and either selects one concrete revised design or bounces all-REJECT outcomes per Step 2 loop-logic. Step 3 implementer receives the selected revised design and the full issue batch verbatim. No direct patching of substantive findings before this loop.

## Brainstormer (unblocker)

Fresh idea generator — fires on-demand when the cycle stalls. Output is raw ideas only; never decisions, verdicts, or filtering. Bigger list = better.

**Genuine stall definition.** Normal ECI issue handling was tried, and the Required Record from `blocker-resolution-protocol` exists. A bare "I'm stuck" without an attempt log is not a stall; push the agent to keep trying.

| Trigger | Action |
|---------|--------|
| Explorer returned zero viable options after documented attempts | Spawn brainstormer + BRP primary explorer -> run `brp-feasibility-validator` -> feed blocker record, validated feasible ideas, primary explorer facts, and prior failures into the next explorer/implementer prompt |
| Step 2 bounce cap reached (one explorer revision round did not yield a clean option) | Spawn brainstormer + BRP primary explorer -> run `brp-feasibility-validator` -> feed blocker record, validated feasible ideas, primary explorer facts, and prior failures into the next explorer/implementer prompt |
| Implementer genuinely blocked inside Step 3 (per Genuine stall definition above) | Spawn brainstormer + BRP primary explorer -> run `brp-feasibility-validator` -> feed blocker record, validated feasible ideas, primary explorer facts, and prior failures into the next explorer/implementer prompt |

### Prompt requirements

- Original problem + everything tried so far, verbatim.
- Current code/file paths — brainstormer reads them independently.
- "Generate as many distinct ideas as possible. No filtering, no feasibility judgment, no negatives. Bigger list = better."
- "You are NOT one of the cycle agents. Do not trust prior agent summaries."

### Constraints

- Spawn as separate `brainstormer` agent; never message the explorer or implementer agent.
- Must NOT be any other cycle agent (explorer, Step 2 critic, implementer, Critic A, Critic B, Critic C, E2E, brp-feasibility-validator, loop-breaker).
- Each invocation is a new blind `spawn_agent` with `fork_turns: "none"` and a self-contained prompt.
- Ideas only — `brp-feasibility-validator` filters BRP-triggered ideas.
- Brainstormer output never goes directly to explorer/implementer after a BRP trigger; only validator-approved ideas may be routed onward.

## Loop-breaker

A separate agent — not any of the cycle agents — gets one chance to break the loop before escalating to the user.

**One loop-breaker invocation per change**, regardless of trigger. A failed granted retry or `BLOCKED` result creates a protocol-limit blocker record, runs `blocker-resolution-protocol`, and hard escalates only if BRP finds no feasible internal path or the blocker is user-owned. ECI stays active.

### Prompt must include

- Original problem statement.
- All cycle attempts: what was tried, what failed, remaining issues verbatim.
- Current code state (file paths — loop-breaker reads them independently).
- Pre-routing outcome, completed gate output, E2E/proof evidence, and clean-pass evaluation.
- "You are a fresh reviewer. Read the code and issues yourself. Do not trust prior agents' assessments."

### Decision — exactly one of three

| Decision | Meaning | Effect |
|----------|---------|--------|
| **ACCEPT** | Pre-routing leaves no `now` issue and clean pass already holds: every original criterion and required E2E/proof passes, zero `now` REJECT/CONDITIONAL remains, and the same gate's required E2E/proof passes | Record evidence; authorizes only normal clean-pass exit and waives nothing. |
| **RETRY** | A `now` issue or required clean-pass evidence gap remains and another attempt can resolve it | Grant exactly one matching retry (gate retry or full cycle) with specific guidance. |
| **BLOCKED** | Clean pass does not hold and no retry can establish it | Create a protocol-limit blocker record, then run `blocker-resolution-protocol`; hard escalate only as BRP allows. |

### Constraints

- Spawn each loop-breaker invocation as a new blind agent with `fork_turns: "none"` and a self-contained prompt.
- Must NOT be any of the 7 cycle agents (explorer, Step 2 critic, implementer, Critic A, Critic B, Critic C, E2E agent).
- Reads code and issues independently — no reliance on prior agent summaries.
- Never ACCEPT with a remaining `now` issue or failed/missing original criterion, required E2E, or required proof.
- One invocation per change. A granted retry fails or BLOCKED result -> create a protocol-limit blocker record, run `blocker-resolution-protocol`, and hard escalate only if BRP finds no feasible internal path or the blocker is user-owned.

## Escalation

Single decision table for all limit hits. One loop-breaker per change total.

| Trigger | Condition | Action | If retry fails |
|---------|-----------|--------|----------------|
| Gate retry cap | 3 gate retries failed within one cycle | Invoke loop-breaker (if not yet used for this change) | Create protocol-limit blocker record -> run `blocker-resolution-protocol` -> hard escalate only if BRP finds no feasible internal path or the blocker is user-owned; ECI stays active |
| Cycle limit | 3 full cycles failed for one change | Invoke loop-breaker (if not yet used for this change) | Create protocol-limit blocker record -> run `blocker-resolution-protocol` -> hard escalate only if BRP finds no feasible internal path or the blocker is user-owned; ECI stays active |
| Loop-breaker already used | Either limit hit but loop-breaker was consumed by prior trigger | Create protocol-limit blocker record -> run `blocker-resolution-protocol` -> hard escalate only if BRP finds no feasible internal path or the blocker is user-owned; ECI stays active | — |
| Step 2 post-brainstormer all-REJECT | Brainstormer fired and new explorer's options still all-REJECT after one revision | Create protocol-limit blocker record -> run `blocker-resolution-protocol` -> hard escalate only if BRP finds no feasible internal path or the blocker is user-owned; ECI stays active | — |

**Hard escalate** = report a blocker requiring user input while ECI remains active. Use the escalation report from `blocker-resolution-protocol`, plus: (a) original problem, (b) what each cycle tried, (c) loop-breaker's assessment (if invoked), (d) last blocking issue, (e) next-best alternative from explorer's ranking. Silent punts forbidden.

## Iteration limit

Cycle limit defined in Escalation table (3 full cycles per change).

## Exit conditions

- Normal clean pass is demonstrated and clean-pass teardown completed, OR
- User closes ECI by requesting ATE or by cancelling, withdrawing, or replacing its root scope, and user-closed teardown completes, OR
- Hard escalate triggered → blocker/user decision request reported; ECI remains active.

## Status reports

Reports to user use:

| Rule | Example |
|------|---------|
| Human-readable names, not task/iteration numbers | "severity-codes table done", not "task 3 done" / "cycle 2 failed" |
| Tree structure when work decomposes into sub-issues or nested ECI pipelines | Indent children under parent; never flatten |

- Use `<role label> (<runtime name>)` in every status, wait, or close update; do not use bare runtime nicknames once labeled.
- Use human-readable lane names and preserve parent/child trees. In an active ECI/ATE lineage, every reported lane has non-empty root-qualified `Lane requirement refs`; include a nearby redacted-verbatim Requirements registry with each referenced ID's wording and source. The project-understanding ledger remains the source for the full edge chain; status columns carry refs, not the graph.
- In a direct workflow with inactive ECI/ATE lineage, preserve direct-workflow reporting and do not fabricate refs or a registry.
- A lineage-admission failure leaves status unchanged and is reported as a routing risk/next action, never as `PAUSED`, `BLOCKED`, BRP, or a lifecycle phase.

Issue uncovered mid-iteration that spawns its own ECI pipeline → nest under the iteration that found it.

```
auth middleware swap [Lane requirement refs: root-requirement-lineage-20260822::R1]
├─ severity-codes change [Lane requirement refs: root-requirement-lineage-20260822::R1]: gate passed, committed
├─ E2E uncovered stale-session bug [Lane requirement refs: root-requirement-lineage-20260822::R3] → nested ECI:
│   ├─ session-cache invalidation [Lane requirement refs: root-requirement-lineage-20260822::R3]: 3 options ranked
│   └─ blocked on prod log access [Lane requirement refs: root-requirement-lineage-20260822::R3]
└─ docstring update [Lane requirement refs: root-requirement-lineage-20260822::R1]: pending
```

## Pressure-test checklist

Use exactly these nine counters in RED/GREEN pressure runs. Emit one bounded evidence record per counter with this schema:

```text
{counter, commit_sha, scenario, expected_invariant, observed_result, owner, artifact_path, artifact_sha256, verdict}
```

`commit_sha` is the final successor Git OID for this policy change. `ade3ee3` and `05c05fa` are baseline references only and cannot satisfy successor evidence. Missing evidence, including a missing artifact path/hash, successor OID, or verdict, is `FAIL`; no clean pass is valid until all nine successor records are GREEN. This is an evidence format, not a fake-task checklist.

For reproducible GREEN validation, the validator must persist deterministic validator source and captured output under the active session proof evidence directory, outside the repository, hash each exact byte stream, and make every one of the nine records bind to an evidence bundle naming `validator_source_path`, `validator_source_sha256`, `validator_output_path`, and `validator_output_sha256` through its `artifact_path`/`artifact_sha256`. Do not regenerate evidence here or infer runtime/effective-provider claims from validator output.

- `pause_continue_hold_ambiguity`: hold on quoted, qualified, one-task, status, timer, provider, silence, and `stop for today` text; trigger only the direct all-active imperative.
- `pause_missing_report`: validate wrong-type/wrong-literal scalar cases, the exact session-proof canonical path, and the canonical body separately from exactly one ASCII `report_sha256` trailer; test the unavailable-drain report-only branch (redacted source/quotation, exact reason, observable-only snapshots, bounded drain-unavailable resume text, valid digest, no frozen-manifest/transaction/marker/awaiting-user claim, and transaction pending/unpublished) versus the attested path; drain and attest closure before constructing byte-identical `frozen_manifest` arrays, reject mutation/reordering/wrong-manifest-hash vectors, publish and verify the closed transaction only when both hashes/fields/paths/intended marker state match, deterministically republish a missing transaction only from verified report+manifest bytes, record requested-special plus child identity and, when effective telemetry is unavailable, also record `effective-unavailable`; record unexposed selectors as `unavailable_by_schema`; reject omitted/rejected selectors or conflicting effective telemetry only for that child, require the provider-native drain barrier, and fail closed when atomic marker projection is unavailable; test direct ECI current-marker/nonterminal behavior, fresh requested-selector records for every special role including mixed, and exact operational-label normalization; missing or mismatched evidence is `FAIL`.
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
- `rejected-selector`: an omitted or rejected exposed selector rejects only that child dependency; continue ECI/BRP without ordinary fallback, reuse, or downgrade.
- `same-fingerprint-callback-ids`: duplicate and changed callback IDs with the same normalized fingerprint are no-ops; do not repeat action, wait, retry, final/status reply, or question.
- `keyless-new-evidence`: a missing event key neither resumes nor suppresses; new normalized source/test evidence changes the fingerprint and permits one new action.
- `solvable-blocker`: a feasible internal ECI/BRP path exists; continue it and do not quiet or escalate.
- `exhausted-concrete-user-owned-input`: BRP proves no feasible internal path and identifies unobtainable user-owned input/resource/decision; emit one blocker report/question, then quiet.
- `go-style-admission`: a governed diff containing Go files, `go.mod`, or `go.sum` loads `go-coding-style`, resolves formatter/linter/config anchors, and checks material adherence; invocation alone is not compliance.
- `non-go-style-admission`: a non-Go governed diff loads every matching installed coding-style skill and records missing or unverified admission as blocking.
- `style-finding-no-edit`: Critic A reports a material style issue with evidence and leaves all edits to the implementer.
- `cosmetic-style-nit`: a cosmetic-only style preference is classified as NIT and does not block the gate.
- `hard-consequence-not-style`: behavior, security, interface, test/proof, architecture, or ownership failures remain hard Critic B/C findings and cannot be downgraded as style.
- `omitted-required-critic`: an absent Critic A, B, or C report routes back to spawning that exact fresh blind critic; no gate, commit, or teardown proceeds.
- `stale-diff-report`: a report whose bound diff SHA-256 or child identity does not match the current manifest is unverified and cannot satisfy the gate.
- `target-scoped-critic-ledger-row`: root, subtask, and candidate-fix each receive one immutable A/B/C row with the exact schema, lowercase hashes, and shared target+diff+child tuple; missing, stale, contradictory, or unverified rows block the gate.
- `critic-c-prewrite-postwrite`: Critic C's pre-write skip-design admission report and post-write reconciliation report are separate fresh reports with separate write and final-acceptance gates; neither substitutes for the other.
- `postcompact-refresh-signal`: PostCompact is authoritative for compaction refresh; SessionStart startup/resume/clear is only a best-effort reminder.

## Red flags

| Symptom | Fix |
|---------|-----|
| Implementing 2+ changes before re-critiquing | Stop. One at a time |
| "Good enough" at cycle 3 | Invoke loop-breaker, don't settle or force |
| Any two of {explorer, Step 2 critic, implementer, Critic A, Critic B, Critic C, E2E agent, brainstormer, brp-feasibility-validator, loop-breaker} are the same agent | Banned. Up to ten distinct agents (seven per normal cycle + brainstormer/validator for BRP + loop-breaker at limits) |
| Review-gate Critic A returned before Critic B or Critic C was spawned | Sequential gate. Spawn Critic A + Critic B + Critic C (+ E2E when in scope) in one message with parallel `spawn_agent` tool calls; do not serialize even if one critic's view seems sufficient. |
| Task/round-specific role labels (`critic-r3`, `e2e-gate-7`) used instead of reusable role slots | STOP. Use stable labels (`critic-step2`, `e2e-gate`) and put round/gate details in the assignment. |
| Skipping E2E inside loop | E2E is part of the review gate — runs every iteration, not at the end |
| Skipping exploration or critique for later iterations | Every iteration runs all four steps — none are optional |
| Winner lacks concrete text | Critic under-specified. Re-spawn with "concrete text required" |
| No rejected list in Step 2 | Critic is not adversarial. Re-spawn |
| Brainstormer output filters/judges/picks a winner | Brainstormer is idea-only. Re-spawn with "no filtering, no negatives" |
| Reusable explorer or implementer addressed for critic-role work, or blind critic spawned without `fork_turns: "none"` and a self-contained prompt | STOP. Spawn a new isolated critic identity; the producer must never act as critic. |
| Disengage without teardown sequence | STOP. Observe terminal states or cancel exact active work, then run eci-active off last. Never close a terminal agent. |
| Shell-launched Codex process used as an agent | STOP. Use standard collaboration tools (`spawn_agent`, `followup_task`, `send_message`, `wait_agent({timeout_ms:3600000})`, `interrupt_agent`), or hard-escalate if unavailable. |
| Status report uses task/iteration numbers, or flat-lists nested work | See **Status reports** section. |
| Lane assignment has empty/unresolved refs, a missing full chain, cross-root parent, cycle, or no user requirement | STOP the provider/tool call; repair lineage admission before routing. |
| Discovered work is executed without an authorized requirement ancestor | Queue it as scope-creep debt; do not create a lane or change status until the user authorizes it through the lifecycle. |
| Lineage-admission failure is labeled `PAUSED`, `BLOCKED`, BRP, or a lifecycle phase | Keep the existing status unchanged; report a routing risk and next action. |
| Spawn/reassignment/review packet omits lane fields or full chain from its body (except Critic C Packet 1's closed body-serialization exception; admission checks remain mandatory) | STOP and rebuild the packet before provider execution. |
| New producer spawned although its prior role is idle/addressable | Use `followup_task` with a self-contained assignment. `send_message` is only for a currently running turn. |
| Critic absorbed pre-routed work by rewriting option | STOP. Critic tags only — orchestrator folds only `treatment: now` text into Step 3. |
| Orchestrator forgot pre-routing or the `now` fix-list | STOP. Include the general pre-routing record; include `started`, deadline, and `sealed-at` only for a potential defer; include only `treatment: now` fixes in Step 3. |
| Submission accepted with untagged factual claims | STOP. Tag-audit failure = REJECT in current gate (per Critic A/B/C rule). |
| A matching coding-style skill was loaded, but no independent admission exists | STOP. Invocation is not compliance; complete the applicable record and Step 2 admission before durable work. |
| Durable work starts before admission, or affected work continues after scope/source/conflict/deviation drift | STOP affected work. Isolated disposable work may continue under the stated boundary; route local/tool-covered deltas to `critic-step2` and substantive drift through Steps 1/2. |
| Empty Style Brief, bare no-source claim, or rule-by-rule style inventory | STOP. Use only the applicable admission route with exact discovery anchors and grouped material decisions. |
| A false correctness, security, RCA, testing/proof/TDD, or approved architecture/ownership/purpose/interface result is labeled a style deviation | STOP. Critic B or Critic C treats it as the corresponding hard non-style failure. |
| Hook/protocol/reviewer wording claims a heuristic proves, classifies, or determines task nature without matching mechanism evidence and boundary tests | STOP. Reword to the strongest supported claim and add negative/boundary pressure. |
| Code/debugging submission lacks root-cause rationale or required regression explanation | STOP. Bounce before gate; unknown "why" means unsubmittable. |
| Bug RCA prompt lacks regression report path or previous/current test-run evidence packet | STOP. Write/update the report artifact, then resend the RCA assignment. |
| Critic fails to critique root-cause rationale or regression explanation | STOP. Re-prompt or re-spawn critic. |
| Remaining substantive `now` REJECT/CONDITIONAL fixed directly after review gate | STOP. Batch all remaining `now` gate issues and return to Step 1/Step 2 explorer/designer-critic loop. |
| Gate issues handled one-by-one | STOP. Batch by affected artifact/API/contract before re-exploration or implementation. |

## Relationship to other skills

| Skill | Difference |
|-------|-----------|
| `brainstorming` | Explores user intent before design. This skill explores solutions after intent is clear. |
| `agent-teams-execution` | ATE is the outer workflow for large or multi-workstream work. It may route bounded work through ECI; ATE remains outer. ECI borrows ATE's rubber-stamp check: a critic citing no issues beyond producer self-reports must be re-spawned with a harsher prompt. |
| `blocker-resolution-protocol` | Shared blocker handling. ECI keeps its own role separation, loop-breaker, and hard-escalation semantics while using the shared blocker record and escalation rules. |
| `systematic-debugging` | For diagnosing a known bug. This skill is for open-ended improvement/design research. |
| `proof-driven-development` | Proves correctness of logic. This skill selects which logic to build. |
