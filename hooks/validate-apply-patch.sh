#!/usr/bin/env bash
# PreToolUse hook: validate file edits made through apply_patch.

set -euo pipefail

input=$(cat)
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

if printf '%s\n' "$patch_paths" | grep -Eq '(^|/)docs/(superpowers/)?plans/'; then
  deny 'Do not edit plan files under docs/plans or docs/superpowers/plans from normal implementation flow. Use the active plan/checklist instead.'
fi

if printf '%s\n' "$patch_paths" | grep -Eq '(^|/)go\.mod$' &&
   printf '%s\n' "$patch_text" | grep -Eq '^\+replace[[:space:]].*=>[[:space:]]*(\.\./|\./)'; then
  deny 'Do not add local relative replace directives to go.mod. Use a workspace, module proxy, or explicit user-approved local override.'
fi
