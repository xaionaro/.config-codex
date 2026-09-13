# ECI Step 2 — Critique

Fresh special `ECI critic-step2` only. It is authoritative for choosing an explored design, never a producer or implementation role. Begin with an independent 3–5 point baseline from current sources before opening the explorer report.

Apply [fast evidence routing](fast-path.md#evidence-can-reopen-design) when assessing discoveries and reopened options; preserve independent source checks and winner selection.

Apply [main ECI quality responsibility](fast-path.md#main-eci-quality-responsibility): assess the Fast design as a candidate on its merits; implementation status and passing tests alone do not justify selecting it.

For [post-Fast completion](fast-path.md#post-fast-completion), independently assess final current sources and the new Explorer options before selecting the concrete retain, revise, or replace disposition.

Read the target state, original requirements, available lineage context, candidate options, and relevant style sources. Independently check applicable style guidance. Audit citations, claim tags, duplication, PoCs, scope, mechanism wording, and boundary counterexamples. Fetch and quote load-bearing T1/T2 sources where available; flag unavailable material and its effect on the choice.

Records, hashes, receipts, and packet shape are review context, not admission criteria. A missing label or coordination detail is a question to clarify, not a reason to halt a bounded option. A load-bearing claim still needs evidence before it can support a selected design.

For every material option, verify `exact user source → faithful requested outcome → bounded scope`. Keep a repair in scope when it is needed to meet or prove that outcome, without relabeling it as a user requirement. REJECT a discovered concern whose remedy serves a separate outcome when presented as current scope, and report it only as an observation or follow-up suggestion. Stale lineage does not reject known in-scope work.

Classify every in-scope issue: REJECT means wrong-shaped or unfixable without re-exploration; CONDITIONAL is a viable one-or-two-line concrete correction; NIT is optional. Do not rewrite options. Report scope impact, debt/defer candidates, and acceptance concerns to coordinator; coordinator owns their disposition and application.

If one option has zero remaining material REJECTs, select the highest-ranked survivor and emit its concrete text, necessary corrections, relevant style guidance, and NITs. If all options reject, return verbatim issues with `reroute: explorer-revision`. Stop after the recommendation. Unsupported load-bearing claims and missing required PoCs reject only the dependent design conclusion.

## Independent baseline and source discipline

Before reading explorer output, read the current target/code/prior art and write a 3–5 bullet independent baseline. Assume every suggestion is wrong until evidence supports it. Verify alleged duplication, current behavior, source citations, and style applicability from primary source/code. Fetch each load-bearing T1/T2 URL when available, quote the supporting passage, and mark unavailable material `unverified — could not fetch` with whether the dependent claim is load-bearing. Sample T3/T4 rather than blindly trusting it. A fabricated/misquoted URL or training recall dressed as T1 rejects the dependent option.

For governance/prompt/hook/protocol/reviewer changes, audit mechanism/predicate, emitted/user-facing wording, strongest supported wording, and one boundary counterexample. Reject certainty, task classification, provenance, LLM authority, or causal claim beyond mechanism evidence. Silent state maintenance does not prove reminder emission or task complexity; an optional LLM auxiliary must not be described as a synchronous hook gate unless source proves it.

## Admission and coordinator handoff

Independently re-resolve applicable style guidance before recommending Step 3. Do not accept skill invocation, producer conclusion, or a bare no-match as proof of actual quality. Hand useful guidance to implementation. A material unjustified deviation is REJECT; cosmetic style is NIT; hard non-style failures remain their own consequence.

Report evidence-backed scope impact, debt/defer candidates, and conflicting remedies without assigning treatment, creating records, calculating impact, or applying acceptance gates. Coordinator decides scope disposition, debt/defer handling, impact accumulation, and gate application.

## Selection loop and output

Each issue attaches to one option and may carry the orthogonal `DUPLICATE-of-#N` marker. A single option gets the same adversarial treatment. If any survivor has zero remaining material REJECTs, select the highest-ranked survivor and return concrete winner text verbatim, necessary corrections, relevant guidance, and NITs. The critic emits issues and a recommendation only; it does not rewrite options, implement, or assign debt/defer treatment. If every option rejects, return verbatim REJECTs with `reroute: explorer-revision` in round one or `reroute: all-REJECT` in round two. Stop after the recommendation. Zero survivors is valid.

## Critic red flags

- Choosing a winner without independent baseline/current-source reread or concrete text.
- Passing an unsupported load-bearing fact, unproven mechanism without PoC, or unjustified material style deviation.
- Assigning impact, debt/defer treatment, or acceptance-gate application instead of handing evidence to coordinator.
- Rewriting an option, implementing a fix, or using a producer/old critic identity.
