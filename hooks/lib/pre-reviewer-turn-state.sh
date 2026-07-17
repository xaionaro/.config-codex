# Shared per-turn state primitives for UserPromptSubmit and PreToolUse hooks.
# shellcheck shell=bash

codex_hook_turn_id_json() {
  local input="${1:-}"

  # Input is a valid UTF-8 JSON object. A malformed raw-byte alias is outside
  # this shell helper's contract; valid U+FFFD remains an ordinary character.
  printf '%s' "$input" | jq -c \
    'if type != "object" then empty else (.turn_id? // null) as $turn_id
    | if (($turn_id | type) == "string"
        and ($turn_id | utf8bytelength) > 0
        and ($turn_id | utf8bytelength) <= 4096)
      then $turn_id
      else empty
      end end' \
    2>/dev/null || true
}

codex_turn_state_key() {
  local turn_id_json="$1"
  local key

  key="$(codex_hash_string "$turn_id_json" 2>/dev/null || true)"
  case "$key" in
    ""|*[!A-Za-z0-9_-]*) return 1 ;;
  esac
  printf '%s\n' "$key"
}

codex_turn_capture_path() {
  printf '%s/capture-turn-%s.json\n' "$1" "$2"
}

codex_turn_claim_path() {
  printf '%s/claim-turn-%s\n' "$1" "$2"
}

codex_ensure_private_pre_reviewer_state_dir() {
  local state_dir="$1"
  local metadata owner helper_dir

  if [ ! -e "$state_dir" ] && [ ! -L "$state_dir" ]; then
    (umask 077; mkdir -p -m 0700 -- "$state_dir") || return 1
  fi
  metadata="$(stat -c '%F|%u|%a' -- "$state_dir" 2>/dev/null)" || return 1
  owner="$(id -u)" || return 1
  if [ "$metadata" = "directory|$owner|700" ]; then
    return 0
  fi

  [ -e "$state_dir" ] || return 1
  helper_dir="${BASH_SOURCE[0]%/*}"
  [ "$helper_dir" != "${BASH_SOURCE[0]}" ] || helper_dir=.
  python3 "$helper_dir/migrate_pre_reviewer_state_dir.py" "$state_dir" \
    >/dev/null 2>&1 || return 1

  owner="$(id -u)" || return 1
  metadata="$(stat -c '%F|%u|%a' -- "$state_dir" 2>/dev/null)" || return 1
  [ "$metadata" = "directory|$owner|700" ]
}

codex_private_regular_file() {
  local path="$1"
  local metadata owner file_type file_owner file_mode link_count

  [ ! -L "$path" ] || return 1
  metadata="$(stat -c '%F|%u|%a|%h' -- "$path" 2>/dev/null)" || return 1
  owner="$(id -u)" || return 1
  IFS='|' read -r file_type file_owner file_mode link_count <<<"$metadata"
  case "$file_type" in
    "regular file"|"regular empty file") ;;
    *) return 1 ;;
  esac
  [ "$file_owner" = "$owner" ] && [ "$file_mode" = 600 ] && [ "$link_count" = 1 ]
}

codex_lock_pre_reviewer_turn() {
  local state_dir="$1"
  local timeout="${CODEX_PRE_REVIEWER_LOCK_TIMEOUT:-1}"
  local path_metadata descriptor_metadata owner expected_metadata

  [[ "$timeout" =~ ^(0+([.][0123456789]+)?|0*1([.]0+)?)$ ]] || timeout=1
  codex_ensure_private_pre_reviewer_state_dir "$state_dir" || return 1
  owner="$(id -u)" || return 1
  path_metadata="$(stat -c '%d:%i|%F|%u|%a' -- "$state_dir" 2>/dev/null)" || return 1
  expected_metadata="${path_metadata%%|*}|directory|$owner|700"
  [ "$path_metadata" = "$expected_metadata" ] || return 1
  exec {CODEX_TURN_LOCK_FD}<"$state_dir" || return 1
  descriptor_metadata="$(stat -Lc '%d:%i|%F|%u|%a' \
    -- "/proc/self/fd/$CODEX_TURN_LOCK_FD" 2>/dev/null)" || {
    exec {CODEX_TURN_LOCK_FD}>&-
    CODEX_TURN_LOCK_FD=""
    return 1
  }
  if [ "$descriptor_metadata" != "$path_metadata" ]; then
    exec {CODEX_TURN_LOCK_FD}>&-
    CODEX_TURN_LOCK_FD=""
    return 1
  fi
  if ! flock -x -w "$timeout" "$CODEX_TURN_LOCK_FD"; then
    exec {CODEX_TURN_LOCK_FD}>&-
    CODEX_TURN_LOCK_FD=""
    return 1
  fi

  path_metadata="$(stat -c '%d:%i|%F|%u|%a' -- "$state_dir" 2>/dev/null)" || {
    flock -u "$CODEX_TURN_LOCK_FD" 2>/dev/null || true
    exec {CODEX_TURN_LOCK_FD}>&-
    CODEX_TURN_LOCK_FD=""
    return 1
  }
  descriptor_metadata="$(stat -Lc '%d:%i|%F|%u|%a' \
    -- "/proc/self/fd/$CODEX_TURN_LOCK_FD" 2>/dev/null)" || {
    flock -u "$CODEX_TURN_LOCK_FD" 2>/dev/null || true
    exec {CODEX_TURN_LOCK_FD}>&-
    CODEX_TURN_LOCK_FD=""
    return 1
  }
  owner="$(id -u)" || {
    flock -u "$CODEX_TURN_LOCK_FD" 2>/dev/null || true
    exec {CODEX_TURN_LOCK_FD}>&-
    CODEX_TURN_LOCK_FD=""
    return 1
  }
  expected_metadata="${descriptor_metadata%%|*}|directory|$owner|700"
  if [ "$path_metadata" != "$descriptor_metadata" ] ||
      [ "$descriptor_metadata" != "$expected_metadata" ]; then
    flock -u "$CODEX_TURN_LOCK_FD" 2>/dev/null || true
    exec {CODEX_TURN_LOCK_FD}>&-
    CODEX_TURN_LOCK_FD=""
    return 1
  fi
}

codex_unlock_pre_reviewer_turn() {
  if [ -n "${CODEX_TURN_LOCK_FD:-}" ]; then
    flock -u "$CODEX_TURN_LOCK_FD" 2>/dev/null || true
    exec {CODEX_TURN_LOCK_FD}>&-
    CODEX_TURN_LOCK_FD=""
  fi
}

codex_prune_pre_reviewer_turn_state() {
  local state_dir="$1"
  local helper_dir now path_metadata descriptor_metadata owner expected_metadata

  # Maintenance is deliberately outside the shared turn lock. The Python
  # pruner uses its own nonblocking lock for one bounded cursor-backed batch.
  [ -z "${CODEX_TURN_LOCK_FD:-}" ] || return 1
  codex_ensure_private_pre_reviewer_state_dir "$state_dir" || return 1
  owner="$(id -u)" || return 1
  path_metadata="$(stat -c '%d:%i|%F|%u|%a' -- "$state_dir" 2>/dev/null)" || return 1
  expected_metadata="${path_metadata%%|*}|directory|$owner|700"
  [ "$path_metadata" = "$expected_metadata" ] || return 1
  exec {CODEX_PRUNE_STATE_FD}<"$state_dir" || return 1
  descriptor_metadata="$(stat -Lc '%d:%i|%F|%u|%a' \
    -- "/proc/self/fd/$CODEX_PRUNE_STATE_FD" 2>/dev/null)" || {
    exec {CODEX_PRUNE_STATE_FD}>&-
    CODEX_PRUNE_STATE_FD=""
    return 1
  }
  path_metadata="$(stat -c '%d:%i|%F|%u|%a' -- "$state_dir" 2>/dev/null)" || {
    exec {CODEX_PRUNE_STATE_FD}>&-
    CODEX_PRUNE_STATE_FD=""
    return 1
  }
  if [ "$descriptor_metadata" != "$path_metadata" ] ||
      [ "$descriptor_metadata" != "$expected_metadata" ]; then
    exec {CODEX_PRUNE_STATE_FD}>&-
    CODEX_PRUNE_STATE_FD=""
    return 1
  fi
  now="$(date +%s)" || {
    exec {CODEX_PRUNE_STATE_FD}>&-
    CODEX_PRUNE_STATE_FD=""
    return 1
  }
  helper_dir="${BASH_SOURCE[0]%/*}"
  [ "$helper_dir" != "${BASH_SOURCE[0]}" ] || helper_dir=.
  python3 "$helper_dir/prune_pre_reviewer_turn_state.py" \
    "$CODEX_PRUNE_STATE_FD" "$now" >/dev/null 2>&1 || true
  exec {CODEX_PRUNE_STATE_FD}>&-
  CODEX_PRUNE_STATE_FD=""
}
