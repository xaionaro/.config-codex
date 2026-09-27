---
name: explore-critique-implement
description: Use when CODEX selects ECI or active ATE routes bounded work through ECI
---

# Explore-Critique-Implement

Separate exploration, authoritative critique, implementation, and independent review. The builder never critiques its own output.

## Activation and invariants

Start only when CODEX selects ECI or active ATE explicitly routes bounded work through it. Loading this router alone does not start ECI. Use ECI for non-mechanical work with uncertainty, future behavior/routing/protocol risk, or two plausible approaches; classify by decision complexity and risk, not diff size. A one-line/local change is still non-trivial when it changes instructions, prompts, routing, protocols, public contracts, security, persistence, concurrency, architecture, or reviewer/agent behavior. Skip only a mechanical answer whose consequences are obvious, directly verifiable, and carry no future behavior or routing risk.

- Maintain requirement lineage and a project-understanding ledger. The active ECI/ATE lifecycle owns normal work; ATE may contain normal ECI.
- Apply [concurrent task scheduling](../../CODEX.md#concurrent-tasks) to new user requests, independent progress, task-local gates, and root closure. Each task keeps its own scope and main/Fast ownership.
- For material ECI work, keep `exact user source → faithful requested outcome →
  bounded scope`. A repair necessary to meet or prove that outcome stays current-lane work.
  For each already-discovered lower-priority code issue that remains unfixed, add the TODO defined by [Main ECI quality responsibility](references/fast-path.md#main-eci-quality-responsibility). It does not change an in-scope disposition or replace its required repair; for a separate-outcome issue, its TODO is the only code edit and the issue remains post-ECI.
  Missing or stale lineage never blocks known in-scope work.
- Every ECI task starts main ECI and one [Fast owner](references/fast-path.md) concurrently. That module owns launch, lifetime, shared-tree priority, evidence feedback, adoption, and closure rules.
- Follow the normative [post-Fast completion sequence](references/fast-path.md#post-fast-completion).
- Intermediate iteration progress remains concurrent.
- Record `Stage: normal` for ECI; show main and fast progress within the same task, not as separate stages or automatic lanes.
- A lane is an independently advancing workstream, not an ECI step. Serial implement→review→repair→review→implement stays one lane with one critical path. Create distinct lanes only for independently advancing work with separate ownership or synchronization.
- Every normal ECI worker reads this router plus the exact module(s) useful to its assignment. An unknown role, predicate, or link is reported to the coordinator and resolved while safe bounded assigned work continues; it does not itself deny or stall normal work.
- Own your assigned outcome through successful completion, required evidence, and complete handoff. Resolve recoverable obstacles with safe, authorized in-scope actions; use and verify available recovery paths before asking for help (for example, use authorized ADB recovery to unlock the task device). If no authorized in-scope path is available, or attempted recovery leaves the outcome blocked, report why, what you tried (where possible), and the exact missing input, access, or approval. Keep scope bounded; the coordinator retains ECI lifecycle and final acceptance.
- Coordinator/lead alone load lifecycle, blocker, pause, stop, required-critic, teardown, and pressure-policy modules. Workers never infer those duties.
- Each normal iteration is Explore → Critique → Implement → parallel Review. A producer never acts as critic.
- Main-path bugs with hard uncertainty or a material competing diagnosis/approach use `debugging-discipline`; the Fast owner follows its assigned module.

## Configuration E2E contract

Every configuration change, including configuration-only work, requires the final implementer-owned and fresh independent E2E pair on the stabilized final cumulative state described below. This requirement may not be waived.

## Runtime E2E policy

Code/debug work affecting runtime behavior reachable through a UI, API, device, or CLI requires the final E2E pair below. Docs, prompts, design-only changes, tests-only changes, and pure refactors do not require E2E under this policy.

## E2E cadence, scope, and timing

Each implementation iteration still gets focused tests/proof, independent verification of its exact diff, a coordinator checkpoint, and independent code review. Do not run routine E2E between iterations. An early E2E is allowed only to investigate a concrete failure or integration uncertainty; run the shortest faithful real-path scenario that can resolve it. Early evidence does not replace final E2E.

For active ECI, this router controls E2E applicability and cadence within ECI iterations. `testing-discipline` still governs focused-check and required-E2E quality, but its generic per-modification E2E default does not add routine E2E between ECI iterations. This ECI-local cadence does not replace separately applicable outer-workflow acceptance evidence, such as ATE root gates.

Once main implementation, post-Fast findings/dispositions, and any resulting implementation repairs are complete, run one final pair before acceptance whenever a configuration or runtime trigger applies: the implementer-owned E2E and a fresh independent Step 4 E2E on the same stabilized final cumulative revision. The independent run may repeat or extend the implementer run. A later material edit affecting exercised behavior, assertions, or configuration invalidates the affected E2E evidence; refresh it before acceptance.

Use the shortest faithful real path that proves the original criteria and checks relevant regressions. Run the full suite only when it supplies coverage required for that proof. Cite the command and actual output/state/screenshot; proxy evidence alone is insufficient.

Every early, Fast, implementer-final, and independent-final E2E report records `started_at_utc` and `finished_at_utc` (RFC 3339 UTC), `elapsed_monotonic_seconds`, command, scope/coverage, tested revision, and environment identity sufficient for comparison (runner/host class, OS/architecture, relevant tool/runtime versions, and test-service/data configuration). Redact secrets. Compare duration only for matching commands and scope/coverage in materially equivalent environments; do not rerun solely to collect timing. A comparable material regression beyond ordinary variance triggers a Fast owner or bounded helper to profile and optimize E2E duration in parallel while main ECI continues. Preserve assertions, coverage, real-path evidence, and the independent final E2E.

## Module routing

Coordinator routes begin with [coordinator runtime](../references/workflow-runtime/coordinator-runtime.md). Use [coding-style admission](../references/workflow-runtime/coding-style-admission.md) only for governed writing/admission, [review policy](../references/workflow-runtime/review-policy.md) only for review/impact routing, [pause-all-work](../references/workflow-runtime/pause-all-work.md) only for its exact direct-user predicate, [stop recovery](../references/workflow-runtime/stop-recovery.md) only for recognized Stop diagnostics, and [policy pressure tests](../references/workflow-runtime/policy-pressure-tests.md) only for workflow-policy changes.

## Model selection

At each new spawn, read `~/.codex/model-selection.yaml` and pass both `model` and `reasoning_effort` explicitly. Existing agents keep their launch settings. Treat the file as a routing reference; it does not configure automatic loading or provide effective-model telemetry. An unavailable selector is nonblocking: continue with an available selector and report the limitation. Profile selection does not change role authority or reviewer independence.

Choose by assigned activity; mixed assignments use the highest applicable profile.

| Profile | Activities |
| --- | --- |
| `max` | Solution design; unresolved RCA; design review, including Step 2; long-term health review, including Critic C. |
| `higher` | Other independent reviews, including Critics A/B and independent Step 4 E2E. |
| `default` | Implementation; routine work; producer E2E. |

| Role | Required module | Conditional module/predicate |
| --- | --- | --- |
| coordinator | [coordinator](references/coordinator.md), [coordinator runtime](../references/workflow-runtime/coordinator-runtime.md), [review policy](../references/workflow-runtime/review-policy.md) | [pause-all-work](../references/workflow-runtime/pause-all-work.md), [stop recovery](../references/workflow-runtime/stop-recovery.md), and [policy pressure tests](../references/workflow-runtime/policy-pressure-tests.md) only by their predicates |
| `explorer` | [explore](references/explore.md) | [debugging-discipline](../debugging-discipline/SKILL.md) only for assigned bug investigation; [coding-style admission](../references/workflow-runtime/coding-style-admission.md) only for assigned governed source discovery |
| `critic-step2` | [critique](references/critique.md) | [coding-style admission](../references/workflow-runtime/coding-style-admission.md) only for independent admission |
| `implementer` | [implement](references/implement.md) | [debugging-discipline](../debugging-discipline/SKILL.md) only for assigned code/debug work; [coding-style admission](../references/workflow-runtime/coding-style-admission.md) only for a governed scope |
| `fast-owner` | [ECI fast path](references/fast-path.md) | Early E2E only under [E2E cadence, scope, and timing](#e2e-cadence-scope-and-timing) |
| Critic A/B/C, E2E | [review](references/review.md) | [coding-style admission](../references/workflow-runtime/coding-style-admission.md) only for reviewed governed scope; E2E follows [E2E cadence, scope, and timing](#e2e-cadence-scope-and-timing). |

## Step handoffs

1. Explorer ranks tagged, evidence-backed options and required PoC/style-source proposal.
2. Fresh special Step 2 critic independently baselines, admits scope, rejects bad options, and selects concrete winner text or returns bounded re-exploration.
3. Reusable implementer applies only the winner and `treatment: now` corrections with causal/proof evidence.
After the Step 3 handoff and before Step 4 or another implementation iteration, the coordinator applies the `CODEX.md` per-implementer checkpoint commit rule. Step 4 receives the named checkpoint, its parent-to-checkpoint diff, and explicit exclusions; a `pre-existing baseline` remains context outside the iteration range.
4. Fresh A/B/C critics review in parallel on every iteration; E2E follows [E2E cadence, scope, and timing](#e2e-cadence-scope-and-timing). Substantive findings return as one design batch; contained fixes return once to implementation. Clean pass needs every original criterion, required proof, and no remaining `now` issue.

## Relationship to other skills

| Skill | Relationship |
| --- | --- |
| `brainstorming` | Explores user intent before design; ECI explores solutions after intent is clear. |
| `agent-teams-execution` | Starts only on explicit user request; once active, may route bounded work through ECI. Re-spawn an ECI critic that cites no issues beyond producer self-reports. |
| `blocker-resolution-protocol` | Supplies shared blocker records and escalation rules. ECI retains role separation, loop-breaker, and hard-escalation semantics. |
| `debugging-discipline` | Diagnoses known bugs; ECI explores open-ended improvement/design. |

Maintenance provenance: [coverage map](references/coverage-map.md).

## Red flags

- A worker loads coordinator/blocker/pause/stop/teardown/review-runtime/pressure policy without explicit assignment.
- A producer reviews itself, a blind critic reuses context, or review critics run sequentially.
- A substantive gate finding is patched directly instead of returning through Explore/Critique.
- A marker is removed to bypass routing or acceptance.
