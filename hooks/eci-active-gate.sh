#!/usr/bin/env bash
# PreToolUse hook: block direct main-session edits while ECI is active.

set -euo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HOOK_DIR/lib/codex-proof-state.sh"
. "$HOOK_DIR/lib/eci-diagnostic.sh"

input=$(cat)
has_any_active_eci_marker() {
  local probe_cwd probe_session
  probe_cwd="$(printf '%s' "$input" | jq -r 'if (.cwd? | type) == "string" then .cwd else "" end' 2>/dev/null || true)"
  probe_session="$(printf '%s' "$input" | jq -r 'if (.session_id? | type) == "string" then .session_id else "" end' 2>/dev/null || true)"
  [ -n "$probe_cwd" ] || probe_cwd="$PWD"
  mapfile -t active_markers < <(codex_eci_markers_for_cwd "$probe_cwd" strict "$probe_session" 2>/dev/null || true)
  [ "${#active_markers[@]}" -gt 0 ]
}

deny_malformed_identity() {
  local target subject="session=${session_id:-<missing>},cwd=${cwd:-<missing>},tool=$(eci_diagnostic_value "${tool_name:-<missing>}")"
  target="$(printf '%s' "$input" | jq -r 'if (.tool_input?.file_path? | type) == "string" then .tool_input.file_path elif (.tool_input?.path? | type) == "string" then .tool_input.path else "<missing>" end' 2>/dev/null || true)"
  subject="$subject,target=$(eci_diagnostic_value "${target:-<missing>}")"
  local reason
  reason="$(eci_diagnostic_reason "ECI_HOOK_IDENTITY_MALFORMED" "PreToolUse" "edit-routing" "$subject" "malformed hook identity: tool_name, session_id, cwd, and edit path fields must be typed strings while an active marker exists" "provide typed tool_name, session_id, cwd, and edit path fields, then retry")"
  jq -n --arg reason "$reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
}

deny_unsafe_marker() {
  local marker="${1:-}" expected_cwd="${2:-}" expected_session="${3:-}" code
  local detail remediation
  code="$(codex_eci_marker_failure_code "$marker" "$expected_cwd" "$expected_session")"
  local reason
  case "$code" in
    ECI_MARKER_MISSING_CURRENT)
      detail="active ECI marker is missing for session=$expected_session cwd=$expected_cwd"
      remediation="recreate the coordinator-owned marker through the ECI lifecycle route, or complete teardown before retrying"
      ;;
    ECI_MARKER_UNSAFE_PATH)
      detail="active ECI marker path is outside the validated proof-root layout or is a symlink"
      remediation="use the canonical proof-root/session/eci_active path and remove the unsafe path before retrying"
      ;;
    ECI_MARKER_MALFORMED)
      detail="active ECI marker content is malformed or exceeds the bounded record schema"
      remediation="rewrite the marker through the coordinator lifecycle route with the required bounded fields"
      ;;
    ECI_MARKER_SCOPE_MISMATCH)
      detail="active ECI marker owner or cwd does not match session=$expected_session cwd=$expected_cwd"
      remediation="use the marker bound to this session and cwd, or complete teardown before retrying"
      ;;
    ECI_MARKER_OWNERSHIP_INVALID)
      detail="active ECI marker path owner does not match its embedded session identity"
      remediation="repair marker ownership through the coordinator lifecycle route; do not edit the marker directly"
      ;;
    *)
      detail="active ECI marker failed validation for session=$expected_session cwd=$expected_cwd"
      remediation="inspect the marker binding and repair or complete ECI teardown before retrying"
      ;;
  esac
  local marker_target="$(tool_paths 2>/dev/null || true)"
  reason="$(eci_diagnostic_reason "$code" "PreToolUse" "edit-routing" "tool=${tool_name:-<unknown>},target=${marker_target:-<unparsed>},marker=$marker,session=$expected_session,cwd=$expected_cwd" "$detail (marker=$marker)" "$remediation")"
  jq -n --arg reason "$reason" ' {
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
}

if ! printf '%s' "$input" | jq -e '
  type == "object" and (.tool_name | type) == "string" and
  (.tool_name | length > 0) and
  (.session_id | type) == "string" and (.cwd | type) == "string"
' >/dev/null 2>&1; then
  if has_any_active_eci_marker; then
    deny_malformed_identity
  fi
  exit 0
fi
tool_name=$(printf '%s' "$input" | jq -r '.tool_name' 2>/dev/null || true)

session_id=$(printf '%s' "$input" | jq -r '.session_id' 2>/dev/null || true)
cwd=$(printf '%s' "$input" | jq -r '.cwd' 2>/dev/null || true)
case "$session_id" in
  ""|*[!A-Za-z0-9_-]*)
    if has_any_active_eci_marker; then
      deny_malformed_identity
    fi
    exit 0
    ;;
esac
[ -n "$cwd" ] || {
  if has_any_active_eci_marker; then
    deny_malformed_identity
  fi
  exit 0
}
case "$cwd" in
  *[![:print:]]*)
    if has_any_active_eci_marker; then
      deny_malformed_identity
    fi
    exit 0
    ;;
esac
canonical_edit_cwd="$(codex_canonical_cwd "$cwd")"

case "$tool_name" in
  apply_patch|Edit|Write|MultiEdit|NotebookEdit) ;;
  *) exit 0 ;;
esac

is_subagent=false
# The bounded transcript parser is only meaningful when the hook transport
# supplies a transcript path.  Avoid starting Python for ordinary callbacks;
# a patch body that happens to mention the field merely takes the conservative
# slower path.
if [[ "$input" == *'"transcript_path"'* ]] && codex_hook_is_subagent_context "$input"; then
  is_subagent=true
fi

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

# The high-level log is history, not a rewriteable Markdown document.  Route
# it through the append-only shell path; Edit/Write/apply_patch cannot prove
# prefix preservation or EOF-only publication.
tool_path_list="$(tool_paths)"
while IFS= read -r ledger_path; do
  [ -n "$ledger_path" ] || continue
  resolved_ledger_path="$(codex_resolve_hook_path "$cwd" "$ledger_path" 2>/dev/null || true)"
  if [ -n "$resolved_ledger_path" ] &&
    [ "${resolved_ledger_path##*/}" = "high_level_log.anchor" ] &&
    codex_path_is_session_ledger_file "$resolved_ledger_path"; then
    target_value="$(eci_diagnostic_value "$resolved_ledger_path")"
    reason="$(eci_diagnostic_reason "ECI_LEDGER_APPEND_ONLY" "PreToolUse" "edit-routing" "tool=$tool_name,target=$target_value" "ECI denies direct ledger-anchor edits because the append-only anchor is coordinator-managed" "use the coordinator-only eci-active ledger-append route for this canonical target")"
    jq -n --arg reason "$reason" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: $reason
      }
    }'
    exit 0
  fi
  if [ -n "$resolved_ledger_path" ] && codex_path_is_high_level_log_file "$resolved_ledger_path"; then
    target_value="$(eci_diagnostic_value "$resolved_ledger_path")"
    reason="$(eci_diagnostic_reason "ECI_LEDGER_APPEND_ONLY" "PreToolUse" "edit-routing" "tool=$tool_name,target=$target_value" "ECI denies direct high_level_log.md edits because the append-only ledger is coordinator-managed" "use the coordinator-only eci-active ledger-append route for the canonical target")"
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

direct_marker="$(codex_proof_root)/$session_id/eci_active"
direct_valid=false
if [ -e "$direct_marker" ] || [ -L "$direct_marker" ]; then
  [ -f "$direct_marker" ] && [ ! -L "$direct_marker" ] || {
    deny_unsafe_marker "$direct_marker" "$canonical_edit_cwd" "$session_id"
    exit 0
  }
  codex_eci_marker_file_is_bounded "$direct_marker" || {
    deny_unsafe_marker "$direct_marker" "$canonical_edit_cwd" "$session_id"
    exit 0
  }
  if codex_eci_marker_is_valid_for_cwd "$direct_marker" "$canonical_edit_cwd"; then
    direct_valid=true
  else
    deny_unsafe_marker "$direct_marker" "$canonical_edit_cwd" "$session_id"
    exit 0
  fi
fi

# Resolve a spawned worker's parent marker directly before the bounded proof
# root scan. This keeps a valid orchestrator owner discoverable even when
# unrelated entries fill the finite scan budget.
if [ "$is_subagent" = true ]; then
  parent_session_id="$(codex_hook_parent_session_id "$input" 2>/dev/null || true)"
  if codex_valid_session_id "$parent_session_id" && codex_session_dir_is_safe "$(codex_proof_root)" "$parent_session_id"; then
    parent_marker="$(codex_proof_root)/$parent_session_id/eci_active"
    if [ -f "$parent_marker" ] && [ ! -L "$parent_marker" ] &&
      codex_eci_marker_file_is_bounded "$parent_marker" &&
      codex_eci_marker_is_valid_for_cwd "$parent_marker" "$canonical_edit_cwd"; then
      parent_marker_direct=true
    else
      parent_marker_direct=false
    fi
  else
    parent_marker_direct=false
  fi
else
  parent_marker_direct=false
fi
mapfile -t active_markers < <(codex_eci_markers_for_cwd "$canonical_edit_cwd" strict "$session_id" 2>/dev/null || true)
overflow_seen=false
filtered_markers=()
for active_marker in "${active_markers[@]}"; do
  if [ "$active_marker" = "$codex_eci_marker_scan_overflow_token" ]; then
    overflow_seen=true
    continue
  fi
  filtered_markers+=("$active_marker")
done
active_markers=("${filtered_markers[@]}")
for active_marker in "${active_markers[@]}"; do
  if ! codex_eci_marker_path_owner_is_valid "$active_marker"; then
    deny_unsafe_marker "$active_marker" "$canonical_edit_cwd" "$session_id"
    exit 0
  fi
done
if [ "$overflow_seen" = true ]; then
  # A validated direct/current marker is authoritative for this edit route;
  # unrelated proof-root entries beyond the bounded scan must not deny it.
  # A worker may legitimately have a different hook session id from the
  # single orchestrator marker selected by cwd ownership.  With one validated
  # owner, that bounded worker route is still unambiguous; multiple owners or
  # no owner remain unsafe and fail closed.
  if [ "$parent_marker_direct" = true ]; then
    active_markers=("$parent_marker")
  elif [ "${#active_markers[@]}" -gt 1 ] ||
    { [ "$direct_valid" != true ] &&
      { [ "$is_subagent" != true ] || [ "${#active_markers[@]}" -ne 1 ]; }; }; then
    deny_unsafe_marker "${active_markers[0]:-}" "$canonical_edit_cwd" "$session_id"
    exit 0
  fi
fi
if [ "$direct_valid" = true ]; then
  direct_seen=false
  for active_marker in "${active_markers[@]}"; do
    [ "$active_marker" = "$direct_marker" ] && direct_seen=true
  done
  [ "$direct_seen" = true ] || active_markers+=("$direct_marker")
fi
[ "${#active_markers[@]}" -gt 0 ] || exit 0
[ "${#active_markers[@]}" -eq 1 ] || {
  reason="$(eci_diagnostic_reason "ECI_MARKER_OWNERSHIP_AMBIGUOUS" "PreToolUse" "edit-routing" "$canonical_edit_cwd" "ECI edit routing denied multiple active marker owners for this cwd" "resolve marker ownership so exactly one validated owner remains, then retry")"
  jq -n --arg reason "$reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
}
marker="${active_markers[0]}"

if [ "$is_subagent" = true ]; then
  # Assigned workers are permitted to edit through the worker routing gate;
  # critic admission is enforced at coordinator commit/final/off boundaries.
  exit 0
fi

codex_eci_marker_file_is_bounded "$marker" || {
  deny_unsafe_marker "$marker" "$canonical_edit_cwd" "$session_id"
  exit 0
}
marker_code="$(codex_eci_marker_failure_code "$marker" "$canonical_edit_cwd" "$session_id")"
reason="$(eci_diagnostic_reason "ECI_MAIN_THREAD_EDIT_DELEGATION_REQUIRED" "PreToolUse" "edit-routing" "tool=$tool_name,target=${tool_path_list:-<unparsed>},session=$session_id,cwd=$cwd,marker=$marker,marker_code=$marker_code" "ECI is active for this ${tool_name} edit; direct main-thread edits are prohibited" "delegate repository edits to the assigned implementer; this denial governs edit routing only")"
jq -n --arg reason "$reason" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $reason
  }
}'
