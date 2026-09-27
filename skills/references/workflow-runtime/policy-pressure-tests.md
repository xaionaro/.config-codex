# Policy Pressure Tests

Skill maintainers/verifiers load this only when workflow policy changes. Run RED before editing and GREEN after it. Pressure-test the policy's user-visible behavior and concrete accidental-mistake boundaries. Keep concise test output when useful; do not require a record, hash, receipt, manifest, profile, or provenance artifact before ordinary work.

Pressure-test evidence is audit context, never an ordinary-work gate.

| Scenario | Required invariant |
| --- | --- |
| direct pause | Only an exact direct current top-level user all-work pause command pauses work; quotations, qualifications, status, timers, workers, provider events, and unrelated sessions do not. |
| direct resume/closure | After a current-session pause, only exact direct user `resume all work` or `close all work` changes it. |
| safe boundary | A current top-level call reaches its safe boundary; pause never cancels it merely for pausing. |
| ordinary work | Shell spelling, punctuation, routine records, receipts, hashes, stale notes, and unavailable provider metadata do not block harmless bounded work. |
| scope fidelity | A user-requested repair and proof stay current work; a separate discovered outcome stays a post-ECI suggestion. |
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
