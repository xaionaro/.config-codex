#!/usr/bin/env bash
# PreToolUse hook: block direct main-session edits while ECI is active.

set -euo pipefail

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
case "$session_id" in
  ""|*[!A-Za-z0-9_-]*) exit 0 ;;
esac

root="${CODEX_PROOF_ROOT:-$HOME/.cache/codex-proof}"
marker="$root/$session_id/eci_active"
[ -f "$marker" ] || exit 0

marker_text=$(cat "$marker" 2>/dev/null || true)
jq -n --arg reason "ECI is active for this session. Route edits through the implementer role, or disengage with ~/.codex/bin/eci-active off <disengage-report.md>. Marker: $marker_text" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $reason
  }
}'
