---
name: agent-teams-execution
description: Use when CODEX selects ATE as the outer workflow
---

# Agent Teams Execution

ATE is the outer workflow for coordinated multi-workstream work: research, design, disjoint execution, integrated review, proof, and QA. Coordinator and lead route/enforce; they never implement.

## Activation and invariants

Start only when CODEX selects ATE. Loading this router alone does not start the team. Maintain active lineage and a project-understanding ledger; every durable route has an admitted lane, assignment, ownership, and full requirement chain.

- Every worker reads this router plus only its exact role module and named conditional modules. Unknown role, predicate, or link returns to coordinator before work.
- Coordinator/lead alone load lifecycle, prompt/model admission, blocker, pause, stop, required-critic, shutdown, and pressure-policy modules.
- Use provider-native agents, stable reusable producer roles, fresh blind reviewers, disjoint write ownership, and one event-driven wait per expected completion.
- Every root follows research → design → execution → root proof → aggregate review → post-review proof → QA. Do not collapse phases because a request looks small.
- ATE may nest ECI for bounded uncertain work; ATE remains outer and owns status/lifecycle.

## Module routing

Coordinator/lead routes begin with [coordinator runtime](../references/workflow-runtime/coordinator-runtime.md). Use [coding-style admission](../references/workflow-runtime/coding-style-admission.md) only for governed writing/admission, [review policy](../references/workflow-runtime/review-policy.md) only for review/impact routing, [pause-all-work](../references/workflow-runtime/pause-all-work.md) only for its exact direct-user predicate, [stop recovery](../references/workflow-runtime/stop-recovery.md) only for recognized Stop diagnostics, and [policy pressure tests](../references/workflow-runtime/policy-pressure-tests.md) only for workflow-policy changes.

| Role | Required module | Conditional module/predicate |
| --- | --- | --- |
| Coordinator, Lead | [orchestration](references/orchestration.md), [coordinator runtime](../references/workflow-runtime/coordinator-runtime.md), [review policy](../references/workflow-runtime/review-policy.md) | [pause-all-work](../references/workflow-runtime/pause-all-work.md), [stop recovery](../references/workflow-runtime/stop-recovery.md), and [policy pressure tests](../references/workflow-runtime/policy-pressure-tests.md) only by predicates; [blocker-resolution-protocol](../blocker-resolution-protocol/SKILL.md) only after normal handling fails |
| Snitch | [snitch](references/snitch.md) | — |
| Explorer/researcher | [research](references/research.md) | [coding-style admission](../references/workflow-runtime/coding-style-admission.md) only for assigned source discovery |
| Designer, Design Reviewer, FDR | [design](references/design.md) | [coding-style admission](../references/workflow-runtime/coding-style-admission.md) only for design/admission scope |
| `Executor` | [execution](references/execution.md) | [coding-style admission](../references/workflow-runtime/coding-style-admission.md) only for a governed scope |
| Execution Reviewer A/B/C | [review](references/review.md) | [coding-style admission](../references/workflow-runtime/coding-style-admission.md) only for reviewed governed scope; E2E only for code |
| Test Designer/Executor/Reviewer, Verifier, QA | [testing and QA](references/testing-and-qa.md) | [coding-style admission](../references/workflow-runtime/coding-style-admission.md) only for governed test/non-code scope |

## Phase handoffs

1. Research returns tagged facts and style-source discovery, not design.
2. Fresh special design and independent design/FDR review establish architecture, ownership, contracts, PoCs, and admission.
3. Executors own independent slices, use debugging discipline for observed failures, and submit proof rather than completion claims.
4. Fresh A/B/C reviewers inspect each governed code target in parallel; root aggregate review follows root proof.
5. Testing/QA obtain direct evidence for every criterion, then report a verdict to the user and wait for explicit closure.

## Followups and boundaries

Question/clarification → research then answer. Trivial config → producer discovery, verifier admission, execution, targeted proof, aggregate review, QA. Bug → debugging/execution, proof, aggregate review, QA. Behavior change/new feature → full pipeline. `blocker-resolution-protocol` starts only after normal routing fails or a documented cap; concrete failure diagnosis uses systematic-debugging and debugging-discipline first.

## Pre-split coverage map

Baseline source SHA-256: `9d9d990b4c65c2175bd10d87949512293fc64704aeb4672a868702aa0bcd6623`.

| Source family | Invariant | Destination | Verification |
| --- | --- | --- | --- |
| `ATE :1-109,177-245,290-397,427-526,542-704,830-1008` | outer lifecycle/roles/lineage | ATE router + orchestration + coordinator-runtime | routing-test |
| `ATE :110-176` | exact pause transaction | pause-all-work | routing-test |
| `ATE :246-289,705-797` | acceptance/review runtime | coordinator-runtime + review-policy + ATE review | routing-test |
| `ATE :398-426` | independent style admission | coding-style-admission | routing-test |
| `ATE :512-526,726-759` | architecture/PoC/design review | ATE design | routing-test |
| `ATE research` | fact discovery | ATE research | routing-test |
| `ATE execution+debug` | owned implementation/RCA | ATE execution + debugging-discipline | routing-test |
| `ATE :798-829` | test design/QA | ATE testing-and-qa | routing-test |
| `ATE :1009-1051` | policy scenarios | policy-pressure-tests | routing-test |
| `ATE :1052-1122` | red flags/cross-skill limits | owners + ATE router | routing-test |

## Red flags

- A worker loads coordinator/blocker/pause/stop/teardown/review-runtime/pressure policy without its assignment.
- Coordinator/lead implements, researches, or declares success from an agent claim.
- Reviewers edit their target, lack fresh independent identity, or skip the A/B/C/E2E gate.
- Root aggregate review starts before root proof, QA starts before post-review proof, or QA approval is treated as automatic mission closure.
- Unadmitted durable work, unrooted discovered work, or scope-creep debt consumes critical-path capacity.
