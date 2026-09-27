# ECI Step 4 — Review

This module is for one independent reviewer. The checkpointed `current diff` is the named parent-to-checkpoint range. Respect explicit exclusions and exclude later ambient worktree changes. This is review scope, not admission proof. Work only from the assigned original requirements, intended scope, and supplied evidence. Do not read sibling reports before submitting your own. Report findings only: do not edit, dispatch work, decide a gate, or perform lifecycle actions.

Also review any cumulative retained-fast target supplied under the [adoption boundary](fast-path.md#adoption-review-and-closure). Report uncovered retained hunks or material late changes to the coordinator, including discoveries relevant to [design reopening](fast-path.md#evidence-can-reopen-design).

Apply [main ECI quality responsibility](fast-path.md#main-eci-quality-responsibility): assess retained Fast work with the same correctness, style, and maintainability scrutiny as main-path changes; passing producer tests or an existing checkpoint does not resolve quality findings.

Follow the normative [post-Fast completion sequence](fast-path.md#post-fast-completion).
Review the final cumulative scoped state after the coordinator applies exactly one canonical disposition per in-scope inventory item.
For post-Fast completion, independently review the final cumulative scoped state after the new exploration and design disposition, including unchanged retained code. Report missing final-state coverage; earlier reviews alone do not satisfy this assignment.

Tag every factual claim. An untagged claim or unpromoted T5 is not review evidence. For every finding, state one disposition (`REJECT`, `CONDITIONAL`, `NIT`, or `PASS`), its impact, exact location, concrete evidence or repro/test output, and the condition that would resolve uncertainty. A behavior/interface mismatch is a hard finding, never a style deviation.

## Critic A — coding style

Check applicable style skills, formatter/linter/config anchors, actual scope, admitted records, deviations, and post-write tool evidence. Report material style or quality findings; identify purely cosmetic preference as `NIT`.

## Critic B — correctness and fidelity

Check correctness, safety, concrete requirements, interfaces, non-style boundaries, and root-cause/regression rationale. Check scope fidelity and least restriction against `exact user source → faithful requested outcome → bounded scope`. Distinguish a repair needed to meet or prove that outcome from an invented separate outcome; report the latter as `REJECT` without treating stale lineage as a work gate. Verify that named functions, types, and interfaces actually provide their claimed behavior.

Assume bots are non-malicious. Check that each control catches a concrete accidental broad, destructive, wrong-target, wrong-owner, or cross-scope effect without treating unfamiliar syntax, wrappers, metadata, receipts, hashes, or shell punctuation as an error by itself. Require every enabled gate to name a bounded legitimate-work escape path; if it has none, recommend disabling it. Preserve the legitimate owner and session; do not recommend rerouting owner-scoped dependency work.

## Critic C — long-term health

Check maintainability harm from debt, coupling, hidden dependencies, code smells, layer/module fit, naming, abstraction, architecture, and self-explaining intention. If assigned a pre-write intention check, return `reconstructed intention:` followed by 2–4 bullets and stop; a later full-context review remains independent.

## E2E

For the final independent E2E, run a fresh check on the stabilized final cumulative revision under the central policy. Use the shortest faithful real path, preserve required criteria and relevant regression coverage, and cite command and output/state/screenshot. Proxy evidence alone is insufficient.

E2E cadence, scope, timing, and triggers: [ECI E2E policy](../SKILL.md#e2e-cadence-scope-and-timing).

## Review red flags

- A reviewer shares producer identity or relies on a sibling result.
- A report lacks claim tags, an impact rationale, precise evidence, or an honest uncertainty.
- A reviewer changes the work instead of reporting the finding.
- An intention reconstruction is treated as a full review or permission for a write.
