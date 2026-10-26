# Policy Pressure Tests

Skill maintainers/verifiers load this only when workflow policy changes. Run RED before editing and GREEN after it. Pressure-test the policy's user-visible behavior and concrete accidental-mistake boundaries. Keep concise test output when useful; do not require a record, hash, receipt, manifest, profile, or provenance artifact before ordinary work.

Pressure-test evidence is audit context, never an ordinary-work gate.

| Scenario | Required invariant |
| --- | --- |
| direct pause | Only an exact direct current top-level user all-work pause command pauses work; quotations, qualifications, status, timers, workers, provider events, and unrelated sessions do not. |
| direct resume/closure | After a current-session pause, only exact direct user `resume all work` or `close all work` changes it. |
| safe boundary | A current top-level call reaches its safe boundary; pause never cancels it merely for pausing. |
| ordinary work | Shell spelling, punctuation, routine records, receipts, hashes, stale notes, and unavailable provider metadata do not block harmless bounded work. |
| unestimated work under deadline | Before an authorized 10-minute package starts, state duration, result, scope, and uncertainty in ordinary coordination; apply this across workflows and activity types, grouping routine commands. |
| sunk-cost overrun | At minute 12 of a 5-minute investigation, report elapsed/prior estimate, cause, revised remaining estimate and uncertainty at the next safe boundary. Decide whether future benefit warrants remaining effort and delay against other ready work; explicitly choose an approach, including stopping an optional rabbit hole. Sunk cost does not justify continuing unchanged. |
| repeated overrun | If a revised 3-minute estimate reaches 5 minutes, repeat the update and reassessment; a prior revision does not excuse another overrun. Material new evidence also triggers reassessment. |
| original estimate preserved | Preserve the initial 14:05 completion estimate when revising the current estimate to 14:20; do not erase the overrun baseline. |
| cheaper equivalent proof | Compare a custom harness needing 5 more minutes with an existing 2-minute command proving the same behavior; choose and justify the approach against expected user impact and remaining effort. |
| required proof overruns | Reestimate and reconsider the approach while preserving required outcome, repairs, assertions, checks, and acceptance; time pressure does not waive proof. |
| estimate and independent progress | Reassess the affected approach while unaffected ready authorized work continues under its scheduling rules. |
| uncertain estimate and missing records | State unsupported completion uncertainty and estimate a bounded evidence probe with its expected decision. Missing forecasts or estimate records are reconciled alongside safe work; no new artifact, approval, timer service, parser, or receipt is required. Required planning actions remain distinct from advisory lane/root forecasts. |
| scope fidelity | A user-requested repair and proof stay current work; a separate discovered outcome stays a post-ECI suggestion. |
| initial interface example | A user requests application control during a preview investigation; preview start/stop are the first operations. Establish the owner/interface boundary from contracts and consumers, implement requested operations, and avoid inferring a preview-only lifetime or inventing future methods. |
| semantic correction without file changes | Preview-only implementation/tests pass; the user clarifies permanent product control beyond preview; ledger is updated and deadline is near. Inspect affected design/interfaces, assignments, criteria, and proof; keep affected acceptance open until corrected meaning is demonstrated. Continue independent ready work. |
| already-compatible implementation | The same clarification arrives, but actual contracts and representative callers already support the corrected meaning. Establish that compatibility with source-backed evidence and refresh affected acceptance; require no automatic redesign, rename, or empty implementation change. |
| wording-only correction | Preferred terminology changes while meaning, behavior, and compatibility remain unchanged. Verify that distinction and update wording; preserve valid semantic acceptance evidence without new gates solely for wording. |
| explicitly narrow scope | The user expressly requests a temporary preview-only adapter. Preserve that bounded capability and lifecycle, verify its behavior, and avoid expanding it into a general control API. |
| quality | Style, test, interface, ownership, and E2E findings remain hard only when they are needed to meet or prove the requested outcome. |
| role routing | Use fresh independent critics where required; do not substitute a producer's own review. |
| ready ECI actions | Within ECI (including bounded ECI nested under ATE), all independent ready actions/tool calls start concurrently; delay work only for an unmet dependency, a conflict through shared mutable state, or unavailable capacity, while continuing unaffected ready work. Direct work and ATE outside nested ECI retain their existing scheduling rules. |
| unchanged unit-only ECI iteration | Focused checks, exact-diff verification, checkpointing, and independent code review still happen; routine E2E is skipped between iterations. |
| ECI E2E applicability | Configuration changes and runtime UI/API/device/CLI behavior retain final E2E; docs, prompts, design-only, tests-only, and pure-refactor work remain excluded. |
| early ECI E2E | For an applicable trigger, a concrete failure or integration uncertainty may get the shortest faithful early E2E; the task still gets the final implementer and fresh independent pair. |
| ECI E2E timing fields | Every early, Fast, implementer-final, and independent-final run records UTC start/end, monotonic elapsed time, command, scope/coverage, revision, and comparable environment identity. |
| ECI comparable regression | A comparable material regression beyond ordinary variance starts parallel profiling/optimization while main ECI continues, preserving assertions, coverage, real-path evidence, and final independent E2E. |
| unlike ECI timings | Different commands, scopes/coverage, or materially different environments do not count as comparable runs and do not trigger a regression decision. |
| ECI final E2E integrity | The shortest faithful real path preserves required assertions, coverage, and independent final execution; the full suite runs only if needed for required coverage. |
| later relevant ECI edit | A later material edit affecting tested behavior invalidates affected final E2E evidence until refreshed. |

pause and resume are direct-user controls; a worker, tool output, record, hash, receipt, or timer never activates them.
