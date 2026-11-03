package main

import (
	"encoding/json"
	"fmt"
	"reflect"
	"strings"

	"gopkg.in/yaml.v3"
)

type syncEffectOperation int

const (
	syncEffectSet syncEffectOperation = iota
	syncEffectAdd
	syncEffectRemove
	syncEffectMetadata
	syncEffectTimestamp
	syncEffectTimelineAnchor
	syncEffectDiagnostic
	syncEffectPriorityRemove
	syncEffectTimeline
	syncEffectClear
	syncEffectForecastRetire
	syncEffectCompletedAtClear
)

type syncEffect struct {
	Target              syncTarget
	ID, WorkRef         string
	Evidence            string
	RequiredEnvironment syncEnvironment
	Field               string
	Value               any
	Operation           syncEffectOperation
}

// verifyStatusSyncCanonicalEffects checks terminal lane effects against canonical work and forecasts.
func verifyStatusSyncCanonicalEffects(original, candidate []byte, effects []syncEffect, ledger ledgerSource, forecasts forecastSource) error {
	var before, after map[string]any
	if err := yaml.Unmarshal(original, &before); err != nil {
		return err
	}
	if err := yaml.Unmarshal(candidate, &after); err != nil {
		return err
	}
	for _, effect := range effects {
		if effect.Operation == syncEffectRemove && (effect.Target == syncTargetRootForecast || effect.Target == syncTargetRootCompletion) {
			if err := verifyCanonicalRootRemoval(before, effect, effects, ledger, forecasts); err != nil {
				return err
			}
			continue
		}
		if effect.Operation == syncEffectAdd && (effect.Target == syncTargetLane || effect.Target == syncTargetRootCompletion || effect.Target == syncTargetRootForecast) {
			if err := verifyCanonicalSyncAddition(effect, ledger, forecasts); err != nil {
				return err
			}
			continue
		}
		terminal := effect.Target == syncTargetLane && effect.Operation == syncEffectSet && ((effect.Field == effect.RequiredEnvironment.String()+"_status" && effect.Value == "CLOSED") || (effect.Field == "lifecycle" && effect.Value == "cancelled"))
		retirement := effect.Operation == syncEffectForecastRetire || (effect.Operation == syncEffectRemove && effect.Target == syncTargetLane && effect.Field == "forecast")
		if !terminal && !retirement {
			continue
		}
		if effect.Target != syncTargetLane || !validRef(effect.WorkRef, "project-understanding.yaml") || strings.TrimSpace(effect.Evidence) == "" {
			return fmt.Errorf("terminal lane effect lacks canonical identity or evidence")
		}
		work, ok := ledger.Records[sourceID(effect.WorkRef, "project-understanding.yaml")]
		if !ok || work.Type != "work" {
			return fmt.Errorf("terminal lane work missing")
		}
		items, ok := after["lanes"].([]any)
		if !ok {
			return fmt.Errorf("terminal lane missing")
		}
		index, err := syncEffectIndex(items, "task_id", effect)
		if err != nil || index < 0 {
			return fmt.Errorf("terminal lane identity missing or ambiguous")
		}
		lane := items[index].(map[string]any)
		cancelled := lane["lifecycle"] == "cancelled"
		if cancelled {
			if work.Data.State != workStateCancelled {
				return fmt.Errorf("lane cancellation disagrees with canonical work")
			}
		} else {
			completed, ok := lane["completed_at"].(string)
			if work.Data.State != workStateCompleted || !ok || !sameValue(completed, work.Data.CompletedAt) || lane[effect.RequiredEnvironment.String()+"_status"] != "CLOSED" {
				return fmt.Errorf("lane completion disagrees with canonical work")
			}
		}
		ref := string(work.Data.ForecastRef)
		if ref != "" && (!validRef(ref, "forecasts.yaml") || textField(forecasts.Records[sourceID(ref, "forecasts.yaml")], "status") != "inactive") {
			return fmt.Errorf("terminal lane forecast is not inactive")
		}
		if retirement {
			oldItems, _ := before["lanes"].([]any)
			oldIndex, err := syncEffectIndex(oldItems, "task_id", effect)
			if err != nil || oldIndex < 0 {
				return fmt.Errorf("retired forecast lane missing")
			}
			oldLane := oldItems[oldIndex].(map[string]any)
			forecast, ok := oldLane["forecast"].(map[string]any)
			if !ok || forecast["forecast_ref"] != ref || ref == "" {
				return fmt.Errorf("retired forecast does not match canonical work")
			}
		}
	}
	return nil
}

// verifyStatusSyncEffects checks the entire original-to-candidate semantic delta
// against explicit accepted effects and preserves the ordered YAML comments.
func verifyStatusSyncEffects(original, candidate []byte, effects []syncEffect) error {
	beforeComments, err := yamlComments(original)
	if err != nil {
		return err
	}
	afterComments, err := yamlComments(candidate)
	if err != nil {
		return err
	}
	if !reflect.DeepEqual(beforeComments, afterComments) {
		return fmt.Errorf("status sync would change YAML comments")
	}
	var before, after map[string]any
	if err := yaml.Unmarshal(original, &before); err != nil {
		return err
	}
	if err := yaml.Unmarshal(candidate, &after); err != nil {
		return err
	}
	for _, effect := range effects {
		if err := applyExpectedSyncEffect(before, effect); err != nil {
			return fmt.Errorf("invalid status sync effect: %w", err)
		}
	}
	if !reflect.DeepEqual(before, after) {
		return fmt.Errorf("status sync candidate differs from authorized effects")
	}
	return nil
}

func applyExpectedSyncEffect(root map[string]any, effect syncEffect) error {
	switch effect.Operation {
	case syncEffectMetadata:
		encoded, err := json.Marshal(effect.Value)
		if err != nil {
			return err
		}
		var value any
		if err := yaml.Unmarshal(encoded, &value); err != nil {
			return err
		}
		root["status_sync"] = value
		return nil
	case syncEffectTimestamp, syncEffectTimelineAnchor:
		value, ok := effect.Value.(string)
		if !ok {
			return fmt.Errorf("timestamp must be a string")
		}
		field := "timestamp"
		if effect.Operation == syncEffectTimelineAnchor {
			field = "timeline_as_of"
		}
		root[field] = value
		return nil
	case syncEffectTimeline:
		snapshot, ok := effect.Value.(syncTimelineSnapshot)
		if !ok {
			return fmt.Errorf("invalid timeline snapshot")
		}
		encoded, err := yaml.Marshal(snapshot.Entries)
		if err != nil {
			return err
		}
		var entries any
		if err := yaml.Unmarshal(encoded, &entries); err != nil {
			return err
		}
		root["timeline"] = entries
		root["timeline_state"] = snapshot.State
		root["timeline_as_of"] = snapshot.AsOf
		return nil
	case syncEffectPriorityRemove:
		items, ok := root["top_priorities"].([]any)
		if !ok {
			return fmt.Errorf("missing top priorities")
		}
		remaining := make([]any, 0, len(items))
		for _, item := range items {
			id, ok := item.(string)
			if !ok {
				return fmt.Errorf("invalid top priority")
			}
			if id != effect.ID {
				remaining = append(remaining, item)
			}
		}
		root["top_priorities"] = remaining
		return nil
	case syncEffectDiagnostic:
		value, ok := effect.Value.(string)
		if !ok {
			return fmt.Errorf("diagnostic must be a string")
		}
		items, ok := root["blockers_risks"].([]any)
		if !ok {
			return fmt.Errorf("missing blockers")
		}
		root["scope_complete"] = false
		for _, item := range items {
			if text, ok := item.(string); ok && text == value {
				return nil
			}
		}
		root["blockers_risks"] = append(items, value)
		return nil
	case syncEffectSet:
		value := effect.Value
		if raw, ok := value.(json.RawMessage); ok {
			if err := yaml.Unmarshal(raw, &value); err != nil {
				return err
			}
		} else if _, ok := value.(string); !ok {
			return fmt.Errorf("invalid field value")
		}
		if effect.Target == syncTargetReport {
			if effect.ID != "current" {
				return fmt.Errorf("bad report identity")
			}
			root[effect.Field] = value
			return nil
		}
		section, identity, err := syncEffectSection(effect.Target)
		if err != nil {
			return err
		}
		items, ok := root[section].([]any)
		if !ok {
			return fmt.Errorf("missing %s", section)
		}
		index, err := syncEffectIndex(items, identity, effect)
		if err != nil {
			return err
		}
		if index < 0 {
			if identity != "subject_ref" || effect.Field != "text" {
				return fmt.Errorf("missing target %s", effect.ID)
			}
			items = append(items, map[string]any{identity: effect.ID, effect.Field: value})
			root[section] = items
			return nil
		}
		items[index].(map[string]any)[effect.Field] = value
		return nil
	case syncEffectAdd:
		section, identity, err := syncEffectSection(effect.Target)
		if err != nil {
			return err
		}
		raw, ok := effect.Value.(json.RawMessage)
		if !ok {
			return fmt.Errorf("addition must be raw JSON")
		}
		var record map[string]any
		if err := yaml.Unmarshal(raw, &record); err != nil {
			return err
		}
		if record[identity] != effect.ID {
			return fmt.Errorf("addition identity mismatch")
		}
		items, exists := root[section].([]any)
		if !exists && section != "reviews" && section != "lanes" && section != "root_completions" && section != "root_forecasts" {
			return fmt.Errorf("missing %s", section)
		}
		index, err := syncEffectIndex(items, identity, effect)
		if err != nil || index >= 0 {
			return fmt.Errorf("duplicate addition")
		}
		root[section] = append(items, record)
		return nil
	case syncEffectRemove:
		if effect.Target == syncTargetLane && (effect.Field == "forecast" || effect.Field == "completed_at") {
			effect.Operation = syncEffectClear
			return applyExpectedSyncEffect(root, effect)
		}
		section, identity, err := syncEffectSection(effect.Target)
		if err != nil {
			return err
		}
		if identity != "subject_ref" && effect.Target != syncTargetRootForecast && effect.Target != syncTargetRootCompletion {
			return fmt.Errorf("unsupported removal")
		}
		items, ok := root[section].([]any)
		if !ok {
			return fmt.Errorf("missing %s", section)
		}
		index, err := syncEffectIndex(items, identity, effect)
		if err != nil || index < 0 {
			return fmt.Errorf("missing removal target")
		}
		if identity != "subject_ref" {
			addition, ok := effect.Value.(syncAddition)
			if !ok {
				return fmt.Errorf("root removal lacks authorization")
			}
			var expected any
			if err := json.Unmarshal(addition.ExpectedPrior, &expected); err != nil {
				return fmt.Errorf("invalid expected prior")
			}
			encoded, err := json.Marshal(items[index])
			if err != nil {
				return err
			}
			var actual any
			if err := json.Unmarshal(encoded, &actual); err != nil || !reflect.DeepEqual(actual, expected) {
				return fmt.Errorf("root prior mismatch")
			}
		}
		root[section] = append(items[:index], items[index+1:]...)
		return nil
	case syncEffectClear, syncEffectForecastRetire, syncEffectCompletedAtClear:
		field := effect.Field
		if effect.Operation == syncEffectForecastRetire {
			field = "forecast"
		}
		if effect.Operation == syncEffectCompletedAtClear {
			field = "completed_at"
		}
		if effect.Target == syncTargetReport {
			if effect.ID != "current" {
				return fmt.Errorf("bad report identity")
			}
			delete(root, field)
			return nil
		}
		section, identity, err := syncEffectSection(effect.Target)
		if err != nil {
			return err
		}
		items, ok := root[section].([]any)
		if !ok {
			return fmt.Errorf("missing %s", section)
		}
		index, err := syncEffectIndex(items, identity, effect)
		if err != nil || index < 0 {
			return fmt.Errorf("missing target")
		}
		delete(items[index].(map[string]any), field)
		return nil
	default:
		return fmt.Errorf("unknown effect")
	}
}

func syncEffectSection(target syncTarget) (string, string, error) {
	switch target {
	case syncTargetTask:
		return "tasks", "id", nil
	case syncTargetLane:
		return "lanes", "task_id", nil
	case syncTargetReview:
		return "reviews", "task_id", nil
	case syncTargetPriorityEstimate:
		return "priority_estimates", "priority", nil
	case syncTargetRootCompletion:
		return "root_completions", "work_ref", nil
	case syncTargetRootForecast:
		return "root_forecasts", "forecast_ref", nil
	case syncTargetProgress, syncTargetDecisions, syncTargetBlockers, syncTargetVerification:
		return target.String(), "subject_ref", nil
	default:
		return "", "", fmt.Errorf("unknown target")
	}
}

func syncEffectIndex(items []any, identity string, effect syncEffect) (int, error) {
	found := -1
	for i, item := range items {
		record, ok := item.(map[string]any)
		if !ok || record[identity] != effect.ID {
			continue
		}
		if effect.Target == syncTargetLane && (record["work_ref"] != effect.WorkRef || record["required_environment"] != effect.RequiredEnvironment.String()) {
			continue
		}
		if found >= 0 {
			return -1, fmt.Errorf("duplicate target")
		}
		found = i
	}
	return found, nil
}

// verifyCanonicalSyncAddition validates source-owned records independently of insertion.
func verifyCanonicalSyncAddition(effect syncEffect, ledger ledgerSource, forecasts forecastSource) error {
	raw, ok := effect.Value.(json.RawMessage)
	if !ok {
		return fmt.Errorf("addition lacks source record")
	}
	var record struct {
		WorkRef     string `json:"work_ref"`
		ForecastRef string `json:"forecast_ref"`
		Outcome     string `json:"outcome"`
		CompletedAt string `json:"completed_at"`
		Lifecycle   string `json:"lifecycle"`
		Forecast    *struct {
			ForecastRef string `json:"forecast_ref"`
		} `json:"forecast"`
	}
	if err := json.Unmarshal(raw, &record); err != nil {
		return err
	}
	forecastMatches := func(ref, status, kind string) bool {
		if !validRef(ref, "forecasts.yaml") {
			return false
		}
		source := forecasts.Records[sourceID(ref, "forecasts.yaml")]
		return textField(source, "status") == status && textField(source, "kind") == kind
	}
	if effect.Target == syncTargetRootForecast {
		if !forecastMatches(record.ForecastRef, "active", "root") {
			return fmt.Errorf("invalid canonical root forecast")
		}
		found := false
		for _, work := range ledger.Records {
			if work.Type == "work" && hasRole(work.Data.Roles, reportingRoleRoot) && openWork(work.Data.State) && string(work.Data.ForecastRef) == record.ForecastRef {
				if !outcomeCorresponds(work, ledger.Records, record.Outcome) {
					return fmt.Errorf("root outcome mismatch")
				}
				found = true
			}
		}
		if !found {
			return fmt.Errorf("root forecast lacks active canonical work")
		}
		return nil
	}
	if !validRef(record.WorkRef, "project-understanding.yaml") {
		return fmt.Errorf("invalid canonical work reference")
	}
	work, ok := ledger.Records[sourceID(record.WorkRef, "project-understanding.yaml")]
	if !ok || work.Type != "work" || !outcomeCorresponds(work, ledger.Records, record.Outcome) {
		return fmt.Errorf("canonical work or outcome mismatch")
	}
	ref := string(work.Data.ForecastRef)
	if effect.Target == syncTargetRootCompletion {
		if strings.TrimSpace(effect.Evidence) == "" || !hasRole(work.Data.Roles, reportingRoleRoot) || work.Data.State != workStateCompleted || !sameValue(work.Data.CompletedAt, record.CompletedAt) || (ref != "" && !forecastMatches(ref, "inactive", "root")) {
			return fmt.Errorf("invalid canonical root completion")
		}
		return nil
	}
	if !hasRole(work.Data.Roles, reportingRoleLane) {
		return fmt.Errorf("canonical work is not a lane")
	}
	if openWork(work.Data.State) {
		if record.Forecast == nil || record.Forecast.ForecastRef != ref || !forecastMatches(ref, "active", "lane") {
			return fmt.Errorf("invalid active lane forecast")
		}
		return nil
	}
	if record.Forecast != nil || strings.TrimSpace(effect.Evidence) == "" || (ref != "" && !forecastMatches(ref, "inactive", "lane")) {
		return fmt.Errorf("invalid terminal lane forecast or evidence")
	}
	if work.Data.State == workStateCompleted && sameValue(work.Data.CompletedAt, record.CompletedAt) {
		return nil
	}
	if work.Data.State == workStateCancelled && record.Lifecycle == "cancelled" {
		return nil
	}
	return fmt.Errorf("invalid canonical lane completion")
}

// verifyCanonicalRootRemoval validates the explicit transition and its exact prior record.
func verifyCanonicalRootRemoval(before map[string]any, effect syncEffect, effects []syncEffect, ledger ledgerSource, forecasts forecastSource) error {
	addition, ok := effect.Value.(syncAddition)
	if !ok || strings.TrimSpace(addition.Evidence) == "" || effect.Evidence != addition.Evidence {
		return fmt.Errorf("root transition lacks evidence")
	}
	section, identity, err := syncEffectSection(effect.Target)
	if err != nil {
		return err
	}
	items, ok := before[section].([]any)
	if !ok {
		return fmt.Errorf("root prior missing")
	}
	index, err := syncEffectIndex(items, identity, effect)
	if err != nil || index < 0 {
		return fmt.Errorf("root prior identity missing")
	}
	actual, err := json.Marshal(items[index])
	if err != nil {
		return err
	}
	var got, expected any
	if json.Unmarshal(actual, &got) != nil || json.Unmarshal(addition.ExpectedPrior, &expected) != nil || !reflect.DeepEqual(got, expected) {
		return fmt.Errorf("root prior mismatch")
	}
	matched := false
	for _, add := range effects {
		raw, ok := add.Value.(json.RawMessage)
		if add.Operation == syncEffectAdd && add.Target == addition.Target && ok && string(raw) == string(addition.Record) && add.Evidence == addition.Evidence {
			matched = true
			break
		}
	}
	if !matched {
		return fmt.Errorf("root transition missing accompanying addition")
	}
	if err := verifyCanonicalSyncAddition(syncEffect{Target: addition.Target, Value: addition.Record, Evidence: addition.Evidence}, ledger, forecasts); err != nil {
		return err
	}
	var record struct {
		WorkRef     string `json:"work_ref"`
		ForecastRef string `json:"forecast_ref"`
	}
	if json.Unmarshal(addition.Record, &record) != nil {
		return fmt.Errorf("invalid root addition")
	}
	switch effect.Target {
	case syncTargetRootForecast:
		if addition.Target != syncTargetRootCompletion || !addition.RetireForecast || addition.ReopenWorkRef != "" || !validRef(record.WorkRef, "project-understanding.yaml") {
			return fmt.Errorf("root retirement not authorized")
		}
		work := ledger.Records[sourceID(record.WorkRef, "project-understanding.yaml")]
		if string(work.Data.ForecastRef) != effect.ID {
			return fmt.Errorf("root retirement forecast mismatch")
		}
	case syncTargetRootCompletion:
		if addition.Target != syncTargetRootForecast || addition.RetireForecast || addition.ReopenWorkRef != effect.ID || !validRef(effect.ID, "project-understanding.yaml") {
			return fmt.Errorf("root reopening not authorized")
		}
		work, ok := ledger.Records[sourceID(effect.ID, "project-understanding.yaml")]
		if !ok || work.Type != "work" || !hasRole(work.Data.Roles, reportingRoleRoot) || !openWork(work.Data.State) || string(work.Data.ForecastRef) != record.ForecastRef {
			return fmt.Errorf("root reopening work mismatch")
		}
	}
	return nil
}
