#!/usr/bin/env bash

set -Eeuo pipefail
trap 'status=$?; printf "protected Git target test failure: line=%s status=%s command=%q\n" "$LINENO" "$status" "$BASH_COMMAND" >&2' ERR

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/eci-protected-git-target.XXXXXX")"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

fixture_root="$TMP_ROOT/home/.codex"
mkdir -p -- "$fixture_root/hooks"
cp -- "$ROOT/hooks/validate-bash.sh" "$fixture_root/hooks/validate-bash.sh"
sed -i '2{/^exit 0$/d;}' -- "$fixture_root/hooks/validate-bash.sh"
ln -s -- "$ROOT/hooks/lib" "$fixture_root/hooks/lib"
ln -s -- "$ROOT/bin" "$fixture_root/bin"

proof_root="$TMP_ROOT/proof"
session_dir="$proof_root/t00-session"
mkdir -p -- "$session_dir/evidence"
printf '%s\n' \
  'scope: coordinator protected Git target test' \
  "cwd: $ROOT" \
  'session_id: t00-session' \
  'created_utc: 2026-09-13T00:00:00Z' \
  >"$session_dir/eci_active"
printf '%s\n' '# protected Git target test' >"$session_dir/high_level_log.md"
printf '%s\n' '# test instructions' >"$session_dir/instructions.md"

hooks_session='t01-hooks-session'
hooks_cwd="$ROOT/hooks"
hooks_session_dir="$proof_root/$hooks_session"
mkdir -p -- "$hooks_session_dir/evidence"
printf '%s\n' \
  'scope: coordinator protected Git target test' \
  "cwd: $hooks_cwd" \
  "session_id: $hooks_session" \
  'created_utc: 2026-09-13T00:00:00Z' \
  >"$hooks_session_dir/eci_active"
printf '%s\n' '# protected Git target test' >"$hooks_session_dir/high_level_log.md"
printf '%s\n' '# test instructions' >"$hooks_session_dir/instructions.md"

run_hook() {
  run_hook_at t00-session "$ROOT" "$1" "$2"
}

run_hook_at() {
  local session="$1" hook_cwd="$2" command="$3" output="$4"
  jq -cn --arg session "$session" --arg cwd "$hook_cwd" --arg command "$command" \
    '{session_id:$session,cwd:$cwd,tool_input:{command:$command}}' |
    HOME="${HOME:?}" CODEX_SESSION_ID="$session" CODEX_ROLE=coordinator \
    CODEX_PROOF_ROOT="$proof_root" CODEX_HOME="$ROOT" \
    KIMI_CODE_HOME="${KIMI_CODE_HOME:-$HOME/.kimi-code}" PATH="$ROOT/bin:$PATH" \
      bash "$fixture_root/hooks/validate-bash.sh" >"$output"
}

assert_protected_denial() {
  local command="$1" output="$TMP_ROOT/denial.json"
  run_hook "$command" "$output"
  jq -e '
    .hookSpecificOutput.permissionDecision == "deny" and
    (.hookSpecificOutput.permissionDecisionReason | contains("[ECI_COORDINATOR_EDIT_ROUTING_REQUIRED]")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("operation=edit-routing")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("predicate=coordinator-protected-target")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("target=")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("reason:")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("remediation:"))
  ' "$output" >/dev/null || {
    printf 'protected target was not denied: command=%q\n' "$command" >&2
    cat -- "$output" >&2
    return 1
  }
}

assert_protected_denial_at() {
  local hook_cwd="$1" command="$2" output="$TMP_ROOT/denial-at.json"
  run_hook_at "$hooks_session" "$hook_cwd" "$command" "$output"
  jq -e '
    .hookSpecificOutput.permissionDecision == "deny" and
    (.hookSpecificOutput.permissionDecisionReason | contains("[ECI_COORDINATOR_EDIT_ROUTING_REQUIRED]")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("operation=edit-routing")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("predicate=coordinator-protected-target")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("target=")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("reason:")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("remediation:"))
  ' "$output" >/dev/null || {
    printf 'protected target was not denied at cwd: cwd=%q command=%q\n' "$hook_cwd" "$command" >&2
    cat -- "$output" >&2
    return 1
  }
}

assert_allowed() {
  local command="$1" output="$TMP_ROOT/allowed.json"
  run_hook "$command" "$output"
  [ ! -s "$output" ] || {
    printf 'transparent or ordinary Git target was denied: command=%q\n' "$command" >&2
    cat -- "$output" >&2
    return 1
  }
}

assert_protected_denial 'git rm -- hooks/validate-bash.sh'
assert_protected_denial 'git rm -r -- hooks/validate-bash.sh'
assert_protected_denial 'git rm -r -- hooks'
assert_protected_denial 'git rm -r -- .'
assert_protected_denial 'git mv -- hooks/validate-bash.sh hooks/renamed-hook.sh'
assert_protected_denial 'git mv -- hooks hooks-renamed'
assert_protected_denial 'env git rm -- hooks/validate-bash.sh'
assert_protected_denial 'command git rm -- hooks/validate-bash.sh'
assert_protected_denial 'timeout 10 git rm -- hooks/validate-bash.sh'
assert_protected_denial 'nice -n 5 git rm -- hooks/validate-bash.sh'
assert_protected_denial 'git rm -- :/hooks/validate-bash.sh'
assert_protected_denial "git rm -- ':(top)hooks/validate-bash.sh'"
assert_protected_denial 'git rm -r -- :/'
assert_protected_denial "git rm -r -- ':(top)'"
assert_protected_denial 'git rm -- hooks/../hooks/validate-bash.sh'
assert_protected_denial 'timeout 10 env FOO=bar command git rm -- hooks/validate-bash.sh'
assert_protected_denial 'env timeout 10 command git rm -- hooks/validate-bash.sh'
assert_protected_denial 'if git rm -- hooks/validate-bash.sh; then true; fi'
assert_protected_denial 'git rm -- hooks/validate-bash.sh > /tmp/eci-protected-target-test.log'
assert_protected_denial 'git restore -- hooks/validate-bash.sh'
assert_protected_denial 'git restore --source=HEAD -- hooks/validate-bash.sh'
assert_protected_denial 'git restore --source HEAD -- hooks/validate-bash.sh'
assert_protected_denial 'git checkout HEAD -- hooks/validate-bash.sh'
assert_protected_denial 'git checkout -- hooks/validate-bash.sh'
assert_protected_denial_at "$hooks_cwd" 'git -C .. rm -- hooks/validate-bash.sh'
assert_protected_denial_at "$hooks_cwd" 'env -C .. git rm -- hooks/validate-bash.sh'
assert_protected_denial_at "$hooks_cwd" 'sudo -C .. git rm -- hooks/validate-bash.sh'
assert_allowed 'git rm --cached -- hooks/validate-bash.sh'
assert_allowed 'git rm -n -- hooks/validate-bash.sh'
assert_allowed 'git rm --dry-run -- hooks/validate-bash.sh'
assert_allowed 'git restore --staged -- hooks/validate-bash.sh'
assert_allowed 'git checkout -- hooks/does-not-exist'
assert_allowed 'git rm -- hooks'
assert_allowed 'git rm -- hooks/does-not-exist'
assert_allowed 'git rm -- hooks/alias-to-validate.sh'
assert_allowed 'git rm -- hooks/tests/test-coordinator-protected-git-target.sh'
assert_allowed 'git mv -- hooks/validate-bash.sh hooks/validate-bash.sh'
assert_allowed 'git mv -- hooks/validate-bash.sh ../outside'

printf '%s\n' 'coordinator protected Git target contract: PASS'
