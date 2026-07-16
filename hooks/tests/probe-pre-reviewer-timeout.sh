#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/pre-reviewer-real-timeout.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT HUP INT TERM

formal_executable="${CODEX_PRE_REVIEWER_FORMAL_EXE:-}"
formal_stamp="${CODEX_PRE_REVIEWER_FORMAL_STAMP:-}"
if [ -z "$formal_executable" ] || [ -z "$formal_stamp" ]; then
  printf '%s\n' \
    'pre-reviewer timeout formal artifact identity is not configured' >&2
  exit 1
fi
if ! "$ROOT/hooks/tests/differential/pre-reviewer-controller.sh" \
    --verify-artifact "$formal_executable" "$formal_stamp"; then
  printf 'pre-reviewer timeout formal artifact identity rejected: executable=%s stamp=%s\n' \
    "$formal_executable" "$formal_stamp" >&2
  exit 1
fi

started_ns="$(date +%s%N)"
python3 "$ROOT/hooks/tests/pre_reviewer_lifecycle.py" \
  --root "$ROOT" \
  --lean "$formal_executable" \
  --artifact-root "$TMP_ROOT/artifacts" \
  --scenario real-timeout >"$TMP_ROOT/result"
elapsed_ms=$((($(date +%s%N) - started_ns) / 1000000))
[ "$elapsed_ms" -lt 75000 ]

trace="$TMP_ROOT/artifacts/real-timeout/strace"
controller_pid="$(awk '/fcntl\(0, F_DUPFD_CLOEXEC, 300\)/ {print $1; exit}' "$trace")"
[ -n "$controller_pid" ]
grep -Eq 'pidfd_send_signal\([^,]+, SIGTERM' "$trace"
! grep -Eq "^${controller_pid}[[:space:]].*(kill|killpg)\\(" "$trace"
grep -Eq '^real-timeout[[:space:]]+0 0 0 1 1 1' "$TMP_ROOT/result"

printf 'real timeout compatibility: elapsed_ms=%s exact-source pidfd cancellation and reap passed\n' "$elapsed_ms"
