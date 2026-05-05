# Stop Verification

Before stopping, verify the work against the user's request.

Proof file: `{{PROOF}}`

Run only checks that prove the actual change. Prefer direct evidence: source reads, targeted diffs, tests/static checks, screenshots, observed state, or command output.

## Fast Exit

Write `fast-exit: <reason>` to the proof file only when no completion claim is being made, the answer is still mid-conversation, or the change is trivial enough that a mistake is implausible.

## Full Verification

1. Inspect every file or state change relevant to this turn.
2. Check for secrets or credentials when touched files could contain them.
3. Review the change for correctness, error handling, security, consistency, and completeness.
4. For bug fixes, identify root cause and whether the fix addresses the cause.
5. Search for the same pattern elsewhere when the fix may generalize.
6. Run the narrowest meaningful tests/static checks for changed behavior.
7. Verify user-visible behavior directly when touched.
8. Commit this session's completed changes before writing proof. Do not commit unrelated user changes. If committing is unsafe, state the blocker. Do not paste routine git output into proof.
9. Scan `CODEX.md`, applicable skills, and project instructions for current-turn rule violations.

Required proof sections:

## Summary

- What changed.

## Verification

- Changed files/state reviewed, summarized without routine git output:
- Tests/checks run:
- User-visible evidence:
- Secrets check:

## Requirements

- Original request items verified:

## Root Cause

- Cause:
- Generalization search:

## Claim Inventory

- Claims and source/confidence:

## Pre-Mortem

- Most likely flaw considered:
- Result:

## Adversarial Critique

- Objections found and resolution:

## Rule-Compliance Self-Audit

<!-- Keep in sync with stop-checklist.md "Rule-Compliance Self-Audit". -->
<!-- Grammar below is parsed by stop-gate.sh. -->

The audit subject is the written rule: `CODEX.md`, skill rules, project instructions, and user instructions. Audit the last turn only: conduct between the previous stop or session start and this stop attempt.

Use exactly one form.

Form A:

    clean-scan: CODEX.md, <skill>, <project instruction>

Name at least three non-empty sources you actually scanned. Include `CODEX.md`.

Form B:

    Violation: <short label>
    Rule: <path or section>
    Correction:
      commit: <reachable commit>
      ```edit <path>
      <content>
      ```
      ```grep <path>
      <output>
      ```
      ```restate
      <corrected statement>
      ```
      blocker:
      input: <specific missing input>
      command: <exact command or edit>

Every `Violation:` needs a correction marker. A `blocker:` needs non-empty `input:` and concrete `command:` fields. Placeholder commands such as `TBD`, `TODO`, or `later` are rejected. `commit:` must name a commit reachable from the current repo.

If repeating a byte-identical audit on an unchanged repo, add:

    rescanned: CODEX.md, <source2>, <source3> - <UTC time>

Dirty trees, HEAD movement, missing/invalid `rescanned:`, and old-only commit evidence are rejected when they make the audit stale.

## Gaps

- Unrun checks, uncommitted changes, blockers, and residual risks:
