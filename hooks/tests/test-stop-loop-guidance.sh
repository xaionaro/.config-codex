#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_ROOT="$(mktemp -d "/tmp/codex-stop-loop.XXXXXX")"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

proof_root="$TMP_ROOT/proof"
mkdir -p "$proof_root/activity/sessions/t00-session"
printf '%s\n' 'created_utc: 2026-08-17T00:00:00Z' >"$proof_root/activity/sessions/t00-session/shell"
repo="$TMP_ROOT/repo"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config user.email 'eci-test@example.invalid'
git -C "$repo" config user.name 'ECI stop-loop test'
printf '%s\n' 'clean stop-loop fixture' >"$repo/README"
git -C "$repo" add README
git -C "$repo" commit -qm 'create clean stop-loop fixture'
input="$TMP_ROOT/input.json"
jq -cn --arg cwd "$repo" \
  '{session_id:"t00-session",cwd:$cwd,transcript_path:"/tmp/nonexistent-stop-loop-transcript.jsonl",stop_hook_active:false}' >"$input"
output="$TMP_ROOT/output.json"
for _ in 1 2 3 4 5; do
  CODEX_PROOF_ROOT="$proof_root" bash "$ROOT/hooks/stop-gate.sh" <"$input" >"$output"
done

jq -e '
  .decision == "block" and
  (.reason | contains("LOOP DETECTED")) and
  (.reason | contains("unchanged control metadata")) and
  (.reason | contains("Automated stop checks")) and
  (.reason | contains("do not emit another final/status/question")) and
  (.reason | contains("one concrete user-owned blocker")) and
  (.reason | contains("wait for new external state")) and
  (.reason | contains("stop again") | not)
' "$output" >/dev/null || {
  cat "$output" >&2
  exit 1
}

printf '%s\n' 'stop loop guidance assertions: PASS'

# Once the same normalized diagnostic has emitted loop guidance, a repeated
# identical Stop admission must converge to a neutral continuation response;
# it must not produce another status/final/question or repeat the guidance.
CODEX_PROOF_ROOT="$proof_root" bash "$ROOT/hooks/stop-gate.sh" <"$input" >"$output"
jq -e '
  .continue == true and
  ((.reason // "") | contains("LOOP DETECTED") | not)
' "$output" >/dev/null || {
  cat "$output" >&2
  exit 1
}

printf '%s\n' 'stop loop repeat convergence assertions: PASS'

# Scope-mismatch denials use the active-marker fast path. They must share the
# same bounded loop state as ordinary Stop denials instead of repeating the
# identical marker diagnostic forever.
scope_proof_root="$TMP_ROOT/scope-mismatch-proof"
scope_session=t00-scope-mismatch
scope_input="$TMP_ROOT/scope-mismatch-input.json"
scope_output="$TMP_ROOT/scope-mismatch-output.json"
mkdir -p "$scope_proof_root/$scope_session" "$scope_proof_root/unrelated" "$TMP_ROOT/other-cwd"
printf 'scope: scope mismatch\ncwd: %s\nsession_id: %s\n' \
  "$TMP_ROOT/other-cwd" "$scope_session" >"$scope_proof_root/$scope_session/eci_active"
jq -cn --arg cwd "$repo" --arg session_id "$scope_session" \
  '{session_id:$session_id,cwd:$cwd,transcript_path:"/tmp/nonexistent-scope-mismatch-transcript.jsonl",stop_hook_active:false}' \
  >"$scope_input"
for _ in 1 2 3 4 5; do
  CODEX_PROOF_ROOT="$scope_proof_root" bash "$ROOT/hooks/stop-gate.sh" <"$scope_input" >"$scope_output"
done
jq -e '
  .decision == "block" and
  (.reason | contains("[ECI_MARKER_SCOPE_MISMATCH]")) and
  (.reason | contains("LOOP DETECTED")) and
  (.reason | contains("do not retry or poll Stop")) and
  (.reason | contains("wait for new external state"))
' "$scope_output" >/dev/null || { cat "$scope_output" >&2; exit 1; }
CODEX_PROOF_ROOT="$scope_proof_root" bash "$ROOT/hooks/stop-gate.sh" <"$scope_input" >"$scope_output"
jq -e '.continue == true and ((.reason // "") | contains("LOOP DETECTED") | not)' "$scope_output" >/dev/null || { cat "$scope_output" >&2; exit 1; }

printf '%s\n' 'scope mismatch loop convergence assertions: PASS'
