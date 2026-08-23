#!/usr/bin/env bash

set -euo pipefail

ROOT="${ECI_TEST_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
TMP_ROOT="$(mktemp -d "${CODEX_TMPDIR:-${HOME:?}/tmp}/codex-eci-marker-scope.XXXXXX")"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

export XDG_CONFIG_HOME="$TMP_ROOT/xdg-config"
mkdir -p "$XDG_CONFIG_HOME/eci"
chmod 700 "$XDG_CONFIG_HOME" "$XDG_CONFIG_HOME/eci"
printf '%s\n' enforcing >"$XDG_CONFIG_HOME/eci/command-gate-mode"
chmod 600 "$XDG_CONFIG_HOME/eci/command-gate-mode"

run_validate() {
  local proof_root="$1" session_id="$2" cwd="$3" command="$4" output="$TMP_ROOT/output"
  jq -cn --arg session_id "$session_id" --arg cwd "$cwd" --arg command "$command" \
    '{session_id:$session_id,cwd:$cwd,tool_input:{command:$command}}' |
    CODEX_PROOF_ROOT="$proof_root" CODEX_HOME="$ROOT" PATH="$ROOT/bin:$PATH" \
      bash "$ROOT/hooks/validate-bash.sh" >"$output"
  cat "$output"
}

run_edit_gate() {
  local proof_root="$1" session_id="$2" cwd="$3" path="$4" output="$TMP_ROOT/edit-output"
  jq -cn --arg session_id "$session_id" --arg cwd "$cwd" --arg path "$path" \
    '{tool_name:"Write",session_id:$session_id,cwd:$cwd,tool_input:{file_path:$path,content:"forged"}}' |
    CODEX_PROOF_ROOT="$proof_root" CODEX_HOME="$ROOT" \
      bash "$ROOT/hooks/eci-active-gate.sh" >"$output"
  cat "$output"
}

proof_root="$TMP_ROOT/proof"
current_session=current-session
stale_session=stale-session
mkdir -p "$proof_root/$stale_session" "$TMP_ROOT/other-cwd"
printf '%s\n' 'not a marker' >"$proof_root/$stale_session/eci_active"

# A deleted current marker plus an unrelated malformed marker is inactive for
# the current session.  The old global strict scan incorrectly denied this.
output="$(run_validate "$proof_root" "$current_session" "$ROOT" 'git status')"
[ -z "$output" ]

proof_root="$TMP_ROOT/proof-current"
mkdir -p "$proof_root/$current_session"
printf '%s\n' \
  'scope: malformed-current' \
  "cwd: $ROOT" \
  'session_id: wrong-owner' \
  >"$proof_root/$current_session/eci_active"
output="$(run_validate "$proof_root" "$current_session" "$ROOT" 'git status')"
jq -e --arg marker "$proof_root/$current_session/eci_active" '
  .hookSpecificOutput.permissionDecision == "deny" and
  (.hookSpecificOutput.permissionDecisionReason | contains("ECI_MARKER_OWNERSHIP_INVALID")) and
  (.hookSpecificOutput.permissionDecisionReason | contains($marker)) and
  (.hookSpecificOutput.permissionDecisionReason | contains("scope: malformed-current") | not)
' <<<"$output" >/dev/null
output="$(run_edit_gate "$proof_root" "$current_session" "$ROOT" "$ROOT/hooks/stop-gate.sh")"
jq -e '
  .hookSpecificOutput.permissionDecision == "deny" and
  (.hookSpecificOutput.permissionDecisionReason | contains("ECI_MARKER_OWNERSHIP_INVALID")) and
  (.hookSpecificOutput.permissionDecisionReason | contains("scope: malformed-current") | not)
' <<<"$output" >/dev/null

# A valid current marker remains the diagnostic owner when a bounded scan also
# encounters an unrelated malformed marker from another cwd. The old
# candidate loop reported the unrelated path as ECI_MARKER_SCOPE_MISMATCH.
proof_root="$TMP_ROOT/proof-stop-owner"
mkdir -p "$proof_root/unrelated-session" "$proof_root/$current_session"
printf '%s\n' \
  'scope: unrelated malformed' \
  "cwd: $TMP_ROOT/other-cwd" \
  'session_id: wrong-owner' \
  'created_utc: 2026-08-17T00:00:00Z' \
  >"$proof_root/unrelated-session/eci_active"
printf '%s\n' \
  'scope: current stop owner' \
  "cwd: $ROOT" \
  "session_id: $current_session" \
  'created_utc: 2026-08-17T00:00:00Z' \
  >"$proof_root/$current_session/eci_active"
output="$TMP_ROOT/stop-owner-output"
jq -cn --arg session_id "$current_session" --arg cwd "$ROOT" \
  '{session_id:$session_id,cwd:$cwd,transcript_path:"",stop_hook_active:false}' |
  CODEX_PROOF_ROOT="$proof_root" CODEX_HOME="$ROOT" \
    bash "$ROOT/hooks/stop-gate.sh" >"$output"
jq -e --arg current "$proof_root/$current_session/eci_active" \
  --arg unrelated "$proof_root/unrelated-session/eci_active" '
  .decision == "block" and
  (.reason | contains("ECI_STOP_ACTIVE_ECI")) and
  (.reason | contains($current)) and
  (.reason | contains($unrelated) | not)
' "$output" >/dev/null

# A stale queued marker passed directly to the diagnostic formatter must be
# rebound to the valid current owner. This exercises the handoff that occurs
# after an older selector/callback has already supplied a marker path.
proof_root="$TMP_ROOT/proof-stop-queued"
mkdir -p "$proof_root/$current_session" "$proof_root/stale-session" "$TMP_ROOT/stale-cwd"
proof_root_canonical="$(realpath -e "$proof_root")"
printf '%s\n' \
  'scope: current stop owner' \
  "cwd: $ROOT" \
  "session_id: $current_session" \
  'created_utc: 2026-08-17T00:00:00Z' \
  >"$proof_root/$current_session/eci_active"
printf '%s\n' \
  'scope: stale queued owner' \
  "cwd: $TMP_ROOT/stale-cwd" \
  'session_id: stale-session' \
  'created_utc: 2026-08-17T00:00:00Z' \
  >"$proof_root/stale-session/eci_active"
queued_output="$TMP_ROOT/stop-queued-output"
queued_harness="$TMP_ROOT/stop-queued-harness"
{
  printf '%s\n' 'set -euo pipefail'
  printf '%s\n' 'unset CODEX_STOP_GATE_ROOT'
  printf 'source %q\n' "$ROOT/hooks/lib/codex-proof-state.sh"
  sed -n '/^stop_direct_marker_path() {/,/^}/p' "$ROOT/hooks/stop-gate.sh"
  sed -n '/^stop_marker_candidate_matches_current() {/,/^}/p' "$ROOT/hooks/stop-gate.sh"
  sed -n '/^json_block_fast() {/,/^}/p' "$ROOT/hooks/stop-gate.sh"
  cat <<EOF
CODEX_PROOF_ROOT=$(printf '%q' "$proof_root")
HOME=$(printf '%q' "$HOME")
root=$(printf '%q' "$proof_root_canonical")
session_id=$(printf '%q' "$current_session")
cwd=$(printf '%q' "$ROOT")
canonical_stop_cwd=$(printf '%q' "$ROOT")
transcript_path=
stop_invalid_marker=
stop_marker_cache_status=0
stop_marker_cache=()
stop_direct_marker_valid_fast=false
stop_root_requires_ambiguity_scan() { return 1; }
stop_direct_marker_is_valid_fast() { return 1; }
json_block_with_loop_state() { jq -cn --arg reason "\$1" '{decision:"block",reason:\$reason}'; }
json_block_fast $(printf '%q' "$proof_root_canonical/stale-session/eci_active")
EOF
} >"$queued_harness"
bash "$queued_harness" >"$queued_output"
jq -e --arg current "$proof_root_canonical/$current_session/eci_active" \
  --arg stale "$proof_root_canonical/stale-session/eci_active" '
  .decision == "block" and
  (.reason | contains("ECI_STOP_ACTIVE_ECI")) and
  (.reason | contains($current)) and
  (.reason | contains($stale) | not)
' "$queued_output" >/dev/null

# A valid marker from another session is also ignored when the current
# session has no direct marker. Same-cwd legacy discovery must not fabricate
# ownership for the callback.
proof_root="$TMP_ROOT/proof-stop-unrelated"
mkdir -p "$proof_root/other-session" "$TMP_ROOT/unrelated-cwd"
printf '%s\n' \
  'scope: unrelated valid' \
  "cwd: $TMP_ROOT/unrelated-cwd" \
  'session_id: other-session' \
  'created_utc: 2026-08-17T00:00:00Z' \
  >"$proof_root/other-session/eci_active"
output="$TMP_ROOT/stop-unrelated-output"
jq -cn --arg session_id "$current_session" --arg cwd "$TMP_ROOT/unrelated-cwd" \
  '{session_id:$session_id,cwd:$cwd,transcript_path:"",stop_hook_active:false}' |
  CODEX_PROOF_ROOT="$proof_root" CODEX_HOME="$ROOT" \
    bash "$ROOT/hooks/stop-gate.sh" >"$output"
jq -e '.continue == true' "$output" >/dev/null

proof_root="$TMP_ROOT/proof-alias"
mkdir -p "$proof_root/$current_session"
printf '%s\n' \
  'scope: alias-current' \
  "cwd: $ROOT" \
  "session_id: $current_session" \
  'created_utc: 2026-08-17T00:00:00Z' \
  >"$proof_root/$current_session/eci_active"
output="$(run_validate "$proof_root" "$current_session" "$ROOT" 'git status')"
[ -z "$output" ]

# The marker bound is over actual eci_active candidates, not unrelated proof
# artifacts. A current marker must remain authoritative with more than 64
# ordinary proof-root directories/files present.
proof_root="$TMP_ROOT/proof-candidate-only"
candidate_session=candidate-session
mkdir -p "$proof_root/$candidate_session"
printf '%s\n' \
  'scope: candidate-only current owner' \
  "cwd: $ROOT" \
  "session_id: $candidate_session" \
  'created_utc: 2026-08-17T00:00:00Z' \
  >"$proof_root/$candidate_session/eci_active"
for i in $(seq 1 70); do
  mkdir -p "$proof_root/proof-artifact-dir-$i"
done
for i in $(seq 1 6); do
  printf '%s\n' 'ordinary proof artifact' >"$proof_root/proof-artifact-file-$i"
done
output="$TMP_ROOT/candidate-only-stop-output"
jq -cn --arg session_id "$candidate_session" --arg cwd "$ROOT" \
  '{session_id:$session_id,cwd:$cwd,transcript_path:"",stop_hook_active:false}' |
  CODEX_PROOF_ROOT="$proof_root" CODEX_HOME="$ROOT" \
    bash "$ROOT/hooks/stop-gate.sh" >"$output"
jq -e --arg marker "$proof_root/$candidate_session/eci_active" '
  .decision == "block" and
  (.reason | contains("ECI_STOP_ACTIVE_ECI")) and
  (.reason | contains($marker)) and
  (.reason | contains("ECI_STOP_MARKER_SCAN_UNSAFE") | not)
' "$output" >/dev/null
candidate_markers="$TMP_ROOT/candidate-only-markers"
CODEX_PROOF_ROOT="$proof_root" CODEX_HOME="$ROOT" bash -c \
  'source "$CODEX_HOME/hooks/lib/codex-proof-state.sh"; codex_eci_marker_candidates_bounded' \
  >"$candidate_markers"
grep -F "/$candidate_session/eci_active" "$candidate_markers" >/dev/null
! grep -Fq '__CODEX_ECI_MARKER_SCAN_OVERFLOW__' "$candidate_markers"

# Two valid same-cwd owners remain fail-closed as duplicate control state even
# when unrelated proof artifacts do not consume the candidate bound.
proof_root="$TMP_ROOT/proof-duplicate-candidate"
duplicate_current=duplicate-current
duplicate_peer=duplicate-peer
mkdir -p "$proof_root/$duplicate_current" "$proof_root/$duplicate_peer"
for i in $(seq 1 70); do
  mkdir -p "$proof_root/proof-artifact-$i"
done
printf '%s\n' \
  'scope: duplicate current owner' \
  "cwd: $ROOT" \
  "session_id: $duplicate_current" \
  'created_utc: 2026-08-17T00:00:00Z' \
  >"$proof_root/$duplicate_current/eci_active"
printf '%s\n' \
  'scope: duplicate peer owner' \
  "cwd: $ROOT" \
  "session_id: $duplicate_peer" \
  'created_utc: 2026-08-17T00:00:00Z' \
  >"$proof_root/$duplicate_peer/eci_active"
duplicate_root_canonical="$(realpath -e "$proof_root")"
duplicate_harness="$TMP_ROOT/duplicate-marker-harness"
duplicate_result="$TMP_ROOT/duplicate-marker-result"
{
  printf '%s\n' 'set -euo pipefail'
  printf 'source %q\n' "$ROOT/hooks/lib/codex-proof-state.sh"
  sed -n '/^stop_direct_marker_path() {/,/^}/p' "$ROOT/hooks/stop-gate.sh"
  sed -n '/^stop_marker_scan() {/,/^}/p' "$ROOT/hooks/stop-gate.sh"
  sed -n '/^stop_root_requires_ambiguity_scan() {/,/^}/p' "$ROOT/hooks/stop-gate.sh"
  sed -n '/^stop_marker_scan_required() {/,/^}/p' "$ROOT/hooks/stop-gate.sh"
  sed -n '/^stop_marker_cache_load() {/,/^}/p' "$ROOT/hooks/stop-gate.sh"
  sed -n '/^stop_marker_candidate_matches_current() {/,/^}/p' "$ROOT/hooks/stop-gate.sh"
  sed -n '/^stop_direct_marker_is_valid_fast() {/,/^}/p' "$ROOT/hooks/stop-gate.sh"
  sed -n '/^active_eci_marker_for_stop() {/,/^}/p' "$ROOT/hooks/stop-gate.sh"
  cat <<EOF
root=$(printf '%q' "$duplicate_root_canonical")
session_id=$(printf '%q' "$duplicate_current")
cwd=$(printf '%q' "$ROOT")
canonical_stop_cwd=$(printf '%q' "$ROOT")
eci_stop_max_markers=64
transcript_path=
stop_identity_malformed=false
stop_root_ambiguity_scan_cached=
stop_marker_cache=()
stop_marker_cache_loaded=false
stop_marker_cache_status=0
stop_direct_marker_valid_fast=false
marker_status=0
active_eci_marker_for_stop >$(printf '%q' "$duplicate_result") || marker_status=\$?
printf 'status=%s cache_status=%s cache_count=%s\\n' \$marker_status \$stop_marker_cache_status \${#stop_marker_cache[@]}
EOF
} >"$duplicate_harness"
bash "$duplicate_harness" >"$TMP_ROOT/duplicate-marker-summary"
grep -Fx 'status=2 cache_status=0 cache_count=2' "$TMP_ROOT/duplicate-marker-summary" >/dev/null || {
  cat "$TMP_ROOT/duplicate-marker-summary" >&2
  exit 1
}

# A nonempty syntactically invalid callback session still identifies an
# active marker as a scope mismatch.  It must not degrade into an ambiguous
# scan error merely because no path can equal the invalid ID.
proof_root="$TMP_ROOT/proof-stop-invalid-session"
foreign_session=foreign-session
mkdir -p "$proof_root/$foreign_session"
printf '%s\n' \
  'scope: invalid-session control' \
  "cwd: $ROOT" \
  "session_id: $foreign_session" \
  'created_utc: 2026-08-17T00:00:00Z' \
  >"$proof_root/$foreign_session/eci_active"
output="$TMP_ROOT/stop-invalid-session-output"
jq -cn --arg cwd "$ROOT" \
  '{session_id:"invalid!",cwd:$cwd,transcript_path:"",stop_hook_active:false}' |
  CODEX_PROOF_ROOT="$proof_root" CODEX_HOME="$ROOT" \
    bash "$ROOT/hooks/stop-gate.sh" >"$output"
jq -e --arg marker "$proof_root/$foreign_session/eci_active" '
  .decision == "block" and
  (.reason | contains("ECI_MARKER_SCOPE_MISMATCH")) and
  (.reason | contains($marker)) and
  (.reason | contains("ECI_STOP_MARKER_SCAN_UNSAFE") | not)
' "$output" >/dev/null

# An empty callback session has no owner to select.  A foreign marker remains
# an unsafe scan condition rather than a fabricated session/cwd mismatch.
proof_root="$TMP_ROOT/proof-stop-empty-session"
mkdir -p "$proof_root/$foreign_session"
printf '%s\n' \
  'scope: empty-session control' \
  "cwd: $ROOT" \
  "session_id: $foreign_session" \
  'created_utc: 2026-08-17T00:00:00Z' \
  >"$proof_root/$foreign_session/eci_active"
output="$TMP_ROOT/stop-empty-session-output"
jq -cn --arg cwd "$ROOT" \
  '{session_id:"",cwd:$cwd,transcript_path:"",stop_hook_active:false}' |
  CODEX_PROOF_ROOT="$proof_root" CODEX_HOME="$ROOT" \
    bash "$ROOT/hooks/stop-gate.sh" >"$output"
jq -e --arg marker "$proof_root/$foreign_session/eci_active" '
  .decision == "block" and
  (.reason | contains("ECI_STOP_MARKER_SCAN_UNSAFE")) and
  (.reason | contains("ECI_MARKER_SCOPE_MISMATCH") | not) and
  (.reason | contains($marker) | not)
' "$output" >/dev/null

# A valid session with a malformed cwd field is still not a license to select
# a foreign marker.  The malformed identity has no usable current owner, so
# the foreign candidate remains an unsafe scan condition.
proof_root="$TMP_ROOT/proof-stop-malformed-cwd"
mkdir -p "$proof_root/$foreign_session"
printf '%s\n' \
  'scope: malformed-cwd foreign control' \
  "cwd: $ROOT" \
  "session_id: $foreign_session" \
  'created_utc: 2026-08-17T00:00:00Z' \
  >"$proof_root/$foreign_session/eci_active"
output="$TMP_ROOT/stop-malformed-cwd-output"
printf '%s\n' \
  '{"session_id":"valid-session","cwd":123,"transcript_path":"","stop_hook_active":false}' |
  CODEX_PROOF_ROOT="$proof_root" CODEX_HOME="$ROOT" \
    bash "$ROOT/hooks/stop-gate.sh" >"$output"
jq -e --arg marker "$proof_root/$foreign_session/eci_active" '
  .decision == "block" and
  (.reason | contains("ECI_STOP_MARKER_SCAN_UNSAFE")) and
  (.reason | contains("ECI_MARKER_SCOPE_MISMATCH") | not) and
  (.reason | contains($marker) | not)
' "$output" >/dev/null

# An overflowed cache is only a partial observation.  Even a nonempty invalid
# session must retain the scan-unsafe diagnostic rather than selecting the
# first arbitrary complete-looking marker from the partial cache.
proof_root="$TMP_ROOT/proof-stop-invalid-session-overflow"
for i in $(seq 1 65); do
  overflow_session="overflow-session-$i"
  mkdir -p "$proof_root/$overflow_session"
  printf '%s\n' \
    'scope: overflow control' \
    "cwd: $ROOT" \
    "session_id: $overflow_session" \
    'created_utc: 2026-08-17T00:00:00Z' \
    >"$proof_root/$overflow_session/eci_active"
done
output="$TMP_ROOT/stop-invalid-session-overflow-output"
jq -cn --arg cwd "$ROOT" \
  '{session_id:"invalid!",cwd:$cwd,transcript_path:"",stop_hook_active:false}' |
  CODEX_PROOF_ROOT="$proof_root" CODEX_HOME="$ROOT" \
    bash "$ROOT/hooks/stop-gate.sh" >"$output"
jq -e --arg proof_root "$proof_root" '
  .decision == "block" and
  (.reason | contains("ECI_STOP_MARKER_SCAN_UNSAFE")) and
  (.reason | contains("ECI_MARKER_SCOPE_MISMATCH") | not) and
  (.reason | contains($proof_root) | not)
' "$output" >/dev/null

printf '%s\n' 'eci marker scope assertions: PASS'
