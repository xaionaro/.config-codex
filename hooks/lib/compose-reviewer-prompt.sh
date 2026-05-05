# Shellcheck-friendly library: compose the reviewer system prompt.
# shellcheck shell=bash

compose_reviewer_prompt() {
  local wrapper="$1"
  local instructions="$HOME/.codex/CODEX.md"
  local stop_checklist="$HOME/.codex/hooks/stop-checklist.md"
  local import_summary="$HOME/.codex/memories/migration-import/ACTIVE-SUMMARY.md"
  local legacy_import_summary="$HOME/.codex/memories/claude"'-import/ACTIVE-SUMMARY.md'

  [ -f "$wrapper" ] || { printf 'compose_reviewer_prompt: wrapper not found: %s\n' "$wrapper" >&2; return 1; }
  [ -f "$instructions" ] || { printf 'compose_reviewer_prompt: CODEX.md not found: %s\n' "$instructions" >&2; return 1; }

  cat "$wrapper"
  printf '\n\n============================================================\n'
  printf '# CODEX.md (user global instructions)\n'
  printf '============================================================\n\n'
  cat "$instructions"
  printf '\n'

  if [ -f "$stop_checklist" ]; then
    printf '\n============================================================\n'
    printf '# stop-checklist.md (acceptance criteria for ending a turn)\n'
    printf '============================================================\n\n'
    cat "$stop_checklist"
    printf '\n'
  fi

  if [ ! -f "$import_summary" ] && [ -f "$legacy_import_summary" ]; then
    import_summary="$legacy_import_summary"
  fi

  if [ -f "$import_summary" ]; then
    printf '\n============================================================\n'
    printf '# imported migration summary (Codex migration notes)\n'
    printf '============================================================\n\n'
    cat "$import_summary"
    printf '\n'
  fi
}
