#!/usr/bin/env bash
# PreToolUse hook: protect active ECI control and ledger targets during edits.

set -euo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HOOK_DIR/lib/codex-proof-state.sh"
. "$HOOK_DIR/lib/eci-diagnostic.sh"

input=$(cat)

if ! printf '%s' "$input" | jq -e '
  type == "object" and (.tool_name | type) == "string" and
  (.tool_name | length > 0) and
  (.session_id | type) == "string" and (.cwd | type) == "string"
' >/dev/null 2>&1; then
  # Callback transport is not an edit target.  Without a typed callback we
  # cannot resolve a concrete unsafe file, so leave the ordinary tool call to
  # its normal validation instead of converting metadata uncertainty into a
  # user-facing repair task.
  exit 0
fi
tool_name=$(printf '%s' "$input" | jq -r '.tool_name' 2>/dev/null || true)

session_id=$(printf '%s' "$input" | jq -r '.session_id' 2>/dev/null || true)
cwd=$(printf '%s' "$input" | jq -r '.cwd' 2>/dev/null || true)
case "$session_id" in
  ""|*[!A-Za-z0-9_-]*)
    exit 0
    ;;
esac
[ -n "$cwd" ] || {
  exit 0
}
case "$cwd" in
  *[![:print:]]*)
    exit 0
    ;;
esac

case "$tool_name" in
  apply_patch|Edit|Write|MultiEdit|NotebookEdit) ;;
  *) exit 0 ;;
esac

tool_paths() {
  case "$tool_name" in
    apply_patch)
      printf '%s' "$input" |
        jq -r '.tool_input.command // .tool_input.patch // .tool_input.input // empty' 2>/dev/null |
        awk '
          /^\*\*\* (Add|Update|Delete) File: / {
            sub(/^\*\*\* (Add|Update|Delete) File: /, "")
            print
          }
          /^\*\*\* Move to: / {
            sub(/^\*\*\* Move to: /, "")
            print
          }
        '
      ;;
    Edit|Write|MultiEdit|NotebookEdit)
      printf '%s' "$input" |
        jq -r '.tool_input.file_path // .tool_input.notebook_path // .tool_input.path // .tool_input.target_file // empty' 2>/dev/null
      ;;
  esac
}

markdown_only_edit() {
  local path
  local seen=false

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    seen=true
    case "$path" in
      *.[mM][dD]|*.[mM][aA][rR][kK][dD][oO][wW][nN]) ;;
      *) return 1 ;;
    esac
  done

  [ "$seen" = "true" ]
}

# These are current-session coordination documents, not cross-scope lifecycle
# controls.  Keep the exception scoped to the callback's own proof session so
# a foreign proof record still reaches the concrete control boundary below.
#
# The high-level anchor is derived local coordination state.  PreToolUse sees
# a requested write, not its result, so requiring a record-shaped payload or a
# hash here would make metadata a prerequisite for ordinary coordinator work.
# A later PostToolUse reconciler could regenerate the anchor from the actual
# log bytes; until one exists, a coordinator's own bounded update remains
# nonblocking rather than becoming a lifecycle-artifact denial.
current_session_working_document() {
  local path="${1:-}" owner_session

  case "${path##*/}" in
    project-understanding.md|latest-status-report.md|handoff.md|high_level_log.md|high_level_log.anchor) ;;
    *) return 1 ;;
  esac
  owner_session="$(codex_path_owner_session_id "$path" 2>/dev/null || true)"
  [ "$owner_session" = "$session_id" ]
}

tool_path_list="$(tool_paths)"

# A coordinator's ordinary repository edit must not become a control edit
# solely because it is made from the main thread.  Preserve the real target
# boundary, including lexical aliases and resolved proof-root controls, before
# the Markdown fast path below permits ordinary documentation edits.
while IFS= read -r control_path; do
  [ -n "$control_path" ] || continue
  lexical_control_path="$(codex_lexical_hook_path "$cwd" "$control_path" 2>/dev/null || true)"
  resolved_control_path="$(codex_resolve_hook_path "$cwd" "$control_path" 2>/dev/null || true)"
  control_alias=false
  if [ -n "$lexical_control_path" ] && codex_path_is_eci_control_alias "$lexical_control_path"; then
    control_alias=true
  elif [ -n "$resolved_control_path" ] && [ "$resolved_control_path" != "$lexical_control_path" ] &&
    codex_path_is_eci_control_alias "$resolved_control_path"; then
    control_alias=true
  fi
  if { codex_path_is_eci_control_file "$lexical_control_path" ||
       codex_path_is_eci_control_file "$resolved_control_path" ||
       [ "$control_alias" = true ]; } &&
     ! current_session_working_document "${resolved_control_path:-$lexical_control_path}"; then
    target_value="$(eci_diagnostic_value "${resolved_control_path:-$control_path}")"
    reason="$(eci_diagnostic_reason "ECI_CONTROL_OWNER_REQUIRED" "PreToolUse" "edit-routing" "tool=$tool_name,target=$target_value" "ECI denies direct edits to coordinator-owned active control state" "route this exact control-state operation through its coordinator lifecycle owner")"
    jq -n --arg reason "$reason" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: $reason
      }
    }'
    exit 0
  fi
done <<< "$tool_path_list"

if printf '%s\n' "$tool_path_list" | markdown_only_edit; then
  exit 0
fi

# Marker discovery and callback-parent state are not edit targets.  They may
# be stale, incomplete, or disagree while this callback still names an
# ordinary repository file.  The concrete path checks above have already
# stopped direct marker, ledger, active-control, and cross-session control
# targets; leave every other edit to normal routing/validation.
exit 0
