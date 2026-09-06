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
# FIXTURE_PLANNER supplies deterministic malformed or compound responses.
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
# CALLBACK_TRACE records commands that reach the real recursive hook setup.
CALLBACK_TRACE="$TMP_ROOT/callbacks"
# CHILD_DENIAL is a valid callback envelope whose forwarding must be unchanged.
CHILD_DENIAL='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"[ECI_BROAD_DESTRUCTIVE_DENIED] operation=broad-destructive; fixture child denial"}}'

mkdir -p -- "$FIXTURE_ROOT" "$PROOF_ROOT/$SESSION" "$PROOF_ROOT/$FOREIGN_SESSION" "$FIXTURE_HOME/tmp" \
  "$TMP_ROOT/config/eci" "$TMP_ROOT/state"
cp -a -- "$ROOT/bin" "$FIXTURE_ROOT/"
cp -a -- "$ROOT/hooks" "$FIXTURE_ROOT/"

[ "$(sed -n '2p' -- "$FIXTURE_HOOK")" = 'exit 0' ] || {
  printf '%s\n' 'fixture expected the user-owned validate-bash bypass at line 2' >&2
  exit 1
}
sed -i '2d' -- "$FIXTURE_HOOK"

# This private-only seam selects deterministic planner responses after normal
# hook setup. It does not alter the checked-in provenance path.
sed -i 's/^if codex_plan_provenance_is_current; then$/if true; then/' "$FIXTURE_HOOK"
grep -Fqx 'if true; then' "$FIXTURE_HOOK" || {
  printf '%s\n' 'fixture could not select its malformed planner seam' >&2
  exit 1
}

# Only recursive callbacks receive these protocol failures. The outer hook
# and normal callbacks continue through their actual setup and target routes.
sed -i '/^if true; then$/i\
if [ "${ECI_COMPOUND_SEGMENT_VALIDATION:-false}" = true ]; then\
  printf "%s|" "$command" >>"$FIXTURE_CALLBACK_TRACE"\
  case "${FIXTURE_CALLBACK_MODE:-normal}" in\
    malformed) printf "%s" callback-response-unavailable; exit 0 ;;\
    nonzero) exit 42 ;;\
    denial) printf "%s" "$FIXTURE_CHILD_DENIAL"; exit 0 ;;\
  esac\
fi' "$FIXTURE_HOOK"

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'if [ "${FIXTURE_PLANNER_MODE:-malformed}" = malformed ]; then' \
  '  cat >/dev/null' \
  '  printf "%s\\n" planner-response-unavailable' \
  '  exit 2' \
  'fi' \
  'if [ "${ECI_COMPOUND_SEGMENT_VALIDATION:-false}" = true ]; then' \
  '  cat >/dev/null' \
  '  printf "%s\\n" "{\"decision\":\"allow\"}"' \
  '  exit 0' \
  'fi' \
  'jq -c '\''{decision:"allow",plan:{segments:[{command:"printf first"},{command:(.command | ltrimstr("printf first;"))}],operators:[";"]}}'\''' \
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

  : >"$CALLBACK_TRACE"
  jq -cn --arg cwd "$FIXTURE_ROOT" --arg command "$command" --arg session "$SESSION" \
    '{session_id:$session,cwd:$cwd,tool_input:{command:$command}}' >"$INPUT"
  HOME="$FIXTURE_HOME" CODEX_HOME="$FIXTURE_ROOT" CODEX_PROOF_ROOT="$PROOF_ROOT" \
    XDG_CONFIG_HOME="$TMP_ROOT/config" XDG_STATE_HOME="$TMP_ROOT/state" \
    CODEX_ROLE="${ROLE:-coordinator}" CODEX_HOOK_IS_SUBAGENT="${IS_WORKER:-false}" \
    ECI_COMPOUND_SEGMENT_VALIDATION=false \
    FIXTURE_PLANNER_MODE="${PLANNER_MODE:-malformed}" \
    FIXTURE_CALLBACK_MODE="${CALLBACK_MODE:-normal}" \
    FIXTURE_CALLBACK_TRACE="$CALLBACK_TRACE" FIXTURE_CHILD_DENIAL="$CHILD_DENIAL" \
    PATH="/usr/bin:/bin" bash "$FIXTURE_HOOK" <"$INPUT" >"$OUTPUT"
}

# assert_callbacks proves each test exercised the intended recursive path.
assert_callbacks() {
  [ "$(<"$CALLBACK_TRACE")" = "$1" ] || {
    printf '%s\n' "$ROLE/$CALLBACK_MODE: unexpected recursive callbacks:" >&2
    cat -- "$CALLBACK_TRACE" >&2
    exit 1
  }
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

PLANNER_MODE=compound
for ROLE in coordinator worker; do
  IS_WORKER=false
  MARKER_CODE=ECI_CROSS_SESSION_ACTIVE_MARKER_DENIED
  if [ "$ROLE" = worker ]; then
    IS_WORKER=true
    MARKER_CODE=ECI_CONTROL_OWNER_REQUIRED
  fi

  CALLBACK_MODE=normal
  run_hook 'printf first; printf second'
  assert_callbacks 'printf first| printf second|'
  [ ! -s "$OUTPUT" ] || {
    printf '%s\n' "$ROLE: normal recursive callbacks blocked ordinary work:" >&2
    cat -- "$OUTPUT" >&2
    exit 1
  }

  CALLBACK_MODE=denial
  run_hook 'printf first; printf second'
  assert_callbacks 'printf first|'
  [ "$(<"$OUTPUT")" = "$CHILD_DENIAL" ] || {
    printf '%s\n' "$ROLE: valid child denial was not forwarded unchanged:" >&2
    cat -- "$OUTPUT" >&2
    exit 1
  }

  for CALLBACK_MODE in malformed nonzero; do
    run_hook 'printf first; printf second'
    assert_callbacks 'printf first|'
    [ ! -s "$OUTPUT" ] || {
      printf '%s\n' "$ROLE/$CALLBACK_MODE: recursive callback failure blocked ordinary work:" >&2
      cat -- "$OUTPUT" >&2
      exit 1
    }

    run_hook 'printf first; rm -rf /'
    assert_callbacks 'printf first|'
    jq -e '
      .hookSpecificOutput.permissionDecision == "deny" and
      (.hookSpecificOutput.permissionDecisionReason | contains("[ECI_BROAD_DESTRUCTIVE_DENIED]")) and
      (.hookSpecificOutput.permissionDecisionReason | contains("operation=broad-destructive"))
    ' "$OUTPUT" >/dev/null || {
      printf '%s\n' "$ROLE/$CALLBACK_MODE: recursive callback failure bypassed the later broad target:" >&2
      cat -- "$OUTPUT" >&2
      exit 1
    }

    run_hook "printf first; printf marker > $PROOF_ROOT/$FOREIGN_SESSION/eci_active"
    assert_callbacks 'printf first|'
    jq -e --arg code "$MARKER_CODE" --arg target "$PROOF_ROOT/$FOREIGN_SESSION/eci_active" '
      .hookSpecificOutput.permissionDecision == "deny" and
      (.hookSpecificOutput.permissionDecisionReason | contains("[" + $code + "]")) and
      (.hookSpecificOutput.permissionDecisionReason | contains($target))
    ' "$OUTPUT" >/dev/null || {
      printf '%s\n' "$ROLE/$CALLBACK_MODE: recursive callback failure bypassed the later foreign marker:" >&2
      cat -- "$OUTPUT" >&2
      exit 1
    }
    printf '%s\n' "$ROLE/$CALLBACK_MODE: ordinary compound allowed; broad and foreign targets denied"
  done
done

printf '%s\n' 'planner protocol fallback: PASS'
