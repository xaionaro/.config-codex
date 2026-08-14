#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/codex-session-refresh.XXXXXX")"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

run_snapshot() {
  local proof_root="$1"
  local input_source="$2"
  local out="$3"

  mkdir -p "$TMP_ROOT/home/tmp" "$proof_root"
  jq -cn \
    --arg source "$input_source" \
    --arg cwd "$ROOT" \
    '{session_id:"t00-session", transcript_path:"/tmp/session.jsonl", cwd:$cwd, source:$source}' |
    HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" \
      bash "$ROOT/hooks/session-snapshot.sh" >"$out"
}

test_active_eci_refresh_signal_for_generic_session_start() {
  local proof_root="$TMP_ROOT/active-proof" out
  mkdir -p "$proof_root/t00-session"
  printf '%s\n' 'scope: refresh test' >"$proof_root/t00-session/eci_active"
  out="$TMP_ROOT/active.out"

  run_snapshot "$proof_root" compaction "$out"

  jq -e '
    (.hookSpecificOutput.hookEventName == "SessionStart") and
    (.hookSpecificOutput.additionalContext | contains("ECI is active")) and
    (.hookSpecificOutput.additionalContext | contains("ECI refresh signal (not proof of compaction)")) and
    (.hookSpecificOutput.additionalContext | contains("re-read the entire skills/explore-critique-implement/SKILL.md")) and
    (.hookSpecificOutput.additionalContext | contains("re-invoke it before the next decision/tool"))
  ' "$out" >/dev/null
}

test_inactive_session_keeps_baseline_context() {
  local proof_root="$TMP_ROOT/inactive-proof" out
  out="$TMP_ROOT/inactive.out"

  run_snapshot "$proof_root" startup "$out"

  jq -e '
    (.hookSpecificOutput.additionalContext == "Load ~/.codex/CODEX.md and matching ~/.codex/skills when applicable.")
  ' "$out" >/dev/null
  if jq -e '.hookSpecificOutput.additionalContext | contains("ECI is active")' "$out" >/dev/null; then
    return 1
  fi
}

test_session_start_matcher_catches_any_source() {
  jq -e '
    (.hooks.SessionStart | length > 0) and
    (.hooks.SessionStart | all(.matcher == ""))
  ' "$ROOT/hooks.json" >/dev/null
}

test_active_eci_refresh_signal_for_generic_session_start
test_inactive_session_keeps_baseline_context
test_session_start_matcher_catches_any_source
printf '%s\n' 'session-snapshot refresh tests: PASS'
