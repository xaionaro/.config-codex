package main

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestLaneChainProvenanceRejectsForgedLogPosition(t *testing.T) {
	u := syncUpdate{Target: syncTargetLane, ID: "1", WorkRef: "project-understanding.yaml#/records/work:first", RequiredEnvironment: syncEnvironmentImplementation, Evidence: "done", Fields: map[string]string{"implementation_status": "CLOSED", "completed_at": "2026-11-02T15:45:00Z"}}
	encoded, err := encodeSyncGroup(u)
	if err != nil {
		t.Fatal(err)
	}
	g := syncPendingGroup{Line: 1, Ordinal: 0, Update: encoded}
	raw, err := json.Marshal(u)
	if err != nil {
		t.Fatal(err)
	}
	log := []byte(`{"event":"lifecycle_change","details":{"status_update":{"updates":[` + string(raw) + `]}}}` + "\n")
	ledger := ledgerSource{Records: map[string]sourceRecord{"work:first": {Type: "work", Data: workData{State: workStateCompleted, CompletedAt: "2026-11-02T15:45:00Z", ForecastRef: "forecasts.yaml#/records/first"}}}}
	forecasts := forecastSource{Records: map[string]map[string]any{"first": {"kind": "lane", "status": "inactive"}}}
	if err := verifyLaneLifecycleChain([]byte(linkedReport), []byte(linkedReport), []syncPendingGroup{g}, nil, nil, nil, log, ledger, forecasts); err == nil {
		t.Fatal("accepted missing effects")
	}
	g.Ordinal = 1
	if err := verifyLaneLifecycleChain([]byte(linkedReport), []byte(linkedReport), []syncPendingGroup{g}, nil, nil, nil, log, ledger, forecasts); err == nil {
		t.Fatal("accepted forged ordinal")
	}
}

func TestLaneChainProvenanceChecksLogAndOwner(t *testing.T) {
	raw := []string{
		`{"event":"lifecycle_change","details":{"status_update":{"updates":[{"target":"lane","id":"1","work_ref":"project-understanding.yaml#/records/work:first","required_environment":"implementation","evidence":"cancelled","fields":{"lifecycle":"cancelled"}}]}}}`,
		`{"event":"lifecycle_change","details":{"status_update":{"updates":[{"target":"lane","id":"1","work_ref":"project-understanding.yaml#/records/work:first","required_environment":"implementation","evidence":"reopened","fields":{"blocker":"waiting"},"clear":["lifecycle"]}]}}}`,
		`{"event":"lifecycle_change","details":{"status_update":{"updates":[{"target":"lane","id":"1","work_ref":"project-understanding.yaml#/records/work:first","required_environment":"implementation","evidence":"accepted","fields":{"implementation_status":"CLOSED","completed_at":"2026-11-02T15:45:00Z"}}]}}}`,
	}
	var groups []syncPendingGroup
	for i, line := range raw {
		var event syncEvent
		if err := json.Unmarshal([]byte(line), &event); err != nil {
			t.Fatal(err)
		}
		encoded, err := encodeSyncGroup(event.Details.StatusUpdate.Updates[0])
		if err != nil {
			t.Fatal(err)
		}
		groups = append(groups, syncPendingGroup{Line: i + 1, Update: encoded})
	}
	ledger := ledgerSource{Records: map[string]sourceRecord{"work:first": {Type: "work", Data: workData{State: workStateCompleted, CompletedAt: "2026-11-02T15:45:00Z", ForecastRef: "forecasts.yaml#/records/first"}}}}
	forecasts := forecastSource{Records: map[string]map[string]any{"first": {"kind": "lane", "status": "inactive"}}}
	candidate, effects, provenance, ok := planLaneLifecycleChain([]byte(linkedReport), groups, ledger, forecasts, nil)
	if !ok {
		t.Fatal("planner rejected fixture")
	}
	log := []byte(strings.Join(raw, "\n") + "\n")
	if err := verifyLaneLifecycleChain([]byte(linkedReport), candidate, groups, effects, provenance, nil, log, ledger, forecasts); err != nil {
		t.Fatal(err)
	}
	if err := verifyLaneLifecycleChain([]byte(linkedReport), candidate, groups, effects, provenance, map[string]string{"blocker": "someone else's value"}, log, ledger, forecasts); err == nil {
		t.Fatal("accepted owner conflict")
	}
	raw[1] = strings.Replace(raw[1], "waiting", "forged", 1)
	if err := verifyLaneLifecycleChain([]byte(linkedReport), candidate, groups, effects, provenance, nil, []byte(strings.Join(raw, "\n")), ledger, forecasts); err == nil {
		t.Fatal("accepted mismatched log payload")
	}
}
