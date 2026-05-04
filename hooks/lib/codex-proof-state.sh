#!/usr/bin/env bash
# Shared state helpers for Codex proof-adjacent hooks.

codex_proof_root() {
  printf '%s\n' "${CODEX_PROOF_ROOT:-$HOME/.cache/codex-proof}"
}

codex_valid_session_id() {
  case "${1:-}" in
    ""|*[!A-Za-z0-9_-]*) return 1 ;;
    *) return 0 ;;
  esac
}

codex_canonical_cwd() {
  local cwd="${1:-$PWD}"
  if [ -d "$cwd" ]; then
    (cd "$cwd" 2>/dev/null && pwd -P) || printf '%s\n' "$cwd"
  else
    printf '%s\n' "$cwd"
  fi
}

codex_cwd_key() {
  local cwd
  cwd="$(codex_canonical_cwd "${1:-$PWD}")"
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$cwd" | sha256sum | awk '{print $1}'
  else
    printf '%s' "$cwd" | cksum | awk '{print $1}'
  fi
}

codex_session_state_dir() {
  local kind="$1"
  local session_id="$2"
  codex_valid_session_id "$session_id" || return 1
  printf '%s/%s/sessions/%s\n' "$(codex_proof_root)" "$kind" "$session_id"
}

codex_cwd_state_dir() {
  local kind="$1"
  local cwd="${2:-$PWD}"
  printf '%s/%s/cwd/%s\n' "$(codex_proof_root)" "$kind" "$(codex_cwd_key "$cwd")"
}

codex_ensure_cwd_state_dir() {
  local kind="$1"
  local cwd="${2:-$PWD}"
  local dir
  dir="$(codex_cwd_state_dir "$kind" "$cwd")" || return 1
  mkdir -p "$dir" || return 1
  codex_canonical_cwd "$cwd" >"$dir/cwd"
  printf '%s\n' "$dir"
}

codex_cli_state_dir() {
  local kind="$1"
  local create="${2:-false}"
  local dir

  if [ -n "${CODEX_SESSION_ID:-}" ]; then
    dir="$(codex_session_state_dir "$kind" "$CODEX_SESSION_ID")" || return 1
    [ "$create" = "true" ] && mkdir -p "$dir"
    printf '%s\n' "$dir"
    return 0
  fi

  if [ "$create" = "true" ]; then
    codex_ensure_cwd_state_dir "$kind" "$PWD"
  else
    codex_cwd_state_dir "$kind" "$PWD"
  fi
}

codex_cli_state_file() {
  local kind="$1"
  local filename="$2"
  local create="${3:-false}"
  local dir
  dir="$(codex_cli_state_dir "$kind" "$create")" || return 1
  printf '%s/%s\n' "$dir" "$filename"
}

codex_existing_state_file() {
  local kind="$1"
  local filename="$2"
  local session_id="${3:-}"
  local cwd="${4:-}"
  local dir path

  if codex_valid_session_id "$session_id"; then
    dir="$(codex_session_state_dir "$kind" "$session_id")" || return 1
    path="$dir/$filename"
    [ -f "$path" ] && { printf '%s\n' "$path"; return 0; }
  fi

  if [ -n "$cwd" ]; then
    dir="$(codex_cwd_state_dir "$kind" "$cwd")" || return 1
    path="$dir/$filename"
    [ -f "$path" ] && { printf '%s\n' "$path"; return 0; }
  fi

  if codex_valid_session_id "$session_id"; then
    path="$(codex_proof_root)/$session_id/$filename"
    [ -f "$path" ] && { printf '%s\n' "$path"; return 0; }
  fi

  return 1
}

codex_state_session_id() {
  local file="$1"
  awk -F':[[:space:]]*' '$1 == "session_id" { print $2; exit }' "$file" 2>/dev/null
}

codex_note_state_session_id() {
  local file="$1"
  local session_id="$2"
  local existing

  codex_valid_session_id "$session_id" || return 0
  [ -f "$file" ] || return 0
  existing="$(codex_state_session_id "$file" || true)"
  [ -n "$existing" ] && return 0
  printf 'session_id: %s\n' "$session_id" >>"$file"
}

codex_state_value() {
  local file="$1"
  local key="$2"
  awk -F':[[:space:]]*' -v key="$key" '$1 == key { print $2; exit }' "$file" 2>/dev/null
}

codex_side_stop_applies_to_session() {
  local file="$1"
  local session_id="$2"
  local command parent_session_id

  [ -f "$file" ] || return 1
  command="$(codex_state_value "$file" command || true)"
  [ "$command" = "/side" ] || return 1

  parent_session_id="$(codex_state_value "$file" parent_session_id || true)"
  if codex_valid_session_id "$parent_session_id"; then
    [ "$parent_session_id" != "$session_id" ]
    return
  fi

  return 0
}

codex_hook_is_subagent_context() {
  local input="${1:-}"
  local transcript_path first_event

  transcript_path="$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null || true)"
  case "$transcript_path" in
    "$HOME/.codex/sessions/"*.jsonl) ;;
    *) return 1 ;;
  esac

  [ -f "$transcript_path" ] || return 1
  first_event="$(sed -n '1p' "$transcript_path" 2>/dev/null || true)"
  printf '%s' "$first_event" | jq -e '
    .type == "session_meta" and
    (.payload.source.subagent.thread_spawn? != null)
  ' >/dev/null 2>&1
}

codex_remove_session_state_file() {
  local kind="$1"
  local filename="$2"
  local session_id="$3"
  local dir
  dir="$(codex_session_state_dir "$kind" "$session_id")" || return 0
  rm -f "$dir/$filename"
}

codex_remove_cwd_state_file() {
  local kind="$1"
  local filename="$2"
  local cwd="${3:-$PWD}"
  local dir
  dir="$(codex_cwd_state_dir "$kind" "$cwd")" || return 0
  rm -f "$dir/$filename"
}
