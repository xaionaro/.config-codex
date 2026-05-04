#!/usr/bin/env bash
# PreToolUse hook: lead/coordinator roles orchestrate; they do not edit.

set -euo pipefail

input=$(cat)
tool_name=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || true)

case "$tool_name" in
  apply_patch|Edit|Write|MultiEdit) ;;
  *) exit 0 ;;
esac

case "${CODEX_ROLE:-}" in
  lead|coordinator)
    jq -n --arg role "$CODEX_ROLE" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: ("CODEX_ROLE=" + $role + " is an orchestration role. Assign edits to an executor/worker role instead of editing directly.")
      }
    }'
    ;;
esac
