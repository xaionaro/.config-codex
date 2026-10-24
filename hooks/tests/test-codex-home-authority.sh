#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d "${CODEX_TMPDIR:-${HOME:?}/tmp}/codex-home-authority.XXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT

home="$tmp/home"
canonical_codex="$home/.codex"
foreign_codex="$tmp/foreign-codex"
proof_root="$tmp/proof"
session_id=t00-copied-subagent
cwd="$tmp/cwd"
transcript="$canonical_codex/sessions/copied-subagent.jsonl"
input="$tmp/input.json"
output="$tmp/output.json"

mkdir -p "$canonical_codex" "$foreign_codex/sessions" \
  "$proof_root/$session_id" "$cwd" "$canonical_codex/sessions"
cp -a -- "$ROOT/hooks" "$canonical_codex/hooks"

global_home="$tmp/global-home"
global_codex="$global_home/.codex"
global_foreign_codex="$tmp/global-foreign-codex"
mkdir -p "$global_codex" "$global_foreign_codex"
global_paths="$(
  HOME="$global_home" CODEX_HOME="$global_foreign_codex" \
    bash -c '. "$1"; codex_eci_accidental_override_global_root; codex_eci_accidental_override_record_path global' \
      bash "$ROOT/hooks/lib/codex-proof-state.sh"
)"
expected_global_root="$(realpath -e -- "$global_codex")"
expected_global_paths="$expected_global_root"$'\n'"$expected_global_root/.eci-accidental-mistake-override"
[ "$global_paths" = "$expected_global_paths" ] || {
  printf 'global authority paths followed poisoned CODEX_HOME: %s\n' "$global_paths" >&2
  exit 1
}

# Every active validate-bash route runs from this source.  CODEX_HOME may be
# printed for diagnostics, but it must never be read as a path selector: a
# poisoned value would otherwise make a foreign root worker-owned.  Keep this
# source regression independent of the currently pinned planner artifact.
mapfile -t codex_home_references < <(
  rg -n --fixed-strings 'CODEX_HOME' "$ROOT/hooks/validate-bash.sh" |
    awk -F: '$2 !~ /^[[:space:]]*#/' || true
)
if [ "${#codex_home_references[@]}" -ne 1 ] ||
  [[ "${codex_home_references[0]:-}" != *'"HOME", "PWD", "PATH", "CODEX_HOME", "KIMI_CODE_HOME",'* ]]; then
  printf '%s\n' 'validate-bash retains a non-diagnostic CODEX_HOME reference' >&2
  printf '%s\n' "${codex_home_references[@]}" >&2
  exit 1
fi
grep -Fq 'configured_codex="${HOME:?HOME must be set}/.codex"' "$ROOT/hooks/validate-bash.sh" &&
  grep -Fq 'CODEX_CONFIGURED_HOME="${HOME:?HOME must be set}/.codex"' "$ROOT/hooks/validate-bash.sh" || {
  printf '%s\n' 'validate-bash no longer exports the lexical HOME/.codex authority' >&2
  exit 1
}

# A missing HOME must fail closed before a Codex authority path is formed;
# it must not silently fall back to /.codex or a cwd-relative .codex.  It is
# still a PreToolUse callback, so the failure must be one valid provider
# denial rather than a nonzero process with no JSON for Codex to parse.
no_home_input="$tmp/no-home-input.json"
no_home_output="$tmp/no-home-output.json"
no_home_error="$tmp/no-home-error.log"
jq -n --arg cwd "$cwd" --arg session_id "$session_id" \
  '{session_id:$session_id,cwd:$cwd,tool_input:{command:"true"}}' >"$no_home_input"

assert_home_authority_deny() {
  local label="$1" expected_code="$2" expected_reason="$3"

  jq -s -e '
    (length == 1) and
    (.[0] |
      type == "object" and
      (keys | sort) == ["hookSpecificOutput"] and
      (.hookSpecificOutput |
        type == "object" and
        (keys | sort) == ["hookEventName", "permissionDecision", "permissionDecisionReason"] and
        .hookEventName == "PreToolUse" and
        .permissionDecision == "deny" and
        (.permissionDecisionReason | type == "string") and
        contains($expected_code) and
        contains($expected_reason)
      )
    )
  ' --arg expected_code "$expected_code" --arg expected_reason "$expected_reason" \
    "$no_home_output" >/dev/null || {
    printf 'validate-bash %s-HOME authority failure was not one valid PreToolUse denial:\n' "$label" >&2
    cat -- "$no_home_output" >&2
    return 1
  }
  [ ! -s "$no_home_error" ] || {
    printf 'validate-bash %s-HOME authority failure wrote unexpected stderr:\n' "$label" >&2
    cat -- "$no_home_error" >&2
    return 1
  }
}

if ! env -u HOME CODEX_PROOF_ROOT="$proof_root" \
  bash "$ROOT/hooks/validate-bash.sh" <"$no_home_input" \
  >"$no_home_output" 2>"$no_home_error"; then
  printf '%s\n' 'validate-bash missing-HOME authority did not return a hook decision' >&2
  exit 1
fi
assert_home_authority_deny missing '[ECI_HOME_AUTHORITY_UNAVAILABLE]' 'HOME is unset or empty'

if ! HOME='' CODEX_PROOF_ROOT="$proof_root" \
  bash "$ROOT/hooks/validate-bash.sh" <"$no_home_input" \
  >"$no_home_output" 2>"$no_home_error"; then
  printf '%s\n' 'validate-bash empty-HOME authority did not return a hook decision' >&2
  exit 1
fi
assert_home_authority_deny empty '[ECI_HOME_AUTHORITY_UNAVAILABLE]' 'HOME is unset or empty'

if ! HOME=/ CODEX_PROOF_ROOT="$proof_root" \
  bash "$ROOT/hooks/validate-bash.sh" <"$no_home_input" \
  >"$no_home_output" 2>"$no_home_error"; then
  printf '%s\n' 'validate-bash root-HOME authority did not return a hook decision' >&2
  exit 1
fi
assert_home_authority_deny root '[ECI_HOME_AUTHORITY_INVALID]' 'non-root normalized absolute path'

printf '%s\n' 'Codex HOME authority regression: PASS'
