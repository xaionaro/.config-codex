---
name: explore-critique-implement
description: Use when solving any non-trivial problem where the solution space is uncertain — research options via a persistent explorer agent, adversarially critique them via separately-spawned critic agents, then loop (implement → critique) until the critic finds nothing. Skip only for single-line or trivial changes.
---

# Explore-Critique-Implement

Separate the hand that builds from the hand that tears down. The builder cannot credibly critique its own output.

## When to use

| Use | Skip |
|-----|------|
| Solution space uncertain | Single-line change |
| 2+ plausible approaches | Trivial typo or reformat |
| Correctness is load-bearing | Throwaway experiment |
| Research would reduce uncertainty | Mechanical rename |

Maintain a project-understanding ledger for every ECI run. Use the `maintaining-context-ledger` skill for storage path, content schema, update timing, and validity rules.

## Codex adapter

- A user request to "use ECI" or `explore-critique-implement` authorizes this skill's required spawned agents.
- Automatic skill routing may load this file for uncertain work, but loading alone is not ECI invocation. Do not claim ECI is active without explicit ECI or agent authorization.
- Claude `TeamCreate` / named Agent / `SendMessage` / `TeamDelete` maps to Codex `spawn_agent` / `send_input` / `wait_agent` / `close_agent`.
- Codex ECI uses standard agent management tools only. Do not launch shell-wrapped Codex agents. If `spawn_agent` or related agent tools are unavailable, ECI cannot run; hard-escalate to the user.

## Prerequisites

Coding task? Every subagent prompt (explorer, critic, implementer) must include: "Before starting, load the `<language>-coding-style` skill and follow its rules."

## Engagement marker

The PreToolUse gate `~/.codex/hooks/eci-active-gate.sh` denies direct Edit/Write/MultiEdit on the main thread while engaged. Every code change must flow through a spawned agent. Spawned agents write from their own session; the marker is keyed to the orchestrator's session and must not block them.

| Step | Command | When |
|------|---------|------|
| Engage | `~/.codex/bin/eci-active on "<task + scope>"` | Before Step 1 of the first iteration |
| Disengage | See Teardown sequence below | Clean pass landed or user confirms scope closed |
| Hard escalate | Report blocker requiring user input; marker stays active | ECI cannot proceed without user input |

Do not disengage mid-task to escape the gate — that is the regression this marker exists to catch. If a hand-edit feels necessary, send the work to the persistent `implementer` agent.

## Team setup

**Persistent agent** = spawned once with `spawn_agent`, then reused with `send_input`. **One-shot agent** = spawned for one bounded assignment, then closed. ECI uses persistent agents for every cycle role when reuse is available.

Persistent agents handle Step 1 (explorer) and Step 3 (implementer) across iterations. Critic-role work (Step 2 critic, Critic A, Critic B, brainstormer, loop-breaker) is also done by persistent agents — not the explorer or implementer, but separately-spawned critic agents with their own identity. E2E agent is also a persistent agent. The producer (explorer/implementer) must never act as critic.

**"Persistent" != "carries cross-iteration context".** The persistent agent's spawn-prompt baseline already forces fresh-assignment treatment each message (re-read referenced files, no prior-turn trust). Spawning a new agent for Step 1 or Step 3 because "fresh context is needed" defeats the persistent role — `send_input` to the existing agent already gives that. The producer-vs-critic split is about *agent identity for adversarial separation* (critic must not be the producer), not about context staleness.

**Critic identity rule.** Step 2 critic, Critic A, Critic B, brainstormer, and loop-breaker are spawned as separate agents with a unique role-name (`critic-r<N>`, `critic-A`, `critic-B`, `brainstormer`, `loop-breaker`). Adversarial separation = identity rule (critic != producer). Bias-freedom between rounds/invocations is achieved by clearing context when reuse is available or shutting down and respawning under the same role name. Do not rely on persistent-context "carrying over" — each round must start clean.

Codex does not use `CLAUDE_ROLE`, `TeamCreate`, `team_name`, or independent tmux/CLI agents for ECI. Role identity is carried in the spawn prompt, roster label, and subsequent `send_input` messages.

### Spawning

| Action | Command |
|--------|---------|
| Spawn explorer | `spawn_agent` with `agent_type: "explorer"` and role label `explorer` |
| Spawn implementer | `spawn_agent` with `agent_type: "worker"`, role label `implementer`, and explicit file/module ownership |
| Spawn Step 2 critic | `spawn_agent` with `agent_type: "explorer"` or `default`; role label `critic-r<N>` |
| Spawn Step 4 critic-A / critic-B | Parallel `spawn_agent` calls with role labels `critic-A` / `critic-B` |
| Spawn E2E agent | `spawn_agent` with `agent_type: "worker"` or `default`; role label `e2e-<gate-N>` |
| Spawn brainstormer | `spawn_agent` with `agent_type: "explorer"` and role label `brainstormer` |
| Spawn loop-breaker | `spawn_agent` with `agent_type: "explorer"` and role label `loop-breaker` |

Every spawned agent prompt states the role name, original user requirements, exact scope, expected output, and that other agents may be editing in parallel.
Every spawned ECI agent prompt must also state: "Follow any Stop-hook prompt in that session, including required proof/checklist files. Fix blockers within assigned scope. Report to the orchestrator only when recovery needs out-of-scope changes, unrelated user work, credentials, or approval."

### Explorer spawn-prompt baseline

Per-message body in Step 1.
- Role label per Spawning table.
- "Treat each new task message as a fresh assignment per Step 1 of the ECI skill. Re-read every referenced file each turn — do not trust prior-turn reads."

### Implementer spawn-prompt baseline

Per-message body in Step 3.
- Role label per Spawning table.
- "Treat each new task message as a fresh assignment per Step 3 of the ECI skill. Re-read every file you intend to modify each turn."
- One commit per logical change.
- Code/debugging submissions include root-cause rationale: cause chain, evidence, and why the diff repairs the cause. Unknown "why" = unsubmittable.
- Every factual claim in submission carries a T1-T5 tag per CODEX.md Claim Verification protocol. E2E evidence ("tests pass", "build succeeded", screenshots, observed state) cited as T1 with tool output, log path, or screenshot file. Concrete example: "[T1: `go test ./...` exit 0, all 47 pass]" not bare "tests pass". Untagged "all green" = unsubmittable.

## Teardown sequence

Run in this exact order on disengage. Stopping mid-sequence keeps the gate armed.

1. Write disengage-report markdown (content per **Disengage report** below).
2. `send_input` `commit any uncommitted work and confirm clean tree` to `implementer`; await ack.
3. `send_input` `{"type": "shutdown_request"}` to active ECI agents; await shutdown reports.
4. `close_agent` completed ECI agents. If an agent does not respond, report the blocker and close it when possible.
5. `~/.codex/bin/eci-active off <report.md>` (LAST — keeps gate armed if teardown fails partway).

If the orchestrator's next Stop blocks, follow the hook prompt and use the disengage report as the verification summary.

### Disengage report

`~/.codex/bin/eci-active off` requires a markdown report walking the stop checklist (`~/.codex/hooks/stop-checklist.md`) and critically analyzing items that could not be fully complied with during the ECI scope. Required sections:

```
## ECI completion certificate
<exactly one of: clean-pass: <evidence> | user-closed: <evidence>>

## Stop checklist walkthrough
- Questions: pass/fail/N-A — <one-line evidence>
- Git: pass/fail/N-A — <one-line evidence>
- Completion: pass/fail/N-A — <one-line evidence>
- Root cause: ...
- Adversarial self-critique: ...
- Assumed blockers: ...
- Rule-compliance self-audit: ...
- Project understanding ledger: ...
- Testing: ...

## Incomplete compliance
- <item> — could not fully comply because <reason>; impact: <what slipped>
- ...
fully-compliant: <reason rule-by-rule>   # only if no incomplete items
```

The bin rejects reports missing `## Stop checklist walkthrough`, `## Incomplete compliance`, non-empty bodies, and exactly one terminal verdict marker: `clean-pass:` or `user-closed:`. Include either all full Codex stop-verification sections or `## ECI completion certificate`. Validation is a content gate, not a wordcount — write substance, not boilerplate.

Full Codex stop-verification sections: `Summary`, `Verification`, `Requirements`, `Root Cause`, `Claim Inventory`, `Pre-Mortem`, `Adversarial Critique`, `Rule-Compliance Self-Audit`, `Gaps`.

## Loop structure

Each iteration tackles one change. All four steps run per iteration. Do not advance to next change until current one passes all steps.

| Step | Phase | Actor | Output |
|------|-------|-------|--------|
| 1 | Explore | Persistent `explorer` agent (`send_input`) | Ranked options + cited sources |
| 2 | Critique explorations | Critic agent (per round, clear context or shutdown+respawn) | Winner with concrete text + tagged CONDITIONAL/NIT list (one explorer revision round permitted on all-REJECT) |
| 3 | Implement | Persistent `implementer` agent (`send_input`) | One diff |
| 4 | Review gate (parallel) | Critic A + Critic B + E2E agents in parallel | All three run concurrently; wait for all |
| Exit | Main thread | Apply / commit / report |

Agent separation: see Red Flags. Main thread orchestrates; agents produce.

Polling cadence: re-check a working agent at most every 30 minutes; faster polling produces no new signal and burns context. Use `wait_agent` for waiting.

### Bug-discovery routing

If any ECI agent, gate, or user followup discovers a concrete bug (failure, flake, perf regression, or incorrect behavior), route the bug through a debugging iteration or nested ECI pipeline. Main thread only coordinates.

Map `debugging-discipline` to separate delegated ECI roles: repro → `repro` worker; RCA → explorer; critic → Step 2 critic; fix → implementer; review → Critic A/B + E2E gate. Every bug prompt says: "Load `debugging-discipline`; follow its repro/RCA-critic/fix-review loop. Do not submit until root cause is falsifiable and the fix is proven on the real failing path."

## Step 1: Explore

`send_input` to the persistent `explorer` agent. Each per-message body must include:
- The problem/change for THIS iteration, in full context.
- What's already been tried or ruled out (iterations 2+: include results from prior iterations, current codebase state, and last blocking gate issues verbatim if a prior cycle's gate failed).
- Exact file paths of existing related code — explorer must re-read them this turn to avoid suggesting duplicates. "Re-read referenced files; do not trust prior turn reads."
- Required output: ranked options, each with {what, why, where it applies, cost, tradeoffs}.
- Every factual claim in the report must carry a T1-T5 tag per CODEX.md Claim Verification protocol. Primary sources only for T1. Untagged factual claims are not allowed.
- Word cap on the report (default: 1000 words).

## Step 2: Critique explorations

Spawn a DIFFERENT agent — not the explorer, not the main thread. The critic identity must differ from explorer and implementer. Spawn the critic with a unique role label `critic-r<N>` (round) or `critic-A` / `critic-B` (Step 4). Each new round must start with a clean critic context — either clear context when supported or shut it down and respawn under the same role label. MUST NOT reuse the persistent explorer or implementer agent for critic work.

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

**Critic emits issues only.** CONDITIONAL absorption happens at the orchestrator's hand-off to Step 3 — orchestrator folds the winner's CONDITIONAL fix-text into the Step 3 implementer `send_input` body. The critic does NOT rewrite options.

## Step 3: Implement

`send_input` to the persistent `implementer` agent. One change, one diff per message. Code tasks: implementer invokes `test-driven-development`, `debugging-discipline`, and the applicable `<language>-coding-style` skill on each new task message; re-reads every file it intends to modify.

Each new task message to `implementer` includes:
- The current iteration's concrete-text from the Step 2 critic (verbatim).
- Iterations 2+: prior iteration's gate findings (verbatim) and files changed since the last message.
- Step 2 CONDITIONAL fix-list (verbatim, if any) — implementer applies these alongside the concrete text.
- Code/debugging submissions include root-cause rationale. A fix must identify and repair the mechanism that causes the failure. No causal link may remain unexplained. Any change that only alters the failure's frequency, timing, visibility, or blast radius is mitigation unless containment was explicitly requested.
- Submission tags every factual claim. Untagged claim → orchestrator bounces back without spawning the gate (parallel to E2E-evidence rule).

**Affected-path E2E before submit.** Apply only when a code/debugging task changes runtime behavior reachable via UI/API/device/CLI. Skip for docs, prompt/skill edits, config-only, tests-only, or pure refactors with no behavior change. If applicable but unavailable, the implementer reports BLOCKED with the exact missing resource. Missing applicable E2E without rationale → orchestrator bounces before Step 4.

When applicable, implementer must build, run full test suite, exercise the affected feature through real UI/API as a user. Cite direct evidence (output, screenshot, observed state). Proxy evidence (unit tests, lint) insufficient.

If submission lacks E2E evidence (and E2E is applicable), `send_input`: "Submission lacks E2E evidence — re-run build, test suite, and user-path exercise; cite output. Do not re-submit until evidence is in the message body."

## Step 4: Review gate (parallel)

Spawn all three as critic agents in a single message (three parallel `spawn_agent` tool calls with role labels `critic-A` / `critic-B` / `e2e-<gate-N>`). Each MUST NOT message the persistent `explorer` or `implementer` agent. Wait for all three to complete before evaluating results. Every reviewer prompt must include the **original user requirements verbatim** — reviewers catch requirement deviations, not just technical issues.

### Issue severity codes

Every issue from Critic A and Critic B must carry exactly one code:

| Code | Meaning | Effect |
|------|---------|--------|
| **REJECT** | Would make the change wrong, unsafe, or contradictory | Triggers gate re-run after fix |
| **CONDITIONAL** | Fix needed, but obvious/trivial enough to trust without re-review | Must be fixed; no re-run needed |
| **NIT** | Soft recommendation | May be ignored |

Both critics tag every issue per the severity codes table above. Same vocabulary as Step 2; Effect differs (re-implement vs. re-explore).

For every REJECT or CONDITIONAL, reviewers must also tag `impact: trivial` or `impact: substantive` with a one-line rationale. `substantive` means non-trivial, major, API-changing, contract-changing, architecture-changing, security-sensitive, persistence-affecting, concurrency-affecting, or requiring a design tradeoff. Missing impact tag = REJECT against the review output; re-prompt that reviewer before evaluating the gate.

Both critics critique the implementer's root-cause rationale. Unknown causal link or symptom-only change = REJECT unless containment was explicitly requested.

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
Batch E2E only when E2E capacity is the bottleneck (device/browser/env slots, credentials, long setup). Before launch, wait briefly for imminent ready tasks unless the bottleneck would idle. After launch, leave healthy batches alone; queue late arrivals. Report separate verdicts per task.

1. Build the project. Compilation failure = issue.
2. Run full test suite. Failures = issue.
3. Exercise the affected feature through real UI or API as a user would. Verify observable outcomes (output, screenshots, state). Proxy evidence (unit tests pass, linter clean) alone insufficient — direct evidence required.
4. Confirm no regressions in related features.

### Evaluating results

Collect results from all three agents. Apply severity logic:

- At least one substantive REJECT or substantive CONDITIONAL, OR an E2E failure caused by design/API uncertainty → batch all REJECTs, CONDITIONALs, and E2E failures into one design-revision issue list → return to Step 1/Step 2 explorer/designer-critic loop → Step 3 implements the selected revised design plus the full batch → re-run gate.
- At least one trivial REJECT from Critic A or Critic B, OR any trivial E2E failure → fix all REJECTs, CONDITIONALs, and E2E failures in one implementer message → re-run gate.
- Zero REJECTs but only trivial CONDITIONALs exist → fix all CONDITIONALs in one implementer message → gate passes (no re-run).
- Only NITs → gate passes.

Gate retry and cycle limits defined in Escalation table.

**Clean pass** = zero REJECTs + zero CONDITIONALs + E2E pass, all from the same gate run.

### Design-revision issue batch

When the gate routes back to design revision, batch issues before contacting any agent. Do not run one loop per issue.

The batch must include:
- All REJECTs, CONDITIONALs, and E2E failures from the completed gate, grouped by affected artifact/API/contract.
- Source agent, severity, impact tag, file:line or direct evidence, and the exact quoted issue text.
- Acceptance criteria for resolving the whole batch.

Step 1 explorer re-reads current code and researches options that resolve the full batch. Step 2 critic reviews those options as the designer-critic and either selects one concrete revised design or bounces all-REJECT outcomes per Step 2 loop-logic. Step 3 implementer receives the selected revised design and the full issue batch verbatim. No direct patching of substantive findings before this loop.

## Brainstormer (unblocker)

Fresh idea generator — fires on-demand when the cycle stalls. Output is raw ideas only; never decisions, verdicts, or filtering. Bigger list = better.

**Genuine stall definition.** Brainstormer fires only after the producing agent (explorer or implementer) has attempted obvious resolutions and recorded each with why it failed. Attempt log is part of the trigger evidence, not optional. A bare "I'm stuck" without log → not a stall, push the agent to keep trying.

| Trigger | Action |
|---------|--------|
| Explorer returned zero viable options after documented attempts | Spawn brainstormer → feed ideas into a new explorer |
| Step 2 bounce cap reached (one explorer revision round did not yield a clean option) | Spawn brainstormer → feed ideas into a new explorer |
| Implementer genuinely blocked inside Step 3 (per Genuine stall definition above) | Spawn brainstormer → feed ideas into a new implementer prompt |

### Prompt requirements

- Original problem + everything tried so far, verbatim.
- Current code/file paths — brainstormer reads them independently.
- "Generate as many distinct ideas as possible. No filtering, no feasibility judgment, no negatives. Bigger list = better."
- "You are NOT one of the cycle agents. Do not trust prior agent summaries."

### Constraints

- Spawn as separate `brainstormer` agent; never message the explorer or implementer agent.
- Must NOT be any other cycle agent (explorer, Step 2 critic, implementer, Critic A, Critic B, E2E, loop-breaker).
- Each invocation refreshes context via `/clear` or shutdown+respawn — start each idea-burst clean.
- Ideas only — the next cycle agent does the filtering.

## Loop-breaker

A separate agent — not any of the cycle agents — gets one chance to break the loop before escalating to the user.

**One loop-breaker invocation per change**, regardless of trigger. If the granted retry fails → hard escalate; ECI stays active.

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

- Spawn as separate `loop-breaker` agent; refresh context by clearing when supported or shutdown+respawn between invocations.
- Must NOT be any of the 6 cycle agents (explorer, Step 2 critic, implementer, Critic A, Critic B, E2E agent).
- Reads code and issues independently — no reliance on prior agent summaries.
- One invocation per change. Granted retry fails → escalate to user.

## Escalation

Single decision table for all limit hits. One loop-breaker per change total.

| Trigger | Condition | Action | If retry fails |
|---------|-----------|--------|----------------|
| Gate retry cap | 3 gate retries failed within one cycle | Invoke loop-breaker (if not yet used for this change) | Hard escalate; ECI stays active |
| Cycle limit | 3 full cycles failed for one change | Invoke loop-breaker (if not yet used for this change) | Hard escalate; ECI stays active |
| Loop-breaker already used | Either limit hit but loop-breaker was consumed by prior trigger | Skip loop-breaker → hard escalate immediately; ECI stays active | — |
| Step 2 post-brainstormer all-REJECT | Brainstormer fired and new explorer's options still all-REJECT after one revision | Hard escalate; ECI stays active | — |

**Hard escalate** = report a blocker requiring user input while ECI remains active. Include: (a) original problem, (b) what each cycle tried, (c) loop-breaker's assessment (if invoked), (d) last blocking issue, (e) next-best alternative from explorer's ranking. Silent punts forbidden.

## Iteration limit

Cycle limit defined in Escalation table (3 full cycles per change).

## Exit conditions

- All changes landed with clean pass and clean-pass teardown completed, OR
- Loop-breaker ACCEPT → current state accepted with reasoning and clean-pass teardown completed, OR
- User confirms scope closed and user-closed teardown completed, OR
- Hard escalate triggered → blocker/user decision request reported; ECI remains active.

## Status reports

Reports to user use:

| Rule | Example |
|------|---------|
| Human-readable names, not task/iteration numbers | "severity-codes table done", not "task 3 done" / "cycle 2 failed" |
| Tree structure when work decomposes into sub-issues or nested ECI pipelines | Indent children under parent; never flatten |

- Use `<role label> (<runtime name>)` in every status, wait, or close update; do not use bare runtime nicknames once labeled.

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
| Review-gate Critic A returned before Critic B was spawned | Sequential gate. Spawn Critic A + Critic B (+ E2E when in scope) in one message with parallel `spawn_agent` tool calls; do not serialize even if one critic's view seems sufficient. |
| Skipping E2E inside loop | E2E is part of the review gate — runs every iteration, not at the end |
| Skipping exploration or critique for later iterations | Every iteration runs all four steps — none are optional |
| Winner lacks concrete text | Critic under-specified. Re-spawn with "concrete text required" |
| No rejected list in Step 2 | Critic is not adversarial. Re-spawn |
| Brainstormer output filters/judges/picks a winner | Brainstormer is idea-only. Re-spawn with "no filtering, no negatives" |
| Persistent explorer or implementer agent addressed for any critic-role work (Step 2 critic, Critic A, Critic B, brainstormer, loop-breaker) | STOP. Spawn a separate critic agent; the producer (explorer/implementer) must never act as critic. |
| Disengage without teardown sequence | STOP. Shutdown/close agents → eci-active off, in that order. |
| Shell-launched Codex process used as an agent | STOP. Use standard `spawn_agent`/`send_input`/`wait_agent`/`close_agent`, or hard-escalate if unavailable. |
| Status report uses task/iteration numbers, or flat-lists nested work | See **Status reports** section. |
| "Fresh context needed" → spawned a separate agent for Step 1 or Step 3 instead of using `send_input` with the existing agent | The persistent agent provides fresh context per message via the spawn-prompt baseline. Use `send_input` to existing explorer/implementer; do not spawn fresh. |
| Critic absorbed CONDITIONALs by rewriting option | STOP. Critic tags only — orchestrator folds CONDITIONALs into Step 3 `send_input` body. |
| Orchestrator forgot to pass Step 2 CONDITIONALs to implementer | STOP. Step 3 message must include verbatim CONDITIONAL fix-list. |
| Submission accepted with untagged factual claims | STOP. Tag-audit failure = REJECT in current gate (per Critic A/B rule). |
| Code/debugging submission lacks root-cause rationale | STOP. Bounce before gate; unknown "why" means unsubmittable. |
| Critic fails to critique root-cause rationale | STOP. Re-prompt or re-spawn critic. |
| Substantive REJECT/CONDITIONAL fixed directly after review gate | STOP. Batch all gate issues and return to Step 1/Step 2 explorer/designer-critic loop. |
| Gate issues handled one-by-one | STOP. Batch by affected artifact/API/contract before re-exploration or implementation. |

## Relationship to other skills

| Skill | Difference |
|-------|-----------|
| `brainstorming` | Explores user intent before design. This skill explores solutions after intent is clear. |
| `agent-teams-execution` | Full multi-role pipeline for large builds. This skill is the medium-task pattern (explore → critique → implement → parallel review gate). ECI shares the standard Codex agent mechanism (`spawn_agent` / `send_input` / `wait_agent` / `close_agent`) for the persistent explorer + implementer. Borrow its rubber-stamp check: critic citing zero issues beyond producer's self-reports = re-spawn with harsher prompt. |
| `systematic-debugging` | For diagnosing a known bug. This skill is for open-ended improvement/design research. |
| `proof-driven-development` | Proves correctness of logic. This skill selects which logic to build. |
