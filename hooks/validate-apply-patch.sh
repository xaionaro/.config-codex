#!/usr/bin/env bash
# PreToolUse hook: validate file edits made through apply_patch.

set -euo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HOOK_DIR/lib/codex-proof-state.sh"
. "$HOOK_DIR/lib/codex-tmp.sh"
codex_init_tmp || true
codex_install_fail_open_trap validate-apply-patch

input=$(cat)
session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)

patch_text=$(printf '%s' "$input" | jq -r '.tool_input.command // .tool_input.patch // .tool_input.input // empty' 2>/dev/null || true)

[ -n "$patch_text" ] || exit 0

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

if codex_hook_is_subagent_context "$input"; then
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    resolved_path="$(codex_resolve_hook_path "${cwd:-$PWD}" "$path" 2>/dev/null || true)"
    if [ -n "$resolved_path" ] && codex_path_is_session_ledger_file "$resolved_path"; then
      deny "Only the main thread may modify session ledger file ${path##*/}."
    fi
  done <<<"$patch_paths"
fi

if printf '%s\n' "$patch_paths" | grep -Eq '(^|/)docs/(superpowers/)?plans/'; then
  deny 'Do not edit plan files under docs/plans or docs/superpowers/plans from normal implementation flow. Use the active plan/checklist instead.'
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
while IFS= read -r path; do
  [ -n "$path" ] || continue
  owner_session_id="$(codex_path_owner_session_id "$path" 2>/dev/null || true)"
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

while IFS= read -r path; do
  [ -n "$path" ] || continue
  codex_note_touched_repo "$session_id" "$cwd" "$path" || true
done <<<"$patch_paths"

if ! codex_hook_is_subagent_context "$input"; then
  codex_mark_activity "$session_id" "$cwd" edit || true
fi
