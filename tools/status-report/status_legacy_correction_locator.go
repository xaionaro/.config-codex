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

// holdLegacyCompanions preserves fields of the same unresolved transaction.
//
// Example: A held lifecycle field keeps its same-line evidence pending.
func holdLegacyCompanions(
	pending map[string]syncPending,
	held map[string]syncPending,
	target syncPending,
) {
	for key, item := range pending {
		if item.Line == target.Line && syncTargetKey(item.Update, "") == syncTargetKey(target.Update, "") {
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
	if u.Corrects != pending.Line {
		return u.Corrects < pending.Line, true
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
	return syncCorrectionLocatorPrecedes(u, pending.Line, match), true
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
