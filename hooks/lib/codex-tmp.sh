#!/usr/bin/env bash
# Hook scratch + error helpers.
. "${BASH_SOURCE[0]%/*}/eci-diagnostic.sh"

codex_init_tmp() {
  local home="${HOME:-}" requested target canonical inherited inherited_canonical status=0 unsafe_reported=false
  if [ -z "$home" ]; then
    printf '%s\n' "$(eci_diagnostic_reason "ECI_TMPDIR_HOME_MISSING" "PreToolUse" "tmp-init" "hook=codex" "HOME is unset; a home-scoped temporary directory cannot be selected" "set HOME to the Codex user's home directory and retry")" >&2
    return 1
  fi

  requested="${CODEX_TMPDIR:-$home/tmp}"
  target="$requested"
  canonical="$(realpath -m -- "$target" 2>/dev/null || true)"
  if [ -z "$canonical" ]; then
    canonical="$target"
  fi
  if [ "$canonical" = /tmp ] || [[ "$canonical" == /tmp/* ]]; then
    printf '%s\n' "$(eci_diagnostic_reason "ECI_TMPDIR_SYSTEM_ROOT" "PreToolUse" "tmp-init" "hook=codex,requested=$requested,canonical=$canonical" "system temporary root /tmp is not a Codex scratch location" "unset CODEX_TMPDIR or set it to a writable home-scoped directory such as \$HOME/tmp")" >&2
    target="$home/tmp"
    status=1
    unsafe_reported=true
  fi
  inherited="${TMPDIR:-}"
  if [ "$unsafe_reported" = false ] && [ -n "$inherited" ]; then
    inherited_canonical="$(realpath -m -- "$inherited" 2>/dev/null || true)"
    if [ "$inherited_canonical" = /tmp ] || [[ "$inherited_canonical" == /tmp/* ]]; then
      printf '%s\n' "$(eci_diagnostic_reason "ECI_TMPDIR_SYSTEM_ROOT" "PreToolUse" "tmp-init" "hook=codex,source=TMPDIR,requested=$inherited,canonical=$inherited_canonical" "system temporary root /tmp inherited in TMPDIR is not a Codex scratch location" "set TMPDIR to a home-scoped directory such as \$HOME/tmp before invoking Codex")" >&2
      status=1
    fi
  fi

  export TMPDIR="$target"
  if ! mkdir -p "$target" 2>/dev/null || [ ! -w "$target" ]; then
    printf '%s\n' "$(eci_diagnostic_reason "ECI_TMPDIR_UNWRITABLE" "PreToolUse" "tmp-init" "hook=codex,target=$target,requested=$requested,tmpdir=$TMPDIR" "home-scoped temporary directory is unwritable" "make the configured temporary directory writable or set CODEX_TMPDIR to a writable directory under the Codex home")" >&2
    return 1
  fi
  return "$status"
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
