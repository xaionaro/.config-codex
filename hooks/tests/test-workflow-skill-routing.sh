#!/usr/bin/env bash

set -euo pipefail

ROOT="${WORKFLOW_SKILL_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
ECI="$ROOT/skills/explore-critique-implement/SKILL.md"
STATUS_REPORT="$ROOT/skills/writing-status-reports/SKILL.md"
ATE="$ROOT/skills/agent-teams-execution/SKILL.md"
ECI_COVERAGE="$ROOT/skills/explore-critique-implement/references/coverage-map.md"
ATE_COVERAGE="$ROOT/skills/agent-teams-execution/references/coverage-map.md"
EMERGENCY="$ROOT/skills/explore-critique-implement/references/emergency-unblock.md"
PAUSE="$ROOT/skills/references/workflow-runtime/pause-all-work.md"
POLICY="$ROOT/skills/references/workflow-runtime/policy-pressure-tests.md"
ECI_CRITIQUE="$ROOT/skills/explore-critique-implement/references/critique.md"
REVIEW="$ROOT/skills/explore-critique-implement/references/review.md"
COORDINATOR="$ROOT/skills/explore-critique-implement/references/coordinator.md"
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

assert_local_links_resolve() {
  local file target resolved
  local -a documents=(
    "$ECI"
    "$ATE"
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
    '## E2E — code and debug work' \
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
    'fresh Critic A, Critic B, Critic C, and E2E' \
    'Wait for all required review and E2E evidence before aggregating.' \
    'Pre-route every finding with the review policy.' \
    'Use the shared coordinator/runtime policy for repair cycles, clean-pass, and limits.'; do
    require_text "$COORDINATOR" "$required"
  done
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
  require_text "$EMERGENCY" 'Before the one provisional action, waive normal ECI Step 1/2, coding-style admission, TDD, tests, E2E, and critic review.'
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
  require_text "$EMERGENCY" '**Emergency Unblock** is a one-shot provisional path before normal ECI.'
  require_text "$EMERGENCY" 'Eligible only when already available direct evidence shows that the user is blocked now;'
  require_text "$EMERGENCY" 'the exact bug cause and repair, or the exact missing-capability change and repair, are already known;'
  require_text "$EMERGENCY" 'one smallest bounded reversible repair is obvious;'
  require_text "$EMERGENCY" 'no material competing diagnosis or approach exists;'
  require_text "$EMERGENCY" 'Qualification performs no new diagnosis, reproduction, exploration, comparison, or hypothesis testing.'
  require_text "$EMERGENCY" '**“provisional Emergency Unblock — unchecked”**'
  require_text "$EMERGENCY" 'Immediately after that action, start normal ECI Step 1 against the changed state.'
  require_text "$EMERGENCY" 'If the repair fails, uncertainty appears, diagnosis is hard, or another unchecked change seems necessary, make no second emergency repair: load `debugging-discipline` and enter the normal debugging route.'
  require_text "$ATE" 'concrete failure diagnosis uses debugging-discipline first.'
  require_text "$ROOT/CODEX.md" '- Use Go, not Python, for new code, scripts, helpers, and tooling. Do not port existing Python solely to apply this preference.'
  require_text "$ROOT/CODEX.md" '| Debugging/test failures/unexpected behavior/performance/build failures | `debugging-discipline` |'
}

assert_status_lane_stage_contract() {
  local header
  header="$(grep -F -- '| Task ID | Parent ID | Lane | Lane requirement refs | Stage | Owner |' "$STATUS_REPORT" || true)"
  [ -n "$header" ] || fail 'status report lane table is missing the Stage column'
  [[ "$header" == *'| Stage |'* ]] || fail 'status report lane table does not expose Stage'

  require_text "$STATUS_REPORT" 'Every lane records `Stage: normal` or `Stage: emergency`.'
  require_text "$STATUS_REPORT" 'Stage vocabulary | Every lane must record `normal` or `emergency`; `emergency` requires the Emergency Unblock protocol and its immediate return to normal ECI Step 1 described above.'
  require_text "$STATUS_REPORT" '`Stage: emergency` is'
  require_text "$STATUS_REPORT" 'the Emergency Unblock protocol: load and follow'
  require_text "$STATUS_REPORT" '`skills/explore-critique-implement/references/emergency-unblock.md`'
  require_text "$STATUS_REPORT" '`provisional Emergency Unblock — unchecked`'
  require_text "$STATUS_REPORT" 'immediately return to normal'
  require_text "$STATUS_REPORT" 'ECI Step 1.'

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
  local fixture missing_transition
  fixture=$'Lane Stage: emergency\nAssignment Stage: emergency\nLedger Stage: emergency\nProtocol: skills/explore-critique-implement/references/emergency-unblock.md\nRecord: provisional Emergency Unblock — unchecked\nTransition: emergency→normal ECI Step 1\nLane Stage: normal\nAssignment Stage: normal\nLedger Stage: normal'

  stage_resume_allowed() {
    local state="$1"
    local emergency_count normal_count transition_line normal_line
    emergency_count="$(grep -Fc -- 'Stage: emergency' <<<"$state" || true)"
    normal_count="$(grep -Fc -- 'Stage: normal' <<<"$state" || true)"
    transition_line="$(grep -nF -- 'Transition: emergency→normal ECI Step 1' <<<"$state" | cut -d: -f1 || true)"
    normal_line="$(grep -nF -- 'Lane Stage: normal' <<<"$state" | head -n1 | cut -d: -f1 || true)"
    [ "$emergency_count" -eq 3 ] && [ "$normal_count" -eq 3 ] &&
      grep -Fq -- 'Protocol: skills/explore-critique-implement/references/emergency-unblock.md' <<<"$state" &&
      grep -Fq -- 'Record: provisional Emergency Unblock — unchecked' <<<"$state" &&
      [ -n "$transition_line" ] && [ -n "$normal_line" ] &&
      [ "$transition_line" -lt "$normal_line" ]
  }

  stage_resume_allowed "$fixture" || fail 'valid emergency-to-normal fixture was rejected'
  missing_transition="${fixture/Transition: emergency→normal ECI Step 1/}"
  if stage_resume_allowed "$missing_transition"; then
    fail 'emergency-to-normal resume was admitted without a recorded transition'
  fi
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

assert_local_links_resolve
assert_role_rows_are_local
assert_eci_relationships
assert_compaction_provenance
assert_reviewer_role_split
assert_ate_ordinary_role_split
assert_emergency_qualification_source
assert_emergency_and_go_preference
assert_status_lane_stage_contract
assert_status_lane_stage_transition_fixture
assert_pause_resume_closure_contract
assert_eci_ordinary_role_split
printf '%s\n' 'workflow skill routing assertions: PASS'
