package main

import (
	"bytes"
	"encoding/json"
)

// promoteLegacyStructuredCorrections reconstructs provable complete corrections.
//
// Example: A saved owner fragment can recover its jointly owned effort update.
func promoteLegacyStructuredCorrections(
	state *syncState,
	before map[string]syncPending,
	data []byte,
	log []byte,
) {
	lines := bytes.Split(log, []byte("\n"))
	for key, pending := range state.Pending {
		if !legacyCorrectionHasStructuredCompanions(pending, log) || pending.Update.Corrects <= 0 || pending.Line <= 0 || pending.Line > len(lines) {
			continue
		}
		var event syncEvent
		if json.Unmarshal(lines[pending.Line-1], &event) != nil || event.Event != "correction" || event.Details.StatusUpdate == nil {
			continue
		}
		index := -1
		var update syncUpdate
		for i, item := range event.Details.StatusUpdate.Updates {
			if legacyCorrectionUpdateMatches(pending.Update, item) {
				if index >= 0 {
					index = -2
					break
				}
				index, update = i, item
			}
		}
		if index < 0 || !validStructuredSyncUpdate(update) {
			continue
		}
		valid, known := legacyCorrectionLocatorValid(pending, log)
		if !valid || !known || !legacyStructuredPriorProven(*state, data, lines, pending.Line, index, update) {
			continue
		}
		encoded, err := encodeSyncGroup(update)
		if err != nil {
			continue
		}
		groupKey := syncGroupKey(pending.Line, index)
		if _, exists := state.Groups[groupKey]; exists {
			continue
		}
		state.Groups[groupKey] = syncPendingGroup{Line: pending.Line, Ordinal: index, Update: encoded}
		for _, field := range syncGroupFields(update) {
			fieldKey := syncTargetKey(update, field)
			state.Latest[fieldKey] = update.Corrects
			delete(state.Pending, fieldKey)
			delete(before, fieldKey)
		}
		delete(state.Pending, key)
		delete(before, key)
	}
}

// legacyStructuredPriorProven requires exact baseline and unobstructed chronology.
//
// Example: An unowned or owner-edited effort keeps its correction pending.
func legacyStructuredPriorProven(
	state syncState,
	data []byte,
	lines [][]byte,
	line int,
	ordinal int,
	update syncUpdate,
) bool {
	priorOrdinal := 0
	if update.CorrectsOrdinal != nil {
		priorOrdinal = *update.CorrectsOrdinal
	}
	if update.Corrects <= 0 || update.Corrects > len(lines) {
		return false
	}
	var priorEvent syncEvent
	if json.Unmarshal(lines[update.Corrects-1], &priorEvent) != nil || priorEvent.Details.StatusUpdate == nil || priorOrdinal >= len(priorEvent.Details.StatusUpdate.Updates) {
		return false
	}
	prior := priorEvent.Details.StatusUpdate.Updates[priorOrdinal]
	if !validStructuredSyncUpdate(prior) || syncTargetKey(prior, "") != syncTargetKey(update, "") || prior.Corrects != 0 {
		return false
	}
	current, ok := structuredSyncValues(data, update)
	if !ok {
		return false
	}
	for _, field := range syncGroupFields(update) {
		key := syncTargetKey(update, field)
		if other, exists := state.Pending[key]; exists && (other.Line != line || !legacyCorrectionUpdateMatches(other.Update, update)) {
			return false
		}
		value, exists := state.Applied[key]
		if !exists || current[field] != value || state.AppliedOrdinals[key] != priorOrdinal || (state.Latest[key] != update.Corrects && state.Latest[key] != line) {
			return false
		}
		expected, found := legacyStructuredSuppliedValue(prior, field)
		if !found || value != expected {
			return false
		}
	}
	for number := update.Corrects; number <= line; number++ {
		var event syncEvent
		if json.Unmarshal(lines[number-1], &event) != nil || event.Details.StatusUpdate == nil {
			return false
		}
		for i, item := range event.Details.StatusUpdate.Updates {
			if number == update.Corrects && i <= priorOrdinal || number == line && i >= ordinal {
				continue
			}
			if syncTargetKey(item, "") == syncTargetKey(update, "") {
				return false
			}
		}
	}
	return true
}

// legacyStructuredSuppliedValue encodes the predecessor's explicit field value.
//
// Example: A cleared field has the absent ownership sentinel.
func legacyStructuredSuppliedValue(
	update syncUpdate,
	field string,
) (string, bool) {
	if value, ok := update.Fields[field]; ok {
		if update.Target == syncTargetTask || update.Target == syncTargetLane || update.Target == syncTargetReport {
			return scalarSyncStoredValue(value), true
		}
		return value, true
	}
	if raw, ok := update.Values[field]; ok {
		var value any
		decoder := json.NewDecoder(bytes.NewReader(raw))
		decoder.UseNumber()
		if decoder.Decode(&value) != nil {
			return "", false
		}
		encoded, err := json.Marshal(value)
		return string(encoded), err == nil
	}
	for _, item := range update.Clear {
		if item == field {
			return syncAbsentValue, true
		}
	}
	return "", false
}
