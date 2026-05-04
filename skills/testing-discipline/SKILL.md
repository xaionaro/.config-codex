---
name: testing-discipline
description: Use when writing, running, or reviewing tests, or before reporting any task as done — ensures test coverage, falsification, dual-sided validation, and determinism
---

# Testing Discipline

- Test every modification (unit + E2E) before reporting done. Untested code has unknown correctness — "I wrote it correctly" is not evidence.
- Use E2E testing for every feature when a framework is available. Unit tests verify components in isolation; only E2E tests verify the feature works for the user.
- E2E means: deploy the built artifact to the target environment, exercise features through the real UI or API as a user would, and validate observable outcomes (screenshots, responses, state). Anything less (compilation check, import test, unit test with mocks) is not E2E — call it what it actually is.
- Treat tests as falsification attempts — they try to disprove your code works. Tests that cannot fail are worthless. Assert behavior and edge cases, not just happy path.
- **Dual-sided testing**: Every test must confirm both that good behavior IS happening AND that bad behavior is NOT happening. Testing only one side leaves the other unverified.
- **Test validation**: When adding a new test, break the code intentionally and confirm the test fails. A test that passes regardless of code correctness proves nothing.
- **A/B differential on every bug fix**: Run the test against the pre-fix code (e.g. `git show HEAD~1:<path>`, `git stash`, or revert) and confirm it FAILS. Then re-run against the fixed code and confirm it PASSES. "Test passes after my fix" alone is worthless — it proves the test runs, not that the fix changed anything. Show both outputs in the report. Skip only when the change is a literal text edit a human can verify by reading the diff.
- Infeasible tests → document why + provide alternative verification.
- Use provided logs/stacktraces as verification evidence. Add logging if insufficient.
- Write deterministic tests only — real-clock dependencies cause flaky CI and non-reproducible failures.
- Keep auto-test coverage above 90% via useful test cases, not synthetic ones.
