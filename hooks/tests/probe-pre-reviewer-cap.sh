#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/pre-reviewer-cap.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT HUP INT TERM

result="$TMP_ROOT/result"
"$ROOT/hooks/tests/differential/pre-reviewer-controller.sh" \
  --artifact-root "$TMP_ROOT/artifacts" \
  --scenario exact-cap \
  --scenario over-cap-valid \
  --scenario oversize-open >"$result"

grep -Eq '^exact-cap[[:space:]]+1 1 1 1 1 0' "$result"
grep -Eq '^over-cap-valid[[:space:]]+0 0 0 1 1 0' "$result"
grep -Eq '^oversize-open[[:space:]]+0 0 0 1 1 0' "$result"
printf '%s\n' 'capped capture: exact cap published; valid cap+1 and open oversize failed open'
