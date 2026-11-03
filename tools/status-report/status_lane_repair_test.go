package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func explorationProjection(t *testing.T, report, log string, ledger ledgerSource, forecasts forecastSource) report {
	t.Helper()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "high_level_log.jsonl"), []byte(log+"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	out, _, err := projectLogStatus(dir, []byte(report), ledger, forecasts)
	if err != nil {
		t.Fatal(err)
	}
	r, err := parse(out)
	if err != nil {
		t.Fatal(err)
	}
	return r
}

func TestExplorationForecastedLaneCompletion(t *testing.T) {
	ledger := ledgerSource{Records: map[string]sourceRecord{"work:first": {Type: "work", Data: workData{State: workStateCompleted, CompletedAt: "2026-11-02T15:25:00Z", ForecastRef: "forecasts.yaml#/records/first"}}}}
	forecasts := forecastSource{Records: map[string]map[string]any{"first": {"status": "inactive"}}}
	log := `{"event":"lifecycle_change","details":{"status_update":{"updates":[{"target":"lane","id":"1","work_ref":"project-understanding.yaml#/records/work:first","required_environment":"implementation","evidence":"accepted","fields":{"implementation_status":"CLOSED","completed_at":"2026-11-02T15:25:00Z"}}]}}}`
	r := explorationProjection(t, linkedReport, log, ledger, forecasts)
	if r.Lanes[0].ImplementationStatus != statusClosed || r.Lanes[0].Forecast != nil {
		t.Fatalf("canonical completion + inactive forecast did not close/retire report lane: status=%v forecast=%v pending=%d", r.Lanes[0].ImplementationStatus, r.Lanes[0].Forecast != nil, len(r.StatusSync.Pending))
	}
}

func TestExplorationForecastedLaneCancellation(t *testing.T) {
	ledger := ledgerSource{Records: map[string]sourceRecord{"work:first": {Type: "work", Data: workData{State: workStateCancelled, ForecastRef: "forecasts.yaml#/records/first"}}}}
	forecasts := forecastSource{Records: map[string]map[string]any{"first": {"status": "inactive"}}}
	log := `{"event":"lifecycle_change","details":{"status_update":{"updates":[{"target":"lane","id":"1","work_ref":"project-understanding.yaml#/records/work:first","required_environment":"implementation","evidence":"owner cancelled","fields":{"lifecycle":"cancelled"}}]}}}`
	r := explorationProjection(t, linkedReport, log, ledger, forecasts)
	if r.Lanes[0].Lifecycle != laneLifecycleCancelled || r.Lanes[0].Forecast != nil {
		t.Fatalf("canonical cancellation + inactive forecast did not cancel/retire report lane: lifecycle=%v forecast=%v pending=%d", r.Lanes[0].Lifecycle, r.Lanes[0].Forecast != nil, len(r.StatusSync.Pending))
	}
}

func TestExplorationClosedLaneCorrection(t *testing.T) {
	report := strings.Replace(linkedReport, "    forecast: {forecast_ref: 'forecasts.yaml#/records/first', outcome: First result, target: '2026-11-02T16:00:00Z', assessment: complete, baseline: '2026-11-02T16:00:00Z', evidence: initial}\n", "    completed_at: '2026-11-02T15:25:00Z'\n", 1)
	report = strings.Replace(report, "implementation_status: IN PROGRESS", "implementation_status: CLOSED", 1)
	log := `{"event":"lifecycle_change","details":{"status_update":{"updates":[{"target":"lane","id":"1","work_ref":"project-understanding.yaml#/records/work:first","required_environment":"implementation","fields":{"implementation_status":"IN PROGRESS"}}]}}}`
	r := explorationProjection(t, report, log, ledgerSource{}, forecastSource{})
	if r.Lanes[0].ImplementationStatus != statusInProgress || r.Lanes[0].CompletedAt != "" {
		t.Fatalf("reopening lane could not clear terminal completion: status=%v completed_at=%q pending=%d", r.Lanes[0].ImplementationStatus, r.Lanes[0].CompletedAt, len(r.StatusSync.Pending))
	}
}

func TestExtendedAdditionRequiresIdentityAndCompleteRecords(t *testing.T) {
	for _, tc := range []struct {
		target, record string
		want           bool
	}{
		{"lane", `{"task_id":"1","work_ref":"project-understanding.yaml#/records/work:first","outcome":"First result","required_environment":"implementation","implementation_status":"NEW","test_status":"NEW","prod_status":"NEW"}`, true},
		{"lane", `{"task_id":"1","outcome":"First result"}`, false},
		{"root_completion", `{"work_ref":"project-understanding.yaml#/records/root","outcome":"Root result","completed_at":"2026-11-02T15:00:00Z"}`, true},
		{"root_completion", `{"work_ref":"project-understanding.yaml#/records/root","outcome":"Root result"}`, false},
		{"root_forecast", `{"forecast_ref":"forecasts.yaml#/records/root","outcome":"Root result","target":"2026-11-02T16:00:00Z","assessment":"complete"}`, true},
	} {
		input := []byte(valid)
		got, ok := applySyncAddition(input, syncAddition{Target: parseSyncTarget(tc.target), Record: json.RawMessage(tc.record)})
		if ok != tc.want {
			t.Errorf("%s: accepted=%v wanted %v: %s", tc.target, ok, tc.want, got)
		}
	}
}

func TestLaneTransitionRequiresCanonicalIdentity(t *testing.T) {
	update := syncUpdate{Target: syncTargetLane, ID: "1", WorkRef: "project-understanding.yaml#/records/work:first", RequiredEnvironment: syncEnvironmentImplementation, Evidence: "accepted", Fields: map[string]string{"implementation_status": "CLOSED", "completed_at": "2026-11-02T15:25:00Z"}}
	ledger := ledgerSource{Records: map[string]sourceRecord{"work:first": {Type: "work", Data: workData{State: workStateCompleted, CompletedAt: "2026-11-02T15:25:00Z", ForecastRef: "forecasts.yaml#/records/first"}}}}
	forecasts := forecastSource{Records: map[string]map[string]any{"first": {"status": "inactive"}}}
	got, ok := applyLaneSyncUpdateRaw([]byte(linkedReport), update, ledger, forecasts, nil)
	if !ok {
		removed, rok := removeLaneSyncField([]byte(linkedReport), update, "forecast")
		timed, tok := applySyncField(removed, update, "completed_at", update.Fields["completed_at"], "")
		closed, cok := applySyncField(timed, update, "implementation_status", "CLOSED", "")
		_, err := parse(closed)
		t.Fatalf("valid transition rejected: remove=%v time=%v close=%v parse=%v candidate=%s", rok, tok, cok, err, closed)
	}
	r, err := parse(got)
	if err != nil || r.Lanes[0].Forecast != nil || r.Lanes[0].ImplementationStatus != statusClosed {
		t.Fatalf("invalid transition: %v %s", err, got)
	}
	forecasts.Records["first"]["status"] = "active"
	if got, ok = applyLaneSyncUpdateRaw([]byte(linkedReport), update, ledger, forecasts, nil); ok || string(got) != linkedReport {
		t.Fatal("active forecast allowed closure")
	}
	forecasts.Records["first"]["status"] = "inactive"
	update.Evidence = ""
	if _, ok = applyLaneSyncUpdateRaw([]byte(linkedReport), update, ledger, forecasts, nil); ok {
		t.Fatal("closure without evidence accepted")
	}
}

func TestAdditionSourceValidation(t *testing.T) {
	work := sourceRecord{Type: "work", OutcomeRefs: []string{"o"}, Data: workData{State: workStateCompleted, CompletedAt: "2026-11-02T15:00:00Z", Roles: []reportingRole{reportingRoleRoot}, ForecastRef: "forecasts.yaml#/records/f"}}
	ledger := ledgerSource{Records: map[string]sourceRecord{"w": work, "o": {Type: "outcome", Outcome: "Result"}}}
	forecasts := forecastSource{Records: map[string]map[string]any{"f": {"status": "inactive", "kind": "root"}}}
	add := syncAddition{Target: syncTargetRootCompletion, Evidence: "accepted", Record: json.RawMessage(`{"work_ref":"project-understanding.yaml#/records/w","outcome":"Result","completed_at":"2026-11-02T15:00:00Z"}`)}
	if !syncAdditionSourceValid(add, ledger, forecasts) {
		t.Fatal("valid source rejected")
	}
	add.Evidence = ""
	if syncAdditionSourceValid(add, ledger, forecasts) {
		t.Fatal("accepted completion without evidence")
	}
	add.Evidence = "accepted"
	forecasts.Records["f"]["status"] = "active"
	if syncAdditionSourceValid(add, ledger, forecasts) {
		t.Fatal("active forecast allowed completed root")
	}
}

func TestLaneTransitionPreservesCommentsAndOwnerCompletion(t *testing.T) {
	closed := strings.Replace(linkedReport, "    forecast: {forecast_ref: 'forecasts.yaml#/records/first', outcome: First result, target: '2026-11-02T16:00:00Z', assessment: complete, baseline: '2026-11-02T16:00:00Z', evidence: initial}\n", "    completed_at: '2026-11-02T15:25:00Z' # owner note\n", 1)
	closed = strings.Replace(closed, "implementation_status: IN PROGRESS", "implementation_status: CLOSED", 1)
	update := syncUpdate{Target: syncTargetLane, ID: "1", WorkRef: "project-understanding.yaml#/records/work:first", RequiredEnvironment: syncEnvironmentImplementation, Fields: map[string]string{"implementation_status": "IN PROGRESS"}}
	if _, ok := applyLaneSyncUpdateRaw([]byte(closed), update, ledgerSource{}, forecastSource{}, nil); ok {
		t.Fatal("removed owner comment")
	}
	closed = strings.Replace(closed, " # owner note", "", 1)
	if _, ok := applyLaneSyncUpdateRaw([]byte(closed), update, ledgerSource{}, forecastSource{}, map[string]string{"completed_at": "2026-11-02T15:24:00Z"}); ok {
		t.Fatal("removed owner-edited completion")
	}
	got, ok := applyLaneSyncUpdateRaw([]byte(closed), update, ledgerSource{}, forecastSource{}, nil)
	if !ok || strings.Contains(string(got), "completed_at:") {
		t.Fatal("reopen did not clear stale completion")
	}
}
