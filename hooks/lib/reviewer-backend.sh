# Shellcheck-friendly library: parse no-credential reviewer backend specs.
# shellcheck shell=bash

SYNTHETIC_USER_TAG_RE='^[[:space:]]*<(task-notification|command-name|command-message|command-args|local-command-stdout|local-command-caveat|system-reminder)>'

reviewer_reset_backend() {
  REVIEWER_BACKEND=""
  REVIEWER_OLLAMA_HOST=""
  REVIEWER_OLLAMA_MODEL=""
  REVIEWER_OPENCODE_HOST=""
  REVIEWER_OPENCODE_MODEL=""
}

parse_reviewer_env() {
  local env_name="${1:-CODEX_STOP_REVIEWER}"
  local raw="${!env_name:-}"

  reviewer_reset_backend
  [ -z "$raw" ] && return 0

  case "$raw" in
    ollama:*)
      local rest="${raw#ollama:}"
      if [[ "$rest" =~ ^([a-zA-Z][a-zA-Z0-9+.-]*://[^:/[:space:]]+(:[0-9]+)?)/?:(.+)$ ]]; then
        REVIEWER_BACKEND="ollama"
        REVIEWER_OLLAMA_HOST="${BASH_REMATCH[1]}"
        REVIEWER_OLLAMA_MODEL="${BASH_REMATCH[3]}"
        return 0
      fi
      printf 'reviewer-backend: malformed %s=%q (expected ollama:scheme://host[:port]:MODEL)\n' "$env_name" "$raw" >&2
      return 1
      ;;
    opencode-zen:*)
      local rest="${raw#opencode-zen:}"
      if [[ "$rest" =~ ^([a-zA-Z][a-zA-Z0-9+.-]*://[^:/[:space:]]+(:[0-9]+)?)/?:(.+)$ ]]; then
        REVIEWER_BACKEND="opencode-zen"
        REVIEWER_OPENCODE_HOST="${BASH_REMATCH[1]}"
        REVIEWER_OPENCODE_MODEL="${BASH_REMATCH[3]}"
        return 0
      fi
      printf 'reviewer-backend: malformed %s=%q (expected opencode-zen:scheme://host[:port]:MODEL)\n' "$env_name" "$raw" >&2
      return 1
      ;;
    *)
      printf 'reviewer-backend: unknown %s=%q (review skipped; allowed: ollama:URL:MODEL, opencode-zen:URL:MODEL)\n' "$env_name" "$raw" >&2
      return 1
      ;;
  esac
}
