package main

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

// TestLegacyAppliedRootCorrectionLineage checks every immutable predecessor.
//
// Example: A duplicate or intervening same-work event prevents reconciliation.
func TestLegacyAppliedRootCorrectionLineage(t *testing.T) {
	firstRecord := `{"work_ref":"project-understanding.yaml#/records/w","outcome":"Result","completed_at":"2026-11-02T15:00:00Z"}`
	secondRecord := `{"work_ref":"project-understanding.yaml#/records/w","outcome":"Result","completed_at":"2026-11-02T15:05:00Z"}`
	thirdRecord := `{"work_ref":"project-understanding.yaml#/records/w","outcome":"Result","completed_at":"2026-11-02T15:10:00Z"}`
	firstEntry := `{"target":"root_completion","evidence":"accepted","record":` + firstRecord + `}`
	first := `{"event":"lifecycle_change","details":{"status_update":{"additions":[` + firstEntry + `]}}}`
	second := `{"event":"correction","details":{"corrects":1,"status_update":{"additions":[{"target":"root_completion","evidence":"corrected","expected_prior":` + firstRecord + `,"record":` + secondRecord + `}]}}}`
	third := `{"event":"correction","details":{"corrects":2,"status_update":{"additions":[{"target":"root_completion","evidence":"corrected again","expected_prior":` + secondRecord + `,"record":` + thirdRecord + `}]}}}`
	cases := []struct {
		name, log string
		want      bool
	}{
		{"valid recursive", first + "\n" + second + "\n" + third, true},
		{"ambiguous predecessor", strings.Replace(first, firstEntry, firstEntry+","+firstEntry, 1) + "\n" + second + "\n" + third, false},
		{"wrong ancestor", first + "\n" + strings.Replace(second, `"corrects":1`, `"corrects":9`, 1) + "\n" + third, false},
		{"intervening work", first + "\n" + strings.Replace(second, `"additions":[`, `"additions":[`+firstEntry+`,`, 1) + "\n" + third, false},
	}
	for _, tc := range cases {
		t.Run(tc.name,
			// Check the selected chain against its source history.
			//
			// Example: A duplicate predecessor is ambiguous.
			func(t *testing.T) {
				lines := bytes.Split([]byte(tc.log), []byte("\n"))
				var event syncEvent
				require.NoError(t, json.Unmarshal(lines[2], &event))
				old := syncPendingAddition{Line: 3, Target: syncTargetRootCompletion, Record: thirdRecord, ExpectedPrior: secondRecord, PriorLine: 2, PriorRecord: secondRecord}
				require.Equal(t, tc.want, legacyAppliedRootCorrectionLineage(lines, old, event, 0))
			})
	}
}
