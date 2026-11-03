package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

// TestNumericTaskIdentitiesReplayLexically checks the public refresh path.
//
// Example: Numeric-looking 1.10 and 1.1 remain distinct task identifiers.
func TestNumericTaskIdentitiesReplayLexically(t *testing.T) {
	report := strings.Replace(linkedReport, "id: '1', title: First", "id: 1, title: First", 1)
	report = strings.Replace(report, "id: '2', title: Second", "id: 1.1, parent_id: 1, title: Second", 1)
	report = strings.Replace(report, "top_priorities: ['1', '2']", "  - {id: 1.10, parent_id: 1, title: Third, priority: high, impact: Useful, effort: {min_minutes: 10, max_minutes: 20, kind: elapsed, basis: guess}, status: IN PROGRESS, work_refs: ['project-understanding.yaml#/records/work:second']}\ntop_priorities: [1, 1.1, 1.10]", 1)
	report = strings.Replace(report, "task_id: '1'", "task_id: 1", 1)
	report = strings.Replace(report, "task_id: '2'", "task_id: 1.1", 1)
	_, err := parse([]byte(report))
	require.NoError(t, err)
	dir := writeLinkedSources(t, linkedLedger, linkedForecasts)
	path := filepath.Join(dir, "latest-status-report.yaml")
	require.NoError(t, os.WriteFile(path, []byte(report), 0600))
	event := `{"event":"assignment_change","details":{"status_update":{"updates":[{"target":"task","id":"1.10","fields":{"owner":"selected owner"}}]}}}` + "\n"
	require.NoError(t, os.WriteFile(filepath.Join(dir, "high_level_log.jsonl"), []byte(event), 0600))
	var out, errOut bytes.Buffer
	require.Equal(t, 0, run([]string{"refresh", dir, "assignment_change"}, strings.NewReader(""), &out, &errOut), errOut.String())
	result, err := os.ReadFile(path)
	require.NoError(t, err)
	parsed, err := parse(result)
	require.NoError(t, err)
	require.Equal(t, taskID("1.1"), parsed.Tasks[1].ID)
	require.Empty(t, parsed.Tasks[1].Owner)
	require.Equal(t, taskID("1.10"), parsed.Tasks[2].ID)
	require.Equal(t, "selected owner", parsed.Tasks[2].Owner)
	require.Equal(t, []taskID{"1", "1.1", "1.10"}, parsed.TopPriorities)
	out.Reset()
	errOut.Reset()
	require.Equal(t, 0, run([]string{"refresh", dir, "assignment_change"}, strings.NewReader(""), &out, &errOut), errOut.String())
	retry, err := os.ReadFile(path)
	require.NoError(t, err)
	require.Equal(t, result, retry)
}

// TestNumericTopPriorityCancellation checks the keyed removal effect.
//
// Example: Cancelling numeric task 1 removes only its own numeric priority entry.
func TestNumericTopPriorityCancellation(t *testing.T) {
	report := strings.Replace(linkedReport, "id: '1', title: First", "id: 1, title: First", 1)
	report = strings.Replace(report, "top_priorities: ['1', '2']", "top_priorities: [1, '2']", 1)
	report = strings.Replace(report, "task_id: '1'", "task_id: 1", 1)
	dir := writeLinkedSources(t, linkedLedger, linkedForecasts)
	path := filepath.Join(dir, "latest-status-report.yaml")
	require.NoError(t, os.WriteFile(path, []byte(report), 0600))
	event := `{"event":"lifecycle_change","details":{"status_update":{"updates":[{"target":"task","id":"1","fields":{"status":"unknown","lifecycle":"cancelled","evidence":"withdrawn"}}]}}}` + "\n"
	require.NoError(t, os.WriteFile(filepath.Join(dir, "high_level_log.jsonl"), []byte(event), 0600))
	var out, errOut bytes.Buffer
	require.Equal(t, 0, run([]string{"refresh", dir, "lifecycle_change"}, strings.NewReader(""), &out, &errOut), errOut.String())
	result, err := os.ReadFile(path)
	require.NoError(t, err)
	parsed, err := parse(result)
	require.NoError(t, err)
	require.Equal(t, taskLifecycleCancelled, parsed.Tasks[0].Lifecycle)
	require.Equal(t, []taskID{"2"}, parsed.TopPriorities)
}

// TestVerificationRetainsUnchangedIdentityRepresentation checks owner-authored IDs.
//
// Example: Updating task 1 cannot silently rewrite another numeric ID as a string.
func TestVerificationRetainsUnchangedIdentityRepresentation(t *testing.T) {
	before := []byte("tasks: [{id: 1, owner: old}, {id: 2, owner: keep}]\n")
	effects := []syncEffect{{Target: syncTargetTask, ID: "1", Field: "owner", Value: "new", Operation: syncEffectSet}}
	good := []byte("tasks: [{id: 1, owner: new}, {id: 2, owner: keep}]\n")
	changed := []byte("tasks: [{id: 1, owner: new}, {id: '2', owner: keep}]\n")
	require.NoError(t, verifyStatusSyncEffects(before, good, effects))
	require.Error(t, verifyStatusSyncEffects(before, changed, effects))
}

// TestNumericLaneAndReviewSelectorsReplay checks other task-keyed targets.
//
// Example: A numeric lane or review task ID matches its explicit string selector.
func TestNumericLaneAndReviewSelectorsReplay(t *testing.T) {
	base := strings.Replace(linkedReport, "id: '1', title: First", "id: 1, title: First", 1)
	base = strings.Replace(base, "top_priorities: ['1', '2']", "top_priorities: [1, '2']", 1)
	base = strings.Replace(base, "task_id: '1'", "task_id: 1", 1)
	for _, tc := range []struct{ name, input, event string }{
		{"lane", base, `{"event":"assignment_change","details":{"status_update":{"updates":[{"target":"lane","id":"1","work_ref":"project-understanding.yaml#/records/work:first","required_environment":"implementation","fields":{"owner":"lane owner"}}]}}}`},
		{"review", base + "reviews: [{task_id: 1, reporter: A, critic: B, rounds: 1, estimate: checked, impact: checked, priority: checked, unresolved: none}]\n", `{"event":"review_result","details":{"status_update":{"updates":[{"target":"review","id":"1","values":{"critic":"new critic"}}]}}}`},
	} {
		t.Run(tc.name,
			// Apply a targeted lane or review event through refresh.
			//
			// Example: Numeric task ID 1 matches exactly one section entry.
			func(t *testing.T) {
				dir := writeLinkedSources(t, linkedLedger, linkedForecasts)
				path := filepath.Join(dir, "latest-status-report.yaml")
				require.NoError(t, os.WriteFile(path, []byte(tc.input), 0600))
				require.NoError(t, os.WriteFile(filepath.Join(dir, "high_level_log.jsonl"), []byte(tc.event+"\n"), 0600))
				var out, errOut bytes.Buffer
				require.Equal(t, 0, run([]string{"refresh", dir, "decision"}, strings.NewReader(""), &out, &errOut), errOut.String())
				result, err := os.ReadFile(path)
				require.NoError(t, err)
				parsed, err := parse(result)
				require.NoError(t, err)
				if tc.name == "lane" {
					require.Equal(t, "lane owner", parsed.Lanes[0].Owner)
				} else {
					require.Equal(t, "new critic", parsed.Reviews[0].Critic)
				}
				require.Empty(t, parsed.StatusSync.Groups)
			})
	}
}

// TestVerificationRetainsOtherSectionIdentityStyles checks unrelated record IDs.
//
// Example: A task update cannot rewrite a lane or review ID's YAML type.
func TestVerificationRetainsOtherSectionIdentityStyles(t *testing.T) {
	before := []byte("tasks: [{id: 1, owner: old}]\nlanes: [{task_id: 1, work_ref: work, required_environment: implementation}]\nreviews: [{task_id: 1, critic: B}]\n")
	effects := []syncEffect{{Target: syncTargetTask, ID: "1", Field: "owner", Value: "new", Operation: syncEffectSet}}
	good := strings.Replace(string(before), "owner: old", "owner: new", 1)
	require.NoError(t, verifyStatusSyncEffects(before, []byte(good), effects))
	changedLane := strings.Replace(good, "lanes: [{task_id: 1,", "lanes: [{task_id: '1',", 1)
	changedReview := strings.Replace(good, "reviews: [{task_id: 1,", "reviews: [{task_id: '1',", 1)
	require.Error(t, verifyStatusSyncEffects(before, []byte(changedLane), effects))
	require.Error(t, verifyStatusSyncEffects(before, []byte(changedReview), effects))
}
