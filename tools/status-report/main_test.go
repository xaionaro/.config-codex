package main

import (
	"strings"
	"testing"
)

const valid = `timestamp: "2026-11-02T15:24:00Z"
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

func TestNestedSchemaValidation(t *testing.T) {
	for _, replacement := range []string{
		"lanes:\n  - {task_id: '1', outcome: X, implementation_status: NEW, test_status: NEW, prod_status: NEW, forecast: 42}",
		"lanes:\n  - {task_id: '1', outcome: X, implementation_status: NEW, test_status: NEW, prod_status: NEW, forecast: {target: [bad]}}",
		"timeline:\n  - {job: X, parent_chain: X, interval: X, fast: X, normal: X, lost_field: X}",
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

func TestRejectNonFiniteEffort(t *testing.T) {
	for _, value := range []string{".nan", ".inf", "-.inf"} {
		input := strings.Replace(valid, "min_minutes: 30", "min_minutes: "+value, 1)
		if _, err := parse([]byte(input)); err == nil {
			t.Errorf("accepted %s", value)
		}
	}
}

func TestTimelineParentChainConsistency(t *testing.T) {
	input := strings.Replace(valid, "timeline: []", "timeline:\n  - {job: X, parent_chain: A, interval: one, fast: unknown, normal: unknown}\n  - {job: X, parent_chain: B, interval: two, fast: unknown, normal: unknown}", 1)
	if _, err := parse([]byte(input)); err == nil {
		t.Fatal("accepted inconsistent chain")
	}
}

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

func TestPartialTimelineDisclosure(t *testing.T) {
	input := strings.Replace(valid, "timeline: []", "timeline_state: unavailable\ntimeline:\n  - {job: X, parent_chain: A, interval: one, fast: unknown, normal: unknown}", 1)
	r, err := parse([]byte(input))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(render(r), "History is incomplete or unavailable") {
		t.Fatal(render(r))
	}
}
