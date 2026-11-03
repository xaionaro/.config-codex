package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

// TestLegacyStructuredCorrectionRecovers proves complete predecessor ownership.
//
// Example: An owner and effort correction applies as one transaction.
func TestLegacyStructuredCorrectionRecovers(t *testing.T) {
	log := `{"event":"assignment_change","details":{"status_update":{"updates":[{"target":"task","id":"1","fields":{"owner":"first"},"values":{"effort":{"min_minutes":10,"max_minutes":20,"kind":"elapsed","basis":"guess"}}}]}}}` + "\n" + `{"event":"correction","details":{"status_update":{"updates":[{"target":"task","id":"1","corrects":1,"fields":{"owner":"third"},"values":{"effort":{"min_minutes":11,"max_minutes":21,"kind":"elapsed","basis":"guess"}}}]}}}` + "\n"
	dir := writeLinkedSources(t, linkedLedger, linkedForecasts)
	require.NoError(t, os.WriteFile(filepath.Join(dir, "high_level_log.jsonl"), []byte(log), 0600))
	update := syncUpdate{Target: syncTargetTask, ID: "1", Corrects: 1, Fields: map[string]string{"owner": "third"}}
	owner := syncTargetKey(update, "owner")
	effort := syncTargetKey(update, "effort")
	state := syncState{Cursor: 2, Applied: map[string]string{owner: "first", effort: `{"basis":"guess","kind":"elapsed","max_minutes":20,"min_minutes":10}`}, Latest: map[string]int{owner: 2, effort: 1}, Pending: map[string]syncPending{owner: {Line: 2, Update: update}}}
	encoded, err := json.Marshal(state)
	require.NoError(t, err)
	input := strings.Replace(linkedReport, "title: First,", "title: First, owner: first,", 1)
	initial, err := putSyncState([]byte(input), string(encoded))
	require.NoError(t, err)
	result, _, err := projectLogStatus(dir, initial, ledgerSource{}, forecastSource{})
	require.NoError(t, err)
	report, err := parse(result)
	require.NoError(t, err)
	require.Equal(t, "third", report.Tasks[0].Owner)
	require.Empty(t, report.StatusSync.Pending)
}

// TestLegacyStructuredCorrectionRequiresCompleteOwnership rejects unproven baselines.
//
// Example: A manual effort edit blocks the owner and effort correction together.
func TestLegacyStructuredCorrectionRequiresCompleteOwnership(t *testing.T) {
	log := `{"event":"assignment_change","details":{"status_update":{"updates":[{"target":"task","id":"1","fields":{"owner":"first"},"values":{"effort":{"min_minutes":10,"max_minutes":20,"kind":"elapsed","basis":"guess"}}}]}}}` + "\n" + `{"event":"correction","details":{"status_update":{"updates":[{"target":"task","id":"1","corrects":1,"fields":{"owner":"third"},"values":{"effort":{"min_minutes":11,"max_minutes":21,"kind":"elapsed","basis":"guess"}}}]}}}` + "\n"
	var event syncEvent
	require.NoError(t, json.Unmarshal(bytes.Split([]byte(log), []byte("\n"))[1], &event))
	update := event.Details.StatusUpdate.Updates[0]
	owner, effort := syncTargetKey(update, "owner"), syncTargetKey(update, "effort")
	input := []byte(strings.Replace(linkedReport, "title: First,", "title: First, owner: first,", 1))
	for _, mode := range []string{"missing", "edited", "stale", "conflicting pending"} {
		t.Run(mode,
			// Preserve the pending transaction when ownership is unproven.
			//
			// Example: A manual edit is not overwritten.
			func(t *testing.T) {
				state := syncState{Applied: map[string]string{owner: "first", effort: `{"basis":"guess","kind":"elapsed","max_minutes":20,"min_minutes":10}`}, Latest: map[string]int{owner: 2, effort: 1}, Pending: map[string]syncPending{}}
				data := input
				switch mode {
				case "missing":
					delete(state.Applied, effort)
				case "edited":
					data = bytes.Replace(input, []byte("max_minutes: 20"), []byte("max_minutes: 22"), 1)
				case "stale":
					state.Latest[effort] = 3
				case "conflicting pending":
					state.Pending[effort] = syncPending{Line: 3, Update: update}
				}
				require.False(t, legacyStructuredPriorProven(state, data, bytes.Split([]byte(log), []byte("\n")), 2, 0, update))
			})
	}
}

// TestLegacyClearCorrectionRecovers applies a proven explicit clear atomically.
//
// Example: Updating an owner and clearing context retains neither old field value.
func TestLegacyClearCorrectionRecovers(t *testing.T) {
	log := `{"event":"assignment_change","details":{"status_update":{"updates":[{"target":"task","id":"1","fields":{"owner":"first","context":"old"},"values":{"effort":{"min_minutes":10,"max_minutes":20,"kind":"elapsed","basis":"guess"}}}]}}}` + "\n" + `{"event":"correction","details":{"status_update":{"updates":[{"target":"task","id":"1","corrects":1,"fields":{"owner":"third"},"clear":["context"]}]}}}` + "\n"
	dir := writeLinkedSources(t, linkedLedger, linkedForecasts)
	require.NoError(t, os.WriteFile(filepath.Join(dir, "high_level_log.jsonl"), []byte(log), 0600))
	update := syncUpdate{Target: syncTargetTask, ID: "1", Corrects: 1, Fields: map[string]string{"owner": "third"}}
	owner, context := syncTargetKey(update, "owner"), syncTargetKey(update, "context")
	state := syncState{Cursor: 2, Applied: map[string]string{owner: "first", context: "old"}, Latest: map[string]int{owner: 2, context: 1}, Pending: map[string]syncPending{owner: {Line: 2, Update: update}}}
	encoded, err := json.Marshal(state)
	require.NoError(t, err)
	input := strings.Replace(linkedReport, "title: First,", "title: First, owner: first, context: old,", 1)
	initial, err := putSyncState([]byte(input), string(encoded))
	require.NoError(t, err)
	result, _, err := projectLogStatus(dir, initial, ledgerSource{}, forecastSource{})
	require.NoError(t, err)
	report, err := parse(result)
	require.NoError(t, err)
	require.Equal(t, "third", report.Tasks[0].Owner)
	require.NotContains(t, string(result), "context: old")
	require.Empty(t, report.StatusSync.Pending)
}
