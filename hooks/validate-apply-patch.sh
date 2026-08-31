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
    control_alias=false
    if [ -n "$lexical_path" ] && codex_path_is_eci_control_alias "$lexical_path"; then
      control_alias=true
    elif [ -n "$resolved_path" ] && [ "$resolved_path" != "$lexical_path" ] &&
          codex_path_is_eci_control_alias "$resolved_path"; then
      control_alias=true
    fi
    if { codex_path_is_session_ledger_file "$resolved_path" ||
         codex_path_is_eci_control_file "$lexical_path" ||
         codex_path_is_eci_control_file "$resolved_path" ||
         [ "$control_alias" = true ] ||
         codex_path_is_git_approval_file "$lexical_path" ||
         codex_path_is_git_approval_file "$resolved_path"; }; then
      deny "$(eci_diagnostic_reason "ECI_CONTROL_OWNER_REQUIRED" "PreToolUse" "patch-validation" "$path" "Only the main thread may modify coordinator-owned ECI control state." "route coordinator-owned ECI control changes through the main/orchestrator")"
    fi
  done <<<"$patch_paths"
fi

# Session ownership is a concrete target check only when both the target owner
# and the callback's allowed session set resolve.  A probe failure leaves this
# child advisory; it must not deny an ordinary repository patch.
while IFS= read -r path; do
  [ -n "$path" ] || continue
  lexical_owner_path="$(codex_lexical_hook_path "${cwd:-$PWD}" "$path" 2>/dev/null || true)"
  resolved_owner_path="$(codex_resolve_hook_path "${cwd:-$PWD}" "$path" 2>/dev/null || true)"
  # Ordinary repository paths have no session owner to resolve.  Skip the
  # metadata probe unless the target is actually under a proof root.
  if ! codex_path_is_under_proof_root "$lexical_owner_path" &&
     ! codex_path_is_under_proof_root "${resolved_owner_path:-}"; then
    continue
  fi
  owner_probe="${lexical_owner_path:-$path}"
  owner_session_id="$(codex_path_owner_session_id "$owner_probe" 2>/dev/null || true)"
  [ -n "$owner_session_id" ] || owner_session_id="$(codex_path_owner_session_id "${resolved_owner_path:-$path}" 2>/dev/null || true)"
  [ -n "$owner_session_id" ] || continue
  mapfile -t allowed_session_ids < <(codex_hook_allowed_session_ids "$input")
  if [ "${#allowed_session_ids[@]}" -gt 0 ] &&
    ! codex_session_owner_allowed "$owner_session_id" "${allowed_session_ids[@]}"; then
    deny "Refusing to edit ${path##*/}: file belongs to session $owner_session_id, allowed sessions are ${allowed_session_ids[*]}."
  fi
done <<<"$patch_paths"

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
