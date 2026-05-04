# Claude Port Notes

## Skill Markers

Status: not ported.

Claude source behavior:

- `/home/streaming/.claude/settings.json` wires `PostToolUse` matcher `Skill` to `/home/streaming/.claude/hooks/skill-marker-record.sh`.
- `/home/streaming/.claude/hooks/skill-marker-record.sh` reads `.tool_input.skill`, with `.tool_input.name` and `.tool_input.skill_name` fallbacks, then writes per-session marker files.
- `/home/streaming/.claude/settings.json` wires `PreToolUse` matcher `Edit|Write|MultiEdit` to `/home/streaming/.claude/hooks/skill-marker-gate.sh`.
- `/home/streaming/.claude/hooks/skill-marker-gate.sh` denies protected `Edit`, `Write`, and `MultiEdit` calls when a required skill marker is missing before the edit.

Codex probe result:

- Temporary probe `hooks/tests/skill-event-probe.sh` recorded sanitized Codex `PostToolUse` payloads under `/home/streaming/.cache/codex-proof/skill-event-probes/*.jsonl`.
- Captured `PostToolUse` tool names were `Bash` and `apply_patch`; the row count is omitted because probe cache totals can change.
- Captured `tool_input_keys` were only `["command"]`.
- No captured row exposed `tool_input.skill`, `tool_input.name`, `tool_input.skill_name`, `tool_input.skill_id`, `path`, `file_path`, `source_path`, or `uri`.
- The probe produced no `redacted_values` for watched skill/path-like keys.

Active replacement behavior:

- Skill routing remains instruction-only through `CODEX.md`, developer instructions, and each skill's trigger metadata.
- Do not add Codex `skill-marker-record` or `skill-marker-gate` scripts until a real Codex skill hook payload with identity/path fields is captured as sanitized evidence.
- Do not add a Codex `PreToolUse` skill-marker gate unless real sanitized Codex payload evidence captures the skill identity and edit target path fields needed to enforce it.
- `hooks/tests/fixtures/runtime-hook-probe-evidence.jsonl` is historical sanitized evidence only. It is not active wiring proof.
