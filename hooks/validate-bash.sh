#!/usr/bin/env bash
# PreToolUse hook: validate Bash commands before execution.

set -euo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HOOK_DIR/lib/codex-proof-state.sh"

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

if codex_hook_is_subagent_context "$input" && command_invokes_eci_off "$command"; then
  deny 'Only the main thread/orchestrator may disengage ECI with eci-active off. Subagents must report completion or blockers to the orchestrator while ECI remains active.'
fi

read_only=false
if command_is_read_only "$command"; then
  read_only=true
fi

if ! codex_hook_is_subagent_context "$input" && [ "$read_only" != true ]; then
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
