#!/usr/bin/env bash

# Lightweight contract/timing probe for the active-ECI stop path.  This is
# intentionally independent of the full formal hooks harness.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d "${CODEX_TMPDIR:-${HOME:?}/tmp}/codex-eci-fast.XXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT

proof_root="$tmp/proof"
home="$tmp/home"
mkdir -p "$proof_root/t00-session" "$home"
printf '%s\n' \
  'scope: fast-path probe' \
  "cwd: $ROOT" \
  'session_id: t00-session' \
  'created_utc: 2026-08-15T00:00:00Z' \
  >"$proof_root/t00-session/eci_active"

input="$tmp/input.json"
out="$tmp/out.json"
jq -n --arg cwd "$ROOT" '{session_id:"t00-session", transcript_path:"", stop_hook_active:false, cwd:$cwd}' >"$input"

# The callback path must not recurse through arbitrary proof-root descendants.
# Keep this structural assertion beside a non-marker directory stress fixture.
! grep -Fq 'find "$root" -mindepth 2 -maxdepth 2 -print0' "$ROOT/hooks/stop-gate.sh"
grep -Fq 'find "$root" -mindepth 2 -maxdepth 2 -name eci_active -print0' "$ROOT/hooks/stop-gate.sh"
grep -Fq 'eci_stop_max_markers=' "$ROOT/hooks/stop-gate.sh"
! grep -Fq 'find "$root" -mindepth 1 -maxdepth 1 -print0' "$ROOT/hooks/stop-gate.sh"
! grep -Fq 'for marker in "$root"/*/eci_active' "$ROOT/hooks/stop-gate.sh"
non_marker_root="$tmp/non-marker-root"
mkdir -p "$non_marker_root"
for i in $(seq 1 2000); do
  mkdir -p "$non_marker_root/t00-no-marker-$i"
done
jq -n --arg cwd "$ROOT" \
  '{session_id:"t00-no-marker-caller",transcript_path:"",stop_hook_active:false,cwd:$cwd}' >"$input"
timeout 1s env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$non_marker_root" \
  bash "$ROOT/hooks/stop-gate.sh" <"$input" >"$out"
[ "$(jq -r '.continue // empty' "$out")" = true ]
jq -n --arg cwd "$ROOT" '{session_id:"t00-session", transcript_path:"", stop_hook_active:false, cwd:$cwd}' >"$input"

# An inherited helper override must not redirect Stop away from the configured
# proof root.  The canonical active marker remains authoritative.
override_root="$tmp/stop-gate-override-root"
mkdir -p "$override_root"
env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$proof_root" CODEX_STOP_GATE_ROOT="$override_root" \
  bash "$ROOT/hooks/stop-gate.sh" <"$input" >"$out"
[ "$(jq -r '.decision // empty' "$out")" = block ]
jq -e '.reason |
  contains("[ECI_STOP_ACTIVE_ECI]") and
  contains("valid and bound") and
  contains("no marker repair") and
  contains("control metadata, not a new user request") and
  contains("do not emit another final/status/question") and
  contains("do not retry or poll Stop") and
  contains("delegate the next bounded work item to a subagent") and
  contains("wait for and collect its result") and
  contains("do not finish this turn without taking that action") and
  contains("remediation: do not retry or poll Stop while the marker and normalized control state are unchanged")' "$out" >/dev/null

run_once() {
  env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$proof_root" \
    bash "$ROOT/hooks/stop-gate.sh" <"$input" >"$out"
  [ "$(jq -r '.decision // empty' "$out")" = block ]
}

# A recursive stop callback must honor the scalar stop_hook_active flag. The
# closing JSON quote is part of the field token; keep this regression on the
# lightweight path so a malformed match cannot re-enter manual bookkeeping.
recursive_input="$tmp/recursive-input.json"
recursive_out="$tmp/recursive-out.json"
mkdir -p "$proof_root/activity/sessions/recursive-session"
printf '%s\n' 'created_utc: probe' >"$proof_root/activity/sessions/recursive-session/shell"
jq -n --arg cwd "$ROOT" \
  --arg transcript "$home/tmp/nonexistent-codex-transcript.jsonl" \
  '{session_id:"recursive-session", transcript_path:$transcript, stop_hook_active:true, cwd:$cwd}' \
  >"$recursive_input"
env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_TMPDIR="$tmp/recursive-tmp" CODEX_PROOF_ROOT="$proof_root" \
  bash "$ROOT/hooks/stop-gate.sh" <"$recursive_input" >"$recursive_out"
[ "$(jq -r '.continue // empty' "$recursive_out")" = true ]
[ ! -e "$proof_root/activity/sessions/recursive-session/shell" ]

max_ms=0
for _ in $(seq 1 5); do
  start_ns="$(date +%s%N)"
  run_once
  elapsed_ms=$(( ($(date +%s%N) - start_ns) / 1000000 ))
  [ "$elapsed_ms" -gt "$max_ms" ] && max_ms="$elapsed_ms"
done
[ "$max_ms" -lt 1000 ]

run_concurrent() {
  local workers="$1"
  local worker_dir="$tmp/workers-$workers"
  local start_ns end_ns wall_ms worker_ms worker_max=0 batch_size
  local i pid
  local -a pids=()

  mkdir -p "$worker_dir"
  # Keep the probe itself from saturating a small CI host: 80 total callbacks
  # still exercise concurrent waves, while each callback's wall time remains
  # a useful latency signal rather than scheduler queue time.
  batch_size=32
  start_ns="$(date +%s%N)"
  for i in $(seq 1 "$workers"); do
    (
      local_start="$(date +%s%N)"
      env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$proof_root" \
        bash "$ROOT/hooks/stop-gate.sh" <"$input" >"$worker_dir/$i.out"
      local_end="$(date +%s%N)"
      printf '%s\n' "$(( (local_end - local_start) / 1000000 ))" >"$worker_dir/$i.ms"
      [ "$(jq -r '.decision // empty' "$worker_dir/$i.out")" = block ]
    ) &
    pids+=("$!")
    if [ "${#pids[@]}" -ge "$batch_size" ]; then
      for pid in "${pids[@]}"; do
        wait "$pid"
      done
      pids=()
    fi
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
  # Concurrent wall time includes scheduler queueing.  Keep it as a bounded
  # liveness check; the serial probe above is the configured-chain <1s gate.
  [ "$wall_ms" -lt 10000 ]
  printf 'PASS active ECI concurrent fast path: %s callbacks, max %sms, wall %sms\n' \
    "$workers" "$worker_max" "$wall_ms"
}

run_concurrent 32
run_concurrent 80

# Lifecycle safety remains intentionally separate from the hook hot path:
# proof-root, session, and marker symlinks must fail closed; a stable cache
# parent symlink is the supported deployment layout tested below.
safety_root="$tmp/safety-root"
mkdir -p "$safety_root/real-session"
ln -s "$safety_root" "$tmp/safety-root-link"
if CODEX_PROOF_ROOT="$tmp/safety-root-link" CODEX_SESSION_ID=safety \
  "$ROOT/bin/eci-active" on "scope" >"$tmp/safety.out" 2>"$tmp/safety.err"; then
  printf 'ECI root symlink was accepted\n' >&2
  exit 1
fi

# A symlinked cache parent is valid when the final proof-root directory is
# regular and resolves to a directory. Both CLI activation and the stop hook
# must accept this normal deployment layout.
cache_target="$tmp/cache-target"
cache_link="$tmp/cache-link"
mkdir -p "$cache_target/proof"
ln -s "$cache_target" "$cache_link"
CODEX_PROOF_ROOT="$cache_link/proof" CODEX_SESSION_ID=cache-session \
  "$ROOT/bin/eci-active" on "cache-parent scope" >"$tmp/cache-on.out"
[ -f "$cache_target/proof/cache-session/eci_active" ]
cache_input="$tmp/cache-input.json"
cache_out="$tmp/cache-out.json"
jq -n --arg cwd "$ROOT" \
  '{session_id:"cache-session",transcript_path:"",stop_hook_active:false,cwd:$cwd}' >"$cache_input"
env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$cache_link/proof" \
  bash "$ROOT/hooks/stop-gate.sh" <"$cache_input" >"$cache_out"
[ "$(jq -r '.decision // empty' "$cache_out")" = block ]
jq -n --arg cwd "$ROOT" \
  '{session_id:"cache-empty",transcript_path:"",stop_hook_active:false,cwd:$cwd}' >"$cache_input"
env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$cache_link/proof" \
  bash "$ROOT/hooks/stop-gate.sh" <"$cache_input" >"$cache_out"
[ "$(jq -r '.continue // empty' "$cache_out")" = true ]

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

# Scope validation must reject LF without command-substitution newline loss.
scope_root="$tmp/scope-root"
mkdir -p "$scope_root/scope-session"
if CODEX_PROOF_ROOT="$scope_root" CODEX_SESSION_ID=scope-session \
  "$ROOT/bin/eci-active" on $'line one\nline two' >"$tmp/scope.out" 2>"$tmp/scope.err"; then
  printf 'ECI newline scope was accepted\n' >&2
  exit 1
fi
[ ! -e "$scope_root/scope-session/eci_active" ]

long_scope_root="$tmp/long-scope-root"
mkdir -p "$long_scope_root/long-session"
long_scope="$(head -c 5000 /dev/zero | tr '\0' x)"
if CODEX_PROOF_ROOT="$long_scope_root" CODEX_SESSION_ID=long-session \
  "$ROOT/bin/eci-active" on "$long_scope" >"$tmp/long-scope.out" 2>"$tmp/long-scope.err"; then
  printf 'ECI oversized scope was accepted\n' >&2
  exit 1
fi
[ ! -e "$long_scope_root/long-session/eci_active" ]

partial_root="$tmp/partial-marker-root"
mkdir -p "$partial_root/partial-session"
partial_marker="$partial_root/partial-session/eci_active"
printf '%s\n' 'scope: pre-existing partial marker' >"$partial_marker"
if CODEX_PROOF_ROOT="$partial_root" CODEX_SESSION_ID=partial-session \
  "$ROOT/bin/eci-active" on "replacement must not occur" >"$tmp/partial.out" 2>"$tmp/partial.err"; then
  printf 'ECI activation replaced a pre-existing marker\n' >&2
  exit 1
fi
[ "$(cat "$partial_marker")" = 'scope: pre-existing partial marker' ]
[ ! -e "$partial_marker.tmp" ]

mkdir -p "$safety_root/reviewer"
printf 'scope: bad\tc0\ncwd: %s\nsession_id: reviewer\n' "$ROOT" \
  >"$safety_root/reviewer/eci_active"
if CODEX_PROOF_ROOT="$safety_root" bash -c \
  '. "$1/hooks/lib/codex-proof-state.sh"; codex_legacy_eci_markers_for_cwd "$2"' \
  bash "$ROOT" "$ROOT" | grep -q .; then
  printf 'legacy control-byte marker was accepted\n' >&2
  exit 1
fi

# Stop-gate regression: unsafe own and parent markers must fail closed before
# generic json_block can create stop_timestamps or append session ownership.
stop_safety_root="$tmp/stop-safety-root"
mkdir -p "$stop_safety_root/t00-session" "$stop_safety_root/t00-parent" \
  "$stop_safety_root/side-stop/sessions/t00-side" "$tmp/stop-target"
printf 'scope: target\n' >"$tmp/stop-target/eci_active"
ln -s "$tmp/stop-target/eci_active" "$stop_safety_root/t00-session/eci_active"
stop_input="$tmp/stop-input.json"
stop_out="$tmp/stop-out.json"
jq -n --arg cwd "$ROOT" \
  '{session_id:"t00-session",transcript_path:"",stop_hook_active:false,cwd:$cwd}' >"$stop_input"
env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$stop_safety_root" \
  bash "$ROOT/hooks/stop-gate.sh" <"$stop_input" >"$stop_out"
[ "$(jq -r '.decision // empty' "$stop_out")" = block ]
jq -e '.reason | contains("[ECI_MARKER_UNSAFE_PATH]") and contains("symlink")' "$stop_out" >/dev/null
[ ! -e "$stop_safety_root/t00-session/stop_timestamps" ]
[ ! -e "$stop_safety_root/stop_timestamps" ]
[ "$(cat "$tmp/stop-target/eci_active")" = 'scope: target' ]

mkdir -p "$home/.codex/sessions"
printf '%s\n' '{"type":"session_meta","payload":{"source":{"subagent":{"thread_spawn":{"parent_thread_id":"t00-session"}}}}}' \
  >"$home/.codex/sessions/child.jsonl"
jq --arg transcript "$home/.codex/sessions/child.jsonl" \
  '.transcript_path = $transcript' "$stop_input" >"$stop_input.next"
mv "$stop_input.next" "$stop_input"
env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$stop_safety_root" \
  bash "$ROOT/hooks/stop-gate.sh" <"$stop_input" >"$stop_out"
[ "$(jq -r '.decision // empty' "$stop_out")" = block ]
[ ! -e "$stop_safety_root/t00-session/stop_timestamps" ]

printf 'command: /side\nparent_session_id: t00-parent\n' \
  >"$stop_safety_root/side-stop/sessions/t00-side/side_stop"
ln -s "$tmp/stop-target/eci_active" "$stop_safety_root/t00-parent/eci_active"
jq -n --arg cwd "$ROOT" \
  '{session_id:"t00-side",transcript_path:"",stop_hook_active:false,cwd:$cwd}' >"$stop_input"
env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$stop_safety_root" \
  bash "$ROOT/hooks/stop-gate.sh" <"$stop_input" >"$stop_out"
[ "$(jq -r '.decision // empty' "$stop_out")" = block ]
[ ! -e "$stop_safety_root/t00-side/stop_timestamps" ]
[ ! -e "$stop_safety_root/stop_timestamps" ]

# Marker ownership regression: duplicate validated owners and malformed typed
# identities must fail closed without creating recovery state.
duplicate_root="$tmp/duplicate-root"
mkdir -p "$duplicate_root/t00-one" "$duplicate_root/t00-two"
printf 'scope: one\ncwd: %s\nsession_id: t00-one\n' "$ROOT" >"$duplicate_root/t00-one/eci_active"
printf 'scope: two\ncwd: %s\nsession_id: t00-two\n' "$ROOT" >"$duplicate_root/t00-two/eci_active"
jq -n --arg cwd "$ROOT" \
  '{session_id:"t00-one",transcript_path:"",stop_hook_active:false,cwd:$cwd}' >"$stop_input"
env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$duplicate_root" \
  bash "$ROOT/hooks/stop-gate.sh" <"$stop_input" >"$stop_out"
[ "$(jq -r '.decision // empty' "$stop_out")" = block ]
[ ! -e "$duplicate_root/t00-one/stop_timestamps" ]

# A direct typed marker must not bypass duplicate-owner detection merely
# because the proof root contains many unrelated session directories.  Arm a
# valid wait state on the direct session as well: the duplicate ambiguity is
# authoritative and must retain both marker and wait state while returning a
# block.
large_duplicate_root="$tmp/large-duplicate-root"
mkdir -p "$large_duplicate_root/t00-direct" "$large_duplicate_root/t00-duplicate"
CODEX_SESSION_ID=t00-direct CODEX_PROOF_ROOT="$large_duplicate_root" \
  "$ROOT/bin/eci-active" on "direct wait probe" >"$tmp/large-duplicate-on.out" 2>&1
printf 'scope: duplicate\ncwd: %s\nsession_id: t00-duplicate\n' "$ROOT" \
  >"$large_duplicate_root/t00-duplicate/eci_active"
for i in $(seq 1 2000); do
  mkdir -p "$large_duplicate_root/t00-unrelated-$i"
done
large_wait_report="$(realpath -m -- "$large_duplicate_root/t00-direct/eci_user_owned_wait.md")"
{
  printf '# ECI User-Owned Wait\n'
  printf 'state: user-owned-wait\n'
  printf 'blocker_id: fast-path-duplicate\n'
  printf 'state_fingerprint: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'
  printf 'owner: user\n'
  printf 'brp_result: exhausted-no-feasible-internal-path\n'
  printf 'user_owned_input: unobtainable\n'
  printf 'unblock_kind: input\n'
  printf 'unblock: user-owned input required\n'
} >"$large_wait_report"
CODEX_SESSION_ID=t00-direct CODEX_PROOF_ROOT="$large_duplicate_root" \
  "$ROOT/bin/eci-active" wait "$large_wait_report" >"$tmp/large-duplicate-wait.out" 2>&1
jq -n --arg cwd "$ROOT" \
  '{session_id:"t00-direct",transcript_path:"",stop_hook_active:false,cwd:$cwd}' >"$stop_input"
env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$large_duplicate_root" \
  bash "$ROOT/hooks/stop-gate.sh" <"$stop_input" >"$stop_out"
[ "$(jq -r '.decision // empty' "$stop_out")" = block ]
[ -s "$large_duplicate_root/t00-direct/eci_active" ]
[ -s "$large_duplicate_root/t00-direct/eci_wait" ]
[ ! -e "$large_duplicate_root/t00-direct/stop_timestamps" ]

invalid_identity_root="$tmp/invalid-identity-root"
mkdir -p "$invalid_identity_root/t00-one"
printf 'scope: active\ncwd: %s\nsession_id: t00-one\n' "$ROOT" >"$invalid_identity_root/t00-one/eci_active"
jq -n --arg cwd "$ROOT" \
  '{session_id:"invalid!",transcript_path:"",stop_hook_active:false,cwd:$cwd}' >"$stop_input"
env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$invalid_identity_root" \
  bash "$ROOT/hooks/stop-gate.sh" <"$stop_input" >"$stop_out"
[ "$(jq -r '.decision // empty' "$stop_out")" = block ]
jq -e '.reason | contains("[ECI_MARKER_SCOPE_MISMATCH]") and contains("session/cwd binding")' "$stop_out" >/dev/null

# The active-marker scan has a fixed resource bound.  Valid markers for other
# cwds must not turn an oversized proof root into an unbounded callback.
overflow_root="$tmp/overflow-root"
mkdir -p "$overflow_root"
for i in $(seq 1 65); do
  overflow_sid="t00-overflow-$i"
  mkdir -p "$overflow_root/$overflow_sid"
  printf 'scope: overflow\ncwd: /other/cwd\nsession_id: %s\n' "$overflow_sid" \
    >"$overflow_root/$overflow_sid/eci_active"
done
jq -n --arg cwd "$ROOT" \
  '{session_id:"invalid!",transcript_path:"",stop_hook_active:false,cwd:$cwd}' >"$stop_input"
env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$overflow_root" \
  bash "$ROOT/hooks/stop-gate.sh" <"$stop_input" >"$stop_out"
[ "$(jq -r '.decision // empty' "$stop_out")" = block ]
[ ! -e "$overflow_root/t00-overflow-caller/stop_timestamps" ]

# A single oversized marker is also unsafe before metadata validation.
oversized_root="$tmp/oversized-root"
mkdir -p "$oversized_root/t00-oversized"
{
  printf 'scope: '
  head -c 5000 /dev/zero | tr '\0' x
  printf '\ncwd: /other/cwd\nsession_id: t00-oversized\n'
} >"$oversized_root/t00-oversized/eci_active"
jq -n --arg cwd "$ROOT" \
  '{session_id:"invalid!",transcript_path:"",stop_hook_active:false,cwd:$cwd}' >"$stop_input"
env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$oversized_root" \
  bash "$ROOT/hooks/stop-gate.sh" <"$stop_input" >"$stop_out"
[ "$(jq -r '.decision // empty' "$stop_out")" = block ]
[ ! -e "$oversized_root/t00-oversized-caller/stop_timestamps" ]
if CODEX_SESSION_ID=t00-oversized CODEX_PROOF_ROOT="$oversized_root" \
    "$ROOT/bin/eci-active" status >"$tmp/oversized-status.out" 2>"$tmp/oversized-status.err"; then
  printf 'oversized marker was read by eci-active status\n' >&2
  exit 1
fi

# A bounded but malformed direct marker must retain its concrete path and
# classify the content failure as ECI_MARKER_MALFORMED, not as an ambiguous
# proof-root scan failure.
malformed_direct_root="$tmp/malformed-direct-root"
mkdir -p "$malformed_direct_root/t00-malformed"
malformed_direct_marker="$malformed_direct_root/t00-malformed/eci_active"
printf '%s\n' 'scope: malformed direct marker' >"$malformed_direct_marker"
jq -n --arg cwd "$ROOT" \
  '{session_id:"t00-malformed",transcript_path:"",stop_hook_active:false,cwd:$cwd}' >"$stop_input"
env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$malformed_direct_root" \
  bash "$ROOT/hooks/stop-gate.sh" <"$stop_input" >"$stop_out"
[ "$(jq -r '.decision // empty' "$stop_out")" = block ]
jq -e --arg marker "$malformed_direct_marker" \
  '.reason | contains("[ECI_MARKER_MALFORMED]") and contains($marker) and (contains("[ECI_STOP_MARKER_SCAN_UNSAFE]") | not)' \
  "$stop_out" >/dev/null
[ ! -e "$malformed_direct_root/t00-malformed/stop_timestamps" ]

# A duplicate identity key must not be resolved by the first regex match. The
# active-marker path performs one strict object/duplicate/type check and blocks
# without creating callback bookkeeping.
duplicate_json_root="$tmp/duplicate-json-root"
mkdir -p "$duplicate_json_root/t00-one"
printf 'scope: duplicate json\ncwd: %s\nsession_id: t00-one\n' "$ROOT" >"$duplicate_json_root/t00-one/eci_active"
printf '{"session_id":"t00-one","session_id":"t00-two","cwd":"%s","transcript_path":"","stop_hook_active":false}\n' "$ROOT" >"$stop_input"
env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$duplicate_json_root" \
  bash "$ROOT/hooks/stop-gate.sh" <"$stop_input" >"$stop_out"
[ "$(jq -r '.decision // empty' "$stop_out")" = block ]
[ ! -e "$duplicate_json_root/t00-one/stop_timestamps" ]

invalid_symlink_identity_root="$tmp/invalid-symlink-identity-root"
mkdir -p "$invalid_symlink_identity_root/t00-one"
printf '%s\n' 'scope: unsafe marker target' >"$tmp/unsafe-marker-target"
ln -s "$tmp/unsafe-marker-target" "$invalid_symlink_identity_root/t00-one/eci_active"
env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$invalid_symlink_identity_root" \
  bash "$ROOT/hooks/stop-gate.sh" <"$stop_input" >"$stop_out"
[ "$(jq -r '.decision // empty' "$stop_out")" = block ]

# A proof marker must not be consumable through a hardlink alias.  The
# metadata is identical, but the link count proves that an unrelated path can
# mutate the same control bytes; readers fail closed before treating it as an
# active owner.
hardlink_identity_root="$tmp/hardlink-identity-root"
mkdir -p "$hardlink_identity_root/t00-one"
printf 'scope: hardlink\ncwd: %s\nsession_id: t00-one\n' "$ROOT" \
  >"$hardlink_identity_root/t00-one/eci_active"
ln "$hardlink_identity_root/t00-one/eci_active" "$tmp/eci-active-hardlink-alias"
jq -n --arg cwd "$ROOT" \
  '{session_id:"t00-one",transcript_path:"",stop_hook_active:false,cwd:$cwd}' >"$stop_input"
env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$hardlink_identity_root" \
  bash "$ROOT/hooks/stop-gate.sh" <"$stop_input" >"$stop_out"
[ "$(jq -r '.decision // empty' "$stop_out")" = block ]
[ ! -e "$hardlink_identity_root/t00-one/stop_timestamps" ]

# The path owner is part of the marker identity.  A marker embedded with a
# different session must not become invisible simply because the requested
# session has no matching directory; discovery scans it and fails closed.
mismatched_owner_root="$tmp/mismatched-owner-root"
mkdir -p "$mismatched_owner_root/t00-one"
printf 'scope: mismatch\ncwd: %s\nsession_id: t00-two\n' "$ROOT" \
  >"$mismatched_owner_root/t00-one/eci_active"
jq -n --arg cwd "$ROOT" \
  '{session_id:"invalid!",transcript_path:"",stop_hook_active:false,cwd:$cwd}' >"$stop_input"
env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$mismatched_owner_root" \
  bash "$ROOT/hooks/stop-gate.sh" <"$stop_input" >"$stop_out"
[ "$(jq -r '.decision // empty' "$stop_out")" = block ]
[ ! -e "$mismatched_owner_root/t00-two/stop_timestamps" ]

# Root-integrity regression: replacing an active proof root or its parent with
# a regular file must block read-only before transcriptless continuation.
swap_root="$tmp/swap-root"
mkdir -p "$swap_root/t00-session"
printf 'scope: before root swap\n' >"$swap_root/t00-session/eci_active"
mv "$swap_root" "$swap_root.original"
printf 'root replaced\n' >"$swap_root"
jq -n --arg cwd "$ROOT" \
  '{session_id:"t00-session",transcript_path:"",stop_hook_active:false,cwd:$cwd}' >"$stop_input"
env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$swap_root" \
  bash "$ROOT/hooks/stop-gate.sh" <"$stop_input" >"$stop_out"
[ "$(jq -r '.decision // empty' "$stop_out")" = block ]
[ "$(cat "$swap_root")" = 'root replaced' ]

swap_parent="$tmp/swap-parent"
mkdir -p "$swap_parent/proof/t00-session"
printf 'scope: before parent swap\n' >"$swap_parent/proof/t00-session/eci_active"
mv "$swap_parent" "$swap_parent.original"
printf 'parent replaced\n' >"$swap_parent"
swap_parent_root="$swap_parent/proof"
env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$swap_parent_root" \
  bash "$ROOT/hooks/stop-gate.sh" <"$stop_input" >"$stop_out"
[ "$(jq -r '.decision // empty' "$stop_out")" = block ]
[ "$(cat "$swap_parent")" = 'parent replaced' ]

# A worker with a different session id must still route through its validated
# parent marker when unrelated proof-root entries exhaust the bounded scan.
# Parent metadata is resolved directly from the bounded transcript record.
overflow_edit_root="$tmp/overflow-edit-root"
mkdir -p "$overflow_edit_root"
for i in $(seq 1 65); do
  mkdir -p "$overflow_edit_root/t00-edit-unrelated-$i"
done
mkdir -p "$overflow_edit_root/parent-session"
printf 'scope: parent worker\ncwd: %s\nsession_id: parent-session\n' "$ROOT" \
  >"$overflow_edit_root/parent-session/eci_active"
mkdir -p "$home/.codex/sessions"
overflow_transcript="$home/.codex/sessions/overflow-worker.jsonl"
printf '%s\n' '{"type":"session_meta","payload":{"source":{"subagent":{"thread_spawn":{"parent_thread_id":"parent-session","depth":1,"agent_nickname":"Overflow","agent_role":"worker"}}}}}' \
  >"$overflow_transcript"
overflow_edit_input="$tmp/overflow-edit.json"
jq -n --arg cwd "$ROOT" --arg transcript "$overflow_transcript" \
  '{session_id:"child-session",cwd:$cwd,transcript_path:$transcript,tool_name:"apply_patch",tool_input:{command:"*** Begin Patch\\n*** Add File: worker-file.txt\\n+worker\\n*** End Patch\\n"}}' >"$overflow_edit_input"
env -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$overflow_edit_root" \
  bash "$ROOT/hooks/eci-active-gate.sh" <"$overflow_edit_input" >"$tmp/overflow-edit.out"
[ ! -s "$tmp/overflow-edit.out" ]

# An inactive coordinator callback must ignore an overflow made entirely of
# unrelated proof-root entries.  The direct current-session lookup is the
# authority; an empty direct marker must not become MISSING_CURRENT merely
# because the bounded unrelated scan emitted its overflow sentinel.
inactive_overflow_edit_root="$tmp/inactive-overflow-edit-root"
mkdir -p "$inactive_overflow_edit_root"
for i in $(seq 1 65); do
  mkdir -p "$inactive_overflow_edit_root/t00-inactive-unrelated-$i"
  printf 'scope: unrelated overflow\ncwd: /other/cwd\nsession_id: t00-inactive-unrelated-%s\n' "$i" \
    >"$inactive_overflow_edit_root/t00-inactive-unrelated-$i/eci_active"
done
inactive_overflow_edit_input="$tmp/inactive-overflow-edit.json"
jq -n --arg cwd "$ROOT" \
  '{session_id:"t00-inactive-overflow",cwd:$cwd,tool_name:"apply_patch",tool_input:{command:"*** Begin Patch\n*** Add File: inactive-overflow-file.txt\n+inactive\n*** End Patch\n"}}' >"$inactive_overflow_edit_input"
env -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$inactive_overflow_edit_root" \
  bash "$ROOT/hooks/eci-active-gate.sh" <"$inactive_overflow_edit_input" >"$tmp/inactive-overflow-edit.out"
[ ! -s "$tmp/inactive-overflow-edit.out" ]

# A malformed callback must likewise remain inactive when the bounded scan
# sees only unrelated entries.  The overflow sentinel is a scan limitation,
# not an active owner and must not fabricate an identity denial.
malformed_overflow_edit_input="$tmp/malformed-overflow-edit.json"
jq -n --arg cwd "$ROOT" \
  '{session_id:123,cwd:$cwd,tool_name:"Edit",tool_input:{file_path:"inactive-overflow-file.txt"}}' \
  >"$malformed_overflow_edit_input"
env -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$inactive_overflow_edit_root" \
  bash "$ROOT/hooks/eci-active-gate.sh" <"$malformed_overflow_edit_input" >"$tmp/malformed-overflow-edit.out"
[ ! -s "$tmp/malformed-overflow-edit.out" ]

# The active path may publish only its bounded deduplication record. It must
# not create stop_timestamps or any unrelated proof-root/recovery state.
[ ! -e "$proof_root/t00-session/stop_timestamps" ]
while IFS= read -r found_state; do
  case "$found_state" in
    "$proof_root/t00-session/stop_loop_state") ;;
    *) printf 'unexpected active-path state file: %s\n' "$found_state" >&2; exit 1 ;;
  esac
done < <(find "$proof_root" -type f ! -name eci_active -print)
[ ! -e "$home/tmp" ]

if command -v strace >/dev/null 2>&1; then
  trace="$tmp/trace"
  strace -f -qq -e trace=process,file -o "$trace" \
    env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$proof_root" \
    bash "$ROOT/hooks/stop-gate.sh" <"$input" >"$out"
  state_writes="$(awk -v proof_root="$proof_root" -v home="$home" '
    /O_(WRONLY|RDWR|CREAT|TRUNC)|mkdir\(|rename\(|unlink\(/ &&
      (index($0, proof_root) || index($0, home)) {
      # stop_loop_state and its same-directory temporary publication are the
      # only intentional active-path writes; all other proof/recovery writes
      # remain a failure.
      if (index($0, proof_root "/t00-session/stop_loop_state")) next
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
printf 'PASS active ECI fast path: 5 callbacks, max %sms; only bounded stop-loop state writes\n' "$max_ms"
