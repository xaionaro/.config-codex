#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_ROOT="$(mktemp -d "${CODEX_TMPDIR:-${HOME:?}/tmp}/codex-session-refresh.XXXXXX")"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

run_snapshot() {
  local proof_root="$1"
  local input_source="$2"
  local out="$3"
  local session_id="${4:-t00-session}"

  mkdir -p "$TMP_ROOT/home/tmp" "$proof_root"
  jq -cn \
    --arg session_id "$session_id" \
    --arg source "$input_source" \
    --arg cwd "$ROOT" \
    '{session_id:$session_id, transcript_path:"/tmp/session.jsonl", cwd:$cwd, source:$source}' |
    HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" \
      bash "$ROOT/hooks/session-snapshot.sh" >"$out"
}

write_direct_marker() {
  local proof_root="$1" scope="${2:-refresh test}"
  printf 'scope: %s\ncwd: %s\nsession_id: t00-session\ncreated_utc: 2026-08-14T00:00:00Z\n' "$scope" "$ROOT" >"$proof_root/t00-session/eci_active"
}

test_active_eci_refresh_signal_for_session_start_reminder() {
  local proof_root="$TMP_ROOT/active-proof" out
  mkdir -p "$proof_root/t00-session"
  write_direct_marker "$proof_root"
  out="$TMP_ROOT/active.out"

  run_snapshot "$proof_root" resume "$out"

  jq -e '
    (.hookSpecificOutput.hookEventName == "SessionStart") and
    (.hookSpecificOutput.additionalContext | contains("ECI is active")) and
    (.hookSpecificOutput.additionalContext | contains("ECI refresh signal (not proof of compaction)")) and
    (.hookSpecificOutput.additionalContext | contains("re-read the entire skills/explore-critique-implement/SKILL.md")) and
    (.hookSpecificOutput.additionalContext | contains("re-invoke it before the next decision/tool"))
  ' "$out" >/dev/null
}

test_session_start_rejects_marker_owner_mismatch() {
  local proof_root="$TMP_ROOT/mismatched-owner-proof" out
  mkdir -p "$proof_root/t00-session"
  write_direct_marker "$proof_root" 'mismatched owner must not refresh'
  sed -i 's/^session_id: t00-session$/session_id: t00-other/' "$proof_root/t00-session/eci_active"
  out="$TMP_ROOT/mismatched-owner.out"
  run_snapshot "$proof_root" resume "$out"
  jq -e '.hookSpecificOutput.additionalContext == "Load ~/.codex/CODEX.md and matching ~/.codex/skills when applicable."' "$out" >/dev/null
}

test_nested_eci_refresh_signal_is_explicit() {
  local proof_root="$TMP_ROOT/nested-proof" out
  mkdir -p "$proof_root/t00-session"
  printf 'scope: nested outer\ncwd: %s\nsession_id: t00-session\ncreated_utc: 2026-08-14T00:00:00Z\n' "$ROOT" >"$proof_root/t00-session/eci_active"
  printf 'outer_session_id: t00-session\nouter_marker: %s/eci_active\nowner: ate\nwriter_session_id: t00-session\nacceptance_version: 1\nstep: 4\niteration: 1\nstate: active\n' "$proof_root/t00-session" >"$proof_root/t00-session/ate_nested_eci_active"
  out="$TMP_ROOT/nested.out"
  run_snapshot "$proof_root" resume "$out"
  jq -e '.hookSpecificOutput.additionalContext | contains("ECI is active")' "$out" >/dev/null
  rm -f -- "$proof_root/t00-session/eci_active"
  printf 'outer_session_id: wrong\nouter_marker: %s/eci_active\nowner: ate\nwriter_session_id: t00-session\nacceptance_version: 1\nstep: 4\niteration: 1\nstate: active\n' "$proof_root/t00-session" >"$proof_root/t00-session/ate_nested_eci_active"
  run_snapshot "$proof_root" resume "$out"
  jq -e '.hookSpecificOutput.additionalContext == "Load ~/.codex/CODEX.md and matching ~/.codex/skills when applicable."' "$out" >/dev/null
  printf 'outer_session_id: t00-session\nstep: 4\niteration: 1\n' >"$proof_root/t00-session/ate_nested_eci_active"
  run_snapshot "$proof_root" resume "$out"
  jq -e '.hookSpecificOutput.additionalContext == "Load ~/.codex/CODEX.md and matching ~/.codex/skills when applicable."' "$out" >/dev/null
}

test_inactive_session_keeps_baseline_context() {
  local proof_root="$TMP_ROOT/inactive-proof" out
  out="$TMP_ROOT/inactive.out"

  run_snapshot "$proof_root" startup "$out"

  jq -e '
    (.hookSpecificOutput.additionalContext == "Load ~/.codex/CODEX.md and matching ~/.codex/skills when applicable.")
  ' "$out" >/dev/null
  if jq -e '.hookSpecificOutput.additionalContext | contains("ECI is active")' "$out" >/dev/null; then
    return 1
  fi
}

test_session_start_matcher_uses_supported_lifecycle_sources() {
  jq -e '
    (.hooks.SessionStart | length > 0) and
    (.hooks.SessionStart | all(.matcher == "startup|resume|clear"))
  ' "$ROOT/hooks.json" >/dev/null
}

test_session_start_rejects_malformed_types() {
  local proof_root="$TMP_ROOT/malformed-proof" out
  mkdir -p "$proof_root"
  out="$TMP_ROOT/malformed.out"
  printf '%s\n' '{"session_id":[],"transcript_path":"/tmp/x","cwd":"/tmp"}' |
    HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" bash "$ROOT/hooks/session-snapshot.sh" >"$out"
  [ ! -s "$out" ]
  printf '%s\n' '{"session_id":"t00-session","transcript_path":"/tmp/x","cwd":[]}' |
    HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" bash "$ROOT/hooks/session-snapshot.sh" >"$out"
  [ ! -s "$out" ]
}

test_session_start_rejects_root_and_session_symlinks() {
  local root_link="$TMP_ROOT/root-link" root_target="$TMP_ROOT/root-target" out target
  mkdir -p "$root_target/t00-session" "$TMP_ROOT/home/tmp"
  ln -s "$root_target" "$root_link"
  out="$TMP_ROOT/root-link.out"
  jq -cn '{session_id:"t00-session",transcript_path:"/tmp/x",cwd:"/tmp"}' |
    HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$root_link" bash "$ROOT/hooks/session-snapshot.sh" >"$out"
  [ ! -s "$out" ]

  root_target="$TMP_ROOT/session-link-root"
  target="$TMP_ROOT/session-link-target"
  mkdir -p "$root_target" "$target"
  ln -s "$target" "$root_target/t00-session"
  out="$TMP_ROOT/session-link.out"
  jq -cn '{session_id:"t00-session",transcript_path:"/tmp/x",cwd:"/tmp"}' |
    HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$root_target" bash "$ROOT/hooks/session-snapshot.sh" >"$out"
  [ ! -s "$out" ]
}

test_baseline_uses_fixed_git_and_resolves_head() {
  local proof_root="$TMP_ROOT/poisoned-git-proof" fakebin="$TMP_ROOT/poisoned-git-bin" out baseline expected
  mkdir -p "$proof_root" "$fakebin" "$TMP_ROOT/home/tmp"
  printf '#!/usr/bin/env bash\nprintf poisoned-baseline\\n' >"$fakebin/git"
  chmod +x "$fakebin/git"
  out="$TMP_ROOT/poisoned-git.out"
  jq -cn --arg cwd "$ROOT" '{session_id:"t00-session",transcript_path:"/tmp/x",cwd:$cwd}' |
    HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" GIT_DIR="$TMP_ROOT/poisoned-git-dir" PATH="$fakebin:$PATH" \
      bash "$ROOT/hooks/session-snapshot.sh" >"$out"
  baseline="$proof_root/t00-session/baseline_head"
  expected="$(git -C "$ROOT" rev-parse HEAD)"
  [ "$(cat "$baseline")" = "$expected" ]
  binding="$proof_root/t00-session/baseline_head.binding"
  [ -f "$binding" ] && [ ! -L "$binding" ]
  grep -Fxq 'schema: eci-baseline-binding/v1' "$binding"
  grep -Fxq 'session_id: t00-session' "$binding"
  grep -Fxq "base_oid: $expected" "$binding"
}

test_baseline_pair_recovers_after_publication_boundary() {
  local proof_root="$TMP_ROOT/baseline-recovery-proof" out baseline binding
  mkdir -p "$proof_root" "$TMP_ROOT/home/tmp"
  baseline="$proof_root/t00-session/baseline_head"
  binding="$proof_root/t00-session/baseline_head.binding"
  out="$TMP_ROOT/baseline-recovery.out"

  if jq -cn --arg cwd "$ROOT" '{session_id:"t00-session",transcript_path:"/tmp/session.jsonl",cwd:$cwd}' |
    HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" CODEX_SESSION_SNAPSHOT_FAIL_AFTER=baseline \
      bash "$ROOT/hooks/session-snapshot.sh" >"$out"; then
    return 1
  fi
  [ -f "$baseline" ] && [ ! -L "$baseline" ]
  [ ! -e "$binding" ] && [ ! -L "$binding" ]

  # A retry repairs the missing binding from the validated baseline instead of
  # leaving the review gate wedged on a half-published pair.
  run_snapshot "$proof_root" resume "$out"
  [ -f "$baseline" ] && [ -f "$binding" ]
  grep -Fxq "base_oid: $(cat "$baseline")" "$binding"

  proof_root="$TMP_ROOT/baseline-binding-recovery-proof"
  baseline="$proof_root/t00-session/baseline_head"
  binding="$proof_root/t00-session/baseline_head.binding"
  mkdir -p "$proof_root"
  if jq -cn --arg cwd "$ROOT" '{session_id:"t00-session",transcript_path:"/tmp/session.jsonl",cwd:$cwd}' |
    HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" CODEX_SESSION_SNAPSHOT_FAIL_AFTER=binding \
      bash "$ROOT/hooks/session-snapshot.sh" >"$out"; then
    return 1
  fi
  [ -f "$baseline" ] && [ -f "$binding" ]
  run_snapshot "$proof_root" resume "$out"
  [ -f "$baseline" ] && [ -f "$binding" ]
}

test_worker_cli_lifecycle_mutations_are_main_owned() {
  local proof_root="$TMP_ROOT/worker-lifecycle-proof" session_dir report fingerprint
  session_dir="$proof_root/t00-worker"
  report="$session_dir/disengage.md"
  fingerprint="$(printf '%064d' 1)"
  mkdir -p "$session_dir" "$TMP_ROOT/home/tmp"
  printf '%s\n' '# worker teardown report' >"$report"
  for command in \
    "on worker-scope" \
    "wait $session_dir/eci_user_owned_wait.md" \
    "resume $fingerprint" \
    "off $report"; do
    if CODEX_ROLE=eci-implementer CODEX_PROOF_ROOT="$proof_root" CODEX_SESSION_ID=t00-worker \
      "$ROOT/bin/eci-active" $command >"$TMP_ROOT/worker-lifecycle.out" 2>"$TMP_ROOT/worker-lifecycle.err"; then
      return 1
    fi
    grep -Fq 'main/orchestrator' "$TMP_ROOT/worker-lifecycle.err" || return 1
  done
  [ ! -e "$session_dir/eci_wait" ]
}

test_eci_active_mutations_fail_closed_when_lock_is_busy() {
  local proof_root="$TMP_ROOT/mutation-lock-proof" session_dir report out lock_fd
  session_dir="$proof_root/t00-session"
  report="$session_dir/disengage.md"
  mkdir -p "$session_dir" "$TMP_ROOT/home/tmp"
  printf 'scope: lock test\n' >"$session_dir/eci_active"
  printf '%s\n' '# lock test' >"$report"
  exec {lock_fd}>>"$proof_root/.eci-active.lock"
  flock -n "$lock_fd"

  if CODEX_PROOF_ROOT="$proof_root" CODEX_SESSION_ID=t00-session \
      "$ROOT/bin/eci-active" on 'blocked on' >"$TMP_ROOT/on-lock.out" 2>"$TMP_ROOT/on-lock.err"; then
    return 1
  fi
  if CODEX_PROOF_ROOT="$proof_root" CODEX_SESSION_ID=t00-session \
      "$ROOT/bin/eci-active" wait "$session_dir/eci_user_owned_wait.md" >"$TMP_ROOT/wait-lock.out" 2>"$TMP_ROOT/wait-lock.err"; then
    return 1
  fi
  if CODEX_PROOF_ROOT="$proof_root" CODEX_SESSION_ID=t00-session \
      "$ROOT/bin/eci-active" resume "$(printf '%064d' 1)" >"$TMP_ROOT/resume-lock.out" 2>"$TMP_ROOT/resume-lock.err"; then
    return 1
  fi
  if CODEX_PROOF_ROOT="$proof_root" CODEX_SESSION_ID=t00-session \
      "$ROOT/bin/eci-active" off "$report" >"$TMP_ROOT/off-lock.out" 2>"$TMP_ROOT/off-lock.err"; then
    return 1
  fi
  [ -f "$session_dir/eci_active" ]
  [ ! -e "$session_dir/eci_wait" ]
  flock -u "$lock_fd"
  eval "exec ${lock_fd}>&-"
}

test_session_start_skips_pruning_when_mutation_lock_is_busy() {
  local proof_root="$TMP_ROOT/lock-proof" out old_dir lock_fd
  old_dir="$proof_root/019df400-0000-7000-8000-000000000002"
  mkdir -p "$old_dir"
  printf 'old marker\n' >"$old_dir/eci_active"
  touch -t 202001010000 "$old_dir" "$old_dir/eci_active"
  mkdir -p "$proof_root"
  exec {lock_fd}>>"$proof_root/.eci-active.lock"
  flock -n "$lock_fd"
  out="$TMP_ROOT/lock.out"
  run_snapshot "$proof_root" resume "$out" t00-session
  [ -e "$old_dir/eci_active" ]
  flock -u "$lock_fd"
  eval "exec ${lock_fd}>&-"
}

test_old_uuid_session_with_active_eci_marker_survives_cleanup() {
  local proof_root="$TMP_ROOT/old-uuid-proof" session_dir out
  session_dir="$proof_root/019df400-0000-7000-8000-000000000001"
  mkdir -p "$session_dir"
  printf '%s\n' 'baseline' >"$session_dir/baseline_head"
  printf '%s\n' 'scope: old active session' >"$session_dir/eci_active"
  touch -t 202001010000 "$session_dir" "$session_dir/baseline_head" "$session_dir/eci_active"
  out="$TMP_ROOT/old-uuid.out"

  run_snapshot "$proof_root" compaction "$out" 019df400-0000-7000-8000-000000000001

  [ -s "$session_dir/baseline_head" ] &&
    [ -s "$session_dir/eci_active" ] &&
    grep -q '^scope: old active session$' "$session_dir/eci_active"
}

test_old_marker_dir_with_symlink_eci_marker_is_pruned() {
  local proof_root="$TMP_ROOT/old-symlink-proof" marker_dir target out
  marker_dir="$proof_root/eci/sessions/stale-session"
  target="$TMP_ROOT/stale-eci-target"
  mkdir -p "$marker_dir"
  printf '%s\n' 'scope: stale symlink' >"$target"
  ln -s "$target" "$marker_dir/eci_active"
  touch -t 202001010000 "$marker_dir"
  out="$TMP_ROOT/old-symlink.out"

  run_snapshot "$proof_root" compaction "$out"

  [ ! -e "$marker_dir" ] && [ ! -L "$marker_dir" ] && [ -s "$target" ]
}

test_active_eci_refresh_signal_for_session_start_reminder
test_session_start_rejects_marker_owner_mismatch
test_nested_eci_refresh_signal_is_explicit
test_inactive_session_keeps_baseline_context
test_session_start_matcher_uses_supported_lifecycle_sources
test_session_start_rejects_malformed_types
test_session_start_rejects_root_and_session_symlinks
test_baseline_uses_fixed_git_and_resolves_head
test_baseline_pair_recovers_after_publication_boundary
test_worker_cli_lifecycle_mutations_are_main_owned
test_eci_active_mutations_fail_closed_when_lock_is_busy
test_session_start_skips_pruning_when_mutation_lock_is_busy
test_old_uuid_session_with_active_eci_marker_survives_cleanup
test_old_marker_dir_with_symlink_eci_marker_is_pruned
printf '%s\n' 'session-snapshot refresh tests: PASS'
