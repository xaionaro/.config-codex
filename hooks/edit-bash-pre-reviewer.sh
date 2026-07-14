#!/usr/bin/env bash
# PreToolUse admission reviewer for first tool call in a user turn.

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HOOK_DIR/lib/codex-proof-state.sh"
. "$HOOK_DIR/lib/codex-tmp.sh"
. "$HOOK_DIR/lib/pre-reviewer-turn-state.sh"
. "$HOOK_DIR/lib/reviewer-backend.sh"
. "$HOOK_DIR/lib/reviewer-call.sh"
. "$HOOK_DIR/lib/reviewer-redact.sh"
codex_init_tmp || true

input=$(cat)
session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)
tool_name=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || true)
turn_id_json="$(codex_hook_turn_id_json "$input")"
codex_valid_session_id "$session_id" || exit 0

case "$tool_name" in
  Bash|apply_patch|Edit|Write|MultiEdit|NotebookEdit) ;;
  *) exit 0 ;;
esac

[ -n "$turn_id_json" ] || exit 0

if codex_hook_is_subagent_context "$input"; then
  exit 0
fi

root="$(codex_proof_root)"
state_dir="$root/pre-reviewer/$session_id"
stop_state_dir="$root/reviewer/$session_id"
codex_ensure_private_pre_reviewer_state_dir "$state_dir" || exit 0

is_touch_bypass_command() {
  local command_text="$1"
  local bypass_file="$2"

  case "$command_text" in
    "touch $bypass_file"|"touch '$bypass_file'"|"touch \"$bypass_file\""|\
    "touch -- $bypass_file"|"touch -- '$bypass_file'"|"touch -- \"$bypass_file\"") return 0 ;;
    *) return 1 ;;
  esac
}

if [ "$tool_name" = "Bash" ]; then
  command_text=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
  is_touch_bypass_command "$command_text" "$state_dir/bypass" && exit 0
  if is_touch_bypass_command "$command_text" "$stop_state_dir/bypass"; then
    mkdir -p "$stop_state_dir" 2>/dev/null || true
    exit 0
  fi
fi

[ -f "$state_dir/bypass" ] && exit 0

select_edit_pre_reviewer_env() {
  local env_name

  for env_name in CODEX_EDIT_PRE_REVIEWER LLM_EDIT_PRE_REVIEWER CLAUDE_EDIT_PRE_REVIEWER; do
    if [ -n "${!env_name:-}" ]; then
      printf '%s\n' "$env_name"
      return 0
    fi
  done
}

reviewer_env_name="$(select_edit_pre_reviewer_env)"
[ -n "$reviewer_env_name" ] || exit 0
if ! parse_reviewer_env "$reviewer_env_name"; then
  exit 0
fi
[ -n "$REVIEWER_BACKEND" ] || exit 0

claim_key="$(codex_turn_state_key "$turn_id_json" 2>/dev/null || true)"
[ -n "$claim_key" ] || exit 0
capture="$(codex_turn_capture_path "$state_dir" "$claim_key")"
claim="$(codex_turn_claim_path "$state_dir" "$claim_key")"
consumed_capture_tmp=""
validated_prompt_tmp=""
cleanup_present_turn() {
  codex_unlock_pre_reviewer_turn
  rm -f "${consumed_capture_tmp:-}" "${validated_prompt_tmp:-}" 2>/dev/null || true
}
trap cleanup_present_turn EXIT
trap 'cleanup_present_turn; exit 0' HUP INT TERM
codex_lock_pre_reviewer_turn "$state_dir" || exit 0
if [ -e "$claim" ] || [ -L "$claim" ]; then
  exit 0
fi
if [ ! -e "$capture" ] && [ ! -L "$capture" ]; then
  exit 0
fi
umask 077
consumed_capture_tmp="$(mktemp "$state_dir/.capture-turn-$claim_key.consumed.XXXXXX")" || exit 0
chmod 0600 "$consumed_capture_tmp" || exit 0
mv -f -- "$capture" "$consumed_capture_tmp" || exit 0
codex_private_regular_file "$consumed_capture_tmp" || exit 0
validated_prompt_tmp="$(mktemp "$state_dir/.capture-turn-$claim_key.prompt.XXXXXX")" || exit 0
if ! python3 "$HOOK_DIR/lib/turn_capture_validator.py" "$turn_id_json" \
    {CODEX_TURN_LOCK_FD}>&- \
    <"$consumed_capture_tmp" >"$validated_prompt_tmp"; then
  exit 0
fi
chmod 0600 "$validated_prompt_tmp" || exit 0
last_user_message="$(cat "$validated_prompt_tmp" 2>/dev/null)" || exit 0
if ! ( umask 077; set -C; : >"$claim" ) 2>/dev/null; then
  if mv -f -- "$consumed_capture_tmp" "$capture"; then
    consumed_capture_tmp=""
  fi
  exit 0
fi
codex_unlock_pre_reviewer_turn
rm -f -- "$consumed_capture_tmp" "$validated_prompt_tmp" 2>/dev/null || true
consumed_capture_tmp=""
validated_prompt_tmp=""
trap - EXIT HUP INT TERM
tool_input=$(printf '%s' "$input" | jq -c '.tool_input // {}' 2>/dev/null | redact_sensitive_text | head -c 4000)

sys_file=$(mktemp)
usr_file=$(mktemp)
schema_file=$(mktemp)
trap 'rm -f "$sys_file" "$usr_file" "$schema_file"' EXIT

cat >"$sys_file" <<'EOF'
Admission controller for a coding agent. The agent is about to invoke a tool on the first action of a new user turn. Decide whether the agent may proceed directly or should first load a matching skill / delegate.

Codex routing excerpt:
- Debugging, failures, unexpected behavior: use debugging skills.
- Go code: use go-coding-style.
- Python code: use python-coding-style.
- Tests: use testing-discipline.
- Prompt, skill, or CODEX.md edits: use harness-tuning.
- Medium uncertain coding task: use explore-critique-implement.
- Explicit subagent/delegation request: use standard subagent tools.

Rules:
- Trivial = file read, quick status, simple lookup, or typo-scale change.
- Non-trivial = logic, bugfix, tests, multi-file change, prompt/hook behavior, or uncertain implementation.
- Deny only when the next action should clearly be skill/delegation setup first.
- When in doubt, allow.

Output JSON only: {"verdict":"allow"|"deny","reason":"one sentence"}
EOF
printf 'LAST USER MESSAGE:\n%s\n\nTOOL ABOUT TO BE CALLED: %s\nTOOL INPUT: %s\n' "$last_user_message" "$tool_name" "$tool_input" >"$usr_file"
if [ -n "${CODEX_PRE_REVIEWER_DEBUG_BODY_PATH:-}" ]; then
  cp "$usr_file" "$CODEX_PRE_REVIEWER_DEBUG_BODY_PATH" 2>/dev/null || true
fi
cat >"$schema_file" <<'JSON'
{
  "type": "object",
  "required": ["verdict", "reason"],
  "additionalProperties": false,
  "properties": {
    "verdict": {"type": "string", "enum": ["allow", "deny"]},
    "reason": {"type": "string"}
  }
}
JSON

if [ -n "${CODEX_PRE_REVIEWER_FAKE_RESULT:-}" ]; then
  result=$(printf '%s' "$CODEX_PRE_REVIEWER_FAKE_RESULT" | reviewer_strip_fences)
else
  result=$(reviewer_call_chat "pre_reviewer" "$sys_file" "$usr_file" "$schema_file" "$CODEX_EDIT_PRE_REVIEWER_TIMEOUT" 2>/dev/null) || exit 0
fi

verdict=$(printf '%s' "$result" | jq -r '.verdict // empty' 2>/dev/null || true)
reason=$(printf '%s' "$result" | jq -r '.reason // empty' 2>/dev/null || true)

if [ "$verdict" = "deny" ]; then
  message=$(printf 'Pre-tool admission reviewer denied the first tool call of this turn.\n\nReason: %s\n\nLoad the matching skill or delegate before invoking %s directly.\n\nOverride: touch %s/bypass' "$reason" "$tool_name" "$state_dir")
  jq -n --arg reason "$message" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
fi
