#!/usr/bin/env bash
# PreToolUse hook: block direct main-session edits while ECI is active.

set -euo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HOOK_DIR/lib/codex-proof-state.sh"

input=$(cat)
tool_name=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || true)

case "$tool_name" in
  apply_patch|Edit|Write|MultiEdit) ;;
  *) exit 0 ;;
esac

case "${CODEX_ROLE:-}" in
  eci-implementer|executor|test-executor) exit 0 ;;
esac

session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)
[ -z "$cwd" ] && cwd="$PWD"

marker=$(codex_existing_state_file eci eci_active "$session_id" "$cwd" 2>/dev/null || true)
[ -f "$marker" ] || exit 0
codex_note_state_session_id "$marker" "$session_id" || true

marker_text=$(cat "$marker" 2>/dev/null || true)
jq -n --arg reason "ECI is active for this session. Route edits through the implementer role, or disengage with ~/.codex/bin/eci-active off <disengage-report.md>. Marker: $marker_text" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $reason
  }
}'
