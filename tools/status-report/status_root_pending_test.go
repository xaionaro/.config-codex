package main

import (
	"encoding/json"
	"testing"

	"gopkg.in/yaml.v3"
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
		ok := migratePendingRootAdditions(legacy, pending, []byte(tc.log), nil)
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
	if !migratePendingRootAdditions(legacy, pending, []byte(log), nil) || len(legacy) != 0 || len(pending) != 2 {
		t.Fatalf("lost correction provenance: %v %v", legacy, pending)
	}
}

// TestRootPendingYAMLRoundTrip restores structured JSON fields from persisted state.
//
// Example: A pending transition survives report decoding.
func TestRootPendingYAMLRoundTrip(t *testing.T) {
	original := syncPendingRootAddition{Locator: rootLifecycleLocator{Line: 1, Ordinal: 0, Target: syncTargetRootCompletion}, Addition: syncAddition{Target: syncTargetRootCompletion, Record: json.RawMessage(`{"work_ref":"w","outcome":"x"}`), ExpectedPrior: json.RawMessage(`{"forecast_ref":"f"}`), Evidence: "accepted"}}
	encoded, err := json.Marshal(original)
	if err != nil {
		t.Fatal(err)
	}
	var decoded syncPendingRootAddition
	if err := yaml.Unmarshal(encoded, &decoded); err != nil {
		t.Fatal(err)
	}
	if !sameRootPendingJSON(original.Addition.Record, decoded.Addition.Record) || !sameRootPendingJSON(original.Addition.ExpectedPrior, decoded.Addition.ExpectedPrior) || decoded.Locator != original.Locator {
		t.Fatalf("round trip changed entry: %+v", decoded)
	}
}
