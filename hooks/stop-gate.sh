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
      reason="$reason LOOP DETECTED ($recent_count blocks in 5min). Recovery flow: read instructions or stop-checklist, write proof, stop again, identify failing step, do not retry same approach."
    fi
  fi

  jq -n --arg reason "$reason" '{decision: "block", reason: $reason}'
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

hash_string() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    printf '%s' "$1" | cksum | awk '{print $1}'
  fi
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

case "$session_id" in
  ""|*[!A-Za-z0-9_-]*) json_continue; exit 0 ;;
esac

if codex_hook_is_subagent_context "$input"; then
  json_continue
  exit 0
fi

root="${CODEX_PROOF_ROOT:-$HOME/.cache/codex-proof}"
repo="${cwd:-$PWD}"
side_stop=$(codex_existing_state_file side-stop side_stop "$session_id" "$cwd" 2>/dev/null || true)

if [ -n "$side_stop" ] && [ -f "$side_stop" ] &&
  [ -n "$(find "$side_stop" -mmin -60 -print 2>/dev/null)" ] &&
  codex_side_stop_applies_to_session "$side_stop" "$session_id"; then
  json_continue
  exit 0
fi

proof_dir="$root/$session_id"
proof="$proof_dir/proof.md"
summary="$proof_dir/summary-to-print.md"
instructions="$proof_dir/instructions.md"
baseline="$proof_dir/baseline_head"
skip=$(codex_existing_state_file skip-stop skip_stop "$session_id" "$cwd" 2>/dev/null || true)
eci_active=$(codex_existing_state_file eci eci_active "$session_id" "$cwd" 2>/dev/null || true)
change_summary="$(git_change_summary "$repo" "$baseline" || true)"
changed=false
[ -n "$change_summary" ] && changed=true
repo_is_git=false
if git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  repo_is_git=true
fi

mkdir -p "$proof_dir"

proof_recovery_text() {
  printf ' Update %s using %s; if that file is missing, read %s.' \
    "$proof" "$instructions" "$HOME/.codex/hooks/stop-checklist.md"
}

block_proof_validation() {
  json_block "$1$(proof_recovery_text)"
  exit 0
}

if [ -n "$eci_active" ] && [ -f "$eci_active" ]; then
  codex_note_state_session_id "$eci_active" "$session_id" || true
  json_block "ECI is active for this session. Complete the ECI task, hard-escalate it, or disengage through ~/.codex/bin/eci-active off <disengage-report.md> before stopping."
  exit 0
fi

if [ -n "$skip" ] && [ -f "$skip" ] && [ -n "$(find "$skip" -mmin -60 -print 2>/dev/null)" ]; then
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
  if section_has_body "$proof" "ECI completion certificate"; then
    if ! section_has_body "$proof" "Stop checklist walkthrough" || ! section_has_body "$proof" "Incomplete compliance"; then
      block_proof_validation "ECI completion proof must include non-empty Stop checklist walkthrough and Incomplete compliance sections."
    fi

    verdicts=$(terminal_verdict_count "$proof")
    if [ "$verdicts" -ne 1 ]; then
      block_proof_validation "ECI completion proof must include exactly one terminal verdict marker: clean-pass:, hard-escalation:, or user-closed:."
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
    history_key="$(hash_string "$history_identity")"
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

if [ "$stop_active" = "true" ]; then
  json_continue
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
