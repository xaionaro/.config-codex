#!/usr/bin/env bash

set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
FIXTURES="$ROOT/hooks/tests/fixtures"
. "$ROOT/hooks/tests/lib/formal-tmpfs.sh"
if ! command -v strace >/dev/null 2>&1; then
  printf '%s\n' "FAIL setup strace is required"
  exit 1
fi
if ! lean_prefix="$(lean --print-prefix 2>/dev/null)" ||
    [ ! -x "$(command -v lake 2>/dev/null)" ] ||
    [ ! -f "$lean_prefix/lib/lean/Lake.olean" ] ||
    [ ! -f "$lean_prefix/lib/lean/Lean/Data/Json.olean" ]; then
  printf '%s\n' "FAIL setup complete Lean/Lake object closure is required"
  exit 1
fi
FORMAL_TMP_ROOT=""
if ! FORMAL_TMP_ROOT="$(codex_select_formal_tmpfs_scratch)"; then
  printf '%s\n' "FAIL setup private writable tmpfs is required for formal lifecycle checks"
  exit 1
fi
TMP_ROOT=""
if ! TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/codex-hooks-tests.XXXXXX")"; then
  rm -rf -- "$FORMAL_TMP_ROOT"
  printf '%s\n' "FAIL setup could not create temporary test root"
  exit 1
fi

FORMAL_PERSISTENT_ROOT=""
if ! FORMAL_PERSISTENT_ROOT="$(codex_select_formal_persistent_storage)"; then
  rm -rf -- "$TMP_ROOT" "$FORMAL_TMP_ROOT"
  printf '%s\n' "FAIL setup private persistent formal evidence storage is required"
  exit 1
fi

PASS_COUNT=0
FAIL_COUNT=0
XFAIL_COUNT=0
XPASS_COUNT=0
TODO_COUNT=0

cleanup() {
  local status=$?
  trap - EXIT
  if [ -n "${TMP_ROOT:-}" ] && [ -d "$TMP_ROOT" ]; then
    rm -f "$(subagent_transcript_path 2>/dev/null || true)" 2>/dev/null || true
    rm -rf "$TMP_ROOT"
  fi
  if [ -n "${FORMAL_TMP_ROOT:-}" ] && [ -d "$FORMAL_TMP_ROOT" ]; then
    rm -rf -- "$FORMAL_TMP_ROOT"
  fi
  if [ -n "${FORMAL_PERSISTENT_ROOT:-}" ] && [ -d "$FORMAL_PERSISTENT_ROOT" ]; then
    if [ "$status" -eq 0 ] && [ "${FAIL_COUNT:-1}" -eq 0 ]; then
      rm -rf -- "$FORMAL_PERSISTENT_ROOT" 2>/dev/null || true
    else
      printf 'preserved formal evidence: %s\n' "$FORMAL_PERSISTENT_ROOT" >&2
    fi
  fi
  exit "$status"
}

trap cleanup EXIT

controller_verifier="$ROOT/hooks/tests/differential/pre-reviewer-controller.sh"
controller_publish="$FORMAL_PERSISTENT_ROOT/artifacts/pre-reviewer"
profile_report="$FORMAL_PERSISTENT_ROOT/evidence/pre-reviewer-profile.out"
profile_audit="$FORMAL_PERSISTENT_ROOT/logs/controller-build.audit"
profile_stdout="$TMP_ROOT/pre-reviewer-profile-setup.out"
profile_expected_commit="$(git rev-parse --verify HEAD)"
if ! "$ROOT/hooks/tests/profile-pre-reviewer.sh" \
    --formal-tmp-root "$FORMAL_TMP_ROOT" \
    --output-root "$FORMAL_PERSISTENT_ROOT" >"$profile_stdout"; then
  printf '%s\n' "FAIL setup pre-reviewer single-build profile failed"
  exit 1
fi
export CODEX_PRE_REVIEWER_FORMAL_EXE="$controller_publish/preReviewerControllerDiff"
export CODEX_PRE_REVIEWER_FORMAL_STAMP="$CODEX_PRE_REVIEWER_FORMAL_EXE.stamp"
if ! cmp -s -- "$profile_stdout" "$profile_report"; then
  printf '%s\n' "FAIL setup pre-reviewer profile output binding failed"
  exit 1
fi
if ! "$controller_verifier" --verify-artifact \
    "$CODEX_PRE_REVIEWER_FORMAL_EXE" "$CODEX_PRE_REVIEWER_FORMAL_STAMP"; then
  printf '%s\n' "FAIL setup pre-reviewer formal artifact verification failed"
  exit 1
fi
if ! PROFILE_REPORT_SHA256="$(python3 - "$ROOT" "$profile_report" \
    "$FORMAL_PERSISTENT_ROOT" "$profile_expected_commit" <<'PY'
import importlib.util
from pathlib import Path
import sys

root = Path(sys.argv[1])
report_path = Path(sys.argv[2])
output_root = Path(sys.argv[3])
expected_commit = sys.argv[4]
module_path = root / "hooks/tests/profile_pre_reviewer_ab.py"
spec = importlib.util.spec_from_file_location("runner_profile_contract", module_path)
if spec is None or spec.loader is None:
    raise SystemExit(1)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
print(module.validate_persisted_profile(report_path, output_root, expected_commit))
PY
)"; then
  printf '%s\n' "FAIL setup pre-reviewer profile summary validation failed"
  exit 1
fi
export PROFILE_REPORT_SHA256

prune_verifier="$ROOT/hooks/tests/differential/prune-turn-state.sh"
prune_publish="$FORMAL_PERSISTENT_ROOT/artifacts/prune"
mkdir -p "$prune_publish"
if ! codex_build_formal_artifact \
    "$FORMAL_TMP_ROOT" "$FORMAL_PERSISTENT_ROOT" "$ROOT" \
    "$ROOT/hooks/tests/process-watchdog.py" prune-build.log \
    "$prune_verifier" --build-artifact "$prune_publish"; then
  printf '%s\n' "FAIL setup prune formal artifact build failed"
  exit 1
fi
export CODEX_PRUNE_FORMAL_EXE="$prune_publish/pruneTurnStateDiff"
export CODEX_PRUNE_FORMAL_STAMP="$CODEX_PRUNE_FORMAL_EXE.stamp"
if ! "$prune_verifier" --verify-artifact \
    "$CODEX_PRUNE_FORMAL_EXE" "$CODEX_PRUNE_FORMAL_STAMP"; then
  printf '%s\n' "FAIL setup prune formal artifact verification failed"
  exit 1
fi

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

json_field_not_contains() {
  ! json_field_contains "$@"
}

run_hook() {
  local outfile="$1"
  local script="$2"
  local fixture="$3"
  shift 3
  env -u CODEX_ROLE "$@" bash "$script" <"$fixture" 2>"$outfile.err" |
    cat >"$outfile"
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

make_fake_gitleaks() {
  local name="$1"
  local bin_dir="$TMP_ROOT/bin-$name"
  mkdir -p "$bin_dir" || return 1
  cat >"$bin_dir/gitleaks" <<'SCRIPT'
#!/usr/bin/env bash
set -u

report=""
source="."
while [ "$#" -gt 0 ]; do
  case "$1" in
    --report-path|-r)
      shift
      report="${1:-}"
      ;;
    --source|-s)
      shift
      source="${1:-.}"
      ;;
  esac
  shift || break
done

if [ -z "$report" ]; then
  printf '%s\n' "missing report path" >&2
  exit 2
fi

if [ "${FAKE_GITLEAKS_MODE:-}" = "error" ]; then
  printf '%s\n' "scanner exploded" >&2
  exit 2
fi

if [ -d "$source" ] && grep -R "FAKE_SECRET" "$source" >/dev/null 2>&1; then
  cat >"$report" <<'JSON'
[
  {
    "Description": "Fake secret",
    "StartLine": 2,
    "File": "file.txt",
    "RuleID": "fake-secret"
  }
]
JSON
  exit 1
fi

printf '[]\n' >"$report"
exit 0
SCRIPT
  chmod +x "$bin_dir/gitleaks" || return 1
  printf '%s\n' "$bin_dir"
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
  mkdir -p "$proof_root/reviewer/t00-session"
  mkdir -p -m 0700 "$proof_root/pre-reviewer/t00-session"
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

test_prompt_state_keeps_session_eci_marker_silent() {
  local proof_root out marker
  proof_root="$(fresh_proof_root prompt-eci)"
  marker="$proof_root/t00-session/eci_active"
  mkdir -p "$(dirname "$marker")" || return 1
  printf 'scope: prompt state test\n' >"$marker"
  out="$TMP_ROOT/prompt-eci.out"

  run_hook "$out" "$ROOT/hooks/prompt-task-reminder.sh" "$FIXTURES/user-prompt-submit.json" \
    CODEX_PROOF_ROOT="$proof_root" || return 1

  expect_no_output "$out" &&
    [ -f "$marker" ] &&
    grep -q "scope: prompt state test" "$marker"
}

test_prompt_state_config_is_wired_without_probe() {
  jq -e '
    ([.hooks.UserPromptSubmit[]?.hooks[]?.command]
      | any(test("\\$\\{CODEX_HOME:-\\$HOME/\\.codex\\}/hooks/prompt-task-reminder\\.sh"))) and
    ([.hooks.PostToolUse[]?.hooks[]?.command] | length == 0) and
    ([.. | objects | .command? // empty]
      | all(contains("/hooks/tests/skill-event-probe.sh") | not))
  ' "$ROOT/hooks.json" >/dev/null
}

test_prompt_state_keeps_nontrivial_governance_task_silent() {
  prompt_state_prompt_stays_silent "prompt-nontrivial-governance-silent" \
    "Update CODEX.md and hooks/prompt-task-reminder.sh to enforce governance routing."
}

test_prompt_state_keeps_codex_typo_silent() {
  prompt_state_prompt_stays_silent "prompt-codex-typo-silent" \
    "Fix a typo in CODEX.md"
}

test_prompt_state_keeps_hooks_path_governance_task_silent() {
  prompt_state_prompt_stays_silent "prompt-hooks-path-silent" \
    "Fix hooks/stop-gate.sh to enforce ECI teardown."
}

test_prompt_state_leaves_react_hook_prompt_silent() {
  local proof_root input out
  proof_root="$(fresh_proof_root prompt-react-hook-silent)"
  input="$TMP_ROOT/prompt-react-hook-silent.json"
  jq '.prompt = "Fix React hook useUser."' "$FIXTURES/user-prompt-submit.json" >"$input"
  out="$TMP_ROOT/prompt-react-hook-silent.out"

  run_hook "$out" "$ROOT/hooks/prompt-task-reminder.sh" "$input" \
    CODEX_PROOF_ROOT="$proof_root" || return 1

  expect_no_output "$out"
}

test_prompt_state_leaves_react_app_hooks_path_silent() {
  prompt_state_prompt_stays_silent "prompt-react-app-hooks-path-silent" \
    "Fix hooks/useUser.ts in the React app."
}

test_prompt_state_leaves_react_src_hooks_path_silent() {
  prompt_state_prompt_stays_silent "prompt-react-src-hooks-path-silent" \
    "Fix src/hooks/useUser.ts to correct stale state."
}

test_prompt_state_leaves_express_routing_prompt_silent() {
  local proof_root input out
  proof_root="$(fresh_proof_root prompt-express-routing-silent)"
  input="$TMP_ROOT/prompt-express-routing-silent.json"
  jq '.prompt = "Write routing for the Express app."' "$FIXTURES/user-prompt-submit.json" >"$input"
  out="$TMP_ROOT/prompt-express-routing-silent.out"

  run_hook "$out" "$ROOT/hooks/prompt-task-reminder.sh" "$input" \
    CODEX_PROOF_ROOT="$proof_root" || return 1

  expect_no_output "$out"
}

test_prompt_state_leaves_email_rule_prompt_silent() {
  local proof_root input out
  proof_root="$(fresh_proof_root prompt-email-rule-silent)"
  input="$TMP_ROOT/prompt-email-rule-silent.json"
  jq '.prompt = "Add a rule to the email filter."' "$FIXTURES/user-prompt-submit.json" >"$input"
  out="$TMP_ROOT/prompt-email-rule-silent.out"

  run_hook "$out" "$ROOT/hooks/prompt-task-reminder.sh" "$input" \
    CODEX_PROOF_ROOT="$proof_root" || return 1

  expect_no_output "$out"
}

prompt_state_prompt_stays_silent() {
  local tag="$1"
  local prompt_text="$2"
  local proof_root input out
  proof_root="$(fresh_proof_root "$tag")"
  input="$TMP_ROOT/$tag.json"
  jq --arg prompt "$prompt_text" '.prompt = $prompt' "$FIXTURES/user-prompt-submit.json" >"$input"
  out="$TMP_ROOT/$tag.out"

  run_hook "$out" "$ROOT/hooks/prompt-task-reminder.sh" "$input" \
    CODEX_PROOF_ROOT="$proof_root" || return 1

  expect_no_output "$out"
}

test_prompt_state_keeps_system_prompt_task_silent() {
  prompt_state_prompt_stays_silent "prompt-system-prompt-silent" \
    "Improve the system prompt."
}

test_prompt_state_keeps_subagent_stop_hook_prompt_task_silent() {
  prompt_state_prompt_stays_silent "prompt-subagent-stop-hook-silent" \
    "Update the subagent prompt for Stop-hook handling."
}

test_prompt_state_keeps_stop_hook_prompt_task_silent() {
  prompt_state_prompt_stays_silent "prompt-stop-hook-prompt-silent" \
    "Tighten the Stop-hook prompt."
}

test_prompt_state_keeps_codex_review_task_silent() {
  prompt_state_prompt_stays_silent "prompt-codex-review-silent" \
    "Review CODEX.md."
}

test_prompt_state_keeps_hook_behavior_audit_task_silent() {
  prompt_state_prompt_stays_silent "prompt-hook-behavior-audit-silent" \
    "Audit hook behavior."
}

test_prompt_state_keeps_hook_tests_task_silent() {
  prompt_state_prompt_stays_silent "prompt-hook-tests-silent" \
    "Add hook tests for stop gate behavior."
}

test_prompt_state_keeps_task_routing_task_silent() {
  prompt_state_prompt_stays_silent "prompt-task-routing-silent" \
    "Fix task routing for non-trivial requests."
}

test_prompt_state_keeps_agent_routing_protocol_task_silent() {
  prompt_state_prompt_stays_silent "prompt-agent-routing-protocol-silent" \
    "Fix agent routing so non-trivial tasks use the right protocol."
}

test_prompt_state_keeps_nontrivial_tasks_use_eci_question_silent() {
  prompt_state_prompt_stays_silent "prompt-nontrivial-tasks-use-eci-question-silent" \
    "What should we fix so non-trivial tasks use ECI at least?"
}

test_prompt_state_keeps_ensure_nontrivial_tasks_use_eci_silent() {
  prompt_state_prompt_stays_silent "prompt-ensure-nontrivial-tasks-use-eci-silent" \
    "Ensure non-trivial tasks use ECI at least."
}

test_prompt_state_keeps_route_nontrivial_tasks_to_eci_silent() {
  prompt_state_prompt_stays_silent "prompt-route-nontrivial-tasks-to-eci-silent" \
    "Route non-trivial tasks to ECI."
}

test_prompt_state_keeps_routing_nontrivial_tasks_use_eci_silent() {
  prompt_state_prompt_stays_silent "prompt-routing-nontrivial-tasks-use-eci-silent" \
    "Fix routing so non-trivial tasks use ECI at least."
}

test_prompt_state_keeps_eci_routing_nontrivial_tasks_silent() {
  prompt_state_prompt_stays_silent "prompt-eci-routing-nontrivial-tasks-silent" \
    "Fix ECI routing for non-trivial tasks."
}

test_prompt_state_keeps_make_nontrivial_tasks_use_eci_silent() {
  prompt_state_prompt_stays_silent "prompt-make-nontrivial-tasks-use-eci-silent" \
    "Make non-trivial tasks use ECI at least."
}

test_prompt_state_keeps_caveman_switch_task_silent() {
  prompt_state_prompt_stays_silent "prompt-caveman-switch-silent" \
    "OK, we switched from caveman to ponytail previously. Switch it back to caveman."
}

test_prompt_state_keeps_plain_stop_gate_task_silent() {
  prompt_state_prompt_stays_silent "prompt-stop-gate-silent" \
    "Fix stop gate behavior."
}

test_prompt_state_keeps_hyphen_stop_gate_task_silent() {
  prompt_state_prompt_stays_silent "prompt-hyphen-stop-gate-silent" \
    "Fix stop-gate behavior."
}

test_prompt_state_keeps_stop_gate_script_task_silent() {
  prompt_state_prompt_stays_silent "prompt-stop-gate-script-silent" \
    "Update stop-gate.sh."
}

test_prompt_state_keeps_stop_checklist_path_task_silent() {
  prompt_state_prompt_stays_silent "prompt-stop-checklist-path-silent" \
    "Update hooks/stop-checklist.md."
}

test_prompt_state_keeps_stop_checklist_task_silent() {
  prompt_state_prompt_stays_silent "prompt-stop-checklist-silent" \
    "Update stop checklist."
}

test_prompt_state_keeps_codex_config_task_silent() {
  prompt_state_prompt_stays_silent "prompt-codex-config-silent" \
    "Update Codex config.toml."
}

test_prompt_state_leaves_cli_installation_instructions_silent() {
  prompt_state_prompt_stays_silent "prompt-cli-instructions-silent" \
    "Write installation instructions for the CLI."
}

test_prompt_state_leaves_onboarding_email_instructions_silent() {
  prompt_state_prompt_stays_silent "prompt-email-instructions-silent" \
    "Add instructions to the onboarding email."
}

test_prompt_state_leaves_react_hook_behavior_prompt_silent() {
  prompt_state_prompt_stays_silent "prompt-react-hook-behavior-silent" \
    "Fix React hook behavior in useUser."
}

test_prompt_state_leaves_react_hook_behavior_audit_silent() {
  prompt_state_prompt_stays_silent "prompt-react-hook-behavior-audit-silent" \
    "Audit hook behavior in React useUser."
}

test_prompt_state_leaves_react_hook_tests_silent() {
  prompt_state_prompt_stays_silent "prompt-react-hook-tests-silent" \
    "Add hook tests for React useUser."
}

test_prompt_state_leaves_express_routing_rule_prompt_silent() {
  prompt_state_prompt_stays_silent "prompt-express-routing-rule-silent" \
    "Add a routing rule to the Express app."
}

test_prompt_state_leaves_rust_config_silent() {
  prompt_state_prompt_stays_silent "prompt-rust-config-silent" \
    "Update config.toml for the Rust app."
}

test_prompt_state_leaves_web_app_hooks_json_silent() {
  prompt_state_prompt_stays_silent "prompt-web-app-hooks-json-silent" \
    "Modify hooks.json for my web app."
}

test_prompt_state_leaves_caveman_story_silent() {
  prompt_state_prompt_stays_silent "prompt-caveman-story-silent" \
    "Write a caveman story."
}

test_stop_gate_blocks_side_prompt_with_parent_eci_state() {
  local proof_root prompt_out prompt_input input out
  proof_root="$(fresh_proof_root stop-side-eci)"
  prompt_out="$TMP_ROOT/stop-side-prompt.out"
  prompt_input="$TMP_ROOT/stop-side-prompt.json"

  jq --arg cwd "$ROOT" '.session_id = "t00-parent" | .cwd = $cwd' "$FIXTURES/user-prompt-side.json" >"$prompt_input"
  run_hook "$prompt_out" "$ROOT/hooks/prompt-task-reminder.sh" "$prompt_input" \
    CODEX_PROOF_ROOT="$proof_root" || return 1
  CODEX_SESSION_ID=t00-parent CODEX_PROOF_ROOT="$proof_root" "$ROOT/bin/eci-active" on "test scope" >"$TMP_ROOT/stop-side-eci-on.out" 2>&1 || return 1

  input="$TMP_ROOT/stop-side-eci.json"
  jq --arg cwd "$ROOT" '.session_id = "t00-side" | .cwd = $cwd' "$FIXTURES/stop-basic.json" >"$input"
  out="$TMP_ROOT/stop-side-eci.out"

  run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$input" CODEX_PROOF_ROOT="$proof_root" || return 1
  is_stop_block "$out" &&
    json_field_contains "$out" '.reason // empty' "ECI is active" &&
    json_field_contains "$out" '.reason // empty' "$proof_root/t00-parent/eci_active"
}

test_stop_gate_blocks_side_parent_session_with_eci_state() {
  local proof_root prompt_out prompt_input input out
  proof_root="$(fresh_proof_root stop-side-parent-eci)"
  prompt_out="$TMP_ROOT/stop-side-parent-prompt.out"
  prompt_input="$TMP_ROOT/stop-side-parent-prompt.json"

  jq --arg cwd "$ROOT" '.session_id = "t00-parent" | .cwd = $cwd' "$FIXTURES/user-prompt-side.json" >"$prompt_input"
  run_hook "$prompt_out" "$ROOT/hooks/prompt-task-reminder.sh" "$prompt_input" \
    CODEX_PROOF_ROOT="$proof_root" || return 1
  CODEX_SESSION_ID=t00-parent CODEX_PROOF_ROOT="$proof_root" "$ROOT/bin/eci-active" on "test scope" >"$TMP_ROOT/stop-side-parent-eci-on.out" 2>&1 || return 1

  input="$TMP_ROOT/stop-side-parent-eci.json"
  jq --arg cwd "$ROOT" '.session_id = "t00-parent" | .cwd = $cwd' "$FIXTURES/stop-basic.json" >"$input"
  out="$TMP_ROOT/stop-side-parent-eci.out"

  run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$input" CODEX_PROOF_ROOT="$proof_root" || return 1
  is_stop_block "$out" &&
    json_field_contains "$out" '.reason // empty' "ECI is active" &&
    json_field_contains "$out" '.reason // empty' "$proof_root/t00-parent/eci_active"
}

test_runtime_hook_probe_historical_evidence_is_sanitized() {
  jq -e -s '
    length == 2 and
    all(type == "object") and
    all(keys_unsorted | all(IN("hook_event_name", "session_id", "cwd", "tool_name", "tool_input_keys", "observed"))) and
    any(
      .hook_event_name == "UserPromptSubmit" and
      .cwd == "<codex-home>" and
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
  local proof_root out skip_cwd
  proof_root="$(fresh_proof_root session-old-markers)"
  CODEX_SESSION_ID=t00-session CODEX_PROOF_ROOT="$proof_root" "$ROOT/bin/skip-stop" on >/dev/null 2>&1 || return 1
  env -u CODEX_SESSION_ID CODEX_PROOF_ROOT="$proof_root" "$ROOT/bin/skip-stop" on >/dev/null 2>&1 || return 1
  CODEX_SESSION_ID=t00-session CODEX_PROOF_ROOT="$proof_root" "$ROOT/bin/eci-active" on "test scope" >/dev/null 2>&1 || return 1

  skip_cwd=$(find "$proof_root/skip-stop/cwd" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n1)
  [ -n "$skip_cwd" ] || return 1
  touch -t 202001010000 "$proof_root/skip-stop/sessions/t00-session" "$skip_cwd" "$proof_root/t00-session"

  out="$TMP_ROOT/session-snapshot-old-markers.out"
  run_hook "$out" "$ROOT/hooks/session-snapshot.sh" "$FIXTURES/session-start.json" \
    CODEX_PROOF_ROOT="$proof_root" || return 1

  [ -e "$proof_root/skip-stop/sessions/t00-session/skip_stop" ] &&
    [ -e "$skip_cwd/skip_stop" ] &&
    [ -e "$proof_root/t00-session/eci_active" ] &&
    [ "$(find "$proof_root/eci/cwd" -mindepth 2 -maxdepth 2 -name eci_active 2>/dev/null | wc -l)" -eq 0 ]
}

test_stop_gate_blocks_ephemeral_threads_with_eci_state() {
  local proof_root out
  proof_root="$(fresh_proof_root stop-ephemeral-eci)"
  CODEX_SESSION_ID=t00-side CODEX_PROOF_ROOT="$proof_root" "$ROOT/bin/eci-active" on "test scope" >/dev/null 2>&1 || return 1
  out="$TMP_ROOT/stop-ephemeral-eci.out"

  run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$FIXTURES/stop-ephemeral.json" \
    CODEX_PROOF_ROOT="$proof_root" || return 1

  is_stop_block "$out" &&
    json_field_contains "$out" '.reason // empty' "$proof_root/t00-side/eci_active"
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
  CODEX_SESSION_ID=t00-parent CODEX_PROOF_ROOT="$proof_root" "$ROOT/bin/eci-active" on "test scope" >"$TMP_ROOT/session-side-eci-on.out" 2>&1 || return 1

  stop_input="$TMP_ROOT/session-side-stop.json"
  jq --arg cwd "$ROOT" '.session_id = "t00-side" | .cwd = $cwd' "$FIXTURES/stop-basic.json" >"$stop_input"
  stop_out="$TMP_ROOT/session-side-stop.out"
  run_hook "$stop_out" "$ROOT/hooks/stop-gate.sh" "$stop_input" CODEX_PROOF_ROOT="$proof_root" || return 1

  expect_no_output "$start_out" &&
    [ -f "$child_marker" ] &&
    grep -q '^parent_session_id: t00-parent$' "$child_marker" &&
    is_stop_block "$stop_out" &&
    json_field_contains "$stop_out" '.reason // empty' "$proof_root/t00-parent/eci_active"
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

test_eci_gate_skips_invalid_session_id() {
  local proof_root input out
  proof_root="$(fresh_proof_root eci-invalid-session)"
  mkdir -p "$proof_root/../bad"
  printf 'scope: bad\n' >"$proof_root/../bad/eci_active"
  input="$TMP_ROOT/eci-invalid-session.json"
  jq '.session_id = "../bad"' "$FIXTURES/eci-apply-patch-code.json" >"$input"
  out="$TMP_ROOT/eci-invalid-session.out"

  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" \
    CODEX_PROOF_ROOT="$proof_root" || return 1

  expect_no_output "$out"
}

test_eci_gate_message_mentions_clean_pass_user_closed() {
  local proof_root out
  proof_root="$(fresh_proof_root eci-message)"
  mkdir -p "$proof_root/t00-session"
  printf 'scope: test\n' >"$proof_root/t00-session/eci_active"
  out="$TMP_ROOT/eci-message.out"

  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$FIXTURES/eci-apply-patch-code.json" \
    CODEX_PROOF_ROOT="$proof_root" || return 1

  is_pretool_deny "$out" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "Never stop until the ECI task is complete" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "Continue the ECI task" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "Disengage only with clean-pass or user-closed" &&
    json_field_not_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "Route edits" &&
    json_field_not_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "implementer role" &&
    json_field_not_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "request"
}

test_eci_gate_ignores_code_apply_patch_from_cwd_state() {
  local proof_root input out cwd_dir
  proof_root="$(fresh_proof_root eci-code-cwd)"
  cwd_dir="$(CODEX_PROOF_ROOT="$proof_root" bash -c '. "$0/hooks/lib/codex-proof-state.sh"; codex_ensure_cwd_state_dir eci "$1"' "$ROOT" "$ROOT")" || return 1
  printf 'scope: stale cwd state\n' >"$cwd_dir/eci_active"

  input="$TMP_ROOT/eci-code-cwd.json"
  jq --arg cwd "$ROOT" '.cwd = $cwd' "$FIXTURES/eci-apply-patch-code.json" >"$input"
  out="$TMP_ROOT/eci-code-cwd.out"

  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" \
    CODEX_PROOF_ROOT="$proof_root" || return 1

  expect_no_output "$out"
}

test_eci_gate_blocks_code_apply_patch_from_session_state() {
  local proof_root out
  proof_root="$(fresh_proof_root eci-code-session)"
  out="$TMP_ROOT/eci-code-session-active.out"
  CODEX_SESSION_ID=t00-session CODEX_PROOF_ROOT="$proof_root" "$ROOT/bin/eci-active" on "test scope" >"$out" 2>"$out.err" || return 1
  [ -f "$proof_root/t00-session/eci_active" ] || return 1
  [ ! -e "$proof_root/eci/cwd" ] || return 1

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

write_first_record_scoped_subagent_transcript() {
  local path="$1"
  local record_bytes="$2"
  local include_newline="${3:-yes}"
  local include_history="${4:-yes}"
  local prefix suffix newline_bytes padding_length history_prefix history_suffix
  prefix='{"type":"session_meta","payload":{"source":{"subagent":{"thread_spawn":{"parent_thread_id":"parent-session"}}}},"padding":"'
  suffix='"}'
  newline_bytes=1
  [ "$include_newline" = yes ] || newline_bytes=0
  padding_length=$((record_bytes - ${#prefix} - ${#suffix} - newline_bytes))
  [ "$padding_length" -ge 0 ] || return 1
  mkdir -p "$(dirname "$path")" || return 1
  printf '%s%*s%s' "$prefix" "$padding_length" '' "$suffix" | tr ' ' x >"$path"
  [ "$include_newline" = yes ] && printf '\n' >>"$path"
  if [ "$include_history" = yes ]; then
    history_prefix='{"padding":"'
    history_suffix='","sentinel":"DEEP_SECOND_RECORD_SENTINEL"}'
    printf '%s%*s%s\n' "$history_prefix" 1048576 '' "$history_suffix" | tr ' ' y >>"$path"
  fi
  [ "$record_bytes" -eq "$(head -c "$record_bytes" "$path" | wc -c)" ]
}

trace_first_record_helper() {
  local helper="$1"
  local transcript="$2"
  local output="$3"
  local trace="$4"

  strace -f -qq -s 8192 -e trace=read -P "$transcript" -o "$trace" \
    env HOME="$TMP_ROOT/home" bash -c '. "$1"; "$2" "$3"' \
    bash "$ROOT/hooks/lib/codex-proof-state.sh" "$helper" \
    "$(jq -cn --arg transcript "$transcript" '{transcript_path: $transcript}')" \
    >"$output" 2>"$output.err"
}

trace_read_bytes() {
  local trace="$1"

  awk '$NF ~ /^[0-9]+$/ { total += $NF } END { print total + 0 }' "$trace"
}

trace_is_first_record_scoped() {
  local trace="$1"
  local transcript="$2"
  local first_record_bytes total_bytes read_bytes
  first_record_bytes="$(sed -n '1{p;q;}' "$transcript" | wc -c)"
  total_bytes="$(wc -c <"$transcript")"
  read_bytes="$(trace_read_bytes "$trace")"

  [ -s "$trace" ] &&
    [ "$read_bytes" -le $((first_record_bytes + 8192)) ] &&
    { [ "$first_record_bytes" -eq "$total_bytes" ] || [ "$read_bytes" -lt "$total_bytes" ]; } &&
    ! grep -Fq 'DEEP_SECOND_RECORD_SENTINEL' "$trace"
}

invoke_state_helper() {
  local helper="$1"
  local input="$2"
  local output="$3"

  env HOME="$TMP_ROOT/home" bash -c '. "$1"; "$2" "$3"' \
    bash "$ROOT/hooks/lib/codex-proof-state.sh" "$helper" "$input" \
    >"$output" 2>"$output.err"
}

test_subagent_helper_rejects_oversize_first_record() {
  local label record_bytes transcript output trace
  for label in short boundary large; do
    case "$label" in
      short) record_bytes=256 ;;
      boundary) record_bytes=4096 ;;
      large) record_bytes=1048576 ;;
    esac
    transcript="$TMP_ROOT/home/.codex/sessions/first-record-subagent-$label.jsonl"
    output="$TMP_ROOT/first-record-subagent-$label.out"
    trace="$TMP_ROOT/first-record-subagent-$label.strace"
    write_first_record_scoped_subagent_transcript "$transcript" "$record_bytes" || return 1
    if [ "$label" = large ]; then
      if trace_first_record_helper codex_hook_is_subagent_context \
          "$transcript" "$output" "$trace"; then
        return 1
      fi
    else
      trace_first_record_helper codex_hook_is_subagent_context \
        "$transcript" "$output" "$trace" || return 1
    fi
    [ ! -s "$output" ] && trace_is_first_record_scoped "$trace" "$transcript" || return 1
  done
}

test_parent_helper_rejects_oversize_first_record() {
  local transcript output trace
  transcript="$TMP_ROOT/home/.codex/sessions/first-record-parent-large.jsonl"
  output="$TMP_ROOT/first-record-parent-large.out"
  trace="$TMP_ROOT/first-record-parent-large.strace"
  write_first_record_scoped_subagent_transcript "$transcript" 1048576 || return 1

  if trace_first_record_helper codex_hook_parent_session_id \
      "$transcript" "$output" "$trace"; then
    return 1
  fi
  [ ! -s "$output" ] && trace_is_first_record_scoped "$trace" "$transcript"
}

test_first_record_helpers_reject_oversize_without_final_newline() {
  local transcript input output
  transcript="$TMP_ROOT/home/.codex/sessions/first-record-no-final-newline.jsonl"
  output="$TMP_ROOT/first-record-no-final-newline.out"
  write_first_record_scoped_subagent_transcript "$transcript" 1048576 no no || return 1
  input="$(jq -cn --arg transcript "$transcript" '{transcript_path: $transcript}')"

  if invoke_state_helper codex_hook_is_subagent_context "$input" "$output"; then
    return 1
  fi
  if invoke_state_helper codex_hook_parent_session_id "$input" "$output"; then
    return 1
  fi
  [ ! -s "$output" ]
}

test_first_record_helpers_preserve_boundary_behavior() {
  local dir transcript input output
  dir="$TMP_ROOT/home/.codex/sessions"
  mkdir -p "$dir" || return 1

  transcript="$dir/boundary-subagent.jsonl"
  write_subagent_transcript "$transcript" || return 1
  input="$(jq -cn --arg transcript "$transcript" --arg sid child-session \
    '{transcript_path: $transcript, session_id: $sid}')"
  output="$TMP_ROOT/boundary-subagent.out"
  invoke_state_helper codex_hook_is_subagent_context "$input" "$output" || return 1
  invoke_state_helper codex_hook_parent_session_id "$input" "$output" || return 1
  [ "$(cat "$output")" = parent-session ] || return 1

  transcript="$dir/boundary-no-final-newline.jsonl"
  printf '%s' "$(cat "$dir/boundary-subagent.jsonl")" >"$transcript"
  input="$(jq -cn --arg transcript "$transcript" '{transcript_path: $transcript}')"
  invoke_state_helper codex_hook_is_subagent_context "$input" "$output" || return 1
  invoke_state_helper codex_hook_parent_session_id "$input" "$output" || return 1
  [ "$(cat "$output")" = parent-session ] || return 1

  transcript="$dir/boundary-empty.jsonl"
  : >"$transcript"
  input="$(jq -cn --arg transcript "$transcript" '{transcript_path: $transcript}')"
  if invoke_state_helper codex_hook_is_subagent_context "$input" "$output"; then return 1; fi
  invoke_state_helper codex_hook_parent_session_id "$input" "$output" || true
  [ ! -s "$output" ] || return 1

  transcript="$dir/boundary-malformed.jsonl"
  printf '%s\n' '{malformed' >"$transcript"
  input="$(jq -cn --arg transcript "$transcript" '{transcript_path: $transcript}')"
  if invoke_state_helper codex_hook_is_subagent_context "$input" "$output"; then return 1; fi
  invoke_state_helper codex_hook_parent_session_id "$input" "$output" || true
  [ ! -s "$output" ] || return 1

  transcript="$dir/boundary-missing.jsonl"
  input="$(jq -cn --arg transcript "$transcript" '{transcript_path: $transcript}')"
  if invoke_state_helper codex_hook_is_subagent_context "$input" "$output"; then return 1; fi
  if invoke_state_helper codex_hook_parent_session_id "$input" "$output"; then return 1; fi

  transcript="$dir/boundary-main.jsonl"
  write_main_transcript "$transcript" || return 1
  input="$(jq -cn --arg transcript "$transcript" '{transcript_path: $transcript}')"
  if invoke_state_helper codex_hook_is_subagent_context "$input" "$output"; then return 1; fi
  invoke_state_helper codex_hook_parent_session_id "$input" "$output" || true
  [ ! -s "$output" ] || return 1

  transcript="$dir/boundary-invalid-parent.jsonl"
  printf '%s\n' '{"type":"session_meta","payload":{"source":{"subagent":{"thread_spawn":{"parent_thread_id":"../bad"}}}}}' >"$transcript"
  input="$(jq -cn --arg transcript "$transcript" --arg sid child-session \
    '{transcript_path: $transcript, session_id: $sid}')"
  invoke_state_helper codex_hook_allowed_session_ids "$input" "$output" || return 1
  [ "$(cat "$output")" = child-session ] || return 1

  transcript="$TMP_ROOT/outside-restricted-session-path.jsonl"
  write_subagent_transcript "$transcript" || return 1
  input="$(jq -cn --arg transcript "$transcript" '{transcript_path: $transcript}')"
  if invoke_state_helper codex_hook_is_subagent_context "$input" "$output"; then return 1; fi
  if invoke_state_helper codex_hook_parent_session_id "$input" "$output"; then return 1; fi
  [ ! -s "$output" ]
}

write_main_transcript() {
  local path="$1"
  mkdir -p "$(dirname "$path")" || return 1
  cat >"$path" <<'JSON'
{"timestamp":"2026-05-04T00:00:00.000Z","type":"session_meta","payload":{"id":"t00-session","source":"cli"}}
JSON
}

write_main_transcript_with_subagent_call() {
  local path="$1"
  mkdir -p "$(dirname "$path")" || return 1
  cat >"$path" <<'JSON'
{"timestamp":"2026-05-04T00:00:00.000Z","type":"session_meta","payload":{"id":"t00-session","source":"cli"}}
{"timestamp":"2026-05-04T00:00:01.000Z","type":"user","message":{"content":"use a subagent"}}
{"timestamp":"2026-05-04T00:00:02.000Z","type":"response_item","payload":{"type":"function_call","name":"spawn_agent","arguments":"{\"agent_type\":\"explorer\"}"}}
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
      ! CODEX_STOP_REVIEWER="codex:codex" parse_reviewer_env CODEX_STOP_REVIEWER &&
      ! CODEX_STOP_REVIEWER="shell:agent" parse_reviewer_env CODEX_STOP_REVIEWER
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
    grep -q '^# Response$' "$out" &&
    grep -q '^## Evidence$' "$out" &&
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

test_system_reviewer_skips_vcs_when_eci_active() {
  local proof_root input out transcript body marker
  proof_root="$(fresh_proof_root reviewer-eci-vcs-skip)"
  transcript="$(main_reviewer_transcript_path)"
  install_reviewer_transcript_fixture "$FIXTURES/reviewer-main-transcript.jsonl" "$transcript" || return 1
  marker="$proof_root/t00-session/eci_active"
  mkdir -p "$(dirname "$marker")" || return 1
  printf 'scope: reviewer skip\n' >"$marker"
  input="$TMP_ROOT/reviewer-eci-vcs-skip.json"
  jq --arg cwd "$ROOT" --arg transcript "$transcript" \
    '.cwd = $cwd | .transcript_path = $transcript' "$FIXTURES/stop-basic.json" >"$input"
  out="$TMP_ROOT/reviewer-eci-vcs-skip.out"
  body="$TMP_ROOT/reviewer-eci-vcs-skip-body.md"

  run_hook "$out" "$ROOT/hooks/system-prompt-reviewer.sh" "$input" \
    CODEX_PROOF_ROOT="$proof_root" \
    CODEX_STOP_REVIEWER="ollama:http://127.0.0.1:11434:qwen3:4b" \
    CODEX_REVIEWER_FAKE_RESULT='{"assistant_tail_quote":"Done.","passes_completed":["tail","tools","checklist","agreements"],"verdict":"pass","violations":[]}' \
    CODEX_REVIEWER_DEBUG_BODY_PATH="$body" || return 1

  expect_no_output "$out" &&
    grep -q '## VCS_STATUS' "$body" &&
    grep -q 'skipped: ECI active' "$body" &&
    grep -q '## DIFF' "$body" &&
    grep -q 'skipped: same reason as VCS_STATUS' "$body"
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
103 1 12 S $ROOT/hooks/system-prompt-reviewer.sh --token should_skip
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
  mkdir -p "$proof_root/activity/sessions/t00-session"
  printf 'created_utc: 2026-05-04T00:00:00Z\n' >"$proof_root/activity/sessions/t00-session/shell"
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
  mkdir -p "$proof_root/activity/sessions/t00-session"
  printf 'created_utc: 2026-05-04T00:00:00Z\n' >"$proof_root/activity/sessions/t00-session/shell"
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
  mkdir -p "$proof_root/activity/sessions/t00-session"
  printf 'created_utc: 2026-05-04T00:00:00Z\n' >"$proof_root/activity/sessions/t00-session/shell"
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
    ([.hooks.Stop[]?.hooks[]? | select((.command // "") | test("/stop-gate\\.sh")) | .timeout] | all(. >= 240)) and
    ([.hooks.Stop[]?.hooks[]?.command] | all((test("/system-prompt-reviewer\\.sh") | not))) and
    ([.hooks.PreToolUse[]?.hooks[]? | select((.command // "") | test("/edit-bash-pre-reviewer\\.sh"))]
      | length == 3 and all(.timeout == 75)) and
    ([.hooks.PreToolUse[]? | select(.matcher == "^Bash$") | .hooks[]?
      | select((.command // "") | test("/validate-bash\\.sh"))]
      | length == 1 and all(.timeout == 75)) and
    ([.hooks.PreToolUse[]? | select(.matcher == "^Bash$") | .hooks[]?.command] | any(test("/edit-bash-pre-reviewer\\.sh"))) and
    ([.hooks.PreToolUse[]? | select(.matcher == "^apply_patch$") | .hooks[]?.command] | any(test("/edit-bash-pre-reviewer\\.sh"))) and
    ([.hooks.PreToolUse[]? | select(.matcher == "^(Edit|Write|MultiEdit|NotebookEdit)$") | .hooks[]?.command] | any(test("/edit-bash-pre-reviewer\\.sh")))
  ' "$ROOT/hooks.json" >/dev/null || return 1
  [ "$(bash -c '. "$1"; printf "%s" "$CODEX_EDIT_PRE_REVIEWER_TIMEOUT"' \
      bash "$ROOT/hooks/lib/reviewer-call.sh")" = 58 ]
}

pre_reviewer_controller_has_only_exact_child_kill() {
  python3 - "$1" <<'PY'
import ast
import sys
from pathlib import Path


class KillCallVisitor(ast.NodeVisitor):
    def __init__(self) -> None:
        self.function_names: list[str] = []
        self.class_depth: int = 0
        self.kill_count: int = 0
        self.errors: list[str] = []

    def visit_ClassDef(self, node: ast.ClassDef) -> None:
        self.class_depth += 1
        self.generic_visit(node)
        self.class_depth -= 1

    def visit_FunctionDef(self, node: ast.FunctionDef) -> None:
        self.function_names.append(node.name)
        self.generic_visit(node)
        self.function_names.pop()

    def visit_AsyncFunctionDef(self, node: ast.AsyncFunctionDef) -> None:
        self.function_names.append(node.name)
        self.generic_visit(node)
        self.function_names.pop()

    def visit_Call(self, node: ast.Call) -> None:
        function = node.func
        if isinstance(function, ast.Attribute) and function.attr == "killpg":
            self.errors.append(f"line {node.lineno}: killpg is forbidden")

        is_os_kill = (
            isinstance(function, ast.Attribute)
            and function.attr == "kill"
            and isinstance(function.value, ast.Name)
            and function.value.id == "os"
        )
        if is_os_kill:
            self.kill_count += 1
            in_failed_gated_fork = (
                self.class_depth == 0
                and self.function_names == ["_failed_gated_fork"]
            )
            exact_arguments = (
                len(node.args) == 2
                and not node.keywords
                and isinstance(node.args[0], ast.Name)
                and node.args[0].id == "pid"
                and isinstance(node.args[1], ast.Attribute)
                and node.args[1].attr == "SIGKILL"
                and isinstance(node.args[1].value, ast.Name)
                and node.args[1].value.id == "signal"
            )
            if not in_failed_gated_fork or not exact_arguments:
                self.errors.append(
                    f"line {node.lineno}: only os.kill(pid, signal.SIGKILL) "
                    "inside _failed_gated_fork is permitted"
                )

        self.generic_visit(node)


source_path = Path(sys.argv[1])
tree = ast.parse(source_path.read_text(encoding="utf-8"), filename=str(source_path))
visitor = KillCallVisitor()
visitor.visit(tree)
if visitor.kill_count != 1:
    visitor.errors.append(f"expected one os.kill call, found {visitor.kill_count}")
if visitor.errors:
    raise SystemExit("\n".join(visitor.errors))
PY
}

test_pre_reviewer_controller_is_split_preflighted_and_bounded() {
  local clone worker controller out tmp_dir value invalid
  clone="$TMP_ROOT/pre-reviewer-controller-clone"
  worker="$clone/hooks/lib/edit-bash-pre-reviewer-worker.sh"
  out="$TMP_ROOT/pre-reviewer-controller.out"
  tmp_dir="$TMP_ROOT/pre-reviewer-controller-tmp"
  mkdir -p "$clone/hooks/lib" "$tmp_dir" || return 1
  cp "$ROOT/hooks/edit-bash-pre-reviewer.sh" "$clone/hooks/" || return 1
  controller="$clone/hooks/lib/edit_bash_pre_reviewer_controller.py"
  cp "$ROOT/hooks/lib/edit_bash_pre_reviewer_controller.py" "$controller" || return 1

  cat >"$worker" <<'SH'
#!/usr/bin/env bash
case "${CODEX_TEST_WORKER_MODE:-success}" in
  success)
    jq -n --arg timeout "${CODEX_EDIT_PRE_REVIEWER_TIMEOUT:-58}" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: $timeout
      }
    }'
    ;;
  failure) printf 'partial'; exit 9 ;;
esac
SH
  chmod 0644 "$worker" || return 1

  value="$(CODEX_EDIT_PRE_REVIEWER_TIMEOUT=37 \
    bash "$clone/hooks/edit-bash-pre-reviewer.sh" </dev/null)" || return 1
  [ "$(printf '%s' "$value" | jq -r '.hookSpecificOutput.permissionDecisionReason')" = 37 ] || return 1
  value="$(env -u CODEX_EDIT_PRE_REVIEWER_TIMEOUT \
    bash "$clone/hooks/edit-bash-pre-reviewer.sh" </dev/null)" || return 1
  [ "$(printf '%s' "$value" | jq -r '.hookSpecificOutput.permissionDecisionReason')" = 58 ] || return 1
  CODEX_TEST_WORKER_MODE=failure bash "$clone/hooks/edit-bash-pre-reviewer.sh" \
    </dev/null >"$out" || return 1
  expect_no_output "$out" || return 1

  for invalid in '' 0 59 61 1.5 ' 1' '--help'; do
    rm -f "$tmp_dir"/.edit-pre-reviewer.*
    env CODEX_EDIT_PRE_REVIEWER_TIMEOUT="$invalid" TMPDIR="$tmp_dir" \
      bash "$clone/hooks/edit-bash-pre-reviewer.sh" </dev/null >"$out" || return 1
    expect_no_output "$out" &&
      [ -z "$(find "$tmp_dir" -maxdepth 1 -name '.edit-pre-reviewer.*' -print -quit)" ] || return 1
  done

  value="$(bash -c 'BASH=relative; . "$1"' bash \
    "$clone/hooks/edit-bash-pre-reviewer.sh" </dev/null)" || return 1
  [ "$(printf '%s' "$value" | jq -r '.hookSpecificOutput.permissionDecisionReason')" = 58 ] || return 1
  rm -f "$worker" || return 1
  bash "$clone/hooks/edit-bash-pre-reviewer.sh" </dev/null >"$out" || return 1
  expect_no_output "$out" || return 1

  grep -Fq 'exec "$python_command" "$controller"' "$ROOT/hooks/edit-bash-pre-reviewer.sh" &&
    grep -Fq 'OUTPUT_CAP: Final = 4_096' "$ROOT/hooks/lib/edit_bash_pre_reviewer_controller.py" &&
    grep -Fq 'signal.pidfd_send_signal' "$ROOT/hooks/lib/edit_bash_pre_reviewer_controller.py" &&
    grep -Fq '"--kill-child=KILL"' "$ROOT/hooks/lib/edit_bash_pre_reviewer_controller.py" &&
    ! grep -Fq 'CODEX_PRE_REVIEWER_TRACE_FD' "$ROOT/hooks/lib/edit_bash_pre_reviewer_controller.py" &&
    pre_reviewer_controller_has_only_exact_child_kill \
      "$ROOT/hooks/lib/edit_bash_pre_reviewer_controller.py"
}

test_pre_reviewer_controller_matches_lean_lifecycle() {
  local evidence executable stamp verifier
  verifier="$ROOT/hooks/tests/differential/pre-reviewer-controller.sh"
  executable="$CODEX_PRE_REVIEWER_FORMAL_EXE"
  stamp="$CODEX_PRE_REVIEWER_FORMAL_STAMP"
  evidence="$FORMAL_PERSISTENT_ROOT/evidence/controller-lifecycle"
  mkdir -p "$evidence" || return 1
  CODEX_TEST_SKIP_LEAN_BUILD=1 \
    "$verifier" --artifact-root "$evidence" >/dev/null || return 1
  "$verifier" --verify-artifact "$executable" "$stamp"
}

test_pre_reviewer_controller_mutations_are_killed() {
  local audit="$FORMAL_PERSISTENT_ROOT/evidence/controller-mutation-build.audit"
  CODEX_PRE_REVIEWER_BUILD_AUDIT="$audit" \
    CODEX_PRE_REVIEWER_BUILD_AUDIT_ROOT="$FORMAL_PERSISTENT_ROOT" \
    python3 "$ROOT/hooks/tests/test_pre_reviewer_controller_mutations.py" \
      >/dev/null || return 1
  [ ! -e "$audit" ]
}

test_pre_reviewer_identity_record_mutations_are_rejected() {
  python3 "$ROOT/hooks/tests/test_pre_reviewer_python_controller.py" >/dev/null
}

test_pre_reviewer_behavioral_mutations_are_rejected() {
  python3 "$ROOT/hooks/tests/test_pre_reviewer_behavioral_mutations.py" >/dev/null
}

test_pre_reviewer_gate_races_are_rejected() {
  python3 "$ROOT/hooks/tests/test_pre_reviewer_gate_races.py" >/dev/null
}

test_pre_reviewer_formal_stamps_are_bound() {
  python3 "$ROOT/hooks/tests/test_pre_reviewer_formal_stamp.py" >/dev/null
}

test_pre_reviewer_lifecycle_parser_is_exact() {
  python3 "$ROOT/hooks/tests/test_pre_reviewer_lifecycle.py" >/dev/null
}

test_pre_reviewer_admission_inputs_are_bounded() {
  python3 "$ROOT/hooks/tests/test_bounded_hook_input.py" >/dev/null
}

test_pre_reviewer_formal_tmpfs_setup_is_owned() {
  python3 "$ROOT/hooks/tests/test_formal_tmpfs.py" >/dev/null
}

test_process_watchdog_drains_exact_owned_group() {
  python3 "$ROOT/hooks/tests/test_process_watchdog.py" >/dev/null
}

test_pre_reviewer_backend_timeout_is_hard() {
  python3 "$ROOT/hooks/tests/test_reviewer_backend_timeout.py" >/dev/null
}

test_pre_reviewer_timeout_compatibility_probe() {
  "$ROOT/hooks/tests/probe-pre-reviewer-timeout.sh" >/dev/null
}

test_pre_reviewer_capped_capture_probe() {
  CODEX_TEST_SKIP_LEAN_BUILD=1 \
    "$ROOT/hooks/tests/probe-pre-reviewer-cap.sh" >/dev/null
}

test_pre_reviewer_profile_uses_configured_pair() {
  local profile="$profile_report"

  python3 "$ROOT/hooks/tests/test_pre_reviewer_profile_contract.py" >/dev/null || return 1
  python3 "$ROOT/hooks/tests/test_pre_reviewer_profile_ab.py" >/dev/null || return 1
  python3 - "$ROOT" "$profile" "$FORMAL_PERSISTENT_ROOT" \
      "$profile_expected_commit" "$PROFILE_REPORT_SHA256" <<'PY' || return 1
import importlib.util
from pathlib import Path
import sys

root = Path(sys.argv[1])
report_path = Path(sys.argv[2])
output_root = Path(sys.argv[3])
expected_commit = sys.argv[4]
expected_sha256 = sys.argv[5]
module_path = root / "hooks/tests/profile_pre_reviewer_ab.py"
spec = importlib.util.spec_from_file_location("runner_profile_reuse", module_path)
if spec is None or spec.loader is None:
    raise SystemExit(1)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
module.validate_persisted_profile(
    report_path,
    output_root,
    expected_commit,
    expected_sha256=expected_sha256,
)
PY
  [ "$(grep -c '^controller-build$' "$profile_audit")" -eq 1 ] || return 1
  "$controller_verifier" --verify-artifact \
    "$CODEX_PRE_REVIEWER_FORMAL_EXE" "$CODEX_PRE_REVIEWER_FORMAL_STAMP" || return 1
  grep -Eq '^runtime-manifest-before \{"claim":' "$profile" &&
    grep -Eq '^runtime-manifest-after \{"claim":' "$profile" &&
    grep -Eq '^source-identities baseline_commit=[0-9a-f]{40} parent_commit=[0-9a-f]{40} candidate_commit=[0-9a-f]{40} parent_wrapper_sha256=[0-9a-f]{64} candidate_wrapper_sha256=[0-9a-f]{64} parent_python_controller_sha256=(absent|[0-9a-f]{64}) candidate_python_controller_sha256=[0-9a-f]{64} parent_manifest_sha256=[0-9a-f]{64} candidate_manifest_sha256=[0-9a-f]{64} parent_executed=true candidate_executed=true$' "$profile" &&
    grep -Eq '^ab-no-capture parent_raw_ms=' "$profile" &&
    grep -Eq '^ab-prepared-fake parent_raw_ms=' "$profile" &&
    grep -Eq '^compatibility-backend status=(completed-observed|blocked-[^ ]+)' "$profile" &&
    grep -Fxq 'causal-scope transcript_history_scans=0 shared_turn_lock_prune_records_max=0 maintenance_prune_records_max=170 backend_timeout_max_seconds=58 controller_timeout_seconds=70 hook_timeout_seconds=75' "$profile" &&
    grep -Fq 'Two rows per matching Bash invocation are expected; displayed rows alone do not prove that all corresponding processes remain active.' "$profile"
}

write_large_history_main_pre_reviewer_transcript() {
  local path="$1"

  mkdir -p "$(dirname "$path")" || return 1
  printf '%s\n' '{"type":"session_meta","payload":{"id":"t00-session","source":"cli"}}' >"$path"
  printf '%s\n' '{"type":"user","message":{"content":"OLD_HISTORY_POISON_MUST_NOT_BE_READ"}}' >>"$path"
  printf '%12000s\n' '' | tr ' ' x >>"$path"
  [ "$(wc -c <"$path")" -gt 8192 ]
}

submit_current_turn() {
  local proof_root="$1"
  local turn_id="$2"
  local prompt="$3"
  local tag="$4"
  local input="$TMP_ROOT/$tag-submit.json"
  local out="$TMP_ROOT/$tag-submit.out"

  jq -n --arg cwd "$ROOT" --arg turn_id "$turn_id" --arg prompt "$prompt" \
    '{session_id:"t00-session",hook_event_name:"UserPromptSubmit",cwd:$cwd,turn_id:$turn_id,prompt:$prompt}' \
    >"$input" || return 1
  run_hook "$out" "$ROOT/hooks/prompt-task-reminder.sh" "$input" \
    HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" || return 1
  expect_no_output "$out"
}

turn_state_key() {
  local turn_id="$1"

  env HOME="$TMP_ROOT/home" bash -c '. "$1"; codex_hash_string "$2"' \
    bash "$ROOT/hooks/lib/codex-proof-state.sh" \
    "$(jq -cn --arg turn_id "$turn_id" '$turn_id')"
}

turn_capture_path() {
  local proof_root="$1"
  local turn_id="$2"
  local key
  key="$(turn_state_key "$turn_id")" || return 1
  printf '%s/pre-reviewer/t00-session/capture-turn-%s.json\n' "$proof_root" "$key"
}

turn_claim_path() {
  local proof_root="$1"
  local turn_id="$2"
  local key
  key="$(turn_state_key "$turn_id")" || return 1
  printf '%s/pre-reviewer/t00-session/claim-turn-%s\n' "$proof_root" "$key"
}

test_pre_reviewer_lock_is_bounded_and_fileless() {
  local state_dir holder_fd started_ns ended_ns elapsed_ms status
  state_dir="$TMP_ROOT/pre-reviewer-bounded-lock"
  mkdir -m 0700 "$state_dir" || return 1
  exec {holder_fd}<"$state_dir" || return 1
  flock -x "$holder_fd" || return 1
  started_ns="$(date +%s%N)" || return 1
  status=0
  env CODEX_PRE_REVIEWER_LOCK_TIMEOUT=2 bash -c '
    . "$1"
    codex_lock_pre_reviewer_turn "$2"
  ' bash "$ROOT/hooks/lib/pre-reviewer-turn-state.sh" "$state_dir" || status=$?
  ended_ns="$(date +%s%N)" || return 1
  flock -u "$holder_fd" || return 1
  exec {holder_fd}>&-
  elapsed_ms=$(((ended_ns - started_ns) / 1000000))

  [ "$status" -ne 0 ] && [ "$elapsed_ms" -lt 2000 ] &&
    [ "$(find "$state_dir" -maxdepth 1 -type f -name 'lock-turn-*' | wc -l)" -eq 0 ] &&
    grep -Eq 'flock[[:space:]]+-x[[:space:]]+-w' \
      "$ROOT/hooks/lib/pre-reviewer-turn-state.sh" &&
    ! grep -q 'lock-turn-' "$ROOT/hooks/lib/pre-reviewer-turn-state.sh"
}

write_flock_timeout_argv_spy() {
  local bin_dir="$1"

  mkdir -p "$bin_dir" || return 1
  cat >"$bin_dir/flock" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = -x ] && [ "${2:-}" = -w ]; then
  printf '%s\n' "${3:-}" >"$CODEX_TEST_FLOCK_TIMEOUT_ARG"
  exit 0
fi
if [ "${1:-}" = -u ]; then
  exit 0
fi
exit 99
SH
  chmod 0755 "$bin_dir/flock"
}

test_pre_reviewer_lock_timeout_accepts_only_zero_through_one() {
  local state_dir bin_dir observed value
  local -a accepted rejected
  state_dir="$TMP_ROOT/pre-reviewer-lock-timeout-values"
  bin_dir="$TMP_ROOT/pre-reviewer-lock-timeout-values-bin"
  mkdir -m 0700 "$state_dir" || return 1
  write_flock_timeout_argv_spy "$bin_dir" || return 1
  accepted=(0 00 0.0 000.999 1 01 1.0 001.000)
  rejected=(
    "" 2 0002 1.0001 01.1 -0 +0 .5 0. 1. 1e0
    " 1" "1 " $'\t1' 0x1 one 1second ١ １
    99999999999999999999999999999999999999999999999999
  )

  for value in "${accepted[@]}"; do
    rm -f "$TMP_ROOT/flock-timeout-arg"
    env PATH="$bin_dir:$PATH" \
      CODEX_TEST_FLOCK_TIMEOUT_ARG="$TMP_ROOT/flock-timeout-arg" \
      CODEX_PRE_REVIEWER_LOCK_TIMEOUT="$value" bash -c '
        . "$1"
        codex_lock_pre_reviewer_turn "$2" || exit 1
        codex_unlock_pre_reviewer_turn
      ' bash "$ROOT/hooks/lib/pre-reviewer-turn-state.sh" "$state_dir" || return 1
    IFS= read -r observed <"$TMP_ROOT/flock-timeout-arg" || return 1
    [ "$observed" = "$value" ] || return 1
  done

  for value in "${rejected[@]}"; do
    rm -f "$TMP_ROOT/flock-timeout-arg"
    env PATH="$bin_dir:$PATH" \
      CODEX_TEST_FLOCK_TIMEOUT_ARG="$TMP_ROOT/flock-timeout-arg" \
      CODEX_PRE_REVIEWER_LOCK_TIMEOUT="$value" bash -c '
        . "$1"
        codex_lock_pre_reviewer_turn "$2" || exit 1
        codex_unlock_pre_reviewer_turn
      ' bash "$ROOT/hooks/lib/pre-reviewer-turn-state.sh" "$state_dir" || return 1
    IFS= read -r observed <"$TMP_ROOT/flock-timeout-arg" || return 1
    [ "$observed" = 1 ] || return 1
  done

  grep -Fq '[[ "$timeout" =~ ^(0+([.][0123456789]+)?|0*1([.]0+)?)$ ]] || timeout=1' \
    "$ROOT/hooks/lib/pre-reviewer-turn-state.sh"
}

test_pre_reviewer_lock_revalidates_after_waiting_path_swap() {
  local state_dir moved_dir bin_dir ready holder_fd ready_fd ready_signal pid status
  state_dir="$TMP_ROOT/pre-reviewer-lock-swap"
  moved_dir="$TMP_ROOT/pre-reviewer-lock-swap-moved"
  bin_dir="$TMP_ROOT/pre-reviewer-lock-swap-bin"
  ready="$TMP_ROOT/pre-reviewer-lock-swap-ready"
  mkdir -m 0700 "$state_dir" || return 1
  exec {holder_fd}<"$state_dir" || return 1
  flock -x "$holder_fd" || return 1
  mkfifo "$ready" || return 1
  exec {ready_fd}<>"$ready" || return 1
  write_signaling_flock_wrapper "$bin_dir" || return 1

  env PATH="$bin_dir:$PATH" CODEX_TEST_LOCK_READY="$ready" \
    CODEX_PRE_REVIEWER_LOCK_TIMEOUT=1 bash -c '
      . "$1"
      if codex_lock_pre_reviewer_turn "$2"; then
        codex_unlock_pre_reviewer_turn
        exit 0
      fi
      exit 1
    ' bash "$ROOT/hooks/lib/pre-reviewer-turn-state.sh" "$state_dir" &
  pid=$!
  if ! IFS= read -r -t 5 -u "$ready_fd" ready_signal || [ "$ready_signal" != ready ]; then
    flock -u "$holder_fd" || true
    exec {holder_fd}>&-
    wait "$pid" 2>/dev/null || true
    exec {ready_fd}>&-
    rm -f "$ready"
    return 1
  fi
  exec {ready_fd}>&-
  rm -f "$ready"
  mv "$state_dir" "$moved_dir" || return 1
  mkdir -m 0700 "$state_dir" || return 1
  flock -u "$holder_fd" || return 1
  exec {holder_fd}>&-
  status=0
  wait "$pid" || status=$?

  [ "$status" -ne 0 ] &&
    env bash -c '
      . "$1"
      codex_lock_pre_reviewer_turn "$2" || exit 1
      codex_unlock_pre_reviewer_turn
    ' bash "$ROOT/hooks/lib/pre-reviewer-turn-state.sh" "$state_dir"
}

test_pre_reviewer_lock_revalidates_private_mode_after_waiting() {
  local state_dir bin_dir ready holder_fd ready_fd ready_signal pid status
  state_dir="$TMP_ROOT/pre-reviewer-lock-mode-change"
  bin_dir="$TMP_ROOT/pre-reviewer-lock-mode-change-bin"
  ready="$TMP_ROOT/pre-reviewer-lock-mode-change-ready"
  mkdir -m 0700 "$state_dir" || return 1
  exec {holder_fd}<"$state_dir" || return 1
  flock -x "$holder_fd" || return 1
  mkfifo "$ready" || return 1
  exec {ready_fd}<>"$ready" || return 1
  write_signaling_flock_wrapper "$bin_dir" || return 1

  env PATH="$bin_dir:$PATH" CODEX_TEST_LOCK_READY="$ready" \
    CODEX_PRE_REVIEWER_LOCK_TIMEOUT=1 bash -c '
      . "$1"
      if codex_lock_pre_reviewer_turn "$2"; then
        codex_unlock_pre_reviewer_turn
        exit 0
      fi
      exit 1
    ' bash "$ROOT/hooks/lib/pre-reviewer-turn-state.sh" "$state_dir" &
  pid=$!
  if ! IFS= read -r -t 5 -u "$ready_fd" ready_signal || [ "$ready_signal" != ready ]; then
    flock -u "$holder_fd" || true
    exec {holder_fd}>&-
    wait "$pid" 2>/dev/null || true
    exec {ready_fd}>&-
    rm -f "$ready"
    return 1
  fi
  exec {ready_fd}>&-
  rm -f "$ready"
  chmod 0755 "$state_dir" || return 1
  flock -u "$holder_fd" || return 1
  exec {holder_fd}>&-
  status=0
  wait "$pid" || status=$?
  chmod 0700 "$state_dir" || return 1

  [ "$status" -ne 0 ]
}

test_many_turns_leave_no_lock_files() {
  local proof_root state_dir index
  proof_root="$(fresh_proof_root pre-reviewer-many-turns-no-lock-files)"
  state_dir="$proof_root/pre-reviewer/t00-session"
  for index in $(seq 1 128); do
    submit_current_turn "$proof_root" "turn-$index" "PROMPT_$index" \
      "pre-reviewer-many-turns-$index" || return 1
  done

  [ "$(find "$state_dir" -maxdepth 1 -type f -name 'lock-turn-*' | wc -l)" -eq 0 ] &&
    [ "$(find "$state_dir" -maxdepth 1 -type f -name 'capture-turn-*.json' | wc -l)" -eq 128 ]
}

test_pre_reviewer_present_turn_skips_transcript_find() {
  local proof_root bin_dir marker input out body
  proof_root="$(fresh_proof_root pre-reviewer-present-no-find)"
  submit_current_turn "$proof_root" turn-no-find "NO_FIND_CAPTURE" \
    pre-reviewer-present-no-find || return 1
  bin_dir="$TMP_ROOT/pre-reviewer-present-no-find-bin"
  marker="$TMP_ROOT/pre-reviewer-present-no-find-called"
  mkdir -p "$bin_dir" || return 1
  cat >"$bin_dir/find" <<'SH'
#!/usr/bin/env bash
printf 'called\n' >"$CODEX_TEST_FIND_MARKER"
exit 99
SH
  chmod 0755 "$bin_dir/find"
  input="$TMP_ROOT/pre-reviewer-present-no-find.json"
  jq -n --arg cwd "$ROOT" \
    '{session_id:"t00-session",tool_name:"Bash",turn_id:"turn-no-find",cwd:$cwd,
      tool_input:{command:"sed -n 1,20p hooks/stop-gate.sh"}}' >"$input" || return 1
  out="$TMP_ROOT/pre-reviewer-present-no-find.out"
  body="$TMP_ROOT/pre-reviewer-present-no-find-body.md"

  run_hook "$out" "$ROOT/hooks/edit-bash-pre-reviewer.sh" "$input" \
    PATH="$bin_dir:$PATH" HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" \
    CODEX_TEST_FIND_MARKER="$marker" \
    CODEX_EDIT_PRE_REVIEWER="ollama:http://127.0.0.1:11434:qwen3:4b" \
    CODEX_PRE_REVIEWER_DEBUG_BODY_PATH="$body" \
    CODEX_PRE_REVIEWER_FAKE_RESULT='{"verdict":"deny","reason":"No find."}' || return 1

  is_pretool_deny "$out" && grep -Fq NO_FIND_CAPTURE "$body" && [ ! -e "$marker" ]
}

write_blocking_perl_wrapper() {
  local bin_dir="$1"
  local real_perl

  real_perl="$(command -v perl)" || return 1
  mkdir -p "$bin_dir" || return 1
  cat >"$bin_dir/perl" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [ -n "\${CODEX_TEST_CAPTURE_READY:-}" ]; then
  printf 'ready\n' >"\$CODEX_TEST_CAPTURE_READY"
  exec {release_fd}<>"\$CODEX_TEST_CAPTURE_RELEASE"
  cleanup_release_fd() { exec {release_fd}>&-; }
  trap cleanup_release_fd EXIT
  trap 'cleanup_release_fd; exit 0' HUP INT TERM
  read -r -u "\$release_fd" release
  [ "\$release" = release ]
  cleanup_release_fd
  trap - EXIT HUP INT TERM
fi
exec "$real_perl" "\$@"
EOF
  chmod 0755 "$bin_dir/perl"
}

write_blocking_validation_python_wrapper() {
  local bin_dir="$1"
  local real_python

  real_python="$(command -v python3)" || return 1
  mkdir -p "$bin_dir" || return 1
  cat >"$bin_dir/python3" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ " \$* " == *turn_capture_validator.py* ]] && [ ! -e "\$CODEX_TEST_ONCE" ]; then
  : >"\$CODEX_TEST_ONCE"
  printf 'ready\n' >"\$CODEX_TEST_VALIDATION_READY"
  exec {release_fd}<>"\$CODEX_TEST_VALIDATION_RELEASE"
  cleanup_release_fd() { exec {release_fd}>&-; }
  trap cleanup_release_fd EXIT
  trap 'cleanup_release_fd; exit 0' HUP INT TERM
  read -r -u "\$release_fd" release
  [ "\$release" = release ]
  cleanup_release_fd
  trap - EXIT HUP INT TERM
fi
exec "$real_python" "\$@"
EOF
  chmod 0755 "$bin_dir/python3"
}

write_signaling_flock_wrapper() {
  local bin_dir="$1"
  local real_flock

  real_flock="$(command -v flock)" || return 1
  mkdir -p "$bin_dir" || return 1
  cat >"$bin_dir/flock" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [ "\${1:-}" = -x ] && [ -n "\${CODEX_TEST_LOCK_READY:-}" ]; then
  printf 'ready\n' >"\$CODEX_TEST_LOCK_READY"
fi
exec "$real_flock" "\$@"
EOF
  chmod 0755 "$bin_dir/flock"
}

test_prompt_capture_distinct_turns_overlap_without_overwrite() {
  local proof_root state_dir bin_dir ready release input_a input_b out_a out_b pid_a ready_fd release_fd
  local key_a key_b capture_a capture_b redacted_tmp ready_signal wait_status
  proof_root="$(fresh_proof_root prompt-capture-distinct-overlap)"
  state_dir="$proof_root/pre-reviewer/t00-session"
  bin_dir="$TMP_ROOT/prompt-capture-distinct-overlap-bin"
  ready="$TMP_ROOT/prompt-capture-distinct-overlap-ready"
  release="$TMP_ROOT/prompt-capture-distinct-overlap-release"
  mkfifo "$ready" "$release" || return 1
  exec {ready_fd}<>"$ready" || return 1
  exec {release_fd}<>"$release" || { exec {ready_fd}>&-; return 1; }
  write_blocking_perl_wrapper "$bin_dir" || return 1
  input_a="$TMP_ROOT/prompt-capture-distinct-overlap-a.json"
  input_b="$TMP_ROOT/prompt-capture-distinct-overlap-b.json"
  jq -n --arg cwd "$ROOT" \
    '{session_id:"t00-session",hook_event_name:"UserPromptSubmit",cwd:$cwd,turn_id:"turn-a",prompt:"PROMPT_A"}' \
    >"$input_a" || return 1
  jq -n --arg cwd "$ROOT" \
    '{session_id:"t00-session",hook_event_name:"UserPromptSubmit",cwd:$cwd,turn_id:"turn-b",prompt:"PROMPT_B"}' \
    >"$input_b" || return 1
  out_a="$TMP_ROOT/prompt-capture-distinct-overlap-a.out"
  out_b="$TMP_ROOT/prompt-capture-distinct-overlap-b.out"

  run_hook "$out_a" "$ROOT/hooks/prompt-task-reminder.sh" "$input_a" \
    PATH="$bin_dir:$PATH" HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" \
    CODEX_TEST_CAPTURE_READY="$ready" CODEX_TEST_CAPTURE_RELEASE="$release" &
  pid_a=$!
  if ! IFS= read -r -t 5 -u "$ready_fd" ready_signal || [ "$ready_signal" != ready ]; then
    printf 'release\n' >&"$release_fd" || true
    kill "$pid_a" 2>/dev/null || true
    wait "$pid_a" 2>/dev/null || true
    exec {ready_fd}>&-
    exec {release_fd}>&-
    rm -f "$ready" "$release"
    return 1
  fi
  redacted_tmp=$(find "$state_dir" -maxdepth 1 -type f -name '.capture-turn-*.redacted.*' -print -quit)
  if [ -z "$redacted_tmp" ] || [ "$(stat -c '%a' "$redacted_tmp")" != 600 ] ||
      ! run_hook "$out_b" "$ROOT/hooks/prompt-task-reminder.sh" "$input_b" \
        HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root"; then
    printf 'release\n' >&"$release_fd" || true
    kill "$pid_a" 2>/dev/null || true
    wait "$pid_a" 2>/dev/null || true
    exec {ready_fd}>&-
    exec {release_fd}>&-
    rm -f "$ready" "$release"
    return 1
  fi
  printf 'release\n' >&"$release_fd"
  wait_status=0
  wait "$pid_a" || wait_status=$?
  exec {ready_fd}>&-
  exec {release_fd}>&-
  rm -f "$ready" "$release"
  [ "$wait_status" -eq 0 ] || return 1

  key_a="$(turn_state_key turn-a)" || return 1
  key_b="$(turn_state_key turn-b)" || return 1
  capture_a="$state_dir/capture-turn-$key_a.json"
  capture_b="$state_dir/capture-turn-$key_b.json"
  expect_no_output "$out_a" && expect_no_output "$out_b" &&
    jq -e '.turn_id == "turn-a" and .prompt == "PROMPT_A"' "$capture_a" >/dev/null &&
    jq -e '.turn_id == "turn-b" and .prompt == "PROMPT_B"' "$capture_b" >/dev/null &&
    [ "$(stat -c '%a' "$capture_a")" = 600 ] && [ "$(stat -c '%a' "$capture_b")" = 600 ]
}

test_prompt_cap_failure_leaves_no_same_key_reusable_state() {
  local proof_root state_dir capture claim bin_dir input out real_python
  proof_root="$(fresh_proof_root prompt-cap-failure)"
  state_dir="$proof_root/pre-reviewer/t00-session"
  submit_current_turn "$proof_root" turn-cap-failure "OLD_CAPTURE" prompt-cap-failure-old || return 1
  capture="$(turn_capture_path "$proof_root" turn-cap-failure)" || return 1
  claim="$(turn_claim_path "$proof_root" turn-cap-failure)" || return 1
  bin_dir="$TMP_ROOT/prompt-cap-failure-bin"
  mkdir -p "$bin_dir" || return 1
  real_python="$(command -v python3)" || return 1
  cat >"$bin_dir/python3" <<SH
#!/usr/bin/env bash
if [[ "\${1:-}" == *utf8_prefix_cap.py ]]; then
  exit 1
fi
exec "$real_python" "\$@"
SH
  chmod 0755 "$bin_dir/python3"
  input="$TMP_ROOT/prompt-cap-failure.json"
  jq -n --arg cwd "$ROOT" \
    '{session_id:"t00-session",hook_event_name:"UserPromptSubmit",cwd:$cwd,
      turn_id:"turn-cap-failure",prompt:"NEW_CAPTURE"}' >"$input" || return 1
  out="$TMP_ROOT/prompt-cap-failure.out"

  run_hook "$out" "$ROOT/hooks/prompt-task-reminder.sh" "$input" \
    PATH="$bin_dir:$PATH" HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" || return 1

  expect_no_output "$out" && [ ! -e "$capture" ] && [ ! -e "$claim" ] &&
    [ "$(find "$state_dir" -maxdepth 1 -type f -name '.capture-turn-*' | wc -l)" -eq 0 ]
}

test_turn_state_pruning_is_old_regular_file_and_namespace_scoped() {
  local state_dir old_capture old_temp old_claim fresh_capture bypass other
  state_dir="$TMP_ROOT/prune-turn-state"
  mkdir -m 0700 "$state_dir" || return 1
  old_capture="$state_dir/capture-turn-old.json"
  old_temp="$state_dir/.capture-turn-old.capped.ABCDEF"
  old_claim="$state_dir/claim-turn-old"
  fresh_capture="$state_dir/capture-turn-fresh.json"
  bypass="$state_dir/bypass"
  other="$state_dir/unrelated"
  : >"$old_capture"
  : >"$old_temp"
  : >"$old_claim"
  : >"$fresh_capture"
  : >"$bypass"
  : >"$other"
  mkdir "$state_dir/capture-turn-old-directory.json" || return 1
  touch -d '2 hours ago' "$old_capture" "$old_temp" "$old_claim" "$bypass" "$other" \
    "$state_dir/capture-turn-old-directory.json" || return 1

  env HOME="$TMP_ROOT/home" bash -c \
    '. "$1"; codex_prune_pre_reviewer_turn_state "$2"' \
    bash "$ROOT/hooks/lib/pre-reviewer-turn-state.sh" "$state_dir" || return 1

  [ ! -e "$old_capture" ] && [ ! -e "$old_temp" ] && [ ! -e "$old_claim" ] &&
    [ -e "$fresh_capture" ] && [ -e "$bypass" ] && [ -e "$other" ] &&
    [ -d "$state_dir/capture-turn-old-directory.json" ]
}

test_turn_state_pruning_rejects_shared_lock_and_runs_after_release() {
  local state_dir old_claim
  state_dir="$TMP_ROOT/prune-turn-state-unlocked"
  mkdir -m 0700 "$state_dir" || return 1
  old_claim="$state_dir/claim-turn-old"
  : >"$old_claim"
  touch -d '2 hours ago' "$old_claim" || return 1

  env HOME="$TMP_ROOT/home" bash -c \
    '. "$1"
      codex_lock_pre_reviewer_turn "$2" || exit 1
      if codex_prune_pre_reviewer_turn_state "$2"; then exit 1; fi
      codex_unlock_pre_reviewer_turn
      codex_prune_pre_reviewer_turn_state "$2"' \
    bash "$ROOT/hooks/lib/pre-reviewer-turn-state.sh" "$state_dir" || return 1
  [ ! -e "$old_claim" ]
}

populate_retained_turn_state() {
  local state_dir="$1"
  local old_count="$2"
  local fresh_count="$3"
  local index path
  local -a old_paths

  old_paths=()
  for index in $(seq 1 "$old_count"); do
    case $((index % 4)) in
      0) path="$state_dir/capture-turn-retained-old-$index.json" ;;
      1) path="$state_dir/claim-turn-retained-old-$index" ;;
      2) path="$state_dir/.capture-turn-retained-old-$index.capped.A$index" ;;
      3) path="$state_dir/.capture-turn-retained-old-$index.prompt.A$index" ;;
    esac
    : >"$path" || return 1
    old_paths+=("$path")
  done
  touch -d '2 hours ago' "${old_paths[@]}" || return 1
  for index in $(seq 1 "$fresh_count"); do
    : >"$state_dir/claim-turn-retained-fresh-$index" || return 1
  done
}

write_prune_observer_python_wrapper() {
  local bin_dir="$1"
  local real_python

  real_python="$(command -v python3)" || return 1
  mkdir -p "$bin_dir" || return 1
  cat >"$bin_dir/python3" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" == *prune_pre_reviewer_turn_state.py ]]; then
  printf 'prune\n' >>"\$CODEX_TEST_PRUNE_TRACE"
  if [ "\${CODEX_TEST_PRUNE_FATAL:-}" = 1 ]; then
    exit 99
  fi
fi
exec "$real_python" "\$@"
EOF
  chmod 0755 "$bin_dir/python3"
}

write_stat_rm_observer_wrappers() {
  local bin_dir="$1"
  local real_stat real_rm command_name

  real_stat="$(command -v stat)" || return 1
  real_rm="$(command -v rm)" || return 1
  mkdir -p "$bin_dir" || return 1
  for command_name in stat rm; do
    cat >"$bin_dir/$command_name" <<EOF
#!/usr/bin/env bash
set -euo pipefail
command_name=\${0##*/}
printf '%s\n' "\$command_name" >>"\$CODEX_TEST_COMMAND_TRACE"
case "\$command_name" in
  stat) exec "$real_stat" "\$@" ;;
  rm) exec "$real_rm" "\$@" ;;
  *) exit 99 ;;
esac
EOF
    chmod 0755 "$bin_dir/$command_name"
  done
}

trace_count() {
  local pattern="$1"
  local path="$2"
  awk -v pattern="$pattern" '$0 == pattern { count++ } END { print count + 0 }' "$path"
}

test_present_turn_with_retained_state_skips_pruner() {
  local proof_root state_dir transcript input out body bin_dir trace capture
  local started_ns ended_ns elapsed_ms
  proof_root="$(fresh_proof_root pre-reviewer-retained-no-prune)"
  state_dir="$proof_root/pre-reviewer/t00-session"
  transcript="$TMP_ROOT/home/.codex/sessions/pre-reviewer-retained-no-prune.jsonl"
  write_large_history_main_pre_reviewer_transcript "$transcript" || return 1
  submit_current_turn "$proof_root" retained-current CURRENT_CAPTURE retained-current || return 1
  populate_retained_turn_state "$state_dir" 2000 0 || return 1
  input="$TMP_ROOT/pre-reviewer-retained-no-prune.json"
  write_present_pre_reviewer_input "$transcript" retained-current "$input" || return 1
  out="$TMP_ROOT/pre-reviewer-retained-no-prune.out"
  body="$TMP_ROOT/pre-reviewer-retained-no-prune-body.md"
  bin_dir="$TMP_ROOT/pre-reviewer-retained-no-prune-bin"
  trace="$TMP_ROOT/pre-reviewer-retained-no-prune.trace"
  : >"$trace"
  write_prune_observer_python_wrapper "$bin_dir" || return 1

  started_ns="$(date +%s%N)" || return 1
  run_hook "$out" "$ROOT/hooks/edit-bash-pre-reviewer.sh" "$input" \
    PATH="$bin_dir:$PATH" HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" \
    CODEX_TEST_PRUNE_TRACE="$trace" CODEX_TEST_PRUNE_FATAL=1 \
    CODEX_EDIT_PRE_REVIEWER="ollama:http://127.0.0.1:11434:qwen3:4b" \
    CODEX_PRE_REVIEWER_DEBUG_BODY_PATH="$body" \
    CODEX_PRE_REVIEWER_FAKE_RESULT='{"verdict":"deny","reason":"Retained state."}' || return 1
  ended_ns="$(date +%s%N)" || return 1
  elapsed_ms=$(((ended_ns - started_ns) / 1000000))
  capture="$(turn_capture_path "$proof_root" retained-current)" || return 1

  is_pretool_deny "$out" && grep -Fq CURRENT_CAPTURE "$body" &&
    [ ! -e "$capture" ] && [ ! -s "$trace" ] && [ "$elapsed_ms" -lt 2000 ] &&
    [ "$(find "$state_dir" -maxdepth 1 -type f -name 'claim-turn-retained-old-*' | wc -l)" -eq 500 ] &&
    [ "$(find "$state_dir" -maxdepth 1 -type f -name 'capture-turn-retained-old-*.json' | wc -l)" -eq 500 ] &&
    [ "$(find "$state_dir" -maxdepth 1 -type f -name '.capture-turn-retained-old-*' | wc -l)" -eq 1000 ] &&
    ! grep -q 'codex_prune_pre_reviewer_turn_state' "$ROOT/hooks/edit-bash-pre-reviewer.sh"
}

test_prompt_retained_state_prunes_once_without_per_file_subprocesses() {
  local proof_root state_dir bin_dir trace command_trace baseline_stat baseline_rm
  local input out capture captured remaining_old invocation max_invocations made_progress
  proof_root="$(fresh_proof_root prompt-retained-one-pass)"
  state_dir="$proof_root/pre-reviewer/t00-session"
  bin_dir="$TMP_ROOT/prompt-retained-one-pass-bin"
  trace="$TMP_ROOT/prompt-retained-one-pass-prune.trace"
  command_trace="$TMP_ROOT/prompt-retained-one-pass-command.trace"
  write_prune_observer_python_wrapper "$bin_dir" || return 1
  write_stat_rm_observer_wrappers "$bin_dir" || return 1
  : >"$trace"
  : >"$command_trace"
  input="$TMP_ROOT/prompt-retained-baseline.json"
  jq -n --arg cwd "$ROOT" \
    '{session_id:"t00-session",hook_event_name:"UserPromptSubmit",cwd:$cwd,
      turn_id:"baseline",prompt:"BASELINE"}' >"$input" || return 1
  run_hook "$TMP_ROOT/prompt-retained-baseline.out" "$ROOT/hooks/prompt-task-reminder.sh" "$input" \
    PATH="$bin_dir:$PATH" HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" \
    CODEX_TEST_PRUNE_TRACE="$trace" CODEX_TEST_COMMAND_TRACE="$command_trace" || return 1
  [ "$(trace_count prune "$trace")" -eq 1 ] || return 1
  baseline_stat="$(trace_count stat "$command_trace")"
  baseline_rm="$(trace_count rm "$command_trace")"

  populate_retained_turn_state "$state_dir" 2000 500 || return 1
  rm -f "$state_dir/.prune-cursor" || return 1
  : >"$trace"
  : >"$command_trace"
  input="$TMP_ROOT/prompt-retained-populated.json"
  jq -n --arg cwd "$ROOT" \
    '{session_id:"t00-session",hook_event_name:"UserPromptSubmit",cwd:$cwd,
      turn_id:"current-retained",prompt:"CURRENT_RETAINED"}' >"$input" || return 1
  out="$TMP_ROOT/prompt-retained-populated.out"
  invocation=0
  max_invocations=64
  made_progress=0
  remaining_old=2000
  while [ "$invocation" -lt "$max_invocations" ]; do
    invocation=$((invocation + 1))
    : >"$trace"
    : >"$command_trace"
    run_hook "$out" "$ROOT/hooks/prompt-task-reminder.sh" "$input" \
      PATH="$bin_dir:$PATH" HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" \
      CODEX_TEST_PRUNE_TRACE="$trace" CODEX_TEST_COMMAND_TRACE="$command_trace" || return 1
    capture="$(turn_capture_path "$proof_root" current-retained)" || return 1
    captured="$(jq -r '.prompt' "$capture" 2>/dev/null)" || return 1
    remaining_old="$(find "$state_dir" -maxdepth 1 -type f -name '*retained-old-*' | wc -l)"

    expect_no_output "$out" && [ "$captured" = CURRENT_RETAINED ] &&
      [ "$(trace_count prune "$trace")" -eq 1 ] &&
      [ "$(trace_count stat "$command_trace")" -eq "$baseline_stat" ] &&
      [ "$(trace_count rm "$command_trace")" -eq "$baseline_rm" ] &&
      [ "$(find "$state_dir" -maxdepth 1 -type f -name 'claim-turn-retained-fresh-*' | wc -l)" -eq 500 ] || return 1
    if [ "$remaining_old" -lt 2000 ]; then
      made_progress=1
      break
    fi
  done

  [ "$made_progress" -eq 1 ] && [ "$remaining_old" -ge 1830 ]
}

write_pausing_prune_python_wrapper() {
  local bin_dir="$1"
  local real_python

  real_python="$(command -v python3)" || return 1
  mkdir -p "$bin_dir" || return 1
  cat >"$bin_dir/python3" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" == *prune_pre_reviewer_turn_state.py ]]; then
  printf 'ready\n' >"\$CODEX_TEST_PRUNE_READY"
  exec {release_fd}<>"\$CODEX_TEST_PRUNE_RELEASE"
  cleanup_release_fd() { exec {release_fd}>&-; }
  trap cleanup_release_fd EXIT
  trap 'cleanup_release_fd; exit 0' HUP INT TERM
  IFS= read -r -u "\$release_fd" release
  [ "\$release" = release ]
  cleanup_release_fd
  trap - EXIT HUP INT TERM
fi
exec "$real_python" "\$@"
EOF
  chmod 0755 "$bin_dir/python3"
}

test_paused_prompt_pruning_does_not_block_concurrent_pretool() {
  local proof_root state_dir transcript prompt_input prompt_out pre_input pre_out bin_dir
  local ready release ready_fd release_fd signal prompt_pid started_ns ended_ns elapsed_ms
  proof_root="$(fresh_proof_root paused-prompt-pruning)"
  state_dir="$proof_root/pre-reviewer/t00-session"
  transcript="$TMP_ROOT/home/.codex/sessions/paused-prompt-pruning.jsonl"
  write_large_history_main_pre_reviewer_transcript "$transcript" || return 1
  bin_dir="$TMP_ROOT/paused-prompt-pruning-bin"
  ready="$TMP_ROOT/paused-prompt-pruning-ready"
  release="$TMP_ROOT/paused-prompt-pruning-release"
  mkfifo "$ready" "$release" || return 1
  exec {ready_fd}<>"$ready" || return 1
  exec {release_fd}<>"$release" || return 1
  write_pausing_prune_python_wrapper "$bin_dir" || return 1
  prompt_input="$TMP_ROOT/paused-prompt-pruning-submit.json"
  jq -n --arg cwd "$ROOT" \
    '{session_id:"t00-session",hook_event_name:"UserPromptSubmit",cwd:$cwd,
      turn_id:"paused-turn",prompt:"PAUSED_CAPTURE"}' >"$prompt_input" || return 1
  prompt_out="$TMP_ROOT/paused-prompt-pruning-submit.out"
  run_hook "$prompt_out" "$ROOT/hooks/prompt-task-reminder.sh" "$prompt_input" \
    PATH="$bin_dir:$PATH" HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" \
    CODEX_TEST_PRUNE_READY="$ready" CODEX_TEST_PRUNE_RELEASE="$release" &
  prompt_pid=$!
  if ! IFS= read -r -t 5 -u "$ready_fd" signal || [ "$signal" != ready ]; then
    printf 'release\n' >&"$release_fd" || true
    wait "$prompt_pid" 2>/dev/null || true
    exec {ready_fd}>&-
    exec {release_fd}>&-
    rm -f "$ready" "$release"
    return 1
  fi

  pre_input="$TMP_ROOT/paused-prompt-pruning-pretool.json"
  write_present_pre_reviewer_input "$transcript" paused-turn "$pre_input" || return 1
  pre_out="$TMP_ROOT/paused-prompt-pruning-pretool.out"
  started_ns="$(date +%s%N)" || return 1
  run_hook "$pre_out" "$ROOT/hooks/edit-bash-pre-reviewer.sh" "$pre_input" \
    HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" \
    CODEX_PRE_REVIEWER_LOCK_TIMEOUT=0.1 \
    CODEX_EDIT_PRE_REVIEWER="ollama:http://127.0.0.1:11434:qwen3:4b" \
    CODEX_PRE_REVIEWER_FAKE_RESULT='{"verdict":"deny","reason":"Must fail open."}' || return 1
  ended_ns="$(date +%s%N)" || return 1
  elapsed_ms=$(((ended_ns - started_ns) / 1000000))
  printf 'release\n' >&"$release_fd" || return 1
  wait "$prompt_pid" || return 1
  exec {ready_fd}>&-
  exec {release_fd}>&-
  rm -f "$ready" "$release"

  is_pretool_deny "$pre_out" && [ "$elapsed_ms" -lt 2000 ] && expect_no_output "$prompt_out" &&
    [ "$(find "$state_dir" -maxdepth 1 -type f -name 'capture-turn-*.json' | wc -l)" -eq 0 ]
}

test_prune_pre_reviewer_turn_state_python_unit_suite() {
  python3 "$ROOT/hooks/tests/test_prune_pre_reviewer_turn_state.py" >/dev/null
}

test_pre_reviewer_pruning_allows_concurrent_publication() {
  python3 "$ROOT/hooks/tests/test_pre_reviewer_prune_contention.py" >/dev/null
}

test_prune_pre_reviewer_turn_state_matches_lean_spec() {
  CODEX_TEST_SKIP_LEAN_BUILD=1 \
    "$ROOT/hooks/tests/differential/prune-turn-state.sh" >/dev/null
}

test_prune_differential_disables_python_bytecode_with_parent_env_unset() {
  find "$ROOT/hooks" -type d -name __pycache__ -prune -exec rm -rf {} +
  env -u PYTHONDONTWRITEBYTECODE CODEX_TEST_SKIP_LEAN_BUILD=1 \
    "$ROOT/hooks/tests/differential/prune-turn-state.sh" >/dev/null || return 1
  [ -z "$(find "$ROOT/hooks" -type d -name __pycache__ -print -quit)" ]
}

test_generated_fifo_wrappers_use_owned_blocking_release_descriptors() {
  [ "$(grep -c 'exec {release_fd}<>"\\$CODEX_TEST_.*_RELEASE"' "$ROOT/hooks/tests/run.sh")" -eq 3 ] &&
    [ "$(grep -c 'read -r -u "\\$release_fd" release' "$ROOT/hooks/tests/run.sh")" -eq 3 ] &&
    ! grep -q 'read -r -t 1 -u "\\$release_fd"' "$ROOT/hooks/tests/run.sh" ||
    return 1
  test_generated_fifo_wrapper_release_timeouts
}

test_generated_fifo_wrapper_release_timeouts() {
  local bin_dir kind kind_bin wrapper ready release ready_fd pid_file status_file launcher
  local status wrapper_pid signal
  local -a command
  bin_dir="$TMP_ROOT/generated-fifo-bounded-bin"

  for kind in capture validation prune; do
    kind_bin="$bin_dir/$kind"
    ready="$TMP_ROOT/generated-fifo-$kind-ready"
    release="$TMP_ROOT/generated-fifo-$kind-release"
    pid_file="$TMP_ROOT/generated-fifo-$kind.pid"
    status_file="$TMP_ROOT/generated-fifo-$kind.status"
    case "$kind" in
      capture)
        write_blocking_perl_wrapper "$kind_bin" || return 1
        wrapper="$kind_bin/perl"
        command=(env CODEX_TEST_CAPTURE_READY="$ready" CODEX_TEST_CAPTURE_RELEASE="$release"
          "$wrapper" -e 1)
        ;;
      validation)
        write_blocking_validation_python_wrapper "$kind_bin" || return 1
        wrapper="$kind_bin/python3"
        command=(env CODEX_TEST_VALIDATION_READY="$ready" CODEX_TEST_VALIDATION_RELEASE="$release"
          CODEX_TEST_ONCE="$TMP_ROOT/generated-fifo-validation-once"
          "$wrapper" "$ROOT/hooks/lib/turn_capture_validator.py")
        ;;
      prune)
        write_pausing_prune_python_wrapper "$kind_bin" || return 1
        wrapper="$kind_bin/python3"
        command=(env CODEX_TEST_PRUNE_READY="$ready" CODEX_TEST_PRUNE_RELEASE="$release"
          "$wrapper" "$ROOT/hooks/lib/prune_pre_reviewer_turn_state.py")
        ;;
    esac
    mkfifo "$ready" "$release" || return 1
    exec {ready_fd}<>"$ready" || return 1
    (
      wrapper_status=0
      python3 - "$pid_file" "${command[@]}" <<'PY' || wrapper_status=$?
import os
import signal
import subprocess
import sys

pid_file, *command = sys.argv[1:]
process = subprocess.Popen(command, start_new_session=True)
with open(pid_file, "w", encoding="ascii") as stream:
    print(process.pid, file=stream)
try:
    process.wait(timeout=0.3)
except subprocess.TimeoutExpired:
    os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=0.2)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
    raise SystemExit(142)
raise SystemExit(process.returncode)
PY
      printf '%s\n' "$wrapper_status" >"$status_file"
    ) &
    launcher=$!
    if ! IFS= read -r -t 2 -u "$ready_fd" signal || [ "$signal" != ready ]; then
      kill "$launcher" 2>/dev/null || true
      wait "$launcher" 2>/dev/null || true
      exec {ready_fd}>&-
      rm -f "$ready" "$release"
      return 1
    fi
    wait "$launcher" || return 1
    exec {ready_fd}>&-
    rm -f "$ready" "$release"
    status="$(cat "$status_file" 2>/dev/null)" || return 1
    wrapper_pid="$(cat "$pid_file" 2>/dev/null)" || return 1
    [ "$status" -eq 142 ] && ! kill -0 "$wrapper_pid" 2>/dev/null || return 1
  done
}

write_present_pre_reviewer_input() {
  local transcript="$1"
  local turn_id="$2"
  local output="$3"

  jq -n --arg cwd "$ROOT" --arg transcript "$transcript" --arg turn_id "$turn_id" \
    '{session_id:"t00-session",tool_name:"Bash",turn_id:$turn_id,transcript_path:$transcript,
      cwd:$cwd,tool_input:{command:"sed -n '1,80p' hooks/stop-gate.sh"}}' >"$output"
}

trace_present_pre_reviewer() {
  local proof_root="$1"
  local input="$2"
  local transcript="$3"
  local out="$4"
  local trace="$5"
  local body="$6"

  strace -f -qq -s 8192 -e trace=read -P "$transcript" -o "$trace" \
    env -u CODEX_ROLE HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" \
      CODEX_EDIT_PRE_REVIEWER="ollama:http://127.0.0.1:11434:qwen3:4b" \
      CODEX_PRE_REVIEWER_DEBUG_BODY_PATH="$body" \
      CODEX_PRE_REVIEWER_FAKE_RESULT='{"verdict":"deny","reason":"Captured current turn."}' \
      bash "$ROOT/hooks/edit-bash-pre-reviewer.sh" <"$input" 2>"$out.err" |
    cat >"$out"
}

present_pre_reviewer_trace_is_first_record_scoped() {
  local trace="$1"
  local transcript="$2"

  trace_is_first_record_scoped "$trace" "$transcript"
}

make_path_without_sha256sum() {
  local bin_dir="$1"
  local command_name command_path

  mkdir -p "$bin_dir" || return 1
  for command_name in bash dirname jq sed mkdir mktemp cat awk cp rm python3 perl \
      flock chmod mv find grep date stat id timeout unshare; do
    command_path="$(command -v "$command_name")" || return 1
    ln -s "$command_path" "$bin_dir/$command_name" || return 1
  done
  [ ! -e "$bin_dir/sha256sum" ]
}

test_hash_fails_open_without_sha256_or_python() {
  local bin_dir out
  bin_dir="$TMP_ROOT/hash-no-sha-no-python-bin"
  out="$TMP_ROOT/hash-no-sha-no-python.out"
  mkdir -p "$bin_dir" || return 1

  if PATH="$bin_dir" /bin/bash -c '. "$1"; codex_hash_string value' \
      bash "$ROOT/hooks/lib/codex-proof-state.sh" >"$out" 2>/dev/null; then
    return 1
  fi
  [ ! -s "$out" ]
}

test_pre_reviewer_present_turn_uses_per_turn_capture_with_first_record_scope() {
  local proof_root transcript input out trace body capture claim
  local turn_id=$'../opaque/turn\nwith spaces'
  proof_root="$(fresh_proof_root pre-reviewer-present-capture)"
  transcript="$TMP_ROOT/home/.codex/sessions/pre-reviewer-present-capture.jsonl"
  write_large_history_main_pre_reviewer_transcript "$transcript" || return 1
  submit_current_turn "$proof_root" "$turn_id" "CURRENT_CAPTURE_ONLY" \
    pre-reviewer-present-capture || return 1
  input="$TMP_ROOT/pre-reviewer-present-capture.json"
  write_present_pre_reviewer_input "$transcript" "$turn_id" "$input" || return 1
  out="$TMP_ROOT/pre-reviewer-present-capture.out"
  trace="$TMP_ROOT/pre-reviewer-present-capture.strace"
  body="$TMP_ROOT/pre-reviewer-present-capture-body.md"

  trace_present_pre_reviewer "$proof_root" "$input" "$transcript" "$out" "$trace" "$body" || return 1
  capture="$(turn_capture_path "$proof_root" "$turn_id")" || return 1
  claim="$(turn_claim_path "$proof_root" "$turn_id")" || return 1
  is_pretool_deny "$out" &&
    grep -Fq 'CURRENT_CAPTURE_ONLY' "$body" &&
    ! grep -Fq 'OLD_HISTORY_POISON_MUST_NOT_BE_READ' "$body" &&
    present_pre_reviewer_trace_is_first_record_scoped "$trace" "$transcript" &&
    [ ! -e "$capture" ] &&
    [ -f "$claim" ] &&
    [ "$(stat -c '%a' "$claim")" = 600 ] &&
    [ "$(basename "$claim")" != *opaque* ] &&
    [ "$(find "$proof_root/pre-reviewer/t00-session" -maxdepth 1 -type f -name '.capture-turn-*.validated.*' | wc -l)" -eq 0 ]
}

test_pre_reviewer_present_turn_claim_uses_hash_fallback() {
  local proof_root transcript input submit_input out body reduced_path claim turn_id
  turn_id='../fallback/turn-id'
  proof_root="$(fresh_proof_root pre-reviewer-present-hash-fallback)"
  transcript="$TMP_ROOT/home/.codex/sessions/pre-reviewer-present-hash-fallback.jsonl"
  write_large_history_main_pre_reviewer_transcript "$transcript" || return 1
  reduced_path="$TMP_ROOT/pre-reviewer-present-hash-fallback-bin"
  make_path_without_sha256sum "$reduced_path" || return 1
  submit_input="$TMP_ROOT/pre-reviewer-present-hash-fallback-submit.json"
  jq -n --arg cwd "$ROOT" --arg turn_id "$turn_id" --arg prompt "HASH_FALLBACK_CAPTURE" \
    '{session_id:"t00-session",hook_event_name:"UserPromptSubmit",cwd:$cwd,turn_id:$turn_id,prompt:$prompt}' \
    >"$submit_input" || return 1
  run_hook "$TMP_ROOT/pre-reviewer-present-hash-fallback-submit.out" \
    "$ROOT/hooks/prompt-task-reminder.sh" "$submit_input" \
    PATH="$reduced_path" HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" || return 1
  input="$TMP_ROOT/pre-reviewer-present-hash-fallback.json"
  write_present_pre_reviewer_input "$transcript" "$turn_id" "$input" || return 1
  out="$TMP_ROOT/pre-reviewer-present-hash-fallback.out"
  body="$TMP_ROOT/pre-reviewer-present-hash-fallback-body.md"
  run_hook "$out" "$ROOT/hooks/edit-bash-pre-reviewer.sh" "$input" \
    PATH="$reduced_path" HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" \
    CODEX_EDIT_PRE_REVIEWER="ollama:http://127.0.0.1:11434:qwen3:4b" \
    CODEX_PRE_REVIEWER_DEBUG_BODY_PATH="$body" \
    CODEX_PRE_REVIEWER_FAKE_RESULT='{"verdict":"deny","reason":"Fallback hash."}' || return 1

  claim=$(find "$proof_root/pre-reviewer/t00-session" -maxdepth 1 -type f -name 'claim-*' -print -quit)
  is_pretool_deny "$out" &&
    grep -Fq 'HASH_FALLBACK_CAPTURE' "$body" &&
    [ -n "$claim" ] &&
    [[ "$(basename "$claim")" =~ ^claim-turn-[0-9a-f]{64}$ ]] &&
    [ "$(basename "$claim")" != *fallback* ]
}

test_pre_reviewer_present_turn_duplicate_is_silent_and_first_record_scoped() {
  local proof_root transcript input first_out second_out trace first_body second_body
  proof_root="$(fresh_proof_root pre-reviewer-present-duplicate)"
  transcript="$TMP_ROOT/home/.codex/sessions/pre-reviewer-present-duplicate.jsonl"
  write_large_history_main_pre_reviewer_transcript "$transcript" || return 1
  submit_current_turn "$proof_root" "turn-duplicate" "DUPLICATE_CAPTURE" \
    pre-reviewer-present-duplicate || return 1
  input="$TMP_ROOT/pre-reviewer-present-duplicate.json"
  write_present_pre_reviewer_input "$transcript" "turn-duplicate" "$input" || return 1
  first_out="$TMP_ROOT/pre-reviewer-present-duplicate-first.out"
  first_body="$TMP_ROOT/pre-reviewer-present-duplicate-first-body.md"
  run_hook "$first_out" "$ROOT/hooks/edit-bash-pre-reviewer.sh" "$input" \
    HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" \
    CODEX_EDIT_PRE_REVIEWER="ollama:http://127.0.0.1:11434:qwen3:4b" \
    CODEX_PRE_REVIEWER_DEBUG_BODY_PATH="$first_body" \
    CODEX_PRE_REVIEWER_FAKE_RESULT='{"verdict":"deny","reason":"Captured current turn."}' || return 1
  second_out="$TMP_ROOT/pre-reviewer-present-duplicate-second.out"
  trace="$TMP_ROOT/pre-reviewer-present-duplicate-second.strace"
  second_body="$TMP_ROOT/pre-reviewer-present-duplicate-second-body.md"
  trace_present_pre_reviewer "$proof_root" "$input" "$transcript" "$second_out" "$trace" "$second_body" || return 1

  is_pretool_deny "$first_out" &&
    [ -s "$first_body" ] &&
    expect_no_output "$second_out" &&
    [ ! -e "$second_body" ] &&
    present_pre_reviewer_trace_is_first_record_scoped "$trace" "$transcript" &&
    [ "$(find "$proof_root/pre-reviewer/t00-session" -maxdepth 1 -type f -name 'claim-*' | wc -l)" -eq 1 ]
}

test_same_turn_resubmit_is_idempotent_after_claim() {
  local proof_root transcript input first_out second_out first_body second_body claim
  local denials bodies
  proof_root="$(fresh_proof_root pre-reviewer-same-turn-resubmit)"
  transcript="$TMP_ROOT/home/.codex/sessions/pre-reviewer-same-turn-resubmit.jsonl"
  write_large_history_main_pre_reviewer_transcript "$transcript" || return 1
  submit_current_turn "$proof_root" same-turn "FIRST_CAPTURE" \
    pre-reviewer-same-turn-first-submit || return 1
  input="$TMP_ROOT/pre-reviewer-same-turn-resubmit.json"
  write_present_pre_reviewer_input "$transcript" same-turn "$input" || return 1
  first_out="$TMP_ROOT/pre-reviewer-same-turn-first.out"
  first_body="$TMP_ROOT/pre-reviewer-same-turn-first-body.md"
  run_hook "$first_out" "$ROOT/hooks/edit-bash-pre-reviewer.sh" "$input" \
    HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" \
    CODEX_EDIT_PRE_REVIEWER="ollama:http://127.0.0.1:11434:qwen3:4b" \
    CODEX_PRE_REVIEWER_DEBUG_BODY_PATH="$first_body" \
    CODEX_PRE_REVIEWER_FAKE_RESULT='{"verdict":"deny","reason":"First only."}' || return 1

  submit_current_turn "$proof_root" same-turn "SECOND_MUST_NOT_PUBLISH" \
    pre-reviewer-same-turn-second-submit || return 1
  second_out="$TMP_ROOT/pre-reviewer-same-turn-second.out"
  second_body="$TMP_ROOT/pre-reviewer-same-turn-second-body.md"
  run_hook "$second_out" "$ROOT/hooks/edit-bash-pre-reviewer.sh" "$input" \
    HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" \
    CODEX_EDIT_PRE_REVIEWER="ollama:http://127.0.0.1:11434:qwen3:4b" \
    CODEX_PRE_REVIEWER_DEBUG_BODY_PATH="$second_body" \
    CODEX_PRE_REVIEWER_FAKE_RESULT='{"verdict":"deny","reason":"Duplicate."}' || return 1

  denials=0
  is_pretool_deny "$first_out" && denials=$((denials + 1))
  is_pretool_deny "$second_out" && denials=$((denials + 1))
  bodies=0
  [ -s "$first_body" ] && bodies=$((bodies + 1))
  [ -s "$second_body" ] && bodies=$((bodies + 1))
  claim="$(turn_claim_path "$proof_root" same-turn)" || return 1
  [ "$denials" -eq 1 ] && [ "$bodies" -eq 1 ] && [ -f "$claim" ] &&
    [ ! -e "$(turn_capture_path "$proof_root" same-turn)" ]
}

test_pre_reviewer_present_turn_capture_failure_clears_stale_and_never_falls_back() {
  local proof_root state_dir transcript prompt_input input out trace body capture claim other_capture
  proof_root="$(fresh_proof_root pre-reviewer-present-capture-failure)"
  state_dir="$proof_root/pre-reviewer/t00-session"
  mkdir -p -m 0700 "$state_dir" || return 1
  capture="$(turn_capture_path "$proof_root" turn-failure)" || return 1
  claim="$(turn_claim_path "$proof_root" turn-failure)" || return 1
  other_capture="$(turn_capture_path "$proof_root" other-turn)" || return 1
  printf '%s\n' '{"turn_id":"turn-failure","prompt":"STALE_CAPTURE"}' >"$capture"
  printf '%s\n' '{"turn_id":"other-turn","prompt":"OTHER_CAPTURE"}' >"$other_capture"
  chmod 0600 "$capture" "$other_capture"
  transcript="$TMP_ROOT/home/.codex/sessions/pre-reviewer-present-capture-failure.jsonl"
  write_large_history_main_pre_reviewer_transcript "$transcript" || return 1
  prompt_input="$TMP_ROOT/pre-reviewer-present-capture-failure-submit.json"
  jq -n --arg cwd "$ROOT" \
    '{session_id:"t00-session",hook_event_name:"UserPromptSubmit",cwd:$cwd,turn_id:"turn-failure",prompt:{bad:true}}' \
    >"$prompt_input" || return 1
  run_hook "$TMP_ROOT/pre-reviewer-present-capture-failure-submit.out" \
    "$ROOT/hooks/prompt-task-reminder.sh" "$prompt_input" \
    HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" || return 1
  input="$TMP_ROOT/pre-reviewer-present-capture-failure.json"
  write_present_pre_reviewer_input "$transcript" "turn-failure" "$input" || return 1
  out="$TMP_ROOT/pre-reviewer-present-capture-failure.out"
  trace="$TMP_ROOT/pre-reviewer-present-capture-failure.strace"
  body="$TMP_ROOT/pre-reviewer-present-capture-failure-body.md"
  trace_present_pre_reviewer "$proof_root" "$input" "$transcript" "$out" "$trace" "$body" || return 1

  expect_no_output "$out" &&
    [ ! -e "$body" ] &&
    [ ! -e "$capture" ] && [ ! -e "$claim" ] && [ -e "$other_capture" ] &&
    present_pre_reviewer_trace_is_first_record_scoped "$trace" "$transcript"
}

test_pre_reviewer_present_turn_mismatch_is_silent_and_first_record_scoped() {
  local proof_root transcript input out trace body
  proof_root="$(fresh_proof_root pre-reviewer-present-mismatch)"
  transcript="$TMP_ROOT/home/.codex/sessions/pre-reviewer-present-mismatch.jsonl"
  write_large_history_main_pre_reviewer_transcript "$transcript" || return 1
  submit_current_turn "$proof_root" "captured-turn" "MISMATCH_CAPTURE" \
    pre-reviewer-present-mismatch || return 1
  input="$TMP_ROOT/pre-reviewer-present-mismatch.json"
  write_present_pre_reviewer_input "$transcript" "other-turn" "$input" || return 1
  out="$TMP_ROOT/pre-reviewer-present-mismatch.out"
  trace="$TMP_ROOT/pre-reviewer-present-mismatch.strace"
  body="$TMP_ROOT/pre-reviewer-present-mismatch-body.md"
  trace_present_pre_reviewer "$proof_root" "$input" "$transcript" "$out" "$trace" "$body" || return 1

  expect_no_output "$out" &&
    [ ! -e "$body" ] &&
    [ "$(find "$proof_root/pre-reviewer/t00-session" -maxdepth 1 -type f -name 'claim-*' | wc -l)" -eq 0 ] &&
    present_pre_reviewer_trace_is_first_record_scoped "$trace" "$transcript"
}

test_pre_reviewer_hash_collision_fails_open_without_claim() {
  local proof_root state_dir transcript input out body capture claim
  proof_root="$(fresh_proof_root pre-reviewer-hash-collision)"
  state_dir="$proof_root/pre-reviewer/t00-session"
  mkdir -p -m 0700 "$state_dir" || return 1
  transcript="$TMP_ROOT/home/.codex/sessions/pre-reviewer-hash-collision.jsonl"
  write_large_history_main_pre_reviewer_transcript "$transcript" || return 1
  capture="$(turn_capture_path "$proof_root" requested-turn)" || return 1
  claim="$(turn_claim_path "$proof_root" requested-turn)" || return 1
  printf '%s\n' '{"turn_id":"colliding-other-turn","prompt":"MUST_NOT_REVIEW"}' >"$capture"
  chmod 0600 "$capture"
  input="$TMP_ROOT/pre-reviewer-hash-collision.json"
  write_present_pre_reviewer_input "$transcript" requested-turn "$input" || return 1
  out="$TMP_ROOT/pre-reviewer-hash-collision.out"
  body="$TMP_ROOT/pre-reviewer-hash-collision-body.md"

  run_hook "$out" "$ROOT/hooks/edit-bash-pre-reviewer.sh" "$input" \
    HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" \
    CODEX_EDIT_PRE_REVIEWER="ollama:http://127.0.0.1:11434:qwen3:4b" \
    CODEX_PRE_REVIEWER_DEBUG_BODY_PATH="$body" \
    CODEX_PRE_REVIEWER_FAKE_RESULT='{"verdict":"deny","reason":"Must not review."}' || return 1

  expect_no_output "$out" && [ ! -e "$body" ] && [ ! -e "$capture" ] && [ ! -e "$claim" ]
}

test_pre_reviewer_claim_loser_does_not_delete_capture() {
  local proof_root transcript input out body capture claim
  proof_root="$(fresh_proof_root pre-reviewer-claim-loser)"
  transcript="$TMP_ROOT/home/.codex/sessions/pre-reviewer-claim-loser.jsonl"
  write_large_history_main_pre_reviewer_transcript "$transcript" || return 1
  submit_current_turn "$proof_root" turn-loser "LOSER_CAPTURE" pre-reviewer-claim-loser || return 1
  capture="$(turn_capture_path "$proof_root" turn-loser)" || return 1
  claim="$(turn_claim_path "$proof_root" turn-loser)" || return 1
  : >"$claim"
  input="$TMP_ROOT/pre-reviewer-claim-loser.json"
  write_present_pre_reviewer_input "$transcript" turn-loser "$input" || return 1
  out="$TMP_ROOT/pre-reviewer-claim-loser.out"
  body="$TMP_ROOT/pre-reviewer-claim-loser-body.md"

  run_hook "$out" "$ROOT/hooks/edit-bash-pre-reviewer.sh" "$input" \
    HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" \
    CODEX_EDIT_PRE_REVIEWER="ollama:http://127.0.0.1:11434:qwen3:4b" \
    CODEX_PRE_REVIEWER_DEBUG_BODY_PATH="$body" \
    CODEX_PRE_REVIEWER_FAKE_RESULT='{"verdict":"deny","reason":"Loser."}' || return 1

  expect_no_output "$out" && [ ! -e "$body" ] && [ -e "$capture" ] && [ -e "$claim" ]
}

test_claim_creation_failure_restores_consumed_capture() {
  local proof_root transcript input out body capture claim bin_dir real_python
  proof_root="$(fresh_proof_root pre-reviewer-claim-restore)"
  transcript="$TMP_ROOT/home/.codex/sessions/pre-reviewer-claim-restore.jsonl"
  write_large_history_main_pre_reviewer_transcript "$transcript" || return 1
  submit_current_turn "$proof_root" turn-restore "RESTORE_CAPTURE" \
    pre-reviewer-claim-restore-submit || return 1
  capture="$(turn_capture_path "$proof_root" turn-restore)" || return 1
  claim="$(turn_claim_path "$proof_root" turn-restore)" || return 1
  bin_dir="$TMP_ROOT/pre-reviewer-claim-restore-bin"
  real_python="$(command -v python3)" || return 1
  mkdir -p "$bin_dir" || return 1
  cat >"$bin_dir/python3" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ " \$* " == *turn_capture_validator.py* ]]; then
  mkdir "\$CODEX_TEST_CLAIM_PATH"
fi
exec "$real_python" "\$@"
EOF
  chmod 0755 "$bin_dir/python3"
  input="$TMP_ROOT/pre-reviewer-claim-restore.json"
  write_present_pre_reviewer_input "$transcript" turn-restore "$input" || return 1
  out="$TMP_ROOT/pre-reviewer-claim-restore.out"
  body="$TMP_ROOT/pre-reviewer-claim-restore-body.md"

  run_hook "$out" "$ROOT/hooks/edit-bash-pre-reviewer.sh" "$input" \
    PATH="$bin_dir:$PATH" HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" \
    CODEX_TEST_CLAIM_PATH="$claim" \
    CODEX_EDIT_PRE_REVIEWER="ollama:http://127.0.0.1:11434:qwen3:4b" \
    CODEX_PRE_REVIEWER_DEBUG_BODY_PATH="$body" \
    CODEX_PRE_REVIEWER_FAKE_RESULT='{"verdict":"deny","reason":"Must not run."}' || return 1

  expect_no_output "$out" && [ ! -e "$body" ] && [ -d "$claim" ] &&
    jq -e '.turn_id == "turn-restore" and .prompt == "RESTORE_CAPTURE"' "$capture" >/dev/null
}

test_same_key_resubmit_preserves_winner_claim() {
  local proof_root transcript input out body capture claim bin_python bin_flock validation_ready validation_release
  local lock_ready once pre_pid prompt_pid replacement_input replacement_out validation_ready_fd validation_release_fd
  local lock_ready_fd validation_signal lock_signal pre_status prompt_status
  proof_root="$(fresh_proof_root pre-reviewer-same-key-replacement)"
  transcript="$TMP_ROOT/home/.codex/sessions/pre-reviewer-same-key-replacement.jsonl"
  write_large_history_main_pre_reviewer_transcript "$transcript" || return 1
  submit_current_turn "$proof_root" same-key "OLD_CAPTURE" pre-reviewer-same-key-old || return 1
  capture="$(turn_capture_path "$proof_root" same-key)" || return 1
  input="$TMP_ROOT/pre-reviewer-same-key-replacement.json"
  write_present_pre_reviewer_input "$transcript" same-key "$input" || return 1
  out="$TMP_ROOT/pre-reviewer-same-key-replacement.out"
  body="$TMP_ROOT/pre-reviewer-same-key-replacement-body.md"
  bin_python="$TMP_ROOT/pre-reviewer-same-key-python-bin"
  bin_flock="$TMP_ROOT/pre-reviewer-same-key-flock-bin"
  validation_ready="$TMP_ROOT/pre-reviewer-same-key-validation-ready"
  validation_release="$TMP_ROOT/pre-reviewer-same-key-validation-release"
  lock_ready="$TMP_ROOT/pre-reviewer-same-key-lock-ready"
  once="$TMP_ROOT/pre-reviewer-same-key-once"
  mkfifo "$validation_ready" "$validation_release" "$lock_ready" || return 1
  exec {validation_ready_fd}<>"$validation_ready" || return 1
  exec {validation_release_fd}<>"$validation_release" || { exec {validation_ready_fd}>&-; return 1; }
  exec {lock_ready_fd}<>"$lock_ready" || {
    exec {validation_ready_fd}>&-
    exec {validation_release_fd}>&-
    return 1
  }
  write_blocking_validation_python_wrapper "$bin_python" || return 1
  write_signaling_flock_wrapper "$bin_flock" || return 1

  run_hook "$out" "$ROOT/hooks/edit-bash-pre-reviewer.sh" "$input" \
    PATH="$bin_python:$PATH" HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" \
    CODEX_TEST_ONCE="$once" CODEX_TEST_VALIDATION_READY="$validation_ready" \
    CODEX_TEST_VALIDATION_RELEASE="$validation_release" \
    CODEX_EDIT_PRE_REVIEWER="ollama:http://127.0.0.1:11434:qwen3:4b" \
    CODEX_PRE_REVIEWER_DEBUG_BODY_PATH="$body" \
    CODEX_PRE_REVIEWER_FAKE_RESULT='{"verdict":"deny","reason":"Old winner."}' &
  pre_pid=$!
  if ! IFS= read -r -t 5 -u "$validation_ready_fd" validation_signal ||
      [ "$validation_signal" != ready ]; then
    printf 'release\n' >&"$validation_release_fd" || true
    kill "$pre_pid" 2>/dev/null || true
    wait "$pre_pid" 2>/dev/null || true
    exec {validation_ready_fd}>&-
    exec {validation_release_fd}>&-
    exec {lock_ready_fd}>&-
    rm -f "$validation_ready" "$validation_release" "$lock_ready"
    return 1
  fi

  replacement_input="$TMP_ROOT/pre-reviewer-same-key-replacement-submit.json"
  if ! jq -n --arg cwd "$ROOT" \
    '{session_id:"t00-session",hook_event_name:"UserPromptSubmit",cwd:$cwd,turn_id:"same-key",prompt:"NEW_CAPTURE"}' \
    >"$replacement_input"; then
    printf 'release\n' >&"$validation_release_fd" || true
    kill "$pre_pid" 2>/dev/null || true
    wait "$pre_pid" 2>/dev/null || true
    exec {validation_ready_fd}>&-
    exec {validation_release_fd}>&-
    exec {lock_ready_fd}>&-
    rm -f "$validation_ready" "$validation_release" "$lock_ready"
    return 1
  fi
  replacement_out="$TMP_ROOT/pre-reviewer-same-key-replacement-submit.out"
  run_hook "$replacement_out" "$ROOT/hooks/prompt-task-reminder.sh" "$replacement_input" \
    PATH="$bin_flock:$PATH" HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" \
    CODEX_TEST_LOCK_READY="$lock_ready" &
  prompt_pid=$!
  if ! IFS= read -r -t 5 -u "$lock_ready_fd" lock_signal || [ "$lock_signal" != ready ]; then
    printf 'release\n' >&"$validation_release_fd" || true
    kill "$pre_pid" "$prompt_pid" 2>/dev/null || true
    wait "$pre_pid" 2>/dev/null || true
    wait "$prompt_pid" 2>/dev/null || true
    exec {validation_ready_fd}>&-
    exec {validation_release_fd}>&-
    exec {lock_ready_fd}>&-
    rm -f "$validation_ready" "$validation_release" "$lock_ready"
    return 1
  fi
  printf 'release\n' >&"$validation_release_fd"
  pre_status=0
  prompt_status=0
  wait "$pre_pid" || pre_status=$?
  wait "$prompt_pid" || prompt_status=$?
  exec {validation_ready_fd}>&-
  exec {validation_release_fd}>&-
  exec {lock_ready_fd}>&-
  rm -f "$validation_ready" "$validation_release" "$lock_ready"
  [ "$pre_status" -eq 0 ] && [ "$prompt_status" -eq 0 ] || return 1

  claim="$(turn_claim_path "$proof_root" same-key)" || return 1
  is_pretool_deny "$out" && grep -Fq OLD_CAPTURE "$body" &&
    [ ! -e "$capture" ] && [ -f "$claim" ] &&
    ! grep -Fq NEW_CAPTURE "$body"
}

test_present_turn_claim_persists_across_non_deny_outcomes() {
  local variant proof_root transcript input first_out second_out first_body second_body claim capture
  for variant in allow malformed backend-failure; do
    proof_root="$(fresh_proof_root pre-reviewer-claim-persists-$variant)"
    transcript="$TMP_ROOT/home/.codex/sessions/pre-reviewer-claim-persists-$variant.jsonl"
    write_large_history_main_pre_reviewer_transcript "$transcript" || return 1
    submit_current_turn "$proof_root" "turn-$variant" "PROMPT_$variant" \
      "pre-reviewer-claim-persists-$variant" || return 1
    input="$TMP_ROOT/pre-reviewer-claim-persists-$variant.json"
    write_present_pre_reviewer_input "$transcript" "turn-$variant" "$input" || return 1
    first_out="$TMP_ROOT/pre-reviewer-claim-persists-$variant-first.out"
    first_body="$TMP_ROOT/pre-reviewer-claim-persists-$variant-first-body.md"
    case "$variant" in
      allow)
        run_hook "$first_out" "$ROOT/hooks/edit-bash-pre-reviewer.sh" "$input" \
          HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" \
          CODEX_EDIT_PRE_REVIEWER="ollama:http://127.0.0.1:11434:qwen3:4b" \
          CODEX_PRE_REVIEWER_DEBUG_BODY_PATH="$first_body" \
          CODEX_PRE_REVIEWER_FAKE_RESULT='{"verdict":"allow","reason":"Allowed."}' || return 1 ;;
      malformed)
        run_hook "$first_out" "$ROOT/hooks/edit-bash-pre-reviewer.sh" "$input" \
          HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" \
          CODEX_EDIT_PRE_REVIEWER="ollama:http://127.0.0.1:11434:qwen3:4b" \
          CODEX_PRE_REVIEWER_DEBUG_BODY_PATH="$first_body" \
          CODEX_PRE_REVIEWER_FAKE_RESULT='{malformed' || return 1 ;;
      backend-failure)
        run_hook "$first_out" "$ROOT/hooks/edit-bash-pre-reviewer.sh" "$input" \
          HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" \
          CODEX_EDIT_PRE_REVIEWER="ollama:http://127.0.0.1:1:qwen3:4b" \
          CODEX_EDIT_PRE_REVIEWER_TIMEOUT=1 CODEX_PRE_REVIEWER_DEBUG_BODY_PATH="$first_body" || return 1 ;;
    esac
    claim="$(turn_claim_path "$proof_root" "turn-$variant")" || return 1
    capture="$(turn_capture_path "$proof_root" "turn-$variant")" || return 1
    expect_no_output "$first_out" && [ -e "$claim" ] && [ ! -e "$capture" ] || return 1

    second_out="$TMP_ROOT/pre-reviewer-claim-persists-$variant-second.out"
    second_body="$TMP_ROOT/pre-reviewer-claim-persists-$variant-second-body.md"
    run_hook "$second_out" "$ROOT/hooks/edit-bash-pre-reviewer.sh" "$input" \
      HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" \
      CODEX_EDIT_PRE_REVIEWER="ollama:http://127.0.0.1:11434:qwen3:4b" \
      CODEX_PRE_REVIEWER_DEBUG_BODY_PATH="$second_body" \
      CODEX_PRE_REVIEWER_FAKE_RESULT='{"verdict":"deny","reason":"Must stay silent."}' || return 1
    expect_no_output "$second_out" && [ ! -e "$second_body" ] && [ -e "$claim" ] || return 1
  done
}

test_pre_reviewer_present_turn_rejects_malformed_capture_payloads() {
  local variant proof_root state_dir transcript input out body capture
  transcript="$TMP_ROOT/home/.codex/sessions/pre-reviewer-present-invalid-capture.jsonl"
  write_large_history_main_pre_reviewer_transcript "$transcript" || return 1

  for variant in malformed nonstring-prompt; do
    proof_root="$(fresh_proof_root pre-reviewer-present-invalid-capture-$variant)"
    state_dir="$proof_root/pre-reviewer/t00-session"
    mkdir -p -m 0700 "$state_dir" || return 1
    capture="$(turn_capture_path "$proof_root" turn-invalid-capture)" || return 1
    case "$variant" in
      malformed) printf '%s\n' '{malformed' >"$capture" ;;
      nonstring-prompt) printf '%s\n' '{"turn_id":"turn-invalid-capture","prompt":{"bad":true}}' \
        >"$capture" ;;
    esac
    chmod 0600 "$capture"
    input="$TMP_ROOT/pre-reviewer-present-invalid-capture-$variant.json"
    write_present_pre_reviewer_input "$transcript" "turn-invalid-capture" "$input" || return 1
    out="$TMP_ROOT/pre-reviewer-present-invalid-capture-$variant.out"
    body="$TMP_ROOT/pre-reviewer-present-invalid-capture-$variant-body.md"
    run_hook "$out" "$ROOT/hooks/edit-bash-pre-reviewer.sh" "$input" \
      HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" \
      CODEX_EDIT_PRE_REVIEWER="ollama:http://127.0.0.1:11434:qwen3:4b" \
      CODEX_PRE_REVIEWER_DEBUG_BODY_PATH="$body" \
      CODEX_PRE_REVIEWER_FAKE_RESULT='{"verdict":"deny","reason":"Must not review."}' || return 1
    expect_no_output "$out" && [ ! -e "$body" ] && [ ! -e "$capture" ] &&
      [ "$(find "$state_dir" -maxdepth 1 -type f -name 'claim-*' | wc -l)" -eq 0 ] || return 1
  done
}

test_present_turn_strict_capture_consumer_rejects_unsafe_inputs() {
  local variant proof_root state_dir transcript input out body capture claim target
  transcript="$TMP_ROOT/home/.codex/sessions/pre-reviewer-strict-capture.jsonl"
  write_large_history_main_pre_reviewer_transcript "$transcript" || return 1

  for variant in invalid-utf8 oversized mismatched symlink hardlink wrong-mode; do
    proof_root="$(fresh_proof_root pre-reviewer-strict-capture-$variant)"
    submit_current_turn "$proof_root" strict-turn "PLACEHOLDER" \
      "pre-reviewer-strict-capture-$variant-submit" || return 1
    state_dir="$proof_root/pre-reviewer/t00-session"
    capture="$(turn_capture_path "$proof_root" strict-turn)" || return 1
    claim="$(turn_claim_path "$proof_root" strict-turn)" || return 1
    target="$state_dir/strict-target-$variant"
    case "$variant" in
      invalid-utf8)
        printf '{"turn_id":"strict-turn","prompt":"bad\377"}' >"$capture" ;;
      oversized)
        {
          printf '{"turn_id":"strict-turn","prompt":"'
          printf '%4001s' '' | tr ' ' x
          printf '"}'
        } >"$capture" ;;
      mismatched)
        printf '%s\n' '{"turn_id":"colliding-turn","prompt":"MISMATCH"}' >"$capture" ;;
      symlink)
        printf '%s\n' '{"turn_id":"strict-turn","prompt":"SYMLINK"}' >"$target"
        chmod 0600 "$target"
        rm -f "$capture"
        ln -s "$target" "$capture" ;;
      hardlink)
        printf '%s\n' '{"turn_id":"strict-turn","prompt":"HARDLINK"}' >"$target"
        chmod 0600 "$target"
        rm -f "$capture"
        ln "$target" "$capture" ;;
      wrong-mode)
        printf '%s\n' '{"turn_id":"strict-turn","prompt":"WRONG_MODE"}' >"$capture"
        chmod 0644 "$capture" ;;
    esac
    [ "$variant" = symlink ] || [ "$variant" = hardlink ] || [ "$variant" = wrong-mode ] ||
      chmod 0600 "$capture"
    input="$TMP_ROOT/pre-reviewer-strict-capture-$variant.json"
    write_present_pre_reviewer_input "$transcript" strict-turn "$input" || return 1
    out="$TMP_ROOT/pre-reviewer-strict-capture-$variant.out"
    body="$TMP_ROOT/pre-reviewer-strict-capture-$variant-body.md"
    run_hook "$out" "$ROOT/hooks/edit-bash-pre-reviewer.sh" "$input" \
      HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" \
      CODEX_EDIT_PRE_REVIEWER="ollama:http://127.0.0.1:11434:qwen3:4b" \
      CODEX_PRE_REVIEWER_DEBUG_BODY_PATH="$body" \
      CODEX_PRE_REVIEWER_FAKE_RESULT='{"verdict":"deny","reason":"Unsafe capture."}' || return 1
    expect_no_output "$out" && [ ! -e "$body" ] && [ ! -e "$claim" ] &&
      [ ! -e "$capture" ] || return 1
    case "$variant" in
      symlink|hardlink) [ -f "$target" ] || return 1 ;;
    esac
  done
}

test_present_turn_strict_capture_consumer_preserves_valid_replacement_character() {
  local proof_root transcript input out body
  proof_root="$(fresh_proof_root pre-reviewer-strict-capture-replacement)"
  transcript="$TMP_ROOT/home/.codex/sessions/pre-reviewer-strict-capture-replacement.jsonl"
  write_large_history_main_pre_reviewer_transcript "$transcript" || return 1
  submit_current_turn "$proof_root" strict-replacement "VALID_�_CAPTURE" \
    pre-reviewer-strict-capture-replacement-submit || return 1
  input="$TMP_ROOT/pre-reviewer-strict-capture-replacement.json"
  write_present_pre_reviewer_input "$transcript" strict-replacement "$input" || return 1
  out="$TMP_ROOT/pre-reviewer-strict-capture-replacement.out"
  body="$TMP_ROOT/pre-reviewer-strict-capture-replacement-body.md"

  run_hook "$out" "$ROOT/hooks/edit-bash-pre-reviewer.sh" "$input" \
    HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" \
    CODEX_EDIT_PRE_REVIEWER="ollama:http://127.0.0.1:11434:qwen3:4b" \
    CODEX_PRE_REVIEWER_DEBUG_BODY_PATH="$body" \
    CODEX_PRE_REVIEWER_FAKE_RESULT='{"verdict":"deny","reason":"Valid capture."}' || return 1

  is_pretool_deny "$out" && grep -Fq 'VALID_�_CAPTURE' "$body"
}

test_pre_reviewer_owned_0755_state_directory_migrates_and_publishes() {
  local proof_root state_dir capture
  proof_root="$(fresh_proof_root pre-reviewer-state-migration)"
  state_dir="$proof_root/pre-reviewer/t00-session"
  mkdir -p "$proof_root/pre-reviewer" || return 1
  mkdir -m 0755 "$state_dir" || return 1
  chmod 0755 "$state_dir" || return 1

  submit_current_turn "$proof_root" migration-turn MIGRATED_CAPTURE \
    pre-reviewer-state-migration || return 1
  capture="$(turn_capture_path "$proof_root" migration-turn)" || return 1

  [ "$(stat -c '%a' "$state_dir")" = 700 ] &&
    [ "$(stat -c '%a' "$capture")" = 600 ] &&
    jq -e '.turn_id == "migration-turn" and .prompt == "MIGRATED_CAPTURE"' \
      "$capture" >/dev/null
}

test_pre_reviewer_private_state_directory_skips_python_migrator() {
  local state_dir bin_dir marker out status
  state_dir="$TMP_ROOT/pre-reviewer-private-fast-path"
  bin_dir="$TMP_ROOT/pre-reviewer-private-fast-path-bin"
  marker="$TMP_ROOT/pre-reviewer-private-fast-path-python-called"
  out="$TMP_ROOT/pre-reviewer-private-fast-path.out"
  mkdir -m 0700 "$state_dir" || return 1
  mkdir -p "$bin_dir" || return 1
  cat >"$bin_dir/python3" <<'SH'
#!/usr/bin/env bash
printf 'called\n' >"$CODEX_TEST_PYTHON_MARKER"
exit 99
SH
  chmod 0755 "$bin_dir/python3"

  status=0
  env PATH="$bin_dir:$PATH" CODEX_TEST_PYTHON_MARKER="$marker" bash -c '
    . "$1"
    codex_ensure_private_pre_reviewer_state_dir "$2"
  ' bash "$ROOT/hooks/lib/pre-reviewer-turn-state.sh" "$state_dir" \
    >"$out" 2>"$out.err" || status=$?

  [ "$status" -eq 0 ] && expect_no_output "$out" && [ ! -s "$out.err" ] &&
    [ ! -e "$marker" ] && [ "$(stat -c '%a' "$state_dir")" = 700 ]
}

test_pre_reviewer_unavailable_migrator_fails_silently_without_mutation() {
  local state_dir bin_dir marker out status
  state_dir="$TMP_ROOT/pre-reviewer-unavailable-migrator"
  bin_dir="$TMP_ROOT/pre-reviewer-unavailable-migrator-bin"
  marker="$TMP_ROOT/pre-reviewer-unavailable-migrator-python-called"
  out="$TMP_ROOT/pre-reviewer-unavailable-migrator.out"
  mkdir -m 0755 "$state_dir" || return 1
  chmod 0755 "$state_dir" || return 1
  mkdir -p "$bin_dir" || return 1
  cat >"$bin_dir/python3" <<'SH'
#!/usr/bin/env bash
printf 'called\n' >"$CODEX_TEST_PYTHON_MARKER"
exit 127
SH
  chmod 0755 "$bin_dir/python3"

  status=0
  env PATH="$bin_dir:$PATH" CODEX_TEST_PYTHON_MARKER="$marker" bash -c '
    . "$1"
    codex_ensure_private_pre_reviewer_state_dir "$2"
  ' bash "$ROOT/hooks/lib/pre-reviewer-turn-state.sh" "$state_dir" \
    >"$out" 2>"$out.err" || status=$?

  [ "$status" -ne 0 ] && expect_no_output "$out" && [ ! -s "$out.err" ] &&
    [ -e "$marker" ] && [ "$(stat -c '%a' "$state_dir")" = 755 ]
}

test_pre_reviewer_wrong_owner_fails_without_mutation_or_publication() {
  local proof_root state_dir bin_dir input out capture real_python
  proof_root="$(fresh_proof_root pre-reviewer-wrong-owner)"
  state_dir="$proof_root/pre-reviewer/t00-session"
  bin_dir="$TMP_ROOT/pre-reviewer-wrong-owner-bin"
  input="$TMP_ROOT/pre-reviewer-wrong-owner-submit.json"
  out="$TMP_ROOT/pre-reviewer-wrong-owner.out"
  mkdir -p "$proof_root/pre-reviewer" "$bin_dir" || return 1
  mkdir -m 0755 "$state_dir" || return 1
  chmod 0755 "$state_dir" || return 1
  real_python="$(command -v python3)" || return 1
  cat >"$bin_dir/python3" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == *migrate_pre_reviewer_state_dir.py ]]; then
  exec "$CODEX_TEST_REAL_PYTHON" - "$1" "$2" <<'PY'
import importlib.util
import os
import sys

spec = importlib.util.spec_from_file_location("state_dir_migrator", sys.argv[1])
if spec is None or spec.loader is None:
    raise SystemExit(1)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
actual_uid = os.geteuid()
module.os.geteuid = lambda: actual_uid + 1
raise SystemExit(0 if module.migrate(sys.argv[2]) else 1)
PY
fi
exec "$CODEX_TEST_REAL_PYTHON" "$@"
SH
  chmod 0755 "$bin_dir/python3"
  jq -n --arg cwd "$ROOT" \
    '{session_id:"t00-session",hook_event_name:"UserPromptSubmit",cwd:$cwd,
      turn_id:"wrong-owner",prompt:"MUST_NOT_PUBLISH"}' >"$input" || return 1

  run_hook "$out" "$ROOT/hooks/prompt-task-reminder.sh" "$input" \
    PATH="$bin_dir:$PATH" CODEX_TEST_REAL_PYTHON="$real_python" \
    HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" || return 1
  capture="$(turn_capture_path "$proof_root" wrong-owner)" || return 1

  expect_no_output "$out" && [ ! -s "$out.err" ] && [ ! -e "$capture" ] &&
    [ "$(stat -c '%a' "$state_dir")" = 755 ]
}

test_pre_reviewer_rejects_unsafe_state_directories() {
  local variant proof_root pre_parent state_dir target input out capture
  for variant in symlink non-directory; do
    proof_root="$(fresh_proof_root pre-reviewer-unsafe-state-$variant)"
    pre_parent="$proof_root/pre-reviewer"
    state_dir="$pre_parent/t00-session"
    mkdir -p "$pre_parent" || return 1
    case "$variant" in
      symlink)
        target="$proof_root/attacker-state"
        mkdir -m 0755 "$target" || return 1
        chmod 0755 "$target" || return 1
        ln -s "$target" "$state_dir" || return 1 ;;
      non-directory)
        printf 'state\n' >"$state_dir"
        chmod 0644 "$state_dir" ;;
    esac
    input="$TMP_ROOT/pre-reviewer-unsafe-state-$variant-submit.json"
    jq -n --arg cwd "$ROOT" \
      '{session_id:"t00-session",hook_event_name:"UserPromptSubmit",cwd:$cwd,
        turn_id:"unsafe-state",prompt:"MUST_NOT_PUBLISH"}' >"$input" || return 1
    out="$TMP_ROOT/pre-reviewer-unsafe-state-$variant.out"
    run_hook "$out" "$ROOT/hooks/prompt-task-reminder.sh" "$input" \
      HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" || return 1
    capture="$(turn_capture_path "$proof_root" unsafe-state)" || return 1
    expect_no_output "$out" && [ ! -s "$out.err" ] && [ ! -e "$capture" ] || return 1
    case "$variant" in
      symlink)
        [ "$(stat -c '%a' "$target")" = 755 ] &&
          [ "$(find "$target" -mindepth 1 -maxdepth 1 | wc -l)" -eq 0 ] || return 1 ;;
      non-directory)
        [ "$(stat -c '%a' "$state_dir")" = 644 ] || return 1 ;;
    esac
  done
}

test_pre_reviewer_present_turn_claim_is_atomic_under_concurrency() {
  local proof_root transcript input out_a out_b body_a body_b status_a status_b denials bodies
  proof_root="$(fresh_proof_root pre-reviewer-present-concurrent)"
  transcript="$TMP_ROOT/home/.codex/sessions/pre-reviewer-present-concurrent.jsonl"
  write_large_history_main_pre_reviewer_transcript "$transcript" || return 1
  submit_current_turn "$proof_root" "turn-concurrent" "CONCURRENT_CAPTURE" \
    pre-reviewer-present-concurrent || return 1
  input="$TMP_ROOT/pre-reviewer-present-concurrent.json"
  write_present_pre_reviewer_input "$transcript" "turn-concurrent" "$input" || return 1
  out_a="$TMP_ROOT/pre-reviewer-present-concurrent-a.out"
  out_b="$TMP_ROOT/pre-reviewer-present-concurrent-b.out"
  body_a="$TMP_ROOT/pre-reviewer-present-concurrent-a-body.md"
  body_b="$TMP_ROOT/pre-reviewer-present-concurrent-b-body.md"

  run_hook "$out_a" "$ROOT/hooks/edit-bash-pre-reviewer.sh" "$input" \
    HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" \
    CODEX_EDIT_PRE_REVIEWER="ollama:http://127.0.0.1:11434:qwen3:4b" \
    CODEX_PRE_REVIEWER_DEBUG_BODY_PATH="$body_a" \
    CODEX_PRE_REVIEWER_FAKE_RESULT='{"verdict":"deny","reason":"Concurrent winner."}' &
  local pid_a=$!
  run_hook "$out_b" "$ROOT/hooks/edit-bash-pre-reviewer.sh" "$input" \
    HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" \
    CODEX_EDIT_PRE_REVIEWER="ollama:http://127.0.0.1:11434:qwen3:4b" \
    CODEX_PRE_REVIEWER_DEBUG_BODY_PATH="$body_b" \
    CODEX_PRE_REVIEWER_FAKE_RESULT='{"verdict":"deny","reason":"Concurrent winner."}' &
  local pid_b=$!
  wait "$pid_a"; status_a=$?
  wait "$pid_b"; status_b=$?
  [ "$status_a" -eq 0 ] && [ "$status_b" -eq 0 ] || return 1

  denials=0
  is_pretool_deny "$out_a" && denials=$((denials + 1))
  is_pretool_deny "$out_b" && denials=$((denials + 1))
  bodies=0
  [ -s "$body_a" ] && bodies=$((bodies + 1))
  [ -s "$body_b" ] && bodies=$((bodies + 1))
  [ "$denials" -eq 1 ] && [ "$bodies" -eq 1 ] &&
    [ "$(find "$proof_root/pre-reviewer/t00-session" -maxdepth 1 -type f -name 'claim-*' | wc -l)" -eq 1 ] &&
    grep -Fq 'CONCURRENT_CAPTURE' "$body_a" "$body_b" 2>/dev/null &&
    ! grep -Fq 'OLD_HISTORY_POISON_MUST_NOT_BE_READ' "$body_a" "$body_b" 2>/dev/null
}

test_pre_reviewer_distinct_turn_ids_with_same_prompt_each_review() {
  local proof_root transcript input_a input_b out_a out_b body_a body_b
  proof_root="$(fresh_proof_root pre-reviewer-distinct-turns)"
  transcript="$TMP_ROOT/home/.codex/sessions/pre-reviewer-distinct-turns.jsonl"
  write_large_history_main_pre_reviewer_transcript "$transcript" || return 1

  submit_current_turn "$proof_root" "turn-a" "SAME_PROMPT" pre-reviewer-distinct-a || return 1
  input_a="$TMP_ROOT/pre-reviewer-distinct-a.json"
  write_present_pre_reviewer_input "$transcript" "turn-a" "$input_a" || return 1
  out_a="$TMP_ROOT/pre-reviewer-distinct-a.out"
  body_a="$TMP_ROOT/pre-reviewer-distinct-a-body.md"
  run_hook "$out_a" "$ROOT/hooks/edit-bash-pre-reviewer.sh" "$input_a" \
    HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" \
    CODEX_EDIT_PRE_REVIEWER="ollama:http://127.0.0.1:11434:qwen3:4b" \
    CODEX_PRE_REVIEWER_DEBUG_BODY_PATH="$body_a" \
    CODEX_PRE_REVIEWER_FAKE_RESULT='{"verdict":"deny","reason":"Turn A."}' || return 1

  submit_current_turn "$proof_root" "turn-b" "SAME_PROMPT" pre-reviewer-distinct-b || return 1
  input_b="$TMP_ROOT/pre-reviewer-distinct-b.json"
  write_present_pre_reviewer_input "$transcript" "turn-b" "$input_b" || return 1
  out_b="$TMP_ROOT/pre-reviewer-distinct-b.out"
  body_b="$TMP_ROOT/pre-reviewer-distinct-b-body.md"
  run_hook "$out_b" "$ROOT/hooks/edit-bash-pre-reviewer.sh" "$input_b" \
    HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" \
    CODEX_EDIT_PRE_REVIEWER="ollama:http://127.0.0.1:11434:qwen3:4b" \
    CODEX_PRE_REVIEWER_DEBUG_BODY_PATH="$body_b" \
    CODEX_PRE_REVIEWER_FAKE_RESULT='{"verdict":"deny","reason":"Turn B."}' || return 1

  is_pretool_deny "$out_a" && is_pretool_deny "$out_b" &&
    [ -s "$body_a" ] && [ -s "$body_b" ]
}

test_prompt_capture_redacts_complete_prompt_before_byte_cap() {
  local proof_root prompt capture captured secret_material private_key_begin private_key_end
  proof_root="$(fresh_proof_root prompt-capture-redact-cap)"
  secret_material="PRIVATE_MATERIAL_MUST_NOT_SURVIVE"
  private_key_begin="$(redaction_fixture_value private-key-begin)" || return 1
  private_key_end="$(redaction_fixture_value private-key-end)" || return 1
  prompt=$(printf '%3900s\n%s\n%s\n%300s\n%s\nTAIL' \
    '' "$private_key_begin" "$secret_material" '' "$private_key_end")
  submit_current_turn "$proof_root" "turn-redact-cap" "$prompt" prompt-capture-redact-cap || return 1
  capture="$(turn_capture_path "$proof_root" turn-redact-cap)" || return 1
  captured=$(jq -r '.prompt' "$capture" 2>/dev/null) || return 1

  jq -e . "$capture" >/dev/null &&
    [ "$(printf '%s' "$captured" | wc -c)" -le 4000 ] &&
    case "$captured" in *'[REDACTED]'*) true ;; *) false ;; esac &&
    case "$captured" in *"$secret_material"*) false ;; *) true ;; esac
}

test_prompt_capture_byte_cap_preserves_utf8_boundary() {
  local proof_root prompt capture captured prefix
  proof_root="$(fresh_proof_root prompt-capture-utf8-cap)"
  prefix=$(printf '%3999s' '')
  prompt="${prefix}éTAIL"
  submit_current_turn "$proof_root" "turn-utf8-cap" "$prompt" prompt-capture-utf8-cap || return 1
  capture="$(turn_capture_path "$proof_root" turn-utf8-cap)" || return 1
  captured=$(jq -r '.prompt' "$capture" 2>/dev/null) || return 1

  jq -e . "$capture" >/dev/null &&
    [ "$(printf '%s' "$captured" | wc -c)" -le 4000 ] &&
    [ "$captured" = "$prefix" ] &&
    case "$captured" in *$'\uFFFD'*|*é*|*TAIL*) false ;; *) true ;; esac
}

test_large_prompt_submission_fails_open_before_capture() {
  local proof_root prompt_file input out capture
  proof_root="$(fresh_proof_root prompt-capture-large)"
  prompt_file="$TMP_ROOT/prompt-capture-large.txt"
  dd if=/dev/zero bs=1048576 count=8 status=none | tr '\0' x >"$prompt_file" || return 1
  input="$TMP_ROOT/prompt-capture-large.json"
  jq -Rs --arg cwd "$ROOT" \
    '{session_id:"t00-session",hook_event_name:"UserPromptSubmit",cwd:$cwd,
      turn_id:"turn-large-prompt",prompt:.}' "$prompt_file" >"$input" || return 1
  out="$TMP_ROOT/prompt-capture-large.out"

  run_hook "$out" "$ROOT/hooks/prompt-task-reminder.sh" "$input" \
    HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" || return 1
  capture="$(turn_capture_path "$proof_root" turn-large-prompt)" || return 1
  expect_no_output "$out" && [ ! -e "$capture" ]
}

test_prompt_capture_utf8_prefix_matches_lean_spec() {
  "$ROOT/hooks/tests/differential/utf8-prefix.sh" >/dev/null
}

test_utf8_prefix_cap_python_unit_suite() {
  python3 "$ROOT/hooks/tests/test_utf8_prefix_cap.py" >/dev/null
}

test_turn_capture_validator_python_unit_suite() {
  python3 "$ROOT/hooks/tests/test_turn_capture_validator.py" >/dev/null
}

test_turn_capture_validator_matches_lean_spec() {
  "$ROOT/hooks/tests/differential/turn-capture.sh" >/dev/null
}

write_lock_fd_observer_python_wrapper() {
  local bin_dir="$1"
  local real_python

  real_python="$(command -v python3)" || return 1
  mkdir -p "$bin_dir" || return 1
  printf '#!/usr/bin/env bash\nset -euo pipefail\nREAL_PYTHON=%q\n' "$real_python" >"$bin_dir/python3" || return 1
  cat >>"$bin_dir/python3" <<'SH'
kind=other
case " $* " in
  *prune_pre_reviewer_turn_state.py*) kind=pruner ;;
  *turn_capture_validator.py*) kind=validator ;;
esac
if [ "$kind" != other ]; then
  child=closed
  parent=missing
  parent_pid=""
  while read -r status_key status_value _status_rest; do
    if [ "$status_key" = PPid: ]; then
      parent_pid="$status_value"
      break
    fi
  done </proc/self/status
  [ -n "$parent_pid" ] || exit 1
  for fd in /proc/$$/fd/*; do
    [ "$(readlink "$fd" 2>/dev/null || true)" = "$CODEX_TEST_STATE_DIR" ] && child=has
  done
  for fd in /proc/$parent_pid/fd/*; do
    [ "$(readlink "$fd" 2>/dev/null || true)" = "$CODEX_TEST_STATE_DIR" ] && parent=has
  done
  printf '%s-child-%s\n%s-parent-%s\n' "$kind" "$child" "$kind" "$parent" >>"$CODEX_TEST_FD_TRACE"
fi
exec "$REAL_PYTHON" "$@"
SH
  chmod 0755 "$bin_dir/python3"
}

test_capture_validator_child_closes_lock_fd_while_pruner_inherits() {
  local proof_root state_dir transcript input out body bin_dir trace submit_input submit_out
  proof_root="$(fresh_proof_root pre-reviewer-validator-fd)"
  state_dir="$proof_root/pre-reviewer/t00-session"
  mkdir -p -m 0700 "$state_dir" || return 1
  state_dir="$(readlink -f "$state_dir")" || return 1
  transcript="$TMP_ROOT/home/.codex/sessions/pre-reviewer-validator-fd.jsonl"
  write_large_history_main_pre_reviewer_transcript "$transcript" || return 1
  bin_dir="$TMP_ROOT/pre-reviewer-validator-fd-bin"
  trace="$TMP_ROOT/pre-reviewer-validator-fd.trace"
  : >"$trace"
  write_lock_fd_observer_python_wrapper "$bin_dir" || return 1
  submit_input="$TMP_ROOT/pre-reviewer-validator-fd-submit.json"
  submit_out="$TMP_ROOT/pre-reviewer-validator-fd-submit.out"
  jq -n --arg cwd "$ROOT" \
    '{session_id:"t00-session",hook_event_name:"UserPromptSubmit",cwd:$cwd,turn_id:"validator-fd",prompt:"FD_PROMPT"}' \
    >"$submit_input" || return 1
  run_hook "$submit_out" "$ROOT/hooks/prompt-task-reminder.sh" "$submit_input" \
    PATH="$bin_dir:$PATH" HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" \
    CODEX_TEST_STATE_DIR="$state_dir" CODEX_TEST_FD_TRACE="$trace" || return 1
  expect_no_output "$submit_out" || return 1
  input="$TMP_ROOT/pre-reviewer-validator-fd.json"
  write_present_pre_reviewer_input "$transcript" validator-fd "$input" || return 1
  out="$TMP_ROOT/pre-reviewer-validator-fd.out"
  body="$TMP_ROOT/pre-reviewer-validator-fd-body.md"

  run_hook "$out" "$ROOT/hooks/edit-bash-pre-reviewer.sh" "$input" \
    PATH="$bin_dir:$PATH" HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" \
    CODEX_TEST_STATE_DIR="$state_dir" CODEX_TEST_FD_TRACE="$trace" \
    CODEX_EDIT_PRE_REVIEWER="ollama:http://127.0.0.1:11434:qwen3:4b" \
    CODEX_PRE_REVIEWER_DEBUG_BODY_PATH="$body" \
    CODEX_PRE_REVIEWER_FAKE_RESULT='{"verdict":"deny","reason":"FD test."}' || return 1

  if ! is_pretool_deny "$out" ||
      ! grep -qx 'pruner-child-has' "$trace" ||
      ! grep -qx 'pruner-parent-has' "$trace" ||
      ! grep -qx 'validator-child-closed' "$trace" ||
      ! grep -qx 'validator-parent-has' "$trace" ||
      grep -qx 'validator-child-has' "$trace"; then
    printf 'FD predicates: %s\n' "$(sort "$trace" | tr '\n' ' ')" >&2
    return 1
  fi
}

test_hook_tests_leave_no_python_bytecode_cache() {
  [ -z "$(find "$ROOT/hooks" -type d -name __pycache__ -print -quit)" ]
}

test_pre_reviewer_state_dir_migration_python_unit_suite() {
  python3 "$ROOT/hooks/tests/test_pre_reviewer_state_dir_migration.py" >/dev/null
}

test_prompt_submit_without_usable_turn_id_preserves_per_turn_state() {
  local kind proof_root state_dir input out

  for kind in absent empty object; do
    proof_root="$(fresh_proof_root prompt-clear-prior-$kind)"
    state_dir="$proof_root/pre-reviewer/t00-session"
    mkdir -p -m 0700 "$state_dir" || return 1
    printf '%s\n' '{"turn_id":"other-turn","prompt":"OTHER"}' >"$state_dir/capture-turn-other.json"
    : >"$state_dir/.capture-turn-other.capped.STALE"
    : >"$state_dir/claim-turn-other"
    input="$TMP_ROOT/prompt-clear-prior-$kind.json"
    case "$kind" in
      absent) jq -n --arg cwd "$ROOT" \
        '{session_id:"t00-session",hook_event_name:"UserPromptSubmit",cwd:$cwd,prompt:"legacy"}' >"$input" ;;
      empty) jq -n --arg cwd "$ROOT" \
        '{session_id:"t00-session",hook_event_name:"UserPromptSubmit",cwd:$cwd,turn_id:"",prompt:"legacy"}' >"$input" ;;
      object) jq -n --arg cwd "$ROOT" \
        '{session_id:"t00-session",hook_event_name:"UserPromptSubmit",cwd:$cwd,turn_id:{bad:true},prompt:"legacy"}' >"$input" ;;
    esac
    out="$TMP_ROOT/prompt-clear-prior-$kind.out"
    run_hook "$out" "$ROOT/hooks/prompt-task-reminder.sh" "$input" \
      HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" || return 1
    expect_no_output "$out" &&
      [ -e "$state_dir/capture-turn-other.json" ] &&
      [ -e "$state_dir/.capture-turn-other.capped.STALE" ] &&
      [ -e "$state_dir/claim-turn-other" ] || return 1
  done
}

test_turn_id_extractor_enforces_utf8_byte_bound_and_canonical_json() {
  local label turn_id expected input extracted canonical

  for label in empty ascii-4095 ascii-4096 ascii-4097 two-4096 two-4098 four-4096 four-4100 mixed-4096; do
    case "$label" in
      empty) turn_id=; expected=0 ;;
      ascii-4095) printf -v turn_id '%*s' 4095 ''; turn_id=${turn_id// /x}; expected=1 ;;
      ascii-4096) printf -v turn_id '%*s' 4096 ''; turn_id=${turn_id// /x}; expected=1 ;;
      ascii-4097) printf -v turn_id '%*s' 4097 ''; turn_id=${turn_id// /x}; expected=0 ;;
      two-4096) printf -v turn_id '%*s' 2048 ''; turn_id=${turn_id// /é}; expected=1 ;;
      two-4098) printf -v turn_id '%*s' 2049 ''; turn_id=${turn_id// /é}; expected=0 ;;
      four-4096) printf -v turn_id '%*s' 1024 ''; turn_id=${turn_id// /😀}; expected=1 ;;
      four-4100) printf -v turn_id '%*s' 1025 ''; turn_id=${turn_id// /😀}; expected=0 ;;
      mixed-4096) printf -v turn_id '%*s' 4090 ''; turn_id=${turn_id// /x}; turn_id+="é😀"; expected=1 ;;
    esac
    input=$(jq -cn --arg turn_id "$turn_id" '{turn_id:$turn_id}') || return 1
    extracted=$(bash -c '. "$1"; codex_hook_turn_id_json "$2"' \
      bash "$ROOT/hooks/lib/pre-reviewer-turn-state.sh" "$input") || return 1
    canonical=$(jq -cn --arg turn_id "$turn_id" '$turn_id') || return 1
    if [ "$expected" -eq 1 ]; then
      [ "$extracted" = "$canonical" ] || return 1
    else
      [ -z "$extracted" ] || return 1
    fi
  done

  input="$TMP_ROOT/turn-id-invalid-utf8.json"
  printf '{"turn_id":"\377"}' >"$input"
  # jq normalizes a raw invalid byte to U+FFFD; strict rejection remains in the
  # Python capture validator, whose parser receives bytes rather than shell text.
  [ "$(bash -c '. "$1"; codex_hook_turn_id_json "$(cat "$2")"' \
    bash "$ROOT/hooks/lib/pre-reviewer-turn-state.sh" "$input")" = '"�"' ]
}

test_prompt_unusable_turn_ids_skip_normal_state_but_preserve_side() {
  local kind proof_root input out

  for kind in absent empty null bool number array object; do
    proof_root="$(fresh_proof_root prompt-unusable-$kind)"
    input="$TMP_ROOT/prompt-unusable-$kind.json"
    jq -n --arg cwd "$ROOT" \
      '{session_id:"t00-session",hook_event_name:"UserPromptSubmit",cwd:$cwd,prompt:"ordinary"}' \
      >"$input" || return 1
    case "$kind" in
      absent) ;;
      empty) jq '.turn_id = ""' "$input" >"$input.tmp" && mv "$input.tmp" "$input" ;;
      null) jq '.turn_id = null' "$input" >"$input.tmp" && mv "$input.tmp" "$input" ;;
      bool) jq '.turn_id = true' "$input" >"$input.tmp" && mv "$input.tmp" "$input" ;;
      number) jq '.turn_id = 42' "$input" >"$input.tmp" && mv "$input.tmp" "$input" ;;
      array) jq '.turn_id = ["bad"]' "$input" >"$input.tmp" && mv "$input.tmp" "$input" ;;
      object) jq '.turn_id = {bad:true}' "$input" >"$input.tmp" && mv "$input.tmp" "$input" ;;
    esac
    out="$TMP_ROOT/prompt-unusable-$kind.out"
    run_hook "$out" "$ROOT/hooks/prompt-task-reminder.sh" "$input" \
      HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" || return 1
    expect_no_output "$out" && [ ! -e "$proof_root/reviewer/t00-session" ] &&
      [ ! -e "$proof_root/pre-reviewer/t00-session" ] || return 1
  done

  proof_root="$(fresh_proof_root prompt-unusable-side)"
  input="$TMP_ROOT/prompt-unusable-side.json"
  jq -n --arg cwd "$ROOT" --arg turn_id "$(printf '%4097s' '' | tr ' ' x)" \
    '{session_id:"t00-session",hook_event_name:"UserPromptSubmit",cwd:$cwd,
      turn_id:$turn_id,prompt:"/side continue"}' >"$input" || return 1
  out="$TMP_ROOT/prompt-unusable-side.out"
  run_hook "$out" "$ROOT/hooks/prompt-task-reminder.sh" "$input" \
    HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" || return 1
  expect_no_output "$out" && [ -f "$proof_root/side-stop/sessions/t00-session/side_stop" ] &&
    [ ! -e "$proof_root/reviewer/t00-session" ] && [ ! -e "$proof_root/pre-reviewer/t00-session" ]
}

test_turn_id_byte_bound_applies_to_prompt_and_pretool_lifecycle() {
  local label turn_id proof_root transcript prompt_input prompt_out pre_input pre_out trace body bin_dir effects
  local state_dir capture

  for label in ascii-4096 two-4096; do
    case "$label" in
      ascii-4096) printf -v turn_id '%*s' 4096 ''; turn_id=${turn_id// /x} ;;
      two-4096) printf -v turn_id '%*s' 2048 ''; turn_id=${turn_id// /é} ;;
    esac
    proof_root="$(fresh_proof_root turn-bound-accepted-$label)"
    transcript="$TMP_ROOT/home/.codex/sessions/turn-bound-accepted-$label.jsonl"
    write_large_history_main_pre_reviewer_transcript "$transcript" || return 1
    submit_current_turn "$proof_root" "$turn_id" "BOUNDARY_PROMPT_$label" \
      "turn-bound-accepted-$label" || return 1
    capture="$(turn_capture_path "$proof_root" "$turn_id")" || return 1
    [ -f "$capture" ] && [ -d "$proof_root/reviewer/t00-session" ] || return 1
    pre_input="$TMP_ROOT/turn-bound-accepted-$label-pre.json"
    write_present_pre_reviewer_input "$transcript" "$turn_id" "$pre_input" || return 1
    pre_out="$TMP_ROOT/turn-bound-accepted-$label-pre.out"
    run_hook "$pre_out" "$ROOT/hooks/edit-bash-pre-reviewer.sh" "$pre_input" \
      HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" \
      CODEX_EDIT_PRE_REVIEWER="ollama:http://127.0.0.1:11434:qwen3:4b" \
      CODEX_PRE_REVIEWER_FAKE_RESULT='{"verdict":"deny","reason":"Boundary accepted."}' || return 1
    is_pretool_deny "$pre_out" || return 1
  done

  for label in ascii-4097 two-4098; do
    case "$label" in
      ascii-4097) printf -v turn_id '%*s' 4097 ''; turn_id=${turn_id// /x} ;;
      two-4098) printf -v turn_id '%*s' 2049 ''; turn_id=${turn_id// /é} ;;
    esac
    proof_root="$(fresh_proof_root turn-bound-rejected-$label)"
    state_dir="$proof_root/pre-reviewer/t00-session"
    transcript="$TMP_ROOT/home/.codex/sessions/turn-bound-rejected-$label.jsonl"
    write_large_history_main_pre_reviewer_transcript "$transcript" || return 1
    prompt_input="$TMP_ROOT/turn-bound-rejected-$label-prompt.json"
    jq -n --arg cwd "$ROOT" --arg turn_id "$turn_id" \
      '{session_id:"t00-session",hook_event_name:"UserPromptSubmit",cwd:$cwd,
        turn_id:$turn_id,prompt:"REJECTED_BOUNDARY"}' >"$prompt_input" || return 1
    prompt_out="$TMP_ROOT/turn-bound-rejected-$label-prompt.out"
    run_hook "$prompt_out" "$ROOT/hooks/prompt-task-reminder.sh" "$prompt_input" \
      HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" || return 1

    bin_dir="$TMP_ROOT/turn-bound-rejected-$label-bin"
    effects="$TMP_ROOT/turn-bound-rejected-$label-effects"
    write_pre_reviewer_side_effect_spies "$bin_dir" || return 1
    : >"$effects"
    pre_input="$TMP_ROOT/turn-bound-rejected-$label-pre.json"
    write_present_pre_reviewer_input "$transcript" "$turn_id" "$pre_input" || return 1
    pre_out="$TMP_ROOT/turn-bound-rejected-$label-pre.out"
    trace="$TMP_ROOT/turn-bound-rejected-$label.trace"
    body="$TMP_ROOT/turn-bound-rejected-$label-body.md"
    strace -f -qq -e trace=read -P "$transcript" -o "$trace" \
      env -u CODEX_ROLE PATH="$bin_dir:$PATH" HOME="$TMP_ROOT/home" \
        CODEX_PROOF_ROOT="$proof_root" CODEX_TEST_SIDE_EFFECTS="$effects" \
        CODEX_EDIT_PRE_REVIEWER="ollama:http://127.0.0.1:11434:qwen3:4b" \
        CODEX_PRE_REVIEWER_DEBUG_BODY_PATH="$body" \
        bash "$ROOT/hooks/edit-bash-pre-reviewer.sh" <"$pre_input" >"$pre_out" 2>"$pre_out.err" || return 1
    expect_no_output "$prompt_out" && expect_no_output "$pre_out" &&
      [ ! -e "$proof_root/reviewer/t00-session" ] && [ ! -e "$state_dir" ] &&
      [ ! -e "$body" ] && [ ! -s "$effects" ] && ! grep -q 'read(' "$trace" || return 1
  done
}

write_pre_reviewer_side_effect_spies() {
  local bin_dir="$1"
  local name real

  mkdir -p "$bin_dir" || return 1
  for name in sed find curl; do
    real="$(command -v "$name")" || return 1
    cat >"$bin_dir/$name" <<EOF
#!/usr/bin/env bash
printf '%s\n' '$name' >>"\$CODEX_TEST_SIDE_EFFECTS"
exec "$real" "\$@"
EOF
    chmod 0755 "$bin_dir/$name" || return 1
  done
}

test_pre_reviewer_unusable_turn_ids_fail_open_before_side_effects() {
  local kind proof_root transcript input out trace body bin_dir effects state_dir
  transcript="$TMP_ROOT/home/.codex/sessions/pre-reviewer-unusable-turn-id.jsonl"
  install_reviewer_transcript_fixture "$FIXTURES/reviewer-main-transcript.jsonl" "$transcript" || return 1
  bin_dir="$TMP_ROOT/pre-reviewer-unusable-turn-id-bin"
  effects="$TMP_ROOT/pre-reviewer-unusable-turn-id-effects"
  write_pre_reviewer_side_effect_spies "$bin_dir" || return 1

  for kind in absent empty null bool number array object; do
    proof_root="$(fresh_proof_root pre-reviewer-unusable-turn-id-$kind)"
    state_dir="$proof_root/pre-reviewer/t00-session"
    input="$TMP_ROOT/pre-reviewer-unusable-turn-id-$kind.json"
    case "$kind" in
      absent) jq --arg cwd "$ROOT" --arg transcript "$transcript" \
        '.cwd = $cwd | .transcript_path = $transcript | del(.turn_id)' \
        "$FIXTURES/pre-reviewer-bash.json" >"$input" ;;
      empty) jq --arg cwd "$ROOT" --arg transcript "$transcript" \
        '.cwd = $cwd | .transcript_path = $transcript | .turn_id = ""' \
        "$FIXTURES/pre-reviewer-bash.json" >"$input" ;;
      null) jq --arg cwd "$ROOT" --arg transcript "$transcript" \
        '.cwd = $cwd | .transcript_path = $transcript | .turn_id = null' \
        "$FIXTURES/pre-reviewer-bash.json" >"$input" ;;
      bool) jq --arg cwd "$ROOT" --arg transcript "$transcript" \
        '.cwd = $cwd | .transcript_path = $transcript | .turn_id = true' \
        "$FIXTURES/pre-reviewer-bash.json" >"$input" ;;
      number) jq --arg cwd "$ROOT" --arg transcript "$transcript" \
        '.cwd = $cwd | .transcript_path = $transcript | .turn_id = 42' \
        "$FIXTURES/pre-reviewer-bash.json" >"$input" ;;
      array) jq --arg cwd "$ROOT" --arg transcript "$transcript" \
        '.cwd = $cwd | .transcript_path = $transcript | .turn_id = ["bad"]' \
        "$FIXTURES/pre-reviewer-bash.json" >"$input" ;;
      object) jq --arg cwd "$ROOT" --arg transcript "$transcript" \
        '.cwd = $cwd | .transcript_path = $transcript | .turn_id = {bad:true}' \
        "$FIXTURES/pre-reviewer-bash.json" >"$input" ;;
    esac
    out="$TMP_ROOT/pre-reviewer-unusable-turn-id-$kind.out"
    trace="$TMP_ROOT/pre-reviewer-unusable-turn-id-$kind.trace"
    body="$TMP_ROOT/pre-reviewer-unusable-turn-id-$kind-body.md"
    : >"$effects"
    strace -f -qq -e trace=read -P "$transcript" -o "$trace" \
      env -u CODEX_ROLE PATH="$bin_dir:$PATH" HOME="$TMP_ROOT/home" \
        CODEX_PROOF_ROOT="$proof_root" CODEX_TEST_SIDE_EFFECTS="$effects" \
        CODEX_EDIT_PRE_REVIEWER="ollama:http://127.0.0.1:11434:qwen3:4b" \
        CODEX_PRE_REVIEWER_DEBUG_BODY_PATH="$body" \
        CODEX_PRE_REVIEWER_FAKE_RESULT='{"verdict":"deny","reason":"Must not run."}' \
        bash "$ROOT/hooks/edit-bash-pre-reviewer.sh" <"$input" >"$out" 2>"$out.err" || return 1
    expect_no_output "$out" && ! grep -q 'read(' "$trace" && [ ! -s "$effects" ] &&
      [ ! -e "$state_dir" ] && [ ! -e "$body" ] || return 1
  done

  ! grep -Eq 'find_transcript|jq[[:space:]]+-rs' "$ROOT/hooks/edit-bash-pre-reviewer.sh"
}

test_pre_reviewer_denies_first_tool_call_once_per_turn() {
  local proof_root input out transcript
  proof_root="$(fresh_proof_root pre-reviewer-first)"
  transcript="$(main_reviewer_transcript_path)"
  install_reviewer_transcript_fixture "$FIXTURES/reviewer-main-transcript.jsonl" "$transcript" || return 1
  submit_current_turn "$proof_root" pre-reviewer-first "FIRST_TOOL_PROMPT" pre-reviewer-first || return 1
  input="$TMP_ROOT/pre-reviewer-first.json"
  write_present_pre_reviewer_input "$transcript" pre-reviewer-first "$input" || return 1
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

run_pre_reviewer_fake_deny() {
  local tag="$1"
  local proof_root input out transcript
  shift

  proof_root="$(fresh_proof_root "$tag")"
  transcript="$(main_reviewer_transcript_path)"
  install_reviewer_transcript_fixture "$FIXTURES/reviewer-main-transcript.jsonl" "$transcript" || return 1
  submit_current_turn "$proof_root" "$tag-turn" "ALIAS_PROMPT" "$tag" || return 1
  input="$TMP_ROOT/$tag.json"
  write_present_pre_reviewer_input "$transcript" "$tag-turn" "$input" || return 1
  out="$TMP_ROOT/$tag.out"

  run_hook "$out" "$ROOT/hooks/edit-bash-pre-reviewer.sh" "$input" \
    HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" \
    "$@" \
    CODEX_PRE_REVIEWER_FAKE_RESULT='{"verdict":"deny","reason":"Alias selected."}' || return 1

  is_pretool_deny "$out" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "Alias selected"
}

run_pre_reviewer_expect_no_output() {
  local tag="$1"
  local proof_root input out transcript
  shift

  proof_root="$(fresh_proof_root "$tag")"
  transcript="$(main_reviewer_transcript_path)"
  install_reviewer_transcript_fixture "$FIXTURES/reviewer-main-transcript.jsonl" "$transcript" || return 1
  submit_current_turn "$proof_root" "$tag-turn" "ALIAS_PROMPT" "$tag" || return 1
  input="$TMP_ROOT/$tag.json"
  write_present_pre_reviewer_input "$transcript" "$tag-turn" "$input" || return 1
  out="$TMP_ROOT/$tag.out"

  run_hook "$out" "$ROOT/hooks/edit-bash-pre-reviewer.sh" "$input" \
    HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" \
    "$@" \
    CODEX_PRE_REVIEWER_FAKE_RESULT='{"verdict":"deny","reason":"Fallback selected."}' || return 1

  expect_no_output "$out"
}

test_pre_reviewer_llm_alias_enables_fake_deny() {
  run_pre_reviewer_fake_deny "pre-reviewer-llm-alias" \
    CODEX_EDIT_PRE_REVIEWER= \
    LLM_EDIT_PRE_REVIEWER="ollama:http://127.0.0.1:11434:qwen3:4b" \
    CLAUDE_EDIT_PRE_REVIEWER=
}

test_pre_reviewer_claude_alias_enables_fake_deny() {
  run_pre_reviewer_fake_deny "pre-reviewer-claude-alias" \
    CODEX_EDIT_PRE_REVIEWER= \
    LLM_EDIT_PRE_REVIEWER= \
    CLAUDE_EDIT_PRE_REVIEWER="ollama:http://127.0.0.1:11434:qwen3:4b"
}

test_pre_reviewer_codex_alias_precedence_ignores_malformed_lower_aliases() {
  run_pre_reviewer_fake_deny "pre-reviewer-codex-precedence" \
    CODEX_EDIT_PRE_REVIEWER="ollama:http://127.0.0.1:11434:qwen3:4b" \
    LLM_EDIT_PRE_REVIEWER="malformed" \
    CLAUDE_EDIT_PRE_REVIEWER="also-malformed"
}

test_pre_reviewer_llm_alias_precedence_ignores_malformed_claude() {
  run_pre_reviewer_fake_deny "pre-reviewer-llm-precedence" \
    CODEX_EDIT_PRE_REVIEWER= \
    LLM_EDIT_PRE_REVIEWER="ollama:http://127.0.0.1:11434:qwen3:4b" \
    CLAUDE_EDIT_PRE_REVIEWER="malformed"
}

test_pre_reviewer_malformed_codex_does_not_fallback_to_llm() {
  run_pre_reviewer_expect_no_output "pre-reviewer-malformed-codex-no-llm-fallback" \
    CODEX_EDIT_PRE_REVIEWER="malformed" \
    LLM_EDIT_PRE_REVIEWER="ollama:http://127.0.0.1:11434:qwen3:4b" \
    CLAUDE_EDIT_PRE_REVIEWER=
}

test_pre_reviewer_malformed_llm_does_not_fallback_to_claude() {
  run_pre_reviewer_expect_no_output "pre-reviewer-malformed-llm-no-claude-fallback" \
    CODEX_EDIT_PRE_REVIEWER= \
    LLM_EDIT_PRE_REVIEWER="malformed" \
    CLAUDE_EDIT_PRE_REVIEWER="ollama:http://127.0.0.1:11434:qwen3:4b"
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
  local proof_root input out transcript body command description prompt
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
  prompt="$(jq -rs '.[1].message.content' "$transcript")" || return 1
  submit_current_turn "$proof_root" pre-reviewer-redaction "$prompt" pre-reviewer-redaction || return 1
  write_present_pre_reviewer_input "$transcript" pre-reviewer-redaction "$input" || return 1
  jq --arg command "$command" --arg description "$description" \
    '.tool_input.command = $command | .tool_input.description = $description' "$input" >"$input.tmp" || return 1
  mv "$input.tmp" "$input" || return 1
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
  submit_current_turn "$proof_root" pre-reviewer-stop-bypass "BYPASS_PROMPT" pre-reviewer-stop-bypass || return 1
  command="touch $proof_root/reviewer/t00-session/bypass"
  input="$TMP_ROOT/pre-reviewer-stop-bypass.json"
  write_present_pre_reviewer_input "$transcript" pre-reviewer-stop-bypass "$input" || return 1
  jq --arg command "$command" '.tool_input.command = $command' "$input" >"$input.tmp" || return 1
  mv "$input.tmp" "$input" || return 1
  out="$TMP_ROOT/pre-reviewer-stop-bypass.out"

  run_hook "$out" "$ROOT/hooks/edit-bash-pre-reviewer.sh" "$input" \
    HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" \
    CODEX_EDIT_PRE_REVIEWER="ollama:http://127.0.0.1:11434:qwen3:4b" \
    CODEX_PRE_REVIEWER_FAKE_RESULT='{"verdict":"deny","reason":"Load the matching skill first."}' || return 1

  expect_no_output "$out"
}

test_pre_reviewer_allows_after_prior_tool_call() {
  local proof_root input first_out out transcript
  proof_root="$(fresh_proof_root pre-reviewer-prior)"
  transcript="$(main_reviewer_transcript_path)"
  install_reviewer_transcript_fixture "$FIXTURES/reviewer-prior-tool-transcript.jsonl" "$transcript" || return 1
  submit_current_turn "$proof_root" pre-reviewer-prior "PRIOR_PROMPT" pre-reviewer-prior || return 1
  input="$TMP_ROOT/pre-reviewer-prior.json"
  write_present_pre_reviewer_input "$transcript" pre-reviewer-prior "$input" || return 1
  first_out="$TMP_ROOT/pre-reviewer-prior-first.out"
  run_hook "$first_out" "$ROOT/hooks/edit-bash-pre-reviewer.sh" "$input" \
    HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" \
    CODEX_EDIT_PRE_REVIEWER="ollama:http://127.0.0.1:11434:qwen3:4b" \
    CODEX_PRE_REVIEWER_FAKE_RESULT='{"verdict":"allow","reason":"Claim turn."}' || return 1
  expect_no_output "$first_out" || return 1
  out="$TMP_ROOT/pre-reviewer-prior.out"

  run_hook "$out" "$ROOT/hooks/edit-bash-pre-reviewer.sh" "$input" \
    HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" \
    CODEX_EDIT_PRE_REVIEWER="ollama:http://127.0.0.1:11434:qwen3:4b" \
    CODEX_PRE_REVIEWER_FAKE_RESULT='{"verdict":"deny","reason":"Load the matching skill first."}' || return 1

  expect_no_output "$out"
}

test_pre_reviewer_allows_after_prior_response_item_tool_call() {
  local proof_root input first_out out transcript
  proof_root="$(fresh_proof_root pre-reviewer-prior-response-item)"
  transcript="$(main_reviewer_transcript_path)"
  install_reviewer_transcript_fixture "$FIXTURES/reviewer-prior-response-item-tool-transcript.jsonl" "$transcript" || return 1
  submit_current_turn "$proof_root" pre-reviewer-prior-response "PRIOR_RESPONSE_PROMPT" pre-reviewer-prior-response || return 1
  input="$TMP_ROOT/pre-reviewer-prior-response-item.json"
  write_present_pre_reviewer_input "$transcript" pre-reviewer-prior-response "$input" || return 1
  first_out="$TMP_ROOT/pre-reviewer-prior-response-item-first.out"
  run_hook "$first_out" "$ROOT/hooks/edit-bash-pre-reviewer.sh" "$input" \
    HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" \
    CODEX_EDIT_PRE_REVIEWER="ollama:http://127.0.0.1:11434:qwen3:4b" \
    CODEX_PRE_REVIEWER_FAKE_RESULT='{"verdict":"allow","reason":"Claim turn."}' || return 1
  expect_no_output "$first_out" || return 1
  out="$TMP_ROOT/pre-reviewer-prior-response-item.out"

  run_hook "$out" "$ROOT/hooks/edit-bash-pre-reviewer.sh" "$input" \
    HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" \
    CODEX_EDIT_PRE_REVIEWER="ollama:http://127.0.0.1:11434:qwen3:4b" \
    CODEX_PRE_REVIEWER_FAKE_RESULT='{"verdict":"deny","reason":"Load the matching skill first."}' || return 1

  expect_no_output "$out"
}

test_pre_reviewer_skips_spawned_subagent_transcript() {
  local proof_root input out transcript capture claim
  proof_root="$(fresh_proof_root pre-reviewer-subagent)"
  transcript="$(subagent_transcript_path)"
  write_subagent_transcript "$transcript" || return 1
  submit_current_turn "$proof_root" pre-reviewer-subagent "SUBAGENT_PROMPT" pre-reviewer-subagent || return 1
  capture="$(turn_capture_path "$proof_root" pre-reviewer-subagent)" || return 1
  claim="$(turn_claim_path "$proof_root" pre-reviewer-subagent)" || return 1
  input="$TMP_ROOT/pre-reviewer-subagent.json"
  write_present_pre_reviewer_input "$transcript" pre-reviewer-subagent "$input" || return 1
  out="$TMP_ROOT/pre-reviewer-subagent.out"

  run_hook "$out" "$ROOT/hooks/edit-bash-pre-reviewer.sh" "$input" \
    HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" \
    CODEX_EDIT_PRE_REVIEWER="ollama:http://127.0.0.1:11434:qwen3:4b" \
    CODEX_PRE_REVIEWER_FAKE_RESULT='{"verdict":"deny","reason":"Load the matching skill first."}' || return 1

  expect_no_output "$out" && [ -f "$capture" ] && [ ! -e "$claim" ]
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

test_eci_gate_denies_code_notebookedit_payload() {
  local proof_root input out
  proof_root="$(fresh_proof_root eci-code-notebook)"
  mkdir -p "$proof_root/t00-session"
  printf 'scope: test\n' >"$proof_root/t00-session/eci_active"
  input="$TMP_ROOT/eci-notebook.json"
  jq -n '{session_id:"t00-session",tool_name:"NotebookEdit",tool_input:{notebook_path:"src/file.ipynb"}}' >"$input"
  out="$TMP_ROOT/eci-notebook.out"

  run_hook "$out" "$ROOT/hooks/eci-active-gate.sh" "$input" \
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
      | select(any(.hooks[]?; (.command // "") | test("/eci-active-gate\\.sh")))
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

test_notebookedit_hook_config_is_wired() {
  local matcher
  matcher="$(eci_gate_matcher)" || return 1
  matcher_has_tool "$matcher" "NotebookEdit"
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

test_validate_apply_patch_blocks_vendor_path() {
  local out
  out="$TMP_ROOT/apply-patch-vendor.out"
  run_hook "$out" "$ROOT/hooks/validate-apply-patch.sh" "$FIXTURES/validate-apply-patch-vendor.json" || return 1
  is_pretool_deny "$out" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "original source" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "revendor"
}

test_validate_apply_patch_blocks_imports_move_destination() {
  local out
  out="$TMP_ROOT/apply-patch-imports-move.out"
  run_hook "$out" "$ROOT/hooks/validate-apply-patch.sh" "$FIXTURES/validate-apply-patch-imports-move.json" || return 1
  is_pretool_deny "$out" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "original source" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "revendor"
}

test_validate_apply_patch_allows_vendorish_path() {
  local out
  out="$TMP_ROOT/apply-patch-vendorish.out"
  run_hook "$out" "$ROOT/hooks/validate-apply-patch.sh" "$FIXTURES/validate-apply-patch-vendorish.json" || return 1
  expect_no_output "$out"
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

test_validate_edit_write_blocks_direct_write_imports_path() {
  local out
  out="$TMP_ROOT/edit-write-imports-write.out"
  run_hook "$out" "$ROOT/hooks/validate-edit-write.sh" "$FIXTURES/validate-edit-write-imports-write.json" || return 1
  is_pretool_deny "$out" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "original source" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "revendor"
}

test_validate_edit_write_blocks_direct_multiedit_vendor_path() {
  local out
  out="$TMP_ROOT/edit-write-vendor-multiedit.out"
  run_hook "$out" "$ROOT/hooks/validate-edit-write.sh" "$FIXTURES/validate-edit-write-vendor-multiedit.json" || return 1
  is_pretool_deny "$out" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "original source" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "revendor"
}

test_validate_edit_write_allows_vendorish_path() {
  local out
  out="$TMP_ROOT/edit-write-vendorish.out"
  run_hook "$out" "$ROOT/hooks/validate-edit-write.sh" "$FIXTURES/validate-edit-write-vendorish-edit.json" || return 1
  expect_no_output "$out"
}

test_validate_edit_write_blocks_submodule_edit() {
  local repo sub input out
  repo="$TMP_ROOT/sup-repo-$$"
  sub="$repo/sub"
  mkdir -p "$repo/.git" "$sub"
  printf 'gitdir: %s/modules/sub\n' "$repo/.git" >"$sub/.git"
  echo "package x" >"$sub/file.go"
  input="$TMP_ROOT/edit-submod-codex.json"
  jq -n --arg fp "$sub/file.go" '{tool_name:"Edit",tool_input:{file_path:$fp,old_string:"x",new_string:"y"}}' >"$input"
  out="$TMP_ROOT/edit-submod-codex.out"
  run_hook "$out" "$ROOT/hooks/validate-edit-write.sh" "$input" || return 1
  is_pretool_deny "$out" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "git submodule"
}

test_validate_edit_write_allows_regular_repo_edit() {
  local repo input out
  repo="$TMP_ROOT/regular-repo-$$"
  mkdir -p "$repo/.git"
  echo "package x" >"$repo/file.go"
  input="$TMP_ROOT/edit-regular-codex.json"
  jq -n --arg fp "$repo/file.go" '{tool_name:"Edit",tool_input:{file_path:$fp,old_string:"x",new_string:"y"}}' >"$input"
  out="$TMP_ROOT/edit-regular-codex.out"
  run_hook "$out" "$ROOT/hooks/validate-edit-write.sh" "$input" || return 1
  expect_no_output "$out"
}

test_validate_edit_write_allows_notebookedit_same_sid_proof() {
  local proof_root input out
  proof_root="$(fresh_proof_root edit-write-notebook-same)"
  mkdir -p "$proof_root/t00-session"
  input="$TMP_ROOT/edit-write-notebook-same.json"
  jq -n --arg fp "$proof_root/t00-session/project-understanding.md" \
    '{session_id:"t00-session",tool_name:"NotebookEdit",tool_input:{notebook_path:$fp,new_string:"x"}}' >"$input"
  out="$TMP_ROOT/edit-write-notebook-same.out"

  run_hook "$out" "$ROOT/hooks/validate-edit-write.sh" "$input" CODEX_PROOF_ROOT="$proof_root" || return 1
  expect_no_output "$out"
}

test_validate_edit_write_allows_aliased_proof_dir() {
  local proof_root input out alias_dir
  proof_root="$(fresh_proof_root edit-write-alias)"
  alias_dir="$proof_root/mission-alias"
  mkdir -p "$alias_dir"
  printf 'session_id: t00-session\n' >"$alias_dir/.codex-proof-alias"
  input="$TMP_ROOT/edit-write-alias.json"
  jq -n --arg fp "$alias_dir/project-understanding.md" \
    '{session_id:"t00-session",tool_name:"Write",tool_input:{file_path:$fp,content:"x"}}' >"$input"
  out="$TMP_ROOT/edit-write-alias.out"

  run_hook "$out" "$ROOT/hooks/validate-edit-write.sh" "$input" CODEX_PROOF_ROOT="$proof_root" || return 1
  expect_no_output "$out"
}

test_validate_edit_write_blocks_notebookedit_other_sid_proof() {
  local proof_root input out
  proof_root="$(fresh_proof_root edit-write-notebook-other)"
  mkdir -p "$proof_root/other-session"
  input="$TMP_ROOT/edit-write-notebook-other.json"
  jq -n --arg fp "$proof_root/other-session/project-understanding.md" \
    '{session_id:"t00-session",tool_name:"NotebookEdit",tool_input:{notebook_path:$fp,new_string:"x"}}' >"$input"
  out="$TMP_ROOT/edit-write-notebook-other.out"

  run_hook "$out" "$ROOT/hooks/validate-edit-write.sh" "$input" CODEX_PROOF_ROOT="$proof_root" || return 1
  is_pretool_deny "$out" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "other-session"
}

test_validate_apply_patch_allows_aliased_proof_dir() {
  local proof_root input out alias_dir patch_path patch_text
  proof_root="$(fresh_proof_root apply-patch-alias)"
  alias_dir="$proof_root/mission-alias"
  mkdir -p "$alias_dir"
  printf 'session_id: t00-session\n' >"$alias_dir/.codex-proof-alias"
  patch_path="$alias_dir/project-understanding.md"
  patch_text="$(printf '*** Begin Patch\n*** Add File: %s\n+test\n*** End Patch\n' "$patch_path")"
  input="$TMP_ROOT/apply-patch-alias.json"
  jq -n --arg patch "$patch_text" \
    '{session_id:"t00-session",tool_name:"apply_patch",tool_input:{patch:$patch}}' >"$input"
  out="$TMP_ROOT/apply-patch-alias.out"

  run_hook "$out" "$ROOT/hooks/validate-apply-patch.sh" "$input" CODEX_PROOF_ROOT="$proof_root" || return 1
  expect_no_output "$out"
}

test_validate_apply_patch_blocks_other_sid_proof() {
  local proof_root input out patch_path patch_text
  proof_root="$(fresh_proof_root apply-patch-other-session)"
  mkdir -p "$proof_root/other-session"
  patch_path="$proof_root/other-session/project-understanding.md"
  patch_text="$(printf '*** Begin Patch\n*** Add File: %s\n+test\n*** End Patch\n' "$patch_path")"
  input="$TMP_ROOT/apply-patch-other-session.json"
  jq -n --arg patch "$patch_text" \
    '{session_id:"t00-session",tool_name:"apply_patch",tool_input:{patch:$patch}}' >"$input"
  out="$TMP_ROOT/apply-patch-other-session.out"

  run_hook "$out" "$ROOT/hooks/validate-apply-patch.sh" "$input" CODEX_PROOF_ROOT="$proof_root" || return 1
  is_pretool_deny "$out" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "other-session"
}

test_validate_apply_patch_blocks_uuid_sid_despite_alias_marker() {
  local proof_root input out uuid_dir patch_path patch_text
  proof_root="$(fresh_proof_root apply-patch-uuid-alias)"
  uuid_dir="$proof_root/019e55e6-6d85-7181-b197-43aa5708609b"
  mkdir -p "$uuid_dir"
  printf 'session_id: t00-session\n' >"$uuid_dir/.codex-proof-alias"
  patch_path="$uuid_dir/project-understanding.md"
  patch_text="$(printf '*** Begin Patch\n*** Add File: %s\n+test\n*** End Patch\n' "$patch_path")"
  input="$TMP_ROOT/apply-patch-uuid-alias.json"
  jq -n --arg patch "$patch_text" \
    '{session_id:"t00-session",tool_name:"apply_patch",tool_input:{patch:$patch}}' >"$input"
  out="$TMP_ROOT/apply-patch-uuid-alias.out"

  run_hook "$out" "$ROOT/hooks/validate-apply-patch.sh" "$input" CODEX_PROOF_ROOT="$proof_root" || return 1
  is_pretool_deny "$out" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "019e55e6-6d85-7181-b197-43aa5708609b"
}

ledger_basenames() {
  printf '%s\n' \
    "project-understanding.md" \
    "high_level_log.md" \
    "latest-status-report.md"
}

test_validate_bash_allows_subagent_low_level_work() {
  local proof_root transcript repo input out command tag failures=0
  proof_root="$(fresh_proof_root bash-subagent-low-level)"
  transcript="$(subagent_transcript_path)"
  write_subagent_transcript "$transcript" || return 1
  repo="$(make_git_repo bash-subagent-low-level)" || return 1
  printf 'next\n' >"$repo/file.txt"

  while IFS=$'\t' read -r tag command; do
    [ -n "$tag" ] || continue
    input="$TMP_ROOT/bash-subagent-low-level-$tag.json"
    out="$TMP_ROOT/bash-subagent-low-level-$tag.out"
    jq --arg cwd "$repo" --arg transcript "$transcript" --arg command "$command" \
      '.session_id = "t00-session" | .cwd = $cwd | .transcript_path = $transcript | .tool_input.command = $command' \
      "$FIXTURES/pre-reviewer-bash.json" >"$input" || return 1

    run_hook "$out" "$ROOT/hooks/validate-bash.sh" "$input" HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" || return 1
    if ! expect_no_output "$out"; then
      note "$tag expected no hook output"
      cat "$out"
      failures=$((failures + 1))
    fi
  done <<EOF
mkdir	mkdir -p build/output
rg	rg -n ledger_basenames $ROOT/hooks/tests/run.sh
git-commit	git add file.txt && git commit -m low-level-work
EOF

  [ "$failures" -eq 0 ]
}

write_direct_ledger_input() {
  local tool="$1"
  local path="$2"
  local output="$3"

  case "$tool" in
    Edit)
      jq -n --arg fp "$path" \
        '{session_id:"t00-session",tool_name:"Edit",tool_input:{file_path:$fp,old_string:"old",new_string:"new"}}' >"$output"
      ;;
    Write)
      jq -n --arg fp "$path" \
        '{session_id:"t00-session",tool_name:"Write",tool_input:{file_path:$fp,content:"new"}}' >"$output"
      ;;
    MultiEdit)
      jq -n --arg fp "$path" \
        '{session_id:"t00-session",tool_name:"MultiEdit",tool_input:{file_path:$fp,edits:[{old_string:"old",new_string:"new"}]}}' >"$output"
      ;;
    NotebookEdit)
      jq -n --arg fp "$path" \
        '{session_id:"t00-session",tool_name:"NotebookEdit",tool_input:{notebook_path:$fp,new_string:"new"}}' >"$output"
      ;;
    *) return 1 ;;
  esac
}

write_apply_patch_input() {
  local path="$1"
  local output="$2"
  local patch_text

  patch_text="$(printf '*** Begin Patch\n*** Update File: %s\n@@\n-old\n+new\n*** End Patch\n' "$path")"
  jq -n --arg patch "$patch_text" \
    '{session_id:"t00-session",tool_name:"apply_patch",tool_input:{patch:$patch}}' >"$output"
}

test_validate_direct_and_apply_block_subagent_ledger_paths() {
  local proof_root ledger_dir transcript ledger tool input out tag
  proof_root="$(fresh_proof_root direct-subagent-ledger)"
  ledger_dir="$proof_root/t00-session"
  mkdir -p "$ledger_dir" || return 1
  transcript="$(subagent_transcript_path)"
  write_subagent_transcript "$transcript" || return 1

  while IFS= read -r ledger; do
    for tool in Edit Write MultiEdit NotebookEdit; do
      tag="direct-subagent-ledger-${tool}-${ledger//[^A-Za-z0-9]/-}"
      input="$TMP_ROOT/$tag.json"
      write_direct_ledger_input "$tool" "$ledger" "$input" || return 1
      jq --arg cwd "$ledger_dir" --arg transcript "$transcript" \
        '.cwd = $cwd | .transcript_path = $transcript' "$input" >"$input.tmp" &&
        mv "$input.tmp" "$input" || return 1
      out="$TMP_ROOT/$tag.out"

      run_hook "$out" "$ROOT/hooks/validate-edit-write.sh" "$input" HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" || return 1
      is_pretool_deny "$out" &&
        json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "Only the main thread" || {
          printf '%s\n' "$tag expected ledger write denial" >&2
          cat "$out" >&2
          return 1
        }
    done

    tag="apply-subagent-ledger-${ledger//[^A-Za-z0-9]/-}"
    input="$TMP_ROOT/$tag.json"
    write_apply_patch_input "$ledger" "$input" || return 1
    jq --arg cwd "$ledger_dir" --arg transcript "$transcript" \
      '.cwd = $cwd | .transcript_path = $transcript' "$input" >"$input.tmp" &&
      mv "$input.tmp" "$input" || return 1
    out="$TMP_ROOT/$tag.out"

    run_hook "$out" "$ROOT/hooks/validate-apply-patch.sh" "$input" HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" || return 1
    is_pretool_deny "$out" &&
      json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "Only the main thread" || {
        printf '%s\n' "$tag expected ledger write denial" >&2
        cat "$out" >&2
        return 1
      }
  done < <(ledger_basenames)
}

test_validate_direct_and_apply_allow_main_ledger_paths() {
  local proof_root ledger_dir ledger tool input out tag
  proof_root="$(fresh_proof_root direct-main-ledger)"
  ledger_dir="$proof_root/t00-session"
  mkdir -p "$ledger_dir" || return 1

  while IFS= read -r ledger; do
    for tool in Edit Write MultiEdit NotebookEdit; do
      tag="direct-main-ledger-${tool}-${ledger//[^A-Za-z0-9]/-}"
      input="$TMP_ROOT/$tag.json"
      write_direct_ledger_input "$tool" "$ledger" "$input" || return 1
      jq --arg cwd "$ledger_dir" '.cwd = $cwd' "$input" >"$input.tmp" &&
        mv "$input.tmp" "$input" || return 1
      out="$TMP_ROOT/$tag.out"

      run_hook "$out" "$ROOT/hooks/validate-edit-write.sh" "$input" CODEX_PROOF_ROOT="$proof_root" || return 1
      expect_no_output "$out" || {
        printf '%s\n' "$tag expected no denial" >&2
        cat "$out" >&2
        return 1
      }
    done

    tag="apply-main-ledger-${ledger//[^A-Za-z0-9]/-}"
    input="$TMP_ROOT/$tag.json"
    write_apply_patch_input "$ledger" "$input" || return 1
    jq --arg cwd "$ledger_dir" '.cwd = $cwd' "$input" >"$input.tmp" &&
      mv "$input.tmp" "$input" || return 1
    out="$TMP_ROOT/$tag.out"

    run_hook "$out" "$ROOT/hooks/validate-apply-patch.sh" "$input" CODEX_PROOF_ROOT="$proof_root" || return 1
    expect_no_output "$out" || {
      printf '%s\n' "$tag expected no denial" >&2
      cat "$out" >&2
      return 1
    }
  done < <(ledger_basenames)
}

test_validate_direct_and_apply_allow_subagent_non_ledger_parent_proof_paths() {
  local proof_root parent_dir transcript tool input out tag proof_path
  proof_root="$(fresh_proof_root direct-subagent-parent-proof)"
  parent_dir="$proof_root/parent-session"
  mkdir -p "$parent_dir" || return 1
  proof_path="$parent_dir/proof.md"
  transcript="$(subagent_transcript_path)"
  write_subagent_transcript "$transcript" || return 1

  for tool in Edit Write MultiEdit NotebookEdit; do
    tag="direct-subagent-parent-proof-$tool"
    input="$TMP_ROOT/$tag.json"
    write_direct_ledger_input "$tool" "$proof_path" "$input" || return 1
    jq --arg cwd "$ROOT" --arg transcript "$transcript" \
      '.cwd = $cwd | .transcript_path = $transcript' "$input" >"$input.tmp" &&
      mv "$input.tmp" "$input" || return 1
    out="$TMP_ROOT/$tag.out"

    run_hook "$out" "$ROOT/hooks/validate-edit-write.sh" "$input" HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" || return 1
    expect_no_output "$out" || {
      printf '%s\n' "$tag expected no denial" >&2
      cat "$out" >&2
      return 1
    }
  done

  input="$TMP_ROOT/apply-subagent-parent-proof.json"
  write_apply_patch_input "$proof_path" "$input" || return 1
  jq --arg cwd "$ROOT" --arg transcript "$transcript" \
    '.cwd = $cwd | .transcript_path = $transcript' "$input" >"$input.tmp" &&
    mv "$input.tmp" "$input" || return 1
  out="$TMP_ROOT/apply-subagent-parent-proof.out"

  run_hook "$out" "$ROOT/hooks/validate-apply-patch.sh" "$input" HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" || return 1
  expect_no_output "$out"
}

test_validate_bash_allows_write_into_submodule() {
  # Submodule write blocking is the file-edit tools' job (Edit/Write/MultiEdit
  # via validate-edit-write.sh). Bash is intentionally NOT gated on submodule
  # paths, so normal script/build workflows in submodules still work.
  local repo sub input out
  repo="$TMP_ROOT/sup-repo-bash-$$"
  sub="$repo/sub"
  mkdir -p "$repo/.git" "$sub"
  printf 'gitdir: %s/modules/sub\n' "$repo/.git" >"$sub/.git"
  input="$TMP_ROOT/bash-submod-codex.json"
  jq -n --arg cmd "echo y > $sub/file.go" '{tool_name:"Bash",tool_input:{command:$cmd}}' >"$input"
  out="$TMP_ROOT/bash-submod-codex.out"
  run_hook "$out" "$ROOT/hooks/validate-bash.sh" "$input" || return 1
  local decision
  decision=$(jq -r '.hookSpecificOutput.permissionDecision // "no-decision"' <"$out" 2>/dev/null)
  [ -z "$decision" ] && decision="no-decision"

  if [ "$decision" != "deny" ]; then
    pass "validate-bash allows writes into a git submodule"
  else
    fail "validate-bash allows writes into a git submodule" \
      "decision=$decision; expected non-deny. Output: $(head -c 300 "$out")"
  fi
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
      any($commands[]?; contains($suffix));

    (commands_for("^apply_patch$") as $apply
      | commands_for("^(Edit|Write|MultiEdit|NotebookEdit)$") as $direct
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

test_validate_bash_marks_shell_activity() {
  local proof_root input out
  proof_root="$(fresh_proof_root activity-bash)"
  input="$TMP_ROOT/activity-bash.json"
  jq --arg cwd "$ROOT" '.session_id = "t00-session" | .cwd = $cwd' "$FIXTURES/validate-bash-go-test-redirect.json" >"$input"
  out="$TMP_ROOT/activity-bash.out"

  run_hook "$out" "$ROOT/hooks/validate-bash.sh" "$input" CODEX_PROOF_ROOT="$proof_root" || return 1
  expect_no_output "$out" &&
    [ -s "$proof_root/activity/sessions/t00-session/shell" ]
}

test_validate_bash_skips_read_only_shell_activity() {
  local proof_root input out command
  proof_root="$(fresh_proof_root activity-bash-read-only)"
  command='rg -n "codex-proof|CODEX_PROOF_ROOT|proof_dir" . -S'
  input="$TMP_ROOT/activity-bash-read-only.json"
  jq --arg cwd "$ROOT" --arg command "$command" \
    '.session_id = "t00-session" | .cwd = $cwd | .tool_input.command = $command' \
    "$FIXTURES/pre-reviewer-bash.json" >"$input"
  out="$TMP_ROOT/activity-bash-read-only.out"

  run_hook "$out" "$ROOT/hooks/validate-bash.sh" "$input" CODEX_PROOF_ROOT="$proof_root" || return 1
  expect_no_output "$out" &&
    [ ! -e "$proof_root/activity/sessions/t00-session/shell" ]
}

test_validate_bash_skips_read_only_shell_chain_activity() {
  local proof_root input out command
  proof_root="$(fresh_proof_root activity-bash-read-chain)"
  command="sed -n '1,90p' hooks/stop-gate.sh && sed -n '360,430p' hooks/stop-gate.sh && sed -n '660,745p' hooks/stop-gate.sh"
  input="$TMP_ROOT/activity-bash-read-chain.json"
  jq --arg cwd "$ROOT" --arg command "$command" \
    '.session_id = "t00-session" | .cwd = $cwd | .tool_input.command = $command' \
    "$FIXTURES/pre-reviewer-bash.json" >"$input"
  out="$TMP_ROOT/activity-bash-read-chain.out"

  run_hook "$out" "$ROOT/hooks/validate-bash.sh" "$input" CODEX_PROOF_ROOT="$proof_root" || return 1
  expect_no_output "$out" &&
    [ ! -e "$proof_root/activity/sessions/t00-session/shell" ]
}

test_validate_bash_marks_redirected_read_shell_activity() {
  local proof_root input out command
  proof_root="$(fresh_proof_root activity-bash-read-redirect)"
  command="sed -n '1,5p' CODEX.md > /tmp/codex-read-output.txt"
  input="$TMP_ROOT/activity-bash-read-redirect.json"
  jq --arg cwd "$ROOT" --arg command "$command" \
    '.session_id = "t00-session" | .cwd = $cwd | .tool_input.command = $command' \
    "$FIXTURES/pre-reviewer-bash.json" >"$input"
  out="$TMP_ROOT/activity-bash-read-redirect.out"

  run_hook "$out" "$ROOT/hooks/validate-bash.sh" "$input" CODEX_PROOF_ROOT="$proof_root" || return 1
  expect_no_output "$out" &&
    [ -s "$proof_root/activity/sessions/t00-session/shell" ]
}

test_validate_bash_blocks_subagent_eci_active_off() {
  local input out transcript command
  transcript="$(subagent_transcript_path)"
  write_subagent_transcript "$transcript" || return 1
  command="~/.codex/bin/eci-active off /tmp/eci-disengage.md"
  input="$TMP_ROOT/bash-subagent-eci-off.json"
  jq --arg cwd "$ROOT" --arg transcript "$transcript" --arg command "$command" \
    '.cwd = $cwd | .transcript_path = $transcript | .tool_input.command = $command' \
    "$FIXTURES/pre-reviewer-bash.json" >"$input"
  out="$TMP_ROOT/bash-subagent-eci-off.out"

  run_hook "$out" "$ROOT/hooks/validate-bash.sh" "$input" HOME="$TMP_ROOT/home" || return 1
  is_pretool_deny "$out" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "Only the main thread"
}

test_validate_bash_allows_main_eci_active_off() {
  local input out transcript command
  transcript="$TMP_ROOT/home/.codex/sessions/codex-hooks-test-main-eci-off.jsonl"
  write_main_transcript "$transcript" || return 1
  command="~/.codex/bin/eci-active off /tmp/eci-disengage.md"
  input="$TMP_ROOT/bash-main-eci-off.json"
  jq --arg cwd "$ROOT" --arg transcript "$transcript" --arg command "$command" \
    '.cwd = $cwd | .transcript_path = $transcript | .tool_input.command = $command' \
    "$FIXTURES/pre-reviewer-bash.json" >"$input"
  out="$TMP_ROOT/bash-main-eci-off.out"

  run_hook "$out" "$ROOT/hooks/validate-bash.sh" "$input" HOME="$TMP_ROOT/home" || return 1
  expect_no_output "$out"
}

test_validate_bash_blocks_git_reset_without_marker() {
  local repo input out command
  repo="$TMP_ROOT/git-reset-without-marker"
  mkdir -p "$repo" || return 1
  git -C "$repo" init -q || return 1
  command="git -C $repo reset --hard HEAD"
  input="$TMP_ROOT/bash-git-reset-without-marker.json"
  jq --arg cwd "$ROOT" --arg command "$command" \
    '.session_id = "t00-session" | .cwd = $cwd | .tool_input.command = $command' \
    "$FIXTURES/pre-reviewer-bash.json" >"$input"
  out="$TMP_ROOT/bash-git-reset-without-marker.out"

  run_hook "$out" "$ROOT/hooks/validate-bash.sh" "$input" || return 1
  is_pretool_deny "$out" &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "git reset denied"
}

test_validate_bash_consumes_git_reset_marker() {
  local repo marker input out command
  repo="$TMP_ROOT/git-reset-with-marker"
  mkdir -p "$repo" || return 1
  git -C "$repo" init -q || return 1
  command="git -C $repo reset --hard HEAD"
  marker="$repo/.git-reset-approved-once"
  {
    printf 'date: 2026-05-17\n'
    printf 'reason: hook test\n'
    printf 'command: %s\n' "$command"
  } >"$marker"
  input="$TMP_ROOT/bash-git-reset-with-marker.json"
  jq --arg cwd "$ROOT" --arg command "$command" \
    '.session_id = "t00-session" | .cwd = $cwd | .tool_input.command = $command' \
    "$FIXTURES/pre-reviewer-bash.json" >"$input"
  out="$TMP_ROOT/bash-git-reset-with-marker.out"

  run_hook "$out" "$ROOT/hooks/validate-bash.sh" "$input" || return 1
  expect_no_output "$out" &&
    [ ! -e "$marker" ]
}

test_validate_bash_blocks_git_reset_marker_mismatch() {
  local repo marker input out command
  repo="$TMP_ROOT/git-reset-marker-mismatch"
  mkdir -p "$repo" || return 1
  git -C "$repo" init -q || return 1
  command="git -C $repo reset --hard HEAD"
  marker="$repo/.git-reset-approved-once"
  {
    printf 'date: 2026-05-17\n'
    printf 'reason: hook test\n'
    printf 'command: git -C %s reset --soft HEAD~1\n' "$repo"
  } >"$marker"
  input="$TMP_ROOT/bash-git-reset-marker-mismatch.json"
  jq --arg cwd "$ROOT" --arg command "$command" \
    '.session_id = "t00-session" | .cwd = $cwd | .tool_input.command = $command' \
    "$FIXTURES/pre-reviewer-bash.json" >"$input"
  out="$TMP_ROOT/bash-git-reset-marker-mismatch.out"

  run_hook "$out" "$ROOT/hooks/validate-bash.sh" "$input" || return 1
  is_pretool_deny "$out" &&
    [ -e "$marker" ] &&
    json_field_contains "$out" '.hookSpecificOutput.permissionDecisionReason // empty' "does not match"
}

test_validate_bash_allows_redirect_to_vendor_path() {
  local out
  out="$TMP_ROOT/bash-vendor-redirect.out"
  run_hook "$out" "$ROOT/hooks/validate-bash.sh" "$FIXTURES/validate-bash-vendor-redirect.json" || return 1
  expect_no_output "$out"
}

test_validate_bash_allows_in_place_imports_path() {
  local out
  out="$TMP_ROOT/bash-imports-sed.out"
  run_hook "$out" "$ROOT/hooks/validate-bash.sh" "$FIXTURES/validate-bash-imports-sed.json" || return 1
  expect_no_output "$out"
}

test_validate_bash_allows_vendor_test_with_tmp_redirect() {
  local out
  out="$TMP_ROOT/bash-vendor-go-test.out"
  run_hook "$out" "$ROOT/hooks/validate-bash.sh" "$FIXTURES/validate-bash-vendor-go-test.json" || return 1
  expect_no_output "$out"
}

run_validate_bash_command() {
  local command="$1"
  local tag="$2"
  local input out

  input="$TMP_ROOT/${tag}.json"
  out="$TMP_ROOT/${tag}.out"
  jq --arg cwd "$ROOT" --arg command "$command" \
    '.cwd = $cwd | .tool_input.command = $command' \
    "$FIXTURES/pre-reviewer-bash.json" >"$input" || return 1
  run_hook "$out" "$ROOT/hooks/validate-bash.sh" "$input" || return 1
  printf '%s\n' "$out"
}

is_make_memory_cap_deny() {
  is_pretool_deny "$1" &&
    json_field_contains "$1" '.hookSpecificOutput.permissionDecisionReason // empty' \
      "make must be run with a finite memory cap"
}

test_validate_bash_blocks_direct_make_without_memory_cap() {
  local out
  out="$(run_validate_bash_command "make test" "bash-make-direct")" || return 1
  is_make_memory_cap_deny "$out"
}

test_validate_bash_blocks_env_make_without_memory_cap() {
  local out
  out="$(run_validate_bash_command "env make test" "bash-make-env")" || return 1
  is_make_memory_cap_deny "$out"
}

test_validate_bash_blocks_sudo_make_without_memory_cap() {
  local out
  out="$(run_validate_bash_command "sudo make test" "bash-make-sudo")" || return 1
  is_make_memory_cap_deny "$out"
}

test_validate_bash_blocks_command_make_without_memory_cap() {
  local out
  out="$(run_validate_bash_command "command -- make test" "bash-make-command")" || return 1
  is_make_memory_cap_deny "$out"
}

test_validate_bash_blocks_exec_make_without_memory_cap() {
  local out
  out="$(run_validate_bash_command "exec -- make test" "bash-make-exec")" || return 1
  is_make_memory_cap_deny "$out"
}

test_validate_bash_blocks_time_make_without_memory_cap() {
  local out
  out="$(run_validate_bash_command "time make test" "bash-make-time")" || return 1
  is_make_memory_cap_deny "$out"
}

test_validate_bash_blocks_time_format_make_without_memory_cap() {
  local out
  out="$(run_validate_bash_command \
    "/usr/bin/time -f '%M' make test" \
    "bash-make-time-format")" || return 1
  is_make_memory_cap_deny "$out"
}

test_validate_bash_blocks_nice_make_without_memory_cap() {
  local out
  out="$(run_validate_bash_command "nice make test" "bash-make-nice")" || return 1
  is_make_memory_cap_deny "$out"
}

test_validate_bash_blocks_timeout_make_without_memory_cap() {
  local out
  out="$(run_validate_bash_command "timeout 30s make test" "bash-make-timeout")" || return 1
  is_make_memory_cap_deny "$out"
}

test_validate_bash_blocks_bash_c_make_without_memory_cap() {
  local out
  out="$(run_validate_bash_command "bash -c 'make test'" "bash-make-bash-c")" || return 1
  is_make_memory_cap_deny "$out"
}

test_validate_bash_blocks_bash_lc_make_without_memory_cap() {
  local out
  out="$(run_validate_bash_command "bash -lc 'make test'" "bash-make-bash-lc")" || return 1
  is_make_memory_cap_deny "$out"
}

test_validate_bash_blocks_sh_c_make_without_memory_cap() {
  local out
  out="$(run_validate_bash_command "sh -c 'make test'" "bash-make-sh-c")" || return 1
  is_make_memory_cap_deny "$out"
}

test_validate_bash_blocks_xargs_make_without_memory_cap() {
  local out
  out="$(run_validate_bash_command "printf test | xargs make" "bash-make-xargs")" || return 1
  is_make_memory_cap_deny "$out"
}

test_validate_bash_blocks_find_exec_make_without_memory_cap() {
  local out
  out="$(run_validate_bash_command \
    "find . -maxdepth 0 -exec make test \\;" \
    "bash-make-find-exec")" || return 1
  is_make_memory_cap_deny "$out"
}

test_validate_bash_allows_systemd_run_property_capped_make() {
  local out
  out="$(run_validate_bash_command \
    "systemd-run --scope --property=MemoryMax=1G make test" \
    "bash-make-systemd-property")" || return 1
  expect_no_output "$out"
}

test_validate_bash_allows_systemd_run_short_property_capped_make() {
  local out
  out="$(run_validate_bash_command \
    "systemd-run --scope -p MemoryMax=1G make test" \
    "bash-make-systemd-short-property")" || return 1
  expect_no_output "$out"
}

test_validate_bash_allows_systemd_run_unit_capped_make() {
  local out
  out="$(run_validate_bash_command \
    "systemd-run --scope -u build -p MemoryMax=1G make test" \
    "bash-make-systemd-unit-capped")" || return 1
  expect_no_output "$out"
}

test_validate_bash_allows_prlimit_as_capped_make() {
  local out
  out="$(run_validate_bash_command \
    "prlimit --as=1073741824 make test" \
    "bash-make-prlimit-as")" || return 1
  expect_no_output "$out"
}

test_validate_bash_allows_prlimit_attached_v_capped_make() {
  local out
  out="$(run_validate_bash_command \
    "prlimit -v1048576 make test" \
    "bash-make-prlimit-v")" || return 1
  expect_no_output "$out"
}

test_validate_bash_blocks_systemd_run_without_memorymax_for_make() {
  local out
  out="$(run_validate_bash_command \
    "systemd-run --scope make test" \
    "bash-make-systemd-uncapped")" || return 1
  is_make_memory_cap_deny "$out"
}

test_validate_bash_blocks_systemd_run_unit_without_memorymax_for_make() {
  local out
  out="$(run_validate_bash_command \
    "systemd-run --scope -u build make test" \
    "bash-make-systemd-unit-uncapped")" || return 1
  is_make_memory_cap_deny "$out"
}

test_validate_bash_blocks_systemd_run_memoryhigh_for_make() {
  local out
  out="$(run_validate_bash_command \
    "systemd-run --scope -p MemoryHigh=1G make test" \
    "bash-make-systemd-memoryhigh")" || return 1
  is_make_memory_cap_deny "$out"
}

test_validate_bash_blocks_prlimit_unlimited_cap_for_make() {
  local out
  out="$(run_validate_bash_command \
    "prlimit --as=unlimited make test" \
    "bash-make-prlimit-unlimited")" || return 1
  is_make_memory_cap_deny "$out"
}

test_validate_bash_allows_non_make_command_with_make_substring() {
  local out
  out="$(run_validate_bash_command "cmake --version" "bash-make-substring")" || return 1
  expect_no_output "$out"
}

test_validate_bash_allows_printf_make_word() {
  local out
  out="$(run_validate_bash_command "printf make" "bash-make-printf-word")" || return 1
  expect_no_output "$out"
}

test_validate_bash_allows_echo_make_word() {
  local out
  out="$(run_validate_bash_command "echo make" "bash-make-echo-word")" || return 1
  expect_no_output "$out"
}

test_validate_bash_allows_command_v_make_lookup() {
  local out
  out="$(run_validate_bash_command "command -v make" "bash-make-command-v")" || return 1
  expect_no_output "$out"
}

test_validate_bash_allows_find_name_make_print() {
  local out
  out="$(run_validate_bash_command \
    "find . -name make -print" \
    "bash-make-find-name-print")" || return 1
  expect_no_output "$out"
}

test_validate_bash_allows_xargs_echo_make_word() {
  local out
  out="$(run_validate_bash_command \
    "printf make | xargs echo" \
    "bash-make-xargs-echo-word")" || return 1
  expect_no_output "$out"
}

test_validate_bash_allows_dynamic_fragment_scope_boundary() {
  local out
  out="$(run_validate_bash_command "ma\$'ke' test" "bash-make-dynamic-boundary")" || return 1
  expect_no_output "$out"
}

test_validate_bash_denied_make_does_not_mark_activity() {
  local proof_root input out touched_count
  proof_root="$(fresh_proof_root bash-denied-make-no-activity)"
  input="$TMP_ROOT/bash-denied-make-no-activity.json"
  out="$TMP_ROOT/bash-denied-make-no-activity.out"
  jq --arg cwd "$ROOT" \
    '.session_id = "t00-session" | .cwd = $cwd | .tool_input.command = "make test"' \
    "$FIXTURES/pre-reviewer-bash.json" >"$input" || return 1

  run_hook "$out" "$ROOT/hooks/validate-bash.sh" "$input" CODEX_PROOF_ROOT="$proof_root" || return 1
  touched_count="$(find "$proof_root/touched-repos/sessions/t00-session" -type f 2>/dev/null | wc -l)"

  is_make_memory_cap_deny "$out" &&
    [ ! -e "$proof_root/activity/sessions/t00-session/shell" ] &&
    [ "$touched_count" -eq 0 ]
}

test_validate_apply_patch_marks_edit_activity() {
  local proof_root input out
  proof_root="$(fresh_proof_root activity-apply-patch)"
  input="$TMP_ROOT/activity-apply-patch.json"
  jq --arg cwd "$ROOT" '.session_id = "t00-session" | .cwd = $cwd' "$FIXTURES/eci-apply-patch-markdown.json" >"$input"
  out="$TMP_ROOT/activity-apply-patch.out"

  run_hook "$out" "$ROOT/hooks/validate-apply-patch.sh" "$input" CODEX_PROOF_ROOT="$proof_root" || return 1
  expect_no_output "$out" &&
    [ -s "$proof_root/activity/sessions/t00-session/edit" ]
}

test_validate_edit_write_marks_edit_activity() {
  local proof_root input out
  proof_root="$(fresh_proof_root activity-edit-write)"
  input="$TMP_ROOT/activity-edit-write.json"
  jq --arg cwd "$ROOT" '.session_id = "t00-session" | .cwd = $cwd' "$FIXTURES/validate-edit-write-allow-unrelated-edit.json" >"$input"
  out="$TMP_ROOT/activity-edit-write.out"

  run_hook "$out" "$ROOT/hooks/validate-edit-write.sh" "$input" CODEX_PROOF_ROOT="$proof_root" || return 1
  expect_no_output "$out" &&
    [ -s "$proof_root/activity/sessions/t00-session/edit" ]
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

test_stop_gate_continues_clean_inactive_turn() {
  local proof_root input out repo
  proof_root="$(fresh_proof_root stop-clean-inactive)"
  repo="$(make_git_repo stop-clean-inactive)" || return 1
  input="$TMP_ROOT/stop-clean-inactive.json"
  with_cwd_path "$FIXTURES/stop-basic.json" "$input" "$repo"
  out="$TMP_ROOT/stop-clean-inactive.out"

  run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$input" CODEX_PROOF_ROOT="$proof_root" || return 1
  json_field_equals "$out" '.continue // false' "true" &&
    [ ! -e "$proof_root/t00-session/instructions.md" ] &&
    [ ! -e "$proof_root/t00-session/proof.md" ]
}

test_stop_gate_blocks_activity_marker() {
  local proof_root input out repo
  proof_root="$(fresh_proof_root stop-activity-marker)"
  repo="$(make_git_repo stop-activity-marker)" || return 1
  mkdir -p "$proof_root/activity/sessions/t00-session"
  printf 'created_utc: 2026-05-04T00:00:00Z\n' >"$proof_root/activity/sessions/t00-session/shell"
  input="$TMP_ROOT/stop-activity-marker.json"
  with_cwd_path "$FIXTURES/stop-basic.json" "$input" "$repo"
  out="$TMP_ROOT/stop-activity-marker.out"

  run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$input" CODEX_PROOF_ROOT="$proof_root" || return 1
  is_stop_block "$out" &&
    json_field_contains "$out" '.reason // empty' "Automated stop checks passed" &&
    json_field_not_contains "$out" '.reason // empty' "write " &&
    [ -s "$proof_root/t00-session/instructions.md" ] &&
    grep -q "Git state: clean" "$proof_root/t00-session/instructions.md" &&
    grep -q "Do not rerun automated git checks" "$proof_root/t00-session/instructions.md"
}

test_stop_gate_blocks_parent_subagent_tool_call() {
  local proof_root input out transcript repo
  proof_root="$(fresh_proof_root stop-parent-subagent-tool)"
  repo="$(make_git_repo stop-parent-subagent-tool)" || return 1
  transcript="$TMP_ROOT/home/.codex/sessions/codex-hooks-test-main-subagent-tool.jsonl"
  write_main_transcript_with_subagent_call "$transcript" || return 1
  input="$TMP_ROOT/stop-parent-subagent-tool.json"
  jq --arg cwd "$repo" --arg transcript "$transcript" '.cwd = $cwd | .transcript_path = $transcript' "$FIXTURES/stop-basic.json" >"$input"
  out="$TMP_ROOT/stop-parent-subagent-tool.out"

  run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$input" HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" || return 1
  is_stop_block "$out" &&
    json_field_contains "$out" '.reason // empty' "Automated stop checks passed" &&
    json_field_not_contains "$out" '.reason // empty' "write " &&
    [ -s "$proof_root/t00-session/instructions.md" ] &&
    grep -q "Git state: clean" "$proof_root/t00-session/instructions.md" &&
    grep -q "Do not rerun automated git checks" "$proof_root/t00-session/instructions.md"
}

test_stop_gate_reports_automated_git_checks_for_dirty_state() {
  local proof_root input out repo
  proof_root="$(fresh_proof_root stop-dirty-automated-checks)"
  repo="$(make_git_repo stop-dirty-automated-checks)" || return 1
  printf 'dirty\n' >>"$repo/file.txt"
  input="$TMP_ROOT/stop-dirty-automated-checks.json"
  with_cwd_path "$FIXTURES/stop-basic.json" "$input" "$repo"
  out="$TMP_ROOT/stop-dirty-automated-checks.out"

  run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$input" CODEX_PROOF_ROOT="$proof_root" || return 1
  is_stop_block "$out" &&
    json_field_contains "$out" '.reason // empty' "Automated stop checks found changed git state" &&
    [ -s "$proof_root/t00-session/instructions.md" ] &&
    grep -q "Dirty worktree:  M file.txt" "$proof_root/t00-session/instructions.md" &&
    grep -q "HEAD: " "$proof_root/t00-session/instructions.md" &&
    grep -q "Do not rerun automated git checks" "$proof_root/t00-session/instructions.md"
}

test_stop_gate_reports_automated_git_checks_for_committed_state() {
  local proof_root input out repo base
  proof_root="$(fresh_proof_root stop-committed-automated-checks)"
  repo="$(make_git_repo stop-committed-automated-checks)" || return 1
  mkdir -p "$proof_root/t00-session"
  base="$(git -C "$repo" rev-parse HEAD)" || return 1
  printf '%s\n' "$base" >"$proof_root/t00-session/baseline_head"
  printf 'committed\n' >>"$repo/file.txt"
  git -C "$repo" add file.txt || return 1
  git -C "$repo" commit -qm "committed change" || return 1
  input="$TMP_ROOT/stop-committed-automated-checks.json"
  with_cwd_path "$FIXTURES/stop-basic.json" "$input" "$repo"
  out="$TMP_ROOT/stop-committed-automated-checks.out"

  run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$input" CODEX_PROOF_ROOT="$proof_root" || return 1
  is_stop_block "$out" &&
    json_field_contains "$out" '.reason // empty' "Automated stop checks found changed git state" &&
    [ -s "$proof_root/t00-session/instructions.md" ] &&
    grep -q "Dirty worktree: clean" "$proof_root/t00-session/instructions.md" &&
    grep -q "HEAD: .*committed change" "$proof_root/t00-session/instructions.md" &&
    grep -q "commits changed since baseline" "$proof_root/t00-session/instructions.md" &&
    grep -q "Do not rerun automated git checks" "$proof_root/t00-session/instructions.md"
}

test_stop_gate_reports_automated_secret_scan_pass() {
  local proof_root input out repo bin_dir
  proof_root="$(fresh_proof_root stop-secret-scan-pass)"
  repo="$(make_git_repo stop-secret-scan-pass)" || return 1
  bin_dir="$(make_fake_gitleaks stop-secret-scan-pass)" || return 1
  printf 'ordinary change\n' >>"$repo/file.txt"
  input="$TMP_ROOT/stop-secret-scan-pass.json"
  with_cwd_path "$FIXTURES/stop-basic.json" "$input" "$repo"
  out="$TMP_ROOT/stop-secret-scan-pass.out"

  PATH="$bin_dir:$PATH" run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$input" \
    CODEX_PROOF_ROOT="$proof_root" || return 1
  is_stop_block "$out" &&
    json_field_contains "$out" '.reason // empty' "Automated stop checks found changed git state" &&
    [ -s "$proof_root/t00-session/instructions.md" ] &&
    grep -q "Secret scan: passed (gitleaks)" "$proof_root/t00-session/instructions.md" &&
    [ ! -e "$proof_root/t00-session/gitleaks-findings.txt" ]
}

test_stop_gate_blocks_gitleaks_findings_from_dirty_state() {
  local proof_root input out repo bin_dir
  proof_root="$(fresh_proof_root stop-secret-scan-dirty)"
  repo="$(make_git_repo stop-secret-scan-dirty)" || return 1
  bin_dir="$(make_fake_gitleaks stop-secret-scan-dirty)" || return 1
  printf 'FAKE_SECRET\n' >>"$repo/file.txt"
  input="$TMP_ROOT/stop-secret-scan-dirty.json"
  with_cwd_path "$FIXTURES/stop-basic.json" "$input" "$repo"
  out="$TMP_ROOT/stop-secret-scan-dirty.out"

  PATH="$bin_dir:$PATH" run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$input" \
    CODEX_PROOF_ROOT="$proof_root" || return 1
  is_stop_block "$out" &&
    json_field_contains "$out" '.reason // empty' "Automated secret scan found possible secrets" &&
    [ -s "$proof_root/t00-session/gitleaks-report.json" ] &&
    [ -s "$proof_root/t00-session/gitleaks-findings.txt" ] &&
    grep -q "file.txt:2 fake-secret Fake secret" "$proof_root/t00-session/gitleaks-findings.txt"
}

test_stop_gate_blocks_gitleaks_findings_from_untracked_state() {
  local proof_root input out repo bin_dir
  proof_root="$(fresh_proof_root stop-secret-scan-untracked)"
  repo="$(make_git_repo stop-secret-scan-untracked)" || return 1
  bin_dir="$(make_fake_gitleaks stop-secret-scan-untracked)" || return 1
  printf 'FAKE_SECRET\n' >"$repo/new.txt"
  input="$TMP_ROOT/stop-secret-scan-untracked.json"
  with_cwd_path "$FIXTURES/stop-basic.json" "$input" "$repo"
  out="$TMP_ROOT/stop-secret-scan-untracked.out"

  PATH="$bin_dir:$PATH" run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$input" \
    CODEX_PROOF_ROOT="$proof_root" || return 1
  is_stop_block "$out" &&
    json_field_contains "$out" '.reason // empty' "Automated secret scan found possible secrets" &&
    [ -s "$proof_root/t00-session/gitleaks-report.json" ] &&
    [ -s "$proof_root/t00-session/gitleaks-findings.txt" ]
}

test_stop_gate_blocks_gitleaks_findings_from_committed_state() {
  local proof_root input out repo bin_dir base
  proof_root="$(fresh_proof_root stop-secret-scan-committed)"
  repo="$(make_git_repo stop-secret-scan-committed)" || return 1
  bin_dir="$(make_fake_gitleaks stop-secret-scan-committed)" || return 1
  mkdir -p "$proof_root/t00-session"
  base="$(git -C "$repo" rev-parse HEAD)" || return 1
  printf '%s\n' "$base" >"$proof_root/t00-session/baseline_head"
  printf 'FAKE_SECRET\n' >>"$repo/file.txt"
  git -C "$repo" add file.txt || return 1
  git -C "$repo" commit -qm "secret" || return 1
  input="$TMP_ROOT/stop-secret-scan-committed.json"
  with_cwd_path "$FIXTURES/stop-basic.json" "$input" "$repo"
  out="$TMP_ROOT/stop-secret-scan-committed.out"

  PATH="$bin_dir:$PATH" run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$input" \
    CODEX_PROOF_ROOT="$proof_root" || return 1
  is_stop_block "$out" &&
    json_field_contains "$out" '.reason // empty' "Automated secret scan found possible secrets" &&
    [ -s "$proof_root/t00-session/gitleaks-report.json" ] &&
    [ -s "$proof_root/t00-session/gitleaks-findings.txt" ]
}

test_stop_gate_blocks_gitleaks_execution_failure() {
  local proof_root input out repo bin_dir
  proof_root="$(fresh_proof_root stop-secret-scan-error)"
  repo="$(make_git_repo stop-secret-scan-error)" || return 1
  bin_dir="$(make_fake_gitleaks stop-secret-scan-error)" || return 1
  printf 'ordinary change\n' >>"$repo/file.txt"
  input="$TMP_ROOT/stop-secret-scan-error.json"
  with_cwd_path "$FIXTURES/stop-basic.json" "$input" "$repo"
  out="$TMP_ROOT/stop-secret-scan-error.out"

  PATH="$bin_dir:$PATH" run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$input" \
    CODEX_PROOF_ROOT="$proof_root" FAKE_GITLEAKS_MODE=error || return 1
  is_stop_block "$out" &&
    json_field_contains "$out" '.reason // empty' "Automated secret scan could not complete" &&
    [ -s "$proof_root/t00-session/gitleaks-findings.txt" ] &&
    grep -q "scanner exploded" "$proof_root/t00-session/gitleaks-findings.txt"
}

test_stop_gate_blocks_ate_active_state() {
  local proof_root input out repo
  proof_root="$(fresh_proof_root stop-ate-active)"
  repo="$(make_git_repo stop-ate-active)" || return 1
  mkdir -p "$proof_root/ate/sessions/t00-session"
  printf 'phase: execution\n' >"$proof_root/ate/sessions/t00-session/ate_active"
  input="$TMP_ROOT/stop-ate-active.json"
  with_cwd_path "$FIXTURES/stop-basic.json" "$input" "$repo"
  out="$TMP_ROOT/stop-ate-active.out"

  run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$input" CODEX_PROOF_ROOT="$proof_root" || return 1
  is_stop_block "$out" &&
    json_field_contains "$out" '.reason // empty' "ATE is active"
}

test_stop_gate_allows_ate_awaiting_user_without_other_activity() {
  local proof_root input out repo
  proof_root="$(fresh_proof_root stop-ate-awaiting-user)"
  repo="$(make_git_repo stop-ate-awaiting-user)" || return 1
  mkdir -p "$proof_root/ate/sessions/t00-session"
  printf 'phase: awaiting_user\n' >"$proof_root/ate/sessions/t00-session/ate_active"
  input="$TMP_ROOT/stop-ate-awaiting-user.json"
  with_cwd_path "$FIXTURES/stop-basic.json" "$input" "$repo"
  out="$TMP_ROOT/stop-ate-awaiting-user.out"

  run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$input" CODEX_PROOF_ROOT="$proof_root" || return 1
  json_field_equals "$out" '.continue // false' "true"
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
    [ ! -e "$proof_root/t00-session/summary-to-print.md" ] &&
    [ ! -e "$proof_root/t00-session/proof.md" ]
}

test_stop_gate_accepts_proof_clears_active_work_markers() {
  local proof_root input out repo
  proof_root="$(fresh_proof_root stop-complete-clears-active)"
  repo="$(make_git_repo stop-complete-clears-active)" || return 1
  mkdir -p "$proof_root/t00-session" \
    "$proof_root/activity/sessions/t00-session" \
    "$proof_root/active-task/sessions/t00-session"
  cp "$FIXTURES/proof-complete.md" "$proof_root/t00-session/proof.md"
  printf 'created_utc: 2026-05-04T00:00:00Z\n' >"$proof_root/activity/sessions/t00-session/shell"
  printf 'created_utc: 2026-05-04T00:00:00Z\n' >"$proof_root/active-task/sessions/t00-session/task_active"
  input="$TMP_ROOT/stop-complete-clears-active.json"
  with_cwd_path "$FIXTURES/stop-basic.json" "$input" "$repo"
  out="$TMP_ROOT/stop-complete-clears-active.out"

  run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$input" CODEX_PROOF_ROOT="$proof_root" || return 1
  is_stop_block "$out" &&
    json_field_contains "$out" '.reason // empty' "Verification proof accepted" &&
    [ ! -e "$proof_root/t00-session/summary-to-print.md" ] &&
    [ ! -e "$proof_root/activity/sessions/t00-session/shell" ] &&
    [ ! -e "$proof_root/active-task/sessions/t00-session/task_active" ]
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
    [ ! -e "$proof_root/t00-session/summary-to-print.md" ] &&
    [ -s "$proof_root/t00-session/git-status-at-accept.txt" ] &&
    grep -q ' M file.txt' "$proof_root/t00-session/git-status-at-accept.txt"
}

test_stop_gate_accepts_proof_after_baseline_commit_without_dirty_state() {
  local proof_root input out repo base
  proof_root="$(fresh_proof_root stop-proof-baseline-commit-clean)"
  mkdir -p "$proof_root/t00-session"
  cp "$FIXTURES/proof-complete.md" "$proof_root/t00-session/proof.md"
  repo="$(make_git_repo stop-proof-baseline-commit-clean)" || return 1
  base="$(git -C "$repo" rev-parse HEAD)" || return 1
  printf '%s\n' "$base" >"$proof_root/t00-session/baseline_head"
  printf 'committed\n' >>"$repo/file.txt"
  git -C "$repo" add file.txt || return 1
  git -C "$repo" commit -qm "committed change" || return 1
  input="$TMP_ROOT/stop-proof-baseline-commit-clean.json"
  with_cwd_path "$FIXTURES/stop-basic.json" "$input" "$repo"
  out="$TMP_ROOT/stop-proof-baseline-commit-clean.out"

  run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$input" CODEX_PROOF_ROOT="$proof_root" || return 1
  is_stop_block "$out" &&
    json_field_contains "$out" '.reason // empty' "Verification proof accepted" &&
    json_field_not_contains "$out" '.reason // empty' "git state is still dirty" &&
    [ ! -e "$proof_root/t00-session/git-status-at-accept.txt" ]
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
  mkdir -p "$proof_root/activity/sessions/t00-session"
  printf 'created_utc: 2026-05-04T00:00:00Z\n' >"$proof_root/activity/sessions/t00-session/shell"
  input="$TMP_ROOT/stop-loop-reminder.json"
  with_cwd_fixture "$FIXTURES/stop-basic.json" "$input"
  out="$TMP_ROOT/stop-loop-reminder.out"

  for i in 1 2 3 4 5; do
    run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$input" CODEX_PROOF_ROOT="$proof_root" || return 1
  done

  is_stop_block "$out" &&
    json_field_contains "$out" '.reason // empty' "LOOP DETECTED" &&
    json_field_contains "$out" '.reason // empty' "read instructions or stop-checklist" &&
    json_field_contains "$out" '.reason // empty' "stop again" &&
    json_field_contains "$out" '.reason // empty' "identify failing step" &&
    json_field_contains "$out" '.reason // empty' "do not retry same approach"
}

test_stop_gate_ignores_cwd_eci_state() {
  local proof_root input out cwd_dir repo
  proof_root="$(fresh_proof_root stop-cwd-eci)"
  repo="$(make_git_repo stop-cwd-eci)" || return 1
  cwd_dir="$(CODEX_PROOF_ROOT="$proof_root" bash -c '. "$0/hooks/lib/codex-proof-state.sh"; codex_ensure_cwd_state_dir eci "$1"' "$ROOT" "$repo")" || return 1
  printf 'scope: stale cwd state\n' >"$cwd_dir/eci_active"

  input="$TMP_ROOT/stop-cwd-eci.json"
  with_cwd_path "$FIXTURES/stop-basic.json" "$input" "$repo"
  out="$TMP_ROOT/stop-cwd-eci.out"

  run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$input" CODEX_PROOF_ROOT="$proof_root" || return 1
  json_field_equals "$out" '.continue // false' "true"
}

test_stop_gate_ignores_cwd_eci_state_without_cwd_field() {
  local proof_root input out cwd_dir repo
  proof_root="$(fresh_proof_root stop-cwd-eci-no-cwd)"
  repo="$(make_git_repo stop-cwd-eci-no-cwd)" || return 1
  cwd_dir="$(CODEX_PROOF_ROOT="$proof_root" bash -c '. "$0/hooks/lib/codex-proof-state.sh"; codex_ensure_cwd_state_dir eci "$1"' "$ROOT" "$repo")" || return 1
  printf 'scope: stale cwd state\n' >"$cwd_dir/eci_active"

  input="$TMP_ROOT/stop-cwd-eci-no-cwd.json"
  jq 'del(.cwd)' "$FIXTURES/stop-basic.json" >"$input"
  out="$TMP_ROOT/stop-cwd-eci-no-cwd.out"

  (
    cd "$repo" || exit 1
    env -u CODEX_ROLE CODEX_PROOF_ROOT="$proof_root" bash "$ROOT/hooks/stop-gate.sh" \
      <"$input" >"$out" 2>"$out.err"
  ) || return 1
  json_field_equals "$out" '.continue // false' "true"
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
    json_field_contains "$out" '.reason // empty' "ECI is active" &&
    json_field_contains "$out" '.reason // empty' "$proof_root/t00-session/eci_active"
}

test_stop_gate_blocks_transcriptless_session_eci_state() {
  local proof_root input out
  proof_root="$(fresh_proof_root stop-transcriptless-session-eci)"
  mkdir -p "$proof_root/t00-session" || return 1
  printf 'scope: transcriptless test\n' >"$proof_root/t00-session/eci_active"

  input="$TMP_ROOT/stop-transcriptless-session-eci.json"
  jq '.transcript_path = null' "$FIXTURES/stop-basic.json" >"$input"
  out="$TMP_ROOT/stop-transcriptless-session-eci.out"

  run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$input" CODEX_PROOF_ROOT="$proof_root" || return 1
  is_stop_block "$out" &&
    json_field_contains "$out" '.reason // empty' "ECI is active" &&
    json_field_contains "$out" '.reason // empty' "$proof_root/t00-session/eci_active"
}

test_stop_gate_blocks_session_eci_before_skip_marker() {
  local proof_root input out
  proof_root="$(fresh_proof_root stop-session-eci-before-skip)"
  mkdir -p "$proof_root/t00-session" "$proof_root/skip-stop/sessions/t00-session" || return 1
  printf 'scope: skip test\n' >"$proof_root/t00-session/eci_active"
  printf 'created_utc: now\n' >"$proof_root/skip-stop/sessions/t00-session/skip_stop"

  input="$TMP_ROOT/stop-session-eci-before-skip.json"
  with_cwd_fixture "$FIXTURES/stop-basic.json" "$input"
  out="$TMP_ROOT/stop-session-eci-before-skip.out"

  run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$input" CODEX_PROOF_ROOT="$proof_root" || return 1
  is_stop_block "$out" &&
    json_field_contains "$out" '.reason // empty' "ECI is active" &&
    json_field_contains "$out" '.reason // empty' "$proof_root/t00-session/eci_active"
}

test_stop_gate_blocks_legacy_reserved_eci_marker_same_cwd() {
  local proof_root input out
  proof_root="$(fresh_proof_root stop-legacy-reserved-eci)"
  mkdir -p "$proof_root/pre-reviewer" || return 1
  {
    printf 'scope: legacy test\n'
    printf 'cwd: %s\n' "$ROOT"
    printf 'session_id: pre-reviewer\n'
  } >"$proof_root/pre-reviewer/eci_active"

  input="$TMP_ROOT/stop-legacy-reserved-eci.json"
  with_cwd_fixture "$FIXTURES/stop-basic.json" "$input"
  out="$TMP_ROOT/stop-legacy-reserved-eci.out"

  run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$input" CODEX_PROOF_ROOT="$proof_root" || return 1
  is_stop_block "$out" &&
    json_field_contains "$out" '.reason // empty' "ECI is active" &&
    json_field_contains "$out" '.reason // empty' "$proof_root/pre-reviewer/eci_active"
}

test_stop_gate_ignores_legacy_reserved_eci_marker_other_cwd() {
  local proof_root input out repo
  proof_root="$(fresh_proof_root stop-legacy-reserved-eci-other-cwd)"
  repo="$(make_git_repo stop-legacy-reserved-eci-other-cwd)" || return 1
  mkdir -p "$proof_root/pre-reviewer" || return 1
  {
    printf 'scope: legacy test\n'
    printf 'cwd: %s\n' "$TMP_ROOT/other-cwd"
    printf 'session_id: pre-reviewer\n'
  } >"$proof_root/pre-reviewer/eci_active"

  input="$TMP_ROOT/stop-legacy-reserved-eci-other-cwd.json"
  with_cwd_path "$FIXTURES/stop-basic.json" "$input" "$repo"
  out="$TMP_ROOT/stop-legacy-reserved-eci-other-cwd.out"

  run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$input" CODEX_PROOF_ROOT="$proof_root" || return 1
  json_field_equals "$out" '.continue // false' "true"
}

test_stop_gate_skips_invalid_session_before_legacy_eci_state() {
  local proof_root input out
  proof_root="$(fresh_proof_root stop-invalid-session-legacy-eci)"
  mkdir -p "$proof_root/pre-reviewer" || return 1
  {
    printf 'scope: legacy invalid-session test\n'
    printf 'cwd: %s\n' "$ROOT"
    printf 'session_id: pre-reviewer\n'
  } >"$proof_root/pre-reviewer/eci_active"

  input="$TMP_ROOT/stop-invalid-session-legacy-eci.json"
  jq --arg cwd "$ROOT" '.session_id = "../bad" | .cwd = $cwd' "$FIXTURES/stop-basic.json" >"$input"
  out="$TMP_ROOT/stop-invalid-session-legacy-eci.out"

  run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$input" CODEX_PROOF_ROOT="$proof_root" || return 1
  json_field_equals "$out" '.continue // false' "true" &&
    [ ! -e "$proof_root/../bad/stop_timestamps" ]
}

test_stop_gate_matches_eci_marker_decision_table() {
  local valid subagent own parent legacy name proof_root sid transcript input out expected repo

  for valid in true false; do
    for subagent in true false; do
      for own in true false; do
        for parent in true false; do
          for legacy in true false; do
            name="stop-eci-table-v${valid}-s${subagent}-o${own}-p${parent}-l${legacy}"
            proof_root="$(fresh_proof_root "$name")" || return 1
            repo="$(make_git_repo "$name")" || return 1
            sid="t00-session"
            [ "$valid" = true ] || sid="../bad"

            if [ "$own" = true ]; then
              mkdir -p "$proof_root/t00-session" || return 1
              printf 'scope: table own session\n' >"$proof_root/t00-session/eci_active"
            fi

            if [ "$parent" = true ]; then
              mkdir -p "$proof_root/t00-parent" "$proof_root/side-stop/sessions/t00-session" || return 1
              printf 'scope: table parent session\n' >"$proof_root/t00-parent/eci_active"
              {
                printf 'command: /side\n'
                printf 'parent_session_id: t00-parent\n'
              } >"$proof_root/side-stop/sessions/t00-session/side_stop"
            fi

            if [ "$legacy" = true ]; then
              mkdir -p "$proof_root/pre-reviewer" || return 1
              {
                printf 'scope: table legacy\n'
                printf 'cwd: %s\n' "$repo"
                printf 'session_id: pre-reviewer\n'
              } >"$proof_root/pre-reviewer/eci_active"
            fi

            transcript="$TMP_ROOT/home/.codex/sessions/$name.jsonl"
            if [ "$subagent" = true ]; then
              write_subagent_transcript "$transcript" || return 1
            else
              write_main_transcript "$transcript" || return 1
            fi

            input="$TMP_ROOT/$name.json"
            jq --arg sid "$sid" --arg cwd "$repo" --arg transcript "$transcript" \
              '.session_id = $sid | .cwd = $cwd | .transcript_path = $transcript' \
              "$FIXTURES/stop-basic.json" >"$input"
            out="$TMP_ROOT/$name.out"

            expected=none
            if [ "$valid" = true ]; then
              if [ "$own" = true ]; then
                expected=session
              elif [ "$subagent" = true ]; then
                expected=none
              elif [ "$parent" = true ]; then
                expected=parent
              elif [ "$legacy" = true ]; then
                expected=legacy
              fi
            fi

            run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$input" \
              HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" || return 1

            case "$expected" in
              none)
                json_field_equals "$out" '.continue // false' "true" || {
                  printf '%s\n' "$name expected continue" >&2
                  cat "$out" >&2
                  return 1
                }
                ;;
              session)
                is_stop_block "$out" &&
                  json_field_contains "$out" '.reason // empty' "$proof_root/t00-session/eci_active" || {
                    printf '%s\n' "$name expected session marker block" >&2
                    cat "$out" >&2
                    return 1
                  }
                ;;
              parent)
                is_stop_block "$out" &&
                  json_field_contains "$out" '.reason // empty' "$proof_root/t00-parent/eci_active" || {
                    printf '%s\n' "$name expected parent marker block" >&2
                    cat "$out" >&2
                    return 1
                  }
                ;;
              legacy)
                is_stop_block "$out" &&
                  json_field_contains "$out" '.reason // empty' "$proof_root/pre-reviewer/eci_active" || {
                    printf '%s\n' "$name expected legacy marker block" >&2
                    cat "$out" >&2
                    return 1
                  }
                ;;
              *) return 1 ;;
            esac
          done
        done
      done
    done
  done
}

test_stop_gate_blocks_codex_role_spoof_with_eci_state() {
  local proof_root input out
  proof_root="$(fresh_proof_root stop-role-spoof)"
  out="$TMP_ROOT/stop-role-spoof-eci-active.out"
  CODEX_SESSION_ID=t00-session CODEX_PROOF_ROOT="$proof_root" "$ROOT/bin/eci-active" on "test scope" >"$out" 2>"$out.err" || return 1

  input="$TMP_ROOT/stop-role-spoof.json"
  with_cwd_fixture "$FIXTURES/stop-basic.json" "$input"
  out="$TMP_ROOT/stop-role-spoof.out"

  run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$input" CODEX_PROOF_ROOT="$proof_root" CODEX_ROLE=explorer || return 1
  is_stop_block "$out" &&
    json_field_contains "$out" '.reason // empty' "ECI is active"
}

test_stop_gate_blocks_spawned_agent_transcript_with_own_eci_state() {
  local proof_root input out transcript
  proof_root="$(fresh_proof_root stop-subagent-transcript)"
  out="$TMP_ROOT/stop-subagent-transcript-eci-active.out"
  CODEX_SESSION_ID=t00-session CODEX_PROOF_ROOT="$proof_root" "$ROOT/bin/eci-active" on "test scope" >"$out" 2>"$out.err" || return 1

  transcript="$(subagent_transcript_path)"
  write_subagent_transcript "$transcript" || return 1
  input="$TMP_ROOT/stop-subagent-transcript.json"
  jq --arg cwd "$ROOT" --arg transcript "$transcript" '.cwd = $cwd | .transcript_path = $transcript' "$FIXTURES/stop-basic.json" >"$input"
  out="$TMP_ROOT/stop-subagent-transcript.out"

  run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$input" HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" || return 1
  is_stop_block "$out" &&
    json_field_contains "$out" '.reason // empty' "ECI is active" &&
    [ -e "$proof_root/t00-session/eci_active" ]
}

test_stop_gate_allows_spawned_agent_transcript_with_legacy_parent_eci_state() {
  local proof_root input out transcript
  proof_root="$(fresh_proof_root stop-subagent-legacy-parent-eci)"
  mkdir -p "$proof_root/pre-reviewer" || return 1
  {
    printf 'scope: legacy parent test\n'
    printf 'cwd: %s\n' "$ROOT"
    printf 'session_id: pre-reviewer\n'
  } >"$proof_root/pre-reviewer/eci_active"

  transcript="$(subagent_transcript_path)"
  write_subagent_transcript "$transcript" || return 1
  input="$TMP_ROOT/stop-subagent-legacy-parent-eci.json"
  jq --arg cwd "$ROOT" --arg transcript "$transcript" \
    '.cwd = $cwd | .transcript_path = $transcript' "$FIXTURES/stop-basic.json" >"$input"
  out="$TMP_ROOT/stop-subagent-legacy-parent-eci.out"

  run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$input" HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" || return 1
  json_field_equals "$out" '.continue // false' "true"
}

test_stop_gate_allows_spawned_agent_transcript_when_input_session_is_parent_eci() {
  local proof_root input out transcript
  proof_root="$(fresh_proof_root stop-subagent-input-parent-eci)"
  CODEX_SESSION_ID=parent-session CODEX_PROOF_ROOT="$proof_root" "$ROOT/bin/eci-active" on "parent ECI" >"$TMP_ROOT/stop-subagent-input-parent-eci-on.out" 2>"$TMP_ROOT/stop-subagent-input-parent-eci-on.err" || return 1

  transcript="$(subagent_transcript_path)"
  write_subagent_transcript "$transcript" || return 1
  input="$TMP_ROOT/stop-subagent-input-parent-eci.json"
  jq --arg cwd "$ROOT" --arg transcript "$transcript" \
    '.session_id = "parent-session" | .cwd = $cwd | .transcript_path = $transcript' \
    "$FIXTURES/stop-basic.json" >"$input"
  out="$TMP_ROOT/stop-subagent-input-parent-eci.out"

  run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$input" HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" || return 1
  json_field_equals "$out" '.continue // false' "true"
}

test_stop_gate_blocks_subagent_touched_repo_changes() {
  local proof_root repo transcript touch_input stop_input out marker_count reminder
  proof_root="$(fresh_proof_root stop-subagent-touched-change)"
  repo="$(make_git_repo stop-subagent-touched-change)" || return 1
  transcript="$(subagent_transcript_path)"
  write_subagent_transcript "$transcript" || return 1

  touch_input="$TMP_ROOT/subagent-touch-apply-patch.json"
  jq --arg cwd "$repo" --arg transcript "$transcript" \
    '.session_id = "t00-session" | .cwd = $cwd | .transcript_path = $transcript |
     .tool_input.patch = "*** Begin Patch\n*** Update File: file.txt\n@@\n-base\n+base\n+touched\n*** End Patch\n"' \
    "$FIXTURES/validate-apply-patch-unrelated.json" >"$touch_input"
  out="$TMP_ROOT/subagent-touch-apply-patch.out"
  run_hook "$out" "$ROOT/hooks/validate-apply-patch.sh" "$touch_input" \
    HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" || return 1
  expect_no_output "$out" || return 1

  printf 'touched\n' >>"$repo/file.txt"
  stop_input="$TMP_ROOT/stop-subagent-touched-change.json"
  jq --arg cwd "$repo" --arg transcript "$transcript" \
    '.session_id = "t00-session" | .cwd = $cwd | .transcript_path = $transcript' \
    "$FIXTURES/stop-basic.json" >"$stop_input"
  out="$TMP_ROOT/stop-subagent-touched-change.out"

  run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$stop_input" \
    HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" || return 1
  marker_count="$(find "$proof_root/touched-repos/sessions/t00-session" -type f 2>/dev/null | wc -l)"
  reminder="$proof_root/t00-session/subagent-commit-reminder.md"
  is_stop_block "$out" &&
    [ "$marker_count" -eq 1 ] &&
    [ -s "$reminder" ] &&
    json_field_contains "$out" '.reason // empty' "commit only owned completed dirty paths" &&
    json_field_contains "$out" '.reason // empty' "skip-stop on" &&
    grep -q "Do not commit unrelated dirty files" "$reminder" &&
    grep -q "CODEX_SESSION_ID=t00-session ~/.codex/bin/skip-stop on" "$reminder" &&
    grep -q "file.txt" "$reminder"
}

test_stop_gate_ignores_subagent_unrelated_dirty_file() {
  local proof_root repo transcript touch_input stop_input out marker_count
  proof_root="$(fresh_proof_root stop-subagent-unrelated-dirty)"
  repo="$(make_git_repo stop-subagent-unrelated-dirty)" || return 1
  printf 'other\n' >"$repo/other.txt"
  git -C "$repo" add other.txt || return 1
  git -C "$repo" commit -qm "add other file" || return 1
  transcript="$(subagent_transcript_path)"
  write_subagent_transcript "$transcript" || return 1

  touch_input="$TMP_ROOT/subagent-unrelated-dirty-apply-patch.json"
  jq --arg cwd "$repo" --arg transcript "$transcript" \
    '.session_id = "t00-session" | .cwd = $cwd | .transcript_path = $transcript |
     .tool_input.patch = "*** Begin Patch\n*** Update File: file.txt\n@@\n-base\n+base\n+touched\n*** End Patch\n"' \
    "$FIXTURES/validate-apply-patch-unrelated.json" >"$touch_input"
  out="$TMP_ROOT/subagent-unrelated-dirty-apply-patch.out"
  run_hook "$out" "$ROOT/hooks/validate-apply-patch.sh" "$touch_input" \
    HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" || return 1
  expect_no_output "$out" || return 1
  marker_count="$(find "$proof_root/touched-repos/sessions/t00-session" -type f 2>/dev/null | wc -l)"
  [ "$marker_count" -eq 1 ] || return 1

  printf 'dirty\n' >>"$repo/other.txt"
  stop_input="$TMP_ROOT/stop-subagent-unrelated-dirty.json"
  jq --arg cwd "$repo" --arg transcript "$transcript" \
    '.session_id = "t00-session" | .cwd = $cwd | .transcript_path = $transcript' \
    "$FIXTURES/stop-basic.json" >"$stop_input"
  out="$TMP_ROOT/stop-subagent-unrelated-dirty.out"

  run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$stop_input" \
    HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" || return 1
  json_field_equals "$out" '.continue // false' "true" &&
    [ ! -e "$proof_root/t00-session/subagent-commit-reminder.md" ]
}

test_stop_gate_ignores_subagent_preexisting_dirty_at_first_touch() {
  local proof_root repo transcript touch_input stop_input out marker_count
  proof_root="$(fresh_proof_root stop-subagent-preexisting-dirty)"
  repo="$(make_git_repo stop-subagent-preexisting-dirty)" || return 1
  transcript="$(subagent_transcript_path)"
  write_subagent_transcript "$transcript" || return 1
  printf 'preexisting\n' >>"$repo/file.txt"

  touch_input="$TMP_ROOT/subagent-preexisting-apply-patch.json"
  jq --arg cwd "$repo" --arg transcript "$transcript" \
    '.session_id = "t00-session" | .cwd = $cwd | .transcript_path = $transcript |
     .tool_input.patch = "*** Begin Patch\n*** Update File: .\n@@\n-base\n+base\n+touched\n*** End Patch\n"' \
    "$FIXTURES/validate-apply-patch-unrelated.json" >"$touch_input"
  out="$TMP_ROOT/subagent-preexisting-apply-patch.out"
  run_hook "$out" "$ROOT/hooks/validate-apply-patch.sh" "$touch_input" \
    HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" || return 1
  expect_no_output "$out" || return 1
  marker_count="$(find "$proof_root/touched-repos/sessions/t00-session" -type f 2>/dev/null | wc -l)"
  [ "$marker_count" -eq 1 ] || return 1

  stop_input="$TMP_ROOT/stop-subagent-preexisting-dirty.json"
  jq --arg cwd "$repo" --arg transcript "$transcript" \
    '.session_id = "t00-session" | .cwd = $cwd | .transcript_path = $transcript' \
    "$FIXTURES/stop-basic.json" >"$stop_input"
  out="$TMP_ROOT/stop-subagent-preexisting-dirty.out"

  run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$stop_input" \
    HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" || return 1
  json_field_equals "$out" '.continue // false' "true" &&
    [ ! -e "$proof_root/t00-session/subagent-commit-reminder.md" ]
}

test_stop_gate_allows_subagent_skip_marker() {
  local proof_root repo transcript touch_input stop_input out marker_count
  proof_root="$(fresh_proof_root stop-subagent-skip-marker)"
  repo="$(make_git_repo stop-subagent-skip-marker)" || return 1
  transcript="$(subagent_transcript_path)"
  write_subagent_transcript "$transcript" || return 1

  touch_input="$TMP_ROOT/subagent-skip-marker-apply-patch.json"
  jq --arg cwd "$repo" --arg transcript "$transcript" \
    '.session_id = "t00-session" | .cwd = $cwd | .transcript_path = $transcript |
     .tool_input.patch = "*** Begin Patch\n*** Update File: file.txt\n@@\n-base\n+base\n+touched\n*** End Patch\n"' \
    "$FIXTURES/validate-apply-patch-unrelated.json" >"$touch_input"
  out="$TMP_ROOT/subagent-skip-marker-apply-patch.out"
  run_hook "$out" "$ROOT/hooks/validate-apply-patch.sh" "$touch_input" \
    HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" || return 1
  expect_no_output "$out" || return 1
  marker_count="$(find "$proof_root/touched-repos/sessions/t00-session" -type f 2>/dev/null | wc -l)"
  [ "$marker_count" -eq 1 ] || return 1

  printf 'dirty\n' >>"$repo/file.txt"
  CODEX_SESSION_ID=t00-session CODEX_PROOF_ROOT="$proof_root" "$ROOT/bin/skip-stop" on \
    >"$TMP_ROOT/subagent-skip-marker-on.out" 2>&1 || return 1

  stop_input="$TMP_ROOT/stop-subagent-skip-marker.json"
  jq --arg cwd "$repo" --arg transcript "$transcript" \
    '.session_id = "t00-session" | .cwd = $cwd | .transcript_path = $transcript' \
    "$FIXTURES/stop-basic.json" >"$stop_input"
  out="$TMP_ROOT/stop-subagent-skip-marker.out"

  run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$stop_input" \
    HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" || return 1
  json_field_equals "$out" '.continue // false' "true" &&
    [ ! -e "$proof_root/t00-session/subagent-commit-reminder.md" ]
}

test_stop_gate_allows_subagent_committed_clean_repo() {
  local proof_root repo transcript touch_input stop_input out marker_count
  proof_root="$(fresh_proof_root stop-subagent-committed-clean)"
  repo="$(make_git_repo stop-subagent-committed-clean)" || return 1
  transcript="$(subagent_transcript_path)"
  write_subagent_transcript "$transcript" || return 1

  touch_input="$TMP_ROOT/subagent-committed-clean-apply-patch.json"
  jq --arg cwd "$repo" --arg transcript "$transcript" \
    '.session_id = "t00-session" | .cwd = $cwd | .transcript_path = $transcript |
     .tool_input.patch = "*** Begin Patch\n*** Update File: file.txt\n@@\n-base\n+base\n+committed\n*** End Patch\n"' \
    "$FIXTURES/validate-apply-patch-unrelated.json" >"$touch_input"
  out="$TMP_ROOT/subagent-committed-clean-apply-patch.out"
  run_hook "$out" "$ROOT/hooks/validate-apply-patch.sh" "$touch_input" \
    HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" || return 1
  expect_no_output "$out" || return 1
  marker_count="$(find "$proof_root/touched-repos/sessions/t00-session" -type f 2>/dev/null | wc -l)"
  [ "$marker_count" -eq 1 ] || return 1

  printf 'committed\n' >>"$repo/file.txt"
  git -C "$repo" add file.txt || return 1
  git -C "$repo" commit -qm "subagent committed change" || return 1
  stop_input="$TMP_ROOT/stop-subagent-committed-clean.json"
  jq --arg cwd "$repo" --arg transcript "$transcript" \
    '.session_id = "t00-session" | .cwd = $cwd | .transcript_path = $transcript' \
    "$FIXTURES/stop-basic.json" >"$stop_input"
  out="$TMP_ROOT/stop-subagent-committed-clean.out"

  run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$stop_input" \
    HOME="$TMP_ROOT/home" CODEX_PROOF_ROOT="$proof_root" || return 1
  json_field_equals "$out" '.continue // false' "true" &&
    [ ! -e "$proof_root/t00-session/subagent-commit-reminder.md" ]
}

test_stop_gate_blocks_main_transcript_with_eci_state() {
  local proof_root input out transcript
  proof_root="$(fresh_proof_root stop-main-transcript)"
  out="$TMP_ROOT/stop-main-transcript-eci-active.out"
  CODEX_SESSION_ID=t00-session CODEX_PROOF_ROOT="$proof_root" "$ROOT/bin/eci-active" on "test scope" >"$out" 2>"$out.err" || return 1

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

write_user_closed_eci_report() {
  local report="$1"

  cat >"$report" <<'EOF'
## ECI completion certificate

user-closed: fixture user confirmed scope closure.

## Stop checklist walkthrough

- Fixture stop checklist item was reviewed.

## Incomplete compliance

- None.
EOF
}

write_mixed_eci_report() {
  local report="$1"

  cat >"$report" <<'EOF'
## ECI completion certificate

clean-pass: fixture ECI completion proof.
hard-escalation: retired marker must keep ECI active.

## Stop checklist walkthrough

- Fixture stop checklist item was reviewed.

## Incomplete compliance

- None.
EOF
}

test_stop_gate_rejects_hard_escalation_eci_proof() {
  local proof_root input out
  proof_root="$(fresh_proof_root stop-hard-eci-proof)"
  install_proof_fixture "$proof_root" "$FIXTURES/hard-eci-proof-complete.md" || return 1

  input="$TMP_ROOT/stop-hard-eci-proof.json"
  with_cwd_fixture "$FIXTURES/stop-basic.json" "$input"
  out="$TMP_ROOT/stop-hard-eci-proof.out"

  run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$input" CODEX_PROOF_ROOT="$proof_root" || return 1
  is_stop_block "$out" &&
    json_field_contains "$out" '.reason // empty' "clean-pass: or user-closed:" &&
    [ -s "$proof_root/t00-session/proof.md" ] &&
    [ ! -e "$proof_root/t00-session/summary-to-print.md" ]
}

test_stop_gate_accepts_user_closed_eci_proof() {
  local proof_root input out
  proof_root="$(fresh_proof_root stop-user-closed-eci-proof)"
  mkdir -p "$proof_root/t00-session" || return 1
  write_user_closed_eci_report "$proof_root/t00-session/proof.md" || return 1

  input="$TMP_ROOT/stop-user-closed-eci-proof.json"
  with_cwd_fixture "$FIXTURES/stop-basic.json" "$input"
  out="$TMP_ROOT/stop-user-closed-eci-proof.out"

  run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$input" CODEX_PROOF_ROOT="$proof_root" || return 1
  is_stop_block "$out" &&
    json_field_contains "$out" '.reason // empty' "Verification proof accepted" &&
    [ ! -e "$proof_root/t00-session/summary-to-print.md" ] &&
    [ ! -e "$proof_root/t00-session/proof.md" ]
}

test_stop_gate_rejects_mixed_hard_escalation_eci_proof() {
  local proof_root input out
  proof_root="$(fresh_proof_root stop-mixed-hard-eci-proof)"
  mkdir -p "$proof_root/t00-session" || return 1
  write_mixed_eci_report "$proof_root/t00-session/proof.md" || return 1

  input="$TMP_ROOT/stop-mixed-hard-eci-proof.json"
  with_cwd_fixture "$FIXTURES/stop-basic.json" "$input"
  out="$TMP_ROOT/stop-mixed-hard-eci-proof.out"

  run_hook "$out" "$ROOT/hooks/stop-gate.sh" "$input" CODEX_PROOF_ROOT="$proof_root" || return 1
  is_stop_block "$out" &&
    json_field_contains "$out" '.reason // empty' "hard-escalation:" &&
    [ -s "$proof_root/t00-session/proof.md" ] &&
    [ ! -e "$proof_root/t00-session/summary-to-print.md" ]
}

test_eci_active_off_rejects_hard_escalation_report() {
  local proof_root out marker status
  proof_root="$(fresh_proof_root eci-off-hard-escalation)"
  CODEX_SESSION_ID=t00-session CODEX_PROOF_ROOT="$proof_root" "$ROOT/bin/eci-active" on "test scope" >"$TMP_ROOT/eci-off-hard-on.out" 2>&1 || return 1
  marker="$proof_root/t00-session/eci_active"
  [ -s "$marker" ] || return 1

  out="$TMP_ROOT/eci-off-hard.out"
  CODEX_SESSION_ID=t00-session CODEX_PROOF_ROOT="$proof_root" "$ROOT/bin/eci-active" off "$FIXTURES/hard-eci-proof-complete.md" >"$out" 2>"$out.err"
  status=$?

  [ "$status" -ne 0 ] &&
    [ -s "$marker" ] &&
    [ ! -e "$proof_root/t00-session/proof.md" ] &&
    grep -q "clean-pass: or user-closed:" "$out.err"
}

test_eci_active_off_accepts_user_closed_report() {
  local proof_root out report marker
  proof_root="$(fresh_proof_root eci-off-user-closed)"
  CODEX_SESSION_ID=t00-session CODEX_PROOF_ROOT="$proof_root" "$ROOT/bin/eci-active" on "test scope" >"$TMP_ROOT/eci-off-user-closed-on.out" 2>&1 || return 1
  report="$TMP_ROOT/eci-off-user-closed.md"
  write_user_closed_eci_report "$report" || return 1
  marker="$proof_root/t00-session/eci_active"
  [ -s "$marker" ] || return 1

  out="$TMP_ROOT/eci-off-user-closed.out"
  CODEX_SESSION_ID=t00-session CODEX_PROOF_ROOT="$proof_root" "$ROOT/bin/eci-active" off "$report" >"$out" 2>"$out.err" || return 1

  [ ! -e "$marker" ] &&
    [ ! -e "$proof_root/t00-session/proof.md" ] &&
    grep -q "ECI inactive" "$out"
}

test_eci_active_off_rejects_mixed_hard_escalation_report() {
  local proof_root out marker report status
  proof_root="$(fresh_proof_root eci-off-mixed-hard)"
  CODEX_SESSION_ID=t00-session CODEX_PROOF_ROOT="$proof_root" "$ROOT/bin/eci-active" on "test scope" >"$TMP_ROOT/eci-off-mixed-hard-on.out" 2>&1 || return 1
  report="$TMP_ROOT/eci-off-mixed-hard.md"
  write_mixed_eci_report "$report" || return 1
  marker="$proof_root/t00-session/eci_active"
  [ -s "$marker" ] || return 1

  out="$TMP_ROOT/eci-off-mixed-hard.out"
  CODEX_SESSION_ID=t00-session CODEX_PROOF_ROOT="$proof_root" "$ROOT/bin/eci-active" off "$report" >"$out" 2>"$out.err"
  status=$?

  [ "$status" -ne 0 ] &&
    [ -s "$marker" ] &&
    [ ! -e "$proof_root/t00-session/proof.md" ] &&
    grep -q "hard-escalation:" "$out.err"
}

test_eci_active_status_uses_legacy_reserved_marker_same_cwd() {
  local proof_root out
  proof_root="$(fresh_proof_root eci-status-legacy-reserved)"
  mkdir -p "$proof_root/pre-reviewer" || return 1
  {
    printf 'scope: legacy status\n'
    printf 'cwd: %s\n' "$ROOT"
    printf 'session_id: pre-reviewer\n'
  } >"$proof_root/pre-reviewer/eci_active"
  out="$TMP_ROOT/eci-status-legacy-reserved.out"

  env -u CODEX_SESSION_ID CODEX_THREAD_ID=t00-session CODEX_PROOF_ROOT="$proof_root" \
    "$ROOT/bin/eci-active" status >"$out" 2>"$out.err" || return 1

  grep -q "scope: legacy status" "$out" &&
    grep -q "session_id: pre-reviewer" "$out"
}

test_eci_active_off_removes_legacy_reserved_marker_same_cwd() {
  local proof_root out
  proof_root="$(fresh_proof_root eci-off-legacy-reserved)"
  mkdir -p "$proof_root/pre-reviewer" || return 1
  {
    printf 'scope: legacy off\n'
    printf 'cwd: %s\n' "$ROOT"
    printf 'session_id: pre-reviewer\n'
  } >"$proof_root/pre-reviewer/eci_active"
  out="$TMP_ROOT/eci-off-legacy-reserved.out"

  env -u CODEX_SESSION_ID CODEX_THREAD_ID=t00-session CODEX_PROOF_ROOT="$proof_root" \
    "$ROOT/bin/eci-active" off "$FIXTURES/eci-proof-complete.md" >"$out" 2>"$out.err" || return 1

  [ ! -e "$proof_root/pre-reviewer/eci_active" ] &&
    grep -q "ECI inactive" "$out"
}

test_eci_active_on_uses_newest_session_without_session_id() {
  local proof_root out status count
  proof_root="$(fresh_proof_root eci-on-newest-session)"
  mkdir -p "$proof_root/019df400-0000-7000-8000-000000000001" \
    "$proof_root/019df400-0000-7000-8000-000000000002"
  touch -t 202001010000 "$proof_root/019df400-0000-7000-8000-000000000001"
  touch -t 202101010000 "$proof_root/019df400-0000-7000-8000-000000000002"
  out="$TMP_ROOT/eci-active-newest-session.out"

  env -u CODEX_SESSION_ID -u CODEX_THREAD_ID CODEX_PROOF_ROOT="$proof_root" \
    "$ROOT/bin/eci-active" on "test scope" >"$out" 2>"$out.err"
  status=$?
  count=$(find "$proof_root/eci/cwd" -mindepth 2 -maxdepth 2 -name eci_active 2>/dev/null | wc -l)

  [ "$status" -eq 0 ] &&
    [ ! -e "$proof_root/019df400-0000-7000-8000-000000000001/eci_active" ] &&
    [ -e "$proof_root/019df400-0000-7000-8000-000000000002/eci_active" ] &&
    [ "$count" -eq 0 ] &&
    grep -q "ECI active: $proof_root/019df400-0000-7000-8000-000000000002/eci_active" "$out"
}

test_eci_active_on_prefers_thread_id_without_session_id() {
  local proof_root out status
  proof_root="$(fresh_proof_root eci-on-thread-id)"
  mkdir -p "$proof_root/019df400-0000-7000-8000-000000000001" \
    "$proof_root/019df400-0000-7000-8000-000000000002"
  touch -t 202001010000 "$proof_root/019df400-0000-7000-8000-000000000001"
  touch -t 202101010000 "$proof_root/019df400-0000-7000-8000-000000000002"
  out="$TMP_ROOT/eci-active-thread-id.out"

  env -u CODEX_SESSION_ID CODEX_THREAD_ID=019df400-0000-7000-8000-000000000001 CODEX_PROOF_ROOT="$proof_root" \
    "$ROOT/bin/eci-active" on "test scope" >"$out" 2>"$out.err"
  status=$?

  [ "$status" -eq 0 ] &&
    [ -e "$proof_root/019df400-0000-7000-8000-000000000001/eci_active" ] &&
    [ ! -e "$proof_root/019df400-0000-7000-8000-000000000002/eci_active" ] &&
    grep -q "ECI active: $proof_root/019df400-0000-7000-8000-000000000001/eci_active" "$out"
}

test_eci_active_on_ignores_reserved_dirs_without_session_id() {
  local proof_root out status
  proof_root="$(fresh_proof_root eci-on-ignore-reserved)"
  mkdir -p "$proof_root/pre-reviewer" "$proof_root/reviewer" \
    "$proof_root/019df400-0000-7000-8000-000000000001"
  touch -t 202001010000 "$proof_root/019df400-0000-7000-8000-000000000001"
  touch -t 202201010000 "$proof_root/reviewer"
  touch -t 202301010000 "$proof_root/pre-reviewer"
  out="$TMP_ROOT/eci-active-ignore-reserved.out"

  env -u CODEX_SESSION_ID -u CODEX_THREAD_ID CODEX_PROOF_ROOT="$proof_root" \
    "$ROOT/bin/eci-active" on "test scope" >"$out" 2>"$out.err"
  status=$?

  [ "$status" -eq 0 ] &&
    [ -e "$proof_root/019df400-0000-7000-8000-000000000001/eci_active" ] &&
    [ ! -e "$proof_root/pre-reviewer/eci_active" ] &&
    [ ! -e "$proof_root/reviewer/eci_active" ] &&
    grep -q "ECI active: $proof_root/019df400-0000-7000-8000-000000000001/eci_active" "$out"
}

test_eci_active_off_uses_newest_session_without_session_id() {
  local proof_root out status
  proof_root="$(fresh_proof_root eci-off-newest-session)"
  CODEX_SESSION_ID=t00-session CODEX_PROOF_ROOT="$proof_root" "$ROOT/bin/eci-active" on "test scope" >"$TMP_ROOT/eci-off-requires-session-on.out" 2>&1 || return 1

  out="$TMP_ROOT/eci-off-newest-session.out"
  env -u CODEX_SESSION_ID -u CODEX_THREAD_ID CODEX_PROOF_ROOT="$proof_root" \
    "$ROOT/bin/eci-active" off "$FIXTURES/eci-proof-complete.md" >"$out" 2>"$out.err"
  status=$?

  [ "$status" -eq 0 ] &&
    [ ! -e "$proof_root/t00-session/eci_active" ] &&
    grep -q "ECI inactive" "$out"
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
run_case "prompt state keeps session ECI marker silent" \
  test_prompt_state_keeps_session_eci_marker_silent
run_case "prompt state config is wired without temporary probe" \
  test_prompt_state_config_is_wired_without_probe
run_case "prompt state keeps nontrivial governance task silent" \
  test_prompt_state_keeps_nontrivial_governance_task_silent
run_case "prompt state keeps CODEX typo silent" \
  test_prompt_state_keeps_codex_typo_silent
run_case "prompt state keeps hooks path governance task silent" \
  test_prompt_state_keeps_hooks_path_governance_task_silent
run_case "prompt state leaves React hook prompt silent" \
  test_prompt_state_leaves_react_hook_prompt_silent
run_case "prompt state leaves React app hooks path silent" \
  test_prompt_state_leaves_react_app_hooks_path_silent
run_case "prompt state leaves React src hooks path silent" \
  test_prompt_state_leaves_react_src_hooks_path_silent
run_case "prompt state leaves Express routing prompt silent" \
  test_prompt_state_leaves_express_routing_prompt_silent
run_case "prompt state leaves email rule prompt silent" \
  test_prompt_state_leaves_email_rule_prompt_silent
run_case "prompt state keeps system prompt task silent" \
  test_prompt_state_keeps_system_prompt_task_silent
run_case "prompt state keeps subagent Stop-hook prompt task silent" \
  test_prompt_state_keeps_subagent_stop_hook_prompt_task_silent
run_case "prompt state keeps Stop-hook prompt task silent" \
  test_prompt_state_keeps_stop_hook_prompt_task_silent
run_case "prompt state keeps CODEX.md review task silent" \
  test_prompt_state_keeps_codex_review_task_silent
run_case "prompt state keeps hook behavior audit task silent" \
  test_prompt_state_keeps_hook_behavior_audit_task_silent
run_case "prompt state keeps hook tests task silent" \
  test_prompt_state_keeps_hook_tests_task_silent
run_case "prompt state keeps task routing task silent" \
  test_prompt_state_keeps_task_routing_task_silent
run_case "prompt state keeps agent routing protocol task silent" \
  test_prompt_state_keeps_agent_routing_protocol_task_silent
run_case "prompt state keeps nontrivial tasks use ECI question silent" \
  test_prompt_state_keeps_nontrivial_tasks_use_eci_question_silent
run_case "prompt state keeps ensure nontrivial tasks use ECI silent" \
  test_prompt_state_keeps_ensure_nontrivial_tasks_use_eci_silent
run_case "prompt state keeps route nontrivial tasks to ECI silent" \
  test_prompt_state_keeps_route_nontrivial_tasks_to_eci_silent
run_case "prompt state keeps routing nontrivial tasks use ECI silent" \
  test_prompt_state_keeps_routing_nontrivial_tasks_use_eci_silent
run_case "prompt state keeps ECI routing nontrivial tasks silent" \
  test_prompt_state_keeps_eci_routing_nontrivial_tasks_silent
run_case "prompt state keeps make nontrivial tasks use ECI silent" \
  test_prompt_state_keeps_make_nontrivial_tasks_use_eci_silent
run_case "prompt state keeps caveman switch task silent" \
  test_prompt_state_keeps_caveman_switch_task_silent
run_case "prompt state keeps plain stop gate task silent" \
  test_prompt_state_keeps_plain_stop_gate_task_silent
run_case "prompt state keeps hyphen stop gate task silent" \
  test_prompt_state_keeps_hyphen_stop_gate_task_silent
run_case "prompt state keeps stop gate script task silent" \
  test_prompt_state_keeps_stop_gate_script_task_silent
run_case "prompt state keeps stop checklist path task silent" \
  test_prompt_state_keeps_stop_checklist_path_task_silent
run_case "prompt state keeps stop checklist task silent" \
  test_prompt_state_keeps_stop_checklist_task_silent
run_case "prompt state keeps Codex config task silent" \
  test_prompt_state_keeps_codex_config_task_silent
run_case "prompt state leaves CLI installation instructions silent" \
  test_prompt_state_leaves_cli_installation_instructions_silent
run_case "prompt state leaves onboarding email instructions silent" \
  test_prompt_state_leaves_onboarding_email_instructions_silent
run_case "prompt state leaves React hook behavior prompt silent" \
  test_prompt_state_leaves_react_hook_behavior_prompt_silent
run_case "prompt state leaves React hook behavior audit silent" \
  test_prompt_state_leaves_react_hook_behavior_audit_silent
run_case "prompt state leaves React hook tests silent" \
  test_prompt_state_leaves_react_hook_tests_silent
run_case "prompt state leaves Express routing rule prompt silent" \
  test_prompt_state_leaves_express_routing_rule_prompt_silent
run_case "prompt state leaves Rust config silent" \
  test_prompt_state_leaves_rust_config_silent
run_case "prompt state leaves web app hooks.json silent" \
  test_prompt_state_leaves_web_app_hooks_json_silent
run_case "prompt state leaves caveman story silent" \
  test_prompt_state_leaves_caveman_story_silent
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
run_case "ECI gate skips invalid session id" \
  test_eci_gate_skips_invalid_session_id
run_case "ECI gate message names clean-pass/user-closed teardown" \
  test_eci_gate_message_mentions_clean_pass_user_closed
run_case "ECI gate ignores code apply_patch from cwd marker" \
  test_eci_gate_ignores_code_apply_patch_from_cwd_state
run_case "ECI gate blocks code apply_patch from session marker" \
  test_eci_gate_blocks_code_apply_patch_from_session_state
run_case "ECI gate blocks CODEX_ROLE spoof through marker" \
  test_eci_gate_blocks_codex_role_spoof
run_case "subagent helper rejects oversize first record" \
  test_subagent_helper_rejects_oversize_first_record
run_case "parent helper rejects oversize first record" \
  test_parent_helper_rejects_oversize_first_record
run_case "first-record helpers reject oversize record without final newline" \
  test_first_record_helpers_reject_oversize_without_final_newline
run_case "first-record helpers preserve boundary behavior" \
  test_first_record_helpers_preserve_boundary_behavior
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
run_case "system reviewer skips VCS context when ECI active" \
  test_system_reviewer_skips_vcs_when_eci_active
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
run_case "pre reviewer controller is split, preflighted, and bounded" \
  test_pre_reviewer_controller_is_split_preflighted_and_bounded
run_case "pre reviewer controller matches Lean lifecycle" \
  test_pre_reviewer_controller_matches_lean_lifecycle
run_case "pre reviewer controller mutations are killed" \
  test_pre_reviewer_controller_mutations_are_killed
run_case "pre reviewer identity record mutations are rejected" \
  test_pre_reviewer_identity_record_mutations_are_rejected
run_case "pre reviewer behavioral mutations are rejected" \
  test_pre_reviewer_behavioral_mutations_are_rejected
run_case "pre reviewer gate races are rejected" \
  test_pre_reviewer_gate_races_are_rejected
run_case "pre reviewer formal stamps bind all evidence" \
  test_pre_reviewer_formal_stamps_are_bound
run_case "pre reviewer lifecycle parser is exact" \
  test_pre_reviewer_lifecycle_parser_is_exact
run_case "pre reviewer admission inputs are bounded" \
  test_pre_reviewer_admission_inputs_are_bounded
run_case "pre reviewer formal tmpfs setup is owned" \
  test_pre_reviewer_formal_tmpfs_setup_is_owned
run_case "process watchdog drains its exact owned group" \
  test_process_watchdog_drains_exact_owned_group
run_case "pre reviewer backend timeout is hard" \
  test_pre_reviewer_backend_timeout_is_hard
run_case "pre reviewer timeout behavior is compatible" \
  test_pre_reviewer_timeout_compatibility_probe
run_case "pre reviewer capped capture is complete and bounded" \
  test_pre_reviewer_capped_capture_probe
run_case "pre reviewer profile uses the exact configured pair" \
  test_pre_reviewer_profile_uses_configured_pair
run_case "pre reviewer lock is bounded and fileless" \
  test_pre_reviewer_lock_is_bounded_and_fileless
run_case "pre reviewer lock timeout accepts only zero through one" \
  test_pre_reviewer_lock_timeout_accepts_only_zero_through_one
run_case "pre reviewer lock revalidates after waiting path swap" \
  test_pre_reviewer_lock_revalidates_after_waiting_path_swap
run_case "pre reviewer lock revalidates private mode after waiting" \
  test_pre_reviewer_lock_revalidates_private_mode_after_waiting
run_case "many turns leave no lock files" \
  test_many_turns_leave_no_lock_files
run_case "present-turn pre reviewer skips transcript find" \
  test_pre_reviewer_present_turn_skips_transcript_find
run_case "present-turn pre reviewer uses per-turn capture with first-record scope" \
  test_pre_reviewer_present_turn_uses_per_turn_capture_with_first_record_scope
run_case "distinct prompt captures overlap without overwrite" \
  test_prompt_capture_distinct_turns_overlap_without_overwrite
run_case "prompt cap failure leaves no same-key reusable state" \
  test_prompt_cap_failure_leaves_no_same_key_reusable_state
run_case "turn state pruning is old regular-file and namespace scoped" \
  test_turn_state_pruning_is_old_regular_file_and_namespace_scoped
run_case "turn state pruning rejects shared lock and runs after release" \
  test_turn_state_pruning_rejects_shared_lock_and_runs_after_release
run_case "present-turn pre reviewer with retained state skips pruner" \
  test_present_turn_with_retained_state_skips_pruner
run_case "prompt retained state prunes once without per-file subprocesses" \
  test_prompt_retained_state_prunes_once_without_per_file_subprocesses
run_case "paused prompt pruning does not block concurrent pretool" \
  test_paused_prompt_pruning_does_not_block_concurrent_pretool
run_case "pre reviewer pruning allows concurrent publication" \
  test_pre_reviewer_pruning_allows_concurrent_publication
run_case "Python pre reviewer pruning unit suite" \
  test_prune_pre_reviewer_turn_state_python_unit_suite
run_case "pre reviewer pruning matches Lean namespace spec" \
  test_prune_pre_reviewer_turn_state_matches_lean_spec
run_case "prune differential disables Python bytecode with parent env unset" \
  test_prune_differential_disables_python_bytecode_with_parent_env_unset
run_case "generated FIFO wrappers own blocking release descriptors" \
  test_generated_fifo_wrappers_use_owned_blocking_release_descriptors
run_case "present-turn pre reviewer claim uses hash fallback" \
  test_pre_reviewer_present_turn_claim_uses_hash_fallback
run_case "hash fails open without SHA-256 or Python" \
  test_hash_fails_open_without_sha256_or_python
run_case "present-turn pre reviewer duplicate is silent and first-record scoped" \
  test_pre_reviewer_present_turn_duplicate_is_silent_and_first_record_scoped
run_case "same-turn resubmit remains idempotent after claim" \
  test_same_turn_resubmit_is_idempotent_after_claim
run_case "present-turn capture failure clears stale state without legacy fallback" \
  test_pre_reviewer_present_turn_capture_failure_clears_stale_and_never_falls_back
run_case "present-turn pre reviewer mismatch is silent and first-record scoped" \
  test_pre_reviewer_present_turn_mismatch_is_silent_and_first_record_scoped
run_case "present-turn hash collision fails open without claim" \
  test_pre_reviewer_hash_collision_fails_open_without_claim
run_case "present-turn claim loser does not delete capture" \
  test_pre_reviewer_claim_loser_does_not_delete_capture
run_case "claim creation failure restores consumed capture" \
  test_claim_creation_failure_restores_consumed_capture
run_case "same-key resubmit preserves winner claim" \
  test_same_key_resubmit_preserves_winner_claim
run_case "present-turn claim persists across non-deny outcomes" \
  test_present_turn_claim_persists_across_non_deny_outcomes
run_case "present-turn pre reviewer rejects malformed capture payloads" \
  test_pre_reviewer_present_turn_rejects_malformed_capture_payloads
run_case "present-turn strict capture consumer rejects unsafe inputs" \
  test_present_turn_strict_capture_consumer_rejects_unsafe_inputs
run_case "present-turn strict capture consumer preserves replacement character" \
  test_present_turn_strict_capture_consumer_preserves_valid_replacement_character
run_case "owned 0755 pre reviewer state directory migrates and publishes" \
  test_pre_reviewer_owned_0755_state_directory_migrates_and_publishes
run_case "private pre reviewer state directory skips Python migrator" \
  test_pre_reviewer_private_state_directory_skips_python_migrator
run_case "unavailable pre reviewer migrator fails silently without mutation" \
  test_pre_reviewer_unavailable_migrator_fails_silently_without_mutation
run_case "wrong-owner pre reviewer state fails without mutation or publication" \
  test_pre_reviewer_wrong_owner_fails_without_mutation_or_publication
run_case "pre reviewer rejects unsafe state directories without mutation" \
  test_pre_reviewer_rejects_unsafe_state_directories
run_case "present-turn claim is atomic under concurrency" \
  test_pre_reviewer_present_turn_claim_is_atomic_under_concurrency
run_case "distinct turn ids with the same prompt each review" \
  test_pre_reviewer_distinct_turn_ids_with_same_prompt_each_review
run_case "prompt capture redacts completely before byte cap" \
  test_prompt_capture_redacts_complete_prompt_before_byte_cap
run_case "prompt capture byte cap preserves UTF-8 boundary" \
  test_prompt_capture_byte_cap_preserves_utf8_boundary
run_case "large prompt submission fails open before capture" \
  test_large_prompt_submission_fails_open_before_capture
run_case "prompt capture UTF-8 prefix matches Lean spec" \
  test_prompt_capture_utf8_prefix_matches_lean_spec
run_case "Python UTF-8 prefix cap unit suite" \
  test_utf8_prefix_cap_python_unit_suite
run_case "Python strict turn capture unit suite" \
  test_turn_capture_validator_python_unit_suite
run_case "turn capture validator matches Lean specification" \
  test_turn_capture_validator_matches_lean_spec
run_case "validator child closes turn lock FD while pruner inherits it" \
  test_capture_validator_child_closes_lock_fd_while_pruner_inherits
run_case "Python pre reviewer state directory migration unit suite" \
  test_pre_reviewer_state_dir_migration_python_unit_suite
run_case "hook tests leave no Python bytecode cache" \
  test_hook_tests_leave_no_python_bytecode_cache
run_case "prompt submit without usable turn id preserves per-turn state" \
  test_prompt_submit_without_usable_turn_id_preserves_per_turn_state
run_case "turn id extractor enforces UTF-8 byte bound and canonical JSON" \
  test_turn_id_extractor_enforces_utf8_byte_bound_and_canonical_json
run_case "prompt unusable turn ids skip normal state but preserve side" \
  test_prompt_unusable_turn_ids_skip_normal_state_but_preserve_side
run_case "turn id byte bound applies to prompt and pretool lifecycle" \
  test_turn_id_byte_bound_applies_to_prompt_and_pretool_lifecycle
run_case "unusable turn ids fail open before transcript, state, or backend access" \
  test_pre_reviewer_unusable_turn_ids_fail_open_before_side_effects
run_case "pre reviewer denies first tool call once per turn" \
  test_pre_reviewer_denies_first_tool_call_once_per_turn
run_case "pre reviewer accepts LLM compatibility alias" \
  test_pre_reviewer_llm_alias_enables_fake_deny
run_case "pre reviewer accepts CLAUDE compatibility alias" \
  test_pre_reviewer_claude_alias_enables_fake_deny
run_case "pre reviewer prefers CODEX over malformed lower aliases" \
  test_pre_reviewer_codex_alias_precedence_ignores_malformed_lower_aliases
run_case "pre reviewer prefers LLM over malformed CLAUDE alias" \
  test_pre_reviewer_llm_alias_precedence_ignores_malformed_claude
run_case "pre reviewer malformed CODEX does not fallback to LLM" \
  test_pre_reviewer_malformed_codex_does_not_fallback_to_llm
run_case "pre reviewer malformed LLM does not fallback to CLAUDE" \
  test_pre_reviewer_malformed_llm_does_not_fallback_to_claude
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
run_case "ECI gate denies code NotebookEdit payload" \
  test_eci_gate_denies_code_notebookedit_payload
run_case "ECI gate denies mixed markdown/code apply_patch" \
  test_eci_gate_denies_mixed_markdown_code_patch
run_case "ECI gate blocks MultiEdit JSON stdin when marker exists" \
  test_eci_gate_blocks_multiedit_stdin
run_case "hooks.json edit matcher includes MultiEdit" \
  test_multiedit_hook_config_is_wired
run_case "hooks.json edit matcher includes NotebookEdit" \
  test_notebookedit_hook_config_is_wired
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
run_case "validate-apply-patch blocks vendor paths" \
  test_validate_apply_patch_blocks_vendor_path
run_case "validate-apply-patch blocks imports move destinations" \
  test_validate_apply_patch_blocks_imports_move_destination
run_case "validate-apply-patch allows vendorish paths" \
  test_validate_apply_patch_allows_vendorish_path
run_case "validate-edit-write blocks direct Edit plan paths" \
  test_validate_edit_write_blocks_direct_edit_plan_path
run_case "validate-edit-write blocks direct Write plan paths" \
  test_validate_edit_write_blocks_direct_write_plan_path
run_case "validate-edit-write blocks direct MultiEdit plan paths" \
  test_validate_edit_write_blocks_direct_multiedit_plan_path
run_case "validate-edit-write blocks direct Write imports paths" \
  test_validate_edit_write_blocks_direct_write_imports_path
run_case "validate-edit-write blocks direct MultiEdit vendor paths" \
  test_validate_edit_write_blocks_direct_multiedit_vendor_path
run_case "validate-edit-write allows vendorish paths" \
  test_validate_edit_write_allows_vendorish_path
run_case "validate-edit-write blocks edits inside a git submodule" \
  test_validate_edit_write_blocks_submodule_edit
run_case "validate-edit-write allows edits in a regular non-submodule repo" \
  test_validate_edit_write_allows_regular_repo_edit
run_case "validate-edit-write allows NotebookEdit on own proof dir" \
  test_validate_edit_write_allows_notebookedit_same_sid_proof
run_case "validate-edit-write allows aliased proof dir" \
  test_validate_edit_write_allows_aliased_proof_dir
run_case "validate-edit-write blocks NotebookEdit on another session proof dir" \
  test_validate_edit_write_blocks_notebookedit_other_sid_proof
run_case "validate-apply-patch allows aliased proof dir" \
  test_validate_apply_patch_allows_aliased_proof_dir
run_case "validate-apply-patch blocks edits to another session proof dir" \
  test_validate_apply_patch_blocks_other_sid_proof
run_case "validate-apply-patch blocks UUID proof dir despite alias marker" \
  test_validate_apply_patch_blocks_uuid_sid_despite_alias_marker
run_case "validate-bash allows subagent low-level work" \
  test_validate_bash_allows_subagent_low_level_work
run_case "validate direct/apply blocks subagent ledger paths" \
  test_validate_direct_and_apply_block_subagent_ledger_paths
run_case "validate direct/apply allows main-thread ledger paths" \
  test_validate_direct_and_apply_allow_main_ledger_paths
run_case "validate direct/apply allows subagent non-ledger parent proof paths" \
  test_validate_direct_and_apply_allow_subagent_non_ledger_parent_proof_paths
run_case "validate-bash allows writes into a git submodule" \
  test_validate_bash_allows_write_into_submodule
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
run_case "validate-bash marks shell activity" \
  test_validate_bash_marks_shell_activity
run_case "validate-bash skips read-only shell activity" \
  test_validate_bash_skips_read_only_shell_activity
run_case "validate-bash skips read-only shell chain activity" \
  test_validate_bash_skips_read_only_shell_chain_activity
run_case "validate-bash marks redirected read shell activity" \
  test_validate_bash_marks_redirected_read_shell_activity
run_case "validate-bash blocks subagent eci-active off" \
  test_validate_bash_blocks_subagent_eci_active_off
run_case "validate-bash allows main eci-active off" \
  test_validate_bash_allows_main_eci_active_off
run_case "validate-bash blocks git reset without marker" \
  test_validate_bash_blocks_git_reset_without_marker
run_case "validate-bash consumes git reset marker" \
  test_validate_bash_consumes_git_reset_marker
run_case "validate-bash blocks git reset marker mismatch" \
  test_validate_bash_blocks_git_reset_marker_mismatch
run_case "validate-bash allows redirect to vendor paths" \
  test_validate_bash_allows_redirect_to_vendor_path
run_case "validate-bash allows in-place imports paths" \
  test_validate_bash_allows_in_place_imports_path
run_case "validate-bash allows vendor test with tmp redirect" \
  test_validate_bash_allows_vendor_test_with_tmp_redirect
run_case "validate-bash blocks direct make without memory cap" \
  test_validate_bash_blocks_direct_make_without_memory_cap
run_case "validate-bash blocks env make without memory cap" \
  test_validate_bash_blocks_env_make_without_memory_cap
run_case "validate-bash blocks sudo make without memory cap" \
  test_validate_bash_blocks_sudo_make_without_memory_cap
run_case "validate-bash blocks command make without memory cap" \
  test_validate_bash_blocks_command_make_without_memory_cap
run_case "validate-bash blocks exec make without memory cap" \
  test_validate_bash_blocks_exec_make_without_memory_cap
run_case "validate-bash blocks time make without memory cap" \
  test_validate_bash_blocks_time_make_without_memory_cap
run_case "validate-bash blocks time format make without memory cap" \
  test_validate_bash_blocks_time_format_make_without_memory_cap
run_case "validate-bash blocks nice make without memory cap" \
  test_validate_bash_blocks_nice_make_without_memory_cap
run_case "validate-bash blocks timeout make without memory cap" \
  test_validate_bash_blocks_timeout_make_without_memory_cap
run_case "validate-bash blocks bash -c make without memory cap" \
  test_validate_bash_blocks_bash_c_make_without_memory_cap
run_case "validate-bash blocks bash -lc make without memory cap" \
  test_validate_bash_blocks_bash_lc_make_without_memory_cap
run_case "validate-bash blocks sh -c make without memory cap" \
  test_validate_bash_blocks_sh_c_make_without_memory_cap
run_case "validate-bash blocks xargs make without memory cap" \
  test_validate_bash_blocks_xargs_make_without_memory_cap
run_case "validate-bash blocks find -exec make without memory cap" \
  test_validate_bash_blocks_find_exec_make_without_memory_cap
run_case "validate-bash allows systemd-run property capped make" \
  test_validate_bash_allows_systemd_run_property_capped_make
run_case "validate-bash allows systemd-run short property capped make" \
  test_validate_bash_allows_systemd_run_short_property_capped_make
run_case "validate-bash allows systemd-run unit capped make" \
  test_validate_bash_allows_systemd_run_unit_capped_make
run_case "validate-bash allows prlimit --as capped make" \
  test_validate_bash_allows_prlimit_as_capped_make
run_case "validate-bash allows prlimit attached -v capped make" \
  test_validate_bash_allows_prlimit_attached_v_capped_make
run_case "validate-bash blocks systemd-run without MemoryMax for make" \
  test_validate_bash_blocks_systemd_run_without_memorymax_for_make
run_case "validate-bash blocks systemd-run unit without MemoryMax for make" \
  test_validate_bash_blocks_systemd_run_unit_without_memorymax_for_make
run_case "validate-bash blocks systemd-run MemoryHigh-only for make" \
  test_validate_bash_blocks_systemd_run_memoryhigh_for_make
run_case "validate-bash blocks prlimit unlimited cap for make" \
  test_validate_bash_blocks_prlimit_unlimited_cap_for_make
run_case "validate-bash allows non-make command with make substring" \
  test_validate_bash_allows_non_make_command_with_make_substring
run_case "validate-bash allows printf make word" \
  test_validate_bash_allows_printf_make_word
run_case "validate-bash allows echo make word" \
  test_validate_bash_allows_echo_make_word
run_case "validate-bash allows command -v make lookup" \
  test_validate_bash_allows_command_v_make_lookup
run_case "validate-bash allows find name make print" \
  test_validate_bash_allows_find_name_make_print
run_case "validate-bash allows xargs echo make word" \
  test_validate_bash_allows_xargs_echo_make_word
run_case "validate-bash allows dynamic command-fragment scope boundary" \
  test_validate_bash_allows_dynamic_fragment_scope_boundary
run_case "validate-bash denied make does not mark shell activity or touched repo" \
  test_validate_bash_denied_make_does_not_mark_activity
run_case "validate-apply-patch marks edit activity" \
  test_validate_apply_patch_marks_edit_activity
run_case "validate-edit-write marks edit activity" \
  test_validate_edit_write_marks_edit_activity
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
run_case "stop gate continues clean inactive turn" \
  test_stop_gate_continues_clean_inactive_turn
run_case "stop gate blocks activity marker" \
  test_stop_gate_blocks_activity_marker
run_case "stop gate blocks parent subagent tool call" \
  test_stop_gate_blocks_parent_subagent_tool_call
run_case "stop gate reports automated git checks for dirty state" \
  test_stop_gate_reports_automated_git_checks_for_dirty_state
run_case "stop gate reports automated git checks for committed state" \
  test_stop_gate_reports_automated_git_checks_for_committed_state
run_case "stop gate reports automated secret scan pass" \
  test_stop_gate_reports_automated_secret_scan_pass
run_case "stop gate blocks gitleaks findings from dirty state" \
  test_stop_gate_blocks_gitleaks_findings_from_dirty_state
run_case "stop gate blocks gitleaks findings from untracked state" \
  test_stop_gate_blocks_gitleaks_findings_from_untracked_state
run_case "stop gate blocks gitleaks findings from committed state" \
  test_stop_gate_blocks_gitleaks_findings_from_committed_state
run_case "stop gate blocks gitleaks execution failure" \
  test_stop_gate_blocks_gitleaks_execution_failure
run_case "stop gate blocks ATE active state" \
  test_stop_gate_blocks_ate_active_state
run_case "stop gate allows ATE awaiting user without other activity" \
  test_stop_gate_allows_ate_awaiting_user_without_other_activity
run_case "stop gate accepts complete proof fixture" \
  test_stop_gate_accepts_complete_proof_fixture
run_case "stop gate accepts proof clears active work markers" \
  test_stop_gate_accepts_proof_clears_active_work_markers
run_case "stop gate accepted proof reports dirty git state" \
  test_stop_gate_accepts_proof_reports_dirty_git_state
run_case "stop gate accepts proof after baseline commit without dirty state" \
  test_stop_gate_accepts_proof_after_baseline_commit_without_dirty_state
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
run_case "stop gate ignores cwd-scoped ECI marker" \
  test_stop_gate_ignores_cwd_eci_state
run_case "stop gate ignores cwd-scoped ECI marker without cwd field" \
  test_stop_gate_ignores_cwd_eci_state_without_cwd_field
run_case "stop gate blocks session-scoped ECI marker" \
  test_stop_gate_blocks_session_eci_state
run_case "stop gate blocks transcriptless session-scoped ECI marker" \
  test_stop_gate_blocks_transcriptless_session_eci_state
run_case "stop gate blocks session ECI before skip marker" \
  test_stop_gate_blocks_session_eci_before_skip_marker
run_case "stop gate blocks legacy reserved ECI marker for same cwd" \
  test_stop_gate_blocks_legacy_reserved_eci_marker_same_cwd
run_case "stop gate ignores legacy reserved ECI marker for other cwd" \
  test_stop_gate_ignores_legacy_reserved_eci_marker_other_cwd
run_case "stop gate skips invalid session before legacy ECI state" \
  test_stop_gate_skips_invalid_session_before_legacy_eci_state
run_case "stop gate matches ECI marker decision table" \
  test_stop_gate_matches_eci_marker_decision_table
run_case "stop gate blocks CODEX_ROLE spoof with ECI state" \
  test_stop_gate_blocks_codex_role_spoof_with_eci_state
run_case "stop gate blocks /side when parent ECI is active" \
  test_stop_gate_blocks_side_prompt_with_parent_eci_state
run_case "stop gate blocks /side parent session with ECI state" \
  test_stop_gate_blocks_side_parent_session_with_eci_state
run_case "stop gate blocks ephemeral threads with ECI state" \
  test_stop_gate_blocks_ephemeral_threads_with_eci_state
run_case "stop gate blocks spawned-agent transcript with own ECI state" \
  test_stop_gate_blocks_spawned_agent_transcript_with_own_eci_state
run_case "stop gate allows spawned-agent transcript with legacy parent ECI state" \
  test_stop_gate_allows_spawned_agent_transcript_with_legacy_parent_eci_state
run_case "stop gate allows spawned-agent transcript when input session is parent ECI" \
  test_stop_gate_allows_spawned_agent_transcript_when_input_session_is_parent_eci
run_case "stop gate blocks subagent touched repo changes" \
  test_stop_gate_blocks_subagent_touched_repo_changes
run_case "stop gate ignores subagent unrelated dirty file" \
  test_stop_gate_ignores_subagent_unrelated_dirty_file
run_case "stop gate ignores subagent preexisting dirty at first touch" \
  test_stop_gate_ignores_subagent_preexisting_dirty_at_first_touch
run_case "stop gate allows subagent skip marker" \
  test_stop_gate_allows_subagent_skip_marker
run_case "stop gate allows subagent committed clean repo" \
  test_stop_gate_allows_subagent_committed_clean_repo
run_case "stop gate blocks main transcript with ECI state" \
  test_stop_gate_blocks_main_transcript_with_eci_state
run_case "stop gate allows session-scoped skip marker" \
  test_stop_gate_allows_session_skip_state
run_case "stop gate allows cwd-scoped skip marker" \
  test_stop_gate_allows_cwd_skip_state
run_case "stop gate rejects hard-escalation ECI proof" \
  test_stop_gate_rejects_hard_escalation_eci_proof
run_case "stop gate accepts user-closed ECI proof" \
  test_stop_gate_accepts_user_closed_eci_proof
run_case "stop gate rejects mixed hard-escalation ECI proof" \
  test_stop_gate_rejects_mixed_hard_escalation_eci_proof
run_case "eci-active off rejects hard-escalation report" \
  test_eci_active_off_rejects_hard_escalation_report
run_case "eci-active off accepts user-closed report" \
  test_eci_active_off_accepts_user_closed_report
run_case "eci-active off rejects mixed hard-escalation report" \
  test_eci_active_off_rejects_mixed_hard_escalation_report
run_case "eci-active status uses legacy reserved marker for same cwd" \
  test_eci_active_status_uses_legacy_reserved_marker_same_cwd
run_case "eci-active off removes legacy reserved marker for same cwd" \
  test_eci_active_off_removes_legacy_reserved_marker_same_cwd
run_case "eci-active on uses newest session without CODEX_SESSION_ID" \
  test_eci_active_on_uses_newest_session_without_session_id
run_case "eci-active on prefers CODEX_THREAD_ID without CODEX_SESSION_ID" \
  test_eci_active_on_prefers_thread_id_without_session_id
run_case "eci-active on ignores reserved proof dirs without CODEX_SESSION_ID" \
  test_eci_active_on_ignores_reserved_dirs_without_session_id
run_case "eci-active off uses newest session without CODEX_SESSION_ID" \
  test_eci_active_off_uses_newest_session_without_session_id
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

if [ -f "$profile_audit" ] &&
    [ "$(grep -c '^controller-build$' "$profile_audit")" -eq 1 ]; then
  pass "pre reviewer profile final build audit remains exactly one"
else
  fail "pre reviewer profile final build audit remains exactly one"
fi

note "SUMMARY pass=$PASS_COUNT fail=$FAIL_COUNT xfail=$XFAIL_COUNT xpass=$XPASS_COUNT todo=$TODO_COUNT"

if [ "$FAIL_COUNT" -ne 0 ] || [ "$XPASS_COUNT" -ne 0 ]; then
  exit 1
fi
