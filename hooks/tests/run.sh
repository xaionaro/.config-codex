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

with_cwd_fixture() {
  local src="$1"
  local dst="$2"
  jq --arg cwd "$ROOT" '.cwd = $cwd' "$src" >"$dst"
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

test_eci_gate_allows_implementer_role() {
  local proof_root out
  proof_root="$(fresh_proof_root eci-role)"
  mkdir -p "$proof_root/t00-session"
  printf 'scope: test\n' >"$proof_root/t00-session/eci_active"
  out="$TMP_ROOT/eci-role.out"

  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$FIXTURES/eci-apply-patch-code.json" \
    CODEX_PROOF_ROOT="$proof_root" CODEX_ROLE="eci-implementer" || return 1

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

current_bad_eci_gate_denies_markdown_only_apply_patch() {
  local proof_root out
  proof_root="$(fresh_proof_root eci-markdown-bad)"
  mkdir -p "$proof_root/t00-session"
  printf 'scope: test\n' >"$proof_root/t00-session/eci_active"
  out="$TMP_ROOT/eci-markdown-bad.out"

  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$FIXTURES/eci-apply-patch-markdown.json" \
    CODEX_PROOF_ROOT="$proof_root"

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

current_bad_multiedit_hook_config_is_missing() {
  local matcher
  matcher="$(eci_gate_matcher)" || return 1
  matcher_has_tool "$matcher" "apply_patch" || return 1
  matcher_has_tool "$matcher" "Edit" || return 1
  matcher_has_tool "$matcher" "Write" || return 1
  ! matcher_has_tool "$matcher" "MultiEdit"
}

test_validate_apply_patch_blocks_plan_paths_from_input() {
  local out
  out="$TMP_ROOT/apply-patch-plan.out"
  run_hook "$out" "$ROOT/hooks/validate-apply-patch.sh" "$FIXTURES/validate-apply-patch-plan.json" || return 1
  is_pretool_deny "$out" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "docs/plans"
}

test_validate_apply_patch_blocks_local_gomod_replace_from_patch() {
  local out
  out="$TMP_ROOT/apply-patch-gomod.out"
  run_hook "$out" "$ROOT/hooks/validate-apply-patch.sh" "$FIXTURES/validate-apply-patch-gomod.json" || return 1
  is_pretool_deny "$out" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "local relative replace"
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
run_case "ECI gate allows implementer role through marker" \
  test_eci_gate_allows_implementer_role
run_xfail "ECI gate allows markdown-only apply_patch while marker exists" \
  test_eci_gate_allows_markdown_only_apply_patch \
  current_bad_eci_gate_denies_markdown_only_apply_patch
run_case "ECI gate denies mixed markdown/code apply_patch" \
  test_eci_gate_denies_mixed_markdown_code_patch
run_case "ECI gate blocks MultiEdit JSON stdin when marker exists" \
  test_eci_gate_blocks_multiedit_stdin
run_xfail "hooks.json edit matcher includes MultiEdit" \
  test_multiedit_hook_config_is_wired \
  current_bad_multiedit_hook_config_is_missing
run_case "validate-apply-patch parses tool_input.input plan paths" \
  test_validate_apply_patch_blocks_plan_paths_from_input
run_case "validate-apply-patch parses tool_input.patch go.mod replaces" \
  test_validate_apply_patch_blocks_local_gomod_replace_from_patch
run_case "stop gate blocks proof missing required sections" \
  test_stop_gate_blocks_missing_proof_sections
run_case "stop gate accepts complete proof fixture" \
  test_stop_gate_accepts_complete_proof_fixture
run_case "stop gate blocks cwd-scoped ECI marker" \
  test_stop_gate_blocks_cwd_eci_state
run_case "stop gate blocks cwd-scoped ECI marker without cwd field" \
  test_stop_gate_blocks_cwd_eci_state_without_cwd_field
run_case "stop gate blocks session-scoped ECI marker" \
  test_stop_gate_blocks_session_eci_state
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
