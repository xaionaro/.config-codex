#!/usr/bin/env bash

set -Eeuo pipefail

# ROOT identifies the checked-in Codex source tree under test.
ROOT="$(cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
# TMP_PARENT keeps the private hook fixture out of the repository tree.
TMP_PARENT="${CODEX_TMPDIR:-${TMPDIR:-${HOME:?}/tmp}}"
mkdir -p -- "$TMP_PARENT"
# TMP_ROOT contains the complete disposable planner-response fixture.
TMP_ROOT="$(mktemp -d "$TMP_PARENT/eci-planner-protocol-fallback.XXXXXX")"
# TMP_ROOT is canonicalized before its paths are embedded in marker records.
TMP_ROOT="$(realpath -e -- "$TMP_ROOT")"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

# FIXTURE_HOME is the temporary HOME whose `.codex` child owns the hook.
FIXTURE_HOME="$TMP_ROOT/home"
# FIXTURE_ROOT is the copied source tree selected through FIXTURE_HOME.
FIXTURE_ROOT="$FIXTURE_HOME/.codex"
# FIXTURE_HOOK is the private validating hook with only the user bypass removed.
FIXTURE_HOOK="$FIXTURE_ROOT/hooks/validate-bash.sh"
# FIXTURE_PLANNER is replaced by a deterministic malformed-response executable.
FIXTURE_PLANNER="$FIXTURE_ROOT/hooks/lib/eci-command-plan-go/eci-command-plan"
# PROOF_ROOT holds the current-session marker consumed by the fixture hook.
PROOF_ROOT="$TMP_ROOT/proof"
# SESSION names the one marker owned by this isolated test.
SESSION="planner-protocol-fallback"
# FOREIGN_SESSION names a second proof record whose marker must remain untouched.
FOREIGN_SESSION="planner-protocol-fallback-peer"
# INPUT carries one PreToolUse callback request into the fixture hook.
INPUT="$TMP_ROOT/input.json"
# OUTPUT records the fixture hook's sole JSON response.
OUTPUT="$TMP_ROOT/output.json"

mkdir -p -- "$FIXTURE_HOME" "$PROOF_ROOT/$SESSION" "$PROOF_ROOT/$FOREIGN_SESSION" "$FIXTURE_HOME/tmp" \
  "$TMP_ROOT/config/eci" "$TMP_ROOT/state"
cp -a -- "$ROOT/bin" "$FIXTURE_ROOT/"
cp -a -- "$ROOT/hooks" "$FIXTURE_ROOT/"

[ "$(sed -n '2p' -- "$FIXTURE_HOOK")" = 'exit 0' ] || {
  printf '%s\n' 'fixture expected the user-owned validate-bash bypass at line 2' >&2
  exit 1
}
sed -i '2d' -- "$FIXTURE_HOOK"

# This private-only seam injects a malformed planner response after all normal
# hook setup has completed. It does not alter the checked-in provenance path.
sed -i 's/^if codex_plan_provenance_is_current; then$/if true; then/' "$FIXTURE_HOOK"
grep -Fqx 'if true; then' "$FIXTURE_HOOK" || {
  printf '%s\n' 'fixture could not select its malformed planner seam' >&2
  exit 1
}

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'cat >/dev/null' \
  'printf "%s\\n" planner-response-unavailable' \
  'exit 2' \
  >"$FIXTURE_PLANNER"
chmod 755 -- "$FIXTURE_PLANNER"

printf '%s\n' enforcing >"$TMP_ROOT/config/eci/command-gate-mode"
printf '%s\n' \
  'scope: planner response fallback regression' \
  "cwd: $FIXTURE_ROOT" \
  "session_id: $SESSION" \
  'created_utc: 2026-08-28T00:00:00Z' \
  >"$PROOF_ROOT/$SESSION/eci_active"
printf '%s\n' \
  'scope: planner response peer fixture' \
  "cwd: $FIXTURE_ROOT" \
  "session_id: $FOREIGN_SESSION" \
  'created_utc: 2026-08-28T00:00:00Z' \
  >"$PROOF_ROOT/$FOREIGN_SESSION/eci_active"

# run_hook submits one command without executing it, then preserves the hook
# response for the assertion immediately following the call.
#
# Example: run_hook 'printf ordinary'.
run_hook() {
  local command="$1"

  jq -cn --arg cwd "$FIXTURE_ROOT" --arg command "$command" --arg session "$SESSION" \
    '{session_id:$session,cwd:$cwd,tool_input:{command:$command}}' >"$INPUT"
  HOME="$FIXTURE_HOME" CODEX_HOME="$FIXTURE_ROOT" CODEX_PROOF_ROOT="$PROOF_ROOT" \
    XDG_CONFIG_HOME="$TMP_ROOT/config" XDG_STATE_HOME="$TMP_ROOT/state" \
    PATH="/usr/bin:/bin" bash "$FIXTURE_HOOK" <"$INPUT" >"$OUTPUT"
}

run_hook 'printf planner-response-fallback-benign'
[ ! -s "$OUTPUT" ] || {
  printf '%s\n' 'malformed planner response blocked ordinary work:' >&2
  cat -- "$OUTPUT" >&2
  exit 1
}

run_hook 'rm -rf /'
jq -e '
  .hookSpecificOutput.permissionDecision == "deny" and
  (.hookSpecificOutput.permissionDecisionReason | contains("[ECI_BROAD_DESTRUCTIVE_DENIED]")) and
  (.hookSpecificOutput.permissionDecisionReason | contains("operation=broad-destructive"))
' "$OUTPUT" >/dev/null || {
  printf '%s\n' 'malformed planner response bypassed the concrete broad-target boundary:' >&2
  cat -- "$OUTPUT" >&2
  exit 1
}

run_hook "printf marker > $PROOF_ROOT/$FOREIGN_SESSION/eci_active"
jq -e '
  .hookSpecificOutput.permissionDecision == "deny" and
  (.hookSpecificOutput.permissionDecisionReason | contains("[ECI_CROSS_SESSION_ACTIVE_MARKER_DENIED]")) and
  (.hookSpecificOutput.permissionDecisionReason | contains("foreign_session=planner-protocol-fallback-peer"))
' "$OUTPUT" >/dev/null || {
  printf '%s\n' 'malformed planner response bypassed the cross-session marker boundary:' >&2
  cat -- "$OUTPUT" >&2
  exit 1
}

printf '%s\n' 'planner protocol fallback: PASS'
