#!/usr/bin/env bash
# PreToolUse hook: block direct main-session edits while ECI is active.

set -euo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HOOK_DIR/lib/codex-proof-state.sh"
. "$HOOK_DIR/lib/eci-diagnostic.sh"

input=$(cat)

# Resolve the worker transcript once.  The edit dispatcher runs this gate
# beside the authoritative edit validator; reparsing the same bounded
# transcript for the early overflow probe and the parent-marker route adds a
# full Python startup to every worker callback.
hook_is_subagent=false
parent_session_id=""
hook_context_metadata=""
hook_transcript_path="$(printf '%s' "$input" | jq -r 'if (.transcript_path? | type) == "string" then .transcript_path else "" end' 2>/dev/null || true)"
if [ -n "$hook_transcript_path" ] &&
   hook_context_metadata="$(codex_hook_thread_spawn_metadata "$input" 2>/dev/null)"; then
  if [[ "$hook_context_metadata" =~ ^\{\"parent_thread_id\":\"([A-Za-z0-9_-]+)\"\}$ ]]; then
    # The Python helper emits this canonical bounded form.  Parse it with a
    # shell regex so ordinary worker callbacks do not start two jq processes.
    hook_is_subagent=true
    parent_session_id="${BASH_REMATCH[1]}"
  elif [ "$hook_context_metadata" = '{"parent_thread_id":null}' ]; then
    # Preserve the prior worker classification for a valid thread-spawn record
    # whose parent is absent; downstream ownership checks still reject an
    # unusable parent id rather than treating it as a proof owner.
    hook_is_subagent=true
  elif printf '%s' "$hook_context_metadata" | jq -e 'type == "object" and has("parent_thread_id")' >/dev/null 2>&1; then
    # Keep the old fail-closed behavior for an unexpected but valid helper
    # representation; this branch is not used for the canonical output.
    hook_is_subagent=true
    parent_session_id="$(printf '%s' "$hook_context_metadata" | jq -r '.parent_thread_id // empty' 2>/dev/null || true)"
  fi
fi

has_any_active_eci_marker() {
  local probe_cwd probe_session direct_marker parent_marker parent_session_id marker
  local scan_unsafe=false
  probe_cwd="$(printf '%s' "$input" | jq -r 'if (.cwd? | type) == "string" then .cwd else "" end' 2>/dev/null || true)"
  probe_session="$(printf '%s' "$input" | jq -r 'if (.session_id? | type) == "string" then .session_id else "" end' 2>/dev/null || true)"
  [ -n "$probe_cwd" ] || probe_cwd="$PWD"

  # The typed current-session marker is authoritative.  Probe it before the
  # bounded unrelated-root scan so an overflow cannot fabricate activity or
  # hide a malformed current marker behind a generic scan result.
  if codex_valid_session_id "$probe_session"; then
    direct_marker="$(codex_proof_root)/$probe_session/eci_active"
    if [ -e "$direct_marker" ] || [ -L "$direct_marker" ]; then
      return 0
    fi
  fi

  # A worker callback may carry a different session id from its coordinator.
  # A valid parent marker is likewise an authoritative active owner.
  if [ "$hook_is_subagent" = true ]; then
    if codex_valid_session_id "$parent_session_id" &&
      [ "$parent_session_id" != "$probe_session" ]; then
      parent_marker="$(codex_proof_root)/$parent_session_id/eci_active"
      if [ -e "$parent_marker" ] || [ -L "$parent_marker" ]; then
        return 0
      fi
    fi
  fi

  # Overflow is only a bounded discovery limitation.  It is not proof of an
  # active owner for an otherwise unbound callback.  Unsafe proof-root state
  # remains fail-closed and is deliberately not filtered out.
  while IFS= read -r marker; do
    case "$marker" in
      "$codex_eci_marker_scan_overflow_token") continue ;;
      "$codex_eci_marker_scan_unsafe_token") scan_unsafe=true ;;
      *) [ -n "$marker" ] && return 0 ;;
    esac
  done < <(codex_eci_markers_for_cwd "$probe_cwd" strict "$probe_session" 2>/dev/null || true)
  [ "$scan_unsafe" = true ]
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

deny_ambiguous_markers() {
  local owner_count="${1:-0}" expected_cwd="${2:-}" expected_session="${3:-}" reason
  reason="$(eci_diagnostic_reason "ECI_MARKER_OWNERSHIP_AMBIGUOUS" "PreToolUse" "edit-routing" "owner_count=$owner_count,session=$expected_session,cwd=$expected_cwd,proof_root=$(codex_proof_root)" "bounded marker discovery found $owner_count validated active owners for this cwd while the scan also overflowed; ownership cannot be selected safely" "resolve marker ownership so exactly one validated owner remains, or complete stale ECI teardowns through the coordinator lifecycle route, then retry")"
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

is_subagent="$hook_is_subagent"

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
  # no owner are handled independently.  In particular, an ordinary callback
  # with no own marker must not be converted into ECI_MARKER_MISSING_CURRENT
  # merely because unrelated proof-root entries exhausted the scan budget.
  # The direct marker probes above already fail closed for a malformed current
  # marker, so an empty filtered set here means no current-session owner.
  if [ "$parent_marker_direct" = true ]; then
    active_markers=("$parent_marker")
  elif [ "${#active_markers[@]}" -gt 1 ]; then
    deny_ambiguous_markers "${#active_markers[@]}" "$canonical_edit_cwd" "$session_id"
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
