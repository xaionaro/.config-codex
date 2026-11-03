package main

import (
	"strings"

	"github.com/goccy/go-yaml/lexer"
	"github.com/goccy/go-yaml/token"
	"gopkg.in/yaml.v3"
)

// applyLaneSyncUpdateRaw builds one validated lane transition.
func applyLaneSyncUpdateRaw(
	data []byte,
	update syncUpdate,
	ledger ledgerSource,
	forecasts forecastSource,
	previous map[string]string,
) ([]byte, bool) {
	if update.Target != syncTargetLane || !validSyncUpdate(update) {
		return data, false
	}
	var doc yaml.Node
	if yaml.Unmarshal(data, &doc) != nil || len(doc.Content) != 1 {
		return data, false
	}
	list := mapValue(doc.Content[0], "lanes")
	if list == nil || list.Kind != yaml.SequenceNode {
		return data, false
	}
	var lane *yaml.Node
	for _, item := range list.Content {
		id, ref, env := mapValue(item, "task_id"), mapValue(item, "work_ref"), mapValue(item, "required_environment")
		if id != nil && ref != nil && env != nil && id.Value == update.ID && ref.Value == update.WorkRef && env.Value == update.RequiredEnvironment.String() {
			if lane != nil {
				return data, false
			}
			lane = item
		}
	}
	if lane == nil {
		return data, false
	}
	statusField := update.RequiredEnvironment.String() + "_status"
	terminal := update.Fields[statusField] == "CLOSED" || update.Fields["lifecycle"] == "cancelled"
	candidate := data
	if terminal {
		if !validRef(update.WorkRef, "project-understanding.yaml") || strings.TrimSpace(update.Evidence) == "" {
			return data, false
		}
		work, ok := ledger.Records[sourceID(update.WorkRef, "project-understanding.yaml")]
		if !ok || work.Type != "work" {
			return data, false
		}
		if update.Fields["lifecycle"] == "cancelled" {
			if work.Data.State != workStateCancelled {
				return data, false
			}
		}
		if update.Fields["lifecycle"] != "cancelled" && (work.Data.State != workStateCompleted || work.Data.CompletedAt == "" || !sameValue(update.Fields["completed_at"], work.Data.CompletedAt)) {
			return data, false
		}
		if forecast := mapValue(lane, "forecast"); forecast != nil {
			ref := mapValue(forecast, "forecast_ref")
			if ref == nil || ref.Value != string(work.Data.ForecastRef) || !validRef(ref.Value, "forecasts.yaml") || textField(forecasts.Records[sourceID(ref.Value, "forecasts.yaml")], "status") != "inactive" {
				return data, false
			}
			candidate, ok = removeLaneSyncField(candidate, update, "forecast")
			if !ok {
				return data, false
			}
		}
		if mapValue(lane, "forecast") == nil && work.Data.ForecastRef != "" && (!validRef(string(work.Data.ForecastRef), "forecasts.yaml") || textField(forecasts.Records[sourceID(string(work.Data.ForecastRef), "forecasts.yaml")], "status") != "inactive") {
			return data, false
		}
	}
	if status, ok := update.Fields[statusField]; ok && status != "CLOSED" && mapValue(lane, "completed_at") != nil {
		if prior := previous["completed_at"]; prior != "" && mapValue(lane, "completed_at").Value != prior {
			return data, false
		}
		var removed bool
		candidate, removed = removeLaneSyncField(candidate, update, "completed_at")
		if !removed {
			return data, false
		}
	}
	for field, value := range update.Fields {
		var ok bool
		candidate, ok = applySyncField(candidate, update, field, value, previous[field])
		if !ok {
			return data, false
		}
	}
	if _, err := parse(candidate); err != nil {
		return data, false
	}
	return candidate, true
}

// removeLaneSyncField removes a supplied field only when its bytes are unambiguous.
func removeLaneSyncField(
	data []byte,
	update syncUpdate,
	field string,
) ([]byte, bool) {
	var doc yaml.Node
	if yaml.Unmarshal(data, &doc) != nil || len(doc.Content) != 1 {
		return data, false
	}
	list := mapValue(doc.Content[0], "lanes")
	if list == nil {
		return data, false
	}
	var lane *yaml.Node
	for _, item := range list.Content {
		id, ref, env := mapValue(item, "task_id"), mapValue(item, "work_ref"), mapValue(item, "required_environment")
		if id != nil && ref != nil && env != nil && id.Value == update.ID && ref.Value == update.WorkRef && env.Value == update.RequiredEnvironment.String() {
			if lane != nil {
				return data, false
			}
			lane = item
		}
	}
	if lane == nil || lane.Kind != yaml.MappingNode {
		return data, false
	}
	for i := 0; i+1 < len(lane.Content); i += 2 {
		key := lane.Content[i]
		if key.Value != field {
			continue
		}
		start, err := yamlByteOffset(data, key.Line, key.Column)
		if err != nil {
			return data, false
		}
		var end int
		if lane.Style&yaml.FlowStyle != 0 {
			if i+2 < len(lane.Content) {
				end, err = yamlByteOffset(data, lane.Content[i+2].Line, lane.Content[i+2].Column)
			} else {
				end, err = flowMappingEndCached(&flowDocument{data: data}, lane)
				if err == nil {
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
			start -= key.Column - 1
			if i+2 < len(lane.Content) {
				end, err = yamlByteOffset(data, lane.Content[i+2].Line, 1)
			} else {
				end, _, err = blockMappingEnd(data, lane)
			}
		}
		if err != nil || start < 0 || end < start || end > len(data) || laneRemovalHasComment(data, start, end) {
			return data, false
		}
		out := append(append([]byte(nil), data[:start]...), data[end:]...)
		return out, true
	}
	return data, true
}

// laneRemovalHasComment protects comments while allowing hash characters in references.
func laneRemovalHasComment(
	data []byte,
	start int,
	end int,
) bool {
	for _, item := range lexer.Tokenize(string(data)) {
		if item.Type != token.CommentType || item.Position == nil {
			continue
		}
		offset, err := yamlByteOffset(data, item.Position.Line, item.Position.Column)
		if err != nil || (offset >= start && offset < end) {
			return true
		}
	}
	return false
}

// applyLaneSyncUpdate records the authorized changes accompanying a lane transition.
func applyLaneSyncUpdate(
	data []byte,
	update syncUpdate,
	ledger ledgerSource,
	forecasts forecastSource,
	previous map[string]string,
) ([]byte, []syncEffect, bool) {
	candidate, ok := applyLaneSyncUpdateRaw(data, update, ledger, forecasts, previous)
	if !ok {
		return data, nil, false
	}
	var before, after yaml.Node
	if yaml.Unmarshal(data, &before) != nil || yaml.Unmarshal(candidate, &after) != nil {
		return data, nil, false
	}
	find := func(doc *yaml.Node) *yaml.Node {
		list := mapValue(doc.Content[0], "lanes")
		for _, item := range list.Content {
			id, ref, env := mapValue(item, "task_id"), mapValue(item, "work_ref"), mapValue(item, "required_environment")
			if id != nil && ref != nil && env != nil && id.Value == update.ID && ref.Value == update.WorkRef && env.Value == update.RequiredEnvironment.String() {
				return item
			}
		}
		return nil
	}
	oldLane, newLane := find(&before), find(&after)
	if oldLane == nil || newLane == nil {
		return data, nil, false
	}
	base := syncEffect{Target: syncTargetLane, ID: update.ID, WorkRef: update.WorkRef, RequiredEnvironment: update.RequiredEnvironment}
	var effects []syncEffect
	for _, field := range []string{"forecast", "completed_at"} {
		if mapValue(oldLane, field) != nil && mapValue(newLane, field) == nil {
			effect := base
			effect.Field = field
			effect.Operation = syncEffectRemove
			effects = append(effects, effect)
		}
	}
	for field, value := range update.Fields {
		effect := base
		effect.Field = field
		effect.Value = value
		effect.Operation = syncEffectSet
		effects = append(effects, effect)
	}
	return candidate, effects, true
}
