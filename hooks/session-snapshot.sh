#!/usr/bin/env bash
# SessionStart hook: save git HEAD as the stop-hook baseline.

set -euo pipefail

input=$(cat)
session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)

case "$session_id" in
  ""|*[!A-Za-z0-9_-]*) exit 0 ;;
esac

root="${CODEX_PROOF_ROOT:-$HOME/.cache/codex-proof}"
proof_dir="$root/$session_id"
baseline="$proof_dir/baseline_head"

mkdir -p "$proof_dir"

if [ ! -f "$baseline" ]; then
  git rev-parse HEAD >"$baseline" 2>/dev/null || true
fi

rm -f "$proof_dir/skip_stop"

find "$root" -mindepth 1 -maxdepth 1 -type d -mtime +30 -exec rm -rf {} + 2>/dev/null || true
find "$root/history" -mindepth 1 -maxdepth 1 -type f -mtime +30 -delete 2>/dev/null || true

jq -n --arg ctx 'Load ~/.codex/CODEX.md and matching ~/.codex/skills when applicable.' '{
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: $ctx
  }
}'
