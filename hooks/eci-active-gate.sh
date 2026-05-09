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

if codex_hook_is_subagent_context "$input"; then
  exit 0
fi

tool_paths() {
  case "$tool_name" in
    apply_patch)
      printf '%s' "$input" |
        jq -r '.tool_input.command // .tool_input.patch // .tool_input.input // empty' 2>/dev/null |
        awk '
          /^\*\*\* (Add|Update|Delete) File: / {
            sub(/^\*\*\* (Add|Update|Delete) File: /, "")
            print
          }
          /^\*\*\* Move to: / {
            sub(/^\*\*\* Move to: /, "")
            print
          }
        '
      ;;
    Edit|Write|MultiEdit)
      printf '%s' "$input" |
        jq -r '.tool_input.file_path // .tool_input.path // .tool_input.target_file // empty' 2>/dev/null
      ;;
  esac
}

markdown_only_edit() {
  local path
  local seen=false

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    seen=true
    case "$path" in
      *.[mM][dD]|*.[mM][aA][rR][kK][dD][oO][wW][nN]) ;;
      *) return 1 ;;
    esac
  done

  [ "$seen" = "true" ]
}

if tool_paths | markdown_only_edit; then
  exit 0
fi

session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)
[ -z "$cwd" ] && cwd="$PWD"

marker=$(codex_existing_state_file eci eci_active "$session_id" "$cwd" 2>/dev/null || true)
[ -f "$marker" ] || exit 0
codex_note_state_session_id "$marker" "$session_id" || true

marker_text=$(cat "$marker" 2>/dev/null || true)
jq -n --arg reason "ECI is active for this session. Never stop until the ECI task is complete. Continue the ECI task, or report a blocker requiring user input while ECI remains active. Disengage only with clean-pass or user-closed via ~/.codex/bin/eci-active off <disengage-report.md>. Marker: $marker_text" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $reason
  }
}'
