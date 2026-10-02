#!/usr/bin/env bash
# PreToolUse hook: validate Bash commands before execution.

# Callback HOME metadata selects diagnostic context; it is not a concrete
# command effect. Malformed values therefore leave the command to Codex's
# ordinary execution path rather than creating an ECI denial or invalid hook
# response before a target can be evaluated.
case "${HOME:-}" in
  ''|/|*/|*'//'|*/./*|*/../*|*/.|*/..|*$'\n'*|*$'\r'*|!/*)
    exit 0
    ;;
esac

set -euo pipefail

unset ECI_READ_ONLY_PIPELINE

# Cross-repository Git checks remain enabled. The active session owner may
# declare one additional repository for Git mutations. Worker inspection and
# script routes still apply their worker-only boundary before using the same
# session-bound repository record.
ECI_CROSS_SCOPE_GATE_ENABLED=true

# Determine the hook directory without a PATH lookup: callback PATH may be
# empty or relative until the original value is captured below.
case "${BASH_SOURCE[0]}" in
  */*) hook_source_dir="${BASH_SOURCE[0]%/*}" ;;
  *) hook_source_dir=. ;;
esac
HOOK_DIR="$(cd "$hook_source_dir" && pwd)"
. "$HOOK_DIR/lib/codex-proof-state.sh"
. "$HOOK_DIR/lib/codex-tmp.sh"
. "$HOOK_DIR/lib/eci-diagnostic.sh"
. "$HOOK_DIR/lib/eci-environment-command.sh"
. "$HOOK_DIR/lib/eci-cleanup-route.sh"

# A configured proof-root alias is a spelling detail, not a second proof
# domain.  Canonicalize one existing final-component alias before any marker
# discovery so the rest of this callback uses one ordinary directory identity.
# Non-directory, dangling, and nested-link targets remain invalid through the
# existing state-path checks; this does not make an escaping control-file path
# admissible.
codex_canonicalize_configured_proof_root_alias() {
  local configured canonical

  [ -z "${CODEX_STOP_GATE_ROOT:-}" ] || return 0
  configured="$(codex_configured_proof_root)"
  [ -L "$configured" ] || return 0
  canonical="$(realpath -e -- "$configured" 2>/dev/null || true)"
  [ -n "$canonical" ] && [ -d "$canonical" ] && [ ! -L "$canonical" ] || return 0
  [ "$(realpath -m -- "$canonical" 2>/dev/null || true)" = "$canonical" ] || return 0
  CODEX_PROOF_ROOT="$canonical"
  export CODEX_PROOF_ROOT
}
codex_canonicalize_configured_proof_root_alias

CODEX_COMMAND_PATH_SET=false
CODEX_COMMAND_PATH_EXPORTED=false
if [[ -v PATH ]]; then
  CODEX_COMMAND_PATH_SET=true
  CODEX_COMMAND_PATH_EXPORTED=true
fi
CODEX_COMMAND_PATH="${PATH-}"
export CODEX_COMMAND_PATH CODEX_COMMAND_PATH_EXPORTED
CODEX_CD_PATH_SET=false
if [[ -v CDPATH ]]; then
  CODEX_CD_PATH_SET=true
fi
CODEX_CD_PATH="${CDPATH-}"
export CODEX_CD_PATH CODEX_CD_PATH_SET
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
    env)
      for candidate in /usr/bin/env /bin/env /usr/local/bin/env; do
        candidate="$(realpath -e -- "$candidate" 2>/dev/null || true)"
        if [ -n "$candidate" ] && [ -x "$candidate" ]; then
          printf '%s\n' "$candidate"
          return 0
        fi
      done
      ;;
  esac
  return 1
}

CODEX_TRUSTED_SED="$(resolve_trusted_system_executable sed || true)"
CODEX_TRUSTED_GIT="$(resolve_trusted_system_executable git || true)"
CODEX_TRUSTED_ENV="$(resolve_trusted_system_executable env || true)"
export CODEX_TRUSTED_SED CODEX_TRUSTED_GIT CODEX_TRUSTED_ENV

trusted_executable_on_path() {
  local name="${1:-}" expected path_entry candidate
  case "$name" in
    sed) expected="$CODEX_TRUSTED_SED" ;;
    git) expected="$CODEX_TRUSTED_GIT" ;;
    env) expected="$CODEX_TRUSTED_ENV" ;;
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

# trusted_literal_executable binds a planner-attested literal executable token
# to the established provider executable without executing that token. Bare
# names use the callback PATH; path spellings resolve from the callback cwd.
trusted_literal_executable() {
  local name="${1:-}" literal="${2:-}" expected candidate
  case "$name" in
    sed) expected="$CODEX_TRUSTED_SED" ;;
    git) expected="$CODEX_TRUSTED_GIT" ;;
    env) expected="$CODEX_TRUSTED_ENV" ;;
    *) return 1 ;;
  esac
  [ -n "$expected" ] || return 1
  if [ "$literal" = "$name" ]; then
    trusted_executable_on_path "$name"
    return $?
  fi
  case "$literal" in
    /*) candidate="$literal" ;;
    */*) candidate="$cwd/$literal" ;;
    *) return 1 ;;
  esac
  [ -x "$candidate" ] &&
    [ "$(realpath -e -- "$candidate" 2>/dev/null || true)" = "$expected" ]
}

finalize_command_gate_denial() {
  local source="$1" denial="$2"
  local role="${plan_role:-coordinator}" marker="${plan_marker_state:-inactive}"
  [ "${hook_is_subagent:-false}" != true ] || role=worker
  if declare -p syntax_eci_markers >/dev/null 2>&1 && [ "${#syntax_eci_markers[@]}" -gt 0 ]; then
    marker=active
  fi
  # A permissive gate-mode setting records inactive callback telemetry and
  # intentionally suppresses its output.  An active ECI marker is an
  # enforcement boundary, so forwarding a denial through that mode would turn
  # any rejected command into an allow.  Keep the exact denial bytes local to
  # the active callback instead.
  if [ "$marker" = active ]; then
    printf '%s\n' "$denial"
    return 0
  fi
  if printf '%s\n' "$denial" | "$HOOK_DIR/../bin/eci-command-gate-mode" \
    finalize codex "$role" "$marker" "$source"; then
    return 0
  fi
  printf '%s\n' "$denial"
}

command_plan_pretooluse_denial() {
  local plan_result="${1:-}" callback_marker='inactive'
  if declare -p syntax_eci_markers >/dev/null 2>&1 && [ "${#syntax_eci_markers[@]}" -gt 0 ]; then
    callback_marker="${syntax_eci_markers[0]}"
  fi
  printf '%s' "$plan_result" | jq -cser \
    --arg callback_session "${session_id:-<missing>}" \
    --arg callback_cwd "${cwd:-<missing>}" \
    --arg callback_marker "$callback_marker" '
    def valid_planner_denial:
      type == "object" and
      .decision == "deny" and
      (.hookSpecificOutput | type) == "object" and
      ((.hookSpecificOutput | keys | sort) == [
        "hookEventName",
        "permissionDecision",
        "permissionDecisionReason"
      ]) and
      .hookSpecificOutput.hookEventName == "PreToolUse" and
      .hookSpecificOutput.permissionDecision == "deny" and
      (.hookSpecificOutput.permissionDecisionReason | type) == "string" and
      (.hookSpecificOutput.permissionDecisionReason | length > 0);
    if (length == 1 and (.[0] | valid_planner_denial)) then
      {hookSpecificOutput: (.[0].hookSpecificOutput |
        .permissionDecisionReason += "; callback_session=" + $callback_session +
        ", callback_cwd=" + $callback_cwd + ", callback_marker=" + $callback_marker)}
    else
      error("invalid command-plan PreToolUse denial")
    end
  ' 2>/dev/null
}

deny() {
  local reason="${1:-unspecified Bash validation denial}"
  if [[ "$reason" != \[ECI_* ]]; then
    local subject
    subject="tool=Bash,command=$(eci_command_identity_subject "${command:-}"),session=$(eci_diagnostic_value "${session_id:-<missing>}"),cwd=$(eci_diagnostic_value "${cwd:-<missing>}")"
    reason="$(eci_diagnostic_reason "$(eci_diagnostic_code_for_reason "$reason")" "PreToolUse" "bash-validation" "$subject" "$reason" "correct the reported command or route acceptance-sensitive work to the Supervisor, then retry")"
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
      remediation="recreate the marker through the Supervisor lifecycle route, or complete teardown before retrying"
      ;;
    ECI_MARKER_UNSAFE_PATH)
      detail="active ECI marker path is outside the validated proof-root layout or is a symlink"
      remediation="use the canonical proof-root/session/eci_active path and remove the unsafe path before retrying"
      ;;
    ECI_MARKER_MALFORMED)
      detail="active ECI marker content is malformed or exceeds the bounded record schema"
      remediation="repair the marker through the Supervisor lifecycle route with the required bounded fields"
      ;;
    ECI_MARKER_SCOPE_MISMATCH)
      detail="active ECI marker owner or cwd does not match session=$expected_session cwd=$expected_cwd"
      remediation="use the marker bound to this session and cwd, or complete teardown before retrying"
      ;;
    ECI_MARKER_OWNERSHIP_INVALID)
      detail="active ECI marker path owner does not match its embedded session identity"
      remediation="repair marker ownership through the Supervisor lifecycle route; do not edit the marker directly"
      ;;
    *)
      detail="active ECI marker failed validation for session=$expected_session cwd=$expected_cwd"
      remediation="inspect the marker binding and repair or complete ECI teardown before retrying"
      ;;
  esac
  deny "$(eci_diagnostic_reason "$code" "PreToolUse" "acceptance-boundary" "$marker" "$detail" "$remediation")"
}

command_invokes_eci_control_mutation_if_defined() {
  # deny_eci runs during the initial marker and planner boundary checks,
  # before the full mutation classifier is defined later in this file.  The
  # surrounding denial remains fail-closed either way; this guard prevents an
  # undefined-function diagnostic from corrupting the hook's JSON protocol.
  declare -F command_invokes_eci_control_mutation >/dev/null 2>&1 || return 1
  command_invokes_eci_control_mutation "$@"
}

deny_eci() {
  local code="$1" operation="$2" detail="$3" remediation="$4"
  local subject identity role="${plan_role:-coordinator}" marker="${plan_marker_state:-inactive}"
  # A historical permissive record is diagnostic state, never command
  # authority.  Normal work must not need it, and malformed, expired, or
  # unreadable state must not change this callback's result.  The concrete
  # operation and target decide whether a denial is warranted.
  [ "${hook_is_subagent:-false}" != true ] || role=worker
  if declare -p syntax_eci_markers >/dev/null 2>&1 && [ "${#syntax_eci_markers[@]}" -gt 0 ]; then
    marker=active
  fi
  identity="$(eci_command_identity_subject "${command:-}")"
  [[ "$detail" == *"rejected command="* ]] || detail="$detail; rejected command=$identity"
  subject="provider=codex,role=$role,marker=$marker,command=$identity,session=$(eci_diagnostic_value "${session_id:-<missing>}"),cwd=$(eci_diagnostic_value "${cwd:-<missing>}"),repo=$(eci_diagnostic_value "${cwd:-$PWD}")"
  deny "$(eci_diagnostic_reason "$code" "PreToolUse" "$operation" "$subject" "$detail" "$remediation")"
}

# Resolve interpreter-context assignments by their concrete effect.  An
# environment variable name, punctuation, or an unfamiliar wrapper is not a
# denial reason.  Only an assignment that points at an existing file/path and
# is attached to an existing literal interpreter script is actionable: it can
# change that script's startup/modules/executable context before the script
# runs.  Missing, empty, ordinary, and unresolved values remain transparent.
environment_script_target() {
  python3 - "$1" "$cwd" <<'PY'
import os
import re
import shlex
import sys

command, callback_cwd = sys.argv[1:]

FILE_VARS = {"BASH_ENV", "ENV", "PYTHONSTARTUP", "LD_PRELOAD"}
PATH_VARS = {
    "PATH", "CDPATH", "GEM_HOME", "GEM_PATH", "LD_LIBRARY_PATH", "NODE_PATH",
    "PERL5LIB", "PYTHONHOME", "PYTHONPATH", "RUBYLIB", "ZDOTDIR",
}
OPTION_VARS = {"NODE_OPTIONS", "PERL5OPT", "RUBYOPT"}
CONTEXT_VARS = FILE_VARS | PATH_VARS | OPTION_VARS
ASSIGNMENT = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)=(.*)", re.S)

# `shlex` with punctuation enabled gives us a finite top-level argv for each
# visible shell segment.  Operators split execution contexts; they do not
# themselves make a command unsafe.
OPERATORS = {
    ";", "&", "&&", "|", "||", "(", ")", ">", ">>", ">|", ">&",
    "<", "<<", "<<<", "<&",
}

INTERPRETER_RE = {
    "shell": re.compile(r"^(?:ash|bash|dash|fish|ksh|sh|zsh)(?:[0-9.]*)$"),
    "node": re.compile(r"^(?:node|nodejs)(?:[0-9.]*)$"),
    "perl": re.compile(r"^perl(?:[0-9.]*)$"),
    "php": re.compile(r"^php(?:[0-9.]*)$"),
    "python": re.compile(r"^python(?:[0-9.]*)$"),
    "ruby": re.compile(r"^ruby(?:[0-9.]*)$"),
}


def split_segments(values):
    segments = []
    current = []
    for token in values + [";"]:
        if token in OPERATORS:
            if current:
                segments.append(current)
            current = []
        else:
            current.append(token)
    return segments


def resolved_path(value, base):
    # Shell expansion is intentionally not guessed.  A literal `$VAR`, glob,
    # command substitution, or malformed value is unresolved and transparent.
    if not value or "\x00" in value or "\n" in value or "\r" in value:
        return None
    candidate = value if os.path.isabs(value) else os.path.join(base, value)
    return os.path.realpath(os.path.normpath(candidate))


def existing_file(value, base):
    path = resolved_path(value, base)
    return path if path and os.path.isfile(path) else None


def existing_path(value, base):
    path = resolved_path(value, base)
    return path if path and os.path.exists(path) else None


def option_references(value, kind):
    try:
        tokens = shlex.split(value, posix=True)
    except ValueError:
        return []
    references = []
    index = 0
    if kind == "node":
        attached = ("--require=", "--loader=", "--import=")
        separate = {"--require", "--loader", "--import", "-r"}
    elif kind == "ruby":
        attached = ()
        separate = {"-r", "-I"}
    else:  # perl
        attached = ()
        separate = {"-I"}

    while index < len(tokens):
        token = tokens[index]
        if any(token.startswith(prefix) and len(token) > len(prefix) for prefix in attached):
            for prefix in attached:
                if token.startswith(prefix) and len(token) > len(prefix):
                    references.append(token[len(prefix):])
                    break
        elif token in separate:
            if index + 1 < len(tokens):
                references.append(tokens[index + 1])
                index += 1
        elif kind == "node" and token.startswith("-r") and len(token) > 2:
            references.append(token[2:])
        elif kind == "ruby" and token.startswith(("-r", "-I")) and len(token) > 2:
            references.append(token[2:])
        elif kind == "perl" and token.startswith("-I") and len(token) > 2:
            references.append(token[2:])
        index += 1
    return references


def assignment_effect(name, value, base):
    if name in FILE_VARS:
        return ("file", existing_file(value, base))
    if name in PATH_VARS:
        for component in value.split(":"):
            if component:
                path = existing_path(component, base)
                if path:
                    return ("path", path)
        return ("path", None)
    if name in OPTION_VARS:
        if name == "NODE_OPTIONS":
            kind = "node"
        elif name == "RUBYOPT":
            kind = "ruby"
        else:
            kind = "perl"
        for reference in option_references(value, kind):
            path = existing_path(reference, base)
            if path:
                return ("option", path)
        return ("option", None)
    return ("", None)


def interpreter_kind(token):
    name = os.path.basename(token)
    for kind, pattern in INTERPRETER_RE.items():
        if pattern.fullmatch(name):
            return kind
    return None


def script_target(values, kind, base):
    if not values:
        return None
    index = 1
    while index < len(values):
        token = values[index]
        if token == "--":
            index += 1
            break
        if token == "-":
            return None
        if kind == "shell":
            if token in {"-c", "--command", "--rcfile"}:
                return None
            if token.startswith("--command=") or token.startswith("--rcfile="):
                return None
            if token in {"-O", "--option"}:
                index += 2
                continue
        elif kind == "node":
            if token in {"-e", "--eval", "-p", "--print"} or token.startswith(("--eval=", "--print=")):
                return None
        elif kind == "perl":
            if token in {"-e", "-E"} or token.startswith(("-e", "-E")):
                return None
        elif kind == "php":
            if token in {"-r", "-R", "-B", "-E"} or token.startswith(("-r", "-R", "-B", "-E")):
                return None
        elif kind == "python":
            if token in {"-c", "-m", "-"} or token.startswith(("-c", "-m")):
                return None
            if token in {"-X", "-W"}:
                index += 2
                continue
        elif kind == "ruby":
            if token in {"-e", "-E", "-"} or token.startswith(("-e", "-E")):
                return None
        if token.startswith("-"):
            index += 1
            continue
        break
    if index >= len(values):
        return None
    candidate = values[index]
    resolved = resolved_path(candidate, base)
    if not resolved or not os.path.isfile(resolved):
        return None
    return resolved


def parse_command(values, context, base, segment, allow_assignments=True, depth=0):
    if not values or depth > 8:
        return None
    values = list(values)
    index = 0
    context = list(context)
    if allow_assignments:
        while index < len(values):
            match = ASSIGNMENT.fullmatch(values[index])
            if not match:
                break
            name, value = match.groups()
            if name in CONTEXT_VARS:
                effect, path = assignment_effect(name, value, base)
                context.append((name, index, effect, path))
            index += 1
    if index >= len(values):
        return None

    executable = os.path.basename(values[index])
    if executable == "env":
        index += 1
        env_context = list(context)
        env_base = base
        while index < len(values):
            token = values[index]
            if token in {"-i", "--ignore-environment"}:
                env_context = []
                index += 1
                continue
            if token in {"-u", "--unset"}:
                if index + 1 >= len(values):
                    return None
                name = values[index + 1]
                env_context = [item for item in env_context if item[0] != name]
                index += 2
                continue
            if token.startswith("--unset="):
                name = token.split("=", 1)[1]
                env_context = [item for item in env_context if item[0] != name]
                index += 1
                continue
            if token in {"-C", "--chdir"}:
                if index + 1 >= len(values):
                    return None
                changed = existing_path(values[index + 1], env_base)
                if changed and os.path.isdir(changed):
                    env_base = changed
                index += 2
                continue
            if token.startswith("--chdir="):
                changed = existing_path(token.split("=", 1)[1], env_base)
                if changed and os.path.isdir(changed):
                    env_base = changed
                index += 1
                continue
            if token in {"-S", "--split-string"} or token.startswith("--split-string="):
                if token in {"-S", "--split-string"}:
                    if index + 1 >= len(values):
                        return None
                    payload = values[index + 1]
                else:
                    payload = token.split("=", 1)[1]
                try:
                    nested = shlex.split(payload, posix=True)
                except ValueError:
                    return None
                return parse_command(nested, env_context, env_base, segment, True, depth + 1)
            if token == "--":
                # After `env --`, all following tokens are command argv.  An
                # assignment-looking token is not reinterpreted as an env
                # assignment (for example `env -- BASH_ENV=/etc/profile bash script`).
                return parse_command(values[index + 1:], env_context, env_base, segment, False, depth + 1)
            match = ASSIGNMENT.fullmatch(token)
            if match:
                name, value = match.groups()
                if name in CONTEXT_VARS:
                    effect, path = assignment_effect(name, value, env_base)
                    env_context.append((name, index, effect, path))
                index += 1
                continue
            if token.startswith("-"):
                return None
            break
        return parse_command(values[index:], env_context, env_base, segment, False, depth + 1)

    if executable in {"command", "builtin", "exec", "nohup", "setsid"}:
        return parse_command(values[index + 1:], context, base, segment, False, depth + 1)

    kind = interpreter_kind(values[index])
    if kind is None:
        return None
    target = script_target(values[index:], kind, base)
    if target is None:
        return None
    for name, assignment_index, effect, path in context:
        if path:
            return name, assignment_index, segment, target, effect
    return None


try:
    lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
    tokens = list(lexer)
except ValueError:
    raise SystemExit(1)

for segment, values in enumerate(split_segments(tokens), 1):
    result = parse_command(values, [], callback_cwd, segment)
    if result is not None:
        print("\t".join(str(value) for value in result))
        raise SystemExit(0)
raise SystemExit(1)
PY
}

enforce_environment_script_target() {
  local command_value="$1" detail context_name context_index segment target effect
  detail="$(environment_script_target "$command_value" 2>/dev/null || true)"
  [ -n "$detail" ] || return 0
  IFS=$'\t' read -r context_name context_index segment target effect <<<"$detail"
  deny_eci "ECI_ENVIRONMENT_CONTEXT_DENIED" "environment-boundary" \
    "ECI ${plan_role:-coordinator} environment context denied for an existing interpreter script: token=$context_name argv_index=$context_index segment=$segment target=$target effect=$effect; predicate=interpreter-context; reason=the resolved environment assignment changes the reviewed script's execution context" \
    "invoke the existing script without the resolved startup/module/path assignment, or use a reviewed clean-context route"
}

active_eci_markers_for_cwd() {
  local probe_cwd="${1:-}" probe_session="${2:-}" marker parent_session
  local direct_marker="" parent_marker="" canonical_cwd="" resolved_marker=""
  [ -n "$probe_cwd" ] || return 0
  canonical_cwd="$(codex_canonical_cwd "$probe_cwd")"

  # Marker discovery is advisory context for ordinary work. Select at most one
  # valid marker bound to this callback; malformed, stale, duplicate, and
  # unsafe scan observations do not turn an unrelated command into a denial.
  # Concrete writes to a resolved foreign marker remain target-checked later.
  if ! codex_proof_root_is_safe; then
    return 0
  fi
  if codex_valid_session_id "$probe_session"; then
    direct_marker="$(codex_proof_root)/$probe_session/eci_active"
    if { [ -e "$direct_marker" ] || [ -L "$direct_marker" ]; } &&
      codex_eci_marker_metadata_is_valid "$direct_marker" "$canonical_cwd"; then
      resolved_marker="$direct_marker"
    fi
  fi

  # The typed session marker is authoritative.  Avoid rescanning the entire
  # proof root on every callback once it has been validated; the scan is only
  # needed to discover a marker when the direct session record is absent.
  if [ -n "$resolved_marker" ]; then
    printf '%s\n' "$resolved_marker"
    return 0
  fi

  # A historical session_ alias can be the one valid marker for this callback.
  # Once the direct marker is valid, any additional aliases are observations,
  # not competing owners.
  while IFS= read -r marker; do
    case "$marker" in
      "$codex_eci_marker_scan_unsafe_token"|"$codex_eci_marker_scan_overflow_token") continue ;;
    esac
    [ -z "$resolved_marker" ] || continue
    [ -n "$marker" ] || continue
    if codex_eci_marker_metadata_is_valid "$marker" "$canonical_cwd"; then
      resolved_marker="$marker"
    fi
  done < <(codex_eci_markers_for_cwd "$probe_cwd" strict "$probe_session" 2>/dev/null || true)

  # A worker may inherit a valid parent aggregate marker. Keep that one
  # resolved record available for the aggregate route, but treat a stale or
  # malformed parent record as advisory just like any other observation.
  if [ -z "$resolved_marker" ] && [ "${hook_is_subagent:-false}" = true ]; then
    parent_session="${CODEX_HOOK_PARENT_SESSION_ID:-}"
    if codex_valid_session_id "$parent_session" && [ "$parent_session" != "$probe_session" ]; then
      parent_marker="$(codex_proof_root)/$parent_session/eci_active"
      if { [ -e "$parent_marker" ] || [ -L "$parent_marker" ]; } &&
        codex_eci_marker_metadata_is_valid "$parent_marker"; then
        resolved_marker="$parent_marker"
      fi
    fi
  fi

  [ -z "$resolved_marker" ] || printf '%s\n' "$resolved_marker"
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
hook_original_command="$command"

# Recursive segment state is accepted only when structurally eligible JSON is
# paired with the per-child token carried on FD9 by the parent planner. A
# shape-valid callback payload alone never activates this route. Never consume
# the historical ECI_COMPOUND_* environment variables: inherited values are
# caller-controlled and may describe a stale CWD or replay context. The
# callback CWD remains the marker anchor; the planner-owned segment fact is
# carried separately to target resolvers.
COMPOUND_SEGMENT_VALIDATION=false
COMPOUND_SEGMENT_CWD_KNOWN=false
COMPOUND_SEGMENT_CWD_UNKNOWN=false
COMPOUND_SEGMENT_CWD=""
COMPOUND_SEGMENT_CWD_CANDIDATES='[]'
COMPOUND_SEGMENT_CWD_PHYSICAL=""
COMPOUND_SEGMENT_CWD_PHYSICAL_CANDIDATES='[]'
COMPOUND_SEGMENT_REACHABILITY=reachable
COMPOUND_SEGMENT_COMMAND_PATH=""
COMPOUND_SEGMENT_COMMAND_PATH_SET=false
COMPOUND_SEGMENT_COMMAND_PATH_EXPORTED=false
COMPOUND_HANDOFF_TOKEN=""
COMPOUND_SEGMENT_METADATA_ELIGIBLE=false
if jq -e '
  . as $root |
  (.eci_compound_segment? | type) == "object" and
  ((.eci_compound_segment | keys | sort) == [
    "command_path", "command_path_exported", "command_path_set", "cwd",
    "cwd_candidates", "cwd_known", "cwd_physical", "cwd_physical_candidates", "cwd_unknown", "handoff_token", "reachability", "validation"
  ]) and
  .eci_compound_segment.validation == true and
  (.eci_compound_segment.handoff_token | type) == "string" and
  (.eci_compound_segment.handoff_token | length > 0) and
  (.eci_compound_segment.cwd | type) == "string" and
  (.eci_compound_segment.cwd_candidates | type == "array" and
    length <= 128 and all(.[]; type == "string" and test("^/") and length <= 4096)) and
  (.eci_compound_segment.cwd_physical | type == "string") and
  (.eci_compound_segment.cwd_physical_candidates | type == "array" and
    length <= 128 and all(.[]; type == "string" and test("^/") and length <= 4096)) and
  (.eci_compound_segment.cwd_known | type) == "boolean" and
  (.eci_compound_segment.cwd_unknown | type) == "boolean" and
  (.eci_compound_segment.reachability | type == "string" and
    (. == "reachable" or . == "unreachable" or . == "unknown")) and
  (if .eci_compound_segment.cwd_known then
    (.eci_compound_segment.cwd_unknown == false) and
    (.eci_compound_segment.cwd | test("^/")) and
    ($root.eci_compound_segment.cwd_candidates |
      index($root.eci_compound_segment.cwd) != null)
   else .eci_compound_segment.cwd == "" end) and
  (if .eci_compound_segment.cwd_known then
    (.eci_compound_segment.cwd_physical != "") and
    ($root.eci_compound_segment.cwd_physical_candidates |
      index($root.eci_compound_segment.cwd_physical) != null)
   else .eci_compound_segment.cwd_physical == "" end) and
  (.eci_compound_segment.command_path | type) == "string" and
  (.eci_compound_segment.command_path_set | type) == "boolean" and
  (.eci_compound_segment.command_path_exported | type) == "boolean" and
  (if .eci_compound_segment.command_path_set then true
   else .eci_compound_segment.command_path == "" and
        .eci_compound_segment.command_path_exported == false end)
' <<<"$input" >/dev/null 2>&1; then
  COMPOUND_SEGMENT_METADATA_ELIGIBLE=true
  if [ -e "/proc/$$/fd/9" ]; then
    IFS= read -r COMPOUND_HANDOFF_TOKEN <&9 || COMPOUND_HANDOFF_TOKEN=""
  fi
  if [ "$COMPOUND_SEGMENT_METADATA_ELIGIBLE" = true ] &&
    jq -e --arg handoff_token "$COMPOUND_HANDOFF_TOKEN" \
    '.eci_compound_segment.handoff_token == $handoff_token' <<<"$input" >/dev/null 2>&1; then
    COMPOUND_SEGMENT_VALIDATION=true
    COMPOUND_SEGMENT_CWD_KNOWN="$(jq -r '.eci_compound_segment.cwd_known' <<<"$input")"
    COMPOUND_SEGMENT_CWD_UNKNOWN="$(jq -r '.eci_compound_segment.cwd_unknown' <<<"$input")"
    COMPOUND_SEGMENT_CWD="$(jq -r '.eci_compound_segment.cwd' <<<"$input")"
    COMPOUND_SEGMENT_CWD_CANDIDATES="$(jq -c '.eci_compound_segment.cwd_candidates' <<<"$input")"
    COMPOUND_SEGMENT_CWD_PHYSICAL="$(jq -r '.eci_compound_segment.cwd_physical' <<<"$input")"
    COMPOUND_SEGMENT_CWD_PHYSICAL_CANDIDATES="$(jq -c '.eci_compound_segment.cwd_physical_candidates' <<<"$input")"
    COMPOUND_SEGMENT_REACHABILITY="$(jq -r '.eci_compound_segment.reachability' <<<"$input")"
    COMPOUND_SEGMENT_COMMAND_PATH="$(jq -r '.eci_compound_segment.command_path' <<<"$input")"
    COMPOUND_SEGMENT_COMMAND_PATH_SET="$(jq -r '.eci_compound_segment.command_path_set' <<<"$input")"
    COMPOUND_SEGMENT_COMMAND_PATH_EXPORTED="$(jq -r '.eci_compound_segment.command_path_exported' <<<"$input")"
    compound_candidate_valid=true
    while IFS= read -r compound_candidate; do
      compound_candidate_physical="$(realpath -e -- "$compound_candidate" 2>/dev/null || true)"
      if [ -z "$compound_candidate" ] || [ -z "$compound_candidate_physical" ] ||
        [ ! -d "$compound_candidate" ] || [ ! -x "$compound_candidate" ] ||
        ! jq -e --arg physical "$compound_candidate_physical" 'index($physical) != null' <<<"$COMPOUND_SEGMENT_CWD_PHYSICAL_CANDIDATES" >/dev/null 2>&1; then
        compound_candidate_valid=false
        break
      fi
    done < <(jq -r '.[]' <<<"$COMPOUND_SEGMENT_CWD_CANDIDATES" 2>/dev/null || true)
    if [ "$COMPOUND_SEGMENT_CWD_KNOWN" = true ] &&
      [ "$compound_candidate_valid" = true ] &&
      [ "$(realpath -e -- "$COMPOUND_SEGMENT_CWD" 2>/dev/null || true)" = "$COMPOUND_SEGMENT_CWD_PHYSICAL" ] &&
      [ -d "$COMPOUND_SEGMENT_CWD" ] && [ -x "$COMPOUND_SEGMENT_CWD" ]; then
      :
    elif [ "$COMPOUND_SEGMENT_CWD_KNOWN" = true ] || [ "$compound_candidate_valid" != true ]; then
      # A malformed planner handoff is not allowed to fall back to callback CWD.
      COMPOUND_SEGMENT_CWD_KNOWN=false
      COMPOUND_SEGMENT_CWD_UNKNOWN=true
      COMPOUND_SEGMENT_CWD=""
      COMPOUND_SEGMENT_CWD_CANDIDATES='[]'
      COMPOUND_SEGMENT_CWD_PHYSICAL=""
      COMPOUND_SEGMENT_CWD_PHYSICAL_CANDIDATES='[]'
    fi
    CODEX_COMMAND_PATH="$COMPOUND_SEGMENT_COMMAND_PATH"
    CODEX_COMMAND_PATH_SET="$COMPOUND_SEGMENT_COMMAND_PATH_SET"
    CODEX_COMMAND_PATH_EXPORTED="$COMPOUND_SEGMENT_COMMAND_PATH_EXPORTED"
    export CODEX_COMMAND_PATH CODEX_COMMAND_PATH_EXPORTED
    CODEX_CD_PATH_SET=false
    CODEX_CD_PATH=""
    PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${CODEX_COMMAND_PATH}"
    export PATH
  fi
fi

# Authenticate explicit worker context before malformed-input handling. The
# bounded transcript parser runs only for a typed payload that supplies a
# transcript path; ordinary planner callbacks do not need transcript metadata.
hook_is_subagent=false
case "${CODEX_HOOK_IS_SUBAGENT:-false}" in
  true)
    hook_is_subagent=true
    ;;
  *)
    ;;
esac
CODEX_HOOK_PARENT_SESSION_ID=""
CODEX_HOOK_CONTEXT_METADATA=""
CODEX_TIMEOUT_REPLAY=false
CODEX_TIMEOUT_REPLAYS='[]'

if [ "$typed_input" != true ]; then
  # Callback shape is context, not an effect. A malformed callback cannot be
  # safely attributed to a resolved target, so make no hook decision.
  exit 0
fi

# Recursive compound validation receives only planner-produced timeout replay
# records. Missing or malformed metadata deliberately selects an empty replay
# mode so a child cannot re-probe using this hook's stale outer callback state.
if [ "$COMPOUND_SEGMENT_VALIDATION" = true ]; then
  CODEX_TIMEOUT_REPLAY=true
  CODEX_TIMEOUT_REPLAYS="$(jq -c '
    def exact_keys($expected): (keys | sort) == $expected;
    def positive_integer: type == "number" and floor == . and . >= 1 and . <= 8;
    def bounded_string: type == "string" and length > 0 and length <= 4096;
    def replay_fact:
      type == "object" and
      ((keys | sort) == ["command_path", "command_path_exported", "command_path_set", "cwd", "disposition", "parent_segment", "prefix", "segment"] or
       (keys | sort) == ["command_path", "command_path_exported", "command_path_set", "cwd", "cwd_physical", "disposition", "parent_segment", "prefix", "segment"]) and
      (.segment | positive_integer) and
      (.parent_segment | positive_integer) and
      (.prefix | type == "array" and length >= 2 and length <= 128 and all(.[]; bounded_string)) and
      (.cwd | type == "string" and test("^/")) and
      (.cwd_physical? // "" | type == "string" and (length == 0 or test("^/"))) and
      (.command_path | type == "string") and
      (.command_path_set | type == "boolean") and
      (.command_path_exported | type == "boolean") and
      (.disposition == "observed" or .disposition == "opaque") and
      (if .command_path_set then true else (.command_path == "" and .command_path_exported == false) end);
    if (.timeout_replays? | type) == "array" then
      [.timeout_replays[] | select(replay_fact)]
    else
      []
    end
  ' <<<"$input" 2>/dev/null || printf '[]')"
fi

# Help, short help, and status expose lifecycle state only. Let the invoked
# program handle those commands before planner receipts, marker metadata,
# provider spelling, role, or executable identity can turn visibility into a
# false access boundary. A shell operator is not ignored here: it may add a
# concrete redirect or other effect, which remains for the normal target-aware
# evaluation below.
read_only_lifecycle_visibility_command() {
  python3 - "$1" <<'PY'
import os
import re
import shlex
import sys

try:
    lexer = shlex.shlex(sys.argv[1], posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    tokens = list(lexer)
except ValueError:
    raise SystemExit(1)

operators = {";", "&", "&&", "|", "||", "(", ")", ">", ">>", ">|", ">&", "<", "<<", "<<<", "<&"}
if not tokens or any(token in operators for token in tokens):
    raise SystemExit(1)

assignment = re.compile(r"[A-Za-z_][A-Za-z0-9_]*=.*", re.DOTALL)
index = 0
while index < len(tokens) and assignment.fullmatch(tokens[index]):
    index += 1
if index >= len(tokens):
    raise SystemExit(1)

launcher = os.path.basename(os.path.expanduser(os.path.expandvars(tokens[index])))
if launcher == "env":
    index += 1
    while index < len(tokens):
        token = tokens[index]
        if token == "--":
            index += 1
            continue
        if assignment.fullmatch(token):
            index += 1
            continue
        if token in {"-i", "--ignore-environment", "-0", "--null"}:
            index += 1
            continue
        if token in {"-u", "--unset"}:
            index += 2
            continue
        if token.startswith("--unset="):
            index += 1
            continue
        break
if index >= len(tokens):
    raise SystemExit(1)

executable = os.path.basename(os.path.expanduser(os.path.expandvars(tokens[index])))
arguments = tokens[index + 1:]
if (executable == "eci-active" and len(arguments) == 1 and
        arguments[0] in {"--help", "-h", "status"}):
    raise SystemExit(0)
raise SystemExit(1)
PY
}

if read_only_lifecycle_visibility_command "$command"; then
  exit 0
fi

# A lifecycle mutation has a concrete executable target. Keep that target
# check independent of planner provenance and spelling, while leaving an
# unresolved command to normal execution and leaving the visibility verbs
# above unrestricted.
lifecycle_mutation_different_target() {
  python3 - "$1" "$cwd" <<'PY'
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

operators = {";", "&", "&&", "|", "||", "(", ")", ">", ">>", ">|", ">&", "<", "<<", "<<<", "<&"}
if not tokens or any(token in operators for token in tokens):
    raise SystemExit(1)

assignment = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)=(.*)", re.DOTALL)
environment = dict(os.environ)
def skip_transparent(index):
    """Return the child argv index for finite transparent wrappers."""
    if index >= len(tokens):
        return None
    name = os.path.basename(os.path.expanduser(os.path.expandvars(tokens[index])))
    if name == "env":
        index += 1
        while index < len(tokens):
            token = tokens[index]
            if token == "--":
                return index + 1
            match = assignment.fullmatch(token)
            if match is not None:
                environment[match.group(1)] = match.group(2)
                index += 1
                continue
            if token in {"-i", "--ignore-environment", "-0", "--null"}:
                index += 1
                continue
            if token in {"-u", "--unset", "-C", "--chdir"}:
                index += 2
                continue
            if token.startswith("--unset=") or token.startswith("--chdir="):
                index += 1
                continue
            break
        return index
    if name in {"command", "builtin", "exec", "nohup", "setsid", "chronic"}:
        return index + 1
    if name == "busybox":
        return index + 2 if index + 1 < len(tokens) and tokens[index + 1] == "--" else index + 1
    if name == "stdbuf":
        index += 1
        while index < len(tokens) and tokens[index].startswith("-"):
            index += 1
        return index
    if name == "timeout":
        index += 1
        while index < len(tokens) and tokens[index].startswith("-"):
            index += 2 if tokens[index] in {"-k", "--kill-after", "-s", "--signal"} else 1
        return index + 1 if index < len(tokens) else index
    if name in {"time", "nice", "prlimit", "systemd-run", "sudo", "doas"}:
        index += 1
        while index < len(tokens) and tokens[index].startswith("-"):
            index += 1
        return index
    return index

index = 0
while index < len(tokens):
    match = assignment.fullmatch(tokens[index])
    if match is None:
        break
    environment[match.group(1)] = match.group(2)
    index += 1
while index < len(tokens):
    child = skip_transparent(index)
    if child is None or child == index:
        break
    index = child
if index >= len(tokens):
    raise SystemExit(1)

raw_executable = os.path.expanduser(os.path.expandvars(tokens[index]))
arguments = tokens[index + 1:]
if (not os.path.basename(raw_executable).startswith("eci-active") or not arguments or
        arguments[0] in {"--help", "-h", "status"}):
    raise SystemExit(1)
if "/" in raw_executable:
    candidate = raw_executable if os.path.isabs(raw_executable) else os.path.join(sys.argv[2], raw_executable)
else:
    candidate = shutil.which(raw_executable, path=environment.get("PATH"))
if not candidate:
    raise SystemExit(1)
candidate = os.path.realpath(candidate)
canonical = os.path.join(os.environ.get("HOME", ""), ".codex", "bin", "eci-active")
try:
    same_target = os.path.samefile(candidate, canonical)
except OSError:
    same_target = False
if not same_target:
    print(candidate)
    raise SystemExit(0)
raise SystemExit(1)
PY
}

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

# The early metadata check above normally makes this unreachable. Keep the
# same no-decision behavior here if a shell edge case reaches it after parsing;
# malformed context must not block an otherwise harmless command.
case "${HOME:?HOME must be set}" in
  /|*/|*'//'|*/./*|*/../*|*/.|*/..|*$'\n'*|*$'\r'*)
    exit 0
    ;;
  /*) ;;
  *)
    exit 0
    ;;
esac
CODEX_CONFIGURED_HOME="${HOME:?HOME must be set}/.codex"
export CODEX_CONFIGURED_HOME

canonical_approved_repo_roots() {
  local configured_codex configured_kimi allowed normalized
  configured_codex="${HOME:?HOME must be set}/.codex"
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
  # A worker may inspect only its declared current repository.  Approved
  # `-C` contexts remain a coordinator route and must not be re-admitted by
  # this legacy candidate after the worker Git capability parser defers them.
  [ "$hook_is_subagent" != true ] || return 1
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

# Shell spelling is diagnostic context, not a command permission boundary.
# Parse marker context before planning; later target-aware routes decide only
# concrete broad, destructive, cross-scope, or control-state effects.
mapfile -t syntax_eci_markers < <(active_eci_markers_for_cwd "$cwd" "$session_id")
ECI_ENVIRONMENT_BOUNDARY_CHECKED=false
ECI_ENVIRONMENT_COMMAND_STATE=""
ECI_ENVIRONMENT_COMMAND_CODE=""
ECI_ENVIRONMENT_COMMAND_SEGMENT=""
ECI_ENVIRONMENT_COMMAND_ARGV_INDEX=""
ECI_ENVIRONMENT_COMMAND_REASON=""

# `active_eci_markers_for_cwd` selects one concrete, valid marker. Scan
# failures and sibling records remain advisory rather than a generic
# marker-discovery denial for an ordinary command.

# Parse and classify every finite literal command plan once before the legacy
# single-command recognizers.  The classifier admits ordinary argv without an
# executable allowlist and defers only visibly protected capabilities to the
# established operation-specific gates below.
plan_role=coordinator
[ "$hook_is_subagent" != true ] || plan_role=worker
plan_marker_state=inactive
[ "${#syntax_eci_markers[@]}" -eq 0 ] || plan_marker_state=active

# Resolve concrete startup/module/path effects immediately after marker
# selection, before planner fast paths or read-only exits can bypass the
# check.  This is effect-based: ordinary and unresolved assignments remain
# transparent, while an existing interpreter script with an existing context
# path receives the narrow execution-context denial.
if [ "${#syntax_eci_markers[@]}" -gt 0 ]; then
  enforce_environment_script_target "$command"
fi

if lifecycle_mutation_target="$(lifecycle_mutation_different_target "$command" 2>/dev/null || true)"; then
  if [ -n "$lifecycle_mutation_target" ]; then
    deny_eci "ECI_LIFECYCLE_TARGET_DENIED" "eci-lifecycle" \
      "ECI lifecycle mutation has a different concrete executable target: target=$lifecycle_mutation_target" \
      "invoke the intended lifecycle executable for this provider, or inspect the reported copy before using a mutating verb"
  fi
fi

# A named temporary path is an ordinary resolved target.  Internal hook
# scratch selection may choose a private directory, but `/tmp`, `TMPDIR`, or
# a temp-looking argument is not an admission boundary by itself.  Concrete
# destructive or cross-scope targets remain checked by the normal routes.

# The planner is a helper for understanding a command, not an ordinary-work
# permission authority. Select it from the literal `$HOME/.codex` source and
# use publication metadata only to avoid silently running an older binary.
# Controlled `planner-check` remains the full maintenance attestation route;
# ordinary commands continue through the transparent fallback when metadata or
# source execution is unavailable.
CODEX_PLAN_PROVENANCE_DETAIL=""
CODEX_PLAN_PROVENANCE_FD=""
CODEX_PLAN_PROVENANCE_EXECUTABLE=""

codex_plan_provenance_fail() {
  CODEX_PLAN_PROVENANCE_DETAIL="$1"
  return 1
}

codex_plan_provenance_close_pinned_binary() {
  if [[ "${CODEX_PLAN_PROVENANCE_FD:-}" =~ ^[0-9]+$ ]]; then
    exec {CODEX_PLAN_PROVENANCE_FD}<&- 2>/dev/null || true
  fi
  CODEX_PLAN_PROVENANCE_FD=""
  CODEX_PLAN_PROVENANCE_EXECUTABLE=""
}

codex_plan_provenance_pin_binary() {
  local path="$1"
  local fd_path

  codex_plan_provenance_close_pinned_binary
  if ! exec {CODEX_PLAN_PROVENANCE_FD}<"$path"; then
    codex_plan_provenance_fail 'planner binary could not be opened for pinned validation'
    return 1
  fi
  fd_path="/proc/self/fd/$CODEX_PLAN_PROVENANCE_FD"
  # The canonical HOME-derived planner path was checked by the caller before
  # opening this descriptor.  Pinning the already-open regular executable is
  # enough to keep an atomic publication from swapping the bytes underneath
  # this callback; repeated owner/inode/hash probes here only turn advisory
  # metadata into a latency and access boundary.
  if [ ! -f "$path" ] || [ -L "$path" ] || [ ! -x "$path" ] ||
    [ ! -e "$fd_path" ]; then
    codex_plan_provenance_close_pinned_binary
    codex_plan_provenance_fail 'planner binary changed or became unsafe while it was being pinned for validation'
    return 1
  fi
  CODEX_PLAN_PROVENANCE_EXECUTABLE="/proc/self/fd/$CODEX_PLAN_PROVENANCE_FD"
  return 0
}

codex_plan_provenance_is_current() {
  local selected_root="${HOME:?HOME must be set}/.codex"
  local root_real planner_dir planner_dir_real binary receipt binary_mtime source_mtime
  local recorded_binary_sha actual_binary_sha
  local -a mtimes=() sources=()

  # Select the planner authority lexically from HOME.  Both registered
  # provider callbacks consume this canonical source, so a Kimi callback does
  # not turn its copied hook tree into a second planner authority.
  root_real="$(realpath -e -- "$selected_root" 2>/dev/null || true)"
  if [ ! -d "$selected_root" ] || [ -L "$selected_root" ] || [ -z "$root_real" ] ||
    [ "$root_real" != "$selected_root" ]; then
    codex_plan_provenance_fail 'the canonical $HOME/.codex planner authority is unavailable or unsafe'
    return 1
  fi

  planner_dir="$selected_root/hooks/lib/eci-command-plan-go"
  planner_dir_real="$(realpath -e -- "$planner_dir" 2>/dev/null || true)"
  if [ ! -d "$planner_dir" ] || [ -L "$planner_dir" ] ||
    [ "$planner_dir_real" != "$root_real/hooks/lib/eci-command-plan-go" ]; then
    codex_plan_provenance_fail 'the planner source directory is missing or unsafe below the literal $HOME/.codex authority'
    return 1
  fi

  binary="$planner_dir/eci-command-plan"
  sources=("$planner_dir/go.mod" "$planner_dir/go.sum" "$planner_dir"/*.go)
  for source in "${sources[@]}"; do
    [ -f "$source" ] && [ ! -L "$source" ] || {
      codex_plan_provenance_fail "planner source file is missing or unsafe: $source"
      return 1
    }
  done
  [ -f "$binary" ] && [ ! -L "$binary" ] && [ -x "$binary" ] || {
    codex_plan_provenance_fail 'planner binary is missing or not executable'
    return 1
  }

  # A producer receipt may identify the binary that was published with the
  # source snapshot.  Use that digest only to choose the current source when
  # the pathname now contains a different binary; it is never an ordinary
  # work permission check.  Missing or malformed receipt metadata remains
  # advisory and does not deny the callback.
  receipt="$planner_dir/.eci-command-plan.provenance"
  if [ -f "$receipt" ] && [ ! -L "$receipt" ]; then
    recorded_binary_sha="$(awk -F '\t' '$1 == "binary_sha256" { print $2; exit }' "$receipt" 2>/dev/null || true)"
    if [[ "$recorded_binary_sha" =~ ^[0-9a-f]{64}$ ]]; then
      actual_binary_sha="$(sha256sum -- "$binary" 2>/dev/null | awk '{print $1}' || true)"
      if [ "$actual_binary_sha" != "$recorded_binary_sha" ]; then
        codex_plan_provenance_fail 'planner binary provenance differs from the published receipt; selecting current source'
        return 1
      fi
    fi
  fi

  # Source freshness is a cheap advisory selector.  It keeps an older binary
  # from silently classifying a callback after a local source edit, while a
  # missing/malformed receipt never blocks ordinary work.
  if ! mapfile -t mtimes < <(/usr/bin/stat -c '%Y' -- "$binary" "${sources[@]}" 2>/dev/null); then
    codex_plan_provenance_fail 'planner freshness metadata is unavailable'
    return 1
  fi
  [ "${#mtimes[@]}" -eq "$(( ${#sources[@]} + 1 ))" ] || {
    codex_plan_provenance_fail 'planner freshness metadata is malformed'
    return 1
  }
  binary_mtime="${mtimes[0]}"
  [[ "$binary_mtime" =~ ^[0-9]+$ ]] || {
    codex_plan_provenance_fail 'planner binary freshness metadata is malformed'
    return 1
  }
  for source_mtime in "${mtimes[@]:1}"; do
    [[ "$source_mtime" =~ ^[0-9]+$ ]] || {
      codex_plan_provenance_fail 'planner source freshness metadata is malformed'
      return 1
    }
    if [ "$source_mtime" -gt "$binary_mtime" ]; then
      codex_plan_provenance_fail 'planner source is newer than the published binary; selecting current source'
      return 1
    fi
  done

  codex_plan_provenance_pin_binary "$binary" || return 1
  [ -x "$CODEX_PLAN_PROVENANCE_EXECUTABLE" ] || {
    codex_plan_provenance_close_pinned_binary
    codex_plan_provenance_fail 'pinned planner binary is not executable'
    return 1
  }

  return 0
}

# Planner publication state is a selector, not an admission boundary. A
# published binary whose mtime covers the current source is the fast path. If
# source is newer, the current Go source is selected so an old binary does not
# silently classify the callback. Missing or malformed receipts are ignored;
# they are maintenance evidence, not ordinary-work permission. If the source
# is mid-edit and cannot run, existing Bash/Python capability gates below
# provide the transparent fallback; no second command parser is introduced.
CODEX_PLAN_CURRENT_SOURCE=false
CODEX_PLAN_TRANSPARENT_FALLBACK=false
command_plan_binary="${HOME:?HOME must be set}/.codex/hooks/lib/eci-command-plan-go/eci-command-plan"
command_plan_source_dir="${HOME:?HOME must be set}/.codex/hooks/lib/eci-command-plan-go"
if codex_plan_provenance_is_current; then
  command_plan_executable="${CODEX_PLAN_PROVENANCE_EXECUTABLE:-$command_plan_binary}"
else
  codex_plan_provenance_close_pinned_binary
  CODEX_PLAN_CURRENT_SOURCE=true
  command_plan_executable=""
fi

plan_input="$(
  jq -cn \
    --arg provider codex \
    --arg role "$plan_role" \
    --arg cwd "$cwd" \
    --arg marker "$plan_marker_state" \
    --arg active_session "$session_id" \
    --arg command "$command" \
    --arg command_path "$CODEX_COMMAND_PATH" \
    --argjson command_path_set "$CODEX_COMMAND_PATH_SET" \
    --argjson command_path_exported "$CODEX_COMMAND_PATH_EXPORTED" \
    --arg cd_path "$CODEX_CD_PATH" \
    --argjson cd_path_set "$CODEX_CD_PATH_SET" \
    --argjson compound_segment_validation "$COMPOUND_SEGMENT_VALIDATION" \
    --arg segment_cwd "$COMPOUND_SEGMENT_CWD" \
    --argjson segment_cwd_known "$COMPOUND_SEGMENT_CWD_KNOWN" \
    --argjson segment_cwd_unknown "$COMPOUND_SEGMENT_CWD_UNKNOWN" \
    --argjson segment_cwd_candidates "$COMPOUND_SEGMENT_CWD_CANDIDATES" \
    --arg segment_cwd_physical "$COMPOUND_SEGMENT_CWD_PHYSICAL" \
    --argjson segment_cwd_physical_candidates "$COMPOUND_SEGMENT_CWD_PHYSICAL_CANDIDATES" \
    --argjson timeout_replay "$CODEX_TIMEOUT_REPLAY" \
    --argjson timeout_replays "$CODEX_TIMEOUT_REPLAYS" \
    --arg approved_root_1 "$CODEX_APPROVED_REPO_ROOT_1" \
    --arg approved_root_2 "$CODEX_APPROVED_REPO_ROOT_2" \
    --arg approved_root_3 "$CODEX_APPROVED_REPO_ROOT_3" \
    --args \
    '{provider:$provider,role:$role,cwd:$cwd,marker:$marker,active_session:$active_session,command:$command,command_path:$command_path,command_path_set:$command_path_set,command_path_exported:$command_path_exported,cd_path:$cd_path,cd_path_set:$cd_path_set,segment_cwd:(if $compound_segment_validation then $segment_cwd else null end),segment_cwd_known:(if $compound_segment_validation then $segment_cwd_known else null end),segment_cwd_unknown:(if $compound_segment_validation then $segment_cwd_unknown else null end),segment_cwd_candidates:(if $compound_segment_validation then $segment_cwd_candidates else null end),segment_cwd_physical:(if $compound_segment_validation then $segment_cwd_physical else null end),segment_cwd_physical_candidates:(if $compound_segment_validation then $segment_cwd_physical_candidates else null end),timeout_replay:$timeout_replay,timeout_replays:$timeout_replays,active_markers:$ARGS.positional,approved_roots:[$approved_root_1,$approved_root_2,$approved_root_3]|map(select(length > 0))}' \
    "${syntax_eci_markers[@]}"
)"

# Planner output is advisory metadata.  A failed, empty, or malformed
# classifier response cannot establish a harmful effect, so it must select the
# existing capability-aware fallback rather than become a new denial surface.
# Keep the status synchronized with the flag: later dispatch must not re-enter
# the status-2 denial branch after this helper has been selected.
planner_mark_transparent_fallback() {
  plan_status=3
  plan_output=""
  CODEX_PLAN_TRANSPARENT_FALLBACK=true
}

if [ "$CODEX_PLAN_CURRENT_SOURCE" = true ]; then
  current_go="$(command -v go 2>/dev/null || true)"
  plan_output=""
  if [ -n "$current_go" ] && [ -x "$current_go" ] &&
    [ -d "$command_plan_source_dir" ] && [ ! -L "$command_plan_source_dir" ]; then
    plan_output="$(
      printf '%s\n' "$plan_input" |
        (cd "$command_plan_source_dir" && "$current_go" run .) 2>/dev/null || true
    )"
  fi
  case "$(jq -r 'if type == "object" then (.decision // "") else "" end' <<<"${plan_output:-}" 2>/dev/null || true)" in
    allow) plan_status=0 ;;
    deny) plan_status=2 ;;
    defer) plan_status=3 ;;
    *)
      planner_mark_transparent_fallback
      ;;
  esac
else
  if plan_output="$(printf '%s\n' "$plan_input" | "$command_plan_executable" 2>/dev/null)"; then
    plan_status=0
  else
    plan_status=$?
  fi
fi
codex_plan_provenance_close_pinned_binary

# The planner is an optional classifier, not a prerequisite for ordinary
# command execution. A malformed, stale, or incomplete response cannot name a
# concrete harmful target, so preserve only usable decisions and let the
# target-aware routes below inspect everything else.
planner_response_matches_status() {
  local status="${1:-}" result="${2:-}"

  case "$status" in
    0)
      jq -e '
        type == "object" and
        .decision == "allow" and
        (.diagnostic == null)
      ' <<<"$result" >/dev/null 2>&1
      ;;
    2)
      command_plan_pretooluse_denial "$result" >/dev/null
      ;;
    3)
      jq -e '
        type == "object" and
        .decision == "defer" and
        (.diagnostic == null)
      ' <<<"$result" >/dev/null 2>&1
      ;;
    *) return 1 ;;
  esac
}

if [ "$CODEX_PLAN_TRANSPARENT_FALLBACK" != true ] &&
  ! planner_response_matches_status "$plan_status" "$plan_output"; then
  planner_mark_transparent_fallback
fi

# The optional shell projection carries argv/context separately from the raw,
# lossless plan. Inert heredoc bytes must never be fed back into shlex by an
# effect reader. Missing analysis remains advisory, as with the ordinary plan.
PLAN_SHELL_ANALYSIS=null
PLAN_SHELL_ANALYSIS_COMMAND="$command"
if jq -e '
    .shell_analysis | type == "object" and
    (.commands | type == "array" and all(.[];
      (.argv | type == "array" and all(.[]; type == "string")) and
      ((.argv | length) as $argc | (.unknown_arguments // []) |
        type == "array" and all(.[];
          type == "number" and . == floor and . >= 0 and . < $argc)) and
      ((.argv | length) as $argc |
        [.may_disappear_arguments, .may_multiply_arguments, .unknown_cardinality_arguments] |
        all(.[]; (. // []) | type == "array" and all(.[];
          type == "number" and . == floor and . >= 0 and . < $argc))) and
      (.cwd | type == "string") and (.cwd_known | type == "boolean") and
      (.cwd_candidates | type == "array" and all(.[]; type == "string")) and
      (.reachability == "reachable" or .reachability == "unknown" or .reachability == "unreachable") and
      (.segment | type == "number")))
  ' <<<"${plan_output:-}" >/dev/null 2>&1; then
  PLAN_SHELL_ANALYSIS="$(jq -c '.shell_analysis' <<<"$plan_output")"
fi

planner_shell_analysis_for() {
  if [ "$1" = "$PLAN_SHELL_ANALYSIS_COMMAND" ]; then
    printf '%s\n' "$PLAN_SHELL_ANALYSIS"
  else
    printf 'null\n'
  fi
}

# A current planner result normally selects the lifecycle adapter. During a
# source-build gap the adapter itself remains the existing bounded parser, so
# it may resolve a lifecycle target without consulting stale code.
PLAN_CODEX_LIFECYCLE_ROUTE=false
if [ "$CODEX_PLAN_TRANSPARENT_FALLBACK" = true ]; then
  PLAN_CODEX_LIFECYCLE_ROUTE=true
elif [ "$plan_status" -eq 3 ] && jq -e '
  type == "object" and
  .decision == "defer" and
  .deferred_route == "codex-lifecycle" and
  (.diagnostic == null)
' <<<"${plan_output:-}" >/dev/null 2>&1; then
  PLAN_CODEX_LIFECYCLE_ROUTE=true
fi

# The reviewed trace diagnostic is the sole punctuation-bearing planner route.
# Validate its complete typed topology and byte-for-byte reconstruction before
# the existing reviewed-script adapter is allowed to inspect the raw command.
# No generic redirect or pipeline reaches that adapter through this predicate.
planner_reviewed_script_trace_topology_is_valid() {
  [ "${plan_status:-64}" -eq 3 ] || return 1
  jq -e --arg command "$command" '
    def exact_keys($expected): (keys | sort) == $expected;
    type == "object" and
    (.decision == "defer") and
    (.deferred_route == "reviewed-script-trace") and
    (.diagnostic == null) and
    ((.capabilities // []) | type == "array" and length == 0) and
    (.plan | type == "object" and exact_keys(["trace"])) and
    (.plan.trace | type == "object" and
      exact_keys(["command", "lines", "operator", "redirect", "script", "shell", "shell_flag", "sink", "sink_flag"]) and
      .command == $command and
      (.shell == "bash" or .shell == "sh") and
      .shell_flag == "-x" and
      (.script | type == "string") and
      (.script | test("^[A-Za-z0-9._/-]+\\.sh$") and (contains("..") | not)) and
      .redirect == "2>&1" and
      .operator == "|" and
      .sink == "tail" and
      .sink_flag == "-n" and
      (.lines | type == "string" and test("^(?:[1-9]|[1-9][0-9]|1[0-9]{2}|200)$")) and
      .command == (.shell + " " + .shell_flag + " " + .script + " " + .redirect + " " + .operator + " " + .sink + " " + .sink_flag + " " + .lines)
    )
  ' <<<"${plan_output:-}" >/dev/null 2>&1
}

PLAN_REVIEWED_SCRIPT_TRACE_ROUTE=false
if [ "$hook_is_subagent" != true ] && [ "${#syntax_eci_markers[@]}" -gt 0 ] &&
  planner_reviewed_script_trace_topology_is_valid; then
  PLAN_REVIEWED_SCRIPT_TRACE_ROUTE=true
fi

planner_approved_pipeline_candidate() {
  [ "${plan_status:-64}" -eq 0 ] || return 1
  jq -e '
    type == "object" and
    .decision == "allow" and
    (.diagnostic == null)
  ' <<<"${plan_output:-}" >/dev/null 2>&1
}

# planner_git_clone_source_acquisition_shape accepts only the typed planner
# capability and launcher metadata for an otherwise opaque Git clone argv.
# Git owns clone option parsing; this adapter binds only the attested literal
# executables and inherited-environment boundary.
planner_git_clone_source_acquisition_shape() {
  [ "${plan_status:-64}" -eq 0 ] || return 1
  jq -e '
    def exact_keys($expected): (keys | sort) == $expected;
    def nonnegative_integer: type == "number" and floor == . and . >= 0;
    def direct_or_command_launch:
      if type != "object" then false else
        exact_keys(["class", "environment_preserved", "git_argv_index", "git_executable"]) and
        (.class == "direct" or .class == "command") and
        (.git_argv_index | nonnegative_integer) and
        (.git_executable | type == "string" and length > 0) and
        .environment_preserved == true
      end;
    def env_launch:
      if type != "object" then false else
        exact_keys(["class", "env_argv_index", "env_executable", "environment_preserved", "git_argv_index", "git_executable"]) and
        .class == "env" and
        (.env_argv_index | nonnegative_integer) and
        (.env_executable | type == "string" and length > 0) and
        (.git_argv_index | nonnegative_integer) and
        (.git_executable | type == "string" and length > 0) and
        .environment_preserved == true
      end;
    type == "object" and
    .decision == "allow" and
    (.diagnostic == null) and
    ((.deferred_route // "") == "") and
    (.capabilities == ["git-clone-source-acquisition"]) and
    ((.git_clone_launch | direct_or_command_launch) or
      (.git_clone_launch | env_launch))
  ' <<<"${plan_output:-}" >/dev/null 2>&1
}

PLAN_GIT_CLONE_SOURCE_ACQUISITION=false
PLAN_GIT_CLONE_LAUNCH_CLASS=''
PLAN_GIT_CLONE_GIT_EXECUTABLE=''
PLAN_GIT_CLONE_ENV_EXECUTABLE=''
if [ "${#syntax_eci_markers[@]}" -gt 0 ] &&
  planner_git_clone_source_acquisition_shape; then
  PLAN_GIT_CLONE_SOURCE_ACQUISITION=true
  PLAN_GIT_CLONE_LAUNCH_CLASS="$(jq -r '.git_clone_launch.class' <<<"${plan_output:-}")"
  PLAN_GIT_CLONE_GIT_EXECUTABLE="$(jq -r '.git_clone_launch.git_executable' <<<"${plan_output:-}")"
  PLAN_GIT_CLONE_ENV_EXECUTABLE="$(jq -r '.git_clone_launch.env_executable // ""' <<<"${plan_output:-}")"
fi
# planner_timeout_replays_shape accepts complete planner-owned timeout state.
# Bash uses an observed replay only as a coordinate for existing Git target
# resolution; it never reconstructs timeout option or signal behavior.
planner_timeout_replays_shape() {
  [ "${plan_status:-64}" -eq 0 ] || [ "${plan_status:-64}" -eq 3 ] || return 1
  jq -e '
    def exact_keys($expected): (keys | sort) == $expected;
    def positive_integer: type == "number" and floor == . and . >= 1 and . <= 8;
    def bounded_string: type == "string" and length > 0 and length <= 4096;
    def replay_fact:
      type == "object" and
      ((keys | sort) == ["command_path", "command_path_exported", "command_path_set", "cwd", "disposition", "parent_segment", "prefix", "segment"] or
       (keys | sort) == ["command_path", "command_path_exported", "command_path_set", "cwd", "cwd_physical", "disposition", "parent_segment", "prefix", "segment"]) and
      (.segment | positive_integer) and
      (.parent_segment | positive_integer) and
      (.prefix | type == "array" and length >= 2 and length <= 128 and all(.[]; bounded_string)) and
      (.cwd | type == "string" and test("^/")) and
      (.cwd_physical? // "" | type == "string" and (length == 0 or test("^/"))) and
      (.command_path | type == "string") and
      (.command_path_set | type == "boolean") and
      (.command_path_exported | type == "boolean") and
      (.disposition == "observed" or .disposition == "opaque") and
      (if .command_path_set then true else (.command_path == "" and .command_path_exported == false) end);
    type == "object" and
    (.decision == "allow" or .decision == "defer") and
    (.diagnostic == null) and
    ((.timeout_replays // []) | type == "array" and all(.[]; replay_fact))
  ' <<<"${plan_output:-}" >/dev/null 2>&1
}

PLAN_TIMEOUT_REPLAYS='[]'
if [ "${#syntax_eci_markers[@]}" -gt 0 ] && planner_timeout_replays_shape; then
  PLAN_TIMEOUT_REPLAYS="$(jq -c '.timeout_replays // []' <<<"${plan_output:-}")"
fi

# The regression harness may request one bounded, pre-created trace file to
# compare the planner's actual FD9 child handoff with an explicit replay. This
# is diagnostics only: absent that test-only opt-in, the hook never writes a
# replay artifact.
eci_test_timeout_replay_trace() {
  local trace_file="${ECI_TEST_REPLAY_TRACE_FILE:-}"
  [ -n "$trace_file" ] && [ -f "$trace_file" ] && [ ! -L "$trace_file" ] || return 0
  jq -c --arg command "$command" --arg outer_cwd "$cwd" \
    --arg command_path "$CODEX_COMMAND_PATH" \
    --argjson command_path_set "$CODEX_COMMAND_PATH_SET" \
    --argjson command_path_exported "$CODEX_COMMAND_PATH_EXPORTED" \
    --arg compound_cwd "$COMPOUND_SEGMENT_CWD" \
    --argjson compound_segment "$COMPOUND_SEGMENT_VALIDATION" \
    --argjson compound_known "$COMPOUND_SEGMENT_CWD_KNOWN" \
    --argjson compound_unknown "$COMPOUND_SEGMENT_CWD_UNKNOWN" \
    --argjson compound_candidates "$COMPOUND_SEGMENT_CWD_CANDIDATES" \
    --arg compound_physical "$COMPOUND_SEGMENT_CWD_PHYSICAL" \
    --argjson compound_physical_candidates "$COMPOUND_SEGMENT_CWD_PHYSICAL_CANDIDATES" \
    --arg compound_reachability "$COMPOUND_SEGMENT_REACHABILITY" \
    '{compound_segment_validation:$compound_segment,command:$command,outer_cwd:$outer_cwd,decision:(.decision // ""),timeout_replays:((.timeout_replays // []) | map({cwd,cwd_physical,prefix,disposition,segment,parent_segment,command_path,command_path_set,command_path_exported})),effective_cwd:((.timeout_replays // [])[0].cwd // $compound_cwd),effective_cwd_physical:((.timeout_replays // [])[0].cwd_physical // $compound_physical),cwd_candidates:$compound_candidates,cwd_physical_candidates:$compound_physical_candidates,cwd_unknown:$compound_unknown,reachability:$compound_reachability,command_path:$command_path,command_path_set:$command_path_set,command_path_exported:$command_path_exported}' \
    <<<"${plan_output:-}" >>"$trace_file" 2>/dev/null || true
}
eci_test_timeout_replay_trace

# planner_current_ledger_append_shape accepts the planner's concrete resolved
# append result without reconstructing a shell redirect grammar in Bash.
planner_current_ledger_append_shape() {
  [ "${plan_status:-64}" -eq 0 ] || return 1
  jq -e '
    type == "object" and
    .decision == "allow" and
    (.diagnostic == null) and
    ((.capabilities // []) | type == "array" and length == 0) and
    ((.deferred_route // "") == "") and
    (.git_clone_launch == null) and
    .ledger_redirect_append == true
  ' <<<"${plan_output:-}" >/dev/null 2>&1
}

PLAN_CURRENT_LEDGER_APPEND=false
if [ "${#syntax_eci_markers[@]}" -gt 0 ] && planner_current_ledger_append_shape; then
  PLAN_CURRENT_LEDGER_APPEND=true
fi

# planner_compound_topology_is_valid accepts only the lossless topology emitted
# by the compiled planner and only when it reconstructs the original command
# byte for byte. Shell punctuation is therefore not a Bash admission boundary:
# it is planner-owned topology that selects repeated direct-route validation.
planner_compound_topology_is_valid() {
  case "${plan_status:-64}" in
    0|3) ;;
    *) return 1 ;;
  esac
  jq -e --arg command "$command" '
    def exact_keys($expected): (keys | sort) == $expected;
    def valid_segment:
      . as $segment |
      ($segment | type == "object") and
      ($segment | exact_keys(["command", "cwd", "cwd_candidates", "cwd_known", "cwd_physical", "cwd_physical_candidates", "cwd_unknown", "git_worktree_effect", "reachability"])) and
      ($segment.command | type == "string") and
      ($segment.command | length > 0) and
      ($segment.cwd | type == "string") and
      ($segment.cwd_candidates | type == "array" and length <= 128 and
        all(.[]; type == "string" and test("^/") and length <= 4096)) and
      ($segment.cwd_physical | type == "string") and
      ($segment.cwd_physical_candidates | type == "array" and length <= 128 and
        all(.[]; type == "string" and test("^/") and length <= 4096)) and
      ($segment.cwd_known | type == "boolean") and
      ($segment.cwd_unknown | type == "boolean") and
      ($segment.git_worktree_effect | type == "string" and
        (. == "" or . == "worktree-mutation")) and
      ($segment.reachability | type == "string" and
        (. == "reachable" or . == "unreachable" or . == "unknown")) and
      (if $segment.cwd_known then
        ($segment.cwd_unknown == false) and
        ($segment.cwd | test("^/")) and
        ($segment.cwd_candidates | index($segment.cwd) != null)
       else $segment.cwd == "" end) and
      (if $segment.cwd_known then
        ($segment.cwd_physical != "") and
        ($segment.cwd_physical_candidates | index($segment.cwd_physical) != null)
       else $segment.cwd_physical == "" end);
    def valid_operator:
      type == "string" and
      (. == "&&" or . == "||" or . == ";" or . == "|" or . == "\n");
    type == "object" and
    (.plan | type == "object") and
    (.plan | exact_keys(["operators", "segments"])) and
    (.plan.segments | type == "array" and length >= 2 and length <= 8 and all(.[]; valid_segment)) and
    (.plan.operators | type == "array" and all(.[]; valid_operator)) and
    ((.plan.segments | length) == ((.plan.operators | length) + 1)) and
    (
      .plan.segments as $segments |
      .plan.operators as $operators |
      (reduce range(0; ($segments | length)) as $index
        (""; . + $segments[$index].command +
          (if $index < ($operators | length) then $operators[$index] else "" end))) == $command
    )
  ' <<<"${plan_output:-}" >/dev/null 2>&1
}

# A pipeline is selected only from the planner's lossless operator topology.
# A literal `|` in quoted data is not a pipeline, and absent topology leaves
# ordinary work to the concrete-effect fallback below.
planner_compound_pipeline_topology_is_valid() {
  planner_compound_topology_is_valid || return 1
  jq -e '
    (.plan.operators | index("|")) != null
  ' <<<"${plan_output:-}" >/dev/null 2>&1
}

# A planner-approved compound containing a visible Git worktree verb must
# still reach the concrete-effect resolver below.  Do not let the compound
# fast path hide a later `git rm`, `git mv`, `git restore`, or path-form
# `git checkout` behind an `if`, redirection, or ordinary wrapper.  This is a
# routing hint only: the effect resolver remains the sole source of a denial,
# and false positives merely take the slower transparent path.
planner_compound_git_worktree_candidate() {
  planner_compound_topology_is_valid || return 1
  jq -e '
    any(.plan.segments[]?;
      .reachability != "unreachable" and .git_worktree_effect == "worktree-mutation")
  ' <<<"${plan_output:-}" >/dev/null 2>&1
}

# A typed compound script route owns the original command as one reviewed
# script topology. It deliberately reuses the parser's byte-for-byte compound
# reconstruction instead of replaying individual safe-looking segments.
planner_reviewed_script_compound_topology_is_valid() {
  planner_compound_topology_is_valid || return 1
  jq -e '
    type == "object" and
    .decision == "defer" and
    .deferred_route == "reviewed-script-compound" and
    (.diagnostic == null) and
    ((.capabilities // []) | type == "array" and length == 0)
  ' <<<"${plan_output:-}" >/dev/null 2>&1
}

PLAN_REVIEWED_SCRIPT_COMPOUND_ROUTE=false
if [ "$hook_is_subagent" != true ] && [ "${#syntax_eci_markers[@]}" -gt 0 ] &&
  [ "${plan_role:-}" = coordinator ] && planner_reviewed_script_compound_topology_is_valid; then
  PLAN_REVIEWED_SCRIPT_COMPOUND_ROUTE=true
fi

# compound_segment_pretooluse_denial validates one recursive direct-route
# response before it can become this hook's sole provider envelope.
compound_segment_pretooluse_denial() {
  local segment_output="${1:-}"
  printf '%s' "$segment_output" | jq -cser '
    def valid_denial:
      type == "object" and
      (keys | sort) == ["hookSpecificOutput"] and
      (.hookSpecificOutput | type == "object") and
      ((.hookSpecificOutput | keys | sort) == [
        "hookEventName",
        "permissionDecision",
        "permissionDecisionReason"
      ]) and
      .hookSpecificOutput.hookEventName == "PreToolUse" and
      .hookSpecificOutput.permissionDecision == "deny" and
      (.hookSpecificOutput.permissionDecisionReason | type == "string") and
      (.hookSpecificOutput.permissionDecisionReason | length > 0);
    if length == 1 and (.[0] | valid_denial) then .[0]
    else error("invalid direct-route PreToolUse denial")
    end
  ' 2>/dev/null
}

# validate_planner_compound_segments replays every planner-owned segment
# through this same hook as one direct callback. The CWD fact is copied from
# the validated planner topology into the child JSON; no inherited environment
# variable can alter segment resolution.
#
# Example: `printf ok; rm -f target` cannot inherit printf's allow: rm receives
# the same named cleanup route it would receive by itself. The recursive hook
# validates only JSON; it never executes a user command.
PLANNER_COMPOUND_SEGMENT_DENIAL=""
new_compound_handoff_token() {
  local token
  token="$(/usr/bin/od -An -N24 -tx1 /dev/urandom 2>/dev/null | /usr/bin/tr -d '[:space:]' || true)"
  if [[ "$token" =~ ^[[:xdigit:]]{48}$ ]]; then
    printf '%s\n' "$token"
    return 0
  fi
  token="$(printf '%s:%s:%s:%s' "$$" "$BASHPID" "${EPOCHREALTIME:-}" "${RANDOM:-}" |
    /usr/bin/sha256sum 2>/dev/null | /usr/bin/awk '{print $1}' || true)"
  [[ "$token" =~ ^[[:xdigit:]]{64}$ ]] || return 1
  printf '%s\n' "$token"
}

validate_planner_compound_segments() {
  local segment child_input child_output child_denial child_status self_hook parent_segment replay_records handoff_token
  local segment_cwd segment_cwd_known segment_cwd_unknown segment_cwd_candidates segment_cwd_physical segment_cwd_physical_candidates segment_reachability segment_index
  local -a segments=() segment_cwds=() segment_cwd_knowns=() segment_cwd_unknowns=() segment_cwd_candidates=() segment_cwd_physicals=() segment_cwd_physical_candidates=() segment_reachabilities=()
  PLANNER_COMPOUND_SEGMENT_DENIAL=""
  self_hook="${BASH_SOURCE[0]}"
  if ! handoff_token="$(new_compound_handoff_token)" || [ -z "$handoff_token" ]; then
    return 2
  fi
  mapfile -t segments < <(jq -r '.plan.segments[].command' <<<"${plan_output:-}")
  mapfile -t segment_cwds < <(jq -r '.plan.segments[].cwd' <<<"${plan_output:-}")
  mapfile -t segment_cwd_knowns < <(jq -r '.plan.segments[].cwd_known' <<<"${plan_output:-}")
  mapfile -t segment_cwd_unknowns < <(jq -r '.plan.segments[].cwd_unknown' <<<"${plan_output:-}")
  mapfile -t segment_cwd_candidates < <(jq -c '.plan.segments[].cwd_candidates' <<<"${plan_output:-}")
  mapfile -t segment_cwd_physicals < <(jq -r '.plan.segments[].cwd_physical' <<<"${plan_output:-}")
  mapfile -t segment_cwd_physical_candidates < <(jq -c '.plan.segments[].cwd_physical_candidates' <<<"${plan_output:-}")
  mapfile -t segment_reachabilities < <(jq -r '.plan.segments[].reachability' <<<"${plan_output:-}")
  [ "${#segments[@]}" -ge 2 ] || return 2
  [ "${#segment_cwds[@]}" -eq "${#segments[@]}" ] || return 2
  [ "${#segment_cwd_knowns[@]}" -eq "${#segments[@]}" ] || return 2
  [ "${#segment_cwd_unknowns[@]}" -eq "${#segments[@]}" ] || return 2
  [ "${#segment_cwd_candidates[@]}" -eq "${#segments[@]}" ] || return 2
  [ "${#segment_cwd_physicals[@]}" -eq "${#segments[@]}" ] || return 2
  [ "${#segment_cwd_physical_candidates[@]}" -eq "${#segments[@]}" ] || return 2
  [ "${#segment_reachabilities[@]}" -eq "${#segments[@]}" ] || return 2
  for segment_index in "${!segments[@]}"; do
    parent_segment="$segment_index"
    segment="${segments[segment_index]}"
    # The planner preserves the separator whitespace around a compound
    # segment.  It is not part of the segment's argv, and leaving it on the
    # replay command can bypass a target-aware route such as `rm`.  Remove
    # only shell whitespace at the outer edges; preserve every interior byte
    # and therefore the command's parsed meaning.
    segment="${segment#"${segment%%[!$' \t\r\n']*}"}"
    segment="${segment%"${segment##*[!$' \t\r\n']}"}"
    parent_segment=$((parent_segment + 1))
    if ! replay_records="$(jq -c --argjson parent_segment "$parent_segment" '
      if type == "array" then
        [.[] |
          select(type == "object") |
          select(.segment == $parent_segment and .parent_segment == $parent_segment) |
          .segment = 1]
      else
        []
      end
    ' <<<"${PLAN_TIMEOUT_REPLAYS:-[]}" 2>/dev/null)"; then
      return 2
    fi
    segment_cwd="${segment_cwds[segment_index]}"
    segment_cwd_known="${segment_cwd_knowns[segment_index]}"
    segment_cwd_unknown="${segment_cwd_unknowns[segment_index]}"
    segment_cwd_candidates="${segment_cwd_candidates[segment_index]}"
    segment_cwd_physical="${segment_cwd_physicals[segment_index]}"
    segment_cwd_physical_candidates="${segment_cwd_physical_candidates[segment_index]}"
    segment_reachability="${segment_reachabilities[segment_index]}"
    case "$segment_reachability" in
      reachable|unknown) ;;
      unreachable) continue ;;
      *) return 2 ;;
    esac
    if ! child_input="$(printf '%s' "$input" | jq -c \
      --arg command "$segment" \
      --arg segment_cwd "$segment_cwd" \
      --argjson segment_cwd_known "$segment_cwd_known" \
      --argjson segment_cwd_unknown "$segment_cwd_unknown" \
      --argjson segment_cwd_candidates "$segment_cwd_candidates" \
      --arg segment_cwd_physical "$segment_cwd_physical" \
      --argjson segment_cwd_physical_candidates "$segment_cwd_physical_candidates" \
      --arg segment_reachability "$segment_reachability" \
      --arg command_path "$CODEX_COMMAND_PATH" \
      --argjson command_path_set "$CODEX_COMMAND_PATH_SET" \
      --argjson command_path_exported "$CODEX_COMMAND_PATH_EXPORTED" \
      --arg handoff_token "$handoff_token" \
      --argjson replay_records "$replay_records" '
      .tool_input.command = $command |
      .timeout_replay = true |
      .timeout_replays = $replay_records |
      .eci_compound_segment = {
        validation: true,
        cwd: $segment_cwd,
        cwd_known: $segment_cwd_known,
        cwd_unknown: $segment_cwd_unknown,
        cwd_candidates: $segment_cwd_candidates,
        cwd_physical: $segment_cwd_physical,
        cwd_physical_candidates: $segment_cwd_physical_candidates,
        reachability: $segment_reachability,
        command_path: $command_path,
        command_path_set: $command_path_set,
        command_path_exported: $command_path_exported,
        handoff_token: $handoff_token
      }
    ' 2>/dev/null)"; then
      return 2
    fi
    if child_output="$(
      env -u BASH_ENV -u ENV -u CDPATH \
        -u ECI_COMPOUND_COMMAND_PATH -u ECI_COMPOUND_CWD -u ECI_COMPOUND_SEGMENT_VALIDATION \
        bash "$self_hook" 9<<<"$handoff_token" <<<"$child_input" 2>/dev/null
    )"; then
      child_status=0
    else
      child_status=$?
    fi
    [ "$child_status" -eq 0 ] || return 2
    if [ -z "$child_output" ]; then
      # A direct cleanup segment may be valid JSON and still have no
      # user-facing response when its destination is outside the bounded
      # cleanup route.  Re-check that concrete effect here; otherwise the
      # parent's successful first inspection would hide the rejected cleanup
      # segment.  Workers do not own this coordinator-only cleanup capability.
      if [ "$hook_is_subagent" != true ] &&
        eci_cleanup_command_shape "$segment" &&
        ! eci_shared_cleanup_route "$segment" false; then
        deny_eci "ECI_COMPOUND_MUTATION_DENIED" "compound-mutation" \
          "ECI coordinator compound mutation denied: ${ECI_SHARED_CLEANUP_ROUTE_DETAIL:-command=$(eci_command_identity_subject "$segment")}; predicate=compound-mutation; reason=the mutation segment is not admitted by the bounded ownership route" \
          "split the read-only inspection from the mutation, or use the bounded coordinator cleanup route for the exact generated target"
      fi
      continue
    fi
    if ! child_denial="$(compound_segment_pretooluse_denial "$child_output")"; then
      return 2
    fi
    PLANNER_COMPOUND_SEGMENT_DENIAL="$child_denial"
    return 1
  done
  return 0
}

eci_cleanup_command_shape() {
  case "${1:-}" in
    mv|mv\ *|rm|rm\ *) return 0 ;;
    *) return 1 ;;
  esac
}

# A compound that contains a source/cleanup mutation must not inherit the
# allow decision of an earlier read-only segment. This is a capability shape
# check; read-only compounds remain on the planner fast path.
coordinator_compound_mutation_shape() {
  [ "${plan_role:-coordinator}" != worker ] || return 1
  [ "${plan_marker_state:-inactive}" = active ] || return 1
  case "${1:-}" in
    *'&&'*|*'||'*) ;;
    *) return 1 ;;
  esac
  # The common unquoted direct-argv form can be classified without starting
  # another interpreter. Quoted/env/path-qualified forms fall through to the
  # language-neutral parser below, so this is only a latency fast path for the
  # same capability grammar, not a policy exception.
  case "$1" in
    *"'"*|*'"'*|*'\\'*|*'$'*|*'`'*) ;;
    *'&& rm '*|*'&& rm'|*'|| rm '*|*'|| rm'|\
    *'&& mv '*|*'&& mv'|*'|| mv '*|*'|| mv'|\
    *'&& touch '*|*'&& touch'|*'|| touch '*|*'|| touch'|\
    *'&& chmod '*|*'&& chmod'|*'|| chmod '*|*'|| chmod'|\
    *'&& sed -i '*|*'&& sed -i'|*'|| sed -i '*|*'|| sed -i'*) return 0 ;;
  esac
  python3 - "$1" <<'PY'
import os
import re
import shlex
import sys

try:
    lexer = shlex.shlex(sys.argv[1], posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    tokens = list(lexer)
except ValueError:
    raise SystemExit(1)
if not tokens:
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

source_writers = {
    "chmod", "chown", "cp", "dd", "install", "ln", "mkdir", "mv", "patch",
    "rm", "rmdir", "rsync", "shred", "srm", "tee", "touch", "truncate", "unlink",
}
git_mutations = {
    "add", "apply", "branch", "checkout", "clean", "commit", "merge", "mv", "pull",
    "push", "rebase", "remote", "reset", "restore", "rm", "stash", "switch", "tag",
    "worktree",
}

def executable_and_args(part):
    index = 0
    if part and part[0] == "env":
        index = 1
        while index < len(part):
            token = part[index]
            if token == "--":
                index += 1
                break
            if token in {"-i", "--ignore-environment"}:
                index += 1
                continue
            if token in {"-u", "--unset"}:
                index += 2
                continue
            if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=.*", token):
                index += 1
                continue
            break
    return (part[index], part[index + 1:]) if index < len(part) else ("", [])

for part in parts:
    executable, args = executable_and_args(part)
    name = os.path.basename(executable)
    if name in source_writers:
        raise SystemExit(0)
    if name == "sed" and any(
        value == "-i" or value == "--in-place" or value.startswith("-i") or
        value.startswith("--in-place=") for value in args
    ):
        raise SystemExit(0)
    if name == "git":
        subcommand = ""
        for value in args:
            if value == "--":
                break
            if value.startswith("-"):
                continue
            subcommand = value
            break
        if subcommand in git_mutations:
            raise SystemExit(0)
raise SystemExit(1)
PY
}

# Coordinator behavior routes implementation to an implementer; this command
# gate does not turn an ordinary source mutation into a role-only denial just
# because it appears after &&, ||, or a pipeline segment. Concrete target
# checks below remain authoritative.
coordinator_compound_mutation=false

COORDINATOR_COMPOUND_FAST_APPLICABLE=false
COORDINATOR_CLEANUP_ROUTE_DETAIL=""
coordinator_shared_cleanup_route() {
  local allow_private_session_child="${2:-false}"
  case "$allow_private_session_child" in
    true|false) ;;
    *) return 1 ;;
  esac
  if eci_shared_cleanup_route "$1" "$allow_private_session_child"; then
    COORDINATOR_CLEANUP_ROUTE_DETAIL=""
    return 0
  fi
  COORDINATOR_CLEANUP_ROUTE_DETAIL="${ECI_SHARED_CLEANUP_ROUTE_DETAIL:-coordinator-cleanup-route reason=command is outside the bounded cleanup grammar}"
  return 1
}

coordinator_compound_fast_route() {
  COORDINATOR_COMPOUND_FAST_APPLICABLE=false
  [ "$hook_is_subagent" != true ] || return 1
  case "$1" in
    *"'"*|*'"'*|*'\\'*|*'$'*|*'`'*|*';'*|*'|'*|*'<'*|*'>'*) return 1 ;;
    *'&&'*'&&'*|*'||'*'||'*) return 1 ;;
    *'&&'*|*'||'*) ;;
    *) return 1 ;;
  esac
  local left right target allow_private_session_child=false
  if [[ "$1" == *'&&'* ]]; then
    left="${1%%&&*}"
    right="${1#*&&}"
  else
    left="${1%%||*}"
    right="${1#*||}"
  fi
  left="${left#"${left%%[![:space:]]*}"}"
  left="${left%"${left##*[![:space:]]}"}"
  right="${right#"${right%%[![:space:]]*}"}"
  right="${right%"${right##*[![:space:]]}"}"
  COORDINATOR_COMPOUND_FAST_APPLICABLE=true
  case "$left" in
    realpath|realpath\ *|readlink|readlink\ *|stat|stat\ *|rg|rg\ *|grep|grep\ *) ;;
    *)
      COORDINATOR_COMPOUND_FAST_APPLICABLE=false
      COORDINATOR_CLEANUP_ROUTE_DETAIL="coordinator-cleanup-route command=$right reason=left compound segment is not a bounded read-only inspection"
      return 1
      ;;
  esac
  case "$right" in
    "rm -f -- "* ) target="${right#rm -f -- }" ;;
    "rm -f "* ) target="${right#rm -f }" ;;
    touch|"touch "* )
      COORDINATOR_CLEANUP_ROUTE_DETAIL="coordinator-cleanup-route command=$right reason=mutation segment is not an ownership-approved cleanup operation"
      # `touch` is an ordinary non-destructive writer. Leave it for the
      # segment target checks below instead of turning this fast-path miss
      # into a generic compound denial.
      COORDINATOR_COMPOUND_FAST_APPLICABLE=false
      return 1
      ;;
    *)
      COORDINATOR_COMPOUND_FAST_APPLICABLE=false
      COORDINATOR_CLEANUP_ROUTE_DETAIL="coordinator-cleanup-route command=$right reason=mutation segment is not the bounded rm -f cleanup form"
      return 1
      ;;
  esac
  case "$target" in
    /*) ;;
    *)
      COORDINATOR_CLEANUP_ROUTE_DETAIL="coordinator-cleanup-route command=$right reason=temporary cleanup requires one absolute literal target"
      return 1
      ;;
  esac
  case "$target" in
    *' '*|*'	'*|*'/'../'*|*'/..'|*'/'./'*|*'/.'|*'*'*|*'?'*|*'['*|*']'*)
      COORDINATOR_COMPOUND_FAST_APPLICABLE=false
      COORDINATOR_CLEANUP_ROUTE_DETAIL="coordinator-cleanup-route command=$right reason=temporary cleanup target is not a normalized literal path"
      return 1
      ;;
  esac
  coordinator_shared_cleanup_route "$right" "$allow_private_session_child"
}

ECI_MARKER_VALIDATION_COMPLETE=false
ECI_AGGREGATE_SESSION=false
ECI_AGGREGATE_REPO_ID=""
ECI_AGGREGATE_REPO_ROOT=""

# An aggregate recovery session retains one parent marker at a non-Git cwd.
# A callback inside a declared sibling therefore cannot pass the normal
# marker-cwd equality check. Resolve that exception only from the immutable,
# marker-bound plan; no callback path is ever used as a repository selector.
aggregate_marker_context_for_callback() {
  local marker="$1" marker_dir plan marker_outer_raw marker_outer

  marker_dir="${marker%/*}"
  plan="$marker_dir/eci-aggregate-plan.json"
  if [ ! -e "$plan" ] && [ ! -L "$plan" ]; then
    return 1
  fi
  [ -f "$plan" ] && [ ! -L "$plan" ] || return 2
  marker_outer_raw="$(codex_state_value "$marker" cwd false 2>/dev/null || true)"
  [ -n "$marker_outer_raw" ] || return 2
  marker_outer="$(codex_canonical_cwd "$marker_outer_raw")"
  codex_eci_aggregate_plan_is_valid "$plan" "$session_id" "$marker_outer" "$marker" || return 2
  ECI_AGGREGATE_SESSION=true
  if codex_eci_aggregate_plan_select_cwd "$plan" "$session_id" "$marker" "$(codex_canonical_cwd "$cwd")"; then
    ECI_AGGREGATE_REPO_ID="$codex_eci_aggregate_selected_id"
    ECI_AGGREGATE_REPO_ROOT="$codex_eci_aggregate_selected_root"
    return 0
  fi
  return 3
}

validate_active_marker_binding() {
  # A discovery record can go stale after initial selection. That is
  # diagnostic context, not a reason to stop ordinary work. Target-aware
  # mutation checks remain responsible for concrete unsafe effects.
  if ! codex_proof_root_is_safe || [ -z "${CODEX_PROOF_ROOT_CANONICAL:-}" ]; then
    ECI_MARKER_VALIDATION_COMPLETE=true
    return 0
  fi
  CODEX_STOP_GATE_ROOT="$CODEX_PROOF_ROOT_CANONICAL"
  CODEX_PROOF_ROOT="$CODEX_PROOF_ROOT_CANONICAL"

  [ "$ECI_MARKER_VALIDATION_COMPLETE" = true ] && return 0
  if [ "${#syntax_eci_markers[@]}" -eq 0 ]; then
    ECI_MARKER_VALIDATION_COMPLETE=true
    return 0
  fi
  local marker
  for marker in "${syntax_eci_markers[@]}"; do
    # A valid aggregate plan can still enrich callback context. A stale,
    # malformed, or sibling observation is advisory and must not become a
    # generic active-owner denial for an otherwise harmless command.
    aggregate_marker_context_for_callback "$marker" || true
  done
  ECI_MARKER_VALIDATION_COMPLETE=true
}


direct_ledger_prefix_effect_check() {
  # A selected ledger append is safe only when this already parsed static
  # segment has no independently resolved protected effect. Unknown ordinary
  # segments remain transparent; a known lifecycle/control segment falls
  # through to its existing route rather than gaining fallback admission.
  local prefix="$1" prefix_detail
  local command="$prefix"

  case "$command" in
    *git*|*reset*|*worktree*) enforce_git_mutation_gate ;;
  esac

  prefix_detail="$(protected_literal_operation_detail "$command" "$hook_is_subagent" 2>/dev/null || true)"
  case "$prefix_detail" in
    class=broad\ *)
      deny_eci "ECI_BROAD_DESTRUCTIVE_DENIED" "broad-destructive" \
        "ECI ownership gate denied a broad destructive operation: ${prefix_detail}; reason=the resolved target is a filesystem, home, repository, provider, proof, or current working root" \
        "narrow the reported target to the exact task-owned file or subdirectory and retry as one finite literal argv"
      ;;
    class=worker-git\ *)
      deny_eci "ECI_WORKER_GIT_OWNERSHIP_DENIED" "worker-git-ownership" \
        "ECI worker ownership gate denied a protected Git operation: ${prefix_detail}; predicate=worker-git-ownership; reason=protected Git operations route through the Supervisor while ECI is active; ordinary assigned Producer commits use the separate repository/effect checks" \
        "route the reported protected Git operation request to the Supervisor; ordinary assigned Producer commits use the resolved repository/effect checks"
      ;;
  esac

  if command_invokes_eci_lifecycle "$command" || command_invokes_eci_binary "$command" ||
    [ -n "$(review_gate_command_identity "$command" 2>/dev/null || true)" ] ||
    [ -n "$(protected_control_script_identity "$command" 2>/dev/null || true)" ]; then
    return 1
  fi
  if [ "$DIRECT_LEDGER_STATIC_DYNAMIC_TARGET" != true ] &&
    command_invokes_eci_control_mutation "$command"; then
    return 1
  fi
  if [ "$hook_is_subagent" = true ] && [ "$DIRECT_LEDGER_STATIC_DYNAMIC_TARGET" != true ]; then
    prefix_detail="$(worker_control_path_detail 2>/dev/null || true)"
    [ -z "$prefix_detail" ] || return 1
  fi
  return 0
}

DIRECT_LEDGER_NESTED_PAYLOAD=""
DIRECT_LEDGER_NESTED_END=""

# These extractors only recognize a syntactically complete substitution. An
# unresolved or malformed payload remains opaque ordinary input: it does not
# create a parser-shape denial or a guessed capability.
direct_ledger_command_substitution_payload() {
  local raw="$1" start="$2" length index payload_start character state=unquoted depth=1

  [ "${raw:start:2}" = '$(' ] || return 1
  length=${#raw}
  payload_start=$((start + 2))
  index="$payload_start"
  while [ "$index" -lt "$length" ]; do
    character="${raw:index:1}"
    if [ "$state" = single ]; then
      if [ "$character" = "'" ]; then
        state=unquoted
      fi
      index=$((index + 1))
      continue
    fi
    if [ "$state" = double ]; then
      case "$character" in
        '"') state=unquoted; index=$((index + 1)) ;;
        '\\')
          [ $((index + 1)) -lt "$length" ] || return 1
          index=$((index + 2))
          ;;
        *) index=$((index + 1)) ;;
      esac
      continue
    fi
    case "$character" in
      "'") state=single; index=$((index + 1)) ;;
      '"') state=double; index=$((index + 1)) ;;
      '\\')
        [ $((index + 1)) -lt "$length" ] || return 1
        index=$((index + 2))
        ;;
      '`')
        if direct_ledger_backtick_payload "$raw" "$index"; then
          index=$((DIRECT_LEDGER_NESTED_END + 1))
        else
          return 1
        fi
        ;;
      '(') depth=$((depth + 1)); index=$((index + 1)) ;;
      ')')
        depth=$((depth - 1))
        if [ "$depth" -eq 0 ]; then
          DIRECT_LEDGER_NESTED_PAYLOAD="${raw:payload_start:$((index - payload_start))}"
          DIRECT_LEDGER_NESTED_END="$index"
          return 0
        fi
        index=$((index + 1))
        ;;
      *) index=$((index + 1)) ;;
    esac
  done
  return 1
}

direct_ledger_backtick_payload() {
  local raw="$1" start="$2" length index character

  [ "${raw:start:1}" = '`' ] || return 1
  length=${#raw}
  index=$((start + 1))
  while [ "$index" -lt "$length" ]; do
    character="${raw:index:1}"
    case "$character" in
      '\\')
        [ $((index + 1)) -lt "$length" ] || return 1
        index=$((index + 2))
        ;;
      '`')
        DIRECT_LEDGER_NESTED_PAYLOAD="${raw:$((start + 1)):$((index - start - 1))}"
        DIRECT_LEDGER_NESTED_END="$index"
        return 0
        ;;
      *) index=$((index + 1)) ;;
    esac
  done
  return 1
}

direct_ledger_nested_payload_is_static() {
  local saved_payload="$DIRECT_LEDGER_NESTED_PAYLOAD" saved_end="$DIRECT_LEDGER_NESTED_END" status

  direct_ledger_nested_payload_is_static_inner "$1"
  status=$?
  DIRECT_LEDGER_NESTED_PAYLOAD="$saved_payload"
  DIRECT_LEDGER_NESTED_END="$saved_end"
  return "$status"
}

direct_ledger_nested_payload_is_static_inner() {
  local raw="$1" length index=0 character state=unquoted

  case "$raw" in
    *$'\n'*|*$'\r'*) return 1 ;;
  esac
  length=${#raw}
  while [ "$index" -lt "$length" ]; do
    character="${raw:index:1}"
    if [ "$state" = single ]; then
      if [ "$character" = "'" ]; then
        state=unquoted
      fi
      index=$((index + 1))
      continue
    fi
    if [ "$state" = double ]; then
      case "$character" in
        '"') state=unquoted; index=$((index + 1)) ;;
        '\\')
          [ $((index + 1)) -lt "$length" ] || return 1
          index=$((index + 2))
          ;;
        '$')
          if [ "${raw:$((index + 1)):1}" = '(' ] &&
            direct_ledger_command_substitution_payload "$raw" "$index" &&
            direct_ledger_nested_payload_is_static "$DIRECT_LEDGER_NESTED_PAYLOAD"; then
            index=$((DIRECT_LEDGER_NESTED_END + 1))
          else
            return 1
          fi
          ;;
        '`')
          if direct_ledger_backtick_payload "$raw" "$index" &&
            direct_ledger_nested_payload_is_static "$DIRECT_LEDGER_NESTED_PAYLOAD"; then
            index=$((DIRECT_LEDGER_NESTED_END + 1))
          else
            return 1
          fi
          ;;
        *) index=$((index + 1)) ;;
      esac
      continue
    fi
    case "$character" in
      "'") state=single; index=$((index + 1)) ;;
      '"') state=double; index=$((index + 1)) ;;
      '\\')
        [ $((index + 1)) -lt "$length" ] || return 1
        index=$((index + 2))
        ;;
      '$')
        if [ "${raw:$((index + 1)):1}" = '(' ] &&
          direct_ledger_command_substitution_payload "$raw" "$index" &&
          direct_ledger_nested_payload_is_static "$DIRECT_LEDGER_NESTED_PAYLOAD"; then
          index=$((DIRECT_LEDGER_NESTED_END + 1))
        else
          return 1
        fi
        ;;
      '`')
        if direct_ledger_backtick_payload "$raw" "$index" &&
          direct_ledger_nested_payload_is_static "$DIRECT_LEDGER_NESTED_PAYLOAD"; then
          index=$((DIRECT_LEDGER_NESTED_END + 1))
        else
          return 1
        fi
        ;;
      *) index=$((index + 1)) ;;
    esac
  done
  [ "$state" = unquoted ]
}

direct_ledger_direct_shell_c_payload() {
  local token_index=0
  local -a tokens=("$@")

  DIRECT_LEDGER_NESTED_PAYLOAD=""
  while [ "$token_index" -lt "${#tokens[@]}" ] &&
    [[ "${tokens[$token_index]}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do
    token_index=$((token_index + 1))
  done
  case "${tokens[$token_index]:-}" in
    bash|sh|/bin/bash|/bin/sh|/usr/bin/bash|/usr/bin/sh) ;;
    *) return 1 ;;
  esac
  [ "${tokens[$((token_index + 1))]:-}" = -c ] || return 1
  [ $((token_index + 2)) -lt "${#tokens[@]}" ] || return 1
  DIRECT_LEDGER_NESTED_PAYLOAD="${tokens[$((token_index + 2))]}"
  direct_ledger_nested_payload_is_static "$DIRECT_LEDGER_NESTED_PAYLOAD"
}

# direct_ledger_static_records decodes only static shell words, quotes, and
# visible output redirects. It leaves ordinary values (including environment
# assignments and their expansions) as data, while unsupported control forms
# simply fall through to the existing routes.
DIRECT_LEDGER_TEE_INPUT_DEV_NULL_TOKEN=$'\036eci-tee-input-dev-null\036'

direct_ledger_static_records() {
  local raw="$1" record_mode="${2:-ledger}" length index=0 character next_character state=unquoted word="" word_started=false word_plain=false
  local token_index segment_start segment_end prefix quoted_word effect target nested_text input_index input_end
  local foreign_segment_index=0
  local -a token_kinds=() token_values=() records=() stripped=() foreign_redirect_targets=()

  case "$record_mode" in
    ledger|foreign-marker) ;;
    *) return 1 ;;
  esac
  [ -n "$raw" ] || return 1
  case "$raw" in
    *$'\n'*|*$'\r'*) return 1 ;;
  esac
  length=${#raw}
  [ "$length" -le 16384 ] || return 1

  while [ "$index" -lt "$length" ]; do
    character="${raw:index:1}"
    if [ "$state" = single ]; then
      if [ "$character" = "'" ]; then
        state=unquoted
      else
        word+="$character"
      fi
      index=$((index + 1))
      continue
    fi
    if [ "$state" = double ]; then
      if [ "$character" = '$' ] && [ "${raw:$((index + 1)):1}" = '(' ]; then
        if direct_ledger_command_substitution_payload "$raw" "$index"; then
          nested_text="${raw:index:$((DIRECT_LEDGER_NESTED_END - index + 1))}"
          word+="$nested_text"
          [ "$record_mode" != foreign-marker ] || return 1
          if direct_ledger_nested_payload_is_static "$DIRECT_LEDGER_NESTED_PAYLOAD"; then
            records+=(nested "$DIRECT_LEDGER_NESTED_PAYLOAD")
          fi
          index=$((DIRECT_LEDGER_NESTED_END + 1))
        else
          [ "$record_mode" != foreign-marker ] || return 1
          word+='$('
          index=$((index + 2))
        fi
        continue
      fi
      if [ "$character" = '`' ]; then
        if direct_ledger_backtick_payload "$raw" "$index"; then
          nested_text="${raw:index:$((DIRECT_LEDGER_NESTED_END - index + 1))}"
          word+="$nested_text"
          [ "$record_mode" != foreign-marker ] || return 1
          if direct_ledger_nested_payload_is_static "$DIRECT_LEDGER_NESTED_PAYLOAD"; then
            records+=(nested "$DIRECT_LEDGER_NESTED_PAYLOAD")
          fi
          index=$((DIRECT_LEDGER_NESTED_END + 1))
        else
          [ "$record_mode" != foreign-marker ] || return 1
          word+='`'
          index=$((index + 1))
        fi
        continue
      fi
      if [ "$character" = '"' ]; then
        state=unquoted
        index=$((index + 1))
        continue
      fi
      if [ "$character" = '\' ]; then
        [ $((index + 1)) -lt "$length" ] || return 1
        next_character="${raw:$((index + 1)):1}"
        case "$next_character" in
          '"'|'$'|'`'|'\\') word+="$next_character" ;;
          *) word+="\\$next_character" ;;
        esac
        index=$((index + 2))
        continue
      fi
      word+="$character"
      index=$((index + 1))
      continue
    fi

    if [[ "$character" =~ [[:space:]] ]]; then
      if [ "$word_started" = true ]; then
        token_kinds+=(word)
        token_values+=("$word")
        word=""
        word_started=false
        word_plain=false
      fi
      index=$((index + 1))
      continue
    fi
    if [ "$character" = '#' ] && [ "$word_started" = false ]; then
      break
    fi
    if [ "$character" = "'" ]; then
      word_started=true
      word_plain=false
      state=single
      index=$((index + 1))
      continue
    fi
    if [ "$character" = '"' ]; then
      word_started=true
      word_plain=false
      state=double
      index=$((index + 1))
      continue
    fi
    if [ "$character" = '\' ]; then
      [ $((index + 1)) -lt "$length" ] || return 1
      word_started=true
      word_plain=false
      word+="${raw:$((index + 1)):1}"
      index=$((index + 2))
      continue
    fi
    if [ "$character" = '$' ] && [ "${raw:$((index + 1)):1}" = '(' ]; then
      word_started=true
      word_plain=false
      if direct_ledger_command_substitution_payload "$raw" "$index"; then
        nested_text="${raw:index:$((DIRECT_LEDGER_NESTED_END - index + 1))}"
        word+="$nested_text"
        [ "$record_mode" != foreign-marker ] || return 1
        if direct_ledger_nested_payload_is_static "$DIRECT_LEDGER_NESTED_PAYLOAD"; then
          records+=(nested "$DIRECT_LEDGER_NESTED_PAYLOAD")
        fi
        index=$((DIRECT_LEDGER_NESTED_END + 1))
      else
        [ "$record_mode" != foreign-marker ] || return 1
        word+='$('
        index=$((index + 2))
      fi
      continue
    fi
    if [ "$character" = '`' ]; then
      word_started=true
      word_plain=false
      if direct_ledger_backtick_payload "$raw" "$index"; then
        nested_text="${raw:index:$((DIRECT_LEDGER_NESTED_END - index + 1))}"
        word+="$nested_text"
        [ "$record_mode" != foreign-marker ] || return 1
        if direct_ledger_nested_payload_is_static "$DIRECT_LEDGER_NESTED_PAYLOAD"; then
          records+=(nested "$DIRECT_LEDGER_NESTED_PAYLOAD")
        fi
        index=$((DIRECT_LEDGER_NESTED_END + 1))
      else
        [ "$record_mode" != foreign-marker ] || return 1
        word+='`'
        index=$((index + 1))
      fi
      continue
    fi
    if [ "$character" = ';' ]; then
      if [ "$word_started" = true ]; then
        token_kinds+=(word)
        token_values+=("$word")
        word=""
        word_started=false
        word_plain=false
      fi
      token_kinds+=(delimiter)
      token_values+=("")
      index=$((index + 1))
      continue
    fi
    if [ "$character" = '>' ]; then
      if [ "$word_started" = true ]; then
        token_kinds+=(word)
        token_values+=("$word")
        word=""
        word_started=false
        word_plain=false
      fi
      case "${raw:index:2}" in
        '>>') token_kinds+=(operator); token_values+=('>>'); index=$((index + 2)) ;;
        '>|') token_kinds+=(operator); token_values+=('>|'); index=$((index + 2)) ;;
        '>&') token_kinds+=(operator); token_values+=('>&'); index=$((index + 2)) ;;
        *) token_kinds+=(operator); token_values+=('>'); index=$((index + 1)) ;;
      esac
      continue
    fi
    if [ "$character" = '&' ]; then
      if [ "$word_started" = true ]; then
        token_kinds+=(word)
        token_values+=("$word")
        word=""
        word_started=false
        word_plain=false
      fi
      if [ "$record_mode" = foreign-marker ]; then
        case "${raw:index:3}" in
          '&>>'|'&>'*) ;;
          *) return 1 ;;
        esac
      fi
      case "${raw:index:3}" in
        '&>>') token_kinds+=(operator); token_values+=('&>>'); index=$((index + 3)) ;;
        '&>'*) token_kinds+=(operator); token_values+=('&>'); index=$((index + 2)) ;;
        '&&'*) token_kinds+=(delimiter); token_values+=(""); index=$((index + 2)) ;;
        *) token_kinds+=(delimiter); token_values+=(""); index=$((index + 1)) ;;
      esac
      continue
    fi
    if [ "$character" = '|' ]; then
      if [ "$word_started" = true ]; then
        token_kinds+=(word)
        token_values+=("$word")
        word=""
        word_started=false
        word_plain=false
      fi
      # A single pipe starts another visible command segment. Leave `||`
      # opaque in the foreign-marker walk rather than guessing its effect.
      if [ "$record_mode" = foreign-marker ] && [ "${raw:$((index + 1)):1}" = '|' ]; then
        return 1
      fi
      token_kinds+=(delimiter)
      token_values+=("")
      if [ "${raw:$((index + 1)):1}" = '|' ]; then
        index=$((index + 2))
      else
        index=$((index + 1))
      fi
      continue
    fi
    if [ "$character" = '<' ]; then
      if [ "$word_started" = true ]; then
        case "$word_plain:$word" in
          true:0|true:1|true:2) ;;
          *)
            # Unsupported input FDs are syntax, not child operands.
            if [ "$word_plain" = true ] && [[ "$word" =~ ^[0-9]+$ ]]; then
              return 1
            fi
            token_kinds+=(word)
            token_values+=("$word")
            ;;
        esac
        word=""
        word_started=false
        word_plain=false
      fi
      if [ "${raw:$((index + 1)):1}" = '&' ]; then
        input_index=$((index + 2))
        while [ "$input_index" -lt "$length" ] && [[ "${raw:input_index:1}" =~ [[:space:]] ]]; do
          input_index=$((input_index + 1))
        done
        [ "${raw:input_index:1}" = 0 ] || return 1
        next_character="${raw:$((input_index + 1)):1}"
        case "$next_character" in
          ''|[[:space:]]|';'|'&'|'|'|'<'|'>') ;;
          *) return 1 ;;
        esac
        token_kinds+=(foreign-input-fd0)
        token_values+=("")
        index=$((input_index + 1))
        continue
      fi
      case "${raw:$((index + 1)):1}" in
        ''|'<'|'>'|'|'|';') return 1 ;;
      esac
      token_kinds+=(foreign-input)
      token_values+=("")
      index=$((index + 1))
      continue
    fi
    if [[ "$character" = '(' || "$character" = ')' ]]; then
      return 1
    fi
    if [ "$word_started" = false ]; then
      word_plain=true
    fi
    word_started=true
    word+="$character"
    index=$((index + 1))
  done
  [ "$state" = unquoted ] || return 1
  if [ "$word_started" = true ]; then
    token_kinds+=(word)
    token_values+=("$word")
  fi
  segment_start=0
  for ((segment_end = 0; segment_end <= ${#token_kinds[@]}; segment_end++)); do
    if [ "$segment_end" -lt "${#token_kinds[@]}" ] && [ "${token_kinds[$segment_end]}" != delimiter ]; then
      continue
    fi
    if [ "$segment_start" -lt "$segment_end" ]; then
      stripped=()
      foreign_redirect_targets=()
      token_index="$segment_start"
      while [ "$token_index" -lt "$segment_end" ]; do
        if [ "${token_kinds[$token_index]}" = word ]; then
          stripped+=("${token_values[$token_index]}")
          token_index=$((token_index + 1))
          continue
        fi
        if [ "${token_kinds[$token_index]}" = tee-input-dev-null ]; then
          stripped+=("$DIRECT_LEDGER_TEE_INPUT_DEV_NULL_TOKEN")
          token_index=$((token_index + 1))
          continue
        fi
        if [ "${token_kinds[$token_index]}" = foreign-input ]; then
          [ $((token_index + 1)) -lt "$segment_end" ] || return 1
          [ "${token_kinds[$((token_index + 1))]}" = word ] || return 1
          foreign_active_marker_dynamic_text "${token_values[$((token_index + 1))]}" && return 1
          if [ "$record_mode" = ledger ] && [ "${stripped[0]:-}" = tee ]; then
            # Preserve the existing bare tee /dev/null suffix contract.
            [ "${token_values[$((token_index + 1))]}" = /dev/null ] || return 1
            stripped+=("$DIRECT_LEDGER_TEE_INPUT_DEV_NULL_TOKEN")
          fi
          token_index=$((token_index + 2))
          continue
        fi
        if [ "${token_kinds[$token_index]}" = foreign-input-fd0 ]; then
          token_index=$((token_index + 1))
          continue
        fi
        [ $((token_index + 1)) -lt "$segment_end" ] || return 1
        [ "${token_kinds[$((token_index + 1))]}" = word ] || return 1
        target="${token_values[$((token_index + 1))]}"
        case "${token_values[$token_index]}" in
          '>>'|'&>>') effect=append ;;
          '>&')
            if [ "$target" = - ] || [[ "$target" =~ ^[0-9]+$ ]]; then
              effect=""
            else
              effect=overwrite
            fi
            ;;
          '>|') effect=force-overwrite ;;
          '>'|'&>') effect=overwrite ;;
          *) return 1 ;;
        esac
        if [ -n "$effect" ]; then
          if [ "$record_mode" = foreign-marker ]; then
            foreign_redirect_targets+=("$target")
          else
            records+=(redirect "$effect" "$target")
          fi
        fi
        token_index=$((token_index + 2))
      done
      if [ "${#stripped[@]}" -gt 0 ]; then
        if [ "$record_mode" = foreign-marker ]; then
          DIRECT_LEDGER_FOREIGN_WORDS=("${stripped[@]}")
          DIRECT_LEDGER_FOREIGN_REDIRECT_TARGETS=("${foreign_redirect_targets[@]}")
          foreign_segment_index=$((foreign_segment_index + 1))
          foreign_active_marker_consume_ledger_segment "$foreign_segment_index" || true
          [ -z "${FOREIGN_ACTIVE_MARKER_DETAIL:-}" ] || return 0
        else
          prefix=""
          for word in "${stripped[@]}"; do
            printf -v quoted_word '%q' "$word"
            if [ -n "$prefix" ]; then
              prefix+=" "
            fi
            prefix+="$quoted_word"
          done
          records+=(segment "$prefix")
          records+=(words "${#stripped[@]}" "${stripped[@]}")
          if direct_ledger_direct_shell_c_payload "${stripped[@]}"; then
            records+=(nested "$DIRECT_LEDGER_NESTED_PAYLOAD")
          fi
        fi
      fi
    fi
    segment_start=$((segment_end + 1))
  done
  if [ "$record_mode" = ledger ]; then
    printf '%s\0' "${records[@]}" complete
  fi
  return 0
}

# direct_ledger_redirect_effect_check preserves the existing ledger-specific
# diagnostics for every statically visible redirect. Ordinary resolved paths
# remain ordinary; a selected-session log append marks only that one effect as
# eligible for the fallback's final decision.
direct_ledger_redirect_effect_check() {
  local effect="$1" target="$2" selected_dir="$3" selected_real="$4" proof_root="$5" selected_session="$6"
  local target_path resolved target_identity target_session="" target_artifact=""
  local candidate_dir candidate_session candidate artifact candidate_identity link_count

  if [[ "$target" = /* ]]; then
    target_path="$target"
  else
    target_path="$cwd/$target"
  fi
  resolved="$(realpath -e -- "$target_path" 2>/dev/null || true)"
  [ -n "$resolved" ] && [ -f "$resolved" ] || return 0
  target_identity="$(stat -Lc '%d:%i' -- "$resolved" 2>/dev/null || true)"
  [[ "$target_identity" =~ ^[0-9]+:[0-9]+$ ]] || return 0

  for artifact in high_level_log.md high_level_log.anchor; do
    candidate="$selected_real/$artifact"
    [ -f "$candidate" ] && [ ! -L "$candidate" ] || continue
    candidate_identity="$(stat -Lc '%d:%i' -- "$candidate" 2>/dev/null || true)"
    if [ "$target_identity" = "$candidate_identity" ]; then
      target_session="$selected_session"
      target_artifact="$artifact"
      break
    fi
  done
  if [ -z "$target_artifact" ]; then
    for candidate_dir in "$proof_root"/*; do
      [ -d "$candidate_dir" ] && [ ! -L "$candidate_dir" ] || continue
      candidate_session="${candidate_dir##*/}"
      [ "$candidate_session" != "$selected_session" ] || continue
      for artifact in high_level_log.md high_level_log.anchor; do
        candidate="$candidate_dir/$artifact"
        [ -f "$candidate" ] && [ ! -L "$candidate" ] || continue
        candidate_identity="$(stat -Lc '%d:%i' -- "$candidate" 2>/dev/null || true)"
        if [ "$target_identity" = "$candidate_identity" ]; then
          target_session="$candidate_session"
          target_artifact="$artifact"
          break 2
        fi
      done
    done
  fi
  [ -n "$target_artifact" ] || return 0

  if [ "$target_session" != "$selected_session" ]; then
    DIRECT_LEDGER_FALLBACK_DECISION=deny
    DIRECT_LEDGER_FALLBACK_CODE=ECI_LEDGER_FOREIGN_SESSION_DENIED
    DIRECT_LEDGER_FALLBACK_DETAIL="ledger redirect targets a sibling proof session: target_session=$target_session path=$resolved"
    DIRECT_LEDGER_FALLBACK_REMEDIATION="write only the selected session's high_level_log.md"
    return 0
  fi
  if [ "$target_artifact" = high_level_log.anchor ]; then
    DIRECT_LEDGER_FALLBACK_DECISION=deny
    DIRECT_LEDGER_FALLBACK_CODE=ECI_LEDGER_ANCHOR_WRITE_DENIED
    DIRECT_LEDGER_FALLBACK_DETAIL="selected-session ledger anchor is control state: target=high_level_log.anchor path=$resolved"
    DIRECT_LEDGER_FALLBACK_REMEDIATION="leave high_level_log.anchor for normal ledger reconciliation"
    return 0
  fi
  if [ "$effect" != append ]; then
    DIRECT_LEDGER_FALLBACK_DECISION=deny
    DIRECT_LEDGER_FALLBACK_CODE=ECI_LEDGER_REWRITE_DENIED
    DIRECT_LEDGER_FALLBACK_DETAIL="selected-session ledger redirect would replace its target: effect=$effect target=$resolved"
    DIRECT_LEDGER_FALLBACK_REMEDIATION="append at EOF to the selected session's high_level_log.md"
    return 0
  fi
  link_count="$(stat -Lc '%h' -- "$resolved" 2>/dev/null || true)"
  if [ "$link_count" != 1 ]; then
    DIRECT_LEDGER_FALLBACK_DECISION=deny
    DIRECT_LEDGER_FALLBACK_CODE=ECI_LEDGER_SHARED_INODE_DENIED
    DIRECT_LEDGER_FALLBACK_DETAIL="selected-session ledger append target must have one link: target=$resolved nlink=${link_count:-unavailable}"
    DIRECT_LEDGER_FALLBACK_REMEDIATION="restore a uniquely linked selected-session high_level_log.md before appending"
    return 0
  fi
  DIRECT_LEDGER_FALLBACK_CURRENT_APPEND=true
}

# Resolve a concrete static target by canonical path or the existing device /
# inode identity comparison. An ordinary alias never creates a control effect.
direct_ledger_resolved_current_control_target() {
  local target="$1" selected_real="$2" candidate resolved parent target_identity candidate_identity

  DIRECT_LEDGER_RESOLVED_CONTROL_TARGET=""
  [ -n "$target" ] || return 1
  case "$target" in
    -*|*'$'*|*'`'*|*'~'*|*'?'|*'['*|*']'*) return 1 ;;
  esac
  if [[ "$target" = /* ]]; then
    candidate="$target"
  else
    candidate="$cwd/$target"
  fi
  resolved="$(realpath -m -- "$candidate" 2>/dev/null || true)"
  [ -n "$resolved" ] || return 1
  parent="${resolved%/*}"
  if [ "$parent" = "$selected_real" ]; then
    case "${resolved##*/}" in
      instructions.md|project-understanding.md|latest-status-report.md) ;;
      *)
        if codex_eci_control_basename "${resolved##*/}"; then
          DIRECT_LEDGER_RESOLVED_CONTROL_TARGET="$resolved"
          return 0
        fi
        ;;
    esac
  fi
  [ -f "$resolved" ] || return 1
  target_identity="$(stat -Lc '%d:%i' -- "$resolved" 2>/dev/null || true)"
  [[ "$target_identity" =~ ^[0-9]+:[0-9]+$ ]] || return 1
  for candidate in "$selected_real"/*; do
    [ -f "$candidate" ] && [ ! -L "$candidate" ] || continue
    case "${candidate##*/}" in
      instructions.md|project-understanding.md|latest-status-report.md) continue ;;
    esac
    codex_eci_control_basename "${candidate##*/}" || continue
    candidate_identity="$(stat -Lc '%d:%i' -- "$candidate" 2>/dev/null || true)"
    if [ "$target_identity" = "$candidate_identity" ]; then
      DIRECT_LEDGER_RESOLVED_CONTROL_TARGET="$candidate"
      return 0
    fi
  done
  return 1
}

direct_ledger_deny_current_control_target() {
  DIRECT_LEDGER_FALLBACK_DECISION=deny
  DIRECT_LEDGER_FALLBACK_CODE=ECI_CONTROL_OWNER_REQUIRED
  DIRECT_LEDGER_FALLBACK_DETAIL="static mutation targets current-session ECI control state: resolved_control_target=$DIRECT_LEDGER_RESOLVED_CONTROL_TARGET"
  DIRECT_LEDGER_FALLBACK_REMEDIATION="route the resolved ECI control target through the Supervisor lifecycle route"
}

direct_ledger_static_target_is_dynamic() {
  case "$1" in
    *'$'*|*'`'*|*'~'*|*'?'|*'['*|*']'*) return 0 ;;
    *) return 1 ;;
  esac
}

direct_ledger_static_redirect_control_target_check() {
  local effect="$1" target="$2" selected_real="$3"

  direct_ledger_resolved_current_control_target "$target" "$selected_real" || return 0
  # The current log's EOF append is the one deliberately admitted ledger
  # effect. Rewrites and anchor writes already received their more concrete
  # ledger diagnostics before this shared control-target pass.
  if [ "$effect" = append ] &&
    [ "${DIRECT_LEDGER_RESOLVED_CONTROL_TARGET##*/}" = high_level_log.md ]; then
    return 0
  fi
  direct_ledger_deny_current_control_target
}

# Classify already selected output targets in effect order: ledger semantics,
# current control identity, then a genuinely foreign active marker.
direct_ledger_static_output_target_check() {
  local effect="$1" target="$2" selected_real="$3" foreign_detail

  direct_ledger_redirect_effect_check "$effect" "$target" "$selected_real" "$selected_real" "${selected_real%/*}" "${selected_real##*/}"
  [ "$DIRECT_LEDGER_FALLBACK_DECISION" != deny ] || return 0
  direct_ledger_static_redirect_control_target_check "$effect" "$target" "$selected_real"
  [ "$DIRECT_LEDGER_FALLBACK_DECISION" != deny ] || return 0
  foreign_detail="$(foreign_active_marker_candidate_detail "$target" "$cwd" "${selected_real##*/}" 2>/dev/null || true)"
  [ -n "$foreign_detail" ] || return 0
  DIRECT_LEDGER_FALLBACK_DECISION=deny
  DIRECT_LEDGER_FALLBACK_CODE=ECI_CROSS_SESSION_ACTIVE_MARKER_DENIED
  DIRECT_LEDGER_FALLBACK_DETAIL="ECI control boundary denied mutation of another session's active marker: $foreign_detail"
  DIRECT_LEDGER_FALLBACK_REMEDIATION="leave the other session marker unchanged; use its coordinator or the current session's normal routing path"
}

direct_ledger_static_segment_control_target_check() {
  local selected_real="$1" token_index=0 target command_name output_start output_end output_count
  local dd_if_seen=false dd_of_seen=false dd_output=""
  local cwd="$cwd"
  shift
  local -a tokens=("$@") current_targets=()

  while [ "$token_index" -lt "${#tokens[@]}" ] &&
    [[ "${tokens[$token_index]}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do
    token_index=$((token_index + 1))
  done
  [ "$token_index" -lt "${#tokens[@]}" ] || return 0
  command_name="${tokens[$token_index]##*/}"
  if [ "$command_name" = env ]; then
    foreign_active_marker_env_child "$cwd" "${tokens[@]:$token_index}" || return 0
    cwd="$FOREIGN_ACTIVE_MARKER_ENV_CHILD_CWD"
    tokens=("$FOREIGN_ACTIVE_MARKER_ENV_CHILD_EXECUTABLE" "${tokens[@]:$((token_index + FOREIGN_ACTIVE_MARKER_ENV_CHILD_ARGS_INDEX))}")
    token_index=0
    command_name="${tokens[0]##*/}"
    # Unwrap only these current-effect families. Keep the existing bare
    # tee/dd/install contracts and the foreign/timeout consumer unchanged.
    case "$command_name" in
      cp|rm|touch|sed) ;;
      *) return 0 ;;
    esac
  fi
  case "$command_name" in
    cp|rm|touch)
      # Reuse the finite option and destination roles without interpreting
      # source operands as targets or reparsing the decoded argv values.
      mapfile -t current_targets < <(foreign_active_marker_writer_targets \
        "$command_name" "${tokens[@]:$((token_index + 1))}")
      ;;
    sed)
      # Only bare -i SCRIPT FILE... is known here. The one script is data;
      # suffixes, additional options and other sed forms remain ordinary.
      [ "${tokens[$((token_index + 1))]:-}" = -i ] || return 0
      [ "${#tokens[@]}" -ge $((token_index + 4)) ] || return 0
      target="${tokens[$((token_index + 2))]}"
      direct_ledger_static_target_is_dynamic "$target" && return 0
      case "$target" in
        -*) return 0 ;;
      esac
      current_targets=("${tokens[@]:$((token_index + 3))}")
      for target in "${current_targets[@]}"; do
        case "$target" in
          ''|-*) return 0 ;;
        esac
      done
      ;;
    unlink|rmdir|truncate|shred|srm|chmod|chown)
      token_index=$((token_index + 1))
      [ "$token_index" -lt "${#tokens[@]}" ] || return 0
      # Options make operand roles command-specific. Do not guess: the normal
      # target-aware routes remain available for those ordinary forms.
      for target in "${tokens[@]:$token_index}"; do
        case "$target" in
          --|-*) return 0 ;;
        esac
      done
      for target in "${tokens[@]:$token_index}"; do
        if direct_ledger_static_target_is_dynamic "$target"; then
          DIRECT_LEDGER_STATIC_DYNAMIC_TARGET=true
          continue
        fi
        direct_ledger_resolved_current_control_target "$target" "$selected_real" || continue
        direct_ledger_deny_current_control_target
        return 0
      done
      ;;
    tee)
      # Keep this intentionally smaller than tee's general grammar. Bare tee
      # has one to sixteen non-option output operands and may end in only the
      # exact /dev/null input suffix decoded by direct_ledger_static_records.
      # Every other option, wrapper, path spelling, or input form remains
      # ordinary input for the normal target-aware routes.
      [ "$token_index" -eq 0 ] && [ "${tokens[0]:-}" = tee ] || return 0
      output_start=1
      output_end=$((${#tokens[@]} - 1))
      if [ "${tokens[$output_end]:-}" = "$DIRECT_LEDGER_TEE_INPUT_DEV_NULL_TOKEN" ]; then
        output_end=$((output_end - 1))
      fi
      output_count=$((output_end - output_start + 1))
      [ "$output_count" -ge 1 ] && [ "$output_count" -le 16 ] || return 0
      for ((token_index = output_start; token_index <= output_end; token_index++)); do
        target="${tokens[$token_index]}"
        [ -n "$target" ] || return 0
        [ "$target" != "$DIRECT_LEDGER_TEE_INPUT_DEV_NULL_TOKEN" ] || return 0
        case "$target" in
          -*) return 0 ;;
        esac
      done
      for ((token_index = output_start; token_index <= output_end; token_index++)); do
        target="${tokens[$token_index]}"
        if direct_ledger_static_target_is_dynamic "$target"; then
          DIRECT_LEDGER_STATIC_DYNAMIC_TARGET=true
          continue
        fi
        direct_ledger_resolved_current_control_target "$target" "$selected_real" || continue
        direct_ledger_deny_current_control_target
        return 0
      done
      ;;
    dd)
      # Recognize only bare dd with exactly one nonempty if= and one nonempty
      # of= operand. A dynamic input does not obscure a literal output target;
      # all extra or unknown operands remain outside this finite extractor.
      [ "$token_index" -eq 0 ] && [ "${tokens[0]:-}" = dd ] || return 0
      [ "${#tokens[@]}" -eq 3 ] || return 0
      for target in "${tokens[@]:1}"; do
        case "$target" in
          if=?*)
            [ "$dd_if_seen" = false ] || return 0
            dd_if_seen=true
            ;;
          of=?*)
            [ "$dd_of_seen" = false ] || return 0
            dd_of_seen=true
            dd_output="${target#of=}"
            ;;
          *) return 0 ;;
        esac
      done
      [ "$dd_if_seen" = true ] && [ "$dd_of_seen" = true ] || return 0
      if direct_ledger_static_target_is_dynamic "$dd_output"; then
        DIRECT_LEDGER_STATIC_DYNAMIC_TARGET=true
        return 0
      fi
      direct_ledger_resolved_current_control_target "$dd_output" "$selected_real" || return 0
      direct_ledger_deny_current_control_target
      return 0
      ;;
    install)
      # Bare install SOURCE DEST is enough to catch an accidental literal
      # current-control destination. Options and any extra operands retain
      # ordinary command semantics rather than a guessed destination role.
      [ "$token_index" -eq 0 ] && [ "${tokens[0]:-}" = install ] || return 0
      [ "${#tokens[@]}" -eq 3 ] || return 0
      [ -n "${tokens[1]}" ] && [ -n "${tokens[2]}" ] || return 0
      case "${tokens[1]}" in
        -*) return 0 ;;
      esac
      case "${tokens[2]}" in
        -*) return 0 ;;
      esac
      target="${tokens[2]}"
      if direct_ledger_static_target_is_dynamic "$target"; then
        DIRECT_LEDGER_STATIC_DYNAMIC_TARGET=true
        return 0
      fi
      direct_ledger_resolved_current_control_target "$target" "$selected_real" || return 0
      direct_ledger_deny_current_control_target
      return 0
      ;;
    git) ;; # Git archive retains its existing provider-owned output route.
    sort|gitleaks)
      # The words have already lost scalar input operands. Select only the
      # evidenced command/option output pairs; other option spellings remain
      # data unless a separate writer or redirection selects a target.
      for ((token_index = token_index + 1; token_index < ${#tokens[@]}; token_index++)); do
        [ "${tokens[$token_index]}" != -- ] || break
        target=""
        case "$command_name:${tokens[$token_index]}" in
          gitleaks:--report-path|sort:--output|sort:-o)
            token_index=$((token_index + 1))
            target="${tokens[$token_index]:-}"
            ;;
          gitleaks:--report-path=*|sort:--output=*) target="${tokens[$token_index]#*=}" ;;
          sort:-o=*) target="${tokens[$token_index]#-o=}" ;;
          sort:-o?*) target="${tokens[$token_index]#-o}" ;;
        esac
        case "$target" in
          ''|-*) continue ;;
        esac
        direct_ledger_static_target_is_dynamic "$target" && continue
        direct_ledger_static_output_target_check overwrite "$target" "$selected_real"
        [ "$DIRECT_LEDGER_FALLBACK_DECISION" != deny ] || return 0
      done
      ;;
  esac
  for target in "${current_targets[@]}"; do
    if direct_ledger_static_target_is_dynamic "$target"; then
      DIRECT_LEDGER_STATIC_DYNAMIC_TARGET=true
      continue
    fi
    direct_ledger_resolved_current_control_target "$target" "$selected_real" || continue
    direct_ledger_deny_current_control_target
    return 0
  done
}

direct_ledger_static_target_walk() {
  local raw="$1" selected_dir="$2" selected_real="$3" proof_root="$4" selected_session="$5"
  local nested_context="${6:-false}" depth="${7:-0}" record_kind prefix effect target nested_payload record_index word_count word_index
  local -a records=() prefixes=() effects=() targets=() nested_payloads=() word_counts=() word_values=() segment_words=()

  # A depth limit is an opaque ordinary nested payload, never a new syntax
  # gate. The outer visible effects still receive their normal checks.
  [ "$depth" -lt 16 ] || return 0
  mapfile -d '' -t records < <(direct_ledger_static_records "$raw")
  if [ "${#records[@]}" -eq 0 ] || [ "${records[$(( ${#records[@]} - 1 ))]:-}" != complete ]; then
    [ "$nested_context" = true ] && return 0
    return 1
  fi
  unset 'records[$(( ${#records[@]} - 1 ))]'

  record_index=0
  while [ "$record_index" -lt "${#records[@]}" ]; do
    record_kind="${records[$record_index]}"
    case "$record_kind" in
      segment)
        [ $((record_index + 1)) -lt "${#records[@]}" ] || return 1
        prefixes+=("${records[$((record_index + 1))]}")
        record_index=$((record_index + 2))
        ;;
      redirect)
        [ $((record_index + 2)) -lt "${#records[@]}" ] || return 1
        effects+=("${records[$((record_index + 1))]}")
        targets+=("${records[$((record_index + 2))]}")
        record_index=$((record_index + 3))
        ;;
      words)
        [ $((record_index + 1)) -lt "${#records[@]}" ] || return 1
        word_count="${records[$((record_index + 1))]}"
        [[ "$word_count" =~ ^[1-9][0-9]*$ ]] || return 1
        [ $((record_index + 1 + word_count)) -lt "${#records[@]}" ] || return 1
        word_counts+=("$word_count")
        for ((word_index = 0; word_index < word_count; word_index++)); do
          word_values+=("${records[$((record_index + 2 + word_index))]}")
        done
        record_index=$((record_index + 2 + word_count))
        ;;
      nested)
        [ $((record_index + 1)) -lt "${#records[@]}" ] || return 1
        nested_payloads+=("${records[$((record_index + 1))]}")
        record_index=$((record_index + 2))
        ;;
      *) return 1 ;;
    esac
  done

  for record_index in "${!effects[@]}"; do
    effect="${effects[$record_index]}"
    target="${targets[$record_index]}"
    direct_ledger_static_output_target_check "$effect" "$target" "$selected_real"
    [ "$DIRECT_LEDGER_FALLBACK_DECISION" != deny ] || return 0
  done
  word_index=0
  for word_count in "${word_counts[@]}"; do
    segment_words=("${word_values[@]:$word_index:$word_count}")
    word_index=$((word_index + word_count))
    direct_ledger_static_segment_control_target_check "$selected_real" "${segment_words[@]}"
    [ "$DIRECT_LEDGER_FALLBACK_DECISION" != deny ] || return 0
  done
  for nested_payload in "${nested_payloads[@]}"; do
    direct_ledger_static_target_walk "$nested_payload" "$selected_dir" "$selected_real" "$proof_root" "$selected_session" true "$((depth + 1))" || return 1
    [ "$DIRECT_LEDGER_FALLBACK_DECISION" != deny ] || return 0
  done
  DIRECT_LEDGER_STATIC_PREFIXES+=("${prefixes[@]}")
}

direct_ledger_static_record_walk() {
  local prefix prefixes_complete=true

  DIRECT_LEDGER_STATIC_PREFIXES=()
  direct_ledger_static_target_walk "$@" || return 1
  [ "$DIRECT_LEDGER_FALLBACK_DECISION" != deny ] || return 0
  for prefix in "${DIRECT_LEDGER_STATIC_PREFIXES[@]}"; do
    # An incomplete prefix is advisory: later static prefixes can still name
    # a concrete broad, Git, proof, or control effect. Preserve incompleteness
    # for the caller so it cannot admit a ledger append unconditionally.
    direct_ledger_prefix_effect_check "$prefix" || prefixes_complete=false
  done
  [ "$prefixes_complete" = true ]
}

DIRECT_LEDGER_STATIC_SCAN_COMPLETE=false
DIRECT_LEDGER_STATIC_SCAN_COMMAND=""
DIRECT_LEDGER_STATIC_DYNAMIC_TARGET=false
DIRECT_LEDGER_STATIC_PREFIXES=()

direct_ledger_static_control_target_pass() {
  local raw="$1" target_only="${2:-false}" selected_marker selected_dir selected_real proof_root selected_session

  if [ "$DIRECT_LEDGER_STATIC_SCAN_COMPLETE" = true ] &&
    [ "$DIRECT_LEDGER_STATIC_SCAN_COMMAND" = "$raw" ]; then
    return 0
  fi
  [ "${#syntax_eci_markers[@]}" -eq 1 ] || return 1
  selected_marker="${syntax_eci_markers[0]}"
  selected_dir="${selected_marker%/*}"
  selected_real="$(realpath -e -- "$selected_dir" 2>/dev/null || true)"
  [ -n "$selected_real" ] && [ -d "$selected_dir" ] && [ ! -L "$selected_dir" ] || return 1
  proof_root="${selected_real%/*}"
  selected_session="${selected_real##*/}"
  DIRECT_LEDGER_FALLBACK_CURRENT_APPEND=false
  DIRECT_LEDGER_FALLBACK_DECISION=""
  DIRECT_LEDGER_FALLBACK_CODE=""
  DIRECT_LEDGER_FALLBACK_DETAIL=""
  DIRECT_LEDGER_FALLBACK_REMEDIATION=""
  DIRECT_LEDGER_STATIC_DYNAMIC_TARGET=false

  if [ "$target_only" = true ]; then
    DIRECT_LEDGER_STATIC_PREFIXES=()
    direct_ledger_static_target_walk "$raw" "$selected_dir" "$selected_real" "$proof_root" "$selected_session"
    return $?
  fi
  direct_ledger_static_record_walk "$raw" "$selected_dir" "$selected_real" "$proof_root" "$selected_session" || return 1
  DIRECT_LEDGER_STATIC_SCAN_COMPLETE=true
  DIRECT_LEDGER_STATIC_SCAN_COMMAND="$raw"
  return 0
}

direct_ledger_redirect_fallback() {
  local raw="$1"

  direct_ledger_static_control_target_pass "$raw" || return 1
  [ "$DIRECT_LEDGER_FALLBACK_DECISION" != deny ] || return 0
  [ "$DIRECT_LEDGER_FALLBACK_CURRENT_APPEND" = true ] || return 1
  DIRECT_LEDGER_FALLBACK_DECISION=allow
  return 0
}

direct_ledger_emit_fallback_denial() {
  local operation=ledger-redirect
  case "$DIRECT_LEDGER_FALLBACK_CODE" in
    ECI_CONTROL_OWNER_REQUIRED|ECI_CROSS_SESSION_ACTIVE_MARKER_DENIED) operation=eci-control ;;
  esac
  deny_eci "$DIRECT_LEDGER_FALLBACK_CODE" "$operation" \
    "$DIRECT_LEDGER_FALLBACK_DETAIL" "$DIRECT_LEDGER_FALLBACK_REMEDIATION"
}

if [ "${#syntax_eci_markers[@]}" -gt 0 ] &&
  [ "$hook_is_subagent" != true ] &&
  [ "$plan_role" = coordinator ] &&
  [ "$plan_marker_state" = active ] &&
  [ "$command" = 'go test ./pkg/chathandler/platform/youtube -count=1' ]; then
  validate_active_marker_binding
  exit 0
fi

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
    if len(segment) < 2 or segment[0] not in {"bash", "sh"}:
        raise SystemExit(1)
    if segment[1] == "-n":
        scripts = segment[2:]
    elif len(segment) == 2:
        scripts = segment[1:]
    else:
        raise SystemExit(1)
    if not scripts or any(
        not script or script.startswith("-") or any(mark in script for mark in ("$", "`"))
        for script in scripts
    ):
        raise SystemExit(1)
raise SystemExit(0)
PY
}

# These are conservative lexical prefilters for deferred legacy routes.  The
# route parser remains authoritative; a false positive only spends the route's
# existing validation cost, while a false negative must never skip a protected
# capability. The Go planner exposes exact parsed capability values.
deferred_route_gate_mode_shape() {
  [ "${plan_status:-}" -eq 3 ] || return 1
  [[ "${plan_output:-}" == *'"gate-mode"'* ]]
}

deferred_route_lifecycle_shape() {
  local executable="${1:-}"
  # Inspect only the visible executable token.  Matching lifecycle names
  # anywhere in a command incorrectly deferred ordinary operands such as
  # `./tools/eci-review-gate.sh verify`; canonical identity/ownership checks
  # remain authoritative after this cheap prefilter.
  executable="${executable%%[[:space:]]*}"
  case "$executable" in
    eci-active|eci-active-gate.sh|eci-review-gate|eci-review-gate.sh|eci-stage|stop-gate.sh|ate-orchestrator-gate.sh|\
    */bin/eci-active|*/bin/eci-review-gate|*/bin/eci-stage|\
    */hooks/eci-active-gate.sh|*/hooks/eci-review-gate.sh|*/hooks/stop-gate.sh|*/hooks/ate-orchestrator-gate.sh)
      return 0 ;;
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
  if [[ "${1:-}" =~ ^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*= ]]; then
    return 0
  fi
  case "${1:-}" in
    env\ [A-Za-z_]*=*\ *|env\ -i\ *|env\ -u\ [A-Za-z_]*\ *|env\ --\ *) return 1 ;;
    env|env\ *|printenv|printenv\ *|*\ env\ *|*\ printenv\ *) return 0 ;;
    *) return 1 ;;
  esac
}

deferred_route_git_shape() {
  # Raw Git never has a generic planner fast capability. Every caller-selected
  # Git argv stays on the identity-aware provider route.
  local executable="${1#"${1%%[![:space:]]*}"}"
  executable="${executable%%[[:space:]]*}"
  case "$executable" in
    git|*/git) ;;
    *) return 1 ;;
  esac
  case "${1:-}" in
    git|git\ *|*/git|*/git\ *|*\ git\ *|*\/git\ *) return 0 ;;
    *) return 1 ;;
  esac
}

# The compiled planner has classified this active coordinator Git read as a
# capability-free defer. Revalidate the one finite approved-root pathspec form
# here before the legacy inspection adapter: its historical sixteen-path bound
# is only fallback parser capacity, not an effect boundary. If the planner is
# unavailable or falls back transparently, this route stays inactive and the
# legacy bound remains unchanged.
planner_admitted_coordinator_git_read_route() {
  [ "${hook_is_subagent:-false}" != true ] || return 1
  [ "${plan_role:-}" = coordinator ] || return 1
  [ "${plan_marker_state:-inactive}" = active ] || return 1
  [ "${#syntax_eci_markers[@]}" -gt 0 ] || return 1
  [ "${CODEX_PLAN_TRANSPARENT_FALLBACK:-false}" != true ] || return 1
  [ "${plan_status:-1}" -eq 3 ] || return 1
  jq -e '
    type == "object" and
    .decision == "defer" and
    (.diagnostic == null) and
    ((.capabilities // []) | type == "array" and length == 0)
  ' <<<"${plan_output:-}" >/dev/null 2>&1 || return 1
  trusted_executable_on_path git || return 1
  python3 - "$1" "$cwd" \
    "$CODEX_APPROVED_REPO_ROOT_1" "$CODEX_APPROVED_REPO_ROOT_2" "$CODEX_APPROVED_REPO_ROOT_3" <<'PY'
import os
import shlex
import sys

command, hook_cwd, *approved_roots = sys.argv[1:]
try:
    lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    tokens = list(lexer)
except ValueError:
    raise SystemExit(1)

operators = {";", "&", "&&", "||", "|", "(", ")", ">", ">>", ">|",
             ">&", "<", "<<", "<<<", "<&"}
if (not tokens or any(token in operators for token in tokens) or
        len(tokens) < 6 or tokens[:2] != ["git", "-C"] or
        tokens[3:5] != ["diff", "--"]):
    raise SystemExit(1)

repo = tokens[2]
if (not repo or not os.path.isabs(repo) or os.path.normpath(repo) != repo or
        not os.path.isdir(repo) or os.path.islink(repo) or
        os.path.realpath(repo) != repo or repo not in approved_roots):
    raise SystemExit(1)

paths = tokens[5:]
if len(paths) <= 16:
    raise SystemExit(1)
for path in paths:
    if (not path or path.startswith(("-", "/", "~", ":")) or
            any(mark in path for mark in ("$", "`", "\\", "*", "?", "[", "]", "(", ")")) or
            any(ord(character) < 0x20 for character in path) or
            os.path.normpath(path) != path or
            any(component in {"", ".", ".."} for component in path.split("/"))):
        raise SystemExit(1)
raise SystemExit(0)
PY
}

git_legacy_route_shape() {
  # Compound read-only batches are complete planner decisions and stay on the
  # generic fast path. A direct Git argv that lacks its exact compiled
  # capability must retain the provider Git adapter (notably archive output,
  # remote, executable, and inherited-context forms).
  case "${1:-}" in
    *';'*|*'&&'*|*'||'*|*'|'*) return 1 ;;
  esac
  # A transparent env prefix changes the executable/context identity used by
  # the Git adapter, so every env-wrapped Git invocation stays on that route.
  case "${1:-}" in
    env\ git\ *|env\ [A-Za-z_][A-Za-z0-9_]*=*\ git\ *|\
    env\ -i\ *\ git\ *|env\ -u\ *\ git\ *|env\ --\ git\ *)
      return 0 ;;
  esac
  deferred_route_git_shape "$1"
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
    *install-pre-commit-go-mod.sh*|*pre-commit-go-mod.sh*) return 0 ;;
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

deferred_worker_environment_child_wrapper_shape() {
  local child
  child="$(python3 - "${1:-}" <<'PY'
import re
import shlex
import sys

try:
    values = shlex.split(sys.argv[1], posix=True)
except ValueError:
    raise SystemExit(1)
if not values or values[0] != "env":
    raise SystemExit(1)

index = 1
while index < len(values):
    token = values[index]
    if token == "--":
        index += 1
        break
    if token in {"-i", "--ignore-environment"}:
        index += 1
        continue
    if token in {"-u", "--unset", "-C", "--chdir"}:
        index += 2
        continue
    if token.startswith(("--unset=", "--chdir=")):
        index += 1
        continue
    if token.startswith("-"):
        raise SystemExit(1)
    if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=.*", token):
        index += 1
        continue
    break
if index >= len(values):
    raise SystemExit(1)
print(values[index])
PY
  )" || return 1
  case "$child" in
    */*|printenv|command|builtin|exec|bash|bash/*|*/bash|sh|sh/*|*/sh|dash|dash/*|*/dash|zsh|zsh/*|*/zsh|ksh|ksh/*|*/ksh|ash|ash/*|*/ash|fish|fish/*|*/fish|timeout|time|nice|nohup|setsid|sudo|doas|systemd-run|xargs|find)
      return 0 ;;
    *) return 1 ;;
  esac
}

deferred_worker_wrapper_shape() {
  # Transparent launch wrappers are a worker-only ownership boundary. The
  # coordinator uses the dedicated shell/opaque routes below, which preserve
  # its existing-script manifest check without suppressing a planner-approved
  # absent-script argv.
  [ "${plan_role:-coordinator}" = worker ] || return 1
  if [ "${plan_marker_state:-inactive}" = active ] &&
    [ "${plan_status:-1}" -eq 0 ]; then
    case "${1:-}" in
      env|env\ *)
        if [ "${ECI_ENVIRONMENT_BOUNDARY_CHECKED:-false}" != true ]; then
          enforce_environment_command_boundary
        fi
        case "${ECI_ENVIRONMENT_COMMAND_STATE:-}" in
          ALLOW|WRAPPER)
            deferred_worker_environment_child_wrapper_shape "$1" && return 0
            return 1
            ;;
        esac
        ;;
    esac
  fi
  case "${1:-}" in
    env|env\ *|printenv|printenv\ *|command|command\ *|builtin|builtin\ *|exec|exec\ *|\
    bash|bash\ *|sh|sh\ *|dash|dash\ *|zsh|zsh\ *|ksh|ksh\ *|ash|ash\ *|fish|fish\ *|\
    */bash|*/bash\ *|*/sh|*/sh\ *|*/dash|*/dash\ *|*/zsh|*/zsh\ *|\
    timeout|timeout\ *|time|time\ *|nice|nice\ *|prlimit|prlimit\ *|nohup|nohup\ *|\
    setsid|setsid\ *|sudo|sudo\ *|doas|doas\ *|systemd-run|systemd-run\ *|\
    xargs|xargs\ *|*' -c '*|*' --command '*|*' --eval '*|*' --execute '*) return 0 ;;
    *) return 1 ;;
  esac
}

# raw_shell_script_token_shape is a conservative lexical prefilter for shell
# interpreter launches. It intentionally checks every parsed token rather than
# trying to duplicate the Go transparent-wrapper grammar in Bash: a benign
# operand may spend the legacy classifier cost, but a new wrapper can never
# skip the reviewed-script ownership route.
raw_shell_script_token_shape() {
  python3 - "${1:-}" <<'PY'
import os
import re
import shlex
import sys

try:
    lexer = shlex.shlex(sys.argv[1], posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    tokens = list(lexer)
except ValueError:
    raise SystemExit(0)

shells = {"ash", "bash", "dash", "fish", "ksh", "sh", "zsh"}
raise SystemExit(0 if any(os.path.basename(token) in shells for token in tokens) else 1)
PY
}

# Shell interpreters execute a second program payload, so every apparent shell
# launch stays on the reviewed-script ownership route. The broad prefilter
# also covers transparent wrappers without a duplicated wrapper-name list.
shell_script_launcher_shape() {
  raw_shell_script_token_shape "${1:-}" && return 0
  case "${1:-}" in
    ./*.sh|./*/*.sh|/*.sh|/*/*.sh) return 0 ;;
    *) return 1 ;;
  esac
}

# Transparent launchers still add an execution layer even when their visible
# argv is finite. Keep them on the existing ownership route; unlike `env` with
# a literal ordinary child, these wrappers must not become generic fast-path
# approvals. Shell interpreters are handled by shell_script_launcher_shape.
opaque_launcher_shape() {
  case "${1:-}" in
    command|command\ *|builtin|builtin\ *|exec|exec\ *|timeout|timeout\ *|time|time\ *|nice|nice\ *|prlimit|prlimit\ *|nohup|nohup\ *|setsid|setsid\ *|sudo|sudo\ *|doas|doas\ *|systemd-run|systemd-run\ *) return 0 ;;
    env\ [A-Za-z_]*=*\ command\ *|env\ [A-Za-z_]*=*\ builtin\ *|env\ [A-Za-z_]*=*\ exec\ *|env\ [A-Za-z_]*=*\ timeout\ *|env\ [A-Za-z_]*=*\ time\ *|env\ [A-Za-z_]*=*\ nice\ *|env\ [A-Za-z_]*=*\ prlimit\ *|env\ [A-Za-z_]*=*\ nohup\ *|env\ [A-Za-z_]*=*\ setsid\ *|env\ [A-Za-z_]*=*\ sudo\ *|env\ [A-Za-z_]*=*\ doas\ *|env\ [A-Za-z_]*=*\ systemd-run\ *) return 0 ;;
    env\ -i\ *\ command\ *|env\ -i\ *\ builtin\ *|env\ -i\ *\ exec\ *|env\ -i\ *\ timeout\ *|env\ -i\ *\ time\ *|env\ -i\ *\ nice\ *|env\ -i\ *\ prlimit\ *|env\ -i\ *\ nohup\ *|env\ -i\ *\ setsid\ *|env\ -i\ *\ sudo\ *|env\ -i\ *\ doas\ *|env\ -i\ *\ systemd-run\ *) return 0 ;;
    env\ -u\ *\ command\ *|env\ -u\ *\ builtin\ *|env\ -u\ *\ exec\ *|env\ -u\ *\ timeout\ *|env\ -u\ *\ time\ *|env\ -u\ *\ nice\ *|env\ -u\ *\ prlimit\ *|env\ -u\ *\ nohup\ *|env\ -u\ *\ setsid\ *|env\ -u\ *\ sudo\ *|env\ -u\ *\ doas\ *|env\ -u\ *\ systemd-run\ *) return 0 ;;
    env\ --\ command\ *|env\ --\ builtin\ *|env\ --\ exec\ *|env\ --\ timeout\ *|env\ --\ time\ *|env\ --\ nice\ *|env\ --\ prlimit\ *|env\ --\ nohup\ *|env\ --\ setsid\ *|env\ --\ sudo\ *|env\ --\ doas\ *|env\ --\ systemd-run\ *) return 0 ;;
    *) return 1 ;;
  esac
}

deferred_worker_control_shape() {
  case "${1:-}" in
    *eci_active*|*goal_state*|*eci_wait*|*eci-required-critics*|*eci-critic-identities*|\
    *eci-acceptance-*|*baseline_head*|*proof.md*|*instructions.md*|*stop_timestamps*|\
    *stop_loop_state*|*disengage.md*|*user-closed.md*|*project-understanding.md*|\
    *high_level_log*|*latest-status-report*|*eci_user_owned_wait*|\
    *eci-teardown-complete*|*eci-baseline-binding*|*eci-commit-admitted*|*eci-aggregate*) return 0 ;;
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

# A parser that cannot classify ordinary shell spelling must not turn
# punctuation, wrappers, interpreter switches, option grammar, or an unknown
# worker utility into a command allowlist boundary.  Later target-aware routes
# still catch named control/proof, cross-scope write, and broad destructive
# operations.  This list intentionally excludes those concrete-target
# diagnostics for every role.
if [ "${#syntax_eci_markers[@]}" -gt 0 ] && [ "$plan_status" -eq 2 ] && jq -e '
    .diagnostic.code as $code |
    $code == "ECI_PLAN_SYNTAX_DENIED" or
    $code == "ECI_PLAN_LIMIT_DENIED" or
    $code == "ECI_PLAN_WRAPPER_DENIED" or
    ($code == "ECI_PLAN_DYNAMIC_LAUNCH_DENIED" and
      (.diagnostic.predicate // "") != "dynamic-find-action") or
    $code == "ECI_PLAN_STAT_FORMAT_DENIED" or
    $code == "ECI_PLAN_FILE_OPTION_DENIED" or
    $code == "ECI_PLAN_UNIQ_ARGUMENTS_DENIED" or
    $code == "ECI_ENVIRONMENT_ENUMERATION_DENIED" or
    $code == "ECI_ENVIRONMENT_NAME_DENIED" or
    $code == "ECI_ENVIRONMENT_OPTION_DENIED" or
    $code == "ECI_ENVIRONMENT_CONTEXT_DENIED" or
    $code == "ECI_COMMAND_NOT_ALLOWLISTED" or
    $code == "ECI_WORKER_COMMAND_NOT_ALLOWLISTED"
  ' <<<"${plan_output:-}" >/dev/null 2>&1; then
  planner_mark_transparent_fallback
fi

# Preserve the concrete capability result before any planner/fallback branch
# can select a generic coordinator fast exit.  When the compiled planner is
# unavailable, a compound whose later segment mutates still needs the named
# coordinator inspection/cleanup route below; a harmless compound remains
# transparent.
if coordinator_compound_mutation_shape "$command"; then
  coordinator_compound_mutation=true
fi

# Planner diagnostics are authoritative. Forward a specific malformed,
# dynamic, protected, or limit denial before examining any legacy shell shape.
if [ "${#syntax_eci_markers[@]}" -gt 0 ] &&
  [ "$plan_status" -eq 2 ] &&
  [ "$CODEX_PLAN_TRANSPARENT_FALLBACK" != true ]; then
  if plan_denial="$(command_plan_pretooluse_denial "$plan_output")"; then
    finalize_command_gate_denial parser "$plan_denial"
    exit 0
  fi
  planner_mark_transparent_fallback
fi

# A bounded compound plan is owned by the compiled planner's lossless parser,
# not by punctuation heuristics in this adapter. Replay every parser-attested
# direct segment through its ordinary route before deciding the whole plan.
# This keeps all named routes intact and prevents an early harmless segment
# from fast-exiting past a later cleanup, Git, source-write, proof/control,
# lifecycle, script, or environment segment.
coordinator_static_pipeline_candidate=false
worker_read_only_pipeline_candidate=false
if planner_compound_pipeline_topology_is_valid && ! planner_compound_git_worktree_candidate; then
  if [ "$hook_is_subagent" != true ]; then
    coordinator_static_pipeline_candidate=true
  else
    worker_read_only_pipeline_candidate=true
  fi
fi
if [ "${#syntax_eci_markers[@]}" -gt 0 ] && [ "$PLAN_REVIEWED_SCRIPT_COMPOUND_ROUTE" != true ] &&
  planner_compound_topology_is_valid && ! planner_compound_git_worktree_candidate; then
  if validate_planner_compound_segments; then
    validate_active_marker_binding
    exit 0
  else
    compound_segment_status=$?
  fi
  if [ "$compound_segment_status" -eq 1 ] && [ -n "$PLANNER_COMPOUND_SEGMENT_DENIAL" ]; then
    finalize_command_gate_denial compound-segment "$PLANNER_COMPOUND_SEGMENT_DENIAL"
    exit 0
  fi
  plan_status=3
  plan_output=""
  CODEX_PLAN_TRANSPARENT_FALLBACK=true
  PLAN_CODEX_LIFECYCLE_ROUTE=true
  coordinator_static_pipeline_candidate=false
  worker_read_only_pipeline_candidate=false
fi

# Missing topology is parser diagnostic information, not a permission
# boundary.  A complete topology above gets segment-by-segment target checks;
# an incomplete one continues to the target-aware routes below.  This keeps a
# harmless command from becoming a denial because a parser build is stale or
# does not understand its spelling.

foreign_active_marker_static_assignment() {
  [[ "${1:-}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]
}

foreign_active_marker_dynamic_text() {
  case "${1:-}" in
    *'$'*|*'`'*|*'~'*|*'?'|*'['*|*']'*|*'*'*|*'{'*|*'}'*) return 0 ;;
    *) return 1 ;;
  esac
}

foreign_active_marker_literal_env_name() {
  [[ "${1:-}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
}

foreign_active_marker_literal_env_assignment() {
  foreign_active_marker_static_assignment "$1" || return 1
  foreign_active_marker_dynamic_text "$1" && return 1
  return 0
}

foreign_active_marker_literal_existing_directory() {
  local raw="$1" base="$2" candidate resolved

  [ -n "$raw" ] || return 1
  foreign_active_marker_dynamic_text "$raw" && return 1
  if [[ "$raw" = /* ]]; then
    candidate="$raw"
  else
    [ -n "$base" ] || return 1
    candidate="$base/$raw"
  fi
  resolved="$(realpath -e -- "$candidate" 2>/dev/null || true)"
  [ -n "$resolved" ] && [ -d "$resolved" ] || return 1
  printf '%s\n' "$resolved"
}

# Resolve a literal candidate before deriving its owner.  The proof-state
# validators own the Codex session grammar; the small provider-neutral record
# check below applies the same bounded path, owner, and CWD facts to Kimi's
# configured proof root.
foreign_active_marker_provider_metadata_is_valid() {
  local root="$1" marker="$2" session="$3" line marker_cwd marker_owner scope
  local session_count=0 cwd_count=0
  [ -d "$root" ] && [ ! -L "$root" ] || return 1
  [ "$(realpath -e -- "$root" 2>/dev/null || true)" = "$root" ] || return 1
  [ "$marker" = "$root/$session/eci_active" ] || return 1
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  [ "$(realpath -e -- "$marker" 2>/dev/null || true)" = "$marker" ] || return 1
  codex_valid_session_id "$session" || return 1
  IFS= read -r line <"$marker" || return 1
  case "$line" in
    'scope: '*)
      scope="${line#scope: }"
      [ -n "$scope" ] || return 1
      ;;
    *)
      return 1
      ;;
  esac
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      'scope: '*)
        scope="${line#scope: }"
        [ -n "$scope" ] || return 1
        ;;
      'session_id: '*)
        marker_owner="${line#session_id: }"
        session_count=$((session_count + 1))
        [ "$marker_owner" = "$session" ] || return 1
        ;;
      'cwd: '*)
        marker_cwd="${line#cwd: }"
        cwd_count=$((cwd_count + 1))
        [ -n "$marker_cwd" ] && [[ "$marker_cwd" = /* ]] || return 1
        [ "$(realpath -e -- "$marker_cwd" 2>/dev/null || true)" = "$marker_cwd" ] || return 1
        [ -d "$marker_cwd" ] && [ ! -L "$marker_cwd" ] && [ -x "$marker_cwd" ] || return 1
        ;;
    esac
  done <"$marker"
  [ "$session_count" -eq 1 ] && [ "$cwd_count" -eq 1 ]
}

foreign_active_marker_candidate_detail() {
  local raw="$1" base="$2" current_session="$3" candidate proof_root foreign_session foreign_marker foreign_root root
  local -a provider_roots=()

  [ -n "$raw" ] || return 1
  foreign_active_marker_dynamic_text "$raw" && return 1
  if [[ "$raw" = /* ]]; then
    candidate="$raw"
  else
    [ -n "$base" ] || return 1
    candidate="$base/$raw"
  fi
  candidate="$(realpath -e -- "$candidate" 2>/dev/null || true)"
  [ -n "$candidate" ] || return 1
  proof_root="$(realpath -e -- "$(codex_proof_root)" 2>/dev/null || true)"
  [ -n "$proof_root" ] && provider_roots+=("$proof_root")
  for root in "${KIMI_PROOF_ROOT:-}" "${KIMI_PROOF_ROOT_CANONICAL:-}" \
    "${KIMI_PROOF_ROOT_CONFIGURED:-}" "${KIMI_PROOF_ROOT_STABLE_ALIAS:-}"; do
    [ -n "$root" ] || continue
    root="$(realpath -e -- "$root" 2>/dev/null || true)"
    [ -n "$root" ] || continue
    case " ${provider_roots[*]} " in
      *" $root "*) continue ;;
    esac
    provider_roots+=("$root")
  done
  for root in "${provider_roots[@]}"; do
    case "$candidate" in
      "$root"/*/eci_active)
        foreign_session="${candidate#"$root"/}"
        foreign_session="${foreign_session%/eci_active}"
        [ "$foreign_session" != "$current_session" ] || return 1
        if [ "$root" = "$proof_root" ]; then
          codex_eci_marker_metadata_is_valid "$candidate" || return 1
          codex_eci_direct_marker_cwd "$candidate" "$foreign_session" >/dev/null || return 1
        else
          foreign_active_marker_provider_metadata_is_valid "$root" "$candidate" "$foreign_session" || return 1
        fi
        printf 'target=%s foreign_session=%s provider_root=%s\n' "$candidate" "$foreign_session" "$root"
        return 0
        ;;
    esac
  done

  # A hardlink retains the marker's device/inode identity even when its
  # ordinary pathname has no marker spelling. Reuse the bounded Codex marker
  # candidate list and Bash's native same-file identity comparison.
  while IFS= read -r foreign_marker; do
    [ -f "$foreign_marker" ] && [ ! -L "$foreign_marker" ] || continue
    if [ "$candidate" -ef "$foreign_marker" ]; then
      candidate="$foreign_marker"
      break
    fi
  done < <(
    codex_eci_marker_candidates_bounded
    for root in "${KIMI_PROOF_ROOT:-}" "${KIMI_PROOF_ROOT_CANONICAL:-}" \
      "${KIMI_PROOF_ROOT_CONFIGURED:-}" "${KIMI_PROOF_ROOT_STABLE_ALIAS:-}"; do
      [ -n "$root" ] || continue
      root="$(realpath -e -- "$root" 2>/dev/null || true)"
      [ -n "$root" ] && [ -d "$root" ] || continue
      find "$root" -mindepth 2 -maxdepth 2 -name eci_active -type f -print 2>/dev/null || true
    done
  )
  foreign_root=""
  for root in "$proof_root" "${KIMI_PROOF_ROOT:-}" "${KIMI_PROOF_ROOT_CANONICAL:-}" \
    "${KIMI_PROOF_ROOT_CONFIGURED:-}" "${KIMI_PROOF_ROOT_STABLE_ALIAS:-}"; do
    [ -n "$root" ] || continue
    root="$(realpath -e -- "$root" 2>/dev/null || true)"
    case "$candidate" in
      "$root"/*/eci_active) foreign_root="$root"; break ;;
    esac
  done
  [ -n "$foreign_root" ] || return 1
  foreign_session="${candidate#"$foreign_root"/}"
  foreign_session="${foreign_session%/eci_active}"
  [ "$foreign_session" != "$current_session" ] || return 1
  if [ "$foreign_root" = "$proof_root" ]; then
    codex_eci_marker_metadata_is_valid "$candidate" || return 1
    codex_eci_direct_marker_cwd "$candidate" "$foreign_session" >/dev/null || return 1
  else
    foreign_active_marker_provider_metadata_is_valid "$foreign_root" "$candidate" "$foreign_session" || return 1
  fi
  printf 'target=%s foreign_session=%s provider_root=%s\n' "$candidate" "$foreign_session" "$foreign_root"
}

FOREIGN_ACTIVE_MARKER_WRITER_FORCE=false
FOREIGN_ACTIVE_MARKER_WRITER_OPERANDS=()

# Decode only the finite zero-arity flags whose target positions are known.
# `--` is a terminator, not an operand filter: literal paths on either side
# remain visible to the extractor.
foreign_active_marker_writer_operands() {
  local flag_mode="$1" token options_ended=false
  shift

  FOREIGN_ACTIVE_MARKER_WRITER_FORCE=false
  FOREIGN_ACTIVE_MARKER_WRITER_OPERANDS=()
  for token in "$@"; do
    if [ "$options_ended" = false ]; then
      if [ "$token" = -- ]; then
        options_ended=true
        continue
      fi
      case "$flag_mode" in
        rm-cp)
          case "$token" in
            -f|-r|-R|-v|-a|--force|--recursive|--verbose|--archive) continue ;;
          esac
          if [[ "$token" =~ ^-[frR]+$ ]]; then
            continue
          fi
          ;;
        tee)
          case "$token" in
            -a|-i|-p|--append|--ignore-interrupts) continue ;;
          esac
          if [[ "$token" =~ ^-[ai]+$ ]]; then
            continue
          fi
          ;;
        force)
          case "$token" in
            -f|--force)
              FOREIGN_ACTIVE_MARKER_WRITER_FORCE=true
              continue
              ;;
          esac
          ;;
      esac
      case "$token" in
        -*) return 1 ;;
      esac
    fi
    FOREIGN_ACTIVE_MARKER_WRITER_OPERANDS+=("$token")
  done
}

foreign_active_marker_touch_targets() {
  local token options_ended=false skip=0
  FOREIGN_ACTIVE_MARKER_WRITER_OPERANDS=()
  for token in "$@"; do
    if [ "$skip" -gt 0 ]; then
      skip=0
      continue
    fi
    if [ "$options_ended" = false ]; then
      case "$token" in
        --) options_ended=true; continue ;;
        -a|-m|-c|-h) continue ;;
        -d|-t|--date|--time) skip=1; continue ;;
        --date=*|--time=*|-d?*|-t?*) continue ;;
        -*) return 1 ;;
      esac
    fi
    FOREIGN_ACTIVE_MARKER_WRITER_OPERANDS+=("$token")
  done
  [ "$skip" -eq 0 ]
}

foreign_active_marker_truncate_targets() {
  local token options_ended=false skip=0
  FOREIGN_ACTIVE_MARKER_WRITER_OPERANDS=()
  for token in "$@"; do
    if [ "$skip" -gt 0 ]; then
      skip=0
      continue
    fi
    if [ "$options_ended" = false ]; then
      case "$token" in
        --) options_ended=true; continue ;;
        -c|--no-create) continue ;;
        -s|--size) skip=1; continue ;;
        -s?*|--size=*) continue ;;
        -*) return 1 ;;
      esac
    fi
    FOREIGN_ACTIVE_MARKER_WRITER_OPERANDS+=("$token")
  done
  [ "$skip" -eq 0 ]
}

foreign_active_marker_sed_targets() {
  local token options_ended=false in_place=false script_seen=false skip=0
  FOREIGN_ACTIVE_MARKER_WRITER_OPERANDS=()
  for token in "$@"; do
    if [ "$skip" -gt 0 ]; then
      skip=0
      continue
    fi
    if [ "$options_ended" = false ]; then
      case "$token" in
        --) options_ended=true; continue ;;
        -i|--in-place|-i?*|--in-place=*) in_place=true; continue ;;
        -e|--expression|-f|--file) skip=1; script_seen=true; continue ;;
        -e?*|-f?*|--expression=*|--file=*) script_seen=true; continue ;;
        -n|--quiet|--silent) continue ;;
        -*) return 1 ;;
      esac
    fi
    if [ "$script_seen" = false ]; then
      script_seen=true
      continue
    fi
    FOREIGN_ACTIVE_MARKER_WRITER_OPERANDS+=("$token")
  done
  [ "$in_place" = true ] && [ "$script_seen" = true ]
}

foreign_active_marker_dd_target() {
  local operand key value seen_keys=" " output=""

  foreign_active_marker_writer_operands none "$@" || return 1
  for operand in "${FOREIGN_ACTIVE_MARKER_WRITER_OPERANDS[@]}"; do
    case "$operand" in
      *=*) ;;
      *) return 1 ;;
    esac
    key="${operand%%=*}"
    value="${operand#*=}"
    [ -n "$value" ] || return 1
    foreign_active_marker_dynamic_text "$value" && return 1
    case "$key" in
      of|if|bs|cbs|conv|count|ibs|iflag|skip|iseek|obs|oflag|seek|oseek|status) ;;
      *) return 1 ;;
    esac
    case " $seen_keys " in
      *" $key "*) return 1 ;;
    esac
    seen_keys+="$key "
    if [ "$key" = of ]; then
      output="$value"
    fi
  done
  [ -n "$output" ] || return 1
  printf '%s\n' "$output"
}

foreign_active_marker_writer_targets() {
  local command_name="$1" target index
  shift

  case "$command_name" in
    rm)
      foreign_active_marker_writer_operands rm-cp "$@" || return 0
      for target in "${FOREIGN_ACTIVE_MARKER_WRITER_OPERANDS[@]}"; do
        printf '%s\n' "$target"
      done
      ;;
    shred)
      foreign_active_marker_writer_operands none "$@" || return 0
      for target in "${FOREIGN_ACTIVE_MARKER_WRITER_OPERANDS[@]}"; do
        printf '%s\n' "$target"
      done
      ;;
    touch)
      foreign_active_marker_touch_targets "$@" || return 0
      for target in "${FOREIGN_ACTIVE_MARKER_WRITER_OPERANDS[@]}"; do
        printf '%s\n' "$target"
      done
      ;;
    truncate)
      foreign_active_marker_truncate_targets "$@" || return 0
      for target in "${FOREIGN_ACTIVE_MARKER_WRITER_OPERANDS[@]}"; do
        printf '%s\n' "$target"
      done
      ;;
    unlink)
      foreign_active_marker_writer_operands none "$@" || return 0
      [ "${#FOREIGN_ACTIVE_MARKER_WRITER_OPERANDS[@]}" -eq 1 ] || return 0
      printf '%s\n' "${FOREIGN_ACTIVE_MARKER_WRITER_OPERANDS[0]}"
      ;;
    chmod|chown)
      foreign_active_marker_writer_operands none "$@" || return 0
      [ "${#FOREIGN_ACTIVE_MARKER_WRITER_OPERANDS[@]}" -ge 2 ] || return 0
      for ((index = 1; index < ${#FOREIGN_ACTIVE_MARKER_WRITER_OPERANDS[@]}; index++)); do
        printf '%s\n' "${FOREIGN_ACTIVE_MARKER_WRITER_OPERANDS[$index]}"
      done
      ;;
    tee)
      foreign_active_marker_writer_operands tee "$@" || return 0
      for target in "${FOREIGN_ACTIVE_MARKER_WRITER_OPERANDS[@]}"; do
        printf '%s\n' "$target"
      done
      ;;
    dd)
      foreign_active_marker_dd_target "$@" || return 0
      ;;
    cp)
      foreign_active_marker_writer_operands rm-cp "$@" || return 0
      [ "${#FOREIGN_ACTIVE_MARKER_WRITER_OPERANDS[@]}" -eq 2 ] || return 0
      printf '%s\n' "${FOREIGN_ACTIVE_MARKER_WRITER_OPERANDS[1]}"
      ;;
    install)
      foreign_active_marker_writer_operands none "$@" || return 0
      [ "${#FOREIGN_ACTIVE_MARKER_WRITER_OPERANDS[@]}" -eq 2 ] || return 0
      printf '%s\n' "${FOREIGN_ACTIVE_MARKER_WRITER_OPERANDS[1]}"
      ;;
    sed)
      foreign_active_marker_sed_targets "$@" || return 0
      for target in "${FOREIGN_ACTIVE_MARKER_WRITER_OPERANDS[@]}"; do
        printf '%s\n' "$target"
      done
      ;;
    mv)
      foreign_active_marker_writer_operands none "$@" || return 0
      [ "${#FOREIGN_ACTIVE_MARKER_WRITER_OPERANDS[@]}" -eq 2 ] || return 0
      for target in "${FOREIGN_ACTIVE_MARKER_WRITER_OPERANDS[@]}"; do
        printf '%s\n' "$target"
      done
      ;;
    ln)
      foreign_active_marker_writer_operands force "$@" || return 0
      [ "$FOREIGN_ACTIVE_MARKER_WRITER_FORCE" = true ] || return 0
      [ "${#FOREIGN_ACTIVE_MARKER_WRITER_OPERANDS[@]}" -eq 2 ] || return 0
      printf '%s\n' "${FOREIGN_ACTIVE_MARKER_WRITER_OPERANDS[1]}"
      ;;
  esac
  return 0
}

FOREIGN_ACTIVE_MARKER_TIMEOUT_CHILD_CWD=""
FOREIGN_ACTIVE_MARKER_TIMEOUT_CHILD_WORDS=()
FOREIGN_ACTIVE_MARKER_ENV_CHILD_EXECUTABLE=""
FOREIGN_ACTIVE_MARKER_ENV_CHILD_ARGS_INDEX=-1
FOREIGN_ACTIVE_MARKER_ENV_CHILD_CWD=""

foreign_active_marker_observed_timeout_child() {
  local segment_index="$1" timeout_index="$2" record replay_cwd index
  shift 2
  local -a segment_words=("$@") replay_values=() replay_prefix=()

  [ "$timeout_index" -lt "${#segment_words[@]}" ] || return 1
  [ "${segment_words[$timeout_index]##*/}" = timeout ] || return 1
  record="$(jq -cer --argjson segment "$segment_index" '
    def bounded_integer: type == "number" and floor == . and . >= 1 and . <= 8;
    def valid_record:
      if type != "object" then false else
        ((keys | sort == ["command_path", "command_path_exported", "command_path_set", "cwd", "disposition", "parent_segment", "prefix", "segment"]) or
         (keys | sort == ["command_path", "command_path_exported", "command_path_set", "cwd", "cwd_physical", "disposition", "parent_segment", "prefix", "segment"])) and
        (.segment | bounded_integer) and
        (.parent_segment | bounded_integer) and
        (.prefix | type == "array" and length >= 2 and length <= 128 and all(.[]; type == "string" and length > 0 and length <= 4096)) and
        (.cwd | type == "string" and startswith("/")) and
        (.cwd_physical? // "" | type == "string" and (length == 0 or startswith("/"))) and
        (.command_path | type == "string") and
        (.command_path_set | type == "boolean") and
        (.command_path_exported | type == "boolean") and
        (if .command_path_set then true else (.command_path == "" and .command_path_exported == false) end)
      end;
    if type == "array" then
      [.[] | select(if valid_record then (.segment == $segment and .disposition == "observed") else false end)] |
      if length == 1 then .[0] else empty end
    else empty end
  ' <<<"$FOREIGN_ACTIVE_MARKER_TIMEOUT_REPLAYS" 2>/dev/null)" || return 1
  mapfile -t replay_values < <(jq -r '.cwd, .prefix[]' <<<"$record" 2>/dev/null)
  replay_cwd="${replay_values[0]:-}"
  replay_prefix=("${replay_values[@]:1}")
  [ "${#replay_prefix[@]}" -ge 2 ] && [ "${#replay_prefix[@]}" -lt "${#segment_words[@]}" ] || return 1
  for index in "${!replay_prefix[@]}"; do
    [ "${replay_prefix[$index]}" = "${segment_words[$index]}" ] || return 1
  done
  [ -n "$replay_cwd" ] || return 1
  FOREIGN_ACTIVE_MARKER_TIMEOUT_CHILD_CWD="$replay_cwd"
  FOREIGN_ACTIVE_MARKER_TIMEOUT_CHILD_WORDS=("${segment_words[@]:${#replay_prefix[@]}}")
}

# A timeout child is argv, not a shell fragment. Decode only the demonstrated
# standard env launch forms whose direct child and child CWD are finite.
# Everything else remains ordinary execution.
foreign_active_marker_env_child() {
  local base="$1" token name child_cwd split_word index=1 options_ended=false chdir_seen=false
  shift
  local -a words=("$@")

  FOREIGN_ACTIVE_MARKER_ENV_CHILD_EXECUTABLE=""
  FOREIGN_ACTIVE_MARKER_ENV_CHILD_ARGS_INDEX=-1
  FOREIGN_ACTIVE_MARKER_ENV_CHILD_CWD=""
  case "${words[0]:-}" in
    env|/usr/bin/env) ;;
    *) return 1 ;;
  esac
  child_cwd="$base"
  while [ "$index" -lt "${#words[@]}" ]; do
    token="${words[$index]}"
    if [ "$options_ended" = false ]; then
      case "$token" in
        --|-)
          options_ended=true
          index=$((index + 1))
          continue
          ;;
        -v|--debug|-i|--ignore-environment)
          index=$((index + 1))
          continue
          ;;
        -u|--unset)
          index=$((index + 1))
          [ "$index" -lt "${#words[@]}" ] || return 1
          name="${words[$index]}"
          foreign_active_marker_literal_env_name "$name" || return 1
          index=$((index + 1))
          continue
          ;;
        -u?*)
          name="${token#-u}"
          foreign_active_marker_literal_env_name "$name" || return 1
          index=$((index + 1))
          continue
          ;;
        --unset=*)
          name="${token#--unset=}"
          foreign_active_marker_literal_env_name "$name" || return 1
          index=$((index + 1))
          continue
          ;;
        -C|--chdir)
          [ "$chdir_seen" = false ] || return 1
          index=$((index + 1))
          [ "$index" -lt "${#words[@]}" ] || return 1
          token="${words[$index]}"
          child_cwd="$(foreign_active_marker_literal_existing_directory "$token" "$child_cwd")" || return 1
          chdir_seen=true
          index=$((index + 1))
          continue
          ;;
        -C?*)
          [ "$chdir_seen" = false ] || return 1
          token="${token#-C}"
          child_cwd="$(foreign_active_marker_literal_existing_directory "$token" "$child_cwd")" || return 1
          chdir_seen=true
          index=$((index + 1))
          continue
          ;;
        --chdir=*)
          [ "$chdir_seen" = false ] || return 1
          token="${token#--chdir=}"
          child_cwd="$(foreign_active_marker_literal_existing_directory "$token" "$child_cwd")" || return 1
          chdir_seen=true
          index=$((index + 1))
          continue
          ;;
        # Plain split-string forms remain ordinary. The only split syntax
        # modeled here is the separately demonstrated terminal-S v-family.
        -S|--split-string|-S?*|--split-string=*) return 1 ;;
        -*)
          if [[ "$token" =~ ^-v+$ ]]; then
            index=$((index + 1))
            continue
          fi
          if [[ "$token" =~ ^-v+S$ ]]; then
            index=$((index + 1))
            [ "$index" -lt "${#words[@]}" ] || return 1
            split_word="${words[$index]}"
          elif [[ "$token" =~ ^-v+S.+$ ]]; then
            split_word="${token#*-v}"
            split_word="${split_word#*S}"
          else
            return 1
          fi
          foreign_active_marker_dynamic_text "$split_word" && return 1
          [ -n "$split_word" ] && [[ "$split_word" != *[[:space:]]* ]] || return 1
          FOREIGN_ACTIVE_MARKER_ENV_CHILD_EXECUTABLE="$split_word"
          FOREIGN_ACTIVE_MARKER_ENV_CHILD_ARGS_INDEX=$((index + 1))
          FOREIGN_ACTIVE_MARKER_ENV_CHILD_CWD="$child_cwd"
          return 0
          ;;
        *)
          ;;
      esac
    fi
    if foreign_active_marker_literal_env_assignment "$token"; then
      options_ended=true
      index=$((index + 1))
      continue
    fi
    foreign_active_marker_static_assignment "$token" && return 1
    if [ "$options_ended" = true ] && [ "$token" = - ]; then
      index=$((index + 1))
      continue
    fi
    FOREIGN_ACTIVE_MARKER_ENV_CHILD_EXECUTABLE="$token"
    FOREIGN_ACTIVE_MARKER_ENV_CHILD_ARGS_INDEX=$((index + 1))
    FOREIGN_ACTIVE_MARKER_ENV_CHILD_CWD="$child_cwd"
    return 0
  done
  return 1
}

FOREIGN_ACTIVE_MARKER_CURRENT_SESSION=""
FOREIGN_ACTIVE_MARKER_TIMEOUT_REPLAYS='[]'
FOREIGN_ACTIVE_MARKER_DETAIL=""

# `direct_ledger_static_records ... foreign-marker` calls this private
# consumer in-process with its static lexical data. It deliberately has no
# independent record grammar.
foreign_active_marker_consume_ledger_segment() {
  local segment_index="$1"
  local writer_base="$cwd" redirect_base="$cwd" token_index=0 writer_args_index=-1 command_name="" timeout_opaque=false child_mode=false target detail
  local -a words=("${DIRECT_LEDGER_FOREIGN_WORDS[@]}") writer_targets=()

  [ "${#words[@]}" -gt 0 ] || return 0
  while [ "$token_index" -lt "${#words[@]}" ] &&
    foreign_active_marker_static_assignment "${words[$token_index]}"; do
    token_index=$((token_index + 1))
  done
  if [ "$token_index" -lt "${#words[@]}" ] && [ "${words[$token_index]##*/}" = timeout ]; then
    if foreign_active_marker_observed_timeout_child "$segment_index" "$token_index" "${words[@]}"; then
      words=("${FOREIGN_ACTIVE_MARKER_TIMEOUT_CHILD_WORDS[@]}")
      writer_base="$FOREIGN_ACTIVE_MARKER_TIMEOUT_CHILD_CWD"
      redirect_base="$FOREIGN_ACTIVE_MARKER_TIMEOUT_CHILD_CWD"
      token_index=0
      child_mode=true
    else
      timeout_opaque=true
    fi
  fi

  if [ "$timeout_opaque" = false ]; then
    if [ "$child_mode" = true ]; then
      case "${words[0]:-}" in
        env|/usr/bin/env)
          if foreign_active_marker_env_child "$writer_base" "${words[@]}"; then
            writer_args_index="$FOREIGN_ACTIVE_MARKER_ENV_CHILD_ARGS_INDEX"
            command_name="${FOREIGN_ACTIVE_MARKER_ENV_CHILD_EXECUTABLE##*/}"
            writer_base="$FOREIGN_ACTIVE_MARKER_ENV_CHILD_CWD"
          fi
          ;;
        *)
          if [ "${#words[@]}" -gt 0 ]; then
            command_name="${words[0]##*/}"
          fi
          ;;
      esac
    else
      while [ "$token_index" -lt "${#words[@]}" ] &&
        foreign_active_marker_static_assignment "${words[$token_index]}"; do
        token_index=$((token_index + 1))
      done
      if [ "$token_index" -lt "${#words[@]}" ]; then
        command_name="${words[$token_index]##*/}"
        case "$command_name" in
          env|command|builtin|exec)
            token_index=$((token_index + 1))
            while [ "$token_index" -lt "${#words[@]}" ] &&
              { foreign_active_marker_static_assignment "${words[$token_index]}" || [[ "${words[$token_index]}" = -* ]]; }; do
              token_index=$((token_index + 1))
            done
            [ "$token_index" -lt "${#words[@]}" ] || command_name=""
            [ -z "$command_name" ] || command_name="${words[$token_index]##*/}"
            ;;
        esac
      fi
    fi
    if [ -n "$command_name" ]; then
      if [ "$writer_args_index" -lt 0 ]; then
        writer_args_index=$((token_index + 1))
      fi
      mapfile -t writer_targets < <(foreign_active_marker_writer_targets "$command_name" "${words[@]:$writer_args_index}")
      for target in "${writer_targets[@]}"; do
        if detail="$(foreign_active_marker_candidate_detail "$target" "$writer_base" "$FOREIGN_ACTIVE_MARKER_CURRENT_SESSION" 2>/dev/null)"; then
          FOREIGN_ACTIVE_MARKER_DETAIL="$detail"
          return 0
        fi
      done
    fi
  fi

  for target in "${DIRECT_LEDGER_FOREIGN_REDIRECT_TARGETS[@]}"; do
    if detail="$(foreign_active_marker_candidate_detail "$target" "$redirect_base" "$FOREIGN_ACTIVE_MARKER_CURRENT_SESSION" 2>/dev/null)"; then
      FOREIGN_ACTIVE_MARKER_DETAIL="$detail"
      return 0
    fi
  done
  return 0
}

# Detect the one proof mutation that can accidentally disrupt another active
# session. This stays target-specific: ordinary source files and current
# session coordination notes do not match it.
foreign_active_marker_mutation_detail() {
  local command_text="$1" current_session="$2" timeout_replays="${3:-[]}"
  local resolution_cwd="${4-$cwd}" saved_cwd direct_status

  FOREIGN_ACTIVE_MARKER_CURRENT_SESSION="$current_session"
  FOREIGN_ACTIVE_MARKER_TIMEOUT_REPLAYS="$timeout_replays"
  FOREIGN_ACTIVE_MARKER_DETAIL=""
  # The foreign-marker walk shares the same planner-owned segment CWD as the
  # generic worker-control walk. Empty means unknown and deliberately leaves
  # relative operands unresolved while retaining absolute-target checks.
  saved_cwd="$cwd"
  cwd="$resolution_cwd"
  if direct_ledger_static_records "$command_text" foreign-marker >/dev/null; then
    direct_status=0
  else
    direct_status=$?
  fi
  cwd="$saved_cwd"
  [ "$direct_status" -eq 0 ] || return 1
  [ -n "$FOREIGN_ACTIVE_MARKER_DETAIL" ] || return 1
  printf '%s\n' "$FOREIGN_ACTIVE_MARKER_DETAIL"
}

# enforce_foreign_active_marker_mutation_boundary stops only a resolved write
# to another active session's marker. Both planner success and transparent
# fallback paths use it so unavailable planner protocol data cannot hide a
# cross-session effect.
enforce_foreign_active_marker_mutation_boundary() {
  local detail resolution_cwd
  local -a resolution_cwds=()

  [ "${#syntax_eci_markers[@]}" -gt 0 ] || return 0
  if [ "$COMPOUND_SEGMENT_VALIDATION" = true ]; then
    if [ "$COMPOUND_SEGMENT_CWD_KNOWN" = true ]; then
      resolution_cwds=("$COMPOUND_SEGMENT_CWD")
    else
      mapfile -t resolution_cwds < <(jq -r '.[]' <<<"$COMPOUND_SEGMENT_CWD_CANDIDATES" 2>/dev/null || true)
    fi
  else
    resolution_cwds=("$cwd")
  fi
  detail=""
  if [ "${#resolution_cwds[@]}" -eq 0 ]; then
    resolution_cwds=("")
  fi
  for resolution_cwd in "${resolution_cwds[@]}"; do
    detail="$(foreign_active_marker_mutation_detail "$command" "$session_id" "$PLAN_TIMEOUT_REPLAYS" "$resolution_cwd" 2>/dev/null || true)"
    [ -z "$detail" ] || break
  done
  [ -z "$detail" ] ||
    deny_eci "ECI_CROSS_SESSION_ACTIVE_MARKER_DENIED" "eci-control" \
      "ECI control boundary denied mutation of another session's active marker: ${detail}" \
      "leave the other session marker unchanged; use its coordinator or the current session's normal routing path"
}

protected_resolved_operation_detail() {
  python3 - "$1" "$cwd" "$HOOK_DIR" "$2" "$3" <<'PY'
import os
import re
import shlex
import sys

text, hook_cwd, hook_dir, is_worker, effect_scope = sys.argv[1:]
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
def unwrap(values: list[str], operand_cwd: str) -> tuple[list[str], str]:
    values = list(values)
    depth = 0
    while values and depth < 8:
        while values and assignment.fullmatch(values[0]):
            values.pop(0)
        if not values:
            return [], operand_cwd
        name = os.path.basename(values[0])
        if name == "env":
            index = 1
            while index < len(values):
                token = values[index]
                if assignment.fullmatch(token) or token in {"-i", "--ignore-environment"}:
                    index += 1
                    continue
                if token in {"-C", "--chdir"} or token.startswith(("-C", "--chdir=")):
                    if token in {"-C", "--chdir"}:
                        if index + 1 >= len(values):
                            return [], operand_cwd
                        directory = values[index + 1]
                        index += 2
                    else:
                        directory = token[2:] if token.startswith("-C") else token.split("=", 1)[1]
                        index += 1
                    operand_cwd = os.path.realpath(os.path.join(operand_cwd, directory))
                    if not os.path.isdir(operand_cwd):
                        return [], operand_cwd
                    continue
                if token in {"-u", "--unset"}:
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
        if name == "timeout":
            return values, operand_cwd
        if name == "stdbuf":
            index = 1
            while index < len(values):
                token = values[index]
                if token == "--":
                    index += 1
                    break
                if token in {"-i", "-o", "-e", "--input", "--output", "--error"}:
                    if index + 1 >= len(values):
                        values = []
                        break
                    index += 2
                    continue
                if (
                    (token.startswith(("-i", "-o", "-e")) and len(token) > 2)
                    or token.startswith(("--input=", "--output=", "--error="))
                ):
                    index += 1
                    continue
                if token.startswith("-"):
                    # The compiled planner reports unsupported stdbuf options
                    # as malformed wrapper syntax.  The fallback likewise
                    # declines to infer a child argv from them; it does not
                    # parse an opaque nested command.
                    values = []
                break
            values = values[index:] if values else []
            depth += 1
            continue
        if name == "busybox":
            index = 1
            if index < len(values) and values[index] == "--":
                index += 1
            values = values[index:]
            depth += 1
            continue
        if name in {"nice", "time", "prlimit", "chronic", "systemd-run"}:
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
            values = values[index:]
            depth += 1
            continue
        break
    return values, operand_cwd

argv, operand_cwd = unwrap(tokens, hook_cwd)
if not argv:
    raise SystemExit(1)
name = os.path.basename(argv[0])
args = argv[1:]

def resolved(value: str) -> str:
    expanded = os.path.expanduser(value)
    candidate = expanded if os.path.isabs(expanded) else os.path.join(operand_cwd, expanded)
    return os.path.realpath(os.path.normpath(candidate))

broad_roots = {"/", os.path.realpath(hook_cwd), os.path.realpath(os.path.dirname(hook_dir))}
for value in (
    os.environ.get("HOME", ""), os.environ["CODEX_CONFIGURED_HOME"],
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
filesystem_destruction = name in {"mkfs", "mkfs.ext2", "mkfs.ext3", "mkfs.ext4", "mkfs.xfs"}
if filesystem_destruction or name == "wipefs":
    options = args[:args.index("--")] if "--" in args else args
    informational = "--help" in options or (name in {"mkfs", "wipefs"} and "--version" in options)
    if name == "wipefs":
        informational = informational or any(token in {"-h", "-V", "-n", "--no-act"} for token in options)
        filesystem_destruction = any(
            token in {"-a", "--all", "-o", "--offset"} or token.startswith("--offset=") or
            (token.startswith("-o") and len(token) > 2)
            for token in options
        )
    filesystem_destruction = filesystem_destruction and not informational
if filesystem_destruction:
    target = next((token for token in reversed(args) if not token.startswith("-")), "<missing>")
    print("class=broad executable=%s token=%s target=%s kind=device-filesystem-destruction" %
          (argv[0], target, resolved(target) if target != "<missing>" else target))
    raise SystemExit(0)
if name == "dd":
    for token in args:
        if not token.startswith("of="):
            continue
        target = resolved(token[3:])
        if target == os.path.realpath("/dev/null"):
            continue
        if target.startswith("/dev/") or target in broad_roots:
            print("class=broad executable=%s token=%s target=%s kind=raw-output-overwrite" %
                  (argv[0], token, target))
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

if effect_scope == "broad":
    raise SystemExit(1)

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
        if token in {"config", "reset", "worktree"}:
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
        for value in (
            os.environ["CODEX_CONFIGURED_HOME"],
            os.environ.get("KIMI_CODE_HOME", ""),
        ):
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

        def chmod_option_is_recursive(token):
            if token.startswith("--"):
                return len(token) >= len("--rec") and "--recursive".startswith(token)
            return token.startswith("-") and not token.startswith("--") and "R" in token[1:]

        def chmod_option_is_reference(token):
            option, separator, reference = token.partition("=")
            return (
                (not separator or reference != "")
                and len(option) >= len("--ref")
                and "--reference".startswith(option)
            )

        def chmod_option_has_empty_reference_value(token):
            option, separator, reference = token.partition("=")
            return (
                separator
                and reference == ""
                and len(option) >= len("--ref")
                and "--reference".startswith(option)
            )

        operands = []
        cursor = 0
        recursive = False
        reference_mode = False
        options = True
        malformed_reference = False
        while cursor < len(args):
            token = args[cursor]
            if options and token == "--":
                options = False
                cursor += 1
                continue
            if options and chmod_option_has_empty_reference_value(token):
                malformed_reference = True
                break
            if options and chmod_option_is_reference(token):
                reference_mode = True
                if "=" in token:
                    cursor += 1
                    continue
                if cursor + 1 >= len(args):
                    malformed_reference = True
                    break
                cursor += 2
                continue
            if options and chmod_option_is_recursive(token):
                recursive = True
                cursor += 1
                continue
            if options and token.startswith("-"):
                cursor += 1
                continue
            operands.append(token)
            cursor += 1

        if malformed_reference:
            operands = []
        if reference_mode:
            targets = operands
        elif len(operands) >= 2:
            targets = operands[1:]
        else:
            targets = []

        def path_within(path, root):
            try:
                return os.path.commonpath((path, root)) == root
            except ValueError:
                return False

        for token in targets:
            if token == "--":
                continue
            target = resolved(token)
            if target in protected_hooks:
                print("class=worker-hook-mode executable=%s token=%s path=%s resolved=%s kind=protected-hook-mode-mutation" %
                      (argv[0], token, target, target))
                raise SystemExit(0)
            if recursive and any(path_within(protected_hook, target) for protected_hook in protected_hooks):
                print("class=worker-hook-mode executable=%s token=%s path=%s resolved=%s kind=protected-hook-mode-mutation" %
                      (argv[0], token, target, target))
                raise SystemExit(0)
    raise SystemExit(1)

# The compiled planner intentionally defers coordinator hook-mode mutations
# to this provider-aware adapter.  Keep the peer boundary concrete: changing
# a protected Kimi hook from a Codex coordinator can desynchronise the peer's
# control path, while an ordinary target (or an opaque shell payload) has no
# such resolved effect and remains transparent.
if is_worker != "true" and name == "chmod":
    kimi_root = os.environ.get("KIMI_CODE_HOME", "") or os.path.join(
        os.environ.get("HOME", ""), ".kimi-code"
    )
    if (kimi_root and os.path.isabs(kimi_root) and
            os.path.normpath(kimi_root) == kimi_root and
            os.path.isdir(kimi_root) and not os.path.islink(kimi_root)):
        kimi_root = os.path.realpath(kimi_root)
        protected_peer_hooks = {
            os.path.join(kimi_root, "hooks", "validate-bash.sh"),
            os.path.join(kimi_root, "hooks", "pre-commit-go-mod.sh"),
            os.path.join(kimi_root, "hooks", "install-pre-commit-go-mod.sh"),
            os.path.join(kimi_root, "hooks", "tests", "test-pre-commit-go-mod.sh"),
        }

        def peer_chmod_option_is_recursive(token):
            if token.startswith("--"):
                return len(token) >= len("--rec") and "--recursive".startswith(token)
            return token.startswith("-") and not token.startswith("--") and "R" in token[1:]

        def peer_chmod_option_is_reference(token):
            option, separator, reference = token.partition("=")
            return (
                (not separator or reference != "") and
                len(option) >= len("--ref") and
                "--reference".startswith(option)
            )

        def peer_chmod_option_has_empty_reference_value(token):
            option, separator, reference = token.partition("=")
            return (
                separator and reference == "" and
                len(option) >= len("--ref") and
                "--reference".startswith(option)
            )

        peer_operands = []
        cursor = 0
        peer_recursive = False
        peer_reference_mode = False
        peer_options = True
        peer_malformed_reference = False
        while cursor < len(args):
            token = args[cursor]
            if peer_options and token == "--":
                peer_options = False
                cursor += 1
                continue
            if peer_options and peer_chmod_option_has_empty_reference_value(token):
                peer_malformed_reference = True
                break
            if peer_options and peer_chmod_option_is_reference(token):
                peer_reference_mode = True
                if "=" in token:
                    cursor += 1
                    continue
                if cursor + 1 >= len(args):
                    peer_malformed_reference = True
                    break
                cursor += 2
                continue
            if peer_options and peer_chmod_option_is_recursive(token):
                peer_recursive = True
                cursor += 1
                continue
            if peer_options and token.startswith("-"):
                cursor += 1
                continue
            peer_operands.append(token)
            cursor += 1

        if peer_malformed_reference:
            peer_operands = []
        if peer_reference_mode:
            peer_targets = peer_operands
        elif len(peer_operands) >= 2:
            peer_targets = peer_operands[1:]
        else:
            peer_targets = []

        def peer_path_within(path, root):
            try:
                return os.path.commonpath((path, root)) == root
            except ValueError:
                return False

        for token in peer_targets:
            if token == "--":
                continue
            target = resolved(token)
            if target in protected_peer_hooks or (
                    peer_recursive and any(
                        peer_path_within(protected_hook, target)
                        for protected_hook in protected_peer_hooks
                    )):
                print(
                    "class=coordinator-peer-hook-mode executable=%s token=%s "
                    "path=%s resolved=%s provider=kimi "
                    "kind=peer-protected-hook-mode-mutation" %
                    (argv[0], token, target, target)
                )
                raise SystemExit(0)

source_roots = {os.path.realpath(hook_cwd), os.path.realpath(os.path.dirname(hook_dir))}
for value in (
    os.environ["CODEX_CONFIGURED_HOME"],
    os.environ.get("KIMI_CODE_HOME", ""),
):
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

# Early admission checks only resolved broad effects, sharing root resolution
# with the later worker Git and source-ownership policy.
protected_broad_operation_detail() {
  protected_resolved_operation_detail "$1" false broad
}

protected_literal_operation_detail() {
  protected_resolved_operation_detail "$1" "$2" all
}

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
    # A proof-root alias may be a symlink outside the configured spelling.
    # Treat only a lexical prefix that resolves to the already-authoritative
    # canonical root as an alias; an arbitrary path is not pulled into the
    # protected namespace merely because it contains similar text.
    prefix = os.path.sep
    for component in candidate.split(os.path.sep):
        if not component:
            continue
        prefix = os.path.join(prefix, component)
        if os.path.realpath(prefix) == canonical:
            lexical_roots.append(prefix)
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

proof_path_dereferencing_read() {
  python3 - "$1" <<'PY'
import os
import shlex
import sys

read_tools = {
    "cat", "cmp", "cut", "diff", "egrep", "fgrep", "file", "grep", "head",
    "jq", "ls", "nl", "od", "readlink", "rg", "sed", "sha256sum", "sort",
    "stat", "tail", "tr", "uniq", "wc",
}
try:
    tokens = shlex.split(sys.argv[1], posix=True)
except ValueError:
    raise SystemExit(1)
if not tokens:
    raise SystemExit(1)
index = 0
while index < len(tokens) and "=" in tokens[index] and tokens[index].split("=", 1)[0].replace("_", "A").isalnum():
    index += 1
if index < len(tokens) and os.path.basename(tokens[index]) in read_tools:
    raise SystemExit(0)
raise SystemExit(1)
PY
}

# Proof-root ownership is a coordinator-only effect check.  It rejects only a
# read utility whose literal path begins in a configured proof-root spelling
# but resolves through a symlink outside the canonical proof root.  Ordinary
# paths, non-read commands, worker commands, and planner uncertainty remain
# transparent; this helper is shared by all coordinator fast exits so that no
# one route can accidentally bypass the same concrete check.
enforce_proof_path_escape_boundary() {
  local candidate="${1:-}" detail
  [ "$hook_is_subagent" != true ] || return 0
  [ "${#syntax_eci_markers[@]}" -gt 0 ] || return 0
  proof_path_dereferencing_read "$candidate" || return 0
  detail="$(proof_path_escape_detail "$candidate" 2>/dev/null || true)"
  [ -z "$detail" ] ||
    deny_eci "ECI_PROOF_PATH_ESCAPE_DENIED" "proof-path-ownership" \
      "ECI proof-path ownership denied a read target that escapes the canonical proof root: ${detail}; predicate=proof-path-escape" \
      "use the canonical proof-root path or keep the referenced evidence within the proof root"
}

# Keep planner status-0 compounds with a visible Git worktree verb on the
# concrete-effect path below.  This is deliberately a routing hint rather
# than a denial: an unrecognized wrapper, shell keyword, or path merely loses
# the fast exit and is then judged by the resolved effect parser.
coordinator_git_worktree_effect_candidate() {
  [ "${#syntax_eci_markers[@]}" -gt 0 ] || return 1
  python3 - "${1:-}" <<'PY'
import os
import shlex
import sys

try:
    tokens = list(shlex.shlex(sys.argv[1], posix=True, punctuation_chars=True))
except ValueError:
    raise SystemExit(1)
verbs = {"rm", "mv", "restore", "checkout"}
for index, value in enumerate(tokens):
    if os.path.basename(value) != "git":
        continue
    for child in tokens[index + 1:]:
        if child in {";", "&", "&&", "|", "||", "(", ")"}:
            break
        if child in verbs:
            raise SystemExit(0)
raise SystemExit(1)
PY
}

# The compiled planner may conservatively allow an otherwise finite argv while
# the shell launcher still hides a concrete lifecycle mutation.  Resolve only
# that effect before the planner's status-0 fast exit; ordinary sourced or
# inline scripts remain transparent.
coordinator_dynamic_lifecycle_detail_early() {
  [ "$hook_is_subagent" != true ] || return 1
  [ "${#syntax_eci_markers[@]}" -gt 0 ] || return 1
  python3 - "${1:-}" "${cwd:-}" "${CODEX_CONFIGURED_HOME:-}" <<'PY'
import os
import shlex
import sys

text, invocation_cwd, configured_home = sys.argv[1:]
configured_eci = os.path.realpath(os.path.join(configured_home, "bin", "eci-active"))
mutating = {
    "on", "off", "wait", "resume", "ledger-append", "nested-enter",
    "nested-accept", "nested-exit", "manifest-write", "approve-commit",
    "aggregate-migrate", "aggregate-stage", "aggregate-manifest-write",
    "aggregate-review", "aggregate-commit", "repository-allow-on",
    "repository-allow-off",
}
operators = {";", "&", "&&", "|", "||", "(", ")"}

def tokenize(value):
    try:
        lexer = shlex.shlex(value, posix=True, punctuation_chars=True)
        lexer.whitespace_split = True
        return list(lexer)
    except ValueError:
        return None

def canonical_script(value):
    value = os.path.expandvars(os.path.expanduser(value))
    if os.path.isabs(value):
        candidate = value
    else:
        candidate = os.path.join(invocation_cwd, value)
    return os.path.realpath(candidate) == configured_eci and os.path.isfile(candidate)

def split(values):
    result, current = [], []
    for value in values + [";"]:
        if value in operators:
            if current:
                result.append(current)
            current = []
        else:
            current.append(value)
    return result

def skip_env(argv, index):
    while index < len(argv):
        value = argv[index]
        if value == "--":
            return index + 1
        if value.startswith(("-u=", "--unset=", "-C=", "--chdir=")):
            index += 1
            continue
        if value in {"-i", "--ignore-environment"} or "=" in value and value.split("=", 1)[0].replace("_", "A").isalnum():
            index += 1
            continue
        if value in {"-u", "--unset", "-C", "--chdir"}:
            index += 2
            continue
        break
    return index

def inspect(argv, base=0, depth=0):
    if not argv or depth > 6:
        return None
    while argv and "=" in argv[0] and argv[0].split("=", 1)[0].replace("_", "A").isalnum():
        argv, base = argv[1:], base + 1
    if not argv:
        return None
    name = os.path.basename(argv[0])
    if name in {"source", "."}:
        if len(argv) >= 3 and canonical_script(argv[1]) and argv[2] in mutating:
            return "token=%s argv_index=%d" % (name, base)
        return None
    if name == "env":
        index = skip_env(argv, 1)
        return inspect(argv[index:], base + index, depth + 1)
    if name in {"command", "builtin", "exec", "nohup", "setsid", "sudo", "doas"}:
        return inspect(argv[1:], base + 1, depth + 1)
    if name in {"timeout", "nice", "chronic", "systemd-run", "prlimit", "time"}:
        index = 1
        while index < len(argv) and argv[index].startswith("-"):
            index += 2 if index + 1 < len(argv) and argv[index] in {"-k", "--kill-after", "-s", "--signal", "-n", "--adjustment", "-p", "--property", "--unit", "--setenv", "--working-directory", "-C", "--chdir"} else 1
        if name == "timeout" and index < len(argv):
            index += 1
        return inspect(argv[index:], base + index, depth + 1)
    if name in {"bash", "sh", "dash", "zsh"}:
        for index, value in enumerate(argv[1:], 1):
            if value in {"-c", "-lc", "-cl"} and index + 1 < len(argv):
                nested = tokenize(argv[index + 1])
                if nested is not None and any(inspect(part, 0, depth + 1) for part in split(nested)):
                    return "token=%s argv_index=%d" % (value, base + index)
        return None
    if len(argv) >= 2 and canonical_script(argv[0]) and argv[1] in mutating:
        return None
    return None

tokens = tokenize(text)
if tokens is not None:
    for segment in split(tokens):
        detail = inspect(segment)
        if detail:
            print(detail)
            raise SystemExit(0)
raise SystemExit(1)
PY
}

if [ "$plan_marker_state" = active ] && [ "$plan_status" -ne 2 ]; then
  direct_ledger_static_control_target_pass "$command" true || true
  if [ "$DIRECT_LEDGER_FALLBACK_DECISION" = deny ]; then
    direct_ledger_emit_fallback_denial
  fi
  broad_effect_detail="$(protected_broad_operation_detail "$command" 2>/dev/null || true)"
  if [ -n "$broad_effect_detail" ]; then
    deny_eci "ECI_BROAD_DESTRUCTIVE_DENIED" "broad-destructive" \
      "$broad_effect_detail" "replace the broad root with one explicit narrow recoverable target"
  fi
fi

coordinator_dynamic_lifecycle_detail="$(coordinator_dynamic_lifecycle_detail_early "$command" 2>/dev/null || true)"
if [ -n "$coordinator_dynamic_lifecycle_detail" ]; then
  deny_eci "ECI_PLAN_DYNAMIC_LAUNCH_DENIED" "plan-segment" \
    "ECI coordinator command plan denied dynamic lifecycle indirection: ${coordinator_dynamic_lifecycle_detail}; predicate=dynamic-launch; reason=the resolved lifecycle mutation is hidden behind a shell launcher and cannot use the literal lifecycle admission route" \
    "invoke the canonical lifecycle executable directly through the Supervisor route"
fi

worker_fast_path_candidate=false
case "$plan_status" in
  0)
    # A status-0 result is the compiled planner's complete finite-argv
    # decision. Validate the active marker once, then return before any
    # provider-specific legacy classifier can spawn unrelated helpers. The
    # planner deliberately admits the finite cleanup shape so the existing
    # immediate cleanup adapter can validate its destination; let only that
    # ownership-sensitive route run before the generic return.
    validate_active_marker_binding
    enforce_proof_path_escape_boundary "$command"
    enforce_foreign_active_marker_mutation_boundary
    if [ "$PLAN_CURRENT_LEDGER_APPEND" = true ]; then
      exit 0
    fi
    if [ "$PLAN_GIT_CLONE_SOURCE_ACQUISITION" = true ] &&
      ! trusted_literal_executable git "$PLAN_GIT_CLONE_GIT_EXECUTABLE"; then
      deny_eci "ECI_GIT_EXECUTION_CONTEXT_DENIED" "git-execution-context" \
        "ECI Git source-acquisition denied: literal Git executable does not resolve to the established trusted Git executable" \
        "use a Git executable that resolves to the established trusted Git executable, then retry the same clone"
    fi
    if [ "$PLAN_GIT_CLONE_SOURCE_ACQUISITION" = true ] &&
      [ "$PLAN_GIT_CLONE_LAUNCH_CLASS" = env ] &&
      ! trusted_literal_executable env "$PLAN_GIT_CLONE_ENV_EXECUTABLE"; then
      deny_eci "ECI_GIT_EXECUTION_CONTEXT_DENIED" "git-execution-context" \
        "ECI Git source-acquisition denied: literal env launcher does not resolve to the established trusted env executable" \
        "use an env launcher that resolves to the established trusted env executable, then retry the same clone"
    fi
    if [ "$coordinator_compound_mutation" = true ]; then
      if coordinator_compound_fast_route "$command"; then
        exit 0
      elif [ "$COORDINATOR_COMPOUND_FAST_APPLICABLE" = true ]; then
        deny_eci "ECI_COMPOUND_MUTATION_DENIED" "compound-mutation" \
          "ECI coordinator compound mutation denied: ${COORDINATOR_CLEANUP_ROUTE_DETAIL:-command=$(eci_command_identity_subject "$command")}; predicate=compound-mutation; reason=the mutation segment is not admitted by the bounded ownership route" \
          "split the read-only inspection from the mutation, or use the bounded coordinator cleanup route for the exact generated target"
      fi
    fi
    if [ "$coordinator_compound_mutation" != true ] &&
      [ "$coordinator_static_pipeline_candidate" != true ] &&
      [ "$worker_read_only_pipeline_candidate" != true ] &&
      ! { [ "$plan_role" = worker ] && [ "$plan_marker_state" = active ] &&
        deferred_worker_wrapper_shape "$command" &&
        [ "$PLAN_GIT_CLONE_SOURCE_ACQUISITION" != true ]; } &&
      ! eci_cleanup_command_shape "$command" &&
      ! coordinator_git_worktree_effect_candidate "$command" &&
      ! shell_script_launcher_shape "$command" &&
      { ! opaque_launcher_shape "$command" ||
        [ "$PLAN_GIT_CLONE_SOURCE_ACQUISITION" = true ]; } &&
      { ! deferred_route_environment_shape "$command" ||
        [ "$PLAN_GIT_CLONE_SOURCE_ACQUISITION" = true ]; } &&
      { ! git_legacy_route_shape "$command" ||
        [ "$PLAN_GIT_CLONE_SOURCE_ACQUISITION" = true ]; }; then
      # Keep the bounded worker ownership guard as the only post-planner
      # route for active worker allows. Coordinator/inactive allows can leave
      # immediately; worker control and instruction operands still need the
      # existing specific ownership diagnostic.
      if [ "$plan_role" = worker ] && [ "$plan_marker_state" = active ]; then
        worker_fast_path_candidate=true
      else
        enforce_proof_path_escape_boundary "$command"
        exit 0
      fi
    fi
    :
    ;;
  3)
    # Protected deferrals must continue into the legacy operation gates even
    # when this callback has no active ECI marker.  Inactive Git approval
    # callbacks still require the user-owned one-time artifact; ordinary
    # finite allows retain the fast exit above.
    if planner_admitted_coordinator_git_read_route "$command"; then
      validate_active_marker_binding
      exit 0
    fi
    ;;
  2)
    if [ "$CODEX_PLAN_TRANSPARENT_FALLBACK" = true ]; then
      planner_mark_transparent_fallback
    elif plan_denial="$(command_plan_pretooluse_denial "$plan_output")"; then
      finalize_command_gate_denial parser "$plan_denial"
      exit 0
    else
      planner_mark_transparent_fallback
    fi
    ;;
  *)
    planner_mark_transparent_fallback
    ;;
esac

# `printenv NAME...` has no child executable or path operand.  Once strict
# marker discovery and the role-neutral environment grammar accept the one
# direct argv, no later ownership recognizer can find a protected operation.
# Return here instead of running the full multi-language ownership scanner.
# Direct named environment queries can use the worker fast path.  Coordinator
# queries are ordinary read-only work and must not be held to an env-name
# grammar before their actual target/effect is known.
if [ "${#syntax_eci_markers[@]}" -gt 0 ] && [ "$hook_is_subagent" = true ]; then
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
        "eci-permissive-mode", "eci-permissive-authorize",
        ".eci-permissive-mode", ".eci-permissive-authorize",
        "eci-required-critics.json", "eci-critic-identities.ledger",
        "eci-acceptance-anchor", "eci-acceptance-transaction",
        "eci-teardown-complete", "eci-baseline-binding", "baseline_head",
        "eci-commit-admitted", "eci-aggregate", "eci-aggregate-plan.json", "eci-aggregate-teardown-complete", "eci-accidental-mistake-override", ".eci-accidental-mistake-override", "eci-user-closed.ledger", "proof.md",
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
    if name == "eval":
        # A literal eval payload can still expose a concrete broad target.
        # Inspect that payload recursively, but do not deny eval merely
        # because its eventual effect is unknown.
        nested = tokenize(" ".join(segment[index + 1:]))
        return nested is not None and any(
            inspect(part, depth + 1) for part in segment_tokens(nested)
        )
    if name in wrappers:
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
    os.environ["CODEX_CONFIGURED_HOME"]
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
            "CODEX_CONFIGURED_HOME",
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
        os.environ["CODEX_CONFIGURED_HOME"],
    ]
    # A worker may inspect its own provider root, but the companion provider
    # root remains coordinator-owned even when it is exported through one of
    # the generic approved-repository slots.  Filter by canonical home rather
    # than by variable name so aliases cannot reopen the peer path.
    worker_home = os.path.realpath(
        os.environ["CODEX_CONFIGURED_HOME"]
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
    skills = os.path.join(os.environ["CODEX_CONFIGURED_HOME"], "skills")
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
    if len(segment) != index + 6 or segment[index:index + 6] != ["git", "-C", segment[index + 2], "--no-pager", "status", "--short"]:
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

def finite_git_pathspec(value):
    """Accept one canonical relative pathspec without resolving its target."""
    if (not value or len(value) > 4096 or value.startswith(("-", "/", "~", ":")) or
            any(mark in value for mark in ("$", "`", "\\", "*", "?", "[", "]", "(", ")")) or
            any(ord(character) < 0x20 for character in value) or
            os.path.normpath(value) != value):
        return False
    return all(component not in {"", ".", ".."} for component in value.split("/"))

def finite_git_log_limit(value):
    return any(value in {f"-{count}", f"--max-count={count}"} for count in range(1, 17))

def finite_git_diff_option(value):
    if value in {"--check", "--cached", "--staged", "--stat", "--name-only", "--name-status"}:
        return True
    match = re.fullmatch(r"(?:-U|--unified=)([0-9]{1,4})", value)
    return match is not None and int(match.group(1)) <= 1000

def finite_git_read_only_args(args):
    """Validate the finite grammar after a raw git --no-pager prefix."""
    if not args:
        return False
    subcommand, values = args[0], args[1:]
    if subcommand == "status":
        return all(value in {
            "--short", "--branch", "--porcelain", "--porcelain=v1", "--porcelain=v2",
            "--untracked-files=no", "--untracked-files=normal", "--untracked-files=all",
        } for value in values)
    if subcommand == "log":
        after_separator = False
        for value in values:
            if after_separator:
                if not finite_git_pathspec(value):
                    return False
                continue
            if value == "--":
                after_separator = True
                continue
            if value not in {"--oneline", "--format=%H"} and not finite_git_log_limit(value):
                return False
        return True
    if subcommand == "diff":
        after_separator = False
        option_seen = False
        for value in values:
            if after_separator:
                if not finite_git_pathspec(value):
                    return False
                continue
            if value == "--":
                after_separator = True
                continue
            if not finite_git_diff_option(value):
                return False
            option_seen = True
        return option_seen
    if subcommand == "grep":
        pattern_seen = False
        after_separator = False
        index = 0
        while index < len(values):
            value = values[index]
            if after_separator:
                if not finite_git_pathspec(value):
                    return False
            elif value == "--":
                after_separator = True
            elif value in {"-n", "--line-number", "-i", "--ignore-case", "-F", "--fixed-strings", "-I", "--no-textconv"}:
                pass
            elif value in {"-e", "--regexp"}:
                if index + 1 >= len(values) or not values[index + 1] or any(mark in values[index + 1] for mark in ("$", "`", "\n", "\r")):
                    return False
                pattern_seen = True
                index += 1
            elif value.startswith("--regexp="):
                if not value.removeprefix("--regexp=") or any(mark in value.removeprefix("--regexp=") for mark in ("$", "`", "\n", "\r")):
                    return False
                pattern_seen = True
            elif pattern_seen or not value or any(mark in value for mark in ("$", "`", "\n", "\r")):
                return False
            else:
                pattern_seen = True
            index += 1
        return pattern_seen
    if subcommand == "ls-files":
        return not values
    if subcommand == "rev-parse":
        return values == ["HEAD"]
    if subcommand == "branch":
        return values in (["--show-current"], ["--all", "--contains", "HEAD"])
    if subcommand == "remote":
        return values == ["-v"]
    return False

def bounded_git_read_only(segment, index):
    # Raw Git can inherit repository configuration and attributes that select
    # external helpers. Only lifecycle-owned codex_git_safe routes may execute
    # it while an active marker is enforced.
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
    # the canonical basename. Canonical shell/test routes are handled by
    # their identity checks before this capability classifier.
    program = segment[index]
    name = os.path.basename(segment[index])
    # `PATH` can expose a copied/renamed lifecycle binary. Resolve the actual
    # executable (and its bounded digest) before admitting ordinary direct
    # paths, so a bare `eci-active` cannot evade the worker boundary.
    if lifecycle_executable(program) or name == "eci-active":
        return True
    # A noncanonical slash-qualified direct argv is still a finite capability
    # plan. Canonical lifecycle/review-gate ownership was checked above by the
    # dedicated identity routes; path syntax alone is not an opaque launcher.
    if "/" in program:
        return False
    if name == "eval":
        # Resolve literal payloads for concrete lifecycle/control effects.
        # An unknown or ordinary payload is not itself an accidental effect,
        # so leave it transparent to the capability-aware routes.
        nested = tokenize(" ".join(segment[index + 1:]))
        return nested is not None and any(
            inspect(part, depth + 1) for part in split(nested)
        )
    if name in archive_writers:
        return True
    if name in shells:
        # The unified reviewed-script route owns shell-test byte validation.
        # This worker launcher guard remains conservative so a later generic
        # read-only classifier cannot bypass that resolver.
        return True
    if name in interpreters:
        return True
    if name == "gitleaks" and any(
        token == "-r" or token == "--report-path" or token.startswith("--report-path=")
        for token in segment[index + 1:]
    ):
        return True
    if name == "diff" and any(
        token in {"-o", "--output"} or token.startswith("--output=")
        for token in segment[index + 1:]
    ):
        return True
    if name == "sort" and any(
        token == "-o" or (token.startswith("-o") and len(token) > 2) or token.startswith("--output=")
        for token in segment[index + 1:]
    ):
        return True
    if name == "env":
        # Transparent environment prefixes remain finite ordinary argv when
        # their child is a bare tool. A path-qualified child can be an opaque
        # copied worker or control executable, so keep that child on the
        # worker ownership route.
        nested = segment[index + 1:]
        while nested and (assignment(nested[0]) or nested[0] in {"-i", "--ignore-environment"}):
            nested = nested[1:]
        while nested and nested[0] in {"-u", "--unset", "-C", "--chdir"}:
            nested = nested[2:]
        while nested and nested[0].startswith(("--unset=", "--chdir=")):
            nested = nested[1:]
        if nested and nested[0] == "--":
            nested = nested[1:]
        return not (nested and "/" not in nested[0])
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
        # The source path alone does not establish a concrete ECI effect.
        # Canonical lifecycle/control paths are recognized by the dedicated
        # effect routes; unknown scripts remain ordinary execution.
        return False
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

# Shared supported Git semantics for the existing embedded effect readers.
# This literal library is source from this hook, not command-supplied Python.
git_effect_python() {
  cat <<'PY'
import stat


def git_branch_effect(
    arguments: list[str],
    unknown: frozenset[int] = frozenset(),
    variable: frozenset[int] = frozenset(),
) -> str:
    """Resolve supported branch argument roles before selecting the final action."""
    actions = dict.fromkeys(("delete", "move", "copy", "edit-description", "set-upstream-to", "unset-upstream"), False)
    short_actions = {"-d": "delete", "-D": "delete", "-m": "move", "-M": "move", "-c": "copy", "-C": "copy"}
    required = {"--format", "--sort", "--points-at", "--set-upstream-to"}
    filters = {"--contains", "--no-contains", "--merged", "--no-merged", "--points-at"}
    list_mode = False
    show_current = False
    filter_mode = False
    positional = False
    paths_only = False
    action_unknown = False
    roles_unknown = False
    index = 0
    while index < len(arguments):
        value = arguments[index]
        uncertain = index in unknown
        variable_word = index in variable
        index += 1
        if paths_only:
            positional = True
            continue
        if uncertain:
            if variable_word or value.startswith(("$?", "-")):
                action_unknown = True
                roles_unknown = roles_unknown or variable_word or "=" not in value
            else:
                positional = True
            continue
        if roles_unknown:
            continue
        if value == "--":
            paths_only = True
            continue
        option, attached, operand = value.partition("=")
        if option in required:
            if not attached:
                if index >= len(arguments):
                    return "inspection"
                roles_unknown = roles_unknown or index in variable
                index += 1
            if option == "--set-upstream-to":
                actions["set-upstream-to"] = True
            if option == "--points-at":
                filter_mode = True
            continue
        if option in filters:
            filter_mode = True
            if not attached and index < len(arguments) and not arguments[index].startswith("-"):
                roles_unknown = roles_unknown or index in variable
                index += 1
            continue
        if value in short_actions:
            actions[short_actions[value]] = True
            continue
        if value.startswith("--"):
            name = value[2:]
            negated = name.startswith("no-")
            normalized = name[3:] if negated else name
            if normalized in actions:
                actions[normalized] = not negated
                continue
            if normalized == "list":
                list_mode = not negated
                continue
            if normalized == "show-current":
                show_current = not negated
                continue
        if value == "-l":
            list_mode = True
            continue
        if option in {"--color", "--column", "--abbrev"}:
            continue
        if value in {"-a", "-r", "-v", "-vv", "-q", "-f", "-i", "--all", "--remotes", "--verbose", "--quiet", "--force", "--ignore-case", "--no-color", "--no-column", "--no-abbrev", "--omit-empty", "--create-reflog", "--no-create-reflog", "--recurse-submodules", "--no-recurse-submodules"}:
            continue
        if value.startswith("-"):
            action_unknown = True
            continue
        positional = True
    list_mode = list_mode or filter_mode
    if sum(actions.values()) + int(list_mode) + int(show_current) > 1:
        return "inspection"  # Git rejects conflicting final actions.
    if any(actions.values()):
        return "repository"
    if action_unknown or roles_unknown:
        return "repository-unresolved"
    if list_mode or show_current or not positional:
        return "inspection"
    return "repository"


def git_apply_effect(
    arguments: list[str],
    unknown: frozenset[int] = frozenset(),
    variable: frozenset[int] = frozenset(),
) -> str:
    """Retain final check/output modes without exempting actual patch writes."""
    state = dict.fromkeys(("check", "stat", "numstat", "summary", "apply"), False)
    values = {"--include", "--exclude", "--directory", "--whitespace", "--build-fake-ancestor", "-p", "-C"}
    flags = {"--index", "--cached", "--3way", "--ours", "--theirs", "--union", "--reject", "--reverse", "--recount", "--unidiff-zero", "--allow-empty", "--unsafe-paths", "--inaccurate-eof", "--ignore-space-change", "--ignore-whitespace", "--verbose", "--quiet", "-3", "-R", "-N", "-z", "-v", "-q"}
    output_write = False
    uncertain = False
    index = 0
    while index < len(arguments):
        value = arguments[index]
        if index in unknown:
            uncertain = True
            index += 1
            continue
        index += 1
        if value == "--":
            break
        option, attached, operand = value.partition("=")
        if option in values:
            if not attached:
                if index >= len(arguments):
                    return "inspection"
                uncertain = uncertain or index in variable
                operand = arguments[index]
                index += 1
            if option == "--build-fake-ancestor":
                output_write = bool(operand)
            continue
        if value.startswith(("-p", "-C")) and not value.startswith("--"):
            continue
        if value == "--no-build-fake-ancestor":
            output_write = False
            continue
        if value.startswith("--"):
            name = value[2:]
            negated = name.startswith("no-")
            normalized = name[3:] if negated else name
            if normalized in state:
                if not uncertain:
                    state[normalized] = not negated
                continue
            if value in flags or "--" + normalized in flags:
                continue
        if value in flags or not value.startswith("-"):
            continue
        uncertain = True
    if output_write:
        return "mutation"
    if uncertain:
        return "advisory"
    if not state["apply"] and any(state[name] for name in ("check", "stat", "numstat", "summary")):
        return "inspection"
    return "mutation"


def git_pathspec_entries(
    value: str | None,
    base: str | None,
    nul: bool,
) -> list[str] | None:
    """Read a bounded resolved regular file; None differs from a proven empty list."""
    if value is None or value == "-" or not base or not os.path.isabs(base):
        return None
    path = value if os.path.isabs(value) else os.path.join(base, value)
    try:
        info = os.stat(path)
        if not stat.S_ISREG(info.st_mode) or info.st_size > 65536:
            return None
        with open(path, "rb") as stream:
            data = stream.read(65537)
    except (OSError, ValueError):
        return None
    if len(data) > 65536 or not nul and b"\0" in data:
        return None
    if not data:
        return []
    separator = b"\0" if nul else b"\n"
    parts = data.split(separator)
    terminated_count = len(parts) - 1
    if data.endswith(separator):
        parts.pop()  # Only the synthetic suffix is not a real record.
    entries = []
    for index, part in enumerate(parts):
        if not nul and index < terminated_count:
            part = part.removesuffix(b"\r")
        # An actual blank record is invalid, not absence of selection. Keep
        # unsupported C-quoting advisory without using later file records.
        if not part or not nul and part.startswith(b'"'):
            return None
        entries.append(os.fsdecode(part))
    return entries if len(entries) <= 1024 else None


def git_reset_effect(
    arguments: list[str],
    unknown: frozenset[int] = frozenset(),
    may_disappear: frozenset[int] = frozenset(),
    may_multiply: frozenset[int] = frozenset(),
    cardinality_unknown: frozenset[int] = frozenset(),
    base: str | None = None,
) -> tuple[str, list[tuple[str, bool]]]:
    """Keep supported final reset modes and file/path selection on one record."""
    mode = ""
    filename = ""
    file_nul = paths_only = roles_unknown = False
    selectors = []
    operands = []
    variable = may_disappear | may_multiply | cardinality_unknown
    index = 0
    while index < len(arguments):
        value = arguments[index]
        offset = index
        index += 1
        if paths_only:
            selectors.append((offset, value, offset not in unknown))
            continue
        if offset in unknown:
            option, attached, operand = value.partition("=")
            if option == "--pathspec-from-file" and attached:
                filename = None
                continue
            roles_unknown = roles_unknown or offset in variable or value.startswith(("$?", "-"))
            operands.append((offset, value))
            continue
        if value == "--":
            paths_only = True
            continue
        option, attached, operand = value.partition("=")
        if option == "--pathspec-from-file":
            value_unknown = False
            if not attached:
                if index >= len(arguments):
                    return "reset-option-unresolved", []
                operand = arguments[index]
                value_unknown = index in unknown
                roles_unknown = roles_unknown or index in variable
                index += 1
            filename = None if value_unknown else operand
            continue
        if value == "--no-pathspec-from-file":
            filename = ""
            continue
        if value in {"--pathspec-file-nul", "--no-pathspec-file-nul"}:
            file_nul = value == "--pathspec-file-nul"
            continue
        if value in {"--hard", "--merge", "--keep", "--mixed", "--soft"}:
            if not roles_unknown:
                mode = value
            continue
        if value in {"-q", "--quiet", "--no-quiet", "--refresh", "--no-refresh", "-N", "--intent-to-add", "--no-intent-to-add"}:
            continue
        if value.startswith("-"):
            return "reset-option-unresolved", []
        operands.append((offset, value))
    if filename is None or filename:
        # File plus positional paths is invalid. A revision before -- can be
        # supported separately; without lookup, do not guess an operand role.
        if selectors or operands or roles_unknown:
            return "reset-option-unresolved", []
        if filename is None:
            return "reset-option-unresolved", []
        entries = git_pathspec_entries(filename, base, file_nul)
        if entries is None:
            return "reset-option-unresolved", []
        selectors = [(len(arguments) + offset, value, True) for offset, value in enumerate(entries)]
    elif file_nul:
        return "reset-option-unresolved", []
    known_selectors = [(value, literal) for _, value, literal in selectors]
    disappearing_scope = selectors and not roles_unknown and all(
        offset in may_disappear and offset not in cardinality_unknown
        for offset, _, _ in selectors)
    # A path/mode combination is not proven invalid when every established
    # selector may vanish, leaving the broad no-path reset form.
    if disappearing_scope:
        return "reset-unresolved", known_selectors
    if selectors and mode not in {"", "--mixed"}:
        return "reset-option-unresolved", []  # Git rejects guaranteed paths.
    if mode in {"--hard", "--merge", "--keep"}:
        return "reset-working-tree", known_selectors
    if not paths_only and not filename and any(offset in unknown for offset, _ in operands):
        return "reset-option-unresolved", []
    if roles_unknown:
        return "reset-option-unresolved", known_selectors
    if any(literal and value in {":/", ":(top)"} for _, value, literal in selectors):
        return "reset-index", known_selectors
    if selectors:
        return "reset", known_selectors
    return "reset-index", []


def git_add_effect(
    arguments: list[str],
    unknown: frozenset[int] = frozenset(),
    may_disappear: frozenset[int] = frozenset(),
    may_multiply: frozenset[int] = frozenset(),
    cardinality_unknown: frozenset[int] = frozenset(),
    base: str | None = None,
) -> tuple[str, list[tuple[str, bool]]]:
    """Resolve each add record's final modes and supported selector contents."""
    variable = may_disappear | may_multiply | cardinality_unknown
    all_mode = update_mode = refresh = interactive = False
    preview = preview_proven = roles_unknown = all_proven = update_proven = False
    option_unknown = False
    shape_known = True
    paths_only = False
    filename = ""
    file_nul = False
    selectors = []
    index = 0
    while index < len(arguments):
        value = arguments[index]
        offset = index
        index += 1
        if paths_only:
            selectors.append((offset, value, offset not in unknown))
            continue
        if offset in unknown:
            if offset in variable or value.startswith("$?") or (value.startswith("-") and "=" not in value):
                roles_unknown = True
                preview_proven = False
            if value.startswith("-"):
                option, attached, operand = value.partition("=")
                if option == "--pathspec-from-file" and attached:
                    filename = None
                elif option != "--chmod" or not attached:
                    option_unknown = True
            else:
                selectors.append((offset, value, False))
            continue
        if value == "--":
            paths_only = True
            continue
        option, attached, operand = value.partition("=")
        if option in {"--pathspec-from-file", "--chmod"}:
            value_unknown = False
            if not attached:
                if index >= len(arguments):
                    return "add-option-unresolved", []
                operand = arguments[index]
                value_unknown = index in unknown
                if index in variable:
                    roles_unknown = True
                    preview_proven = False
                    option_unknown = True
                index += 1
            if option == "--pathspec-from-file":
                filename = None if value_unknown else operand
            continue
        if value == "--no-pathspec-from-file":
            filename = ""
            continue
        if value in {"--pathspec-file-nul", "--no-pathspec-file-nul"}:
            file_nul = value == "--pathspec-file-nul"
            continue
        if value in {"-A", "--all", "--no-all", "--ignore-removal", "--no-ignore-removal"}:
            all_mode = value not in {"--no-all", "--ignore-removal"}
            all_proven = not roles_unknown
            continue
        if value in {"-u", "--update", "--no-update"}:
            update_mode = value != "--no-update"
            update_proven = not roles_unknown
            continue
        if value in {"--refresh", "--no-refresh"}:
            refresh = value == "--refresh"
            continue
        if value in {"-n", "--dry-run", "--no-dry-run"}:
            preview = value != "--no-dry-run"
            preview_proven = not roles_unknown
            continue
        if value in {"-p", "-i", "-e", "--patch", "--interactive", "--edit", "--renormalize"}:
            interactive = True
            continue
        if value.startswith("-"):
            if value not in {"-v", "-f", "-N", "--verbose", "--no-verbose", "--force", "--no-force", "--intent-to-add", "--no-intent-to-add", "--sparse", "--ignore-errors", "--ignore-missing"}:
                shape_known = False
            continue
        selectors.append((offset, value, True))
    if all_mode and update_mode or interactive or not shape_known:
        return "add-option-unresolved", []
    if preview:
        return ("inspection" if preview_proven else "add-option-unresolved"), []
    if refresh:
        return "add-option-unresolved", []
    if filename is None or filename:
        if selectors or roles_unknown:
            return "add-option-unresolved", []  # Mixed or unproved selector roles.
        if filename is None:
            return "add-option-unresolved", []
        entries = git_pathspec_entries(filename, base, file_nul)
        if entries is None:
            return "add-option-unresolved", []
        selectors = [(len(arguments) + offset, value, True) for offset, value in enumerate(entries)]
    elif file_nul:
        return "add-option-unresolved", []
    known_selectors = [(value, literal) for _, value, literal in selectors]
    if any(literal and value in {":/", ":(top)"} for _, value, literal in selectors):
        return "whole-worktree-staging", known_selectors
    broad_without_selectors = (all_mode and all_proven or update_mode and update_proven) and not option_unknown
    if broad_without_selectors and not selectors:
        return "whole-worktree-staging", []
    if broad_without_selectors and selectors and all(
            offset in may_disappear and offset not in cardinality_unknown for offset, _, _ in selectors):
        return "add-target-unresolved", known_selectors
    if option_unknown:
        return "add-option-unresolved", known_selectors
    return "prep", known_selectors
PY
}

command_invokes_git_branch_remote_mutation() {
  python3 - "$1" "$(planner_shell_analysis_for "$1")" "$(git_effect_python)" <<'PY'
import json
import os
import hashlib
import re
import shlex
import sys

exec(compile(sys.argv[3], "git-effect-library", "exec"))

text = sys.argv[1]
separators = {";", "&", "&&", "|", "||", "(", ")"}
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

def inspect(
    segment: list[str],
    depth: int = 0,
    unknown: frozenset[int] = frozenset(),
    variable_cardinality: frozenset[int] = frozenset(),
) -> bool:
    if depth > 5:
        return False
    index = 0
    while index < len(segment) and "=" in segment[index] and not segment[index].startswith("-"):
        index += 1
    if index >= len(segment):
        return False
    if index in unknown or any(value < index for value in variable_cardinality):
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
            if token in {"-u", "--unset", "-C", "--chdir", "-S", "--split-string", "-a", "--argv0"} and index + 1 < len(segment):
                index += 2
                continue
            if token.startswith("-"):
                index += 1
                continue
            break
        if any(value < index for value in variable_cardinality):
            return False
        return inspect(segment[index:], depth + 1,
                       frozenset(value - index for value in unknown if value >= index),
                       frozenset(value - index for value in variable_cardinality if value >= index))
    if name in {"bash", "sh", "dash", "zsh"}:
        for option_index, option in enumerate(segment[index + 1:], index + 1):
            if option == "-c" or (option.startswith("-") and "c" in option[1:]):
                if option_index + 1 >= len(segment):
                    return False
                if option_index in unknown or option_index + 1 in unknown:
                    return False
                nested = tokenize(segment[option_index + 1])
                return nested is not None and any(inspect(part, depth + 1) for part in split(nested))
        return False
    if name in {"command", "builtin", "exec", "sudo", "doas", "nohup", "setsid"}:
        index += 1
        if any(value < index for value in variable_cardinality):
            return False
        return inspect(segment[index:], depth + 1,
                       frozenset(value - index for value in unknown if value >= index),
                       frozenset(value - index for value in variable_cardinality if value >= index))
    if name == "timeout":
        return False
    if name in {"systemd-run", "nice", "time", "prlimit", "chronic"}:
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
        if any(value < index for value in variable_cardinality):
            return False
        return inspect(segment[index:], depth + 1,
                       frozenset(value - index for value in unknown if value >= index),
                       frozenset(value - index for value in variable_cardinality if value >= index))
    if name != "git":
        return False
    index += 1
    while index < len(segment) and segment[index].startswith("-"):
        index += 2 if segment[index] in {"-C", "-c", "--git-dir", "--work-tree", "--config-env", "--exec-path"} else 1
    if index >= len(segment) or index in unknown or any(value <= index for value in variable_cardinality):
        return False
    subcommand, args = segment[index], segment[index + 1:]
    if subcommand == "branch":
        effect = git_branch_effect(args,
            frozenset(value - index - 1 for value in unknown if value > index),
            frozenset(value - index - 1 for value in variable_cardinality if value > index))
        if effect == "repository":
            print("executable=git subcommand=branch kind=branch-mutation")
            return True
        return False
    if subcommand == "remote" and args and index + 1 not in unknown and args[0] in remote_mutators:
        print("executable=git subcommand=remote token=%s argv_index=%d kind=remote-mutation" %
              (args[0], index + 1))
        return True
    return False

analysis = json.loads(sys.argv[2])
if analysis is not None:
    found = any(inspect(record["argv"], unknown=frozenset(record.get("unknown_arguments") or []),
                        variable_cardinality=frozenset(record.get("may_disappear_arguments") or []) |
                        frozenset(record.get("may_multiply_arguments") or []) |
                        frozenset(record.get("unknown_cardinality_arguments") or []) |
                        (frozenset(record.get("unknown_arguments") or [])
                         if "may_disappear_arguments" not in record else frozenset())) for record in analysis["commands"]
                if record["reachability"] != "unreachable")
else:
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

# Git inspection is resolved from the concrete repository target below.  This
# compatibility parser is retained only for older helper callers; it is not an
# admission allowlist and the active worker route does not use its spelling.
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
  worker_git_resolved_inspection_route "$1"
  return $?

  [ "$hook_is_subagent" = true ] || return 1
  local detail
  detail="$(python3 - "$1" "$cwd" <<'PY'
import os
import shlex
import sys

command, hook_cwd = sys.argv[1:]
OPS = {";", "&", "|", "||", ">", ">>", ">|", ">&", "<", "<<", "<<<", "<&", "(", ")"}
READ_ONLY = {
    "branch", "describe", "diff", "grep", "log", "ls-files", "remote",
    "rev-parse", "show", "status", "submodule",
}
CONTEXT_OPTIONS = {
    "-c", "--config-env", "--exec-path", "--git-dir", "--namespace",
    "--super-prefix", "--work-tree", "--textconv", "--ext-diff",
}
OUTPUT_OPTIONS = {"-o", "--output", "--output-directory"}
PATH_MARKERS = ("$", "`", "\n", "\r", "*", "?", "[", "]", "(", ")")

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

def safe_value(value, allow_option=False):
    return bool(value) and (allow_option or not value.startswith("-")) and not any(
        marker in value for marker in PATH_MARKERS
    )

def safe_git_read_only(args):
    args = list(args)
    # `git -C <repo> status` only reads the selected repository. Its spelling,
    # existence, or ownership metadata cannot make that inspection destructive;
    # Git reports ordinary errors itself if the requested directory is invalid.
    while args[:1] == ["-C"]:
        if len(args) < 2:
            return False
        args = args[2:]
    if not args or args[0] not in READ_ONLY:
        return False
    subcommand, values = args[0], args[1:]
    if any(value in CONTEXT_OPTIONS or value.startswith(tuple(
            option + "=" for option in CONTEXT_OPTIONS if option.startswith("--")
    )) for value in values):
        return False
    if any(value in OUTPUT_OPTIONS or value.startswith(("--output=", "--output-directory="))
           for value in values):
        return False
    if subcommand == "submodule":
        return values == ["status"]
    if subcommand == "status":
        return all(value in {"--short", "--porcelain", "--branch"} for value in values)
    if subcommand == "branch":
        mutators = {"-d", "-D", "-m", "-M", "-c", "-C", "--delete", "--move",
                    "--copy", "--edit-description", "--set-upstream-to", "--unset-upstream"}
        return all(value.startswith("-") and value not in mutators for value in values)
    if subcommand == "remote":
        return not values or values in (["-v"], ["--verbose"], ["show"], ["get-url"])
    if subcommand == "diff":
        delimiter = values.index("--") if "--" in values else len(values)
        options, paths = values[:delimiter], values[delimiter + 1:]
        allowed_options = {"--binary", "--cached", "--staged", "--check", "--stat",
                           "--name-only", "--name-status", "--no-ext-diff", "--no-textconv"}
        if any(option not in allowed_options for option in options):
            return False
        return all(safe_value(path) for path in paths)
    if subcommand == "grep":
        return bool(values) and all(safe_value(value, allow_option=True) for value in values)
    if subcommand in {"log", "show", "ls-files", "describe", "rev-parse"}:
        return all(safe_value(value, allow_option=True) for value in values)
    return False

for segment in chunks:
    if segment[0] != "git" or any("/" in token for token in segment[:1]):
        reject("segment must invoke the git command")
    args = segment[1:]
    if not safe_git_read_only(args):
        reject("segment is outside the bounded read-only Git capability grammar")
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
  local history_pathspec_exception="${1:-false}" detail worker_control_cwd="$cwd" worker_control_cwds='[]' worker_control_cwd_physical="" worker_control_cwd_physicals='[]'
  case "$history_pathspec_exception" in
    true|false) ;;
    *) history_pathspec_exception=false ;;
  esac
  if [ "$COMPOUND_SEGMENT_VALIDATION" = true ]; then
    worker_control_cwds="$COMPOUND_SEGMENT_CWD_CANDIDATES"
    worker_control_cwd_physicals="$COMPOUND_SEGMENT_CWD_PHYSICAL_CANDIDATES"
    worker_control_cwd_physical="$COMPOUND_SEGMENT_CWD_PHYSICAL"
    if [ "$COMPOUND_SEGMENT_CWD_KNOWN" = true ]; then
      worker_control_cwd="$COMPOUND_SEGMENT_CWD"
    else
      # Unknown planner state is explicit. Do not resolve relative operands
      # against the outer callback CWD; the Python adapter still checks
      # absolute targets and targeted control basenames.
      worker_control_cwd=""
    fi
  else
    worker_control_cwds="$(jq -cn --arg cwd "$worker_control_cwd" 'if $cwd == "" then [] else [$cwd] end')"
    worker_control_cwd_physical="$(realpath -e -- "$worker_control_cwd" 2>/dev/null || true)"
    worker_control_cwd_physicals="$(jq -cn --arg cwd "$worker_control_cwd_physical" 'if $cwd == "" then [] else [$cwd] end')"
  fi
  detail="$(python3 - "$command" "$worker_control_cwd" "$worker_control_cwd_physical" "$HOOK_DIR" "$history_pathspec_exception" "$session_id" "$worker_control_cwds" "$worker_control_cwd_physicals" "${syntax_eci_markers[@]}" <<'PY'
import os
import json
import re
import shlex
import sys

command, hook_cwd, hook_cwd_physical, hook_dir, history_pathspec_exception, current_session, cwd_json, cwd_physical_json = sys.argv[1:9]
try:
    cwd_candidates = [value for value in json.loads(cwd_json)
                      if isinstance(value, str) and os.path.isabs(value)
                      and os.path.normpath(value) == value]
except (TypeError, ValueError, json.JSONDecodeError):
    cwd_candidates = []
try:
    cwd_physical_candidates = [value for value in json.loads(cwd_physical_json)
                               if isinstance(value, str) and os.path.isabs(value)
                               and os.path.normpath(value) == value]
except (TypeError, ValueError, json.JSONDecodeError):
    cwd_physical_candidates = []
if (hook_cwd and (not hook_cwd_physical or os.path.realpath(hook_cwd) != hook_cwd_physical)):
    hook_cwd_physical = ""
if len(cwd_candidates) != len(cwd_physical_candidates) or any(
        os.path.realpath(logical) != physical
        for logical, physical in zip(cwd_candidates, cwd_physical_candidates)):
    cwd_candidates = []
    cwd_physical_candidates = []
active_markers = sys.argv[9:]
history_pathspec_exception = history_pathspec_exception == "true"
try:
    tokens = shlex.split(command, posix=True)
except ValueError:
    raise SystemExit(1)
if len(tokens) < 2:
    raise SystemExit(1)

control_bases = {
    "eci_active", "goal_state", "eci_wait", "eci_user_owned_wait.md",
    "eci-permissive-mode", "eci-permissive-authorize",
    ".eci-permissive-mode", ".eci-permissive-authorize",
    "eci-required-critics.json", "eci-critic-identities.ledger",
    "eci-acceptance-anchor", "eci-acceptance-transaction",
    "eci-teardown-complete", "eci-baseline-binding", "baseline_head",
    "eci-commit-admitted", "eci-aggregate", "eci-aggregate-plan.json", "eci-aggregate-teardown-complete", "eci-accidental-mistake-override", ".eci-accidental-mistake-override", "eci-user-closed.ledger", "proof.md",
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

def nonlive_foreign_marker_path(path):
    """Exclude only an exact provider marker proven non-live by its record."""
    if not path or os.path.islink(path):
        return False
    physical_path = os.path.realpath(path)
    reserved_directories = {
        "activity", "audit", "eci", "history", "pre-reviewer", "reviewer",
        "reviewer-dumps", "side-stop", "skip-stop", "skills",
    }
    for root in roots:
        try:
            relative = os.path.relpath(physical_path, root)
        except ValueError:
            continue
        parts = relative.split(os.sep)
        if (len(parts) != 2 or parts[1] != "eci_active" or
                not re.fullmatch(r"[A-Za-z0-9_-]+", parts[0]) or
                parts[0] in reserved_directories or
                parts[0].startswith("security-warnings-") or
                parts[0] == current_session):
            continue
        marker = os.path.join(root, parts[0], "eci_active")
        if os.path.realpath(marker) != physical_path:
            continue
        if not os.path.isfile(path) or os.path.islink(path):
            return True
        try:
            with open(path, "rb") as stream:
                raw = stream.read(8193)
        except OSError:
            return True
        if len(raw) > 8192 or not raw.endswith(b"\n"):
            return True
        try:
            lines = raw.decode("utf-8").splitlines()
        except UnicodeDecodeError:
            return True
        if (not lines or not lines[0].startswith("scope: ") or
                not lines[0][len("scope: "):]):
            return True
        values = {}
        for line in lines:
            key, separator, value = line.partition(": ")
            if separator:
                values.setdefault(key, value)
        marker_cwd = values.get("cwd", "")
        if (values.get("scope", "") == "" or values.get("session_id") != parts[0] or
                not marker_cwd or not os.path.isabs(marker_cwd) or
                os.path.normpath(marker_cwd) != marker_cwd or
                not os.path.isdir(marker_cwd) or os.path.islink(marker_cwd) or
                os.path.realpath(marker_cwd) != marker_cwd or
                not os.access(marker_cwd, os.X_OK)):
            return True
        return False
    return False

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

def resolve_candidate(path):
    candidates = resolve_candidates(path)
    return candidates[0] if candidates else None

def resolve_candidates(path):
    expanded = os.path.expanduser(path)
    if os.path.isabs(expanded):
        return [os.path.normpath(expanded)]
    return [os.path.normpath(os.path.join(base, expanded))
            for base in cwd_candidates]

def unresolved_control_target(path):
    expanded = os.path.expanduser(path)
    return (bool(expanded) and not os.path.isabs(expanded) and
            is_control_name(os.path.basename(expanded)))

readable_documents = {"instructions.md", "project-understanding.md", "high_level_log.md", "latest-status-report.md"}
operators = {";", "&", "&&", "|", "||", "(", ")", ">", ">>", ">|", ">&", "<", "<<", "<<<", "<&"}

def canonical_document(path):
    if (not path or path.startswith("-") or any(mark in path for mark in
            ("$", "`", "..", "*", "?", "[", "]", "(", ")"))):
        return False
    candidate = resolve_candidate(path)
    if candidate is None:
        return False
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
            if not os.path.isabs(requested) and not base:
                return ([], base)
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
    os.path.dirname(hook_dir),
    os.environ.get("KIMI_CODE_HOME", ""),
    os.environ["CODEX_CONFIGURED_HOME"],
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
    # A symlink directly in an active session directory is itself a control
    # namespace entry even when its final target resolves outside the proof
    # root.  Preserve the lexical ownership boundary without treating an
    # arbitrary repository symlink as control state.
    if os.path.islink(path) and any(
            os.path.dirname(path) == os.path.dirname(marker)
            for marker in active_markers):
        return True
    if ((in_root(path) and is_control_name(os.path.basename(path))) or
            (in_root(resolved) and is_control_name(os.path.basename(resolved)))):
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

def finite_operands(values, flags=(), value_options=()):
    """Return positional paths for one bounded command, or no paths on ambiguity."""
    operands = []
    flags = set(flags)
    value_options = set(value_options)
    index = 1
    options_ended = False
    while index < len(values):
        token = values[index]
        if token in operators:
            if token in {"<", "<<", "<<<", "<&"}:
                index += 2
                continue
            if token in {">", ">>", ">|", ">>", ">&", "&>", "&>>"}:
                index += 2
                continue
            index += 1
            continue
        if not options_ended and token == "--":
            options_ended = True
            index += 1
            continue
        if not options_ended and token.startswith("-"):
            if (os.path.basename(values[0]) == "sed" and
                    (token.startswith("-i") or token.startswith("--in-place="))):
                index += 1
                continue
            if token in value_options:
                if index + 1 >= len(values):
                    return []
                index += 2
                continue
            if any(token.startswith(option + "=") for option in value_options):
                index += 1
                continue
            if token in flags:
                index += 1
                continue
            if token.startswith("-") and token != "-":
                return []
        operands.append(token)
        index += 1
    return operands

def command_writer_operands(values):
    """Return only direct filesystem operands whose command effect writes them."""
    if not values:
        return []
    name = os.path.basename(values[0])
    if name == "truncate":
        return finite_operands(
            values,
            flags={"-c", "--no-create"},
            value_options={"-s", "--size"},
        )
    if name in {"rm", "unlink", "shred", "srm", "touch", "rmdir"}:
        return finite_operands(
            values,
            flags={"-f", "-r", "-R", "-v", "-a", "-m", "-c", "-p", "-i",
                   "--force", "--recursive", "--verbose", "--no-create",
                   "--parents", "--ignore-fail-on-non-empty", "--remove"},
            value_options={"-d", "-t", "--date", "--time"},
        )
    if name == "cp":
        operands = finite_operands(
            values,
            flags={"-f", "-r", "-R", "-v", "-a", "--force", "--recursive", "--verbose", "--archive"},
        )
        return [operands[-1]] if len(operands) == 2 else []
    if name == "mv":
        return finite_operands(
            values,
            flags={"-f", "-i", "-n", "-v", "-T", "--force", "--interactive",
                   "--no-clobber", "--verbose", "--no-target-directory"},
        )
    if name == "ln":
        operands = finite_operands(
            values,
            flags={"-f", "-s", "-n", "-v", "--force", "--symbolic", "--no-dereference", "--verbose"},
        )
        return [operands[-1]] if len(operands) == 2 else []
    if name in {"chmod", "chown", "chgrp"}:
        operands = finite_operands(
            values,
            flags={"-f", "-h", "-R", "-v", "--changes", "--silent", "--quiet",
                   "--dereference", "--no-dereference", "--recursive", "--verbose"},
            value_options={"--reference", "--from"},
        )
        return operands[1:] if len(operands) >= 2 else []
    if name == "dd":
        return [token.split("=", 1)[1] for token in values[1:]
                if token.startswith("of=") and token != "of="]
    if name == "install":
        operands = finite_operands(
            values,
            flags={"-b", "-c", "-d", "-D", "-g", "-m", "-o", "-p", "-s", "-S", "-t", "-T", "-v",
                   "--backup", "--compare", "--directory", "--preserve-timestamps", "--strip", "--verbose"},
            value_options={"-g", "-m", "-o", "-S", "-t", "--group", "--mode", "--owner", "--suffix",
                           "--target-directory"},
        )
        return [operands[-1]] if len(operands) >= 2 else []
    if name == "tee":
        return finite_operands(
            values,
            flags={"-a", "-i", "-p", "--append", "--ignore-interrupts", "--output-error"},
        )
    if name == "rsync":
        operands = finite_operands(values, flags={"-a", "-r", "-v", "-n", "--archive", "--recursive", "--verbose", "--dry-run"})
        return [operands[-1]] if len(operands) >= 2 else []
    if name == "sed":
        if not any(token == "-i" or token == "--in-place" or token.startswith("-i") or token.startswith("--in-place=") for token in values[1:]):
            return []
        operands = []
        options_ended = False
        index = 1
        while index < len(values):
            token = values[index]
            if token in operators:
                index += 2 if token in {"<", "<<", "<<<", "<", ">", ">>", ">|"} else 1
                continue
            if not options_ended and token == "--":
                options_ended = True
                index += 1
                continue
            if not options_ended:
                if token in {"-i", "--in-place", "-n", "--quiet", "--silent"} or token.startswith(("-i", "--in-place=")):
                    index += 1
                    continue
                if token in {"-e", "--expression", "-f", "--file"}:
                    if index + 1 >= len(values):
                        return []
                    index += 2
                    continue
                if token.startswith(("-e", "-f", "--expression=", "--file=")):
                    index += 1
                    continue
                if token.startswith("-") and token != "-":
                    return []
            operands.append(token)
            index += 1
        return operands
    return []

def redirect_writer_operands(values):
    """Return output-redirection targets while excluding input descriptors."""
    result = []
    output_tokens = {">", ">>", ">|", ">&", "&>", "&>>", ">>&"}
    index = 0
    while index + 1 < len(values):
        if values[index] in output_tokens:
            result.append(values[index + 1])
            index += 2
            continue
        index += 1
    return result

output_path_options = {"sort": {"--output", "-o"}, "gitleaks": {"--report-path"}}.get(command_name, set())
writer_tokens = []
instruction_denied_detail = ""
for index, raw_token in enumerate(tokens[1:], 1):
    if raw_token == "--":
        break
    path_token = ""
    if raw_token in output_path_options and index + 1 < len(tokens):
        path_token = tokens[index + 1]
    else:
        for option in output_path_options:
            prefix = option + "="
            if raw_token.startswith(prefix):
                path_token = raw_token[len(prefix):]
                break
        if command_name == "sort" and raw_token.startswith("-o") and not raw_token.startswith("--"):
            path_token = raw_token[2:].removeprefix("=")
    if path_token:
        writer_tokens.append(path_token)
writer_tokens.extend(command_writer_operands(tokens))
writer_tokens.extend(redirect_writer_operands(tokens))

for token in writer_tokens:
    if token.startswith("-") or token in operators:
        continue
    candidates = resolve_candidates(token)
    if not candidates:
        if unresolved_control_target(token):
            emit("write", token, "<unknown-cwd>")
        continue
    for candidate in candidates:
        resolved = os.path.realpath(candidate)
        control_alias = current_control_hardlink(candidate)
        if not control_alias:
            control_alias = current_control_hardlink(resolved)
        if control_alias:
            emit("write", token, control_alias)
        if nonlive_foreign_marker_path(candidate):
            continue
        if in_root(candidate) and protected_control_path(candidate):
            emit("write", token, candidate)
        if in_provider_sessions(candidate):
            emit("write", token, candidate)
        if in_root(resolved) and (protected_control_path(candidate) or protected_control_path(resolved)):
            emit("write", token, resolved)
        if in_provider_sessions(resolved):
            emit("write", token, resolved)

# A finite wrapper can hide a concrete write from the top-level argv scanner:
# `timeout ... bash -c '... > proof/eci_wait'` and `env -S '... > proof/...'
# are still ordinary shell execution, but their resolved target is a worker
# control record. Decode only these bounded wrapper/interpreter forms; do not
# reject a wrapper or punctuation merely because it is present.
def shell_tokens(value):
    try:
        lexer = shlex.shlex(value, posix=True, punctuation_chars=True)
        lexer.whitespace_split = True
        return list(lexer)
    except ValueError:
        return None

def nested_segments(values):
    segments, current = [], []
    for token in values + [";"]:
        if token in operators:
            if current:
                segments.append(current)
            current = []
        else:
            current.append(token)
    return segments

def nested_emit_path(token):
    if not token or token.startswith("-") or token in operators:
        return False
    candidates = resolve_candidates(token)
    if not candidates:
        if unresolved_control_target(token):
            print("write token=%s resolved=<unknown-cwd>" % token)
            raise SystemExit(0)
        return False
    for candidate in candidates:
        resolved = os.path.realpath(candidate)
        control_alias = current_control_hardlink(candidate)
        if not control_alias:
            control_alias = current_control_hardlink(resolved)
        if control_alias:
            print("write token=%s resolved=%s" % (token, control_alias))
            raise SystemExit(0)
        if nonlive_foreign_marker_path(candidate):
            continue
        if (in_root(candidate) or in_root(resolved)) and protected_control_path(candidate):
            print("write token=%s resolved=%s" % (token, resolved))
            raise SystemExit(0)
    return False

def nested_shell_payload(payload, depth):
    nested = shell_tokens(payload)
    if nested is None:
        return
    # Redirection operators are separators in `nested_segments`; inspect only
    # output targets so input-only operands remain transparent.
    for value in redirect_writer_operands(nested):
        nested_emit_path(value)
    for segment in nested_segments(nested):
        nested_inspect(segment, depth + 1)

def nested_inspect(values, depth=0):
    if depth > 5 or not values:
        return
    name = os.path.basename(values[0])
    if name == "eval":
        # Resolve a literal eval payload for concrete control-path writes;
        # unknown payloads stay transparent and are handled by ordinary shell
        # execution rather than denied for indirection alone.
        nested_shell_payload(" ".join(values[1:]), depth)
        return
    if name in {"source", "."}:
        # Sourcing an arbitrary script has no statically resolved write target.
        # Canonical lifecycle/control targets are recognized by their direct
        # effect routes elsewhere in the hook.
        return
    if name == "env":
        index = 1
        while index < len(values):
            value = values[index]
            if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=.*", value) or value in {"-i", "--ignore-environment"}:
                index += 1
                continue
            if value in {"-u", "--unset", "-C", "--chdir"}:
                index += 2
                continue
            if value.startswith(("--unset=", "--chdir=")):
                index += 1
                continue
            if value == "-S" or value == "--split-string":
                if index + 1 < len(values):
                    nested_shell_payload(values[index + 1], depth)
                return
            if value == "--":
                index += 1
            break
        nested_inspect(values[index:], depth + 1)
        return
    if name in {"timeout", "time", "nice", "prlimit", "chronic", "systemd-run"}:
        index = 1
        value_options = {
            "-k", "--kill-after", "-s", "--signal", "-n", "--adjustment",
            "-p", "--property", "--unit", "--setenv", "--working-directory",
            "-C", "--chdir",
        }
        while index < len(values) and values[index].startswith("-"):
            if values[index] == "--":
                index += 1
                break
            index += 2 if values[index] in value_options and index + 1 < len(values) else 1
        if name == "timeout" and index < len(values) and re.fullmatch(r"[0-9]+(?:\.[0-9]+)?[smhd]?", values[index]):
            index += 1
        nested_inspect(values[index:], depth + 1)
        return
    if name in {"command", "builtin", "exec", "nohup", "setsid", "sudo", "doas"}:
        nested_inspect(values[1:], depth + 1)
        return
    if name in {"bash", "sh", "dash", "zsh", "ksh", "ash", "fish"}:
        for index, value in enumerate(values[1:], 1):
            if value == "-c" or value.startswith("--command="):
                payload = value.split("=", 1)[1] if value.startswith("--command=") else (
                    values[index + 1] if index + 1 < len(values) else ""
                )
                if payload:
                    nested_shell_payload(payload, depth)
                return
        return
    for value in command_writer_operands(values) + redirect_writer_operands(values):
        nested_emit_path(value)

for segment in nested_segments(tokens):
    nested_inspect(segment)
if instruction_denied_detail:
    print(instruction_denied_detail)
    raise SystemExit(0)
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
  python3 - "$1" "$(planner_shell_analysis_for "$1")" "$(git_effect_python)" <<'PY'
import json
import os
import re
import shlex
import sys

exec(compile(sys.argv[3], "git-effect-library", "exec"))

text = sys.argv[1]
operators = {";", "&", "&&", "|", "||", "(", ")"}
git_mutators = {
    "merge", "rebase", "cherry-pick", "revert", "am", "apply",
    "tag",
}
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

def inspect(
    segment: list[str],
    depth: int = 0,
    unknown: frozenset[int] = frozenset(),
    variable_cardinality: frozenset[int] = frozenset(),
) -> bool:
    if depth > 6 or not segment:
        return depth > 6
    index = 0
    while index < len(segment) and assignment(segment[index]):
        index += 1
    if index >= len(segment):
        return False
    if index in unknown or any(value < index for value in variable_cardinality):
        return False
    name = os.path.basename(segment[index])
    if name == "git":
        index += 1
        # Git's global options are execution context, not acceptance
        # mutations on their own.  In particular, an option-only invocation
        # such as `env git --lost-found` is invalid Git and exits before it
        # can change repository state; classifying the option as a commit
        # boundary would turn a harmless runtime error into a misleading
        # worker denial.  Skip global options (and their separate operands),
        # then classify only a concrete Git subcommand/effect below.
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
                index += 1
                continue
            if index in unknown or any(value <= index for value in variable_cardinality):
                return False
            argument_unknown = frozenset(value - index - 1 for value in unknown if value > index)
            argument_variable = frozenset(value - index - 1 for value in variable_cardinality if value > index)
            if token == "apply":
                return git_apply_effect(segment[index + 1:], argument_unknown, argument_variable) == "mutation"
            if token in git_mutators:
                return True
            if token == "branch":
                return git_branch_effect(segment[index + 1:], argument_unknown, argument_variable) == "repository"
            if token == "remote":
                return bool(segment[index + 1:] and index + 1 not in unknown and segment[index + 1] in remote_mutators)
            return False
        return False
    if name in {"bash", "sh", "dash", "zsh"}:
        for option_index, option in enumerate(segment[index + 1:], index + 1):
            if option == "-c" or (option.startswith("-") and "c" in option[1:]):
                if option_index + 1 >= len(segment):
                    return True
                if option_index in unknown or option_index + 1 in unknown:
                    return False
                nested = tokenize(segment[option_index + 1])
                return nested is not None and any(inspect(part, depth + 1) for part in split(nested))
        return False
    if name == "eval":
        # Evaluate only the literal payload for a concrete acceptance-sensitive
        # Git effect.  An ordinary or unresolved payload is not itself a
        # reason to reroute the worker.
        if any(offset in unknown for offset in range(index + 1, len(segment))):
            return False
        nested = tokenize(" ".join(segment[index + 1:]))
        return nested is not None and any(
            inspect(part, depth + 1) for part in split(nested)
        )
    if name == "env":
        index += 1
        while index < len(segment):
            token = segment[index]
            if assignment(token) or token in {"-i", "--ignore-environment"}:
                index += 1
                continue
            if token in {"-u", "--unset", "-C", "--chdir", "-S", "--split-string", "-a", "--argv0"} and index + 1 < len(segment):
                if token in {"-S", "--split-string"}:
                    if index in unknown or index + 1 in unknown:
                        return False
                    nested = tokenize(segment[index + 1])
                    return nested is not None and any(inspect(part, depth + 1) for part in split(nested))
                index += 2
                continue
            if token.startswith("-"):
                index += 1
                continue
            break
        if any(value < index for value in variable_cardinality):
            return False
        return inspect(segment[index:], depth + 1,
                       frozenset(value - index for value in unknown if value >= index),
                       frozenset(value - index for value in variable_cardinality if value >= index))
    if name == "timeout":
        return False
    if name in {"systemd-run", "nice", "time", "prlimit", "chronic"}:
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
        if any(value < index for value in variable_cardinality):
            return False
        return inspect(segment[index:], depth + 1,
                       frozenset(value - index for value in unknown if value >= index),
                       frozenset(value - index for value in variable_cardinality if value >= index))
    if name in {"command", "builtin", "exec", "nohup", "setsid", "sudo", "doas"}:
        index += 1
        if any(value < index for value in variable_cardinality):
            return False
        return inspect(segment[index:], depth + 1,
                       frozenset(value - index for value in unknown if value >= index),
                       frozenset(value - index for value in variable_cardinality if value >= index))
    if name in {"xargs", "find"}:
        # These launchers receive commands indirectly; a visible Git token is
        # enough to route the whole acceptance-sensitive command to main.
        return any(offset not in unknown and os.path.basename(token) == "git"
                   for offset, token in enumerate(segment[index + 1:], index + 1))
    return False

analysis = json.loads(sys.argv[2])
if analysis is not None:
    found = any(inspect(record["argv"], unknown=frozenset(record.get("unknown_arguments") or []),
                        variable_cardinality=frozenset(record.get("may_disappear_arguments") or []) |
                        frozenset(record.get("may_multiply_arguments") or []) |
                        frozenset(record.get("unknown_cardinality_arguments") or []) |
                        (frozenset(record.get("unknown_arguments") or [])
                         if "may_disappear_arguments" not in record else frozenset())) for record in analysis["commands"]
                if record["reachability"] != "unreachable")
else:
    parsed = tokenize(text)
    # Unparsed text does not establish a Git mutation.
    found = parsed is not None and any(inspect(part) for part in split(parsed))
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
    os.environ["CODEX_CONFIGURED_HOME"]
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
    return bool(args) and args[0] in {target, "aggregate-off"}

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
    return real_eci(segment[index]) and index + 1 < len(segment) and segment[index + 1] in {"off", "aggregate-off"}

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
targets = {"on", "wait", "resume", "ledger-append", "nested-enter", "nested-accept", "nested-exit", "manifest-write", "aggregate-migrate", "aggregate-stage", "aggregate-manifest-write", "aggregate-review", "aggregate-commit"}
configured_home = os.path.realpath(os.path.abspath(
    os.environ["CODEX_CONFIGURED_HOME"]
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

    if command == "eval":
        nested = tokenize(" ".join(segment[index + 1:]))
        return nested is not None and any(
            inspect(part, depth + 1) for part in split(nested)
        )

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
    "nested-accept", "nested-exit", "manifest-write", "approve-commit", "maintain-planner",
    "accidental-override-cleanup", "aggregate-review", "aggregate-stage",
    "repository-allow-on", "repository-allow-off", "repository-allow-status",
}

home = os.environ.get("HOME", "")
codex_home = os.environ["CODEX_CONFIGURED_HOME"]
home_lifecycle_paths = {
    "$HOME/.codex/bin/eci-active": os.path.join(codex_home, "bin", "eci-active"),
    "$HOME/.kimi-code/bin/eci-active": os.path.join(home, ".kimi-code", "bin", "eci-active"),
}
roots = []
for value in (
    # Codex lifecycle authority is the literal current-home route.  Admission
    # still belongs to coordinator_peer_eci_route, which binds the exact
    # current-home executable and its runtime-sync receipt.
    codex_home,
    os.environ.get("KIMI_CODE_HOME", ""),
    os.path.join(home, ".kimi-code"),
):
    if not value or not os.path.isabs(value) or os.path.islink(value):
        continue
    root = os.path.realpath(value)
    if os.path.normpath(root) != root or not os.path.isdir(root):
        continue
    roots.append(os.path.join(root, "bin", "eci-active"))
canonical = set(roots)

def lifecycle_path(value):
    expanded = home_lifecycle_paths.get(value, os.path.expanduser(value))
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
codex_home = os.environ["CODEX_CONFIGURED_HOME"]
home_lifecycle_paths = {
    "$HOME/.codex/bin/eci-active": os.path.join(codex_home, "bin", "eci-active"),
    "$HOME/.kimi-code/bin/eci-active": os.path.join(home, ".kimi-code", "bin", "eci-active"),
}
roots = []
for value in (
    # See command_invokes_eci_lifecycle: the exact current-home lifecycle
    # identity must remain visible to later checks.
    codex_home,
    os.environ.get("KIMI_CODE_HOME", ""),
    os.path.join(home, ".kimi-code"),
):
    if not value or not os.path.isabs(value) or os.path.islink(value):
        continue
    root = os.path.realpath(value)
    if os.path.normpath(root) != root or not os.path.isdir(root):
        continue
    roots.append(os.path.join(root, "bin", "eci-active"))
canonical = set(roots)

def lifecycle_path(value):
    expanded = home_lifecycle_paths.get(value, os.path.expanduser(value))
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

# A worker may use only the explicit owner-scoped repository declaration
# lifecycle route. The CLI validates the active marker and canonical Git
# target; this parser admits the shape without turning other eci-active calls
# into worker capabilities. Resolve the executable identity so an absolute
# spelling of the same configured Codex binary follows the same route.
worker_repository_allow_lifecycle_route() {
  [ "${hook_is_subagent:-false}" = true ] || return 1
  python3 - "$1" "$session_id" <<'PY'
import os
import re
import shlex
import sys

command_text, expected_session = sys.argv[1:3]
try:
    lexer = shlex.shlex(command_text, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    tokens = list(lexer)
except ValueError:
    raise SystemExit(1)
operators = {";", "&", "&&", "|", "||", "(", ")", ">", ">>", "<", "<<", "<<<", ">|", ">&", "<&"}
if any(token in operators for token in tokens):
    raise SystemExit(1)
if tokens and tokens[0] == "env":
    tokens = tokens[1:]
    if tokens and tokens[0] == "--":
        tokens = tokens[1:]
    while tokens and tokens[0].startswith("CODEX_SESSION_ID="):
        match = re.fullmatch(r"CODEX_SESSION_ID=([A-Za-z0-9][A-Za-z0-9_.-]{0,127})", tokens[0])
        if not match or match.group(1) != expected_session:
            raise SystemExit(1)
        tokens = tokens[1:]
configured_home = os.environ.get("CODEX_CONFIGURED_HOME", "")
if not configured_home or not os.path.isabs(configured_home) or os.path.islink(configured_home):
    raise SystemExit(1)
configured_root = os.path.realpath(configured_home)
if os.path.normpath(configured_root) != configured_root or not os.path.isdir(configured_root):
    raise SystemExit(1)
canonical_executable = os.path.join(configured_root, "bin", "eci-active")
if not tokens:
    raise SystemExit(1)
executable = os.path.expandvars(os.path.expanduser(tokens[0]))
if not os.path.isabs(executable) or os.path.realpath(executable) != canonical_executable:
    raise SystemExit(1)
if len(tokens) == 2 and tokens[1] == "repository-allow-status":
    raise SystemExit(0)
if len(tokens) == 3 and tokens[1] == "repository-allow-off":
    target = tokens[2]
    raise SystemExit(0 if target.startswith("/") and target == os.path.normpath(target) else 1)
if len(tokens) == 4 and tokens[1] == "repository-allow-on":
    target, reason = tokens[2:]
    if not target.startswith("/") or target != os.path.normpath(target) or not reason:
        raise SystemExit(1)
    if any(ord(char) < 32 or ord(char) == 127 for char in reason):
        raise SystemExit(1)
    raise SystemExit(0)
raise SystemExit(1)
PY
}

classify_eci_command() {
  python3 - "$1" <<'PY'
import os
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


AGGREGATE_STAGE_CONTROL_EXACT = {
    "eci-wait-repair-authorize", "eci_active", "eci-additional-repository", "goal_state", "eci_wait",
    "eci_user_owned_wait.md", "eci-permissive-mode", "eci-permissive-authorize",
    ".eci-permissive-mode", ".eci-permissive-authorize", "eci-required-critics.json",
    "eci-critic-identities.ledger", "eci-acceptance-anchor", "eci-acceptance-transaction",
    "eci-teardown-complete", "eci-baseline-binding", "baseline_head", "eci-commit-admitted",
    "eci-user-closed.ledger", "eci-aggregate-plan.json", "eci-aggregate-teardown-complete",
    "eci-accidental-mistake-override", ".eci-accidental-mistake-override",
    ".eci-accidental-mistake-override.claim", "ate_nested_eci_active",
    "ate_nested_eci_completion", "eci-blocker-report.md", "stop_timestamps", "stop_loop_state",
    "disengage.md", "user-closed.md", "proof.md", "instructions.md", "project-understanding.md",
    "high_level_log.md", "latest-status-report.md", "high_level_log.anchor",
}
AGGREGATE_STAGE_CONTROL_PREFIXES = (
    "eci-wait-repair-authorize.", "eci_active.", "eci-additional-repository.", "goal_state.", "eci_wait.",
    "eci_user_owned_wait.md.", "eci-permissive-mode.", "eci-permissive-authorize.",
    ".eci-permissive-mode.", ".eci-permissive-authorize.", "eci-required-critics.",
    "eci-critic-identities.ledger.", "eci-acceptance-anchor.",
    "eci-acceptance-transaction.", "eci-teardown-complete.", "eci-prewrite-admitted.",
    "eci-baseline-binding.", "baseline_head.", "eci-commit-admitted.",
    "eci-user-closed.ledger.", "eci-aggregate-plan.json.",
    "eci-aggregate-teardown-complete.", "eci-aggregate.",
    "eci-accidental-mistake-override.", ".eci-accidental-mistake-override.",
    "ate_nested_eci_active.", "ate_nested_eci_completion.", "stop_loop_state.",
    "project-understanding.md.", "high_level_log.md.", "latest-status-report.md.",
    "high_level_log.anchor.", "high_level_log.md.tmp.",
)
AGGREGATE_STAGE_APPROVAL_BASENAMES = {
    ".git-reset-approved-once", ".git-worktree-approved-once", ".git-commit-approved-once",
}


def aggregate_stage_control_basename(value):
    return (value in AGGREGATE_STAGE_CONTROL_EXACT or
            value.startswith(AGGREGATE_STAGE_CONTROL_PREFIXES))


def aggregate_stage_approval_basename(value):
    return (value in AGGREGATE_STAGE_APPROVAL_BASENAMES or
            (value.startswith(".git-") and value.endswith("-approved-once")))


def safe_aggregate_stage_path(value):
    if (not isinstance(value, str) or not value or len(value.encode()) > 4096 or
            "\n" in value or "\r" in value or
            any(ord(char) < 32 or ord(char) == 127 for char in value)):
        return False
    if (os.path.isabs(value) or value in {".", "..", "--"} or value.endswith("/") or
            value.startswith("./") or value.startswith("../") or "//" in value or
            "/./" in value or "/../" in value or any(char in value for char in "*?[]") or
            ":(" in value):
        return False
    components = value.split("/")
    return all(
        component and component not in {".", "..", ".git"} and
        not aggregate_stage_approval_basename(component) and
        not aggregate_stage_control_basename(component)
        for component in components
    )


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
    os.environ["CODEX_CONFIGURED_HOME"]
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
    # Status can invoke the configured filesystem-monitor hook. It therefore
    # has no generic read-only route while active ECI is enforcing ownership.
    return False


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
    """Do not admit diff pipelines before a config-neutral Git route exists."""
    return False


def bounded_git_c_read_only(segment, index):
    # See bounded_git_diff_sed_pipeline: raw Git remains provider-deferred.
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


def safe_read_only_args(args):
    """Reject options that turn a nominally read-only utility into a writer."""
    forbidden = {
        "-i", "--in-place", "--delete", "-delete", "-exec", "-execdir", "-ok", "-okdir",
        "-o", "--output", "--textconv", "--ext-diff",
        "-C", "-c", "--config-env", "--git-dir", "--work-tree", "--exec-path",
        "--namespace", "--super-prefix",
    }
    return not any(
        token in forbidden
        or token.startswith(("-o", "--output=", "--textconv=", "--ext-diff=",
                             "--config-env=", "--git-dir=", "--work-tree=", "--exec-path=",
                             "--namespace=", "--super-prefix="))
        for token in args
    )


def approved_read_roots():
    worker_home = os.path.realpath(
        os.environ["CODEX_CONFIGURED_HOME"]
    ) if os.environ.get("CODEX_HOOK_IS_SUBAGENT") == "true" else ""
    canonical_peer_homes = {
        os.path.realpath(os.environ["CODEX_CONFIGURED_HOME"]),
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
    if command == "file":
        # GNU file -C/--compile writes a compiled .mgc sibling.  Keep this
        # parser structural: only a short inspection option set, one literal
        # magic-file selector, and one to sixteen approved operands can use
        # the active read-only route.
        read_only_options = {
            "-b", "--brief", "-h", "--no-dereference", "-i", "--mime",
            "--mime-encoding", "--mime-type", "-L", "--dereference",
        }
        paths = []
        options = True
        magic_seen = False
        index = 0
        while index < len(args):
            token = args[index]
            if options and token == "--":
                options = False
                index += 1
                continue
            if options and (token in {"-C", "--compile"} or token.startswith("--compile=") or
                            (token.startswith("-") and not token.startswith("--") and "C" in token[1:])):
                return False
            if options and token in {"-m", "--magic-file"}:
                if magic_seen or index + 1 >= len(args) or not approved_read_path(args[index + 1], roots):
                    return False
                magic_seen = True
                index += 2
                continue
            if options and token.startswith("--magic-file="):
                magic_path = token.split("=", 1)[1]
                if magic_seen or not approved_read_path(magic_path, roots):
                    return False
                magic_seen = True
                index += 1
                continue
            if options and token in read_only_options:
                index += 1
                continue
            if options and token.startswith("-"):
                return False
            if not approved_read_path(token, roots):
                return False
            options = False
            paths.append(token)
            if len(paths) > 16:
                return False
            index += 1
        return bool(paths)
    if command == "uniq":
        # uniq [INPUT [OUTPUT]] writes OUTPUT.  The active generic route is
        # only a filter (stdin) or a one-input inspection, never a writer.
        return (not args and pipeline_stdin) or (
            len(args) == 1 and approved_read_path(args[0], roots)
        )
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
        token in {"-o", "--output"}
        or token.startswith("--output=")
        for token in args
    ):
        return False
    if pipeline_stdin and command in {"cat", "sha256sum"} and not args:
        return True
    if command in {"echo", "cat", "cmp", "diff", "du", "sha256sum", "tr", "basename", "dirname"}:
        return bool(args) and all(approved_read_path(token, roots) for token in args if not token.startswith("-"))
    if command == "ls":
        allowed = {"-1", "-a", "-l", "-t", "-lt", "-h", "-d", "-i", "-la", "-al", "-li", "-il", "-ld", "-dl", "--all", "--human-readable", "--directory"}
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
                if args[index + 1] not in {"%s", "%a %n", "%A %n", "%i %a %n", "%i %a %h %n", "%d:%i %a %h %n", "%F %N", "%F %s %n", "%y %n", "%y %s %n"}:
                    return False
                index += 2
                continue
            if command == "stat" and token.startswith("--format="):
                if token.split("=", 1)[1] not in {"%s", "%a %n", "%A %n", "%i %a %n", "%i %a %h %n", "%d:%i %a %h %n", "%F %N", "%F %s %n", "%y %n", "%y %s %n"}:
                    return False
                index += 1
                continue
            if command == "stat" and token in {"-L", "--dereference"}:
                index += 1
                continue
            if command == "stat" and token in {"-Lc", "-cL"} and index + 1 < len(args):
                if args[index + 1] not in {"%s", "%a %n", "%A %n", "%i %a %n", "%i %a %h %n", "%d:%i %a %h %n", "%F %N", "%F %s %n", "%y %n", "%y %s %n"}:
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
        if lifecycle[0] == "aggregate-migrate" and len(lifecycle) == 2:
            return CONTROL
        if (lifecycle[0] == "aggregate-stage" and len(lifecycle) >= 4 and
                lifecycle[2] == "--" and
                all(safe_aggregate_stage_path(path) for path in lifecycle[3:])):
            return CONTROL
        if lifecycle[0] == "aggregate-manifest-write" and len(lifecycle) == 3:
            return CONTROL
        if lifecycle[0] in {"aggregate-review", "aggregate-commit"} and len(lifecycle) == 3:
            return CONTROL
        if lifecycle[0] == "aggregate-off" and len(lifecycle) == 2:
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
        # All shell-test forms are evaluated by reviewed_script_route before
        # this generic classifier. Never make a filename or syntax-only form
        # read-only here, because that would bypass its reviewed byte binding.
        return UNKNOWN
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
            if token == "checkout":
                # Checkout is routed to the concrete worktree-effect
                # resolver. Branch/ref forms remain transparent there; only
                # a resolved protected path becomes a coordinator edit route.
                return UNKNOWN if (
                    saw_assignment or repo_context_changed or git_global_seen
                    or INHERITED_GIT_CONTEXT
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
            # All remaining inspection verbs can inherit configuration or
            # attributes that execute helpers. They remain unknown until a
            # single config-neutral route proves its complete environment.
            return UNKNOWN
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
    os.environ["CODEX_CONFIGURED_HOME"]
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
  # This resolver enriches known Git targets. It is not a permission parser:
  # unfamiliar spelling or shell topology is advisory and must not turn
  # ordinary repository work into a denial.
  local command_text="${1:-$command}" timeout_replays="${PLAN_TIMEOUT_REPLAYS:-[]}"
  local worker_mode="${hook_is_subagent:-false}"
  python3 - "$command_text" "${cwd:-$PWD}" "$timeout_replays" "$worker_mode" "$(planner_shell_analysis_for "$command_text")" "$(git_effect_python)" <<'PY'
import json
import os
import re
import shlex
import sys

exec(compile(sys.argv[6], "git-effect-library", "exec"))

command, cwd = sys.argv[1:3]
worker_mode = len(sys.argv) > 4 and sys.argv[4] == "true"
cwd = cwd or os.getcwd()
try:
    timeout_replays = json.loads(sys.argv[3])
except (IndexError, TypeError, ValueError):
    raise SystemExit(0)
MUTATING_WORKTREE = {"add", "remove", "move", "prune", "lock", "unlock", "repair"}
READ_ONLY_GIT = {
    "branch", "describe", "diff", "grep", "log", "ls-files", "rev-parse",
    "show", "status", "submodule", "remote",
}
SEPARATORS = {";", "&", "&&", "|", "||"}
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=(.*)$")


def resolve(path: str | None, base: str | None) -> str | None:
    if path is None:
        return None
    path = os.path.expanduser(path)
    if os.path.isabs(path):
        return os.path.normpath(path)
    if not base or not os.path.isabs(base):
        return None
    return os.path.normpath(os.path.join(base, path))


def observed_timeout_command_index(tokens, index, segment_index):
    if index >= len(tokens) or os.path.basename(tokens[index]) != "timeout":
        return index, None
    matches = []
    for replay in timeout_replays:
        if not isinstance(replay, dict) or replay.get("segment") != segment_index:
            continue
        if replay.get("disposition") != "observed":
            continue
        if not isinstance(replay.get("cwd"), str) or not replay["cwd"].startswith("/"):
            continue
        prefix = replay.get("prefix")
        if not isinstance(prefix, list) or not all(isinstance(value, str) for value in prefix):
            continue
        if len(prefix) < 2 or index + len(prefix) >= len(tokens):
            continue
        if tokens[index:index + len(prefix)] == prefix:
            matches.append((index + len(prefix), replay))
    return matches[0] if len(matches) == 1 else (None, None)


def commit_effect(
    arguments: list[str],
    unknown: frozenset[int] = frozenset(),
    variable_cardinality: frozenset[int] = frozenset(),
) -> str | None:
    # Git v2.51.0 builtin/commit.c defines this option inventory. Resolve
    # abbreviations before arity so --mes --dry-run consumes a message.
    required_values = {
        "file", "author", "date", "message", "reedit-message", "reuse-message",
        "fixup", "squash", "trailer", "template", "cleanup", "unified",
        "inter-hunk-context", "pathspec-from-file",
    }
    optional_values = {"gpg-sign", "untracked-files"}
    nonnegatable = {"trailer", "unified", "inter-hunk-context"}
    negative_names = {"verify", "post-rewrite"}
    selection_options = {"include", "only", "interactive", "patch", "pathspec-from-file"}
    state = dict.fromkeys(selection_options | {"all", "amend", "dry-run", "null"}, False)
    format_options = {"short", "porcelain", "long"}
    long_options = required_values | optional_values | state.keys() | format_options | {
        "quiet", "verbose", "reset-author", "signoff", "edit", "status",
        "branch", "ahead-behind", "pathspec-file-nul", "allow-empty",
        "allow-empty-message",
    } | negative_names
    short_effects = {"a": "all", "i": "include", "o": "only", "p": "patch", "z": "null"}
    format_preview = False
    path_operands = False
    option_unknown = False
    arity_unknown = False
    established = None
    preview_may_change = False

    def lose_arity(can_change_preview: bool = True) -> None:
        nonlocal arity_unknown, established, preview_may_change
        if not arity_unknown:
            established = (state.copy(), path_operands, format_preview)
        arity_unknown = True
        preview_may_change = preview_may_change or can_change_preview

    index = 0
    while index < len(arguments):
        argument = arguments[index]
        argument_unknown = index in unknown
        if index in variable_cardinality:
            lose_arity()
        index += 1
        if argument in {"--", "--end-of-options"}:
            path_operands = path_operands or index < len(arguments)
            break
        if argument_unknown and argument.startswith("$?"):
            # A standalone scalar may itself be an option, including a
            # preview cancellation. Known option values were consumed above.
            option_unknown = True
            lose_arity()
            continue
        if argument == "-" or not argument.startswith("-"):
            path_operands = True
            continue
        if argument.startswith("--"):
            name, separator, value = argument[2:].partition("=")
            negated = name.startswith("no-")
            candidates = long_options
            if negated:
                name = name[3:]
                candidates = candidates - nonnegatable
                # Git accepts double negation only for names declared with
                # no-: no-verify and no-post-rewrite (parse-options.c).
                if name.startswith("no-"):
                    name = name[3:]
                    candidates = negative_names
            matches = {name} if name in candidates else {
                option for option in candidates if option.startswith(name)
            }
            if len(matches) != 1:
                if not argument_unknown:
                    return None
                # An attached value cannot consume the next option. A bare
                # unknown option may consume it or end option parsing, so
                # following argument roles are not established.
                option_unknown = True
                if not separator:
                    lose_arity()
                continue
            name = next(iter(matches))
            takes_value = name in required_values | optional_values
            if separator and (negated or not takes_value):
                return None
            value_unknown = argument_unknown
            if not negated and name in required_values and not separator:
                if index == len(arguments):
                    return None
                value = arguments[index]
                value_unknown = index in unknown
                if index in variable_cardinality:
                    lose_arity()
                index += 1
            if name == "pathspec-from-file":
                # Git's OPT_FILENAME treats an empty value as NULL, clearing
                # any earlier pathspec file just as negation does.
                state[name] = None if not negated and value_unknown else not negated and bool(value)
            elif name in state:
                state[name] = not negated
            elif name in format_options:
                # These options share status_format; every negation sets
                # it to NONE, even if a different format set it earlier.
                format_preview = not negated
            continue
        for option_index, option in enumerate(argument[1:], 1):
            if option in {"m", "F", "C", "c", "t", "U"}:
                if option_index == len(argument) - 1:
                    if index == len(arguments):
                        return None
                    if index in variable_cardinality:
                        lose_arity()
                    index += 1
                break
            if option in {"S", "u"}:  # Optional values consume only the suffix.
                break
            if option in short_effects:
                state[short_effects[option]] = True
            elif option not in {"q", "v", "s", "e", "n"}:
                if not argument_unknown:
                    return None
                option_unknown = True
                # An opaque first option character can produce a long
                # preview cancellation; later argv may also change state.
                lose_arity(argument.startswith("-$?") or index < len(arguments))
                break

    # finalize_deferred_config and parse_and_validate_options in commit.c
    # make final status format/null output imply preview independently of
    # the final explicit dry-run flag. Negated flags must not stay latched.
    if arity_unknown:
        # Later opaque argv cannot invent an effect, but an option whose
        # role was already established keeps its concrete boundary.
        prior, prior_paths, prior_format = established
        if prior["dry-run"] or prior_format or prior["null"]:
            # Losing proof of preview does not itself prove a mutation.
            return "commit-option-unresolved" if preview_may_change else None
        if prior["all"]:
            return "commit-all"
        if prior_paths or any(prior[option] for option in selection_options):
            return "commit-stage"
        if prior["amend"]:
            return "commit-amend"
        if prior["pathspec-from-file"] is None:
            return "commit-unresolved"
        return "commit-option-unresolved"
    if state["dry-run"] or format_preview or state["null"]:
        return None
    if state["all"]:
        return "commit-all"
    if path_operands or any(state[option] for option in selection_options):
        return "commit-stage"
    if state["amend"]:
        return "commit-amend"
    if state["pathspec-from-file"] is None:
        return "commit-unresolved"
    if option_unknown:
        return "commit-option-unresolved"
    return "commit"


def segment_spec(
    tokens: list[str],
    segment_index: int,
    unknown: frozenset[int] = frozenset(),
    may_disappear: frozenset[int] = frozenset(),
    may_multiply: frozenset[int] = frozenset(),
    cardinality_unknown: frozenset[int] = frozenset(),
) -> tuple[str, str | None] | None:
    if not tokens:
        return None

    index = 0
    environment = {}
    # Shell control words, labels, assignments, and redirections are
    # structural context.  They do not change the concrete Git child that
    # follows them, so skip them before resolving that child.
    while index < len(tokens):
        value = tokens[index]
        if value in {"if", "then", "else", "elif", "while", "until", "do", "{", "}"}:
            index += 1
            continue
        if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_-]*:", value):
            index += 1
            continue
        if value in {">", ">>", "<", "<<", ">|", "<<<", "<&", ">&"}:
            index += min(2, len(tokens) - index)
            continue
        if value.isdigit() and index + 1 < len(tokens) and tokens[index + 1] in {">", ">>", "<", "<<", ">|", "<<<", "<&", ">&"}:
            index += 1
            continue
        break
    while index < len(tokens):
        assignment = ASSIGNMENT.fullmatch(tokens[index])
        if not assignment:
            break
        name, value = tokens[index].split("=", 1)
        environment[name] = None if index in unknown else value
        index += 1

    original_index = index
    index, timeout_replay = observed_timeout_command_index(tokens, index, segment_index)
    # An observed timeout replay is useful context when the planner has it,
    # but a plain finite `timeout DURATION git ...` is still an ordinary
    # structural wrapper.  Missing replay metadata must not make the wrapper
    # a permission boundary.
    if index is None:
        if (original_index >= len(tokens) or
                os.path.basename(tokens[original_index]) != "timeout"):
            return None
        index = original_index
    repo_dir = timeout_replay["cwd"] if timeout_replay else cwd

    # `env NAME=value git ...` is a normal spelling. Its assignments help
    # resolve a concrete target, but do not themselves require a special
    # route. An observed direct timeout may select this exact env child.
    def consume_env(index: int, repo_dir: str | None) -> tuple[int, str | None] | None:
        index += 1
        while index < len(tokens):
            assignment = ASSIGNMENT.fullmatch(tokens[index])
            if assignment:
                name, value = tokens[index].split("=", 1)
                environment[name] = None if index in unknown else value
                index += 1
                continue
            if tokens[index] == "--":
                return index + 1, repo_dir
            if tokens[index] in {"-C", "--chdir"}:
                if index + 1 >= len(tokens):
                    return None
                return_index = index + 2
                repo_dir = resolve(None if index + 1 in unknown else tokens[index + 1], repo_dir)
                index = return_index
                continue
            if tokens[index].startswith("--chdir="):
                repo_dir = resolve(None if index in unknown else tokens[index].split("=", 1)[1], repo_dir)
                index += 1
                continue
            if tokens[index].startswith("-"):
                if tokens[index] in {"-i", "--ignore-environment", "-v", "--debug"}:
                    if tokens[index] in {"-i", "--ignore-environment"}:
                        environment.clear()
                    index += 1
                    continue
                if tokens[index] in {"-u", "--unset", "-a", "--argv0"}:
                    if index + 1 >= len(tokens):
                        return None
                    if tokens[index] in {"-u", "--unset"}:
                        if index + 1 in unknown:
                            environment.update((name, None) for name in environment)
                        else:
                            environment.pop(tokens[index + 1], None)
                    index += 2
                    continue
                if tokens[index].startswith("--unset="):
                    if index in unknown:
                        environment.update((name, None) for name in environment)
                    else:
                        environment.pop(tokens[index].split("=", 1)[1], None)
                    index += 1
                    continue
                if tokens[index].startswith("--argv0=") or tokens[index].startswith("-a"):
                    index += 1
                    continue
                return None
            break
        return index, repo_dir

    if index < len(tokens) and os.path.basename(tokens[index]) == "env":
        result = consume_env(index, repo_dir)
        if result is None:
            return None
        index, repo_dir = result

    # Transparent launch wrappers preserve the Git child and its current
    # repository target. Their option values are skipped structurally; no
    # finite wrapper-name allowlist is used as an admission decision.
    while index < len(tokens):
        if index in unknown:
            return None
        name = os.path.basename(tokens[index])
        if name == "env":
            result = consume_env(index, repo_dir)
            if result is None:
                return None
            index, repo_dir = result
            continue
        if name in {"command", "builtin", "exec", "nohup", "setsid"}:
            index += 1
            while index < len(tokens) and tokens[index].startswith("-"):
                if name == "exec" and tokens[index] == "-a":
                    if index + 1 >= len(tokens):
                        return None
                    index += 2
                else:
                    index += 1
            continue
        if name == "busybox":
            index += 1
            if index < len(tokens) and tokens[index] == "--":
                index += 1
            continue
        if name == "stdbuf":
            index += 1
            while index < len(tokens) and tokens[index].startswith("-"):
                index += 1
            continue
        if name == "timeout":
            # A coordinator keeps an unobserved timeout opaque because its
            # callback-selected executable may not launch the child. An
            # active worker's finite literal timeout is a concrete wrapper
            # around the visible child and must not bypass Git ownership.
            if (not timeout_replay or timeout_replay.get("disposition") != "observed") and not worker_mode:
                return None
            index += 1
            while index < len(tokens) and tokens[index].startswith("-"):
                option = tokens[index]
                if option in {"-k", "--kill-after", "-s", "--signal"}:
                    if index + 1 >= len(tokens):
                        return None
                    index += 2
                elif option.startswith(("--kill-after=", "--signal=")):
                    index += 1
                else:
                    index += 1
            # timeout requires a duration before its child command.
            if index >= len(tokens) or tokens[index].startswith("-"):
                return None
            index += 1
            continue
        if name in {"chronic", "nice", "time", "prlimit", "systemd-run"}:
            index += 1
            value_options = {
                "-n", "-p", "--adjustment", "--property", "--unit",
                "--setenv", "--working-directory", "-C", "--chdir",
            }
            while index < len(tokens) and tokens[index].startswith("-"):
                if tokens[index] == "--":
                    index += 1
                    break
                option = tokens[index]
                if name == "systemd-run" and option == "--working-directory":
                    if index + 1 >= len(tokens):
                        return None
                    repo_dir = resolve(None if index + 1 in unknown else tokens[index + 1], repo_dir)
                    index += 2
                elif name == "systemd-run" and option.startswith("--working-directory="):
                    repo_dir = resolve(None if index in unknown else option.split("=", 1)[1], repo_dir)
                    index += 1
                elif name == "systemd-run" and option == "--setenv":
                    if index + 1 >= len(tokens):
                        return None
                    name_value = tokens[index + 1].split("=", 1)
                    if len(name_value) == 2 and name_value[0] in {"GIT_DIR", "GIT_WORK_TREE"}:
                        environment[name_value[0]] = None if index + 1 in unknown else name_value[1]
                    index += 2
                elif name == "systemd-run" and option.startswith("--setenv="):
                    name_value = option.split("=", 1)[1].split("=", 1)
                    if len(name_value) == 2 and name_value[0] in {"GIT_DIR", "GIT_WORK_TREE"}:
                        environment[name_value[0]] = None if index in unknown else name_value[1]
                    index += 1
                elif option in value_options:
                    if index + 1 >= len(tokens):
                        return None
                    index += 2
                else:
                    index += 1
            continue
        if name in {"sudo", "doas"}:
            index += 1
            value_options = {
                "-u", "--user", "-g", "--group", "-h", "--host",
                "-p", "--prompt", "-C", "--chdir", "-R", "--chroot",
                "-D", "--chdir", "-r", "--role", "-t", "--type",
            }
            while index < len(tokens) and tokens[index].startswith("-"):
                option = tokens[index]
                if option == "--":
                    index += 1
                    break
                if option in value_options:
                    if index + 1 >= len(tokens):
                        return None
                    # sudo -C is a file-descriptor close option, not a
                    # working-directory option.  Only sudo's directory
                    # options alter the child Git worktree context.
                    if option in {"--chdir", "-D"}:
                        repo_dir = resolve(None if index + 1 in unknown else tokens[index + 1], repo_dir)
                    index += 2
                elif any(option.startswith(value + "=") for value in value_options):
                    if option.startswith(("--chdir=", "-D=")):
                        repo_dir = resolve(None if index in unknown else option.split("=", 1)[1], repo_dir)
                    index += 1
                else:
                    index += 1
            continue
        break

    if index < len(tokens) and os.path.basename(tokens[index]) in {"bash", "sh", "dash", "zsh"}:
        shell_args = tokens[index + 1:]
        for shell_index, shell_value in enumerate(shell_args):
            is_c = shell_value in {"-c", "-lc", "-cl"} or (
                shell_value.startswith("-") and not shell_value.startswith("--") and
                "c" in shell_value[1:]
            )
            if not is_c or shell_index + 1 >= len(shell_args):
                continue
            if index + shell_index + 1 in unknown or index + shell_index + 2 in unknown:
                return None
            try:
                nested_lexer = shlex.shlex(shell_args[shell_index + 1], posix=True, punctuation_chars=True)
                nested_tokens = list(nested_lexer)
            except ValueError:
                return None
            nested_segments, nested_current = [], []
            for nested_value in nested_tokens + [";"]:
                if nested_value in SEPARATORS:
                    if nested_current:
                        nested_segments.append(nested_current)
                        nested_current = []
                else:
                    nested_current.append(nested_value)
            for nested_segment in nested_segments:
                nested_spec = segment_spec(nested_segment, segment_index)
                if nested_spec:
                    return nested_spec
            return None
        return None
    if index >= len(tokens) or index in unknown or os.path.basename(tokens[index]) != "git":
        return None
    index += 1

    git_dir = environment.get("GIT_DIR", "")
    work_tree = environment.get("GIT_WORK_TREE", "")
    value_options = {
        "-c", "--config-env", "--exec-path", "--namespace", "--super-prefix",
        "--source", "--pathspec-from-file",
    }
    while index < len(tokens):
        token = tokens[index]
        if token == "-C":
            if index + 1 >= len(tokens):
                return None
            repo_dir = resolve(None if index + 1 in unknown else tokens[index + 1], repo_dir)
            index += 2
            continue
        if token.startswith("-C") and len(token) > 2:
            repo_dir = resolve(None if index in unknown else token[2:], repo_dir)
            index += 1
            continue
        if token in {"--git-dir", "--work-tree"}:
            if index + 1 >= len(tokens):
                return None
            if token == "--git-dir":
                git_dir = None if index + 1 in unknown else tokens[index + 1]
            else:
                work_tree = None if index + 1 in unknown else tokens[index + 1]
            index += 2
            continue
        if token.startswith("--git-dir="):
            git_dir = None if index in unknown else token.split("=", 1)[1]
            index += 1
            continue
        if token.startswith("--work-tree="):
            work_tree = None if index in unknown else token.split("=", 1)[1]
            index += 1
            continue
        if token in value_options:
            if index + 1 >= len(tokens):
                return None
            index += 2
            continue
        if token.startswith(("--config-env=", "--exec-path=", "--namespace=", "--super-prefix=", "--source=", "--pathspec-from-file=")):
            index += 1
            continue
        if token == "--":
            index += 1
            break
        if token in {"--literal-pathspecs", "--glob-pathspecs", "--noglob-pathspecs", "--no-pager"}:
            index += 1
            continue
        if token.startswith("-"):
            return None
        break

    if index >= len(tokens) or index in unknown:
        return None
    resolved_git_dir = resolve(git_dir, repo_dir) if git_dir else git_dir
    resolved_work_tree = resolve(work_tree, repo_dir) if work_tree else work_tree
    if resolved_work_tree is None or resolved_git_dir is None:
        repo_dir = None
    elif work_tree:
        repo_dir = resolved_work_tree
    elif git_dir:
        repo_dir = (os.path.dirname(resolved_git_dir)
                    if resolved_git_dir and os.path.basename(resolved_git_dir) == ".git"
                    else resolved_git_dir)

    variable_cardinality = may_disappear | may_multiply | cardinality_unknown
    # Variable-width global/wrapper operands do not establish the following
    # executable, verb, or repository-option alignment.
    if any(value < index for value in variable_cardinality):
        return None
    verb = tokens[index]
    if verb == "reset":
        effect, _ = git_reset_effect(tokens[index + 1:],
            frozenset(value - index - 1 for value in unknown if value > index),
            frozenset(value - index - 1 for value in may_disappear if value > index),
            frozenset(value - index - 1 for value in may_multiply if value > index),
            frozenset(value - index - 1 for value in cardinality_unknown if value > index),
            repo_dir)
        return effect, repo_dir
    if verb == "add":
        effect, _ = git_add_effect(tokens[index + 1:],
            frozenset(value - index - 1 for value in unknown if value > index),
            frozenset(value - index - 1 for value in may_disappear if value > index),
            frozenset(value - index - 1 for value in may_multiply if value > index),
            frozenset(value - index - 1 for value in cardinality_unknown if value > index),
            repo_dir)
        return effect, repo_dir
    if verb in {"add", "rm", "mv", "restore"}:
        return "prep", repo_dir
    if verb == "checkout":
        # Route every checkout to the concrete effect resolver.  Branch/ref
        # forms remain transparent there; a path form is admitted only when
        # it resolves to an actual worktree target.
        return "prep", repo_dir
    if verb == "commit":
        effect = commit_effect(tokens[index + 1:], frozenset(
            value - index - 1 for value in unknown if value > index), frozenset(
            value - index - 1 for value in variable_cardinality if value > index))
        return (effect, repo_dir) if effect else None
    if verb == "worktree":
        if index + 1 < len(tokens) and index + 1 not in unknown and tokens[index + 1] in MUTATING_WORKTREE:
            return "worktree", repo_dir
        return None
    if verb == "branch":
        return git_branch_effect(tokens[index + 1:],
            frozenset(value - index - 1 for value in unknown if value > index),
            frozenset(value - index - 1 for value in variable_cardinality if value > index)), repo_dir
    if verb == "apply":
        effect = git_apply_effect(tokens[index + 1:],
            frozenset(value - index - 1 for value in unknown if value > index),
            frozenset(value - index - 1 for value in variable_cardinality if value > index))
        return ("inspection" if effect == "inspection" else "apply"), repo_dir
    if verb == "remote":
        remote_mutators = {"add", "remove", "rename", "set-url", "set-head", "prune", "update"}
        if tokens[index + 1:index + 2] and index + 1 in unknown:
            return "repository-unresolved", repo_dir
        if tokens[index + 1:index + 2] and index + 1 not in unknown and tokens[index + 1] in remote_mutators:
            return "repository", repo_dir
        return "inspection", repo_dir
    if verb in READ_ONLY_GIT - {"branch", "remote"}:
        if any(value in {"-o", "--output"} or value.startswith("--output=")
               for value in tokens[index + 1:]):
            return "output", repo_dir
        return "inspection", repo_dir
    # These operations are ordinary when they resolve inside the current
    # repository. They still expose a concrete foreign repository target.
    if verb in {"branch", "remote", "push"}:
        return "repository", repo_dir
    return None


analysis = json.loads(sys.argv[5])
if analysis is not None:
    for record in analysis["commands"]:
        if record["reachability"] == "unreachable":
            continue
        directories = [record["cwd"]] if record["cwd_known"] else record["cwd_candidates"]
        # An absolute Git context can resolve even when the incoming CWD
        # cannot. Never substitute the callback directory for an unknown one.
        for cwd in directories or [""]:
            unknown = frozenset(record.get("unknown_arguments") or [])
            cardinality_unknown = frozenset(record.get("unknown_cardinality_arguments") or [])
            if "may_disappear_arguments" not in record or "may_multiply_arguments" not in record:
                cardinality_unknown |= unknown
            spec = segment_spec(record["argv"], record["segment"],
                                unknown,
                                frozenset(record.get("may_disappear_arguments") or []),
                                frozenset(record.get("may_multiply_arguments") or []),
                                cardinality_unknown)
            if spec:
                print(spec[0])
                # Transport uncertainty explicitly; never resolve this
                # marker as a filesystem path in the shell consumer.
                print(spec[1] if spec[1] and os.path.isabs(spec[1]) else "<unresolved>")
else:
    try:
        lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
        lexer.whitespace_split = True
        tokens = list(lexer)
    except ValueError:
        raise SystemExit(0)
    segments, current = [], []
    for token in tokens + [";"]:
        if token in SEPARATORS:
            if current:
                segments.append(current)
                current = []
        else:
            current.append(token)
    for segment_index, segment in enumerate(segments, 1):
        spec = segment_spec(segment, segment_index)
        if spec:
            print(spec[0])
            print(spec[1] if spec[1] and os.path.isabs(spec[1]) else "<unresolved>")
PY
}

worker_git_resolved_inspection_route() {
  [ "$hook_is_subagent" = true ] || return 1
  local command_text="$1" specs_text operation repo_dir repo_root active_repo index
  local -a specs=()

  specs_text="$(git_mutation_specs "$command_text" 2>/dev/null || true)"
  [ -n "$specs_text" ] || return 1
  mapfile -t specs <<<"$specs_text"
  [ $(( ${#specs[@]} % 2 )) -eq 0 ] || return 1
  active_repo="$(codex_git_safe -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)"
  active_repo="$(realpath -m -- "$active_repo" 2>/dev/null || true)"
  [ -n "$active_repo" ] && [ -d "$active_repo" ] && [ ! -L "$active_repo" ] || return 1

  for ((index = 0; index < ${#specs[@]}; index += 2)); do
    operation="${specs[index]}"
    repo_dir="${specs[index + 1]}"
    # A harmless segment cannot short-circuit a second segment that mutates
    # or otherwise writes. Let the normal mutation/control routes inspect the
    # complete command whenever any resolved operation is not an inspection.
    [ "$operation" = inspection ] || return 1
    [ "$repo_dir" != '<unresolved>' ] || return 1
    repo_root="$(codex_git_safe -C "$repo_dir" rev-parse --show-toplevel 2>/dev/null || true)"
    repo_root="$(realpath -m -- "$repo_root" 2>/dev/null || true)"
    [ -n "$repo_root" ] && [ -d "$repo_root" ] && [ ! -L "$repo_root" ] || return 1
    if [ "$ECI_CROSS_SCOPE_GATE_ENABLED" = true ] && [ "$repo_root" != "$active_repo" ] &&
      ! worker_additional_repository_allowed "$repo_root"; then
      deny_eci "ECI_GIT_CROSS_SCOPE_DENIED" "git-inspection" \
        "ECI worker Git inspection targets a different undeclared repository: active_repo=$active_repo target_repo=$repo_root; operation=inspection" \
        "declare this exact repository once for the owning worker with \"$HOME/.codex/bin/eci-active\" repository-allow-on <canonical-repository> \"<reason>\", or run the Git inspection from its owning worker repository"
    fi
    WORKER_PROJECT_INSPECTION_ALLOWED=true
    WORKER_PROJECT_INSPECTION_DETAIL="resolved repository=$repo_root operation=inspection"
  done
  [ "$WORKER_PROJECT_INSPECTION_ALLOWED" = true ]
}

active_session_additional_repository_allowed() {
  local repository="$1" marker marker_cwd active_session

  [ "${ECI_CROSS_SCOPE_GATE_ENABLED:-true}" = true ] || return 0
  active_session="${session_id:-}"
  codex_valid_session_id "$active_session" || return 1
  marker="${syntax_eci_markers[0]:-}"
  [ -n "$marker" ] || return 1
  marker_cwd="$(codex_state_value "$marker" cwd false 2>/dev/null || true)"
  [ -n "$marker_cwd" ] || return 1
  marker_cwd="$(codex_canonical_cwd "$marker_cwd")"
  codex_eci_additional_repository_is_allowed "$active_session" "$marker_cwd" "$repository"
}

worker_additional_repository_allowed() {
  [ "${hook_is_subagent:-false}" = true ] || return 1
  active_session_additional_repository_allowed "$1"
}

# A worker may execute a script outside its assigned provider root only when
# the resolved script belongs to the one additional repository it explicitly
# declared. This reuses the same owner/session-bound record as Git cross-scope
# work; a path or launcher spelling alone never grants the exception.
worker_script_target_additional_repository_allowed() {
  local detail="$1" resolved repository

  [ "${hook_is_subagent:-false}" = true ] || return 1
  case "$detail" in
    *" resolved="*" reason="*) ;;
    *) return 1 ;;
  esac
  resolved="${detail#* resolved=}"
  resolved="${resolved%% reason=*}"
  [ -n "$resolved" ] && [ -f "$resolved" ] || return 1
  repository="$(codex_git_safe -C "$(dirname -- "$resolved")" rev-parse --show-toplevel 2>/dev/null || true)"
  repository="$(realpath -e -- "$repository" 2>/dev/null || true)"
  [ -n "$repository" ] || return 1
  worker_additional_repository_allowed "$repository"
}

git_mutation_cross_scope_detail() {
  local target_repo="$1" active_repo

  active_repo="$(codex_git_safe -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)"
  active_repo="$(realpath -m -- "$active_repo" 2>/dev/null || true)"
  [ -n "$active_repo" ] && [ -d "$active_repo" ] && [ ! -L "$active_repo" ] || return 1
  [ "$target_repo" = "$active_repo" ] && return 1
  printf 'active_repo=%s target_repo=%s' "$active_repo" "$target_repo"
}

git_mutation_broad_effect_detail() {
  local target_repo="$1" command_text="${2:-$command}" command_cwd="${3:-$cwd}" timeout_replays="${PLAN_TIMEOUT_REPLAYS:-[]}"

  python3 - "$command_text" "$target_repo" "$command_cwd" "$timeout_replays" "$(planner_shell_analysis_for "$command_text")" "$(git_effect_python)" <<'PY'
import json
import os
import re
import shlex
import sys

exec(compile(sys.argv[6], "git-effect-library", "exec"))

command, repo, cwd = sys.argv[1:4]
try:
    timeout_replays = json.loads(sys.argv[4])
except (IndexError, TypeError, ValueError):
    raise SystemExit(1)
separators = {";", "&", "&&", "|", "||"}
opaque = {"(", ")", ">", ">>", "<", "<<", ">|", "<<<", "<&", ">&"}
assignment = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
repo = os.path.realpath(repo)
cwd = os.path.realpath(os.path.abspath(cwd))
analysis = json.loads(sys.argv[5])
if analysis is not None:
    records = [record for record in analysis["commands"]
               if record["reachability"] != "unreachable"]
else:
    try:
        lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
        lexer.whitespace_split = True
        tokens = list(lexer)
    except ValueError:
        raise SystemExit(1)
    if any(token in opaque for token in tokens):
        raise SystemExit(1)
    segments, current = [], []
    for token in tokens + [";"]:
        if token in separators:
            if current:
                segments.append(current)
                current = []
        else:
            current.append(token)
    records = [{"argv": segment, "segment": index, "cwd": cwd,
                "cwd_known": True, "cwd_candidates": []}
               for index, segment in enumerate(segments, 1)]

def resolve(path: str | None, base: str | None) -> str | None:
    if path is None:
        return None
    path = os.path.expanduser(path)
    if os.path.isabs(path):
        return os.path.normpath(path)
    if not base or not os.path.isabs(base):
        return None
    return os.path.normpath(os.path.join(base, path))


def observed_timeout_command_index(tokens, index, segment_index):
    if index >= len(tokens) or os.path.basename(tokens[index]) != "timeout":
        return index, None
    matches = []
    for replay in timeout_replays:
        if not isinstance(replay, dict) or replay.get("segment") != segment_index:
            continue
        if replay.get("disposition") != "observed":
            continue
        if not isinstance(replay.get("cwd"), str) or not replay["cwd"].startswith("/"):
            continue
        prefix = replay.get("prefix")
        if not isinstance(prefix, list) or not all(isinstance(value, str) for value in prefix):
            continue
        if len(prefix) < 2 or index + len(prefix) >= len(tokens):
            continue
        if tokens[index:index + len(prefix)] == prefix:
            matches.append((index + len(prefix), replay))
    return matches[0] if len(matches) == 1 else (None, None)


def git_record_command(
    segment: list[str],
    segment_index: int,
    unknown: frozenset[int],
    variable_cardinality: frozenset[int],
) -> tuple[str, list[str], frozenset[int], str, int] | None:
    index = 0
    environment = {}
    while index < len(segment) and assignment.match(segment[index]):
        name, value = segment[index].split("=", 1)
        environment[name] = None if index in unknown else value
        index += 1
    index, timeout_replay = observed_timeout_command_index(segment, index, segment_index)
    if index is None:
        return None
    repo_dir = timeout_replay["cwd"] if timeout_replay else cwd
    if index < len(segment) and os.path.basename(segment[index]) == "env":
        if index in unknown:
            return None
        index += 1
        while index < len(segment):
            if assignment.match(segment[index]):
                name, value = segment[index].split("=", 1)
                environment[name] = None if index in unknown else value
                index += 1
                continue
            value = segment[index]
            if value in {"-i", "--ignore-environment"}:
                environment.clear()
                index += 1
                continue
            if value in {"-a", "--argv0", "-u", "--unset", "-C", "--chdir"}:
                if index + 1 >= len(segment):
                    return None
                operand = None if index + 1 in unknown else segment[index + 1]
                if value in {"-C", "--chdir"}:
                    repo_dir = resolve(operand, repo_dir)
                elif value in {"-u", "--unset"}:
                    if operand is None:
                        environment.update((name, None) for name in environment)
                    else:
                        environment.pop(operand, None)
                index += 2
                continue
            if value.startswith(("--chdir=", "--unset=", "--argv0=")):
                operand = None if index in unknown else value.split("=", 1)[1]
                if value.startswith("--chdir="):
                    repo_dir = resolve(operand, repo_dir)
                elif value.startswith("--unset="):
                    if operand is None:
                        environment.update((name, None) for name in environment)
                    else:
                        environment.pop(operand, None)
                index += 1
                continue
            if value.startswith("-a") and len(value) > 2:
                index += 1
                continue
            if segment[index] == "--":
                index += 1
                break
            if segment[index].startswith("-"):
                return None
            break
    if index >= len(segment) or index in unknown or os.path.basename(segment[index]) != "git":
        return None
    index += 1
    git_dir = environment.get("GIT_DIR", "")
    work_tree = environment.get("GIT_WORK_TREE", "")
    value_options = {"-C", "-c", "--config-env", "--exec-path", "--namespace", "--super-prefix", "--git-dir", "--work-tree"}
    while index < len(segment):
        token = segment[index]
        if token == "-C":
            if index + 1 >= len(segment):
                return None
            repo_dir = resolve(None if index + 1 in unknown else segment[index + 1], repo_dir)
            index += 2
            continue
        if token.startswith("-C") and len(token) > 2:
            repo_dir = resolve(None if index in unknown else token[2:], repo_dir)
            index += 1
            continue
        if token in value_options:
            if index + 1 >= len(segment):
                return None
            if token == "--git-dir":
                git_dir = None if index + 1 in unknown else segment[index + 1]
            elif token == "--work-tree":
                work_tree = None if index + 1 in unknown else segment[index + 1]
            index += 2
            continue
        if token.startswith(("--config-env=", "--exec-path=", "--namespace=", "--super-prefix=", "--git-dir=", "--work-tree=")):
            if token.startswith("--git-dir="):
                git_dir = None if index in unknown else token.split("=", 1)[1]
            elif token.startswith("--work-tree="):
                work_tree = None if index in unknown else token.split("=", 1)[1]
            index += 1
            continue
        if token == "--":
            index += 1
            break
        if token in {"--literal-pathspecs", "--glob-pathspecs", "--noglob-pathspecs", "--no-pager"}:
            index += 1
            continue
        if token.startswith("-"):
            return None
        break
    if index >= len(segment) or index in unknown or any(value <= index for value in variable_cardinality) or git_dir is None or work_tree is None:
        return None
    resolved_git_dir = resolve(git_dir, repo_dir) if git_dir else ""
    resolved_work_tree = resolve(work_tree, repo_dir) if work_tree else ""
    if resolved_git_dir is None or resolved_work_tree is None:
        return None
    if work_tree:
        repo_dir = resolved_work_tree
    elif git_dir:
        repo_dir = resolved_git_dir
        if repo_dir and os.path.basename(repo_dir) == ".git":
            repo_dir = os.path.dirname(repo_dir)
    if not repo_dir or not os.path.isabs(repo_dir):
        return None
    current = os.path.realpath(repo_dir)
    while current != repo:
        parent = os.path.dirname(current)
        if parent == current or os.path.lexists(os.path.join(current, ".git")):
            return None
        current = parent
    return (segment[index], segment[index + 1:], frozenset(
        value - index - 1 for value in unknown if value > index), repo_dir, index)


for record in records:
    directories = [record["cwd"]] if record["cwd_known"] else record["cwd_candidates"]
    for cwd in directories or [""]:
        parsed = git_record_command(record["argv"], record["segment"],
                                    frozenset(record.get("unknown_arguments") or []),
                                    frozenset(record.get("may_disappear_arguments") or []) |
                                    frozenset(record.get("may_multiply_arguments") or []) |
                                    frozenset(record.get("unknown_cardinality_arguments") or []) |
                                    (frozenset(record.get("unknown_arguments") or [])
                                     if "may_disappear_arguments" not in record else frozenset()))
        if parsed is None:
            continue
        verb, arguments, unknown, repo_dir, verb_index = parsed
        disappearing = frozenset(value - verb_index - 1 for value in record.get("may_disappear_arguments") or [] if value > verb_index)
        multiplying = frozenset(value - verb_index - 1 for value in record.get("may_multiply_arguments") or [] if value > verb_index)
        unavailable = frozenset(value - verb_index - 1 for value in record.get("unknown_cardinality_arguments") or [] if value > verb_index)
        if "may_disappear_arguments" not in record or "may_multiply_arguments" not in record:
            unavailable |= unknown
        if verb == "reset":
            effect, selectors = git_reset_effect(arguments, unknown, disappearing, multiplying, unavailable, repo_dir)
            if effect in {"reset-working-tree", "reset-index", "reset-unresolved"}:
                print("effect=%s target=%s" % (effect, repo))
                raise SystemExit(0)
            if effect == "reset" and any(literal and value and os.path.realpath(resolve(value, repo_dir)) == repo
                                         for value, literal in selectors):
                print("effect=reset-index target=%s" % repo)
                raise SystemExit(0)
        if verb == "add":
            effect, selectors = git_add_effect(arguments, unknown, disappearing, multiplying, unavailable, repo_dir)
            if effect in {"whole-worktree-staging", "add-target-unresolved"}:
                print("effect=%s target=%s" % (effect, repo))
                raise SystemExit(0)
            if effect != "prep":
                continue
            for selector, literal in selectors:
                if literal and selector and os.path.realpath(resolve(selector, repo_dir)) == repo:
                    print("effect=whole-worktree-staging target=%s selector=%s" % (repo, selector))
                    raise SystemExit(0)
raise SystemExit(1)
PY
}


git_protected_worktree_target_detail() {
  local command_text="${1:-$command}" target_repo="${2:-}" command_cwd="${3:-$cwd}"
  local include_index="${4:-false}"
  local configured_home="${CODEX_CONFIGURED_HOME:-${CODEX_HOME:-}}"

  # This is an effect check for the coordinator's Git preparation route.  It
  # deliberately follows a concrete Git child through ordinary launch
  # wrappers, and it uses lexical worktree paths: a symlink alias is a
  # different Git entry from the live control file it may point at.
  python3 - "$command_text" "$target_repo" "$command_cwd" "$configured_home" "$HOOK_DIR" "$include_index" "$(planner_shell_analysis_for "$command_text")" "$(git_effect_python)" <<'PY'
import glob
import json
import os
import re
import shlex
import sys

exec(compile(sys.argv[8], "git-effect-library", "exec"))

command, target_repo, command_cwd, configured_home, hook_dir, include_index = sys.argv[1:7]
analysis = json.loads(sys.argv[7])

SEPARATORS = {";", "&", "&&", "|", "||"}
REDIRECTIONS = {">", ">>", "<", "<<", ">|", "<<<", "<&", ">&"}
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=.*$")
target_repo = os.path.realpath(os.path.normpath(os.path.abspath(target_repo or command_cwd)))
# The callback CWD identifies the Git worktree, so resolve a CWD symlink before
# joining ordinary pathspecs.  A final path component is kept lexical and is
# checked with lstat-style existence below; an alias entry remains distinct.
command_cwd = os.path.realpath(os.path.normpath(os.path.abspath(command_cwd)))

def canonical_root(value):
    if not value or not os.path.isabs(value):
        return None
    return os.path.realpath(os.path.normpath(value))

control_roots = set()
for value in (
    configured_home,
    os.environ.get("KIMI_CODE_HOME", ""),
    os.path.join(os.environ.get("HOME", ""), ".kimi-code"),
    os.path.dirname(os.path.realpath(hook_dir)),
):
    root = canonical_root(value)
    if root:
        control_roots.add(root)

protected = {
    os.path.join(root, "hooks", name)
    for root in control_roots
    for name in (
        "validate-bash.sh", "pretooluse-edit-dispatch.sh", "stop-gate.sh",
        "eci-active-gate.sh", "eci-review-gate.sh", "ate-orchestrator-gate.sh",
        "validate-edit-write.sh", "validate-apply-patch.sh",
    )
}

def lexical_resolve(value: str | None, base: str | None) -> str:
    if value is None:
        return ""
    expanded = os.path.expanduser(value)
    if os.path.isabs(expanded):
        return os.path.normpath(expanded)
    if not base or not os.path.isabs(base):
        return ""
    return os.path.normpath(os.path.join(base, expanded))

def parse_pathspec(value, base):
    exclude = False
    if value.startswith(":/"):
        value = value[2:]
        return value, target_repo, exclude, not value
    elif value.startswith(":("):
        close = value.find(")")
        if close < 0:
            return None
        magic = {part.strip().lower() for part in value[2:close].split(",")}
        exclude = "exclude" in magic or "!" in magic or "^" in magic
        if "top" in magic:
            base = target_repo
        value = value[close + 1:]
        return value, base, exclude, "top" in magic and not value
    return value, base, exclude, False

def pathspec_candidates(value, base):
    # An explicit empty scalar is an invalid Git pathspec, not repository root.
    if value == "":
        return [], False
    parsed = parse_pathspec(value, base)
    if parsed is None:
        return [], False
    value, base, exclude, root = parsed
    if exclude:
        return [], exclude
    if root or not value:
        return [target_repo], False
    candidate = lexical_resolve(value, base)
    if not candidate:
        return [], False
    if any(character in value for character in "*?["):
        return glob.glob(candidate, recursive=True), False
    return [candidate], False

def pathspec_from_file_argument(value: str) -> tuple[bool, str | None]:
    option, separator, argument = value.partition("=")
    prefix = "--pathspec-fr"
    full = "--pathspec-from-file"
    if len(option) < len(prefix) or not full.startswith(option):
        return False, None
    return True, argument if separator else None

def collect_pathspecs(
    args: list[str],
    base: str,
    unknown: frozenset[int] = frozenset(),
) -> list[str]:
    paths = []
    filename = ""
    file_nul = False
    after_separator = False
    index = 0
    value_options = {
        "--source", "--conflict", "-b", "-B", "--orphan", "--unified", "-U",
        "--inter-hunk-context", "--recurse-submodules",
    }
    while index < len(args):
        value = args[index]
        offset = index
        index += 1
        if not after_separator and value == "--" and offset not in unknown:
            after_separator = True
            continue
        if not after_separator and value.startswith("-"):
            is_file, operand = pathspec_from_file_argument(value)
            if is_file:
                value_unknown = offset in unknown
                if operand is None:
                    if index >= len(args):
                        return []
                    operand = args[index]
                    value_unknown = index in unknown
                    index += 1
                filename = None if value_unknown else operand
                continue
            if offset in unknown:
                continue
            if value == "--no-pathspec-from-file":
                filename = ""
            elif value in {"--pathspec-file-nul", "--no-pathspec-file-nul"}:
                file_nul = value == "--pathspec-file-nul"
            elif value in value_options:
                index += 1
            continue
        if offset not in unknown:
            paths.append(value)
    if filename is None or filename:
        if paths:
            return []  # Git rejects simultaneous file and explicit paths.
        entries = git_pathspec_entries(filename, base, file_nul)
        return entries if entries is not None else []
    return [] if file_nul else paths

def inside(root, path):
    return path == root or path.startswith(root + os.sep)

def existing_protected_file(path):
    # Do not follow a symlink alias: Git removes/renames the alias entry, not
    # the live control file reached through the alias.
    return path in protected and os.path.lexists(path) and not os.path.islink(path)

def existing_protected_descendant(path):
    if os.path.islink(path):
        return False
    return any(
        protected_path.startswith(path + os.sep) and
        os.path.lexists(protected_path) and
        not os.path.islink(protected_path)
        for protected_path in protected
    )

def protected_path_detail(path, operation, recursive=False):
    if existing_protected_file(path):
        return "operation=%s target=%s kind=protected-live-hook" % (operation, path)
    if recursive and existing_protected_descendant(path):
        return "operation=%s target=%s kind=protected-live-hook-tree" % (operation, path)
    return None

def split_segments(values):
    segments, current = [], []
    for value in values + [";"]:
        if value in SEPARATORS:
            if current:
                segments.append(current)
                current = []
        else:
            current.append(value)
    return segments

def strip_structural_prefix(
    segment: list[str],
    unknown: frozenset[int],
) -> tuple[list[str], frozenset[int]]:
    index = 0
    while index < len(segment):
        value = segment[index]
        if value in {"if", "then", "else", "elif", "while", "until", "do", "{", "}", "("}:
            index += 1
            continue
        if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_-]*:", value):
            index += 1
            continue
        if value in REDIRECTIONS:
            index += min(2, len(segment) - index)
            continue
        if value.isdigit() and index + 1 < len(segment) and segment[index + 1] in REDIRECTIONS:
            index += 1
            continue
        break
    return segment[index:], frozenset(value - index for value in unknown if value >= index)

def consume_env(
    segment: list[str],
    index: int,
    base: str,
    environment: dict[str, str | None],
    unknown: frozenset[int],
) -> tuple[int, str, dict[str, str | None]] | None:
    index += 1
    while index < len(segment):
        value = segment[index]
        if ASSIGNMENT.fullmatch(value):
            name, assigned = value.split("=", 1)
            environment[name] = None if index in unknown else assigned
            index += 1
            continue
        if value in {"-i", "--ignore-environment", "-v", "--debug"}:
            if value in {"-i", "--ignore-environment"}:
                environment.clear()
            index += 1
            continue
        if value in {"-u", "--unset", "-a", "--argv0"}:
            if index + 1 >= len(segment):
                return None
            if value in {"-u", "--unset"}:
                if index + 1 in unknown:
                    environment.update((name, None) for name in environment)
                else:
                    environment.pop(segment[index + 1], None)
            index += 2
            continue
        if value.startswith(("--argv0=", "--unset=")) or (value.startswith("-a") and len(value) > 2):
            if value.startswith("--unset="):
                if index in unknown:
                    environment.update((name, None) for name in environment)
                else:
                    environment.pop(value.split("=", 1)[1], None)
            index += 1
            continue
        if value in {"-C", "--chdir"}:
            if index + 1 >= len(segment):
                return None
            base = lexical_resolve(None if index + 1 in unknown else segment[index + 1], base)
            index += 2
            continue
        if value.startswith("--chdir="):
            base = lexical_resolve(None if index in unknown else value.split("=", 1)[1], base)
            index += 1
            continue
        if value == "--":
            index += 1
        break
    return index, base, environment

def unwrap(
    segment: list[str],
    initial_base: str | None = None,
    unknown: frozenset[int] = frozenset(),
) -> tuple[int, str, dict[str, str | None]] | None:
    index = 0
    base = command_cwd if initial_base is None else initial_base
    environment = {}

    while index < len(segment):
        while index < len(segment) and ASSIGNMENT.fullmatch(segment[index]):
            name, assigned = segment[index].split("=", 1)
            environment[name] = None if index in unknown else assigned
            index += 1
        if index >= len(segment):
            break
        if index in unknown:
            return None
        name = os.path.basename(segment[index])
        if name == "env":
            result = consume_env(segment, index, base, environment, unknown)
            if result is None:
                return None
            index, base, environment = result
            continue
        if name in {"command", "builtin", "exec", "nohup", "setsid"}:
            index += 1
            while index < len(segment) and segment[index].startswith("-"):
                if name == "exec" and segment[index] == "-a":
                    if index + 1 >= len(segment):
                        return None
                    index += 2
                else:
                    index += 1
            continue
        if name == "busybox":
            index += 1
            if index < len(segment) and segment[index] == "--":
                index += 1
            continue
        if name == "stdbuf":
            index += 1
            while index < len(segment) and segment[index].startswith("-"):
                index += 1
            continue
        if name == "timeout":
            index += 1
            while index < len(segment) and segment[index].startswith("-"):
                option = segment[index]
                if option in {"-k", "--kill-after", "-s", "--signal"}:
                    if index + 1 >= len(segment):
                        return None
                    index += 2
                elif option.startswith(("--kill-after=", "--signal=")):
                    index += 1
                else:
                    index += 1
            if index >= len(segment) or segment[index].startswith("-"):
                return None
            index += 1
            continue
        if name in {"chronic", "nice", "time", "prlimit", "systemd-run"}:
            index += 1
            value_options = {
                "-n", "-p", "--adjustment", "--property", "--unit",
                "--setenv", "--working-directory", "-C", "--chdir",
            }
            while index < len(segment) and segment[index].startswith("-"):
                option = segment[index]
                if option == "--":
                    index += 1
                    break
                if name == "systemd-run" and option in {"--working-directory", "--chdir"}:
                    if index + 1 >= len(segment):
                        return None
                    base = lexical_resolve(None if index + 1 in unknown else segment[index + 1], base)
                    index += 2
                elif name == "systemd-run" and option.startswith(("--working-directory=", "--chdir=")):
                    base = lexical_resolve(None if index in unknown else option.split("=", 1)[1], base)
                    index += 1
                elif name == "systemd-run" and option == "--setenv":
                    if index + 1 >= len(segment):
                        return None
                    name_value = segment[index + 1].split("=", 1)
                    if len(name_value) == 2:
                        environment[name_value[0]] = None if index + 1 in unknown else name_value[1]
                    index += 2
                elif name == "systemd-run" and option.startswith("--setenv="):
                    name_value = option.split("=", 1)[1].split("=", 1)
                    if len(name_value) == 2:
                        environment[name_value[0]] = None if index in unknown else name_value[1]
                    index += 1
                elif option in value_options:
                    if index + 1 >= len(segment):
                        return None
                    index += 2
                else:
                    index += 1
            continue
        if name in {"sudo", "doas"}:
            index += 1
            value_options = {
                "-u", "--user", "-g", "--group", "-h", "--host",
                "-p", "--prompt", "-C", "--chdir", "-R", "--chroot",
                "-D", "-r", "--role", "-t", "--type",
            }
            while index < len(segment) and segment[index].startswith("-"):
                option = segment[index]
                if option == "--":
                    index += 1
                    break
                if option in value_options:
                    if index + 1 >= len(segment):
                        return None
                    if option in {"--chdir", "-D"}:
                        base = lexical_resolve(None if index + 1 in unknown else segment[index + 1], base)
                    index += 2
                elif any(option.startswith(value + "=") for value in value_options):
                    if option.startswith(("--chdir=", "-D=")):
                        base = lexical_resolve(None if index in unknown else option.split("=", 1)[1], base)
                    index += 1
                else:
                    index += 1
            continue
        break
    return index, base, environment

def git_command(
    segment: list[str],
    initial_base: str | None = None,
    unknown: frozenset[int] = frozenset(),
    variable_cardinality: frozenset[int] = frozenset(),
) -> tuple[str, list[str], str, frozenset[int]] | None:
    original_length = len(segment)
    segment, unknown = strip_structural_prefix(segment, unknown)
    removed = original_length - len(segment)
    if any(value < removed for value in variable_cardinality):
        return None
    variable_cardinality = frozenset(value - removed for value in variable_cardinality)
    result = unwrap(segment, initial_base, unknown)
    if result is None:
        return None
    index, base, environment = result
    if index >= len(segment) or index in unknown or os.path.basename(segment[index]) != "git":
        return None
    index += 1
    work_tree = environment.get("GIT_WORK_TREE", "")
    git_dir = environment.get("GIT_DIR", "")
    while index < len(segment):
        value = segment[index]
        if value == "-C":
            if index + 1 >= len(segment):
                return None
            base = lexical_resolve(None if index + 1 in unknown else segment[index + 1], base)
            index += 2
            continue
        if value.startswith("-C") and len(value) > 2:
            base = lexical_resolve(None if index in unknown else value[2:], base)
            index += 1
            continue
        if value in {"--git-dir", "--work-tree", "-c", "--config-env", "--exec-path", "--namespace", "--super-prefix", "--source", "--pathspec-from-file"}:
            if index + 1 >= len(segment):
                return None
            if value == "--git-dir":
                git_dir = None if index + 1 in unknown else segment[index + 1]
            elif value == "--work-tree":
                work_tree = None if index + 1 in unknown else segment[index + 1]
            index += 2
            continue
        if value.startswith(("--git-dir=", "--work-tree=", "--config-env=", "--exec-path=", "--namespace=", "--super-prefix=", "--source=", "--pathspec-from-file=")):
            if value.startswith("--git-dir="):
                git_dir = None if index in unknown else value.split("=", 1)[1]
            elif value.startswith("--work-tree="):
                work_tree = None if index in unknown else value.split("=", 1)[1]
            index += 1
            continue
        if value == "--":
            index += 1
            break
        if value in {"--literal-pathspecs", "--glob-pathspecs", "--noglob-pathspecs", "--no-pager"}:
            index += 1
            continue
        if value.startswith("-"):
            index += 1
            continue
        break
    if index >= len(segment) or index in unknown or any(value <= index for value in variable_cardinality) or work_tree is None or git_dir is None:
        return None
    resolved_git_dir = lexical_resolve(git_dir, base) if git_dir else ""
    resolved_work_tree = lexical_resolve(work_tree, base) if work_tree else ""
    if (git_dir and not resolved_git_dir) or (work_tree and not resolved_work_tree):
        return None
    repository_base = base
    if work_tree:
        base = resolved_work_tree
        repository_base = base
    elif git_dir:
        repository_base = resolved_git_dir
        if repository_base and os.path.basename(repository_base) == ".git":
            repository_base = os.path.dirname(repository_base)
    if not repository_base or not os.path.isabs(repository_base):
        return None
    current = os.path.realpath(repository_base)
    while current != target_repo:
        parent = os.path.dirname(current)
        if parent == current or os.path.lexists(os.path.join(current, ".git")):
            return None
        current = parent
    return segment[index], segment[index + 1:], base, frozenset(
        value - index - 1 for value in unknown if value > index)

def rm_detail(
    args: list[str],
    base: str,
    unknown: frozenset[int],
) -> str | None:
    recursive = cached = dry_run = False
    final_state_unknown = False
    index = 0
    while index < len(args):
        value = args[index]
        offset = index
        index += 1
        if offset in unknown:
            if value.startswith(("$?", "-")):
                final_state_unknown = True
            continue
        if value == "--":
            break
        is_file, operand = pathspec_from_file_argument(value)
        if is_file:
            if operand is None:
                index += 1
            continue
        if value in {"--cached", "--no-cached"}:
            cached = value == "--cached"
        elif value in {"--dry-run", "--no-dry-run", "-n"}:
            dry_run = value != "--no-dry-run"
        elif value == "--recursive":
            recursive = True
        elif value == "--no-recursive":
            recursive = False
        elif value.startswith("-") and not value.startswith("--"):
            recursive = recursive or "r" in value[1:]
            dry_run = dry_run or "n" in value[1:]
    # Resolve both final exemptions independently. Unknown option identity
    # does not establish removal, and consumed filenames are never options.
    if cached or dry_run or final_state_unknown:
        return None
    for value in collect_pathspecs(args, base, unknown):
        candidates, _ = pathspec_candidates(value, base)
        for candidate in candidates:
            if not inside(target_repo, candidate):
                continue
            detail = protected_path_detail(candidate, "rm", recursive)
            if detail:
                return detail
    return None

def mv_detail(
    args: list[str],
    base: str,
    unknown: frozenset[int],
    include_index: bool = False,
) -> str | None:
    dry_run = False
    paths = []
    after_separator = False
    for index, value in enumerate(args):
        if index in unknown:
            paths.append(None)
            continue
        if not after_separator and value == "--":
            after_separator = True
            continue
        if not after_separator and value.startswith("-"):
            if value in {"-n", "--dry-run"} or (value.startswith("-") and not value.startswith("--") and "n" in value[1:]):
                dry_run = True
            continue
        paths.append(value)
    if dry_run or len(paths) < 2:
        return None
    destination_raw = paths[-1]
    if destination_raw is None:
        # An unknown opposite endpoint cannot erase a known protected source.
        for value in paths[:-1]:
            if value is None:
                continue
            candidates, _ = pathspec_candidates(value, base)
            for source in candidates:
                if inside(target_repo, source):
                    detail = protected_path_detail(source, "mv", True)
                    if detail:
                        return detail
        return None
    destination_values, destination_excluded = pathspec_candidates(destination_raw, base)
    if destination_excluded or not destination_values:
        return None
    destination = destination_values[0]
    # `git mv` cannot move a worktree entry outside its repository. Treat
    # that invalid request as transparent rather than blocking it by spelling.
    if not inside(target_repo, destination):
        return None
    if any(value is None for value in paths[:-1]) and destination in protected:
        return "operation=mv target=%s kind=protected-live-hook" % destination
    sources = []
    for value in paths[:-1]:
        if value is None:
            continue
        candidates, _ = pathspec_candidates(value, base)
        sources.extend(candidates)
    if not sources:
        return None
    for source in sources:
        effective_destination = destination
        if os.path.isdir(destination) and not os.path.islink(destination):
            effective_destination = os.path.normpath(os.path.join(destination, os.path.basename(source)))
        # A source outside the worktree is invalid for Git mv and cannot
        # mutate the protected target through this command.
        if not inside(target_repo, source):
            continue
        # Missing/invalid sources are ordinary Git errors.  They cannot
        # rename a protected live entry, even when the destination spells one.
        if not os.path.lexists(source):
            continue
        if source == effective_destination:
            if include_index:
                detail = protected_path_detail(source, "mv", True)
                if detail:
                    return detail
            continue
        detail = protected_path_detail(source, "mv", True)
        if detail:
            return detail
        if effective_destination in protected:
            return "operation=mv target=%s kind=protected-live-hook" % effective_destination
    return None

def restore_detail(
    args: list[str],
    base: str,
    unknown: frozenset[int],
    include_index: bool = False,
) -> str | None:
    worktree = True
    after_separator = False
    for index, value in enumerate(args):
        if index in unknown:
            continue
        if value == "--":
            after_separator = True
            continue
        if not after_separator and (value in {"--staged", "-S"} or value.startswith("--staged=")):
            worktree = False
        elif not after_separator and (value in {"--worktree", "-W"} or value.startswith("--worktree=")):
            worktree = True
    if not worktree and not include_index:
        return None
    for value in collect_pathspecs(args, base, unknown):
        candidates, _ = pathspec_candidates(value, base)
        for candidate in candidates:
            if not inside(target_repo, candidate):
                continue
            detail = protected_path_detail(candidate, "restore", True)
            if detail:
                return detail
    return None

def checkout_revision(value):
    # A path-looking token is a branch/ref when Git can resolve it to a
    # commit.  Failed/ambiguous probing stays on path inspection; only a
    # positive revision result exempts an existing protected path.
    if not value or value.startswith("-"):
        return False
    try:
        import subprocess
        result = subprocess.run(
            ["/usr/bin/git", "-C", target_repo, "rev-parse", "--verify", "--quiet", value + "^{commit}"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            check=False, timeout=1,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    return result.returncode == 0

def checkout_context_value_valid(value):
    # Git accepts a nonnegative 32-bit integer with an optional k/m/g suffix,
    # plus signed zero and -1, for checkout's context options. Keep malformed
    # and out-of-range values transparent because Git rejects them before
    # touching the worktree.
    match = re.fullmatch(r"([+-]?)([0-9]+)([kKmMgG]?)", value)
    if not match:
        return False
    sign, digits, suffix = match.groups()
    if sign == "-" and suffix:
        return False
    try:
        number = int(digits)
    except (TypeError, ValueError):
        return False
    if sign == "-" and number not in {0, 1}:
        return False
    number *= {"": 1, "k": 1024, "K": 1024, "m": 1024 ** 2,
               "M": 1024 ** 2, "g": 1024 ** 3, "G": 1024 ** 3}[suffix]
    if sign == "-":
        number = -number
    return -(1 << 31) <= number <= (1 << 31) - 1

def checkout_context_value_has_unpatched_effect(value):
    # Git's checkout path mode accepts -1 without --patch and can still
    # restore a path. Other valid context values require --patch, while
    # negative zero is invalid without it, so those commands remain
    # transparent.
    if not checkout_context_value_valid(value):
        return False
    match = re.fullmatch(r"([+-]?)([0-9]+)([kKmMgG]?)", value)
    return match is not None and match.group(1) == "-" and not match.group(3) and int(match.group(2)) == 1

def checkout_detach_state(
    args: list[str],
    unknown: frozenset[int],
) -> tuple[bool | None, bool, bool, int | None, bool, bool]:
    """Return detach state, branch mode, start point, separator, and flags."""
    state = None
    branch_mode = False
    branch_startpoint = False
    unified_context_option = False
    unified_context_unpatched_effect = False
    inter_hunk_context_option = False
    inter_hunk_context_unpatched_effect = False
    patch_mode = False
    pathspec_file_option = False
    pathspec_dash_consumed = False
    pathspec_dash_trailing_path = False
    separator_index = None
    index = 0

    def invalid_result():
        return (None, branch_mode, branch_startpoint, separator_index,
                pathspec_file_option, True)

    while index < len(args):
        value = args[index]
        if index in unknown:
            index += 1
            continue
        if value == "--":
            separator_index = index
            break
        is_pathspec_file, pathspec_file = pathspec_from_file_argument(value)
        if is_pathspec_file:
            pathspec_file_option = True
            # This option consumes the following token even when it starts
            # with a dash.  Do not mistake a pathspec filename named
            # --detach for a later detach toggle.
            if pathspec_file is None:
                if index + 1 >= len(args) or args[index + 1] == "--":
                    if index + 1 >= len(args):
                        return invalid_result()
                    pathspec_dash_consumed = True
                index += 2
            elif not pathspec_file:
                return invalid_result()
            else:
                index += 1
            continue
        option, separator, argument = value.partition("=")
        if option in {"--source", "--conflict", "--orphan", "--unified", "--inter-hunk-context"}:
            if separator:
                if option in {"--unified", "--inter-hunk-context"}:
                    if not checkout_context_value_valid(argument):
                        return invalid_result()
                elif argument.startswith("-"):
                    return invalid_result()
                if option == "--conflict" and argument not in {"merge", "diff3", "zdiff3"}:
                    return invalid_result()
                branch_mode = branch_mode or option == "--orphan"
                if option == "--unified":
                    unified_context_option = True
                    unified_context_unpatched_effect = checkout_context_value_has_unpatched_effect(argument)
                elif option == "--inter-hunk-context":
                    inter_hunk_context_option = True
                    inter_hunk_context_unpatched_effect = checkout_context_value_has_unpatched_effect(argument)
                index += 1
                continue
            if index + 1 >= len(args):
                return invalid_result()
            context_value = args[index + 1]
            if option in {"--unified", "--inter-hunk-context"}:
                if not checkout_context_value_valid(context_value):
                    return invalid_result()
            elif context_value.startswith("-"):
                return invalid_result()
            if option == "--conflict" and context_value not in {"merge", "diff3", "zdiff3"}:
                return invalid_result()
            branch_mode = branch_mode or option == "--orphan"
            if option == "--unified":
                unified_context_option = True
                unified_context_unpatched_effect = checkout_context_value_has_unpatched_effect(context_value)
            elif option == "--inter-hunk-context":
                inter_hunk_context_option = True
                inter_hunk_context_unpatched_effect = checkout_context_value_has_unpatched_effect(context_value)
            index += 2
            continue
        if value.startswith("-") and not value.startswith("--"):
            short_options = value[1:]
            short_options_recognized = True
            short_index = 0
            while short_index < len(short_options):
                short_option = short_options[short_index]
                if short_option in {"b", "B", "U"}:
                    branch_mode = branch_mode or short_option in {"b", "B"}
                    if short_option == "U":
                        unified_context_option = True
                    argument = short_options[short_index + 1:]
                    if argument:
                        if short_option == "U":
                            if not checkout_context_value_valid(argument):
                                return invalid_result()
                            unified_context_unpatched_effect = checkout_context_value_has_unpatched_effect(argument)
                        elif argument.startswith("-"):
                            return invalid_result()
                        break
                    if index + 1 >= len(args):
                        return invalid_result()
                    if short_option == "U":
                        if not checkout_context_value_valid(args[index + 1]):
                            return invalid_result()
                        unified_context_unpatched_effect = checkout_context_value_has_unpatched_effect(args[index + 1])
                    elif args[index + 1].startswith("-"):
                        return invalid_result()
                    index += 1
                    break
                if short_option == "d":
                    state = True
                elif short_option == "p":
                    patch_mode = True
                elif short_option in {"f", "l", "m", "q", "t"}:
                    pass
                else:
                    short_options_recognized = False
                short_index += 1
            if pathspec_dash_consumed and not short_options_recognized:
                # After a literal `--` has been consumed as the pathspec
                # filename, an unrecognized short option is Git-invalid
                # rather than a second protected pathspec.
                return invalid_result()
            index += 1
            continue
        if value.startswith("--"):
            long_option_recognized = False
            if option.startswith("--no-"):
                suffix = option[len("--no-"):]
                if suffix and "detach".startswith(suffix):
                    if separator:
                        return invalid_result()
                    state = False
                    long_option_recognized = True
                elif len(suffix) >= len("patc") and "patch".startswith(suffix):
                    if separator:
                        return invalid_result()
                    patch_mode = False
                    long_option_recognized = True
                elif suffix and len(suffix) < len("patc") and "patch".startswith(suffix):
                    return invalid_result()
                elif option in {
                    "--no-force", "--no-guess", "--no-ignore-other-worktrees",
                    "--no-ignore-skip-worktree-bits", "--no-merge",
                    "--no-overlay", "--no-overwrite-ignore", "--no-progress",
                    "--no-quiet", "--no-recurse-submodules", "--no-track",
                } and not separator:
                    long_option_recognized = True
            elif option != "--" and "--detach".startswith(option):
                if separator:
                    return invalid_result()
                state = True
                long_option_recognized = True
            elif len(option) >= len("--patc") and "--patch".startswith(option):
                if separator:
                    return invalid_result()
                patch_mode = True
                long_option_recognized = True
            elif len(option) < len("--patc") and "--patch".startswith(option):
                return invalid_result()
            elif option in {
                "--force", "--guess", "--ignore-other-worktrees",
                "--ignore-skip-worktree-bits", "--merge", "--no-force",
                "--no-guess", "--no-ignore-other-worktrees",
                "--no-ignore-skip-worktree-bits", "--no-merge",
                "--no-overlay", "--no-overwrite-ignore", "--no-progress",
                "--no-quiet", "--no-recurse-submodules", "--no-track",
                "--ours", "--overlay", "--overwrite-ignore", "--progress",
                "--quiet", "--recurse-submodules", "--theirs", "--track",
                "--pathspec-file-nul",
            } and not separator:
                long_option_recognized = True
            if pathspec_dash_consumed and not long_option_recognized:
                # After a literal `--` has been consumed as the pathspec
                # filename, an unrecognized option is Git-invalid rather
                # than a second protected pathspec.
                return invalid_result()
        index += 1
        if pathspec_dash_consumed and not value.startswith("-"):
            # Once a literal `--` was consumed as the pathspec filename,
            # another positional token is a second pathspec argument.  Git
            # rejects that combination before touching the worktree.
            pathspec_dash_trailing_path = True
        if branch_mode and not value.startswith("-") and checkout_revision(value) is True:
            branch_startpoint = True
    if pathspec_dash_trailing_path:
        return invalid_result()
    if not patch_mode:
        if unified_context_option and not unified_context_unpatched_effect:
            return invalid_result()
        if inter_hunk_context_option and not inter_hunk_context_unpatched_effect:
            return invalid_result()
    if patch_mode and pathspec_file_option:
        return invalid_result()
    return (state, branch_mode, branch_startpoint, separator_index,
            pathspec_file_option, False)

def checkout_detail(args: list[str], base: str, unknown: frozenset[int]) -> str | None:
    # With `--`, every following token is a worktree pathspec.  Without it,
    # preserve branch/ref inspection and only inspect an existing path that
    # Git cannot resolve as a revision.
    # Positive detach options select a revision; they cannot introduce a
    # worktree pathspec.  Restrict this exemption to an effective positive
    # option before `--`; a later --no-detach or an option value cancels it.
    (detach_state, branch_mode, branch_startpoint, separator_index,
     pathspec_file_option, invalid) = checkout_detach_state(args, unknown)
    if invalid or detach_state is True:
        return None
    explicit_paths = separator_index is not None
    if branch_mode:
        if explicit_paths or not branch_startpoint:
            return None
    # Git rejects a pathspec-file option combined with explicit pathspecs;
    # leave that ordinary invalid command transparent even when the file
    # itself names a protected path.
    if pathspec_file_option and explicit_paths and args[separator_index + 1:]:
        return None
    # Scan the complete option region so a pathspec file placed before the
    # actual separator cannot be discarded.  `separator_index` comes from
    # the option-state parser, so a `--` consumed as an option value is not
    # mistaken for the pathspec separator.
    paths = collect_pathspecs(args, base, unknown)
    for value in paths:
        if not explicit_paths:
            revision = checkout_revision(value)
            if revision is True:
                continue
        candidates, _ = pathspec_candidates(value, base)
        for candidate in candidates:
            if not inside(target_repo, candidate):
                continue
            detail = protected_path_detail(candidate, "checkout", True)
            if detail:
                return detail
    return None

def shell_child_segments(
    segment: list[str],
    initial_base: str | None = None,
    unknown: frozenset[int] = frozenset(),
    variable_cardinality: frozenset[int] = frozenset(),
) -> tuple[list[list[str]], str] | list[list[str]] | None:
    original_length = len(segment)
    segment, unknown = strip_structural_prefix(segment, unknown)
    removed = original_length - len(segment)
    if any(value < removed for value in variable_cardinality):
        return None
    variable_cardinality = frozenset(value - removed for value in variable_cardinality)
    result = unwrap(segment, initial_base, unknown)
    if result is None:
        return None
    index, base, _ = result
    if index >= len(segment) or index in unknown or os.path.basename(segment[index]) not in {"bash", "sh", "dash", "zsh"}:
        return None
    shell_args = segment[index + 1:]
    for shell_index, shell_value in enumerate(shell_args):
        is_c = shell_value in {"-c", "-lc", "-cl"} or (
            shell_value.startswith("-") and not shell_value.startswith("--") and
            "c" in shell_value[1:]
        )
        if not is_c or shell_index + 1 >= len(shell_args):
            continue
        if (index + shell_index + 1 in unknown or index + shell_index + 2 in unknown or
                any(value <= index + shell_index + 2 for value in variable_cardinality)):
            return []
        try:
            nested_lexer = shlex.shlex(shell_args[shell_index + 1], posix=True, punctuation_chars=True)
            nested_tokens = list(nested_lexer)
        except ValueError:
            return []
        nested_segments, nested_current = [], []
        for nested_value in nested_tokens + [";"]:
            if nested_value in SEPARATORS:
                if nested_current:
                    nested_segments.append(nested_current)
                    nested_current = []
            else:
                nested_current.append(nested_value)
        # The nested callback uses the same canonical worktree identity. A
        # shell payload with a variable/opaque command simply has no visible
        # concrete child and remains transparent.
        return nested_segments, base
    return []

def inspect_segment(
    segment: list[str],
    depth: int = 0,
    base_override: str | None = None,
    unknown: frozenset[int] = frozenset(),
    variable_cardinality: frozenset[int] = frozenset(),
) -> str | None:
    if depth > 4:
        return None
    nested = shell_child_segments(segment, base_override, unknown, variable_cardinality)
    if nested is not None:
        nested_segments, nested_base = nested if nested else ([], base_override or command_cwd)
        for nested_segment in nested_segments:
            detail = inspect_segment(nested_segment, depth + 1, nested_base)
            if detail:
                return detail
        return None
    parsed = git_command(segment, base_override, unknown, variable_cardinality)
    if parsed is None:
        return None
    verb, args, base, argument_unknown = parsed
    if verb == "rm":
        return rm_detail(args, base, argument_unknown)
    if verb == "mv":
        return mv_detail(args, base, argument_unknown, include_index=(include_index == "true"))
    if verb == "restore":
        return restore_detail(args, base, argument_unknown, include_index=(include_index == "true"))
    if verb == "checkout":
        return checkout_detail(args, base, argument_unknown)
    return None

if analysis is not None:
    for record in analysis["commands"]:
        if record["reachability"] == "unreachable":
            continue
        directories = [record["cwd"]] if record["cwd_known"] else record["cwd_candidates"]
        for directory in directories or [""]:
            detail = inspect_segment(record["argv"], base_override=directory,
                                     unknown=frozenset(record.get("unknown_arguments") or []),
                                     variable_cardinality=frozenset(record.get("may_disappear_arguments") or []) |
                                                          frozenset(record.get("may_multiply_arguments") or []) |
                                                          frozenset(record.get("unknown_cardinality_arguments") or []) |
                                                          (frozenset(record.get("unknown_arguments") or [])
                                                           if "may_disappear_arguments" not in record else frozenset()))
            if detail:
                print(detail)
                raise SystemExit(0)
else:
    try:
        lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
        lexer.whitespace_split = True
        tokens = list(lexer)
    except ValueError:
        raise SystemExit(1)
    for segment in split_segments(tokens):
        detail = inspect_segment(segment)
        if detail:
            print(detail)
            raise SystemExit(0)
raise SystemExit(1)
PY
}

enforce_git_mutation_gate() {
  local specs=() operation repo_dir repo_root git_dir_raw git_dir marker specs_text index protected_target_detail protected_target_scope protected_target_token

  if ! specs_text="$(git_mutation_specs)"; then
    return 0
  fi
  if [ -n "$specs_text" ]; then
    mapfile -t specs <<<"$specs_text"
  fi
  if [ "${#specs[@]}" -eq 0 ]; then
    # A finite timeout wrapper may have no planner replay because its child
    # was not observed.  That absence is not a generic denial, but a
    # concrete protected-hook target remains actionable when the callback
    # CWD itself is a repository.  Keep this narrow fallback target-aware.
    repo_root="$(codex_git_safe -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)"
    repo_root="$(realpath -m -- "$repo_root" 2>/dev/null || true)"
    protected_target_scope=false
    [ "${hook_is_subagent:-false}" = true ] && protected_target_scope=true
    protected_target_detail="$(git_protected_worktree_target_detail "$command" "$repo_root" "$cwd" "$protected_target_scope" 2>/dev/null || true)"
    if [ -n "$protected_target_detail" ]; then
      if [ "${hook_is_subagent:-false}" = true ]; then
        protected_target_token="${protected_target_detail#operation=}"
        protected_target_token="${protected_target_token%% *}"
        deny_eci "ECI_WORKER_GIT_OWNERSHIP_DENIED" "worker-git-ownership" \
          "ECI worker Git preparation targets a protected live hook: ${protected_target_detail}; token=${protected_target_token}; predicate=worker-git-ownership; subpredicate=worker-protected-target; reason=active ECI control and provider-hook operations route through the Supervisor while ordinary implementation remains assigned to Producers" \
          "route the protected hook operation to the Supervisor, or use the assigned Producer route for ordinary scoped implementation changes"
      else
        deny_eci "ECI_COORDINATOR_EDIT_ROUTING_REQUIRED" "edit-routing" \
          "ECI Supervisor Git worktree mutation targets a protected live hook: ${protected_target_detail}; predicate=coordinator-protected-target; reason=tracked active-hook source edits are Producer-owned; protected provider/control operations use the Supervisor route" \
          "assign the exact tracked hook edit to a Producer, or route the provider/control operation through the Supervisor's canonical control route"
      fi
    fi
    return 0
  fi
  if [ $(( ${#specs[@]} % 2 )) -ne 0 ]; then
    return 0
  fi
  for ((index = 0; index < ${#specs[@]}; index += 2)); do
    operation="${specs[index]}"
    repo_dir="${specs[index + 1]}"
    case "$operation" in reset|reset-index|reset-working-tree|reset-unresolved|reset-option-unresolved|add-option-unresolved|add-target-unresolved|whole-worktree-staging|worktree|commit|commit-all|commit-stage|commit-amend|commit-unresolved|commit-option-unresolved|prep|repository|repository-unresolved|apply|output) ;; *) continue ;; esac
    if [ "${#syntax_eci_markers[@]}" -gt 0 ]; then
      validate_active_marker_binding
    fi
    # Known operation boundaries do not depend on a repository path being
    # known. The transport marker below is never a filesystem target.
    command_state="$operation"
    if [ "$operation" = reset-working-tree ] || [ "$operation" = reset-index ] || [ "$operation" = whole-worktree-staging ]; then
      deny_eci "ECI_BROAD_DESTRUCTIVE_DENIED" "git-mutation" \
        "ECI Git mutation has a broad destructive effect: effect=$operation target=$repo_dir" \
        "name the intended repository-relative paths, or use a non-destructive targeted Git action"
    fi
    if [ "$operation" = reset-unresolved ]; then
      deny_eci "ECI_BROAD_DESTRUCTIVE_DENIED" "git-mutation" \
        "ECI Git reset has an unresolved revision-or-path target or a path selection that may disappear: operation=$operation target=$repo_dir" \
        "supply the exact nonempty repository-relative paths after -- as preserved arguments, or use a non-destructive targeted Git action"
    fi
    if [ "$operation" = add-target-unresolved ]; then
      deny_eci "ECI_BROAD_DESTRUCTIVE_DENIED" "git-mutation" \
        "ECI Git add has no guaranteed narrowing path because every selector may disappear: operation=$operation target=$repo_dir" \
        "stage the exact nonempty owned paths as preserved arguments or stage their owned hunks separately"
    fi
    if [ "$operation" = commit-all ]; then
      deny_eci "ECI_BROAD_DESTRUCTIVE_DENIED" "git-mutation" \
        "ECI commit would automatically stage the whole tracked worktree: repository=$repo_dir; operation=commit-all" \
        "stage only the producing worker's exact owned paths or hunks, then make an ordinary commit"
    fi
    if [ "$operation" = commit-stage ]; then
      deny_eci "ECI_GIT_COMMIT_STAGING_DENIED" "git-commit" \
        "ECI commit would select or stage content outside the prepared index: repository=$repo_dir; operation=commit-stage" \
        "stage the exact owned paths or hunks separately, inspect the staged diff, then commit the prepared index"
    fi
    if [[ "$operation" = commit* ]] && [ "$operation" != commit-option-unresolved ] &&
      [ "${hook_is_subagent:-false}" != true ] &&
      [ "${#syntax_eci_markers[@]}" -gt 0 ]; then
      deny_eci "ECI_GIT_COMMIT_PRODUCER_REQUIRED" "git-commit" \
        "ECI Supervisor cannot author a Producer checkpoint: repository=$repo_dir; operation=$operation" \
        "have the assigned Producer commit its exact checked scope; the Supervisor verifies the immutable parent-to-commit range before the published Job owner starts dependent review or work"
    fi
    if [ "$operation" = commit-unresolved ]; then
      deny_eci "ECI_GIT_COMMIT_STAGING_DENIED" "git-commit" \
        "ECI commit has an unresolved pathspec-file selector: repository=$repo_dir; operation=commit-unresolved" \
        "stage and inspect the exact owned paths or hunks separately, then commit the prepared index without commit-time path selection; ordinary message values may remain dynamic"
    fi
    if [ "${hook_is_subagent:-false}" = true ]; then
      case "$operation" in
        commit-amend|worktree|repository)
          deny_eci "ECI_WORKER_GIT_OWNERSHIP_DENIED" "worker-git-ownership" \
            "ECI worker Git mutation controls repository acceptance or references: operation=${operation}; token=${operation}; predicate=worker-git-ownership" \
            "this history or reference mutation remains denied; send the protected request to the Supervisor; assigned Producers make ordinary scoped checkpoint commits through the resolved repository/effect checks"
          ;;
      esac
    fi
    # Unknown option/action identity is advisory, not a prohibited effect.
    # Concrete repository boundaries still apply to retained Git commands.
    # Remaining target uncertainty cannot become an invented repository path.
    [ "$repo_dir" != '<unresolved>' ] || continue
    repo_root="$(codex_git_safe -C "$repo_dir" rev-parse --show-toplevel 2>/dev/null || true)"
    repo_root="$(realpath -m -- "$repo_root" 2>/dev/null || true)"
    # A non-repository or otherwise unresolved Git target is Git's normal
    # runtime error, not proof of an accidental cross-scope mutation. Keep it
    # advisory; only a target that resolves to a different repository stops.
    [ -n "$repo_root" ] && [ -d "$repo_root" ] && [ ! -L "$repo_root" ] || continue
    git_dir_raw="$(codex_git_safe -C "$repo_root" rev-parse --absolute-git-dir 2>/dev/null || true)"
    git_dir="$(realpath -m -- "$git_dir_raw" 2>/dev/null || true)"
    [ -n "$git_dir" ] && [ -d "$git_dir" ] || continue
    if [ "$ECI_CROSS_SCOPE_GATE_ENABLED" = true ] &&
      cross_scope_detail="$(git_mutation_cross_scope_detail "$repo_root")" &&
      ! active_session_additional_repository_allowed "$repo_root"; then
      deny_eci "ECI_GIT_CROSS_SCOPE_DENIED" "git-mutation" \
        "ECI Git mutation targets a different repository without a valid declaration for this active session: ${cross_scope_detail}" \
        "from the active session, declare this exact canonical repository once with \"$HOME/.codex/bin/eci-active\" repository-allow-on <canonical-repository> \"<reason>\", or run the Git action from its owning session/repository"
    fi
    if [ "$operation" = output ]; then
      deny_eci "ECI_GIT_OUTPUT_WRITE_DENIED" "git-output" \
        "ECI Git inspection writes command output to a file: repository=$repo_root; operation=output" \
        "keep Git inspection output on stdout or use a separate, explicitly scoped file-writing command"
    fi
    if { [ "$operation" = reset ] || [ "$operation" = prep ]; } &&
      broad_effect_detail="$(git_mutation_broad_effect_detail "$repo_root")"; then
      deny_eci "ECI_BROAD_DESTRUCTIVE_DENIED" "git-mutation" \
        "ECI Git mutation has a broad destructive effect: ${broad_effect_detail}" \
        "name the intended repository-relative paths, or use a non-destructive targeted Git action"
    fi
    protected_target_scope=false
    [ "${hook_is_subagent:-false}" = true ] && protected_target_scope=true
    if [ "$operation" = prep ] &&
      protected_target_detail="$(git_protected_worktree_target_detail "$command" "$repo_root" "$cwd" "$protected_target_scope" 2>/dev/null || true)" &&
      [ -n "$protected_target_detail" ]; then
      if [ "${hook_is_subagent:-false}" = true ]; then
        protected_target_token="${protected_target_detail#operation=}"
        protected_target_token="${protected_target_token%% *}"
        deny_eci "ECI_WORKER_GIT_OWNERSHIP_DENIED" "worker-git-ownership" \
          "ECI worker Git preparation targets a protected live hook: ${protected_target_detail}; token=${protected_target_token}; predicate=worker-git-ownership; subpredicate=worker-protected-target; reason=active ECI control and provider-hook operations route through the Supervisor while ordinary implementation remains assigned to Producers" \
          "route the protected hook operation to the Supervisor, or use the assigned Producer route for ordinary scoped implementation changes"
      else
        deny_eci "ECI_COORDINATOR_EDIT_ROUTING_REQUIRED" "edit-routing" \
          "ECI Supervisor Git worktree mutation targets a protected live hook: ${protected_target_detail}; predicate=coordinator-protected-target; reason=tracked active-hook source edits are Producer-owned; protected provider/control operations use the Supervisor route" \
          "assign the exact tracked hook edit to a Producer, or route the provider/control operation through the Supervisor's canonical control route"
      fi
    fi
  done
  # Normal commits, refs, remotes, pushes, and targeted repository actions
  # need no approval artifact, exact grammar, receipt, or command spelling
  # ceremony. Review remains ordinary workflow, not a PreToolUse prerequisite.
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

# Projected records have already separated executable statements from body
# data. Resolve their Git effects before any generic allow route can exit.
if [ "$PLAN_SHELL_ANALYSIS" != null ] && [ "${#syntax_eci_markers[@]}" -gt 0 ]; then
  enforce_git_mutation_gate
  if [ "$hook_is_subagent" = true ] && command_invokes_eci_acceptance_mutation "$command"; then
    deny_eci "ECI_WORKER_ACCEPTANCE_DENIED" "worker-acceptance" \
      "ECI worker boundary denied a resolved Git history, explicit reference, or patch-application mutation in shell command analysis" \
      "route this history, reference, or patch-application operation through the ECI Supervisor"
  fi
fi

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
  # A pipeline is ordinary shell composition. Preserve a known broad reset
  # independently of target uncertainty; other reset effects need resolution.
  local segment="$1" specs=() specs_text operation repo_dir repo_root

  specs_text="$(git_mutation_specs "$segment" 2>/dev/null || true)"
  [ -n "$specs_text" ] || return 1
  mapfile -t specs <<<"$specs_text"
  [ "${#specs[@]}" -eq 2 ] || return 1
  operation="${specs[0]}"
  repo_dir="${specs[1]}"
  if [ "$operation" = reset-working-tree ]; then
    printf 'effect=%s target=%s\n' "$operation" "$repo_dir"
    return 0
  fi
  [ "$operation" = reset ] || return 1
  [ "$repo_dir" != '<unresolved>' ] || return 1
  repo_root="$(codex_git_safe -C "$repo_dir" rev-parse --show-toplevel 2>/dev/null || true)"
  repo_root="$(realpath -m -- "$repo_root" 2>/dev/null || true)"
  [ -n "$repo_root" ] && [ -d "$repo_root" ] && [ ! -L "$repo_root" ] || return 1
  git_mutation_broad_effect_detail "$repo_root" "$segment"
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
syntax_only = False
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
            if option in {"-n", "--noexec"}:
                syntax_only = True
            index += 1
            continue
        if option == "-O" and index + 1 < len(tokens):
            index += 2
            continue
        if option.startswith("-"):
            raise SystemExit(1)
        break
# A syntax-only invocation still names the protected control script.  Keep
# identifying that concrete target so workers receive the same ownership
# guidance as for an executing invocation; ordinary scripts remain outside
# this target-specific route.
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
        value_options = {
            "-amin", "-anewer", "-atime", "-cmin", "-cnewer", "-ctime",
            "-fstype", "-gid", "-group", "-iname", "-inum", "-ipath",
            "-iregex", "-iwholename", "-links", "-lname", "-mmin", "-mtime",
            "-name", "-newer", "-newerXY", "-path", "-perm", "-size",
            "-samefile", "-type", "-uid", "-used", "-user", "-wholename",
            "-regex",
        }
        index = 1
        while index < len(segment):
            token = segment[index]
            if token in value_options:
                index += 2
                continue
            if token in {"-delete", "-exec", "-execdir", "-ok", "-okdir"}:
                return token, base + index, "dynamic-find-action"
            index += 1
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

# A find action has a concrete per-match effect even when its visible root is
# an ordinary path. Keep -print and other inspections transparent, but do not
# let an active worker fast path hide -delete or an indirect child launch.
worker_dynamic_find_action_detail() {
  [ "${hook_is_subagent:-false}" = true ] || return 1
  [ "${plan_marker_state:-inactive}" = active ] || return 1
  [ "$COMPOUND_SEGMENT_VALIDATION" != true ] || return 1
  # Compound pipelines retain the existing bounded pipeline policy. This
  # guard owns a direct worker find action; its concrete target checks still
  # run for each pipeline segment below.
  local pipeline_segments detail
  pipeline_segments="$(eci_static_pipeline_segments "$1" 2>/dev/null || true)"
  [ -z "$pipeline_segments" ] || return 1
  detail="$(dynamic_indirection_detail "$1" 2>/dev/null || true)"
  case "$detail" in
    *'kind=dynamic-find-action')
      printf '%s\n' "$detail"
      return 0
      ;;
    *) return 1 ;;
  esac
}

# Admit only a finite pure read-only pipeline for an active worker. Concrete
# broad-destructive targets, Git ownership, and ECI control paths are checked
# before this route makes its read-only admission decision. Each segment is
# still passed through the existing capability classifier under a pipeline-only
# stdin context. This is a capability route, not an executable-name exception.
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
      # A dynamic value without a resolved target is not a concrete accidental
      # effect.  Let it fall through to normal execution; known control,
      # write, and broad-destructive targets are checked separately.
      return 1
    fi
    classification="$(ECI_READ_ONLY_PIPELINE=true classify_eci_command "$segment" 2>/dev/null || true)"
    # Resolve concrete protected/destructive targets before considering a
    # segment's general pipeline shape.  A broad `find -delete`, for example,
    # is a real accidental effect and must keep its target-aware diagnosis
    # rather than looking like an unsupported launcher.
    detail="$(protected_literal_operation_detail "$segment" true 2>/dev/null || true)"
    case "$detail" in
      class=broad\ *)
        deny_eci "ECI_BROAD_DESTRUCTIVE_DENIED" "broad-destructive" \
          "ECI worker pipeline denied broad destructive segment=$(eci_command_identity_subject "$segment"): ${detail}" \
          "narrow the reported target to the exact task-owned file or subdirectory, then retry the intended operation"
        ;;
      class=worker-git\ *)
        deny_eci "ECI_WORKER_GIT_OWNERSHIP_DENIED" "worker-git-ownership" \
          "ECI worker ownership gate denied protected Git segment=$(eci_command_identity_subject "$segment"): ${detail}; predicate=worker-git-ownership; ordinary assigned Producer commits use the separate repository/effect checks" \
          "route the reported protected Git operation request to the Supervisor; ordinary assigned Producer commits use the resolved repository/effect checks"
        ;;
    esac
    detail="$(command_invokes_git_branch_remote_mutation "$segment" 2>/dev/null || true)"
    if [ -n "$detail" ]; then
      deny_eci "ECI_WORKER_GIT_OWNERSHIP_DENIED" "worker-git-ownership" \
        "ECI worker ownership gate denied branch/remote mutation in pipeline segment=$(eci_command_identity_subject "$segment"): ${detail}; predicate=worker-git-ownership" \
        "send the reported Git ref or remote mutation request to the Supervisor"
    fi
    if command_invokes_eci_binary "$segment"; then
      detail="$(rejected_command_detail "$segment" 2>/dev/null || printf 'segment=<unclassified>')"
      deny_eci "ECI_CONTROL_OWNER_REQUIRED" "eci-control" \
        "ECI worker boundary denied Supervisor-owned control segment=$(eci_command_identity_subject "$segment"): ${detail}; reason=the canonical eci-active target owns lifecycle/control state" \
        "route the reported lifecycle/control request to the Supervisor"
    fi
    command="$segment"
    enforce_foreign_active_marker_mutation_boundary
    direct_ledger_static_control_target_pass "$command" || true
    [ "$DIRECT_LEDGER_FALLBACK_DECISION" != deny ] || direct_ledger_emit_fallback_denial
    # A launcher/classification miss is not a resolved effect. Unknown
    # segments fall through after the concrete checks above.
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

# A worker's ordinary read-only fast path must not turn provider control
# directories into an inspection relay. This is intentionally effect-based:
# it recognizes only a recursive find rooted in the known peer-runner fixture
# area and readlink/realpath of the current provider's session directory.
# Ordinary project reads, finite metadata reads, and equivalent coordinator
# commands remain outside this worker-only route.
worker_protected_inspection_detail() {
  [ "${hook_is_subagent:-false}" = true ] || return 1
  [ "${plan_marker_state:-inactive}" = active ] || return 1
  python3 - "$1" "$cwd" "$HOOK_DIR" "${KIMI_CODE_HOME:-${HOME:-}/.kimi-code}" <<'PY'
import os
import re
import shlex
import sys

command, hook_cwd, hook_dir, raw_peer_root = sys.argv[1:]

try:
    lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    tokens = list(lexer)
except ValueError:
    raise SystemExit(1)

operators = {";", "&", "&&", "|", "||", ">", ">>", ">|", ">&",
             "<", "<<", "<<<", "<&", "(", ")"}

def segments(values):
    current = []
    for token in values + [";"]:
        if token in operators:
            if current:
                yield current
            current = []
        else:
            current.append(token)

assignment = re.compile(r"[A-Za-z_][A-Za-z0-9_]*=.*", re.DOTALL)

def command_argv(values):
    """Return argv after literal launch wrappers accepted by the planner."""
    index = 0
    while index < len(values) and assignment.fullmatch(values[index]):
        index += 1
    while index < len(values):
        name = os.path.basename(values[index])
        if name == "env":
            index += 1
            while index < len(values):
                token = values[index]
                if assignment.fullmatch(token):
                    index += 1
                elif token in {"-i", "--ignore-environment", "-0", "--null"}:
                    index += 1
                elif token in {"-u", "--unset"}:
                    index += 2
                elif token.startswith("--unset="):
                    index += 1
                elif token == "--":
                    index += 1
                    break
                else:
                    break
            continue
        if name in {"command", "builtin", "exec", "nohup", "setsid"}:
            index += 1
            continue
        if name in {"timeout", "nice", "prlimit", "time"}:
            index += 1
            while index < len(values) and values[index].startswith("-"):
                if values[index] in {"-k", "--kill-after", "-s", "--signal",
                                     "-n", "--adjustment", "-p", "--property"}:
                    index += 2
                else:
                    index += 1
            if name == "timeout" and index < len(values):
                index += 1
            continue
        break
    return values[index:]

def concrete_path(token):
    if (not token or token.startswith("-") or any(marker in token for marker in
            ("$", "`", "*", "?", "[", "]", "{", "}"))):
        return None
    expanded = os.path.expanduser(token)
    candidate = expanded if os.path.isabs(expanded) else os.path.abspath(
        os.path.join(hook_cwd, expanded)
    )
    return os.path.normpath(candidate)

codex_root = os.path.realpath(os.path.dirname(hook_dir))
provider_sessions = os.path.normpath(os.path.join(codex_root, "sessions"))
peer_root = os.path.realpath(raw_peer_root) if raw_peer_root.startswith("/") else ""
if peer_root == codex_root:
    peer_root = ""

runner_name = re.compile(r"^\.codex-runner-test\.[A-Za-z0-9._-]+$")

def peer_runner_path(path):
    if not peer_root or not (path == peer_root or path.startswith(peer_root + os.sep)):
        return False
    relative = os.path.relpath(path, peer_root)
    first = relative.split(os.sep, 1)[0]
    return bool(runner_name.fullmatch(first))

def find_roots(argv):
    roots = []
    index = 1
    expression_starts = {"!", "(", ")", ","}
    while index < len(argv):
        token = argv[index]
        if token == "--":
            index += 1
            continue
        if token.startswith("-") or token in expression_starts:
            break
        path = concrete_path(token)
        if path is None:
            return []
        roots.append(path)
        index += 1
    return roots

def recursive_find(argv):
    roots = find_roots(argv)
    if not roots:
        return None
    # maxdepth 0 examines only the named starting point and is a finite
    # metadata read. Any deeper bound, or the default unbounded traversal,
    # walks the provider-control subtree.
    for index, token in enumerate(argv[1:], 1):
        if token == "-maxdepth" and index + 1 < len(argv):
            if argv[index + 1] == "0":
                return None
        if token.startswith("-maxdepth=") and token.split("=", 1)[1] == "0":
            return None
    for path in roots:
        if peer_runner_path(path):
            return path
    return None

for raw_segment in segments(tokens):
    argv = command_argv(raw_segment)
    if not argv:
        continue
    executable = os.path.basename(argv[0])
    if executable == "find":
        target = recursive_find(argv)
        if target is not None:
            print("predicate=peer-provider-recursive-inspection executable=find target=%s peer_root=%s" %
                  (target, peer_root))
            raise SystemExit(0)
    elif executable in {"readlink", "realpath"}:
        for token in argv[1:]:
            target = concrete_path(token)
            if target is None:
                continue
            if target == provider_sessions or os.path.realpath(target) == provider_sessions:
                print("predicate=provider-session-inspection executable=%s target=%s provider_sessions=%s" %
                      (executable, target, provider_sessions))
                raise SystemExit(0)
raise SystemExit(1)
PY
}

enforce_worker_protected_inspection() {
  local detail
  detail="$(worker_protected_inspection_detail "$1" 2>/dev/null || true)"
  if [ -n "$detail" ]; then
    deny_eci "ECI_WORKER_CONTROL_INSPECTION_DENIED" "worker-control" \
      "ECI worker control inspection denied: ${detail}; reason=the worker does not own this provider-control inspection and it could divert work from its task-owned files" \
      "inspect task-owned project or evidence files, or route provider-control inspection through the Supervisor"
  fi
}

worker_fast_path_control_guard() {
  enforce_foreign_active_marker_mutation_boundary
  direct_ledger_static_control_target_pass "$command" || true
  [ "$DIRECT_LEDGER_FALLBACK_DECISION" != deny ] || direct_ledger_emit_fallback_denial
  enforce_worker_protected_inspection "$command"
}

dynamic_find_action_detail="$(worker_dynamic_find_action_detail "$command" 2>/dev/null || true)"
if [ -n "$dynamic_find_action_detail" ]; then
  deny_eci "ECI_PLAN_DYNAMIC_LAUNCH_DENIED" "plan-segment" \
    "ECI worker command plan denied a dynamic find action: ${dynamic_find_action_detail}; predicate=dynamic-find-action" \
    "replace the find action with a finite direct command, or use -print for inspection"
fi

# Inline interpreter code is ordinary work when its effect is unresolved and
# no protected target is named.  Once the payload names an ECI control target
# and a write-like operation, however, the resolved effect is concrete even
# though the interpreter hides it from the argv planner.  Preserve the same
# dynamic-launch diagnostic for that narrow accidental-control-state case.
dynamic_interpreter_control_detail() {
  python3 - "${1:-}" "${CODEX_PROOF_ROOT_CONFIGURED:-${CODEX_PROOF_ROOT:-${HOME:?}/.cache/codex-proof}}" <<'PY'
import os
import re
import shlex
import sys

text, configured_root = sys.argv[1:]
try:
    tokens = shlex.split(text, posix=True)
except ValueError:
    raise SystemExit(1)

separators = {";", "&", "&&", "|", "||", "(", ")"}
interpreters = {
    "awk", "node", "nodejs", "perl", "php", "python", "python2", "python3",
    "ruby", "tclsh", "wish",
}
control_names = {
    "eci_active", "goal_state", "eci_wait", "eci_user_owned_wait.md",
    "eci-permissive-mode", "eci-permissive-authorize", ".eci-permissive-mode",
    ".eci-permissive-authorize", "eci-required-critics.json",
    "eci-critic-identities.ledger", "eci-acceptance-anchor",
    "eci-acceptance-transaction", "eci-teardown-complete", "eci-baseline-binding",
    "eci-commit-admitted", "eci-aggregate", "eci-aggregate-plan.json",
    "eci-aggregate-teardown-complete", "eci-accidental-mistake-override",
    ".eci-accidental-mistake-override", "eci-user-closed.ledger", "proof.md",
    "instructions.md", "stop_timestamps", "stop_loop_state", "disengage.md",
    "user-closed.md", "project-understanding.md", "high_level_log.md",
    "latest-status-report.md", "high_level_log.anchor",
}
write_call = re.compile(
    r"\b(?:open|write|write_text|unlink|remove|rename|replace|chmod|chown|mkdir|makedirs|rmdir|truncate|copy|move|install)\s*\(",
    re.IGNORECASE,
)
write_mode = re.compile(r"['\"](?:[wax]|[wax]\+|\+[wax])['\"]")

try:
    root = os.path.realpath(os.path.abspath(configured_root))
except OSError:
    root = ""

def split_segments(values):
    result, current = [], []
    for value in values + [";"]:
        if value in separators:
            if current:
                result.append(current)
            current = []
        else:
            current.append(value)
    return result

def mutating_payload(payload):
    return bool(write_call.search(payload) or write_mode.search(payload))

def target_in_payload(payload):
    if not mutating_payload(payload):
        return ""
    if root:
        absolute = re.escape(root)
        match = re.search(absolute + r"/[A-Za-z0-9_.@+-]+(?:/[A-Za-z0-9_.@+-]+)*", payload)
        if match and os.path.basename(match.group(0)) in control_names:
            return match.group(0)
    for name in sorted(control_names, key=len, reverse=True):
        if re.search(r"(?<![A-Za-z0-9_.-])" + re.escape(name) + r"(?![A-Za-z0-9_.-])", payload):
            return name
    return ""

def interpreter_flags(name):
    if name in {"python", "python2", "python3"} or name.startswith("python3."):
        return {"-c", "-"}
    if name in {"node", "nodejs"}:
        return {"-e", "-p", "--eval", "--print"}
    if name == "perl":
        return {"-e", "-E", "-"}
    if name == "php":
        return {"-r", "-R", "-B", "-E"}
    if name == "ruby" or name.startswith("ruby"):
        return {"-e", "-"}
    return {"-c", "-e", "-"}

def inspect(argv, depth=0):
    if depth > 5 or not argv:
        return
    while argv and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=.*", argv[0]):
        argv = argv[1:]
    if not argv:
        return
    name = os.path.basename(argv[0])
    if name == "env":
        index = 1
        while index < len(argv):
            value = argv[index]
            if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=.*", value) or value in {"-i", "--ignore-environment"}:
                index += 1
                continue
            if value in {"-u", "--unset", "-C", "--chdir"}:
                index += 2
                continue
            if value.startswith("--unset=") or value.startswith("--chdir="):
                index += 1
                continue
            if value == "--":
                index += 1
            break
        inspect(argv[index:], depth + 1)
        return
    if name in {"command", "builtin", "exec", "nohup", "setsid"}:
        inspect(argv[1:], depth + 1)
        return
    if name in interpreters:
        flags = interpreter_flags(name)
        for index, value in enumerate(argv[1:], 1):
            flag = next(
                (
                    candidate for candidate in sorted(flags, key=len, reverse=True)
                    if value == candidate or
                    (candidate != "-" and value.startswith(candidate) and len(value) > len(candidate))
                ),
                "",
            )
            if not flag:
                continue
            if value == flag:
                if index + 1 >= len(argv):
                    return
                payload = argv[index + 1]
            else:
                payload = value[len(flag):]
            target = target_in_payload(payload)
            if target:
                print("token=%s argv_index=%d target=%s" % (flag, index, target))
                return

for segment in split_segments(tokens):
    inspect(segment)
PY
}

worker_dynamic_execution_context_detail() {
  [ "$hook_is_subagent" = true ] || return 1
  [ "${#syntax_eci_markers[@]}" -gt 0 ] || return 1
  python3 - "${1:-}" <<'PY'
import os
import re
import shlex
import sys

try:
    tokens = shlex.split(sys.argv[1], posix=True)
except ValueError:
    raise SystemExit(1)

assignment = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)=(.*)", re.DOTALL)
context_names = {
    "BASH_ENV", "CDPATH", "ENV", "LD_LIBRARY_PATH", "LD_PRELOAD",
    "NODE_OPTIONS", "NODE_PATH", "PATH", "PERL5LIB", "PERL5OPT",
    "PYTHONHOME", "PYTHONPATH", "PYTHONSTARTUP", "RUBYLIB", "RUBYOPT",
    "ZDOTDIR",
}
if not tokens:
    raise SystemExit(1)

# Exporting a variable or installing a shell hash entry changes only the
# current shell context; it does not itself invoke a control executable.  Do
# not turn those state changes into an ECI denial.  A leading PATH assignment
# matters only when it resolves the immediately invoked bare eci-active to the
# canonical Codex binary and therefore establishes a concrete lifecycle call.
if tokens[0] in {"export", "hash"}:
    raise SystemExit(1)

configured_home = os.path.realpath(os.path.abspath(
    os.environ["CODEX_CONFIGURED_HOME"]
))
configured_eci = os.path.realpath(os.path.join(configured_home, "bin", "eci-active"))
index = 0
path_value = None
while index < len(tokens):
    match = assignment.fullmatch(tokens[index])
    if match is None:
        break
    if match.group(1) == "PATH":
        path_value = match.group(2)
    index += 1

if path_value is not None and index < len(tokens):
    executable = tokens[index]
    if executable == "eci-active":
        expanded_path = os.path.expandvars(os.path.expanduser(path_value))
        for path_entry in expanded_path.split(os.pathsep):
            if not path_entry:
                path_entry = "."
            candidate = os.path.realpath(os.path.join(path_entry, executable))
            if candidate == configured_eci:
                print("token=PATH argv_index=0 context=canonical-lifecycle-resolution executable=%s" % executable)
                raise SystemExit(0)
raise SystemExit(1)
PY
}

worker_dynamic_shell_indirection_detail() {
  [ "$hook_is_subagent" = true ] || return 1
  [ "${#syntax_eci_markers[@]}" -gt 0 ] || return 1
  local detail
  detail="$(dynamic_indirection_detail "$1" 2>/dev/null || true)"
  case "$detail" in
    token=eval\ *|token=source\ *|token=.\ *)
      # Indirection is not an effect by itself.  Keep ordinary/unknown
      # payloads transparent and route only a payload whose concrete target is
      # already recognized by an effect-aware boundary.
      if command_invokes_eci_binary "$1" ||
         command_invokes_eci_off "$1" ||
         command_invokes_eci_wait_or_resume "$1" ||
         command_invokes_eci_acceptance_mutation "$1" ||
         command_invokes_eci_control_mutation "$1" ||
         protected_literal_operation_detail "$1" true >/dev/null 2>&1; then
        printf '%s\n' "$detail"
        return 0
      fi
      return 1
      ;;
    *) return 1 ;;
  esac
}

worker_dynamic_shell_indirection_detail="$(worker_dynamic_shell_indirection_detail "$command" 2>/dev/null || true)"
if [ -n "$worker_dynamic_shell_indirection_detail" ]; then
  deny_eci "ECI_PLAN_DYNAMIC_LAUNCH_DENIED" "plan-segment" \
    "ECI worker command plan denied arbitrary shell indirection: ${worker_dynamic_shell_indirection_detail}; predicate=dynamic-shell-indirection; reason=the evaluated or sourced payload can execute an effect that cannot be established from the reviewed argv" \
    "invoke the intended executable or script directly through its resolved task-owned route"
fi

worker_dynamic_execution_context_detail="$(worker_dynamic_execution_context_detail "$command" 2>/dev/null || true)"
if [ -n "$worker_dynamic_execution_context_detail" ]; then
  dynamic_context_predicate=leading-assignment
  [[ "$worker_dynamic_execution_context_detail" == *"context=command-name-alias"* ]] &&
    dynamic_context_predicate=dynamic-launch
  deny_eci "ECI_PLAN_DYNAMIC_LAUNCH_DENIED" "plan-segment" \
    "ECI worker command plan denied a dynamic execution-context mutation: ${worker_dynamic_execution_context_detail}; predicate=$dynamic_context_predicate; reason=the command changes executable resolution or command-name binding beyond a bounded task target" \
    "invoke the task executable with its ordinary context, or use a resolved reviewed route"
fi

# Resolve concrete worker mutations of ECI control state before any generic
# planner/inspection route can fall through.  This is target/effect based:
# ordinary files and unrelated commands remain transparent, while a worker
# attempting to write the active control records is routed to the coordinator.
worker_control_detail=""
if [ "$hook_is_subagent" = true ] && [ "${#syntax_eci_markers[@]}" -gt 0 ]; then
  # Resolve a validated foreign active marker for this exact segment before
  # the generic worker-control ownership check can consume the same writer.
  enforce_foreign_active_marker_mutation_boundary
  worker_control_detail="$(worker_control_path_detail 2>/dev/null || true)"
  # A bounded read of a missing instruction-like path can report an
  # instruction-denied diagnostic from the shared resolver; it is not a
  # mutation of ECI control state and must remain transparent.
  case "$worker_control_detail" in
    instruction-denied\ *) worker_control_detail="" ;;
  esac
  if [ -n "$worker_control_detail" ]; then
    deny_eci "ECI_CONTROL_OWNER_REQUIRED" "worker-control" \
      "ECI worker ownership gate denied mutation of ECI control state: $worker_control_detail; predicate=worker-control; reason=the resolved target is active ECI control state rather than task-owned project data" \
      "route the resolved ECI control mutation through the Supervisor"
  fi
fi

dynamic_interpreter_control_detail="$(dynamic_interpreter_control_detail "$command" 2>/dev/null || true)"
if [ -n "$dynamic_interpreter_control_detail" ]; then
  deny_eci "ECI_PLAN_DYNAMIC_LAUNCH_DENIED" "plan-segment" \
    "ECI command plan denied a dynamic interpreter launch targeting ECI control state: ${dynamic_interpreter_control_detail}; predicate=dynamic-interpreter-launch; reason=the payload contains a write-like operation whose control target cannot be validated as an ordinary project file" \
    "invoke a literal script or executable with a resolved task-owned target, or route the control-state mutation through the Supervisor"
fi

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

# A source-build gap leaves ordinary work transparent. Before the ledger
# append fallback, inspect only static concrete current-session control targets
# so an accidental control mutation retains its target-specific diagnosis.
if [ "$CODEX_PLAN_TRANSPARENT_FALLBACK" = true ] && [ "${#syntax_eci_markers[@]}" -gt 0 ]; then
  if [ "$hook_is_subagent" = true ]; then
    enforce_worker_protected_inspection "$command"
  fi
  if [ "$hook_is_subagent" != true ]; then
    case "$command" in
      rm|rm\ *|mv|mv\ *)
        if ! eci_shared_cleanup_route "$command" false; then
          deny_eci "ECI_COORDINATOR_ROUTE_ARGUMENTS_DENIED" "coordinator-cleanup" \
            "ECI coordinator cleanup route denied: ${ECI_SHARED_CLEANUP_ROUTE_DETAIL:-command=$(eci_command_identity_subject "$command")}; predicate=cleanup-target" \
            "use the bounded coordinator cleanup route for an exact generated target"
        fi
        exit 0
        ;;
    esac
  fi
  if direct_ledger_static_control_target_pass "$command"; then
    [ "$DIRECT_LEDGER_FALLBACK_DECISION" != deny ] || direct_ledger_emit_fallback_denial
    if [ "$DIRECT_LEDGER_STATIC_DYNAMIC_TARGET" = true ]; then
      validate_active_marker_binding
      exit 0
    fi
  fi
  if direct_ledger_redirect_fallback "$command"; then
    case "$DIRECT_LEDGER_FALLBACK_DECISION" in
      allow)
        exit 0
        ;;
      deny)
        direct_ledger_emit_fallback_denial
        ;;
    esac
  fi
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
  [ "$WORKER_PROJECT_INSPECTION_ALLOWED" != true ] &&
  [ -z "$worker_protected_control_identity" ]; then
  enforce_foreign_active_marker_mutation_boundary
  direct_ledger_static_control_target_pass "$command" || true
  [ "$DIRECT_LEDGER_FALLBACK_DECISION" != deny ] || direct_ledger_emit_fallback_denial
fi

if [ "${#syntax_eci_markers[@]}" -gt 0 ] && [ "$plan_status" -eq 0 ] &&
  ! eci_cleanup_command_shape "$command" &&
  ! coordinator_git_worktree_effect_candidate "$command" &&
  [ "$coordinator_compound_mutation" != true ] &&
  [ "$coordinator_static_pipeline_candidate" != true ] &&
  ! coordinator_script_batch_shape "$command" &&
  ! shell_script_launcher_shape "$command" &&
  ! opaque_launcher_shape "$command" &&
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
  enforce_proof_path_escape_boundary "$command"
  exit 0
fi

# `bash -n` and `sh -n` parse one or more files without executing them. Keep
# this default-read-only route independent of reviewed test manifests and
# filename suffixes so extensionless runtime scripts can be checked before
# repair.
syntax_only_shell_check_route() {
  python3 - "$1" "$cwd" <<'PY'
import os
import shlex
import sys

command, hook_cwd = sys.argv[1:]
try:
    lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    tokens = list(lexer)
except ValueError:
    raise SystemExit(1)
if len(tokens) < 3 or tokens[0] not in {"bash", "sh"} or tokens[1] != "-n":
    raise SystemExit(1)
root = os.path.realpath(hook_cwd)
if (not os.path.isabs(hook_cwd) or os.path.normpath(hook_cwd) != hook_cwd or
        not os.path.isdir(hook_cwd) or os.path.islink(hook_cwd) or root != hook_cwd):
    raise SystemExit(1)
for script in tokens[2:]:
    if not script or script.startswith("-"):
        raise SystemExit(1)
    candidate = script if os.path.isabs(script) else os.path.join(root, script)
    candidate = os.path.normpath(candidate)
    resolved = os.path.realpath(candidate)
    if (not os.path.isfile(resolved) or
            not resolved.startswith(root + os.sep)):
        raise SystemExit(1)
raise SystemExit(0)
PY
}

# `bash -n`/`sh -n` only parse the named file and do not execute it.  That
# remains harmless inspection even when the file is a coordinator-owned hook;
# the worker control-script boundary below applies only to execution.
if syntax_only_shell_check_route "$command"; then
  validate_active_marker_binding
  exit 0
fi

COORDINATOR_SCRIPT_ROUTE_DETAIL=""
reviewed_script_route() {
  local detail
  detail="$(python3 - "$1" "$cwd" <<'PY'
import os
import hashlib
import re
import shlex
import shutil
import sys

command, hook_cwd = sys.argv[1], sys.argv[2]
worker = os.environ.get("CODEX_HOOK_IS_SUBAGENT") == "true"
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
if worker and (assignments or trace_pipeline or bounded_trace_flags or direct_script or
               len(tokens) != 2 or tokens[0] not in {"bash", "sh"}):
    print("coordinator-script-route worker reason=worker shell-test route requires exactly bash/sh SCRIPT without assignments, diagnostics, direct execution, batches, or repair arguments")
    raise SystemExit(1)
resolved_shell = shutil.which(shell_name) if shell_name else None
trusted_shells = {
    "bash": {"/bin/bash", "/usr/bin/bash", "/usr/local/bin/bash"},
    "sh": {"/bin/sh", "/usr/bin/sh", "/usr/local/bin/sh"},
}

if not direct_script and (not resolved_shell or resolved_shell not in trusted_shells[shell_name]):
    print("coordinator-script-route executable=" + shell_name + " reason=resolved executable is not trusted")
    raise SystemExit(1)
values = [os.environ.get(name, "") for name in (
    "CODEX_APPROVED_REPO_ROOT_1", "CODEX_APPROVED_REPO_ROOT_2",
    "CODEX_APPROVED_REPO_ROOT_3", "CODEX_PROOF_ROOT_CANONICAL",
    "CODEX_PROOF_ROOT_CONFIGURED", "CODEX_PROOF_ROOT_STABLE_ALIAS",
    "CODEX_CONFIGURED_HOME", "KIMI_CODE_HOME",
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

# Test-launch admission protects against accidental wrong-workspace and
# wrong-target writes, not adversarially modeled byte changes. A generic test
# must resolve to a readable .sh file directly below hooks/tests in the
# callback root; harmless symlink aliases are judged by that resolved target.
def structural_test_script(root, relative, candidate, resolved):
    prefix = "hooks/tests/"
    resolved_relative = os.path.relpath(resolved, root)
    if not resolved.startswith(root + os.sep):
        return False
    if not resolved_relative.startswith(prefix):
        return False
    leaf = resolved_relative[len(prefix):]
    if not leaf or "/" in leaf or not leaf.endswith(".sh"):
        return False
    return (os.path.isfile(resolved) and not os.path.islink(resolved)
            and os.access(resolved, os.R_OK))

def structural_installer_script(root, relative, candidate, resolved):
    target = os.path.join(root, "hooks/install-pre-commit-go-mod.sh")
    return (resolved == target and os.path.isfile(resolved)
            and not os.path.islink(resolved) and os.access(resolved, os.R_OK))

# Bind the route to the callback's selected canonical provider root.  Peer and
# companion roots are deliberately not fallback candidates for generic tests.
selected_root = os.path.realpath(hook_cwd)
if (not os.path.isabs(hook_cwd) or os.path.normpath(hook_cwd) != hook_cwd or
        not os.path.isdir(hook_cwd) or os.path.islink(hook_cwd) or
        selected_root != hook_cwd or selected_root not in roots):
    print("coordinator-script-route workspace=" + hook_cwd +
          " reason=callback workspace is not a canonical selected provider root")
    raise SystemExit(1)

def require_trusted_test_shell(shell, label):
    if shell not in trusted_shells:
        print("coordinator-script-route " + label + " shell=" + shell +
              " reason=script launcher must be literal bash or sh")
        raise SystemExit(1)
    shell_path = shutil.which(shell)
    if shell_path not in trusted_shells[shell]:
        print("coordinator-script-route " + label + " shell=" + shell +
              " reason=script launcher does not resolve to a trusted shell")
        raise SystemExit(1)

def resolve_structural_callback_script(script, label):
    if not script or script.startswith("-") or any(mark in script for mark in ("$", "`")):
        print("coordinator-script-route " + label + " script=" + script +
              " reason=non-literal path")
        raise SystemExit(1)
    # Normalize harmless internal `.`/`..` components before identifying the
    # concrete script.  The resolved target, rather than lexical spelling or
    # symlink shape, determines whether the script remains in the selected
    # callback root.
    candidate = script if os.path.isabs(script) else os.path.join(selected_root, script)
    candidate = os.path.normpath(candidate)
    resolved = os.path.realpath(candidate)
    if (resolved != selected_root and
            not resolved.startswith(selected_root + os.sep)):
        print("coordinator-script-route " + label + " script=" + script +
              " candidate=" + candidate + " resolved=" + resolved +
              " reason=script must be below the callback provider root")
        raise SystemExit(1)
    # A missing ordinary script is deliberately transparent: the shell owns
    # the resulting "not found" diagnostic and no control-state effect can
    # occur.  Keep this distinct from an existing malformed, unsupported, or
    # unreadable script, which still needs the reviewed-route boundary.
    if not os.path.exists(resolved):
        print("coordinator-script-route " + label + " script=" + script +
              " candidate=" + candidate + " resolved=" + resolved +
              " reason=script target does not exist")
        raise SystemExit(1)
    if (not os.path.isfile(resolved) or
            not resolved.endswith(".sh") or not os.access(resolved, os.R_OK)):
        print("coordinator-script-route " + label + " script=" + script +
              " candidate=" + candidate + " resolved=" + resolved +
              " reason=readable regular .sh file required")
        raise SystemExit(1)
    return candidate, resolved, os.path.relpath(resolved, selected_root)

# The prevalidated manifest-emitter assignment set is only useful to the
# canonical review-gate test; it is not a general assignment escape hatch.
manifest_emitter_entrypoint = "hooks/tests/test-eci-review-gate.sh"

# Shell composition is parsed into bounded child launches.  Each child is
# evaluated structurally; a safe test chain is admitted and an unsafe child is
# rejected at its own capability boundary.
if "&&" in tokens:
    if assignments:
        print("coordinator-script-route batch=assignments" +
              " reason=manifest-emitter assignments require one canonical review-gate launch")
        raise SystemExit(1)
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
        if not segment or segment[0] not in {"bash", "sh"} or len(segment) < 2:
            print("coordinator-script-route batch=segment-" + str(segment_index) + " reason=expected bash/sh SCRIPT or bash/sh -n SCRIPT...")
            raise SystemExit(1)
        require_trusted_test_shell(segment[0], "batch=segment-" + str(segment_index))
        if segment[1] == "-n":
            syntax_scripts = segment[2:]
            if not syntax_scripts:
                print("coordinator-script-route batch=segment-" + str(segment_index) + " reason=syntax-only route requires at least one script")
                raise SystemExit(1)
            for syntax_script in syntax_scripts:
                syntax_candidate = syntax_script if os.path.isabs(syntax_script) else os.path.join(selected_root, syntax_script)
                syntax_candidate = os.path.normpath(syntax_candidate)
                syntax_resolved = os.path.realpath(syntax_candidate)
                if (not os.path.isfile(syntax_resolved) or
                        not syntax_resolved.startswith(selected_root + os.sep)):
                    print("coordinator-script-route batch=segment-" + str(segment_index) + " script=" + syntax_script + " candidate=" + syntax_candidate + " resolved=" + syntax_resolved + " reason=syntax-only target is outside the callback provider root")
                    raise SystemExit(1)
            continue
        if len(segment) != 2:
            print("coordinator-script-route batch=segment-" + str(segment_index) + " reason=expected exactly one executable script for an executing route")
            raise SystemExit(1)
        candidate, resolved, relative = resolve_structural_callback_script(
            segment[1], "batch=segment-" + str(segment_index))
        if not structural_test_script(selected_root, relative, candidate, resolved):
            print("coordinator-script-route batch=segment-" + str(segment_index) + " script=" + segment[1] + " reason=script is outside the structural callback-root test route")
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
    route_kind = "trace"
elif direct_script:
    script = tokens[0]
    syntax_only = False
    repair_peer = None
    route_kind = "direct"
elif bounded_trace_flags:
    # Shell diagnostics are bounded to one structural .sh entrypoint; only
    # the finite -x/-n flag grammar above is accepted.
    script = tokens[-1]
    syntax_only = "-n" in bounded_trace_flags
    repair_peer = None
    route_kind = "diagnostic"
elif len(tokens) == 2:
    script = tokens[1]
    syntax_only = False
    repair_peer = None
    route_kind = "shell"
elif len(tokens) == 4 and tokens[2] == "--repair-hardlink":
    script = tokens[1]
    syntax_only = False
    repair_peer = tokens[3]
    route_kind = "installer-repair"
else:
    print("coordinator-script-route command=" + tokens[0] + " reason=expected exactly bash/sh SCRIPT or the installer hard-link repair form")
    raise SystemExit(1)
if not direct_script:
    require_trusted_test_shell(tokens[0], route_kind)
candidate, resolved, relative = resolve_structural_callback_script(script, route_kind)
if structural_installer_script(selected_root, relative, candidate, resolved):
    if worker or assignments or route_kind not in {"shell", "installer-repair"}:
        print("coordinator-script-route script=" + relative +
              " canonical_target=" + resolved +
              " reason=installer route is coordinator-only, non-diagnostic, and accepts no assignments")
        raise SystemExit(1)
    if repair_peer is not None:
        project_roots = {
            os.path.realpath(value)
            for value in (
                os.environ["CODEX_CONFIGURED_HOME"],
                os.environ.get("KIMI_CODE_HOME") or os.path.join(os.environ.get("HOME", ""), ".kimi-code"),
            )
            if value and os.path.isabs(value) and os.path.isdir(value) and not os.path.islink(value)
        }
        if (repair_peer.startswith("-") or os.path.normpath(repair_peer) != repair_peer or
                os.path.islink(repair_peer) or os.path.realpath(repair_peer) not in project_roots or
                os.path.realpath(repair_peer) == selected_root):
            print("coordinator-script-route hard-link-repair reason=installer and peer must be the other canonical Codex/Kimi repository root")
            raise SystemExit(1)
    print("ok")
    raise SystemExit(0)
if assignments and (worker or route_kind != "shell" or relative != manifest_emitter_entrypoint):
    print("coordinator-script-route script=" + relative +
          " canonical_target=" + os.path.join(selected_root, manifest_emitter_entrypoint) +
          " reason=manifest-emitter assignments require the canonical coordinator review-gate test")
    raise SystemExit(1)
if repair_peer is not None or not structural_test_script(
        selected_root, relative, candidate, resolved):
    print("coordinator-script-route script=" + relative +
          " reason=generic route admits only readable canonical direct-child hooks/tests/*.sh scripts")
    raise SystemExit(1)
print("ok")
raise SystemExit(0)
PY
  )" && {
    COORDINATOR_SCRIPT_ROUTE_DETAIL=""
    return 0
  }
  COORDINATOR_SCRIPT_ROUTE_DETAIL="${detail:-coordinator-script-route reason=command is outside approved verification grammar}"
  return 1
}

# The Stop syntax route admits one no-exec check by literal command and
# canonical target identity. It intentionally does not read a content digest:
# Bash -n does not execute the changed hook, and the route guards accidental
# wrong-shell, wrong-target, and ownership mistakes instead.
trusted_stop_gate_syntax_bash() {
  local bash_type bash_path bash_real

  bash_type="$(type -t bash 2>/dev/null || true)"
  [ "$bash_type" = file ] || return 1
  bash_path="$(type -P bash 2>/dev/null || true)"
  [ -n "$bash_path" ] && [ -f "$bash_path" ] && [ -x "$bash_path" ] && [ ! -L "$bash_path" ] || return 1
  bash_real="$(realpath -e -- "$bash_path" 2>/dev/null || true)"
  [ "$bash_real" = "$bash_path" ] || return 1
  case "$bash_real" in
    /bin/bash|/usr/bin/bash|/usr/local/bin/bash) return 0 ;;
    *) return 1 ;;
  esac
}

coordinator_stop_gate_syntax_route() {
  local canonical_root canonical_target cwd_target root_real target_real cwd_target_real relative_target

  [ "$hook_is_subagent" != true ] || return 1
  [ "${plan_role:-}" = coordinator ] || return 1
  trusted_stop_gate_syntax_bash || return 1

  canonical_root="${HOME:?HOME must be set}/.codex"
  canonical_target="$canonical_root/hooks/stop-gate.sh"
  cwd_target="$cwd/hooks/stop-gate.sh"
  # The canonical hook may be syntax-checked by its coordinator from a
  # foreign callback CWD.  An absolute canonical target identifies the same
  # read-only effect regardless of CWD; keep the relative spelling bound to
  # the callback workspace so a foreign relative path cannot borrow this
  # route.
  case "$1" in
    'bash -n hooks/stop-gate.sh')
      relative_target=true
      ;;
    "bash -n $canonical_target")
      relative_target=false
      ;;
    *)
      return 1
      ;;
  esac
  # Relative inspection is tied to an active marker for the callback CWD;
  # absolute inspection already identifies the canonical provider target and
  # is harmless even when the callback itself runs from another workspace.
  if [ "$relative_target" = true ]; then
    [ "${plan_marker_state:-}" = active ] || return 1
    [ "${#syntax_eci_markers[@]}" -eq 1 ] || return 1
  fi
  [ -d "$canonical_root" ] && [ ! -L "$canonical_root" ] || return 1
  root_real="$(realpath -e -- "$canonical_root" 2>/dev/null || true)"
  [ "$root_real" = "$canonical_root" ] || return 1
  [ -f "$canonical_target" ] && [ ! -L "$canonical_target" ] || return 1
  target_real="$(realpath -e -- "$canonical_target" 2>/dev/null || true)"
  [ "$target_real" = "$canonical_target" ] || return 1
  [ "$relative_target" = false ] || {
    cwd_target_real="$(realpath -e -- "$cwd_target" 2>/dev/null || true)"
    [ "$cwd_target_real" = "$canonical_target" ] || return 1
  }
  return 0
}

coordinator_script_route() {
  [ "$hook_is_subagent" != true ] || return 1
  reviewed_script_route "$1"
}

# The coordinator may run the configured peer provider's bounded test scripts
# for cross-provider verification.  This is a concrete provider-root route,
# not a generic escape for arbitrary external scripts; canonical installer and
# lifecycle operations retain their own routes above.
coordinator_peer_script_target_allowed() {
  local detail="$1" resolved peer
  [[ "$detail" == *"reason=script must be below the callback provider root"* ]] || return 1
  resolved="${detail#* resolved=}"
  resolved="${resolved%% reason=*}"
  peer="${KIMI_CODE_HOME:-${HOME:-}/.kimi-code}"
  [ -n "$peer" ] && [ "${peer#/}" != "$peer" ] || return 1
  [ "$(realpath -e -- "$peer" 2>/dev/null || true)" = "$peer" ] || return 1
  case "$resolved" in
    "$peer"/hooks/tests/*.sh) ;;
    *) return 1 ;;
  esac
  [ -f "$resolved" ] && [ ! -L "$resolved" ] &&
    [ "$(realpath -e -- "$resolved" 2>/dev/null || true)" = "$resolved" ] &&
  [ -r "$resolved" ]
}

coordinator_enforce_script_target() {
  local command_value="$1" detail
  [ "$hook_is_subagent" != true ] || return 0
  shell_script_launcher_shape "$command_value" || return 0
  COORDINATOR_SCRIPT_ROUTE_DETAIL=""
  coordinator_script_route "$command_value" && return 0
  detail="${COORDINATOR_SCRIPT_ROUTE_DETAIL:-}"
  [[ "$detail" == *"reason=script must be below the callback provider root"* ]] || return 0
  coordinator_peer_script_target_allowed "$detail" && return 0
  coordinator_peer_installer_route "$command_value" && return 0
  deny_eci "ECI_COORDINATOR_SCRIPT_TARGET_DENIED" "coordinator-script-target" \
    "ECI coordinator shell-script target denied: ${detail}; predicate=coordinator-script-target; reason=the resolved script target is outside the selected provider root" \
    "invoke a script under the selected canonical provider root, or route the concrete dependency-repository work to the current Job owner"
}


# Manifest-emitter assignments are a concrete control-state route, not a
# generic shell-syntax permission.  If those bounded assignments are present,
# require the canonical review-gate entrypoint; an ordinary script command (or
# an unknown planner result) remains transparent.  This catches an accidental
# wrong-entrypoint invocation without turning parser/receipt metadata into a
# blanket denial.
coordinator_enforce_manifest_script_route() {
  local command_value="$1" detail
  [ "$hook_is_subagent" != true ] || return 0
  [[ "$command_value" == ECI_EMIT_* ]] || return 0
  COORDINATOR_SCRIPT_ROUTE_DETAIL=""
  coordinator_script_route "$command_value" && return 0
  detail="${COORDINATOR_SCRIPT_ROUTE_DETAIL:-}"
  [[ "$detail" == *"assignment="* ||
    "$detail" == *"assignment-set"* ||
    "$detail" == *"manifest-emitter assignments require the canonical coordinator review-gate test"* ]] || return 0
  deny_eci "ECI_COORDINATOR_MANIFEST_ROUTE_DENIED" "coordinator-manifest-route" \
    "ECI coordinator manifest-emitter route denied: ${detail}; predicate=coordinator-manifest-route; reason=ECI_EMIT_* assignments are control metadata and may be passed only to the canonical review-gate test entrypoint" \
    "invoke hooks/tests/test-eci-review-gate.sh with the complete supported ECI_EMIT_* assignment set, or remove the manifest-emitter assignments"
}

worker_reviewed_script_route() {
  [ "$hook_is_subagent" = true ] || return 1
  reviewed_script_route "$1"
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
    os.environ["CODEX_CONFIGURED_HOME"]
) if os.environ.get("CODEX_HOOK_IS_SUBAGENT") == "true" else ""
peer_homes = {
    os.path.realpath(os.environ["CODEX_CONFIGURED_HOME"]),
    os.path.realpath(os.path.join(os.environ.get("HOME", ""), ".kimi-code")),
}
for name in (
    "CODEX_APPROVED_REPO_ROOT_1", "CODEX_APPROVED_REPO_ROOT_2", "CODEX_APPROVED_REPO_ROOT_3",
    "CODEX_PROOF_ROOT_CANONICAL", "CODEX_PROOF_ROOT_CONFIGURED", "CODEX_PROOF_ROOT_STABLE_ALIAS",
    "KIMI_CODE_HOME",
):
    value = os.environ.get(name, "")
    if value and os.path.isabs(value) and os.path.normpath(value) == value and os.path.isdir(value):
        resolved = os.path.realpath(value)
        if (worker_home and resolved in peer_homes and resolved != worker_home):
            continue
        if not os.path.islink(value) and resolved == value:
            roots.add(value)
home = os.environ.get("HOME", "")
for value in (os.environ["CODEX_CONFIGURED_HOME"], os.path.join(home, ".kimi-code")):
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
    directives = set("aAbBCdDfFgGhimnNostTuUwWxXyYzZ")

    def bounded_format(value):
        if not value or len(value) > 256:
            return False
        directive_seen = False
        index = 0
        while index < len(value):
            character = value[index]
            if character == "%":
                if index + 1 >= len(value):
                    return False
                directive = value[index + 1]
                if directive == "%":
                    index += 2
                    continue
                if directive not in directives:
                    return False
                directive_seen = True
                index += 2
                continue
            if ord(character) < 0x20 or character in "$`\\;|&<>(){}[]*?":
                return False
            index += 1
        return directive_seen

    paths = []
    index = 0
    while index < len(args):
        token = args[index]
        if token in {"-c", "--format", "-Lc", "-cL"}:
            if index + 1 >= len(args) or not bounded_format(args[index + 1]):
                return False
            index += 2
        elif token.startswith("--format="):
            if not bounded_format(token.split("=", 1)[1]):
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
    directives = set("aAbBCdDfFgGhimnNostTuUwWxXyYzZ")

    def bounded_format(value):
        if not value or len(value) > 256:
            return False
        directive_seen = False
        index = 0
        while index < len(value):
            character = value[index]
            if character == "%":
                if index + 1 >= len(value):
                    return False
                directive = value[index + 1]
                if directive == "%":
                    index += 2
                    continue
                if directive not in directives:
                    return False
                directive_seen = True
                index += 2
                continue
            if ord(character) < 0x20 or character in "$`\\;|&<>(){}[]*?":
                return False
            index += 1
        return directive_seen

    paths = []
    index = 1
    while index < len(tokens):
        token = tokens[index]
        if token in {"-c", "--format", "-Lc", "-cL"}:
            if index + 1 >= len(tokens) or not bounded_format(tokens[index + 1]):
                reject("stat format is outside the bounded metadata grammar")
            index += 2
            continue
        if token.startswith("--format="):
            if not bounded_format(token.split("=", 1)[1]):
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

# A reviewed script is a bounded read-only segment only after the existing
# digest-bound script route accepts it; inspection commands retain their own
# literal parser.
coordinator_compound_read_only_segment() {
  # `bash -n`/`sh -n` only parse a file; they do not execute its payload and
  # therefore remain ordinary inspection even when composed with a writer.
  syntax_only_shell_check_route "$1" ||
    coordinator_inspection_route "$1" ||
    coordinator_script_route "$1"
}

coordinator_compound_private_session_cleanup_left() {
  local operator="$1" left="$2"
  case "$left" in
    git\ status|git\ status\ *) return 0 ;;
  esac
  [ "$operator" = '&&' ] || return 1
  case "$left" in
    bash\ hooks/tests/*.sh|sh\ hooks/tests/*.sh) return 0 ;;
  esac
  return 1
}

# A non-cleanup mutation in a coordinator compound is not automatically an
# ECI error.  The planner has already identified the segment as a finite
# ordinary argv; this adapter only replays the concrete target checks that a
# direct segment would receive.  In particular, `touch`, `tee`, and similar
# ordinary writers must not be rejected merely because they follow an
# inspection with `&&`/`||`.  Destructive cleanup remains on its named bounded
# route, while broad, proof/control, and Git effects keep their own diagnoses.
coordinator_compound_mutation_effect_route() {
  [ "$hook_is_subagent" != true ] || return 1
  local segment="$1" detail saved_command

  # Cleanup has a deliberately narrower ownership route.  Let the caller
  # report the existing compound-mutation diagnostic when it is not eligible.
  if eci_cleanup_command_shape "$segment"; then
    return 1
  fi

  detail="$(protected_broad_operation_detail "$segment" 2>/dev/null || true)"
  if [ -n "$detail" ]; then
    deny_eci "ECI_BROAD_DESTRUCTIVE_DENIED" "broad-destructive" \
      "ECI coordinator compound contains a broad destructive effect: ${detail}; predicate=compound-mutation" \
      "replace the broad target with one explicit narrow recoverable target"
  fi

  # Reuse the normal proof/control target resolver for this one segment.  It
  # emits the concrete cross-session/live-control denial itself when needed;
  # an ordinary repository or temporary-file writer leaves the decision empty.
  direct_ledger_static_control_target_pass "$segment" true || true
  [ "$DIRECT_LEDGER_FALLBACK_DECISION" != deny ] || direct_ledger_emit_fallback_denial
  enforce_proof_path_escape_boundary "$segment"

  # Git target/effect checks use the shell-global command for historical
  # compatibility.  Temporarily bind it to this segment so a compound does
  # not lose cross-repository, output, broad, or protected-worktree checks.
  if [[ "$segment" == *git* || "$segment" == *reset* || "$segment" == *worktree* ]]; then
    saved_command="$command"
    command="$segment"
    maybe_enforce_git_mutation_gate
    command="$saved_command"
  fi
  return 0
}

coordinator_compound_inspection_route() {
  [ "$hook_is_subagent" != true ] || return 1
  local segments detail segment
  # Avoid a second shell lexer for the common one-operator direct-argv form.
  # The planner has already rejected quoting, expansion, and unsupported
  # operators; route each literal side through the same authoritative adapters.
  case "$1" in
    *"'"*|*'"'*|*'\\'*|*'$'*|*'`'*) ;;
    *'&&'*'&&'*|*'||'*'||'*) ;;
    *'&&'*|*'||'*)
      local left right operator allow_private_session_child=false
      if [[ "$1" == *'&&'* ]]; then
        left="${1%%&&*}"
        right="${1#*&&}"
        operator='&&'
      else
        left="${1%%||*}"
        right="${1#*||}"
        operator='||'
      fi
      left="${left#"${left%%[![:space:]]*}"}"
      left="${left%"${left##*[![:space:]]}"}"
      right="${right#"${right%%[![:space:]]*}"}"
      right="${right%"${right##*[![:space:]]}"}"
      coordinator_compound_read_only_segment "$left" || return 1
      if coordinator_compound_private_session_cleanup_left "$operator" "$left"; then
        allow_private_session_child=true
      fi
      if coordinator_shared_cleanup_route "$right" "$allow_private_session_child"; then
        return 0
      fi
      coordinator_compound_mutation_effect_route "$right" || return 1
      return 0
      ;;
  esac
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
    coordinator_compound_read_only_segment "$segment" ||
      coordinator_shared_cleanup_route "$segment" ||
      coordinator_compound_mutation_effect_route "$segment" || return 1
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
    os.environ["CODEX_CONFIGURED_HOME"],
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
COORDINATOR_PEER_ECI_ROUTE_MODE=""
coordinator_peer_eci_route() {
  [ "$PLAN_CODEX_LIFECYCLE_ROUTE" = true ] || return 1

  # Resolve the executable that this finite direct/env command would launch.
  # The text spelling is never authority: a same-file target is compatible,
  # a known different target is reported, and syntax we cannot resolve simply
  # falls through to the ordinary command path.
  local target_resolution
  COORDINATOR_PEER_ECI_ROUTE_DETAIL=""
  COORDINATOR_PEER_ECI_ROUTE_MODE=""
  target_resolution="$(python3 - "$1" "$cwd" "${session_id:-}" <<'PY'
import os
import re
import shutil
import stat
import sys

command, callback_cwd, active_session = sys.argv[1:]

def unresolved():
    print("unresolved")
    raise SystemExit(0)

def parse_words(source):
    words = []
    index = 0
    length = len(source)

    def expand_variable(position):
        if position >= length:
            return None, position
        if source[position] == "{":
            closing = source.find("}", position + 1)
            if closing < 0:
                return None, position
            name = source[position + 1:closing]
            if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name) is None:
                return None, position
            return os.environ.get(name, ""), closing + 1
        match = re.match(r"[A-Za-z_][A-Za-z0-9_]*", source[position:])
        if match is None:
            return None, position
        name = match.group(0)
        return os.environ.get(name, ""), position + len(name)

    while index < length:
        while index < length and source[index] in " \t":
            index += 1
        if index == length:
            break
        value = []
        quote = None
        started = False
        while index < length:
            character = source[index]
            if quote is None:
                if character in " \t":
                    break
                if character in ";|&()<>":
                    return None
                if character in "*?[]`":
                    return None
                if character == "'":
                    quote = "'"
                    started = True
                    index += 1
                    continue
                if character == '"':
                    quote = '"'
                    started = True
                    index += 1
                    continue
                if character == "\\":
                    if index + 1 >= length:
                        return None
                    value.append(source[index + 1])
                    started = True
                    index += 2
                    continue
                if character == "$":
                    expanded, next_index = expand_variable(index + 1)
                    if expanded is None:
                        return None
                    value.append(expanded)
                    started = True
                    index = next_index
                    continue
                if character == "~" and not value:
                    if index + 1 < length and source[index + 1] not in "/ \t":
                        return None
                    home = os.environ.get("HOME", "")
                    if not home:
                        return None
                    value.append(home)
                    started = True
                    index += 1
                    continue
                value.append(character)
                started = True
                index += 1
                continue
            if quote == "'":
                if character == "'":
                    quote = None
                else:
                    value.append(character)
                index += 1
                continue
            if character == '"':
                quote = None
                index += 1
                continue
            if character == "`":
                return None
            if character == "\\":
                if index + 1 >= length:
                    return None
                value.append(source[index + 1])
                index += 2
                continue
            if character == "$":
                expanded, next_index = expand_variable(index + 1)
                if expanded is None:
                    return None
                value.append(expanded)
                index = next_index
                continue
            value.append(character)
            index += 1
        if quote is not None or not started:
            return None
        words.append("".join(value))
    return words

def executable_path(value, environment):
    if not value:
        return ""
    if "/" in value:
        candidate = value if os.path.isabs(value) else os.path.join(callback_cwd, value)
    else:
        candidate = shutil.which(value, path=environment.get("PATH"))
    if not candidate:
        return ""
    try:
        status = os.stat(candidate)
    except OSError:
        return ""
    if not stat.S_ISREG(status.st_mode) or not os.access(candidate, os.X_OK):
        return ""
    return os.path.realpath(candidate)

def real_system_env(value, environment):
    resolved = executable_path(value, environment)
    if not resolved:
        return False
    for system_env in ("/usr/bin/env", "/bin/env"):
        try:
            if os.path.samefile(resolved, system_env):
                return True
        except OSError:
            continue
    return False

words = parse_words(command)
if not words:
    unresolved()

environment = dict(os.environ)
assigned_names = set()
index = 0
launcher = words[index]
if os.path.basename(launcher) == "env":
    if not real_system_env(launcher, environment):
        unresolved()
    index += 1
    if index < len(words) and words[index] == "--":
        index += 1
    while index < len(words):
        assignment = words[index]
        match = re.fullmatch(r"([A-Za-z_][A-Za-z0-9_]*)=(.*)", assignment, re.DOTALL)
        if match is None:
            break
        name, value = match.groups()
        environment[name] = value
        assigned_names.add(name)
        index += 1
if index >= len(words):
    unresolved()

candidate = executable_path(words[index], environment)
if not candidate:
    unresolved()
# This adapter is a lifecycle parser, not a generic executable gate.  A
# planner-source fallback must leave ordinary commands alone; only a resolved
# eci-active target needs lifecycle identity handling.
if os.path.basename(candidate) != "eci-active":
    unresolved()
canonical = os.path.join(os.environ.get("HOME", ""), ".codex", "bin", "eci-active")
try:
    same_target = bool(canonical) and os.path.samefile(candidate, canonical)
except OSError:
    unresolved()
if not same_target:
    print("different lifecycle target")
    raise SystemExit(0)

arguments = words[index + 1:]
session_independent_maintenance = (
    bool(arguments) and arguments[0] in {"maintain-planner", "sync-runtime"}
)
# Mutating Codex lifecycle calls must retain the literal current-home authority
# so a symlinked/expanded path cannot silently become a second control entry
# point.  Read-only visibility (help/status) was handled before this adapter;
# malformed help continues to the CLI as ordinary discovery.
canonical_spelling = re.compile(r"(?:(?:\"|')?\$HOME/\.codex/bin/eci-active(?:\"|')?)")
if (arguments and arguments[0] not in {"--help", "-h", "status"} and
        not canonical_spelling.search(command)):
    print("canonical lifecycle spelling mismatch: expected literal $HOME/.codex/bin/eci-active for mutating provider arguments")
    raise SystemExit(0)
if not session_independent_maintenance:
    if "KIMI_SESSION_ID" in assigned_names:
        print("provider session identity mismatch: expected_name=CODEX_SESSION_ID observed_name=KIMI_SESSION_ID")
        raise SystemExit(0)
    if "CODEX_SESSION_ID" in assigned_names:
        if environment["CODEX_SESSION_ID"] != active_session:
            print("active session identity mismatch: expected=CODEX_SESSION_ID=%s observed=CODEX_SESSION_ID=%s" % (active_session, environment["CODEX_SESSION_ID"]))
            raise SystemExit(0)

if arguments and arguments[0] in {"--help", "-h"}:
    print("same help")
else:
    print("same lifecycle")
PY
)" || target_resolution="unresolved"
  case "$target_resolution" in
    "same help")
      COORDINATOR_PEER_ECI_ROUTE_MODE=help
      return 0
      ;;
    "same lifecycle")
      COORDINATOR_PEER_ECI_ROUTE_MODE=lifecycle
      ;;
    "different lifecycle target")
      COORDINATOR_PEER_ECI_ROUTE_DETAIL="target identity mismatch: executable resolves to a different provider, copy, or target"
      return 1
      ;;
    "canonical lifecycle spelling mismatch:"*)
      COORDINATOR_PEER_ECI_ROUTE_DETAIL="$target_resolution"
      return 1
      ;;
    "provider session identity mismatch:"*|"active session identity mismatch:"*)
      COORDINATOR_PEER_ECI_ROUTE_DETAIL="$target_resolution"
      return 1
      ;;
    *)
      return 1
      ;;
  esac

  local detail

if detail="$(python3 - "$1" "${session_id:-}" <<'PY'
import os
import re
import shlex
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
home = os.environ.get("HOME", "")
canonical_command = os.path.join(home, ".codex", "bin", "eci-active")
# The typed Go route already proved the raw command spelling. Recheck only
# that its decoded child agrees with that route before binding HOME-derived
# identity; this is consistency validation, not a second value-only acceptor.
if command != "$HOME/.codex/bin/eci-active":
    print("typed Codex lifecycle route did not contain the canonical decoded child")
    raise SystemExit(1)
command = canonical_command
if not command or not os.path.isabs(command) or os.path.normpath(command) != command:
    raise SystemExit(1)
roots = (
    os.environ["CODEX_CONFIGURED_HOME"],
)
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

def canonical_proof_root_claim(value):
    proof_root = os.environ.get("CODEX_PROOF_ROOT_CANONICAL", "")
    if (not proof_root or not os.path.isabs(proof_root) or
            os.path.normpath(proof_root) != proof_root or
            os.path.realpath(proof_root) != proof_root or
            not os.path.isdir(proof_root) or os.path.islink(proof_root)):
        return False
    if (not bounded_data(value, 4096) or not os.path.isabs(value) or
            os.path.normpath(value) != value or
            not value.startswith(proof_root + os.sep)):
        return False
    relative = value[len(proof_root) + 1:]
    parts = relative.split(os.sep)
    if (len(parts) != 2 or parts[1] != ".eci-accidental-mistake-override.claim" or
            re.fullmatch(r"[A-Za-z0-9_-]+", parts[0]) is None):
        return False
    session_dir = os.path.join(proof_root, parts[0])
    if os.path.islink(session_dir):
        return False
    probe = value
    while not os.path.lexists(probe) and probe != os.path.dirname(probe):
        probe = os.path.dirname(probe)
    return os.path.realpath(probe) == probe

def safe_temp_source(value, basename):
    if not (safe_lifecycle_path(value) and os.path.isabs(value) and
            os.path.basename(value) == basename):
        return False
    configured_tmpdir = assignments.get("TMPDIR", "")
    return (not configured_tmpdir or
            value.startswith(configured_tmpdir + os.sep))

AGGREGATE_STAGE_CONTROL_EXACT = {
    "eci-wait-repair-authorize", "eci_active", "goal_state", "eci_wait",
    "eci_user_owned_wait.md", "eci-permissive-mode", "eci-permissive-authorize",
    ".eci-permissive-mode", ".eci-permissive-authorize", "eci-required-critics.json",
    "eci-critic-identities.ledger", "eci-acceptance-anchor", "eci-acceptance-transaction",
    "eci-teardown-complete", "eci-baseline-binding", "baseline_head", "eci-commit-admitted",
    "eci-user-closed.ledger", "eci-aggregate-plan.json", "eci-aggregate-teardown-complete",
    "eci-accidental-mistake-override", ".eci-accidental-mistake-override",
    ".eci-accidental-mistake-override.claim", "ate_nested_eci_active",
    "ate_nested_eci_completion", "eci-blocker-report.md", "stop_timestamps", "stop_loop_state",
    "disengage.md", "user-closed.md", "proof.md", "instructions.md", "project-understanding.md",
    "high_level_log.md", "latest-status-report.md", "high_level_log.anchor",
}
AGGREGATE_STAGE_CONTROL_PREFIXES = (
    "eci-wait-repair-authorize.", "eci_active.", "goal_state.", "eci_wait.",
    "eci_user_owned_wait.md.", "eci-permissive-mode.", "eci-permissive-authorize.",
    ".eci-permissive-mode.", ".eci-permissive-authorize.", "eci-required-critics.",
    "eci-critic-identities.ledger.", "eci-acceptance-anchor.",
    "eci-acceptance-transaction.", "eci-teardown-complete.", "eci-prewrite-admitted.",
    "eci-baseline-binding.", "baseline_head.", "eci-commit-admitted.",
    "eci-user-closed.ledger.", "eci-aggregate-plan.json.",
    "eci-aggregate-teardown-complete.", "eci-aggregate.",
    "eci-accidental-mistake-override.", ".eci-accidental-mistake-override.",
    "ate_nested_eci_active.", "ate_nested_eci_completion.", "stop_loop_state.",
    "project-understanding.md.", "high_level_log.md.", "latest-status-report.md.",
    "high_level_log.anchor.", "high_level_log.md.tmp.",
)
AGGREGATE_STAGE_APPROVAL_BASENAMES = {
    ".git-reset-approved-once", ".git-worktree-approved-once", ".git-commit-approved-once",
}


def aggregate_stage_control_basename(value):
    return (value in AGGREGATE_STAGE_CONTROL_EXACT or
            value.startswith(AGGREGATE_STAGE_CONTROL_PREFIXES))


def aggregate_stage_approval_basename(value):
    return (value in AGGREGATE_STAGE_APPROVAL_BASENAMES or
            (value.startswith(".git-") and value.endswith("-approved-once")))


def safe_aggregate_stage_path(value):
    if (not bounded_data(value, 4096) or os.path.isabs(value) or value in {".", "..", "--"} or
            value.endswith("/") or value.startswith("./") or value.startswith("../") or
            "//" in value or "/./" in value or "/../" in value or
            any(char in value for char in "*?[]") or ":(" in value):
        return False
    components = value.split("/")
    return all(
        component and component not in {".", "..", ".git"} and
        not aggregate_stage_approval_basename(component) and
        not aggregate_stage_control_basename(component)
        for component in components
    )

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
    elif verb == "aggregate-migrate":
        accepted = len(tokens) == 3 and safe_temp_source(tokens[2], "eci-aggregate-plan.json.source")
    elif verb == "aggregate-stage":
        accepted = (not env_wrapped and not assignments and len(tokens) >= 5 and
                    re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,31}", tokens[2]) is not None and
                    tokens[3] == "--" and
                    all(safe_aggregate_stage_path(path) for path in tokens[4:]))
    elif verb == "aggregate-manifest-write":
        accepted = (len(tokens) == 4 and
                    re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,31}", tokens[2]) is not None and
                    safe_temp_source(tokens[3], "eci-required-critics.json.source"))
    elif verb == "aggregate-review":
        accepted = (len(tokens) == 4 and tokens[2] in {"prewrite", "final"} and
                    re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,31}", tokens[3]) is not None)
    elif verb == "aggregate-commit":
        accepted = (len(tokens) == 4 and
                    re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,31}", tokens[2]) is not None and
                    safe_temp_source(tokens[3], "eci-aggregate-commit-message.source"))
    elif verb == "aggregate-off":
        accepted = len(tokens) == 3 and safe_lifecycle_path(tokens[2])
    elif verb == "approve-commit":
        # Legacy compatibility spelling only. It cannot authorize a commit,
        # and it must not impose repository, command-form, or user-artifact
        # prerequisites on ordinary Git work.
        accepted = True
    elif verb == "maintain-planner":
        accepted = len(tokens) == 2 and os.path.basename(matched_root) == ".codex"
    elif verb == "repository-allow-status":
        accepted = len(tokens) == 2
    elif verb == "repository-allow-off":
        accepted = (len(tokens) == 3 and os.path.isabs(tokens[2]) and
                    os.path.normpath(tokens[2]) == tokens[2])
    elif verb == "repository-allow-on":
        accepted = (len(tokens) == 4 and os.path.isabs(tokens[2]) and
                    os.path.normpath(tokens[2]) == tokens[2] and
                    bounded_data(tokens[3]))
    elif verb == "accidental-override-cleanup":
        accepted = (len(tokens) == 4 and tokens[2] == "--authorized-by-user" and
                    os.path.basename(matched_root) == ".codex" and
                    canonical_proof_root_claim(tokens[3]))
    elif verb == "nested-enter":
        accepted = (len(tokens) in {4, 5} and
                    bool(re.fullmatch(r"[1-9][0-9]*", tokens[2])) and
                    bool(re.fullmatch(r"[1-9][0-9]*", tokens[3])) and
                    (len(tokens) == 4 or bool(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", tokens[4]))))
    elif verb in {"nested-accept", "nested-exit"}:
        accepted = len(tokens) == 2
    else:
        accepted = False
if accepted:
    raise SystemExit(0)

# Aggregate staging is a lifecycle mutation with a concrete repository and
# path-selection payload.  Unlike read-only help (whose malformed argv should
# reach the CLI), malformed aggregate-stage shapes must be rejected here so a
# wrapper, missing separator, or control-file operand cannot be mistaken for
# an admitted parent-owned staging route.  Keep this diagnostic specific; all
# other malformed lifecycle argv remains the CLI's responsibility.
if verb == "aggregate-stage":
    print("aggregate-stage provider arguments do not match the bounded repository -- relative-path route")
raise SystemExit(1)
PY
)"; then
    COORDINATOR_PEER_ECI_ROUTE_DETAIL=""
    COORDINATOR_PEER_ECI_ROUTE_MODE=lifecycle
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

# A lifecycle candidate is resolved by executable identity before generic
# shell checks. Help is read-only and reaches the CLI without a marker or
# coordinator role; other lifecycle verbs retain the active callback binding.
PLAN_PEER_ECI_ROUTE=false
if [ "$PLAN_CODEX_LIFECYCLE_ROUTE" = true ]; then
  if coordinator_peer_eci_route "$command"; then
    case "$COORDINATOR_PEER_ECI_ROUTE_MODE" in
      help)
        PLAN_PEER_ECI_ROUTE=true
        exit 0
        ;;
      lifecycle)
        if [ "${#syntax_eci_markers[@]}" -gt 0 ] && [ "$hook_is_subagent" != true ]; then
          PLAN_PEER_ECI_ROUTE=true
          validate_active_marker_binding
          exit 0
        fi
        ;;
    esac
  fi
  lifecycle_target_detail="${COORDINATOR_PEER_ECI_ROUTE_DETAIL:-}"
  case "$lifecycle_target_detail" in
    "target identity mismatch:"*)
      deny_eci "ECI_LIFECYCLE_TARGET_DENIED" "eci-lifecycle" \
        "ECI lifecycle target denied: ${lifecycle_target_detail}" \
        "use the eci-active executable that resolves to the current Codex target"
      ;;
    "provider session identity mismatch:"*|"active session identity mismatch:"*)
      deny_eci "ECI_LIFECYCLE_IDENTITY_DENIED" "eci-lifecycle" \
        "ECI lifecycle identity denied: ${lifecycle_target_detail}" \
        "use the callback's active Codex session identity"
      ;;
    "canonical lifecycle spelling mismatch:"*)
      deny_eci "ECI_LIFECYCLE_CANONICAL_PATH_DENIED" "eci-lifecycle" \
        "ECI lifecycle canonical path denied: ${lifecycle_target_detail}; predicate=canonical-lifecycle-spelling; target=canonical Codex/Kimi eci-active control binary" \
        "invoke the mutating lifecycle command through the literal \"\$HOME/.codex/bin/eci-active\" spelling"
      ;;
    "aggregate-stage provider arguments do not match"*)
      deny_eci "ECI_LIFECYCLE_ARGUMENTS_DENIED" "eci-lifecycle" \
        "ECI lifecycle provider arguments denied: ${lifecycle_target_detail}; target=canonical Codex/Kimi eci-active control binary; reason=aggregate-stage requires one repository selector, a literal -- separator, and one or more safe repository-relative paths" \
        "use the canonical Codex/Kimi eci-active control binary with aggregate-stage <repository> -- <relative-path>..."
      ;;
  esac
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
for candidate_root in (os.environ["CODEX_CONFIGURED_HOME"], os.path.join(home, ".kimi-code")):
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
    "ECI worker boundary denied coordinator-only temporary-directory setup: mktemp -d may be requested only by the ECI Supervisor through the bounded literal route; rejected command=$(eci_command_identity_subject "$command"); reason=temporary-directory creation is coordinator-owned" \
    "route mktemp -d setup through the ECI Supervisor using a literal home-scoped temporary-root or canonical non-system TMPDIR template"
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
for root in (
    os.environ["CODEX_CONFIGURED_HOME"],
    os.environ.get("KIMI_CODE_HOME") or os.path.join(home, ".kimi-code"),
):
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
    os.environ["CODEX_CONFIGURED_HOME"],
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

# The Kimi provider's no-argument installer is a canonical cross-provider
# maintenance entrypoint. Keep this narrower than the generic reviewed-script
# route: only literal bash/sh, the configured canonical Kimi root, and no
# installer arguments are admitted. Repair arguments remain on their existing
# hard-link route.
coordinator_peer_installer_route() {
  python3 - "$1" "${KIMI_CODE_HOME:-${HOME:-}/.kimi-code}" <<'PY'
import os
import shlex
import shutil
import sys

try:
    tokens = shlex.split(sys.argv[1], posix=True)
except ValueError:
    raise SystemExit(1)
if len(tokens) != 2 or tokens[0] not in {"bash", "sh"}:
    raise SystemExit(1)
shell_path = shutil.which(tokens[0])
trusted = {"/bin/bash", "/usr/bin/bash", "/usr/local/bin/bash",
           "/bin/sh", "/usr/bin/sh", "/usr/local/bin/sh"}
if shell_path not in trusted:
    raise SystemExit(1)
kimi_root = sys.argv[2]
if (not kimi_root or not os.path.isabs(kimi_root) or
        os.path.normpath(kimi_root) != kimi_root or
        not os.path.isdir(kimi_root) or os.path.islink(kimi_root) or
        os.path.realpath(kimi_root) != kimi_root):
    raise SystemExit(1)
expected = os.path.join(kimi_root, "hooks", "install-pre-commit-go-mod.sh")
if (tokens[1] != expected or not os.path.isfile(expected) or
        os.path.islink(expected) or os.path.realpath(expected) != expected or
        not os.access(expected, os.R_OK)):
    raise SystemExit(1)
raise SystemExit(0)
PY
}

# The shared Go hook installer mutates provider-owned Git hook state. Its
# canonical identity remains protected when its arguments are malformed.
if [ "${#syntax_eci_markers[@]}" -gt 0 ] && [ "$hook_is_subagent" != true ]; then
  go_hook_installer_identity="$(coordinator_go_hook_installer_identity "$command" 2>/dev/null || true)"
  if [ -n "$go_hook_installer_identity" ] &&
    ! coordinator_script_route "$command" &&
    ! coordinator_peer_installer_route "$command"; then
    deny_eci "ECI_COORDINATOR_ROUTE_ARGUMENTS_DENIED" "coordinator-go-hook-installer" \
      "ECI coordinator Go hook installer route denied malformed arguments: ${go_hook_installer_identity}; ${COORDINATOR_SCRIPT_ROUTE_DETAIL}" \
      "invoke the canonical installer without arguments, or use --repair-hardlink with the other canonical Codex/Kimi repository root"
  fi
fi

# Shell spelling is not a permission boundary.  A worker may use ordinary
# substitution, expansion, redirection, or compound syntax; later checks own
# only a resolved broad destructive, cross-scope, or live-control effect.

# Direct commits use the normal Git target resolver below.  Do not add a
# command-spelling fast path here: `-C`, an absolute Git path, environment
# setup, or harmless shell sequencing does not itself make a commit unsafe.

read_only=false
coordinator_inspection_allowed=false
worker_read_only_pipeline_admitted=false
if [ "${#syntax_eci_markers[@]}" -gt 0 ]; then
  if [ "$coordinator_compound_mutation" = true ]; then
    if coordinator_compound_inspection_route "$command"; then
      # The compound adapter has already validated every segment and the
      # status-0 path validated marker ownership. Return now so the ordinary
      # read-only scanner cannot repeat the same Python/process-heavy checks.
      exit 0
    else
      deny_eci "ECI_COMPOUND_MUTATION_DENIED" "compound-mutation" \
        "ECI coordinator compound mutation denied: ${COORDINATOR_CLEANUP_ROUTE_DETAIL:-command=$(eci_command_identity_subject "$command")}; predicate=compound-mutation; reason=the mutation segment is not admitted by the bounded ownership route" \
        "split the read-only inspection from the mutation, or use the bounded coordinator cleanup route for the exact generated target"
    fi
  elif coordinator_readlink_route "$command" || coordinator_compound_inspection_route "$command" || coordinator_inspection_route "$command"; then
    read_only=true
    coordinator_inspection_allowed=true
  elif [ "$(classify_eci_command "$command" 2>/dev/null || true)" = read-only ]; then
    read_only=true
  elif [ "$hook_is_subagent" = true ] && [ "$WORKER_PROJECT_INSPECTION_ALLOWED" = true ]; then
    # The worker Git route has already validated the current-repository
    # read-only capability and ownership boundary.  Preserve that decision
    # through the legacy adapter instead of reapplying its old command-name
    # allowlist.
    read_only=true
  fi
elif command_is_read_only "$command"; then
  read_only=true
fi

# Read-only classification must not create a lifecycle grammar boundary.
# Resolved cross-provider targets and callback identity mismatches have already
# been handled by the peer route.  A malformed invocation, extra option, or
# normal environment assignment is CLI-owned and remains transparent here.

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
      "ECI worker boundary denied Supervisor-owned review-gate invocation: ${review_gate_identity}; segment=1; argv_index=0; byte_offset=0; token=eci-review-gate.sh; path=n/a; predicate=worker-lifecycle-control; reason=the canonical review gate records acceptance evidence and cannot be invoked directly by a worker" \
      "send this phase/session request to the Supervisor; after range verification, the published Job owner starts dependent review and the Supervisor retains acceptance"
  elif [[ "$review_gate_identity" != *" valid_shape=true "* ]]; then
    deny_eci "ECI_REVIEW_GATE_ARGUMENTS_DENIED" "review-gate" \
      "ECI coordinator review-gate route denied malformed arguments: ${review_gate_identity}; segment=1; argv_index=0; byte_offset=0; token=eci-review-gate.sh; path=n/a; predicate=review-gate-arguments; reason=the recognized canonical review gate requires exactly one supported phase and one bounded session id" \
      "correct the reported malformed_token and invoke the canonical review gate with <commit|final|off|prewrite> <session-id>"
  fi
fi

if [ "$hook_is_subagent" = true ] && [ -n "$worker_protected_control_identity" ]; then
  case "$worker_protected_control_identity" in
    *"install-pre-commit-go-mod.sh"*)
      deny_eci "ECI_WORKER_HOOK_INSTALLER_DENIED" "worker-hook-installer" \
        "ECI worker boundary denied Supervisor-owned hook installer: ${worker_protected_control_identity}; predicate=worker-hook-installer; reason=the canonical installer mutates provider hook state and is Supervisor-owned" \
        "route this exact canonical installer invocation to the Supervisor"
      ;;
    *)
      deny_eci "ECI_WORKER_CONTROL_SCRIPT_DENIED" "worker-control-script" \
        "ECI worker boundary denied Supervisor-owned lifecycle/control script: ${worker_protected_control_identity}; reason=the canonical control script owns ECI admission or stop state" \
        "route this exact canonical control-script request to the Supervisor"
      ;;
  esac
fi

if [ "$hook_is_subagent" = true ] && [ "${#syntax_eci_markers[@]}" -gt 0 ]; then
  enforce_foreign_active_marker_mutation_boundary
  direct_ledger_static_control_target_pass "$command" || true
  [ "$DIRECT_LEDGER_FALLBACK_DECISION" != deny ] || direct_ledger_emit_fallback_denial
fi

# `env`/`printenv` option grammar is an execution-envelope diagnostic.  An
# ordinary command may use a shell wrapper or an option the recognizer does
# not understand; that alone is not evidence of a wrong target. The
# effect-based interpreter-context check above has already handled an
# existing context path attached to an existing script. Concrete downstream
# routes still inspect Git/proof/control effects.
if [ "${#syntax_eci_markers[@]}" -gt 0 ] && [ "$hook_is_subagent" = true ] &&
  [ "$ECI_ENVIRONMENT_BOUNDARY_CHECKED" != true ]; then
  enforce_environment_command_boundary
fi

# Compound syntax, executable spelling, and Git context options are diagnostic
# context, not a permission boundary. Resolve only a concrete repository effect
# before the transparent/planner fast paths, so a known foreign mutation or a
# broad reset is still caught regardless of ordinary shell spelling.
git_mutation_approved=false
command_state=unknown
if [ "${#syntax_eci_markers[@]}" -gt 0 ]; then
  maybe_enforce_git_mutation_gate
fi

# A worker may use only the explicit owner-scoped repository declaration
# lifecycle route. Check the full callback command before the read-only return
# and bind any env session override to the callback session.
if [ "$hook_is_subagent" = true ] && command_invokes_eci_binary "$hook_original_command"; then
  if worker_repository_allow_lifecycle_route "$hook_original_command"; then
    validate_active_marker_binding
    exit 0
  fi
  eci_binary_subject="$(eci_command_identity_subject "$hook_original_command")"
  eci_binary_detail="$(rejected_command_detail "$hook_original_command" 2>/dev/null || printf 'segment=<unclassified>')"
  deny_eci "ECI_CONTROL_OWNER_REQUIRED" "eci-control" \
    "ECI worker boundary denied direct invocation of a canonical Codex/Kimi eci-active binary: ${eci_binary_detail}; literal command=${eci_binary_subject} targets Supervisor-owned lifecycle/control state" \
    "use only the exact owner-scoped repository-allow route for this active session; send other lifecycle/control requests to the Supervisor"
fi

# A typed, literal read-only command never mutates ECI or repository state.
# Resolve the bounded marker set once so malformed/duplicate active markers
# still fail closed, enforce the worker Git boundary, then return before Git
# mutation parsing, activity bookkeeping, or other non-hot-path work. This
# keeps every ordinary inspection callback local and sub-second by design.
if [ "$coordinator_static_pipeline_candidate" != true ] &&
  ! eci_cleanup_command_shape "$command" && [ "$read_only" = true ] && {
  if [ "$hook_is_subagent" = true ]; then
    [ "$WORKER_PROJECT_INSPECTION_ALLOWED" = true ]
  else
    [ "$coordinator_inspection_allowed" = true ] || read_only_fast_safe "$command"
  fi
}; then
  # Read-only-looking utilities can still write through a visible redirect or
  # a concrete control target. Resolve those effects before the early return;
  # a pathname or incomplete read classification is not itself a mutation.
  if [ "$hook_is_subagent" = true ] && [ "${#syntax_eci_markers[@]}" -gt 0 ]; then
    enforce_foreign_active_marker_mutation_boundary
    direct_ledger_static_control_target_pass "$command" || true
    [ "$DIRECT_LEDGER_FALLBACK_DECISION" != deny ] || direct_ledger_emit_fallback_denial
  fi
  mapfile -t read_only_markers < <(active_eci_markers_for_cwd "$cwd" "$session_id")
  for read_only_marker in "${read_only_markers[@]}"; do
    if ! codex_eci_marker_path_owner_is_valid "$read_only_marker"; then
      deny_marker_boundary "$read_only_marker" "$(codex_canonical_cwd "$cwd")" "$session_id"
    fi
  done
  [ "${#read_only_markers[@]}" -le 1 ] ||
    deny_eci "ECI_MARKER_OWNERSHIP_AMBIGUOUS" "commit-boundary" "ECI commit boundary denied: multiple active markers are unsafe; resolve ownership before committing." "resolve marker ownership so exactly one validated owner remains, then retry the commit"
  enforce_proof_path_escape_boundary "$command"
  exit 0
fi

coordinator_static_pipeline_route() {
  [ "$hook_is_subagent" != true ] || return 1
  local segments segment detail review_detail git_detail protected_detail classification
  segments="$(eci_static_pipeline_segments "$1" 2>/dev/null)" || return 1
  [ -n "$segments" ] || return 1
  while IFS= read -r segment; do
    [ -n "$segment" ] || return 1
    eci_finite_literal_argv "$segment" || return 1
    detail="$(dynamic_indirection_detail "$segment" 2>/dev/null || true)"
    if [ -n "$detail" ]; then
      # This parser cannot resolve the value, so it has no concrete target to
      # protect. Fall through to normal execution and the later resolved-
      # target checks rather than denying punctuation or expansion by itself.
      return 1
    fi
    review_detail="$(review_gate_command_identity "$segment" 2>/dev/null || true)"
    if [ -n "$review_detail" ] ||
       command_invokes_eci_binary "$segment" || command_invokes_eci_control_mutation "$segment"; then
      deny_eci "ECI_COORDINATOR_CONTROL_PIPELINE_DENIED" "coordinator-static-pipeline" \
        "ECI Supervisor static pipeline denied Supervisor-owned lifecycle/control segment=$(eci_command_identity_subject "$segment"); review_gate=${review_detail:-none}; reason=control and acceptance operations require their direct Supervisor route" \
        "send the reported lifecycle/control request to the Supervisor for its direct entrypoint, outside a pipeline"
    fi
    git_detail="$(protected_pipeline_git_detail "$segment" 2>/dev/null || true)"
    if [ -n "$git_detail" ]; then
      deny_eci "ECI_BROAD_DESTRUCTIVE_DENIED" "git-mutation" \
        "ECI Git mutation has a broad destructive effect: ${git_detail}" \
        "name the intended repository-relative paths, or use a non-destructive targeted Git action"
    fi
    protected_detail="$(protected_literal_operation_detail "$segment" false 2>/dev/null || true)"
    case "$protected_detail" in
      class=broad\ *)
        deny_eci "ECI_BROAD_DESTRUCTIVE_DENIED" "coordinator-static-pipeline" \
          "ECI coordinator static pipeline denied broad destructive segment=$(eci_command_identity_subject "$segment"): ${protected_detail}" \
          "narrow the target to the exact task-owned file or subdirectory, then retry the intended operation"
        ;;
    esac
  done <<< "$segments"
  return 0
}

# A finite pipeline is not denied merely because it contains a pipe or a
# coordinator source operation. Each visible component above still receives
# concrete control/proof/Git/broad-target checks.
if [ "${#syntax_eci_markers[@]}" -gt 0 ] &&
  [ "$coordinator_static_pipeline_candidate" = true ]; then
  validate_active_marker_binding
  if coordinator_static_pipeline_route "$command"; then
    exit 0
  fi
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
        "ECI worker ownership gate denied a protected Git operation: ${protected_literal_detail}; predicate=worker-git-ownership; reason=protected Git operations route through the Supervisor while ECI is active; ordinary assigned Producer commits use the separate repository/effect checks" \
        "route the reported protected Git operation request to the Supervisor; ordinary assigned Producer commits use the resolved repository/effect checks"
      ;;
    class=worker-hook-mode\ *)
      # The compiled planner normally reports this ownership-sensitive source
      # mode repair directly.  When the planner is unavailable or being
      # rebuilt, preserve the same resolved target through the legacy route
      # instead of allowing the worker's plain-argv fast path to skip it.
      worker_hook_mode_detail="${protected_literal_detail/#class=worker-hook-mode /class=source }"
      worker_hook_mode_detail="${worker_hook_mode_detail/kind=protected-hook-mode-mutation/kind=coordinator-source-write}"
      deny_eci "ECI_CONTROL_OWNER_REQUIRED" "worker-control" \
        "ECI worker ownership gate denied Supervisor-owned pre-commit hook mode repair: ${worker_hook_mode_detail}; predicate=hook-mode-repair; reason=the canonical provider hook mode is Supervisor-controlled while ECI is active" \
        "route the exact pre-commit hook mode repair request to the Supervisor"
      ;;
    class=coordinator-peer-hook-mode\ *)
      # A coordinator may repair its own Codex hook mode through the bounded
      # route above, but a direct mutation of the configured Kimi peer belongs
      # to that provider's control path.  Keep the resolved target in the
      # diagnostic so this is an accidental-wrong-peer denial, not a generic
      # shell or permission-form restriction.
      deny_eci "ECI_COORDINATOR_PEER_CONTROL_DENIED" "coordinator-peer-control" \
        "ECI Supervisor peer-control boundary denied protected Kimi hook mode mutation: ${protected_literal_detail}; predicate=peer-hook-mode-repair; reason=the resolved target belongs to the configured Kimi provider control path and provider-hook operations route through the Supervisor" \
        "route the Kimi hook-mode repair request to the Supervisor"
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

# Keep the control-metadata route narrow even when the planner is unavailable
# or returns a generic admission.  This is intentionally limited to the
# explicit ECI_EMIT_* assignment family; ordinary shell commands remain
# effect-transparent.
if [ "${#syntax_eci_markers[@]}" -gt 0 ] && [ "$hook_is_subagent" != true ]; then
  coordinator_enforce_manifest_script_route "$command"
fi

# Current-source compilation can be temporarily unavailable while the planner
# is being edited. After the existing marker, proof-path, cleanup, and concrete
# destructive-target checks above have run, ordinary coordinator work remains
# transparent. Lifecycle commands never use this exit; their existing adapter
# retains canonical target, role, session, cwd, and marker validation.
if [ "$CODEX_PLAN_TRANSPARENT_FALLBACK" = true ] &&
  [ "$hook_is_subagent" != true ] &&
  [ "$COMPOUND_SEGMENT_VALIDATION" != true ] &&
  [ "$coordinator_compound_mutation" != true ] &&
  ! command_invokes_eci_lifecycle "$command"; then
  coordinator_enforce_script_target "$command"
  if [ "${#syntax_eci_markers[@]}" -gt 0 ]; then
    validate_active_marker_binding
    enforce_foreign_active_marker_mutation_boundary
  fi
  # Preserve the concrete proof-ownership check while leaving ordinary
  # planner-unavailable commands transparent.
  enforce_proof_path_escape_boundary "$command"
  exit 0
fi

ECI_LITERAL_ADMITTED=false
if [ "${#syntax_eci_markers[@]}" -gt 0 ] && [ "$plan_status" -eq 0 ] &&
  [ "$COMPOUND_SEGMENT_VALIDATION" != true ] &&
  ! coordinator_script_batch_shape "$command" &&
  ! shell_script_launcher_shape "$command" &&
  ! opaque_launcher_shape "$command" &&
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

# Git push is governed by the coordinator's behavioral instruction (only on
# an explicit user request), not by an unconditional PreToolUse denial.
# Preserve the early concrete-effect result when the command reached it.
: "${git_mutation_approved:=false}"
: "${command_state:=unknown}"
review_markers=()

if [ "$hook_is_subagent" = true ] && command_invokes_eci_off "$command"; then
  deny_eci "ECI_LIFECYCLE_OWNER_REQUIRED" "eci-off" "Only the Supervisor may disengage ECI with eci-active off. Workers report completion or blockers to the Supervisor while ECI remains active." "send completion or blocker reports to the Supervisor"
fi

if [ "$hook_is_subagent" = true ] && command_invokes_eci_wait_or_resume "$command"; then
  deny_eci "ECI_LIFECYCLE_OWNER_REQUIRED" "eci-lifecycle" "Only the Supervisor may mutate ECI lifecycle state with eci-active wait/resume/ledger-append/nested-enter/nested-accept/nested-exit/manifest-write/aggregate-stage. Workers report the BRP result to the Supervisor." "send the requested lifecycle transition to the Supervisor"
fi

if [ "$hook_is_subagent" = true ] && command_invokes_eci_acceptance_mutation "$command"; then
  deny_eci "ECI_WORKER_ACCEPTANCE_DENIED" "worker-acceptance" "ECI worker boundary denied a Git history, explicit reference, or patch-application mutation. Assigned Producers may make ordinary scoped checkpoint commits through the resolved repository/effect checks; amendments, other history changes, explicit reference mutations, and git apply remain denied. Send protected acceptance/history/reference/patch requests to the Supervisor." "send this protected history, reference, or patch request to the Supervisor; the reported mutation remains denied"
fi

if [ "$hook_is_subagent" = true ] && command_invokes_subagent_coordinator_only "$command"; then
  deny_eci "ECI_WORKER_COORDINATOR_ROUTE_DENIED" "coordinator-route" "ECI worker boundary denied coordinator-only temporary-directory setup: mktemp -d may be requested only by the ECI Supervisor through the bounded literal route." "route mktemp -d setup through the ECI Supervisor using a literal home-scoped temporary-root or canonical non-system TMPDIR template"
fi

# A deferred, capability-free planner result for one direct env-prefixed Git
# fsck writer needs the worker launcher diagnostic before generic wrapper
# admission. The compiled planner owns the complete env/argv grammar and
# publishes this route only after final classification.
worker_env_git_fsck_lost_found_shape() {
  [ "$hook_is_subagent" = true ] || return 1
  [ "${#syntax_eci_markers[@]}" -gt 0 ] || return 1
  [ "${plan_role:-coordinator}" = worker ] || return 1
  [ "${plan_marker_state:-inactive}" = active ] || return 1
  [ "${plan_status:-1}" -eq 3 ] || return 1
  jq -e '
    type == "object" and
    .decision == "defer" and
    .deferred_route == "worker-env-git-fsck-lost-found" and
    (.diagnostic == null) and
    ((.capabilities // []) | length == 0)
  ' <<<"${plan_output:-}" >/dev/null 2>&1 || return 1
}

if worker_env_git_fsck_lost_found_shape; then
  launcher_identity="$(eci_command_identity_subject "$command")"
  launcher_detail="$(rejected_command_detail "$command" 2>/dev/null || printf 'segment=<unclassified>')"
  deny_eci "ECI_WORKER_LAUNCHER_DENIED" "worker-launcher" \
    "ECI worker boundary denied transparent env Git fsck writer: command=${launcher_identity}; detail=${launcher_detail}; predicate=worker-env-git-fsck-lost-found; reason=the exact --lost-found option writes dangling objects under the repository metadata" \
    "remove --lost-found or route the repository-metadata write request to the Supervisor"
fi

worker_reviewed_script_admitted=false
worker_reviewed_script_route_detail=""
if [ "$hook_is_subagent" = true ] && [ "${#syntax_eci_markers[@]}" -gt 0 ] &&
  worker_reviewed_script_route "$command"; then
  worker_reviewed_script_admitted=true
else
  worker_reviewed_script_route_detail="${COORDINATOR_SCRIPT_ROUTE_DETAIL:-}"
fi

if [ "$hook_is_subagent" = true ] && [ "${#syntax_eci_markers[@]}" -gt 0 ] &&
  { [[ "$worker_reviewed_script_route_detail" == *"reason=script path or a parent must not be a symlink"* ]] ||
    [[ "$worker_reviewed_script_route_detail" == *"reason=script must be below the callback provider root"* ]]; }; then
  if ! worker_script_target_additional_repository_allowed "$worker_reviewed_script_route_detail"; then
    deny_eci "ECI_WORKER_SCRIPT_TARGET_DENIED" "worker-script-target" \
      "ECI worker boundary denied a script target outside the assigned canonical provider root: ${worker_reviewed_script_route_detail}; predicate=worker-script-target; reason=the resolved script target is outside the worker's assigned root and has no owner-declared additional-repository allowance" \
      "for an owned dependency repository, first run \"$HOME/.codex/bin/eci-active\" repository-allow-on <canonical-repository> \"<reason>\"; otherwise route the foreign script execution to the current Job owner"
  fi
fi

if [ "$hook_is_subagent" = true ] && [ "${#syntax_eci_markers[@]}" -gt 0 ] &&
  [[ "$worker_reviewed_script_route_detail" == *"script=hooks/install-pre-commit-go-mod.sh canonical_target="* ]] &&
  [[ "$worker_reviewed_script_route_detail" == *"reason=installer route is coordinator-only"* ]]; then
  deny_eci "ECI_WORKER_HOOK_INSTALLER_DENIED" "worker-hook-installer" \
    "ECI worker boundary denied Supervisor-owned hook installer: ${worker_reviewed_script_route_detail}; predicate=worker-hook-installer; reason=the canonical installer mutates provider hook state and is Supervisor-owned" \
    "route this exact canonical installer invocation to the Supervisor"
fi

# An unfamiliar worker launcher, interpreter spelling, or direct utility is
# not a concrete accidental mistake.  Let ordinary work proceed; the
# target-aware routes below still stop a resolved broad destructive operation,
# cross-scope write, or live control-state mutation.

# Peer-provider reads are advisory context.  A path alone has no accidental
# effect; concrete writes and destructive targets are handled by their own
# resolved-target checks.

# Keep the concrete script-target boundary active even when the compiled
# planner has already granted a finite literal argv.  Planner admission is
# not a substitute for resolving an interpreter's script operand: an
# arbitrary out-of-root script remains a wrong-target execution, while the
# helper above preserves the explicit canonical Kimi peer route.
if [ "$hook_is_subagent" != true ] && [ "${#syntax_eci_markers[@]}" -gt 0 ]; then
  coordinator_enforce_script_target "$command"
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
    if [ "$command_state" = unknown ] && coordinator_stop_gate_syntax_route "$command"; then
      [ "${#review_markers[@]}" -eq 0 ] || validate_active_marker_binding
      command_state=read-only
      read_only=true
    fi
    if [ "$command_state" = unknown ] && [ "$PLAN_REVIEWED_SCRIPT_TRACE_ROUTE" = true ]; then
      if coordinator_script_route "$command"; then
        validate_active_marker_binding
        command_state=read-only
        read_only=true
      fi
    fi
    if [ "$command_state" = unknown ] && [ "$PLAN_REVIEWED_SCRIPT_COMPOUND_ROUTE" = true ]; then
      if coordinator_script_route "$command"; then
        validate_active_marker_binding
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
    # A failed structural-script parse is not itself a harmful effect.  Keep
    # ordinary in-root scripts, harmless extra arguments, and missing scripts
    # transparent; concrete control/installer routes and resolved out-of-root
    # targets are handled by their named checks below.
    if [ "$command_state" = unknown ]; then
      coordinator_enforce_script_target "$command"
    fi
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
    fi
    # Cleanup is a coordinator escape hatch for generated artifacts only.
    # Keep it in the unknown-command dispatcher so mv/rm are classified before
    # ordinary unknown work falls through to normal execution.
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
  # Lifecycle argument grammar belongs to eci-active itself.  The hook has
  # already rejected a resolved wrong provider target and a callback-identity
  # mismatch above; a harmless extra argv or ordinary environment assignment
  # is neither.  Let the CLI report that normal invocation error instead of
  # turning incomplete parser knowledge into a coordinator-facing denial.
  maybe_enforce_git_mutation_gate
  # Legacy accidental-override records are not an admission route.  Their
  # absence, malformed bytes, or an interrupted historical claim is advisory
  # state only; ordinary coordination falls through to the concrete target
  # checks below without a repair ceremony.
  # Unknown worker syntax is ordinary work until a concrete target-aware
  # route identifies a destructive, wrong-scope, or control-state effect.
  # Parser coverage and role metadata are diagnostic context, never an
  # allowlist that blocks the command by itself.
else
  maybe_enforce_git_mutation_gate
fi

if [ "$read_only" != true ]; then
  codex_note_touched_repo "$session_id" "$cwd" "$cwd" || true
fi

if [ "$hook_is_subagent" != true ] && [ "$read_only" != true ]; then
  codex_mark_activity "$session_id" "$cwd" shell || true
fi
