package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

// TestLegacyTaskCancellationRecovery retries a persisted field-wise cancellation.
//
// Example: A cancelled task leaves its sibling open and exits the priority list.
func TestLegacyTaskCancellationRecovery(t *testing.T) {
	dir := t.TempDir()
	require.NoError(t, os.WriteFile(filepath.Join(dir, "high_level_log.jsonl"), []byte("{}\n"), 0600))
	state := syncState{Cursor: 1, Applied: map[string]string{}, Latest: map[string]int{}, Pending: map[string]syncPending{}}
	for field, value := range map[string]string{"lifecycle": "cancelled", "status": "unknown", "evidence": "owner withdrew"} {
		update := syncUpdate{Target: syncTargetTask, ID: "1", Fields: map[string]string{field: value}}
		key := syncTargetKey(update, field)
		state.Pending[key] = syncPending{Line: 1, Update: update}
		state.Latest[key] = 1
	}
	encoded, err := json.Marshal(state)
	require.NoError(t, err)
	initial, err := putSyncState([]byte(linkedReport), string(encoded))
	require.NoError(t, err)
	result, _, err := projectLogStatus(dir, initial, ledgerSource{}, forecastSource{})
	require.NoError(t, err)
	report, err := parse(result)
	require.NoError(t, err)
	require.Equal(t, taskLifecycleCancelled, report.Tasks[0].Lifecycle)
	require.Equal(t, statusUnknown, report.Tasks[0].Status)
	require.Equal(t, "owner withdrew", report.Tasks[0].Evidence)
	require.Equal(t, statusInProgress, report.Tasks[1].Status)
	require.NotContains(t, report.TopPriorities, taskID("1"))
	require.Empty(t, report.StatusSync.Pending)
}

// TestLegacyTaskClosureRecoveryRequiresEvidence retries a persisted acceptance.
//
// Example: Closure waits for matching evidence and preserves a manual replacement.
func TestLegacyTaskClosureRecoveryRequiresEvidence(t *testing.T) {
	for _, evidence := range []string{"accepted", "manual replacement"} {
		t.Run(evidence,
			// Check one persisted evidence value.
			//
			// Example: An owner edit keeps closure pending.
			func(t *testing.T) {
				dir := t.TempDir()
				require.NoError(t, os.WriteFile(filepath.Join(dir, "high_level_log.jsonl"), []byte("{}\n"), 0600))
				update := syncUpdate{Target: syncTargetTask, ID: "1", Fields: map[string]string{"status": "CLOSED"}}
				key := syncTargetKey(update, "status")
				state := syncState{Cursor: 1, Applied: map[string]string{}, Latest: map[string]int{key: 1}, Pending: map[string]syncPending{key: {Line: 1, Update: update, Acceptance: "accepted"}}}
				encoded, err := json.Marshal(state)
				require.NoError(t, err)
				input := strings.Replace(linkedReport, "status: IN PROGRESS, work_refs:", "status: IN PROGRESS, evidence: '"+evidence+"', work_refs:", 1)
				require.NotEqual(t, linkedReport, input)
				initial, err := putSyncState([]byte(input), string(encoded))
				require.NoError(t, err)
				result, _, err := projectLogStatus(dir, initial, ledgerSource{}, forecastSource{})
				require.NoError(t, err)
				report, err := parse(result)
				require.NoError(t, err)
				require.Equal(t, evidence, report.Tasks[0].Evidence)
				require.Equal(t, statusInProgress, report.Tasks[1].Status)
				if evidence == "accepted" {
					require.Equal(t, statusClosed, report.Tasks[0].Status)
					require.Empty(t, report.StatusSync.Pending)
				} else {
					require.Equal(t, statusInProgress, report.Tasks[0].Status)
					require.NotEmpty(t, report.StatusSync.Pending)
				}
			})
	}
}

// TestLegacyLaneCompletionRecoveryRequiresCanonicalCompletion retries a saved closure.
//
// Example: A completed source closes the named lane and leaves another lane open.
func TestLegacyLaneCompletionRecoveryRequiresCanonicalCompletion(t *testing.T) {
	for _, completed := range []bool{true, false} {
		t.Run(fmt.Sprint(completed),
			// Check one canonical work state.
			//
			// Example: Active work keeps closure pending.
			func(t *testing.T) {
				dir := t.TempDir()
				require.NoError(t, os.WriteFile(filepath.Join(dir, "high_level_log.jsonl"), []byte("{}\n"), 0600))
				state := syncState{Cursor: 1, Applied: map[string]string{}, Latest: map[string]int{}, Pending: map[string]syncPending{}}
				for field, value := range map[string]string{"implementation_status": "CLOSED", "completed_at": "2026-11-02T15:25:00Z"} {
					update := syncUpdate{Target: syncTargetLane, ID: "1", WorkRef: "project-understanding.yaml#/records/work:first", RequiredEnvironment: syncEnvironmentImplementation, Evidence: "accepted", Fields: map[string]string{field: value}}
					key := syncTargetKey(update, field)
					state.Pending[key] = syncPending{Line: 1, Update: update}
					state.Latest[key] = 1
				}
				encoded, err := json.Marshal(state)
				require.NoError(t, err)
				input := strings.Replace(linkedReport, "    forecast: {forecast_ref: 'forecasts.yaml#/records/first', outcome: First result, target: '2026-11-02T16:00:00Z', assessment: complete, baseline: '2026-11-02T16:00:00Z', evidence: initial}\n", "", 1)
				require.NotEqual(t, linkedReport, input)
				initial, err := putSyncState([]byte(input), string(encoded))
				require.NoError(t, err)
				source := workData{State: workStateActive}
				if completed {
					source = workData{State: workStateCompleted, CompletedAt: "2026-11-02T15:25:00Z"}
				}
				ledger := ledgerSource{Records: map[string]sourceRecord{"work:first": {Type: "work", Data: source}}}
				result, _, err := projectLogStatus(dir, initial, ledger, forecastSource{})
				require.NoError(t, err)
				report, err := parse(result)
				require.NoError(t, err)
				require.Equal(t, statusInProgress, report.Lanes[1].ImplementationStatus)
				if completed {
					require.Equal(t, statusClosed, report.Lanes[0].ImplementationStatus)
					require.Equal(t, "2026-11-02T15:25:00Z", report.Lanes[0].CompletedAt)
					require.Empty(t, report.StatusSync.Pending)
				} else {
					require.Equal(t, statusInProgress, report.Lanes[0].ImplementationStatus)
					require.Empty(t, report.Lanes[0].CompletedAt)
					require.Len(t, report.StatusSync.Pending, 2)
				}
			})
	}
}

// TestLegacyPendingTimelineRecovery publishes a saved complete snapshot.
//
// Example: A verified-empty timeline keeps its supplied anchor during migration.
func TestLegacyPendingTimelineRecovery(t *testing.T) {
	dir := t.TempDir()
	require.NoError(t, os.WriteFile(filepath.Join(dir, "high_level_log.jsonl"), []byte("{}\n"), 0600))
	snapshot := `{"as_of":"2026-11-02T15:24:00Z","state":"verified_empty","entries":[]}`
	state := syncState{Cursor: 1, PendingTimeline: &syncPendingTimeline{Line: 1, Snapshot: snapshot}}
	encoded, err := json.Marshal(state)
	require.NoError(t, err)
	initial, err := putSyncState([]byte(linkedReport), string(encoded))
	require.NoError(t, err)
	result, _, err := projectLogStatus(dir, initial, ledgerSource{}, forecastSource{})
	require.NoError(t, err)
	report, err := parse(result)
	require.NoError(t, err)
	require.Equal(t, timelineVerifiedEmpty, report.TimelineState)
	require.Equal(t, "2026-11-02T15:24:00Z", report.TimelineAsOf)
	require.Empty(t, report.Timeline)
	require.Nil(t, report.StatusSync.PendingTimeline)
	require.Empty(t, report.StatusSync.PendingTimelines)
}
