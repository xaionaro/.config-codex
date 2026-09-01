# Coding-style Guidance

Load this for a governed write or its independent review. It improves the changed work; it never weakens non-style requirements or becomes permission ceremony.

## Rule

Style is the baseline among otherwise correct choices. Behavior, names/interfaces, root-cause analysis, TDD/tests/proof, and approved architecture, ownership, purpose, or interface contracts remain hard when they serve the requested outcome.

Style sources guide the change; a brief or tool output is review context, not a write permit. Before writing, identify readily available repository conventions, formatter/linter settings, matching style skills, and relevant exclusions. Apply them where they fit. Missing, stale, or disputed style context prompts a concise clarification or review note; it does not pause a bounded in-scope change.

Use a concise note only when it helps explain a real deviation or an unresolved style conflict. State the source, choice, technical reason, and tradeoff. Do not inventory rules, create empty records, or require a note before work. Convenience, deadline, authority, fatigue, sunk cost, precedent, or completed work do not justify a material deviation.

An independent reviewer checks the actual diff, applicable tools, and any meaningful deviation. Formatter/linter output covers only its mechanical domain. Cosmetic preference is NIT. A behavior, interface, test, ownership, architecture, or purpose failure is not downgraded to style.

## Consequence boundary

Treat names, package purpose, and interfaces as quality contracts: fulfill what they promise and avoid smuggled effects. A bug fix repairs its causal mechanism, not merely timing, visibility, or blast radius unless containment was requested. Prefer consistent names, parallel structure, domain types, approved placement, and simple maintainable code among correct choices.
