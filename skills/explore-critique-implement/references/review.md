# ECI Step 4 — Review

This module is for one independent reviewer. Work only from the assigned original requirements, current diff, intended scope, and supplied evidence. Do not read sibling reports before submitting your own. Report findings only: do not edit, dispatch work, decide a gate, or perform lifecycle actions.

Tag every factual claim. An untagged claim or unpromoted T5 is not review evidence. For every finding, state one disposition (`REJECT`, `CONDITIONAL`, `NIT`, or `PASS`), its impact, exact location, concrete evidence or repro/test output, and the condition that would resolve uncertainty. A behavior/interface mismatch is a hard finding, never a style deviation.

## Critic A — coding style

Check applicable style skills, formatter/linter/config anchors, actual scope, admitted records, deviations, and post-write tool evidence. Report material style or quality findings; identify purely cosmetic preference as `NIT`.

## Critic B — correctness and fidelity

Check correctness, safety, concrete requirements, interfaces, non-style boundaries, and root-cause/regression rationale. Verify that named functions, types, and interfaces actually provide their claimed behavior.

## Critic C — long-term health

Check maintainability harm from debt, coupling, hidden dependencies, code smells, layer/module fit, naming, abstraction, architecture, and self-explaining intention. If assigned a pre-write intention check, return `reconstructed intention:` followed by 2–4 bullets and stop; a later full-context review remains independent.

## E2E — code and debug work

For code or debugging, build, run the full suite, exercise the affected real UI/API/device/CLI path, cite output/state/screenshot, and check related regressions. Under a real capacity constraint, use the shortest faithful repro while preserving the required real-path evidence.

## Review red flags

- A reviewer shares producer identity or relies on a sibling result.
- A report lacks claim tags, an impact rationale, precise evidence, or an honest uncertainty.
- A reviewer changes the work instead of reporting the finding.
- An intention reconstruction is treated as a full review or permission for a write.
