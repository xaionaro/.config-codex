#!/usr/bin/env bash

# Role-neutral tri-state recognizer for reserved environment commands.  It
# reports only argv shape and registry membership; caller-owned gates decide
# whether the command otherwise belongs to an ordinary or protected route.
environment_command_detail() {
  local direct_command="${1:-}" direct_name direct_fast=true
  local -a direct_words=()

  # The overwhelmingly common environment query is a direct, literal
  # `printenv NAME...` with a small bounded set of registered names.  Keep
  # this path entirely in Bash: it avoids starting Python/shlex for a query
  # whose grammar is already expressible as one argv check.  Anything that
  # is not provably this exact shape falls through to the complete recognizer
  # below, preserving its diagnostics and wrapper handling.
  read -r -a direct_words <<<"$direct_command"
  if [ "${direct_words[0]:-}" = printenv ] &&
     [ "${#direct_words[@]}" -ge 2 ] && [ "${#direct_words[@]}" -le 17 ]; then
    local -A direct_seen=()
    for direct_name in "${direct_words[@]:1}"; do
      if [[ ! "$direct_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        direct_fast=false
        break
      fi
      case "$direct_name" in
        HOME|PWD|PATH|CODEX_HOME|KIMI_CODE_HOME|SESSION_ID|CODEX_ROLE|CODEX_SESSION_ID|KIMI_SESSION_ID|CODEX_VALIDATE_CWD|KIMI_VALIDATE_CWD|CODEX_VALIDATE_SESSION_ID|KIMI_VALIDATE_SESSION_ID|CODEX_CONFIGURED_HOME|KIMI_CONFIGURED_HOME|CODEX_COMMAND_PATH|KIMI_COMMAND_PATH|CODEX_STOP_GATE_ROOT|KIMI_STOP_GATE_ROOT|TMPDIR|CODEX_PROOF_ROOT|KIMI_PROOF_ROOT|CODEX_PROOF_ROOT_CANONICAL|CODEX_PROOF_ROOT_CONFIGURED|CODEX_PROOF_ROOT_STABLE_ALIAS|KIMI_PROOF_ROOT_CANONICAL|KIMI_PROOF_ROOT_CONFIGURED|KIMI_PROOF_ROOT_STABLE_ALIAS|CODEX_APPROVED_REPO_ROOT_1|CODEX_APPROVED_REPO_ROOT_2|CODEX_APPROVED_REPO_ROOT_3|KIMI_APPROVED_REPO_ROOT_1|KIMI_APPROVED_REPO_ROOT_2|KIMI_APPROVED_REPO_ROOT_3|CODEX_HIGH_LEVEL_LOG_PATH|CODEX_HIGH_LEVEL_LOG_PATH_ALIAS|KIMI_HIGH_LEVEL_LOG_PATH|KIMI_HIGH_LEVEL_LOG_PATH_ALIAS)
          ;;
        *)
          direct_fast=false
          break
          ;;
      esac
      if [[ -n "${direct_seen[$direct_name]+set}" ]]; then
        direct_fast=false
        break
      fi
      direct_seen["$direct_name"]=1
    done
    if [ "$direct_fast" = true ]; then
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        ALLOW printenv 1 0 printenv direct-registered-query
      return 0
    fi
  fi

  python3 - "$1" <<'PY'
import os
import re
import shlex
import sys

PUBLIC_ENV_NAMES = {
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
INTERPRETER_CONTEXT_NAMES = {
    "BASH_ENV", "BASHOPTS", "CDPATH", "ENV", "GEM_HOME", "GEM_PATH",
    "IFS", "LD_LIBRARY_PATH", "LD_PRELOAD", "NODE_OPTIONS", "NODE_PATH",
    "PATH", "PERL5LIB", "PERL5OPT", "PYTHONHOME", "PYTHONPATH",
    "PYTHONSTARTUP", "RUBYLIB", "RUBYOPT", "SHELLOPTS", "ZDOTDIR",
}
IDENTIFIER = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
ASSIGNMENT = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)=(.*)", re.S)
OPERATORS = {
    ";", "&", "&&", "|", "||", "(", ")", ">", ">>", ">|", ">&",
    "<", "<<", "<<<", "<&",
}


def shown(value):
    return value.encode("unicode_escape").decode("ascii")


def denied(code, segment, index, token, reason):
    return ("DENY", code, str(segment), str(index), shown(token), reason)


def inspect(values, segment, base=0, depth=0):
    if not values or depth > 8:
        return None
    name = os.path.basename(values[0])
    if name == "printenv":
        names = values[1:]
        if not names:
            return denied(
                "ECI_ENVIRONMENT_ENUMERATION_DENIED",
                segment,
                base,
                "printenv",
                "no-names",
            )
        if len(names) > 16:
            return denied(
                "ECI_ENVIRONMENT_ENUMERATION_DENIED",
                segment,
                base,
                "printenv",
                "too-many-names",
            )
        seen = set()
        for offset, candidate in enumerate(names, 1):
            index = base + offset
            if candidate.startswith("-"):
                return denied(
                    "ECI_ENVIRONMENT_OPTION_DENIED",
                    segment,
                    index,
                    candidate,
                    "unsupported-option",
                )
            if IDENTIFIER.fullmatch(candidate) is None:
                return denied(
                    "ECI_ENVIRONMENT_ENUMERATION_DENIED",
                    segment,
                    index,
                    candidate,
                    "malformed-name",
                )
            if candidate in seen:
                return denied(
                    "ECI_ENVIRONMENT_ENUMERATION_DENIED",
                    segment,
                    index,
                    candidate,
                    "duplicate-name",
                )
            seen.add(candidate)
            if candidate not in PUBLIC_ENV_NAMES:
                return denied(
                    "ECI_ENVIRONMENT_NAME_DENIED",
                    segment,
                    index,
                    candidate,
                    "unregistered-name",
                )
        return (
            "ALLOW",
            "printenv",
            str(segment),
            str(base),
            "printenv",
            "registered-query",
        )
    if name != "env":
        return None

    index = 1
    options_done = False
    while index < len(values) and not options_done:
        token = values[index]
        absolute_index = base + index
        if token == "--":
            index += 1
            options_done = True
        elif token in {"-i", "--ignore-environment"}:
            index += 1
        elif token in {"-S", "--split-string"} or token.startswith(
            "--split-string="
        ):
            return denied(
                "ECI_ENVIRONMENT_OPTION_DENIED",
                segment,
                absolute_index,
                token,
                "split-string",
            )
        elif token in {"-u", "--unset", "-C", "--chdir"}:
            if index + 1 >= len(values):
                return denied(
                    "ECI_ENVIRONMENT_OPTION_DENIED",
                    segment,
                    absolute_index,
                    token,
                    "missing-option-argument",
                )
            argument = values[index + 1]
            if token in {"-u", "--unset"} and IDENTIFIER.fullmatch(argument) is None:
                return denied(
                    "ECI_ENVIRONMENT_OPTION_DENIED",
                    segment,
                    absolute_index,
                    token,
                    "malformed-option-argument",
                )
            index += 2
        elif token.startswith("--unset="):
            argument = token.split("=", 1)[1]
            if IDENTIFIER.fullmatch(argument) is None:
                return denied(
                    "ECI_ENVIRONMENT_OPTION_DENIED",
                    segment,
                    absolute_index,
                    token,
                    "malformed-option-argument",
                )
            index += 1
        elif token.startswith("--chdir="):
            if not token.split("=", 1)[1]:
                return denied(
                    "ECI_ENVIRONMENT_OPTION_DENIED",
                    segment,
                    absolute_index,
                    token,
                    "missing-option-argument",
                )
            index += 1
        elif token.startswith("-"):
            return denied(
                "ECI_ENVIRONMENT_OPTION_DENIED",
                segment,
                absolute_index,
                token,
                "unsupported-option",
            )
        else:
            options_done = True

    while index < len(values):
        match = ASSIGNMENT.fullmatch(values[index])
        if match is None:
            break
        assignment_name = match.group(1)
        absolute_index = base + index
        if assignment_name.startswith("GIT_"):
            return denied(
                "ECI_ENVIRONMENT_CONTEXT_DENIED",
                segment,
                absolute_index,
                assignment_name,
                "repository-context",
            )
        if assignment_name in INTERPRETER_CONTEXT_NAMES:
            return denied(
                "ECI_ENVIRONMENT_CONTEXT_DENIED",
                segment,
                absolute_index,
                assignment_name,
                "interpreter-context",
            )
        index += 1
    if index >= len(values):
        return denied(
            "ECI_ENVIRONMENT_ENUMERATION_DENIED",
            segment,
            base,
            "env",
            "no-child",
        )
    nested = inspect(values[index:], segment, base + index, depth + 1)
    if nested is not None:
        return nested
    return ("WRAPPER", "env", str(segment), str(base), "env", "finite-child")


try:
    lexer = shlex.shlex(sys.argv[1], posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    tokens = list(lexer)
except ValueError:
    raise SystemExit(1)

segments = []
current = []
for token in tokens + [";"]:
    if token in OPERATORS:
        if current:
            segments.append(current)
        current = []
    else:
        current.append(token)
result = None
for segment_index, values in enumerate(segments, 1):
    outcome = inspect(values, segment_index)
    if outcome is None:
        continue
    if outcome[0] == "DENY":
        print("\t".join(outcome))
        raise SystemExit(0)
    result = outcome
if result is None:
    raise SystemExit(1)
if (
    result[0] == "ALLOW"
    and result[1] == "printenv"
    and result[2] == "1"
    and result[3] == "0"
    and len(segments) == 1
):
    result = result[:-1] + ("direct-registered-query",)
print("\t".join(result))
PY
}

enforce_environment_command_boundary() {
  local detail state code segment argv_index token reason_key
  local reason remediation subject
  detail="$(environment_command_detail "$command" 2>/dev/null || true)"
  ECI_ENVIRONMENT_BOUNDARY_CHECKED=true
  ECI_ENVIRONMENT_COMMAND_STATE=""
  ECI_ENVIRONMENT_COMMAND_CODE=""
  ECI_ENVIRONMENT_COMMAND_SEGMENT=""
  ECI_ENVIRONMENT_COMMAND_ARGV_INDEX=""
  ECI_ENVIRONMENT_COMMAND_REASON=""
  [ -n "$detail" ] || return 0
  IFS=$'\t' read -r state code segment argv_index token reason_key <<<"$detail"
  ECI_ENVIRONMENT_COMMAND_STATE="$state"
  ECI_ENVIRONMENT_COMMAND_CODE="$code"
  ECI_ENVIRONMENT_COMMAND_SEGMENT="$segment"
  ECI_ENVIRONMENT_COMMAND_ARGV_INDEX="$argv_index"
  ECI_ENVIRONMENT_COMMAND_REASON="$reason_key"
  [ "$state" = DENY ] || return 0
  case "$reason_key" in
    no-child) reason="environment enumeration denied because env has no remaining child argv" ;;
    no-names) reason="environment enumeration denied because printenv has no queried names" ;;
    too-many-names) reason="environment enumeration denied because printenv exceeds the 16-name query bound" ;;
    malformed-name) reason="environment enumeration denied because the reported query token is not an identifier" ;;
    duplicate-name) reason="environment enumeration denied because the reported query name is duplicated" ;;
    unregistered-name) reason="environment query name is not registered; name=$token; index=$argv_index; status=unregistered" ;;
    split-string) reason="environment option denied because split-string reparses a dynamic argv payload" ;;
    missing-option-argument) reason="environment option denied because the reported option is missing its required argument" ;;
    malformed-option-argument) reason="environment option denied because the reported option argument is not a valid identifier or path" ;;
    unsupported-option) reason="environment option denied because the reported option is unsupported by the finite env/printenv grammar" ;;
    interpreter-context) reason="environment context denied because assignment name=$token activates registered interpreter or executable lookup context" ;;
    repository-context) reason="environment context denied because assignment name=$token activates registered repository lookup or execution context" ;;
    *) reason="environment command denied because the recognizer returned unknown status=$reason_key" ;;
  esac
  case "$code" in
    ECI_ENVIRONMENT_NAME_DENIED) remediation="query one to sixteen unique identifiers from PUBLIC_ENV_NAMES, or remove the reported name" ;;
    ECI_ENVIRONMENT_OPTION_DENIED) remediation="remove the reported option or supply its required literal argument using the finite env option grammar" ;;
    ECI_ENVIRONMENT_CONTEXT_DENIED) remediation="remove the reported context assignment and invoke the child with ordinary non-context assignments only" ;;
    *) remediation="for printenv, name one to sixteen registered identifiers; for env, supply one finite literal child argv" ;;
  esac
  subject="session=$(eci_diagnostic_value "${session_id:-<missing>}")"\
",cwd=$(eci_diagnostic_value "${cwd:-<missing>}")"\
",segment=$segment,token=$(eci_diagnostic_value "$token"),argv_index=$argv_index"
  deny "$(eci_diagnostic_reason "$code" "PreToolUse" "environment-boundary" "$subject" "$reason" "$remediation")"
}
