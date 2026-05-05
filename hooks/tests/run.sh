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

install_proof_fixture() {
  local proof_root="$1"
  local fixture="$2"
  mkdir -p "$proof_root/t00-session" || return 1
  cp "$fixture" "$proof_root/t00-session/proof.md"
}

stop_reason_has_proof_recovery_paths() {
  local out="$1"
  local proof_root="$2"
  json_field_contains "$out" '.reason // empty' "$proof_root/t00-session/proof.md" &&
    json_field_contains "$out" '.reason // empty' "$proof_root/t00-session/instructions.md"
}

accept_stop_proof() {
  local proof_root="$1"
  local repo="$2"
  local fixture="$3"
  local tag="$4"
  local input out

  install_proof_fixture "$proof_root" "$fixture" || return 1
  input="$TMP_ROOT/${tag}.json"
  with_cwd_path "$FIXTURES/stop-basic.json" "$input" "$repo"
  out="$TMP_ROOT/${tag}.out"
  run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$input" CODEX_PROOF_ROOT="$proof_root" || return 1
  is_stop_block "$out" &&
    json_field_contains "$out" '.reason // empty' "Verification proof accepted"
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
  local proof_root out marker cwd_marker_count cwd_marker
  proof_root="$(fresh_proof_root prompt-side)"
  out="$TMP_ROOT/prompt-side.out"

  run_hook "$out" "$ROOT/hooks/prompt-task-reminder.sh" "$FIXTURES/user-prompt-side.json" \
    CODEX_PROOF_ROOT="$proof_root" || return 1

  marker="$proof_root/side-stop/sessions/t00-session/side_stop"
  cwd_marker_count=$(find "$proof_root/side-stop/cwd" -mindepth 2 -maxdepth 2 -name side_stop 2>/dev/null | wc -l)
  cwd_marker=$(find "$proof_root/side-stop/cwd" -mindepth 2 -maxdepth 2 -name side_stop 2>/dev/null | head -n1)
  expect_no_output "$out" &&
    [ -f "$marker" ] &&
    grep -q '^command: /side$' "$marker" &&
    grep -q '^parent_session_id: t00-session$' "$marker" &&
    [ "$cwd_marker_count" -eq 1 ] &&
    grep -q '^command: /side$' "$cwd_marker" &&
    grep -q '^parent_session_id: t00-session$' "$cwd_marker"
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
      | all(contains("/hooks/tests/skill-event-probe.sh") | not))
  ' "$ROOT/hooks.json" >/dev/null
}

test_stop_gate_allows_side_prompt_before_eci_state() {
  local proof_root prompt_out prompt_input input out
  proof_root="$(fresh_proof_root stop-side-eci)"
  prompt_out="$TMP_ROOT/stop-side-prompt.out"
  prompt_input="$TMP_ROOT/stop-side-prompt.json"

  jq --arg cwd "$ROOT" '.session_id = "t00-parent" | .cwd = $cwd' "$FIXTURES/user-prompt-side.json" >"$prompt_input"
  run_hook "$prompt_out" "$ROOT/hooks/prompt-task-reminder.sh" "$prompt_input" \
    CODEX_PROOF_ROOT="$proof_root" || return 1
  env -u CODEX_SESSION_ID CODEX_PROOF_ROOT="$proof_root" "$ROOT/bin/eci-active" on "test scope" >"$TMP_ROOT/stop-side-eci-on.out" 2>&1 || return 1

  input="$TMP_ROOT/stop-side-eci.json"
  jq --arg cwd "$ROOT" '.session_id = "t00-side" | .cwd = $cwd' "$FIXTURES/stop-basic.json" >"$input"
  out="$TMP_ROOT/stop-side-eci.out"

  run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$input" CODEX_PROOF_ROOT="$proof_root" || return 1
  json_field_equals "$out" '.continue // false' "true"
}

test_stop_gate_blocks_side_parent_session_with_eci_state() {
  local proof_root prompt_out prompt_input input out
  proof_root="$(fresh_proof_root stop-side-parent-eci)"
  prompt_out="$TMP_ROOT/stop-side-parent-prompt.out"
  prompt_input="$TMP_ROOT/stop-side-parent-prompt.json"

  jq --arg cwd "$ROOT" '.session_id = "t00-parent" | .cwd = $cwd' "$FIXTURES/user-prompt-side.json" >"$prompt_input"
  run_hook "$prompt_out" "$ROOT/hooks/prompt-task-reminder.sh" "$prompt_input" \
    CODEX_PROOF_ROOT="$proof_root" || return 1
  env -u CODEX_SESSION_ID CODEX_PROOF_ROOT="$proof_root" "$ROOT/bin/eci-active" on "test scope" >"$TMP_ROOT/stop-side-parent-eci-on.out" 2>&1 || return 1

  input="$TMP_ROOT/stop-side-parent-eci.json"
  jq --arg cwd "$ROOT" '.session_id = "t00-parent" | .cwd = $cwd' "$FIXTURES/stop-basic.json" >"$input"
  out="$TMP_ROOT/stop-side-parent-eci.out"

  run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$input" CODEX_PROOF_ROOT="$proof_root" || return 1
  is_stop_block "$out" &&
    json_field_contains "$out" '.reason // empty' "ECI is active"
}

test_runtime_hook_probe_historical_evidence_is_sanitized() {
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

test_session_snapshot_skips_ephemeral_threads() {
  local proof_root out
  proof_root="$(fresh_proof_root session-ephemeral)"
  out="$TMP_ROOT/session-snapshot-ephemeral.out"

  run_hook "$out" "$ROOT/hooks/session-snapshot.sh" "$FIXTURES/session-start-ephemeral.json" \
    CODEX_PROOF_ROOT="$proof_root" || return 1

  expect_no_output "$out" &&
    [ ! -e "$proof_root/t00-side/baseline_head" ]
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

test_stop_gate_allows_ephemeral_threads_before_eci_state() {
  local proof_root out
  proof_root="$(fresh_proof_root stop-ephemeral-eci)"
  CODEX_SESSION_ID=t00-side CODEX_PROOF_ROOT="$proof_root" "$ROOT/bin/eci-active" on "test scope" >/dev/null 2>&1 || return 1
  out="$TMP_ROOT/stop-ephemeral-eci.out"

  run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$FIXTURES/stop-ephemeral.json" \
    CODEX_PROOF_ROOT="$proof_root" || return 1

  json_field_equals "$out" '.continue // false' "true"
}

test_side_session_start_is_silent_and_binds_stop_bypass() {
  local proof_root prompt_out prompt_input start_input start_out stop_input stop_out child_marker cwd_marker
  proof_root="$(fresh_proof_root session-side)"
  prompt_out="$TMP_ROOT/session-side-prompt.out"
  prompt_input="$TMP_ROOT/session-side-prompt.json"

  jq --arg cwd "$ROOT" '.session_id = "t00-parent" | .cwd = $cwd' "$FIXTURES/user-prompt-side.json" >"$prompt_input"
  run_hook "$prompt_out" "$ROOT/hooks/prompt-task-reminder.sh" "$prompt_input" \
    CODEX_PROOF_ROOT="$proof_root" || return 1

  start_input="$TMP_ROOT/session-side-start.json"
  jq --arg cwd "$ROOT" '.session_id = "t00-side" | .cwd = $cwd' "$FIXTURES/session-start.json" >"$start_input"
  start_out="$TMP_ROOT/session-side-start.out"
  run_hook "$start_out" "$ROOT/hooks/session-snapshot.sh" "$start_input" \
    CODEX_PROOF_ROOT="$proof_root" || return 1

  child_marker="$proof_root/side-stop/sessions/t00-side/side_stop"
  cwd_marker=$(find "$proof_root/side-stop/cwd" -mindepth 2 -maxdepth 2 -name side_stop 2>/dev/null | head -n1)
  [ -n "$cwd_marker" ] || return 1
  touch -t 202001010000 "$cwd_marker"
  env -u CODEX_SESSION_ID CODEX_PROOF_ROOT="$proof_root" "$ROOT/bin/eci-active" on "test scope" >"$TMP_ROOT/session-side-eci-on.out" 2>&1 || return 1

  stop_input="$TMP_ROOT/session-side-stop.json"
  jq --arg cwd "$ROOT" '.session_id = "t00-side" | .cwd = $cwd' "$FIXTURES/stop-basic.json" >"$stop_input"
  stop_out="$TMP_ROOT/session-side-stop.out"
  run_hook "$stop_out" "$ROOT/hooks/stop-gate.sh" "$stop_input" CODEX_PROOF_ROOT="$proof_root" || return 1

  expect_no_output "$start_out" &&
    [ -f "$child_marker" ] &&
    grep -q '^parent_session_id: t00-parent$' "$child_marker" &&
    json_field_equals "$stop_out" '.continue // false' "true"
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

main_reviewer_transcript_path() {
  printf '%s/home/.codex/sessions/codex-hooks-test-main-reviewer.jsonl\n' "$TMP_ROOT"
}

install_reviewer_transcript_fixture() {
  local fixture="$1"
  local path="$2"
  mkdir -p "$(dirname "$path")" || return 1
  cp "$fixture" "$path"
}

redaction_fixture_value() {
  case "$1" in
    openai-api-key) printf '%s%s%s' 'sk-' 'test' 'SECRET1234567890' ;;
    password) printf '%s%s' 'hunter' '2' ;;
    bearer-token) printf '%s%s' 'bearer' 'SECRET987654321' ;;
    github-token) printf '%s%s%s' 'gh' 'p_' 'SECRETtoken1234567890' ;;
    slack-token) printf '%s%s%s' 'xo' 'xb-' '1234567890-secretvalue' ;;
    aws-access-key) printf '%s%s' 'AK' 'IAABCDEFGHIJKLMNOP' ;;
    google-api-key) printf '%s%s%s' 'AI' 'za' 'SyA1234567890abcdefghijklmnopqrstu' ;;
    private-key-begin) printf '%s%s %s %s %s%s' '-----' 'BEGIN' 'OPENSSH' 'PRIVATE' 'KEY' '-----' ;;
    private-key-material) printf '%s%s%s' 'private' '-key-' 'material' ;;
    private-key-end) printf '%s%s %s %s %s%s' '-----' 'END' 'OPENSSH' 'PRIVATE' 'KEY' '-----' ;;
    private-key-block)
      printf '%s\n%s\n%s' \
        "$(redaction_fixture_value private-key-begin)" \
        "$(redaction_fixture_value private-key-material)" \
        "$(redaction_fixture_value private-key-end)"
      ;;
    *) return 1 ;;
  esac
}

file_lacks_values() {
  local file="$1"
  local value
  shift

  for value in "$@"; do
    [ -n "$value" ] || continue
    if grep -Fq -- "$value" "$file"; then
      return 1
    fi
  done
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

test_reviewer_backend_parser_accepts_no_credential_backends() {
  (
    . "$ROOT/hooks/lib/reviewer-backend.sh"
    CODEX_STOP_REVIEWER="" parse_reviewer_env CODEX_STOP_REVIEWER &&
      [ "$REVIEWER_BACKEND" = "" ] &&
      CODEX_STOP_REVIEWER="ollama:http://127.0.0.1:11434:qwen3:4b" parse_reviewer_env CODEX_STOP_REVIEWER &&
      [ "$REVIEWER_BACKEND" = "ollama" ] &&
      [ "$REVIEWER_OLLAMA_HOST" = "http://127.0.0.1:11434" ] &&
      [ "$REVIEWER_OLLAMA_MODEL" = "qwen3:4b" ] &&
      CODEX_STOP_REVIEWER="opencode-zen:https://zen.example:nemotron" parse_reviewer_env CODEX_STOP_REVIEWER &&
      [ "$REVIEWER_BACKEND" = "opencode-zen" ] &&
      [ "$REVIEWER_OPENCODE_HOST" = "https://zen.example" ] &&
      [ "$REVIEWER_OPENCODE_MODEL" = "nemotron" ]
  )
}

test_reviewer_backend_parser_rejects_credential_backends() {
  (
    . "$ROOT/hooks/lib/reviewer-backend.sh"
    ! CODEX_STOP_REVIEWER="claude" parse_reviewer_env CODEX_STOP_REVIEWER &&
      ! CODEX_STOP_REVIEWER="github-copilot:gpt-4.1" parse_reviewer_env CODEX_STOP_REVIEWER &&
      ! CODEX_STOP_REVIEWER="codex-as-role:reviewer" parse_reviewer_env CODEX_STOP_REVIEWER &&
      ! CODEX_STOP_REVIEWER="codex:/usr/bin/codex" parse_reviewer_env CODEX_STOP_REVIEWER &&
      ! CODEX_STOP_REVIEWER="shell:/home/streaming/.codex/bin/agent" parse_reviewer_env CODEX_STOP_REVIEWER
  )
}

test_reviewer_schema_matches_rules() {
  jq -e '
    (.required | index("assistant_tail_quote")) and
    (.required | index("passes_completed")) and
    (.required | index("verdict")) and
    (.required | index("violations")) and
    (.properties.passes_completed.items.enum | index("tail")) and
    (.properties.passes_completed.items.enum | index("tools")) and
    (.properties.passes_completed.items.enum | index("checklist")) and
    (.properties.passes_completed.items.enum | index("agreements"))
  ' "$ROOT/hooks/lib/reviewer-schema.json" >/dev/null &&
    grep -q 'passes_completed' "$ROOT/hooks/reviewer-rules.md" &&
    grep -q 'assistant_tail_quote' "$ROOT/hooks/reviewer-rules.md"
}

test_compose_reviewer_prompt_uses_codex_sources() {
  local out
  out="$TMP_ROOT/reviewer-prompt.out"

  (
    . "$ROOT/hooks/lib/compose-reviewer-prompt.sh"
    compose_reviewer_prompt "$ROOT/hooks/reviewer-rules.md" >"$out"
  ) || return 1

  grep -q '# CODEX.md' "$out" &&
    grep -q '# stop-checklist.md' "$out" &&
    grep -q 'Claim Verification' "$out" &&
    ! grep -Eq '[.]claude' "$out"
}

test_reviewer_filter_keeps_real_rules_and_drops_fabricated_rules() {
  (
    . "$ROOT/hooks/lib/reviewer-filter.sh"
    REVIEWER_FILTER_CORPUS_FILES="$ROOT/hooks/stop-checklist.md"
    kept=$(filter_violations '{"verdict":"fail","violations":[{"rule":"Commit this session completed changes before stopping.","evidence":"example"}]}')
    dropped=$(filter_violations '{"verdict":"fail","violations":[{"rule":"Always whistle three times before stopping.","evidence":"example"}]}')
    [ "$(printf '%s' "$kept" | jq -r '.verdict')" = "fail" ] &&
      [ "$(printf '%s' "$kept" | jq '.violations | length')" = "1" ] &&
      [ "$(printf '%s' "$dropped" | jq -r '.verdict')" = "pass" ] &&
      [ "$(printf '%s' "$dropped" | jq '.violations | length')" = "0" ]
  )
}

test_reviewer_filter_keeps_user_history_agreement_rules() {
  local body
  body="$TMP_ROOT/reviewer-filter-user-history.md"
  cat >"$body" <<'EOF'
## USER_HISTORY

<entry>USER: Always run bash hooks/tests/run.sh before stopping.</entry>

## CURRENT_TURN

<entry>ASSISTANT: I skipped it.</entry>
<entry>ASSISTANT: I skipped it because the database migration failed.</entry>
EOF

  (
    . "$ROOT/hooks/lib/reviewer-filter.sh"
    REVIEWER_FILTER_CORPUS_FILES="$ROOT/hooks/stop-checklist.md"
    kept=$(filter_violations '{"verdict":"fail","violations":[{"rule":"Always run bash hooks/tests/run.sh before stopping.","evidence":"I skipped it."}]}' "$body")
    paraphrased=$(filter_violations '{"verdict":"fail","violations":[{"rule":"You must execute the requested hook test suite before ending the turn.","evidence":"I skipped it."}]}' "$body")
    fabricated=$(filter_violations '{"verdict":"fail","violations":[{"rule":"Always whistle three times before stopping.","evidence":"I skipped it."}]}' "$body")
    current_copy=$(filter_violations '{"verdict":"fail","violations":[{"rule":"I skipped it because the database migration failed.","evidence":"I skipped it because the database migration failed."}]}' "$body")
    [ "$(printf '%s' "$kept" | jq -r '.verdict')" = "fail" ] &&
      [ "$(printf '%s' "$kept" | jq '.violations | length')" = "1" ] &&
      [ "$(printf '%s' "$paraphrased" | jq -r '.verdict')" = "fail" ] &&
      [ "$(printf '%s' "$paraphrased" | jq '.violations | length')" = "1" ] &&
      [ "$(printf '%s' "$fabricated" | jq -r '.verdict')" = "pass" ] &&
      [ "$(printf '%s' "$fabricated" | jq '.violations | length')" = "0" ] &&
      [ "$(printf '%s' "$current_copy" | jq -r '.verdict')" = "pass" ] &&
      [ "$(printf '%s' "$current_copy" | jq '.violations | length')" = "0" ]
  )
}

test_system_reviewer_slices_sanitized_codex_transcript() {
  local proof_root input out transcript body
  proof_root="$(fresh_proof_root reviewer-slice)"
  transcript="$(main_reviewer_transcript_path)"
  install_reviewer_transcript_fixture "$FIXTURES/reviewer-main-transcript.jsonl" "$transcript" || return 1
  input="$TMP_ROOT/reviewer-slice.json"
  jq --arg cwd "$ROOT" --arg transcript "$transcript" \
    '.cwd = $cwd | .transcript_path = $transcript' "$FIXTURES/stop-basic.json" >"$input"
  out="$TMP_ROOT/reviewer-slice.out"
  body="$TMP_ROOT/reviewer-slice-body.md"

  run_hook "$out" "$ROOT/hooks/system-prompt-reviewer.sh" "$input" \
    CODEX_PROOF_ROOT="$proof_root" \
    CODEX_STOP_REVIEWER="ollama:http://127.0.0.1:11434:qwen3:4b" \
    CODEX_REVIEWER_FAKE_RESULT='{"assistant_tail_quote":"Done.","passes_completed":["tail","tools","checklist","agreements"],"verdict":"pass","violations":[]}' \
    CODEX_REVIEWER_DEBUG_BODY_PATH="$body" || return 1

  expect_no_output "$out" &&
    grep -q '## USER_HISTORY' "$body" &&
    grep -q 'Earlier request: inspect the hook config.' "$body" &&
    grep -q '## CURRENT_TURN' "$body" &&
    grep -q 'Current request: implement the Codex reviewer hook.' "$body" &&
    grep -q 'TOOL_RESULT:' "$body" &&
    ! grep -q 'Earlier response should not appear in USER_HISTORY.' "$body"
}

write_fake_ps_with_secrets() {
  local dir="$1"
  local openai_key password bearer_token aws_access_key github_token
  mkdir -p "$dir" || return 1
  openai_key="$(redaction_fixture_value openai-api-key)" || return 1
  password="$(redaction_fixture_value password)" || return 1
  bearer_token="$(redaction_fixture_value bearer-token)" || return 1
  aws_access_key="$(redaction_fixture_value aws-access-key)" || return 1
  github_token="$(redaction_fixture_value github-token)" || return 1

  cat >"$dir/ps" <<SH
#!/usr/bin/env bash
cat <<'PS'
101 1 10 S python worker.py --api-key=$openai_key --password $password Authorization: Bearer $bearer_token
102 1 11 S node service.js AWS_SECRET_ACCESS_KEY=$aws_access_key token=$github_token
103 1 12 S /home/streaming/.codex/hooks/system-prompt-reviewer.sh --token should_skip
104 1 13 S ./service --safe flag
PS
SH
  chmod +x "$dir/ps"
}

test_system_reviewer_redacts_background_process_secrets() {
  local proof_root input out transcript body fake_bin background
  local openai_key password bearer_token aws_access_key github_token
  proof_root="$(fresh_proof_root reviewer-redacts-processes)"
  transcript="$(main_reviewer_transcript_path)"
  install_reviewer_transcript_fixture "$FIXTURES/reviewer-main-transcript.jsonl" "$transcript" || return 1
  input="$TMP_ROOT/reviewer-redacts-processes.json"
  jq --arg cwd "$ROOT" --arg transcript "$transcript" \
    '.cwd = $cwd | .transcript_path = $transcript' "$FIXTURES/stop-basic.json" >"$input"
  out="$TMP_ROOT/reviewer-redacts-processes.out"
  body="$TMP_ROOT/reviewer-redacts-processes-body.md"
  background="$TMP_ROOT/reviewer-redacts-processes-background.md"
  fake_bin="$TMP_ROOT/fake-ps-bin"
  write_fake_ps_with_secrets "$fake_bin" || return 1
  openai_key="$(redaction_fixture_value openai-api-key)" || return 1
  password="$(redaction_fixture_value password)" || return 1
  bearer_token="$(redaction_fixture_value bearer-token)" || return 1
  aws_access_key="$(redaction_fixture_value aws-access-key)" || return 1
  github_token="$(redaction_fixture_value github-token)" || return 1

  run_hook "$out" "$ROOT/hooks/system-prompt-reviewer.sh" "$input" \
    PATH="$fake_bin:$PATH" CODEX_PROOF_ROOT="$proof_root" \
    CODEX_STOP_REVIEWER="ollama:http://127.0.0.1:11434:qwen3:4b" \
    CODEX_REVIEWER_FAKE_RESULT='{"assistant_tail_quote":"Done.","passes_completed":["tail","tools","checklist","agreements"],"verdict":"pass","violations":[]}' \
    CODEX_REVIEWER_DEBUG_BODY_PATH="$body" || return 1

  awk '/## BACKGROUND_PROCESSES/{flag=1; next} flag{print}' "$body" >"$background"
  expect_no_output "$out" &&
    grep -q '## BACKGROUND_PROCESSES' "$body" &&
    grep -q './service --safe flag' "$background" &&
    grep -q '\[REDACTED\]' "$background" &&
    file_lacks_values "$background" "$openai_key" "$password" "$bearer_token" "$aws_access_key" "$github_token" &&
    ! grep -Eq 'should_skip|system-prompt-reviewer\.sh' "$background"
}

test_system_reviewer_renders_response_item_tool_events() {
  local proof_root input out transcript body
  proof_root="$(fresh_proof_root reviewer-response-item)"
  transcript="$(main_reviewer_transcript_path)"
  install_reviewer_transcript_fixture "$FIXTURES/reviewer-response-item-transcript.jsonl" "$transcript" || return 1
  input="$TMP_ROOT/reviewer-response-item.json"
  jq --arg cwd "$ROOT" --arg transcript "$transcript" \
    '.cwd = $cwd | .transcript_path = $transcript' "$FIXTURES/stop-basic.json" >"$input"
  out="$TMP_ROOT/reviewer-response-item.out"
  body="$TMP_ROOT/reviewer-response-item-body.md"

  run_hook "$out" "$ROOT/hooks/system-prompt-reviewer.sh" "$input" \
    CODEX_PROOF_ROOT="$proof_root" \
    CODEX_STOP_REVIEWER="ollama:http://127.0.0.1:11434:qwen3:4b" \
    CODEX_REVIEWER_FAKE_RESULT='{"assistant_tail_quote":"Done.","passes_completed":["tail","tools","checklist","agreements"],"verdict":"pass","violations":[]}' \
    CODEX_REVIEWER_DEBUG_BODY_PATH="$body" || return 1

  expect_no_output "$out" &&
    grep -Fq 'ASSISTANT: [tool_use=functions.exec_command input={"command":"sed -n' "$body" &&
    grep -q 'TOOL_RESULT:' "$body" &&
    grep -q 'hooks/system-prompt-reviewer.sh' "$body"
}

test_stop_reviewer_blocks_main_session_fail_verdict() {
  local proof_root input out transcript
  proof_root="$(fresh_proof_root stop-reviewer-block)"
  transcript="$(main_reviewer_transcript_path)"
  install_reviewer_transcript_fixture "$FIXTURES/reviewer-main-transcript.jsonl" "$transcript" || return 1
  input="$TMP_ROOT/stop-reviewer-block.json"
  jq --arg cwd "$ROOT" --arg transcript "$transcript" \
    '.cwd = $cwd | .transcript_path = $transcript' "$FIXTURES/stop-basic.json" >"$input"
  out="$TMP_ROOT/stop-reviewer-block.out"

  run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$input" \
    CODEX_PROOF_ROOT="$proof_root" \
    CODEX_STOP_REVIEWER="ollama:http://127.0.0.1:11434:qwen3:4b" \
    CODEX_REVIEWER_FAKE_RESULT='{"assistant_tail_quote":"Done.","passes_completed":["tail","tools","checklist","agreements"],"verdict":"fail","violations":[{"rule":"Commit this session completed changes before stopping.","evidence":"Done."}]}' || return 1

  is_stop_block "$out" &&
    json_field_contains "$out" '.reason // empty' "External compliance reviewer" &&
    json_field_contains "$out" '.reason // empty' "Commit this session"
}

test_stop_reviewer_pass_verdict_continues_to_proof_gate() {
  local proof_root input out transcript
  proof_root="$(fresh_proof_root stop-reviewer-pass)"
  transcript="$(main_reviewer_transcript_path)"
  install_reviewer_transcript_fixture "$FIXTURES/reviewer-main-transcript.jsonl" "$transcript" || return 1
  input="$TMP_ROOT/stop-reviewer-pass.json"
  jq --arg cwd "$ROOT" --arg transcript "$transcript" \
    '.cwd = $cwd | .transcript_path = $transcript' "$FIXTURES/stop-basic.json" >"$input"
  out="$TMP_ROOT/stop-reviewer-pass.out"

  run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$input" \
    CODEX_PROOF_ROOT="$proof_root" \
    CODEX_STOP_REVIEWER="ollama:http://127.0.0.1:11434:qwen3:4b" \
    CODEX_REVIEWER_FAKE_RESULT='{"assistant_tail_quote":"Done.","passes_completed":["tail","tools","checklist","agreements"],"verdict":"pass","violations":[]}' || return 1

  # Codex intentionally does not port Claude-style pass summary surfacing; pass verdicts stay silent and continue to proof validation.
  is_stop_block "$out" &&
    json_field_contains "$out" '.reason // empty' "Follow" &&
    ! json_field_contains "$out" '.reason // empty' "External compliance reviewer"
}

test_stop_reviewer_fail_open_for_unknown_backend() {
  local proof_root input out transcript
  proof_root="$(fresh_proof_root stop-reviewer-fail-open)"
  transcript="$(main_reviewer_transcript_path)"
  install_reviewer_transcript_fixture "$FIXTURES/reviewer-main-transcript.jsonl" "$transcript" || return 1
  input="$TMP_ROOT/stop-reviewer-fail-open.json"
  jq --arg cwd "$ROOT" --arg transcript "$transcript" \
    '.cwd = $cwd | .transcript_path = $transcript' "$FIXTURES/stop-basic.json" >"$input"
  out="$TMP_ROOT/stop-reviewer-fail-open.out"

  run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$input" \
    CODEX_PROOF_ROOT="$proof_root" \
    CODEX_STOP_REVIEWER="claude" \
    CODEX_REVIEWER_FAKE_RESULT='{"assistant_tail_quote":"Done.","passes_completed":["tail","tools","checklist","agreements"],"verdict":"fail","violations":[{"rule":"Commit this session completed changes before stopping.","evidence":"Done."}]}' || return 1

  is_stop_block "$out" &&
    json_field_contains "$out" '.reason // empty' "Follow" &&
    grep -q 'unknown CODEX_STOP_REVIEWER' "$out.err"
}

test_stop_reviewer_skips_spawned_subagent_transcript() {
  local proof_root input out transcript body
  proof_root="$(fresh_proof_root stop-reviewer-subagent)"
  transcript="$(subagent_transcript_path)"
  write_subagent_transcript "$transcript" || return 1
  input="$TMP_ROOT/stop-reviewer-subagent.json"
  jq --arg cwd "$ROOT" --arg transcript "$transcript" \
    '.cwd = $cwd | .transcript_path = $transcript' "$FIXTURES/stop-basic.json" >"$input"
  out="$TMP_ROOT/stop-reviewer-subagent.out"
  body="$TMP_ROOT/stop-reviewer-subagent-body.md"

  run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$input" \
    HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" \
    CODEX_STOP_REVIEWER="ollama:http://127.0.0.1:11434:qwen3:4b" \
    CODEX_REVIEWER_DEBUG_BODY_PATH="$body" \
    CODEX_REVIEWER_FAKE_RESULT='{"assistant_tail_quote":"Done.","passes_completed":["tail","tools","checklist","agreements"],"verdict":"fail","violations":[{"rule":"Commit this session completed changes before stopping.","evidence":"Done."}]}' || return 1

  json_field_equals "$out" '.continue // false' "true" &&
    [ ! -e "$proof_root/t00-session" ] &&
    [ ! -e "$proof_root/reviewer/t00-session" ] &&
    [ ! -e "$body" ]
}

test_stop_reviewer_timeout_and_hook_wiring() {
  jq -e '
    ([.hooks.Stop[]?.hooks[]? | select((.command // "") | endswith("/stop-gate.sh")) | .timeout] | all(. >= 240)) and
    ([.hooks.Stop[]?.hooks[]?.command] | all((endswith("/system-prompt-reviewer.sh") | not))) and
    ([.hooks.PreToolUse[]?.hooks[]?.command] | any(endswith("/edit-bash-pre-reviewer.sh"))) and
    ([.hooks.PreToolUse[]? | select(.matcher == "^Bash$") | .hooks[]?.command] | any(endswith("/edit-bash-pre-reviewer.sh"))) and
    ([.hooks.PreToolUse[]? | select(.matcher == "^apply_patch$") | .hooks[]?.command] | any(endswith("/edit-bash-pre-reviewer.sh"))) and
    ([.hooks.PreToolUse[]? | select(.matcher == "^(Edit|Write|MultiEdit)$") | .hooks[]?.command] | any(endswith("/edit-bash-pre-reviewer.sh")))
  ' "$ROOT/hooks.json" >/dev/null
}

test_pre_reviewer_denies_first_tool_call_once_per_turn() {
  local proof_root input out transcript
  proof_root="$(fresh_proof_root pre-reviewer-first)"
  transcript="$(main_reviewer_transcript_path)"
  install_reviewer_transcript_fixture "$FIXTURES/reviewer-main-transcript.jsonl" "$transcript" || return 1
  input="$TMP_ROOT/pre-reviewer-first.json"
  jq --arg cwd "$ROOT" --arg transcript "$transcript" \
    '.cwd = $cwd | .transcript_path = $transcript' "$FIXTURES/pre-reviewer-bash.json" >"$input"
  out="$TMP_ROOT/pre-reviewer-first.out"

  run_hook "$out" "$ROOT/hooks/edit-bash-pre-reviewer.sh" "$input" \
    HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" \
    CODEX_EDIT_PRE_REVIEWER="ollama:http://127.0.0.1:11434:qwen3:4b" \
    CODEX_PRE_REVIEWER_FAKE_RESULT='{"verdict":"deny","reason":"Load the matching skill first."}' || return 1
  is_pretool_deny "$out" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "Load the matching skill first" || return 1

  out="$TMP_ROOT/pre-reviewer-first-repeat.out"
  run_hook "$out" "$ROOT/hooks/edit-bash-pre-reviewer.sh" "$input" \
    HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" \
    CODEX_EDIT_PRE_REVIEWER="ollama:http://127.0.0.1:11434:qwen3:4b" \
    CODEX_PRE_REVIEWER_FAKE_RESULT='{"verdict":"deny","reason":"Load the matching skill first."}' || return 1
  expect_no_output "$out"
}

write_pre_reviewer_secret_transcript() {
  local path="$1"
  local openai_key password bearer_token github_token slack_token aws_access_key google_key private_key content
  mkdir -p "$(dirname "$path")" || return 1
  openai_key="$(redaction_fixture_value openai-api-key)" || return 1
  password="$(redaction_fixture_value password)" || return 1
  bearer_token="$(redaction_fixture_value bearer-token)" || return 1
  github_token="$(redaction_fixture_value github-token)" || return 1
  slack_token="$(redaction_fixture_value slack-token)" || return 1
  aws_access_key="$(redaction_fixture_value aws-access-key)" || return 1
  google_key="$(redaction_fixture_value google-api-key)" || return 1
  private_key="$(redaction_fixture_value private-key-block)" || return 1
  content=$(printf 'Use OPENAI_API_KEY=%s and password=%s with Authorization: Bearer %s. GitHub token %s, Slack token %s, AWS key %s, Google key %s, and this key:\n%s' \
    "$openai_key" "$password" "$bearer_token" "$github_token" "$slack_token" "$aws_access_key" "$google_key" "$private_key")

  {
    jq -nc '{"timestamp":"2026-05-04T00:00:00.000Z","type":"session_meta","payload":{"id":"t00-session","source":"cli"}}'
    jq -nc --arg content "$content" '{"timestamp":"2026-05-04T00:00:01.000Z","type":"user","message":{"content":$content}}'
  } >"$path"
}

test_pre_reviewer_redacts_user_message_and_tool_input_payload() {
  local proof_root input out transcript body command description
  local openai_key password bearer_token github_token slack_token aws_access_key google_key
  local private_key_begin private_key_material private_key_end
  proof_root="$(fresh_proof_root pre-reviewer-redaction)"
  transcript="$TMP_ROOT/home/.codex/sessions/codex-hooks-test-pre-reviewer-secrets.jsonl"
  write_pre_reviewer_secret_transcript "$transcript" || return 1
  input="$TMP_ROOT/pre-reviewer-redaction.json"
  openai_key="$(redaction_fixture_value openai-api-key)" || return 1
  password="$(redaction_fixture_value password)" || return 1
  bearer_token="$(redaction_fixture_value bearer-token)" || return 1
  github_token="$(redaction_fixture_value github-token)" || return 1
  slack_token="$(redaction_fixture_value slack-token)" || return 1
  aws_access_key="$(redaction_fixture_value aws-access-key)" || return 1
  google_key="$(redaction_fixture_value google-api-key)" || return 1
  private_key_begin="$(redaction_fixture_value private-key-begin)" || return 1
  private_key_material="$(redaction_fixture_value private-key-material)" || return 1
  private_key_end="$(redaction_fixture_value private-key-end)" || return 1
  command=$(printf 'curl -H "Authorization: Bearer %s" --password %s --api-key=%s https://example.invalid' \
    "$bearer_token" "$password" "$openai_key")
  description=$(printf 'uses %s %s %s %s' "$github_token" "$slack_token" "$aws_access_key" "$google_key")
  jq --arg cwd "$ROOT" --arg transcript "$transcript" \
    --arg command "$command" --arg description "$description" \
    '.cwd = $cwd | .transcript_path = $transcript | .tool_input.command = $command | .tool_input.description = $description' \
    "$FIXTURES/pre-reviewer-bash.json" >"$input"
  out="$TMP_ROOT/pre-reviewer-redaction.out"
  body="$TMP_ROOT/pre-reviewer-redaction-body.md"

  run_hook "$out" "$ROOT/hooks/edit-bash-pre-reviewer.sh" "$input" \
    HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" \
    CODEX_EDIT_PRE_REVIEWER="ollama:http://127.0.0.1:11434:qwen3:4b" \
    CODEX_PRE_REVIEWER_DEBUG_BODY_PATH="$body" \
    CODEX_PRE_REVIEWER_FAKE_RESULT='{"verdict":"allow","reason":"ok"}' || return 1

  expect_no_output "$out" &&
    [ -s "$body" ] &&
    grep -q '\[REDACTED\]' "$body" &&
    file_lacks_values "$body" "$openai_key" "$password" "$bearer_token" "$github_token" "$slack_token" \
      "$aws_access_key" "$google_key" "$private_key_begin" "$private_key_material" "$private_key_end"
}

test_pre_reviewer_allows_stop_reviewer_bypass_command() {
  local proof_root input out transcript command
  proof_root="$(fresh_proof_root pre-reviewer-stop-bypass)"
  transcript="$(main_reviewer_transcript_path)"
  install_reviewer_transcript_fixture "$FIXTURES/reviewer-main-transcript.jsonl" "$transcript" || return 1
  command="touch $proof_root/reviewer/t00-session/bypass"
  input="$TMP_ROOT/pre-reviewer-stop-bypass.json"
  jq --arg cwd "$ROOT" --arg transcript "$transcript" --arg command "$command" \
    '.cwd = $cwd | .transcript_path = $transcript | .tool_input.command = $command' \
    "$FIXTURES/pre-reviewer-bash.json" >"$input"
  out="$TMP_ROOT/pre-reviewer-stop-bypass.out"

  run_hook "$out" "$ROOT/hooks/edit-bash-pre-reviewer.sh" "$input" \
    HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" \
    CODEX_EDIT_PRE_REVIEWER="ollama:http://127.0.0.1:11434:qwen3:4b" \
    CODEX_PRE_REVIEWER_FAKE_RESULT='{"verdict":"deny","reason":"Load the matching skill first."}' || return 1

  expect_no_output "$out"
}

test_pre_reviewer_allows_after_prior_tool_call() {
  local proof_root input out transcript
  proof_root="$(fresh_proof_root pre-reviewer-prior)"
  transcript="$(main_reviewer_transcript_path)"
  install_reviewer_transcript_fixture "$FIXTURES/reviewer-prior-tool-transcript.jsonl" "$transcript" || return 1
  input="$TMP_ROOT/pre-reviewer-prior.json"
  jq --arg cwd "$ROOT" --arg transcript "$transcript" \
    '.cwd = $cwd | .transcript_path = $transcript' "$FIXTURES/pre-reviewer-bash.json" >"$input"
  out="$TMP_ROOT/pre-reviewer-prior.out"

  run_hook "$out" "$ROOT/hooks/edit-bash-pre-reviewer.sh" "$input" \
    HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" \
    CODEX_EDIT_PRE_REVIEWER="ollama:http://127.0.0.1:11434:qwen3:4b" \
    CODEX_PRE_REVIEWER_FAKE_RESULT='{"verdict":"deny","reason":"Load the matching skill first."}' || return 1

  expect_no_output "$out"
}

test_pre_reviewer_allows_after_prior_response_item_tool_call() {
  local proof_root input out transcript
  proof_root="$(fresh_proof_root pre-reviewer-prior-response-item)"
  transcript="$(main_reviewer_transcript_path)"
  install_reviewer_transcript_fixture "$FIXTURES/reviewer-prior-response-item-tool-transcript.jsonl" "$transcript" || return 1
  input="$TMP_ROOT/pre-reviewer-prior-response-item.json"
  jq --arg cwd "$ROOT" --arg transcript "$transcript" \
    '.cwd = $cwd | .transcript_path = $transcript' "$FIXTURES/pre-reviewer-bash.json" >"$input"
  out="$TMP_ROOT/pre-reviewer-prior-response-item.out"

  run_hook "$out" "$ROOT/hooks/edit-bash-pre-reviewer.sh" "$input" \
    HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" \
    CODEX_EDIT_PRE_REVIEWER="ollama:http://127.0.0.1:11434:qwen3:4b" \
    CODEX_PRE_REVIEWER_FAKE_RESULT='{"verdict":"deny","reason":"Load the matching skill first."}' || return 1

  expect_no_output "$out"
}

test_pre_reviewer_skips_spawned_subagent_transcript() {
  local proof_root input out transcript
  proof_root="$(fresh_proof_root pre-reviewer-subagent)"
  transcript="$(subagent_transcript_path)"
  write_subagent_transcript "$transcript" || return 1
  input="$TMP_ROOT/pre-reviewer-subagent.json"
  jq --arg cwd "$ROOT" --arg transcript "$transcript" \
    '.cwd = $cwd | .transcript_path = $transcript' "$FIXTURES/pre-reviewer-bash.json" >"$input"
  out="$TMP_ROOT/pre-reviewer-subagent.out"

  run_hook "$out" "$ROOT/hooks/edit-bash-pre-reviewer.sh" "$input" \
    HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" \
    CODEX_EDIT_PRE_REVIEWER="ollama:http://127.0.0.1:11434:qwen3:4b" \
    CODEX_PRE_REVIEWER_FAKE_RESULT='{"verdict":"deny","reason":"Load the matching skill first."}' || return 1

  expect_no_output "$out"
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
    [
      .hooks.PreToolUse[]?
      | select(any(.hooks[]?; (.command // "") | endswith("/eci-active-gate.sh")))
      | .matcher
      | strings
    ] | join("|")
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

test_validate_edit_write_blocks_direct_edit_plan_path() {
  local out
  out="$TMP_ROOT/edit-write-plan-edit.out"
  run_hook "$out" "$ROOT/hooks/validate-edit-write.sh" "$FIXTURES/validate-edit-write-plan-edit.json" || return 1
  is_pretool_deny "$out" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "docs/plans"
}

test_validate_edit_write_blocks_direct_write_plan_path() {
  local out
  out="$TMP_ROOT/edit-write-plan-write.out"
  run_hook "$out" "$ROOT/hooks/validate-edit-write.sh" "$FIXTURES/validate-edit-write-plan-write.json" || return 1
  is_pretool_deny "$out" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "docs/plans"
}

test_validate_edit_write_blocks_direct_multiedit_plan_path() {
  local out
  out="$TMP_ROOT/edit-write-plan-multiedit.out"
  run_hook "$out" "$ROOT/hooks/validate-edit-write.sh" "$FIXTURES/validate-edit-write-plan-multiedit.json" || return 1
  is_pretool_deny "$out" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "docs/plans"
}

test_validate_edit_write_blocks_direct_edit_local_gomod_replace() {
  local out
  out="$TMP_ROOT/edit-write-gomod-edit.out"
  run_hook "$out" "$ROOT/hooks/validate-edit-write.sh" "$FIXTURES/validate-edit-write-gomod-local-edit.json" || return 1
  is_pretool_deny "$out" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "local relative replace"
}

test_validate_edit_write_blocks_direct_write_local_gomod_replace() {
  local out
  out="$TMP_ROOT/edit-write-gomod-write.out"
  run_hook "$out" "$ROOT/hooks/validate-edit-write.sh" "$FIXTURES/validate-edit-write-gomod-local-write.json" || return 1
  is_pretool_deny "$out" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "local relative replace"
}

test_validate_edit_write_blocks_direct_multiedit_local_gomod_replace() {
  local out
  out="$TMP_ROOT/edit-write-gomod-multiedit.out"
  run_hook "$out" "$ROOT/hooks/validate-edit-write.sh" "$FIXTURES/validate-edit-write-gomod-local-multiedit.json" || return 1
  is_pretool_deny "$out" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "local relative replace"
}

test_validate_edit_write_allows_unrelated_non_plan_edit() {
  local out
  out="$TMP_ROOT/edit-write-allow-unrelated.out"
  run_hook "$out" "$ROOT/hooks/validate-edit-write.sh" "$FIXTURES/validate-edit-write-allow-unrelated-edit.json" || return 1
  expect_no_output "$out"
}

test_validate_edit_write_allows_remote_write_gomod_replace() {
  local out
  out="$TMP_ROOT/edit-write-allow-remote-write.out"
  run_hook "$out" "$ROOT/hooks/validate-edit-write.sh" "$FIXTURES/validate-edit-write-allow-remote-write.json" || return 1
  expect_no_output "$out"
}

test_validate_edit_write_allows_remote_multiedit_gomod_replace() {
  local out
  out="$TMP_ROOT/edit-write-allow-remote-multiedit.out"
  run_hook "$out" "$ROOT/hooks/validate-edit-write.sh" "$FIXTURES/validate-edit-write-allow-remote-multiedit.json" || return 1
  expect_no_output "$out"
}

test_edit_write_hook_config_is_split_and_preserves_gates() {
  jq -e '
    def commands_for($matcher):
      [.hooks.PreToolUse[]? | select(.matcher == $matcher) | .hooks[]?.command];
    def has($commands; $suffix):
      any($commands[]?; endswith($suffix));

    (commands_for("^apply_patch$") as $apply
      | commands_for("^(Edit|Write|MultiEdit)$") as $direct
      | has($apply; "/validate-apply-patch.sh") and
        (has($apply; "/validate-edit-write.sh") | not) and
        has($apply; "/security-reminder.py") and
        has($apply; "/eci-active-gate.sh") and
        has($apply; "/ate-orchestrator-gate.sh") and
        has($apply; "/edit-bash-pre-reviewer.sh") and
        has($direct; "/validate-edit-write.sh") and
        (has($direct; "/validate-apply-patch.sh") | not) and
        has($direct; "/security-reminder.py") and
        has($direct; "/eci-active-gate.sh") and
        has($direct; "/ate-orchestrator-gate.sh") and
        has($direct; "/edit-bash-pre-reviewer.sh"))
  ' "$ROOT/hooks.json" >/dev/null
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

test_validate_apply_patch_blocks_block_form_local_gomod_replace() {
  local out
  out="$TMP_ROOT/apply-patch-gomod-block.out"
  run_hook "$out" "$ROOT/hooks/validate-apply-patch.sh" "$FIXTURES/validate-apply-patch-gomod-block.json" || return 1
  is_pretool_deny "$out" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "local relative replace"
}

test_validate_apply_patch_allows_remote_gomod_replace() {
  local out
  out="$TMP_ROOT/apply-patch-gomod-remote.out"
  run_hook "$out" "$ROOT/hooks/validate-apply-patch.sh" "$FIXTURES/validate-apply-patch-gomod-remote.json" || return 1
  expect_no_output "$out"
}

test_validate_apply_patch_allows_unrelated_non_plan_edit() {
  local out
  out="$TMP_ROOT/apply-patch-unrelated.out"
  run_hook "$out" "$ROOT/hooks/validate-apply-patch.sh" "$FIXTURES/validate-apply-patch-unrelated.json" || return 1
  expect_no_output "$out"
}

test_validate_bash_blocks_bare_go_test() {
  local out
  out="$TMP_ROOT/bash-go-test-bare.out"
  run_hook "$out" "$ROOT/hooks/validate-bash.sh" "$FIXTURES/validate-bash-go-test-bare.json" || return 1
  is_pretool_deny "$out" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "captured to a file"
}

test_validate_bash_blocks_go_test_count_one() {
  local out
  out="$TMP_ROOT/bash-go-test-count.out"
  run_hook "$out" "$ROOT/hooks/validate-bash.sh" "$FIXTURES/validate-bash-go-test-count.json" || return 1
  is_pretool_deny "$out" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "-count=1"
}

test_validate_bash_allows_redirected_go_test() {
  local out
  out="$TMP_ROOT/bash-go-test-redirect.out"
  run_hook "$out" "$ROOT/hooks/validate-bash.sh" "$FIXTURES/validate-bash-go-test-redirect.json" || return 1
  expect_no_output "$out"
}

test_validate_bash_allows_go_test_tee() {
  local out
  out="$TMP_ROOT/bash-go-test-tee.out"
  run_hook "$out" "$ROOT/hooks/validate-bash.sh" "$FIXTURES/validate-bash-go-test-tee.json" || return 1
  expect_no_output "$out"
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

test_stop_gate_blocks_clean_scan_empty_source() {
  local proof_root input out
  proof_root="$(fresh_proof_root stop-clean-empty-source)"
  install_proof_fixture "$proof_root" "$FIXTURES/proof-audit-clean-empty-source.md"
  input="$TMP_ROOT/stop-clean-empty-source.json"
  with_cwd_fixture "$FIXTURES/stop-basic.json" "$input"
  out="$TMP_ROOT/stop-clean-empty-source.out"

  run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$input" CODEX_PROOF_ROOT="$proof_root" || return 1
  is_stop_block "$out" &&
    json_field_contains "$out" '.reason // empty' "empty audit source" &&
    stop_reason_has_proof_recovery_paths "$out" "$proof_root"
}

test_stop_gate_blocks_blocker_missing_input() {
  local proof_root input out
  proof_root="$(fresh_proof_root stop-blocker-missing-input)"
  install_proof_fixture "$proof_root" "$FIXTURES/proof-audit-blocker-missing-input.md"
  input="$TMP_ROOT/stop-blocker-missing-input.json"
  with_cwd_fixture "$FIXTURES/stop-basic.json" "$input"
  out="$TMP_ROOT/stop-blocker-missing-input.out"

  run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$input" CODEX_PROOF_ROOT="$proof_root" || return 1
  is_stop_block "$out" &&
    json_field_contains "$out" '.reason // empty' "blocker missing non-empty input" &&
    stop_reason_has_proof_recovery_paths "$out" "$proof_root"
}

test_stop_gate_blocks_blocker_missing_command() {
  local proof_root input out
  proof_root="$(fresh_proof_root stop-blocker-missing-command)"
  install_proof_fixture "$proof_root" "$FIXTURES/proof-audit-blocker-missing-command.md"
  input="$TMP_ROOT/stop-blocker-missing-command.json"
  with_cwd_fixture "$FIXTURES/stop-basic.json" "$input"
  out="$TMP_ROOT/stop-blocker-missing-command.out"

  run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$input" CODEX_PROOF_ROOT="$proof_root" || return 1
  is_stop_block "$out" &&
    json_field_contains "$out" '.reason // empty' "blocker missing non-empty command" &&
    stop_reason_has_proof_recovery_paths "$out" "$proof_root"
}

test_stop_gate_blocks_placeholder_blocker_command() {
  local proof_root input out
  proof_root="$(fresh_proof_root stop-blocker-placeholder)"
  install_proof_fixture "$proof_root" "$FIXTURES/proof-audit-blocker-placeholder-command.md"
  input="$TMP_ROOT/stop-blocker-placeholder.json"
  with_cwd_fixture "$FIXTURES/stop-basic.json" "$input"
  out="$TMP_ROOT/stop-blocker-placeholder.out"

  run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$input" CODEX_PROOF_ROOT="$proof_root" || return 1
  is_stop_block "$out" &&
    json_field_contains "$out" '.reason // empty' "blocker command is a placeholder" &&
    stop_reason_has_proof_recovery_paths "$out" "$proof_root"
}

test_stop_gate_blocks_fake_audit_commit() {
  local proof_root input out repo
  proof_root="$(fresh_proof_root stop-fake-commit)"
  repo="$(make_git_repo stop-fake-commit)" || return 1
  install_proof_fixture "$proof_root" "$FIXTURES/proof-audit-fake-commit.md"
  input="$TMP_ROOT/stop-fake-commit.json"
  with_cwd_path "$FIXTURES/stop-basic.json" "$input" "$repo"
  out="$TMP_ROOT/stop-fake-commit.out"

  run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$input" CODEX_PROOF_ROOT="$proof_root" || return 1
  is_stop_block "$out" &&
    json_field_contains "$out" '.reason // empty' "unreachable audit commit" &&
    stop_reason_has_proof_recovery_paths "$out" "$proof_root"
}

test_stop_gate_validates_proof_when_stop_hook_active() {
  local proof_root input out
  proof_root="$(fresh_proof_root stop-active-validates-proof)"
  install_proof_fixture "$proof_root" "$FIXTURES/proof-missing-sections.md"
  input="$TMP_ROOT/stop-active-validates-proof.json"
  jq --arg cwd "$ROOT" '.cwd = $cwd | .stop_hook_active = true' "$FIXTURES/stop-basic.json" >"$input"
  out="$TMP_ROOT/stop-active-validates-proof.out"

  run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$input" CODEX_PROOF_ROOT="$proof_root" || return 1
  is_stop_block "$out" &&
    json_field_contains "$out" '.reason // empty' "missing required sections" &&
    stop_reason_has_proof_recovery_paths "$out" "$proof_root"
}

test_stop_gate_blocks_identical_audit_without_rescanned() {
  local proof_root input out repo
  proof_root="$(fresh_proof_root stop-identical-no-rescan)"
  repo="$(make_git_repo stop-identical-no-rescan)" || return 1
  accept_stop_proof "$proof_root" "$repo" "$FIXTURES/proof-complete.md" "stop-identical-no-rescan-first" || return 1
  install_proof_fixture "$proof_root" "$FIXTURES/proof-complete.md"
  input="$TMP_ROOT/stop-identical-no-rescan.json"
  with_cwd_path "$FIXTURES/stop-basic.json" "$input" "$repo"
  out="$TMP_ROOT/stop-identical-no-rescan.out"

  run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$input" CODEX_PROOF_ROOT="$proof_root" || return 1
  is_stop_block "$out" &&
    json_field_contains "$out" '.reason // empty' "missing/invalid rescanned:" &&
    stop_reason_has_proof_recovery_paths "$out" "$proof_root"
}

test_stop_gate_accepts_identical_audit_with_rescanned() {
  local proof_root input out repo
  proof_root="$(fresh_proof_root stop-identical-rescanned)"
  repo="$(make_git_repo stop-identical-rescanned)" || return 1
  accept_stop_proof "$proof_root" "$repo" "$FIXTURES/proof-complete-rescanned.md" "stop-identical-rescanned-first" || return 1
  install_proof_fixture "$proof_root" "$FIXTURES/proof-complete-rescanned.md"
  input="$TMP_ROOT/stop-identical-rescanned.json"
  with_cwd_path "$FIXTURES/stop-basic.json" "$input" "$repo"
  out="$TMP_ROOT/stop-identical-rescanned.out"

  run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$input" CODEX_PROOF_ROOT="$proof_root" || return 1
  is_stop_block "$out" &&
    json_field_contains "$out" '.reason // empty' "Verification proof accepted"
}

test_stop_gate_blocks_dirty_identical_audit() {
  local proof_root input out repo
  proof_root="$(fresh_proof_root stop-dirty-identical)"
  repo="$(make_git_repo stop-dirty-identical)" || return 1
  accept_stop_proof "$proof_root" "$repo" "$FIXTURES/proof-complete.md" "stop-dirty-identical-first" || return 1
  printf 'dirty\n' >>"$repo/file.txt"
  install_proof_fixture "$proof_root" "$FIXTURES/proof-complete.md"
  input="$TMP_ROOT/stop-dirty-identical.json"
  with_cwd_path "$FIXTURES/stop-basic.json" "$input" "$repo"
  out="$TMP_ROOT/stop-dirty-identical.out"

  run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$input" CODEX_PROOF_ROOT="$proof_root" || return 1
  is_stop_block "$out" &&
    json_field_contains "$out" '.reason // empty' "identical audit plus dirty tree" &&
    stop_reason_has_proof_recovery_paths "$out" "$proof_root"
}

test_stop_gate_blocks_identical_audit_after_head_advance() {
  local proof_root input out repo
  proof_root="$(fresh_proof_root stop-identical-head-advance)"
  repo="$(make_git_repo stop-identical-head-advance)" || return 1
  accept_stop_proof "$proof_root" "$repo" "$FIXTURES/proof-complete.md" "stop-identical-head-advance-first" || return 1
  printf 'new\n' >>"$repo/file.txt"
  git -C "$repo" add file.txt || return 1
  git -C "$repo" commit -qm "advance" || return 1
  install_proof_fixture "$proof_root" "$FIXTURES/proof-complete.md"
  input="$TMP_ROOT/stop-identical-head-advance.json"
  with_cwd_path "$FIXTURES/stop-basic.json" "$input" "$repo"
  out="$TMP_ROOT/stop-identical-head-advance.out"

  run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$input" CODEX_PROOF_ROOT="$proof_root" || return 1
  is_stop_block "$out" &&
    json_field_contains "$out" '.reason // empty' "HEAD advance" &&
    stop_reason_has_proof_recovery_paths "$out" "$proof_root"
}

test_stop_gate_allows_same_session_history_across_repos() {
  local proof_root input out repo_a repo_b
  proof_root="$(fresh_proof_root stop-cross-repo-history)"
  repo_a="$(make_git_repo stop-cross-repo-history-a)" || return 1
  repo_b="$(make_git_repo stop-cross-repo-history-b)" || return 1
  printf 'repo-b\n' >>"$repo_b/file.txt"
  git -C "$repo_b" add file.txt || return 1
  git -C "$repo_b" commit -qm "repo b advance" || return 1

  accept_stop_proof "$proof_root" "$repo_a" "$FIXTURES/proof-complete.md" "stop-cross-repo-history-first" || return 1
  install_proof_fixture "$proof_root" "$FIXTURES/proof-complete.md"
  input="$TMP_ROOT/stop-cross-repo-history.json"
  with_cwd_path "$FIXTURES/stop-basic.json" "$input" "$repo_b"
  out="$TMP_ROOT/stop-cross-repo-history.out"

  run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$input" CODEX_PROOF_ROOT="$proof_root" || return 1
  is_stop_block "$out" &&
    json_field_contains "$out" '.reason // empty' "Verification proof accepted"
}

test_stop_gate_blocks_preexisting_commit_after_head_advance() {
  local proof_root input out repo old_commit
  proof_root="$(fresh_proof_root stop-old-commit-head-advance)"
  repo="$(make_git_repo stop-old-commit-head-advance)" || return 1
  old_commit="$(git -C "$repo" rev-parse HEAD)" || return 1
  accept_stop_proof "$proof_root" "$repo" "$FIXTURES/proof-complete.md" "stop-old-commit-head-advance-first" || return 1
  printf 'new\n' >>"$repo/file.txt"
  git -C "$repo" add file.txt || return 1
  git -C "$repo" commit -qm "advance" || return 1
  mkdir -p "$proof_root/t00-session" || return 1
  sed "s/__OLD_COMMIT__/$old_commit/g" "$FIXTURES/proof-audit-old-commit-template.md" >"$proof_root/t00-session/proof.md"
  input="$TMP_ROOT/stop-old-commit-head-advance.json"
  with_cwd_path "$FIXTURES/stop-basic.json" "$input" "$repo"
  out="$TMP_ROOT/stop-old-commit-head-advance.out"

  run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$input" CODEX_PROOF_ROOT="$proof_root" || return 1
  is_stop_block "$out" &&
    json_field_contains "$out" '.reason // empty' "old-only commit range" &&
    stop_reason_has_proof_recovery_paths "$out" "$proof_root"
}

test_stop_gate_adds_loop_reminder_after_five_blocks() {
  local proof_root input out i
  proof_root="$(fresh_proof_root stop-loop-reminder)"
  input="$TMP_ROOT/stop-loop-reminder.json"
  with_cwd_fixture "$FIXTURES/stop-basic.json" "$input"
  out="$TMP_ROOT/stop-loop-reminder.out"

  for i in 1 2 3 4 5; do
    run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$input" CODEX_PROOF_ROOT="$proof_root" || return 1
  done

  is_stop_block "$out" &&
    json_field_contains "$out" '.reason // empty' "LOOP DETECTED" &&
    json_field_contains "$out" '.reason // empty' "read instructions or stop-checklist" &&
    json_field_contains "$out" '.reason // empty' "write proof" &&
    json_field_contains "$out" '.reason // empty' "stop again" &&
    json_field_contains "$out" '.reason // empty' "identify failing step" &&
    json_field_contains "$out" '.reason // empty' "do not retry same approach"
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

test_audit_sync_checker_ok() {
  local out
  out="$TMP_ROOT/audit-sync-ok.out"
  bash "$ROOT/hooks/check-audit-sync.sh" >"$out" 2>"$out.err" || return 1
  grep -q "check-audit-sync: OK" "$out"
}

test_audit_sync_checker_direct_exec_ok() {
  local out
  out="$TMP_ROOT/audit-sync-direct-ok.out"
  "$ROOT/hooks/check-audit-sync.sh" >"$out" 2>"$out.err" || return 1
  grep -q "check-audit-sync: OK" "$out"
}

test_audit_sync_checker_detects_drift() {
  local hook_dir out status
  hook_dir="$TMP_ROOT/audit-sync-drift"
  mkdir -p "$hook_dir" || return 1
  cp "$ROOT/hooks/check-audit-sync.sh" "$hook_dir/check-audit-sync.sh" || return 1
  cp "$ROOT/hooks/stop-verification.md" "$hook_dir/stop-verification.md" || return 1
  sed '/rescanned:/d' "$ROOT/hooks/stop-checklist.md" >"$hook_dir/stop-checklist.md"
  out="$TMP_ROOT/audit-sync-drift.out"

  bash "$hook_dir/check-audit-sync.sh" >"$out" 2>"$out.err"
  status=$?

  [ "$status" -ne 0 ] &&
    grep -q "rescanned:" "$out"
}

test_audit_sync_checker_fails_when_synced_file_missing() {
  local hook_dir out status
  hook_dir="$TMP_ROOT/audit-sync-missing"
  mkdir -p "$hook_dir" || return 1
  cp "$ROOT/hooks/check-audit-sync.sh" "$hook_dir/check-audit-sync.sh" || return 1
  cp "$ROOT/hooks/stop-verification.md" "$hook_dir/stop-verification.md" || return 1
  out="$TMP_ROOT/audit-sync-missing.out"

  bash "$hook_dir/check-audit-sync.sh" >"$out" 2>"$out.err"
  status=$?

  [ "$status" -ne 0 ] &&
    grep -q "missing required file" "$out.err"
}

run_case "prompt state is silent and records HEAD" \
  test_prompt_state_is_silent_records_head_and_clears_bypass
run_case "prompt state marks /side prompts" \
  test_prompt_state_marks_side_prompt
run_case "prompt state skips state writes for invalid session" \
  test_prompt_state_skips_state_for_invalid_session
run_case "prompt state config is wired without temporary probe" \
  test_prompt_state_config_is_wired_without_probe
run_case "runtime hook probe historical evidence is sanitized" \
  test_runtime_hook_probe_historical_evidence_is_sanitized
run_case "session snapshot saves baseline and clears legacy skip_stop" \
  test_session_snapshot_saves_baseline_and_clears_legacy_skip
run_case "session snapshot skips ephemeral threads" \
  test_session_snapshot_skips_ephemeral_threads
run_case "session snapshot preserves fresh markers in old state dirs" \
  test_session_snapshot_preserves_fresh_markers_in_old_state_dirs
run_case "side session start is silent and binds stop bypass" \
  test_side_session_start_is_silent_and_binds_stop_bypass
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
run_case "reviewer backend parser accepts no-credential backends" \
  test_reviewer_backend_parser_accepts_no_credential_backends
run_case "reviewer backend parser rejects credential backends" \
  test_reviewer_backend_parser_rejects_credential_backends
run_case "reviewer schema matches reviewer rules" \
  test_reviewer_schema_matches_rules
run_case "reviewer prompt composition uses Codex sources" \
  test_compose_reviewer_prompt_uses_codex_sources
run_case "reviewer filter keeps real rules and drops fabricated rules" \
  test_reviewer_filter_keeps_real_rules_and_drops_fabricated_rules
run_case "reviewer filter keeps user-history agreement rules" \
  test_reviewer_filter_keeps_user_history_agreement_rules
run_case "system reviewer slices sanitized Codex transcript" \
  test_system_reviewer_slices_sanitized_codex_transcript
run_case "system reviewer redacts background process secrets" \
  test_system_reviewer_redacts_background_process_secrets
run_case "system reviewer renders response_item tool events" \
  test_system_reviewer_renders_response_item_tool_events
run_case "stop reviewer blocks main-session fail verdict" \
  test_stop_reviewer_blocks_main_session_fail_verdict
run_case "stop reviewer pass verdict continues to proof gate" \
  test_stop_reviewer_pass_verdict_continues_to_proof_gate
run_case "stop reviewer fails open for unknown backend" \
  test_stop_reviewer_fail_open_for_unknown_backend
run_case "stop reviewer skips spawned subagent transcript" \
  test_stop_reviewer_skips_spawned_subagent_transcript
run_case "reviewer timeout and hook wiring are configured" \
  test_stop_reviewer_timeout_and_hook_wiring
run_case "pre reviewer denies first tool call once per turn" \
  test_pre_reviewer_denies_first_tool_call_once_per_turn
run_case "pre reviewer redacts user message and tool input payload" \
  test_pre_reviewer_redacts_user_message_and_tool_input_payload
run_case "pre reviewer allows stop-reviewer bypass command" \
  test_pre_reviewer_allows_stop_reviewer_bypass_command
run_case "pre reviewer allows after prior tool call" \
  test_pre_reviewer_allows_after_prior_tool_call
run_case "pre reviewer allows after prior response_item tool call" \
  test_pre_reviewer_allows_after_prior_response_item_tool_call
run_case "pre reviewer skips spawned subagent transcript" \
  test_pre_reviewer_skips_spawned_subagent_transcript
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
run_case "hooks.json splits apply_patch and direct edit validators while preserving gates" \
  test_edit_write_hook_config_is_split_and_preserves_gates
run_case "ATE gate denies markdown edits for lead role" \
  test_ate_gate_denies_markdown_edits_for_lead
run_case "ATE gate denies markdown edits for coordinator role" \
  test_ate_gate_denies_markdown_edits_for_coordinator
run_case "validate-apply-patch parses tool_input.input plan paths" \
  test_validate_apply_patch_blocks_plan_paths_from_input
run_case "validate-apply-patch blocks Move to plan paths" \
  test_validate_apply_patch_blocks_plan_move_destination
run_case "validate-edit-write blocks direct Edit plan paths" \
  test_validate_edit_write_blocks_direct_edit_plan_path
run_case "validate-edit-write blocks direct Write plan paths" \
  test_validate_edit_write_blocks_direct_write_plan_path
run_case "validate-edit-write blocks direct MultiEdit plan paths" \
  test_validate_edit_write_blocks_direct_multiedit_plan_path
run_case "validate-edit-write blocks direct Edit go.mod local replace" \
  test_validate_edit_write_blocks_direct_edit_local_gomod_replace
run_case "validate-edit-write blocks direct Write go.mod local replace" \
  test_validate_edit_write_blocks_direct_write_local_gomod_replace
run_case "validate-edit-write blocks direct MultiEdit go.mod local replace" \
  test_validate_edit_write_blocks_direct_multiedit_local_gomod_replace
run_case "validate-edit-write allows unrelated non-plan Edit" \
  test_validate_edit_write_allows_unrelated_non_plan_edit
run_case "validate-edit-write allows remote Write go.mod replace" \
  test_validate_edit_write_allows_remote_write_gomod_replace
run_case "validate-edit-write allows remote MultiEdit go.mod replace" \
  test_validate_edit_write_allows_remote_multiedit_gomod_replace
run_case "validate-apply-patch parses tool_input.patch go.mod replaces" \
  test_validate_apply_patch_blocks_local_gomod_replace_from_patch
run_case "validate-apply-patch blocks go.mod replace on Move to destination" \
  test_validate_apply_patch_blocks_local_gomod_replace_on_move_destination
run_case "validate-apply-patch blocks block-form go.mod local replace" \
  test_validate_apply_patch_blocks_block_form_local_gomod_replace
run_case "validate-apply-patch allows remote go.mod replace" \
  test_validate_apply_patch_allows_remote_gomod_replace
run_case "validate-apply-patch allows unrelated non-plan edit" \
  test_validate_apply_patch_allows_unrelated_non_plan_edit
run_case "validate-bash blocks bare go test" \
  test_validate_bash_blocks_bare_go_test
run_case "validate-bash blocks go test -count=1" \
  test_validate_bash_blocks_go_test_count_one
run_case "validate-bash allows redirected go test" \
  test_validate_bash_allows_redirected_go_test
run_case "validate-bash allows go test piped to tee" \
  test_validate_bash_allows_go_test_tee
run_case "security reminder sees workflow Move to destination" \
  test_security_reminder_sees_workflow_move_destination
run_case "stop gate blocks proof missing required sections" \
  test_stop_gate_blocks_missing_proof_sections
run_case "stop gate accepts complete proof fixture" \
  test_stop_gate_accepts_complete_proof_fixture
run_case "stop gate accepted proof reports dirty git state" \
  test_stop_gate_accepts_proof_reports_dirty_git_state
run_case "stop gate blocks clean-scan empty source" \
  test_stop_gate_blocks_clean_scan_empty_source
run_case "stop gate blocks blocker missing input" \
  test_stop_gate_blocks_blocker_missing_input
run_case "stop gate blocks blocker missing command" \
  test_stop_gate_blocks_blocker_missing_command
run_case "stop gate blocks placeholder blocker command" \
  test_stop_gate_blocks_placeholder_blocker_command
run_case "stop gate blocks fake audit commit" \
  test_stop_gate_blocks_fake_audit_commit
run_case "stop gate validates proof while stop_hook_active is true" \
  test_stop_gate_validates_proof_when_stop_hook_active
run_case "stop gate blocks identical audit without rescanned" \
  test_stop_gate_blocks_identical_audit_without_rescanned
run_case "stop gate accepts identical audit with valid rescanned" \
  test_stop_gate_accepts_identical_audit_with_rescanned
run_case "stop gate blocks dirty identical audit" \
  test_stop_gate_blocks_dirty_identical_audit
run_case "stop gate blocks identical audit after HEAD advance" \
  test_stop_gate_blocks_identical_audit_after_head_advance
run_case "stop gate scopes freshness history across repos" \
  test_stop_gate_allows_same_session_history_across_repos
run_case "stop gate blocks pre-existing commit after HEAD advance" \
  test_stop_gate_blocks_preexisting_commit_after_head_advance
run_case "stop gate adds loop reminder after five blocks" \
  test_stop_gate_adds_loop_reminder_after_five_blocks
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
run_case "stop gate blocks /side parent session with ECI state" \
  test_stop_gate_blocks_side_parent_session_with_eci_state
run_case "stop gate allows ephemeral threads before ECI state" \
  test_stop_gate_allows_ephemeral_threads_before_eci_state
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
run_case "audit sync checker reports ok" \
  test_audit_sync_checker_ok
run_case "audit sync checker supports direct exec" \
  test_audit_sync_checker_direct_exec_ok
run_case "audit sync checker detects drift" \
  test_audit_sync_checker_detects_drift
run_case "audit sync checker fails when synced files are missing" \
  test_audit_sync_checker_fails_when_synced_file_missing

note "SUMMARY pass=$PASS_COUNT fail=$FAIL_COUNT xfail=$XFAIL_COUNT xpass=$XPASS_COUNT todo=$TODO_COUNT"

if [ "$FAIL_COUNT" -ne 0 ] || [ "$XPASS_COUNT" -ne 0 ]; then
  exit 1
fi
