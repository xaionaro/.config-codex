#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TMP_PARENT="${CODEX_TMPDIR:-${TMPDIR:-${HOME:?}/tmp}}"
mkdir -p -- "$TMP_PARENT"
TMP_ROOT="$(mktemp -d "$TMP_PARENT/stop-ordinary-continuation.XXXXXX")"
FIXTURE_HOME="$TMP_ROOT/home"
FIXTURE_CODEX="$FIXTURE_HOME/.codex"
REPO="$TMP_ROOT/repo"
trap 'rm -rf -- "$TMP_ROOT"' EXIT
# Smoke-test the copied PreToolUse hook bodies, removing a line-2 bypass if
# present, with any callback state confined to the private fixture.
mkdir -p -- "$FIXTURE_CODEX" "$FIXTURE_HOME/tmp" "$REPO"
cp -a -- "$ROOT/hooks" "$FIXTURE_CODEX/hooks"
cp -a -- "$ROOT/bin" "$FIXTURE_CODEX/bin"
sed -i '2{/^exit 0$/d;}' -- "$FIXTURE_CODEX/hooks/validate-bash.sh"
sed -i '2{/^exit 0$/d;}' -- "$FIXTURE_CODEX/hooks/pretooluse-edit-dispatch.sh"
(
  export HOME="$FIXTURE_HOME" CODEX_HOME="$FIXTURE_CODEX" CODEX_PROOF_ROOT="$TMP_ROOT/pretooluse-proof"
  export XDG_CONFIG_HOME="$TMP_ROOT/config" XDG_STATE_HOME="$TMP_ROOT/state" XDG_CACHE_HOME="$TMP_ROOT/cache"
  printf '%s\n' '{"tool_name":"Bash"}' | bash "$FIXTURE_CODEX/hooks/validate-bash.sh" >/dev/null
  printf '%s\n' '{"tool_name":"Edit"}' | bash "$FIXTURE_CODEX/hooks/pretooluse-edit-dispatch.sh" >/dev/null
)
printf 'PreToolUse copied-hook smoke: PASS\n'
