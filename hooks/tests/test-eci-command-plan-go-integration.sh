#!/usr/bin/env bash

set -euo pipefail

CODEX_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
KIMI_ROOT="${KIMI_CODE_HOME:-${HOME:?}/.kimi-code}"
TMP_ROOT="$(mktemp -d "${CODEX_TMPDIR:-${HOME:?}/tmp}/eci-command-plan-go.XXXXXX")"
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

mkdir -p "$TMP_ROOT/config/eci" "$TMP_ROOT/state"
chmod 700 "$TMP_ROOT/config" "$TMP_ROOT/config/eci" "$TMP_ROOT/state"
printf '%s\n' enforcing >"$TMP_ROOT/config/eci/command-gate-mode"
chmod 600 "$TMP_ROOT/config/eci/command-gate-mode"

make_marker() {
  local proof_root="$1" session_id="$2"
  mkdir -p "$proof_root/$session_id"
  printf '%s\n' \
    'scope: Go command-plan provider integration' \
    "cwd: $CODEX_ROOT" \
    "session_id: $session_id" \
    'created_utc: 2026-08-21T00:00:00Z' \
    >"$proof_root/$session_id/eci_active"
}

run_hook() {
  local provider="$1" command_text="$2" expected="$3" round="$4" denial_code="${5:-}"
  local detail_fragment="${6:-}" role="${7:-coordinator}" latency_limit_ms="${8:-1000}"
  local provider_root session_id proof_root output start_ns end_ns elapsed_ms subagent=false callback_path
  local -a callback

  case "$role" in
    coordinator) subagent=false ;;
    worker) subagent=true ;;
    *) return 2 ;;
  esac

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

  proof_root="$TMP_ROOT/$provider-proof"
  make_marker "$proof_root" "$session_id"
  output="$TMP_ROOT/$provider-$expected-$round.json"
  callback_path="$provider_root/bin:$PATH"
  if [ -n "${FAKE_GIT_BIN:-}" ]; then
    callback_path="$FAKE_GIT_BIN:$callback_path"
  fi
  start_ns="$(date +%s%N)"
  jq -cn \
    --arg session_id "$session_id" \
    --arg cwd "$CODEX_ROOT" \
    --arg command "$command_text" \
    '{session_id:$session_id,cwd:$cwd,tool_input:{command:$command}}' |
    HOME="$HOME" CODEX_HOME="$CODEX_ROOT" KIMI_CODE_HOME="$KIMI_ROOT" \
      CODEX_PROOF_ROOT="$proof_root" KIMI_PROOF_ROOT="$proof_root" \
      CODEX_HOOK_IS_SUBAGENT="$subagent" KIMI_HOOK_IS_SUBAGENT="$subagent" \
      CODEX_ROLE="$role" KIMI_ROLE="$role" \
      XDG_CONFIG_HOME="$TMP_ROOT/config" XDG_STATE_HOME="$TMP_ROOT/state" \
      PATH="$callback_path" CODEX_COMMAND_PATH="$callback_path" "${callback[@]}" >"$output"
  end_ns="$(date +%s%N)"
  elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))

  case "$expected" in
    allow)
      [ ! -s "$output" ]
      ;;
    deny)
      jq -e --arg code "[$denial_code]" '
        .hookSpecificOutput.permissionDecision == "deny" and
        (.hookSpecificOutput.permissionDecisionReason |
          contains($code))
      ' "$output" >/dev/null || {
        printf 'provider denial mismatch: provider=%s case=%s round=%s code=%s\n' \
          "$provider" "$expected" "$round" "$denial_code" >&2
        cat -- "$output" >&2
        return 1
      }
      ;;
    *) return 2 ;;
  esac
  if [ -n "$detail_fragment" ]; then
    jq -e --arg fragment "$detail_fragment" '
      .hookSpecificOutput.permissionDecisionReason | contains($fragment)
    ' "$output" >/dev/null || {
      printf 'provider detail mismatch: provider=%s round=%s fragment=%s\n' \
        "$provider" "$round" "$detail_fragment" >&2
      cat -- "$output" >&2
      return 1
    }
  fi
  if [ "$elapsed_ms" -ge "$latency_limit_ms" ]; then
    printf 'callback exceeded %s ms: provider=%s case=%s round=%s elapsed_ms=%s\n' \
      "$latency_limit_ms" "$provider" "$expected" "$round" "$elapsed_ms" >&2
    return 1
  fi
  printf 'provider=%s case=%s round=%s elapsed_ms=%s\n' \
    "$provider" "$expected" "$round" "$elapsed_ms"
}

for round in cold warm; do
  for provider in codex kimi; do
    run_hook "$provider" 'adb devices -l' allow "$round"
    run_hook "$provider" 'env | sort' deny "$round" ECI_ENVIRONMENT_ENUMERATION_DENIED
  done
done

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

printf 'Go command-plan provider integration tests passed\n'

assert_worker_fsck_helper_is_jq_only() {
  local helper
  helper="$(sed -n '/^worker_env_git_fsck_lost_found_shape() {/,/^if worker_env_git_fsck_lost_found_shape; then/p' \
    "$CODEX_ROOT/hooks/validate-bash.sh")"
  [[ "$helper" == *'.deferred_route == "worker-env-git-fsck-lost-found"'* ]] || return 1
  [[ "$helper" == *'.decision == "defer"'* ]] || return 1
  [[ "$helper" == *'.diagnostic == null'* ]] || return 1
  [[ "$helper" == *'(.capabilities // []) | length == 0'* ]] || return 1
  [[ "$helper" != *python3* ]] || return 1
  [[ "$helper" != *shlex* ]] || return 1
  [[ "$helper" != *environment_command_detail* ]] || return 1
  [[ "$helper" != *"token parser"* ]] || return 1
}

assert_worker_fsck_helper_is_jq_only

FAKE_GIT_BIN="$TMP_ROOT/fake-git-bin"
FAKE_GIT_SENTINEL="$TMP_ROOT/submitted-git-executed"
mkdir -p "$FAKE_GIT_BIN"
printf '%s\n' '#!/usr/bin/env bash' 'touch "$FAKE_GIT_SENTINEL"' >"$FAKE_GIT_BIN/git"
chmod 700 "$FAKE_GIT_BIN/git"
export FAKE_GIT_BIN FAKE_GIT_SENTINEL

run_codex_worker_fsck() {
  local command_text="$1" round="$2" denial_code="$3" detail_fragment="${4:-}"
  rm -f -- "$FAKE_GIT_SENTINEL"
  run_hook codex "$command_text" deny "$round" "$denial_code" "$detail_fragment" worker 5000
  [ ! -e "$FAKE_GIT_SENTINEL" ] || {
    printf 'submitted Git executable ran during callback: command=%s\n' "$command_text" >&2
    return 1
  }
}

for route_case in \
  'env git fsck --lost-found' \
  'env FOO=bar git fsck --lost-found' \
  'env -i git fsck --lost-found' \
  'env -u FOO git fsck --lost-found' \
  'env -C . git fsck --lost-found' \
  'env -- git fsck --lost-found' \
  "env git fsck '--lost-found'" \
  '"env" git fsck --lost-found' \
  'env "git" fsck --lost-found' \
  'env git "fsck" --lost-found'; do
  round="worker-route-${route_case//[^A-Za-z0-9]/-}"
  run_codex_worker_fsck "$route_case" "$round" ECI_WORKER_LAUNCHER_DENIED \
    worker-env-git-fsck-lost-found
done

for writer_case in \
  'git fsck --lost-found' \
  'git --no-pager fsck --lost-found' \
  '/usr/bin/git fsck --lost-found' \
  'env command git fsck --lost-found' \
  'env git -C . fsck --lost-found' \
  'env git --no-pager fsck --lost-found'; do
  round="worker-writer-${writer_case//[^A-Za-z0-9]/-}"
  run_codex_worker_fsck "$writer_case" "$round" ECI_WORKER_GIT_OWNERSHIP_DENIED
done

for context_case in \
  'git --git-dir=.git fsck --lost-found' \
  'git --work-tree=. fsck --lost-found' \
  'git --namespace=eci fsck --lost-found' \
  'git --exec-path=/usr/lib/git-core fsck --lost-found' \
  'git --config-env=foo=bar fsck --lost-found' \
  'env git --git-dir=.git fsck --lost-found' \
  'env git --work-tree=. fsck --lost-found' \
  'env git --namespace=eci fsck --lost-found' \
  'env git --exec-path=/usr/lib/git-core fsck --lost-found' \
  'env git --config-env=foo=bar fsck --lost-found'; do
  round="worker-context-${context_case//[^A-Za-z0-9]/-}"
  run_codex_worker_fsck "$context_case" "$round" ECI_GIT_EXECUTION_CONTEXT_DENIED
done

run_codex_worker_fsck 'env git fsck --lost-found=ignored' \
  worker-equals-form ECI_WORKER_LAUNCHER_DENIED

run_hook codex 'env git fsck --lost-found' deny worker-provider-codex \
  ECI_WORKER_LAUNCHER_DENIED worker-env-git-fsck-lost-found worker 5000
run_hook kimi 'env git fsck --lost-found' deny worker-provider-kimi \
  ECI_COMMAND_NOT_ALLOWLISTED '' worker 5000

printf 'Go command-plan fsck worker integration tests passed\n'
