#!/usr/bin/env bash
# PreToolUse hook: lead/coordinator roles orchestrate; they do not edit.

set -euo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HOOK_DIR/lib/eci-diagnostic.sh"

input=$(cat)
tool_name=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || true)
session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)

case "$tool_name" in
  apply_patch|Edit|Write|MultiEdit|NotebookEdit) ;;
  *) exit 0 ;;
esac

case "${CODEX_ROLE:-}" in
  lead|coordinator)
    reason="$(eci_diagnostic_reason "ECI_ORCHESTRATOR_ROLE_DENIED" "PreToolUse" "edit-routing" "role=$(eci_diagnostic_value "$CODEX_ROLE"),tool=$(eci_diagnostic_value "$tool_name"),session=$(eci_diagnostic_value "${session_id:-<missing>}"),cwd=$(eci_diagnostic_value "${cwd:-<missing>}")" "CODEX_ROLE=$CODEX_ROLE is an orchestration role. Assign edits to an executor/worker role instead of editing directly." "assign this edit to an executor/worker role or route it through the main/orchestrator")"
    jq -n --arg reason "$reason" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: $reason
      }
    }'
    ;;
esac
