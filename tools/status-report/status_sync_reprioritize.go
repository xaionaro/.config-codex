package main

import (
	"encoding/json"
	"sort"
)

// applyPendingReprioritizations applies a supplied estimate and existing task change together.
//
// Example: Move a task to a new priority without publishing an invalid intermediate report.
func applyPendingReprioritizations(
	data []byte,
	state *syncState,
	ledger ledgerSource,
	forecasts forecastSource,
	onlyKey string,
) ([]byte, []syncEffect) {
	keys := make([]string, 0, len(state.Groups))
	for key := range state.Groups {
		keys = append(keys, key)
	}
	sort.Slice(keys,
		// Preserve the event and within-event transaction order.
		//
		// Example: An earlier task update remains ahead of a later reprioritization.
		func(
			i int,
			j int,
		) bool {
			a, b := state.Groups[keys[i]], state.Groups[keys[j]]
			if a.Line != b.Line {
				return a.Line < b.Line
			}
			return a.Ordinal < b.Ordinal
		})
	var effects []syncEffect
	for _, key := range keys {
		if key != onlyKey {
			continue
		}
		group, exists := state.Groups[key]
		if !exists {
			continue
		}
		update, err := decodeSyncGroup(group.Update)
		if err != nil || update.Target != syncTargetTask || len(update.Values) == 0 {
			continue
		}
		var priority string
		if json.Unmarshal(update.Values["priority"], &priority) != nil || priority == "" {
			continue
		}
		estimateKey := "addition/priority_estimate/" + priority
		estimate, exists := state.PendingAdditions[estimateKey]
		if !exists || estimate.Line != group.Line || state.Latest[estimateKey] != estimate.Line {
			continue
		}
		if syncGroupOvertaken(*state, update, group.Line, group.Ordinal) || !syncGroupCorrectionMatches(*state, update) || syncHasPriorTargetGroup(*state, update, group) {
			continue
		}
		addition := syncAddition{Target: syncTargetPriorityEstimate, Record: json.RawMessage(estimate.Record), RetirePriority: estimate.RetirePriority, ExpectedPrior: json.RawMessage(estimate.ExpectedPrior)}
		candidate := data
		var removalEffects []syncEffect
		if addition.RetirePriority != "" {
			if addition.RetirePriority == priority || !syncTaskHasPriority(data, update.ID, addition.RetirePriority) {
				continue
			}
			var ok bool
			candidate, ok = removeRootSyncRecord(candidate, syncTargetPriorityEstimate, addition.RetirePriority, addition.ExpectedPrior)
			if !ok {
				continue
			}
			removalEffects = append(removalEffects, syncEffect{Target: syncTargetPriorityEstimate, ID: addition.RetirePriority, Value: addition, Operation: syncEffectRemove})
		}
		candidate, ok := insertSyncAddition(candidate, addition)
		if !ok {
			continue
		}
		candidate, changes, ok := applySyncGroup(candidate, update, ledger, forecasts, syncGroupPriorValues(*state, update))
		if !ok {
			continue
		}
		values, ok := syncGroupAppliedValues(candidate, update)
		if !ok {
			continue
		}
		additionEffect := syncEffect{Target: syncTargetPriorityEstimate, ID: priority, Value: json.RawMessage(estimate.Record), Operation: syncEffectAdd}
		groupEffects := append(removalEffects, additionEffect)
		groupEffects = append(groupEffects, changes...)
		if verifyPriorityRetirementEffects(data, groupEffects) != nil {
			continue
		}
		if verifyStatusSyncCanonicalEffects(data, candidate, groupEffects, ledger, forecasts) != nil {
			continue
		}
		ownership, valid := additionOwnership(syncTargetPriorityEstimate, json.RawMessage(estimate.Record))
		if !valid {
			continue
		}
		data = candidate
		effects = append(effects, groupEffects...)
		recordAdditionOwnership(state, syncUpdate{Target: syncTargetPriorityEstimate, ID: priority}, estimate.Line, ownership)
		state.Applied[estimateKey] = estimate.Record
		delete(state.PendingAdditions, estimateKey)
		for _, field := range syncGroupFields(update) {
			target := syncTargetKey(update, field)
			state.Latest[target] = group.Line
			state.AppliedOrdinals[target] = group.Ordinal
			state.Applied[target] = values[field]
		}
		delete(state.Groups, key)
	}
	return data, effects
}

// syncTaskHasPriority confirms an explicit retirement belongs to the selected task.
//
// Example: Reprioritizing one task cannot remove an unrelated estimate.
func syncTaskHasPriority(
	data []byte,
	id string,
	priority string,
) bool {
	report, err := parse(data)
	if err != nil {
		return false
	}
	for _, task := range report.Tasks {
		if string(task.ID) == id {
			return string(task.Priority) == priority
		}
	}
	return false
}

// syncHasPriorTargetGroup keeps target-local updates in their original order.
//
// Example: A blocked earlier task update is not bypassed by reprioritization.
func syncHasPriorTargetGroup(
	state syncState,
	update syncUpdate,
	group syncPendingGroup,
) bool {
	for _, other := range state.Groups {
		if other.Line > group.Line || (other.Line == group.Line && other.Ordinal >= group.Ordinal) {
			continue
		}
		prior, err := decodeSyncGroup(other.Update)
		if err != nil {
			continue
		}
		if syncTargetKey(prior, "") == syncTargetKey(update, "") {
			return true
		}
	}
	return false
}
