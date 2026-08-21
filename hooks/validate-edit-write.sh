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
if codex_path_is_under_proof_root "$lexical_file_path" &&
   ! codex_state_path_is_safe "$lexical_file_path" "$(codex_proof_root)" 2>/dev/null; then
  deny "Refusing unsafe session-scoped edit path ${file_path##*/}: proof-root ancestors and final components must not be symlinks."
fi
  if [ -n "$resolved_file_path" ] &&
   codex_path_is_under_proof_root "$resolved_file_path" &&
   ! codex_state_path_is_safe "$resolved_file_path" "$(codex_proof_root)" 2>/dev/null; then
  deny "Refusing unsafe resolved session-scoped edit path ${file_path##*/}: proof-root ancestors and final components must not be symlinks."
fi
if [ -n "$resolved_file_path" ] &&
   [ "$hook_is_subagent" = true ] &&
   { codex_path_is_session_ledger_file "$resolved_file_path" ||
     codex_path_is_eci_control_file "$lexical_file_path" ||
     codex_path_is_eci_control_file "$resolved_file_path" ||
     codex_path_is_eci_control_alias "$lexical_file_path" ||
     codex_path_is_eci_control_alias "$resolved_file_path" ||
     codex_path_is_git_approval_file "$lexical_file_path" ||
     codex_path_is_git_approval_file "$resolved_file_path"; }; then
  deny "$(eci_diagnostic_reason "ECI_CONTROL_OWNER_REQUIRED" "PreToolUse" "edit-validation" "$file_path" "Only the main thread may modify coordinator-owned ECI or authorization state." "route coordinator-owned ECI or authorization changes through the main/orchestrator")"
fi

ownership_failure_deny() {
  deny "ownership check failed; failing closed for session-scoped path safety (file=${BASH_SOURCE[0]},line=${BASH_LINENO[0]:-unknown},command=${BASH_COMMAND})"
}

trap 'ownership_failure_deny' ERR
owner_probe="${lexical_file_path:-$file_path}"
owner_session_id="$(codex_path_owner_session_id "$owner_probe" 2>/dev/null || true)"
[ -n "$owner_session_id" ] || owner_session_id="$(codex_path_owner_session_id "${resolved_file_path:-$file_path}" 2>/dev/null || true)"
if [ -n "$owner_session_id" ]; then
  mapfile -t allowed_session_ids < <(codex_hook_allowed_session_ids "$input")
  if [ "${#allowed_session_ids[@]}" -eq 0 ]; then
    deny "Session-scoped file ${file_path##*/} requires a current session id; none resolved. Refusing fail-open on a session-scoped path."
  fi
  if ! codex_session_owner_allowed "$owner_session_id" "${allowed_session_ids[@]}"; then
    deny "Refusing to edit ${file_path##*/}: file belongs to session $owner_session_id, allowed sessions are ${allowed_session_ids[*]}."
  fi
fi
trap - ERR
codex_install_fail_open_trap validate-edit-write

if printf '%s\n' "$file_path" | grep -Eq '(^|/)docs/(superpowers/)?plans/'; then
  deny 'Do not edit plan files under docs/plans or docs/superpowers/plans from normal implementation flow. Use the active plan/checklist instead.'
fi

if printf '%s\n' "$file_path" | grep -Eiq '(^|/)(import|imports|vendor|(3rd|third)[ _-]?party)(/|$)'; then
  deny 'Do not edit files under import/, imports/, vendor/, or any third-party/3rdparty variant directly. Edit the original source and revendor the files. Worst case: edit the originals and rsync them into the vendored dir.'
fi

# Block edits inside git submodules. A submodule is identified by a `.git`
# entry that is a FILE (gitlink) rather than a directory.
is_inside_submodule() {
  local p="$1"
  [ -n "$p" ] || return 1
  local d
  if [ -d "$p" ]; then
    d="$p"
  else
    d="$(dirname -- "$p")"
  fi
  case "$d" in
    /*) ;;
    *) d="$PWD/$d" ;;
  esac
  while [ -n "$d" ] && [ "$d" != "/" ]; do
    if [ -e "$d/.git" ]; then
      [ -f "$d/.git" ] && return 0
      return 1
    fi
    d="$(dirname -- "$d")"
  done
  return 1
}
if [ -n "$file_path" ] && is_inside_submodule "$file_path"; then
  deny 'Do not edit files inside a git submodule. Update the submodule upstream and pull, or detach with git submodule deinit if intentional.'
fi

eci_direct_marker="$(codex_proof_root)/${session_id}/eci_active"
if [ ! -f "$eci_direct_marker" ] || [ -L "$eci_direct_marker" ]; then
  codex_note_touched_repo "$session_id" "$cwd" "$file_path" || true
  if [ "$hook_is_subagent" != true ]; then
    codex_mark_activity "$session_id" "$cwd" edit || true
  fi
fi

case "$tool_name" in
  Write)
    edit_text=$(printf '%s' "$input" | jq -r '.tool_input.content // empty' 2>/dev/null || true)
    ;;
  Edit)
    edit_text=$(printf '%s' "$input" | jq -r '.tool_input.new_string // empty' 2>/dev/null || true)
    ;;
  MultiEdit)
    edit_text=$(printf '%s' "$input" | jq -r '.tool_input.edits[]? | .new_string // empty' 2>/dev/null || true)
    ;;
  NotebookEdit)
    edit_text=""
    ;;
esac

if printf '%s\n' "$file_path" | grep -Eq '(^|/)go\.mod$' &&
   printf '%s\n' "$edit_text" | grep -Eq '=>[[:space:]]*(\.\./|\./)'; then
  deny 'Do not add local relative replace directives to go.mod. Use a workspace, module proxy, or explicit user-approved local override.'
fi
