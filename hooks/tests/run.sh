#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
FIXTURES="$ROOT/hooks/tests/fixtures"
TMP_ROOT=""
if ! TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/codex-hooks-tests.XXXXXX")"; then
  printf '%s\n' "FAIL setup could not create temporary test root"
  exit 1
fi

PASS_COUNT=0
FAIL_COUNT=0
XFAIL_COUNT=0
XPASS_COUNT=0
TODO_COUNT=0

cleanup() {
  if [ -n "${TMP_ROOT:-}" ] && [ -d "$TMP_ROOT" ]; then
    rm -f "$(subagent_transcript_path 2>/dev/null || true)" 2>/dev/null || true
    rm -rf "$TMP_ROOT"
  fi
}

trap cleanup EXIT

note() {
  printf '%s\n' "$*"
}

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  note "PASS $1"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  note "FAIL $1"
  if [ "${2:-}" ]; then
    note "     $2"
  fi
}

xfail() {
  XFAIL_COUNT=$((XFAIL_COUNT + 1))
  note "XFAIL $1"
}

xpass() {
  XPASS_COUNT=$((XPASS_COUNT + 1))
  note "XPASS $1"
  if [ "${2:-}" ]; then
    note "      $2"
  fi
}

todo() {
  TODO_COUNT=$((TODO_COUNT + 1))
  note "TODO $1"
}

run_case() {
  local name="$1"
  shift
  if "$@"; then
    pass "$name"
  else
    fail "$name"
  fi
}

run_xfail() {
  local name="$1"
  local future_check="$2"
  local current_bad_check="$3"
  shift
  shift
  shift
  if "$future_check" "$@"; then
    xpass "$name" "expected failure passed; flip this case to PASS in this runner"
  elif "$current_bad_check" "$@"; then
    xfail "$name"
  else
    fail "$name" "unexpected failure mode; not counted as XFAIL"
  fi
}

json_field_equals() {
  local file="$1"
  local expr="$2"
  local want="$3"
  local got
  got="$(jq -r "$expr" "$file" 2>/dev/null || true)"
  [ "$got" = "$want" ]
}

json_field_contains() {
  local file="$1"
  local expr="$2"
  local needle="$3"
  local got
  got="$(jq -r "$expr" "$file" 2>/dev/null || true)"
  case "$got" in
    *"$needle"*) return 0 ;;
    *) return 1 ;;
  esac
}

run_hook() {
  local outfile="$1"
  local script="$2"
  local fixture="$3"
  shift 3
  env -u CODEX_ROLE "$@" bash "$script" <"$fixture" >"$outfile" 2>"$outfile.err"
}

is_pretool_deny() {
  json_field_equals "$1" '.hookSpecificOutput.permissionDecision // empty' "deny"
}

is_stop_block() {
  json_field_equals "$1" '.decision // empty' "block"
}

expect_no_output() {
  [ ! -s "$1" ]
}

fresh_proof_root() {
  local root="$TMP_ROOT/proof-$1"
  rm -rf "$root"
  mkdir -p "$root" || return 1
  printf '%s\n' "$root"
}

subagent_transcript_path() {
  printf '%s/home/.codex/sessions/codex-hooks-test-subagent.jsonl\n' "$TMP_ROOT"
}

with_cwd_fixture() {
  local src="$1"
  local dst="$2"
  jq --arg cwd "$ROOT" '.cwd = $cwd' "$src" >"$dst"
}

with_cwd_path() {
  local src="$1"
  local dst="$2"
  local cwd="$3"
  jq --arg cwd "$cwd" '.cwd = $cwd' "$src" >"$dst"
}

make_git_repo() {
  local name="$1"
  local repo="$TMP_ROOT/git-$name"
  mkdir -p "$repo" || return 1
  git -C "$repo" init -q || return 1
  git -C "$repo" config user.email "hooks-test@example.invalid" || return 1
  git -C "$repo" config user.name "Hooks Test" || return 1
  printf 'base\n' >"$repo/file.txt"
  git -C "$repo" add file.txt || return 1
  git -C "$repo" commit -qm "initial" || return 1
  printf '%s\n' "$repo"
}

test_prompt_state_is_silent_records_head_and_clears_bypass() {
  local proof_root out expected
  proof_root="$(fresh_proof_root prompt-head)"
  mkdir -p "$proof_root/reviewer/t00-session" "$proof_root/pre-reviewer/t00-session"
  touch "$proof_root/reviewer/t00-session/bypass" "$proof_root/pre-reviewer/t00-session/bypass"
  expected="$(git -C "$ROOT" rev-parse HEAD)"
  out="$TMP_ROOT/prompt-head.out"

  run_hook "$out" "$ROOT/hooks/prompt-task-reminder.sh" "$FIXTURES/user-prompt-submit.json" \
    CODEX_PROOF_ROOT="$proof_root" || return 1

  expect_no_output "$out" &&
    [ "$(cat "$proof_root/reviewer/t00-session/prompt_head" 2>/dev/null || true)" = "$expected" ] &&
    [ ! -e "$proof_root/reviewer/t00-session/bypass" ] &&
    [ ! -e "$proof_root/pre-reviewer/t00-session/bypass" ]
}

test_prompt_state_marks_side_prompt() {
  local proof_root out marker
  proof_root="$(fresh_proof_root prompt-side)"
  out="$TMP_ROOT/prompt-side.out"

  run_hook "$out" "$ROOT/hooks/prompt-task-reminder.sh" "$FIXTURES/user-prompt-side.json" \
    CODEX_PROOF_ROOT="$proof_root" || return 1

  marker="$proof_root/side-stop/sessions/t00-session/side_stop"
  expect_no_output "$out" &&
    [ -f "$marker" ] &&
    grep -q '^command: /side$' "$marker"
}

test_prompt_state_skips_state_for_invalid_session() {
  local proof_root out
  proof_root="$(fresh_proof_root prompt-invalid)"
  out="$TMP_ROOT/prompt-invalid.out"

  run_hook "$out" "$ROOT/hooks/prompt-task-reminder.sh" "$FIXTURES/user-prompt-invalid-session.json" \
    CODEX_PROOF_ROOT="$proof_root" || return 1

  expect_no_output "$out" &&
    [ ! -e "$proof_root/reviewer/../bad/prompt_head" ] &&
    [ "$(find "$proof_root/reviewer" -name prompt_head 2>/dev/null | wc -l)" -eq 0 ]
}

test_prompt_state_config_is_wired_without_probe() {
  jq -e '
    ([.hooks.UserPromptSubmit[]?.hooks[]?.command]
      | any(. == "/home/streaming/.codex/hooks/prompt-task-reminder.sh")) and
    ([.hooks.PostToolUse[]?.hooks[]?.command] | length == 0) and
    ([.. | objects | .command? // empty]
      | all(contains("/hooks/tests/hook-event-probe.sh") | not))
  ' "$ROOT/hooks.json" >/dev/null
}

test_stop_gate_allows_side_prompt_before_eci_state() {
  local proof_root prompt_out input out
  proof_root="$(fresh_proof_root stop-side-eci)"
  prompt_out="$TMP_ROOT/stop-side-prompt.out"

  run_hook "$prompt_out" "$ROOT/hooks/prompt-task-reminder.sh" "$FIXTURES/user-prompt-side.json" \
    CODEX_PROOF_ROOT="$proof_root" || return 1
  CODEX_SESSION_ID=t00-session CODEX_PROOF_ROOT="$proof_root" "$ROOT/bin/eci-active" on "test scope" >"$TMP_ROOT/stop-side-eci-on.out" 2>&1 || return 1

  input="$TMP_ROOT/stop-side-eci.json"
  with_cwd_fixture "$FIXTURES/stop-basic.json" "$input"
  out="$TMP_ROOT/stop-side-eci.out"

  run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$input" CODEX_PROOF_ROOT="$proof_root" || return 1
  json_field_equals "$out" '.continue // false' "true"
}

test_runtime_hook_probe_evidence_is_sanitized_and_wired() {
  jq -e -s '
    length == 2 and
    all(type == "object") and
    all(keys_unsorted | all(IN("hook_event_name", "session_id", "cwd", "tool_name", "tool_input_keys", "observed"))) and
    any(
      .hook_event_name == "UserPromptSubmit" and
      .cwd == "/home/streaming/.codex" and
      (.session_id | test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"))
    ) and
    any(
      .hook_event_name == "PostToolUse" and
      .tool_name == "Bash" and
      (.tool_input_keys | type == "array" and index("command") != null)
    ) and
    ([
      paths(scalars) as $p
      | {
          key: ($p[-1] | tostring),
          value: (getpath($p) | tostring)
        }
      | select(
          (.key | test("(?i)(password|passwd|secret|token|api[_-]?key|access[_-]?key|credential|auth|bearer|cookie|private[_-]?key)")) or
          (.value | test("(?i)(sk-[A-Za-z0-9]|ghp_|xox[baprs]-|AKIA[0-9A-Z]{16}|BEGIN (RSA |OPENSSH |DSA |EC |)PRIVATE KEY|Bearer[[:space:]]+[A-Za-z0-9._=-]+|password|passwd|secret|token|api[_-]?key|access[_-]?key|credential|cookie)"))
        )
    ] | length == 0)
  ' "$FIXTURES/runtime-hook-probe-evidence.jsonl" >/dev/null
}

test_session_snapshot_saves_baseline_and_clears_legacy_skip() {
  local proof_root out
  proof_root="$(fresh_proof_root session)"
  mkdir -p "$proof_root/t00-session"
  touch "$proof_root/t00-session/skip_stop"
  CODEX_SESSION_ID=t00-session CODEX_PROOF_ROOT="$proof_root" "$ROOT/bin/skip-stop" on >/dev/null 2>&1 || return 1
  env -u CODEX_SESSION_ID CODEX_PROOF_ROOT="$proof_root" "$ROOT/bin/skip-stop" on >/dev/null 2>&1 || return 1
  out="$TMP_ROOT/session-snapshot.out"

  run_hook "$out" "$ROOT/hooks/session-snapshot.sh" "$FIXTURES/session-start.json" \
    CODEX_PROOF_ROOT="$proof_root" || return 1

  [ -s "$proof_root/t00-session/baseline_head" ] &&
    [ ! -e "$proof_root/t00-session/skip_stop" ] &&
    [ -e "$proof_root/skip-stop/sessions/t00-session/skip_stop" ] &&
    [ "$(find "$proof_root/skip-stop/cwd" -mindepth 2 -maxdepth 2 -name skip_stop 2>/dev/null | wc -l)" -eq 1 ] &&
    json_field_contains "$out" '.hookSpecificOutput.additionalContext // empty' "CODEX.md"
}

test_session_snapshot_preserves_fresh_markers_in_old_state_dirs() {
  local proof_root out skip_cwd eci_cwd
  proof_root="$(fresh_proof_root session-old-markers)"
  CODEX_SESSION_ID=t00-session CODEX_PROOF_ROOT="$proof_root" "$ROOT/bin/skip-stop" on >/dev/null 2>&1 || return 1
  env -u CODEX_SESSION_ID CODEX_PROOF_ROOT="$proof_root" "$ROOT/bin/skip-stop" on >/dev/null 2>&1 || return 1
  CODEX_SESSION_ID=t00-session CODEX_PROOF_ROOT="$proof_root" "$ROOT/bin/eci-active" on "test scope" >/dev/null 2>&1 || return 1
  env -u CODEX_SESSION_ID CODEX_PROOF_ROOT="$proof_root" "$ROOT/bin/eci-active" on "test scope" >/dev/null 2>&1 || return 1

  skip_cwd=$(find "$proof_root/skip-stop/cwd" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n1)
  eci_cwd=$(find "$proof_root/eci/cwd" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n1)
  [ -n "$skip_cwd" ] && [ -n "$eci_cwd" ] || return 1
  touch -t 202001010000 "$proof_root/skip-stop/sessions/t00-session" "$skip_cwd" \
    "$proof_root/eci/sessions/t00-session" "$eci_cwd"

  out="$TMP_ROOT/session-snapshot-old-markers.out"
  run_hook "$out" "$ROOT/hooks/session-snapshot.sh" "$FIXTURES/session-start.json" \
    CODEX_PROOF_ROOT="$proof_root" || return 1

  [ -e "$proof_root/skip-stop/sessions/t00-session/skip_stop" ] &&
    [ -e "$skip_cwd/skip_stop" ] &&
    [ -e "$proof_root/eci/sessions/t00-session/eci_active" ] &&
    [ -e "$eci_cwd/eci_active" ]
}

test_eci_gate_blocks_code_apply_patch() {
  local proof_root out
  proof_root="$(fresh_proof_root eci-code)"
  mkdir -p "$proof_root/t00-session"
  printf 'scope: test\n' >"$proof_root/t00-session/eci_active"
  out="$TMP_ROOT/eci-code.out"

  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$FIXTURES/eci-apply-patch-code.json" \
    CODEX_PROOF_ROOT="$proof_root" || return 1

  is_pretool_deny "$out"
}

test_eci_gate_blocks_code_apply_patch_from_cwd_state() {
  local proof_root input out count
  proof_root="$(fresh_proof_root eci-code-cwd)"
  out="$TMP_ROOT/eci-code-cwd-active.out"
  env -u CODEX_SESSION_ID CODEX_PROOF_ROOT="$proof_root" "$ROOT/bin/eci-active" on "test scope" >"$out" 2>"$out.err" || return 1
  count=$(find "$proof_root/eci/cwd" -mindepth 2 -maxdepth 2 -name eci_active 2>/dev/null | wc -l)
  [ "$count" -eq 1 ] || return 1

  input="$TMP_ROOT/eci-code-cwd.json"
  jq --arg cwd "$ROOT" '.cwd = $cwd' "$FIXTURES/eci-apply-patch-code.json" >"$input"
  out="$TMP_ROOT/eci-code-cwd.out"

  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" \
    CODEX_PROOF_ROOT="$proof_root" || return 1

  is_pretool_deny "$out"
}

test_eci_gate_blocks_code_apply_patch_from_session_state() {
  local proof_root out
  proof_root="$(fresh_proof_root eci-code-session)"
  out="$TMP_ROOT/eci-code-session-active.out"
  CODEX_SESSION_ID=t00-session CODEX_PROOF_ROOT="$proof_root" "$ROOT/bin/eci-active" on "test scope" >"$out" 2>"$out.err" || return 1
  [ -f "$proof_root/eci/sessions/t00-session/eci_active" ] || return 1
  [ ! -e "$proof_root/t00-session/eci_active" ] || return 1

  out="$TMP_ROOT/eci-code-session.out"
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$FIXTURES/eci-apply-patch-code.json" \
    CODEX_PROOF_ROOT="$proof_root" || return 1

  is_pretool_deny "$out"
}

test_eci_gate_blocks_codex_role_spoof() {
  local proof_root out
  proof_root="$(fresh_proof_root eci-role-spoof)"
  mkdir -p "$proof_root/t00-session"
  printf 'scope: test\n' >"$proof_root/t00-session/eci_active"
  out="$TMP_ROOT/eci-role-spoof.out"

  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$FIXTURES/eci-apply-patch-code.json" \
    CODEX_PROOF_ROOT="$proof_root" CODEX_ROLE="eci-implementer" || return 1

  is_pretool_deny "$out"
}

write_subagent_transcript() {
  local path="$1"
  mkdir -p "$(dirname "$path")" || return 1
  cat >"$path" <<'JSON'
{"timestamp":"2026-05-04T00:00:00.000Z","type":"session_meta","payload":{"id":"t00-session","source":{"subagent":{"thread_spawn":{"parent_thread_id":"parent-session","depth":1,"agent_nickname":"Test","agent_role":"default"}}}}}
JSON
}

write_main_transcript() {
  local path="$1"
  mkdir -p "$(dirname "$path")" || return 1
  cat >"$path" <<'JSON'
{"timestamp":"2026-05-04T00:00:00.000Z","type":"session_meta","payload":{"id":"t00-session","source":"cli"}}
JSON
}

test_eci_gate_allows_spawned_agent_transcript_payload() {
  local proof_root input out transcript
  proof_root="$(fresh_proof_root eci-subagent-transcript)"
  mkdir -p "$proof_root/t00-session"
  printf 'scope: test\n' >"$proof_root/t00-session/eci_active"
  transcript="$(subagent_transcript_path)"
  write_subagent_transcript "$transcript" || return 1
  input="$TMP_ROOT/eci-subagent-transcript.json"
  jq --arg transcript "$transcript" '.transcript_path = $transcript' "$FIXTURES/eci-apply-patch-code.json" >"$input"
  out="$TMP_ROOT/eci-subagent-transcript.out"

  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" \
    HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" || return 1

  expect_no_output "$out"
}

test_eci_gate_blocks_main_transcript_payload() {
  local proof_root input out transcript
  proof_root="$(fresh_proof_root eci-main-transcript)"
  mkdir -p "$proof_root/t00-session"
  printf 'scope: test\n' >"$proof_root/t00-session/eci_active"
  transcript="$TMP_ROOT/home/.codex/sessions/codex-hooks-test-main.jsonl"
  write_main_transcript "$transcript" || return 1
  input="$TMP_ROOT/eci-main-transcript.json"
  jq --arg transcript "$transcript" '.transcript_path = $transcript' "$FIXTURES/eci-apply-patch-code.json" >"$input"
  out="$TMP_ROOT/eci-main-transcript.out"

  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" \
    HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" || return 1

  is_pretool_deny "$out"
}

test_eci_gate_allows_markdown_only_apply_patch() {
  local proof_root out
  proof_root="$(fresh_proof_root eci-markdown)"
  mkdir -p "$proof_root/t00-session"
  printf 'scope: test\n' >"$proof_root/t00-session/eci_active"
  out="$TMP_ROOT/eci-markdown.out"

  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$FIXTURES/eci-apply-patch-markdown.json" \
    CODEX_PROOF_ROOT="$proof_root" || return 1

  expect_no_output "$out"
}

test_eci_gate_allows_markdown_only_edit_payloads() {
  local proof_root out
  proof_root="$(fresh_proof_root eci-markdown-edit)"
  mkdir -p "$proof_root/t00-session"
  printf 'scope: test\n' >"$proof_root/t00-session/eci_active"

  out="$TMP_ROOT/eci-edit-markdown.out"
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$FIXTURES/eci-edit-markdown.json" \
    CODEX_PROOF_ROOT="$proof_root" || return 1
  expect_no_output "$out" || return 1

  out="$TMP_ROOT/eci-multiedit-markdown.out"
  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$FIXTURES/eci-multiedit-markdown.json" \
    CODEX_PROOF_ROOT="$proof_root" || return 1
  expect_no_output "$out"
}

test_eci_gate_allows_markdown_only_write_payload() {
  local proof_root out
  proof_root="$(fresh_proof_root eci-markdown-write)"
  mkdir -p "$proof_root/t00-session"
  printf 'scope: test\n' >"$proof_root/t00-session/eci_active"
  out="$TMP_ROOT/eci-write-markdown.out"

  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$FIXTURES/eci-write-markdown.json" \
    CODEX_PROOF_ROOT="$proof_root" || return 1

  expect_no_output "$out"
}

test_eci_gate_denies_code_write_payload() {
  local proof_root out
  proof_root="$(fresh_proof_root eci-code-write)"
  mkdir -p "$proof_root/t00-session"
  printf 'scope: test\n' >"$proof_root/t00-session/eci_active"
  out="$TMP_ROOT/eci-write-code.out"

  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$FIXTURES/eci-write-code.json" \
    CODEX_PROOF_ROOT="$proof_root" || return 1

  is_pretool_deny "$out"
}

test_eci_gate_denies_mixed_markdown_code_patch() {
  local proof_root out
  proof_root="$(fresh_proof_root eci-mixed)"
  mkdir -p "$proof_root/t00-session"
  printf 'scope: test\n' >"$proof_root/t00-session/eci_active"
  out="$TMP_ROOT/eci-mixed.out"

  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$FIXTURES/eci-apply-patch-mixed.json" \
    CODEX_PROOF_ROOT="$proof_root" || return 1

  is_pretool_deny "$out"
}

test_eci_gate_blocks_multiedit_stdin() {
  local proof_root out
  proof_root="$(fresh_proof_root eci-multiedit)"
  mkdir -p "$proof_root/t00-session"
  printf 'scope: test\n' >"$proof_root/t00-session/eci_active"
  out="$TMP_ROOT/eci-multiedit.out"

  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$FIXTURES/eci-multiedit.json" \
    CODEX_PROOF_ROOT="$proof_root" || return 1

  is_pretool_deny "$out"
}

eci_gate_matcher() {
  jq -er '
    first(
      .hooks.PreToolUse[]?
      | select(any(.hooks[]?; (.command // "") | endswith("/eci-active-gate.sh")))
      | .matcher
      | strings
    )
  ' "$ROOT/hooks.json"
}

matcher_has_tool() {
  local matcher="$1"
  local tool="$2"
  jq -e -n --arg matcher "$matcher" --arg tool "$tool" '
    $matcher | test("(^|[^A-Za-z0-9_])" + $tool + "([^A-Za-z0-9_]|$)")
  ' >/dev/null
}

test_multiedit_hook_config_is_wired() {
  local matcher
  matcher="$(eci_gate_matcher)" || return 1
  matcher_has_tool "$matcher" "MultiEdit"
}

test_validate_apply_patch_blocks_plan_paths_from_input() {
  local out
  out="$TMP_ROOT/apply-patch-plan.out"
  run_hook "$out" "$ROOT/hooks/validate-apply-patch.sh" "$FIXTURES/validate-apply-patch-plan.json" || return 1
  is_pretool_deny "$out" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "docs/plans"
}

test_validate_apply_patch_blocks_plan_move_destination() {
  local out
  out="$TMP_ROOT/apply-patch-plan-move.out"
  run_hook "$out" "$ROOT/hooks/validate-apply-patch.sh" "$FIXTURES/validate-apply-patch-plan-move.json" || return 1
  is_pretool_deny "$out" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "docs/plans"
}

test_ate_gate_denies_markdown_edits_for_lead() {
  local out
  out="$TMP_ROOT/ate-markdown-lead.out"
  run_hook "$out" "$ROOT/hooks/ate-orchestrator-gate.sh" "$FIXTURES/eci-apply-patch-markdown.json" \
    CODEX_ROLE=lead || return 1
  is_pretool_deny "$out"
}

test_ate_gate_denies_markdown_edits_for_coordinator() {
  local out
  out="$TMP_ROOT/ate-markdown-coordinator.out"
  run_hook "$out" "$ROOT/hooks/ate-orchestrator-gate.sh" "$FIXTURES/eci-apply-patch-markdown.json" \
    CODEX_ROLE=coordinator || return 1
  is_pretool_deny "$out"
}

test_validate_apply_patch_blocks_local_gomod_replace_from_patch() {
  local out
  out="$TMP_ROOT/apply-patch-gomod.out"
  run_hook "$out" "$ROOT/hooks/validate-apply-patch.sh" "$FIXTURES/validate-apply-patch-gomod.json" || return 1
  is_pretool_deny "$out" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "local relative replace"
}

test_validate_apply_patch_blocks_local_gomod_replace_on_move_destination() {
  local out
  out="$TMP_ROOT/apply-patch-gomod-move.out"
  run_hook "$out" "$ROOT/hooks/validate-apply-patch.sh" "$FIXTURES/validate-apply-patch-gomod-move.json" || return 1
  is_pretool_deny "$out" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "local relative replace"
}

test_security_reminder_sees_workflow_move_destination() {
  local proof_root out
  proof_root="$(fresh_proof_root security-workflow-move)"
  out="$TMP_ROOT/security-workflow-move.out"
  env -u CODEX_ROLE CODEX_PROOF_ROOT="$proof_root" "$ROOT/hooks/security-reminder.py" \
    <"$FIXTURES/security-workflow-move.json" >"$out" 2>"$out.err" || return 1
  json_field_contains "$out" '.systemMessage // empty' "GitHub Actions workflow"
}

test_stop_gate_blocks_missing_proof_sections() {
  local proof_root input out
  proof_root="$(fresh_proof_root stop-missing)"
  mkdir -p "$proof_root/t00-session"
  cp "$FIXTURES/proof-missing-sections.md" "$proof_root/t00-session/proof.md"
  input="$TMP_ROOT/stop-missing.json"
  with_cwd_fixture "$FIXTURES/stop-basic.json" "$input"
  out="$TMP_ROOT/stop-missing.out"

  run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$input" CODEX_PROOF_ROOT="$proof_root" || return 1
  is_stop_block "$out" &&
    json_field_contains "$out" '.reason // empty' "missing required sections"
}

test_stop_gate_accepts_complete_proof_fixture() {
  local proof_root input out
  proof_root="$(fresh_proof_root stop-complete)"
  mkdir -p "$proof_root/t00-session"
  cp "$FIXTURES/proof-complete.md" "$proof_root/t00-session/proof.md"
  input="$TMP_ROOT/stop-complete.json"
  with_cwd_fixture "$FIXTURES/stop-basic.json" "$input"
  out="$TMP_ROOT/stop-complete.out"

  run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$input" CODEX_PROOF_ROOT="$proof_root" || return 1
  is_stop_block "$out" &&
    json_field_contains "$out" '.reason // empty' "Verification proof accepted" &&
    [ -s "$proof_root/t00-session/summary-to-print.md" ] &&
    [ ! -e "$proof_root/t00-session/proof.md" ]
}

test_stop_gate_accepts_proof_reports_dirty_git_state() {
  local proof_root input out repo
  proof_root="$(fresh_proof_root stop-proof-dirty)"
  mkdir -p "$proof_root/t00-session"
  cp "$FIXTURES/proof-complete.md" "$proof_root/t00-session/proof.md"
  repo="$(make_git_repo stop-proof-dirty)" || return 1
  printf 'dirty\n' >>"$repo/file.txt"
  input="$TMP_ROOT/stop-proof-dirty.json"
  with_cwd_path "$FIXTURES/stop-basic.json" "$input" "$repo"
  out="$TMP_ROOT/stop-proof-dirty.out"

  run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$input" CODEX_PROOF_ROOT="$proof_root" || return 1
  is_stop_block "$out" &&
    json_field_contains "$out" '.reason // empty' "git state is still dirty" &&
    [ -s "$proof_root/t00-session/summary-to-print.md" ] &&
    [ -s "$proof_root/t00-session/git-status-at-accept.txt" ] &&
    grep -q ' M file.txt' "$proof_root/t00-session/git-status-at-accept.txt"
}

test_stop_gate_blocks_cwd_eci_state() {
  local proof_root input out
  proof_root="$(fresh_proof_root stop-cwd-eci)"
  out="$TMP_ROOT/stop-cwd-eci-active.out"
  env -u CODEX_SESSION_ID CODEX_PROOF_ROOT="$proof_root" "$ROOT/bin/eci-active" on "test scope" >"$out" 2>"$out.err" || return 1

  input="$TMP_ROOT/stop-cwd-eci.json"
  with_cwd_fixture "$FIXTURES/stop-basic.json" "$input"
  out="$TMP_ROOT/stop-cwd-eci.out"

  run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$input" CODEX_PROOF_ROOT="$proof_root" || return 1
  is_stop_block "$out" &&
    json_field_contains "$out" '.reason // empty' "ECI is active"
}

test_stop_gate_blocks_cwd_eci_state_without_cwd_field() {
  local proof_root input out
  proof_root="$(fresh_proof_root stop-cwd-eci-no-cwd)"
  out="$TMP_ROOT/stop-cwd-eci-no-cwd-active.out"
  env -u CODEX_SESSION_ID CODEX_PROOF_ROOT="$proof_root" "$ROOT/bin/eci-active" on "test scope" >"$out" 2>"$out.err" || return 1

  input="$TMP_ROOT/stop-cwd-eci-no-cwd.json"
  jq 'del(.cwd)' "$FIXTURES/stop-basic.json" >"$input"
  out="$TMP_ROOT/stop-cwd-eci-no-cwd.out"

  run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$input" CODEX_PROOF_ROOT="$proof_root" || return 1
  is_stop_block "$out" &&
    json_field_contains "$out" '.reason // empty' "ECI is active"
}

test_stop_gate_blocks_session_eci_state() {
  local proof_root input out
  proof_root="$(fresh_proof_root stop-session-eci)"
  out="$TMP_ROOT/stop-session-eci-active.out"
  CODEX_SESSION_ID=t00-session CODEX_PROOF_ROOT="$proof_root" "$ROOT/bin/eci-active" on "test scope" >"$out" 2>"$out.err" || return 1

  input="$TMP_ROOT/stop-session-eci.json"
  with_cwd_fixture "$FIXTURES/stop-basic.json" "$input"
  out="$TMP_ROOT/stop-session-eci.out"

  run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$input" CODEX_PROOF_ROOT="$proof_root" || return 1
  is_stop_block "$out" &&
    json_field_contains "$out" '.reason // empty' "ECI is active"
}

test_stop_gate_blocks_codex_role_spoof_with_eci_state() {
  local proof_root input out
  proof_root="$(fresh_proof_root stop-role-spoof)"
  out="$TMP_ROOT/stop-role-spoof-eci-active.out"
  env -u CODEX_SESSION_ID CODEX_PROOF_ROOT="$proof_root" "$ROOT/bin/eci-active" on "test scope" >"$out" 2>"$out.err" || return 1

  input="$TMP_ROOT/stop-role-spoof.json"
  with_cwd_fixture "$FIXTURES/stop-basic.json" "$input"
  out="$TMP_ROOT/stop-role-spoof.out"

  run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$input" CODEX_PROOF_ROOT="$proof_root" CODEX_ROLE=explorer || return 1
  is_stop_block "$out" &&
    json_field_contains "$out" '.reason // empty' "ECI is active"
}

test_stop_gate_allows_spawned_agent_transcript_without_proof_state() {
  local proof_root input out transcript
  proof_root="$(fresh_proof_root stop-subagent-transcript)"
  out="$TMP_ROOT/stop-subagent-transcript-eci-active.out"
  env -u CODEX_SESSION_ID CODEX_PROOF_ROOT="$proof_root" "$ROOT/bin/eci-active" on "test scope" >"$out" 2>"$out.err" || return 1

  transcript="$(subagent_transcript_path)"
  write_subagent_transcript "$transcript" || return 1
  input="$TMP_ROOT/stop-subagent-transcript.json"
  jq --arg cwd "$ROOT" --arg transcript "$transcript" '.cwd = $cwd | .transcript_path = $transcript' "$FIXTURES/stop-basic.json" >"$input"
  out="$TMP_ROOT/stop-subagent-transcript.out"

  run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$input" HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" || return 1
  json_field_equals "$out" '.continue // false' "true" &&
    [ ! -e "$proof_root/t00-session" ]
}

test_stop_gate_blocks_main_transcript_with_eci_state() {
  local proof_root input out transcript
  proof_root="$(fresh_proof_root stop-main-transcript)"
  out="$TMP_ROOT/stop-main-transcript-eci-active.out"
  env -u CODEX_SESSION_ID CODEX_PROOF_ROOT="$proof_root" "$ROOT/bin/eci-active" on "test scope" >"$out" 2>"$out.err" || return 1

  transcript="$TMP_ROOT/home/.codex/sessions/codex-hooks-test-main.jsonl"
  write_main_transcript "$transcript" || return 1
  input="$TMP_ROOT/stop-main-transcript.json"
  jq --arg cwd "$ROOT" --arg transcript "$transcript" '.cwd = $cwd | .transcript_path = $transcript' "$FIXTURES/stop-basic.json" >"$input"
  out="$TMP_ROOT/stop-main-transcript.out"

  run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$input" HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" || return 1
  is_stop_block "$out" &&
    json_field_contains "$out" '.reason // empty' "ECI is active"
}

test_stop_gate_allows_session_skip_state() {
  local proof_root input out
  proof_root="$(fresh_proof_root stop-session-skip)"
  CODEX_SESSION_ID=t00-session CODEX_PROOF_ROOT="$proof_root" "$ROOT/bin/skip-stop" on >"$TMP_ROOT/stop-session-skip-on.out" 2>&1 || return 1

  input="$TMP_ROOT/stop-session-skip.json"
  with_cwd_fixture "$FIXTURES/stop-basic.json" "$input"
  out="$TMP_ROOT/stop-session-skip.out"

  run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$input" CODEX_PROOF_ROOT="$proof_root" || return 1
  json_field_equals "$out" '.continue // false' "true"
}

test_stop_gate_allows_cwd_skip_state() {
  local proof_root input out
  proof_root="$(fresh_proof_root stop-cwd-skip)"
  env -u CODEX_SESSION_ID CODEX_PROOF_ROOT="$proof_root" "$ROOT/bin/skip-stop" on >"$TMP_ROOT/stop-cwd-skip-on.out" 2>&1 || return 1

  input="$TMP_ROOT/stop-cwd-skip.json"
  with_cwd_fixture "$FIXTURES/stop-basic.json" "$input"
  out="$TMP_ROOT/stop-cwd-skip.out"

  run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$input" CODEX_PROOF_ROOT="$proof_root" || return 1
  json_field_equals "$out" '.continue // false' "true"
}

test_eci_active_off_cwd_marker_writes_bound_session_proof() {
  local proof_root input out active_count
  proof_root="$(fresh_proof_root eci-off-cwd)"
  env -u CODEX_SESSION_ID CODEX_PROOF_ROOT="$proof_root" "$ROOT/bin/eci-active" on "test scope" >"$TMP_ROOT/eci-off-cwd-on.out" 2>&1 || return 1

  input="$TMP_ROOT/eci-off-cwd-stop.json"
  with_cwd_fixture "$FIXTURES/stop-basic.json" "$input"
  out="$TMP_ROOT/eci-off-cwd-stop.out"
  run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$input" CODEX_PROOF_ROOT="$proof_root" || return 1
  is_stop_block "$out" || return 1

  env -u CODEX_SESSION_ID CODEX_PROOF_ROOT="$proof_root" "$ROOT/bin/eci-active" off "$FIXTURES/eci-proof-complete.md" >"$TMP_ROOT/eci-off-cwd-off.out" 2>"$TMP_ROOT/eci-off-cwd-off.err" || return 1
  active_count=$(find "$proof_root/eci/cwd" -mindepth 2 -maxdepth 2 -name eci_active 2>/dev/null | wc -l)
  [ "$active_count" -eq 0 ] || return 1
  [ -s "$proof_root/t00-session/proof.md" ] || return 1

  out="$TMP_ROOT/eci-off-cwd-accept.out"
  run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$input" CODEX_PROOF_ROOT="$proof_root" || return 1
  is_stop_block "$out" &&
    json_field_contains "$out" '.reason // empty' "Verification proof accepted" &&
    [ -s "$proof_root/t00-session/summary-to-print.md" ] &&
    [ ! -e "$proof_root/t00-session/proof.md" ]
}

test_eci_active_off_rejects_unbound_cwd_marker() {
  local proof_root out marker status
  proof_root="$(fresh_proof_root eci-off-unbound)"
  env -u CODEX_SESSION_ID CODEX_PROOF_ROOT="$proof_root" "$ROOT/bin/eci-active" on "test scope" >"$TMP_ROOT/eci-off-unbound-on.out" 2>&1 || return 1
  marker=$(find "$proof_root/eci/cwd" -mindepth 2 -maxdepth 2 -name eci_active 2>/dev/null | head -n1)
  [ -n "$marker" ] || return 1

  out="$TMP_ROOT/eci-off-unbound-off.out"
  env -u CODEX_SESSION_ID CODEX_PROOF_ROOT="$proof_root" "$ROOT/bin/eci-active" off "$FIXTURES/eci-proof-complete.md" >"$out" 2>"$out.err"
  status=$?

  [ "$status" -ne 0 ] &&
    [ -e "$marker" ] &&
    [ ! -e "$(dirname "$marker")/proof.md" ] &&
    [ ! -e "$proof_root/t00-session/proof.md" ] &&
    grep -q "not associated with a Codex session" "$out.err"
}

test_eci_active_uses_cwd_state_without_session() {
  local proof_root out status count
  proof_root="$(fresh_proof_root cwd-state)"
  mkdir -p "$proof_root/019df400-0000-7000-8000-000000000001" \
    "$proof_root/019df400-0000-7000-8000-000000000002"
  touch -t 202001010000 "$proof_root/019df400-0000-7000-8000-000000000001"
  touch -t 202101010000 "$proof_root/019df400-0000-7000-8000-000000000002"
  out="$TMP_ROOT/eci-active-cwd.out"

  env -u CODEX_SESSION_ID CODEX_PROOF_ROOT="$proof_root" "$ROOT/bin/eci-active" on "test scope" >"$out" 2>"$out.err"
  status=$?
  count=$(find "$proof_root/eci/cwd" -mindepth 2 -maxdepth 2 -name eci_active 2>/dev/null | wc -l)

  [ "$status" -eq 0 ] &&
    [ ! -e "$proof_root/019df400-0000-7000-8000-000000000001/eci_active" ] &&
    [ ! -e "$proof_root/019df400-0000-7000-8000-000000000002/eci_active" ] &&
    [ "$count" -eq 1 ] &&
    grep -q "ECI active: $proof_root/eci/cwd/" "$out"
}

test_skip_stop_uses_cwd_state_without_session() {
  local proof_root out count
  proof_root="$(fresh_proof_root skip-cwd)"
  mkdir -p "$proof_root/019df400-0000-7000-8000-000000000001" \
    "$proof_root/019df400-0000-7000-8000-000000000002"
  out="$TMP_ROOT/skip-stop-cwd.out"

  env -u CODEX_SESSION_ID CODEX_PROOF_ROOT="$proof_root" "$ROOT/bin/skip-stop" on >"$out" 2>"$out.err" || return 1
  count=$(find "$proof_root/skip-stop/cwd" -mindepth 2 -maxdepth 2 -name skip_stop 2>/dev/null | wc -l)

  [ "$count" -eq 1 ] &&
    [ ! -e "$proof_root/019df400-0000-7000-8000-000000000001/skip_stop" ] &&
    [ ! -e "$proof_root/019df400-0000-7000-8000-000000000002/skip_stop" ] &&
    grep -q "Stop hook bypass enabled: $proof_root/skip-stop/cwd/" "$out"
}

run_case "prompt state is silent and records HEAD" \
  test_prompt_state_is_silent_records_head_and_clears_bypass
run_case "prompt state marks /side prompts" \
  test_prompt_state_marks_side_prompt
run_case "prompt state skips state writes for invalid session" \
  test_prompt_state_skips_state_for_invalid_session
run_case "prompt state config is wired without temporary probe" \
  test_prompt_state_config_is_wired_without_probe
run_case "runtime hook probe evidence is sanitized and wired" \
  test_runtime_hook_probe_evidence_is_sanitized_and_wired
run_case "session snapshot saves baseline and clears legacy skip_stop" \
  test_session_snapshot_saves_baseline_and_clears_legacy_skip
run_case "session snapshot preserves fresh markers in old state dirs" \
  test_session_snapshot_preserves_fresh_markers_in_old_state_dirs
run_case "ECI gate blocks code apply_patch when marker exists" \
  test_eci_gate_blocks_code_apply_patch
run_case "ECI gate blocks code apply_patch from cwd marker" \
  test_eci_gate_blocks_code_apply_patch_from_cwd_state
run_case "ECI gate blocks code apply_patch from session marker" \
  test_eci_gate_blocks_code_apply_patch_from_session_state
run_case "ECI gate blocks CODEX_ROLE spoof through marker" \
  test_eci_gate_blocks_codex_role_spoof
run_case "ECI gate allows spawned-agent transcript payload" \
  test_eci_gate_allows_spawned_agent_transcript_payload
run_case "ECI gate blocks main transcript payload" \
  test_eci_gate_blocks_main_transcript_payload
run_case "ECI gate allows markdown-only apply_patch while marker exists" \
  test_eci_gate_allows_markdown_only_apply_patch
run_case "ECI gate allows markdown-only Edit and MultiEdit payloads" \
  test_eci_gate_allows_markdown_only_edit_payloads
run_case "ECI gate allows markdown-only Write payload" \
  test_eci_gate_allows_markdown_only_write_payload
run_case "ECI gate denies code Write payload" \
  test_eci_gate_denies_code_write_payload
run_case "ECI gate denies mixed markdown/code apply_patch" \
  test_eci_gate_denies_mixed_markdown_code_patch
run_case "ECI gate blocks MultiEdit JSON stdin when marker exists" \
  test_eci_gate_blocks_multiedit_stdin
run_case "hooks.json edit matcher includes MultiEdit" \
  test_multiedit_hook_config_is_wired
run_case "ATE gate denies markdown edits for lead role" \
  test_ate_gate_denies_markdown_edits_for_lead
run_case "ATE gate denies markdown edits for coordinator role" \
  test_ate_gate_denies_markdown_edits_for_coordinator
run_case "validate-apply-patch parses tool_input.input plan paths" \
  test_validate_apply_patch_blocks_plan_paths_from_input
run_case "validate-apply-patch blocks Move to plan paths" \
  test_validate_apply_patch_blocks_plan_move_destination
run_case "validate-apply-patch parses tool_input.patch go.mod replaces" \
  test_validate_apply_patch_blocks_local_gomod_replace_from_patch
run_case "validate-apply-patch blocks go.mod replace on Move to destination" \
  test_validate_apply_patch_blocks_local_gomod_replace_on_move_destination
run_case "security reminder sees workflow Move to destination" \
  test_security_reminder_sees_workflow_move_destination
run_case "stop gate blocks proof missing required sections" \
  test_stop_gate_blocks_missing_proof_sections
run_case "stop gate accepts complete proof fixture" \
  test_stop_gate_accepts_complete_proof_fixture
run_case "stop gate accepted proof reports dirty git state" \
  test_stop_gate_accepts_proof_reports_dirty_git_state
run_case "stop gate blocks cwd-scoped ECI marker" \
  test_stop_gate_blocks_cwd_eci_state
run_case "stop gate blocks cwd-scoped ECI marker without cwd field" \
  test_stop_gate_blocks_cwd_eci_state_without_cwd_field
run_case "stop gate blocks session-scoped ECI marker" \
  test_stop_gate_blocks_session_eci_state
run_case "stop gate blocks CODEX_ROLE spoof with ECI state" \
  test_stop_gate_blocks_codex_role_spoof_with_eci_state
run_case "stop gate allows /side before ECI state" \
  test_stop_gate_allows_side_prompt_before_eci_state
run_case "stop gate allows spawned-agent transcript without proof state" \
  test_stop_gate_allows_spawned_agent_transcript_without_proof_state
run_case "stop gate blocks main transcript with ECI state" \
  test_stop_gate_blocks_main_transcript_with_eci_state
run_case "stop gate allows session-scoped skip marker" \
  test_stop_gate_allows_session_skip_state
run_case "stop gate allows cwd-scoped skip marker" \
  test_stop_gate_allows_cwd_skip_state
run_case "eci-active off maps cwd marker proof to bound session" \
  test_eci_active_off_cwd_marker_writes_bound_session_proof
run_case "eci-active off rejects unbound cwd marker" \
  test_eci_active_off_rejects_unbound_cwd_marker
run_case "eci-active uses cwd state without CODEX_SESSION_ID" \
  test_eci_active_uses_cwd_state_without_session
run_case "skip-stop uses cwd state without CODEX_SESSION_ID" \
  test_skip_stop_uses_cwd_state_without_session

todo "stop proof freshness oracle parity with .claude detailed audit history"

note "SUMMARY pass=$PASS_COUNT fail=$FAIL_COUNT xfail=$XFAIL_COUNT xpass=$XPASS_COUNT todo=$TODO_COUNT"

if [ "$FAIL_COUNT" -ne 0 ] || [ "$XPASS_COUNT" -ne 0 ]; then
  exit 1
fi
