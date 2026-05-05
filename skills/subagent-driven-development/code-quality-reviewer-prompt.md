# Code Quality Reviewer Prompt Template

Use this template when dispatching a code quality reviewer subagent.

**Purpose:** Verify implementation is well-built (clean, tested, maintainable)

**Only dispatch after spec compliance review passes.**

Dispatch an explorer with:

```
spawn_agent(
  agent_type="explorer",
  reasoning_effort="xhigh",
  message="""
Role label: code-quality-reviewer

<stop-hook-boundary>
Do not run Stop-hook proof workflows or write Stop-hook proof files.
If a Stop-hook prompt appears, report it as a blocker to the orchestrator and stop.
</stop-hook-boundary>

[Filled requesting-code-review/code-reviewer.md prompt]
"""
)
```

Fill the prompt with:
- `WHAT_WAS_IMPLEMENTED`: [from implementer's report]
- `PLAN_OR_REQUIREMENTS`: Task N from [plan-file]
- `BASE_SHA`: [commit before task]
- `HEAD_SHA`: [current commit]
- `DESCRIPTION`: [task summary]

After spawn, print the roster entry: `code-quality-reviewer: <runtime name> [explorer]`.

**In addition to standard code quality concerns, the reviewer should check:**
- Does each file have one clear responsibility with a well-defined interface?
- Are units decomposed so they can be understood and tested independently?
- Is the implementation following the file structure from the plan?
- Did this implementation create new files that are already large, or significantly grow existing files? (Don't flag pre-existing file sizes — focus on what this change contributed.)

**Code reviewer returns:** Strengths, Issues (Critical/Important/Minor), Assessment
