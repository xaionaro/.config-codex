---
name: explore-critique-implement
description: Use when CODEX selects ECI as the outer workflow or active ATE routes bounded work through ECI
---

# Explore-Critique-Implement

Separate exploration, authoritative critique, implementation, and independent review. The builder never critiques its own output.

## Activation and invariants

Start only when CODEX selects ECI or active ATE explicitly routes bounded work through it. Loading this router alone does not start ECI. Use ECI for non-mechanical work with uncertainty, future behavior/routing/protocol risk, or two plausible approaches; classify by decision complexity and risk, not diff size. A one-line/local change is still non-trivial when it changes instructions, prompts, routing, protocols, public contracts, security, persistence, concurrency, architecture, or reviewer/agent behavior. Skip only a mechanical answer whose consequences are obvious, directly verifiable, and carry no future behavior or routing risk.

- Maintain requirement lineage and a project-understanding ledger. The active outer owns lifecycle; nested ECI remains inside ATE.
- Authoritative lane tracking records exactly one `Stage: normal` or `Stage: emergency` on every ECI lane, assignment, and current ledger state. `Stage: emergency` requires the [Emergency Unblock](references/emergency-unblock.md) protocol, the `provisional Emergency Unblock — unchecked` record, and a recorded `emergency→normal ECI Step 1` transition before work resumes.
- Every ordinary worker reads this router plus only the exact module(s) in its assignment. Unknown role, predicate, or link returns to coordinator before work.
- Coordinator/lead alone load lifecycle, blocker, pause, stop, required-critic, teardown, and pressure-policy modules. Workers never infer those duties.
- Each normal iteration is Explore → Critique → Implement → parallel Review. A producer never acts as critic.
- A hard/uncertain bug uses debugging-discipline. The only unchecked exception is the one-shot conditional Emergency Unblock route.

## Module routing

Coordinator routes begin with [coordinator runtime](../references/workflow-runtime/coordinator-runtime.md). Use [coding-style admission](../references/workflow-runtime/coding-style-admission.md) only for governed writing/admission, [review policy](../references/workflow-runtime/review-policy.md) only for review/impact routing, [pause-all-work](../references/workflow-runtime/pause-all-work.md) only for its exact direct-user predicate, [stop recovery](../references/workflow-runtime/stop-recovery.md) only for recognized Stop diagnostics, and [policy pressure tests](../references/workflow-runtime/policy-pressure-tests.md) only for workflow-policy changes.

| Role | Required module | Conditional module/predicate |
| --- | --- | --- |
| coordinator | [coordinator](references/coordinator.md), [coordinator runtime](../references/workflow-runtime/coordinator-runtime.md), [review policy](../references/workflow-runtime/review-policy.md) | [pause-all-work](../references/workflow-runtime/pause-all-work.md), [stop recovery](../references/workflow-runtime/stop-recovery.md), and [policy pressure tests](../references/workflow-runtime/policy-pressure-tests.md) only by their predicates; [Emergency Unblock](references/emergency-unblock.md) to assess a potential case |
| `explorer` | [explore](references/explore.md) | [coding-style admission](../references/workflow-runtime/coding-style-admission.md) only for assigned governed source discovery |
| `critic-step2` | [critique](references/critique.md) | [coding-style admission](../references/workflow-runtime/coding-style-admission.md) only for independent admission |
| `implementer` | [implement](references/implement.md) | [coding-style admission](../references/workflow-runtime/coding-style-admission.md) only for a governed scope |
| Critic A/B/C, E2E | [review](references/review.md) | [coding-style admission](../references/workflow-runtime/coding-style-admission.md) only for reviewed governed scope; E2E only for code/debug work |
| emergency implementer | [Emergency Unblock](references/emergency-unblock.md) | only after coordinator qualification; immediately rejoin normal Step 1 |

Potential Emergency Unblock cases load [Emergency Unblock](references/emergency-unblock.md) to determine qualification. That reference is the single normative qualification source.

## Step handoffs

1. Explorer ranks tagged, evidence-backed options and required PoC/style-source proposal.
2. Fresh special Step 2 critic independently baselines, admits scope, rejects bad options, and selects concrete winner text or returns bounded re-exploration.
3. Reusable implementer applies only the winner and `treatment: now` corrections with causal/proof evidence.
4. Fresh A/B/C critics review in parallel; E2E joins when code applies. Substantive findings return as one design batch; contained fixes return once to implementation. Clean pass needs every original criterion, required proof, and no remaining `now` issue.

## Relationship to other skills

| Skill | Relationship |
| --- | --- |
| `brainstorming` | Explores user intent before design; ECI explores solutions after intent is clear. |
| `agent-teams-execution` | Remains outer for large or multi-workstream work and may route bounded work through ECI. Re-spawn an ECI critic that cites no issues beyond producer self-reports. |
| `blocker-resolution-protocol` | Supplies shared blocker records and escalation rules. ECI retains role separation, loop-breaker, and hard-escalation semantics. |
| `debugging-discipline` | Diagnoses known bugs; ECI explores open-ended improvement/design. |

Maintenance provenance: [coverage map](references/coverage-map.md).

## Red flags

- A worker loads coordinator/blocker/pause/stop/teardown/review-runtime/pressure policy without explicit assignment.
- Emergency Unblock is used for diagnosis, non-reversible change, a second unchecked attempt, or is called accepted/fixed.
- A producer reviews itself, a blind critic reuses context, or review critics run sequentially.
- A substantive gate finding is patched directly instead of returning through Explore/Critique.
- A marker is removed to bypass routing or acceptance.
