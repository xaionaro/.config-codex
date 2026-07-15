---
name: explore-critique-implement
description: Use when CODEX selects ECI as the outer workflow or active ATE routes bounded work through ECI
---

# Explore-Critique-Implement

Separate the hand that builds from the hand that tears down. The builder cannot credibly critique its own output.

## When to use

| Use | Skip |
|-----|------|
| Solution space uncertain | Mechanical change with obvious answer and no future behavior risk |
| 2+ plausible approaches | Trivial typo or reformat |
| Correctness is load-bearing | Throwaway experiment |
| Research would reduce uncertainty | Mechanical rename |

**Triviality rule:** Classify by decision complexity and future behavior risk, not diff size, line count, file count, or locality. A single-line or single-file change is non-trivial when it changes instructions, prompts, routing, protocols, public contracts, security, persistence, concurrency, architecture, or reviewer/agent behavior, or when 2+ plausible approaches exist. Skip ECI only when the correct change is mechanical and consequences are obvious, directly verifiable, and carry no future behavior or routing risk.

Maintain a project-understanding ledger for every ECI run. Use the `maintaining-context-ledger` skill for storage path, content schema, update timing, and validity rules.

## Codex adapter

- Start ECI only when CODEX selects it as the outer workflow or active ATE routes bounded work through it. Loading this skill alone does not start ECI.
- ECI includes its required spawned agents.
- A request to use ATE while ECI is active, or to cancel, withdraw, or replace ECI's root scope, is user closure for ECI teardown. Checkpoint unfinished work and record its successor handoff or scope removal before using `user-closed:`.
- Claude `TeamCreate` / named Agent / `SendMessage` / `TeamDelete` maps to Codex `spawn_agent` / `send_input` / `wait_agent` / `close_agent`.
- Codex ECI uses standard agent management tools only. Do not launch shell-wrapped Codex agents. If `spawn_agent` or related agent tools are unavailable, ECI cannot run; hard-escalate to the user.

## Prerequisites

Coding task? Every subagent prompt (explorer, critic, implementer) must include: "Before starting, load the `<language>-coding-style` skill and follow its rules."

## Blocker handling

Use `blocker-resolution-protocol` only after normal ECI issue handling cannot resolve a stall, after Step 2 post-bounce all-REJECT outcomes, or after gate/cycle limit hits before hard escalation.

Concrete bug/failure/flake/perf/incorrect behavior -> debugging iteration (`debugging-discipline`), not BRP; BRP only if debugging itself is blocked with an attempt log, hits its cap, or needs user-owned input.

ECI adapter:
- Keep ECI active while resolving blockers.
- Subagent-blocked != mission-blocked. Try normal ECI issue handling first; BRP is last resort before hard escalation.
- Use the separate `brainstormer` role for genuine stalls and Step 2 all-REJECT caps.
- Run a BRP primary explorer and separate `brp-feasibility-validator` before routing brainstormer output onward.
- Feed the blocker record, validated feasible ideas, primary explorer facts, and prior failures into the next explorer or implementer message.
- Use the separate `loop-breaker` role at gate/cycle limits before hard escalation.
- Hard escalation reports the blocker requiring user input; it does not disengage ECI.

## Engagement marker

The PreToolUse gate `~/.codex/hooks/eci-active-gate.sh` denies direct Edit/Write/MultiEdit on the main thread while engaged. Every code change must flow through a spawned agent. Spawned agents write from their own session; the marker is keyed to the orchestrator's session and must not block them.

| Step | Command | When |
|------|---------|------|
| Engage | `~/.codex/bin/eci-active on "<task + scope>"` | Before Step 1 of the first iteration |
| Disengage | See Teardown sequence below | Clean pass or user closes ECI through protocol or root-scope replacement |
| Hard escalate | Report blocker requiring user input; marker stays active | ECI cannot proceed without user input |

Do not disengage mid-task to escape the gate — that is the regression this marker exists to catch. If a hand-edit feels necessary, send the work to the persistent `implementer` agent.

## Team setup

**Persistent agent** = spawned once with `spawn_agent`, then reused with `send_input`. **One-shot agent** = spawned for one bounded assignment, then closed. ECI uses persistent agents for every cycle role when reuse is available.

Persistent agents handle Step 1 (explorer) and Step 3 (implementer) across iterations. Critic-role work (Step 2 critic, Critic A, Critic B, brainstormer, brp-feasibility-validator, loop-breaker) is also done by persistent agents — not the explorer or implementer, but separately-spawned critic agents with their own identity. E2E agent is also a persistent agent. The producer (explorer/implementer) must never act as critic.

**"Persistent" != "carries cross-iteration context".** The persistent agent's spawn-prompt baseline already forces fresh-assignment treatment each message (re-read referenced files, no prior-turn trust). Spawning a new agent for Step 1 or Step 3 because "fresh context is needed" defeats the persistent role — `send_input` to the existing agent already gives that. The producer-vs-critic split is about *agent identity for adversarial separation* (critic must not be the producer), not about context staleness.

**Reusable role rule.** Spawn stable role slots, not task/round-specific identities. Use the tool's reusable `agent_type` values (`explorer`, `worker`, `default`); carry ECI identity in the spawn prompt, roster label, and `send_input` messages. Put changing details (`round`, `gate`, `scope`, `lens`) in the assignment, not the role name.

**Critic identity rule.** Step 2 critic, Critic A, Critic B, brainstormer, brp-feasibility-validator, and loop-breaker are spawned as separate reusable role slots (`critic-step2`, `critic-A`, `critic-B`, `brainstormer`, `brp-feasibility-validator`, `loop-breaker`). Adversarial separation = identity rule (critic != producer). Bias-freedom between rounds/invocations is achieved by clearing context when reuse is available or shutting down and respawning under the same role name. Do not rely on persistent-context "carrying over" — each round must start clean.

Codex does not use `CLAUDE_ROLE`, `TeamCreate`, `team_name`, or independent tmux/CLI agents for ECI. Role identity is carried in the spawn prompt, roster label, and subsequent `send_input` messages.

### Spawning

| Action | Command |
|--------|---------|
| Spawn explorer | `spawn_agent` with `agent_type: "explorer"` and role label `explorer` |
| Spawn implementer | `spawn_agent` with `agent_type: "worker"`, role label `implementer`, and explicit file/module ownership |
| Spawn Step 2 critic | `spawn_agent` with `agent_type: "explorer"` or `default`; role label `critic-step2`; assignment includes round number |
| Spawn Step 4 critic-A / critic-B | Parallel `spawn_agent` calls with role labels `critic-A` / `critic-B` |
| Spawn E2E agent | `spawn_agent` with `agent_type: "worker"` or `default`; role label `e2e-gate`; assignment includes gate number |
| Spawn brainstormer | `spawn_agent` with `agent_type: "explorer"` and role label `brainstormer` |
| Spawn BRP feasibility validator | `spawn_agent` with `agent_type: "explorer"` or `default`; role label `brp-feasibility-validator` |
| Spawn loop-breaker | `spawn_agent` with `agent_type: "explorer"` and role label `loop-breaker` |

Every spawned agent prompt states the role name, original user requirements, exact scope, expected output, and that other agents may be editing in parallel. Exception: Critic B Packet 1 for code diffs contains only role label, stop-hook/reporting boilerplate, code diff, and reconstruction instruction; omit original requirements, exact scope, ledger/task/design context, rationale, commit message, and prior review output until Packet 2.
Every spawned ECI agent prompt must also state: "Follow any Stop-hook prompt in that session, including required proof/checklist files. Fix blockers within assigned scope. Report to the orchestrator only when resolution needs out-of-scope changes, unrelated user work, credentials, or approval."

### Explorer spawn-prompt baseline

Per-message body in Step 1.
- Role label per Spawning table.
- "Treat each new task message as a fresh assignment per Step 1 of the ECI skill. Re-read every referenced file each turn — do not trust prior-turn reads."

### Implementer spawn-prompt baseline

Per-message body in Step 3.
- Role label per Spawning table.
- "Treat each new task message as a fresh assignment per Step 3 of the ECI skill. Re-read every file you intend to modify each turn."
- One commit per logical change.
- Code/debugging submissions include root-cause rationale plus regression status/explanation when applicable: cause chain, evidence, and why the diff repairs the cause. Unknown "why" = unsubmittable.
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
| 2 | Critique explorations | `critic-step2` agent (per round, clear context or shutdown+respawn under same role label) | Winner with concrete text + tagged CONDITIONAL/NIT list (one explorer revision round permitted on all-REJECT) |
| 3 | Implement | Persistent `implementer` agent (`send_input`) | One diff |
| 4 | Review gate (parallel) | Critic A + Critic B + E2E agents in parallel | All three run concurrently; wait for all |
| Exit | Main thread | Apply / commit / report |

Agent separation: see Red Flags. Main thread orchestrates; agents produce.

Polling cadence: re-check a working agent at most every 30 minutes; faster polling produces no new signal and burns context. Use `wait_agent` for waiting.

### Bug-discovery routing

If any ECI agent, gate, or user followup discovers a concrete bug (failure, flake, perf regression, or incorrect behavior), route the bug through a debugging iteration or nested ECI pipeline. Main thread only coordinates.

Map `debugging-discipline` to separate delegated ECI roles: repro -> `repro` worker; RCA/regression -> `rcaer` explorer; critic -> Step 2 critic; fix -> implementer; review -> Critic A/B + E2E gate. Every bug prompt says: "Load `debugging-discipline`; follow its repro/RCA-critic/fix-review loop. Determine `regression: yes/no/unknown`; if regression, explain how it happened. Do not submit until root cause is falsifiable and the fix is proven on the real failing path."

Before sending the RCA/regression assignment, write or update a human-readable regression report file: `~/.cache/codex-proof/$SESSION_ID/eci-regression-reports/<task>.md` when `$SESSION_ID` exists; otherwise `./.codex-regression-reports/<task>.md`. Include bug statement, repro, previous/current test-run artifact paths, CI/log/release/QA evidence, known-good/current-bad anchors, regression status, missing evidence, and the regression explanation once known. Send the report path and evidence packet to `rcaer`. Human reading is optional; never block the pipeline waiting for user review.

## Step 1: Explore

`send_input` to the persistent `explorer` agent. Each per-message body must include:
- The problem/change for THIS iteration, in full context.
- What's already been tried or ruled out (iterations 2+: include results from prior iterations, current codebase state, and last blocking gate issues verbatim if a prior cycle's gate failed).
- Exact file paths of existing related code — explorer must re-read them this turn to avoid suggesting duplicates. "Re-read referenced files; do not trust prior turn reads."
- Required output: ranked options, each with {what, why, where it applies, cost, tradeoffs}.
- Every factual claim in the report must carry a T1-T5 tag per CODEX.md Claim Verification protocol. Primary sources only for T1. Untagged factual claims are not allowed.
- Word cap on the report (default: 1000 words).

### Proof of Concept Requirement

Any proposed option whose core mechanism is unproven-in-practice (not a well-known pattern, not already shipped in this codebase, not a documented vendor API used as documented) ships with a minimal PoC alongside the proposal:

- Strip every concern not needed to exercise the core mechanism — no error handling, no edge cases, no production polish, no scaffolding beyond what the demo requires.
- Run end-to-end on one real input; produce the observable behavior the mechanism claims.
- Explorer attaches the PoC to the option in Step 1. Missing PoC on an unproven option = Step 2 REJECT.

Proven-in-practice mechanisms need no PoC. State "proven by <link/citation>" when claiming exemption.

## Step 2: Critique explorations

Spawn a DIFFERENT agent — not the explorer, not the main thread. The critic identity must differ from explorer and implementer. Spawn or reuse the stable role label `critic-step2` (Step 2) or `critic-A` / `critic-B` (Step 4); put the round number in the assignment. Each new round must start with a clean critic context — either clear context when supported or shut it down and respawn under the same role label. MUST NOT reuse the persistent explorer or implementer agent for critic work.

The critic's prompt must include:
- **Original user requirements verbatim.** The critic must verify options against what the user actually asked for, not just technical soundness.
- **"Step 0 — Independent baseline."** Read the source material (target file, existing code, prior art) and write your own 3-5 bullet assessment BEFORE opening the explorer's report. Include this baseline in the critique output.
- "Assume every suggestion is wrong until you prove otherwise."
- "Read the current state first" (the file/code/doc the explorer was working on) — verify duplication claims independently.
- **Claim-scope audit for governance/prompt/hook/protocol/reviewer changes:** record mechanism/predicate, emitted or user-facing wording, strongest wording evidence supports, and one boundary counterexample. REJECT certainty, classification, provenance, or authority wording beyond mechanism evidence. Silent `UserPromptSubmit` state maintenance does not prove the user's work is non-trivial. `prompt-task-reminder.sh` maintains prompt state silently; optional LLM first-tool admission review is separate `PreToolUse` behavior configured through `CODEX_EDIT_PRE_REVIEWER`, with `LLM_EDIT_PRE_REVIEWER` and `CLAUDE_EDIT_PRE_REVIEWER` accepted only as lower-precedence compatibility aliases when earlier variables are unset.
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
- Each retry round uses a clean critic context under the same reusable critic role label.

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
| Every option has ≥1 REJECT, round 1 | Bounce verbatim REJECT reasons to explorer; explorer revises; reset/reuse `critic-step2` for round 2 | Bounce-back |
| Every option has ≥1 REJECT, round 2 | Trigger brainstormer per Brainstormer trigger row; new explorer round | Escalation per Escalation table |
| Only NITs across all options | Pick highest-ranked option directly | Winner + NITs |

**Critic emits issues only.** CONDITIONAL absorption happens at the orchestrator's hand-off to Step 3 — orchestrator folds the winner's CONDITIONAL fix-text into the Step 3 implementer `send_input` body. The critic does NOT rewrite options.

## Step 3: Implement

`send_input` to the persistent `implementer` agent. One change, one diff per message. Code tasks: implementer invokes `test-driven-development`, `debugging-discipline`, and the applicable `<language>-coding-style` skill on each new task message; re-reads every file it intends to modify.

Each new task message to `implementer` includes:
- The current iteration's concrete-text from the Step 2 critic (verbatim).
- Iterations 2+: prior iteration's gate findings (verbatim) and files changed since the last message.
- Step 2 CONDITIONAL fix-list (verbatim, if any) — implementer applies these alongside the concrete text.
- Code/debugging submissions include root-cause rationale plus regression status/explanation when applicable. A fix must identify and repair the mechanism that causes the failure. No causal link may remain unexplained. Any change that only alters the failure's frequency, timing, visibility, or blast radius is mitigation unless containment was explicitly requested.
- Submission tags every factual claim. Untagged claim → orchestrator bounces back without spawning the gate (parallel to E2E-evidence rule).

**Affected-path E2E before submit.** Runtime behavior reachable via UI/API/device/CLI: build, run full tests, exercise affected user path, cite output/screenshot/state. Proxy evidence alone insufficient. Skip docs, prompts, config-only, tests-only, pure refactors. If E2E unavailable, report BLOCKED with the exact missing resource; missing E2E/rationale → bounce before Step 4.

If applicable E2E evidence is missing, `send_input`: "Missing E2E evidence — build, run full suite, exercise user path, cite output/screenshot/state. Do not resubmit without evidence."

## Step 4: Review gate (parallel)

Spawn all three as critic agents in a single message (three parallel `spawn_agent` tool calls with role labels `critic-A` / `critic-B` / `e2e-gate`; assignment includes gate number). Each MUST NOT message the persistent `explorer` or `implementer` agent. Wait for all three to complete before evaluating results. Every reviewer prompt must include the **original user requirements verbatim** — reviewers catch requirement deviations, not just technical issues.

Critic B code-diff exception:
- Code diffs use two packets. Skip Packet 1 when there is no code diff.
- Packet 1 is diff-only isolation. If Critic B is reused, clear context first when supported; otherwise shutdown+respawn under `critic-B`.
- Packet 1 contains only role label, stop-hook/reporting boilerplate, code diff, and reconstruction instruction. It is exempt from original requirements, exact scope, and normal review context.
- After `reconstructed intention:` returns, send Packet 2 with original requirements and full Critic B context.
- Gate incomplete until Packet 2 returns.

### Issue severity codes

Every issue from Critic A and Critic B must carry exactly one code:

| Code | Meaning | Effect |
|------|---------|--------|
| **REJECT** | Would make the change wrong, unsafe, or contradictory | Must be fixed; routing follows impact/evaluation rules below |
| **CONDITIONAL** | Fix needed, but specific enough for the implementer to apply without redesign unless impact requires it | Must be fixed; routing follows impact/evaluation rules below |
| **NIT** | Soft recommendation | May be ignored |

Both critics tag every issue per the severity codes table above. Same vocabulary as Step 2; Effect differs (re-implement vs. re-explore).

For every REJECT or CONDITIONAL, reviewers must also tag `impact: trivial` or `impact: substantive` with a one-line rationale. `substantive` means non-trivial, major, API-changing, contract-changing, architecture-changing, security-sensitive, persistence-affecting, concurrency-affecting, or requiring a design tradeoff. Use the Triviality rule above for impact tags. Small patches are substantive when they alter future behavior, decision rules, contracts, prompts/instructions, or review routing. Missing impact tag = REJECT against the review output; re-prompt that reviewer before evaluating the gate.

Both critics critique the implementer's root-cause rationale and regression explanation when applicable. Unknown causal link or symptom-only change = REJECT unless containment was explicitly requested.

For governance/prompt/hook/protocol/reviewer changes, Critic A and Critic B perform the Step 2 claim-scope audit. REJECT overclaims and missing boundary/negative tests; silent `UserPromptSubmit` state maintenance must not be described as reminder emission or an LLM reviewer/classifier. Optional LLM first-tool admission review is separate `PreToolUse` behavior configured through `CODEX_EDIT_PRE_REVIEWER`, with `LLM_EDIT_PRE_REVIEWER` and `CLAUDE_EDIT_PRE_REVIEWER` accepted only as lower-precedence compatibility aliases when earlier variables are unset.

### Critic A — correctness

Emit only issues affecting correctness, safety, or fidelity to the concrete text. Interface contract fulfillment — does every interface implementation actually work, not just compile? Polish and taste items are NITs at most.

Tag-discipline audit: every factual claim in the implementer's submission must carry a T1-T5 tag per CODEX.md Claim Verification protocol. Untagged factual claim = REJECT.

### Critic B — long-term health

Different agent from Critic A.

Diff-only intention check:
- Code diffs only. Skip when there is no code diff.
- Before Packet 1, clear `critic-B` context when supported; otherwise shutdown+respawn under `critic-B`.
- Packet 1 contains only role label, stop-hook/reporting boilerplate, code diff, and reconstruction instruction.
- Exclude original requirements, exact scope, ledger/task/design context, rationale, commit message, implementer or teammate summaries, and prior review output.
- Output `reconstructed intention:` with 2-4 bullets covering apparent root reason and intended behavior change, then stop.
- Main thread compares the reconstruction with the actual root reason and desired effects.
- If it misses the root reason, relies on hidden context, or claims an undesired effect, add a `CONDITIONAL` follow-up with the normal `impact:` tag to make code, tests, names, comments, or commit message explain the change.
- Packet 2: continue normal long-term-health review with full context.

Focus — adversarial, long-term lens:
- **Tech debt**: Coupling, hidden dependencies, or shortcuts costing more to fix later than now?
- **Coding style**: Load the applicable `<language>-coding-style` skill. Does the diff follow naming, error handling, structure, and idiom conventions?
- **Code smells**: God methods, feature envy, primitive obsession, duplicated logic, unclear names, missing/premature abstractions. Flag only smells that materially hurt readability or maintainability.
- **Architectural fit**: Right layer? Respects module boundaries? Code in correct binary/package per its stated purpose?
- **Tag-discipline**: every factual claim in submission carries T1-T5 per CODEX.md Claim Verification. Untagged factual claim = REJECT.

Emit only issues that matter for long-term health. "Would refactor eventually" is not an issue — "will cause bugs or confusion within 3 months" is.

### E2E agent — end-to-end verification

**Code/debugging tasks only.** Skip for non-code tasks (docs, config, design).
E2E capacity bottlenecked (device/browser/env slots, credentials, long setup): batch only then. While waiting, debug via shortest faithful repro (unit/API/CLI/log replay/component) before full E2E. Wait briefly for imminent tasks only if no slot idles; keep healthy batches running; queue late arrivals; report per-task verdicts.

1. Build; failure = issue.
2. Run full suite; failure = issue.
3. Exercise affected user path through real UI/API; cite output/screenshot/state. Proxy evidence alone insufficient.
4. Check related regressions.

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

**Genuine stall definition.** Normal ECI issue handling was tried, and the Required Record from `blocker-resolution-protocol` exists. A bare "I'm stuck" without an attempt log is not a stall; push the agent to keep trying.

| Trigger | Action |
|---------|--------|
| Explorer returned zero viable options after documented attempts | Spawn brainstormer + BRP primary explorer -> run `brp-feasibility-validator` -> feed blocker record, validated feasible ideas, primary explorer facts, and prior failures into the next explorer/implementer prompt |
| Step 2 bounce cap reached (one explorer revision round did not yield a clean option) | Spawn brainstormer + BRP primary explorer -> run `brp-feasibility-validator` -> feed blocker record, validated feasible ideas, primary explorer facts, and prior failures into the next explorer/implementer prompt |
| Implementer genuinely blocked inside Step 3 (per Genuine stall definition above) | Spawn brainstormer + BRP primary explorer -> run `brp-feasibility-validator` -> feed blocker record, validated feasible ideas, primary explorer facts, and prior failures into the next explorer/implementer prompt |

### Prompt requirements

- Original problem + everything tried so far, verbatim.
- Current code/file paths — brainstormer reads them independently.
- "Generate as many distinct ideas as possible. No filtering, no feasibility judgment, no negatives. Bigger list = better."
- "You are NOT one of the cycle agents. Do not trust prior agent summaries."

### Constraints

- Spawn as separate `brainstormer` agent; never message the explorer or implementer agent.
- Must NOT be any other cycle agent (explorer, Step 2 critic, implementer, Critic A, Critic B, E2E, brp-feasibility-validator, loop-breaker).
- Each invocation refreshes context via `/clear` or shutdown+respawn — start each idea-burst clean.
- Ideas only — `brp-feasibility-validator` filters BRP-triggered ideas.
- Brainstormer output never goes directly to explorer/implementer after a BRP trigger; only validator-approved ideas may be routed onward.

## Loop-breaker

A separate agent — not any of the cycle agents — gets one chance to break the loop before escalating to the user.

**One loop-breaker invocation per change**, regardless of trigger. If the granted retry fails -> create a protocol-limit blocker record, run `blocker-resolution-protocol`, and hard escalate only if BRP finds no feasible internal path or the blocker is user-owned. ECI stays active.

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
- One invocation per change. Granted retry fails -> create a protocol-limit blocker record, run `blocker-resolution-protocol`, and hard escalate only if BRP finds no feasible internal path or the blocker is user-owned.

## Escalation

Single decision table for all limit hits. One loop-breaker per change total.

| Trigger | Condition | Action | If retry fails |
|---------|-----------|--------|----------------|
| Gate retry cap | 3 gate retries failed within one cycle | Invoke loop-breaker (if not yet used for this change) | Create protocol-limit blocker record -> run `blocker-resolution-protocol` -> hard escalate only if BRP finds no feasible internal path or the blocker is user-owned; ECI stays active |
| Cycle limit | 3 full cycles failed for one change | Invoke loop-breaker (if not yet used for this change) | Create protocol-limit blocker record -> run `blocker-resolution-protocol` -> hard escalate only if BRP finds no feasible internal path or the blocker is user-owned; ECI stays active |
| Loop-breaker already used | Either limit hit but loop-breaker was consumed by prior trigger | Create protocol-limit blocker record -> run `blocker-resolution-protocol` -> hard escalate only if BRP finds no feasible internal path or the blocker is user-owned; ECI stays active | — |
| Step 2 post-brainstormer all-REJECT | Brainstormer fired and new explorer's options still all-REJECT after one revision | Create protocol-limit blocker record -> run `blocker-resolution-protocol` -> hard escalate only if BRP finds no feasible internal path or the blocker is user-owned; ECI stays active | — |

**Hard escalate** = report a blocker requiring user input while ECI remains active. Use the escalation report from `blocker-resolution-protocol`, plus: (a) original problem, (b) what each cycle tried, (c) loop-breaker's assessment (if invoked), (d) last blocking issue, (e) next-best alternative from explorer's ranking. Silent punts forbidden.

## Iteration limit

Cycle limit defined in Escalation table (3 full cycles per change).

## Exit conditions

- All changes landed with clean pass and clean-pass teardown completed, OR
- Loop-breaker ACCEPT → current state accepted with reasoning and clean-pass teardown completed, OR
- User closes ECI by requesting ATE or by cancelling, withdrawing, or replacing its root scope, and user-closed teardown completes, OR
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
| Any two of {explorer, Step 2 critic, implementer, Critic A, Critic B, E2E agent, brainstormer, brp-feasibility-validator, loop-breaker} are the same agent | Banned. Up to nine distinct agents (six per normal cycle + brainstormer/validator for BRP + loop-breaker at limits) |
| Review-gate Critic A returned before Critic B was spawned | Sequential gate. Spawn Critic A + Critic B (+ E2E when in scope) in one message with parallel `spawn_agent` tool calls; do not serialize even if one critic's view seems sufficient. |
| Task/round-specific role labels (`critic-r3`, `e2e-gate-7`) used instead of reusable role slots | STOP. Use stable labels (`critic-step2`, `e2e-gate`) and put round/gate details in the assignment. |
| Skipping E2E inside loop | E2E is part of the review gate — runs every iteration, not at the end |
| Skipping exploration or critique for later iterations | Every iteration runs all four steps — none are optional |
| Winner lacks concrete text | Critic under-specified. Re-spawn with "concrete text required" |
| No rejected list in Step 2 | Critic is not adversarial. Re-spawn |
| Brainstormer output filters/judges/picks a winner | Brainstormer is idea-only. Re-spawn with "no filtering, no negatives" |
| Persistent explorer or implementer agent addressed for any critic-role work (Step 2 critic, Critic A, Critic B, brainstormer, brp-feasibility-validator, loop-breaker) | STOP. Spawn a separate critic agent; the producer (explorer/implementer) must never act as critic. |
| Disengage without teardown sequence | STOP. Shutdown/close agents → eci-active off, in that order. |
| Shell-launched Codex process used as an agent | STOP. Use standard `spawn_agent`/`send_input`/`wait_agent`/`close_agent`, or hard-escalate if unavailable. |
| Status report uses task/iteration numbers, or flat-lists nested work | See **Status reports** section. |
| "Fresh context needed" → spawned a separate agent for Step 1 or Step 3 instead of using `send_input` with the existing agent | The persistent agent provides fresh context per message via the spawn-prompt baseline. Use `send_input` to existing explorer/implementer; do not spawn fresh. |
| Critic absorbed CONDITIONALs by rewriting option | STOP. Critic tags only — orchestrator folds CONDITIONALs into Step 3 `send_input` body. |
| Orchestrator forgot to pass Step 2 CONDITIONALs to implementer | STOP. Step 3 message must include verbatim CONDITIONAL fix-list. |
| Submission accepted with untagged factual claims | STOP. Tag-audit failure = REJECT in current gate (per Critic A/B rule). |
| Hook/protocol/reviewer wording claims a heuristic proves, classifies, or determines task nature without matching mechanism evidence and boundary tests | STOP. Reword to the strongest supported claim and add negative/boundary pressure. |
| Code/debugging submission lacks root-cause rationale or required regression explanation | STOP. Bounce before gate; unknown "why" means unsubmittable. |
| Bug RCA prompt lacks regression report path or previous/current test-run evidence packet | STOP. Write/update the report artifact, then resend the RCA assignment. |
| Critic fails to critique root-cause rationale or regression explanation | STOP. Re-prompt or re-spawn critic. |
| Substantive REJECT/CONDITIONAL fixed directly after review gate | STOP. Batch all gate issues and return to Step 1/Step 2 explorer/designer-critic loop. |
| Gate issues handled one-by-one | STOP. Batch by affected artifact/API/contract before re-exploration or implementation. |

## Relationship to other skills

| Skill | Difference |
|-------|-----------|
| `brainstorming` | Explores user intent before design. This skill explores solutions after intent is clear. |
| `agent-teams-execution` | ATE is the outer workflow for large or multi-workstream work. It may route bounded work through ECI; ATE remains outer. ECI borrows ATE's rubber-stamp check: a critic citing no issues beyond producer self-reports must be re-spawned with a harsher prompt. |
| `blocker-resolution-protocol` | Shared blocker handling. ECI keeps its own role separation, loop-breaker, and hard-escalation semantics while using the shared blocker record and escalation rules. |
| `systematic-debugging` | For diagnosing a known bug. This skill is for open-ended improvement/design research. |
| `proof-driven-development` | Proves correctness of logic. This skill selects which logic to build. |
