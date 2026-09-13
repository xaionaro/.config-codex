# Coordinator Runtime

Coordinator/lead only. Ordinary workers load only the local module named in their assignment. This reference routes work and review; it is not a permission system. Assume bots are not malicious. Prevent concrete accidental target or scope damage. Do not stop normal work for an artifact, receipt, hash, allowlist, raw command spelling, parser shape, model label, or missing coordination field. When a lower rule appears stricter without a concrete resolved accidental effect, this rule wins.

## Admission and agent lifecycle

- Start an outer workflow only when CODEX selects it. A nested ECI remains owned by outer ATE.
- Apply [concurrent task scheduling](../../../CODEX.md#concurrent-tasks) to ECI tasks within the active lifecycle. Stage, checkpoint, and review waits follow the affected task's dependencies; root teardown covers all owned tasks.
- Before a durable spawn, followup, lane-changing message, or write, identify task, scope, owner, and enough target detail to avoid an accidental cross-scope change. For material ECI work, carry `exact user source → faithful requested outcome → bounded scope`. Missing lineage or a stale label calls for a concise clarification or reassignment; it does not block harmless work.
- Keep a repair in its current lane when the record shows it is necessary to meet or prove the requested outcome. Do not relabel that repair as a substitute user requirement.
- Record a discovered concern whose remedy serves a separate outcome as an observation or follow-up suggestion after current ECI. It does not create current lane, assignment, code change, review, deadline, forecast, or proof work.
- Keep prompts and handoffs as readable coordination records. They may support review, but no proof-directory artifact, hash, receipt, ledger prefix, or serialized field list is a prerequisite for normal spawn, followup, exploration, implementation, or verification.
- `spawn_agent` creates a role; `followup_task` starts a new turn only for an idle reusable role; `send_message` supplies bounded information to a running turn; `interrupt_agent` cancels exact active work only. Never shell-launch agents or close terminal agents.
- Name reusable ordinary producers by stable semantic role. Every blind critic and every special role uses a fresh `spawn_agent({fork_turns:"none"})` with a unique transport name. A `followup_task` never upgrades an ordinary role to special.
- Keep at most one outstanding `wait_agent({timeout_ms:3600000})` per undelivered expected completion. A timeout is non-terminal: do not poll, retry, or infer a crash. Use `list_agents` only for roster maintenance or documented crash recovery.
- Include this exact Stop-hook rule in every subagent prompt: “Follow any Stop-hook prompt in that session, including required proof/checklist files. Fix blockers within assigned scope. Report to the orchestrator only when resolution needs out-of-scope changes, unrelated user work, credentials, or approval.”

## Role and model admission

Every assignment and roster entry names one category and one semantic role. State the work, target/change/verification for implementation, and owner. Use plain readable records; canonical JSON, hashes, receipts, and exact field order are optional diagnostics, never admission requirements.

| Category | Authority/model | Permitted roles and work |
| --- | --- | --- |
| `exploration-only` | non-authoritative / ordinary | Fact gathering, options, evidence; never authoritative design/admission. |
| `design` | authoritative / special | Designers, design reviewers, ECI Step 2/Critic C, ATE long-term-health reviewers. |
| `mixed` | combined / special | Only explicit `combined fact-and-authority`; never infer it. |
| `implementation` | non-authoritative / ordinary | Implementers, Fast owners, executors, test/QA, Critic A/B, correctness reviewers. |

Use stable role labels where available. An unfamiliar label or changed profile prompts a quick clarification or a reasonable available assignment; it does not block normal work or require profile hashing. Request the intended model and effort when the provider exposes them, and record unavailable selector fields plainly.

Send exposed selectors when they materially help the assignment. Treat unavailable or conflicting telemetry as a note for review, not a reason to halt, manufacture evidence, or reject ordinary worker progress.

### Closed role map

`fast-owner`→`Fast owner` is a reusable ECI producer governed by [ECI fast path](../../explore-critique-implement/references/fast-path.md), including its scoped shared-tree ownership exception.

Common labels include `explorer`→`Explorer`; `researcher`→`researcher`; `brainstormer`→`Brainstormer`; `critic-step2`→`ECI critic-step2`; `critic-A`→`ECI Critic A`; `critic-B`→`ECI Critic B`; `critic-C`→`ECI Critic C`; `e2e-gate`→`E2E gate`; `implementer`→`implementer`; `executor`→`Executor`; `qa`→`QA`; `fdr-reviewer`→`FDR reviewer`; `fdr-meta-reviewer`→`FDR meta-reviewer`; `ate-design-reviewer`→`ATE Design Reviewer`; `ate-meta-reviewer`→`ATE meta-reviewer`; `execution-reviewer-correctness`→`Execution Reviewer: correctness/fidelity`; and `execution-reviewer-long-term-health`→`Execution Reviewer: long-term-health`. Normalize when useful; unknown labels ask for clarification rather than block.

- Use role categories as routing defaults: exploration gathers facts; design reviews consequential design choices; implementation changes and tests code. If the exact role is unavailable, use a reasonable available role and schedule independent review where it matters. Do not make a special model, field shape, or role label a normal-work gate.

If work needs a different role, reassign it clearly and use a fresh reviewer where independence matters. Special roles normally use a fresh unique `spawn_agent({fork_turns:"none"})`; ordinary Explorer, implementer, and ordinary correctness/fidelity slots may be reusable where their outer workflow permits. Do not create an artifact or model-routing blocker merely to record the reassignment.

`PostCompact` is the authoritative compaction refresh signal. Immediately after it, the coordinator/lead re-reads the active outer skill before another decision or tool call. `SessionStart` `startup|resume|clear` is only a best-effort resume/clear reminder. The `PostCompact` hook is read-only; it is a reminder, not proof of rereading.

## Required-critic runtime

The coordinator keeps the current review state visible while the direct marker is active. A manifest is a useful summary, not a publication or command-admission monopoly; workers may provide ordinary reports and the coordinator reconciles them.

For each target, record its path or scope, current diff/revision when useful, assigned reviewers, required verification, and current verdict. Keep enough context to notice that the target changed; do not require a prescribed header, hashes, or artifact paths before work can proceed.

At review and final acceptance, obtain the independent checks and E2E that the task actually needs. A changed target or missing review routes fresh review before claiming acceptance; it does not freeze exploration, implementation, ordinary verification, or targeted commits behind row schemas, receipts, or hashes.

At acceptance, compare the actual current target and diff with the review scope. A meaningful change triggers fresh appropriate review. Preserve historical notes when useful, but missing or malformed ledgers, receipts, hashes, or anchors are repairable coordination gaps, not a reason to reject normal work.

**Adjudication:** Preserve each critic's substantive verdict and explain any coordinator disagreement. Use readable reports; do not make terminal markers, byte format, bounded text rules, or report hashes prerequisites for progress.

The optional Critic C prewrite note may help a selected skip-design route, and a post-write reconciliation can improve final review. Neither is a prerequisite for the first production write. Nested ECI never removes the outer ATE marker.

## Acceptance and Git boundary

Only governed target paths need the assigned review; leave unrelated changes out of that review. The coordinator maintains the review summary through the ordinary coordination path. A document path, writer spelling, redirection, or generic file operation is not a permission boundary; protect only real active control records and other sessions' control state.

Before a destructive Git action, resolve the repository and concrete paths. Stop only a broad, unresolved, or unrelated destructive action and offer the narrow safe route. After each implementer handoff, independently verify the exact iteration diff and make its narrow coordinator-owned checkpoint commit before review or another implementation iteration. The checkpointed `current diff` is the named parent-to-checkpoint range. Respect explicit exclusions and exclude later ambient worktree changes. This is review scope, not admission proof. Use normal targeted Git coordination: preserve unrelated dirty paths as exclusions. It needs no approval artifact, receipt, hash, canonical spelling, or command-shape prerequisite.

For ECI fast contributions, apply the [adoption boundary](../../explore-critique-implement/references/fast-path.md#adoption-review-and-closure), including cumulative review beyond the iteration range and both-producer closure. Normal-path completion requires the [post-Fast sequence](../../explore-critique-implement/references/fast-path.md#post-fast-completion), even after a clean intermediate review.

After ECI `off`, record a concise teardown summary and the actual current repository state. If a historical coordination note disagrees, reconcile it; do not make hashes, receipts, or byte-exact records a prerequisite for normal teardown.

## Shared records

Use readable current-state records for current requested work. A concern whose
remedy serves a separate outcome is only a post-ECI observation or follow-up
suggestion, never a current queue or replay record. It never waives an original
criterion.

## Routing packet guidance

Before every spawn, followup, lane-changing `send_message`, or durable execution, carry enough context to identify the task, scope, owner, target/change/verification when implementation is involved, and reason for any reroute. Use stable IDs and lineage where helpful. Missing metadata routes a concise clarification or queue; it does not block harmless work or create an admission failure state.

Every prompt states semantic role, exact scope/files/ownership, expected output, fresh-assignment reread rule, matching skills, concurrent-edit warning, relevant verification, and the Stop-hook rule. Reviewer/verifier/QA packets also state objective/criteria and the current target/diff. Use concise readable context; no prompt artifact, hash, or ledger prefix gates dispatch.

Prompts and selector records aid review. They do not prove effective model behavior and do not gate ordinary work. Record a limitation when relevant, then continue with the available provider.

### Stable roles and fresh identities

Use the closed role map above. Reusable ordinary producer slots are Explorer, implementer, Fast owner, ordinary Executor, and ordinary correctness reviewer only where the outer workflow says so. Step-2 critics, Critic A, Critic B, Critic C, E2E, brainstormer, BRP validator, loop-breaker, Design Reviewer, FDR reviewer/meta-reviewer, and every special semantic role are fresh identities as their owning workflow requires. An ordinary followup never upgrades category or model class.

## Critic-manifest currentness

A manifest is a current, readable review summary. Compare it with the actual target and diff before final acceptance. If they differ materially, obtain fresh appropriate review. Do not demand a header, canonical byte stream, hash, receipt, lock, symlink policy, or fixed A/B/C row count before continuing normal work.

Keep prewrite/postwrite notes only when they help a chosen review route. They never create a universal write firewall or make a reviewer report artifact a prerequisite for an ordinary edit, command, or targeted commit.

Preserve substantive critic findings. A stale or missing summary is a coordination repair, not an access denial.

### Code-diff and nested boundaries

The optional Critic C prewrite route may be used for selected skip-design work before its first production write. It informs review, not command admission. After write, a separate critic may reconcile actual scope, approved deltas/deviations, and tool evidence when that review is useful.

Nested ECI records outer owner/session/target and does not remove the outer ATE marker. Resolve actual competing writes or teardown targets; do not block nested work solely because a receipt or lock record is absent or malformed.

## Guarded command and completion behavior

Evaluate commands by their resolved effect and target. Unknown syntax, interpreters, Make, aliases, options, substitutions, wrappers, environment expansion, parser limitations, or shell punctuation are not reasons to deny normal work. Resolve and stop only an actual broad, unresolved, cross-scope, or destructive effect; explain the concrete mistake and offer a narrow safe route. Locks and records coordinate concurrent work but never become proof or a prerequisite for harmless work.

Before coordinator completion, independently re-read changed lines, run relevant checks, inspect current diff/status, and verify every original requirement. A worker handoff is an unreviewed PR: no acceptance claim, commit, teardown, or user success statement depends on it until the coordinator verifies it. Preserve unrelated dirty paths as explicit exclusions; never bundle them into a critic target or commit.
