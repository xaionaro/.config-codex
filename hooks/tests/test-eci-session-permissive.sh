#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TMP_ROOT="$(mktemp -d "${CODEX_TMPDIR:-${HOME:?}/tmp}/codex-session-permissive.XXXXXX")"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

export HOME="$TMP_ROOT/home"
export CODEX_HOME="$HOME/.codex"
export CODEX_PROOF_ROOT="$TMP_ROOT/proof"
export XDG_CONFIG_HOME="$TMP_ROOT/config"
session_id=t00-permissive
cwd="$TMP_ROOT/worktree"
other_cwd="$TMP_ROOT/other"
mkdir -p -- "$CODEX_HOME" "$CODEX_PROOF_ROOT/$session_id" "$XDG_CONFIG_HOME" "$cwd" "$other_cwd"
cp -a -- "$ROOT/bin" "$CODEX_HOME/bin"
cp -a -- "$ROOT/hooks" "$CODEX_HOME/hooks"

marker="$CODEX_PROOF_ROOT/$session_id/eci_active"
printf '%s\n' \
  'scope: session permissive test' \
  "cwd: $(realpath -e -- "$cwd")" \
  "session_id: $session_id" \
  'created_utc: 2026-08-25T00:00:00Z' >"$marker"
cp -- "$marker" "$TMP_ROOT/marker.before"

request='ordinary current-session recovery'
gate=validate-bash
operation=acceptance-boundary

. "$CODEX_HOME/hooks/lib/codex-proof-state.sh"

run_active() {
  CODEX_SESSION_ID="$session_id" CODEX_PROOF_ROOT="$CODEX_PROOF_ROOT" \
    CODEX_HOME="$CODEX_HOME" HOME="$HOME" "$CODEX_HOME/bin/eci-active" "$@"
}

# Direct activation creates a bounded state record; it does not require an
# auxiliary authorization file, fingerprint, or receipt.
run_active permissive-on session "$gate" "$operation" "$request" 300
record="$(codex_eci_session_permissive_record_path session "$session_id")"
[ -f "$record" ] && [ ! -L "$record" ]
[ "$(stat -c '%a' -- "$record")" = 600 ]
grep -q '^schema: eci-permissive-mode/v2$' "$record"
! grep -qE 'authorized_by|fingerprint|sha256|receipt' "$record"
codex_eci_session_permissive_active session "$session_id" "$cwd" "$gate" "$operation" "$request"
! codex_eci_session_permissive_active session "$session_id" "$other_cwd" "$gate" "$operation" "$request"
! codex_eci_session_permissive_active session "$session_id" "$cwd" other-gate "$operation" "$request"
grep -q '^ECI permissive mode active$' <<<"$(run_active permissive-status session "$gate" "$operation" "$request")"

# A malformed historical record is overwritten by direct activation for this
# live session instead of becoming a user-facing repair prerequisite.
printf '%s\n' 'historical malformed record' >"$record"
run_active permissive-on session "$gate" "$operation" "$request" 300
grep -q '^schema: eci-permissive-mode/v2$' "$record"

# Direct off removes malformed historical state and leaves the live marker
# untouched. It is scoped to the resolved current session, never another one.
printf '%s\n' 'historical malformed record' >"$record"
run_active permissive-off session "$gate" "$operation" "$request"
[ ! -e "$record" ] && [ ! -L "$record" ]
cmp -s "$TMP_ROOT/marker.before" "$marker"
grep -q '^ECI permissive mode inactive$' <<<"$(run_active permissive-status session "$gate" "$operation" "$request")"

# Global activation/off has the same direct lifecycle shape without a session
# authorization artifact.
run_active permissive-on global "$gate" "$operation" "$request" 300
global_record="$(codex_eci_session_permissive_record_path global '')"
[ -f "$global_record" ] && [ ! -L "$global_record" ]
codex_eci_session_permissive_active global unrelated-session "$other_cwd" "$gate" "$operation" "$request"
run_active permissive-off global "$gate" "$operation" "$request"
[ ! -e "$global_record" ] && [ ! -L "$global_record" ]

# Writer validation uses its captured issuance epoch, while later readers use
# their live clock. This deterministic fake date catches a TTL boundary
# without depending on sleep or scheduler timing.
fake_bin="$TMP_ROOT/fake-bin"
fake_counter="$TMP_ROOT/fake-date-counter"
mkdir -p -- "$fake_bin"
printf '%s\n' 0 >"$fake_counter"
cat >"$fake_bin/date" <<'EOF'
#!/usr/bin/env bash
count="$(cat -- "${ECI_FAKE_DATE_COUNTER:?}")"
case "$count" in
  0) printf '%s\n' 1 >"${ECI_FAKE_DATE_COUNTER:?}"; printf '%s\n' 100 ;;
  *) printf '%s\n' 101 ;;
esac
EOF
chmod 755 -- "$fake_bin/date"
PATH="$fake_bin:$PATH" ECI_FAKE_DATE_COUNTER="$fake_counter" \
  run_active permissive-on session "$gate" "$operation" "$request" 1
if PATH="$fake_bin:$PATH" ECI_FAKE_DATE_COUNTER="$fake_counter" \
  codex_eci_session_permissive_active session "$session_id" "$cwd" "$gate" "$operation" "$request"; then
  printf '%s\n' 'permissive reader accepted an expired TTL record' >&2
  exit 1
fi
[ ! -e "$record" ] && [ ! -L "$record" ]

printf '%s\n' 'session permissive lifecycle assertions: PASS'
