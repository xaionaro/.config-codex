#!/usr/bin/env bash

set -euo pipefail

SOURCE_ROOT="$(cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TMP_ROOT="$(mktemp -d "${CODEX_TMPDIR:-${HOME:?}/tmp}/eci-current-ledger-append.XXXXXX")"
trap 'rm -rf -- "$TMP_ROOT"' EXIT HUP INT TERM

# The live hook has a user-installed temporary bypass at line 2. Exercise a
# complete copied runtime with only that local fixture bypass removed.
HOME_ROOT="$TMP_ROOT/home"
RUNTIME_ROOT="$HOME_ROOT/.codex"
PROOF_ROOT="$TMP_ROOT/proof"
REPOSITORY="$TMP_ROOT/repository"
FOREIGN_REPOSITORY="$TMP_ROOT/foreign-repository"
mkdir -p -- "$RUNTIME_ROOT" "$TMP_ROOT/config/eci" "$TMP_ROOT/state" "$PROOF_ROOT" "$REPOSITORY" "$FOREIGN_REPOSITORY"
git -C "$REPOSITORY" init -q
git -C "$FOREIGN_REPOSITORY" init -q
printf '%s\n' current-fixture >"$REPOSITORY/file.txt"
printf '%s\n' foreign-fixture >"$FOREIGN_REPOSITORY/file.txt"
cp -a -- "$SOURCE_ROOT/hooks" "$RUNTIME_ROOT"
mkdir -p -- "$RUNTIME_ROOT/bin"
cp -a -- "$SOURCE_ROOT/bin/eci-active" "$SOURCE_ROOT/bin/eci-command-gate-mode" "$RUNTIME_ROOT/bin/"
[ "$(sed -n '2p' -- "$RUNTIME_ROOT/hooks/validate-bash.sh")" = 'exit 0' ] || {
  printf '%s\n' 'expected the live validate-bash temporary bypass at line 2' >&2
  exit 1
}
sed -i '2d' -- "$RUNTIME_ROOT/hooks/validate-bash.sh"

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

run_lifecycle() {
  local session="$1"
  shift
  (
    cd -- "$REPOSITORY"
    HOME="$HOME_ROOT" CODEX_HOME="$RUNTIME_ROOT" CODEX_PROOF_ROOT="$PROOF_ROOT" \
      CODEX_SESSION_ID="$session" XDG_CONFIG_HOME="$TMP_ROOT/config" XDG_STATE_HOME="$TMP_ROOT/state" \
      PATH="$RUNTIME_ROOT/bin:$PATH" "$RUNTIME_ROOT/bin/eci-active" "$@"
  )
}

run_hook() {
  local session="$1" command="$2" role="${3:-coordinator}" output="$TMP_ROOT/hook-$session-${RANDOM}.json"
  local subagent=false
  if [ "$role" = worker ]; then
    subagent=true
  fi
  jq -cn --arg session "$session" --arg cwd "$REPOSITORY" --arg command "$command" \
    '{session_id:$session,cwd:$cwd,tool_input:{command:$command}}' |
    HOME="$HOME_ROOT" CODEX_HOME="$RUNTIME_ROOT" CODEX_PROOF_ROOT="$PROOF_ROOT" \
      CODEX_ROLE="$role" CODEX_HOOK_IS_SUBAGENT="$subagent" \
      XDG_CONFIG_HOME="$TMP_ROOT/config" XDG_STATE_HOME="$TMP_ROOT/state" \
      PATH="$RUNTIME_ROOT/bin:$PATH" bash "$RUNTIME_ROOT/hooks/validate-bash.sh" >"$output"
  printf '%s\n' "$output"
}

assert_allowed() {
  local session="$1" command="$2" role="${3:-coordinator}" output
  output="$(run_hook "$session" "$command" "$role")"
  if [ -s "$output" ]; then
    printf 'expected ledger redirect to proceed: %q\n' "$command" >&2
    cat -- "$output" >&2
    return 1
  fi
}

assert_denied() {
  local session="$1" command="$2" code="$3" detail="${4:-}" role="${5:-coordinator}" output
  output="$(run_hook "$session" "$command" "$role")"
  jq -e --arg code "[$code]" --arg detail "$detail" '
    .hookSpecificOutput.permissionDecision == "deny" and
    (.hookSpecificOutput.permissionDecisionReason | contains($code)) and
    ($detail == "" or (.hookSpecificOutput.permissionDecisionReason | contains($detail))) and
    (.hookSpecificOutput.permissionDecisionReason | contains("[ECI_CONTROL_OWNER_REQUIRED]") | not) and
    (.hookSpecificOutput.permissionDecisionReason | contains("[ECI_PLAN_LIVE_CONTROL_DENIED]") | not)
  ' "$output" >/dev/null || {
    printf 'expected %s denial for ledger redirect: %q\n' "$code" "$command" >&2
    [ ! -e "$output" ] || cat -- "$output" >&2
    return 1
  }
}

assert_control_denied() {
  local session="$1" command="$2" target="$3" role="${4:-coordinator}" output
  output="$(run_hook "$session" "$command" "$role")"
  jq -e --arg target "$target" '
    .hookSpecificOutput.permissionDecision == "deny" and
    (.hookSpecificOutput.permissionDecisionReason | contains("[ECI_CONTROL_OWNER_REQUIRED]")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("resolved_control_target=" + $target))
  ' "$output" >/dev/null || {
    printf 'expected current-session control-target denial for: %q\n' "$command" >&2
    [ ! -e "$output" ] || cat -- "$output" >&2
    return 1
  }
}

assert_no_new_current_control_target_denial() {
  local session="$1" command="$2" role="${3:-coordinator}" output
  if [ "$role" = coordinator ]; then
    assert_allowed "$session" "$command" "$role"
    return 0
  fi
  output="$(run_hook "$session" "$command" "$role")"
  [ ! -s "$output" ] && return 0
  jq -e '
    .hookSpecificOutput.permissionDecision == "deny" and
    (.hookSpecificOutput.permissionDecisionReason | contains("resolved_control_target=") | not)
  ' "$output" >/dev/null || {
    printf 'non-qualifying writer form gained a current-target denial: %q\n' "$command" >&2
    [ ! -e "$output" ] || cat -- "$output" >&2
    return 1
  }
}

hook_disposition() {
  local output="$1"
  if [ ! -s "$output" ]; then
    printf '%s\n' allow
    return 0
  fi
  jq -r '
    if .hookSpecificOutput.permissionDecision == "deny" then
      .hookSpecificOutput.permissionDecisionReason |
      capture("\\[(?<code>ECI_[A-Z0-9_]+)\\]").code
    else
      "allow"
    end
  ' "$output"
}

assert_prefix_disposition_preserved() {
  local session="$1" prefix="$2" target="$3" role="${4:-coordinator}"
  local direct_output append_output direct_disposition append_disposition
  direct_output="$(run_hook "$session" "$prefix" "$role")"
  append_output="$(run_hook "$session" "printf ledger-entry >> \"$target\"; $prefix" "$role")"
  direct_disposition="$(hook_disposition "$direct_output")"
  append_disposition="$(hook_disposition "$append_output")"
  if [ "$role" = worker ] && [ "$direct_disposition" = allow ]; then
    printf 'expected worker lifecycle/control prefix to retain its protected route: %q\n' "$prefix" >&2
    return 1
  fi
  if [ "$direct_disposition" != "$append_disposition" ]; then
    printf 'terminal ledger redirect changed protected prefix disposition: %q\n' "$prefix" >&2
    printf 'direct=%s appended=%s\n' "$direct_disposition" "$append_disposition" >&2
    cat -- "$direct_output" "$append_output" >&2
    return 1
  fi
}

SESSION=current-ledger-session
SESSION_DIR="$PROOF_ROOT/$SESSION"
LOG="$SESSION_DIR/high_level_log.md"
ANCHOR="$SESSION_DIR/high_level_log.anchor"
mkdir -p -- "$SESSION_DIR"
printf '%s\n' 'initial ledger entry' >"$LOG"
run_lifecycle "$SESSION" on 'direct ledger redirect fixture' >/dev/null

# Current-session EOF appends are role-neutral, including normal FD append
# spelling. They do not depend on a lifecycle invocation or anchor receipt.
assert_allowed "$SESSION" "printf raw >> $LOG" coordinator
assert_allowed "$SESSION" "printf raw >> $LOG" worker
assert_allowed "$SESSION" "printf raw 2>> $LOG" coordinator
assert_allowed "$SESSION" "printf raw 2>> $LOG" worker
assert_allowed "$SESSION" "printf raw &>> $LOG" coordinator
assert_allowed "$SESSION" "printf raw &>> $LOG" worker
assert_allowed "$SESSION" 'printf raw 2>&1' coordinator
assert_allowed "$SESSION" 'printf raw 2>&1' worker

# Rewrites, anchors, sibling session records, escapes, and shared inodes keep
# distinct concrete diagnostics. Hook admission never executes these commands.
assert_denied "$SESSION" "printf raw > $LOG" ECI_LEDGER_REWRITE_DENIED 'effect=overwrite'
assert_denied "$SESSION" "printf raw >| $LOG" ECI_LEDGER_REWRITE_DENIED 'effect=force-overwrite'
assert_denied "$SESSION" "printf raw >& $LOG" ECI_LEDGER_REWRITE_DENIED 'effect=overwrite'
assert_denied "$SESSION" "printf raw &> $LOG" ECI_LEDGER_REWRITE_DENIED 'effect=overwrite'
assert_denied "$SESSION" "printf raw >> $ANCHOR" ECI_LEDGER_ANCHOR_WRITE_DENIED 'target=high_level_log.anchor'

FOREIGN_SESSION=foreign-ledger-session
FOREIGN_DIR="$PROOF_ROOT/$FOREIGN_SESSION"
FOREIGN_LOG="$FOREIGN_DIR/high_level_log.md"
FOREIGN_ANCHOR="$FOREIGN_DIR/high_level_log.anchor"
mkdir -p -- "$FOREIGN_DIR"
printf '%s\n' foreign >"$FOREIGN_LOG"
printf '%s\n' foreign-anchor >"$FOREIGN_ANCHOR"
assert_denied "$SESSION" "printf raw >> $FOREIGN_LOG" ECI_LEDGER_FOREIGN_SESSION_DENIED "target_session=$FOREIGN_SESSION"
assert_denied "$SESSION" "printf raw >> $FOREIGN_ANCHOR" ECI_LEDGER_FOREIGN_SESSION_DENIED "target_session=$FOREIGN_SESSION"

ESCAPE_TARGET="$TMP_ROOT/outside-ledger.txt"
ESCAPE_LINK="$SESSION_DIR/escaping-ledger-link"
printf '%s\n' outside >"$ESCAPE_TARGET"
ln -s -- "$ESCAPE_TARGET" "$ESCAPE_LINK"
assert_denied "$SESSION" "printf raw >> $ESCAPE_LINK" ECI_PROOF_PATH_ESCAPE_DENIED 'predicate=proof-symlink-escape'

SHARED_PEER="$TMP_ROOT/shared-ledger-peer"
ln -- "$LOG" "$SHARED_PEER"
cp -- "$SHARED_PEER" "$TMP_ROOT/shared-ledger-peer.before"
assert_denied "$SESSION" "printf raw >> $LOG" ECI_LEDGER_SHARED_INODE_DENIED 'nlink=2'
cmp -s -- "$TMP_ROOT/shared-ledger-peer.before" "$SHARED_PEER"
rm -f -- "$SHARED_PEER"

# A literal path outside the proof root can still resolve to an active ledger
# inode. Preserve the target-specific diagnostics for both callback roles;
# these aliases must not become generic worker-control denials.
EXTERNAL_CURRENT_LOG="$TMP_ROOT/external-current-log"
EXTERNAL_CURRENT_ANCHOR="$TMP_ROOT/external-current-anchor"
EXTERNAL_FOREIGN_LOG="$TMP_ROOT/external-foreign-log"
EXTERNAL_FOREIGN_ANCHOR="$TMP_ROOT/external-foreign-anchor"
ln -- "$LOG" "$EXTERNAL_CURRENT_LOG"
ln -- "$ANCHOR" "$EXTERNAL_CURRENT_ANCHOR"
ln -- "$FOREIGN_LOG" "$EXTERNAL_FOREIGN_LOG"
ln -- "$FOREIGN_ANCHOR" "$EXTERNAL_FOREIGN_ANCHOR"
for role in coordinator worker; do
  assert_denied "$SESSION" "printf raw > $EXTERNAL_CURRENT_LOG" ECI_LEDGER_REWRITE_DENIED 'effect=overwrite' "$role"
  assert_denied "$SESSION" "printf raw >> $EXTERNAL_CURRENT_LOG" ECI_LEDGER_SHARED_INODE_DENIED 'nlink=2' "$role"
  assert_denied "$SESSION" "printf raw >> $EXTERNAL_CURRENT_ANCHOR" ECI_LEDGER_ANCHOR_WRITE_DENIED 'target=high_level_log.anchor' "$role"
  assert_denied "$SESSION" "printf raw >> $EXTERNAL_FOREIGN_LOG" ECI_LEDGER_FOREIGN_SESSION_DENIED "target_session=$FOREIGN_SESSION" "$role"
  assert_denied "$SESSION" "printf raw >> $EXTERNAL_FOREIGN_ANCHOR" ECI_LEDGER_FOREIGN_SESSION_DENIED "target_session=$FOREIGN_SESSION" "$role"
done

ORDINARY_OUTPUT="$TMP_ROOT/ordinary-output.txt"
assert_allowed "$SESSION" "printf raw > $ORDINARY_OUTPUT"
assert_allowed "$SESSION" "printf raw >> $ORDINARY_OUTPUT"
assert_allowed "$SESSION" "printf raw >| $ORDINARY_OUTPUT"

assert_reconciliation_preserves_raw_append() {
  local session="$1" seed="$2" log anchor snapshot prefix raw_bytes raw_hash anchor_bytes anchor_hash actual_bytes actual_hash
  local session_dir="$PROOF_ROOT/$session"
  log="$session_dir/high_level_log.md"
  anchor="$session_dir/high_level_log.anchor"
  snapshot="$TMP_ROOT/$session.raw"
  prefix="$TMP_ROOT/$session.prefix"

  mkdir -p -- "$session_dir"
  printf '%s' "$seed" >"$log"
  run_lifecycle "$session" on 'raw append reconciliation fixture' >/dev/null
  assert_allowed "$session" "printf raw >> $log" worker
  printf '%s' raw-direct-entry >>"$log"
  cp -- "$log" "$snapshot"
  raw_bytes="$(wc -c <"$snapshot")"
  raw_hash="$(sha256sum -- "$snapshot" | awk '{print $1}')"
  cp -- "$anchor" "$TMP_ROOT/$session.anchor.before"

  run_lifecycle "$session" ledger-append "lifecycle reconciliation $session" >/dev/null
  head -c "$raw_bytes" -- "$log" >"$prefix"
  cmp -s -- "$snapshot" "$prefix"
  [ "$(sha256sum -- "$prefix" | awk '{print $1}')" = "$raw_hash" ]
  actual_bytes="$(wc -c <"$log")"
  actual_hash="$(sha256sum -- "$log" | awk '{print $1}')"
  anchor_bytes="$(awk -F ': ' '$1 == "bytes" { print $2 }' "$anchor")"
  anchor_hash="$(awk -F ': ' '$1 == "sha256" { print $2 }' "$anchor")"
  [ "$anchor_bytes" = "$actual_bytes" ]
  [ "$anchor_hash" = "$actual_hash" ]
  [ "$(sha256sum -- "$anchor" | awk '{print $1}')" != "$(sha256sum -- "$TMP_ROOT/$session.anchor.before" | awk '{print $1}')" ]
}

# A raw append need not have an anchor precondition. The lifecycle route later
# retains the raw bytes and publishes a fresh full-file anchor both when the
# prior log did and did not end in LF.
assert_reconciliation_preserves_raw_append ledger-reconcile-with-lf $'seed with LF\n'
assert_reconciliation_preserves_raw_append ledger-reconcile-without-lf 'seed without LF'

# Remove only the copied planner source after all normal-path checks above.
# The final probe exercises the real copied hook when no planner binary or
# source is available, without changing either live user-owned bypass.
FALLBACK_SESSION=planner-unavailable-ledger-session
FALLBACK_DIR="$PROOF_ROOT/$FALLBACK_SESSION"
FALLBACK_LOG="$FALLBACK_DIR/high_level_log.md"
FALLBACK_ANCHOR="$FALLBACK_DIR/high_level_log.anchor"
FALLBACK_FOREIGN_SESSION=planner-unavailable-foreign-session
FALLBACK_FOREIGN_DIR="$PROOF_ROOT/$FALLBACK_FOREIGN_SESSION"
FALLBACK_FOREIGN_LOG="$FALLBACK_FOREIGN_DIR/high_level_log.md"
FALLBACK_FOREIGN_ACTIVE="$FALLBACK_FOREIGN_DIR/eci_active"
FALLBACK_ESCAPE_TARGET="$TMP_ROOT/planner-unavailable-outside-log"
FALLBACK_ESCAPE_LINK="$FALLBACK_DIR/escaping-output"
FALLBACK_ACTIVE="$FALLBACK_DIR/eci_active"
FALLBACK_GOAL="$FALLBACK_DIR/goal_state"
FALLBACK_ORDINARY="$TMP_ROOT/planner-unavailable-ordinary-output"
FALLBACK_ACTIVE_REAL="$(realpath -m -- "$FALLBACK_ACTIVE")"
FALLBACK_GOAL_REAL="$(realpath -m -- "$FALLBACK_GOAL")"
mkdir -p -- "$FALLBACK_DIR" "$FALLBACK_FOREIGN_DIR"
printf '%s\n' current >"$FALLBACK_LOG"
printf '%s\n' foreign >"$FALLBACK_FOREIGN_LOG"
run_lifecycle "$FALLBACK_SESSION" on 'planner-unavailable ledger fallback fixture' >/dev/null
printf '%s\n' outside >"$FALLBACK_ESCAPE_TARGET"
ln -s -- "$FALLBACK_ESCAPE_TARGET" "$FALLBACK_ESCAPE_LINK"
rm -rf -- "$PLANNER_DIR"

for role in coordinator worker; do
  assert_allowed "$FALLBACK_SESSION" "printf raw >> $FALLBACK_LOG" "$role"
  assert_allowed "$FALLBACK_SESSION" "printf raw &>> \"$FALLBACK_LOG\"" "$role"
  assert_allowed "$FALLBACK_SESSION" "printf 'quoted ledger entry' >> \"$FALLBACK_LOG\"" "$role"
  assert_allowed "$FALLBACK_SESSION" "printf harmless; printf raw >> \"$FALLBACK_LOG\"" "$role"
  assert_allowed "$FALLBACK_SESSION" "LEDGER_NOTE=ordinary printf raw >> \"$FALLBACK_LOG\"" "$role"
  assert_denied "$FALLBACK_SESSION" "LEDGER_NOTE=ordinary printf raw >> \"$FALLBACK_ANCHOR\"" ECI_LEDGER_ANCHOR_WRITE_DENIED 'target=high_level_log.anchor' "$role"
  assert_allowed "$FALLBACK_SESSION" "LEDGER_NOTE=\"\$UNRESOLVED_LEDGER_NOTE\" printf raw >> \"$FALLBACK_LOG\"" "$role"
  assert_allowed "$FALLBACK_SESSION" "printf \"\$(printf harmless)\" >> \"$FALLBACK_LOG\"" "$role"
  assert_allowed "$FALLBACK_SESSION" "printf \"\$(printf \"\$(printf harmless)\")\" >> \"$FALLBACK_LOG\"" "$role"
  assert_allowed "$FALLBACK_SESSION" "printf \"\$(printf '\$')\" >> \"$FALLBACK_LOG\"" "$role"
  assert_allowed "$FALLBACK_SESSION" "printf \"\`printf harmless\`\" >> \"$FALLBACK_LOG\"" "$role"
  assert_allowed "$FALLBACK_SESSION" "printf \"\$(\$UNRESOLVED_LEDGER_COMMAND)\" >> \"$FALLBACK_LOG\"" "$role"
  assert_allowed "$FALLBACK_SESSION" "\"\$UNRESOLVED_SHELL\" -c 'rm -rf /' >> \"$FALLBACK_LOG\"" "$role"
  assert_allowed "$FALLBACK_SESSION" "bash -c \"\$UNRESOLVED_SHELL_PAYLOAD\" >> \"$FALLBACK_LOG\"" "$role"
  assert_allowed "$FALLBACK_SESSION" "printf \"\$(printf malformed\" >> \"$FALLBACK_LOG\"" "$role"
  assert_allowed "$FALLBACK_SESSION" "printf harmless && printf raw >> \"$FALLBACK_LOG\"" "$role"
  assert_allowed "$FALLBACK_SESSION" "printf harmless || printf raw >> \"$FALLBACK_LOG\"" "$role"
  assert_allowed "$FALLBACK_SESSION" "printf harmless | printf raw >> \"$FALLBACK_LOG\"" "$role"
  assert_allowed "$FALLBACK_SESSION" "printf harmless & printf raw >> \"$FALLBACK_LOG\"" "$role"
  assert_allowed "$FALLBACK_SESSION" "touch \"$FALLBACK_ORDINARY\"" "$role"
  assert_allowed "$FALLBACK_SESSION" "touch \"$FALLBACK_DIR/\$UNRESOLVED_LEDGER_TARGET\"" "$role"
  assert_denied "$FALLBACK_SESSION" "printf \"\$(rm -rf /)\" >> \"$FALLBACK_LOG\"" ECI_BROAD_DESTRUCTIVE_DENIED 'kind=recursive-root-delete' "$role"
  assert_denied "$FALLBACK_SESSION" "printf \"\$(printf \"\$(rm -rf /)\")\" >> \"$FALLBACK_LOG\"" ECI_BROAD_DESTRUCTIVE_DENIED 'kind=recursive-root-delete' "$role"
  assert_denied "$FALLBACK_SESSION" "printf \"\$(printf '\$'; rm -rf /)\" >> \"$FALLBACK_LOG\"" ECI_BROAD_DESTRUCTIVE_DENIED 'kind=recursive-root-delete' "$role"
  assert_denied "$FALLBACK_SESSION" "printf \"\`rm -rf /\`\" >> \"$FALLBACK_LOG\"" ECI_BROAD_DESTRUCTIVE_DENIED 'kind=recursive-root-delete' "$role"
  for shell in bash sh /bin/bash /bin/sh /usr/bin/bash /usr/bin/sh; do
    assert_allowed "$FALLBACK_SESSION" "$shell -c 'printf harmless' >> \"$FALLBACK_LOG\"" "$role"
    assert_denied "$FALLBACK_SESSION" "$shell -c 'rm -rf /' >> \"$FALLBACK_LOG\"" ECI_BROAD_DESTRUCTIVE_DENIED 'kind=recursive-root-delete' "$role"
  done
  assert_allowed "$FALLBACK_SESSION" "unrecognized-ledger-wrapper --ordinary-argument >> \"$FALLBACK_LOG\"" "$role"
  assert_denied "$FALLBACK_SESSION" "printf raw >> \"$FALLBACK_LOG\"; rm -rf /" ECI_BROAD_DESTRUCTIVE_DENIED 'kind=recursive-root-delete' "$role"
  assert_denied "$FALLBACK_SESSION" "printf raw >> \"$FALLBACK_LOG\"; git -C $FOREIGN_REPOSITORY add -- file.txt" ECI_GIT_CROSS_SCOPE_DENIED 'active_repo=' "$role"
  assert_denied "$FALLBACK_SESSION" "printf raw >> \"$FALLBACK_LOG\"; git -C $REPOSITORY add ." ECI_BROAD_DESTRUCTIVE_DENIED 'effect=whole-worktree-staging' "$role"
  assert_denied "$FALLBACK_SESSION" "printf raw >> \"$FALLBACK_LOG\"; git -C $REPOSITORY reset --hard" ECI_BROAD_DESTRUCTIVE_DENIED 'effect=reset-working-tree' "$role"
  assert_denied "$FALLBACK_SESSION" "printf raw >> \"$FALLBACK_LOG\"; touch $FALLBACK_ESCAPE_LINK" ECI_PROOF_PATH_ESCAPE_DENIED 'write target follows an escaping proof symlink' "$role"
  assert_denied "$FALLBACK_SESSION" "printf raw >> \"$FALLBACK_LOG\" & rm -rf /" ECI_BROAD_DESTRUCTIVE_DENIED 'kind=recursive-root-delete' "$role"
  assert_denied "$FALLBACK_SESSION" "printf raw >> \"$FALLBACK_LOG\" & git -C $FOREIGN_REPOSITORY add -- file.txt" ECI_GIT_CROSS_SCOPE_DENIED 'active_repo=' "$role"
  assert_denied "$FALLBACK_SESSION" "printf raw >> \"$FALLBACK_LOG\" & touch $FALLBACK_ESCAPE_LINK" ECI_PROOF_PATH_ESCAPE_DENIED 'write target follows an escaping proof symlink' "$role"
  assert_control_denied "$FALLBACK_SESSION" "touch \"$FALLBACK_ACTIVE\"" "$FALLBACK_ACTIVE_REAL" "$role"
  assert_control_denied "$FALLBACK_SESSION" "touch \"$FALLBACK_GOAL\"" "$FALLBACK_GOAL_REAL" "$role"
  assert_control_denied "$FALLBACK_SESSION" "printf raw >> \"$FALLBACK_LOG\"; touch \"$FALLBACK_ACTIVE\"" "$FALLBACK_ACTIVE_REAL" "$role"
  assert_control_denied "$FALLBACK_SESSION" "printf raw >> \"$FALLBACK_LOG\" & touch \"$FALLBACK_ACTIVE\"" "$FALLBACK_ACTIVE_REAL" "$role"
  assert_control_denied "$FALLBACK_SESSION" "printf \"\$(touch \"$FALLBACK_ACTIVE\")\" >> \"$FALLBACK_LOG\"" "$FALLBACK_ACTIVE_REAL" "$role"
  assert_control_denied "$FALLBACK_SESSION" "bash -c 'touch $FALLBACK_ACTIVE' >> \"$FALLBACK_LOG\"" "$FALLBACK_ACTIVE_REAL" "$role"

  # Finite writer forms are checked by their directly resolved output target,
  # not by the presence of a writer name, an option parser, or a shell form.
  # The coordinator probes are RED before the matching fallback extraction is
  # implemented; workers already have a later generic ownership route, so the
  # target-specific assertion below also proves diagnostic parity after GREEN.
  assert_control_denied "$FALLBACK_SESSION" "tee \"$FALLBACK_ACTIVE\"" "$FALLBACK_ACTIVE_REAL" "$role"
  assert_control_denied "$FALLBACK_SESSION" "tee \"$FALLBACK_ORDINARY\" \"$FALLBACK_ACTIVE\" </dev/null" "$FALLBACK_ACTIVE_REAL" "$role"
  assert_control_denied "$FALLBACK_SESSION" "tee \"$FALLBACK_ACTIVE\" < /dev/null" "$FALLBACK_ACTIVE_REAL" "$role"
  assert_control_denied "$FALLBACK_SESSION" "dd if=/dev/null of=\"$FALLBACK_ACTIVE\"" "$FALLBACK_ACTIVE_REAL" "$role"
  assert_control_denied "$FALLBACK_SESSION" "dd of=\"$FALLBACK_ACTIVE\" if=/dev/null" "$FALLBACK_ACTIVE_REAL" "$role"
  assert_control_denied "$FALLBACK_SESSION" "dd if=\"\$UNRESOLVED_LEDGER_INPUT\" of=\"$FALLBACK_ACTIVE\"" "$FALLBACK_ACTIVE_REAL" "$role"
  assert_control_denied "$FALLBACK_SESSION" "install /dev/null \"$FALLBACK_ACTIVE\"" "$FALLBACK_ACTIVE_REAL" "$role"
  assert_control_denied "$FALLBACK_SESSION" "install \"\$UNRESOLVED_LEDGER_SOURCE\" \"$FALLBACK_ACTIVE\"" "$FALLBACK_ACTIVE_REAL" "$role"
  assert_control_denied "$FALLBACK_SESSION" "install source:-still-positional \"$FALLBACK_ACTIVE\"" "$FALLBACK_ACTIVE_REAL" "$role"
  assert_control_denied "$FALLBACK_SESSION" "printf \"\$(tee \"$FALLBACK_ACTIVE\")\" >> \"$FALLBACK_LOG\"" "$FALLBACK_ACTIVE_REAL" "$role"
  assert_control_denied "$FALLBACK_SESSION" "printf \"\`dd if=/dev/null of=\"$FALLBACK_ACTIVE\"\`\" >> \"$FALLBACK_LOG\"" "$FALLBACK_ACTIVE_REAL" "$role"
  assert_control_denied "$FALLBACK_SESSION" "bash -c 'install /dev/null $FALLBACK_ACTIVE' >> \"$FALLBACK_LOG\"" "$FALLBACK_ACTIVE_REAL" "$role"
  assert_control_denied "$FALLBACK_SESSION" "printf raw >> \"$FALLBACK_LOG\"; tee \"$FALLBACK_ACTIVE\"" "$FALLBACK_ACTIVE_REAL" "$role"
  assert_control_denied "$FALLBACK_SESSION" "printf raw >> \"$FALLBACK_LOG\" & dd if=/dev/null of=\"$FALLBACK_ACTIVE\"" "$FALLBACK_ACTIVE_REAL" "$role"

  assert_allowed "$FALLBACK_SESSION" "tee \"$FALLBACK_ORDINARY\"" "$role"
  assert_allowed "$FALLBACK_SESSION" "dd if=/dev/null of=\"$FALLBACK_ORDINARY\"" "$role"
  assert_allowed "$FALLBACK_SESSION" "install /dev/null \"$FALLBACK_ORDINARY\"" "$role"
  assert_allowed "$FALLBACK_SESSION" "tee \"$FALLBACK_DIR/\$UNRESOLVED_LEDGER_TARGET\"" "$role"
  assert_allowed "$FALLBACK_SESSION" "dd if=/dev/null of=\"$FALLBACK_DIR/\$UNRESOLVED_LEDGER_TARGET\"" "$role"
  assert_allowed "$FALLBACK_SESSION" "install /dev/null \"$FALLBACK_DIR/\$UNRESOLVED_LEDGER_TARGET\"" "$role"

  # Do not infer output roles for options, wrappers, path spellings, unknown
  # operands, or input redirection other than tee's exact /dev/null suffix.
  assert_no_new_current_control_target_denial "$FALLBACK_SESSION" "tee -a \"$FALLBACK_ACTIVE\"" "$role"
  assert_no_new_current_control_target_denial "$FALLBACK_SESSION" "tee -- \"$FALLBACK_ACTIVE\"" "$role"
  assert_no_new_current_control_target_denial "$FALLBACK_SESSION" "tee \"$FALLBACK_ACTIVE\" < \"$FALLBACK_LOG\"" "$role"
  assert_no_new_current_control_target_denial "$FALLBACK_SESSION" "dd if=/dev/null of=\"$FALLBACK_ACTIVE\" bs=1" "$role"
  assert_no_new_current_control_target_denial "$FALLBACK_SESSION" "install -m 600 /dev/null \"$FALLBACK_ACTIVE\"" "$role"
  assert_no_new_current_control_target_denial "$FALLBACK_SESSION" "/usr/bin/tee \"$FALLBACK_ACTIVE\"" "$role"
  assert_no_new_current_control_target_denial "$FALLBACK_SESSION" "env dd if=/dev/null of=\"$FALLBACK_ACTIVE\"" "$role"
  assert_no_new_current_control_target_denial "$FALLBACK_SESSION" "/usr/bin/install /dev/null \"$FALLBACK_ACTIVE\"" "$role"
  if [ "$role" = coordinator ]; then
    assert_denied "$FALLBACK_SESSION" "tee \"$FALLBACK_FOREIGN_ACTIVE\"" ECI_CROSS_SESSION_ACTIVE_MARKER_DENIED "foreign_session=$FALLBACK_FOREIGN_SESSION" "$role"
  else
    assert_no_new_current_control_target_denial "$FALLBACK_SESSION" "tee \"$FALLBACK_FOREIGN_ACTIVE\"" "$role"
  fi

  # Redirect-specific diagnostics remain more concrete than the writer target.
  assert_denied "$FALLBACK_SESSION" "tee \"$FALLBACK_ACTIVE\" >> \"$FALLBACK_ANCHOR\"" ECI_LEDGER_ANCHOR_WRITE_DENIED 'target=high_level_log.anchor' "$role"
  assert_denied "$FALLBACK_SESSION" "dd if=/dev/null of=\"$FALLBACK_ACTIVE\" >> \"$FALLBACK_FOREIGN_LOG\"" ECI_LEDGER_FOREIGN_SESSION_DENIED "target_session=$FALLBACK_FOREIGN_SESSION" "$role"
  assert_denied "$FALLBACK_SESSION" "install /dev/null \"$FALLBACK_ACTIVE\" >> \"$FALLBACK_ESCAPE_LINK\"" ECI_PROOF_PATH_ESCAPE_DENIED 'predicate=proof-symlink-escape' "$role"
  assert_prefix_disposition_preserved "$FALLBACK_SESSION" "$RUNTIME_ROOT/bin/eci-active off $TMP_ROOT/fallback-disengage.md" "$FALLBACK_LOG" "$role"
  assert_denied "$FALLBACK_SESSION" "cat /dev/null > $FALLBACK_LOG" ECI_LEDGER_REWRITE_DENIED 'effect=overwrite' "$role"
  assert_denied "$FALLBACK_SESSION" "printf raw &> \"$FALLBACK_LOG\"" ECI_LEDGER_REWRITE_DENIED 'effect=overwrite' "$role"
  assert_denied "$FALLBACK_SESSION" "printf raw > $FALLBACK_LOG" ECI_LEDGER_REWRITE_DENIED 'effect=overwrite' "$role"
  assert_denied "$FALLBACK_SESSION" "printf raw >> $FALLBACK_ANCHOR" ECI_LEDGER_ANCHOR_WRITE_DENIED 'target=high_level_log.anchor' "$role"
  assert_denied "$FALLBACK_SESSION" "printf raw >> $FALLBACK_FOREIGN_LOG" ECI_LEDGER_FOREIGN_SESSION_DENIED "target_session=$FALLBACK_FOREIGN_SESSION" "$role"
  assert_denied "$FALLBACK_SESSION" "printf raw >> $FALLBACK_ESCAPE_LINK" ECI_PROOF_PATH_ESCAPE_DENIED 'predicate=proof-symlink-escape' "$role"
done
FALLBACK_SHARED_PEER="$TMP_ROOT/planner-unavailable-shared-log"
ln -- "$FALLBACK_LOG" "$FALLBACK_SHARED_PEER"
for role in coordinator worker; do
  assert_denied "$FALLBACK_SESSION" "printf raw >> $FALLBACK_LOG" ECI_LEDGER_SHARED_INODE_DENIED 'nlink=2' "$role"
  assert_denied "$FALLBACK_SESSION" "tee \"$FALLBACK_ACTIVE\" >> $FALLBACK_LOG" ECI_LEDGER_SHARED_INODE_DENIED 'nlink=2' "$role"
done
assert_allowed "$FALLBACK_SESSION" 'unrecognized-ledger-wrapper --ordinary-argument' worker
assert_allowed "$FALLBACK_SESSION" 'timeout not-a-duration git add .' worker

printf '%s\n' 'current-session ledger append: PASS'
