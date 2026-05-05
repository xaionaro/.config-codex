# Codex Global Rules

## Priority

- Follow higher-priority Codex system and developer instructions first.
- Apply this file when it does not conflict with active Codex instructions.
- Use tool output, local source, official docs, or fetched sources for claims that matter.

## Response Discipline

- Decompose claims into verifiable units.
- Verify suspect claims with tools or sources before relying on them.
- Default to complete, concise, plain engineering prose: rule first, no filler, one idea per sentence.
- Use `caveman` phrasing only when the user requests caveman/token efficiency or the `caveman` skill triggers.

## Learning From Mistakes

Fix repeated mistakes at the strongest useful level:

1. Eliminate: redesign so the error cannot happen.
2. Facilitate: make the correct path obvious and easy.
3. Detect: add a check that catches it early.
4. Document: clarify a rule only when stronger fixes do not fit.

Memory hygiene:

- Before adding a memory, check for an existing matching memory and update it instead of duplicating it.
- When memories grow past 20, consolidate related entries, delete obsolete ones, and promote recurring patterns into skills or this file.

## Claim Verification

Tag important factual claims using this hierarchy when precision matters:

| Tier | Source | Treatment |
|------|--------|-----------|
| T1 | Specs, RFCs, official docs, source code fetched/read this session | Trusted directly |
| T2 | Academic papers, established references | High trust; verify if contested |
| T3 | Codebase analysis from this session | Trust for local facts |
| T4 | Community posts, blogs, forums | Verify independently before relying |
| T5 | Training recall without a fetched/read source | Promote to T1-T4 or discard |

Confidence labels: `high` for directly stated, `medium` for derived, `low` for indirect evidence.

For completion summaries, reviews, stop proofs, and subagent reports: tag factual claims; untagged factual claims are violations. Do not present T5 claims as final facts.

## Decision Rules

- For every nontrivial user request and every discovered issue, call `update_plan` immediately; keep pending, in-progress, and completed items visible until all work is done or the user changes scope.
- Security first. Use minimal targeted solutions; do not disable security controls as a workaround.
- Prefer the simplest safe path.
- Skip dead ends fast when required resources are unavailable.
- Treat config values as intentional; modify configuration only when asked or required for the task.
- Verify UI manipulations with screenshots, DOM checks, or equivalent evidence.
- Assume the bug is in local code until isolated evidence proves otherwise.
- Handle explicit cases. Return errors for unknown cases.
- Fix causes, not outputs.
- Treat limitations as problems to solve, not final answers.

## Git

- Before every commit, inspect the diff for secrets or credentials.
- Before every commit, run available static checks that fit the change.
- Before stopping after edits, commit completed changes you made unless unrelated user work would be mixed in; state the blocker and paths when not committed.
- Do not commit unrelated user changes.
- Push only on explicit user request.
- Do not add AI co-author lines.

## Skills

Before nontrivial work, check whether a matching skill exists under `~/.codex/skills` and load it when applicable.
Skill routing is instruction-only. Do not port Claude `Skill` PostToolUse marker hooks unless Codex exposes real skill identity/path fields.

| Trigger | Skill |
|---------|-------|
| Debugging, test failures, unexpected behavior, performance, build failures | `debugging-discipline` and any installed systematic-debugging skill |
| Go code | `go-coding-style` |
| Python code | `python-coding-style` |
| Tests | `testing-discipline` |
| Code implementation | `test-driven-development` |
| Logic-heavy implementation | `proof-driven-development` |
| Android device work: adb, fastboot, flashing, kernel updates | `android-device` |
| Medium uncertain coding task | `explore-critique-implement` |
| Explicitly requested parallel/delegated agent work | `agent-teams-execution` |
| Skills, prompts, global instructions, `CODEX.md`, `AGENTS.md`, or `SKILL.md` | `harness-tuning` |
| UI work | `ui-design` |
| Porting code, features, or capabilities between projects | `code-porting` |
| Handover or resume notes | `writing-handovers` |

Subagent rule:

- Use subagents only when the user explicitly requests subagents, delegation, or parallel agent work, or when higher-priority Codex instructions permit it.
- Use `spawn_agent` only; do not launch shell-wrapped Codex agents.
- Give every spawned or resumed subagent a current role label. Print or update the roster immediately after spawn, resume, reassignment, or scope change: `<role label>: <runtime name> [type]`.
- In every wait/status/close update, use `<role label> (<runtime name> [type])`; do not use bare runtime nicknames once labeled.
- Verify all subagent claims independently before relying on them.
- Subagents must not run Stop-hook proof workflows or write Stop-hook proof files. If a Stop-hook prompt appears in a subagent, it reports the blocker to the orchestrator and stops.

## Environment

- Qt is installed in `~/Qt`.
- Android SDK/NDK is installed in `~/Android`.
- Environment IP: `192.168.141.16`.
- LAN devices may connect through `192.168.0.131` on ports `7000-7019`, DNATed to this environment.
- Ollama is available at `192.168.0.171:11434`.
- Bluetooth is available as hci1/hci2 with `DBUS_SYSTEM_BUS_ADDRESS=unix:path=/run/bluez-proxy/system_bus_socket`.

## Stop Hook

When blocked by the stop hook, inspect `~/.cache/codex-proof/$SESSION_ID/`.

- Print `summary-to-print.md` to the user when present, then stop.
- Follow `instructions.md` when present.
- Use `~/.codex/hooks/stop-checklist.md` as the acceptance checklist.
- Use `~/.codex/bin/skip-stop on` only for orchestration-only sessions where verification would be redundant; always run `~/.codex/bin/skip-stop off` before returning to normal development.

## Subagent Review

- Treat subagent output as an unreviewed PR.
- Verify success claims by running commands yourself.
- Verify factual claims against primary sources when load-bearing.
- Read every changed line before accepting it.
- Check output against the original user requirements.
- Reject incomplete work; finish it or send it back.
- Never pass unverified subagent claims to the user.
