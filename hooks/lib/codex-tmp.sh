#!/usr/bin/env bash
# Hook scratch + error helpers.

codex_init_tmp() {
  local target="${CODEX_TMPDIR:-$HOME/tmp}"
  if mkdir -p "$target" 2>/dev/null && [ -w "$target" ]; then
    export TMPDIR="$target"
    return 0
  fi
  printf 'codex_init_tmp: %s unwritable; TMPDIR left as %s\n' \
    "$target" "${TMPDIR:-/tmp}" >&2
  return 1
}

_codex_fail_open_emit() {
  local hook_name="$1" line="$2" exit_code="$3" cmd="$4"
  printf '%s: aborted line=%d exit=%d cmd=%q; failing open; check disk space (df -h /tmp $HOME/tmp)\n' \
    "$hook_name" "$line" "$exit_code" "$cmd" >&2
}

codex_install_fail_open_trap() {
  local name="${1:-${BASH_SOURCE[1]##*/}}"
  # shellcheck disable=SC2064
  trap '_codex_fail_open_emit "'"$name"'" "$LINENO" "$?" "$BASH_COMMAND"; exit 0' ERR
}
