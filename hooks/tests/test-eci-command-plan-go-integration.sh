#!/usr/bin/env bash

set -euo pipefail

ENTRYPOINT_ROOT="$(cd -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"

# This test is installed in both provider homes.  The entrypoint's physical
# root identifies the provider being exercised; the other provider is only a
# companion and must be selected through its provider-specific environment
# variable.  Do not infer either root by replacing `/home` with `/mnt` (or by
# treating the entrypoint root as both providers): those spellings can be
# aliases for the same filesystem and would silently bind a standalone Kimi
# run to Codex, which is exactly the integration failure this test guards.
resolve_companion_root() {
  local provider="$1" configured="$2" expected_basename="$3" resolved
  [ -n "$configured" ] || {
    printf 'ECI_PROVIDER_ROOT_BINDING_DENIED: provider=%s companion root is unset; expected basename=%s; remediation: set the provider-specific home variable to the canonical companion root\n' \
      "$provider" "$expected_basename" >&2
    exit 2
  }
  resolved="$(cd -- "$configured" 2>/dev/null && pwd -P)" || {
    printf 'ECI_PROVIDER_ROOT_BINDING_DENIED: provider=%s companion root is not a directory: configured=%s; remediation: use the canonical provider home\n' \
      "$provider" "$configured" >&2
    exit 2
  }
  [ "${resolved##*/}" = "$expected_basename" ] || {
    printf 'ECI_PROVIDER_ROOT_BINDING_DENIED: provider=%s companion root has wrong provider identity: resolved=%s expected_basename=%s; remediation: use the provider-matched companion root\n' \
      "$provider" "$resolved" "$expected_basename" >&2
    exit 2
  }
  printf '%s\n' "$resolved"
}

case "${ENTRYPOINT_ROOT##*/}" in
  .codex)
    ENTRYPOINT_PROVIDER=codex
    CODEX_ROOT="$ENTRYPOINT_ROOT"
    configured_kimi="${KIMI_CODE_HOME:-${HOME:?}/.kimi-code}"
    KIMI_ROOT="$(resolve_companion_root codex "$configured_kimi" .kimi-code)"
    ;;
  .kimi-code)
    ENTRYPOINT_PROVIDER=kimi
    KIMI_ROOT="$ENTRYPOINT_ROOT"
    configured_codex="${CODEX_HOME:-${HOME:?}/.codex}"
    CODEX_ROOT="$(resolve_companion_root kimi "$configured_codex" .codex)"
    ;;
  *)
    printf 'ECI_PROVIDER_ROOT_BINDING_DENIED: entrypoint root has no registered provider identity: resolved=%s; remediation: invoke the installed Codex or Kimi integration entrypoint\n' \
      "$ENTRYPOINT_ROOT" >&2
    exit 2
    ;;
esac

# An explicitly configured home for the provider that owns this entrypoint is
# also required to resolve to that entrypoint.  This catches a Kimi callback
# accidentally launched with CODEX_HOME (or the inverse) before any marker or
# command-plan assertions can be attributed to the wrong provider.
case "$ENTRYPOINT_PROVIDER" in
  codex)
    configured_own="${CODEX_HOME:-$ENTRYPOINT_ROOT}"
    ;;
  kimi)
    configured_own="${KIMI_CODE_HOME:-$ENTRYPOINT_ROOT}"
    ;;
esac
resolved_own="$(cd -- "$configured_own" 2>/dev/null && pwd -P)" || {
  printf 'ECI_PROVIDER_ROOT_BINDING_DENIED: provider=%s own root is not a directory: configured=%s; remediation: use the canonical entrypoint provider home\n' \
    "$ENTRYPOINT_PROVIDER" "$configured_own" >&2
  exit 2
}
[ "$resolved_own" = "$ENTRYPOINT_ROOT" ] || {
  printf 'ECI_PROVIDER_ROOT_BINDING_DENIED: provider=%s own root does not match entrypoint: entrypoint=%s configured=%s resolved=%s; remediation: invoke the hook from the matching provider home or correct its provider-specific home variable\n' \
    "$ENTRYPOINT_PROVIDER" "$ENTRYPOINT_ROOT" "$configured_own" "$resolved_own" >&2
  exit 2
}

if [ "${1:-}" = --print-root-binding ]; then
  printf 'entrypoint_provider=%s\nentrypoint_root=%s\ncodex_root=%s\nkimi_root=%s\n' \
    "$ENTRYPOINT_PROVIDER" "$ENTRYPOINT_ROOT" "$CODEX_ROOT" "$KIMI_ROOT"
  exit 0
fi

TMP_ROOT="$(mktemp -d "${CODEX_TMPDIR:-${HOME:?}/tmp}/eci-command-plan-go.XXXXXX")"
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

mkdir -p "$TMP_ROOT/config/eci" "$TMP_ROOT/state"
chmod 700 "$TMP_ROOT/config" "$TMP_ROOT/config/eci" "$TMP_ROOT/state"
printf '%s\n' enforcing >"$TMP_ROOT/config/eci/command-gate-mode"
chmod 600 "$TMP_ROOT/config/eci/command-gate-mode"

make_marker() {
  local proof_root="$1" session_id="$2" marker_cwd="$3"
  mkdir -p "$proof_root/$session_id"
  printf '%s\n' \
    'scope: Go command-plan provider integration' \
    "cwd: $marker_cwd" \
    "session_id: $session_id" \
    'created_utc: 2026-08-21T00:00:00Z' \
    >"$proof_root/$session_id/eci_active"
}

assert_worker_fsck_route_helper_is_go_only() {
  local helper_region
  helper_region="$(sed -n '/^worker_env_git_fsck_lost_found_shape() {/,/^if worker_env_git_fsck_lost_found_shape; then/p' \
    "$CODEX_ROOT/hooks/validate-bash.sh")"
  grep -Fq '.deferred_route == "worker-env-git-fsck-lost-found"' <<<"$helper_region" || {
    printf 'worker fsck helper does not assert the typed deferred route\n' >&2
    return 1
  }
  if grep -Eiq 'python3|shlex|environment_command_detail|token parser' <<<"$helper_region"; then
    printf 'worker fsck helper retains a forbidden parser dependency\n' >&2
    return 1
  fi
}

assert_worker_fsck_route_helper_is_go_only

run_hook() {
  local provider="$1" command_text="$2" expected="$3" round="$4" denial_code="${5:-}" role="${6:-coordinator}" max_elapsed_ms="${7:-2000}" required_text="${8:-}" forbidden_text="${9:-}"
  local provider_root session_id proof_root output start_ns end_ns elapsed_ms is_subagent marker_cwd callback_path callback_status
  local -a callback

  case "$provider" in
    codex)
      provider_root="$CODEX_ROOT"
      session_id=codex-go-integration
      callback=(bash -c 'exec "${CODEX_HOME:-$HOME/.codex}/hooks/validate-bash.sh"')
      ;;
    kimi)
      provider_root="$KIMI_ROOT"
      session_id=session_11111111-1111-4111-8111-111111111111
      callback=(bash -c 'exec "${KIMI_CODE_HOME:-$HOME/.kimi-code}/hooks/validate-bash.sh"')
      ;;
    *) return 2 ;;
  esac

  marker_cwd="$provider_root"

  is_subagent=false
  if [ "$role" = worker ]; then
    is_subagent=true
  fi

  proof_root="$TMP_ROOT/$provider-proof"
  make_marker "$proof_root" "$session_id" "$marker_cwd"
  output="$TMP_ROOT/$provider-$expected-$round.json"
  callback_path="$provider_root/bin:$PATH"
  if [ -n "${FAKE_GIT_BIN:-}" ]; then
    callback_path="$FAKE_GIT_BIN:$callback_path"
    rm -f -- "${FAKE_GIT_SENTINEL:?}"
  fi
  if [ -n "${FAKE_ENV_BIN:-}" ]; then
    callback_path="$FAKE_ENV_BIN:$callback_path"
    rm -f -- "${FAKE_ENV_SENTINEL:?}"
  fi
  start_ns="$(date +%s%N)"
  if jq -cn \
    --arg session_id "$session_id" \
    --arg cwd "$marker_cwd" \
    --arg command "$command_text" \
    '{session_id:$session_id,cwd:$cwd,tool_input:{command:$command}}' |
    HOME="$HOME" CODEX_HOME="$CODEX_ROOT" KIMI_CODE_HOME="$KIMI_ROOT" \
      CODEX_PROOF_ROOT="$proof_root" KIMI_PROOF_ROOT="$proof_root" \
      CODEX_HOOK_IS_SUBAGENT="$is_subagent" KIMI_HOOK_IS_SUBAGENT="$is_subagent" \
      CODEX_ROLE="$role" KIMI_ROLE="$role" \
      XDG_CONFIG_HOME="$TMP_ROOT/config" XDG_STATE_HOME="$TMP_ROOT/state" \
      PATH="$callback_path" CODEX_COMMAND_PATH="$callback_path" \
      bash -c 'cd -- "$1" && exec "${@:2}"' _ "$provider_root" "${callback[@]}" >"$output"; then
    :
  else
    callback_status=$?
    printf 'callback pipeline failed: provider=%s case=%s round=%s command=%s status=%s\n' \
      "$provider" "$expected" "$round" "$command_text" "$callback_status" >&2
    cat -- "$output" >&2
    return 1
  fi
  end_ns="$(date +%s%N)"
  elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))

  if [ -n "${FAKE_GIT_SENTINEL:-}" ] && [ -e "$FAKE_GIT_SENTINEL" ]; then
    printf 'submitted Git executable ran during callback: provider=%s round=%s command=%s\n' \
      "$provider" "$round" "$command_text" >&2
    return 1
  fi
  if [ -n "${FAKE_ENV_SENTINEL:-}" ] && [ -e "$FAKE_ENV_SENTINEL" ]; then
    printf 'submitted env executable ran during callback: provider=%s round=%s command=%s\n' \
      "$provider" "$round" "$command_text" >&2
    return 1
  fi

  case "$expected" in
    allow)
      [ ! -s "$output" ] || {
        printf 'provider unexpected allow output: provider=%s case=%s round=%s command=%s\n' \
          "$provider" "$expected" "$round" "$command_text" >&2
        cat -- "$output" >&2
        return 1
      }
      ;;
    deny)
      jq -e --arg code "[$denial_code]" --arg required "$required_text" --arg forbidden "$forbidden_text" '
        .hookSpecificOutput.permissionDecision == "deny" and
        (.hookSpecificOutput.permissionDecisionReason |
          contains($code)) and
        ($required == "" or (.hookSpecificOutput.permissionDecisionReason | contains($required))) and
        ($forbidden == "" or ((.hookSpecificOutput.permissionDecisionReason | contains($forbidden)) | not))
      ' "$output" >/dev/null || {
        printf 'provider denial mismatch: provider=%s case=%s round=%s code=%s\n' \
          "$provider" "$expected" "$round" "$denial_code" >&2
        cat -- "$output" >&2
        return 1
      }
      ;;
    deny-gate)
      jq -e '
        .hookSpecificOutput.permissionDecision == "deny" and
        (.hookSpecificOutput.permissionDecisionReason | startswith("[ECI_")) and
        (.hookSpecificOutput.permissionDecisionReason | contains("phase=PreToolUse")) and
        (.hookSpecificOutput.permissionDecisionReason | contains("operation="))
      ' "$output" >/dev/null || {
        printf 'provider legacy-gate denial mismatch: provider=%s case=%s round=%s\n' \
          "$provider" "$expected" "$round" >&2
        cat -- "$output" >&2
        return 1
      }
      ;;
    *) return 2 ;;
  esac
  if [ "$elapsed_ms" -ge "$max_elapsed_ms" ]; then
    printf 'callback exceeded %s ms: provider=%s case=%s round=%s elapsed_ms=%s\n' \
      "$max_elapsed_ms" "$provider" "$expected" "$round" "$elapsed_ms" >&2
    return 1
  fi
  printf 'provider=%s case=%s round=%s elapsed_ms=%s\n' \
    "$provider" "$expected" "$round" "$elapsed_ms"
}

if [ "${1:-}" != --git-clone-source-acquisition ]; then
  for round in cold warm; do
    for provider in codex kimi; do
      run_hook "$provider" 'adb devices -l' allow "$round"
      run_hook "$provider" "stat -c '%x %s %n' hooks/validate-bash.sh" allow "$round"
      run_hook "$provider" "stat -c '%Q' hooks/validate-bash.sh" deny "$round" ECI_PLAN_STAT_FORMAT_DENIED
      run_hook "$provider" "stat --printf='%s' hooks/validate-bash.sh" deny "$round" ECI_PLAN_STAT_FORMAT_DENIED
      run_hook "$provider" 'env | sort' deny "$round" ECI_ENVIRONMENT_ENUMERATION_DENIED
      run_hook "$provider" "interpreter-tool -c 'dynamic payload'" deny "$round" ECI_PLAN_DYNAMIC_LAUNCH_DENIED
      run_hook "$provider" 'interpreter-tool --module test-suite --flag value' allow "$round"
    done
  done
fi

# An active raw Git read is deliberately a status-3 planner result. The worker
# callback must therefore reach the provider's legacy gate and emit a
# structured denial rather than inherit generic literal admission.
assert_active_git_deferred() {
  local provider="$1" role="$2" command_text="$3"
  local provider_root session_id proof_root planner plan_output plan_status marker

  case "$provider" in
    codex)
      provider_root="$CODEX_ROOT"
      session_id=codex-go-git
      ;;
    kimi)
      provider_root="$KIMI_ROOT"
      session_id=session_22222222-2222-4222-8222-222222222222
      ;;
    *) return 2 ;;
  esac
  proof_root="$TMP_ROOT/$provider-git-proof"
  make_marker "$proof_root" "$session_id" "$provider_root"
  marker="$proof_root/$session_id/eci_active"
  planner="$provider_root/hooks/lib/eci-command-plan-go/eci-command-plan"
  if plan_output="$(
    jq -cn \
      --arg provider "$provider" \
      --arg role "$role" \
      --arg cwd "$provider_root" \
      --arg marker_state active \
      --arg session_id "$session_id" \
      --arg command "$command_text" \
      --args \
      '{provider:$provider,role:$role,cwd:$cwd,marker:$marker_state,active_session:$session_id,command:$command,active_markers:$ARGS.positional}' \
      "$marker" | "$planner" 2>/dev/null
  )"; then
    plan_status=0
  else
    plan_status=$?
  fi
  if [ "$plan_status" -ne 3 ]; then
    printf 'raw-Git planner did not defer: provider=%s role=%s status=%s command=%s output=%s\n' \
      "$provider" "$role" "$plan_status" "$command_text" "$plan_output" >&2
    return 1
  fi
  jq -e '
    .decision == "defer" and
    .diagnostic == null and
    ((.capabilities // []) | length == 0) and
    (.deferred_route // "") == ""
  ' <<<"$plan_output" >/dev/null || {
    printf 'raw-Git planner defer envelope mismatch: provider=%s role=%s command=%s output=%s\n' \
      "$provider" "$role" "$command_text" "$plan_output" >&2
    return 1
  }
}

# A direct Git clone is a source-acquisition capability. The callback must
# inspect only the planner result and executable identity; it must never run
# the submitted Git command.
assert_active_git_clone_source_acquisition() {
  local provider="$1" role="$2" command_text="$3" expected_launch="$4"
  local provider_root session_id proof_root planner plan_output plan_status marker

  case "$provider" in
    codex)
      provider_root="$CODEX_ROOT"
      session_id=codex-go-git-clone
      ;;
    kimi)
      provider_root="$KIMI_ROOT"
      session_id=session_33333333-3333-4333-8333-333333333333
      ;;
    *) return 2 ;;
  esac
  proof_root="$TMP_ROOT/$provider-git-clone-proof"
  make_marker "$proof_root" "$session_id" "$provider_root"
  marker="$proof_root/$session_id/eci_active"
  planner="$provider_root/hooks/lib/eci-command-plan-go/eci-command-plan"
  if plan_output="$(
    jq -cn \
      --arg provider "$provider" \
      --arg role "$role" \
      --arg cwd "$provider_root" \
      --arg marker_state active \
      --arg session_id "$session_id" \
      --arg command "$command_text" \
      --args \
      '{provider:$provider,role:$role,cwd:$cwd,marker:$marker_state,active_session:$session_id,command:$command,active_markers:$ARGS.positional}' \
      "$marker" | "$planner" 2>/dev/null
  )"; then
    plan_status=0
  else
    plan_status=$?
  fi
  if [ "$plan_status" -ne 0 ]; then
    printf 'Git clone planner did not allow source acquisition: provider=%s role=%s status=%s command=%s output=%s\n' \
      "$provider" "$role" "$plan_status" "$command_text" "$plan_output" >&2
    return 1
  fi
  jq -e --argjson expected_launch "$expected_launch" '
    .decision == "allow" and
    .diagnostic == null and
    (.deferred_route // "") == "" and
    (.capabilities == ["git-clone-source-acquisition"]) and
    .git_clone_launch == $expected_launch
  ' <<<"$plan_output" >/dev/null || {
    printf 'Git clone planner capability mismatch: provider=%s role=%s command=%s output=%s\n' \
      "$provider" "$role" "$command_text" "$plan_output" >&2
    return 1
  }
}

# run_git_clone_source_acquisition_cases exercises the typed planner result and
# the provider callback without ever executing a submitted clone command.
run_git_clone_source_acquisition_cases() {
  local provider role command_text launch_json launch_index
  local fake_git_bin fake_git_sentinel fake_env_bin fake_env_sentinel
  local -a admitted_commands=(
    'git clone --branch rust-v0.149.0 --depth 1 https://github.com/openai/codex.git /home/pheona/tmp/codex-stop-gate-src'
    'git clone --template=/templates/clone --reference=/cache/repository --shared --upload-pack=/usr/lib/git-core/git-upload-pack --future-clone-option source destination'
    "'git' clone source destination"
    '/usr/bin/git clone source destination'
    'command git clone source destination'
    'command -- /usr/bin/git clone source destination'
    'env git clone source destination'
    'env -- /usr/bin/git clone source destination'
  )
  local -a admitted_launches=(
    '{"class":"direct","git_argv_index":0,"git_executable":"git","environment_preserved":true}'
    '{"class":"direct","git_argv_index":0,"git_executable":"git","environment_preserved":true}'
    '{"class":"direct","git_argv_index":0,"git_executable":"git","environment_preserved":true}'
    '{"class":"direct","git_argv_index":0,"git_executable":"/usr/bin/git","environment_preserved":true}'
    '{"class":"command","git_argv_index":1,"git_executable":"git","environment_preserved":true}'
    '{"class":"command","git_argv_index":2,"git_executable":"/usr/bin/git","environment_preserved":true}'
    '{"class":"env","git_argv_index":1,"git_executable":"git","environment_preserved":true,"env_argv_index":0,"env_executable":"env"}'
    '{"class":"env","git_argv_index":2,"git_executable":"/usr/bin/git","environment_preserved":true,"env_argv_index":0,"env_executable":"env"}'
  )

  # The planner owns the entire literal clone argv. It records the semantic
  # launch class and literal executable tokens; clone options and operands
  # remain opaque to this hook. Parser-attested compound segments are
  # recursively validated through those same child routes.
  for provider in codex kimi; do
    for role in coordinator worker; do
      for launch_index in "${!admitted_commands[@]}"; do
        command_text="${admitted_commands[$launch_index]}"
        launch_json="${admitted_launches[$launch_index]}"
        assert_active_git_clone_source_acquisition "$provider" "$role" "$command_text" "$launch_json"
        run_hook "$provider" "$command_text" allow git-clone-source-acquisition '' "$role" 10000
      done

      run_hook "$provider" 'git clone source destination && printf after' \
        allow git-clone-source-acquisition-compound '' "$role" 10000

      for command_text in \
        'env FOO=bar git clone source destination' \
        'env -i git clone source destination' \
        'env -u HOME git clone source destination' \
        'env -C /tmp git clone source destination' \
        "env -S 'git clone source destination'" \
        'command -p git clone source destination' \
        'command -v git clone source destination' \
        'command -V git clone source destination' \
        'exec git clone source destination' \
        'sudo git clone source destination' \
        'systemd-run -- git clone source destination' \
        'nice git clone source destination' \
        'chronic git clone source destination' \
        'git -C /tmp clone source destination' \
        'git -c user.name=test clone source destination' \
        'git --git-dir=.git clone source destination'; do
        run_hook "$provider" "$command_text" deny-gate git-clone-non-capability '' "$role" 10000
      done
    done
  done

  fake_git_bin="$TMP_ROOT/fake-git-clone-bin"
  fake_git_sentinel="$TMP_ROOT/git-clone-submitted-executable-ran"
  mkdir -p "$fake_git_bin"
  printf '%s\n' '#!/usr/bin/env bash' 'touch "$FAKE_GIT_SENTINEL"' >"$fake_git_bin/git"
  chmod 700 "$fake_git_bin/git"
  FAKE_GIT_BIN="$fake_git_bin"
  FAKE_GIT_SENTINEL="$fake_git_sentinel"
  export FAKE_GIT_BIN FAKE_GIT_SENTINEL
  for provider in codex kimi; do
    for role in coordinator worker; do
      for command_text in \
        'git clone source destination' \
        "'git' clone source destination" \
        "$fake_git_bin/git clone source destination" \
        'command git clone source destination' \
        'env git clone source destination'; do
        run_hook "$provider" "$command_text" \
          deny git-clone-untrusted-git ECI_GIT_EXECUTION_CONTEXT_DENIED "$role" 10000 \
          'literal Git executable does not resolve to the established trusted Git executable'
      done
      run_hook "$provider" 'git clone source destination && printf after' \
        deny git-clone-compound-untrusted-git ECI_GIT_EXECUTION_CONTEXT_DENIED "$role" 10000 \
        'literal Git executable does not resolve to the established trusted Git executable'
    done
  done
  unset FAKE_GIT_BIN FAKE_GIT_SENTINEL

  fake_env_bin="$TMP_ROOT/fake-env-clone-bin"
  fake_env_sentinel="$TMP_ROOT/env-clone-submitted-executable-ran"
  mkdir -p "$fake_env_bin"
  printf '%s\n' '#!/usr/bin/env bash' 'touch "$FAKE_ENV_SENTINEL"' >"$fake_env_bin/env"
  chmod 700 "$fake_env_bin/env"
  FAKE_ENV_BIN="$fake_env_bin"
  FAKE_ENV_SENTINEL="$fake_env_sentinel"
  export FAKE_ENV_BIN FAKE_ENV_SENTINEL
  for provider in codex kimi; do
    for role in coordinator worker; do
      run_hook "$provider" 'env git clone source destination' \
        deny git-clone-untrusted-env ECI_GIT_EXECUTION_CONTEXT_DENIED "$role" 10000 \
        'literal env launcher does not resolve to the established trusted env executable'
    done
  done
  unset FAKE_ENV_BIN FAKE_ENV_SENTINEL
}

if [ "${1:-}" = --git-clone-source-acquisition ]; then
  run_git_clone_source_acquisition_cases
  printf 'Git clone source-acquisition provider integration test passed\n'
  exit 0
fi

for provider in codex kimi; do
  case "$provider" in
    codex) provider_root="$CODEX_ROOT" ;;
    kimi) provider_root="$KIMI_ROOT" ;;
  esac
  for role in coordinator worker; do
    for command_template in \
      'git status --short' \
      "'git' status --short" \
      '/usr/bin/git status --short' \
      'env FOO=bar git status --short' \
      'stdbuf -oL git status --short' \
      'busybox -- git status --short' \
      'chronic git status --short' \
      'systemd-run --unit eci git status --short' \
      'sudo -n git status --short' \
      'git -C __PROVIDER_ROOT__ status --short'; do
      command_text="${command_template//__PROVIDER_ROOT__/$provider_root}"
      assert_active_git_deferred "$provider" "$role" "$command_text"
      if [ "$provider" = kimi ]; then
        run_hook "$provider" "$command_text" deny raw-git-status-final \
          ECI_COMMAND_NOT_ALLOWLISTED "$role" 10000 \
          'operation=planner-deferred-provider-route'
      else
        # Codex retains its provider-specific terminal ownership denials.
        # This shared matrix still proves the planner's status-3 fall-through
        # without constraining that separate provider contract here.
        run_hook "$provider" "$command_text" deny-gate raw-git-status-legacy "$role" 10000
      fi
    done
  done
done

run_git_clone_source_acquisition_cases

# `git fsck --lost-found` writes dangling objects under .git/lost-found. The
# Codex worker planner owns the semantic writer denial for every form outside
# the one typed transparent-env route; Kimi keeps its existing adapter path.
FAKE_GIT_BIN="$TMP_ROOT/fake-git-bin"
FAKE_GIT_SENTINEL="$TMP_ROOT/submitted-git-executed"
mkdir -p "$FAKE_GIT_BIN"
printf '%s\n' '#!/usr/bin/env bash' 'touch "$FAKE_GIT_SENTINEL"' >"$FAKE_GIT_BIN/git"
chmod 700 "$FAKE_GIT_BIN/git"
export FAKE_GIT_BIN FAKE_GIT_SENTINEL
for provider in codex kimi; do
  direct_code=ECI_WORKER_COMMAND_NOT_ALLOWLISTED
  no_pager_code=ECI_WORKER_ACCEPTANCE_DENIED
  if [ "$provider" = codex ]; then
    direct_code=ECI_WORKER_GIT_OWNERSHIP_DENIED
    no_pager_code=ECI_WORKER_GIT_OWNERSHIP_DENIED
  fi
  if [ "$provider" = kimi ]; then
    direct_code=ECI_COMMAND_NOT_ALLOWLISTED
    no_pager_code=ECI_COMMAND_NOT_ALLOWLISTED
  fi
  run_hook "$provider" 'git fsck --lost-found' deny fsck-worker-raw "$direct_code" worker 10000
  run_hook "$provider" 'git --no-pager fsck --lost-found' deny fsck-worker-no-pager "$no_pager_code" worker 10000
done

# Only a direct, transparent env prefix may use the targeted worker wrapper
# boundary. Each accepted spelling still carries the planner defer/no-capability
# precondition; path-qualified, wrapped, and Git-global-option forms remain on
# their existing generic routes.
for provider in codex kimi; do
  if [ "$provider" = codex ]; then
    run_hook "$provider" 'env git fsck --lost-found' deny fsck-worker-env ECI_WORKER_LAUNCHER_DENIED worker 10000 \
      'predicate=worker-env-git-fsck-lost-found'
    run_hook "$provider" 'env FOO=bar BAR=baz git fsck --lost-found' deny fsck-worker-env-assignments ECI_WORKER_LAUNCHER_DENIED worker 10000 \
      'predicate=worker-env-git-fsck-lost-found'
    run_hook "$provider" 'env -i git fsck --lost-found' deny fsck-worker-env-ignore ECI_WORKER_LAUNCHER_DENIED worker 10000 \
      'predicate=worker-env-git-fsck-lost-found'
    run_hook "$provider" 'env -u FOO git fsck --lost-found' deny fsck-worker-env-unset ECI_WORKER_LAUNCHER_DENIED worker 10000 \
      'predicate=worker-env-git-fsck-lost-found'
    run_hook "$provider" 'env -C . git fsck --lost-found' deny fsck-worker-env-chdir ECI_WORKER_LAUNCHER_DENIED worker 10000 \
      'predicate=worker-env-git-fsck-lost-found'
    run_hook "$provider" 'env -- git fsck --full --lost-found --no-progress' deny fsck-worker-env-end-options ECI_WORKER_LAUNCHER_DENIED worker 10000 \
      'predicate=worker-env-git-fsck-lost-found'
    run_hook "$provider" 'env git fsck '\''--lost-found'\''' deny fsck-worker-env-quoted-option ECI_WORKER_LAUNCHER_DENIED worker 10000 \
      'predicate=worker-env-git-fsck-lost-found'
    run_hook "$provider" '"env" git fsck --lost-found' deny fsck-worker-env-quoted-name ECI_WORKER_LAUNCHER_DENIED worker 10000 \
      'predicate=worker-env-git-fsck-lost-found'
    run_hook "$provider" 'env "git" fsck --lost-found' deny fsck-worker-env-quoted-git ECI_WORKER_LAUNCHER_DENIED worker 10000 \
      'predicate=worker-env-git-fsck-lost-found'
    run_hook "$provider" 'env git "fsck" --lost-found' deny fsck-worker-env-quoted-fsck ECI_WORKER_LAUNCHER_DENIED worker 10000 \
      'predicate=worker-env-git-fsck-lost-found'
    run_hook "$provider" 'env /usr/bin/git fsck --lost-found' deny fsck-worker-path-git ECI_WORKER_GIT_OWNERSHIP_DENIED worker 10000 \
      'predicate=worker-git-ownership' ''
    run_hook "$provider" 'env command git fsck --lost-found' deny fsck-worker-wrapped-git ECI_WORKER_GIT_OWNERSHIP_DENIED worker 10000 \
      'predicate=worker-git-ownership'
    run_hook "$provider" 'env "command" git fsck --lost-found' deny fsck-worker-quoted-wrapped-git ECI_WORKER_GIT_OWNERSHIP_DENIED worker 10000 \
      'predicate=worker-git-ownership'
    run_hook "$provider" 'git --git-dir=.git fsck --lost-found' deny fsck-worker-context-attached ECI_GIT_EXECUTION_CONTEXT_DENIED worker 10000 \
      'predicate=git-execution-context'
    run_hook "$provider" 'env git --git-dir=.git fsck --lost-found' deny fsck-worker-env-context-attached ECI_GIT_EXECUTION_CONTEXT_DENIED worker 10000 \
      'predicate=git-execution-context'
    run_hook "$provider" 'env git --git-dir .git fsck --lost-found' deny fsck-worker-env-context-split ECI_GIT_EXECUTION_CONTEXT_DENIED worker 10000 \
      'predicate=git-execution-context'
    run_hook "$provider" 'env git --no-pager fsck --lost-found' deny fsck-worker-global-no-pager ECI_WORKER_GIT_OWNERSHIP_DENIED worker 10000 \
      'predicate=worker-git-ownership'
    run_hook "$provider" 'env git -C . fsck --lost-found' deny fsck-worker-global-context ECI_WORKER_GIT_OWNERSHIP_DENIED worker 10000 \
      'predicate=worker-git-ownership'
    run_hook "$provider" 'env git fsck --lost-found=ignored' allow fsck-worker-equals-ignored '' worker 10000
  else
    run_hook "$provider" 'env git fsck --lost-found' deny fsck-worker-env ECI_COMMAND_NOT_ALLOWLISTED worker 10000
    run_hook "$provider" 'env FOO=bar BAR=baz git fsck --lost-found' deny fsck-worker-env-assignments ECI_COMMAND_NOT_ALLOWLISTED worker 10000
    run_hook "$provider" 'env -i git fsck --lost-found' deny fsck-worker-env-ignore ECI_COMMAND_NOT_ALLOWLISTED worker 10000
    run_hook "$provider" 'env -u FOO git fsck --lost-found' deny fsck-worker-env-unset ECI_COMMAND_NOT_ALLOWLISTED worker 10000
    run_hook "$provider" 'env -C . git fsck --lost-found' deny fsck-worker-env-chdir ECI_COMMAND_NOT_ALLOWLISTED worker 10000
    run_hook "$provider" 'env -- git fsck --full --lost-found --no-progress' deny fsck-worker-env-end-options ECI_COMMAND_NOT_ALLOWLISTED worker 10000
    run_hook "$provider" 'env /usr/bin/git fsck --lost-found' deny fsck-worker-path-git ECI_WORKER_LAUNCHER_DENIED worker 10000
    run_hook "$provider" 'env command git fsck --lost-found' deny fsck-worker-wrapped-git ECI_COMMAND_NOT_ALLOWLISTED worker 10000
    run_hook "$provider" 'env git --no-pager fsck --lost-found' deny fsck-worker-global-no-pager ECI_COMMAND_NOT_ALLOWLISTED worker 10000
    run_hook "$provider" 'env git -C . fsck --lost-found' deny fsck-worker-global-context ECI_COMMAND_NOT_ALLOWLISTED worker 10000
    run_hook "$provider" 'env git fsck --lost-found=ignored' deny fsck-worker-equals-ignored ECI_COMMAND_NOT_ALLOWLISTED worker 10000
  fi
done
unset FAKE_GIT_BIN FAKE_GIT_SENTINEL

for provider in codex kimi; do
  case "$provider" in
    codex) session_id=codex-go-integration ;;
    kimi) session_id=session_11111111-1111-4111-8111-111111111111 ;;
  esac
  proof_root_alias="$TMP_ROOT/$provider-proof-alias"
  ln -s -- "$TMP_ROOT/$provider-proof" "$proof_root_alias"
  evidence_dir="$proof_root_alias/$session_id/evidence"
  outside_file="$TMP_ROOT/$provider-outside-proof.txt"
  mkdir -p "$evidence_dir"
  printf '%s\n' outside >"$outside_file"
  ln -s -- "$outside_file" "$evidence_dir/outside-link"
  run_hook "$provider" "cat $evidence_dir/outside-link" deny proof-escape \
    ECI_PROOF_PATH_ESCAPE_DENIED
done

# A planner-approved coordinator compound with a mutation must still reach the
# bounded ownership adapter instead of inheriting an earlier read-only allow.
compound_cleanup_target="$HOME/tmp/eci-command-plan-compound-${BASHPID}-cleanup"
compound_denied_target="$TMP_ROOT/eci-command-plan-compound-denied"
compound_touch_target="$HOME/tmp/eci-command-plan-compound-${BASHPID}-touch"
for provider in codex kimi; do
  run_hook "$provider" "realpath -e hooks/validate-bash.sh && rm -f $compound_cleanup_target" allow compound-approved
  run_hook "$provider" "realpath -e hooks/validate-bash.sh && rm -f $compound_denied_target" deny compound-denied \
    ECI_COMPOUND_MUTATION_DENIED
  run_hook "$provider" "realpath -e hooks/validate-bash.sh && touch $compound_touch_target" deny compound-touch-denied \
    ECI_COMPOUND_MUTATION_DENIED
  if [ "$provider" = kimi ]; then
    run_hook "$provider" 'git rev-parse HEAD && git status --short' deny raw-git-status-compound \
      ECI_COMMAND_NOT_ALLOWLISTED coordinator 10000 \
      'operation=planner-deferred-provider-route'
  else
    run_hook "$provider" 'git rev-parse HEAD && git status --short' deny-gate raw-git-status-compound
  fi
done

printf 'Go command-plan provider integration tests passed\n'
