#!/usr/bin/env bash

set -euo pipefail

ROOT="${ECI_TEST_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
TMP_ROOT="$(mktemp -d "${CODEX_TMPDIR:-${HOME:?}/tmp}/codex-eci-marker-scope.XXXXXX")"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

# The live validate hook is deliberately user-disabled while the broader ECI
# repair is in progress.  Keep that user-owned line untouched: this test uses
# a private copied hook tree and enables only the copy it executes.
[ "$(sed -n '2p' "$ROOT/hooks/validate-bash.sh")" = 'exit 0' ] || {
  printf '%s\n' 'expected the live user-owned validate-bash override at line 2' >&2
  exit 1
}
TEST_HOOK_ROOT="$TMP_ROOT/private-hooks"
cp -a -- "$ROOT/hooks" "$TEST_HOOK_ROOT"
sed -i '2d' "$TEST_HOOK_ROOT/validate-bash.sh"

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
      bash "$TEST_HOOK_ROOT/validate-bash.sh" >"$output"
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
# encounters an unrelated malformed marker and a fully valid different-cwd
# peer. The old candidate loop reported the unrelated path as
# ECI_MARKER_SCOPE_MISMATCH. A different-cwd peer is not counted as a
# same-cwd peer.
proof_root="$TMP_ROOT/proof-stop-owner"
valid_other_session=valid-other-session
mkdir -p "$proof_root/unrelated-session" "$proof_root/$valid_other_session" "$proof_root/$current_session"
printf '%s\n' \
  'scope: unrelated malformed' \
  "cwd: $TMP_ROOT/other-cwd" \
  'session_id: wrong-owner' \
  'created_utc: 2026-08-17T00:00:00Z' \
  >"$proof_root/unrelated-session/eci_active"
printf '%s\n' \
  'scope: valid different-cwd peer' \
  "cwd: $TMP_ROOT/other-cwd" \
  "session_id: $valid_other_session" \
  'created_utc: 2026-08-17T00:00:00Z' \
  >"$proof_root/$valid_other_session/eci_active"
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
  --arg unrelated "$proof_root/unrelated-session/eci_active" \
  --arg valid_other "$proof_root/$valid_other_session/eci_active" '
  .decision == "block" and
  (.reason | contains("ECI_STOP_ACTIVE_ECI")) and
  (.reason | contains($current)) and
  (.reason | contains($unrelated) | not) and
  (.reason | contains($valid_other) | not) and
  (.reason | contains("same_cwd_valid_peer_count") | not)
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
queued_err="$TMP_ROOT/stop-queued.err"
queued_harness="$TMP_ROOT/stop-queued-harness"
{
  printf '%s\n' 'set -euo pipefail'
  printf '%s\n' 'unset CODEX_STOP_GATE_ROOT'
  printf 'source %q\n' "$ROOT/hooks/lib/codex-proof-state.sh"
  sed -n '/^stop_direct_marker_path() {/,/^}/p' "$ROOT/hooks/stop-gate.sh"
  sed -n '/^stop_marker_candidate_matches_current() {/,/^}/p' "$ROOT/hooks/stop-gate.sh"
  sed -n '/^active_eci_stop_reason() {/,/^}/p' "$ROOT/hooks/stop-gate.sh"
  sed -n '/^foreign_same_cwd_eci_marker_is_valid() {/,/^}/p' "$ROOT/hooks/stop-gate.sh"
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
bash "$queued_harness" >"$queued_output" 2>"$queued_err"
[ ! -s "$queued_err" ] || {
  cat "$queued_err" >&2
  exit 1
}
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
jq -cn --arg session_id "$current_session" --arg cwd "$ROOT" \
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

# A complete bounded scan may find a valid same-cwd peer, but the callback's
# exact valid marker remains the selector owner. Unrelated proof artifacts do
# not consume the candidate bound.
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
cp -- "$proof_root/$duplicate_current/eci_active" "$TMP_ROOT/duplicate-current-marker.before"
cp -- "$proof_root/$duplicate_peer/eci_active" "$TMP_ROOT/duplicate-peer-marker.before"
duplicate_root_canonical="$(realpath -e "$proof_root")"
duplicate_harness="$TMP_ROOT/duplicate-marker-harness"
duplicate_result="$TMP_ROOT/duplicate-marker-result"
{
  printf '%s\n' 'set -euo pipefail'
  printf 'export CODEX_PROOF_ROOT=%q\n' "$duplicate_root_canonical"
  printf 'export CODEX_STOP_GATE_ROOT=%q\n' "$duplicate_root_canonical"
  printf 'source %q\n' "$ROOT/hooks/lib/codex-proof-state.sh"
  sed -n '/^stop_direct_marker_path() {/,/^}/p' "$ROOT/hooks/stop-gate.sh"
  sed -n '/^stop_marker_scan() {/,/^}/p' "$ROOT/hooks/stop-gate.sh"
  sed -n '/^stop_root_has_unsafe_child_symlink() {/,/^}/p' "$ROOT/hooks/stop-gate.sh"
  sed -n '/^stop_root_requires_ambiguity_scan() {/,/^}/p' "$ROOT/hooks/stop-gate.sh"
  sed -n '/^stop_marker_scan_required() {/,/^}/p' "$ROOT/hooks/stop-gate.sh"
  sed -n '/^stop_marker_cache_load() {/,/^}/p' "$ROOT/hooks/stop-gate.sh"
  sed -n '/^stop_marker_candidate_matches_current() {/,/^}/p' "$ROOT/hooks/stop-gate.sh"
  sed -n '/^stop_direct_marker_is_valid_fast() {/,/^}/p' "$ROOT/hooks/stop-gate.sh"
  sed -n '/^stop_emit_selected_marker() {/,/^}/p' "$ROOT/hooks/stop-gate.sh"
  sed -n '/^active_eci_marker_for_stop() {/,/^}/p' "$ROOT/hooks/stop-gate.sh"
  cat <<EOF
root=$(printf '%q' "$duplicate_root_canonical")
session_id=$(printf '%q' "$duplicate_current")
cwd=$(printf '%q' "$ROOT")
canonical_stop_cwd=$(printf '%q' "$ROOT")
eci_stop_max_markers=64
eci_stop_max_namespace_entries=4096
transcript_path=
stop_identity_malformed=false
stop_root_ambiguity_scan_cached=
stop_marker_cache=()
stop_marker_cache_loaded=false
stop_marker_cache_status=0
stop_direct_marker_valid_fast=false
stop_recursive_callback_candidate=false
marker_status=0
eci_wait_state_allows() { return 1; }
active_eci_marker_for_stop >$(printf '%q' "$duplicate_result") || marker_status=\$?
printf 'status=%s cache_status=%s cache_count=%s\\n' \$marker_status \$stop_marker_cache_status \${#stop_marker_cache[@]}
EOF
} >"$duplicate_harness"
bash "$duplicate_harness" >"$TMP_ROOT/duplicate-marker-summary"
grep -Fx 'status=0 cache_status=0 cache_count=2' "$TMP_ROOT/duplicate-marker-summary" >/dev/null || {
  cat "$TMP_ROOT/duplicate-marker-summary" >&2
  exit 1
}
grep -Fx "$duplicate_root_canonical/$duplicate_current/eci_active" "$duplicate_result" >/dev/null || {
  cat "$duplicate_result" >&2
  exit 1
}

# A valid same-cwd peer stays visible as a bounded count, while the direct
# marker remains authoritative. One active-ECI reminder is useful; identical
# later callbacks continue without mutating either marker or loop state.
duplicate_input="$TMP_ROOT/duplicate-stop-input"
duplicate_output="$TMP_ROOT/duplicate-stop-output"
duplicate_second_output="$TMP_ROOT/duplicate-stop-second-output"
duplicate_third_output="$TMP_ROOT/duplicate-stop-third-output"
duplicate_fourth_output="$TMP_ROOT/duplicate-stop-fourth-output"
duplicate_fifth_output="$TMP_ROOT/duplicate-stop-fifth-output"
duplicate_loop_state="$proof_root/$duplicate_current/stop_loop_state"
jq -cn --arg session_id "$duplicate_current" --arg cwd "$ROOT" \
  '{session_id:$session_id,cwd:$cwd,transcript_path:"",stop_hook_active:false}' \
  >"$duplicate_input"
CODEX_PROOF_ROOT="$proof_root" CODEX_HOME="$ROOT" \
  bash "$ROOT/hooks/stop-gate.sh" <"$duplicate_input" >"$duplicate_output"
jq -e --arg direct "$duplicate_root_canonical/$duplicate_current/eci_active" '
  .decision == "block" and
  (has("continue") | not) and
  (.reason | contains("[ECI_STOP_ACTIVE_ECI]")) and
  (.reason | contains($direct)) and
  (.reason | contains("same_cwd_valid_peer_count=1")) and
  (.reason | contains("direct marker remains authoritative")) and
  (.reason | contains("[ECI_STOP_MARKER_AMBIGUOUS]") | not)
' "$duplicate_output" >/dev/null || {
  cat "$duplicate_output" >&2
  exit 1
}
cmp -s "$TMP_ROOT/duplicate-current-marker.before" "$proof_root/$duplicate_current/eci_active"
cmp -s "$TMP_ROOT/duplicate-peer-marker.before" "$proof_root/$duplicate_peer/eci_active"
grep -qx 'count: 1' "$duplicate_loop_state"
grep -qx 'loop_emitted: true' "$duplicate_loop_state"
cp -- "$duplicate_loop_state" "$TMP_ROOT/duplicate-loop-state.after-first"
CODEX_PROOF_ROOT="$proof_root" CODEX_HOME="$ROOT" \
  bash "$ROOT/hooks/stop-gate.sh" <"$duplicate_input" >"$duplicate_second_output"
jq -e '.continue == true and (has("decision") | not)' "$duplicate_second_output" >/dev/null || {
  cat "$duplicate_second_output" >&2
  exit 1
}
cmp -s "$TMP_ROOT/duplicate-loop-state.after-first" "$duplicate_loop_state"
cmp -s "$TMP_ROOT/duplicate-current-marker.before" "$proof_root/$duplicate_current/eci_active"
cmp -s "$TMP_ROOT/duplicate-peer-marker.before" "$proof_root/$duplicate_peer/eci_active"
CODEX_PROOF_ROOT="$proof_root" CODEX_HOME="$ROOT" \
  bash "$ROOT/hooks/stop-gate.sh" <"$duplicate_input" >"$duplicate_third_output"
jq -e '.continue == true and (has("decision") | not)' "$duplicate_third_output" >/dev/null || {
  cat "$duplicate_third_output" >&2
  exit 1
}
cmp -s "$duplicate_second_output" "$duplicate_third_output"
cmp -s "$TMP_ROOT/duplicate-loop-state.after-first" "$duplicate_loop_state"
cmp -s "$TMP_ROOT/duplicate-current-marker.before" "$proof_root/$duplicate_current/eci_active"
cmp -s "$TMP_ROOT/duplicate-peer-marker.before" "$proof_root/$duplicate_peer/eci_active"
CODEX_PROOF_ROOT="$proof_root" CODEX_HOME="$ROOT" \
  bash "$ROOT/hooks/stop-gate.sh" <"$duplicate_input" >"$duplicate_fourth_output"
jq -e '.continue == true and (has("decision") | not)' "$duplicate_fourth_output" >/dev/null || {
  cat "$duplicate_fourth_output" >&2
  exit 1
}
cmp -s "$duplicate_second_output" "$duplicate_fourth_output"
cmp -s "$TMP_ROOT/duplicate-loop-state.after-first" "$duplicate_loop_state"
cmp -s "$TMP_ROOT/duplicate-current-marker.before" "$proof_root/$duplicate_current/eci_active"
cmp -s "$TMP_ROOT/duplicate-peer-marker.before" "$proof_root/$duplicate_peer/eci_active"
CODEX_PROOF_ROOT="$proof_root" CODEX_HOME="$ROOT" \
  bash "$ROOT/hooks/stop-gate.sh" <"$duplicate_input" >"$duplicate_fifth_output"
cmp -s "$duplicate_second_output" "$duplicate_fifth_output" || {
  diff -u "$duplicate_fourth_output" "$duplicate_fifth_output" >&2 || true
  exit 1
}
cmp -s "$TMP_ROOT/duplicate-loop-state.after-first" "$duplicate_loop_state"
cmp -s "$TMP_ROOT/duplicate-current-marker.before" "$proof_root/$duplicate_current/eci_active"
cmp -s "$TMP_ROOT/duplicate-peer-marker.before" "$proof_root/$duplicate_peer/eci_active"

# A nonempty syntactically invalid callback session has no safe loop-state
# owner. Even three identical callbacks must remain blocked and must not
# create a session directory merely because no path can equal the invalid ID.
proof_root="$TMP_ROOT/proof-stop-invalid-session"
foreign_session=foreign-session
mkdir -p "$proof_root/$foreign_session"
printf '%s\n' \
  'scope: invalid-session control' \
  "cwd: $ROOT" \
  "session_id: $foreign_session" \
  'created_utc: 2026-08-17T00:00:00Z' \
  >"$proof_root/$foreign_session/eci_active"
invalid_session_input="$TMP_ROOT/stop-invalid-session-input"
invalid_session_first_output="$TMP_ROOT/stop-invalid-session-first-output"
invalid_session_second_output="$TMP_ROOT/stop-invalid-session-second-output"
invalid_session_third_output="$TMP_ROOT/stop-invalid-session-third-output"
foreign_marker="$proof_root/$foreign_session/eci_active"
cp -- "$foreign_marker" "$TMP_ROOT/stop-invalid-session-foreign-marker.before"
jq -cn --arg cwd "$ROOT" \
  '{session_id:"invalid!",cwd:$cwd,transcript_path:"",stop_hook_active:false}' \
  >"$invalid_session_input"
for output in "$invalid_session_first_output" "$invalid_session_second_output" "$invalid_session_third_output"; do
  CODEX_PROOF_ROOT="$proof_root" CODEX_HOME="$ROOT" \
    bash "$ROOT/hooks/stop-gate.sh" <"$invalid_session_input" >"$output"
done
jq -e --arg marker "$foreign_marker" --arg foreign_session "$foreign_session" '
  .decision == "block" and
  (keys | sort) == ["decision", "reason"] and
  (.reason | contains("ECI_STOP_IDENTITY_MALFORMED")) and
  (.reason | contains("ECI_STOP_LOOP_CONTRACT_DEFECT") | not) and
  (.reason | contains("ECI_MARKER_SCOPE_MISMATCH") | not) and
  (.reason | contains($marker) | not) and
  (.reason | contains($foreign_session) | not)
' "$invalid_session_first_output" >/dev/null
cmp -s "$invalid_session_first_output" "$invalid_session_second_output"
cmp -s "$invalid_session_first_output" "$invalid_session_third_output"
cmp -s "$TMP_ROOT/stop-invalid-session-foreign-marker.before" "$foreign_marker"
[ ! -e "$proof_root/invalid!/stop_loop_state" ] && [ ! -L "$proof_root/invalid!/stop_loop_state" ]
[ ! -e "$proof_root/$foreign_session/stop_loop_state" ] && [ ! -L "$proof_root/$foreign_session/stop_loop_state" ]

# An empty callback session has no owner to select.  With a healthy bounded
# scan, it must fail statelessly as a malformed identity without disclosing or
# mutating the foreign owner.
proof_root="$TMP_ROOT/proof-stop-empty-session"
mkdir -p "$proof_root/$foreign_session"
printf '%s\n' \
  'scope: empty-session control' \
  "cwd: $ROOT" \
  "session_id: $foreign_session" \
  'created_utc: 2026-08-17T00:00:00Z' \
  >"$proof_root/$foreign_session/eci_active"
empty_session_input="$TMP_ROOT/stop-empty-session-input"
empty_session_first_output="$TMP_ROOT/stop-empty-session-first-output"
empty_session_second_output="$TMP_ROOT/stop-empty-session-second-output"
empty_session_third_output="$TMP_ROOT/stop-empty-session-third-output"
empty_session_foreign_marker="$proof_root/$foreign_session/eci_active"
cp -- "$empty_session_foreign_marker" "$TMP_ROOT/stop-empty-session-foreign-marker.before"
jq -cn --arg cwd "$ROOT" \
  '{session_id:"",cwd:$cwd,transcript_path:"",stop_hook_active:false}' \
  >"$empty_session_input"
for output in "$empty_session_first_output" "$empty_session_second_output" "$empty_session_third_output"; do
  CODEX_PROOF_ROOT="$proof_root" CODEX_HOME="$ROOT" \
    bash "$ROOT/hooks/stop-gate.sh" <"$empty_session_input" >"$output"
done
jq -e --arg marker "$empty_session_foreign_marker" --arg foreign_session "$foreign_session" '
  .decision == "block" and
  (keys | sort) == ["decision", "reason"] and
  (.reason | contains("ECI_STOP_IDENTITY_MALFORMED")) and
  (.reason | contains("ECI_STOP_MARKER_SCAN_UNSAFE") | not) and
  (.reason | contains("ECI_MARKER_SCOPE_MISMATCH") | not) and
  (.reason | contains("ECI_STOP_LOOP_CONTRACT_DEFECT") | not) and
  (.reason | contains($marker) | not) and
  (.reason | contains($foreign_session) | not)
' "$empty_session_first_output" >/dev/null
cmp -s "$empty_session_first_output" "$empty_session_second_output"
cmp -s "$empty_session_first_output" "$empty_session_third_output"
cmp -s "$TMP_ROOT/stop-empty-session-foreign-marker.before" "$empty_session_foreign_marker"
[ ! -e "$proof_root/stop_loop_state" ] && [ ! -L "$proof_root/stop_loop_state" ]
[ ! -e "$proof_root/$foreign_session/stop_loop_state" ] && [ ! -L "$proof_root/$foreign_session/stop_loop_state" ]

# A valid session with a malformed cwd field is still not a license to select
# a foreign marker.  With a healthy bounded scan, the malformed identity must
# be a stateless identity block without foreign ownership disclosure.
proof_root="$TMP_ROOT/proof-stop-malformed-cwd"
mkdir -p "$proof_root/$foreign_session"
printf '%s\n' \
  'scope: malformed-cwd foreign control' \
  "cwd: $ROOT" \
  "session_id: $foreign_session" \
  'created_utc: 2026-08-17T00:00:00Z' \
  >"$proof_root/$foreign_session/eci_active"
malformed_cwd_input="$TMP_ROOT/stop-malformed-cwd-input"
malformed_cwd_first_output="$TMP_ROOT/stop-malformed-cwd-first-output"
malformed_cwd_second_output="$TMP_ROOT/stop-malformed-cwd-second-output"
malformed_cwd_third_output="$TMP_ROOT/stop-malformed-cwd-third-output"
malformed_cwd_foreign_marker="$proof_root/$foreign_session/eci_active"
cp -- "$malformed_cwd_foreign_marker" "$TMP_ROOT/stop-malformed-cwd-foreign-marker.before"
printf '%s\n' \
  '{"session_id":"valid-session","cwd":123,"transcript_path":"","stop_hook_active":false}' \
  >"$malformed_cwd_input"
for output in "$malformed_cwd_first_output" "$malformed_cwd_second_output" "$malformed_cwd_third_output"; do
  CODEX_PROOF_ROOT="$proof_root" CODEX_HOME="$ROOT" \
    bash "$ROOT/hooks/stop-gate.sh" <"$malformed_cwd_input" >"$output"
done
jq -e --arg marker "$malformed_cwd_foreign_marker" --arg foreign_session "$foreign_session" '
  .decision == "block" and
  (keys | sort) == ["decision", "reason"] and
  (.reason | contains("ECI_STOP_IDENTITY_MALFORMED")) and
  (.reason | contains("ECI_STOP_MARKER_SCAN_UNSAFE") | not) and
  (.reason | contains("ECI_MARKER_SCOPE_MISMATCH") | not) and
  (.reason | contains("ECI_STOP_LOOP_CONTRACT_DEFECT") | not) and
  (.reason | contains($marker) | not) and
  (.reason | contains($foreign_session) | not)
' "$malformed_cwd_first_output" >/dev/null
cmp -s "$malformed_cwd_first_output" "$malformed_cwd_second_output"
cmp -s "$malformed_cwd_first_output" "$malformed_cwd_third_output"
cmp -s "$TMP_ROOT/stop-malformed-cwd-foreign-marker.before" "$malformed_cwd_foreign_marker"
[ ! -e "$proof_root/valid-session/stop_loop_state" ] && [ ! -L "$proof_root/valid-session/stop_loop_state" ]
[ ! -e "$proof_root/$foreign_session/stop_loop_state" ] && [ ! -L "$proof_root/$foreign_session/stop_loop_state" ]

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
  cp -- "$proof_root/$overflow_session/eci_active" "$TMP_ROOT/$overflow_session.eci_active.before"
done
output="$TMP_ROOT/stop-invalid-session-overflow-output"
jq -cn --arg cwd "$ROOT" \
  '{session_id:"invalid!",cwd:$cwd,transcript_path:"",stop_hook_active:false}' |
  CODEX_PROOF_ROOT="$proof_root" CODEX_HOME="$ROOT" \
    bash "$ROOT/hooks/stop-gate.sh" >"$output"
jq -e '
  .decision == "block" and
  (keys | sort) == ["decision", "reason"] and
  (.reason | contains("ECI_STOP_MARKER_SCAN_UNSAFE")) and
  (.reason | contains("ECI_MARKER_SCOPE_MISMATCH") | not) and
  (.reason | contains("ECI_STOP_LOOP_CONTRACT_DEFECT") | not)
' "$output" >/dev/null
for i in $(seq 1 65); do
  overflow_session="overflow-session-$i"
  overflow_marker="$proof_root/$overflow_session/eci_active"
  ! grep -Fq "$overflow_session" "$output"
  ! grep -Fq "$overflow_marker" "$output"
  cmp -s "$TMP_ROOT/$overflow_session.eci_active.before" "$overflow_marker"
  [ ! -e "$proof_root/$overflow_session/stop_loop_state" ] && [ ! -L "$proof_root/$overflow_session/stop_loop_state" ]
done
[ ! -e "$proof_root/invalid!/stop_loop_state" ] && [ ! -L "$proof_root/invalid!/stop_loop_state" ]

printf '%s\n' 'eci marker scope assertions: PASS'
