#!/usr/bin/env bash
# Recover the ignored executable on first use; command policy lives in Go.
set -euo pipefail
case "${HOME:-}" in ''|!/*) exit 0 ;; esac
root="$HOME/.codex"
[ -d "$root" ] || exit 0
source "$root/hooks/lib/eci-runtime-sync.sh" || exit 0
binary="$(eci_runtime_artifact_path codex eci-command-plan)" || exit 0
if [ ! -f "$binary" ] || [ -L "$binary" ] || [ ! -x "$binary" ]; then
  eci_runtime_build_missing "$root" eci-command-plan || exit 0
fi
[ -f "$binary" ] && [ ! -L "$binary" ] && [ -x "$binary" ] || exit 0
exec {planner_fd}<"$binary" || exit 0
exec "/proc/self/fd/$planner_fd" --hook
