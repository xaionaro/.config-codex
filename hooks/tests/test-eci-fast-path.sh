#!/usr/bin/env bash

# Lightweight contract/timing probe for the active-ECI stop path.  This is
# intentionally independent of the full formal hooks harness.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/codex-eci-fast.XXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT

proof_root="$tmp/proof"
home="$tmp/home"
mkdir -p "$proof_root/t00-session" "$home"
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

run_concurrent() {
  local workers="$1"
  local worker_dir="$tmp/workers-$workers"
  local start_ns end_ns wall_ms worker_ms worker_max=0
  local i pid
  local -a pids=()

  mkdir -p "$worker_dir"
  start_ns="$(date +%s%N)"
  for i in $(seq 1 "$workers"); do
    (
      local_start="$(date +%s%N)"
      env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$proof_root" \
        bash "$ROOT/hooks/stop-gate.sh" <"$input" >"$worker_dir/$i.out"
      [ "$(jq -r '.decision // empty' "$worker_dir/$i.out")" = block ]
      local_end="$(date +%s%N)"
      printf '%s\n' "$(( (local_end - local_start) / 1000000 ))" >"$worker_dir/$i.ms"
    ) &
    pids+=("$!")
  done
  for pid in "${pids[@]}"; do
    wait "$pid"
  done
  end_ns="$(date +%s%N)"
  wall_ms=$(( (end_ns - start_ns) / 1000000 ))
  for i in $(seq 1 "$workers"); do
    worker_ms="$(cat "$worker_dir/$i.ms")"
    [ "$worker_ms" -gt "$worker_max" ] && worker_max="$worker_ms"
  done
  [ "$worker_max" -lt 1000 ]
  printf 'PASS active ECI concurrent fast path: %s callbacks, max %sms, wall %sms\n' \
    "$workers" "$worker_max" "$wall_ms"
}

run_concurrent 32
run_concurrent 80

# Lifecycle safety remains intentionally separate from the hook hot path:
# configured/session parent symlinks and marker symlinks must fail closed.
safety_root="$tmp/safety-root"
mkdir -p "$safety_root/real-session"
ln -s "$safety_root" "$tmp/safety-root-link"
if CODEX_PROOF_ROOT="$tmp/safety-root-link" CODEX_SESSION_ID=safety \
  "$ROOT/bin/eci-active" on "scope" >"$tmp/safety.out" 2>"$tmp/safety.err"; then
  printf 'ECI root symlink was accepted\n' >&2
  exit 1
fi
ln -s "$safety_root/real-session" "$safety_root/session-link"
if CODEX_PROOF_ROOT="$safety_root" CODEX_SESSION_ID=session-link \
  "$ROOT/bin/eci-active" on "scope" >"$tmp/session-link.out" 2>"$tmp/session-link.err"; then
  printf 'ECI session symlink was accepted\n' >&2
  exit 1
fi
mkdir -p "$safety_root/safety"
ln -s "$safety_root/real-session/eci_active" "$safety_root/safety/eci_active"
if CODEX_PROOF_ROOT="$safety_root" CODEX_SESSION_ID=safety \
  "$ROOT/bin/eci-active" status >"$tmp/status.out" 2>"$tmp/status.err"; then
  printf 'ECI status followed a marker symlink\n' >&2
  exit 1
fi
mkdir -p "$tmp/legacy-target"
printf 'scope: legacy\ncwd: %s\nsession_id: pre-reviewer\n' "$ROOT" \
  >"$tmp/legacy-target/eci_active"
ln -s "$tmp/legacy-target" "$safety_root/pre-reviewer"
CODEX_PROOF_ROOT="$safety_root" CODEX_SESSION_ID=safety2 \
  "$ROOT/bin/eci-active" on "scope" >/dev/null
[ -f "$tmp/legacy-target/eci_active" ]

# The active path must not create/update recovery state or generic callback
# counters.  The only proof-root file is the marker itself.
[ ! -e "$proof_root/t00-session/stop_timestamps" ]
[ "$(find "$proof_root" -type f ! -name eci_active -print -quit)" = "" ]
[ ! -e "$home/tmp" ]

if command -v strace >/dev/null 2>&1; then
  trace="$tmp/trace"
  strace -f -qq -e trace=process,file -o "$trace" \
    env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$proof_root" \
    bash "$ROOT/hooks/stop-gate.sh" <"$input" >"$out"
  state_writes="$(awk -v proof_root="$proof_root" -v home="$home" '
    /O_(WRONLY|RDWR|CREAT|TRUNC)|mkdir\(|rename\(|unlink\(/ &&
      (index($0, proof_root) || index($0, home)) {
      print
    }
  ' "$trace" || true)"
  if [ -n "$state_writes" ]; then
    printf 'active path performed a state write:\n' >&2
    printf '%s\n' "$state_writes" >&2
    exit 1
  fi
  ! grep -Eq 'execve\(".*/(jq|python3)"' "$trace"
fi

# Each fresh callback stays below one second on the supported fast path;
# this is a measurement, not a timeout or a runtime guard.
[ "$max_ms" -lt 1000 ]
printf 'PASS active ECI fast path: 5 callbacks, max %sms; no recovery-state writes\n' "$max_ms"
