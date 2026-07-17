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

codex_select_formal_persistent_storage() {
  local base="${CODEX_TEST_FORMAL_PERSISTENT_BASE:-${XDG_CACHE_HOME:-$HOME/.cache}/codex-hooks-tests}"
  local scratch metadata owner filesystem findmnt_path

  findmnt_path="$(type -P -- findmnt)" || return 1
  case "$findmnt_path" in /*) ;; *) return 1 ;; esac
  [ -f "$findmnt_path" ] && [ -x "$findmnt_path" ] || return 1
  owner="$(id -u)" || return 1
  mkdir -p -- "$base" || return 1
  [ -d "$base" ] && [ -w "$base" ] && [ -x "$base" ] || return 1
  filesystem="$($findmnt_path -n -o FSTYPE --target "$base")" || return 1
  [ "$filesystem" != tmpfs ] || return 1
  scratch="$(mktemp -d "$base/formal-evidence.XXXXXX")" || return 1
  chmod 0700 "$scratch" || { rm -rf -- "$scratch"; return 1; }
  metadata="$(stat -c '%F|%u|%a' -- "$scratch")" || {
    rm -rf -- "$scratch"
    return 1
  }
  if [ "$metadata" != "directory|$owner|700" ]; then
    rm -rf -- "$scratch"
    return 1
  fi
  printf '%s\n' "$scratch"
}

codex_build_formal_artifact() {
  local formal_tmp_root="$1" persistent_root="$2" repository="$3"
  local watchdog="$4" log_name="$5"
  shift 5
  local build_tmp log status

  codex_private_formal_tmpfs_scratch "$formal_tmp_root" || return 1
  build_tmp="$(mktemp -d "$formal_tmp_root/build.XXXXXX")" || return 1
  mkdir -p "$persistent_root/logs" || { rm -rf -- "$build_tmp"; return 1; }
  log="$persistent_root/logs/$log_name"
  status=0
  python3 "$watchdog" --timeout 900 --log "$log" --cwd "$repository" -- \
    env TMPDIR="$build_tmp" "$@" || status=$?
  rm -rf -- "$build_tmp" 2>/dev/null || true
  return "$status"
}
