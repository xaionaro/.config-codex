#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TMP_PARENT="${CODEX_TMPDIR:-${HOME:?HOME must be set}/tmp}"
mkdir -p -- "$TMP_PARENT"
TEST_ROOT="$(mktemp -d "$TMP_PARENT/eci-active-sync-runtime-local-first.XXXXXX")"
trap 'rm -rf -- "$TEST_ROOT"' EXIT HUP INT TERM

TEST_HOME="$TEST_ROOT/home"
SOURCE_CODEX="$TEST_HOME/.codex"
TARGET_CODEX="$TEST_ROOT/deployed/.codex"
SOURCE_ECI="$SOURCE_CODEX/bin/eci-active"
OUTPUT="$TEST_ROOT/sync-runtime-output"

mkdir -p -- "$TEST_HOME/tmp" "$SOURCE_CODEX" "$TEST_ROOT/deployed"
cp -a -- "$ROOT/bin" "$SOURCE_CODEX/"
cp -a -- "$ROOT/hooks" "$SOURCE_CODEX/"
cp -- "$ROOT/hooks.json" "$SOURCE_CODEX/hooks.json"
cp -a -- "$SOURCE_CODEX" "$TARGET_CODEX"

# Prove that a real local runtime publish is required, rather than merely a
# source receipt update. Kimi is deliberately absent from this fixture.
printf '%s\n' 'stale local runtime target' >"$TARGET_CODEX/hooks/validate-bash.sh"
rm -f -- "$SOURCE_CODEX/.eci-runtime-sync-manifest" \
  "$TARGET_CODEX/.eci-runtime-sync-manifest"

if ! env -u KIMI_CODE_HOME \
  HOME="$TEST_HOME" CODEX_RUNTIME_ROOTS="$TARGET_CODEX" \
  "$SOURCE_ECI" sync-runtime >"$OUTPUT" 2>&1; then
  printf 'sync-runtime should succeed when the Kimi peer is unavailable:\n' >&2
  cat -- "$OUTPUT" >&2
  exit 1
fi

cmp -- "$SOURCE_CODEX/hooks/validate-bash.sh" "$TARGET_CODEX/hooks/validate-bash.sh"
[ -f "$SOURCE_CODEX/.eci-runtime-sync-manifest" ] && [ ! -L "$SOURCE_CODEX/.eci-runtime-sync-manifest" ]
[ -f "$TARGET_CODEX/.eci-runtime-sync-manifest" ] && [ ! -L "$TARGET_CODEX/.eci-runtime-sync-manifest" ]
grep -Fq 'ECI runtime synchronization complete: provider=codex' "$OUTPUT"
grep -Fq 'ECI runtime peer synchronization advisory:' "$OUTPUT"

printf '%s\n' 'eci-active sync-runtime local-first: PASS'
