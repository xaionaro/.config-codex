#!/usr/bin/env bash
# Hook scratch + error helpers.
. "${BASH_SOURCE[0]%/*}/eci-diagnostic.sh"

codex_init_tmp() {
  local target="${CODEX_TMPDIR:-$HOME/tmp}"
  if mkdir -p "$target" 2>/dev/null && [ -w "$target" ]; then
    export TMPDIR="$target"
    return 0
  fi
  printf '%s\n' "$(eci_diagnostic_reason "ECI_TMPDIR_UNWRITABLE" "PreToolUse" "tmp-init" "hook=codex,target=$target,tmpdir=${TMPDIR:-/tmp}" "temporary directory is unwritable; TMPDIR left unchanged" "make the configured temporary directory writable or set CODEX_TMPDIR to a writable bounded directory")" >&2
  return 1
}

_codex_fail_open_emit() {
  local hook_name="$1" line="$2" exit_code="$3" cmd="$4"
  printf '%s\n' "$(eci_diagnostic_reason "ECI_HOOK_FAIL_OPEN" "PreToolUse" "hook-fail-open" "hook=$hook_name,line=$line,exit=$exit_code,command=$cmd" "hook command failed; failing open" "inspect the failing command and available temporary-directory/disk state before retrying")" >&2
}

codex_install_fail_open_trap() {
  local name="${1:-${BASH_SOURCE[1]##*/}}"
  # shellcheck disable=SC2064
  trap '_codex_fail_open_emit "'"$name"'" "$LINENO" "$?" "$BASH_COMMAND"; exit 0' ERR
}
