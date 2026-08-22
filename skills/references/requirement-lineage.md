# Requirement register and lane-lineage contract

Shared normative reference for ECI and ATE; non-triggering and never
auto-loaded. Each coordinator reads `$CODEX_HOME/skills/references/requirement-lineage.md`
before the governed operations in its outer skill. If unreadable, fail closed.
Fallback: an executable lane needs a non-empty active user ref and complete
user-ancestry path; missing/stale evidence blocks the call and leaves status
unchanged; unrooted discovered work never executes.

## Register, IDs, and state

One immutable normalized register lives in `project-understanding.md` per active
root. `register_root_id` is distinct from task roots, display/lane/marker
names, and nested-work IDs; nested ECI inherits its outer ATE root. An ECI→ATE
replacement for the same scope carries that root; an unrelated/replaced scope
gets a new root only after the prior root closes. Declarations
are append-only:
`{register_root_id,requirement_id,origin:"user",redacted_verbatim_user_text,source_location,redaction_ids}`.
Durable identity is `{register_root_id,requirement_id}`. `requirement_id` is a
unique, never-reused lexical local ID (for example `R1`). The immutable,
register-scoped alias map is
`{register_root_id,aliases:[{alias,requirement_ref:{register_root_id,requirement_id}}]}`:
aliases are unique and never reused within that register, and each maps to the
canonical tuple. `R<n>`
is display-only; executable `requirement_refs` carry canonical
`{register_root_id,requirement_id}` tuples, never a bare `R<n>`. Standalone
packets, excerpts, and handoffs carry the tuple or this alias map. Reject
malformed, duplicate, or delimiter-containing IDs.
Preserve clause order/scope/qualifiers/modality; redact only secrets into stable
root-scoped placeholders, record source location, never raw bytes, and call the
result **redacted verbatim user wording**.

The mutable projection is keyed by the canonical tuple:
`{register_root_id,requirement_id,state:active|superseded|retired,supersedes:[{register_root_id,requirement_id}],superseded_by:[{register_root_id,requirement_id}],state_event_ref}`.
`StateEvent={state_event_ref,register_root_id,requirement_id,version,transition,canonical_bytes_sha256}`
is immutable; `version` is monotonic per register and
`canonical_bytes_sha256` is the lowercase 64-hex hash of the canonical event
bytes. Each event binds the tuple, version, and transition.
Active-admission refs must resolve to active state. Historical/provenance paths
may resolve superseded/retired refs only with immutable `state_event_ref`; those
refs never authorize new work. Additions create active IDs;
corrections/replacements create an active successor and atomically supersede
named IDs; withdrawal retires without a successor. Direct user evidence alone
authorizes transitions. Compatibility constraints such as D1 use
`{constraint_id,origin:"protocol-constraint",text,source}` plus a `constrains`
edge; they constrain existing behavior, never authorize work. Only
`origin:"user"` may authorize a lane.
`project-understanding.md` is current state; append capture, wording,
supersession/removal, lane, owner, and material-reroute events to
`high_level_log.md`. Stop affected lanes before provider calls; historical lanes
retain provenance only.

## Graph and invariants

```text
Lane={lane_id,register_root_id,task_root_id,human_name,derivation_kind,predecessor_lane_ids,requirement_refs,derivation_reason,path_ids}
Assignment={assignment_id,lane_id,owner,canonical_status_ref,evidence,admission_binding}
Path={path_id,requirement_ref,lane_id,start:{kind,id},end:{kind,id},edge_ids}
Edge={edge_id,path_id,seq,register_root_id,from:{kind,id},relation,to:{kind,id},reason,evidence:{source_kind,locator,canonical_bytes_sha256}}
```

Lane identity/lineage is immutable after admission. Kinds are
`root|child|derived|protocol|reroute`; roots have none, ordinary children have
ordered predecessors, reroutes point directly to the superseded lane, and
aggregate/review/integration lanes may have several. Owner-only reassignment
creates an Assignment; a material definition change creates a reroute lane.
Nodes are `requirement|decision|lane|assignment`; relations are
`authorizes|justifies|derives|precedes|executes|reroutes|evidences|constrains`.
Require same-register endpoints and relation-kind endpoint compatibility; reject
duplicate/self/cross-root/cyclic edges, undeclared or unordered predecessors,
bad Path start/endpoints, or an Edge whose path/seq membership is wrong. `seq`
must be contiguous per path, every predecessor must appear in a complete path,
and an assignment endpoint's `lane_id` must equal the Path/Lane endpoint.
Evidence must be a lowercase 64-hex SHA-256. Active-admission refs resolve to
active requirements; historical paths use the state-event exception above. Each
active ref has a complete user→current lane/assignment path; children use a
subset of their root's refs. Expand the full
`requirement → decision/reasoning → parent/derived lane → executed assignment`
chain in the ledger and ordinary packets, not duplicate graph objects.

## Admission and scope boundary

Before `spawn_agent`, `followup_task`, a lane-changing `send_message`, or other
unbound durable execution: validate graph/state; verify the existing log
prefix; update and publish/re-read ledger/latest-status; append/verify PREPARE;
materialize/hash the prompt; record
`admission_binding={register_root_id,lane_id,assignment_id,active_requirement_state_version,alias_map_sha256,requirement_state_sha256,expanded_path_sha256,prompt_sha256,ledger_sha256,log_post_append_sha256,log_post_append_size,latest_status_sha256,admission_record_sha256}`;
append/verify COMMIT. This is recoverable evidence, not an atomic provider
transaction; any missing/stale pair/hash fails closed.

A running agent may submit only non-executable
`{proposal_id,source_lane_id,register_root_id,kind,requirement_refs,predecessor_lane_ids,derivation_reason,existing_acceptance_criterion,no_new_outcome_proof,evidence}`.
The coordinator independently admits a necessary derived lane through the same
graph and pair admission binding; the source lane/predecessor/ref subset,
existing acceptance criterion, and no-new-outcome proof are required. Missing
refs alone do not prove new scope. A genuinely new outcome/scope or missing user
ancestry is scope-creep debt: no lane, call, or status change until direct user
authorization creates a declaration.
Admission failure is a routing risk/next action, never `PAUSED`, `BLOCKED`, BRP,
or a lifecycle phase. Do not add lineage fields to closed pause snapshots,
critic manifests, marker schemas, or task-state schemas.
These schemas describe documentation obligations and projections; runtime/provider
enforcement, telemetry, and exhaustive event matrices remain coordinator-owned
and are outside this docs-only patch.
