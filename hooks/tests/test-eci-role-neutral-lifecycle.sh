#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TMP_ROOT="$(mktemp -d "${CODEX_TMPDIR:-${HOME:?}/tmp}/codex-eci-role-neutral.XXXXXX")"
TMP_ROOT="$(realpath -e -- "$TMP_ROOT")"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

proof_root="$TMP_ROOT/proof"
cwd="$TMP_ROOT/repository"
other_cwd="$TMP_ROOT/other-repository"
nested_session=t00-role-neutral-nested
manifest_session=session-current
manifest_tmp="$TMP_ROOT"
manifest_source="$manifest_tmp/eci-required-critics.json.source"
mkdir -p -- "$proof_root" "$cwd" "$other_cwd"

run_worker() {
  local session_id="$1"
  shift
  (
    cd -- "$cwd"
    CODEX_PROOF_ROOT="$proof_root" CODEX_SESSION_ID="$session_id" \
      CODEX_ROLE=eci-implementer CODEX_HOOK_IS_SUBAGENT=true TMPDIR="$manifest_tmp" \
      "$ROOT/bin/eci-active" "$@"
  )
}

# A role label alone cannot deny direct nested lifecycle operations when they
# resolve to the caller's active session and marker-bound CWD.
run_worker "$nested_session" on 'role neutral nested lifecycle fixture' >"$TMP_ROOT/nested-on.out"
run_worker "$nested_session" nested-enter 1 1 "$nested_session" >"$TMP_ROOT/nested-enter.out"
[ -f "$proof_root/$nested_session/ate_nested_eci_active" ]
run_worker "$nested_session" nested-accept >"$TMP_ROOT/nested-accept.out"
[ -f "$proof_root/$nested_session/ate_nested_eci_completion" ]
run_worker "$nested_session" nested-exit >"$TMP_ROOT/nested-exit.out"
[ ! -e "$proof_root/$nested_session/ate_nested_eci_active" ]

# The CWD binding remains the actual boundary even for that role-neutral path.
if (
  cd -- "$other_cwd"
  CODEX_PROOF_ROOT="$proof_root" CODEX_SESSION_ID="$nested_session" \
    CODEX_ROLE=eci-implementer CODEX_HOOK_IS_SUBAGENT=true \
    "$ROOT/bin/eci-active" nested-enter 1 2 "$nested_session"
) >"$TMP_ROOT/wrong-cwd.out" 2>"$TMP_ROOT/wrong-cwd.err"; then
  printf '%s\n' 'role-neutral nested lifecycle accepted a wrong-CWD target' >&2
  exit 1
fi
[ ! -e "$proof_root/$nested_session/ate_nested_eci_active" ]

# Build a valid current-session manifest source using the existing focused
# fixture helper, then publish it from a worker-labelled direct session.
ECI_EMIT_CURRENT_MANIFEST=1 ECI_EMIT_PROOF_ROOT="$proof_root" \
  ECI_EMIT_KIND=root ECI_EMIT_SESSION_ID="$manifest_session" ECI_EMIT_SOURCE_PATH="$manifest_source" \
  TMPDIR="$manifest_tmp" bash "$ROOT/hooks/tests/test-eci-review-gate.sh" >/dev/null
[ -f "$manifest_source" ] && [ ! -L "$manifest_source" ]
jq -e . "$manifest_source" >/dev/null
jq -c . "$manifest_source" | cmp -s - "$manifest_source"
rm -f -- "$proof_root/$manifest_session/eci-required-critics.json"
run_worker "$manifest_session" on 'role neutral manifest publication fixture' >"$TMP_ROOT/manifest-on.out"
run_worker "$manifest_session" manifest-write "$manifest_source" >"$TMP_ROOT/manifest-write.out"
[ -f "$proof_root/$manifest_session/eci-required-critics.json" ]
cmp -s "$manifest_source" "$proof_root/$manifest_session/eci-required-critics.json"

printf '%s\n' 'eci role-neutral lifecycle assertions: PASS'
