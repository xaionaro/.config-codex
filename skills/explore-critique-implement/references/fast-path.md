# ECI fast path

This is the normative contract for the Fast owner and its integration with main ECI. Each role follows its assigned duties; lifecycle and acceptance remain coordinator-owned.

## Start and lifetime

- Start one Fast owner alongside Step 1 for every new ECI task, including bounded ECI under ATE. Neither path waits for the other's solution.
- Additive extensions update the existing owner's scope. A distinct new ECI task gets its own owner; iterations, reviews, repairs, and re-exploration reuse that identity.
- Preserve root workflow and markers. Direct work and ATE outside nested ECI do not acquire this protocol by loading it.
- Assign original requirements, authorized targets, dirty-work exclusions, current ECI decisions, verification, and shared-tree rules. The Fast owner is a reusable ordinary implementation producer, distinct from the main implementer and all independent critics.
- Keep the owner available through acceptance or cancellation. A working result ends unnecessary edits; new evidence or ECI changes may require adaptation.
- Reserve launch capacity for both paths. If constrained, start available work, queue the missing role for the next slot, and report actual concurrency. Yield fast execution when required ECI work needs capacity, retaining ownership and evidence. Do not merge producer/reviewer identities or add compensating artifacts.

## Progress waits

Use either path's available results once independently verified and the next action's dependencies are satisfied. Independent work in the other path is not a completion prerequisite. Apply the [CODEX.md dependency scheduling rule](../../../CODEX.md#concurrent-tasks) across independent tasks, including ECI nested under ATE. Preserve [required review and E2E aggregation](coordinator.md#step-4--review-coordination) and the [write-yield, final-acceptance, and closure boundaries](#adoption-review-and-closure).

## Solo solving

- Track the problem as a list of achievable milestones in existing task tracking. Extend it as investigation reveals additional in-scope issues; report out-of-scope findings without expanding authorization. Keep each milestone's status, verification evidence, and checkpoint current.
- Independently investigate, implement the quickest bounded solution within existing authorization, and validate it end to end. Iterate without waiting for main ECI Steps 1–4; do not delegate solving work.
- Analysis-only requests authorize analysis and evidence only. Preserve secret-handling, destructive-action, external-mutation, unrelated-dirty-work, and target-reread safeguards. Speed grants no broader or irreversible authority.
- Defer the main path's design/style/TDD/review sequence for provisional fast work. Run useful focused checks and all applicable configuration/runtime E2E. If unavailable, report the missing resource and attempted evidence; never equate proxy checks with E2E.
- Promptly send actionable discoveries, failed assumptions, observed behavior, tradeoffs, touched targets, and verification limits to the coordinator for Explorer and Step 2.

E2E requirements: [Configuration E2E contract](../SKILL.md#configuration-e2e-contract) and [Runtime E2E policy](../SKILL.md#runtime-e2e-policy).

## Shared tree and ECI priority

- Both paths use the same checkout and live files. Do not copy the project, branch, stash, or create worktrees to avoid conflicts.
- ECI's selected design and changes take priority within the authorized task. The main implementer may change or replace provisional fast work; unrelated user and other-task work remains protected.
- Before each write, reread the current target and edit narrowly. If concurrent changes invalidate the edit, reread and adapt; never force a stale whole-file replacement.
- When ECI needs an overlapping target, the Fast owner yields affected writes, preserves ECI changes, and adapts its solution and checks. Continue unaffected useful work; ECI does not wait for the fast solution.
- Attribute results to the state exercised. A relevant concurrent change makes affected results stale; rerun them.

## Evidence can reopen design

- The coordinator independently verifies material fast discoveries and gives the evidence to Explorer and fresh Step 2.
- When evidence invalidates a selected premise, obsoletes the design, or demonstrates a materially better in-scope approach, the coordinator returns affected work to Steps 1–2. Suspend only dependent implementation/review; keep independent work moving.
- ECI priority governs decisions and conflicting writes, never dismissal of contradictory evidence. The Fast owner proposes alternatives; Step 2 selects the authoritative winner.
- Route minor compatible corrections through the contained-fix path. Unsupported preferences and ordinary fast edits do not restart design.

## Adoption, review, and closure

- Report fast results as provisional with exact evidence and limits. Fast E2E is producer evidence, not acceptance or independent review.
- After each issue is resolved, immediately hand off its change and evidence for a separate coordinator-owned checkpoint commit. The coordinator independently verifies the scoped change and commits it promptly; do not batch resolved issues or wait for remaining milestones, main-path adoption, or Step 4. The Fast owner never commits. A resolution without file changes needs evidence, not an empty commit.
- The main implementer inspects retained fast changes in place, adopts or revises them under the selected winner, and runs its required checks/E2E. No copying or redundant rewrite is needed.
- Before checkpointing overlapping work, the coordinator obtains a bounded write-yield from both producers and inspects actual scoped changes. It owns checkpoints and preserves unrelated hunks; resume useful work afterward.
- If a checkpoint cannot safely isolate the resolved change, record it as checkpoint-pending with the concrete conflict. Resolve that boundary promptly while unaffected work continues; never silently treat it as committed or include unrelated/in-flight changes.
- The coordinator tracks every retained fast hunk into review. When a preceding baseline contains adopted fast changes, add its unreviewed hunks as an explicit cumulative review target alongside the narrow iteration checkpoint; never exclude them as predecessor context.
- Neither producer supplies its own independent acceptance reviews. Step 4 independently repeats or extends required main-implementer E2E.
- Before final acceptance, the coordinator stops both producers' task-owned writes, inspects the current cumulative scoped diff, and verifies reviews and checks cover that state. Material late edits require fresh appropriate review and verification.
- On cancellation/replacement, the coordinator cancels the Fast owner with the main task, preserves dirty changes/evidence, and performs normal user-closure teardown. On clean pass, it observes both producers' final state before marker removal. On either closure path, it observes both producers and their task-owned write-capable tools stopped or finished before teardown. Fast success alone never closes ECI or outer ATE.
