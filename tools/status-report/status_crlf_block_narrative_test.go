package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
	"gopkg.in/yaml.v3"
)

// TestCRLFBlockNarrativeAppendPreservesLineEndings checks real refresh output.
//
// Example: A new progress entry retains the owner's comment and CRLF layout.
func TestCRLFBlockNarrativeAppendPreservesLineEndings(t *testing.T) {
	input := strings.Replace(linkedReport, "progress: [Implementation started]\n", "progress:\n  - Implementation started\n# decisions note\n", 1)
	require.NotEqual(t, linkedReport, input)
	input = strings.ReplaceAll(input, "\n", "\r\n")
	// event adds a keyed progress entry without replacing the existing text.
	//
	// Example: Append independently supplied work to a block-style list.
	const event = `{"event":"worker_progress","details":{"status_update":{"updates":[{"target":"progress","id":"one","fields":{"text":"new progress"}}]}}}` + "\n"
	dir := t.TempDir()
	path := filepath.Join(dir, "latest-status-report.yaml")
	require.NoError(t, os.WriteFile(path, []byte(input), 0600))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "project-understanding.yaml"), []byte(linkedLedger), 0600))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "forecasts.yaml"), []byte(linkedForecasts), 0600))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "high_level_log.jsonl"), []byte(event), 0600))
	require.NoError(t, refreshTestStatus(dir, "worker_progress"))
	result, err := os.ReadFile(path)
	require.NoError(t, err)
	report, err := parse(result)
	require.NoError(t, err)
	require.Contains(t, report.Progress, "Implementation started")
	require.Contains(t, report.Progress, "new progress")
	require.Contains(t, string(result), "# decisions note\r\ndecisions:")
	require.NotContains(t, strings.ReplaceAll(string(result), "\r\n", ""), "\n")
	require.Equal(t, 1, report.StatusSync.Cursor)
}

// TestCRLFBlockNarrativeRetractionPreservesLineEndings checks an emptied list.
//
// Example: Retracting the last managed entry keeps the report's CRLF layout.
func TestCRLFBlockNarrativeRetractionPreservesLineEndings(t *testing.T) {
	input := strings.Replace(linkedReport, "progress: [Implementation started]\n", "progress:\n  - Implementation started\n# decisions note\n", 1)
	require.NotEqual(t, linkedReport, input)
	input = strings.ReplaceAll(input, "\n", "\r\n")
	// first creates a managed progress entry.
	//
	// Example: Record a claim that may later be retracted.
	const first = `{"event":"decision","details":{"status_update":{"updates":[{"target":"progress","id":"one","fields":{"text":"withdrawn claim"}}]}}}` + "\n"
	// second explicitly retracts that exact claim.
	//
	// Example: Remove the remaining managed item after the owner removes a legacy item.
	const second = `{"event":"correction","details":{"status_update":{"updates":[{"target":"progress","id":"one","corrects":1,"retract":true}]}}}` + "\n"
	dir := t.TempDir()
	path := filepath.Join(dir, "high_level_log.jsonl")
	require.NoError(t, os.WriteFile(path, []byte(first), 0600))
	initial, _, err := projectLogStatus(dir, []byte(input), ledgerSource{}, forecastSource{})
	require.NoError(t, err)
	edited := strings.Replace(string(initial), "  - Implementation started\r\n", "", 1)
	require.NotEqual(t, string(initial), edited)
	require.NoError(t, os.WriteFile(path, []byte(first+second), 0600))
	result, _, err := projectLogStatus(dir, []byte(edited), ledgerSource{}, forecastSource{})
	require.NoError(t, err)
	report, err := parse(result)
	require.NoError(t, err)
	require.Empty(t, report.Progress)
	require.Contains(t, string(result), "# decisions note\r\ndecisions:")
	require.NotContains(t, strings.ReplaceAll(string(result), "\r\n", ""), "\n")
	require.Empty(t, report.StatusSync.Groups)
}

// TestCRLFBlockNarrativeAtEOFWithoutNewline preserves the final line boundary.
//
// Example: Appending to a final list without a newline does not introduce bare CR or LF.
func TestCRLFBlockNarrativeAtEOFWithoutNewline(t *testing.T) {
	input := strings.Replace(linkedReport, "progress: [Implementation started]\n", "", 1)
	require.NotEqual(t, linkedReport, input)
	input = strings.ReplaceAll(input, "\n", "\r\n") + "progress:\r\n  - Implementation started"
	// event appends to the final block list.
	//
	// Example: Preserve the preceding final item when no newline existed at EOF.
	const event = `{"event":"worker_progress","details":{"status_update":{"updates":[{"target":"progress","id":"one","fields":{"text":"new progress"}}]}}}` + "\n"
	dir := t.TempDir()
	require.NoError(t, os.WriteFile(filepath.Join(dir, "high_level_log.jsonl"), []byte(event), 0600))
	result, _, err := projectLogStatus(dir, []byte(input), ledgerSource{}, forecastSource{})
	require.NoError(t, err)
	report, err := parse(result)
	require.NoError(t, err)
	require.Contains(t, report.Progress, "Implementation started")
	require.Contains(t, report.Progress, "new progress")
	normalized := strings.ReplaceAll(string(result), "\r\n", "")
	require.NotContains(t, normalized, "\n")
	require.NotContains(t, normalized, "\r")
}

// TestCRLFMultilineNarrativeRetractionKeepsFinalBoundary checks both EOF layouts.
//
// Example: Removing a multiline final item preserves whether its last line was terminated.
func TestCRLFMultilineNarrativeRetractionKeepsFinalBoundary(t *testing.T) {
	for _, tc := range []struct{ name, input, want string }{
		{"unterminated", "progress:\r\n  - subject_ref: one\r\n    text: done", "progress:\r\n  []"},
		{"terminated", "progress:\r\n  - subject_ref: one\r\n    text: done\r\n", "progress:\r\n  []\r\n"},
		{"following field", "progress:\r\n  - subject_ref: one\r\n    text: done\r\ndecisions: []\r\n", "progress:\r\n  []\r\ndecisions: []\r\n"},
		{"indentless", "progress:\r\n- subject_ref: one\r\n  text: done", "progress:\r\n  []"},
	} {
		t.Run(tc.name,
			// run checks that the emptied list remains valid at each boundary.
			//
			// Example: An unterminated item leaves no stray carriage return.
			func(t *testing.T) {
				out, ok := retractNarrativeSync([]byte(tc.input), syncUpdate{Target: syncTargetProgress, ID: "one"}, "done", true, "", false)
				require.True(t, ok)
				require.Equal(t, tc.want, string(out))
			})
	}
}

// TestCRLFRetractionOfLastEntryKeepsSurvivorBoundary preserves EOF formatting.
//
// Example: Removing the final managed entry keeps the preceding legacy item intact.
func TestCRLFRetractionOfLastEntryKeepsSurvivorBoundary(t *testing.T) {
	for _, tc := range []struct{ name, suffix, want string }{
		{"unterminated", "", "progress:\r\n  - legacy\r\n"},
		{"terminated", "\r\n", "progress:\r\n  - legacy\r\n"},
		{"following field", "\r\ndecisions: []\r\n", "progress:\r\n  - legacy\r\ndecisions: []\r\n"},
	} {
		t.Run(tc.name,
			// check verifies the surviving list and its original final boundary.
			//
			// Example: An unterminated final entry does not leave a bare CR.
			func(t *testing.T) {
				input := "progress:\r\n  - legacy\r\n  - subject_ref: one\r\n    text: done" + tc.suffix
				out, ok := retractNarrativeSync([]byte(input), syncUpdate{Target: syncTargetProgress, ID: "one"}, "done", true, "", false)
				require.True(t, ok)
				require.Equal(t, tc.want, string(out))
			})
	}
}

// TestRetractionPreservesBlockScalarSurvivor checks unowned narrative values.
//
// Example: A clipped literal retains its final newline after a later item is removed.
func TestRetractionPreservesBlockScalarSurvivor(t *testing.T) {
	for _, style := range []string{"|", ">", "|-", ">-"} {
		t.Run(style,
			// check compares the surviving scalar before and after retraction.
			//
			// Example: A clipped folded scalar retains its newline.
			func(t *testing.T) {
				input := []byte("progress:\r\n  - " + style + "\r\n    legacy scalar\r\n  - subject_ref: one\r\n    text: done")
				var before, after yaml.Node
				require.NoError(t, yaml.Unmarshal(input, &before))
				out, ok := retractNarrativeSync(input, syncUpdate{Target: syncTargetProgress, ID: "one"}, "done", true, "", false)
				require.True(t, ok)
				require.NoError(t, yaml.Unmarshal(out, &after))
				require.Equal(t, mapValue(before.Content[0], "progress").Content[0].Value, mapValue(after.Content[0], "progress").Content[0].Value)
			})
	}
}
