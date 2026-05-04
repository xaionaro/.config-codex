#!/usr/bin/env bash
# PreToolUse hook: validate direct file edits made through Edit, Write, and MultiEdit.

set -euo pipefail

input=$(cat)
tool_name=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || true)

case "$tool_name" in
  Edit|Write|MultiEdit) ;;
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

file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.path // .tool_input.target_file // empty' 2>/dev/null || true)

[ -n "$file_path" ] || exit 0

if printf '%s\n' "$file_path" | grep -Eq '(^|/)docs/(superpowers/)?plans/'; then
  deny 'Do not edit plan files under docs/plans or docs/superpowers/plans from normal implementation flow. Use the active plan/checklist instead.'
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
