#!/usr/bin/env bash
# Stop hook: require a checklist pass before ending.

set -euo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HOOK_DIR/lib/codex-proof-state.sh"
. "$HOOK_DIR/lib/codex-tmp.sh"
codex_init_tmp || true
codex_install_fail_open_trap stop-gate

input=$(cat)
session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)
transcript_path=$(printf '%s' "$input" | jq -r 'if (.transcript_path? | type) == "string" then .transcript_path else "" end' 2>/dev/null || true)
stop_active=$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2>/dev/null || true)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)
[ -z "$cwd" ] && cwd="$PWD"
root="${CODEX_PROOF_ROOT:-$HOME/.cache/codex-proof}"
proof_dir="$root/$session_id"

json_continue() {
  jq -n '{continue: true}'
}

json_block() {
  local reason="$1"
  local timestamps now cutoff tmp recent_count

  if [ -n "${proof_dir:-}" ]; then
    mkdir -p "$proof_dir"
    timestamps="$proof_dir/stop_timestamps"
    now="$(date +%s)"
    cutoff=$((now - 300))
    tmp="$timestamps.tmp.$$"
    if [ -f "$timestamps" ]; then
      awk -v cutoff="$cutoff" '$1 >= cutoff' "$timestamps" >"$tmp"
    else
      : >"$tmp"
    fi
    printf '%s\n' "$now" >>"$tmp"
    recent_count="$(awk 'END { print NR + 0 }' "$tmp")"
    mv "$tmp" "$timestamps"

    if [ "$recent_count" -ge 5 ]; then
      reason="$reason LOOP DETECTED ($recent_count blocks in 5min). Recovery flow: read instructions or stop-checklist, identify failing step, stop again, do not retry same approach."
    fi
  fi

  jq -n --arg reason "$reason" '{decision: "block", reason: $reason}'
}

active_eci_marker_for_stop() {
  local marker side_stop parent_session_id is_subagent_context=false

  if codex_hook_is_subagent_context "$input"; then
    is_subagent_context=true
  fi

  if codex_valid_session_id "$session_id"; then
    if [ "$is_subagent_context" = true ]; then
      parent_session_id="$(codex_hook_parent_session_id "$input" 2>/dev/null || true)"
      [ "$session_id" = "$parent_session_id" ] && return 1
    fi

    marker="$root/$session_id/eci_active"
    [ -f "$marker" ] && { printf '%s\n' "$marker"; return 0; }

    [ "$is_subagent_context" = true ] && return 1

    side_stop=$(codex_existing_state_file side-stop side_stop "$session_id" "$cwd" 2>/dev/null || true)
    parent_session_id="$(codex_state_value "$side_stop" parent_session_id || true)"
    if codex_valid_session_id "$parent_session_id"; then
      marker="$root/$parent_session_id/eci_active"
      [ -f "$marker" ] && { printf '%s\n' "$marker"; return 0; }
    fi
  fi

  [ "$is_subagent_context" = true ] && return 1

  codex_legacy_eci_markers_for_cwd "$cwd" 2>/dev/null | head -n1
}

block_if_eci_active_for_stop() {
  local marker

  marker="$(active_eci_marker_for_stop || true)"
  [ -n "$marker" ] && [ -f "$marker" ] || return 1
  codex_valid_session_id "$session_id" && codex_note_state_session_id "$marker" "$session_id" || true
  json_block "ECI is active for this stop attempt via marker $marker. Never stop until the ECI task is complete. Continue the ECI task, update the session project-understanding ledger, or report a blocker requiring user input while ECI remains active. Disengage only with clean-pass or user-closed via ~/.codex/bin/eci-active off <disengage-report.md>."
  return 0
}

case "$session_id" in
  ""|*[!A-Za-z0-9_-]*) json_continue; exit 0 ;;
esac

if block_if_eci_active_for_stop; then
  exit 0
fi

if [ -z "$transcript_path" ]; then
  json_continue
  exit 0
fi

git_change_summary() {
  local repo="$1"
  local baseline="$2"
  local base status changed=false

  git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0

  if [ -s "$baseline" ]; then
    base=$(cat "$baseline" 2>/dev/null || true)
    if [ -n "$base" ] && git -C "$repo" cat-file -e "$base^{commit}" 2>/dev/null; then
      if ! git -C "$repo" diff --quiet "$base"..HEAD -- 2>/dev/null; then
        printf 'commits changed since baseline %s..HEAD\n' "$base"
        changed=true
      fi
    fi
  fi

  status=$(git -C "$repo" status --porcelain 2>/dev/null || true)
  if [ -n "$status" ]; then
    printf '%s\n' "$status"
    changed=true
  fi

  [ "$changed" = "true" ]
}

git_dirty_summary() {
  local repo="$1"
  local status

  git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0

  status=$(git -C "$repo" status --porcelain 2>/dev/null || true)
  if [ -n "$status" ]; then
    printf '%s\n' "$status"
    return 0
  fi

  return 1
}

git_head_summary() {
  local repo="$1"

  git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  git -C "$repo" log -1 --oneline 2>/dev/null || true
}

indent_text() {
  sed 's/^/  /'
}

touched_repo_change_summary() {
  local marker="$1"
  local repo base_status_sha status status_sha repo_wide path path_status found=false

  repo="$(codex_state_value "$marker" repo || true)"
  [ -n "$repo" ] || return 1
  git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1

  status="$(git -C "$repo" status --porcelain=v1 --untracked-files=normal 2>/dev/null || true)"
  [ -n "$status" ] || return 1

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    path_status="$(git -C "$repo" status --porcelain=v1 --untracked-files=normal -- "$path" 2>/dev/null || true)"
    [ -n "$path_status" ] || continue
    if [ "$found" = false ]; then
      printf '%s\n' "$repo"
      found=true
    fi
    printf '%s\n' "$path_status" | indent_text
  done < <(awk 'index($0, "path: ") == 1 { print substr($0, 7) }' "$marker" 2>/dev/null)
  [ "$found" = true ] && return 0

  repo_wide="$(codex_state_value "$marker" repo_wide || true)"
  [ "$repo_wide" = true ] || return 1

  base_status_sha="$(codex_state_value "$marker" status_sha || true)"
  status_sha="$(codex_hash_string "$status")"

  if [ -n "$status" ] && [ -n "$base_status_sha" ] && [ "$status_sha" != "$base_status_sha" ]; then
    printf '%s\n' "$repo"
    printf '%s\n' "$status" | indent_text
    return 0
  fi

  return 1
}

touched_repos_change_summary() {
  local session_id="$1"
  local dir marker found=false summary

  dir="$(codex_session_state_dir touched-repos "$session_id" 2>/dev/null || true)"
  [ -n "$dir" ] && [ -d "$dir" ] || return 1

  for marker in "$dir"/*; do
    [ -f "$marker" ] || continue
    summary="$(touched_repo_change_summary "$marker" || true)"
    [ -n "$summary" ] || continue
    printf '%s\n' "$summary"
    found=true
  done

  [ "$found" = "true" ]
}

format_gitleaks_findings() {
  local report="$1"

  jq -r '
    .[] |
    "\(.File // "<unknown>"):\((.StartLine // "?") | tostring) \(.RuleID // "unknown") \(.Description // "possible secret")"
  ' "$report" 2>/dev/null
}

run_gitleaks_command() {
  local report="$1"
  shift
  local out rc

  out=$("$@" 2>&1)
  rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
    *)
      printf '%s\n' "$out" >"${report}.err"
      return 2
      ;;
  esac
}

run_secret_scan() {
  local repo="$1"
  local baseline="$2"
  local proof_dir="$3"
  local report="$proof_dir/gitleaks-report.json"
  local findings="$proof_dir/gitleaks-findings.txt"
  local worktree_report="$proof_dir/gitleaks-worktree-report.json"
  local commit_report="$proof_dir/gitleaks-commit-report.json"
  local tmp_index base findings_count worktree_dirty commit_changed scan_rc errors=""
  local -a reports

  rm -f "$report" "$findings" "$worktree_report" "$commit_report" \
    "${worktree_report}.err" "${commit_report}.err"

  if ! command -v gitleaks >/dev/null 2>&1; then
    printf '%s\n' "gitleaks not found on PATH" >"$findings"
    return 2
  fi

  worktree_dirty=false
  if [ -n "$(git -C "$repo" status --porcelain 2>/dev/null || true)" ]; then
    worktree_dirty=true
  fi

  commit_changed=false
  if [ -s "$baseline" ]; then
    base=$(cat "$baseline" 2>/dev/null || true)
    if [ -n "$base" ] && git -C "$repo" cat-file -e "$base^{commit}" 2>/dev/null &&
      ! git -C "$repo" diff --quiet "$base"..HEAD -- 2>/dev/null; then
      commit_changed=true
    fi
  fi

  if [ "$worktree_dirty" = "true" ]; then
    tmp_index=$(mktemp "$proof_dir/gitleaks-index.XXXXXX")
    rm -f "$tmp_index"
    if GIT_INDEX_FILE="$tmp_index" git -C "$repo" read-tree HEAD >/dev/null 2>&1; then
      GIT_INDEX_FILE="$tmp_index" git -C "$repo" add -N -- . >/dev/null 2>&1 || true
      scan_rc=0
      GIT_INDEX_FILE="$tmp_index" run_gitleaks_command "$worktree_report" \
        gitleaks protect --source "$repo" --redact --no-banner --log-level error \
          --report-format json --report-path "$worktree_report" || scan_rc=$?
      case "$scan_rc" in
        0|1)
          [ -f "$worktree_report" ] || errors="$errors worktree"
          ;;
        *) errors="$errors worktree" ;;
      esac
    else
      printf '%s\n' "could not prepare temporary git index for worktree scan" >"${worktree_report}.err"
      errors="$errors worktree"
    fi
    rm -f "$tmp_index"
  fi

  if [ "$commit_changed" = "true" ]; then
    scan_rc=0
    run_gitleaks_command "$commit_report" \
      gitleaks detect --source "$repo" --log-opts "$base..HEAD" --redact --no-banner \
        --log-level error --report-format json --report-path "$commit_report" || scan_rc=$?
    case "$scan_rc" in
      0|1)
        [ -f "$commit_report" ] || errors="$errors commits"
        ;;
      *) errors="$errors commits" ;;
    esac
  fi

  reports=()
  [ -f "$worktree_report" ] && reports+=("$worktree_report")
  [ -f "$commit_report" ] && reports+=("$commit_report")
  if [ "${#reports[@]}" -gt 0 ]; then
    jq -s 'add' "${reports[@]}" >"$report" 2>/dev/null || cp "${reports[0]}" "$report"
  else
    printf '[]\n' >"$report"
  fi

  if [ -n "$errors" ]; then
    {
      printf '%s\n' "gitleaks failed for:$errors"
      [ -s "${worktree_report}.err" ] && cat "${worktree_report}.err"
      [ -s "${commit_report}.err" ] && cat "${commit_report}.err"
    } >"$findings"
    return 2
  fi

  findings_count=$(jq 'length' "$report" 2>/dev/null || printf '0')
  if [ "${findings_count:-0}" -gt 0 ]; then
    format_gitleaks_findings "$report" >"$findings"
    return 1
  fi

  rm -f "$findings" "$worktree_report" "$commit_report"
  return 0
}

canonical_existing_path() {
  local path="$1"
  local dir base canonical_dir

  if [ -d "$path" ]; then
    (cd "$path" 2>/dev/null && pwd -P) || printf '%s\n' "$path"
    return
  fi

  dir="$(dirname "$path")"
  base="$(basename "$path")"
  if [ -d "$dir" ]; then
    canonical_dir="$( (cd "$dir" 2>/dev/null && pwd -P) || printf '%s' "$dir" )"
    printf '%s/%s\n' "$canonical_dir" "$base"
  else
    printf '%s\n' "$path"
  fi
}

git_common_dir() {
  local repo="$1"
  local common top

  common="$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  if [ -n "$common" ]; then
    canonical_existing_path "$common"
    return
  fi

  common="$(git -C "$repo" rev-parse --git-common-dir 2>/dev/null || true)"
  top="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null || true)"
  case "$common" in
    /*) canonical_existing_path "$common" ;;
    *) canonical_existing_path "${top:-$repo}/$common" ;;
  esac
}

repo_identity() {
  local repo="$1"
  local top common

  if git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    top="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null || printf '%s\n' "$repo")"
    top="$(canonical_existing_path "$top")"
    common="$(git_common_dir "$repo")"
    printf 'git:%s:%s\n' "$top" "$common"
  else
    printf 'nogit:%s\n' "$(codex_canonical_cwd "$repo")"
  fi
}

activity_marker_summary() {
  local session_id="$1"
  local cwd="$2"
  local marker name found=""

  for name in shell edit subagent; do
    marker=$(codex_existing_state_file activity "$name" "$session_id" "$cwd" 2>/dev/null || true)
    [ -n "$marker" ] && found="$found $name"
  done

  printf '%s\n' "$found"
}

transcript_has_activity_since_last_user() {
  local transcript="$1"

  [ -n "$transcript" ] && [ -f "$transcript" ] || return 1
  jq -e -s '
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
      and ((content_of($e) | test("^[[:space:]]*<(hook_prompt|subagent_notification|turn_aborted)"; "i")) | not)
      and (($e.isMeta // $e.message.isMeta // false) | not);
    def call_records($e):
      if $e.type == "response_item" and response_item_type($e) == "function_call" then
        [{
          name: ($e.payload.name // $e.payload.item.name // ""),
          arguments: (($e.payload.arguments // $e.payload.item.arguments // "") | tostring)
        }]
      else
        (content_of($e) as $c
        | if ($c | type) == "array" then
          [$c[] | select(.type == "tool_use" or .type == "function_call")
            | {name: (.name // ""), arguments: ((.input // .arguments // "") | tostring)}]
        else [] end)
      end;
    def active_call($c):
      (($c.name // "") | test("(^|\\.)(apply_patch|Edit|Write|MultiEdit|spawn_agent|send_input|wait_agent|close_agent|resume_agent)$"))
      or
      (($c.name // "") == "multi_tool_use.parallel"
        and (($c.arguments // "") | test("functions\\.(apply_patch|spawn_agent|send_input|wait_agent|close_agent|resume_agent)")));
    . as $all
    | ([ $all | to_entries[] | select(is_real_user(.value)) | .key ] | last // -1) as $last_user
    | $last_user >= 0 and
      ([ $all | to_entries[]
        | select(.key > $last_user and event_role(.value) == "assistant")
        | call_records(.value)[]
        | select(active_call(.)) ] | length) > 0
  ' "$transcript" >/dev/null 2>&1
}

if codex_hook_is_subagent_context "$input"; then
  case "${CODEX_ROLE:-}" in
    lead|coordinator)
      json_continue
      exit 0
      ;;
  esac

  reminder="$proof_dir/subagent-commit-reminder.md"
  skip=$(codex_existing_state_file skip-stop skip_stop "$session_id" "$cwd" 2>/dev/null || true)
  if [ -n "$skip" ]; then
    rm -f "$reminder" 2>/dev/null || true
    json_continue
    exit 0
  fi

  subagent_change_summary="$(touched_repos_change_summary "$session_id" || true)"
  if [ -n "$subagent_change_summary" ]; then
    mkdir -p "$proof_dir"
    {
      cat <<EOF
# Subagent Commit Reminder

This subagent has dirty files in repos it modified.
Commit only owned completed dirty paths modified by this subagent. Do not commit unrelated dirty files.
If committing is unsafe, report the blocker and affected paths to the orchestrator.

Bypass when handoff with dirty work is intentional:
  CODEX_SESSION_ID=$session_id ~/.codex/bin/skip-stop on

Changed repos:
EOF
      printf '%s\n' "$subagent_change_summary" | indent_text
    } >"$reminder"
    json_block "This subagent has dirty files it modified. Read $reminder; commit only owned completed dirty paths, report the blocker, or bypass with CODEX_SESSION_ID=$session_id ~/.codex/bin/skip-stop on; then stop again."
    exit 0
  fi
  rm -f "$reminder" 2>/dev/null || true
  json_continue
  exit 0
fi

repo="${cwd:-$PWD}"
side_stop=$(codex_existing_state_file side-stop side_stop "$session_id" "$cwd" 2>/dev/null || true)

if codex_side_stop_is_active_for_session "$side_stop" "$session_id"; then
  json_continue
  exit 0
fi

proof="$proof_dir/proof.md"
instructions="$proof_dir/instructions.md"
baseline="$proof_dir/baseline_head"
skip=$(codex_existing_state_file skip-stop skip_stop "$session_id" "$cwd" 2>/dev/null || true)
eci_active="$root/$session_id/eci_active"
legacy_eci_active="$(codex_legacy_eci_markers_for_cwd "$cwd" 2>/dev/null | head -n1 || true)"
ate_active=$(codex_existing_state_file ate ate_active "$session_id" "$cwd" 2>/dev/null || true)
task_active=$(codex_existing_state_file active-task task_active "$session_id" "$cwd" 2>/dev/null || true)
activity_summary="$(activity_marker_summary "$session_id" "$cwd")"
change_summary="$(git_change_summary "$repo" "$baseline" || true)"
changed=false
[ -n "$change_summary" ] && changed=true
transcript_activity=false
if transcript_has_activity_since_last_user "$transcript_path"; then
  transcript_activity=true
fi
repo_is_git=false
if git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  repo_is_git=true
fi

mkdir -p "$proof_dir"

proof_recovery_text() {
  printf ' Legacy proof files are optional. Update or remove %s using %s; if that file is missing, read %s.' \
    "$proof" "$instructions" "$HOME/.codex/hooks/stop-checklist.md"
}

block_proof_validation() {
  json_block "$1$(proof_recovery_text)"
  exit 0
}

if [ -n "$eci_active" ] && [ -f "$eci_active" ]; then
  codex_note_state_session_id "$eci_active" "$session_id" || true
  json_block "ECI is active for this session. Never stop until the ECI task is complete. If work is not done, dispatch remaining work to subagents and use wait_agent; do not stop while they run. Continue the ECI task, update the session project-understanding ledger, or report a blocker requiring user input while ECI remains active. Disengage only with clean-pass or user-closed via ~/.codex/bin/eci-active off <disengage-report.md>."
  exit 0
fi

if [ -n "$legacy_eci_active" ] && [ -f "$legacy_eci_active" ]; then
  json_block "ECI is active for this workspace via legacy marker $legacy_eci_active. Never stop until the ECI task is complete. Continue the ECI task, update the session project-understanding ledger, or report a blocker requiring user input while ECI remains active. Disengage only with clean-pass or user-closed via ~/.codex/bin/eci-active off <disengage-report.md>."
  exit 0
fi

if [ -n "$skip" ] && [ -f "$skip" ] && [ -n "$(find "$skip" -mmin -60 -print 2>/dev/null)" ]; then
  json_continue
  exit 0
fi

if [ -n "$ate_active" ] && [ -f "$ate_active" ]; then
  ate_phase=$(codex_state_value "$ate_active" phase || true)
  case "$ate_phase" in
    awaiting_user|closed) ;;
    *)
      codex_note_state_session_id "$ate_active" "$session_id" || true
      json_block "ATE is active for this session. Continue the agent team task, update the session project-understanding ledger, report a real blocker, or close ATE before stopping."
      exit 0
      ;;
  esac
fi

# Early exit: if this session did no mutation work since the last user
# message and no persisted indicators exist, skip the stop gate regardless of
# pre-existing dirt from prior sessions.
if [ "$transcript_activity" != "true" ] &&
  [ ! -f "$proof" ] &&
  [ "$changed" != "true" ] &&
  [ -z "$task_active" ] &&
  [ -z "$activity_summary" ]; then
  json_continue
  exit 0
fi

reviewer_out=""
if reviewer_out=$(printf '%s' "$input" | "$HOOK_DIR/system-prompt-reviewer.sh"); then
  if [ -n "$reviewer_out" ] &&
    printf '%s' "$reviewer_out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
    printf '%s\n' "$reviewer_out"
    exit 0
  fi
fi

if [ -f "$proof" ]; then
  if codex_markdown_section_has_body "$proof" "ECI completion certificate"; then
    if ! codex_markdown_section_has_body "$proof" "Stop checklist walkthrough" || ! codex_markdown_section_has_body "$proof" "Incomplete compliance"; then
      block_proof_validation "ECI completion proof must include non-empty Stop checklist walkthrough and Incomplete compliance sections."
    fi

    marker_error="$(codex_eci_terminal_verdict_error "ECI completion proof" "$proof")"
    if [ -n "$marker_error" ]; then
      block_proof_validation "$marker_error"
    fi
  elif ! grep -qiE 'fast.exit|fast exit' "$proof"; then
    missing=""
    grep -qi '^##[[:space:]]*Summary' "$proof" || missing="$missing Summary"
    grep -qi '^##[[:space:]]*Verification' "$proof" || missing="$missing Verification"
    grep -qi '^##[[:space:]]*Requirements' "$proof" || missing="$missing Requirements"
    grep -qi '^##[[:space:]]*Root Cause' "$proof" || missing="$missing Root-Cause"
    grep -qi '^##[[:space:]]*Claim Inventory' "$proof" || missing="$missing Claim-Inventory"
    grep -qi '^##[[:space:]]*Pre-Mortem' "$proof" || missing="$missing Pre-Mortem"
    grep -qi '^##[[:space:]]*Adversarial Critique' "$proof" || missing="$missing Adversarial-Critique"
    grep -qi '^##[[:space:]]*Rule-Compliance Self-Audit' "$proof" || missing="$missing Rule-Compliance-Self-Audit"
    grep -qi '^##[[:space:]]*Gaps' "$proof" || missing="$missing Gaps"

    if [ -n "$missing" ]; then
      block_proof_validation "Proof file is missing required sections:$missing."
    fi

    audit_section=$(awk '
      /^##[[:space:]]*Rule-Compliance Self-Audit/ { in_audit=1; next }
      in_audit && /^##[[:space:]]/ { in_audit=0 }
      in_audit { print }
    ' "$proof")
    audit_hashes=$(mktemp "${TMPDIR:-/tmp}/codex-audit-hashes.XXXXXX")
    audit_errs=$(printf '%s\n' "$audit_section" | awk -v hashfile="$audit_hashes" '
      function trim(s) {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
        return s
      }
      function check_sources(raw, label,   body, n, i, item, nonempty, has_codex) {
        body = raw
        sub(/^[^:]*:[[:space:]]*/, "", body)
        n = split(body, parts, ",")
        nonempty = 0
        has_codex = 0
        for (i = 1; i <= n; i++) {
          item = trim(parts[i])
          if (item == "") {
            print label ": empty audit source"
          } else {
            nonempty++
          }
          if (item ~ /CODEX\.md/) has_codex = 1
        }
        if (nonempty < 3) print label ": need at least three non-empty sources"
        if (!has_codex) print label ": must include CODEX.md among the sources"
      }
      function finish_violation() {
        if (violation_count == 0) return
        if (!has_corr) print "violation #" violation_count ": no correction marker"
        if (blocker_seen && !blocker_input) print "violation #" violation_count ": blocker missing non-empty input"
        if (blocker_seen && !blocker_command) print "violation #" violation_count ": blocker missing non-empty command"
      }

      /^[[:space:]]*[Cc][Ll][Ee][Aa][Nn]-[Ss][Cc][Aa][Nn]:[[:space:]]*/ {
        clean_count++
        check_sources($0, "clean-scan")
        next
      }

      /^[[:space:]]*[-*]*[[:space:]]*[Vv]iolation:/ {
        finish_violation()
        violation_count++
        has_corr = 0
        blocker_seen = 0
        blocker_input = 0
        blocker_command = 0
        next
      }

      violation_count > 0 && /^[[:space:]]*commit:[[:space:]]*[0-9a-fA-F]{7,40}/ {
        has_corr = 1
        match($0, /[0-9a-fA-F]{7,40}/)
        print substr($0, RSTART, RLENGTH) > hashfile
        next
      }

      violation_count > 0 && /^[[:space:]]*```(edit|grep|restate)/ {
        has_corr = 1
        next
      }

      violation_count > 0 && /^[[:space:]]*blocker:[[:space:]]*$/ {
        has_corr = 1
        blocker_seen = 1
        next
      }

      violation_count > 0 && blocker_seen && /^[[:space:]]*input:[[:space:]]*/ {
        value = $0
        sub(/^[[:space:]]*input:[[:space:]]*/, "", value)
        if (trim(value) != "") blocker_input = 1
        next
      }

      violation_count > 0 && blocker_seen && /^[[:space:]]*command:[[:space:]]*/ {
        value = $0
        sub(/^[[:space:]]*command:[[:space:]]*/, "", value)
        value = trim(value)
        lower = tolower(value)
        if (value == "") {
          blocker_command = 0
        } else if (lower ~ /^(tbd|todo|later|fix later|figure out|placeholder|none|n\/a|\.\.\.|<.*>)$/) {
          print "violation #" violation_count ": blocker command is a placeholder"
        } else {
          blocker_command = 1
        }
        next
      }

      END {
        finish_violation()
        if (clean_count == 0 && violation_count == 0) print "empty audit: provide clean-scan: or Violation:"
        if (clean_count > 0 && violation_count > 0) print "mutual-exclusion: use clean-scan or Violation:, not both"
      }
    ')

    if [ -n "$audit_errs" ]; then
      rm -f "$audit_hashes"
      block_proof_validation "Rule-compliance self-audit grammar failure: $audit_errs"
    fi

    bad_commits=""
    if [ -s "$audit_hashes" ]; then
      while IFS= read -r audit_hash; do
        if [ "$repo_is_git" != "true" ] ||
          ! git -C "$repo" cat-file -e "${audit_hash}^{commit}" 2>/dev/null ||
          ! git -C "$repo" merge-base --is-ancestor "$audit_hash" HEAD 2>/dev/null; then
          bad_commits="$bad_commits $audit_hash"
        fi
      done <"$audit_hashes"
    fi
    if [ -n "$bad_commits" ]; then
      rm -f "$audit_hashes"
      block_proof_validation "Rule-compliance self-audit has unreachable audit commit(s):$bad_commits."
    fi

    audit_sha=$(printf '%s' "$audit_section" | sha256sum | awk '{print $1}')
    cur_head=""
    workdir_dirty=0
    if [ "$repo_is_git" = "true" ]; then
      cur_head=$(git -C "$repo" rev-parse HEAD 2>/dev/null || true)
      if [ -n "$(git -C "$repo" status --porcelain 2>/dev/null || true)" ]; then
        workdir_dirty=1
      fi
    fi

    history_identity="$(repo_identity "$repo")"
    history_key="$(codex_hash_string "$history_identity")"
    history_dir="$root/history/$history_key"
    history_file="$history_dir/$session_id.log"
    mkdir -p "$history_dir"
    printf '%s\n' "$history_identity" >"$history_dir/repo_identity"
    if [ -f "$history_file" ]; then
      last_line=$(tail -n1 "$history_file")
      prev_sha=$(printf '%s' "$last_line" | cut -d'|' -f1)
      prev_head=$(printf '%s' "$last_line" | cut -d'|' -f2)

      if [ "$audit_sha" = "$prev_sha" ]; then
        if [ "$workdir_dirty" = "1" ]; then
          rm -f "$audit_hashes"
          block_proof_validation "Freshness block: identical audit plus dirty tree."
        fi
        if [ -n "$cur_head" ] && [ -n "$prev_head" ] && [ "$cur_head" != "$prev_head" ]; then
          rm -f "$audit_hashes"
          block_proof_validation "Freshness block: HEAD advance from $prev_head to $cur_head with a byte-identical audit."
        fi

        rescan_ok=$(printf '%s\n' "$audit_section" | awk '
          function trim(s) {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
            return s
          }
          /^[[:space:]]*[Rr]escanned:[[:space:]]*/ {
            body = $0
            sub(/^[^:]*:[[:space:]]*/, "", body)
            n = split(body, parts, ",")
            nonempty = 0
            has_codex = 0
            empty = 0
            for (i = 1; i <= n; i++) {
              item = trim(parts[i])
              if (item == "") empty = 1
              else nonempty++
              if (item ~ /CODEX\.md/) has_codex = 1
            }
            if (nonempty >= 3 && has_codex && !empty) ok = 1
          }
          END { print ok ? 1 : 0 }
        ')
        if [ "$rescan_ok" != "1" ]; then
          rm -f "$audit_hashes"
          block_proof_validation "Freshness block: missing/invalid rescanned: for byte-identical audit on unchanged repo."
        fi
      fi

      if [ -n "$cur_head" ] && [ -n "$prev_head" ] && [ "$cur_head" != "$prev_head" ] && [ -s "$audit_hashes" ]; then
        range_ok=0
        while IFS= read -r audit_hash; do
          if [ "$audit_hash" != "$prev_head" ] &&
            git -C "$repo" merge-base --is-ancestor "$prev_head" "$audit_hash" 2>/dev/null &&
            git -C "$repo" merge-base --is-ancestor "$audit_hash" "$cur_head" 2>/dev/null; then
            range_ok=1
            break
          fi
        done <"$audit_hashes"
        if [ "$range_ok" = "0" ]; then
          rm -f "$audit_hashes"
          block_proof_validation "Freshness block: old-only commit range after HEAD movement."
        fi
      fi
    fi

    printf '%s|%s|%s\n' "$audit_sha" "$cur_head" "$(date -u +%s)" >"$history_file"
    rm -f "$audit_hashes"
  fi

  activity_dir=$(codex_session_state_dir activity "$session_id" 2>/dev/null || true)
  task_dir=$(codex_session_state_dir active-task "$session_id" 2>/dev/null || true)
  [ -n "$activity_dir" ] && rm -rf "$activity_dir"
  [ -n "$task_dir" ] && rm -f "$task_dir/task_active"
  rm -f "$proof" "$instructions" "$baseline"
  dirty_summary="$(git_dirty_summary "$repo" || true)"
  if [ -n "$dirty_summary" ]; then
    git_status_at_accept="$proof_dir/git-status-at-accept.txt"
    printf '%s\n' "$dirty_summary" >"$git_status_at_accept"
    json_block "Verification proof accepted (legacy path), but git state is still dirty. Read $git_status_at_accept, relay the relevant result to the user, commit owned completed changes or state unrelated blockers, then stop."
  else
    json_block "Verification proof accepted (legacy path). Relay the relevant result to the user, then stop."
  fi
  exit 0
fi

if [ "$stop_active" = "true" ]; then
  activity_dir=$(codex_session_state_dir activity "$session_id" 2>/dev/null || true)
  task_dir=$(codex_session_state_dir active-task "$session_id" 2>/dev/null || true)
  [ -n "$activity_dir" ] && rm -rf "$activity_dir"
  [ -n "$task_dir" ] && rm -f "$task_dir/task_active"
  rm -f "$instructions" "$baseline"
  json_continue
  exit 0
fi

if [ "$changed" != "true" ]; then
  head_summary="$(git_head_summary "$repo")"
  [ -n "$head_summary" ] || head_summary="N/A (not a git repo)"
  activity_display="${activity_summary# }"
  [ -n "$activity_display" ] || activity_display="none"
  cat >"$instructions" <<EOF
# Stop Checklist Review

Automated checks already run by stop-gate:
- Git state: clean. No changed git state was detected.
- HEAD: $head_summary
- Activity markers: $activity_display

Do not rerun automated git checks unless investigating a reported failure.

Manual checks remaining:
1. Verify the applicable non-automated stop-checklist items.
2. If ECI or ATE was used, verify the session project-understanding ledger was updated.
3. If any item failed, fix it before stopping.
EOF

  json_block "Automated stop checks passed. Follow $instructions for remaining manual checks, then stop again."
  exit 0
fi

head_summary="$(git_head_summary "$repo")"
[ -n "$head_summary" ] || head_summary="N/A (not a git repo)"
dirty_summary="$(git_dirty_summary "$repo" || true)"
[ -n "$dirty_summary" ] || dirty_summary="clean"
secret_scan_rc=0
run_secret_scan "$repo" "$baseline" "$proof_dir" || secret_scan_rc=$?
case "$secret_scan_rc" in
  0) secret_scan_status="passed (gitleaks)" ;;
  1)
    json_block "Automated secret scan found possible secrets. Read $proof_dir/gitleaks-findings.txt, remove or explicitly remediate them, then stop again."
    exit 0
    ;;
  *)
    json_block "Automated secret scan could not complete. Read $proof_dir/gitleaks-findings.txt, fix the scanner failure, then stop again."
    exit 0
    ;;
esac
{
  cat <<EOF
# Automated Stop Checks

Automated checks already run by stop-gate:
- Git changes since the session baseline: present.
- Dirty worktree: $dirty_summary
- HEAD: $head_summary
- Secret scan: $secret_scan_status
- Change summary:
EOF
  printf '%s\n' "$change_summary" | indent_text
  cat <<'EOF'

Do not rerun automated git checks unless investigating a reported failure.

EOF
  cat "$HOME/.codex/hooks/stop-verification.md"
} >"$instructions"

json_block "Automated stop checks found changed git state. Follow $instructions for remaining verification, then stop again."
