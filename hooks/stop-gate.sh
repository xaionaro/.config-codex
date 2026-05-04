#!/usr/bin/env bash
# Stop hook: require verification proof before ending.

set -euo pipefail

input=$(cat)
session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)
stop_active=$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2>/dev/null || true)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)

json_continue() {
  jq -n '{continue: true}'
}

json_block() {
  jq -n --arg reason "$1" '{decision: "block", reason: $reason}'
}

case "$session_id" in
  ""|*[!A-Za-z0-9_-]*) json_continue; exit 0 ;;
esac

root="${CODEX_PROOF_ROOT:-$HOME/.cache/codex-proof}"
proof_dir="$root/$session_id"
proof="$proof_dir/proof.md"
summary="$proof_dir/summary-to-print.md"
instructions="$proof_dir/instructions.md"
baseline="$proof_dir/baseline_head"
skip="$proof_dir/skip_stop"

mkdir -p "$proof_dir"

case "${CODEX_ROLE:-}" in
  snitch|explorer|brainstormer|designer|reviewer|test-designer|test-reviewer|verifier|qa|eci-implementer|executor|test-executor)
    json_continue
    exit 0
    ;;
esac

if [ -f "$skip" ] && [ -n "$(find "$skip" -mmin -60 -print 2>/dev/null)" ]; then
  json_continue
  exit 0
fi

if [ "$stop_active" = "true" ]; then
  json_continue
  exit 0
fi

if [ -f "$proof" ]; then
  if ! grep -qiE 'fast.exit|fast exit' "$proof"; then
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
  json_block "Verification proof accepted. Read $summary, relay the relevant result to the user, then stop."
  exit 0
fi

repo="${cwd:-$PWD}"
changed=false

if git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if [ -s "$baseline" ]; then
    base=$(cat "$baseline" 2>/dev/null || true)
    if [ -n "$base" ] && git -C "$repo" cat-file -e "$base^{commit}" 2>/dev/null; then
      git -C "$repo" diff --quiet "$base"..HEAD -- 2>/dev/null || changed=true
    fi
  fi
  git -C "$repo" diff --quiet -- 2>/dev/null || changed=true
  git -C "$repo" diff --cached --quiet -- 2>/dev/null || changed=true
  [ -z "$(git -C "$repo" status --porcelain 2>/dev/null || true)" ] || changed=true
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
