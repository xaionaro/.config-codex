#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_ROOT="$(mktemp -d "/tmp/codex-eci-edit-controls.XXXXXX")"
proof_root="$ROOT/.eci-edit-control-proof-$BASHPID"
repo_hardlink_alias="$(pwd)/.eci-active-hardlink-alias-$BASHPID"
ledger_hardlink_alias="$ROOT/.latest-status-report-hardlink-alias-$BASHPID"
trap 'rm -rf -- "$TMP_ROOT" "$proof_root" "$repo_hardlink_alias" "$ledger_hardlink_alias"' EXIT

home="$TMP_ROOT/home"
codex_home="$TMP_ROOT/codex-home"
sid=t00-session
mkdir -p "$proof_root/$sid" "$proof_root/pre-reviewer" "$proof_root/reviewer" "$home" "$codex_home/sessions"
printf '%s\n' \
  'scope: edit control test' \
  "cwd: $ROOT" \
  "session_id: $sid" \
  'created_utc: 2026-08-15T00:00:00Z' \
  >"$proof_root/$sid/eci_active"
transcript="$codex_home/sessions/codex-edit-control-test.jsonl"
printf '%s\n' '{"timestamp":"2026-08-15T00:00:00.000Z","type":"session_meta","payload":{"id":"t00-session","source":{"subagent":{"thread_spawn":{"parent_thread_id":"parent-session","depth":1,"agent_nickname":"Test","agent_role":"default"}}}}}' >"$transcript"

run_bash_worker() {
  local command="$1" expected_code="${2:-ECI_WORKER_CONTROL_READ_DENIED}" out="$TMP_ROOT/bash-worker.out"
  jq -cn --arg command "$command" --arg cwd "$ROOT" --arg transcript "$transcript" \
    '{session_id:"t00-session",cwd:$cwd,transcript_path:$transcript,tool_input:{command:$command}}' |
    CODEX_PROOF_ROOT="$proof_root" CODEX_HOME="$codex_home" HOME="$home" \
      bash "$ROOT/hooks/validate-bash.sh" >"$out"
  jq -e --arg expected "$expected_code" --arg command "$command" '
    .hookSpecificOutput.permissionDecision == "deny" and
    (.hookSpecificOutput.permissionDecisionReason | contains($expected)) and
    (if $expected == "ECI_WORKER_CONTROL_READ_DENIED" then
      (.hookSpecificOutput.permissionDecisionReason | contains("operation=worker-control-read")) and
      (.hookSpecificOutput.permissionDecisionReason | contains("token=")) and
      (.hookSpecificOutput.permissionDecisionReason | contains("resolved=")) and
      (.hookSpecificOutput.permissionDecisionReason | contains("route=coordinator-inspection-route"))
    else true end)
  ' "$out" >/dev/null
}

run_bash_coordinator() {
  local command="$1" out="$TMP_ROOT/bash-coordinator.out"
  jq -cn --arg command "$command" --arg cwd "$ROOT" \
    '{session_id:"t00-session",cwd:$cwd,tool_input:{command:$command}}' |
    CODEX_PROOF_ROOT="$proof_root" CODEX_HOME="$ROOT" HOME="$home" \
      bash "$ROOT/hooks/validate-bash.sh" >"$out"
  [ ! -s "$out" ]
}

run_edit() {
  local path="$1" out="$TMP_ROOT/edit.out"
  jq -cn --arg path "$path" --arg cwd "$ROOT" --arg transcript "$transcript" \
    '{tool_name:"Write",session_id:"t00-session",cwd:$cwd,transcript_path:$transcript,tool_input:{file_path:$path,content:"forged"}}' |
    CODEX_PROOF_ROOT="$proof_root" CODEX_HOME="$codex_home" HOME="$home" \
      bash "$ROOT/hooks/validate-edit-write.sh" >"$out"
  jq -e '.hookSpecificOutput.permissionDecision == "deny"' "$out" >/dev/null
}

run_patch() {
  local path="$1" out="$TMP_ROOT/patch.out" patch_text
  patch_text="*** Begin Patch
*** Update File: $path
-old
+forged
*** End Patch"
  jq -cn --arg patch "$patch_text" --arg cwd "$ROOT" --arg transcript "$transcript" \
    '{session_id:"t00-session",cwd:$cwd,transcript_path:$transcript,tool_input:{command:$patch}}' |
    CODEX_PROOF_ROOT="$proof_root" CODEX_HOME="$codex_home" HOME="$home" \
      bash "$ROOT/hooks/validate-apply-patch.sh" >"$out"
  jq -e '.hookSpecificOutput.permissionDecision == "deny"' "$out" >/dev/null
}

run_main_disengage_edit() {
  local path="$1" out="$TMP_ROOT/main-edit.out"
  jq -cn --arg path "$path" --arg cwd "$ROOT" \
    '{tool_name:"Write",session_id:"t00-session",cwd:$cwd,tool_input:{file_path:$path,content:"user-closed teardown report"}}' |
    CODEX_PROOF_ROOT="$proof_root" CODEX_HOME="$ROOT" HOME="$home" \
      bash "$ROOT/hooks/validate-edit-write.sh" >"$out"
  [ ! -s "$out" ]
}

run_edit "$proof_root/pre-reviewer/legacy-state"
run_edit "$proof_root/pre-reviewer/archive/legacy-state"
run_edit "$proof_root/reviewer/legacy-state"
run_edit "$proof_root/reviewer/archive/legacy-state"
run_edit "$proof_root/t00-session/eci_active"
run_patch "$proof_root/pre-reviewer/legacy-state"
run_main_disengage_edit "$proof_root/$sid/user-closed.md"
run_main_disengage_edit "$proof_root/$sid/disengage.md"

# Control names that are easy to miss must remain coordinator-owned even
# before publication.  An outside-root hardlink alias must be denied as well:
# lexical/resolved path checks alone cannot distinguish it from an ordinary
# repository file.
for control_name in goal_state proof.md instructions.md stop_timestamps stop_loop_state \
  eci-required-critics.json project-understanding.md high_level_log.md \
  latest-status-report.md high_level_log.anchor; do
  run_edit "$proof_root/$sid/$control_name"
  run_patch "$proof_root/$sid/$control_name"
done

# Read-only commands still cannot inspect coordinator control state from a
# worker transcript.  Keep the coordinator route positive for the same paths.
for command in \
  "cat $proof_root/$sid/eci_active" \
  "sed -n '1p' $proof_root/$sid/eci_active"; do
  run_bash_worker "$command"
  run_bash_coordinator "$command"
done

ln "$proof_root/$sid/eci_active" "$repo_hardlink_alias"
run_edit "$repo_hardlink_alias"
run_patch "$repo_hardlink_alias"
for command in \
  "cat $repo_hardlink_alias" \
  "sed -n '1p' $repo_hardlink_alias"; do
  run_bash_worker "$command"
done

printf '%s\n' 'coordinator ledger' >"$proof_root/$sid/latest-status-report.md"
ln "$proof_root/$sid/latest-status-report.md" "$ledger_hardlink_alias"
run_edit "$ledger_hardlink_alias"
run_patch "$ledger_hardlink_alias"
for command in \
  "cat $ledger_hardlink_alias" \
  "sed -n '1p' $ledger_hardlink_alias"; do
  run_bash_worker "$command"
done

# Atomic publication uses temporary siblings; those names are coordinator
# state too, even when the final artifact has not yet been created.
for temp_path in \
  "$proof_root/$sid/eci_active.tmp.123" \
  "$proof_root/$sid/eci_wait.tmp.123" \
  "$proof_root/$sid/eci-required-critics.json.tmp.123" \
  "$proof_root/$sid/eci-acceptance-anchor.tmp.123" \
  "$proof_root/$sid/eci-acceptance-transaction.tmp.123" \
  "$proof_root/$sid/eci-teardown-complete.tmp.123" \
  "$proof_root/$sid/high_level_log.anchor.tmp.123" \
  "$proof_root/$sid/high_level_log.md.tmp.123"; do
  run_edit "$temp_path"
  run_patch "$temp_path"
done

alias_session="$TMP_ROOT/alias-session"
ln -s "$proof_root/$sid" "$alias_session"
run_edit "$alias_session/eci_active"

printf '%s\n' 'edit control path assertions: PASS'
