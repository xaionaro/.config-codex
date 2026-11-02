package main

import "fmt"

// validateFields enforces known scalar fields while allowing absent optional values.
func validateFields(section string, fields map[string]any, allowed map[string]bool) error {
	for key, value := range fields {
		if !allowed[key] {
			return fmt.Errorf("%s: unknown field %s", section, key)
		}
		if value == nil {
			continue
		}
		if _, ok := value.(string); !ok {
			return fmt.Errorf("%s: %s must be a string", section, key)
		}
	}
	return nil
}

// validateSections checks supported lane, forecast, scenario and timeline shapes.
func validateSections(r report) error {
	laneFields := map[string]bool{}
	for _, k := range []string{"id", "task_id", "parent_id", "outcome", "owner", "stage", "implementation_status", "test_status", "prod_status", "next_milestone", "completed_at", "blocker", "next_action", "context", "root_task_status"} {
		laneFields[k] = true
	}
	forecastFields := map[string]bool{}
	for _, k := range []string{"outcome", "target", "assessment", "baseline", "prior", "reason", "evidence", "dependencies"} {
		forecastFields[k] = true
	}
	scenarioFields := map[string]bool{}
	for _, k := range []string{"case", "trigger", "affected_work", "duration_basis", "evidence_assumptions", "endpoint", "evidence_gap_next_action"} {
		scenarioFields[k] = true
	}
	timelineFields := map[string]bool{"job": true, "parent_chain": true, "interval": true, "fast": true, "normal": true, "evidence": true, "uncertainty": true}
	chains := map[string]string{}
	for _, row := range r.Timeline {
		if err := validateFields("timeline", row, timelineFields); err != nil {
			return err
		}
		job, _ := row["job"].(string)
		chain, _ := row["parent_chain"].(string)
		if existing, ok := chains[job]; ok && existing != chain {
			return fmt.Errorf("timeline job %s has inconsistent parent_chain", job)
		}
		chains[job] = chain
	}
	lanes := append([]map[string]any(nil), r.Lanes...)
	for _, f := range r.RootForecasts {
		lanes = append(lanes, map[string]any{"forecast": f})
	}
	for _, lane := range lanes {
		scalars := make(map[string]any, len(lane))
		for k, v := range lane {
			if k != "forecast" {
				scalars[k] = v
			}
		}
		if err := validateFields("lane", scalars, laneFields); err != nil {
			return err
		}
		raw, exists := lane["forecast"]
		if !exists || raw == nil {
			continue
		}
		forecast, ok := raw.(map[string]any)
		if !ok {
			return fmt.Errorf("lane forecast must be a mapping")
		}
		scalars = make(map[string]any, len(forecast))
		for k, v := range forecast {
			if k != "scenarios" {
				scalars[k] = v
			}
		}
		if err := validateFields("forecast", scalars, forecastFields); err != nil {
			return err
		}
		if raw, exists := forecast["scenarios"]; exists {
			scenarios, ok := raw.([]any)
			if !ok {
				return fmt.Errorf("forecast scenarios must be a list")
			}
			for _, v := range scenarios {
				row, ok := v.(map[string]any)
				if !ok {
					return fmt.Errorf("forecast scenario must be a mapping")
				}
				if err := validateFields("forecast scenario", row, scenarioFields); err != nil {
					return err
				}
			}
		}
	}
	return nil
}
