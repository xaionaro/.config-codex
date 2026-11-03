package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRootTransitionRequiresExactPriorAndCanonicalSource(t *testing.T) {
	old := `{"forecast_ref":"forecasts.yaml#/records/f","outcome":"Result","target":"2026-11-02T16:00:00Z","assessment":"complete"}`
	original := []byte(valid + "root_forecasts: [" + old + "]\n")
	add := syncAddition{Target: syncTargetRootCompletion, Evidence: "accepted", RetireForecast: true, ExpectedPrior: json.RawMessage(old), Record: json.RawMessage(`{"work_ref":"project-understanding.yaml#/records/w","outcome":"Result","completed_at":"2026-11-02T15:00:00Z"}`)}
	ledger := ledgerSource{Records: map[string]sourceRecord{"w": {Type: "work", OutcomeRefs: []string{"o"}, Data: workData{State: workStateCompleted, CompletedAt: "2026-11-02T15:00:00Z", Roles: []reportingRole{reportingRoleRoot}, ForecastRef: "forecasts.yaml#/records/f"}}, "o": {Type: "outcome", Outcome: "Result"}}}
	forecasts := forecastSource{Records: map[string]map[string]any{"f": {"kind": "root", "status": "inactive"}}}
	got, effects, ok := applyRootSyncAddition(original, add, ledger, forecasts)
	if !ok || strings.Contains(string(got), old) {
		t.Fatal("root transition failed")
	}
	effects = append(effects, syncEffect{Target: syncTargetRootCompletion, ID: "project-understanding.yaml#/records/w", Value: add.Record, Operation: syncEffectAdd})
	if err := verifyStatusSyncEffects(original, got, effects); err != nil {
		t.Fatal(err)
	}
	add.ExpectedPrior = json.RawMessage(strings.Replace(old, "Result", "Owner edit", 1))
	if _, _, ok := applyRootSyncAddition(original, add, ledger, forecasts); ok {
		t.Fatal("prior mismatch accepted")
	}
}

func TestRootReopenRequiresExactCompletionAndActiveWork(t *testing.T) {
	old := `{"work_ref":"project-understanding.yaml#/records/w","outcome":"Result","completed_at":"2026-11-02T15:00:00Z"}`
	original := []byte(valid + "root_completions: [" + old + "]\n")
	add := syncAddition{Target: syncTargetRootForecast, Evidence: "reopened", ReopenWorkRef: "project-understanding.yaml#/records/w", ExpectedPrior: json.RawMessage(old), Record: json.RawMessage(`{"forecast_ref":"forecasts.yaml#/records/f","outcome":"Result","target":"2026-11-02T16:00:00Z","assessment":"complete"}`)}
	ledger := ledgerSource{Records: map[string]sourceRecord{"w": {Type: "work", OutcomeRefs: []string{"o"}, Data: workData{State: workStateActive, Roles: []reportingRole{reportingRoleRoot}, ForecastRef: "forecasts.yaml#/records/f"}}, "o": {Type: "outcome", Outcome: "Result"}}}
	forecasts := forecastSource{Records: map[string]map[string]any{"f": {"kind": "root", "status": "active"}}}
	got, _, ok := applyRootSyncAddition(original, add, ledger, forecasts)
	if !ok || strings.Contains(string(got), old) {
		t.Fatal("root reopen failed")
	}
	add.Evidence = ""
	if _, _, ok := applyRootSyncAddition(original, add, ledger, forecasts); ok {
		t.Fatal("reopen without evidence accepted")
	}
	add.Evidence = "reopened"
	add.ReopenWorkRef = ""
	add.ExpectedPrior = nil
	if _, _, ok := applyRootSyncAddition(original, add, ledger, forecasts); ok {
		t.Fatal("missing explicit removal accepted")
	}
}

func TestRootTransitionPreservesComments(t *testing.T) {
	prior := `{"forecast_ref":"forecasts.yaml#/records/f","outcome":"Result","target":"2026-11-02T16:00:00Z","assessment":"complete"}`
	original := []byte(valid + "root_forecasts:\n  - " + prior + " # owner comment\n")
	if _, ok := removeRootSyncRecord(original, syncTargetRootForecast, "forecasts.yaml#/records/f", json.RawMessage(prior)); ok {
		t.Fatal("removed owner comment")
	}
}

func TestRootRemovalHandlesBlockAndFlowLists(t *testing.T) {
	prior := `{"forecast_ref":"forecasts.yaml#/records/f","outcome":"Result","target":"2026-11-02T16:00:00Z","assessment":"complete"}`
	other := `{"forecast_ref":"forecasts.yaml#/records/g","outcome":"Other","target":"2026-11-02T17:00:00Z","assessment":"complete"}`
	for _, section := range []string{"root_forecasts:\n  - " + prior + "\n", "root_forecasts:\n  - " + prior + "\n  - " + other + "\n", "root_forecasts: [" + prior + ", " + other + "]\n", "root_forecasts: [" + other + ", " + prior + "]\n"} {
		got, ok := removeRootSyncRecord([]byte(valid+section), syncTargetRootForecast, "forecasts.yaml#/records/f", json.RawMessage(prior))
		if !ok {
			t.Fatalf("removal failed: %s", section)
		}
		r, err := parse(got)
		if err != nil {
			t.Fatalf("invalid removal %s: %v", got, err)
		}
		for _, f := range r.RootForecasts {
			if f.ForecastRef == "forecasts.yaml#/records/f" {
				t.Fatal("target still present")
			}
		}
	}
}

func TestRootTransitionsReplay(t *testing.T) {
	forecast := `{"forecast_ref":"forecasts.yaml#/records/f","outcome":"Result","target":"2026-11-02T16:00:00Z","assessment":"complete"}`
	completion := `{"work_ref":"project-understanding.yaml#/records/w","outcome":"Result","completed_at":"2026-11-02T15:00:00Z"}`
	cases := []struct {
		name, section string
		addition      syncAddition
		work          workData
		state         string
	}{
		{"complete", "root_forecasts", syncAddition{Target: syncTargetRootCompletion, Evidence: "accepted", RetireForecast: true, ExpectedPrior: json.RawMessage(forecast), Record: json.RawMessage(completion)}, workData{State: workStateCompleted, CompletedAt: "2026-11-02T15:00:00Z", Roles: []reportingRole{reportingRoleRoot}, ForecastRef: "forecasts.yaml#/records/f"}, "inactive"},
		{"reopen", "root_completions", syncAddition{Target: syncTargetRootForecast, Evidence: "reopened", ReopenWorkRef: "project-understanding.yaml#/records/w", ExpectedPrior: json.RawMessage(completion), Record: json.RawMessage(forecast)}, workData{State: workStateActive, Roles: []reportingRole{reportingRoleRoot}, ForecastRef: "forecasts.yaml#/records/f"}, "active"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			prior := forecast
			if tc.name == "reopen" {
				prior = completion
			}
			original := []byte(valid + tc.section + ": [" + prior + "]\n")
			ledger := ledgerSource{Records: map[string]sourceRecord{"w": {Type: "work", OutcomeRefs: []string{"o"}, Data: tc.work}, "o": {Type: "outcome", Outcome: "Result"}}}
			forecasts := forecastSource{Records: map[string]map[string]any{"f": {"kind": "root", "status": tc.state}}}
			for _, mode := range []string{"valid", "mismatch", "missing"} {
				addition := tc.addition
				if mode == "mismatch" {
					addition.ExpectedPrior = json.RawMessage(`{"outcome":"wrong"}`)
				}
				if mode == "missing" {
					addition.ExpectedPrior = nil
				}
				raw, err := json.Marshal(addition)
				if err != nil {
					t.Fatal(err)
				}
				dir := t.TempDir()
				log := `{"event":"lifecycle_change","details":{"status_update":{"additions":[` + string(raw) + `]}}}` + "\n"
				if err := os.WriteFile(filepath.Join(dir, "high_level_log.jsonl"), []byte(log), 0600); err != nil {
					t.Fatal(err)
				}
				out, _, err := projectLogStatus(dir, original, ledger, forecasts)
				if err != nil {
					t.Fatal(err)
				}
				report, err := parse(out)
				if err != nil {
					t.Fatal(err)
				}
				if mode != "valid" {
					if len(report.StatusSync.PendingAdditions) != 1 {
						t.Fatal("mismatched prior did not remain pending")
					}
					continue
				}
				if len(report.StatusSync.PendingAdditions) != 0 {
					t.Fatal("valid transition pending")
				}
				if tc.name == "complete" && (len(report.RootCompletions) != 1 || len(report.RootForecasts) != 0) {
					t.Fatal("completion transition not applied")
				}
				if tc.name == "reopen" && (len(report.RootCompletions) != 0 || len(report.RootForecasts) != 1) {
					t.Fatal("reopen transition not applied")
				}
			}
		})
	}
}
