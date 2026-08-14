#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/codex-post-compact-refresh.XXXXXX")"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

run_post_compact() {
  local proof_root="$1"
  local out="$2"

  mkdir -p "$TMP_ROOT/home/tmp" "$proof_root"
  jq -cn --arg cwd "$ROOT" \
    '{hook_event_name:"PostCompact", session_id:"t00-session", cwd:$cwd, source:"compaction"}' |
    HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" \
      bash "$ROOT/hooks/eci-post-compact-refresh.sh" >"$out"
}

test_post_compact_active_eci_refresh_signal() {
  local proof_root="$TMP_ROOT/active-proof" out
  mkdir -p "$proof_root/t00-session"
  printf '%s\n' 'scope: post compact test' >"$proof_root/t00-session/eci_active"
  out="$TMP_ROOT/active.out"

  run_post_compact "$proof_root" "$out"

  jq -e '
    (.hookSpecificOutput.hookEventName == "PostCompact") and
    (.hookSpecificOutput.additionalContext | contains("PostCompact ECI refresh signal")) and
    (.hookSpecificOutput.additionalContext | contains("ECI is active")) and
    (.hookSpecificOutput.additionalContext | contains("re-read the entire skills/explore-critique-implement/SKILL.md")) and
    (.hookSpecificOutput.additionalContext | contains("re-invoke it before the next decision/tool"))
  ' "$out" >/dev/null
}

test_post_compact_inactive_eci_is_silent() {
  local proof_root="$TMP_ROOT/inactive-proof" out
  out="$TMP_ROOT/inactive.out"

  run_post_compact "$proof_root" "$out"

  [ ! -s "$out" ]
}

test_post_compact_symlink_marker_is_silent() {
  local proof_root="$TMP_ROOT/symlink-proof" out target
  target="$TMP_ROOT/eci-target"
  mkdir -p "$proof_root/t00-session"
  printf '%s\n' 'scope: symlink marker must not activate refresh' >"$target"
  ln -s "$target" "$proof_root/t00-session/eci_active"
  out="$TMP_ROOT/symlink.out"

  run_post_compact "$proof_root" "$out"

  [ ! -s "$out" ]
}

test_post_compact_does_not_scan_or_mutate_state() {
  local proof_root="$TMP_ROOT/no-write-proof" out before after
  mkdir -p "$proof_root/t00-session"
  printf '%s\n' 'scope: no-write test' >"$proof_root/t00-session/eci_active"
  before="$(find "$proof_root" -mindepth 1 -maxdepth 2 -printf '%P:%y:%s\n' | sort)"
  out="$TMP_ROOT/no-write.out"

  run_post_compact "$proof_root" "$out"

  after="$(find "$proof_root" -mindepth 1 -maxdepth 2 -printf '%P:%y:%s\n' | sort)"
  [ "$before" = "$after" ] || return 1
  if grep -Eq '(^|[[:space:]])(find|mkdir|rm|sleep|timeout|date)([[:space:]]|$)' \
      "$ROOT/hooks/eci-post-compact-refresh.sh"; then
    return 1
  fi
  if grep -Fq 'transcript' "$ROOT/hooks/eci-post-compact-refresh.sh"; then
    return 1
  fi
}

test_post_compact_rejects_malformed_session_or_cwd() {
  local proof_root="$TMP_ROOT/malformed-proof" out
  mkdir -p "$proof_root/t00-session"
  printf '%s\n' 'scope: malformed input must not refresh' >"$proof_root/t00-session/eci_active"
  out="$TMP_ROOT/malformed.out"
  printf '%s\n' '{"session_id":"t00-session","cwd":[],"source":"compaction"}' |
    HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" \
      bash "$ROOT/hooks/eci-post-compact-refresh.sh" >"$out"
  [ ! -s "$out" ]
}

test_post_compact_hook_is_registered_and_session_start_is_restricted() {
  jq -e '
    (.hooks.SessionStart | all(.matcher == "startup|resume|clear")) and
    ([.hooks.PostCompact[]?.hooks[]?.command]
      | any(contains("/hooks/eci-post-compact-refresh.sh")))
  ' "$ROOT/hooks.json" >/dev/null
}

test_policy_names_post_compact_authority_and_exact_manifest_schema() {
  local skill
  for skill in \
    "$ROOT/skills/explore-critique-implement/SKILL.md" \
    "$ROOT/skills/agent-teams-execution/SKILL.md"; do
    grep -Fq 'PostCompact` is the authoritative compaction refresh signal' "$skill"
    grep -Fq 'SessionStart` `startup|resume|clear`' "$skill"
    grep -Fq 'best-effort resume/clear reminder' "$skill"
    grep -Fq '"target_id":string,"target_kind":"root|subtask|candidate-fix"' "$skill"
    grep -Fq '"diff_artifact":string,"diff_sha256":lowercase64hex,"critic_role":"A|B|C","child_identity":string' "$skill"
    grep -Fq '"spawn_request_artifact":string,"spawn_request_sha256":lowercase64hex,"report_artifact":string,"report_sha256":lowercase64hex' "$skill"
    grep -Fq '"verdict":string,"e2e_required":boolean,"e2e_artifact":string|null,"e2e_sha256":lowercase64hex|null' "$skill"
    grep -Fq 'Critic C pre-write skip-design admission report' "$skill"
    grep -Fq 'Critic C post-write reconciliation report' "$skill"
    grep -Fq '`target-scoped-critic-ledger-row`' "$skill"
    grep -Fq '`critic-c-prewrite-postwrite`' "$skill"
    grep -Fq '`postcompact-refresh-signal`' "$skill"
    if grep -Fq 'There is no dedicated compaction hook' "$skill"; then
      return 1
    fi
  done
  if grep -Fq 'both execution-review lenses' "$ROOT/skills/agent-teams-execution/SKILL.md"; then
    return 1
  fi
}

test_post_compact_active_eci_refresh_signal
test_post_compact_inactive_eci_is_silent
test_post_compact_symlink_marker_is_silent
test_post_compact_does_not_scan_or_mutate_state
test_post_compact_rejects_malformed_session_or_cwd
test_post_compact_hook_is_registered_and_session_start_is_restricted
test_policy_names_post_compact_authority_and_exact_manifest_schema
printf '%s\n' 'PostCompact ECI refresh tests: PASS'
