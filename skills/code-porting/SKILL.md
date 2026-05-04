---
name: code-porting
description: Use when porting code, features, or capabilities from one codebase/project to another — extracts exhaustive feature inventory, analyzes gaps against target, designs porting plan through adversarial critique loops, then implements via explore-critique-implement.
---

# Code Porting

Port code between codebases through exhaustive extraction, adversarial critique, and gated implementation. Keep each phase as a separate work product. Use separate subagents only when higher-priority Codex instructions allow delegation and the user explicitly requested subagents, parallel agents, or delegated work.

## When to use

| Use | Skip |
|-----|------|
| Porting features/capabilities between projects | Copy-pasting a single function |
| Migrating subsystems to new architecture | Trivial config transplant |
| Adopting patterns from a concrete source codebase | Rewriting from scratch (no source to port from) |
| Backporting fixes across forks | Mechanical file copy with no adaptation |

## Agent separation

Every numbered phase below has a separate role and artifact. No role serves dual purposes. When delegation is authorized, run phases as separate agents. Otherwise, perform the phases locally while preserving the boundaries and critique gates.

Propagate **original user requirements verbatim** to every subagent prompt.

When combined phase outputs exceed 6000 words, main thread summarizes before spawning the next agent. Preserve: all feature names, all verdicts with one-line reasoning, all MISSING/OVERTURN entries in full. Never silently drop features.

## Phases

| Phase | Actor | Input | Output |
|-------|-------|-------|--------|
| 0 | Main thread | User request | Plan/checklist established |
| 1 | Extraction agent | Source codebase + user scope | Feature inventory |
| 2 | Gap agent | Feature inventory + target codebase | Gap analysis |
| 3 | Critique agent | Inventory + gap analysis | Pruned/corrected list |
| 4 | Meta-critique agent | Inventory + gap analysis + critique | Validated critique |
| 5a | Plan designer agent | All prior outputs | Porting plan |
| 5b | Plan critic agent | Porting plan + all prior outputs | Approved/rejected plan |
| 5 | Loop 5a→5b | Until plan critic passes or 3 iterations | Final plan |
| 6 | Main thread | Final plan → user | User-approved plan |
| 7 | Per-task | `explore-critique-implement` per porting task | Landed changes |

## Phase 0: Establish plan

Create a visible plan/checklist before adaptation work begins. Phases 1-5 are analysis/design work. Phase 6 is the user-facing review point before implementation when approval is needed.

## Phase 1: Feature extraction

Spawn extraction agent. Prompt must include:

- Source codebase paths and user-specified scope.
- "List AS MUCH AS POSSIBLE. Err on over-listing. The critique phases prune — you do not."

### Semantic context tree (required, before feature list)

Extract the full semantic hierarchy from project root to modified parts:

```
Project: what it is, who it serves, core purpose
  └── Module: what this module does within the project
        └── Component: what this component does within the module
              └── Modified parts: what changed and how it affects the component/module/project semantics
```

Every feature in the inventory must be anchored to its branch in this tree. Reviewers need to understand not just WHAT was changed but HOW it affects the system's meaning at every level.

### Per-feature output format

| Field | Content |
|-------|---------|
| Feature | Name/identifier |
| Semantic path | Project → Module → Component (branch from tree above) |
| What | What it does |
| Why | Why it exists (user-facing purpose) |
| Semantic impact | How this feature affects the meaning/behavior of its parent module and the project |
| Dependencies | Internal and external deps |
| Complexity | S/M/L estimate with justification |
| Source files | Exact paths read |

- Agent must read source code comprehensively — no summaries from memory.
- Word cap: 3000 words.

## Phase 2: Gap analysis

Spawn a DIFFERENT agent — not the extraction agent.

Prompt must include:

- Feature inventory from Phase 1 verbatim.
- Target codebase paths.
- "Read target code independently. Do not trust the extraction agent's claims about the target."

Required output per feature:

| Field | Content |
|-------|---------|
| Feature | From inventory |
| Status | Present / Absent / Partial |
| Evidence | File paths and line references in target |
| If Absent | Why useful, what it enables |
| If Partial | What's missing, what exists |
| Porting cost | S/M/L estimate |

Word cap: 2000 words.

## Phase 3: Critique the list

Spawn a DIFFERENT agent — not the extractor or gap analyzer.

Prompt must include:

- Feature inventory + gap analysis.
- Source and target codebase paths (critic reads code independently).
- "Assume every entry is wrong until you prove otherwise."

Required output:

- Per-feature verdict: CONFIRMED / CORRECTED / REJECTED / MISSING (new feature the extractor missed).
- For CORRECTED: what was wrong and the fix.
- For REJECTED: evidence it's not a real feature or not in scope.
- For MISSING: full feature entry (same format as Phase 1).
- "Be harsh. Over-extraction is expected — prune noise, but do not prune real features to look selective."

Word cap: 2000 words.

## Phase 4: Critique the critique

Spawn a DIFFERENT agent — not any prior agent.

Purpose: prevent single-critic bias. The Phase 3 critic may be too aggressive (pruning real features) or too lenient (rubber-stamping).

Prompt must include:

- All Phase 1–3 outputs.
- Source and target codebase paths.
- "Review the critic's work, not the original list. Is the critic accurate? Too aggressive? Too lenient? Missing patterns?"

Required output:

- Per-verdict assessment: AGREE / OVERTURN / AMEND.
- For OVERTURN: evidence the critic was wrong, restored feature entry.
- For AMEND: what the critic got partially right and the correction.
- Systemic patterns: is the critic consistently biased in a direction?

Word cap: 1500 words.

## Phase 5: Design loop

Iterative loop, max 3 iterations.

### Phase 5a: Plan designer

Spawn plan designer agent. Prompt must include:

- Reconciled feature list (main thread resolves Phase 3 + Phase 4 verdicts into a single adjudicated inventory before spawning this agent).
- Gap analysis.
- Target codebase paths.
- "Design a concrete porting plan."

Required output:

| Field | Content |
|-------|---------|
| Task ID | Sequential |
| Feature(s) | Which features this task ports |
| Order | Execution order (respects dependencies) |
| Files | Create / modify / delete in target |
| Dependencies | Which prior tasks must complete first |
| Approach | How to port (adapt, rewrite, translate) |
| Risk | What could go wrong |

Word cap: 3000 words.

### Phase 5b: Plan critic

Spawn a DIFFERENT agent — not the plan designer.

Prompt must include:

- The porting plan from 5a.
- All prior phase outputs.
- "Assume the plan is wrong."

Checks:

- Dependency ordering correct?
- Missing steps?
- Over-engineering (porting things that aren't needed)?
- Under-scoping (missing integration glue)?
- File-to-binary assignment coherence — does each file belong in the binary whose purpose matches?
- Task granularity appropriate for `explore-critique-implement`?

Verdict: PASS (with NITs) or FAIL (with mandatory fixes). On FAIL, loop back to 5a with critic's feedback. Word cap: 1500 words.

### Loop exit

- Plan critic passes, OR
- 3 iterations exhausted → present best plan to user with unresolved critic issues flagged.

## Phase 6: User configuration

Exit plan mode. Present the final plan to the user:

- Full task list with ordering.
- Unresolved critic issues (if any).
- Estimated total scope.

User may: approve all, approve subset, modify tasks, reject and restart.

Proceed only with user-approved tasks.

## Phase 7: Implementation

For each approved task, invoke `explore-critique-implement`. Each task goes through the full explore→critique→implement→review gate loop independently.

Per-task prompt must include:

- Original user requirements verbatim.
- Specific task from porting plan (Task ID, features, approach, files, risks).
- Source file paths relevant to the feature being ported.
- Target file paths from the porting plan.
- Dependencies on prior completed tasks and their outcomes.
- "This is a porting task. Read the source implementation before exploring options."

`explore-critique-implement` handles coding-style loading per its own prerequisites.

Task ordering from Phase 5 is mandatory — do not parallelize tasks with dependencies.

Independent tasks (no dependency relationship) may run in parallel via `agent-teams-execution`.

## Escalation

| Trigger | Action |
|---------|--------|
| Phase 5 loop exhausted (3 iterations) | Present best plan + unresolved issues to user |
| `explore-critique-implement` hard escalation | Report to user per that skill's escalation protocol |
| Feature extraction agent produces empty list | Verify scope with user before proceeding |
| Gap analysis finds all features already present | Report to user — nothing to port |

## Red flags

| Symptom | Fix |
|---------|-----|
| Main thread implementing instead of spawning agents | Stop. Main thread orchestrates only |
| Same agent doing extraction + gap analysis | Banned. Separate agents per phase |
| Feature list suspiciously short (<5 entries for non-trivial source) | Re-spawn extractor with "you are under-listing" |
| Critique agrees with everything | Re-spawn with harsher prompt: "zero survivors is valid" |
| Meta-critique rubber-stamps the critique | Re-spawn: "the critic may be wrong — prove it or prove they're right" |
| Skipping Phase 4 (meta-critique) | Never skip. Single-critic bias is the failure mode this prevents |
| Plan designer ignoring critic feedback in loop | Include critic feedback verbatim in 5a re-prompt |
| Implementation skipping `explore-critique-implement` | Every porting task uses the full skill. No raw implementation |
| User requirements lost in subagent prompts | Propagate original requirements verbatim to every agent |

## Relationship to other skills

| Skill | Relationship |
|-------|-------------|
| `explore-critique-implement` | Phase 7 delegates each porting task to this skill. Full review gate per change. |
| `agent-teams-execution` | Use for parallel independent porting tasks in Phase 7. |
| `harness-tuning` | Apply when the porting target is a skill file, system prompt, or CODEX.md. |
| `superpowers:brainstorming` | Use before this skill if user intent is unclear (what to port, why). |
| `proof-driven-development` | Invoked inside `explore-critique-implement` for logic-bearing ported code. |
