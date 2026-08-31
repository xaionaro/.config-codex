#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TMP_BASE="$(realpath -e -- "${CODEX_TMPDIR:-${HOME:?}/tmp}")"
case "$TMP_BASE" in
  /tmp|/tmp/*|/) printf 'planner fd handoff test: unsafe temporary root: %s\n' "$TMP_BASE" >&2; exit 1 ;;
esac
TMP_ROOT="$(mktemp -d "$TMP_BASE/eci-planner-fd-handoff.XXXXXX")"
trap 'rm -rf -- "$TMP_ROOT"' EXIT HUP INT TERM

planner="$TMP_ROOT/eci-command-plan"
replacement="$TMP_ROOT/eci-command-plan.replacement"

printf '%s\n' '#!/usr/bin/env bash' 'printf pinned-planner' >"$planner"
printf '%s\n' '#!/usr/bin/env bash' 'printf replacement-planner' >"$replacement"
chmod 755 -- "$planner" "$replacement"

# A path replacement after validation must not change the executable selected
# for this callback. The descriptor remains inherited by the child process,
# so /proc/self/fd/N executes the original inode rather than the new pathname.
exec {planner_fd}<"$planner"
mv -- "$replacement" "$planner"
[ "$(/proc/self/fd/"$planner_fd")" = pinned-planner ] || {
  printf '%s\n' 'planner fd handoff executed the replacement rather than the pinned inode' >&2
  exit 1
}
[ "$("$planner")" = replacement-planner ] || {
  printf '%s\n' 'planner fd handoff fixture did not replace the planner pathname' >&2
  exit 1
}
closed_fd="$planner_fd"
exec {planner_fd}<&-
[ ! -e "/proc/self/fd/$closed_fd" ] || {
  printf '%s\n' 'planner fd handoff did not close the inherited descriptor' >&2
  exit 1
}

# Keep the hook contract explicit: active validated planners execute only via
# the inherited descriptor, and the descriptor is closed after classification.
grep -Fq 'CODEX_PLAN_PROVENANCE_EXECUTABLE="/proc/self/fd/$CODEX_PLAN_PROVENANCE_FD"' \
  "$ROOT/hooks/validate-bash.sh" || {
  printf '%s\n' 'validate-bash does not expose the pinned planner descriptor handoff' >&2
  exit 1
}
grep -Fq '"$command_plan_executable" 2>/dev/null' "$ROOT/hooks/validate-bash.sh" || {
  printf '%s\n' 'validate-bash does not execute the planner through its pinned handoff' >&2
  exit 1
}
grep -Fq 'codex_plan_provenance_close_pinned_binary' "$ROOT/hooks/validate-bash.sh" || {
  printf '%s\n' 'validate-bash does not close the pinned planner descriptor' >&2
  exit 1
}
pin_line="$(grep -n -F 'codex_plan_provenance_pin_binary "$binary" "$planner_dir_real/eci-command-plan" "$uid"' "$ROOT/hooks/validate-bash.sh" | cut -d: -f1)"
execute_line="$(grep -n -F '"$command_plan_executable" 2>/dev/null' "$ROOT/hooks/validate-bash.sh" | cut -d: -f1)"
close_line="$(grep -n -x 'codex_plan_provenance_close_pinned_binary' "$ROOT/hooks/validate-bash.sh" | tail -n 1 | cut -d: -f1)"
[[ "$pin_line" =~ ^[0-9]+$ ]] && [[ "$execute_line" =~ ^[0-9]+$ ]] && [[ "$close_line" =~ ^[0-9]+$ ]] &&
  [ "$pin_line" -lt "$execute_line" ] && [ "$execute_line" -lt "$close_line" ] || {
    printf '%s\n' 'validate-bash does not pin before planner execution and close afterward' >&2
    exit 1
  }

printf '%s\n' 'ECI planner fd handoff: PASS'
