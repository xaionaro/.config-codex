package main

import (
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

// TestCalculatedPriority checks score ordering and explicit unknowns through the report.
//
// Example: A higher return moves past a lower one while an unscored slot remains fixed.
func TestCalculatedPriority(t *testing.T) {
	input := strings.Replace(valid, "tasks:\n", "impact_scale: '0-10 user benefit'\ntasks:\n", 1)
	input = strings.Replace(input, "impact: Useful\n    effort: {min_minutes: 30, max_minutes: 30, kind: elapsed, basis: guess}", "impact: Useful\n    impact_points: 9\n    impact_basis: educated guess\n    effort: {min_minutes: 30, max_minutes: 30, kind: work, basis: guess}", 1)
	input = strings.Replace(input, "impact: unknown\n    effort: {min_minutes: 10, max_minutes: 30, kind: elapsed, basis: educated guess}", "impact: unknown\n    impact_points: 3\n    impact_basis: guess\n    effort: {min_minutes: 10, max_minutes: 30, kind: work, basis: educated guess}", 1)
	input = strings.Replace(input, `top_priorities: ["1.1"]`, `top_priorities: ["1.2", "1", "1.1"]`, 1)
	r, err := parse([]byte(input))
	require.NoError(t, err)
	out := render(r)
	top := strings.Split(strings.Split(out, "Top priorities:\n")[1], "\nFull task tree:")[0]
	require.Less(t, strings.Index(top, "1.1 Complete"), strings.Index(top, "1.2 Unknown"))
	require.Contains(t, top, "0.3 points/work-minute")
	require.Contains(t, top, "unscored:")
}

// TestPriorityScoreRejectsInvalidPoints checks invalid score inputs are rejected.
//
// Example: Negative impact cannot be ranked.
func TestPriorityScoreRejectsInvalidPoints(t *testing.T) {
	for _, value := range []string{"-1", ".nan", ".inf"} {
		input := strings.Replace(valid, "impact: Useful", "impact: Useful\n    impact_points: "+value, 1)
		_, err := parse([]byte(input))
		require.Error(t, err, value)
	}
}

// TestPriorityScoreBoundaries checks missing and zero inputs and stable ordering.
//
// Example: Zero impact is scored, while zero effort is unscored.
func TestPriorityScoreBoundaries(t *testing.T) {
	zero, one, two := 0.0, 1.0, 2.0
	ten := fractionalMinutes(10)
	base := task{ImpactPoints: &one, ImpactBasis: "guess", Effort: estimate{MaxMinutes: &ten, Kind: effortWork}}
	for _, tc := range []struct {
		name          string
		task          task
		scale, reason string
	}{
		{"scale", base, "", "missing impact scale"},
		{"points", task{ImpactBasis: "guess", Effort: base.Effort}, "scale", "missing impact points"},
		{"basis", task{ImpactPoints: &one, Effort: base.Effort}, "scale", "missing impact basis"},
		{"kind", task{ImpactPoints: &one, ImpactBasis: "guess", Effort: estimate{MaxMinutes: &ten, Kind: effortElapsed}}, "scale", "effort is not work minutes"},
		{"zero effort", task{ImpactPoints: &one, ImpactBasis: "guess", Effort: estimate{MaxMinutes: (*fractionalMinutes)(&zero), Kind: effortWork}}, "scale", "remaining effort must be positive"},
	} {
		_, reason := priorityScore(tc.task, tc.scale)
		require.Equal(t, tc.reason, reason, tc.name)
	}
	tasks := map[taskID]task{"low": {ImpactPoints: &zero, ImpactBasis: "guess", Effort: base.Effort}, "unknown": {}, "high": {ImpactPoints: &two, ImpactBasis: "guess", Effort: base.Effort}, "tie": {ImpactPoints: &two, ImpactBasis: "guess", Effort: base.Effort}}
	require.Equal(t, []taskID{"high", "unknown", "tie", "low"}, orderTaskIDs([]taskID{"low", "unknown", "high", "tie"}, tasks, "scale"))
	require.Contains(t, priorityText(tasks["low"], "scale"), "0 points/work-minute")
}

// TestLaneCalculatedPriority checks lane output uses the same score as task output.
//
// Example: A lane displays its task's points per work-minute.
func TestLaneCalculatedPriority(t *testing.T) {
	points := 6.0
	minutes := fractionalMinutes(20)
	tasks := map[taskID]task{"1": {ImpactPoints: &points, ImpactBasis: "guess", Effort: estimate{MinMinutes: &minutes, MaxMinutes: &minutes, Kind: effortWork}}}
	var out strings.Builder
	renderLaneTable(&out, []lane{{TaskID: "1"}}, tasks, "benefit")
	require.Contains(t, out.String(), "0.3 points/work-minute")
	require.NotContains(t, out.String(), "unscored:")
}
