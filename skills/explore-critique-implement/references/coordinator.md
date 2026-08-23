# ECI Coordinator

Coordinator-only ECI lifecycle. Load shared coordinator runtime before this module and load blocker-resolution-protocol only after ordinary ECI issue handling fails.

## Engage and route

- Maintain the project-understanding ledger through maintaining-context-ledger. Apply requirement-lineage admission before every routing change or durable execution.
- Create the direct ECI marker before Step 1 and keep it through all governed work. An outer ATE marker does not replace it. Never disengage to evade the write gate; route edits to the reusable implementer.
- ECI has reusable Explorer and implementer producers. Each Step 2 critic, Critic A/B/C, E2E, brainstormer, feasibility validator, and loop-breaker is a fresh isolated identity. Producer and critic identities never overlap.
- Each packet contains original requirements where required, exact scope, lane/assignment binding, full requirement chain, paths/edges, expected output, claim tags, Stop-hook instruction, and exactly one `Stage: normal` or `Stage: emergency`. A failed lineage/model/boundary admission stops the provider call.
- When a lane or assignment is `Stage: emergency`, the packet records the [Emergency Unblock](emergency-unblock.md) protocol and `provisional Emergency Unblock — unchecked`; before any resume, record the `emergency→normal ECI Step 1` transition in the assignment and current ledger state.
- Follow the shared pause-all-work and stop-recovery modules only on their exact predicates. Load policy-pressure-tests only for workflow-policy changes.

## Step 4 — Review coordination

After Step 3, the coordinator alone assigns fresh Critic A, Critic B, Critic C, and E2E for code/debug work. Each reviewer is independent of producers and receives original requirements, current diff, objective/criteria, pre-routing record, applicable style evidence, exact lens, and claim-tag rules.

Before dispatch, validate fresh identity, lineage/assignment binding, current requirements/diff, and supplied evidence. Keep the required-role and evidence bindings in the shared runtime record; missing, stale, or contradictory evidence blocks the gate.

Wait for all required review and E2E evidence before aggregating. Pre-route every finding with the review policy. Send substantive `now` findings or design/API uncertainty back as one complete Steps 1–2 repair batch; send a trivial `now` finding once to the implementer. Preserve auditable debt/defer/ignored-contradictory records without treating them as a clean result. Use the shared coordinator/runtime policy for repair cycles, clean-pass, and limits.

## Blockers, bugs, and limits

Concrete bug/failure/flake/performance/incorrect behavior enters delegated debugging-discipline roles: repro, RCA/regression, Step 2 critic, implementer, A/B/C, and E2E. Write/update the regression report before RCA; require a falsifiable cause, regression status, previous/current evidence, and proof on the real failing path.

After a first Step 2 all-REJECT, route the verbatim findings to one Explorer revision, then assign a fresh blind Step 2 critic. A second all-REJECT enters the ordinary blocker route.

Use blocker-resolution-protocol only after normal handling cannot resolve a stall, after Step 2’s bounded all-REJECT path, or after a gate/cycle limit. A subagent blocker is not mission blocker. BRP uses a primary explorer and separate feasibility validator; a fresh idea-only brainstormer runs for genuine stalls. At the configured gate/cycle cap, invoke one fresh loop-breaker. It may ACCEPT only a demonstrated clean pass, RETRY exactly once with guidance, or BLOCKED into BRP. Hard escalation reports the original problem, attempts, final issue, and next-best option while ECI stays active.

## Clean pass and teardown

An iteration is Step 1 explore → Step 2 critique → Step 3 implement → Step 4 parallel review. Do not advance the change until its gate is clean. A clean pass needs every original criterion and applicable proof/E2E, no remaining `now` REJECT/CONDITIONAL, and same-gate proof.

On clean pass or user closure: write the disengage report; request/observe final implementer confirmation; record role state without closing terminal agents; then run `eci-active off <report>` last. The report contains exactly one `clean-pass:` or `user-closed:` certificate, Stop-checklist walkthrough, and incomplete-compliance analysis. Teardown failure keeps the marker armed.

Status uses human-readable role/lane names, parent-child trees for nested work, and a nearby redacted-verbatim requirements registry for every non-empty canonical `Lane requirement refs`; every lane row, assignment state, and current ledger state records exactly one `Stage: normal` or `Stage: emergency`; the ledger carries the full edge chain. Direct work with inactive lineage does not fabricate refs. Use `<role label> (<runtime name>)` in every status, wait, or close update. Lineage failures are routing risks, never fake `PAUSED`/`BLOCKED` states.

## Provider adapter and marker

ECI uses only `spawn_agent`, `followup_task`, `send_message`, `wait_agent({timeout_ms:3600000})`, and cancellation-only `interrupt_agent`. If standard tools are unavailable, hard-escalate rather than shell-launch a Codex agent. `spawn_agent` starts a new role; `followup_task` starts a fresh turn only for an idle reusable producer; `send_message` is bounded in-turn delivery only. Label every spawned/resumed role and immediately update the roster as `<role label>: <runtime name> [type]`.

Before Step 1 of the first iteration run `eci-active on "<task + scope>"`. The main thread does not directly edit while engaged. An ATE `ate_active` marker alone is insufficient. Keep ECI active through blocker work, nested paths, review, and acceptance; user cancellation/withdraw/replacement/ATE switch is user closure only after checkpointing successor handoff or scope removal. A PostCompact signal requires the coordinator/lead to reread the full router and then its exact assigned modules before the next decision.

Every producer assignment says fresh task treatment: Explorer rereads every referenced file; implementer rereads every intended target. Every report/submission tags factual claims; E2E evidence identifies exact tool output/log/screenshot/state rather than bare “green.” Code/debug submissions include root-cause cause chain, evidence, regression status/explanation, and why the diff repairs the cause; unknown why is not submittable. The coordinator independently verifies each handoff before routing it as evidence.

## Exact team separation

Use one stable Explorer and one stable implementer across iterations. Every invocation of Step 2 critic, Critic A, Critic B, Critic C, E2E, brainstormer, BRP feasibility validator, and loop-breaker is a distinct blind identity; no producer acts as critic. A blind critic receives a self-contained prompt with role, original requirements, files/scope, sources to reread, expected output, and all review rules. Critic C code Packet 1 remains the shared runtime’s narrow diff-only exception, never an omission of admission checks. Reuse does not imply trust: a reusable producer still treats every turn as fresh.

## Bug and blocker packet rules

For a concrete bug write/update a human-readable regression report before RCA at `~/.cache/codex-proof/$SESSION_ID/eci-regression-reports/<task>.md` when `$SESSION_ID` exists, otherwise `./.codex-regression-reports/<task>.md`. It contains bug statement, repro, previous/current test artifacts, CI/log/release/QA evidence, known-good/current-bad anchors, regression status, missing evidence, and eventual regression explanation. The RCA packet names the report and says: load debugging-discipline; follow repro/RCA-critic/fix-review; determine `regression: yes/no/unknown`; if regression explain how it happened; do not submit until root cause is falsifiable and the fix is proven on the real failing path.

An isolated disposable repro/PoC may run before style admission, but no production reuse/copy/adaptation occurs until final-scope admission. Normal issue handling precedes BRP. A genuine stall needs the blocker-resolution-protocol required record/attempt log; “I am stuck” is not enough. BRP primary explorer, fresh brainstormer, and separate feasibility validator are distinct roles. Only validator-approved feasible ideas reach a producer after BRP.

## Brainstormer, loop-breaker, and caps

Brainstormer is fresh, blind, and idea-only: original problem, attempts, paths, and “generate as many distinct ideas as possible; no filtering, feasibility judgment, negatives, or winner.” It never directly decides or edits. It fires after zero viable documented options, Step 2 bounce cap, or genuine implementer stall, together with BRP fact gathering/validation.

Use one fresh loop-breaker per change when three gate retries in a cycle, three failed full cycles, or the post-brainstorm Step 2 all-REJECT condition reaches its limit. Its self-contained packet includes original problem, all attempts/failures/issues, current paths, pre-routing, gate/E2E/proof evidence, and clean-pass assessment. It returns exactly `ACCEPT`, `RETRY`, or `BLOCKED`: ACCEPT only when clean pass already holds and waives nothing; RETRY grants exactly one matching retry with guidance; BLOCKED creates a protocol-limit record and enters BRP. Failed retry or exhausted limit never silently settles for good enough.

## Teardown certificate

The disengage report has `## ECI completion certificate` with exactly one `clean-pass:` or `user-closed:` evidence line; `## Stop checklist walkthrough` covering Questions, Git, Completion, Root cause, Adversarial self-critique, Assumed blockers, Rule-compliance self-audit, Project understanding ledger, and Testing; and `## Incomplete compliance` with each gap/impact or explicit `fully-compliant:` rule-by-rule explanation. It may instead include full Codex sections `Summary`, `Verification`, `Requirements`, `Root Cause`, `Claim Inventory`, `Pre-Mortem`, `Adversarial Critique`, `Rule-Compliance Self-Audit`, and `Gaps`; either form needs substance, not boilerplate. After it, request/observe implementer final confirmation, record each role completed/idle/cancelled/still-running, and invoke `eci-active off <report>` last. A timeout/silence is nonterminal; never close a terminal agent to finish teardown.

## Coordinator red flags

- Two changes are implemented before a new critique, or an iteration skips any of Steps 1–4.
- A critic prompt lacks lineage/full chain, original requirements, concrete winner text, or applies a defer/debt as implementation.
- A fresh critic is replaced by a producer, a same-role followup, or serial review.
- A known bug is sent to BRP before debugging discipline/attempt record.
- An unchanged Stop block causes a status/final/retry instead of one distinct recovery action or wait.
- A stable reusable producer is replaced while idle, a `send_message` is used to start its turn, or a special/fresh critic is upgraded by followup.
- A status report uses task/iteration numbers or flattens nested work, or a lane packet omits the full chain outside Critic C Packet 1.
