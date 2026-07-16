#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/pre-reviewer-timeout-probe.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT HUP INT TERM
mkdir -p "$TMP_ROOT/hooks/lib"
cp "$ROOT/hooks/edit-bash-pre-reviewer.sh" "$TMP_ROOT/hooks/"
worker="$TMP_ROOT/hooks/lib/edit-bash-pre-reviewer-worker.sh"

cat >"$worker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "$CODEX_TEST_WORKER_MODE" in
  success) printf 'complete' ;;
  failure) printf 'partial'; exit 9 ;;
  signal)
    printf '%s:%s\n' "$PPID" "$(ps -o pgid= -p "$PPID" | tr -d ' ')" >"$CODEX_TEST_LEADER"
    printf '%s\n' "$$" >"$CODEX_TEST_WORKER"
    sleep 30 &
    child=$!
    printf '%s\n' "$child" >"$CODEX_TEST_CHILD"
    kill -TERM "$CODEX_TEST_CONTROLLER_PID"
    wait "$child"
    ;;
esac
SH
chmod 0644 "$worker"

out="$TMP_ROOT/out"
CODEX_TEST_WORKER_MODE=success bash "$TMP_ROOT/hooks/edit-bash-pre-reviewer.sh" \
  </dev/null >"$out"
[ "$(cat "$out")" = complete ]
CODEX_TEST_WORKER_MODE=failure bash "$TMP_ROOT/hooks/edit-bash-pre-reviewer.sh" \
  </dev/null >"$out"
[ ! -s "$out" ]

trace="$TMP_ROOT/trace"
log="$TMP_ROOT/watchdog.log"
CODEX_TEST_WORKER_MODE=signal CODEX_TEST_LEADER="$TMP_ROOT/leader" \
  CODEX_TEST_WORKER="$TMP_ROOT/worker" CODEX_TEST_CHILD="$TMP_ROOT/child" \
  CODEX_TEST_CONTROLLER="$TMP_ROOT/controller" \
  python3 "$ROOT/hooks/tests/process-watchdog.py" --timeout 10 --log "$log" -- \
  strace -f -qq -e trace=kill,wait4,waitid -o "$trace" \
  bash -c 'printf "%s\n" "$$" >"$CODEX_TEST_CONTROLLER"; export CODEX_TEST_CONTROLLER_PID=$$; exec bash "$1"' \
    bash "$TMP_ROOT/hooks/edit-bash-pre-reviewer.sh"

IFS=: read -r leader leader_pgid <"$TMP_ROOT/leader"
controller_pid="$(cat "$TMP_ROOT/controller")"
worker_pid="$(cat "$TMP_ROOT/worker")"
child_pid="$(cat "$TMP_ROOT/child")"
[ "$leader" = "$leader_pgid" ]
grep -Eq "kill\(-$leader, SIGTERM" "$trace"
grep -Eq "kill\(-$leader, SIGKILL" "$trace"
grep -Eq "^$controller_pid .*wait4.* = $leader$|^$controller_pid .*waitid\(P_PID, $leader," "$trace"

synthetic_pid_absent() {
  local pid="$1"
  local attempt

  for ((attempt = 0; attempt < 50; attempt++)); do
    ! kill -0 "$pid" 2>/dev/null && return 0
    sleep 0.02
  done
  ! kill -0 "$pid" 2>/dev/null
}

synthetic_pid_absent "$leader"
synthetic_pid_absent "$worker_pid"
synthetic_pid_absent "$child_pid"
printf '%s\n' 'timeout compatibility: uutils 0.2.2; success/failure/PGID/negative-signal/exact-leader wait probe passed'
