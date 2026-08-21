#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_ROOT="$(mktemp -d "/tmp/codex-eci-marker-scope.XXXXXX")"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

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
