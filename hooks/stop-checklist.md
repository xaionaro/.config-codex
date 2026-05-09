# Stop Checklist

Before stopping, verify every applicable item. If any check fails, keep working or state the concrete blocker.

## Git

- Commit this session's completed changes before stopping.
- Do not commit unrelated user changes.
- If committing is unsafe because unrelated work is mixed in, state the blocker, affected paths, and exact next command.
- Do not paste routine git output into the final answer; summarize only the commit outcome or blocker.
- Never push unless the user explicitly asked.

## Completion

- User request fully addressed.
- DONE requires objective evidence, not inference.
- Relevant changed files/state reviewed with targeted evidence.
- No secrets or credentials exposed in code, commits, logs, prompts, or final output.
- Known remaining work is either completed or stated as a blocker with next action.
- Claims in the final answer are supported by tool output, source, or explicit caveat.

## Project Understanding Ledger

- If ECI or ATE was used, update the session project-understanding ledger per the `maintaining-context-ledger` skill before stopping.
- If no ledger update is needed, state why.

## Root Cause

- Bug/debugging fixes identify the root cause, not only the symptom.
- External blame has isolated reproduction or source evidence.
- Similar patterns were searched when the fix may generalize.

## Adversarial Self-Critique

- Nontrivial work has a claim inventory, pre-mortem, and concrete objections considered.
- Each found problem is fixed or refuted with evidence.
- Uncertain claims are labeled as uncertain.

## Assumed Blockers

- Missing tools, services, files, or test paths were actually tried before claiming blocked.
- "Can't test this" includes attempted alternatives and the observed failure.

## Rule-Compliance Self-Audit

<!-- Keep in sync with stop-verification.md "Rule-Compliance Self-Audit". -->

The audit subject is the written rule: `CODEX.md`, skill rules, project instructions, and user instructions. Audit the last turn only: conduct between the previous stop or session start and this stop attempt.

Use exactly one form.

- Form A: `clean-scan: CODEX.md, <skill>, <project instruction>` naming at least three non-empty scanned sources, including `CODEX.md`.
- Form B: one or more `Violation:` blocks. Every block needs a correction marker: `commit: <reachable commit>`, an `` ```edit `` fence, a `` ```grep `` fence, a `` ```restate `` fence, or `blocker:` with non-empty `input:` and concrete `command:` fields.

Placeholder blocker commands such as `TBD`, `TODO`, or `later` are rejected. Fake or unreachable commit hashes are rejected.

If repeating a byte-identical audit on an unchanged repo, add `rescanned: CODEX.md, <source2>, <source3> - <UTC time>`.

Dirty trees, HEAD movement, missing/invalid `rescanned:`, and old-only commit evidence are rejected when they make the audit stale.

## Background Processes

- No unneeded session-spawned background processes are left running.
- Intended long-lived services are documented with one-line rationale.

## Testing

- Static checks/tests run when available and relevant.
- Skipped checks are justified with the missing prerequisite or risk.
- UI or user-visible behavior is verified with direct evidence when touched.
- Unrun checks and residual risks are stated plainly.
