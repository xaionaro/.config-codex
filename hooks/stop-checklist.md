# Stop Checklist

Before stopping, verify every applicable item. If any check fails, keep working or state the concrete blocker.

## Git

- Commit this session's completed changes before stopping.
- Do not commit unrelated user changes.
- If committing is unsafe because unrelated work is mixed in, state the blocker, affected paths, and exact next command.
- Do not paste routine git output into proof; summarize only the commit outcome or blocker.
- Never push unless the user explicitly asked.

## Completion

- User request fully addressed.
- DONE requires objective evidence, not inference.
- Relevant changed files/state reviewed with targeted evidence.
- Secrets or credentials checked when touched files could contain them.
- Known remaining work is either completed or stated as a blocker with next action.
- Claims in the final answer are supported by tool output, source, or explicit caveat.

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

- Scan `CODEX.md`, applicable skills, and project instructions for current-turn violations.
- Use `clean-scan: CODEX.md, <skill>, <project instruction>` when no violations remain.
- For violations, record the violated rule and the correction applied.

## Background Processes

- No unneeded session-spawned background processes are left running.
- Intended long-lived services are documented with one-line rationale.

## Testing

- Static checks/tests run when available and relevant.
- Skipped checks are justified with the missing prerequisite or risk.
- UI or user-visible behavior is verified with direct evidence when touched.
- Unrun checks and residual risks are stated plainly.
