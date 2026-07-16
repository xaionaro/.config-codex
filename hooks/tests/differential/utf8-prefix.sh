#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/utf8-prefix-diff.XXXXXX")"
UTF8_PREFIX_HELPER="${CODEX_TEST_UTF8_PREFIX_HELPER:-$ROOT/hooks/lib/utf8_prefix_cap.py}"
trap 'rm -rf "$TMP_ROOT"' EXIT

cases=(
  ""
  "ascii"
  "$(printf '%3999s' '')é"
  "$(printf '%3998s' '')éz"
  "$(printf '%3997s' '')😀"
  "$(printf '%3996s' '')😀z"
)
suffixes=(a é 中 😀 'é中' '😀a')
seed=1729
for index in $(seq 0 23); do
  seed=$(((seed * 1103515245 + 12345) & 2147483647))
  padding=$((3968 + seed % 49))
  suffix="${suffixes[$((seed % ${#suffixes[@]}))]}"
  cases+=("$(printf "%${padding}s" '')${suffix}TAIL")
done

if [ "${CODEX_TEST_SKIP_LEAN_BUILD:-}" = 1 ]; then
  [ -x "$ROOT/proofs/.lake/build/bin/utf8PrefixDiff" ]
else
  build_log="$(mktemp "${TMPDIR:-/tmp}/utf8-prefix-lean-build.XXXXXX")"
  trap 'rm -f "$build_log"' EXIT HUP INT TERM
  python3 "$ROOT/hooks/tests/process-watchdog.py" --timeout 300 --log "$build_log" \
    --cwd "$ROOT/proofs" -- lake build utf8PrefixDiff || { cat "$build_log" >&2; exit 1; }
fi
mapfile -t lean_outputs < <(
  "$ROOT/proofs/.lake/build/bin/utf8PrefixDiff" 4000 "${cases[@]}"
)
[ "${#lean_outputs[@]}" -eq "${#cases[@]}" ]

for index in "${!cases[@]}"; do
  output="$TMP_ROOT/python-$index.out"
  printf '%s' "${cases[$index]}" | \
    python3 "$UTF8_PREFIX_HELPER" >"$output"
  [ "$(cat "$output")" = "${lean_outputs[$index]}" ]
done

printf 'UTF-8 prefix differential cases: %s\n' "${#cases[@]}"
