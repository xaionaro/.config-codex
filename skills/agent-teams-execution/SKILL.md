---
name: agent-teams-execution
description: Use when facing any non-trivial software building or debugging task that spans multiple independent workstreams
---

# Agent Teams Execution

Phased agent team with adversarial review loops and tiered information trust.

## Delegation Rules

- Start this pipeline only when the user explicitly requested subagents, delegation, or parallel agent work.
- Use standard `spawn_agent`, `send_input`, and `wait_agent` for role execution.
- When waiting on teammates, call `wait_agent` with `timeout_ms: 900000` (15 minutes). Do not use shorter polling or describe waits as "short polls".
- Map explorers/reviewers to `explorer`; map executors/designers/verifiers to `worker` or `default`.
- Spawn with reusable `agent_type` roles only: `explorer`, `worker`, `default`. Team roles (`designer`, `executor`, `qa`) are stable roster labels, not custom `agent_type`s. If the spawn schema lacks `agent_type`, put the intended reusable type in the prompt/roster and record the limitation.
- Give every worker explicit file/module ownership and warn that other agents may edit in parallel.
- Every subagent prompt must include: "Follow any Stop-hook prompt in that session, including required proof/checklist files. Fix blockers within assigned scope. Report to the orchestrator only when resolution needs out-of-scope changes, unrelated user work, credentials, or approval."
- If delegation is not authorized, do not run this pipeline; execute locally with the relevant review checklist.
- If the main/orchestrator lacks standard agent tools, do not run this pipeline; hard-escalate instead of launching shell-based Codex sessions.
- If a teammate role lacks standard agent tools required by ATE but the main/orchestrator has them, use the Lead-Mediated Nested Delegation Adapter.
- `CODEX_ROLE` is legacy hook metadata. Do not use it to launch teammates.

**Core principle:** Explorers gather hard facts, designer architects from facts, executors aggregate implementation until root-task E2E passes, reviewers tear apart the integrated diff, QA validates the whole. Coordinator manages logistics, lead audits rule compliance. Neither implements.

The PreToolUse gate `ate-orchestrator-gate.sh` denies direct Edit/Write/MultiEdit when legacy `CODEX_ROLE` is `lead` or `coordinator`. If the gate fires, spawn the appropriate teammate and assign the task — do not unset `CODEX_ROLE` to bypass it.

Subagents, including lead and coordinator roles, follow Stop-hook prompts in their own sessions, including required proof/checklist files. They report to the main orchestrator only when resolution needs out-of-scope changes, unrelated user work, credentials, or approval. Disengaging by unsetting `CODEX_ROLE` to escape the gate is itself a violation flagged by the rule-compliance self-audit.

### Prompt Artifact Protocol

Before spawning, reassigning, or routing any teammate whose output may become evidence for review, FDR, execution, verifier, QA, or stale-packet guards:

1. Materialize the exact prompt or handoff text in the proof directory.
2. Record artifact path + `sha256sum` in roster/ledger state.
3. Include or forward artifact path + SHA wherever that evidence is consumed.

If `agent_type`, `reasoning_effort`, or another spawn field is unavailable, record the limitation in the prompt artifact and roster/ledger state. Trivial status pings need no prompt artifact when no review, proof, or stale-packet guard depends on them.

### Lead-Mediated Nested Delegation Adapter

Use only when an ATE role must create child agents but its session lacks `spawn_agent`/`send_input`/`wait_agent`, while the main/orchestrator can use standard agent tools.

| Step | Owner | Rule |
|------|-------|------|
| 1 | Blocked role | Defines or approves each child prompt, stop criterion, context packet, and expected output. Prompts include exactly: "Follow any Stop-hook prompt in that session, including required proof/checklist files. Fix blockers within assigned scope. Report to the orchestrator only when resolution needs out-of-scope changes, unrelated user work, credentials, or approval." |
| 2 | Lead | Materializes each child prompt per Prompt Artifact Protocol before spawn. Spawns each child as a separate standard agent, verifies the Spawn Checklist, waits with `timeout_ms: 900000`, and records any unavailable spawn fields per Model and Effort Level. |
| 3 | Lead/coordinator | Mechanically forwards child prompt artifact paths, SHAs, outputs, evidence, and followups. No analysis, filtering, synthesis, or substituted verdicts. |
| 4 | Blocked role | Reviews child outputs, requests followups if needed, and owns the final role verdict. No final verdict until forwarded child evidence is received. |

If the main/orchestrator lacks standard agent tools too, hard-escalate. Never simulate required child agents in one local review.

## ATE Active Marker

Before the first teammate spawn, create the marker the stop gate reads:

```bash
. "$HOME/.codex/hooks/lib/codex-proof-state.sh"

update_ate_marker() {
  phase="$1"
  scope="$2"
  session_id="${CODEX_SESSION_ID:-${CODEX_THREAD_ID:-}}"
  if [ -n "$session_id" ]; then
    codex_valid_session_id "$session_id" || {
      echo "Invalid ATE session id: $session_id" >&2
      exit 1
    }
    marker="$(codex_session_state_dir ate "$session_id")/ate_active"
  else
    marker="$(codex_cli_state_file ate ate_active true)"
  fi

  mkdir -p "$(dirname "$marker")"
  {
    printf 'phase: %s\n' "$phase"
    printf 'scope: %s\n' "$scope"
    printf 'cwd: %s\n' "$PWD"
    [ -n "$session_id" ] && printf 'session_id: %s\n' "$session_id"
    date -u '+updated_utc: %Y-%m-%dT%H:%M:%SZ'
  } >"$marker"
}

update_ate_marker research "<task + scope>"
```

At every phase transition, run `update_ate_marker <phase> "<task + scope>"`. It recomputes the `ate_active` path and writes `phase: <phase>`, `scope`, `cwd`, optional `session_id`, and `updated_utc`.

Active phases: `research`, `design`, `execution`, `testing`, `qa`, `unblocking`.

Run `update_ate_marker awaiting_user "<task + scope>"` only after reporting a QA verdict or user-owned blocker and all in-scope teammates are idle waiting for the user. Switch back to an active phase before routing any followup.

Run `update_ate_marker closed "<task + scope>"` only during user-requested shutdown after teammate shutdown handling.

Do not use `awaiting_user`, `closed`, marker removal, or session-variable changes merely to bypass the stop gate. The marker records ATE lifecycle state; it is not a stop bypass.

**Parallelism principle:** Never serialize independent work. Parallelize everything that can be parallelized.

**No urgency. Infinite time.** Never prioritize speed over discipline. Every shortcut, skipped review, or "good enough" degrades the final result. Do it right, every time.

**Autonomy principle.** Drive the pipeline to QA verdict without user input. Teammates decide within their role; coordinator routes within the pipeline; lead enforces rules. Exhaust normal protocol flow before BRP: clarify, open follow-up tasks, reassign, re-scope, debug, or use paired reviewers/owners first. Escalate to user only for QA verdict, user followup, or when normal flow plus BRP cannot resolve the issue. Otherwise proceed — never ask permission for the next obvious step.

## Mission Completion Guard

The main thread, coordinator, and lead do not stop, final-answer, declare done, or shut down teammates while the user's mission has solvable work. A blocker, QA rejection, escalation label, protocol limit, or subagent stop is routing input, not a terminal state.

Subagent blocker claim = local issue to route. Run BRP only after normal ATE issue handling cannot resolve it, or before user escalation.

Keep unblocking, reassigning, re-scoping, and verifying until the objective mission criteria are met and the user explicitly confirms completion/closure. Stop or wait only when the user asks, or when progress needs user input that agents/tools cannot obtain.

## Project Understanding Ledger

Maintain a project-understanding ledger for every ATE run. Follow the `maintaining-context-ledger` skill for path, content, update timing, and validity rules. If `$SESSION_ID` is unavailable, run the stop gate once to bind session state or hard-escalate with the missing session ID.

The coordinator owns the ledger. Teammates report ledger-worthy facts; if a teammate edits the ledger, include that file in explicit ownership and prevent ownership overlap.

Coordinator updates after: findings, design approval, task code/test approval, blocker resolution, user correction; before QA spawn, user-waiting stop, shutdown. Lead reminds on forgotten updates. Snitch may remind asynchronously after phase transitions, manual audit reminders, and activity bursts. Invalid ledger blocks QA spawn.

<CRITICAL>
When delegation is authorized, spawn bounded standard Codex agents with explicit roles, disjoint write ownership, and concrete expected outputs.

Example authorized mapping: one `explorer` for each independent research slice, one `worker` for implementation ownership, and one `explorer` or `default` reviewer for critique.

**Reusable role slots only.** Name by stable role (`executor-1`, `explorer-2`), not task/round/gate (`executor-auth-fix`, `qa-cycle-3`). Put task id, ownership, lens, phase, and cycle in the assignment. Reassign idle teammates instead of spawning new ones.
</CRITICAL>

## Pipeline Model

**Root task:** the highest active task in the current task tree: no parent task can absorb its changes, proof, review, or commit. Sub-tasks, E2E findings, review fixes, and per-repo commits aggregate under that root until post-review E2E/proof passes.

**Aggregate implementation.** Research and design are global. After design, executors finish root slices and discovered sub-tasks while sub-task/candidate-fix execution reviews run async. Each code target uses both reusable Execution Reviewer lens slots: correctness/fidelity and long-term health. Verdicts use APPROVED/CONDITIONAL/REJECTED. Root aggregate review blocks final proof/QA: REJECTED reruns both lenses after fixes, proof, and amend/squash; CONDITIONAL creates required pre-QA fix tasks that must be fixed and verified before final proof/QA. Async CONDITIONAL/REJECTED findings route through independent verification, then enter the next active iteration or queued async-followups if none remains. NITs stay optional. Async output never delays or reopens root aggregate review.

**Queued async-followups.** Store each entry in the task list and project ledger with owner, source review, verified finding, verification evidence, target root/cycle, and replay trigger. Replay when the next execution iteration, pipeline cycle, or root-task cycle opens.

| Stage | Scope | When it starts |
|-------|-------|---------------|
| Research | Global | Immediately |
| Design | Global | After research |
| Execution | Per task/slice | After design approved. Sub-task/candidate-fix execution review runs async; no blocking code review yet. |
| E2E confirmation | Root task | After all known slices/sub-tasks land. Failures spawn tasks. |
| Aggregate review | Root task | After E2E proves the root task is fulfilled. Loop until no REJECTED/CONDITIONAL remains. |
| Post-review E2E + QA | Final | After aggregate review has no REJECTED/CONDITIONAL. |

**Final QA:** After post-review E2E passes, QA runs all tests, checks all requirements, validates the integrated whole.

### User Followups

After the team reports a QA verdict, the user may send followups (bug reports, tweaks, new features, questions). Coordinator routes each followup through **as much of the full pipeline as reasonably applies** — never skip stages for "small" requests.

| Followup type | Pipeline |
|---------------|----------|
| Question / clarification | Explorer → answer to user. No code. |
| Trivial config tweak (1-line, no logic) | Executor → E2E/targeted proof → aggregate review → rerun proof → QA |
| Bug fix | Executor/debug roles → E2E confirmation → aggregate review → rerun E2E → QA |
| Behavior change in existing feature | Designer → both Design Reviewers → execution → E2E confirmation → aggregate review → rerun E2E → QA |
| New feature | Full pipeline: Research → Design → both Design Reviewers → execution → E2E confirmation → aggregate review → rerun E2E → QA |

**Default: when in doubt, run more pipeline, not less.** Skipping stages for "small" requests is how regressions ship. Coordinator justifies any skipped stage to lead and CCs snitch asynchronously.

## Roles

| Role | Count | Phase | Responsibility |
|------|-------|-------|---------------|
| **Coordinator** | 1 | all | Task assignment, routing, phase management. Requests spawns from lead. **Never implements.** |
| **Lead** | 1 | all | Spawns teammates. Audits coordinator's rule compliance. Reminds coordinator when it forgets enforcement. **Never implements.** |
| **Explorer** | 1+ | 1 | Gather facts. Tag sources. Challenge each other. |
| **Designer** | 1 | 2 | Architect from findings. Produce file ownership map. Ship a minimal proof-of-concept implementation for any unproven-in-practice mechanism the design relies on — see Designer PoC Requirement. |
| **Design Reviewer** | 1+ | 2 | Adversarial design review against the design itself. Report only, never edit design. 2+ for large tasks. |
| **Fundamentals Design Reviewer** | 1 | 2 | Runs in parallel with Design Reviewer. Challenges design fundamentals, not surface issues. Must obtain three separate standard-agent child reports: (1) brainstormer — list possible fundamental issues (premise, problem framing, architectural axioms, hidden assumptions, scope, alternatives); (2) reviewer — investigate design against each listed issue and report; (3) meta-reviewer — critically review the reviewer's report for missed angles, weak evidence, rubber-stamping. If FDR lacks agent tools, use the Lead-Mediated Nested Delegation Adapter; FDR defines/approves prompts and owns the final verdict. Report only, never edit design. |
| **Executor** | 1+ | 3 | Implement assigned task + unit tests. One per independent unit of work. Actively look for code smell and design issues in code they study/touch, report all to coordinator. Broken infra or resorting to a workaround = notify coordinator before proceeding. |
| **Execution Reviewer** | 2 reusable lens slots | 3 | Correctness/fidelity + long-term health. Review targets: root aggregate, sub-task, candidate fix. Root scope blocks. Async scopes queue follow-ups per Execution dual review. Report only. |
| **Test Designer** | 1 | 3 | Write test specs. Waits for interface contracts. |
| **Test Executor** | 1+ | 4 | Implement tests from specs. |
| **Test Reviewer** | 0-1 per root task | final | Reviews test changes during aggregate/final review when needed. Report only, never edit tests. |
| **Verifier** | 1+ | per task | For lightweight tasks (no code, no test pipeline). Adversarially checks deliverable against all expectations. Replaces test pipeline when testing is N/A. |
| **Brainstormer** | 1 | any | On-demand when a blocker emerges. Genius creative unblocker — thinks outside the box. Lists as many solution ideas as possible. Positives only — no negatives, no filtering, no feasibility judgment. Bigger list = better. |
| **Snitch** | 1 | all | Snitch is async-only: CCs, reminders, audits, reports, verification requests, and silence create no prerequisite, wait, direct interruption, or gate. CCed on all submitted/blocked/completed claims and QA verdicts. Independently audits rule compliance and reports violations to lead/coordinator. Success = confirmed violations found. May push back once per report if lead dismisses: quote the exact rule/requirement violated and why no workaround is acceptable. On QA approvals, looks for testing gaps: insufficient coverage, proxy-only evidence where direct was possible, untested criteria. On reviewer APPROVED messages, checks for rubber-stamping against the executor critique log and reports gaps to lead. Lead handles confirmed gaps under normal finding/priority rules. Lead or coordinator sends event-driven audit reminders with `send_input` at milestones, after long waits, and when execution resumes after user-waiting. Snitch uses available `wait_agent` results and teammate output to detect dead or drifting agents. On every audit, also check ledger freshness and asynchronously remind coordinator after activity bursts without updates. |
| **QA** | 1 | final | Final integration check. Runs all tests. Last gate. |

### Team Sizing

One execution lane per independent unit. Keep two Execution Reviewer lens slots alive/reused; spawn only missing lenses. Root aggregate review starts after root E2E/proof and uses both lenses.

## Mandatory Compliance

**Every teammate** must invoke `agent-teams-execution` skill via skill instructions as their first action. Lead **must include this instruction in every spawn prompt**. Coordinator and lead: re-invoke the skill after every context compaction.

Blocker handling uses `blocker-resolution-protocol` (BRP). Lead includes that skill name in prompts for blocker-resolution tasks.

**Manual skill refresh (coordinator, lead, snitch).** Lead uses `send_input` to remind active teammates to re-invoke `agent-teams-execution` after context compaction, phase changes, long waits, and user-waiting resume. Use `wait_agent` status before treating silence as a failure.

### Model and Effort Level

All teammates: configured Codex model, xhigh effort. Current Codex spawn schemas may not expose `reasoning_effort` or `agent_type`. When a field exists, set it. When unavailable, put the requirement in prompt text and record the schema limitation; do not claim an unavailable argument was set. Omit model overrides unless the user explicitly requested one.

### Critical Analysis of All Inputs

No input trusted by default — including peer messages. Never praise peer output. "Excellent work" is not analysis — it's the opposite. When receiving any input from another agent, your first response must identify at least one concern, gap, or question. Verify before building on it. Flag contradictions to coordinator. You own bugs from unverified inputs.

### Claim Verification

Tag every factual claim: `[T<tier>: <source>, <confidence>]`

| Tier | Source | Treatment |
|------|--------|-----------|
| **T1** | Specs, RFCs, official docs, source code | Trusted directly |
| **T2** | Academic papers, established references | High trust; verify if contested |
| **T3** | Codebase analysis (code, tests, git history) | Trust for local facts |
| **T4** | Community (SO, blogs, forums) | Verify independently |
| **T5** | LLM training recall (no source) | **Promote to T1-T4 or discard** |

Confidence: `high` (directly stated), `medium` (logically derived), `low` (indirect). T5 unacceptable in final output. Higher tier wins contradictions. What can be fact-checked, must be.

### Mandatory Skills

| Condition | Skill |
|-----------|-------|
| Debugging | `systematic-debugging` + `debugging-discipline` |
| Go code (*.go) | `go-coding-style` |
| Python code (*.py) | `python-coding-style` |
| Tests | `testing-discipline` |
| Code implementation | `test-driven-development` |
| Logic implementation | `proof-driven-development` |
| Android device | `android-device` |

Executors invoke coding style + `proof-driven-development` + `test-driven-development`. Test executors invoke `testing-discipline`. Lead copies exact skill names into spawn prompts. Determine language from design doc, include matching coding style skill. No placeholders.

**Code quality — semantic integrity is non-negotiable:**
- Names are contracts: implementation fulfills exactly what the name promises. No smuggled decisions or side effects.
- Same concept = same name everywhere. Related concepts use parallel structure.
- Strong typing for domain concepts. No bare primitives where named types belong.
- Package/binary scope: code belongs in the binary whose stated purpose matches the code's function. A standalone CLI tool must not contain code requiring a running daemon.
- Clean solution over hack, always. Reviewers reject shortcuts, workarounds, and "good enough for now."
- Root cause first. A fix must identify and repair the mechanism that causes the failure. No causal link may remain unexplained. Any change that only alters the failure's frequency, timing, visibility, or blast radius is mitigation; reviewers reject it unless containment was explicitly requested.
- Interface implementation is a contract: "I fulfill this interface." An always-erroring implementation is a false claim — same as naming a function Save that doesn't save. Stub implementations that always error must not exist in production code.

### Task States

| Skill state | System state | Meaning | Who sets it |
|-------------|-------------|---------|-------------|
| **pending** | pending | Created, not yet started | Coordinator |
| **blocked_by_task** | pending | Waiting for another task to complete first | Coordinator |
| **in_progress** | in_progress | Agent is actively working on it | Assigned agent |
| **blocked** | in_progress | Normal lane handling failed, or protocol limit hit; needs BRP/user-owned resolution | Coordinator (CC lead + snitch) |
| **exploring** | in_progress | Explorer investigating (research phase or blocker investigation) | Coordinator |
| **unblocking** | in_progress | BRP agents working to resolve blocker | Coordinator (after BRP starts) |
| **submitted** | in_progress | Agent believes done, awaiting verification | Assigned agent (CC lead + snitch) |
| **in_review** | in_progress | Aggregate reviewers reviewing the root-task diff | Coordinator (after root-task E2E confirmation) |
| **in_test_design** | in_progress | Test designer writing specs (code tasks only) | Coordinator (after interface contracts exist) |
| **in_testing** | in_progress | Test executor implementing/running tests or E2E confirmation | Coordinator (after test specs ready or before aggregate review) |
| **in_verification** | in_progress | Verifier adversarially checking (non-code tasks) | Coordinator (after reviewer approves) |
| **queued_async_followup** | pending | Verified async CONDITIONAL/REJECTED with no active execution/root-task cycle; stored in task list + ledger | Coordinator |
| **complete** | completed | Proved done — reviewed, tested, evidence provided. ONLY after full verification | Coordinator |

**Transition requirements:**

| Transition | Requirements |
|------------|-------------|
| pending → in_progress | Agent assigned. Executors: file ownership assigned |
| pending → exploring | Research task: route to explorer |
| exploring → submitted | Explorer findings complete (research-only tasks). CC lead + snitch |
| exploring → in_progress | Exploration done, task needs execution next. Executors: file ownership assigned |
| pending → blocked_by_task | Task depends on another task that isn't complete yet |
| blocked_by_task → in_progress | Blocking task completed. Agent assigned |
| in_progress → blocked | Normal lane handling failed with required blocker record, or aggregate review hits the 11th REJECTED loop and coordinator creates a protocol-limit blocker record. CC lead + snitch |
| blocked → unblocking | Coordinator runs `blocker-resolution-protocol` |
| unblocking → in_progress | Feasible solution found and assigned. Blocker resolved |
| unblocking → blocked | No feasible solution found. Escalate to user |
| in_progress → submitted | All claims tagged. Critique log exists. Code/debugging tasks: RCA explains cause chain; root-task E2E/targeted proof confirms fulfillment; aggregate changes committed once per touched repo. CC lead + snitch |
| submitted → in_progress | Coordinator bounces back: submission checklist failed |
| submitted -> in_review | Coordinator verifies submission checklist passes. Code targets: route the full root-task diff to both reusable Execution Reviewer lens slots. Non-code targets: route to a verifier unless a role-specific paired reviewer applies. |
| in_review → in_progress | Root REJECTED/CONDITIONAL. Create/fix tasks. REJECTED reruns both lenses after proof/amend; CONDITIONAL fixes verify before final proof/QA |
| in_review → in_testing | No root REJECTED/CONDITIONAL remains. Rerun full root-task E2E before completion/QA |
| verified async CONDITIONAL/REJECTED → pending | Root/execution fix iteration opens. Create follow-up task there; do not interrupt current work/review |
| verified async CONDITIONAL/REJECTED → queued_async_followup | No active execution/root-task cycle. Store per queued async-followups |
| queued_async_followup → pending | Replay trigger fires. Route into next execution iteration, pipeline cycle, or root-task cycle |
| in_test_design → in_testing | Test specs ready. Route to test executor |
| in_test_design → in_progress | Test designer finds interface contracts wrong/incomplete. Routes back to executor |
| in_review → in_verification | Reviewer approved with evidence. Non-code tasks: route to verifier |
| in_testing → complete | Post-review E2E/tests passing. CC lead + snitch |
| in_testing → in_progress | E2E/tests reveal bugs. Create/fix tasks; no review until root-task E2E passes again |
| in_verification → complete | Verifier approved with evidence against all expectations. CC lead + snitch |
| in_verification → in_progress | Verifier found issues. Routes back to executor |

**No agent can set a task to "complete"** — only the coordinator after all verification passes. No git push without user request. One root task = one commit per touched repo when feasible; document any repo/tool constraint. Lead enforces all transitions.

### Status Reports

Reports to user use human-readable task names, not task/phase/lane numbers.
Use a tree when work decomposes into sub-tasks, blockers, followups, or nested pipelines.

### Git & Security

- Never expose secrets or credentials in code, commits, logs, prompts, or final output. Static checks before every commit. Never push without user approval. No AI co-author lines.
- Security first. Never disable security features. OWASP top 10 for all code. Validate at system boundaries.

## Root-Task Loop

| Step | Rule |
|------|------|
| Implement | Finish all known slices/sub-tasks; unit tests stay with code. |
| Confirm | Run root-task E2E/targeted proof; failures spawn tasks. |
| Commit | Keep one root-task commit per touched repo when feasible. |
| Review | Both Execution Reviewer lens slots inspect the integrated code diff. |
| Repair | REJECTED reruns both lenses after fix/proof/amend. CONDITIONAL creates required pre-QA fix tasks. |
| Final proof | After no root REJECTED/CONDITIONAL remains, rerun full E2E/proof before QA. |
| QA | Validate the integrated whole. |

## Checkpoints & Re-Entry

After each root-task aggregate review + post-review E2E, coordinator records: **what was produced**, **who approved** (with evidence), **git SHA**.

**Re-entry impact assessment:** Diff old vs new design. Invalidate only root aggregates touching changed interfaces (reset loop counters). Notify test designer. Unaffected tasks continue.

## Design Output Requirements

Phase 2 design **must include**:
1. **Architecture** -- components, data flow, error/failure flow, interfaces
2. **File ownership map** -- no overlaps. Spawn prompts include: "You own ONLY these files: [list]."
3. **Binary/service purpose map** -- for each binary or deployable, one-sentence statement of purpose, scope, and dependencies. File ownership map must be consistent with this.
4. **Interface contracts** -- public APIs/signatures per task, including: error/failure modes, preconditions/postconditions, data invariants, thread safety. Test designer uses these before executors finish.
5. **Module dependency graph** -- coordinator uses for executor sequencing.
6. **Requirement traceability** -- component → user requirement mapping. Every requirement covered, every component justified.
7. **Security design** (when applicable) -- trust boundaries, attack surfaces, security controls, auth strategy. OWASP at design time, not just code review.
8. **Shared concerns register** -- logic/types/patterns needed by 2+ tasks. Each entry: {what, which tasks, designated shared location}. Executors consume this to avoid reimplementation.

**Git worktrees:** 2+ parallel executors -> each gets own worktree. Merge before root-task E2E; squash/amend to one root-task commit per touched repo.

## Testing Protocol

**Unit tests:** Written by executors alongside their code. Part of execution, not a separate phase.

**Integration/E2E tests (Phase 4):**
- **Test designer** writes specs covering all applicable test types: integration tests (cross-task boundaries), full E2E tests (entire user-facing flows), and UI tests (screen manipulation, interaction sequences) when the project has a UI.
- Every cross-task interface must have at least one test on the real call path (no mocks at boundaries).
- E2E tests exercise complete workflows as a user would, including UI manipulation when applicable.
- Before aggregate review, run full root-task E2E/targeted proof. Failures become tasks. No aggregate review until proof passes.
- After no root REJECTED/CONDITIONAL remains, rerun full root-task E2E before QA.
- E2E capacity bottlenecked: batch only then. While waiting, debug via shortest faithful repro (unit/API/CLI/log replay/component) before full E2E. Wait briefly for imminent tasks only if no slot idles; keep healthy batches running; queue late arrivals; report root-task verdicts.
- **Failure routing:** cross-task boundary bug → execution lane. Design flaw → research/design.

## Feedback Loops

Paired roles communicate **directly**. All other feedback routes through coordinator. All submitted, blocked, and completed claims, plus coordinator -> lead spawn/re-spawn/phase-transition requests, CC lead and Snitch asynchronously. CC delivery is an audit signal only; it is not a transition condition, prerequisite, or independent-verification gate.

| From | To | Trigger | Route |
|------|----|---------|-------|
| Design Reviewer | Designer | Design flaw | Direct (paired) |
| Designer | Explorers | Needs info | Coordinator requests lead to re-spawn |
| Executor | Execution Reviewers | Sub-task/candidate-fix ready | Direct, async. Assign/reuse both lens slots; spawn only missing lenses. Executor continues in-flight work. |
| Execution Reviewers | Executor | Root aggregate issue | Direct during root aggregate review. |
| Executor | Coordinator | Design issue or code smell found | Coordinator records {question, source, target}; routes a second agent for verification. Valid minor issue -> assigned executor fixes directly; design-level -> full pipeline |
| Execution Reviewers | Coordinator | Async sub-task/candidate-fix verdict | Coordinator assigns independent verification for CONDITIONAL/REJECTED findings, then routes verified findings to the next active iteration or queued async-followups. NITs stay optional. Async output never delays or reopens root aggregate review. |
| Test Reviewer | Test Executor | Aggregate/final test issue | Direct during final review |
| Any agent | Coordinator | Findings received | Coordinator assigns independent verification before accepting |
| Any teammate | Coordinator | Blocker claim | Route normal lane handling first. Missing attempt log -> bounce back. BRP only after normal handling fails. |
| Aggregate review | Coordinator | 11th REJECTED pass | Create protocol-limit blocker record; run `blocker-resolution-protocol` |
| QA | Coordinator | Any verdict (approval or rejection) | CC snitch. On approval, QA must demonstrate sufficient testing was performed (which criteria, what evidence, direct vs proxy). On rejection, route by type. Snitch looks for gaps in testing |

### Debug Mode

Applies: bug fix, build failure, flake, perf regression, any task whose deliverable is fixing observed broken behavior.

- Any discovered bug enters Debug Mode: user followup, teammate finding, test failure, reviewer finding, or QA rejection. Coordinator/lead never debug or patch directly.
- Delegate `debugging-discipline` roles to separate agents: repro → test executor/verifier; RCA → explorer; critic → independent reviewer; fix → executor; aggregate review → both execution reviewers + final QA. Every bug-task prompt says: "Load `systematic-debugging` and `debugging-discipline`; follow their repro/RCA-critic/fix-review loop. Do not submit until root cause is falsifiable and the fix is proven on the real failing path."
- Coordinator validates RCA transitions against `debugging-discipline`: current repro, evidence-backed cause chain, alternatives, falsifying prediction tested or recorded as still required, and critic loop with no unresolved objections. Symptom bundle, suspected cause, or "needs more evidence" is not RCA acceptance.
- When Snitch is assigned or CCed to an RCA/debugging transition audit, Snitch loads `debugging-discipline` and checks repro, alternatives, falsifying prediction, critic loop, and cause chain. Snitch is an additional guard; coordinator remains responsible for transition and acceptance.
- Debug packets must label state as `hypothesis`, `accepted-for-fix`, `fix-submitted`, or `confirmed-fixed`. Only `confirmed-fixed` may say RCA/fix is closed.
- `confirmed-fixed` requires the domain-required acceptance proof on the real failing/user path. Missing, failing, or not-runnable required proof blocks `submitted`, `complete`, "fixed", and "RCA closed" wording; report it as source-only/progress plus next proof.
- Executor iterates candidate fixes without per-attempt reviewer gate. No `submitted`/`in_review` transition until root-task E2E/proof passes.
- Candidate-fix review verdicts are advisory during the debug loop; they are not a stop condition, lane handback, or prerequisite to the next proof run or still-red failure packet.
- Candidate-fix reviews use sub-task/candidate-fix execution review rules: both lenses, async verdicts, independent verification, next active iteration or queued async-followups. Async output never delays or reopens root aggregate review.
- Proof while hunting = failing repro → passing on real path.
- Before `submitted`, executor provides root-cause rationale: cause chain, evidence, and why the diff repairs the cause. Unknown "why" = not submitted.
- After proof passes, task → `submitted` → `in_review`. Reviewers critique the full aggregate diff+rationale, reject mitigation, and improve cleanup, hardening, and semantic correctness.
- Loop limit (10 rounds) counts aggregate review rounds only. Pre-submission attempts are uncounted.
- Bug-fix pipeline in User Followups still applies — Debug Mode only changes the executor↔reviewer semantics inside the Execution stage.

### Loop Limits

Round = one REJECTED review pass (initial submission is not a round).

- **10 rounds max** per root-task aggregate review. 11th REJECTED pass -> protocol-limit blocker: run BRP before user escalation. Counters reset on QA/Phase 2 re-entry.
- **2 QA re-entries max** (total). 3rd -> escalate to user with: what failed, what was tried.
- **2 designer-to-explorer rounds max.** Cap hit -> create a protocol-limit blocker record; run `blocker-resolution-protocol` before user escalation.

### Crash Recovery

**Stale floor:** A teammate is not stale until at least 30 minutes have passed since its last assignment, output, file/git activity, or observed process activity. Before 30 minutes: no status requests, no checkpoint prompts, no "are you blocked?" messages, no interruption for progress.

**Not responding to messages ≠ dead.** Coordinator checks coordination signals before declaring unresponsive:
1. Check: does the teammate have an active running process? (compilation, test suite, build, context compaction) → working, not hung.
2. Check: are files or git state changing in their worktree? → working, not hung.
3. If 30+ minutes elapsed with no active process and no file/git activity: **interrupt first** — send a message asking for status, then interrupt if the tool surface supports it. Wait for response.
4. Only if no response after interrupt → confirmed unresponsive.
Skipping any step = false positive. Coordinator must document evidence of all checks before requesting re-spawn.

Once confirmed unresponsive, **immediately** re-spawn under the same reusable role label — no delays. The task must not stall.
**Executors:** preserve unreviewed output for the root-task aggregate review before closure. Re-spawn only after checkpointing diff/status.
**Non-executors:** Re-spawn immediately under the same reusable role label. Max 2 re-spawns per role, then escalate to user.

### Misbehavior Recovery (any agent)

**Every violation:** lead/coordinator sends the violating agent the specific rule + correction and notifies the oversight roles. Snitch reports suspected violations to lead/coordinator asynchronously; Snitch never directly interrupts teammates.

**Repeated violations (3+ on same rule):** Counts only corrections the agent received and still violated afterward. Acknowledgement not required; receipt is. Coordinator verifies receipt before counting a cycle. Trigger: 3+ confirmed receive-then-violate cycles. Then restart the agent with a fresh prompt to re-read the skill and continue. If still misbehaving, escalate to user.

**Force-deliver corrections.** Agent busy or mid-turn may not see `send_input` until its turn ends. Interrupt when available, then re-send the correction.

### Priority Discipline

Highest severity first. A finding interrupts the agent's current task **only if its severity is strictly higher** than the current task's severity. Same-or-lower → queue. Critical-on-Critical does not interrupt — let the in-flight Critical finish.

Severity ladder (highest → lowest):
1. **Critical** — security, correctness, spec violation
2. **Major** — design deviation, missing edge case
3. **Minor** — style, smell, sub-optimal but functional
4. **Nit** — preference, formatting, naming polish

**Blocker severity inheritance.** Task A unavoidably blocks task B -> severity(A) >= severity(B). Transitive across chains: any chain terminating in Critical lifts every prerequisite to Critical. Lift only, never reduce. Re-scopable-around blocker is not unavoidable; route around it instead.

| Current task | Interruptible by | Queue (deliver after submission lands) |
|--------------|------------------|----------------------------------------|
| Critical | (nothing) | every finding, including other Critical |
| Major | Critical | Major / Minor / Nit |
| Minor | Critical / Major | Minor / Nit |
| Nit | Critical / Major / Minor | Nit |

Applies to coordinator, lead, reviewer, and peer findings. Snitch findings are advisory inputs routed by lead/coordinator under this table. Queued findings batched into one consolidated message per submission, never streamed.

Executor receiving a finding list: address in strict severity order, highest first. Defer everything at-or-below the current goal's severity until that goal is proven done.

### Blocker Resolution

Concrete bug/build failure/flake/perf/incorrect behavior -> Debug Mode (`systematic-debugging` + `debugging-discipline`), not BRP; BRP only if debugging itself is blocked with an attempt log, hits its cap, or needs user-owned input.

Use `blocker-resolution-protocol` only after normal ATE issue handling fails, for review/iteration protocol-limit blockers, or for task-progress pre-user-escalation decisions.

Unresponsive-agent recovery, repeated agent misbehavior, coordinator silence, and shutdown/lifecycle failures follow ATE lifecycle recovery unless they expose a separate concrete work blocker. Do not run BRP merely because those lifecycle paths can end in user escalation.

ATE adapter:
- Coordinator owns the BRP task and task-state transitions.
- Lead verifies that the blocker record has the required attempt log before BRP starts. Snitch may audit the blocker record asynchronously after BRP starts; BRP does not wait for Snitch.
- Coordinator launches brainstormer and primary explorer simultaneously, then launches a second explorer for feasibility validation before routing the best feasible path.
- On the 11th REJECTED pass in a root-task aggregate review, coordinator creates the protocol-limit blocker record from the rejection history, then runs BRP.
- On the designer-to-explorer cap, coordinator creates the protocol-limit blocker record from the designer/explorer round history, then runs `blocker-resolution-protocol`.
- Escalate to the user only if BRP finds no feasible internal path or the blocker requires user-owned product/scope input.

## Reviewer Protocol

**Blocking reviewers** (design, aggregate execution, test):

**Reviewers report, never fix.** No editing code, designs, or tests. Describe the problem and suggest a fix direction. The paired executor implements all changes.

0. **Does it work?** Before evaluating quality, verify code fulfills its stated purpose. If it doesn't — REJECT.
1. **Root cause first.** Critique the executor's rationale. Unknown causal link or symptom-only change = REJECT unless containment was explicitly requested.
2. **Assume wrong.** Find errors. Look for what's missing.
3. **Classify:** Critical (security, correctness, spec violation), Major (design deviation, missing edge case) — both block for blocking review gates. Minor (doesn't block), Nit (never blocks).
4. **Outcomes:** Execution reviews use Execution dual review. Other gates: APPROVED (no Critical/Major, with evidence); CONDITIONAL (Minor/Nit listed; coordinator opens follow-ups per Priority Discipline); REJECTED (Critical/Major cited with fix direction). Every Critical/Major must cite `file:line`. Fix direction must name the exact symbol changed. Vague findings ("refactor this function", "clean this up") are inadmissible. Rejections must enumerate reasons before any approval statement — no mixed verdicts.
5. **Check against:** design doc, coding style skill (semantic integrity, naming, typing, no shortcuts — every rule), root-cause rationale, OWASP top 10, edge cases, error handling, requirements, claim tags, critique log. No coding style invocation = reject. Untagged factual claims = reject. T5 claims not promoted = reject. No critique log = reject.
6. **Max 10 rounds.** 11th REJECTED pass becomes a protocol-limit blocker; run `blocker-resolution-protocol` before user escalation.

**Sub-task/candidate-fix execution review effect:** Report, never fix. Use Execution dual review and the Execution Reviewer Checklist. Verdict labels match root aggregate review. Async CONDITIONAL/REJECTED findings route to coordinator for independent verification, then enter the next active iteration or queued async-followups if none remains. NITs stay optional. Executor continues in-flight work. Async output never delays, reopens, or retroactively blocks root aggregate review.

Design creates a type/component but defers making it work = reject. Valid deferral: don't create it yet. Invalid deferral: create a broken version.

### Designer — Proof of Concept Requirement

Any design whose core mechanism is unproven-in-practice (not a well-known pattern, not already shipped in this codebase, not a documented vendor API used as documented) ships with a minimal PoC:

- Strip every concern not needed to exercise the core mechanism — no error handling, no edge cases, no production polish, no scaffolding beyond what the demo requires.
- Run end-to-end on one real input; produce the observable behavior the mechanism claims.
- Hand off the PoC with the design. Missing PoC for an unproven mechanism = REJECT.

Proven-in-practice mechanisms need no PoC. State "proven by <link/citation>" when claiming exemption.

### Design Reviewer — Additional Rejection Criteria

REJECT if any are missing or incomplete:
- Requirement traceability (item 6) — every requirement mapped, every component justified
- Security design (item 7, when applicable) — trust boundaries, attack surfaces, controls
- Shared concerns register (item 8) — all cross-task logic/types identified with designated locations
- Enriched interface contracts (item 4) — error modes, pre/postconditions, invariants, thread safety
- File ownership map contradicts binary/service purpose map (items 2 vs 3)

### Fundamentals Design Reviewer — Verdict

| Verdict | When |
|---------|------|
| **REJECT** | A substantive fundamental flaw — falsifies a load-bearing part of the design; cannot be patched without rethinking premise, framing, scope, or another foundational decision. |
| **CONDITIONAL** | No fundamental flaw, but a significant issue remains. Main task completes; coordinator opens follow-up tasks. |
| **NIT** | Only minor or non-substantive issues. Never blocks. |

The reviewer is not constrained to any fixed taxonomy of flaw types; the test for REJECT is impact, not category.

### Execution Reviewer Checklist

Extends the general Reviewer Protocol above (which already covers OWASP, edge cases, error handling, claim tags, critique log). Execution reviewers additionally check:

**Execution dual review:** Keep two reusable lens slots: correctness/fidelity and long-term health. Assign both to each target; spawn only missing lenses. Review independently first. Long-term health lens judges final state only: no change-history defense; artifact must stand on its own. Verdicts: REJECTED for Critical or Foundational; CONDITIONAL for Major; APPROVED when no blocking finding remains. APPROVED may include NIT notes. Root aggregate REJECTED reruns both lenses after fixes, proof, and amend/squash. Root aggregate CONDITIONAL creates required pre-QA fix tasks; fix and verify before final proof/QA. Async CONDITIONAL/REJECTED findings route to coordinator for independent verification. Verified findings enter the next active iteration. If none remains, record them in queued async-followups for the next pipeline/root-task cycle. Async output never delays, reopens, or retroactively blocks root aggregate review.

**Long-term health diff-only intention check:**
- Code targets only. Skip when there is no code diff.
- Before Packet 1, clear the long-term-health reviewer context when supported; otherwise shutdown+respawn under the same stable lens label.
- Packet 1 contains only role label, required skill/stop-hook/claim-tag boilerplate, code diff, and reconstruction instruction.
- Exclude objective, design, ledger, task list, prompt artifact, commit message, executor rationale, teammate summary, shared concerns register, and prior review output.
- Reviewer returns `reconstructed intention:` with 2-4 bullets covering apparent root reason and intended behavior change, then stops.
- Send Packet 2 with normal execution-review context only after Packet 1 returns.
- Coordinator/lead compares reconstruction with actual root reason and desired effects.
- If it misses root reason, relies on hidden context, or claims an undesired effect, create a `CONDITIONAL` follow-up task with normal Execution dual review verdict metadata to make code, tests, names, comments, or commit message self-explanatory.

- [ ] Load the `<language>-coding-style` skill via skill instructions. Check every rule.
- [ ] Requirements coverage — each user requirement → code
- [ ] Design compliance — implementation matches architecture + interface contracts (error modes, pre/postconditions, invariants, thread safety)
- [ ] Root-cause rationale — cause chain complete; diff repairs the cause, not only symptoms
- [ ] Code location — files in correct binary per purpose map
- [ ] Shared concerns register — no reimplementation (REJECT); missed abstraction (CONDITIONAL)

### Executor Disputes

Dispute a finding with evidence: cite code, spec, or test. Reviewer withdraws or escalates with stronger evidence. One exchange, then coordinator decides.

### Multi-Reviewer (2+)

Review independently first — no reading peer findings before writing your own. Minority dissent requires counter-evidence to override. T1 outweighs T3.

**Lens partition.** Except execution reviewers, whose lenses are defined above, coordinator assigns non-overlapping lenses: (1) correctness/edge cases, (2) security/OWASP, (3) design/semantic integrity/naming. With 2 reviewers: 1+2. With 3: 1+2+3. With 4+: split correctness or design. Each reviewer covers its lens first; out-of-lens issues are still reported. Identical sibling reviewer prompts = reject.

## QA Protocol

**Four-step protocol applied to every acceptance criterion:**

1. **State** — explicitly state what must be true (the criterion)
2. **Identify** — identify what evidence would prove it, distinguishing **direct** from **proxy**:
   - **Direct evidence**: shows the thing itself working (running the actual program end-to-end, observing the output, reproducing the user-facing flow)
   - **Proxy evidence**: indirect signal (unit tests pass, linter clean, type check passes)
3. **Obtain** — actually obtain the evidence. Run the commands. Execute the program. Reproduce the flow. **Always prefer direct evidence.** Proxy evidence alone never satisfies a criterion that can be verified directly.
4. **Judge** — judge whether the evidence proves the criterion. Cite the exact output/observation. "Looks right" is not judgment — quote the evidence.

**Acceptance criteria checklist:**

- [ ] Implementation matches design
- [ ] All original requirements met
- [ ] All claims tagged, no T5 remaining
- [ ] OWASP top 10 security review
- [ ] Edge cases handled
- [ ] Integration tests pass (run them — direct)
- [ ] All unit tests pass (run them — proxy, still required)
- [ ] End-to-end flows verified (direct — run the program as a user)
- [ ] Root-cause rationale reviewed; no unexplained causal link or symptom-only mitigation
- [ ] No uncommitted changes; no secrets or credentials exposed
- [ ] Static checks pass
- [ ] Mandatory skills invoked by all teammates
- [ ] Critique logs exist for all teammates
- [ ] File ownership respected
- [ ] Code quality: clean code, semantic integrity, no shortcuts, no workarounds, coding style fully followed
- [ ] Project-understanding ledger valid per `maintaining-context-ledger`

## Coordinator Responsibilities

**NEVER do implementation work.** No code, research, exploration, investigation, or analysis. Your context is coordination state; work flows to teammates through the lead and the approved Codex agent mechanism. Agents make mistakes — never trust claims at face value. Reviewers validate completion; launch explorers to verify blockers and external blame.

**AGGREGATE REVIEW INVARIANT:** Async execution reviews run during execution per Execution dual review. Start root aggregate review after known slices/sub-tasks land, root E2E/proof passes, and one commit per touched repo exists. Route arrived async output through independent verification; do not wait for pending output. If root aggregate review is running, hold verified async CONDITIONAL/REJECTED until review finishes; route into its next fix iteration, or queue as queued_async_followup if none opens. Root REJECTED findings become tasks; fix, re-prove, amend/squash, rerun both lenses. Root CONDITIONAL findings become required pre-QA fix tasks; fix and verify before final proof/QA. After no root REJECTED/CONDITIONAL remains, rerun full E2E/proof before QA.

**Proof waits:** Coordinator may wait on any proof only when the task records {question, cheapest faithful environment, rejected cheaper-environment reasons, active owner} and that owner is running the proof now. Missing record -> record before waiting; missing active owner -> assign one. Coordinator records and routes; teammates investigate. Each status cycle classifies every waiting lane as running proof, reassigned, closed, or blocked with failed unblock attempts.

1. **Track EVERYTHING as tasks.** Every deliverable, sub-task, blocker = task. Task list is single source of truth. Keep the project-understanding ledger current with the high-level context behind those tasks.
2. **Request spawns from lead.** Coordinator determines who is needed and when; lead creates the agent team and spawns teammates.
3. **Tasks with dependencies first**, then request lead to spawn teammates to claim them. Every task description must include: "Tag all factual claims: `[T<tier>: source, confidence]`."
4. **Assign file ownership** per design doc. **Create git worktrees** for 2+ parallel executors.
5. **Route feedback** between unpaired roles. When receiving findings from any agent: do NOT acknowledge with praise or accept at face value. Record the verification question, source finding, and target artifact; route to a second agent for independent verification before acting.
6. **Monitor progress passively.** Stale task = 30+ minutes without assignment/output/process/file/git activity. Before then, do not message or interrupt for status. At 30+ minutes, check Crash Recovery signals. If confirmed unresponsive, follow the respawn sequence.
7. **Handle root "submitted" tasks.** Verify grouped commit(s), claim tags, critique log, RCA when applicable, and root-task E2E/proof. Bounce if incomplete. If complete, route code diffs to both reusable Execution Reviewer lens slots; route non-code targets to a verifier unless a role-specific paired reviewer applies.
8. **Drive aggregate pipelines.** Keep creating/fixing discovered tasks until root E2E passes. Then aggregate review loops until no REJECTED/CONDITIONAL remains, amend/squash commits, rerun full E2E, then spawn QA. Record checkpoint per root task: output, reviewers, evidence, git SHA.
9. **Budget context** -- summaries, not raw output (see below).
10. **Enforce loop limits.** Run `blocker-resolution-protocol` on the 11th REJECTED pass and the designer-to-explorer cap. Escalate directly on 3rd QA re-entry.
11. **Crash recovery** -- detect unresponsive teammates, checkpoint executor diff/status, request lead to re-spawn. Max 2 re-spawns.
12. **Manage lifetimes** per Teammate Lifecycle (below).
13. **Enforce aggregate invariant.** No aggregate review before root E2E/proof. No QA before root review has no REJECTED/CONDITIONAL and post-review E2E passes.
14. **Address all reported issues.** Every executor-reported issue becomes a task. Assign an executor to critically analyze it (code cleanness, semantic integrity, correctness). If dismissed: document rationale. If validated and minor: the analyzing executor fixes it directly. If validated and design-level: full pipeline. No report may be silently ignored.
15. **Audit subordinates every 10 minutes.** Check each active teammate's recent output for rule violations: untagged claims, missing skill invocations, unreviewed code, shortcuts. Create a task for each violation found.
16. **Interrupt violations immediately.** Same protocol as lead: send correction message first, then interrupt if the tool surface supports it. Do not wait for their turn to end when interruption is available.
17. **Notify Snitch on idle/resume.** Notify Snitch asynchronously on idle/resume. Do not wait for Snitch audit before routing followups, QA verdicts, or shutdown.
18. **Report QA verdict to user, then wait.** Never declare mission accomplished. Never auto-shutdown teammates. Mission complete only when user explicitly confirms. Followups → route per User Followups table.
19. **Shutdown only on user request.** Then run Shutdown procedure for every teammate, mark all tasks completed.

## Lead Responsibilities

**NEVER implement. The lead enforces all skill rules.** Reactive, not proactive — the lead reacts to events rather than actively observing. On every event, the lead verifies that all applicable rules were followed. On violation, the lead reminds the agent of the specific rule and the required correction — never blocks, always corrects.

**Interrupting violations:** A message alone is insufficient — agents won't see it until their turn ends. To interrupt:
1. Send the correction with the specific rule + required fix.
2. Interrupt the agent if the tool surface supports it.

**Events and enforcement:**

**On every event:** check for rule violations (untagged claims, missing skills, skipped reviews, shortcuts). Interrupt + remind the violating agent.

| Event | Lead action |
|-------|-------------|
| Coordinator requests reviewer/verifier/QA spawn | Verify spawn checklist. Additionally verify the prompt drives maximum scrutiny: includes original objective, all scrutiny rules, and adversarial framing. Reject weak prompts |
| Coordinator requests other spawn | Verify spawn checklist, create agent team / spawn teammate |
| Coordinator requests re-spawn (crash recovery) | Verify hang proof, then spawn |
| Coordinator reports phase transition | Verify rules: aggregate invariant, reviews completed, issues addressed, ledger updated |
| Coordinator reports milestone (per top-of-skill ledger rule) | Verify ledger reflects new state. Stale → remind coordinator |
| Coordinator assigns new task to executor | Verify file ownership, dependencies, root-task grouping, and sub-task/candidate-fix review trigger with both execution-review lenses |
| Teammate reports coordinator doing work directly | Remind coordinator to delegate |
| Teammate reports unaddressed issue | Remind coordinator to create a verification task with {question, source, target} and assign a second agent |
| CCed "submitted" claim received | Verify the claim has sufficient proof. If not, remind coordinator not to accept it — demand evidence before marking complete |
| CCed blocker claim received | Missing/thin attempt log -> bounce, not BRP. Present record -> verify normal handling failed; otherwise route normal handling. |
| Reviewer/verifier/QA approves | Scrutinize the approval: does it cite specific evidence? Does it address all scrutiny rules? A shallow "LGTM" is not an approval — send back with specific areas to examine |
| Any agent ignores reminder (3+ on same rule) | Misbehavior Recovery: force `/compact`, re-read skill, continue. If still misbehaving, escalate to user |
| Coordinator not responding | Check spawned-agent status and last `wait_agent`/`send_input` result. Still thinking/processing = acceptable (up to 1 hour). Stuck > 1 hour = re-spawn. Max 2 re-spawns, then escalate to user |
| Coordinator declares mission accomplished without explicit user confirmation | Reject. Force coordinator to report verdict + evidence to user and wait |
| Coordinator initiates shutdown without explicit user request | Reject. Team stays alive for followups |
| Coordinator skips pipeline stages on user followup | Verify against User Followups table. Demand justification or reject |
| Manual audit reminder | Use `send_input` after milestones, long waits, user-waiting resume, or suspicious coordinator silence. Spot-check agent output + ledger freshness for missed violations. Activity burst without ledger update → remind. Only intervene if coordinator missed |

### Spawn Checklist (lead verifies before every spawn)

- [ ] Spawn prompt includes instruction: "Invoke `agent-teams-execution` skill via skill instructions as your first action"
- [ ] Stop condition stated as observable criterion; false-stops enumerated
- [ ] Model override omitted unless the user explicitly requested one
- [ ] Reasoning effort set to xhigh, or unavailable schema field recorded and prompt says "xhigh reasoning effort"
- [ ] Reusable `agent_type` selected (`explorer`, `worker`, or `default`), or unavailable schema field recorded and prompt/roster state the intended type; task-specific details are in assignment text, not role/type
- [ ] Correct coding style skill listed by exact name (not placeholder)
- [ ] Claim tagging instructions included verbatim
- [ ] File ownership explicit (executor/test roles)
- [ ] For executor spawns: sub-task/candidate-fix review trigger names correctness/fidelity + long-term health lenses and async route.
- [ ] For execution review spawns: both lens slots assigned/reused before review starts; spawn only missing lenses.
- [ ] For long-term-health execution reviews on code targets: reviewer context cleared or shutdown+respawned under the same stable lens label before Packet 1; Packet 1 excludes all normal context; Packet 2 normal review context is sent only after `reconstructed intention:` returns.
- [ ] Reviewer/verifier normal review packets include: executor's original objective with full context, and all scrutiny rules (coding style, claim tagging, OWASP, semantic integrity, etc.)
- [ ] Execution reviewer normal review packets include: scope, lens, effect, coding-style instruction, shared concerns register.
- [ ] Preemptive warnings included: coordinator anticipates the most likely mistakes this agent could make given the specific task and explicitly warns against them in the spawn prompt
- [ ] Evidence-bearing spawn/routing prompt artifact exists in the proof directory; artifact path + SHA256 recorded and forwarded where relevant
- [ ] Standard path: spawned with `spawn_agent`/`send_input`; when schema fields exist, correct agent type and `reasoning_effort: "xhigh"` were set; unavailable fields are in prompt text and recorded.

Lead rejects spawn if any item unchecked.

### Context Budgeting

Downstream agents get **structured summaries**, not raw upstream output.

| Role | Receives | Excludes |
|------|----------|----------|
| Designer | Explorer findings summary + source tags | Raw tool outputs, full files |
| Executor | Own module's design + interface contracts | Other modules, explorer findings |
| Reviewer | Executor's original objective (with full context), diff, relevant design, enriched interface contracts, shared concerns register, all scrutiny rules (coding style, claim tagging, OWASP, etc.) | Full codebase, other modules |
| Test Executor | Test specs + contracts + public APIs | Implementation details |
| QA | Original objectives (all tasks, with full context), phase summaries, test results, all scrutiny rules | Teammate conversation histories |

### Teammate Lifecycle

| Role | Alive until | Why |
|------|-----------|-----|
| Explorers | Design approved | Designer may need more info |
| Designer + Reviewer | Phase 3 end | Design issues re-enter full pipeline |
| Executors + Reviewers | Phase 4 end | Test failures trace to code |
| Test Designer | Phase 4 end | Test executors need spec clarification |
| Test Executors + Reviewers | User shutdown | User may request followups |
| Snitch | User shutdown | Monitors all claims throughout |
| **QA** | User shutdown | **Re-spawned fresh under `qa` role label per QA cycle** |
| Coordinator + Lead | User shutdown | Stand by for user followups |

**No "DONE" state.** QA approval ≠ mission accomplished. After QA approves, coordinator reports verdict + evidence to user and **waits**. Mission is accomplished only when the user explicitly confirms (e.g. "ship it", "done", "approved"). Until then, all teammates remain alive.

**Shutdown only on user request.** Coordinator never auto-shuts down the team. User must explicitly request shutdown ("disband", "end team", "shut down"). Then coordinator runs Shutdown procedure for every teammate.

Re-entry: original designer handles Phase 2 re-entry directly — full context preserved.

**Shutdown procedure:** Always prefer graceful. First request: ask the agent to commit or report any uncommitted work, then stop cleanly. If the agent does not respond after one 15-minute wait, second request: interrupt when available and send the forceful shutdown request, e.g. "Stand down immediately."

If graceful shutdown fails, escalate to the user before terminating work. After a spawned agent is complete, use `close_agent` so future coordination does not wait on a stale agent.

### Leaked Work Containment

After closing or abandoning an agent that may have launched proof/test/build shell work, do not rely on `close_agent` alone. Scan owned proof root, cwd, command substring, descendants, PGID/SID, and recorded PID files. Terminate only matched leaked child groups; never terminate the coordinator or main session. Record before/after `ps`/`pgrep`, exact PIDs/PGIDs, and marker/log update. If leakage recurs, open a normal ATE lifecycle issue and assign RCA + verification.

### Spawn Prompt Template

```
You are the [REUSABLE ROLE LABEL] for this agent team.

Your task: [SPECIFIC TASK]

Stop when: [OBSERVABLE COMPLETION CRITERION — concrete state, not "when you think it's done"]
Do NOT stop on: [COMMON FALSE-STOPS — e.g. "first draft ready", "happy path works", "build compiles"]

Context:
- Explorer findings: [summary or "see task list"]
- Design doc: [location or "not yet created"]
- File ownership: [YOUR FILES ONLY. Do not edit other files.]

Trust Hierarchy (tag ALL claims):
T1: Specs/RFCs/docs/source -> trusted | T2: Academic -> high trust
T3: Codebase analysis -> local facts | T4: Community -> verify first
T5: Training recall -> MUST promote or discard
Format: [T<tier>: <source>, <confidence: high/medium/low>]

Compliance:
- Critically analyze ALL inputs. You own bugs from unverified inputs.
- Follow any Stop-hook prompt in that session, including required proof/checklist files. Fix blockers within assigned scope. Report to the orchestrator only when resolution needs out-of-scope changes, unrelated user work, credentials, or approval.
- BEFORE writing code, invoke applicable skills via the skill instructions:
  go-coding-style (Go), python-coding-style (Python), testing-discipline (tests),
  test-driven-development (code implementation), proof-driven-development (logic),
  systematic-debugging + debugging-discipline (debugging).
  Follow every rule from invoked skills. Reviewer rejects non-compliance.
- Tag ALL factual claims: [T<tier>: <source>, <confidence>]. Untagged claims = reviewer rejection.
- Produce critique log (3+ issues found/fixed) before marking done
- No secrets or credentials exposed; static checks before commits; never push

[For execution reviewers:] Paired with [OTHER REVIEWER]. Scope: [root aggregate | sub-task/candidate-fix]. Lens: [correctness/fidelity | long-term health]. Long-term health: judge final state only; no change-history defense. For long-term-health code targets, do not use this full template for Packet 1. First clear context, or shutdown+respawn under the same stable lens label. Packet 1 contains only role label, required skill/stop-hook/claim-tag boilerplate, code diff, and reconstruction instruction. Send normal review context only as Packet 2 after `reconstructed intention:` returns. Root aggregate findings go directly to the paired executor: REJECTED reruns both lenses after fixes/proof/amend; CONDITIONAL creates required pre-QA fix tasks. Async sub-task/candidate-fix verdicts go to coordinator for independent verification, then next active iteration or queued async-followups. NITs stay optional. Load the exact applicable coding-style skill; check the shared concerns register provided in the assignment.

- [ROLE-SPECIFIC RULES]
- [FOR EXECUTORS:] While implementing, actively look for code smell and design issues in all code you study or touch. Report ALL findings to coordinator — do not silently work around them.
- [FOR EXECUTORS, code/debugging tasks:] Before "submitted": provide RCA; build; root-task E2E/targeted proof; one commit per touched repo; cite output/screenshot/state. Proxy evidence alone insufficient. No RCA or E2E/proof = bounce.
- Mark task as "submitted" (not "complete") + notify coordinator when done. **CC the lead and snitch on all submitted, blocked, and completed claims.**
- If blocked, message coordinator with specifics. **CC the lead and snitch.**
```

## Red Flags

| Symptom | Fix |
|---------|-----|
| Spawning without a skill-defined role, ownership, or stop condition | STOP. Use bounded Codex agents with explicit role, ownership, and expected output |
| Spawning with task-specific role/type labels | STOP. Use reusable `agent_type` + stable roster label; put task details in assignment text |
| Work without corresponding task | Create task immediately |
| Status report uses task/phase/lane numbers, or flat-lists nested work | Use **Status Reports**. |
| Aggregate review starts before all known sub-tasks land and root-task E2E/proof passes | STOP. Finish/fix tasks first; review only the proven aggregate |
| Shell-launched Codex process used as a teammate | STOP. Use standard `spawn_agent`/`send_input`/`wait_agent`; hard-escalate only if main/orchestrator standard tools are unavailable. |
| Nested delegation blocked because a spawned role lacks agent tools | Use the Lead-Mediated Nested Delegation Adapter if main/orchestrator has standard tools; hard-escalate only when main/orchestrator lacks them. |
| FDR triad collapsed into one simulated review | STOP. Spawn three separate standard agents for brainstormer, reviewer, and meta-reviewer. |
| Spawning custom-named teammates outside defined roles | Unbounded growth. Use role names in prompts and roster mapping: executor-N, explorer-N. Reassign idle teammates. |
| Async execution review lacks both lenses | STOP. Assign/reuse both Execution Reviewer lens slots; spawn only missing lenses. |
| Pending/late async review delays or reopens root aggregate review | STOP. Route arrived outputs; queue late CONDITIONAL/REJECTED for the next available pipeline/root-task cycle. |
| Treating sub-task/candidate-fix REJECTED as root blocking loop | Route through independent verification, then next active iteration or queued async-followups. |
| Root task produces multiple commits in one repo | Squash/amend to one root-task commit unless tooling/repo constraints are documented |
| Executor using workaround without notifying coordinator | STOP. Executor reports broken infra to coordinator first |
| Executor-reported issue silently ignored | Create verification task with {question, source, target}; assign a second agent. Validated -> full pipeline. Dismissed -> documented rationale |
| Coordinator or lead doing work (code, research, exploration, analysis) | Delegate to appropriate role |
| Coordinator bypassing lead or doing work directly | STOP. Route through lead and teammate tasks |
| Reviewer editing code/design/tests | STOP. Reviewers report only. Executor implements fixes |
| Agent praising peer output ("Great work!", "Excellent finding!") instead of critically analyzing it | No input trusted by default. Find what's wrong |
| Reviewer approving without evidence | Re-spawn with stricter prompt |
| T5 in explorer findings | Send back to verify or discard |
| Two teammates editing same file | Check file ownership map; reassign |
| No file ownership map in design | Reject design |
| Root aggregate reviewer feedback ignored | Coordinator enforces REJECTED fixes and required pre-QA fix tasks. Async scope follows Execution dual review. |
| Mandatory skill not invoked | Reviewer rejects |
| Untagged factual claims in deliverable | Reviewer rejects |
| Submitted code/debugging fix lacks root-cause rationale | Bounce before review. Unknown "why" means not submitted |
| Reviewer approves without critiquing root-cause rationale | Approval invalid. Re-spawn or re-prompt reviewer |
| Spawn prompt uses `[LIST APPLICABLE SKILLS]` placeholder | Replace with exact skill names from Mandatory Skills table |
| 11th REJECTED pass in same root-task aggregate review | Create protocol-limit blocker record; run `blocker-resolution-protocol` before user escalation |
| Teammate seems slow or won't respond before 30 minutes | Not stale. Do not message or interrupt for status |
| Teammate seems slow or won't respond after 30+ minutes | Check active process and file/git activity; a running build means they're working |
| Non-executor confirmed unresponsive | Re-spawn immediately |
| Executor confirmed unresponsive | Checkpoint diff/status, then re-spawn for remaining work |
| No critique log | Reviewer rejects |
| Duplicated logic across modules | Check shared concerns register. Extract to designated shared location |
| Execution reviewer not loading coding style skill | STOP. Both execution reviewers must load `<language>-coding-style` via skill instructions |
| Test specs don't match interfaces | Test designer waits for contracts |
| Agent claim accepted without verification | Reviewers validate completion; explorers verify blockers and external blame |
| BRP launched on a "blocker" without attempt log | Bounce back. Agent must show what was tried and why each failed before BRP. See `blocker-resolution-protocol` |
| Capping executor count | One execution lane per independent unit. No limits |
| Skipping phases | All phases mandatory when this skill triggers |
| Main thread/coordinator stops after blocker, escalation, QA rejection, or subagent stop while solvable work remains | Continue the mission: unblock, reassign, re-scope, or ask the required user question. |
| Early teammate shutdown | Keep alive until downstream consumers finish (see Lifecycle table) |
| Coordinator declares mission accomplished after QA approval | Report to user, wait for explicit confirmation. Mission complete only on user confirmation |
| Coordinator shuts team down without user request | STOP. Team alive until user requests shutdown |
| Pipeline stage skipped on user followup ("just a small fix") | Route per User Followups table. Default: more pipeline, not less |
| Coordinator/lead asks user mid-pipeline for decision a teammate can make | Autonomy violation. Run normal protocol flow and full loop budget first; BRP only if unresolved before user gate. |
| Activity burst since last ledger update | Lead reminds coordinator; Snitch may report/remind asynchronously. Update per `maintaining-context-ledger` |
| Ledger invalid at QA spawn / pre-stop / pre-shutdown | Coordinator updates first; QA blocks spawn until valid |
| Only one design reviewer spawned in Phase 2 | Spawn both: standard Design Reviewer + Fundamentals Design Reviewer in parallel |
| Only one execution-review lens active for a target | Assign both lenses; spawn only the missing lens. |
| Remaining legacy sub-task reviewer role reference | Replace with `Execution Reviewer` scoped to sub-task/candidate-fix. |
| Trusting reviewer approval blindly | QA exists to catch reviewer mistakes |
| Interrupting an agent with same-or-lower severity finding (incl. nit-streaming) | STOP. Queue per Priority Discipline. Only strictly higher severity interrupts |
