#!/usr/bin/env bash

set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$ROOT/hooks/tests/lib/formal-tmpfs.sh"

if [ -n "${CODEX_PROFILE_INTERNAL_REEXEC:-}" ]; then
  printf '%s\n' 'inherited internal profiler reexec state is forbidden' >&2
  exit 2
fi

formal_tmp_root=""
output_root=""
profiler_pid=""
wrapper_owns_formal=false
wrapper_owns_output=false
completed=false

profile_group_exists() {
  kill -0 -- "-$1" 2>/dev/null
}

stop_external_profile() {
  local requested_signal="${1:-TERM}" pid group_owned=false attempt
  pid="$profiler_pid"
  [ -n "$pid" ] || return 0
  profiler_pid=""
  if profile_group_exists "$pid"; then
    group_owned=true
    kill -s "$requested_signal" -- "-$pid" 2>/dev/null || true
  elif kill -0 "$pid" 2>/dev/null; then
    kill -s "$requested_signal" "$pid" 2>/dev/null || true
  fi
  for ((attempt = 0; attempt < 100; attempt++)); do
    if [ "$group_owned" = true ]; then
      profile_group_exists "$pid" || break
    else
      kill -0 "$pid" 2>/dev/null || break
    fi
    sleep 0.02
  done
  if [ "$group_owned" = true ]; then
    if profile_group_exists "$pid"; then
      kill -KILL -- "-$pid" 2>/dev/null || true
    fi
  elif kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
  fi
  wait "$pid" 2>/dev/null || true
}

cleanup_wrapper() {
  stop_external_profile TERM
  if [ "$wrapper_owns_formal" = true ] && [ -n "$formal_tmp_root" ]; then
    rm -rf -- "$formal_tmp_root"
  fi
  if [ "$wrapper_owns_output" = true ] && [ "$completed" = true ] &&
      [ -n "$output_root" ]; then
    rm -rf -- "$output_root"
  fi
}

handle_wrapper_signal() {
  local requested_signal="$1" signal_number="$2"
  stop_external_profile "$requested_signal"
  if [ -n "$output_root" ] && [ -d "$output_root" ]; then
    printf 'preserved profile evidence: %s\n' "$output_root" >&2
  fi
  exit "$((128 + signal_number))"
}

trap cleanup_wrapper EXIT
trap 'handle_wrapper_signal HUP 1' HUP
trap 'handle_wrapper_signal INT 2' INT
trap 'handle_wrapper_signal TERM 15' TERM

run_external_profile() {
  local formal_tmp_root="$1" output_root="$2" status=0
  python3 -c \
    'import os, sys; os.setsid(); executable = sys.executable; os.execv(executable, [executable, *sys.argv[1:]])' \
    "$ROOT/hooks/tests/profile_pre_reviewer_ab.py" "$ROOT" \
    --formal-tmp-root "$formal_tmp_root" --output-root "$output_root" &
  profiler_pid=$!
  wait "$profiler_pid" || status=$?
  profiler_pid=""
  if [ "$status" -eq 0 ]; then
    cat "$output_root/evidence/pre-reviewer-profile.out"
  fi
  return "$status"
}

if [ "$#" -eq 4 ] && [ "$1" = --formal-tmp-root ] && [ "$3" = --output-root ]; then
  formal_tmp_root="$2"
  output_root="$4"
  run_external_profile "$formal_tmp_root" "$output_root"
  exit "$?"
fi
if [ "$#" -ne 0 ]; then
  printf '%s\n' \
    'usage: profile-pre-reviewer.sh [--formal-tmp-root ABS --output-root ABS]' >&2
  exit 2
fi

status=0
formal_tmp_root="$(codex_select_formal_tmpfs_scratch)" || {
  printf '%s\n' 'private writable tmpfs is required for profiling' >&2
  exit 1
}
wrapper_owns_formal=true
output_root="$(codex_select_formal_persistent_storage)" || {
  printf '%s\n' 'private persistent evidence storage is required for profiling' >&2
  exit 1
}
wrapper_owns_output=true

run_external_profile "$formal_tmp_root" "$output_root" || status=$?
if [ "$status" -eq 0 ]; then
  completed=true
fi
if [ "$status" -ne 0 ]; then
  printf 'preserved profile evidence: %s\n' "$output_root" >&2
fi
exit "$status"
