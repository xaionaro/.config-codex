package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

// TestRootCorrectionReplayPreservesConflicts checks the production correction path.
//
// Example: Owner edits, comments and changed source time prevent a replacement.
func TestRootCorrectionReplayPreservesConflicts(t *testing.T) {
	old := `{"work_ref":"project-understanding.yaml#/records/w","outcome":"Result","completed_at":"2026-11-02T15:00:00Z"}`
	newer := `{"work_ref":"project-understanding.yaml#/records/w","outcome":"Result","completed_at":"2026-11-02T15:05:00Z"}`
	first := `{"event":"lifecycle_change","details":{"status_update":{"additions":[{"target":"root_completion","evidence":"accepted","record":` + old + `}]}}}` + "\n"
	second := `{"event":"correction","details":{"corrects":1,"status_update":{"additions":[{"target":"root_completion","evidence":"corrected","expected_prior":` + old + `,"record":` + newer + `}]}}}` + "\n"
	saved := `{"cursor":1,"applied":{"addition/root_completion/project-understanding.yaml#/records/w":` + strconv.Quote(old) + `},"latest":{"addition/root_completion/project-understanding.yaml#/records/w":1},"pending":{}}`
	for _, mode := range []string{"owner edit", "comment", "source mismatch"} {
		t.Run(mode,
			// Check one reason an explicit correction must remain pending.
			//
			// Example: Preserve a comment on the existing completion.
			func(t *testing.T) {
				prior := old
				section := "root_completions: [" + prior + "]\n"
				sourceTime := "2026-11-02T15:05:00Z"
				if mode == "owner edit" {
					prior = strings.Replace(old, "15:00:00Z", "15:01:00Z", 1)
					section = "root_completions: [" + prior + "]\n"
				}
				if mode == "comment" {
					section = "root_completions:\n  - " + prior + " # keep owner comment\n"
				}
				if mode == "source mismatch" {
					sourceTime = "2026-11-02T15:06:00Z"
				}
				initial, err := putSyncState([]byte(valid+section), saved)
				require.NoError(t, err)
				dir := t.TempDir()
				require.NoError(t, os.WriteFile(filepath.Join(dir, "high_level_log.jsonl"), []byte(first+second), 0600))
				ledger := ledgerSource{Records: map[string]sourceRecord{"w": {Type: "work", OutcomeRefs: []string{"o"}, Data: workData{State: workStateCompleted, CompletedAt: sourceTime, Roles: []reportingRole{reportingRoleRoot}}}, "o": {Type: "outcome", Outcome: "Result"}}}
				out, _, err := projectLogStatus(dir, initial, ledger, forecastSource{})
				require.NoError(t, err)
				report, err := parse(out)
				require.NoError(t, err)
				require.Len(t, report.RootCompletions, 1)
				require.NotEqual(t, "2026-11-02T15:05:00Z", report.RootCompletions[0].CompletedAt)
				require.NotEmpty(t, report.StatusSync.PendingRootAdditions)
				if mode == "comment" {
					require.Contains(t, string(out), "# keep owner comment")
				}
			})
	}
}

// TestLegacyPendingRootDoesNotUndoOwnerRemoval checks applied record ownership.
//
// Example: An owner-deleted applied completion is not reinserted through legacy pending state.
func TestLegacyPendingRootDoesNotUndoOwnerRemoval(t *testing.T) {
	old := `{"work_ref":"project-understanding.yaml#/records/w","outcome":"Result","completed_at":"2026-11-02T15:00:00Z"}`
	newer := `{"work_ref":"project-understanding.yaml#/records/w","outcome":"Result","completed_at":"2026-11-02T15:05:00Z"}`
	first := `{"event":"lifecycle_change","details":{"status_update":{"additions":[{"target":"root_completion","evidence":"accepted","record":` + old + `}]}}}` + "\n"
	second := `{"event":"correction","details":{"corrects":1,"status_update":{"additions":[{"target":"root_completion","evidence":"corrected","expected_prior":` + old + `,"record":` + newer + `}]}}}` + "\n"
	key := "addition/root_completion/project-understanding.yaml#/records/w"
	saved := syncState{Cursor: 1, Applied: map[string]string{key: old}, Latest: map[string]int{key: 1}, PendingAdditions: map[string]syncPendingAddition{key: {Line: 1, Target: syncTargetRootCompletion, ID: "project-understanding.yaml#/records/w", Record: old, Evidence: "accepted"}}}
	raw, err := json.Marshal(saved)
	require.NoError(t, err)
	initial, err := putSyncState([]byte(valid), string(raw))
	require.NoError(t, err)
	dir := t.TempDir()
	require.NoError(t, os.WriteFile(filepath.Join(dir, "high_level_log.jsonl"), []byte(first+second), 0600))
	ledger := ledgerSource{Records: map[string]sourceRecord{"w": {Type: "work", OutcomeRefs: []string{"o"}, Data: workData{State: workStateCompleted, CompletedAt: "2026-11-02T15:05:00Z", Roles: []reportingRole{reportingRoleRoot}}}, "o": {Type: "outcome", Outcome: "Result"}}}
	out, _, err := projectLogStatus(dir, initial, ledger, forecastSource{})
	require.NoError(t, err)
	report, err := parse(out)
	require.NoError(t, err)
	require.Empty(t, report.RootCompletions)
	require.NotEmpty(t, report.StatusSync.PendingRootAdditions)
}
