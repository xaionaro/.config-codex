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
  local provider_root session_id proof_root output start_ns end_ns elapsed_ms
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

  proof_root="$TMP_ROOT/$provider-proof"
  make_marker "$proof_root" "$session_id"
  output="$TMP_ROOT/$provider-$expected-$round.json"
  start_ns="$(date +%s%N)"
  jq -cn \
    --arg session_id "$session_id" \
    --arg cwd "$CODEX_ROOT" \
    --arg command "$command_text" \
    '{session_id:$session_id,cwd:$cwd,tool_input:{command:$command}}' |
    HOME="$HOME" CODEX_HOME="$CODEX_ROOT" KIMI_CODE_HOME="$KIMI_ROOT" \
      CODEX_PROOF_ROOT="$proof_root" KIMI_PROOF_ROOT="$proof_root" \
      CODEX_HOOK_IS_SUBAGENT=false KIMI_HOOK_IS_SUBAGENT=false \
      CODEX_ROLE=coordinator KIMI_ROLE=coordinator \
      XDG_CONFIG_HOME="$TMP_ROOT/config" XDG_STATE_HOME="$TMP_ROOT/state" \
      PATH="$provider_root/bin:$PATH" "${callback[@]}" >"$output"
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
  if [ "$elapsed_ms" -ge 1000 ]; then
    printf 'callback exceeded 1000 ms: provider=%s case=%s round=%s elapsed_ms=%s\n' \
      "$provider" "$expected" "$round" "$elapsed_ms" >&2
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
