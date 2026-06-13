#!/usr/bin/env bash
# PreToolUse hook: validate Bash commands before execution.

set -euo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HOOK_DIR/lib/codex-proof-state.sh"
. "$HOOK_DIR/lib/codex-tmp.sh"
codex_init_tmp || true
codex_install_fail_open_trap validate-bash

input=$(cat)
session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)
command=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)

deny() {
  jq -n --arg reason "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
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

command_invokes_eci_off() {
  printf '%s' "$1" |
    tr "\"';&|()" '       ' |
    awk '
      {
        for (i = 1; i < NF; i++) {
          token = $i
          sub(/^.*\//, "", token)
          if (token == "eci-active" && $(i + 1) == "off") {
            found = 1
          }
        }
      }
      END { exit found ? 0 : 1 }
    '
}

git_reset_dirs() {
  python3 - "$command" "${cwd:-$PWD}" <<'PY'
import os
import shlex
import sys

command = sys.argv[1]
cwd = sys.argv[2] or os.getcwd()

try:
    lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    tokens = list(lexer)
except ValueError:
    sys.exit(2)

operators = {";", "&", "&&", "|", "||", "(", ")"}


def basename(token):
    return os.path.basename(token)


def is_assignment(token):
    name, sep, _ = token.partition("=")
    return bool(sep) and bool(name) and name.replace("_", "A").isalnum() and not name[0].isdigit()


def resolve(path, base):
    path = os.path.expanduser(path)
    if os.path.isabs(path):
        return os.path.normpath(path)
    return os.path.normpath(os.path.join(base, path))


def skip_env(segment, index):
    index += 1
    while index < len(segment):
        token = segment[index]
        if is_assignment(token):
            index += 1
            continue
        if token in {"-i", "-0"} or token.startswith("-u"):
            index += 1
            continue
        if token in {"-C", "-S"} and index + 1 < len(segment):
            index += 2
            continue
        if token.startswith("-"):
            index += 1
            continue
        break
    return index


def command_index(segment):
    index = 0
    while index < len(segment) and is_assignment(segment[index]):
        index += 1
    while index < len(segment):
        name = basename(segment[index])
        if name in {"command", "builtin", "exec"}:
            index += 1
            continue
        if name == "env":
            index = skip_env(segment, index)
            continue
        if name in {"sudo", "doas"}:
            index += 1
            while index < len(segment) and segment[index].startswith("-"):
                index += 1
            continue
        return index
    return index


def git_reset_dir(segment, index, base_dir):
    git_dir = base_dir
    arg_takes_value = {
        "-c",
        "--config-env",
        "--exec-path",
        "--git-dir",
        "--namespace",
        "--super-prefix",
        "--work-tree",
    }
    arg_takes_value_eq = {arg + "=" for arg in arg_takes_value if arg.startswith("--")}
    index += 1
    while index < len(segment):
        token = segment[index]
        if token == "-C" and index + 1 < len(segment):
            git_dir = resolve(segment[index + 1], base_dir)
            index += 2
            continue
        if token.startswith("-C") and len(token) > 2:
            git_dir = resolve(token[2:], base_dir)
            index += 1
            continue
        if token in arg_takes_value and index + 1 < len(segment):
            index += 2
            continue
        if any(token.startswith(prefix) for prefix in arg_takes_value_eq):
            index += 1
            continue
        if token.startswith("-"):
            index += 1
            continue
        if token == "reset":
            return git_dir
        return None
    return None


segments = []
start = 0
for index, token in enumerate(tokens + [";"]):
    if token in operators:
        if start < index:
            segments.append(tokens[start:index])
        start = index + 1

current_dir = cwd
reset_dirs = []
for segment in segments:
    index = command_index(segment)
    if index >= len(segment):
        continue
    name = basename(segment[index])
    if name == "cd" and index + 1 < len(segment):
        current_dir = resolve(segment[index + 1], current_dir)
        continue
    if name in {"bash", "sh"} and "-c" in segment[index + 1 :]:
        script_index = segment.index("-c", index + 1) + 1
        if script_index < len(segment) and "git reset" in segment[script_index]:
            print("!shell-c")
        continue
    if name != "git":
        continue
    reset_dir = git_reset_dir(segment, index, current_dir)
    if reset_dir:
        reset_dirs.append(reset_dir)

for reset_dir in reset_dirs:
    print(reset_dir)
PY
}

enforce_git_reset_gate() {
  local reset_dirs=()
  local reset_dir repo_root marker marker_command

  case "$command" in
    *reset*) ;;
    *) return 0 ;;
  esac

  if ! command -v python3 >/dev/null 2>&1; then
    deny 'git reset denied: python3 is required to validate the one-time reset marker.'
  fi

  if ! mapfile -t reset_dirs < <(git_reset_dirs); then
    deny 'git reset denied: could not parse the shell command safely.'
  fi

  [ "${#reset_dirs[@]}" -gt 0 ] || return 0

  if [ "${#reset_dirs[@]}" -gt 1 ]; then
    deny 'git reset denied: run only one git reset per Bash tool call.'
  fi

  reset_dir="${reset_dirs[0]}"
  if [ "$reset_dir" = "!shell-c" ]; then
    deny 'git reset denied: run git reset directly, not through bash -c or sh -c.'
  fi

  if ! repo_root="$(git -C "$reset_dir" rev-parse --show-toplevel 2>/dev/null)"; then
    deny "git reset denied: could not identify the target repo for '$reset_dir'."
  fi

  marker="$repo_root/.git-reset-approved-once"
  if [ ! -f "$marker" ]; then
    deny "git reset denied: create $marker with date, reason, and command: $command after inspecting uncommitted changes."
  fi

  marker_command="$(awk '/^command: / { print substr($0, 10); found = 1; exit } END { if (!found) exit 1 }' "$marker" 2>/dev/null || true)"
  if [ -z "$marker_command" ]; then
    deny "git reset denied: $marker must contain a command: <exact Bash command> line."
  fi

  if [ "$marker_command" != "$command" ]; then
    deny "git reset denied: $marker command does not match this Bash command."
  fi

  if ! rm -f -- "$marker"; then
    deny "git reset denied: could not consume $marker."
  fi
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
    awk '
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
    awk '
      function base_name(token) {
        sub(/^.*\//, "", token)
        return token
      }
      function allowed_simple(cmd) {
        return cmd ~ /^(cat|cut|date|dirname|du|egrep|fgrep|file|grep|head|jq|ls|nl|printf|pwd|readlink|realpath|rg|sed|sort|stat|tail|test|tr|uniq|wc|which|\[)$/
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
          subcmd = parts[idx + 1]
          if (subcmd !~ /^(branch|describe|diff|grep|log|ls-files|remote|rev-parse|show|status)$/) {
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
          for (i = idx + 1; i <= part_count; i++) {
            if (parts[i] ~ /^-.*i/) {
              bad = 1
            }
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

if [ -n "$command" ] && [ "$(detect_git_push 2>/dev/null)" = "1" ]; then
  deny 'git push is blocked. No task in this environment requires git push, and no task is blocked by its absence. If you believe push is needed, that judgment is wrong — commit locally and proceed.'
fi

hook_is_subagent=false
if codex_hook_is_subagent_context "$input"; then
  hook_is_subagent=true
fi

read_only=false
if command_is_read_only "$command"; then
  read_only=true
fi

if [ "$hook_is_subagent" = true ] && command_invokes_eci_off "$command"; then
  deny 'Only the main thread/orchestrator may disengage ECI with eci-active off. Subagents must report completion or blockers to the orchestrator while ECI remains active.'
fi

enforce_git_reset_gate

if [ -n "$command" ] && [ "$(detect_uncapped_make 2>/dev/null)" = "1" ]; then
  deny 'make must be run with a finite memory cap, for example: systemd-run --scope -p MemoryMax=1G make ...'
fi

if [ "$read_only" != true ]; then
  codex_note_touched_repo "$session_id" "$cwd" "$cwd" || true
fi

if [ "$hook_is_subagent" != true ] && [ "$read_only" != true ]; then
  codex_mark_activity "$session_id" "$cwd" shell || true
fi

case "$input" in
  *"go test"*) ;;
  *) exit 0 ;;
esac

if ! printf '%s' "$command" | grep -qE '(^|[^A-Za-z0-9_-])go[[:space:]]+test\b'; then
  exit 0
fi

if printf '%s' "$command" | grep -qE '\-count[= ]1\b'; then
  deny 'Do not pass -count=1 to go test; it defeats the test cache. Re-run without -count=1.'
fi

if ! printf '%s' "$command" | grep -qE '([12&]?>>?|\|[[:space:]]*tee\b)'; then
  deny 'go test output must be captured to a file to avoid overrunning context. Example: go test ./... > /tmp/go-test.log 2>&1; then inspect the log with tail/head/grep.'
fi
