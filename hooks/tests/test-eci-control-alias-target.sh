#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
tmp="$(cd "$tmp" && pwd -P)"
trap 'rm -rf -- "$tmp"' EXIT
export CODEX_PROOF_ROOT="$tmp/proof"
. "$ROOT/hooks/lib/codex-proof-state.sh"

mkdir -p "$CODEX_PROOF_ROOT/current" "$CODEX_PROOF_ROOT/foreign" "$CODEX_PROOF_ROOT/inactive/history"
for sid in current foreign; do
  printf 'scope: alias fixture\ncwd: %s\nsession_id: %s\n' "$ROOT" "$sid" >"$CODEX_PROOF_ROOT/$sid/eci_active"
done
printf ordinary >"$tmp/ordinary"
printf control >"$CODEX_PROOF_ROOT/foreign/goal_state"
ln "$CODEX_PROOF_ROOT/foreign/goal_state" "$tmp/foreign-alias"
ln "$CODEX_PROOF_ROOT/current/eci_active" "$tmp/current-alias"
printf hidden >"$CODEX_PROOF_ROOT/foreign/.eci-permissive-mode.pending"
ln "$CODEX_PROOF_ROOT/foreign/.eci-permissive-mode.pending" "$tmp/hidden-alias"
printf historical >"$CODEX_PROOF_ROOT/inactive/history/goal_state"
ln "$CODEX_PROOF_ROOT/inactive/history/goal_state" "$tmp/historical-alias"
printf shared >"$tmp/shared"
ln "$tmp/shared" "$tmp/shared-alias"

# Record traversal attempts without changing their result. Ordinary edits
# must not enumerate proof storage, and shared targets must not use find.
find() {
  printf '%s\n' find >>"$tmp/find-calls"
  command find "$@"
}
eval "$(declare -f codex_proof_root | sed '1s/codex_proof_root/codex_proof_root_original/')"
codex_proof_root() {
  printf '%s\n' root >>"$tmp/root-calls"
  codex_proof_root_original
}
expect_ordinary() {
  if codex_path_is_eci_control_alias "$1"; then
    printf 'ordinary target incorrectly protected: %s\n' "$1" >&2
    exit 1
  fi
}
expect_ordinary "$tmp/ordinary"
if [ -e "$tmp/find-calls" ] || [ -e "$tmp/root-calls" ]; then
  printf '%s\n' 'FAIL: single-link edit enumerated proof storage' >&2
  exit 1
fi
codex_path_is_eci_control_file "$CODEX_PROOF_ROOT/foreign/goal_state"
codex_path_is_eci_control_alias "$tmp/foreign-alias"
codex_path_is_eci_control_alias "$tmp/current-alias"
codex_path_is_eci_control_alias "$tmp/hidden-alias"
expect_ordinary "$tmp/shared-alias"
expect_ordinary "$tmp/historical-alias"
expect_ordinary "$tmp/missing"
[ ! -e "$tmp/find-calls" ]

# Exercise real Write and apply_patch routing for exact controls and aliases.
for tool in Write apply_patch; do
  for target in "$CODEX_PROOF_ROOT/foreign/goal_state" "$tmp/foreign-alias" "$tmp/current-alias" "$tmp/hidden-alias"; do
    if [ "$tool" = Write ]; then
      tool_input="$(jq -cn --arg path "$target" '{file_path:$path,content:"fixture"}')"
    else
      tool_input="$(jq -cn --arg path "$target" '{patch:("*** Begin Patch\n*** Update File: " + $path + "\n@@\n-fixture\n+changed\n*** End Patch") }')"
    fi
    jq -cn --arg tool "$tool" --arg cwd "$ROOT" --argjson tool_input "$tool_input" \
      '{session_id:"current",tool_name:$tool,cwd:$cwd,tool_input:$tool_input}' |
      bash "$ROOT/hooks/eci-active-gate.sh" >"$tmp/hook-output"
    jq -e '.hookSpecificOutput.permissionDecision == "deny"' "$tmp/hook-output" >/dev/null
  done
done
printf '%s\n' 'PASS: ordinary targets avoid proof traversal; current/foreign active aliases protected'
