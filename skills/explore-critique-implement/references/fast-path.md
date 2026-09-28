# ECI fast path

This is the normative contract for the Fast owner and its integration with main ECI. Each role follows its assigned duties; lifecycle and acceptance remain coordinator-owned.

## Start and lifetime

- Start one Fast owner alongside Step 1 for every new ECI task, including bounded ECI under ATE. Neither path waits for the other's solution.
- Additive extensions update the existing owner's scope. A distinct new ECI task gets its own owner; iterations, reviews, repairs, and re-exploration reuse that identity.
- Preserve root workflow and markers. Direct work and ATE outside nested ECI do not acquire this protocol by loading it.
- Assign original requirements, authorized targets, dirty-work exclusions, current ECI decisions, verification, and shared-tree rules. The Fast owner owns the whole root-task outcome, not a lane; it is a reusable ordinary implementation producer, distinct from the main implementer and all independent critics.
- Finish assigned milestones, stop task-owned write-capable tools, and report completion promptly. The Fast owner remains accountable for delegated work and keeps the reusable identity idle through acceptance or cancellation; new evidence or ECI changes may require adaptation.
- Reserve launch capacity for both paths. If constrained, start available work, queue the missing role for the next slot, and report actual concurrency. Yield fast execution when required ECI work needs capacity, retaining ownership and evidence. Do not merge producer/reviewer identities or add compensating artifacts.

## Progress waits

Use either path's available results once independently verified and the next action's dependencies are satisfied. Independent work in the other path does not block intermediate progress. Normal-path completion requires the [post-Fast sequence](#post-fast-completion). Apply the [CODEX.md dependency scheduling rule](../../../CODEX.md#concurrent-tasks) across independent tasks, including ECI nested under ATE. Preserve [required review and E2E aggregation](coordinator.md#step-4--review-coordination) and the [write-yield, final-acceptance, and closure boundaries](#adoption-review-and-closure).

## Fast solving and delegation

- Track the root-task outcome as achievable milestones in existing task tracking. Extend them only for in-scope work; report out-of-scope findings without expanding authorization. Keep milestone status, verification evidence, and checkpoints current. Delegated work need not be organized into lanes; delegation alone does not create a lane.
- Prioritize in-scope paths under [Main ECI quality responsibility](#main-eci-quality-responsibility).
- Own the whole task while delegating any bounded, in-scope work that can accelerate it. Delegation is highly encouraged. Helpers may advance different lanes or other work; delegation does not transfer root-task accountability or create a separate outcome. Assign clear scope and expected evidence, integrate helper results, and account for every delegated finding and change.
- Choose each helper's model and reasoning effort under [Model selection](../SKILL.md#model-selection) for its assigned activity, independently of the Fast owner's profile.
- Personally advance other bounded work and validate the provisional Fast result with focused checks, with or without helpers. Run an early E2E only for a concrete failure or integration uncertainty under the [central ECI E2E policy](../SKILL.md#e2e-cadence-scope-and-timing). Iterate without waiting for main ECI Steps 1–4.
- Analysis-only requests authorize analysis and evidence only. Preserve secret-handling, destructive-action, external-mutation, unrelated-dirty-work, and target-reread safeguards. Speed grants no broader or irreversible authority.
- Defer the main path's design/style/TDD/review sequence for provisional fast work. Run useful focused checks; do not run routine E2E between iterations. Any early E2E follows the central policy's shortest-faithful-scope and timing rules. If an early E2E is needed but unavailable, report the missing resource and attempted evidence; never equate proxy checks with E2E.
- Promptly send actionable discoveries, failed assumptions, observed behavior, tradeoffs, touched targets, and verification limits to the coordinator for Explorer and Step 2.

Fast-owner E2E follows the [central ECI policy](../SKILL.md#e2e-cadence-scope-and-timing), including per-run timestamps, comparable-run regression checks, and parallel optimization when a material regression appears.

## Shared tree and ECI priority

- Both paths use the same checkout and live files. Do not copy the project, branch, stash, or create worktrees to avoid conflicts.
- ECI's selected design and changes take priority within the authorized task. The main implementer may change or replace provisional fast work; unrelated user and other-task work remains protected.
- Before each write, reread the current target and edit narrowly. If concurrent changes invalidate the edit, reread and adapt; never force a stale whole-file replacement.
- When ECI needs an overlapping target, the Fast owner yields affected writes, preserves ECI changes, and adapts its solution and checks. Continue unaffected useful work; ECI does not wait for the fast solution.
- Attribute results to the state exercised. A relevant concurrent change makes affected results stale; rerun them.

## Main ECI quality responsibility

Main ECI establishes design and quality from original requirements and applicable standards. Treat existing Fast work as a candidate implementation, never as acceptance or an authoritative design premise. Its presence, checkpoint, sunk cost, deadline pressure, or passing tests alone does not settle quality or restrict exploration to polishing it.

Evaluate viable alternatives within authorized scope for correctness, maintainability, architecture, and applicable style. Explorer develops options; Step 2 independently selects the winner; implementation meets it; Step 4 applies the same quality scrutiny to retained Fast work and main-path changes.

Preserve useful verified discoveries, still-valid tests, and qualifying code in place. Revise or replace material deficiencies through normal ECI. Fast provenance or cosmetic preference alone does not justify a rewrite.

After scope-screening, rank in-scope options and current repair directions by qualitative user-requirement progress per forecast time: prefer paths expected to move the requested solution further toward usability for the time they take. Use the [canonical ECI scenario forecast method](../../maintaining-context-ledger/SKILL.md#eci-scenario-forecasts) and relevant current milestone or dependency evidence as time estimates; state material tradeoffs or uncertainty when they cannot distinguish paths. Do not invent impact scores or per-finding ETAs. This changes work order only: separate-outcome concerns stay post-ECI, and no original requirement, necessary repair, check, proof, or gate is waived.

After scope-screening and priority ranking, maintain one concise, actionable `TODO:` comment beside the relevant code for each already-discovered code issue below the current top-priority direction that remains unfixed. Reuse an existing TODO if it covers the issue, update it if stale or incomplete, and add one only if absent. State the observed issue and known fix direction; do not search for or investigate further issues to populate TODOs. A TODO records follow-up only: it changes no scope, priority, `now` or blocker status, acceptance, deferral eligibility, or in-scope disposition, and never replaces a required in-scope repair.

A separate-outcome issue remains post-ECI; its TODO is the only code change directed at that issue. Do not investigate or repair it, or create a separate issue-specific lane, blocker, deadline, forecast, proof, or review. Remove the TODO when the issue is fixed.

Reviewers report only. The assigned implementer authors the TODO within the ordinary implementation, full current-diff review, independent verification, and checkpoint flow; review the complete diff, not only the TODO hunk. If no current assignment covers it, the coordinator routes a bounded TODO-only implementer assignment and independently verifies and checkpoints the edit under [coordinator repository-edit routing](coordinator.md#engage-and-route). The coordinator edits directly only under that section's narrow exception for genuine code-edit edge cases.

## Evidence can reopen design

- The coordinator independently verifies material fast discoveries and gives the evidence to Explorer and fresh Step 2.
- When evidence invalidates a selected premise, obsoletes the design, or demonstrates a materially better in-scope approach, the coordinator returns affected work to Steps 1–2. Suspend only dependent implementation/review; keep independent work moving.
- ECI priority governs decisions and conflicting writes, never dismissal of contradictory evidence. The Fast owner proposes alternatives; Step 2 selects the authoritative winner.
- Route minor compatible corrections through the contained-fix path. Unsupported preferences and ordinary fast edits do not restart design.

## Adoption, review, and closure

- Report fast results as provisional with exact evidence and limits. Fast E2E is producer evidence, not acceptance or independent review.
- After each issue is resolved, immediately hand off its change and evidence for a separate coordinator-owned checkpoint commit. This includes delegated work. The coordinator independently verifies the scoped change and commits it promptly; do not batch resolved issues or wait for remaining milestones, main-path adoption, or Step 4. The Fast owner never commits. A resolution without file changes needs evidence, not an empty commit.
- The main implementer inspects retained fast changes in place, adopts or revises them under the selected winner, and runs focused checks. Required final E2E follows the central policy after post-Fast implementation is complete. No copying or redundant rewrite is needed.
- Before checkpointing overlapping work, the coordinator obtains a bounded write-yield from both producers and inspects actual scoped changes. It owns checkpoints and preserves unrelated hunks; resume useful work afterward.
- If a checkpoint cannot safely isolate the resolved change, record it as checkpoint-pending with the concrete conflict. Resolve that boundary promptly while unaffected work continues; never silently treat it as committed or include unrelated/in-flight changes.
- The coordinator reconciles every Fast finding and Fast-originated changed hunk under [post-Fast completion](#post-fast-completion), then tracks each in-scope inventory item into review. Retained fast hunks are cumulative code targets. When a preceding baseline contains adopted fast changes, add its unreviewed hunks as an explicit cumulative review target alongside the narrow iteration checkpoint; never exclude them as predecessor context.
- Neither producer supplies its own independent acceptance reviews. Step 4 runs the fresh independent final E2E required by the central policy.
- Before normal-path completion or final acceptance, satisfy [post-Fast completion](#post-fast-completion). The coordinator stops both producers' task-owned writes, including delegated Fast work, inspects the current cumulative scoped diff, and verifies reviews and checks cover that state. Material late edits require fresh appropriate review and verification.
- On task cancellation/replacement, the coordinator cancels the Fast owner and its delegated work with the main task and preserves dirty changes/evidence. On task clean pass, it observes both producers' final state. On either closure path, it observes both producers and their task-owned write-capable tools stopped or finished. Root teardown and marker removal follow [concurrent task scheduling](../../../CODEX.md#concurrent-tasks). Fast success alone never closes ECI or outer ATE.

## Post-Fast completion

Main ECI may advance and review iterations concurrently with Fast.

After the coordinator confirms genuine Fast completion, report root-task status
`FOLLOWUP` while the required sequence below remains unaccepted. Use
`FOLLOWUP_PAUSED` only when the next required post-Fast action cannot advance
because it awaits a named in-scope dependency. Report the dependency, impact,
owner, and resume condition; return to `FOLLOWUP` when it clears. A user input
or decision remains `BLOCKED` in the affected lane, never `FOLLOWUP_PAUSED`.
End either root-task status on coordinator acceptance or explicit user closure.
Keep these statuses outside lane Implementation/Test/Prod readiness; see
[status guidance](../../writing-status-reports/SKILL.md#multi-lane-mission-status).

A genuine Fast completion restarts the normal path from a fresh Step 1.

Any Step 4 review that runs concurrently before this restart is intermediate only and never acceptance. The normal path remains incomplete until this post-Fast sequence passes for the task:

1. The coordinator observes that the Fast owner has finished its assigned work, including delegated work, and all task-owned write-capable tools have stopped. A write-yield, idle label, timeout, or cancellation is not Fast completion. Keep Fast idle while main ECI performs the following steps; Fast need not wait for main acceptance to finish.
   - The Fast owner completion report enumerates every finding and changed hunk from the Fast owner and its helpers.
   - Include findings with no retained hunk and changes that are retained, revised, non-retained, superseded, or reverted.
   - Inventory states retained, revised, non-retained, superseded, and reverted are provenance only, not canonical dispositions; no inventory state implies a disposition.
   - The coordinator reconciles the report with shared state.
   - This complete inventory is review context, never a manifest, receipt, or admission/write gate.
   - Final acceptance requires every in-scope inventory item to have a disposition and evidence.
2. Restart main ECI at a fresh Step 1.
   - Scope-screen every Fast finding and every Fast-originated changed hunk against `exact user source → faithful requested outcome → bounded scope`. Keep only repairs necessary to meet or prove that outcome in scope.
   - Keep every Fast-originated hunk in inventory/review context; do not expand authorization. A separate-outcome finding stays a post-ECI observation/follow-up and creates no issue-specific repair, review, proof, or acceptance work. Allow only the TODO comment defined under [Main ECI quality responsibility](#main-eci-quality-responsibility) for an already-discovered code issue; include its hunk in ordinary current-diff review and keep the issue in inventory context only.
   - Then assign the reusable Explorer a new Step 1 exploration of the final shared scoped code, started after Fast completion. The Explorer reviews every in-scope Fast finding and every in-scope Fast-originated changed hunk for quality.
   - The Explorer reviews each in-scope inventory item against original requirements and quality standards, alongside retained main-path changes. Reread current targets and relevant surrounding code. Prior exploration, diffs, and passing tests are context, not this new exploration.
3. A fresh Step 2 critic independently assesses the current sources and Explorer's options.
   - The fresh Step 2 critic reviews every in-scope Fast finding and every in-scope Fast-originated changed hunk and recommends exactly one canonical disposition for each in-scope inventory item: retain, revise, replace, superseded, resolved-with-evidence, or policy-valid deferred-with-reason, under [main ECI quality responsibility](#main-eci-quality-responsibility).
   - Step 2 authority is limited to design-winner selection; it does not apply treatment.
   - The coordinator owns final disposition application/treatment and applies exactly one canonical disposition per in-scope inventory item.
   - Apply impact-proportional routing before implementation.
   - Return substantive `now` findings or design/API uncertainty through one complete fresh Steps 1–2 repair batch.
   - Send a `treatment: now` finding to the implementer once only if it is contained, in-scope, impact-trivial, and isolated.
   - A coordinator-applied `revise` or `replace` disposition reaches the implementer as `treatment: now` only when it is in-scope, contained, impact-trivial, and isolated; otherwise return through one complete fresh Steps 1–2 design-repair batch before implementation.
   - Other dispositions require evidence, not implementation.
   - Carry the resulting disposition and evidence into Step 4; never leave it unresolved.
   - Use policy-valid deferred-with-reason only where [review-policy.md#impact-proportional-routing](../../references/workflow-runtime/review-policy.md#impact-proportional-routing) permits.
   - A policy-valid deferred-with-reason disposition is only for an in-scope, non-hard, impact-trivial, isolated finding; it requires evidence supporting each eligibility condition, plus a technical reason and revisit trigger; it never waives original criteria.
   - Missing evidence invalidates only that defer conclusion; it never waives criteria or gates unrelated bounded work.
   - Preserve qualifying code; make only justified changes through the main implementer.
   - The implementer fixes every routed `treatment: now` finding and fixes or justifies every retained Fast finding and every retained Fast-originated change under that selected winner, including no-hunk findings.
   - Every no-hunk retain or resolved-with-evidence outcome requires evidence.
   - The implementer implements those routed coordinator-applied revise/replace changes and validates retained/revised changes.
   - The implementer supplies evidence for no-hunk resolutions and for non-retained, superseded, reverted, resolved, and deferred outcomes.
   - Run required focused checks and checkpoint changed iterations normally. Reserve triggered final E2E for the stabilized candidate under the central policy.
4. After the fresh Step 1, Step 2, and implementer disposition, the final cumulative Step 4 independently reviews the final cumulative scoped state even when no further edits are needed.
   - The final cumulative Step 4 verifies every in-scope inventory item has exactly one disposition and final evidence.
   - The final cumulative Step 4 leaves no unresolved in-scope `treatment: now` finding or failed-eligibility `revise`/`replace` needing implementation.
   - Separate-outcome observations remain outside acceptance.
   - Aggregate all required critics and the final E2E pair when triggered, resolve remaining `now` findings, and verify coverage of the current state before completing the normal path or accepting the task.
   - Earlier reviews alone cannot satisfy this sequence.

Resumed Fast writes invalidate this sequence; after Fast finishes again, repeat it. Later main-path or interacting task edits refresh affected review and verification; material design findings return through Steps 1–2. Independent sibling tasks keep advancing.

Cancellation uses user closure, never a clean pass or substitute Fast completion. Preserve changes and evidence, observe task-owned writers stopped, and keep uncancelled siblings active under the existing closure rules.
