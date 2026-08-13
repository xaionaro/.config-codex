#!/usr/bin/env bash

# Lightweight contract/timing probe for the active-ECI stop path.  This is
# intentionally independent of the full formal hooks harness.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/codex-eci-fast.XXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT

proof_root="$tmp/proof"
home="$tmp/home"
mkdir -p "$proof_root/t00-session" "$home/tmp"
printf '%s\n' 'scope: fast-path probe' >"$proof_root/t00-session/eci_active"

input="$tmp/input.json"
out="$tmp/out.json"
jq -n --arg cwd "$ROOT" '{session_id:"t00-session", transcript_path:"", stop_hook_active:false, cwd:$cwd}' >"$input"

run_once() {
  env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$proof_root" \
    bash "$ROOT/hooks/stop-gate.sh" <"$input" >"$out"
  [ "$(jq -r '.decision // empty' "$out")" = block ]
}

max_ms=0
for _ in $(seq 1 5); do
  start_ns="$(date +%s%N)"
  run_once
  elapsed_ms=$(( ($(date +%s%N) - start_ns) / 1000000 ))
  [ "$elapsed_ms" -gt "$max_ms" ] && max_ms="$elapsed_ms"
done

# The active path must not create/update recovery state or generic callback
# counters.  The only proof-root file is the marker itself.
[ ! -e "$proof_root/t00-session/stop_timestamps" ]
[ "$(find "$proof_root" -type f ! -name eci_active -print -quit)" = "" ]

if command -v strace >/dev/null 2>&1; then
  trace="$tmp/trace"
  strace -f -qq -e trace=file -o "$trace" \
    env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$proof_root" \
    bash "$ROOT/hooks/stop-gate.sh" <"$input" >"$out"
  ! grep -Eq 'O_(WRONLY|RDWR|CREAT|TRUNC)|mkdir\(|rename\(|unlink\(' "$trace"
fi

# Each fresh callback stays below one second on the supported fast path;
# this is a measurement, not a timeout or a runtime guard.
[ "$max_ms" -lt 1000 ]
printf 'PASS active ECI fast path: 5 callbacks, max %sms; no recovery-state writes\n' "$max_ms"
