#!/usr/bin/env bash

# Stop is a post-response continuation hook. A valid active marker gets one
# useful reminder; identical later callbacks continue so the client does not
# loop through repeated final/retry/poll attempts.

set -euo pipefail

ROOT="${ECI_TEST_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
TMP_PARENT="${CODEX_TMPDIR:-${TMPDIR:-${HOME:?}/tmp}}"
mkdir -p -- "$TMP_PARENT"
TMP_ROOT="$(mktemp -d "$TMP_PARENT/eci-stop-loop.XXXXXX")"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

FIXTURE_HOME="$TMP_ROOT/home"
FIXTURE_CODEX="$FIXTURE_HOME/.codex"
PROOF_ROOT="$TMP_ROOT/proof"
REPO="$TMP_ROOT/repo"

mkdir -p -- "$FIXTURE_CODEX" "$FIXTURE_HOME/tmp" "$PROOF_ROOT" "$REPO"
cp -a -- "$ROOT/hooks" "$FIXTURE_CODEX/hooks"

run_stop() {
  local input="$1" output="$2" proof_root="${3:-$PROOF_ROOT}"

  env -u CODEX_HOME -u CODEX_ROLE \
    HOME="$FIXTURE_HOME" CODEX_PROOF_ROOT="$proof_root" \
    bash "$FIXTURE_CODEX/hooks/stop-gate.sh" <"$input" >"$output"
}

write_marker() {
  local proof_root="$1" session="$2" marker_cwd="$3"
  local marker="$proof_root/$session/eci_active"

  mkdir -p -- "${marker%/*}"
  printf 'scope: stop-loop fixture\ncwd: %s\nsession_id: %s\ncreated_utc: 2026-08-28T00:00:00Z\n' \
    "$marker_cwd" "$session" >"$marker"
  printf '%s\n' "$marker"
}

assert_continue() {
  local output="$1"

  jq -e '.continue == true and (has("decision") | not)' "$output" >/dev/null || {
    cat "$output" >&2
    exit 1
  }
}

git -C "$REPO" init -q
git -C "$REPO" config user.email 'eci-stop-loop@example.invalid'
git -C "$REPO" config user.name 'ECI stop loop test'
printf 'base\n' >"$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit -qm 'initial fixture'

# A valid direct marker is authoritative even if sibling records are stale or
# malformed. The first callback tells the agent to resume work or teardown.
session=stop-loop-session
sibling=stale-sibling
marker="$(write_marker "$PROOF_ROOT" "$session" "$REPO")"
mkdir -p -- "$PROOF_ROOT/$sibling"
printf 'stale sibling marker\n' >"$PROOF_ROOT/$sibling/eci_active"
cp -- "$marker" "$TMP_ROOT/marker.before"

input="$TMP_ROOT/input.json"
first="$TMP_ROOT/first.json"
second="$TMP_ROOT/second.json"
third="$TMP_ROOT/third.json"
jq -cn --arg session_id "$session" --arg cwd "$REPO" \
  '{session_id:$session_id,cwd:$cwd,transcript_path:"",stop_hook_active:false}' >"$input"

run_stop "$input" "$first"
jq -e --arg marker "$marker" '
  .decision == "block" and
  ((.reason // "") | contains("[ECI_STOP_ACTIVE_ECI]")) and
  ((.reason // "") | contains($marker)) and
  ((.reason // "") | contains("sibling marker state is advisory")) and
  ((.reason // "") | contains("ECI_STOP_LOOP_CONTRACT_DEFECT") | not)
' "$first" >/dev/null || {
  cat "$first" >&2
  exit 1
}
state="$PROOF_ROOT/$session/stop_loop_state"
grep -qx 'count: 1' "$state"
grep -qx 'loop_emitted: true' "$state"
cmp -s "$TMP_ROOT/marker.before" "$marker"

# The same unchanged callback must be stable continuation, not another Stop
# denial. Its marker and one-reminder state remain untouched.
cp -- "$state" "$TMP_ROOT/state.after-reminder"
run_stop "$input" "$second"
assert_continue "$second"
run_stop "$input" "$third"
assert_continue "$third"
cmp -s "$second" "$third"
cmp -s "$TMP_ROOT/marker.before" "$marker"
cmp -s "$TMP_ROOT/state.after-reminder" "$state"

# An actually mismatched direct marker is still a concrete first-callback
# boundary. It is not converted into a generic sibling or loop diagnostic.
mismatch_root="$TMP_ROOT/mismatch-proof"
mismatch_session=mismatch-session
mkdir -p -- "$mismatch_root/$mismatch_session" "$TMP_ROOT/other-cwd"
printf 'scope: mismatch\ncwd: %s\nsession_id: %s\ncreated_utc: 2026-08-28T00:00:00Z\n' \
  "$TMP_ROOT/other-cwd" "$mismatch_session" >"$mismatch_root/$mismatch_session/eci_active"
mismatch_input="$TMP_ROOT/mismatch-input.json"
mismatch_output="$TMP_ROOT/mismatch-output.json"
jq -cn --arg session_id "$mismatch_session" --arg cwd "$REPO" \
  '{session_id:$session_id,cwd:$cwd,transcript_path:"",stop_hook_active:false}' >"$mismatch_input"
run_stop "$mismatch_input" "$mismatch_output" "$mismatch_root"
jq -e '
  .decision == "block" and
  ((.reason // "") | contains("[ECI_MARKER_SCOPE_MISMATCH]")) and
  ((.reason // "") | contains("ECI_STOP_LOOP_CONTRACT_DEFECT") | not)
' "$mismatch_output" >/dev/null || {
  cat "$mismatch_output" >&2
  exit 1
}

# Once normal teardown leaves no active marker, Stop has no ECI loop boundary.
teardown_root="$TMP_ROOT/teardown-proof"
teardown_output="$TMP_ROOT/teardown-output.json"
run_stop "$input" "$teardown_output" "$teardown_root"
assert_continue "$teardown_output"

printf '%s\n' 'stop loop one-reminder continuation assertions: PASS'
