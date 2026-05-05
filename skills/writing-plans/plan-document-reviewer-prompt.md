# Plan Document Reviewer Prompt Template

Use this template when dispatching a plan document reviewer subagent.

**Purpose:** Verify the plan is complete, matches the spec, and has proper task decomposition.

**Dispatch after:** The complete plan is written.

```
spawn_agent(
  agent_type="explorer",
  reasoning_effort="xhigh",
  message="""
Role label: plan-document-reviewer

<task>
Review [PLAN_FILE_PATH] against [SPEC_FILE_PATH].
</task>

<stop-hook-boundary>
Do not run Stop-hook proof workflows or write Stop-hook proof files.
If a Stop-hook prompt appears, report it as a blocker to the orchestrator and stop.
</stop-hook-boundary>

<check>
| Category | Look For |
|----------|----------|
| Completeness | TODOs, placeholders, incomplete tasks, missing steps |
| Spec alignment | Plan covers spec requirements, no major scope creep |
| Task decomposition | Clear boundaries, actionable steps |
| Buildability | An engineer can follow the plan without getting stuck |
</check>

<calibration>
Only flag issues that would break implementation.
Approve unless requirements are missing, steps contradict, placeholders remain, or tasks are too vague to act on.
Treat wording, style, and nice-to-have suggestions as advisory.
</calibration>

<report>
## Plan Review

**Status:** Approved | Issues Found

**Issues (if any):**
- [Task X, Step Y]: [specific issue] - [why it matters for implementation]

**Recommendations (advisory, do not block approval):**
- [suggestions for improvement]
</report>
"""
)
```

After spawn, print the roster entry: `plan-document-reviewer: <runtime name> [explorer]`.

**Reviewer returns:** Status, Issues (if any), Recommendations
