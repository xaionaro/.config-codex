package main

import (
	"bytes"
	"encoding/json"
)

// holdAmbiguousLegacyCorrections isolates unprovable field-wise transactions.
//
// Example: Hold companion fields together until their source ordinal is known.
func holdAmbiguousLegacyCorrections(
	state *syncState,
	before map[string]syncPending,
	log []byte,
) (map[string]syncPending, bool) {
	held := map[string]syncPending{}
	invalid := false
	for key, pending := range state.Pending {
		if legacyRetractionIsSuperseded(*state, pending) {
			continue
		}
		valid, known := legacyCorrectionLocatorValid(pending, log)
		if !known {
			held[key] = pending
			continue
		}
		if !valid {
			delete(state.Pending, key)
			delete(before, key)
			invalid = true
		}
	}
	for _, pending := range held {
		holdLegacyCompanions(state.Pending, held, pending)
	}
	for key := range held {
		delete(state.Pending, key)
	}
	return held, invalid
}

// legacyRetractionIsSuperseded recognizes a later recorded narrative version.
//
// Example: A retraction for line one cannot remove text projected on line three.
func legacyRetractionIsSuperseded(
	state syncState,
	pending syncPending,
) bool {
	if !pending.Update.Retract || pending.Update.Corrects <= 0 || pending.Update.Corrects >= pending.Line {
		return false
	}
	return state.Latest[syncTargetKey(pending.Update, "text")] > pending.Update.Corrects || state.Latest[syncTargetKey(pending.Update, "evidence")] > pending.Update.Corrects
}

// holdLegacyCompanions preserves fields of the same unresolved transaction.
//
// Example: A held lifecycle field keeps its same-line evidence pending.
func holdLegacyCompanions(
	pending map[string]syncPending,
	held map[string]syncPending,
	target syncPending,
) {
	for key, item := range pending {
		if (item.Line == target.Line || target.Update.Retract) && syncTargetKey(item.Update, "") == syncTargetKey(target.Update, "") {
			held[key] = item
		}
	}
}

// legacyCorrectionLocatorValid verifies ordering when old field state lacks an ordinal.
//
// Example: A uniquely matched same-line update may name an earlier ordinal.
func legacyCorrectionLocatorValid(
	pending syncPending,
	log []byte,
) (valid bool, known bool) {
	u := pending.Update
	if u.Corrects == 0 {
		return u.CorrectsOrdinal == nil, true
	}
	if u.Corrects < 0 || pending.Line <= 0 || (u.CorrectsOrdinal != nil && *u.CorrectsOrdinal < 0) {
		return false, true
	}
	if u.Corrects > pending.Line {
		return false, true
	}
	lines := bytes.Split(log, []byte("\n"))
	if pending.Line > len(lines) {
		return false, false
	}
	var event syncEvent
	if json.Unmarshal(lines[pending.Line-1], &event) != nil || event.Event != "correction" || event.Details.StatusUpdate == nil {
		return false, false
	}
	match := -1
	for ordinal, candidate := range event.Details.StatusUpdate.Updates {
		if !legacyCorrectionUpdateMatches(u, candidate) {
			continue
		}
		if match >= 0 {
			return false, false
		}
		match = ordinal
	}
	if match < 0 {
		return false, false
	}
	if !syncCorrectionLocatorPrecedes(u, pending.Line, match) {
		return false, true
	}
	priorOrdinal := 0
	if u.CorrectsOrdinal != nil {
		priorOrdinal = *u.CorrectsOrdinal
	}
	var priorEvent syncEvent
	if json.Unmarshal(lines[u.Corrects-1], &priorEvent) != nil || priorEvent.Details.StatusUpdate == nil {
		return false, false
	}
	if priorOrdinal >= len(priorEvent.Details.StatusUpdate.Updates) {
		return false, true
	}
	prior := priorEvent.Details.StatusUpdate.Updates[priorOrdinal]
	if prior.Target == syncTargetUnknown {
		return false, false
	}
	if !legacyCorrectionPriorMatches(u, prior) {
		return false, true
	}
	return legacyCorrectionHasNoInterveningUpdate(u, lines, pending.Line, priorOrdinal, match)
}

// legacyCorrectionHasNoInterveningUpdate verifies that the predecessor is latest.
//
// Example: A newer assignment to the same field makes an older locator stale.
func legacyCorrectionHasNoInterveningUpdate(
	update syncUpdate,
	lines [][]byte,
	line int,
	priorOrdinal int,
	currentOrdinal int,
) (bool, bool) {
	for index := update.Corrects - 1; index < line; index++ {
		var event syncEvent
		if json.Unmarshal(lines[index], &event) != nil {
			return false, false
		}
		if event.Details.StatusUpdate == nil {
			continue
		}
		start, end := 0, len(event.Details.StatusUpdate.Updates)
		if index == update.Corrects-1 {
			start = priorOrdinal + 1
		}
		if index == line-1 {
			end = currentOrdinal
		}
		valid, known := legacyCorrectionInterveningFields(update, event.Event, index+1, start, priorOrdinal, event.Details.StatusUpdate.Updates[start:end])
		if !valid || !known {
			return valid, known
		}
	}
	return true, true
}

// legacyCorrectionInterveningFields rejects newer changes to the corrected field.
//
// Example: A later owner assignment supersedes an earlier assignment.
func legacyCorrectionInterveningFields(
	update syncUpdate,
	eventName string,
	line int,
	startOrdinal int,
	priorOrdinal int,
	intervening []syncUpdate,
) (bool, bool) {
	for offset, candidate := range intervening {
		if candidate.Target == syncTargetUnknown {
			return false, false
		}
		if !legacyCorrectionPriorMatches(update, candidate) {
			continue
		}
		if !legacyInterveningUpdateEligible(candidate, eventName, line, startOrdinal+offset, update.Corrects, priorOrdinal) {
			continue
		}
		return false, true
	}
	return true, true
}

// legacyInterveningUpdateEligible excludes updates that fresh replay rejects.
//
// Example: A self-referencing correction cannot supersede an earlier owner.
func legacyInterveningUpdateEligible(
	update syncUpdate,
	eventName string,
	line int,
	ordinal int,
	priorLine int,
	priorOrdinal int,
) bool {
	if !syncCorrectionLocatorPrecedes(update, line, ordinal) || !syncUpdateSelectorValid(update) {
		return false
	}
	if eventName != "correction" {
		return update.Corrects == 0 && !update.Retract && (validSyncUpdate(update) || validNarrativeSyncUpdate(update) || validStructuredSyncUpdate(update) || validLaneSyncUpdate(update) || validRootRetirementSyncUpdate(update))
	}
	if update.Corrects != priorLine {
		return false
	}
	actualOrdinal := 0
	if update.CorrectsOrdinal != nil {
		actualOrdinal = *update.CorrectsOrdinal
	}
	if actualOrdinal != priorOrdinal {
		return false
	}
	if update.Retract {
		probe := update
		probe.Fields = map[string]string{"text": "probe"}
		probe.Retract = false
		return len(update.Fields) == 0 && len(update.Values) == 0 && len(update.Clear) == 0 && validNarrativeSyncUpdate(probe)
	}
	return validSyncUpdate(update) || validNarrativeSyncUpdate(update) || validStructuredSyncUpdate(update) || validLaneSyncUpdate(update) || validRootRetirementSyncUpdate(update)
}

// legacyCorrectionPriorMatches checks that the named update owns the field.
//
// Example: An owner correction cannot name another task's assignment.
func legacyCorrectionPriorMatches(
	pending syncUpdate,
	prior syncUpdate,
) bool {
	if syncTargetKey(pending, "") != syncTargetKey(prior, "") {
		return false
	}
	fields := map[string]bool{}
	for _, field := range syncGroupFields(prior) {
		fields[field] = true
	}
	if pending.Retract {
		return fields["text"] || fields["evidence"]
	}
	for field := range pending.Fields {
		if !fields[field] {
			return false
		}
	}
	return true
}

// legacyCorrectionUpdateMatches identifies a field-wise update in its source event.
//
// Example: An event containing several fields may supply one saved field.
func legacyCorrectionUpdateMatches(
	pending syncUpdate,
	candidate syncUpdate,
) bool {
	if syncTargetKey(pending, "") != syncTargetKey(candidate, "") || pending.Corrects != candidate.Corrects || pending.Retract != candidate.Retract {
		return false
	}
	if (pending.CorrectsOrdinal == nil) != (candidate.CorrectsOrdinal == nil) {
		return false
	}
	if pending.CorrectsOrdinal != nil && *pending.CorrectsOrdinal != *candidate.CorrectsOrdinal {
		return false
	}
	for field, value := range pending.Fields {
		if actual, exists := candidate.Fields[field]; !exists || actual != value {
			return false
		}
	}
	return true
}
