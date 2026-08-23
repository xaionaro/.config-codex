#!/usr/bin/env bash
# PreToolUse hook: validate Bash commands before execution.

set -euo pipefail

unset ECI_READ_ONLY_PIPELINE

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HOOK_DIR/lib/codex-proof-state.sh"
. "$HOOK_DIR/lib/codex-tmp.sh"
. "$HOOK_DIR/lib/eci-diagnostic.sh"
. "$HOOK_DIR/lib/eci-environment-command.sh"
. "$HOOK_DIR/lib/eci-cleanup-route.sh"
CODEX_COMMAND_PATH="${PATH:-}"
export CODEX_COMMAND_PATH
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${CODEX_COMMAND_PATH}"
export PATH
codex_init_tmp || true
codex_install_fail_open_trap validate-bash
export CODEX_TRUSTED_GIT="${codex_git_executable:-}"

resolve_trusted_system_executable() {
  local name="${1:-}" candidate
  case "$name" in
    sed)
      for candidate in /usr/bin/sed /bin/sed /usr/local/bin/sed; do
        if [ -x "$candidate" ] &&
          [ "$(realpath -e -- "$candidate" 2>/dev/null || true)" = "$candidate" ]; then
          printf '%s\n' "$candidate"
          return 0
        fi
      done
      ;;
    git)
      if [ -n "$CODEX_TRUSTED_GIT" ] &&
        [ "$(realpath -e -- "$CODEX_TRUSTED_GIT" 2>/dev/null || true)" = "$CODEX_TRUSTED_GIT" ]; then
        printf '%s\n' "$CODEX_TRUSTED_GIT"
        return 0
      fi
      ;;
  esac
  return 1
}

CODEX_TRUSTED_SED="$(resolve_trusted_system_executable sed || true)"
CODEX_TRUSTED_GIT="$(resolve_trusted_system_executable git || true)"
export CODEX_TRUSTED_SED CODEX_TRUSTED_GIT

trusted_executable_on_path() {
  local name="${1:-}" expected path_entry candidate
  case "$name" in
    sed) expected="$CODEX_TRUSTED_SED" ;;
    git) expected="$CODEX_TRUSTED_GIT" ;;
    *) return 1 ;;
  esac
  [ -n "$expected" ] || return 1
  local -a path_entries=()
  IFS=: read -r -a path_entries <<<"${CODEX_COMMAND_PATH:-}"
  for path_entry in "${path_entries[@]}"; do
    [[ "$path_entry" = /* ]] || return 1
    candidate="$path_entry/$name"
    [ -x "$candidate" ] || continue
    [ "$(realpath -e -- "$candidate" 2>/dev/null || true)" = "$expected" ]
    return $?
  done
  return 1
}

finalize_command_gate_denial() {
  local source="$1" denial="$2"
  local role="${plan_role:-coordinator}" marker="${plan_marker_state:-inactive}"
  case "${CODEX_HOOK_IS_SUBAGENT:-false}:${CODEX_ROLE:-}:${hook_is_subagent:-false}" in
    true:*:*|*:subagent:*|*:worker:*|*:*:true) role=worker ;;
  esac
  if declare -p syntax_eci_markers >/dev/null 2>&1 && [ "${#syntax_eci_markers[@]}" -gt 0 ]; then
    marker=active
  fi
  if printf '%s\n' "$denial" | "$HOOK_DIR/../bin/eci-command-gate-mode" \
    finalize codex "$role" "$marker" "$source"; then
    return 0
  fi
  printf '%s\n' "$denial"
}

deny() {
  local reason="${1:-unspecified Bash validation denial}"
  if [[ "$reason" != \[ECI_* ]]; then
    local subject
    subject="tool=Bash,command=$(eci_command_identity_subject "${command:-}"),session=$(eci_diagnostic_value "${session_id:-<missing>}"),cwd=$(eci_diagnostic_value "${cwd:-<missing>}")"
    reason="$(eci_diagnostic_reason "$(eci_diagnostic_code_for_reason "$reason")" "PreToolUse" "bash-validation" "$subject" "$reason" "correct the reported command or route acceptance-sensitive work through the main/orchestrator, then retry")"
  fi
  local denial
  denial="$(jq -n --arg reason "$reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }')"
  finalize_command_gate_denial legacy "$denial"
  exit 0
}

deny_marker_boundary() {
  local marker="$1" expected_cwd="$2" expected_session="$3" code
  local detail remediation
  code="$(codex_eci_marker_failure_code "$marker" "$expected_cwd" "$expected_session")"
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
  deny "$(eci_diagnostic_reason "$code" "PreToolUse" "acceptance-boundary" "$marker" "$detail" "$remediation")"
}

deny_eci() {
  local code="$1" operation="$2" detail="$3" remediation="$4"
  local subject identity role="${plan_role:-coordinator}" marker="${plan_marker_state:-inactive}"
  case "${CODEX_HOOK_IS_SUBAGENT:-false}:${CODEX_ROLE:-}:${hook_is_subagent:-false}" in
    true:*:*|*:subagent:*|*:worker:*|*:*:true) role=worker ;;
  esac
  if declare -p syntax_eci_markers >/dev/null 2>&1 && [ "${#syntax_eci_markers[@]}" -gt 0 ]; then
    marker=active
  fi
  identity="$(eci_command_identity_subject "${command:-}")"
  [[ "$detail" == *"rejected command="* ]] || detail="$detail; rejected command=$identity"
  subject="provider=codex,role=$role,marker=$marker,command=$identity,session=$(eci_diagnostic_value "${session_id:-<missing>}"),cwd=$(eci_diagnostic_value "${cwd:-<missing>}"),repo=$(eci_diagnostic_value "${cwd:-$PWD}")"
  deny "$(eci_diagnostic_reason "$code" "PreToolUse" "$operation" "$subject" "$detail" "$remediation")"
}

active_eci_markers_for_cwd() {
  local probe_cwd="${1:-}" probe_session="${2:-}" marker parent_session
  local direct_marker="" parent_marker=""
  [ -n "$probe_cwd" ] || return 0
  # The direct current/parent marker is authoritative. Probe it before the
  # bounded unrelated-root scan so an overflow cannot hide active ownership
  # or turn a valid inactive callback into a generic scan denial. Existing
  # direct markers are emitted even when malformed; downstream binding checks
  # must preserve the concrete fail-closed diagnostic.
  if ! codex_proof_root_is_safe; then
    printf '%s\n' "$codex_eci_marker_scan_unsafe_token"
    return 0
  fi
  if codex_valid_session_id "$probe_session"; then
    direct_marker="$(codex_proof_root)/$probe_session/eci_active"
    if [ -e "$direct_marker" ] || [ -L "$direct_marker" ]; then
      printf '%s\n' "$direct_marker"
    fi
  fi
  if [ "${hook_is_subagent:-false}" = true ]; then
    parent_session="${CODEX_HOOK_PARENT_SESSION_ID:-}"
    if codex_valid_session_id "$parent_session" && [ "$parent_session" != "$probe_session" ]; then
      parent_marker="$(codex_proof_root)/$parent_session/eci_active"
      if [ -e "$parent_marker" ] || [ -L "$parent_marker" ]; then
        printf '%s\n' "$parent_marker"
      fi
    fi
  fi
  # Keep validated owners and unsafe proof-root state, but filter the bounded
  # scan's overflow sentinel. Overflow alone says only that unrelated entries
  # exceeded the finite scan budget; it is not an active owner.
  while IFS= read -r marker; do
    [ "$marker" = "$codex_eci_marker_scan_overflow_token" ] && continue
    [ -n "$direct_marker" ] && [ "$marker" = "$direct_marker" ] && continue
    [ -n "$parent_marker" ] && [ "$marker" = "$parent_marker" ] && continue
    [ -n "$marker" ] && printf '%s\n' "$marker"
  done < <(codex_eci_markers_for_cwd "$probe_cwd" strict "$probe_session" 2>/dev/null || true)
}

input=$(cat)
typed_input=false
if printf '%s' "$input" | jq -e '
  type == "object" and
  (.session_id | type) == "string" and (.session_id | length > 0) and
  (.cwd | type) == "string" and (.cwd | length > 0) and
  (.tool_input | type) == "object" and
  (.tool_input.command | type) == "string"
' >/dev/null 2>&1; then
  typed_input=true
fi

session_id=$(printf '%s' "$input" | jq -r 'if (.session_id? | type) == "string" then .session_id else "" end' 2>/dev/null || true)
cwd=$(printf '%s' "$input" | jq -r 'if (.cwd? | type) == "string" then .cwd else "" end' 2>/dev/null || true)
command=$(printf '%s' "$input" | jq -r 'if (.tool_input?.command? | type) == "string" then .tool_input.command else "" end' 2>/dev/null || true)

# Authenticate explicit worker context before malformed-input handling. The
# bounded transcript parser runs only for a typed payload that supplies a
# transcript path; ordinary planner callbacks do not need transcript metadata.
hook_is_subagent=false
case "${CODEX_HOOK_IS_SUBAGENT:-false}:${CODEX_ROLE:-}" in
  true:*|*:subagent|*:worker)
    hook_is_subagent=true
    ;;
  *)
    ;;
esac
CODEX_HOOK_PARENT_SESSION_ID=""
CODEX_HOOK_CONTEXT_METADATA=""

if [ "$typed_input" != true ]; then
  malformed_cwd="$cwd"
  [ -n "$malformed_cwd" ] || malformed_cwd="$PWD"
  mapfile -t malformed_markers < <(active_eci_markers_for_cwd "$malformed_cwd" "$session_id")
  if [ "${#malformed_markers[@]}" -gt 0 ]; then
    deny_eci "ECI_HOOK_IDENTITY_MALFORMED" "hook-identity" "[ECI_HOOK_IDENTITY_MALFORMED] ECI acceptance boundary denied malformed hook identity: session_id, cwd, tool_input.command, and command identity must be typed strings while an active marker exists." "provide typed session_id, cwd, tool_input.command, and command identity fields, then retry"
  fi
  exit 0
fi

transcript_path="$(printf '%s' "$input" | jq -r 'if (.transcript_path? | type) == "string" then .transcript_path else "" end' 2>/dev/null || true)"
if [ -n "$transcript_path" ] &&
  CODEX_HOOK_CONTEXT_METADATA="$(codex_hook_thread_spawn_metadata "$input" 2>/dev/null)" &&
  printf '%s' "$CODEX_HOOK_CONTEXT_METADATA" | jq -e 'type == "object" and has("parent_thread_id")' >/dev/null 2>&1; then
  hook_is_subagent=true
  CODEX_HOOK_PARENT_SESSION_ID="$(printf '%s' "$CODEX_HOOK_CONTEXT_METADATA" | jq -r '.parent_thread_id // empty' 2>/dev/null || true)"
fi
export CODEX_HOOK_PARENT_SESSION_ID
export CODEX_HOOK_IS_SUBAGENT="$hook_is_subagent"

# Lifecycle parsers use the hook-declared cwd when resolving relative
# invocations.  This is only coordinator identity metadata; it is not a
# command execution or filesystem recovery path.
export CODEX_VALIDATE_CWD="$cwd"
export CODEX_VALIDATE_SESSION_ID="$session_id"

canonical_approved_repo_roots() {
  local configured_codex configured_kimi allowed normalized
  configured_codex="${CODEX_HOME:-${HOME:-}/.codex}"
  configured_kimi="${KIMI_CODE_HOME:-${HOME:-}/.kimi-code}"
  for allowed in "$configured_codex" "$configured_kimi" "${CODEX_VALIDATE_CWD:-$PWD}"; do
    [[ "$allowed" = /* ]] || continue
    [ -d "$allowed" ] && [ ! -L "$allowed" ] || continue
    normalized="$(realpath -m -- "$allowed" 2>/dev/null || true)"
    [ -n "$normalized" ] && [ "$normalized" = "$allowed" ] || continue
    case "$normalized" in *$'\n'*|*$'\r'*) continue ;; esac
    printf '%s\n' "$normalized"
  done
}

mapfile -t CODEX_APPROVED_REPO_ROOTS < <(canonical_approved_repo_roots)
CODEX_APPROVED_REPO_ROOT_1="${CODEX_APPROVED_REPO_ROOTS[0]:-}"
CODEX_APPROVED_REPO_ROOT_2="${CODEX_APPROVED_REPO_ROOTS[1]:-}"
CODEX_APPROVED_REPO_ROOT_3="${CODEX_APPROVED_REPO_ROOTS[2]:-}"
export CODEX_APPROVED_REPO_ROOT_1 CODEX_APPROVED_REPO_ROOT_2 CODEX_APPROVED_REPO_ROOT_3
CODEX_GIT_STATUS_CONTEXT_SAFE=true
for git_context_name in ${!GIT_@}; do
  case "$git_context_name" in
    GIT_PAGER|GIT_PAGER_IN_USE) ;;
    *) CODEX_GIT_STATUS_CONTEXT_SAFE=false; break ;;
  esac
done
export CODEX_GIT_STATUS_CONTEXT_SAFE

CODEX_PROOF_ROOT_CANONICAL="$(codex_proof_root 2>/dev/null || true)"
CODEX_PROOF_ROOT_CONFIGURED="$(codex_configured_proof_root 2>/dev/null || true)"
CODEX_PROOF_ROOT_STABLE_ALIAS="${HOME:-}/.cache/codex-proof"
CODEX_CONFIGURED_HOME="${CODEX_HOME:-${HOME:-}/.codex}"
export CODEX_CONFIGURED_HOME

proof_root_spelling_is_stable() {
  local path="${1:-}"
  case "$path" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$path" in
    *"/../"*|*"/./"*|*"//"*|"/.."|*/..|"/."|*/.) return 1 ;;
  esac
  return 0
}

canonical_high_level_log_path() {
  local root="$CODEX_PROOF_ROOT_CANONICAL" session="${1:-}" path
  codex_proof_root_is_safe || return 1
  [ -d "$root" ] && [ ! -L "$root" ] || return 1
  [[ "$session" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || return 1
  path="$root/$session/high_level_log.md"
  [ -d "$root/$session" ] && [ ! -L "$root/$session" ] || return 1
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  [ "$(realpath -m -- "$path" 2>/dev/null || true)" = "$path" ] || return 1
  printf '%s\n' "$path"
}

CODEX_HIGH_LEVEL_LOG_PATH="$(canonical_high_level_log_path "$session_id" || true)"

stable_high_level_log_alias_path() {
  local root="$CODEX_PROOF_ROOT_CANONICAL" canonical_path="$CODEX_HIGH_LEVEL_LOG_PATH"
  local session="${1:-}" alias_root alias_path
  [ -n "$canonical_path" ] || return 1
  for alias_root in "$CODEX_PROOF_ROOT_CONFIGURED" "$CODEX_PROOF_ROOT_STABLE_ALIAS"; do
    [ -n "$alias_root" ] && [ "$alias_root" != "$root" ] || continue
    proof_root_spelling_is_stable "$alias_root" || continue
    [ -d "$alias_root" ] && [ ! -L "$alias_root" ] || continue
    [ "$(realpath -m -- "$alias_root" 2>/dev/null || true)" = "$root" ] || continue
    alias_path="$alias_root/$session/high_level_log.md"
    [ -d "$alias_root/$session" ] && [ ! -L "$alias_root/$session" ] || continue
    [ -f "$alias_path" ] && [ ! -L "$alias_path" ] || continue
    [ "$(realpath -m -- "$alias_path" 2>/dev/null || true)" = "$canonical_path" ] || continue
    printf '%s\n' "$alias_path"
    return 0
  done
  return 1
}

CODEX_HIGH_LEVEL_LOG_PATH_ALIAS="$(stable_high_level_log_alias_path "$session_id" || true)"
export CODEX_PROOF_ROOT_CANONICAL CODEX_PROOF_ROOT_CONFIGURED CODEX_PROOF_ROOT_STABLE_ALIAS
export CODEX_HIGH_LEVEL_LOG_PATH CODEX_HIGH_LEVEL_LOG_PATH_ALIAS

high_level_log_path_allowed() {
  local path="${1:-}"
  [ "$path" = "$CODEX_HIGH_LEVEL_LOG_PATH" ] ||
    { [ -n "$CODEX_HIGH_LEVEL_LOG_PATH_ALIAS" ] && [ "$path" = "$CODEX_HIGH_LEVEL_LOG_PATH_ALIAS" ]; } || return 1
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  [ "$(realpath -m -- "$path" 2>/dev/null || true)" = "$CODEX_HIGH_LEVEL_LOG_PATH" ]
}

read_only_sed_candidate() {
  local -a words=()
  local script log
  read -r -a words <<<"${1:-}"
  [ "${#words[@]}" -eq 4 ] || return 1
  [ "${words[0]}" = sed ] && trusted_executable_on_path sed || return 1
  [ "${words[1]}" = -n ] || [ "${words[1]}" = --quiet ] || return 1
  script="${words[2]}"
  case "$script" in
    \'*\'|\"*\") script="${script:1:${#script}-2}" ;;
  esac
  [[ "$script" =~ ^[1-9][0-9]*(,[1-9][0-9]*)?p$ ]] || return 1
  log="${words[3]}"
  case "$log" in
    \'*\'|\"*\") log="${log:1:${#log}-2}" ;;
  esac
  high_level_log_path_allowed "$log"
}

read_only_git_c_status_candidate() {
  local -a words=()
  local repo approved_repo="" token saw_limit=false saw_option=false verb_index=1
  [ "${CODEX_GIT_STATUS_CONTEXT_SAFE:-false}" = true ] && trusted_executable_on_path git || return 1
  read -r -a words <<<"${1:-}"
  [ "${#words[@]}" -ge 4 ] || return 1
  [ "${words[0]}" = git ] && [ "${words[1]}" = -C ] || return 1
  while [ "$verb_index" -lt "${#words[@]}" ] && [ "${words[$verb_index]}" = -C ]; do
    [ "$((verb_index + 1))" -lt "${#words[@]}" ] || return 1
    repo="${words[$((verb_index + 1))]}"
    case "$repo" in
      \'*\'|\"*\") repo="${repo:1:${#repo}-2}" ;;
    esac
    approved_repo=""
    for approved_repo in "$CODEX_APPROVED_REPO_ROOT_1" "$CODEX_APPROVED_REPO_ROOT_2" "$CODEX_APPROVED_REPO_ROOT_3"; do
      [ -n "$approved_repo" ] && [ "$repo" = "$approved_repo" ] && break
    done
    [ -n "$approved_repo" ] && [ "$repo" = "$approved_repo" ] || return 1
    [ "$repo" != "-"* ] && [ -d "$repo" ] && [ ! -L "$repo" ] || return 1
    [ "$(realpath -m -- "$repo" 2>/dev/null || true)" = "$repo" ] || return 1
    verb_index=$((verb_index + 2))
  done
  [ "$verb_index" -lt "${#words[@]}" ] || return 1
  case "${words[$verb_index]}" in
    status)
      for token in "${words[@]:$((verb_index + 1))}"; do
        case "$token" in --short|--porcelain) ;; *) return 1 ;; esac
      done
      return 0
      ;;
    log)
      for token in "${words[@]:$((verb_index + 1))}"; do
        case "$token" in
          -[1-9]|-1[0-6]|--max-count=[1-9]|--max-count=1[0-6]) saw_limit=true ;;
          --oneline) saw_option=true ;;
          *) return 1 ;;
        esac
      done
      [ "$saw_limit" = true ]
      ;;
    diff)
      [ "${#words[@]}" -gt "$((verb_index + 1))" ] || return 1
      for token in "${words[@]:$((verb_index + 1))}"; do
        case "$token" in --check|--stat|--name-only|--name-status) saw_option=true ;; *) return 1 ;; esac
      done
      [ "$saw_option" = true ]
      ;;
    show)
      [ "${#words[@]}" -gt "$((verb_index + 1))" ] || return 1
      for token in "${words[@]:$((verb_index + 1))}"; do
        case "$token" in --stat|--oneline|--no-patch) saw_option=true ;; *) return 1 ;; esac
      done
      [ "$saw_option" = true ]
      ;;
    submodule)
      [ "${#words[@]}" -eq "$((verb_index + 2))" ] && [ "${words[$((verb_index + 1))]}" = status ]
      ;;
    *) return 1 ;;
  esac
}

# Shell syntax boundary.  Unsafe shell expansion/operators are never accepted
# as a literal ECI tool command.  Safe single-quoted literals and the bounded
# coordinator inspection/script routes remain handled by their existing
# reviewed grammars.
mapfile -t syntax_eci_markers < <(active_eci_markers_for_cwd "$cwd" "$session_id")
ECI_ENVIRONMENT_BOUNDARY_CHECKED=false
ECI_ENVIRONMENT_COMMAND_STATE=""
ECI_ENVIRONMENT_COMMAND_CODE=""
ECI_ENVIRONMENT_COMMAND_SEGMENT=""
ECI_ENVIRONMENT_COMMAND_ARGV_INDEX=""
ECI_ENVIRONMENT_COMMAND_REASON=""

# Strict marker discovery returns explicit sentinels when the proof root is
# unsafe or its bounded scan cannot establish ownership.  These are active
# control-state failures, not an inactive callback; surface the exact state
# before the planner or hot-path allow can accidentally hide it.
for marker_scan_result in "${syntax_eci_markers[@]}"; do
  case "$marker_scan_result" in
    "$codex_eci_marker_scan_unsafe_token")
      deny_eci "ECI_MARKER_UNSAFE_PATH" "marker-discovery" \
        "ECI marker discovery denied an unsafe proof-root path: path=$CODEX_PROOF_ROOT_CONFIGURED; predicate=proof-root-safety; reason=the configured proof root is not a canonical non-symlink directory" \
        "use a canonical non-symlink proof root and retry the coordinator callback"
      ;;
    "$codex_eci_marker_scan_overflow_token")
      deny_eci "ECI_MARKER_OWNERSHIP_AMBIGUOUS" "marker-discovery" \
        "ECI marker discovery denied an overfull proof-root scan: path=$CODEX_PROOF_ROOT_CONFIGURED; predicate=bounded-marker-scan; reason=marker ownership could not be established within the bounded scan" \
        "reduce the proof-root entries to the bounded marker budget, then retry"
      ;;
  esac
done

# Parse and classify every finite literal command plan once before the legacy
# single-command recognizers.  The classifier admits ordinary argv without an
# executable allowlist and defers only visibly protected capabilities to the
# established operation-specific gates below.
plan_role=coordinator
case "${CODEX_HOOK_IS_SUBAGENT:-false}:${CODEX_ROLE:-}" in
  true:*|*:subagent|*:worker) plan_role=worker ;;
  *) ;;
esac
plan_marker_state=inactive
[ "${#syntax_eci_markers[@]}" -eq 0 ] || plan_marker_state=active
command_plan_binary="$HOOK_DIR/lib/eci-command-plan-go/eci-command-plan"
[ -x "$command_plan_binary" ] || deny_eci \
  "ECI_PLAN_BINARY_UNAVAILABLE" "plan-segment" \
  "compiled command-plan classifier is unavailable at path=$command_plan_binary" \
  "restore the provider-owned hard-linked command-plan binary and retry"
if plan_output="$(
  jq -cn \
    --arg provider codex \
    --arg role "$plan_role" \
    --arg cwd "$cwd" \
    --arg marker "$plan_marker_state" \
    --arg active_session "$session_id" \
    --arg command "$command" \
    --arg approved_root_1 "$CODEX_APPROVED_REPO_ROOT_1" \
    --arg approved_root_2 "$CODEX_APPROVED_REPO_ROOT_2" \
    --arg approved_root_3 "$CODEX_APPROVED_REPO_ROOT_3" \
    --args \
    '{provider:$provider,role:$role,cwd:$cwd,marker:$marker,active_session:$active_session,command:$command,active_markers:$ARGS.positional,approved_roots:[$approved_root_1,$approved_root_2,$approved_root_3]|map(select(length > 0))}' \
    "${syntax_eci_markers[@]}" |
    "$command_plan_binary" 2>/dev/null
)"; then
  plan_status=0
else
  plan_status=$?
fi

eci_cleanup_command_shape() {
  case "${1:-}" in
    mv|mv\ *|rm|rm\ *) return 0 ;;
    *) return 1 ;;
  esac
}

validate_active_marker_binding() {
  [ "${#syntax_eci_markers[@]}" -gt 0 ] || return 0
  local marker
  for marker in "${syntax_eci_markers[@]}"; do
    if ! codex_eci_marker_path_owner_is_valid "$marker"; then
      deny_marker_boundary "$marker" "$(codex_canonical_cwd "$cwd")" "$session_id"
    fi
  done
  [ "${#syntax_eci_markers[@]}" -le 1 ] ||
    deny_eci "ECI_MARKER_OWNERSHIP_AMBIGUOUS" "marker-discovery" \
      "ECI marker ownership denied an active callback with multiple validated owners: path=$CODEX_PROOF_ROOT_CONFIGURED; predicate=duplicate-active-owner; reason=the callback cannot safely select one ECI session marker" \
      "resolve marker ownership so exactly one validated marker remains, then retry"
}

worker_nonliteral_operator_detail() {
  python3 - "$1" <<'PY'
import shlex
import sys
try:
    lexer = shlex.shlex(sys.argv[1], posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    tokens = list(lexer)
except ValueError:
    raise SystemExit(1)
segment = 1
for token in tokens:
    if token == ";":
        segment += 1
        continue
    # A finite semicolon batch is an explicitly supported worker shape.  All
    # other shell punctuation is an operator boundary that requires literal
    # argv calls to be split before submission.
    if token != ";" and token and all(char in "|&;()<>" for char in token):
        print("operator/token=%s; segment=%d; path=n/a" % (token, segment))
        raise SystemExit(0)
raise SystemExit(1)
PY
}

# A pure pipe is a bounded read-only candidate only when the active worker
# envelope contains no other shell operator.  Keep this lexical gate generic;
# the provider classifier below establishes the capabilities of each segment.
worker_pure_pipeline_shape() {
  [ "${plan_role:-coordinator}" = worker ] || return 1
  [ "${plan_marker_state:-inactive}" = active ] || return 1
  case "$1" in
    *'|'*) ;;
    *) return 1 ;;
  esac
  python3 - "$1" <<'PY'
import re
import shlex
import sys

text = sys.argv[1]
if not text or len(text) > 16384 or any(mark in text for mark in ("\n", "\r", "\x00")):
    raise SystemExit(1)
try:
    lexer = shlex.shlex(text, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    tokens = list(lexer)
except ValueError:
    raise SystemExit(1)
operators = {";", "&", "&&", "||", "(", ")", ">", ">>", ">|", "<", "<<", "<<<", "<&", ">&"}
if (not tokens or tokens.count("|") not in range(1, 8)
        or any(token in operators for token in tokens)
        or len(tokens) > 128 or any(len(token) > 4096 for token in tokens)):
    raise SystemExit(1)
parts, current = [], []
for token in tokens:
    if token == "|":
        if not current:
            raise SystemExit(1)
        parts.append(current)
        current = []
    else:
        current.append(token)
if not current:
    raise SystemExit(1)
parts.append(current)
assignment = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
if any(assignment.match(part[0]) or len(part) > 128 for part in parts):
    raise SystemExit(1)
raise SystemExit(0)
PY
}

deny_worker_nonliteral() {
  [ "${plan_role:-coordinator}" = worker ] || return 1
  [ "${plan_marker_state:-inactive}" = active ] || return 1
  local detail
  detail="$(worker_nonliteral_operator_detail "$command" 2>/dev/null || true)"
  [ -n "$detail" ] || return 1
  deny_eci "ECI_COMMAND_NONLITERAL_DENIED" "direct-argv" \
    "ECI worker command envelope denied ${detail}; reason=the callback contains an unsupported shell operator/token and more than one direct argv vector" \
    "split at the reported operator/token and submit each finite direct argv vector as a separate tool call"
}

# A coordinator batch made entirely of visible shell-script operands belongs
# to the manifest-backed script route. Keep this shape check independent of
# filenames so the generic planner cannot fast-path an unreviewed segment,
# while ordinary coordinator compounds and worker operator boundaries retain
# their existing handling.
coordinator_script_batch_shape() {
  [ "${plan_role:-coordinator}" != worker ] || return 1
  case "${1:-}" in
    *'&&'*) ;;
    *) return 1 ;;
  esac
  python3 - "$1" <<'PY'
import shlex
import sys

command = sys.argv[1]
if any(mark in command for mark in ("\n", "\r", "$", "`")):
    raise SystemExit(1)
try:
    lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    tokens = list(lexer)
except ValueError:
    raise SystemExit(1)
if "&&" not in tokens:
    raise SystemExit(1)
unsafe = {";", "&", "||", "|", "(", ")", ">", ">>", "<", "<<", "<<<", ">|", ">&", "<&"}
if any(token in unsafe for token in tokens):
    raise SystemExit(1)
chunks, current = [], []
for token in tokens:
    if token == "&&":
        if not current:
            raise SystemExit(1)
        chunks.append(current)
        current = []
    else:
        current.append(token)
if not current:
    raise SystemExit(1)
chunks.append(current)
if len(chunks) < 2 or len(chunks) > 16:
    raise SystemExit(1)
for segment in chunks:
    if (len(segment) not in {2, 3} or segment[0] not in {"bash", "sh"} or
            (len(segment) == 3 and segment[1] != "-n")):
        raise SystemExit(1)
    script = segment[-1]
    if not script or script.startswith("-") or any(mark in script for mark in ("$", "`", "..")):
        raise SystemExit(1)
raise SystemExit(0)
PY
}

# These are conservative lexical prefilters for deferred legacy routes.  The
# route parser remains authoritative; a false positive only spends the route's
# existing validation cost, while a false negative must never skip a protected
# capability.  The Go planner's capability field is the parsed gate-mode bit.
deferred_route_gate_mode_shape() {
  [ "${plan_status:-}" -eq 3 ] || return 1
  [[ "${plan_output:-}" == *'"gate-mode"'* ]]
}

deferred_route_lifecycle_shape() {
  case "${1:-}" in
    *eci-active*|*eci-review-gate*|*eci-stage*|*stop-gate.sh*|*ate-orchestrator-gate.sh*) return 0 ;;
    *) return 1 ;;
  esac
}

deferred_route_script_shape() {
  case "${1:-}" in
    bash|bash\ *|sh|sh\ *|./hooks/*.sh|./hooks/tests/*.sh|/*/*.sh|*/install-pre-commit-go-mod.sh|*/eci-review-gate.sh) return 0 ;;
    *) return 1 ;;
  esac
}

deferred_route_environment_shape() {
  case "${1:-}" in
    env\ [A-Za-z_]*=*\ *|env\ -i\ *|env\ -u\ [A-Za-z_]*\ *|env\ --\ *) return 1 ;;
    env|env\ *|printenv|printenv\ *|*\ env\ *|*\ printenv\ *) return 0 ;;
    *) return 1 ;;
  esac
}

deferred_route_git_shape() {
  case "${1:-}" in
    git|git\ *|*/git|*/git\ *|*\ git\ *|*\/git\ *) return 0 ;;
    *) return 1 ;;
  esac
}

literal_git_mutation_shape() {
  case "${1:-}" in
    git\ *\ commit*|git\ *\ reset*|git\ *\ add*|git\ *\ rm*|git\ *\ mv*|git\ *\ restore*|git\ *\ worktree*|*/git\ *\ commit*|*/git\ *\ reset*) return 0 ;;
    *) return 1 ;;
  esac
}

deferred_route_proof_path_shape() {
  local value="${1:-}" root
  for root in \
    "${CODEX_PROOF_ROOT_CANONICAL:-}" "${CODEX_PROOF_ROOT_CONFIGURED:-}" \
    "${CODEX_PROOF_ROOT_STABLE_ALIAS:-}" "${KIMI_PROOF_ROOT_CANONICAL:-}" \
    "${KIMI_PROOF_ROOT_CONFIGURED:-}" "${KIMI_PROOF_ROOT_STABLE_ALIAS:-}"; do
    [ -n "$root" ] || continue
    case "$value" in
      "$root"|"$root"/*|*" $root"|*" $root"/*) return 0 ;;
    esac
  done
  return 1
}

deferred_route_hook_repair_shape() {
  case "${1:-}" in
    chmod\ 755\ *|*install-pre-commit-go-mod.sh*|*pre-commit-go-mod.sh*) return 0 ;;
    *) return 1 ;;
  esac
}

# A worker plan with status=0 is authoritative only for a plain, finite
# argv.  Keep every capability that has an ownership or syntax boundary on
# the deferred route; this lexical gate is deliberately conservative and
# does not identify commands by an allowlist.
deferred_worker_operator_shape() {
  [ "${plan_role:-coordinator}" = worker ] || return 1
  case "${1:-}" in
    *'&&'*|*'||'*|*'|'*|*'>'*|*'<'*|*'`'*|*'$('*|*'${'*|*$'\n'*|*$'\r'*) return 0 ;;
    *) return 1 ;;
  esac
}

deferred_worker_wrapper_shape() {
  if [ "${plan_role:-coordinator}" != worker ]; then
    case "${1:-}" in
      env\ [A-Za-z_]*=*\ *|env\ -i\ *|env\ -u\ [A-Za-z_]*\ *|env\ --\ *) return 1 ;;
    esac
  fi
  case "${1:-}" in
    env|env\ *|printenv|printenv\ *|command|command\ *|builtin|builtin\ *|exec|exec\ *|\
    bash|bash\ *|sh|sh\ *|dash|dash\ *|zsh|zsh\ *|ksh|ksh\ *|ash|ash\ *|fish|fish\ *|\
    */bash|*/bash\ *|*/sh|*/sh\ *|*/dash|*/dash\ *|*/zsh|*/zsh\ *|\
    python|python\ *|python2|python2\ *|python3|python3\ *|perl|perl\ *|ruby|ruby\ *|\
    node|node\ *|php|php\ *|timeout|timeout\ *|time|time\ *|nice|nice\ *|nohup|nohup\ *|\
    setsid|setsid\ *|sudo|sudo\ *|doas|doas\ *|systemd-run|systemd-run\ *|\
    xargs|xargs\ *|find|find\ *|*' -c '*|*' --command '*|*' --eval '*|*' --execute '*) return 0 ;;
    *) return 1 ;;
  esac
}

deferred_worker_control_shape() {
  case "${1:-}" in
    *eci_active*|*goal_state*|*eci_wait*|*eci-required-critics*|*eci-critic-identities*|\
    *eci-acceptance-*|*baseline_head*|*proof.md*|*instructions.md*|*stop_timestamps*|\
    *stop_loop_state*|*disengage.md*|*user-closed.md*|*project-understanding.md*|\
    *high_level_log*|*latest-status-report*|*eci_user_owned_wait*|\
    *eci-teardown-complete*|*eci-baseline-binding*|*eci-commit-admitted*) return 0 ;;
    *) return 1 ;;
  esac
}

worker_plain_plan_shape() {
  [ "${plan_role:-coordinator}" = worker ] || return 1
  [ "${plan_marker_state:-inactive}" = active ] || return 1
  [ "${plan_status:-1}" -eq 0 ] || return 1
  eci_cleanup_command_shape "$1" && return 1
  coordinator_script_batch_shape "$1" && return 1
  deferred_worker_operator_shape "$1" && return 1
  deferred_worker_wrapper_shape "$1" && return 1
  deferred_worker_control_shape "$1" && return 1
  deferred_route_lifecycle_shape "$1" && return 1
  deferred_route_script_shape "$1" && return 1
  deferred_route_environment_shape "$1" && return 1
  deferred_route_git_shape "$1" && return 1
  deferred_route_proof_path_shape "$1" && return 1
  deferred_route_hook_repair_shape "$1" && return 1
  [[ "$1" =~ ^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*= ]] && return 1
  # The compiled planner has already performed the exact path-ownership,
  # live-control, lifecycle, proof, Git, environment, wrapper, and operator
  # checks for this finite single-segment argv.  Ordinary path operands,
  # including arbitrary-basename helper hardlinks, may therefore use the
  # worker fast path; the shape guards above retain protected deferrals.
  return 0
}

# Keep the syntax boundary ahead of every fast path and coordinator cleanup
# route.  The planner may admit the first line of a multiline cleanup payload,
# but cleanup routing must never turn that partial parse into an approval.
if [ "${#syntax_eci_markers[@]}" -gt 0 ] &&
  { [ "$plan_status" -ne 0 ] || eci_cleanup_command_shape "$command"; }; then
  case "$command" in
    *$'\n'*|*$'\r'*)
      deny_eci "ECI_COMMAND_SYNTAX_DENIED" "acceptance-boundary" "ECI command syntax denied literal newlines in a shell command; multiline or eval payloads must be split into separately reviewed calls." "split multiline or eval payloads into separately reviewed literal calls"
      ;;
  esac
fi

worker_fast_path_candidate=false
worker_read_only_pipeline_candidate=false
case "$command" in
  *'|'*)
    if worker_pure_pipeline_shape "$command"; then
      worker_read_only_pipeline_candidate=true
    fi
    ;;
esac
case "$plan_status" in
  0)
    # Active worker allows must pass the worker instruction/control ownership
    # predicate before the fast exit.  Keep the candidate bit so the existing
    # bounded worker-control route can run without duplicating its classifier.
    if worker_plain_plan_shape "$command"; then
      worker_fast_path_candidate=true
    fi
    # Non-worker allows still pass the ownership predicates below.  The
    # fast-path exit is deliberately after worker instruction/control checks.
    # Cleanup-shaped mutations must also reach the coordinator cleanup route:
    # an allowed planner result cannot bypass destination/path ownership
    # checks (for example, an existing quarantine destination).
    if [ "$worker_fast_path_candidate" != true ] &&
      { [ "$plan_marker_state" != active ] ||
      { [ "$plan_role" != worker ] &&
        ! eci_cleanup_command_shape "$command" &&
        ! coordinator_script_batch_shape "$command" &&
        ! deferred_route_lifecycle_shape "$command" &&
        ! deferred_route_script_shape "$command" &&
        ! deferred_route_environment_shape "$command" &&
        ! deferred_route_git_shape "$command" &&
        ! deferred_route_proof_path_shape "$command" &&
        ! deferred_route_hook_repair_shape "$command" &&
        ! deferred_worker_operator_shape "$command" &&
        ! deferred_worker_wrapper_shape "$command" &&
        ! deferred_worker_control_shape "$command" &&
        ! literal_git_mutation_shape "$command"; }; }; then
      validate_active_marker_binding
      exit 0
    fi
    ;;
  3)
    # Protected deferrals must continue into the legacy operation gates even
    # when this callback has no active ECI marker.  Inactive Git approval
    # callbacks still require the user-owned one-time artifact; ordinary
    # finite allows retain the fast exit above.
    ;;
  2)
    if [ "$worker_read_only_pipeline_candidate" != true ] &&
      [[ "$plan_output" == *ECI_COMMAND_NOT_ALLOWLISTED* ||
      "$plan_output" == *ECI_WORKER_COMMAND_NOT_ALLOWLISTED* ]]; then
      if deny_worker_nonliteral; then
        :
      fi
    fi
    [ -n "$plan_output" ] || deny_eci "ECI_PLAN_INTERNAL_DENIED" "plan-segment" \
      "command-plan classifier returned an empty denial" \
      "retry one finite literal argv and report the missing classifier diagnostic"
    finalize_command_gate_denial parser "$plan_output"
    exit 0
    ;;
  *)
    deny_eci "ECI_PLAN_INTERNAL_DENIED" "plan-segment" \
      "command-plan classifier failed with status=$plan_status" \
      "correct the classifier invocation or command encoding before retrying"
    ;;
esac

# The compiled planner has already admitted the finite cleanup shape.  Bind
# the active marker and run the shared live capability parser before legacy
# route scanners; a valid cleanup callback must not pay for unrelated probes.
if [ "${#syntax_eci_markers[@]}" -gt 0 ] &&
  [ "$hook_is_subagent" != true ] &&
  [ "$plan_status" -eq 0 ] &&
  eci_cleanup_command_shape "$command"; then
  validate_active_marker_binding
  if eci_shared_cleanup_route "$command"; then
    exit 0
  fi
  deny_eci "ECI_COMMAND_NOT_ALLOWLISTED" "coordinator-cleanup-route" \
    "ECI coordinator cleanup route denied the reported command: ${ECI_SHARED_CLEANUP_ROUTE_DETAIL:-command=$(eci_command_identity_subject "$command")}" \
    "correct the reported cleanup token/path/shape and use only the bounded generated-artifact cleanup route"
fi

# A literal line break is a command boundary even when it appears inside a
# quoted shell payload.  Reject it before either the legacy read-only scanner
# or the Python classifier can accidentally treat only the first line as the
# command identity.  The same guard covers nested sh -c/eval payloads below.
if [ "${#syntax_eci_markers[@]}" -gt 0 ] &&
  { [ "$plan_status" -ne 0 ] || eci_cleanup_command_shape "$command"; }; then
  case "$command" in
    *$'\n'*|*$'\r'*)
      deny_eci "ECI_COMMAND_SYNTAX_DENIED" "acceptance-boundary" "ECI command syntax denied literal newlines in a shell command; multiline or eval payloads must be split into separately reviewed calls." "split multiline or eval payloads into separately reviewed literal calls"
      ;;
  esac
fi

# `printenv NAME...` has no child executable or path operand.  Once strict
# marker discovery and the role-neutral environment grammar accept the one
# direct argv, no later ownership recognizer can find a protected operation.
# Return here instead of running the full multi-language ownership scanner.
if [ "${#syntax_eci_markers[@]}" -gt 0 ]; then
  enforce_environment_command_boundary
  if [ "$ECI_ENVIRONMENT_COMMAND_STATE" = ALLOW ] &&
     [ "$ECI_ENVIRONMENT_COMMAND_CODE" = printenv ] &&
     [ "$ECI_ENVIRONMENT_COMMAND_REASON" = direct-registered-query ]; then
    [ "${#syntax_eci_markers[@]}" -le 1 ] ||
      deny_eci "ECI_MARKER_OWNERSHIP_AMBIGUOUS" "environment-boundary" \
        "environment query denied because strict marker discovery resolved multiple active owners" \
        "resolve marker ownership so exactly one validated owner remains, then retry the direct query"
    exit 0
  fi
fi

command_has_unsafe_shell_syntax() {
  python3 - "$1" <<'PY'
import sys

value = sys.argv[1]
single = False
double = False
escaped = False
index = 0
while index < len(value):
    char = value[index]
    if single:
        if char == "'":
            single = False
        index += 1
        continue
    if escaped:
        escaped = False
        index += 1
        continue
    if char == "\\":
        escaped = True
        index += 1
        continue
    if char == "'":
        single = True
        index += 1
        continue
    if char == '"':
        double = not double
        index += 1
        continue
    if char == '`' or (char == '<' and index + 1 < len(value) and value[index + 1] == '(') or (char == '>' and index + 1 < len(value) and value[index + 1] == '('):
        raise SystemExit(0)
    if char in '{}' and not double:
        raise SystemExit(0)
    if char == '$':
        next_char = value[index + 1] if index + 1 < len(value) else ''
        if next_char == '(' or next_char == '{' or next_char in '?*!@#$-_' or next_char.isdigit() or next_char.isalpha():
            raise SystemExit(0)
    index += 1
raise SystemExit(1)
PY
}

unsafe_shell_syntax_detail() {
  python3 - "$1" <<'PY'
import sys

value = sys.argv[1]
single = False
double = False
escaped = False
index = 0

def reject(detail):
    print(detail)
    raise SystemExit(0)

while index < len(value):
    char = value[index]
    if single:
        if char == "'":
            single = False
        index += 1
        continue
    if escaped:
        escaped = False
        index += 1
        continue
    if char == "\\":
        escaped = True
        index += 1
        continue
    if char == "'":
        single = True
        index += 1
        continue
    if char == '"':
        double = not double
        index += 1
        continue
    if char == chr(96):
        reject("syntax=backtick-substitution")
    if char in "<>" and index + 1 < len(value) and value[index + 1] == "(":
        reject("syntax=process-substitution")
    if char in "{}" and not double:
        reject("syntax=brace-expansion")
    if char == "$":
        next_char = value[index + 1] if index + 1 < len(value) else ""
        if next_char == "(":
            reject("syntax=command-substitution")
        if next_char == "{":
            reject("syntax=parameter-expansion")
        if next_char in "?*!@#$-_" or next_char.isdigit() or next_char.isalpha():
            reject("syntax=shell-expansion")
    index += 1
raise SystemExit(1)
PY
}

rejected_command_detail() {
  python3 - "$1" <<'PY'
import shlex
import sys

value = sys.argv[1]
try:
    lexer = shlex.shlex(value, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    tokens = list(lexer)
except ValueError:
    print("syntax=unbalanced quoting")
    raise SystemExit(0)
for token in tokens:
    if token in {"&", "&&", "||", ">", ">>", "<", "<<", "<<<", ">|", ">&", "<&", "(", ")"}:
        print("operator/token=" + token)
        raise SystemExit(0)
parts, current = [], []
for token in tokens:
    if token in {";", "|"}:
        if current:
            parts.append(" ".join(current))
        current = []
    else:
        current.append(token)
if current:
    parts.append(" ".join(current))
print("segment=" + (parts[0] if parts else "<empty>"))
PY
}

detect_git_push() {
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$command" <<'PY'
import os, shlex, sys

cmd = sys.argv[1]
OPS = {';', '&', '&&', '|', '||', '(', ')'}
GIT_KV = {'-c', '--config-env', '--exec-path', '--git-dir',
          '--namespace', '--super-prefix', '--work-tree'}
GIT_KV_EQ = tuple(a + '=' for a in GIT_KV if a.startswith('--'))

def tokenize(s):
    try:
        lex = shlex.shlex(s, posix=True, punctuation_chars=True)
        lex.whitespace_split = True
        return list(lex), True
    except ValueError:
        return [], False

def segments(toks):
    out, start = [], 0
    for i, t in enumerate(toks + [';']):
        if t in OPS:
            if start < i:
                out.append(toks[start:i])
            start = i + 1
    return out

def is_assign(t):
    n, s, _ = t.partition('=')
    return bool(s) and bool(n) and n.replace('_', 'A').isalnum() and not n[0].isdigit()

def cmd_start(seg):
    i = 0
    while i < len(seg) and is_assign(seg[i]):
        i += 1
    while i < len(seg):
        n = os.path.basename(seg[i])
        if n in ('command', 'builtin', 'exec'):
            i += 1
            continue
        if n == 'env':
            i += 1
            while i < len(seg):
                t = seg[i]
                if is_assign(t):
                    i += 1; continue
                if t in ('-i', '-0') or t.startswith('-u'):
                    i += 1; continue
                if t in ('-C', '-S') and i + 1 < len(seg):
                    i += 2; continue
                if t.startswith('-'):
                    i += 1; continue
                break
            continue
        if n in ('sudo', 'doas'):
            i += 1
            while i < len(seg) and seg[i].startswith('-'):
                i += 1
            continue
        return i
    return i

def check_seg(seg, depth=0):
    i = cmd_start(seg)
    if i >= len(seg):
        return False
    n = os.path.basename(seg[i])
    if n in ('bash', 'sh', 'zsh', 'dash'):
        j = i + 1
        while j < len(seg):
            if seg[j] == '-c' and j + 1 < len(seg):
                return check_command(seg[j + 1], depth + 1)
            j += 1
        return False
    if n != 'git':
        return False
    j = i + 1
    while j < len(seg):
        t = seg[j]
        if t == '-C' and j + 1 < len(seg):
            j += 2; continue
        if t.startswith('-C') and len(t) > 2:
            j += 1; continue
        if t in GIT_KV and j + 1 < len(seg):
            j += 2; continue
        if any(t.startswith(p) for p in GIT_KV_EQ):
            j += 1; continue
        if t.startswith('-'):
            j += 1; continue
        return t == 'push'
    return False

def check_command(s, depth=0):
    if depth > 3:
        return 'git push' in s
    toks, ok = tokenize(s)
    if not ok:
        return 'git push' in s
    for seg in segments(toks):
        if check_seg(seg, depth):
            return True
    return False

if check_command(cmd):
    print('1')
PY
  else
    case "$command" in
      *"git push"*) printf '1\n' ;;
    esac
  fi
}

command_invokes_eci_control_mutation() {
  python3 - "$1" <<'PY'
import os
import hashlib
import re
import shlex
import sys

text = sys.argv[1]
root = os.path.realpath(os.path.abspath(
    os.environ.get("CODEX_PROOF_ROOT") or
    os.path.join(os.environ.get("HOME", ""), ".cache", "codex-proof")
))
separators = {";", "&", "&&", "|", "||", "(", ")"}
output_redirects = {">", ">>", ">|", ">&"}
mutators = {
    "cat", "chmod", "chown", "cp", "dd", "echo", "install", "ln",
    "mv", "perl", "printf", "python", "python2", "python3", "rm",
    "ruby", "sed", "tee", "touch", "truncate", "awk", "node", "unlink",
    "shred", "srm", "rmdir", "tar", "unzip", "rsync", "cpio", "zip", "7z",
}
approval_basenames = {
    ".git-reset-approved-once",
    ".git-worktree-approved-once",
    ".git-commit-approved-once",
}
wrappers = {
    "bash", "dash", "eval", "sh", "zsh", "command", "builtin", "exec",
    "nohup", "setsid", "sudo", "doas", "timeout", "nice", "systemd-run",
    "prlimit", "time",
}

def tokenize(value):
    try:
        lexer = shlex.shlex(value, posix=True, punctuation_chars=True)
        lexer.whitespace_split = True
        return list(lexer)
    except ValueError:
        return None

def assignment(value):
    return bool(re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", value))

def under_root(value):
    if not value or value.startswith("-"):
        return False
    # Compare the lexical path before resolving its final component.  A
    # symlink inside the proof root may resolve outside it, but the command is
    # still attempting to mutate a control-path name and must be denied.
    expanded = os.path.expanduser(value)
    if os.path.isabs(expanded):
        candidate = os.path.normpath(os.path.abspath(expanded))
    else:
        candidate = os.path.normpath(os.path.abspath(os.path.join(
            os.environ.get("CODEX_VALIDATE_CWD", os.getcwd()), expanded)))
    canonical_candidate = os.path.realpath(candidate)
    return (
        candidate == root or candidate.startswith(root + os.sep) or
        canonical_candidate == root or canonical_candidate.startswith(root + os.sep)
    )

def is_approval_path(value):
    if not value or value.startswith("-"):
        return False
    expanded = os.path.normpath(os.path.expanduser(value))
    resolved = os.path.realpath(expanded)
    return (
        os.path.basename(expanded) in approval_basenames
        or os.path.basename(resolved) in approval_basenames
    )

def is_control_hardlink_alias(value):
    """Recognize an outside-root hardlink to canonical ECI control state."""
    if not value or value.startswith("-"):
        return False
    expanded = os.path.expanduser(value)
    candidate = expanded if os.path.isabs(expanded) else os.path.abspath(os.path.join(
        os.environ.get("CODEX_VALIDATE_CWD", os.getcwd()), expanded
    ))
    try:
        target = os.stat(candidate, follow_symlinks=False)
    except OSError:
        return False
    if not os.path.isfile(candidate) or os.path.islink(candidate):
        return False
    control_names = {
        "eci_active", "goal_state", "eci_wait", "eci_user_owned_wait.md",
        "eci-required-critics.json", "eci-critic-identities.ledger",
        "eci-acceptance-anchor", "eci-acceptance-transaction",
        "eci-teardown-complete", "eci-baseline-binding", "baseline_head",
        "eci-commit-admitted", "eci-user-closed.ledger", "proof.md",
        "instructions.md", "stop_timestamps", "stop_loop_state",
        "disengage.md", "user-closed.md", "project-understanding.md",
        "high_level_log.md", "latest-status-report.md", "high_level_log.anchor",
    }
    session_id = os.environ.get("CODEX_VALIDATE_SESSION_ID", "")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", session_id):
        return False
    control_roots = []
    for raw in (
        root,
        os.environ.get("CODEX_PROOF_ROOT_CANONICAL", ""),
        os.environ.get("CODEX_PROOF_ROOT_CONFIGURED", ""),
        os.environ.get("CODEX_PROOF_ROOT_STABLE_ALIAS", ""),
    ):
        if not raw or not os.path.isabs(raw) or os.path.normpath(raw) != raw:
            continue
        resolved_root = os.path.realpath(raw)
        if (not os.path.isdir(resolved_root) or os.path.islink(resolved_root)
                or resolved_root in control_roots):
            continue
        control_roots.append(resolved_root)
    for control_root in control_roots:
        session_dir = os.path.join(control_root, session_id)
        for name in control_names:
            control_path = os.path.join(session_dir, name)
            try:
                state = os.stat(control_path, follow_symlinks=False)
            except OSError:
                continue
            if (os.path.isfile(control_path) and not os.path.islink(control_path)
                    and state.st_dev == target.st_dev and state.st_ino == target.st_ino):
                return True
    return False

def segment_tokens(tokens):
    result, current = [], []
    for token in tokens + [";"]:
        if token in separators:
            if current:
                result.append(current)
            current = []
        else:
            current.append(token)
    return result

def command_index(segment):
    index = 0
    while index < len(segment) and assignment(segment[index]):
        index += 1
    return index

def inspect(segment, depth=0):
    if depth > 5:
        return False
    index = command_index(segment)
    if index >= len(segment):
        return False
    name = os.path.basename(segment[index])
    # Archive/copy formats expose helper, destination, and execution options
    # too broad for a bounded worker proof.  Route the whole family through
    # the explicit control-boundary denial before option parsing.
    if name in {"tar", "unzip", "rsync", "cpio", "zip", "7z"}:
        return True
    if name in wrappers:
        if name == "eval":
            # `eval` is arbitrary shell indirection.  Even a payload that
            # currently looks harmless can source a copied lifecycle binary
            # or mutate state through a later expansion.
            return True
        if name in {"bash", "dash", "sh", "zsh"}:
            for option_index, option in enumerate(segment[index + 1:], index + 1):
                if option == "-c" or (option.startswith("-") and "c" in option[1:]):
                    if option_index + 1 >= len(segment):
                        return False
                    nested = tokenize(segment[option_index + 1])
                    return nested is not None and any(inspect(part, depth + 1) for part in segment_tokens(nested))
            return False
        index += 1
        while index < len(segment):
            token = segment[index]
            if token in {"-i", "--ignore-environment", "--foreground", "--preserve-status", "--scope", "--wait", "--quiet", "-n"}:
                index += 1
                continue
            if token in {"-k", "--kill-after", "-s", "--signal", "-u", "--user", "-C", "--chdir", "--unit", "--property", "--setenv"} and index + 1 < len(segment):
                index += 2
                continue
            if token.startswith("-"):
                index += 1
                continue
            break
        if name == "timeout" and index < len(segment):
            index += 1
        return inspect(segment[index:], depth + 1)
    if name == "env":
        index += 1
        while index < len(segment):
            token = segment[index]
            if token in {"-S", "--split-string"}:
                if index + 1 >= len(segment):
                    return False
                nested = tokenize(segment[index + 1])
                return nested is not None and any(inspect(part, depth + 1) for part in segment_tokens(nested))
            if assignment(token) or token in {"-i", "--ignore-environment"}:
                index += 1
                continue
            if token in {"-u", "--unset", "-C", "--chdir"} and index + 1 < len(segment):
                index += 2
                continue
            if token.startswith("-"):
                index += 1
                continue
            break
        return inspect(segment[index:], depth + 1)
    if name == "xargs":
        index += 1
        while index < len(segment):
            token = segment[index]
            if token in {"-I", "-n", "-P", "-a", "-d", "-E", "-L"} and index + 1 < len(segment):
                index += 2
                continue
            if token.startswith("-"):
                index += 1
                continue
            break
        return inspect(segment[index:], depth + 1)
    if name in {"command", "builtin", "exec", "nohup", "setsid", "sudo", "doas"}:
        return inspect(segment[index + 1:], depth + 1)
    if name in {"timeout", "systemd-run", "nice"}:
        index += 1
        while index < len(segment) and segment[index].startswith("-"):
            index += 2 if segment[index] in {"-k", "--kill-after", "-s", "--signal", "-u", "--user", "--unit"} else 1
        if name == "timeout" and index < len(segment):
            index += 1
        return inspect(segment[index:], depth + 1)
    if name == "find":
        if "-delete" in segment[index + 1:] and any(under_root(token) for token in segment[index + 1:]):
            return True
        for option_index, option in enumerate(segment[index + 1:], index + 1):
            if option not in {"-exec", "-execdir", "-ok", "-okdir"}:
                continue
            end = option_index + 1
            while end < len(segment) and segment[end] not in {";", "+"}:
                end += 1
            nested = segment[option_index + 1:end]
            if inspect(nested, depth + 1):
                return True
        return False

    # Reading a proof document is not a control-state mutation.  Keep the
    # writer checks below for sed -i/--in-place and output redirections, but
    # do not classify ordinary cat/sed/rg/grep reads of instructions,
    # ledgers, or status logs as worker-owned mutations.  The bounded
    # read-only route performs the path/command validation separately.
    if name in {"cat", "rg", "grep"}:
        return False
    if name == "sed" and not any(
        token in {"-i", "--in-place"} or token.startswith(("-i", "--in-place=") )
        for token in segment[index + 1:]
    ):
        return False

    # Path-bearing writer options do not appear as standalone paths.  Keep
    # these forms fail-closed for worker commands so a proof-state target
    # cannot be hidden in dd's if=/of= syntax or a copy/install target option.
    option_paths = []
    for option_index, option in enumerate(segment[index + 1:], index + 1):
        if option.startswith(("if=", "of=")):
            option_paths.append(option.split("=", 1)[1])
            continue
        if name == "tar":
            if option.startswith("-C") and len(option) > 2:
                option_paths.append(option[2:])
                continue
            if option.startswith("--directory="):
                option_paths.append(option.split("=", 1)[1])
                continue
            if option == "--directory" and option_index + 1 < len(segment):
                option_paths.append(segment[option_index + 1])
                continue
        if name == "unzip":
            if option.startswith("-d") and len(option) > 2:
                option_paths.append(option[2:])
                continue
            if option == "-d" and option_index + 1 < len(segment):
                option_paths.append(segment[option_index + 1])
                continue
        if name == "rsync":
            rsync_path_option = False
            for rsync_option in ("--backup-dir", "--compare-dest", "--copy-dest", "--link-dest"):
                if option.startswith(rsync_option + "="):
                    option_paths.append(option.split("=", 1)[1])
                    rsync_path_option = True
                    break
                if option == rsync_option and option_index + 1 < len(segment):
                    option_paths.append(segment[option_index + 1])
                    rsync_path_option = True
                    break
            if rsync_path_option:
                continue
        if option.startswith(("--target-directory=", "--target=") ):
            option_paths.append(option.split("=", 1)[1])
            continue
        # cp/mv/ln/install accept compact option clusters such as -itPATH or
        # -it PATH.  Find the t flag inside the cluster before generic '-'
        # handling can hide a proof-root target.
        if option.startswith("-") and not option.startswith("--") and "t" in option[1:]:
            t_index = option.find("t", 1)
            if t_index + 1 < len(option):
                option_paths.append(option[t_index + 1:])
            elif option_index + 1 < len(segment):
                option_paths.append(segment[option_index + 1])
            continue
        if option in {"-t", "--target-directory", "--target", "--directory"} and option_index + 1 < len(segment):
            option_paths.append(segment[option_index + 1])
    if name in {"dd", "cp", "mv", "ln", "install", "tar", "unzip", "rsync", "cpio", "zip", "7z"} and any(under_root(path) for path in option_paths):
        return True

    has_control_path = any(
        under_root(token) or is_approval_path(token) or is_control_hardlink_alias(token)
        for token in segment[index + 1:]
    )
    has_output_to_control = any(
        token in output_redirects and (
            under_root(segment[next_index + 1]) or
            is_approval_path(segment[next_index + 1]) or
            is_control_hardlink_alias(segment[next_index + 1])
        )
        for next_index, token in enumerate(segment[:-1])
    )
    return (name in mutators and has_control_path) or has_output_to_control

try:
    parsed = tokenize(text)
    found = parsed is not None and any(inspect(part) for part in segment_tokens(parsed))
except (TypeError, ValueError):
    found = False
sys.exit(0 if found else 1)
PY
}

# Subagents may edit ordinary repository files, but an interpreter or shell
# launcher can hide control-file mutation and lifecycle calls from the
# bounded token checks above.  Keep this recognizer deliberately narrow: allow
# syntax-only shell checks and the explicit hook-test entry points, while
# denying shell options, arbitrary scripts, and direct review-gate execution
# in the active subagent context.  This is parser hygiene, not an attempt at
# cryptographic identity.
command_invokes_subagent_unsafe_launcher() {
  python3 - "$1" <<'PY'
import os
import hashlib
import re
import shlex
import sys
import hashlib
import shutil
import stat

text = sys.argv[1]
separators = {";", "&", "&&", "|", "||", "(", ")"}
shells = {"bash", "dash", "sh", "zsh"}
interpreters = {
    "awk", "node", "perl", "php", "python", "python2", "python3",
    "ruby", "tclsh", "wish",
}
wrappers = {
    "command", "builtin", "exec", "nohup", "setsid", "sudo", "doas", "env",
    "timeout", "systemd-run", "time", "nice", "prlimit", "chronic",
    "xargs", "find",
}

# Archive/copy tools have a large and evolving set of path, helper, and
# execution options.  In the worker boundary they are not a bounded proof of
# ordinary inspection, so fail closed for the whole family rather than
# chasing individual option spellings.
archive_writers = {"tar", "unzip", "rsync", "cpio", "zip", "7z"}
configured_home = os.path.realpath(os.path.abspath(
    os.environ.get("CODEX_HOME") or os.path.join(os.environ.get("HOME", ""), ".codex")
))
configured_eci = os.path.realpath(os.path.normpath(os.path.join(configured_home, "bin", "eci-active")))

def digest(path):
    try:
        info = os.stat(path)
        if not stat.S_ISREG(info.st_mode) or info.st_size > 8 * 1024 * 1024:
            return None
        value = hashlib.sha256()
        with open(path, "rb") as stream:
            for chunk in iter(lambda: stream.read(65536), b""):
                value.update(chunk)
        return value.hexdigest()
    except OSError:
        return None

configured_eci_digest = digest(configured_eci)

def lifecycle_executable(token):
    expanded = os.path.expanduser(token)
    if os.path.isabs(expanded) or "/" in expanded:
        candidates = [expanded]
    else:
        resolved = shutil.which(expanded)
        candidates = [resolved] if resolved else []
    for candidate in candidates:
        if os.path.realpath(os.path.abspath(candidate)) == configured_eci:
            return True
        if configured_eci_digest is not None and digest(candidate) == configured_eci_digest:
            return True
    return False
unsafe_shell_options = {
    "-e", "-x", "-i", "-l", "-O", "--debugger", "--login", "--noprofile",
    "--norc", "--posix", "--rcfile", "--restricted", "--verbose",
}

def tokenize(value):
    try:
        lexer = shlex.shlex(value, posix=True, punctuation_chars=True)
        lexer.whitespace_split = True
        return list(lexer)
    except ValueError:
        return None

def split(tokens):
    result, current = [], []
    for token in tokens + [";"]:
        if token in separators:
            if current:
                result.append(current)
            current = []
        else:
            current.append(token)
    return result

def assignment(token):
    return bool(re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", token))

def worker_approved_path(value):
    if not value or value.startswith("-") or any(mark in value for mark in ("$", "`", "(", ")", "..")):
        return False
    if not os.path.isabs(value):
        value = os.path.abspath(os.path.join(os.environ.get("CODEX_VALIDATE_CWD", os.getcwd()), value))
    if os.path.normpath(value) != value:
        return False
    roots = {
        os.environ.get(name, "")
        for name in (
            "CODEX_APPROVED_REPO_ROOT_1", "CODEX_APPROVED_REPO_ROOT_2",
            "CODEX_APPROVED_REPO_ROOT_3", "CODEX_PROOF_ROOT_CANONICAL",
            "CODEX_PROOF_ROOT_CONFIGURED", "CODEX_PROOF_ROOT_STABLE_ALIAS",
            "CODEX_CONFIGURED_HOME", "CODEX_HOME",
        )
        if os.environ.get(name, "")
    }
    if not any(value == root or value.startswith(root + os.sep) for root in roots):
        return False
    stable_alias = os.environ.get("CODEX_PROOF_ROOT_STABLE_ALIAS", "")
    canonical_root = os.environ.get("CODEX_PROOF_ROOT_CANONICAL", "")
    stable_path = bool(
        stable_alias and canonical_root and
        (value == stable_alias or value.startswith(stable_alias + os.sep)) and
        os.path.realpath(value) == canonical_root + value[len(stable_alias):]
    )
    if os.path.realpath(value) != value and not stable_path:
        return False
    return os.path.exists(value)

def bounded_worker_find(segment, index):
    args = segment[index + 1:]
    if not args:
        return False
    arg_index = 1 if args[0] == "-P" else 0
    if arg_index >= len(args) or not worker_approved_path(args[arg_index]):
        return False
    arg_index += 1
    saw_filter = False
    while arg_index < len(args):
        token = args[arg_index]
        if token == "2" and arg_index + 2 < len(args) and args[arg_index + 1] == ">" and args[arg_index + 2] == "/dev/null":
            arg_index += 3
            continue
        if token == "-print":
            arg_index += 1
            continue
        if token in {"-type", "-name", "-maxdepth", "-mindepth"} and arg_index + 1 < len(args):
            if token == "-type" and args[arg_index + 1] not in {"f", "d", "l"}:
                return False
            if token in {"-maxdepth", "-mindepth"} and not re.fullmatch(r"[0-9]+", args[arg_index + 1]):
                return False
            saw_filter = saw_filter or token in {"-type", "-name"}
            arg_index += 2
            continue
        if token == "-o" and arg_index + 1 < len(args) and args[arg_index + 1] != "-o":
            arg_index += 1
            continue
        return False
    return saw_filter

def bounded_worker_literal(value):
    return (
        bool(value) and len(value) <= 512 and
        not any(mark in value for mark in ("$", "`", "\n", "\r"))
    )

def bounded_worker_gofmt(segment, index):
    args = segment[index + 1:]
    if len(args) < 2 or len(args) > 17 or args[0] not in {"-d", "-w"}:
        return False
    shell_tokens = separators | {">", ">>", ">|", ">>&", "<", "<<", "<<<", "<&"}
    if any(token in shell_tokens for token in args):
        return False
    paths = args[1:]
    return all(
        bounded_worker_literal(path) and
        not os.path.isabs(path) and
        path.endswith(".go") and
        worker_approved_path(path)
        for path in paths
    )

def known_test_script(path):
    if any(mark in path for mark in ("$", "`", "..")):
        return False
    normalized = path[2:] if path.startswith("./") else path
    if not normalized.startswith("hooks/tests/"):
        return False
    expected = {
        "run.sh": "09c23c2490a8c3a134a5c21de6aa8eec30eea67ba58548f2ed75189a37045380",
        "test-eci-fast-path.sh": "dc1233b4c496954d496c6645f4304aadb6e07b22fb1e1a6fc4f820d81811bd3a",
        "test-eci-post-compact-refresh.sh": "7735c9d4b5d71d1f57dffedbafae32ce818019c865ba7250520971010aca66cf",
        "test-eci-review-gate.sh": "6fdb8d8a0e8a4aab410f96d5030225a7d873605956d93ae3f0d26dad93be8a88",
        "test-session-snapshot-refresh.sh": "bd093a9a8a6e282e3a4d48b1905ebac59a370a273b0c416bec5defd5129d428d",
        "test-validate-bash-classifier.sh": "d4e488073a53300581510b5293404fea82640e346a15555a6fb2d45d7d397e5e",
        "test-validate-bash-git-approvals.sh": "62553126dffa4373880142dd802d5737da29a9535868f7e7b7568f0b920c8261",
        "test-policy-design-boundary.sh": "e084a05ad1ed7a001c6bbd7816a36ba5aad386d91fd27012329d1671d87a1de3",
        "test-eci-edit-control-paths.sh": "ba7e26be82c09748e57c4c79d092ab46420a40f116bcdff2e6988e00142ce2f7",
        "test-eci-diagnostic-specificity.sh": "fbb40f2b717834f3eaad96535a3c3ed52e576f25c2ce8b678d84b6add2ab4dc0",
        "test-eci-marker-scope.sh": "64300cd57c7feef8b1de358078541acba4f1844e9e789c153cae56acfc089875",
        "test-pretooluse-latency.sh": "7e8f73f23dafd6389103c97f599c558aa56a6b46ee5d8d82fc32df3ed4e7dcca",
        "test-pre-commit-go-mod.sh": "39256e08a8512ca00263dfb8b4a67593c512a3488c8ea16e684f68ffd6b095a4",
        "test-eci-command-syntax-gating.sh": "78fe91f5dfd1d92c051ab260eb62dd47c47a4bed0362179c3c53d007a43894d8",
        "test-go-mod-hook-parity.sh": "63ba8579491e894bfb2adfe6d84e1bd056c1d814c4c5c0e97c25e417c3cbb5cf",
        "test-stop-loop-guidance.sh": "f8fa9f1f036a8511a029d90e5466736b292dd089106a5fc735d4336d79d538d6",
        "test-stop-marker-validation.sh": "3483c29a26283369929f782c18e0c91bc332748730dbc6539a1a22033e39bd57",
    }
    name = normalized.rsplit("/", 1)[-1]
    expected_sha = expected.get(name)
    if expected_sha is None:
        return False
    absolute = os.path.join(os.getcwd(), normalized)
    return os.path.isfile(absolute) and not os.path.islink(absolute) and digest(absolute) == expected_sha

read_only_commands = {
    "[", "basename", "cat", "cmp", "cut", "date", "diff", "dirname",
    "du", "egrep", "fgrep", "file", "gitleaks", "gofmt", "grep", "head", "jq", "ls", "nl", "printenv",
    "od", "printf", "pwd", "readlink", "realpath", "rg", "sed", "sha256sum",
    "sort", "stat", "tail", "test", "tr", "true", "uniq", "wc", "which",
}
git_read_only = {"describe", "diff", "grep", "log", "ls-files", "rev-parse", "show", "status"}
git_branch_read_only = {"--show-current", "--list", "-l", "--verbose", "-v"}
git_remote_read_only = {"-v", "--verbose", "show", "get-url"}
redirections = {">", ">>", ">|", ">&", "<", "<<"}

SED_SCRIPT = re.compile(r"^[1-9][0-9]*(,[1-9][0-9]*)?p$")

TRUSTED_SED = os.path.realpath(os.environ.get("CODEX_TRUSTED_SED", ""))
TRUSTED_GIT = os.path.realpath(os.environ.get("CODEX_TRUSTED_GIT", ""))


def trusted_path_token(token, name, expected):
    if token != name or not expected:
        return False
    for entry in os.environ.get("CODEX_COMMAND_PATH", "").split(":"):
        if not entry.startswith("/"):
            return False
        candidate = os.path.join(entry, name)
        if not os.path.isfile(candidate) or not os.access(candidate, os.X_OK):
            continue
        return os.path.realpath(candidate) == expected
    return False


def trusted_sed_token(token):
    return trusted_path_token(token, "sed", TRUSTED_SED)


def trusted_git_token(token):
    return trusted_path_token(token, "git", TRUSTED_GIT)

def canonical_high_level_log(path):
    expected = os.environ.get("CODEX_HIGH_LEVEL_LOG_PATH", "")
    alias = os.environ.get("CODEX_HIGH_LEVEL_LOG_PATH_ALIAS", "")
    if not expected or path not in {expected, alias}:
        return False
    return (
        os.path.isfile(path) and
        not os.path.islink(path) and
        os.path.realpath(path) == expected
    )

def git_context_is_safe():
    return all(name in {"GIT_PAGER", "GIT_PAGER_IN_USE"}
               for name in os.environ if name.startswith("GIT_"))

def approved_inspection_path(path):
    if not os.path.isabs(path):
        if any(mark in path for mark in ("$", "`", "(", ")", "..")):
            return False
        path = os.path.abspath(os.path.join(
            os.environ.get("CODEX_VALIDATE_CWD", os.getcwd()), path
        ))
    values = [
        os.environ.get("CODEX_APPROVED_REPO_ROOT_1", ""),
        os.environ.get("CODEX_APPROVED_REPO_ROOT_2", ""),
        os.environ.get("CODEX_APPROVED_REPO_ROOT_3", ""),
        os.environ.get("CODEX_PROOF_ROOT", ""),
        os.environ.get("CODEX_PROOF_ROOT_CANONICAL", ""),
        os.environ.get("CODEX_PROOF_ROOT_CONFIGURED", ""),
        os.environ.get("CODEX_PROOF_ROOT_STABLE_ALIAS", ""),
        os.environ.get("CODEX_HOME", ""),
        os.environ.get("CODEX_CONFIGURED_HOME", ""),
    ]
    # A worker may inspect its own provider root, but the companion provider
    # root remains coordinator-owned even when it is exported through one of
    # the generic approved-repository slots.  Filter by canonical home rather
    # than by variable name so aliases cannot reopen the peer path.
    worker_home = os.path.realpath(
        os.environ.get("CODEX_HOME") or
        os.environ.get("CODEX_CONFIGURED_HOME") or ""
    ) if os.environ.get("CODEX_HOOK_IS_SUBAGENT") == "true" else ""
    peer_home = os.path.realpath(os.path.join(
        os.environ.get("HOME", ""), ".kimi-code"
    )) if worker_home else ""
    if worker_home and peer_home:
        values = [
            value for value in values
            if not (value and (
                os.path.realpath(value) == peer_home or
                os.path.realpath(value).startswith(peer_home + os.sep)
            ))
        ]
    if os.environ.get("CODEX_HOOK_IS_SUBAGENT") != "true":
        values.extend([
            os.environ.get("KIMI_PROOF_ROOT_CANONICAL", ""),
            os.environ.get("KIMI_PROOF_ROOT_CONFIGURED", ""),
            os.environ.get("KIMI_PROOF_ROOT_STABLE_ALIAS", ""),
            os.environ.get("KIMI_PROOF_ROOT", ""),
            os.environ.get("KIMI_CODE_HOME", ""),
        ])
    roots = {value for value in values if value and os.path.isabs(value) and os.path.realpath(value) == value}
    if os.environ.get("CODEX_HOOK_IS_SUBAGENT") != "true":
        for value in ("/bin", "/usr/bin", "/usr/local/bin"):
            if (os.path.isdir(value) and not os.path.islink(value)
                    and os.path.realpath(value) == value):
                roots.add(value)
    skills = os.path.join(os.environ.get("CODEX_CONFIGURED_HOME", os.environ.get("CODEX_HOME", "")), "skills")
    if skills and os.path.isdir(skills) and os.path.realpath(skills) == skills:
        roots.add(skills)
    if os.environ.get("CODEX_HOOK_IS_SUBAGENT") != "true":
        kimi_home = os.environ.get("KIMI_CODE_HOME", os.path.join(os.environ.get("HOME", ""), ".kimi-code"))
        kimi_skills = os.path.join(kimi_home, "skills")
        for cross_root in (kimi_home, kimi_skills):
            if cross_root and os.path.isdir(cross_root) and not os.path.islink(cross_root) and os.path.realpath(cross_root) == cross_root:
                roots.add(cross_root)
    if not path or not os.path.isabs(path) or os.path.normpath(path) != path:
        return False
    resolved = os.path.realpath(path)
    system_dirs = ("/bin", "/usr/bin", "/usr/local/bin", "/usr/lib/cargo/bin/coreutils")
    if os.environ.get("CODEX_HOOK_IS_SUBAGENT") != "true" and any(
            path == directory or path.startswith(directory + os.sep)
            for directory in system_dirs):
        return (
            os.path.isfile(resolved) and
            os.access(resolved, os.X_OK) and
            any(resolved == directory or resolved.startswith(directory + os.sep)
                for directory in system_dirs)
        )
    if resolved != path or not os.path.isfile(path) or os.path.islink(path):
        return False
    return any(path == root or path.startswith(root + os.sep) for root in roots)

def bounded_sed_read_only(segment, index):
    if index != 0 or segment[index] != "sed":
        return False
    if not trusted_sed_token(segment[index]):
        return False
    args = segment[index + 1:]
    return (
        len(args) == 3 and
        args[0] in {"-n", "--quiet"} and
        SED_SCRIPT.fullmatch(args[1]) is not None and
        (canonical_high_level_log(args[2]) or approved_inspection_path(args[2]))
    )

def bounded_git_c_status(segment, index):
    if index != 0 or not git_context_is_safe():
        return False
    if len(segment) != index + 5 or segment[index:index + 5] != ["git", "-C", segment[index + 2], "status", "--short"]:
        return False
    repo = segment[index + 2]
    approved_roots = {
        os.path.realpath(value)
        for value in (
            os.environ.get("CODEX_APPROVED_REPO_ROOT_1", ""),
            os.environ.get("CODEX_APPROVED_REPO_ROOT_2", ""),
            os.environ.get("CODEX_APPROVED_REPO_ROOT_3", ""),
        )
        if value
    }
    if not trusted_git_token(segment[index]):
        return False
    if not approved_roots or repo not in approved_roots or repo.startswith("-"):
        return False
    return (
        os.path.isdir(repo) and
        not os.path.islink(repo) and
        os.path.realpath(repo) == repo
    )

def safe_bounded_git_pathspec(value, allow_exclude_magic=False):
    """Accept a bounded literal Git pathspec without resolving its target."""
    if not value or len(value) > 4096 or value.startswith("-"):
        return False
    if any(ord(character) < 0x20 for character in value):
        return False
    if value.startswith(":("):
        suffix = value[len(":(exclude)"):]
        return (allow_exclude_magic and value.startswith(":(exclude)") and suffix and
                not any(mark in suffix for mark in ("$", "`", "\n", "\r", "*", "?", "[", "]", "(", ")")))
    if any(mark in value for mark in ("$", "`", "\n", "\r", "*", "?", "[", "]", "(", ")")):
        return False
    return True

def bounded_git_pathspecs(values, options, allow_exclude_magic=False):
    """Validate bounded Git options and literal pathspec operands."""
    paths = []
    explicit_delimiter = False
    for value in values:
        if value == "--":
            if explicit_delimiter:
                return False
            explicit_delimiter = True
            continue
        if not explicit_delimiter and value in options:
            continue
        if not explicit_delimiter and value.startswith("-"):
            return False
        if not safe_bounded_git_pathspec(value, allow_exclude_magic):
            return False
        paths.append(value)
        if len(paths) > 16:
            return False
    return True

def bounded_git_read_only(segment, index):
    if not trusted_git_token(segment[index]):
        return False
    if bounded_git_c_status(segment, index):
        return True
    args = segment[index + 1:]
    if args[:1] == ["-C"]:
        if len(args) < 3:
            return False
        repo = args[1]
        approved_roots = {
            os.path.realpath(value)
            for value in (
                os.environ.get("CODEX_APPROVED_REPO_ROOT_1", ""),
                os.environ.get("CODEX_APPROVED_REPO_ROOT_2", ""),
                os.environ.get("CODEX_APPROVED_REPO_ROOT_3", ""),
            )
            if value
        }
        if (not repo or repo.startswith("-") or repo not in approved_roots or
                not os.path.isdir(repo) or os.path.islink(repo) or os.path.realpath(repo) != repo):
            return False
        args = args[2:]
    if any(token in redirections or token in {"--textconv", "--ext-diff", "-o", "--output", "--to-file"}
           or token.startswith(("--output=", "--to-file=")) for token in args):
        return False
    if not args:
        return False
    if any(token in {"-C", "-c", "--config-env", "--git-dir", "--work-tree", "--exec-path", "--namespace"}
           or token.startswith(("-C", "--config-env=", "--git-dir=", "--work-tree=", "--exec-path=", "--namespace="))
           for token in args):
        return False
    subcommand = args[0]
    if subcommand == "diff":
        diff_options = {
            "--cached", "--check", "--name-only", "--name-status", "--stat",
            "--staged", "--submodule",
        }
        for value in args[1:]:
            if re.fullmatch(r"-U[0-9]{1,4}", value) and int(value[2:]) <= 1000:
                diff_options.add(value)
            if re.fullmatch(r"--unified=[0-9]{1,4}", value) and int(value.split("=", 1)[1]) <= 1000:
                diff_options.add(value)
        if not bounded_git_pathspecs(args[1:], diff_options):
            return False
    if subcommand in git_read_only:
        return True
    if subcommand == "submodule":
        return args[1:] == ["status"]
    if subcommand == "branch":
        commitish = re.compile(r"(?:[0-9A-Fa-f]{7,64}|HEAD(?:~[0-9]+|\^[0-9]+)?)")
        value_options = {"--contains", "--merged", "--no-merged", "--points-at"}
        branch_args = args[1:]
        index = 0
        while index < len(branch_args):
            token = branch_args[index]
            if token in value_options:
                if index + 1 >= len(branch_args) or commitish.fullmatch(branch_args[index + 1]) is None:
                    return False
                index += 2
                continue
            if any(token.startswith(option + "=") for option in value_options):
                option, value = token.split("=", 1)
                if commitish.fullmatch(value) is None:
                    return False
                index += 1
                continue
            if not token.startswith("-") or token not in git_branch_read_only | {"--all", "--remotes"}:
                return False
            index += 1
        return True
    if subcommand == "remote":
        return len(args) == 1 or args[1] in git_remote_read_only
    return False

def inspect(segment, depth=0):
    if depth > 6 or not segment:
        return depth > 6
    index = 0
    while index < len(segment) and assignment(segment[index]):
        index += 1
    # Do not let startup-sensitive assignments run before an allowlisted test
    # script.  The validator must see a clean execution context; otherwise a
    # BASH_ENV/ENV/PYTHONSTARTUP-style probe can execute before the script.
    if index > 0:
        return True
    if index >= len(segment):
        return False
    # Lifecycle ownership must not depend on the copied executable retaining
    # the canonical basename. A direct path to any executable/script is an
    # opaque worker launcher; inspecting its arguments cannot prove that it
    # will not mutate ECI state. Canonical shell/test routes are handled
    # below before this generic path check.
    program = segment[index]
    name = os.path.basename(segment[index])
    # `PATH` can expose a copied/renamed lifecycle binary.  Resolve the
    # actual executable (and its bounded digest) before the generic slash
    # check, so a bare `eci-stage wait` cannot evade the worker boundary.
    if lifecycle_executable(program) or name == "eci-active" or "/" in program:
        return True
    if name == "eci-review-gate.sh":
        return True
    if name == "eval":
        # Shell evaluation is arbitrary indirection even when its payload
        # happens not to contain an obvious control path.
        return True
    if name in archive_writers:
        return True
    if name in shells:
        args = segment[index + 1:]
        # -c/eval payloads and shell option combinations are intentionally not
        # admitted for subagents; control mutations can be hidden in them.
        for option_index, option in enumerate(args):
            if option in unsafe_shell_options or option.startswith("--noprofile=") or option.startswith("--rcfile="):
                return True
            if option == "-c" or (option.startswith("-") and not option.startswith("--") and "c" in option[1:]):
                return True
        if "-n" in args:
            non_options = [token for token in args if not token.startswith("-")]
            return not non_options or any(
                any(mark in token for mark in ("$", "`", "<(", ">("))
                for token in non_options
            )
        if len(args) == 1 and known_test_script(args[0]):
            return False
        # An unqualified script or an option-free interactive shell is not a
        # bounded worker/read-only route.
        return True
    if name in interpreters:
        return True
    if name == "gitleaks" and any(
        token == "-r" or token == "--report-path" or token.startswith("--report-path=")
        for token in segment[index + 1:]
    ):
        return True
    if name == "diff" and any(
        token in {"-o", "--output", "--to-file"} or token.startswith(("--output=", "--to-file="))
        for token in segment[index + 1:]
    ):
        return True
    if name == "sort" and any(
        token == "-o" or (token.startswith("-o") and len(token) > 2) or token.startswith("--output=")
        for token in segment[index + 1:]
    ):
        return True
    if name == "env":
        # A worker must not dump inherited environment state; the coordinator
        # path handles the bounded source form separately.
        return True
    if name == "printenv":
        safe_names = {
            "HOME", "PWD", "PATH", "CODEX_HOME", "KIMI_CODE_HOME",
            "SESSION_ID", "CODEX_ROLE", "CODEX_SESSION_ID", "KIMI_SESSION_ID",
            "CODEX_VALIDATE_CWD", "KIMI_VALIDATE_CWD",
            "CODEX_VALIDATE_SESSION_ID", "KIMI_VALIDATE_SESSION_ID",
            "CODEX_CONFIGURED_HOME", "KIMI_CONFIGURED_HOME",
            "CODEX_COMMAND_PATH", "KIMI_COMMAND_PATH",
            "CODEX_STOP_GATE_ROOT", "KIMI_STOP_GATE_ROOT", "TMPDIR",
            "CODEX_PROOF_ROOT", "KIMI_PROOF_ROOT",
            "CODEX_PROOF_ROOT_CANONICAL", "CODEX_PROOF_ROOT_CONFIGURED",
            "CODEX_PROOF_ROOT_STABLE_ALIAS", "KIMI_PROOF_ROOT_CANONICAL",
            "KIMI_PROOF_ROOT_CONFIGURED", "KIMI_PROOF_ROOT_STABLE_ALIAS",
            "CODEX_APPROVED_REPO_ROOT_1", "CODEX_APPROVED_REPO_ROOT_2",
            "CODEX_APPROVED_REPO_ROOT_3", "KIMI_APPROVED_REPO_ROOT_1",
            "KIMI_APPROVED_REPO_ROOT_2", "KIMI_APPROVED_REPO_ROOT_3",
            "CODEX_HIGH_LEVEL_LOG_PATH", "CODEX_HIGH_LEVEL_LOG_PATH_ALIAS",
            "KIMI_HIGH_LEVEL_LOG_PATH", "KIMI_HIGH_LEVEL_LOG_PATH_ALIAS",
        }
        return not (segment[index + 1:] and all(token in safe_names for token in segment[index + 1:]))
    if name == "find":
        return not bounded_worker_find(segment, index)
    if name == "gofmt":
        return not bounded_worker_gofmt(segment, index)
    if name == "sed":
        return not bounded_sed_read_only(segment, index)
    if name == "git":
        return not bounded_git_read_only(segment, index)
    if name in read_only_commands:
        return False
    if name in wrappers:
        if name == "env" and any(
            assignment(token) or token in {"-S", "--split-string"}
            for token in segment[index + 1:]
        ):
            return True
        if name == "find":
            if any(token in {"-exec", "-execdir", "-ok", "-okdir", "-delete"} for token in segment[index + 1:]):
                return True
        if name == "xargs":
            # xargs can launch arbitrary commands supplied by input; only a
            # nested explicit command is safe to inspect here.
            return True
        nested = segment[index + 1:]
        if name == "env":
            while nested and (assignment(nested[0]) or nested[0] in {"-i", "--ignore-environment", "-u", "--unset", "-C", "--chdir"}):
                if nested[0] in {"-u", "--unset", "-C", "--chdir"} and len(nested) > 1:
                    nested = nested[2:]
                else:
                    nested = nested[1:]
        if any(inspect(part, depth + 1) for part in split(nested)):
            return True
        # A generic launcher is not proof that the nested executable is a
        # bounded worker command.  Keep the subagent boundary fail-closed for
        # unknown wrapped scripts and startup contexts.
        return name != "find"
    if name in {"source", "."}:
        # Sourcing an arbitrary script executes code before bounded token
        # inspection.  Canonical lifecycle forms are handled by the separate
        # lifecycle recognizers; subagents may not source unknown paths.
        return True
    # Unknown bare commands, PATH/hash aliases, and exported shell helpers are
    # not bounded worker routes. Only the explicit read-only/test allowlist
    # above remains admissible.
    return True

parsed = tokenize(text)
unsafe = parsed is None or any(inspect(part) for part in split(parsed))
sys.exit(0 if unsafe else 1)
PY
}

command_invokes_subagent_explicit_launcher() {
  python3 - "$1" <<'PY'
import os
import re
import shlex
import sys
try:
    tokens = shlex.split(sys.argv[1], posix=True)
except ValueError:
    raise SystemExit(0)
if not tokens:
    raise SystemExit(1)
name = os.path.basename(tokens[0])
explicit = {
    "bash", "dash", "sh", "zsh", "awk", "node", "perl", "php", "python", "python2", "python3", "ruby", "tclsh", "wish",
    "command", "builtin", "exec", "nohup", "setsid", "sudo", "doas", "env", "timeout", "systemd-run", "time", "nice", "prlimit", "xargs",
    "source", ".", "eval", "eci-review-gate.sh",
}
if name == "find" and any(value in {"-exec", "-execdir", "-ok", "-okdir", "-delete"} for value in tokens[1:]):
    raise SystemExit(0)
raise SystemExit(0 if name in explicit else 1)
PY
}

command_invokes_subagent_coordinator_only() {
  python3 - "$1" <<'PY'
import shlex
import sys

try:
    tokens = shlex.split(sys.argv[1], posix=True)
except ValueError:
    raise SystemExit(1)
raise SystemExit(0 if tokens and tokens[0] == "mktemp" else 1)
PY
}

command_invokes_git_branch_remote_mutation() {
  python3 - "$1" <<'PY'
import os
import hashlib
import re
import shlex
import sys

text = sys.argv[1]
separators = {";", "&", "&&", "|", "||", "(", ")"}
branch_mutators = {"-d", "-D", "-m", "-M", "-c", "-C", "--delete", "--move", "--copy", "--edit-description", "--set-upstream-to", "--unset-upstream"}
remote_mutators = {"add", "remove", "rename", "set-url", "set-head", "prune", "update"}

def tokenize(value):
    try:
        lexer = shlex.shlex(value, posix=True, punctuation_chars=True)
        lexer.whitespace_split = True
        return list(lexer)
    except ValueError:
        return None

def split(tokens):
    result, current = [], []
    for token in tokens + [";"]:
        if token in separators:
            if current:
                result.append(current)
            current = []
        else:
            current.append(token)
    return result

def inspect(segment, depth=0):
    if depth > 5:
        return False
    index = 0
    while index < len(segment) and "=" in segment[index] and not segment[index].startswith("-"):
        index += 1
    if index >= len(segment):
        return False
    name = os.path.basename(segment[index])
    if name == "env":
        index += 1
        while index < len(segment):
            token = segment[index]
            if "=" in token and not token.startswith("-"):
                index += 1
                continue
            if token in {"-i", "--ignore-environment"}:
                index += 1
                continue
            if token in {"-u", "--unset", "-C", "--chdir", "-S", "--split-string"} and index + 1 < len(segment):
                index += 2
                continue
            if token.startswith("-"):
                index += 1
                continue
            break
        return inspect(segment[index:], depth + 1)
    if name in {"bash", "sh", "dash", "zsh"}:
        for option_index, option in enumerate(segment[index + 1:], index + 1):
            if option == "-c" or (option.startswith("-") and "c" in option[1:]):
                if option_index + 1 >= len(segment):
                    return False
                nested = tokenize(segment[option_index + 1])
                return nested is not None and any(inspect(part, depth + 1) for part in split(nested))
        return False
    if name in {"command", "builtin", "exec", "sudo", "doas", "nohup", "setsid"}:
        index += 1
        return inspect(segment[index:], depth + 1)
    if name in {"timeout", "systemd-run", "nice", "time", "prlimit", "chronic"}:
        index += 1
        value_options = {
            "-k", "--kill-after", "-s", "--signal", "-n", "--adjustment",
            "-p", "--property", "--unit", "--setenv", "--working-directory",
            "-C", "--chdir",
        }
        while index < len(segment) and segment[index].startswith("-"):
            if segment[index] == "--":
                index += 1
                break
            index += 2 if segment[index] in value_options else 1
        if name == "timeout" and index < len(segment):
            index += 1
        return inspect(segment[index:], depth + 1)
    if name != "git":
        return False
    index += 1
    while index < len(segment) and segment[index].startswith("-"):
        index += 2 if segment[index] in {"-C", "-c", "--git-dir", "--work-tree", "--config-env", "--exec-path"} else 1
    if index >= len(segment):
        return False
    subcommand, args = segment[index], segment[index + 1:]
    if subcommand == "branch":
        for offset, token in enumerate(args, index + 1):
            if token in branch_mutators or any(
                    token.startswith(option + "=") for option in branch_mutators
                    if option.startswith("--")):
                print("executable=git subcommand=branch token=%s argv_index=%d kind=branch-mutation" %
                      (token, offset))
                return True
        value_options = {"--contains", "--no-contains", "--merged", "--no-merged", "--points-at", "--format", "--sort", "--column", "--color"}
        skip = False
        for offset, token in enumerate(args, index + 1):
            if skip:
                skip = False
            elif token in value_options:
                skip = True
            elif not token.startswith("-"):
                print("executable=git subcommand=branch token=%s argv_index=%d kind=branch-ref-mutation" %
                      (token, offset))
                return True
        return False
    if subcommand == "remote" and args and args[0] in remote_mutators:
        print("executable=git subcommand=remote token=%s argv_index=%d kind=remote-mutation" %
              (args[0], index + 1))
        return True
    return False

parsed = tokenize(text)
found = parsed is not None and any(inspect(part) for part in split(parsed))
sys.exit(0 if found else 1)
PY
}

git_dynamic_execution_detail() {
  python3 - "$1" <<'PY'
import os
import re
import shlex
import sys

try:
    tokens = shlex.split(sys.argv[1], posix=True)
except ValueError:
    raise SystemExit(1)

hazardous_env = {
    "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_CONFIG", "GIT_CONFIG_COUNT",
    "GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM", "GIT_DIR",
    "GIT_EXTERNAL_DIFF", "GIT_OBJECT_DIRECTORY", "GIT_PAGER",
    "GIT_WORK_TREE",
}
for index, token in enumerate(tokens):
    name = token.split("=", 1)[0] if "=" in token else ""
    if name in hazardous_env:
        print(f"token={name} argv_index={index}")
        raise SystemExit(0)

git_index = next(
    (index for index, token in enumerate(tokens) if os.path.basename(token) == "git"),
    None,
)
if git_index is None:
    raise SystemExit(1)

global_hazardous = {
    "-c", "--config-env", "--exec-path", "--git-dir", "--work-tree",
    "--namespace", "--super-prefix",
}
global_prefixes = tuple(option + "=" for option in global_hazardous if option.startswith("--"))
bounded_read_only_subcommands = {
    "branch", "describe", "diff", "grep", "log", "ls-files", "remote",
    "rev-parse", "show", "status", "submodule",
}
git_c_options = []
index = git_index + 1
while index < len(tokens):
    token = tokens[index]
    if token in global_hazardous or token.startswith(global_prefixes):
        print(f"token={token} argv_index={index}")
        raise SystemExit(0)
    if token == "-C":
        if index + 1 >= len(tokens):
            if git_index == 0 and tokens[git_index] == "git":
                print(f"token=-C argv_index={index} reason=missing-canonical-repository-root")
                raise SystemExit(0)
            raise SystemExit(1)
        git_c_options.append((index, tokens[index + 1]))
        index += 2
        continue
    if token.startswith("-"):
        index += 1
        continue
    break

# `classify_eci_command` admits a direct Git inspection only after every
# leading `-C` selects a canonical approved root. If that bounded parser
# rejects a read-only-looking command, do not let the ordinary-command
# fallback silently allow it. Repeated `-C` invocations receive the same
# context validation for every Git subcommand; a single mutation remains on
# its existing approval route.
if (git_index == 0 and tokens[git_index] == "git" and git_c_options and
        (len(git_c_options) > 1 or
         (index < len(tokens) and tokens[index] in bounded_read_only_subcommands))):
    approved_roots = {
        os.environ.get("CODEX_APPROVED_REPO_ROOT_1", ""),
        os.environ.get("CODEX_APPROVED_REPO_ROOT_2", ""),
        os.environ.get("CODEX_APPROVED_REPO_ROOT_3", ""),
    }
    approved_roots.discard("")
    for option_index, repo in git_c_options:
        if (repo not in approved_roots or not os.path.isabs(repo) or
                os.path.normpath(repo) != repo or not os.path.isdir(repo) or
                os.path.islink(repo) or os.path.realpath(repo) != repo):
            print(
                "token=-C argv_index=%d repo=%s reason=unapproved-canonical-repository-root"
                % (option_index, repo)
            )
            raise SystemExit(0)

if index < len(tokens) and tokens[index] == "diff":
    for option_index in range(index + 1, len(tokens)):
        option = tokens[option_index]
        if option in {"--textconv", "--ext-diff"}:
            print(f"token={option} argv_index={option_index}")
            raise SystemExit(0)
raise SystemExit(1)
PY
}

# Workers do not get a direct Git inspection capability while ECI is active.
# Even read-only-looking Git commands can load repository-local configuration,
# aliases, external diff/textconv helpers, hooks, or other executable helpers.
# The coordinator has the bounded Git inspection route; workers must report
# the requested inspection to it instead of executing Git in their own shell.
command_invokes_worker_git_read_only() {
  python3 - "$1" <<'PY'
import os
import shlex
import sys

READ_ONLY = {"describe", "diff", "grep", "log", "ls-files", "rev-parse", "show", "status"}
GLOBAL_VALUE = {"-C", "-c", "--config-env", "--exec-path", "--git-dir", "--namespace", "--super-prefix", "--work-tree"}
OPERATORS = {";", "&", "&&", "|", "||", "(", ")"}

def split(tokens):
    result, current = [], []
    for token in tokens + [";"]:
        if token in OPERATORS:
            if current:
                result.append(current)
            current = []
        else:
            current.append(token)
    return result

def tokenize(value):
    try:
        lexer = shlex.shlex(value, posix=True, punctuation_chars=True)
        lexer.whitespace_split = True
        return list(lexer)
    except ValueError:
        return None

def is_assignment(token):
    name, sep, _ = token.partition("=")
    return bool(sep) and bool(name) and name.replace("_", "A").isalnum() and not name[0].isdigit()

def git_read_only(segment, index):
    if index >= len(segment) or os.path.basename(segment[index]) != "git":
        return False
    index += 1
    while index < len(segment):
        token = segment[index]
        if token in GLOBAL_VALUE:
            index += 2
            continue
        if token.startswith(("--config-env=", "--exec-path=", "--git-dir=", "--namespace=", "--super-prefix=", "--work-tree=")):
            index += 1
            continue
        if token.startswith("-"):
            index += 1
            continue
        subcommand = token
        args = segment[index + 1:]
        if subcommand in READ_ONLY:
            return True
        if subcommand == "submodule" and args[:1] == ["status"]:
            return True
        if subcommand == "branch":
            mutators = {"-d", "-D", "-m", "-M", "-c", "-C", "--delete", "--move", "--copy", "--edit-description", "--set-upstream-to", "--unset-upstream"}
            return not any(value in mutators or not value.startswith("-") for value in args)
        if subcommand == "remote":
            mutators = {"add", "remove", "rename", "set-url", "set-head", "prune", "update"}
            return not args or args[0] not in mutators
        return False
    return False

def inspect(segment, depth=0):
    if depth > 5 or not segment:
        return False
    index = 0
    while index < len(segment) and is_assignment(segment[index]):
        index += 1
    if index >= len(segment):
        return False
    name = os.path.basename(segment[index])
    if name == "env":
        index += 1
        while index < len(segment):
            token = segment[index]
            if is_assignment(token) or token.startswith("-"):
                index += 2 if token in {"-C", "-S", "-u", "--chdir", "--split-string", "--unset"} else 1
                continue
            break
        return inspect(segment[index:], depth + 1)
    if name in {"command", "builtin", "exec", "sudo", "doas", "nohup", "setsid", "timeout", "xargs"}:
        return inspect(segment[index + 1:], depth + 1)
    if name in {"bash", "sh", "dash", "zsh"}:
        for option_index, option in enumerate(segment[index + 1:], index + 1):
            if option == "-c" and option_index + 1 < len(segment):
                nested = tokenize(segment[option_index + 1])
                return nested is not None and any(inspect(part, depth + 1) for part in split(nested))
        return False
    return git_read_only(segment, index)

tokens = tokenize(sys.argv[1])
sys.exit(0 if tokens is not None and any(inspect(part) for part in split(tokens)) else 1)
PY
}

WORKER_PROJECT_INSPECTION_ALLOWED=false
WORKER_PROJECT_INSPECTION_DETAIL=""
worker_project_inspection_route() {
  [ "$hook_is_subagent" = true ] || return 1
  local detail
  detail="$(python3 - "$1" "$cwd" <<'PY'
import os
import shlex
import shutil
import sys

command, hook_cwd = sys.argv[1:]
OPS = {";", "&", "|", "||", ">", ">>", ">|", ">&", "<", "<<", "<<<", "<&", "(", ")"}
SAFE = {
    ("status", "--short"), ("status", "--porcelain"),
    ("submodule", "status"), ("diff", "--stat"),
}

def reject(reason):
    print("worker-project-inspection-route reason=" + reason)
    raise SystemExit(1)

try:
    lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    tokens = list(lexer)
except ValueError:
    reject("shell quoting is unbalanced")
if not tokens or any(token in OPS for token in tokens):
    # && is handled below; every other shell operator is never a relay form.
    if "&&" not in tokens or any(token in OPS - {"&&"} for token in tokens):
        reject("only literal && inspection chaining is allowed")

chunks, current = [], []
for token in tokens + ["&&"]:
    if token == "&&":
        if not current:
            reject("empty inspection segment")
        chunks.append(current)
        current = []
    else:
        current.append(token)
if not 1 <= len(chunks) <= 3:
    reject("inspection chain must contain one to three Git segments")

def trusted_git():
    resolved = shutil.which("git")
    if not resolved or not os.path.isabs(resolved):
        return False
    real = os.path.realpath(resolved)
    return os.path.isfile(real) and os.access(real, os.X_OK) and any(
        real == root or real.startswith(root + os.sep)
        for root in ("/bin", "/usr/bin", "/usr/local/bin", "/usr/lib/cargo/bin/coreutils")
    )

if not trusted_git():
    reject("git executable is not a trusted system binary")
if any(name.startswith("GIT_") and name not in {"GIT_PAGER", "GIT_PAGER_IN_USE"}
       for name in os.environ):
    reject("GIT_* environment contains an executable or repository override")

roots = set()
home = os.environ.get("HOME", "")
for name, fallback in (
    ("CODEX_APPROVED_REPO_ROOT_1", ""), ("CODEX_APPROVED_REPO_ROOT_2", ""),
    ("CODEX_APPROVED_REPO_ROOT_3", ""), ("KIMI_APPROVED_REPO_ROOT_1", ""),
    ("KIMI_APPROVED_REPO_ROOT_2", ""), ("KIMI_APPROVED_REPO_ROOT_3", ""),
):
    value = os.environ.get(name, fallback)
    if (value and os.path.isabs(value) and os.path.normpath(value) == value
            and os.path.isdir(value) and not os.path.islink(value)
            and os.path.realpath(value) == value):
        roots.add(value)
if not roots:
    reject("no canonical approved repository root is available")

def repo_ok(value):
    candidate = value if os.path.isabs(value) else os.path.abspath(os.path.join(hook_cwd, value))
    return (os.path.normpath(candidate) == candidate and os.path.isdir(candidate)
            and not os.path.islink(candidate) and os.path.realpath(candidate) == candidate
            and any(candidate == root for root in roots))

for segment in chunks:
    if segment[0] != "git" or any("/" in token for token in segment[:1]):
        reject("segment must invoke the trusted literal git executable")
    args = segment[1:]
    repo = hook_cwd
    if args[:1] == ["-C"]:
        if len(args) < 3 or not repo_ok(args[1]):
            reject("-C target must be an approved canonical repository root")
        repo = args[1]
        args = args[2:]
    elif not repo_ok(hook_cwd):
        reject("inspection cwd is not an approved canonical repository root")
    if tuple(args) not in SAFE:
        reject("segment must be git status --short, git submodule status, or git diff --stat")
print("ok")
PY
  )" || true
  if [[ "$detail" == ok ]]; then
    WORKER_PROJECT_INSPECTION_ALLOWED=true
    WORKER_PROJECT_INSPECTION_DETAIL=""
    return 0
  fi
  WORKER_PROJECT_INSPECTION_DETAIL="${detail:-worker-project-inspection-route reason=command is outside the bounded Git relay grammar}"
  return 1
}

WORKER_CONTROL_DETAIL=""
worker_control_path_detail() {
  [ "$hook_is_subagent" = true ] || return 1
  local detail
  detail="$(python3 - "$command" "$cwd" "$HOOK_DIR" "${syntax_eci_markers[@]}" <<'PY'
import os
import re
import shlex
import sys

command, hook_cwd, hook_dir = sys.argv[1:4]
active_markers = sys.argv[4:]
try:
    tokens = shlex.split(command, posix=True)
except ValueError:
    raise SystemExit(1)
if len(tokens) < 2:
    raise SystemExit(1)

control_bases = {
    "eci_active", "goal_state", "eci_wait", "eci_user_owned_wait.md",
    "eci-required-critics.json", "eci-critic-identities.ledger",
    "eci-acceptance-anchor", "eci-acceptance-transaction",
    "eci-teardown-complete", "eci-baseline-binding", "baseline_head",
    "eci-commit-admitted", "eci-user-closed.ledger", "proof.md",
    "instructions.md", "stop_timestamps", "stop_loop_state",
    "disengage.md", "user-closed.md", "project-understanding.md",
    "high_level_log.md", "latest-status-report.md", "high_level_log.anchor",
}
def is_control_name(value):
    return value in control_bases or any(value.startswith(base + ".") for base in control_bases)

roots = []
for name in (
    "CODEX_PROOF_ROOT", "CODEX_PROOF_ROOT_CANONICAL", "CODEX_PROOF_ROOT_CONFIGURED",
    "CODEX_PROOF_ROOT_STABLE_ALIAS", "KIMI_PROOF_ROOT", "KIMI_PROOF_ROOT_CANONICAL",
    "KIMI_PROOF_ROOT_CONFIGURED", "KIMI_PROOF_ROOT_STABLE_ALIAS",
):
    raw = os.environ.get(name, "")
    if (raw and os.path.isabs(raw) and os.path.normpath(raw) == raw
            and os.path.isdir(raw) and not os.path.islink(raw)
            and os.path.realpath(raw) == raw and raw not in roots):
        roots.append(raw)

def in_root(path):
    return any(path == root or path.startswith(root + os.sep) for root in roots)

def containing_root(path):
    for root in roots:
        if path == root or path.startswith(root + os.sep):
            return root
    return ""

provider_session_roots = {
    os.path.realpath(os.path.join(os.path.dirname(hook_dir), "sessions")),
}
home = os.environ.get("HOME", "")
if home:
    provider_session_roots.add(os.path.realpath(os.path.join(home, ".kimi-code", "sessions")))

def in_provider_sessions(path):
    return any(path == root or path.startswith(root + os.sep) for root in provider_session_roots)

readable_documents = {"instructions.md", "project-understanding.md", "high_level_log.md", "latest-status-report.md"}
operators = {";", "&", "&&", "|", "||", "(", ")", ">", ">>", ">|", ">&", "<", "<<", "<<<", "<&"}

def canonical_document(path):
    if (not path or path.startswith("-") or any(mark in path for mark in
            ("$", "`", "..", "*", "?", "[", "]", "(", ")"))):
        return False
    candidate = path if os.path.isabs(path) else os.path.abspath(os.path.join(hook_cwd, path))
    return (os.path.normpath(candidate) == candidate and os.path.isfile(candidate)
            and not os.path.islink(candidate) and os.path.realpath(candidate) == candidate
            and os.path.basename(candidate) in readable_documents and in_root(candidate))

def bounded_control_read(values):
    if any(token in operators for token in values):
        return False
    name = os.path.basename(values[0])
    args = values[1:]
    paths = []
    if name == "cat":
        if any(token.startswith("-") and token != "--" for token in args):
            return False
        paths = [token for token in args if token != "--"]
    elif name == "sed":
        if (len(args) != 3 or args[0] not in {"-n", "--quiet"}
                or not re.fullmatch(r"[1-9][0-9]*(,[1-9][0-9]*)?p", args[1])):
            return False
        paths = [args[2]]
    elif name in {"rg", "grep"}:
        index = 0
        pattern = False
        while index < len(args):
            token = args[index]
            if token in {"-n", "--line-number", "-i", "--ignore-case", "-F", "--fixed-strings", "-I", "--no-ignore"}:
                index += 1
                continue
            if token in {"-g", "--glob"} and index + 1 < len(args):
                index += 2
                continue
            if token == "--":
                paths.extend(args[index + 1:])
                break
            if token.startswith("-"):
                return False
            if not pattern:
                pattern = True
            else:
                paths.append(token)
            index += 1
        if not pattern:
            return False
    else:
        return False
    return bool(paths) and len(paths) <= 16 and all(canonical_document(path) for path in paths)

read_tools = {
    "cat", "cmp", "cut", "diff", "egrep", "fgrep", "file", "grep", "head",
    "jq", "ls", "nl", "od", "printenv", "readlink", "rg", "sed", "sha256sum", "sort",
    "stat", "tail", "tr", "uniq", "wc",
}
command_name = os.path.basename(tokens[0])
generic_read_command = (
    command_name in read_tools and
    not any(token in operators for token in tokens) and
    not (command_name == "sed" and any(
        token in {"-i", "--in-place"} or token.startswith(("-i=", "--in-place="))
        for token in tokens[1:]
    ))
)

def git_read_path_operands(values):
    if os.path.basename(values[0]) != "git":
        return ([], hook_cwd)
    args = values[1:]
    base = hook_cwd
    index = 0
    value_options = {"-c", "--config-env", "--git-dir", "--work-tree", "--namespace"}
    while index < len(args):
        token = args[index]
        if token == "-C":
            if index + 1 >= len(args):
                return ([], base)
            requested = os.path.expanduser(args[index + 1])
            base = requested if os.path.isabs(requested) else os.path.abspath(os.path.join(base, requested))
            base = os.path.normpath(base)
            index += 2
            continue
        if token in value_options:
            if index + 1 >= len(args):
                return ([], base)
            index += 2
            continue
        if any(token.startswith(option + "=") for option in value_options if option.startswith("--")):
            index += 1
            continue
        if token in {"--literal-pathspecs", "--no-optional-locks", "--no-pager"}:
            index += 1
            continue
        if token.startswith("-"):
            return ([], base)
        break
    if index >= len(args):
        return ([], base)
    verb = args[index]
    if verb not in {
        "annotate", "blame", "diff", "diff-files", "diff-index", "diff-tree",
        "grep", "log", "shortlog", "show", "whatchanged",
    }:
        return ([], base)
    tail = args[index + 1:]
    if "--" not in tail:
        return ([], base)
    paths = tail[tail.index("--") + 1:]
    if not paths or len(paths) > 16:
        return ([], base)
    if any(not path or path.startswith("-") or path in operators for path in paths):
        return ([], base)
    return (paths, base)

git_instruction_operands, git_operand_cwd = git_read_path_operands(tokens)
read_command = generic_read_command or bool(git_instruction_operands)

def read_path_operands(values):
    name = os.path.basename(values[0])
    args = values[1:]
    if name in {"rg", "grep", "egrep", "fgrep"}:
        paths = []
        pattern_seen = False
        index = 0
        option_args = {"-A", "-B", "-C", "--after-context", "--before-context",
                       "--context", "-e", "--regexp", "-f", "--file", "-g", "--glob"}
        while index < len(args):
            token = args[index]
            if token == "--":
                tail = args[index + 1:]
                if pattern_seen:
                    paths.extend(tail)
                elif tail:
                    pattern_seen = True
                    paths.extend(tail[1:])
                break
            if token in option_args and index + 1 < len(args):
                if token in {"-e", "--regexp", "-f", "--file"}:
                    pattern_seen = True
                index += 2
                continue
            if token.startswith("-"):
                index += 1
                continue
            if not pattern_seen:
                pattern_seen = True
            else:
                paths.append(token)
            index += 1
        return paths
    if name == "sed":
        return [args[-1]] if len(args) >= 2 and not args[-1].startswith("-") else []
    if name == "jq":
        non_options = [token for token in args if not token.startswith("-")]
        return non_options[1:] if len(non_options) > 1 else []
    return [token for token in args if token not in operators and not token.startswith("-")]

def normalized_root(raw):
    if not raw or not os.path.isabs(raw) or os.path.normpath(raw) != raw:
        return None
    resolved = os.path.realpath(raw)
    if not os.path.isdir(resolved):
        return None
    return (raw, resolved)

instruction_roots = []
for raw in (
    os.path.dirname(hook_dir), os.environ.get("CODEX_HOME", ""),
    os.environ.get("KIMI_CODE_HOME", ""),
    os.path.join(os.environ.get("HOME", ""), ".codex"),
    os.path.join(os.environ.get("HOME", ""), ".kimi-code"),
):
    root = normalized_root(raw)
    if root and root not in instruction_roots:
        instruction_roots.append(root)

def contained(path, root):
    return path == root or path.startswith(root + os.sep)

directory_read_tools = {"diff", "egrep", "fgrep", "file", "grep", "ls", "rg", "stat"}

def instruction_source_detail(token, operand_cwd):
    expanded = os.path.expanduser(token)
    candidate = expanded if os.path.isabs(expanded) else os.path.abspath(
        os.path.join(operand_cwd, expanded)
    )
    candidate = os.path.normpath(candidate)
    resolved = os.path.realpath(candidate)
    basename = os.path.basename(candidate)
    parts = [part for part in candidate.split(os.sep) if part]
    kind = "document" if basename in {"CODEX.md", "AGENTS.md"} else (
        "skill" if "skills" in parts else ""
    )
    if not kind:
        return None

    matched = None
    lexical_match = False
    if kind == "skill":
        for lexical_root, real_root in instruction_roots:
            lexical_skills = os.path.join(lexical_root, "skills")
            real_skills = os.path.join(real_root, "skills")
            if contained(candidate, lexical_skills):
                matched = (lexical_root, real_root)
                lexical_match = True
                break
            if contained(resolved, real_skills):
                matched = (lexical_root, real_root)
                break
    else:
        project_roots = [(hook_cwd, os.path.realpath(hook_cwd))]
        parent = hook_cwd
        while parent != os.path.dirname(parent):
            parent = os.path.dirname(parent)
            project_roots.append((parent, os.path.realpath(parent)))
        for lexical_root, real_root in instruction_roots + project_roots:
            lexical_target = os.path.join(lexical_root, basename)
            real_target = os.path.join(real_root, basename)
            if candidate == lexical_target:
                matched = (lexical_root, real_root)
                lexical_match = True
                break
            if resolved == real_target:
                matched = (lexical_root, real_root)
                break
        if matched is None and contained(candidate, hook_cwd):
            matched = (hook_cwd, os.path.realpath(hook_cwd))
            lexical_match = True

    if matched is None:
        return ("deny", "token=%s candidate=%s resolved=%s instruction_root=<none> failure=outside-instruction-root" %
                (token, candidate, resolved))
    lexical_root, real_root = matched
    instruction_root = os.path.join(lexical_root, "skills") if kind == "skill" else lexical_root
    real_instruction_root = os.path.join(real_root, "skills") if kind == "skill" else real_root
    if not os.path.exists(candidate):
        return ("deny", "token=%s candidate=%s resolved=%s instruction_root=%s failure=missing-instruction-source" %
                (token, candidate, resolved, instruction_root))
    if lexical_match and not contained(resolved, real_instruction_root):
        return ("deny", "token=%s candidate=%s resolved=%s instruction_root=%s failure=symlink-escape" %
                (token, candidate, resolved, instruction_root))
    if os.path.islink(candidate):
        return ("deny", "token=%s candidate=%s resolved=%s instruction_root=%s failure=noncanonical-symlink" %
                (token, candidate, resolved, instruction_root))
    if os.path.isdir(candidate):
        if command_name not in directory_read_tools:
            return ("deny", "token=%s candidate=%s resolved=%s instruction_root=%s failure=directory-not-readable-by-tool tool=%s" %
                    (token, candidate, resolved, instruction_root, command_name))
        return ("allow", "token=%s candidate=%s resolved=%s instruction_root=%s source_type=directory tool=%s" %
                (token, candidate, resolved, instruction_root, command_name))
    if not os.path.isfile(candidate):
        return ("deny", "token=%s candidate=%s resolved=%s instruction_root=%s failure=not-regular-file" %
                (token, candidate, resolved, instruction_root))
    return ("allow", "token=%s candidate=%s resolved=%s instruction_root=%s source_type=regular-file" %
            (token, candidate, resolved, instruction_root))

def active_control_inode_index():
    """Index only control records in the currently active session directories."""
    index = {}
    seen_session_dirs = set()
    for marker in active_markers:
        session_dir = os.path.dirname(marker)
        if session_dir in seen_session_dirs:
            continue
        seen_session_dirs.add(session_dir)
        try:
            entries = os.scandir(session_dir)
        except OSError:
            continue
        try:
            for entry in entries:
                if not is_control_name(entry.name) or entry.is_symlink():
                    continue
                try:
                    state = entry.stat(follow_symlinks=False)
                except OSError:
                    continue
                index[(state.st_dev, state.st_ino)] = entry.path
        finally:
            entries.close()
    return index

active_control_inodes = active_control_inode_index()

def current_control_hardlink(path):
    try:
        target = os.stat(path, follow_symlinks=False)
    except OSError:
        return None
    return active_control_inodes.get((target.st_dev, target.st_ino))

def protected_control_path(path):
    """Return whether path names live or reserved ECI control state."""
    if not path:
        return False
    resolved = os.path.realpath(path)
    if (in_root(path) and is_control_name(os.path.basename(path))) or (
            in_root(resolved) and is_control_name(os.path.basename(resolved))):
        return True
    return current_control_hardlink(path) is not None

instruction_operands = (
    set(git_instruction_operands) if git_instruction_operands else
    (set(read_path_operands(tokens)) if generic_read_command else set())
)

def emit(kind, token, resolved):
    if kind == "read":
        print("read token=%s resolved=%s route=coordinator-inspection-route" % (token, resolved))
    else:
        print("write token=%s resolved=%s" % (token, resolved))
    raise SystemExit(0)

output_path_options = {"--report-path", "--to-file", "--output", "-o"}
output_operands = set()
for index, raw_token in enumerate(tokens[1:], 1):
    path_token = ""
    if raw_token in output_path_options and index + 1 < len(tokens):
        path_token = tokens[index + 1]
    else:
        for option in output_path_options:
            prefix = option + "="
            if raw_token.startswith(prefix):
                path_token = raw_token[len(prefix):]
                break
    if not path_token:
        continue
    output_operands.add(path_token)
    candidate = path_token if os.path.isabs(path_token) else os.path.abspath(
        os.path.join(hook_cwd, path_token)
    )
    candidate = os.path.normpath(candidate)
    resolved = os.path.realpath(candidate)
    if (in_root(candidate) or in_root(resolved)) and protected_control_path(candidate):
        emit("write", raw_token if "=" in raw_token else path_token, resolved)

for token in tokens[1:]:
    if token.startswith("-") or token in operators:
        continue
    expanded = os.path.expanduser(token)
    candidate = expanded if os.path.isabs(expanded) else os.path.abspath(os.path.join(hook_cwd, expanded))
    candidate = os.path.normpath(candidate)
    if token in instruction_operands:
        operand_cwd = git_operand_cwd if token in git_instruction_operands else hook_cwd
        instruction_detail = instruction_source_detail(token, operand_cwd)
        if instruction_detail is not None:
            instruction_state, detail = instruction_detail
            if instruction_state == "deny":
                print("instruction-denied " + detail)
                raise SystemExit(0)
            control_alias = current_control_hardlink(candidate)
            if control_alias:
                emit("read", token, control_alias)
            continue
    resolved = os.path.realpath(candidate)
    if in_root(candidate):
        if not os.path.lexists(candidate) and token not in output_operands:
            print("instruction-denied token=%s candidate=%s resolved=%s instruction_root=%s failure=missing-instruction-source" %
                  (token, candidate, resolved, containing_root(candidate)))
            raise SystemExit(0)
        if bounded_control_read(tokens) and canonical_document(token):
            continue
        if protected_control_path(candidate):
            emit("read" if read_command else "write", token, candidate)
        continue
    if in_provider_sessions(candidate):
        emit("read" if read_command else "write", token, candidate)
    if is_control_name(os.path.basename(candidate)) and in_root(candidate):
        if bounded_control_read(tokens) and canonical_document(token):
            continue
        emit("read" if read_command else "write", token, candidate)
    resolved = os.path.realpath(candidate)
    if in_root(resolved):
        if bounded_control_read(tokens) and canonical_document(token):
            continue
        if protected_control_path(candidate) or protected_control_path(resolved):
            emit("read" if read_command else "write", token, resolved)
        continue
    if in_provider_sessions(resolved):
        emit("read" if read_command else "write", token, resolved)
    if resolved != candidate and is_control_name(os.path.basename(resolved)) and in_root(resolved):
        if bounded_control_read(tokens) and canonical_document(token):
            continue
        emit("read" if read_command else "write", token, resolved)
    control_alias = current_control_hardlink(candidate)
    if control_alias:
        emit("read" if read_command else "write", token, control_alias)
raise SystemExit(1)
PY
  )" || true
  WORKER_CONTROL_DETAIL="${detail:-worker-control reason=command is outside coordinator control-path grammar}"
  if [ -n "$detail" ]; then
    printf '%s\n' "$detail"
    return 0
  fi
  return 1
}

command_invokes_eci_acceptance_mutation() {
  python3 - "$1" <<'PY'
import os
import re
import shlex
import sys

text = sys.argv[1]
operators = {";", "&", "&&", "|", "||", "(", ")"}
git_mutators = {
    "commit", "merge", "rebase", "cherry-pick", "revert", "am", "apply",
    "add", "rm", "mv", "restore",
    "tag",
}
branch_mutators = {"-d", "-D", "-m", "-M", "-c", "-C", "--delete", "--move", "--copy", "--edit-description", "--set-upstream-to", "--unset-upstream"}
remote_mutators = {"add", "remove", "rename", "set-url", "set-head", "prune", "update"}

def tokenize(value):
    try:
        lexer = shlex.shlex(value, posix=True, punctuation_chars=True)
        lexer.whitespace_split = True
        return list(lexer)
    except ValueError:
        return None

def split(tokens):
    result, current = [], []
    for token in tokens + [";"]:
        if token in operators:
            if current:
                result.append(current)
            current = []
        else:
            current.append(token)
    return result

def assignment(token):
    return bool(re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", token))

def inspect(segment, depth=0):
    if depth > 6 or not segment:
        return depth > 6
    index = 0
    while index < len(segment) and assignment(segment[index]):
        index += 1
    if index >= len(segment):
        return False
    name = os.path.basename(segment[index])
    if name == "git":
        index += 1
        while index < len(segment):
            token = segment[index]
            if token in {"-C", "-c", "--config-env", "--git-dir", "--work-tree", "--namespace", "--exec-path", "--super-prefix"}:
                index += 2
                continue
            if token.startswith(("-C", "--config-env=", "--git-dir=", "--work-tree=", "--namespace=", "--exec-path=", "--super-prefix=")):
                index += 1
                continue
            if token == "--":
                index += 1
                continue
            if token.startswith("-"):
                return True
            if token in git_mutators:
                return True
            if token == "branch":
                return any(arg in branch_mutators or any(arg.startswith(opt + "=") for opt in branch_mutators) for arg in segment[index + 1:])
            if token == "remote":
                return bool(segment[index + 1:] and segment[index + 1] in remote_mutators)
            return False
        return False
    if name in {"bash", "sh", "dash", "zsh"}:
        for option_index, option in enumerate(segment[index + 1:], index + 1):
            if option == "-c" or (option.startswith("-") and "c" in option[1:]):
                if option_index + 1 >= len(segment):
                    return True
                nested = tokenize(segment[option_index + 1])
                return nested is None or any(inspect(part, depth + 1) for part in split(nested))
        return False
    if name == "env":
        index += 1
        while index < len(segment):
            token = segment[index]
            if assignment(token) or token in {"-i", "--ignore-environment"}:
                index += 1
                continue
            if token in {"-u", "--unset", "-C", "--chdir", "-S", "--split-string"} and index + 1 < len(segment):
                if token in {"-S", "--split-string"}:
                    nested = tokenize(segment[index + 1])
                    return nested is None or any(inspect(part, depth + 1) for part in split(nested))
                index += 2
                continue
            if token.startswith("-"):
                index += 1
                continue
            break
        return any(inspect(part, depth + 1) for part in split(segment[index:]))
    if name in {"timeout", "systemd-run", "nice", "time", "prlimit", "chronic"}:
        index += 1
        value_options = {
            "-k", "--kill-after", "-s", "--signal", "-n", "--adjustment",
            "-p", "--property", "--unit", "--setenv", "--working-directory",
            "-C", "--chdir",
        }
        while index < len(segment) and segment[index].startswith("-"):
            option = segment[index]
            if option == "--":
                index += 1
                break
            if option in value_options:
                if index + 1 >= len(segment):
                    return True
                index += 2
                continue
            index += 1
        if name == "timeout":
            if index >= len(segment):
                return True
            index += 1
        return inspect(segment[index:], depth + 1)
    if name in {"command", "builtin", "exec", "nohup", "setsid", "sudo", "doas"}:
        return any(inspect(part, depth + 1) for part in split(segment[index + 1:]))
    if name in {"xargs", "find"}:
        # These launchers receive commands indirectly; a visible Git token is
        # enough to route the whole acceptance-sensitive command to main.
        return any(os.path.basename(token) == "git" for token in segment[index + 1:])
    return False

parsed = tokenize(text)
found = parsed is None or any(inspect(part) for part in split(parsed))
sys.exit(0 if found else 1)
PY
}

command_invokes_eci_off() {
  python3 - "$1" <<'PY'
import os
import re
import shlex
import shutil
import sys

text = sys.argv[1]
operators = {";", "&", "&&", "|", "||", "(", ")"}
configured_home = os.path.realpath(os.path.abspath(
    os.environ.get("CODEX_HOME") or os.path.join(os.environ.get("HOME", ""), ".codex")
))
configured_eci = os.path.realpath(os.path.normpath(os.path.join(configured_home, "bin", "eci-active")))
invocation_cwd = os.path.realpath(os.environ.get("CODEX_VALIDATE_CWD") or os.getcwd())

def real_eci(token):
    if token == "eci-active":
        resolved = shutil.which(token)
        return bool(resolved) and os.path.realpath(os.path.abspath(resolved)) == configured_eci
    token = os.path.expanduser(token)
    candidates = [token] if os.path.isabs(token) else [
        os.path.join(invocation_cwd, token),
        os.path.join(configured_home, token),
    ]
    return any(
        os.path.isfile(candidate) and
        os.path.realpath(candidate) == configured_eci
        for candidate in candidates
    )

def assignment(token):
    return bool(re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", token))

def tokenize(value):
    try:
        lexer = shlex.shlex(value, posix=True, punctuation_chars=True)
        lexer.whitespace_split = True
        return list(lexer)
    except ValueError:
        return None

def split(tokens):
    result, current = [], []
    for token in tokens + [";"]:
        if token in operators:
            if current:
                result.append(current)
            current = []
        else:
            current.append(token)
    return result

def skip_options(segment, index, with_args=(), without_args=()):
    with_args = set(with_args)
    without_args = set(without_args)
    while index < len(segment):
        token = segment[index]
        if token == "--":
            return index + 1
        if token in with_args:
            if index + 1 >= len(segment):
                return None
            index += 2
        elif any(token.startswith(option + "=") for option in with_args):
            index += 1
        elif token in without_args or token.startswith("-"):
            index += 1
        else:
            break
    return index

def shell_script_lifecycle(segment, index, target):
    script_index = index + 1
    while script_index < len(segment):
        token = segment[script_index]
        if token == "--":
            script_index += 1
            break
        if token.startswith("-"):
            return False
        break
    if script_index >= len(segment) or not real_eci(segment[script_index]):
        return False
    args = segment[script_index + 1:]
    # This recognizer protects the subagent boundary, not the lifecycle CLI's
    # argument validator.  Once the canonical binary and mutation verb are
    # visible, extra/malformed arguments must still be routed to the main
    # thread rather than becoming a parser bypass.
    return bool(args) and args[0] == target

def inspect(segment, depth=0):
    if depth > 4:
        return False
    index = 0
    while index < len(segment) and assignment(segment[index]):
        index += 1
    if index >= len(segment):
        return False
    command = os.path.basename(segment[index])
    if command in {"source", "."}:
        return shell_script_lifecycle(segment, index, "off")
        if command == "env":
            return UNKNOWN
        for option_index, option in enumerate(segment[index + 1:], index + 1):
            if option == "-S":
                if option_index + 1 >= len(segment):
                    return False
                nested = tokenize(segment[option_index + 1])
                return nested is not None and any(inspect(part, depth + 1) for part in split(nested))
        index = skip_options(segment, index + 1, {"-C", "--chdir", "-u", "--unset"}, {"-i", "--ignore-environment"})
        if index is None:
            return False
        while index < len(segment) and assignment(segment[index]):
            index += 1
        return inspect(segment[index:], depth + 1)
    if command in {"command", "builtin", "exec"}:
        if command == "command":
            index = skip_options(segment, index + 1, (), {"-p", "-v", "-V"})
        elif command == "exec":
            index = skip_options(segment, index + 1, {"-a"}, {"-c", "-l"})
        else:
            index += 1
        return index is not None and inspect(segment[index:], depth + 1)
    if command in {"nohup", "setsid", "doas", "sudo", "timeout", "systemd-run"}:
        index = skip_options(segment, index + 1, {"-k", "--kill-after", "-u", "--user", "-C", "--chdir", "--unit"})
        if index is None:
            return False
        if command == "timeout" and index < len(segment):
            index += 1
        return inspect(segment[index:], depth + 1)
    if command == "xargs":
        index = skip_options(
            segment,
            index + 1,
            {"-a", "-d", "-E", "-I", "-L", "-n", "-P", "--delimiter", "--eof", "--replace", "--max-lines", "--max-args", "--max-procs"},
            {"-0", "-r", "--null", "--no-run-if-empty", "--", "--verbose", "--interactive"},
        )
        return index is not None and inspect(segment[index:], depth + 1)
    if command == "find":
        for option_index, option in enumerate(segment[index + 1:], index + 1):
            if option not in {"-exec", "-execdir", "-ok", "-okdir"}:
                continue
            end = option_index + 1
            while end < len(segment) and segment[end] not in {";", "+"}:
                end += 1
            if any(inspect(part, depth + 1) for part in split(segment[option_index + 1:end])):
                return True
        return False
    if command in {"bash", "sh", "dash", "zsh"}:
        for option_index, option in enumerate(segment[index + 1:], index + 1):
            if option in {"-c", "-lc", "-cl"} or (option.startswith("-") and not option.startswith("--") and "c" in option[1:]):
                if option_index + 1 >= len(segment):
                    return False
                nested = tokenize(segment[option_index + 1])
                return nested is not None and any(inspect(part, depth + 1) for part in split(nested))
        return shell_script_lifecycle(segment, index, "off")
    if command == "eval":
        nested = tokenize(" ".join(segment[index + 1:]))
        return nested is not None and any(inspect(part, depth + 1) for part in split(nested))
    return real_eci(segment[index]) and index + 1 < len(segment) and segment[index + 1] == "off"

try:
    tokens = tokenize(text)
    found = tokens is not None and any(inspect(part) for part in split(tokens))
except (TypeError, ValueError):
    found = False
sys.exit(0 if found else 1)
PY
}

command_invokes_eci_wait_or_resume() {
  python3 - "$1" <<'PY'
import os
import re
import shlex
import shutil
import sys

text = sys.argv[1]
operators = {";", "&", "&&", "|", "||", "(", ")"}
targets = {"on", "wait", "resume", "ledger-append", "nested-enter", "nested-accept", "nested-exit", "manifest-write"}
configured_home = os.path.realpath(os.path.abspath(
    os.environ.get("CODEX_HOME") or os.path.join(os.environ.get("HOME", ""), ".codex")
))
configured_eci = os.path.realpath(os.path.normpath(os.path.join(configured_home, "bin", "eci-active")))
invocation_cwd = os.path.realpath(os.environ.get("CODEX_VALIDATE_CWD") or os.getcwd())


def real_eci(token):
    if token == "eci-active":
        resolved = shutil.which(token)
        return bool(resolved) and os.path.realpath(os.path.abspath(resolved)) == configured_eci
    token = os.path.expanduser(token)
    candidates = [token] if os.path.isabs(token) else [
        os.path.join(invocation_cwd, token),
        os.path.join(configured_home, token),
    ]
    return any(
        os.path.isfile(candidate) and
        os.path.realpath(candidate) == configured_eci
        for candidate in candidates
    )


def tokens(value):
    lexer = shlex.shlex(value, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    return list(lexer)


def segments(value):
    result = []
    current = []
    for token in value:
        if token in operators:
            if current:
                result.append(current)
            current = []
        else:
            current.append(token)
    if current:
        result.append(current)
    return result


def is_assignment(token):
    return bool(re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", token))


def basename(token):
    return os.path.basename(token)


def skip_options(segment, index, with_argument=(), without_argument=()):
    with_argument = set(with_argument)
    without_argument = set(without_argument)
    while index < len(segment):
        token = segment[index]
        if token == "--":
            return index + 1
        if token in with_argument:
            index += 2
            continue
        if any(token.startswith(option + "=") for option in with_argument):
            index += 1
            continue
        if token in without_argument or token.startswith("-"):
            index += 1
            continue
        break
    return index

def shell_script_lifecycle(segment, index):
    script_index = index + 1
    while script_index < len(segment):
        token = segment[script_index]
        if token == "--":
            script_index += 1
            break
        if token.startswith("-"):
            return False
        break
    if script_index >= len(segment) or not real_eci(segment[script_index]):
        return False
    args = segment[script_index + 1:]
    if not args:
        return False
    target = args[0]
    # The hook only needs to recognize the lifecycle verb.  The CLI performs
    # its own exact argument validation; extra arguments must not evade the
    # main/orchestrator ownership boundary.
    return target in targets


def inspect(segment, depth=0):
    if depth > 4:
        return False
    index = 0
    while index < len(segment) and is_assignment(segment[index]):
        index += 1
    if index >= len(segment):
        return False

    command = basename(segment[index])
    if command in {"source", "."}:
        return shell_script_lifecycle(segment, index)
    if command == "env":
        for option_index, option in enumerate(segment[index + 1:], index + 1):
            if option == "-S":
                if option_index + 1 >= len(segment):
                    return False
                try:
                    return any(inspect(part, depth + 1) for part in segments(tokens(segment[option_index + 1])))
                except ValueError:
                    return False
        index = skip_options(
            segment,
            index + 1,
            with_argument={"-C", "--chdir", "-u", "--unset"},
            without_argument={"-i", "--ignore-environment"},
        )
        while index < len(segment) and is_assignment(segment[index]):
            index += 1
        return inspect(segment[index:], depth + 1)

    if command in {"command", "builtin", "exec"}:
        if command == "command":
            next_index = skip_options(segment, index + 1, without_argument={"-p", "-v", "-V"})
        elif command == "exec":
            next_index = skip_options(segment, index + 1, with_argument={"-a"}, without_argument={"-c", "-l"})
        else:
            next_index = index + 1
        return inspect(segment[next_index:], depth + 1)

    if command in {"nohup", "setsid", "doas", "sudo"}:
        option_index = skip_options(
            segment,
            index + 1,
            with_argument={"-u", "--user", "-g", "--group", "-C", "--chdir", "-D"},
        )
        return inspect(segment[option_index:], depth + 1)

    if command == "xargs":
        option_index = skip_options(
            segment,
            index + 1,
            with_argument={"-a", "-d", "-E", "-I", "-L", "-n", "-P", "--delimiter", "--eof", "--replace", "--max-lines", "--max-args", "--max-procs"},
            without_argument={"-0", "-r", "--null", "--no-run-if-empty", "--", "--verbose", "--interactive"},
        )
        return option_index is not None and inspect(segment[option_index:], depth + 1)

    if command == "find":
        for option_index, option in enumerate(segment[index + 1:], index + 1):
            if option not in {"-exec", "-execdir", "-ok", "-okdir"}:
                continue
            end = option_index + 1
            while end < len(segment) and segment[end] not in {";", "+"}:
                end += 1
            try:
                if any(inspect(part, depth + 1) for part in segments(segment[option_index + 1:end])):
                    return True
            except ValueError:
                return False
        return False

    if command in {"bash", "sh", "dash", "zsh"}:
        for option_index in range(index + 1, len(segment)):
            option = segment[option_index]
            if option in {"-c", "-lc", "-cl"} or (
                option.startswith("-") and not option.startswith("--") and "c" in option[1:]
            ):
                if option_index + 1 >= len(segment):
                    return False
                try:
                    return any(inspect(part, depth + 1) for part in segments(tokens(segment[option_index + 1])))
                except ValueError:
                    return False
        return shell_script_lifecycle(segment, index)

    if command in {"timeout", "nice", "chronic", "systemd-run", "prlimit", "time"}:
        option_index = skip_options(
            segment,
            index + 1,
            with_argument={
                "-k", "--kill-after", "-s", "--signal", "-n", "--adjustment",
                "-p", "--property", "--unit", "--setenv", "--working-directory", "-C", "--chdir",
            },
            without_argument={"--foreground", "--preserve-status", "--scope", "--user", "--system", "--wait", "--pipe", "--quiet"},
        )
        if command == "timeout" and option_index < len(segment):
            option_index += 1
        return inspect(segment[option_index:], depth + 1)

    return index + 1 < len(segment) and real_eci(segment[index]) and segment[index + 1] in targets


try:
    found = any(inspect(part) for part in segments(tokens(text)))
except (TypeError, ValueError):
    found = False
sys.exit(0 if found else 1)
PY
}

# Detect lifecycle verbs for either provider before the generic finite-literal
# admission.  Provider symmetry matters here: the coordinator may route a
# canonical Codex or Kimi lifecycle binary, but an invalid verb/argument must
# not become an ordinary novel executable merely because it is an absolute
# path.  The peer route remains the authority for the exact accepted shape.
command_invokes_eci_lifecycle() {
  python3 - "$1" <<'PY'
import os
import re
import shlex
import shutil
import sys

try:
    lexer = shlex.shlex(sys.argv[1], posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    tokens = list(lexer)
except ValueError:
    raise SystemExit(1)

operators = {";", "&", "&&", "|", "||", "(", ")"}
targets = {
    "--help", "-h", "status", "on", "off", "wait", "resume", "ledger-append", "nested-enter",
    "nested-accept", "nested-exit", "manifest-write", "approve-commit",
}

home = os.environ.get("HOME", "")
roots = []
for value in (
    os.environ.get("CODEX_HOME") or os.path.join(home, ".codex"),
    os.environ.get("KIMI_CODE_HOME") or os.path.join(home, ".kimi-code"),
):
    if not value or not os.path.isabs(value) or os.path.islink(value):
        continue
    root = os.path.realpath(value)
    if os.path.normpath(root) != root or not os.path.isdir(root):
        continue
    roots.append(os.path.join(root, "bin", "eci-active"))
canonical = set(roots)

def lifecycle_path(value):
    expanded = os.path.expanduser(value)
    if value == "eci-active":
        resolved = shutil.which(value)
        return bool(resolved) and os.path.realpath(os.path.abspath(resolved)) in canonical
    if not os.path.isabs(expanded) or os.path.normpath(expanded) != expanded:
        return False
    return os.path.realpath(expanded) in canonical

for index, token in enumerate(tokens):
    if token in operators:
        continue
    if lifecycle_path(token) and index + 1 < len(tokens) and tokens[index + 1] in targets:
        raise SystemExit(0)
raise SystemExit(1)
PY
}

# Recognize either provider's canonical lifecycle executable for worker
# ownership checks, including read-only verbs such as status/--help. A worker
# may use ordinary project tools directly, but canonical eci-active binaries
# remain coordinator-owned control surfaces.
command_invokes_eci_binary() {
  python3 - "$1" <<'PY'
import os
import shlex
import shutil
import sys

try:
    lexer = shlex.shlex(sys.argv[1], posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    tokens = list(lexer)
except ValueError:
    raise SystemExit(1)

operators = {";", "&", "&&", "|", "||", "(", ")"}
home = os.environ.get("HOME", "")
roots = []
for value in (
    os.environ.get("CODEX_HOME") or os.path.join(home, ".codex"),
    os.environ.get("KIMI_CODE_HOME") or os.path.join(home, ".kimi-code"),
):
    if not value or not os.path.isabs(value) or os.path.islink(value):
        continue
    root = os.path.realpath(value)
    if os.path.normpath(root) != root or not os.path.isdir(root):
        continue
    roots.append(os.path.join(root, "bin", "eci-active"))
canonical = set(roots)

def lifecycle_path(value):
    expanded = os.path.expanduser(value)
    if value == "eci-active":
        resolved = shutil.which(value)
        return bool(resolved) and os.path.realpath(os.path.abspath(resolved)) in canonical
    if not os.path.isabs(expanded) or os.path.normpath(expanded) != expanded:
        return False
    return os.path.realpath(expanded) in canonical

for token in tokens:
    if token not in operators and lifecycle_path(token):
        raise SystemExit(0)
raise SystemExit(1)
PY
}

classify_eci_command() {
  python3 - "$1" <<'PY'
import os
import hashlib
import re
import shlex
import shutil
import sys

operators = {";", "&", "&&", "|", "||", "(", ")"}
redirections = {">", ">>", ">|", "<", "<<", "<<<", ">&", "<&"}
READ_ONLY = "read-only"
COMMIT = "commit"
PREP = "prep"
RESET = "reset"
WORKTREE = "worktree"
CONTROL = "control"
VERIFICATION = "verification"
UNKNOWN = "unknown"


def tokenize(value):
    try:
        lexer = shlex.shlex(value, posix=True, punctuation_chars=True)
        lexer.whitespace_split = True
        return list(lexer)
    except ValueError:
        return None


def segments(tokens):
    result, current = [], []
    for token in tokens + [";"]:
        if token in operators or token in redirections:
            if current:
                result.append(current)
            current = []
        else:
            current.append(token)
    return result


def bounded_batch_segments(tokens):
    """Split a finite read-only batch, rejecting ambiguous shell operators."""
    result = []
    current = []
    index = 0
    while index < len(tokens):
        token = tokens[index]
        if token == "2>/dev/null" or (
            token == "2" and index + 2 < len(tokens)
            and tokens[index + 1] == ">" and tokens[index + 2] == "/dev/null"
        ):
            index += 1 if token == "2>/dev/null" else 3
            continue
        if token == "||":
            if not current or index + 1 >= len(tokens) or tokens[index + 1] != "true":
                return None
            if len(result) >= 16:
                return None
            result.append(current)
            current = ["true"]
            index += 2
            continue
        if token in {";", "|", "&&"}:
            if not current:
                return None
            if len(result) >= 16:
                return None
            result.append(current)
            current = []
            index += 1
            continue
        if token in operators or token in redirections:
            return None
        current.append(token)
        index += 1
    if not current:
        return None
    result.append(current)
    return result


def assignment(token):
    return bool(re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", token))


def skip_options(segment, index, with_argument=(), without_argument=()):
    with_argument = set(with_argument)
    without_argument = set(without_argument)
    while index < len(segment):
        token = segment[index]
        if token == "--":
            return index + 1
        if token in with_argument:
            if index + 1 >= len(segment):
                return None
            index += 2
        elif any(token.startswith(option + "=") for option in with_argument):
            index += 1
        elif token in without_argument:
            index += 1
        elif token.startswith("-"):
            return None
        else:
            break
    return index


def combine(states):
    states = list(states)
    if not states:
        return UNKNOWN
    if UNKNOWN in states:
        return UNKNOWN
    if VERIFICATION in states:
        return VERIFICATION if all(state == VERIFICATION for state in states) else UNKNOWN
    if COMMIT in states:
        return COMMIT
    if PREP in states:
        return PREP
    if RESET in states:
        return RESET
    if WORKTREE in states:
        return WORKTREE
    if CONTROL in states:
        return CONTROL
    return READ_ONLY


READ_ONLY_COMMANDS = {
    "basename", "cat", "cmp", "cut", "date", "diff", "dirname", "du", "echo",
    "env", "file", "find", "gitleaks", "go", "gofmt", "grep", "head", "jq", "ls", "od", "printenv",
    "printf", "ps", "pwd", "realpath", "readlink", "rg", "sha256sum", "sort", "stat", "tail",
    "tr", "true", "false", "uniq", "wc", "which",
}
GIT_READ_ONLY = {
    "describe", "diff", "grep", "log", "ls-files", "rev-parse", "show", "status", "submodule",
}
BRANCH_MUTATORS = {
    "-d", "-D", "-m", "-M", "-c", "-C", "--delete", "--move",
    "--copy", "--edit-description", "--set-upstream-to", "--unset-upstream",
}
REMOTE_MUTATORS = {
    "add", "remove", "rename", "set-url", "set-head", "prune", "update",
}
COMMIT_FLAG_OPTIONS = {
    "-a", "--all", "--amend", "--no-verify", "--verify", "--signoff", "-s",
    "--no-signoff", "--no-edit", "--edit", "--allow-empty", "--allow-empty-message",
    "--no-post-rewrite", "--post-rewrite", "--reset-author", "--quiet", "-q",
    "--verbose", "-v", "-vv", "--no-status", "--status", "--dry-run", "--only",
    "--include", "-i", "-o", "--no-gpg-sign", "--gpg-sign",
}
COMMIT_VALUE_OPTIONS = {
    "-m", "--message", "-F", "--file", "--author", "--date", "--cleanup",
    "--template", "--reuse-message", "-C", "--reedit-message", "-c",
    "--fixup", "--squash", "--trailer", "--pathspec-from-file",
}
COMMIT_VALUE_PREFIXES = tuple(
    option + "=" for option in COMMIT_VALUE_OPTIONS if option.startswith("--")
)

configured_codex_home = os.path.realpath(os.path.abspath(
    os.environ.get("CODEX_HOME") or os.path.join(os.environ.get("HOME", ""), ".codex")
))
configured_kimi_home = os.path.realpath(os.path.abspath(
    os.environ.get("KIMI_CODE_HOME") or os.path.join(os.environ.get("HOME", ""), ".kimi-code")
))
configured_eci = os.path.realpath(os.path.normpath(os.path.join(configured_codex_home, "bin", "eci-active")))
configured_review_gate = os.path.realpath(os.path.normpath(os.path.join(configured_codex_home, "hooks", "eci-review-gate.sh")))
invocation_cwd = os.path.realpath(os.environ.get("CODEX_VALIDATE_CWD") or os.getcwd())
HIGH_RISK_GIT_ENV_NAMES = {
    "GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_CONFIG",
    "GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM", "GIT_CONFIG_NOSYSTEM",
    "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT", "GIT_EXEC_PATH",
    "GIT_CEILING_DIRECTORIES", "GIT_NAMESPACE", "GIT_INDEX_FILE",
    "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_EXTERNAL_DIFF", "GIT_DIFF_OPTS", "GIT_ATTR_NOSYSTEM",
    "GIT_EDITOR", "GIT_SEQUENCE_EDITOR", "GIT_SSH", "GIT_SSH_COMMAND",
    "GIT_ASKPASS", "GIT_PROXY_COMMAND", "GIT_HTTP_PROXY", "GIT_HTTPS_PROXY",
}
EXECUTION_CONTEXT_NAMES = {
    "BASH_ENV", "ENV", "CDPATH", "PYTHONSTARTUP", "RUBYOPT",
    "NODE_OPTIONS", "PERL5OPT", "PATH",
}
# All Git_* controls are treated as inherited context except the pager-only
# pair, which does not select a repository/config/helper and is neutralized by
# codex_git_safe's fixed no-pager environment.  Every repository/helper/editor
# control remains acceptance-unsafe.
INHERITED_GIT_CONTEXT = any(
    name.startswith("GIT_") and name not in {"GIT_PAGER", "GIT_PAGER_IN_USE"}
    or name in HIGH_RISK_GIT_ENV_NAMES
    or name.startswith("GIT_CONFIG_KEY_")
    or name.startswith("GIT_CONFIG_VALUE_")
    for name in os.environ
)
SED_SCRIPT = re.compile(r"^[1-9][0-9]*(,[1-9][0-9]*)?p$")

def git_context_is_safe():
    return all(name in {"GIT_PAGER", "GIT_PAGER_IN_USE"}
               for name in os.environ if name.startswith("GIT_"))

def canonical_high_level_log(path):
    expected = os.environ.get("CODEX_HIGH_LEVEL_LOG_PATH", "")
    alias = os.environ.get("CODEX_HIGH_LEVEL_LOG_PATH_ALIAS", "")
    if not expected or path not in {expected, alias}:
        return False
    return (
        os.path.isfile(path) and
        not os.path.islink(path) and
        os.path.realpath(path) == expected
    )

def bounded_sed_read_only(segment, index):
    if index != 0 or segment[index] != "sed":
        return False
    if not trusted_sed_token(segment[index]):
        return False
    args = segment[index + 1:]
    return (
        len(args) == 3 and
        args[0] in {"-n", "--quiet"} and
        SED_SCRIPT.fullmatch(args[1]) is not None and
        (canonical_high_level_log(args[2]) or approved_read_path(args[2], approved_read_roots()))
    )

def bounded_git_c_status(segment, index):
    if index != 0 or not git_context_is_safe():
        return False
    if len(segment) != index + 5 or segment[index + 1] != "-C" or segment[index + 3:] != ["status", "--short"]:
        return False
    return bounded_git_c_read_only(segment, index)


def approved_git_repo(value):
    if not value or value.startswith("-") or os.path.islink(value):
        return False
    approved_roots = approved_read_roots()
    return bool(value in approved_roots and os.path.isdir(value)
                and os.path.realpath(value) == value)


def safe_git_pathspecs(repo, options):
    """Return (options, paths, explicit-delimiter), or None if unsafe."""
    explicit_delimiter = "--" in options
    if "--" in options:
        delimiter = options.index("--")
        option_tokens = options[:delimiter]
        paths = options[delimiter + 1:]
        if not paths:
            return None
    else:
        option_tokens = []
        while len(option_tokens) < len(options) and options[len(option_tokens)].startswith("-"):
            option_tokens.append(options[len(option_tokens)])
        paths = options[len(option_tokens):]
    if len(paths) > 16:
        return None
    if not paths:
        return option_tokens, [], explicit_delimiter
    repo = os.path.realpath(repo)
    for path in paths:
        if (not path or path.startswith("-") or os.path.isabs(path)
                or path.startswith(":") or any(mark in path for mark in
                    ("$", "`", "\n", "\r", "*", "?", "[", "]", "(" , ")"))):
            return None
        components = path.split("/")
        if any(component in {"", ".", ".."} for component in components):
            return None
        candidate = os.path.normpath(os.path.join(repo, path))
        if candidate != os.path.join(repo, path):
            return None
        if not (candidate == repo or candidate.startswith(repo + os.sep)):
            return None
    return option_tokens, paths, explicit_delimiter


def bounded_git_diff_sed_pipeline(tokens):
    """Admit one coordinator-only finite Git-diff-to-sed inspection pipe."""
    if os.environ.get("CODEX_HOOK_IS_SUBAGENT") == "true" or tokens.count("|") != 1:
        return False
    pipe_index = tokens.index("|")
    left, right = tokens[:pipe_index], tokens[pipe_index + 1:]
    if len(right) != 3 or right[0] != "sed" or right[1] not in {"-n", "--quiet"}:
        return False
    if not trusted_sed_token(right[0]):
        return False
    range_match = re.fullmatch(r"([1-9][0-9]*)(?:,([1-9][0-9]*))?p", right[2])
    if not range_match:
        return False
    if any(int(value) > 1000 for value in range_match.groups() if value is not None):
        return False
    if len(left) < 2 or left[0] != "git" or not trusted_git_token(left[0]):
        return False
    if not git_context_is_safe():
        return False
    if left[1] == "-C":
        if len(left) < 4:
            return False
        repo, args = left[2], left[3:]
    else:
        repo, args = invocation_cwd, left[1:]
    if not approved_git_repo(repo) or not args or args[0] != "diff":
        return False
    parsed = safe_git_pathspecs(repo, args[1:])
    if parsed is None:
        return False
    option_tokens, paths, explicit_delimiter = parsed
    return (explicit_delimiter and bool(paths) and
            all(option in {"--check", "--stat", "--name-only", "--name-status"}
                for option in option_tokens))


def bounded_git_c_read_only(segment, index):
    if index != 0 or len(segment) < index + 4:
        return False
    if segment[index:index + 2] != ["git", "-C"]:
        return False
    if not git_context_is_safe():
        return False
    if not trusted_git_token(segment[index]):
        return False
    cursor = index + 1
    repo = ""
    while cursor < len(segment) and segment[cursor] == "-C":
        if cursor + 1 >= len(segment) or not approved_git_repo(segment[cursor + 1]):
            return False
        repo = segment[cursor + 1]
        cursor += 2
    args = segment[cursor:]
    if not args:
        return False
    subcommand, options = args[0], args[1:]
    if subcommand == "submodule":
        return options == ["status"]
    def bounded_log_limit(value):
        match = re.fullmatch(r"-(?:([1-9])|1([0-6]))|--max-count=(?:([1-9])|1([0-6]))", value)
        if not match:
            return False
        return True
    allowed = {
        "status": {"--short", "--porcelain", "--branch"},
        "grep": {"-n", "--line-number", "-i", "--ignore-case", "-F", "--fixed-strings", "-I", "--no-textconv"},
        "log": {"--oneline"},
        "diff": {"--cached", "--staged", "--check", "--stat", "--name-only", "--name-status"},
        "show": {"--stat", "--oneline", "--no-patch", "-1"},
    }.get(subcommand)
    if allowed is None:
        return False
    if subcommand == "grep":
        pattern_seen = False
        cursor = 0
        while cursor < len(options):
            option = options[cursor]
            if option == "--":
                paths = options[cursor + 1:]
                return pattern_seen and len(paths) <= 16 and all(
                    path and not path.startswith("-") and not os.path.isabs(path)
                    and not any(mark in path for mark in ("$", "`", "\n", "\r", "*", "?", "[", "]", "(", ")"))
                    and all(component not in {"", ".", ".."} for component in path.split("/"))
                    for path in paths
                )
            if option in allowed:
                cursor += 1
                continue
            if option in {"-e", "--regexp"}:
                if cursor + 1 >= len(options):
                    return False
                pattern = options[cursor + 1]
                if not pattern or any(mark in pattern for mark in ("$", "`", "\n", "\r")):
                    return False
                pattern_seen = True
                cursor += 2
                continue
            if option.startswith("--regexp="):
                pattern = option.split("=", 1)[1]
                if not pattern or any(mark in pattern for mark in ("$", "`", "\n", "\r")):
                    return False
                pattern_seen = True
                cursor += 1
                continue
            if not pattern_seen:
                if not option or option.startswith("-") or any(mark in option for mark in ("$", "`", "\n", "\r")):
                    return False
                pattern_seen = True
                cursor += 1
                continue
            if (not option or option.startswith("-") or os.path.isabs(option)
                    or any(mark in option for mark in ("$", "`", "\n", "\r", "*", "?", "[", "]", "(", ")"))
                    or any(component in {"", ".", ".."} for component in option.split("/"))):
                return False
            cursor += 1
        return pattern_seen
    parsed_paths = safe_git_pathspecs(repo, options)
    if parsed_paths is None:
        return False
    option_tokens, paths, explicit_delimiter = parsed_paths
    if subcommand == "log":
        if any(option not in allowed and not bounded_log_limit(option) for option in option_tokens):
            return False
    elif any(option not in allowed for option in option_tokens):
        return False
    if subcommand == "status":
        return True
    if subcommand == "log":
        return any(bounded_log_limit(option) for option in option_tokens)
    if subcommand == "diff":
        # An optionless pathspec is admitted only after an explicit `--`.
        return bool(option_tokens) or explicit_delimiter
    if subcommand == "show":
        return bool(option_tokens) or explicit_delimiter
    return False

TRUSTED_SED = os.path.realpath(os.environ.get("CODEX_TRUSTED_SED", ""))
TRUSTED_GIT = os.path.realpath(os.environ.get("CODEX_TRUSTED_GIT", ""))


def trusted_path_token(token, name, expected):
    if token != name or not expected:
        return False
    path_value = os.environ.get("CODEX_COMMAND_PATH", "")
    for entry in path_value.split(":"):
        if not entry.startswith("/"):
            return False
        candidate = os.path.join(entry, name)
        if not os.path.isfile(candidate) or not os.access(candidate, os.X_OK):
            continue
        return os.path.realpath(candidate) == expected
    return False


def trusted_sed_token(token):
    return trusted_path_token(token, "sed", TRUSTED_SED)


def trusted_git_token(token):
    return trusted_path_token(token, "git", TRUSTED_GIT)


def real_eci_command(token):
    if token == "eci-active":
        resolved = shutil.which(token)
        return bool(resolved) and os.path.realpath(os.path.abspath(resolved)) == configured_eci
    expanded = os.path.expanduser(token)
    candidates = [expanded] if os.path.isabs(expanded) else [
        os.path.join(invocation_cwd, expanded),
        os.path.join(configured_codex_home, expanded),
    ]
    return any(
        os.path.isfile(candidate) and
        os.path.realpath(candidate) == configured_eci
        for candidate in candidates
    )


def real_review_gate_command(token):
    expanded = os.path.expanduser(token)
    candidates = [expanded] if os.path.isabs(expanded) else [
        os.path.join(invocation_cwd, expanded),
        os.path.join(configured_codex_home, expanded),
    ]
    return any(
        os.path.isfile(candidate) and
        os.path.realpath(candidate) == configured_review_gate
        for candidate in candidates
    )


def shell_script_control(segment, index, inherited_injection=False):
    # A test entry point is safe only with the hook's clean execution context.
    # Leading assignments or env/wrapper injection can run startup hooks (for
    # example BASH_ENV) before the reviewed script and therefore remain
    # unknown under an active ECI marker.
    if inherited_injection:
        return UNKNOWN
    script_index = index + 1
    while script_index < len(segment) and segment[script_index].startswith("-"):
        script_index += 1
    if script_index >= len(segment) or not real_eci_command(segment[script_index]):
        if script_index >= len(segment) or not real_review_gate_command(segment[script_index]):
            return UNKNOWN
        args = segment[script_index + 1:]
        return CONTROL if (
            len(args) == 2 and args[0] in {"commit", "final", "off", "prewrite"}
            and re.match(r"^[A-Za-z0-9][A-Za-z0-9_-]*$", args[1])
        ) else UNKNOWN
    args = segment[script_index + 1:]
    if len(args) == 2 and args[0] in {"on", "off", "wait", "resume", "manifest-write"}:
        return CONTROL
    if len(args) == 2 and args[0] == "ledger-append":
        return CONTROL
    if len(args) in {3, 4} and args[0] == "nested-enter":
        return CONTROL
    if len(args) == 1 and args[0] in {"nested-accept", "nested-exit"}:
        return CONTROL
    return UNKNOWN


def known_test_script(path):
    """Only explicit repository hook-test entry points are executable here."""
    if any(mark in path for mark in ("$", "`", "..")):
        return False
    normalized = path[2:] if path.startswith("./") else path
    if not normalized.startswith("hooks/tests/"):
        return False
    name = normalized.rsplit("/", 1)[-1]
    return name in {
        "run.sh",
        "test-eci-fast-path.sh",
        "test-eci-post-compact-refresh.sh",
        "test-eci-review-gate.sh",
        "test-session-snapshot-refresh.sh",
        "test-validate-bash-classifier.sh",
        "test-validate-bash-git-approvals.sh",
        "test-policy-design-boundary.sh",
        "test-eci-edit-control-paths.sh",
        "test-pretooluse-latency.sh",
        "test-pre-commit-go-mod.sh",
        "test-eci-command-syntax-gating.sh",
        "test-stop-marker-validation.sh",
    }


def safe_read_only_args(args):
    """Reject options that turn a nominally read-only utility into a writer."""
    forbidden = {
        "-i", "--in-place", "--delete", "-delete", "-exec", "-execdir", "-ok", "-okdir",
        "-o", "--output", "--to-file", "--textconv", "--ext-diff",
        "-C", "-c", "--config-env", "--git-dir", "--work-tree", "--exec-path",
        "--namespace", "--super-prefix",
    }
    return not any(
        token in forbidden
        or token.startswith(("-o", "--output=", "--to-file=", "--textconv=", "--ext-diff=",
                             "--config-env=", "--git-dir=", "--work-tree=", "--exec-path=",
                             "--namespace=", "--super-prefix="))
        for token in args
    )


def approved_read_roots():
    worker_home = os.path.realpath(
        os.environ.get("CODEX_HOME") or os.environ.get("KIMI_CODE_HOME") or ""
    ) if os.environ.get("CODEX_HOOK_IS_SUBAGENT") == "true" else ""
    canonical_peer_homes = {
        os.path.realpath(os.path.join(os.environ.get("HOME", ""), ".codex")),
        os.path.realpath(os.path.join(os.environ.get("HOME", ""), ".kimi-code")),
    }
    values = [
        os.environ.get("CODEX_APPROVED_REPO_ROOT_1", ""),
        os.environ.get("CODEX_APPROVED_REPO_ROOT_2", ""),
        os.environ.get("CODEX_APPROVED_REPO_ROOT_3", ""),
        os.environ.get("CODEX_PROOF_ROOT_CANONICAL", ""),
        os.environ.get("CODEX_PROOF_ROOT_CONFIGURED", ""),
        os.environ.get("CODEX_PROOF_ROOT_STABLE_ALIAS", ""),
        configured_codex_home,
        configured_kimi_home,
    ]
    roots = set()
    for value in values:
        if not value or not os.path.isabs(value) or os.path.islink(value):
            continue
        normalized = os.path.normpath(value)
        if normalized != value:
            continue
        resolved = os.path.realpath(value)
        # A worker may use its own configured home, but the other canonical
        # Codex/Kimi home is coordinator-owned.  Do not let the generic
        # read-only fast path turn a peer root into an inspection escape hatch.
        if (worker_home and resolved in canonical_peer_homes and
                resolved != worker_home):
            continue
        if resolved == value and os.path.isdir(value):
            roots.add(value)
    stable_alias = os.environ.get("CODEX_PROOF_ROOT_STABLE_ALIAS", "")
    canonical_root = os.environ.get("CODEX_PROOF_ROOT_CANONICAL", "")
    if (stable_alias and canonical_root and os.path.isabs(stable_alias)
            and os.path.isdir(stable_alias)
            and os.path.realpath(stable_alias) == canonical_root):
        roots.add(stable_alias)
    skills = os.path.join(configured_codex_home, "skills")
    if os.path.isdir(skills) and not os.path.islink(skills) and os.path.realpath(skills) == skills:
        roots.add(skills)
    configured_proof = os.environ.get("CODEX_PROOF_ROOT_CONFIGURED", "")
    canonical_proof = os.environ.get("CODEX_PROOF_ROOT_CANONICAL", "")
    if (configured_proof and canonical_proof and
            os.path.isabs(configured_proof) and os.path.isabs(canonical_proof) and
            os.path.normpath(configured_proof) == configured_proof and
            os.path.normpath(canonical_proof) == canonical_proof and
            os.path.basename(configured_proof) == os.path.basename(canonical_proof) == "codex-proof" and
            os.path.basename(os.path.dirname(configured_proof)) == os.path.basename(os.path.dirname(canonical_proof)) == ".cache" and
            os.path.isdir(configured_proof) and os.path.isdir(canonical_proof)):
        configured_anchor = os.path.dirname(os.path.dirname(configured_proof))
        canonical_anchor = os.path.dirname(os.path.dirname(canonical_proof))
        for root in tuple(roots):
            try:
                relative = os.path.relpath(root, configured_anchor)
            except ValueError:
                continue
            if relative == ".." or relative.startswith(".." + os.sep):
                continue
            alias = os.path.normpath(os.path.join(canonical_anchor, relative))
            if os.path.isdir(alias) and not os.path.islink(alias):
                roots.add(alias)
    # The coordinator may inspect bounded temporary probe output. Keep this
    # root out of worker admission, but accept configured deployment aliases
    # only after resolving them into the approved local home/temp topology.
    if os.environ.get("CODEX_HOOK_IS_SUBAGENT") != "true":
        def canonical_directory(raw):
            if (not raw or not os.path.isabs(raw) or
                    os.path.normpath(raw) != raw):
                return ""
            canonical = os.path.realpath(raw)
            if (not os.path.isabs(canonical) or
                    os.path.normpath(canonical) != canonical or
                    not os.path.isdir(canonical) or os.path.islink(canonical) or
                    os.path.realpath(canonical) != canonical):
                return ""
            return canonical

        canonical_tmp = canonical_directory("/tmp")
        if canonical_tmp != "/tmp":
            canonical_tmp = ""
        home = os.environ.get("HOME", "")
        canonical_home_tmp = canonical_directory(os.path.join(home, "tmp") if home else "")
        topology = {root for root in (canonical_tmp, canonical_home_tmp) if root}
        for value in {"/bin", "/usr/bin", "/usr/local/bin", "/usr/lib/cargo/bin/coreutils"}:
            if canonical_directory(value) == value:
                roots.add(value)
        for raw in (
                os.environ.get("CODEX_TMPDIR", ""),
                os.environ.get("TMPDIR", ""),
                os.path.join(home, "tmp") if home else "",
                "/tmp",
        ):
            canonical = canonical_directory(raw)
            if canonical and any(canonical == root or canonical.startswith(root + os.sep)
                                 for root in topology):
                roots.add(canonical)
    return roots


def approved_read_path(value, roots, allow_missing=True):
    if not value or value.startswith("-"):
        return False
    if any(mark in value for mark in ("$", "`", "(", ")", "*", "?", "[", "]")):
        return False
    if not os.path.isabs(value):
        if ".." in value.split("/"):
            return False
        value = os.path.abspath(os.path.join(
            os.environ.get("CODEX_VALIDATE_CWD", os.getcwd()), value
        ))
    normalized = os.path.normpath(value)
    if normalized != value or "/../" in value or "/./" in value or "//" in value:
        return False
    resolved = os.path.realpath(value)
    # A proof-root path is a security boundary of its own.  Do not let the
    # coordinator's generic /tmp inspection root legitimize a symlink from
    # proof state to an unrelated /tmp target.  Configured/stable spellings
    # are admitted only when they resolve to the canonical proof root.
    canonical_proof = os.environ.get("CODEX_PROOF_ROOT_CANONICAL", "")
    canonical_proof = (
        os.path.realpath(canonical_proof)
        if canonical_proof and os.path.isabs(canonical_proof)
        else ""
    )
    proof_scope_roots = []
    for name in (
        "CODEX_PROOF_ROOT_CANONICAL",
        "CODEX_PROOF_ROOT_CONFIGURED",
        "CODEX_PROOF_ROOT_STABLE_ALIAS",
    ):
        lexical_root = os.environ.get(name, "")
        if not lexical_root or not os.path.isabs(lexical_root):
            continue
        lexical_root = os.path.normpath(lexical_root)
        resolved_root = os.path.realpath(lexical_root)
        if canonical_proof and resolved_root == canonical_proof:
            proof_scope_roots.append((lexical_root, canonical_proof))
    if not canonical_proof:
        for name in ("CODEX_PROOF_ROOT_CONFIGURED", "CODEX_PROOF_ROOT_STABLE_ALIAS"):
            lexical_root = os.environ.get(name, "")
            if lexical_root and os.path.isabs(lexical_root):
                proof_scope_roots.append((os.path.normpath(lexical_root), os.path.realpath(lexical_root)))
    for lexical_root, proof_root in proof_scope_roots:
        if value == lexical_root or value.startswith(lexical_root + os.sep):
            if not (resolved == proof_root or resolved.startswith(proof_root + os.sep)):
                return False
            break
    stable_alias = os.environ.get("CODEX_PROOF_ROOT_STABLE_ALIAS", "")
    canonical_root = os.environ.get("CODEX_PROOF_ROOT_CANONICAL", "")
    stable_path = bool(
        stable_alias and canonical_root and
        (value == stable_alias or value.startswith(stable_alias + os.sep)) and
        resolved == canonical_root + value[len(stable_alias):]
    )
    under_root = lambda candidate: any(candidate == root or candidate.startswith(root + os.sep) for root in roots)
    equivalent_root = False
    for root in roots:
        if value != root and not value.startswith(root + os.sep):
            continue
        relative = os.path.relpath(value, root)
        resolved_root = resolved
        for _ in relative.split(os.sep):
            resolved_root = os.path.dirname(resolved_root)
        if (resolved_root != root and resolved_root.endswith(root) and
                os.path.isdir(resolved_root) and not os.path.islink(resolved_root)):
            equivalent_root = True
            break
    if (resolved != value and not stable_path and not under_root(resolved) and not equivalent_root) or not (under_root(value) or under_root(resolved) or equivalent_root):
        return False
    if os.path.exists(value):
        return True
    if not allow_missing:
        return False
    # Preserve the containment decision for an absent final component. The
    # nearest extant ancestor must still resolve below the approved root; no
    # missing-path diagnostic can step through a symlink outside it.
    ancestor = value
    while not os.path.lexists(ancestor):
        parent = os.path.dirname(ancestor)
        if parent == ancestor:
            return False
        ancestor = parent
    resolved_ancestor = os.path.realpath(ancestor)
    return under_root(resolved_ancestor) or equivalent_root


def bounded_read_only_args(command, args):
    """Accept only finite inspection arguments and paths under approved roots."""
    # Shell syntax is validated against the original command before this
    # token-level classifier runs.  shlex has intentionally removed quote
    # provenance by this point, so rejecting literal '$'/'`' characters here
    # would incorrectly deny safe single-quoted search patterns (for example
    # rg -n 'literal ` text' file).  Unquoted expansion remains rejected by
    # command_has_unsafe_shell_syntax; path-specific checks below still reject
    # expansion-looking path components.
    if any(token in redirections or token in {"(", ")"} for token in args):
        return False
    roots = approved_read_roots()
    pipeline_stdin = os.environ.get("ECI_READ_ONLY_PIPELINE") == "true"
    if command in {"true", "false", "pwd"}:
        return not args
    if command == "env":
        return False
    if command == "date":
        return args in (["-u", "+%Y-%m-%dT%H:%M:%SZ"], ["--utc", "+%Y-%m-%dT%H:%M:%SZ"])
    if command == "printenv":
        return False
    if command in {"printf", "echo"}:
        return bool(args) and all(token not in redirections and token not in {"(", ")"} for token in args)
    if command == "which":
        return bool(args) and all(re.fullmatch(r"[A-Za-z0-9_.+-]+", token) for token in args)
    if command == "ps":
        if os.environ.get("CODEX_HOOK_IS_SUBAGENT") == "true" and not pipeline_stdin:
            return False
        # Keep process inspection bounded to stable identity/state views.  The
        # compact `pid,cmd` form is sufficient for coordinator helper
        # inspection; arbitrary ps format strings remain rejected.
        format_values = {
            "pid,cmd", "pid=,cmd=", "pid,ppid,cmd", "pid=,ppid=,cmd=",
            "pid,etime,stat,cmd", "pid=,etime=,stat=,cmd=",
            "pid,ppid,etimes,stat,args", "pid=,ppid=,etimes=,stat=,args=",
        }
        index = 0
        saw_format = False
        while index < len(args):
            token = args[index]
            if token in {"-o", "--format"} and index + 1 < len(args):
                if args[index + 1] not in format_values or saw_format:
                    return False
                saw_format = True
                index += 2
            elif token == "-eo" and index + 1 < len(args) and args[index + 1] in format_values and not saw_format:
                saw_format = True
                index += 2
                continue
            if token.startswith("--format="):
                if token.split("=", 1)[1] not in format_values or saw_format:
                    return False
                saw_format = True
                index += 1
                continue
            if token in {"-e", "--everyone", "--no-headers"}:
                index += 1
                continue
            if token in {"-p", "--pid"} and index + 1 < len(args):
                if not re.fullmatch(r"[1-9][0-9]*(,[1-9][0-9]*)*", args[index + 1]):
                    return False
                index += 2
                continue
            if token.startswith("--pid="):
                if not re.fullmatch(r"--pid=[1-9][0-9]*(,[1-9][0-9]*)*", token):
                    return False
                index += 1
                continue
            return False
        return saw_format
    if command == "sort":
        return not args
    if command == "diff" and any(
        token in {"-o", "--output", "--to-file"}
        or token.startswith(("--output=", "--to-file="))
        for token in args
    ):
        return False
    if pipeline_stdin and command in {"cat", "sha256sum", "uniq"} and not args:
        return True
    if command in {"echo", "cat", "cmp", "diff", "file", "du", "sha256sum", "tr", "uniq", "basename", "dirname"}:
        return bool(args) and all(approved_read_path(token, roots) for token in args if not token.startswith("-"))
    if command == "ls":
        allowed = {"-1", "-a", "-l", "-h", "-d", "-i", "-la", "-al", "-li", "-il", "-ld", "-dl", "--all", "--human-readable", "--directory"}
        paths = []
        index = 0
        while index < len(args):
            token = args[index]
            if token in allowed:
                index += 1
                continue
            if token.startswith("-"):
                return False
            paths.append(token)
            index += 1
        return bool(paths) and len(paths) <= 16 and all(approved_read_path(path, roots) for path in paths)
    if command in {"head", "tail", "wc"}:
        paths = []
        index = 0
        while index < len(args):
            token = args[index]
            if command == "wc" and token in {"-l", "--lines"}:
                index += 1
                continue
            if command in {"head", "tail"} and token in {"-n", "--lines"} and index + 1 < len(args):
                if not re.fullmatch(r"[1-9][0-9]*", args[index + 1]):
                    return False
                index += 2
                continue
            if command in {"head", "tail"} and re.fullmatch(r"-[1-9][0-9]*", token):
                index += 1
                continue
            if command in {"head", "tail"} and token.startswith("--lines="):
                if not re.fullmatch(r"--lines=[1-9][0-9]*", token):
                    return False
                index += 1
                continue
            if token.startswith("-"):
                return False
            paths.append(token)
            index += 1
        return all(approved_read_path(path, roots) for path in paths)
    if command in {"stat", "readlink", "realpath"}:
        paths = []
        index = 0
        while index < len(args):
            token = args[index]
            if command == "stat" and token in {"-c", "--format"} and index + 1 < len(args):
                if args[index + 1] not in {"%a %n", "%A %n", "%i %a %n", "%i %a %h %n", "%d:%i %a %h %n", "%F %N", "%F %s %n", "%y %n", "%y %s %n"}:
                    return False
                index += 2
                continue
            if command == "stat" and token.startswith("--format="):
                if token.split("=", 1)[1] not in {"%a %n", "%A %n", "%i %a %n", "%i %a %h %n", "%d:%i %a %h %n", "%F %N", "%F %s %n", "%y %n", "%y %s %n"}:
                    return False
                index += 1
                continue
            if command == "stat" and token in {"-L", "--dereference"}:
                index += 1
                continue
            if command == "stat" and token in {"-Lc", "-cL"} and index + 1 < len(args):
                if args[index + 1] not in {"%a %n", "%A %n", "%i %a %n", "%i %a %h %n", "%d:%i %a %h %n", "%F %N", "%F %s %n", "%y %n", "%y %s %n"}:
                    return False
                index += 2
                continue
            if command == "readlink" and token in {"-f", "-e", "-m", "--canonicalize", "--canonicalize-existing", "--canonicalize-missing"}:
                index += 1
                continue
            if command == "realpath" and token in {"-e", "-m", "-L", "--canonicalize-existing", "--canonicalize-missing"}:
                index += 1
                continue
            if token.startswith("-"):
                return False
            paths.append(token)
            index += 1
        return bool(paths) and len(paths) <= 16 and all(approved_read_path(path, roots) for path in paths)
    if command == "grep":
        return len(args) >= 2 and all(approved_read_path(path, roots) for path in args[1:])
    if command == "rg":
        if not args:
            return False
        paths = []
        index = 0
        saw_files = False
        saw_pattern = False
        while index < len(args):
            token = args[index]
            if token == "--files":
                saw_files = True
                index += 1
                continue
            if token in {"-g", "--glob"} and index + 1 < len(args):
                index += 2
                continue
            if token in {"--hidden", "--no-ignore", "-i", "--ignore-case", "-n", "--line-number", "-l", "--files-with-matches", "-F", "-c", "--count", "--count-matches"}:
                index += 1
                continue
            if token.startswith("-"):
                return False
            if not saw_files and not paths:
                # A literal search pattern is allowed; it is not a path.
                index += 1
                saw_pattern = True
                continue
            paths.append(token)
            index += 1
        return (bool(paths) or saw_files or saw_pattern) and all(approved_read_path(path, roots) for path in paths)
    if command == "find":
        if not args:
            return False
        index = 0
        if args[0] == "-P":
            index = 1
        paths = []
        while index < len(args) and not args[index].startswith("-"):
            paths.append(args[index])
            if len(paths) > 16 or not approved_read_path(args[index], roots):
                return False
            index += 1
        if not paths:
            return False
        saw_print = False
        saw_default_filter = False
        while index < len(args):
            token = args[index]
            if token == "-print":
                saw_print = True
                index += 1
                continue
            if token in {"-type", "-name", "-maxdepth", "-mindepth"}:
                if index + 1 >= len(args):
                    return False
                if token == "-type" and args[index + 1] not in {"f", "d", "l"}:
                    return False
                if token == "-name":
                    pattern = args[index + 1]
                    if (any(mark in pattern for mark in ("$", "`", "?", "[", "]", "/", "\\", "\n", "\r"))
                            or pattern in {".", ".."}
                            or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*\*", pattern)):
                        return False
                if token in {"-type", "-name"}:
                    saw_default_filter = True
                if token in {"-maxdepth", "-mindepth"} and not re.fullmatch(r"[0-9]+", args[index + 1]):
                    return False
                index += 2
                continue
            if token == "-o":
                if index + 1 >= len(args) or args[index + 1] in {"-o", "-print"}:
                    return False
                index += 1
                continue
            return False
        return saw_print or saw_default_filter
    if command == "go":
        if not args or args[0] != "list":
            return False
        index = 1
        saw_format = False
        packages = []
        while index < len(args):
            token = args[index]
            if token in {"-f", "--format"} and index + 1 < len(args):
                if args[index + 1] not in {"{{.Dir}}", "{{.GoFiles}}"}:
                    return False
                saw_format = True
                index += 2
                continue
            if token.startswith("--format="):
                if token.split("=", 1)[1] not in {"{{.Dir}}", "{{.GoFiles}}"}:
                    return False
                saw_format = True
                index += 1
                continue
            if token.startswith("-") or not re.fullmatch(r"[A-Za-z0-9_./+@:-]+", token) or ".." in token:
                return False
            packages.append(token)
            index += 1
        return saw_format and bool(packages)
    if command == "gofmt":
        if len(args) < 2 or len(args) > 17 or args[0] != "-d":
            return False
        paths = args[1:]
        return all(
            not os.path.isabs(path) and
            path.endswith(".go") and
            approved_read_path(path, roots)
            for path in paths
        )
    return False

GO_TEST_VERIFICATION = VERIFICATION
GO_VET_VERIFICATION = VERIFICATION

def bounded_go_package_literal(value):
    if value == "./...":
        return True
    if not value.startswith("./"):
        return False
    components = value[2:].split("/")
    if components[-1] == "...":
        components = components[:-1]
    return bool(components) and all(
        component not in {"", ".", "..", "..."} and
        re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.-]*", component)
        for component in components
    )

def bounded_go_capture_sink(parsed, capture_index):
    if parsed[capture_index] != ">" or capture_index + 1 >= len(parsed):
        return False
    sink = parsed[capture_index + 1]
    if parsed[capture_index + 2:] != ["2", ">&", "1"]:
        return False
    if not os.path.isabs(sink) or os.path.normpath(sink) != sink:
        return False
    if not os.path.isdir("/tmp") or os.path.islink("/tmp") or os.path.realpath("/tmp") != "/tmp":
        return False
    if not sink.startswith("/tmp" + os.sep) or os.path.realpath(sink) != sink:
        return False
    if os.path.lexists(sink) and (os.path.islink(sink) or not os.path.isfile(sink)):
        return False
    parent = os.path.dirname(sink)
    return os.path.isdir(parent) and not os.path.islink(parent) and os.path.realpath(parent) == parent

def bounded_go_test_capture(value):
    """Admit only coordinator-owned bounded go-test output capture."""
    if os.environ.get("CODEX_HOOK_IS_SUBAGENT") == "true":
        return False
    parsed = tokenize(value)
    if parsed is None or len(parsed) < 3 or parsed[:2] != ["go", "test"]:
        return False
    if any(any(mark in token for mark in ("$", "`")) for token in parsed):
        return False
    capture_indexes = [
        index for index, token in enumerate(parsed)
        if (token == ">" and index + 1 < len(parsed) and parsed[index + 1] != "&") or
        (token == "|" and index + 1 < len(parsed) and parsed[index + 1] == "tee")
    ]
    if len(capture_indexes) != 1:
        return False
    capture_index = capture_indexes[0]
    test_args = parsed[2:capture_index]
    if len(test_args) > 32:
        return False
    shell_tokens = {";", "&", "&&", "|", "||", "(", ")", ">", ">>", ">|", "<", "<<", "<<<", ">&", "<&"}
    if any(token in shell_tokens for token in test_args):
        return False
    position = 0
    saw_package = False
    package_count = 0
    saw_count = False
    saw_timeout = False
    while position < len(test_args):
        token = test_args[position]
        if not token or len(token) > 512 or any(ord(char) < 32 or ord(char) == 127 for char in token):
            return False
        if token == "-count=2":
            saw_count = True
            position += 1
            continue
        if token.startswith("-timeout="):
            duration = token.split("=", 1)[1]
            match = re.fullmatch(r"([0-9]+)(ms|s|m)", duration)
            if not match or int(match.group(1)) <= 0 or (
                (match.group(2) == "ms" and int(match.group(1)) > 120000) or
                (match.group(2) == "s" and int(match.group(1)) > 120) or
                (match.group(2) == "m" and int(match.group(1)) > 2)
            ):
                return False
            saw_timeout = True
            position += 1
            continue
        if token == "-tags":
            if position + 1 >= len(test_args) or test_args[position + 1] != "with_libav":
                return False
            position += 2
            continue
        if token == "-run":
            if position + 1 >= len(test_args):
                return False
            run_pattern = test_args[position + 1]
            if len(run_pattern) > 128 or re.fullmatch(r"\^Test[A-Za-z0-9_./-]*", run_pattern) is None:
                return False
            position += 2
            continue
        if token.startswith("-run="):
            run_pattern = token.split("=", 1)[1]
            if len(run_pattern) > 128 or re.fullmatch(r"\^Test[A-Za-z0-9_./-]*", run_pattern) is None:
                return False
            position += 1
            continue
        if token.startswith("-") or not bounded_go_package_literal(token):
            return False
        saw_package = True
        package_count += 1
        position += 1
    if not saw_package or package_count != 1 or not saw_count or not saw_timeout:
        return False
    return bounded_go_capture_sink(parsed, capture_index)

def bounded_go_vet_capture(value):
    """Admit only coordinator-owned bounded go-vet output capture."""
    if os.environ.get("CODEX_HOOK_IS_SUBAGENT") == "true":
        return False
    parsed = tokenize(value)
    if parsed is None or len(parsed) < 4 or parsed[:2] != ["go", "vet"]:
        return False
    if any(any(mark in token for mark in ("$", "`")) for token in parsed):
        return False
    capture_indexes = [
        index for index, token in enumerate(parsed)
        if (token == ">" and index + 1 < len(parsed) and parsed[index + 1] != "&") or
        (token == "|" and index + 1 < len(parsed) and parsed[index + 1] == "tee")
    ]
    if len(capture_indexes) != 1:
        return False
    capture_index = capture_indexes[0]
    packages = parsed[2:capture_index]
    if not packages or len(packages) > 16 or not all(bounded_go_package_literal(package) for package in packages):
        return False
    return bounded_go_capture_sink(parsed, capture_index)


def safe_ledger_append_invocation(raw_text):
    """Allow shell-quoted literal ledger data without allowing expansion."""
    try:
        lexer = shlex.shlex(raw_text, posix=False, punctuation_chars=True)
        lexer.whitespace_split = True
        tokens = list(lexer)
    except ValueError:
        return False
    if len(tokens) != 3 or tokens[1] != "ledger-append":
        return False
    payload = tokens[2]
    single = False
    double = False
    escaped = False
    for char in payload:
        if escaped:
            escaped = False
            continue
        if char == "\\":
            escaped = True
            continue
        if char == "'" and not double:
            single = not single
            continue
        if char == '"' and not single:
            double = not double
            continue
        if char in {"$", "`"} and not single:
            return False
    return not single and not double and not escaped


def canonical_high_level_append(tokens, raw_text=""):
    # Raw shell redirection cannot prove the lock, prefix, size preflight, and
    # anchor publication performed by the canonical lifecycle command. Keep
    # all `printf|echo|cat >> high_level_log.md` forms unknown; only the
    # canonical `eci-active ledger-append <one-line-entry>` control route is
    # admitted by inspect() below.
    return False


def git_branch_or_remote_read_only(subcommand, args):
    global_options = {
        "-C", "-c", "--config-env", "--git-dir", "--work-tree", "--exec-path",
        "--namespace", "--super-prefix",
    }
    if any(token in global_options or token.startswith(("-C", "--config-env=", "--git-dir=", "--work-tree=", "--exec-path=", "--namespace=", "--super-prefix=")) for token in args):
        return False
    if subcommand == "branch":
        # A bare branch listing and option-only inspection are read-only.  Any
        # positional branch name or known branch mutation is unknown.  The
        # bounded `--contains <commit-ish>` query is also a read-only branch
        # inspection used by coordinators to locate a reviewed commit.
        index = 0
        while index < len(args):
            token = args[index]
            if token in BRANCH_MUTATORS or any(token.startswith(option + "=") for option in BRANCH_MUTATORS):
                return False
            if token == "--contains":
                if (index + 1 >= len(args) or
                        not re.fullmatch(r"(?:[0-9A-Fa-f]{7,64}|HEAD(?:~[0-9]+|\\^[0-9]+)?)", args[index + 1])):
                    return False
                index += 2
                continue
            if token.startswith("--contains="):
                if not re.fullmatch(r"--contains=(?:[0-9A-Fa-f]{7,64}|HEAD(?:~[0-9]+|\\^[0-9]+)?)", token):
                    return False
                index += 1
                continue
            if not token.startswith("-"):
                return False
            index += 1
        return True
    if subcommand == "remote":
        if not args or args == ["-v"] or args == ["--verbose"]:
            return True
        action = args[0]
        if action in REMOTE_MUTATORS:
            return False
        if action == "show":
            return True
        if action == "get-url":
            return True
        return False
    return None


def direct_commit_spelling(text):
    return bool(re.match(r"^git[ \t]+commit(?:[ \t]|$)", text))


def safe_commit_args(args):
    index = 0
    while index < len(args):
        token = args[index]
        if token == "--":
            return False
        if token in COMMIT_FLAG_OPTIONS:
            index += 1
            continue
        if token in COMMIT_VALUE_OPTIONS:
            if index + 1 >= len(args):
                return False
            index += 2
            continue
        if token.startswith(COMMIT_VALUE_PREFIXES):
            index += 1
            continue
        if token.startswith("-m") and len(token) > 2:
            index += 1
            continue
        if token.startswith("-S"):
            index += 1
            continue
        if token.startswith("-") and len(token) > 1:
            # Accept only a bounded cluster of ordinary short flags. A
            # cluster may contain -m or -S only when its value is attached.
            cluster = token[1:]
            cursor = 0
            while cursor < len(cluster):
                flag = cluster[cursor]
                if flag in "avsqeio":
                    cursor += 1
                    continue
                if flag in "mS":
                    if cursor + 1 == len(cluster):
                        if index + 1 >= len(args):
                            return False
                        index += 2
                    else:
                        index += 1
                    break
                return False
            else:
                index += 1
            continue
        return False
    return True


def safe_prep_args(subcommand, args):
    """Admit only explicit relative path preparation, never pathspec magic."""
    if subcommand == "restore":
        if args[:2] != ["--staged", "--"] or len(args) < 3:
            return False
        paths = args[2:]
    else:
        if not args or args[0] != "--" or len(args) < 2:
            return False
        paths = args[1:]
        if subcommand == "mv" and len(paths) != 2:
            return False
        if subcommand != "mv" and not paths:
            return False
    for path in paths:
        if not path or os.path.isabs(path) or path in {".", ".."}:
            return False
        if any(mark in path for mark in ("$", "`", "\n", "\r", "*", "?", "[", "]")):
            return False
        components = path.split("/")
        if any(component in {"", ".", ".."} for component in components):
            return False
        if path.startswith(":") or any(component.startswith(":") for component in components):
            return False
    return True


RESET_FLAGS = {
    "--soft", "--mixed", "--hard", "--merge", "--keep", "--quiet", "-q",
    "--recurse-submodules", "--no-recurse-submodules",
}


def safe_reset_args(args):
    for token in args:
        if token == "--":
            return True
        if token.startswith("-"):
            if token not in RESET_FLAGS:
                return False
            continue
        if any(mark in token for mark in ("$", "`", "(", ")", ";", "|", "<", ">")):
            return False
    return True


WORKTREE_MUTATORS = {"add", "remove", "move", "prune", "lock", "unlock", "repair"}


def safe_worktree_args(args):
    return bool(args) and args[0] in WORKTREE_MUTATORS


def literal_command(value, inherited_assignments=False, inherited_injection=False):
    # Keep the original shell spelling in this parser.  The outer acceptance
    # boundary rejects unquoted expansion, but a quoted literal '$' or '`' is
    # valid data in a reviewed search/pattern argument.  Do not repeat the
    # old post-shlex blanket check, which lost quote context and overblocked
    # those benign commands.
    if value is None or any(mark in value for mark in ("\n", "\r")):
        return UNKNOWN
    if bounded_go_test_capture(value):
        return GO_TEST_VERIFICATION
    if bounded_go_vet_capture(value):
        return GO_VET_VERIFICATION
    parsed = tokenize(value)
    if parsed is None:
        return UNKNOWN
    parts = bounded_batch_segments(parsed)
    if parts is None:
        return UNKNOWN
    return combine(inspect(part, 1, inherited_assignments, inherited_injection) for part in parts)


def inspect(segment, depth=0, inherited_assignments=False, inherited_injection=False):
    if depth > 6:
        return UNKNOWN
    index = 0
    saw_assignment = inherited_assignments
    saw_injection = inherited_injection
    while index < len(segment) and assignment(segment[index]):
        name, _, _ = segment[index].partition("=")
        saw_assignment = True
        saw_injection = saw_injection or name in EXECUTION_CONTEXT_NAMES
        index += 1
    if index >= len(segment):
        return READ_ONLY
    command = os.path.basename(segment[index])
    if "/" in segment[index] and not (
        real_eci_command(segment[index]) or real_review_gate_command(segment[index])
    ):
        return UNKNOWN
    if command in {"source", "."}:
        return shell_script_control(segment, index, saw_injection)
    if command == "env":
        # Environment grammar and context assignments are checked by the
        # role-neutral boundary before this acceptance classifier runs.
        # Preserve inherited-context tracking while inspecting the child.
        if segment[index + 1:index + 3] != ["-u", "CODEX_ROLE"]:
            return UNKNOWN
        saw_assignment = True
        if any(token in {"-S", "--split-string"} for token in segment[index + 1:]):
            saw_injection = True
        for option_index, option in enumerate(segment[index + 1:-1], index + 1):
            if option in {"-u", "--unset"} and segment[option_index + 1] in EXECUTION_CONTEXT_NAMES:
                saw_injection = True
        if any(
            token in {"-i", "--ignore-environment", "-u", "--unset"}
            or token.startswith("-u")
            for token in segment[index + 1:]
        ):
            saw_assignment = True
        index = skip_options(segment, index + 1, with_argument={"-C", "--chdir", "-u", "--unset"}, without_argument={"-i", "--ignore-environment"})
        if index is None:
            return UNKNOWN
        while index < len(segment) and assignment(segment[index]):
            name, _, _ = segment[index].partition("=")
            saw_assignment = True
            saw_injection = saw_injection or name in EXECUTION_CONTEXT_NAMES
            index += 1
        return inspect(segment[index:], depth + 1, saw_assignment, saw_injection)
    if command in {"command", "builtin", "exec"}:
        saw_assignment = True
        if command == "command" and "-p" in segment[index + 1:]:
            # command -p searches the shell's default PATH, not necessarily
            # the PATH used by this hook; do not claim executable identity.
            saw_assignment = True
        args = {"command": ((), ("-p", "-v", "-V")), "builtin": ((), ()), "exec": (("-a",), ("-c", "-l"))}[command]
        index = skip_options(segment, index + 1, with_argument=args[0], without_argument=args[1])
        if index is None:
            return UNKNOWN
        return inspect(segment[index:], depth + 1, saw_assignment, saw_injection)
    if command in {"sudo", "doas", "nohup", "setsid"}:
        saw_assignment = True
        if command in {"sudo", "doas"}:
            # Privilege wrappers may apply a secure_path unknown to the hook.
            saw_assignment = True
        index = skip_options(
            segment,
            index + 1,
            with_argument={"-u", "--user", "-g", "--group", "-C", "--chdir", "-D"},
            without_argument={"-n", "--non-interactive", "--preserve-env", "-f", "--fork"},
        )
        if index is None:
            return UNKNOWN
        return inspect(segment[index:], depth + 1, saw_assignment, saw_injection)
    if command in {"timeout", "nice", "chronic", "systemd-run", "prlimit", "time"}:
        saw_assignment = True
        index = skip_options(segment, index + 1, with_argument={"-k", "--kill-after", "-s", "--signal", "-n", "--adjustment", "-p", "--property", "--unit", "--setenv", "--working-directory", "-C", "--chdir"}, without_argument={"--foreground", "--preserve-status", "--scope", "--user", "--system", "--wait", "--pipe", "--quiet"})
        if index is None:
            return UNKNOWN
        if command == "timeout" and index < len(segment):
            index += 1
        elif command == "timeout":
            return UNKNOWN
        return inspect(segment[index:], depth + 1, saw_assignment, saw_injection)
    if command == "xargs":
        saw_assignment = True
        index = skip_options(
            segment,
            index + 1,
            with_argument={"-a", "-d", "-E", "-I", "-L", "-n", "-P", "--delimiter", "--eof", "--replace", "--max-lines", "--max-args", "--max-procs"},
            without_argument={"-0", "-r", "--null", "--no-run-if-empty", "--", "--verbose", "--interactive"},
        )
        if index is None:
            return UNKNOWN
        return inspect(segment[index:], depth + 1, saw_assignment, saw_injection)
    if command == "eci-active":
        if os.environ.get("CODEX_HOOK_IS_SUBAGENT") == "true":
            return UNKNOWN
        lifecycle = segment[index + 1:]
        if saw_assignment or not real_eci_command(segment[index]):
            return UNKNOWN
        if any(mark in token for token in lifecycle for mark in ("$", "`")) and not (
            lifecycle[:1] == ["ledger-append"] and
            len(lifecycle) == 2 and
            safe_ledger_append_invocation(raw_command_text)
        ):
            return UNKNOWN
        if lifecycle in (["--help"], ["-h"], ["status"]):
            # ECI status/help is a coordinator peer route, not generic
            # read-only inspection. The route below binds the executable to
            # one canonical Codex/Kimi path and its expected digest.
            return UNKNOWN
        if lifecycle[0] in {"on", "off", "wait", "resume"} and len(lifecycle) == 2:
            return CONTROL
        if lifecycle[0] == "nested-enter" and len(lifecycle) in {3, 4}:
            return CONTROL
        if lifecycle[0] == "nested-exit" and len(lifecycle) == 1:
            return CONTROL
        if lifecycle[0] == "nested-accept" and len(lifecycle) == 1:
            return CONTROL
        if lifecycle[0] == "manifest-write" and len(lifecycle) == 2:
            return CONTROL
        if lifecycle[0] == "ledger-append" and len(lifecycle) == 2:
            return CONTROL
        return UNKNOWN
    if command in {"bash", "sh", "dash", "zsh"}:
        if saw_injection:
            return UNKNOWN
        shell_args = segment[index + 1:]
        for option_index, option in enumerate(segment[index + 1:], index + 1):
            if option in {"-c", "-lc", "-cl"} or (option.startswith("-") and not option.startswith("--") and "c" in option[1:]):
                if saw_injection or option_index + 1 >= len(segment):
                    return UNKNOWN
                payload = segment[option_index + 1]
                nested = tokenize(payload)
                # The only shell payload admitted here is the existing,
                # canonical lifecycle source route. Everything else remains
                # opaque and unknown; do not classify arbitrary nested text.
                if (nested is None or not nested or nested[0] not in {"source", "."}
                        or any(token in {";", "&", "&&", "|", "||", "(", ")"}
                               for token in nested)):
                    return UNKNOWN
                return literal_command(payload, saw_assignment, saw_injection)
        scripted = shell_script_control(segment, index, saw_injection)
        if scripted != UNKNOWN:
            return scripted
        if "-n" in shell_args:
            syntax_seen = False
            script_seen = False
            end_options = False
            for token in shell_args:
                if not end_options and token == "-n":
                    syntax_seen = True
                    continue
                if not end_options and token == "--":
                    end_options = True
                    continue
                if not end_options and token.startswith("-"):
                    return UNKNOWN
                if any(mark in token for mark in ("$", "`")):
                    return UNKNOWN
                script_seen = True
            return READ_ONLY if syntax_seen and script_seen else UNKNOWN
        if any(token.startswith("-") for token in shell_args):
            return UNKNOWN
        return READ_ONLY if len(shell_args) == 1 and known_test_script(shell_args[0]) else UNKNOWN
    if command == "eval":
        # eval is arbitrary shell indirection; its payload is never admitted
        # through the read-only classifier.
        return UNKNOWN
    if command == "sed":
        return READ_ONLY if bounded_sed_read_only(segment, index) else UNKNOWN
    if command == "eci-review-gate.sh" and real_review_gate_command(segment[index]):
        return READ_ONLY if segment[index + 1:] in (["--help"], ["-h"]) else UNKNOWN
    if command in READ_ONLY_COMMANDS:
        if command == "gitleaks" and any(
            token == "-r" or token == "--report-path" or token.startswith("--report-path=")
            for token in segment[index + 1:]
        ):
            return UNKNOWN
        return READ_ONLY if bounded_read_only_args(command, segment[index + 1:]) else UNKNOWN
    if command != "git":
        return UNKNOWN
    if not trusted_git_token(segment[index]):
        return UNKNOWN
    if bounded_git_c_status(segment, index):
        return READ_ONLY
    if bounded_git_c_read_only(segment, index):
        return READ_ONLY
    index += 1
    repo_context_changed = False
    git_global_seen = False
    while index < len(segment):
        token = segment[index]
        if token in {"-C", "--git-dir", "--work-tree"}:
            repo_context_changed = True
            git_global_seen = git_global_seen or token != "-C"
            if index + 1 >= len(segment):
                return UNKNOWN
            index += 2
        elif token in {"-c", "--namespace", "--config-env", "--exec-path"}:
            git_global_seen = True
            if index + 1 >= len(segment):
                return UNKNOWN
            index += 2
        elif token.startswith(("--git-dir=", "--work-tree=")):
            repo_context_changed = True
            git_global_seen = True
            index += 1
        elif token.startswith(("--config-env=", "--namespace=", "--exec-path=")):
            git_global_seen = True
            index += 1
        elif token == "--":
            index += 1
        elif token.startswith("-"):
            return UNKNOWN
        else:
            if any(mark in token for mark in ("$", "`", "$((")):
                return UNKNOWN
            if token == "commit":
                # Do not accept a commit reached through an inherited
                # environment, wrapper, alternate repository, or git global
                # option.  The coordinator must run the canonical git command
                # from the reviewed cwd.
                return UNKNOWN if (
                    not direct_commit_spelling(text)
                    or saw_assignment
                    or repo_context_changed
                    or git_global_seen
                    or INHERITED_GIT_CONTEXT
                    or not safe_commit_args(segment[index + 1:])
                ) else COMMIT
            if token in {"add", "rm", "mv"}:
                return UNKNOWN if (
                    saw_assignment or repo_context_changed or git_global_seen
                    or INHERITED_GIT_CONTEXT
                    or not safe_prep_args(token, segment[index + 1:])
                ) else PREP
            if token == "restore":
                return UNKNOWN if (
                    saw_assignment or repo_context_changed or git_global_seen
                    or INHERITED_GIT_CONTEXT
                    or not safe_prep_args(token, segment[index + 1:])
                ) else PREP
            if token == "reset":
                return UNKNOWN if (
                    saw_assignment or git_global_seen or INHERITED_GIT_CONTEXT
                    or not safe_reset_args(segment[index + 1:])
                ) else RESET
            if token == "worktree":
                return UNKNOWN if (
                    saw_assignment or git_global_seen or INHERITED_GIT_CONTEXT
                    or not safe_worktree_args(segment[index + 1:])
                ) else WORKTREE
            if token == "submodule":
                return READ_ONLY if (
                    not saw_assignment and not repo_context_changed and not git_global_seen
                    and not INHERITED_GIT_CONTEXT and segment[index + 1:] == ["status"]
                ) else UNKNOWN
            branch_remote_state = git_branch_or_remote_read_only(token, segment[index + 1:])
            if branch_remote_state is False:
                return UNKNOWN
            if branch_remote_state is True:
                return UNKNOWN if (
                    saw_assignment or repo_context_changed or git_global_seen or INHERITED_GIT_CONTEXT
                ) else READ_ONLY
            if token not in GIT_READ_ONLY:
                return UNKNOWN
            return UNKNOWN if (
                saw_assignment or repo_context_changed or git_global_seen or INHERITED_GIT_CONTEXT
            ) else (READ_ONLY if safe_read_only_args(segment[index + 1:]) else UNKNOWN)
    return UNKNOWN


text = sys.argv[1]
raw_command_text = text
if "\n" in text or "\r" in text:
    print(UNKNOWN)
    raise SystemExit(0)
tokens = tokenize(text)
if tokens is None:
    print(UNKNOWN)
    raise SystemExit(0)

if bounded_git_diff_sed_pipeline(tokens):
    print(READ_ONLY)
    raise SystemExit(0)

if bounded_go_test_capture(text):
    print(GO_TEST_VERIFICATION)
    raise SystemExit(0)

if bounded_go_vet_capture(text):
    print(GO_VET_VERIFICATION)
    raise SystemExit(0)

configured_home = os.path.realpath(os.path.abspath(
    os.environ.get("CODEX_HOME") or os.path.join(os.environ.get("HOME", ""), ".codex")
))
configured_eci = os.path.realpath(os.path.normpath(os.path.join(configured_home, "bin", "eci-active")))

def canonical_eci(token):
    expanded = os.path.expanduser(token)
    if token == "eci-active":
        resolved = shutil.which(token)
        return bool(resolved) and os.path.realpath(os.path.abspath(resolved)) == configured_eci
    return os.path.isfile(expanded) and os.path.realpath(os.path.abspath(expanded)) == configured_eci

# The coordinator's direct teardown command is a control action, not an
# unknown shell command. Keep this recognizer exact: no wrappers, assignments,
# chains, or extra arguments may turn into an acceptance bypass.
if len(tokens) == 3 and tokens[1] == "off" and canonical_eci(tokens[0]):
    print(CONTROL)
    raise SystemExit(0)

# The main/orchestrator may invoke the canonical review gate directly.  Keep
# this exact and bounded: only the canonical executable, one supported phase,
# and one syntactically valid session id qualify; wrappers are handled by the
# separate shell-control path and remain subject to its ownership checks.
if len(tokens) == 3 and real_review_gate_command(tokens[0]) and \
   tokens[1] in {"commit", "final", "off", "prewrite"} and \
   re.match(r"^[A-Za-z0-9][A-Za-z0-9_-]*$", tokens[2]):
    print(CONTROL)
    raise SystemExit(0)

if canonical_high_level_append(tokens, text):
    print(CONTROL)
    raise SystemExit(0)
parts = bounded_batch_segments(tokens)
print(UNKNOWN if parts is None else combine(inspect(part) for part in parts))
PY
}

git_mutation_specs() {
  # A mutation parser must fail closed when shell expansion/operators make the
  # Git command identity ambiguous.  Keep this scoped to Git mutations: safe
  # non-Git shell expansion (for example printf with a command substitution)
  # remains ordinary inactive-session behavior.
  if command_has_unsafe_shell_syntax "$command"; then
    printf '!unsupported\n'
    return 0
  fi
  python3 - "$command" "${cwd:-$PWD}" <<'PY'
import os
import re
import shlex
import sys

command = sys.argv[1]
cwd = sys.argv[2] or os.getcwd()
MUTATING_WORKTREE = {"add", "remove", "move", "prune", "lock", "unlock", "repair"}
MUTATING_PREP = {"add", "rm", "mv", "restore"}
OPERATORS = {";", "&", "&&", "|", "||", "(", ")", ">", ">>", "<", "<<", ">|"}
SIMPLE_TEXT_COMMANDS = {"cat", "echo", "grep", "printf", "rg", "sed", "awk", "head", "tail"}
COMMIT_FLAG_OPTIONS = {
    "-a", "--all", "--amend", "--no-verify", "--verify", "--signoff", "-s",
    "--no-signoff", "--no-edit", "--edit", "--allow-empty", "--allow-empty-message",
    "--no-post-rewrite", "--post-rewrite", "--reset-author", "--quiet", "-q",
    "--verbose", "-v", "-vv", "--no-status", "--status", "--dry-run", "--only",
    "--include", "-i", "-o", "--no-gpg-sign", "--gpg-sign",
}
COMMIT_VALUE_OPTIONS = {
    "-m", "--message", "-F", "--file", "--author", "--date", "--cleanup",
    "--template", "--reuse-message", "-C", "--reedit-message", "-c",
    "--fixup", "--squash", "--trailer", "--pathspec-from-file",
}
COMMIT_VALUE_PREFIXES = tuple(
    option + "=" for option in COMMIT_VALUE_OPTIONS if option.startswith("--")
)


def resolve(path, base):
    path = os.path.expanduser(path)
    if os.path.isabs(path):
        return os.path.normpath(path)
    return os.path.normpath(os.path.join(base, path))


def emit_unsupported():
    print("!unsupported")


def direct_commit_spelling(value):
    return bool(re.match(r"^git[ \t]+commit(?:[ \t]|$)", value))


def safe_commit_args(args):
    index = 0
    while index < len(args):
        token = args[index]
        if token == "--":
            return False
        if token in COMMIT_FLAG_OPTIONS:
            index += 1
            continue
        if token in COMMIT_VALUE_OPTIONS:
            if index + 1 >= len(args):
                return False
            index += 2
            continue
        if token.startswith(COMMIT_VALUE_PREFIXES):
            index += 1
            continue
        if token.startswith("-m") and len(token) > 2:
            index += 1
            continue
        if token.startswith("-S"):
            index += 1
            continue
        if token.startswith("-") and len(token) > 1:
            cluster = token[1:]
            cursor = 0
            while cursor < len(cluster):
                flag = cluster[cursor]
                if flag in "avsqeio":
                    cursor += 1
                    continue
                if flag in "mS":
                    if cursor + 1 == len(cluster):
                        if index + 1 >= len(args):
                            return False
                        index += 2
                    else:
                        index += 1
                    break
                return False
            else:
                index += 1
            continue
        return False
    return True


def safe_prep_args(subcommand, args):
    if subcommand == "restore":
        if args[:2] != ["--staged", "--"] or len(args) < 3:
            return False
        paths = args[2:]
    else:
        if not args or args[0] != "--" or len(args) < 2:
            return False
        paths = args[1:]
        if subcommand == "mv" and len(paths) != 2:
            return False
    for path in paths:
        if not path or os.path.isabs(path) or path in {".", ".."}:
            return False
        if any(mark in path for mark in ("$", "`", "\n", "\r", "*", "?", "[", "]")):
            return False
        components = path.split("/")
        if any(component in {"", ".", ".."} for component in components):
            return False
        if path.startswith(":") or any(component.startswith(":") for component in components):
            return False
    return True


try:
    lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    tokens = list(lexer)
except ValueError:
    emit_unsupported()
    raise SystemExit(0)

if not tokens:
    raise SystemExit(0)

# The approval is intentionally only for one direct git invocation.  A shell
# chain, assignment, wrapper, redirection, or nested shell containing a
# mutating Git verb is not an exact command boundary and can never consume the
# user approval.  Unrelated read-only chains remain with the normal classifier.
if any(token in OPERATORS for token in tokens):
    for index, token in enumerate(tokens):
        if token == "git" and any(subcommand in tokens[index + 1:] for subcommand in {"reset", "worktree", "commit", "add", "rm", "mv", "restore"}):
            emit_unsupported()
            raise SystemExit(0)
        if re.search(r"(?<![A-Za-z0-9_])git(?:\s+[^;&|()]+)*\s+(?:reset|worktree|commit|add|rm|mv|restore)(?:\s|$)", token):
            emit_unsupported()
            raise SystemExit(0)
    raise SystemExit(0)

first = os.path.basename(tokens[0])
if first != "git" or tokens[0] != "git":
    if first in SIMPLE_TEXT_COMMANDS:
        raise SystemExit(0)
    exact_direct = (
        len(tokens) >= 2 and tokens[0] == "git" and tokens[1] == "commit"
        and direct_commit_spelling(command) and safe_commit_args(tokens[2:])
    )
    if first == "git" and not exact_direct and any(subcommand in tokens[1:] for subcommand in {"reset", "worktree", "commit", "add", "rm", "mv", "restore"}):
        emit_unsupported()
        raise SystemExit(0)
    for index, token in enumerate(tokens):
        if token == "git" and any(subcommand in tokens[index + 1:] for subcommand in {"reset", "worktree", "commit", "add", "rm", "mv", "restore"}):
            emit_unsupported()
            raise SystemExit(0)
        if re.search(r"(?<![A-Za-z0-9_])git(?:\s+[^;&|()]+)*\s+(?:reset|worktree|commit|add|rm|mv|restore)(?:\s|$)", token):
            emit_unsupported()
            raise SystemExit(0)
    raise SystemExit(0)

repo_dir = cwd
index = 1
while index < len(tokens):
    token = tokens[index]
    if token == "-C":
        if index + 1 >= len(tokens):
            emit_unsupported()
            raise SystemExit(0)
        repo_dir = resolve(tokens[index + 1], repo_dir)
        index += 2
        continue
    if token.startswith("-C") and len(token) > 2:
        repo_dir = resolve(token[2:], repo_dir)
        index += 1
        continue
    if token in {"--", "--literal-pathspecs", "--glob-pathspecs", "--noglob-pathspecs"}:
        index += 1
        continue
    if token in {"-c", "--config-env", "--exec-path", "--git-dir", "--namespace", "--super-prefix", "--work-tree"} or token.startswith(("--config-env=", "--exec-path=", "--git-dir=", "--namespace=", "--super-prefix=", "--work-tree=")):
        if any(subcommand in tokens[index + 1:] for subcommand in {"reset", "worktree", "commit", "add", "rm", "mv", "restore"}):
            emit_unsupported()
        raise SystemExit(0)
    if token.startswith("-"):
        # A global option with unknown arity could hide the subcommand.
        if any(subcommand in tokens[index + 1:] for subcommand in {"reset", "worktree", "commit", "add", "rm", "mv", "restore"}):
            emit_unsupported()
        raise SystemExit(0)
    break

if index >= len(tokens):
    raise SystemExit(0)

if tokens[index] == "reset":
    sys.stdout.write("reset\n" + repo_dir + "\n")
    raise SystemExit(0)

if tokens[index] in {"add", "rm", "mv", "restore"}:
    if index == 1 and tokens[0] == "git" and safe_prep_args(tokens[index], tokens[index + 1:]):
        sys.stdout.write("prep\n" + repo_dir + "\n")
    else:
        emit_unsupported()
    raise SystemExit(0)

# The hidden commit workaround is deliberately limited to one direct git
# invocation. Safe post-subcommand commit options are allowed, but -C/global
# context options, wrappers, assignments, aliases, and shell chains remain
# outside the approval boundary.
if tokens[index] == "commit":
    if index == 1 and tokens[0] == "git" and direct_commit_spelling(command) and safe_commit_args(tokens[index + 1:]):
        sys.stdout.write("commit\n" + repo_dir + "\n")
    else:
        emit_unsupported()
    raise SystemExit(0)

if tokens[index] == "worktree":
    index += 1
    if index < len(tokens) and tokens[index] in MUTATING_WORKTREE:
        sys.stdout.write("worktree\n" + repo_dir + "\n")
    elif index < len(tokens) and tokens[index] == "list":
        raise SystemExit(0)
    elif index < len(tokens) and tokens[index].startswith("-"):
        if any(subcommand in tokens[index + 1:] for subcommand in MUTATING_WORKTREE):
            emit_unsupported()
    raise SystemExit(0)

# Non-mutating git commands are handled by the normal classifier.
PY
}

git_mutation_denied() {
  local gate_operation="${operation:-${command_state:-unknown}}"
  local gate_repo="${repo_root:-${repo_dir:-${cwd:-<unknown>}}}"
  local gate_path="${marker:-${gate_repo}/.git-approval}" subject detail remediation
  subject="command=$(eci_command_identity_subject "${command:-}"),repo=$(eci_diagnostic_value "$gate_repo"),path=$(eci_diagnostic_value "$gate_path")"
  detail="git repository mutation denied: valid user authorization is required; missing or invalid authorization for operation=${gate_operation}/index"
  remediation="obtain coordinator ECI admission for this exact operation and repository, or provide the user-owned one-time approval artifact, then retry"
  deny "$(eci_diagnostic_reason "ECI_GIT_MUTATION_DENIED" "PreToolUse" "git-mutation" "$subject" "$detail" "$remediation")"
}

validate_git_approval_marker() {
  local marker="$1" operation="$2" repo_root="$3" git_dir="$4"
  local marker_command marker_reason approved_at claim
  local -a approval_lines=()

  [ -f "$marker" ] && [ ! -L "$marker" ] || git_mutation_denied
  [ "$(realpath -m -- "$marker" 2>/dev/null || true)" = "$marker" ] || git_mutation_denied
  [ "$(wc -c <"$marker" 2>/dev/null || printf 999999)" -le 4096 ] || git_mutation_denied
  [ "$(tail -c 1 -- "$marker" 2>/dev/null | od -An -t x1 | tr -d '[:space:]')" = 0a ] || git_mutation_denied
  mapfile -t approval_lines <"$marker" || git_mutation_denied
  [ "${#approval_lines[@]}" -eq 9 ] || git_mutation_denied
  for line in "${approval_lines[@]}"; do
    case "$line" in *$'\r'*|*$'\t'*) git_mutation_denied ;; esac
    LC_ALL=C printf '%s' "$line" | LC_ALL=C grep -q '[[:cntrl:]]' && git_mutation_denied
  done
  [ "${approval_lines[0]}" = 'schema: codex-user-git-approval/v1' ] || git_mutation_denied
  [ "${approval_lines[1]}" = 'authorized_by: user' ] || git_mutation_denied
  [ "${approval_lines[2]}" = "operation: $operation" ] || git_mutation_denied
  [ "${approval_lines[3]}" = "repo_root: $repo_root" ] || git_mutation_denied
  [ "${approval_lines[4]}" = "git_dir: $git_dir" ] || git_mutation_denied
  marker_command="${approval_lines[5]#command: }"
  [ "${approval_lines[5]}" = "command: $command" ] || git_mutation_denied
  [ "$marker_command" = "$command" ] || git_mutation_denied
  case "${approval_lines[6]}" in
    'reason: '*) marker_reason="${approval_lines[6]#reason: }" ;;
    *) git_mutation_denied ;;
  esac
  [ -n "$marker_reason" ] && [ "${#marker_reason}" -le 512 ] || git_mutation_denied
  [[ "${approval_lines[7]}" =~ ^approved_at:\ [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || git_mutation_denied
  [ "${approval_lines[8]}" = 'one_time: true' ] || git_mutation_denied

  # Approval files are user-owned control artifacts, never repository input.
  # A tracked or staged copy can be replayed by checkout/reset, so refuse it
  # before claiming or consuming the one-time marker.
  approval_rel="${marker#"$repo_root"/}"
  [ "$approval_rel" != "$marker" ] || git_mutation_denied
  if codex_git_safe -C "$repo_root" ls-files --error-unmatch -- "$approval_rel" >/dev/null 2>&1; then
    git_mutation_denied
  fi

  claim="$marker.claim"
  if [ -e "$claim" ] || [ -L "$claim" ]; then
    # A crashed callback may leave an empty claim directory.  Recover only an
    # empty, canonical, non-symlink claim older than the fixed bounded window;
    # fresh/non-empty/unknown claims remain fail-closed.
    claim_recovered=false
    if [ -d "$claim" ] && [ ! -L "$claim" ] &&
      [ "$(realpath -m -- "$claim" 2>/dev/null || true)" = "$claim" ]; then
      claim_mtime="$(stat -c '%Y' -- "$claim" 2>/dev/null || printf '')"
      claim_now="$(date +%s)"
      if [[ "$claim_mtime" =~ ^[0-9]+$ ]] && [ $((claim_now - claim_mtime)) -ge 600 ]; then
        if rmdir -- "$claim" 2>/dev/null; then
          claim_recovered=true
        fi
      fi
    fi
    [ "$claim_recovered" = true ] || git_mutation_denied
  fi
  mkdir -- "$claim" 2>/dev/null || git_mutation_denied
  # Re-read and validate after the atomic claim, so concurrent callbacks cannot
  # consume one user approval twice.  A failed validation leaves the marker in
  # place and removes only the claim directory.
  if ! validate_git_approval_lines "$marker" "$operation" "$repo_root" "$git_dir"; then
    rmdir -- "$claim" 2>/dev/null || true
    git_mutation_denied
  fi
  if ! rm -f -- "$marker"; then
    rmdir -- "$claim" 2>/dev/null || true
    git_mutation_denied
  fi
  # A successful one-time approval must not survive the command boundary as a
  # misleading untracked repository artifact.  Treat any residual path,
  # including a replacement symlink, as a failed consumption.
  [ ! -e "$marker" ] && [ ! -L "$marker" ] || {
    rmdir -- "$claim" 2>/dev/null || true
    git_mutation_denied
  }
  rmdir -- "$claim" 2>/dev/null || true
}

validate_git_approval_lines() {
  local marker="$1" operation="$2" repo_root="$3" git_dir="$4"
  local -a lines=()
  local reason
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  [ "$(realpath -m -- "$marker" 2>/dev/null || true)" = "$marker" ] || return 1
  mapfile -t lines <"$marker" || return 1
  [ "${#lines[@]}" -eq 9 ] || return 1
  [ "${lines[0]}" = 'schema: codex-user-git-approval/v1' ] || return 1
  [ "${lines[1]}" = 'authorized_by: user' ] || return 1
  [ "${lines[2]}" = "operation: $operation" ] || return 1
  [ "${lines[3]}" = "repo_root: $repo_root" ] || return 1
  [ "${lines[4]}" = "git_dir: $git_dir" ] || return 1
  [ "${lines[5]}" = "command: $command" ] || return 1
  case "${lines[6]}" in
    'reason: '*) reason="${lines[6]#reason: }" ;;
    *) return 1 ;;
  esac
  [ -n "$reason" ] && [ "${#reason}" -le 512 ] || return 1
  [[ "${lines[7]}" =~ ^approved_at:\ [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || return 1
  [ "${lines[8]}" = 'one_time: true' ] || return 1
}

consume_eci_commit_admission() {
  local marker="$1" root session_dir receipt claim claim_recovered=false
  local claim_mtime claim_now

  root="$(codex_proof_root)"
  [ -n "$root" ] || return 1
  [ "$marker" = "$root/$session_id/eci_active" ] || return 1
  session_dir="$root/$session_id"
  receipt="$session_dir/eci-commit-admitted"
  codex_eci_commit_admission_receipt_is_valid "$receipt" "$session_id" \
    "$session_dir/eci-required-critics.json" || return 1

  claim="$receipt.claim"
  if [ -e "$claim" ] || [ -L "$claim" ]; then
    # Recover only an empty, canonical claim left by a dead callback after the
    # bounded recovery window. Fresh, non-empty, or unknown claims deny.
    if [ -d "$claim" ] && [ ! -L "$claim" ] &&
      [ "$(realpath -m -- "$claim" 2>/dev/null || true)" = "$claim" ]; then
      claim_mtime="$(stat -c '%Y' -- "$claim" 2>/dev/null || true)"
      claim_now="$(date +%s)"
      if [[ "$claim_mtime" =~ ^[0-9]+$ ]] && [ "$((claim_now - claim_mtime))" -ge 600 ] &&
        rmdir -- "$claim" 2>/dev/null; then
        claim_recovered=true
      fi
    fi
    [ "$claim_recovered" = true ] || return 1
  fi
  mkdir -- "$claim" 2>/dev/null || return 1
  if ! codex_eci_commit_admission_receipt_is_valid "$receipt" "$session_id" \
    "$session_dir/eci-required-critics.json"; then
    rmdir -- "$claim" 2>/dev/null || true
    return 1
  fi
  if ! rm -f -- "$receipt"; then
    rmdir -- "$claim" 2>/dev/null || true
    return 1
  fi
  rmdir -- "$claim" 2>/dev/null || true
}

enforce_git_mutation_gate() {
  local specs=() operation repo_dir repo_root git_dir_raw git_dir marker specs_text

  if ! specs_text="$(git_mutation_specs)"; then
    git_mutation_denied
  fi
  if [ -n "$specs_text" ]; then
    mapfile -t specs <<<"$specs_text"
  fi
  [ "${#specs[@]}" -gt 0 ] || return 0
  if [ "${specs[0]}" = '!unsupported' ] || [ "${#specs[@]}" -ne 2 ]; then
    git_mutation_denied
  fi
  [ "${hook_is_subagent:-false}" != true ] || git_mutation_denied
  operation="${specs[0]}"
  repo_dir="${specs[1]}"
  case "$operation" in reset|worktree|commit|prep) ;; *) git_mutation_denied ;; esac
  if [ "${command_state:-unknown}" != "$operation" ]; then
    # Approval must never turn an UNKNOWN command or inherited Git context
    # into an allow.  The classifier ran before this gate and is authoritative
    # for every approved operation, not only the exceptional commit route.
    git_mutation_denied
  fi
  if [ "$operation" = prep ]; then
    # Preparation is a bounded coordinator route.  Inactive direct Git keeps
    # its ordinary behavior; an active ECI marker must be the single valid
    # coordinator marker bound to this cwd.  Workers are rejected above and
    # never reach this branch.
    if [ "${#review_markers[@]}" -eq 0 ]; then
      return 0
    fi
    [ "${#review_markers[@]}" -eq 1 ] || git_mutation_denied
    codex_eci_marker_is_valid_for_cwd "${review_markers[0]}" "$(codex_canonical_cwd "$cwd")" || git_mutation_denied
    git_mutation_approved=true
    return 0
  fi
  repo_root="$(codex_git_safe -C "$repo_dir" rev-parse --show-toplevel 2>/dev/null || true)"
  repo_root="$(realpath -m -- "$repo_root" 2>/dev/null || true)"
  [ -n "$repo_root" ] && [ -d "$repo_root" ] && [ ! -L "$repo_root" ] || git_mutation_denied
  git_dir_raw="$(codex_git_safe -C "$repo_root" rev-parse --absolute-git-dir 2>/dev/null || true)"
  git_dir="$(realpath -m -- "$git_dir_raw" 2>/dev/null || true)"
  [ -n "$git_dir" ] && [ -d "$git_dir" ] || git_mutation_denied
  case "$operation" in
    reset) marker="$repo_root/.git-reset-approved-once" ;;
    worktree) marker="$repo_root/.git-worktree-approved-once" ;;
    commit) marker="$repo_root/.git-commit-approved-once" ;;
  esac
  if [ "$operation" = commit ] && [ ! -e "$marker" ] && [ ! -L "$marker" ]; then
    [ ! -e "$marker.claim" ] && [ ! -L "$marker.claim" ] || git_mutation_denied
    # A coordinator-owned review-gate admission is a one-shot receipt bound
    # to the exact active session and live repository tuple. Consume it before
    # allowing the ordinary direct git invocation. Inactive commits remain
    # available without this receipt; hidden user approval remains the
    # exceptional bypass handled below.
    if [ "${#review_markers[@]}" -eq 1 ] &&
      consume_eci_commit_admission "${review_markers[0]}"; then
      git_mutation_approved=true
    fi
    return 0
  fi
  validate_git_approval_marker "$marker" "$operation" "$repo_root" "$git_dir"
  git_mutation_approved=true
}

maybe_enforce_git_mutation_gate() {
  # A validated coordinator peer lifecycle command may carry a literal
  # git-commit payload for approval; do not classify that payload as the
  # eventual repository mutation.
  if coordinator_peer_eci_route "$command"; then
    return 0
  fi
  case "$command" in
    *git*|*reset*|*worktree*) enforce_git_mutation_gate ;;
  esac
}

detect_uncapped_make() {
  [ -n "${command:-}" ] || return 0

  python3 - "$command" <<'PY'
from __future__ import annotations

import os
import shlex
import sys

command = sys.argv[1]
SEPARATORS = {";", "&", "&&", "|", "||"}
FINITE_BAD_LIMITS = {"", "infinity", "unlimited"}
SYSTEMD_VALUE_OPTIONS = {
    "--background",
    "--description",
    "--expand-environment",
    "--gid",
    "--host",
    "--json",
    "--machine",
    "--nice",
    "--service-type",
    "--setenv",
    "--slice",
    "--uid",
    "--unit",
    "--working-directory",
    "-E",
    "-H",
    "-M",
    "-u",
}
SYSTEMD_VALUE_PREFIXES = tuple(
    option + "=" for option in SYSTEMD_VALUE_OPTIONS if option.startswith("--")
)
TIME_VALUE_OPTIONS = {"--format", "--output", "-f", "-o"}
TIME_VALUE_PREFIXES = ("--format=", "--output=")


def tokenize(command_text: str) -> list[str] | None:
    try:
        lexer = shlex.shlex(command_text, posix=True, punctuation_chars=True)
        lexer.whitespace_split = True
        return list(lexer)
    except ValueError:
        return None


def basename(token: str) -> str:
    return os.path.basename(token)


def is_assignment(token: str) -> bool:
    name, separator, _ = token.partition("=")
    return (
        bool(separator)
        and bool(name)
        and name.replace("_", "A").isalnum()
        and not name[0].isdigit()
    )


def finite_limit(limit: str) -> bool:
    return limit.lower() not in FINITE_BAD_LIMITS


def memorymax_property(property_text: str) -> bool:
    name, separator, value = property_text.partition("=")
    return name == "MemoryMax" and bool(separator) and finite_limit(value)


def command_index(tokens: list[str]) -> int:
    index = 0
    while index < len(tokens) and is_assignment(tokens[index]):
        index += 1
    return index


def command_segments(tokens: list[str]) -> list[list[str]]:
    result = []
    start = 0
    for index, token in enumerate(tokens + [";"]):
        if token in SEPARATORS:
            if start < index:
                result.append(tokens[start:index])
            start = index + 1
    return result


def has_uncapped_make_text(
    command_text: str,
    capped: bool = False,
    depth: int = 0,
) -> bool:
    if depth > 3:
        return False
    tokens = tokenize(command_text)
    if tokens is None:
        return False
    return any(
        has_uncapped_make(segment, capped=capped, depth=depth)
        for segment in command_segments(tokens)
    )


def wrapper_tail(tokens: list[str], index: int, value_options: set[str]) -> list[str]:
    index += 1
    while index < len(tokens):
        token = tokens[index]
        if token == "--":
            return tokens[index + 1:]
        if token in value_options and index + 1 < len(tokens):
            index += 2
            continue
        if token.startswith("-"):
            index += 1
            continue
        return tokens[index:]
    return []


def env_tail(tokens: list[str], index: int) -> list[str]:
    index += 1
    while index < len(tokens):
        token = tokens[index]
        if token == "--":
            return tokens[index + 1:]
        if is_assignment(token):
            index += 1
            continue
        if token in {"-u", "--unset", "-C", "--chdir"} and index + 1 < len(tokens):
            index += 2
            continue
        if token.startswith("-"):
            index += 1
            continue
        return tokens[index:]
    return []


def command_tail(tokens: list[str], index: int) -> list[str]:
    index += 1
    while index < len(tokens):
        token = tokens[index]
        if token in {"-v", "-V"}:
            return []
        if token == "--":
            return tokens[index + 1:]
        if token == "-p":
            index += 1
            continue
        if token.startswith("-"):
            index += 1
            continue
        return tokens[index:]
    return []


def exec_tail(tokens: list[str], index: int) -> list[str]:
    index += 1
    while index < len(tokens):
        token = tokens[index]
        if token == "--":
            return tokens[index + 1:]
        if token == "-a" and index + 1 < len(tokens):
            index += 2
            continue
        if token.startswith("-"):
            index += 1
            continue
        return tokens[index:]
    return []


def timeout_tail(tokens: list[str], index: int) -> list[str]:
    index += 1
    while index < len(tokens):
        token = tokens[index]
        if token == "--":
            index += 1
            break
        if token in {"-k", "--kill-after", "-s", "--signal"} and index + 1 < len(tokens):
            index += 2
            continue
        if token in {"--foreground", "--preserve-status", "--verbose", "-f", "-p", "-v"}:
            index += 1
            continue
        if token.startswith("-"):
            index += 1
            continue
        break
    if index >= len(tokens):
        return []
    return tokens[index + 1:]


def time_tail(tokens: list[str], index: int) -> list[str]:
    index += 1
    while index < len(tokens):
        token = tokens[index]
        if token == "--":
            return tokens[index + 1:]
        if token in TIME_VALUE_OPTIONS and index + 1 < len(tokens):
            index += 2
            continue
        if token.startswith(TIME_VALUE_PREFIXES):
            index += 1
            continue
        if token.startswith("-"):
            index += 1
            continue
        return tokens[index:]
    return []


def shell_payload(tokens: list[str], index: int) -> str | None:
    index += 1
    while index < len(tokens):
        token = tokens[index]
        if token == "-c" or (token.startswith("-") and "c" in token[1:]):
            if index + 1 < len(tokens):
                return tokens[index + 1]
            return None
        index += 1
    return None


def systemd_tail(tokens: list[str], index: int) -> tuple[list[str], bool]:
    capped = False
    index += 1
    while index < len(tokens):
        token = tokens[index]
        if token == "--":
            return tokens[index + 1:], capped
        if token in {"-p", "--property"} and index + 1 < len(tokens):
            capped = capped or memorymax_property(tokens[index + 1])
            index += 2
            continue
        if token.startswith("--property="):
            capped = capped or memorymax_property(token.partition("=")[2])
            index += 1
            continue
        if token.startswith("-p") and len(token) > 2:
            capped = capped or memorymax_property(token[2:])
            index += 1
            continue
        if token in SYSTEMD_VALUE_OPTIONS and index + 1 < len(tokens):
            index += 2
            continue
        if token.startswith(SYSTEMD_VALUE_PREFIXES):
            index += 1
            continue
        if token.startswith("-"):
            index += 1
            continue
        return tokens[index:], capped
    return [], capped


def prlimit_tail(tokens: list[str], index: int) -> tuple[list[str], bool]:
    capped = False
    index += 1
    while index < len(tokens):
        token = tokens[index]
        if token == "--":
            return tokens[index + 1:], capped
        if token.startswith("--as="):
            capped = capped or finite_limit(token.partition("=")[2])
            index += 1
            continue
        if token.startswith("-v="):
            capped = capped or finite_limit(token[3:])
            index += 1
            continue
        if token.startswith("-v") and len(token) > 2:
            capped = capped or finite_limit(token[2:])
            index += 1
            continue
        if token.startswith("-"):
            index += 1
            continue
        return tokens[index:], capped
    return [], capped


def xargs_tail(tokens: list[str], index: int) -> list[str]:
    index += 1
    while index < len(tokens):
        token = tokens[index]
        if token == "--":
            return tokens[index + 1:]
        if token in {"-I", "-n", "-P", "-a", "-d", "-s", "-L"} and index + 1 < len(tokens):
            index += 2
            continue
        if token.startswith("-"):
            index += 1
            continue
        return tokens[index:]
    return []


def find_has_uncapped_make(
    tokens: list[str],
    index: int,
    capped: bool,
    depth: int,
) -> bool:
    index += 1
    while index < len(tokens):
        if tokens[index] not in {"-exec", "-execdir", "-ok", "-okdir"}:
            index += 1
            continue
        start = index + 1
        end = start
        while end < len(tokens) and tokens[end] not in {";", "+"}:
            end += 1
        if has_uncapped_make(tokens[start:end], capped=capped, depth=depth + 1):
            return True
        index = end + 1
    return False


def has_uncapped_make(tokens: list[str], capped: bool, depth: int) -> bool:
    index = command_index(tokens)
    if index >= len(tokens):
        return False

    name = basename(tokens[index])
    if name == "make":
        return not capped
    if name == "env":
        return has_uncapped_make(env_tail(tokens, index), capped=capped, depth=depth)
    if name == "sudo":
        return has_uncapped_make(
            wrapper_tail(tokens, index, {"-u", "-g", "-D"}),
            capped=capped,
            depth=depth,
        )
    if name == "command":
        return has_uncapped_make(command_tail(tokens, index), capped=capped, depth=depth)
    if name == "exec":
        return has_uncapped_make(exec_tail(tokens, index), capped=capped, depth=depth)
    if name == "time":
        return has_uncapped_make(time_tail(tokens, index), capped=capped, depth=depth)
    if name == "nice":
        return has_uncapped_make(
            wrapper_tail(tokens, index, {"-n", "--adjustment"}),
            capped=capped,
            depth=depth,
        )
    if name == "timeout":
        return has_uncapped_make(timeout_tail(tokens, index), capped=capped, depth=depth)
    if name in {"bash", "sh"}:
        payload = shell_payload(tokens, index)
        return bool(payload) and has_uncapped_make_text(
            payload,
            capped=capped,
            depth=depth + 1,
        )
    if name == "systemd-run":
        tail, wrapper_capped = systemd_tail(tokens, index)
        return has_uncapped_make(tail, capped=capped or wrapper_capped, depth=depth)
    if name == "prlimit":
        tail, wrapper_capped = prlimit_tail(tokens, index)
        return has_uncapped_make(tail, capped=capped or wrapper_capped, depth=depth)
    if name == "xargs":
        tail = xargs_tail(tokens, index)
        return bool(tail) and has_uncapped_make(tail, capped=capped, depth=depth)
    if name == "find":
        return find_has_uncapped_make(tokens, index, capped, depth)
    return False


if has_uncapped_make_text(command):
    print("1")
PY
}

command_is_read_only() {
  local scrubbed

  [ -n "${1:-}" ] || return 1
  scrubbed="$(printf '%s' "$1" | sed -E 's/[[:space:]][0-9]*>>?[[:space:]]*\/dev\/null([[:space:]]|$)/ /g')"

  case "$scrubbed" in
    *'`'*|*'$('*|*'>'*|*'<'*) return 1 ;;
  esac

  printf '%s\n' "$scrubbed" |
    awk -v canonical_log="$CODEX_HIGH_LEVEL_LOG_PATH" \
      -v canonical_log_alias="$CODEX_HIGH_LEVEL_LOG_PATH_ALIAS" '
      function emit() {
        print segment
        segment = ""
      }
      BEGIN {
        single_quote_char = sprintf("%c", 39)
      }
      {
        for (pos = 1; pos <= length($0); pos++) {
          char = substr($0, pos, 1)
          next_char = substr($0, pos + 1, 1)
          if (escaped) {
            segment = segment char
            escaped = 0
            continue
          }
          if (char == "\\" && double_quote) {
            segment = segment char
            escaped = 1
            continue
          }
          if (!double_quote && char == single_quote_char) {
            single_quote = !single_quote
            segment = segment char
            continue
          }
          if (!single_quote && char == "\"") {
            double_quote = !double_quote
            segment = segment char
            continue
          }
          if (!single_quote && !double_quote) {
            if (char == ";") {
              emit()
              continue
            }
            if (char == "&" && next_char == "&") {
              emit()
              pos++
              continue
            }
            if (char == "|" && next_char == "|") {
              emit()
              pos++
              continue
            }
            if (char == "|") {
              emit()
              continue
            }
          }
          segment = segment char
        }
        emit()
      }
    ' |
    awk -v canonical_repo_1="$CODEX_APPROVED_REPO_ROOT_1" \
      -v canonical_repo_2="$CODEX_APPROVED_REPO_ROOT_2" \
      -v canonical_repo_3="$CODEX_APPROVED_REPO_ROOT_3" \
      -v git_context_safe="$CODEX_GIT_STATUS_CONTEXT_SAFE" '
      function base_name(token) {
        sub(/^.*\//, "", token)
        return token
      }
      function allowed_simple(cmd) {
        return cmd ~ /^(cat|cut|date|dirname|du|egrep|fgrep|file|gitleaks|grep|head|jq|ls|nl|printf|pwd|readlink|realpath|rg|sort|stat|tail|test|tr|uniq|wc|which|\[)$/
      }
      {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
        if ($0 == "") {
          next
        }
        part_count = split($0, parts, /[[:space:]]+/)
        idx = 1
        while (idx <= part_count && parts[idx] ~ /^[A-Za-z_][A-Za-z0-9_]*=/) {
          idx++
        }
        cmd = base_name(parts[idx])
        if (cmd == "") {
          next
        }
        if (cmd == "command") {
          if (parts[idx + 1] != "-v") {
            bad = 1
          }
          next
        }
        if (cmd == "git") {
          if (git_context_safe == "true" && idx == 1 && parts[idx] == "git" &&
              part_count == idx + 4 && parts[idx + 1] == "-C" &&
              parts[idx + 3] == "status" && parts[idx + 4] == "--short" &&
              (parts[idx + 2] == canonical_repo_1 || parts[idx + 2] == canonical_repo_2 || parts[idx + 2] == canonical_repo_3)) {
            next
          }
          subcmd = parts[idx + 1]
          if (subcmd == "branch") {
            for (i = idx + 2; i <= part_count; i++) {
              if (parts[i] !~ /^-/ || parts[i] ~ /^(-d|-D|-m|-M|-c|-C|--delete|--move|--copy|--edit-description|--set-upstream-to|--unset-upstream)(=|$)/) {
                bad = 1
              }
            }
            next
          }
          if (subcmd == "remote") {
            if (parts[idx + 2] != "" && parts[idx + 2] !~ /^(-v|--verbose|show|get-url)$/) {
              bad = 1
            }
            next
          }
          if (subcmd !~ /^(describe|diff|grep|log|ls-files|rev-parse|show|status)$/) {
            bad = 1
          }
          next
        }
        if (cmd == "find") {
          for (i = idx + 1; i <= part_count; i++) {
            if (parts[i] ~ /^-(delete|exec|execdir|ok|okdir)$/) {
              bad = 1
            }
          }
          next
        }
        if (cmd == "sed") {
          if (parts[idx] != "sed" || part_count != idx + 3 ||
              parts[idx + 1] !~ /^(-n|--quiet)$/ ||
              parts[idx + 2] !~ /^[1-9][0-9]*(,[1-9][0-9]*)?p$/ ||
              parts[idx + 3] != canonical_log && parts[idx + 3] != canonical_log_alias) {
            bad = 1
          }
          next
        }
        if (!allowed_simple(cmd)) {
          bad = 1
        }
      }
      END { exit bad ? 1 : 0 }
    '
}

# ECI admission is an ownership boundary, not an executable allowlist. Once
# reserved lifecycle/control/Git/source/destructive checks have had their
# chance to reject a command, this parser admits one finite direct argv vector
# independent of the tool ecosystem. It does not claim that the executable is
# safe or read-only; it only rejects visible shell indirection and recognizable
# ownership-sensitive forms.
eci_finite_literal_argv() {
  python3 - "$1" <<'PY'
import re
import shlex
import sys

text = sys.argv[1]
if not text or len(text) > 16384:
    raise SystemExit(1)

# Operators are rejected only when outside quotes. A quoted search pattern may
# contain punctuation and remains an ordinary literal argument.
single = False
double = False
escaped = False
index = 0
while index < len(text):
    char = text[index]
    if single:
        if char == "'":
            single = False
        index += 1
        continue
    if escaped:
        escaped = False
        index += 1
        continue
    if char == "\\":
        escaped = True
        index += 1
        continue
    if char == "'":
        single = True
        index += 1
        continue
    if char == '"':
        double = not double
        index += 1
        continue
    if char in "\n\r\0;|&()<>*?[]" or char == '`':
        raise SystemExit(1)
    if char == '$':
        next_char = text[index + 1] if index + 1 < len(text) else ''
        if next_char in '({' or next_char == '_' or next_char.isalpha():
            raise SystemExit(1)
    index += 1
if single or double or escaped:
    raise SystemExit(1)

try:
    lexer = shlex.shlex(text, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    tokens = list(lexer)
except ValueError:
    raise SystemExit(1)
if not tokens or len(tokens) > 128 or any(len(token) > 4096 for token in tokens):
    raise SystemExit(1)

assignment = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
operators = {";", "&", "&&", "|", "||", "(", ")", ">", ">>", ">|", "<", "<<", "<<<", "<&", ">&"}
if assignment.match(tokens[0]) or any(token in operators for token in tokens):
    raise SystemExit(1)
raise SystemExit(0)
PY
}

# A coordinator inspection pipeline is a bounded list of direct argv vectors,
# not an executable allowlist. This parser only proves the static envelope;
# the caller runs every segment through protected-operation recognizers.
eci_static_pipeline_segments() {
  python3 - "$1" <<'PY'
import re
import shlex
import sys

text = sys.argv[1]
if not text or len(text) > 16384:
    raise SystemExit(1)
try:
    lexer = shlex.shlex(text, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    tokens = list(lexer)
except ValueError:
    raise SystemExit(1)
operators = {";", "&", "&&", "||", "(", ")", ">", ">>", ">|", "<", "<<", "<<<", "<&", ">&"}
if not tokens or any(token in operators for token in tokens) or tokens.count("|") not in range(1, 8):
    raise SystemExit(1)
parts, current = [], []
for token in tokens:
    if token == "|":
        if not current:
            raise SystemExit(1)
        parts.append(current)
        current = []
    else:
        current.append(token)
if not current:
    raise SystemExit(1)
parts.append(current)
assignment = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
for part in parts:
    if (len(part) > 128 or assignment.match(part[0])
            or any(len(token) > 4096 for token in part)):
        raise SystemExit(1)
    print(shlex.join(part))
PY
}

protected_pipeline_git_detail() {
  python3 - "$1" <<'PY'
import os
import shlex
import sys

try:
    tokens = shlex.split(sys.argv[1], posix=True)
except ValueError:
    raise SystemExit(1)
if not tokens or os.path.basename(tokens[0]) != "git":
    raise SystemExit(1)
index = 1
value_options = {"-C", "-c", "--config-env", "--git-dir", "--work-tree", "--namespace"}
while index < len(tokens):
    token = tokens[index]
    if token in value_options:
        index += 2
        continue
    if any(token.startswith(option + "=") for option in value_options if option.startswith("--")):
        index += 1
        continue
    if token in {"--literal-pathspecs", "--no-optional-locks", "--no-pager"}:
        index += 1
        continue
    if token.startswith("-"):
        raise SystemExit(1)
    break
if index >= len(tokens):
    raise SystemExit(1)
verb = tokens[index]
if verb in {"add", "commit", "config", "mv", "reset", "restore", "rm", "worktree"}:
    print("executable=%s token=%s argv_index=%d kind=acceptance-sensitive-git" %
          (tokens[0], verb, index))
    raise SystemExit(0)
raise SystemExit(1)
PY
}

protected_literal_operation_detail() {
  python3 - "$1" "$cwd" "$HOOK_DIR" "$2" <<'PY'
import os
import re
import shlex
import sys

text, hook_cwd, hook_dir, is_worker = sys.argv[1:]
try:
    lexer = shlex.shlex(text, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    tokens = list(lexer)
except ValueError:
    raise SystemExit(1)
operators = {";", "&", "&&", "|", "||", "(", ")", ">", ">>", "<", "<<", ">|", ">&", "<&"}
if not tokens or any(token in operators for token in tokens):
    raise SystemExit(1)

assignment = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=.*$")
def unwrap(values):
    values = list(values)
    depth = 0
    while values and depth < 8:
        while values and assignment.fullmatch(values[0]):
            values.pop(0)
        if not values:
            return []
        name = os.path.basename(values[0])
        if name == "env":
            index = 1
            while index < len(values):
                token = values[index]
                if assignment.fullmatch(token) or token in {"-i", "--ignore-environment"}:
                    index += 1
                    continue
                if token in {"-u", "--unset", "-C", "--chdir"}:
                    index += 2
                    continue
                if token == "--":
                    index += 1
                break
            values = values[index:]
            depth += 1
            continue
        if name in {"command", "builtin", "exec", "nohup", "setsid", "sudo", "doas"}:
            values = values[1:]
            depth += 1
            continue
        if name in {"timeout", "nice", "time", "prlimit", "chronic", "systemd-run"}:
            index = 1
            value_options = {
                "-k", "--kill-after", "-s", "--signal", "-n", "--adjustment",
                "-p", "--pid", "--property", "--unit", "--setenv",
                "--working-directory", "-C", "--chdir",
            }
            while index < len(values) and values[index].startswith("-"):
                if values[index] == "--":
                    index += 1
                    break
                index += 2 if values[index] in value_options else 1
            if name == "timeout" and index < len(values):
                index += 1
            values = values[index:]
            depth += 1
            continue
        break
    return values

argv = unwrap(tokens)
if not argv:
    raise SystemExit(1)
name = os.path.basename(argv[0])
args = argv[1:]

def resolved(value):
    expanded = os.path.expanduser(value)
    candidate = expanded if os.path.isabs(expanded) else os.path.join(hook_cwd, expanded)
    return os.path.realpath(os.path.normpath(candidate))

broad_roots = {"/", os.path.realpath(hook_cwd), os.path.realpath(os.path.dirname(hook_dir))}
for value in (
    os.environ.get("HOME", ""), os.environ.get("CODEX_HOME", ""),
    os.environ.get("KIMI_CODE_HOME", ""), os.environ.get("CODEX_PROOF_ROOT", ""),
    os.environ.get("KIMI_PROOF_ROOT", ""),
):
    if value and os.path.isabs(value):
        broad_roots.add(os.path.realpath(value))

if name == "rm" and any(token == "--recursive" or (token.startswith("-") and "r" in token[1:].lower()) for token in args):
    for token in args:
        if token == "--" or token.startswith("-"):
            continue
        target = resolved(token)
        if target in broad_roots:
            print("class=broad executable=%s token=%s target=%s kind=recursive-root-delete" % (argv[0], token, target))
            raise SystemExit(0)
if name in {"mkfs", "mkfs.ext2", "mkfs.ext3", "mkfs.ext4", "mkfs.xfs", "wipefs"}:
    target = next((token for token in reversed(args) if not token.startswith("-")), "<missing>")
    print("class=broad executable=%s token=%s target=%s kind=device-filesystem-destruction" %
          (argv[0], target, resolved(target) if target != "<missing>" else target))
    raise SystemExit(0)
if name == "dd":
    for token in args:
        if token.startswith("of=") and (token[3:].startswith("/dev/") or resolved(token[3:]) in broad_roots):
            print("class=broad executable=%s token=%s target=%s kind=raw-output-overwrite" %
                  (argv[0], token, resolved(token[3:])))
            raise SystemExit(0)
if name == "find" and "-delete" in args:
    for token in args:
        if token.startswith("-"):
            break
        target = resolved(token)
        if target in broad_roots:
            print("class=broad executable=%s token=%s target=%s kind=recursive-find-delete" %
                  (argv[0], token, target))
            raise SystemExit(0)

if is_worker == "true" and name == "git":
    index = 0
    value_options = {"-C", "-c", "--config-env", "--git-dir", "--work-tree", "--namespace"}
    while index < len(args):
        token = args[index]
        if token in value_options:
            index += 2
            continue
        if any(token.startswith(option + "=") for option in value_options if option.startswith("--")):
            index += 1
            continue
        if token in {"--literal-pathspecs", "--no-optional-locks", "--no-pager"}:
            index += 1
            continue
        if token.startswith("-"):
            break
        if token in {"commit", "config", "reset", "worktree"}:
            print("class=worker-git executable=%s token=%s kind=acceptance-sensitive-git" %
                  (argv[0], token))
            raise SystemExit(0)
        break

if is_worker == "true":
    if name == "chmod":
        protected_roots = {
            os.path.realpath(hook_cwd),
            os.path.realpath(os.path.dirname(hook_dir)),
        }
        for value in (os.environ.get("CODEX_HOME", ""), os.environ.get("KIMI_CODE_HOME", "")):
            if value and os.path.isabs(value) and os.path.isdir(value) and not os.path.islink(value):
                protected_roots.add(os.path.realpath(value))
        protected_hooks = set()
        for root in protected_roots:
            protected_hooks.update({
                os.path.join(root, "hooks", "validate-bash.sh"),
                os.path.join(root, "hooks", "pre-commit-go-mod.sh"),
                os.path.join(root, "hooks", "install-pre-commit-go-mod.sh"),
                os.path.join(root, "hooks", "tests", "test-pre-commit-go-mod.sh"),
            })

        cursor = 0
        reference_mode = False
        while cursor < len(args) and args[cursor] != "--":
            token = args[cursor]
            if token == "--reference":
                if cursor + 1 >= len(args):
                    break
                reference_mode = True
                cursor += 2
            elif token.startswith("--reference="):
                reference_mode = True
                cursor += 1
            elif token.startswith("-"):
                cursor += 1
            else:
                if not reference_mode:
                    cursor += 1  # mode
                break
        if cursor < len(args) and args[cursor] == "--":
            cursor += 1
        for token in args[cursor:]:
            if token == "--":
                continue
            target = resolved(token)
            if target in protected_hooks:
                print("class=worker-hook-mode executable=%s token=%s path=%s resolved=%s kind=protected-hook-mode-mutation" %
                      (argv[0], token, target, target))
                raise SystemExit(0)
    raise SystemExit(1)

source_roots = {os.path.realpath(hook_cwd), os.path.realpath(os.path.dirname(hook_dir))}
for value in (os.environ.get("CODEX_HOME", ""), os.environ.get("KIMI_CODE_HOME", "")):
    if value and os.path.isabs(value) and os.path.isdir(value):
        source_roots.add(os.path.realpath(value))
def under_source(path):
    return any(path == root or path.startswith(root + os.sep) for root in source_roots)

targets = []
plain = [token for token in args if token != "--" and not token.startswith("-")]
if name in {"touch", "truncate", "mkdir", "rmdir", "rm", "shred", "srm", "tee", "patch", "ed", "ex"}:
    targets = plain
elif name == "chmod":
    targets = plain[1:] if plain else []
elif name in {"cp", "install", "ln"}:
    targets = plain[-1:]
elif name == "mv":
    targets = plain
elif name in {"sed", "perl"} and any(token == "-i" or token.startswith(("-i", "--in-place")) for token in args):
    targets = plain[1:]
elif name == "find" and "-delete" in args:
    targets = [token for token in args if not token.startswith("-")][:1]
elif name == "dd":
    targets = [token[3:] for token in args if token.startswith("of=")]
elif name == "apply_patch":
    print("class=source executable=%s token=<patch-payload> path=<payload> resolved=<payload> kind=coordinator-source-write" % argv[0])
    raise SystemExit(0)

for token in targets:
    target = resolved(token)
    if under_source(target):
        print("class=source executable=%s token=%s path=%s resolved=%s kind=coordinator-source-write" %
              (argv[0], token, target, target))
        raise SystemExit(0)
raise SystemExit(1)
PY
}

# Resolve a protected review-gate command independently of its argument
# validity and independently of ordinary executable admission.  This is an
# ownership recognizer: the canonical target is reserved even when reached
# through a finite shell-script form or supplied malformed/extra arguments.
review_gate_command_identity() {
  python3 - "$1" "$HOOK_DIR" "${KIMI_CODE_HOME:-${HOME:-}/.kimi-code}" <<'PY'
import json
import os
import re
import shlex
import sys

text, codex_hooks, kimi_home = sys.argv[1:]
try:
    lexer = shlex.shlex(text, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    tokens = list(lexer)
except ValueError:
    raise SystemExit(1)
operators = {";", "&", "&&", "|", "||", "(", ")", ">", ">>", "<", "<<", ">|", ">&", "<&"}
if not tokens or any(token in operators for token in tokens):
    raise SystemExit(1)

targets = {
    os.path.realpath(os.path.join(codex_hooks, "eci-review-gate.sh")),
    os.path.realpath(os.path.join(kimi_home, "hooks", "eci-review-gate.sh")),
}

def canonical_target(value):
    expanded = os.path.expanduser(value)
    if not os.path.isabs(expanded):
        expanded = os.path.abspath(os.path.join(os.environ.get("CODEX_VALIDATE_CWD", os.getcwd()), expanded))
    resolved = os.path.realpath(expanded)
    return resolved if resolved in targets and os.path.isfile(resolved) else None

invocation = "direct"
target_index = 0
shells = {"bash", "dash", "sh", "zsh"}
if os.path.basename(tokens[0]) in shells:
    invocation = "shell-script"
    target_index = 1
    no_argument = {
        "-e", "-n", "--noexec", "-x", "--trace", "--noprofile",
        "--norc", "--posix", "--restricted", "--verbose",
    }
    while target_index < len(tokens):
        option = tokens[target_index]
        if option == "--":
            target_index += 1
            break
        if option in no_argument:
            target_index += 1
            continue
        if option == "-O":
            if target_index + 1 >= len(tokens):
                raise SystemExit(1)
            target_index += 2
            continue
        if option.startswith("-"):
            # Inline/stdin/source payload switches are dynamic-indirection
            # denials, not review-gate identities.
            raise SystemExit(1)
        break

if target_index >= len(tokens):
    raise SystemExit(1)
target = canonical_target(tokens[target_index])
if target is None:
    raise SystemExit(1)
argv = tokens[target_index + 1:]
valid_shape = bool(
    len(argv) == 2 and
    argv[0] in {"commit", "final", "off", "prewrite"} and
    re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]*", argv[1])
)
malformed_token = "<none>"
if not valid_shape:
    if not argv:
        malformed_token = "<missing-phase>"
    elif argv[0] not in {"commit", "final", "off", "prewrite"}:
        malformed_token = argv[0]
    elif len(argv) < 2:
        malformed_token = "<missing-session>"
    elif re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]*", argv[1]) is None:
        malformed_token = argv[1]
    else:
        malformed_token = argv[2]
print(
    "canonical_target=%s invocation=%s argv=%s valid_shape=%s malformed_token=%s" % (
        target,
        invocation,
        json.dumps(argv, separators=(",", ":")),
        str(valid_shape).lower(),
        json.dumps(malformed_token),
    )
)
PY
}

protected_control_script_identity() {
  python3 - "$1" "$HOOK_DIR" "${KIMI_CODE_HOME:-${HOME:-}/.kimi-code}" <<'PY'
import os
import shlex
import sys

text, codex_hooks, kimi_home = sys.argv[1:]
try:
    lexer = shlex.shlex(text, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    tokens = list(lexer)
except ValueError:
    raise SystemExit(1)
operators = {";", "&", "&&", "|", "||", "(", ")", ">", ">>", "<", "<<", ">|", ">&", "<&"}
if not tokens or any(token in operators for token in tokens):
    raise SystemExit(1)
names = {"stop-gate.sh", "eci-active-gate.sh", "ate-orchestrator-gate.sh"}
targets = {
    os.path.realpath(os.path.join(root, name))
    for root in (codex_hooks, os.path.join(kimi_home, "hooks"))
    for name in names
}
index = 0
invocation = "direct"
if os.path.basename(tokens[0]) in {"bash", "dash", "sh", "zsh"}:
    invocation = "shell-script"
    index = 1
    no_argument = {
        "-e", "-n", "--noexec", "-x", "--trace", "--noprofile",
        "--norc", "--posix", "--restricted", "--verbose",
    }
    while index < len(tokens):
        option = tokens[index]
        if option == "--":
            index += 1
            break
        if option in no_argument:
            index += 1
            continue
        if option == "-O" and index + 1 < len(tokens):
            index += 2
            continue
        if option.startswith("-"):
            raise SystemExit(1)
        break
if index >= len(tokens):
    raise SystemExit(1)
candidate = tokens[index]
expanded = os.path.expanduser(candidate)
if not os.path.isabs(expanded):
    expanded = os.path.abspath(os.path.join(os.environ.get("CODEX_VALIDATE_CWD", os.getcwd()), expanded))
resolved = os.path.realpath(expanded)
if resolved not in targets or not os.path.isfile(resolved):
    raise SystemExit(1)
print("canonical_target=%s invocation=%s argv=%s" % (resolved, invocation, tokens[index + 1:]))
PY
}

command_operator_detail() {
  python3 - "$1" <<'PY'
import shlex
import sys
try:
    lexer = shlex.shlex(sys.argv[1], posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    tokens = list(lexer)
except ValueError:
    raise SystemExit(1)
for token in tokens:
    if token in {"&&", "||", ";", "|", "&", "(", ")", ">", ">>", "<", "<<"}:
        print("operator/token=" + token)
        raise SystemExit(0)
raise SystemExit(1)
PY
}

dynamic_indirection_detail() {
  python3 - "$1" <<'PY'
import os
import re
import shlex
import sys
text = sys.argv[1]
quote = None
escaped = False
for index, char in enumerate(text):
    if escaped:
        escaped = False
        continue
    if char == "\\" and quote != "'":
        escaped = True
        continue
    if quote:
        if char == quote:
            quote = None
        continue
    if char in {"'", '"'}:
        quote = char
        continue
    if char in {"*", "?"}:
        print("token=%s char_index=%d kind=unquoted-glob" % (char, index))
        raise SystemExit(0)
try:
    tokens = shlex.split(sys.argv[1], posix=True)
except ValueError:
    raise SystemExit(1)
dynamic = {
    "bash": {"-c", "--command", "-s", "--stdin", "--rcfile"},
    "dash": {"-c", "-s"},
    "sh": {"-c", "-s"},
    "zsh": {"-c", "-s"},
    "python": {"-c"}, "python2": {"-c"}, "python3": {"-c"},
    "node": {"-e", "--eval", "-p", "--print"},
    "nodejs": {"-e", "--eval", "-p", "--print"},
    "perl": {"-e"}, "ruby": {"-e"}, "php": {"-r"},
}


def inspect(segment, base=0, depth=0):
    if not segment or depth > 8:
        return None
    name = os.path.basename(segment[0])
    if name == "xargs":
        return segment[0], base, "stdin-argv-indirection"
    if name == "find":
        for index, token in enumerate(segment[1:], 1):
            if token in {"-exec", "-execdir", "-ok", "-okdir"}:
                return token, base + index, "indirect-exec"
    if name in {"eval", "source", "."}:
        return segment[0], base, None
    if name == "export":
        return segment[0], base, "execution-context-mutation"
    if name == "hash" and any(token == "-p" for token in segment[1:]):
        return "-p", base + segment.index("-p"), "execution-context-mutation"
    if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=.*", segment[0]):
        return segment[0], base, "environment-assignment"
    if name == "env":
        index = 1
        while index < len(segment):
            token = segment[index]
            if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=.*", token):
                index += 1
                continue
            if token in {"-i", "--ignore-environment"}:
                index += 1
                continue
            if token in {"-u", "--unset", "-C", "--chdir", "-S", "--split-string"}:
                if index + 1 >= len(segment):
                    return None
                index += 2
                continue
            if token.startswith(("--unset=", "--chdir=", "--split-string=")):
                index += 1
                continue
            if token == "--":
                index += 1
                break
            if token.startswith("-"):
                index += 1
                continue
            break
        return inspect(segment[index:], base + index, depth + 1)
    if name in {"timeout", "systemd-run", "nice", "time", "prlimit", "chronic"}:
        index = 1
        value_options = {
            "-k", "--kill-after", "-s", "--signal", "-n", "--adjustment",
            "-p", "--property", "--unit", "--setenv", "--working-directory",
            "-C", "--chdir",
        }
        while index < len(segment) and segment[index].startswith("-"):
            option = segment[index]
            if option == "--":
                index += 1
                break
            if option in value_options:
                if index + 1 >= len(segment):
                    return None
                index += 2
                continue
            index += 1
        if name == "timeout":
            if index >= len(segment):
                return None
            index += 1
        return inspect(segment[index:], base + index, depth + 1)
    for index, token in enumerate(segment[1:], 1):
        if name in dynamic and (token in dynamic[name] or
                (name == "bash" and token.startswith("--rcfile=")) or
                token.startswith(("--eval=", "--execute="))):
            return token, base + index, None
    return None

detail = inspect(tokens)
if detail is None:
    raise SystemExit(1)
token, index, kind = detail
suffix = " kind=%s" % kind if kind else ""
print("token=%s argv_index=%d%s" % (token, index, suffix))
PY
}

# Admit only a finite pure read-only pipeline for an active worker.  Ownership
# and launcher checks remain ahead of this route; each segment is still passed
# through the existing capability classifier under a pipeline-only stdin
# context.  This is a capability route, not an executable-name exception.
worker_read_only_pipeline_route() {
  [ "${worker_read_only_pipeline_candidate:-false}" = true ] || return 1
  [ "${hook_is_subagent:-false}" = true ] || return 1
  [ "${#syntax_eci_markers[@]}" -gt 0 ] || return 1
  local pipeline_command="$1" segments segment classification detail
  local command="$pipeline_command"
  segments="$(eci_static_pipeline_segments "$pipeline_command" 2>/dev/null)" || return 1
  [ -n "$segments" ] || return 1
  while IFS= read -r segment; do
    [ -n "$segment" ] || return 1
    eci_finite_literal_argv "$segment" || return 1
    deferred_worker_wrapper_shape "$segment" && return 1
    detail="$(dynamic_indirection_detail "$segment" 2>/dev/null || true)"
    if [ -n "$detail" ]; then
      deny_eci "ECI_COMMAND_DYNAMIC_INDIRECTION_DENIED" "direct-argv" \
        "ECI worker pipeline denied dynamic indirection in segment=$(eci_command_identity_subject "$segment"): ${detail}; reason=the reported token hides or changes executable payload identity" \
        "remove the reported token and submit each finite direct argv segment separately"
    fi
    classification="$(ECI_READ_ONLY_PIPELINE=true classify_eci_command "$segment" 2>/dev/null || true)"
    if command_invokes_subagent_unsafe_launcher "$segment"; then
      if [ "$classification" != read-only ]; then
        detail="$(rejected_command_detail "$segment" 2>/dev/null || printf 'segment=<unclassified>')"
        deny_eci "ECI_WORKER_LAUNCHER_DENIED" "worker-launcher" \
          "ECI worker boundary denied unsupported launcher in pipeline segment=$(eci_command_identity_subject "$segment"): ${detail}; reason=worker pipeline segments must remain direct literal argv" \
          "remove the wrapper/interpreter and submit the bounded direct argv through the approved worker route"
      fi
    fi
    detail="$(protected_literal_operation_detail "$segment" true 2>/dev/null || true)"
    case "$detail" in
      class=broad\ *)
        deny_eci "ECI_BROAD_DESTRUCTIVE_DENIED" "broad-destructive" \
          "ECI worker pipeline denied broad destructive segment=$(eci_command_identity_subject "$segment"): ${detail}" \
          "narrow the reported target and submit the operation as a separately reviewed direct argv"
        ;;
      class=worker-git\ *)
        deny_eci "ECI_WORKER_GIT_OWNERSHIP_DENIED" "worker-git-ownership" \
          "ECI worker ownership gate denied acceptance-sensitive Git segment=$(eci_command_identity_subject "$segment"): ${detail}; predicate=worker-git-ownership" \
          "route the reported Git verb through the main/orchestrator coordinator"
        ;;
    esac
    detail="$(command_invokes_git_branch_remote_mutation "$segment" 2>/dev/null || true)"
    if [ -n "$detail" ]; then
      deny_eci "ECI_WORKER_GIT_OWNERSHIP_DENIED" "worker-git-ownership" \
        "ECI worker ownership gate denied branch/remote mutation in pipeline segment=$(eci_command_identity_subject "$segment"): ${detail}; predicate=worker-git-ownership" \
        "route the reported Git ref or remote mutation through the main/orchestrator coordinator"
    fi
    if command_invokes_eci_binary "$segment"; then
      detail="$(rejected_command_detail "$segment" 2>/dev/null || printf 'segment=<unclassified>')"
      deny_eci "ECI_CONTROL_OWNER_REQUIRED" "eci-control" \
        "ECI worker boundary denied coordinator-owned control segment=$(eci_command_identity_subject "$segment"): ${detail}; reason=the canonical eci-active target owns lifecycle/control state" \
        "route the reported lifecycle/control invocation through the main/orchestrator coordinator"
    fi
    command="$segment"
    detail="$(worker_control_path_detail 2>/dev/null || true)"
    if [ -n "$detail" ]; then
      deny_eci "ECI_CONTROL_OWNER_REQUIRED" "worker-control" \
        "ECI worker boundary denied coordinator-owned control path in pipeline segment=$(eci_command_identity_subject "$segment"): ${detail}" \
        "route the reported ECI control or proof path through the main/orchestrator coordinator"
    fi
    if declare -F worker_peer_path_detail >/dev/null 2>&1; then
      detail="$(worker_peer_path_detail "$segment" 2>/dev/null || true)"
      [ -z "$detail" ] || return 1
    fi
    [ "$classification" = read-only ] || return 1
  done <<< "$segments"
  return 0
}

read_only_fast_safe() {
  # Keep this shell filter intentionally conservative.  The full classifier
  # below remains authoritative; this predicate only decides whether the
  # marker-only read path may short-circuit it.  Output/configuration options
  # stay on the full path so they cannot turn a nominal inspection command
  # into a writer or bypass active-marker policy.
  if [[ "${1:-}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] ||
     [[ "${1:-}" =~ ^[[:space:]]*(env|command|builtin|exec|bash|sh|dash|zsh|nohup|setsid|sudo|doas|timeout|systemd-run|nice|prlimit|time|xargs|find)([[:space:]]|$) ]]; then
    return 1
  fi
  # A command token containing a path is never eligible for the marker-only
  # fast path.  The basename may spoof a trusted read-only tool (notably
  # `git`); the full classifier must establish executable identity first.
  case "${1:-}" in
    */*) return 1 ;;
    *'('*|*')'*) return 1 ;;
  esac
  case "${1:-}" in
    sed\ *|sed)
      trusted_executable_on_path sed || return 1
      ;;
    git\ *|-*\ git\ *)
      trusted_executable_on_path git || return 1
      case "$1" in
        *\ --textconv*|*\ --ext-diff*|*\ --output\ *|*\ --output=*|*\ --to-file\ *|*\ --to-file=*|*\ -o\ *|*\ -o*|*\ -C\ *|*\ -c\ *|*\ --config-env*|*\ --git-dir*|*\ --work-tree*|*\ --exec-path*|*\ --namespace*)
          return 1
          ;;
      esac
      ;;
    gitleaks\ *|gitleaks)
      case "$1" in
        *\ -r*|*\ --report-path\ *|*\ --report-path=*) return 1 ;;
      esac
      ;;
    sort\ *)
      case "$1" in
        *\ -o\ *|*\ -o*|*\ --output=*) return 1 ;;
      esac
      ;;
  esac
  return 0
}

worker_fast_path_control_guard() {
  local detail
  detail="$(worker_control_path_detail 2>/dev/null || true)"
  [ -n "$detail" ] || return 0
  if [[ "$detail" == instruction-denied\ * ]]; then
    detail="${detail#instruction-denied }"
    deny_eci "ECI_WORKER_INSTRUCTION_READ_DENIED" "worker-instruction-read" \
      "ECI worker boundary denied a claimed instruction-source read: $detail; reason=the reported instruction operand is not an existing canonical regular file or read-only traversable directory contained by a configured provider instruction root" \
      "use the reported instruction_root and read an existing regular CODEX.md, AGENTS.md, installed skill resource, or contained skill directory with a read-only traversal command; do not use missing targets, special files, mutations, or symlink escapes"
  elif [[ "$detail" == read\ * ]]; then
    detail="${detail#read }"
    deny_eci "ECI_WORKER_CONTROL_READ_DENIED" "worker-control-read" \
      "ECI worker boundary denied a coordinator-owned control read: $detail" \
      "route the reported token through the bounded coordinator inspection route; workers may read only the explicitly allowlisted proof documents"
  else
    detail="${detail#write }"
    deny_eci "ECI_CONTROL_OWNER_REQUIRED" "worker-control" \
      "ECI worker boundary denied a command path owned by the coordinator: $detail" \
      "route ECI marker, proof, ledger, or teardown state through the main/orchestrator coordinator; workers may not mutate ECI control files or other coordinator-owned control paths"
  fi
}

if [ "$worker_fast_path_candidate" = true ]; then
  # The planner's plain-worker shape excludes lifecycle, control-path,
  # wrapper, Git, proof, environment, and operator forms.  Bind the active
  # marker and rerun the compiled/adapter ownership checks before leaving the
  # callback.  A status-0 planner result must never hide a mismatched marker.
  validate_active_marker_binding
  worker_fast_path_control_guard
  [ "${#syntax_eci_markers[@]}" -le 1 ] ||
    deny_eci "ECI_MARKER_OWNERSHIP_AMBIGUOUS" "marker-discovery" \
      "ECI worker fast path denied multiple active marker owners: path=$CODEX_PROOF_ROOT_CONFIGURED; predicate=duplicate-active-owner; reason=the callback cannot safely select one ECI session marker" \
      "resolve marker ownership so exactly one validated marker remains, then retry"
  exit 0
fi

if [ "$hook_is_subagent" = true ] && [ "${#syntax_eci_markers[@]}" -gt 0 ] &&
  [ "$worker_fast_path_candidate" != true ]; then
  worker_project_inspection_route "$command" || true
fi

coordinator_go_test_capture_route() {
  [ "$hook_is_subagent" != true ] || return 1
  [ "$(classify_eci_command "$1" 2>/dev/null || true)" = "verification" ]
}

coordinator_go_vet_capture_route() {
  [ "$hook_is_subagent" != true ] || return 1
  [ "$(classify_eci_command "$1" 2>/dev/null || true)" = "verification" ]
}

worker_protected_control_identity=""
if [ "$hook_is_subagent" = true ] && [ "${#syntax_eci_markers[@]}" -gt 0 ] &&
  ! command_invokes_eci_binary "$command"; then
  worker_protected_control_identity="$(protected_control_script_identity "$command" 2>/dev/null || true)"
fi

if [ "$hook_is_subagent" = true ] && [ "${#syntax_eci_markers[@]}" -gt 0 ] &&
  ! command_invokes_eci_binary "$command" &&
  [ -z "$worker_protected_control_identity" ] &&
  worker_control_detail="$(worker_control_path_detail 2>/dev/null || true)" &&
  [ -n "$worker_control_detail" ]; then
  if [[ "$worker_control_detail" == instruction-denied\ * ]]; then
    worker_control_detail="${worker_control_detail#instruction-denied }"
    deny_eci "ECI_WORKER_INSTRUCTION_READ_DENIED" "worker-instruction-read" \
      "ECI worker boundary denied a claimed instruction-source read: $worker_control_detail; reason=the reported instruction operand is not an existing canonical regular file or read-only traversable directory contained by a configured provider instruction root" \
      "use the reported instruction_root and read an existing regular CODEX.md, AGENTS.md, installed skill resource, or contained skill directory with a read-only traversal command; do not use missing targets, special files, mutations, or symlink escapes"
  elif [[ "$worker_control_detail" == read\ * ]]; then
    worker_control_detail="${worker_control_detail#read }"
    deny_eci "ECI_WORKER_CONTROL_READ_DENIED" "worker-control-read" \
      "ECI worker boundary denied a coordinator-owned control read: $worker_control_detail" \
      "route the reported token through the bounded coordinator inspection route; workers may read only the explicitly allowlisted proof documents"
  else
    worker_control_detail="${worker_control_detail#write }"
    deny_eci "ECI_CONTROL_OWNER_REQUIRED" "worker-control" \
      "ECI worker boundary denied a command path owned by the coordinator: $worker_control_detail" \
      "route ECI marker, proof, ledger, or teardown state through the main/orchestrator coordinator; workers may not mutate ECI control files or other coordinator-owned control paths"
  fi
fi

worker_reserved_lifecycle_alias_detail() {
  [ "$hook_is_subagent" = true ] || return 1
  python3 - "$1" "$HOOK_DIR" <<'PY'
import hashlib
import json
import os
import shlex
import shutil
import sys

command, hook_dir = sys.argv[1:]
try:
    tokens = shlex.split(command, posix=True)
except ValueError:
    raise SystemExit(1)
if not tokens or any(token in {";", "&", "&&", "|", "||", "(", ")"} for token in tokens):
    raise SystemExit(1)

provider_bin_aliases = {"eci-review-gate", "eci-stage"}

roots = []
seen_roots = set()
for value in (
    os.environ.get("CODEX_HOME", ""), os.environ.get("KIMI_CODE_HOME", ""),
    os.path.dirname(hook_dir),
):
    if value and os.path.isabs(value) and os.path.isdir(value) and not os.path.islink(value):
        root = os.path.realpath(value)
        if root not in seen_roots:
            seen_roots.add(root)
            roots.append(root)

def digest(path):
    try:
        with open(path, "rb") as stream:
            value = hashlib.sha256()
            for chunk in iter(lambda: stream.read(65536), b""):
                value.update(chunk)
            return value.hexdigest()
    except OSError:
        return None

candidate = tokens[0]
resolved = shutil.which(candidate) if not os.path.isabs(candidate) else candidate
if not resolved or not os.path.isfile(resolved) or os.path.islink(resolved):
    raise SystemExit(1)
resolved = os.path.realpath(resolved)
if not os.path.isfile(resolved) or not os.access(resolved, os.X_OK):
    raise SystemExit(1)
candidate_digest = digest(resolved)
for root in roots:
    alias = os.path.basename(candidate)
    provider_alias = os.path.join(root, "bin", alias)
    if alias in provider_bin_aliases and resolved == provider_alias:
        print("canonical_target=%s invocation=reserved-alias argv=%s" %
              (provider_alias, json.dumps(tokens[1:], separators=(",", ":"))))
        raise SystemExit(0)
    canonical = os.path.join(root, "bin", "eci-active")
    if os.path.isfile(canonical) and candidate_digest and candidate_digest == digest(canonical):
        print("canonical_target=%s invocation=direct argv=%s" %
              (canonical, json.dumps(tokens[1:], separators=(",", ":"))))
        raise SystemExit(0)
raise SystemExit(1)
PY
}

worker_reserved_lifecycle_alias=""
if [ "$hook_is_subagent" = true ] && [ "${#syntax_eci_markers[@]}" -gt 0 ]; then
  worker_reserved_lifecycle_alias="$(worker_reserved_lifecycle_alias_detail "$command" 2>/dev/null || true)"
fi
if [ -n "$worker_reserved_lifecycle_alias" ]; then
  deny_eci "ECI_CONTROL_OWNER_REQUIRED" "worker-control" \
    "ECI worker boundary denied coordinator-owned lifecycle/control invocation: ${worker_reserved_lifecycle_alias}; predicate=worker-lifecycle-control; reason=the reserved lifecycle executable alias owns ECI control state" \
    "route this exact lifecycle/control invocation through the main/orchestrator coordinator"
fi

if [ "${#syntax_eci_markers[@]}" -gt 0 ] && [ "$plan_status" -eq 0 ] &&
  ! eci_cleanup_command_shape "$command" &&
  ! coordinator_script_batch_shape "$command" &&
  ! deferred_route_lifecycle_shape "$command" &&
  ! deferred_route_git_shape "$command" &&
  ! deferred_route_script_shape "$command" &&
  ! deferred_route_environment_shape "$command" &&
  ! deferred_route_proof_path_shape "$command" &&
  ! deferred_route_hook_repair_shape "$command" &&
  ! deferred_worker_operator_shape "$command" &&
  ! deferred_worker_wrapper_shape "$command" &&
  ! deferred_worker_control_shape "$command"; then
  validate_active_marker_binding
  exit 0
fi

COORDINATOR_SCRIPT_ROUTE_DETAIL=""
coordinator_script_route() {
  [ "$hook_is_subagent" != true ] || return 1
  local detail
  detail="$(python3 - "$1" "$cwd" <<'PY'
import os
import hashlib
import re
import shlex
import shutil
import sys

command, hook_cwd = sys.argv[1], sys.argv[2]
try:
    lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    tokens = list(lexer)
except ValueError:
    print("coordinator-script-route syntax=unbalanced quoting")
    raise SystemExit(1)
assignments = {}
while tokens and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=.*", tokens[0]):
    name, value = tokens.pop(0).split("=", 1)
    if name in assignments or name not in {"ECI_EMIT_CURRENT_MANIFEST", "ECI_EMIT_SESSION_ID", "ECI_TEST_REPO", "ECI_EMIT_PROOF_ROOT", "ECI_EMIT_KIND", "ECI_EMIT_SOURCE_PATH"}:
        print("coordinator-script-route assignment=" + name + " reason=only bounded manifest-emitter assignments are admitted")
        raise SystemExit(1)
    if name == "ECI_EMIT_CURRENT_MANIFEST" and value != "1":
        print("coordinator-script-route assignment=" + name + " reason=value must be literal 1")
        raise SystemExit(1)
    if name == "ECI_EMIT_SESSION_ID" and not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,127}", value):
        print("coordinator-script-route assignment=" + name + " reason=session id is not bounded")
        raise SystemExit(1)
    if name == "ECI_TEST_REPO" and (not os.path.isabs(value) or os.path.normpath(value) != value or os.path.basename(value) not in {".codex", ".kimi-code"} or not os.path.isdir(value) or os.path.islink(value) or os.path.realpath(value) != value):
        print("coordinator-script-route assignment=" + name + " reason=repository must be an approved canonical Codex/Kimi root")
        raise SystemExit(1)
    if name == "ECI_EMIT_KIND" and value not in {"root", "subtask", "candidate-fix", "current"}:
        print("coordinator-script-route assignment=" + name + " reason=kind must be root, subtask, candidate-fix, or current")
        raise SystemExit(1)
    if name == "ECI_EMIT_PROOF_ROOT" and (not os.path.isabs(value) or os.path.normpath(value) != value or not os.path.isdir(value) or os.path.islink(value) or os.path.realpath(value) != value or os.path.basename(value) != "codex-proof" or os.path.basename(os.path.dirname(value)) != ".cache"):
        print("coordinator-script-route assignment=" + name + " reason=proof root must be the existing canonical .cache/codex-proof parent directory")
        raise SystemExit(1)
    if name == "ECI_EMIT_SOURCE_PATH" and (not os.path.isabs(value) or os.path.normpath(value) != value or os.path.basename(value) != "eci-required-critics.json.source" or not os.path.isdir(os.path.dirname(value)) or os.path.islink(os.path.dirname(value)) or os.path.realpath(os.path.dirname(value)) != os.path.dirname(value) or not (os.path.dirname(value) == "/tmp" or os.path.dirname(value).startswith(os.path.realpath(os.environ.get("TMPDIR", "/tmp")) + "/"))):
        print("coordinator-script-route assignment=" + name + " reason=source path must be eci-required-critics.json.source directly under canonical temporary storage")
        raise SystemExit(1)
    assignments[name] = value
required_assignments = {"ECI_EMIT_CURRENT_MANIFEST", "ECI_EMIT_SESSION_ID", "ECI_TEST_REPO", "ECI_EMIT_PROOF_ROOT", "ECI_EMIT_KIND", "ECI_EMIT_SOURCE_PATH"}
if assignments and (set(assignments) != required_assignments or assignments.get("ECI_EMIT_CURRENT_MANIFEST") != "1"):
    print("coordinator-script-route assignment-set reason=manifest emitter requires exactly ECI_EMIT_CURRENT_MANIFEST, ECI_EMIT_SESSION_ID, ECI_TEST_REPO, ECI_EMIT_PROOF_ROOT, ECI_EMIT_KIND, and ECI_EMIT_SOURCE_PATH")
    raise SystemExit(1)
trace_pipeline = False
bounded_trace_flags = []
# `-x` (execution tracing) and `-n` (syntax-only checking) are independent,
# finite shell diagnostics.  Admit either flag alone or the unique two-flag
# combination in either order, but never arbitrary shell options.  The same
# grammar is used for the optional bounded trace sink below.
trace_match = re.fullmatch(
    r"(bash|sh) ((?:-(?:x|n) )+)(\S+)(?: 2>&1 \| tail -n ([1-9][0-9]*))?",
    command,
)
if trace_match:
    candidate_flags = trace_match.group(2).split()
    valid_flags = (
        1 <= len(candidate_flags) <= 2 and
        len(set(candidate_flags)) == len(candidate_flags) and
        set(candidate_flags) <= {"-x", "-n"}
    )
    trace_count = trace_match.group(4)
    valid_count = (
        trace_count is None or
        (trace_count.isdigit() and 1 <= int(trace_count) <= 200 and
         str(int(trace_count)) == trace_count)
    )
    if valid_flags and valid_count and (trace_count is None or "-x" in candidate_flags):
        bounded_trace_flags = candidate_flags
        tokens = [trace_match.group(1), *candidate_flags, trace_match.group(3)]
        trace_pipeline = trace_count is not None
if not trace_pipeline and len(tokens) >= 8 and tokens[0] in {"bash", "sh"} and "-x" in tokens[1:3]:
    trace_count = tokens[-1]
    valid_count = trace_count.isdigit() and 1 <= int(trace_count) <= 200 and str(int(trace_count)) == trace_count
    literal_trace_redirect = re.search(r"(?<!\S)2>&1(?!\S)", command) is not None
    pipe_index = tokens.index("|") if "|" in tokens else -1
    prefix = tokens[:pipe_index] if pipe_index >= 0 else []
    suffix = tokens[pipe_index + 1:] if pipe_index >= 0 else []
    trace_sink = ["tail", "-n", trace_count]
    trace_redirects = (["2", ">&", "1"], ["2>&1"], ["2", ">", "&", "1"])
    if (not trace_pipeline and literal_trace_redirect and valid_count and
            suffix == trace_sink and len(prefix) >= 3 and prefix[0] in {"bash", "sh"}):
        for redirect in trace_redirects:
            invocation = prefix[:-len(redirect)] if prefix[-len(redirect):] == redirect else []
            candidate_flags = invocation[1:-1] if len(invocation) >= 3 else []
            if (invocation and len(candidate_flags) <= 2 and
                    len(set(candidate_flags)) == len(candidate_flags) and
                    set(candidate_flags) <= {"-x", "-n"} and "-x" in candidate_flags):
                trace_pipeline = True
                bounded_trace_flags = candidate_flags
                tokens = invocation
                break
if not bounded_trace_flags and tokens and tokens[0] in {"bash", "sh"} and len(tokens) >= 3:
    candidate_flags = tokens[1:-1]
    if (1 <= len(candidate_flags) <= 2 and
            len(set(candidate_flags)) == len(candidate_flags) and
            set(candidate_flags) <= {"-x", "-n"}):
        bounded_trace_flags = candidate_flags
if any(char in command for char in ("\n", "\r", "$", "`")):
    print("coordinator-script-route syntax=indirection-or-newline")
    raise SystemExit(1)
unsafe = {";", "&", "&&", "||", "(", ")", ">", ">>", "<", "<<", "<<<", ">|", ">&", "<&"}
if any(token in unsafe - {"&&"} for token in tokens):
    print("coordinator-script-route operator/token=" + next(token for token in tokens if token in unsafe - {"&&"}))
    raise SystemExit(1)
direct_script = False
if tokens and tokens[0] in {"bash", "sh"}:
    shell_name = tokens[0]
elif len(tokens) == 1 and (tokens[0].startswith("./") or os.path.isabs(tokens[0])):
    # A direct invocation is admitted only for a reviewed, literal .sh test
    # entrypoint below; it is not a general executable escape hatch.
    direct_script = True
    shell_name = ""
else:
    print("coordinator-script-route executable=unknown reason=expected trusted bash/sh or one reviewed direct .sh test entrypoint")
    raise SystemExit(1)
resolved_shell = shutil.which(shell_name) if shell_name else None
trusted_shells = {
    "bash": {"/bin/bash", "/usr/bin/bash", "/usr/local/bin/bash"},
    "sh": {"/bin/sh", "/usr/bin/sh", "/usr/local/bin/sh"},
}

if not direct_script and (not resolved_shell or os.path.realpath(resolved_shell) not in trusted_shells[shell_name]):
    print("coordinator-script-route executable=" + shell_name + " reason=resolved executable is not trusted")
    raise SystemExit(1)
values = [os.environ.get(name, "") for name in (
    "CODEX_APPROVED_REPO_ROOT_1", "CODEX_APPROVED_REPO_ROOT_2",
    "CODEX_APPROVED_REPO_ROOT_3", "CODEX_PROOF_ROOT_CANONICAL",
    "CODEX_PROOF_ROOT_CONFIGURED", "CODEX_PROOF_ROOT_STABLE_ALIAS",
    "CODEX_CONFIGURED_HOME", "CODEX_HOME", "KIMI_CODE_HOME",
)]
values.append(os.path.join(os.environ.get("HOME", ""), ".kimi-code"))
roots = {
    value for value in values
    if value and os.path.isabs(value) and os.path.isdir(value)
    and not os.path.islink(value) and os.path.realpath(value) == value
}
configured_proof = os.environ.get("CODEX_PROOF_ROOT_CONFIGURED", "")
canonical_proof = os.environ.get("CODEX_PROOF_ROOT_CANONICAL", "")
if (configured_proof and canonical_proof and
        os.path.isabs(configured_proof) and os.path.isabs(canonical_proof) and
        os.path.normpath(configured_proof) == configured_proof and
        os.path.normpath(canonical_proof) == canonical_proof and
        os.path.basename(configured_proof) == os.path.basename(canonical_proof) == "codex-proof" and
        os.path.basename(os.path.dirname(configured_proof)) == os.path.basename(os.path.dirname(canonical_proof)) == ".cache" and
        os.path.isdir(configured_proof) and os.path.isdir(canonical_proof)):
    configured_anchor = os.path.dirname(os.path.dirname(configured_proof))
    canonical_anchor = os.path.dirname(os.path.dirname(canonical_proof))
    for value in values:
        if not value or not os.path.isabs(value) or os.path.normpath(value) != value:
            continue
        try:
            relative = os.path.relpath(value, configured_anchor)
        except ValueError:
            continue
        if relative == ".." or relative.startswith(".." + os.sep):
            continue
        alias = os.path.normpath(os.path.join(canonical_anchor, relative))
        if os.path.isdir(alias) and not os.path.islink(alias):
            roots.add(alias)
if not roots:
    print("coordinator-script-route root=<none> reason=no approved canonical root")
    raise SystemExit(1)

# Filename allowlists are not trust anchors: a worker or another local
# process can rewrite a reviewed test between admission and execution.  Bind
# every coordinator entrypoint to the reviewed bytes for the two canonical
# repositories, and fail closed when a file is absent from this manifest.
reviewed_digests = {
    ".codex": {
        "hooks/install-pre-commit-go-mod.sh": "7d98c8e7a6644fab8383631c58a30ec8f6bf62572b18cce74b6241462d6c7cd0",
        "hooks/tests/run.sh": "09c23c2490a8c3a134a5c21de6aa8eec30eea67ba58548f2ed75189a37045380",
        "hooks/tests/test-eci-fast-path.sh": "dc1233b4c496954d496c6645f4304aadb6e07b22fb1e1a6fc4f820d81811bd3a",
        "hooks/tests/test-eci-post-compact-refresh.sh": "7735c9d4b5d71d1f57dffedbafae32ce818019c865ba7250520971010aca66cf",
        "hooks/tests/test-eci-review-gate.sh": "6fdb8d8a0e8a4aab410f96d5030225a7d873605956d93ae3f0d26dad93be8a88",
        "hooks/tests/test-session-snapshot-refresh.sh": "bd093a9a8a6e282e3a4d48b1905ebac59a370a273b0c416bec5defd5129d428d",
        "hooks/tests/test-validate-bash-classifier.sh": "d4e488073a53300581510b5293404fea82640e346a15555a6fb2d45d7d397e5e",
        "hooks/tests/test-validate-bash-git-approvals.sh": "62553126dffa4373880142dd802d5737da29a9535868f7e7b7568f0b920c8261",
        "hooks/tests/test-policy-design-boundary.sh": "e084a05ad1ed7a001c6bbd7816a36ba5aad386d91fd27012329d1671d87a1de3",
        "hooks/tests/test-eci-edit-control-paths.sh": "ba7e26be82c09748e57c4c79d092ab46420a40f116bcdff2e6988e00142ce2f7",
        "hooks/tests/test-eci-diagnostic-specificity.sh": "fbb40f2b717834f3eaad96535a3c3ed52e576f25c2ce8b678d84b6add2ab4dc0",
        "hooks/tests/test-eci-marker-scope.sh": "64300cd57c7feef8b1de358078541acba4f1844e9e789c153cae56acfc089875",
        "hooks/tests/test-pretooluse-latency.sh": "7e8f73f23dafd6389103c97f599c558aa56a6b46ee5d8d82fc32df3ed4e7dcca",
        "hooks/tests/test-pre-commit-go-mod.sh": "39256e08a8512ca00263dfb8b4a67593c512a3488c8ea16e684f68ffd6b095a4",
        "hooks/tests/test-eci-command-syntax-gating.sh": "78fe91f5dfd1d92c051ab260eb62dd47c47a4bed0362179c3c53d007a43894d8",
        "hooks/tests/test-go-mod-hook-parity.sh": "63ba8579491e894bfb2adfe6d84e1bd056c1d814c4c5c0e97c25e417c3cbb5cf",
        "hooks/tests/test-stop-loop-guidance.sh": "f8fa9f1f036a8511a029d90e5466736b292dd089106a5fc735d4336d79d538d6",
    },
    ".kimi-code": {
        "hooks/install-pre-commit-go-mod.sh": "7d98c8e7a6644fab8383631c58a30ec8f6bf62572b18cce74b6241462d6c7cd0",
        "hooks/tests/run.sh": "dc8509023753cec8bd7fef5184474ba4bd1ab92444fec78942fa4ea96e948f9c",
        "hooks/tests/test-eci-edit-control-paths.sh": "299dc076d014c1f0f5c389f6563372ed93a1dba90d0d105637558962e645c727",
        "hooks/tests/test-eci-diagnostic-specificity.sh": "fbb40f2b717834f3eaad96535a3c3ed52e576f25c2ce8b678d84b6add2ab4dc0",
        "hooks/tests/test-pretooluse-latency.sh": "de2fed19b0dc80d0df1547c78a2bcd404f919a5b07f3ee5b9aed5f800582a6b3",
        "hooks/tests/test-pre-commit-go-mod.sh": "daa6dee604ca9f63b85f842a468965b843bfa77095c39d0476ff43ea0def5b24",
        "hooks/tests/test-eci-command-syntax-gating.sh": "9bc3e892a1d8536bb4fda43d5d6ff78c1e8c8075e2122b1c4bbef4d6da72e1f1",
        "hooks/tests/test-go-mod-hook-parity.sh": "63ba8579491e894bfb2adfe6d84e1bd056c1d814c4c5c0e97c25e417c3cbb5cf",
        "hooks/tests/test-block-no-progress.sh": "443bb67f96bdfedfe31e30e626d38abc58a4637551ca97ab4d564a2632731937",
        "hooks/tests/test-stop-loop-guidance.sh": "d05353d7cccb0c2f46b9b1745ee4f9f064483fc23f0fad59d82a8de7cd353279",
        "hooks/tests/test-stop-marker-validation.sh": "3483c29a26283369929f782c18e0c91bc332748730dbc6539a1a22033e39bd57",
    },
}

def reviewed_script(relative, resolved):
    matches = sorted(
        (root for root in roots if resolved == root or resolved.startswith(root + os.sep)),
        key=len, reverse=True,
    )
    if not matches:
        return False
    expected = reviewed_digests.get(os.path.basename(matches[0]), {}).get(relative)
    if expected is None:
        return False
    value = hashlib.sha256()
    try:
        with open(resolved, "rb") as stream:
            for chunk in iter(lambda: stream.read(65536), b""):
                value.update(chunk)
    except OSError:
        return False
    return value.hexdigest() == expected

# A coordinator may run a finite verification batch, but only as a literal
# chain of reviewed test entrypoints.  Every segment is checked independently
# below; allowing && here does not admit arbitrary shell composition, wrappers,
# substitutions, redirects, or mutation.
if "&&" in tokens:
    chunks, current = [], []
    for token in tokens:
        if token == "&&":
            if not current:
                print("coordinator-script-route batch=invalid reason=empty segment before &&")
                raise SystemExit(1)
            chunks.append(current)
            current = []
        else:
            current.append(token)
    if not current:
        print("coordinator-script-route batch=invalid reason=empty segment after &&")
        raise SystemExit(1)
    chunks.append(current)
    if len(chunks) < 2 or len(chunks) > 16:
        print("coordinator-script-route batch=count=" + str(len(chunks)) + " reason=expected 2..16 reviewed segments")
        raise SystemExit(1)
    for segment_index, segment in enumerate(chunks, 1):
        if not segment or segment[0] not in {"bash", "sh"} or len(segment) not in {2, 3} or (len(segment) == 3 and segment[1] != "-n"):
            print("coordinator-script-route batch=segment-" + str(segment_index) + " reason=expected bash/sh SCRIPT or bash/sh -n SCRIPT")
            raise SystemExit(1)
        script = segment[-1]
        if not script or script.startswith("-") or any(mark in script for mark in ("$", "`", "..")):
            print("coordinator-script-route batch=segment-" + str(segment_index) + " script=" + script + " reason=non-literal or traversal path")
            raise SystemExit(1)
        candidate = script if os.path.isabs(script) else os.path.abspath(os.path.join(hook_cwd, script))
        if os.path.normpath(candidate) != candidate:
            print("coordinator-script-route batch=segment-" + str(segment_index) + " script=" + script + " reason=non-canonical path spelling")
            raise SystemExit(1)
        resolved = os.path.realpath(candidate)
        if not any(resolved == root or resolved.startswith(root + os.sep) for root in roots):
            print("coordinator-script-route batch=segment-" + str(segment_index) + " script=" + script + " reason=resolved path is outside approved roots")
            raise SystemExit(1)
        if not os.path.isfile(candidate) or os.path.islink(candidate) or not candidate.endswith(".sh"):
            print("coordinator-script-route batch=segment-" + str(segment_index) + " script=" + script + " reason=regular non-symlink .sh file required")
            raise SystemExit(1)
        if len(segment) == 2:
            matching_roots = sorted(
                (root for root in roots if resolved == root or resolved.startswith(root + os.sep)),
                key=len, reverse=True,
            )
            relative = os.path.relpath(resolved, matching_roots[0]) if matching_roots else ""
            if not reviewed_script(relative, resolved):
                print("coordinator-script-route batch=segment-" + str(segment_index) + " script=" + script + " reason=script is absent from or differs from the reviewed digest manifest")
                raise SystemExit(1)
    print("ok")
    raise SystemExit(0)
if trace_pipeline:
    tail_path = shutil.which("tail")
    tail_real = os.path.realpath(tail_path) if tail_path else ""
    trusted_tail_dirs = ("/bin", "/usr/bin", "/usr/local/bin", "/usr/lib/cargo/bin/coreutils")
    if (not tail_path or not tail_real or not os.path.isabs(tail_real)
            or not os.path.isfile(tail_real) or not os.access(tail_real, os.X_OK)
            or not any(tail_real == directory or tail_real.startswith(directory + os.sep)
                       for directory in trusted_tail_dirs)):
        print("coordinator-script-route trace=sink reason=resolved tail executable is not trusted")
        raise SystemExit(1)
    script = tokens[-1]
    syntax_only = "-n" in bounded_trace_flags
    repair_peer = None
elif direct_script:
    script = tokens[0]
    syntax_only = False
    repair_peer = None
elif bounded_trace_flags:
    # Coordinator-only shell diagnostics are bounded to one reviewed .sh
    # entrypoint; only the finite -x/-n flag grammar above is accepted.
    script = tokens[-1]
    syntax_only = "-n" in bounded_trace_flags
    repair_peer = None
elif len(tokens) == 2:
    script = tokens[1]
    syntax_only = False
    repair_peer = None
elif len(tokens) == 4 and tokens[2] == "--repair-hardlink":
    script = tokens[1]
    syntax_only = False
    repair_peer = tokens[3]
else:
    print("coordinator-script-route command=" + tokens[0] + " reason=expected a reviewed SCRIPT, optional unique -x/-n diagnostics, or bounded hard-link repair arguments")
    raise SystemExit(1)
if not script or script.startswith("-") or any(mark in script for mark in ("$", "`", "..")):
    print("coordinator-script-route script=" + script + " reason=non-literal or traversal path")
    raise SystemExit(1)
candidate = script if os.path.isabs(script) else os.path.abspath(os.path.join(hook_cwd, script))
if not os.path.isfile(candidate):
    companion_candidates = []
    for root in sorted(roots):
        alternative = os.path.normpath(os.path.join(root, script))
        if (alternative != candidate and
                os.path.isfile(alternative) and
                not os.path.islink(alternative) and
                os.path.realpath(alternative) == alternative and
                any(alternative == approved_root or alternative.startswith(approved_root + os.sep)
                    for approved_root in roots)):
            companion_candidates.append(alternative)
    if len(companion_candidates) == 1:
        candidate = companion_candidates[0]
if os.path.normpath(candidate) != candidate:
    print("coordinator-script-route script=" + script + " reason=non-canonical path spelling")
    raise SystemExit(1)
resolved = os.path.realpath(candidate)
if not any(resolved == root or resolved.startswith(root + os.sep) for root in roots):
    print("coordinator-script-route script=" + script + " reason=resolved path is outside approved roots")
    raise SystemExit(1)
if not os.path.isfile(candidate) or os.path.islink(candidate) or not candidate.endswith(".sh"):
    print("coordinator-script-route script=" + script + " reason=regular non-symlink .sh file required")
    raise SystemExit(1)
if not syntax_only:
    matching_roots = sorted(
        (root for root in roots if resolved == root or resolved.startswith(root + os.sep)),
        key=len, reverse=True,
    )
    relative = os.path.relpath(resolved, matching_roots[0]) if matching_roots else ""
    installer_route = (
        not direct_script and shell_name == "bash" and repair_peer is None and
        relative == "hooks/install-pre-commit-go-mod.sh"
    )
    if installer_route:
        if not reviewed_script(relative, resolved):
            print("coordinator-script-route installer=" + script + " reason=installer differs from the reviewed digest manifest")
            raise SystemExit(1)
    elif repair_peer is not None:
        project_roots = {
            os.path.realpath(value)
            for value in (
                os.environ.get("CODEX_HOME") or os.path.join(os.environ.get("HOME", ""), ".codex"),
                os.environ.get("KIMI_CODE_HOME") or os.path.join(os.environ.get("HOME", ""), ".kimi-code"),
            )
            if value and os.path.isabs(value) and os.path.isdir(value) and not os.path.islink(value)
        }
        if (relative != "hooks/install-pre-commit-go-mod.sh" or repair_peer.startswith("-") or
                os.path.normpath(repair_peer) != repair_peer or os.path.islink(repair_peer) or
                os.path.realpath(repair_peer) not in project_roots or os.path.realpath(repair_peer) == os.path.realpath(hook_cwd)):
            print("coordinator-script-route hard-link-repair reason=installer and peer must be the other canonical Codex/Kimi repository root")
            raise SystemExit(1)
    elif not reviewed_script(relative, resolved):
        print("coordinator-script-route script=" + script + " reason=script is absent from or differs from the reviewed digest manifest")
        raise SystemExit(1)
print("ok")
PY
  )" && {
    COORDINATOR_SCRIPT_ROUTE_DETAIL=""
    return 0
  }
  COORDINATOR_SCRIPT_ROUTE_DETAIL="${detail:-coordinator-script-route reason=command is outside approved verification grammar}"
  return 1
}

coordinator_hardlink_repair_shape() {
  python3 - "$1" <<'PY'
import os
import shlex
import sys

try:
    tokens = shlex.split(sys.argv[1], posix=True)
except ValueError:
    raise SystemExit(1)
if len(tokens) < 4 or tokens[0] not in {"bash", "sh", "dash", "zsh"}:
    raise SystemExit(1)
for index in range(1, len(tokens) - 1):
    if (os.path.basename(tokens[index]) == "install-pre-commit-go-mod.sh" and
            tokens[index + 1] == "--repair-hardlink"):
        raise SystemExit(0)
raise SystemExit(1)
PY
}

if [ "${#syntax_eci_markers[@]}" -gt 0 ] && [ "$hook_is_subagent" != true ] &&
  coordinator_hardlink_repair_shape "$command" && ! coordinator_script_route "$command"; then
  deny_eci "ECI_COORDINATOR_ROUTE_ARGUMENTS_DENIED" "coordinator-hardlink-repair" \
    "ECI coordinator hard-link repair route denied malformed or unsafe arguments: ${COORDINATOR_SCRIPT_ROUTE_DETAIL:-command=$(eci_command_identity_subject "$command")}; predicate=coordinator-hardlink-repair; reason=the canonical installer requires a distinct canonical Codex/Kimi peer repository root" \
    "invoke the canonical install-pre-commit-go-mod.sh --repair-hardlink with the other provider’s canonical repository root; do not use the current repository as its own peer"
fi

coordinator_go_hook_installer_identity() {
  python3 - "$1" "$cwd" "$HOOK_DIR" "${KIMI_CODE_HOME:-${HOME:-}/.kimi-code}" <<'PY'
import os
import shlex
import sys

text, hook_cwd, hook_dir, peer_home = sys.argv[1:]
try:
    tokens = shlex.split(text, posix=True)
except ValueError:
    raise SystemExit(1)
if not tokens:
    raise SystemExit(1)
index = 0
if os.path.basename(tokens[0]) in {"bash", "sh", "dash", "zsh"}:
    index = 1
if index >= len(tokens):
    raise SystemExit(1)
script = os.path.expanduser(tokens[index])
candidate = script if os.path.isabs(script) else os.path.abspath(os.path.join(hook_cwd, script))
candidate = os.path.normpath(candidate)
roots = {os.path.realpath(os.path.dirname(hook_dir))}
if peer_home and os.path.isabs(peer_home) and os.path.isdir(peer_home):
    roots.add(os.path.realpath(peer_home))
for root in roots:
    expected = os.path.join(root, "hooks", "install-pre-commit-go-mod.sh")
    if (candidate == expected and os.path.isfile(candidate) and not os.path.islink(candidate)
            and os.path.realpath(candidate) == candidate):
        print("canonical_target=%s argv=%s" % (candidate, tokens[index + 1:]))
        raise SystemExit(0)
raise SystemExit(1)
PY
}

coordinator_inspection_route() {
  [ "$hook_is_subagent" != true ] || return 1
  local detail
  detail="$(python3 - "$1" "$cwd" <<'PY'
import os
import re
import shlex
import shutil
import sys

command, hook_cwd = sys.argv[1], sys.argv[2]
lex_command = command.replace("2>/dev/null", "2 > /dev/null")
def reject(reason):
    print("coordinator-inspection-route command=" + command + " reason=" + reason)
    raise SystemExit(1)

if any(mark in command for mark in ("\n", "\r", "`", "$(", "${")):
    reject("literal command contains newline or shell substitution")
try:
    lexer = shlex.shlex(lex_command, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    tokens = list(lexer)
except ValueError:
    reject("shell quoting is unbalanced")
unsafe = {";", "&", "&&", "||", "(", ")", ">", ">>", "<", "<<", "<<<", ">|", ">&", "<&"}
for token_index, token in enumerate(tokens):
    if token == "2>/dev/null":
        continue
    if token in unsafe and not (
        token == ">" and token_index > 0 and token_index + 1 < len(tokens)
        and tokens[token_index - 1] == "2" and tokens[token_index + 1] == "/dev/null"
    ):
        reject("operator/token=" + token)

def trusted(name):
    resolved = shutil.which(name)
    if not resolved or not os.path.isabs(resolved):
        return False
    real = os.path.realpath(resolved)
    return os.path.isfile(real) and os.access(real, os.X_OK) and any(
        real == root or real.startswith(root + os.sep)
        for root in ("/bin", "/usr/bin", "/usr/local/bin", "/usr/lib/cargo/bin/coreutils")
    )

roots = set()
worker_home = os.path.realpath(
    os.environ.get("CODEX_HOME") or os.environ.get("KIMI_CODE_HOME") or ""
) if os.environ.get("CODEX_HOOK_IS_SUBAGENT") == "true" else ""
peer_homes = {
    os.path.realpath(os.path.join(os.environ.get("HOME", ""), ".codex")),
    os.path.realpath(os.path.join(os.environ.get("HOME", ""), ".kimi-code")),
}
for name in (
    "CODEX_APPROVED_REPO_ROOT_1", "CODEX_APPROVED_REPO_ROOT_2", "CODEX_APPROVED_REPO_ROOT_3",
    "CODEX_PROOF_ROOT_CANONICAL", "CODEX_PROOF_ROOT_CONFIGURED", "CODEX_PROOF_ROOT_STABLE_ALIAS",
    "CODEX_HOME", "KIMI_CODE_HOME",
):
    value = os.environ.get(name, "")
    if value and os.path.isabs(value) and os.path.normpath(value) == value and os.path.isdir(value):
        resolved = os.path.realpath(value)
        if (worker_home and resolved in peer_homes and resolved != worker_home):
            continue
        if not os.path.islink(value) and resolved == value:
            roots.add(value)
home = os.environ.get("HOME", "")
for value in (os.path.join(home, ".codex"), os.path.join(home, ".kimi-code")):
    resolved = os.path.realpath(value) if value else ""
    if (worker_home and resolved in peer_homes and resolved != worker_home):
        continue
    if value and os.path.isdir(value) and not os.path.islink(value) and resolved == value:
        roots.add(value)
if not roots:
    reject("no approved canonical inspection root")

def under_root(value):
    return any(value == root or value.startswith(root + os.sep) for root in roots)

def safe_path(value, base=hook_cwd):
    if not value or value.startswith("-") or any(mark in value for mark in ("$", "`", "\n", "\r", "*", "?", "[", "]", "(", ")")):
        return False
    if not os.path.isabs(value):
        if value != "." and any(component in {"", ".", ".."} for component in value.split("/")):
            return False
        value = os.path.normpath(os.path.join(base, value))
    if os.path.normpath(value) != value:
        return False
    return under_root(os.path.realpath(value))

def safe_repo(value):
    return bool(value and os.path.isabs(value) and os.path.normpath(value) == value
                and os.path.isdir(value) and not os.path.islink(value)
                and os.path.realpath(value) == value and under_root(value))

def bounded_number(value, maximum=10000):
    return bool(re.fullmatch(r"[1-9][0-9]{0,4}", value)) and int(value) <= maximum

def safe_literal(value):
    return bool(value) and not value.startswith("-") and not any(
        mark in value for mark in ("$", "`", "\n", "\r", "*", "?", "[", "]", "(", ")")
    )

def safe_pattern(value):
    return bool(value) and len(value) <= 512 and not any(mark in value for mark in ("\n", "\r", "`", "$(", "${"))

def safe_glob(value):
    return bool(value) and len(value) <= 128 and not any(mark in value for mark in ("$", "`", "\n", "\r"))

def safe_paths(values, base=hook_cwd, maximum=16):
    return bool(values) and len(values) <= maximum and all(safe_path(value, base) for value in values)

def safe_git_pathspec(value, allow_exclude_magic=False):
    """Validate one bounded literal Git read pathspec without resolving it."""
    if not value or len(value) > 4096 or value.startswith("-"):
        return False
    if any(ord(character) < 0x20 for character in value):
        return False
    if value.startswith(":("):
        suffix = value[len(":(exclude)"):]
        return (allow_exclude_magic and value.startswith(":(exclude)") and suffix and
                not any(mark in suffix for mark in ("$", "`", "\n", "\r", "*", "?", "[", "]", "(", ")")))
    if any(mark in value for mark in ("$", "`", "\n", "\r", "*", "?", "[", "]", "(", ")")):
        return False
    return True

def bounded_git_paths(options, known_options, allow_exclude_magic=False):
    """Split bounded Git options from literal pathspec operands."""
    paths = []
    explicit_delimiter = False
    for value in options:
        if value == "--":
            if explicit_delimiter:
                return False, [], False
            explicit_delimiter = True
            continue
        if not explicit_delimiter and value in known_options:
            continue
        if not explicit_delimiter and value.startswith("-"):
            return False, [], False
        if not safe_git_pathspec(value, allow_exclude_magic):
            return False, [], False
        paths.append(value)
        if len(paths) > 16:
            return False, [], False
    return True, paths, explicit_delimiter

def bounded_find(args):
    roots_found = []
    index = 0
    if args[:1] == ["-P"]:
        index = 1
    while index < len(args) and not args[index].startswith("-"):
        roots_found.append(args[index])
        index += 1
    if not safe_paths(roots_found) or index == len(args):
        return False
    seen_action = False
    while index < len(args):
        token = args[index]
        if token in {"-maxdepth", "-mindepth"}:
            if index + 1 >= len(args) or not bounded_number(args[index + 1], 32):
                return False
            index += 2
        elif token == "-type":
            if index + 1 >= len(args) or args[index + 1] not in {"b", "c", "d", "f", "l", "p", "s"}:
                return False
            index += 2
        elif token in {"-name", "-iname", "-path", "-ipath"}:
            if index + 1 >= len(args) or not safe_literal(args[index + 1]):
                return False
            index += 2
        elif token == "-o":
            index += 1
        elif token == "2" and index + 2 < len(args) and args[index + 1] == ">" and args[index + 2] == "/dev/null":
            index += 3
        elif token == "2>/dev/null":
            index += 1
        elif token in {"-print", "-print0", "-ls"}:
            seen_action = True
            index += 1
        else:
            return False
    # `find` defaults to `-print` when no explicit action is present.
    return True

def bounded_options_and_paths(args, options, option_arguments=(), base=hook_cwd):
    paths = []
    index = 0
    options = set(options)
    option_arguments = set(option_arguments)
    while index < len(args):
        token = args[index]
        if token == "--":
            paths.extend(args[index + 1:])
            break
        if token in option_arguments:
            if index + 1 >= len(args) or not bounded_number(args[index + 1]):
                return False
            index += 2
        elif ((token.startswith("-n") and token[2:].isdigit()) or
              (token.startswith("-") and token[1:].isdigit())) and 0 < int(token.lstrip("-n")) <= 10000:
            index += 1
        elif token.startswith("--lines="):
            if not bounded_number(token.split("=", 1)[1]):
                return False
            index += 1
        elif token in options:
            index += 1
        elif token.startswith("-"):
            return False
        else:
            paths.append(token)
            index += 1
    return not paths or safe_paths(paths, base)

def bounded_grep(args):
    flags = {"-n", "--line-number", "-i", "--ignore-case", "-F", "--fixed-strings",
             "-E", "--extended-regexp", "-I", "--binary-files=without-match", "-r", "-R"}
    pattern = False
    paths = []
    index = 0
    while index < len(args):
        token = args[index]
        if token == "--":
            paths.extend(args[index + 1:])
            break
        if token in flags:
            index += 1
        elif token.startswith("-"):
            return False
        elif not pattern:
            pattern = safe_pattern(token)
            index += 1
        else:
            paths.append(token)
            index += 1
    return pattern and (not paths or safe_paths(paths))

def bounded_rg(args):
    flags = {"-n", "--line-number", "-i", "--ignore-case", "-F", "--fixed-strings",
             "-l", "--files-with-matches", "-c", "--count", "--count-matches",
             "--hidden", "--no-ignore", "--files"}
    pattern = False
    files_mode = False
    paths = []
    index = 0
    while index < len(args):
        token = args[index]
        if token == "--":
            paths.extend(args[index + 1:])
            break
        if token in {"-g", "--glob"}:
            if index + 1 >= len(args) or not safe_glob(args[index + 1]):
                return False
            index += 2
        elif token in {"-A", "--after-context", "-B", "--before-context", "-C", "--context"}:
            if index + 1 >= len(args) or not bounded_number(args[index + 1], 1000):
                return False
            index += 2
        elif re.fullmatch(r"-[ABC][1-9][0-9]{0,3}", token):
            if int(token[2:]) > 1000:
                return False
            index += 1
        elif re.fullmatch(r"--(?:after-context|before-context|context)=[1-9][0-9]{0,3}", token):
            if int(token.split("=", 1)[1]) > 1000:
                return False
            index += 1
        elif token in flags:
            files_mode = files_mode or token == "--files"
            index += 1
        elif token.startswith("-"):
            return False
        elif not pattern and not files_mode:
            pattern = safe_pattern(token)
            index += 1
        else:
            paths.append(token)
            index += 1
    return (pattern or files_mode) and (not paths or safe_paths(paths))

def bounded_stat(args):
    formats = {"%a %n", "%A %n", "%i %a %n", "%i %a %h %n", "%d:%i %a %h %n",
               "%d:%i %F", "%d:%i %F %n", "%F %N", "%F %s %n", "%y %n", "%y %s %n"}
    paths = []
    index = 0
    while index < len(args):
        token = args[index]
        if token in {"-c", "--format", "-Lc", "-cL"}:
            if index + 1 >= len(args) or args[index + 1] not in formats:
                return False
            index += 2
        elif token.startswith("--format="):
            if token.split("=", 1)[1] not in formats:
                return False
            index += 1
        elif token in {"-L", "--dereference"}:
            index += 1
        elif token.startswith("-"):
            return False
        else:
            paths.append(token)
            index += 1
    return safe_paths(paths)

def bounded_git(args):
    repo = os.path.realpath(hook_cwd)
    index = 0
    if args[:1] == ["-C"]:
        if len(args) < 2:
            return False
        repo = args[1]
        index = 2
    if not safe_repo(repo) or index >= len(args):
        return False
    subcommand = args[index]
    options = args[index + 1:]
    if subcommand == "status":
        valid, _, _ = bounded_git_paths(options, {"--short", "--branch", "--porcelain"})
        return valid
    if subcommand == "submodule":
        return options == ["status"]
    if subcommand == "log":
        known_options = {"--oneline", "--decorate", "--no-decorate", "--stat"}
        known_options.update(value for value in options
                             if value.startswith("-") and bounded_number(value[1:]))
        valid, _, _ = bounded_git_paths(options, known_options, allow_exclude_magic=True)
        return valid
    if subcommand == "diff":
        known_options = {
            "--cached", "--check", "--name-only", "--name-status", "--stat",
            "--staged", "--submodule",
        }
        for value in options:
            if re.fullmatch(r"-U[0-9]{1,4}", value) and int(value[2:]) <= 1000:
                known_options.add(value)
            if re.fullmatch(r"--unified=[0-9]{1,4}", value) and int(value.split("=", 1)[1]) <= 1000:
                known_options.add(value)
        valid, _, _ = bounded_git_paths(options, known_options)
        return valid
    if subcommand == "show":
        known_options = {"--stat", "--oneline", "--no-patch", "--name-only", "--name-status"}
        known_options.update(value for value in options
                             if value.startswith("-") and bounded_number(value[1:]))
        valid, _, _ = bounded_git_paths(options, known_options)
        return valid
    return False

def safe_bounded_segment(segment):
    if not segment:
        return False
    if segment[0] != os.path.basename(segment[0]):
        return False
    command = os.path.basename(segment[0])
    args = segment[1:]
    if command not in {"cat", "cut", "date", "dirname", "du", "grep", "egrep", "fgrep",
                       "find", "head", "jq", "ls", "nl", "printf", "pwd", "readlink",
                       "realpath", "rg", "sed", "sort", "stat", "tail", "tr", "uniq", "ps",
                       "wc", "which", "printenv", "git"}:
        return False
    if not trusted(command):
        return False
    if command == "pwd":
        return not args
    if command == "ps":
        formats = {"pid,cmd", "pid=,cmd=", "pid,ppid,cmd", "pid=,ppid,cmd=",
                   "pid,etime,stat,cmd", "pid=,etime=,stat=,cmd=",
                   "pid,etimes,stat,cmd", "pid=,etimes=,stat=,cmd=",
                   "pid,ppid,etimes,stat,args", "pid=,ppid=,etimes=,stat=,args="}
        index = 0
        saw_format = False
        while index < len(args):
            token = args[index]
            if token in {"-o", "--format"} and index + 1 < len(args):
                if args[index + 1] not in formats or saw_format:
                    return False
                saw_format = True
                index += 2
            elif token == "-eo" and index + 1 < len(args) and args[index + 1] in formats and not saw_format:
                saw_format = True
                index += 2
            elif ((token.startswith("-o") and token[2:] in formats) or
                  (token.startswith("-e") and token[2:] in formats)) and not saw_format:
                saw_format = True
                index += 1
            elif token.startswith("--format=") and token.split("=", 1)[1] in formats and not saw_format:
                saw_format = True
                index += 1
            elif token in {"-e", "--everyone", "--no-headers"}:
                index += 1
            elif token in {"-p", "--pid"} and index + 1 < len(args) and re.fullmatch(r"[1-9][0-9]*(,[1-9][0-9]*)*", args[index + 1]):
                index += 2
            elif token.startswith("--pid=") and re.fullmatch(r"--pid=[1-9][0-9]*(,[1-9][0-9]*)*", token):
                index += 1
            else:
                return False
        return saw_format
    if command == "printenv":
        # The shared role-neutral environment boundary owns query admission.
        return False
    if command == "date":
        return args in (["-u", "+%Y-%m-%dT%H:%M:%SZ"], ["--utc", "+%Y-%m-%dT%H:%M:%SZ"])
    if command == "printf":
        return bool(args) and len(args) <= 16 and all(safe_literal(value) for value in args)
    if command == "which":
        return bool(args) and len(args) <= 16 and all(re.fullmatch(r"[A-Za-z0-9_.+-]+", value) for value in args)
    if command == "find":
        return bounded_find(args)
    if command == "git":
        return bounded_git(args)
    if command in {"rg"}:
        return bounded_rg(args)
    if command in {"grep", "egrep", "fgrep"}:
        return bounded_grep(args)
    if command == "stat":
        return bounded_stat(args)
    if command == "sed":
        if len(args) not in {2, 3} or args[0] not in {"-n", "--quiet"}:
            return False
        return bool(re.fullmatch(r"[1-9][0-9]{0,4}(,[1-9][0-9]{0,4})?p", args[1])) and (len(args) == 2 or safe_path(args[2]))
    if command in {"head", "tail"}:
        return bounded_options_and_paths(args, {"-q", "--quiet", "-v", "--verbose"}, {"-n", "--lines"})
    if command == "ls":
        ls_options = {"-a", "-A", "-l", "-h", "-i", "-1", "-d", "--all", "--almost-all", "--human-readable"}
        clusters = [value for value in args if value.startswith("-") and len(value) > 2 and not value.startswith("--")]
        if any(not re.fullmatch(r"-[AaAdhil1]+", value) for value in clusters):
            return False
        return bounded_options_and_paths(
            [value for value in args if value not in clusters]
            if clusters
            else args,
            ls_options,
        )
    if command == "du":
        return bounded_options_and_paths(args, {"-h", "--human-readable", "-s", "--summarize", "-a", "--all", "-x", "--one-file-system"})
    if command in {"cat", "dirname", "readlink", "realpath", "wc", "nl"}:
        return bool(args) and bounded_options_and_paths(args, {"-n", "-b", "-ba", "-q", "--quiet", "-e", "--canonicalize-existing", "-f", "--canonicalize", "-m", "--bytes", "-l", "--lines", "-w", "--words"})
    if command == "jq":
        if not args or any(value.startswith("-") for value in args):
            return False
        paths = [value for value in args[1:] if value != "-"]
        return safe_literal(args[0]) and (not paths or safe_paths(paths))
    if command == "cut":
        paths = []
        index = 0
        while index < len(args):
            token = args[index]
            if token in {"-d", "--delimiter", "-f", "--fields", "-b", "--bytes", "-c", "--characters"}:
                if index + 1 >= len(args) or not safe_literal(args[index + 1]):
                    return False
                index += 2
            elif token.startswith(("--delimiter=", "--fields=", "--bytes=", "--characters=")):
                index += 1
            elif token == "--":
                paths.extend(args[index + 1:])
                break
            elif token.startswith("-"):
                return False
            else:
                paths.append(token)
                index += 1
        return bool(args) and (not paths or safe_paths(paths))
    if command in {"sort", "tr", "uniq"}:
        if any(value in {"-o", "--output", "--output-delimiter"} or value.startswith("--output=") for value in args):
            return False
        paths = [value for value in args if not value.startswith("-")]
        return len(args) <= 16 and all(safe_literal(value) for value in args) and (not paths or safe_paths(paths))
    return False

def bounded_command_lookup():
    # `command -v` and `type -a` are coordinator context probes: they inspect
    # PATH resolution and execute no target. Keep the name set finite and
    # require a real, trusted executable.
    if len(tokens) != 3 or tokens[0] not in {"command", "type"}:
        return False
    if tokens[0] == "command" and tokens[1] not in {"-v", "--verbose"}:
        return False
    if tokens[0] == "type" and tokens[1] != "-a":
        return False
    name = tokens[2]
    allowed = {"bash", "cat", "curl", "date", "find", "git", "go", "grep",
               "head", "jq", "make", "python3", "rg", "sed", "stat", "tail",
               "which", "eci-active"}
    if not re.fullmatch(r"[A-Za-z0-9_.+-]+", name) or name not in allowed:
        return False
    resolved = shutil.which(name)
    if not resolved or not os.path.isabs(resolved):
        return False
    real = os.path.realpath(resolved)
    if name == "eci-active":
        homes = (os.path.join(os.environ.get("HOME", ""), ".codex", "bin", "eci-active"),
                 os.path.join(os.environ.get("HOME", ""), ".kimi-code", "bin", "eci-active"))
        return real in {os.path.realpath(path) for path in homes if os.path.isfile(path)}
    return os.path.isfile(real) and os.access(real, os.X_OK) and any(
        real == root or real.startswith(root + os.sep)
        for root in ("/bin", "/usr/bin", "/usr/local/bin", "/usr/local/go/bin", "/usr/lib/cargo/bin/coreutils")
    )

if bounded_command_lookup():
    print("ok")
    raise SystemExit(0)

if "|" in tokens:
    segments, current = [], []
    for token in tokens:
        if token == "|":
            segments.append(current)
            current = []
        else:
            current.append(token)
    segments.append(current)
    if len(segments) <= 8 and all(safe_bounded_segment(segment) for segment in segments):
        print("ok")
        raise SystemExit(0)
    reject("pipeline contains a command outside bounded coordinator inspection grammar")
if safe_bounded_segment(tokens):
    print("ok")
    raise SystemExit(0)

def safe_git_grep(args):
    flags = {"-n", "--line-number", "-i", "--ignore-case", "-F", "--fixed-strings", "-I", "--no-textconv"}
    pattern = False
    index = 0
    while index < len(args):
        token = args[index]
        if token == "--":
            paths = args[index + 1:]
            return pattern and len(paths) <= 16 and all(
                path and not path.startswith("-") and not os.path.isabs(path)
                and all(component not in {"", ".", ".."} for component in path.split("/"))
                and not any(mark in path for mark in ("$", "`", "\n", "\r", "*", "?", "[", "]", "(", ")"))
                for path in paths
            )
        if token in flags:
            index += 1
            continue
        if token in {"-e", "--regexp"}:
            if index + 1 >= len(args) or not args[index + 1]:
                return False
            pattern = True
            index += 2
            continue
        if token.startswith("--regexp="):
            if not token.split("=", 1)[1]:
                return False
            pattern = True
            index += 1
            continue
        if not pattern:
            if not token or token.startswith("-"):
                return False
            pattern = True
            index += 1
            continue
        return False
    return pattern

if tokens and tokens[0] == "git":
    if not trusted("git"):
        reject("executable=git is not trusted")
    index = 1
    repo = os.path.realpath(hook_cwd)
    if index + 1 < len(tokens) and tokens[index] == "-C":
        repo = tokens[index + 1]
        index += 2
    if not safe_repo(repo) or tokens[index:index + 1] != ["grep"] or not safe_git_grep(tokens[index + 1:]):
        reject("git grep requires an approved canonical repository and literal bounded pathspecs")
    print("ok")
    raise SystemExit(0)

if tokens and tokens[0] == "rg":
    if not trusted("rg"):
        reject("executable=rg is not trusted")
    flags = {"-n", "--line-number", "-i", "--ignore-case", "-F", "--fixed-strings", "-l", "--files-with-matches", "-c", "--count", "--count-matches", "--hidden", "--no-ignore", "--files"}
    args = tokens[1:]
    pattern = False
    files_mode = False
    paths = []
    index = 0
    while index < len(args):
        token = args[index]
        if token == "--":
            paths.extend(args[index + 1:])
            break
        if token in {"-g", "--glob"}:
            if index + 1 >= len(args) or not args[index + 1]:
                reject("rg glob argument is missing")
            index += 2
            continue
        if token in flags:
            files_mode = files_mode or token == "--files"
            index += 1
            continue
        if token.startswith("-"):
            reject("rg option=" + token + " is outside bounded inspection grammar")
        if not pattern and not files_mode:
            pattern = True
        else:
            paths.append(token)
        index += 1
    if not (pattern or files_mode) or len(paths) > 16 or not all(safe_path(path) for path in paths):
        reject("rg requires one literal pattern or --files and canonical approved paths")
    print("ok")
    raise SystemExit(0)

if tokens and tokens[0] == "stat":
    formats = {"%a %n", "%A %n", "%i %a %n", "%i %a %h %n", "%d:%i %a %h %n", "%d:%i %F", "%d:%i %F %n", "%F %N", "%F %s %n", "%y %n", "%y %s %n"}
    paths = []
    index = 1
    while index < len(tokens):
        token = tokens[index]
        if token in {"-c", "--format", "-Lc", "-cL"}:
            if index + 1 >= len(tokens) or tokens[index + 1] not in formats:
                reject("stat format is outside the bounded metadata grammar")
            index += 2
            continue
        if token.startswith("--format="):
            if token.split("=", 1)[1] not in formats:
                reject("stat format is outside the bounded metadata grammar")
            index += 1
            continue
        if token in {"-L", "--dereference"}:
            index += 1
            continue
        if token.startswith("-"):
            reject("stat option=" + token + " is outside bounded inspection grammar")
        paths.append(token)
        index += 1
    if not paths or len(paths) > 16 or not all(safe_path(path) for path in paths):
        reject("stat requires canonical paths under approved roots")
    print("ok")
    raise SystemExit(0)
reject("command is outside rg, git grep, and stat inspection grammar")
PY
  )" && {
    COORDINATOR_INSPECTION_ROUTE_DETAIL=""
    return 0
  }
  COORDINATOR_INSPECTION_ROUTE_DETAIL="${detail:-coordinator-inspection-route reason=command is outside bounded inspection grammar}"
  return 1
}

coordinator_compound_inspection_route() {
  [ "$hook_is_subagent" != true ] || return 1
  local segments detail segment
  detail="$(python3 - "$1" <<'PY'
import shlex
import sys

command = sys.argv[1]
if any(mark in command for mark in ("\n", "\r", "$", "`")):
    raise SystemExit(1)
try:
    lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    tokens = list(lexer)
except ValueError:
    raise SystemExit(1)
operators = [token for token in tokens if token in {"&&", "||"}]
if len(operators) < 1 or len(operators) > 7:
    raise SystemExit(1)
unsafe = {";", "&", "|", "(", ")", ">", ">>", "<", "<<", "<<<", ">|", ">&", "<&"}
if any(token in unsafe for token in tokens):
    raise SystemExit(1)
parts, current = [], []
for token in tokens:
    if token in {"&&", "||"}:
        if not current:
            raise SystemExit(1)
        parts.append(current)
        current = []
    else:
        current.append(token)
if not current:
    raise SystemExit(1)
parts.append(current)
if len(parts) > 8:
    raise SystemExit(1)
for part in parts:
    print(shlex.join(part))
PY
  )" || return 1
  [ -n "$detail" ] || return 1
  while IFS= read -r segment; do
    [ -n "$segment" ] || return 1
    coordinator_inspection_route "$segment" || coordinator_cleanup_route "$segment" || return 1
  done <<< "$detail"
  return 0
}

coordinator_date_route() {
  [ "$hook_is_subagent" != true ] || return 1
  case "$1" in
    "date -u +%Y-%m-%dT%H:%M:%SZ"|"date --utc +%Y-%m-%dT%H:%M:%SZ") ;;
    *) return 1 ;;
  esac
  python3 <<'PY'
import os
import shutil

resolved = shutil.which("date")
trusted = {
    "/bin/date", "/usr/bin/date", "/usr/local/bin/date",
    "/usr/lib/cargo/bin/coreutils/date",
}
raise SystemExit(0 if resolved and os.path.realpath(resolved) in trusted else 1)
PY
}

COORDINATOR_READLINK_ROUTE_DETAIL=""
coordinator_readlink_route() {
  [ "$hook_is_subagent" != true ] || return 1
  local detail
  detail="$(python3 - "$1" "$cwd" <<'PY'
import os
import shlex
import shutil
import sys

command, hook_cwd = sys.argv[1], sys.argv[2]
def reject(reason):
    print("coordinator-readlink-route command=" + command + " reason=" + reason)
    raise SystemExit(1)

if any(mark in command for mark in ("\n", "\r", "`", "$(", "${")):
    reject("literal command contains newline or shell substitution")
try:
    tokens = shlex.split(command, posix=True)
except ValueError:
    reject("shell quoting is unbalanced")
if not tokens or os.path.basename(tokens[0]) != "readlink":
    reject("expected readlink executable")
resolved = shutil.which("readlink")
trusted = {"/bin/readlink", "/usr/bin/readlink", "/usr/local/bin/readlink", "/usr/lib/cargo/bin/coreutils/readlink"}
if not resolved or os.path.realpath(resolved) not in trusted:
    reject("resolved readlink executable is not trusted")
options = {"-f", "-e", "-m", "--canonicalize", "--canonicalize-existing", "--canonicalize-missing"}
paths = []
for token in tokens[1:]:
    if token in options:
        continue
    if token.startswith("-"):
        reject("option=" + token + " is outside bounded readlink grammar")
    paths.append(token)
if not paths or len(paths) > 16:
    reject("readlink requires one to sixteen literal paths")
home = os.environ.get("HOME", "")
roots = set()
for raw in (
    os.environ.get("CODEX_HOME") or os.path.join(home, ".codex"),
    os.environ.get("KIMI_CODE_HOME") or os.path.join(home, ".kimi-code"),
    os.environ.get("CODEX_PROOF_ROOT_CANONICAL", ""),
    os.environ.get("KIMI_PROOF_ROOT_CANONICAL", ""),
):
    if raw and os.path.isabs(raw) and os.path.normpath(raw) == raw and os.path.isdir(raw):
        if not os.path.islink(raw) and os.path.realpath(raw) == raw:
            roots.add(raw)
if not roots:
    reject("no approved canonical inspection root")
def under_root(value):
    return any(value == root or value.startswith(root + os.sep) for root in roots)
for value in paths:
    if any(mark in value for mark in ("$", "`", "\n", "\r", "*", "?", "[", "]", "(", ")")):
        reject("path contains shell syntax or glob characters: " + value)
    candidate = value if os.path.isabs(value) else os.path.abspath(os.path.join(hook_cwd, value))
    if os.path.normpath(candidate) != candidate:
        reject("path is not normalized: " + value)
    # readlink -f is safe for a missing final component when its existing
    # parent resolves inside an approved root. Do not follow a symlinked
    # parent outside that root.
    probe = candidate
    while not os.path.lexists(probe) and probe != os.path.dirname(probe):
        probe = os.path.dirname(probe)
    if not under_root(os.path.realpath(probe)):
        reject("path or existing parent resolves outside approved roots: " + value)
print("ok")
PY
)" && {
    COORDINATOR_READLINK_ROUTE_DETAIL=""
    return 0
  }
  COORDINATOR_READLINK_ROUTE_DETAIL="${detail:-coordinator-readlink-route reason=command is outside bounded canonical-path grammar}"
  return 1
}

COORDINATOR_PEER_ECI_ROUTE_DETAIL=""
coordinator_peer_eci_route() {
  [ "$hook_is_subagent" != true ] || return 1
  local detail
  if detail="$(python3 - "$1" "${session_id:-}" <<'PY'
import hashlib
import os
import re
import shlex
import shutil
import sys

try:
    lexer = shlex.shlex(sys.argv[1], posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    shell_tokens = list(lexer)
except ValueError:
    raise SystemExit(1)
if any(token in {";", "&", "&&", "|", "||", "(", ")", ">", ">>", "<", "<<", "<<<", ">|", ">&", "<&"}
       for token in shell_tokens):
    raise SystemExit(1)
try:
    tokens = shlex.split(sys.argv[1], posix=True)
except ValueError:
    raise SystemExit(1)
if len(tokens) < 2:
    raise SystemExit(1)
active_session = sys.argv[2]
assignments = {}
env_wrapped = bool(tokens and os.path.basename(tokens[0]) == "env")
if env_wrapped:
    tokens.pop(0)
    if tokens and tokens[0] == "--":
        tokens.pop(0)
while tokens and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=.*", tokens[0]):
    name, value = tokens.pop(0).split("=", 1)
    if name in assignments or name not in {"CODEX_SESSION_ID", "KIMI_SESSION_ID", "TMPDIR"}:
        raise SystemExit(1)
    # Preserve an empty provider-session assignment long enough to report the
    # lifecycle identity mismatch with the expected and observed values.  An
    # empty identity remains invalid below; rejecting it here loses the
    # lifecycle-specific diagnostic and falls through to a generic argument
    # denial.
    if name != "TMPDIR" and value and not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}", value):
        raise SystemExit(1)
    assignments[name] = value
if len(tokens) < 2:
    raise SystemExit(1)
command = tokens[0]
if command == "eci-active":
    # Resolve the provider selected by PATH, then bind any explicit session
    # assignment to that provider's canonical executable and digest below.
    command = shutil.which(command) or ""
elif command.startswith("~/"):
    if command not in {"~/.codex/bin/eci-active", "~/.kimi-code/bin/eci-active"}:
        raise SystemExit(1)
    command = os.path.expanduser(command)
if not command or not os.path.isabs(command) or os.path.normpath(command) != command:
    raise SystemExit(1)
home = os.environ.get("HOME", "")
roots = (
    os.path.join(home, ".codex"),
    os.path.join(home, ".kimi-code"),
)
def reviewed_digest(root):
    """Read the atomically published provider receipt, if present.

    A missing receipt is tolerated for a canonical provider root so a fresh
    installation can bootstrap the sync route.  A malformed receipt is not
    tolerated: it must not silently turn into an identity bypass.
    """
    receipt = os.path.join(root, ".eci-runtime-sync-manifest")
    try:
        stat = os.lstat(receipt)
        if not stat or not os.path.isfile(receipt) or os.path.islink(receipt):
            return ""
        if stat.st_uid != os.getuid() or stat.st_mode & 0o002:
            return ""
        matches = []
        with open(receipt, "r", encoding="ascii") as stream:
            for line in stream:
                fields = line.rstrip("\n").split("\t")
                if len(fields) != 3 or fields[0] != "bin/eci-active":
                    continue
                if not re.fullmatch(r"[0-9a-f]{64}", fields[1]) or not re.fullmatch(r"[0-9]+", fields[2]):
                    return ""
                matches.append(fields[1])
        return matches[0] if len(matches) == 1 else ""
    except (OSError, UnicodeError):
        return None
def lexical_bind_alias(path):
    if os.path.islink(path):
        return False
    resolved = os.path.realpath(path)
    try:
        left = os.stat(path)
        right = os.stat(resolved)
    except OSError:
        return False
    return (left.st_dev, left.st_ino) == (right.st_dev, right.st_ino)

matched_root = None
for root in roots:
    if not (root and os.path.isabs(root) and os.path.isdir(root)
            and lexical_bind_alias(root)):
        continue
    candidate = os.path.join(root, "bin", "eci-active")
    if (command == candidate and os.path.isfile(candidate) and
            lexical_bind_alias(candidate) and
            os.access(candidate, os.X_OK)):
        digest = hashlib.sha256()
        with open(candidate, "rb") as stream:
            for chunk in iter(lambda: stream.read(131072), b""):
                digest.update(chunk)
        expected_digest = reviewed_digest(root)
        if expected_digest == "" or (expected_digest is not None and digest.hexdigest() != expected_digest):
            continue
        matched_root = root
        break
if matched_root is None:
    raise SystemExit(1)

expected_session_env = "KIMI_SESSION_ID" if os.path.basename(matched_root) == ".kimi-code" else "CODEX_SESSION_ID"
companion_session_env = "CODEX_SESSION_ID" if expected_session_env == "KIMI_SESSION_ID" else "KIMI_SESSION_ID"
if companion_session_env in assignments:
    print("provider session identity mismatch: expected_name=%s observed_name=%s" %
          (expected_session_env, companion_session_env))
    raise SystemExit(1)
if env_wrapped and expected_session_env not in assignments:
    print("provider session identity missing: expected_name=%s observed_name=<none>" % expected_session_env)
    raise SystemExit(1)
if expected_session_env in assignments and assignments[expected_session_env] != active_session:
    print("active session identity mismatch: expected=%s=%s observed=%s=%s" %
          (expected_session_env, active_session, expected_session_env,
           assignments[expected_session_env]))
    raise SystemExit(1)
if assignments and not set(assignments).issubset({expected_session_env, "TMPDIR"}):
    print("lifecycle environment contains unsupported assignment name")
    raise SystemExit(1)
if "TMPDIR" in assignments:
    tmpdir = assignments["TMPDIR"]
    home_tmp = os.path.join(home, "tmp") if home else ""
    canonical_home = os.path.realpath(home) if home else ""
    canonical_tmpdir = os.path.realpath(tmpdir) if os.path.isabs(tmpdir) else ""
    home_scoped = bool(canonical_home and
                       (canonical_tmpdir == canonical_home or
                        canonical_tmpdir.startswith(canonical_home + os.sep)))
    home_scoped = home_scoped or tmpdir == home_tmp
    if (not os.path.isabs(tmpdir) or os.path.normpath(tmpdir) != tmpdir or
            not os.path.isdir(tmpdir) or
            (canonical_tmpdir != tmpdir and not home_scoped) or
            canonical_tmpdir == "/tmp" or canonical_tmpdir.startswith("/tmp/")):
        print("TMPDIR must be a canonical non-system temporary directory: " + tmpdir)
        raise SystemExit(1)

def bounded_data(value, limit=8192):
    if not value or "\n" in value or "\r" in value:
        return False
    if any(ord(char) < 32 or ord(char) == 127 for char in value):
        return False
    return len(value.encode()) <= limit

def safe_lifecycle_path(value):
    if not bounded_data(value, 4096) or value.startswith("-"):
        return False
    if os.path.isabs(value):
        return os.path.normpath(value) == value
    return os.path.normpath(value) == value and value not in {"", "."} and not value.startswith("../") and "/../" not in value

verb = tokens[1]
if verb in {"--help", "-h", "status"}:
    accepted = len(tokens) == 2
else:
    if verb == "on":
        accepted = len(tokens) == 3 and bounded_data(tokens[2])
    elif verb == "off":
        accepted = len(tokens) == 3 and safe_lifecycle_path(tokens[2])
    elif verb == "wait":
        accepted = len(tokens) == 3 and safe_lifecycle_path(tokens[2])
    elif verb == "resume":
        accepted = len(tokens) == 3 and bool(re.fullmatch(r"[0-9a-f]{64}", tokens[2]))
    elif verb == "ledger-append":
        accepted = len(tokens) == 3 and bounded_data(tokens[2])
    elif verb == "manifest-write":
        accepted = (len(tokens) == 3 and safe_lifecycle_path(tokens[2]) and
                    os.path.basename(tokens[2]) == "eci-required-critics.json.source" and
                    ("TMPDIR" not in assignments or os.path.dirname(tokens[2]) == assignments["TMPDIR"]))
    elif verb == "approve-commit":
        # Coordinator-only admission for the exact one-time commit approval
        # route. Keep the peer classifier literal and bounded; eci-active
        # performs the authoritative repository and commit validation.
        repo = tokens[2] if len(tokens) == 4 else ""
        commit = tokens[3] if len(tokens) == 4 else ""
        accepted = (len(tokens) == 4 and safe_lifecycle_path(repo) and
                    os.path.isabs(repo) and lexical_bind_alias(repo) and
                    bounded_data(commit) and
                    re.fullmatch(r"git commit(?: [^\n\r;&|<>`$]+)?", commit) is not None)
    elif verb == "nested-enter":
        accepted = (len(tokens) in {4, 5} and
                    bool(re.fullmatch(r"[1-9][0-9]*", tokens[2])) and
                    bool(re.fullmatch(r"[1-9][0-9]*", tokens[3])) and
                    (len(tokens) == 4 or bool(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", tokens[4]))))
    elif verb in {"nested-accept", "nested-exit"}:
        accepted = len(tokens) == 2
    else:
        accepted = False
raise SystemExit(0 if accepted else 1)
PY
)"; then
    COORDINATOR_PEER_ECI_ROUTE_DETAIL=""
    return 0
  fi
  COORDINATOR_PEER_ECI_ROUTE_DETAIL="${detail:-lifecycle command does not match the bounded provider route}"
  return 1
}

coordinator_peer_eci_identity_detail() {
  case "$COORDINATOR_PEER_ECI_ROUTE_DETAIL" in
    "provider session identity mismatch: expected_name="*|\
      "provider session identity missing: expected_name="*|\
      "active session identity mismatch: expected="*)
      printf '%s\n' "$COORDINATOR_PEER_ECI_ROUTE_DETAIL"
      ;;
    *) return 1 ;;
  esac
}

# The canonical provider lifecycle route performs the complete manifest,
# executable-digest, provider-session, and bounded-argument validation.  For a
# coordinator callback, finish that decision here instead of paying for the
# unrelated legacy ownership scanners.  Workers deliberately remain on the
# ownership-denial path below.
if [ "${#syntax_eci_markers[@]}" -gt 0 ] &&
  [ "$hook_is_subagent" != true ] &&
  command_invokes_eci_lifecycle "$command"; then
  lifecycle_subject="$(eci_command_identity_subject "$command")"
  if coordinator_peer_eci_route "$command"; then
    validate_active_marker_binding
    exit 0
  fi
  lifecycle_identity_detail="$(coordinator_peer_eci_identity_detail 2>/dev/null || true)"
  if [ -n "$lifecycle_identity_detail" ]; then
    deny_eci "ECI_LIFECYCLE_IDENTITY_DENIED" "eci-lifecycle" \
      "ECI coordinator lifecycle identity denied: $lifecycle_identity_detail" \
      "use the provider-matched active session identity and canonical eci-active target"
  fi
  lifecycle_detail="${COORDINATOR_PEER_ECI_ROUTE_DETAIL:-lifecycle command does not match the bounded provider route}"
  deny_eci "ECI_LIFECYCLE_ARGUMENTS_DENIED" "eci-lifecycle" \
    "ECI coordinator lifecycle route denied malformed provider arguments: ${lifecycle_detail}; literal command=${lifecycle_subject} names a canonical Codex/Kimi eci-active control binary but does not match the validated provider route" \
    "use the provider-matched canonical eci-active binary with its exact verb, session assignment, and argument shape"
fi

COORDINATOR_TMPDIR_ROUTE_DETAIL=""
coordinator_tmpdir_manifest_route() {
  [ "$hook_is_subagent" != true ] || return 1
  case "$1" in
    TMPDIR=*) ;;
    *) return 1 ;;
  esac
  local detail
  if detail="$(python3 - "$1" <<'PY'
import hashlib
import os
import re
import shlex
import sys

def reject(message):
    print(message)
    raise SystemExit(1)

try:
    lexer = shlex.shlex(sys.argv[1], posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    shell_tokens = list(lexer)
except ValueError as exc:
    reject("literal tokenization failed: %s" % exc)
if any(token in {";", "&", "&&", "|", "||", "(", ")", ">", ">>", "<", "<<", "<<<", ">|", ">&", "<&"}
       for token in shell_tokens):
    reject("shell operators are not permitted in the TMPDIR lifecycle prefix")
try:
    tokens = shlex.split(sys.argv[1], posix=True)
except ValueError as exc:
    reject("literal tokenization failed: %s" % exc)
if len(tokens) != 4 or not tokens[0].startswith("TMPDIR="):
    reject("expected exactly: TMPDIR=<canonical non-system temporary root> <canonical eci-active> manifest-write <root>/eci-required-critics.json.source")
command = tokens[1]
home = os.environ.get("HOME", "")
tmpdir = tokens[0].split("=", 1)[1]
canonical_home = os.path.realpath(home) if home else ""
canonical_tmpdir = os.path.realpath(tmpdir) if os.path.isabs(tmpdir) else ""
home_scoped = bool(canonical_home and
                   (canonical_tmpdir == canonical_home or
                    canonical_tmpdir.startswith(canonical_home + os.sep)))
home_scoped = home_scoped or tmpdir == os.path.join(home, "tmp")
if (not home or not os.path.isabs(tmpdir) or os.path.normpath(tmpdir) != tmpdir or
        not os.path.isdir(tmpdir) or
        (canonical_tmpdir != tmpdir and not home_scoped) or
        tmpdir == "/tmp" or tmpdir.startswith("/tmp/")):
    reject("TMPDIR must be a canonical non-system temporary directory")
provider_root = None
for candidate_root in (os.path.join(home, ".codex"), os.path.join(home, ".kimi-code")):
    if command == os.path.join(candidate_root, "bin", "eci-active"):
        provider_root = candidate_root
        break
if provider_root is None:
    reject("eci-active executable must be the canonical Codex or Kimi coordinator path")
receipt = os.path.join(provider_root, ".eci-runtime-sync-manifest")
expected = None
try:
    receipt_stat = os.lstat(receipt)
    if (not os.path.isfile(receipt) or os.path.islink(receipt) or
            receipt_stat.st_uid != os.getuid() or receipt_stat.st_mode & 0o002):
        reject("provider runtime receipt is not a regular owner-only file")
    with open(receipt, "r", encoding="ascii") as stream:
        for line in stream:
            fields = line.rstrip("\n").split("\t")
            if len(fields) == 3 and fields[0] == "bin/eci-active":
                if expected is not None or not re.fullmatch(r"[0-9a-f]{64}", fields[1]):
                    reject("provider runtime receipt has an invalid eci-active digest entry")
                expected = fields[1]
except FileNotFoundError:
    expected = None
except (OSError, UnicodeError):
    reject("provider runtime receipt could not be read")
if (not os.path.isfile(command) or os.path.islink(command) or
        os.path.realpath(command) != command or not os.access(command, os.X_OK)):
    reject("eci-active executable is missing, symlinked, non-canonical, or not executable")
digest = hashlib.sha256()
with open(command, "rb") as stream:
    for chunk in iter(lambda: stream.read(131072), b""):
        digest.update(chunk)
if expected is not None and digest.hexdigest() != expected:
    reject("eci-active executable digest does not match the reviewed coordinator binary")
if tokens[2] != "manifest-write" or tokens[3] != os.path.join(tmpdir, "eci-required-critics.json.source"):
    reject("manifest-write must target the direct TMPDIR/eci-required-critics.json.source file")
print("accepted")
PY
)"; then
    COORDINATOR_TMPDIR_ROUTE_DETAIL=""
    return 0
  fi
  COORDINATOR_TMPDIR_ROUTE_DETAIL="coordinator TMPDIR manifest-write route rejected: ${detail:-route parser returned no diagnostic}; command=$(eci_command_identity_subject "$1")"
  return 1
}

COORDINATOR_MKTEMP_ROUTE_DETAIL=""
coordinator_mktemp_route() {
  [ "$hook_is_subagent" != true ] || return 1
  local detail
  detail="$(python3 - "$1" <<'PY'
import os
import re
import shlex
import shutil
import sys

command = sys.argv[1]
def reject(reason):
    print("coordinator-mktemp-route command=" + command + " reason=" + reason)
    raise SystemExit(1)

if any(mark in command for mark in ("\n", "\r", "$", "`", "'", '"')):
    reject("literal command must not contain quoting, substitution, or newlines")
try:
    tokens = shlex.split(command, posix=True)
except ValueError:
    reject("shell quoting is unbalanced")
if len(tokens) != 3 or tokens[0] != "mktemp" or tokens[1] != "-d":
    reject("expected exactly: mktemp -d $HOME/tmp/SAFE-PREFIX.XXXXXX")
if "/" in tokens[0] or any(token.startswith("-") for token in tokens[2:]):
    reject("path-qualified executable and extra options are not permitted")
template = tokens[2]
if not re.fullmatch(r"/(?:[A-Za-z0-9._-]+/)+[A-Za-z0-9][A-Za-z0-9._-]*\.XXXXXX", template):
    reject("template must be one literal absolute directory plus SAFE-PREFIX.XXXXXX")
parent, basename = template.rsplit("/", 1)
if basename.count("/") or ".." in basename or parent != os.path.normpath(parent):
    reject("template contains traversal or non-canonical path spelling")
resolved_mktemp = shutil.which("mktemp")
trusted_mktemp = {
    "/bin/mktemp", "/usr/bin/mktemp", "/usr/local/bin/mktemp",
    "/usr/lib/cargo/bin/coreutils/mktemp",
}
if not resolved_mktemp or os.path.realpath(resolved_mktemp) not in trusted_mktemp:
    reject("resolved mktemp executable is not trusted")
roots = []
home = os.environ.get("HOME", "")
canonical_home = os.path.realpath(home) if home else ""
home_tmp = os.path.join(home, "tmp") if home else ""
for raw in (os.environ.get("TMPDIR", ""), os.path.join(home, "tmp") if home else ""):
    if not raw or not os.path.isabs(raw) or os.path.normpath(raw) != raw:
        continue
    if not os.path.isdir(raw):
        continue
    resolved = os.path.realpath(raw)
    home_scoped = bool(canonical_home and
                       (resolved == canonical_home or
                        resolved.startswith(canonical_home + os.sep)))
    home_scoped = home_scoped or raw == home_tmp
    if (os.path.isdir(raw) and os.path.isdir(resolved) and
            (resolved == raw or home_scoped) and
            resolved != "/tmp" and not resolved.startswith("/tmp/")):
        roots.append((raw, resolved))
if not roots:
    reject("no configured canonical temporary directory is available")
if not any((parent == raw or os.path.realpath(parent) == resolved) for raw, resolved in roots):
    reject("template directory must be the canonical home-scoped temporary root or configured non-system TMPDIR")
print("ok")
PY
  )" && {
    COORDINATOR_MKTEMP_ROUTE_DETAIL=""
    return 0
  }
  COORDINATOR_MKTEMP_ROUTE_DETAIL="${detail:-coordinator-mktemp-route reason=command is outside the bounded temporary-directory grammar}"
  return 1
}

if [ "${#syntax_eci_markers[@]}" -gt 0 ] && [ "$hook_is_subagent" != true ] &&
  [[ "$command" == mktemp || "$command" == mktemp\ * ]] && ! coordinator_mktemp_route "$command"; then
  deny_eci "ECI_COORDINATOR_ROUTE_ARGUMENTS_DENIED" "coordinator-mktemp" \
    "ECI coordinator temporary-directory route denied malformed arguments: ${COORDINATOR_MKTEMP_ROUTE_DETAIL:-command=$(eci_command_identity_subject "$command")}; predicate=coordinator-mktemp; reason=active mktemp capability must use one canonical literal template" \
    "use exactly mktemp -d with one literal template under the home-scoped temporary root or configured non-system TMPDIR"
fi
if [ "${#syntax_eci_markers[@]}" -gt 0 ] && [ "$hook_is_subagent" = true ] &&
  [[ "$command" == mktemp || "$command" == mktemp\ * ]]; then
  deny_eci "ECI_WORKER_COORDINATOR_ROUTE_DENIED" "coordinator-route" \
    "ECI worker boundary denied coordinator-only temporary-directory setup: mktemp -d may be requested only by the main/orchestrator through the bounded literal route; rejected command=$(eci_command_identity_subject "$command"); reason=temporary-directory creation is coordinator-owned" \
    "route mktemp -d setup through the main/orchestrator using a literal home-scoped temporary-root or canonical non-system TMPDIR template"
fi

COORDINATOR_CLEANUP_ROUTE_DETAIL=""
coordinator_cleanup_route() {
  [ "$hook_is_subagent" != true ] || return 1
  local detail
  detail="$(python3 - "$1" <<'PY'
import os
import re
import shlex
import sys

command = sys.argv[1]
def reject(reason):
    print("coordinator-cleanup-route command=" + command + " reason=" + reason)
    raise SystemExit(1)

if any(mark in command for mark in ("\n", "\r", "$", "`", "'", '"')):
    reject("literal cleanup command contains quoting, substitution, or newlines")
try:
    tokens = shlex.split(command, posix=True)
except ValueError:
    reject("shell quoting is unbalanced")
temporary_unqualified_file_remove = False
if tokens and tokens[0] == "mv":
    if len(tokens) != 4 or tokens[1] != "--":
        reject("expected exactly mv -- <approved-artifact> <quarantine-destination>")
    mode = "mv"
    paths = tokens[2:]
elif len(tokens) >= 3 and tokens[0] == "rm" and tokens[1] == "-f":
    mode = "-f"
    if tokens[2] == "--":
        paths = tokens[3:]
    else:
        paths = tokens[2:]
        temporary_unqualified_file_remove = True
    if len(paths) > 64:
        reject("cleanup target list exceeds the 64-path bound")
    if len(paths) != len(set(paths)):
        reject("cleanup target list contains duplicate paths")
elif len(tokens) >= 4 and tokens[0] == "rm" and tokens[2] == "--":
    mode = tokens[1]
    if mode not in {"-f", "-rf"}:
        reject("rm option must be exactly -f for files or -rf for directories")
    paths = tokens[3:]
    if len(paths) > 64:
        reject("cleanup target list exceeds the 64-path bound")
    if len(paths) != len(set(paths)):
        reject("cleanup target list contains duplicate paths")
else:
    reject("expected rm -f -- <files>, rm -rf -- <directories>, or mv -- <artifact> <quarantine-destination>")
if not paths:
    reject("cleanup target list is empty")

if temporary_unqualified_file_remove:
    temporary_roots = set()
    home = os.environ.get("HOME", "")
    def canonical_directory(raw):
        if (not raw or not os.path.isabs(raw) or
                os.path.normpath(raw) != raw):
            return ""
        canonical = os.path.realpath(raw)
        if (not os.path.isabs(canonical) or
                os.path.normpath(canonical) != canonical or
                not os.path.isdir(canonical) or os.path.islink(canonical) or
                os.path.realpath(canonical) != canonical):
            return ""
        return canonical

    for raw in (
            os.environ.get("CODEX_TMPDIR", ""),
            os.environ.get("TMPDIR", ""),
            os.path.join(home, "tmp") if home else "",
    ):
        canonical = canonical_directory(raw)
        if canonical and canonical != "/tmp" and not canonical.startswith("/tmp/"):
            temporary_roots.add(canonical)
    if not temporary_roots:
        reject("no canonical temporary directory is available")
    for path in paths:
        if not os.path.isabs(path) or os.path.normpath(path) != path:
            reject("path=" + path + " reason=temporary cleanup requires canonical absolute paths")
        parent = os.path.dirname(path)
        canonical_parent = os.path.realpath(parent)
        if canonical_parent not in temporary_roots:
            reject("path=" + path + " reason=unqualified rm -f is limited to canonical temporary roots")
        if os.path.islink(path):
            reject("path=" + path + " reason=symlink targets are not cleanup-eligible")
        if os.path.lexists(path) and (not os.path.isfile(path) or os.path.realpath(path) != path):
            reject("path=" + path + " reason=temporary cleanup requires a canonical regular file")
        ancestor = parent
        while not os.path.lexists(ancestor) and ancestor != os.path.dirname(ancestor):
            ancestor = os.path.dirname(ancestor)
        canonical_ancestor = os.path.realpath(ancestor)
        if not any(canonical_ancestor == root or canonical_ancestor.startswith(root + os.sep)
                   for root in temporary_roots):
            reject("path=" + path + " reason=temporary cleanup parent escapes canonical temporary roots")
    print("ok")
    raise SystemExit(0)

home = os.environ.get("HOME", "")
homes = []
for value, fallback in (
    (os.environ.get("CODEX_HOME", ""), os.path.join(home, ".codex")),
    (os.environ.get("KIMI_CODE_HOME", ""), os.path.join(home, ".kimi-code")),
):
    root = value or fallback
    if not root or not os.path.isabs(root) or os.path.normpath(root) != root:
        continue
    if not os.path.isdir(root) or os.path.islink(root):
        continue
    canonical_root = os.path.realpath(root)
    if (not os.path.isabs(canonical_root) or
            os.path.normpath(canonical_root) != canonical_root or
            not os.path.isdir(canonical_root) or os.path.islink(canonical_root) or
            os.path.realpath(canonical_root) != canonical_root):
        continue
    # A provider home may be spelled through the user's home-scoped temporary
    # alias (for example $HOME/tmp/... during a bounded fixture).  Accept that
    # spelling only when the alias is exactly a direct child of HOME; arbitrary
    # symlinked provider roots remain rejected.
    if canonical_root != root:
        canonical_home = os.path.realpath(home) if home else ""
        if (not home or not os.path.isabs(home) or os.path.normpath(home) != home or
                not os.path.isdir(home) or os.path.islink(home) or
                not canonical_home or os.path.realpath(canonical_home) != canonical_home or
                os.path.dirname(root) != home or
                os.path.realpath(os.path.dirname(root)) != canonical_home):
            continue
    homes.append((root, canonical_root))
if not homes:
    reject("no canonical Codex or Kimi home is available")

root_files = {"config-new.toml", "migrations-effort.json"}
root_dirs = {"cron", "search-index", "workspace-trust", "bin/__pycache__", "bin/tests/__pycache__", "hooks/tests/__pycache__"}
runner_file = re.compile(r"^\.codex-runner-test\.[A-Za-z0-9._-]+$")
def approved_path(path):
    if not os.path.isabs(path) or os.path.normpath(path) != path:
        return None, "target path must be canonical absolute"
    for root, canonical_root in homes:
        if path == root or path.startswith(root + os.sep):
            canonical_path = os.path.realpath(path)
            if (canonical_path != canonical_root and
                    not canonical_path.startswith(canonical_root + os.sep)):
                return root, "resolved target escapes canonical provider home"
            relative = os.path.relpath(canonical_path, canonical_root)
            if relative in root_files or relative == "bin/codex-pending-couriers":
                return root, "file"
            if relative in root_dirs:
                return root, "directory"
            if os.path.dirname(relative) in ("", ".") and runner_file.fullmatch(os.path.basename(relative)):
                if os.path.isdir(path):
                    return root, "directory"
                if os.path.isfile(path):
                    return root, "file"
                return root, "unapproved generated path"
            return root, "unapproved generated path"
    return None, "target is outside canonical Codex/Kimi homes"

if mode == "mv":
    source, destination = paths
    root, kind = approved_path(source)
    if root is None:
        reject("path=" + source + " reason=" + kind)
    if kind == "unapproved generated path":
        reject("path=" + source + " reason=path is not an approved generated artifact")
    if os.path.islink(source):
        reject("path=" + source + " reason=symlink targets are not cleanup-eligible")
    if (kind == "file" and (not os.path.isfile(source) or os.path.islink(source))) or (kind == "directory" and (not os.path.isdir(source) or os.path.islink(source))):
        reject("path=" + source + " reason=approved artifact is missing or not canonical")
    home = os.environ.get("HOME", "")
    configured_tmpdir = os.environ.get("TMPDIR") or (os.path.join(home, "tmp") if home else "")
    if not os.path.isabs(configured_tmpdir) or os.path.normpath(configured_tmpdir) != configured_tmpdir:
        reject("configured TMPDIR must be an absolute normalized path")
    real_tmpdir = os.path.realpath(configured_tmpdir)
    if not os.path.isabs(real_tmpdir) or os.path.normpath(real_tmpdir) != real_tmpdir or not os.path.isdir(real_tmpdir) or os.path.islink(real_tmpdir) or os.path.realpath(real_tmpdir) != real_tmpdir:
        reject("configured TMPDIR does not resolve to a canonical directory")
    temporary_roots = {real_tmpdir}
    temporary_roots = {
        root for root in temporary_roots
        if root != "/tmp" and not root.startswith("/tmp/")
    }
    destination_parent = os.path.dirname(destination)
    allowed_temp_roots = ",".join(sorted(temporary_roots))
    destination_parent_real = os.path.realpath(destination_parent)
    if (not os.path.isabs(destination) or os.path.normpath(destination) != destination or
            os.path.islink(destination_parent) or destination_parent_real not in temporary_roots):
        reject("destination must be a direct child of the canonical non-system temporary root; configured_tmpdir=" + configured_tmpdir + "; real_tmpdir=" + real_tmpdir + "; destination_parent=" + destination_parent + "; allowed_temp_roots=" + allowed_temp_roots)
    if not re.fullmatch(r"eci-generated-cleanup-[A-Za-z0-9._-]+", os.path.basename(destination)):
        reject("destination basename must match eci-generated-cleanup-<literal-safe-name>")
    if os.path.lexists(destination):
        reject("destination must not already exist")
else:
  for path in paths:
    root, kind = approved_path(path)
    if root is None:
        reject("path=" + path + " reason=" + kind)
    if kind == "unapproved generated path":
        reject("path=" + path + " reason=path is not an approved generated artifact")
    if os.path.islink(path):
        reject("path=" + path + " reason=symlink targets are not cleanup-eligible")
    if mode == "-f":
        if kind != "file":
            reject("path=" + path + " reason=-f requires an approved regular file")
        if not os.path.isfile(path) or os.path.islink(path):
            reject("path=" + path + " reason=approved file is missing or not a canonical regular file")
    else:
        if kind != "directory":
            reject("path=" + path + " reason=-rf requires an approved generated directory")
        if not os.path.isdir(path) or os.path.islink(path):
            reject("path=" + path + " reason=approved directory is missing or not canonical")
print("ok")
PY
  )" && {
    COORDINATOR_CLEANUP_ROUTE_DETAIL=""
    return 0
  }
  COORDINATOR_CLEANUP_ROUTE_DETAIL="${detail:-coordinator-cleanup-route reason=command is outside the bounded cleanup grammar}"
  return 1
}

# Cleanup is a coordinator-owned route with a complete bounded parser of its
# own.  Once the compiled planner has admitted the direct command, do not send
# it through the unrelated legacy ownership scanners: those scanners add
# several Python/jq/stat processes and cannot grant any additional cleanup
# capability.  Validate marker ownership first so malformed, unsafe, or
# ambiguous ECI state still fails closed with its existing diagnostic.
if [ "${#syntax_eci_markers[@]}" -gt 0 ] &&
  [ "$hook_is_subagent" != true ] &&
  { [ "$command" = rm ] || [ "$command" = mv ] ||
    [[ "$command" == rm\ * || "$command" == mv\ * ]]; }; then
  validate_active_marker_binding
  if coordinator_cleanup_route "$command"; then
    exit 0
  fi
  deny_eci "ECI_COMMAND_NOT_ALLOWLISTED" "coordinator-cleanup-route" \
    "ECI coordinator cleanup route denied the reported command: ${COORDINATOR_CLEANUP_ROUTE_DETAIL:-command=$(eci_command_identity_subject "$command")}" \
    "correct the reported cleanup token/path/shape and use only the bounded generated-artifact cleanup route"
fi

coordinator_hook_mode_repair_route() {
  [ "$hook_is_subagent" != true ] || return 1
  python3 - "$1" "$cwd" <<'PY'
import os
import shlex
import sys

command, hook_cwd = sys.argv[1], sys.argv[2]
try:
    tokens = shlex.split(command, posix=True)
except ValueError:
    raise SystemExit(1)
if len(tokens) < 3 or tokens[0] != "chmod" or tokens[1] != "755":
    raise SystemExit(1)
if any(any(mark in token for mark in ("$", chr(96), "..")) for token in tokens):
    raise SystemExit(1)
approved = set()
home = os.environ.get("HOME", "")
for root in (
    os.environ.get("CODEX_HOME") or os.path.join(home, ".codex"),
    os.environ.get("KIMI_CODE_HOME") or os.path.join(home, ".kimi-code"),
):
    if not root or not os.path.isabs(root) or os.path.islink(root):
        continue
    root = os.path.realpath(root)
    if not os.path.isdir(root):
        continue
    approved.update({
        os.path.join(root, "hooks", "validate-bash.sh"),
        os.path.join(root, "hooks", "pre-commit-go-mod.sh"),
        os.path.join(root, "hooks", "install-pre-commit-go-mod.sh"),
        os.path.join(root, "hooks", "tests", "test-pre-commit-go-mod.sh"),
    })
targets = []
for token in tokens[2:]:
    candidate = token if os.path.isabs(token) else os.path.abspath(os.path.join(hook_cwd, token))
    if os.path.normpath(candidate) != candidate or candidate not in approved:
        raise SystemExit(1)
    if not os.path.isfile(candidate) or os.path.islink(candidate) or os.path.realpath(candidate) != candidate:
        raise SystemExit(1)
    targets.append(candidate)
raise SystemExit(0 if targets else 1)
PY
}

# The shared Go hook installer mutates provider-owned Git hook state. Its
# canonical identity remains protected when its arguments are malformed.
if [ "${#syntax_eci_markers[@]}" -gt 0 ] && [ "$hook_is_subagent" != true ]; then
  go_hook_installer_identity="$(coordinator_go_hook_installer_identity "$command" 2>/dev/null || true)"
  if [ -n "$go_hook_installer_identity" ] && ! coordinator_script_route "$command"; then
    deny_eci "ECI_COORDINATOR_ROUTE_ARGUMENTS_DENIED" "coordinator-go-hook-installer" \
      "ECI coordinator Go hook installer route denied malformed arguments: ${go_hook_installer_identity}; ${COORDINATOR_SCRIPT_ROUTE_DETAIL}" \
      "invoke the canonical installer without arguments, or use --repair-hardlink with the other canonical Codex/Kimi repository root"
  fi
fi

# Shell metacharacters are ordinary main-thread Bash syntax when no ECI
# session is bound to this callback.  Keep the literal-vector rule at the
# active ECI acceptance boundary only; the Git/ECI mutation gates below still
# inspect acceptance-sensitive commands independently.
if [ "${#syntax_eci_markers[@]}" -gt 0 ] && command_has_unsafe_shell_syntax "$command"; then
  if ! worker_project_inspection_route "$command" &&
     ! coordinator_compound_inspection_route "$command" &&
     ! coordinator_inspection_route "$command" && ! coordinator_script_route "$command" &&
     ! coordinator_go_test_capture_route "$command" &&
     ! coordinator_go_vet_capture_route "$command" &&
     ! eci_static_pipeline_segments "$command" >/dev/null; then
    unsafe_detail="$(unsafe_shell_syntax_detail "$command")"
    identity="$(eci_command_identity_subject "$command")"
    deny_eci "ECI_COMMAND_SYNTAX_DENIED" "acceptance-boundary" "ECI acceptance boundary denied ${unsafe_detail}; rejected command=${identity} must remain a literal vector." "remove ${unsafe_detail} from rejected command=${identity} and submit one literal command for review"
  fi
fi

# Reject the ordinary direct-commit form before any classifier or repository
# probing.  This is a narrow, literal fast path: alternate repository/global
# options remain on the full parser, while a validated active marker is reused
# for the admission decision.
fast_commit_markers=()
case "$command" in
  git[[:space:]]commit|git[[:space:]]commit[[:space:]]*)
    if [ "$hook_is_subagent" != true ]; then
      case "$command" in
        *\ --git-dir*|*\ --work-tree*|*\ --exec-path*|*\ --config-env*|*\ --namespace*|*\ -C\ *|*\ -c\ *)
          ;;
        *)
          fast_commit_markers=()
          fast_commit_markers=("${syntax_eci_markers[@]}")
          for fast_commit_marker in "${fast_commit_markers[@]}"; do
            codex_eci_marker_path_owner_is_valid "$fast_commit_marker" ||
              deny_marker_boundary "$fast_commit_marker" "$(codex_canonical_cwd "$cwd")" "$session_id"
          done
          [ "${#fast_commit_markers[@]}" -le 1 ] ||
            deny_eci "ECI_MARKER_OWNERSHIP_AMBIGUOUS" "commit-boundary" "ECI commit boundary denied: multiple active markers are unsafe; resolve ownership before committing." "resolve marker ownership so exactly one validated owner remains, then retry the commit"
          fast_commit_receipt=""
          if [ "${#fast_commit_markers[@]}" -eq 1 ]; then
            fast_commit_receipt="${fast_commit_markers[0]%/*}/eci-commit-admitted"
          fi
          if [ "${#fast_commit_markers[@]}" -eq 1 ] &&
             [ ! -f "$cwd/.git-commit-approved-once" ] &&
             [ ! -f "$fast_commit_receipt" ]; then
            deny_eci "ECI_COMMIT_ADMISSION_REQUIRED" "commit-boundary" "ECI commit boundary denied: coordinator acceptance requires the eci-required-critics manifest and critic evidence before this commit; manifest=${fast_commit_markers[0]%/*}/eci-required-critics.json" "complete coordinator ECI review admission and publish the required manifest/evidence before committing"
          fi
          ;;
      esac
    fi
    ;;
esac

read_only=false
coordinator_inspection_allowed=false
worker_read_only_pipeline_admitted=false
if [ "${#syntax_eci_markers[@]}" -gt 0 ]; then
  if coordinator_readlink_route "$command" || coordinator_compound_inspection_route "$command" || coordinator_inspection_route "$command"; then
    read_only=true
    coordinator_inspection_allowed=true
  elif [ "$(classify_eci_command "$command" 2>/dev/null || true)" = read-only ]; then
    read_only=true
  fi
elif command_is_read_only "$command"; then
  read_only=true
fi

# Read-only classification must not hide a provider-control identity.  Valid
# canonical Codex/Kimi lifecycle calls are admitted by the peer route; a
# malformed, altered, or unbound eci-active path is denied before the generic
# read-only fast return can bypass its ownership diagnostic.
if [ "$hook_is_subagent" != true ] && [ "${#syntax_eci_markers[@]}" -gt 0 ] &&
  command_invokes_eci_binary "$command" && ! coordinator_peer_eci_route "$command"; then
  lifecycle_subject="$(eci_command_identity_subject "$command")"
  lifecycle_detail="$(rejected_command_detail "$command" 2>/dev/null || printf 'segment=<unclassified>')"
  if [ -n "$COORDINATOR_PEER_ECI_ROUTE_DETAIL" ]; then
    lifecycle_detail="$COORDINATOR_PEER_ECI_ROUTE_DETAIL; $lifecycle_detail"
  fi
  lifecycle_identity_detail="$(coordinator_peer_eci_identity_detail 2>/dev/null || true)"
  if [ -n "$lifecycle_identity_detail" ]; then
    deny_eci "ECI_LIFECYCLE_IDENTITY_DENIED" "eci-lifecycle" \
      "ECI coordinator lifecycle identity denied: $lifecycle_identity_detail" \
      "use env with the provider-matched active session identity and canonical eci-active target"
  fi
  deny_eci "ECI_LIFECYCLE_ARGUMENTS_DENIED" "eci-lifecycle" \
    "ECI coordinator lifecycle route denied malformed, altered, or unbound provider arguments: ${lifecycle_detail}; literal command=${lifecycle_subject} names a canonical Codex/Kimi eci-active control binary but does not match the validated provider route" \
    "use the provider-matched canonical eci-active binary with its exact argument shape and session assignment; route lifecycle calls through the coordinator entrypoint"
fi

# Review-gate ownership is resolved before ordinary literal admission.  A
# worker never owns this acceptance capability; a coordinator may use only
# the exact supported phase/session shape.  Recognized malformed invocations
# cannot fall through as ordinary scripts.
review_gate_identity=""
if [ "${#syntax_eci_markers[@]}" -gt 0 ]; then
  review_gate_identity="$(review_gate_command_identity "$command" 2>/dev/null || true)"
fi
if [ -n "$review_gate_identity" ]; then
  if [ "$hook_is_subagent" = true ]; then
    deny_eci "ECI_WORKER_REVIEW_GATE_DENIED" "worker-review-gate" \
      "ECI worker boundary denied coordinator-owned review-gate invocation: ${review_gate_identity}; segment=1; argv_index=0; byte_offset=0; token=eci-review-gate.sh; path=n/a; predicate=worker-lifecycle-control; reason=the canonical review gate owns acceptance evidence and cannot be invoked by a worker" \
      "route this exact review-gate phase/session invocation through the main/orchestrator coordinator"
  elif [[ "$review_gate_identity" != *" valid_shape=true "* ]]; then
    deny_eci "ECI_REVIEW_GATE_ARGUMENTS_DENIED" "review-gate" \
      "ECI coordinator review-gate route denied malformed arguments: ${review_gate_identity}; segment=1; argv_index=0; byte_offset=0; token=eci-review-gate.sh; path=n/a; predicate=review-gate-arguments; reason=the recognized canonical review gate requires exactly one supported phase and one bounded session id" \
      "correct the reported malformed_token and invoke the canonical review gate with <commit|final|off|prewrite> <session-id>"
  fi
fi

if [ "$hook_is_subagent" = true ] && [ -n "$worker_protected_control_identity" ]; then
  deny_eci "ECI_WORKER_CONTROL_SCRIPT_DENIED" "worker-control-script" \
    "ECI worker boundary denied coordinator-owned lifecycle/control script: ${worker_protected_control_identity}; reason=the canonical control script owns ECI admission or stop state" \
    "route this exact canonical control-script invocation through the main/orchestrator coordinator"
fi

if [ "$hook_is_subagent" = true ] && command_invokes_eci_control_mutation "$command"; then
  deny_eci "ECI_CONTROL_OWNER_REQUIRED" "worker-control" \
    "ECI worker boundary denied a recognizable mutation of coordinator-owned ECI control, proof, ledger, teardown, or acceptance state; rejected command=$(eci_command_identity_subject "$command")" \
    "route this exact lifecycle, proof-state, or acceptance-state mutation through the main/orchestrator coordinator; workers may not mutate ECI control files"
fi

if [ "${#syntax_eci_markers[@]}" -gt 0 ] && [ "$ECI_ENVIRONMENT_BOUNDARY_CHECKED" != true ]; then
  enforce_environment_command_boundary
fi

# Spawned workers receive one direct literal argv per callback.  Compound
# operators are not a second command envelope and must identify the exact
# token instead of falling into an executable-name diagnostic.  Coordinators
# retain their separately bounded inspection/verification batches.
if [ "${#syntax_eci_markers[@]}" -gt 0 ]; then
  if [ "$worker_read_only_pipeline_candidate" != true ] && deny_worker_nonliteral; then
    :
  fi
fi

if [ "${#syntax_eci_markers[@]}" -gt 0 ]; then
  dynamic_detail="$(dynamic_indirection_detail "$command" 2>/dev/null || true)"
  if [ -n "$dynamic_detail" ] &&
    ! { [ "$hook_is_subagent" != true ] && coordinator_peer_eci_route "$command"; }; then
    deny_eci "ECI_COMMAND_DYNAMIC_INDIRECTION_DENIED" "direct-argv" \
      "ECI command envelope denied dynamic indirection: ${dynamic_detail}; reason=the reported inline, stdin, source, split-string, or execution-context token hides or changes executable payload identity; rejected command=$(eci_command_identity_subject "$command")" \
      "remove the reported token and invoke a finite literal script, module, or executable argv directly"
  fi
fi

git_branch_remote_detail=""
if [ "${#syntax_eci_markers[@]}" -gt 0 ]; then
  git_branch_remote_detail="$(command_invokes_git_branch_remote_mutation "$command" 2>/dev/null || true)"
fi
if [ -n "$git_branch_remote_detail" ]; then
  if [ "$hook_is_subagent" = true ]; then
    deny_eci "ECI_WORKER_GIT_OWNERSHIP_DENIED" "worker-git-ownership" \
      "ECI worker boundary denied recognizable Git branch/remote mutation: ${git_branch_remote_detail}; predicate=worker-git-ownership; rejected command=$(eci_command_identity_subject "$command")" \
      "route this exact Git ref or remote mutation through the main/orchestrator coordinator acceptance route"
  fi
  deny_eci "ECI_GIT_BRANCH_REMOTE_DENIED" "git-branch-remote" \
    "ECI coordinator gate denied recognizable Git branch/remote mutation outside a supported acceptance route: ${git_branch_remote_detail}; rejected command=$(eci_command_identity_subject "$command")" \
    "use the bounded coordinator acceptance route for this exact Git ref or remote operation"
fi

if [ "${#syntax_eci_markers[@]}" -gt 0 ]; then
  git_dynamic_detail="$(git_dynamic_execution_detail "$command" 2>/dev/null || true)"
  if [ -n "$git_dynamic_detail" ]; then
    deny_eci "ECI_GIT_EXECUTION_CONTEXT_DENIED" "git-execution-context" \
      "ECI gate denied recognizable Git helper or execution-context activation: ${git_dynamic_detail}; rejected command=$(eci_command_identity_subject "$command")" \
      "remove the reported Git option or environment token and use the bounded coordinator Git route"
  fi
fi

# A typed, literal read-only command never mutates ECI or repository state.
# Resolve the bounded marker set once so malformed/duplicate active markers
# still fail closed, enforce the worker Git boundary, then return before Git
# mutation parsing, activity bookkeeping, or other non-hot-path work. This
# keeps every ordinary inspection callback local and sub-second by design.
if ! eci_cleanup_command_shape "$command" && [ "$read_only" = true ] && {
  if [ "$hook_is_subagent" = true ]; then
    [ "$WORKER_PROJECT_INSPECTION_ALLOWED" = true ]
  else
    [ "$coordinator_inspection_allowed" = true ] || read_only_fast_safe "$command"
  fi
}; then
  # Read-only-looking utilities can still write through redirection or an
  # alias to proof state. Apply the worker control-file boundary before the
  # early return, just as the full path does below.
  if [ "$hook_is_subagent" = true ] && [ "${#syntax_eci_markers[@]}" -gt 0 ] &&
    command_invokes_eci_control_mutation "$command"; then
    deny_eci "ECI_CONTROL_OWNER_REQUIRED" "eci-control" "Only the main/orchestrator may mutate ECI control files. The worker command targets coordinator-owned proof state: command=$(eci_command_identity_subject "$command")." "route lifecycle and proof-state changes through the main/orchestrator"
  fi
  mapfile -t read_only_markers < <(active_eci_markers_for_cwd "$cwd" "$session_id")
  for read_only_marker in "${read_only_markers[@]}"; do
    if ! codex_eci_marker_path_owner_is_valid "$read_only_marker"; then
      deny_marker_boundary "$read_only_marker" "$(codex_canonical_cwd "$cwd")" "$session_id"
    fi
  done
  [ "${#read_only_markers[@]}" -le 1 ] ||
    deny_eci "ECI_MARKER_OWNERSHIP_AMBIGUOUS" "commit-boundary" "ECI commit boundary denied: multiple active markers are unsafe; resolve ownership before committing." "resolve marker ownership so exactly one validated owner remains, then retry the commit"
  exit 0
fi

proof_path_escape_detail() {
  python3 - "$1" "$cwd" "$CODEX_PROOF_ROOT_CONFIGURED" "$CODEX_PROOF_ROOT_CANONICAL" "$CODEX_PROOF_ROOT_STABLE_ALIAS" <<'PY'
import os
import shlex
import sys

command, hook_cwd, configured, canonical, stable = sys.argv[1:]
if not canonical or not os.path.isabs(canonical):
    raise SystemExit(1)
canonical = os.path.realpath(canonical)
lexical_roots = []
for value in (configured, canonical, stable):
    if not value or not os.path.isabs(value):
        continue
    value = os.path.normpath(value)
    if os.path.realpath(value) == canonical:
        lexical_roots.append(value)
try:
    tokens = shlex.split(command, posix=True)
except ValueError:
    raise SystemExit(1)
for token in tokens[1:]:
    if not token or token.startswith("-") or any(char in token for char in ("\n", "\r", "\0")):
        continue
    candidate = token if os.path.isabs(token) else os.path.abspath(os.path.join(hook_cwd, token))
    candidate = os.path.normpath(candidate)
    for lexical_root in lexical_roots:
        if candidate != lexical_root and not candidate.startswith(lexical_root + os.sep):
            continue
        resolved = os.path.realpath(candidate)
        if resolved != canonical and not resolved.startswith(canonical + os.sep):
            print(
                "path=%s resolved=%s proof_root=%s reason=lexical proof path escapes through a symlink"
                % (token, resolved, canonical)
            )
            raise SystemExit(0)
raise SystemExit(1)
PY
}

coordinator_static_pipeline_route() {
  [ "$hook_is_subagent" != true ] || return 1
  local segments segment detail review_detail control_detail git_detail protected_detail
  segments="$(eci_static_pipeline_segments "$1" 2>/dev/null)" || return 1
  [ -n "$segments" ] || return 1
  while IFS= read -r segment; do
    [ -n "$segment" ] || return 1
    eci_finite_literal_argv "$segment" || return 1
    detail="$(dynamic_indirection_detail "$segment" 2>/dev/null || true)"
    if [ -n "$detail" ]; then
      deny_eci "ECI_COMMAND_DYNAMIC_INDIRECTION_DENIED" "coordinator-static-pipeline" \
        "ECI coordinator static pipeline denied dynamic indirection in segment=$(eci_command_identity_subject "$segment"): ${detail}; reason=the reported token hides or changes executable payload identity" \
        "remove the reported token or split the pipeline into finite direct literal argv calls"
    fi
    detail="$(proof_path_escape_detail "$segment" 2>/dev/null || true)"
    if [ -n "$detail" ]; then
      deny_eci "ECI_PROOF_PATH_ESCAPE_DENIED" "proof-path-ownership" \
        "ECI proof-path boundary denied symlink escape in pipeline segment=$(eci_command_identity_subject "$segment"): ${detail}" \
        "use the resolved outside path directly, or replace the symlink with a regular in-root evidence file"
    fi
    review_detail="$(review_gate_command_identity "$segment" 2>/dev/null || true)"
    control_detail="$(protected_control_script_identity "$segment" 2>/dev/null || true)"
    if [ -n "$review_detail" ] || [ -n "$control_detail" ] ||
       command_invokes_eci_binary "$segment" || command_invokes_eci_control_mutation "$segment"; then
      deny_eci "ECI_COORDINATOR_CONTROL_PIPELINE_DENIED" "coordinator-static-pipeline" \
        "ECI coordinator static pipeline denied coordinator-owned lifecycle/control segment=$(eci_command_identity_subject "$segment"); review_gate=${review_detail:-none}; control_script=${control_detail:-none}; reason=control and acceptance operations require their direct coordinator route" \
        "invoke the reported lifecycle/control operation through its direct coordinator entrypoint, outside a pipeline"
    fi
    git_detail="$(command_invokes_git_branch_remote_mutation "$segment" 2>/dev/null || true)"
    if [ -n "$git_detail" ]; then
      deny_eci "ECI_GIT_BRANCH_REMOTE_DENIED" "coordinator-static-pipeline" \
        "ECI coordinator static pipeline denied recognizable Git branch/remote mutation in segment=$(eci_command_identity_subject "$segment"): ${git_detail}" \
        "use the bounded coordinator acceptance route for the reported Git ref or remote operation"
    fi
    git_detail="$(git_dynamic_execution_detail "$segment" 2>/dev/null || true)"
    if [ -n "$git_detail" ]; then
      deny_eci "ECI_GIT_EXECUTION_CONTEXT_DENIED" "coordinator-static-pipeline" \
        "ECI coordinator static pipeline denied Git execution-context activation in segment=$(eci_command_identity_subject "$segment"): ${git_detail}" \
        "remove the reported Git option or environment token and use the bounded coordinator Git route"
    fi
    git_detail="$(protected_pipeline_git_detail "$segment" 2>/dev/null || true)"
    if [ -n "$git_detail" ]; then
      deny_eci "ECI_GIT_MUTATION_DENIED" "coordinator-static-pipeline" \
        "ECI coordinator static pipeline denied acceptance-sensitive Git segment=$(eci_command_identity_subject "$segment"): ${git_detail}" \
        "invoke the reported Git mutation directly through the coordinator acceptance route"
    fi
    protected_detail="$(protected_literal_operation_detail "$segment" false 2>/dev/null || true)"
    case "$protected_detail" in
      class=broad\ *)
        deny_eci "ECI_BROAD_DESTRUCTIVE_DENIED" "coordinator-static-pipeline" \
          "ECI coordinator static pipeline denied broad destructive segment=$(eci_command_identity_subject "$segment"): ${protected_detail}" \
          "narrow the target and invoke the operation as a separately reviewed direct argv"
        ;;
      class=source\ *)
        deny_eci "ECI_COORDINATOR_SOURCE_WRITE_DENIED" "coordinator-static-pipeline" \
          "ECI coordinator static pipeline denied source-tree write segment=$(eci_command_identity_subject "$segment"): ${protected_detail}; predicate=coordinator-source-write" \
          "delegate the source write to the implementer and keep coordinator inspection pipelines non-mutating"
        ;;
    esac
    case "$segment" in
      rm|rm\ *|mv|mv\ *)
        deny_eci "ECI_COORDINATOR_CLEANUP_PIPELINE_DENIED" "coordinator-static-pipeline" \
          "ECI coordinator static pipeline denied cleanup segment=$(eci_command_identity_subject "$segment"); reason=cleanup ownership cannot be composed with an inspection pipeline" \
          "invoke the bounded cleanup route as one direct argv outside a pipeline"
        ;;
    esac
  done <<< "$segments"
  return 0
}

if [ "${#syntax_eci_markers[@]}" -gt 0 ]; then
  proof_escape_detail="$(proof_path_escape_detail "$command" 2>/dev/null || true)"
  if [ -n "$proof_escape_detail" ]; then
    deny_eci "ECI_PROOF_PATH_ESCAPE_DENIED" "proof-path-ownership" \
      "ECI proof-path boundary denied symlink escape: ${proof_escape_detail}" \
      "use the resolved outside path directly for ordinary inspection, or replace the symlink with a regular in-root evidence file"
  fi
fi

if [ "${#syntax_eci_markers[@]}" -gt 0 ] && [ "$hook_is_subagent" != true ]; then
  case "$command" in
    mv|mv\ *|rm|rm\ *)
      if ! coordinator_cleanup_route "$command"; then
        deny_eci "ECI_COMMAND_NOT_ALLOWLISTED" "coordinator-cleanup-route" \
          "ECI coordinator cleanup route denied the reported command: ${COORDINATOR_CLEANUP_ROUTE_DETAIL}; rejected command=$(eci_command_identity_subject "$command")" \
          "correct the reported cleanup token/path/shape and use only the bounded generated-artifact cleanup route"
      fi
      ;;
  esac
fi

if [ "${#syntax_eci_markers[@]}" -gt 0 ]; then
  protected_literal_detail="$(protected_literal_operation_detail "$command" "$hook_is_subagent" 2>/dev/null || true)"
  case "$protected_literal_detail" in
    class=broad\ *)
      deny_eci "ECI_BROAD_DESTRUCTIVE_DENIED" "broad-destructive" \
        "ECI ownership gate denied a broad destructive operation: ${protected_literal_detail}; reason=the resolved target is a filesystem, home, repository, provider, proof, or current working root" \
        "narrow the reported target to the exact task-owned file or subdirectory and retry as one finite literal argv"
      ;;
    class=worker-git\ *)
      deny_eci "ECI_WORKER_GIT_OWNERSHIP_DENIED" "worker-git-ownership" \
        "ECI worker ownership gate denied an acceptance-sensitive Git operation: ${protected_literal_detail}; predicate=worker-git-ownership; reason=the reported Git verb changes or controls repository acceptance/history and is coordinator-owned while ECI is active" \
        "route the reported Git verb through the main/orchestrator coordinator; workers may use finite read-only Git inspection and history commands"
      ;;
    class=source\ *)
      source_write_exempt=false
      case "$command" in
        mv|mv\ *|rm|rm\ *)
          if coordinator_cleanup_route "$command"; then
            source_write_exempt=true
          elif [ -n "$COORDINATOR_CLEANUP_ROUTE_DETAIL" ]; then
            deny_eci "ECI_COMMAND_NOT_ALLOWLISTED" "coordinator-cleanup-route" \
              "ECI coordinator cleanup route denied the reported command: ${COORDINATOR_CLEANUP_ROUTE_DETAIL}; rejected command=$(eci_command_identity_subject "$command")" \
              "correct the reported cleanup token/path/shape and use only the bounded generated-artifact cleanup route"
          fi
          ;;
        chmod|chmod\ *) ;;
      esac
      if [ "$source_write_exempt" != true ]; then
        deny_eci "ECI_COORDINATOR_SOURCE_WRITE_DENIED" "coordinator-source-write" \
          "ECI ownership gate denied a coordinator source-tree write: ${protected_literal_detail}; predicate=coordinator-source-write; reason=the resolved target is inside the project/provider source boundary and production writes belong to the implementer worker" \
          "delegate the reported source write to the ECI implementer; use a bounded coordinator lifecycle/proof route only for coordinator-owned artifacts"
      fi
      ;;
  esac
  if [ "$hook_is_subagent" != true ]; then
    case "$command" in
      mktemp|mktemp\ *)
        if ! coordinator_mktemp_route "$command"; then
          deny_eci "ECI_COORDINATOR_ROUTE_ARGUMENTS_DENIED" "coordinator-mktemp" \
            "ECI coordinator temporary-directory route denied malformed arguments: ${COORDINATOR_MKTEMP_ROUTE_DETAIL:-command=$(eci_command_identity_subject "$command")}; reason=the protected coordinator route accepts exactly one bounded mktemp -d template" \
            "use exactly mktemp -d with one literal template under the home-scoped temporary root or configured non-system TMPDIR"
        fi
        ;;
    esac
  fi
fi

PLAN_PEER_ECI_ROUTE=false
if [ "${#syntax_eci_markers[@]}" -gt 0 ] && [ "$plan_status" -eq 3 ] &&
  [ "$hook_is_subagent" != true ]; then
  if coordinator_peer_eci_route "$command"; then
    PLAN_PEER_ECI_ROUTE=true
  else
    lifecycle_identity_detail="$(coordinator_peer_eci_identity_detail 2>/dev/null || true)"
    case "$lifecycle_identity_detail" in
      "active session identity mismatch: expected="*)
        deny_eci "ECI_LIFECYCLE_IDENTITY_DENIED" "eci-lifecycle" \
          "ECI coordinator lifecycle identity denied: $lifecycle_identity_detail" \
          "use env with the provider-matched active session identity and canonical eci-active target"
        ;;
      "provider session identity mismatch: expected_name="*|\
        "provider session identity missing: expected_name="*)
        deny_eci "ECI_PLAN_LIFECYCLE_IDENTITY_DENIED" "plan-segment" \
          "ECI lifecycle identity plan denied: $lifecycle_identity_detail" \
          "use env with the provider-matched active session identity and canonical eci-active target"
        ;;
    esac
  fi
fi

ECI_LITERAL_ADMITTED=false
if [ "${#syntax_eci_markers[@]}" -gt 0 ] && [ "$plan_status" -eq 0 ] &&
  ! eci_cleanup_command_shape "$command" &&
  ! coordinator_script_batch_shape "$command" &&
  ! deferred_worker_operator_shape "$command" &&
  ! deferred_worker_wrapper_shape "$command" &&
  ! deferred_worker_control_shape "$command" &&
  ! deferred_route_lifecycle_shape "$command" &&
  ! deferred_route_script_shape "$command" &&
  ! deferred_route_environment_shape "$command" &&
  ! deferred_route_git_shape "$command" &&
  ! literal_git_mutation_shape "$command" &&
  ! deferred_route_proof_path_shape "$command" &&
  ! deferred_route_hook_repair_shape "$command"; then
  # The Go planner has already validated this complete finite plan. Keep the
  # active ownership predicates above, then use its generic admission instead
  # of re-applying the legacy executable grammar.
  ECI_LITERAL_ADMITTED=true
fi

if [ -n "$command" ] && [ "$(detect_git_push 2>/dev/null)" = "1" ]; then
  deny 'git push is blocked. No task in this environment requires git push, and no task is blocked by its absence. If you believe push is needed, that judgment is wrong — commit locally and proceed.'
fi

git_mutation_approved=false
command_state=unknown
review_markers=()

if [ "$hook_is_subagent" = true ] && command_invokes_eci_binary "$command"; then
  eci_binary_subject="$(eci_command_identity_subject "$command")"
  eci_binary_detail="$(rejected_command_detail "$command" 2>/dev/null || printf 'segment=<unclassified>')"
  deny_eci "ECI_CONTROL_OWNER_REQUIRED" "eci-control" \
    "ECI worker boundary denied direct invocation of a canonical Codex/Kimi eci-active binary: ${eci_binary_detail}; literal command=${eci_binary_subject} targets coordinator-owned lifecycle/control state" \
    "route the provider-matched lifecycle or control operation through the main/orchestrator; workers may report completion or blockers but must not invoke coordinator eci-active binaries"
fi

if [ "$hook_is_subagent" = true ] && command_invokes_eci_off "$command"; then
  deny_eci "ECI_LIFECYCLE_OWNER_REQUIRED" "eci-off" "Only the main thread/orchestrator may disengage ECI with eci-active off. Subagents must report completion or blockers to the orchestrator while ECI remains active." "report completion or blockers to the main/orchestrator"
fi

if [ "$hook_is_subagent" = true ] && command_invokes_eci_wait_or_resume "$command"; then
  deny_eci "ECI_LIFECYCLE_OWNER_REQUIRED" "eci-lifecycle" "Only the main/orchestrator may mutate ECI lifecycle state with eci-active wait/resume/ledger-append/nested-enter/nested-accept/nested-exit/manifest-write. Subagents must report the BRP result to the orchestrator." "report the requested lifecycle transition to the main/orchestrator"
fi

if [ "$hook_is_subagent" = true ] && command_invokes_eci_acceptance_mutation "$command"; then
  deny_eci "ECI_WORKER_ACCEPTANCE_DENIED" "worker-acceptance" "ECI worker boundary denied acceptance-sensitive Git mutation. Subagents must not commit or alter reviewed Git history; route the acceptance command through the main/orchestrator." "route the acceptance command through the main/orchestrator after the required review"
fi

if [ "$hook_is_subagent" = true ] && command_invokes_subagent_coordinator_only "$command"; then
  deny_eci "ECI_WORKER_COORDINATOR_ROUTE_DENIED" "coordinator-route" "ECI worker boundary denied coordinator-only temporary-directory setup: mktemp -d may be requested only by the main/orchestrator through the bounded literal route." "route mktemp -d setup through the main/orchestrator using a literal home-scoped temporary-root or canonical non-system TMPDIR template"
fi

if [ "$hook_is_subagent" = true ] && [ "${#syntax_eci_markers[@]}" -gt 0 ] &&
  [ "$ECI_LITERAL_ADMITTED" != true ] &&
  [ "$worker_read_only_pipeline_candidate" != true ] &&
  command_invokes_subagent_unsafe_launcher "$command"; then
  if command_invokes_subagent_explicit_launcher "$command"; then
    launcher_identity="$(eci_command_identity_subject "$command")"
    launcher_detail="$(rejected_command_detail "$command" 2>/dev/null || printf 'segment=<unclassified>')"
    deny_eci "ECI_WORKER_LAUNCHER_DENIED" "worker-launcher" "ECI worker boundary denied unsupported shell/interpreter launcher or direct review-gate invocation: command=${launcher_identity}; detail=${launcher_detail}. Route control-state and acceptance work through the main/orchestrator." "use the approved coordinator entrypoint instead of a shell/interpreter wrapper or direct review-gate invocation"
  else
    worker_identity="$(eci_command_identity_subject "$command")"
    worker_detail="$(rejected_command_detail "$command" 2>/dev/null || printf 'segment=<unclassified>')"
    deny_eci "ECI_WORKER_COMMAND_NOT_ALLOWLISTED" "worker-command" "ECI worker boundary denied unrecognized command form: ${worker_detail}; literal command=${worker_identity} is not in the bounded worker grammar while an active marker exists." "use an allowlisted worker read/inspection form or route the command through the coordinator-approved entrypoint"
  fi
fi

# A worker may use ordinary project tools, but must not inspect the peer
# provider's coordinator home through the generic read-only classifier.  The
# peer-root check is deliberately path-aware so benign worker writes and
# implementation/test commands remain available while coordinator-owned
# inspection state fails with a specific diagnostic.
worker_peer_path_detail() {
  python3 - "$1" <<'PY'
import os
import shlex
import sys

command = sys.argv[1]
worker_home = os.path.realpath(
    os.environ.get("CODEX_HOME") or os.environ.get("KIMI_CODE_HOME") or ""
)
home = os.environ.get("HOME", "")
peer_homes = {
    os.path.realpath(os.path.join(home, ".codex")),
    os.path.realpath(os.path.join(home, ".kimi-code")),
}
if not worker_home or not peer_homes:
    raise SystemExit(1)
try:
    tokens = shlex.split(command, posix=True)
except ValueError:
    raise SystemExit(1)
if not tokens or os.path.basename(tokens[0]) not in {
    "cat", "find", "grep", "head", "ls", "readlink", "realpath", "rg", "sed", "stat", "tail", "wc"
}:
    raise SystemExit(1)
for token in tokens[1:]:
    if not os.path.isabs(token) or any(mark in token for mark in ("$", "`", "(", ")", "*", "?", "[", "]")):
        continue
    lexical = os.path.normpath(token)
    resolved = os.path.realpath(token)
    for peer in peer_homes:
        if peer != worker_home and (
                lexical == peer or lexical.startswith(peer + os.sep) or
                resolved == peer or resolved.startswith(peer + os.sep)):
            print("peer-root path=%s resolved=%s worker-root=%s" % (token, resolved, worker_home))
            raise SystemExit(0)
raise SystemExit(1)
PY
}

worker_peer_check_needed=true
if [ "$ECI_LITERAL_ADMITTED" = true ]; then
  worker_peer_check_needed=false
  case "$command" in
    *"$HOME/.codex"*|*"$HOME/.kimi-code"*|*"~/.codex"*|*"~/.kimi-code"*) worker_peer_check_needed=true ;;
  esac
fi
if [ "$hook_is_subagent" = true ] && [ "${#syntax_eci_markers[@]}" -gt 0 ]; then
  if [ "$ECI_LITERAL_ADMITTED" = true ] && [ "$worker_peer_check_needed" != true ]; then
    worker_classification=allow
    worker_peer_detail=""
  else
    worker_classification="$(classify_eci_command "$command" 2>/dev/null || true)"
    worker_peer_detail="$(worker_peer_path_detail "$command" 2>/dev/null || true)"
  fi
  if [ "$worker_classification" = unknown ] && [ "$ECI_LITERAL_ADMITTED" != true ] &&
    [ -n "$worker_peer_detail" ]; then
  worker_subject="$(eci_command_identity_subject "$command")"
  worker_detail="$(rejected_command_detail "$command" 2>/dev/null || printf 'segment=<unclassified>')"
  deny_eci "ECI_WORKER_COMMAND_NOT_ALLOWLISTED" "worker-command" \
    "ECI worker boundary denied peer coordinator inspection: ${worker_peer_detail}; detail=${worker_detail}; literal command=${worker_subject} is not in the bounded worker grammar while marker=${syntax_eci_markers[0]} is active" \
    "for finite project/state inspection route the exact bounded payload through the main/orchestrator; for implementation, exploration, or test work delegate it to an ECI worker/subagent; otherwise invoke an allowlisted worker literal"
  fi
fi

if [ "$ECI_LITERAL_ADMITTED" = true ]; then
  # The planner has already completed the protected checks and admitted this
  # finite literal; avoid duplicate legacy coordinator classification.
  command_state=read-only
  read_only=true
fi

if [ "$worker_read_only_pipeline_candidate" = true ]; then
  if worker_read_only_pipeline_route "$command"; then
    worker_read_only_pipeline_admitted=true
    read_only=true
  else
    deny_worker_nonliteral || true
  fi
fi

if [ "$hook_is_subagent" != true ] && [ "$ECI_LITERAL_ADMITTED" != true ]; then
  mapfile -t review_markers < <(active_eci_markers_for_cwd "$cwd" "$session_id")
  for review_marker in "${review_markers[@]}"; do
    if ! codex_eci_marker_path_owner_is_valid "$review_marker"; then
      deny_marker_boundary "$review_marker" "$(codex_canonical_cwd "$cwd")" "$session_id"
    fi
  done
  [ "${#review_markers[@]}" -le 1 ] ||
    deny_eci "ECI_MARKER_OWNERSHIP_AMBIGUOUS" "commit-boundary" "ECI commit boundary denied: multiple active markers are unsafe; resolve ownership before committing." "resolve marker ownership so exactly one validated owner remains, then retry the commit"
  if ! command_state="$(classify_eci_command "$command")"; then
    command_state=unknown
  fi
  if [ "$command_state" = verification ]; then
    read_only=false
  elif [ "$command_state" = unknown ]; then
    # Environment-prefixed lifecycle commands are coordinator escape hatches,
    # not arbitrary shell assignments. Route this narrow form before the
    # generic command grammar so manifest-write reaches its peer recognizer.
    if [ "${#review_markers[@]}" -eq 1 ] && [[ "$command" == TMPDIR=* ]]; then
      if coordinator_tmpdir_manifest_route "$command"; then
        command_state=read-only
        read_only=true
      fi
    fi
    case "$command" in
      bash|bash\ *|sh|sh\ *|./hooks/tests/*.sh|/*)
        if [ "$command_state" = unknown ] && coordinator_script_route "$command"; then
          command_state=read-only
        fi
        ;;
      mv|mv\ *|rm|rm\ *)
        if [ "${#review_markers[@]}" -eq 1 ] && coordinator_cleanup_route "$command"; then
          command_state=cleanup
        fi
        ;;
    esac
    if [ "$command_state" = unknown ] && [ "${#review_markers[@]}" -eq 1 ] && coordinator_mktemp_route "$command"; then
      # Creating a temporary directory is a coordinator-owned setup action,
      # not a worker read-only capability.  The helper accepts only the exact
      # literal mktemp -d template and trusted executable/path roots.
      command_state=read-only
      read_only=true
    fi
    if [ "$command_state" = unknown ] && [ "${#review_markers[@]}" -eq 1 ] && coordinator_date_route "$command"; then
      command_state=read-only
      read_only=true
    fi
    if [ "$command_state" = unknown ] && [ "${#review_markers[@]}" -eq 1 ] && coordinator_peer_eci_route "$command"; then
      command_state=read-only
      read_only=true
      # approve-commit is itself the coordinator admission command; its
      # embedded git commit payload must not be reclassified as a mutation.
      # The eventual direct git commit remains subject to the normal gate.
      case "$command" in
        eci-active\ approve-commit\ *|/*/eci-active\ approve-commit\ *|~/.codex/bin/eci-active\ approve-commit\ *|~/.kimi-code/bin/eci-active\ approve-commit\ *)
          git_mutation_approved=true
          ;;
      esac
    fi
    # Cleanup is a coordinator escape hatch for generated artifacts only.
    # Keep it in the unknown-command dispatcher so mv/rm are classified before
    # the generic not-allowlisted diagnostic can fire.
    if [ "$command_state" = unknown ] && [ "${#review_markers[@]}" -eq 1 ]; then
      case "$command" in
        mv|mv\ *|rm|rm\ *)
          if coordinator_cleanup_route "$command"; then
            command_state=cleanup
          fi
          ;;
      esac
    fi
    if [ "$command_state" = unknown ] && coordinator_hook_mode_repair_route "$command"; then
      command_state=mode-repair
    fi
  fi
  # A canonical Codex/Kimi lifecycle binary is a coordinator-owned control
  # capability, even when its spelling would otherwise look like an ordinary
  # finite executable.  The peer route above admits only the exact provider
  # argument shapes; keep malformed lifecycle forms on the diagnostic path
  # instead of letting literal admission hide the bad verb/extra argument.
  if [ "${#review_markers[@]}" -eq 1 ] && [ "$command_state" = unknown ] &&
    command_invokes_eci_lifecycle "$command"; then
    lifecycle_subject="$(eci_command_identity_subject "$command")"
    lifecycle_detail="$(rejected_command_detail "$command" 2>/dev/null || printf 'segment=<unclassified>')"
    if [ -n "$COORDINATOR_PEER_ECI_ROUTE_DETAIL" ]; then
      lifecycle_detail="$COORDINATOR_PEER_ECI_ROUTE_DETAIL; $lifecycle_detail"
    fi
    lifecycle_identity_detail="$(coordinator_peer_eci_identity_detail 2>/dev/null || true)"
    if [ -n "$lifecycle_identity_detail" ]; then
      deny_eci "ECI_LIFECYCLE_IDENTITY_DENIED" "eci-lifecycle" \
        "ECI coordinator lifecycle identity denied: $lifecycle_identity_detail" \
        "use env with the provider-matched active session identity and canonical eci-active target"
    fi
    deny_eci "ECI_LIFECYCLE_ARGUMENTS_DENIED" "eci-lifecycle" \
      "ECI coordinator lifecycle route denied malformed provider arguments: ${lifecycle_detail}; literal command=${lifecycle_subject} names a canonical Codex/Kimi eci-active control binary but does not match an accepted lifecycle shape while marker=${review_markers[0]} is active" \
      "use the provider-matched eci-active lifecycle verb with its exact argument shape; route valid Codex/Kimi lifecycle calls through the coordinator entrypoint"
  fi
  maybe_enforce_git_mutation_gate
  if [ "${#review_markers[@]}" -eq 1 ] && [ "$command_state" = unknown ]; then
    case "$command" in
      git\ alias*|git\ ci\ *|git\ ci)
        deny_eci "ECI_GIT_EXECUTION_CONTEXT_DENIED" "git-execution-context" \
          "unrecognized or alias-capable Git verb may redirect execution: executable=git subcommand=$(printf '%s' "$command" | awk '{print $2}') argv_index=1" \
          "use an explicit bounded read-only Git verb or route Git mutation/alias through coordinator acceptance"
        ;;
    esac
  fi
  if [ "${#review_markers[@]}" -eq 1 ] && [ "$command_state" = unknown ] && [ "$git_mutation_approved" != true ] && [ "$ECI_LITERAL_ADMITTED" != true ]; then
    unsupported_subject="$(eci_command_identity_subject "$command")"
    unsupported_detail="$(rejected_command_detail "$command" 2>/dev/null || printf 'segment=<unclassified>')"
    case "$command" in
      bash\ *|sh\ *|/bin/bash\ *|/usr/bin/bash\ *|/bin/sh\ *|/usr/bin/sh\ *)
        [ -n "$COORDINATOR_SCRIPT_ROUTE_DETAIL" ] && unsupported_detail="$COORDINATOR_SCRIPT_ROUTE_DETAIL; $unsupported_detail"
        ;;
      mktemp|mktemp\ *)
        [ -n "$COORDINATOR_MKTEMP_ROUTE_DETAIL" ] && unsupported_detail="$COORDINATOR_MKTEMP_ROUTE_DETAIL; $unsupported_detail"
        ;;
      mv|mv\ *|rm|rm\ *)
        [ -n "$COORDINATOR_CLEANUP_ROUTE_DETAIL" ] && unsupported_detail="$COORDINATOR_CLEANUP_ROUTE_DETAIL; $unsupported_detail"
        ;;
      TMPDIR=*)
        [ -n "$COORDINATOR_TMPDIR_ROUTE_DETAIL" ] && unsupported_detail="$COORDINATOR_TMPDIR_ROUTE_DETAIL; $unsupported_detail"
        ;;
    esac
    unsupported_code="ECI_COMMAND_NOT_ALLOWLISTED"
    case "$command" in
      bash\ *|sh\ *|zsh\ *|dash\ *|env\ *|command\ *|builtin\ *|exec\ *|python\ *|python2\ *|python3\ *|perl\ *|ruby\ *|node\ *|deno\ *|go\ run\ *)
        unsupported_code="ECI_COMMAND_WRAPPER_UNSUPPORTED"
        unsupported_reason="unsupported wrapper/interpreter: ${unsupported_detail}; literal command=${unsupported_subject} is not in accepted grammar while marker=${review_markers[0]} is active"
        unsupported_remediation="for finite project/state inspection use the bounded coordinator inspection route; for implementation, exploration, or test payloads delegate to an ECI worker/subagent; otherwise invoke the payload directly as a separately reviewed literal call"
        ;;
      *)
        if [ "$hook_is_subagent" = true ]; then
          unsupported_code="ECI_WORKER_COMMAND_NOT_ALLOWLISTED"
          unsupported_reason="ECI worker boundary denied unrecognized command form: ${unsupported_detail}; literal command=${unsupported_subject} is not in the bounded worker grammar while marker=${review_markers[0]} is active"
          unsupported_remediation="use an allowlisted worker read/inspection form or route the command through the coordinator-approved entrypoint"
        else
          unsupported_reason="unrecognized command form: ${unsupported_detail}; literal command=${unsupported_subject} is not in accepted grammar while marker=${review_markers[0]} is active"
          unsupported_remediation="invoke an allowlisted literal command or route this script/test through the coordinator-approved entrypoint, then retry"
        fi
        ;;
    esac
    if [ "$hook_is_subagent" = true ]; then
      deny_eci "$unsupported_code" "worker-command" "$unsupported_reason" "$unsupported_remediation"
    else
      deny "$(eci_diagnostic_reason "$unsupported_code" "PreToolUse" "acceptance-boundary" "$unsupported_subject" "$unsupported_reason" "$unsupported_remediation")"
    fi
  fi
  if [ "${#review_markers[@]}" -eq 1 ] && [ "$command_state" = commit ] && [ "$git_mutation_approved" != true ]; then
    # PreToolUse is a synchronous local hook.  Do not invoke the full
    # repository/evidence review gate here: its bounded Git and manifest
    # checks belong to the explicit coordinator acceptance command.  Keeping
    # this boundary as a fast deny preserves the gate (and its fail-closed
    # semantics) without making every attempted commit wait on it.
    deny_eci "ECI_COMMIT_ADMISSION_REQUIRED" "commit-boundary" "ECI commit boundary denied: coordinator acceptance requires the eci-required-critics manifest and critic evidence before this commit; manifest=${review_markers[0]%/*}/eci-required-critics.json" "complete coordinator ECI review admission and publish the required manifest/evidence before committing"
  fi
else
  maybe_enforce_git_mutation_gate
fi

if [ "$read_only" != true ]; then
  codex_note_touched_repo "$session_id" "$cwd" "$cwd" || true
fi

if [ "$hook_is_subagent" != true ] && [ "$read_only" != true ]; then
  codex_mark_activity "$session_id" "$cwd" shell || true
fi
