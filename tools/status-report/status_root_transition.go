package main

import (
	"encoding/json"
	"reflect"
	"strings"

	"github.com/goccy/go-yaml/token"
	"gopkg.in/yaml.v3"
)

// applyRootSyncAddition applies a root addition and any explicitly identified retirement atomically.
//
// Example: Replace a root forecast with its completion.
func applyRootSyncAddition(
	data []byte,
	addition syncAddition,
	ledger ledgerSource,
	forecasts forecastSource,
) ([]byte, []syncEffect, bool) {
	if !syncAdditionSourceValid(addition, ledger, forecasts) {
		return data, nil, false
	}
	var supplied struct {
		WorkRef     string `json:"work_ref"`
		ForecastRef string `json:"forecast_ref"`
	}
	if json.Unmarshal(addition.Record, &supplied) != nil {
		return data, nil, false
	}
	if !addition.RetireForecast && addition.ReopenWorkRef == "" && len(addition.ExpectedPrior) == 0 {
		if rootAdditionHasCounterpart(data, addition, ledger) {
			return data, nil, false
		}
		candidate, ok := applySyncAddition(data, addition)
		return candidate, nil, ok
	}
	if len(addition.ExpectedPrior) == 0 {
		return data, nil, false
	}
	var target syncTarget
	var id string
	switch {
	case addition.Target == syncTargetRootCompletion && addition.RetireForecast && addition.ReopenWorkRef == "":
		work := ledger.Records[sourceID(supplied.WorkRef, "project-understanding.yaml")]
		target, id = syncTargetRootForecast, string(work.Data.ForecastRef)
	case addition.Target == syncTargetRootCompletion && !addition.RetireForecast && addition.ReopenWorkRef == "":
		target, id = syncTargetRootCompletion, supplied.WorkRef
	case addition.Target == syncTargetRootForecast && !addition.RetireForecast && validRef(addition.ReopenWorkRef, "project-understanding.yaml"):
		if strings.TrimSpace(addition.Evidence) == "" {
			return data, nil, false
		}
		work, ok := ledger.Records[sourceID(addition.ReopenWorkRef, "project-understanding.yaml")]
		if !ok || work.Type != "work" || !hasRole(work.Data.Roles, reportingRoleRoot) || !openWork(work.Data.State) || string(work.Data.ForecastRef) != supplied.ForecastRef {
			return data, nil, false
		}
		target, id = syncTargetRootCompletion, addition.ReopenWorkRef
	default:
		return data, nil, false
	}
	if id == "" {
		return data, nil, false
	}
	candidate, ok := removeRootSyncRecord(data, target, id, addition.ExpectedPrior)
	if !ok {
		return data, nil, false
	}
	if rootAdditionHasCounterpart(candidate, addition, ledger) {
		return data, nil, false
	}
	candidate, ok = applySyncAddition(candidate, addition)
	if !ok {
		return data, nil, false
	}
	operation := syncEffectRemove
	if target == syncTargetRootCompletion && addition.Target == syncTargetRootCompletion {
		operation = syncEffectRootCompletionCorrection
	}
	return candidate, []syncEffect{{Target: target, ID: id, Value: addition, Evidence: addition.Evidence, Operation: operation}}, true
}

// rootAdditionHasCounterpart detects terminal/open representations of the same work.
//
// Example: Detect a forecast already representing a completed root.
func rootAdditionHasCounterpart(
	data []byte,
	addition syncAddition,
	ledger ledgerSource,
) bool {
	var supplied struct {
		WorkRef     string `json:"work_ref"`
		ForecastRef string `json:"forecast_ref"`
	}
	if json.Unmarshal(addition.Record, &supplied) != nil {
		return true
	}
	var doc yaml.Node
	if yaml.Unmarshal(data, &doc) != nil || len(doc.Content) != 1 {
		return true
	}
	if addition.Target == syncTargetRootCompletion {
		work := ledger.Records[sourceID(supplied.WorkRef, "project-understanding.yaml")]
		list := mapValue(doc.Content[0], "root_forecasts")
		if list == nil {
			return false
		}
		for _, item := range list.Content {
			if ref := mapValue(item, "forecast_ref"); ref != nil && ref.Value == string(work.Data.ForecastRef) {
				return true
			}
		}
		return false
	}
	list := mapValue(doc.Content[0], "root_completions")
	if list == nil {
		return false
	}
	for _, item := range list.Content {
		ref := mapValue(item, "work_ref")
		if ref == nil || !validRef(ref.Value, "project-understanding.yaml") {
			continue
		}
		work := ledger.Records[sourceID(ref.Value, "project-understanding.yaml")]
		if string(work.Data.ForecastRef) == supplied.ForecastRef {
			return true
		}
	}
	return false
}

// removeRootSyncRecord removes an exact root or priority record without deleting comments.
//
// Example: Retire a matching priority estimate while retaining neighboring comments.
func removeRootSyncRecord(
	data []byte,
	target syncTarget,
	id string,
	expected json.RawMessage,
) ([]byte, bool) {
	section, identity := "root_forecasts", "forecast_ref"
	switch target {
	case syncTargetRootCompletion:
		section, identity = "root_completions", "work_ref"
	case syncTargetPriorityEstimate:
		section, identity = "priority_estimates", "priority"
	case syncTargetRootForecast:
	default:
		return data, false
	}
	var doc yaml.Node
	if yaml.Unmarshal(data, &doc) != nil || len(doc.Content) != 1 {
		return data, false
	}
	root := doc.Content[0]
	list := mapValue(root, section)
	if list == nil || list.Kind != yaml.SequenceNode {
		return data, false
	}
	var expectedValue any
	if json.Unmarshal(expected, &expectedValue) != nil {
		return data, false
	}
	index := -1
	for i, item := range list.Content {
		key := mapValue(item, identity)
		if key != nil && key.Value == id {
			if index >= 0 {
				return data, false
			}
			index = i
		}
	}
	if index < 0 {
		return data, false
	}
	var actual any
	if list.Content[index].Decode(&actual) != nil {
		return data, false
	}
	encoded, err := json.Marshal(actual)
	if err != nil {
		return data, false
	}
	var normalized any
	if json.Unmarshal(encoded, &normalized) != nil || !reflect.DeepEqual(normalized, expectedValue) {
		return data, false
	}
	item := list.Content[index]
	start, err := yamlByteOffset(data, item.Line, item.Column)
	if err != nil {
		return data, false
	}
	end := 0
	replacement := ""
	if list.Style&yaml.FlowStyle != 0 {
		if index+1 < len(list.Content) {
			end, err = yamlByteOffset(data, list.Content[index+1].Line, list.Content[index+1].Column)
		} else {
			listStart, e := yamlByteOffset(data, list.Line, list.Column)
			if e != nil {
				return data, false
			}
			end, err = flowEnd(data, listStart, token.SequenceStartType)
			if index > 0 {
				for start > 0 && (data[start-1] == ' ' || data[start-1] == '\t') {
					start--
				}
				if start == 0 || data[start-1] != ',' {
					return data, false
				}
				start--
			}
		}
	} else {
		lineStart := strings.LastIndex(string(data[:start]), "\n") + 1
		if !strings.HasPrefix(strings.TrimSpace(string(data[lineStart:start])), "-") {
			return data, false
		}
		start = lineStart
		switch {
		case index+1 < len(list.Content):
			end, err = yamlByteOffset(data, list.Content[index+1].Line, 1)
		case nextMappingFieldLine(root, section) > 0:
			end, err = yamlByteOffset(data, nextMappingFieldLine(root, section), 1)
		default:
			end = len(data)
		}
		if len(list.Content) == 1 {
			replacement = "  []\n"
		}
	}
	if err != nil || start < 0 || end < start || end > len(data) || laneRemovalHasComment(data, start, end) {
		return data, false
	}
	return append(append(append([]byte(nil), data[:start]...), []byte(replacement)...), data[end:]...), true
}
