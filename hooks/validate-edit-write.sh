#!/usr/bin/env bash
# PreToolUse hook: validate direct file edits made through Edit, Write, MultiEdit, and NotebookEdit.

set -euo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HOOK_DIR/lib/codex-proof-state.sh"
. "$HOOK_DIR/lib/codex-tmp.sh"
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
  jq -n --arg reason "$1" '{
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

resolved_file_path="$(codex_resolve_hook_path "${cwd:-$PWD}" "$file_path" 2>/dev/null || true)"
if [ -n "$resolved_file_path" ] &&
   codex_hook_is_subagent_context "$input" &&
   codex_path_is_session_ledger_file "$resolved_file_path"; then
  deny "Only the main thread may modify session ledger file ${file_path##*/}."
fi

ownership_failure_deny() {
  local reason="ownership check failed; failing closed for session-scoped path safety"
  jq -n --arg reason "$reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
}

trap 'ownership_failure_deny' ERR
owner_session_id="$(codex_path_owner_session_id "$file_path" 2>/dev/null || true)"
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

codex_note_touched_repo "$session_id" "$cwd" "$file_path" || true

if ! codex_hook_is_subagent_context "$input"; then
  codex_mark_activity "$session_id" "$cwd" edit || true
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
