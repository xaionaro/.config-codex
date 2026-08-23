#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
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

printf '%s\n' 'eci marker scope assertions: PASS'
