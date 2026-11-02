package main

import (
	"strings"
	"testing"
	"time"
)

// validCore is a representative report before completion estimates.
//
// Example: Add estimates to exercise validation.
const validCore = `timestamp: "2026-11-02T15:24:00Z"
state: Working
progress: [Implementation started]
decisions: [Use YAML]
blockers_risks: [none]
verification: [pending]
next_focus: Finish
scope_complete: false
tasks:
  - id: "1"
    title: Root
    priority: high
    impact: Useful
    effort: {min_minutes: 60, max_minutes: 60, kind: elapsed, basis: guess}
    status: IN PROGRESS
  - id: "1.1"
    parent_id: "1"
    title: Complete
    priority: high
    impact: Useful
    effort: {min_minutes: 30, max_minutes: 30, kind: elapsed, basis: guess}
    status: CLOSED
    evidence: accepted test
  - id: "1.2"
    parent_id: "1"
    title: Unknown
    priority: unknown
    impact: unknown
    effort: {min_minutes: 10, max_minutes: 30, kind: elapsed, basis: educated guess}
    status: unknown
top_priorities: ["1.1"]
lanes: []
roster: {}
timeline: []
reviews: []
`

// estimates supplies representative priority and overall ranges.
//
// Example: Combine it with validCore for a complete report.
const estimates = `priority_estimates:
  - {priority: high, min_minutes: 20, max_minutes: 40, earliest: "2026-11-02T15:44:00Z", latest: "2026-11-02T16:04:00Z", basis: educated guess, assumptions: review available, dependencies: review, critical_path: latest parallel endpoint}
  - {priority: unknown, min_minutes: 20, max_minutes: 40, earliest: "2026-11-02T15:44:00Z", latest: "2026-11-02T16:04:00Z", basis: educated guess, assumptions: review available, dependencies: review, critical_path: latest parallel endpoint}
completion_estimate: {min_minutes: 20, max_minutes: 40, earliest: "2026-11-02T15:44:00Z", latest: "2026-11-02T16:04:00Z", basis: educated guess, assumptions: review available, dependencies: review, critical_path: latest parallel endpoint}
`

// valid combines the report and its estimates.
//
// Example: Parse it in behavior tests.
const valid = validCore + estimates

// TestRenderProgressAndSeparateLists checks the corresponding status report behavior.
//
// Example: Verify render progress and separate lists through the public behavior.
func TestRenderProgressAndSeparateLists(t *testing.T) {
	r, err := parse([]byte(valid))
	if err != nil {
		t.Fatal(err)
	}
	out := render(r)
	for _, s := range []string{"Top priorities", "Full task tree", "100%", "partial", "1/1", "1.2", "equal-package"} {
		if !strings.Contains(out, s) {
			t.Errorf("missing %q in %s", s, out)
		}
	}
}

// TestRejectInvalidStructures checks the corresponding status report behavior.
//
// Example: Verify reject invalid structures through the public behavior.
func TestRejectInvalidStructures(t *testing.T) {
	cases := []string{
		strings.Replace(valid, `top_priorities: ["1.1"]`, `top_priorities: ["missing"]`, 1),
		strings.Replace(valid, `parent_id: "1"`, `parent_id: "missing"`, 1),
		strings.Replace(valid, `evidence: accepted test`, `evidence: ""`, 1),
		strings.Replace(valid, `status: CLOSED`, `status: FINISHED`, 1),
		strings.Replace(valid, `scope_complete: false`, `scope_complete: maybe`, 1),
		valid + "state: duplicate\n",
	}
	for _, input := range cases {
		if _, err := parse([]byte(input)); err == nil {
			t.Errorf("accepted invalid input: %s", input)
		}
	}
}

// TestZeroKnownProgress checks the corresponding status report behavior.
//
// Example: Verify zero known progress through the public behavior.
func TestZeroKnownProgress(t *testing.T) {
	input := strings.Replace(valid, "status: CLOSED\n    evidence: accepted test", "status: unknown", 1)
	r, err := parse([]byte(input))
	if err != nil {
		t.Fatal(err)
	}
	out := render(r)
	if !strings.Contains(out, "Progress: unknown") {
		t.Fatal(out)
	}
}

// TestLaneAndUnknownCoverage checks the corresponding status report behavior.
//
// Example: Verify lane and unknown coverage through the public behavior.
func TestLaneAndUnknownCoverage(t *testing.T) {
	input := strings.Replace(valid, "lanes: []", "lanes:\n  - task_id: 'missing'\n    outcome: Test\n    implementation_status: NEW\n    test_status: NEW\n    prod_status: NEW", 1)
	if _, err := parse([]byte(input)); err == nil {
		t.Fatal("accepted lane referencing missing task")
	}
	input = strings.Replace(input, "task_id: 'missing'", "task_id: '1'", 1)
	r, err := parse([]byte(input))
	if err != nil {
		t.Fatal(err)
	}
	out := render(r)
	if !strings.Contains(out, "covered: 1.1") {
		t.Fatal(out)
	}
}

// TestLaneForecastRendering checks the corresponding status report behavior.
//
// Example: Verify lane forecast rendering through the public behavior.
func TestLaneForecastRendering(t *testing.T) {
	input := strings.Replace(valid, "lanes: []", `lanes:
  - task_id: '1'
    outcome: Finish work
    implementation_status: IN PROGRESS
    test_status: NEW
    prod_status: NEW
    next_milestone: Checks pass
    forecast:
      outcome: Finish work
      target: '2026-11-02T17:22:00Z'
      assessment: provisional — review pending; target conditional
      baseline: '2026-11-02T17:22:00Z'
      evidence: Initial estimate
      dependencies: Review
`, 1)
	r, err := parse([]byte(input))
	if err != nil {
		t.Fatal(err)
	}
	out := render(r)
	for _, want := range []string{"Next milestone: Checks pass", "Forecast deadline: Finish work will be finished by 2026-11-02T17:22:00Z.", "Forecast assessment: provisional", "Forecast recalibration: unchanged — baseline", "Dependencies / critical path: Review"} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q", want)
		}
	}
}

// TestPackageAndReviewValidation checks the corresponding status report behavior.
//
// Example: Verify package and review validation through the public behavior.
func TestPackageAndReviewValidation(t *testing.T) {
	for _, input := range []string{
		strings.Replace(valid, "max_minutes: 30, kind: elapsed, basis: guess", "max_minutes: 60, kind: elapsed, basis: guess", 1),
		strings.Replace(valid, "min_minutes: 30, max_minutes: 30", "min_minutes: 40, max_minutes: 30", 1),
		strings.Replace(valid, "reviews: []", "reviews:\n  - {task_id: '1.1', reporter: A, critic: B, rounds: 6, estimate: checked, impact: checked, priority: checked, unresolved: none}", 1),
		strings.Replace(valid, "reviews: []", "reviews:\n  - {task_id: missing, reporter: A, critic: B, rounds: 1, estimate: checked, impact: checked, priority: checked, unresolved: none}", 1),
	} {
		if _, err := parse([]byte(input)); err == nil {
			t.Errorf("accepted invalid structure: %s", input)
		}
	}
	oversized := strings.Replace(valid, "max_minutes: 30, kind: elapsed, basis: guess}\n    status: CLOSED", "max_minutes: 60, kind: elapsed, basis: guess}\n    indivisible_reason: Cannot split\n    status: CLOSED", 1)
	r, err := parse([]byte(oversized))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(render(r), "Larger indivisible packages: 1.1: Cannot split") {
		t.Fatal(render(r))
	}
}

// TestEmptyTimelineEvidence checks the corresponding status report behavior.
//
// Example: Verify empty timeline evidence through the public behavior.
func TestEmptyTimelineEvidence(t *testing.T) {
	r, err := parse([]byte(valid + "timeline_state: verified_empty\n"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(render(r), "Timeline: verified no evidenced activity") {
		t.Fatal(render(r))
	}
	if _, err := parse([]byte(valid + "timeline_state: invented\n")); err == nil {
		t.Fatal("accepted invented timeline state")
	}
}

// TestNestedSchemaValidation checks the corresponding status report behavior.
//
// Example: Verify nested schema validation through the public behavior.
func TestNestedSchemaValidation(t *testing.T) {
	for _, replacement := range []string{
		"lanes:\n  - {task_id: '1', outcome: X, implementation_status: NEW, test_status: NEW, prod_status: NEW, forecast: 42}",
		"lanes:\n  - {task_id: '1', outcome: X, implementation_status: NEW, test_status: NEW, prod_status: NEW, forecast: {target: [bad]}}",
		"timeline:\n  - {job: X, parent_chain: X, start: '2026-11-02T14:00:00Z', end: '2026-11-02T14:30:00Z', fast: X, normal: X, lost_field: X}",
	} {
		source := "lanes: []"
		if strings.HasPrefix(replacement, "timeline:") {
			source = "timeline: []"
		}
		if _, err := parse([]byte(strings.Replace(valid, source, replacement, 1))); err == nil {
			t.Errorf("accepted %s", replacement)
		}
	}
}

// TestRejectNonFiniteEffort checks the corresponding status report behavior.
//
// Example: Verify reject non finite effort through the public behavior.
func TestRejectNonFiniteEffort(t *testing.T) {
	for _, value := range []string{".nan", ".inf", "-.inf"} {
		input := strings.Replace(valid, "min_minutes: 30", "min_minutes: "+value, 1)
		if _, err := parse([]byte(input)); err == nil {
			t.Errorf("accepted %s", value)
		}
	}
}

// TestTimelineParentChainConsistency checks the corresponding status report behavior.
//
// Example: Verify timeline parent chain consistency through the public behavior.
func TestTimelineParentChainConsistency(t *testing.T) {
	input := strings.Replace(valid, "timeline: []", "timeline:\n  - {job: X, parent_chain: A, start: '2026-11-02T14:00:00Z', end: '2026-11-02T14:30:00Z', fast: unknown, normal: unknown}\n  - {job: X, parent_chain: B, start: '2026-11-02T14:30:00Z', end: '2026-11-02T15:00:00Z', fast: unknown, normal: unknown}", 1)
	if _, err := parse([]byte(input)); err == nil {
		t.Fatal("accepted inconsistent chain")
	}
}

// TestLaneScenarioAndRootForecastOutput checks the corresponding status report behavior.
//
// Example: Verify lane scenario and root forecast output through the public behavior.
func TestLaneScenarioAndRootForecastOutput(t *testing.T) {
	input := strings.Replace(valid, "lanes: []", `lanes:
  - task_id: '1'
    outcome: Finish work
    implementation_status: IN PROGRESS
    test_status: NEW
    prod_status: NEW
    root_task_status: FOLLOWUP
    forecast:
      outcome: Finish work
      target: '2026-11-02T17:22:00Z'
      assessment: complete
      scenarios:
        - {case: base, trigger: none, affected_work: checks, duration_basis: none, evidence_assumptions: ready, endpoint: '2026-11-02T17:22:00Z', evidence_gap_next_action: none}
root_forecasts:
  - {outcome: Complete root, target: '2026-11-02T18:00:00Z', assessment: complete}
`, 1)
	r, err := parse([]byte(input))
	if err != nil {
		t.Fatal(err)
	}
	out := render(r)
	for _, want := range []string{"| Task ID |", "| Lane/root and case |", "Root-task status [1 / Finish work]: FOLLOWUP", "Root completion forecast: Complete root will be finished by 2026-11-02T18:00:00Z."} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q", want)
		}
	}
}

// TestPartialTimelineDisclosure checks the corresponding status report behavior.
//
// Example: Verify partial timeline disclosure through the public behavior.
func TestPartialTimelineDisclosure(t *testing.T) {
	input := strings.Replace(valid, "timeline: []", "timeline_state: unavailable\ntimeline:\n  - {job: X, parent_chain: A, start: '2026-11-02T14:00:00Z', end: '2026-11-02T14:30:00Z', fast: unknown, normal: unknown}", 1)
	r, err := parse([]byte(input))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(render(r), "History is incomplete or unavailable") {
		t.Fatal(render(r))
	}
}

// TestRepairRegressionInputs checks the corresponding status report behavior.
//
// Example: Verify repair regression inputs through the public behavior.
func TestRepairRegressionInputs(t *testing.T) {
	lane := `lanes:
  - task_id: '1'
    outcome: Work
    implementation_status: IN PROGRESS
    test_status: NEW
    prod_status: NEW
    completed_at: '2026-11-02T15:00:00Z'
    forecast: {outcome: Work, target: '2026-11-02T16:00:00Z', assessment: complete}
`
	if _, err := parse([]byte(strings.Replace(valid, "lanes: []", lane, 1))); err == nil {
		t.Error("accepted active task with completed_at and active forecast")
	}
	if _, err := parse([]byte(valid + "root_forecasts: [{}]\n")); err == nil {
		t.Error("accepted empty root forecast")
	}
	bad := strings.Replace(valid, "timeline: []", "timeline:\n  - {job: '1', parent_chain: '1', start: '2026-11-02T13:00:00Z', end: '2026-11-02T14:00:00Z', fast: unknown, normal: unknown}", 1)
	if _, err := parse([]byte(bad)); err == nil {
		t.Error("accepted one-hour interval")
	}
	utc := strings.Replace(valid, "2026-11-02T15:24:00Z", "2026-11-02T15:24:00+00:00", 1)
	if _, err := parse([]byte(utc)); err != nil {
		t.Errorf("rejected zero-offset UTC: %v", err)
	}
}

// TestCompletionEstimates checks the corresponding status report behavior.
//
// Example: Verify completion estimates through the public behavior.
func TestCompletionEstimates(t *testing.T) {
	input := validCore + `priority_estimates:
  - {priority: unknown, min_minutes: 10, max_minutes: 30, earliest: "2026-11-02T15:34:00Z", latest: "2026-11-02T15:54:00Z", basis: educated guess, assumptions: review available, dependencies: none, critical_path: unknown}
  - priority: high
    min_minutes: 20
    max_minutes: 40
    earliest: '2026-11-02T15:44:00Z'
    latest: '2026-11-02T16:04:00Z'
    basis: educated guess
    assumptions: review available
    dependencies: review
    critical_path: parallel work, latest endpoint
completion_estimate:
  min_minutes: 20
  max_minutes: 50
  earliest: '2026-11-02T15:44:00Z'
  latest: '2026-11-02T16:14:00Z'
  basis: educated guess
  assumptions: reviewers available
  dependencies: review
  critical_path: latest parallel endpoint
`
	r, err := parse([]byte(input))
	if err != nil {
		t.Fatal(err)
	}
	out := render(r)
	for _, want := range []string{"Priority high completion estimate", "Priority unknown completion estimate", "Overall completion estimate", "latest parallel endpoint"} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q", want)
		}
	}
}

// TestTimelineUTCAndLifecycle checks the corresponding status report behavior.
//
// Example: Verify timeline utcand lifecycle through the public behavior.
func TestTimelineUTCAndLifecycle(t *testing.T) {
	oldTZ := time.Local
	time.Local = time.FixedZone("local", -5*3600)
	base := strings.Replace(valid, "2026-11-02T15:24:00Z", "2026-11-02T00:15:00+00:00", 1)
	row := "timeline:\n  - {job: '1', parent_chain: '1', start: '2026-11-01T23:30:00Z', end: '2026-11-02T00:00:00+00:00', fast: unknown, normal: unknown}"
	if _, err := parse([]byte(strings.Replace(base, "timeline: []", row, 1))); err != nil {
		t.Errorf("valid midnight UTC: %v", err)
	}
	for _, replacement := range []string{"2026-11-02T00:01:00Z", "2026-11-01T19:00:00Z", "2026-11-02T00:00:00+01:00"} {
		bad := strings.Replace(row, "2026-11-02T00:00:00+00:00", replacement, 1)
		if _, err := parse([]byte(strings.Replace(base, "timeline: []", bad, 1))); err == nil {
			t.Errorf("accepted invalid end %s", replacement)
		}
	}
	closed := strings.Replace(valid, "status: IN PROGRESS\n  - id:", "status: CLOSED\n    evidence: accepted\n  - id:", 1)
	lane := "lanes:\n  - {task_id: '1', outcome: Work, implementation_status: CLOSED, test_status: IN PROGRESS, prod_status: NEW, forecasted: true}"
	if _, err := parse([]byte(strings.Replace(closed, "lanes: []", lane, 1))); err == nil {
		t.Error("missing completed_at accepted")
	}
	lane = strings.Replace(lane, "forecasted: true}", "forecasted: true, completed_at: '2026-11-02T15:00:00+00:00'}", 1)
	if _, err := parse([]byte(strings.Replace(closed, "lanes: []", lane, 1))); err != nil {
		t.Errorf("valid closed lane: %v", err)
	}
	time.Local = oldTZ
}

// TestEstimateCoverageRejectsMissing checks every priority and overall are estimated.
//
// Example: An unknown-priority task still needs a labeled educated estimate.
func TestEstimateCoverageRejectsMissing(t *testing.T) {
	if _, err := parse([]byte(validCore)); err == nil {
		t.Error("accepted missing estimates")
	}
	input := strings.Replace(valid, "  - {priority: unknown, min_minutes: 20, max_minutes: 40, earliest: \"2026-11-02T15:44:00Z\", latest: \"2026-11-02T16:04:00Z\", basis: educated guess, assumptions: review available, dependencies: review, critical_path: latest parallel endpoint}\n", "", 1)
	if _, err := parse([]byte(input)); err == nil {
		t.Error("accepted missing unknown-priority estimate")
	}
}

// TestClosedLifecycleRejectsContradictoryForecast verifies separate readiness and completion.
//
// Example: A closed forecasted task cannot retain an active target.
func TestClosedLifecycleRejectsContradictoryForecast(t *testing.T) {
	closed := strings.Replace(valid, "status: IN PROGRESS\n  - id:", "status: CLOSED\n    evidence: accepted\n  - id:", 1)
	lane := `lanes:
  - task_id: '1'
    outcome: Work
    implementation_status: CLOSED
    test_status: IN PROGRESS
    prod_status: NEW
    forecasted: true
    completed_at: '2026-11-02T15:00:00Z'
    forecast: {outcome: Work, target: '2026-11-02T16:00:00Z', assessment: complete}
`
	if _, err := parse([]byte(strings.Replace(closed, "lanes: []", lane, 1))); err == nil {
		t.Error("accepted closed task with active forecast")
	}
}
