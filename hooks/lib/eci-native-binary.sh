# Host compatibility for the managed Linux ELF runtime artifacts.
# shellcheck shell=bash

eci_runtime_binary_is_native() {
  local path="$1" candidate_header host_header index
  local -a candidate=() host=()
  [ -f "$path" ] && [ ! -L "$path" ] && [ -x "$path" ] || return 1
  candidate_header="$(od -An -v -tx1 -w20 -N20 -- "$path" 2>/dev/null)" || return 1
  host_header="$(od -An -v -tx1 -w20 -N20 -- "/proc/$$/exe" 2>/dev/null)" || return 1
  read -r -a candidate <<<"$candidate_header"
  read -r -a host <<<"$host_header"
  [ "${#candidate[@]}" -eq 20 ] && [ "${#host[@]}" -eq 20 ] || return 1
  [ "${candidate[*]:0:4}" = '7f 45 4c 46' ] || return 1
  # ELF class, byte order and machine identify the host execution format.
  # Ignore the executable/shared-object distinction and padding bytes.
  for index in 4 5 18 19; do
    [ "${candidate[$index]}" = "${host[$index]}" ] || return 1
  done
  case "${candidate[7]}" in 00|03) ;; *) return 1 ;; esac
}
