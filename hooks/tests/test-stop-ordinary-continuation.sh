#!/usr/bin/env bash

# Ordinary Stop callbacks use a private copied hook.  Workflow records and
# callback metadata are advisory unless a valid direct marker names concrete
# active work for this session.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TMP_PARENT="${CODEX_TMPDIR:-${TMPDIR:-${HOME:?}/tmp}}"
mkdir -p -- "$TMP_PARENT"
TMP_ROOT="$(mktemp -d "$TMP_PARENT/stop-ordinary-continuation.XXXXXX")"
FIXTURE_HOME="$TMP_ROOT/home"
FIXTURE_CODEX="$FIXTURE_HOME/.codex"
REPO="$TMP_ROOT/repo"

cp -- "$ROOT/hooks/stop-gate.sh" "$TMP_ROOT/live-stop-gate.before"

cleanup() {
  local status=$?

  if ! cmp -s "$TMP_ROOT/live-stop-gate.before" "$ROOT/hooks/stop-gate.sh"; then
    printf '%s\n' 'the copied-hook test changed the live production Stop hook' >&2
    status=1
  fi
  rm -rf -- "$TMP_ROOT"
  exit "$status"
}
trap cleanup EXIT

# Smoke-test the copied PreToolUse hooks in their existing enabled or bypassed
# state, with any callback state confined to the private fixture.
mkdir -p -- "$FIXTURE_CODEX" "$FIXTURE_HOME/tmp" "$REPO"
cp -a -- "$ROOT/hooks" "$FIXTURE_CODEX/hooks"
(
  export HOME="$FIXTURE_HOME" CODEX_HOME="$FIXTURE_CODEX" CODEX_PROOF_ROOT="$TMP_ROOT/pretooluse-proof"
  export XDG_CONFIG_HOME="$TMP_ROOT/config" XDG_STATE_HOME="$TMP_ROOT/state" XDG_CACHE_HOME="$TMP_ROOT/cache"
  printf '%s\n' '{"tool_name":"Bash"}' | bash "$FIXTURE_CODEX/hooks/validate-bash.sh" >/dev/null
  printf '%s\n' '{"tool_name":"Edit"}' | bash "$FIXTURE_CODEX/hooks/pretooluse-edit-dispatch.sh" >/dev/null
)

git -C "$REPO" init -q
git -C "$REPO" config user.email 'stop-ordinary@example.invalid'
git -C "$REPO" config user.name 'Stop ordinary continuation test'
printf 'base\n' >"$REPO/file.txt"
git -C "$REPO" add file.txt
git -C "$REPO" commit -qm 'initial fixture'

run_stop() {
  local input="$1" output="$2" proof_root="$3"

  env -u CODEX_HOME -u CODEX_ROLE \
    HOME="$FIXTURE_HOME" CODEX_PROOF_ROOT="$proof_root" \
    bash "$FIXTURE_CODEX/hooks/stop-gate.sh" <"$input" >"$output"
}

assert_continue() {
  local output="$1"

  jq -e '.continue == true and (has("decision") | not)' "$output" >/dev/null || {
    cat "$output" >&2
    exit 1
  }
}

write_activity_transcript() {
  local transcript="$1"

  mkdir -p -- "${transcript%/*}"
  printf '%s\n' '{"type":"user","message":{"content":"inspect ordinary work"}}' >"$transcript"
  printf '%s\n' '{"type":"response_item","payload":{"type":"function_call","name":"apply_patch","arguments":"{}"}}' >>"$transcript"
}

write_marker() {
  local proof_root="$1" session="$2" marker_cwd="$3"
  local marker="$proof_root/$session/eci_active"

  mkdir -p -- "${marker%/*}"
  printf 'scope: direct marker fixture\ncwd: %s\nsession_id: %s\ncreated_utc: 2026-08-28T00:00:00Z\n' \
    "$marker_cwd" "$session" >"$marker"
}

# Clean post-user activity is ordinary work.  It must not be converted into a
# manual-checklist Stop denial merely because no workflow marker was written.
ordinary_proof="$TMP_ROOT/ordinary-proof"
ordinary_session=ordinary-session
ordinary_transcript="$FIXTURE_CODEX/sessions/$ordinary_session.jsonl"
ordinary_input="$TMP_ROOT/ordinary-input.json"
ordinary_output="$TMP_ROOT/ordinary-output.json"
mkdir -p -- "$ordinary_proof"
write_activity_transcript "$ordinary_transcript"
jq -cn --arg session_id "$ordinary_session" --arg cwd "$REPO" --arg transcript "$ordinary_transcript" \
  '{session_id:$session_id,cwd:$cwd,transcript_path:$transcript,stop_hook_active:false}' >"$ordinary_input"
run_stop "$ordinary_input" "$ordinary_output" "$ordinary_proof"
assert_continue "$ordinary_output"

# An active ATE phase is workflow ceremony, not a concrete destructive or
# cross-scope target.  It must be advisory and allow the callback to return.
ate_proof="$TMP_ROOT/ate-proof"
ate_session=ate-session
ate_input="$TMP_ROOT/ate-input.json"
ate_output="$TMP_ROOT/ate-output.json"
ate_transcript="$FIXTURE_CODEX/sessions/$ate_session.jsonl"
mkdir -p -- "$ate_proof/ate/sessions/$ate_session"
printf '%s\n' 'phase: execution' >"$ate_proof/ate/sessions/$ate_session/ate_active"
write_activity_transcript "$ate_transcript"
jq -cn --arg session_id "$ate_session" --arg cwd "$REPO" --arg transcript "$ate_transcript" \
  '{session_id:$session_id,cwd:$cwd,transcript_path:$transcript,stop_hook_active:false}' >"$ate_input"
run_stop "$ate_input" "$ate_output" "$ate_proof"
assert_continue "$ate_output"

# A recursive callback with no direct marker continues even when a peer marker
# exists.  Peer discovery and callback metadata cannot manufacture ownership.
peer_proof="$TMP_ROOT/recursive-peer-proof"
recursive_session=recursive-session
peer_input="$TMP_ROOT/recursive-peer-input.json"
peer_output="$TMP_ROOT/recursive-peer-output.json"
mkdir -p -- "$peer_proof"
write_marker "$peer_proof" peer-session "$REPO"
jq -cn --arg session_id "$recursive_session" --arg cwd "$REPO" \
  '{session_id:$session_id,cwd:$cwd,transcript_path:"",stop_hook_active:true}' >"$peer_input"
run_stop "$peer_input" "$peer_output" "$peer_proof"
assert_continue "$peer_output"

# The same is true when the recursive callback has no marker records at all.
empty_proof="$TMP_ROOT/recursive-empty-proof"
empty_input="$TMP_ROOT/recursive-empty-input.json"
empty_output="$TMP_ROOT/recursive-empty-output.json"
mkdir -p -- "$empty_proof"
jq -cn --arg session_id "$recursive_session" --arg cwd "$REPO" \
  '{session_id:$session_id,cwd:$cwd,transcript_path:"",stop_hook_active:true}' >"$empty_input"
run_stop "$empty_input" "$empty_output" "$empty_proof"
assert_continue "$empty_output"

# A valid direct marker retains its one useful reminder; this is the only
# workflow record that can own the callback's active-work boundary.
direct_proof="$TMP_ROOT/recursive-direct-proof"
direct_session=direct-session
direct_input="$TMP_ROOT/recursive-direct-input.json"
direct_first="$TMP_ROOT/recursive-direct-first.json"
direct_second="$TMP_ROOT/recursive-direct-second.json"
mkdir -p -- "$direct_proof"
write_marker "$direct_proof" "$direct_session" "$REPO"
jq -cn --arg session_id "$direct_session" --arg cwd "$REPO" \
  '{session_id:$session_id,cwd:$cwd,transcript_path:"",stop_hook_active:true}' >"$direct_input"
run_stop "$direct_input" "$direct_first" "$direct_proof"
jq -e '.decision == "block" and ((.reason // "") | contains("[ECI_STOP_ACTIVE_ECI]"))' \
  "$direct_first" >/dev/null || {
  cat "$direct_first" >&2
  exit 1
}
run_stop "$direct_input" "$direct_second" "$direct_proof"
assert_continue "$direct_second"

printf '%s\n' 'ordinary Stop continuation assertions: PASS'
