#!/usr/bin/env bash

set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/pre-reviewer-profile.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT HUP INT TERM

samples=5

profile_case() {
  local label="$1"
  shift
  local index started ended elapsed values sorted median
  values=""
  for ((index = 0; index < samples; index++)); do
    started="$(date +%s%N)"
    "$@"
    ended="$(date +%s%N)"
    elapsed=$(((ended - started) / 1000000))
    values+=" $elapsed"
  done
  sorted="$(printf '%s\n' $values | sort -n | tr '\n' ' ')"
  median="$(printf '%s\n' $values | sort -n | sed -n '3p')"
  printf '%-18s median=%4sms samples_ms=[%s]\n' "$label" "$median" "${sorted% }"
}

missing_id() {
  printf '%s' '{"session_id":"profile","tool_name":"Bash","tool_input":{"command":"true"}}' |
    HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$TMP_ROOT/proof-missing" \
      bash "$ROOT/hooks/edit-bash-pre-reviewer.sh" >/dev/null
}

valid_no_capture() {
  printf '%s' '{"session_id":"profile","turn_id":"turn","tool_name":"Bash","tool_input":{"command":"true"}}' |
    HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$TMP_ROOT/proof-no-capture" \
      bash "$ROOT/hooks/edit-bash-pre-reviewer.sh" >/dev/null
}

prompt_capture() {
  printf '%s' '{"session_id":"profile","hook_event_name":"UserPromptSubmit","cwd":".","turn_id":"turn","prompt":"profile"}' |
    HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$TMP_ROOT/proof-prompt-$RANDOM" \
      bash "$ROOT/hooks/prompt-task-reminder.sh" >/dev/null
}

fake_review() {
  local proof="$TMP_ROOT/proof-review-$RANDOM"
  printf '%s' '{"session_id":"profile","hook_event_name":"UserPromptSubmit","cwd":".","turn_id":"turn","prompt":"profile"}' |
    HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof" \
      bash "$ROOT/hooks/prompt-task-reminder.sh" >/dev/null
  printf '%s' '{"session_id":"profile","turn_id":"turn","tool_name":"Bash","tool_input":{"command":"true"}}' |
    HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof" \
      CODEX_EDIT_PRE_REVIEWER='ollama:http://127.0.0.1:11434:qwen3:4b' \
      CODEX_PRE_REVIEWER_FAKE_RESULT='{"verdict":"allow","reason":"profile"}' \
      bash "$ROOT/hooks/edit-bash-pre-reviewer.sh" >/dev/null
}

concurrent_pair() {
  valid_no_capture &
  local first=$!
  valid_no_capture &
  local second=$!
  wait "$first"
  wait "$second"
}

printf 'Synthetic pre-reviewer phase profile (%s samples each)\n' "$samples"
profile_case missing-id missing_id
profile_case valid-no-capture valid_no_capture
profile_case prompt prompt_capture
profile_case fake-reviewer fake_review
profile_case concurrent-pair concurrent_pair
printf '%s\n' 'Attribution: missing-ID/no-capture emphasize controller+early-worker phases; prompt and fake-reviewer add state/backend work.'
printf '%s\n' 'Displayed hook-row count is event history, not a count of concurrently active hook work.'
printf '%s\n' 'The controller requests TERM/KILL for its owned process group and reaps the timeout leader. Synthetic responsive descendants were absent after cleanup; uninterruptible members may outlive controller return.'
