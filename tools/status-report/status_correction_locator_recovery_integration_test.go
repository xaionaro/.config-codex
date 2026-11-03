package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

// TestInvalidCorrectionLocatorsDoNotBlockLaterAssignments checks replay ordering.
//
// Example: A self-referencing or future correction cannot block a later owner.
func TestInvalidCorrectionLocatorsDoNotBlockLaterAssignments(t *testing.T) {
	for _, tc := range []struct {
		name, locator string
	}{
		{"self", `"corrects":1`},
		{"future", `"corrects":2`},
		{"same ordinal", `"corrects":1,"corrects_ordinal":0`},
		{"later ordinal", `"corrects":1,"corrects_ordinal":1`},
	} {
		t.Run(tc.name,
			// Verify an impossible locator is diagnosed without blocking valid work.
			//
			// Example: The log retains both the invalid correction and assignment.
			func(t *testing.T) {
				dir := writeLinkedSources(t, linkedLedger, linkedForecasts)
				path := filepath.Join(dir, "latest-status-report.yaml")
				log := `{"event":"correction","details":{"status_update":{"updates":[{"target":"task","id":"1",` + tc.locator + `,"fields":{"owner":"mistaken"}}]}}}` + "\n" + `{"event":"assignment_change","details":{"status_update":{"updates":[{"target":"task","id":"1","fields":{"owner":"actual"}}]}}}` + "\n"
				require.NoError(t, os.WriteFile(path, []byte(linkedReport), 0600))
				require.NoError(t, os.WriteFile(filepath.Join(dir, "high_level_log.jsonl"), []byte(log), 0600))
				require.NoError(t, refreshTestStatus(dir, "assignment_change"))
				result, err := os.ReadFile(path)
				require.NoError(t, err)
				report, err := parse(result)
				require.NoError(t, err)
				require.Equal(t, "actual", report.Tasks[0].Owner)
				require.Empty(t, report.StatusSync.Groups)
				require.Contains(t, report.Blockers, "Status refresh incomplete: invalid status_update requires manual review")
				require.NoError(t, refreshTestStatus(dir, "assignment_change"))
				retry, err := os.ReadFile(path)
				require.NoError(t, err)
				require.Equal(t, result, retry)
			})
	}
}

// TestPersistedSelfCorrectionDoesNotBlockRetry checks existing queued state.
//
// Example: A previously saved impossible locator is diagnosed and removed.
func TestPersistedSelfCorrectionDoesNotBlockRetry(t *testing.T) {
	// saved is a previously persisted impossible correction and later assignment.
	//
	// Example: Retry removes the invalid group without discarding the assignment.
	const saved = `status_sync: {"cursor":2,"applied":{},"latest":{},"pending":{},"groups":{"[1,0]":{"line":1,"ordinal":0,"update":"{\"target\":\"task\",\"id\":\"1\",\"corrects\":1,\"fields\":{\"owner\":\"mistaken\"}}"},"[2,0]":{"line":2,"ordinal":0,"update":"{\"target\":\"task\",\"id\":\"1\",\"fields\":{\"owner\":\"actual\"}}"}}}`
	// log preserves the two immutable events referenced by the saved state.
	//
	// Example: The correction cannot precede itself.
	const log = `{"event":"correction","details":{"status_update":{"updates":[{"target":"task","id":"1","corrects":1,"fields":{"owner":"mistaken"}}]}}}` + "\n" + `{"event":"assignment_change","details":{"status_update":{"updates":[{"target":"task","id":"1","fields":{"owner":"actual"}}]}}}` + "\n"
	dir := writeLinkedSources(t, linkedLedger, linkedForecasts)
	path := filepath.Join(dir, "latest-status-report.yaml")
	require.NoError(t, os.WriteFile(path, []byte(linkedReport+saved+"\n"), 0600))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "high_level_log.jsonl"), []byte(log), 0600))
	require.NoError(t, refreshTestStatus(dir, "assignment_change"))
	result, err := os.ReadFile(path)
	require.NoError(t, err)
	report, err := parse(result)
	require.NoError(t, err)
	require.Equal(t, "actual", report.Tasks[0].Owner)
	require.Empty(t, report.StatusSync.Groups)
	require.Contains(t, report.Blockers, "Status refresh incomplete: invalid status_update requires manual review")
}

// TestCorrectionCanNameEarlierSameLineOrdinal checks valid intra-event ordering.
//
// Example: A second correction may name the first correction on the same line.
func TestCorrectionCanNameEarlierSameLineOrdinal(t *testing.T) {
	// log contains two ordered corrections in one canonical event.
	//
	// Example: The last correction names ordinal zero of its own line.
	const log = `{"event":"assignment_change","details":{"status_update":{"updates":[{"target":"task","id":"1","fields":{"owner":"first"}}]}}}` + "\n" + `{"event":"correction","details":{"status_update":{"updates":[{"target":"task","id":"1","corrects":1,"fields":{"owner":"second"}},{"target":"task","id":"1","corrects":2,"corrects_ordinal":0,"fields":{"owner":"third"}}]}}}` + "\n"
	dir := writeLinkedSources(t, linkedLedger, linkedForecasts)
	path := filepath.Join(dir, "latest-status-report.yaml")
	require.NoError(t, os.WriteFile(path, []byte(linkedReport), 0600))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "high_level_log.jsonl"), []byte(log), 0600))
	require.NoError(t, refreshTestStatus(dir, "correction"))
	result, err := os.ReadFile(path)
	require.NoError(t, err)
	report, err := parse(result)
	require.NoError(t, err)
	require.Equal(t, "third", report.Tasks[0].Owner)
	require.Empty(t, report.StatusSync.Groups)
}

// TestLegacyFieldSelfCorrectionIsRejected checks field-wise persisted state.
//
// Example: A saved correction cannot authorize its own owner value.
func TestLegacyFieldSelfCorrectionIsRejected(t *testing.T) {
	// saved is a legacy field pending entry with a self-referencing locator.
	//
	// Example: The invalid correction must never be projected on retry.
	const saved = `status_sync: {"cursor":1,"applied":{},"latest":{"[\"task\",\"1\",\"\",\"\"]/owner":1},"pending":{"[\"task\",\"1\",\"\",\"\"]/owner":{"line":1,"update":{"target":"task","id":"1","corrects":1,"fields":{"owner":"mistaken"}}}}}`
	// log is the exact immutable source for the saved field.
	//
	// Example: Its only update cannot precede itself.
	const log = `{"event":"correction","details":{"status_update":{"updates":[{"target":"task","id":"1","corrects":1,"fields":{"owner":"mistaken"}}]}}}` + "\n"
	dir := writeLinkedSources(t, linkedLedger, linkedForecasts)
	path := filepath.Join(dir, "latest-status-report.yaml")
	require.NoError(t, os.WriteFile(path, []byte(linkedReport+saved+"\n"), 0600))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "high_level_log.jsonl"), []byte(log), 0600))
	require.NoError(t, refreshTestStatus(dir, "correction"))
	result, err := os.ReadFile(path)
	require.NoError(t, err)
	report, err := parse(result)
	require.NoError(t, err)
	require.Empty(t, report.Tasks[0].Owner)
	require.Empty(t, report.StatusSync.Pending)
	require.Contains(t, report.Blockers, "Status refresh incomplete: invalid status_update requires manual review")
}

// TestLegacySameLineCorrectionUsesUniqueSourceOrdinal checks old pending compatibility.
//
// Example: A uniquely identified later update can correct ordinal zero.
func TestLegacySameLineCorrectionUsesUniqueSourceOrdinal(t *testing.T) {
	for _, tc := range []struct {
		name, duplicate string
		applies         bool
	}{
		{"unique", "", true},
		{"ambiguous", `,{"target":"task","id":"1","corrects":2,"corrects_ordinal":0,"fields":{"owner":"third"}}`, false},
	} {
		t.Run(tc.name,
			// Replay one field saved without an ordinal.
			//
			// Example: Two indistinguishable occurrences remain pending.
			func(t *testing.T) {
				// saved is the field-wise state produced before ordinal storage.
				//
				// Example: The previous owner was projected on line two.
				const saved = `status_sync: {"cursor":2,"applied":{"[\"task\",\"1\",\"\",\"\"]/owner":"second"},"latest":{"[\"task\",\"1\",\"\",\"\"]/owner":2},"pending":{"[\"task\",\"1\",\"\",\"\"]/owner":{"line":2,"update":{"target":"task","id":"1","corrects":2,"corrects_ordinal":0,"fields":{"owner":"third"}}}}}`
				log := `{"event":"assignment_change","details":{"status_update":{"updates":[{"target":"task","id":"1","fields":{"owner":"first"}}]}}}` + "\n" + `{"event":"correction","details":{"status_update":{"updates":[{"target":"task","id":"1","corrects":1,"fields":{"owner":"second"}},{"target":"task","id":"1","corrects":2,"corrects_ordinal":0,"fields":{"owner":"third"}}` + tc.duplicate + `]}}}` + "\n"
				dir := writeLinkedSources(t, linkedLedger, linkedForecasts)
				path := filepath.Join(dir, "latest-status-report.yaml")
				input := strings.Replace(linkedReport, "title: First,", `title: First, owner: second,`, 1)
				require.NoError(t, os.WriteFile(path, []byte(input+saved+"\n"), 0600))
				require.NoError(t, os.WriteFile(filepath.Join(dir, "high_level_log.jsonl"), []byte(log), 0600))
				require.NoError(t, refreshTestStatus(dir, "correction"))
				result, err := os.ReadFile(path)
				require.NoError(t, err)
				report, err := parse(result)
				require.NoError(t, err)
				if tc.applies {
					require.Equal(t, "third", report.Tasks[0].Owner)
					require.Empty(t, report.StatusSync.Pending)
				} else {
					require.Equal(t, "second", report.Tasks[0].Owner)
					require.NotEmpty(t, report.StatusSync.Pending)
				}
			})
	}
}

// TestLegacyCancellationRejectsSelfCorrectionsBeforeAtomicReplay checks grouped fields.
//
// Example: An invalid lifecycle correction cannot cancel a task through legacy pending state.
func TestLegacyCancellationRejectsSelfCorrectionsBeforeAtomicReplay(t *testing.T) {
	// log contains a cancellation whose correction names itself.
	//
	// Example: All three fields must remain unapplied.
	const log = `{"event":"correction","details":{"status_update":{"updates":[{"target":"task","id":"1","corrects":1,"fields":{"lifecycle":"cancelled","status":"unknown","evidence":"withdrawn"}}]}}}` + "\n"
	state := syncState{Cursor: 1, Applied: map[string]string{}, Latest: map[string]int{}, Pending: map[string]syncPending{}}
	for field, value := range map[string]string{"lifecycle": "cancelled", "status": "unknown", "evidence": "withdrawn"} {
		update := syncUpdate{Target: syncTargetTask, ID: "1", Corrects: 1, Fields: map[string]string{field: value}}
		key := syncTargetKey(update, field)
		state.Latest[key] = 1
		state.Pending[key] = syncPending{Line: 1, Update: update}
	}
	encoded, err := json.Marshal(state)
	require.NoError(t, err)
	input, err := putSyncState([]byte(linkedReport), string(encoded))
	require.NoError(t, err)
	dir := writeLinkedSources(t, linkedLedger, linkedForecasts)
	path := filepath.Join(dir, "latest-status-report.yaml")
	require.NoError(t, os.WriteFile(path, input, 0600))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "high_level_log.jsonl"), []byte(log), 0600))
	require.NoError(t, refreshTestStatus(dir, "correction"))
	result, err := os.ReadFile(path)
	require.NoError(t, err)
	report, err := parse(result)
	require.NoError(t, err)
	require.Equal(t, statusInProgress, report.Tasks[0].Status)
	require.NotEqual(t, taskLifecycleCancelled, report.Tasks[0].Lifecycle)
	require.Empty(t, report.Tasks[0].Evidence)
	require.Empty(t, report.StatusSync.Pending)
	require.Contains(t, report.Blockers, "Status refresh incomplete: invalid status_update requires manual review")
}

// TestLegacySameLineCorrectionRequiresMatchingPriorField checks provenance.
//
// Example: A different task or field cannot authorize an owner correction.
func TestLegacySameLineCorrectionRequiresMatchingPriorField(t *testing.T) {
	for _, tc := range []struct {
		name, prior string
	}{
		{"other task", `{"target":"task","id":"2","corrects":1,"fields":{"owner":"other"}}`},
		{"other field", `{"target":"task","id":"1","corrects":1,"fields":{"status":"IN PROGRESS"}}`},
	} {
		t.Run(tc.name,
			// Check an unrelated predecessor beside a saved legacy correction.
			//
			// Example: The existing owner remains unchanged.
			func(t *testing.T) {
				// saved is a field-wise correction naming ordinal zero of line two.
				//
				// Example: The saved owner remains "second" when its locator is invalid.
				const saved = `status_sync: {"cursor":2,"applied":{"[\"task\",\"1\",\"\",\"\"]/owner":"second"},"latest":{"[\"task\",\"1\",\"\",\"\"]/owner":2},"pending":{"[\"task\",\"1\",\"\",\"\"]/owner":{"line":2,"update":{"target":"task","id":"1","corrects":2,"corrects_ordinal":0,"fields":{"owner":"third"}}}}}`
				log := `{"event":"assignment_change","details":{"status_update":{"updates":[{"target":"task","id":"1","fields":{"owner":"first"}}]}}}` + "\n" + `{"event":"correction","details":{"status_update":{"updates":[` + tc.prior + `,{"target":"task","id":"1","corrects":2,"corrects_ordinal":0,"fields":{"owner":"third"}}]}}}` + "\n"
				dir := writeLinkedSources(t, linkedLedger, linkedForecasts)
				path := filepath.Join(dir, "latest-status-report.yaml")
				input := strings.Replace(linkedReport, "title: First,", `title: First, owner: second,`, 1)
				require.NoError(t, os.WriteFile(path, []byte(input+saved+"\n"), 0600))
				require.NoError(t, os.WriteFile(filepath.Join(dir, "high_level_log.jsonl"), []byte(log), 0600))
				require.NoError(t, refreshTestStatus(dir, "correction"))
				result, err := os.ReadFile(path)
				require.NoError(t, err)
				report, err := parse(result)
				require.NoError(t, err)
				require.Equal(t, "second", report.Tasks[0].Owner)
				require.Empty(t, report.StatusSync.Pending)
				require.Contains(t, report.Blockers, "Status refresh incomplete: invalid status_update requires manual review")
			})
	}
}

// TestLegacyEarlierCorrectionRequiresMatchingLatestPrior checks cross-line provenance.
//
// Example: A prior assignment to another task cannot authorize this correction.
func TestLegacyEarlierCorrectionRequiresMatchingLatestPrior(t *testing.T) {
	for _, tc := range []struct {
		name, prior, middle string
		applies, pending    bool
	}{
		{"valid", `{"target":"task","id":"1","fields":{"owner":"second"}}`, `{}`, true, false},
		{"other task", `{"target":"task","id":"2","fields":{"owner":"other"}}`, `{}`, false, false},
		{"other field", `{"target":"task","id":"1","fields":{"status":"IN PROGRESS"}}`, `{}`, false, false},
		{"newer assignment", `{"target":"task","id":"1","fields":{"owner":"first"}}`, `{"event":"assignment_change","details":{"status_update":{"updates":[{"target":"task","id":"1","fields":{"owner":"second"}}]}}}`, false, false},
		{"missing source", ``, `{}`, false, true},
	} {
		t.Run(tc.name,
			// Check one predecessor and any intervening field update.
			//
			// Example: Missing source remains pending for reconciliation.
			func(t *testing.T) {
				// saved is legacy field state for a line-three correction.
				//
				// Example: Owner "second" remains until a valid correction applies.
				const saved = `status_sync: {"cursor":3,"applied":{"[\"task\",\"1\",\"\",\"\"]/owner":"second"},"latest":{"[\"task\",\"1\",\"\",\"\"]/owner":3},"pending":{"[\"task\",\"1\",\"\",\"\"]/owner":{"line":3,"update":{"target":"task","id":"1","corrects":1,"fields":{"owner":"third"}}}}}`
				prior := `{}`
				if tc.prior != "" {
					prior = `{"event":"assignment_change","details":{"status_update":{"updates":[` + tc.prior + `]}}}`
				}
				log := prior + "\n" + tc.middle + "\n" + `{"event":"correction","details":{"status_update":{"updates":[{"target":"task","id":"1","corrects":1,"fields":{"owner":"third"}}]}}}` + "\n"
				dir := writeLinkedSources(t, linkedLedger, linkedForecasts)
				path := filepath.Join(dir, "latest-status-report.yaml")
				input := strings.Replace(linkedReport, "title: First,", `title: First, owner: second,`, 1)
				require.NoError(t, os.WriteFile(path, []byte(input+saved+"\n"), 0600))
				require.NoError(t, os.WriteFile(filepath.Join(dir, "high_level_log.jsonl"), []byte(log), 0600))
				require.NoError(t, refreshTestStatus(dir, "correction"))
				result, err := os.ReadFile(path)
				require.NoError(t, err)
				report, err := parse(result)
				require.NoError(t, err)
				if tc.applies {
					require.Equal(t, "third", report.Tasks[0].Owner)
				} else {
					require.Equal(t, "second", report.Tasks[0].Owner)
				}
				if tc.pending {
					require.NotEmpty(t, report.StatusSync.Pending)
				} else {
					require.Empty(t, report.StatusSync.Pending)
				}
			})
	}
}
