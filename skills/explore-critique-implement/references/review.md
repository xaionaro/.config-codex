# ECI Step 4 — Review

This module is for one independent reviewer. The checkpointed `current diff` is the named parent-to-checkpoint range. Respect explicit exclusions and exclude later ambient worktree changes. This is review scope, not admission proof. Work only from the assigned original requirements, intended scope, and supplied evidence. Do not read sibling reports before submitting your own. Report findings only: do not edit, dispatch work, decide a gate, or perform lifecycle actions.

Also review any cumulative retained-fast target supplied under the [adoption boundary](fast-path.md#adoption-review-and-closure). Report uncovered retained hunks or material late changes to the coordinator, including discoveries relevant to [design reopening](fast-path.md#evidence-can-reopen-design).

Tag every factual claim. An untagged claim or unpromoted T5 is not review evidence. For every finding, state one disposition (`REJECT`, `CONDITIONAL`, `NIT`, or `PASS`), its impact, exact location, concrete evidence or repro/test output, and the condition that would resolve uncertainty. A behavior/interface mismatch is a hard finding, never a style deviation.

## Critic A — coding style

Check applicable style skills, formatter/linter/config anchors, actual scope, admitted records, deviations, and post-write tool evidence. Report material style or quality findings; identify purely cosmetic preference as `NIT`.

## Critic B — correctness and fidelity

Check correctness, safety, concrete requirements, interfaces, non-style boundaries, and root-cause/regression rationale. Check scope fidelity and least restriction against `exact user source → faithful requested outcome → bounded scope`. Distinguish a repair needed to meet or prove that outcome from an invented separate outcome; report the latter as `REJECT` without treating stale lineage as a work gate. Verify that named functions, types, and interfaces actually provide their claimed behavior.

## Critic C — long-term health

Check maintainability harm from debt, coupling, hidden dependencies, code smells, layer/module fit, naming, abstraction, architecture, and self-explaining intention. If assigned a pre-write intention check, return `reconstructed intention:` followed by 2–4 bullets and stop; a later full-context review remains independent.

## E2E

For required E2E, independently repeat or extend the implementer-owned E2E: build and run the full suite where applicable, exercise the affected actual consumer path, cite output/state/screenshot as appropriate, and check related regressions. Proxy evidence alone is insufficient. Under a real capacity constraint, use the shortest faithful repro while preserving the required real-path evidence.

E2E requirements: [Configuration E2E contract](../SKILL.md#configuration-e2e-contract) and [Runtime E2E policy](../SKILL.md#runtime-e2e-policy).

## Review red flags

- A reviewer shares producer identity or relies on a sibling result.
- A report lacks claim tags, an impact rationale, precise evidence, or an honest uncertainty.
- A reviewer changes the work instead of reporting the finding.
- An intention reconstruction is treated as a full review or permission for a write.
