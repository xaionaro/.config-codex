#!/usr/bin/env bash

# Lightweight contract/timing probe for the active-ECI stop path.  This is
# intentionally independent of the full formal hooks harness.
set -euo pipefail
test_bash="${BASH:?the running Bash shell must provide BASH}"
case "$test_bash" in
  /*) ;;
  *)
    printf 'running Bash path is not absolute: %s\n' "$test_bash" >&2
    exit 1
    ;;
esac
[ -x "$test_bash" ] || {
  printf 'running Bash path is not executable: %s\n' "$test_bash" >&2
  exit 1
}
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d "${CODEX_TMPDIR:-${HOME:?}/tmp}/codex-eci-fast.XXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT

proof_root="$tmp/proof"
# Keep a complete temporary Codex source under the test HOME.  Every hook and
# lifecycle invocation therefore uses the same literal HOME/.codex root while
# all test-only sessions and transcript paths stay isolated.
home="$tmp/home"
CODEX_ROOT="$home/.codex"
mkdir -p "$proof_root/t00-session" "$CODEX_ROOT"
cp -a -- "$ROOT/bin" "$CODEX_ROOT/bin"
cp -a -- "$ROOT/hooks" "$CODEX_ROOT/hooks"
export HOME="$home"
printf '%s\n' \
  'scope: fast-path probe' \
  "cwd: $ROOT" \
  'session_id: t00-session' \
  'created_utc: 2026-08-15T00:00:00Z' \
  >"$proof_root/t00-session/eci_active"
cp -- "$proof_root/t00-session/eci_active" "$tmp/direct-marker.before"

input="$tmp/input.json"
out="$tmp/out.json"
jq -n --arg cwd "$ROOT" '{session_id:"t00-session", transcript_path:"", stop_hook_active:false, cwd:$cwd}' >"$input"

# The source configuration is an authority boundary: exercise the exact Stop
# launcher instead of only invoking the script directly under the fixture HOME.
configured_stop_launcher="bash -lc 'exec \"\$HOME/.codex/hooks/stop-gate.sh\"'"
jq -e --arg expected "$configured_stop_launcher" '
  [.hooks.Stop[]?.hooks[]?.command] == [$expected]
' "$ROOT/hooks.json" >/dev/null
configured_launcher_root="$tmp/configured-launcher-proof"
configured_launcher_session=t00-configured-launcher
configured_launcher_marker="$configured_launcher_root/$configured_launcher_session/eci_active"
configured_launcher_input="$tmp/configured-launcher-input.json"
configured_launcher_out="$tmp/configured-launcher-output.json"
mkdir -p "$configured_launcher_root/$configured_launcher_session"
printf 'scope: configured launcher probe\ncwd: %s\nsession_id: %s\n' \
  "$ROOT" "$configured_launcher_session" >"$configured_launcher_marker"
cp -- "$configured_launcher_marker" "$tmp/configured-launcher-marker.before"
jq -cn --arg cwd "$ROOT" --arg session_id "$configured_launcher_session" \
  '{session_id:$session_id,transcript_path:"",stop_hook_active:false,cwd:$cwd}' \
  >"$configured_launcher_input"
env -u BASH_ENV -u ENV -u CODEX_HOME -u CODEX_ROLE HOME="$home" \
  CODEX_PROOF_ROOT="$configured_launcher_root" \
  bash -lc 'exec "$HOME/.codex/hooks/stop-gate.sh"' \
  <"$configured_launcher_input" >"$configured_launcher_out"
jq -s -e '
  length == 1 and
  .[0].decision == "block" and
  ((.[0] | keys | sort) == ["decision", "reason"]) and
  (.[0].continue? != false) and
  ((.[0].reason // "") | contains("[ECI_STOP_ACTIVE_ECI]"))
' "$configured_launcher_out" >/dev/null || {
  cat "$configured_launcher_out" >&2
  exit 1
}
cmp -s "$tmp/configured-launcher-marker.before" "$configured_launcher_marker"

# A same-cwd peer remains authoritative even when accidental permission loss
# makes its session directory non-searchable. Run the actual hook as the
# non-root, capability-free test user so directory permissions are meaningful.
nonsearchable_peer_root="$tmp/nonsearchable-peer-root"
nonsearchable_peer_session=t00-nonsearchable-peer
nonsearchable_callback_session=t00-nonsearchable-callback
nonsearchable_peer_dir="$nonsearchable_peer_root/$nonsearchable_peer_session"
nonsearchable_peer_marker="$nonsearchable_peer_dir/eci_active"
nonsearchable_peer_input="$tmp/nonsearchable-peer-input.json"
nonsearchable_peer_out="$tmp/nonsearchable-peer-output.json"
nonsearchable_test_euid="$(id -u)"
nonsearchable_test_cap_eff="$(awk '/^CapEff:/ { print $2 }' /proc/self/status)"
[ "$nonsearchable_test_euid" -ne 0 ] || {
  printf '%s\n' 'non-searchable peer proof requires a non-root effective user' >&2
  exit 1
}
[ "$nonsearchable_test_cap_eff" = 0000000000000000 ] || {
  printf 'non-searchable peer proof requires no effective capabilities, got %s\n' \
    "$nonsearchable_test_cap_eff" >&2
  exit 1
}
mkdir -p "$nonsearchable_peer_dir"
printf 'scope: non-searchable same-cwd peer\ncwd: %s\nsession_id: %s\n' \
  "$ROOT" "$nonsearchable_peer_session" >"$nonsearchable_peer_marker"
cp -- "$nonsearchable_peer_marker" "$tmp/nonsearchable-peer-marker.before"
jq -cn --arg cwd "$ROOT" --arg session_id "$nonsearchable_callback_session" \
  '{session_id:$session_id,transcript_path:"",stop_hook_active:false,cwd:$cwd}' \
  >"$nonsearchable_peer_input"
[ ! -e "$nonsearchable_peer_root/$nonsearchable_callback_session/eci_active" ]
nonsearchable_peer_mode="$(stat -c %a "$nonsearchable_peer_dir")"
chmod u-x "$nonsearchable_peer_dir"
[ ! -x "$nonsearchable_peer_dir" ] || {
  chmod "$nonsearchable_peer_mode" "$nonsearchable_peer_dir"
  printf '%s\n' 'non-searchable peer directory retained search permission' >&2
  exit 1
}
if ! env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$nonsearchable_peer_root" \
  bash "$CODEX_ROOT/hooks/stop-gate.sh" <"$nonsearchable_peer_input" >"$nonsearchable_peer_out"; then
  chmod "$nonsearchable_peer_mode" "$nonsearchable_peer_dir"
  exit 1
fi
chmod "$nonsearchable_peer_mode" "$nonsearchable_peer_dir"
jq -s -e '
  length == 1 and
  .[0].decision == "block" and
  ((.[0] | has("continue")) | not) and
  ((.[0].reason // "") | contains("[ECI_STOP_MARKER_SCAN_UNSAFE]"))
' "$nonsearchable_peer_out" >/dev/null || {
  printf '%s\n' 'non-searchable same-cwd peer incorrectly exposed raw continuation:' >&2
  cat "$nonsearchable_peer_out" >&2
  exit 1
}
cmp -s "$tmp/nonsearchable-peer-marker.before" "$nonsearchable_peer_marker"

# An unreadable empty peer directory is equally unsafe: marker discovery must
# fail closed instead of treating the namespace as empty.
nonsearchable_empty_root="$tmp/nonsearchable-empty-root"
nonsearchable_empty_dir="$nonsearchable_empty_root/t00-nonsearchable-empty"
nonsearchable_empty_input="$tmp/nonsearchable-empty-input.json"
nonsearchable_empty_out="$tmp/nonsearchable-empty-output.json"
mkdir -p "$nonsearchable_empty_dir"
jq -cn --arg cwd "$ROOT" \
  '{session_id:"t00-nonsearchable-empty-callback",transcript_path:"",stop_hook_active:false,cwd:$cwd}' \
  >"$nonsearchable_empty_input"
nonsearchable_empty_mode="$(stat -c %a "$nonsearchable_empty_dir")"
chmod u-x "$nonsearchable_empty_dir"
[ ! -x "$nonsearchable_empty_dir" ] || {
  chmod "$nonsearchable_empty_mode" "$nonsearchable_empty_dir"
  printf '%s\n' 'non-searchable empty directory retained search permission' >&2
  exit 1
}
if ! env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$nonsearchable_empty_root" \
  bash "$CODEX_ROOT/hooks/stop-gate.sh" <"$nonsearchable_empty_input" >"$nonsearchable_empty_out"; then
  chmod "$nonsearchable_empty_mode" "$nonsearchable_empty_dir"
  exit 1
fi
chmod "$nonsearchable_empty_mode" "$nonsearchable_empty_dir"
jq -s -e '
  length == 1 and
  .[0].decision == "block" and
  ((.[0] | has("continue")) | not) and
  ((.[0].reason // "") | contains("[ECI_STOP_MARKER_SCAN_UNSAFE]"))
' "$nonsearchable_empty_out" >/dev/null || {
  printf '%s\n' 'non-searchable empty directory incorrectly exposed raw continuation:' >&2
  cat "$nonsearchable_empty_out" >&2
  exit 1
}
printf '%s\n' 'PASS non-searchable peer and empty-directory scan guards'

write_wait_report() {
  local report="$1" blocker_id="$2"

  {
    printf '# ECI User-Owned Wait\n'
    printf 'state: user-owned-wait\n'
    printf 'blocker_id: %s\n' "$blocker_id"
    printf 'state_fingerprint: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'
    printf 'owner: user\n'
    printf 'brp_result: exhausted-no-feasible-internal-path\n'
    printf 'user_owned_input: unobtainable\n'
    printf 'unblock_kind: input\n'
    printf 'unblock: user-owned input required\n'
  } >"$report"
}

# The bounded-marker preflight runs before the later direct-marker helper is
# declared. An oversized direct marker must still produce the concrete
# malformed-marker block without leaking a masked Bash command-not-found
# diagnostic on stderr.
oversized_root="$tmp/oversized-marker-root"
oversized_err="$tmp/oversized-marker.err"
mkdir -p "$oversized_root/t00-session"
{
  printf '%s\n' 'scope: oversized direct marker'
  printf 'cwd: %s\n' "$ROOT"
  printf '%s\n' 'session_id: t00-session'
  printf 'created_utc: '
  head -c 5000 /dev/zero | tr '\0' x
  printf '\n'
} >"$oversized_root/t00-session/eci_active"
env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$oversized_root" \
  bash "$CODEX_ROOT/hooks/stop-gate.sh" <"$input" >"$out" 2>"$oversized_err"
[ ! -s "$oversized_err" ] || {
  cat "$oversized_err" >&2
  exit 1
}
[ "$(jq -r '.decision // empty' "$out")" = block ]
jq -e '.reason | contains("[ECI_MARKER_MALFORMED]")' "$out" >/dev/null

# The callback path must not recurse through arbitrary proof-root descendants.
# Keep this structural assertion beside a non-marker directory stress fixture.
grep -Fq 'eci_stop_max_markers=' "$CODEX_ROOT/hooks/stop-gate.sh"
grep -Fq 'eci_stop_max_namespace_entries=' "$CODEX_ROOT/hooks/stop-gate.sh"
grep -Fq '__ECI_STOP_MARKER_NAMESPACE_OVERFLOW__' "$CODEX_ROOT/hooks/stop-gate.sh"
grep -Fq 'The hook records that reminder and returns `{"continue":true}` for identical unchanged callbacks' "$ROOT/CODEX.md"
grep -Fq 'Its normalized state then returns `{"continue":true}` for identical callbacks' "$ROOT/skills/references/workflow-runtime/stop-recovery.md"
non_marker_root="$tmp/non-marker-root"
mkdir -p "$non_marker_root"
for i in $(seq 1 2000); do
  mkdir -p "$non_marker_root/t00-no-marker-$i"
done
jq -n --arg cwd "$ROOT" \
  '{session_id:"t00-no-marker-caller",transcript_path:"",stop_hook_active:false,cwd:$cwd}' >"$input"
timeout 1s env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$non_marker_root" \
  bash "$CODEX_ROOT/hooks/stop-gate.sh" <"$input" >"$out"
[ "$(jq -r '.continue // empty' "$out")" = true ]
[ ! -e "$non_marker_root/t00-no-marker-caller" ]
[ ! -e "$non_marker_root/t00-no-marker-caller/stop_loop_state" ]
namespace_entry_limit=4096
namespace_overflow_root="$tmp/namespace-overflow-root"
namespace_overflow_callback_session=t00-namespace-overflow-caller
namespace_overflow_expected_entry_count=$((namespace_entry_limit + 1))
namespace_overflow_input="$tmp/namespace-overflow-input.json"
namespace_overflow_out="$tmp/namespace-overflow-output.json"
namespace_overflow_contaminated_out="$tmp/namespace-overflow-contaminated-output.json"
namespace_overflow_bash_env="$tmp/namespace-overflow-bash-env.sh"
namespace_overflow_direct_marker="$namespace_overflow_root/$namespace_overflow_callback_session/eci_active"
namespace_overflow_direct_loop_state="$proof_root/t00-session/stop_loop_state"
namespace_overflow_startup_status='BASH_ENV=unset ENV=unset CODEX_HOME=unset CODEX_ROLE=unset'

namespace_overflow_runtime_matches_source() {
  cmp -s "$ROOT/hooks/stop-gate.sh" "$CODEX_ROOT/hooks/stop-gate.sh" &&
    cmp -s "$ROOT/hooks/lib/codex-proof-state.sh" "$CODEX_ROOT/hooks/lib/codex-proof-state.sh" &&
    cmp -s "$ROOT/hooks/lib/codex-tmp.sh" "$CODEX_ROOT/hooks/lib/codex-tmp.sh" &&
    cmp -s "$ROOT/hooks/lib/eci-diagnostic.sh" "$CODEX_ROOT/hooks/lib/eci-diagnostic.sh"
}

namespace_overflow_provenance_failure() {
  local source_copy_equal=no direct_marker_absent=no

  if namespace_overflow_runtime_matches_source; then
    source_copy_equal=yes
  fi
  if [ ! -e "$namespace_overflow_direct_marker" ] && [ ! -L "$namespace_overflow_direct_marker" ]; then
    direct_marker_absent=yes
  fi
  printf '%s\n' 'namespace-overflow provenance:' >&2
  printf 'expected_root: %s\n' "$namespace_overflow_root" >&2
  printf 'callback_session: %s\n' "$namespace_overflow_callback_session" >&2
  printf 'entry_count: %s\n' "${namespace_overflow_actual_entry_count:-unavailable}" >&2
  printf 'direct_marker_absent: %s\n' "$direct_marker_absent" >&2
  printf 'source_copy_equal: %s\n' "$source_copy_equal" >&2
  printf 'bash_path: %s\n' "$test_bash" >&2
  printf 'bash_version: %s\n' "$BASH_VERSION" >&2
  printf 'startup_vars: %s\n' "$namespace_overflow_startup_status" >&2
  printf '%s\n' 'input:' >&2
  head -c 4096 -- "$namespace_overflow_input" >&2
  printf '\n%s\n' 'output:' >&2
  head -c 4096 -- "$namespace_overflow_out" >&2
  printf '\n' >&2
  exit 1
}

mkdir -p "$namespace_overflow_root"
for i in $(seq 1 "$namespace_overflow_expected_entry_count"); do
  mkdir -p "$namespace_overflow_root/t00-namespace-entry-$i"
done
namespace_overflow_actual_entry_count="$(find "$namespace_overflow_root" -mindepth 1 -maxdepth 1 -printf . | wc -c | tr -d '[:space:]')"
jq -n --arg cwd "$ROOT" --arg session_id "$namespace_overflow_callback_session" \
  '{session_id:$session_id,transcript_path:"",stop_hook_active:false,cwd:$cwd}' \
  >"$namespace_overflow_input"
[ "$namespace_overflow_actual_entry_count" -eq "$namespace_overflow_expected_entry_count" ] || {
  namespace_overflow_provenance_failure
}
[ ! -e "$namespace_overflow_direct_marker" ] && [ ! -L "$namespace_overflow_direct_marker" ] || {
  namespace_overflow_provenance_failure
}
namespace_overflow_runtime_matches_source || {
  namespace_overflow_provenance_failure
}
printf '%s\n' '# test-only copied-helper drift' >>"$CODEX_ROOT/hooks/lib/codex-tmp.sh"
if namespace_overflow_runtime_matches_source; then
  printf '%s\n' 'namespace-overflow runtime verifier missed copied-helper drift' >&2
  exit 1
fi
cp -- "$ROOT/hooks/lib/codex-tmp.sh" "$CODEX_ROOT/hooks/lib/codex-tmp.sh"
namespace_overflow_runtime_matches_source || {
  namespace_overflow_provenance_failure
}

# An unsanitized noninteractive Bash child obeys BASH_ENV. This control proves
# that startup contamination is observable by forcing the known direct marker.
[ ! -e "$namespace_overflow_direct_loop_state" ] || {
  printf '%s\n' 'namespace-overflow control found pre-existing direct loop state' >&2
  exit 1
}
printf 'export CODEX_PROOF_ROOT=%q\n' "$proof_root" >"$namespace_overflow_bash_env"
if ! BASH_ENV="$namespace_overflow_bash_env" env -u CODEX_HOME -u CODEX_ROLE HOME="$home" \
  CODEX_PROOF_ROOT="$namespace_overflow_root" "$test_bash" "$CODEX_ROOT/hooks/stop-gate.sh" \
  <"$namespace_overflow_input" >"$namespace_overflow_contaminated_out"; then
  printf '%s\n' 'namespace-overflow BASH_ENV contamination control did not run' >&2
  exit 1
fi
jq -s -e --arg marker "$proof_root/t00-session/eci_active" '
  length == 1 and
  .[0].decision == "block" and
  ((.[0] | has("continue")) | not) and
  ((.[0].reason // "") | contains($marker))
' "$namespace_overflow_contaminated_out" >/dev/null || {
  printf '%s\n' 'namespace-overflow BASH_ENV contamination control did not select the direct marker:' >&2
  head -c 4096 -- "$namespace_overflow_contaminated_out" >&2
  printf '\n' >&2
  exit 1
}
cmp -s "$tmp/direct-marker.before" "$proof_root/t00-session/eci_active"
rm -f -- "$namespace_overflow_direct_loop_state"

# The tested child must run the copied runtime under the configured overflow
# root, with noninteractive startup files and source-selection overrides gone.
namespace_overflow_runtime_matches_source || {
  namespace_overflow_provenance_failure
}
if ! timeout 2s env -u BASH_ENV -u ENV -u CODEX_HOME -u CODEX_ROLE HOME="$home" \
  CODEX_PROOF_ROOT="$namespace_overflow_root" "$test_bash" "$CODEX_ROOT/hooks/stop-gate.sh" \
  <"$namespace_overflow_input" >"$namespace_overflow_out"; then
  namespace_overflow_provenance_failure
fi
jq -s -e '
  length == 1 and
  .[0].decision == "block" and
  ((.[0] | has("continue")) | not) and
  ((.[0].reason // "") | contains("[ECI_STOP_MARKER_SCAN_UNSAFE]"))
' "$namespace_overflow_out" >/dev/null || {
  namespace_overflow_provenance_failure
}
printf '%s\n' 'PASS namespace-overflow provenance isolation'
jq -n --arg cwd "$ROOT" '{session_id:"t00-session", transcript_path:"", stop_hook_active:false, cwd:$cwd}' >"$input"

# An inherited helper override must not redirect Stop away from the configured
# proof root.  The canonical active marker remains authoritative.
override_root="$tmp/stop-gate-override-root"
mkdir -p "$override_root"
env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$proof_root" CODEX_STOP_GATE_ROOT="$override_root" \
  bash "$CODEX_ROOT/hooks/stop-gate.sh" <"$input" >"$out"
[ "$(jq -r '.decision // empty' "$out")" = block ]
jq -e '.reason |
  contains("[ECI_STOP_ACTIVE_ECI]") and
  contains("valid and bound") and
  contains("no marker repair") and
  contains("The marker remains authoritative") and
  contains("Resume actual active ECI work or complete valid normal teardown") and
  contains("Do not retry unchanged Stop") and
  (contains("delegate the next bounded work item") | not) and
  (contains("wait for and collect its result") | not) and
  (contains("do not finish this turn") | not) and
  (contains("do not emit another final/status/question") | not)' "$out" >/dev/null

# The override callback above is an independent assertion. Republish the
# marker before timing the ordinary direct-marker sequence so generation reset
# is part of the contract rather than an accidental carry-over.
cp -- "$proof_root/t00-session/eci_active" "$tmp/direct-marker.timing-reset"
mv -- "$tmp/direct-marker.timing-reset" "$proof_root/t00-session/eci_active"

run_active_once() {
  env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$proof_root" \
    bash "$CODEX_ROOT/hooks/stop-gate.sh" <"$input" >"$out"
}

run_once() {
  run_active_once
  [ "$(jq -r '.decision // empty' "$out")" = block ]
}

assert_active_result() {
  jq -e '
    .decision == "block" and
    (has("continue") | not)
  ' "$out" >/dev/null
}

# A normal direct Stop gives one useful reminder. A validated recursive
# callback with the same unchanged marker follows with stable continuation.
printf '%s\n' '{"continue":true}' >"$tmp/expected-continue.json"
run_once
direct_loop_state="$proof_root/t00-session/stop_loop_state"
[ -f "$direct_loop_state" ]
grep -qx 'count: 1' "$direct_loop_state"
grep -qx 'loop_emitted: true' "$direct_loop_state"
cp -- "$direct_loop_state" "$tmp/direct-loop.after-first"
direct_recursive_input="$tmp/direct-recursive-input.json"
direct_recursive_out="$tmp/direct-recursive-out.json"
jq -cn --arg cwd "$ROOT" \
  '{session_id:"t00-session",transcript_path:"",stop_hook_active:true,cwd:$cwd}' \
  >"$direct_recursive_input"
env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$proof_root" \
  bash "$CODEX_ROOT/hooks/stop-gate.sh" <"$direct_recursive_input" >"$direct_recursive_out"
jq -e '.continue == true and (has("decision") | not)' "$direct_recursive_out" >/dev/null || {
  cat "$direct_recursive_out" >&2
  exit 1
}
cmp -s "$tmp/direct-marker.before" "$proof_root/t00-session/eci_active"
cmp -s "$tmp/direct-loop.after-first" "$direct_loop_state"

assert_stop_loop_continuation() {
  local output_path="$1"

  jq -e '.continue == true and (has("decision") | not)' "$output_path" >/dev/null || {
    cat "$output_path" >&2
    exit 1
  }
}

assert_stop_loop_reminder() {
  local output_path="$1" expected_code="$2"

  jq -e --arg expected_code "$expected_code" '
    .decision == "block" and
    (has("continue") | not) and
    ((.reason // "") | contains("[" + $expected_code + "]"))
  ' "$output_path" >/dev/null || {
    cat "$output_path" >&2
    exit 1
  }
}

run_active_once
assert_stop_loop_continuation "$out"
cmp -s "$tmp/expected-continue.json" "$out"
cp -- "$proof_root/t00-session/eci_active" "$tmp/direct-marker.loop.before"
cmp -s "$tmp/direct-loop.after-first" "$direct_loop_state"

# Identical recursive and ordinary callbacks remain continuations without
# mutating marker or loop state.
env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$proof_root" \
  bash "$CODEX_ROOT/hooks/stop-gate.sh" <"$direct_recursive_input" >"$direct_recursive_out"
assert_stop_loop_continuation "$direct_recursive_out"
cmp -s "$tmp/expected-continue.json" "$direct_recursive_out"
cmp -s "$tmp/direct-marker.loop.before" "$proof_root/t00-session/eci_active"
cmp -s "$tmp/direct-loop.after-first" "$direct_loop_state"

# The ordinary callback has the same continuation contract.
run_active_once
assert_stop_loop_continuation "$out"
cmp -s "$tmp/expected-continue.json" "$out"
cmp -s "$tmp/direct-marker.loop.before" "$proof_root/t00-session/eci_active"
cmp -s "$tmp/direct-loop.after-first" "$direct_loop_state"

# Replacing the marker entry with identical bytes changes its publication
# generation, so a later ordinary Stop starts a fresh bounded sequence.
cp -- "$proof_root/t00-session/eci_active" "$tmp/direct-marker.generation-reset"
mv -- "$tmp/direct-marker.generation-reset" "$proof_root/t00-session/eci_active"
run_once
grep -qx 'count: 1' "$direct_loop_state"
grep -qx 'loop_emitted: true' "$direct_loop_state"

# Ownership is decoded only from the typed top-level record. Nested metadata
# that happens to name session_id/cwd must not select a different owner or
# permit the active direct marker to fall through to continuation.
metadata_identity_root="$tmp/metadata-identity-root"
metadata_identity_session=t00-top-level-identity
metadata_identity_marker="$metadata_identity_root/$metadata_identity_session/eci_active"
metadata_identity_input="$tmp/metadata-identity-input.json"
metadata_identity_out="$tmp/metadata-identity-output.json"
mkdir -p "$metadata_identity_root/$metadata_identity_session"
printf 'scope: top-level identity\ncwd: %s\nsession_id: %s\n' \
  "$ROOT" "$metadata_identity_session" >"$metadata_identity_marker"
cp -- "$metadata_identity_marker" "$tmp/metadata-identity-marker.before"
jq -cn --arg cwd "$ROOT" --arg session_id "$metadata_identity_session" \
  '{metadata:{session_id:"wrong-nested-session",cwd:"/wrong/nested/cwd"},session_id:$session_id,cwd:$cwd,transcript_path:"",stop_hook_active:false}' \
  >"$metadata_identity_input"
env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$metadata_identity_root" \
  bash "$CODEX_ROOT/hooks/stop-gate.sh" <"$metadata_identity_input" >"$metadata_identity_out"
jq -e '
  .decision == "block" and
  (has("continue") | not) and
  ((.reason // "") | contains("[ECI_STOP_ACTIVE_ECI]"))
' "$metadata_identity_out" >/dev/null || {
  cat "$metadata_identity_out" >&2
  exit 1
}
grep -qx 'version: 2' "$metadata_identity_root/$metadata_identity_session/stop_loop_state"
grep -Eq '^fingerprint: [0-9a-f]{64}$' "$metadata_identity_root/$metadata_identity_session/stop_loop_state"
grep -qx 'count: 1' "$metadata_identity_root/$metadata_identity_session/stop_loop_state"
grep -qx 'loop_emitted: true' "$metadata_identity_root/$metadata_identity_session/stop_loop_state"
cp -- "$metadata_identity_root/$metadata_identity_session/stop_loop_state" \
  "$tmp/metadata-identity-state.before"
env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$metadata_identity_root" \
  bash "$CODEX_ROOT/hooks/stop-gate.sh" <"$metadata_identity_input" >"$metadata_identity_out"
assert_stop_loop_continuation "$metadata_identity_out"
cmp -s "$tmp/expected-continue.json" "$metadata_identity_out"
cmp -s "$tmp/metadata-identity-state.before" \
  "$metadata_identity_root/$metadata_identity_session/stop_loop_state"
cmp -s "$tmp/metadata-identity-marker.before" "$metadata_identity_marker"

run_publish_fixture() {
  local fixture_root="$1" fixture_input="$2" fixture_out="$3"

  env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$fixture_root" \
    bash "$CODEX_ROOT/hooks/stop-gate.sh" <"$fixture_input" >"$fixture_out"
}

prepare_publish_fixture() {
  local fixture_root="$1" fixture_session="$2" fixture_input="$3" fixture_out="$4"

  mkdir -p "$fixture_root/$fixture_session"
  printf 'scope: loop publication fixture\ncwd: %s\nsession_id: %s\n' \
    "$ROOT" "$fixture_session" >"$fixture_root/$fixture_session/eci_active"
  jq -cn --arg cwd "$ROOT" --arg session_id "$fixture_session" \
    '{session_id:$session_id,transcript_path:"",stop_hook_active:false,cwd:$cwd}' >"$fixture_input"
  run_publish_fixture "$fixture_root" "$fixture_input" "$fixture_out"
  grep -qx 'count: 1' "$fixture_root/$fixture_session/stop_loop_state"
  grep -qx 'loop_emitted: true' "$fixture_root/$fixture_session/stop_loop_state"
  # A v2 record left by the retired count-based implementation may be valid
  # but un-emitted. Exercise transactional publication while migrating it to
  # the current one-reminder state.
  sed -i 's/^loop_emitted: true$/loop_emitted: false/' \
    "$fixture_root/$fixture_session/stop_loop_state"
  grep -qx 'loop_emitted: false' "$fixture_root/$fixture_session/stop_loop_state"
}

assert_loop_state_publication_failure() {
  local output_path="$1"

  jq -e '
    .decision == "block" and
    (has("continue") | not) and
    ((.reason // "") | contains("[ECI_STOP_LOOP_STATE_UNSAFE]")) and
    ((.reason // "") | contains("[ECI_STOP_LOOP_CONTRACT_DEFECT]") | not)
  ' "$output_path" >/dev/null || {
    cat "$output_path" >&2
    exit 1
  }
}

# Loop publication is transactional. A legacy un-emitted state needs a single
# reminder publication; independently cover a temp-write and rename failure.
publish_temp_root="$tmp/publish-temp-root"
publish_temp_session=t00-publish-temp
publish_temp_input="$tmp/publish-temp-input.json"
publish_temp_out="$tmp/publish-temp-output.json"
prepare_publish_fixture "$publish_temp_root" "$publish_temp_session" \
  "$publish_temp_input" "$publish_temp_out"
publish_temp_state="$publish_temp_root/$publish_temp_session/stop_loop_state"
publish_temp_marker="$publish_temp_root/$publish_temp_session/eci_active"
cp -- "$publish_temp_state" "$tmp/publish-temp-state.before"
cp -- "$publish_temp_marker" "$tmp/publish-temp-marker.before"
chmod u-w "$publish_temp_root/$publish_temp_session"
run_publish_fixture "$publish_temp_root" "$publish_temp_input" "$publish_temp_out"
chmod u+w "$publish_temp_root/$publish_temp_session"
assert_loop_state_publication_failure "$publish_temp_out"
cmp -s "$tmp/publish-temp-state.before" "$publish_temp_state"
cmp -s "$tmp/publish-temp-marker.before" "$publish_temp_marker"
! compgen -G "$publish_temp_state.tmp.*" >/dev/null
run_publish_fixture "$publish_temp_root" "$publish_temp_input" "$publish_temp_out"
assert_stop_loop_reminder "$publish_temp_out" "ECI_STOP_ACTIVE_ECI"
grep -qx 'count: 1' "$publish_temp_state"
grep -qx 'loop_emitted: true' "$publish_temp_state"

publish_rename_root="$tmp/publish-rename-root"
publish_rename_session=t00-publish-rename
publish_rename_input="$tmp/publish-rename-input.json"
publish_rename_out="$tmp/publish-rename-output.json"
prepare_publish_fixture "$publish_rename_root" "$publish_rename_session" \
  "$publish_rename_input" "$publish_rename_out"
publish_rename_state="$publish_rename_root/$publish_rename_session/stop_loop_state"
publish_rename_marker="$publish_rename_root/$publish_rename_session/eci_active"
cp -- "$publish_rename_state" "$tmp/publish-rename-state.before"
cp -- "$publish_rename_marker" "$tmp/publish-rename-marker.before"
publish_fake_bin="$tmp/publish-fake-bin"
mkdir -p "$publish_fake_bin"
printf '%s\n' '#!/usr/bin/env bash' 'exit 1' >"$publish_fake_bin/mv"
chmod +x "$publish_fake_bin/mv"
PATH="$publish_fake_bin:$PATH" run_publish_fixture "$publish_rename_root" \
  "$publish_rename_input" "$publish_rename_out"
assert_loop_state_publication_failure "$publish_rename_out"
cmp -s "$tmp/publish-rename-state.before" "$publish_rename_state"
cmp -s "$tmp/publish-rename-marker.before" "$publish_rename_marker"
! compgen -G "$publish_rename_state.tmp.*" >/dev/null
run_publish_fixture "$publish_rename_root" "$publish_rename_input" "$publish_rename_out"
assert_stop_loop_reminder "$publish_rename_out" "ECI_STOP_ACTIVE_ECI"
grep -qx 'count: 1' "$publish_rename_state"
grep -qx 'loop_emitted: true' "$publish_rename_state"

# A recursive callback entering a fresh valid direct marker is an active ECI
# denial, not a terminal admission. It preserves the marker while publishing
# the normal first loop-state record.
fresh_recursive_root="$tmp/fresh-recursive-root"
mkdir -p "$fresh_recursive_root/t00-fresh"
printf 'scope: fresh recursive\ncwd: %s\nsession_id: t00-fresh\n' "$ROOT" \
  >"$fresh_recursive_root/t00-fresh/eci_active"
jq -cn --arg cwd "$ROOT" \
  '{session_id:"t00-fresh",transcript_path:"",stop_hook_active:true,cwd:$cwd}' \
  >"$direct_recursive_input"
cp -- "$fresh_recursive_root/t00-fresh/eci_active" "$tmp/fresh-recursive-marker.before"
env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$fresh_recursive_root" \
  bash "$CODEX_ROOT/hooks/stop-gate.sh" <"$direct_recursive_input" >"$direct_recursive_out"
jq -e '
  .decision == "block" and
  ((.continue // false) | not) and
  ((.reason // "") | contains("[ECI_STOP_ACTIVE_ECI]"))
' "$direct_recursive_out" >/dev/null || {
  cat "$direct_recursive_out" >&2
  exit 1
}
cmp -s "$tmp/fresh-recursive-marker.before" "$fresh_recursive_root/t00-fresh/eci_active"

# A safe valid sibling for another cwd does not make the direct callback
# ambiguous; the direct recursive callback remains an active ECI block.
safe_sibling_root="$tmp/safe-sibling-root"
safe_sibling_cwd="$tmp/safe-sibling-cwd"
mkdir -p "$safe_sibling_root/t00-safe-direct" \
  "$safe_sibling_root/t00-safe-unrelated" "$safe_sibling_cwd"
printf 'scope: direct recursive\ncwd: %s\nsession_id: t00-safe-direct\n' "$ROOT" \
  >"$safe_sibling_root/t00-safe-direct/eci_active"
printf 'scope: safe unrelated\ncwd: %s\nsession_id: t00-safe-unrelated\n' "$safe_sibling_cwd" \
  >"$safe_sibling_root/t00-safe-unrelated/eci_active"
jq -cn --arg cwd "$ROOT" \
  '{session_id:"t00-safe-direct",transcript_path:"",stop_hook_active:true,cwd:$cwd}' \
  >"$tmp/safe-sibling-input.json"
env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$safe_sibling_root" \
  bash "$CODEX_ROOT/hooks/stop-gate.sh" <"$tmp/safe-sibling-input.json" >"$direct_recursive_out"
jq -e '
  .decision == "block" and
  ((.continue // false) | not) and
  ((.reason // "") | contains("[ECI_STOP_ACTIVE_ECI]"))
' "$direct_recursive_out" >/dev/null || {
  cat "$direct_recursive_out" >&2
  exit 1
}

# A valid direct marker cannot admit recursion while a bounded sibling scan
# contains a metadata-invalid correct-owner marker. The sibling must not be
# silently discarded as an unrelated session.
malformed_sibling_root="$tmp/malformed-sibling-root"
mkdir -p "$malformed_sibling_root/t00-malformed-direct" \
  "$malformed_sibling_root/t00-malformed-sibling"
printf 'scope: direct recursive\ncwd: %s\nsession_id: t00-malformed-direct\n' "$ROOT" \
  >"$malformed_sibling_root/t00-malformed-direct/eci_active"
printf 'scope: \ncwd: %s\nsession_id: t00-malformed-sibling\n' "$ROOT" \
  >"$malformed_sibling_root/t00-malformed-sibling/eci_active"
jq -cn --arg cwd "$ROOT" \
  '{session_id:"t00-malformed-direct",transcript_path:"",stop_hook_active:true,cwd:$cwd}' \
  >"$tmp/malformed-sibling-input.json"
env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$malformed_sibling_root" \
  bash "$CODEX_ROOT/hooks/stop-gate.sh" <"$tmp/malformed-sibling-input.json" >"$direct_recursive_out"
jq -e '.decision == "block" and ((.continue // false) | not)' \
  "$direct_recursive_out" >/dev/null || {
  cat "$direct_recursive_out" >&2
  exit 1
}

# A hard-linked sibling marker is likewise unsafe control state even when its
# bytes otherwise describe a valid unrelated owner.
hardlink_sibling_root="$tmp/hardlink-sibling-root"
mkdir -p "$hardlink_sibling_root/t00-hardlink-direct" \
  "$hardlink_sibling_root/t00-hardlink-sibling"
printf 'scope: direct recursive\ncwd: %s\nsession_id: t00-hardlink-direct\n' "$ROOT" \
  >"$hardlink_sibling_root/t00-hardlink-direct/eci_active"
hardlink_sibling_target="$tmp/hardlink-sibling-target"
printf 'scope: hardlinked sibling\ncwd: %s\nsession_id: t00-hardlink-sibling\n' "$ROOT" \
  >"$hardlink_sibling_target"
ln -- "$hardlink_sibling_target" \
  "$hardlink_sibling_root/t00-hardlink-sibling/eci_active"
jq -cn --arg cwd "$ROOT" \
  '{session_id:"t00-hardlink-direct",transcript_path:"",stop_hook_active:true,cwd:$cwd}' \
  >"$tmp/hardlink-sibling-input.json"
hardlink_sibling_failures=0
for callback in 1 2 3 4; do
  hardlink_sibling_out="$tmp/hardlink-sibling-$callback.out"
  env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$hardlink_sibling_root" \
    bash "$CODEX_ROOT/hooks/stop-gate.sh" <"$tmp/hardlink-sibling-input.json" >"$hardlink_sibling_out"
  if ! jq -e '
    .decision == "block" and
    ((.continue // false) | not) and
    ((.reason // "") | contains("[ECI_STOP_MARKER_SCAN_UNSAFE]"))
  ' "$hardlink_sibling_out" >/dev/null; then
    printf 'hard-linked sibling callback %s did not retain the unsafe scan denial:\n' "$callback" >&2
    cat "$hardlink_sibling_out" >&2
    hardlink_sibling_failures=1
  fi
  if [ "$callback" -eq 4 ] && cmp -s "$tmp/expected-continue.json" "$hardlink_sibling_out"; then
    printf '%s\n' 'hard-linked sibling fourth callback incorrectly continued' >&2
    hardlink_sibling_failures=1
  fi
done

# The ordinary Stop callback must preserve the same unsafe-marker denial.
# It cannot use the post-threshold continuation merely because the direct
# marker itself is valid while a hard-linked sibling makes the full scan
# untrustworthy.
ordinary_hardlink_sibling_root="$tmp/ordinary-hardlink-sibling-root"
mkdir -p "$ordinary_hardlink_sibling_root/t00-ordinary-hardlink-direct" \
  "$ordinary_hardlink_sibling_root/t00-ordinary-hardlink-sibling"
printf 'scope: ordinary hardlink direct\ncwd: %s\nsession_id: t00-ordinary-hardlink-direct\n' "$ROOT" \
  >"$ordinary_hardlink_sibling_root/t00-ordinary-hardlink-direct/eci_active"
ordinary_hardlink_sibling_target="$tmp/ordinary-hardlink-sibling-target"
printf 'scope: ordinary hardlinked sibling\ncwd: %s\nsession_id: t00-ordinary-hardlink-sibling\n' "$ROOT" \
  >"$ordinary_hardlink_sibling_target"
ln -- "$ordinary_hardlink_sibling_target" \
  "$ordinary_hardlink_sibling_root/t00-ordinary-hardlink-sibling/eci_active"
jq -cn --arg cwd "$ROOT" \
  '{session_id:"t00-ordinary-hardlink-direct",transcript_path:"",stop_hook_active:false,cwd:$cwd}' \
  >"$tmp/ordinary-hardlink-sibling-input.json"
for callback in 1 2 3 4; do
  ordinary_hardlink_sibling_out="$tmp/ordinary-hardlink-sibling-$callback.out"
  env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$ordinary_hardlink_sibling_root" \
    bash "$CODEX_ROOT/hooks/stop-gate.sh" <"$tmp/ordinary-hardlink-sibling-input.json" >"$ordinary_hardlink_sibling_out"
  if ! jq -e '
    .decision == "block" and
    ((.continue // false) | not) and
    ((.reason // "") | contains("[ECI_STOP_MARKER_SCAN_UNSAFE]"))
  ' "$ordinary_hardlink_sibling_out" >/dev/null; then
    printf 'ordinary hard-linked sibling callback %s did not retain the unsafe scan denial:\n' "$callback" >&2
    cat "$ordinary_hardlink_sibling_out" >&2
    hardlink_sibling_failures=1
  fi
  if [ "$callback" -eq 4 ] && cmp -s "$tmp/expected-continue.json" "$ordinary_hardlink_sibling_out"; then
    printf '%s\n' 'ordinary hard-linked sibling fourth callback incorrectly continued' >&2
    hardlink_sibling_failures=1
  fi
done
[ "$hardlink_sibling_failures" -eq 0 ] || exit 1

# Recursive admission requires strict top-level identity, including a
# transcript_path string. Malformed JSON, non-booleans, duplicate keys,
# nested-only flags, a missing transcript, oversized input, and cwd mismatches
# all retain the active-marker fail-closed path.
strict_negative_root="$tmp/strict-negative-root"
mkdir -p "$strict_negative_root/t00-strict" "$tmp/strict-other-cwd"
printf 'scope: strict negatives\ncwd: %s\nsession_id: t00-strict\n' "$ROOT" \
  >"$strict_negative_root/t00-strict/eci_active"
assert_recursive_blocked() {
  local input_path="$1"
  env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$strict_negative_root" \
    bash "$CODEX_ROOT/hooks/stop-gate.sh" <"$input_path" >"$direct_recursive_out"
  jq -e '.decision == "block" and ((.continue // false) | not)' \
    "$direct_recursive_out" >/dev/null || {
    cat "$direct_recursive_out" >&2
    exit 1
  }
}
printf '{"session_id":"t00-strict","cwd":"%s","transcript_path":"","stop_hook_active":true\n' \
  "$ROOT" >"$tmp/strict-malformed.json"
# A malformed recursive callback has no safe normalized key. Repeating its
# exact bytes must remain blocked past the automatic-loop threshold.
for _ in 1 2 3; do
  assert_recursive_blocked "$tmp/strict-malformed.json"
done
printf '{"session_id":"t00-strict","cwd":"%s","transcript_path":"","stop_hook_active":"true"}\n' \
  "$ROOT" >"$tmp/strict-nonboolean.json"
assert_recursive_blocked "$tmp/strict-nonboolean.json"
printf '{"session_id":"t00-strict","cwd":"%s","transcript_path":"","stop_hook_active":true,"stop_hook_active":true}\n' \
  "$ROOT" >"$tmp/strict-duplicate.json"
assert_recursive_blocked "$tmp/strict-duplicate.json"
printf '{"session_id":"t00-strict","cwd":"%s","transcript_path":"","callback":{"stop_hook_active":true}}\n' \
  "$ROOT" >"$tmp/strict-nested.json"
assert_recursive_blocked "$tmp/strict-nested.json"
printf '{"wrapper":{"session_id":"t00-strict","cwd":"%s","transcript_path":""},"stop_hook_active":true}\n' \
  "$ROOT" >"$tmp/strict-nested-identity.json"
assert_recursive_blocked "$tmp/strict-nested-identity.json"
jq -cn --arg cwd "$ROOT" \
  '{session_id:"t00-strict",cwd:$cwd,stop_hook_active:true}' \
  >"$tmp/strict-missing-transcript.json"
cp -- "$strict_negative_root/t00-strict/eci_active" "$tmp/strict-missing-transcript-marker.before"
assert_recursive_blocked "$tmp/strict-missing-transcript.json"
jq -e '
  .decision == "block" and
  (has("continue") | not) and
  ((.reason // "") | contains("[ECI_STOP_ACTIVE_ECI]"))
' "$direct_recursive_out" >/dev/null || {
  cat "$direct_recursive_out" >&2
  exit 1
}
grep -qx 'count: 1' "$strict_negative_root/t00-strict/stop_loop_state"
grep -qx 'loop_emitted: true' "$strict_negative_root/t00-strict/stop_loop_state"
cp -- "$strict_negative_root/t00-strict/stop_loop_state" \
  "$tmp/strict-missing-transcript-state.after-first"
env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$strict_negative_root" \
  bash "$CODEX_ROOT/hooks/stop-gate.sh" <"$tmp/strict-missing-transcript.json" >"$direct_recursive_out"
assert_stop_loop_continuation "$direct_recursive_out"
cmp -s "$tmp/expected-continue.json" "$direct_recursive_out"
env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$strict_negative_root" \
  bash "$CODEX_ROOT/hooks/stop-gate.sh" <"$tmp/strict-missing-transcript.json" >"$direct_recursive_out"
assert_stop_loop_continuation "$direct_recursive_out"
cmp -s "$tmp/expected-continue.json" "$direct_recursive_out"
cmp -s "$tmp/strict-missing-transcript-marker.before" \
  "$strict_negative_root/t00-strict/eci_active"
cmp -s "$tmp/strict-missing-transcript-state.after-first" \
  "$strict_negative_root/t00-strict/stop_loop_state"
jq -cn --arg cwd "$tmp/strict-other-cwd" \
  '{session_id:"t00-strict",transcript_path:"",stop_hook_active:true,cwd:$cwd}' \
  >"$tmp/strict-cwd-mismatch.json"
assert_recursive_blocked "$tmp/strict-cwd-mismatch.json"
{
  printf '{"session_id":"t00-strict","cwd":"%s","transcript_path":"","padding":"' "$ROOT"
  head -c 70000 /dev/zero | tr '\0' x
  printf '","stop_hook_active":true}\n'
} >"$tmp/strict-oversized.json"
assert_recursive_blocked "$tmp/strict-oversized.json"

printf '%s\n' 'PASS strict recursive callback admission'

# A no-marker recursive stop callback still reaches normal proof validation.
# The closing JSON quote is part of the scalar field token.
recursive_input="$tmp/recursive-input.json"
recursive_out="$tmp/recursive-out.json"
no_marker_recursive_root="$tmp/no-marker-recursive-root"
no_marker_recursive_repo="$tmp/no-marker-recursive-repo"
mkdir -p "$no_marker_recursive_root/recursive-session" "$no_marker_recursive_repo"
git -C "$no_marker_recursive_repo" init -q
git -C "$no_marker_recursive_repo" config user.email 'eci-test@example.invalid'
git -C "$no_marker_recursive_repo" config user.name 'ECI fast-path test'
printf '%s\n' 'clean recursive fixture' >"$no_marker_recursive_repo/README"
git -C "$no_marker_recursive_repo" add README
git -C "$no_marker_recursive_repo" commit -qm 'create recursive fixture'
printf '%s\n' '# intentionally incomplete proof' \
  >"$no_marker_recursive_root/recursive-session/proof.md"
jq -n --arg cwd "$no_marker_recursive_repo" \
  '{session_id:"recursive-session", transcript_path:"", stop_hook_active:true, cwd:$cwd}' \
  >"$recursive_input"
env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_TMPDIR="$tmp/recursive-tmp" CODEX_PROOF_ROOT="$no_marker_recursive_root" \
  bash "$CODEX_ROOT/hooks/stop-gate.sh" <"$recursive_input" >"$recursive_out"
jq -e '.decision == "block" and ((.reason // "") | contains("Proof file is missing required sections"))' \
  "$recursive_out" >/dev/null || {
  cat "$recursive_out" >&2
  exit 1
}
[ -f "$no_marker_recursive_root/recursive-session/proof.md" ]

printf '%s\n' 'PASS no-marker recursive proof path'

# Even without a marker, a recursive candidate must not use the generic clean
# turn shortcut as a continuation permit.
marker_free_recursive_root="$tmp/marker-free-recursive-root"
mkdir -p "$marker_free_recursive_root"
jq -cn --arg cwd "$no_marker_recursive_repo" \
  '{session_id:"marker-free-session",transcript_path:"",stop_hook_active:true,cwd:$cwd}' \
  >"$tmp/marker-free-recursive.json"
env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_TMPDIR="$tmp/marker-free-tmp" CODEX_PROOF_ROOT="$marker_free_recursive_root" \
  bash "$CODEX_ROOT/hooks/stop-gate.sh" <"$tmp/marker-free-recursive.json" >"$recursive_out"
jq -e '.decision == "block" and ((.continue // false) | not)' "$recursive_out" >/dev/null || {
  cat "$recursive_out" >&2
  exit 1
}
jq -cn --arg cwd "$no_marker_recursive_repo" \
  '{wrapper:{session_id:"nested-marker-free-session",transcript_path:"",cwd:$cwd},stop_hook_active:true}' \
  >"$tmp/nested-marker-free-recursive.json"
env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_TMPDIR="$tmp/marker-free-tmp" CODEX_PROOF_ROOT="$marker_free_recursive_root" \
  bash "$CODEX_ROOT/hooks/stop-gate.sh" <"$tmp/nested-marker-free-recursive.json" >"$recursive_out"
jq -e '.decision == "block" and ((.continue // false) | not)' "$recursive_out" >/dev/null || {
  cat "$recursive_out" >&2
  exit 1
}

# A recursive callback for another session must not use a victim's direct
# marker as a continuation permit.
spoof_root="$tmp/recursive-session-spoof-root"
mkdir -p "$spoof_root/victim-session"
printf 'scope: victim\ncwd: %s\nsession_id: victim-session\n' "$ROOT" \
  >"$spoof_root/victim-session/eci_active"
jq -cn --arg cwd "$ROOT" \
  '{session_id:"attacker-session",transcript_path:"",stop_hook_active:true,cwd:$cwd}' \
  >"$tmp/recursive-session-spoof.json"
env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$spoof_root" \
  bash "$CODEX_ROOT/hooks/stop-gate.sh" <"$tmp/recursive-session-spoof.json" >"$recursive_out"
jq -e '.decision == "block" and ((.continue // false) | not)' "$recursive_out" >/dev/null || {
  cat "$recursive_out" >&2
  exit 1
}

max_ms=0
for _ in $(seq 1 5); do
  start_ns="$(date +%s%N)"
  run_active_once
  assert_active_result
  elapsed_ms=$(( ($(date +%s%N) - start_ns) / 1000000 ))
  [ "$elapsed_ms" -gt "$max_ms" ] && max_ms="$elapsed_ms"
done
printf 'active ECI serial fast path: max %sms\n' "$max_ms"
[ "$max_ms" -lt 1000 ]

run_concurrent() {
  local workers="$1"
  local worker_dir="$tmp/workers-$workers"
  local start_ns end_ns wall_ms worker_ms worker_max=0 batch_size
  local i pid
  local -a pids=()

  mkdir -p "$worker_dir"
  # Keep the probe itself from saturating a small CI host: 80 total callbacks
  # still exercise concurrent waves, while each callback's wall time remains
  # a useful latency signal rather than scheduler queue time.
  batch_size=32
  start_ns="$(date +%s%N)"
  for i in $(seq 1 "$workers"); do
    (
      local_start="$(date +%s%N)"
      env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$proof_root" \
        bash "$CODEX_ROOT/hooks/stop-gate.sh" <"$input" >"$worker_dir/$i.out"
      local_end="$(date +%s%N)"
      printf '%s\n' "$(( (local_end - local_start) / 1000000 ))" >"$worker_dir/$i.ms"
      cmp -s "$tmp/expected-stop-loop-contract-defect.json" "$worker_dir/$i.out"
    ) &
    pids+=("$!")
    if [ "${#pids[@]}" -ge "$batch_size" ]; then
      for pid in "${pids[@]}"; do
        wait "$pid"
      done
      pids=()
    fi
  done
  for pid in "${pids[@]}"; do
    wait "$pid"
  done
  end_ns="$(date +%s%N)"
  wall_ms=$(( (end_ns - start_ns) / 1000000 ))
  for i in $(seq 1 "$workers"); do
    worker_ms="$(cat "$worker_dir/$i.ms")"
    [ "$worker_ms" -gt "$worker_max" ] && worker_max="$worker_ms"
  done
  # Concurrent wall time includes scheduler queueing.  Keep it as a bounded
  # liveness check; the serial probe above is the configured-chain <1s gate.
  [ "$wall_ms" -lt 10000 ]
  printf 'PASS active ECI concurrent fast path: %s callbacks, max %sms, wall %sms\n' \
    "$workers" "$worker_max" "$wall_ms"
}

run_concurrent 32
run_concurrent 80

# Lifecycle safety remains intentionally separate from the hook hot path:
# proof-root, session, and marker symlinks must fail closed; a stable cache
# parent symlink is the supported deployment layout tested below.
safety_root="$tmp/safety-root"
mkdir -p "$safety_root/real-session"
ln -s "$safety_root" "$tmp/safety-root-link"
if CODEX_PROOF_ROOT="$tmp/safety-root-link" CODEX_SESSION_ID=safety \
  "$CODEX_ROOT/bin/eci-active" on "scope" >"$tmp/safety.out" 2>"$tmp/safety.err"; then
  printf 'ECI root symlink was accepted\n' >&2
  exit 1
fi

# A symlinked cache parent is valid when the final proof-root directory is
# regular and resolves to a directory. Both CLI activation and the stop hook
# must accept this normal deployment layout.
cache_target="$tmp/cache-target"
cache_link="$tmp/cache-link"
mkdir -p "$cache_target/proof"
ln -s "$cache_target" "$cache_link"
CODEX_PROOF_ROOT="$cache_link/proof" CODEX_SESSION_ID=cache-session \
  "$CODEX_ROOT/bin/eci-active" on "cache-parent scope" >"$tmp/cache-on.out"
[ -f "$cache_target/proof/cache-session/eci_active" ]
cache_input="$tmp/cache-input.json"
cache_out="$tmp/cache-out.json"
jq -n --arg cwd "$ROOT" \
  '{session_id:"cache-session",transcript_path:"",stop_hook_active:false,cwd:$cwd}' >"$cache_input"
env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$cache_link/proof" \
  bash "$CODEX_ROOT/hooks/stop-gate.sh" <"$cache_input" >"$cache_out"
[ "$(jq -r '.decision // empty' "$cache_out")" = block ]
jq -n --arg cwd "$ROOT" \
  '{session_id:"cache-empty",transcript_path:"",stop_hook_active:false,cwd:$cwd}' >"$cache_input"
env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$cache_link/proof" \
  bash "$CODEX_ROOT/hooks/stop-gate.sh" <"$cache_input" >"$cache_out"
 [ "$(jq -r '.continue // empty' "$cache_out")" = true ] || {
  cat "$cache_out" >&2
  exit 1
}

ln -s "$safety_root/real-session" "$safety_root/session-link"
if CODEX_PROOF_ROOT="$safety_root" CODEX_SESSION_ID=session-link \
  "$CODEX_ROOT/bin/eci-active" on "scope" >"$tmp/session-link.out" 2>"$tmp/session-link.err"; then
  printf 'ECI session symlink was accepted\n' >&2
  exit 1
fi
mkdir -p "$safety_root/safety"
ln -s "$safety_root/real-session/eci_active" "$safety_root/safety/eci_active"
if CODEX_PROOF_ROOT="$safety_root" CODEX_SESSION_ID=safety \
  "$CODEX_ROOT/bin/eci-active" status >"$tmp/status.out" 2>"$tmp/status.err"; then
  printf 'ECI status followed a marker symlink\n' >&2
  exit 1
fi
mkdir -p "$tmp/legacy-target"
printf 'scope: legacy\ncwd: %s\nsession_id: pre-reviewer\n' "$ROOT" \
  >"$tmp/legacy-target/eci_active"
ln -s "$tmp/legacy-target" "$safety_root/pre-reviewer"
CODEX_PROOF_ROOT="$safety_root" CODEX_SESSION_ID=safety2 \
  "$CODEX_ROOT/bin/eci-active" on "scope" >/dev/null
[ -f "$tmp/legacy-target/eci_active" ]

# Scope validation must reject LF without command-substitution newline loss.
scope_root="$tmp/scope-root"
mkdir -p "$scope_root/scope-session"
if CODEX_PROOF_ROOT="$scope_root" CODEX_SESSION_ID=scope-session \
  "$CODEX_ROOT/bin/eci-active" on $'line one\nline two' >"$tmp/scope.out" 2>"$tmp/scope.err"; then
  printf 'ECI newline scope was accepted\n' >&2
  exit 1
fi
[ ! -e "$scope_root/scope-session/eci_active" ]

long_scope_root="$tmp/long-scope-root"
mkdir -p "$long_scope_root/long-session"
long_scope="$(head -c 5000 /dev/zero | tr '\0' x)"
if CODEX_PROOF_ROOT="$long_scope_root" CODEX_SESSION_ID=long-session \
  "$CODEX_ROOT/bin/eci-active" on "$long_scope" >"$tmp/long-scope.out" 2>"$tmp/long-scope.err"; then
  printf 'ECI oversized scope was accepted\n' >&2
  exit 1
fi
[ ! -e "$long_scope_root/long-session/eci_active" ]

partial_root="$tmp/partial-marker-root"
mkdir -p "$partial_root/partial-session"
partial_marker="$partial_root/partial-session/eci_active"
printf '%s\n' 'scope: pre-existing partial marker' >"$partial_marker"
if CODEX_PROOF_ROOT="$partial_root" CODEX_SESSION_ID=partial-session \
  "$CODEX_ROOT/bin/eci-active" on "replacement must not occur" >"$tmp/partial.out" 2>"$tmp/partial.err"; then
  printf 'ECI activation replaced a pre-existing marker\n' >&2
  exit 1
fi
[ "$(cat "$partial_marker")" = 'scope: pre-existing partial marker' ]
[ ! -e "$partial_marker.tmp" ]

mkdir -p "$safety_root/reviewer"
printf 'scope: bad\tc0\ncwd: %s\nsession_id: reviewer\n' "$ROOT" \
  >"$safety_root/reviewer/eci_active"
if CODEX_PROOF_ROOT="$safety_root" bash -c \
  '. "$1/hooks/lib/codex-proof-state.sh"; codex_legacy_eci_markers_for_cwd "$2"' \
  bash "$CODEX_ROOT" "$ROOT" | grep -q .; then
  printf 'legacy control-byte marker was accepted\n' >&2
  exit 1
fi

# Stop-gate regression: unsafe own and parent markers must fail closed before
# generic json_block can create stop_timestamps or append session ownership.
stop_safety_root="$tmp/stop-safety-root"
mkdir -p "$stop_safety_root/t00-session" "$stop_safety_root/t00-parent" \
  "$stop_safety_root/side-stop/sessions/t00-side" "$tmp/stop-target"
printf 'scope: target\n' >"$tmp/stop-target/eci_active"
ln -s "$tmp/stop-target/eci_active" "$stop_safety_root/t00-session/eci_active"
stop_input="$tmp/stop-input.json"
stop_out="$tmp/stop-out.json"
jq -n --arg cwd "$ROOT" \
  '{session_id:"t00-session",transcript_path:"",stop_hook_active:true,cwd:$cwd}' >"$stop_input"
env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$stop_safety_root" \
  bash "$CODEX_ROOT/hooks/stop-gate.sh" <"$stop_input" >"$stop_out"
[ "$(jq -r '.decision // empty' "$stop_out")" = block ]
jq -e '.reason | contains("[ECI_MARKER_UNSAFE_PATH]") and contains("symlink")' "$stop_out" >/dev/null
[ ! -e "$stop_safety_root/t00-session/stop_timestamps" ]
[ ! -e "$stop_safety_root/stop_timestamps" ]
[ "$(cat "$tmp/stop-target/eci_active")" = 'scope: target' ]

mkdir -p "$home/.codex/sessions"
printf '%s\n' '{"type":"session_meta","payload":{"source":{"subagent":{"thread_spawn":{"parent_thread_id":"t00-session"}}}}}' \
  >"$home/.codex/sessions/child.jsonl"
jq --arg transcript "$home/.codex/sessions/child.jsonl" \
  '.transcript_path = $transcript' "$stop_input" >"$stop_input.next"
mv "$stop_input.next" "$stop_input"
env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$stop_safety_root" \
  bash "$CODEX_ROOT/hooks/stop-gate.sh" <"$stop_input" >"$stop_out"
[ "$(jq -r '.decision // empty' "$stop_out")" = block ]
[ ! -e "$stop_safety_root/t00-session/stop_timestamps" ]

# A transcript marked as a subagent must not exempt its validated parent
# session marker from active-ECI Stop denial.  Without this regression, the
# parent-thread branch can fall through to the subagent's json_continue path.
parent_active_root="$tmp/parent-active-marker-root"
parent_active_session=t00-parent-active
parent_active_marker="$parent_active_root/$parent_active_session/eci_active"
parent_active_input="$tmp/parent-active-marker-input.json"
parent_active_out="$tmp/parent-active-marker-output.json"
mkdir -p "$parent_active_root/$parent_active_session" "$home/.codex/sessions"
printf 'scope: parent transcript active marker\ncwd: %s\nsession_id: %s\n' \
  "$ROOT" "$parent_active_session" >"$parent_active_marker"
printf '%s\n' '{"type":"session_meta","payload":{"source":{"subagent":{"thread_spawn":{"parent_thread_id":"t00-parent-active"}}}}}' \
  >"$home/.codex/sessions/parent-active.jsonl"
cp -- "$parent_active_marker" "$tmp/parent-active-marker.before"
jq -n --arg cwd "$ROOT" --arg session_id "$parent_active_session" \
  --arg transcript "$home/.codex/sessions/parent-active.jsonl" \
  '{session_id:$session_id,transcript_path:$transcript,stop_hook_active:false,cwd:$cwd}' \
  >"$parent_active_input"
env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$parent_active_root" \
  bash "$CODEX_ROOT/hooks/stop-gate.sh" <"$parent_active_input" >"$parent_active_out"
jq -e '
  .decision == "block" and
  ((.continue // false) | not) and
  ((.reason // "") | contains("[ECI_STOP_ACTIVE_ECI]"))
' "$parent_active_out" >/dev/null || {
  cat "$parent_active_out" >&2
  exit 1
}
cmp -s "$tmp/parent-active-marker.before" "$parent_active_marker"
grep -qx 'count: 1' "$parent_active_root/$parent_active_session/stop_loop_state"

printf 'command: /side\nparent_session_id: t00-parent\n' \
  >"$stop_safety_root/side-stop/sessions/t00-side/side_stop"
ln -s "$tmp/stop-target/eci_active" "$stop_safety_root/t00-parent/eci_active"
jq -n --arg cwd "$ROOT" \
  '{session_id:"t00-side",transcript_path:"",stop_hook_active:true,cwd:$cwd}' >"$stop_input"
env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$stop_safety_root" \
  bash "$CODEX_ROOT/hooks/stop-gate.sh" <"$stop_input" >"$stop_out"
[ "$(jq -r '.decision // empty' "$stop_out")" = block ]
[ ! -e "$stop_safety_root/t00-side/stop_timestamps" ]
[ ! -e "$stop_safety_root/stop_timestamps" ]

# Marker ownership regression: duplicate validated owners and malformed typed
# identities must fail closed without creating recovery state.
duplicate_root="$tmp/duplicate-root"
mkdir -p "$duplicate_root/t00-one" "$duplicate_root/t00-two"
printf 'scope: one\ncwd: %s\nsession_id: t00-one\n' "$ROOT" >"$duplicate_root/t00-one/eci_active"
printf 'scope: two\ncwd: %s\nsession_id: t00-two\n' "$ROOT" >"$duplicate_root/t00-two/eci_active"
jq -n --arg cwd "$ROOT" \
  '{session_id:"t00-one",transcript_path:"",stop_hook_active:true,cwd:$cwd}' >"$stop_input"
env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$duplicate_root" \
  bash "$CODEX_ROOT/hooks/stop-gate.sh" <"$stop_input" >"$stop_out"
[ "$(jq -r '.decision // empty' "$stop_out")" = block ]
[ ! -e "$duplicate_root/t00-one/stop_timestamps" ]

# A valid direct marker stays authoritative when fully valid same-cwd peer
# markers exist. The peer remains advisory while the direct marker and
# wait/report artifacts remain untouched.
large_duplicate_root="$tmp/large-duplicate-root"
mkdir -p "$large_duplicate_root/t00-direct" "$large_duplicate_root/t00-duplicate"
CODEX_SESSION_ID=t00-direct CODEX_PROOF_ROOT="$large_duplicate_root" \
  "$CODEX_ROOT/bin/eci-active" on "direct wait probe" >"$tmp/large-duplicate-on.out" 2>&1
printf 'scope: duplicate\ncwd: %s\nsession_id: t00-duplicate\n' "$ROOT" \
  >"$large_duplicate_root/t00-duplicate/eci_active"
for i in $(seq 1 2000); do
  mkdir -p "$large_duplicate_root/t00-unrelated-$i"
done
large_wait_report="$(realpath -m -- "$large_duplicate_root/t00-direct/eci_user_owned_wait.md")"
write_wait_report "$large_wait_report" fast-path-duplicate
CODEX_SESSION_ID=t00-direct CODEX_PROOF_ROOT="$large_duplicate_root" \
  "$CODEX_ROOT/bin/eci-active" wait "$large_wait_report" >"$tmp/large-duplicate-wait.out" 2>&1
cp -- "$large_duplicate_root/t00-direct/eci_active" "$tmp/large-duplicate-marker.before"
cp -- "$large_duplicate_root/t00-duplicate/eci_active" "$tmp/large-duplicate-peer-marker.before"
cp -- "$large_duplicate_root/t00-direct/eci_wait" "$tmp/large-duplicate-wait.before"
cp -- "$large_wait_report" "$tmp/large-duplicate-report.before"
jq -n --arg cwd "$ROOT" \
  '{session_id:"t00-direct",transcript_path:"",stop_hook_active:false,cwd:$cwd}' >"$stop_input"
env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$large_duplicate_root" \
  bash "$CODEX_ROOT/hooks/stop-gate.sh" <"$stop_input" >"$stop_out"
jq -e '
  .decision == "block" and
  (has("continue") | not) and
  ((.reason // "") | contains("[ECI_STOP_ACTIVE_ECI]"))
' "$stop_out" >/dev/null || {
  cat "$stop_out" >&2
  exit 1
}
cmp -s "$tmp/large-duplicate-marker.before" "$large_duplicate_root/t00-direct/eci_active"
cmp -s "$tmp/large-duplicate-peer-marker.before" "$large_duplicate_root/t00-duplicate/eci_active"
cmp -s "$tmp/large-duplicate-wait.before" "$large_duplicate_root/t00-direct/eci_wait"
cmp -s "$tmp/large-duplicate-report.before" "$large_wait_report"
[ ! -e "$large_duplicate_root/t00-direct/stop_timestamps" ]
grep -qx 'version: 2' "$large_duplicate_root/t00-direct/stop_loop_state"
grep -qx 'count: 1' "$large_duplicate_root/t00-direct/stop_loop_state"
grep -qx 'loop_emitted: true' "$large_duplicate_root/t00-direct/stop_loop_state"
cp -- "$large_duplicate_root/t00-direct/stop_loop_state" \
  "$tmp/large-duplicate-state.after-first"
large_duplicate_recursive_input="$tmp/large-duplicate-recursive-input.json"
jq -n --arg cwd "$ROOT" \
  '{session_id:"t00-direct",transcript_path:"",stop_hook_active:true,cwd:$cwd}' \
  >"$large_duplicate_recursive_input"
env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$large_duplicate_root" \
  bash "$CODEX_ROOT/hooks/stop-gate.sh" <"$large_duplicate_recursive_input" >"$stop_out"
assert_stop_loop_continuation "$stop_out"
cmp -s "$tmp/expected-continue.json" "$stop_out" || {
  cat "$stop_out" >&2
  exit 1
}
cmp -s "$tmp/large-duplicate-marker.before" "$large_duplicate_root/t00-direct/eci_active"
cmp -s "$tmp/large-duplicate-peer-marker.before" "$large_duplicate_root/t00-duplicate/eci_active"
cmp -s "$tmp/large-duplicate-wait.before" "$large_duplicate_root/t00-direct/eci_wait"
cmp -s "$tmp/large-duplicate-report.before" "$large_wait_report"
cmp -s "$tmp/large-duplicate-state.after-first" \
  "$large_duplicate_root/t00-direct/stop_loop_state"

arm_direct_wait_fixture() {
  local fixture_root="$1" fixture_session="$2" report

  mkdir -p "$fixture_root/$fixture_session"
  CODEX_SESSION_ID="$fixture_session" CODEX_PROOF_ROOT="$fixture_root" \
    "$CODEX_ROOT/bin/eci-active" on "direct wait safety fixture" \
    >"$tmp/$fixture_session-on.out" 2>&1
  report="$(realpath -m -- "$fixture_root/$fixture_session/eci_user_owned_wait.md")"
  write_wait_report "$report" "$fixture_session-wait"
  CODEX_SESSION_ID="$fixture_session" CODEX_PROOF_ROOT="$fixture_root" \
    "$CODEX_ROOT/bin/eci-active" wait "$report" \
    >"$tmp/$fixture_session-wait.out" 2>&1
}

assert_direct_wait_blocked() {
  local fixture_root="$1" fixture_session="$2" fixture_input="$tmp/$2-stop.json"

  jq -n --arg cwd "$ROOT" --arg session_id "$fixture_session" \
    '{session_id:$session_id,transcript_path:"",stop_hook_active:false,cwd:$cwd}' >"$fixture_input"
  env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$fixture_root" \
    bash "$CODEX_ROOT/hooks/stop-gate.sh" <"$fixture_input" >"$stop_out"
  jq -e '.decision == "block" and ((.continue // false) | not)' "$stop_out" >/dev/null || {
    cat "$stop_out" >&2
    exit 1
  }
}

# A callback session without its own marker must still block when exactly one
# fully validated marker owned by another session is bound to the same cwd.
# Bookkeeping belongs only to the callback session; the foreign marker and its
# lifecycle artifacts remain byte-for-byte unchanged.
foreign_root="$tmp/foreign-owner-root"
foreign_peer_session=t00-foreign-peer
foreign_callback_session=t00-foreign-callback
foreign_input="$tmp/foreign-owner-input.json"
foreign_out="$tmp/foreign-owner-output.json"
arm_direct_wait_fixture "$foreign_root" "$foreign_peer_session"
foreign_marker="$foreign_root/$foreign_peer_session/eci_active"
foreign_wait="$foreign_root/$foreign_peer_session/eci_wait"
foreign_report="$foreign_root/$foreign_peer_session/eci_user_owned_wait.md"
cp -- "$foreign_marker" "$tmp/foreign-marker.before"
cp -- "$foreign_wait" "$tmp/foreign-wait.before"
cp -- "$foreign_report" "$tmp/foreign-report.before"
jq -cn --arg cwd "$ROOT" --arg session_id "$foreign_callback_session" \
  '{session_id:$session_id,transcript_path:"",stop_hook_active:false,cwd:$cwd}' \
  >"$foreign_input"
foreign_active_reason="[ECI_STOP_ACTIVE_ECI] Stop is denied because callback session $foreign_callback_session has no direct active ECI marker; the fully validated active ECI marker at $foreign_marker is owned by different session $foreign_peer_session and bound to the same canonical cwd. The marker remains authoritative. Resume actual active ECI work or complete valid normal teardown before retrying Stop. Do not retry unchanged Stop."
foreign_callback_state="$foreign_root/$foreign_callback_session/stop_loop_state"
env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$foreign_root" \
  bash "$CODEX_ROOT/hooks/stop-gate.sh" <"$foreign_input" >"$foreign_out"
jq -e --arg reason "$foreign_active_reason" '
  .decision == "block" and
  (has("continue") | not) and
  ((.reason // "") | startswith($reason))
' "$foreign_out" >/dev/null || {
  cat "$foreign_out" >&2
  exit 1
}
grep -qx 'version: 2' "$foreign_callback_state"
grep -qx 'count: 1' "$foreign_callback_state"
grep -qx 'loop_emitted: true' "$foreign_callback_state"
cp -- "$foreign_callback_state" "$tmp/foreign-state.before"
env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$foreign_root" \
  bash "$CODEX_ROOT/hooks/stop-gate.sh" <"$foreign_input" >"$foreign_out"
assert_stop_loop_continuation "$foreign_out"
cmp -s "$tmp/expected-continue.json" "$foreign_out"
cmp -s "$tmp/foreign-state.before" "$foreign_callback_state"
cmp -s "$tmp/foreign-marker.before" "$foreign_marker"
cmp -s "$tmp/foreign-wait.before" "$foreign_wait"
cmp -s "$tmp/foreign-report.before" "$foreign_report"
[ ! -e "$foreign_root/$foreign_peer_session/stop_loop_state" ]

# The same foreign owner must also block an ordinary callback carrying a
# transcript path; later transcript handling cannot fall through to clean-turn
# continuation.
foreign_transcript_callback_session=t00-foreign-transcript-callback
foreign_transcript_input="$tmp/foreign-transcript-input.json"
jq -cn --arg cwd "$ROOT" --arg session_id "$foreign_transcript_callback_session" \
  --arg transcript "$tmp/nonexistent-foreign-transcript.jsonl" \
  '{session_id:$session_id,transcript_path:$transcript,stop_hook_active:false,cwd:$cwd}' \
  >"$foreign_transcript_input"
foreign_transcript_active_reason="[ECI_STOP_ACTIVE_ECI] Stop is denied because callback session $foreign_transcript_callback_session has no direct active ECI marker; the fully validated active ECI marker at $foreign_marker is owned by different session $foreign_peer_session and bound to the same canonical cwd. The marker remains authoritative. Resume actual active ECI work or complete valid normal teardown before retrying Stop. Do not retry unchanged Stop."
env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$foreign_root" \
  bash "$CODEX_ROOT/hooks/stop-gate.sh" <"$foreign_transcript_input" >"$foreign_out"
jq -e --arg reason "$foreign_transcript_active_reason" '
  .decision == "block" and
  (has("continue") | not) and
  ((.reason // "") | startswith($reason)) and
  ((.reason // "") | contains("[ECI_STOP_LOOP_CONTRACT_DEFECT]") | not)
' "$foreign_out" >/dev/null || {
  cat "$foreign_out" >&2
  exit 1
}
[ -f "$foreign_root/$foreign_transcript_callback_session/stop_loop_state" ]
cmp -s "$tmp/foreign-marker.before" "$foreign_marker"
cmp -s "$tmp/foreign-wait.before" "$foreign_wait"
cmp -s "$tmp/foreign-report.before" "$foreign_report"

# Two foreign same-cwd owners remain an ambiguity for both callback identity
# and lifecycle artifacts; no direct marker is required to reach this block.
two_foreign_root="$tmp/two-foreign-root"
two_foreign_one=t00-two-foreign-one
two_foreign_two=t00-two-foreign-two
two_foreign_callback=t00-two-foreign-callback
two_foreign_input="$tmp/two-foreign-input.json"
arm_direct_wait_fixture "$two_foreign_root" "$two_foreign_one"
arm_direct_wait_fixture "$two_foreign_root" "$two_foreign_two"
for peer_session in "$two_foreign_one" "$two_foreign_two"; do
  cp -- "$two_foreign_root/$peer_session/eci_active" "$tmp/$peer_session-marker.before"
  cp -- "$two_foreign_root/$peer_session/eci_wait" "$tmp/$peer_session-wait.before"
  cp -- "$two_foreign_root/$peer_session/eci_user_owned_wait.md" "$tmp/$peer_session-report.before"
done
jq -cn --arg cwd "$ROOT" --arg session_id "$two_foreign_callback" \
  '{session_id:$session_id,transcript_path:"",stop_hook_active:false,cwd:$cwd}' \
  >"$two_foreign_input"
two_foreign_state="$two_foreign_root/$two_foreign_callback/stop_loop_state"
two_foreign_ambiguity_reason="[ECI_STOP_MARKER_AMBIGUOUS] Stop is denied because multiple fully validated ECI markers are bound to this callback cwd: session=$two_foreign_callback cwd=$ROOT. Resolve duplicate ECI ownership through the coordinator route before retrying Stop."
env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$two_foreign_root" \
  bash "$CODEX_ROOT/hooks/stop-gate.sh" <"$two_foreign_input" >"$foreign_out"
jq -e --arg reason "$two_foreign_ambiguity_reason" '
  .decision == "block" and
  (has("continue") | not) and
  ((.reason // "") | startswith($reason))
' "$foreign_out" >/dev/null || {
  cat "$foreign_out" >&2
  exit 1
}
grep -qx 'version: 2' "$two_foreign_state"
grep -qx 'count: 1' "$two_foreign_state"
grep -qx 'loop_emitted: true' "$two_foreign_state"
cp -- "$two_foreign_state" "$tmp/two-foreign-state.before"
env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$two_foreign_root" \
  bash "$CODEX_ROOT/hooks/stop-gate.sh" <"$two_foreign_input" >"$foreign_out"
assert_stop_loop_continuation "$foreign_out"
cmp -s "$tmp/expected-continue.json" "$foreign_out"
cmp -s "$tmp/two-foreign-state.before" "$two_foreign_state"
for peer_session in "$two_foreign_one" "$two_foreign_two"; do
  cmp -s "$tmp/$peer_session-marker.before" "$two_foreign_root/$peer_session/eci_active"
  cmp -s "$tmp/$peer_session-wait.before" "$two_foreign_root/$peer_session/eci_wait"
  cmp -s "$tmp/$peer_session-report.before" "$two_foreign_root/$peer_session/eci_user_owned_wait.md"
done
[ ! -e "$two_foreign_root/$two_foreign_one/stop_loop_state" ]
[ ! -e "$two_foreign_root/$two_foreign_two/stop_loop_state" ]

# A fully validated peer for a different canonical cwd is not an owner for
# this callback and leaves the ordinary inactive path unchanged.
different_cwd_root="$tmp/different-cwd-foreign-root"
different_cwd_peer=t00-different-cwd-peer
different_cwd_callback=t00-different-cwd-callback
different_cwd="$tmp/different-cwd-peer-cwd"
different_cwd_input="$tmp/different-cwd-foreign-input.json"
mkdir -p "$different_cwd_root/$different_cwd_peer" "$different_cwd"
printf 'scope: different cwd foreign peer\ncwd: %s\nsession_id: %s\n' \
  "$different_cwd" "$different_cwd_peer" >"$different_cwd_root/$different_cwd_peer/eci_active"
cp -- "$different_cwd_root/$different_cwd_peer/eci_active" "$tmp/different-cwd-marker.before"
jq -cn --arg cwd "$ROOT" --arg session_id "$different_cwd_callback" \
  '{session_id:$session_id,transcript_path:"",stop_hook_active:false,cwd:$cwd}' \
  >"$different_cwd_input"
env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$different_cwd_root" \
  bash "$CODEX_ROOT/hooks/stop-gate.sh" <"$different_cwd_input" >"$foreign_out"
[ "$(cat "$foreign_out")" = '{"continue":true}' ]
[ ! -e "$different_cwd_root/$different_cwd_callback/stop_loop_state" ]
cmp -s "$tmp/different-cwd-marker.before" "$different_cwd_root/$different_cwd_peer/eci_active"

# A regex-readable but malformed callback cannot use direct eci_wait evidence
# to weaken active-marker denial. Each replay stays stateless and preserves all
# wait artifacts.
malformed_wait_root="$tmp/malformed-json-wait-root"
malformed_wait_session=t00-malformed-json-wait
malformed_wait_input="$tmp/malformed-json-wait-input.json"
malformed_wait_out="$tmp/malformed-json-wait-output.json"
arm_direct_wait_fixture "$malformed_wait_root" "$malformed_wait_session"
malformed_wait_marker="$malformed_wait_root/$malformed_wait_session/eci_active"
malformed_wait_state="$malformed_wait_root/$malformed_wait_session/eci_wait"
malformed_wait_report="$malformed_wait_root/$malformed_wait_session/eci_user_owned_wait.md"
cp -- "$malformed_wait_marker" "$tmp/malformed-json-wait-marker.before"
cp -- "$malformed_wait_state" "$tmp/malformed-json-wait-state.before"
cp -- "$malformed_wait_report" "$tmp/malformed-json-wait-report.before"
printf '{"session_id":"%s","cwd":"%s","transcript_path":"","stop_hook_active":false\n' \
  "$malformed_wait_session" "$ROOT" >"$malformed_wait_input"
for callback in 1 2 3; do
  env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$malformed_wait_root" \
    bash "$CODEX_ROOT/hooks/stop-gate.sh" <"$malformed_wait_input" >"$malformed_wait_out"
  jq -e '
    .decision == "block" and
    (has("continue") | not) and
    ((.reason // "") | startswith("[ECI_STOP_IDENTITY_MALFORMED]")) and
    ((.reason // "") | contains("[ECI_STOP_LOOP_CONTRACT_DEFECT]") | not)
  ' "$malformed_wait_out" >/dev/null || {
    cat "$malformed_wait_out" >&2
    exit 1
  }
done
[ ! -e "$malformed_wait_root/$malformed_wait_session/stop_loop_state" ]
cmp -s "$tmp/malformed-json-wait-marker.before" "$malformed_wait_marker"
cmp -s "$tmp/malformed-json-wait-state.before" "$malformed_wait_state"
cmp -s "$tmp/malformed-json-wait-report.before" "$malformed_wait_report"

# Malformed/no-marker callbacks normally continue, but a malformed callback
# must not continue when bounded marker discovery itself is unsafe.
malformed_unsafe_root="$tmp/malformed-unsafe-root"
malformed_unsafe_input="$tmp/malformed-unsafe-input.json"
malformed_unsafe_out="$tmp/malformed-unsafe-output.json"
printf '%s\n' 'proof root replaced by a regular file' >"$malformed_unsafe_root"
printf '{"session_id":"t00-malformed-unsafe","cwd":"%s"\n' "$ROOT" \
  >"$malformed_unsafe_input"
env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$malformed_unsafe_root" \
  bash "$CODEX_ROOT/hooks/stop-gate.sh" <"$malformed_unsafe_input" >"$malformed_unsafe_out"
jq -e '
  .decision == "block" and
  (has("continue") | not) and
  ((.reason // "") | contains("[ECI_STOP_MARKER_SCAN_UNSAFE]"))
' "$malformed_unsafe_out" >/dev/null || {
  cat "$malformed_unsafe_out" >&2
  exit 1
}
[ "$(cat "$malformed_unsafe_root")" = 'proof root replaced by a regular file' ]

# Wait artifacts cannot weaken same-cwd peer ownership checks. The direct
# marker must still bind to the callback cwd before ordinary blocking.
cross_cwd_wait_root="$tmp/cross-cwd-wait-root"
cross_cwd_wait_session=t00-cross-cwd-wait-direct
cross_cwd_marker_cwd="$tmp/cross-cwd-marker-cwd"
mkdir -p "$cross_cwd_marker_cwd" \
  "$cross_cwd_wait_root/t00-cross-cwd-wait-peer-one" \
  "$cross_cwd_wait_root/t00-cross-cwd-wait-peer-two"
arm_direct_wait_fixture "$cross_cwd_wait_root" "$cross_cwd_wait_session"
printf 'scope: cross cwd direct wait\ncwd: %s\nsession_id: %s\n' \
  "$cross_cwd_marker_cwd" "$cross_cwd_wait_session" \
  >"$cross_cwd_wait_root/$cross_cwd_wait_session/eci_active"
printf 'scope: first callback peer\ncwd: %s\nsession_id: t00-cross-cwd-wait-peer-one\n' "$ROOT" \
  >"$cross_cwd_wait_root/t00-cross-cwd-wait-peer-one/eci_active"
printf 'scope: second callback peer\ncwd: %s\nsession_id: t00-cross-cwd-wait-peer-two\n' "$ROOT" \
  >"$cross_cwd_wait_root/t00-cross-cwd-wait-peer-two/eci_active"
assert_direct_wait_blocked "$cross_cwd_wait_root" "$cross_cwd_wait_session"

# A direct session directory may not be followed through a symlink merely
# because its final marker and user-owned wait records are individually valid.
direct_symlink_backing_root="$tmp/direct-session-symlink-backing"
direct_symlink_root="$tmp/direct-session-symlink-root"
direct_symlink_session=t00-direct-session-symlink
arm_direct_wait_fixture "$direct_symlink_backing_root" "$direct_symlink_session"
mkdir -p "$direct_symlink_root"
ln -s -- "$direct_symlink_backing_root/$direct_symlink_session" \
  "$direct_symlink_root/$direct_symlink_session"
assert_direct_wait_blocked "$direct_symlink_root" "$direct_symlink_session"

# Marker discovery does not follow a peer session-directory symlink. That
# hidden peer must nevertheless fail closed while wait artifacts are preserved.
peer_symlink_wait_root="$tmp/peer-session-symlink-root"
peer_symlink_wait_session=t00-peer-session-symlink-direct
peer_symlink_target="$tmp/peer-session-symlink-target"
arm_direct_wait_fixture "$peer_symlink_wait_root" "$peer_symlink_wait_session"
mkdir -p "$peer_symlink_target"
printf 'scope: hidden peer\ncwd: %s\nsession_id: t00-peer-session-symlink\n' "$ROOT" \
  >"$peer_symlink_target/eci_active"
ln -s -- "$peer_symlink_target" \
  "$peer_symlink_wait_root/t00-peer-session-symlink"
assert_direct_wait_blocked "$peer_symlink_wait_root" "$peer_symlink_wait_session"
jq -e '
  .decision == "block" and
  ((.continue // false) | not) and
  (.reason | contains("[ECI_STOP_MARKER_SCAN_UNSAFE]")) and
  (.reason | contains("immediate proof-root child symlink")) and
  (.reason | contains("repair or remove")) and
  (.reason | contains("[ECI_STOP_ACTIVE_ECI]") | not)
' "$stop_out" >/dev/null || {
  cat "$stop_out" >&2
  exit 1
}
[ ! -e "$peer_symlink_wait_root/$peer_symlink_wait_session/stop_loop_state" ] || {
  printf 'unsafe sibling scan created direct stop-loop state\n' >&2
  exit 1
}
[ ! -e "$peer_symlink_wait_root/$peer_symlink_wait_session/stop_timestamps" ] || {
  printf 'unsafe sibling scan created direct stop timestamps\n' >&2
  exit 1
}

# A peer marker is never ignored just because the direct owner has a valid
# wait. Every peer must be regular, single-linked, and schema-valid.
malformed_wait_peer_root="$tmp/malformed-wait-peer-root"
malformed_wait_peer_session=t00-malformed-wait-direct
mkdir -p "$malformed_wait_peer_root/t00-malformed-wait-peer"
arm_direct_wait_fixture "$malformed_wait_peer_root" "$malformed_wait_peer_session"
printf 'scope: \ncwd: %s\nsession_id: t00-malformed-wait-peer\n' "$ROOT" \
  >"$malformed_wait_peer_root/t00-malformed-wait-peer/eci_active"
assert_direct_wait_blocked "$malformed_wait_peer_root" "$malformed_wait_peer_session"

hardlink_wait_peer_root="$tmp/hardlink-wait-peer-root"
hardlink_wait_peer_session=t00-hardlink-wait-direct
mkdir -p "$hardlink_wait_peer_root/t00-hardlink-wait-peer"
arm_direct_wait_fixture "$hardlink_wait_peer_root" "$hardlink_wait_peer_session"
hardlink_wait_peer_target="$tmp/hardlink-wait-peer-target"
printf 'scope: hardlinked wait peer\ncwd: %s\nsession_id: t00-hardlink-wait-peer\n' "$ROOT" \
  >"$hardlink_wait_peer_target"
ln -- "$hardlink_wait_peer_target" \
  "$hardlink_wait_peer_root/t00-hardlink-wait-peer/eci_active"
assert_direct_wait_blocked "$hardlink_wait_peer_root" "$hardlink_wait_peer_session"

symlink_wait_peer_root="$tmp/symlink-wait-peer-root"
symlink_wait_peer_session=t00-symlink-wait-direct
mkdir -p "$symlink_wait_peer_root/t00-symlink-wait-peer"
arm_direct_wait_fixture "$symlink_wait_peer_root" "$symlink_wait_peer_session"
symlink_wait_peer_target="$tmp/symlink-wait-peer-target"
printf 'scope: symlinked wait peer\ncwd: %s\nsession_id: t00-symlink-wait-peer\n' "$ROOT" \
  >"$symlink_wait_peer_target"
ln -s -- "$symlink_wait_peer_target" \
  "$symlink_wait_peer_root/t00-symlink-wait-peer/eci_active"
assert_direct_wait_blocked "$symlink_wait_peer_root" "$symlink_wait_peer_session"

# The same full-scan path must still validate the direct wait and report.
invalid_wait_root="$tmp/invalid-wait-with-peer-root"
invalid_wait_session=t00-invalid-wait-direct
mkdir -p "$invalid_wait_root/t00-invalid-wait-peer"
arm_direct_wait_fixture "$invalid_wait_root" "$invalid_wait_session"
printf 'scope: valid wait peer\ncwd: %s\nsession_id: t00-invalid-wait-peer\n' "$ROOT" \
  >"$invalid_wait_root/t00-invalid-wait-peer/eci_active"
printf 'state: user-owned-wait\ninvalid: true\n' \
  >"$invalid_wait_root/$invalid_wait_session/eci_wait"
assert_direct_wait_blocked "$invalid_wait_root" "$invalid_wait_session"

mismatched_wait_root="$tmp/mismatched-wait-with-peer-root"
mismatched_wait_session=t00-mismatched-wait-direct
mkdir -p "$mismatched_wait_root/t00-mismatched-wait-peer"
arm_direct_wait_fixture "$mismatched_wait_root" "$mismatched_wait_session"
printf 'scope: valid wait peer\ncwd: %s\nsession_id: t00-mismatched-wait-peer\n' "$ROOT" \
  >"$mismatched_wait_root/t00-mismatched-wait-peer/eci_active"
sed -i 's/user-owned input required/user-owned input changed/' \
  "$mismatched_wait_root/$mismatched_wait_session/eci_user_owned_wait.md"
assert_direct_wait_blocked "$mismatched_wait_root" "$mismatched_wait_session"

# Wait artifacts never skip the global bounded-marker preflight or proof-root
# integrity check.
overflow_wait_root="$tmp/overflow-wait-root"
overflow_wait_session=t00-overflow-wait-direct
arm_direct_wait_fixture "$overflow_wait_root" "$overflow_wait_session"
for i in $(seq 1 64); do
  overflow_wait_peer="t00-overflow-wait-peer-$i"
  mkdir -p "$overflow_wait_root/$overflow_wait_peer"
  printf 'scope: overflow wait peer\ncwd: /other/cwd\nsession_id: %s\n' \
    "$overflow_wait_peer" >"$overflow_wait_root/$overflow_wait_peer/eci_active"
done
assert_direct_wait_blocked "$overflow_wait_root" "$overflow_wait_session"

unsafe_wait_root="$tmp/unsafe-wait-root"
unsafe_wait_session=t00-unsafe-wait-direct
arm_direct_wait_fixture "$unsafe_wait_root" "$unsafe_wait_session"
mv -- "$unsafe_wait_root" "$unsafe_wait_root.backing"
printf '%s\n' 'unsafe proof root replacement' >"$unsafe_wait_root"
assert_direct_wait_blocked "$unsafe_wait_root" "$unsafe_wait_session"
[ "$(cat "$unsafe_wait_root")" = 'unsafe proof root replacement' ]

invalid_identity_root="$tmp/invalid-identity-root"
mkdir -p "$invalid_identity_root/t00-one"
printf 'scope: active\ncwd: %s\nsession_id: t00-one\n' "$ROOT" >"$invalid_identity_root/t00-one/eci_active"
jq -n --arg cwd "$ROOT" \
  '{session_id:"invalid!",transcript_path:"",stop_hook_active:true,cwd:$cwd}' >"$stop_input"
env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$invalid_identity_root" \
  bash "$CODEX_ROOT/hooks/stop-gate.sh" <"$stop_input" >"$stop_out"
[ "$(jq -r '.decision // empty' "$stop_out")" = block ]
jq -e '.reason | startswith("[ECI_STOP_IDENTITY_MALFORMED]")' "$stop_out" >/dev/null

# The active-marker scan has a fixed resource bound.  Valid markers for other
# cwds must not turn an oversized proof root into an unbounded callback.
overflow_root="$tmp/overflow-root"
mkdir -p "$overflow_root"
for i in $(seq 1 65); do
  overflow_sid="t00-overflow-$i"
  mkdir -p "$overflow_root/$overflow_sid"
  printf 'scope: overflow\ncwd: /other/cwd\nsession_id: %s\n' "$overflow_sid" \
    >"$overflow_root/$overflow_sid/eci_active"
done
jq -n --arg cwd "$ROOT" \
  '{session_id:"invalid!",transcript_path:"",stop_hook_active:true,cwd:$cwd}' >"$stop_input"
env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$overflow_root" \
  bash "$CODEX_ROOT/hooks/stop-gate.sh" <"$stop_input" >"$stop_out"
[ "$(jq -r '.decision // empty' "$stop_out")" = block ]
[ ! -e "$overflow_root/t00-overflow-caller/stop_timestamps" ]

# A single oversized marker remains unsafe before Stop metadata validation.
# Read-only lifecycle status separately reports a compact advisory summary.
oversized_root="$tmp/oversized-root"
mkdir -p "$oversized_root/t00-oversized"
{
  printf 'scope: '
  head -c 5000 /dev/zero | tr '\0' x
  printf '\ncwd: /other/cwd\nsession_id: t00-oversized\n'
} >"$oversized_root/t00-oversized/eci_active"
jq -n --arg cwd "$ROOT" \
  '{session_id:"invalid!",transcript_path:"",stop_hook_active:true,cwd:$cwd}' >"$stop_input"
env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$oversized_root" \
  bash "$CODEX_ROOT/hooks/stop-gate.sh" <"$stop_input" >"$stop_out"
[ "$(jq -r '.decision // empty' "$stop_out")" = block ]
[ ! -e "$oversized_root/t00-oversized-caller/stop_timestamps" ]
if ! CODEX_SESSION_ID=t00-oversized CODEX_PROOF_ROOT="$oversized_root" \
    "$CODEX_ROOT/bin/eci-active" status >"$tmp/oversized-status.out" 2>"$tmp/oversized-status.err"; then
  printf 'oversized marker blocked ordinary eci-active status\n' >&2
  exit 1
fi
grep -Fqx "ECI active: $oversized_root/t00-oversized/eci_active" "$tmp/oversized-status.out" || {
  printf 'oversized marker status did not report a compact direct-marker summary\n' >&2
  cat "$tmp/oversized-status.out" >&2
  exit 1
}
grep -Fqx 'session_id: t00-oversized' "$tmp/oversized-status.out" || {
  printf 'oversized marker status did not report the direct session\n' >&2
  cat "$tmp/oversized-status.out" >&2
  exit 1
}
if grep -Fq 'scope: ' "$tmp/oversized-status.out" || [ "$(wc -c <"$tmp/oversized-status.out")" -ge 1024 ]; then
  printf 'oversized marker status emitted raw marker metadata\n' >&2
  cat "$tmp/oversized-status.out" >&2
  exit 1
fi
[ ! -s "$tmp/oversized-status.err" ] || {
  printf 'oversized marker status wrote stderr\n' >&2
  cat "$tmp/oversized-status.err" >&2
  exit 1
}

# A bounded but malformed direct marker must retain its concrete path and
# classify the content failure as ECI_MARKER_MALFORMED, not as an ambiguous
# proof-root scan failure.
malformed_direct_root="$tmp/malformed-direct-root"
mkdir -p "$malformed_direct_root/t00-malformed"
malformed_direct_marker="$malformed_direct_root/t00-malformed/eci_active"
printf '%s\n' 'scope: malformed direct marker' >"$malformed_direct_marker"
jq -n --arg cwd "$ROOT" \
  '{session_id:"t00-malformed",transcript_path:"",stop_hook_active:true,cwd:$cwd}' >"$stop_input"
env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$malformed_direct_root" \
  bash "$CODEX_ROOT/hooks/stop-gate.sh" <"$stop_input" >"$stop_out"
[ "$(jq -r '.decision // empty' "$stop_out")" = block ]
jq -e --arg marker "$malformed_direct_marker" \
  '.reason | contains("[ECI_MARKER_MALFORMED]") and contains($marker) and (contains("[ECI_STOP_MARKER_SCAN_UNSAFE]") | not)' \
  "$stop_out" >/dev/null
[ ! -e "$malformed_direct_root/t00-malformed/stop_timestamps" ]

# A duplicate identity key must not be resolved by the first regex match. The
# active-marker path performs one strict object/duplicate/type check and blocks
# without creating callback bookkeeping.
duplicate_json_root="$tmp/duplicate-json-root"
mkdir -p "$duplicate_json_root/t00-one"
printf 'scope: duplicate json\ncwd: %s\nsession_id: t00-one\n' "$ROOT" >"$duplicate_json_root/t00-one/eci_active"
printf '{"session_id":"t00-one","session_id":"t00-two","cwd":"%s","transcript_path":"","stop_hook_active":true}\n' "$ROOT" >"$stop_input"
env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$duplicate_json_root" \
  bash "$CODEX_ROOT/hooks/stop-gate.sh" <"$stop_input" >"$stop_out"
[ "$(jq -r '.decision // empty' "$stop_out")" = block ]
[ ! -e "$duplicate_json_root/t00-one/stop_timestamps" ]

invalid_symlink_identity_root="$tmp/invalid-symlink-identity-root"
mkdir -p "$invalid_symlink_identity_root/t00-one"
printf '%s\n' 'scope: unsafe marker target' >"$tmp/unsafe-marker-target"
ln -s "$tmp/unsafe-marker-target" "$invalid_symlink_identity_root/t00-one/eci_active"
env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$invalid_symlink_identity_root" \
  bash "$CODEX_ROOT/hooks/stop-gate.sh" <"$stop_input" >"$stop_out"
[ "$(jq -r '.decision // empty' "$stop_out")" = block ] || {
  cat "$stop_out" >&2
  exit 1
}

# A proof marker must not be consumable through a hardlink alias.  The
# metadata is identical, but the link count proves that an unrelated path can
# mutate the same control bytes; readers fail closed before treating it as an
# active owner.
hardlink_identity_root="$tmp/hardlink-identity-root"
mkdir -p "$hardlink_identity_root/t00-one"
printf 'scope: hardlink\ncwd: %s\nsession_id: t00-one\n' "$ROOT" \
  >"$hardlink_identity_root/t00-one/eci_active"
ln "$hardlink_identity_root/t00-one/eci_active" "$tmp/eci-active-hardlink-alias"
jq -n --arg cwd "$ROOT" \
  '{session_id:"t00-one",transcript_path:"",stop_hook_active:true,cwd:$cwd}' >"$stop_input"
env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$hardlink_identity_root" \
  bash "$CODEX_ROOT/hooks/stop-gate.sh" <"$stop_input" >"$stop_out"
[ "$(jq -r '.decision // empty' "$stop_out")" = block ]
[ ! -e "$hardlink_identity_root/t00-one/stop_timestamps" ]

# The path owner is part of the marker identity.  A marker embedded with a
# different session must not become invisible simply because the requested
# session has no matching directory; discovery scans it and fails closed.
mismatched_owner_root="$tmp/mismatched-owner-root"
mkdir -p "$mismatched_owner_root/t00-one"
printf 'scope: mismatch\ncwd: %s\nsession_id: t00-two\n' "$ROOT" \
  >"$mismatched_owner_root/t00-one/eci_active"
jq -n --arg cwd "$ROOT" \
  '{session_id:"invalid!",transcript_path:"",stop_hook_active:true,cwd:$cwd}' >"$stop_input"
env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$mismatched_owner_root" \
  bash "$CODEX_ROOT/hooks/stop-gate.sh" <"$stop_input" >"$stop_out"
[ "$(jq -r '.decision // empty' "$stop_out")" = block ]
[ ! -e "$mismatched_owner_root/t00-two/stop_timestamps" ]

# Root-integrity regression: replacing an active proof root or its parent with
# a regular file must block read-only before transcriptless continuation.
swap_root="$tmp/swap-root"
mkdir -p "$swap_root/t00-session"
printf 'scope: before root swap\n' >"$swap_root/t00-session/eci_active"
mv "$swap_root" "$swap_root.original"
printf 'root replaced\n' >"$swap_root"
jq -n --arg cwd "$ROOT" \
  '{session_id:"t00-session",transcript_path:"",stop_hook_active:true,cwd:$cwd}' >"$stop_input"
env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$swap_root" \
  bash "$CODEX_ROOT/hooks/stop-gate.sh" <"$stop_input" >"$stop_out"
[ "$(jq -r '.decision // empty' "$stop_out")" = block ]
[ "$(cat "$swap_root")" = 'root replaced' ]

swap_parent="$tmp/swap-parent"
mkdir -p "$swap_parent/proof/t00-session"
printf 'scope: before parent swap\n' >"$swap_parent/proof/t00-session/eci_active"
mv "$swap_parent" "$swap_parent.original"
printf 'parent replaced\n' >"$swap_parent"
swap_parent_root="$swap_parent/proof"
env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$swap_parent_root" \
  bash "$CODEX_ROOT/hooks/stop-gate.sh" <"$stop_input" >"$stop_out"
[ "$(jq -r '.decision // empty' "$stop_out")" = block ]
[ "$(cat "$swap_parent")" = 'parent replaced' ]

# A worker with a different session id must still route through its validated
# parent marker when unrelated proof-root entries exhaust the bounded scan.
# Parent metadata is resolved directly from the bounded transcript record.
overflow_edit_root="$tmp/overflow-edit-root"
mkdir -p "$overflow_edit_root"
for i in $(seq 1 65); do
  mkdir -p "$overflow_edit_root/t00-edit-unrelated-$i"
done
mkdir -p "$overflow_edit_root/parent-session"
printf 'scope: parent worker\ncwd: %s\nsession_id: parent-session\n' "$ROOT" \
  >"$overflow_edit_root/parent-session/eci_active"
mkdir -p "$home/.codex/sessions"
overflow_transcript="$home/.codex/sessions/overflow-worker.jsonl"
printf '%s\n' '{"type":"session_meta","payload":{"source":{"subagent":{"thread_spawn":{"parent_thread_id":"parent-session","depth":1,"agent_nickname":"Overflow","agent_role":"worker"}}}}}' \
  >"$overflow_transcript"
overflow_edit_input="$tmp/overflow-edit.json"
jq -n --arg cwd "$ROOT" --arg transcript "$overflow_transcript" \
  '{session_id:"child-session",cwd:$cwd,transcript_path:$transcript,tool_name:"apply_patch",tool_input:{command:"*** Begin Patch\\n*** Add File: worker-file.txt\\n+worker\\n*** End Patch\\n"}}' >"$overflow_edit_input"
env -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$overflow_edit_root" \
  bash "$CODEX_ROOT/hooks/eci-active-gate.sh" <"$overflow_edit_input" >"$tmp/overflow-edit.out"
[ ! -s "$tmp/overflow-edit.out" ]

# An inactive coordinator callback must ignore an overflow made entirely of
# unrelated proof-root entries.  The direct current-session lookup is the
# authority; an empty direct marker must not become MISSING_CURRENT merely
# because the bounded unrelated scan emitted its overflow sentinel.
inactive_overflow_edit_root="$tmp/inactive-overflow-edit-root"
mkdir -p "$inactive_overflow_edit_root"
for i in $(seq 1 65); do
  mkdir -p "$inactive_overflow_edit_root/t00-inactive-unrelated-$i"
  printf 'scope: unrelated overflow\ncwd: /other/cwd\nsession_id: t00-inactive-unrelated-%s\n' "$i" \
    >"$inactive_overflow_edit_root/t00-inactive-unrelated-$i/eci_active"
done
inactive_overflow_edit_input="$tmp/inactive-overflow-edit.json"
jq -n --arg cwd "$ROOT" \
  '{session_id:"t00-inactive-overflow",cwd:$cwd,tool_name:"apply_patch",tool_input:{command:"*** Begin Patch\n*** Add File: inactive-overflow-file.txt\n+inactive\n*** End Patch\n"}}' >"$inactive_overflow_edit_input"
env -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$inactive_overflow_edit_root" \
  bash "$CODEX_ROOT/hooks/eci-active-gate.sh" <"$inactive_overflow_edit_input" >"$tmp/inactive-overflow-edit.out"
[ ! -s "$tmp/inactive-overflow-edit.out" ]

# A malformed callback must likewise remain inactive when the bounded scan
# sees only unrelated entries.  The overflow sentinel is a scan limitation,
# not an active owner and must not fabricate an identity denial.
malformed_overflow_edit_input="$tmp/malformed-overflow-edit.json"
jq -n --arg cwd "$ROOT" \
  '{session_id:123,cwd:$cwd,tool_name:"Edit",tool_input:{file_path:"inactive-overflow-file.txt"}}' \
  >"$malformed_overflow_edit_input"
env -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$inactive_overflow_edit_root" \
  bash "$CODEX_ROOT/hooks/eci-active-gate.sh" <"$malformed_overflow_edit_input" >"$tmp/malformed-overflow-edit.out"
[ ! -s "$tmp/malformed-overflow-edit.out" ]

# The active path may publish only its bounded deduplication record. It must
# not create stop_timestamps or any unrelated proof-root/recovery state.
[ ! -e "$proof_root/t00-session/stop_timestamps" ]
while IFS= read -r found_state; do
  case "$found_state" in
    "$proof_root/t00-session/stop_loop_state") ;;
    *) printf 'unexpected active-path state file: %s\n' "$found_state" >&2; exit 1 ;;
  esac
done < <(find "$proof_root" -type f ! -name eci_active -print)
[ ! -e "$home/tmp" ]

if command -v strace >/dev/null 2>&1; then
  trace="$tmp/trace"
  strace -f -qq -e trace=process,file -o "$trace" \
    env -u CODEX_HOME -u CODEX_ROLE HOME="$home" CODEX_PROOF_ROOT="$proof_root" \
    bash "$CODEX_ROOT/hooks/stop-gate.sh" <"$input" >"$out"
  state_writes="$(awk -v proof_root="$proof_root" -v home="$home" '
    /O_(WRONLY|RDWR|CREAT|TRUNC)|mkdir\(|rename\(|unlink\(/ &&
      (index($0, proof_root) || index($0, home)) {
      # stop_loop_state and its same-directory temporary publication are the
      # only intentional active-path writes; all other proof/recovery writes
      # remain a failure.
      if (index($0, proof_root "/t00-session/stop_loop_state")) next
      print
    }
  ' "$trace" || true)"
  if [ -n "$state_writes" ]; then
    printf 'active path performed a state write:\n' >&2
    printf '%s\n' "$state_writes" >&2
    exit 1
  fi
  ! grep -Eq 'execve\(".*/(jq|python3)"' "$trace"
fi

# Each fresh callback stays below one second on the supported fast path;
# this is a measurement, not a timeout or a runtime guard.
[ "$max_ms" -lt 1000 ]
printf 'PASS active ECI fast path: 5 callbacks, max %sms; only bounded stop-loop state writes\n' "$max_ms"
