#!/usr/bin/env bash

# Regression for R11 command admission.  This is not a shell-syntax firewall:
# ordinary commands with punctuation, expansion, unfamiliar tools, or ordinary
# repository targets must proceed.  Only a resolved concrete wrong target is
# a hook denial.

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
FIXTURE_TMP="${HOME:?}/tmp"
mkdir -p -- "$FIXTURE_TMP"
FIXTURE_TMP="$(realpath -e -- "$FIXTURE_TMP")"
TMP_ROOT="$(mktemp -d "$FIXTURE_TMP/eci-command-syntax.XXXXXX")"
TMP_ROOT="$(realpath -e -- "$TMP_ROOT")"
case "$TMP_ROOT" in
"$FIXTURE_TMP"/*) ;;
*)
  printf 'fixture root is outside physical home temp: tmp_root=%s fixture_tmp=%s\n' \
    "$TMP_ROOT" "$FIXTURE_TMP" >&2
  exit 1
  ;;
esac
trap 'rm -rf -- "$TMP_ROOT"' EXIT

SESSION_ID="t00-command-syntax"
PROOF_ROOT="$TMP_ROOT/proof"
MARKER="$PROOF_ROOT/$SESSION_ID/eci_active"
OTHER_MARKER="$PROOF_ROOT/other-session/eci_active"
INPUT="$TMP_ROOT/input.json"
OUTPUT="$TMP_ROOT/output.json"
ERROR_OUTPUT="$TMP_ROOT/error.txt"
EVIDENCE_DIR="$PROOF_ROOT/$SESSION_ID/evidence"
OUTSIDE_PROOF="$TMP_ROOT/outside-proof.txt"

mkdir -p -- "$(dirname -- "$MARKER")" "$(dirname -- "$OTHER_MARKER")" \
  "$EVIDENCE_DIR" "$TMP_ROOT/config/eci" "$TMP_ROOT/state"
printf '%s\n' \
  'scope: command syntax regression' \
  "cwd: $ROOT" \
  "session_id: $SESSION_ID" \
  'created_utc: 2026-08-28T00:00:00Z' \
  >"$MARKER"
printf '%s\n' \
  'scope: foreign-session control fixture' \
  "cwd: $ROOT" \
  'session_id: other-session' \
  'created_utc: 2026-08-28T00:00:00Z' \
  >"$OTHER_MARKER"
printf '%s\n' enforcing >"$TMP_ROOT/config/eci/command-gate-mode"
printf '%s\n' outside >"$OUTSIDE_PROOF"
ln -s -- "$OUTSIDE_PROOF" "$EVIDENCE_DIR/outside-link"

# The live hook is deliberately disabled by the user while source repairs are
# under review.  Test an isolated copy and prove the test did not alter live
# hook behavior.
[ "$(sed -n '2p' -- "$ROOT/hooks/validate-bash.sh")" = 'exit 0' ] || {
  printf '%s\n' 'expected the live user-owned validate-bash bypass at line 2' >&2
  exit 1
}
TEST_HOOK_ROOT="$TMP_ROOT/private-hooks"
cp -a -- "$ROOT/hooks" "$TEST_HOOK_ROOT"
sed -i '2d' -- "$TEST_HOOK_ROOT/validate-bash.sh"
[ "$(sed -n '2p' -- "$ROOT/hooks/validate-bash.sh")" = 'exit 0' ] || {
  printf '%s\n' 'test modified the live user-owned validate-bash bypass' >&2
  exit 1
}

run_hook() {
  local command="$1" role="$2" hook_status

  jq -cn \
    --arg session_id "$SESSION_ID" \
    --arg cwd "$ROOT" \
    --arg command "$command" \
    '{session_id:$session_id,cwd:$cwd,tool_input:{command:$command}}' \
    >"$INPUT"

  set +e
  CODEX_TMPDIR="$FIXTURE_TMP" TMPDIR="$FIXTURE_TMP" \
    HOME="$HOME" CODEX_HOME="$ROOT" CODEX_PROOF_ROOT="$PROOF_ROOT" \
    CODEX_ROLE="$role" CODEX_HOOK_IS_SUBAGENT="$([ "$role" = worker ] && printf true || printf false)" \
    XDG_CONFIG_HOME="$TMP_ROOT/config" XDG_STATE_HOME="$TMP_ROOT/state" \
    PATH="$ROOT/bin:$PATH" \
    bash "$TEST_HOOK_ROOT/validate-bash.sh" <"$INPUT" >"$OUTPUT" 2>"$ERROR_OUTPUT"
  hook_status=$?
  set -e
  [ "$hook_status" -eq 0 ] || {
    printf 'private command-syntax hook exited nonzero: status=%s command=%s\n' "$hook_status" "$command" >&2
    cat -- "$ERROR_OUTPUT" >&2
    exit 1
  }
  [ ! -s "$ERROR_OUTPUT" ] || {
    printf 'private command-syntax hook wrote stderr for command=%s\n' "$command" >&2
    cat -- "$ERROR_OUTPUT" >&2
    exit 1
  }
}

assert_allowed() {
  local command="$1" role

  for role in coordinator worker; do
    run_hook "$command" "$role"
    [ ! -s "$OUTPUT" ] || {
      printf 'ordinary command was hook-denied for role=%s: %s\n' "$role" "$command" >&2
      cat -- "$OUTPUT" >&2
      exit 1
    }
  done
}

assert_broad_root_denied() {
  local role

  for role in coordinator worker; do
    run_hook 'rm -rf / | head -n 20' "$role"
    jq -e '
      .hookSpecificOutput.permissionDecision == "deny" and
      (.hookSpecificOutput.permissionDecisionReason |
        contains("[ECI_BROAD_DESTRUCTIVE_DENIED]") and
        contains("operation=broad-destructive") and
        contains("token=/") and
        contains("path=/") and
        contains("predicate=broad-destructive-root")
      )
    ' "$OUTPUT" >/dev/null || {
      printf 'broad root denial contract mismatch for role=%s\n' "$role" >&2
      cat -- "$OUTPUT" >&2
      exit 1
    }
  done
}

assert_current_marker_denied() {
  local role predicate

  for role in coordinator worker; do
    case "$role" in
    coordinator) predicate=coordinator-proof-control ;;
    worker) predicate=worker-proof-control ;;
    esac
    run_hook "touch $MARKER | head -n 20" "$role"
    jq -e --arg marker "$MARKER" --arg predicate "$predicate" '
      .hookSpecificOutput.permissionDecision == "deny" and
      (.hookSpecificOutput.permissionDecisionReason |
        contains("[ECI_PLAN_LIVE_CONTROL_DENIED]") and
        contains("operation=plan-segment") and
        contains("token=" + $marker) and
        contains("path=" + $marker) and
        contains("predicate=" + $predicate)
      )
    ' "$OUTPUT" >/dev/null || {
      printf 'current marker denial contract mismatch for role=%s\n' "$role" >&2
      cat -- "$OUTPUT" >&2
      exit 1
    }
  done
}

assert_foreign_marker_denied() {
  local role command foreign_marker

  foreign_marker="$(realpath -e -- "$OTHER_MARKER")"
  for command in \
    "touch $OTHER_MARKER | head -n 20" \
    "printf '%s\\n' marker > $OTHER_MARKER"; do
    for role in coordinator worker; do
      run_hook "$command" "$role"
      jq -e --arg foreign_marker "$foreign_marker" '
        .hookSpecificOutput.permissionDecision == "deny" and
        (.hookSpecificOutput.permissionDecisionReason |
          contains("[ECI_CROSS_SESSION_ACTIVE_MARKER_DENIED]") and
          contains("operation=eci-control") and
          contains("target=" + $foreign_marker) and
          contains("foreign_session=other-session")
        )
      ' "$OUTPUT" >/dev/null || {
        printf 'foreign marker denial contract mismatch for role=%s: %s\n' "$role" "$command" >&2
        cat -- "$OUTPUT" >&2
        exit 1
      }
    done
  done
}

assert_worker_fsck_lost_found_denied() {
  run_hook 'env git fsck --lost-found | head -n 20' worker
  jq -e '
    .hookSpecificOutput.permissionDecision == "deny" and
    (.hookSpecificOutput.permissionDecisionReason |
      contains("[ECI_WORKER_GIT_OWNERSHIP_DENIED]") and
      contains("operation=worker-git-ownership") and
      contains("token=--lost-found") and
      contains("predicate=worker-git-ownership") and
      contains("worker argv selects Git fsck --lost-found writer") and
      (contains("predicate=worker-env-git-fsck-lost-found") | not)
    )
  ' "$OUTPUT" >/dev/null || {
    printf '%s\n' 'worker Git fsck --lost-found denial contract mismatch' >&2
    cat -- "$OUTPUT" >&2
    exit 1
  }
}

# These commands may fail when executed in a real shell (for example an
# unfamiliar executable), but the admission hook must not deny them merely for
# their form.  The test executes only the hook, never these commands.
assert_allowed $'printf \'%s\\n\' first\nprintf \'%s\\n\' second'
assert_allowed 'printf "%s\\n" "$(printf nested)"'
assert_allowed 'novel-inspection-tool --format table'
assert_allowed 'novel-inspection-tool --format table | head -n 20'
assert_allowed 'env'
assert_allowed "env | sort | rg '^PATH='"
assert_allowed 'printenv'
assert_allowed 'env --unset=9FOO novel-tool'
assert_allowed "env FOO=bar python3 -c 'print(1)'"
assert_allowed 'file -C -m hooks/validate-bash.sh | head -n 20'
assert_allowed 'touch hooks/validate-bash.sh'
assert_allowed "printf '%s\\n' ordinary > $ROOT/.eci-normal-redirect-target"
assert_allowed "printf '%s\\n' nested <(printf '%s\\n' input)"
assert_allowed 'printf "%s\n" brace-{one,two}'
assert_allowed 'printf "%s\n" `printf nested`'
assert_allowed 'printf "%s\n" background &'
assert_allowed "cat $EVIDENCE_DIR/outside-link"
assert_allowed "rm -f -- $ROOT/.eci-normal-target-does-not-exist"
assert_allowed 'cat /tmp/ordinary-eci-inspection'
assert_allowed 'rm -f -- /tmp/ordinary-eci-scratch'
assert_allowed 'TMPDIR=/tmp novel-tool --scratch'

# `git fsck --lost-found` writes recovered objects under .git/lost-found.  Its
# worker denial preserves the concrete Git ownership boundary, independent of
# the surrounding env wrapper or pipeline syntax.
assert_worker_fsck_lost_found_denied

# Retain only resolved targets that would concretely escape the session's
# ownership/control boundary.  A pipe or quote cannot change this outcome.
assert_broad_root_denied
assert_current_marker_denied
assert_foreign_marker_denied

printf '%s\n' 'target-aware command syntax regression: PASS'
