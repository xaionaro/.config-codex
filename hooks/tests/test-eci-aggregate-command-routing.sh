#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_ROOT="$(realpath -m -- "$(mktemp -d "${CODEX_TMPDIR:-${HOME:?}/tmp}/codex-eci-aggregate-routing.XXXXXX")")"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

# Exercise a private complete provider copy so this test can validate the
# real PreTool hook without changing the working provider runtime.
sandbox_home="$TMP_ROOT/home"
sandbox_root="$sandbox_home/.codex"
mkdir -p -- "$sandbox_home/tmp" "$sandbox_root"
cp -a -- "$ROOT/hooks.json" "$ROOT/bin" "$ROOT/hooks" "$sandbox_root/"

# Remove a line-2 bypass if present in the private copy. The callback JSON
# must reach the hook body to exercise routing without an early-exit SIGPIPE.
fixture_validate_bash="$sandbox_root/hooks/validate-bash.sh"
sed -i '2{/^exit 0$/d;}' -- "$fixture_validate_bash"

write_full_sandbox_runtime_receipt() {
  local relative source digest mode

  : >"$sandbox_root/.eci-runtime-sync-manifest"
  {
    printf '%s\n' hooks.json
    printf '%s\n' bin/eci-active
    printf '%s\n' bin/eci-active-dispatch
    printf '%s\n' bin/eci-runtime-sync
    [ -f "$sandbox_root/bin/eci-command-gate-mode" ] && printf '%s\n' bin/eci-command-gate-mode
    find "$sandbox_root/hooks" -type f ! -path "$sandbox_root/hooks/tests/*" \
      ! -path '*/__pycache__/*' ! -name '*.pyc' ! -name '*.pyo' -printf 'hooks/%P\n'
  } | LC_ALL=C sort -u | while IFS= read -r relative; do
    [ -n "$relative" ] || continue
    source="$sandbox_root/$relative"
    digest="$(sha256sum -- "$source" | awk '{print $1}')"
    mode="$(stat -c '%a' -- "$source")"
    printf '%s\t%s\t%s\n' "$relative" "$digest" "$mode" >>"$sandbox_root/.eci-runtime-sync-manifest"
  done
  chmod 600 -- "$sandbox_root/.eci-runtime-sync-manifest"
}

write_full_sandbox_runtime_receipt

xdg_config="$TMP_ROOT/config"
xdg_state="$TMP_ROOT/state"
mkdir -p -- "$xdg_config/eci" "$xdg_state"
printf '%s\n' enforcing >"$xdg_config/eci/command-gate-mode"
chmod 600 -- "$xdg_config/eci/command-gate-mode"

session_id=aggregate-routing-session
proof_root="$TMP_ROOT/proof"
outer_cwd="$TMP_ROOT/aggregate-root"
plan_source="$TMP_ROOT/eci-aggregate-plan.json.source"
mkdir -p -- "$proof_root" "$outer_cwd"

init_repo() {
  local repo="$1"

  mkdir -p -- "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.name 'ECI aggregate routing test'
  git -C "$repo" config user.email 'eci-aggregate-routing@example.invalid'
  printf '%s\n' baseline >"$repo/tracked.txt"
  git -C "$repo" add -- tracked.txt
  git -C "$repo" commit -qm 'fixture baseline'
}

repo_a="$outer_cwd/repo-a"
repo_b="$outer_cwd/repo-b"
outside_child="$outer_cwd/not-in-plan"
init_repo "$repo_a"
init_repo "$repo_b"
mkdir -p -- "$outside_child"

run_active() {
  run_active_from "$outer_cwd" "$@"
}

run_active_from() {
  local caller_cwd="$1"
  shift

  (
    cd -- "$caller_cwd"
    HOME="$sandbox_home" CODEX_HOME="$sandbox_root" CODEX_PROOF_ROOT="$proof_root" \
      CODEX_SESSION_ID="$session_id" CODEX_ROLE=main TMPDIR="$TMP_ROOT" \
      XDG_CONFIG_HOME="$xdg_config" XDG_STATE_HOME="$xdg_state" PATH="$sandbox_root/bin:$PATH" \
      "$sandbox_root/bin/eci-active" "$@"
  )
}

run_hook() {
  local hook_cwd="$1" command="$2" output="$3"

  jq -cn --arg session_id "$session_id" --arg cwd "$hook_cwd" --arg command "$command" \
    '{session_id:$session_id,cwd:$cwd,tool_input:{command:$command}}' |
    HOME="$sandbox_home" CODEX_HOME="$sandbox_root" CODEX_PROOF_ROOT="$proof_root" \
      XDG_CONFIG_HOME="$xdg_config" XDG_STATE_HOME="$xdg_state" PATH="$sandbox_root/bin:$PATH" \
      bash "$sandbox_root/hooks/validate-bash.sh" >"$output"
}

codex_lifecycle='$HOME/.codex/bin/eci-active'

jq -cn --arg repo_a "$repo_a" --arg repo_b "$repo_b" \
  '{schema:"eci-aggregate-plan-source/v1",repositories:[{id:"repo-a",repo_root:$repo_a},{id:"repo-b",repo_root:$repo_b}]}' \
  >"$plan_source"
run_active on 'aggregate routing fixture' >/dev/null
run_active aggregate-migrate "$plan_source" >/dev/null

# A canonical aggregate command is admitted from the parent marker cwd. The
# repository selector remains an ID, never a sibling path.
accepted_output="$TMP_ROOT/accepted.json"
accepted_command="env CODEX_SESSION_ID=$session_id TMPDIR=$TMP_ROOT $codex_lifecycle aggregate-review final repo-a"
run_hook "$outer_cwd" "$accepted_command" "$accepted_output"
[ ! -s "$accepted_output" ] || {
  cat -- "$accepted_output" >&2
  exit 1
}

# Aggregate staging reaches the CLI through ordinary command spellings. The
# hook diagnoses no separator, repeated separator, ordinary filenames, and
# environment wrappers only after their selected target is resolved; the CLI
# and Git own ordinary argument/path errors.
stage_accepted_output="$TMP_ROOT/stage-accepted.json"
stage_accepted_command="$codex_lifecycle aggregate-stage repo-a -- tracked.txt"
run_hook "$outer_cwd" "$stage_accepted_command" "$stage_accepted_output"
[ ! -s "$stage_accepted_output" ] || {
  cat -- "$stage_accepted_output" >&2
  exit 1
}

# Aggregate staging has no arbitrary upper operand cap. The private full
# runtime fixture proves both mirrored hook classifiers admit 65 otherwise
# ordinary selected-root-relative paths with its copied hook body enabled.
stage_many_paths=()
for stage_index in $(seq 1 65); do
  stage_many_paths+=("many-$stage_index.txt")
done
stage_many_output="$TMP_ROOT/stage-many.json"
stage_many_command="$codex_lifecycle aggregate-stage repo-a -- ${stage_many_paths[*]}"
if ! run_hook "$outer_cwd" "$stage_many_command" "$stage_many_output"; then
  printf '%s\n' 'aggregate stage hook process rejected a valid 65-path batch' >&2
  exit 1
fi
[ ! -s "$stage_many_output" ] || {
  cat -- "$stage_many_output" >&2
  printf '%s\n' 'aggregate stage hook rejected a valid 65-path batch' >&2
  exit 1
}
for stage_case in missing-separator extra-separator control-path env-wrapper; do
  stage_deferred_output="$TMP_ROOT/stage-$stage_case.json"
  case "$stage_case" in
  missing-separator)
    stage_denied_command="$codex_lifecycle aggregate-stage repo-a tracked.txt"
    ;;
  extra-separator)
    stage_denied_command="$codex_lifecycle aggregate-stage repo-a -- --"
    ;;
  control-path)
    stage_denied_command="$codex_lifecycle aggregate-stage repo-a -- eci_active"
    ;;
  env-wrapper)
    stage_denied_command="env CODEX_SESSION_ID=$session_id $codex_lifecycle aggregate-stage repo-a -- tracked.txt"
    ;;
  esac
  run_hook "$outer_cwd" "$stage_denied_command" "$stage_deferred_output"
  [ ! -s "$stage_deferred_output" ] || {
    cat -- "$stage_deferred_output" >&2
    printf 'aggregate stage hook blocked ordinary syntax case=%s instead of deferring to the selected CLI target\n' "$stage_case" >&2
    exit 1
  }
done

# A transparent wrapper does not change the selected lifecycle target. The
# hook may observe it, but must defer the ordinary command to the CLI.
transparent_wrapper_output="$TMP_ROOT/stage-transparent-wrapper.json"
transparent_wrapper_command="timeout 5 $codex_lifecycle aggregate-stage repo-a -- tracked.txt"
run_hook "$outer_cwd" "$transparent_wrapper_command" "$transparent_wrapper_output"
[ ! -s "$transparent_wrapper_output" ] || {
  cat -- "$transparent_wrapper_output" >&2
  printf '%s\n' 'aggregate stage hook blocked a transparent wrapper instead of deferring to the selected CLI target' >&2
  exit 1
}

# The callback hook defers ordinary lifecycle argument spelling to the CLI;
# the live aggregate target still accepts only an opaque repository ID.
bad_selector_output="$TMP_ROOT/bad-selector.json"
bad_selector_command="env CODEX_SESSION_ID=$session_id TMPDIR=$TMP_ROOT $codex_lifecycle aggregate-review final ../repo-a"
run_hook "$outer_cwd" "$bad_selector_command" "$bad_selector_output"
[ ! -s "$bad_selector_output" ] || {
  cat -- "$bad_selector_output" >&2
  printf '%s\n' 'aggregate hook unexpectedly classified ordinary lifecycle argument spelling' >&2
  exit 1
}
if run_active aggregate-review final ../repo-a >/dev/null 2>&1; then
  printf '%s\n' 'aggregate CLI accepted a path-shaped repository selector' >&2
  exit 1
fi

# The shell hook does not turn a raw Git spelling into a lifecycle ceremony;
# the selected-root boundary lives at the aggregate command that would target
# session state. An arbitrary descendant cannot select repo-a.
outside_output="$TMP_ROOT/outside-child.json"
run_hook "$outside_child" "git commit -m ordinary" "$outside_output"
[ ! -s "$outside_output" ] || {
  cat -- "$outside_output" >&2
  printf '%s\n' 'aggregate hook unexpectedly classified ordinary Git spelling' >&2
  exit 1
}
if run_active_from "$outside_child" aggregate-review final repo-a >/dev/null 2>&1; then
  printf '%s\n' 'aggregate CLI accepted a caller outside the selected parent/member scope' >&2
  exit 1
fi

# The compiled planner also treats namespaced aggregate artifacts as live
# control files, not ordinary worker-readable output.
control_path="$proof_root/$session_id/eci-aggregate.repo-a.required-critics.json"
printf '%s\n' '{}' >"$control_path"
planner_output="$TMP_ROOT/planner.json"
if jq -cn --arg cwd "$repo_a" --arg session_id "$session_id" --arg marker "$proof_root/$session_id/eci_active" \
  --arg command "cat $control_path" \
  '{provider:"codex",role:"worker",cwd:$cwd,marker:"active",active_session:$session_id,command:$command,active_markers:[$marker]}' |
  "$sandbox_root/hooks/lib/eci-command-plan-go/eci-command-plan" >"$planner_output"; then
  printf '%s\n' 'planner unexpectedly admitted worker access to aggregate control state' >&2
  exit 1
fi
jq -e '
  .hookSpecificOutput.permissionDecision == "deny" and
  (.hookSpecificOutput.permissionDecisionReason | contains("[ECI_PLAN_LIVE_CONTROL_DENIED]"))
' "$planner_output" >/dev/null

# A normal manifest remains a current-review input. The direct gate reports
# fresh review for its current target; it does not publish historic anchor or
# ledger records as a condition of ordinary work.
singleton_repo="$TMP_ROOT/singleton-repo"
singleton_proof="$TMP_ROOT/singleton-proof"
singleton_session=singleton-routing-session
init_repo "$singleton_repo"
printf '%s\n' reviewed >>"$singleton_repo/tracked.txt"
git -C "$singleton_repo" add -- tracked.txt
ECI_EMIT_CURRENT_MANIFEST=1 ECI_EMIT_PROOF_ROOT="$singleton_proof" \
  ECI_EMIT_SESSION_ID="$singleton_session" ECI_EMIT_KIND=root \
  ECI_TEST_REPO="$singleton_repo" ECI_TEST_TARGET="$singleton_repo/tracked.txt" \
  "$sandbox_root/hooks/tests/test-eci-review-gate.sh" >/dev/null
singleton_dir="$singleton_proof/$singleton_session"
(
  cd -- "$singleton_repo"
  HOME="$sandbox_home" CODEX_HOME="$sandbox_root" CODEX_PROOF_ROOT="$singleton_proof" \
    ECI_REVIEW_CWD="$singleton_repo" "$sandbox_root/hooks/eci-review-gate.sh" final "$singleton_session"
)
[ ! -e "$singleton_dir/eci-acceptance-anchor" ] && [ ! -L "$singleton_dir/eci-acceptance-anchor" ]
[ ! -e "$singleton_dir/eci-required-critics.final.1.ledger" ] && [ ! -L "$singleton_dir/eci-required-critics.final.1.ledger" ]
[ -f "$singleton_dir/eci-required-critics.json" ] && [ ! -L "$singleton_dir/eci-required-critics.json" ]

printf '%s\n' 'ECI aggregate command routing tests: PASS'
