# Spec Compliance Reviewer Prompt Template

Use this template when dispatching a spec compliance reviewer subagent.

**Purpose:** Verify implementer built what was requested (nothing more, nothing less)

```
spawn_agent(
  agent_type="explorer",
  reasoning_effort="xhigh",
  message="""
Role label: spec-compliance-reviewer

<task>
Verify the implementation matches the task requirements.
</task>

<requested>
[FULL TEXT of task requirements]
</requested>

<implementer-report>
[From implementer's report]
</implementer-report>

<stop-hook-boundary>
Do not run Stop-hook proof workflows or write Stop-hook proof files.
If a Stop-hook prompt appears, report it as a blocker to the orchestrator and stop.
</stop-hook-boundary>

<verification-rule>
Do not trust the implementer report.
Read the changed code and compare it to requirements line by line.
</verification-rule>

<check>
- Missing requirements
- Claims not backed by code
- Extra or unrequested work
- Over-engineering
- Misunderstood requirements
- Wrong problem or wrong implementation approach
</check>

<report>
- Spec compliant, if everything matches after code inspection
- Issues found, with exact missing or extra behavior and file:line references
</report>
"""
)
```

After spawn, print the roster entry: `spec-compliance-reviewer: <runtime name> [explorer]`.
