#!/usr/bin/env bash
# UserPromptSubmit hook: maintain per-prompt state without injecting context.

set -euo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HOOK_DIR/lib/codex-proof-state.sh"

input=$(cat)
session_id=$(printf '%s' "$input" | jq -r 'if (.session_id? | type) == "string" then .session_id else "" end' 2>/dev/null || true)
cwd=$(printf '%s' "$input" | jq -r 'if (.cwd? | type) == "string" then .cwd else "" end' 2>/dev/null || true)
prompt=$(printf '%s' "$input" | jq -r 'if (.prompt? | type) == "string" then .prompt else "" end' 2>/dev/null || true)
root="$(codex_proof_root)"

write_side_stop_marker() {
  local dir="$1"
  mkdir -p "$dir"
  {
    printf 'command: /side\n'
    printf 'parent_session_id: %s\n' "$session_id"
    [ -n "$cwd" ] && printf 'cwd: %s\n' "$cwd"
    date -u '+created_utc: %Y-%m-%dT%H:%M:%SZ'
  } >"$dir/side_stop"
}

prompt_has_governance_action() {
  printf '%s\n' "$prompt" |
    grep -Eiq '(^|[^[:alnum:]_])(update|edit|change|modify|fix|enforce|ensure|ensures|ensured|ensuring|add|write|rewrite|tighten|improve|implement|create|remove|delete|refactor|review|audit|route|routes|routed|routing|make|makes|made|making|switch(ed|es|ing)?)([^[:alnum:]_]|$)'
}

prompt_has_governance_target() {
  local codex_config_path codex_hook_path eci_task_routing_target skill_mode_target text
  codex_config_path='(\.codex/(hooks\.json|config\.toml)|(codex|CODEX_HOME|governance|global guidance|global instructions)[[:space:]/_-]+(hooks\.json|config\.toml)|(hooks\.json|config\.toml)[[:space:]/_-]+(codex|CODEX_HOME|governance|global guidance|global instructions))'
  codex_hook_path='hooks/((prompt-task-reminder|stop-gate|session-snapshot|validate-(apply-patch|bash|edit-write)|eci-active-gate|ate-orchestrator-gate|edit-bash-pre-reviewer|system-prompt-reviewer|check-audit-sync)\.sh|security-reminder\.py|stop-checklist\.md)'
  eci_task_routing_target='((non-trivial|nontrivial)[[:space:]-]+(tasks?|requests?)[^.?!]*(ECI|explore-critique-implement)|(ECI|explore-critique-implement)[^.?!]*(non-trivial|nontrivial)[[:space:]-]+tasks?)'
  skill_mode_target='(switch(ed|es|ing)?[^.?!]*(caveman|ponytail)|(caveman|ponytail)[[:space:]-]+mode|skill[[:space:]-]+mode)'
  text=$(printf '%s\n' "$prompt")

  printf '%s\n' "$text" |
    grep -Eiq "(^|[^[:alnum:]_])(CODEX\.md|AGENTS\.md|SKILL\.md|$codex_hook_path|$codex_config_path|$eci_task_routing_target|$skill_mode_target|UserPromptSubmit|Stop[- ]hook)([^[:alnum:]_]|$)" &&
    return 0

  printf '%s\n' "$text" |
    grep -Eiq '(^|[^[:alnum:]_])hook behavior[[:space:]]*[.?!]?[[:space:]]*$' &&
    return 0

  printf '%s\n' "$text" |
    grep -Eiq '(^|[^[:alnum:]_])(governance|global guidance|system prompt|subagent prompt|skill routing|task routing|agent routing|prompt-task|prompt reminder|prompt hook|hook gate|stop[- ]gate(\.sh)?|stop[- ]checklist|routing guidance|routing hook|teardown rule)([^[:alnum:]_]|$)'
}

emit_governance_reminder() {
  jq -n --arg ctx 'Governance/prompt/hook/routing reminder matched a deterministic action+target heuristic. Before acting, check whether the user request is trivial or non-trivial; use direct work for truly mechanical safe changes, explore-critique-implement for non-trivial work, agent-teams-execution for very long/heavy/multi-workstream work, harness-tuning for prompt/global guidance edits, and testing-discipline for hook tests. Tag factual claims T1-T5. This UserPromptSubmit reminder is deterministic and session-safe, creates no marker state, and is not an LLM classifier; any LLM first-tool admission review is separate PreToolUse behavior configured through CODEX_EDIT_PRE_REVIEWER, with LLM_EDIT_PRE_REVIEWER and CLAUDE_EDIT_PRE_REVIEWER accepted only as lower-precedence compatibility aliases when earlier variables are unset.' '{
    hookSpecificOutput: {
      hookEventName: "UserPromptSubmit",
      additionalContext: $ctx
    }
  }'
}

if codex_valid_session_id "$session_id"; then
  reviewer_dir="$root/reviewer/$session_id"
  mkdir -p "$reviewer_dir"
  head=$(git -C "$HOME/.codex" rev-parse HEAD 2>/dev/null || true)
  if [ -n "$head" ]; then
    printf '%s\n' "$head" >"$reviewer_dir/prompt_head"
  fi
  rm -f "$reviewer_dir/bypass" "$root/pre-reviewer/$session_id/bypass"

  if printf '%s\n' "$prompt" | grep -Eq '^[[:space:]]*/side([[:space:]]|$)'; then
    write_side_stop_marker "$root/side-stop/sessions/$session_id"
    if [ -n "$cwd" ]; then
      side_dir="$(codex_ensure_cwd_state_dir side-stop "$cwd" 2>/dev/null || true)"
      [ -n "$side_dir" ] && write_side_stop_marker "$side_dir"
    fi
  fi

fi

if prompt_has_governance_action && prompt_has_governance_target; then
  emit_governance_reminder
fi
