#!/usr/bin/env bash
# PreToolUse admission reviewer for first tool call in a user turn.

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HOOK_DIR/lib/codex-proof-state.sh"
. "$HOOK_DIR/lib/codex-tmp.sh"
. "$HOOK_DIR/lib/reviewer-backend.sh"
. "$HOOK_DIR/lib/reviewer-call.sh"
. "$HOOK_DIR/lib/reviewer-redact.sh"
codex_init_tmp || true

input=$(cat)
session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)
tool_name=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || true)
codex_valid_session_id "$session_id" || exit 0

case "$tool_name" in
  Bash|apply_patch|Edit|Write|MultiEdit|NotebookEdit) ;;
  *) exit 0 ;;
esac

if codex_hook_is_subagent_context "$input"; then
  exit 0
fi

root="$(codex_proof_root)"
state_dir="$root/pre-reviewer/$session_id"
stop_state_dir="$root/reviewer/$session_id"
mkdir -p "$state_dir" 2>/dev/null || exit 0

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

find_transcript() {
  local path
  path=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null || true)
  if [ -n "$path" ] && [ -f "$path" ]; then
    printf '%s\n' "$path"
    return 0
  fi
  find "$HOME/.codex/sessions" -name "*${session_id}*.jsonl" -type f 2>/dev/null | head -n1
}

transcript=$(find_transcript || true)
[ -n "$transcript" ] && [ -f "$transcript" ] || exit 0

read -r last_user_index first_of_turn < <(jq -rs \
  --argjson gated '["Bash","apply_patch","Edit","Write","MultiEdit"]' \
  --arg synth_re "$SYNTHETIC_USER_TAG_RE" \
  '
  def response_item_type($e):
    $e.payload.type // $e.payload.item.type // "";
  def content_of($e):
    $e.message.content // $e.payload.message.content // $e.payload.item.content // $e.payload.content // "";
  def event_role($e):
    if $e.type == "user" then "user"
    elif $e.type == "assistant" then "assistant"
    elif $e.type == "response_item" then
      if response_item_type($e) == "function_call" then "assistant"
      elif response_item_type($e) == "function_call_output" then "tool_result"
      else ($e.payload.role // $e.payload.item.role // "") end
    elif $e.type == "message" then ($e.role // "")
    else "" end;
  def is_real_user($e):
    event_role($e) == "user"
    and ((content_of($e) | type) == "string")
    and (($e.isMeta // $e.message.isMeta // false) | not)
    and (($e.origin.kind // $e.message.origin.kind // "") == "")
    and ((content_of($e) | tostring | test($synth_re; "i")) | not);
  def assistant_tool_names($e):
    if $e.type == "response_item" and response_item_type($e) == "function_call" then
      [($e.payload.name // $e.payload.item.name // "")]
    else
      (content_of($e) as $c
      | if ($c | type) == "array" then
        [$c[] | if .type == "tool_use" then (.name // "")
          elif .type == "function_call" then (.name // "")
          else empty end]
      else [] end)
    end;
  def is_prior_gated_tool($name):
    (($gated | index($name)) != null) or
    ((($name // "") | ascii_downcase) as $n
      | ["functions.exec_command","exec_command","functions.apply_patch","functions.edit","functions.write","functions.multiedit"] | index($n) != null);
  . as $all
  | ([ $all | to_entries[] | select(is_real_user(.value)) | .key ] | last // -1) as $lts
  | if $lts < 0 then "\($lts) no"
    else
      ([ $all | to_entries[]
        | select(.key > $lts and event_role(.value) == "assistant")
        | assistant_tool_names(.value)[]
        | select(is_prior_gated_tool(.)) ] | length) as $prior
      | if $prior == 0 then "\($lts) yes" else "\($lts) no" end
    end
  ' "$transcript" 2>/dev/null)

[ "${first_of_turn:-no}" = "yes" ] || exit 0

claim="$state_dir/claim-$last_user_index"
( set -C; : >"$claim" ) 2>/dev/null || exit 0

last_user_message=$(jq -rs --arg synth_re "$SYNTHETIC_USER_TAG_RE" '
  def response_item_type($e):
    $e.payload.type // $e.payload.item.type // "";
  def content_of($e):
    $e.message.content // $e.payload.message.content // $e.payload.item.content // $e.payload.content // "";
  def event_role($e):
    if $e.type == "user" then "user"
    elif $e.type == "response_item" then
      if response_item_type($e) == "function_call" then "assistant"
      elif response_item_type($e) == "function_call_output" then "tool_result"
      else ($e.payload.role // $e.payload.item.role // "") end
    elif $e.type == "message" then ($e.role // "")
    else "" end;
  [.[] | select(event_role(.) == "user"
                and ((content_of(.) | type) == "string")
                and ((.isMeta // .message.isMeta // false) | not)
                and ((.origin.kind // .message.origin.kind // "") == "")
                and ((content_of(.) | tostring | test($synth_re; "i")) | not))
   | content_of(.)] | last // ""
' "$transcript" 2>/dev/null | redact_sensitive_text | head -c 4000)
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
