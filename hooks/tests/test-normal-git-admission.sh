#!/usr/bin/env bash

set -euo pipefail

SOURCE_ROOT="$(cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TMP_ROOT="$(mktemp -d "${CODEX_TMPDIR:-${HOME:?}/tmp}/eci-normal-git-admission.XXXXXX")"
trap 'rm -rf -- "$TMP_ROOT"' EXIT HUP INT TERM

# The live hook intentionally has a temporary line-2 bypass while this repair
# is in progress.  Exercise a complete private runtime with only that bypass
# removed, so this test continues to validate the actual gate source.
HOME_ROOT="$TMP_ROOT/home"
RUNTIME_ROOT="$HOME_ROOT/.codex"
mkdir -p -- "$RUNTIME_ROOT" "$TMP_ROOT/config/eci" "$TMP_ROOT/state"
cp -a -- "$SOURCE_ROOT/hooks" "$RUNTIME_ROOT"
cp -- "$SOURCE_ROOT/hooks.json" "$RUNTIME_ROOT/hooks.json"
mkdir -p -- "$RUNTIME_ROOT/bin"
cp -a -- "$SOURCE_ROOT/bin/eci-command-gate-mode" "$RUNTIME_ROOT/bin/"
[ "$(sed -n '2p' -- "$RUNTIME_ROOT/hooks/validate-bash.sh")" = 'exit 0' ] || {
  printf '%s\n' 'expected the live validate-bash temporary bypass at line 2' >&2
  exit 1
}
sed -i '2d' -- "$RUNTIME_ROOT/hooks/validate-bash.sh"
BASH_LAUNCHER="$(jq -er '.hooks.PreToolUse[] | select(.matcher == "^Bash$") | .hooks[] | select(.type == "command") | .command' "$RUNTIME_ROOT/hooks.json")"
[ "$BASH_LAUNCHER" = 'bash "$HOME/.codex/hooks/validate-bash.sh"' ] || {
  printf 'unexpected copied Bash launcher: %s\n' "$BASH_LAUNCHER" >&2
  exit 1
}

# Refresh only this private fixture's planner receipt. This keeps the test on
# the real hook path while avoiding a source build for every Git probe.
PLANNER_DIR="$RUNTIME_ROOT/hooks/lib/eci-command-plan-go"
(
  cd -- "$PLANNER_DIR"
  /usr/lib/go-1.24/bin/go build -trimpath -buildvcs=false -o eci-command-plan .
)
chmod 755 -- "$PLANNER_DIR/eci-command-plan"
planner_go_mod_sha="$(sha256sum -- "$PLANNER_DIR/go.mod" | awk '{print $1}')"
planner_main_sha="$(sha256sum -- "$PLANNER_DIR/main.go" | awk '{print $1}')"
planner_classifier_sha="$(sha256sum -- "$PLANNER_DIR/classifier.go" | awk '{print $1}')"
planner_binary_sha="$(sha256sum -- "$PLANNER_DIR/eci-command-plan" | awk '{print $1}')"
planner_binary_size="$(stat -Lc '%s' -- "$PLANNER_DIR/eci-command-plan")"
awk \
  -v go_mod="$planner_go_mod_sha" \
  -v main="$planner_main_sha" \
  -v classifier="$planner_classifier_sha" \
  -v binary="$planner_binary_sha" \
  -v size="$planner_binary_size" '
  $1 == "source_go.mod_sha256" { print $1 "\t" go_mod; next }
  $1 == "source_main.go_sha256" { print $1 "\t" main; next }
  $1 == "source_classifier.go_sha256" { print $1 "\t" classifier; next }
  $1 == "binary_sha256" { print $1 "\t" binary; next }
  $1 == "binary_size" { print $1 "\t" size; next }
  { print }
' "$PLANNER_DIR/.eci-command-plan.provenance" >"$PLANNER_DIR/.eci-command-plan.provenance.tmp"
mv -- "$PLANNER_DIR/.eci-command-plan.provenance.tmp" "$PLANNER_DIR/.eci-command-plan.provenance"
chmod 600 -- "$PLANNER_DIR/.eci-command-plan.provenance"

printf '%s\n' enforcing >"$TMP_ROOT/config/eci/command-gate-mode"

REPO="$TMP_ROOT/repo"
FOREIGN_REPO="$TMP_ROOT/foreign-repo"
NON_REPO="$TMP_ROOT/not-a-repository"
for path in "$REPO" "$FOREIGN_REPO"; do
  mkdir -p -- "$path"
  git -C "$path" init -q
  git -C "$path" config user.email normal-git-test@example.invalid
  git -C "$path" config user.name 'Normal Git Test'
  printf 'base\n' >"$path/file.txt"
  printf '{"fixture":true}\n' >"$path/hooks.json"
  printf '# Fixture\n' >"$path/README.md"
  git -C "$path" add -- file.txt hooks.json README.md
  git -C "$path" commit -qm initial
done
REPO="$(realpath -e -- "$REPO")"
FOREIGN_REPO="$(realpath -e -- "$FOREIGN_REPO")"
mkdir -p -- "$NON_REPO"
NON_REPO="$(realpath -e -- "$NON_REPO")"

SESSION='normal-git-session'
PROOF_ROOT="$TMP_ROOT/proof"
mkdir -p -- "$PROOF_ROOT/$SESSION"
printf '%s\n' \
  'scope: normal Git admission regression' \
  "cwd: $REPO" \
  "session_id: $SESSION" \
  'created_utc: 2026-08-28T00:00:00Z' \
  >"$PROOF_ROOT/$SESSION/eci_active"

# A second valid marker gives timeout replay tests a concrete foreign control
# target without changing the callback's current-session binding.
FOREIGN_SESSION='foreign-timeout-session'
FOREIGN_TIMEOUT_CONTROL_INNER="$PROOF_ROOT/$FOREIGN_SESSION"
mkdir -p -- "$FOREIGN_TIMEOUT_CONTROL_INNER"
printf '%s\n' \
  'scope: foreign timeout marker regression' \
  "cwd: $FOREIGN_REPO" \
  "session_id: $FOREIGN_SESSION" \
  'created_utc: 2026-08-28T00:00:00Z' \
  >"$FOREIGN_TIMEOUT_CONTROL_INNER/eci_active"

# The callback PATH is deliberately deterministic because the planner must
# resolve a bare timeout from the callback's original PATH, before the hook
# prepends its own trusted utility directories.
BASE_CALLBACK_PATH="$RUNTIME_ROOT/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
CALLBACK_PATH="$BASE_CALLBACK_PATH"

FAKE_TIMEOUT_LAUNCH_DIR="$TMP_ROOT/fake-timeout-launch"
FAKE_TIMEOUT_ACCEPT_DIR="$TMP_ROOT/fake-timeout-accept"
FAKE_TIMEOUT_INVALID_DIR="$TMP_ROOT/fake-timeout-invalid"
FAKE_TIMEOUT_REQUIRED_DIR="$TMP_ROOT/fake-timeout-required"
mkdir -p -- "$FAKE_TIMEOUT_LAUNCH_DIR" "$FAKE_TIMEOUT_ACCEPT_DIR" "$FAKE_TIMEOUT_INVALID_DIR" "$FAKE_TIMEOUT_REQUIRED_DIR"
printf '%s\n' \
  '#!/bin/bash' \
  'set -euo pipefail' \
  'signal=""' \
  'while (($#)); do' \
  '  case "$1" in' \
  '    --signal) signal="${2:-}"; shift 2 ;;' \
  '    --signal=*) signal="${1#--signal=}"; shift ;;' \
  '    -s) signal="${2:-}"; shift 2 ;;' \
  '    -s*) signal="${1#-s}"; shift ;;' \
  '    --preserve-status|--foreground|--verbose|-p|-f|-v) shift ;;' \
  '    --) shift; break ;;' \
  '    -*) exit 125 ;;' \
  '    *) shift; break ;;' \
  '  esac' \
  'done' \
  'case "$signal" in' \
  '  0|invalid-signal) exit 125 ;;' \
  'esac' \
  'exec "$@"' \
  >"$FAKE_TIMEOUT_LAUNCH_DIR/timeout"
printf '%s\n' '#!/bin/bash' 'exit 0' >"$FAKE_TIMEOUT_ACCEPT_DIR/timeout"
printf '%s\n' '#!/bin/bash' 'exit 125' >"$FAKE_TIMEOUT_INVALID_DIR/timeout"
printf '%s\n' \
  '#!/bin/bash' \
  'set -euo pipefail' \
  '[ "${PROBE_REQUIRED-}" = present ] || exit 125' \
  'signal=""' \
  'while (($#)); do' \
  '  case "$1" in' \
  '    --signal) signal="${2:-}"; shift 2 ;;' \
  '    --signal=*) signal="${1#--signal=}"; shift ;;' \
  '    -s) signal="${2:-}"; shift 2 ;;' \
  '    -s*) signal="${1#-s}"; shift ;;' \
  '    --preserve-status|--foreground|--verbose|-p|-f|-v) shift ;;' \
  '    --) shift; break ;;' \
  '    -*) exit 125 ;;' \
  '    *) shift; break ;;' \
  '  esac' \
  'done' \
  'case "$signal" in' \
  '  0|invalid-signal) exit 125 ;;' \
  'esac' \
  'exec "$@"' \
  >"$FAKE_TIMEOUT_REQUIRED_DIR/timeout"
chmod 755 -- "$FAKE_TIMEOUT_LAUNCH_DIR/timeout" "$FAKE_TIMEOUT_ACCEPT_DIR/timeout" "$FAKE_TIMEOUT_INVALID_DIR/timeout" "$FAKE_TIMEOUT_REQUIRED_DIR/timeout"

run_hook() {
  local command="$1" role="${2:-coordinator}" path_mode="${3:-configured}" probe_required="${4:-absent}" callback_cwd="${5:-$REPO}" timeout_replays="${6:-[]}" compound_replay="${7:-false}" output="$TMP_ROOT/output.json" stderr=/dev/null
  local subagent=false
  if [ "$role" = worker ]; then
    subagent=true
  fi
  local -a runner=(/bin/bash)
  if [ "${DEBUG_GIT_HOOK:-false}" = true ]; then
    runner=(/bin/bash -x)
    stderr="$TMP_ROOT/hook-xtrace.log"
  fi
  jq -cn --arg session "$SESSION" --arg cwd "$callback_cwd" --arg command "$command" --argjson timeout_replays "$timeout_replays" \
    '{session_id:$session,cwd:$cwd,timeout_replays:$timeout_replays,tool_input:{command:$command}}' |
    (
      export HOME="$HOME_ROOT" CODEX_HOME="$RUNTIME_ROOT" CODEX_PROOF_ROOT="$PROOF_ROOT"
      export CODEX_ROLE="$role" CODEX_HOOK_IS_SUBAGENT="$subagent"
      export XDG_CONFIG_HOME="$TMP_ROOT/config" XDG_STATE_HOME="$TMP_ROOT/state"
      export ECI_COMPOUND_SEGMENT_VALIDATION="$compound_replay"
      case "$probe_required" in
        present) export PROBE_REQUIRED=present ;;
        absent) unset PROBE_REQUIRED ;;
        wrong) export PROBE_REQUIRED=wrong ;;
        *) printf 'unknown probe-required mode: %s\n' "$probe_required" >&2; exit 64 ;;
      esac
      case "$path_mode" in
        configured)
          PATH="$CALLBACK_PATH" "${runner[@]}" -c "$BASH_LAUNCHER"
          ;;
        raw)
          PATH="$CALLBACK_PATH" "${runner[@]}" "$RUNTIME_ROOT/hooks/validate-bash.sh"
          ;;
        empty)
          PATH="" "${runner[@]}" "$RUNTIME_ROOT/hooks/validate-bash.sh"
          ;;
        unset)
          /bin/bash -c 'unset PATH; source "$1"' -- "$RUNTIME_ROOT/hooks/validate-bash.sh"
          ;;
        *) printf 'unknown callback PATH mode: %s\n' "$path_mode" >&2; exit 64 ;;
      esac
    ) >"$output" 2>>"$stderr"
  printf '%s\n' "$output"
}

assert_allowed() {
  local command="$1" role="${2:-coordinator}" path_mode="${3:-configured}" probe_required="${4:-absent}" callback_cwd="${5:-$REPO}" timeout_replays="${6:-[]}" compound_replay="${7:-false}" output
  output="$(run_hook "$command" "$role" "$path_mode" "$probe_required" "$callback_cwd" "$timeout_replays" "$compound_replay")"
  if [ -s "$output" ]; then
    printf 'ordinary Git command was denied: %q\n' "$command" >&2
    cat -- "$output" >&2
    return 1
  fi
}

assert_denied_code() {
  local command="$1" code="$2" role="${3:-coordinator}" detail="${4:-}" path_mode="${5:-configured}" probe_required="${6:-absent}" callback_cwd="${7:-$REPO}" timeout_replays="${8:-[]}" compound_replay="${9:-false}" output
  output="$(run_hook "$command" "$role" "$path_mode" "$probe_required" "$callback_cwd" "$timeout_replays" "$compound_replay")"
  jq -e --arg code "[$code]" --arg detail "$detail" '
    .hookSpecificOutput.permissionDecision == "deny" and
    (.hookSpecificOutput.permissionDecisionReason | contains($code)) and
    ($detail == "" or (.hookSpecificOutput.permissionDecisionReason | contains($detail)))
  ' "$output" >/dev/null || {
    printf 'expected concrete %s denial for: %q\n' "$code" "$command" >&2
    cat -- "$output" >&2
    [ "${DEBUG_GIT_HOOK:-false}" != true ] || tail -n 240 -- "$TMP_ROOT/hook-xtrace.log" >&2
    return 1
  }
}

# This bounded target exercises the copied real hook's timeout replay path
# without requiring the broad normal-Git matrix to finish. The default matrix
# below remains its established entrypoint and coverage surface.
run_foreign_timeout_marker_target() {
  local role current_timeout_inner outside_timeout_inner missing_first_marker stale_foreign_cwd target_failures=0
  local observed_replays opaque_replays duplicate_replays malformed_replays prefix_mismatch_replays

  current_timeout_inner="$PROOF_ROOT/$SESSION"
  outside_timeout_inner="$TMP_ROOT/timeout-outside-proof"
  missing_first_marker='../foreign-timeout-missing-first/eci_active'
  cp -- "$FAKE_TIMEOUT_LAUNCH_DIR/timeout" "$FOREIGN_TIMEOUT_CONTROL_INNER/timeout"
  cp -- "$FAKE_TIMEOUT_LAUNCH_DIR/timeout" "$current_timeout_inner/timeout"
  mkdir -p -- "$outside_timeout_inner"
  cp -- "$FAKE_TIMEOUT_LAUNCH_DIR/timeout" "$outside_timeout_inner/timeout"
  printf '%s\n' ordinary >"$outside_timeout_inner/eci_active"
  chmod 755 -- "$FOREIGN_TIMEOUT_CONTROL_INNER/timeout" "$current_timeout_inner/timeout" "$outside_timeout_inner/timeout"
  CALLBACK_PATH="$FAKE_TIMEOUT_ACCEPT_DIR:$BASE_CALLBACK_PATH"

  # An actual observed timeout child may not mutate a valid foreign marker.
  for role in coordinator worker; do
    assert_denied_code "cd $FOREIGN_TIMEOUT_CONTROL_INNER; ./timeout 5 rm eci_active" ECI_CROSS_SESSION_ACTIVE_MARKER_DENIED "$role" \
      "foreign_session=$FOREIGN_SESSION"
  done

  # An invalid first marker-shaped operand is advisory; the later valid
  # foreign marker is the concrete target that must still be found.
  for role in coordinator worker; do
    assert_denied_code "cd $FOREIGN_TIMEOUT_CONTROL_INNER; ./timeout 5 rm $missing_first_marker eci_active" ECI_CROSS_SESSION_ACTIVE_MARKER_DENIED "$role" \
      "foreign_session=$FOREIGN_SESSION" || target_failures=1
  done

  # A structurally valid record is not live after its declared CWD disappears.
  # Keep collecting both expected RED controls before returning their failure.
  stale_foreign_cwd="$TMP_ROOT/stale-foreign-timeout-cwd"
  mkdir -p -- "$stale_foreign_cwd"
  printf '%s\n' \
    'scope: foreign timeout marker regression' \
    "cwd: $stale_foreign_cwd" \
    "session_id: $FOREIGN_SESSION" \
    'created_utc: 2026-08-28T00:00:00Z' \
    >"$FOREIGN_TIMEOUT_CONTROL_INNER/eci_active"
  rmdir -- "$stale_foreign_cwd"
  for role in coordinator worker; do
    assert_allowed "cd $FOREIGN_TIMEOUT_CONTROL_INNER; ./timeout 5 rm eci_active" "$role" || target_failures=1
  done
  printf '%s\n' \
    'scope: foreign timeout marker regression' \
    "cwd: $FOREIGN_REPO" \
    "session_id: $FOREIGN_SESSION" \
    'created_utc: 2026-08-28T00:00:00Z' \
    >"$FOREIGN_TIMEOUT_CONTROL_INNER/eci_active"
  [ "$target_failures" -eq 0 ] || return 1

  # The current marker remains covered by its existing direct-control route.
  assert_denied_code "cd $current_timeout_inner; ./timeout 5 rm eci_active" ECI_PLAN_LIVE_CONTROL_DENIED worker \
    "path=$(realpath -e -- "$current_timeout_inner/eci_active")"

  # A pathname observation alone is advisory. Missing, malformed, and
  # path/session-owner-mismatched candidates must not become foreign-marker
  # denials for either role.
  rm -- "$FOREIGN_TIMEOUT_CONTROL_INNER/eci_active"
  for role in coordinator worker; do
    assert_allowed "cd $FOREIGN_TIMEOUT_CONTROL_INNER; ./timeout 5 rm eci_active" "$role"
  done
  printf '%s\n' 'scope: malformed timeout marker' >"$FOREIGN_TIMEOUT_CONTROL_INNER/eci_active"
  for role in coordinator worker; do
    assert_allowed "cd $FOREIGN_TIMEOUT_CONTROL_INNER; ./timeout 5 rm eci_active" "$role"
  done
  printf '%s\n' \
    'scope: foreign timeout marker regression' \
    "cwd: $FOREIGN_REPO" \
    'session_id: mismatched-timeout-owner' \
    'created_utc: 2026-08-28T00:00:00Z' \
    >"$FOREIGN_TIMEOUT_CONTROL_INNER/eci_active"
  for role in coordinator worker; do
    assert_allowed "cd $FOREIGN_TIMEOUT_CONTROL_INNER; ./timeout 5 rm eci_active" "$role"
  done

  # A same-named ordinary file outside the proof root is not an ECI marker.
  for role in coordinator worker; do
    assert_allowed "cd $outside_timeout_inner; ./timeout 5 rm eci_active" "$role"
  done

  # Restore the valid foreign marker to distinguish a valid observed replay
  # from absent, opaque, duplicate, malformed, and prefix-mismatched facts.
  printf '%s\n' \
    'scope: foreign timeout marker regression' \
    "cwd: $FOREIGN_REPO" \
    "session_id: $FOREIGN_SESSION" \
    'created_utc: 2026-08-28T00:00:00Z' \
    >"$FOREIGN_TIMEOUT_CONTROL_INNER/eci_active"
  observed_replays="$(jq -cn --arg cwd "$FOREIGN_TIMEOUT_CONTROL_INNER" '
    [{segment:1,parent_segment:2,prefix:["./timeout","5"],cwd:$cwd,command_path:"",command_path_set:false,command_path_exported:false,disposition:"observed"}]
  ')"
  opaque_replays="$(jq -c '.[0].disposition = "opaque" | .' <<<"$observed_replays")"
  duplicate_replays="$(jq -c '[.[0], .[0]]' <<<"$observed_replays")"
  malformed_replays='[{"segment":1}]'
  prefix_mismatch_replays="$(jq -c '.[0].prefix = ["./timeout", "6"] | .' <<<"$observed_replays")"
  for role in coordinator worker; do
    assert_denied_code "./timeout 5 rm eci_active" ECI_CROSS_SESSION_ACTIVE_MARKER_DENIED "$role" \
      "foreign_session=$FOREIGN_SESSION" configured absent "$REPO" "$observed_replays" true
    # A synthetic observed replay must also scan beyond an invalid first
    # marker-shaped operand to the later live foreign marker.
    assert_denied_code "./timeout 5 rm $missing_first_marker eci_active" ECI_CROSS_SESSION_ACTIVE_MARKER_DENIED "$role" \
      "foreign_session=$FOREIGN_SESSION" configured absent "$REPO" "$observed_replays" true
    assert_allowed "./timeout 5 rm eci_active" "$role" configured absent "$REPO" '[]' true
    assert_allowed "./timeout 5 rm eci_active" "$role" configured absent "$REPO" "$opaque_replays" true
    assert_allowed "./timeout 5 rm eci_active" "$role" configured absent "$REPO" "$duplicate_replays" true
    assert_allowed "./timeout 5 rm eci_active" "$role" configured absent "$REPO" "$malformed_replays" true
    assert_allowed "./timeout 5 rm eci_active" "$role" configured absent "$REPO" "$prefix_mismatch_replays" true
  done
}

case "${NORMAL_GIT_ADMISSION_TARGET:-full}" in
  full) ;;
  foreign-timeout-marker)
    run_foreign_timeout_marker_target
    printf '%s\n' 'normal Git admission foreign-timeout-marker target: PASS'
    exit 0
    ;;
  *)
    printf 'unknown normal Git admission target: %s\n' "${NORMAL_GIT_ADMISSION_TARGET}" >&2
    exit 64
    ;;
esac

# Normal commits must not need an approval artifact or a review receipt.
assert_allowed "git commit -m 'ordinary commit'"

# Command spelling, `-C`, environment setup, and punctuation are not an
# accidental mistake by themselves.  The target remains this active repo.
assert_allowed "git -C $REPO commit -am 'ordinary commit'"
assert_allowed "env GIT_EDITOR=true /usr/bin/git -C $REPO commit --allow-empty -m 'ordinary commit'"
assert_allowed "printf prepare && git -C $REPO commit -m 'ordinary commit'"
[ ! -e "$REPO/.git-commit-approved-once" ]
[ ! -e "$PROOF_ROOT/$SESSION/eci-required-critics.json" ]
[ ! -e "$PROOF_ROOT/$SESSION/eci-commit-admitted" ]

# Targeted index changes are ordinary repository work.
assert_allowed "git -C $REPO add -- file.txt"
assert_allowed "git -C $REPO restore --staged -- file.txt"
assert_allowed "git -C $REPO reset -- file.txt"

# A worker's local index may stage explicit same-repository paths. The private
# fixture removes the live temporary bypass above, so these exercise the real
# planner and target resolver rather than an early exit.
assert_allowed "git add -- hooks.json" worker
assert_allowed "git add README.md" worker

# A timeout-wrapped Git child is exposed only after the exact callback-PATH
# timeout executable launches the planner's harmless replacement child. The
# launch fixture therefore keeps normal named-path work ordinary and preserves
# the resolved foreign and broad target boundaries for both roles.
CALLBACK_PATH="$FAKE_TIMEOUT_LAUNCH_DIR:$BASE_CALLBACK_PATH"
for role in coordinator worker; do
  assert_allowed "timeout --signal TERM 5 git add -- hooks.json" "$role"
  assert_denied_code "timeout --signal TERM 5 git -C $FOREIGN_REPO add -- file.txt" ECI_GIT_CROSS_SCOPE_DENIED "$role" \
    "active_repo=$REPO target_repo=$FOREIGN_REPO"
  assert_denied_code "timeout --signal TERM 5 git add ." ECI_BROAD_DESTRUCTIVE_DENIED "$role" \
    "effect=whole-worktree-staging target=$REPO selector=."
  assert_denied_code "timeout --signal TERM 5 env git -C $FOREIGN_REPO add -- file.txt" ECI_GIT_CROSS_SCOPE_DENIED "$role" \
    "active_repo=$REPO target_repo=$FOREIGN_REPO"
  assert_denied_code "timeout --signal TERM 5 env git add ." ECI_BROAD_DESTRUCTIVE_DENIED "$role" \
    "effect=whole-worktree-staging target=$REPO selector=."
  assert_allowed "timeout --signal '\$TIMEOUT_SIGNAL' 5 git add ." "$role"
done
# Conditional prefixes poison replay state: the direct timeout remains
# ordinary instead of borrowing an observation from the callback context.
assert_allowed "printf prepare && timeout --signal TERM 5 git add ." worker
# Timeout does not turn history acceptance into local index work after a
# positive launch observation.
assert_denied_code "timeout --signal TERM 5 git commit --allow-empty -m 'worker commit'" ECI_WORKER_GIT_OWNERSHIP_DENIED worker \
  "token=commit"

# State-only semicolon prefixes carry the actual shell CWD and PATH into the
# observed timeout record. The copied launcher must preserve the outer callback
# CWD for active-scope checks while Git resolves its child from this state.
STATE_CHILD="$REPO/timeout-state-child"
mkdir -p -- "$STATE_CHILD"
cp -- "$FAKE_TIMEOUT_LAUNCH_DIR/timeout" "$STATE_CHILD/timeout"
cp -- "$FAKE_TIMEOUT_LAUNCH_DIR/timeout" "$FOREIGN_REPO/timeout"
chmod 755 -- "$STATE_CHILD/timeout" "$FOREIGN_REPO/timeout"
CALLBACK_PATH="$FAKE_TIMEOUT_ACCEPT_DIR:$BASE_CALLBACK_PATH"
for role in coordinator worker; do
  assert_denied_code "cd $STATE_CHILD; ./timeout --signal TERM 5 git add :/" ECI_BROAD_DESTRUCTIVE_DENIED "$role" \
    "effect=whole-worktree-staging target=$REPO selector=:/"
  assert_denied_code "cd $STATE_CHILD; cd $FOREIGN_REPO; ./timeout --signal TERM 5 git add ." ECI_GIT_CROSS_SCOPE_DENIED "$role" \
    "active_repo=$REPO target_repo=$FOREIGN_REPO"
done
# A later absolute cd back to the outer repository is also modeled, not a
# stale reuse of the first transition's directory.
cp -- "$FAKE_TIMEOUT_LAUNCH_DIR/timeout" "$REPO/timeout"
chmod 755 -- "$REPO/timeout"
for role in coordinator worker; do
  assert_denied_code "cd $STATE_CHILD; cd $REPO; ./timeout --signal TERM 5 git add ." ECI_BROAD_DESTRUCTIVE_DENIED "$role" \
    "effect=whole-worktree-staging target=$REPO selector=."
done

# An observed timeout child resolves its relative writer target from the
# semicolon-modeled CWD. The real inner control file remains denied, while an
# outer hardlink to that control file does not falsely deny an inner ordinary
# eci_active name during recursive segment validation.
TIMEOUT_CONTROL_INNER="$PROOF_ROOT/$SESSION"
TIMEOUT_ORDINARY_INNER="$TMP_ROOT/timeout-ordinary-inner"
OUTER_CONTROL_ALIAS="$REPO/eci_active"
mkdir -p -- "$TIMEOUT_ORDINARY_INNER"
cp -- "$FAKE_TIMEOUT_LAUNCH_DIR/timeout" "$TIMEOUT_CONTROL_INNER/timeout"
cp -- "$FAKE_TIMEOUT_LAUNCH_DIR/timeout" "$TIMEOUT_ORDINARY_INNER/timeout"
printf '%s\n' ordinary >"$TIMEOUT_ORDINARY_INNER/eci_active"
chmod 755 -- "$TIMEOUT_CONTROL_INNER/timeout" "$TIMEOUT_ORDINARY_INNER/timeout"
TIMEOUT_CONTROL_MARKER="$(realpath -e -- "$TIMEOUT_CONTROL_INNER/eci_active")"
CALLBACK_PATH="$FAKE_TIMEOUT_ACCEPT_DIR:$BASE_CALLBACK_PATH"
assert_denied_code "cd $TIMEOUT_CONTROL_INNER; ./timeout 5 rm eci_active" ECI_PLAN_LIVE_CONTROL_DENIED worker \
  "path=$TIMEOUT_CONTROL_MARKER"
ln -- "$TIMEOUT_CONTROL_INNER/eci_active" "$OUTER_CONTROL_ALIAS"
assert_allowed "cd $TIMEOUT_ORDINARY_INNER; ./timeout 5 rm eci_active" worker configured absent "$REPO"
rm -- "$OUTER_CONTROL_ALIAS"

# A planner-observed timeout child runs from its replay CWD.  That must catch
# a foreign active marker for either role without changing the outer callback
# scope anchor.  A nonlaunching timeout and invalid replay facts remain
# ordinary because they do not establish a child write.
cp -- "$FAKE_TIMEOUT_LAUNCH_DIR/timeout" "$FOREIGN_TIMEOUT_CONTROL_INNER/timeout"
chmod 755 -- "$FOREIGN_TIMEOUT_CONTROL_INNER/timeout"
for role in coordinator worker; do
  assert_denied_code "cd $FOREIGN_TIMEOUT_CONTROL_INNER; ./timeout 5 rm eci_active" ECI_CROSS_SESSION_ACTIVE_MARKER_DENIED "$role" \
    "foreign_session=$FOREIGN_SESSION"
done
cp -- "$FAKE_TIMEOUT_ACCEPT_DIR/timeout" "$FOREIGN_TIMEOUT_CONTROL_INNER/timeout"
chmod 755 -- "$FOREIGN_TIMEOUT_CONTROL_INNER/timeout"
for role in coordinator worker; do
  assert_allowed "cd $FOREIGN_TIMEOUT_CONTROL_INNER; ./timeout 5 rm eci_active" "$role"
done

FOREIGN_TIMEOUT_OBSERVED_REPLAYS="$(jq -cn --arg cwd "$FOREIGN_TIMEOUT_CONTROL_INNER" '
  [{segment:1,parent_segment:2,prefix:["./timeout","5"],cwd:$cwd,command_path:"",command_path_set:false,command_path_exported:false,disposition:"observed"}]
')"
FOREIGN_TIMEOUT_OPAQUE_REPLAYS="$(jq -c '.[0].disposition = "opaque" | .' <<<"$FOREIGN_TIMEOUT_OBSERVED_REPLAYS")"
FOREIGN_TIMEOUT_DUPLICATE_REPLAYS="$(jq -c '[.[0], .[0]]' <<<"$FOREIGN_TIMEOUT_OBSERVED_REPLAYS")"
FOREIGN_TIMEOUT_PREFIX_MISMATCH_REPLAYS="$(jq -c '.[0].prefix = ["./timeout", "6"] | .' <<<"$FOREIGN_TIMEOUT_OBSERVED_REPLAYS")"
for role in coordinator worker; do
  assert_denied_code "./timeout 5 rm eci_active" ECI_CROSS_SESSION_ACTIVE_MARKER_DENIED "$role" \
    "foreign_session=$FOREIGN_SESSION" configured absent "$REPO" "$FOREIGN_TIMEOUT_OBSERVED_REPLAYS" true
  assert_allowed "./timeout 5 rm eci_active" "$role" configured absent "$REPO" '[]' true
  assert_allowed "./timeout 5 rm eci_active" "$role" configured absent "$REPO" "$FOREIGN_TIMEOUT_OPAQUE_REPLAYS" true
  assert_allowed "./timeout 5 rm eci_active" "$role" configured absent "$REPO" "$FOREIGN_TIMEOUT_DUPLICATE_REPLAYS" true
  assert_allowed "./timeout 5 rm eci_active" "$role" configured absent "$REPO" '[{"segment":1}]' true
  assert_allowed "./timeout 5 rm eci_active" "$role" configured absent "$REPO" "$FOREIGN_TIMEOUT_PREFIX_MISMATCH_REPLAYS" true
done

# A recursive callback consumes only planner-shaped replay records. A scalar
# replay entry is advisory metadata, so an otherwise ordinary compound stays
# ordinary instead of becoming an internal planner denial.
assert_allowed 'printf ordinary; printf still-ordinary' coordinator configured absent "$REPO" '[1]' true

# PATH state is likewise literal and ordered: assignments, export changes,
# set-empty, unset, and a known nonlaunch cannot borrow the callback PATH.
for role in coordinator worker; do
  CALLBACK_PATH="$FAKE_TIMEOUT_ACCEPT_DIR:$BASE_CALLBACK_PATH"
  assert_denied_code "PATH=$FAKE_TIMEOUT_LAUNCH_DIR; timeout --signal TERM 5 git add ." ECI_BROAD_DESTRUCTIVE_DENIED "$role" \
    "effect=whole-worktree-staging target=$REPO selector=."
  assert_denied_code "export PATH=$FAKE_TIMEOUT_LAUNCH_DIR; timeout --signal TERM 5 git add ." ECI_BROAD_DESTRUCTIVE_DENIED "$role" \
    "effect=whole-worktree-staging target=$REPO selector=."
  assert_denied_code "PATH=$FAKE_TIMEOUT_LAUNCH_DIR; export -n PATH; timeout --signal TERM 5 git add ." ECI_BROAD_DESTRUCTIVE_DENIED "$role" \
    "effect=whole-worktree-staging target=$REPO selector=."
  CALLBACK_PATH="$FAKE_TIMEOUT_LAUNCH_DIR:$BASE_CALLBACK_PATH"
  assert_allowed "PATH=; timeout --signal TERM 5 git add ." "$role"
  assert_allowed "unset PATH; timeout --signal TERM 5 git add ." "$role"
  assert_allowed "PATH=$FAKE_TIMEOUT_ACCEPT_DIR; timeout --signal TERM 5 git add ." "$role"
  assert_allowed "PATH=$FAKE_TIMEOUT_ACCEPT_DIR && timeout --signal TERM 5 git add ." "$role"
  assert_allowed 'PATH=$TIMEOUT_PATH; timeout --signal TERM 5 git add .' "$role"
  assert_allowed "printf harmless; timeout --signal TERM 5 git add ." "$role"
done
CALLBACK_PATH="$FAKE_TIMEOUT_LAUNCH_DIR:$BASE_CALLBACK_PATH"

# The probe keeps inherited callback variables other than its explicitly bound
# PWD and PATH. A fake timeout requiring this variable distinguishes an actual
# child launch from an executable that merely accepts the timeout prefix.
CALLBACK_PATH="$FAKE_TIMEOUT_REQUIRED_DIR:$BASE_CALLBACK_PATH"
assert_denied_code "timeout --signal TERM 5 git commit --allow-empty -m 'worker commit'" ECI_WORKER_GIT_OWNERSHIP_DENIED worker \
  "token=commit" configured present
assert_allowed "timeout --signal TERM 5 git commit --allow-empty -m 'worker commit'" worker configured absent

# Shell PATH lookup retains callback-CWD empty and relative components. The
# test invokes the copied hook through /bin/bash so the raw callback PATH is
# not consumed by the harness before the hook captures it.
mkdir -p -- "$REPO/bin"
cp -- "$FAKE_TIMEOUT_LAUNCH_DIR/timeout" "$REPO/timeout"
cp -- "$FAKE_TIMEOUT_LAUNCH_DIR/timeout" "$REPO/bin/timeout"
chmod 755 -- "$REPO/timeout" "$REPO/bin/timeout"
for CALLBACK_PATH in "$TMP_ROOT/missing:bin" : . bin; do
  assert_denied_code "timeout --signal TERM 5 git commit --allow-empty -m 'worker commit'" ECI_WORKER_GIT_OWNERSHIP_DENIED worker \
    "token=commit" raw
done

# Explicitly empty PATH differs from an empty component: bare timeout remains
# opaque when PATH is empty or unset, while a direct absolute or ./timeout
# spelling launches because the replacement child is an absolute executable.
assert_allowed "timeout --signal TERM 5 git commit --allow-empty -m 'worker commit'" worker empty
assert_allowed "timeout --signal TERM 5 git commit --allow-empty -m 'worker commit'" worker unset
assert_denied_code "$FAKE_TIMEOUT_LAUNCH_DIR/timeout --signal TERM 5 git commit --allow-empty -m 'worker commit'" ECI_WORKER_GIT_OWNERSHIP_DENIED worker \
  "token=commit" empty
assert_denied_code "$FAKE_TIMEOUT_LAUNCH_DIR/timeout --signal TERM 5 git commit --allow-empty -m 'worker commit'" ECI_WORKER_GIT_OWNERSHIP_DENIED worker \
  "token=commit" unset
assert_denied_code "./timeout --signal TERM 5 git commit --allow-empty -m 'worker commit'" ECI_WORKER_GIT_OWNERSHIP_DENIED worker \
  "token=commit" empty
assert_denied_code "./timeout --signal TERM 5 git commit --allow-empty -m 'worker commit'" ECI_WORKER_GIT_OWNERSHIP_DENIED worker \
  "token=commit" unset

# An executable that accepts the same prefix but does not start its child must
# leave foreign and broad Git forms ordinary. This is an E2E A/B check against
# the launching executable above, not a timeout option-name table.
CALLBACK_PATH="$FAKE_TIMEOUT_ACCEPT_DIR:$BASE_CALLBACK_PATH"
for role in coordinator worker; do
  assert_allowed "timeout --signal TERM 5 git -C $FOREIGN_REPO add -- file.txt" "$role"
  assert_allowed "timeout --signal TERM 5 git add ." "$role"
  assert_allowed "timeout --signal TERM 5 env git -C $FOREIGN_REPO add -- file.txt" "$role"
  assert_allowed "timeout --signal TERM 5 env git add ." "$role"
  assert_allowed "timeout --signal 0 5 git add ." "$role"
done
# A nonlaunching timeout is opaque to each worker recognizer. It must not
# reconstruct a direct Git child or a piped branch mutation from argv alone.
assert_allowed "timeout --signal TERM 5 git commit --allow-empty -m 'worker commit'" worker
assert_allowed "timeout --signal TERM 5 git merge topic" worker
assert_allowed "printf prepare | timeout --signal TERM 5 git branch --delete topic" worker

# A fake timeout that rejects its signal and a structurally malformed prefix
# both have no observed child launch. They remain ordinary runtime behavior.
CALLBACK_PATH="$FAKE_TIMEOUT_INVALID_DIR:$BASE_CALLBACK_PATH"
for role in coordinator worker; do
  assert_allowed "timeout --signal invalid-signal 5 git add ." "$role"
done
CALLBACK_PATH="$FAKE_TIMEOUT_LAUNCH_DIR:$BASE_CALLBACK_PATH"
assert_allowed "timeout not-a-duration git add ." worker
assert_allowed "timeout --not-a-timeout-option 5 git add ." worker
assert_allowed "chronic git add ." worker
CALLBACK_PATH="$BASE_CALLBACK_PATH"

# Preserve only resolved accidental-risk boundaries.
assert_denied_code "git -C $REPO reset --hard" ECI_BROAD_DESTRUCTIVE_DENIED
assert_denied_code "env GIT_EDITOR=true /usr/bin/git -C $REPO reset --hard" ECI_BROAD_DESTRUCTIVE_DENIED
assert_denied_code "git -C $FOREIGN_REPO add -- file.txt" ECI_GIT_CROSS_SCOPE_DENIED
# The same resolved foreign target stays cross-scope through ordinary wrapper
# and sequencing spellings. Punctuation is not the boundary; the target is.
assert_denied_code "env GIT_EDITOR=true /usr/bin/git -C $FOREIGN_REPO add -- file.txt" ECI_GIT_CROSS_SCOPE_DENIED
assert_denied_code "printf prepare && git -C $FOREIGN_REPO add -- file.txt" ECI_GIT_CROSS_SCOPE_DENIED
# A target that does not resolve to a repository has no known cross-scope
# mutation. Let Git report its ordinary runtime error instead of manufacturing
# an ECI denial from incomplete target information.
assert_allowed "git -C $NON_REPO add -- file.txt"

# The worker keeps the same concrete target/effect boundary: foreign staging,
# a known whole-worktree selector, and a working-tree reset remain denied.
assert_denied_code "git -C $FOREIGN_REPO add -- file.txt" ECI_GIT_CROSS_SCOPE_DENIED worker \
  "active_repo=$REPO target_repo=$FOREIGN_REPO"
assert_denied_code "git add ." ECI_BROAD_DESTRUCTIVE_DENIED worker \
  "effect=whole-worktree-staging target=$REPO"
assert_denied_code "git reset --hard" ECI_BROAD_DESTRUCTIVE_DENIED worker \
  "effect=reset-working-tree target=$REPO"

printf '%s\n' 'normal Git admission: PASS'
