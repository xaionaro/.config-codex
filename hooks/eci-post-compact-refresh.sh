#!/usr/bin/env bash

# PostCompact hook: refresh ECI instructions without touching session state.

set -euo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HOOK_DIR/lib/codex-proof-state.sh"

input=$(cat)
if ! printf '%s' "$input" | jq -e '
  type == "object" and
  (.session_id? | type) == "string" and
  (.cwd? | type) == "string" and
  (.hook_event_name? | type) == "string" and
  .hook_event_name == "PostCompact" and
  ((has("trigger") | not) or ((.trigger | type) == "string" and (.trigger == "manual" or .trigger == "auto")))
' >/dev/null 2>&1; then
  exit 0
fi

session_id=$(printf '%s' "$input" | jq -r '.session_id' 2>/dev/null || true)
cwd=$(printf '%s' "$input" | jq -r '.cwd' 2>/dev/null || true)
[ -n "$cwd" ] || exit 0

codex_valid_session_id "$session_id" || exit 0
case "$cwd" in
  *[![:print:]]*) exit 0 ;;
esac

root="$(codex_proof_root)"
proof_dir="$root/$session_id"
marker="$proof_dir/eci_active"
nested_marker="$proof_dir/ate_nested_eci_active"

codex_proof_root_is_safe || exit 0
codex_session_dir_is_safe "$root" "$session_id" || exit 0
[ -d "$proof_dir" ] && [ ! -L "$proof_dir" ] || exit 0

nested_marker_is_active() {
  local bytes line_count
  local -a lines=()

  [ -f "$nested_marker" ] && [ ! -L "$nested_marker" ] || return 1
  bytes="$(wc -c <"$nested_marker" 2>/dev/null || true)"
  case "$bytes" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$bytes" -le 1024 ] || return 1
  [ "$(tail -c 1 -- "$nested_marker" 2>/dev/null | od -An -t x1 | tr -d '[:space:]')" = 0a ] || return 1
  line_count="$(awk 'END { print NR + 0 }' "$nested_marker" 2>/dev/null || printf '0')"
  [ "$line_count" -eq 3 ] || return 1
  mapfile -t lines <"$nested_marker" || return 1
  [ "${#lines[@]}" -eq 3 ] || return 1
  [[ "${lines[0]}" == "outer_session_id: $session_id" ]] || return 1
  [[ "${lines[1]}" =~ ^step:[[:space:]]*[0-9]+$ ]] || return 1
  [[ "${lines[2]}" =~ ^iteration:[[:space:]]*[0-9]+$ ]] || return 1
  return 0
}

if ! { [ -f "$marker" ] && [ ! -L "$marker" ]; } && ! nested_marker_is_active; then
  exit 0
fi

jq -n '{
  hookSpecificOutput: {
    hookEventName: "PostCompact",
    additionalContext: "PostCompact ECI refresh signal (authoritative compaction signal): ECI is active. The coordinator/lead must immediately re-read the entire skills/explore-critique-implement/SKILL.md and re-invoke it before the next decision/tool."
  }
}'
