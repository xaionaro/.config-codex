#!/usr/bin/env bash

set -euo pipefail

SOURCE_ROOT="$(cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TMP_ROOT="$(mktemp -d "${CODEX_TMPDIR:-${HOME:?}/tmp}/eci-normal-git-admission.XXXXXX")"
TMP_ROOT="$(realpath -e -- "$TMP_ROOT")"
trap 'chmod -R u+w -- "$TMP_ROOT"; rm -rf -- "$TMP_ROOT"' EXIT HUP INT TERM

# Exercise a complete private runtime, removing only a leading bypass after
# the shebang, blank lines, and comments. Never change the live runtime.
HOME_ROOT="$TMP_ROOT/home"
RUNTIME_ROOT="$HOME_ROOT/.codex"
mkdir -p -- "$RUNTIME_ROOT" "$TMP_ROOT/config/eci" "$TMP_ROOT/state"
cp -a -- "$SOURCE_ROOT/hooks" "$RUNTIME_ROOT"
if [ -n "${NORMAL_GIT_ADMISSION_HOOK_SOURCE:-}" ]; then
  cp -- "$NORMAL_GIT_ADMISSION_HOOK_SOURCE" "$RUNTIME_ROOT/hooks/validate-bash.sh"
fi
cp -- "$SOURCE_ROOT/hooks.json" "$RUNTIME_ROOT/hooks.json"
mkdir -p -- "$RUNTIME_ROOT/bin"
cp -a -- "$SOURCE_ROOT/bin/eci-command-gate-mode" "$RUNTIME_ROOT/bin/"
awk '
  BEGIN { prefix = 1 }
  prefix && /^exit 0$/ { prefix = 0; next }
  prefix && !/^#/ && !/^[[:space:]]*$/ { prefix = 0 }
  { print }
' "$RUNTIME_ROOT/hooks/validate-bash.sh" >"$RUNTIME_ROOT/hooks/validate-bash.sh.tmp"
mv -- "$RUNTIME_ROOT/hooks/validate-bash.sh.tmp" "$RUNTIME_ROOT/hooks/validate-bash.sh"
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

KIMI_PROOF_ROOT_RAW="$TMP_ROOT/kimi-proof"
mkdir -p -- "$KIMI_PROOF_ROOT_RAW"
KIMI_PROOF_ROOT="$(realpath -e -- "$KIMI_PROOF_ROOT_RAW")"
KIMI_FOREIGN_SESSION='foreign-kimi-session'
KIMI_FOREIGN_MARKER="$KIMI_PROOF_ROOT/$KIMI_FOREIGN_SESSION/eci_active"
mkdir -p -- "${KIMI_FOREIGN_MARKER%/*}"
printf '%s\n' \
  'scope: foreign Kimi marker regression' \
  "cwd: $FOREIGN_REPO" \
  "session_id: $KIMI_FOREIGN_SESSION" \
  'created_utc: 2026-08-28T00:00:00Z' \
  >"$KIMI_FOREIGN_MARKER"

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

# Leading punctuation is valid in a proof-session identity.  Keep concrete
# foreign markers for the timeout replay boundary instead of re-validating
# their spelling in the consumer under test.
FOREIGN_UNDERSCORE_SESSION='_foreign-timeout-session'
FOREIGN_DASH_SESSION='-foreign-timeout-session'
for foreign_session in "$FOREIGN_UNDERSCORE_SESSION" "$FOREIGN_DASH_SESSION"; do
  mkdir -p -- "$PROOF_ROOT/$foreign_session"
  printf '%s\n' \
    'scope: foreign timeout marker regression' \
    "cwd: $FOREIGN_REPO" \
    "session_id: $foreign_session" \
    'created_utc: 2026-08-28T00:00:00Z' \
    >"$PROOF_ROOT/$foreign_session/eci_active"
done

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
  local command="$1" role="${2:-coordinator}" path_mode="${3:-configured}" probe_required="${4:-absent}" callback_cwd="${5:-$REPO}" timeout_replays="${6:-[]}" compound_replay="${7:-false}" compound_handoff="${8:-true}" output="$TMP_ROOT/output.json" stderr=/dev/null
  local compound_cwd="${9:-$callback_cwd}"
  local compound_physical
  compound_physical="$(realpath -e -- "$compound_cwd" 2>/dev/null || true)"
  local compound_handoff_token=normal-git-test-handoff
  local fd9_mode="${10:-none}" fd9_token="${11:-$compound_handoff_token}"
  local subagent=false
  if [ "$role" = worker ]; then
    subagent=true
  fi
  local -a runner=(/bin/bash)
  if [ "${DEBUG_GIT_HOOK:-false}" = true ]; then
    runner=(/bin/bash -x)
    stderr="$TMP_ROOT/hook-xtrace.log"
  fi
  jq -cn \
    --arg session "$SESSION" \
    --arg cwd "$callback_cwd" \
    --arg compound_cwd "$compound_cwd" \
    --arg compound_physical "$compound_physical" \
    --arg handoff_token "$compound_handoff_token" \
    --arg command "$command" \
    --arg command_path "$CALLBACK_PATH" \
    --argjson timeout_replays "$timeout_replays" \
    --argjson compound_validation "$compound_replay" \
    '{session_id:$session,cwd:$cwd,timeout_replays:$timeout_replays,tool_input:{command:$command}} |
      if $compound_validation then
        .eci_compound_segment = {
          validation: true,
          cwd: $compound_cwd,
          cwd_known: true,
          cwd_unknown: false,
          cwd_candidates: [$compound_cwd],
          cwd_physical: $compound_physical,
          cwd_physical_candidates: [$compound_physical],
          reachability: "reachable",
          command_path: $command_path,
          command_path_set: true,
          command_path_exported: true,
          handoff_token: $handoff_token
        }
      else . end' |
    (
      export HOME="$HOME_ROOT" CODEX_HOME="$RUNTIME_ROOT" CODEX_PROOF_ROOT="$PROOF_ROOT" KIMI_PROOF_ROOT="$KIMI_PROOF_ROOT"
      export CODEX_ROLE="$role" CODEX_HOOK_IS_SUBAGENT="$subagent"
      export XDG_CONFIG_HOME="$TMP_ROOT/config" XDG_STATE_HOME="$TMP_ROOT/state"
      if [ "$compound_replay" = true ] && [ "$compound_handoff" = true ]; then
        exec 9<<<"$fd9_token"
      elif [ "$fd9_mode" = sentinel ]; then
        exec 9<<<"sentinel"
      elif [ "$fd9_mode" = blocking ]; then
        exec 9<"${COMPOUND_FD9_FIFO:?missing blocking FD9 FIFO}"
      fi
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

run_compound_handoff_boundary_target() {
  local inner fifo writer hook_pid status output nonlive_session nonlive_dir nonlive_marker

  inner="$TMP_ROOT/compound-handoff-inner"
  fifo="$TMP_ROOT/compound-handoff-blocking.fifo"
  mkdir -p -- "$inner"
  printf '%s\n' ordinary >"$inner/eci_active"
  mkfifo -- "$fifo"
  ln -- "$PROOF_ROOT/$SESSION/eci_active" "$REPO/eci_active"

  foreign_marker="$FOREIGN_TIMEOUT_CONTROL_INNER/eci_active"
  foreign_goal_state="$FOREIGN_TIMEOUT_CONTROL_INNER/goal_state"
  foreign_wait="$FOREIGN_TIMEOUT_CONTROL_INNER/eci_wait"
  printf '%s\n' pending >"$foreign_goal_state"
  printf '%s\n' pending >"$foreign_wait"
  printf '%s\n' ordinary >"$TMP_ROOT/ordinary-copy"

  # Source-only operands are inputs, not writes; only destination/effect
  # positions may route a worker through the control boundary.
  assert_allowed "cp $foreign_marker $TMP_ROOT/ordinary-copy" worker
  assert_allowed "ln $foreign_marker $TMP_ROOT/ordinary-link" worker
  assert_allowed "dd if=$foreign_marker" worker
  assert_allowed "cat $foreign_goal_state" worker
  for target in "$foreign_marker" "$foreign_goal_state" "$foreign_wait"; do
    output="$(run_hook "rm $target" worker configured absent "$REPO")"
    jq -e --arg target "$target" '.hookSpecificOutput.permissionDecision == "deny" and (.hookSpecificOutput.permissionDecisionReason | contains($target))' "$output" >/dev/null || {
      printf 'recognized foreign control write was not denied: %s\n' "$(cat -- "$output")" >&2
      return 1
    }
  done
  assert_allowed "cp $KIMI_FOREIGN_MARKER $TMP_ROOT/kimi-marker-copy" worker
  output="$(run_hook "rm $KIMI_FOREIGN_MARKER" worker configured absent "$REPO")"
  jq -e --arg target "$KIMI_FOREIGN_MARKER" '.hookSpecificOutput.permissionDecision == "deny" and (.hookSpecificOutput.permissionDecisionReason | contains("ECI_CROSS_SESSION_ACTIVE_MARKER_DENIED")) and (.hookSpecificOutput.permissionDecisionReason | contains($target))' "$output" >/dev/null || {
    printf 'configured Kimi foreign marker write was not dedicated-denied: %s\n' "$(cat -- "$output")" >&2
    return 1
  }
  KIMI_FOREIGN_HARDLINK="$TMP_ROOT/kimi-foreign-marker-hardlink"
  ln -- "$KIMI_FOREIGN_MARKER" "$KIMI_FOREIGN_HARDLINK"
  output="$(run_hook "rm $KIMI_FOREIGN_HARDLINK" worker configured absent "$REPO")"
  jq -e --arg target "$KIMI_FOREIGN_MARKER" '.hookSpecificOutput.permissionDecision == "deny" and (.hookSpecificOutput.permissionDecisionReason | contains("ECI_CROSS_SESSION_ACTIVE_MARKER_DENIED")) and (.hookSpecificOutput.permissionDecisionReason | contains($target))' "$output" >/dev/null || {
    printf 'configured Kimi foreign marker hardlink was not dedicated-denied: %s\n' "$(cat -- "$output")" >&2
    return 1
  }
  rm -- "$KIMI_FOREIGN_HARDLINK"
  KIMI_FOREIGN_GOAL_STATE="${KIMI_FOREIGN_MARKER%/*}/goal_state"
  KIMI_FOREIGN_WAIT="${KIMI_FOREIGN_MARKER%/*}/eci_wait"
  printf '%s\n' pending >"$KIMI_FOREIGN_GOAL_STATE"
  printf '%s\n' pending >"$KIMI_FOREIGN_WAIT"
  for target in "$KIMI_FOREIGN_GOAL_STATE" "$KIMI_FOREIGN_WAIT"; do
    assert_denied_code "rm $target" ECI_CONTROL_OWNER_REQUIRED worker
  done
  printf '%s\n' 'scope: malformed Kimi marker' >"$KIMI_FOREIGN_MARKER"
  assert_allowed "rm $KIMI_FOREIGN_MARKER" worker
  printf '%s\n' \
    "cwd: $FOREIGN_REPO" \
    "session_id: $KIMI_FOREIGN_SESSION" \
    'created_utc: 2026-08-28T00:00:00Z' \
    >"$KIMI_FOREIGN_MARKER"
  assert_allowed "rm $KIMI_FOREIGN_MARKER" worker
  printf '%s\n' \
    'scope: foreign Kimi goal state' \
    "cwd: $FOREIGN_REPO" \
    "session_id: $KIMI_FOREIGN_SESSION" \
    'created_utc: 2026-08-28T00:00:00Z' \
    >"${KIMI_FOREIGN_MARKER%/*}/goal_state"
  assert_denied_code "rm ${KIMI_FOREIGN_MARKER%/*}/goal_state" ECI_CONTROL_OWNER_REQUIRED worker

  # A foreign marker pathname without a recognized live record is not itself
  # a live-control effect. Keep the exact proof/session spelling visible to
  # the adapter so the generic reserved-name route cannot blanket-deny these
  # advisory, malformed, mismatched, and stale observations.
  nonlive_session=foreign-nonlive-session
  nonlive_dir="$PROOF_ROOT/$nonlive_session"
  nonlive_marker="$nonlive_dir/eci_active"
  mkdir -p -- "$nonlive_dir"
  assert_allowed "rm $nonlive_marker" worker
  printf '%s\n' 'scope: malformed foreign marker' >"$nonlive_marker"
  assert_allowed "rm $nonlive_marker" worker
  printf '%s\n' \
    'scope: foreign marker mismatch' \
    "cwd: $FOREIGN_REPO" \
    'session_id: another-foreign-session' \
    'created_utc: 2026-08-28T00:00:00Z' \
    >"$nonlive_marker"
  assert_allowed "rm $nonlive_marker" worker
  printf '%s\n' \
    'scope: stale foreign marker' \
    "cwd: $TMP_ROOT/nonexistent-stale-cwd" \
    "session_id: $nonlive_session" \
    'created_utc: 2026-08-28T00:00:00Z' \
    >"$nonlive_marker"
  assert_allowed "rm $nonlive_marker" worker
  assert_allowed "./timeout 5 rm $nonlive_marker" worker

  # An ordinary callback with an inherited sentinel must not consume FD9 or
  # activate recursive metadata merely because the descriptor exists.
  assert_allowed "printf ordinary" worker configured absent "$REPO" '[]' false none sentinel

  # A blocking inherited descriptor proves the adapter gates its read behind
  # structurally eligible handoff metadata. The callback must finish before
  # the writer closes the FIFO.
  (
    sleep 0.1
    exec 8>"$fifo"
    sleep 12
  ) &
  writer=$!
  COMPOUND_FD9_FIFO="$fifo" run_hook "printf ordinary" worker configured absent "$REPO" '[]' false true none blocking >"$TMP_ROOT/blocking-run.out" &
  hook_pid=$!
  status=0
  for _ in $(seq 1 80); do
    if ! kill -0 "$hook_pid" 2>/dev/null; then
      break
    fi
    sleep 0.1
  done
  if kill -0 "$hook_pid" 2>/dev/null; then
    kill "$hook_pid" 2>/dev/null || true
    wait "$hook_pid" 2>/dev/null || status=$?
  else
    wait "$hook_pid" || status=$?
  fi
  kill "$writer" 2>/dev/null || true
  wait "$writer" 2>/dev/null || true
  [ "$status" -eq 0 ] || {
    printf 'ordinary callback blocked or failed while FD9 was inherited: status=%s\n' "$status" >&2
    return 1
  }

  # Shape-valid metadata from an ordinary callback still cannot activate the
  # recursive route when FD9 carries only an inherited sentinel.
  output="$(run_hook "rm eci_active" worker configured absent "$REPO" '[]' true false "$inner" sentinel)"
  jq -e '.hookSpecificOutput.permissionDecision == "deny" and (.hookSpecificOutput.permissionDecisionReason | contains("ECI_PLAN_LIVE_CONTROL_DENIED"))' "$output" >/dev/null || {
    printf 'forged compound metadata activated without the handoff token: %s\n' "$(cat -- "$output")" >&2
    return 1
  }

  local replay
  replay="$(jq -cn --arg cwd "$inner" '[{segment:1,parent_segment:2,prefix:["./timeout","5"],cwd:$cwd,command_path:"",command_path_set:false,command_path_exported:false,disposition:"observed"}]')"
  output="$(run_hook "./timeout 5 rm eci_active" worker configured absent "$REPO" "$replay" true true "$inner")"
  [ ! -s "$output" ] || {
    printf 'valid compound handoff was denied: %s\n' "$(cat -- "$output")" >&2
    return 1
  }

  # Capture the planner-selected timeout record at the actual recursive FD9
  # child boundary, then compare it with the equivalent explicit replay. The
  # compared fields are the effective CWD, replay disposition/prefix, command,
  # and decision; the parent callback record is deliberately filtered out.
  cp -- "$FAKE_TIMEOUT_LAUNCH_DIR/timeout" "$inner/timeout"
  chmod 755 -- "$inner/timeout"
  local replay_trace actual_replay explicit_replay
  replay_trace="$TMP_ROOT/fd9-replay-trace"
  : >"$replay_trace"
  actual_replay="$(jq -cn --arg cwd "$inner" --arg command_path "$CALLBACK_PATH" '[{segment:1,parent_segment:2,prefix:["./timeout","5"],cwd:$cwd,command_path:$command_path,command_path_set:true,command_path_exported:true,disposition:"observed"}]')"
  ECI_TEST_REPLAY_TRACE_FILE="$replay_trace" assert_allowed "cd $inner; ./timeout 5 printf ordinary" worker configured absent "$REPO"
  export ECI_TEST_REPLAY_TRACE_FILE="$replay_trace"
  output="$(run_hook "./timeout 5 printf ordinary" worker configured absent "$REPO" "$actual_replay" true true "$inner")"
  unset ECI_TEST_REPLAY_TRACE_FILE
  [ ! -s "$output" ] || {
    printf 'explicit replay trace command was denied: %s\n' "$(cat -- "$output")" >&2
    return 1
  }
  explicit_replay="$(jq -cs '[.[] | select(.compound_segment_validation == true and (.command | startswith("./timeout 5")))]' "$replay_trace")"
  jq -e 'length == 2 and .[0].command == .[1].command and .[0].decision == .[1].decision and .[0].outer_cwd == .[1].outer_cwd and .[0].effective_cwd == .[1].effective_cwd and .[0].cwd_candidates == .[1].cwd_candidates and .[0].cwd_unknown == .[1].cwd_unknown and .[0].reachability == .[1].reachability and .[0].command_path == .[1].command_path and .[0].timeout_replays == .[1].timeout_replays and .[0].timeout_replays[0].cwd == .[1].timeout_replays[0].cwd and .[0].timeout_replays[0].prefix == .[1].timeout_replays[0].prefix and .[0].timeout_replays[0].command_path == .[1].timeout_replays[0].command_path and .[0].timeout_replays[0].command_path_set == true and .[0].timeout_replays[0].command_path_exported == true and .[1].timeout_replays[0].command_path_set == true and .[1].timeout_replays[0].command_path_exported == true and .[0].timeout_replays[0].disposition == .[1].timeout_replays[0].disposition' <<<"$explicit_replay" >/dev/null || {
    printf 'actual FD9 replay did not match explicit replay: %s\n' "$explicit_replay" >&2
    return 1
  }

  # A valid shape with a mismatched FD9 token is not an authenticated handoff;
  # the callback CWD remains authoritative and the hardlink reaches the
  # current marker's direct-control denial.
  output="$(run_hook "./timeout 5 rm eci_active" worker configured absent "$REPO" "$replay" true true "$inner" none wrong-token)"
  jq -e '.hookSpecificOutput.permissionDecision == "deny"' "$output" >/dev/null || {
    printf 'mismatched compound handoff was accepted: %s\n' "$(cat -- "$output")" >&2
    return 1
  }
  unlink "$REPO/eci_active"
}

assert_allowed() {
  local command="$1" role="${2:-coordinator}" path_mode="${3:-configured}" probe_required="${4:-absent}" callback_cwd="${5:-$REPO}" timeout_replays="${6:-[]}" compound_replay="${7:-false}" fd9_mode="${8:-none}" fd9_token="${9:-normal-git-test-handoff}" output
  output="$(run_hook "$command" "$role" "$path_mode" "$probe_required" "$callback_cwd" "$timeout_replays" "$compound_replay" true "$callback_cwd" "$fd9_mode" "$fd9_token")"
  if [ -s "$output" ]; then
    printf 'ordinary Git command was denied: %q\n' "$command" >&2
    cat -- "$output" >&2
    return 1
  fi
}

assert_denied_code() {
  local command="$1" code="$2" role="${3:-coordinator}" detail="${4:-}" path_mode="${5:-configured}" probe_required="${6:-absent}" callback_cwd="${7:-$REPO}" timeout_replays="${8:-[]}" compound_replay="${9:-false}" compound_handoff="${10:-true}" output
  local compound_cwd="${11:-$callback_cwd}"
  output="$(run_hook "$command" "$role" "$path_mode" "$probe_required" "$callback_cwd" "$timeout_replays" "$compound_replay" "$compound_handoff" "$compound_cwd")"
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

foreign_timeout_observed_replays() {
  local timeout_token="$1" child_cwd="$2"

  jq -cn --arg timeout_token "$timeout_token" --arg cwd "$child_cwd" '
    [{segment:1,parent_segment:2,prefix:[$timeout_token,"5"],cwd:$cwd,command_path:"",command_path_set:false,command_path_exported:false,disposition:"observed"}]
  '
}

# Exercise each timeout-child meaning through both sources of evidence: a
# real launching child and the exact synthetic observed replay consumed during
# compound recursion.  Keep both coordinator and worker roles in the helper
# so a new semantic case cannot accidentally cover just one admission path.
assert_foreign_timeout_pair() {
  local expectation="$1" tail="$2" child_cwd="${3:-$FOREIGN_TIMEOUT_CONTROL_INNER}" foreign_session="${4:-$FOREIGN_SESSION}" timeout_token="${5:-./timeout}"
  local actual_command synthetic_command observed_replays role

  actual_command="cd $child_cwd; $timeout_token 5 $tail"
  synthetic_command="$timeout_token 5 $tail"
  observed_replays="$(foreign_timeout_observed_replays "$timeout_token" "$child_cwd")"
  for role in coordinator worker; do
    case "$expectation" in
      deny)
        assert_denied_code "$actual_command" ECI_CROSS_SESSION_ACTIVE_MARKER_DENIED "$role" \
          "foreign_session=$foreign_session"
        assert_denied_code "$synthetic_command" ECI_CROSS_SESSION_ACTIVE_MARKER_DENIED "$role" \
          "foreign_session=$foreign_session" configured absent "$REPO" "$observed_replays" true
        ;;
      allow)
        assert_allowed "$actual_command" "$role"
        assert_allowed "$synthetic_command" "$role" configured absent "$REPO" "$observed_replays" true
        ;;
      *)
        printf 'unknown foreign timeout expectation: %s\n' "$expectation" >&2
        return 64
        ;;
    esac
  done
}

# This bounded target exercises the copied real hook's timeout replay path
# without requiring the broad normal-Git matrix to finish. The default matrix
# below remains its established entrypoint and coverage surface.
run_foreign_timeout_marker_target() {
  local role current_timeout_inner outside_timeout_inner literal_timeout_dir literal_timeout_token missing_first_marker stale_foreign_cwd target_failures=0
  local observed_replays opaque_replays duplicate_replays malformed_replays prefix_mismatch_replays

  current_timeout_inner="$PROOF_ROOT/$SESSION"
  outside_timeout_inner="$TMP_ROOT/timeout-outside-proof"
  literal_timeout_dir="$TMP_ROOT/literal+timeout"
  literal_timeout_token="$literal_timeout_dir/timeout"
  missing_first_marker='../foreign-timeout-missing-first/eci_active'
  cp -- "$FAKE_TIMEOUT_LAUNCH_DIR/timeout" "$FOREIGN_TIMEOUT_CONTROL_INNER/timeout"
  cp -- "$FAKE_TIMEOUT_LAUNCH_DIR/timeout" "$current_timeout_inner/timeout"
  cp -- "$FAKE_TIMEOUT_LAUNCH_DIR/timeout" "$PROOF_ROOT/timeout"
  mkdir -p -- "$literal_timeout_dir"
  cp -- "$FAKE_TIMEOUT_LAUNCH_DIR/timeout" "$literal_timeout_token"
  mkdir -p -- "$outside_timeout_inner"
  cp -- "$FAKE_TIMEOUT_LAUNCH_DIR/timeout" "$outside_timeout_inner/timeout"
  printf '%s\n' ordinary >"$outside_timeout_inner/eci_active"
  chmod 755 -- "$FOREIGN_TIMEOUT_CONTROL_INNER/timeout" "$current_timeout_inner/timeout" "$PROOF_ROOT/timeout" "$literal_timeout_token" "$outside_timeout_inner/timeout"
  CALLBACK_PATH="$FAKE_TIMEOUT_ACCEPT_DIR:$BASE_CALLBACK_PATH"

  # A valid observed replay, rather than a narrow raw-source spelling, owns
  # child mode.  The literal '+' path is deliberately outside the old source
  # regex while remaining an executable timeout pathname.
  for tail in \
    'rm eci_active' \
    'env rm eci_active' \
    '/usr/bin/env rm eci_active' \
    'env -- rm eci_active' \
    'env - rm eci_active' \
    'env - - rm eci_active' \
    'env -- - rm eci_active' \
    'env FOREIGN_ASSIGNMENT=present - rm eci_active' \
    'env -v rm eci_active' \
    'env --debug rm eci_active' \
    'env -v - rm eci_active' \
    'env --debug - rm eci_active' \
    'env -v --debug rm eci_active' \
    'env --debug -v rm eci_active' \
    'env -i rm eci_active' \
    'env --ignore-environment rm eci_active' \
    'env -u NAME rm eci_active' \
    'env -uNAME rm eci_active' \
    'env --unset NAME rm eci_active' \
    'env --unset=NAME rm eci_active' \
    'env -C . rm eci_active' \
    'env -C. rm eci_active' \
    'env --chdir . rm eci_active' \
    'env --chdir=. rm eci_active' \
    "env -C /tmp rm $FOREIGN_TIMEOUT_CONTROL_INNER/eci_active" \
    'env FOREIGN_ASSIGNMENT=present rm eci_active' \
    'rm -v eci_active' \
    'rm --verbose eci_active' \
    'rm -- eci_active' \
    'rm --force eci_active' \
    'rm -r eci_active' \
    'rm -R eci_active' \
    'rm -rf eci_active' \
    'rm -fr eci_active' \
    'rm --recursive eci_active' \
    'cp -r ordinary-copy eci_active' \
    'cp -R ordinary-copy eci_active' \
    'cp -rf ordinary-copy eci_active' \
    'cp -fr ordinary-copy eci_active' \
    'cp -a ordinary-copy eci_active' \
    'cp --archive ordinary-copy eci_active' \
    'cp --recursive ordinary-copy eci_active' \
    'cp -- ordinary-copy eci_active' \
    'cp --force ordinary-copy eci_active' \
    'cp -v ordinary-copy eci_active' \
    'cp --verbose ordinary-copy eci_active' \
    'tee -- eci_active' \
    'tee --append eci_active' \
    'tee -i eci_active' \
    'tee --ignore-interrupts eci_active' \
    'tee -ai eci_active' \
    'tee -ia eci_active' \
    'tee -p eci_active' \
    'tee --append --ignore-interrupts eci_active' \
    'dd of=eci_active' \
    'dd -- of=eci_active' \
    'dd of=eci_active bs=1 count=1' \
    'dd if=/dev/zero of=eci_active' \
    'unlink eci_active' \
    'unlink -- eci_active' \
    "env -C /tmp printf '%s' marker > eci_active" \
    "printf '%s' marker < eci_active > eci_active"; do
    assert_foreign_timeout_pair deny "$tail" "$FOREIGN_TIMEOUT_CONTROL_INNER" "$FOREIGN_SESSION" "$literal_timeout_token"
  done

  # These literal launch forms have an established foreign-marker writer
  # effect.  Keep the matrix finite: core input FDs and the exact installed env
  # debug/split combinations below, not a general shell or env grammar.
  for tail in \
    'cp ordinary-copy < eci_active eci_active' \
    'cp ordinary-copy 0< eci_active eci_active' \
    'cp ordinary-copy 1< eci_active eci_active' \
    'cp ordinary-copy 2< eci_active eci_active' \
    'cp ordinary-copy 2<&0 eci_active' \
    'cp ordinary-copy 2<& 0 eci_active' \
    "cp '3'< eci_active eci_active" \
    'cp 3 < eci_active eci_active' \
    'env -vv rm eci_active' \
    'env -vvv rm eci_active' \
    'env -vS rm eci_active' \
    'env -vSrm eci_active' \
    'env -vvSrm eci_active' \
    'env --debug -vSrm eci_active'; do
    assert_foreign_timeout_pair deny "$tail" "$FOREIGN_TIMEOUT_CONTROL_INNER" "$FOREIGN_SESSION" "$literal_timeout_token"
  done

  # The timeout child is argv, not a second shell.  Unknown/malformed env
  # grammar remains ordinary, while a recognized `-u NAME` retains rm as the
  # direct child.  These use the same literal timeout path and replay shape.
  for tail in \
    'builtin rm eci_active' \
    'command rm eci_active' \
    'command -v rm eci_active' \
    'exec rm eci_active' \
    'FOREIGN_ASSIGNMENT=present rm eci_active' \
    '"FOREIGN_ASSIGNMENT=present" rm eci_active' \
    'env -u rm eci_active' \
    'env -u' \
    'env --unset' \
    'env -C /tmp rm eci_active' \
    "env -C $TMP_ROOT/nonexistent-env-chdir rm eci_active" \
    'env -C . -C . rm eci_active' \
    'env --chdir . --chdir . rm eci_active' \
    'env --unknown rm eci_active' \
    'env FOREIGN_ASSIGNMENT=$TARGET rm eci_active' \
    'env FOREIGN_ASSIGNMENT=present' \
    './env rm eci_active' \
    'rm --unknown eci_active' \
    'cp --unknown ordinary-copy eci_active' \
    'tee --unknown eci_active' \
    'dd --unknown of=eci_active' \
    'unlink eci_active ordinary' \
    'srm eci_active' \
    'dd if=eci_active' \
    'cat < eci_active'; do
    assert_foreign_timeout_pair allow "$tail" "$FOREIGN_TIMEOUT_CONTROL_INNER" "$FOREIGN_SESSION" "$literal_timeout_token"
  done

  # Boundaries around the demonstrated spellings stay ordinary. In particular,
  # do not turn quoted/escaped/non-core FD words, mixed env clusters, or
  # equals split syntax into a broad parser-owned denial surface.
  for tail in \
    'cat 2< eci_active' \
    'cp ordinary-copy 3< eci_active eci_active' \
    'cp 3< eci_active eci_active' \
    'mv eci_active 3</dev/null' \
    'cp \3< eci_active eci_active' \
    "cp ordinary-copy '2'< eci_active eci_active" \
    'cp ordinary-copy \2< eci_active eci_active' \
    'cp ordinary-copy 2 < eci_active eci_active' \
    'cp ordinary-copy 2<&1 eci_active' \
    'cp ordinary-copy 2<& 1 eci_active' \
    'env -iv rm eci_active' \
    'env -vi rm eci_active' \
    'env - -v rm eci_active' \
    'env FOREIGN_ASSIGNMENT=present -v rm eci_active' \
    'env -S rm eci_active' \
    'env --split-string rm eci_active' \
    'env -Srm eci_active' \
    'env -vS "rm eci_active"' \
    'env --split-string=rm eci_active' \
    "env -S 'rm eci_active'" \
    'env -- -v eci_active' \
    'env -- --debug eci_active' \
    'env -- -u eci_active' \
    'env -- -C eci_active'; do
    assert_foreign_timeout_pair allow "$tail" "$FOREIGN_TIMEOUT_CONTROL_INNER" "$FOREIGN_SESSION" "$literal_timeout_token"
  done

  # Every direct finite writer position must agree between a real observed
  # timeout child and its synthetic replay.  Inputs, modes, and ordinary
  # command spellings are deliberately kept in the allow cases below.
  for tail in \
    'rm -f eci_active' \
    'rm eci_active' \
    'shred eci_active' \
    'touch eci_active' \
    'touch -d 2026-01-01T00:00:00Z eci_active' \
    'touch --date=2026-01-01T00:00:00Z eci_active' \
    "sed -i.bak 's/old/new/' eci_active" \
    "sed --in-place=.bak 's/old/new/' eci_active" \
    "sed -e's/old/new/' -i ordinary-copy eci_active" \
    'sed -f ordinary-copy -i eci_active' \
    'unlink eci_active' \
    'chmod 600 eci_active' \
    'chown root eci_active' \
    'tee eci_active' \
    'dd if=/dev/zero of=eci_active' \
    'truncate -s 0 eci_active' \
    'truncate --size=0 eci_active' \
    'cp ordinary-copy eci_active' \
    'install ordinary-copy eci_active' \
    'mv eci_active ordinary-copy' \
    'mv ordinary-copy eci_active' \
    'ln -f ordinary-copy eci_active' \
    'rm --force eci_active' \
    'cp -f ordinary-copy eci_active' \
    'cp --force ordinary-copy eci_active' \
    'tee -a eci_active' \
    'tee --append eci_active' \
    'ln --force ordinary-copy eci_active' \
    'rm -- eci_active' \
    'rm eci_active -- ordinary-copy' \
    'cp -- ordinary-copy eci_active' \
    'tee -- eci_active' \
    'ln -f -- ordinary-copy eci_active' \
    "printf '%s' marker > eci_active" \
    "printf '%s' marker >> eci_active" \
    "printf '%s' marker >| eci_active" \
    "printf '%s' marker >& eci_active" \
    "printf '%s' marker &> eci_active" \
    "printf '%s' marker &>> eci_active" \
    'rm "eci_active"' \
    'env rm eci_active'; do
    assert_foreign_timeout_pair deny "$tail"
  done

  # `--` makes the leading dash an operand instead of an option.  Session
  # identity validation is shared with proof state, so both valid spellings
  # must resolve without a local first-character rule.
  assert_foreign_timeout_pair deny "rm -- $FOREIGN_UNDERSCORE_SESSION/eci_active" "$PROOF_ROOT" "$FOREIGN_UNDERSCORE_SESSION"
  assert_foreign_timeout_pair deny "rm -- $FOREIGN_DASH_SESSION/eci_active" "$PROOF_ROOT" "$FOREIGN_DASH_SESSION"

  # Read/source operands, quoted or escaped operator punctuation, dynamic
  # operands, unsupported nesting, and unknown writer/wrapper grammar are
  # ordinary execution.  A quoted literal pathname remains a concrete target
  # above; only the syntax characters themselves are data here.
  for tail in \
    'cat eci_active' \
    "printf '%s' eci_active" \
    'cp eci_active ordinary-copy' \
    'cp -a eci_active ordinary-copy' \
    'sed -f eci_active -i ordinary-copy' \
    "sed -e's/old/new/' -i ordinary-copy" \
    'truncate -s eci_active ordinary-copy' \
    "sed -i.bak 's/old/new/' ordinary-copy" \
    'rmdir eci_active' \
    'chmod eci_active ordinary-copy' \
    'ln eci_active ordinary-link' \
    "printf '%s' marker '>' eci_active" \
    "printf '%s' marker \\> eci_active" \
    "printf '%s' marker '&>' eci_active" \
    "printf '%s' marker \\&\\> eci_active" \
    'rm "$TARGET"' \
    'rm $(printf eci_active)' \
    "bash -c 'rm eci_active'" \
    'ln -s ordinary-copy eci_active' \
    'unknown-wrapper rm eci_active'; do
    assert_foreign_timeout_pair allow "$tail"
  done

  # An actual observed timeout child may not mutate a valid foreign marker.
  for role in coordinator worker; do
    assert_denied_code "cd $FOREIGN_TIMEOUT_CONTROL_INNER; ./timeout 5 rm eci_active" ECI_CROSS_SESSION_ACTIVE_MARKER_DENIED "$role" \
      "foreign_session=$FOREIGN_SESSION"
  done

  # A marker pathname used as command input is not a foreign-marker mutation.
  # Keep both a pure reader and a writer with that marker only as its source.
  # A redirect to the marker itself remains the concrete effect to deny.
  for role in coordinator worker; do
    assert_allowed "cd $FOREIGN_TIMEOUT_CONTROL_INNER; ./timeout 5 cat eci_active" "$role"
    assert_allowed "cd $FOREIGN_TIMEOUT_CONTROL_INNER; ./timeout 5 printf '%s' eci_active" "$role"
    assert_allowed "cd $FOREIGN_TIMEOUT_CONTROL_INNER; ./timeout 5 cp eci_active ordinary-copy" "$role"
    assert_denied_code "cd $FOREIGN_TIMEOUT_CONTROL_INNER; ./timeout 5 printf '%s' marker > eci_active" ECI_CROSS_SESSION_ACTIVE_MARKER_DENIED "$role" \
      "foreign_session=$FOREIGN_SESSION"
  done

  # Command positions matter: input, mode, and impossible-directory operands
  # stay ordinary; direct destinations and forced replacement targets do not.
  for role in coordinator worker; do
    assert_allowed "cd $FOREIGN_TIMEOUT_CONTROL_INNER; ./timeout 5 rmdir eci_active" "$role"
    assert_allowed "cd $FOREIGN_TIMEOUT_CONTROL_INNER; ./timeout 5 chmod eci_active ordinary-copy" "$role"
    assert_allowed "cd $FOREIGN_TIMEOUT_CONTROL_INNER; ./timeout 5 ln eci_active ordinary-link" "$role"
    assert_denied_code "cd $FOREIGN_TIMEOUT_CONTROL_INNER; ./timeout 5 dd if=/dev/zero of=eci_active" ECI_CROSS_SESSION_ACTIVE_MARKER_DENIED "$role" \
      "foreign_session=$FOREIGN_SESSION"
    assert_denied_code "cd $FOREIGN_TIMEOUT_CONTROL_INNER; ./timeout 5 cp ordinary-copy eci_active" ECI_CROSS_SESSION_ACTIVE_MARKER_DENIED "$role" \
      "foreign_session=$FOREIGN_SESSION"
    assert_denied_code "cd $FOREIGN_TIMEOUT_CONTROL_INNER; ./timeout 5 install ordinary-copy eci_active" ECI_CROSS_SESSION_ACTIVE_MARKER_DENIED "$role" \
      "foreign_session=$FOREIGN_SESSION"
    assert_denied_code "cd $FOREIGN_TIMEOUT_CONTROL_INNER; ./timeout 5 mv eci_active ordinary-copy" ECI_CROSS_SESSION_ACTIVE_MARKER_DENIED "$role" \
      "foreign_session=$FOREIGN_SESSION"
    assert_denied_code "cd $FOREIGN_TIMEOUT_CONTROL_INNER; ./timeout 5 mv ordinary-copy eci_active" ECI_CROSS_SESSION_ACTIVE_MARKER_DENIED "$role" \
      "foreign_session=$FOREIGN_SESSION"
    assert_denied_code "cd $FOREIGN_TIMEOUT_CONTROL_INNER; ./timeout 5 ln -f ordinary-copy eci_active" ECI_CROSS_SESSION_ACTIVE_MARKER_DENIED "$role" \
      "foreign_session=$FOREIGN_SESSION"
    assert_denied_code "cd $FOREIGN_TIMEOUT_CONTROL_INNER; ./timeout 5 chmod 600 eci_active" ECI_CROSS_SESSION_ACTIVE_MARKER_DENIED "$role" \
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
    # The observed replay carries the child CWD, but input paths must still
    # remain ordinary while a redirect to the live marker is denied.
    assert_allowed "./timeout 5 cat eci_active" "$role" configured absent "$REPO" "$observed_replays" true
    assert_allowed "./timeout 5 printf '%s' eci_active" "$role" configured absent "$REPO" "$observed_replays" true
    assert_allowed "./timeout 5 cp eci_active ordinary-copy" "$role" configured absent "$REPO" "$observed_replays" true
    assert_denied_code "./timeout 5 printf '%s' marker > eci_active" ECI_CROSS_SESSION_ACTIVE_MARKER_DENIED "$role" \
      "foreign_session=$FOREIGN_SESSION" configured absent "$REPO" "$observed_replays" true
    assert_allowed "./timeout 5 rmdir eci_active" "$role" configured absent "$REPO" "$observed_replays" true
    assert_allowed "./timeout 5 chmod eci_active ordinary-copy" "$role" configured absent "$REPO" "$observed_replays" true
    assert_allowed "./timeout 5 ln eci_active ordinary-link" "$role" configured absent "$REPO" "$observed_replays" true
    assert_denied_code "./timeout 5 dd if=/dev/zero of=eci_active" ECI_CROSS_SESSION_ACTIVE_MARKER_DENIED "$role" \
      "foreign_session=$FOREIGN_SESSION" configured absent "$REPO" "$observed_replays" true
    assert_denied_code "./timeout 5 cp ordinary-copy eci_active" ECI_CROSS_SESSION_ACTIVE_MARKER_DENIED "$role" \
      "foreign_session=$FOREIGN_SESSION" configured absent "$REPO" "$observed_replays" true
    assert_denied_code "./timeout 5 install ordinary-copy eci_active" ECI_CROSS_SESSION_ACTIVE_MARKER_DENIED "$role" \
      "foreign_session=$FOREIGN_SESSION" configured absent "$REPO" "$observed_replays" true
    assert_denied_code "./timeout 5 mv eci_active ordinary-copy" ECI_CROSS_SESSION_ACTIVE_MARKER_DENIED "$role" \
      "foreign_session=$FOREIGN_SESSION" configured absent "$REPO" "$observed_replays" true
    assert_denied_code "./timeout 5 mv ordinary-copy eci_active" ECI_CROSS_SESSION_ACTIVE_MARKER_DENIED "$role" \
      "foreign_session=$FOREIGN_SESSION" configured absent "$REPO" "$observed_replays" true
    assert_denied_code "./timeout 5 ln -f ordinary-copy eci_active" ECI_CROSS_SESSION_ACTIVE_MARKER_DENIED "$role" \
      "foreign_session=$FOREIGN_SESSION" configured absent "$REPO" "$observed_replays" true
    assert_denied_code "./timeout 5 chmod 600 eci_active" ECI_CROSS_SESSION_ACTIVE_MARKER_DENIED "$role" \
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

run_effect_aware_git_target() {
  local command failures=0 before_head before_branch protected_base protected_changed
  # Protection binds to the configured runtime, so make that complete copied
  # runtime the actual repository instead of using a lookalike sibling path.
  REPO="$(realpath -e -- "$RUNTIME_ROOT")"
  git -C "$REPO" init -q
  git -C "$REPO" config user.email normal-git-test@example.invalid
  git -C "$REPO" config user.name 'Normal Git Test'
  printf 'base\n' >"$REPO/file.txt"
  printf 'ordinary base\n' >"$REPO/CODEX.md"
  printf '%s\n' 'scope: effect-aware Git regression' "cwd: $REPO" \
    "session_id: $SESSION" 'created_utc: 2026-08-28T00:00:00Z' >"$PROOF_ROOT/$SESSION/eci_active"
  git -C "$REPO" add -- hooks/validate-bash.sh hooks.json CODEX.md file.txt
  git -C "$REPO" commit -qm 'effect fixture'
  protected_base="$(git -C "$REPO" hash-object hooks/validate-bash.sh)"
  git -C "$REPO" branch hooks/validate-bash.sh
  git -C "$REPO" branch existing-other-branch
  git -C "$REPO" update-ref refs/remotes/origin/file.txt HEAD
  git -C "$REPO" update-ref refs/remotes/origin/remote-topic HEAD
  git -C "$REPO" config remote.origin.url "$FOREIGN_REPO"
  git -C "$REPO" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
  before_head="$(git -C "$REPO" rev-parse HEAD)"
  before_branch="$(git -C "$REPO" symbolic-ref HEAD)"
  assert_denied_code 'git restore -- hooks/validate-bash.sh' ECI_WORKER_GIT_OWNERSHIP_DENIED worker || return 1

  # A verified checkout tree source is not an explicit destination and must
  # not prevent loading file-selected destinations. Protected forms are
  # checked only; admitted ordinary forms execute through real Git.
  printf '%s\n' hooks/validate-bash.sh >"$TMP_ROOT/protected-checkout.paths"
  printf '%s\n' CODEX.md >"$TMP_ROOT/ordinary-checkout.paths"
  for command in \
    "git checkout HEAD --pathspec-from-file=$TMP_ROOT/protected-checkout.paths" \
    "git checkout 'HEAD^{tree}' --pathspec-from-file=$TMP_ROOT/protected-checkout.paths" \
    "git checkout HEAD --pathspec-from-file $TMP_ROOT/protected-checkout.paths" \
    "git checkout --pathspec-from-file=$TMP_ROOT/protected-checkout.paths HEAD" \
    "git checkout --pathspec-from-file=$TMP_ROOT/protected-checkout.paths" \
    'git checkout --orphan=-scratch --no-orphan -- hooks/validate-bash.sh'; do
    assert_denied_code "$command" ECI_WORKER_GIT_OWNERSHIP_DENIED worker || failures=1
  done
  for command in \
    "git checkout HEAD --pathspec-from-file=$TMP_ROOT/ordinary-checkout.paths" \
    "git checkout HEAD --pathspec-from-file $TMP_ROOT/ordinary-checkout.paths" \
    "git checkout 'HEAD^{tree}' --pathspec-from-file=$TMP_ROOT/ordinary-checkout.paths" \
    "git checkout --pathspec-from-file=$TMP_ROOT/ordinary-checkout.paths" \
    'git checkout --orphan=-scratch --no-orphan -- CODEX.md'; do
    printf 'ordinary changed\n' >"$REPO/CODEX.md"
    if assert_allowed "$command" worker; then
      (cd -- "$REPO"; bash -c "$command") || failures=1
      [ "$(cat -- "$REPO/CODEX.md")" = 'ordinary base' ] || failures=1
      [ "$(git -C "$REPO" hash-object hooks/validate-bash.sh)" = "$protected_base" ] || failures=1
      [ "$(git -C "$REPO" symbolic-ref HEAD)" = "$before_branch" ] || failures=1
      [ "$(git -C "$REPO" rev-parse HEAD)" = "$before_head" ] || failures=1
      git -C "$REPO" diff --cached --quiet || failures=1
    else failures=1; fi
  done
  command="git checkout HEAD CODEX.md --pathspec-from-file=$TMP_ROOT/protected-checkout.paths"
  if assert_allowed "$command" worker; then
    if (cd -- "$REPO"; bash -c "$command") >"$TMP_ROOT/explicit-file-conflict.out" 2>&1; then
      printf 'checkout with explicit and file destinations unexpectedly succeeded\n' >&2
      failures=1
    fi
    [ "$(git -C "$REPO" hash-object hooks/validate-bash.sh)" = "$protected_base" ] || failures=1
    [ "$(git -C "$REPO" symbolic-ref HEAD)" = "$before_branch" ] || failures=1
    [ "$(git -C "$REPO" rev-parse HEAD)" = "$before_head" ] || failures=1
    git -C "$REPO" diff --quiet && git -C "$REPO" diff --cached --quiet || failures=1
  else failures=1; fi

  # Git's negative prepass uses reverse candidates. Standard wildcard
  # mappings still permit guessing even with a matching source negative.
  git -C "$REPO" config --add remote.origin.fetch '^refs/heads/wip/*'
  assert_denied_code 'git checkout --guess remote-topic' ECI_WORKER_GIT_OWNERSHIP_DENIED worker || failures=1
  assert_denied_code 'git -c checkout.guess=true checkout remote-topic' ECI_WORKER_GIT_OWNERSHIP_DENIED worker || failures=1
  git -C "$REPO" config --add remote.origin.fetch '^refs/heads/remote-topic'
  assert_denied_code 'git checkout --guess remote-topic' ECI_WORKER_GIT_OWNERSHIP_DENIED worker || failures=1
  # An exact positive contributes its source to the negative prepass, so
  # the matching negative prevents native guessing without changing state.
  git -C "$REPO" config --replace-all remote.origin.fetch 'refs/heads/remote-topic:refs/remotes/origin/remote-topic'
  git -C "$REPO" config --add remote.origin.fetch '^refs/heads/remote-topic'
  command='git checkout --guess remote-topic'
  if assert_allowed "$command" worker; then
    if (cd -- "$REPO"; bash -c "$command") >"$TMP_ROOT/excluded-remote.out" 2>&1; then
      printf 'checkout guessed an excluded remote branch\n' >&2
      failures=1
    fi
    [ "$(git -C "$REPO" symbolic-ref HEAD)" = "$before_branch" ] || failures=1
    [ "$(git -C "$REPO" rev-parse HEAD)" = "$before_head" ] || failures=1
    [ "$(git -C "$REPO" hash-object hooks/validate-bash.sh)" = "$protected_base" ] || failures=1
    git -C "$REPO" diff --quiet && git -C "$REPO" diff --cached --quiet || failures=1
  else failures=1; fi
  git -C "$REPO" config --replace-all remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'

  # These operations are checked for denial only, never executed.
  for command in \
    'git restore --recurse-submodules hooks/validate-bash.sh' \
    'git restore --staged --work -- hooks/validate-bash.sh' \
    'git restore --no-worktree --worktree -- hooks/validate-bash.sh' \
    'git checkout --orp topic HEAD' \
    'git checkout --no-orphan --orphan topic HEAD' \
    'git checkout HEAD hooks/validate-bash.sh' \
    'git checkout existing-other-branch --' \
    'git checkout --guess remote-topic' \
    'git checkout --no-guess --guess remote-topic' \
    'git -c checkout.guess=true checkout remote-topic' \
    'git reset -- file.txt' \
    'git commit --amend --no-edit' \
    'git branch --delete existing-other-branch'; do
    assert_denied_code "$command" ECI_WORKER_GIT_OWNERSHIP_DENIED worker || failures=1
  done

  # Disabling the default worktree effect leaves a Git-invalid restore, not
  # a protected overwrite. The actual error must preserve every tracked state.
  command='git restore --no-worktree -- hooks/validate-bash.sh'
  if assert_allowed "$command" worker; then
    if (cd -- "$REPO"; bash -c "$command") >"$TMP_ROOT/no-worktree.out" 2>&1; then
      printf 'restore with no destination unexpectedly succeeded\n' >&2
      failures=1
    fi
    rg -Fq "neither '--staged' or '--worktree' is specified" "$TMP_ROOT/no-worktree.out" || failures=1
    [ "$(git -C "$REPO" hash-object hooks/validate-bash.sh)" = "$protected_base" ] || failures=1
    [ "$(git -C "$REPO" rev-parse :hooks/validate-bash.sh)" = "$protected_base" ] || failures=1
    [ "$(git -C "$REPO" rev-parse HEAD)" = "$before_head" ] || failures=1
    git -C "$REPO" diff --cached --quiet || failures=1
  else failures=1; fi

  # A tracked path sharing a branch name is ambiguous without an explicit
  # separator. Admit Git's own error and prove it has no branch/worktree effect.
  for command in \
    'git checkout hooks/validate-bash.sh CODEX.md' \
    'git checkout --guess file.txt' \
    'git checkout --no-guess --guess file.txt' \
    'git -c checkout.guess=true checkout file.txt'; do
    if assert_allowed "$command" worker; then
      if (cd -- "$REPO"; bash -c "$command") >"$TMP_ROOT/ambiguous-checkout.out" 2>&1; then
        printf 'ambiguous checkout unexpectedly succeeded: %s\n' "$command" >&2
        failures=1
      fi
      if [ "$command" = 'git checkout hooks/validate-bash.sh CODEX.md' ]; then
        rg -q 'both revision and filename' "$TMP_ROOT/ambiguous-checkout.out" || failures=1
      else
        rg -q 'could be both a local file and a tracking branch' "$TMP_ROOT/ambiguous-checkout.out" || failures=1
      fi
      [ "$(git -C "$REPO" symbolic-ref HEAD)" = "$before_branch" ] || failures=1
      [ "$(git -C "$REPO" rev-parse HEAD)" = "$before_head" ] || failures=1
      [ "$(cat -- "$REPO/file.txt")" = base ] || failures=1
      [ "$(git -C "$REPO" hash-object hooks/validate-bash.sh)" = "$protected_base" ] || failures=1
      git -C "$REPO" diff --quiet && git -C "$REPO" diff --cached --quiet || failures=1
    else failures=1; fi
  done

  # A protected-looking source revision is an input. Execute admitted forms
  # and prove the ordinary destination is restored without touching the hook.
  for command in \
    'git restore -s hooks/validate-bash.sh -- CODEX.md' \
    'git restore -qs hooks/validate-bash.sh -- CODEX.md' \
    'git restore -Wqs hooks/validate-bash.sh -- CODEX.md' \
    'git restore -qshooks/validate-bash.sh -- CODEX.md' \
    'git checkout hooks/validate-bash.sh -- CODEX.md' \
    'git checkout --orphan topic --no-orphan -- CODEX.md'; do
    printf 'ordinary changed\n' >"$REPO/CODEX.md"
    if assert_allowed "$command" worker; then
      (cd -- "$REPO"; bash -c "$command") || failures=1
      [ "$(cat -- "$REPO/CODEX.md")" = 'ordinary base' ] || failures=1
      [ "$(git -C "$REPO" hash-object hooks/validate-bash.sh)" = "$protected_base" ] || failures=1
      [ "$(git -C "$REPO" symbolic-ref HEAD)" = "$before_branch" ] || failures=1
      [ "$(git -C "$REPO" rev-parse HEAD)" = "$before_head" ] || failures=1
    else
      failures=1
    fi
  done

  git -C "$REPO" config checkout.guess false
  assert_denied_code 'git checkout --guess remote-topic' ECI_WORKER_GIT_OWNERSHIP_DENIED worker || failures=1
  for command in \
    'git checkout file.txt' \
    'git checkout --no-guess file.txt' \
    'git checkout --guess --no-guess file.txt' \
    'git -c checkout.guess=false checkout file.txt' \
    'git -c checkout.guess=true checkout --no-guess file.txt'; do
    printf 'changed\n' >"$REPO/file.txt"
    if assert_allowed "$command" worker; then
      (cd -- "$REPO"; bash -c "$command") || failures=1
      [ "$(cat -- "$REPO/file.txt")" = base ] || failures=1
      [ "$(git -C "$REPO" symbolic-ref HEAD)" = "$before_branch" ] || failures=1
    else
      failures=1
    fi
  done
  [ "$(git -C "$REPO" rev-parse HEAD)" = "$before_head" ] || failures=1

  # Normal owned staging, index-only restore, and checkpoint commit remain
  # executable. Index-only restore must preserve the edited protected file.
  printf '\n# Owned fixture checkpoint\n' >>"$REPO/hooks/validate-bash.sh"
  protected_changed="$(git -C "$REPO" hash-object hooks/validate-bash.sh)"
  if assert_allowed 'git add -- hooks/validate-bash.sh' worker; then
    git -C "$REPO" add -- hooks/validate-bash.sh
    [ "$(git -C "$REPO" rev-parse :hooks/validate-bash.sh)" = "$protected_changed" ] || failures=1
  else failures=1; fi
  if assert_allowed 'git restore --staged -- hooks/validate-bash.sh' worker; then
    git -C "$REPO" restore --staged -- hooks/validate-bash.sh
    [ "$(git -C "$REPO" rev-parse :hooks/validate-bash.sh)" = "$protected_base" ] || failures=1
    [ "$(git -C "$REPO" hash-object hooks/validate-bash.sh)" = "$protected_changed" ] || failures=1
  else failures=1; fi
  if assert_allowed 'git add -- hooks/validate-bash.sh' worker &&
     assert_allowed "git commit -qm 'owned checkpoint'" worker; then
    git -C "$REPO" add -- hooks/validate-bash.sh
    git -C "$REPO" commit -qm 'owned checkpoint'
    [ "$(git -C "$REPO" rev-parse HEAD:hooks/validate-bash.sh)" = "$protected_changed" ] || failures=1
    git -C "$REPO" diff --quiet && git -C "$REPO" diff --cached --quiet || failures=1
  else failures=1; fi
  [ "$failures" -eq 0 ]
}

case "${NORMAL_GIT_ADMISSION_TARGET:-full}" in
  full) ;;
  effect-aware-git)
    run_effect_aware_git_target
    printf '%s\n' 'normal Git admission effect-aware-git target: PASS'
    exit 0
    ;;
  compound-handoff-boundary)
    run_compound_handoff_boundary_target
    printf '%s\n' 'normal Git admission compound-handoff-boundary target: PASS'
    exit 0
    ;;
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

# Producers' normal commits need no approval artifact or review receipt.
assert_allowed "git commit -qm --all" worker

# Command spelling, `-C`, environment setup, and punctuation are not an
# accidental mistake by themselves.  The target remains this active repo.
assert_denied_code "git -C $REPO commit -am 'ordinary commit'" ECI_BROAD_DESTRUCTIVE_DENIED worker
assert_allowed "env GIT_EDITOR=true /usr/bin/git -C $REPO commit --allow-empty -m 'ordinary commit'" worker
assert_denied_code "printf prepare && git -C $REPO commit -m 'ordinary commit' -- file.txt" ECI_GIT_COMMIT_STAGING_DENIED worker
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

# Worker Git inspection follows the resolved repository/effect. Harmless
# launchers, Git options, and a current-repository -C spelling remain ordinary;
# only a concrete foreign target or file output is denied.
run_worker_git_inspection() {
  local command="$1"
  assert_allowed "$command" worker
}
for worker_git_read in \
  "git status --short" \
  "git --no-pager status --short" \
  "git -c color.ui=false status --short" \
  "git --git-dir=.git status --short" \
  "git -C $REPO status --short" \
  "env -- git -C $REPO status --short" \
  "command git -C $REPO status --short" \
  "git -C $REPO log -1 --oneline" \
  "git -C $REPO diff --stat" \
  "git -C $REPO rev-parse --show-toplevel" \
  "git branch --list 'main*'" \
  "git branch --contains HEAD" \
  "systemd-run --working-directory=. --setenv=GIT_DIR=.git --setenv=GIT_WORK_TREE=. git status --short" \
  "systemd-run --working-directory $REPO --setenv GIT_DIR=.git --setenv GIT_WORK_TREE=. git log -1 --oneline"; do
  run_worker_git_inspection "$worker_git_read"
done
assert_denied_code "git -C $FOREIGN_REPO status --short" ECI_GIT_CROSS_SCOPE_DENIED worker \
  "active_repo=$REPO target_repo=$FOREIGN_REPO"
assert_denied_code "systemd-run --working-directory=$FOREIGN_REPO git status --short" ECI_GIT_CROSS_SCOPE_DENIED worker \
  "active_repo=$REPO target_repo=$FOREIGN_REPO"
assert_denied_code "systemd-run --working-directory=$REPO --setenv=GIT_WORK_TREE=$FOREIGN_REPO git status --short" ECI_GIT_CROSS_SCOPE_DENIED worker \
  "active_repo=$REPO target_repo=$FOREIGN_REPO"
assert_denied_code "git -C $REPO diff --output=$TMP_ROOT/git-inspection.out" ECI_GIT_OUTPUT_WRITE_DENIED worker \
  "operation=output"

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
assert_denied_code "timeout --signal TERM 5 git rebase topic" ECI_WORKER_GIT_OWNERSHIP_DENIED worker \
  "token=rebase"

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
# Literal branch reachability is carried into the recursive segment route:
# a live inline writer remains denied, while the dead split-body writer is
# retained structurally but skipped by both planner and adapter replay.
assert_denied_code "if true; then; rm $TIMEOUT_CONTROL_MARKER; fi" ECI_PLAN_LIVE_CONTROL_DENIED worker \
  "worker-proof-control"
assert_allowed "if false; then; rm $TIMEOUT_CONTROL_MARKER; fi" worker configured absent "$REPO"
# Spoofed inherited replay/CWD variables must not replace the planner-owned
# ordinary-inner fact or redirect the child back to the callback repository.
ECI_COMPOUND_SEGMENT_VALIDATION=true ECI_COMPOUND_CWD="$REPO" \
ECI_COMPOUND_COMMAND_PATH="$REPO" \
  assert_allowed "cd $TIMEOUT_ORDINARY_INNER; ./timeout 5 rm eci_active" worker configured absent "$REPO"
# Top-level JSON metadata is callback input, not planner provenance. Even a
# shape-valid forged segment fact must not move direct ownership resolution to
# the ordinary inner directory without the parent-only handoff channel.
assert_denied_code "rm eci_active" ECI_PLAN_LIVE_CONTROL_DENIED worker \
  "path=$TIMEOUT_CONTROL_INNER/eci_active" configured absent "$REPO" "[]" true false "$TIMEOUT_ORDINARY_INNER"
rm -- "$OUTER_CONTROL_ALIAS"

# An unsupported cd form leaves the segment CWD unknown. Harmless paths remain
# ordinary, while the unresolved control basename takes the targeted worker
# ownership route instead of borrowing the callback CWD.
assert_denied_code "cd -P $TIMEOUT_ORDINARY_INNER; ./timeout 5 rm eci_active" ECI_CONTROL_OWNER_REQUIRED worker \
  "resolved=<unknown-cwd>"
# Conditional, background, and harmless unknown-CWD segments remain ordinary;
# they cannot inherit a stale callback directory for control resolution.
assert_allowed "cd $TIMEOUT_ORDINARY_INNER || printf ordinary" worker configured absent "$REPO"
assert_allowed "false && cd $TIMEOUT_ORDINARY_INNER; printf ordinary" worker configured absent "$REPO"
assert_allowed "printf ordinary & printf still-ordinary" worker configured absent "$REPO"
assert_allowed "cd -P $TIMEOUT_ORDINARY_INNER; printf ordinary" worker configured absent "$REPO"

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

# Recursive validation must not source an inherited BASH_ENV. The poison file
# records each shell that sources it and exports the historical compound flag;
# the parent callback contributes one record, while the child must contribute
# none because the recursive adapter removes BASH_ENV and ECI_COMPOUND_*.
BASH_ENV_SENTINEL="$TMP_ROOT/compound-bash-env.sourced"
BASH_ENV_POISON="$TMP_ROOT/compound-bash-env.sh"
printf 'printf "%%s\\n" "\$BASHPID" >> %q\nexport ECI_COMPOUND_SEGMENT_VALIDATION=true\n' \
  "$BASH_ENV_SENTINEL" >"$BASH_ENV_POISON"
BASH_ENV="$BASH_ENV_POISON" assert_allowed 'printf ordinary; printf still-ordinary' coordinator configured absent "$REPO"
[ "$(wc -l <"$BASH_ENV_SENTINEL")" -eq 1 ] || {
  printf 'recursive validation sourced inherited BASH_ENV: %s\n' "$BASH_ENV_SENTINEL" >&2
  exit 1
}

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
assert_denied_code "timeout --signal TERM 5 git rebase topic" ECI_WORKER_GIT_OWNERSHIP_DENIED worker \
  "token=rebase" configured present
assert_allowed "timeout --signal TERM 5 git rebase topic" worker configured absent

# Shell PATH lookup retains callback-CWD empty and relative components. The
# test invokes the copied hook through /bin/bash so the raw callback PATH is
# not consumed by the harness before the hook captures it.
mkdir -p -- "$REPO/bin"
cp -- "$FAKE_TIMEOUT_LAUNCH_DIR/timeout" "$REPO/timeout"
cp -- "$FAKE_TIMEOUT_LAUNCH_DIR/timeout" "$REPO/bin/timeout"
chmod 755 -- "$REPO/timeout" "$REPO/bin/timeout"
for CALLBACK_PATH in "$TMP_ROOT/missing:bin" : . bin; do
  assert_denied_code "timeout --signal TERM 5 git rebase topic" ECI_WORKER_GIT_OWNERSHIP_DENIED worker \
    "token=rebase" raw
done

# Explicitly empty PATH differs from an empty component: bare timeout remains
# opaque when PATH is empty or unset, while a direct absolute or ./timeout
# spelling launches because the replacement child is an absolute executable.
assert_allowed "timeout --signal TERM 5 git rebase topic" worker empty
assert_allowed "timeout --signal TERM 5 git rebase topic" worker unset
assert_denied_code "$FAKE_TIMEOUT_LAUNCH_DIR/timeout --signal TERM 5 git rebase topic" ECI_WORKER_GIT_OWNERSHIP_DENIED worker \
  "token=rebase" empty
assert_denied_code "$FAKE_TIMEOUT_LAUNCH_DIR/timeout --signal TERM 5 git rebase topic" ECI_WORKER_GIT_OWNERSHIP_DENIED worker \
  "token=rebase" unset
assert_denied_code "./timeout --signal TERM 5 git rebase topic" ECI_WORKER_GIT_OWNERSHIP_DENIED worker \
  "token=rebase" empty
assert_denied_code "./timeout --signal TERM 5 git rebase topic" ECI_WORKER_GIT_OWNERSHIP_DENIED worker \
  "token=rebase" unset

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
assert_allowed "timeout --signal TERM 5 git rebase topic" worker
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

run_effect_aware_git_target
printf '%s\n' 'normal Git admission: PASS'
