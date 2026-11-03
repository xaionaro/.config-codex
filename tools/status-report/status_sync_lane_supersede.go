package main

// staleLaneTransitionReplaced identifies a fully replaced, source-stale transition.
//
// Example: A later explicit reopening replaces an unapplied obsolete closure.
func staleLaneTransitionReplaced(
	data []byte,
	state syncState,
	old syncUpdate,
	group syncPendingGroup,
	keys []string,
	ledger ledgerSource,
	forecasts forecastSource,
) bool {
	if old.Target != syncTargetLane || old.Corrects != 0 || old.Retract || len(old.Values) != 0 || len(old.Clear) != 0 {
		return false
	}
	status := old.RequiredEnvironment.String() + "_status"
	closed := old.Fields[status] == "CLOSED" && old.Fields["completed_at"] != ""
	cancelled := old.Fields["lifecycle"] == "cancelled"
	if closed == cancelled {
		return false
	}
	for field := range old.Fields {
		if closed && field != status && field != "completed_at" {
			return false
		}
		if cancelled && field != "lifecycle" {
			return false
		}
	}
	work, ok := ledger.Records[sourceID(old.WorkRef, "project-understanding.yaml")]
	if !ok || work.Type != "work" {
		return false
	}
	if closed && work.Data.State == workStateCompleted && sameValue(work.Data.CompletedAt, old.Fields["completed_at"]) {
		return false
	}
	if cancelled && work.Data.State == workStateCancelled {
		return false
	}
	for _, key := range keys {
		nextGroup, exists := state.Groups[key]
		if !exists || nextGroup.Line < group.Line || (nextGroup.Line == group.Line && nextGroup.Ordinal <= group.Ordinal) {
			continue
		}
		next, err := decodeSyncGroup(nextGroup.Update)
		if err != nil || syncTargetKey(next, "") != syncTargetKey(old, "") {
			continue
		}
		if next.Corrects != 0 || next.Retract {
			return false
		}
		if cancelled {
			found := false
			for _, field := range next.Clear {
				if field == "lifecycle" {
					found = true
				}
			}
			if !found || !openWork(work.Data.State) {
				return false
			}
		} else if next.Fields[status] == "CLOSED" {
			if next.Fields["completed_at"] == "" || work.Data.State != workStateCompleted || !sameValue(work.Data.CompletedAt, next.Fields["completed_at"]) {
				return false
			}
		} else if next.Fields[status] == "" || !openWork(work.Data.State) {
			return false
		}
		candidate, effects, ok := applySyncGroup(data, next, ledger, forecasts, syncGroupPriorValues(state, next))
		if !ok {
			return false
		}
		for i := range effects {
			effects[i].Evidence = syncGroupEvidence(next)
		}
		return verifyStatusSyncCanonicalEffects(data, candidate, effects, ledger, forecasts) == nil
	}
	return false
}
