#!/usr/bin/env bash
# PreToolUse hook: validate file edits made through apply_patch.

set -euo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HOOK_DIR/lib/codex-proof-state.sh"
. "$HOOK_DIR/lib/codex-tmp.sh"
. "$HOOK_DIR/lib/eci-diagnostic.sh"
codex_init_tmp || true
codex_install_fail_open_trap validate-apply-patch

input=$(cat)
session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)

patch_text=$(printf '%s' "$input" | jq -r '.tool_input.command // .tool_input.patch // .tool_input.input // empty' 2>/dev/null || true)

# Resolve thread ownership once.  This hook is on the synchronous edit path;
# repeating transcript metadata parsing for each path/late bookkeeping branch
# needlessly burns the sub-second callback budget.
hook_is_subagent=false
if [[ "$input" == *'"transcript_path"'* ]] && codex_hook_is_subagent_context "$input"; then
  hook_is_subagent=true
fi

[ -n "$patch_text" ] || exit 0

deny() {
  local reason="${1:-unspecified patch validation denial}"
  if [[ "$reason" != \[ECI_* ]]; then
    local subject
    subject="tool=apply_patch,path=$(eci_diagnostic_value "${patch_paths:-<unparsed>}"),session=$(eci_diagnostic_value "${session_id:-<missing>}"),cwd=$(eci_diagnostic_value "${cwd:-<missing>}")"
    reason="$(eci_diagnostic_reason "$(eci_diagnostic_code_for_reason "$reason")" "PreToolUse" "patch-validation" "$subject" "$reason" "correct the reported patch target or route the change through the approved source/coordinator path, then retry")"
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

patch_paths=$(printf '%s\n' "$patch_text" | awk '
  /^\*\*\* (Add|Update|Delete) File: / {
    sub(/^\*\*\* (Add|Update|Delete) File: /, "")
    print
  }
  /^\*\*\* Move to: / {
    sub(/^\*\*\* Move to: /, "")
    print
  }
')

if [ "$hook_is_subagent" = true ]; then
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    resolved_path="$(codex_resolve_hook_path "${cwd:-$PWD}" "$path" 2>/dev/null || true)"
    lexical_path="$(codex_lexical_hook_path "${cwd:-$PWD}" "$path" 2>/dev/null || true)"
    if { codex_path_is_session_ledger_file "$resolved_path" ||
         codex_path_is_eci_control_file "$lexical_path" ||
         codex_path_is_eci_control_file "$resolved_path" ||
         codex_path_is_eci_control_alias "$lexical_path" ||
         codex_path_is_eci_control_alias "$resolved_path" ||
         codex_path_is_git_approval_file "$lexical_path" ||
         codex_path_is_git_approval_file "$resolved_path"; }; then
      deny "$(eci_diagnostic_reason "ECI_CONTROL_OWNER_REQUIRED" "PreToolUse" "patch-validation" "$path" "Only the main thread may modify coordinator-owned ECI or authorization state." "route coordinator-owned ECI or authorization changes through the main/orchestrator")"
    fi
  done <<<"$patch_paths"
fi

if printf '%s\n' "$patch_paths" | grep -Eq '(^|/)docs/(superpowers/)?plans/'; then
  deny 'Do not edit plan files under docs/plans or docs/superpowers/plans from normal implementation flow. Use the active plan/checklist instead.'
fi

ownership_failure_deny() {
  deny "ownership check failed; failing closed for session-scoped path safety (file=${BASH_SOURCE[0]},line=${BASH_LINENO[0]:-unknown},command=${BASH_COMMAND})"
}

trap 'ownership_failure_deny' ERR
while IFS= read -r path; do
  [ -n "$path" ] || continue
  lexical_owner_path="$(codex_lexical_hook_path "${cwd:-$PWD}" "$path" 2>/dev/null || true)"
  if codex_path_is_under_proof_root "$lexical_owner_path" &&
     ! codex_state_path_is_safe "$lexical_owner_path" "$(codex_proof_root)" 2>/dev/null; then
    deny "Refusing unsafe session-scoped patch path ${path##*/}: proof-root ancestors and final components must not be symlinks."
  fi
  resolved_owner_path="$(codex_resolve_hook_path "${cwd:-$PWD}" "$path" 2>/dev/null || true)"
  if [ -n "$resolved_owner_path" ] &&
     codex_path_is_under_proof_root "$resolved_owner_path" &&
     ! codex_state_path_is_safe "$resolved_owner_path" "$(codex_proof_root)" 2>/dev/null; then
    deny "Refusing unsafe resolved session-scoped patch path ${path##*/}: proof-root ancestors and final components must not be symlinks."
  fi
  # Ordinary repository paths have no session owner to resolve.  Avoid the
  # expensive alias/session probes for them; proof-root paths already passed
  # both lexical and resolved safety checks above.
  if ! codex_path_is_under_proof_root "$lexical_owner_path" &&
     ! codex_path_is_under_proof_root "${resolved_owner_path:-}"; then
    continue
  fi
  owner_probe="${lexical_owner_path:-$path}"
  owner_session_id="$(codex_path_owner_session_id "$owner_probe" 2>/dev/null || true)"
  [ -n "$owner_session_id" ] || owner_session_id="$(codex_path_owner_session_id "${resolved_owner_path:-$path}" 2>/dev/null || true)"
  [ -n "$owner_session_id" ] || continue
  mapfile -t allowed_session_ids < <(codex_hook_allowed_session_ids "$input")
  if [ "${#allowed_session_ids[@]}" -eq 0 ]; then
    deny "Session-scoped file ${path##*/} requires a current session id; none resolved. Refusing fail-open on a session-scoped path."
  fi
  if ! codex_session_owner_allowed "$owner_session_id" "${allowed_session_ids[@]}"; then
    deny "Refusing to edit ${path##*/}: file belongs to session $owner_session_id, allowed sessions are ${allowed_session_ids[*]}."
  fi
done <<<"$patch_paths"
trap - ERR
codex_install_fail_open_trap validate-apply-patch

if printf '%s\n' "$patch_paths" | grep -Eiq '(^|/)(import|imports|vendor|(3rd|third)[ _-]?party)(/|$)'; then
  deny 'Do not edit files under import/, imports/, vendor/, or any third-party/3rdparty variant directly. Edit the original source and revendor the files. Worst case: edit the originals and rsync them into the vendored dir.'
fi

# Block patches that modify files inside a git submodule. Walk up from each
# patched path and look for a .git that is a FILE (gitlink) rather than dir.
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
while IFS= read -r path; do
  [ -n "$path" ] || continue
  if is_inside_submodule "$path"; then
    deny 'Do not edit files inside a git submodule. Update the submodule upstream and pull, or detach with git submodule deinit if intentional.'
  fi
done <<<"$patch_paths"

if printf '%s\n' "$patch_paths" | grep -Eq '(^|/)go\.mod$' &&
   printf '%s\n' "$patch_text" | grep -Eq '^\+.*=>[[:space:]]*(\.\./|\./)'; then
  deny 'Do not add local relative replace directives to go.mod. Use a workspace, module proxy, or explicit user-approved local override.'
fi

# Active ECI edit callbacks are deliberately marker-only and read-only.  Keep
# the legacy activity bookkeeping for ordinary edits, but do not take its
# lock/write path while a direct marker is active.
eci_direct_marker="$(codex_proof_root)/${session_id}/eci_active"
if [ ! -f "$eci_direct_marker" ] || [ -L "$eci_direct_marker" ]; then
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    codex_note_touched_repo "$session_id" "$cwd" "$path" || true
  done <<<"$patch_paths"
  if [ "$hook_is_subagent" != true ]; then
    codex_mark_activity "$session_id" "$cwd" edit || true
  fi
fi
