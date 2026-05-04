---
name: harness-tuning
description: Use when writing, reviewing, shortening, tightening, deduplicating, or compressing any skill file, system prompt, subagent prompt, or CODEX.md — including when asked to "fix" or "improve" a prompt file.
---

# Harness Tuning

Every token costs context window in every session. Waste is cumulative.

**Core rule:** Every word earns its place. Removing a word doesn't change behavior? Remove it.

## Principles

| # | Rule | Example |
|---|------|---------|
| 1 | One idea per sentence | Split compounds. Cut conjunctions. |
| 2 | Rule first, not reasoning | "Never push without approval" not "Because pushing can cause..." |
| 3 | Tables over prose | Rows scan; paragraphs don't. |
| 4 | No filler | Cut: "It is important to", "Make sure to", "In order to" |
| 5 | Define once, reference elsewhere | Rule in table AND prose AND red flags? Keep table. |
| 6 | Imperatives | "Tag all claims" not "All teammates should tag their claims" |
| 7 | Specific over abstract | "Reject bare `uint64`" not "Ensure strong typing" |
| 8 | Examples compress | One precise example replaces a paragraph. |

## Anti-Patterns

| Verbose | Concise |
|---------|---------|
| "must make sure to always verify that..." | "verifies..." |
| "It is important to note that this is non-negotiable" | (delete) |
| "In the event that a teammate fails to respond" | "Teammate unresponsive:" |
| "Each and every factual claim must be tagged" | "Tag all claims" |
| "Before marking any task as complete, they must verify against..." | "Before marking done:" |

## Triggering (frontmatter `description`)

Always-loaded. Optimize for match, not compression.

| Rule | Example |
|------|---------|
| First 6 words carry the trigger | `Use when writing or shortening...` not `This skill helps when...` |
| List verbs users actually say | `writing, reviewing, shortening, fixing` — cover synonyms |
| Enumerate file types + aliases | `skill file, SKILL.md, system prompt, CODEX.md` |
| Name the failure the skill prevents | `...ensures every word earns its place` |

Bad → good:
- `description: helps with prompts` → `description: Use when writing, reviewing, or shortening skill files, system prompts, CODEX.md`
- `description: for skill authoring` → `description: Use when writing or editing any SKILL.md, agent prompt, or CODEX.md — including "fix this prompt" and "tighten this"`

## Targets

No fixed word budget. The target is marginal value per word: every rule, every example, every sentence must change reader behavior. A 3000-word skill that eliminates repeated failures earns its length; a 200-word skill with filler does not.

Test: 20%+ word reduction with same rules = better version.

## Process

1. Write content.
2. Each sentence: "Does this change behavior?" No -> delete.
3. Deduplicate. Keep most scannable version (table > list > prose).
4. 3+ parallel items -> table.
5. Repeat 2-4 until no further cut preserves all rules.

## Red Flags

| Symptom | Fix |
|---------|-----|
| Same rule in 3+ places | Keep one |
| "It is" / "There are" opener | Imperative |
| Prose restating a table | Delete prose |
| "Must should always" stacking | One verb |
| +10% words, no new rules | Revert |
