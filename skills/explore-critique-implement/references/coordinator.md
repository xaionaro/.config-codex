# ECI Coordinator

Coordinator-only ECI lifecycle. Load shared coordinator runtime before this module and load blocker-resolution-protocol only after ordinary ECI issue handling fails.

## Engage and route

- Apply [concurrent task scheduling](../../../CODEX.md#concurrent-tasks): admit independent user requests under the active lifecycle, keep task-owned producer identities, and scope stage/checkpoint waits to the affected task.
- Maintain the project-understanding ledger through maintaining-context-ledger. Use lineage to explain ownership and handoffs; do not make normal work wait on a lineage artifact, hash, receipt, or schema shape.
- Create the direct ECI marker before Step 1 and keep it through all governed work. An active ATE marker does not replace it. Route ordinary repository-code edits to the reusable implementer; do not disengage merely to change routing.
- ECI has reusable Explorer, implementer, and Fast owner producers. Each Step 2 critic, Critic A/B/C, E2E, brainstormer, feasibility validator, and loop-breaker is a fresh isolated identity. Producer and critic identities never overlap.
- Each packet states exact scope, target/change/verification when it assigns implementation, expected output, claim tags, and Stop-hook instruction. Missing coordination detail is repaired by a concise handoff or clarification; it does not block harmless work.
- Treat records, hashes, receipts, packet shape, and marker spelling as context or audit, never as permission checks. Route only a concrete accidental wrong-target, cross-scope, or destructive effect.
- For every relevant coordinator-to-user ECI progress update, report this standalone line for each executing lane:
  - `Forecast deadline: <named lane/task outcome> will be finished by <UTC ISO8601>.`
- For each unrepresented active root-task outcome omitted by lane reports, include this standalone line:
  - `Root completion forecast: <named active root-task outcome> will be finished by <UTC ISO8601>.`
- For material ECI work, retain `exact user source → faithful requested outcome → bounded scope`.
- A repair needed to meet or prove that outcome stays in its current lane; a
  separate-outcome concern is only a post-ECI observation or follow-up, never
  current work or a forecast.
- Reconcile missing or stale lineage alongside known work; it does not block progress.
- If false current scope is discovered, correct the ledger/status and log the correction. Cancel or reassign only unrooted current work; do not destructively revert already-made work without user direction.
- The forecast line itself names the finished outcome; a separate Lane or Next milestone does not substitute, and it never names a critic, reviewer, actor, or stage. Root completion is full root completion, not a child sum or stage.
- Use the two templates above exactly: named lane/task or root outcome and UTC deadline only. Do not append text.
- For a changed lane or root forecast, restate its current canonical line in the same update, then state Forecast recalibration: <prior UTC ISO8601> → <current UTC ISO8601>; why moved: <why>; supporting evidence: <evidence>.
- If any forecast is missing or stale, say so and reconcile it alongside safe work without delaying the update.
- Forecasts are advisory. They never gate work, grant or deny permissions, require artifacts or receipts, create blockers, require parsers, or require per-command ceremony.
- Use the [`forecast-target-history.tsv` audit contract](../../maintaining-context-ledger/SKILL.md#forecast-target-history) for every root-target transition. It is audit-only and never a gate.
- Before a coordinator edits ordinary repository code, create or reuse a bounded implementer assignment with the target, intended change, and verification. Do not attempt then deny the ordinary edit. Report the handoff. If no implementer is free, queue it and continue other admitted work; capacity alone is not a user blocker. Session coordination documents, ledgers, plans, status reports, handoffs, and proof notes remain coordinator-owned. A genuine code-edit edge case may use the session-scoped self-service coordinator self-edit hatch for 600 seconds; re-activation replaces rather than stacks the window. It needs no user approval artifact and changes routing only.
- Apply [ECI fast path](fast-path.md) at task launch and throughout shared-tree coordination, evidence rerouting, review, and closure.
- Follow the shared pause-all-work and stop-recovery modules only on their exact predicates. Load policy-pressure-tests only for workflow-policy changes.

## Step 4 — Review coordination

After every implementer handoff, independently verify the exact scoped diff and create the one narrow coordinator-owned checkpoint commit before Step 4 or another implementation iteration. The review packet gives each reviewer the named checkpoint, its parent-to-checkpoint diff, and explicit exclusions. A `pre-existing baseline` is context outside the iteration range. A checkpoint commit is not acceptance.

Apply the [fast-path adoption boundary](fast-path.md#adoption-review-and-closure) for write-yields, additional cumulative review targets, and final-state coverage.

After this, the coordinator alone assigns fresh Critic A, Critic B, and Critic C. E2E joins only when an applicable policy requires it.

E2E requirements: [Configuration E2E contract](../SKILL.md#configuration-e2e-contract) and [Runtime E2E policy](../SKILL.md#runtime-e2e-policy).

Name at least one critic in every critic round to check least restriction: bots are non-malicious; controls catch concrete accidental mistakes without turning normal work into permission ceremony.

Before dispatch, verify the assignment still names the right work, current requirements, named review range and exclusions, and supplied evidence. Missing or stale coordination evidence prompts refresh, reassignment, or an additional review; it does not stop ordinary exploration, implementation, or harmless verification.

Wait for all required review and E2E evidence before aggregating. Pre-route every finding with the review policy. Send substantive `now` findings or design/API uncertainty back as one complete Steps 1–2 repair batch; send a trivial `now` finding once to the implementer. Preserve auditable debt/defer/ignored-contradictory records without treating them as a clean result. Use the shared coordinator/runtime policy for repair cycles, clean-pass, and limits.

## Blockers, bugs, and limits

Concrete bug/failure/flake/performance/incorrect behavior enters delegated debugging-discipline roles: repro, RCA/regression, Step 2 critic, implementer, A/B/C, and E2E. Capture a regression report or current coordination note before or alongside RCA; require a falsifiable cause, regression status, previous/current evidence, and proof on the real failing path.

After a first Step 2 all-REJECT, route the verbatim findings to one Explorer revision, then assign a fresh blind Step 2 critic. A second all-REJECT enters the ordinary blocker route.

Use blocker-resolution-protocol only after normal handling cannot resolve a stall, after Step 2’s bounded all-REJECT path, or after a gate/cycle limit. A subagent blocker is not mission blocker. BRP uses a primary explorer and separate feasibility validator; a fresh idea-only brainstormer runs for genuine stalls. At the configured gate/cycle cap, invoke one fresh loop-breaker. It may ACCEPT only a demonstrated clean pass, RETRY exactly once with guidance, or BLOCKED into BRP. Hard escalation reports the original problem, attempts, final issue, and next-best option while ECI stays active.

## Clean pass and teardown

Accept each task against its own required evidence. Keep the root marker and unfinished siblings active after an individual task clean pass or cancellation; run root teardown only when every owned task is accepted or explicitly cancelled and its writers have stopped.

An iteration is Step 1 explore → Step 2 critique → Step 3 implement → Step 4 parallel review. Do not advance the change until its gate is clean. A clean pass needs every original criterion and applicable proof/E2E, no remaining `now` REJECT/CONDITIONAL, and same-gate proof.

On root clean pass or root user closure: apply [both-producer closure](fast-path.md#adoption-review-and-closure); write the disengage report; request/observe final implementer confirmation; record role state without closing terminal agents; then run `eci-active off <report>` last. The report contains exactly one `clean-pass:` or `user-closed:` certificate, Stop-checklist walkthrough, and incomplete-compliance analysis. Teardown failure keeps the marker armed.

Status uses human-readable role/lane names, parent-child trees for nested work, and a nearby redacted-verbatim requirements registry for every non-empty canonical `Lane requirement refs`; ECI records `Stage: normal` with main and fast progress under the same task. The ledger carries the full edge chain. Direct work with inactive lineage does not fabricate refs. Use `<role label> (<runtime name>)` in every status, wait, or close update. Lineage failures are routing risks, never fake `PAUSED`/`BLOCKED` states.

## Provider adapter and marker

ECI uses only `spawn_agent`, `followup_task`, `send_message`, `wait_agent({timeout_ms:3600000})`, and cancellation-only `interrupt_agent`. If standard tools are unavailable, hard-escalate rather than shell-launch a Codex agent. `spawn_agent` starts a new role; `followup_task` starts a fresh turn only for an idle reusable producer; `send_message` is bounded in-turn delivery only. Label every spawned/resumed role and immediately update the roster as `<role label>: <runtime name> [type]`.

Before Step 1 of the first iteration run `eci-active on "<task + scope>"`. While engaged, route ordinary repository-code edits through the implementer assignment above. The coordinator may directly maintain coordination records, and may use the 600-second nonstacking self-edit routing exception for a genuine code-edit edge case. An ATE `ate_active` marker alone is insufficient. Keep ECI active through blocker work, nested paths, review, and acceptance; user cancellation/withdraw/replacement/ATE switch is user closure only after checkpointing successor handoff or scope removal. A PostCompact signal requires the coordinator/lead to reread the full router and then its exact assigned modules before the next decision.

Every producer assignment says fresh task treatment: Explorer rereads every referenced file; implementer rereads every intended target. Every report/submission tags factual claims; E2E evidence identifies exact tool output/log/screenshot/state rather than bare “green.” Code/debug submissions include root-cause cause chain, evidence, regression status/explanation, and why the diff repairs the cause; unknown why is not submittable. The coordinator independently verifies each handoff before routing it as evidence.

## Exact team separation

Use stable Explorer and implementer identities across iterations, plus the Fast owner lifetime defined in [ECI fast path](fast-path.md#start-and-lifetime). Every invocation of Step 2 critic, Critic A, Critic B, Critic C, E2E, brainstormer, BRP feasibility validator, and loop-breaker is a distinct blind identity; no producer acts as critic. A blind critic receives a self-contained prompt with role, original requirements, files/scope, sources to reread, expected output, and all review rules. Critic C code Packet 1 remains the shared runtime’s narrow diff-only exception, never an omission of quality checks. Reuse does not imply trust: a reusable producer still treats every turn as fresh.

## Bug and blocker packet rules

For a concrete bug, capture its statement, repro, previous/current evidence, regression status, and missing evidence in a readable regression report or current coordination note before or alongside RCA. Use debugging-discipline; require a falsifiable cause and proof on the real failing path. Do not make a fixed file path, artifact, or report schema a prerequisite for investigation.

An isolated disposable repro/PoC may run before style review. Normal issue handling precedes BRP. For a genuine stall, record the useful attempts and choose an Explorer, brainstormer, or feasibility validator as needed; do not make a fixed blocker artifact or role sequence a prerequisite for continued ordinary work.

## Brainstormer, loop-breaker, and caps

Brainstormer is fresh, blind, and idea-only: original problem, attempts, paths, and “generate as many distinct ideas as possible; no filtering, feasibility judgment, negatives, or winner.” It never directly decides or edits. It fires after zero viable documented options, Step 2 bounce cap, or genuine implementer stall, together with BRP fact gathering/validation.

Use one fresh loop-breaker per change when three gate retries in a cycle, three failed full cycles, or the post-brainstorm Step 2 all-REJECT condition reaches its limit. Its self-contained packet includes original problem, all attempts/failures/issues, current paths, pre-routing, gate/E2E/proof evidence, and clean-pass assessment. It returns exactly `ACCEPT`, `RETRY`, or `BLOCKED`: ACCEPT only when clean pass already holds and waives nothing; RETRY grants exactly one matching retry with guidance; BLOCKED creates a protocol-limit record and enters BRP. Failed retry or exhausted limit never silently settles for good enough.

## Teardown certificate

The disengage report has `## ECI completion certificate` with exactly one `clean-pass:` or `user-closed:` evidence line; `## Stop checklist walkthrough` covering Questions, Git, Completion, Root cause, Adversarial self-critique, Assumed blockers, Rule-compliance self-audit, Project understanding ledger, and Testing; and `## Incomplete compliance` with each gap/impact or explicit `fully-compliant:` rule-by-rule explanation. It may instead include full Codex sections `Summary`, `Verification`, `Requirements`, `Root Cause`, `Claim Inventory`, `Pre-Mortem`, `Adversarial Critique`, `Rule-Compliance Self-Audit`, and `Gaps`; either form needs substance, not boilerplate. After it, request/observe implementer final confirmation, record each role completed/idle/cancelled/still-running, and invoke `eci-active off <report>` last. A timeout/silence is nonterminal; never close a terminal agent to finish teardown.

## Coordinator red flags

- Two dependent changes in one task are implemented before a new critique, or a main-path iteration skips any of Steps 1–4.
- A critic prompt lacks lineage/full chain, original requirements, concrete winner text, or applies a defer/debt as implementation.
- A fresh critic is replaced by a producer, a same-role followup, or serial review.
- A known bug is sent to BRP before debugging discipline/attempt record.
- An unchanged Stop block causes a status/final/retry instead of one distinct recovery action or wait.
- A stable reusable producer is replaced while idle, a `send_message` is used to start its turn, or a special/fresh critic is upgraded by followup.
- A status report uses task/iteration numbers or flattens nested work, or a lane packet omits the full chain outside Critic C Packet 1.
- An ordinary repository-code edit reaches any denial path instead of an automatic bounded implementer handoff or queue.
- A normal command or routing step waits on an artifact, receipt, hash, allowlist, raw spelling, or shell punctuation without a concrete accidental destructive effect.
