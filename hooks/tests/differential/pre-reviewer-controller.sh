#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
labels=(preflight-failure success worker-failure signal accelerated-timeout)
expected=(
  "0 0 0 0 0 0"
  "1 1 0 0 0 0"
  "0 1 0 0 0 0"
  "0 1 0 0 1 1"
  "0 1 0 0 1 1"
)

if [ "${CODEX_TEST_SKIP_LEAN_BUILD:-}" = 1 ]; then
  [ -x "$ROOT/proofs/.lake/build/bin/preReviewerControllerDiff" ]
else
  build_log="$(mktemp "${TMPDIR:-/tmp}/pre-reviewer-lean-build.XXXXXX")"
  trap 'rm -f "$build_log"' EXIT HUP INT TERM
  if ! python3 "$ROOT/hooks/tests/process-watchdog.py" \
      --timeout 180 --log "$build_log" --cwd "$ROOT/proofs" -- \
      lake build preReviewerControllerDiff; then
    cat "$build_log" >&2
    exit 1
  fi
fi
mapfile -t actual < <("$ROOT/proofs/.lake/build/bin/preReviewerControllerDiff" "${labels[@]}")
[ "${actual[*]}" = "${expected[*]}" ]
printf 'pre reviewer controller differential cases: %s\n' "${#labels[@]}"
