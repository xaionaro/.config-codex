#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/codex-session-refresh.XXXXXX")"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

run_snapshot() {
  local proof_root="$1"
  local input_source="$2"
  local out="$3"
  local session_id="${4:-t00-session}"

  mkdir -p "$TMP_ROOT/home/tmp" "$proof_root"
  jq -cn \
    --arg session_id "$session_id" \
    --arg source "$input_source" \
    --arg cwd "$ROOT" \
    '{session_id:$session_id, transcript_path:"/tmp/session.jsonl", cwd:$cwd, source:$source}' |
    HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" \
      bash "$ROOT/hooks/session-snapshot.sh" >"$out"
}

test_active_eci_refresh_signal_for_session_start_reminder() {
  local proof_root="$TMP_ROOT/active-proof" out
  mkdir -p "$proof_root/t00-session"
  printf '%s\n' 'scope: refresh test' >"$proof_root/t00-session/eci_active"
  out="$TMP_ROOT/active.out"

  run_snapshot "$proof_root" resume "$out"

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

test_session_start_matcher_uses_supported_lifecycle_sources() {
  jq -e '
    (.hooks.SessionStart | length > 0) and
    (.hooks.SessionStart | all(.matcher == "startup|resume|clear"))
  ' "$ROOT/hooks.json" >/dev/null
}

test_old_uuid_session_with_active_eci_marker_survives_cleanup() {
  local proof_root="$TMP_ROOT/old-uuid-proof" session_dir out
  session_dir="$proof_root/019df400-0000-7000-8000-000000000001"
  mkdir -p "$session_dir"
  printf '%s\n' 'baseline' >"$session_dir/baseline_head"
  printf '%s\n' 'scope: old active session' >"$session_dir/eci_active"
  touch -t 202001010000 "$session_dir" "$session_dir/baseline_head" "$session_dir/eci_active"
  out="$TMP_ROOT/old-uuid.out"

  run_snapshot "$proof_root" compaction "$out" 019df400-0000-7000-8000-000000000001

  [ -s "$session_dir/baseline_head" ] &&
    [ -s "$session_dir/eci_active" ] &&
    grep -q '^scope: old active session$' "$session_dir/eci_active"
}

test_old_marker_dir_with_symlink_eci_marker_is_pruned() {
  local proof_root="$TMP_ROOT/old-symlink-proof" marker_dir target out
  marker_dir="$proof_root/eci/sessions/stale-session"
  target="$TMP_ROOT/stale-eci-target"
  mkdir -p "$marker_dir"
  printf '%s\n' 'scope: stale symlink' >"$target"
  ln -s "$target" "$marker_dir/eci_active"
  touch -t 202001010000 "$marker_dir"
  out="$TMP_ROOT/old-symlink.out"

  run_snapshot "$proof_root" compaction "$out"

  [ ! -e "$marker_dir" ] && [ ! -L "$marker_dir" ] && [ -s "$target" ]
}

test_active_eci_refresh_signal_for_session_start_reminder
test_inactive_session_keeps_baseline_context
test_session_start_matcher_uses_supported_lifecycle_sources
test_old_uuid_session_with_active_eci_marker_survives_cleanup
test_old_marker_dir_with_symlink_eci_marker_is_pruned
printf '%s\n' 'session-snapshot refresh tests: PASS'
