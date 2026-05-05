# Spec Document Reviewer Prompt Template

Use this template when dispatching a spec document reviewer subagent.

**Purpose:** Verify the spec is complete, consistent, and ready for implementation planning.

**Dispatch after:** Spec document is written to docs/specs/

```
spawn_agent(
  agent_type="explorer",
  reasoning_effort="xhigh",
  message="""
Role label: spec-document-reviewer

<task>
Review [SPEC_FILE_PATH] for planning readiness.
</task>

<stop-hook-boundary>
Do not run Stop-hook proof workflows or write Stop-hook proof files.
If a Stop-hook prompt appears, report it as a blocker to the orchestrator and stop.
</stop-hook-boundary>

<check>
| Category | Look For |
|----------|----------|
| Completeness | TODOs, placeholders, "TBD", incomplete sections |
| Consistency | Internal contradictions, conflicting requirements |
| Clarity | Requirements ambiguous enough to cause wrong implementation |
| Scope | Focused enough for one plan, not multiple independent subsystems |
| YAGNI | Unrequested features, over-engineering |
</check>

<calibration>
Only flag issues that would break implementation planning.
Approve unless gaps would produce a flawed plan.
Treat wording, style, and uneven section detail as advisory.
</calibration>

<report>
## Spec Review

**Status:** Approved | Issues Found

**Issues (if any):**
- [Section X]: [specific issue] - [why it matters for planning]

**Recommendations (advisory, do not block approval):**
- [suggestions for improvement]
</report>
"""
)
```

After spawn, print the roster entry: `spec-document-reviewer: <runtime name> [explorer]`.

**Reviewer returns:** Status, Issues (if any), Recommendations
