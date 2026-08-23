#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOME_ROOT="${HOME:?HOME must be set}"
TMP_BASE="$(realpath -e -- "$HOME_ROOT/tmp")"
case "$TMP_BASE" in
  /tmp|/tmp/*|/) printf 'runtime-sync test: unsafe temporary root: %s\n' "$TMP_BASE" >&2; exit 1 ;;
esac
TEST_ROOT="$(mktemp -d "$TMP_BASE/eci-runtime-sync-test.XXXXXX")"
trap 'rm -rf -- "$TEST_ROOT"' EXIT HUP INT TERM

make_provider_tree() {
  local root="$1"
  mkdir -p -- "$root/.codex/bin" "$root/.codex/hooks/lib" "$root/runtime/.codex/bin" "$root/runtime/.codex/hooks/lib"
  printf '{"provider":"codex"}\n' >"$root/.codex/hooks.json"
  printf '#!/usr/bin/env bash\nprintf canonical-active\\n' >"$root/.codex/bin/eci-active"
  printf '#!/usr/bin/env bash\nprintf canonical-validator\\n' >"$root/.codex/hooks/validate-bash.sh"
  printf 'nested canonical helper\n' >"$root/.codex/hooks/lib/nested.sh"
  chmod 775 "$root/.codex/bin/eci-active" "$root/.codex/hooks/validate-bash.sh"
  chmod 664 "$root/.codex/hooks.json" "$root/.codex/hooks/lib/nested.sh"
  printf 'stale\n' >"$root/runtime/.codex/hooks.json"
  printf '#!/usr/bin/env bash\nprintf stale-active\\n' >"$root/runtime/.codex/bin/eci-active"
  printf '#!/usr/bin/env bash\nprintf stale-validator\\n' >"$root/runtime/.codex/hooks/validate-bash.sh"
  printf 'stale nested\n' >"$root/runtime/.codex/hooks/lib/nested.sh"
  chmod 600 "$root/runtime/.codex/hooks.json" "$root/runtime/.codex/hooks/lib/nested.sh"
  chmod 700 "$root/runtime/.codex/bin/eci-active" "$root/runtime/.codex/hooks/validate-bash.sh"
}

make_kimi_tree() {
  local root="$1"
  mkdir -p -- "$root/.kimi-code/bin" "$root/.kimi-code/hooks/lib" "$root/runtime/.kimi-code/bin" "$root/runtime/.kimi-code/hooks/lib"
  printf 'provider = "kimi"\n' >"$root/.kimi-code/config.toml"
  printf '#!/usr/bin/env bash\nprintf canonical-kimi-active\\n' >"$root/.kimi-code/bin/eci-active"
  printf '#!/usr/bin/env bash\nprintf canonical-kimi-validator\\n' >"$root/.kimi-code/hooks/validate-bash.sh"
  printf 'nested canonical kimi helper\n' >"$root/.kimi-code/hooks/lib/nested.sh"
  chmod 775 "$root/.kimi-code/bin/eci-active" "$root/.kimi-code/hooks/validate-bash.sh"
  chmod 664 "$root/.kimi-code/config.toml" "$root/.kimi-code/hooks/lib/nested.sh"
  printf stale >"$root/runtime/.kimi-code/config.toml"
  printf stale >"$root/runtime/.kimi-code/bin/eci-active"
  printf stale >"$root/runtime/.kimi-code/hooks/validate-bash.sh"
  printf stale >"$root/runtime/.kimi-code/hooks/lib/nested.sh"
  chmod 700 "$root/runtime/.kimi-code/bin/eci-active" "$root/runtime/.kimi-code/hooks/validate-bash.sh"
  chmod 600 "$root/runtime/.kimi-code/config.toml" "$root/runtime/.kimi-code/hooks/lib/nested.sh"
}

run_sync() {
  local provider="$1" source_root="$2" target_root="$3"
  if [ "$provider" = codex ]; then
    CODEX_HOME="$source_root/.codex" CODEX_RUNTIME_ROOTS="$target_root/.codex" \
      bash -c '. "$1/hooks/lib/eci-runtime-sync.sh"; eci_runtime_sync_run codex "$1"' _ "$ROOT"
  else
    KIMI_CODE_HOME="$source_root/.kimi-code" KIMI_RUNTIME_ROOTS="$target_root/.kimi-code" \
      bash -c '. "$1/hooks/lib/eci-runtime-sync.sh"; eci_runtime_sync_run kimi "$1"' _ "$ROOT"
  fi
}

make_provider_tree "$TEST_ROOT"
run_sync codex "$TEST_ROOT" "$TEST_ROOT/runtime"
cmp "$TEST_ROOT/.codex/hooks.json" "$TEST_ROOT/runtime/.codex/hooks.json"
cmp "$TEST_ROOT/.codex/bin/eci-active" "$TEST_ROOT/runtime/.codex/bin/eci-active"
cmp "$TEST_ROOT/.codex/hooks/validate-bash.sh" "$TEST_ROOT/runtime/.codex/hooks/validate-bash.sh"
cmp "$TEST_ROOT/.codex/hooks/lib/nested.sh" "$TEST_ROOT/runtime/.codex/hooks/lib/nested.sh"
[ -f "$TEST_ROOT/.codex/.eci-runtime-sync-manifest" ]
grep -q $'^bin/eci-active\t[0-9a-f]\{64\}\t[0-9]\+$' "$TEST_ROOT/.codex/.eci-runtime-sync-manifest"
[ "$(stat -c '%a' "$TEST_ROOT/.codex/hooks.json")" = "$(stat -c '%a' "$TEST_ROOT/runtime/.codex/hooks.json")" ]
[ -f "$TEST_ROOT/runtime/.codex/.eci-runtime-sync-manifest" ]
if find "$TEST_ROOT/runtime/.codex" -maxdepth 1 -name '.eci-runtime-sync.*' -print -quit | grep -q .; then
  printf 'runtime-sync test: transaction directory leaked after success\n' >&2
  exit 1
fi

make_kimi_tree "$TEST_ROOT/kimi"
run_sync kimi "$TEST_ROOT/kimi" "$TEST_ROOT/kimi/runtime"
cmp "$TEST_ROOT/kimi/.kimi-code/config.toml" "$TEST_ROOT/kimi/runtime/.kimi-code/config.toml"
cmp "$TEST_ROOT/kimi/.kimi-code/bin/eci-active" "$TEST_ROOT/kimi/runtime/.kimi-code/bin/eci-active"
cmp "$TEST_ROOT/kimi/.kimi-code/hooks/validate-bash.sh" "$TEST_ROOT/kimi/runtime/.kimi-code/hooks/validate-bash.sh"
cmp "$TEST_ROOT/kimi/.kimi-code/hooks/lib/nested.sh" "$TEST_ROOT/kimi/runtime/.kimi-code/hooks/lib/nested.sh"
[ -f "$TEST_ROOT/kimi/.kimi-code/.eci-runtime-sync-manifest" ]
grep -q $'^bin/eci-active\t[0-9a-f]\{64\}\t[0-9]\+$' "$TEST_ROOT/kimi/.kimi-code/.eci-runtime-sync-manifest"
[ -f "$TEST_ROOT/kimi/runtime/.kimi-code/.eci-runtime-sync-manifest" ]
[ "$ROOT/hooks/lib/eci-runtime-sync.sh" -ef "/home/pheona/.kimi-code/hooks/lib/eci-runtime-sync.sh" ]

mkdir -p -- "$TEST_ROOT/failure/.codex/bin" "$TEST_ROOT/failure/.codex/hooks/lib" "$TEST_ROOT/failure/runtime/.codex/bin" "$TEST_ROOT/failure/runtime/.codex/hooks/lib"
cp -- "$TEST_ROOT/.codex/hooks.json" "$TEST_ROOT/failure/.codex/hooks.json"
cp -- "$TEST_ROOT/.codex/bin/eci-active" "$TEST_ROOT/failure/.codex/bin/eci-active"
cp -- "$TEST_ROOT/.codex/hooks/validate-bash.sh" "$TEST_ROOT/failure/.codex/hooks/validate-bash.sh"
cp -- "$TEST_ROOT/.codex/hooks/lib/nested.sh" "$TEST_ROOT/failure/.codex/hooks/lib/nested.sh"
cp -- "$TEST_ROOT/.codex/hooks.json" "$TEST_ROOT/failure/runtime/.codex/hooks.json"
cp -- "$TEST_ROOT/.codex/bin/eci-active" "$TEST_ROOT/failure/runtime/.codex/bin/eci-active"
cp -- "$TEST_ROOT/.codex/hooks/validate-bash.sh" "$TEST_ROOT/failure/runtime/.codex/hooks/validate-bash.sh"
outside="$TEST_ROOT/failure/outside"
printf 'must remain unchanged\n' >"$outside"
ln -s -- "$outside" "$TEST_ROOT/failure/runtime/.codex/hooks/lib/nested.sh"
if run_sync codex "$TEST_ROOT/failure" "$TEST_ROOT/failure/runtime"; then
  printf 'runtime-sync test: unsafe destination was accepted\n' >&2
  exit 1
fi
grep -qx 'must remain unchanged' "$outside"
if find "$TEST_ROOT/failure/runtime/.codex" -maxdepth 1 -name '.eci-runtime-sync.*' -print -quit | grep -q .; then
  printf 'runtime-sync test: transaction directory leaked after failure\n' >&2
  exit 1
fi

if rg -n 'mktemp[^\n]*/tmp|TMPDIR=/tmp' "$ROOT/hooks/lib/eci-runtime-sync.sh"; then
  printf 'runtime-sync test: system /tmp usage found\n' >&2
  exit 1
fi

printf 'eci-runtime-sync: PASS\n'
