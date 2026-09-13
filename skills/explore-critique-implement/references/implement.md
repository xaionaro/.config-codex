# ECI Step 3 — Implement

Implementer-only. Treat every message as fresh, reread each intended target, and change one approved iteration/diff at a time within your assigned task. Other task owners may advance independently.

Follow the [shared-tree priority](fast-path.md#shared-tree-and-eci-priority) and [adoption boundary](fast-path.md#adoption-review-and-closure) when integrating retained Fast owner work. Material fast evidence uses [design reopening](fast-path.md#evidence-can-reopen-design).

Apply [main ECI quality responsibility](fast-path.md#main-eci-quality-responsibility): bring retained Fast code to the selected winner's quality standard; retain qualifying code and revise or replace deficient parts within that winner.

Receive the Step 2 concrete winner, only `treatment: now` fixes, changed-file context, and prior findings. Do not implement a separate-outcome concern, deadline-driven cleanup, or `ignored-contradictory` directive. Put a genuine unrelated concern in a concise post-ECI suggestion; do not edit it in this lane. Report a material scope or style conflict before the next affected write; keep unaffected bounded work moving.

A missing record, receipt, hash, marker, or coordination detail does not deny a bounded in-scope write. Reconcile useful context alongside the work. Stop or reroute only a concrete wrong target, destructive effect, or separate requested outcome.

For code/debug work, load test-driven-development, debugging-discipline, and every matching coding-style skill. Repair the causal mechanism, not timing/visibility/blast radius unless containment was requested. Include a falsifiable root-cause rationale, `regression: yes|no|unknown`, evidence, and why the diff repairs the cause. Every factual submission claim has a T1–T5 tag.

Before submit, perform required unit/proof checks. When E2E is required, build and run the full suite where applicable, exercise the affected actual consumer path, and cite output/state/screenshot as appropriate; proxy evidence alone is insufficient. The implementer owns this E2E. If required E2E is unavailable, report the exact missing resource and shortest faithful evidence attempted; do not claim equivalent proof.

E2E requirements: [Configuration E2E contract](../SKILL.md#configuration-e2e-contract) and [Runtime E2E policy](../SKILL.md#runtime-e2e-policy).

## Write boundary and submission

Before each durable write, reread the intended target, requested outcome, approved winner, and changed-file context. Route a concrete wrong target or separate outcome before writing. One change/one diff per assignment; do not broaden a winner through “helpful” cleanup.

The submission names changed files, the applied winner/fix, checks run, root-cause rationale where applicable, regression explanation, and factual evidence. If a governed scope changes, report it before the next affected write. Continue unaffected work only; a local correction returns to Step 2 and substantive drift returns to Explore/Step 2. An unsupported load-bearing claim, missing required E2E, unknown causal link, or symptom-only fix needs correction before acceptance; labels and coordination notes alone never decide it.

## Test and debugging discipline

For code work, test-driven-development governs production code: write a failing behavior test where applicable, observe the expected RED cause, implement minimal repair, verify GREEN, then refactor only while green. For debugging, debugging-discipline governs repro/hypothesis/RCA; do not claim root cause merely because a patch reduces frequency. If test/E2E infrastructure is unavailable, report the exact missing resource and the shortest faithful evidence attempted; do not silently substitute proxy evidence for a required real path.

Never commit, declare accepted/complete, publish a manifest, or tear down ECI from this role. Hand off tested provisional work for independent Step 4 review.
