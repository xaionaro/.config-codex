---
name: explore-critique-implement
description: Use when CODEX selects ECI as the outer workflow or active ATE routes bounded work through ECI
---

# Explore-Critique-Implement

Separate exploration, authoritative critique, implementation, and independent review. The builder never critiques its own output.

## Activation and invariants

Start only when CODEX selects ECI or active ATE explicitly routes bounded work through it. Loading this router alone does not start ECI. Use ECI for non-mechanical work with uncertainty, future behavior/routing/protocol risk, or two plausible approaches; classify by decision complexity and risk, not diff size. A one-line/local change is still non-trivial when it changes instructions, prompts, routing, protocols, public contracts, security, persistence, concurrency, architecture, or reviewer/agent behavior. Skip only a mechanical answer whose consequences are obvious, directly verifiable, and carry no future behavior or routing risk.

- Maintain requirement lineage and a project-understanding ledger. The active outer owns lifecycle; nested ECI remains inside ATE.
- For material ECI work, keep `exact user source → faithful requested outcome →
  bounded scope`. A repair necessary to meet or prove that outcome stays current-lane work.
  A concern serving a separate outcome is only a post-ECI user follow-up, never current work.
  Missing or stale lineage never blocks known in-scope work.
- Keep one `Stage: normal` or `Stage: emergency` in every ECI lane, assignment, and current ledger state. A missing, stale, or unknown stage is reconciled as part of work; it is not a prerequisite for harmless bounded progress. An `emergency` stage uses [Emergency Unblock](references/emergency-unblock.md) as a recovery aid, not as a permission ceremony.
- A lane is an independently advancing workstream, not an ECI step. Serial implement→review→repair→review→implement stays one lane with one critical path. Create distinct lanes only for independently advancing work with separate ownership or synchronization.
- Every ordinary worker reads this router plus the exact module(s) useful to its assignment. An unknown role, predicate, or link is reported to the coordinator and resolved while safe bounded assigned work continues; it does not itself deny or stall normal work.
- Coordinator/lead alone load lifecycle, blocker, pause, stop, required-critic, teardown, and pressure-policy modules. Workers never infer those duties.
- Each normal iteration is Explore → Critique → Implement → parallel Review. A producer never acts as critic.
- A bug with hard uncertainty or a material competing diagnosis/approach uses `debugging-discipline`. The only pre-normal-ECI exception is the one-shot, single-owner Emergency Unblock route.

## Configuration E2E contract

Every configuration change, including configuration-only work, requires E2E. The implementer runs that E2E before Step 4.

Step 4 independently repeats or extends the implementer's E2E. This Configuration E2E requirement may not be waived.

## Runtime E2E policy

Code/debug work affecting runtime behavior reachable through a UI, API, device, or CLI requires E2E. The implementer runs it before Step 4. Step 4 independently repeats or extends it. E2E builds and runs the full suite where applicable, exercises the affected real UI/API/device/CLI path, and cites output, state, or screenshot. Docs, prompts, design-only changes, tests-only changes, and pure refactors do not require E2E under this policy.

## Module routing

Coordinator routes begin with [coordinator runtime](../references/workflow-runtime/coordinator-runtime.md). Use [coding-style admission](../references/workflow-runtime/coding-style-admission.md) only for governed writing/admission, [review policy](../references/workflow-runtime/review-policy.md) only for review/impact routing, [pause-all-work](../references/workflow-runtime/pause-all-work.md) only for its exact direct-user predicate, [stop recovery](../references/workflow-runtime/stop-recovery.md) only for recognized Stop diagnostics, and [policy pressure tests](../references/workflow-runtime/policy-pressure-tests.md) only for workflow-policy changes.

| Role | Required module | Conditional module/predicate |
| --- | --- | --- |
| coordinator | [coordinator](references/coordinator.md), [coordinator runtime](../references/workflow-runtime/coordinator-runtime.md), [review policy](../references/workflow-runtime/review-policy.md) | [pause-all-work](../references/workflow-runtime/pause-all-work.md), [stop recovery](../references/workflow-runtime/stop-recovery.md), and [policy pressure tests](../references/workflow-runtime/policy-pressure-tests.md) only by their predicates |
| `explorer` | [explore](references/explore.md) | [debugging-discipline](../debugging-discipline/SKILL.md) only for assigned bug investigation; [coding-style admission](../references/workflow-runtime/coding-style-admission.md) only for assigned governed source discovery |
| `critic-step2` | [critique](references/critique.md) | [coding-style admission](../references/workflow-runtime/coding-style-admission.md) only for independent admission |
| `implementer` | [implement](references/implement.md) | [debugging-discipline](../debugging-discipline/SKILL.md) only for assigned code/debug work; [coding-style admission](../references/workflow-runtime/coding-style-admission.md) only for a governed scope |
| Critic A/B/C, E2E | [review](references/review.md) | [coding-style admission](../references/workflow-runtime/coding-style-admission.md) only for reviewed governed scope; E2E as required by the [Configuration E2E contract](#configuration-e2e-contract) or [Runtime E2E policy](#runtime-e2e-policy). |
| emergency fixer | [Emergency Unblock](references/emergency-unblock.md) | self-assesses eligibility; alone performs the minimum diagnosis, one repair, and any required E2E; then hands the dirty/untrusted state into fresh normal ECI Step 1 |

Potential Emergency Unblock cases are self-assessed by the emergency fixer under [Emergency Unblock](references/emergency-unblock.md). That reference is the single normative eligibility source.

## Step handoffs

1. Explorer ranks tagged, evidence-backed options and required PoC/style-source proposal.
2. Fresh special Step 2 critic independently baselines, admits scope, rejects bad options, and selects concrete winner text or returns bounded re-exploration.
3. Reusable implementer applies only the winner and `treatment: now` corrections with causal/proof evidence.
After the Step 3 handoff and before Step 4 or another implementation iteration, the coordinator applies the `CODEX.md` per-implementer checkpoint commit rule. Step 4 receives the named checkpoint, its parent-to-checkpoint diff, and explicit exclusions; a `pre-existing baseline` remains context outside the iteration range.
4. Fresh A/B/C critics review in parallel; E2E joins as required by the [Configuration E2E contract](#configuration-e2e-contract) or [Runtime E2E policy](#runtime-e2e-policy). Substantive findings return as one design batch; contained fixes return once to implementation. Clean pass needs every original criterion, required proof, and no remaining `now` issue.

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
- Emergency Unblock omits required E2E, exceeds the minimum diagnosis needed for its one repair, uses a non-reversible or broader change, makes a second repair, or treats the dirty/untrusted state as accepted.
- A producer reviews itself, a blind critic reuses context, or review critics run sequentially.
- A substantive gate finding is patched directly instead of returning through Explore/Critique.
- A marker is removed to bypass routing or acceptance.
