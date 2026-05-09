#!/usr/bin/env bash
# PreToolUse hook: validate direct file edits made through Edit, Write, and MultiEdit.

set -euo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HOOK_DIR/lib/codex-proof-state.sh"

input=$(cat)
tool_name=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || true)
session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)

case "$tool_name" in
  Edit|Write|MultiEdit) ;;
  *) exit 0 ;;
esac

if ! codex_hook_is_subagent_context "$input"; then
  codex_mark_activity "$session_id" "$cwd" edit || true
fi

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

file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.path // .tool_input.target_file // empty' 2>/dev/null || true)

[ -n "$file_path" ] || exit 0

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
esac

if printf '%s\n' "$file_path" | grep -Eq '(^|/)go\.mod$' &&
   printf '%s\n' "$edit_text" | grep -Eq '=>[[:space:]]*(\.\./|\./)'; then
  deny 'Do not add local relative replace directives to go.mod. Use a workspace, module proxy, or explicit user-approved local override.'
fi
