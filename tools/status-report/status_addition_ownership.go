package main

import "encoding/json"

// taskAdditionOwnership captures supplied fields and absences for later conflict checks.
//
// Example: Remember a newly added task's owner before processing a later update.
func taskAdditionOwnership(record json.RawMessage) (map[string]string, bool) {
	var fields map[string]json.RawMessage
	if json.Unmarshal(record, &fields) != nil || fields == nil {
		return nil, false
	}
	scalar := []string{"status", "evidence", "owner", "context", "lifecycle"}
	typed := []string{"effort", "impact", "impact_points", "impact_basis", "priority", "work_refs", "indivisible_reason", "title", "parent_id"}
	result := make(map[string]string, len(scalar)+len(typed))
	for _, field := range scalar {
		raw, ok := fields[field]
		if !ok {
			result[field] = syncAbsentValue
			continue
		}
		var value string
		if json.Unmarshal(raw, &value) != nil || string(raw) == "null" {
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
		if json.Unmarshal(raw, &value) != nil || value == nil {
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
