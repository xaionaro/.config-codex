#!/usr/bin/env bash

set -euo pipefail

CODEX_ROOT="$(cd -- "${CODEX_HOME:-${HOME:?}/.codex}" && pwd -P)"
KIMI_ROOT="$(cd -- "${KIMI_CODE_HOME:-${HOME:?}/.kimi-code}" && pwd -P)"
INTEGRATION_NAME=hooks/tests/test-eci-command-plan-go-integration.sh
TMP_ROOT="$(mktemp -d "${HOME:?}/tmp/eci-command-plan-go-root-binding.XXXXXX")"
trap 'rm -rf -- "$TMP_ROOT"' EXIT
mkdir -p -- "$TMP_ROOT/config/eci" "$TMP_ROOT/state"
chmod 700 "$TMP_ROOT/config" "$TMP_ROOT/config/eci" "$TMP_ROOT/state"
printf '%s\n' enforcing >"$TMP_ROOT/config/eci/command-gate-mode"
chmod 600 "$TMP_ROOT/config/eci/command-gate-mode"

assert_binding_output() {
  local provider="$1" root="$2" output
  output="$(
    CODEX_HOME="$CODEX_ROOT" KIMI_CODE_HOME="$KIMI_ROOT" \
      bash "$root/$INTEGRATION_NAME" --print-root-binding
  )"
  grep -Fx "entrypoint_provider=$provider" <<<"$output" >/dev/null
  grep -Fx "entrypoint_root=$root" <<<"$output" >/dev/null
  grep -Fx "codex_root=$CODEX_ROOT" <<<"$output" >/dev/null
  grep -Fx "kimi_root=$KIMI_ROOT" <<<"$output" >/dev/null
}

assert_wrong_root_rejected() {
  local provider root wrong_var wrong_root output status
  provider="$1"
  root="$2"
  wrong_root="$3"
  wrong_var="$4"
  set +e
  output="$(
    if [ "$wrong_var" = CODEX_HOME ]; then
      CODEX_HOME="$wrong_root" KIMI_CODE_HOME="$KIMI_ROOT" \
        bash "$root/$INTEGRATION_NAME" --print-root-binding 2>&1
    else
      CODEX_HOME="$CODEX_ROOT" KIMI_CODE_HOME="$wrong_root" \
        bash "$root/$INTEGRATION_NAME" --print-root-binding 2>&1
    fi
  )"
  status=$?
  set -e
  [ "$status" -ne 0 ]
  grep -F 'ECI_PROVIDER_ROOT_BINDING_DENIED' <<<"$output" >/dev/null
  grep -F "provider=$provider" <<<"$output" >/dev/null
}

assert_marker_binding() {
  local provider="$1" root="$2" proof_root session marker_cwd marker_session marker output input
  proof_root="$TMP_ROOT/$provider-proof"
  session="root-binding-${provider}"
  mkdir -p -- "$proof_root/$session"
  chmod 700 "$proof_root" "$proof_root/$session"
  marker="$proof_root/$session/eci_active"
  marker_cwd="$3"
  marker_session="$4"
  printf '%s\n' \
    'scope: provider root-binding regression' \
    "cwd: $marker_cwd" \
    "session_id: $marker_session" \
    'created_utc: 2026-08-24T00:00:00Z' >"$marker"
  chmod 600 "$marker"
  input="$(jq -cn \
    --arg session "$session" \
    --arg cwd "$root" \
    '{session_id:$session,cwd:$cwd,tool_input:{command:"adb devices -l"}}')"
  output="$(
    printf '%s' "$input" |
      HOME="$HOME" CODEX_HOME="$CODEX_ROOT" KIMI_CODE_HOME="$KIMI_ROOT" \
      CODEX_PROOF_ROOT="$proof_root" KIMI_PROOF_ROOT="$proof_root" \
      CODEX_ROLE=coordinator KIMI_ROLE=coordinator \
      XDG_CONFIG_HOME="$TMP_ROOT/config" XDG_STATE_HOME="$TMP_ROOT/state" \
      PATH="$root/bin:$PATH" bash "$root/hooks/validate-bash.sh"
  )"
  if [ "$marker_cwd" = "$root" ] && [ "$marker_session" = "$session" ]; then
    [ -z "$output" ]
    return
  fi
  expected_code=ECI_MARKER_MALFORMED
  if [ "$provider" = codex ]; then
    if [ "$marker_cwd" != "$root" ]; then
      expected_code=ECI_MARKER_SCOPE_MISMATCH
    else
      expected_code=ECI_MARKER_OWNERSHIP_INVALID
    fi
  fi
  jq -e --arg code "[$expected_code]" '
    .hookSpecificOutput.permissionDecision == "deny" and
    (.hookSpecificOutput.permissionDecisionReason | contains($code))
  ' <<<"$output" >/dev/null || {
    printf 'marker binding diagnostic mismatch: provider=%s marker_cwd=%s marker_session=%s output=%s\n' \
      "$provider" "$marker_cwd" "$marker_session" "$output" >&2
    return 1
  }
}

assert_binding_output codex "$CODEX_ROOT"
assert_binding_output kimi "$KIMI_ROOT"
assert_wrong_root_rejected codex "$CODEX_ROOT" "$KIMI_ROOT" CODEX_HOME
assert_wrong_root_rejected kimi "$KIMI_ROOT" "$CODEX_ROOT" KIMI_CODE_HOME

# A standalone callback must bind its marker to its own provider root.  The
# companion root is deliberately used for the malformed cases, so a test that
# accidentally reuses Codex's cwd/session for Kimi cannot pass.
assert_marker_binding codex "$CODEX_ROOT" "$CODEX_ROOT" root-binding-codex
assert_marker_binding kimi "$KIMI_ROOT" "$KIMI_ROOT" root-binding-kimi
assert_marker_binding codex "$CODEX_ROOT" "$KIMI_ROOT" root-binding-codex
assert_marker_binding kimi "$KIMI_ROOT" "$CODEX_ROOT" root-binding-kimi
assert_marker_binding codex "$CODEX_ROOT" "$CODEX_ROOT" root-binding-other
assert_marker_binding kimi "$KIMI_ROOT" "$KIMI_ROOT" root-binding-other

printf 'ECI provider root-binding tests passed\n'
