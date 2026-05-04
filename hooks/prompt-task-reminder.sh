#!/usr/bin/env bash
# UserPromptSubmit hook: add concise Codex-native task reminders.

set -euo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HOOK_DIR/lib/codex-proof-state.sh"

input=$(cat)
session_id=$(printf '%s' "$input" | jq -r 'if (.session_id? | type) == "string" then .session_id else "" end' 2>/dev/null || true)
cwd=$(printf '%s' "$input" | jq -r 'if (.cwd? | type) == "string" then .cwd else "" end' 2>/dev/null || true)
root="$(codex_proof_root)"

if codex_valid_session_id "$session_id"; then
  reviewer_dir="$root/reviewer/$session_id"
  mkdir -p "$reviewer_dir"
  head=$(git -C "$HOME/.codex" rev-parse HEAD 2>/dev/null || true)
  if [ -n "$head" ]; then
    printf '%s\n' "$head" >"$reviewer_dir/prompt_head"
  fi
  rm -f "$reviewer_dir/bypass" "$root/pre-reviewer/$session_id/bypass"
fi

eci_marker=$(codex_existing_state_file eci eci_active "$session_id" "$cwd" 2>/dev/null || true)

context=$(cat <<'EOF'
Codex task reminder:
- For nontrivial requests or discovered issues, call update_plan and keep it current.
- Check and load matching ~/.codex/skills before work.
- Size orchestration deliberately: ECI for uncertain or correctness-heavy work; ATE for independent parallel work.
- If dedicated agents are explicitly required, use standard spawn_agent only; no shell-launched agents, no codex-as-role.
- Tag review, completion, and verification claims T1-T5.
- If an ECI marker is active, main thread must not edit code directly.
EOF
)

if [ -n "$eci_marker" ] && [ -f "$eci_marker" ]; then
  marker_text=$(cat "$eci_marker")
  context=$(printf '%s\n\nECI active marker:\n%s\n\nECI active: main thread must not edit code directly.' "$context" "$marker_text")
fi

jq -n --arg ctx "$context" '{
  hookSpecificOutput: {
    hookEventName: "UserPromptSubmit",
    additionalContext: $ctx
  }
}'
