package main

import "encoding/json"

// taskAdditionOwnership captures supplied fields and absences for later conflict checks.
//
// Example: Remember a newly added task's owner before processing a later update.
func taskAdditionOwnership(record json.RawMessage) (map[string]string, bool) {
	return additionOwnership(syncTargetTask, record)
}

// additionOwnership captures updateable fields for one newly inserted record.
//
// Example: Preserve a review's critic against a later owner's edit.
func additionOwnership(target syncTarget, record json.RawMessage) (map[string]string, bool) {
	var fields map[string]json.RawMessage
	if json.Unmarshal(record, &fields) != nil || fields == nil {
		return nil, false
	}
	var scalar, typed []string
	switch target {
	case syncTargetTask:
		scalar = []string{"status", "evidence", "owner", "context", "lifecycle"}
		typed = []string{"effort", "impact", "impact_points", "impact_basis", "priority", "work_refs", "indivisible_reason", "title", "parent_id"}
	case syncTargetReview:
		typed = []string{"reporter", "critic", "rounds", "estimate", "impact", "priority", "unresolved"}
	case syncTargetPriorityEstimate:
		typed = []string{"min_minutes", "max_minutes", "as_of", "basis", "assumptions", "dependencies", "critical_path"}
	case syncTargetLane:
		scalar = []string{"owner", "implementation_status", "test_status", "prod_status", "blocker", "next_action", "next_milestone", "context", "completed_at", "lifecycle", "root_task_status"}
		typed = []string{"forecast"}
	case syncTargetRootCompletion, syncTargetRootForecast:
	default:
		return nil, false
	}
	result := make(map[string]string, len(scalar)+len(typed))
	for _, field := range scalar {
		raw, ok := fields[field]
		if !ok {
			result[field] = syncAbsentValue
			continue
		}
		var value string
		if string(raw) == "null" {
			result[field] = "null"
			continue
		}
		if json.Unmarshal(raw, &value) != nil {
			return nil, false
		}
		result[field] = value
	}
	for _, field := range typed {
		raw, ok := fields[field]
		if !ok {
			result[field] = syncAbsentValue
			continue
		}
		var value any
		if json.Unmarshal(raw, &value) != nil {
			return nil, false
		}
		encoded, err := json.Marshal(value)
		if err != nil {
			return nil, false
		}
		result[field] = string(encoded)
	}
	return result, true
}
