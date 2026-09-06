#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TMP_PARENT="${CODEX_TMPDIR:-${TMPDIR:-${HOME:?}/tmp}}"
mkdir -p -- "$TMP_PARENT"
TMP_ROOT="$(mktemp -d "$TMP_PARENT/eci-active-help.XXXXXX")"
TMP_ROOT="$(realpath -e -- "$TMP_ROOT")"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

fixture_home="$TMP_ROOT/home"
fixture_home_alias="$TMP_ROOT/home-alias"
fixture_codex="$fixture_home/.codex"
fixture_eci="$fixture_codex/bin/eci-active"
copy_eci="$TMP_ROOT/eci-active-copy"
fixture_context7="$fixture_codex/bin/context7-mcp"
fixture_kimi="$fixture_home/.kimi-code"
fixture_kimi_eci="$fixture_kimi/bin/eci-active"
alternate_home="$TMP_ROOT/alternate-home"
alternate_codex="$alternate_home/.codex"
proof_root="$TMP_ROOT/proof"
active_marker="$proof_root/t00-help/eci_active"
state_root="$TMP_ROOT/state"
config_root="$TMP_ROOT/config"
input="$TMP_ROOT/input.json"
output="$TMP_ROOT/output.json"
stderr_output="$TMP_ROOT/stderr.txt"
fake_bin="$TMP_ROOT/fake-bin"
dispatcher_execution_marker="$TMP_ROOT/dispatcher-executed"
planner_execution_marker="$TMP_ROOT/planner-executed"
fresh_planner="$TMP_ROOT/fresh-eci-command-plan"
planner_dir="$fixture_codex/hooks/lib/eci-command-plan-go"
planner_binary="$planner_dir/eci-command-plan"
planner_receipt="$planner_dir/.eci-command-plan.provenance"
replacement_planner="$TMP_ROOT/replacement-eci-command-plan"
planner_race_done="$TMP_ROOT/planner-race-done"

mkdir -p -- "$fixture_home/tmp" "$fixture_codex/bin" "$fixture_kimi/bin" "$alternate_home" \
  "$proof_root/t00-help" "$state_root" "$config_root/eci" "$fake_bin"
ln -s -- "$fixture_home" "$fixture_home_alias"
cp -- "$ROOT/bin/eci-active" "$fixture_eci"
cp -- "$fixture_eci" "$copy_eci"
cp -- "$ROOT/bin/context7-mcp" "$fixture_context7"
cp -- "$ROOT/bin/eci-active-dispatch" "$fixture_codex/bin/eci-active-dispatch"
cp -- "$ROOT/bin/eci-runtime-sync" "$fixture_codex/bin/eci-runtime-sync"
cp -- "$ROOT/bin/eci-active" "$fixture_kimi_eci"
cp -a -- "$ROOT/hooks/." "$fixture_codex/hooks/"
cp -a -- "$ROOT/hooks/." "$fixture_kimi/hooks/"
# Remove a line-2 bypass if present in each private copy so the assertions
# exercise the hook body without changing the source.
for fixture_validate_bash in "$fixture_codex/hooks/validate-bash.sh" "$fixture_kimi/hooks/validate-bash.sh"; do
  sed -i '2{/^exit 0$/d;}' -- "$fixture_validate_bash"
done
cp -- "$ROOT/CODEX.md" "$fixture_codex/CODEX.md"
cp -- "$ROOT/config.toml" "$fixture_codex/config.toml"
cp -- "$ROOT/hooks.json" "$fixture_codex/hooks.json"
chmod 755 -- "$fixture_eci" "$copy_eci" "$fixture_codex/bin/eci-active-dispatch" "$fixture_codex/bin/eci-runtime-sync"
chmod 755 -- "$fixture_context7"

# Validate this source fixture against a freshly built planner so the test
# exercises the same checked-in Go authority contract without modifying the
# installed runtime binary or deployment receipt.
(
  cd "$fixture_codex/hooks/lib/eci-command-plan-go"
  rm -f -- eci-command-plan
  go build -o eci-command-plan .
)
chmod 755 -- "$planner_binary"
cp -- "$planner_binary" "$fresh_planner"
chmod 755 -- "$fixture_kimi_eci"

fixture_digest="$(sha256sum -- "$fixture_eci")"
fixture_digest="${fixture_digest%% *}"
fixture_mode="$(stat -c '%a' -- "$fixture_eci")"
printf 'bin/eci-active\t%s\t%s\n' "$fixture_digest" "$fixture_mode" >"$fixture_codex/.eci-runtime-sync-manifest"
chmod 600 -- "$fixture_codex/.eci-runtime-sync-manifest"
kimi_digest="$(sha256sum -- "$fixture_kimi_eci")"
kimi_digest="${kimi_digest%% *}"
kimi_mode="$(stat -c '%a' -- "$fixture_kimi_eci")"
printf 'bin/eci-active\t%s\t%s\n' "$kimi_digest" "$kimi_mode" >"$fixture_kimi/.eci-runtime-sync-manifest"
chmod 600 -- "$fixture_kimi/.eci-runtime-sync-manifest"

write_full_codex_runtime_receipt() {
  local relative source digest mode

  : >"$fixture_codex/.eci-runtime-sync-manifest"
  {
    printf '%s\n' hooks.json
    printf '%s\n' bin/eci-active
    printf '%s\n' bin/eci-active-dispatch
    printf '%s\n' bin/eci-runtime-sync
    [ -f "$fixture_codex/bin/eci-command-gate-mode" ] && printf '%s\n' bin/eci-command-gate-mode
    find "$fixture_codex/hooks" -type f ! -path "$fixture_codex/hooks/tests/*" \
      ! -path '*/__pycache__/*' ! -name '*.pyc' ! -name '*.pyo' -printf 'hooks/%P\n'
  } | LC_ALL=C sort -u | while IFS= read -r relative; do
    [ -n "$relative" ] || continue
    source="$fixture_codex/$relative"
    digest="$(sha256sum -- "$source" | awk '{print $1}')"
    mode="$(stat -c '%a' -- "$source")"
    printf '%s\t%s\t%s\n' "$relative" "$digest" "$mode" >>"$fixture_codex/.eci-runtime-sync-manifest"
  done
  chmod 600 -- "$fixture_codex/.eci-runtime-sync-manifest"
}

# This is the producer-shaped source/binary coherence receipt emitted by
# eci-runtime-sync. The per-callback hook validates that coherence while the
# controlled planner-check route remains responsible for full toolchain
# attestation. The fixture stays private and never publishes provider runtime
# state outside its temporary directory.
write_current_planner_provenance() {
  local planner_go='/usr/lib/go-1.24/bin/go'
  local planner_go_root planner_go_tool_path planner_go_version planner_go_sha
  local planner_go_tool_sha planner_tool_manifest planner_tool_path planner_tool_digest
  local source_go_mod_sha source_main_sha source_classifier_sha binary_sha binary_size binary_mode

  [ -x "$planner_go" ] || {
    printf 'pinned Go toolchain is unavailable for planner provenance fixture: %s\n' "$planner_go" >&2
    exit 1
  }
  planner_go_root="$("$planner_go" env GOROOT)"
  planner_go_tool_path="$planner_go_root/pkg/tool/linux_arm64"
  planner_go_version="$("$planner_go" version)"
  planner_go_sha="$(sha256sum -- "$planner_go" | awk '{print $1}')"
  planner_tool_manifest="$TMP_ROOT/planner-toolchain.manifest"
  : >"$planner_tool_manifest"
  while IFS= read -r -d '' planner_tool_path; do
    planner_tool_digest="$(sha256sum -- "$planner_tool_path" | awk '{print $1}')"
    printf '%s\t%s\n' "${planner_tool_path#"$planner_go_tool_path/"}" "$planner_tool_digest" >>"$planner_tool_manifest"
  done < <(find -P "$planner_go_tool_path" -mindepth 1 -maxdepth 1 -print0 | sort -z)
  planner_go_tool_sha="$(sha256sum -- "$planner_tool_manifest" | awk '{print $1}')"
  source_go_mod_sha="$(sha256sum -- "$planner_dir/go.mod" | awk '{print $1}')"
  source_main_sha="$(sha256sum -- "$planner_dir/main.go" | awk '{print $1}')"
  source_classifier_sha="$(sha256sum -- "$planner_dir/classifier.go" | awk '{print $1}')"
  binary_sha="$(sha256sum -- "$planner_binary" | awk '{print $1}')"
  binary_size="$(stat -c '%s' -- "$planner_binary")"
  binary_mode="$(stat -c '%a' -- "$planner_binary")"

  {
    printf 'contract\tclosed-go-build/v1\n'
    printf 'go_path\t%s\n' "$planner_go"
    printf 'go_sha256\t%s\n' "$planner_go_sha"
    printf 'go_version\t%s\n' "$planner_go_version"
    printf 'go_root\t%s\n' "$planner_go_root"
    printf 'go_tool_path\t%s\n' "$planner_go_tool_path"
    printf 'go_tool_sha256\t%s\n' "$planner_go_tool_sha"
    printf 'target\tlinux/arm64\n'
    printf 'source_go.mod_sha256\t%s\n' "$source_go_mod_sha"
    printf 'source_main.go_sha256\t%s\n' "$source_main_sha"
    printf 'source_classifier.go_sha256\t%s\n' "$source_classifier_sha"
    printf 'binary_sha256\t%s\n' "$binary_sha"
    printf 'binary_size\t%s\n' "$binary_size"
    printf 'binary_mode\t%s\n' "$binary_mode"
  } >"$planner_receipt"
  chmod 600 -- "$planner_receipt"
}

printf '%s\n' enforcing >"$config_root/eci/command-gate-mode"
printf '%s\n' \
  'scope: canonical help test' \
  "cwd: $ROOT" \
  'session_id: t00-help' \
  'created_utc: 2026-08-26T00:00:00Z' \
  >"$active_marker"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$fake_bin/eci-active"
chmod 755 -- "$fake_bin/eci-active"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$fake_bin/env"
chmod 755 -- "$fake_bin/env"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'if [ "${1:-}" = -e ]; then exit 0; fi' \
  'printf "%s\\n" context7-fixture-node' \
  >"$fake_bin/node"
chmod 755 -- "$fake_bin/node"
printf '%s\n' '#!/usr/bin/env bash' 'printf dispatcher-executed > "${DISPATCHER_EXECUTION_MARKER:?}"' \
  >"$fake_bin/eci-active-dispatch"
chmod 755 -- "$fake_bin/eci-active-dispatch"

# Keep a complete alternate provider-shaped copy. Runtime maintenance must
# resolve the configured provider source/target, rather than treating this
# launcher's spelling as authority over the selected destination.
cp -a -- "$fixture_codex" "$alternate_codex"
rm -f -- "$alternate_codex/.eci-runtime-sync-manifest"

assert_help_success() {
  local flag="$1"

  if ! HOME="$fixture_home" "$fixture_eci" "$flag" >"$output" 2>"$stderr_output"; then
    printf 'eci-active %s did not exit successfully:\n' "$flag" >&2
    cat -- "$stderr_output" >&2
    exit 1
  fi
  [ ! -s "$stderr_output" ] || {
    printf 'eci-active %s wrote unexpected stderr:\n' "$flag" >&2
    cat -- "$stderr_output" >&2
    exit 1
  }
  grep -Fqx 'Usage:' "$output" || {
    printf 'eci-active %s did not print usage:\n' "$flag" >&2
    cat -- "$output" >&2
    exit 1
  }
}

# Help output is copy/paste guidance. It deliberately shows the stable
# current-home path, but that spelling is not an authorization boundary: the
# hook compares the executable target selected by the command instead.
assert_codex_help_examples_use_literal_home_path() {
  local example

  if ! HOME="$fixture_home" "$fixture_eci" --help >"$output" 2>"$stderr_output"; then
    printf '%s\n' 'eci-active --help did not exit successfully for canonical-path assertions:' >&2
    cat -- "$stderr_output" >&2
    exit 1
  fi
  [ ! -s "$stderr_output" ] || {
    printf '%s\n' 'eci-active --help wrote stderr for canonical-path assertions:' >&2
    cat -- "$stderr_output" >&2
    exit 1
  }

  while IFS= read -r example; do
    case "$example" in
      '  "$HOME/.codex/bin/eci-active" '*) ;;
      *)
        printf 'Codex help emitted an unexpected lifecycle example: %s\n' "$example" >&2
        exit 1
        ;;
    esac
  done < <(sed -n '/^Usage:$/,/^$/p' "$output" | grep '^  ')

  grep -Fq '  "$HOME/.codex/bin/eci-active" status' "$output" || {
    printf '%s\n' 'eci-active --help did not emit canonical lifecycle examples:' >&2
    cat -- "$output" >&2
    exit 1
  }
}

# Normal teardown must not send a coordinator into manifest/receipt recovery.
# The current marker/CWD and supplied report are the lifecycle boundaries;
# historical review metadata is reconciled without another command ceremony.
assert_teardown_history_needs_no_lifecycle_recovery() {
  local lifecycle_source="$ROOT/bin/eci-active"

  grep -Fq 'reconcile_teardown_history' "$lifecycle_source" || {
    printf '%s\n' 'normal teardown does not reconcile historical metadata:' >&2
    exit 1
  }
  if grep -Fq 'provider-native critic/receipt evidence is missing or invalid' "$lifecycle_source" ||
    grep -Fq 'manifest-write <TMPDIR>/eci-required-critics.json.source' "$lifecycle_source" ||
    grep -Fq 'write_teardown_receipt' "$lifecycle_source"; then
    printf '%s\n' 'normal teardown still requires historical artifact recovery:' >&2
    exit 1
  fi
}

# `$HOME/.codex` is the selected source authority even when HOME itself is a
# stable filesystem alias.  The executable may discover its own directory
# physically, but it must compare that physical identity to the resolved
# HOME-rooted authority rather than rejecting the lexical HOME spelling.
assert_home_alias_help_success() {
  if ! HOME="$fixture_home_alias" "$fixture_eci" --help >"$output" 2>"$stderr_output"; then
    printf '%s\n' 'eci-active rejected a HOME-parent alias before lifecycle parsing:' >&2
    cat -- "$stderr_output" >&2
    exit 1
  fi
  grep -Fqx 'Usage:' "$output" || {
    printf '%s\n' 'eci-active HOME-parent alias did not print usage:' >&2
    cat -- "$output" >&2
    exit 1
  }
}

assert_home_alias_context7_success() {
  if ! HOME="$fixture_home_alias" PATH="$fake_bin:/usr/bin:/bin" \
    "$fixture_context7" --help >"$output" 2>"$stderr_output"; then
    printf '%s\n' 'context7-mcp rejected a HOME-parent alias before its canonical source check:' >&2
    cat -- "$stderr_output" >&2
    exit 1
  fi
  grep -Fqx 'context7-fixture-node' "$output" || {
    printf '%s\n' 'context7-mcp HOME-parent alias did not reach the node entrypoint:' >&2
    cat -- "$output" >&2
    exit 1
  }
}

assert_kimi_help_success() {
  if ! HOME="$fixture_home" KIMI_CODE_HOME="$fixture_kimi" "$fixture_kimi_eci" --help >"$output" 2>"$stderr_output"; then
    printf 'Kimi eci-active --help did not preserve its provider-root contract:\n' >&2
    cat -- "$stderr_output" >&2
    exit 1
  fi
  grep -Fqx 'Usage:' "$output" || {
    printf 'Kimi eci-active --help did not print usage:\n' >&2
    cat -- "$output" >&2
    exit 1
  }
  grep -Fq '  "${KIMI_CODE_HOME:-$HOME/.kimi-code}/bin/eci-active" status' "$output" || {
    printf 'Kimi eci-active --help did not preserve its configurable provider lifecycle path:\n' >&2
    cat -- "$output" >&2
    exit 1
  }
  if grep -Fq '$HOME/.codex/bin/eci-active' "$output"; then
    printf 'Kimi eci-active --help leaked the Codex lifecycle path:\n' >&2
    cat -- "$output" >&2
    exit 1
  fi
}

assert_role_label_does_not_block_on_or_status() {
  local role_proof_root="$TMP_ROOT/role-proof"
  local role_marker="$role_proof_root/t00-role/eci_active"

  mkdir -p -- "$role_proof_root"
  if ! (
    cd "$ROOT"
    HOME="$fixture_home" CODEX_ROLE=worker CODEX_SESSION_ID=t00-role \
      CODEX_PROOF_ROOT="$role_proof_root" "$fixture_eci" on 'role-labeled lifecycle fixture'
  ) >"$output" 2>"$stderr_output"; then
    printf '%s\n' 'role label blocked ordinary eci-active on:' >&2
    cat -- "$stderr_output" >&2
    exit 1
  fi
  [ -f "$role_marker" ] && [ ! -L "$role_marker" ] || {
    printf '%s\n' 'role-labeled eci-active on did not create its direct session marker' >&2
    exit 1
  }
  if ! (
    cd "$ROOT"
    HOME="$fixture_home" CODEX_ROLE=worker CODEX_SESSION_ID=t00-role \
      CODEX_PROOF_ROOT="$role_proof_root" "$fixture_eci" status
  ) >"$output" 2>"$stderr_output"; then
    printf '%s\n' 'role label blocked ordinary eci-active status:' >&2
    cat -- "$stderr_output" >&2
    exit 1
  fi
  grep -Fqx 'session_id: t00-role' "$output" || {
    printf '%s\n' 'role-labeled eci-active status did not report the direct active marker' >&2
    cat -- "$output" >&2
    exit 1
  }
}

run_hook_with_path() {
  local command="$1" command_path="$2"

  jq -cn --arg cwd "$ROOT" --arg command "$command" \
    '{session_id:"t00-help",cwd:$cwd,tool_input:{command:$command}}' \
    >"$input"
  HOME="$fixture_home" CODEX_HOME="$alternate_codex" CODEX_PROOF_ROOT="$proof_root" \
    XDG_CONFIG_HOME="$config_root" XDG_STATE_HOME="$state_root" \
    DISPATCHER_EXECUTION_MARKER="$dispatcher_execution_marker" \
    PLANNER_EXECUTION_MARKER="$planner_execution_marker" \
    PATH="$command_path" \
    /bin/bash "$fixture_codex/hooks/validate-bash.sh" <"$input" >"$output" 2>"$stderr_output"
}

run_hook() {
  run_hook_with_path "$1" "$fake_bin:/usr/bin:/bin"
}

run_role_labeled_hook() {
  local command="$1"

  jq -cn --arg cwd "$ROOT" --arg command "$command" \
    '{session_id:"t00-help",cwd:$cwd,tool_input:{command:$command}}' \
    >"$input"
  HOME="$fixture_home" CODEX_HOME="$alternate_codex" CODEX_PROOF_ROOT="$proof_root" \
    XDG_CONFIG_HOME="$config_root" XDG_STATE_HOME="$state_root" CODEX_ROLE=worker \
    DISPATCHER_EXECUTION_MARKER="$dispatcher_execution_marker" \
    PLANNER_EXECUTION_MARKER="$planner_execution_marker" \
    PATH="$fake_bin:/usr/bin:/bin" \
    /bin/bash "$fixture_codex/hooks/validate-bash.sh" <"$input" >"$output" 2>"$stderr_output"
}

run_inactive_worker_hook() {
  local command="$1"

  jq -cn --arg cwd "$ROOT" --arg command "$command" \
    '{session_id:"inactive-help",cwd:$cwd,tool_input:{command:$command}}' \
    >"$input"
  HOME="$fixture_home" CODEX_HOME="$alternate_codex" CODEX_PROOF_ROOT="$proof_root" \
    XDG_CONFIG_HOME="$config_root" XDG_STATE_HOME="$state_root" CODEX_ROLE=worker \
    PATH="$fixture_codex/bin:/usr/bin:/bin" \
    /bin/bash "$fixture_codex/hooks/validate-bash.sh" <"$input" >"$output" 2>"$stderr_output"
}

# Exercise read-only lifecycle visibility from an actual worker callback.
# The hook must defer help/status to the invoked CLI regardless of spelling;
# mutating verbs remain on their target-aware lifecycle route.
run_worker_hook() {
  local command="$1"

  jq -cn --arg cwd "$ROOT" --arg command "$command" \
    '{session_id:"t00-help",cwd:$cwd,tool_input:{command:$command}}' \
    >"$input"
  HOME="$fixture_home" CODEX_HOME="$fixture_codex" CODEX_PROOF_ROOT="$proof_root" \
    XDG_CONFIG_HOME="$config_root" XDG_STATE_HOME="$state_root" \
    CODEX_HOOK_IS_SUBAGENT=true CODEX_ROLE=worker \
    DISPATCHER_EXECUTION_MARKER="$dispatcher_execution_marker" \
    PLANNER_EXECUTION_MARKER="$planner_execution_marker" \
    PATH="$fake_bin:/usr/bin:/bin" \
    /bin/bash "$fixture_codex/hooks/validate-bash.sh" <"$input" >"$output" 2>"$stderr_output"
}

assert_hook_allows_read_only_lifecycle() {
  local command="$1" runner="${2:-run_hook}"

  "$runner" "$command"
  [ ! -s "$stderr_output" ] || {
    printf 'read-only lifecycle route wrote hook stderr: command=%s\n' "$command" >&2
    cat -- "$stderr_output" >&2
    exit 1
  }
  [ ! -s "$output" ] || {
    printf 'read-only lifecycle route was blocked: command=%s\n' "$command" >&2
    cat -- "$output" >&2
    exit 1
  }
}

assert_hook_allows_read_only_lifecycle_with_path() {
  local command="$1" command_path="$2"

  run_hook_with_path "$command" "$command_path"
  [ ! -s "$stderr_output" ] || {
    printf 'read-only lifecycle PATH route wrote hook stderr: command=%s\n' "$command" >&2
    cat -- "$stderr_output" >&2
    exit 1
  }
  [ ! -s "$output" ] || {
    printf 'read-only lifecycle PATH route was blocked: command=%s\n' "$command" >&2
    cat -- "$output" >&2
    exit 1
  }
}

assert_worker_lifecycle_visibility_allowed() {
  local command

  for command in \
    '$HOME/.codex/bin/eci-active-dispatch --help' \
    'eci-active-dispatch --help' \
    'env -- CODEX_SESSION_ID=t00-help "$HOME/.codex/bin/eci-active-dispatch" --help' \
    '"$HOME/.kimi-code/bin/eci-active" status'; do
    rm -f -- "$dispatcher_execution_marker"
    assert_hook_allows_read_only_lifecycle "$command" run_worker_hook
    [ ! -e "$dispatcher_execution_marker" ] || {
      printf 'worker lifecycle visibility unexpectedly executed the dispatcher: command=%s\n' "$command" >&2
      exit 1
    }
  done
}

# Planner drift selects current-source classification and, if those sources
# are temporarily unbuildable, the existing concrete fallback boundaries.
# Neither path may execute the stale installed planner.
assert_stale_planner_uses_safe_fallback() {
  local classifier_backup="$TMP_ROOT/classifier.go.before-unbuildable-fallback"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf planner-executed > "${PLANNER_EXECUTION_MARKER:?}"' \
    'printf "%s\n" "{\"decision\":\"allow\"}"' \
    >"$planner_binary"
  chmod 755 -- "$planner_binary"
  write_full_codex_runtime_receipt
  rm -f -- "$planner_execution_marker" "$dispatcher_execution_marker"

  run_hook 'printf planner-fallback-benign'
  [ ! -s "$output" ] || {
    printf 'planner drift blocked a benign current-source classification:\n' >&2
    cat -- "$output" >&2
    exit 1
  }
  [ ! -e "$planner_execution_marker" ] || {
    printf '%s\n' 'stale planner binary was invoked despite provenance mismatch:' >&2
    exit 1
  }
  # Make the current source temporarily unbuildable so this assertion cannot
  # pass through either installed planner artifact. The existing concrete
  # target evaluator must still reject a broad wrong-target delete.
  cp -- "$planner_dir/classifier.go" "$classifier_backup"
  printf '\nthis is intentionally invalid Go for fallback coverage\n' >>"$planner_dir/classifier.go"
  run_hook 'printf planner-fallback-unbuildable-source'
  [ ! -s "$output" ] || {
    printf 'unbuildable current planner source blocked benign fallback work:\n' >&2
    cat -- "$output" >&2
    exit 1
  }
  run_hook "find $ROOT -delete"
  jq -e '
    .hookSpecificOutput.permissionDecision == "deny" and
    (.hookSpecificOutput.permissionDecisionReason | contains("[ECI_BROAD_DESTRUCTIVE_DENIED]")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("operation=broad-destructive"))
  ' "$output" >/dev/null || {
    printf 'planner fallback missed the broad wrong-target boundary:\n' >&2
    cat -- "$output" >&2
    exit 1
  }
  [ ! -e "$planner_execution_marker" ] || {
    printf '%s\n' 'stale planner binary was invoked by the safe fallback:' >&2
    exit 1
  }
  cp -- "$classifier_backup" "$planner_dir/classifier.go"
}

# The exact reviewed bootstrap must remain available before planner admission,
# otherwise the failed-closed stale artifact cannot be repaired.  Its complete
# runtime receipt has already been refreshed above to describe the current
# fixture files, including the deliberately stale planner binary.
assert_hook_allows_maintain_planner_bootstrap() {
  run_hook '"$HOME/.codex/bin/eci-active" maintain-planner'
  [ ! -s "$stderr_output" ] || {
    printf 'maintain-planner bootstrap wrote unexpected stderr:\n' >&2
    cat -- "$stderr_output" >&2
    exit 1
  }
  [ ! -s "$output" ] || {
    printf 'maintain-planner bootstrap was blocked behind planner provenance:\n' >&2
    cat -- "$output" >&2
    exit 1
  }
}

restore_fresh_planner_artifact() {
  cp -- "$fresh_planner" "$planner_binary"
  chmod 755 -- "$planner_binary"
  write_current_planner_provenance
  write_full_codex_runtime_receipt
}

# Replace the planner pathname immediately after the hook hashes its inherited
# /proc/self/fd descriptor.  The planner itself records which inode executed,
# so this is an integration regression for the hook handoff rather than a
# production fault-injection path.
assert_hook_executes_pinned_planner_after_path_replacement() {
  local hook_copy="$fixture_codex/hooks/validate-bash.sh"
  local patched_hook="$TMP_ROOT/validate-bash.race.sh"
  local patch_status

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'cat >/dev/null' \
    'printf pinned-planner > "${PLANNER_EXECUTION_MARKER:?}"' \
    'printf "%s\\n" "{\"decision\":\"allow\"}"' \
    >"$planner_binary"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'cat >/dev/null' \
    'printf replacement-planner > "${PLANNER_EXECUTION_MARKER:?}"' \
    'printf "%s\\n" "{\"decision\":\"allow\"}"' \
    >"$replacement_planner"
  chmod 755 -- "$planner_binary" "$replacement_planner"
  write_current_planner_provenance

  # Patch only the private fixture copy.  The inserted branch runs after the
  # pinned binary digest comparison and before the copied hook reaches planner
  # execution; no production hook accepts this test control input.
  if awk '
    { print }
    /pinned planner binary digest does not match provenance/ {
      count++
      print "  if [ -n \"${PLANNER_RACE_BINARY:-}\" ] && [ -n \"${PLANNER_RACE_REPLACEMENT:-}\" ] && [ ! -e \"${PLANNER_RACE_DONE:-}\" ]; then"
      print "    mv -- \"$PLANNER_RACE_REPLACEMENT\" \"$PLANNER_RACE_BINARY\""
      print "    : > \"$PLANNER_RACE_DONE\""
      print "  fi"
    }
    END { exit(count == 1 ? 0 : 42) }
  ' "$hook_copy" >"$patched_hook"; then
    :
  else
    patch_status=$?
    printf 'planner-race fixture could not patch exactly one pinned-digest site (status=%s)\n' "$patch_status" >&2
    exit 1
  fi
  mv -- "$patched_hook" "$hook_copy"
  chmod 755 -- "$hook_copy"
  write_full_codex_runtime_receipt

  rm -f -- "$planner_execution_marker" "$dispatcher_execution_marker" "$planner_race_done"
  export PLANNER_RACE_BINARY="$planner_binary"
  export PLANNER_RACE_REPLACEMENT="$replacement_planner"
  export PLANNER_RACE_DONE="$planner_race_done"
  run_worker_hook 'printf hook-fd-handoff'
  unset PLANNER_RACE_BINARY PLANNER_RACE_REPLACEMENT PLANNER_RACE_DONE

  [ -e "$planner_race_done" ] || {
    printf '%s\n' 'planner replacement did not run after pinned-digest validation' >&2
    exit 1
  }
  [ "$(cat -- "$planner_execution_marker")" = pinned-planner ] || {
    printf 'hook executed the replaced planner pathname instead of the pinned descriptor:\n' >&2
    cat -- "$planner_execution_marker" >&2 2>/dev/null || true
    exit 1
  }
  grep -Fq replacement-planner "$planner_binary" || {
    printf '%s\n' 'planner race fixture did not replace the planner pathname' >&2
    exit 1
  }
  [ ! -s "$stderr_output" ] || {
    printf 'pinned planner handoff wrote unexpected stderr:\n' >&2
    cat -- "$stderr_output" >&2
    exit 1
  }
  [ ! -s "$output" ] || {
    printf 'pinned planner handoff was not admitted:\n' >&2
    cat -- "$output" >&2
    exit 1
  }

  cp -- "$ROOT/hooks/validate-bash.sh" "$hook_copy"
  sed -i '2{/^exit 0$/d;}' -- "$hook_copy"
  chmod 755 -- "$hook_copy"
  restore_fresh_planner_artifact
}

assert_hook_allows_home_token_help() {
  local spelling="$1" flag="$2"

  run_hook "$spelling $flag"
  [ ! -s "$stderr_output" ] || {
    printf 'HOME-token help route wrote stderr: spelling=%s flag=%s\n' "$spelling" "$flag" >&2
    cat -- "$stderr_output" >&2
    exit 1
  }
  [ ! -s "$output" ] || {
    printf 'HOME-token help route was not admitted: spelling=%s flag=%s\n' "$spelling" "$flag" >&2
    cat -- "$output" >&2
    exit 1
  }
}

assert_hook_allows_system_env_help() {
  local spelling="$1" flag="$2"
  local command="env -- CODEX_SESSION_ID=t00-help $spelling $flag"

  run_hook_with_path "$command" '/usr/bin:/bin'
  [ ! -s "$stderr_output" ] || {
    printf 'HOME-token env help route wrote stderr: spelling=%s flag=%s\n' "$spelling" "$flag" >&2
    cat -- "$stderr_output" >&2
    exit 1
  }
  [ ! -s "$output" ] || {
    printf 'HOME-token env help route was not admitted: spelling=%s flag=%s\n' "$spelling" "$flag" >&2
    cat -- "$output" >&2
    exit 1
  }
}

# Equivalent command spellings are convenience, not authority. The hook must
# compare the executable selected by the shell with the current Codex target.
assert_hook_allows_equivalent_lifecycle_target() {
  local command="$1" command_path="$2"

  run_hook_with_path "$command" "$command_path"
  [ ! -s "$stderr_output" ] || {
    printf 'equivalent lifecycle target wrote stderr: command=%s\n' "$command" >&2
    cat -- "$stderr_output" >&2
    exit 1
  }
  [ ! -s "$output" ] || {
    printf 'equivalent lifecycle target was not admitted: command=%s\n' "$command" >&2
    cat -- "$output" >&2
    exit 1
  }
}

# Help is the CLI's own read-only interface. It must work before a marker
# exists and without a coordinator role once the executable resolves to the
# current Codex target.
assert_hook_allows_help_without_active_coordinator() {
  run_inactive_worker_hook '"$HOME/.codex/bin/eci-active" --help'
  [ ! -s "$stderr_output" ] || {
    printf '%s\n' 'inactive worker help wrote stderr:' >&2
    cat -- "$stderr_output" >&2
    exit 1
  }
  [ ! -s "$output" ] || {
    printf '%s\n' 'inactive worker help was blocked before the lifecycle CLI:' >&2
    cat -- "$output" >&2
    exit 1
  }
}

# A malformed lifecycle invocation belongs to eci-active's CLI parser, not
# the hook. The hook only establishes the executable identity and leaves the
# CLI to print its normal argument error.
assert_hook_defers_malformed_lifecycle_to_cli() {
  run_hook '"$HOME/.codex/bin/eci-active" --help extra'
  [ ! -s "$stderr_output" ] || {
    printf '%s\n' 'malformed lifecycle help route wrote hook stderr:' >&2
    cat -- "$stderr_output" >&2
    exit 1
  }
  [ ! -s "$output" ] || {
    printf '%s\n' 'malformed lifecycle help was denied by the hook instead of reaching the CLI:' >&2
    cat -- "$output" >&2
    exit 1
  }
}

# A PATH shadow named env is not the system env launcher. It must not gain the
# real-env lifecycle route merely because its command text says env.
assert_hook_does_not_treat_fake_env_as_system_env() {
  run_hook 'env CODEX_SESSION_ID=t00-help "$HOME/.codex/bin/eci-active" --help'
  if [ -s "$output" ]; then
    jq -e '(.hookSpecificOutput.permissionDecisionReason // "") | contains("[ECI_LIFECYCLE_") | not' "$output" >/dev/null || {
      printf '%s\n' 'PATH-shadowed env was misclassified as the system env lifecycle launcher:' >&2
      cat -- "$output" >&2
      exit 1
    }
  fi
}

assert_hook_denies_dispatcher_lifecycle() {
  local command="$1"

  rm -f -- "$dispatcher_execution_marker"
  run_hook "$command"
  jq -e '
    .hookSpecificOutput.permissionDecision == "deny" and
    (.hookSpecificOutput.permissionDecisionReason | contains("[ECI_LIFECYCLE_CANONICAL_PATH_DENIED]")) and
    (.hookSpecificOutput.permissionDecisionReason | contains("operation=eci-lifecycle"))
  ' "$output" >/dev/null || {
    printf 'dispatcher lifecycle spelling was not denied before execution: command=%s\n' "$command" >&2
    cat -- "$output" >&2
    exit 1
  }
  [ ! -e "$dispatcher_execution_marker" ] || {
    printf 'dispatcher lifecycle spelling was executed: command=%s\n' "$command" >&2
    exit 1
  }
}

assert_hook_denies_distinct_lifecycle_mutation() {
  run_hook '"$HOME/.kimi-code/bin/eci-active" on foreign-target-mutation'
  jq -e '
    .hookSpecificOutput.permissionDecision == "deny" and
    (.hookSpecificOutput.permissionDecisionReason | contains("[ECI_LIFECYCLE_TARGET_DENIED]"))
  ' "$output" >/dev/null || {
    printf 'foreign lifecycle mutation was not target-checked:\n' >&2
    cat -- "$output" >&2
    exit 1
  }
}

assert_receipt_deadlock_escape_admitted() {
  local label="$1" command="$2" receipt_before marker_before

  receipt_before="$TMP_ROOT/$label.runtime-receipt.before"
  marker_before="$TMP_ROOT/$label.active-marker.before"
  cp -- "$active_marker" "$marker_before"
  if [ -e "$fixture_codex/.eci-runtime-sync-manifest" ]; then
    cp -- "$fixture_codex/.eci-runtime-sync-manifest" "$receipt_before"
  else
    receipt_before=''
  fi
  run_hook "$command"
  [ ! -s "$stderr_output" ] || {
    printf 'receipt-deadlock escape wrote stderr: %s\n' "$label" >&2
    cat -- "$stderr_output" >&2
    exit 1
  }
  [ ! -s "$output" ] || {
    printf 'receipt-deadlock escape was not admitted: %s\n' "$label" >&2
    cat -- "$output" >&2
    exit 1
  }
  cmp -- "$marker_before" "$active_marker" || {
    printf 'receipt-deadlock escape changed the active marker: %s\n' "$label" >&2
    exit 1
  }
  if [ -n "$receipt_before" ]; then
    cmp -- "$receipt_before" "$fixture_codex/.eci-runtime-sync-manifest" || {
      printf 'receipt-deadlock escape changed the stale receipt: %s\n' "$label" >&2
      exit 1
    }
  else
    [ ! -e "$fixture_codex/.eci-runtime-sync-manifest" ] &&
      [ ! -L "$fixture_codex/.eci-runtime-sync-manifest" ] || {
        printf 'receipt-deadlock escape created a missing receipt: %s\n' "$label" >&2
        exit 1
      }
  fi
}

assert_missing_runtime_receipt_escape_hatches() {
  [ ! -e "$fixture_codex/.eci-runtime-sync-manifest" ] &&
    [ ! -L "$fixture_codex/.eci-runtime-sync-manifest" ] || {
      printf '%s\n' 'missing-receipt regression did not begin with a missing receipt' >&2
      exit 1
    }
  assert_receipt_deadlock_escape_admitted missing-help '"$HOME/.codex/bin/eci-active" --help'
  assert_receipt_deadlock_escape_admitted missing-short-help '"$HOME/.codex/bin/eci-active" -h'
  assert_receipt_deadlock_escape_admitted missing-sync-runtime '"$HOME/.codex/bin/eci-active" sync-runtime'
  assert_receipt_deadlock_escape_admitted missing-maintain-planner '"$HOME/.codex/bin/eci-active" maintain-planner'
  assert_receipt_deadlock_escape_admitted missing-status '"$HOME/.codex/bin/eci-active" status'
}

assert_stale_receipt_admits_ordinary_lifecycle() {
  local label="$1" command="$2"

  assert_receipt_deadlock_escape_admitted "$label" "$command"
}

assert_role_labeled_sync_runtime_is_not_role_denied() {
  # This is the outer callback with a stale role label, not a worker
  # delegation test. Recovery is bound by its session/cwd target, not the
  # incidental CODEX_ROLE value.
  run_role_labeled_hook '"$HOME/.codex/bin/eci-active" sync-runtime'
  [ ! -s "$output" ] || {
    printf '%s\n' 'worker-role sync-runtime was blocked despite matching session/cwd recovery target:' >&2
    cat -- "$output" >&2
    exit 1
  }
}

assert_stale_runtime_receipt_deadlock_policy() {
  local stale_receipt_before marker_before

  printf '%s\n' '# stale runtime receipt fixture' >>"$fixture_eci"
  stale_receipt_before="$TMP_ROOT/stale-receipt.before"
  marker_before="$TMP_ROOT/stale-receipt.active-marker.before"
  cp -- "$fixture_codex/.eci-runtime-sync-manifest" "$stale_receipt_before"
  cp -- "$active_marker" "$marker_before"

  assert_receipt_deadlock_escape_admitted stale-help '"$HOME/.codex/bin/eci-active" --help'
  assert_receipt_deadlock_escape_admitted stale-short-help '"$HOME/.codex/bin/eci-active" -h'
  assert_receipt_deadlock_escape_admitted stale-sync-runtime '"$HOME/.codex/bin/eci-active" sync-runtime'
  assert_receipt_deadlock_escape_admitted stale-maintain-planner '"$HOME/.codex/bin/eci-active" maintain-planner'
  assert_stale_receipt_admits_ordinary_lifecycle stale-status '"$HOME/.codex/bin/eci-active" status'
  assert_stale_receipt_admits_ordinary_lifecycle stale-ledger-append \
    '"$HOME/.codex/bin/eci-active" ledger-append receipt-deadlock-regression'
  assert_role_labeled_sync_runtime_is_not_role_denied

  cmp -- "$stale_receipt_before" "$fixture_codex/.eci-runtime-sync-manifest" || {
    printf '%s\n' 'stale-receipt policy changed the receipt through the active hook' >&2
    exit 1
  }
  cmp -- "$marker_before" "$active_marker" || {
    printf '%s\n' 'stale-receipt policy changed the active marker through the active hook' >&2
    exit 1
  }
}

assert_runtime_sync_rejects_resolved_self_target() {
  local target_digest status

  target_digest="$(sha256sum -- "$fixture_codex/CODEX.md")"
  target_digest="${target_digest%% *}"
  set +e
  HOME="$fixture_home" CODEX_HOME="$fixture_codex" \
    "$alternate_codex/bin/eci-runtime-sync" apply --target "$fixture_codex" \
    >"$output" 2>"$stderr_output"
  status=$?
  set -e
  [ "$status" -ne 0 ] || {
    printf 'runtime sync accepted its resolved provider source as a publish target:\n' >&2
    cat -- "$output" >&2
    cat -- "$stderr_output" >&2
    exit 1
  }
  grep -Fq 'ECI_RUNTIME_SYNC_TARGET' "$stderr_output" &&
    grep -Fq 'target resolves to the canonical provider home' "$stderr_output" || {
    printf 'runtime sync did not reject the resolved self-publish target:\n' >&2
    cat -- "$stderr_output" >&2
    exit 1
  }
  [ "$(sha256sum -- "$fixture_codex/CODEX.md" | awk '{print $1}')" = "$target_digest" ] || {
    printf 'runtime sync changed the resolved self-publish target before denial:\n' >&2
    exit 1
  }
}

assert_alternate_active_sync_refreshes_resolved_home_source() {
  local refreshed_digest refreshed_mode

  rm -f -- "$fixture_codex/.eci-runtime-sync-manifest"
  [ ! -e "$fixture_codex/.eci-runtime-sync-manifest" ] || {
    printf '%s\n' 'alternate active sync fixture could not clear the selected source receipt' >&2
    exit 1
  }
  HOME="$fixture_home" CODEX_HOME="$fixture_codex" CODEX_ROLE=coordinator CODEX_RUNTIME_ROOTS='' \
    "$alternate_codex/bin/eci-active" sync-runtime >"$output" 2>"$stderr_output" || {
    printf 'alternate launcher could not reconcile the resolved Codex source:\n' >&2
    cat -- "$output" >&2
    cat -- "$stderr_output" >&2
    exit 1
  }
  [ ! -s "$stderr_output" ] || {
    printf 'alternate launcher wrote unexpected sync advisory/error output:\n' >&2
    cat -- "$stderr_output" >&2
    exit 1
  }
  grep -Fq "ECI runtime source receipt refreshed: provider=codex source=$fixture_codex" "$output" || {
    printf 'alternate launcher did not report the resolved Codex source receipt refresh:\n' >&2
    cat -- "$output" >&2
    exit 1
  }
  refreshed_digest="$(sha256sum -- "$fixture_eci")"
  refreshed_digest="${refreshed_digest%% *}"
  refreshed_mode="$(stat -c '%a' -- "$fixture_eci")"
  grep -Fqx "$(printf 'bin/eci-active\t%s\t%s' "$refreshed_digest" "$refreshed_mode")" \
    "$fixture_codex/.eci-runtime-sync-manifest" || {
    printf 'alternate launcher did not refresh the resolved source receipt:\n' >&2
    cat -- "$fixture_codex/.eci-runtime-sync-manifest" >&2
    exit 1
  }
  [ ! -e "$alternate_codex/.eci-runtime-sync-manifest" ] || {
    printf 'alternate launcher refreshed its own unselected copy:\n' >&2
    exit 1
  }
}

assert_external_runtime_receipt_refresh() {
  local refreshed_digest refreshed_mode

  cp -- "$active_marker" "$TMP_ROOT/active-marker.before"
  # This simulates the trusted owner-side runtime deployment/receipt publish
  # outside PreToolUse. It is deliberately not a recovery route available to
  # the active hook itself.
  if ! HOME="$fixture_home" CODEX_HOME="$alternate_codex" CODEX_ROLE=coordinator \
    CODEX_PROOF_ROOT="$proof_root" CODEX_RUNTIME_ROOTS='' \
    "$fixture_eci" sync-runtime >"$output" 2>"$stderr_output"; then
    printf 'external runtime receipt refresh did not exit successfully:\n' >&2
    cat -- "$stderr_output" >&2
    exit 1
  fi
  [ ! -s "$stderr_output" ] || {
    printf 'external runtime receipt refresh wrote unexpected stderr:\n' >&2
    cat -- "$stderr_output" >&2
    exit 1
  }
  grep -Fq 'ECI runtime source receipt refreshed: provider=codex' "$output" || {
    printf 'external runtime receipt refresh did not report source receipt publication:\n' >&2
    cat -- "$output" >&2
    exit 1
  }
  refreshed_digest="$(sha256sum -- "$fixture_eci")"
  refreshed_digest="${refreshed_digest%% *}"
  refreshed_mode="$(stat -c '%a' -- "$fixture_eci")"
  grep -Fqx "bin/eci-active	$refreshed_digest	$refreshed_mode" \
    "$fixture_codex/.eci-runtime-sync-manifest" || {
    printf 'external runtime receipt refresh did not bind the changed eci-active digest:\n' >&2
    cat -- "$fixture_codex/.eci-runtime-sync-manifest" >&2
    exit 1
  }
  grep -Eq '^bin/eci-active-dispatch[[:space:]][0-9a-f]{64}[[:space:]][0-9]+$' \
    "$fixture_codex/.eci-runtime-sync-manifest" || {
    printf 'external runtime receipt refresh did not bind the dispatcher:\n' >&2
    cat -- "$fixture_codex/.eci-runtime-sync-manifest" >&2
    exit 1
  }
  [ ! -e "$alternate_codex/.eci-runtime-sync-manifest" ] || {
    printf 'external runtime receipt refresh selected inherited CODEX_HOME:\n' >&2
    exit 1
  }
  cmp -- "$TMP_ROOT/active-marker.before" "$active_marker" || {
    printf 'external runtime receipt refresh changed the active ECI marker:\n' >&2
    exit 1
  }
}

run_fixture_ledger_append() {
  local entry="$1"

  (
    cd "$ROOT"
    HOME="$fixture_home" CODEX_HOME="$fixture_codex" CODEX_ROLE=coordinator \
      CODEX_SESSION_ID=t00-help CODEX_PROOF_ROOT="$proof_root" \
      "$fixture_eci" ledger-append "$entry"
  ) >"$output" 2>"$stderr_output"
}

assert_ledger_append_bootstraps_empty_log_and_reconciles_regular_history() {
  local log="$proof_root/t00-help/high_level_log.md"
  local anchor="$proof_root/t00-help/high_level_log.anchor"
  local foreign="$TMP_ROOT/ledger-foreign-log"
  local log_before="$TMP_ROOT/ledger-log.before"
  local anchor_before="$TMP_ROOT/ledger-anchor.before"
  local log_bytes log_hash

  rm -f -- "$log" "$anchor" "$foreign"
  [ ! -e "$log" ] && [ ! -L "$log" ] && [ ! -e "$anchor" ] && [ ! -L "$anchor" ] || {
    printf '%s\n' 'ledger bootstrap fixture did not begin without log and anchor' >&2
    exit 1
  }
  if ! run_fixture_ledger_append 'empty-log-bootstrap-regression'; then
    printf '%s\n' 'ledger append did not bootstrap an empty log and anchor:' >&2
    cat -- "$stderr_output" >&2
    exit 1
  fi
  [ ! -s "$stderr_output" ] || {
    printf '%s\n' 'ledger bootstrap wrote unexpected stderr:' >&2
    cat -- "$stderr_output" >&2
    exit 1
  }
  [ -f "$log" ] && [ ! -L "$log" ] && [ -f "$anchor" ] && [ ! -L "$anchor" ] || {
    printf '%s\n' 'ledger bootstrap did not create regular log and anchor files' >&2
    exit 1
  }
  grep -Eq '^## [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z - empty-log-bootstrap-regression$' "$log" || {
    printf '%s\n' 'ledger bootstrap did not append the bounded entry at EOF' >&2
    cat -- "$log" >&2
    exit 1
  }
  log_bytes="$(wc -c <"$log")"
  log_hash="$(sha256sum -- "$log" | awk '{print $1}')"
  grep -Fqx 'schema: eci-high-level-log-anchor/v1' "$anchor" &&
    grep -Fqx "bytes: $log_bytes" "$anchor" &&
    grep -Fqx "sha256: $log_hash" "$anchor" || {
      printf '%s\n' 'ledger bootstrap anchor does not bind the appended log bytes' >&2
      cat -- "$anchor" >&2
      exit 1
    }

  rm -f -- "$log" "$anchor"
  printf '%s\n' foreign >"$foreign"
  ln -s -- "$foreign" "$log"
  if run_fixture_ledger_append 'symlink-log-must-fail'; then
    printf '%s\n' 'ledger append accepted a symlink log bootstrap target' >&2
    exit 1
  fi
  [ -L "$log" ] && [ ! -e "$anchor" ] && [ ! -L "$anchor" ] || {
    printf '%s\n' 'ledger append mutated the symlink-log bootstrap fixture' >&2
    exit 1
  }

  rm -f -- "$log"
  printf '%s\n' existing >"$log"
  printf '%s\n' malformed-anchor >"$anchor"
  if ! run_fixture_ledger_append 'malformed-anchor-reconciles'; then
    printf '%s\n' 'ledger append did not reconcile a malformed regular anchor:' >&2
    cat -- "$stderr_output" >&2
    exit 1
  fi
  [ -f "$anchor" ] && [ ! -L "$anchor" ] || {
    printf '%s\n' 'ledger append did not replace the malformed regular anchor' >&2
    exit 1
  }
  grep -Fqx 'schema: eci-high-level-log-anchor/v1' "$anchor" || {
    printf '%s\n' 'ledger append did not publish a reconciled anchor schema' >&2
    exit 1
  }
  grep -Fq 'malformed-anchor-reconciles' "$log" || {
    printf '%s\n' 'ledger append did not retain its ordinary entry after reconciliation' >&2
    exit 1
  }
  rm -f -- "$log" "$anchor" "$foreign"
}

assert_help_success --help
assert_help_success -h
assert_codex_help_examples_use_literal_home_path
assert_teardown_history_needs_no_lifecycle_recovery
assert_home_alias_help_success
assert_home_alias_context7_success
assert_kimi_help_success
assert_role_label_does_not_block_on_or_status
assert_runtime_sync_rejects_resolved_self_target
assert_alternate_active_sync_refreshes_resolved_home_source
write_current_planner_provenance
assert_worker_lifecycle_visibility_allowed
# Establish the missing-receipt fixture before testing the narrow escape hatches.
rm -f -- "$fixture_codex/.eci-runtime-sync-manifest"
assert_missing_runtime_receipt_escape_hatches
write_full_codex_runtime_receipt
assert_ledger_append_bootstraps_empty_log_and_reconciles_regular_history
assert_hook_allows_home_token_help '$HOME/.codex/bin/eci-active' --help
assert_hook_allows_home_token_help '$HOME/.codex/bin/eci-active' -h
assert_hook_allows_home_token_help '"$HOME/.codex/bin/eci-active"' --help
assert_hook_allows_home_token_help '"$HOME/.codex/bin/eci-active"' -h
assert_hook_allows_system_env_help '$HOME/.codex/bin/eci-active' --help
assert_hook_allows_system_env_help '"$HOME/.codex/bin/eci-active"' -h
assert_hook_allows_equivalent_lifecycle_target '"$HOME"/.codex/bin/eci-active --help' "$fake_bin:/usr/bin:/bin"
assert_hook_allows_equivalent_lifecycle_target '${HOME}/.codex/bin/eci-active --help' "$fake_bin:/usr/bin:/bin"
assert_hook_allows_equivalent_lifecycle_target '~/.codex/bin/eci-active --help' "$fake_bin:/usr/bin:/bin"
assert_hook_allows_equivalent_lifecycle_target "$fixture_eci --help" "$fake_bin:/usr/bin:/bin"
assert_hook_allows_equivalent_lifecycle_target 'eci-active --help' "$fixture_codex/bin:/usr/bin:/bin"
assert_hook_allows_equivalent_lifecycle_target 'env -- CODEX_SESSION_ID=t00-help "$HOME"/.codex/bin/eci-active --help' "$fixture_codex/bin:/usr/bin:/bin"
assert_hook_allows_read_only_lifecycle "$copy_eci --help"
assert_hook_allows_read_only_lifecycle "$copy_eci status"
assert_hook_allows_read_only_lifecycle '"$HOME/.kimi-code/bin/eci-active" --help'
assert_hook_allows_read_only_lifecycle '"$HOME/.kimi-code/bin/eci-active" status'
assert_hook_allows_read_only_lifecycle_with_path 'eci-active --help' "$fixture_kimi/bin:/usr/bin:/bin"
assert_hook_allows_read_only_lifecycle_with_path 'eci-active status' "$fixture_kimi/bin:/usr/bin:/bin"
assert_hook_allows_help_without_active_coordinator
assert_hook_defers_malformed_lifecycle_to_cli
assert_hook_does_not_treat_fake_env_as_system_env
assert_hook_allows_read_only_lifecycle '$HOME/.codex/bin/eci-active-dispatch --help'
assert_hook_allows_read_only_lifecycle 'eci-active-dispatch --help'
assert_hook_allows_read_only_lifecycle 'env -- CODEX_SESSION_ID=t00-help "$HOME/.codex/bin/eci-active-dispatch" --help'
assert_hook_allows_read_only_lifecycle 'eci-active --help' run_role_labeled_hook
assert_hook_denies_distinct_lifecycle_mutation
assert_stale_planner_uses_safe_fallback
assert_hook_allows_maintain_planner_bootstrap
restore_fresh_planner_artifact
assert_worker_lifecycle_visibility_allowed
assert_hook_executes_pinned_planner_after_path_replacement
assert_stale_runtime_receipt_deadlock_policy
assert_external_runtime_receipt_refresh
assert_hook_allows_home_token_help '$HOME/.codex/bin/eci-active' --help
assert_hook_allows_home_token_help '$HOME/.codex/bin/eci-active' -h
assert_hook_allows_home_token_help '"$HOME/.codex/bin/eci-active"' --help
assert_hook_allows_home_token_help '"$HOME/.codex/bin/eci-active"' -h
assert_hook_allows_system_env_help '$HOME/.codex/bin/eci-active' --help
assert_hook_allows_system_env_help '"$HOME/.codex/bin/eci-active"' -h

printf '%s\n' 'canonical current-home eci-active help assertions: PASS'
