#!/usr/bin/env bash
# UserPromptSubmit hook: capture only this prompt; never scan transcript history.
# See hooks/pre-reviewer-causal-scope.md for cleanup and timeout invariants.

set -euo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HOOK_DIR/lib/codex-proof-state.sh"
. "$HOOK_DIR/lib/pre-reviewer-turn-state.sh"
. "$HOOK_DIR/lib/reviewer-redact.sh"

input="$(python3 "$HOOK_DIR/lib/bounded_hook_input.py" stdin)" || exit 0
session_id=$(printf '%s' "$input" | jq -r 'if (.session_id? | type) == "string" then .session_id else "" end' 2>/dev/null || true)
cwd=$(printf '%s' "$input" | jq -r 'if (.cwd? | type) == "string" then .cwd else "" end' 2>/dev/null || true)
prompt=$(printf '%s' "$input" | jq -r 'if (.prompt? | type) == "string" then .prompt else "" end' 2>/dev/null || true)
prompt_type=$(printf '%s' "$input" | jq -r '.prompt? | type' 2>/dev/null || true)
turn_id_json="$(codex_hook_turn_id_json "$input")"
root="$(codex_proof_root)"

capture_redacted_tmp=""
capture_capped_tmp=""
capture_json_tmp=""

cleanup_capture_temps() {
  rm -f "${capture_redacted_tmp:-}" "${capture_capped_tmp:-}" "${capture_json_tmp:-}" 2>/dev/null || true
}

cleanup_prompt_turn() {
  codex_unlock_pre_reviewer_turn
  cleanup_capture_temps
}

prepare_current_turn_capture() {
  local state_dir="$1"
  local key="$2"

  umask 077
  capture_redacted_tmp=$(mktemp "$state_dir/.capture-turn-$key.redacted.XXXXXX") || return 1
  capture_capped_tmp=$(mktemp "$state_dir/.capture-turn-$key.capped.XXXXXX") || {
    cleanup_capture_temps
    return 1
  }
  capture_json_tmp=$(mktemp "$state_dir/.capture-turn-$key.json.XXXXXX") || {
    cleanup_capture_temps
    return 1
  }
  trap cleanup_prompt_turn EXIT
  trap 'cleanup_prompt_turn; exit 0' HUP INT TERM

  if ! printf '%s' "$input" | jq -jr '.prompt' 2>/dev/null | redact_sensitive_text >"$capture_redacted_tmp"; then
    cleanup_capture_temps
    return 1
  fi
  if ! python3 "$HOOK_DIR/lib/utf8_prefix_cap.py" \
      <"$capture_redacted_tmp" >"$capture_capped_tmp"; then
    cleanup_capture_temps
    return 1
  fi
  if ! jq -n --argjson turn_id "$turn_id_json" --rawfile prompt "$capture_capped_tmp" \
    '{turn_id:$turn_id,prompt:$prompt}' >"$capture_json_tmp"; then
    cleanup_capture_temps
    return 1
  fi
  if ! chmod 0600 "$capture_json_tmp"; then
    cleanup_capture_temps
    return 1
  fi

  rm -f "$capture_redacted_tmp" "$capture_capped_tmp"
  capture_redacted_tmp=""
  capture_capped_tmp=""
}

write_side_stop_marker() {
  local dir="$1"
  mkdir -p "$dir"
  {
    printf 'command: /side\n'
    printf 'parent_session_id: %s\n' "$session_id"
    [ -n "$cwd" ] && printf 'cwd: %s\n' "$cwd"
    date -u '+created_utc: %Y-%m-%dT%H:%M:%SZ'
  } >"$dir/side_stop"
}

if codex_valid_session_id "$session_id"; then
  if [ -n "$turn_id_json" ]; then
    reviewer_dir="$root/reviewer/$session_id"
    pre_reviewer_dir="$root/pre-reviewer/$session_id"
    mkdir -p "$reviewer_dir"
    pre_reviewer_ready=false
    if codex_ensure_private_pre_reviewer_state_dir "$pre_reviewer_dir"; then
      pre_reviewer_ready=true
    fi
    head=$(git -C "$HOME/.codex" rev-parse HEAD 2>/dev/null || true)
    if [ -n "$head" ]; then
      printf '%s\n' "$head" >"$reviewer_dir/prompt_head"
    fi
    rm -f "$reviewer_dir/bypass"
    if [ "$pre_reviewer_ready" = true ]; then
      rm -f "$pre_reviewer_dir/bypass"
    fi

    if [ "$pre_reviewer_ready" = true ]; then
      turn_key="$(codex_turn_state_key "$turn_id_json" 2>/dev/null || true)"
      capture_prepared=false
      if [ -n "$turn_key" ] && [ "$prompt_type" = "string" ] &&
          prepare_current_turn_capture "$pre_reviewer_dir" "$turn_key"; then
        capture_prepared=true
      fi
      if [ -n "$turn_key" ] && codex_lock_pre_reviewer_turn "$pre_reviewer_dir"; then
        turn_capture="$(codex_turn_capture_path "$pre_reviewer_dir" "$turn_key")"
        turn_claim="$(codex_turn_claim_path "$pre_reviewer_dir" "$turn_key")"
        codex_prune_pre_reviewer_turn_state || true
        if [ ! -e "$turn_claim" ] && [ ! -L "$turn_claim" ]; then
          if rm -f -- "$turn_capture"; then
            if [ "$capture_prepared" = true ]; then
              if mv -f -- "$capture_json_tmp" "$turn_capture"; then
                capture_json_tmp=""
              fi
            fi
          fi
        fi
        codex_unlock_pre_reviewer_turn
      fi
      cleanup_capture_temps
      trap - EXIT HUP INT TERM
    fi
  fi

  if printf '%s\n' "$prompt" | grep -Eq '^[[:space:]]*/side([[:space:]]|$)'; then
    write_side_stop_marker "$root/side-stop/sessions/$session_id"
    if [ -n "$cwd" ]; then
      side_dir="$(codex_ensure_cwd_state_dir side-stop "$cwd" 2>/dev/null || true)"
      [ -n "$side_dir" ] && write_side_stop_marker "$side_dir"
    fi
  fi

fi
