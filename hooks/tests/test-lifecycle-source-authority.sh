#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TMP_ROOT="$(mktemp -d "${CODEX_TMPDIR:-${HOME:?}/tmp}/eci-lifecycle-source-authority.XXXXXX")"
trap 'rm -rf -- "$TMP_ROOT"' EXIT HUP INT TERM

failures=0

fail() {
  printf 'FAIL %s\n' "$*" >&2
  failures=$((failures + 1))
}

fixture_home="$TMP_ROOT/home"
fixture_codex="$fixture_home/.codex"
fixture_kimi_home="$TMP_ROOT/kimi-home"
fixture_kimi="$fixture_kimi_home/.kimi-code"
foreign_root="$TMP_ROOT/foreign"
poisoned_codex="$TMP_ROOT/poisoned-codex"
proof_root="$TMP_ROOT/proof"
cwd="$TMP_ROOT/cwd"
stop_input="$TMP_ROOT/stop-input.json"
stop_output="$TMP_ROOT/stop-output.json"
ledger_input="$TMP_ROOT/ledger-input.json"

mkdir -p -- "$fixture_home" "$fixture_codex" "$fixture_kimi_home" "$fixture_kimi" "$foreign_root/hooks/lib" \
  "$poisoned_codex" "$proof_root" "$cwd"
proof_root="$(realpath -e -- "$proof_root")"
cp -a -- "$ROOT/hooks" "$fixture_codex/hooks"
cp -a -- "$ROOT/hooks" "$fixture_kimi/hooks"
cp -- "$ROOT/hooks/lib/codex-proof-state.sh" "$foreign_root/hooks/lib/codex-proof-state.sh"

printf '%s\n' \
  '{"session_id":"source-authority-stop","cwd":"'"$cwd"'","transcript_path":"","stop_hook_active":false}' \
  >"$stop_input"

run_stop() {
  local selected_home="$1" output="$2"

  env -u CODEX_STOP_GATE_ROOT \
    HOME="$selected_home" CODEX_HOME="$poisoned_codex" CODEX_PROOF_ROOT="$proof_root" \
    bash "$fixture_codex/hooks/stop-gate.sh" <"$stop_input" >"$output"
}

# A symlinked HOME parent is an identity alias, not a replacement of the
# selected final authority component. It must continue to work.
parent_alias="$TMP_ROOT/home-parent-alias"
ln -s -- "$fixture_home" "$parent_alias"
run_stop "$parent_alias" "$stop_output"
if ! jq -e '. == {"continue":true}' "$stop_output" >/dev/null; then
  fail "Stop hook rejected a parent HOME alias: $(cat -- "$stop_output")"
fi

# A final `$HOME/.codex` symlink that resolves to the already loaded hook
# directory is an identity alias. It must keep the normal continuation path.
final_symlink_home="$TMP_ROOT/final-symlink-home"
final_symlink_output="$TMP_ROOT/final-symlink-output.json"
mkdir -p -- "$final_symlink_home"
ln -s -- "$fixture_codex" "$final_symlink_home/.codex"
run_stop "$final_symlink_home" "$final_symlink_output"
if ! jq -e '. == {"continue":true}' "$final_symlink_output" >/dev/null; then
  fail "Stop hook rejected a final HOME/.codex identity alias: $(cat -- "$final_symlink_output")"
fi

make_claim() {
  local session_id="$1" claim
  claim="$proof_root/$session_id/.eci-accidental-mistake-override.claim"
  mkdir -p -- "$claim"
  printf '%s\n' "$claim"
}

codex_claim="$(make_claim codex-recovery)"
kimi_claim="$(make_claim kimi-recovery)"
expected_codex_command='"$HOME/.codex/bin/eci-active"'
expected_kimi_command='"${KIMI_CODE_HOME:-$HOME/.kimi-code}/bin/eci-active"'

codex_cleanup_command="$(
  HOME="$fixture_home" CODEX_HOME="$poisoned_codex" KIMI_CODE_HOME="$fixture_kimi" \
    CODEX_PROOF_ROOT="$proof_root" \
    bash -c '. "$1"; codex_eci_accidental_override_cleanup_command "$2"' _ \
      "$fixture_codex/hooks/lib/codex-proof-state.sh" "$codex_claim"
)" || fail 'Codex recovery helper did not produce a canonical lifecycle command'
if [ "$codex_cleanup_command" != "$expected_codex_command accidental-override-cleanup --authorized-by-user $codex_claim" ]; then
  fail "Codex recovery command did not use literal HOME authority: $codex_cleanup_command"
fi

kimi_cleanup_command="$(
  HOME="$fixture_kimi_home" CODEX_HOME="$poisoned_codex" KIMI_CODE_HOME="$fixture_kimi" \
    CODEX_PROOF_ROOT="$proof_root" \
    bash -c '. "$1"; codex_eci_accidental_override_cleanup_command "$2"' _ \
      "$fixture_kimi/hooks/lib/codex-proof-state.sh" "$kimi_claim"
)" || fail 'Kimi recovery helper did not produce a provider-specific lifecycle command'
if [ "$kimi_cleanup_command" != "$expected_kimi_command accidental-override-cleanup --authorized-by-user $kimi_claim" ]; then
  fail "Kimi recovery command did not use KIMI_CODE_HOME authority: $kimi_cleanup_command"
fi

if kimi_mismatched_cleanup_command="$(
  HOME="$fixture_kimi_home" CODEX_HOME="$poisoned_codex" KIMI_CODE_HOME="$fixture_codex" \
    CODEX_PROOF_ROOT="$proof_root" \
    bash -c '. "$1"; codex_eci_accidental_override_cleanup_command "$2"' _ \
      "$fixture_kimi/hooks/lib/codex-proof-state.sh" "$kimi_claim"
)"; then
  fail "Kimi proof helper emitted a lifecycle command when KIMI_CODE_HOME selected another root: $kimi_mismatched_cleanup_command"
fi

if foreign_cleanup_command="$(
  HOME="$fixture_home" CODEX_HOME="$poisoned_codex" KIMI_CODE_HOME="$fixture_kimi" \
    CODEX_PROOF_ROOT="$proof_root" \
    bash -c '. "$1"; codex_eci_accidental_override_cleanup_command "$2"' _ \
      "$foreign_root/hooks/lib/codex-proof-state.sh" "$codex_claim"
)"; then
  fail "foreign proof helper emitted a lifecycle command: $foreign_cleanup_command"
fi

ledger_path="$proof_root/kimi-ledger/high_level_log.md"
mkdir -p -- "${ledger_path%/*}"
printf '%s\n' coordinator-ledger >"$ledger_path"
jq -cn --arg cwd "$cwd" --arg path "$ledger_path" \
  '{session_id:"kimi-ledger",cwd:$cwd,tool_name:"Write",tool_input:{file_path:$path,content:"forged"}}' \
  >"$ledger_input"
ledger_output="$TMP_ROOT/kimi-ledger-output.json"
HOME="$fixture_kimi_home" CODEX_HOME="$poisoned_codex" KIMI_CODE_HOME="$fixture_kimi" \
  CODEX_PROOF_ROOT="$proof_root" \
  bash "$fixture_kimi/hooks/eci-active-gate.sh" <"$ledger_input" >"$ledger_output"
if [ -s "$ledger_output" ]; then
  fail "Kimi current-session ledger edit was blocked: $(cat -- "$ledger_output")"
fi

if [ "$failures" -ne 0 ]; then
  exit 1
fi

printf '%s\n' 'lifecycle source authority assertions: PASS'
