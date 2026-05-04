---
name: explore-critique-implement
description: Use when solving any non-trivial problem where the solution space is uncertain — research options via a persistent explorer teammate, adversarially critique them via separately-spawned critic teammates, then loop (implement → critique) until the critic finds nothing. Skip only for single-line or trivial changes.
---

# Explore-Critique-Implement

Separate the hand that builds from the hand that tears down. The builder cannot credibly critique its own output.

## Execution Rules

- Use `spawn_agent` only when the user explicitly requested subagents, delegation, parallel agent work, or dedicated agents.
- Use `explorer` agents for research/critique and `worker` agents for implementation.
- Launch every spawned agent with `reasoning_effort: "xhigh"`.
- When ECI is invoked, the orchestrator engages `~/.codex/bin/eci-active on "<task + scope>"` before Step 1 and keeps it active until teardown.
- Use standard agent management tools only. Do not launch Codex agents through shell wrappers or separate CLI processes.
- If delegation is not authorized or standard agent tools are unavailable, run the explore, critique, and implementation phases locally with separate written artifacts for each role. If the user explicitly required dedicated agents and standard agent tools are unavailable, hard-escalate instead of substituting local artifacts.
- When delegation/agents are authorized, Step 2 critic, Critic A, Critic B, brainstormer, loop-breaker, and verifier/E2E roles must be dedicated spawned agents, never main-thread persona critique.

## When to use

| Use | Skip |
|-----|------|
| Solution space uncertain | Single-line change |
| 2+ plausible approaches | Trivial typo or reformat |
| Correctness is load-bearing | Throwaway experiment |
| Research would reduce uncertainty | Mechanical rename |

## Prerequisites

Coding task? Every subagent prompt (explorer, critic, implementer) must include: "Before starting, load the `<language>-coding-style` skill and follow its rules."

## Engagement marker

The PreToolUse gate `~/.codex/hooks/eci-active-gate.sh` denies direct Edit/Write/MultiEdit on the main thread while engaged. When delegation/agents are authorized, every code change must flow through a spawned agent. The hook must exempt spawned-agent metadata; if spawned agents trip the gate, fix the hook instead of using shell-env role workarounds.

| Step | Command | When |
|------|---------|------|
| Engage | `~/.codex/bin/eci-active on "<task + scope>"` | Before Step 1 of the first iteration |
| Disengage | See Teardown sequence below | Clean pass landed, hard escalate, or user confirms scope closed |

Do not disengage mid-task to escape the gate. When delegation/agents are authorized, every code change flows through a subagent or teammate. If no-delegation fallback cannot proceed with the marker active, hard-escalate instead of removing the marker.

## Team setup

Reuse an existing spawned agent with `send_input` when the role needs continuity and delegation is authorized. Otherwise, spawn a bounded `explorer` or `worker` for the role. If standard agent tools are unavailable, use the local-artifact fallback and label critic artifacts `no-delegation fallback`; do not use local fallback when the user explicitly required dedicated agents.

Persistent role instances handle Step 1 (explorer) and Step 3 (implementer) across iterations when the environment supports reuse. Critic/verifier work (Step 2 critic, Critic A, Critic B, brainstormer, loop-breaker, verifier/E2E) must still be separate from the explorer and implementer. The producer must never act as critic.

**"Persistent" != "carries cross-iteration context".** The role prompt baseline requires fresh-assignment treatment each message (re-read referenced files, no prior-turn trust). Reuse role continuity when useful, but require fresh file reads every assignment. The producer-vs-critic split is about agent identity for adversarial separation, not context staleness.

**Critic identity rule.** Step 2 critic, Critic A, Critic B, brainstormer, loop-breaker, and verifier/E2E use separate role instances from producer roles. Adversarial separation = identity rule (critic != producer). When delegation/agents are authorized, those roles must be dedicated spawned agents, never main-thread persona critique. Bias-freedom between rounds/invocations is achieved by clearing context when reuse is available or spawning a new bounded reviewer. Do not rely on prior context carrying over.

### Spawning

| Action | Command |
|--------|---------|
| Spawn explorer | `spawn_agent` with `agent_type: "explorer"`, `reasoning_effort: "xhigh"` |
| Spawn implementer | `spawn_agent` with `agent_type: "worker"`, `reasoning_effort: "xhigh"`, and explicit file/module ownership |
| Spawn Step 2 critic | `spawn_agent` with `agent_type: "explorer"` or `default`; prompt as `critic-r<N>` |
| Spawn Step 4 critic-A / critic-B | parallel `spawn_agent` calls with separate critic prompts |
| Spawn E2E agent | `spawn_agent` with `agent_type: "worker"` or `default` for verification |
| Spawn brainstormer | `spawn_agent` with `agent_type: "explorer"` |
| Spawn loop-breaker | `spawn_agent` with `agent_type: "explorer"` |

Every spawned agent prompt states the role name, original user requirements, exact scope, expected output, and that other agents may be editing in parallel.

### Explorer Prompt Baseline

Per-message body in Step 1.
- Role name per Spawning table.
- "Treat each new task message as a fresh assignment per Step 1 of the ECI skill. Re-read every referenced file each turn — do not trust prior-turn reads."

### Implementer Prompt Baseline

Per-message body in Step 3.
- Role name per Spawning table.
- "Treat each new task message as a fresh assignment per Step 3 of the ECI skill. Re-read every file you intend to modify each turn."
- One commit per logical change.
- Every factual claim in submission carries a T1-T5 tag per CODEX.md Claim Verification protocol. E2E evidence ("tests pass", "build succeeded", screenshots, observed state) cited as T1 with tool output, log path, or screenshot file. Concrete example: "[T1: `go test ./...` exit 0, all 47 pass]" not bare "tests pass". Untagged "all green" = unsubmittable.

## Teardown sequence

Run in this exact order on disengage. Stopping mid-sequence keeps the gate armed.

1. Write disengage-report markdown (content per **Disengage report** below).
2. Ask active spawned agents to commit or report uncommitted work, then stop cleanly. If they do not respond after one 15-minute wait, send the forceful shutdown request on the second iteration.
3. Close completed agents with `close_agent`.
4. `~/.codex/bin/eci-active off <report.md>` (LAST — keeps gate armed if teardown fails partway).

If the orchestrator's next Stop blocks for proof, copy the disengage report to `$PROOF_DIR/proof.md`.

### Disengage report

`~/.codex/bin/eci-active off` requires a markdown report walking the stop checklist (`~/.codex/hooks/stop-checklist.md`) and critically analyzing items that could not be fully complied with during the ECI scope. Required sections:

```
## ECI completion certificate
<exactly one of: clean-pass: <evidence> | hard-escalation: <evidence> | user-closed: <evidence>>

## Stop checklist walkthrough
- Questions: pass/fail/N-A — <one-line evidence>
- Git: pass/fail/N-A — <one-line evidence>
- Completion: pass/fail/N-A — <one-line evidence>
- Root cause: ...
- Adversarial self-critique: ...
- Assumed blockers: ...
- Rule-compliance self-audit: ...
- Testing: ...

## Incomplete compliance
- <item> — could not fully comply because <reason>; impact: <what slipped>
- ...
fully-compliant: <reason rule-by-rule>   # only if no incomplete items
```

The bin rejects reports missing `## Stop checklist walkthrough`, `## Incomplete compliance`, non-empty bodies, and exactly one terminal verdict marker: `clean-pass:`, `hard-escalation:`, or `user-closed:`. Include either all full Codex stop-proof sections or `## ECI completion certificate`. Validation is a content gate, not a wordcount — write substance, not boilerplate.

## Loop structure

Each iteration tackles one change. All four steps run per iteration. Do not advance to next change until current one passes all steps.

| Step | Phase | Actor | Output |
|------|-------|-------|--------|
| 1 | Explore | `explorer` role | Ranked options + cited sources |
| 2 | Critique explorations | Separate critic role per round | Winner with concrete text + tagged CONDITIONAL/NIT list (one explorer revision round permitted on all-REJECT) |
| 3 | Implement | `implementer` role | One diff |
| 4 | Review gate (parallel) | Critic A + Critic B + E2E roles in parallel | All three run concurrently; wait for all |
| Exit | Main thread | Apply / commit / report |

Agent separation: see Red Flags. Main thread orchestrates; agents produce.

**No mid-work polling.** After assigning a role, wait for completion with `wait_agent` using `timeout_ms: 900000` (15 minutes). Do not use shorter polling or describe waits as "short polls". Do not `send_input` status/checkpoint/report requests while the agent is in progress. A role is not stale until 30+ minutes pass with no assignment/output/process/file/git activity. Before then, inspect passively only. Interrupt only for explicit user stop, destructive/wrong-scope action, wrong worktree, policy/security violation, or 30+ minute confirmed no-progress stall.

## Step 1: Explore

Send the assignment to the `explorer` role. Each message/prompt must include:
- The problem/change for THIS iteration, in full context.
- What's already been tried or ruled out (iterations 2+: include results from prior iterations, current codebase state, and last blocking gate issues verbatim if a prior cycle's gate failed).
- Exact file paths of existing related code — explorer must re-read them this turn to avoid suggesting duplicates. "Re-read referenced files; do not trust prior turn reads."
- Required output: ranked options, each with {what, why, where it applies, cost, tradeoffs}.
- Every factual claim in the report must carry a T1-T5 tag per CODEX.md Claim Verification protocol. Primary sources only for T1. Untagged factual claims are not allowed.
- Word cap on the report (default: 1000 words).

## Step 2: Critique explorations

When delegation/agents are authorized, use a dedicated critic `spawn_agent` — not the explorer, not the implementer, not the main thread. Local artifact critique is allowed only in no-delegation fallback and must be labeled `no-delegation fallback`. Each new round starts with clean context. Do not reuse the explorer or implementer for critic work.

The critic's prompt must include:
- **Original user requirements verbatim.** The critic must verify options against what the user actually asked for, not just technical soundness.
- **"Step 0 — Independent baseline."** Read the source material (target file, existing code, prior art) and write your own 3-5 bullet assessment BEFORE opening the explorer's report. Include this baseline in the critique output.
- "Assume every suggestion is wrong until you prove otherwise."
- "Read the current state first" (the file/code/doc the explorer was working on) — verify duplication claims independently.
- **Cite-verify and tag-discipline protocol:**
  - Untagged factual claim from explorer = REJECT-tagged issue on the option that depends on it.
  - Fetch every T1/T2 URL via WebFetch; use Read for source-code citations.
  - Unfetchable URL (auth-gated, internal, tool unavailable) → flag "unverified — could not fetch" + state whether dependent claim is load-bearing.
  - Load-bearing = any citation justifying picking an option as winner, or justifying a REJECT verdict that bounces an option to the explorer. Load-bearing + unfetchable = issue.
  - Quote the exact supporting passage. Flag hallucinated URLs, misquotes, and training-recall mislabeled as T1.
  - Non-load-bearing citations may be skipped if explicitly marked "non-load-bearing: no verdict depends on this source."
  - T3/T4: sample, not exhaustive.
- Per-issue severity code (table below). Issues attach to specific options. Aggregate per-option verdict = strongest severity.
- **DUPLICATE-of-#N marker** (orthogonal to severity): set when one option restates another option's substance.
- **If at least one option has zero REJECTs**: pick winner from that set with CONCRETE TEXT. Output winner + that option's CONDITIONAL fix-text list (verbatim) + NITs (informational).
- **If every option has REJECTs**: do not pick. Return REJECT issues verbatim to orchestrator for bounce per Loop-logic table.
- Single-option explorations get the same adversarial treatment.
- "Be harsh. Most suggestions are noise. Zero survivors is a valid outcome."
- Each retry round spawns a fresh-identity critic (parallels Red Flag agent-identity rule).

### Step 2 severity codes

| Code | Meaning | Effect on the option |
|------|---------|----------------------|
| **REJECT** | Option is wrong-shaped: violates user requirements, rests on unsound assumption, lacks a critical capability, or is unfixable without re-exploration | Option cannot be the winner. If ALL options have ≥1 REJECT, see Loop-logic. |
| **CONDITIONAL** | Option is sound; needs a specific tweak the critic spells out as one-or-two lines of fix-text | Option remains viable. Orchestrator folds the fix-text into Step 3 (see below). |
| **NIT** | Soft preference; doesn't affect viability | May be ignored when picking the winner |

Same vocabulary as Step 4; Effect column differs because receiver/artifact/remediation differ per phase.

### Step 2 loop-logic

| Critic verdict pattern | Action | Output |
|---|---|---|
| ≥1 option with zero REJECTs | Pick highest-ranked clean option as winner | Winner + that option's CONDITIONAL fix-text list + NITs |
| Every option has ≥1 REJECT, round 1 | Bounce verbatim REJECT reasons to explorer; explorer revises; spawn fresh-identity critic for round 2 | Bounce-back |
| Every option has ≥1 REJECT, round 2 | Trigger brainstormer per Brainstormer trigger row; new explorer round | Escalation per Escalation table |
| Only NITs across all options | Pick highest-ranked option directly | Winner + NITs |

**Critic emits issues only.** CONDITIONAL absorption happens at the orchestrator's hand-off to Step 3 — orchestrator folds the winner's CONDITIONAL fix-text into the Step 3 implementer assignment. The critic does NOT rewrite options.

## Step 3: Implement

Send the assignment to the `implementer` role. One change, one diff per message. Code tasks: implementer invokes `test-driven-development`, `debugging-discipline` when debugging, and the applicable `<language>-coding-style` skill on each new task message; re-reads every file it intends to modify.

Each new task message to `implementer` includes:
- The current iteration's concrete-text from the Step 2 critic (verbatim).
- Iterations 2+: prior iteration's gate findings (verbatim) and files changed since the last message.
- Step 2 CONDITIONAL fix-list (verbatim, if any) — implementer applies these alongside the concrete text.
- Submission tags every factual claim. Untagged claim → orchestrator bounces back without spawning the gate (parallel to E2E-evidence rule).

**E2E before submit (code/debugging tasks).** Implementer must, before reporting done: build, run full test suite, exercise the affected feature through real UI/API as a user. Cite direct evidence (output, screenshot, observed state). Proxy evidence (unit tests, lint) insufficient. No E2E evidence in submission = orchestrator bounces back without spawning the gate.

If submission lacks E2E evidence, send: "Submission lacks E2E evidence — re-run build, test suite, and user-path exercise; cite output. Do not re-submit until evidence is in the message body."

## Step 4: Review gate (parallel)

Start Critic A, Critic B, and E2E verification in parallel. Each reviewer must be separate from explorer and implementer roles. Wait for all three to complete before evaluating results. Every reviewer prompt must include the **original user requirements verbatim** — reviewers catch requirement deviations, not just technical issues.

### Issue severity codes

Every issue from Critic A and Critic B must carry exactly one code:

| Code | Meaning | Effect |
|------|---------|--------|
| **REJECT** | Would make the change wrong, unsafe, or contradictory | Triggers gate re-run after fix |
| **CONDITIONAL** | Fix needed, but obvious/trivial enough to trust without re-review | Must be fixed; no re-run needed |
| **NIT** | Soft recommendation | May be ignored |

Both critics tag every issue per the severity codes table above. Same vocabulary as Step 2; Effect differs (re-implement vs. re-explore).

### Critic A — correctness

Emit only issues affecting correctness, safety, or fidelity to the concrete text. Interface contract fulfillment — does every interface implementation actually work, not just compile? Polish and taste items are NITs at most.

Tag-discipline audit: every factual claim in the implementer's submission must carry a T1-T5 tag per CODEX.md Claim Verification protocol. Untagged factual claim = REJECT.

### Critic B — long-term health

Different agent from Critic A.

Focus — adversarial, long-term lens:
- **Tech debt**: Coupling, hidden dependencies, or shortcuts costing more to fix later than now?
- **Coding style**: Load the applicable `<language>-coding-style` skill. Does the diff follow naming, error handling, structure, and idiom conventions?
- **Code smells**: God methods, feature envy, primitive obsession, duplicated logic, unclear names, missing/premature abstractions. Flag only smells that materially hurt readability or maintainability.
- **Architectural fit**: Right layer? Respects module boundaries? Code in correct binary/package per its stated purpose?
- **Tag-discipline**: every factual claim in submission carries T1-T5 per CODEX.md Claim Verification. Untagged factual claim = REJECT.

Emit only issues that matter for long-term health. "Would refactor eventually" is not an issue — "will cause bugs or confusion within 3 months" is.

### E2E agent — end-to-end verification

**Code/debugging tasks only.** Skip for non-code tasks (docs, config, design).

1. Build the project. Compilation failure = issue.
2. Run full test suite. Failures = issue.
3. Exercise the affected feature through real UI or API as a user would. Verify observable outcomes (output, screenshots, state). Proxy evidence (unit tests pass, linter clean) alone insufficient — direct evidence required.
4. Confirm no regressions in related features.

### Evaluating results

Collect results from all three agents. Apply severity logic:

- At least one REJECT from Critic A or Critic B, OR any E2E failure → fix all REJECTs, CONDITIONALs, and E2E failures → re-run gate.
- Zero REJECTs but CONDITIONALs exist → fix them → gate passes (no re-run).
- Only NITs → gate passes.

Gate retry and cycle limits defined in Escalation table.

**Clean pass** = zero REJECTs + zero CONDITIONALs + E2E pass, all from the same gate run.

## Brainstormer (unblocker)

Fresh idea generator — fires on-demand when the cycle stalls. Output is raw ideas only; never decisions, verdicts, or filtering. Bigger list = better.

| Trigger | Action |
|---------|--------|
| Explorer returned zero viable options | Spawn brainstormer → feed ideas into a new explorer |
| Step 2 bounce cap reached (one explorer revision round did not yield a clean option) | Spawn brainstormer → feed ideas into a new explorer |
| Implementer dead-end inside Step 3 | Spawn brainstormer → feed ideas into a new implementer prompt |

### Prompt requirements

- Original problem + everything tried so far, verbatim.
- Current code/file paths — brainstormer reads them independently.
- "Generate as many distinct ideas as possible. No filtering, no feasibility judgment, no negatives. Bigger list = better."
- "You are NOT one of the cycle agents. Do not trust prior agent summaries."

### Constraints

- Spawn as a separate brainstormer role; never assign brainstorming to the explorer or implementer.
- Must NOT be any other cycle agent (explorer, Step 2 critic, implementer, Critic A, Critic B, E2E, loop-breaker).
- Each invocation refreshes context via `/clear` or shutdown+respawn — start each idea-burst clean.
- Ideas only — the next cycle agent does the filtering.

## Loop-breaker

A separate teammate — not any of the cycle agents — gets one chance to break the loop before escalating to the user.

**One loop-breaker invocation per change**, regardless of trigger. If the granted retry fails → hard escalate to user.

### Prompt must include

- Original problem statement.
- All cycle attempts: what was tried, what failed, remaining issues verbatim.
- Current code state (file paths — loop-breaker reads them independently).
- "You are a fresh reviewer. Read the code and issues yourself. Do not trust prior agents' assessments."

### Decision — exactly one of

| Decision | Meaning | Effect |
|----------|---------|--------|
| **ACCEPT** | Remaining issues are cosmetic, speculative, or not worth another iteration | Accept current state with reasoning. Gate passes. |
| **RETRY** | Remaining issues are real and fixable | Grant exactly one more attempt (gate retry or full cycle, matching the trigger). Provide specific guidance. |

### Constraints

- Spawn as a separate loop-breaker role; start from clean context for each invocation.
- Must NOT be any of the 6 cycle agents (explorer, Step 2 critic, implementer, Critic A, Critic B, E2E agent).
- Reads code and issues independently — no reliance on prior agent summaries.
- One invocation per change. Granted retry fails → escalate to user.

## Escalation

Single decision table for all limit hits. One loop-breaker per change total.

| Trigger | Condition | Action | If retry fails |
|---------|-----------|--------|----------------|
| Gate retry cap | 3 gate retries failed within one cycle | Invoke loop-breaker (if not yet used for this change) | Hard escalate to user |
| Cycle limit | 3 full cycles failed for one change | Invoke loop-breaker (if not yet used for this change) | Hard escalate to user |
| Loop-breaker already used | Either limit hit but loop-breaker was consumed by prior trigger | Skip loop-breaker → hard escalate to user immediately | — |
| Step 2 post-brainstormer all-REJECT | Brainstormer fired and new explorer's options still all-REJECT after one revision | Hard escalate to user | — |

**Hard escalate** = report to user with: (a) original problem, (b) what each cycle tried, (c) loop-breaker's assessment (if invoked), (d) last blocking issue, (e) next-best alternative from explorer's ranking. Silent punts forbidden.

## Iteration limit

Cycle limit defined in Escalation table (3 full cycles per change).

## Exit conditions

- All changes landed with clean pass, OR
- Loop-breaker ACCEPT → current state accepted with reasoning, OR
- Hard escalate triggered → report to user per Escalation table.

## Status reports

Reports to user use:

| Rule | Example |
|------|---------|
| Human-readable names, not task/iteration numbers | "severity-codes table done", not "task 3 done" / "cycle 2 failed" |
| Tree structure when work decomposes into sub-issues or nested ECI pipelines | Indent children under parent; never flatten |

Issue uncovered mid-iteration that spawns its own ECI pipeline → nest under the iteration that found it.

```
auth middleware swap
├─ severity-codes change: gate passed, committed
├─ E2E uncovered stale-session bug → nested ECI:
│   ├─ session-cache invalidation: 3 options ranked
│   └─ blocked on prod log access
└─ docstring update: pending
```

## Red flags

| Symptom | Fix |
|---------|-----|
| Implementing 2+ changes before re-critiquing | Stop. One at a time |
| "Good enough" at cycle 3 | Invoke loop-breaker, don't settle or force |
| Any two of {explorer, Step 2 critic, implementer, Critic A, Critic B, E2E agent, loop-breaker} are the same agent | Banned. Up to seven distinct agents (six per normal cycle + loop-breaker at limits) |
| Review-gate Critic A returned before Critic B was spawned | Sequential gate. Spawn Critic A + Critic B (+ E2E when in scope) in one message with parallel spawn_agent tool calls; do not serialize even if one critic's view seems sufficient. |
| Skipping E2E inside loop | E2E is part of the review gate — runs every iteration, not at the end |
| Skipping exploration or critique for later iterations | Every iteration runs all four steps — none are optional |
| Winner lacks concrete text | Critic under-specified. Re-spawn with "concrete text required" |
| No rejected list in Step 2 | Critic is not adversarial. Re-spawn |
| Brainstormer output filters/judges/picks a winner | Brainstormer is idea-only. Re-spawn with "no filtering, no negatives" |
| Explorer or implementer role used for any critic-role work (Step 2 critic, Critic A, Critic B, brainstormer, loop-breaker) | STOP. Use a separate critic role; the producer must never act as critic. |
| Disengage without teardown sequence | STOP. Close spawned agents, then run `eci-active off`. |
| Shell-launched Codex process used as a teammate | STOP. Use standard `spawn_agent`/`send_input`/`wait_agent`, or hard-escalate if unavailable. |
| Status report uses task/iteration numbers, or flat-lists nested work | See **Status reports** section. |
| "Fresh context needed" → spawned a separate agent for Step 1 or Step 3 without reason | Reuse role continuity when useful; require fresh file reads every assignment. |
| Critic absorbed CONDITIONALs by rewriting option | STOP. Critic tags only — orchestrator folds CONDITIONALs into Step 3 assignment. |
| Orchestrator forgot to pass Step 2 CONDITIONALs to implementer | STOP. Step 3 message must include verbatim CONDITIONAL fix-list. |
| Submission accepted with untagged factual claims | STOP. Tag-audit failure = REJECT in current gate (per Critic A/B rule). |

## Relationship to other skills

| Skill | Difference |
|-------|-----------|
| `brainstorming` | Explores user intent before design. This skill explores solutions after intent is clear. |
| `agent-teams-execution` | Full multi-role pipeline for large builds. This skill is the medium-task pattern (explore → critique → implement → parallel review gate). Borrow its rubber-stamp check: critic citing zero issues beyond producer's self-reports = re-run critique with a harsher prompt. |
| `systematic-debugging` | For diagnosing a known bug. This skill is for open-ended improvement/design research. |
| `proof-driven-development` | Proves correctness of logic. This skill selects which logic to build. |
