# ECI Step 3 — Implement

Implementer-only. Treat every message as fresh, reread each intended target, and change one approved iteration/diff at a time.

Receive the Step 2 concrete winner verbatim, only `treatment: now` fixes, admitted style record, full lane/assignment binding, changed-file context, and prior gate findings. Do not implement scope-creep debt, a deadline-qualified defer, or `ignored-contradictory` directives. An affected source for queued future work gets its exact searchable `tech-debt(<tracker-ref>): <debt>; risk: <bounded risk>; revisit: <technical trigger>` comment; otherwise preserve the specific tracker record. Report any style-scope/source/conflict/deviation drift before the next affected write; local/tool-covered drift returns to Step 2 and substantive drift re-enters Steps 1–2.

For code/debug work, load test-driven-development, debugging-discipline, and every matching coding-style skill. Repair the causal mechanism, not timing/visibility/blast radius unless containment was requested. Include a falsifiable root-cause rationale, `regression: yes|no|unknown`, evidence, and why the diff repairs the cause. Every factual submission claim has a T1–T5 tag.

Before submit, perform required unit/proof checks. When E2E is required, build and run the full suite where applicable, exercise the affected actual consumer path, and cite output/state/screenshot as appropriate; proxy evidence alone is insufficient. The implementer owns this E2E. If required E2E is unavailable, report the exact missing resource and shortest faithful evidence attempted; missing E2E/rationale bounces before Step 4.

E2E requirements: [Configuration E2E contract](../SKILL.md#configuration-e2e-contract) and [Runtime E2E policy](../SKILL.md#runtime-e2e-policy).

## Write boundary and submission

Revalidate immutable lane graph and mutable assignment binding before each durable write. The assignment contains canonical refs, state version, derivation reason, complete path/edge evidence, binding, and expanded chain. Discovered work without authorized ancestry is scope-creep debt, not an edit. One change/one diff per assignment; do not broaden a winner through “helpful” cleanup.

The submission includes current files changed, concrete winner/fix text applied, exact admitted style record/deltas, command/proof artifacts, root-cause rationale where applicable, regression explanation, and T1–T5 tag on every factual claim. If a governed scope changes, report it before the next affected write. Continue unaffected work only; local/tool-covered delta returns to Step 2, substantive drift returns to Explore/Step 2. A missing tag, unknown causal link, missing required E2E, missing style admission, or symptom-only fix is bounced before reviewers spawn.

## Test and debugging discipline

For code work, test-driven-development governs production code: write a failing behavior test where applicable, observe the expected RED cause, implement minimal repair, verify GREEN, then refactor only while green. For debugging, debugging-discipline governs repro/hypothesis/RCA; do not claim root cause merely because a patch reduces frequency. If test/E2E infrastructure is unavailable, report the exact missing resource and the shortest faithful evidence attempted; do not silently substitute proxy evidence for a required real path.

Never commit, declare accepted/complete, publish a manifest, or tear down ECI from this role. Hand off tested provisional work for independent Step 4 review.
