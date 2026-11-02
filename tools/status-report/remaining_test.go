package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

func writeLinkedSources(t *testing.T, ledger, forecasts string) string {
	t.Helper()
	dir := t.TempDir()
	require.NoError(t, os.WriteFile(filepath.Join(dir, "project-understanding.yaml"), []byte(ledger), 0600))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "forecasts.yaml"), []byte(forecasts), 0600))
	return dir
}

func TestOpenWorkRequiresRemainingCoverage(t *testing.T) {
	reportText := strings.ReplaceAll(linkedReport, "status: IN PROGRESS, work_refs:", "status: CLOSED, evidence: accepted, work_refs:")
	reportText = strings.Replace(reportText, "  - task_id: '1'", "  - task_id: '1'", 1)
	r, err := parse([]byte(reportText))
	require.NoError(t, err)
	// The open lane represents remaining acceptance despite its closed package.
	dir := writeLinkedSources(t, linkedLedger, linkedForecasts)
	issues := strings.Join(reconcile(r, dir), "\n")
	require.Contains(t, issues, "remaining acceptance")
	direct := strings.Replace(linkedLedger, "reporting_roles: [lane], forecast_ref: 'forecasts.yaml#/records/first'", "reporting_roles: []", 1)
	r.Lanes = r.Lanes[1:]
	r.Tasks[1].Status = statusInProgress // An unrelated sibling cannot cover work:first.
	dir = writeLinkedSources(t, direct, linkedForecasts)
	issues = strings.Join(reconcile(r, dir), "\n")
	require.Contains(t, issues, "no remaining package or open acceptance lane")
}

func TestCancelledLaneMayBeOmitted(t *testing.T) {
	reportText := strings.Replace(linkedReport, "  - task_id: '1'", "  - task_id: '1'", 1)
	r, err := parse([]byte(reportText))
	require.NoError(t, err)
	r.Lanes = r.Lanes[1:]
	ledger := strings.Replace(linkedLedger, "state: active", "state: cancelled", 1)
	forecasts := strings.Replace(linkedForecasts, "status: active", "status: inactive", 1)
	issues := strings.Join(reconcile(r, writeLinkedSources(t, ledger, forecasts)), "\n")
	require.NotContains(t, issues, "declared lane work:first missing")
	require.NotContains(t, issues, "completion")
}

func TestCompletedRootHasOwnCompletionProjection(t *testing.T) {
	r, err := parse([]byte(linkedReport))
	require.NoError(t, err)
	r.Lanes = r.Lanes[1:]
	r.RootCompletions = []rootCompletion{{WorkRef: "project-understanding.yaml#/records/work:first", Outcome: "First result", CompletedAt: "2026-11-02T15:00:00+00:00"}}
	ledger := strings.Replace(linkedLedger, "state: active, next_action: Finish, reporting_roles: [lane]", "state: completed, completed_at: '2026-11-02T15:00:00Z', reporting_roles: [root]", 1)
	ledger = strings.Replace(ledger, "    evidence: []\n  work:second:", "    links: {outcomes: ['outcome:first']}\n    evidence: []\n  outcome:first:\n    section: progress\n    type: outcome\n    data: {description: First result}\n    evidence: []\n  work:second:", 1)
	forecasts := strings.Replace(linkedForecasts, "kind: lane", "kind: root", 1)
	forecasts = strings.Replace(forecasts, "status: active", "status: inactive", 1)
	dir := writeLinkedSources(t, ledger, forecasts)
	require.Empty(t, reconcile(r, dir))
	require.Contains(t, render(r), "Root outcome: First result")
	r.RootCompletions[0].Outcome = "wrong"
	require.Contains(t, strings.Join(reconcile(r, dir), "\n"), "outcome unverified")
	r.RootCompletions[0].CompletedAt = "2026-11-02T15:01:00Z"
	require.Contains(t, strings.Join(reconcile(r, dir), "\n"), "completed_at mismatch")
	r.RootCompletions = nil
	require.Contains(t, strings.Join(reconcile(r, dir), "\n"), "completion missing from report")
}

func TestCancelledLaneRetainedHasNoCompletion(t *testing.T) {
	r, err := parse([]byte(linkedReport))
	require.NoError(t, err)
	r.Lanes[0].Forecast = nil
	r.Lanes[0].Lifecycle = "cancelled"
	ledger := strings.Replace(linkedLedger, "state: active", "state: cancelled", 1)
	forecasts := strings.Replace(linkedForecasts, "status: active", "status: inactive", 1)
	require.Empty(t, reconcile(r, writeLinkedSources(t, ledger, forecasts)))
	require.Contains(t, render(r), "Cancelled: First result; no active forecast deadline.")
	r.Lanes[0].CompletedAt = "2026-11-02T15:00:00Z"
	require.Contains(t, strings.Join(reconcile(r, writeLinkedSources(t, ledger, forecasts)), "\n"), "must not claim completion")
}

func TestRootCompletionRequiresIdentityAndTimestamp(t *testing.T) {
	for _, extra := range []string{
		"root_completions: [{work_ref: '', outcome: Root, completed_at: '2026-11-02T15:00:00Z'}]\n",
		"root_completions: [{work_ref: ref, outcome: '', completed_at: '2026-11-02T15:00:00Z'}]\n",
		"root_completions: [{work_ref: ref, outcome: Root, completed_at: invalid}]\n",
	} {
		_, err := parse([]byte(linkedReport + extra))
		require.Error(t, err)
	}
}

func TestCancelledLifecycleValidation(t *testing.T) {
	r, err := parse([]byte(linkedReport))
	require.NoError(t, err)
	l := r.Lanes[0]
	l.Lifecycle = "cancelled"
	l.Forecast = nil
	l.ImplementationStatus = statusClosed
	require.NoError(t, validateLane(l, map[taskID]task{l.TaskID: r.Tasks[0]}))
	l.CompletedAt = "2026-11-02T15:00:00Z"
	require.Error(t, validateLane(l, map[taskID]task{l.TaskID: r.Tasks[0]}))
	l.Lifecycle = "unknown"
	require.Error(t, validateLane(l, map[taskID]task{l.TaskID: r.Tasks[0]}))
}
