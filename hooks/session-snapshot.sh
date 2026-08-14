#!/usr/bin/env bash
# SessionStart hook: save git HEAD as the stop-hook baseline.

set -euo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HOOK_DIR/lib/codex-proof-state.sh"
. "$HOOK_DIR/lib/codex-tmp.sh"
codex_install_fail_open_trap session-snapshot

input=$(cat)
if ! printf '%s' "$input" | jq -e '
  type == "object" and
  (.session_id? | type) == "string" and
  ((has("transcript_path") | not) or (.transcript_path | type) == "string") and
  ((has("cwd") | not) or (.cwd | type) == "string")
' >/dev/null 2>&1; then
  exit 0
fi
session_id=$(printf '%s' "$input" | jq -r '.session_id' 2>/dev/null || true)
transcript_path=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null || true)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)
[ -z "$cwd" ] && cwd="$PWD"

[ -n "$transcript_path" ] || exit 0

codex_valid_session_id "$session_id" || exit 0
root="$(codex_proof_root)"
codex_proof_root_is_safe || exit 0

if [ ! -d "$root" ]; then
  mkdir -p "$root" || exit 0
  codex_proof_root_is_safe || exit 0
fi

lock_held=false
lock_path="$(codex_eci_lock_path 2>/dev/null || true)"
if [ -n "$lock_path" ] &&
  { [ ! -e "$lock_path" ] || [ -f "$lock_path" ]; } && [ ! -L "$lock_path" ]; then
  if exec {eci_lock_fd}>>"$lock_path" 2>/dev/null && flock -n "$eci_lock_fd" 2>/dev/null; then
    lock_held=true
    trap 'flock -u "$eci_lock_fd" 2>/dev/null || true; eval "exec ${eci_lock_fd}>&-"' EXIT
  else
    if [ -n "${eci_lock_fd:-}" ]; then
      eval "exec ${eci_lock_fd}>&-" 2>/dev/null || true
    fi
  fi
fi

# Do not create scratch state until the input, proof root, session path, and
# mutation lock have all been validated. Lock-busy and unsafe-input branches
# remain read-only.
if [ "$lock_held" = true ]; then
  codex_init_tmp || true
fi

side_stop=$(codex_existing_state_file side-stop side_stop "$session_id" "$cwd" 2>/dev/null || true)
if codex_side_stop_is_active_for_session "$side_stop" "$session_id"; then
  if [ "$lock_held" = true ]; then
    codex_bind_side_stop_to_session "$side_stop" "$session_id" || true
  fi
  exit 0
fi

proof_dir="$root/$session_id"
baseline="$proof_dir/baseline_head"
nested_marker="$proof_dir/ate_nested_eci_active"

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
}

codex_session_dir_is_safe "$root" "$session_id" || exit 0

if [ "$lock_held" != true ]; then
  ctx='Load ~/.codex/CODEX.md and matching ~/.codex/skills when applicable.'
  eci_marker="$proof_dir/eci_active"
  if [ -d "$proof_dir" ] && [ ! -L "$proof_dir" ] &&
      { { [ -f "$eci_marker" ] && [ ! -L "$eci_marker" ]; } || nested_marker_is_active; }; then
    ctx='ECI is active. ECI refresh signal (not proof of compaction): after compaction, the coordinator/lead must immediately re-read the entire skills/explore-critique-implement/SKILL.md and re-invoke it before the next decision/tool.'
  fi
  jq -n --arg ctx "$ctx" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$ctx}}'
  exit 0
fi

mkdir -p "$proof_dir"
codex_session_dir_is_safe "$root" "$session_id" || exit 0

if [ ! -f "$baseline" ]; then
  git rev-parse HEAD >"$baseline" 2>/dev/null || true
fi

rm -f "$proof_dir/skip_stop"

prune_marker_dirs() {
  local state_root="$1"
  local marker_name="$2"
  local dir marker

  [ -d "$state_root" ] || return 0
  find "$state_root" -mindepth 1 -maxdepth 1 -type d -mtime +30 -print 2>/dev/null |
    while IFS= read -r dir; do
      marker="$dir/$marker_name"
      if [ -f "$marker" ] && [ ! -L "$marker" ]; then
        case "$marker_name" in
          eci_active) continue ;;
          skip_stop)
            [ -n "$(find "$marker" -mmin -60 -print 2>/dev/null)" ] && continue
            ;;
        esac
      fi
      rm -rf "$dir"
    done
}

while IFS= read -r -d '' dir; do
  marker="$dir/eci_active"
  if [ -d "$dir" ] && [ ! -L "$dir" ] &&
      [ -f "$marker" ] && [ ! -L "$marker" ]; then
    continue
  fi
  rm -rf -- "$dir"
done < <(find "$root" -mindepth 1 -maxdepth 1 -type d -name '019*' -mtime +30 -print0 2>/dev/null)
find "$root/history" -mindepth 1 -maxdepth 1 -type f -mtime +30 -delete 2>/dev/null || true
for state_root in skills audit reviewer reviewer-dumps; do
  find "$root/$state_root" -mindepth 1 -maxdepth 1 -mtime +30 -exec rm -rf {} + 2>/dev/null || true
done
find "$root/touched-repos/sessions" -mindepth 1 -maxdepth 1 -type d -mtime +30 -exec rm -rf {} + 2>/dev/null || true
prune_marker_dirs "$root/eci/sessions" eci_active
prune_marker_dirs "$root/eci/cwd" eci_active
prune_marker_dirs "$root/skip-stop/sessions" skip_stop
prune_marker_dirs "$root/skip-stop/cwd" skip_stop
prune_marker_dirs "$root/side-stop/sessions" side_stop

ctx='Load ~/.codex/CODEX.md and matching ~/.codex/skills when applicable.'
eci_marker="$proof_dir/eci_active"
if [ -d "$proof_dir" ] && [ ! -L "$proof_dir" ] &&
    { { [ -f "$eci_marker" ] && [ ! -L "$eci_marker" ]; } || nested_marker_is_active; }; then
  ctx='ECI is active. ECI refresh signal (not proof of compaction): after compaction, the coordinator/lead must immediately re-read the entire skills/explore-critique-implement/SKILL.md and re-invoke it before the next decision/tool.'
fi

jq -n --arg ctx "$ctx" '{
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: $ctx
  }
}'
