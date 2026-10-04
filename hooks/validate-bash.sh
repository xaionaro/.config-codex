#!/usr/bin/env bash
# Recover the ignored executable on first use; command policy lives in Go.
set -euo pipefail
case "${HOME:-}" in ''|!/*) exit 0 ;; esac
root="$HOME/.codex"
[ -d "$root" ] || exit 0
binary="$root/hooks/lib/eci-command-plan-go/eci-command-plan"
if [ ! -x "$binary" ]; then
  source "$root/hooks/lib/eci-runtime-sync.sh" || exit 0
  eci_runtime_build_missing "$root" eci-command-plan || exit 0
fi
exec "$binary" --hook
