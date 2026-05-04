#!/usr/bin/env bash
# PreToolUse hook: validate Bash commands before execution.

set -euo pipefail

input=$(cat)

case "$input" in
  *"go test"*) ;;
  *) exit 0 ;;
esac

command=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)

if ! printf '%s' "$command" | grep -qE '(^|[^A-Za-z0-9_-])go[[:space:]]+test\b'; then
  exit 0
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

if printf '%s' "$command" | grep -qE '\-count[= ]1\b'; then
  deny 'Do not pass -count=1 to go test; it defeats the test cache. Re-run without -count=1.'
fi

if ! printf '%s' "$command" | grep -qE '([12&]?>>?|\|[[:space:]]*tee\b)'; then
  deny 'go test output must be captured to a file to avoid overrunning context. Example: go test ./... > /tmp/go-test.log 2>&1; then inspect the log with tail/head/grep.'
fi
