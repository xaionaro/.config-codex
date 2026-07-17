# Shellcheck-friendly lifecycle differential scratch selection.
# shellcheck shell=bash

codex_private_formal_tmpfs_scratch() {
  local scratch="$1"
  local findmnt_path metadata owner filesystem

  findmnt_path="$(type -P -- findmnt)" || return 1
  case "$findmnt_path" in /*) ;; *) return 1 ;; esac
  [ -f "$findmnt_path" ] && [ -x "$findmnt_path" ] || return 1
  owner="$(id -u)" || return 1
  metadata="$(stat -c '%F|%u|%a' -- "$scratch")" || return 1
  filesystem="$($findmnt_path -n -o FSTYPE --target "$scratch")" || return 1
  [ "$metadata" = "directory|$owner|700" ] && [ "$filesystem" = tmpfs ]
}

codex_select_formal_tmpfs_scratch() {
  local base="${CODEX_TEST_FORMAL_TMPFS_BASE:-/tmp}"
  local findmnt_path scratch filesystem

  findmnt_path="$(type -P -- findmnt)" || return 1
  case "$findmnt_path" in /*) ;; *) return 1 ;; esac
  [ -f "$findmnt_path" ] && [ -x "$findmnt_path" ] || return 1
  [ -d "$base" ] && [ -w "$base" ] && [ -x "$base" ] || return 1
  filesystem="$($findmnt_path -n -o FSTYPE --target "$base")" || return 1
  [ "$filesystem" = tmpfs ] || return 1

  scratch="$(mktemp -d "$base/codex-hooks-formal.XXXXXX")" || return 1
  if ! chmod 0700 "$scratch"; then
    rm -rf -- "$scratch"
    return 1
  fi
  if ! codex_private_formal_tmpfs_scratch "$scratch"; then
    rm -rf -- "$scratch"
    return 1
  fi
  printf '%s\n' "$scratch"
}

codex_run_formal_lifecycle_differential() {
  local formal_tmp_root="$1"
  shift

  codex_private_formal_tmpfs_scratch "$formal_tmp_root" || return 1
  [ -w "$formal_tmp_root" ] || return 1
  TMPDIR="$formal_tmp_root" "$@"
}
