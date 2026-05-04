#!/usr/bin/env bash
# Stop hook: require verification proof before ending.

set -euo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HOOK_DIR/lib/codex-proof-state.sh"

input=$(cat)
session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)
stop_active=$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2>/dev/null || true)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)
[ -z "$cwd" ] && cwd="$PWD"

json_continue() {
  jq -n '{continue: true}'
}

json_block() {
  jq -n --arg reason "$1" '{decision: "block", reason: $reason}'
}

section_has_body() {
  local file="$1"
  local target="$2"

  awk -v target="$target" '
    BEGIN { target = tolower(target) }
    function trim(s) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
      return s
    }
    /^##[[:space:]]*/ {
      heading = $0
      sub(/^##[[:space:]]*/, "", heading)
      heading = tolower(trim(heading))
      if (in_section) exit
      if (heading == target) {
        in_section = 1
        next
      }
    }
    in_section {
      line = trim($0)
      if (line != "") found = 1
    }
    END { exit(found ? 0 : 1) }
  ' "$file"
}

terminal_verdict_count() {
  awk '
    {
      line = tolower($0)
      while (match(line, /(^|[^[:alnum:]_-])(clean-pass|hard-escalation|user-closed):/)) {
        count++
        line = substr(line, RSTART + RLENGTH)
      }
    }
    END { print count + 0 }
  ' "$1"
}

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

case "$session_id" in
  ""|*[!A-Za-z0-9_-]*) json_continue; exit 0 ;;
esac

if codex_hook_is_subagent_context "$input"; then
  json_continue
  exit 0
fi

root="${CODEX_PROOF_ROOT:-$HOME/.cache/codex-proof}"
proof_dir="$root/$session_id"
proof="$proof_dir/proof.md"
summary="$proof_dir/summary-to-print.md"
instructions="$proof_dir/instructions.md"
baseline="$proof_dir/baseline_head"
skip=$(codex_existing_state_file skip-stop skip_stop "$session_id" "$cwd" 2>/dev/null || true)
side_stop=$(codex_existing_state_file side-stop side_stop "$session_id" "$cwd" 2>/dev/null || true)
eci_active=$(codex_existing_state_file eci eci_active "$session_id" "$cwd" 2>/dev/null || true)
repo="${cwd:-$PWD}"
change_summary="$(git_change_summary "$repo" "$baseline" || true)"
changed=false
[ -n "$change_summary" ] && changed=true

mkdir -p "$proof_dir"

if [ -n "$side_stop" ] && [ -f "$side_stop" ] && [ -n "$(find "$side_stop" -mmin -60 -print 2>/dev/null)" ]; then
  json_continue
  exit 0
fi

if [ -n "$eci_active" ] && [ -f "$eci_active" ]; then
  codex_note_state_session_id "$eci_active" "$session_id" || true
  json_block "ECI is active for this session. Complete the ECI task, hard-escalate it, or disengage through ~/.codex/bin/eci-active off <disengage-report.md> before stopping."
  exit 0
fi

if [ -n "$skip" ] && [ -f "$skip" ] && [ -n "$(find "$skip" -mmin -60 -print 2>/dev/null)" ]; then
  json_continue
  exit 0
fi

if [ "$stop_active" = "true" ]; then
  json_continue
  exit 0
fi

if [ -f "$proof" ]; then
  if section_has_body "$proof" "ECI completion certificate"; then
    if ! section_has_body "$proof" "Stop checklist walkthrough" || ! section_has_body "$proof" "Incomplete compliance"; then
      json_block "ECI completion proof must include non-empty Stop checklist walkthrough and Incomplete compliance sections."
      exit 0
    fi

    verdicts=$(terminal_verdict_count "$proof")
    if [ "$verdicts" -ne 1 ]; then
      json_block "ECI completion proof must include exactly one terminal verdict marker: clean-pass:, hard-escalation:, or user-closed:."
      exit 0
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
      json_block "Proof file is missing required sections:$missing. Follow $instructions and update $proof."
      exit 0
    fi

    audit_section=$(awk '
      /^##[[:space:]]*Rule-Compliance Self-Audit/ { in_audit=1; next }
      in_audit && /^##[[:space:]]/ { in_audit=0 }
      in_audit { print }
    ' "$proof")
    has_clean=false
    has_violation=false
    printf '%s\n' "$audit_section" | grep -qi 'clean-scan:' && has_clean=true
    printf '%s\n' "$audit_section" | grep -qi 'Violation:' && has_violation=true

    if [ "$has_clean" = "false" ] && [ "$has_violation" = "false" ]; then
      json_block "Rule-compliance self-audit must include clean-scan: or Violation: entries."
      exit 0
    fi
    if [ "$has_clean" = "true" ] && [ "$has_violation" = "true" ]; then
      json_block "Rule-compliance self-audit must use clean-scan or Violation entries, not both."
      exit 0
    fi
    if [ "$has_clean" = "true" ] && ! printf '%s\n' "$audit_section" | grep -q 'CODEX.md'; then
      json_block "Rule-compliance clean-scan must include CODEX.md."
      exit 0
    fi
    if [ "$has_clean" = "true" ]; then
      clean_line=$(printf '%s\n' "$audit_section" | grep -i 'clean-scan:' | head -n1)
      clean_sources=$(printf '%s\n' "$clean_line" | sed 's/^[^:]*:[[:space:]]*//')
      if [ "$(printf '%s\n' "$clean_sources" | awk -F',' '{print NF}')" -lt 3 ]; then
        json_block "Rule-compliance clean-scan must name at least three sources."
        exit 0
      fi
    fi
    if [ "$has_violation" = "true" ]; then
      audit_errs=$(printf '%s\n' "$audit_section" | awk '
        /^[[:space:]]*[-*]*[[:space:]]*Violation:/ {
          if (seen && !corr) print "violation #" n " has no correction marker"
          seen=1; n++; corr=0; next
        }
        seen && /^[[:space:]]*(commit:|```(edit|grep|restate)|blocker:)/ { corr=1 }
        END {
          if (seen && !corr) print "violation #" n " has no correction marker"
        }
      ')
      if [ -n "$audit_errs" ]; then
        json_block "Rule-compliance self-audit grammar failure: $audit_errs"
        exit 0
      fi
    fi
  fi

  cp "$proof" "$summary"
  rm -f "$proof" "$instructions" "$baseline"
  if [ "$changed" = "true" ]; then
    git_status_at_accept="$proof_dir/git-status-at-accept.txt"
    printf '%s\n' "$change_summary" >"$git_status_at_accept"
    json_block "Verification proof accepted, but git state is still dirty. Read $summary and $git_status_at_accept, relay the relevant result to the user, commit owned completed changes or state unrelated blockers, then stop."
  else
    json_block "Verification proof accepted. Read $summary, relay the relevant result to the user, then stop."
  fi
  exit 0
fi

if [ "$changed" != "true" ]; then
  cat >"$instructions" <<EOF
# Stop Checklist Review

No changed git state was detected, so full code verification is not required. Still verify the applicable stop checklist before stopping.

1. Read ~/.codex/hooks/stop-checklist.md.
2. Verify every applicable item.
3. If any item failed, fix it before stopping.
4. Write proof to:

   $proof

Required proof:

fast-exit: checklist review (no changed git state)

- Checklist items applied:
- Pass/fail result:
- Issues found and resolution:
EOF

  json_block "Check stop criteria. Follow $instructions, write $proof, then stop again."
  exit 0
fi

sed \
  -e "s|{{PROOF}}|$proof|g" \
  "$HOME/.codex/hooks/stop-verification.md" >"$instructions"

json_block "Code changes are present. Follow $instructions, write $proof, then stop again."
