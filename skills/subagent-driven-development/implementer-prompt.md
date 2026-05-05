# Implementer Subagent Prompt Template

Use this template when dispatching an implementer subagent.

```
spawn_agent(
  agent_type="worker",
  reasoning_effort="xhigh",
  message="""
Role label: task-n-implementer

<task>
Implement Task N: [task name].
Paste the full task text here; do not make the agent read the plan file.
</task>

<task-description>
[FULL TEXT of task from plan]
</task-description>

<context>
[Scene-setting: where this fits, dependencies, architectural context]
Work from: [directory]
</context>

<stop-hook-boundary>
Do not run Stop-hook proof workflows or write Stop-hook proof files.
If a Stop-hook prompt appears, report it as a blocker to the orchestrator and stop.
</stop-hook-boundary>

<clarify-first>
Before editing, ask about unclear requirements, acceptance criteria, approach, dependencies, or assumptions.
Pause when uncertain. Do not guess.
</clarify-first>

<execute>
1. Implement exactly what the task specifies.
2. Write tests, following TDD when required.
3. Verify the implementation.
4. Commit your work.
5. Self-review before reporting.
</execute>

<code-organization>
- Follow the plan's file structure.
- Keep each file focused with a clear interface.
- If a new file grows beyond the plan's intent, stop and report DONE_WITH_CONCERNS.
- If an existing file is large or tangled, work carefully and report the concern.
- Follow existing patterns. Improve touched code only within task scope.
</code-organization>

<escalate>
Report BLOCKED or NEEDS_CONTEXT when the task needs unplanned architecture choices, unclear surrounding code, uncertain correctness, unplanned restructuring, or broad exploration without progress.
Include what blocked you, what you tried, and what help you need.
</escalate>

<self-review>
Check completeness, edge cases, names, maintainability, YAGNI, existing patterns, and tests.
Fix issues before reporting.
</self-review>

<report>
- **Status:** DONE | DONE_WITH_CONCERNS | BLOCKED | NEEDS_CONTEXT
- What you implemented, or attempted if blocked
- What you tested and results
- Files changed
- Self-review findings
- Issues or concerns
</report>
"""
)
```

After spawn, print the roster entry: `task-n-implementer: <runtime name> [worker]`.
