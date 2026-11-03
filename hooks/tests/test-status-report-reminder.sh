#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
command="$(jq -er '.hooks.UserPromptSubmit[0].hooks[0].command' "$root/hooks.json")"

check_reminder() {
  local prompt="$1" output
  output="$(jq -cn --arg prompt "$prompt" '{session_id:"bad/session",prompt:$prompt}' | bash -c "$command")"
  jq -e '.hookSpecificOutput.hookEventName == "UserPromptSubmit" and (.hookSpecificOutput.additionalContext | contains("status-report render"))' <<<"$output" >/dev/null
}
check_reminder 'status'
check_reminder 'Give me a proper status report'
check_reminder 'Can you give me a progress report?'
check_reminder 'Status report, please.'
check_reminder "What's the status?"
printf '%s\n' 'python3() { return 1; }' 'export -f python3' >"$tmp/fail-capture"
output="$(jq -cn '{session_id:"valid-session",turn_id:"turn",prompt:"status"}' | BASH_ENV="$tmp/fail-capture" bash -c "$command")"
jq -e '.hookSpecificOutput.additionalContext | contains("status-report render")' <<<"$output" >/dev/null
output="$(jq -cn '{session_id:"bad/session",prompt:"Fix the status report renderer"}' | bash -c "$command")"
[[ -z "$output" ]]
printf '%s\n' 'Status-report reminder tests: PASS'
