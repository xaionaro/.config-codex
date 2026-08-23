# Coding-style Admission

Load this only for a governed write or the independent admission/review of one. It owns style admission; it never weakens non-style requirements.

## Rule

Style is a presumptive baseline among otherwise correct alternatives. Behavior, names/interfaces, security, root-cause analysis, TDD/tests/proof, and approved architecture, ownership, purpose, or interface contracts are non-style requirements and stay hard.

Before the first durable write in a governed scope:

1. Resolve exact governing clauses, repository anchors, formatter/linter configuration, referenced standards, matching installed style skills, and relevant exclusions.
2. Load every matching installed coding-style skill. A no-match does not erase repository/config/reference sources, and invocation alone is not compliance.
3. Record only the needed route. Reuse it until the scope, source, conflict, or deviation changes.

| Route | Record |
| --- | --- |
| Style Brief | Scope; exact sources; grouped `guidance -> choice`; each deviation’s baseline/purpose/scope/evidence/proportionality/tradeoff; independent reviewer and verdict. |
| Tool route | Pre-write scope/tool/config/covered domain and independent confirmation of no uncovered judgment; post-write actual scope/command/clean result. |
| No-source verdict | Scope; governing ancestry; discovery basis; installed-skill catalog; independent reviewer and verdict. |

Never create empty records or rule-by-rule inventories. Technical evidence may justify a deviation; convenience, deadline, authority, fatigue, sunk cost, precedent, or completed work never does. An admitted deviation is compliant.

Isolated disposable exploration, PoCs, and repros may precede admission, but cannot be merged, copied, adapted, or used as precedent. New scope/source/conflict/deviation pauses only affected work. An independent reviewer approves a local/tool-covered delta; substantive drift re-enters the owning exploration/design route. Final review reconciles actual scope, admission, deltas/deviations, and tool evidence. Cosmetic-only style is NIT; missing/unverified admission or undeclared material deviation blocks.

## Admission evidence and conflict handling

For each scope, quote exact clause, `path#heading`, configuration key/rule, or installed-skill anchor, plus exclusions whenever scope could be confused. Group artifacts only when governance truly matches. Reuse the record while scope/source/conflict/deviation is unchanged; do not create a fresh record per edit. The independent reviewer re-resolves applicability rather than trusting an explorer/producer conclusion.

An intentional deviation records baseline and purpose, exact scope, contemporaneous technical evidence, proportionality, alternative/tradeoff, reviewer, and workflow verdict. Sources may be governing instructions, repository/task constraints, authoritative framework/toolchain documentation/source, or faithful experiment. If a higher-priority instruction mandates the concrete choice it wins; otherwise resolve style conflicts on technical merit.

A tool route discharges only its covered mechanical domain. It never proves uncovered judgment, conflicting source, deviation, behavior, security, interface, test/proof, architecture, ownership, or purpose. A no-source verdict is not a claim that no requirements exist: it preserves the discovery basis and all non-style obligations.

## Consequence boundary

Treat names as contracts: implementation fulfils what the name promises and has no smuggled decision/side effect. Treat approved package/binary purpose as a contract: code belongs only where that purpose supports it. Treat interface implementation as a contract: production stubs that always error do not satisfy an interface claim. A bug fix identifies and repairs its causal mechanism; a change merely reducing frequency, timing, visibility, or blast radius is mitigation unless containment was requested.

Among otherwise correct choices, consistent naming/parallel structure, named domain types instead of bare primitives, approved placement, and clean solutions over shortcuts are style baselines. A reviewer may call cosmetic preference NIT, but cannot use “style” to lower a hard consequence. Final QA/review independently reconciles actual changed scope against original admission, approved deltas/deviations, and post-write tool evidence.
