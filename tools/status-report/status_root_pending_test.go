package main

import (
	"encoding/json"
	"testing"
)

// TestRootPendingRetainsOrderedOccurrences verifies distinct locators retain repeated roots.
//
// Example: Two same-line transitions remain independently addressable.
func TestRootPendingRetainsOrderedOccurrences(t *testing.T) {
	pending := map[string]syncPendingRootAddition{}
	a := syncAddition{Target: syncTargetRootCompletion, Record: json.RawMessage(`{"work_ref":"project-understanding.yaml#/records/w"}`)}
	if !queueRootAddition(pending, 1, 0, a) || !queueRootAddition(pending, 1, 1, a) || len(pending) != 2 {
		t.Fatal("distinct occurrences not retained")
	}
	if queueRootAddition(pending, 1, 1, a) {
		t.Fatal("duplicate locator accepted")
	}
}

// TestRootPendingMigrationRequiresUniqueExactLogMatch verifies ambiguity is retained.
//
// Example: Duplicate matching entries cannot supply a missing ordinal.
func TestRootPendingMigrationRequiresUniqueExactLogMatch(t *testing.T) {
	entry := `{"target":"root_completion","record":{"work_ref":"project-understanding.yaml#/records/w"},"evidence":"accepted"}`
	old := syncPendingAddition{Line: 1, Target: syncTargetRootCompletion, ID: "project-understanding.yaml#/records/w", Record: `{"work_ref":"project-understanding.yaml#/records/w"}`, Evidence: "accepted"}
	for _, tc := range []struct {
		log  string
		want bool
	}{{`{"details":{"status_update":{"additions":[` + entry + `]}}}`, true}, {`{"details":{"status_update":{"additions":[` + entry + `,` + entry + `]}}}`, false}} {
		legacy := map[string]syncPendingAddition{"old": old}
		pending := map[string]syncPendingRootAddition{}
		ok := migratePendingRootAdditions(legacy, pending, []byte(tc.log))
		if ok != tc.want || (len(pending) == 1) != tc.want || (len(legacy) == 0) != tc.want {
			t.Fatalf("unexpected migration: ok=%v legacy=%v pending=%v", ok, legacy, pending)
		}
	}
}

// TestRootPendingMigrationPreservesCorrectionChain verifies prior source provenance is retained.
//
// Example: A pending correction keeps both its prior and corrected occurrences.
func TestRootPendingMigrationPreservesCorrectionChain(t *testing.T) {
	oldRecord := `{"work_ref":"project-understanding.yaml#/records/w","outcome":"old"}`
	newRecord := `{"work_ref":"project-understanding.yaml#/records/w","outcome":"new"}`
	log := `{"details":{"status_update":{"additions":[{"target":"root_completion","record":` + oldRecord + `,"evidence":"accepted"}]}}}` + "\n" + `{"event":"correction","details":{"corrects":1,"status_update":{"additions":[{"target":"root_completion","record":` + newRecord + `,"evidence":"corrected","expected_prior":` + oldRecord + `}]}}}`
	legacy := map[string]syncPendingAddition{"old": {Line: 2, Target: syncTargetRootCompletion, ID: "project-understanding.yaml#/records/w", Record: newRecord, Evidence: "corrected", ExpectedPrior: oldRecord, PriorLine: 1, PriorRecord: oldRecord}}
	pending := map[string]syncPendingRootAddition{}
	if !migratePendingRootAdditions(legacy, pending, []byte(log)) || len(legacy) != 0 || len(pending) != 2 {
		t.Fatalf("lost correction provenance: %v %v", legacy, pending)
	}
}
