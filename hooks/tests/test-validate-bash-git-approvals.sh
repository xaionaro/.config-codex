#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_ROOT="$(mktemp -d "${CODEX_TMPDIR:-${HOME:?}/tmp}/codex-git-approvals.XXXXXX")"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

# Keep this standalone approval suite deterministic even when invoked outside
# the aggregate enforcing harness; production remains configured-permissive.
export XDG_CONFIG_HOME="$TMP_ROOT/xdg-config"
export XDG_STATE_HOME="$TMP_ROOT/xdg-state"
mkdir -p "$XDG_CONFIG_HOME/eci"
printf '%s\n' enforcing >"$XDG_CONFIG_HOME/eci/command-gate-mode"

proof_root="$TMP_ROOT/proof"
mkdir -p "$proof_root"
# The generic Git-mutation assertions exercise the active ECI ownership
# boundary for the coordinator session used by run_hook_at.  Keep this
# marker separate from the repository-bound commit-session fixture below so
# the direct-commit cases can continue to prove that an inactive/mismatched
# repository session has no hook output.
mkdir -p "$proof_root/git-approval-test"
printf '%s\n' \
  'scope: git approval coordinator test' \
  "cwd: $ROOT" \
  'session_id: git-approval-test' \
  'created_utc: 2026-08-15T00:00:00Z' \
  >"$proof_root/git-approval-test/eci_active"
repo="$TMP_ROOT/repo"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config user.email hooks-test@example.invalid
git -C "$repo" config user.name 'Hooks Test'
printf 'base\n' >"$repo/file.txt"
git -C "$repo" add file.txt
git -C "$repo" commit -qm initial

git_dir="$(git -C "$repo" rev-parse --absolute-git-dir)"

active_proof_root="$TMP_ROOT/active-proof"
mkdir -p "$active_proof_root/t00-session"
printf '%s\n' \
  'scope: git approval active-path test' \
  "cwd: $ROOT" \
  'session_id: t00-session' \
  'created_utc: 2026-08-15T00:00:00Z' \
  >"$active_proof_root/t00-session/eci_active"

active_repo_proof_root="$TMP_ROOT/active-repo-proof"
mkdir -p "$active_repo_proof_root/commit-session"
printf '%s\n' \
  'scope: git approval active-repo test' \
  "cwd: $repo" \
  'session_id: commit-session' \
  'created_utc: 2026-08-15T00:00:00Z' \
  >"$active_repo_proof_root/commit-session/eci_active"

# Worker ownership is evaluated against the worker callback's repository cwd,
# not the coordinator cwd used by run_hook_at.  Keep a separate marker root so
# the worker assertion exercises an active, correctly bound ECI session.
worker_proof_root="$TMP_ROOT/worker-proof"
mkdir -p "$worker_proof_root/git-approval-test"
printf '%s\n' \
  'scope: git approval worker test' \
  "cwd: $repo" \
  'session_id: git-approval-test' \
  'created_utc: 2026-08-15T00:00:00Z' \
  >"$worker_proof_root/git-approval-test/eci_active"

subagent_codex_home="$TMP_ROOT/subagent-codex-home"
subagent_transcript="$subagent_codex_home/sessions/codex-git-approval-subagent-$BASHPID.jsonl"
mkdir -p "$subagent_codex_home/sessions"

run_hook_at() {
  local hook_cwd="$1" command="$2" output="$TMP_ROOT/output"
  jq -cn --arg cwd "$hook_cwd" --arg command "$command" \
    '{session_id:"git-approval-test",cwd:$cwd,tool_input:{command:$command}}' |
    CODEX_PROOF_ROOT="$proof_root" CODEX_HOME="$ROOT" PATH="$ROOT/bin:$PATH" \
      bash "$ROOT/hooks/validate-bash.sh" >"$output"
  printf '%s\n' "$output"
}

run_hook_with_root() {
  local proof_root_arg="$1" hook_cwd="$2" session="$3" command="$4" output="$TMP_ROOT/root-output"
  jq -cn --arg session "$session" --arg cwd "$hook_cwd" --arg command "$command" \
    '{session_id:$session,cwd:$cwd,tool_input:{command:$command}}' |
    CODEX_PROOF_ROOT="$proof_root_arg" CODEX_HOME="$ROOT" PATH="$ROOT/bin:$PATH" \
      bash "$ROOT/hooks/validate-bash.sh" >"$output"
  printf '%s\n' "$output"
}

run_hook() {
  run_hook_at "$ROOT" "$1"
}

run_active_hook() {
  local command="$1" output="$TMP_ROOT/active-output"
  jq -cn --arg cwd "$ROOT" --arg command "$command" \
    '{session_id:"t00-session",cwd:$cwd,tool_input:{command:$command}}' |
    CODEX_PROOF_ROOT="$active_proof_root" CODEX_HOME="$ROOT" PATH="$ROOT/bin:$PATH" \
      bash "$ROOT/hooks/validate-bash.sh" >"$output"
  printf '%s\n' "$output"
}

run_active_repo_hook() {
  local command="$1" output="$TMP_ROOT/active-repo-output"
  jq -cn --arg cwd "$repo" --arg command "$command" \
    '{session_id:"commit-session",cwd:$cwd,tool_input:{command:$command}}' |
    CODEX_PROOF_ROOT="$active_repo_proof_root" CODEX_HOME="$ROOT" PATH="$ROOT/bin:$PATH" \
      bash "$ROOT/hooks/validate-bash.sh" >"$output"
  printf '%s\n' "$output"
}

run_active_repo_git_context_hook() {
  local command="$1" output="$TMP_ROOT/active-repo-git-context-output"
  jq -cn --arg cwd "$repo" --arg command "$command" \
    '{session_id:"commit-session",cwd:$cwd,tool_input:{command:$command}}' |
    GIT_DIR="$TMP_ROOT/alternate.git" GIT_EDITOR="$TMP_ROOT/alternate-editor" \
    CODEX_PROOF_ROOT="$active_repo_proof_root" CODEX_HOME="$ROOT" PATH="$ROOT/bin:$PATH" \
      bash "$ROOT/hooks/validate-bash.sh" >"$output"
  printf '%s\n' "$output"
}

run_worker_hook() {
  local command="$1" hook_cwd="${2:-$ROOT}" output="$TMP_ROOT/worker-output"
  printf '%s\n' '{"timestamp":"2026-08-15T00:00:00.000Z","type":"session_meta","payload":{"id":"git-approval-test","source":{"subagent":{"thread_spawn":{"parent_thread_id":"parent","depth":1,"agent_nickname":"ApprovalTest","agent_role":"default"}}}}}' >"$subagent_transcript"
  jq -cn --arg cwd "$hook_cwd" --arg command "$command" --arg transcript "$subagent_transcript" \
    '{session_id:"git-approval-test",cwd:$cwd,transcript_path:$transcript,tool_input:{command:$command}}' |
    CODEX_PROOF_ROOT="$worker_proof_root" CODEX_HOME="$subagent_codex_home" PATH="$subagent_codex_home/bin:$PATH" \
      bash "$ROOT/hooks/validate-bash.sh" >"$output"
  printf '%s\n' "$output"
}

assert_generic_deny() {
  local command="$1" hook_cwd="${2:-$ROOT}" output
  output="$(run_hook_at "$hook_cwd" "$command")"
  jq -e '
    .hookSpecificOutput.permissionDecision == "deny" and
    (.hookSpecificOutput.permissionDecisionReason | contains("[ECI_GIT_MUTATION_DENIED]")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("phase=PreToolUse")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("operation=git-mutation")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("git repository mutation denied")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("operation=")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("repo=")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("path=")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("remediation:")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("command="))
  ' "$output" >/dev/null
}

assert_any_deny() {
  local command="$1" hook_cwd="${2:-$ROOT}" output
  output="$(run_hook_at "$hook_cwd" "$command")"
  jq -e '
    .hookSpecificOutput.permissionDecision == "deny" and
    (.hookSpecificOutput.permissionDecisionReason |
      contains("[ECI_") and
      contains("phase=") and
      contains("operation=") and
      (contains("subject=") or contains("segment=")) and
      contains("reason:") and
      contains("remediation:") and
      (contains("command=") or contains("segment=") or
       contains("path=") or contains("repo=")))
  ' "$output" >/dev/null
}

assert_allowed_and_consumed() {
  local command="$1" marker="$2" hook_cwd="${3:-$ROOT}" output
  output="$(run_hook_at "$hook_cwd" "$command")"
  if [ -s "$output" ]; then
    cat -- "$output"
    return 1
  fi
  [ ! -e "$marker" ]
}

assert_no_hook_output() {
  local command="$1" hook_cwd="${2:-$ROOT}" output
  output="$(run_hook_at "$hook_cwd" "$command")"
  if [ -s "$output" ]; then
    cat -- "$output"
    return 1
  fi
}

write_approval() {
  local marker="$1" operation="$2" command="$3" authorized_by="${4:-user}" \
    marker_repo="${5:-$repo}" reason="${6:-user-approved test}" approved_at="${7:-2026-08-15T00:00:00Z}"
  {
    printf 'schema: codex-user-git-approval/v1\n'
    printf 'authorized_by: %s\n' "$authorized_by"
    printf 'operation: %s\n' "$operation"
    printf 'repo_root: %s\n' "$marker_repo"
    printf 'git_dir: %s\n' "$git_dir"
    printf 'command: %s\n' "$command"
    printf 'reason: %s\n' "$reason"
    printf 'approved_at: %s\n' "$approved_at"
    printf 'one_time: true\n'
  } >"$marker"
}

reset_command="git -C $repo reset --hard HEAD"
reset_marker="$repo/.git-reset-approved-once"
assert_generic_deny "$reset_command"

assert_generic_deny "/usr/bin/git -C $repo reset --hard HEAD"

write_approval "$reset_marker" reset "$reset_command" agent
assert_generic_deny "$reset_command"
[ -e "$reset_marker" ]

write_approval "$reset_marker" reset 'git -C /other/repo reset --hard HEAD'
assert_generic_deny "$reset_command"
[ -e "$reset_marker" ]

write_approval "$reset_marker" reset "$reset_command"
assert_allowed_and_consumed "$reset_command" "$reset_marker"
assert_generic_deny "$reset_command"

write_approval "$reset_marker" reset "$reset_command"
active_output="$(run_active_hook "$reset_command")"
[ ! -s "$active_output" ]
[ ! -e "$reset_marker" ]

write_approval "$reset_marker" reset "$reset_command"
assert_generic_deny "env git -C $repo reset --hard HEAD"
[ -e "$reset_marker" ]

worktree_marker="$repo/.git-worktree-approved-once"
assert_generic_deny "git -C $repo worktree add $TMP_ROOT/worktree-add HEAD"

declare -a worktree_commands=(
  "git -C $repo worktree add $TMP_ROOT/worktree-add HEAD"
  "git -C $repo worktree remove $TMP_ROOT/worktree-remove"
  "git -C $repo worktree move $TMP_ROOT/worktree-old $TMP_ROOT/worktree-new"
  "git -C $repo worktree prune"
  "git -C $repo worktree lock $TMP_ROOT/worktree-lock"
  "git -C $repo worktree unlock $TMP_ROOT/worktree-unlock"
  "git -C $repo worktree repair"
)
for worktree_command in "${worktree_commands[@]}"; do
  write_approval "$worktree_marker" worktree "$worktree_command"
  assert_allowed_and_consumed "$worktree_command" "$worktree_marker"
done

active_worktree_command="git -C $repo worktree prune"
write_approval "$worktree_marker" worktree "$active_worktree_command"
active_output="$(run_active_hook "$active_worktree_command")"
[ ! -s "$active_output" ]
[ ! -e "$worktree_marker" ]

write_approval "$worktree_marker" worktree "git -C $repo worktree add $TMP_ROOT/wrapped HEAD"
assert_any_deny "bash -c 'git -C $repo worktree add $TMP_ROOT/wrapped HEAD'"
[ -e "$worktree_marker" ]

rm -f -- "$worktree_marker"
assert_generic_deny "git -C $repo worktree -v add $TMP_ROOT/option-wrapped HEAD"
write_approval "$worktree_marker" worktree "git -C $repo worktree -v add $TMP_ROOT/option-wrapped HEAD"
assert_generic_deny "git -C $repo worktree -v add $TMP_ROOT/option-wrapped HEAD"
[ -e "$worktree_marker" ]

# Direct commit approval is narrower than the ordinary review-gated commit
# route: only a literal `git commit` invocation with bounded post-subcommand
# options may consume the pre-existing repository-root approval. The claim is
# one-time and the approval does not fabricate or replace critic/evidence
# admission.
commit_command='git commit'
commit_message_command="git commit -m 'review message'"
commit_marker="$repo/.git-commit-approved-once"
# Without an active ECI marker, the ordinary direct commit route is not an
# approval operation; the approval is an optional exact workaround.
assert_no_hook_output "$commit_command" "$repo"
assert_no_hook_output "$commit_message_command" "$repo"
write_approval "$commit_marker" commit "$commit_command" agent
assert_generic_deny "$commit_command" "$repo"
[ -e "$commit_marker" ]
write_approval "$commit_marker" commit "$commit_command"
assert_allowed_and_consumed "$commit_command" "$commit_marker" "$repo"

# A consumed approval cannot be replayed, and mismatches/wrappers cannot
# consume an approval intended for the exact direct command.
assert_no_hook_output "$commit_command" "$repo"
write_approval "$commit_marker" commit "$commit_message_command"
assert_generic_deny "$commit_command" "$repo"
[ -e "$commit_marker" ]
assert_allowed_and_consumed "$commit_message_command" "$commit_marker" "$repo"

# The coordinator-owned CLI escape hatch may create exactly one validated
# approval claim for a canonical repository.  It is deliberately tested
# against both installed tools because Codex and Kimi share the approval
# artifact schema but have separate lifecycle CLIs.
assert_approval_cli() {
  local tool="$1" role_name="$2"
  local output_file="$TMP_ROOT/approve-commit-${role_name//[^[:alnum:]_.-]/_}.out"
  rm -f -- "$commit_marker"
  if ! CODEX_ROLE="$role_name" KIMI_ROLE="$role_name" CODEX_HOME="$ROOT" \
    "$tool" approve-commit "$repo" "$commit_message_command" >"$output_file" 2>&1; then
    cat -- "$output_file"
    return 1
  fi
  grep -Fq 'ECI commit approval artifact created for exact command' "$output_file"
  [ -f "$commit_marker" ] && [ ! -L "$commit_marker" ]
  grep -Fq "schema: codex-user-git-approval/v1" "$commit_marker"
  grep -Fq 'authorized_by: user' "$commit_marker"
  grep -Fq 'operation: commit' "$commit_marker"
  grep -Fq "repo_root: $repo" "$commit_marker"
  grep -Fq "git_dir: $git_dir" "$commit_marker"
  grep -Fq "command: $commit_message_command" "$commit_marker"
  grep -Fq 'one_time: true' "$commit_marker"
}

assert_approval_cli "$ROOT/bin/eci-active" coordinator
rm -f -- "$commit_marker"
assert_approval_cli /home/pheona/.kimi-code/bin/eci-active coordinator

# Worker identity, shell wrappers, and noncanonical repository aliases cannot
# use the escape hatch and must not leave a partially written claim.
rm -f -- "$commit_marker"
if CODEX_ROLE=subagent CODEX_HOME="$ROOT" "$ROOT/bin/eci-active" \
  approve-commit "$repo" "$commit_message_command" >"$TMP_ROOT/approve-worker.out" 2>&1; then
  exit 1
fi
grep -Fq 'ECI_APPROVE_COMMIT_OWNER_DENIED' "$TMP_ROOT/approve-worker.out"
[ ! -e "$commit_marker" ]
if CODEX_ROLE=coordinator CODEX_HOME="$ROOT" "$ROOT/bin/eci-active" \
  approve-commit "$repo" "bash -c 'git commit'" >"$TMP_ROOT/approve-wrapper.out" 2>&1; then
  exit 1
fi
grep -Fq 'ECI_APPROVE_COMMIT_COMMAND_DENIED' "$TMP_ROOT/approve-wrapper.out"
[ ! -e "$commit_marker" ]
repo_alias="$TMP_ROOT/repo-alias"
ln -s -- "$repo" "$repo_alias"
if CODEX_ROLE=coordinator CODEX_HOME="$ROOT" "$ROOT/bin/eci-active" \
  approve-commit "$repo_alias" "$commit_message_command" >"$TMP_ROOT/approve-alias.out" 2>&1; then
  exit 1
fi
grep -Fq 'ECI_APPROVE_COMMIT_REPO_DENIED' "$TMP_ROOT/approve-alias.out"
[ ! -e "$commit_marker" ]
for safe_commit in \
  "git commit --allow-empty" \
  "git commit -a --amend --no-verify --signoff" \
  "git commit --message=bounded"; do
  assert_no_hook_output "$safe_commit" "$repo"
done
literal_message=$'git commit -m \'cost $5 `literal` {brace}\''
assert_no_hook_output "$literal_message" "$repo"
unsafe_message=$'git commit -m "$(touch /tmp/eci-approval-shell-substitution)"'
assert_any_deny "$unsafe_message" "$repo"
write_approval "$commit_marker" commit "$commit_message_command"
assert_any_deny 'env git commit' "$repo"
[ -e "$commit_marker" ]
assert_any_deny 'PATH=/tmp git commit' "$repo"
[ -e "$commit_marker" ]
assert_any_deny "bash -c 'git commit'" "$repo"
[ -e "$commit_marker" ]
assert_any_deny "git 'commit'" "$repo"
[ -e "$commit_marker" ]

# Wrappers, alternate Git paths, repository context, and command chains are
# never eligible for the exact workaround, even without ECI state.
for commit_variant in \
  "git -C $repo commit" \
  "/usr/bin/git commit" \
  "printf before; git commit"; do
  assert_any_deny "$commit_variant" "$repo"
  [ -e "$commit_marker" ]
done

# A checked-in or staged approval is replayable repository input, not a valid
# user authorization artifact.  It must remain untouched and fail closed.
git -C "$repo" add -- "$commit_marker"
assert_any_deny "$commit_message_command" "$repo"
[ -e "$commit_marker" ]
git -C "$repo" reset -q -- "$commit_marker"

# A fresh claim remains fail-closed; an empty orphaned claim older than the
# bounded recovery window is recoverable exactly once, without a retry loop.
rm -f -- "$commit_marker"
write_approval "$commit_marker" commit "$commit_message_command"
mkdir -- "$commit_marker.claim"
assert_any_deny "$commit_message_command" "$repo"
[ -e "$commit_marker" ]
rmdir -- "$commit_marker.claim"
mkdir -- "$commit_marker.claim"
touch -d '2 hours ago' -- "$commit_marker.claim"
assert_allowed_and_consumed "$commit_message_command" "$commit_marker" "$repo"

# A normal active-ECI direct commit, including ordinary commit options,
# remains review-gated when no approval is present. A valid exact approval
# skips only that acceptance gate once.
rm -f -- "$commit_marker"
normal_active_output="$(run_active_repo_hook "$commit_command")"
jq -e '
  .hookSpecificOutput.permissionDecision == "deny" and
  (.hookSpecificOutput.permissionDecisionReason | contains("ECI commit boundary denied")) and
  (.hookSpecificOutput.permissionDecisionReason | contains("eci-required-critics"))
' "$normal_active_output" >/dev/null
normal_active_message_output="$(run_active_repo_hook "$commit_message_command")"
jq -e '
  .hookSpecificOutput.permissionDecision == "deny" and
  (.hookSpecificOutput.permissionDecisionReason | contains("ECI commit boundary denied"))
' "$normal_active_message_output" >/dev/null

write_approval "$commit_marker" commit "$commit_message_command"
approved_active_output="$(run_active_repo_hook "$commit_message_command")"
[ ! -s "$approved_active_output" ]
[ ! -e "$commit_marker" ]

# Approval is checked only after canonical classification: inherited Git
# context cannot turn UNKNOWN into an allow and cannot consume the marker.
write_approval "$commit_marker" commit "$commit_message_command"
context_output="$(run_active_repo_git_context_hook "$commit_message_command")"
jq -e '
  .hookSpecificOutput.permissionDecision == "deny" and
  (.hookSpecificOutput.permissionDecisionReason | startswith("[ECI_") and contains("phase=") and contains("operation=") and contains("reason:") and contains("remediation:"))
' "$context_output" >/dev/null
[ -e "$commit_marker" ]

# Worker/subagent context remains unable to consume or self-issue the
# coordinator-owned approval, even when the marker content is valid.
write_approval "$commit_marker" commit "$commit_message_command"
worker_output="$(run_worker_hook "$commit_message_command" "$repo")"
jq -e '
  .hookSpecificOutput.permissionDecision == "deny" and
  (.hookSpecificOutput.permissionDecisionReason | contains("[ECI_WORKER_GIT_OWNERSHIP_DENIED]")) and
  (.hookSpecificOutput.permissionDecisionReason | contains("operation=worker-git-ownership")) and
  (.hookSpecificOutput.permissionDecisionReason | contains("token=commit")) and
  (.hookSpecificOutput.permissionDecisionReason | startswith("[ECI_") and contains("phase=") and contains("operation=") and contains("reason:") and contains("remediation:"))
' "$worker_output" >/dev/null
[ -e "$commit_marker" ]

# Existing malformed active ownership and an unsafe proof root are active
# control state, not an inactive discovery result.
malformed_root="$TMP_ROOT/malformed-proof"
mkdir -p "$malformed_root/git-approval-test"
printf '%s\n' \
  'scope: malformed' \
  "cwd: $repo" \
  'session_id: bad!' \
  'created_utc: 2026-08-15T00:00:00Z' \
  >"$malformed_root/git-approval-test/eci_active"
malformed_output="$(run_hook_with_root "$malformed_root" "$repo" git-approval-test 'git status')"
jq -e '
  .hookSpecificOutput.permissionDecision == "deny" and
  (.hookSpecificOutput.permissionDecisionReason | startswith("[ECI_") and contains("phase=") and contains("operation=") and contains("reason:") and contains("remediation:"))
' "$malformed_output" >/dev/null
jq -e '
  .hookSpecificOutput.permissionDecision == "deny" and
  (.hookSpecificOutput.permissionDecisionReason | contains("[ECI_MARKER_OWNERSHIP_INVALID]")) and
  (.hookSpecificOutput.permissionDecisionReason | contains("subject=")) and
  (.hookSpecificOutput.permissionDecisionReason | contains("repair marker ownership"))
' "$malformed_output" >/dev/null

# A malformed marker for a different session is not active for this callback;
# it must remain transparent rather than poisoning unrelated inactive work.
unbound_malformed_root="$TMP_ROOT/unbound-malformed-proof"
mkdir -p "$unbound_malformed_root/other-session"
printf '%s\n' \
  'scope: malformed-unbound' \
  "cwd: $repo" \
  'session_id: bad!' \
  'created_utc: 2026-08-15T00:00:00Z' \
  >"$unbound_malformed_root/other-session/eci_active"
unbound_malformed_output="$(run_hook_with_root "$unbound_malformed_root" "$repo" git-approval-test 'git status')"
[ ! -s "$unbound_malformed_output" ]

unsafe_root="$TMP_ROOT/unsafe-proof-root"
printf '%s\n' unsafe >"$unsafe_root"
unsafe_output="$(run_hook_with_root "$unsafe_root" "$repo" git-approval-test 'git status')"
jq -e '
  .hookSpecificOutput.permissionDecision == "deny" and
  (.hookSpecificOutput.permissionDecisionReason | startswith("[ECI_") and contains("phase=") and contains("operation=") and contains("reason:") and contains("remediation:"))
' "$unsafe_output" >/dev/null

# The worker cannot bootstrap the approval artifact through a shell writer.
worker_issue_output="$(run_worker_hook "printf forged > $commit_marker" "$repo")"
jq -e '
  .hookSpecificOutput.permissionDecision == "deny" and
  (.hookSpecificOutput.permissionDecisionReason | startswith("[ECI_") and contains("phase=") and contains("operation=") and contains("reason:") and contains("remediation:"))
' "$worker_issue_output" >/dev/null
[ -e "$commit_marker" ]

# A stale report/session pair must not be treated as an inactive marker.  The
# CLI reports the active owner and retains it; the validator separately admits
# only the canonical direct coordinator command.
stale_report="$TMP_ROOT/019ff790-0000-7000-8000-000000000001-disengage.md"
printf '%s\n' 'stale report fixture' >"$stale_report"
if (cd "$repo" &&
  CODEX_SESSION_ID=019ff790-0000-7000-8000-000000000001 \
  CODEX_PROOF_ROOT="$active_repo_proof_root" \
  "$ROOT/bin/eci-active" off "$stale_report" >"$TMP_ROOT/stale-off.out" 2>"$TMP_ROOT/stale-off.err"); then
  exit 1
fi
[ -e "$active_repo_proof_root/commit-session/eci_active" ]
grep -Fq 'ECI off session identity mismatch' "$TMP_ROOT/stale-off.err"
grep -Fq "supplied report $stale_report" "$TMP_ROOT/stale-off.err"

printf '%s\n' 'validate-bash git approval tests: PASS'
