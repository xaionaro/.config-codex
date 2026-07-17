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

codex_reserved_proof_dir() {
  case "${1:-}" in
    activity|audit|eci|history|pre-reviewer|reviewer|reviewer-dumps|security-warnings-*|side-stop|skip-stop|skills)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

codex_real_session_dir_name() {
  [[ "${1:-}" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]
}

codex_proof_alias_session_id() {
  local dir="$1"
  local marker session_id

  marker="$dir/.codex-proof-alias"
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  session_id="$(awk -F':[[:space:]]*' '$1 == "session_id" { print $2; exit }' "$marker" 2>/dev/null | tr -d '\r')"
  codex_valid_session_id "$session_id" || return 1
  printf '%s\n' "$session_id"
}

codex_canonical_cwd() {
  local cwd="${1:-$PWD}"
  if [ -d "$cwd" ]; then
    (cd "$cwd" 2>/dev/null && pwd -P) || printf '%s\n' "$cwd"
  else
    printf '%s\n' "$cwd"
  fi
}

codex_resolve_hook_path() {
  local cwd="${1:-$PWD}"
  local path="${2:-}"

  [ -n "$path" ] || return 1
  [ -n "$cwd" ] || cwd="$PWD"
  case "$path" in
    "~") path="$HOME" ;;
    "~/"*) path="$HOME/${path#~/}" ;;
  esac
  case "$path" in
    /*) ;;
    *) path="$cwd/$path" ;;
  esac

  realpath -m -- "$path" 2>/dev/null || printf '%s\n' "$path"
}

codex_session_ledger_basenames() {
  printf '%s\n' \
    "project-understanding.md" \
    "high_level_log.md" \
    "latest-status-report.md"
}

codex_session_ledger_basename() {
  case "${1:-}" in
    project-understanding.md|high_level_log.md|latest-status-report.md)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

codex_path_is_session_ledger_file() {
  local path="$1"
  local actual_root default_root root rest sid filename

  [ -n "$path" ] || return 1
  filename="${path##*/}"
  codex_session_ledger_basename "$filename" || return 1

  actual_root="$(codex_resolve_hook_path "$PWD" "$(codex_proof_root)" 2>/dev/null || codex_proof_root)"
  default_root="$(codex_resolve_hook_path "$PWD" "$HOME/.cache/codex-proof" 2>/dev/null || printf '%s\n' "$HOME/.cache/codex-proof")"
  for root in "$actual_root" "$default_root"; do
    [ -n "$root" ] || continue
    case "$path" in
      "$root"/*)
        rest="${path#"$root"/}"
        sid="${rest%%/*}"
        [ "$rest" != "$sid" ] || continue
        [ "${rest#*/}" = "$filename" ] || continue
        codex_reserved_proof_dir "$sid" && continue
        codex_valid_session_id "$sid" || continue
        return 0
        ;;
    esac
  done

  return 1
}

codex_hash_string() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "${1:-}" | sha256sum | awk '{print $1}'
  elif command -v python3 >/dev/null 2>&1; then
    printf '%s' "${1:-}" | python3 -c \
      'import hashlib, sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'
  else
    return 1
  fi
}

codex_cwd_key() {
  local cwd
  cwd="$(codex_canonical_cwd "${1:-$PWD}")"
  codex_hash_string "$cwd"
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

codex_git_repo_root_for_path() {
  local cwd="${1:-$PWD}"
  local path="${2:-}"
  local target dir repo

  if [ -n "$path" ]; then
    case "$path" in
      /*) target="$path" ;;
      *) target="$cwd/$path" ;;
    esac
  else
    target="$cwd"
  fi

  if [ -d "$target" ]; then
    dir="$target"
  else
    dir="$(dirname -- "$target")"
  fi
  while [ ! -d "$dir" ] && [ "$dir" != "/" ]; do
    dir="$(dirname -- "$dir")"
  done
  [ -d "$dir" ] || return 1

  repo="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$repo" ] || return 1
  codex_canonical_cwd "$repo"
}

codex_repo_relative_file_path() {
  local repo="$1"
  local cwd="${2:-$PWD}"
  local path="${3:-}"
  local target rel

  [ -n "$repo" ] && [ -n "$path" ] || return 1
  case "$path" in
    /*) target="$path" ;;
    *) target="$cwd/$path" ;;
  esac

  [ ! -d "$target" ] || return 1
  rel="$(realpath -m --relative-to="$repo" "$target" 2>/dev/null || true)"
  [ -n "$rel" ] || return 1
  case "$rel" in
    "."|".."|../*|/*) return 1 ;;
  esac
  printf '%s\n' "$rel"
}

codex_note_touched_repo() {
  local session_id="$1"
  local cwd="${2:-$PWD}"
  local path="${3:-}"
  local repo dir marker key head status status_sha tmp rel_path

  codex_valid_session_id "$session_id" || return 0
  repo="$(codex_git_repo_root_for_path "$cwd" "$path" 2>/dev/null || true)"
  [ -n "$repo" ] || return 0
  rel_path="$(codex_repo_relative_file_path "$repo" "$cwd" "$path" 2>/dev/null || true)"

  dir="$(codex_session_state_dir touched-repos "$session_id")" || return 0
  mkdir -p "$dir" || return 0
  key="$(codex_cwd_key "$repo")"
  marker="$dir/$key"
  if [ -f "$marker" ]; then
    if [ -n "$rel_path" ]; then
      grep -Fxq -- "path: $rel_path" "$marker" 2>/dev/null || printf 'path: %s\n' "$rel_path" >>"$marker"
    else
      grep -Fxq 'repo_wide: true' "$marker" 2>/dev/null || printf 'repo_wide: true\n' >>"$marker"
    fi
    return 0
  fi

  head="$(git -C "$repo" rev-parse HEAD 2>/dev/null || true)"
  status="$(git -C "$repo" status --porcelain=v1 --untracked-files=normal 2>/dev/null || true)"
  status_sha="$(codex_hash_string "$status")"
  tmp="$marker.tmp.$$"
  {
    printf 'repo: %s\n' "$repo"
    printf 'head: %s\n' "$head"
    printf 'status_sha: %s\n' "$status_sha"
    if [ -n "$rel_path" ]; then
      printf 'path: %s\n' "$rel_path"
    else
      printf 'repo_wide: true\n'
    fi
    date -u '+created_utc: %Y-%m-%dT%H:%M:%SZ'
  } >"$tmp" && mv "$tmp" "$marker"
}

codex_state_value() {
  local file="$1"
  local key="$2"
  awk -F':[[:space:]]*' -v key="$key" '$1 == key { print $2; exit }' "$file" 2>/dev/null
}

codex_legacy_eci_markers_for_cwd() {
  local cwd="${1:-}"
  local root marker dir name marker_cwd canonical_cwd canonical_marker_cwd found=false

  [ -n "$cwd" ] || return 1
  root="$(codex_proof_root)"
  [ -d "$root" ] || return 1
  canonical_cwd="$(codex_canonical_cwd "$cwd")"

  shopt -s nullglob
  for marker in "$root"/*/eci_active; do
    [ -f "$marker" ] || continue
    dir="${marker%/*}"
    name="${dir##*/}"
    codex_reserved_proof_dir "$name" || continue
    marker_cwd="$(codex_state_value "$marker" cwd || true)"
    [ -n "$marker_cwd" ] || continue
    canonical_marker_cwd="$(codex_canonical_cwd "$marker_cwd")"
    [ "$canonical_marker_cwd" = "$canonical_cwd" ] || continue
    printf '%s\n' "$marker"
    found=true
  done
  shopt -u nullglob

  [ "$found" = true ]
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
  local transcript_path first_record

  transcript_path="$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null || true)"
  case "$transcript_path" in
    "$HOME/.codex/sessions/"*.jsonl) ;;
    *) return 1 ;;
  esac

  [ -f "$transcript_path" ] || return 1
  first_record="$(python3 "${BASH_SOURCE[0]%/*}/bounded_hook_input.py" \
    first-record "$transcript_path" 2>/dev/null)" || return 1
  printf '%s' "$first_record" | jq -e '
    .type == "session_meta" and
    (.payload.source.subagent.thread_spawn? != null)
  ' >/dev/null 2>&1
}

codex_hook_transcript_first_record_is_admissible() {
  local input="${1:-}"
  local transcript_path first_record

  transcript_path="$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null || true)"
  [ -n "$transcript_path" ] || return 0
  case "$transcript_path" in
    "$HOME/.codex/sessions/"*.jsonl) ;;
    *) return 0 ;;
  esac
  [ -e "$transcript_path" ] || [ -L "$transcript_path" ] || return 0
  first_record="$(python3 "${BASH_SOURCE[0]%/*}/bounded_hook_input.py" \
    first-record "$transcript_path" 2>/dev/null)" || return 1
  printf '%s' "$first_record" | jq -e 'type == "object"' >/dev/null 2>&1
}

codex_hook_parent_session_id() {
  local input="${1:-}"
  local transcript_path first_record

  transcript_path="$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null || true)"
  [ -n "$transcript_path" ] && [ -f "$transcript_path" ] || return 1
  first_record="$(python3 "${BASH_SOURCE[0]%/*}/bounded_hook_input.py" \
    first-record "$transcript_path" 2>/dev/null)" || return 1
  printf '%s' "$first_record" | jq -r '
    .payload.source.subagent.thread_spawn.parent_thread_id // empty
  ' 2>/dev/null
}

codex_path_owner_session_id() {
  local path="$1"
  local root default_root rest sid base alias_session_id

  [ -n "$path" ] || return 1

  root="$(codex_proof_root)"
  default_root="$HOME/.cache/codex-proof"
  for root in "$root" "$default_root"; do
    [ -n "$root" ] || continue
    case "$path" in
      "$root"/*)
        rest="${path#"$root"/}"
        sid="${rest%%/*}"
        codex_reserved_proof_dir "$sid" && return 1
        if ! codex_real_session_dir_name "$sid"; then
          alias_session_id="$(codex_proof_alias_session_id "$root/$sid" 2>/dev/null || true)"
          if [ -n "$alias_session_id" ]; then
            printf '%s\n' "$alias_session_id"
            return 0
          fi
        fi
        codex_valid_session_id "$sid" || return 1
        printf '%s\n' "$sid"
        return 0
        ;;
    esac
  done

  case "$path" in
    "$HOME/.codex/sessions/"*.jsonl)
      base="${path##*/}"
      sid="$(printf '%s\n' "$base" | sed -nE 's/^rollout-[0-9T:-]+-([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$/\1/p')"
      if codex_valid_session_id "$sid"; then
        printf '%s\n' "$sid"
        return 0
      fi
      ;;
  esac

  return 1
}

codex_hook_allowed_session_ids() {
  local input="$1"
  local session_id parent_session_id

  session_id="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)"
  if codex_valid_session_id "$session_id"; then
    printf '%s\n' "$session_id"
  fi

  parent_session_id="$(codex_hook_parent_session_id "$input" 2>/dev/null || true)"
  if codex_valid_session_id "$parent_session_id" && [ "$parent_session_id" != "$session_id" ]; then
    printf '%s\n' "$parent_session_id"
  fi
}

codex_session_owner_allowed() {
  local owner="$1"
  local allowed
  shift

  for allowed in "$@"; do
    [ "$owner" = "$allowed" ] && return 0
  done
  return 1
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
