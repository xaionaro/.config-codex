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
check_reminder 'Fix the renderer and give me a status report'
check_reminder 'Give me a status report on the status report renderer'
check_reminder 'Fix the status report renderer, then show me the current progress'
check_reminder 'Provide a progress update for the renderer'
check_reminder 'Show me a status report, then fix the renderer'
printf '%s\n' 'python3() { return 1; }' 'export -f python3' >"$tmp/fail-capture"
output="$(jq -cn '{session_id:"valid-session",turn_id:"turn",prompt:"status"}' | BASH_ENV="$tmp/fail-capture" bash -c "$command")"
jq -e '.hookSpecificOutput.additionalContext | contains("status-report render")' <<<"$output" >/dev/null
printf '%s\n' 'python3() { /usr/bin/python3 "$@"; }' 'export -f python3' >"$tmp/use-python"
output="$(jq -cn '{session_id:"valid-session",turn_id:"turn",prompt:"status"}' | CODEX_PROOF_ROOT="$tmp/proof" BASH_ENV="$tmp/use-python" bash -c "$command")"
jq -e '.hookSpecificOutput.additionalContext | contains("status-report render")' <<<"$output" >/dev/null
capture="$(find "$tmp/proof/pre-reviewer/valid-session" -name 'capture-turn-*.json' -type f -print -quit)"
[[ -n "$capture" ]]
jq -e '.turn_id == "turn" and .prompt == "status"' "$capture" >/dev/null
for prompt in 'Fix the status report renderer' 'provide a fix for the status report renderer' 'show me how status report renderer works' 'Show me a status report renderer implementation' 'Provide a status report renderer fix' 'Show me a status report template' 'Write a status report regression test' 'Provide a progress report schema'; do
  output="$(jq -cn --arg prompt "$prompt" '{session_id:"bad/session",prompt:$prompt}' | bash -c "$command")"
  [[ -z "$output" ]]
done
for invalid in nul utf8 multiple; do
  case "$invalid" in
    nul) printf '{"prompt":"status"}\0' >"$tmp/input" ;;
    utf8) printf '{"prompt":"status"}\377' >"$tmp/input" ;;
    multiple) printf '%s\n' '{"prompt":"status"}' '{}' >"$tmp/input" ;;
  esac
  output="$(bash -c "$command" <"$tmp/input")"
  [[ -z "$output" ]]
done
printf '%s\n' 'Status-report reminder tests: PASS'
