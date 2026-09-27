#!/usr/bin/env bash

set -euo pipefail

ROOT="${WORKFLOW_SKILL_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
CODEX="$ROOT/CODEX.md"
ECI="$ROOT/skills/explore-critique-implement/SKILL.md"
TESTING_DISCIPLINE="$ROOT/skills/testing-discipline/SKILL.md"
DEBUGGING="$ROOT/skills/debugging-discipline/SKILL.md"
STATUS_REPORT="$ROOT/skills/writing-status-reports/SKILL.md"
LEDGER="$ROOT/skills/maintaining-context-ledger/SKILL.md"
LINEAGE="$ROOT/skills/references/requirement-lineage.md"
ATE="$ROOT/skills/agent-teams-execution/SKILL.md"
ECI_COVERAGE="$ROOT/skills/explore-critique-implement/references/coverage-map.md"
STYLE_ADMISSION="$ROOT/skills/references/workflow-runtime/coding-style-admission.md"
ATE_COVERAGE="$ROOT/skills/agent-teams-execution/references/coverage-map.md"
FAST_PATH="$ROOT/skills/explore-critique-implement/references/fast-path.md"
PAUSE="$ROOT/skills/references/workflow-runtime/pause-all-work.md"
POLICY="$ROOT/skills/references/workflow-runtime/policy-pressure-tests.md"
ECI_CRITIQUE="$ROOT/skills/explore-critique-implement/references/critique.md"
IMPLEMENT="$ROOT/skills/explore-critique-implement/references/implement.md"
REVIEW="$ROOT/skills/explore-critique-implement/references/review.md"
COORDINATOR="$ROOT/skills/explore-critique-implement/references/coordinator.md"
COORDINATOR_RUNTIME="$ROOT/skills/references/workflow-runtime/coordinator-runtime.md"
REVIEW_POLICY="$ROOT/skills/references/workflow-runtime/review-policy.md"
GATE_CATALOG="$ROOT/hooks/gate-escape-hatches.md"
SNITCH="$ROOT/skills/agent-teams-execution/references/snitch.md"
ATE_ORCHESTRATION="$ROOT/skills/agent-teams-execution/references/orchestration.md"
ATE_RESEARCH="$ROOT/skills/agent-teams-execution/references/research.md"
ATE_DESIGN="$ROOT/skills/agent-teams-execution/references/design.md"
ATE_EXECUTION="$ROOT/skills/agent-teams-execution/references/execution.md"
ATE_REVIEW="$ROOT/skills/agent-teams-execution/references/review.md"
ATE_TESTING="$ROOT/skills/agent-teams-execution/references/testing-and-qa.md"

fail() {
  printf 'workflow routing assertion failed: %s\n' "$*" >&2
  exit 1
}

require_text() {
  local file="$1" text="$2"
  grep -Fq -- "$text" "$file" || fail "$file is missing: $text"
}

require_line() {
  local file="$1" line="$2"
  grep -Fqx -- "$line" "$file" || fail "$file is missing line: $line"
}

require_pattern() {
  local file="$1" description="$2" pattern="$3" text
  text="$(tr '\n' ' ' <"$file")"
  grep -Eiq -- "$pattern" <<<"$text" || fail "$file is missing: $description"
}

require_order() {
  local input="$1" first="$2" second="$3"
  local before_first before_second

  [[ "$input" == *"$first"* && "$input" == *"$second"* ]] || return 1
  before_first="${input%%"$first"*}"
  before_second="${input%%"$second"*}"
  [ "${#before_first}" -lt "${#before_second}" ]
}

forbid_text() {
  local file="$1" text="$2"
  ! grep -Fq -- "$text" "$file" || fail "$file retains an ordinary-work gate: $text"
}

forbid_legacy_duration_forecast_form() {
  local file="$1" text="$2"
  ! grep -Fq -- "$text" "$file" || fail "$file retains legacy duration forecast form: $text"
}

forbid_legacy_duration_forecast_pattern() {
  local file="$1" description="$2" pattern="$3" text

  text="$(tr '\n' ' ' <"$file")"
  ! grep -Eiq -- "$pattern" <<<"$text" ||
    fail "$file retains legacy duration forecast form: $description"
}

forbid_forecast_advisory_contradiction() {
  local file="$1" text="$2"
  ! grep -Fq -- "$text" "$file" ||
    fail "$file contradicts the advisory forecast contract: $text"
}

forbid_generic_forecast_recalibration_placeholder() {
  local file="$1" placeholder="$2"
  ! grep -Fq -- "$placeholder" "$file" ||
    fail "$file retains non-UTC forecast recalibration placeholder: $placeholder"
}

forbid_pattern() {
  local file="$1" pattern="$2"
  ! grep -Eiq -- "$pattern" "$file" || fail "$file retains an ordinary-work gate matching: $pattern"
}

require_coverage_map_text() {
  local source="$1" label="$2" description="$3" expected="$4"

  grep -Fq -- "$expected" <<<"$source" ||
    fail "coverage map non-gate contract failed: $label is missing $description"
}

forbid_coverage_map_text() {
  local source="$1" label="$2" forbidden="$3"

  ! grep -Fq -- "$forbidden" <<<"$source" ||
    fail "coverage map non-gate contract failed: $label retains $forbidden"
}

forbid_coverage_map_pattern() {
  local source="$1" label="$2" pattern="$3"

  ! grep -Eiq -- "$pattern" <<<"$source" ||
    fail "coverage map non-gate contract failed: $label retains an ordinary-work gate"
}

assert_coverage_map_non_gate_contract() {
  local source="$1" label="$2"

  require_coverage_map_text "$source" "$label" 'the workflow coverage heading' '## Workflow coverage map'
  require_coverage_map_text "$source" "$label" 'the audit-index introduction' \
    'This map is an audit index, not an admission inventory.'
  require_coverage_map_text "$source" "$label" 'the audit-metadata boundary' \
    'Source versions, hashes, records, and coverage-map entries are audit metadata, never ordinary-work admission prerequisites.'
  require_coverage_map_text "$source" "$label" 'the role-table routing responsibility' \
    'The role-table routing responsibilities remain required workflow guidance.'
  forbid_coverage_map_text "$source" "$label" 'Baseline source SHA-256:'
  forbid_coverage_map_text "$source" "$label" 'exact pause transaction'
  forbid_coverage_map_text "$source" "$label" 'route before ordinary bounded work'
  forbid_coverage_map_pattern "$source" "$label" \
    '(record|receipt|hash|source[[:space:]-]+version|coverage-map[[:space:]-]+entr(y|ies)).*(must|required).*(before|for|to).*(ordinary|bounded|normal).*(work|write)'
}

assert_coverage_map_non_gate_mutation_is_rejected() {
  local source="$1" label="$2" mutation="$3" output

  if output="$(assert_coverage_map_non_gate_contract "$mutation" "$label" 2>&1)"; then
    fail "coverage map non-gate mutation was admitted: $label"
  fi
  grep -Fq -- 'coverage map non-gate contract failed' <<<"$output" ||
    fail "coverage map non-gate mutation was rejected for an unexpected reason: $label"
}

forbid_flattened_pattern() {
  local file="$1" description="$2" pattern="$3" text

  text="$(tr '\n' ' ' <"$file")"
  ! grep -Eiq -- "$pattern" <<<"$text" ||
    fail "$file retains forbidden forecast form: $description"
}

assert_local_links_resolve() {
  local file target resolved
  local -a documents=(
    "$CODEX"
    "$LEDGER"
    "$STATUS_REPORT"
    "$ECI"
    "$ATE"
    "$DEBUGGING"
    "$ECI_COVERAGE"
    "$ATE_COVERAGE"
    "$ROOT/skills/explore-critique-implement/references/coordinator.md"
    "$ROOT/skills/explore-critique-implement/references/critique.md"
    "$FAST_PATH"
    "$ROOT/skills/explore-critique-implement/references/explore.md"
    "$ROOT/skills/explore-critique-implement/references/implement.md"
    "$ROOT/skills/explore-critique-implement/references/review.md"
    "$ROOT/skills/agent-teams-execution/references/design.md"
    "$ROOT/skills/agent-teams-execution/references/execution.md"
    "$ROOT/skills/agent-teams-execution/references/orchestration.md"
    "$ROOT/skills/agent-teams-execution/references/research.md"
    "$ROOT/skills/agent-teams-execution/references/review.md"
    "$SNITCH"
    "$ROOT/skills/agent-teams-execution/references/testing-and-qa.md"
    "$ROOT/skills/references/workflow-runtime/coding-style-admission.md"
    "$ROOT/skills/references/workflow-runtime/coordinator-runtime.md"
    "$ROOT/skills/references/workflow-runtime/pause-all-work.md"
    "$ROOT/skills/references/workflow-runtime/policy-pressure-tests.md"
    "$ROOT/skills/references/workflow-runtime/review-policy.md"
    "$ROOT/skills/references/workflow-runtime/stop-recovery.md"
    "$GATE_CATALOG"
  )

  for file in "${documents[@]}"; do
    [ -s "$file" ] || fail "missing or empty workflow document: $file"
    while IFS= read -r target; do
      target="${target#](}"
      target="${target%%#*}"
      case "$target" in
        ''|http://*|https://*|mailto:*) continue ;;
      esac
      resolved="$(realpath -m "$(dirname "$file")/$target")"
      [ -e "$resolved" ] || fail "dangling link from $file: $target"
    done < <(grep -oE '\]\([^)]+' "$file" || true)
  done
}

assert_no_control_routes() {
  local file="$1" marker="$2" count row forbidden
  count="$(grep -Fc -- "$marker" "$file" || true)"
  [ "$count" -eq 1 ] || fail "$file must contain exactly one role row: $marker"
  row="$(grep -F -- "$marker" "$file")"
  for forbidden in \
    'references/coordinator.md' \
    'coordinator-runtime.md' \
    'references/orchestration.md' \
    'blocker-resolution-protocol' \
    'pause-all-work.md' \
    'stop-recovery.md' \
    'policy-pressure-tests.md' \
    'review-policy.md'; do
    [[ "$row" != *"$forbidden"* ]] || fail "$marker routes to coordinator-only module: $forbidden"
  done
}

assert_role_rows_are_local() {
  local snitch_row eci_coordinator_row ate_coordinator_row
  for marker in \
    '| `explorer` |' \
    '| `critic-step2` |' \
    '| `implementer` |' \
    '| Critic A/B/C, E2E |' \
    '| `fast-owner` |'; do
    assert_no_control_routes "$ECI" "$marker"
  done
  for marker in \
    '| Snitch |' \
    '| Explorer/researcher |' \
    '| Designer, Design Reviewer, FDR |' \
    '| `Executor` |' \
    '| Execution Reviewer A/B/C |' \
    '| Test Designer/Executor/Reviewer, Verifier, QA |'; do
    assert_no_control_routes "$ATE" "$marker"
  done

  eci_coordinator_row="$(grep -F -- '| coordinator |' "$ECI")"
  [[ "$eci_coordinator_row" == *'review-policy.md'* ]] ||
    fail 'ECI coordinator row must retain review-policy routing'
  ate_coordinator_row="$(grep -F -- '| Coordinator, Lead |' "$ATE")"
  [[ "$ate_coordinator_row" == *'review-policy.md'* ]] ||
    fail 'ATE coordinator row must retain review-policy routing'

  grep -Fq -- '| Coordinator, Lead, Snitch |' "$ATE" && fail 'obsolete combined Coordinator, Lead, Snitch row remains'
  snitch_row="$(grep -F -- '| Snitch |' "$ATE")"
  [[ "$snitch_row" == *'[snitch](references/snitch.md)'* && "$snitch_row" != *'../'* ]] ||
    fail 'Snitch is not routed only to its local module'
  require_text "$SNITCH" 'Audit assigned evidence and criteria asynchronously, then report reminders or gaps to coordinator/lead.'
  require_text "$SNITCH" 'Never becomes a prerequisite, direct interrupter, lifecycle owner, blocker resolver, writer, authority, or independent rerouter.'
  require_text "$SNITCH" 'Never loads coordinator runtime, orchestration, blocker-resolution-protocol, pause/stop, or policy modules.'
}

assert_debugging_role_routes() {
  local row

  row="$(grep -F -- '| `explorer` |' "$ECI")"
  [[ "$row" == *'[debugging-discipline](../debugging-discipline/SKILL.md)'* &&
     "$row" == *'only for assigned bug investigation'* ]] ||
    fail 'ECI explorer row must conditionally route assigned bug investigation to debugging-discipline'

  row="$(grep -F -- '| `implementer` |' "$ECI")"
  [[ "$row" == *'[debugging-discipline](../debugging-discipline/SKILL.md)'* &&
     "$row" == *'only for assigned code/debug work'* ]] ||
    fail 'ECI implementer row must conditionally route code/debug work to debugging-discipline'

  row="$(grep -F -- '| `Executor` |' "$ATE")"
  [[ "$row" == *'[debugging-discipline](../debugging-discipline/SKILL.md)'* &&
     "$row" == *'only for assigned bug, build-failure, flake, or performance-regression work'* ]] ||
    fail 'ATE Executor row must conditionally route debug work to debugging-discipline'

  require_text "$DEBUGGING" 'name: debugging-discipline'
}

assert_eci_relationships() {
  local table skill count
  table="$(awk '
    /^## Relationship to other skills$/ { capture = 1; next }
    capture && /^## / { exit }
    capture { print }
  ' "$ECI")"
  [ -n "$table" ] || fail 'ECI relationship table is missing'
  for skill in brainstorming agent-teams-execution blocker-resolution-protocol debugging-discipline; do
    count="$(grep -Fc -- "| \`$skill\` |" <<<"$table" || true)"
    [ "$count" -eq 1 ] || fail "ECI relationship table must contain $skill exactly once"
  done
  count="$(grep -Ec '^\| `[^`]+` \|' <<<"$table" || true)"
  [ "$count" -eq 4 ] || fail "ECI relationship table has $count skill rows; want 4"
  ! grep -Fq -- '| `systematic-debugging` |' <<<"$table" || fail 'ECI relationship table includes systematic-debugging'
  ! grep -Fq -- '| `proof-driven-development` |' <<<"$table" || fail 'ECI relationship table includes proof-driven-development'
}

assert_compaction_provenance() {
  local eci_source ate_source mutation

  require_text "$ECI" 'Maintenance provenance: [coverage map](references/coverage-map.md).'
  require_text "$ATE" 'Maintenance provenance: [coverage map](references/coverage-map.md).'
  eci_source="$(<"$ECI_COVERAGE")"
  ate_source="$(<"$ATE_COVERAGE")"
  assert_coverage_map_non_gate_contract "$eci_source" 'ECI coverage map'
  assert_coverage_map_non_gate_contract "$ate_source" 'ATE coverage map'

  mutation="$eci_source"$'\n\nReceipt required to execute bounded work.'
  assert_coverage_map_non_gate_mutation_is_rejected "$eci_source" 'ECI coverage map' "$mutation"
  mutation="$eci_source"$'\n\nNever require a route before ordinary bounded work.'
  assert_coverage_map_non_gate_mutation_is_rejected "$eci_source" 'ECI coverage map' "$mutation"
  mutation="$ate_source"$'\n\nReceipt required to execute bounded work.'
  assert_coverage_map_non_gate_mutation_is_rejected "$ate_source" 'ATE coverage map' "$mutation"
  mutation="$ate_source"$'\n\nNever require a route before ordinary bounded work.'
  assert_coverage_map_non_gate_mutation_is_rejected "$ate_source" 'ATE coverage map' "$mutation"
}

assert_reviewer_role_split() {
  local forbidden

  for required in \
    '## Critic A — coding style' \
    '## Critic B — correctness and fidelity' \
    '## Critic C — long-term health' \
    'Report findings only'; do
    require_text "$REVIEW" "$required"
  done

  for forbidden in \
    'coordinator-runtime' \
    'coordinator runtime' \
    'two-packet' \
    'two packet' \
    'required-critic manifest' \
    'required critic manifest' \
    'aggregate' \
    'acceptance' \
    'teardown' \
    'loop-breaker'; do
    if grep -Fqi -- "$forbidden" "$REVIEW"; then
      fail "reviewer module carries coordinator-only control concept: $forbidden"
    fi
  done

  for required in \
    '## Step 4 — Review coordination' \
    "Wait for each gate's required reviews and focused proof, plus E2E evidence when the central cadence calls for it. Final acceptance also requires the final E2E pair when a trigger applies." \
    'Pre-route every finding with the review policy.' \
    'Use the shared coordinator/runtime policy for repair cycles, clean-pass, and limits.'; do
    require_text "$COORDINATOR" "$required"
  done
}

extract_h2_section() {
  local file="$1" heading="$2"

  awk -v heading="$heading" '
    $0 == heading {
      found = 1
      next
    }
    found && /^## / {
      ended = 1
      exit
    }
    found { print }
    END {
      if (!found || !ended) {
        exit 1
      }
    }
  ' "$file"
}

section_active_literal_directive_line() {
  local section="$1" directive="$2"

  awk -v directive="$directive" '
    BEGIN { tick = sprintf("%c", 96) }

    function path_component(quote_depth, marker_indent, marker, item_id) {
      return quote_depth ":" marker_indent ":" marker ":" item_id
    }

    function path_prefix_for_indent(base, marker_indent, out, count, i, parts) {
      out = ""
      count = split(base, path_parts, "/")
      for (i = 2; i <= count; i++) {
        split(path_parts[i], parts, ":")
        if ((parts[2] + 0) < marker_indent)
          out = out "/" path_parts[i]
        else
          break
      }
      return out
    }

    function clear_list_path() {
      list_path_key = ""
      list_path_depth = 0
      list_path_quote_depth = 0
    }

    function commit_line_path() {
      if (line_is_thematic) {
        clear_list_path()
      } else if (line_has_explicit_list) {
        list_path_key = line_path_key
        list_path_depth = line_path_depth
        list_path_quote_depth = line_quote_depth
      } else if (!(line_inherited_continuation && line_valid &&
                   line_quote_depth == list_path_quote_depth)) {
        clear_list_path()
      }
    }

    function container_content(line, rest, prefix, spaces, leading, continuation, path_base, marker_offset, marker_indent, marker, marker_len, candidate_path, candidate_depth) {
      container_kind = "root"
      container_depth = 0
      container_indent = 0
      container_valid = 1
      line_has_explicit_list = 0
      line_inherited_continuation = 0
      line_path_key = ""
      line_path_depth = 0
      line_path_quote_depth = line_quote_depth
      match(line, /^ */)
      leading = RLENGTH
      rest = line
      path_base = ""
      candidate_path = ""
      candidate_depth = 0
      marker_offset = leading

      # Four-or-more spaces continue the exact preceding list item only when
      # they are at the same quote depth.  Otherwise they are root indented
      # code and must never become an active directive.
      if (list_path_key != "" && list_path_quote_depth == line_quote_depth && leading >= 4) {
        continuation = 1
        line_inherited_continuation = 1
        path_base = list_path_key
        candidate_path = path_base
        candidate_depth = list_path_depth
        container_kind = "list"
        container_depth = list_path_depth
        container_indent = leading
        rest = substr(line, leading + 1)
      } else if (leading >= 4) {
        container_valid = 0
        return ""
      } else {
        sub(/^ {0,3}/, "", rest)
      }

      while (1) {
        if (match(rest, /^[-+*]/)) {
          marker_len = 1
          marker = substr(rest, 1, marker_len)
        } else if (match(rest, /^[0-9]{1,9}[.)]/)) {
          marker_len = RLENGTH
          marker = substr(rest, 1, marker_len)
        } else {
          break
        }
        prefix = substr(rest, marker_len + 1)
        if (!match(prefix, /^[ \t]+/)) break
        spaces = RLENGTH
        marker_indent = marker_offset
        candidate_path = path_prefix_for_indent(candidate_path, marker_indent)
        candidate_depth = (candidate_path == "" ? 0 : split(candidate_path, path_parts, "/") - 1)
        candidate_path = candidate_path \
          "/" path_component(line_quote_depth, marker_indent, marker, ++list_item_serial)
        candidate_depth++
        line_has_explicit_list = 1
        container_kind = "list"
        container_depth = candidate_depth
        container_indent = spaces - 1
        marker_offset += marker_len + spaces
        rest = substr(prefix, spaces + 1)
      }
      line_path_key = candidate_path
      line_path_depth = candidate_depth
      return rest
    }

    function parse_line(line, rest, before, commit_path) {
      line_quote_depth = 0
      match(line, /^[ ]*/)
      line_leading_spaces = RLENGTH
      rest = line
      while (1) {
        before = rest
        if (match(rest, /^ {0,3}>[ \t]?/)) {
          rest = substr(rest, RLENGTH + 1)
          line_quote_depth++
        } else {
          break
        }
      }
      line_quote_content = rest
      line_thematic_content = rest
      sub(/^ {0,3}/, "", line_thematic_content)
      line_content = container_content(rest)
      line_valid = container_valid
      line_kind = container_kind
      line_depth = container_depth
      line_indent = container_indent
      line_blank = (rest ~ /^[ \t]*$/)
      line_is_thematic = line_valid && line_quote_depth == 0 &&
        (line_thematic_content ~ /^([*][ \t]*){3,}$/ ||
         line_thematic_content ~ /^([_][ \t]*){3,}$/ ||
         line_thematic_content ~ /^([-][ \t]*){3,}$/)
      # Commit list state only for ordinary (non-fence) lines.  Active-fence
      # parsing still computes a candidate path so sibling transitions can be
      # distinguished from nested pseudo-closers.
      if (fence_delimiter == "") commit_line_path()
    }

    function fence_width_for(wanted, rest, run, candidate, suffix) {
      fence_candidate = ""
      fence_suffix = ""
      if (!line_valid) return 0
      rest = line_content
      if ((wanted == "" || wanted == tick) && substr(rest, 1, 3) == tick tick tick) {
        run = 3
        while (substr(rest, run + 1, 1) == tick) run++
        candidate = tick
        suffix = substr(rest, run + 1)
        if (suffix ~ tick) return 0
      } else if ((wanted == "" || wanted == "~") && substr(rest, 1, 3) == "~~~") {
        run = 3
        while (substr(rest, run + 1, 1) == "~") run++
        candidate = "~"
        suffix = substr(rest, run + 1)
      } else {
        return 0
      }
      fence_candidate = candidate
      fence_suffix = suffix
      return run
    }

    function is_thematic() {
      return line_valid && line_quote_depth == 0 &&
        (line_thematic_content ~ /^([*][ \t]*){3,}$/ ||
         line_thematic_content ~ /^([_][ \t]*){3,}$/ ||
         line_thematic_content ~ /^([-][ \t]*){3,}$/)
    }

    function is_thematic_candidate() {
      return line_valid && line_quote_depth == 0 &&
        line_thematic_content ~ /^([*_-][ \t]*){3,}$/
    }

    function is_lazy_boundary(width) {
      width = fence_width_for("")
      if (is_thematic_candidate()) return is_thematic()
      return line_blank || line_content ~ /^#{1,6}([ \t]|$)/ ||
        (line_kind == "list" && line_content != "") || width >= 3 || is_thematic()
    }

    function directive_is_active(line, expected, actual_content, actual_valid, actual_quote, expected_content, expected_valid, expected_quote, saved_list_path_key, saved_list_path_depth, saved_list_path_quote_depth, saved_list_item_serial) {
      parse_line(line)
      actual_content = line_content
      actual_valid = line_valid
      actual_quote = line_quote_depth
      saved_list_path_key = list_path_key
      saved_list_path_depth = list_path_depth
      saved_list_path_quote_depth = list_path_quote_depth
      saved_list_item_serial = list_item_serial
      parse_line(expected)
      expected_content = line_content
      expected_valid = line_valid
      expected_quote = line_quote_depth
      list_path_key = saved_list_path_key
      list_path_depth = saved_list_path_depth
      list_path_quote_depth = saved_list_path_quote_depth
      list_item_serial = saved_list_item_serial
      return actual_valid && expected_valid && actual_quote == 0 && expected_quote == 0 &&
        actual_content != "" && expected_content != "" && actual_content == expected_content
    }

    function clear_fence() {
      fence_delimiter = ""
      fence_width = 0
      fence_quote_depth = 0
      fence_container = ""
      fence_depth = 0
      fence_indent = 0
      fence_path_key = ""
      fence_continuation = 0
      lazy_quote_depth = 0
    }

    function fence_close_is_compatible(width) {
      if (width < fence_width || fence_suffix !~ /^[ \t]*$/) return 0
      if (line_quote_depth != fence_quote_depth) return 0
      if (fence_container == "root")
        return line_kind == "root" && line_depth == 0 && line_indent <= fence_indent
      if (line_kind == "root")
        return line_quote_depth == 0 && line_depth == 0 && line_indent <= fence_indent
      if (fence_continuation)
        return line_kind == "list" && line_path_key == fence_path_key &&
          line_indent <= fence_indent + 3
      return line_kind == "list" && line_depth == fence_depth && line_indent <= fence_indent + 3
    }

    {
      parse_line($0)

      if (fence_delimiter != "") {
        # A root/ancestor list-item transition ends a continuation fence.  The
        # transition line is then reprocessed as the next list item, allowing
        # its own continuation fence to open without aliasing the old path.
        if (fence_continuation && line_has_explicit_list &&
            line_quote_depth == fence_quote_depth &&
            line_path_key != fence_path_key && line_path_depth <= fence_depth) {
          clear_fence()
          commit_line_path()
        } else {
          width = fence_width_for(fence_delimiter)
          if (fence_close_is_compatible(width)) clear_fence()
          next
        }
      }

      if (fence_quote_depth > 0) {
        if (line_quote_depth == fence_quote_depth) {
          width = fence_width_for(fence_delimiter)
          if (fence_close_is_compatible(width)) clear_fence()
        }
        next
      }

      if (lazy_quote_depth > 0) {
        if (line_quote_depth > 0) {
          if (line_blank) {
            lazy_quote_depth = 0
            next
          }
          width = fence_width_for("")
          if (width >= 3) {
            fence_delimiter = fence_candidate
            fence_width = width
            fence_quote_depth = line_quote_depth
            fence_container = line_kind
            fence_depth = line_depth
            fence_indent = line_indent
            fence_path_key = line_path_key
            fence_continuation = line_inherited_continuation && !line_has_explicit_list
          }
          next
        }
        if (!is_lazy_boundary()) next
        lazy_quote_depth = 0
      }

      if (line_blank) {
        lazy_quote_depth = 0
        next
      }

      width = fence_width_for("")
      if (width >= 3) {
        fence_delimiter = fence_candidate
        fence_width = width
        fence_quote_depth = line_quote_depth
        fence_container = line_kind
        fence_depth = line_depth
        fence_indent = line_indent
        fence_path_key = line_path_key
        fence_continuation = line_inherited_continuation && !line_has_explicit_list
        next
      }

      if (line_quote_depth > 0) {
        lazy_quote_depth = line_quote_depth
        next
      }

      if (directive_is_active($0, directive)) {
        found = 1
        print NR
        exit
      }
    }
    END { if (!found) exit 1 }
  ' <<<"$section"
}

section_has_active_literal_directive() {
  local section="$1" directive="$2"

  section_active_literal_directive_line "$section" "$directive" >/dev/null
}

require_active_literal_order() {
  local section="$1" first="$2" second="$3"
  local first_line second_line

  first_line="$(section_active_literal_directive_line "$section" "$first")" || return 1
  second_line="$(section_active_literal_directive_line "$section" "$second")" || return 1
  [ "$first_line" -lt "$second_line" ]
}

require_active_literal_directive() {
  local section="$1" description="$2" directive="$3"

  section_has_active_literal_directive "$section" "$directive" ||
    fail "section is missing active literal directive: $description"
}

insert_fixture_after() {
  local input="$1" anchor="$2" fixture="$3" mutation

  mutation="${input/"$anchor"/"$anchor"$'\n'"$fixture"}"
  [ "$mutation" != "$input" ] || return 1
  printf '%s\n' "$mutation"
}

assert_active_literal_directive_fixtures() {
  local checker="$1" source="$2" input="$3" anchor="$4" directive="$5" failure="$6"
  local fixture mutation output

  for fixture in \
    "$directive" \
    " $directive" \
    "  $directive" \
    "   $directive" \
    "- $directive" \
    " - $directive" \
    "  - $directive" \
    "   - $directive" \
    "* $directive" \
    " * $directive" \
    "  * $directive" \
    "   * $directive" \
    "+ $directive" \
    " + $directive" \
    "  + $directive" \
    "   + $directive" \
    "1. $directive" \
    " 1. $directive" \
    "  1. $directive" \
    "   1. $directive" \
    "1) $directive" \
    " 1) $directive" \
    "  1) $directive" \
    "   1) $directive" \
    $'> historical counterexample\n\n'"$directive" \
    $' ```text\nhistorical counterexample\n ```\n'"$directive" \
    $'   ```text\nhistorical counterexample\n   ```\n'"$directive" \
    $' ~~~text\nhistorical counterexample\n ~~~\n'"$directive" \
    $'   ~~~text\nhistorical counterexample\n   ~~~\n'"$directive"; do
    mutation="$(insert_fixture_after "$input" "$anchor" "$fixture")" ||
      fail "$source active directive fixture did not alter its section"
    if output="$("$checker" "$source" "$mutation" "$directive" 2>&1)"; then
      fail "$source admitted active directive fixture: $fixture"
    fi
    grep -Fq -- "$failure" <<<"$output" ||
      fail "$source rejected active directive fixture for an unexpected reason: $fixture"
  done

  for fixture in \
    "> $directive" \
    " > $directive" \
    "   > $directive" \
    "> historical prose mentioning $directive" \
    "\"$directive\"" \
    "$directive trailing explanatory text" \
    "- $directive trailing explanatory text" \
    "* $directive trailing explanatory text" \
    "+ $directive trailing explanatory text" \
    "1. $directive trailing explanatory text" \
    "1) $directive trailing explanatory text" \
    $'```text\n'"$directive"$'\n```' \
    $'~~~text\n'"$directive"$'\n~~~' \
    $' ```text\n'"$directive"$'\n ```' \
    $'   ```text\n'"$directive"$'\n   ```' \
    $' ~~~text\n'"$directive"$'\n ~~~' \
    $'   ~~~text\n'"$directive"$'\n   ~~~' \
    $'````text\n```\n'"$directive"$'\n```\n````' \
    $'````text\n````not-a-close\n'"$directive"$'\n````' \
    $'> historical counterexample\n'"$directive"; do
    mutation="$(insert_fixture_after "$input" "$anchor" "$fixture")" ||
      fail "$source explanatory directive fixture did not alter its section"
    if ! output="$("$checker" "$source" "$mutation" "$directive" 2>&1)"; then
      fail "$source rejected explanatory directive fixture: $fixture: $output"
    fi
  done
}

assert_active_directive_demotions() {
  local checker="$1" source="$2" input="$3" anchor="$4" failure="$5"
  local demotion mutation output

  for demotion in \
    "> $anchor" \
    $'```text\n'"$anchor"$'\n```' \
    $'~~~text\n'"$anchor"$'\n~~~'; do
    mutation="${input/"$anchor"/"$demotion"}"
    [ "$mutation" != "$input" ] ||
      fail "$source active directive demotion did not alter its section"
    if output="$("$checker" "$mutation" 2>&1)"; then
      fail "$source admitted demoted active directive: $anchor"
    fi
    grep -Fq -- "$failure" <<<"$output" ||
      fail "$source rejected demoted active directive for an unexpected reason: $anchor: $output"
  done
}

require_section_pattern() {
  local section="$1" description="$2" pattern="$3" flattened

  flattened="$(tr '\n' ' ' <<<"$section")"
  grep -Eiq -- "$pattern" <<<"$flattened" ||
    fail "section is missing: $description"
}

assert_configuration_e2e_contract() {
  local section

  require_line "$ECI" '## Configuration E2E contract'
  section="$(extract_h2_section "$ECI" '## Configuration E2E contract')" ||
    fail "$ECI lacks a bounded Configuration E2E section"
  require_section_pattern "$section" 'configuration changes require the final implementer and independent E2E pair' \
    'every[[:space:]]+configuration[[:space:]]+change,?[[:space:]]+including[[:space:]]+configuration-only[[:space:]]+work,?[[:space:]]+requires[[:space:]]+the[[:space:]]+final[[:space:]]+implementer-owned[[:space:]]+and[[:space:]]+fresh[[:space:]]+independent[[:space:]]+e2e[[:space:]]+pair'
  require_section_pattern "$section" 'the configuration final E2E pair may not be waived' \
    'this[[:space:]]+requirement[[:space:]]+may[[:space:]]+not[[:space:]]+be[[:space:]]+waived'
}

assert_runtime_e2e_policy() {
  local section

  require_line "$ECI" '## Runtime E2E policy'
  section="$(extract_h2_section "$ECI" '## Runtime E2E policy')" ||
    fail "$ECI lacks a bounded Runtime E2E section"
  require_section_pattern "$section" 'runtime-facing code/debug work requires E2E' \
    'code/debug[[:space:]]+work.*runtime[[:space:]]+behavior.*requires[[:space:]]+the[[:space:]]+final[[:space:]]+e2e[[:space:]]+pair'
  require_section_pattern "$section" 'runtime E2E trigger covers UI/API/device/CLI behavior' \
    'reachable[[:space:]]+through[[:space:]]+a[[:space:]]+ui,[[:space:]]+api,[[:space:]]+device,[[:space:]]+or[[:space:]]+cli'
  require_section_pattern "$section" 'docs, prompts, design-only, tests-only, and pure refactors remain excluded' \
    'docs,[[:space:]]+prompts,[[:space:]]+design-only[[:space:]]+changes,[[:space:]]+tests-only[[:space:]]+changes,[[:space:]]+and[[:space:]]+pure[[:space:]]+refactors[[:space:]]+do[[:space:]]+not[[:space:]]+require[[:space:]]+e2e'
}

assert_eci_e2e_cadence_contract() {
  local section

  require_line "$ECI" '## E2E cadence, scope, and timing'
  section="$(extract_h2_section "$ECI" '## E2E cadence, scope, and timing')" ||
    fail "$ECI lacks a bounded E2E cadence/timing section"
  require_section_pattern "$section" 'focused checks, diff verification, checkpoints, and independent reviews remain per iteration' \
    'each implementation iteration.*focused tests/proof.*independent verification.*exact diff.*coordinator checkpoint.*independent code review'
  require_text "$ECI" 'Do not run routine E2E between iterations.'
  require_section_pattern "$section" 'only concrete failures or integration uncertainty permit early E2E' \
    'early e2e is allowed only.*concrete failure or integration uncertainty.*shortest faithful real-path scenario.*early evidence does not replace final e2e'
  require_section_pattern "$section" 'a stable final cumulative candidate gets implementer and independent E2E' \
    'once main implementation, post-fast findings/dispositions, and any resulting implementation repairs are complete, run one final pair before acceptance whenever a configuration or runtime trigger applies.*implementer-owned e2e.*fresh independent step 4 e2e.*same stabilized final cumulative revision'
  require_section_pattern "$section" 'scope preserves the shortest faithful real path and only runs a full suite for required coverage' \
    'shortest faithful real path.*original criteria.*relevant regressions.*full suite only when it supplies coverage required'
  require_section_pattern "$section" 'E2E output cites the command and real-path evidence' \
    'cite the command and actual output/state/screenshot.*proxy evidence alone is insufficient'
  require_section_pattern "$section" 'all E2E types record timestamps and comparison context' \
    'every early, fast, implementer-final, and independent-final e2e report records.*started_at_utc.*finished_at_utc.*elapsed_monotonic_seconds.*command.*scope/coverage.*tested revision.*environment identity'
  for field in 'runner/host class' 'OS/architecture' 'relevant tool/runtime versions' 'test-service/data configuration' 'Redact secrets.'; do
    require_text "$ECI" "$field"
  done
  require_section_pattern "$section" 'duration comparisons require materially comparable runs and are not collected by rerunning' \
    'compare duration only for matching commands and scope/coverage in materially equivalent environments; do not rerun solely to collect timing'
  require_section_pattern "$section" 'comparable material regressions launch parallel optimization while main ECI continues' \
    'comparable material regression beyond ordinary variance triggers a fast owner or bounded helper to profile and optimize e2e duration in parallel while main eci continues'
  require_section_pattern "$section" 'optimization preserves assertions, coverage, real path, and independent final E2E' \
    'preserve assertions, coverage, real-path evidence, and the independent final e2e'
  require_section_pattern "$section" 'later relevant edits invalidate affected E2E evidence' \
    'later material edit affecting exercised behavior, assertions, or configuration invalidates the affected e2e evidence; refresh it before acceptance'
}

assert_eci_testing_discipline_precedence() {
  local source relationship

  source="$(<"$ECI")"
  relationship='For active ECI, this router controls E2E applicability and cadence within ECI iterations. `testing-discipline` still governs focused-check and required-E2E quality, but its generic per-modification E2E default does not add routine E2E between ECI iterations.'
  [[ "$source" == *"$relationship"* ]] ||
    fail 'ECI/testing-discipline precedence contract is missing or contradicted'
  require_text "$TESTING_DISCIPLINE" 'Test every modification before reporting done: unit checks plus E2E when a framework exists.'
  require_text "$ECI" 'This ECI-local cadence does not replace separately applicable outer-workflow acceptance evidence, such as ATE root gates.'
  require_text "$ATE" 'root aggregate review follows root proof.'
  require_text "$ATE" '5. Testing/QA obtain direct evidence for every criterion, then report a verdict to the user and wait for explicit closure.'
}

assert_e2e_policy_consumer_pointers() {
  local file

  require_line "$IMPLEMENT" 'E2E triggers, cadence, scope, and timing: [ECI E2E policy](../SKILL.md#e2e-cadence-scope-and-timing).'
  require_line "$REVIEW" 'E2E cadence, scope, timing, and triggers: [ECI E2E policy](../SKILL.md#e2e-cadence-scope-and-timing).'
  require_line "$COORDINATOR" 'After this, the coordinator alone assigns fresh Critic A, Critic B, and Critic C for every implementation iteration. E2E follows the [central cadence, scope, and timing policy](../SKILL.md#e2e-cadence-scope-and-timing), including its early-run condition and final independent run.'
  require_line "$FAST_PATH" 'Fast-owner E2E follows the [central ECI policy](../SKILL.md#e2e-cadence-scope-and-timing), including per-run timestamps, comparable-run regression checks, and parallel optimization when a material regression appears.'
  require_text "$REVIEW_POLICY" 'cadence, scope, and timing policy](../../explore-critique-implement/SKILL.md#e2e-cadence-scope-and-timing)'
  require_text "$COORDINATOR_RUNTIME" 'E2E cadence, scope, and timing policy](../../explore-critique-implement/SKILL.md#e2e-cadence-scope-and-timing)'
  for file in "$IMPLEMENT" "$REVIEW" "$COORDINATOR" "$FAST_PATH" "$REVIEW_POLICY" "$COORDINATOR_RUNTIME"; do
    require_text "$file" '#e2e-cadence-scope-and-timing'
  done
}

assert_no_direct_configuration_e2e_waivers_in_input() {
  local source="$1" input="$2" line continuation e2e e2e_end configuration_work configuration_target configuration_e2e
  local primary_configuration_e2e_action configuration_final_pair_action final_pair_first_waiver_action no_waiver_action implementer_e2e_action step4_e2e_action required_e2e_action direct_caveat_suffix
  local -a direct_waiver_patterns

  [ "$#" -ne 3 ] || input="$3"
  e2e='(e2e|\*e2e\*|\*\*e2e\*\*|_e2e_|__e2e__)'
  e2e_end='([[:space:].,;:!?]|$)'
  configuration_work='(^|[^[:alnum:]-])configuration(-only)?[[:space:]]+(changes?|work)'
  configuration_target='configuration(-only)?([[:space:]]+(changes?|work))?'
  configuration_e2e="(^|[^[:alnum:]-])configuration(-only)?([[:space:]]+(changes?|work))?[[:space:]]+${e2e}"
  primary_configuration_e2e_action="((every[[:space:]]+configuration[[:space:]]+change|all[[:space:]]+configuration[[:space:]]+changes),?[[:space:]]+including[[:space:]]+configuration-only[[:space:]]+work|including[[:space:]]+configuration-only[[:space:]]+work,?[[:space:]]+(every[[:space:]]+configuration[[:space:]]+change|all[[:space:]]+configuration[[:space:]]+changes))[[:space:]]*,?[[:space:]]+requires[[:space:]]+${e2e}"
  configuration_final_pair_action='every[[:space:]]+configuration[[:space:]]+change,?[[:space:]]+including[[:space:]]+configuration-only[[:space:]]+work,?[[:space:]]+requires[[:space:]]+the[[:space:]]+final[[:space:]]+implementer-owned[[:space:]]+and[[:space:]]+fresh[[:space:]]+independent[[:space:]]+e2e[[:space:]]+pair'
  final_pair_first_waiver_action="final[[:space:]]+(required[[:space:]]+)?${e2e}[[:space:]]+pair[[:space:]]+((may|can)[[:space:]]+be[[:space:]]+(omitted|skipped|waived)|is[[:space:]]+optional)[[:space:]]+for[[:space:]]+${configuration_target}${e2e_end}"
  no_waiver_action="(this[[:space:]]+configuration[[:space:]]+${e2e}[[:space:]]+requirement|this[[:space:]]+requirement)[[:space:]]+may[[:space:]]+not[[:space:]]+be[[:space:]]+waived"
  implementer_e2e_action="the[[:space:]]+implementer[[:space:]]+(runs[[:space:]]+(that[[:space:]]+${e2e}|it)|performs[[:space:]]+the[[:space:]]+required[[:space:]]+${e2e})[[:space:]]+before[[:space:]]+step[[:space:]]+4"
  step4_e2e_action="step[[:space:]]+4[[:space:]]+independently[[:space:]]+repeats[[:space:]]+or[[:space:]]+extends[[:space:]]+(its|the[[:space:]]+implementer.?s)[[:space:]]+${e2e}"
  required_e2e_action="(${primary_configuration_e2e_action}|${configuration_final_pair_action}|${no_waiver_action}|${implementer_e2e_action}|${step4_e2e_action})"
  direct_caveat_suffix='[[:space:],;:()]*(except|unless)([[:space:]]|$)'
  direct_waiver_patterns=(
    "${configuration_work}[[:space:],]+((may|can)[[:space:]]+(omit|skip|waive)|do(es)?[[:space:]]+not[[:space:]]+(need|require|run|perform)|need[[:space:]]+not[[:space:]]+(require|run|perform))[[:space:]]+${e2e}${e2e_end}"
    "${e2e}[[:space:]]+(may|can)[[:space:]]+be[[:space:]]+(omitted|skipped|waived)[[:space:]]+for[[:space:]]+${configuration_target}"
    "${e2e}[[:space:]]+is[[:space:]]+optional[[:space:]]+for[[:space:]]+${configuration_target}"
    "${e2e}[[:space:]]+for[[:space:]]+${configuration_target}[[:space:],]+(may|can)[[:space:]]+be[[:space:]]+(omitted|skipped|waived)${e2e_end}"
    "${e2e}[[:space:]]+for[[:space:]]+${configuration_target}[[:space:]]+is[[:space:]]+optional${e2e_end}"
    "skip[[:space:]]+${e2e}[[:space:]]+for[[:space:]]+${configuration_target}"
    "${configuration_e2e}[[:space:],]+(may|can)[[:space:]]+be[[:space:]]+(omitted|skipped|waived)${e2e_end}"
    "${configuration_e2e}[[:space:]]+is[[:space:]]+optional${e2e_end}"
    "$final_pair_first_waiver_action"
    "${configuration_work}[[:space:],]+(may|can)[[:space:]]+(omit|skip|waive)[[:space:]]+(the[[:space:]]+)?(required[[:space:]]+)?final[[:space:]]+${e2e}[[:space:]]+pair"
    "final[[:space:]]+${e2e}[[:space:]]+pair[[:space:]]+for[[:space:]]+${configuration_target}[[:space:],]+(may|can)[[:space:]]+be[[:space:]]+(omitted|skipped|waived)${e2e_end}"
    "${required_e2e_action}${direct_caveat_suffix}"
  )

  continuation=''
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ ^[[:space:]]*\>[[:space:]]*(.*)$ ]]; then
      continuation=''
      continue
    fi
    if [[ "$line" =~ ^[[:space:]]*$ ]]; then
      continuation=''
      continue
    fi
    if [ -n "$continuation" ]; then
      line="${continuation}${line}"
    fi
    continuation=''
    for pattern in "${direct_waiver_patterns[@]}"; do
      if grep -Eq -- "$pattern" <<<"${line,,}"; then
        fail "$source contains a direct configuration E2E waiver: $line"
      fi
    done
    if [[ "$line" =~ ,[[:space:]]*$ ]]; then
      continuation="$line"
    fi
  done <<<"$input"
}

assert_no_direct_configuration_e2e_waivers() {
  local file input

  for file in "$ECI" "$IMPLEMENT" "$REVIEW" "$COORDINATOR" "$REVIEW_POLICY" "$FAST_PATH"; do
    input="$(<"$file")"
    assert_no_direct_configuration_e2e_waivers_in_input "$file" "$input"
  done
}

assert_direct_configuration_e2e_waiver_is_rejected() {
  local source="$1" description="$2" input="$3" output

  if output="$(assert_no_direct_configuration_e2e_waivers_in_input "$source" "$input" 2>&1)"; then
    fail "direct configuration E2E waiver was admitted: $description"
  fi
  grep -Fq -- 'contains a direct configuration E2E waiver:' <<<"$output" ||
    fail "direct configuration E2E waiver was rejected for an unexpected reason: $description"
}

fast_path_fixture() {
  local policy_text="$1" provisional_text="$2"

  printf '%s\n%s\n\n%s\n%s\n' \
    '## Solo solving' "$policy_text" \
    '## Adoption, review, and closure' "$provisional_text"
}

assert_configuration_e2e_waiver_fixtures() {
  local primary_configuration_contract no_waiver_contract
  local reverse_action reverse_modal

  primary_configuration_contract='Every configuration change, including configuration-only work, requires the final implementer-owned and fresh independent E2E pair'
  no_waiver_contract='This requirement may not be waived'
  assert_direct_configuration_e2e_waiver_is_rejected "$FAST_PATH" 'configuration reverse waiver' \
    "$(fast_path_fixture 'Configuration E2E may be waived.' 'ordinary operational text.')"
  assert_no_direct_configuration_e2e_waivers_in_input "$ECI" 'fixture: routine inter-iteration E2E skip preserves final pair' \
    'Configuration changes may skip routine inter-iteration E2E; the required final pair remains.'
  assert_direct_configuration_e2e_waiver_is_rejected "$ECI" 'configuration skips required final pair' \
    'Configuration changes may skip the required final E2E pair.'
  assert_direct_configuration_e2e_waiver_is_rejected "$ECI" 'Critic B final pair waiver' \
    'The final E2E pair may be waived for configuration changes.'
  assert_direct_configuration_e2e_waiver_is_rejected "$ECI" 'final pair optional for configuration changes' \
    'The final E2E pair is optional for configuration changes.'
  assert_no_direct_configuration_e2e_waivers_in_input "$ECI" 'fixture: final pair waiver for non-configuration changes' \
    'The final E2E pair may be waived for non-configuration changes.'
  for reverse_modal in may can; do
    for reverse_action in omitted skipped waived; do
      assert_direct_configuration_e2e_waiver_is_rejected "$FAST_PATH" "configuration changes E2E $reverse_modal be $reverse_action" \
        "$(fast_path_fixture "Configuration changes E2E $reverse_modal be $reverse_action." 'ordinary operational text.')"
      assert_direct_configuration_e2e_waiver_is_rejected "$FAST_PATH" "E2E for configuration changes $reverse_modal be $reverse_action" \
        "$(fast_path_fixture "E2E for configuration changes $reverse_modal be $reverse_action." 'ordinary operational text.')"
    done
  done
  assert_direct_configuration_e2e_waiver_is_rejected "$FAST_PATH" 'configuration changes E2E optional' \
    "$(fast_path_fixture 'Configuration changes E2E is optional.' 'ordinary operational text.')"
  assert_direct_configuration_e2e_waiver_is_rejected "$FAST_PATH" 'E2E for configuration changes optional' \
    "$(fast_path_fixture 'E2E for configuration changes is optional.' 'ordinary operational text.')"
  assert_direct_configuration_e2e_waiver_is_rejected "$FAST_PATH" 'E2E for configuration changes comma continuation' \
    "$(fast_path_fixture $'E2E for configuration changes may be waived,\nunless urgent.' 'ordinary operational text.')"
  for reverse_action in omitted skipped; do
    assert_direct_configuration_e2e_waiver_is_rejected "$FAST_PATH" "configuration may be $reverse_action" \
      "$(fast_path_fixture "Configuration E2E may be $reverse_action." 'ordinary operational text.')"
  done
  for reverse_action in omitted skipped waived; do
    assert_direct_configuration_e2e_waiver_is_rejected "$FAST_PATH" "configuration can be $reverse_action" \
      "$(fast_path_fixture "Configuration E2E can be $reverse_action." 'ordinary operational text.')"
  done
  assert_direct_configuration_e2e_waiver_is_rejected "$FAST_PATH" 'configuration optional reverse waiver' \
    "$(fast_path_fixture 'Configuration E2E is optional.' 'ordinary operational text.')"
  assert_direct_configuration_e2e_waiver_is_rejected "$FAST_PATH" 'configuration reverse waiver comma continuation' \
    "$(fast_path_fixture $'Configuration E2E may be waived,\nfor a late change.' 'ordinary operational text.')"

  for reverse_modal in may can; do
    for reverse_action in omit skip waive; do
      assert_direct_configuration_e2e_waiver_is_rejected "$FAST_PATH" "configuration work $reverse_modal $reverse_action E2E" \
        "$(fast_path_fixture "Configuration work $reverse_modal $reverse_action E2E." 'ordinary operational text.')"
    done
  done
  for reverse_modal in may can; do
    for reverse_action in omitted skipped waived; do
      assert_direct_configuration_e2e_waiver_is_rejected "$FAST_PATH" "E2E $reverse_modal be $reverse_action for configuration" \
        "$(fast_path_fixture "E2E $reverse_modal be $reverse_action for configuration." 'ordinary operational text.')"
    done
  done
  assert_direct_configuration_e2e_waiver_is_rejected "$FAST_PATH" 'E2E optional for configuration' \
    "$(fast_path_fixture 'E2E is optional for configuration.' 'ordinary operational text.')"
  assert_direct_configuration_e2e_waiver_is_rejected "$FAST_PATH" 'skip E2E for configuration' \
    "$(fast_path_fixture 'Skip E2E for configuration.' 'ordinary operational text.')"
  assert_direct_configuration_e2e_waiver_is_rejected "$ECI" 'no-waiver comma-soft-wrap except caveat' \
    "$no_waiver_contract,"$'\n''except for late changes.'

  assert_direct_configuration_e2e_waiver_is_rejected "$ECI" 'primary contract except caveat' \
    "$primary_configuration_contract, except for late changes."
  assert_direct_configuration_e2e_waiver_is_rejected "$ECI" 'primary contract unless caveat' \
    "$primary_configuration_contract unless a manager says otherwise."
  assert_direct_configuration_e2e_waiver_is_rejected "$ECI" 'no-waiver contract except caveat' \
    "$no_waiver_contract except for late changes."
  assert_direct_configuration_e2e_waiver_is_rejected "$ECI" 'singular configuration waiver' \
    'Configuration change does not require E2E.'
  assert_direct_configuration_e2e_waiver_is_rejected "$FAST_PATH" 'fast-path prose primary contract except caveat' \
    "$(fast_path_fixture "$primary_configuration_contract, except for late changes." 'ordinary operational text.')"
  assert_direct_configuration_e2e_waiver_is_rejected "$ECI" 'ECI primary comma-soft-wrap except caveat' \
    "$primary_configuration_contract, "$'\n''except for late changes.'
  assert_direct_configuration_e2e_waiver_is_rejected "$FAST_PATH" 'fast-path prose comma-soft-wrap except caveat' \
    "$(fast_path_fixture "$primary_configuration_contract, "$'\n''except for late changes.' 'ordinary operational text.')"
  assert_direct_configuration_e2e_waiver_is_rejected "$ECI" 'ECI primary comma-no-space soft-wrap except caveat' \
    "$primary_configuration_contract,"$'\n''except for late changes.'
  assert_direct_configuration_e2e_waiver_is_rejected "$FAST_PATH" 'fast-path prose comma-no-space soft-wrap except caveat' \
    "$(fast_path_fixture "$primary_configuration_contract,"$'\n''except for late changes.' 'ordinary operational text.')"
  assert_no_direct_configuration_e2e_waivers_in_input "$ECI" 'fixture: historical blockquote primary caveat' \
    "> $primary_configuration_contract, except for late changes."
  assert_no_direct_configuration_e2e_waivers_in_input "$ECI" 'fixture: later separate prose' \
    "$primary_configuration_contract."$'\n''A later prose sentence mentions except and unless without changing the contract.'
  assert_no_direct_configuration_e2e_waivers_in_input "$ECI" 'fixture: comma then blank line' \
    "$primary_configuration_contract, "$'\n\n''except for late changes.'
  assert_no_direct_configuration_e2e_waivers_in_input "$FAST_PATH" 'fixture: nonconfiguration reverse waiver in fast-path policy' \
    "$(fast_path_fixture 'Non-configuration E2E may be waived.' 'ordinary historical text.')"
  assert_no_direct_configuration_e2e_waivers_in_input "$FAST_PATH" 'fixture: E2E-for-nonconfiguration waiver in fast-path policy' \
    "$(fast_path_fixture 'E2E for non-configuration changes may be waived.' 'ordinary historical text.')"
  assert_direct_configuration_e2e_waiver_is_rejected "$FAST_PATH" 'E2E-for-configuration waiver under fast-path policy' \
    "$(fast_path_fixture 'E2E for configuration changes may be waived.' 'ordinary operational text.')"
  assert_direct_configuration_e2e_waiver_is_rejected "$FAST_PATH" 'normative fast-path policy caveat' \
    "$(fast_path_fixture "$primary_configuration_contract, except for late changes." 'ordinary operational text.')"
  assert_no_direct_configuration_e2e_waivers_in_input "$FAST_PATH" 'fixture: nonconfiguration reverse waiver' \
    "$(fast_path_fixture 'normative policy remains unchanged.' 'Non-configuration E2E may be waived.')"
  assert_direct_configuration_e2e_waiver_is_rejected "$FAST_PATH" 'closure configuration waiver remains scanned' \
    "$(fast_path_fixture 'normative policy remains unchanged.' 'Configuration E2E may be waived.')"
  assert_direct_configuration_e2e_waiver_is_rejected "$FAST_PATH" 'closure E2E-for-configuration waiver remains scanned' \
    "$(fast_path_fixture 'normative policy remains unchanged.' 'E2E for configuration changes may be waived.')"
}

assert_coordinator_bug_routing_is_nonblocking() {
  require_text "$COORDINATOR" 'Capture a regression report or current coordination note before or alongside RCA;'
  forbid_text "$COORDINATOR" 'Write/update the regression report before RCA;'
}

assert_eci_ordinary_role_split() {
  local file forbidden
  local -a ordinary_modules=(
    "$ROOT/skills/explore-critique-implement/references/explore.md"
    "$ECI_CRITIQUE"
    "$ROOT/skills/explore-critique-implement/references/implement.md"
    "$REVIEW"
  )

  for file in "${ordinary_modules[@]}"; do
    for forbidden in \
      'coordinator-runtime' \
      'coordinator runtime' \
      'blocker-resolution-protocol' \
      'pause-all-work' \
      'stop-recovery' \
      'policy-pressure-tests' \
      'teardown' \
      'review-runtime' \
      'pressure policy' \
      'BRP' \
      'blocker routing' \
      're-spawn' \
      'respawn'; do
      if grep -Fqi -- "$forbidden" "$file"; then
        fail "$file carries coordinator-only routing: $forbidden"
      fi
    done
  done

  require_text "$ECI_CRITIQUE" 'Stop after the recommendation.'
  require_text "$ECI_CRITIQUE" '`reroute: explorer-revision`'
  for forbidden in 'review policy' 'applicable policy'; do
    if grep -Fqi -- "$forbidden" "$ECI_CRITIQUE"; then
      fail "ECI Step 2 critic carries coordinator-owned policy loading: $forbidden"
    fi
  done
}

assert_ate_ordinary_role_split() {
  local file forbidden
  local -a ordinary_modules=(
    "$ATE_RESEARCH"
    "$ATE_DESIGN"
    "$ATE_EXECUTION"
    "$ATE_REVIEW"
    "$ATE_TESTING"
  )

  for file in "${ordinary_modules[@]}"; do
    for forbidden in \
      'coordinator-runtime' \
      'coordinator runtime' \
      'required-critic' \
      'blocker-resolution-protocol' \
      'pause-all-work' \
      'stop-recovery' \
      'teardown' \
      'policy-pressure-tests' \
      'root aggregate' \
      'root proof' \
      'root E2E' \
      'post-review proof' \
      'protocol-limit' \
      'review cap' \
      'one root-task commit'; do
      if grep -Fqi -- "$forbidden" "$file"; then
        fail "$file carries coordinator-only control concept: $forbidden"
      fi
    done
  done

  require_text "$ATE_RESEARCH" '## Fact handoff'
  require_text "$ATE_RESEARCH" 'Return tagged facts with source anchors, confidence, risks, and unresolved questions.'
  require_text "$ATE_DESIGN" '## Design artifact'
  require_text "$ATE_DESIGN" '## FDR scrutiny'
  require_text "$ATE_EXECUTION" 'Submit as `submitted`, never `complete`.'
  require_text "$ATE_EXECUTION" 'a critique log (3+ issues found/fixed)'
  require_text "$ATE_REVIEW" 'Critic C may return `reconstructed intention:` followed by 2–4 bullets and stop.'
  require_text "$ATE_REVIEW" 'Reject a submission without its critique log.'
  require_text "$ATE_TESTING" 'Report each defect with criterion, evidence, impact, owner, and reproduction.'

  for forbidden in 'review policy' 'applicable policy'; do
    if grep -Fqi -- "$forbidden" "$ATE_REVIEW"; then
      fail "ATE reviewer module carries coordinator-owned policy loading: $forbidden"
    fi
  done

  for forbidden in \
    'Packet 1' \
    'Packet 2' \
    'coordinator runtime' \
    'manifest' \
    'identity validation'; do
    if grep -Fqi -- "$forbidden" "$ATE_REVIEW"; then
      fail "ATE reviewer module carries Critic C coordinator detail: $forbidden"
    fi
  done
  for forbidden in 'three distinct children' 'Lead-Mediated Nested Delegation'; do
    if grep -Fqi -- "$forbidden" "$ATE_DESIGN"; then
      fail "ATE design module carries FDR-child delegation mechanics: $forbidden"
    fi
  done

  for required in \
    '## Design and FDR coordination' \
    '## Root proof, review, and aggregate coordination' \
    '## Critic C packet coordination' \
    '## Debug, BRP, and cap coordination' \
    '## QA sequencing and closure' \
    'Lead-Mediated Nested Delegation' \
    'root aggregate review' \
    'Critic C Packet 1' \
    'QA approval is a verdict, not mission closure.'; do
    require_text "$ATE_ORCHESTRATION" "$required"
  done
  require_text "$ATE_ORCHESTRATION" '## Teardown and explicit closure'
  require_text "$ATE_ORCHESTRATION" 'Teardown occurs only after explicit lifecycle closure.'
  require_text "$ATE_ORCHESTRATION" 'Preserve the marker, teammates, and unresolved ownership until then.'
  require_text "$ATE_ORCHESTRATION" '30 minutes without assignment, output, owned file/Git, or observed-process activity'
  require_text "$ATE_ORCHESTRATION" 'one checkpoint per unchanged silence episode'
  require_text "$ATE_ORCHESTRATION" 'Preserve executor diff/status before closure or re-spawn; confirmed crash may re-spawn the same semantic role at most twice, then escalate to the user.'
}

assert_fast_path_routes() {
  local file
  require_text "$ECI" '| `fast-owner` | [ECI fast path](references/fast-path.md) |'
  require_line "$FAST_PATH" '# ECI fast path'
  for file in "$CODEX" "$ECI" "$COORDINATOR" "$IMPLEMENT" "$REVIEW" \
    "$ECI_CRITIQUE" "$ROOT/skills/explore-critique-implement/references/explore.md" \
    "$ATE" "$ATE_ORCHESTRATION" "$COORDINATOR_RUNTIME" "$REVIEW_POLICY" "$LEDGER" "$STATUS_REPORT"; do
    require_text "$file" 'fast-path.md'
    forbid_pattern "$file" 'Emergency Unblock|emergency-unblock\.md|pre-normal|Stage: emergency'
  done
  [ ! -e "$ROOT/skills/explore-critique-implement/references/emergency-unblock.md" ] ||
    fail 'obsolete emergency module remains'
  require_pattern "$FAST_PATH" 'both paths launch for every ECI task' \
    'Start one Fast owner alongside Step 1 for every new ECI task'
  require_pattern "$FAST_PATH" 'in-scope paths receive priority' \
    'Prioritize in-scope paths under'
  require_pattern "$FAST_PATH" 'shared live files' 'same checkout and live files'
  require_pattern "$FAST_PATH" 'each in-scope inventory item enters review' \
    'tracks each in-scope inventory item into review'
  require_pattern "$FAST_PATH" 'retained hunks remain cumulative code targets' \
    'retained fast hunk.*cumulative code target'
  require_pattern "$FAST_PATH" 'closure observes task-owned writers' \
    'either closure path.*both producers and their task-owned write-capable tools stopped or finished'
}

assert_fast_quality_contract() {
  local text="$1"
  require_section_pattern "$text" 'requirements-first quality assessment' \
    'Main ECI establishes design and quality from original requirements and applicable standards'
  require_section_pattern "$text" 'Fast implementation is a candidate, not a design premise' \
    'candidate implementation, never as acceptance or an authoritative design premise'
  require_section_pattern "$text" 'existing work cannot anchor design' \
    'presence, checkpoint, sunk cost, deadline pressure, or passing tests alone does not settle quality'
  require_section_pattern "$text" 'independent alternatives and material quality' \
    'Evaluate viable alternatives within authorized scope for correctness, maintainability, architecture, and applicable style'
  require_section_pattern "$text" 'evidence survives without mandatory rewriting' \
    'Preserve useful verified discoveries, still-valid tests, and qualifying code in place'
  require_section_pattern "$text" 'provenance or cosmetics do not force a rewrite' \
    'Fast provenance or cosmetic preference alone does not justify a rewrite'
}

assert_fast_quality_critique_contract() {
  require_section_pattern "$1" 'passing tests remain evidence but cannot settle design alone' \
    'implementation status and passing tests alone do not justify selecting it'
}

assert_fast_quality() {
  local text mutation output clause file
  text="$(extract_h2_section "$FAST_PATH" '## Main ECI quality responsibility')" ||
    fail 'Fast quality section missing'
  assert_fast_quality_contract "$text"
  for clause in 'establishes design and quality from original requirements' \
    'candidate implementation, never as acceptance or an authoritative design premise' \
    'does not settle quality' 'within authorized scope' 'still-valid tests' \
    'qualifying code in place' 'cosmetic preference alone does not justify a rewrite'; do
    mutation="${text/"$clause"/REMOVED}"
    if output="$(assert_fast_quality_contract "$mutation" 2>&1)"; then
      fail "Fast quality mutation admitted missing requirement: $clause"
    fi
    [[ "$output" == *'workflow routing assertion failed:'* ]] || fail "unexpected mutation failure: $output"
  done
  text="$(<"$ECI_CRITIQUE")"
  assert_fast_quality_critique_contract "$text"
  mutation="${text/'passing tests alone'/'passing tests'}"
  if output="$(assert_fast_quality_critique_contract "$mutation" 2>&1)"; then
    fail 'Fast quality mutation discarded passing tests as useful evidence'
  fi
  [[ "$output" == *'passing tests remain evidence'* ]] || fail "unexpected mutation failure: $output"
  for file in "$ROOT/skills/explore-critique-implement/references/explore.md" \
    "$ECI_CRITIQUE" "$IMPLEMENT" "$REVIEW"; do
    require_text "$file" 'fast-path.md#main-eci-quality-responsibility'
  done
}

assert_fast_path_progress_wait_contract() {
  local codex_text="$1" fast_text="$2" wait_rule section

  wait_rule="$(grep '^- Wait only for' <<<"$codex_text" || true)"
  require_section_pattern "$wait_rule" 'dependency-scoped global waits' \
    'Wait only for.*next action.*independent.*continue'
  section="$(extract_h2_section <(printf '%s\n' "$fast_text") '## Progress waits')" ||
    fail 'missing cross-path wait section'
  require_section_pattern "$section" 'cross-path wait preserves verification and real dependencies' \
    'available results once independently verified and the next action.s dependencies are satisfied'
  require_section_pattern "$section" 'cross-path wait permits independent progress' \
    'Independent work in the other path does not block intermediate progress'
  require_section_pattern "$section" 'cross-path wait follows general dependency scheduling' \
    'CODEX.md.*dependency.*independent tasks'
  require_section_pattern "$section" 'cross-path wait preserves aggregation and closure boundaries' \
    'coordinator\.md#step-4--review-coordination.*#adoption-review-and-closure'
}

assert_post_fast_transition_contract() {
  local text="$1"
  local restart_directive scope_clause quality_clause explorer_directive step2_directive
  restart_directive='A genuine Fast completion restarts the normal path from a fresh Step 1.'
  scope_clause='Scope-screen every Fast finding and every Fast-originated changed hunk against `exact user source → faithful requested outcome → bounded scope`. Keep only repairs necessary to meet or prove that outcome in scope.'
  quality_clause='The Explorer reviews every in-scope Fast finding and every in-scope Fast-originated changed hunk for quality.'
  explorer_directive='Then assign the reusable Explorer a new Step 1 exploration of the final shared scoped code, started after Fast completion. The Explorer reviews every in-scope Fast finding and every in-scope Fast-originated changed hunk for quality.'
  step2_directive="A fresh Step 2 critic independently assesses the current sources and Explorer's options."
  require_active_literal_directive "$text" 'post-Fast fresh Step 1 restart' "$restart_directive"
  require_section_pattern "$text" 'genuine Fast completion restarts from a fresh Step 1' \
    'A genuine Fast completion restarts the normal path from a fresh Step 1'
  require_section_pattern "$text" 'Explorer reviews every Fast finding and Fast-originated hunk' \
    'The Explorer reviews every in-scope Fast finding and every in-scope Fast-originated changed hunk for quality'
  require_active_literal_directive "$text" 'post-Fast scope-screen and source-outcome chain' "$scope_clause"
  require_active_literal_directive "$text" 'post-Fast Explorer restart and quality review' "$explorer_directive"
  require_order "$text" \
    "$restart_directive" \
    "$explorer_directive" ||
    fail 'post-Fast fresh Step 1 restart must precede the Step 1 quality review'
  require_order "$text" \
    "$scope_clause" \
    "$quality_clause" ||
    fail 'post-Fast scope-screen must precede the Step 1 quality review'
  require_order "$text" \
    'The Explorer reviews every in-scope Fast finding and every in-scope Fast-originated changed hunk for quality' \
    '3. A fresh Step 2 critic independently assesses' ||
    fail 'post-Fast Step 1 quality review must precede the fresh Step 2 critic'
  require_active_literal_directive "$text" 'post-Fast Step 2 critic directive' "$step2_directive"
  require_active_literal_order "$text" "$explorer_directive" "$step2_directive" ||
    fail 'post-Fast active Explorer directive must precede active Step 2'
  require_section_pattern "$text" 'Step 2 reviews every Fast finding and Fast-originated hunk' \
    'fresh Step 2 critic.*reviews every in-scope Fast finding and every in-scope Fast-originated changed hunk.*recommends exactly one canonical disposition'
  require_section_pattern "$text" 'implementer fixes or justifies retained Fast changes under winner' \
    'implementer fixes every routed `treatment: now` finding and fixes or justifies every retained Fast finding and every retained Fast-originated change under that selected winner, including no-hunk findings'
  require_section_pattern "$text" 'concurrent Step 4 is intermediate only' \
    'Any Step 4 review that runs concurrently before this restart is intermediate only and never acceptance'
  require_section_pattern "$text" 'final cumulative Step 4 follows disposition' \
    'After the fresh Step 1, Step 2, and implementer disposition, the final cumulative Step 4 independently reviews'
}

assert_post_fast_completion_observation_contract() {
  local text="$1"

  require_section_pattern "$text" 'completion observation identifies stopped Fast tools' \
    'The coordinator observes that the Fast owner has finished its assigned work, including delegated work, and all task-owned write-capable tools have stopped'
  require_section_pattern "$text" 'owner report enumerates all findings and hunks' \
    'The Fast owner completion report enumerates every finding and changed hunk from the Fast owner and its helpers'
  require_order "$text" \
    'The coordinator observes that the Fast owner has finished its assigned work, including delegated work, and all task-owned write-capable tools have stopped' \
    'The Fast owner completion report enumerates every finding and changed hunk from the Fast owner and its helpers' ||
    fail 'Fast completion observation must precede the owner report'
}

assert_post_fast_scope_and_disposition_contract() {
  local text="$1"
  local scope_clause explorer_directive inventory_directive final_acceptance_directive
  local defer_directive routing_directive repair_batch contained_now revise_replace other_dispositions
  local recommendation_directive final_evidence final_now separate_outcome

  scope_clause='Scope-screen every Fast finding and every Fast-originated changed hunk against `exact user source → faithful requested outcome → bounded scope`. Keep only repairs necessary to meet or prove that outcome in scope.'
  explorer_directive='Then assign the reusable Explorer a new Step 1 exploration of the final shared scoped code, started after Fast completion. The Explorer reviews every in-scope Fast finding and every in-scope Fast-originated changed hunk for quality.'
  inventory_directive='This complete inventory is review context, never a manifest, receipt, or admission/write gate.'
  final_acceptance_directive='Final acceptance requires every in-scope inventory item to have a disposition and evidence.'
  defer_directive='A policy-valid deferred-with-reason disposition is only for an in-scope, non-hard, impact-trivial, isolated finding; it requires evidence supporting each eligibility condition, plus a technical reason and revisit trigger; it never waives original criteria.'
  routing_directive='Apply impact-proportional routing before implementation.'
  repair_batch='Return substantive `now` findings or design/API uncertainty through one complete fresh Steps 1–2 repair batch.'
  contained_now='Send a `treatment: now` finding to the implementer once only if it is contained, in-scope, impact-trivial, and isolated.'
  revise_replace='A coordinator-applied `revise` or `replace` disposition reaches the implementer as `treatment: now` only when it is in-scope, contained, impact-trivial, and isolated; otherwise return through one complete fresh Steps 1–2 design-repair batch before implementation.'
  other_dispositions='Other dispositions require evidence, not implementation.'
  recommendation_directive='The fresh Step 2 critic reviews every in-scope Fast finding and every in-scope Fast-originated changed hunk and recommends exactly one canonical disposition for each in-scope inventory item: retain, revise, replace, superseded, resolved-with-evidence, or policy-valid deferred-with-reason, under [main ECI quality responsibility](#main-eci-quality-responsibility).'
  final_evidence='The final cumulative Step 4 verifies every in-scope inventory item has exactly one disposition and final evidence.'
  final_now='The final cumulative Step 4 leaves no unresolved in-scope `treatment: now` finding or failed-eligibility `revise`/`replace` needing implementation.'
  separate_outcome='Separate-outcome observations remain outside acceptance.'
  require_section_pattern "$text" 'scope-screen covers every Fast finding and hunk' \
    'Scope-screen every Fast finding and every Fast-originated changed hunk against `exact user source → faithful requested outcome → bounded scope`'
  require_section_pattern "$text" 'separate-outcome findings stay outside current work' \
    'A separate-outcome finding stays only a post-ECI observation/follow-up and creates no current repair, review, proof, or acceptance work'
  require_section_pattern "$text" 'Fast-originated hunks stay review context' \
    'Keep every Fast-originated hunk in inventory/review context; do not expand authorization'
  require_active_literal_directive "$text" 'post-Fast scope-screen and source-outcome chain' "$scope_clause"
  require_active_literal_directive "$text" 'post-Fast inventory remains review context' "$inventory_directive"
  require_active_literal_directive "$text" 'post-Fast final acceptance covers every inventory item' "$final_acceptance_directive"
  require_active_literal_directive "$text" 'post-Fast impact routing precedes implementation' "$routing_directive"
  require_active_literal_directive "$text" 'post-Fast substantive findings return through Steps 1–2' "$repair_batch"
  require_active_literal_directive "$text" 'post-Fast contained findings route once' "$contained_now"
  require_active_literal_directive "$text" 'post-Fast revise/replace mapping is explicit' "$revise_replace"
  require_active_literal_directive "$text" 'post-Fast non-now dispositions require evidence' "$other_dispositions"
  require_active_literal_directive "$text" 'post-Fast recommendation covers every disposition' "$recommendation_directive"
  require_active_literal_directive "$text" 'post-Fast defer policy is active' "$defer_directive"
  require_active_literal_directive "$text" 'post-Fast final evidence is active' "$final_evidence"
  require_active_literal_directive "$text" 'post-Fast unresolved-now rejection is active' "$final_now"
  require_active_literal_directive "$text" 'post-Fast separate outcomes stay outside acceptance' "$separate_outcome"
  require_section_pattern "$text" 'Step 1 reviews every Fast finding and hunk for scope and quality' \
    'The Explorer reviews every in-scope Fast finding and every in-scope Fast-originated changed hunk for quality'
  require_section_pattern "$text" 'Step 2 reviews every Fast finding and hunk before disposition' \
    'A fresh Step 2 critic.*reviews every in-scope Fast finding and every in-scope Fast-originated changed hunk.*recommends exactly one canonical disposition'
  require_section_pattern "$text" 'Step 2 recommends one disposition per in-scope item' \
    'A fresh Step 2 critic.*recommends exactly one canonical disposition for each in-scope inventory item: retain, revise, replace, superseded, resolved-with-evidence, or policy-valid deferred-with-reason'
  require_section_pattern "$text" 'Step 2 authority is limited to design-winner selection' \
    'Step 2 authority is limited to design-winner selection.*does not apply treatment'
  require_section_pattern "$text" 'coordinator applies one canonical disposition per item' \
    'The coordinator owns final disposition application/treatment and applies exactly one canonical disposition per in-scope inventory item'
  require_section_pattern "$text" 'Step 2 includes every disposition' \
    'retain, revise, replace, superseded, resolved-with-evidence, or policy-valid deferred-with-reason'
  require_section_pattern "$text" 'defer disposition points to impact-proportional routing' \
    'policy-valid deferred-with-reason only where.*review-policy\.md#impact-proportional-routing.*permits'
  require_section_pattern "$text" 'defer is bounded and never waives criteria' \
    'A policy-valid deferred-with-reason disposition is only for an in-scope, non-hard, impact-trivial, isolated finding; it requires evidence supporting each eligibility condition, plus a technical reason and revisit trigger; it never waives original criteria'
  require_section_pattern "$text" 'defer evidence failure is local and non-gating' \
    'Missing evidence invalidates only that defer conclusion; it never waives criteria or gates unrelated bounded work'
  require_section_pattern "$text" 'retained Fast findings and changes are fixed or justified' \
    'The implementer fixes every routed `treatment: now` finding and fixes or justifies every retained Fast finding and every retained Fast-originated change under that selected winner, including no-hunk findings'
  require_section_pattern "$text" 'no-hunk retain and resolved outcomes require evidence' \
    'Every no-hunk retain or resolved-with-evidence outcome requires evidence'
  require_section_pattern "$text" 'final coverage is every in-scope item exactly once' \
    'final cumulative Step 4 verifies every in-scope inventory item has exactly one disposition and final evidence'
  require_section_pattern "$text" 'final coverage leaves no unresolved now finding' \
    'no unresolved in-scope `treatment: now` finding'
  require_section_pattern "$text" 'separate-outcome observations stay outside acceptance' \
    'Separate-outcome observations remain outside acceptance'
  require_active_literal_directive "$text" 'post-Fast Explorer restart and quality review' "$explorer_directive"
}

assert_post_fast_no_active_contradiction() {
  local source="$1" input="$2" contradiction="$3"

  if section_has_active_literal_directive "$input" "$contradiction"; then
    fail "$source admits active post-Fast contradiction: $contradiction"
  fi
}

assert_post_fast_critique_contract() {
  local text="$1"

  require_section_pattern "$text" 'critic recommends exactly one canonical disposition per in-scope item' \
    'For post-Fast completion, independently assess final current sources and the new Explorer options before recommending exactly one canonical disposition for each in-scope inventory item in.*fast-path\.md#post-fast-completion'
  [[ "$text" != *'before selecting the canonical per-item disposition for each inventory item'* ]] ||
    fail 'critic still owns final per-item disposition selection'
  [[ "$text" != *'before selecting the concrete retain, revise, or replace disposition.'* ]] ||
    fail 'stale three-choice disposition'
}

assert_post_fast_critique_ownership_contract() {
  local text="$1"

  require_text <(printf '%s\n' "$text") \
    'before recommending exactly one canonical disposition for each in-scope inventory item'
  require_text <(printf '%s\n' "$text") \
    'Step 2 authority is limited to design-winner selection; it does not apply treatment.'
  require_text <(printf '%s\n' "$text") \
    'The critic emits issues and a per-item disposition recommendation only; it does not rewrite options, implement, assign debt/defer treatment, or apply treatment.'
  [[ "$text" != *'The Step 2 critic applies treatment.'* ]] ||
    fail 'Step 2 critic ownership contradiction was admitted'
  [[ "$text" != *'The Step 2 critic owns final disposition application/treatment.'* ]] ||
    fail 'Step 2 critic final-treatment contradiction was admitted'
}

assert_post_fast_coordinator_ownership_contract() {
  local text="$1"

  require_text <(printf '%s\n' "$text") \
    'After the Step 2 recommendation, the coordinator owns final disposition application/treatment and applies exactly one canonical disposition per in-scope inventory item.'
  require_text <(printf '%s\n' "$text") \
    'Step 2 authority is limited to design-winner selection; it does not apply treatment.'
  [[ "$text" != *'The coordinator applies multiple canonical dispositions per in-scope inventory item.'* ]] ||
    fail 'coordinator ownership contradiction was admitted'
  [[ "$text" != *'The coordinator does not own final disposition application/treatment.'* ]] ||
    fail 'coordinator final-treatment contradiction was admitted'
}

assert_post_fast_role_ownership() {
  local critique coordinator pressure output

  critique="$(<"$ECI_CRITIQUE")"
  coordinator="$(<"$COORDINATOR")"
  assert_post_fast_critique_ownership_contract "$critique"
  assert_post_fast_coordinator_ownership_contract "$coordinator"
  require_text "$IMPLEMENT" \
    "Receive the Step 2 design-winner recommendation and the coordinator's final per-item disposition/treatment."
  require_text "$IMPLEMENT" \
    'Implement only findings routed as `treatment: now`: fix each routed finding and implement coordinator-applied `revise`/`replace` changes.'
  require_text "$IMPLEMENT" \
    'Provide evidence, not implementation, for other dispositions.'
  require_text "$REVIEW" \
    'Review the final cumulative scoped state after the coordinator applies exactly one canonical disposition per in-scope inventory item.'

  pressure="$critique"$'\n\n''The Step 2 critic applies treatment.'
  if output="$(assert_post_fast_critique_ownership_contract "$pressure" 2>&1)"; then
    fail 'Step 2 critic treatment pressure fixture was admitted'
  fi
  [[ "$output" == *'Step 2 critic ownership contradiction'* ]] ||
    fail "unexpected Step 2 critic treatment pressure failure: $output"
  pressure="$coordinator"$'\n\n''The coordinator applies multiple canonical dispositions per in-scope inventory item.'
  if output="$(assert_post_fast_coordinator_ownership_contract "$pressure" 2>&1)"; then
    fail 'coordinator multiple-disposition pressure fixture was admitted'
  fi
  [[ "$output" == *'coordinator ownership contradiction'* ]] ||
    fail "unexpected coordinator multiple-disposition pressure failure: $output"
  pressure="$coordinator"$'\n\n''The coordinator does not own final disposition application/treatment.'
  if output="$(assert_post_fast_coordinator_ownership_contract "$pressure" 2>&1)"; then
    fail 'coordinator final-treatment pressure fixture was admitted'
  fi
  [[ "$output" == *'coordinator final-treatment contradiction'* ]] ||
    fail "unexpected coordinator final-treatment pressure failure: $output"
}

assert_deferred_disposition_policy_contract_text() {
  local text="$1"

  require_text <(printf '%s\n' "$text") \
    'Only an in-scope, non-hard, impact-trivial, isolated finding may defer.'
  require_text <(printf '%s\n' "$text") \
    'Require evidence supporting each eligibility condition (in-scope, non-hard, impact-trivial, and isolated), plus a technical reason and revisit trigger.'
  require_text <(printf '%s\n' "$text") \
    'Missing evidence invalidates only that defer conclusion; it never waives criteria or gates unrelated bounded work.'
}

assert_deferred_disposition_policy_active_directive_contract() {
  local source="$1" input="$2" routing

  routing="$(extract_h2_section <(printf '%s\n' "$input") '## Impact-proportional routing')" ||
    fail "$source lacks a bounded Impact-proportional routing section for defer-policy validation"
  if section_has_active_literal_directive "$routing" 'Hard findings may also use this disposition.'; then
    fail "$source defer-policy contract admits an active hard-finding disposition directive"
  fi
}

assert_deferred_disposition_policy_contract() {
  local text mutation output clause defer_anchor

  text="$(<"$REVIEW_POLICY")"
  assert_deferred_disposition_policy_contract_text "$text"
  assert_deferred_disposition_policy_active_directive_contract "$REVIEW_POLICY" "$text"
  defer_anchor="$(grep -F -- 'Only an in-scope, non-hard, impact-trivial, isolated finding may defer.' <<<"$text")"
  assert_active_literal_directive_fixtures \
    assert_deferred_disposition_policy_active_directive_contract "$REVIEW_POLICY" "$text" \
    "$defer_anchor" \
    'Hard findings may also use this disposition.' \
    'defer-policy contract'
  for clause in \
    'Only an in-scope, non-hard, impact-trivial, isolated finding may defer.' \
    'Require evidence supporting each eligibility condition' \
    'in-scope, non-hard, impact-trivial, and isolated' \
    'a technical reason and revisit trigger' \
    'Missing evidence invalidates only that defer conclusion' \
    'never waives criteria' \
    'gates unrelated bounded work'; do
    mutation="${text/"$clause"/REMOVED}"
    if output="$(assert_deferred_disposition_policy_contract_text "$mutation" 2>&1)"; then
      fail "deferred disposition policy mutation admitted missing rule: $clause"
    fi
    [[ "$output" == *'workflow routing assertion failed:'* ]] ||
      fail "unexpected deferred disposition policy mutation failure: $clause: $output"
  done
}

assert_post_fast_inventory_contract() {
  local text="$1" recommendation coordinator_application retained_fix scope_clause provenance

  recommendation='recommends exactly one canonical disposition for each in-scope inventory item'
  coordinator_application='The coordinator owns final disposition application/treatment and applies exactly one canonical disposition per in-scope inventory item'
  retained_fix='The implementer fixes every routed `treatment: now` finding and fixes or justifies every retained Fast finding and every retained Fast-originated change under that selected winner, including no-hunk findings'
  scope_clause='Scope-screen every Fast finding and every Fast-originated changed hunk against `exact user source → faithful requested outcome → bounded scope`'
  provenance='Inventory states retained, revised, non-retained, superseded, and reverted are provenance only, not canonical dispositions; no inventory state implies a disposition.'

  assert_post_fast_completion_observation_contract "$text"
  assert_post_fast_scope_and_disposition_contract "$text"

  require_section_pattern "$text" 'Fast completion reports every finding and changed hunk' \
    'Fast owner completion report enumerates every finding and changed hunk from the Fast owner and its helpers'
  require_section_pattern "$text" 'inventory includes no-hunk findings and every change outcome' \
    'Include findings with no retained hunk and changes that are retained, revised, non-retained, superseded, or reverted'
  require_section_pattern "$text" 'inventory states are provenance, not dispositions' "$provenance"
  require_active_literal_directive "$text" 'inventory states are active provenance-only guidance' "$provenance"
  require_section_pattern "$text" 'coordinator reconciles the complete inventory' \
    'The coordinator reconciles the report with shared state'
  require_section_pattern "$text" 'inventory is review context and never a gate' \
    'This complete inventory is review context, never a manifest, receipt, or admission/write gate'
  require_section_pattern "$text" 'final acceptance covers every inventory item' \
    'Final acceptance requires every in-scope inventory item to have a disposition and evidence'
  require_section_pattern "$text" 'fresh Step 1 reviews each in-scope inventory item' \
    'The Explorer reviews each in-scope inventory item'
  require_section_pattern "$text" 'fresh Step 1 reviews every Fast-originated hunk for scope and quality' \
    'The Explorer reviews every in-scope Fast finding and every in-scope Fast-originated changed hunk for quality'
  require_section_pattern "$text" 'fresh Step 2 assigns one disposition per item' \
    'A fresh Step 2 critic.*recommends exactly one canonical disposition for each in-scope inventory item: retain, revise, replace, superseded, resolved-with-evidence, or policy-valid deferred-with-reason'
  require_section_pattern "$text" 'contained treatment-now finding routes once' \
    'Send a `treatment: now` finding to the implementer once only if it is contained, in-scope, impact-trivial, and isolated'
  require_section_pattern "$text" 'implementer applies selected revise and replace dispositions' \
    'The implementer implements those routed coordinator-applied revise/replace changes'
  require_section_pattern "$text" 'implementer validates retained and revised changes' \
    'validates retained/revised changes'
  require_section_pattern "$text" 'implementer evidences no-hunk resolutions' \
    'supplies evidence for no-hunk resolutions'
  require_section_pattern "$text" 'implementer evidences every non-retained and deferred outcome' \
    'supplies evidence for no-hunk resolutions and for non-retained, superseded, reverted, resolved, and deferred outcomes'
  require_section_pattern "$text" 'final Step 4 verifies disposition and final evidence' \
    'final cumulative Step 4 verifies every in-scope inventory item has exactly one disposition and final evidence'
  require_section_pattern "$text" 'final Step 4 leaves no unresolved in-scope item' \
    'no unresolved in-scope `treatment: now` finding'
  require_order "$text" 'The coordinator observes that the Fast owner has finished its assigned work, including delegated work, and all task-owned write-capable tools have stopped' \
    'Fast owner completion report enumerates every finding and changed hunk from the Fast owner and its helpers' &&
    require_order "$text" 'Fast owner completion report enumerates every finding and changed hunk from the Fast owner and its helpers' \
      'The coordinator reconciles the report with shared state' &&
    require_order "$text" 'The coordinator reconciles the report with shared state' \
      "$scope_clause" &&
    require_order "$text" "$scope_clause" \
      'The Explorer reviews each in-scope inventory item' &&
    require_order "$text" 'The Explorer reviews each in-scope inventory item' \
      "$recommendation" &&
    require_order "$text" "$provenance" \
      "$recommendation" &&
    require_order "$text" "$recommendation" \
      "$coordinator_application" &&
    require_order "$text" "$coordinator_application" \
      'Apply impact-proportional routing before implementation.' &&
    require_order "$text" 'Apply impact-proportional routing before implementation.' \
      'Return substantive `now` findings or design/API uncertainty through one complete fresh Steps 1–2 repair batch.' &&
    require_order "$text" 'Return substantive `now` findings or design/API uncertainty through one complete fresh Steps 1–2 repair batch.' \
      'Send a `treatment: now` finding to the implementer once only if it is contained, in-scope, impact-trivial, and isolated.' &&
    require_order "$text" 'Send a `treatment: now` finding to the implementer once only if it is contained, in-scope, impact-trivial, and isolated.' \
      'A coordinator-applied `revise` or `replace` disposition reaches the implementer as `treatment: now` only when it is in-scope, contained, impact-trivial, and isolated; otherwise return through one complete fresh Steps 1–2 design-repair batch before implementation.' &&
    require_order "$text" 'A coordinator-applied `revise` or `replace` disposition reaches the implementer as `treatment: now` only when it is in-scope, contained, impact-trivial, and isolated; otherwise return through one complete fresh Steps 1–2 design-repair batch before implementation.' \
      'Other dispositions require evidence, not implementation.' &&
    require_order "$text" "$coordinator_application" \
      "$retained_fix" &&
    require_order "$text" 'Other dispositions require evidence, not implementation.' \
      "$retained_fix" &&
    require_order "$text" "$retained_fix" \
      'The implementer implements those routed coordinator-applied revise/replace changes' &&
    require_order "$text" 'The implementer implements those routed coordinator-applied revise/replace changes' \
      'supplies evidence for no-hunk resolutions' &&
    require_order "$text" 'supplies evidence for no-hunk resolutions' \
      'the final cumulative Step 4 independently reviews' ||
    fail 'post-Fast inventory and repair sequence is out of order'
}

assert_post_fast_completion_contract() {
  local text="$1"
  assert_post_fast_transition_contract "$text"
  assert_post_fast_inventory_contract "$text"
  require_section_pattern "$text" 'Fast must actually finish before final exploration' \
    'Fast owner has finished its assigned work, including delegated work, and all task-owned write-capable tools have stopped'
  require_section_pattern "$text" 'yield, labels, or cancellation cannot stand in for completion' \
    'write-yield, idle label, timeout, or cancellation is not Fast completion'
  require_section_pattern "$text" 'fresh exploration inspects final shared code' \
    'new Step 1 exploration of the final shared scoped code.*after Fast completion'
  require_section_pattern "$text" 'independent post-Fast design disposition' \
    'fresh Step 2 critic independently assesses.*recommends exactly one canonical disposition'
  require_section_pattern "$text" 'post-Fast review remains required even without changes' \
    'Step 4 independently reviews the final cumulative scoped state even when no further edits are needed'
  require_section_pattern "$text" 'normal completion waits for post-Fast quality' \
    'normal path remains incomplete until this post-Fast sequence passes'
  require_section_pattern "$text" 'resumed Fast writes restart final-state assessment' \
    'Resumed Fast writes invalidate this sequence; after Fast finishes again, repeat it'
  require_section_pattern "$text" 'cancellation closes without claiming success' \
    'Cancellation uses user closure, never a clean pass or substitute Fast completion'
  require_order "$text" 'Fast owner has finished' 'new Step 1 exploration' &&
    require_order "$text" 'new Step 1 exploration' 'fresh Step 2 critic' &&
    require_order "$text" 'fresh Step 2 critic' 'Step 4 independently reviews' ||
    fail 'post-Fast completion sequence is out of order'
}

assert_post_fast_completion() {
  local text clause mutation output file pressure state dispositions replacement inventory_gate contradiction base
  local defer_clause defer_evidence_clause missing_defer missing_evidence observation report critique
  local restart_line quality_clause scope_clause scope_line step2_directive step2_line step4_tail explorer_directive explorer_line recommendation recommendation_line coordinator_application retained_fix contained_now provenance provenance_line
  local inventory_line final_acceptance_line routing_line repair_batch_line contained_now_line revise_replace_line other_dispositions_line
  local defer_line final_evidence_line final_now_line separate_outcome_line
  text="$(awk '
    /^## Post-Fast completion$/ { found = 1; next }
    found && /^## / { exit }
    found { print }
    END { if (!found) exit 1 }
  ' "$FAST_PATH")" ||
    fail 'missing post-Fast completion barrier'
  assert_post_fast_completion_contract "$text"
  restart_line='A genuine Fast completion restarts the normal path from a fresh Step 1.'
  quality_clause='The Explorer reviews every in-scope Fast finding and every in-scope Fast-originated changed hunk for quality.'
  scope_clause='Scope-screen every Fast finding and every Fast-originated changed hunk against `exact user source → faithful requested outcome → bounded scope`. Keep only repairs necessary to meet or prove that outcome in scope.'
  scope_line='   - '"$scope_clause"
  explorer_directive='Then assign the reusable Explorer a new Step 1 exploration of the final shared scoped code, started after Fast completion. The Explorer reviews every in-scope Fast finding and every in-scope Fast-originated changed hunk for quality.'
  explorer_line='   - '"$explorer_directive"
  inventory_line='   - This complete inventory is review context, never a manifest, receipt, or admission/write gate.'
  final_acceptance_line='   - Final acceptance requires every in-scope inventory item to have a disposition and evidence.'
  routing_line='   - Apply impact-proportional routing before implementation.'
  repair_batch_line='   - Return substantive `now` findings or design/API uncertainty through one complete fresh Steps 1–2 repair batch.'
  contained_now_line='   - Send a `treatment: now` finding to the implementer once only if it is contained, in-scope, impact-trivial, and isolated.'
  revise_replace_line='   - A coordinator-applied `revise` or `replace` disposition reaches the implementer as `treatment: now` only when it is in-scope, contained, impact-trivial, and isolated; otherwise return through one complete fresh Steps 1–2 design-repair batch before implementation.'
  other_dispositions_line='   - Other dispositions require evidence, not implementation.'
  defer_line='   - A policy-valid deferred-with-reason disposition is only for an in-scope, non-hard, impact-trivial, isolated finding; it requires evidence supporting each eligibility condition, plus a technical reason and revisit trigger; it never waives original criteria.'
  contained_now='Send a `treatment: now` finding to the implementer once only if it is contained, in-scope, impact-trivial, and isolated.'
  final_evidence_line='   - The final cumulative Step 4 verifies every in-scope inventory item has exactly one disposition and final evidence.'
  final_now_line='   - The final cumulative Step 4 leaves no unresolved in-scope `treatment: now` finding or failed-eligibility `revise`/`replace` needing implementation.'
  separate_outcome_line='   - Separate-outcome observations remain outside acceptance.'
  step2_directive="A fresh Step 2 critic independently assesses the current sources and Explorer's options."
  step2_line='3. '"$step2_directive"
  step4_tail='   - Earlier reviews alone cannot satisfy this sequence.'
  mutation="${text/"$explorer_line"/}"
  mutation="${mutation/"$step2_line"/> The Explorer reviews every in-scope Fast finding and every in-scope Fast-originated changed hunk for quality.
$step2_line}"
  if output="$(assert_post_fast_completion_contract "$mutation" 2>&1)"; then
    fail 'post-Fast active Explorer directive mutation admitted quoted replacement'
  fi
  [[ "$output" == *'section is missing active literal directive: post-Fast Explorer restart and quality review'* ]] ||
    fail "unexpected post-Fast active Explorer directive failure: $output"
  mutation="${text/"$explorer_line"/}"
  mutation="${mutation/"$step2_line"/> $explorer_directive
$step2_line}"
  mutation="${mutation/"$step4_tail"/"$step4_tail"$'\n'"$explorer_line"}"
  if output="$(assert_post_fast_completion_contract "$mutation" 2>&1)"; then
    fail 'post-Fast active Explorer/Step 2 order mutation admitted reordered directives'
  fi
  [[ "$output" == *'post-Fast active Explorer directive must precede active Step 2'* ]] ||
    fail "unexpected post-Fast active Explorer/Step 2 order failure: $output"
  mutation="${text/"$scope_line"/}"
  mutation="${mutation/"$explorer_line"/"$explorer_line"$'\n'"$scope_line"}"
  if output="$(assert_post_fast_completion_contract "$mutation" 2>&1)"; then
    fail 'post-Fast scope-order mutation admitted quality review before scope screening'
  fi
  [[ "$output" == *'post-Fast scope-screen must precede the Step 1 quality review'* ]] ||
    fail "unexpected post-Fast scope-order failure: $output"
  recommendation='recommends exactly one canonical disposition for each in-scope inventory item'
  recommendation_line='   - The fresh Step 2 critic reviews every in-scope Fast finding and every in-scope Fast-originated changed hunk and recommends exactly one canonical disposition for each in-scope inventory item: retain, revise, replace, superseded, resolved-with-evidence, or policy-valid deferred-with-reason, under [main ECI quality responsibility](#main-eci-quality-responsibility).'
  coordinator_application='The coordinator owns final disposition application/treatment and applies exactly one canonical disposition per in-scope inventory item.'
  provenance='Inventory states retained, revised, non-retained, superseded, and reverted are provenance only, not canonical dispositions; no inventory state implies a disposition.'
  provenance_line='   - '"$provenance"
  retained_fix='The implementer fixes every routed `treatment: now` finding and fixes or justifies every retained Fast finding and every retained Fast-originated change under that selected winner, including no-hunk findings.'
  mutation="${text/"$coordinator_application"/}"
  mutation="${mutation/"$contained_now"/"$contained_now"$'\n   - '"$coordinator_application"}"
  if output="$(assert_post_fast_completion_contract "$mutation" 2>&1)"; then
    fail 'post-Fast ownership-order mutation admitted coordinator application after treatment routing'
  fi
  [[ "$output" == *'post-Fast inventory and repair sequence is out of order'* ]] ||
    fail "unexpected post-Fast ownership-order failure: $output"
  mutation="${text/"$retained_fix"/}"
  mutation="${mutation/"$recommendation_line"/"$retained_fix"$'\n'"$recommendation_line"}"
  if output="$(assert_post_fast_completion_contract "$mutation" 2>&1)"; then
    fail 'post-Fast ownership-order mutation admitted retained-fix before coordinator application'
  fi
  [[ "$output" == *'post-Fast inventory and repair sequence is out of order'* ]] ||
    fail "unexpected post-Fast retained-fix order failure: $output"
  for active_line in \
    "$restart_line" \
    "$scope_line" \
    "$inventory_line" \
    "$provenance_line" \
    "$final_acceptance_line" \
    "$routing_line" \
    "$repair_batch_line" \
    "$contained_now_line" \
    "$revise_replace_line" \
    "$other_dispositions_line" \
    "$defer_line" \
    "$final_evidence_line" \
    "$final_now_line" \
    "$separate_outcome_line"; do
    assert_active_directive_demotions \
      assert_post_fast_completion_contract "$FAST_PATH" "$text" "$active_line" \
      'section is missing active literal directive:'
  done
  for clause in 'has finished its assigned work' 'write-capable tools have stopped' \
    'write-yield, idle label, timeout, or cancellation' 'after Fast completion' \
    'fresh Step 2 critic independently assesses' 'even when no further edits are needed' \
    'normal path remains incomplete' 'Resumed Fast writes invalidate this sequence' \
    'never a clean pass or substitute Fast completion' \
    'Scope-screen every Fast finding and every Fast-originated changed hunk' \
    'exact user source → faithful requested outcome → bounded scope' \
    'Keep only repairs necessary to meet or prove that outcome in scope' \
    'Apply impact-proportional routing before implementation' \
    'Return substantive `now` findings or design/API uncertainty through one complete fresh Steps 1–2 repair batch' \
    'Send a `treatment: now` finding to the implementer once only if it is contained, in-scope, impact-trivial, and isolated' \
    'A coordinator-applied `revise` or `replace` disposition reaches the implementer as `treatment: now` only when it is in-scope, contained, impact-trivial, and isolated' \
    'Other dispositions require evidence, not implementation' \
    'separate-outcome finding stays only a post-ECI observation/follow-up' \
    'Keep every Fast-originated hunk in inventory/review context; do not expand authorization' \
    'enumerates every finding and changed hunk from the Fast owner and its helpers' \
    'findings with no retained hunk' \
    'retained, revised, non-retained, superseded, or reverted' \
    'reconciles the report with shared state' \
    'review context, never a manifest, receipt, or admission/write gate' \
    'every in-scope inventory item to have a disposition and evidence' \
    'reviews each in-scope inventory item' \
    'reviews every in-scope Fast finding and every in-scope Fast-originated changed hunk for quality' \
    'recommends exactly one canonical disposition for each in-scope inventory item' \
    'Step 2 authority is limited to design-winner selection' \
    'does not apply treatment' \
    'owns final disposition application/treatment and applies exactly one canonical disposition per in-scope inventory item' \
    'retain, revise, replace, superseded, resolved-with-evidence, or policy-valid deferred-with-reason' \
    'policy-valid deferred-with-reason only where' \
    'A policy-valid deferred-with-reason disposition is only for an in-scope' \
    'evidence supporting each eligibility condition' \
    'technical reason and revisit trigger; it never waives original criteria' \
    'Missing evidence invalidates only that defer conclusion' \
    'gates unrelated bounded work' \
    'fixes every routed `treatment: now` finding and fixes or justifies every retained Fast finding and every retained Fast-originated change' \
    'including no-hunk findings' \
    'Every no-hunk retain or resolved-with-evidence outcome requires evidence' \
    'Send a `treatment: now` finding to the implementer once only if it is contained, in-scope, impact-trivial, and isolated' \
    'implements those routed coordinator-applied revise/replace changes' \
    'validates retained/revised changes' \
    'supplies evidence for no-hunk resolutions' \
    'supplies evidence for no-hunk resolutions and for non-retained, superseded, reverted, resolved, and deferred outcomes' \
    'verifies every in-scope inventory item has exactly one disposition and final evidence' \
    'no unresolved in-scope `treatment: now` finding' \
    'Separate-outcome observations remain outside acceptance'; do
    mutation="${text/"$clause"/REMOVED}"
    if output="$(assert_post_fast_completion_contract "$mutation" 2>&1)"; then
      fail "post-Fast mutation admitted missing requirement: $clause"
    fi
    [[ "$output" == *'workflow routing assertion failed:'* ]] || fail "unexpected mutation failure: $output"
  done
  for clause in 'retained' 'revised' 'non-retained' 'superseded' 'reverted' \
    'provenance only' 'not canonical dispositions' 'no inventory state implies a disposition'; do
    mutation="${text/"$clause"/REMOVED}"
    if output="$(assert_post_fast_completion_contract "$mutation" 2>&1)"; then
      fail "post-Fast provenance mutation admitted missing rule: $clause"
    fi
    [[ "$output" == *'workflow routing assertion failed:'* ]] ||
      fail "unexpected provenance mutation failure: $clause: $output"
  done
  assert_active_literal_directive_fixtures \
    assert_post_fast_no_active_contradiction "$FAST_PATH" "$text" "$provenance_line" \
    'An inventory state implies its same-named canonical disposition.' 'post-Fast contradiction'
  for state in 'no retained hunk' non-retained superseded reverted resolved deferred; do
    mutation="${text/"$state"/REMOVED}"
    if output="$(assert_post_fast_completion_contract "$mutation" 2>&1)"; then
      fail "post-Fast state mutation admitted missing case: $state"
    fi
    [[ "$output" == *'workflow routing assertion failed:'* ]] ||
      fail "unexpected state mutation failure: $state: $output"
  done
  dispositions='retain, revise, replace, superseded, resolved-with-evidence, or policy-valid deferred-with-reason'
  for replacement in \
    'revise, replace, superseded, resolved-with-evidence, or policy-valid deferred-with-reason' \
    'retain, replace, superseded, resolved-with-evidence, or policy-valid deferred-with-reason' \
    'retain, revise, superseded, resolved-with-evidence, or policy-valid deferred-with-reason' \
    'retain, revise, replace, resolved-with-evidence, or policy-valid deferred-with-reason' \
    'retain, revise, replace, superseded, or policy-valid deferred-with-reason' \
    'retain, revise, replace, superseded, resolved-with-evidence'; do
    mutation="${text/"$dispositions"/"$replacement"}"
    if output="$(assert_post_fast_completion_contract "$mutation" 2>&1)"; then
      fail "post-Fast disposition mutation admitted missing item: $replacement"
    fi
    [[ "$output" == *'workflow routing assertion failed:'* ]] ||
      fail "unexpected disposition mutation failure: $replacement: $output"
  done
  defer_clause='A policy-valid deferred-with-reason disposition is only for an in-scope, non-hard, impact-trivial, isolated finding; it requires evidence supporting each eligibility condition, plus a technical reason and revisit trigger; it never waives original criteria.'
  for missing_defer in 'in-scope' non-hard impact-trivial isolated 'technical reason' 'revisit trigger' 'never waives original criteria'; do
    replacement="${defer_clause/"$missing_defer"/REMOVED}"
    mutation="${text/"$defer_clause"/"$replacement"}"
    if output="$(assert_post_fast_completion_contract "$mutation" 2>&1)"; then
      fail "post-Fast defer mutation admitted missing rule: $missing_defer"
    fi
    [[ "$output" == *'workflow routing assertion failed:'* ]] ||
      fail "unexpected defer mutation failure: $missing_defer: $output"
  done
  defer_evidence_clause='Every no-hunk retain or resolved-with-evidence outcome requires evidence.'
  for missing_evidence in 'no-hunk retain' resolved-with-evidence 'requires evidence'; do
    replacement="${defer_evidence_clause/"$missing_evidence"/REMOVED}"
    mutation="${text/"$defer_evidence_clause"/"$replacement"}"
    if output="$(assert_post_fast_completion_contract "$mutation" 2>&1)"; then
      fail "post-Fast no-hunk evidence mutation admitted missing rule: $missing_evidence"
    fi
    [[ "$output" == *'workflow routing assertion failed:'* ]] ||
      fail "unexpected no-hunk evidence mutation failure: $missing_evidence: $output"
  done
  defer_evidence_clause='Missing evidence invalidates only that defer conclusion; it never waives criteria or gates unrelated bounded work.'
  for missing_evidence in 'invalidates only that defer conclusion' 'never waives criteria' 'gates unrelated bounded work'; do
    replacement="${defer_evidence_clause/"$missing_evidence"/REMOVED}"
    mutation="${text/"$defer_evidence_clause"/"$replacement"}"
    if output="$(assert_post_fast_completion_contract "$mutation" 2>&1)"; then
      fail "post-Fast defer evidence-scope mutation admitted missing rule: $missing_evidence"
    fi
    [[ "$output" == *'workflow routing assertion failed:'* ]] ||
      fail "unexpected defer evidence-scope mutation failure: $missing_evidence: $output"
  done
  inventory_gate='This complete inventory is review context, never a manifest, receipt, or admission/write gate.'
  mutation="${text/"$inventory_gate"/'This complete inventory is an admission/write gate.'}"
  if output="$(assert_post_fast_no_active_contradiction "$FAST_PATH" "$mutation" 'This complete inventory is an admission/write gate.' 2>&1)"; then
    fail 'post-Fast inventory gate pressure fixture was admitted'
  fi
  [[ "$output" == *'admits active post-Fast contradiction'* ]] ||
    fail "unexpected inventory gate pressure failure: $output"
  for contradiction in \
    'A separate-outcome finding creates current repair, review, proof, or acceptance work.' \
    'This complete inventory is an admission/write gate.' \
    'Final Step 4 may leave an unresolved in-scope now finding.' \
    'Step 2 may assign multiple dispositions to an in-scope inventory item.' \
    'The fresh Step 2 critic applies treatment.' \
    'The coordinator applies multiple canonical dispositions per in-scope inventory item.' \
    'A policy-valid deferred-with-reason disposition may apply to a hard finding.'; do
    assert_active_literal_directive_fixtures \
      assert_post_fast_no_active_contradiction "$FAST_PATH" "$text" "$scope_line" \
      "$contradiction" 'post-Fast contradiction'
  done
  base="$scope_clause"
  replacement="${base%.} except when the coordinator approves current work."
  pressure="${text/"$base"/"$replacement"}"
  if output="$(assert_post_fast_completion_contract "$pressure" 2>&1)"; then
    fail 'post-Fast scope suffix pressure fixture was admitted'
  fi
  [[ "$output" == *'workflow routing assertion failed:'* ]] ||
    fail "unexpected scope suffix pressure failure: $output"
  base='A policy-valid deferred-with-reason disposition is only for an in-scope, non-hard, impact-trivial, isolated finding; it requires evidence supporting each eligibility condition, plus a technical reason and revisit trigger; it never waives original criteria.'
  replacement="${base%.} Hard findings may also use this disposition."
  pressure="${text/"$base"/"$replacement"}"
  if output="$(assert_post_fast_completion_contract "$pressure" 2>&1)"; then
    fail 'post-Fast defer suffix pressure fixture was admitted'
  fi
  [[ "$output" == *'workflow routing assertion failed:'* ]] ||
    fail "unexpected defer suffix pressure failure: $output"
  base='This complete inventory is review context, never a manifest, receipt, or admission/write gate.'
  replacement="${base%.} except when a manifest is convenient."
  pressure="${text/"$base"/"$replacement"}"
  if output="$(assert_post_fast_completion_contract "$pressure" 2>&1)"; then
    fail 'post-Fast inventory suffix pressure fixture was admitted'
  fi
  [[ "$output" == *'workflow routing assertion failed:'* ]] ||
    fail "unexpected inventory suffix pressure failure: $output"
  base='final cumulative Step 4 verifies every in-scope inventory item has exactly one disposition and final evidence'
  replacement="$base unless the item was unchanged."
  pressure="${text/"$base"/"$replacement"}"
  if output="$(assert_post_fast_completion_contract "$pressure" 2>&1)"; then
    fail 'post-Fast final-coverage suffix pressure fixture was admitted'
  fi
  [[ "$output" == *'workflow routing assertion failed:'* ]] ||
    fail "unexpected final-coverage suffix pressure failure: $output"
  base='retain, revise, replace, superseded, resolved-with-evidence, or policy-valid deferred-with-reason'
  replacement="$base or skipped"
  pressure="${text/"$base"/"$replacement"}"
  if output="$(assert_post_fast_completion_contract "$pressure" 2>&1)"; then
    fail 'post-Fast disposition suffix pressure fixture was admitted'
  fi
  [[ "$output" == *'workflow routing assertion failed:'* ]] ||
    fail "unexpected disposition suffix pressure failure: $output"
  observation='The coordinator observes that the Fast owner has finished its assigned work, including delegated work, and all task-owned write-capable tools have stopped.'
  report='The Fast owner completion report enumerates every finding and changed hunk from the Fast owner and its helpers.'
  pressure="${text/"$observation"/REMOVED}"
  pressure="${pressure/"$report"/"$report $observation"}"
  if output="$(assert_post_fast_completion_observation_contract "$pressure" 2>&1)"; then
    fail 'post-Fast observation/report pressure fixture admitted swapped order'
  fi
  [[ "$output" == *'completion observation must precede the owner report'* ]] ||
    fail "unexpected observation/report pressure failure: $output"
  pressure="${text//Step 1/removed Step 1}"
  require_section_pattern "$pressure" 'pressure fixture retains a Step 4 candidate substitute' \
    'Step 4 independently reviews the final cumulative scoped state'
  if output="$(assert_post_fast_transition_contract "$pressure" 2>&1)"; then
    fail 'post-Fast transition pressure fixture admitted a Step 4 substitute for Step 1'
  fi
  [[ "$output" == *'post-Fast fresh Step 1 restart'* ]] ||
    fail "unexpected post-Fast transition pressure failure: $output"
  pressure="${text/Any Step 4 review that runs concurrently before this restart is intermediate only and never acceptance./Any Step 4 review that runs concurrently before this restart may be acceptance.}"
  if output="$(assert_post_fast_transition_contract "$pressure" 2>&1)"; then
    fail 'post-Fast transition pressure fixture admitted pre-restart Step 4 acceptance'
  fi
  [[ "$output" == *'concurrent Step 4 is intermediate only'* ]] ||
    fail "unexpected pre-restart Step 4 pressure failure: $output"
  for file in "$ECI" "$COORDINATOR" "$COORDINATOR_RUNTIME" "$ECI_CRITIQUE" \
    "$ROOT/skills/explore-critique-implement/references/explore.md" "$IMPLEMENT" "$REVIEW"; do
    require_text "$file" 'fast-path.md#post-fast-completion'
  done
  require_text "$ECI" \
    'Follow the normative [post-Fast completion sequence](references/fast-path.md#post-fast-completion).'
  require_text "$COORDINATOR" \
    'Follow the normative [post-Fast completion sequence](fast-path.md#post-fast-completion).'
  require_text "$COORDINATOR_RUNTIME" \
    'Follow the normative [post-Fast completion sequence](../../explore-critique-implement/references/fast-path.md#post-fast-completion).'
  require_text "$ECI_CRITIQUE" \
    'Follow the normative [post-Fast completion sequence](fast-path.md#post-fast-completion).'
  require_text "$ROOT/skills/explore-critique-implement/references/explore.md" \
    'Follow the normative [post-Fast completion sequence](fast-path.md#post-fast-completion).'
  require_text "$IMPLEMENT" \
    'Follow the normative [post-Fast completion sequence](fast-path.md#post-fast-completion).'
  require_text "$REVIEW" \
    'Follow the normative [post-Fast completion sequence](fast-path.md#post-fast-completion).'
  forbid_text "$FAST_PATH" 'The Explorer reviews every Fast finding and every retained Fast change'
  forbid_text "$FAST_PATH" 'reviews every Fast finding and every retained Fast change, then selects a concrete disposition'
  critique="$(<"$ECI_CRITIQUE")"
  assert_post_fast_critique_contract "$critique"
  pressure="$critique"$'\n\nFor post-Fast completion, independently assess final current sources and the new Explorer options before selecting the concrete retain, revise, or replace disposition.'
  if output="$(assert_post_fast_critique_contract "$pressure" 2>&1)"; then
    fail 'critique stale three-choice pressure fixture was admitted'
  fi
  [[ "$output" == *'stale three-choice disposition'* ]] ||
    fail "unexpected critique stale three-choice failure: $output"
  for file in "$ECI" "$COORDINATOR" "$COORDINATOR_RUNTIME" "$ECI_CRITIQUE" \
    "$ROOT/skills/explore-critique-implement/references/explore.md" "$IMPLEMENT" "$REVIEW"; do
    forbid_text "$file" 'Fast owner completion report enumerates every finding and changed hunk from the Fast owner and its helpers'
    forbid_text "$file" 'The fresh Step 2 critic gives each inventory item exactly one disposition'
    forbid_text "$file" 'final cumulative Step 4 verifies every inventory item has a disposition and final evidence'
  done
  forbid_text "$FAST_PATH" 'Independent work in the other path is not a completion prerequisite'
}

assert_fast_path_progress_waits() {
  local codex_text fast_text mutation output
  codex_text="$(<"$CODEX")"
  fast_text="$(<"$FAST_PATH")"
  assert_fast_path_progress_wait_contract "$codex_text" "$fast_text"
  mutation="$(sed '/^- Wait only for/d' <<<"$codex_text")"
  if output="$(assert_fast_path_progress_wait_contract "$mutation" "$fast_text" 2>&1)"; then
    fail 'cross-path wait regression admitted the blanket global wait'
  fi
  [[ "$output" == *'dependency-scoped global waits'* ]] || fail "unexpected mutation failure: $output"
  mutation="$(sed "s/ and the next action's dependencies are satisfied//" <<<"$fast_text")"
  if output="$(assert_fast_path_progress_wait_contract "$codex_text" "$mutation" 2>&1)"; then
    fail 'cross-path wait regression admitted unfinished required evidence'
  fi
  [[ "$output" == *'cross-path wait preserves verification and real dependencies'* ]] ||
    fail "unexpected mutation failure: $output"
}

assert_fast_treatment_now_contract_text() {
  local text="$1" eligibility carry final_guard

  eligibility='A coordinator-applied `revise` or `replace` disposition reaches the implementer as `treatment: now` only when it is in-scope, contained, impact-trivial, and isolated; otherwise return through one complete fresh Steps 1–2 design-repair batch before implementation.'
  carry='Carry the resulting disposition and evidence into Step 4; never leave it unresolved.'
  final_guard='The final cumulative Step 4 leaves no unresolved in-scope `treatment: now` finding or failed-eligibility `revise`/`replace` needing implementation.'

  require_text <(printf '%s\n' "$text") "$eligibility"
  require_text <(printf '%s\n' "$text") "$carry"
  require_text <(printf '%s\n' "$text") "$final_guard"
  require_active_literal_directive "$text" 'treatment eligibility is active' "$eligibility"
  require_active_literal_directive "$text" 'disposition and evidence reach Step 4' "$carry"
  require_active_literal_directive "$text" 'final guard rejects unresolved findings' "$final_guard"
  require_order "$text" "$eligibility" "$carry" ||
    fail 'Fast treatment-now eligibility must precede Step 4 evidence carry'
}

assert_fast_treatment_now_contract() {
  local text mutation output clause

  text="$(<"$FAST_PATH")"
  assert_fast_treatment_now_contract_text "$text"
  for clause in \
    'A coordinator-applied `revise` or `replace` disposition reaches the implementer as `treatment: now`' \
    'only when it is in-scope, contained, impact-trivial, and isolated' \
    'one complete fresh Steps 1–2 design-repair batch before implementation' \
    'Carry the resulting disposition and evidence into Step 4' \
    'never leave it unresolved' \
    'or failed-eligibility `revise`/`replace` needing implementation'; do
    mutation="${text/"$clause"/REMOVED}"
    if output="$(assert_fast_treatment_now_contract_text "$mutation" 2>&1)"; then
      fail "Fast treatment-now mutation admitted missing requirement: $clause"
    fi
    [[ "$output" == *'workflow routing assertion failed:'* ]] ||
      fail "unexpected Fast treatment-now mutation failure: $clause: $output"
  done
  for contradiction in \
    'If any eligibility condition fails, send it directly to the implementer.' \
    'The final cumulative Step 4 may leave an unresolved failed-eligibility `revise`/`replace` needing implementation.'; do
    mutation="$text"$'\n\n- '"$contradiction"
    if output="$(assert_fast_treatment_now_no_active_contradiction "$FAST_PATH" "$mutation" "$contradiction" 2>&1)"; then
      fail "Fast treatment-now contradiction was admitted: $contradiction"
    fi
  done
}

assert_fast_treatment_now_no_active_contradiction() {
  local source="$1" input="$2" contradiction="$3"

  if section_has_active_literal_directive "$input" "$contradiction"; then
    fail "$source admits active treatment-now contradiction: $contradiction"
  fi
}

assert_fast_lexer_fixtures() {
  local source="$FAST_PATH" directive output fixture mutation

  directive='Send a `treatment: now` finding to the implementer once only if it is contained, in-scope, impact-trivial, and isolated.'
  for fixture in \
    $'> quoted prose\n- '"$directive" \
    $'> quoted prose\n-  '"$directive" \
    $'> quoted prose\n-\t'"$directive" \
    $'> quoted prose\n- - '"$directive" \
    $'> quoted prose\n```text\ninside\n```\n'"$directive" \
    $'> quoted prose\n- ```text\ninside\n- ```\n'"$directive"; do
    if ! output="$(section_active_literal_directive_line "$fixture" "$directive" 2>&1)"; then
      fail "Fast lexer rejected quote boundary fixture: $fixture: $output"
    fi
  done

  for fixture in \
    $'> quoted prose\n```text\n'"$directive"$'\n```' \
    $'> quoted prose\n- ```text\n'"$directive"$'\n- ```' \
    $'> quoted prose\n> '"$directive" \
    $'> quoted prose\n    '"$directive"; do
    if output="$(section_active_literal_directive_line "$fixture" "$directive" 2>&1)"; then
      fail "Fast lexer admitted inactive boundary fixture: $fixture"
    fi
  done

  for fixture in \
    $'```text\n- ```\n'"$directive" \
    $'```text\n1. ```\n'"$directive" \
    $'```text\n* ```\n'"$directive"; do
    if output="$(section_active_literal_directive_line "$fixture" "$directive" 2>&1)"; then
      fail "Fast lexer admitted root-fence pseudo-closer fixture: $fixture"
    fi
  done

  fixture=$'123456789. '"$directive"
  if ! output="$(section_active_literal_directive_line "$fixture" "$directive" 2>&1)"; then
    fail "Fast lexer rejected nine-digit ordered container fixture: $output"
  fi
  fixture=$'1234567890. '"$directive"
  if output="$(section_active_literal_directive_line "$fixture" "$directive" 2>&1)"; then
    fail 'Fast lexer admitted ten-digit ordered pseudo-container fixture'
  fi

  if ! output="$(section_active_literal_directive_line $'> quoted prose\n>\n'"$directive" "$directive" 2>&1)"; then
    fail "Fast lexer rejected active directive after blank blockquote marker: $output"
  fi

  if ! output="$(section_active_literal_directive_line $'```text`invalid\n'"$directive" "$directive" 2>&1)"; then
    fail "Fast lexer rejected active directive after invalid backtick info: $output"
  fi
  if output="$(section_active_literal_directive_line $'```text\n'"$directive"$'\n```' "$directive" 2>&1)"; then
    fail 'Fast lexer admitted directive inside normal-info fence'
  fi

  for fixture in \
    $'-  '"$directive" \
    $'-\t'"$directive" \
    $'  -  '"$directive" \
    $'  -\t'"$directive" \
    $'- -  '"$directive" \
    $'  -\t- '"$directive"; do
    if ! output="$(section_active_literal_directive_line "$fixture" "$directive" 2>&1)"; then
      fail "Fast lexer rejected normalized container fixture: $fixture: $output"
    fi
  done

  for fixture in \
    $'> lazy quote continuation\n'"$directive" \
    $'- ```text\n'"$directive"$'\n```' \
    $'  1. ~~~text\n'"$directive"$'\n  ~~~' \
    $'> - '"$directive" \
    $'    '"$directive"; do
    if output="$(section_active_literal_directive_line "$fixture" "$directive" 2>&1)"; then
      fail "Fast lexer admitted inactive directive fixture: $fixture"
    fi
  done

  fixture=$'> quoted prose\n\n'
  mutation="$fixture$directive"
  if ! output="$(section_active_literal_directive_line "$mutation" "$directive" 2>&1)"; then
    fail "Fast lexer rejected active directive after blank quote boundary: $output"
  fi

  fixture=$'- ```text\ninside\n```\n\n'
  mutation="$fixture$directive"
  if ! output="$(section_active_literal_directive_line "$mutation" "$directive" 2>&1)"; then
    fail "Fast lexer rejected active directive after list-fence closure boundary: $output"
  fi

  # Step 3 state-machine probes: quote depth and quoted-fence ownership.
  if ! output="$(section_active_literal_directive_line $'> \x60\x60\x60text\n> inside\n> \x60\x60\x60\n'"$directive" "$directive" 2>&1)"; then
    fail "Fast lexer rejected directive after quoted-fence close: $output"
  fi
  if ! output="$(section_active_literal_directive_line $'> prose\n> \x60\x60\x60text\n> inside\n> \x60\x60\x60\n'"$directive" "$directive" 2>&1)" || [[ "$output" != 5 ]]; then
    fail "Fast lexer did not select only the directive after a lazily introduced quoted fence: $output"
  fi
  if output="$(section_active_literal_directive_line $'> \x60\x60\x60text\n> inside\n'"$directive" "$directive" 2>&1)"; then
    fail 'Fast lexer admitted unquoted directive after unclosed quoted fence'
  fi
  if output="$(section_active_literal_directive_line $'> \x60\x60\x60text\n> inside\n\x60\x60\x60\n'"$directive" "$directive" 2>&1)"; then
    fail 'Fast lexer admitted unquoted pseudo-close for quoted fence'
  fi
  if output="$(section_active_literal_directive_line $'> > \x60\x60\x60text\n> > inside\n> \x60\x60\x60\n'"$directive" "$directive" 2>&1)"; then
    fail 'Fast lexer admitted shallower pseudo-close for nested quoted fence'
  fi
  if ! output="$(section_active_literal_directive_line $'> > \x60\x60\x60text\n> > inside\n> > \x60\x60\x60\n'"$directive" "$directive" 2>&1)"; then
    fail "Fast lexer rejected directive after nested quoted-fence close: $output"
  fi

  # Whitespace-only lines terminate lazy quote continuation, but remain fence content.
  if ! output="$(section_active_literal_directive_line $'> quoted prose\n   \n'"$directive" "$directive" 2>&1)"; then
    fail "Fast lexer rejected directive after whitespace-only quote boundary: $output"
  fi
  if ! output="$(section_active_literal_directive_line $'\x60\x60\x60text\n \t\n\x60\x60\x60\n'"$directive" "$directive" 2>&1)"; then
    fail "Fast lexer rejected directive after whitespace-only fence content: $output"
  fi

  # Thematic breaks contain at least three copies of one marker and whitespace only.
  for thematic in '***' '* * *' '** **' $'*\t* *' '___' '_ _ _ _' '---' '- - - -'; do
    if ! output="$(section_active_literal_directive_line $'> quoted prose\n'"$thematic"$'\n'"$directive" "$directive" 2>&1)" || [[ "$output" != 3 ]]; then
      fail "Fast lexer rejected directive after thematic-break boundary: $thematic: $output"
    fi
  done
  for thematic in '* * -' '_ - _' '- - *'; do
    if output="$(section_active_literal_directive_line $'> quoted prose\n'"$thematic"$'\n'"$directive" "$directive" 2>&1)"; then
      fail "Fast lexer admitted mixed-marker thematic-break pseudo-boundary: $thematic"
    fi
  done

  # A list-relative four-space fence is active; standalone four-space code is not.
  if output="$(section_active_literal_directive_line $'-    \x60\x60\x60text\n-    inside\n- -    \x60\x60\x60\n'"$directive" "$directive" 2>&1)"; then
    fail 'Fast lexer admitted directive after unclosed list-relative fence'
  fi
  if ! output="$(section_active_literal_directive_line $'-    \x60\x60\x60text\n-    inside\n-    \x60\x60\x60\n'"$directive" "$directive" 2>&1)"; then
    fail "Fast lexer rejected directive after list-relative four-space fence: $output"
  fi
  if output="$(section_active_literal_directive_line $'    code\n    '"$directive" "$directive" 2>&1)"; then
    fail 'Fast lexer admitted standalone indented-code directive'
  fi
  if output="$(section_active_literal_directive_line $'    \x60\x60\x60text\n    '"$directive"$'\n    \x60\x60\x60' "$directive" 2>&1)"; then
    fail 'Fast lexer admitted directive inside standalone four-space fence-shaped code'
  fi
  if ! output="$(section_active_literal_directive_line $'    code\n\n'"$directive" "$directive" 2>&1)"; then
    fail "Fast lexer rejected directive after indented-code boundary: $output"
  fi

  # List fences close at their own depth or a root-dedent, never at a nested marker.
  if output="$(section_active_literal_directive_line $'- \x60\x60\x60text\n- inside\n- - \x60\x60\x60\n'"$directive" "$directive" 2>&1)"; then
    fail 'Fast lexer admitted nested list pseudo-closer for list fence'
  fi
  if ! output="$(section_active_literal_directive_line $'- \x60\x60\x60text\n- inside\n\x60\x60\x60\n'"$directive" "$directive" 2>&1)"; then
    fail "Fast lexer rejected root-dedent list-fence close: $output"
  fi

  # A continuation fence uses the list item's path; three relative spaces
  # remain valid for its closer, while a nested list marker cannot close it.
  if ! output="$(section_active_literal_directive_line $'- item\n    \x60\x60\x60text\n'"$directive"$'\n       \x60\x60\x60\n'"$directive" "$directive" 2>&1)" || [[ "$output" != 5 ]]; then
    fail "Fast lexer did not select only the directive after a list-relative continuation fence: $output"
  fi
  if output="$(section_active_literal_directive_line $'- item\n    \x60\x60\x60text\n'"$directive"$'\n    - \x60\x60\x60\n'"$directive" "$directive" 2>&1)"; then
    fail 'Fast lexer admitted nested list pseudo-closer for continuation fence'
  fi
  if output="$(section_active_literal_directive_line $'- item\n    ~~~text\n'"$directive"$'\n- sibling\n    ~~~\n'"$directive" "$directive" 2>&1)"; then
    fail 'Fast lexer admitted directive inside a sibling continuation fence'
  fi
  if output="$(section_active_literal_directive_line $'> - item\n    '"$directive" "$directive" 2>&1)"; then
    fail 'Fast lexer leaked quoted-list continuation state into root indented code'
  fi
  if ! output="$(section_active_literal_directive_line $'- outer\n    - child\n        ~~~text\n        inside\n    - sibling\n        ~~~\n        '"$directive"$'\n        ~~~\n'"$directive" "$directive" 2>&1)" || [[ "$output" != 9 ]]; then
    fail "Fast lexer did not close a nested continuation fence at a same-indent sibling transition: $output"
  fi
  for thematic in '* * *' '- - -'; do
    if output="$(section_active_literal_directive_line "$thematic"$'\n    '"$directive" "$directive" 2>&1)"; then
      fail "Fast lexer let thematic list state activate root indented code: $thematic"
    fi
  done

  # Mutations must flip only the guard under test.
  mutation=$'> \x60\x60\x60text\n> inside\n\x60\x60\x60\n'"$directive"
  if output="$(section_active_literal_directive_line "$mutation" "$directive" 2>&1)"; then
    fail 'Fast lexer admitted mutation removing the quoted-fence close marker'
  fi
  mutation=$'> quoted prose\n* * -\n'"$directive"
  if output="$(section_active_literal_directive_line "$mutation" "$directive" 2>&1)"; then
    fail 'Fast lexer admitted mutation widening the thematic-break boundary'
  fi
  mutation=$'- item\n    \x60\x60\x60text\n'"$directive"$'\n        \x60\x60\x60\n'"$directive"
  if output="$(section_active_literal_directive_line "$mutation" "$directive" 2>&1)"; then
    fail 'Fast lexer admitted mutation indenting a continuation-fence closer beyond three relative spaces'
  fi
  mutation=$'- \x60\x60\x60text\n- inside\n- - \x60\x60\x60\n'"$directive"
  if output="$(section_active_literal_directive_line "$mutation" "$directive" 2>&1)"; then
    fail 'Fast lexer admitted mutation using a nested list pseudo-closer'
  fi
}

assert_concurrent_task_contract() {
  local input="$1" clause
  for clause in \
    'Admit independent user-requested tasks as separate owned lanes under the active lifecycle' \
    'Queue only work with an unmet dependency, conflicting writes, or unavailable agent capacity' \
    'A discovered separate-outcome concern still needs user authorization' \
    'A task clean pass does not close a root with unfinished sibling tasks' \
    'Direct work and ATE outside ECI retain their existing lifecycle and wait rules' \
    'nonconflicting work in the same file, with target rereads' \
    'Serialize conflicting writes and shared Git-index mutations through coordinator ownership handoffs' \
    'continue disjoint work, including nonconflicting work in the same file' \
    'Later interacting changes invalidate affected acceptance evidence; refresh that review and verification before final root closure' \
    'The coordinator orders cross-task conflicts' \
    'Preserve all required review/E2E evidence before accepting its target'; do
    require_section_pattern "$input" "concurrent task contract: $clause" "$clause"
  done
  if [[ "$input" == *'| Unrelated request | Queue a separate root until the active root closes'* ||
        "$input" == *'- If main waits on agents, await every still-running in-scope subagent before using results'* ]]; then
    fail 'concurrent task contract retains blanket serialization'
  fi
}

assert_concurrent_tasks() {
  local input mutation output clause
  input="$(<"$CODEX")"
  assert_concurrent_task_contract "$input"
  for clause in \
    'Admit independent user-requested tasks as separate owned lanes under the active lifecycle' \
    'Queue only work with an unmet dependency, conflicting writes, or unavailable agent capacity' \
    'A discovered separate-outcome concern still needs user authorization' \
    'A task clean pass does not close a root with unfinished sibling tasks' \
    'Direct work and ATE outside ECI retain their existing lifecycle and wait rules' \
    'nonconflicting work in the same file, with target rereads' \
    'Serialize conflicting writes and shared Git-index mutations through coordinator ownership handoffs' \
    'continue disjoint work, including nonconflicting work in the same file' \
    'Later interacting changes invalidate affected acceptance evidence; refresh that review and verification before final root closure' \
    'The coordinator orders cross-task conflicts' \
    'Preserve all required review/E2E evidence before accepting its target'; do
    mutation="${input/"$clause"/}"
    if output="$(assert_concurrent_task_contract "$mutation" 2>&1)"; then
      fail "concurrent task mutation admitted removed rule: $clause"
    fi
    [[ "$output" == *'concurrent task contract'* ]] || fail "unexpected mutation failure: $output"
  done
  mutation="$input | Unrelated request | Queue a separate root until the active root closes"
  if output="$(assert_concurrent_task_contract "$mutation" 2>&1)"; then
    fail 'concurrent task mutation admitted blanket root queue'
  fi
  [[ "$output" == *'blanket serialization'* ]] || fail "unexpected mutation failure: $output"
}

assert_task_root_closure_contract() {
  local coordinator_text="$1" fast_text="$2"
  require_section_pattern "$coordinator_text" 'root-only coordinator teardown' \
    'On root clean pass or root user closure:'
  require_section_pattern "$fast_text" 'task-owned shutdown on either closure path' \
    'either closure path.*both producers and their task-owned write-capable tools stopped or finished'
  require_section_pattern "$fast_text" 'root-only Fast teardown follows normative scheduling' \
    'Root teardown and marker removal follow.*CODEX.md#concurrent-tasks'
  [[ "$coordinator_text" != *'On clean pass or user closure:'* &&
     "$fast_text" != *'performs normal user-closure teardown'* ]] ||
    fail 'task closure still triggers root teardown'
}

assert_task_root_closure() {
  local coordinator_text fast_text mutation output
  coordinator_text="$(<"$COORDINATOR")"
  fast_text="$(<"$FAST_PATH")"
  assert_task_root_closure_contract "$coordinator_text" "$fast_text"
  mutation="${coordinator_text/On root clean pass or root user closure:/On clean pass or user closure:}"
  if output="$(assert_task_root_closure_contract "$mutation" "$fast_text" 2>&1)"; then
    fail 'task closure mutation admitted task-triggered coordinator teardown'
  fi
  [[ "$output" == *'root-only coordinator teardown'* ]] || fail "unexpected mutation failure: $output"
  mutation="${fast_text/Root teardown and marker removal follow/Task teardown and marker removal follow}"
  if output="$(assert_task_root_closure_contract "$coordinator_text" "$mutation" 2>&1)"; then
    fail 'task closure mutation admitted task-triggered Fast teardown'
  fi
  [[ "$output" == *'root-only Fast teardown'* ]] || fail "unexpected mutation failure: $output"
}

assert_concurrency_section_placement() {
  local section
  section="$(awk '
    /^### Concurrent tasks$/ { capture = 1; next }
    capture && /^##? / { exit }
    capture { print }
  ' "$CODEX")"
  [[ "$section" == *'Run independent ready tasks concurrently'* ]] || fail 'missing concurrency section'
  [[ "$section" != *'Without an active ECI/ATE root'* && "$section" != *'Inferred condition'* ]] ||
    fail 'concurrency section contains root workflow selection'
}

assert_go_preference() {
  require_text "$ATE" 'concrete failure diagnosis uses debugging-discipline first.'
  require_text "$ROOT/CODEX.md" '- Use Go, not Python, for new code, scripts, helpers, and tooling. Do not port existing Python solely to apply this preference.'
  require_text "$ROOT/CODEX.md" '| Debugging/test failures/unexpected behavior/performance/build failures | `debugging-discipline` |'
}

assert_status_lane_stage_contract() {
  local header
  header="$(grep -F -- '| Task ID | Parent ID | Lane | Lane requirement context | Stage | Owner |' "$STATUS_REPORT" || true)"
  [ -n "$header" ] || fail 'status report lane table is missing the Stage column'
  [[ "$header" == *'| Stage |'* ]] || fail 'status report lane table does not expose Stage'

  require_text "$STATUS_REPORT" 'Missing, stale, or unknown stage metadata is reported and reconciled'
  require_text "$STATUS_REPORT" 'without pausing harmless work.'
  require_text "$STATUS_REPORT" 'lineage unavailable—reconcile'
  require_text "$STATUS_REPORT" 'In material ECI status, show `exact user source → faithful requested outcome → bounded scope` in readable form.'
  require_text "$STATUS_REPORT" 'Never delay a report to construct aliases, hashes, receipts, or verbatim'
  require_text "$STATUS_REPORT" 'registries.'
  forbid_text "$STATUS_REPORT" 'Unresolved or empty refs fail the report.'
  forbid_text "$STATUS_REPORT" 'Every reported lane includes non-empty refs'
  forbid_pattern "$STATUS_REPORT" 'lineage.*(must|shall|needs? to).*(resolve|validate|admit).*(report|work)'
  forbid_pattern "$STATUS_REPORT" '(registry|hash|receipt).*(must|shall|needs? to).*(report|work)'

  # Preserve the existing status meanings while adding the lane-stage field.
  require_text "$STATUS_REPORT" 'Status vocabulary | In each status column, use only `NEW`, `IN PROGRESS`, `PAUSED`, `BLOCKED`, `CLOSED`.'
  require_text "$STATUS_REPORT" 'Implementation Status | Covers exploration, RCA, design, code changes, code review, build checks, unit/component/integration auto-tests, and source-level readiness.'
  require_text "$STATUS_REPORT" 'Test Status | Covers E2E validation in the non-production test environment'
  require_text "$STATUS_REPORT" 'Prod Status | Covers E2E validation in production'
  require_text "$STATUS_REPORT" 'Lane closure | A lane is finished only when the required highest environment column is `CLOSED`.'
  require_text "$STATUS_REPORT" 'RCA/fix closure | For bug/debug lanes, missing, failing, or not-runnable domain-required acceptance proof keeps RCA/fix open.'
  require_text "$STATUS_REPORT" '| `PAUSED` | Use only when this lane'
  require_text "$STATUS_REPORT" 'next required action is progress from another in-scope lane.'
  require_text "$STATUS_REPORT" '| `BLOCKED` | Use only when this lane cannot make any more progress until the user provides a named input or decision.'
}

assert_status_lane_stage_transition_fixture() {
  require_text "$STATUS_REPORT" 'For ECI, record `Stage: normal`.'
  require_text "$STATUS_REPORT" 'Stage records never authorize work or change'
  require_text "$STATUS_REPORT" 'the implementation/test/production status meanings below.'
  forbid_text "$STATUS_REPORT" 'Stage: emergency'
  forbid_pattern "$STATUS_REPORT" 'stage.*(must|shall|needs? to).*(record|transition|authorize).*(work|report)'
}

require_forecast_source_pattern() {
  local source="$1" description="$2" pattern="$3" input="$4" text

  text="$(tr '\n' ' ' <<<"$input")"
  grep -Eiq -- "$pattern" <<<"$text" ||
    fail "$source is missing forecast source contract: $description"
}

require_forecast_source_multiline_pattern() {
  local source="$1" description="$2" pattern="$3" input="$4"
  local normalized_input normalized_pattern

  normalized_input="${input,,}"
  normalized_pattern="${pattern,,}"
  [[ "$normalized_input" =~ $normalized_pattern ]] ||
    fail "$source is missing forecast source contract: $description"
}

forbid_forecast_source_multiline_pattern() {
  local source="$1" description="$2" pattern="$3" input="$4"
  local normalized_input normalized_pattern

  normalized_input="${input,,}"
  normalized_pattern="${pattern,,}"
  if [[ "$normalized_input" =~ $normalized_pattern ]]; then
    fail "$source violates forecast source contract: $description"
  fi
}

forbid_forecast_source_pattern() {
  local source="$1" description="$2" pattern="$3" input="$4" text

  text="$(tr '\n' ' ' <<<"$input")"
  ! grep -Eiq -- "$pattern" <<<"$text" ||
    fail "$source violates forecast source contract: $description"
}

forbid_forecast_source_line_pattern() {
  local source="$1" description="$2" pattern="$3" input="$4"

  ! grep -Eiq -- "$pattern" <<<"$input" ||
    fail "$source violates forecast source contract: $description"
}

assert_forecast_source_contract() {
  local source="$1" input="$2"
  local canonical_lane_code canonical_root_code canonical_lane_directive canonical_root_directive
  local lane_post_period_addition root_post_period_addition
  local role_or_stage inline_lane_role_or_stage direct_lane_role_or_stage
  local inline_root_additive direct_root_additive

  canonical_lane_code='`[[:space:]]*Forecast[[:space:]]+deadline:[[:space:]]+<named[[:space:]]+lane/task[[:space:]]+outcome>[[:space:]]+will[[:space:]]+be[[:space:]]+finished[[:space:]]+by[[:space:]]+<UTC[[:space:]]+ISO8601>\.[[:space:]]*`'
  canonical_root_code='`[[:space:]]*Root[[:space:]]+completion[[:space:]]+forecast:[[:space:]]+<named[[:space:]]+active[[:space:]]+root-task[[:space:]]+outcome>[[:space:]]+will[[:space:]]+be[[:space:]]+finished[[:space:]]+by[[:space:]]+<UTC[[:space:]]+ISO8601>\.[[:space:]]*`'
  canonical_lane_directive='(^|'$'\n'')[[:blank:]]*Forecast[[:space:]]+deadline:[[:space:]]+<named[[:space:]]+lane/task[[:space:]]+outcome>[[:space:]]+will[[:space:]]+be[[:space:]]+finished[[:space:]]+by[[:blank:]]*('$'\n''[[:blank:]]*)?<UTC[[:space:]]+ISO8601>\.[[:blank:]]*('$'\n''|$)'
  canonical_root_directive='(^|'$'\n'')[[:blank:]]*Root[[:space:]]+completion[[:space:]]+forecast:[[:space:]]+<named[[:space:]]+active[[:space:]]+root-task[[:space:]]+outcome>[[:space:]]+will[[:space:]]+be[[:space:]]+finished[[:space:]]+by[[:blank:]]*('$'\n''[[:blank:]]*)?<UTC[[:space:]]+ISO8601>\.[[:blank:]]*('$'\n''|$)'
  lane_post_period_addition='`[[:space:]]*Forecast[[:space:]]+deadline:[[:space:]]+<named[[:space:]]+lane/task[[:space:]]+outcome>[[:space:]]+will[[:space:]]+be[[:space:]]+finished[[:space:]]+by[[:space:]]+<UTC[[:space:]]+ISO8601>\.[[:space:]]*[^`[:space:]][^`]*`'
  root_post_period_addition='`[[:space:]]*Root[[:space:]]+completion[[:space:]]+forecast:[[:space:]]+<named[[:space:]]+active[[:space:]]+root-task[[:space:]]+outcome>[[:space:]]+will[[:space:]]+be[[:space:]]+finished[[:space:]]+by[[:space:]]+<UTC[[:space:]]+ISO8601>\.[[:space:]]*[^`[:space:]][^`]*`'
  role_or_stage='(explorer|implementer|coordinator|e2e|critic([[:blank:]]+(a|b|c)|[-[:blank:]]*step[[:blank:]]*2)?|step[[:blank:]]*2[[:blank:]]+critic|fast[[:blank:]]+owner|brainstormer|feasibility[[:blank:]]+validator|loop-breaker|reviewer|actor|stage([[:blank:]]*:[[:blank:]]*[^[:space:]]+)?)'
  inline_lane_role_or_stage='`[[:space:]]*Forecast[[:space:]]+deadline:[[:space:]]+'
  inline_lane_role_or_stage+="$role_or_stage"
  inline_lane_role_or_stage+='[[:space:]]+will[[:space:]]+be[[:space:]]+finished[[:space:]]+by[[:space:]]+<UTC[[:space:]]+ISO8601>\.[[:space:]]*`'
  direct_lane_role_or_stage='(^|'$'\n'')[[:blank:]]*Forecast[[:space:]]+deadline:[[:space:]]+'
  direct_lane_role_or_stage+="$role_or_stage"
  direct_lane_role_or_stage+='[[:blank:]]+will[[:blank:]]+be[[:blank:]]+finished[[:blank:]]+by[[:blank:]]*('$'\n''[[:blank:]]*)?<UTC[[:space:]]+ISO8601>\.[[:blank:]]*('$'\n''|$)'
  inline_root_additive='`[[:space:]]*Root[[:space:]]+completion[[:space:]]+forecast:[[:space:]]+<named[[:space:]]+active[[:space:]]+root-task[[:space:]]+outcome>[[:space:]]+will[[:space:]]+be[[:space:]]+finished[[:space:]]+by[[:space:]]+<UTC[[:space:]]+ISO8601>\.[[:space:]]*(It[[:space:]]+)?(is|means)[[:space:]]+[^`]*((sum|summed)[[:space:]]+[^`]*(child|children))[^`]*`'
  direct_root_additive='(^|'$'\n'')[[:blank:]]*Root[[:space:]]+completion[[:space:]]+forecast:[[:space:]]+<named[[:space:]]+active[[:space:]]+root-task[[:space:]]+outcome>[[:space:]]+will[[:space:]]+be[[:space:]]+finished[[:space:]]+by[[:blank:]]*('$'\n''[[:blank:]]*)?<UTC[[:space:]]+ISO8601>\.[[:blank:]]*('$'\n''[[:blank:]]*)?(It[[:blank:]]+)?(is|means)[[:blank:]]+.*((sum|summed)[[:blank:]]+.*(child|children))'

  require_forecast_source_pattern "$source" 'standalone named-outcome lane deadline template' "$canonical_lane_code" "$input"
  require_forecast_source_pattern "$source" 'standalone active-root deadline template' "$canonical_root_code" "$input"
  forbid_forecast_source_pattern "$source" 'post-period lane deadline addition' "$lane_post_period_addition" "$input"
  forbid_forecast_source_pattern "$source" 'post-period root deadline addition' "$root_post_period_addition" "$input"
  forbid_forecast_source_line_pattern "$source" 'same-line lane deadline addition' "${canonical_lane_code}[[:space:]]*[^[:space:]|<]" "$input"
  forbid_forecast_source_line_pattern "$source" 'same-line root deadline addition' "${canonical_root_code}[[:space:]]*[^[:space:]|<]" "$input"
  forbid_forecast_source_pattern "$source" 'role or stage in an inline lane deadline template' "$inline_lane_role_or_stage" "$input"
  forbid_forecast_source_multiline_pattern "$source" 'role or stage in a complete direct lane deadline template' "$direct_lane_role_or_stage" "$input"
  forbid_forecast_source_pattern "$source" 'additive root completion in an inline root deadline template' "$inline_root_additive" "$input"
  forbid_forecast_source_multiline_pattern "$source" 'additive root completion in a complete direct root deadline template' "$direct_root_additive" "$input"
  forbid_forecast_source_multiline_pattern "$source" 'unquoted direct lane deadline template' "$canonical_lane_directive" "$input"
  forbid_forecast_source_multiline_pattern "$source" 'unquoted direct root deadline template' "$canonical_root_directive" "$input"
}

assert_coordinator_progress_forecast_contract() {
  local source="$1" input="$2" section attached_lane_template attached_root_template

  attached_lane_template='For[[:space:]]+every[[:space:]]+relevant[[:space:]]+coordinator-to-user[[:space:]]+ECI[[:space:]]+progress[[:space:]]+update,[[:space:]]+report[[:space:]]+this[[:space:]]+standalone[[:space:]]+line[[:space:]]+for[[:space:]]+each[[:space:]]+executing[[:space:]]+lane:[[:blank:]]*'$'\n''[[:blank:]]*[-*][[:blank:]]*`[[:space:]]*Forecast[[:space:]]+deadline:[[:space:]]+<named[[:space:]]+lane/task[[:space:]]+outcome>[[:space:]]+will[[:space:]]+be[[:space:]]+finished[[:space:]]+by[[:space:]]+<UTC[[:space:]]+ISO8601>\.[[:space:]]*`'
  attached_root_template='For[[:space:]]+each[[:space:]]+unrepresented[[:space:]]+active[[:space:]]+root-task[[:space:]]+outcome[[:space:]]+omitted[[:space:]]+by[[:space:]]+lane[[:space:]]+reports,[[:space:]]+include[[:space:]]+this[[:space:]]+standalone[[:space:]]+line:[[:space:]]+[-*][[:space:]]*`[[:space:]]*Root[[:space:]]+completion[[:space:]]+forecast:[[:space:]]+<named[[:space:]]+active[[:space:]]+root-task[[:space:]]+outcome>[[:space:]]+will[[:space:]]+be[[:space:]]+finished[[:space:]]+by[[:space:]]+<UTC[[:space:]]+ISO8601>\.[[:space:]]*`'

  section="$(extract_h2_section <(printf '%s\n' "$input") '## Engage and route')" ||
    fail "$source is missing forecast source contract: bounded Engage and route policy block"
  require_forecast_source_multiline_pattern "$source" 'active Engage and route policy binds every relevant coordinator progress update to each executing lane deadline template' "$attached_lane_template" "$section"
  require_forecast_source_multiline_pattern "$source" 'active Engage and route policy binds each unrepresented root outcome to its root completion forecast template' "$attached_root_template" "$section"
}

assert_forecast_source_fixture_is_permitted() {
  local source="$1" description="$2" input="$3" output

  if output="$(assert_forecast_source_contract "$source" "$input" 2>&1)"; then
    :
  else
    fail "forecast source fixture was rejected: $source: $description: $output"
  fi
}

assert_forecast_source_mutation_is_rejected() {
  local source="$1" description="$2" input="$3" output

  if output="$(assert_forecast_source_contract "$source" "$input" 2>&1)"; then
    fail "forecast source mutation was admitted: $source: $description"
  fi
  grep -Fq -- 'forecast source contract' <<<"$output" ||
    fail "forecast source mutation was rejected for an unexpected reason: $source: $description"
}

assert_coordinator_progress_forecast_mutation_is_rejected() {
  local source="$1" description="$2" input="$3" output

  if output="$(assert_coordinator_progress_forecast_contract "$source" "$input" 2>&1)"; then
    fail "coordinator progress forecast mutation was admitted: $source: $description"
  fi
  grep -Fq -- 'forecast source contract' <<<"$output" ||
    fail "coordinator progress forecast mutation was rejected for an unexpected reason: $source: $description"
}

assert_forecast_source_contract_fixtures() {
  local soft_wrapped separate_advisory ordinary_explanation bulleted_explanation
  local inline_malformed inline_stage direct_stage direct_additive_root
  local wrapped_direct_stage wrapped_direct_additive_root outcome
  local -a invalid_lane_outcomes=(
    Explorer
    Implementer
    Coordinator
    E2E
    'Critic A'
    'Critic B'
    'Critic C'
    'Step 2 critic'
    'Fast owner'
    Brainstormer
    'Feasibility validator'
    'Loop-breaker'
    Reviewer
    Actor
  )

  soft_wrapped=$'`Forecast deadline: <named lane/task outcome> will be finished by\n<UTC ISO8601>.`\n`Root completion forecast: <named active root-task outcome> will be finished by\n<UTC ISO8601>.`'
  separate_advisory="$soft_wrapped"$'\n\nForecasts are advisory and do not gate work.'
  ordinary_explanation="$soft_wrapped"$'\n\nOrdinary explanatory prose may mention Forecast deadline: Critic B will be finished by <UTC ISO8601>. and Root completion forecast: an outcome is the sum of child forecasts as invalid examples.'
  bulleted_explanation="$soft_wrapped"$'\n\n- Forecast deadline: Coordinator will be finished by <UTC ISO8601>. is an invalid example.\n- Root completion forecast: <named active root-task outcome> will be finished by <UTC ISO8601>. It is the sum of child forecasts as an invalid example.'
  inline_malformed="$soft_wrapped"$'\n\n`Forecast deadline: Critic B will be finished by <UTC ISO8601>.`'
  inline_stage="$soft_wrapped"$'\n\n`Forecast deadline: Stage: normal will be finished by <UTC ISO8601>.`'
  direct_stage="$soft_wrapped"$'\n\nForecast deadline: Stage: normal will be finished by <UTC ISO8601>.'
  direct_additive_root="$soft_wrapped"$'\n\nRoot completion forecast: <named active root-task outcome> will be finished by <UTC ISO8601>. It is the sum of child forecasts.'
  wrapped_direct_stage="$soft_wrapped"$'\n\nForecast deadline: Stage: normal will be finished by\n<UTC ISO8601>.'
  wrapped_direct_additive_root="$soft_wrapped"$'\n\nRoot completion forecast: <named active root-task outcome> will be finished by\n<UTC ISO8601>.\nIt is the sum of child forecasts.'

  assert_forecast_source_contract 'soft-wrap fixture' "$soft_wrapped"
  assert_forecast_source_contract 'separate-advisory fixture' "$separate_advisory"
  assert_forecast_source_fixture_is_permitted 'ordinary explanatory-prose fixture' 'ordinary prose names invalid examples' "$ordinary_explanation"
  assert_forecast_source_mutation_is_rejected 'inline malformed deadline fixture' 'actor lane outcome' "$inline_malformed"
  assert_forecast_source_mutation_is_rejected 'inline malformed deadline fixture' 'stage lane outcome' "$inline_stage"

  for outcome in "${invalid_lane_outcomes[@]}"; do
    assert_forecast_source_mutation_is_rejected 'inline role deadline fixture' "$outcome lane outcome" \
      "$soft_wrapped"$'\n\n`Forecast deadline: '"$outcome"$' will be finished by <UTC ISO8601>.`'
    assert_forecast_source_mutation_is_rejected 'direct role deadline fixture' "$outcome lane outcome" \
      "$soft_wrapped"$'\n\nForecast deadline: '"$outcome"$' will be finished by <UTC ISO8601>.'
    assert_forecast_source_mutation_is_rejected 'wrapped direct role deadline fixture' "$outcome lane outcome" \
      "$soft_wrapped"$'\n\nForecast deadline: '"$outcome"$' will be finished by\n<UTC ISO8601>.'
  done

  assert_forecast_source_mutation_is_rejected 'direct malformed deadline fixture' 'stage lane outcome' "$direct_stage"
  assert_forecast_source_mutation_is_rejected 'direct malformed root fixture' 'additive root completion' "$direct_additive_root"
  assert_forecast_source_mutation_is_rejected 'wrapped direct malformed deadline fixture' 'stage lane outcome' "$wrapped_direct_stage"
  assert_forecast_source_mutation_is_rejected 'wrapped direct malformed root fixture' 'additive root completion' "$wrapped_direct_additive_root"
  assert_forecast_source_fixture_is_permitted 'bulleted explanatory-prose fixture' 'bulleted lane and root examples' "$bulleted_explanation"
}

assert_coordinator_progress_forecast_contract_fixtures() {
  local source source_pair soft_wrapped_pair detached_pair history_rehomed soft_wrapped

  source="$(<"$COORDINATOR")"
  source_pair=$'- For every relevant coordinator-to-user ECI progress update, report this standalone line for each executing lane:\n  - `Forecast deadline: <named lane/task outcome> will be finished by <UTC ISO8601>.`\n- For each unrepresented active root-task outcome omitted by lane reports, include this standalone line:\n  - `Root completion forecast: <named active root-task outcome> will be finished by <UTC ISO8601>.`'
  soft_wrapped_pair=$'- For every relevant coordinator-to-user ECI progress update, report this standalone line for each executing lane:\n  - `Forecast deadline: <named lane/task outcome> will be finished by\n<UTC ISO8601>.`\n- For each unrepresented active root-task outcome omitted by lane reports, include this standalone line:\n  - `Root completion forecast: <named active root-task outcome> will be finished by\n<UTC ISO8601>.`'
  detached_pair=$'- For every relevant coordinator-to-user ECI progress update, report this standalone line for each executing lane:\n  - See the historical appendix.\n- For each unrepresented active root-task outcome omitted by lane reports, include this standalone line:\n  - See the historical appendix.'
  soft_wrapped="${source/"$source_pair"/"$soft_wrapped_pair"}"
  [ "$soft_wrapped" != "$source" ] || fail 'coordinator soft-wrap fixture did not replace the attached lane template'
  assert_coordinator_progress_forecast_contract 'soft-wrapped coordinator lane binding fixture' "$soft_wrapped"

  history_rehomed="${source/"$source_pair"/"$detached_pair"}"$'\n\n## Historical appendix\n\n'"$source_pair"
  [ "$history_rehomed" != "$source" ] || fail 'coordinator history-rehome fixture did not replace the active pair'
  assert_forecast_source_contract 'history-rehomed coordinator pair generic fixture' "$history_rehomed"
  assert_coordinator_progress_forecast_mutation_is_rejected "$COORDINATOR" 'full coordinator pair rehomed to history' "$history_rehomed"
}

assert_source_forecast_mutations_are_rejected() {
  local file source lane_post_period_addition root_post_period_addition actor stage additive

  for file in "$COORDINATOR" "$LEDGER" "$STATUS_REPORT"; do
    source="$(<"$file")"
    lane_post_period_addition="$source"$'\n\n`Forecast deadline: <named lane/task outcome> will be finished by <UTC ISO8601>. Additional detail.`'
    root_post_period_addition="$source"$'\n\n`Root completion forecast: <named active root-task outcome> will be finished by <UTC ISO8601>. Additional detail.`'
    actor="$source"$'\n\n`Forecast deadline: Critic B will be finished by <UTC ISO8601>.`'
    stage="$source"$'\n\n`Forecast deadline: Stage: normal will be finished by <UTC ISO8601>.`'
    additive="$source"$'\n\n`Root completion forecast: <named active root-task outcome> will be finished by <UTC ISO8601>. It is the sum of child forecasts.`'

    assert_forecast_source_mutation_is_rejected "$file" 'post-period lane deadline addition' "$lane_post_period_addition"
    assert_forecast_source_mutation_is_rejected "$file" 'post-period root deadline addition' "$root_post_period_addition"
    assert_forecast_source_mutation_is_rejected "$file" 'actor lane outcome' "$actor"
    assert_forecast_source_mutation_is_rejected "$file" 'stage lane outcome' "$stage"
    assert_forecast_source_mutation_is_rejected "$file" 'additive root completion' "$additive"
  done
}

require_forecast_target_history_text() {
  local source="$1" description="$2" expected="$3" input="$4"

  [[ "$input" == *"$expected"* ]] ||
    fail "$source is missing forecast target history contract: $description"
}

forbid_forecast_target_history_text() {
  local source="$1" description="$2" forbidden="$3" input="$4"

  [[ "$input" != *"$forbidden"* ]] ||
    fail "$source violates forecast target history contract: $description"
}

assert_forecast_target_history_ledger_contract() {
  local source="$1" input="$2" header

  header=$'added_utc\troot_task_id\tnew_target_utc\treason'
  require_forecast_target_history_text "$source" 'canonical history name' \
    '`forecast-target-history.tsv` is the canonical audit-only history for root-task forecast targets. It has exactly four columns:' "$input"
  require_forecast_target_history_text "$source" 'exact four-column TSV header' "$header" "$input"
  require_forecast_target_history_text "$source" 'concise human-readable target reason' \
    'Every row records the UTC addition time, root task ID, new UTC target, and a concise human-readable reason for setting or changing the target.' "$input"
  require_forecast_target_history_text "$source" 'append-only rows' \
    'Append only: never edit, delete, reorder, or reuse a row.' "$input"
  require_forecast_target_history_text "$source" 'none-to-A transition' \
    '| none → A | Append a material `high_level_log.md` entry naming A, why, and evidence. | Append A row with reason. |' "$input"
  require_forecast_target_history_text "$source" 'A-to-B transition' \
    '| A → B | Append a material `high_level_log.md` entry naming prior A, new B, why, and evidence. | Append B row with reason. |' "$input"
  require_forecast_target_history_text "$source" 'A-to-A reaffirmation rule' \
    '| A → A | No high-level-log entry or history row for mere reaffirmation. | No row. |' "$input"
  require_forecast_target_history_text "$source" 'close row rule' \
    '| close | Record material completion normally. | No date row. |' "$input"
  require_forecast_target_history_text "$source" 'append-only correction rule' \
    '| correction | Append a correction naming the prior entry and corrected target. | Append the corrected-target row with reason; never rewrite earlier rows. |' "$input"
  require_forecast_target_history_text "$source" 'audit-only non-gate boundary' \
    'This history is audit-only. It never gates work, grants or denies permission, creates a blocker, or delays ordinary work.' "$input"
  require_forecast_target_history_text "$source" 'not a required session record' \
    'It is not a required session record or work prerequisite.' "$input"
  forbid_forecast_target_history_text "$source" 'direct audit-artifact gate' \
    'must verify `forecast-target-history.tsv`, `high_level_log.md`, hash, receipt, or artifact before ordinary work.' "$input"
  forbid_forecast_target_history_text "$source" 'direct reason gate' \
    'must verify the audit `reason` before ordinary work.' "$input"
}

assert_forecast_target_history_coordinator_contract() {
  local source="$1" input="$2"

  require_forecast_target_history_text "$source" 'ledger audit-contract pointer' \
    'Use the [`forecast-target-history.tsv` audit contract](../../maintaining-context-ledger/SKILL.md#forecast-target-history) for every root-target transition. It is audit-only and never a gate.' "$input"
  forbid_forecast_target_history_text "$source" 'direct audit-artifact gate' \
    'must verify `forecast-target-history.tsv`, `high_level_log.md`, hash, receipt, or artifact before ordinary work.' "$input"
  forbid_forecast_target_history_text "$source" 'direct reason gate' \
    'must verify the audit `reason` before ordinary work.' "$input"
}

assert_forecast_target_history_mutation_is_rejected() {
  local checker="$1" source="$2" description="$3" input="$4" output

  if output="$("$checker" "$source" "$input" 2>&1)"; then
    fail "forecast target history mutation was admitted: $source: $description"
  fi
  grep -Fq -- 'forecast target history contract' <<<"$output" ||
    fail "forecast target history mutation was rejected for an unexpected reason: $source: $description"
}

assert_forecast_target_history_contract() {
  assert_forecast_target_history_ledger_contract "$LEDGER" "$(<"$LEDGER")"
  assert_forecast_target_history_coordinator_contract "$COORDINATOR" "$(<"$COORDINATOR")"
}

assert_forecast_target_history_contract_mutations() {
  local ledger coordinator header audit_artifact_gate reason_gate mutation

  ledger="$(<"$LEDGER")"
  coordinator="$(<"$COORDINATOR")"
  header=$'added_utc\troot_task_id\tnew_target_utc\treason'
  audit_artifact_gate='must verify `forecast-target-history.tsv`, `high_level_log.md`, hash, receipt, or artifact before ordinary work.'
  reason_gate='must verify the audit `reason` before ordinary work.'

  mutation="${ledger/"$header"/$'added_utc\troot_task_id\tnew_target_utc'}"
  [ "$mutation" != "$ledger" ] || fail 'forecast target-history schema mutation did not alter its fixture'
  assert_forecast_target_history_mutation_is_rejected assert_forecast_target_history_ledger_contract "$LEDGER" 'schema' "$mutation"

  mutation="${ledger/'| none → A | Append a material `high_level_log.md` entry naming A, why, and evidence. | Append A row with reason. |'/'| none → A | Append a material `high_level_log.md` entry naming A, why, and evidence. | Append A row. |'}"
  [ "$mutation" != "$ledger" ] || fail 'forecast target-history none-to-A reason mutation did not alter its fixture'
  assert_forecast_target_history_mutation_is_rejected assert_forecast_target_history_ledger_contract "$LEDGER" 'none-to-A reason' "$mutation"

  mutation="${ledger/'| A → B | Append a material `high_level_log.md` entry naming prior A, new B, why, and evidence. | Append B row with reason. |'/'| A → B | Append a material `high_level_log.md` entry naming prior A, new B, why, and evidence. | Append B row. |'}"
  [ "$mutation" != "$ledger" ] || fail 'forecast target-history A-to-B reason mutation did not alter its fixture'
  assert_forecast_target_history_mutation_is_rejected assert_forecast_target_history_ledger_contract "$LEDGER" 'A-to-B reason' "$mutation"

  mutation="${ledger/'This history is audit-only. It never gates work, grants or denies permission, creates a blocker, or delays ordinary work.'/'This history gates work.'}"
  [ "$mutation" != "$ledger" ] || fail 'forecast target-history audit-only mutation did not alter its fixture'
  assert_forecast_target_history_mutation_is_rejected assert_forecast_target_history_ledger_contract "$LEDGER" 'audit-only non-gate boundary' "$mutation"

  mutation="${ledger/'Append the corrected-target row with reason; never rewrite earlier rows.'/'Append the corrected-target row; never rewrite earlier rows.'}"
  [ "$mutation" != "$ledger" ] || fail 'forecast target-history correction mutation did not alter its fixture'
  assert_forecast_target_history_mutation_is_rejected assert_forecast_target_history_ledger_contract "$LEDGER" 'correction reason' "$mutation"

  mutation="$ledger"$'\n\n- '"$audit_artifact_gate"
  assert_forecast_target_history_mutation_is_rejected assert_forecast_target_history_ledger_contract "$LEDGER" 'audit-artifact gate' "$mutation"

  mutation="$ledger"$'\n\n- '"$reason_gate"
  assert_forecast_target_history_mutation_is_rejected assert_forecast_target_history_ledger_contract "$LEDGER" 'reason gate' "$mutation"

  mutation="$coordinator"$'\n\n- '"$audit_artifact_gate"
  assert_forecast_target_history_mutation_is_rejected assert_forecast_target_history_coordinator_contract "$COORDINATOR" 'coordinator audit-artifact gate' "$mutation"
}

assert_lane_forecast_contract() {
  local file header completed
  local lane_workstream_pattern serial_lane_pattern distinct_lane_pattern root_omission_pattern
  local outcome_pattern actor_stage_pattern root_full_pattern root_nonadditive_pattern
  local changed_forecast_pattern recalibration_template_pattern initial_template_pattern
  local missing_stale_pattern advisory_pattern advisory_no_gate_pattern advisory_no_permission_pattern
  local advisory_no_blocker_pattern closed_lane_pattern closed_lane_no_forecast_pattern
  local parallel_path_pattern parallel_nonadditive_pattern

  completed='`Completed: <UTC ISO8601>; no active forecast deadline.`'
  lane_workstream_pattern='lane[[:space:]]+is[[:space:]]+an[[:space:]]+independently[[:space:]]+advancing[[:space:]]+workstream'
  serial_lane_pattern='Serial[[:space:]]+implement→review→repair→review→implement.*one[[:space:]]+lane.*critical[[:space:]]+path'
  distinct_lane_pattern='distinct[[:space:]]+lanes.*only.*independently[[:space:]]+advancing.*(ownership|synchronization)'
  root_omission_pattern='For[[:space:]]+each[[:space:]]+unrepresented[[:space:]]+active[[:space:]]+root-task[[:space:]]+outcome[[:space:]]+omitted[[:space:]]+by[[:space:]]+(its[[:space:]]+)?lane[[:space:]]+reports.*(state|record|include)'
  outcome_pattern='forecast[[:space:]]+line.*finished[[:space:]]+outcome'
  actor_stage_pattern='(never[[:space:]]+names|does[[:space:]]+not[[:space:]]+name).*(critic|reviewer|actor|stage)'
  root_full_pattern='Root[[:space:]]+completion.*full[[:space:]]+root[[:space:]]+completion'
  root_nonadditive_pattern='Root[[:space:]]+completion.*not.*child[[:space:]]+sum.*stage'
  changed_forecast_pattern='changed.*forecast.*restate.*current.*canonical[[:space:]]+line'
  recalibration_template_pattern='Forecast[[:space:]]+recalibration:[[:space:]]+<prior[[:space:]]+UTC[[:space:]]+ISO8601>[[:space:]]+→[[:space:]]+<current[[:space:]]+UTC[[:space:]]+ISO8601>;[[:space:]]+why[[:space:]]+moved:[[:space:]]+<why>;[[:space:]]+supporting[[:space:]]+evidence:[[:space:]]+<evidence>\.'
  initial_template_pattern='Forecast[[:space:]]+recalibration:[[:space:]]+unchanged[[:space:]]+—[[:space:]]+baseline[[:space:]]+<UTC[[:space:]]+ISO8601>;[[:space:]]+supporting[[:space:]]+evidence:[[:space:]]+<evidence>\.'
  missing_stale_pattern='(forecast.*(missing|stale)|(missing|stale).*forecast).*reconcile.*safe[[:space:]]+work.*without[[:space:]]+delaying.*update'
  advisory_pattern='Forecasts[[:space:]]+are[[:space:]]+advisory\.'
  advisory_no_gate_pattern='never[[:space:]]+gate[[:space:]]+work'
  advisory_no_permission_pattern='grant.*deny[[:space:]]+permissions'
  advisory_no_blocker_pattern='never.*create[[:space:]]+blockers'
  closed_lane_pattern='`CLOSED`[[:space:]]+lane.*records[[:space:]]+completion'
  closed_lane_no_forecast_pattern='do[[:space:]]+not.*(invent|revive).*forecast[[:space:]]+deadline.*recalibration'
  parallel_path_pattern='parallel[[:space:]]+children.*single[[:space:]]+critical-path[[:space:]]+deadline'
  parallel_nonadditive_pattern='never.*(add|sum).*parallel[[:space:]]+child[[:space:]]+deadlines.*(parent|root|mission)'

  require_pattern "$ECI" 'lanes independently advance' "$lane_workstream_pattern"
  require_pattern "$ECI" 'serial implementation and review stay one lane' "$serial_lane_pattern"
  require_pattern "$ECI" 'only independently advancing work becomes a new lane' "$distinct_lane_pattern"
  assert_coordinator_progress_forecast_contract "$COORDINATOR" "$(<"$COORDINATOR")"
  require_line "$COORDINATOR" '- Use the two templates above exactly: named lane/task or root outcome and UTC deadline only. Do not append text.'
  require_pattern "$COORDINATOR" 'coordinator missing/stale forecasts do not delay updates' "$missing_stale_pattern"

  require_line "$STATUS_REPORT" '## Lane forecasts'
  header="$(grep -F -- '| Task ID | Parent ID | Lane | Lane requirement context | Stage | Owner |' "$STATUS_REPORT" || true)"
  [[ "$header" == *'| Next milestone |'* &&
     "$header" == *'| Forecast deadline / recalibration |'* &&
     "$header" == *'| Dependencies / critical path |'* &&
     "$header" == *'| Next proof/action |'* ]] ||
    fail 'status report lane table lacks forecast columns before Next proof/action'

  for file in "$COORDINATOR" "$STATUS_REPORT" "$LEDGER"; do
    assert_forecast_source_contract "$file" "$(<"$file")"
    require_pattern "$file" 'unrepresented active-root reporting rule' "$root_omission_pattern"
    require_pattern "$file" 'forecast line names a finished outcome' "$outcome_pattern"
    require_pattern "$file" 'forecast line excludes actor and stage metadata' "$actor_stage_pattern"
    require_pattern "$file" 'root completion is full' "$root_full_pattern"
    require_pattern "$file" 'root completion is non-additive' "$root_nonadditive_pattern"
    require_pattern "$file" 'changed forecasts restate their canonical line' "$changed_forecast_pattern"
    require_pattern "$file" 'changed forecast recalibration template' "$recalibration_template_pattern"
    require_pattern "$file" 'forecast advisory boundary' "$advisory_pattern"
    require_pattern "$file" 'advisory forecasts do not gate work' "$advisory_no_gate_pattern"
    require_pattern "$file" 'advisory forecasts do not grant or deny permissions' "$advisory_no_permission_pattern"
    require_pattern "$file" 'advisory forecasts do not create blockers' "$advisory_no_blocker_pattern"
    forbid_flattened_pattern "$file" 'bare Forecast deadline: by <UTC ISO8601>' 'Forecast[[:space:]]+deadline:[[:space:]]+by[[:space:]]+<UTC[[:space:]]+ISO8601>'
    forbid_flattened_pattern "$file" 'bare Root completion forecast: by <UTC ISO8601>' 'Root[[:space:]]+completion[[:space:]]+forecast:[[:space:]]+by[[:space:]]+<UTC[[:space:]]+ISO8601>'
  done

  for file in "$STATUS_REPORT" "$LEDGER"; do
    require_pattern "$file" 'lanes independently advance' "$lane_workstream_pattern"
    require_pattern "$file" 'serial implementation and review stay one lane' "$serial_lane_pattern"
    require_pattern "$file" 'only independently advancing work becomes a new lane' "$distinct_lane_pattern"
    require_pattern "$file" 'initial forecast evidence template' "$initial_template_pattern"
    require_pattern "$file" 'missing/stale forecasts do not delay updates' "$missing_stale_pattern"
    require_text "$file" "$completed"
    forbid_generic_forecast_recalibration_placeholder "$file" '<prior deadline>'
    forbid_generic_forecast_recalibration_placeholder "$file" '<current deadline>'
    require_pattern "$file" 'closed lanes record completion' "$closed_lane_pattern"
    require_pattern "$file" 'closed lanes do not revive forecasts' "$closed_lane_no_forecast_pattern"
    forbid_legacy_duration_forecast_form "$file" 'Remaining forecast'
    forbid_legacy_duration_forecast_form "$file" 'remaining range'
    forbid_legacy_duration_forecast_form "$file" 'increased | decreased | unchanged'
    forbid_legacy_duration_forecast_pattern "$file" 'wrapped additive child-estimate wording' 'Never[[:space:]]+add[[:space:]]+overlapping[[:space:]]+child[[:space:]]+estimates[[:space:]]+into[[:space:]]+a[[:space:]]+parent[[:space:]]+or[[:space:]]+mission[[:space:]]+forecast;'
    forbid_legacy_duration_forecast_form "$file" 'overlapping estimates stay non-additive.'
    forbid_forecast_advisory_contradiction "$file" 'A `CLOSED` lane must retain a forecast deadline or recalibration.'
    forbid_forecast_advisory_contradiction "$file" 'Parallel child deadlines may be added into a parent, root, or mission deadline.'
    forbid_forecast_advisory_contradiction "$file" 'Add every child deadline to derive the parent forecast.'
    forbid_forecast_advisory_contradiction "$file" 'A forecast may gate work.'
    forbid_forecast_advisory_contradiction "$file" 'A forecast may block work.'
    forbid_forecast_advisory_contradiction "$file" 'A missed forecast deadline may gate work and block a lane.'
    forbid_forecast_advisory_contradiction "$file" 'A forecast may authorize work.'
    forbid_forecast_advisory_contradiction "$file" 'A forecast may require a receipt or artifact.'
    forbid_forecast_advisory_contradiction "$file" 'A forecast promises completion.'
    require_pattern "$file" 'parallel deadlines use one critical path' "$parallel_path_pattern"
    require_pattern "$file" 'parallel deadlines remain non-additive' "$parallel_nonadditive_pattern"
  done

  require_line "$LEDGER" '### Lane forecasts'
  require_pattern "$STATUS_REPORT" 'review, deploy, and proof remain within a lane' 'Review,[[:space:]]+deploy,[[:space:]]+and[[:space:]]+proof[[:space:]]+are[[:space:]]+current[[:space:]]+work[[:space:]]+within[[:space:]]+a[[:space:]]+lane,[[:space:]]+not[[:space:]]+automatically[[:space:]]+separate[[:space:]]+lanes\.'
  require_pattern "$STATUS_REPORT" 'status requirement covers unrepresented active roots' 'For[[:space:]]+each[[:space:]]+unrepresented[[:space:]]+active[[:space:]]+root-task[[:space:]]+outcome[[:space:]]+omitted[[:space:]]+by[[:space:]]+(its[[:space:]]+)?lane[[:space:]]+reports'
  require_pattern "$STATUS_REPORT" 'status checklist covers unrepresented active roots' 'Root[[:space:]]+coverage[[:space:]]*\|[[:space:]]+In[[:space:]]+a[[:space:]]+material[[:space:]]+changed-state[[:space:]]+update,[[:space:]]+each[[:space:]]+unrepresented[[:space:]]+active[[:space:]]+root-task[[:space:]]+outcome[[:space:]]+omitted[[:space:]]+by[[:space:]]+lane[[:space:]]+reports'
  require_pattern "$LEDGER" 'Progress source and status projection' 'Progress[[:space:]]+is[[:space:]]+the[[:space:]]+source[[:space:]]+of[[:space:]]+truth;[[:space:]]+`latest-status-report\.md`[[:space:]]+projects[[:space:]]+these[[:space:]]+fields[[:space:]]+using[[:space:]]+`writing-status-reports`\.'
  require_pattern "$LEDGER" 'invalid-ledger rule covers unrepresented active roots' 'unrepresented[[:space:]]+active[[:space:]]+root-task[[:space:]]+outcome[[:space:]]+omitted[[:space:]]+by[[:space:]]+lane[[:space:]]+reports'
  require_pattern "$STATUS_REPORT" 'status forecast checklist' 'Lane[[:space:]]+forecasts[[:space:]]*\|[[:space:]]+A[[:space:]]+material[[:space:]]+changed-state[[:space:]]+update[[:space:]]+names[[:space:]]+each[[:space:]]+active[[:space:]]+lane.?s[[:space:]]+milestone[[:space:]]+and[[:space:]]+one[[:space:]]+named-outcome[[:space:]]+forecast'
  require_pattern "$LEDGER" 'invalid ledger detects missing active-lane forecasts' 'active[[:space:]]+lane[[:space:]]+lacks.*Lane[[:space:]]+forecasts'
  require_pattern "$LEDGER" 'invalid ledger detects missing active-root forecasts' 'unrepresented[[:space:]]+active[[:space:]]+root-task[[:space:]]+outcome.*lacks.*Root[[:space:]]+completion[[:space:]]+forecast'
  require_pattern "$LEDGER" 'invalid ledger detects stale changed forecasts' 'changed[[:space:]]+lane/root.*current[[:space:]]+canonical[[:space:]]+line.*recalibration'
  require_pattern "$LEDGER" 'invalid ledger detects closed forecasts' '`CLOSED`[[:space:]]+lane.*retains.*forecast[[:space:]]+deadline/recalibration'
}

assert_lineage_context_contract() {
  require_text "$LINEAGE" 'Requirement lineage is readable coordination context, not a permission system.'
  require_text "$LINEAGE" 'Missing or stale lineage is recorded as `lineage unavailable—reconcile`; it'
  require_text "$LINEAGE" 'does not stop bounded work, status reporting, or a safe assignment.'
  require_text "$LINEAGE" 'Record known outcome, scope, owner, and verification when they are available.'
  require_text "$LINEAGE" 'Label unknown context and reconcile it in parallel; never delay a safe bounded'
  require_text "$LINEAGE" 'handoff.'
  require_text "$LINEAGE" 'Stop or route only a concrete accidental scope mistake:'
  require_text "$LINEAGE" 'requested outcome. Name the resolved target or new outcome and use'
  require_text "$LINEAGE" 'the narrowest safe route.'
  forbid_text "$LINEAGE" 'If unreadable, fail closed.'
  forbid_text "$LINEAGE" 'any missing/stale pair/hash fails closed.'
  forbid_pattern "$LINEAGE" 'lineage.*(must|shall|needs? to).*(resolve|validate|admit).*(work|status|report|assignment)'
  forbid_pattern "$LINEAGE" '(hash|receipt|registry).*(must|shall|needs? to).*(work|status|report|assignment)'
}

require_primary_scope_fidelity_text() {
  local source="$1" description="$2" expected="$3" input="$4"

  [[ "$input" == *"$expected"* ]] ||
    fail "$source is missing primary scope fidelity contract: $description"
}

assert_primary_scope_fidelity_contract() {
  local source="$1" input="$2" activation

  activation="$(extract_h2_section <(printf '%s\n' "$input") '## Activation and invariants')" ||
    fail "$source lacks a bounded Activation and invariants section"

  require_primary_scope_fidelity_text "$source" 'material source-outcome-scope chain' \
    '- For material ECI work, keep `exact user source → faithful requested outcome' "$activation"
  require_primary_scope_fidelity_text "$source" 'bounded scope in primary chain' \
    'bounded scope`.' "$activation"
  require_primary_scope_fidelity_text "$source" 'necessary repair remains current-lane work' \
    'A repair necessary to meet or prove that outcome stays current-lane work.' "$activation"
  require_primary_scope_fidelity_text "$source" 'separate outcome is only post-ECI follow-up' \
    'A concern serving a separate outcome is only a post-ECI user follow-up, never current work.' "$activation"
  if section_has_active_literal_directive "$activation" 'Treat a discovered concern serving a separate outcome as current-lane work.'; then
    fail "$source contradicts primary scope fidelity contract: separate outcome becomes current work"
  fi
  require_primary_scope_fidelity_text "$source" 'stale lineage remains nonblocking' \
    'Missing or stale lineage never blocks known in-scope work.' "$activation"
}

assert_primary_scope_fidelity_mutation_is_rejected() {
  local source="$1" description="$2" input="$3" output

  if output="$(assert_primary_scope_fidelity_contract "$source" "$input" 2>&1)"; then
    fail "primary scope fidelity mutation was admitted: $source: $description"
  fi
  grep -Fq -- 'primary scope fidelity contract' <<<"$output" ||
    fail "primary scope fidelity mutation was rejected for an unexpected reason: $source: $description"
}

assert_primary_scope_fidelity_contract_mutations() {
  local primary mutation

  primary="$(<"$ECI")"

  mutation="${primary/'exact user source → faithful requested outcome'/'generic context'}"
  [ "$mutation" != "$primary" ] || fail 'primary source-outcome mutation did not alter its fixture'
  assert_primary_scope_fidelity_mutation_is_rejected "$ECI" 'source-outcome chain removed' "$mutation"

  mutation="${primary/'A repair necessary to meet or prove that outcome stays current-lane work.'/'Every repair creates a new current lane.'}"
  [ "$mutation" != "$primary" ] || fail 'primary repair mutation did not alter its fixture'
  assert_primary_scope_fidelity_mutation_is_rejected "$ECI" 'necessary repair becomes a separate lane' "$mutation"

  mutation="${primary/'A concern serving a separate outcome is only a post-ECI user follow-up, never current work.'/'A concern serving a separate outcome is current work.'}"
  [ "$mutation" != "$primary" ] || fail 'primary separate-outcome mutation did not alter its fixture'
  assert_primary_scope_fidelity_mutation_is_rejected "$ECI" 'separate outcome becomes current work' "$mutation"

  assert_active_literal_directive_fixtures \
    assert_primary_scope_fidelity_contract "$ECI" "$primary" \
    'A concern serving a separate outcome is only a post-ECI user follow-up, never current work.' \
    'Treat a discovered concern serving a separate outcome as current-lane work.' \
    'primary scope fidelity contract'

  mutation="${primary/'Missing or stale lineage never blocks known in-scope work.'/'Missing or stale lineage blocks known in-scope work.'}"
  [ "$mutation" != "$primary" ] || fail 'primary stale-lineage mutation did not alter its fixture'
  assert_primary_scope_fidelity_mutation_is_rejected "$ECI" 'stale lineage blocks known work' "$mutation"
}

assert_review_policy_least_restriction_contract() {
  local source="$1" input="$2"

  if section_has_active_literal_directive "$input" 'Receipt required before ordinary work.'; then
    fail "$source contradicts least restriction contract: receipt becomes an ordinary-work gate"
  fi
}

assert_implement_write_boundary_contract() {
  local source="$1" input="$2" boundary

  boundary="$(extract_h2_section <(printf '%s\n' "$input") '## Write boundary and submission')" ||
    fail "$source lacks a bounded Write boundary and submission section"
  if section_has_active_literal_directive "$boundary" 'Normal work cannot begin without a receipt.'; then
    fail "$source contradicts least restriction contract: receipt becomes an ordinary-work gate"
  fi
}

assert_implement_write_boundary_contract_mutations() {
  local implement

  implement="$(<"$IMPLEMENT")"

  assert_active_literal_directive_fixtures \
    assert_implement_write_boundary_contract "$IMPLEMENT" "$implement" \
    'One change/one diff per assignment; do not broaden a winner through “helpful” cleanup.' \
    'Normal work cannot begin without a receipt.' \
    'least restriction contract'
}

# Static source contract only: these fixed clauses exercise scope pressure without
# parsing runtime messages or making lineage an admission mechanism.
require_scope_fidelity_text() {
  local source="$1" description="$2" expected="$3" input="$4"

  [[ "$input" == *"$expected"* ]] ||
    fail "$source is missing scope fidelity contract: $description"
}

assert_scope_fidelity_ledger_contract() {
  local source="$1" input="$2"

  require_scope_fidelity_text "$source" 'readable source-outcome-scope chain' \
    'For material ECI work, keep `exact user source → faithful requested outcome' "$input"
  require_scope_fidelity_text "$source" 'bounded scope in source-outcome chain' \
    'bounded scope` as readable context.' "$input"
  require_scope_fidelity_text "$source" 'necessary repair remains current-lane work' \
    'A repair stays in its lane when it is' "$input"
  require_scope_fidelity_text "$source" 'necessary repair proves the requested outcome' \
    'necessary to meet or prove that outcome.' "$input"
  require_scope_fidelity_text "$source" 'separate outcome is post-ECI only' \
    'post-ECI observation or follow-up, never current lane, assignment,' "$input"
  require_scope_fidelity_text "$source" 'separate outcome cannot create work or forecasts' \
    'code change,' "$input"
  require_scope_fidelity_text "$source" 'separate outcome cannot create review, deadline, forecast, or proof' \
    'review, deadline, forecast, or proof program.' "$input"
  require_scope_fidelity_text "$source" 'stale lineage remains nonblocking' \
    'Reconcile missing or stale' "$input"
  require_scope_fidelity_text "$source" 'stale lineage continues known work' \
    'lineage alongside known work; do not block it.' "$input"
}

assert_scope_fidelity_coordinator_contract() {
  local source="$1" input="$2"

  require_scope_fidelity_text "$source" 'material source-outcome-scope chain' \
    '- For material ECI work, retain `exact user source → faithful requested outcome → bounded scope`.' "$input"
  require_scope_fidelity_text "$source" 'necessary repair stays current lane' \
    'A repair needed to meet or prove that outcome stays in its current lane;' "$input"
  require_scope_fidelity_text "$source" 'separate outcome remains post-ECI' \
    'separate-outcome concern is only a post-ECI observation or follow-up, never' "$input"
  require_scope_fidelity_text "$source" 'separate outcome cannot create current work or forecasts' \
    'current work or a forecast.' "$input"
  require_scope_fidelity_text "$source" 'stale lineage remains nonblocking' \
    'Reconcile missing or stale lineage alongside known work; it does not block progress.' "$input"
  require_scope_fidelity_text "$source" 'false current scope correction avoids destructive reversion' \
    'Cancel or reassign only unrooted current work; do not destructively revert already-made work without user direction.' "$input"
}

assert_scope_fidelity_lineage_contract() {
  local source="$1" input="$2"

  require_scope_fidelity_text "$source" 'exact source-outcome-scope chain' \
    'For a material ECI task, record `exact user source → faithful requested outcome' "$input"
  require_scope_fidelity_text "$source" 'no inferred direct requirement' \
    'a reason, discovery, or inferred safeguard is never a substitute user' "$input"
  require_scope_fidelity_text "$source" 'separate concern cannot activate work' \
    'requirement, current lane, assignment, code change, review, forecast, deadline,' "$input"
  require_scope_fidelity_text "$source" 'separate concern cannot create proof' \
    'or proof program.' "$input"
  require_scope_fidelity_text "$source" 'known work remains nonblocking' \
    'does not stop bounded work, status reporting, or a safe assignment.' "$input"
  require_scope_fidelity_text "$source" 'false scope correction preserves completed work' \
    'Cancel or reassign only unrooted current work. Do not' "$input"
  require_scope_fidelity_text "$source" 'diagnostics pressure fixture' \
    'Pressure check: a user requests useful diagnostics; investigation reveals an' "$input"
  require_scope_fidelity_text "$source" 'diagnostics pressure fixture names secret/log concern' \
    'unrelated potential secret/log concern.' "$input"
  require_scope_fidelity_text "$source" 'secret/log discovery stays an observation' \
    'observation or follow-up; do not create a redaction lane, agent assignment,' "$input"
  require_scope_fidelity_text "$source" 'secret/log discovery cannot activate code or review' \
    'code change, review, deadline, forecast, or proof program.' "$input"
}

assert_scope_fidelity_critic_contract() {
  local source="$1" input="$2"

  require_scope_fidelity_text "$source" 'Critic B checks scope fidelity and least restriction' \
    'Check scope fidelity and least restriction against `exact user source → faithful requested outcome → bounded scope`.' "$input"
  require_scope_fidelity_text "$source" 'Critic B distinguishes needed repair from invented outcome' \
    'Distinguish a repair needed to meet or prove that outcome from an invented separate outcome;' "$input"
}

assert_scope_fidelity_status_contract() {
  local source="$1" input="$2"

  require_scope_fidelity_text "$source" 'material status shows faithful source-outcome-scope lineage' \
    'In material ECI status, show `exact user source → faithful requested outcome → bounded scope` in readable form.' "$input"
  require_scope_fidelity_text "$source" 'workflow activity is overhead' \
    'Workflow activity is overhead, not progress.' "$input"
  require_scope_fidelity_text "$source" 'forecasts only accompany material changed state' \
    'Only a material changed-state ECI update emits forecast lines. In one such response, emit each canonical forecast once.' "$input"
  require_scope_fidelity_text "$source" 'preparation and timeline omit forecasts' \
    'Preparation-only commentary, pure explanation, roster/wait, and timeline output omit forecast lines unless they also report a material change.' "$input"
}

assert_scope_fidelity_policy_contract() {
  local source="$1" input="$2"

  require_scope_fidelity_text "$source" 'broad defect labels are subordinate to user outcome' \
    'A remedy is `now` only when it is necessary to meet or prove the original user outcome;' "$input"
  require_scope_fidelity_text "$source" 'labels do not independently create current work' \
    'do not independently make it current work.' "$input"
}

assert_scope_fidelity_critique_contract() {
  local source="$1" input="$2"

  require_scope_fidelity_text "$source" 'Step 2 rejects separate outcome presented as current scope' \
    'REJECT a discovered concern whose remedy serves a separate outcome when presented as current scope,' "$input"
  require_scope_fidelity_text "$source" 'stale lineage is not a rejection gate' \
    'Stale lineage does not reject known in-scope work.' "$input"
}

assert_scope_fidelity_pressure_fixtures() {
  assert_scope_fidelity_ledger_contract "$LEDGER" "$(<"$LEDGER")"
  assert_scope_fidelity_coordinator_contract "$COORDINATOR" "$(<"$COORDINATOR")"
  assert_scope_fidelity_lineage_contract "$LINEAGE" "$(<"$LINEAGE")"
  assert_scope_fidelity_critic_contract "$REVIEW" "$(<"$REVIEW")"
  assert_scope_fidelity_status_contract "$STATUS_REPORT" "$(<"$STATUS_REPORT")"
  assert_scope_fidelity_policy_contract "$REVIEW_POLICY" "$(<"$REVIEW_POLICY")"
  assert_scope_fidelity_critique_contract "$ECI_CRITIQUE" "$(<"$ECI_CRITIQUE")"
}

assert_scope_fidelity_mutation_is_rejected() {
  local checker="$1" source="$2" description="$3" input="$4" output

  if output="$("$checker" "$source" "$input" 2>&1)"; then
    fail "scope fidelity mutation was admitted: $source: $description"
  fi
  grep -Fq -- 'scope fidelity contract' <<<"$output" ||
    fail "scope fidelity mutation was rejected for an unexpected reason: $source: $description"
}

assert_scope_fidelity_pressure_mutations_are_rejected() {
  local ledger coordinator lineage review status policy mutation

  ledger="$(<"$LEDGER")"
  coordinator="$(<"$COORDINATOR")"
  lineage="$(<"$LINEAGE")"
  review="$(<"$REVIEW")"
  status="$(<"$STATUS_REPORT")"
  policy="$(<"$REVIEW_POLICY")"

  mutation="${ledger/'necessary to meet or prove that outcome.'/'merely convenient.'}"
  [ "$mutation" != "$ledger" ] || fail 'needed-repair mutation did not alter its fixture'
  assert_scope_fidelity_mutation_is_rejected assert_scope_fidelity_ledger_contract "$LEDGER" 'needed repair becomes unrelated work' "$mutation"

  mutation="${coordinator/'post-ECI observation or follow-up'/'current lane assignment'}"
  [ "$mutation" != "$coordinator" ] || fail 'separate-outcome coordinator mutation did not alter its fixture'
  assert_scope_fidelity_mutation_is_rejected assert_scope_fidelity_coordinator_contract "$COORDINATOR" 'separate outcome becomes current work' "$mutation"

  mutation="${lineage/'a reason, discovery, or inferred safeguard is never a substitute user'/'a reason, discovery, or inferred safeguard is a substitute user'}"
  [ "$mutation" != "$lineage" ] || fail 'false-direct-requirement mutation did not alter its fixture'
  assert_scope_fidelity_mutation_is_rejected assert_scope_fidelity_lineage_contract "$LINEAGE" 'discovery becomes direct user requirement' "$mutation"

  mutation="${lineage/'does not stop bounded work, status reporting, or a safe assignment.'/'stops bounded work until lineage is repaired.'}"
  [ "$mutation" != "$lineage" ] || fail 'stale-lineage mutation did not alter its fixture'
  assert_scope_fidelity_mutation_is_rejected assert_scope_fidelity_lineage_contract "$LINEAGE" 'stale lineage blocks known work' "$mutation"

  mutation="${lineage/'do not create a redaction lane, agent assignment,'/'create a redaction lane and agent assignment,'}"
  [ "$mutation" != "$lineage" ] || fail 'secret/log pressure mutation did not alter its fixture'
  assert_scope_fidelity_mutation_is_rejected assert_scope_fidelity_lineage_contract "$LINEAGE" 'secret/log discovery creates lane or agent work' "$mutation"

  mutation="${review/'Check scope fidelity and least restriction'/'Check only style preference'}"
  [ "$mutation" != "$review" ] || fail 'Critic B scope mutation did not alter its fixture'
  assert_scope_fidelity_mutation_is_rejected assert_scope_fidelity_critic_contract "$REVIEW" 'Critic B omits scope fidelity' "$mutation"

  mutation="${status/'Workflow activity is overhead, not progress.'/'Workflow activity is progress.'}"
  [ "$mutation" != "$status" ] || fail 'overhead mutation did not alter its fixture'
  assert_scope_fidelity_mutation_is_rejected assert_scope_fidelity_status_contract "$STATUS_REPORT" 'workflow activity becomes progress' "$mutation"

  mutation="${status/'Preparation-only commentary, pure explanation, roster/wait, and timeline output omit forecast lines unless they also report a material change.'/'Preparation-only commentary, pure explanation, roster/wait, and timeline output emit forecast lines.'}"
  [ "$mutation" != "$status" ] || fail 'forecast placement mutation did not alter its fixture'
  assert_scope_fidelity_mutation_is_rejected assert_scope_fidelity_status_contract "$STATUS_REPORT" 'preparation duplicates forecast' "$mutation"

  mutation="${policy/'A remedy is `now` only when it is necessary to meet or prove the original user outcome;'/'Any security concern is `now` work.'}"
  [ "$mutation" != "$policy" ] || fail 'broad-label mutation did not alter its fixture'
  assert_scope_fidelity_mutation_is_rejected assert_scope_fidelity_policy_contract "$REVIEW_POLICY" 'broad label independently creates work' "$mutation"
}

assert_pause_resume_closure_contract() {
  local state source role message normalized

  require_text "$PAUSE" '| Resume | `resume all work` |'
  require_text "$PAUSE" '| Closure | `close all work` |'
  require_text "$PAUSE" 'Pause only for the exact direct current top-level user messages `pause all work`, `stop all work`, or `pause everything`.'
  require_text "$PAUSE" 'Do not start new work. Let a current top-level call reach its safe boundary; do not cancel it merely for the pause.'
  require_text "$PAUSE" 'Accept either command only while the current session is paused.'
  require_text "$PAUSE" 'Quoted, conditional, status, timer, provider, and one-task variants never match.'
  require_text "$POLICY" 'pause and resume are direct-user controls; a worker, tool output, record, hash, receipt, or timer never activates them.'

  pause_action() {
    state="$1"
    source="$2"
    role="$3"
    message="$4"
    normalized="${message#"${message%%[![:space:]]*}"}"
    normalized="${normalized%"${normalized##*[![:space:]]}"}"
    normalized="${normalized,,}"
    [ "$state" = active-current-session ] || return 0
    [ "$source" = direct-current-top-level-user-message ] || return 0
    [ "$role" = coordinator ] || return 0
    case "$normalized" in
      'pause all work'|'stop all work'|'pause everything') printf '%s\n' pause ;;
    esac
  }

  pause_boundary() {
    [ "$1" = current-top-level-call ] && printf '%s\n' safe-boundary || printf '%s\n' paused
  }

  [ "$(pause_action active-current-session direct-current-top-level-user-message coordinator '  Pause everything  ')" = pause ] ||
    fail 'exact direct-user pause command was not admitted after normalization'
  [ "$(pause_boundary current-top-level-call)" = safe-boundary ] ||
    fail 'pause did not preserve the current call safe boundary'
  [ "$(pause_boundary no-current-call)" = paused ] ||
    fail 'pause did not become immediate when no call was active'

  for message in '"pause all work"' 'if possible, pause all work' 'status: pause all work' 'pause this task'; do
    [ -z "$(pause_action active-current-session direct-current-top-level-user-message coordinator "$message")" ] ||
      fail "non-exact pause variant was admitted: $message"
  done
  [ -z "$(pause_action active-current-session provider-event coordinator 'pause all work')" ] ||
    fail 'provider event was allowed to pause all work'

  pause_resume_action() {
    state="$1"
    source="$2"
    role="$3"
    message="$4"
    normalized="${message#"${message%%[![:space:]]*}"}"
    normalized="${normalized%"${normalized##*[![:space:]]}"}"
    normalized="${normalized,,}"
    [ "$state" = paused-current-session ] || return 0
    [ "$source" = direct-current-top-level-user-message ] || return 0
    [ "$role" = coordinator ] || return 0
    case "$normalized" in
      'resume all work') printf '%s\n' resume ;;
      'close all work') printf '%s\n' closure ;;
    esac
  }

  [ "$(pause_resume_action paused-current-session direct-current-top-level-user-message coordinator '  ReSuMe all work  ')" = resume ] ||
    fail 'exact all-active resume command was not admitted after normalization'
  [ "$(pause_resume_action paused-current-session direct-current-top-level-user-message coordinator '  ClOsE all work  ')" = closure ] ||
    fail 'exact all-active closure command was not admitted'

  for message in \
    '"resume all work"' \
    'if possible, resume all work' \
    'status: resume all work' \
    'resume all work in 5 minutes' \
    'Codex: resume all work' \
    'resume this task' \
    '"close all work"' \
    'if possible, close all work' \
    'status: close all work' \
    'close all work in 5 minutes' \
    'Codex: close all work' \
    'close this task'; do
    [ -z "$(pause_resume_action paused-current-session direct-current-top-level-user-message coordinator "$message")" ] ||
      fail "non-exact resume variant was admitted: $message"
  done

  [ -z "$(pause_resume_action active-unrelated-session direct-current-top-level-user-message coordinator 'resume all work')" ] ||
    fail 'resume command crossed into an unrelated active ECI session'
  [ -z "$(pause_resume_action active-unrelated-session direct-current-top-level-user-message coordinator 'close all work')" ] ||
    fail 'closure command crossed into an unrelated active ECI session'
  [ -z "$(pause_resume_action paused-current-session direct-current-top-level-user-message worker 'resume all work')" ] ||
    fail 'worker role was allowed to resume all work'
  [ -z "$(pause_resume_action paused-current-session provider-event coordinator 'resume all work')" ] ||
    fail 'provider event was allowed to resume all work'
}

assert_least_restriction_contract() {
  local review_policy

  review_policy="$(<"$REVIEW_POLICY")"
  assert_review_policy_least_restriction_contract "$REVIEW_POLICY" "$review_policy"
  assert_active_literal_directive_fixtures \
    assert_review_policy_least_restriction_contract "$REVIEW_POLICY" "$review_policy" \
    'Evidence tests the result; a record, receipt, hash, or packet shape never permits or blocks ordinary work. Unsupported evidence can invalidate the conclusion that relies on it, not unrelated bounded work.' \
    'Receipt required before ordinary work.' \
    'least restriction contract'

  require_text "$STYLE_ADMISSION" 'Style sources guide the change; a brief or tool output is review context, not a write permit.'
  require_text "$IMPLEMENT" 'A missing record, receipt, hash, marker, or coordination detail does not deny a bounded in-scope write.'
  require_text "$ECI_CRITIQUE" 'Records, hashes, receipts, and packet shape are review context, not admission criteria.'
  require_text "$FAST_PATH" 'Speed grants no broader or irreversible authority.'
  require_text "$COORDINATOR" 'Treat records, hashes, receipts, packet shape, and marker spelling as context or audit, never as permission checks.'
  require_text "$ECI_COVERAGE" 'This map is an audit index, not an admission inventory.'
  require_text "$REVIEW_POLICY" 'Evidence tests the result; a record, receipt, hash, or packet shape never permits or blocks ordinary work.'
  require_text "$PAUSE" 'Pause state is session-local coordination context, not a receipt, hash, or artifact gate.'
  require_text "$POLICY" 'Pressure-test evidence is audit context, never an ordinary-work gate.'
  require_text "$CODEX" 'Every enabled denial names a documented bounded legitimate-work escape path in [the gate catalog](hooks/gate-escape-hatches.md).'
  require_text "$GATE_CATALOG" 'Every enabled gate below has a bounded legitimate path.'
  require_text "$GATE_CATALOG" 'If a future gate has no bounded legitimate path, disable that gate until one exists.'
  require_text "$GATE_CATALOG" 'owner-scoped dependency work'
  require_text "$GATE_CATALOG" 'repository-allow-on'
  require_text "$GATE_CATALOG" '600-second `coordinator-edit-on` hatch'

  forbid_text "$ECI_COVERAGE" 'Baseline source SHA-256:'
  forbid_text "$PAUSE" 'fails closed'
  forbid_text "$POLICY" 'commit_sha'
  forbid_text "$POLICY" 'artifact_sha256'
}

assert_implementer_iteration_checkpoint_contract() {
  local baseline_contract baseline_exclusions ambiguity_contract
  local step4_bridge coordinator_sequence
  local review_range scope_exclusions scope_not_admission policy_checkpoint_packet

  baseline_contract='If Git cannot represent an iteration without earlier uncommitted content in the same target, first commit a separately named `pre-existing baseline` containing only independently verified, already-completed predecessor content currently coordinator-owned for the same lane.'
  baseline_exclusions='Exclude user-owned, another worker/lane, and in-flight content.'
  ambiguity_contract='If the baseline boundary remains ambiguous, preserve the worktree and re-explore the exact ambiguity while unrelated safe work continues.'
  step4_bridge='After the Step 3 handoff and before Step 4 or another implementation iteration, the coordinator applies the `CODEX.md` per-implementer checkpoint commit rule. Step 4 receives the named checkpoint, its parent-to-checkpoint diff, and explicit exclusions; a `pre-existing baseline` remains context outside the iteration range.'
  coordinator_sequence='After every implementer handoff, independently verify the exact scoped diff and create the one narrow coordinator-owned checkpoint commit before Step 4 or another implementation iteration. The review packet gives each reviewer the named checkpoint, its parent-to-checkpoint diff, and explicit exclusions. A `pre-existing baseline` is context outside the iteration range. A checkpoint commit is not acceptance.'
  review_range='The checkpointed `current diff` is the named parent-to-checkpoint range.'
  scope_exclusions='Respect explicit exclusions and exclude later ambient worktree changes.'
  scope_not_admission='This is review scope, not admission proof.'
  policy_checkpoint_packet='For a checkpointed review, the packet names the checkpoint and states explicit exclusions.'

  require_text "$CODEX" 'Implementers never commit.'
  require_text "$CODEX" 'After every implementer handoff, the coordinator independently verifies the exact scoped diff and creates one narrow coordinator-owned checkpoint commit before Step 4 or another implementation iteration.'
  require_text "$CODEX" 'A checkpoint commit is not acceptance.'
  require_text "$CODEX" 'Stage only exact iteration paths or hunks. Never stage a whole dirty path or tree merely to capture one hunk.'
  require_text "$CODEX" "$baseline_contract"
  require_text "$CODEX" "$baseline_exclusions"
  require_text "$CODEX" "$ambiguity_contract"
  forbid_text "$CODEX" 'A pre-existing baseline may include user-owned content.'
  forbid_text "$CODEX" 'A pre-existing baseline may include another worker/lane content.'
  forbid_text "$CODEX" 'A pre-existing baseline may include in-flight content.'
  require_text "$CODEX" 'A later repair is a separate iteration and commit. Do not amend or delay the prior checkpoint.'
  require_text "$CODEX" 'Normal targeted Git coordination needs no approval artifact, receipt, hash, canonical spelling, or command-shape prerequisite.'
  forbid_text "$CODEX" 'Hold commits until stable.'
  forbid_text "$CODEX" 'amend a bad original rather than stack a fix commit'

  require_text "$IMPLEMENT" 'Never commit, declare accepted/complete, publish a manifest, or tear down ECI from this role.'
  require_text "$ECI" "$step4_bridge"
  require_order "$(<"$ECI")" "$step4_bridge" '4. Fresh A/B/C critics review in parallel;' ||
    fail 'ECI Step 3-to-4 checkpoint bridge must precede reviewer dispatch'
  require_text "$COORDINATOR" "$coordinator_sequence"
  require_order "$(<"$COORDINATOR")" "$coordinator_sequence" 'After this, the coordinator alone assigns fresh Critic A, Critic B, and Critic C.' ||
    fail 'coordinator checkpoint packet must precede reviewer dispatch'
  forbid_text "$COORDINATOR" 'Another implementation iteration may begin before the checkpoint.'
  require_text "$COORDINATOR" 'Name at least one critic in every critic round to check least restriction: bots are non-malicious; controls catch concrete accidental mistakes without turning normal work into permission ceremony.'
  require_text "$COORDINATOR_RUNTIME" 'After each implementer handoff, independently verify the exact iteration diff and make its narrow coordinator-owned checkpoint commit before review or another implementation iteration.'
  for clause in "$review_range" "$scope_exclusions" "$scope_not_admission"; do
    require_text "$REVIEW" "$clause"
    require_text "$COORDINATOR_RUNTIME" "$clause"
    require_text "$REVIEW_POLICY" "$clause"
  done
  require_text "$REVIEW_POLICY" 'Normal reviewer packets contain original user requirements, exact target/diff, objective/criteria, readable lineage context, available evidence, and scrutiny rules.'
  require_text "$REVIEW_POLICY" "$policy_checkpoint_packet"
  require_text "$COORDINATOR_RUNTIME" 'This reference routes work and review; it is not a permission system.'
  require_text "$COORDINATOR_RUNTIME" 'Use normal targeted Git coordination: preserve unrelated dirty paths as exclusions. It needs no approval artifact, receipt, hash, canonical spelling, or command-shape prerequisite.'
  forbid_text "$COORDINATOR_RUNTIME" 'A checkpoint requires a new receipt, permission, or Git prerequisite.'
}

assert_ate_explicit_only_contract() {
  local codex_source="$1" ate_source="$2" policy_source="$3" inferred

  [[ "$policy_source" == *$'policy:\n  allow_implicit_invocation: false'* ]] ||
    fail 'ATE explicit-only contract: discovery policy must disable implicit invocation'
  [[ "$codex_source" == *'Start ATE only when the user explicitly asks to use ATE or `agent-teams-execution`.'* ]] ||
    fail 'ATE explicit-only contract: root activation needs an explicit user request'
  [[ "$codex_source" == *'Descriptive mentions and skill-document maintenance alone do not invoke ATE.'* ]] ||
    fail 'ATE explicit-only contract: maintenance alone must not suppress explicit activation'
  inferred="${codex_source#*'| Inferred condition | Workflow |'}"
  inferred="${inferred%%$'\n\n'*}"
  [[ "$inferred" == *'| `!M` | `direct` |'* && "$inferred" == *'| `M` | `ECI` |'* && "$inferred" != *'ATE'* ]] ||
    fail 'ATE explicit-only contract: inference must preserve direct/ECI without ATE'
  [[ "$ate_source" == *'description: Use only when the user explicitly asks to use ATE or agent-teams-execution;'* &&
    "$ate_source" == *'Once explicitly active, ATE retains its lifecycle until normal closure.'* ]] ||
    fail 'ATE explicit-only contract: discovery trigger and active lifecycle must agree'
  [[ "$ate_source" == *'mentioning or maintaining this skill alone does not invoke it.'* &&
    "$ate_source" == *'Task size, parallel work, descriptive mentions, and skill-document maintenance alone do not activate ATE.'* ]] ||
    fail 'ATE explicit-only contract: description and activation must distinguish maintenance alone'
}

assert_ate_explicit_only() {
  local codex_source ate_source policy_source mutation output
  codex_source="$(<"$CODEX")"
  ate_source="$(<"$ATE")"
  policy_source="$(<"$ROOT/skills/agent-teams-execution/agents/openai.yaml")"
  assert_ate_explicit_only_contract "$codex_source" "$ate_source" "$policy_source"
  require_text "$ECI" 'Starts only on explicit user request; once active, may route bounded work through ECI.'
  require_text "$ROOT/skills/code-porting/SKILL.md" 'Starts only on explicit user request; when already outer, routes each bounded Phase 7 task through ECI and remains outer.'
  require_text "$CODEX" '| `ATE` receives bounded `ECI` | Nest normal ECI;'

  for mutation in '' "${policy_source/false/true}"; do
    if output="$(assert_ate_explicit_only_contract "$codex_source" "$ate_source" "$mutation" 2>&1)"; then
      fail 'ATE explicit-only contract: absent/enabled implicit policy mutation was admitted'
    fi
    [[ "$output" == *'ATE explicit-only contract:'* ]] || fail "unexpected ATE policy mutation failure: $output"
  done
  mutation="${codex_source/'| `M` | `ECI` |'/'| `M` | `ATE` |'}"
  if output="$(assert_ate_explicit_only_contract "$mutation" "$ate_source" "$policy_source" 2>&1)"; then
    fail 'ATE explicit-only contract: automatic ATE routing mutation was admitted'
  fi
  [[ "$output" == *'ATE explicit-only contract:'* ]] || fail "unexpected ATE routing mutation failure: $output"
  mutation="${codex_source/'maintenance alone'/'maintenance'}"
  if output="$(assert_ate_explicit_only_contract "$mutation" "$ate_source" "$policy_source" 2>&1)"; then
    fail 'ATE explicit-only contract: categorical CODEX maintenance exclusion was admitted'
  fi
  [[ "$output" == *'maintenance alone'* ]] || fail "unexpected ATE maintenance mutation failure: $output"
  for mutation in "${ate_source/'skill alone'/'skill'}" "${ate_source/'maintenance alone'/'maintenance'}"; do
    if output="$(assert_ate_explicit_only_contract "$codex_source" "$mutation" "$policy_source" 2>&1)"; then
      fail 'ATE explicit-only contract: categorical skill maintenance exclusion was admitted'
    fi
    [[ "$output" == *'distinguish maintenance alone'* ]] || fail "unexpected ATE skill mutation failure: $output"
  done
}

assert_local_links_resolve
assert_ate_explicit_only
assert_role_rows_are_local
assert_debugging_role_routes
assert_eci_relationships
assert_compaction_provenance
assert_reviewer_role_split
assert_configuration_e2e_contract
assert_runtime_e2e_policy
assert_eci_e2e_cadence_contract
assert_eci_testing_discipline_precedence
assert_e2e_policy_consumer_pointers
assert_no_direct_configuration_e2e_waivers
assert_configuration_e2e_waiver_fixtures
assert_coordinator_bug_routing_is_nonblocking
assert_ate_ordinary_role_split
assert_fast_path_routes
assert_fast_quality
assert_post_fast_completion
assert_fast_treatment_now_contract
assert_fast_lexer_fixtures
assert_post_fast_role_ownership
assert_deferred_disposition_policy_contract
assert_fast_path_progress_waits
assert_concurrent_tasks
assert_task_root_closure
assert_concurrency_section_placement
assert_go_preference
assert_status_lane_stage_contract
assert_status_lane_stage_transition_fixture
assert_forecast_target_history_contract
assert_forecast_target_history_contract_mutations
assert_forecast_source_contract_fixtures
assert_coordinator_progress_forecast_contract_fixtures
assert_primary_scope_fidelity_contract "$ECI" "$(<"$ECI")"
assert_primary_scope_fidelity_contract_mutations
assert_implement_write_boundary_contract "$IMPLEMENT" "$(<"$IMPLEMENT")"
assert_implement_write_boundary_contract_mutations
assert_scope_fidelity_pressure_fixtures
assert_scope_fidelity_pressure_mutations_are_rejected
assert_lane_forecast_contract
assert_source_forecast_mutations_are_rejected
assert_lineage_context_contract
assert_pause_resume_closure_contract
assert_least_restriction_contract
assert_eci_ordinary_role_split
assert_implementer_iteration_checkpoint_contract
printf '%s\n' 'workflow skill routing assertions: PASS'
