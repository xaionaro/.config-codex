#!/usr/bin/env bash
# Preflight and execute the binary-safe first-tool-call reviewer controller.

set -uo pipefail

case "${BASH_SOURCE[0]}" in
  */*) controller_source_dir="${BASH_SOURCE[0]%/*}" ;;
  *) controller_source_dir=. ;;
esac
HOOK_DIR="$(cd -P -- "$controller_source_dir" 2>/dev/null && pwd)" || exit 0
controller="$HOOK_DIR/lib/edit_bash_pre_reviewer_controller.py"
worker="$HOOK_DIR/lib/edit-bash-pre-reviewer-worker.sh"

resolve_absolute_executable() {
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

python_command="$(resolve_absolute_executable python3)" || exit 0
unshare_command="$(resolve_absolute_executable unshare)" || exit 0
case "${BASH:-}" in
  /*) bash_command="$BASH" ;;
  *) bash_command="$(resolve_absolute_executable bash)" || exit 0 ;;
esac
[ -f "$bash_command" ] && [ -x "$bash_command" ] || exit 0
[ -f "$controller" ] && [ -r "$controller" ] || exit 0
[ -f "$worker" ] && [ -r "$worker" ] || exit 0

exec "$python_command" "$controller" \
  "$unshare_command" "$bash_command" "$worker" 2>/dev/null
exit 0
