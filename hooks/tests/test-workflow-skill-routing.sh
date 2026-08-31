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

contains_checkpoint_baseline_contract() {
  local input="$1" baseline="$2" exclusions="$3" ambiguity="$4"

  [[ "$input" == *"$baseline"* &&
     "$input" == *"$exclusions"* &&
     "$input" == *"$ambiguity"* ]]
}

contains_checkpoint_review_packet() {
  local input="$1" bridge="$2" packet="$3" range="$4" exclusions="$5" scope="$6"

  [[ "$input" == *"$bridge"* &&
     "$input" == *"$packet"* &&
     "$input" == *"$range"* &&
     "$input" == *"$exclusions"* &&
     "$input" == *"$scope"* ]] &&
    require_order "$input" "$bridge" "$packet"
}

forbid_text() {
  local file="$1" text="$2"
  ! grep -Fq -- "$text" "$file" || fail "$file retains an ordinary-work gate: $text"
}

forbid_pattern() {
  local file="$1" pattern="$2"
  ! grep -Eiq -- "$pattern" "$file" || fail "$file retains an ordinary-work gate matching: $pattern"
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
  require_text "$STATUS_REPORT" 'Use readable requirement context when it is available in active ECI/ATE.'
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

assert_lane_forecast_contract() {
  local file header

  require_line "$STATUS_REPORT" '## Lane forecasts'
  header="$(grep -F -- '| Task ID | Parent ID | Lane | Lane requirement context | Stage | Owner |' "$STATUS_REPORT" || true)"
  [[ "$header" == *'| Next milestone |'* &&
     "$header" == *'| Remaining forecast / recalibration |'* &&
     "$header" == *'| Dependencies / overlap |'* &&
     "$header" == *'| Next proof/action |'* ]] ||
    fail 'status report lane table lacks forecast columns before Next proof/action'

  for file in "$STATUS_REPORT" "$LEDGER"; do
    require_text "$file" '`Next milestone: <named outcome>`'
    require_text "$file" '`Remaining forecast: <current honest time estimate/range>`'
    require_text "$file" '`Forecast recalibration: increased | decreased | unchanged — <why; evidence>`'
    require_text "$file" '`unchanged — baseline from <evidence>; no prior forecast`'
    require_text "$file" '`Remaining forecast: 0 h`'
    require_pattern "$file" 'non-additive overlapping forecast rule' 'Never[[:space:]]+add[[:space:]]+overlapping[[:space:]]+child[[:space:]]+estimates[[:space:]]+into[[:space:]]+a[[:space:]]+parent[[:space:]]+or[[:space:]]+mission[[:space:]]+forecast;[[:space:]]+name[[:space:]]+the[[:space:]]+non-overlapping[[:space:]]+sequence[[:space:]]+or[[:space:]]+critical[[:space:]]+path\.'
    require_pattern "$file" 'forecast coordination-only purpose' 'Forecasts[[:space:]]+are[[:space:]]+coordination[[:space:]]+aids[[:space:]]+for[[:space:]]+catching[[:space:]]+stale[[:space:]]+planning[[:space:]]+assumptions[[:space:]]+under[[:space:]]+the[[:space:]]+non-malicious-bot[[:space:]]+principle\.'
    require_pattern "$file" 'forecast non-gate boundary' 'They[[:space:]]+never[[:space:]]+authorize[[:space:]]+or[[:space:]]+deny[[:space:]]+work,[[:space:]]+create[[:space:]]+a[[:space:]]+user[[:space:]]+blocker,[[:space:]]+promise[[:space:]]+completion,[[:space:]]+require[[:space:]]+a[[:space:]]+receipt[[:space:]]+or[[:space:]]+artifact,[[:space:]]+or[[:space:]]+require[[:space:]]+per-command[[:space:]]+updates\.'
  done

  require_line "$LEDGER" '### Lane forecasts'
  require_pattern "$STATUS_REPORT" 'status-report recalibration delta, why, and evidence' 'Every[[:space:]]+material[[:space:]]+status[[:space:]]+report[[:space:]]+recalibrates[[:space:]]+each[[:space:]]+affected[[:space:]]+lane[[:space:]]+and[[:space:]]+records[[:space:]]+its[[:space:]]+delta,[[:space:]]+why,[[:space:]]+and[[:space:]]+evidence\.'
  require_pattern "$LEDGER" 'Progress source and status projection' 'Progress[[:space:]]+is[[:space:]]+the[[:space:]]+source[[:space:]]+of[[:space:]]+truth;[[:space:]]+`latest-status-report\.md`[[:space:]]+projects[[:space:]]+these[[:space:]]+fields[[:space:]]+using[[:space:]]+`writing-status-reports`\.'
  require_pattern "$LEDGER" 'ledger recalibration delta, why, and evidence' 'Every[[:space:]]+material[[:space:]]+ledger[[:space:]]+refresh[[:space:]]+recalibrates[[:space:]]+each[[:space:]]+affected[[:space:]]+lane[[:space:]]+and[[:space:]]+records[[:space:]]+its[[:space:]]+delta,[[:space:]]+why,[[:space:]]+and[[:space:]]+evidence\.'
  require_pattern "$LEDGER" 'forecast planning-quality, non-gate treatment' 'Missing[[:space:]]+or[[:space:]]+stale[[:space:]]+forecasts[[:space:]]+are[[:space:]]+planning-quality[[:space:]]+defects\.[[:space:]]+Reconcile[[:space:]]+them[[:space:]]+alongside[[:space:]]+safe[[:space:]]+work;[[:space:]]+they[[:space:]]+never[[:space:]]+gate[[:space:]]+work,[[:space:]]+authorization,[[:space:]]+or[[:space:]]+status[[:space:]]+reporting\.'
  require_text "$STATUS_REPORT" 'An active lane missing a named milestone or range is corrected alongside safe work.'
  require_text "$STATUS_REPORT" 'A copied estimate without `increased`, `decreased`, or `unchanged` plus why/evidence is stale.'
  require_text "$STATUS_REPORT" 'A paused dependency names its owner and resume condition; it is not a user blocker.'
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
  local step4_bridge coordinator_checkpoint coordinator_packet
  local review_range scope_exclusions scope_not_admission policy_checkpoint_packet
  local baseline_fixture review_fixture reversed_fixture clause

  baseline_contract='If Git cannot represent an iteration without earlier uncommitted content in the same target, first commit a separately named `pre-existing baseline` containing only independently verified, already-completed predecessor content currently coordinator-owned for the same lane.'
  baseline_exclusions='Exclude user-owned, another worker/lane, and in-flight content.'
  ambiguity_contract='If the baseline boundary remains ambiguous, preserve the worktree and re-explore the exact ambiguity while unrelated safe work continues.'
  step4_bridge='After the Step 3 handoff and before Step 4 or another implementation iteration, the coordinator applies the `CODEX.md` per-implementer checkpoint commit rule. Step 4 receives the named checkpoint, its parent-to-checkpoint diff, and explicit exclusions; a `pre-existing baseline` remains context outside the iteration range.'
  coordinator_checkpoint='Before reviewer dispatch, independently verify the implementer handoff'"'"'s exact scoped diff and create the named narrow coordinator-owned checkpoint commit required by `CODEX.md`.'
  coordinator_packet='The review packet gives each reviewer the named checkpoint, its parent-to-checkpoint diff, and explicit exclusions. A `pre-existing baseline` is context outside the iteration range. Neither is acceptance.'
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
  require_text "$CODEX" 'A later repair is a separate iteration and commit. Do not amend or delay the prior checkpoint.'
  require_text "$CODEX" 'Normal targeted Git coordination needs no approval artifact, receipt, hash, canonical spelling, or command-shape prerequisite.'
  forbid_text "$CODEX" 'Hold commits until stable.'
  forbid_text "$CODEX" 'amend a bad original rather than stack a fix commit'

  require_text "$IMPLEMENT" 'Never commit, declare accepted/complete, publish a manifest, or tear down ECI from this role.'
  require_text "$ECI" "$step4_bridge"
  require_order "$(<"$ECI")" "$step4_bridge" '4. Fresh A/B/C critics review in parallel;' ||
    fail 'ECI Step 3-to-4 checkpoint bridge must precede reviewer dispatch'
  require_text "$COORDINATOR" "$coordinator_checkpoint"
  require_text "$COORDINATOR" "$coordinator_packet"
  require_order "$(<"$COORDINATOR")" "$coordinator_packet" 'After this, the coordinator alone assigns fresh Critic A, Critic B, and Critic C.' ||
    fail 'coordinator checkpoint packet must precede reviewer dispatch'
  require_text "$COORDINATOR" 'Each reviewer is independent of producers and receives original requirements, named checkpoint, its parent-to-checkpoint diff, explicit exclusions, objective/criteria, pre-routing record, applicable style evidence, exact lens, and claim-tag rules.'
  require_text "$COORDINATOR_RUNTIME" 'After each implementer handoff, independently verify the exact iteration diff and make its narrow coordinator-owned checkpoint commit before review or another implementation iteration.'
  for clause in "$review_range" "$scope_exclusions" "$scope_not_admission"; do
    require_text "$REVIEW" "$clause"
    require_text "$COORDINATOR_RUNTIME" "$clause"
    require_text "$REVIEW_POLICY" "$clause"
  done
  require_text "$REVIEW_POLICY" 'Normal reviewer packets contain original user requirements, exact target/diff, `loop-id`, applicable `decision-id`, objective/criteria, general pre-routing record, admitted style record/deltas/tool evidence, full applicable lineage/binding, and all scrutiny rules.'
  require_text "$REVIEW_POLICY" "$policy_checkpoint_packet"
  require_text "$COORDINATOR_RUNTIME" 'Use normal targeted Git coordination: preserve unrelated dirty paths as exclusions. It needs no approval artifact, receipt, hash, canonical spelling, or command-shape prerequisite.'

  baseline_fixture="$baseline_contract"$'\n'"$baseline_exclusions"$'\n'"$ambiguity_contract"
  contains_checkpoint_baseline_contract "$baseline_fixture" "$baseline_contract" "$baseline_exclusions" "$ambiguity_contract" ||
    fail 'baseline scope fixture is incomplete'
  for clause in "$baseline_contract" "$baseline_exclusions"; do
    if contains_checkpoint_baseline_contract "${baseline_fixture/"$clause"/}" "$baseline_contract" "$baseline_exclusions" "$ambiguity_contract"; then
      fail "baseline scope mutation retained required clause: $clause"
    fi
  done

  review_fixture="$step4_bridge"$'\n'"$coordinator_packet"$'\n'"$review_range"$'\n'"$scope_exclusions"$'\n'"$scope_not_admission"
  contains_checkpoint_review_packet "$review_fixture" "$step4_bridge" "$coordinator_packet" "$review_range" "$scope_exclusions" "$scope_not_admission" ||
    fail 'review scope fixture must keep bridge before reviewer packet'
  reversed_fixture="$coordinator_packet"$'\n'"$step4_bridge"$'\n'"$review_range"$'\n'"$scope_exclusions"$'\n'"$scope_not_admission"
  if contains_checkpoint_review_packet "$reversed_fixture" "$step4_bridge" "$coordinator_packet" "$review_range" "$scope_exclusions" "$scope_not_admission"; then
    fail 'reversed checkpoint bridge/reviewer packet order was accepted'
  fi
  for clause in "$step4_bridge" "$coordinator_packet" "$review_range" "$scope_exclusions" "$scope_not_admission"; do
    if contains_checkpoint_review_packet "${review_fixture/"$clause"/}" "$step4_bridge" "$coordinator_packet" "$review_range" "$scope_exclusions" "$scope_not_admission"; then
      fail "review scope mutation retained required clause: $clause"
    fi
  done
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
assert_lane_forecast_contract
assert_lineage_context_contract
assert_pause_resume_closure_contract
assert_eci_ordinary_role_split
assert_implementer_iteration_checkpoint_contract
printf '%s\n' 'workflow skill routing assertions: PASS'
