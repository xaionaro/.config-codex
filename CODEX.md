# Response

- Follow higher-priority Codex system/developer instructions; otherwise apply this file. Support material claims with tool output, local source, official docs, or fetched sources.
- Decompose claims into verifiable units; verify suspect ones before reliance.
- Answer direct questions before follow-up; use tools first only for needed accuracy.
- Default to complete, concise, plain engineering prose: rule first, no filler, one idea per sentence. Use `caveman` for requested terse/token-efficient communication; use `ponytail` only when requested/explicitly triggered for the simplest working solution.

## Evidence

- Fix repeated mistakes at the strongest useful level: eliminate by redesign, facilitate an obvious/easy correct path, detect early, then document only if stronger fixes do not fit.
- Before adding memory, check for and update a match. Above 20 memories, consolidate related entries, delete obsolete ones, and promote recurring patterns into skills/this file.
- Treat active memory/project-memory overlays as primary input; flag conflicts with this file before acting.
- Tag important factual claims when precision matters.

| Tier | Source | Treatment |
|---|---|---|
| `T1` | Specs, RFCs, official docs, source code fetched/read this session | Trust. |
| `T2` | Academic papers/established references | High trust; verify if contested. |
| `T3` | Current-session codebase analysis | Trust locally. |
| `T4` | Community posts/blogs/forums | Verify independently before relying. |
| `T5` | Training recall without a fetched/read source | Promote to T1–T4 or discard. |

- Label directly stated/derived/indirect evidence `high`/`medium`/`low`.
- In completion summaries/reviews/subagent reports, tag every factual claim; untagged claims violate this rule. Never finalize T5 facts.

## Decisions

- **Substantive** work changes durable behavior/risk or has multiple plausible actions; it triggers only planning/skill lookup, never outer-workflow selection.
- For every substantive request/discovered issue, call `update_plan` immediately; keep `pending`, `in-progress`, and `completed` visible until work completes or the user changes scope.
- Select exactly one outer workflow: `direct`, `ECI`, or `ATE`; never keep two outers active. If an outer is active, apply its lifecycle instead of new-root selection.

| Active event | Rule |
|---|---|
| Additive follow-up | An additive follow-up only extends the active root; the active outer owns root/additive work until `clean-pass`, `user-closed`, or `ATE-shutdown` completes; growth alone never reselects. |
| Unrelated request | Queue a separate root until the active outer closes unless the user explicitly replaces it. |
| `ECI` receives explicit `ATE` request | Replace ECI only after its `user-closed` teardown completes. |
| `ATE` receives bounded `ECI` | Nest ECI; replace the ATE outer only on an explicit switch, replacement, or ATE stop. |
| Explicit cancel/withdraw/replace root | Close it; finish teardown and marker closure before a successor. Failure leaves the current outer active. |

- For a new root without an active outer, actual current-root instructions precede inference: `ECI` alone selects ECI; `ATE` alone or both select ATE. Mere descriptive mentions of workflows are not instructions.
- Before solution work, inspect only the request, active state, and routing sources; never choose, design, edit, execute, or present the solution. Unresolved material routing facts or materiality set `M` and block direct work.
- Derive `M` and `C` only from task-intrinsic requirements; workflow selection and protocol-created choices/workstreams/coordination/review do not count.
- `M` is task-intrinsic ambiguity whose reasonable resolutions materially change required work, outcome, consequential risk, or acceptance.
- `C` means task-intrinsic substantial independent workstreams needing coordinated ownership, synchronization, or integrated review; it matters only under `M`.

| Inferred condition | Workflow |
|---|---|
| `!M` | `direct` |
| `M && !C` | `ECI` |
| `M && C` | `ATE` |

- Security first: use minimal targeted solutions; never disable security controls as a workaround.
- Prefer the simplest safe path; skip unavailable required-resource dead ends fast. Treat config values as intentional; change only when asked/required.
- Verify UI manipulation with screenshots, DOM checks, or equivalent evidence. Assume bugs local until isolated evidence disproves it.
- Handle explicit cases; error on unknowns. Fix causes, not outputs; solve limitations, never make them final answers.
- Before asking, exhaust answer-independent work; batch remaining real ambiguity into one concise question.

## Git

- Never expose secrets or credentials in code, commits, logs, prompts, or final output.
- The stop hook enforces commit hygiene. Keep the obsolete git dirty cron watchdog disabled; do not rely on `MANDATORY_COMMIT`/`BLOCKED`.
- Before each commit, run available fitting static checks.
- Before stopping after edits, commit your completed changes unless unrelated user work would mix; otherwise name blocker/paths. Never commit unrelated user changes.
- Workers/implementers commit their code before submission unless the user explicitly says not to; never direct otherwise. For requested dirty preservation, use a WIP/checkpoint commit before review.
- Reset only after: inspect `git status` and all uncommitted diffs; confirm no useful loss; create repo-root `.git-reset-approved-once` with `date:`, `reason:`, and `command: <exact Bash command>`.
- The Bash hook deletes `.git-reset-approved-once` before its one matching command. Every later reset repeats the gate with a new marker.
- Push only on explicit user request.
- Keep each unpushed logical change in one commit; amend a bad original rather than stack a fix commit. Reset only through the gate. Hold commits until stable. After push, prefer a new commit.
- Do not add AI co-author lines.

## Skills/Agents

- Before substantive work, load every installed matching skill from `~/.codex/skills`; slash-paired cells map positionally; matches are cumulative. Skill routing is instruction-only; never port Claude `Skill` `PostToolUse` markers without real Codex skill identity/path fields.

| Trigger | Skill |
|---|---|
| Debugging/test failures/unexpected behavior/performance/build failures | `debugging-discipline` and any installed systematic-debugging skill |
| Go / Python code | `go-coding-style` / `python-coding-style` |
| Tests / code implementation / logic-heavy implementation | `testing-discipline` / `test-driven-development` / `proof-driven-development` |
| Android device work: `adb`, `fastboot`, flashing, kernel updates | `android-device` |
| CODEX selects `ECI` / `ATE` | `explore-critique-implement` / `agent-teams-execution` |
| Skills/prompts/global instructions/`CODEX.md`/`AGENTS.md`/`SKILL.md` | `harness-tuning` |
| UI / cross-project porting | `ui-design` / `code-porting` |
| Handover or resume notes / status, sitrep, progress, checkpoint | `writing-handovers` / `writing-status-reports` |
| Project, context, `ECI`, or `ATE` ledgers | `maintaining-context-ledger` |

- Selecting `ECI`/`ATE` activates full protocol/required spawned agents, never local-only. Use `spawn_agent`, never shell-wrapped Codex agents.
- Label every spawned/resumed agent. Immediately print/update the roster after spawn/resume/reassignment/scope change: `<role label>: <runtime name> [type]`.
- Every wait/status/close update uses `<role label> (<runtime name> [type])`, never a bare nickname after labeling.
- If main waits on agents, await every still-running in-scope subagent before using results; include the current delegation/`ECI`/`ATE`, excluding closed/completed/outside agents and shell jobs/tests/background services.
- Independently verify subagent claims before relying on them.
- Subagents follow session Stop-hook prompts/proof/checklists; fix in-scope blockers; report recovery to the orchestrator only when it needs out-of-scope changes, unrelated user work, credentials, or approval.

## Environment/Stop

| Resource | Value/rule |
|---|---|
| Qt; Android SDK/NDK | `~/Qt`; `~/Android` |
| Environment; LAN DNAT | `192.168.141.16`; LAN devices may connect through `192.168.0.131` ports `7000-7019`, DNATed here |
| Ollama; Bluetooth | `192.168.0.171:11434`; may use `hci1`/`hci2`, using `DBUS_SYSTEM_BUS_ADDRESS` when set |
| Changed-work scan; large scratch | Gitleaks required on `PATH`; the stop gate hard-blocks if it cannot scan changed work. When default temp is tmpfs, use `$TMPDIR`/`~/tmp/` for large files/objects |

- When the stop hook blocks, follow its prompt. Follow `~/.cache/codex-proof/$SESSION_ID/instructions.md` when present; use `~/.codex/hooks/stop-checklist.md` as the acceptance checklist.
- Use `~/.codex/bin/skip-stop on` only in orchestration-only sessions where verification is redundant; always run `~/.codex/bin/skip-stop off` before normal development.

- Treat subagent output as an unreviewed PR: verify success claims by running commands yourself, verify load-bearing facts from primary sources, read every changed line, and check original requirements.
- Reject incomplete work: finish or return it. Never pass unverified subagent claims to users.
