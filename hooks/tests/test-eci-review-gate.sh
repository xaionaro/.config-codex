#!/usr/bin/env bash

set -euo pipefail

# These bounded files are synthetic contract fixtures, not reviewer reports;
# no fabricated production evidence is admitted by the runtime gate.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/codex-eci-review-gate.XXXXXX")"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

sha() { sha256sum -- "$1" | awk '{print $1}'; }

build_manifest() {
  local proof_root="$1" kind="$2" e2e_required="${3:-false}"
  local sid="session-$kind" target_id="target-$kind" session_dir diff diff_sha rows='[]'
  local spec role phase spawn report spawn_sha report_sha e2e='' e2e_sha=''

  session_dir="$proof_root/$sid"
  mkdir -p "$session_dir"
  diff="$session_dir/diff.txt"
  printf 'diff for %s\n' "$kind" >"$diff"
  diff_sha="$(sha "$diff")"
  if [ "$e2e_required" = true ]; then
    e2e="$session_dir/e2e.txt"
    printf 'e2e for %s\n' "$kind" >"$e2e"
    e2e_sha="$(sha "$e2e")"
  fi

  for spec in A:postwrite B:postwrite C:prewrite C:postwrite; do
    role="${spec%%:*}"
    phase="${spec#*:}"
    spawn="$session_dir/${role}-${phase}-spawn.txt"
    report="$session_dir/${role}-${phase}-report.txt"
    printf 'spawn %s %s\n' "$role" "$phase" >"$spawn"
    printf 'report %s %s\n' "$role" "$phase" >"$report"
    spawn_sha="$(sha "$spawn")"
    report_sha="$(sha "$report")"
    rows="$(jq -cn \
      --argjson old "$rows" \
      --arg tid "$target_id" --arg kind "$kind" --arg diff "$diff" --arg diff_sha "$diff_sha" \
      --arg role "$role" --arg phase "$phase" --arg child "child-$kind-$role-$phase" \
      --arg spawn "$spawn" --arg spawn_sha "$spawn_sha" --arg report "$report" --arg report_sha "$report_sha" \
      --arg e2e "$e2e" --arg e2e_sha "$e2e_sha" --argjson required "$e2e_required" \
      '$old + [{target_id:$tid,target_kind:$kind,diff_artifact:$diff,diff_sha256:$diff_sha,critic_role:$role,gate_phase:$phase,child_identity:$child,spawn_request_artifact:$spawn,spawn_request_sha256:$spawn_sha,report_artifact:$report,report_sha256:$report_sha,verdict:"PASS",e2e_required:$required,e2e_artifact:(if $required then $e2e else null end),e2e_sha256:(if $required then $e2e_sha else null end)}]')"
  done

  jq -cn \
    --arg tid "$target_id" --arg kind "$kind" --arg diff "$diff" --arg diff_sha "$diff_sha" \
    --argjson required "$e2e_required" --argjson rows "$rows" \
    '{schema:"eci-required-critics/v1",current_target_id:$tid,current_target_kind:$kind,current_diff_artifact:$diff,current_diff_sha256:$diff_sha,targets:[{target_id:$tid,target_kind:$kind,diff_artifact:$diff,diff_sha256:$diff_sha,e2e_required:$required}],rows:$rows}' \
    >"$session_dir/eci-required-critics.json"
  printf '%s\n' "$sid"
}

run_gate() {
  local proof_root="$1" phase="$2" sid="$3" out="$4" err="$5"
  CODEX_PROOF_ROOT="$proof_root" "$ROOT/hooks/eci-review-gate.sh" "$phase" "$sid" >"$out" 2>"$err"
}

assert_reject() {
  local proof_root="$1" sid="$2" needle="$3" out="$TMP_ROOT/gate.out" err="$TMP_ROOT/gate.err"
  if run_gate "$proof_root" final "$sid" "$out" "$err"; then
    printf 'expected rejection: %s\n' "$needle" >&2
    return 1
  fi
  grep -Fq "$needle" "$err"
}

test_valid_target_kinds() {
  local kind proof_root sid
  for kind in root subtask candidate-fix; do
    proof_root="$TMP_ROOT/valid-$kind"
    sid="$(build_manifest "$proof_root" "$kind")"
    if ! run_gate "$proof_root" final "$sid" "$TMP_ROOT/$kind.out" "$TMP_ROOT/$kind.err"; then
      return 1
    fi
    grep -Fq "phase=final" "$TMP_ROOT/$kind.out"
  done
}

test_valid_e2e_binding() {
  local proof_root="$TMP_ROOT/valid-e2e" sid
  sid="$(build_manifest "$proof_root" candidate-fix true)"
  run_gate "$proof_root" final "$sid" "$TMP_ROOT/e2e.out" "$TMP_ROOT/e2e.err"
  grep -Fq 'phase=final' "$TMP_ROOT/e2e.out"
}

test_off_boundary_requires_and_accepts_manifest() {
  local proof_root="$TMP_ROOT/off-boundary" sid session_dir manifest saved
  sid="$(build_manifest "$proof_root" root)"
  session_dir="$proof_root/$sid"
  printf '%s\n' 'scope: off boundary' >"$session_dir/eci_active"
  manifest="$session_dir/eci-required-critics.json"
  saved="$TMP_ROOT/off-boundary-manifest.json"
  cp "$manifest" "$saved"
  rm -f "$manifest"
  if run_gate "$proof_root" off "$sid" "$TMP_ROOT/off-missing.out" "$TMP_ROOT/off-missing.err"; then
    return 1
  fi
  grep -Fq 'missing canonical manifest' "$TMP_ROOT/off-missing.err"
  [ -f "$session_dir/eci_active" ]
  mv "$saved" "$manifest"
  run_gate "$proof_root" off "$sid" "$TMP_ROOT/off-valid.out" "$TMP_ROOT/off-valid.err"
  grep -Fq 'phase=off' "$TMP_ROOT/off-valid.out"
}

test_gate_fails_closed_when_mutation_lock_is_busy() {
  local proof_root="$TMP_ROOT/gate-lock" sid lock_fd
  sid="$(build_manifest "$proof_root" root)"
  exec {lock_fd}>>"$proof_root/.eci-active.lock"
  flock -n "$lock_fd"
  if run_gate "$proof_root" final "$sid" "$TMP_ROOT/gate-lock.out" "$TMP_ROOT/gate-lock.err"; then
    return 1
  fi
  grep -Fq 'mutation lock is busy' "$TMP_ROOT/gate-lock.err"
  flock -u "$lock_fd"
  eval "exec ${lock_fd}>&-"
}

test_missing_each_critic_and_c_phase() {
  local role proof_root="$TMP_ROOT/missing" sid session_dir manifest original
  sid="$(build_manifest "$proof_root" root)"
  session_dir="$proof_root/$sid"
  manifest="$session_dir/eci-required-critics.json"
  original="$TMP_ROOT/original.json"
  cp "$manifest" "$original"
  for role in A B C; do
    jq -c --arg role "$role" '.rows |= map(select(.critic_role != $role))' "$original" >"$manifest"
    assert_reject "$proof_root" "$sid" "Critic $role"
  done
  jq -c '.rows |= map(select(.gate_phase != "prewrite" or .critic_role != "C"))' "$original" >"$manifest"
  assert_reject "$proof_root" "$sid" 'Critic C prewrite'
}

test_stale_hashes() {
  local field proof_root="$TMP_ROOT/stale" sid session_dir manifest original
  sid="$(build_manifest "$proof_root" root)"
  session_dir="$proof_root/$sid"
  manifest="$session_dir/eci-required-critics.json"
  original="$TMP_ROOT/stale-original.json"
  cp "$manifest" "$original"
  for field in diff_sha256 spawn_request_sha256 report_sha256; do
    cp "$original" "$manifest"
    jq -c --arg field "$field" '.rows[0][$field] = ("0" * 64)' "$manifest" >"$manifest.tmp"
    mv "$manifest.tmp" "$manifest"
    assert_reject "$proof_root" "$sid" 'stale'
  done
}

test_duplicate_schema_and_e2e_rejections() {
  local proof_root="$TMP_ROOT/schema" sid session_dir manifest original
  sid="$(build_manifest "$proof_root" root)"
  session_dir="$proof_root/$sid"
  manifest="$session_dir/eci-required-critics.json"
  original="$TMP_ROOT/schema-original.json"
  cp "$manifest" "$original"

  jq -c '.targets += [.targets[0]]' "$original" >"$manifest"
  assert_reject "$proof_root" "$sid" 'duplicate governed target'

  jq -c '.unknown = true' "$original" >"$manifest"
  assert_reject "$proof_root" "$sid" 'manifest header/schema'

  jq -c '{rows:.rows,schema:.schema,current_target_id:.current_target_id,current_target_kind:.current_target_kind,current_diff_artifact:.current_diff_artifact,current_diff_sha256:.current_diff_sha256,targets:.targets}' "$original" >"$manifest"
  assert_reject "$proof_root" "$sid" 'manifest header/schema'

  jq -c '.rows[0].e2e_artifact = "unexpected"' "$original" >"$manifest"
  assert_reject "$proof_root" "$sid" 'target/row schema'
}

test_manifest_is_immutable_after_admission() {
  local proof_root="$TMP_ROOT/immutable" sid session_dir manifest
  sid="$(build_manifest "$proof_root" root)"
  session_dir="$proof_root/$sid"
  manifest="$session_dir/eci-required-critics.json"
  run_gate "$proof_root" final "$sid" "$TMP_ROOT/immutable.out" "$TMP_ROOT/immutable.err"
  jq -c '.rows[0].child_identity = "changed-child"' "$manifest" >"$manifest.tmp"
  mv "$manifest.tmp" "$manifest"
  assert_reject "$proof_root" "$sid" 'changed manifest after admission'
}

test_active_stop_does_not_run_manifest_gate() {
  local proof_root="$TMP_ROOT/stop-fast" sid=stop-fast out
  mkdir -p "$proof_root/$sid"
  printf 'scope: active stop\n' >"$proof_root/$sid/eci_active"
  out="$TMP_ROOT/stop-fast.out"
  jq -cn --arg cwd "$ROOT" --arg sid "$sid" '{session_id:$sid,cwd:$cwd,hook_event_name:"Stop",stop_hook_active:false}' |
    CODEX_PROOF_ROOT="$proof_root" bash "$ROOT/hooks/stop-gate.sh" >"$out"
  jq -e '.decision == "block" and (.reason | contains("ECI"))' "$out" >/dev/null
}

test_main_commit_boundary_requires_manifest() {
  local proof_root="$TMP_ROOT/commit-gate" sid=commit-session out
  mkdir -p "$proof_root/$sid" "$TMP_ROOT/home"
  printf 'scope: commit gate\n' >"$proof_root/$sid/eci_active"
  out="$TMP_ROOT/commit-gate.out"
  jq -cn --arg cwd "$ROOT" --arg sid "$sid" \
    '{session_id:$sid,cwd:$cwd,tool_input:{command:"git commit -m checked"}}' |
    HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" \
      bash "$ROOT/hooks/validate-bash.sh" >"$out"
  jq -e '
    (.hookSpecificOutput.permissionDecision == "deny") and
    (.hookSpecificOutput.permissionDecisionReason | contains("commit boundary denied")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("manifest"))
  ' "$out" >/dev/null
}

test_root_and_session_symlink_fail_closed() {
  local parent="$TMP_ROOT/symlink-parent" root="$TMP_ROOT/symlink-root" sid=symlink-session target="$TMP_ROOT/target"
  mkdir -p "$parent/$sid" "$target"
  ln -s "$parent" "$root"
  if CODEX_PROOF_ROOT="$root" "$ROOT/hooks/eci-review-gate.sh" final "$sid" >"$TMP_ROOT/symlink-root.out" 2>"$TMP_ROOT/symlink-root.err"; then
    return 1
  fi
  root="$TMP_ROOT/regular-root"
  mkdir -p "$root/$sid" "$target"
  rm -rf "$root/$sid"
  ln -s "$target" "$root/$sid"
  if CODEX_PROOF_ROOT="$root" "$ROOT/hooks/eci-review-gate.sh" final "$sid" >"$TMP_ROOT/symlink-session.out" 2>"$TMP_ROOT/symlink-session.err"; then
    return 1
  fi
}

test_valid_target_kinds
test_valid_e2e_binding
test_off_boundary_requires_and_accepts_manifest
test_gate_fails_closed_when_mutation_lock_is_busy
test_missing_each_critic_and_c_phase
test_stale_hashes
test_duplicate_schema_and_e2e_rejections
test_manifest_is_immutable_after_admission
test_active_stop_does_not_run_manifest_gate
test_main_commit_boundary_requires_manifest
test_root_and_session_symlink_fail_closed
printf '%s\n' 'ECI required-critic review gate tests: PASS'
