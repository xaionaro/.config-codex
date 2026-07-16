#!/usr/bin/env bash
# Bounded controller for the first-tool-call admission reviewer.

set -uo pipefail

readonly CONTROLLER_TIMEOUT=70
readonly CONTROLLER_KILL_AFTER=2
case "${BASH_SOURCE[0]}" in
  */*) controller_source_dir="${BASH_SOURCE[0]%/*}" ;;
  *) controller_source_dir=. ;;
esac
HOOK_DIR="$(cd -P -- "$controller_source_dir" 2>/dev/null && pwd)" || exit 0
worker="$HOOK_DIR/lib/edit-bash-pre-reviewer-worker.sh"

if [ "${CODEX_EDIT_PRE_REVIEWER_TIMEOUT+x}" = x ]; then
  backend_timeout="$CODEX_EDIT_PRE_REVIEWER_TIMEOUT"
else
  backend_timeout=60
fi
[[ "$backend_timeout" =~ ^([1-9]|[1-5][0-9]|60)$ ]] || exit 0

case "${BASH:-}" in
  /*) [ -f "$BASH" ] && [ -x "$BASH" ] || exit 0 ;;
  *) exit 0 ;;
esac
[ -f "$worker" ] && [ -r "$worker" ] || exit 0

resolve_controller_command() {
  local name="$1"
  local resolved

  resolved="$(type -P -- "$name" 2>/dev/null)" || return 1
  case "$resolved" in
    /*) ;;
    *) return 1 ;;
  esac
  [ -f "$resolved" ] && [ -x "$resolved" ] || return 1
  printf '%s\n' "$resolved"
}

timeout_command="$(resolve_controller_command timeout)" || exit 0
mktemp_command="$(resolve_controller_command mktemp)" || exit 0
chmod_command="$(resolve_controller_command chmod)" || exit 0
cat_command="$(resolve_controller_command cat)" || exit 0
rm_command="$(resolve_controller_command rm)" || exit 0
readonly timeout_command mktemp_command chmod_command cat_command rm_command
export CODEX_EDIT_PRE_REVIEWER_TIMEOUT="$backend_timeout"

controller_buffer=""
controller_stdin_fd=""
controller_leader=""
controller_cleanup_done=0

cleanup_controller() {
  [ "$controller_cleanup_done" -eq 0 ] || return 0
  controller_cleanup_done=1
  trap - EXIT HUP INT TERM

  if [ -n "$controller_stdin_fd" ]; then
    exec {controller_stdin_fd}>&- 2>/dev/null || true
    controller_stdin_fd=""
  fi
  if [ -n "$controller_leader" ]; then
    kill -TERM -- "-$controller_leader" 2>/dev/null || true
    kill -KILL -- "-$controller_leader" 2>/dev/null || true
    wait "$controller_leader" 2>/dev/null || true
    controller_leader=""
  fi
  if [ -n "$controller_buffer" ]; then
    "$rm_command" -f -- "$controller_buffer" 2>/dev/null || true
    controller_buffer=""
  fi
}

trap cleanup_controller EXIT
trap 'cleanup_controller; exit 0' HUP INT TERM

controller_buffer="$($mktemp_command "${TMPDIR:-/tmp}/.edit-pre-reviewer.XXXXXX" 2>/dev/null)" || exit 0
"$chmod_command" 0600 "$controller_buffer" 2>/dev/null || exit 0
exec {controller_stdin_fd}<&0 2>/dev/null || exit 0

"$timeout_command" --signal=TERM --kill-after="${CONTROLLER_KILL_AFTER}s" \
  "${CONTROLLER_TIMEOUT}s" "$BASH" "$worker" \
  <&"$controller_stdin_fd" >"$controller_buffer" 2>/dev/null &
controller_leader=$!
exec {controller_stdin_fd}>&-
controller_stdin_fd=""

controller_status=0
wait "$controller_leader" || controller_status=$?
controller_leader=""
if [ "$controller_status" -eq 0 ]; then
  "$cat_command" "$controller_buffer" 2>/dev/null || true
fi

# The controller requests TERM/KILL for its owned process group and reaps the
# timeout leader. Synthetic responsive descendants were absent after cleanup;
# uninterruptible members may outlive controller return. The nominal 70-to-75
# gap can be reduced by startup, preflight, scheduling, signals, and reaping.
exit 0
