#!/usr/bin/env bash
# PreToolUse hook: validate direct file edits made through Edit, Write, MultiEdit, and NotebookEdit.

set -euo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HOOK_DIR/lib/codex-proof-state.sh"
. "$HOOK_DIR/lib/codex-tmp.sh"
. "$HOOK_DIR/lib/eci-diagnostic.sh"
codex_init_tmp || true
codex_install_fail_open_trap validate-edit-write

input=$(cat)
tool_name=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || true)
session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)

case "$tool_name" in
  Edit|Write|MultiEdit|NotebookEdit) ;;
  *) exit 0 ;;
esac

deny() {
  local reason="${1:-unspecified edit validation denial}"
  if [[ "$reason" != \[ECI_* ]]; then
    local subject
    subject="tool=${tool_name:-Edit},path=$(eci_diagnostic_value "${file_path:-<missing>}"),session=$(eci_diagnostic_value "${session_id:-<missing>}"),cwd=$(eci_diagnostic_value "${cwd:-<missing>}")"
    reason="$(eci_diagnostic_reason "$(eci_diagnostic_code_for_reason "$reason")" "PreToolUse" "edit-validation" "$subject" "$reason" "correct the reported edit target or route the change through the approved source/coordinator path, then retry")"
  fi
  jq -n --arg reason "$reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
}

file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // .tool_input.path // .tool_input.target_file // empty' 2>/dev/null || true)

[ -n "$file_path" ] || exit 0

# This hook runs synchronously for every editor invocation.  Resolve the
# thread ownership once instead of reparsing transcript metadata in both the
# control-file guard and the activity bookkeeping branch.
hook_is_subagent=false
if codex_hook_is_subagent_context "$input"; then
  hook_is_subagent=true
fi

resolved_file_path="$(codex_resolve_hook_path "${cwd:-$PWD}" "$file_path" 2>/dev/null || true)"
lexical_file_path="$(codex_lexical_hook_path "${cwd:-$PWD}" "$file_path" 2>/dev/null || true)"
if [ -n "$resolved_file_path" ] &&
   [ "$hook_is_subagent" = true ] &&
   { control_alias=false
     if [ -n "$lexical_file_path" ] && codex_path_is_eci_control_alias "$lexical_file_path"; then
       control_alias=true
     elif [ "$resolved_file_path" != "$lexical_file_path" ] &&
          codex_path_is_eci_control_alias "$resolved_file_path"; then
       control_alias=true
     fi
     codex_path_is_session_ledger_file "$resolved_file_path" ||
     codex_path_is_eci_control_file "$lexical_file_path" ||
     codex_path_is_eci_control_file "$resolved_file_path" ||
     [ "$control_alias" = true ] ||
     codex_path_is_git_approval_file "$lexical_file_path" ||
     codex_path_is_git_approval_file "$resolved_file_path"; }; then
  deny "$(eci_diagnostic_reason "ECI_CONTROL_OWNER_REQUIRED" "PreToolUse" "edit-validation" "$file_path" "Only the main thread may modify coordinator-owned ECI control state." "route coordinator-owned ECI control changes through the main/orchestrator")"
fi

# Session ownership is a concrete target check only when both the target owner
# and the callback's allowed session set resolve.  Unavailable metadata is an
# advisory limitation, not a reason to deny an ordinary edit.
owner_probe="${lexical_file_path:-$file_path}"
owner_session_id="$(codex_path_owner_session_id "$owner_probe" 2>/dev/null || true)"
[ -n "$owner_session_id" ] || owner_session_id="$(codex_path_owner_session_id "${resolved_file_path:-$file_path}" 2>/dev/null || true)"
if [ -n "$owner_session_id" ]; then
  mapfile -t allowed_session_ids < <(codex_hook_allowed_session_ids "$input")
  if [ "${#allowed_session_ids[@]}" -gt 0 ] &&
    ! codex_session_owner_allowed "$owner_session_id" "${allowed_session_ids[@]}"; then
    deny "Refusing to edit ${file_path##*/}: file belongs to session $owner_session_id, allowed sessions are ${allowed_session_ids[*]}."
  fi
fi

eci_direct_marker="$(codex_proof_root)/${session_id}/eci_active"
if [ ! -f "$eci_direct_marker" ] || [ -L "$eci_direct_marker" ]; then
  codex_note_touched_repo "$session_id" "$cwd" "$file_path" || true
  if [ "$hook_is_subagent" != true ]; then
    codex_mark_activity "$session_id" "$cwd" edit || true
  fi
fi
