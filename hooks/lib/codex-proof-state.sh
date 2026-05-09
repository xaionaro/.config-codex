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

codex_mark_activity() {
  local session_id="$1"
  local cwd="$2"
  local marker_name="$3"
  local dir marker

  codex_valid_session_id "$session_id" || return 0
  case "$marker_name" in
    shell|edit|subagent) ;;
    *) return 0 ;;
  esac

  dir="$(codex_session_state_dir activity "$session_id")" || return 0
  mkdir -p "$dir" || return 0
  marker="$dir/$marker_name"
  {
    printf 'kind: %s\n' "$marker_name"
    [ -n "$cwd" ] && printf 'cwd: %s\n' "$cwd"
    date -u '+created_utc: %Y-%m-%dT%H:%M:%SZ'
  } >"$marker"
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

codex_state_file_is_session_scoped() {
  local kind="$1"
  local filename="$2"
  local session_id="$3"
  local file="$4"
  local expected

  expected="$(codex_session_state_dir "$kind" "$session_id" 2>/dev/null || true)"
  [ -n "$expected" ] && [ "$file" = "$expected/$filename" ]
}

codex_side_stop_is_active_for_session() {
  local file="$1"
  local session_id="$2"

  [ -n "$file" ] && [ -f "$file" ] || return 1
  codex_side_stop_applies_to_session "$file" "$session_id" || return 1

  if codex_state_file_is_session_scoped side-stop side_stop "$session_id" "$file"; then
    return 0
  fi

  [ -n "$(find "$file" -mmin -60 -print 2>/dev/null)" ]
}

codex_bind_side_stop_to_session() {
  local file="$1"
  local session_id="$2"
  local dir

  [ -f "$file" ] || return 1
  dir="$(codex_session_state_dir side-stop "$session_id")" || return 1
  mkdir -p "$dir" || return 1
  cp "$file" "$dir/side_stop"
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

codex_markdown_section_has_body() {
  local file="$1"
  local target="$2"

  awk -v target="$target" '
    BEGIN { target = tolower(target) }
    function trim(s) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
      return s
    }
    /^##[[:space:]]*/ {
      heading = $0
      sub(/^##[[:space:]]*/, "", heading)
      heading = tolower(trim(heading))
      if (in_section) exit
      if (heading == target) {
        in_section = 1
        next
      }
    }
    in_section {
      line = trim($0)
      if (line != "") found = 1
    }
    END { exit(found ? 0 : 1) }
  ' "$file"
}

codex_eci_terminal_verdict_error() {
  local subject="$1"
  local file="$2"
  local counts accepted retired

  counts="$(awk '
    {
      line = tolower($0)
      scan = line
      while (match(scan, /(^|[^[:alnum:]_-])(clean-pass|user-closed):/)) {
        accepted++
        scan = substr(scan, RSTART + RLENGTH)
      }
      scan = line
      while (match(scan, /(^|[^[:alnum:]_-])hard-escalation:/)) {
        retired++
        scan = substr(scan, RSTART + RLENGTH)
      }
    }
    END { print accepted + 0, retired + 0 }
  ' "$file")"
  read -r accepted retired <<EOF
$counts
EOF

  if [ "${retired:-0}" -ne 0 ]; then
    printf '%s must include exactly one terminal verdict marker: clean-pass: or user-closed:, and must not include retired marker hard-escalation:. Report a blocker requiring user input while ECI remains active.\n' "$subject"
  elif [ "${accepted:-0}" -ne 1 ]; then
    printf '%s must include exactly one terminal verdict marker: clean-pass: or user-closed:.\n' "$subject"
  fi
}
