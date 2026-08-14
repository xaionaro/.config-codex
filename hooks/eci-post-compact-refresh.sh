#!/usr/bin/env bash

# PostCompact hook: refresh ECI instructions without touching session state.

set -euo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HOOK_DIR/lib/codex-proof-state.sh"

input=$(cat)
session_id=$(printf '%s' "$input" | jq -r \
  'if (.session_id? | type) == "string" then .session_id else "" end' \
  2>/dev/null || true)
cwd=$(printf '%s' "$input" | jq -r \
  'if (.cwd? | type) == "string" then .cwd else "" end' \
  2>/dev/null || true)
[ -n "$cwd" ] || exit 0

codex_valid_session_id "$session_id" || exit 0
case "$cwd" in
  *[![:print:]]*) exit 0 ;;
esac

root="$(codex_proof_root)"
proof_dir="$root/$session_id"
marker="$proof_dir/eci_active"

[ -d "$root" ] && [ ! -L "$root" ] || exit 0
[ -d "$proof_dir" ] && [ ! -L "$proof_dir" ] || exit 0
[ -f "$marker" ] && [ ! -L "$marker" ] || exit 0

jq -n '{
  hookSpecificOutput: {
    hookEventName: "PostCompact",
    additionalContext: "PostCompact ECI refresh signal (authoritative compaction signal): ECI is active. The coordinator/lead must immediately re-read the entire skills/explore-critique-implement/SKILL.md and re-invoke it before the next decision/tool."
  }
}'
