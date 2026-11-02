package main

import (
	"reflect"
	"sort"
)

// validateWorkOutcomes checks canonical active work outcome links by record identity.
//
// Example: Reject a dangling link even if its text resembles an outcome ID.
func validateWorkOutcomes(
	id string,
	work sourceRecord,
	records map[string]sourceRecord,
) []string {
	if !openWork(work.Data.State) {
		return nil
	}
	if len(work.OutcomeRefs) == 0 {
		return []string{"active work " + id + " missing outcome links"}
	}
	var issues []string
	seen := map[string]bool{}
	for _, ref := range work.OutcomeRefs {
		record, ok := records[ref]
		if !ok || record.Type != "outcome" {
			issues = append(issues, "active work "+id+" has invalid outcome link "+ref)
		}
		if seen[ref] {
			issues = append(issues, "active work "+id+" has duplicate outcome link "+ref)
		}
		seen[ref] = true
	}
	return issues
}

// outcomeSet returns the complete canonical identity set in stable order.
//
// Example: Two differently ordered references identify the same set.
func outcomeSet(refs []string) []string {
	out := append([]string{}, refs...)
	sort.Strings(out)
	return out
}

// checkSharedForecastOwners rejects forecast claims for unrelated outcome sets.
//
// Example: Two roots may share a forecast only for the same full outcome set.
func checkSharedForecastOwners(works map[string]sourceRecord) []string {
	owners := map[sourceRef][]string{}
	var issues []string
	for id, work := range works {
		if work.Data.ForecastRef == "" || (!openWork(work.Data.State) && !hasRole(work.Data.Roles, reportingRoleRoot)) {
			continue
		}
		prior, ok := owners[work.Data.ForecastRef]
		current := outcomeSet(work.OutcomeRefs)
		if ok && (!reflect.DeepEqual(prior, current) || len(current) == 0) {
			issues = append(issues, "forecast "+string(work.Data.ForecastRef)+" shared by unrelated work "+id)
		}
		if !ok {
			owners[work.Data.ForecastRef] = current
		}
	}
	return issues
}

// laneSemanticEquivalence checks whether canonical descriptions establish one identity.
//
// Example: A lane and forecast matching one linked outcome are source-backed.
func laneSemanticEquivalence(
	l lane,
	work sourceRecord,
	ledger ledgerSource,
	source map[string]any,
) bool {
	forecastOutcome := textField(source, "outcome")
	matches := 0
	for _, id := range work.OutcomeRefs {
		record, ok := ledger.Records[id]
		if ok && record.Type == "outcome" && record.Outcome == l.Outcome && record.Outcome == forecastOutcome {
			matches++
		}
	}
	return matches == 1
}
