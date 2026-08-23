# Review Policy

Use this for independent review, impact routing, claim discipline, and design-versus-implementation classification. Reviewers report; writers repair.

## Evidence and severity

Tag factual claims `[T<tier>: source, confidence]`; untagged factual claims and unpromoted T5 claims reject the submission. Verify source-backed claims independently; no peer output is trusted by default. A reviewer’s first response to another agent’s input identifies a concern, gap, or question.

| Code | Meaning |
| --- | --- |
| REJECT / REJECTED | Wrong, unsafe, contradictory, or needs redesign; fix now. |
| CONDITIONAL | Viable but needs concrete bounded text/fix; route by impact. |
| NIT | Preference only; may be ignored. |

Review every applicable root-cause rationale and regression explanation. Unknown cause or symptom-only mitigation is REJECT unless containment was explicitly requested. Governance/prompt/hook/protocol/reviewer changes also audit mechanism/predicate, emitted wording, strongest supported wording, and a boundary counterexample; reject claims beyond evidence.

## Impact-proportional routing

Screen scope before severity. A remedy necessary for the original objective, acceptance criteria, security, correctness, specification, contract/interface, persistence, concurrency, admission, TDD, proof, regression, verification, or required test is `now`. A wholly separable new outcome is scope-creep debt; queue it with the shared record and never use it to waive original work. Split mixed remedies.

Only an in-scope, non-hard, impact-trivial, isolated finding may defer. Its one append-only record starts before research/discussion and is sealed by `started + 2 minutes` with `{elapsed, sealed-at, treatment, evidence/result}`. Missing/late/new/shared evidence makes it `now`. Deadline, fatigue, sunk cost, authority, completed work, and calendar date never qualify. Mutually exclusive remedies for the same criterion from different decisions are `ignored-contradictory`: record them without pretending the unmet criterion is resolved.

## Design-versus-implementation boundary

Critics report implementation-level findings as well as design findings; do not discard a detail merely because the approved design can survive it. Classify by blast radius and repair nature. A design-level finding is REJECT-worthy when substantial scale-up would amplify the problem and fixing it requires a new design decision, model, contract, trust boundary, or feasibility assumption; semantic/model/contract errors are normally in this class. A local syntax/style/wiring/mechanical defect with contained blast radius that can be repaired without changing the approved design is an implementation detail. A critic still reports every real finding under its own adversarial rubric and may label it REJECT when its evidence supports that label; do not bias or silence the report. The coordinator alone adjudicates final impact and may downgrade a contained implementation detail to CONDITIONAL or tech-debt, so it is never a design REJECT after that adjudication. The implementation loop still resolves or records every such finding in its acceptance/debt ledger. Do not silently drop a fixable detail, and do not downgrade a design change to polish.

Examples: a changed persistence model, ownership rule, public contract, or security boundary is design-level; a typo, local adapter wiring error, or mechanical call-site correction that preserves those decisions is implementation-level.

## Three-critic review

For governed code, use fresh blind Critic A (style), Critic B (correctness/fidelity), and fresh special Critic C (long-term health) in parallel; add E2E when code applies. All report only. A/B/C independently classify findings and state impact. Critic A checks the admitted style record and never lets style downgrade a hard contract. Critic B guards behavior, security, interfaces, tests/proof, and fidelity. Critic C checks long-term health, architecture, actual scope/admission reconciliation, and final-state clarity. Withhold the gate until all required reports and E2E arrive.

## Review packet and finding contract

Normal reviewer packets contain original user requirements, exact target/diff, `loop-id`, applicable `decision-id`, objective/criteria, general pre-routing record, admitted style record/deltas/tool evidence, full applicable lineage/binding, and all scrutiny rules. Include `started`, deadline, and `sealed-at` only for a potential defer. Every finding attaches to a specific option/target with severity, impact (`trivial` or `substantive`), one-line rationale, evidence location, and concrete fix direction. A missing impact tag is a defect in the review output; re-prompt or respawn it before gate evaluation.

Critic A loads each matching installed style skill and checks actual material adherence. Critic B independently verifies stated purpose and interface fulfillment before quality. Critic C judges final state, not change-history defense, and flags materially harmful coupling, hidden dependencies, wrong layer, unclear names, duplication, missing/premature abstraction, or architectural mismatch. Cosmetic taste is NIT; “would refactor someday” is not a finding without concrete harm.

Code E2E builds, runs full suite, exercises affected UI/API/device/CLI path, cites output/screenshot/state, and checks related regressions. Docs/config/design/tests-only/pure-refactor tasks skip E2E honestly. A missing required E2E/rationale returns to the implementer before gate, not to a false approval.

## Gate evaluation

After all required reports, pre-route findings. At least one substantive `now` REJECT/CONDITIONAL, or design/API-uncertain E2E failure, becomes one design-revision issue batch for re-exploration/critique. A trivial `now` REJECT/CONDITIONAL or trivial E2E failure returns in one implementer repair batch. A clean gate has no remaining `now` issue and all required same-run proof. Scope-creep debt, valid defer, and ignored contradiction are recorded future work, not clean-pass defects.

The design-revision batch groups all remaining issues by affected artifact/API/contract and includes source reviewer, severity, impact, evidence location, exact issue text, relevant debt/defer reference, and acceptance criteria. Never patch substantive gate issues one by one without the design loop. Review caps and loop-breaker/BRP escalation remain owned by the outer workflow.

## Independent-review discipline

Review independently before reading sibling findings. Do not praise or rubber-stamp producer/peer output. For multiple non-execution reviewers partition primary lenses (correctness/edge, security, design/semantic/naming) while still reporting real out-of-lens issues. A minority dissent needs counter-evidence to override. Higher evidence tier wins contradiction. Reviewers never edit their target; dispute one evidence-backed exchange, then coordinator adjudicates.
