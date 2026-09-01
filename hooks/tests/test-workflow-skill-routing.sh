#!/usr/bin/env bash

set -euo pipefail

ROOT="${WORKFLOW_SKILL_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
CODEX="$ROOT/CODEX.md"
ECI="$ROOT/skills/explore-critique-implement/SKILL.md"
DEBUGGING="$ROOT/skills/debugging-discipline/SKILL.md"
STATUS_REPORT="$ROOT/skills/writing-status-reports/SKILL.md"
LEDGER="$ROOT/skills/maintaining-context-ledger/SKILL.md"
LINEAGE="$ROOT/skills/references/requirement-lineage.md"
ATE="$ROOT/skills/agent-teams-execution/SKILL.md"
ECI_COVERAGE="$ROOT/skills/explore-critique-implement/references/coverage-map.md"
ATE_COVERAGE="$ROOT/skills/agent-teams-execution/references/coverage-map.md"
EMERGENCY="$ROOT/skills/explore-critique-implement/references/emergency-unblock.md"
PAUSE="$ROOT/skills/references/workflow-runtime/pause-all-work.md"
POLICY="$ROOT/skills/references/workflow-runtime/policy-pressure-tests.md"
ECI_CRITIQUE="$ROOT/skills/explore-critique-implement/references/critique.md"
IMPLEMENT="$ROOT/skills/explore-critique-implement/references/implement.md"
REVIEW="$ROOT/skills/explore-critique-implement/references/review.md"
COORDINATOR="$ROOT/skills/explore-critique-implement/references/coordinator.md"
COORDINATOR_RUNTIME="$ROOT/skills/references/workflow-runtime/coordinator-runtime.md"
REVIEW_POLICY="$ROOT/skills/references/workflow-runtime/review-policy.md"
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

forbid_flattened_pattern() {
  local file="$1" description="$2" pattern="$3" text

  text="$(tr '\n' ' ' <"$file")"
  ! grep -Eiq -- "$pattern" <<<"$text" ||
    fail "$file retains forbidden forecast form: $description"
}

assert_local_links_resolve() {
  local file target resolved
  local -a documents=(
    "$ECI"
    "$ATE"
    "$DEBUGGING"
    "$ECI_COVERAGE"
    "$ATE_COVERAGE"
    "$ROOT/skills/explore-critique-implement/references/coordinator.md"
    "$ROOT/skills/explore-critique-implement/references/critique.md"
    "$EMERGENCY"
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
    '| emergency implementer |'; do
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
  require_text "$ECI" 'Maintenance provenance: [coverage map](references/coverage-map.md).'
  require_text "$ATE" 'Maintenance provenance: [coverage map](references/coverage-map.md).'
  require_text "$ECI_COVERAGE" '## Pre-split coverage map'
  require_text "$ECI_COVERAGE" 'Baseline source SHA-256: `ee11cdc0d7a092a22d4abb71c03103cc87c2a6a7e788a4020ee61605a40f1713`.'
  require_text "$ATE_COVERAGE" '## Pre-split coverage map'
  require_text "$ATE_COVERAGE" 'Baseline source SHA-256: `9d9d990b4c65c2175bd10d87949512293fc64704aeb4672a868702aa0bcd6623`.'
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
    'Wait for all required review and E2E evidence before aggregating.' \
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

require_section_pattern() {
  local section="$1" description="$2" pattern="$3" flattened

  flattened="$(tr '\n' ' ' <<<"$section")"
  grep -Eiq -- "$pattern" <<<"$flattened" ||
    fail "section is missing: $description"
}

assert_configuration_e2e_contract() {
  local section e2e

  require_line "$ECI" '## Configuration E2E contract'
  section="$(extract_h2_section "$ECI" '## Configuration E2E contract')" ||
    fail "$ECI lacks a bounded Configuration E2E section"
  e2e='(e2e|\*e2e\*|\*\*e2e\*\*|_e2e_|__e2e__)'
  require_section_pattern "$section" 'all configuration changes, including configuration-only work, require E2E' \
    "((every[[:space:]]+configuration[[:space:]]+change|all[[:space:]]+configuration[[:space:]]+changes),?[[:space:]]+including[[:space:]]+configuration-only[[:space:]]+work|including[[:space:]]+configuration-only[[:space:]]+work,?[[:space:]]+(every[[:space:]]+configuration[[:space:]]+change|all[[:space:]]+configuration[[:space:]]+changes))[[:space:]]*,?[[:space:]]+requires[[:space:]]+${e2e}([[:space:].,;:!?]|$)"
  require_section_pattern "$section" 'the implementer runs E2E before Step 4' \
    "the[[:space:]]+implementer[[:space:]]+(runs[[:space:]]+that|performs[[:space:]]+the[[:space:]]+required)[[:space:]]+${e2e}[[:space:]]+before[[:space:]]+step[[:space:]]+4"
  require_section_pattern "$section" 'Step 4 independently repeats or extends the implementer E2E' \
    "step[[:space:]]+4[[:space:]]+independently[[:space:]]+repeats[[:space:]]+or[[:space:]]+extends[[:space:]]+the[[:space:]]+implementer.?s[[:space:]]+${e2e}([[:space:].,;:!?]|$)"
  require_section_pattern "$section" 'the Configuration E2E requirement may not be waived' \
    "this[[:space:]]+configuration[[:space:]]+${e2e}[[:space:]]+requirement[[:space:]]+may[[:space:]]+not[[:space:]]+be[[:space:]]+waived"
}

assert_runtime_e2e_policy() {
  local section

  require_line "$ECI" '## Runtime E2E policy'
  section="$(extract_h2_section "$ECI" '## Runtime E2E policy')" ||
    fail "$ECI lacks a bounded Runtime E2E section"
  require_section_pattern "$section" 'runtime-facing code/debug work requires E2E' \
    'code/debug[[:space:]]+work.*runtime[[:space:]]+behavior.*requires[[:space:]]+e2e'
  require_section_pattern "$section" 'the runtime implementer runs E2E before Step 4' \
    'implementer[[:space:]]+runs[[:space:]]+it[[:space:]]+before[[:space:]]+step[[:space:]]+4'
  require_section_pattern "$section" 'Step 4 independently repeats or extends runtime E2E' \
    'step[[:space:]]+4[[:space:]]+independently[[:space:]]+repeats[[:space:]]+or[[:space:]]+extends[[:space:]]+it'
  require_section_pattern "$section" 'runtime E2E exercises the relevant real path' \
    'full[[:space:]]+suite[[:space:]]+where[[:space:]]+applicable.*affected[[:space:]]+real[[:space:]]+ui/api/device/cli[[:space:]]+path'
}

assert_e2e_policy_consumer_pointers() {
  local eci_pointer review_policy_pointer

  eci_pointer='E2E requirements: [Configuration E2E contract](../SKILL.md#configuration-e2e-contract) and [Runtime E2E policy](../SKILL.md#runtime-e2e-policy).'
  review_policy_pointer='E2E requirements: [Configuration E2E contract](../../explore-critique-implement/SKILL.md#configuration-e2e-contract) and [Runtime E2E policy](../../explore-critique-implement/SKILL.md#runtime-e2e-policy).'
  require_line "$IMPLEMENT" "$eci_pointer"
  require_line "$REVIEW" "$eci_pointer"
  require_line "$COORDINATOR" "$eci_pointer"
  require_line "$REVIEW_POLICY" "$review_policy_pointer"
}

assert_no_direct_configuration_e2e_waivers_in_input() {
  local source="$1" input="$2" line continuation e2e e2e_end configuration_work configuration_target configuration_e2e
  local primary_configuration_e2e_action no_waiver_action implementer_e2e_action step4_e2e_action required_e2e_action direct_caveat_suffix
  local nonconfiguration_emergency_waiver emergency_section=none
  local line_number=0 emergency_policy_line=0 emergency_provisional_line=0
  local emergency_policy_count=0 emergency_provisional_count=0
  local -a direct_waiver_patterns

  [ "$#" -ne 3 ] || input="$3"
  e2e='(e2e|\*e2e\*|\*\*e2e\*\*|_e2e_|__e2e__)'
  e2e_end='([[:space:].,;:!?]|$)'
  configuration_work='(^|[^[:alnum:]-])configuration(-only)?[[:space:]]+(changes?|work)'
  configuration_target='configuration(-only)?([[:space:]]+(changes?|work))?'
  configuration_e2e="(^|[^[:alnum:]-])configuration(-only)?([[:space:]]+(changes?|work))?[[:space:]]+${e2e}"
  primary_configuration_e2e_action="((every[[:space:]]+configuration[[:space:]]+change|all[[:space:]]+configuration[[:space:]]+changes),?[[:space:]]+including[[:space:]]+configuration-only[[:space:]]+work|including[[:space:]]+configuration-only[[:space:]]+work,?[[:space:]]+(every[[:space:]]+configuration[[:space:]]+change|all[[:space:]]+configuration[[:space:]]+changes))[[:space:]]*,?[[:space:]]+requires[[:space:]]+${e2e}"
  no_waiver_action="this[[:space:]]+configuration[[:space:]]+${e2e}[[:space:]]+requirement[[:space:]]+may[[:space:]]+not[[:space:]]+be[[:space:]]+waived"
  implementer_e2e_action="the[[:space:]]+implementer[[:space:]]+(runs[[:space:]]+that|performs[[:space:]]+the[[:space:]]+required)[[:space:]]+${e2e}[[:space:]]+before[[:space:]]+step[[:space:]]+4"
  step4_e2e_action="step[[:space:]]+4[[:space:]]+independently[[:space:]]+repeats[[:space:]]+or[[:space:]]+extends[[:space:]]+(its|the[[:space:]]+implementer.?s)[[:space:]]+${e2e}"
  required_e2e_action="(${primary_configuration_e2e_action}|${no_waiver_action}|${implementer_e2e_action}|${step4_e2e_action})"
  direct_caveat_suffix='[[:space:],;:()]*(except|unless)([[:space:]]|$)'
  nonconfiguration_emergency_waiver='> For a non-configuration change, E2E may also be waived. E2E required by the [Configuration E2E contract](../SKILL.md#configuration-e2e-contract) may not be waived.'
  direct_waiver_patterns=(
    "${configuration_work}[[:space:],]+((may|can)[[:space:]]+(omit|skip|waive)|do(es)?[[:space:]]+not[[:space:]]+(need|require|run|perform)|need[[:space:]]+not[[:space:]]+(require|run|perform))[[:space:]]+${e2e}${e2e_end}"
    "${e2e}[[:space:]]+(may|can)[[:space:]]+be[[:space:]]+(omitted|skipped|waived)[[:space:]]+for[[:space:]]+${configuration_target}"
    "${e2e}[[:space:]]+is[[:space:]]+optional[[:space:]]+for[[:space:]]+${configuration_target}"
    "${e2e}[[:space:]]+for[[:space:]]+${configuration_target}[[:space:],]+(may|can)[[:space:]]+be[[:space:]]+(omitted|skipped|waived)${e2e_end}"
    "${e2e}[[:space:]]+for[[:space:]]+${configuration_target}[[:space:]]+is[[:space:]]+optional${e2e_end}"
    "skip[[:space:]]+${e2e}[[:space:]]+for[[:space:]]+${configuration_target}"
    "${configuration_e2e}[[:space:],]+(may|can)[[:space:]]+be[[:space:]]+(omitted|skipped|waived)${e2e_end}"
    "${configuration_e2e}[[:space:]]+is[[:space:]]+optional${e2e_end}"
    "${required_e2e_action}${direct_caveat_suffix}"
  )

  continuation=''
  while IFS= read -r line || [ -n "$line" ]; do
    line_number=$((line_number + 1))
    if [ "$source" = "$EMERGENCY" ]; then
      case "$line" in
        '## Emergency policy')
          emergency_section=policy
          emergency_policy_count=$((emergency_policy_count + 1))
          emergency_policy_line="$line_number"
          continuation=''
          continue
          ;;
        '## Provisional action')
          emergency_section=provisional
          emergency_provisional_count=$((emergency_provisional_count + 1))
          emergency_provisional_line="$line_number"
          continuation=''
          continue
          ;;
        '## '*)
          emergency_section=other
          continuation=''
          continue
          ;;
      esac
    fi
    if [ "$source" = "$EMERGENCY" ] && [ "$emergency_section" = policy ] &&
      [ "$line" = "$nonconfiguration_emergency_waiver" ]; then
      continuation=''
      continue
    fi
    if [[ "$line" =~ ^[[:space:]]*\>[[:space:]]*(.*)$ ]]; then
      if [ "$source" = "$EMERGENCY" ] && [ "$emergency_section" = policy ]; then
        line="${BASH_REMATCH[1]}"
      else
        continuation=''
        continue
      fi
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

  if [ "$source" = "$EMERGENCY" ] &&
    { [ "$emergency_policy_count" -ne 1 ] || [ "$emergency_provisional_count" -ne 1 ] ||
      [ "$emergency_policy_line" -ge "$emergency_provisional_line" ]; }; then
    fail "$source requires exactly one ordered ## Emergency policy and ## Provisional action section"
  fi
}

assert_no_direct_configuration_e2e_waivers() {
  local file input

  for file in "$ECI" "$IMPLEMENT" "$REVIEW" "$COORDINATOR" "$REVIEW_POLICY" "$EMERGENCY"; do
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

emergency_fixture() {
  local policy_text="$1" provisional_text="$2"

  printf '%s\n%s\n\n%s\n%s\n' \
    '## Emergency policy' "$policy_text" \
    '## Provisional action' "$provisional_text"
}

assert_configuration_e2e_waiver_fixtures() {
  local primary_configuration_contract no_waiver_contract implementer_contract step4_contract
  local emergency_line reverse_action reverse_modal

  primary_configuration_contract='Every configuration change, including configuration-only work, requires E2E'
  no_waiver_contract='This Configuration E2E requirement may not be waived'
  implementer_contract='The implementer runs that E2E before Step 4'
  step4_contract='Step 4 independently repeats or extends its E2E'
  emergency_line='> For a non-configuration change, E2E may also be waived. E2E required by the [Configuration E2E contract](../SKILL.md#configuration-e2e-contract) may not be waived.'
  assert_direct_configuration_e2e_waiver_is_rejected "$EMERGENCY" 'configuration reverse waiver' \
    "$(emergency_fixture '> Configuration E2E may be waived.' '> ordinary operational text.')"
  for reverse_modal in may can; do
    for reverse_action in omitted skipped waived; do
      assert_direct_configuration_e2e_waiver_is_rejected "$EMERGENCY" "configuration changes E2E $reverse_modal be $reverse_action" \
        "$(emergency_fixture "> Configuration changes E2E $reverse_modal be $reverse_action." '> ordinary operational text.')"
      assert_direct_configuration_e2e_waiver_is_rejected "$EMERGENCY" "E2E for configuration changes $reverse_modal be $reverse_action" \
        "$(emergency_fixture "> E2E for configuration changes $reverse_modal be $reverse_action." '> ordinary operational text.')"
    done
  done
  assert_direct_configuration_e2e_waiver_is_rejected "$EMERGENCY" 'configuration changes E2E optional' \
    "$(emergency_fixture '> Configuration changes E2E is optional.' '> ordinary operational text.')"
  assert_direct_configuration_e2e_waiver_is_rejected "$EMERGENCY" 'E2E for configuration changes optional' \
    "$(emergency_fixture '> E2E for configuration changes is optional.' '> ordinary operational text.')"
  assert_direct_configuration_e2e_waiver_is_rejected "$EMERGENCY" 'E2E for configuration changes comma continuation' \
    "$(emergency_fixture $'> E2E for configuration changes may be waived,\n> unless urgent.' '> ordinary operational text.')"
  for reverse_action in omitted skipped; do
    assert_direct_configuration_e2e_waiver_is_rejected "$EMERGENCY" "configuration may be $reverse_action" \
      "$(emergency_fixture "> Configuration E2E may be $reverse_action." '> ordinary operational text.')"
  done
  for reverse_action in omitted skipped waived; do
    assert_direct_configuration_e2e_waiver_is_rejected "$EMERGENCY" "configuration can be $reverse_action" \
      "$(emergency_fixture "> Configuration E2E can be $reverse_action." '> ordinary operational text.')"
  done
  assert_direct_configuration_e2e_waiver_is_rejected "$EMERGENCY" 'configuration optional reverse waiver' \
    "$(emergency_fixture '> Configuration E2E is optional.' '> ordinary operational text.')"
  assert_direct_configuration_e2e_waiver_is_rejected "$EMERGENCY" 'configuration reverse waiver comma continuation' \
    "$(emergency_fixture $'> Configuration E2E may be waived,\n> for a late change.' '> ordinary operational text.')"

  for reverse_modal in may can; do
    for reverse_action in omit skip waive; do
      assert_direct_configuration_e2e_waiver_is_rejected "$EMERGENCY" "configuration work $reverse_modal $reverse_action E2E" \
        "$(emergency_fixture "> Configuration work $reverse_modal $reverse_action E2E." '> ordinary operational text.')"
    done
  done
  for reverse_modal in may can; do
    for reverse_action in omitted skipped waived; do
      assert_direct_configuration_e2e_waiver_is_rejected "$EMERGENCY" "E2E $reverse_modal be $reverse_action for configuration" \
        "$(emergency_fixture "> E2E $reverse_modal be $reverse_action for configuration." '> ordinary operational text.')"
    done
  done
  assert_direct_configuration_e2e_waiver_is_rejected "$EMERGENCY" 'E2E optional for configuration' \
    "$(emergency_fixture '> E2E is optional for configuration.' '> ordinary operational text.')"
  assert_direct_configuration_e2e_waiver_is_rejected "$EMERGENCY" 'skip E2E for configuration' \
    "$(emergency_fixture '> Skip E2E for configuration.' '> ordinary operational text.')"
  assert_direct_configuration_e2e_waiver_is_rejected "$ECI" 'no-waiver comma-soft-wrap except caveat' \
    "$no_waiver_contract,"$'\n''except for late changes.'
  assert_direct_configuration_e2e_waiver_is_rejected "$ECI" 'implementer comma-soft-wrap unless caveat' \
    "$implementer_contract,"$'\n''unless a manager says otherwise.'
  assert_direct_configuration_e2e_waiver_is_rejected "$ECI" 'Step 4 comma-soft-wrap except caveat' \
    "$step4_contract,"$'\n''except a review is delayed.'

  assert_direct_configuration_e2e_waiver_is_rejected "$ECI" 'primary contract except caveat' \
    "$primary_configuration_contract, except for late changes."
  assert_direct_configuration_e2e_waiver_is_rejected "$ECI" 'primary contract unless caveat' \
    "$primary_configuration_contract unless a manager says otherwise."
  assert_direct_configuration_e2e_waiver_is_rejected "$ECI" 'no-waiver contract except caveat' \
    "$no_waiver_contract except for late changes."
  assert_direct_configuration_e2e_waiver_is_rejected "$ECI" 'implementer contract unless caveat' \
    "$implementer_contract unless a manager says otherwise."
  assert_direct_configuration_e2e_waiver_is_rejected "$ECI" 'Step 4 contract except caveat' \
    "$step4_contract except a review is delayed."
  assert_direct_configuration_e2e_waiver_is_rejected "$ECI" 'singular configuration waiver' \
    'Configuration change does not require E2E.'
  assert_direct_configuration_e2e_waiver_is_rejected "$EMERGENCY" 'Emergency quote primary contract except caveat' \
    "$(emergency_fixture "> $primary_configuration_contract, except for late changes." '> ordinary operational text.')"
  assert_direct_configuration_e2e_waiver_is_rejected "$ECI" 'ECI primary comma-soft-wrap except caveat' \
    "$primary_configuration_contract, "$'\n''except for late changes.'
  assert_direct_configuration_e2e_waiver_is_rejected "$EMERGENCY" 'Emergency quote comma-soft-wrap except caveat' \
    "$(emergency_fixture "> $primary_configuration_contract, "$'\n''> except for late changes.' '> ordinary operational text.')"
  assert_direct_configuration_e2e_waiver_is_rejected "$ECI" 'ECI primary comma-no-space soft-wrap except caveat' \
    "$primary_configuration_contract,"$'\n''except for late changes.'
  assert_direct_configuration_e2e_waiver_is_rejected "$EMERGENCY" 'Emergency quote comma-no-space soft-wrap except caveat' \
    "$(emergency_fixture "> $primary_configuration_contract,"$'\n''> except for late changes.' '> ordinary operational text.')"
  assert_no_direct_configuration_e2e_waivers_in_input "$ECI" 'fixture: non-Emergency historical blockquote primary caveat' \
    "> $primary_configuration_contract, except for late changes."
  assert_no_direct_configuration_e2e_waivers_in_input "$ECI" 'fixture: later separate prose' \
    "$primary_configuration_contract."$'\n''A later prose sentence mentions except and unless without changing the contract.'
  assert_no_direct_configuration_e2e_waivers_in_input "$ECI" 'fixture: comma then blank line' \
    "$primary_configuration_contract, "$'\n\n''except for late changes.'
  assert_no_direct_configuration_e2e_waivers_in_input "$EMERGENCY" 'fixture: exact nonconfiguration Emergency line' \
    "$(emergency_fixture "$emergency_line" '> ordinary operational text.')"
  assert_no_direct_configuration_e2e_waivers_in_input "$EMERGENCY" 'fixture: quoted nonconfiguration reverse waiver in Emergency policy' \
    "$(emergency_fixture '> Non-configuration E2E may be waived.' '> ordinary historical text.')"
  assert_no_direct_configuration_e2e_waivers_in_input "$EMERGENCY" 'fixture: quoted E2E-for-nonconfiguration waiver in Emergency policy' \
    "$(emergency_fixture '> E2E for non-configuration changes may be waived.' '> ordinary historical text.')"
  assert_no_direct_configuration_e2e_waivers_in_input "$EMERGENCY" 'fixture: historical quote under provisional action' \
    "$(emergency_fixture '> normative policy remains unchanged.' '> Configuration E2E may be waived.')"
  assert_no_direct_configuration_e2e_waivers_in_input "$EMERGENCY" 'fixture: E2E-for-configuration quote under provisional action' \
    "$(emergency_fixture '> normative policy remains unchanged.' '> E2E for configuration changes may be waived.')"
  assert_direct_configuration_e2e_waiver_is_rejected "$EMERGENCY" 'quoted E2E-for-configuration waiver under Emergency policy' \
    "$(emergency_fixture '> E2E for configuration changes may be waived.' '> ordinary operational text.')"
  assert_direct_configuration_e2e_waiver_is_rejected "$EMERGENCY" 'normative Emergency policy caveat' \
    "$(emergency_fixture "> $primary_configuration_contract, except for late changes." '> ordinary operational text.')"
  assert_no_direct_configuration_e2e_waivers_in_input "$EMERGENCY" 'fixture: nonconfiguration reverse waiver' \
    "$(emergency_fixture '> normative policy remains unchanged.' 'Non-configuration E2E may be waived.')"
  assert_direct_configuration_e2e_waiver_is_rejected "$EMERGENCY" 'unquoted provisional reverse waiver remains scanned' \
    "$(emergency_fixture '> normative policy remains unchanged.' 'Configuration E2E may be waived.')"
  assert_direct_configuration_e2e_waiver_is_rejected "$EMERGENCY" 'unquoted E2E-for-configuration waiver under provisional action remains scanned' \
    "$(emergency_fixture '> normative policy remains unchanged.' 'E2E for configuration changes may be waived.')"
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

assert_emergency_qualification_source() {
  local file
  require_text "$ECI" 'Potential Emergency Unblock cases load [Emergency Unblock](references/emergency-unblock.md) to determine qualification.'
  require_text "$ECI" '[Emergency Unblock](references/emergency-unblock.md) to assess a potential case'
  require_text "$ECI" 'only after coordinator qualification; immediately rejoin normal Step 1'
  require_text "$EMERGENCY" 'Coordinator loads this module to assess a potential case.'
  require_text "$EMERGENCY" 'The assigned emergency implementer loads it only after coordinator qualification.'
  require_text "$EMERGENCY" 'Eligible only when already available direct evidence shows that the user is blocked now;'
  require_text "$EMERGENCY" 'Route one implementer to make only the smallest repair.'
  require_text "$EMERGENCY" 'make no second emergency repair'
  for file in "$ECI" "$ATE" "$ATE_ORCHESTRATION" "$ATE_RESEARCH" "$ATE_DESIGN" "$ATE_EXECUTION" "$ATE_REVIEW" "$ATE_TESTING"; do
    if grep -Fq -- 'Eligible only when already available direct evidence shows that the user is blocked now;' "$file"; then
      fail "Emergency qualification phrase escaped its sole reference: $file"
    fi
  done
  ! grep -Fq -- 'Emergency Unblock qualifies only when' "$ECI" ||
    fail 'ECI router duplicates Emergency qualification'
}

assert_emergency_and_go_preference() {
  require_text "$ECI" '| emergency implementer | [Emergency Unblock](references/emergency-unblock.md) |'
  require_text "$EMERGENCY" '# Emergency Unblock'
  require_line "$EMERGENCY" '## Emergency policy'
  require_line "$EMERGENCY" '## Provisional action'
  require_text "$EMERGENCY" '**Emergency Unblock** is a one-shot provisional path before normal ECI.'
  require_text "$EMERGENCY" 'Eligible only when already available direct evidence shows that the user is blocked now;'
  require_text "$EMERGENCY" 'the exact bug cause and repair, or the exact missing-capability change and repair, are already known;'
  require_text "$EMERGENCY" 'one smallest bounded reversible repair is obvious;'
  require_text "$EMERGENCY" 'no material competing diagnosis or approach exists;'
  require_text "$EMERGENCY" 'Qualification performs no new diagnosis, reproduction, exploration, comparison, or hypothesis testing.'
  require_line "$EMERGENCY" '> For a non-configuration change, E2E may also be waived. E2E required by the [Configuration E2E contract](../SKILL.md#configuration-e2e-contract) may not be waived.'
  require_text "$EMERGENCY" '**“provisional Emergency Unblock — unchecked”**'
  require_text "$EMERGENCY" 'Immediately after that action, start normal ECI Step 1 against the changed state.'
  require_text "$EMERGENCY" 'If the repair fails, uncertainty appears, diagnosis is hard, or another unchecked change seems necessary, make no second emergency repair: load `debugging-discipline` and enter the normal debugging route.'
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
  require_text "$STATUS_REPORT" 'stage grammar and its records never authorize or deny normal'
  require_text "$STATUS_REPORT" 'work or change the implementation/test/production status meanings below.'
  forbid_text "$STATUS_REPORT" 'Every lane records `Stage: normal` or `Stage: emergency`.'
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
  role_or_stage='(explorer|implementer|coordinator|e2e|critic([[:blank:]]+(a|b|c)|[-[:blank:]]*step[[:blank:]]*2)?|step[[:blank:]]*2[[:blank:]]+critic|emergency[[:blank:]]+implementer|brainstormer|feasibility[[:blank:]]+validator|loop-breaker|reviewer|actor|stage([[:blank:]]*:[[:blank:]]*[^[:space:]]+)?)'
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

  attached_lane_template='Every[[:space:]]+material[[:space:]]+coordinator-to-user[[:space:]]+status/progress[[:space:]]+update[[:space:]]+for[[:space:]]+a[[:space:]]+user-rooted[[:space:]]+outcome[[:space:]]+has[[:space:]]+exactly[[:space:]]+one[[:space:]]+`Forecast[[:space:]]+targets`[[:space:]]+block\.[[:space:]]+Place[[:space:]]+it[[:space:]]+after[[:space:]]+changed[[:space:]]+state[[:space:]]+and[[:space:]]+before[[:space:]]+Verification/Next[[:space:]]+focus\.[[:space:]]+[-*][[:space:]]+For[[:space:]]+each[[:space:]]+executing[[:space:]]+lane,[[:space:]]+report[[:space:]]+this[[:space:]]+standalone[[:space:]]+line:[[:space:]]+[-*][[:space:]]*`[[:space:]]*Forecast[[:space:]]+deadline:[[:space:]]+<named[[:space:]]+lane/task[[:space:]]+outcome>[[:space:]]+will[[:space:]]+be[[:space:]]+finished[[:space:]]+by[[:space:]]+<UTC[[:space:]]+ISO8601>\.[[:space:]]*`'
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
    'Emergency implementer'
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
  source_pair=$'- Every material coordinator-to-user status/progress update for a user-rooted outcome has exactly one `Forecast targets` block. Place it after changed state and before Verification/Next focus.\n  - For each executing lane, report this standalone line:\n    - `Forecast deadline: <named lane/task outcome> will be finished by <UTC ISO8601>.`\n  - For each unrepresented active root-task outcome omitted by lane reports, include this standalone line:\n    - `Root completion forecast: <named active root-task outcome> will be finished by <UTC ISO8601>.`'
  soft_wrapped_pair=$'- Every material coordinator-to-user status/progress update for a user-rooted outcome has exactly one `Forecast targets` block. Place it after changed state and before Verification/Next focus.\n  - For each executing lane, report this standalone line:\n    - `Forecast deadline: <named lane/task outcome> will be finished by\n<UTC ISO8601>.`\n  - For each unrepresented active root-task outcome omitted by lane reports, include this standalone line:\n    - `Root completion forecast: <named active root-task outcome> will be finished by\n<UTC ISO8601>.`'
  detached_pair=$'- Every material coordinator-to-user status/progress update for a user-rooted outcome has exactly one `Forecast targets` block. Place it after changed state and before Verification/Next focus.\n  - For each executing lane, report this standalone line:\n    - See the historical appendix.\n  - For each unrepresented active root-task outcome omitted by lane reports, include this standalone line:\n    - See the historical appendix.'
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

require_forecast_target_history_occurrences() {
  local source="$1" description="$2" expected="$3" input="$4" count

  count="$(grep -Fc -- "$expected" <<<"$input" || true)"
  [ "$count" -eq 1 ] ||
    fail "$source violates forecast target history contract: $description"
}

assert_forecast_target_history_ledger_contract() {
  local source="$1" input="$2" header

  header=$'added_utc\troot_task_id\tnew_target_utc'
  require_forecast_target_history_text "$source" 'canonical history name' \
    '`forecast-target-history.tsv` is the canonical audit-only history for root-task forecast targets.' "$input"
  require_forecast_target_history_text "$source" 'exact TSV header' "$header" "$input"
  require_forecast_target_history_text "$source" 'append-only rows' \
    'Append only: never edit, delete, reorder, or reuse a row.' "$input"
  require_forecast_target_history_text "$source" 'none-to-A transition' \
    '| none → A | Append a material `high_level_log.md` entry naming A, why, and evidence. | Append A row. |' "$input"
  require_forecast_target_history_text "$source" 'A-to-B transition' \
    '| A → B | Append a material `high_level_log.md` entry naming prior A, new B, why, and evidence. | Append B row. |' "$input"
  require_forecast_target_history_text "$source" 'A-to-A reaffirmation rule' \
    '| A → A | No high-level-log entry or history row for mere reaffirmation. | No row. |' "$input"
  require_forecast_target_history_text "$source" 'close row rule' \
    '| close | Record material completion normally. | No date row. |' "$input"
  require_forecast_target_history_text "$source" 'append-only correction rule' \
    '| correction | Append a correction naming the prior entry and corrected target. | Append the corrected-target row; never rewrite earlier rows. |' "$input"
  require_forecast_target_history_text "$source" 'audit-only non-gate boundary' \
    'This history is audit-only. It never gates work, grants or denies permission, creates a blocker, or delays ordinary work.' "$input"
  require_forecast_target_history_text "$source" 'not a required session record' \
    'It is not a required session record or work prerequisite.' "$input"
}

assert_forecast_target_history_coordinator_contract() {
  local source="$1" input="$2" preamble

  preamble='- Every material coordinator-to-user status/progress update for a user-rooted outcome has exactly one `Forecast targets` block. Place it after changed state and before Verification/Next focus.'
  require_forecast_target_history_text "$source" 'ledger audit-contract pointer' \
    'Use the [`forecast-target-history.tsv` audit contract](../../maintaining-context-ledger/SKILL.md#forecast-target-history) for every root-target transition. It is audit-only and never a gate.' "$input"
  require_forecast_target_history_text "$source" 'material target-block preamble' "$preamble" "$input"
  require_forecast_target_history_occurrences "$source" 'target-block preamble is duplicated or absent' "$preamble" "$input"
  require_forecast_target_history_text "$source" 'no duplicate target lines' \
    "- Do not repeat that block's preamble or canonical target line elsewhere in the update." "$input"
  require_forecast_target_history_text "$source" 'non-material output omission' \
    '- Preparatory, pure explanatory, and pure timeline output omit the block. If it materially changes state, use the one material-update block.' "$input"
  require_forecast_target_history_text "$source" 'requested-outcome repair stays in lane' \
    '- A repair needed to meet or prove that outcome stays in its current lane; a' "$input"
  require_forecast_target_history_text "$source" 'separate outcome remains post-ECI' \
    'separate-outcome concern is only a post-ECI observation or follow-up, never' "$input"
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
  local ledger coordinator header preamble mutation

  ledger="$(<"$LEDGER")"
  coordinator="$(<"$COORDINATOR")"
  header=$'added_utc\troot_task_id\tnew_target_utc'
  preamble='- Every material coordinator-to-user status/progress update for a user-rooted outcome has exactly one `Forecast targets` block. Place it after changed state and before Verification/Next focus.'

  mutation="${ledger/"$header"/$'added_utc\troot_task_id\ttarget_utc'}"
  [ "$mutation" != "$ledger" ] || fail 'forecast target-history schema mutation did not alter its fixture'
  assert_forecast_target_history_mutation_is_rejected assert_forecast_target_history_ledger_contract "$LEDGER" 'schema' "$mutation"

  mutation="${ledger/'| A → B | Append a material `high_level_log.md` entry naming prior A, new B, why, and evidence. | Append B row. |'/'| A → B | Append a material entry naming new B. | Append B row. |'}"
  [ "$mutation" != "$ledger" ] || fail 'forecast target-history transition mutation did not alter its fixture'
  assert_forecast_target_history_mutation_is_rejected assert_forecast_target_history_ledger_contract "$LEDGER" 'A-to-B transition evidence' "$mutation"

  mutation="${ledger/'This history is audit-only. It never gates work, grants or denies permission, creates a blocker, or delays ordinary work.'/'This history gates work.'}"
  [ "$mutation" != "$ledger" ] || fail 'forecast target-history audit-only mutation did not alter its fixture'
  assert_forecast_target_history_mutation_is_rejected assert_forecast_target_history_ledger_contract "$LEDGER" 'audit-only non-gate boundary' "$mutation"

  mutation="${ledger/'Append the corrected-target row; never rewrite earlier rows.'/'Rewrite the prior row with the corrected target.'}"
  [ "$mutation" != "$ledger" ] || fail 'forecast target-history correction mutation did not alter its fixture'
  assert_forecast_target_history_mutation_is_rejected assert_forecast_target_history_ledger_contract "$LEDGER" 'append-only correction' "$mutation"

  mutation="${coordinator/'- Preparatory, pure explanatory, and pure timeline output omit the block. If it materially changes state, use the one material-update block.'/'- Preparatory, pure explanatory, and pure timeline output include the block.'}"
  [ "$mutation" != "$coordinator" ] || fail 'forecast target-block placement mutation did not alter its fixture'
  assert_forecast_target_history_mutation_is_rejected assert_forecast_target_history_coordinator_contract "$COORDINATOR" 'reporting placement' "$mutation"

  mutation="${coordinator/'post-ECI observation or follow-up'/'current lane work'}"
  [ "$mutation" != "$coordinator" ] || fail 'forecast target-block scope mutation did not alter its fixture'
  assert_forecast_target_history_mutation_is_rejected assert_forecast_target_history_coordinator_contract "$COORDINATOR" 'requested-outcome repair stays in lane' "$mutation"

  mutation="${coordinator/"$preamble"/"$preamble"$'\n'"$preamble"}"
  [ "$mutation" != "$coordinator" ] || fail 'forecast target-block duplicate-preamble mutation did not alter its fixture'
  assert_forecast_target_history_mutation_is_rejected assert_forecast_target_history_coordinator_contract "$COORDINATOR" 'duplicate preamble' "$mutation"
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
  local source="$1" input="$2"

  require_primary_scope_fidelity_text "$source" 'material source-outcome-scope chain' \
    '- For material ECI work, keep `exact user source → faithful requested outcome' "$input"
  require_primary_scope_fidelity_text "$source" 'bounded scope in primary chain' \
    'bounded scope`.' "$input"
  require_primary_scope_fidelity_text "$source" 'necessary repair remains current-lane work' \
    'A repair necessary to meet or prove that outcome stays current-lane work.' "$input"
  require_primary_scope_fidelity_text "$source" 'separate outcome is only post-ECI follow-up' \
    'A concern serving a separate outcome is only a post-ECI user follow-up, never current work.' "$input"
  require_primary_scope_fidelity_text "$source" 'stale lineage remains nonblocking' \
    'Missing or stale lineage never blocks known in-scope work.' "$input"
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

  mutation="${primary/'Missing or stale lineage never blocks known in-scope work.'/'Missing or stale lineage blocks known in-scope work.'}"
  [ "$mutation" != "$primary" ] || fail 'primary stale-lineage mutation did not alter its fixture'
  assert_primary_scope_fidelity_mutation_is_rejected "$ECI" 'stale lineage blocks known work' "$mutation"
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
  require_text "$PAUSE" 'Accept either command only while the current session has a verified'
  require_text "$PAUSE" 'verified `pause-all-work-report.md` and pause transaction bound to its session and canonical cwd.'
  require_text "$PAUSE" 'An active marker from another session never satisfies this binding.'
  require_text "$PAUSE" 'Quoted, conditional, status, timer, provider, and one-task variants never match.'
  require_text "$POLICY" 'after a verified pause, accept only exact user-owned resume/closure commands bound to the current pause transaction'

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
  require_text "$REVIEW_POLICY" 'Normal reviewer packets contain original user requirements, exact target/diff, `loop-id`, applicable `decision-id`, objective/criteria, general pre-routing record, admitted style record/deltas/tool evidence, full applicable lineage/binding, and all scrutiny rules.'
  require_text "$REVIEW_POLICY" "$policy_checkpoint_packet"
  require_text "$COORDINATOR_RUNTIME" 'This reference routes work and review; it is not a permission system.'
  require_text "$COORDINATOR_RUNTIME" 'Use normal targeted Git coordination: preserve unrelated dirty paths as exclusions. It needs no approval artifact, receipt, hash, canonical spelling, or command-shape prerequisite.'
  forbid_text "$COORDINATOR_RUNTIME" 'A checkpoint requires a new receipt, permission, or Git prerequisite.'
}

assert_local_links_resolve
assert_role_rows_are_local
assert_debugging_role_routes
assert_eci_relationships
assert_compaction_provenance
assert_reviewer_role_split
assert_configuration_e2e_contract
assert_runtime_e2e_policy
assert_e2e_policy_consumer_pointers
assert_no_direct_configuration_e2e_waivers
assert_configuration_e2e_waiver_fixtures
assert_coordinator_bug_routing_is_nonblocking
assert_ate_ordinary_role_split
assert_emergency_qualification_source
assert_emergency_and_go_preference
assert_status_lane_stage_contract
assert_status_lane_stage_transition_fixture
assert_forecast_target_history_contract
assert_forecast_target_history_contract_mutations
assert_forecast_source_contract_fixtures
assert_coordinator_progress_forecast_contract_fixtures
assert_primary_scope_fidelity_contract "$ECI" "$(<"$ECI")"
assert_primary_scope_fidelity_contract_mutations
assert_scope_fidelity_pressure_fixtures
assert_scope_fidelity_pressure_mutations_are_rejected
assert_lane_forecast_contract
assert_source_forecast_mutations_are_rejected
assert_lineage_context_contract
assert_pause_resume_closure_contract
assert_eci_ordinary_role_split
assert_implementer_iteration_checkpoint_contract
printf '%s\n' 'workflow skill routing assertions: PASS'
